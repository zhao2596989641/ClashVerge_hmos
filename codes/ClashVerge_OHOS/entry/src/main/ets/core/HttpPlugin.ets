import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';

import { Log } from '../common/Logger';
import { JsBridge } from '../bridge/JsBridge';

/**
 * `@tauri-apps/plugin-http` 的 ArkTS 实现。
 *
 * 上游前端用 `fetch()`（来自插件，不是浏览器 fetch）取 IP 归属地等信息。该插件是
 * **三段式 IPC**（读 `node_modules/@tauri-apps/plugin-http/dist-js/index.js`）：
 *
 *   1. `plugin:http|fetch`       { clientConfig } → rid
 *   2. `plugin:http|fetch_send`  { rid } → { status, statusText, url, headers, rid }
 *   3. `plugin:http|fetch_read_body` { rid } → number[]，**最后一个字节是结束标志**
 *      （0 = 还有数据，1 = 结束，前端会 slice 掉这个字节）
 *
 * 另有 `fetch_cancel` / `fetch_cancel_body`，这里按"立即丢弃"处理。
 */
class FetchEntry {
  method: string = 'GET';
  url: string = '';
  headers: string[][] = [];
  body: ArrayBuffer = new ArrayBuffer(0);
  timeoutMs: number = 30000;

  status: number = 0;
  statusText: string = '';
  responseHeaders: string[][] = [];
  responseBody: ArrayBuffer = new ArrayBuffer(0);
  consumed: boolean = false;
}

export class HttpPlugin {
  private static seq: number = 1;
  private static entries: Map<number, FetchEntry> = new Map<number, FetchEntry>();
  /** 本地 mixed-port；IP 检测类请求显式走代理，保证显示的是节点出口 IP */
  private static proxyPort: number = 0;

  static setProxyPort(port: number): void {
    if (port > 0) {
      HttpPlugin.proxyPort = port;
    }
  }

  private static isIpCheckUrl(url: string): boolean {
    return url.indexOf('api.ip.sb') >= 0
      || url.indexOf('ipapi.co') >= 0
      || url.indexOf('api.ipapi.is') >= 0
      || url.indexOf('ipwho.is') >= 0
      || url.indexOf('ip.api.skk.moe') >= 0
      || url.indexOf('get.geojs.io') >= 0;
  }

  static install(bridge: JsBridge): void {
    bridge.register('plugin:http|fetch', async (args: Record<string, Object>): Promise<Object | null> => {
      const rid = HttpPlugin.seq++;
      const entry = new FetchEntry();
      const raw = args['clientConfig'];
      if (raw !== undefined && raw !== null) {
        const config = raw as Record<string, Object | null>;
        const method = config['method'];
        if (typeof method === 'string') {
          entry.method = method as string;
        }
        const url = config['url'];
        if (typeof url === 'string') {
          entry.url = url as string;
        }
        const headers = config['headers'];
        if (headers !== undefined && headers !== null) {
          entry.headers = HttpPlugin.pairsOf(headers);
        }
        const data = config['data'];
        if (data !== undefined && data !== null) {
          entry.body = HttpPlugin.bodyOf(data);
        }
        const connectTimeout = config['connectTimeout'];
        if (typeof connectTimeout === 'number' && (connectTimeout as number) > 0) {
          entry.timeoutMs = connectTimeout as number;
        }
      }
      HttpPlugin.entries.set(rid, entry);
      Log.i('HttpPlugin', `fetch #${rid} ${entry.method} ${entry.url}`);
      return rid;
    });

    bridge.register('plugin:http|fetch_send', async (args: Record<string, Object>): Promise<Object | null> => {
      const rid = HttpPlugin.ridOf(args);
      const entry = HttpPlugin.entries.get(rid);
      if (entry === undefined) {
        throw new Error(`unknown http rid ${rid}`);
      }
      await HttpPlugin.perform(rid, entry);
      const out: Record<string, Object | null> = {};
      out['status'] = entry.status;
      out['statusText'] = entry.statusText;
      out['url'] = entry.url;
      out['headers'] = entry.responseHeaders;
      out['rid'] = rid;
      return out;
    });

    bridge.register('plugin:http|fetch_read_body', async (args: Record<string, Object>): Promise<Object | null> => {
      const rid = HttpPlugin.ridOf(args);
      const entry = HttpPlugin.entries.get(rid);
      if (entry === undefined || entry.consumed) {
        // 只有结束标志：前端读到 1 就 close()
        // 顺手把已经读完的 entry 丢掉，避免每次 fetch 泄漏一份响应体
        HttpPlugin.entries.delete(rid);
        const end: number[] = [1];
        return end;
      }
      entry.consumed = true;
      const bytes = new Uint8Array(entry.responseBody);
      if (bytes.length === 0) {
        // 空响应不会再有下一次 pull，这里就把 entry 丢掉
        HttpPlugin.entries.delete(rid);
        const end: number[] = [1];
        return end;
      }
      const payload: number[] = new Array(bytes.length + 1);
      for (let i = 0; i < bytes.length; i++) {
        payload[i] = bytes[i];
      }
      payload[bytes.length] = 0;
      return payload;
    });

    bridge.register('plugin:http|fetch_cancel', async (args: Record<string, Object>): Promise<Object | null> => {
      HttpPlugin.entries.delete(HttpPlugin.ridOf(args));
      return null;
    });

    bridge.register('plugin:http|fetch_cancel_body', async (args: Record<string, Object>): Promise<Object | null> => {
      HttpPlugin.entries.delete(HttpPlugin.ridOf(args));
      return null;
    });
  }

  private static ridOf(args: Record<string, Object>): number {
    const raw = args['rid'];
    if (typeof raw === 'number') {
      return raw as number;
    }
    return -1;
  }

  private static async perform(rid: number, entry: FetchEntry): Promise<void> {
    let client: http.HttpRequest | null = null;
    try {
      client = http.createHttp();
      const header: Record<string, string> = {};
      for (let i = 0; i < entry.headers.length; i++) {
        const pair = entry.headers[i];
        if (pair.length >= 2) {
          header[pair[0]] = pair[1];
        }
      }
      const options: http.HttpRequestOptions = {
        method: HttpPlugin.methodOf(entry.method),
        header: header,
        connectTimeout: entry.timeoutMs,
        readTimeout: entry.timeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      };
      if (entry.body.byteLength > 0) {
        options.extraData = entry.body;
      }
      const response = await client.request(entry.url, options);
      entry.status = response.responseCode;
      entry.statusText = HttpPlugin.statusTextOf(response.responseCode);
      const payload = response.result;
      if (payload instanceof ArrayBuffer) {
        entry.responseBody = payload;
      } else if (typeof payload === 'string') {
        const encoded = new Uint8Array(HttpPlugin.utf8(payload as string));
        const copy = new ArrayBuffer(encoded.length);
        new Uint8Array(copy).set(encoded);
        entry.responseBody = copy;
      }
      entry.responseHeaders = HttpPlugin.headersOf(response);
    } catch (e) {
      Log.w('HttpPlugin', `#${rid} ${entry.method} ${entry.url} failed: ${Log.err(e as Object)}`);
      throw new Error(`http request failed: ${Log.err(e as Object)}`);
    } finally {
      if (client !== null) {
        try {
          client.destroy();
        } catch (e) {
          // ignore
        }
      }
    }
  }

  private static methodOf(name: string): http.RequestMethod {
    switch (name.toUpperCase()) {
      case 'POST':
        return http.RequestMethod.POST;
      case 'PUT':
        return http.RequestMethod.PUT;
      case 'DELETE':
        return http.RequestMethod.DELETE;
      case 'PATCH':
        return http.RequestMethod.PATCH;
      case 'HEAD':
        return http.RequestMethod.HEAD;
      case 'OPTIONS':
        return http.RequestMethod.OPTIONS;
      default:
        return http.RequestMethod.GET;
    }
  }

  private static statusTextOf(code: number): string {
    if (code >= 200 && code < 300) {
      return 'OK';
    }
    if (code >= 300 && code < 400) {
      return 'Redirect';
    }
    if (code >= 400 && code < 500) {
      return 'Client Error';
    }
    if (code >= 500) {
      return 'Server Error';
    }
    return '';
  }

  private static headersOf(response: http.HttpResponse): string[][] {
    const out: string[][] = [];
    try {
      const raw = response.header as Record<string, Object>;
      if (raw === undefined || raw === null) {
        return out;
      }
      const keys = Object.keys(raw);
      for (let i = 0; i < keys.length; i++) {
        const value = raw[keys[i]];
        const pair: string[] = [keys[i], ''];
        if (typeof value === 'string') {
          pair[1] = value as string;
        } else if (Array.isArray(value)) {
          const arr = value as string[];
          pair[1] = arr.length > 0 ? arr[0] : '';
        } else if (value !== undefined && value !== null) {
          pair[1] = `${value}`;
        }
        out.push(pair);
      }
    } catch (e) {
      // 头信息缺失不影响 body
    }
    return out;
  }

  /** Tauri 传的是 [[name, value], ...] */
  private static pairsOf(raw: Object): string[][] {
    const out: string[][] = [];
    try {
      const list = raw as Object[];
      for (let i = 0; i < list.length; i++) {
        const pairRaw = list[i] as Object[];
        if (pairRaw.length < 2) {
          continue;
        }
        const pair: string[] = [`${pairRaw[0]}`, `${pairRaw[1]}`];
        out.push(pair);
      }
    } catch (e) {
      Log.w('HttpPlugin', `bad headers: ${Log.err(e as Object)}`);
    }
    return out;
  }

  /** data 可能是字符串，也可能是字节数组 */
  private static bodyOf(raw: Object): ArrayBuffer {
    if (typeof raw === 'string') {
      const encoded = new Uint8Array(HttpPlugin.utf8(raw as string));
      const buffer = new ArrayBuffer(encoded.length);
      new Uint8Array(buffer).set(encoded);
      return buffer;
    }
    if (Array.isArray(raw)) {
      const arr = raw as number[];
      const buffer = new ArrayBuffer(arr.length);
      const view = new Uint8Array(buffer);
      for (let i = 0; i < arr.length; i++) {
        view[i] = arr[i];
      }
      return buffer;
    }
    return new ArrayBuffer(0);
  }

  private static utf8(text: string): ArrayBuffer {
    const bytes: number[] = [];
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else {
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      }
    }
    const buffer = new ArrayBuffer(bytes.length);
    new Uint8Array(buffer).set(bytes);
    return buffer;
  }
}
