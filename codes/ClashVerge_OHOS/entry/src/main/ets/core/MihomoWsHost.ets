import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { webSocket } from '@kit.NetworkKit';

import { CONTROLLER_HOST, CONTROLLER_PORT } from '../common/Constants';
import { Log } from '../common/Logger';
import { JsBridge } from '../bridge/JsBridge';

/**
 * `plugin:mihomo|ws_*` 的 ArkTS 实现。
 *
 * 上游这些命令在本体（Rust 插件）里是"后端开一条到 mihomo 的 WebSocket，
 * 把收到的文本帧通过 Channel 推给前端"。前端契约（vendor/tauri-plugin-mihomo-api）：
 *
 *   invoke('plugin:mihomo|ws_traffic', { onMessage: Channel }) → id: string
 *   Channel 每帧：字符串 或 {type:'Text', data:string}
 *   invoke('plugin:mihomo|ws_disconnect', { id, forceTimeout }) 关闭
 *
 * 鸿蒙侧直接用 `@ohos.net.webSocket` 连 127.0.0.1:9090，收到文本就 channelSend 出去。
 * 内核没起来时连不上：**不抛错**，每 3s 重连，日志按 10s 节流（否则每秒一条会把 hilog 刷满）。
 */
class WsSession {
  id: string = '';
  channel: number = 0;
  endpoint: string = '';
  /** connections_count 需要把 /connections 的响应折成 {"count":N} */
  countOnly: boolean = false;
  socket: webSocket.WebSocket | null = null;
  frame: number = 0;
  closed: boolean = false;
  connecting: boolean = false;
  retryTimer: number = -1;
  lastErrorLog: number = 0;
  errorCount: number = 0;
}

export class MihomoWsHost {
  private static seq: number = 1;
  private static sessions: Map<string, WsSession> = new Map<string, WsSession>();
  private static bridge: JsBridge | null = null;
  private static host: string = CONTROLLER_HOST;
  private static port: number = CONTROLLER_PORT;
  private static secret: string = '';
  private static readonly RETRY_MS: number = 3000;
  private static readonly ERROR_LOG_GAP_MS: number = 10000;

  static setController(host: string, port: number): void {
    if (host.length > 0) {
      MihomoWsHost.host = host;
    }
    if (port > 0) {
      MihomoWsHost.port = port;
    }
  }

  static setSecret(secret: string): void {
    MihomoWsHost.secret = secret;
  }

  static install(bridge: JsBridge): void {
    MihomoWsHost.bridge = bridge;

    bridge.register('plugin:mihomo|ws_traffic', async (args: Record<string, Object>): Promise<Object | null> =>
      MihomoWsHost.open('/traffic', args, false));
    bridge.register('plugin:mihomo|ws_memory', async (args: Record<string, Object>): Promise<Object | null> =>
      MihomoWsHost.open('/memory', args, false));
    bridge.register('plugin:mihomo|ws_connections', async (args: Record<string, Object>): Promise<Object | null> =>
      MihomoWsHost.open('/connections', args, false));
    bridge.register('plugin:mihomo|ws_connections_count', async (args: Record<string, Object>): Promise<Object | null> =>
      MihomoWsHost.open('/connections', args, true));
    bridge.register('plugin:mihomo|ws_logs', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['level'];
      const level = typeof raw === 'string' ? raw as string : 'info';
      return MihomoWsHost.open(`/logs?level=${level}`, args, false);
    });

    bridge.register('plugin:mihomo|ws_disconnect', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['id'];
      if (typeof raw === 'string') {
        MihomoWsHost.close(raw as string);
      }
      return null;
    });

    bridge.register('plugin:mihomo|clear_all_ws_connections', async (): Promise<Object | null> => {
      const ids: string[] = [];
      MihomoWsHost.sessions.forEach((_value: WsSession, key: string) => {
        ids.push(key);
      });
      for (let i = 0; i < ids.length; i++) {
        MihomoWsHost.close(ids[i]);
      }
      return null;
    });
  }

  private static open(endpoint: string, args: Record<string, Object>, countOnly: boolean): string {
    const id = `ws-${MihomoWsHost.seq++}`;
    const session = new WsSession();
    session.id = id;
    session.endpoint = endpoint;
    session.countOnly = countOnly;
    const raw = args['__channels'];
    if (raw !== undefined && raw !== null) {
      const channels = raw as number[];
      if (channels.length > 0) {
        session.channel = channels[0];
      }
    }
    MihomoWsHost.sessions.set(id, session);
    Log.i('MihomoWs', `open ${id} ${endpoint} channel=${session.channel}`);
    MihomoWsHost.connect(session);
    return id;
  }

  private static connect(session: WsSession): void {
    if (session.closed || session.connecting) {
      return;
    }
    session.connecting = true;
    const socket = webSocket.createWebSocket();
    session.socket = socket;

    socket.on('open', (err: BusinessError, value: Object) => {
      session.connecting = false;
      session.errorCount = 0;
      Log.i('MihomoWs', `${session.id} connected ${session.endpoint}`);
    });

    socket.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (session.closed) {
        return;
      }
      let text = '';
      if (typeof value === 'string') {
        text = value as string;
      } else {
        text = MihomoWsHost.decode(value as ArrayBuffer);
      }
      if (text.length === 0) {
        return;
      }
      if (session.countOnly) {
        text = MihomoWsHost.countOf(text);
      }
      MihomoWsHost.push(session, text);
    });

    socket.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      session.connecting = false;
      if (session.closed) {
        return;
      }
      MihomoWsHost.scheduleReconnect(session);
    });

    socket.on('error', (err: BusinessError) => {
      session.connecting = false;
      if (session.closed) {
        return;
      }
      session.errorCount++;
      const now = Date.now();
      if (now - session.lastErrorLog > MihomoWsHost.ERROR_LOG_GAP_MS) {
        session.lastErrorLog = now;
        Log.w('MihomoWs', `${session.id} error (retry ${session.errorCount}): ${Log.err(err as Object)}`);
      }
      MihomoWsHost.scheduleReconnect(session);
    });

    const header: Record<string, string> = {};
    if (MihomoWsHost.secret.length > 0) {
      header['Authorization'] = `Bearer ${MihomoWsHost.secret}`;
    }
    const suffix = MihomoWsHost.secret.length > 0 ? `?token=${MihomoWsHost.secret}` : '';
    const url = `ws://${MihomoWsHost.host}:${MihomoWsHost.port}${session.endpoint}${suffix}`;
    const options: webSocket.WebSocketRequestOptions = { header: header };
    socket.connect(url, options).catch((e: Object) => {
      session.connecting = false;
      if (session.closed) {
        return;
      }
      session.errorCount++;
      const now = Date.now();
      if (now - session.lastErrorLog > MihomoWsHost.ERROR_LOG_GAP_MS) {
        session.lastErrorLog = now;
        Log.w('MihomoWs', `${session.id} connect failed (${session.errorCount}): ${Log.err(e)}`);
      }
      MihomoWsHost.scheduleReconnect(session);
    });
  }

  private static scheduleReconnect(session: WsSession): void {
    if (session.closed || session.retryTimer >= 0) {
      return;
    }
    MihomoWsHost.teardown(session);
    session.retryTimer = setTimeout(() => {
      session.retryTimer = -1;
      if (!session.closed) {
        MihomoWsHost.connect(session);
      }
    }, MihomoWsHost.RETRY_MS);
  }

  private static push(session: WsSession, text: string): void {
    const bridge = MihomoWsHost.bridge;
    if (bridge === null || session.channel <= 0) {
      return;
    }
    bridge.channelSend(session.channel, session.frame, JSON.stringify(text), false);
    session.frame++;
  }

  private static teardown(session: WsSession): void {
    const socket = session.socket;
    session.socket = null;
    if (socket === null) {
      return;
    }
    try {
      socket.off('message');
      socket.off('open');
      socket.off('close');
      socket.off('error');
      socket.close().catch(() => {
      });
    } catch (e) {
      // 关闭失败不影响重连
    }
  }

  private static close(id: string): void {
    const session = MihomoWsHost.sessions.get(id);
    if (session === undefined) {
      return;
    }
    session.closed = true;
    if (session.retryTimer >= 0) {
      clearTimeout(session.retryTimer);
      session.retryTimer = -1;
    }
    MihomoWsHost.teardown(session);
    MihomoWsHost.sessions.delete(id);
    Log.i('MihomoWs', `closed ${id}`);
  }

  private static countOf(text: string): string {
    try {
      const parsed = JSON.parse(text) as Record<string, Object | null>;
      const list = parsed['connections'];
      const count = (list === undefined || list === null) ? 0 : (list as Object[]).length;
      return JSON.stringify({ count: count });
    } catch (e) {
      return text;
    }
  }

  /**
   * 二进制帧解码。
   *
   * 不能用 `String.fromCharCode(byte)` 逐字节拼：那是 Latin-1 语义，遇到 UTF-8 的
   * 中文（日志里的节点名、报错信息）会变成乱码。统一交给 TextDecoder。
   */
  private static decode(buffer: ArrayBuffer): string {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer));
    } catch (e) {
      return '';
    }
  }
}
