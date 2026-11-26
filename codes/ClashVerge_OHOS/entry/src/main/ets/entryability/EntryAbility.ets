import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';

import { AppCtx } from '../common/AppCtx';
import { AppTheme } from '../common/AppTheme';
import { LOCAL_SERVER_PORT, RAWFILE_WEB } from '../common/Constants';
import { Log } from '../common/Logger';
import { FsUtil } from '../common/FsUtil';
import { WebOrigin } from '../common/WebOrigin';
import { LocalServer } from '../server/LocalServer';
import { BackgroundKeeper } from '../core/BackgroundKeeper';
import { CoreHost } from '../core/CoreHost';
import { AppBridge } from '../bridge/AppBridge';
import { TrayIcon } from '../core/TrayIcon';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  /** 被 hideAbility() 收进托盘；唤回时必须先 showAbility() 再 showWindow() */
  private hiddenToTray: boolean = false;
  /** 本地静态服务随 Ability 存活（页面被销毁重建时不用重启服务） */
  private server: LocalServer | null = null;
  /** 保证 loadContent 只调一次（正常路径 / 超时兜底 二者先到先算） */
  private contentLoaded: boolean = false;
  /** 每次进程只自动居中一次（用户手动挪过之后不再纠正） */
  private centeredOnce: boolean = false;
  /** 自动轻量模式定时器（窗口失焦后计时，回到前台就取消） */
  private liteTimer: number = -1;
  /** 静默启动：窗口先最小化到托盘，不打扰用户 */
  private silentStart: boolean = false;
  /** 托盘面板（扩展进程）→ 主进程刷新配置 */
  private trayEventSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppCtx.init(this.context.filesDir, this.context.cacheDir);
    this.silentStart = EntryAbility.readSilentStart();
    // 内核尽早启动：onCreate 时 ArkWeb/CEF 还没创建，进程里线程最少，
    // Go runtime 的初始化不会和 CEF 抢 musl 的 loader/TLS 锁（真机 11-15 10:53 的死锁）。
    // bootEarly 只是踢一脚（native 线程干活），不会阻塞这里。
    try {
      CoreHost.setResourceManager(this.context.resourceManager);
      CoreHost.bootEarly();
    } catch (e) {
      Log.w('Ability', `core bootEarly failed: ${Log.err(e as Object)}`);
    }
    // 应用主题（theme_mode）与系统深浅色分开处理：
    //   1) setColorMode 让 dark/ 资源目录跟着**应用**主题走（不是系统）；
    //   2) AppStorage 里放两份：systemDark（系统，推给前端用）、appDark（应用，开屏/窗口底色用）。
    const systemDark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate('systemDark', systemDark);
    try {
      const themeMode = AppTheme.readMode(AppCtx.filesDir);
      this.context.getApplicationContext().setColorMode(AppTheme.colorModeOf(themeMode));
      AppStorage.setOrCreate('appDark', AppTheme.resolveDark(AppCtx.filesDir, systemDark));
      Log.i('Ability', `theme_mode=${themeMode} systemDark=${systemDark} ` +
        `appDark=${AppStorage.get<boolean>('appDark') === true}`);
    } catch (e) {
      AppStorage.setOrCreate('appDark', systemDark);
      Log.w('Ability', `apply app theme failed: ${Log.err(e as Object)}`);
    }
    // 便于 DevEco / chrome://inspect 调试前端
    try {
      webview.WebviewController.setWebDebuggingAccess(true);
    } catch (e) {
      Log.w('Ability', `enable web debugging failed: ${Log.err(e as Object)}`);
    }
    Log.i('Ability', 'onCreate');
    this.subscribeTrayRefresh();
  }

  /**
   * 系统配置变化（深浅色、字号、语言…）。
   *
   * 关键：前端在「跟随系统」模式下监听的是 Tauri 的 `tauri://theme-changed`。
   * 我们的桥接从来不发这个事件，所以系统切深浅色后界面纹丝不动 ——
   * 只有用户在设置里重新点一次「跟随系统」触发 theme_mode 变化，前端才会重新拉。
   * 这里补上事件推送，切换即刻生效。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    const mode = newConfig.colorMode;
    if (mode === undefined) {
      return;
    }
    const dark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    Log.i('Ability', `configuration update: colorMode=${mode} dark=${dark}`);
    AppStorage.setOrCreate('systemDark', dark);
    // appDark 还要叠一层 theme_mode：强制深色时系统切浅色，应用仍然是深色
    AppStorage.setOrCreate('appDark', AppTheme.resolveDark(AppCtx.filesDir, dark));
    AppBridge.pushSystemTheme(dark);
    this.applyWindowBackground();
  }

  private subscribeTrayRefresh(): void {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      // TRAY_REFRESH：面板里切了模式/节点，让主界面重新拉配置
      // TRAY_COMMAND：面板下发的指令（TUN 开关）。走公共事件而不是 startAbility ——
      //   startAbility 会把主窗口拉到前台，主人反馈"点虚拟网卡开关会弹出主界面"。
      events: ['com.lyldeer.clashverge.TRAY_REFRESH', 'com.lyldeer.clashverge.TRAY_COMMAND'],
    };
    commonEventManager.createSubscriber(info,
      (err: BusinessError, subscriber: commonEventManager.CommonEventSubscriber): void => {
        if (err) {
          Log.w('Ability', `tray subscriber create failed: ${err.code}`);
          return;
        }
        this.trayEventSubscriber = subscriber;
        commonEventManager.subscribe(subscriber,
          (subErr: BusinessError, data: commonEventManager.CommonEventData): void => {
            if (subErr) {
              Log.w('Ability', `tray event failed: ${subErr.code}`);
              return;
            }
            if (data.event === 'com.lyldeer.clashverge.TRAY_COMMAND') {
              const cmd = data.data;
              Log.i('Ability', `tray command: ${cmd}`);
              if (cmd === 'tun-on') {
                AppBridge.setTunFromTray(true);
              } else if (cmd === 'tun-off') {
                AppBridge.setTunFromTray(false);
              }
              return;
            }
            Log.i('Ability', 'tray panel -> refresh main config');
            AppBridge.notifyClashConfigChanged();
          });
      });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // ⚠️ 这里**绝不能再阻塞**：内核在独立子进程里初始化（见 core/CoreHost.ets），
    // UI 只负责把页面挂上。之前在这里 `waitReadySync(5000)` 会让开屏图标一直挂着。
    // 系统托盘（仅 PC/2in1 有效，失败不影响主流程）
    TrayIcon.get().install(this.context).catch((e: Object) => {
      Log.w('Ability', `tray install failed: ${Log.err(e)}`);
    });
    this.setupCloseToTray(windowStage);
    this.setupAutoLiteMode(windowStage);
    if (this.silentStart) {
      // 静默启动：窗口先最小化到托盘（内容照常加载，托盘点击 onNewWant 恢复）。
      const main = this.mainWindow;
      if (main !== null) {
        main.minimize().catch((e: Object) => {
          Log.w('Ability', `silent start minimize failed: ${Log.err(e)}`);
        });
        Log.i('Ability', 'silent start: minimized to tray');
      }
    }
    // 兜底：4s 内服务没起来也先把页面挂上（页面自己会显示错误态 + 重试），不能让窗口一直空着
    setTimeout(() => {
      if (!this.contentLoaded) {
        Log.w('Ability', 'local server slow, loading page with error state');
        this.loadContentOnce(windowStage);
      }
    }, 4000);
    // 先把本地服务起好，再加载页面 —— 让 Web 一创建就带真实地址（见 WebOrigin 注释）
    this.prepareWebOrigin(windowStage);
  }

  /**
   * 只加载一次页面（正常路径 = 本地服务起好后；兜底路径 = 4s 超时）。
   *
   * ⚠️ 这里必须真的调用 `windowStage.loadContent`：上一版误写成了自我递归，
   * 结果 4s 兜底什么都不做 —— 一旦 `LocalServer.start()` 卡住（不抛错），
   * `prepareWebOrigin` 永远走不到 loadContent，窗口就是永久黑屏。
   */
  private loadContentOnce(windowStage: window.WindowStage): void {
    if (this.contentLoaded) {
      return;
    }
    this.contentLoaded = true;
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Log.e('Ability', `loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      this.applyImmersiveTitleBar(windowStage);
      Log.i('Ability', 'content loaded');
    });
  }

  private async prepareWebOrigin(windowStage: window.WindowStage): Promise<void> {
    try {
      const srv = new LocalServer(this.context.resourceManager, `${RAWFILE_WEB}/`);
      const port = await srv.start(LOCAL_SERVER_PORT, 16);
      this.server = srv;
      WebOrigin.url = `http://127.0.0.1:${port}/index.html`;
      Log.i('Ability', `web origin ready: ${WebOrigin.url}`);
    } catch (e) {
      WebOrigin.error = Log.err(e as Object);
      Log.e('Ability', `local server failed: ${WebOrigin.error}`);
    }
    // 与 4s 兜底共用同一个守卫，谁先到谁加载
    this.loadContentOnce(windowStage);
  }

  /**
   * 点窗口关闭按钮 → 最小化到托盘（而不是退出）。
   *
   * 依据：`window.Window.on('windowWillClose', cb: Callback<void, Promise<boolean>>)`（API 15+）
   *   resolve(true) = 不关闭；resolve(false)/reject = 继续关闭。
   * 只有在托盘真正装上之后才拦截；否则（tablet 上托盘不可用）保持原生关闭行为，
   * 避免出现"关不掉也打不开"。
   */
  /**
   * 沉浸式标题栏：隐藏原生标题栏，但保留官方三键（右上角）；前端 header 由 shim
   * 注入 padding-right 避让。setWindowDecorVisible 必须在 loadContent 之后调用。
   */
  private applyImmersiveTitleBar(windowStage: window.WindowStage): void {
    try {
      const main = windowStage.getMainWindowSync();
      main.setWindowDecorVisible(false);
      main.setWindowDecorHeight(67);
      main.setWindowTitleButtonVisible(true, true, true);
      main.setTitleAndDockHoverShown(false, true);
      Log.i('Ability', 'immersive titlebar applied');
    } catch (e) {
      Log.w('Ability', `immersive titlebar failed: ${Log.err(e as Object)}`);
    }
    this.applyWindowBackground();
    // 首帧之后再量窗口矩形（loadContent 回调时刻的 windowRect 还是布局前的值）
    setTimeout((): void => {
      this.centerWindowIfFloating();
    }, 300);
  }

  /**
   * 冷启动把窗口摆到屏幕中间，并避让底部 Dock / 任务栏。
   *
   * 为什么需要：静默启动（开机自启）时窗口用的是系统的默认/记忆位置，
   * 实测经常偏在一边、贴着 Dock。
   *
   * 要点：
   *   1. `display.availableWidth/availableHeight` 已经扣掉系统栏和 Dock，用它算居中；
   *   2. `window.moveWindowTo(x, y)` 的单位是 **px**（不是 vp），Rect 也是 px；
   *   3. 只在**浮动态**摆位置：最大化 / 全屏 / 分屏 / 最小化一律不动；
   *   4. 每个进程只做一次，用户自己拖过窗口后不再被纠正。
   */
  private centerWindowIfFloating(): void {
    if (this.centeredOnce) {
      return;
    }
    const win = this.mainWindow;
    if (win === null) {
      return;
    }
    try {
      const status = win.getWindowStatus();
      if (status !== window.WindowStatusType.FLOATING) {
        if (status === window.WindowStatusType.MINIMIZE) {
          // ⚠️ 静默启动是「先最小化再等用户点托盘」：这里不能把 centeredOnce 置真，
          // 否则等窗口真的显示出来时就不会再居中了（那正是开机自启的场景）。
          Log.i('Ability', 'skip centering: window minimized, will retry on foreground');
          return;
        }
        // 最大化/全屏/分屏启动：交给系统，别去改矩形
        this.centeredOnce = true;
        Log.i('Ability', `skip centering: window status=${status}`);
        return;
      }
      const rect = win.getWindowProperties().windowRect;
      const screen = display.getDefaultDisplaySync();
      const availW = screen.availableWidth > 0 ? screen.availableWidth : screen.width;
      const availH = screen.availableHeight > 0 ? screen.availableHeight : screen.height;
      const x = Math.max(0, Math.round((availW - rect.width) / 2));
      const y = Math.max(0, Math.round((availH - rect.height) / 2));
      this.centeredOnce = true;
      if (Math.abs(rect.left - x) <= 2 && Math.abs(rect.top - y) <= 2) {
        Log.i('Ability', `window already centered at ${rect.left},${rect.top}`);
        return;
      }
      Log.i('Ability', `center window: ${rect.left},${rect.top} -> ${x},${y} ` +
        `(available ${availW}x${availH}, window ${rect.width}x${rect.height})`);
      win.moveWindowTo(x, y).catch((e: Object) => {
        Log.w('Ability', `moveWindowTo failed: ${Log.err(e)}`);
      });
    } catch (e) {
      Log.w('Ability', `center window failed: ${Log.err(e as Object)}`);
    }
  }

  /**
   * 窗口底色跟主题走。
   *
   * 系统窗口默认底是白的：页面首帧还没画上来的那一瞬（尤其 Web 组件内容为空时），
   * 透出来的就是这层白 —— 深色模式下就是启动完成瞬间的白闪。
   */
  private applyWindowBackground(): void {
    const win = this.mainWindow;
    if (win === null) {
      return;
    }
    const dark = AppStorage.get<boolean>('appDark') === true;
    try {
      // 这个接口是同步的（void），抛 BusinessError 1300002 表示窗口还没就绪
      win.setWindowBackgroundColor(dark ? '#1B1B1B' : '#F5F5F5');
    } catch (e) {
      Log.w('Ability', `set window background failed: ${Log.err(e as Object)}`);
    }
  }

  /** 直接从 verge.json 读取（onWindowStageCreate 早于 AppBridge.setup） */
  private static readSilentStart(): boolean {
    const raw = FsUtil.readText(`${AppCtx.filesDir}/verge/verge.json`);
    if (raw.length === 0) {
      return false;
    }
    try {
      const obj = JSON.parse(raw) as Record<string, Object | null>;
      return obj['enable_silent_start'] === true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 关闭按钮 = 收进托盘，应用继续运行（对齐 Windows）。
   *
   * `windowStage.on('windowStageClose')` 只在用户点主窗三键区 × 时触发，
   * 同步返回 true 拦截关闭；随后用 UIAbilityContext.hideAbility() 把整个应用藏起来。
   * 注意：hideAbility 要求应用已挂到状态栏（TrayIcon 安装后会 hold 一个
   * NEW_PROCESS_ATTACH_TO_STATUS_BAR_ITEM 的 BackGroundAbility）；失败则降级 minimize。
   */
  /**
   * 自动轻量模式：窗口**失焦**后计时 N 分钟，到点把窗口收进 Dock（= 轻量模式）。
   *
   * 上游是"N 分钟没有任何操作就进轻量模式"，语义对齐到鸿蒙就是窗口失焦：
   *   · 窗口 ACTIVE → 取消计时
   *   · 窗口 INACTIVE → 重新计时
   * 只用公开 API `windowStage.on('windowStageEvent')`，不依赖私有能力。
   */
  private setupAutoLiteMode(windowStage: window.WindowStage): void {
    try {
      windowStage.on('windowStageEvent', (event: window.WindowStageEventType): void => {
        if (event === window.WindowStageEventType.ACTIVE) {
          this.cancelLiteTimer();
          return;
        }
        if (event === window.WindowStageEventType.INACTIVE) {
          this.armLiteTimer();
        }
      });
      Log.i('Ability', 'auto lite mode listener attached');
    } catch (e) {
      Log.w('Ability', `attach windowStageEvent failed: ${Log.err(e as Object)}`);
    }
  }

  private armLiteTimer(): void {
    this.cancelLiteTimer();
    const minutes = AppBridge.autoLiteMinutes();
    if (minutes <= 0) {
      return;
    }
    Log.i('Ability', `auto lite mode armed: ${minutes} min`);
    this.liteTimer = setTimeout((): void => {
      this.liteTimer = -1;
      // 与「点关闭按钮」/ 手动轻量模式同一条路径：整个 Ability 收起，托盘留入口
      this.hideMainWindowToTray();
      Log.i('Ability', `auto lite mode: hidden to tray after ${minutes} min idle`);
    }, minutes * 60 * 1000);
  }

  private cancelLiteTimer(): void {
    if (this.liteTimer !== -1) {
      clearTimeout(this.liteTimer);
      this.liteTimer = -1;
    }
  }

  private setupCloseToTray(windowStage: window.WindowStage): void {
    try {
      const main = windowStage.getMainWindowSync();
      this.mainWindow = main;
      TrayIcon.get().setShowHandler((): void => {
        this.restoreMainWindow();
      });
      windowStage.on('windowStageClose', (): boolean => {
        if (!TrayIcon.get().isInstalled()) {
          // 托盘没装上就没有回程入口，保持系统默认关闭，避免“收进去出不来”
          return false;
        }
        Log.i('Ability', 'close button -> hide ability to tray');
        this.hideMainWindowToTray();
        return true;
      });
      Log.i('Ability', 'close button intercepted: hideAbility -> tray');
    } catch (e) {
      Log.w('Ability', `setupCloseToTray failed (fallback default close): ${Log.err(e as Object)}`);
    }
  }

  private hideMainWindowToTray(): void {
    const main = this.mainWindow;
    if (main === null) {
      return;
    }
    this.context.hideAbility().then(() => {
      this.hiddenToTray = true;
      Log.i('Ability', 'main window hidden; process + tray continue');
    }).catch((e: Object) => {
      Log.w('Ability', `hideAbility failed, fallback minimize: ${Log.err(e)}`);
      main.minimize().then(() => {
        this.hiddenToTray = true;
        Log.i('Ability', 'main window minimized (fallback)');
      }).catch((e2: Object) => {
        Log.w('Ability', `minimize failed: ${Log.err(e2)}`);
      });
    });
  }

  /** 托盘左键 / 「显示主界面」/ onNewWant 共用的唤回路径 */
  private restoreMainWindow(): void {
    const main = this.mainWindow;
    if (main === null) {
      return;
    }
    const wasHidden = this.hiddenToTray;
    const reveal = (): void => {
      main.showWindow().then(() => {
        this.hiddenToTray = false;
        this.mainWindow = main;
        Log.i('Ability', 'main window shown');
        main.restore().catch((e: Object) => {
          Log.w('Ability', `restore after showWindow failed: ${Log.err(e)}`);
        });
      }).catch((e: Object) => {
        Log.w('Ability', `showWindow failed, try restore: ${Log.err(e)}`);
        main.restore().then(() => {
          this.hiddenToTray = false;
          Log.i('Ability', 'main window restored');
        }).catch((e2: Object) => {
          Log.w('Ability', `restore failed: ${Log.err(e2)}`);
        });
      });
    };
    if (wasHidden) {
      // hideAbility 是 Ability 级隐藏，单 showWindow 不够，先把 Ability 拉回前台
      this.context.showAbility().then(reveal).catch((e: Object) => {
        Log.w('Ability', `showAbility failed, still try showWindow: ${Log.err(e)}`);
        reveal();
      });
    } else {
      reveal();
    }
  }

  onNewWant(want: Want): void {
    // 从托盘/桌面图标再次打开：把隐藏或最小化的窗口唤回
    Log.i('Ability', 'onNewWant -> restore main window');
    const params = want.parameters;
    if (params !== undefined && params !== null) {
      if (params['trayCommand'] === 'toggle-tun') {
        Log.i('Ability', 'tray command: toggle tun');
        AppBridge.toggleTunFromTray();
        return;
      }
      if (params['trayCommand'] === 'refresh-clash-config') {
        Log.i('Ability', 'tray command: refresh clash config');
        AppBridge.notifyClashConfigChanged();
        return;
      }
    }
    this.restoreMainWindow();
    if (params !== undefined && params !== null) {
      const page = params['trayPage'];
      if (typeof page === 'string' && page.length > 0) {
        setTimeout((): void => {
          AppBridge.navigateTray(page as string);
        }, 350);
      }
    }
  }

  onWindowStageDestroy(): void {
    Log.i('Ability', 'onWindowStageDestroy');
    TrayIcon.get().remove();
  }

  onDestroy(): void {
    Log.i('Ability', 'onDestroy');
    this.cancelLiteTimer();
    const srv = this.server;
    this.server = null;
    if (srv !== null) {
      srv.stop();
    }
  }

  onForeground(): void {
    Log.i('Ability', 'onForeground');
    // 从系统设置回来后同步一次开机自启真实状态（首页/设置页显示与实际一致）。
    AppBridge.syncAutoStartupStatus(true);
    // 在后台期间系统换过深浅色的话，onConfigurationUpdate 可能没送到；
    // 回到前台再对齐一次，避免界面还停在旧主题。
    AppBridge.syncSystemTheme();
    // 静默启动是先最小化再显示：真正显示出来时再兜一次居中
    setTimeout((): void => {
      this.centerWindowIfFloating();
    }, 200);
  }

  onBackground(): void {
    Log.i('Ability', 'onBackground');
    // 代理运行期间保证主进程不被回收（长时任务）
    BackgroundKeeper.keepAliveIfNeeded(this.context);
  }
}
