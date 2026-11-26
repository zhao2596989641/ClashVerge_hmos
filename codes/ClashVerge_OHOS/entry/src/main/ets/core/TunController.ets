import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';

import { AppCtx } from '../common/AppCtx';
import { BUNDLE_NAME, TUN_DNS, TUN_RELAY_SOCKET, VPN_ABILITY_NAME } from '../common/Constants';
import { Log } from '../common/Logger';
import { CoreHost } from './CoreHost';
import { RuntimeStatus, RuntimeStatusStore } from './RuntimeStatus';

/**
 * 主进程侧的 TUN 启停器（内核常驻，见 `core/CoreHost.ets`）。
 *
 * 流程：ensure core（**独立子进程**，控制器 + mixed-port 已在跑）
 *   → startVpnExtensionAbility（扩展只建隧道，把 tunfd SCM_RIGHTS 递出）
 *   → 写 tun.json 通知子进程；**子是子进程自己收 fd**（fd 号跨进程无意义）
 *   → 轮询 status.json 等 tun=true
 *
 * 官方约束（《连接 VPN》服务生命周期）：调用 startVpnExtensionAbility 的应用进程退出时，
 * 系统会主动断开 VPN —— 所以长时任务保活仍然必需（见 BackgroundKeeper）。
 */
export class TunController {
  private static running: boolean = false;
  static isRunning(): boolean {
    return TunController.running;
  }

  private static want(profilePath: string, stack: string): Want {
    const parameters: Record<string, Object> = {};
    parameters['profilePath'] = profilePath;
    parameters['tunStack'] = stack;
    parameters['dns'] = TUN_DNS;
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: parameters,
    };
    return want;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  static async start(profilePath: string, stack: string, context: common.UIAbilityContext): Promise<string> {
    if (TunController.running) {
      return '';
    }
    // 1) 内核子进程先就位（未开 TUN 时也应当已经起来，这里是兜底）
    const coreError = await CoreHost.ensureStarted(profilePath);
    if (coreError.length > 0) {
      RuntimeStatusStore.reset(`core: ${coreError}`);
      return coreError;
    }
    RuntimeStatusStore.reset('starting');

    // 2) 拉起扩展（系统同一时刻只允许一个 VPN，失败先 stop 再重试一次）
    let error = '';
    try {
      await vpnExtension.startVpnExtensionAbility(TunController.want(profilePath, stack));
    } catch (e) {
      error = Log.err(e as Object);
      Log.w('Tun', `start failed (${error}), retry after stop`);
      try {
        await vpnExtension.stopVpnExtensionAbility(TunController.want('', ''));
      } catch (e2) {
        Log.w('Tun', `stop before retry failed: ${Log.err(e2 as Object)}`);
      }
      try {
        await vpnExtension.startVpnExtensionAbility(TunController.want(profilePath, stack));
        error = '';
      } catch (e3) {
        error = Log.err(e3 as Object);
      }
    }
    if (error.length > 0) {
      Log.e('Tun', `start failed: ${error}`);
      RuntimeStatusStore.reset(`start failed: ${error}`);
      return error;
    }

    // 3) 把「收 fd」交给内核子进程：fd 号跨进程没有意义，必须由要使用它的进程
    //    自己用 SCM_RIGHTS 收（子进程内 Go 的 recvFd 实现，见 bridge/child.go）。
    const socketPath = AppCtx.path(TUN_RELAY_SOCKET);
    const tunError = await CoreHost.startTun(socketPath, stack);
    if (tunError.length > 0) {
      Log.e('Tun', tunError);
      RuntimeStatusStore.reset(tunError);
      try {
        await vpnExtension.stopVpnExtensionAbility(TunController.want('', ''));
      } catch (e) {
        Log.w('Tun', `stop after tun failure: ${Log.err(e as Object)}`);
      }
      return tunError;
    }

    TunController.running = true;
    Log.i('Tun', `tun up, profile=${profilePath} stack=${stack}`);
    return '';
  }

  static async stop(): Promise<string> {
    await CoreHost.stopTun();
    // 不能因为本进程的 running=false 就跳过停扩展：应用重启后（内核/扩展仍在跑，
    // 但 UI 的静态状态已丢）用户关 TUN，扩展会继续挂着 VPN 但内核已停 → 全断网。
    try {
      await vpnExtension.stopVpnExtensionAbility(TunController.want('', ''));
      Log.i('Tun', 'vpn extension stopped');
    } catch (e) {
      // 扩展本来就没起来时 stop 会抛错，这里不是失败
      Log.w('Tun', `stop vpn extension: ${Log.err(e as Object)}`);
    }
    TunController.running = false;
    return '';
  }

  /** 以扩展进程写的状态文件为准（它才是隧道真正建起来的判据） */
  static status(): RuntimeStatus {
    return RuntimeStatusStore.read();
  }

  /**
   * 是否真的连着：状态文件说连着 **且** 心跳没过期（扩展每 1s 刷一次 updatedAt）。
   * 扩展被系统杀掉后主进程不能一直以为"已连接"。
   */
  static connected(): boolean {
    const status = RuntimeStatusStore.read();
    if (!status.connected) {
      return false;
    }
    if (status.updatedAt <= 0) {
      return false;
    }
    return Date.now() - status.updatedAt < 20000;
  }
}
