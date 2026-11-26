import { StatusBarViewExtensionAbility } from '@kit.DeskTopExtensionKit';
import { UIExtensionContentSession, Want } from '@kit.AbilityKit';

import { Log } from '../common/Logger';

/**
 * 状态栏图标左键业务弹窗（StatusBarViewExtensionAbility）。
 * 只有 tray_event = tray_menu 时 TrayIcon 才把 quickOperation.abilityName 指到这里。
 */
export default class TrayStatusBarAbility extends StatusBarViewExtensionAbility {
  onCreate(): void {
    Log.i('TrayPanel', 'extension onCreate');
  }

  onSessionCreate(want: Want, session: UIExtensionContentSession): void {
    Log.i('TrayPanel', `session create: ${JSON.stringify(want.parameters)}`);
    session.loadContent('pages/TrayPanel');
  }

  onSessionDestroy(session: UIExtensionContentSession): void {
    Log.i('TrayPanel', 'session destroyed');
  }

  onDestroy(): void {
    Log.i('TrayPanel', 'extension onDestroy');
  }
}
