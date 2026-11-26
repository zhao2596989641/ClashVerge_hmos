import clashOhos from 'libclash_ohos.so';

import { Log } from '../common/Logger';

/**
 * mihomo 内核（libclash_core.so）的 ArkTS 门面。
 *
 * 只允许 VpnExtensionAbility 进程调用：内核在扩展进程里常驻，
 * 主进程通过 REST 控制它，绝不在 UI 进程里初始化 Go runtime。
 */
export class ClashCore {
  private static inited: boolean = false;

  static ping(): string {
    return clashOhos.ping();
  }

  static available(): boolean {
    try {
      return clashOhos.coreAvailable();
    } catch (e) {
      return false;
    }
  }

  static lastError(): string {
    try {
      return clashOhos.lastError();
    } catch (e) {
      return Log.err(e as Object);
    }
  }

  static version(): string {
    try {
      return clashOhos.coreVersion();
    } catch (e) {
      return `napi-error:${Log.err(e as Object)}`;
    }
  }

  static init(home: string, version: string, sdk: number): void {
    if (ClashCore.inited) {
      return;
    }
    // 前后各留一条日志：NAPI 调用是同步阻塞的，一旦 Go 侧卡住，hilog 里就只有 "enter" 没有 "done"，
    // 这样能一眼区分「卡在 NAPI/Go」和「卡在我们自己的 ArkTS 代码」
    Log.i('Core', `init enter home=${home} version=${version} sdk=${sdk}`);
    clashOhos.coreInit(home, version, sdk);
    ClashCore.inited = true;
    Log.i('Core', `init done home=${home} version=${version}`);
  }

  /**
   * 异步初始化：立刻返回，dlopen + 等 Go runtime 都在 native 线程里做。
   *
   * 为什么不再用同步的 `init()`：真机日志（2026-11-15 10:53）显示 `dlopen` 会在**另一个线程**
   * 启动 Go runtime，并在 ~515ms 后才返回；调用线程（原来是 UI 线程）随后与它争 musl 的
   * loader/TLS 锁，整个进程所有线程同时静默，界面停在"正在加载界面"。
   * 现在只在 `EntryAbility.onCreate` 里踢一脚，UI 线程直接返回。
   */
  static initAsync(home: string, version: string, sdk: number): void {
    try {
      Log.i('Core', `initAsync enter home=${home} version=${version} sdk=${sdk}`);
      clashOhos.coreInitAsync(home, version, sdk);
      Log.i('Core', 'initAsync returned (native thread keeps working)');
    } catch (e) {
      Log.e('Core', `initAsync throw: ${Log.err(e as Object)}`);
    }
  }

  /** 0=未开始 1=进行中 2=成功 3=失败 */
  static initState(): number {
    try {
      return clashOhos.coreInitState();
    } catch (e) {
      return 3;
    }
  }

  /** 同步等初始化（仅轮询状态，不会重复 dlopen）；返回 2=成功 3=失败 1=超时 */
  static waitReadySync(timeoutMs: number): number {
    try {
      return clashOhos.coreWaitReadySync(timeoutMs);
    } catch (e) {
      Log.e('Core', `waitReadySync throw: ${Log.err(e as Object)}`);
      return 3;
    }
  }

  static loadConfig(path: string): string {
    try {
      return clashOhos.loadConfig(path);
    } catch (e) {
      return `napi-throw:${Log.err(e as Object)}`;
    }
  }

  static startTun(fd: number, stack: string, gateway: string, portal: string, dns: string): number {
    try {
      return clashOhos.startTun(fd, stack, gateway, portal, dns);
    } catch (e) {
      Log.e('Core', `startTun throw: ${Log.err(e as Object)}`);
      return -1;
    }
  }

  static stopTun(): void {
    try {
      clashOhos.stopTun();
    } catch (e) {
      Log.w('Core', `stopTun throw: ${Log.err(e as Object)}`);
    }
  }

  static shutdown(): void {
    try {
      clashOhos.shutdown();
    } catch (e) {
      Log.w('Core', `shutdown throw: ${Log.err(e as Object)}`);
    }
    // 允许下次 init 重新设置 homeDir（扩展进程可能被复用）
    ClashCore.inited = false;
  }

  static setProtectHook(cb: (fd: number) => void): void {
    try {
      clashOhos.setProtectHook(cb);
    } catch (e) {
      Log.w('Core', `setProtectHook throw: ${Log.err(e as Object)}`);
    }
  }

  static protectDone(): void {
    try {
      clashOhos.protectDone();
    } catch (e) {
      // ignore
    }
  }

  static trafficJson(): string {
    try {
      return clashOhos.traffic();
    } catch (e) {
      return '{"up":0,"down":0}';
    }
  }
}
