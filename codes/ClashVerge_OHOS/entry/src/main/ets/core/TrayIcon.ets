import { common, contextConstant, StartOptions, Want } from '@kit.AbilityKit';
import { BusinessError, emitter } from '@kit.BasicServicesKit';
import { statusBarManager } from '@kit.DeskTopExtensionKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';

import { BUNDLE_NAME } from '../common/Constants';
import { AppBridge } from '../bridge/AppBridge';
import { Log } from '../common/Logger';

const MENU_PAGE_PREFIX: string = 'cv_tray_page:';

/**
 * 系统托盘（HarmonyOS PC / 2in1）。
 *
 * 依据：`@hms.pcService.statusBarManager`（`@kit.DeskTopExtensionKit`）
 *   addToStatusBar(context, StatusBarItem)
 *   on('statusBarIconClick' | 'rightMenuClick', Callback<emitter.EventData>)
 * 实机踩坑（来自 Remielle 验证过的实现，勿回退）：
 *   1. notifyOnly = true 时 abilityName 仍必须是合法名字，空串会弹"未知打开方式"
 *   2. 系统菜单自带"退出"，不要自己再加一个同名的
 */
export class TrayIcon {
  private static instance: TrayIcon | null = null;
  private added: boolean = false;
  private ctx: common.UIAbilityContext | null = null;
  private iconClick: ((data: emitter.EventData) => void) | null = null;
  private menuClick: ((data: emitter.EventData) => void) | null = null;
  private showHandler: (() => void) | null = null;
  private bgHeld: boolean = false;
  private trayEvent: string = 'main_window';

  static get(): TrayIcon {
    if (TrayIcon.instance === null) {
      TrayIcon.instance = new TrayIcon();
    }
    return TrayIcon.instance;
  }

  isInstalled(): boolean {
    return this.added;
  }

  async install(ctx: common.UIAbilityContext): Promise<boolean> {
    if (this.added) {
      return true;
    }
    this.ctx = ctx;
    try {
      const white = await this.loadIcon('icons/tray_white.png');
      const black = await this.loadIcon('icons/tray_black.png');
      const icons: statusBarManager.StatusBarIcon = { white: white, black: black };
      this.trayEvent = this.readTrayEvent();
      const showMenu = this.trayEvent === 'tray_menu';
      const quick: statusBarManager.QuickOperation = {
        title: 'Clash Verge',
        height: showMenu ? 880 : 1,
        // tray_menu：左键由 StatusBarViewExtensionAbility 弹自定义面板；
        // 其余模式：空串 = 点击交给 statusBarIconClick 事件处理。
        abilityName: showMenu ? 'TrayStatusBarAbility' : '',
        moduleName: 'entry',
      };
      const item: statusBarManager.StatusBarItem = {
        icons: icons,
        quickOperation: quick,
        statusBarGroupMenu: TrayIcon.buildMenu(),
        hoverTips: 'Clash Verge',
      };
      // 先注册监听再 add：部分版本要求监听在菜单生效前就存在。
      this.registerEvents();
      statusBarManager.addToStatusBar(ctx, item);
      this.added = true;
      try {
        // add 后再 update 一次，确保 notifyOnly 菜单项的事件通道被激活。
        statusBarManager.updateStatusBarMenu(ctx, TrayIcon.buildMenu());
      } catch (e) {
        Log.w('Tray', `update menu failed: ${Log.err(e as Object)}`);
      }
      Log.i('Tray', 'installed');
      // 托盘图标挂上后，必须在图标之后拉起「贴住托盘」的后台 Ability，
      // 否则 hideAbility() 会因不具备 NEW_PROCESS_ATTACH_TO_STATUS_BAR_ITEM 条件而失败。
      setTimeout((): void => {
        this.holdStatusBar();
      }, 300);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      Log.w('Tray', `install failed code=${err.code} msg=${err.message}`);
      return false;
    }
  }

  private static buildMenu(): statusBarManager.StatusBarGroupMenu[] {
    // 右键只放主界面左侧导航的页面，顺序与 navigationItems 完全一致：
    // 首页 / 代理 / 订阅 / 连接 / 规则 / 日志 / 测试 / 设置。
    const pages: statusBarManager.StatusBarMenuItem[] = [
      TrayIcon.pageItem('首页', '/'),
      TrayIcon.pageItem('代理', '/proxies'),
      TrayIcon.pageItem('订阅', '/profile'),
      TrayIcon.pageItem('连接', '/connections'),
      TrayIcon.pageItem('规则', '/rules'),
      TrayIcon.pageItem('日志', '/logs'),
      TrayIcon.pageItem('测试', '/unlock'),
      TrayIcon.pageItem('设置', '/settings'),
    ];
    const groups: statusBarManager.StatusBarGroupMenu[] = [pages];
    return groups;
  }

  private static pageItem(title: string, path: string): statusBarManager.StatusBarMenuItem {
    const code = `${MENU_PAGE_PREFIX}${path}`;
    const item: statusBarManager.StatusBarMenuItem = {
      title: title,
      menuCode: code,
      menuAction: {
        abilityName: 'EntryAbility',
        moduleName: 'entry',
        notifyOnly: true,
        menuCode: code,
      },
    };
    return item;
  }

  private readTrayEvent(): string {
    const ctx = this.ctx;
    if (ctx === null) {
      return 'main_window';
    }
    try {
      const raw = ctx.filesDir + '/verge/verge.json';
      const content = fs.readTextSync(raw);
      const data = JSON.parse(content) as Record<string, Object | null>;
      const value = data['tray_event'];
      if (typeof value === 'string' && value.length > 0) {
        return value as string;
      }
    } catch (e) {
      Log.w('Tray', `read tray_event failed: ${Log.err(e as Object)}`);
    }
    return 'main_window';
  }

  /** 设置页改了 tray_event 后重新注册状态栏图标（quickOperation 不能原地更新） */
  applyTrayEvent(event: string): void {
    if (event === this.trayEvent) {
      return;
    }
    this.trayEvent = event;
    const ctx = this.ctx;
    if (!this.added || ctx === null) {
      return;
    }
    try {
      statusBarManager.removeFromStatusBar(ctx);
    } catch (e) {
      Log.w('Tray', `remove for tray_event failed: ${Log.err(e as Object)}`);
    }
    this.added = false;
    this.install(ctx).catch((e: Object) => {
      Log.w('Tray', `reinstall for tray_event failed: ${Log.err(e)}`);
    });
    Log.i('Tray', `tray_event applied: ${event}`);
  }

  private async loadIcon(rawPath: string): Promise<image.PixelMap> {
    const ctx = this.ctx;
    if (ctx === null) {
      throw new Error('tray context not ready');
    }
    const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync(rawPath);
    const source = image.createImageSource(bytes.buffer as ArrayBuffer);
    const options: image.DecodingOptions = {
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false,
    };
    const pixelMap = await source.createPixelMap(options);
    source.release();
    return pixelMap;
  }

  /** 点「关闭」时由 EntryAbility 注册；托盘左键/“显示主界面”统一走这里唤回 */
  setShowHandler(handler: (() => void) | null): void {
    this.showHandler = handler;
  }

  /**
   * 把本进程贴到托盘图标上（官方 PC 托盘后台保活做法）。
   * hideAbility() 的 SDK 前置就是应用已挂到状态栏/后台 Ability 已 attach。
   */
  private holdStatusBar(): void {
    if (this.bgHeld || this.ctx === null) {
      return;
    }
    const want: Want = {
      bundleName: BUNDLE_NAME,
      moduleName: 'entry',
      abilityName: 'BackGroundAbility',
    };
    const options: StartOptions = {
      processMode: contextConstant.ProcessMode.NEW_PROCESS_ATTACH_TO_STATUS_BAR_ITEM,
      startupVisibility: contextConstant.StartupVisibility.STARTUP_HIDE,
    };
    this.ctx.startAbility(want, options).then(() => {
      this.bgHeld = true;
      Log.i('Tray', 'background ability attached to status bar');
    }).catch((e: Object) => {
      Log.w('Tray', `hold background ability failed: ${Log.err(e)}`);
    });
  }

  private registerEvents(): void {
    // 重新注册（applyTrayEvent）时先摘掉旧回调，避免一次点击触发多次
    if (this.iconClick !== null) {
      statusBarManager.off('statusBarIconClick', this.iconClick);
      this.iconClick = null;
    }
    if (this.menuClick !== null) {
      statusBarManager.off('rightMenuClick', this.menuClick);
      this.menuClick = null;
    }
    const onIcon: (data: emitter.EventData) => void = (data: emitter.EventData): void => {
      Log.i('Tray', `icon clicked tray_event=${this.trayEvent}`);
      if (this.trayEvent === 'tray_menu') {
        // 系统会打开 StatusBarViewExtensionAbility，不需要额外动作
        return;
      }
      if (this.trayEvent === 'tun_mode') {
        AppBridge.toggleTunFromTray();
        return;
      }
      if (this.trayEvent === 'disable') {
        return;
      }
      this.showMain();
    };
    const onMenu: (data: emitter.EventData) => void = (data: emitter.EventData): void => {
      let code = '';
      const payload = data.data;
      try {
        if (typeof payload === 'string') {
          const parsed = JSON.parse(payload as string) as Record<string, Object>;
          const raw = parsed['menuCode'] ?? parsed['code'];
          code = typeof raw === 'string' ? raw as string : '';
        } else if (payload !== undefined && payload !== null) {
          const map = payload as Record<string, Object>;
          const raw = map['menuCode'] ?? map['code'];
          code = typeof raw === 'string' ? raw as string : '';
        }
      } catch (e) {
        Log.w('Tray', `menu payload parse failed: ${Log.err(e as Object)}`);
      }
      Log.i('Tray', `rightMenuClick code=${code} raw=${JSON.stringify(payload)}`);
      if (code.indexOf(MENU_PAGE_PREFIX) === 0) {
        const path = code.substring(MENU_PAGE_PREFIX.length);
        this.showMain();
        // 等窗口从 hideAbility 恢复后再导航；隐藏时 WebView 仍在，但延后更稳
        setTimeout((): void => {
          AppBridge.navigateTray(path);
        }, 300);
      }
    };
    this.iconClick = onIcon;
    this.menuClick = onMenu;
    try {
      statusBarManager.on('statusBarIconClick', onIcon);
      statusBarManager.on('rightMenuClick', onMenu);
    } catch (e) {
      Log.w('Tray', `register events failed: ${Log.err(e as Object)}`);
    }
  }

  private showMain(): void {
    const ctx = this.ctx;
    if (ctx === null) {
      return;
    }
    if (this.showHandler !== null) {
      this.showHandler();
      return;
    }
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: 'EntryAbility',
    };
    ctx.startAbility(want).catch((e: Object) => {
      Log.w('Tray', `startAbility failed: ${Log.err(e)}`);
    });
  }


  remove(): void {
    try {
      if (this.iconClick !== null) {
        statusBarManager.off('statusBarIconClick', this.iconClick);
        this.iconClick = null;
      }
      if (this.menuClick !== null) {
        statusBarManager.off('rightMenuClick', this.menuClick);
        this.menuClick = null;
      }
    } catch (e) {
      Log.w('Tray', `off events failed: ${Log.err(e as Object)}`);
    }
    if (this.ctx !== null && this.added) {
      try {
        statusBarManager.removeFromStatusBar(this.ctx);
      } catch (e) {
        Log.w('Tray', `remove failed: ${Log.err(e as Object)}`);
      }
    }
    this.added = false;
  }
}
