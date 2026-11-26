import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { webSocket } from '@kit.NetworkKit';

import { CONTROLLER_HOST, CONTROLLER_PORT } from '../common/Constants';
import { Log } from '../common/Logger';

/**
 * 托盘面板用的极简 mihomo WebSocket 客户端。
 *
 * 为什么必须用 WS：内核里 `/traffic`、`/memory` 都是**流式** handler
 * （`for range tick.C { write; flush }`，只有写失败才 break），普通 HTTP GET 永远不返回。
 * 上一版用 `HttpClient.request('/memory')` 每轮都挂到 2.5s 超时，导致：
 *   · 内核占用永远 `--`（拿不到响应体）；
 *   · 同一轮里排在它后面的 `/proxies` 被拖慢 → 活跃连接/节点信息刷新不及时。
 * 主界面首页本来就是走 WS 的（`plugin:mihomo|ws_*`），这里对齐同一套数据源。
 *
 * 与 `MihomoWsHost` 的区别：那个是给 WebView 用、要往 Channel 推二进制帧；
 * 这个只在本进程内回调字符串，不带桥接。
 */
export class TrayWs {
  private endpoint: string;
  private secretOf: () => string;
  private onText: (text: string) => void;
  private socket: webSocket.WebSocket | null = null;
  private closed: boolean = false;
  private connecting: boolean = false;
  private retryTimer: number = -1;
  private lastErrorLog: number = 0;
  private errorCount: number = 0;
  private readonly retryMs: number = 3000;
  private readonly errorLogGapMs: number = 10000;

  constructor(endpoint: string, secretOf: () => string, onText: (text: string) => void) {
    this.endpoint = endpoint;
    this.secretOf = secretOf;
    this.onText = onText;
  }

  start(): void {
    this.closed = false;
    this.connect();
  }

  stop(): void {
    this.closed = true;
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.teardown();
  }

  isOpen(): boolean {
    return this.socket !== null && !this.connecting;
  }

  private connect(): void {
    if (this.closed || this.connecting) {
      return;
    }
    this.connecting = true;
    const socket = webSocket.createWebSocket();
    this.socket = socket;

    socket.on('open', (err: BusinessError, value: Object): void => {
      this.connecting = false;
      this.errorCount = 0;
      Log.i('TrayWs', `${this.endpoint} connected`);
    });

    socket.on('message', (err: BusinessError, value: string | ArrayBuffer): void => {
      if (this.closed) {
        return;
      }
      let text = '';
      if (typeof value === 'string') {
        text = value as string;
      } else {
        text = this.decode(value as ArrayBuffer);
      }
      if (text.length === 0) {
        return;
      }
      this.onText(text);
    });

    socket.on('close', (err: BusinessError, value: webSocket.CloseResult): void => {
      this.connecting = false;
      if (this.closed) {
        return;
      }
      this.scheduleRetry();
    });

    socket.on('error', (err: BusinessError): void => {
      this.connecting = false;
      if (this.closed) {
        return;
      }
      this.errorCount++;
      const now = Date.now();
      if (now - this.lastErrorLog > this.errorLogGapMs) {
        this.lastErrorLog = now;
        Log.w('TrayWs', `${this.endpoint} error (${this.errorCount}): ${Log.err(err as Object)}`);
      }
      this.scheduleRetry();
    });

    // 面板可能在配置落盘前就起来了：每次连接都重新读一次 secret，别把空串写死。
    const token = this.secretOf();
    const header: Record<string, string> = {};
    if (token.length > 0) {
      header['Authorization'] = `Bearer ${token}`;
    }
    const suffix = token.length > 0 ? `?token=${token}` : '';
    const url = `ws://${CONTROLLER_HOST}:${CONTROLLER_PORT}${this.endpoint}${suffix}`;
    const options: webSocket.WebSocketRequestOptions = { header: header };
    socket.connect(url, options).catch((e: Object): void => {
      this.connecting = false;
      if (this.closed) {
        return;
      }
      this.scheduleRetry();
      Log.w('TrayWs', `${this.endpoint} connect failed: ${Log.err(e)}`);
    });
  }

  private scheduleRetry(): void {
    if (this.closed || this.retryTimer >= 0) {
      return;
    }
    this.teardown();
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (!this.closed) {
        this.connect();
      }
    }, this.retryMs);
  }

  private teardown(): void {
    const socket = this.socket;
    this.socket = null;
    if (socket === null) {
      return;
    }
    try {
      socket.off('message');
      socket.off('open');
      socket.off('close');
      socket.off('error');
      socket.close().catch((): void => {
      });
    } catch (e) {
      // 关闭失败不影响重连
    }
  }

  /** 二进制帧按 UTF-8 解码（不能逐字节拼，中文会乱码） */
  private decode(buffer: ArrayBuffer): string {
    try {
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer));
    } catch (e) {
      return '';
    }
  }
}
