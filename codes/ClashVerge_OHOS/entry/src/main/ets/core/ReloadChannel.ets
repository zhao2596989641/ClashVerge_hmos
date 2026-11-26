import { AppCtx } from '../common/AppCtx';
import { DIR_RUNTIME } from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';

/** 主进程 → VPN 扩展进程的「重载运行时配置」信号（跨进程文件桥） */
export class ReloadChannel {
  static path(): string {
    return AppCtx.path(`${DIR_RUNTIME}/reload.json`);
  }

  /** @returns 本次请求的时间戳（扩展侧靠它去重） */
  static request(profilePath: string): number {
    const ts = Date.now();
    const payload: Record<string, Object | null> = {};
    payload['ts'] = ts;
    payload['path'] = profilePath;
    FsUtil.writeText(ReloadChannel.path(), JSON.stringify(payload));
    Log.i('Reload', `request reload ts=${ts} path=${profilePath}`);
    return ts;
  }

  static read(): number {
    return ReloadChannel.readPath()[0];
  }

  static readPath(): [number, string] {
    const raw = FsUtil.readText(ReloadChannel.path());
    if (raw.length === 0) {
      return [0, ''];
    }
    try {
      const obj = JSON.parse(raw) as Record<string, Object | null>;
      const ts = obj['ts'];
      const path = obj['path'];
      return [
        typeof ts === 'number' ? ts as number : 0,
        typeof path === 'string' ? path as string : '',
      ];
    } catch (e) {
      return [0, ''];
    }
  }
}
