import { Log } from './Logger';

/** 主进程全局上下文（filesDir 等在 Ability 创建时注入） */
export class AppCtx {
  private static files: string = '';
  private static cache: string = '';
  private static startedAt: number = Date.now();

  static init(filesDir: string, cacheDir: string): void {
    AppCtx.files = filesDir;
    AppCtx.cache = cacheDir;
    AppCtx.startedAt = Date.now();
    // 日志同时落内存环形缓冲 + 文件，应用内「日志」页靠它显示
    Log.init(`${filesDir}/verge/logs/app.log`);
    Log.i('AppCtx', `filesDir=${filesDir}`);
  }

  static get filesDir(): string {
    return AppCtx.files;
  }

  static get cacheDir(): string {
    return AppCtx.cache;
  }

  static get uptimeMs(): number {
    return Date.now() - AppCtx.startedAt;
  }

  static path(relative: string): string {
    return `${AppCtx.files}/${relative}`;
  }
}
