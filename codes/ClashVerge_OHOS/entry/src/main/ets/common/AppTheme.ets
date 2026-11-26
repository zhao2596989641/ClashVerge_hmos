import { ConfigurationConstant } from '@kit.AbilityKit';

import { FsUtil } from './FsUtil';
import { Log } from './Logger';

/**
 * 应用主题（前端「设置 → 主题模式」里的 theme_mode）与系统深浅色的分离处理。
 *
 * 为什么要分开：
 *   `context.config.colorMode` 是**系统**的深浅色；而本应用的主题是用户在前端选的，
 *   两者可以不一致（比如系统浅色、应用强制深色）。开屏 logo / 启动层底色 / 窗口底色
 *   都必须跟**应用主题**走，否则就会出现「深色应用里白底黑 logo」的割裂。
 *
 * 数据来源统一是 `verge/verge.json` 的 `theme_mode`（'system' | 'light' | 'dark'），
 * 主进程和托盘面板（扩展进程）读的是同一个文件，所以跨进程也一致。
 */
export class AppTheme {
  static readonly MODE_SYSTEM: string = 'system';
  static readonly MODE_LIGHT: string = 'light';
  static readonly MODE_DARK: string = 'dark';

  /** 读 verge.json 里的 theme_mode（读不到/非法 → system） */
  static readMode(filesDir: string): string {
    const raw = AppTheme.readText(`${filesDir}/verge/verge.json`);
    if (raw.length === 0) {
      return AppTheme.MODE_SYSTEM;
    }
    try {
      const obj = JSON.parse(raw) as Record<string, Object | null>;
      const rawMode = obj['theme_mode'];
      if (typeof rawMode === 'string') {
        const mode = rawMode as string;
        if (mode === AppTheme.MODE_LIGHT || mode === AppTheme.MODE_DARK) {
          return mode;
        }
      }
    } catch (e) {
      Log.w('AppTheme', `parse verge.json failed: ${Log.err(e as Object)}`);
    }
    return AppTheme.MODE_SYSTEM;
  }

  /** 应用是否深色：显式 dark → 真；显式 light → 假；system → 跟随系统 */
  static resolveDark(filesDir: string, systemDark: boolean): boolean {
    const mode = AppTheme.readMode(filesDir);
    if (mode === AppTheme.MODE_DARK) {
      return true;
    }
    if (mode === AppTheme.MODE_LIGHT) {
      return false;
    }
    return systemDark;
  }

  /** theme_mode → 应用级 colorMode（同时让 dark 资源目录跟着应用主题走） */
  static colorModeOf(mode: string): ConfigurationConstant.ColorMode {
    if (mode === AppTheme.MODE_DARK) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    if (mode === AppTheme.MODE_LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }

  private static readText(path: string): string {
    return FsUtil.readText(path);
  }
}
