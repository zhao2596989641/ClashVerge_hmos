import { AppCtx } from '../common/AppCtx';
import { DIR_RUNTIME } from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';

/** VPN 扩展进程写、主进程读的运行时状态（跨进程文件桥） */
export class RuntimeStatus {
  connected: boolean = false;
  tunFd: number = -1;
  lastError: string = '';
  coreVersion: string = '';
  profilePath: string = '';
  controller: string = '';
  stack: string = '';
  updatedAt: number = 0;
}

export class RuntimeStatusStore {
  /**
   * ⚠️ 必须与内核子进程的 `status.json` 分开：
   * 子进程每 500ms 覆盖一次 `status.json`（{pid,phase,ready,tun,error,config}），
   * 扩展心跳也写自己的 {connected,tunFd,...} —— 同一路径会互相覆盖，
   * 导致 UI 永远读不到 connected=true（代理页空、TUN 被判失败）。
   */
  static path(): string {
    return AppCtx.path(`${DIR_RUNTIME}/vpn-status.json`);
  }

  static write(status: RuntimeStatus): void {
    try {
      const obj: Record<string, Object | null> = {};
      obj['connected'] = status.connected;
      obj['tunFd'] = status.tunFd;
      obj['lastError'] = status.lastError;
      obj['coreVersion'] = status.coreVersion;
      obj['profilePath'] = status.profilePath;
      obj['controller'] = status.controller;
      obj['stack'] = status.stack;
      obj['updatedAt'] = status.updatedAt;
      FsUtil.writeText(RuntimeStatusStore.path(), JSON.stringify(obj));
    } catch (e) {
      Log.w('Runtime', `write status failed: ${Log.err(e as Object)}`);
    }
  }

  static read(): RuntimeStatus {
    const status = new RuntimeStatus();
    const raw = FsUtil.readText(RuntimeStatusStore.path());
    if (raw.length === 0) {
      return status;
    }
    try {
      const obj = JSON.parse(raw) as Record<string, Object | null>;
      status.connected = obj['connected'] === true;
      const fd = obj['tunFd'];
      status.tunFd = typeof fd === 'number' ? fd as number : -1;
      const err = obj['lastError'];
      status.lastError = typeof err === 'string' ? err as string : '';
      const ver = obj['coreVersion'];
      status.coreVersion = typeof ver === 'string' ? ver as string : '';
      const profile = obj['profilePath'];
      status.profilePath = typeof profile === 'string' ? profile as string : '';
      const ctrl = obj['controller'];
      status.controller = typeof ctrl === 'string' ? ctrl as string : '';
      const stack = obj['stack'];
      status.stack = typeof stack === 'string' ? stack as string : '';
      const ts = obj['updatedAt'];
      status.updatedAt = typeof ts === 'number' ? ts as number : 0;
    } catch (e) {
      Log.w('Runtime', `parse status failed: ${Log.err(e as Object)}`);
    }
    return status;
  }

  static reset(reason: string): void {
    const status = new RuntimeStatus();
    status.lastError = reason;
    status.updatedAt = Date.now();
    RuntimeStatusStore.write(status);
  }
}
