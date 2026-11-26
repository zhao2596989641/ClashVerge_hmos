import { Log } from '../common/Logger';
import { ProfileItem, ProfileStore } from './ProfileStore';

/**
 * 订阅自动更新（对应上游 `update_interval` + `allow_auto_update`）。
 *
 * 纯 ArkTS 前台定时器：每分钟检查一次，到期的远程订阅自动拉取；
 * 若更新的是当前正在使用的配置，通过回调让上层重新写运行时配置并热重载。
 */
export class ProfileScheduler {
  private static timer: number = -1;
  private static onCurrentUpdated: (() => void) | null = null;

  static start(onCurrentUpdated: () => void): void {
    ProfileScheduler.onCurrentUpdated = onCurrentUpdated;
    if (ProfileScheduler.timer >= 0) {
      return;
    }
    ProfileScheduler.timer = setInterval(() => {
      ProfileScheduler.tick().catch((e: Object) => {
        Log.w('Scheduler', `tick failed: ${Log.err(e)}`);
      });
    }, 60000);
    Log.i('Scheduler', 'profile auto-update started (60s tick)');
  }

  static stop(): void {
    if (ProfileScheduler.timer >= 0) {
      clearInterval(ProfileScheduler.timer);
      ProfileScheduler.timer = -1;
    }
  }

  private static optionOf(item: ProfileItem): Record<string, Object | null> | null {
    if (item.option.length === 0) {
      return null;
    }
    try {
      return JSON.parse(item.option) as Record<string, Object | null>;
    } catch (e) {
      return null;
    }
  }

  private static intervalMinutes(item: ProfileItem): number {
    const option = ProfileScheduler.optionOf(item);
    if (option === null) {
      return 0;
    }
    if (option['allow_auto_update'] === false) {
      return 0;
    }
    const interval = option['update_interval'];
    if (typeof interval === 'number' && (interval as number) > 0) {
      return interval as number;
    }
    return 0;
  }

  /** 返回下次更新时间戳（Unix 秒）；无计划返回 null */
  static nextUpdate(uid: string): number | null {
    const item = ProfileStore.find(uid);
    if (item === null || item.type !== 'remote' || item.url.length === 0) {
      return null;
    }
    const minutes = ProfileScheduler.intervalMinutes(item);
    if (minutes <= 0) {
      return null;
    }
    return item.updated + minutes * 60;
  }

  static async tick(): Promise<void> {
    const all = ProfileStore.all();
    const now = Math.floor(Date.now() / 1000);
    const currentUid = ProfileStore.currentUid();
    for (let i = 0; i < all.length; i++) {
      const item = all[i];
      if (item.type !== 'remote' || item.url.length === 0) {
        continue;
      }
      const minutes = ProfileScheduler.intervalMinutes(item);
      if (minutes <= 0) {
        continue;
      }
      const due = item.updated + minutes * 60;
      if (now < due) {
        continue;
      }
      const error = await ProfileStore.download(item);
      if (error.length > 0) {
        Log.w('Scheduler', `auto update ${item.name} failed: ${error}`);
        // 失败也推进时间戳，避免每分钟重试刷屏
        item.updated = now;
        ProfileStore.save();
        continue;
      }
      Log.i('Scheduler', `auto updated ${item.name}`);
      if (item.uid === currentUid) {
        const callback = ProfileScheduler.onCurrentUpdated;
        if (callback !== null) {
          callback();
        }
      }
    }
  }
}
