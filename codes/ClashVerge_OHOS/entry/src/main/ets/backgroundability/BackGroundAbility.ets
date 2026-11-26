import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

import { Log } from '../common/Logger';

/**
 * 托盘后台 Ability：只负责把本进程“贴”到系统托盘图标上。
 *
 * 由 TrayIcon 以 StartOptions.processMode = NEW_PROCESS_ATTACH_TO_STATUS_BAR_ITEM
 * + startupVisibility = STARTUP_HIDE 拉起。没有它，主窗口调用 hideAbility()
 * 会因不具备“已挂到状态栏”的前置条件而失败。
 */
export default class BackGroundAbility extends UIAbility {
  onCreate(): void {
    Log.i('BgAbility', 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 本 Ability 不应有可见窗口；STARTUP_HIDE 已隐藏，这里再兜底一次。
    this.context.hideAbility().then(() => {
      Log.i('BgAbility', 'window hidden (tray holder ready)');
    }).catch((e: Object) => {
      Log.w('BgAbility', `hideAbility failed: ${Log.err(e)}`);
    });
  }

  onDestroy(): void {
    Log.i('BgAbility', 'onDestroy');
  }
}
