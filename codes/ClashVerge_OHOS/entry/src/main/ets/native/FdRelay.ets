import clashOhos from 'libclash_ohos.so';

import { Log } from '../common/Logger';

/**
 * 跨进程 tunfd 传递（native: fd_relay.cpp，Unix socket + `SCM_RIGHTS`）。
 *
 * 分工：
 *   - VPN 扩展进程：`createVpnConnection().create()` 拿到 tunfd 后 `publish()`；
 *   - UI 进程：`receive()` 收回 fd，交给常驻内核 `clash_core_start_tun(fd, …)`。
 *
 * ArkTS 的 `@ohos.net.socket` 没有 `sendmsg`/`SCM_RIGHTS`，所以这层必须走 native
 * （ClashBox 也是同样的做法，只是它把实现藏在 libflclash.so 里）。
 */
export class FdRelay {
  /** 扩展进程侧：后台等一次连接并把 fd 发出去。0 = 已开始等待 */
  static publish(socketPath: string, fd: number, timeoutMs: number): number {
    try {
      return clashOhos.relayPublish(socketPath, fd, timeoutMs);
    } catch (e) {
      Log.e('FdRelay', `publish throw: ${Log.err(e as Object)}`);
      return -1;
    }
  }

  /** UI 进程侧：连接并收 fd；>=0 为 fd，-2 连接失败 / -3 收超时 / -4 无控制数据 */
  static receive(socketPath: string, timeoutMs: number): number {
    try {
      return clashOhos.relayReceive(socketPath, timeoutMs);
    } catch (e) {
      Log.e('FdRelay', `receive throw: ${Log.err(e as Object)}`);
      return -1;
    }
  }
}
