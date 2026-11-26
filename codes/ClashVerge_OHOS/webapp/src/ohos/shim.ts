/**
 * HarmonyOS Tauri 兼容层（必须最先加载）
 *
 * 上游 Clash Verge Rev 的全部业务逻辑都跑在 WebView 里，只通过 Tauri 的 IPC
 * 与 Rust 后端交互。这里把 IPC 的入口 `__TAURI_INTERNALS__.invoke` 完整接管：
 *
 *   前端 invoke(cmd, args)
 *     ├─ 纯前端命令（event / app / path / window 元信息）→ 本地实现
 *     └─ 其余 → clashBridge.invoke(cmd, args, replyId) → ArkTS 后端
 *
 * 这样上游 4 万多行 React 代码一行都不用改语义。
 */

type AnyFn = (...args: any[]) => any;

interface PendingCall {
  resolve: AnyFn;
  reject: AnyFn;
}

interface BridgeObject {
  invoke(cmd: string, argsJson: string, replyId: string): void;
  log(level: string, message: string): void;
}

const pending = new Map<string, PendingCall>();
const callbacks: Record<string, AnyFn> = {};
const eventListeners = new Map<number, { event: string; callbackId: number }>();

let nextCallbackId = 1;

/**
 * Tauri 的 event 插件内部对象。
 *
 * `@tauri-apps/api/event` 的 `_unlisten()` 第一句就是
 *   window.__TAURI_EVENT_PLUGIN_INTERNALS__.unregisterListener(event, eventId)
 * 少这个对象，每次 unlisten 都会抛
 *   TypeError: Cannot read properties of undefined (reading 'unregisterListener')
 * 实机日志里刷了 14 次，事件回调因此泄漏。
 */
;(window as any).__TAURI_EVENT_PLUGIN_INTERNALS__ = {
  unregisterListener: (event: string, eventId: number): void => {
    const key = Number(eventId)
    const record = eventListeners.get(key)
    if (record) {
      // 同步清掉 JS 侧回调，避免 closed-over 引用常驻
      delete callbacks[String(record.callbackId)]
      eventListeners.delete(key)
    }
  },
  emit: (event: string, payload?: unknown): void => {
    dispatchEvent(event, payload)
  },
}
let nextReplyId = 1;
let nextEventId = 1;

const APP_NAME = 'Clash Verge';
const APP_VERSION = '2.6.0';
const APP_IDENTIFIER = 'com.lyldeer.clashverge';

function bridge(): BridgeObject | undefined {
  return (window as any).clashBridge as BridgeObject | undefined;
}

function transformCallback(callback?: AnyFn, once = false): number {
  const id = nextCallbackId++;
  callbacks[String(id)] = (data: any) => {
    if (once) {
      delete callbacks[String(id)];
    }
    callback?.(data);
  };
  return id;
}

function dispatchEvent(event: string, payload: unknown): void {
  const snapshot = Array.from(eventListeners.entries());
  for (const [id, rec] of snapshot) {
    if (rec.event !== event) {
      continue;
    }
    const cb = callbacks[String(rec.callbackId)];
    if (typeof cb === 'function') {
      try {
        cb({ event, id, payload });
      } catch (e) {
        console.error('[shim] event handler failed', e);
      }
    }
  }
}

const windowDefaults: Record<string, unknown> = {
  'plugin:window|is_maximized': false,
  'plugin:window|is_fullscreen': false,
  'plugin:window|is_focused': true,
  'plugin:window|is_visible': true,
  'plugin:window|is_decorated': true,
  'plugin:window|is_resizable': true,
  'plugin:window|is_closable': true,
  'plugin:window|is_minimizable': true,
  'plugin:window|is_maximizable': true,
  'plugin:window|is_always_on_top': false,
  'plugin:window|scale_factor': 1,
  'plugin:window|inner_position': { x: 0, y: 0 },
  'plugin:window|outer_position': { x: 0, y: 0 },
  'plugin:window|title': APP_NAME,
};

function localHandler(cmd: string, args: Record<string, any>): { handled: boolean; value?: unknown } {
  if (cmd === 'plugin:event|listen') {
    const id = nextEventId++;
    eventListeners.set(id, { event: String(args.event), callbackId: Number(args.handler) });
    return { handled: true, value: id };
  }
  if (cmd === 'plugin:event|unlisten') {
    eventListeners.delete(Number(args.eventId));
    return { handled: true, value: null };
  }
  if (cmd === 'plugin:event|emit' || cmd === 'plugin:event|emit_to') {
    dispatchEvent(String(args.event), args.payload);
    return { handled: true, value: null };
  }
  if (cmd === 'plugin:app|name') {
    return { handled: true, value: APP_NAME };
  }
  if (cmd === 'plugin:app|version' || cmd === 'plugin:app|tauri_version') {
    return { handled: true, value: APP_VERSION };
  }
  if (cmd === 'plugin:app|identifier') {
    return { handled: true, value: APP_IDENTIFIER };
  }
  if (cmd === 'plugin:app|bundle_type') {
    return { handled: true, value: 'app' };
  }
  if (cmd === 'plugin:app|supports_multiple_windows') {
    return { handled: true, value: true };
  }
  if (cmd === 'plugin:path|join') {
    const paths = (args.paths as string[]) ?? [];
    return { handled: true, value: paths.join('/').replace(/\/+/gu, '/') };
  }
  if (cmd === 'plugin:path|separator') {
    return { handled: true, value: '/' };
  }
  if (cmd === 'plugin:path|delimiter') {
    return { handled: true, value: ':' };
  }
  if (cmd.startsWith('plugin:window|')) {
    if (cmd in windowDefaults) {
      const fixed = windowDefaults[cmd];
      if (cmd === 'plugin:window|inner_size' || cmd === 'plugin:window|outer_size') {
        return { handled: true, value: { width: window.innerWidth, height: window.innerHeight } };
      }
      return { handled: true, value: fixed };
    }
    if (cmd === 'plugin:window|inner_size' || cmd === 'plugin:window|outer_size') {
      return { handled: true, value: { width: window.innerWidth, height: window.innerHeight } };
    }
    if (cmd === 'plugin:window|theme') {
      return { handled: true, value: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light' };
    }
    // 其余窗口动作（minimize / toggleMaximize / setTheme ...）转给原生，失败也不阻塞 UI
    return { handled: false };
  }
  if (cmd.startsWith('plugin:webview|')) {
    if (cmd === 'plugin:webview|webview_position' || cmd === 'plugin:webview|webview_size') {
      return { handled: true, value: cmd.endsWith('position') ? { x: 0, y: 0 } : { width: window.innerWidth, height: window.innerHeight } };
    }
    return { handled: false };
  }
  return { handled: false };
}

async function invoke<T>(cmd: string, args: Record<string, any> = {}, _options?: unknown): Promise<T> {
  const local = localHandler(cmd, args);
  if (local.handled) {
    return local.value as T;
  }
  const bridgeObject = bridge();
  if (!bridgeObject) {
    throw new Error(`[shim] native bridge unavailable (cmd=${cmd})`);
  }
  const replyId = `r${nextReplyId++}`;
  return await new Promise<T>((resolve, reject) => {
    pending.set(replyId, { resolve: resolve as AnyFn, reject: reject as AnyFn });
    try {
      bridgeObject.invoke(cmd, JSON.stringify(args ?? {}), replyId);
    } catch (e) {
      pending.delete(replyId);
      reject(e as Error);
    }
  });
}

function convertFileSrc(filePath: string, _protocol = 'asset'): string {
  // 本地静态服务同时提供 /__asset 路由，直接映射到应用沙箱内的绝对路径
  const base = (window as any).__CG_ORIGIN__ ?? `${location.protocol}//${location.host}`;
  return `${base}/__asset${encodeURI(filePath.startsWith('/') ? filePath : `/${filePath}`)}`;
}

/**
 * 注意：上游自带的 `Channel`（`@tauri-apps/api/core`）不需要我们重写，
 * 它的 `toJSON()` 会序列化成 `{ __TAURI_TO_IPC_KEY__: <callbackId> }`，
 * ArkTS 侧只要识别该标记，就能通过下面的 `__cgChannel(id, payload)` 往回灌。
 *
 * 消息信封格式（Tauri v2 约定，ArkTS 侧必须照做）：
 *   中间帧：{ index: <递增序号>, message: <数据> }
 *   结束帧：{ index: <序号>, end: true }
 */
function setupInternals(): void {
  const internals = {
    invoke,
    transformCallback,
    convertFileSrc,
    callbacks,
    // Channel 结束时 Channel#cleanupCallback 会调用它，缺了会抛 TypeError
    unregisterCallback: (id: number): void => {
      delete callbacks[String(id)];
    },
    metadata: {
      currentWindow: { label: 'main' },
      currentWebview: { windowLabel: 'main', label: 'main' },
    },
  };
  (window as any).__TAURI_INTERNALS__ = internals;

  // ArkTS 侧推 Channel 帧：直接喂给 @tauri-apps/api 注册的回调
  // frameJson 形如 {"index":0,"message":{...}} 或 {"index":1,"end":true}
  (window as any).__cgChannel = (id: number, frameJson: string): void => {
    const handler = callbacks[String(id)];
    if (typeof handler !== 'function') {
      return;
    }
    try {
      handler(JSON.parse(frameJson));
    } catch (e) {
      console.error('[shim] bad channel frame', e);
    }
  };

  // ArkTS 侧回包：payload 已经是反序列化后的值（ArkTS 端不再二次 stringify）
  (window as any).__cgBridgeReply = (replyId: string, ok: boolean, payload: unknown): void => {
    const entry = pending.get(replyId);
    if (!entry) {
      return;
    }
    pending.delete(replyId);
    if (ok) {
      entry.resolve(payload);
    } else {
      entry.reject(new Error(typeof payload === 'string' ? payload : JSON.stringify(payload)));
    }
  };

  (window as any).__cgEmit = (event: string, payload: unknown): void => {
    dispatchEvent(event, payload);
  };

}

function forwardConsole(): void {
  const levels: Array<'log' | 'info' | 'warn' | 'error' | 'debug'> = ['log', 'info', 'warn', 'error', 'debug'];
  for (const level of levels) {
    const original = console[level].bind(console);
    console[level] = (...args: any[]) => {
      original(...args);
      try {
        const text = args
          .map((item) => {
            if (item instanceof Error) {
              return `${item.message}\n${item.stack ?? ''}`;
            }
            if (typeof item === 'object') {
              try {
                return JSON.stringify(item);
              } catch (e) {
                return String(item);
              }
            }
            return String(item);
          })
          .join(' ');
        bridge()?.log(level === 'debug' ? 'info' : level, text.slice(0, 4000));
      } catch (e) {
        // 日志转发失败不影响业务
      }
    };
  }

  window.addEventListener('error', (event) => {
    bridge()?.log('error', `[uncaught] ${event.message} @ ${event.filename}:${event.lineno}`);
  });
  window.addEventListener('unhandledrejection', (event) => {
    bridge()?.log('error', `[unhandled-rejection] ${String(event.reason)}`);
  });
}

setupInternals();
forwardConsole();
(window as any).__CG_ORIGIN__ = `${location.protocol}//${location.host}`;

/** 托盘右键/点击菜单 → 主窗口内路由（HashRouter） */
;(window as any).__cgTrayNavigate = (path: string): void => {
  if (typeof path !== 'string' || path.length === 0) return
  window.location.hash = `#${path.startsWith('/') ? path : `/${path}`}`
}

console.info('[shim] HarmonyOS tauri bridge ready');

/**
 * 能力门禁：鸿蒙给不了的系统级功能统一置灰。
 *
 * 做法基于上游自带的 `data-setting-target` 锚点（settings 页每个开关都有），
 * 只加属性 + 注入一条 CSS，不改任何 React 组件——上游升级时零冲突。
 * 依据（HANDOFF / COLLAB §3.5、R11）：系统代理、开机自启、静默启动、全局热键、
 * 服务模式、自动更新、轻量模式、启动脚本、系统标题栏，鸿蒙三方应用均无对应 API。
 */
const HIDDEN_HINTS: RegExp[] = [
  // 鸿蒙三方应用没有系统代理 API（只有应用级 connection.setAppHttpProxy）
  /systemProxy/iu,
  /sysproxy/iu,
  // 启动脚本：上游是 exec 一个 .sh/.bat，鸿蒙沙箱里没有对应能力，直接隐藏
  /startupScript/iu,
  // DevTools：WebView 调试端口未开放
  /openDevTools/iu,
];

// 仍然保留但置灰 + 标注的（点击会提示）
const UNSUPPORTED_HINTS: RegExp[] = [
  /service-uninstall/iu,
  /preferSystemTitlebar/iu,
];

// 说明：checkUpdates / clashCore / liteModeSettings 之前被误标成"暂不支持"，
// 现在都已适配（检查更新 → GitHub Release 页；内核对话框 → 只保留重启；
// 轻量模式 → 最小化到 Dock + 自动进入），不要再置灰。

function installCapabilityGate(): void {
  const style = document.createElement('style');
  style.textContent = [
    '[data-ohos-hidden="1"]{display:none !important}',
    '[data-ohos-unsupported="1"]{opacity:.45;pointer-events:none;filter:grayscale(1)}',
    '[data-ohos-unsupported="1"]::after{content:"鸿蒙暂不支持";display:inline-block;margin-left:8px;',
    'font-size:11px;line-height:1;padding:2px 6px;border-radius:6px;background:rgba(127,127,127,.18);',
    'color:currentColor;vertical-align:middle}',
  ].join('');
  document.head.appendChild(style);

  const mark = (): void => {
    const nodes = document.querySelectorAll('[data-setting-target]');
    for (const node of Array.from(nodes)) {
      const target = node.getAttribute('data-setting-target') ?? '';
      const hidden = HIDDEN_HINTS.some((re) => re.test(target));
      if (hidden) {
        if (node.getAttribute('data-ohos-hidden') !== '1') {
          node.setAttribute('data-ohos-hidden', '1');
        }
        node.removeAttribute('data-ohos-unsupported');
        continue;
      }
      if (node.getAttribute('data-ohos-hidden') === '1') {
        node.removeAttribute('data-ohos-hidden');
      }
      const unsupported = UNSUPPORTED_HINTS.some((re) => re.test(target));
      if (unsupported) {
        if (node.getAttribute('data-ohos-unsupported') !== '1') {
          node.setAttribute('data-ohos-unsupported', '1');
        }
      } else if (node.getAttribute('data-ohos-unsupported') === '1') {
        node.removeAttribute('data-ohos-unsupported');
      }
    }
  };

  mark();
  let scheduled = false;
  const observer = new MutationObserver(() => {
    if (scheduled) {
      return;
    }
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      mark();
    });
  });
  observer.observe(document.body, { childList: true, subtree: true });
  console.info('[shim] capability gate installed');
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', installCapabilityGate);
} else {
  installCapabilityGate();
}

/**
 * 全局错误兜底：实机没有 devtools 时，这是唯一能看到 JS 为什么没渲染的手段。
 * 通过 ArkTS 的 `clashBridge.log` 转进 hilog（`WebConsole` 标签）。
 */
function forward(message: string, level: 'info' | 'error' = 'error'): void {
  try {
    const bridge = (window as any).clashBridge
    if (bridge && typeof bridge.log === 'function') {
      bridge.log(level, message)
      return
    }
  } catch {
    // 桥还没注入时退回 console
  }
  console.error(message)
}

window.addEventListener('error', (e) => {
  forward(`[js-error] ${e.message} @ ${e.filename}:${e.lineno}`)
})
window.addEventListener('unhandledrejection', (e) => {
  const reason = (e as PromiseRejectionEvent).reason
  forward(`[js-rejection] ${reason instanceof Error ? `${reason.message}\n${reason.stack ?? ''}` : String(reason)}`)
})
forward('[shim] entry evaluated', 'info')

/**
 * 沉浸式标题栏：原生标题栏已由 EntryAbility 隐藏，但官方三键仍在右上角。
 * 页面 header 右侧留出 150px，避免轻量模式/使用手册/设置等图标被三键压住。
 */
function installTitlebarAvoidance(): void {
  if (!document.head) return
  const style = document.createElement('style')
  style.textContent =
    'header[data-tauri-drag-region="true"]{padding-right:150px !important}'
  document.head.appendChild(style)
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', installTitlebarAvoidance)
} else {
  installTitlebarAvoidance()
}
