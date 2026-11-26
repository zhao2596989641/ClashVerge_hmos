import { fileIo as fs } from '@kit.CoreFileKit';

import { Log } from './Logger';

/** 文件/目录工具：统一吞掉「不存在」「已存在」这类可忽略异常。 */
export class FsUtil {
  static exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  static ensureDir(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (e) {
      Log.w('Fs', `mkdir failed ${path}: ${Log.err(e as Object)}`);
    }
  }

  static readText(path: string): string {
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      return fs.readTextSync(path);
    } catch (e) {
      Log.w('Fs', `read failed ${path}: ${Log.err(e as Object)}`);
      return '';
    }
  }

  static writeText(path: string, content: string): boolean {
    try {
      const dir = path.substring(0, path.lastIndexOf('/'));
      if (dir.length > 0) {
        FsUtil.ensureDir(dir);
      }
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (e) {
      Log.e('Fs', `write failed ${path}: ${Log.err(e as Object)}`);
      return false;
    }
  }

  /** 写二进制（图标缓存、下载的 zip 等） */
  static writeBytes(path: string, bytes: ArrayBuffer): boolean {
    try {
      const dir = path.substring(0, path.lastIndexOf('/'));
      if (dir.length > 0) {
        FsUtil.ensureDir(dir);
      }
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (e) {
      Log.e('Fs', `writeBytes failed ${path}: ${Log.err(e as Object)}`);
      return false;
    }
  }

  static appendText(path: string, content: string): void {
    try {
      const dir = path.substring(0, path.lastIndexOf('/'));
      if (dir.length > 0) {
        FsUtil.ensureDir(dir);
      }
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      Log.w('Fs', `append failed ${path}: ${Log.err(e as Object)}`);
    }
  }

  static readBytes(path: string): ArrayBuffer | null {
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      const stat = fs.statSync(path);
      const buffer = new ArrayBuffer(stat.size);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }
      return buffer;
    } catch (e) {
      Log.w('Fs', `readBytes failed ${path}: ${Log.err(e as Object)}`);
      return null;
    }
  }

  static listDir(path: string): string[] {
    try {
      if (!fs.accessSync(path)) {
        return [];
      }
      return fs.listFileSync(path);
    } catch (e) {
      Log.w('Fs', `list failed ${path}: ${Log.err(e as Object)}`);
      return [];
    }
  }

  static remove(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const stat = fs.statSync(path);
      if (stat.isDirectory()) {
        fs.rmdirSync(path);
      } else {
        fs.unlinkSync(path);
      }
    } catch (e) {
      Log.w('Fs', `remove failed ${path}: ${Log.err(e as Object)}`);
    }
  }

  static copyFile(src: string, dst: string): boolean {
    try {
      const dir = dst.substring(0, dst.lastIndexOf('/'));
      if (dir.length > 0) {
        FsUtil.ensureDir(dir);
      }
      fs.copyFileSync(src, dst);
      return true;
    } catch (e) {
      Log.w('Fs', `copy failed ${src} -> ${dst}: ${Log.err(e as Object)}`);
      return false;
    }
  }

  static rename(src: string, dst: string): boolean {
    try {
      FsUtil.remove(dst);
      fs.renameSync(src, dst);
      return true;
    } catch (e) {
      Log.w('Fs', `rename failed ${src} -> ${dst}: ${Log.err(e as Object)}`);
      return false;
    }
  }

  static size(path: string): number {
    try {
      if (!fs.accessSync(path)) {
        return 0;
      }
      return fs.statSync(path).size;
    } catch (e) {
      return 0;
    }
  }
}
