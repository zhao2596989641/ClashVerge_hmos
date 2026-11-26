import { AppCtx } from '../common/AppCtx';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';
import { BackupService } from './BackupService';
import { HttpClient } from './HttpClient';

/**
 * 节点/订阅图标（对应上游 `copy_icon_file` / `download_icon_cache`）。
 *
 * 上游语义（`src-tauri/src/feat/icon.rs`）：
 *   - `copy_icon_file(path, {name, previous_t, current_t})`：把用户选的图片复制成
 *     `app_home/icons/<name>.<ext>`，并删掉上一次的 `icons/<previous_t>.*`
 *     （前端用 localStorage 记 `icon_<name>_update_time` 当 current_t/previous_t，
 *      目的是换图后 URL 变化，绕过浏览器图片缓存）
 *   - `download_icon_cache(url, name)`：下载到 `icons/cache/<name>`，已存在直接返回
 *   - 两者都**返回本地绝对路径**，前端再 `convertFileSrc()` 换成 `/__asset/...` 由本地服务读
 */
export class IconService {
  static iconsDir(): string {
    return AppCtx.path('verge/icons');
  }

  static cacheDir(): string {
    return AppCtx.path('verge/icons/cache');
  }

  /** 目录穿越防护，与上游 `normalize_icon_segment` 一致 */
  private static safeSegment(raw: string): string {
    const text = raw.trim();
    if (text.length === 0 ||
      text.indexOf('/') >= 0 ||
      text.indexOf('\\') >= 0 ||
      text.indexOf('..') >= 0) {
      throw new Error('invalid icon cache file name');
    }
    return text;
  }

  private static extOf(path: string): string {
    const dot = path.lastIndexOf('.');
    if (dot < 0) {
      return 'png';
    }
    const ext = path.substring(dot + 1).toLowerCase();
    const allowed: string[] = ['png', 'jpg', 'jpeg', 'webp', 'svg', 'gif', 'bmp', 'ico'];
    return allowed.indexOf(ext) >= 0 ? ext : 'png';
  }

  /** 删掉 `icons/` 下所有 `<stem>.*`（stem 是 name 或上一次的时间戳） */
  private static removeByStem(stem: string): void {
    if (stem.length === 0) {
      return;
    }
    const dir = IconService.iconsDir();
    const names = FsUtil.listDir(dir);
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      const dot = name.lastIndexOf('.');
      const base = dot > 0 ? name.substring(0, dot) : name;
      if (base === stem) {
        FsUtil.remove(`${dir}/${name}`);
      }
    }
  }

  /**
   * 复制用户选的图片作为图标。
   * @param path 系统选择器返回的 uri（`file://docs/...`）或沙箱内绝对路径
   * @param info 上游的 IconInfo：{ name, previous_t, current_t }
   * @returns 新图标在沙箱内的绝对路径
   */
  static copyIcon(path: string, info: Record<string, Object | null>): string {
    const name = IconService.safeSegment(`${info['name'] ?? 'common'}`);
    const previousT = `${info['previous_t'] ?? ''}`.trim();
    const currentT = `${info['current_t'] ?? ''}`.trim();
    if (path.length === 0) {
      throw new Error('icon source path is empty');
    }
    FsUtil.ensureDir(IconService.iconsDir());

    // 目标名优先用 current_t（时间戳），这样 URL 一定变化；name 作为可读前缀
    const stem = `${name}${currentT.length > 0 ? `_${currentT}` : ''}`;
    const ext = IconService.extOf(path);
    const dest = `${IconService.iconsDir()}/${stem}.${ext}`;

    const error = BackupService.copyAny(path, dest);
    if (error.length > 0) {
      throw new Error(`copy icon failed: ${error}`);
    }
    // 清理同 name 的旧图（含 previous_t 那一次）
    IconService.removeByStem(name);
    IconService.removeByStem(previousT);
    Log.i('Icon', `copied -> ${dest}`);
    return dest;
  }

  /**
   * 下载并缓存远程图标（订阅里的 `icon:` 字段）。
   * 已缓存直接返回；走二进制通道，避免字符串解码把图片字节弄坏。
   */
  static async download(url: string, name: string): Promise<string> {
    const safe = IconService.safeSegment(name);
    FsUtil.ensureDir(IconService.cacheDir());
    const dest = `${IconService.cacheDir()}/${safe}`;
    if (FsUtil.exists(dest) && FsUtil.size(dest) > 0) {
      return dest;
    }
    // 先下到临时文件，成功后再改名，避免半截文件被当成缓存
    const temp = `${dest}.downloading`;
    const result = await HttpClient.requestBinaryRaw('GET', url, null, {}, 15000);
    if (result.code !== 200 || result.body.byteLength === 0) {
      FsUtil.remove(temp);
      throw new Error(`download icon failed (code=${result.code} ${result.error})`);
    }
    if (!FsUtil.writeBytes(temp, result.body)) {
      throw new Error('write icon cache failed');
    }
    FsUtil.remove(dest);
    FsUtil.rename(temp, dest);
    Log.i('Icon', `cached ${safe} (${FsUtil.size(dest)} bytes)`);
    return dest;
  }
}
