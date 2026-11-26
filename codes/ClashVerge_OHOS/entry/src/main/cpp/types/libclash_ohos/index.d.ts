export const ping: () => string;
export const coreVersion: () => string;
export const coreAvailable: () => boolean;
export const lastError: () => string;
export const coreInit: (home: string, version: string, sdk: number) => void;
export const loadConfig: (path: string) => string;
export const startTun: (fd: number, stack: string, gateway: string, portal: string, dns: string) => number;
export const stopTun: () => void;
export const shutdown: () => void;
export const setProtectHook: (cb: (fd: number) => void) => void;
export const protectDone: () => void;
export const traffic: () => string;

/** 扩展进程侧：后台等一次连接，把 tunfd 通过 SCM_RIGHTS 发给 UI 进程 */
export const relayPublish: (socketPath: string, fd: number, timeoutMs: number) => number;
/** UI 进程侧：连接扩展并把 tunfd 收回来；返回 >=0 为 fd，负数失败 */
export const relayReceive: (socketPath: string, timeoutMs: number) => number;

/** 异步初始化内核（dlopen + 等 Go runtime 完成都在独立 native 线程） */
export const coreInitAsync: (home: string, version: string, sdk: number) => void;
/** 0=未开始 1=进行中 2=成功 3=失败 */
export const coreInitState: () => number;
/** 同步等初始化完成（仅轮询状态），返回 2=成功 3=失败 1=超时 */
export const coreWaitReadySync: (timeoutMs: number) => number;
