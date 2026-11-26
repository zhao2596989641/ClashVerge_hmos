import { Want } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';

import { AppCtx } from '../common/AppCtx';
import {
  BUNDLE_NAME,
  CONTROLLER_PORT,
  TUN_ADDRESS,
  TUN_DNS,
  TUN_MTU,
  TUN_PREFIX,
  TUN_RELAY_SOCKET
} from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';
import { RuntimeStatus, RuntimeStatusStore } from '../core/RuntimeStatus';
import { FdRelay } from '../native/FdRelay';

/**
 * VPN 扩展：**只负责建隧道并把 tunfd 交给 UI 进程**，不加载内核。
 *
 * 依据（对照参考实现）：
 *   - 上游 Windows/mac 的内核是常驻进程，TUN 只是能力开关；
 *   - ClashBox（鸿蒙）把内核放 UI 进程，扩展只有 47 行，靠 `SocketStubService` 递 fd；
 *   - 本工程用 native `fd_relay.cpp`（Unix socket + SCM_RIGHTS）完成同一件事。
 *
 * 内核常驻在独立 native 子进程（见 `core/CoreHost.ets`），所以这里**不要**再碰 ClashCore ——
 * 同一份配置在两个进程各起一个内核会抢 9090/7890，而且节点选择会作用到错误的实例上。
 */
export default class ClashVpnExtensionAbility extends VpnExtensionAbility {
  private conn: vpnExtension.VpnConnection | null = null;
  private tunFd: number = -1;
  private heartbeatTimer: number = -1;
  private ready: boolean = false;
  private profilePath: string = '';

  onCreate(want: Want): void {
    // pid 是判定「扩展是否独立进程」的唯一硬证据（D1 的前提）：
    // 与 UI 侧 `[CoreHost] ui pid=` 比对，相同 = 同进程（那 fd 传递其实没必要，但无害），
    // 不同 = 独立进程（必须靠 SCM_RIGHTS relay）。
    Log.i('VpnAbility', `onCreate pid=${process.pid}`);
    // 扩展是独立进程，必须自己初始化沙箱路径（否则会往 "/verge/..." 写）
    AppCtx.init(this.context.filesDir, this.context.cacheDir);
    this.bootstrap(want);
  }

  onDestroy(): void {
    Log.i('VpnAbility', 'onDestroy');
    if (this.heartbeatTimer >= 0) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
    const conn = this.conn;
    this.conn = null;
    if (conn !== null) {
      conn.destroy().catch((e: Object) => {
        Log.w('VpnAbility', `destroy failed: ${Log.err(e)}`);
      });
    }
    const status = new RuntimeStatus();
    status.connected = false;
    status.lastError = 'vpn extension destroyed';
    status.updatedAt = Date.now();
    RuntimeStatusStore.write(status);
  }

  private async bootstrap(want: Want): Promise<void> {
    const params = want.parameters ?? {};
    const dns = this.paramString(params, 'dns', TUN_DNS);
    this.profilePath = this.paramString(params, 'profilePath', '');

    try {
      const conn = vpnExtension.createVpnConnection(this.context);
      this.conn = conn;

      try {
        await conn.protectProcessNet();
        Log.i('VpnAbility', 'protectProcessNet ok');
      } catch (e) {
        Log.w('VpnAbility', `protectProcessNet skipped: ${Log.err(e as Object)}`);
      }

      const config: vpnExtension.VpnConfig = {
        addresses: [
          {
            address: { address: TUN_ADDRESS, family: 1 },
            prefixLength: TUN_PREFIX,
          },
        ],
        // 显式给默认路由：官方文档只说"虚拟网卡的路由信息"，没有承诺"不配 = 全量"
        routes: [
          {
            interface: 'vpn-tun',
            destination: {
              address: { address: '0.0.0.0', family: 1 },
              prefixLength: 0,
            },
            gateway: { address: TUN_ADDRESS, family: 1 },
            hasGateway: false,
            isDefaultRoute: true,
          },
        ],
        mtu: TUN_MTU,
        dnsAddresses: [dns],
        isIPv4Accepted: true,
        isIPv6Accepted: false,
        // ⚠️ 内核子进程与本应用同 uid：必须把本应用排除在隧道外，否则内核自己的出站会被
        // 自己的 tun 再抓一次（无限回环）。protectProcessNet 只保护扩展进程，对 UI/子进程无效。
        // 官方约束：trustedApplications 与 blockedApplications 不能同时配置。
        blockedApplications: [BUNDLE_NAME],
      };
      this.tunFd = await conn.create(config);
      Log.i('VpnAbility', `tunFd=${this.tunFd}`);
      if (this.tunFd < 0) {
        this.fail('invalid tun fd');
        return;
      }

      // 交给 UI 进程：先确保 runtime 目录存在，再由后台线程等服务端连接
      FsUtil.ensureDir(AppCtx.path('verge/runtime'));
      const socketPath = AppCtx.path(TUN_RELAY_SOCKET);
      const rc = FdRelay.publish(socketPath, this.tunFd, 20000);
      Log.i('VpnAbility', `publish fd=${this.tunFd} rc=${rc} sock=${socketPath}`);
      if (rc !== 0) {
        this.fail(`fd relay publish failed: rc=${rc}`);
        return;
      }

      this.ready = true;
      const status = new RuntimeStatus();
      status.connected = true;
      status.tunFd = this.tunFd;
      status.profilePath = this.profilePath;
      status.stack = this.paramString(params, 'tunStack', 'mips');
      status.controller = `http://127.0.0.1:${CONTROLLER_PORT}`;
      status.updatedAt = Date.now();
      RuntimeStatusStore.write(status);
      this.startHeartbeat();
    } catch (e) {
      this.fail(Log.err(e as Object));
    }
  }

  /** 心跳：UI 侧用 updatedAt 判断扩展是否还活着（超过 20s 视为已断） */
  private startHeartbeat(): void {
    if (this.heartbeatTimer >= 0) {
      return;
    }
    this.heartbeatTimer = setInterval(() => {
      if (!this.ready) {
        return;
      }
      const status = RuntimeStatusStore.read();
      status.connected = true;
      status.updatedAt = Date.now();
      status.tunFd = this.tunFd;
      RuntimeStatusStore.write(status);
    }, 5000);
  }

  private fail(message: string): void {
    Log.e('VpnAbility', `fail: ${message}`);
    this.ready = false;
    const status = new RuntimeStatus();
    status.connected = false;
    status.tunFd = this.tunFd;
    status.lastError = message;
    status.updatedAt = Date.now();
    RuntimeStatusStore.write(status);
  }

  private paramString(params: Record<string, Object>, key: string, fallback: string): string {
    const raw = params[key];
    if (typeof raw === 'string') {
      return raw as string;
    }
    return fallback;
  }
}
