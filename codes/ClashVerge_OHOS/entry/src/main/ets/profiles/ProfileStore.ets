import { http } from '@kit.NetworkKit';

import { AppCtx } from '../common/AppCtx';
import { DIR_PROFILES } from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';
import { HttpClient } from '../core/HttpClient';

export class ProfileItem {
  uid: string = '';
  type: string = 'local';
  name: string = '';
  desc: string = '';
  url: string = '';
  file: string = '';
  updated: number = 0;
  option: string = '{}';
}

/**
 * 配置库（对应上游 profiles.yaml 的 items/current）。
 *
 * 落盘用 JSON（ArkTS 无 YAML 解析器），字段名与上游保持一致；
 * 每个配置的正文单独存 `verge/profiles/<uid>.yaml`，订阅原文一字不改。
 */
export class ProfileStore {
  private static items: ProfileItem[] = [];
  private static currentId: string = '';
  private static loaded: boolean = false;

  private static indexPath(): string {
    return AppCtx.path('verge/profiles.json');
  }

  private static ensureLoaded(): void {
    if (ProfileStore.loaded) {
      return;
    }
    ProfileStore.loaded = true;
    FsUtil.ensureDir(AppCtx.path(DIR_PROFILES));
    const raw = FsUtil.readText(ProfileStore.indexPath());
    if (raw.length === 0) {
      return;
    }
    try {
      const data = JSON.parse(raw) as Record<string, Object | null>;
      const cur = data['current'];
      ProfileStore.currentId = typeof cur === 'string' ? cur as string : '';
      const list = data['items'];
      if (list !== undefined && list !== null) {
        const arr = list as Record<string, Object | null>[];
        for (let i = 0; i < arr.length; i++) {
          ProfileStore.items.push(ProfileStore.fromRecord(arr[i]));
        }
      }
    } catch (e) {
      Log.w('Profiles', `parse index failed: ${Log.err(e as Object)}`);
    }
  }

  private static fromRecord(rec: Record<string, Object | null>): ProfileItem {
    const item = new ProfileItem();
    const uid = rec['uid'];
    item.uid = typeof uid === 'string' ? uid as string : '';
    const type = rec['type'];
    item.type = typeof type === 'string' ? type as string : 'local';
    const name = rec['name'];
    item.name = typeof name === 'string' ? name as string : '';
    const desc = rec['desc'];
    item.desc = typeof desc === 'string' ? desc as string : '';
    const url = rec['url'];
    item.url = typeof url === 'string' ? url as string : '';
    const file = rec['file'];
    item.file = typeof file === 'string' ? file as string : '';
    const updated = rec['updated'];
    let ts = typeof updated === 'number' ? updated as number : 0;
    // 前端按 Unix 秒处理（dayjs(updated * 1000)）；旧版本落盘的是毫秒，
    // 不迁移会直接显示成 58843 年。大于 1e11 一律视为毫秒。
    if (ts > 100000000000) {
      ts = Math.floor(ts / 1000);
    }
    item.updated = ts;
    const option = rec['option'];
    item.option = typeof option === 'string' ? option as string : '{}';
    return item;
  }

  private static toRecord(item: ProfileItem): Record<string, Object | null> {
    const rec: Record<string, Object | null> = {};
    rec['uid'] = item.uid;
    rec['type'] = item.type;
    rec['name'] = item.name;
    rec['desc'] = item.desc;
    rec['url'] = item.url;
    rec['file'] = item.file;
    rec['updated'] = item.updated;
    return rec;
  }

  static save(): void {
    const arr: Record<string, Object | null>[] = [];
    for (let i = 0; i < ProfileStore.items.length; i++) {
      arr.push(ProfileStore.toRecord(ProfileStore.items[i]));
    }
    const root: Record<string, Object | null> = {};
    root['current'] = ProfileStore.currentId;
    root['items'] = arr;
    root['chain'] = [];
    FsUtil.writeText(ProfileStore.indexPath(), JSON.stringify(root));
  }

  /** 备份恢复后让下一次访问重新读盘 */
  static resetCache(): void {
    ProfileStore.loaded = false;
    ProfileStore.items = [];
    ProfileStore.currentId = '';
  }

  static all(): ProfileItem[] {
    ProfileStore.ensureLoaded();
    return ProfileStore.items;
  }

  static currentUid(): string {
    ProfileStore.ensureLoaded();
    return ProfileStore.currentId;
  }

  static setCurrent(uid: string): void {
    ProfileStore.ensureLoaded();
    ProfileStore.currentId = uid;
    ProfileStore.save();
  }

  static find(uid: string): ProfileItem | null {
    ProfileStore.ensureLoaded();
    for (let i = 0; i < ProfileStore.items.length; i++) {
      if (ProfileStore.items[i].uid === uid) {
        return ProfileStore.items[i];
      }
    }
    return null;
  }

  static current(): ProfileItem | null {
    const uid = ProfileStore.currentUid();
    if (uid.length === 0) {
      return null;
    }
    return ProfileStore.find(uid);
  }

  static filePath(uid: string): string {
    return AppCtx.path(`${DIR_PROFILES}/${uid}.yaml`);
  }

  static readContent(uid: string): string {
    return FsUtil.readText(ProfileStore.filePath(uid));
  }

  static writeContent(uid: string, content: string): void {
    FsUtil.writeText(ProfileStore.filePath(uid), content);
  }

  static create(type: string, name: string, desc: string, url: string, content: string): ProfileItem {
    ProfileStore.ensureLoaded();
    const item = new ProfileItem();
    item.uid = `p${Date.now()}${Math.floor(Math.random() * 1000)}`;
    item.type = type;
    item.name = name;
    item.desc = desc;
    item.url = url;
    item.file = `${item.uid}.yaml`;
    item.updated = Math.floor(Date.now() / 1000);
    ProfileStore.items.push(item);
    if (content.length > 0) {
      ProfileStore.writeContent(item.uid, content);
    }
    if (ProfileStore.currentId.length === 0) {
      ProfileStore.currentId = item.uid;
    }
    ProfileStore.save();
    return item;
  }

  static remove(uid: string): boolean {
    ProfileStore.ensureLoaded();
    let index = -1;
    for (let i = 0; i < ProfileStore.items.length; i++) {
      if (ProfileStore.items[i].uid === uid) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return false;
    }
    ProfileStore.items.splice(index, 1);
    FsUtil.remove(ProfileStore.filePath(uid));
    if (ProfileStore.currentId === uid) {
      ProfileStore.currentId = ProfileStore.items.length > 0 ? ProfileStore.items[0].uid : '';
    }
    ProfileStore.save();
    return true;
  }

  static reorder(activeId: string, overId: string): void {
    ProfileStore.ensureLoaded();
    let from = -1;
    let to = -1;
    for (let i = 0; i < ProfileStore.items.length; i++) {
      if (ProfileStore.items[i].uid === activeId) {
        from = i;
      }
      if (ProfileStore.items[i].uid === overId) {
        to = i;
      }
    }
    if (from < 0 || to < 0 || from === to) {
      return;
    }
    const moved = ProfileStore.items.splice(from, 1)[0];
    ProfileStore.items.splice(to, 0, moved);
    ProfileStore.save();
  }

  /** 订阅下载：返回空串=成功，否则为错误信息 */
  static async download(item: ProfileItem): Promise<string> {
    if (item.url.length === 0) {
      return 'profile has no url';
    }
    const headers: Record<string, string> = {};
    headers['User-Agent'] = 'clash-verge/v2.6.0';
    const result = await HttpClient.request(item.url, http.RequestMethod.GET, '', headers, 20000);
    if (result.error.length > 0) {
      return result.error;
    }
    if (result.code !== 200) {
      return `http ${result.code}`;
    }
    if (result.body.trim().length === 0) {
      return 'empty response';
    }
    ProfileStore.writeContent(item.uid, result.body);
    item.updated = Math.floor(Date.now() / 1000);
    ProfileStore.save();
    return '';
  }
}
