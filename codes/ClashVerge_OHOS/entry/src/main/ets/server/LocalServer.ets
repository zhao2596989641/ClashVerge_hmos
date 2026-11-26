import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { socket } from '@kit.NetworkKit';

import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';

class MimeEntry {
  ext: string = '';
  type: string = '';

  constructor(ext: string, type: string) {
    this.ext = ext;
    this.type = type;
  }
}

const MIME_TABLE: MimeEntry[] = [
  new MimeEntry('html', 'text/html; charset=utf-8'),
  new MimeEntry('htm', 'text/html; charset=utf-8'),
  new MimeEntry('js', 'text/javascript; charset=utf-8'),
  new MimeEntry('mjs', 'text/javascript; charset=utf-8'),
  new MimeEntry('css', 'text/css; charset=utf-8'),
  new MimeEntry('json', 'application/json; charset=utf-8'),
  new MimeEntry('map', 'application/json; charset=utf-8'),
  new MimeEntry('svg', 'image/svg+xml'),
  new MimeEntry('png', 'image/png'),
  new MimeEntry('jpg', 'image/jpeg'),
  new MimeEntry('jpeg', 'image/jpeg'),
  new MimeEntry('gif', 'image/gif'),
  new MimeEntry('webp', 'image/webp'),
  new MimeEntry('ico', 'image/x-icon'),
  new MimeEntry('woff', 'font/woff'),
  new MimeEntry('woff2', 'font/woff2'),
  new MimeEntry('ttf', 'font/ttf'),
  new MimeEntry('otf', 'font/otf'),
  new MimeEntry('wasm', 'application/wasm'),
  new MimeEntry('txt', 'text/plain; charset=utf-8')
];

function mimeOf(path: string): string {
  const dot = path.lastIndexOf('.');
  if (dot < 0) {
    return 'application/octet-stream';
  }
  const ext = path.substring(dot + 1).toLowerCase();
  for (let i = 0; i < MIME_TABLE.length; i++) {
    if (MIME_TABLE[i].ext === ext) {
      return MIME_TABLE[i].type;
    }
  }
  return 'application/octet-stream';
}

function asciiOf(bytes: Uint8Array, start: number, end: number): string {
  let out = '';
  const limit = Math.min(end, bytes.length);
  for (let i = start; i < limit; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

/**
 * 主进程内的极简静态资源服务。
 *
 * 为什么不用 `$rawfile` 直接加载：`resource://rawfile` 属于不透明源，ESM / fetch / WS
 * 的行为与普通 http 源不一致（模块脚本与跨源请求最容易被拦）。把前端产物以
 * `http://127.0.0.1:PORT` 提供，前端就是标准的浏览器运行环境，行为可预测。
 *
 * 资源直接从 rawfile 读取（不做解包），保证与 HAP 内容永远一致。
 */
export class LocalServer {
  private resMgr: resourceManager.ResourceManager;
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private rootPrefix: string = 'web/';
  /** rawfile 内容缓存：前端产物总共 20MB 量级，全量驻留内存可接受，避免每帧重读磁盘 */
  private cache: Map<string, Uint8Array> = new Map<string, Uint8Array>();
  private cacheBytes: number = 0;
  private static readonly CACHE_LIMIT: number = 64 * 1024 * 1024;
  private static readonly SEND_CHUNK: number = 64 * 1024;

  constructor(resMgr: resourceManager.ResourceManager, rootPrefix: string) {
    this.resMgr = resMgr;
    this.rootPrefix = rootPrefix;
  }

  getPort(): number {
    return this.port;
  }

  async start(preferredPort: number, attempts: number): Promise<number> {
    const srv = socket.constructTCPSocketServerInstance();
    srv.on('connect', (conn: socket.TCPSocketConnection) => {
      this.onConnection(conn);
    });
    srv.on('error', (err) => {
      Log.e('Server', `server error: ${Log.err(err as Object)}`);
    });

    let lastError: Object = new Error('listen failed');
    for (let i = 0; i < attempts; i++) {
      const candidate = preferredPort + i;
      try {
        await srv.listen({ address: '127.0.0.1', port: candidate, family: 1 });
        this.server = srv;
        this.port = candidate;
        Log.i('Server', `listening on http://127.0.0.1:${candidate}`);
        return candidate;
      } catch (e) {
        lastError = e as Object;
        Log.w('Server', `listen ${candidate} failed: ${Log.err(e as Object)}`);
      }
    }
    throw new Error(`cannot bind local server: ${Log.err(lastError)}`);
  }

  async stop(): Promise<void> {
    const srv = this.server;
    this.server = null;
    if (srv === null) {
      return;
    }
    try {
      srv.off('connect');
      await srv.close();
    } catch (e) {
      Log.w('Server', `close failed: ${Log.err(e as Object)}`);
    }
  }

  private onConnection(conn: socket.TCPSocketConnection): void {
    let buffer = new Uint8Array(0);
    let handled = false;

    conn.on('message', (info: socket.SocketMessageInfo) => {
      if (handled) {
        return;
      }
      const chunk = new Uint8Array(info.message);
      const merged = new Uint8Array(buffer.length + chunk.length);
      merged.set(buffer, 0);
      merged.set(chunk, buffer.length);
      buffer = merged;

      const headEnd = LocalServer.indexOfHeaderEnd(buffer);
      if (headEnd < 0) {
        if (buffer.length > 65536) {
          handled = true;
          this.sendText(conn, 431, 'Request Header Fields Too Large').catch(() => {
          });
        }
        return;
      }
      handled = true;
      const head = asciiOf(buffer, 0, headEnd);
      this.handleRequest(conn, head).catch((e: Object) => {
        Log.w('Server', `handle failed: ${Log.err(e)}`);
      });
    });

    conn.on('close', () => {
      buffer = new Uint8Array(0);
    });

    conn.on('error', (err) => {
      Log.w('Server', `conn error: ${Log.err(err as Object)}`);
    });
  }

  private static indexOfHeaderEnd(bytes: Uint8Array): number {
    for (let i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10) {
        return i;
      }
    }
    return -1;
  }

  private async handleRequest(conn: socket.TCPSocketConnection, head: string): Promise<void> {
    const lines = head.split('\r\n');
    if (lines.length === 0 || lines[0].length === 0) {
      await this.sendText(conn, 400, 'Bad Request');
      return;
    }
    const parts = lines[0].split(' ');
    if (parts.length < 2) {
      await this.sendText(conn, 400, 'Bad Request');
      return;
    }
    const method = parts[0].toUpperCase();
    // 每个请求打一行：实机黑屏时，日志里有没有这行直接区分「Web 没发请求」和「服务返回错」
    Log.i('Server', `req ${method} ${parts[1]}`);
    if (method !== 'GET' && method !== 'HEAD') {
      await this.sendText(conn, 405, 'Method Not Allowed');
      return;
    }
    let target = parts[1];
    const q = target.indexOf('?');
    if (q >= 0) {
      target = target.substring(0, q);
    }
    const hash = target.indexOf('#');
    if (hash >= 0) {
      target = target.substring(0, hash);
    }
    try {
      target = decodeURIComponent(target);
    } catch (e) {
      target = '/';
    }
    if (target.length === 0 || target === '/') {
      target = '/index.html';
    }
    if (target.indexOf('..') >= 0) {
      await this.sendText(conn, 403, 'Forbidden');
      return;
    }
    while (target.startsWith('/')) {
      target = target.substring(1);
    }

    // /__asset/ 前缀映射到应用沙箱绝对路径（供 convertFileSrc 显示本地图标）
    const assetPrefix = '__asset/';
    if (target.startsWith(assetPrefix)) {
      const absPath = `/${target.substring(assetPrefix.length)}`;
      const bytes = FsUtil.readBytes(absPath);
      if (bytes === null) {
        await this.sendText(conn, 404, 'Not Found');
        return;
      }
      await this.sendBytes(conn, mimeOf(absPath), new Uint8Array(bytes), method === 'HEAD', 'no-cache');
      return;
    }

    const rawPath = this.rootPrefix + target;

    const body = this.readRaw(rawPath);
    if (body === null) {
      // SPA 回退：未命中的非静态路径统一回 index.html，交给前端路由处理
      if (target.indexOf('.') < 0) {
        const fallback = this.readRaw(this.rootPrefix + 'index.html');
        if (fallback !== null) {
          await this.sendBytes(conn, mimeOf('index.html'), fallback, method === 'HEAD',
            LocalServer.cacheControlOf('index.html'));
          return;
        }
      }
      await this.sendText(conn, 404, `Not Found: ${target}`);
      return;
    }

    await this.sendBytes(conn, mimeOf(target), body, method === 'HEAD', LocalServer.cacheControlOf(target));
  }

  /** 读 rawfile，命中缓存直接复用；缓存上限内全量驻留 */
  private readRaw(rawPath: string): Uint8Array | null {
    const hit = this.cache.get(rawPath);
    if (hit !== undefined) {
      return hit;
    }
    let bytes: Uint8Array;
    try {
      bytes = this.resMgr.getRawFileContentSync(rawPath);
    } catch (e) {
      return null;
    }
    if (bytes.length > 0 && this.cacheBytes + bytes.length <= LocalServer.CACHE_LIMIT) {
      this.cache.set(rawPath, bytes);
      this.cacheBytes += bytes.length;
    }
    return bytes;
  }

  /**
   * 静态资源缓存策略：vite 产物 assets/ 下带内容 hash，可强缓存；
   * 其余（index.html、rawfile 里的配置/图标）必须每次校验，否则热更新看不到变化。
   */
  private static cacheControlOf(path: string): string {
    if (path.indexOf('assets/') === 0 && path.indexOf('-') > 0) {
      return 'public, max-age=31536000, immutable';
    }
    return 'no-cache';
  }

  private async sendBytes(conn: socket.TCPSocketConnection, ctype: string, body: Uint8Array,
    isHead: boolean, cacheControl: string): Promise<void> {
    const len = body.length;
    Log.i('Server', `send 200 ${ctype} ${len}B`);
    const header = `HTTP/1.1 200 OK\r\nContent-Type: ${ctype}\r\nContent-Length: ${len}\r\n` +
      `Cache-Control: ${cacheControl}\r\nConnection: close\r\n\r\n`;
    try {
      await conn.send({ data: header });
      if (isHead || len === 0) {
        await this.closeQuietly(conn);
        return;
      }
      // 分块发送：单次 send 一个 20MB 的 chunk 会超过内核 socket buffer，务必按块写
      const step = LocalServer.SEND_CHUNK;
      for (let offset = 0; offset < len; offset += step) {
        const end = Math.min(offset + step, len);
        const piece = new ArrayBuffer(end - offset);
        new Uint8Array(piece).set(body.subarray(offset, end));
        await conn.send({ data: piece });
      }
    } catch (e) {
      Log.w('Server', `send failed: ${Log.err(e as Object)}`);
    }
    await this.closeQuietly(conn);
  }

  private async sendText(conn: socket.TCPSocketConnection, code: number, message: string): Promise<void> {
    const body = `${message}`;
    // Content-Length 必须按字节算，中文错误信息按字符数会截断
    const bodyLen = new util.TextEncoder().encodeInto(body).length;
    const header = `HTTP/1.1 ${code} ${message}\r\nContent-Type: text/plain; charset=utf-8\r\n` +
      `Content-Length: ${bodyLen}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`;
    try {
      await conn.send({ data: header });
      await conn.send({ data: body });
    } catch (e) {
      Log.w('Server', `send failed: ${Log.err(e as Object)}`);
    }
    await this.closeQuietly(conn);
  }

  private async closeQuietly(conn: socket.TCPSocketConnection): Promise<void> {
    try {
      await conn.close();
    } catch (e) {
      // 客户端提前断开属正常情况
    }
  }
}
