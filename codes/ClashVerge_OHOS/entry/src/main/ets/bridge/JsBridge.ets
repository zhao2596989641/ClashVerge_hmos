import { webview } from '@kit.ArkWeb';

import { Log } from '../common/Logger';

export type CmdHandler = (args: Record<string, Object>) => Promise<Object | null>;

export type VoidHandler = () => void;

/**
 * ArkWeb ←→ ArkTS 的唯一通道。
 *
 * JS 侧（tauri-shim.js）把每一次 `__TAURI_INTERNALS__.invoke` 转成
 * `clashBridge.invoke(cmd, argsJson, replyId)`；ArkTS 异步处理完后，
 * 用 `runJavaScript` 回到 `window.__cgBridgeReply(replyId, ok, payload)`。
 *
 * 之所以要 replyId 而不是直接 return：javaScriptProxy 的调用是同步返回的，
 * 而绝大多数命令都要等 IO（文件/HTTP/内核），必须走异步回包。
 */
export class JsBridge {
  private controller: webview.WebviewController | null = null;
  private handlers: Map<string, CmdHandler> = new Map<string, CmdHandler>();
  private owner: string = 'main';

  constructor(owner: string) {
    this.owner = owner;
  }

  attach(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  register(cmd: string, handler: CmdHandler): void {
    this.handlers.set(cmd, handler);
  }

  has(cmd: string): boolean {
    return this.handlers.has(cmd);
  }

  /** JS 调用入口：必须与 javaScriptProxy 的 methodList 一致 */
  invoke(cmd: string, argsJson: string, replyId: string): void {
    const handler = this.handlers.get(cmd);
    if (handler === undefined) {
      // 窗口外观类命令（set_theme / set_minimizable / minimize / toggleMaximize ...）一律视为
      // 成功空操作：桌面端的窗口装饰由系统管理，这些调用在我们这儿没有意义；
      // 但**抛错会变成 unhandled rejection**，实测能让 main.tsx 的启动链断掉
      // （日志里 `[main.tsx] Unhandled promise rejection: ... set_minimizable`）。
      if (cmd.indexOf('plugin:window|') === 0) {
        Log.i('Bridge', `window command ignored: ${cmd}`);
        this.reply(replyId, true, 'null');
        return;
      }
      Log.w('Bridge', `unimplemented command: ${cmd}`);
      this.replyError(replyId, `command not implemented in HarmonyOS build: ${cmd}`);
      return;
    }
    let args: Record<string, Object> = {};
    if (argsJson !== undefined && argsJson !== null && argsJson.length > 0) {
      try {
        args = JSON.parse(argsJson) as Record<string, Object>;
      } catch (e) {
        Log.w('Bridge', `bad args for ${cmd}: ${argsJson}`);
        this.replyError(replyId, `invalid arguments for ${cmd}`);
        return;
      }
    }
    // Channel 参数在 IPC 里序列化成 { __TAURI_TO_IPC_KEY__: <callbackId> }，
    // 抽出来放进 args.__channels，需要回灌的 handler 自己取（见 check_media_unlock）
    const channels: number[] = [];
    JsBridge.collectChannels(args, channels);
    if (channels.length > 0) {
      args['__channels'] = channels;
    }
    handler(args).then((result: Object | null) => {
      let payload = 'null';
      try {
        const text = JSON.stringify(result);
        payload = (text === undefined || text === null || text.length === 0) ? 'null' : text;
      } catch (e) {
        payload = 'null';
      }
      this.reply(replyId, true, payload);
    }).catch((e: Object) => {
      const message = Log.err(e);
      Log.w('Bridge', `${cmd} failed: ${message}`);
      this.replyError(replyId, message);
    });
  }

  /** 前端 console 转发（dev 期靠它看日志） */
  log(level: string, message: string): void {
    const line = `[web/${level}] ${message}`;
    if (level === 'error') {
      Log.e('Web', line);
    } else if (level === 'warn') {
      Log.w('Web', line);
    } else {
      Log.i('Web', line);
    }
  }

  /** 后端主动推事件（对应前端 @tauri-apps/api 的 listen） */
  emit(event: string, payload: Object): void {
    // payloadJson 本身就是合法 JSON 字面量，直接拼进脚本，避免二次 stringify 变成「字符串里套字符串」
    const payloadJson = JsBridge.toJsonLiteral(payload);
    this.runJs(`window.__cgEmit && window.__cgEmit(${JSON.stringify(event)}, ${payloadJson});`);
  }

  /**
   * 系统深浅色变化。
   *
   * 前端 `useCustomTheme` 在 `theme_mode === 'system'` 时监听的是 Tauri 的
   * `tauri://theme-changed`（`appWindow.onThemeChanged`）—— 之前我们从来没发过这个事件，
   * 所以系统切主题后界面不会动，只有重新选一次「跟随系统」才会重新拉一次。
   * payload 必须是主题字符串本身（'dark' / 'light'），不是对象。
   */
  emitSystemTheme(mode: string): void {
    const literal = JSON.stringify(mode);
    this.runJs(`window.__cgEmit && window.__cgEmit('tauri://theme-changed', ${literal});`);
  }

  private reply(replyId: string, ok: boolean, payloadJson: string): void {
    const id = JSON.stringify(replyId);
    // 同理：payloadJson 已是合法 JSON 字面量，不能再 JSON.stringify 一次
    const body = payloadJson.length > 0 ? payloadJson : 'null';
    this.runJs(`window.__cgBridgeReply && window.__cgBridgeReply(${id}, ${ok ? 'true' : 'false'}, ${body});`);
  }

  private static toJsonLiteral(value: Object | null): string {
    try {
      const text = JSON.stringify(value);
      if (text === undefined || text === null || text.length === 0) {
        return 'null';
      }
      return text;
    } catch (e) {
      return 'null';
    }
  }

  /** 失败回包：错误文本必须当 JSON 字符串字面量传，否则拼进脚本会语法错误 */
  private replyError(replyId: string, message: string): void {
    this.reply(replyId, false, JsBridge.toJsonLiteral(message));
  }

  /** 递归查找 Channel 标记，收集 callbackId */
  private static collectChannels(node: Object | null, out: number[]): void {
    if (node === null || node === undefined) {
      return;
    }
    if (Array.isArray(node)) {
      const arr = node as Object[];
      for (let i = 0; i < arr.length; i++) {
        JsBridge.collectChannels(arr[i], out);
      }
      return;
    }
    if (typeof node === 'string') {
      // @tauri-apps/api 的 Channel#toJSON() 实际返回 "__CHANNEL__:<id>"
      // （不是旧注释里的 __TAURI_TO_IPC_KEY__ 对象）。
      const text = node as string;
      if (text.indexOf('__CHANNEL__:') === 0) {
        const id = Number(text.substring('__CHANNEL__:'.length));
        if (!Number.isNaN(id)) {
          out.push(id);
        }
      }
      return;
    }
    if (typeof node !== 'object') {
      return;
    }
    const rec = node as Record<string, Object | null>;
    const token = rec['__TAURI_TO_IPC_KEY__'];
    if (typeof token === 'number') {
      out.push(token as number);
    }
    const keys = Object.keys(rec);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] === '__TAURI_TO_IPC_KEY__') {
        continue;
      }
      JsBridge.collectChannels(rec[keys[i]], out);
    }
  }

  /**
   * 向 Channel 推一帧（Tauri v2 信封）：
   *   中间帧 {"index":n,"message":...}；结束帧 {"index":n,"end":true}
   */
  channelSend(callbackId: number, index: number, messageJson: string, end: boolean): void {
    const frame = end
      ? `{"index":${index},"end":true}`
      : `{"index":${index},"message":${messageJson}}`;
    this.runJs(`window.__cgChannel && window.__cgChannel(${callbackId}, ${JSON.stringify(frame)});`);
  }

  runJs(script: string): void {
    const ctrl = this.controller;
    if (ctrl === null) {
      Log.w('Bridge', 'controller not attached, drop script');
      return;
    }
    try {
      ctrl.runJavaScript(script).catch((e: Object) => {
        Log.w('Bridge', `runJavaScript failed: ${Log.err(e)}`);
      });
    } catch (e) {
      Log.w('Bridge', `runJavaScript throw: ${Log.err(e as Object)}`);
    }
  }
}
