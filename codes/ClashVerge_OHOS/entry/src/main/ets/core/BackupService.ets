import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

import { AppCtx } from '../common/AppCtx';
import { DIR_VERGE } from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';

/**
 * 本地备份（对应上游 create/list/delete/restore/import/export_local_backup）。
 *
 * 备份内容 = `filesDir/verge/` 整目录（profiles.json + 各订阅 yaml + verge.json + dns 等）。
 * 备份文件放在 `filesDir/backups/`，**故意放在 verge 之外**，否则压缩时会把自己打进去。
 */
export class BackupService {
  static dir(): string {
    return AppCtx.path('backups');
  }

  private static ensureDir(): void {
    FsUtil.ensureDir(BackupService.dir());
  }

  private static stamp(): string {
    const now = new Date();
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}` +
      `-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  }

  /** 生成备份，返回文件名；失败抛错由上层转成日志 */
  static async create(): Promise<string> {
    BackupService.ensureDir();
    const filename = `harmonyos-backup-${BackupService.stamp()}.zip`;
    const zipPath = `${BackupService.dir()}/${filename}`;
    FsUtil.remove(zipPath);
    const options: zlib.Options = {
      level: zlib.CompressLevel.COMPRESS_LEVEL_BEST_SPEED,
      memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
      keepTopLevelFolder: true,
    };
    await zlib.compressFile(AppCtx.path(DIR_VERGE), zipPath, options);
    Log.i('Backup', `created ${filename} (${FsUtil.size(zipPath)} bytes)`);
    return filename;
  }

  /** 给 WebDAV 用：压到缓存目录（不占本地备份列表），返回路径 */
  static async createTemp(): Promise<string> {
    const zipPath = `${AppCtx.cacheDir}/webdav-backup.zip`;
    FsUtil.remove(zipPath);
    const options: zlib.Options = {
      level: zlib.CompressLevel.COMPRESS_LEVEL_BEST_SPEED,
      memLevel: zlib.MemLevel.MEM_LEVEL_DEFAULT,
      keepTopLevelFolder: true,
    };
    await zlib.compressFile(AppCtx.path(DIR_VERGE), zipPath, options);
    Log.i('Backup', `temp zip ${FsUtil.size(zipPath)} bytes`);
    return zipPath;
  }

  /** 把下载到的字节落成备份文件，返回文件名；失败返回空串 */
  static saveBytes(data: ArrayBuffer, prefix: string): string {
    BackupService.ensureDir();
    const filename = `${prefix}-${BackupService.stamp()}.zip`;
    const path = `${BackupService.dir()}/${filename}`;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, data);
      } finally {
        fs.closeSync(file);
      }
      return filename;
    } catch (e) {
      Log.e('Backup', `saveBytes failed: ${Log.err(e as Object)}`);
      return '';
    }
  }

  /** 删除临时文件（WebDAV 上传后清理） */
  static removeTemp(path: string): void {
    FsUtil.remove(path);
  }

  static list(): Record<string, Object | null>[] {
    BackupService.ensureDir();
    const names = FsUtil.listDir(BackupService.dir());
    const items: Record<string, Object | null>[] = [];
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      if (!name.endsWith('.zip')) {
        continue;
      }
      const path = `${BackupService.dir()}/${name}`;
      const stat = fs.statSync(path);
      const item: Record<string, Object | null> = {};
      item['filename'] = name;
      item['path'] = path;
      item['last_modified'] = new Date(stat.mtime * 1000).toISOString();
      item['content_length'] = stat.size;
      items.push(item);
    }
    // 新的在前
    items.sort((a: Record<string, Object | null>, b: Record<string, Object | null>): number => {
      const ta = a['last_modified'];
      const tb = b['last_modified'];
      const sa = typeof ta === 'string' ? ta as string : '';
      const sb = typeof tb === 'string' ? tb as string : '';
      return sb.localeCompare(sa);
    });
    return items;
  }

  static remove(filename: string): void {
    if (filename.length === 0) {
      return;
    }
    FsUtil.remove(`${BackupService.dir()}/${filename}`);
    Log.i('Backup', `removed ${filename}`);
  }

  /** 解压回 filesDir（verge 目录整体覆盖）；调用方负责让内存缓存失效 */
  static async restore(filename: string): Promise<string> {
    const zipPath = `${BackupService.dir()}/${filename}`;
    if (!FsUtil.exists(zipPath)) {
      return `backup not found: ${filename}`;
    }
    try {
      await zlib.decompressFile(zipPath, AppCtx.filesDir);
      Log.i('Backup', `restored ${filename}`);
      return '';
    } catch (e) {
      const message = Log.err(e as Object);
      Log.e('Backup', `restore failed: ${message}`);
      return message;
    }
  }

  /** 从外部文件导入备份（uri 来自系统选择器） */
  static importFrom(uri: string): string {
    if (uri.length === 0) {
      return '';
    }
    BackupService.ensureDir();
    const filename = `imported-${BackupService.stamp()}.zip`;
    const dest = `${BackupService.dir()}/${filename}`;
    const error = BackupService.copyAny(uri, dest);
    if (error.length > 0) {
      return '';
    }
    Log.i('Backup', `imported ${filename}`);
    return filename;
  }

  /** 导出备份到外部（uri 来自系统选择器） */
  static exportTo(filename: string, destination: string): string {
    const source = `${BackupService.dir()}/${filename}`;
    if (!FsUtil.exists(source)) {
      return `backup not found: ${filename}`;
    }
    const error = BackupService.copyAny(source, destination);
    if (error.length === 0) {
      Log.i('Backup', `exported ${filename} -> ${destination}`);
    }
    return error;
  }

  /** copyFileSync 对 uri 的支持视版本而定，失败则退化为手动读写。IconService 也复用这里 */
  static copyAny(source: string, destination: string): string {
    try {
      fs.copyFileSync(source, destination);
      return '';
    } catch (e) {
      Log.w('Backup', `copyFileSync failed, fallback: ${Log.err(e as Object)}`);
    }
    try {
      const bytes = FsUtil.readBytes(source);
      if (bytes === null) {
        return 'read source failed';
      }
      const file = fs.openSync(destination, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        fs.closeSync(file);
      }
      return '';
    } catch (e) {
      const message = Log.err(e as Object);
      Log.e('Backup', `copy failed: ${message}`);
      return message;
    }
  }
}
