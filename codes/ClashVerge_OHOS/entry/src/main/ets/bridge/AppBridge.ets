import { autoStartupManager, common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError, commonEventManager, deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileUri } from '@kit.CoreFileKit';
import { connection, http } from '@kit.NetworkKit';

import { AppCtx } from '../common/AppCtx';
import { AppTheme } from '../common/AppTheme';
import {
  APP_VERSION_NAME,
  BUNDLE_NAME,
  CONTROLLER_PORT,
  DIR_LOGS,
  DIR_PROFILES,
  DIR_RUNTIME,
  DIR_VERGE,
  FILE_RUNTIME_YAML
} from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';
import { VergeConfig } from '../config/VergeConfig';
import { BackgroundKeeper } from '../core/BackgroundKeeper';
import { CoreHost } from '../core/CoreHost';
import { BackupService } from '../core/BackupService';
import { DialogBridge } from '../core/DialogBridge';
import { HttpPlugin } from '../core/HttpPlugin';
import { MediaUnlockService } from '../core/MediaUnlockService';
import { WebDavService } from '../core/WebDavService';
import { DnsConfig } from '../core/DnsConfig';
import { Diagnostic } from '../core/Diagnostic';
import { HttpClient } from '../core/HttpClient';
import { IconService } from '../core/IconService';
import { HotkeyHost } from '../core/HotkeyHost';
import { TrayIcon } from '../core/TrayIcon';
import { RuntimeStatusStore } from '../core/RuntimeStatus';
import { TunController } from '../core/TunController';
import { ProfileScheduler } from '../profiles/ProfileScheduler';
import { ProfileStore } from '../profiles/ProfileStore';
import { RuntimeConfig } from '../profiles/RuntimeConfig';
import { JsBridge } from './JsBridge';
import { MihomoBridge } from './MihomoBridge';

/**
 * 主进程命令注册表。
 *
 * 覆盖范围遵循 HANDOFF §6.2-1：先补齐 8 个页面要用的命令，
 * 未实现的命令一律返回 null/[]（不 reject），保证界面不白屏。
 */
export class AppBridge {
  private static verge: VergeConfig | null = null;
  private static secret: string = '';
  private static clashMode: string = 'rule';
  private static context: common.UIAbilityContext | null = null;
  private static activeBridge: JsBridge | null = null;
  /**
   * 每个代理组一条串行队列：点得快也不会乱序，但**命令本身立即返回**，
   * 不再让 UI 等内核（内核测速时 PUT 可能 3–5s 才回）。
   */
  private static proxyQueue: Map<string, Promise<void>> = new Map<string, Promise<void>>();

  /** 从「转到设置」回来后的短时状态检测；不是常驻轮询 */
  private static autoStartWatch: number = -1;

  static install(bridge: JsBridge, context: common.UIAbilityContext): void {
    AppBridge.context = context;
    AppBridge.activeBridge = bridge;
    if (AppBridge.verge === null) {
      AppBridge.verge = new VergeConfig(AppCtx.filesDir);
      AppBridge.secret = AppBridge.loadOrCreateSecret();
      FsUtil.ensureDir(AppCtx.path(DIR_VERGE));
      FsUtil.ensureDir(AppCtx.path(DIR_PROFILES));
      FsUtil.ensureDir(AppCtx.path(DIR_LOGS));
      FsUtil.ensureDir(AppCtx.path(DIR_RUNTIME));
    }
    const verge = AppBridge.verge;
    MihomoBridge.install(bridge, AppBridge.secret);

    AppBridge.installApp(bridge, verge);
    AppBridge.installClash(bridge, verge);
    AppBridge.installProfiles(bridge, verge);
    AppBridge.installBackup(bridge, verge);
    DialogBridge.install(bridge, context);
    HttpPlugin.install(bridge);
    HttpPlugin.setProxyPort(verge.getNumber('verge_mixed_port', 7890));

    // Tauri 的 fs 插件：前端只用到了 exists（判断订阅文件/图标是否就位）
    bridge.register('plugin:fs|exists', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['path'];
      if (typeof raw !== 'string') {
        return false;
      }
      return FsUtil.exists(AppBridge.resolvePath(raw as string));
    });
    AppBridge.installNoops(bridge);
    // 必须放在 installNoops 之后：Map.set 后写覆盖，确保拿到真实实现而不是 noop
    AppBridge.installProxyView(bridge);
    AppBridge.installDns(bridge);
    AppBridge.installIconAndDiag(bridge);
    AppBridge.installProxyChain(bridge, verge);
    ProfileScheduler.start(() => {
      AppBridge.applyRuntime(verge).catch((e: Object) => {
        Log.w('Scheduler', `apply after auto-update failed: ${Log.err(e)}`);
      });
    });
    HotkeyHost.setDispatcher((action: string): void => {
      AppBridge.hotkeyAction(action);
    });
    AppBridge.syncHotkeys();
    AppBridge.syncAutoStartupStatus();
    Log.i('AppBridge', 'command set installed');
  }

  private static loadOrCreateSecret(): string {
    const path = AppCtx.path('verge/core-secret.txt');
    const existing = FsUtil.readText(path);
    if (existing.trim().length > 0) {
      return existing.trim();
    }
    const secret = util.generateRandomUUID(false);
    FsUtil.writeText(path, secret);
    return secret;
  }

  static getSecret(): string {
    return AppBridge.secret;
  }

  // ---------------- 应用 / 系统 ----------------

  private static installApp(bridge: JsBridge, verge: VergeConfig): void {
    bridge.register('bridge_ping', async (): Promise<Object | null> => {
      const result: Record<string, Object | null> = {};
      result['pong'] = true;
      result['ts'] = Date.now();
      result['version'] = APP_VERSION_NAME;
      return result;
    });

    bridge.register('get_app_uptime', async (): Promise<Object | null> => AppCtx.uptimeMs);
    bridge.register('get_app_dir', async (): Promise<Object | null> => AppCtx.filesDir);

    bridge.register('get_system_info', async (): Promise<Object | null> => {
      const info: Record<string, Object | null> = {};
      info['system_name'] = 'HarmonyOS';
      info['system_version'] = deviceInfo.osFullName;
      return info;
    });

    bridge.register('get_system_hostname', async (): Promise<Object | null> => deviceInfo.marketName);

    bridge.register('get_verge_config', async (): Promise<Object | null> => verge.get());

    bridge.register('patch_verge_config', async (args: Record<string, Object>): Promise<Object | null> => {
      const payload = args['payload'] as Record<string, Object | null>;
      if (payload === undefined || payload === null) {
        return verge.get();
      }
      const before = verge.getBool('enable_tun_mode', false);
      verge.patch(payload);
      // 主题模式：应用级 colorMode + appDark（开屏/窗口底色/托盘面板都读它）
      const themeMode = payload['theme_mode'];
      if (typeof themeMode === 'string') {
        AppBridge.applyAppTheme(themeMode as string);
      }
      const trayEvent = payload['tray_event'];
      if (typeof trayEvent === 'string') {
        TrayIcon.get().applyTrayEvent(trayEvent as string);
      }
      AppBridge.syncHotkeys();
      const after = verge.getBool('enable_tun_mode', false);
      if (before !== after) {
        await AppBridge.toggleTun(after, verge);
      }
      return verge.get();
    });

    bridge.register('get_sys_proxy', async (): Promise<Object | null> => {
      const info: Record<string, Object | null> = {};
      info['enable'] = false;
      info['server'] = '';
      info['bypass'] = '';
      return info;
    });

    bridge.register('get_auto_proxy', async (): Promise<Object | null> => {
      const info: Record<string, Object | null> = {};
      info['enable'] = false;
      info['url'] = '';
      return info;
    });

    bridge.register('get_network_interfaces', async (): Promise<Object | null> => {
      const info = AppBridge.networkInterfacesInfo();
      const names: string[] = [];
      for (let i = 0; i < info.length; i++) {
        names.push(AppBridge.strOf(info[i]['name']));
      }
      return names;
    });

    bridge.register('get_network_interfaces_info', async (): Promise<Object | null> => {
      return AppBridge.networkInterfacesInfo();
    });

    bridge.register('probe_listener', async (args: Record<string, Object>): Promise<Object | null> => {
      const outcome: Record<string, Object | null> = {};
      outcome['status'] = 'available';
      return outcome;
    });

    bridge.register('get_embedded_server_port', async (): Promise<Object | null> => 45123);

    bridge.register('save_proxy_ports', async (args: Record<string, Object>): Promise<Object | null> => {
      // 前端传给 save_proxy_ports 的是 ProxyPortSettings
      // { mixedPort, socks:{enabled,port}, http:{...}, redir:{...}, tproxy:{...} }，
      // 与 VergeConfig 的 verge_* 字段不是同名结构；直接 verge.patch(settings) 会存一堆
      // 没人读取的嵌套键，界面显示新端口、内核仍监听旧端口（用户改端口无效）。
      const settings = args['settings'] as Record<string, Object | null>;
      if (settings !== undefined && settings !== null) {
        const patch: Record<string, Object | null> = {};
        const mixed = settings['mixedPort'];
        if (typeof mixed === 'number') {
          patch['verge_mixed_port'] = mixed;
        }
        AppBridge.patchPortToggle(patch, settings, 'socks', 'verge_socks_enabled', 'verge_socks_port');
        AppBridge.patchPortToggle(patch, settings, 'http', 'verge_http_enabled', 'verge_port');
        AppBridge.patchPortToggle(patch, settings, 'redir', 'verge_redir_enabled', 'verge_redir_port');
        AppBridge.patchPortToggle(patch, settings, 'tproxy', 'verge_tproxy_enabled', 'verge_tproxy_port');
        verge.patch(patch);
        HttpPlugin.setProxyPort(verge.getNumber('verge_mixed_port', 7890));
        AppBridge.syncAppHttpProxy(verge.getNumber('verge_mixed_port', 7890));
        // 端口是运行时配置项：只落盘不重载的话界面显示新端口、内核还监听旧端口。
        const current = ProfileStore.current();
        const content = current === null ? '' : ProfileStore.readContent(current.uid);
        const path = RuntimeConfig.write(AppBridge.secret, verge, content);
        CoreHost.forceApplyConfig(path);
        // 让前端重新拉 get_clash_info / get_proxy_view，避免设置页仍显示旧端口
        const bridgeRef = AppBridge.activeBridge;
        if (bridgeRef !== null) {
          const payload: Record<string, Object | null> = {};
          bridgeRef.emit('verge://refresh-clash-config', payload);
        }
      }
      const outcome: Record<string, Object | null> = {};
      outcome['status'] = 'saved';
      return outcome;
    });

    bridge.register('open_auto_start_settings', async (): Promise<Object | null> => {
      await AppBridge.openAutoStartSettings();
      return null;
    });

    bridge.register('restart_app', async (): Promise<Object | null> => {
      const ctx = AppBridge.context;
      if (ctx !== null) {
        ctx.terminateSelf();
      }
      return null;
    });

    bridge.register('exit_app', async (): Promise<Object | null> => {
      const ctx = AppBridge.context;
      if (ctx !== null) {
        ctx.terminateSelf();
      }
      return null;
    });
  }

  /** 切换 TUN：写运行时配置 → 起/停 VPN 扩展 → 起/停长时任务 */
  /**
   * App 启动就把内核拉起来（UI 进程常驻，控制器 + mixed-port 始终在线）。
   * 与上游 Windows/mac 一致：内核的生命周期与应用一致，TUN 只是能力开关。
   */
  static async bootCore(): Promise<void> {
    const verge = AppBridge.verge;
    if (verge === null) {
      return;
    }
    const current = ProfileStore.current();
    const content = current === null ? '' : ProfileStore.readContent(current.uid);
    const path = RuntimeConfig.write(AppBridge.secret, verge, content);
    // 左下角常驻提示：冷启动时内核还在加载（尤其在首次释放 geo/大订阅时）。
    const wasReady = CoreHost.alive();
    AppBridge.emitNotice(wasReady ? '' : 'core_loading::start');
    const error = await CoreHost.ensureStarted(path);
    AppBridge.emitNotice(wasReady ? '' : 'core_loading::end');
    if (error.length > 0) {
      Log.e('CoreHost', `boot failed: ${error}`);
      // 同时落进运行时状态：前端 「/get_runtime_config.lastError」 能读到，
      // 免得用户只看到"未连接"却不知道是内核根本没起来。
      RuntimeStatusStore.reset(`core: ${error}`);
      return;
    }
    Log.i('CoreHost', 'boot ok: controller + mixed-port ready');
    AppBridge.syncAppHttpProxy(verge.getNumber('verge_mixed_port', 7890));
  }

  /**
   * 应用级 HTTP 代理：只在 TUN 开启时让 app 内 fetch 走 mixed-port。
   *
   * Windows 的语义是「TUN 关 = 直连真实出口，TUN 开 = 节点出口」；鸿蒙没有系统代理，
   * 如果始终把 app 请求打到 mixed-port，就会出现“TUN 没开 IP 仍显示新加坡”的假象。
   * TUN 关闭时必须清空 app 代理，让 IP 检测走真实网络。
   */
  private static syncAppHttpProxy(port: number): void {
    const verge = AppBridge.verge;
    const tunOn = verge !== null && verge.getBool('enable_tun_mode', false);
    if (!tunOn || port <= 0) {
      AppBridge.clearAppHttpProxy();
      return;
    }
    try {
      const proxy: connection.HttpProxy = {
        host: '127.0.0.1',
        port: port,
        exclusionList: ['127.0.0.1', 'localhost'],
      };
      connection.setAppHttpProxy(proxy);
      Log.i('Http', `app http proxy -> 127.0.0.1:${port} (tun on)`);
    } catch (e) {
      Log.w('Http', `setAppHttpProxy failed: ${Log.err(e as Object)}`);
    }
  }

  private static clearAppHttpProxy(): void {
    try {
      const empty: connection.HttpProxy = { host: '', port: 0, exclusionList: [] };
      connection.setAppHttpProxy(empty);
      Log.i('Http', 'app http proxy cleared (tun off)');
    } catch (e) {
      Log.w('Http', `clearAppHttpProxy failed: ${Log.err(e as Object)}`);
    }
  }

  /** 托盘菜单用：切换 TUN（内部走和热键/首页开关同一条路径） */
  static toggleTunFromTray(): void {
    const verge = AppBridge.verge;
    if (verge === null) {
      return;
    }
    AppBridge.setTunFromTray(!verge.getBool('enable_tun_mode', false));
  }

  /**
   * 托盘面板显式设定 TUN（面板里是一个 Switch，表达的是"目标状态"而不是"翻转"，
   * 用 toggle 会在状态不同步时翻错方向）。
   */
  static setTunFromTray(enable: boolean): void {
    const verge = AppBridge.verge;
    if (verge === null) {
      return;
    }
    if (verge.getBool('enable_tun_mode', false) === enable) {
      Log.i('Tray', `set tun ${enable}: already in this state`);
      return;
    }
    const patch: Record<string, Object | null> = {};
    patch['enable_tun_mode'] = enable;
    verge.patch(patch);
    AppBridge.toggleTun(enable, verge).catch((e: Object) => {
      Log.w('Tray', `set tun from tray failed: ${Log.err(e)}`);
    });
  }

  /** 托盘面板改完核心/TUN 后通知主界面重新拉配置（面板是独立扩展进程，不能直接 emit）。 */
  /**
   * 拖动窗口。
   *
   * 我们隐藏了系统标题栏（setWindowDecorVisible(false)），窗口于是没有任何可拖区域。
   * 前端上游本来就按 Tauri 的约定标好了 `data-tauri-drag-region="true"` 的区域
   * （`the_titlebar-drag-region`、`base-page` 的 header、侧栏 logo），
   * 只是 Tauri 原生会接管这个按下事件、我们没接，所以拖不动。
   * 这里接上：`Window.startMoving()` 由系统接管后续移动，松开即结束。
   */
  /**
   * 双击标题栏 → 最大化 / 还原。
   *
   * 为什么不让系统接管：我们 `setWindowDecorVisible(false)` 隐藏了标题栏，
   * 系统那套「双击标题栏切换最大化」的手势也就没了；而单靠系统三键，
   * 主人期望的「双击」是缺的。这里用 `getWindowStatus()` 判当前态，
   * 分别走 `maximize()` / `recover()` —— 这两个是系统动画，别自己 resize 硬凑。
   */
  static toggleWindowMaximize(): void {
    const ctx = AppBridge.context;
    if (ctx === null) {
      return;
    }
    window.getLastWindow(ctx).then((win: window.Window) => {
      let maximized = false;
      try {
        const status = win.getWindowStatus();
        maximized = status === window.WindowStatusType.MAXIMIZE
          || status === window.WindowStatusType.FULL_SCREEN;
      } catch (e) {
        Log.w('Bridge', `get window status failed: ${Log.err(e as Object)}`);
      }
      if (maximized) {
        win.recover().catch((e: Object) => {
          Log.w('Bridge', `recover failed: ${Log.err(e)}`);
        });
      } else {
        win.maximize().catch((e: Object) => {
          Log.w('Bridge', `maximize failed: ${Log.err(e)}`);
        });
      }
    }).catch((e: Object) => {
      Log.w('Bridge', `get last window failed: ${Log.err(e)}`);
    });
  }

  static startWindowMoving(): void {
    const ctx = AppBridge.context;
    if (ctx === null) {
      return;
    }
    window.getLastWindow(ctx).then((win: window.Window) => {
      win.startMoving().catch((e: Object) => {
        Log.w('Bridge', `startMoving failed: ${Log.err(e)}`);
      });
    }).catch((e: Object) => {
      Log.w('Bridge', `get last window failed: ${Log.err(e)}`);
    });
  }

  /**
   * 跟随系统配色：把当前系统深浅色推给前端（前端据此立刻切主题）。
   * 由 EntryAbility.onConfigurationUpdate 与页面首帧后各调一次。
   */
  static pushSystemTheme(dark: boolean): void {
    const bridge = AppBridge.activeBridge;
    if (bridge === null) {
      return;
    }
    bridge.emitSystemTheme(dark ? 'dark' : 'light');
  }

  /** 读一次系统配置里的 colorMode 并推送（页面加载完成时用，保证首帧就是对的） */
  static syncSystemTheme(): void {
    const ctx = AppBridge.context;
    if (ctx === null) {
      return;
    }
    try {
      const mode = ctx.config.colorMode;
      const dark = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      AppBridge.pushSystemTheme(dark);
      Log.i('Bridge', `system theme synced: dark=${dark}`);
    } catch (e) {
      Log.w('Bridge', `sync system theme failed: ${Log.err(e as Object)}`);
    }
  }

  /**
   * 应用主题（theme_mode）变了：立刻让 dark/ 资源目录、AppStorage.appDark、窗口底色跟上。
   *
   * 为什么要在前端改主题时也走这一步：
   *   前端只管它自己的 React 主题，Web 组件外面的那一圈（启动层、窗口底色、
   *   系统托盘面板）是 ArkTS 画的 —— 不同步就会出现"界面已经变深色，窗口底色还是白的"。
   */
  static applyAppTheme(mode: string): void {
    const ctx = AppBridge.context;
    const systemDark = ctx === null ? false :
      (ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    let dark = mode === AppTheme.MODE_DARK;
    if (mode === AppTheme.MODE_SYSTEM) {
      dark = systemDark;
    }
    if (ctx !== null) {
      try {
        ctx.getApplicationContext().setColorMode(AppTheme.colorModeOf(mode));
      } catch (e) {
        Log.w('Bridge', `setColorMode failed: ${Log.err(e as Object)}`);
      }
    }
    AppStorage.setOrCreate('appDark', dark);
    AppBridge.applyWindowBg(dark);
    Log.i('Bridge', `app theme applied: theme_mode=${mode} appDark=${dark}`);
  }

  private static applyWindowBg(dark: boolean): void {
    const ctx = AppBridge.context;
    if (ctx === null) {
      return;
    }
    window.getLastWindow(ctx).then((win: window.Window) => {
      try {
        win.setWindowBackgroundColor(dark ? '#1B1B1B' : '#F5F5F5');
      } catch (e) {
        Log.w('Bridge', `set window bg failed: ${Log.err(e as Object)}`);
      }
    }).catch((e: Object) => {
      Log.w('Bridge', `get last window failed: ${Log.err(e)}`);
    });
  }

  static notifyClashConfigChanged(): void {
    // 托盘面板在**另一个进程**里，没法直接调函数；用公共事件把"状态变了"推过去，
    // 面板收到就立刻重拉（比等 1s 轮询更跟手）。
    AppBridge.publishTrayState();
    const bridge = AppBridge.activeBridge;
    if (bridge === null) {
      return;
    }
    const payload: Record<string, Object | null> = {};
    bridge.emit('verge://refresh-clash-config', payload);
    bridge.emit('verge://refresh-verge-config', payload);
  }

  /** 通知托盘面板刷新（模式 / TUN / 节点 / 订阅 任何一项变了都该发） */
  static publishTrayState(): void {
    try {
      const options: commonEventManager.CommonEventPublishData = { data: 'state' };
      commonEventManager.publish('com.lyldeer.clashverge.TRAY_STATE', options,
        (err: BusinessError): void => {
          if (err) {
            Log.w('Bridge', `publish tray state failed: ${err.code}`);
          }
        });
    } catch (e) {
      Log.w('Bridge', `publish tray state throw: ${Log.err(e as Object)}`);
    }
  }

  /** 开机自启是系统设置项：把真实状态同步到 verge.enable_auto_launch，UI 不再自欺欺人 */
  static syncAutoStartupStatus(forceEmit: boolean = false): void {
    const verge = AppBridge.verge;
    if (verge === null) {
      return;
    }
    try {
      if (!autoStartupManager.isAutoStartupSupported()) {
        return;
      }
      autoStartupManager.getAutoStartupStatusForSelf().then((enabled: boolean) => {
        const changed = verge.getBool('enable_auto_launch', false) !== enabled;
        if (!changed && !forceEmit) {
          return;
        }
        if (changed) {
          const patch: Record<string, Object | null> = {};
          patch['enable_auto_launch'] = enabled;
          verge.patch(patch);
        }
        // 从设置返回时 CEF 可能还没恢复事件循环，延后一点再通知前端刷新。
        setTimeout(() => {
          const bridge = AppBridge.activeBridge;
          if (bridge !== null) {
            const payload: Record<string, Object | null> = {};
            bridge.emit('verge://refresh-verge-config', payload);
          }
        }, forceEmit ? 500 : 0);
        if (changed) {
          Log.i('AutoStart', `synced enabled=${enabled}`);
        }
      }).catch((e: Object) => {
        Log.w('AutoStart', `get status failed: ${Log.err(e)}`);
      });
    } catch (e) {
      Log.w('AutoStart', `not supported: ${Log.err(e as Object)}`);
    }
  }

  /** 设置页 →「转到设置」后短时观察（默认 3 分钟），不是整个生命周期轮询 */
  static startAutoStartupWatch(): void {
    if (AppBridge.autoStartWatch !== -1) {
      clearInterval(AppBridge.autoStartWatch);
    }
    const deadline = Date.now() + 3 * 60 * 1000;
    AppBridge.autoStartWatch = setInterval(() => {
      if (Date.now() > deadline) {
        AppBridge.stopAutoStartupWatch();
        return;
      }
      AppBridge.syncAutoStartupStatus();
      const verge = AppBridge.verge;
      if (verge !== null && verge.getBool('enable_auto_launch', false)) {
        // 已观察到开启，停止检测；之后用户若在设置里关闭，下一次 onForeground 会同步。
        AppBridge.stopAutoStartupWatch();
      }
    }, 3000);
  }

  private static stopAutoStartupWatch(): void {
    if (AppBridge.autoStartWatch !== -1) {
      clearInterval(AppBridge.autoStartWatch);
      AppBridge.autoStartWatch = -1;
    }
  }

  /** 打开系统设置（系统没有公开「应用启动管理」深链，先到设置首页让用户进入） */
  private static async openAutoStartSettings(): Promise<void> {
    const ctx = AppBridge.context;
    if (ctx === null) {
      throw new Error('no ability context');
    }
    AppBridge.startAutoStartupWatch();
    const want: Want = {
      bundleName: 'com.huawei.hmos.settings',
      abilityName: 'com.huawei.hmos.settings.MainAbility',
    };
    await ctx.startAbility(want);
  }

  // ---------------- 全局快捷键 ----------------

  private static syncHotkeys(): void {
    const verge = AppBridge.verge;
    if (verge === null) {
      return;
    }
    const raw = verge.get()['hotkeys'];
    const list: string[] = [];
    if (Array.isArray(raw)) {
      const arr = raw as Object[];
      for (let i = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          list.push(arr[i] as string);
        }
      }
    }
    HotkeyHost.configure(list, verge.getBool('enable_global_hotkey', false));
  }

  private static hotkeyAction(action: string): void {
    const verge = AppBridge.verge;
    if (verge === null) {
      return;
    }
    Log.i('Hotkey', `run action ${action}`);
    if (action === 'toggle_tun_mode') {
      const next = !verge.getBool('enable_tun_mode', false);
      const patch: Record<string, Object | null> = {};
      patch['enable_tun_mode'] = next;
      verge.patch(patch);
      AppBridge.toggleTun(next, verge).catch((e: Object) => {
        Log.w('Hotkey', `toggle tun failed: ${Log.err(e)}`);
      });
      return;
    }
    if (action === 'clash_mode_rule' || action === 'clash_mode_global' || action === 'clash_mode_direct') {
      const mode = action.substring('clash_mode_'.length);
      AppBridge.clashMode = mode;
      RuntimeConfig.writeMode(mode);
      const patch: Record<string, Object | null> = {};
      patch['mode'] = mode;
      AppBridge.patchCoreConfig(patch).catch((e: Object) => {
        Log.w('Hotkey', `switch mode failed: ${Log.err(e)}`);
      });
      return;
    }
    if (action === 'reactivate_profiles') {
      AppBridge.reactivateProfiles();
      return;
    }
    if (action === 'open_or_close_dashboard' || action === 'entry_lightweight_mode') {
      AppBridge.toggleDashboard();
      return;
    }
    if (action === 'toggle_system_proxy') {
      // 鸿蒙三方应用没有系统代理 API（只有 connection.setAppHttpProxy 应用级代理）。
      Log.w('Hotkey', 'toggle_system_proxy is unsupported on HarmonyOS');
    }
  }

  private static reactivateProfiles(): void {
    const verge = AppBridge.verge;
    if (verge === null) {
      return;
    }
    const current = ProfileStore.current();
    const content = current === null ? '' : ProfileStore.readContent(current.uid);
    const path = RuntimeConfig.write(AppBridge.secret, verge, content);
    CoreHost.forceApplyConfig(path);
    AppBridge.replaySelections();
    Log.i('Hotkey', 'profiles reactivated');
  }

  /**
   * 进入轻量模式：把**整个 Ability 收起来**（窗口消失、任务栏不留窗口），
   * 内核与托盘图标继续运行 —— 与「点关闭按钮」同一条路径（hideAbility）。
   *
   * 为什么不用 minimize：Windows 端的轻量模式是"窗口消失、只剩托盘"，
   * minimize 会在 Dock/任务栏留一个缩略窗，语义不对。restoreMainWindow()
   * 仍是回程入口（托盘左键 / 「打开 Clash Verge」）。
   */
  static enterLiteMode(): void {
    const ctx = AppBridge.context;
    if (ctx === null) {
      return;
    }
    ctx.hideAbility().then((): void => {
      Log.i('Lite', 'lite mode: ability hidden, core + tray keep running');
    }).catch((e: Object): void => {
      Log.w('Lite', `hideAbility failed, fallback minimize: ${Log.err(e)}`);
      window.getLastWindow(ctx).then((win: window.Window) => {
        win.minimize().catch((e2: Object) => {
          Log.w('Lite', `minimize failed: ${Log.err(e2)}`);
        });
      }).catch((e3: Object) => {
        Log.w('Lite', `get last window failed: ${Log.err(e3)}`);
      });
    });
  }

  /** 自动轻量模式的分钟数（0 = 关闭）。EntryAbility 的定时器读它。 */
  static autoLiteMinutes(): number {
    const verge = AppBridge.verge;
    if (verge === null) {
      return 0;
    }
    if (!verge.getBool('enable_auto_light_weight_mode', false)) {
      return 0;
    }
    const minutes = verge.getNumber('auto_light_weight_minutes', 30);
    return minutes > 0 ? minutes : 0;
  }

  private static toggleDashboard(): void {
    const ctx = AppBridge.context;
    if (ctx === null) {
      return;
    }
    window.getLastWindow(ctx).then((win: window.Window) => {
      try {
        const status = win.getWindowStatus();
        Log.i('Hotkey', `window status=${status}`);
        if (status === window.WindowStatusType.MINIMIZE) {
          // showWindow 在 2in1 的最小化窗口上不一定会回到前台，
          // 再用 startAbility 兜底把已有窗口拉起（等价于 `aa start`）。
          win.showWindow().catch((e: Object) => {
            Log.w('Hotkey', `show window failed: ${Log.err(e)}`);
          });
          const want: Want = {
            bundleName: BUNDLE_NAME,
            abilityName: 'EntryAbility',
          };
          ctx.startAbility(want).catch((e: Object) => {
            Log.w('Hotkey', `start ability failed: ${Log.err(e)}`);
          });
        } else {
          win.minimize().catch((e: Object) => {
            Log.w('Hotkey', `minimize failed: ${Log.err(e)}`);
          });
        }
      } catch (e) {
        Log.w('Hotkey', `window status failed: ${Log.err(e as Object)}`);
      }
    }).catch((e: Object) => {
      Log.w('Hotkey', `get window failed: ${Log.err(e)}`);
    });
  }

  private static emitNotice(status: string): void {
    if (status.length === 0) {
      return;
    }
    const bridge = AppBridge.activeBridge;
    if (bridge === null) {
      return;
    }
    const payload: string[] = [status, ''];
    bridge.emit('verge://notice-message', payload);
  }

  /**
   * 把当前内核里的 mode 落盘（`verge/clash-mode.txt`）。
   *
   * TUN 开关会触发整核重载（日志里的 `config loaded by child`），重载只吃
   * 「订阅原文 + runtime-overrides.json」。模式若没落盘，重载后就会回落到
   * 订阅里的 mode / mihomo 默认 `rule` —— 主人看到的就是「一开/关虚拟网卡，
   * 模式自动跳到规则」。
   */
  private static async persistLiveMode(): Promise<void> {
    const config = await AppBridge.readCoreConfig();
    if (config !== null) {
      const mode = config['mode'];
      if (typeof mode === 'string') {
        AppBridge.clashMode = mode as string;
        RuntimeConfig.writeMode(mode as string);
        return;
      }
    }
    // 内核没通（正在重启）时**什么都不做**：
    // clashMode 的初值是 'rule'，拿它兜底会把用户已落盘的 global/direct 冲掉；
    // 落盘文件本身才是权威记录，保持原样最安全。
    Log.w('Clash', 'persistLiveMode: core unreachable, keep persisted mode as-is');
  }

  private static async toggleTun(enable: boolean, verge: VergeConfig): Promise<void> {
    const ctx = AppBridge.context;
    if (ctx === null) {
      return;
    }
    if (enable) {
      // ⚠️ 必须在 RuntimeConfig.write / ensureStarted 之前：那两步会重载内核
      await AppBridge.persistLiveMode();
      const current = ProfileStore.current();
      const content = current === null ? '' : ProfileStore.readContent(current.uid);
      const path = RuntimeConfig.write(AppBridge.secret, verge, content);
      const error = await TunController.start(path, 'mips', ctx);
      if (error.length > 0) {
        const revert: Record<string, Object | null> = {};
        revert['enable_tun_mode'] = false;
        verge.patch(revert);
        AppBridge.syncAppHttpProxy(verge.getNumber('verge_mixed_port', 7890));
        AppBridge.notifyClashConfigChanged();
        return;
      }
      BackgroundKeeper.start(ctx);
    } else {
      await TunController.stop();
      // 关 TUN 时把"释放长时任务"往后挪 1.2s：
      // 主人在托盘面板里点关闭，面板会跟着消失（疑似停掉 VPN 扩展 + 释放长时任务后，
      // 系统把这个扩展窗口一起收了）。先让开关状态落一帧，再收后台任务。
      Log.i('Tray', 'tun off: stop vpn extension done, release background task in 1200ms');
      setTimeout((): void => {
        BackgroundKeeper.stop(ctx).catch((e: Object) => {
          Log.w('Tray', `stop background task failed: ${Log.err(e)}`);
        });
      }, 1200);
    }
    AppBridge.syncAppHttpProxy(verge.getNumber('verge_mixed_port', 7890));
    // 让前端重新拉运行态/配置；TUN 开关读的是 verge.enable_tun_mode，必须同时刷新
    AppBridge.notifyClashConfigChanged();
  }

  // ---- 手动选中的节点（重载后要重新 PUT 一次，否则回到配置默认）----

  private static selectionPath(): string {
    return AppCtx.path('verge/selected-nodes.json');
  }

  /** 读取已落盘的「Clash 设置」补丁（供 patch_clash_config 合并用） */
  private static readClashConfigFile(): Record<string, Object | null> {
    const raw = FsUtil.readText(AppCtx.path('verge/clash-config.json'));
    if (raw.length === 0) {
      return {};
    }
    try {
      return JSON.parse(raw) as Record<string, Object | null>;
    } catch (e) {
      Log.w('Clash', `clash-config.json parse failed: ${Log.err(e as Object)}`);
      return {};
    }
  }

  private static readSelections(): Record<string, string> {
    const raw = FsUtil.readText(AppBridge.selectionPath());
    const out: Record<string, string> = {};
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object | null>;
      const keys = Object.keys(parsed);
      for (let i = 0; i < keys.length; i++) {
        const value = parsed[keys[i]];
        if (typeof value === 'string') {
          out[keys[i]] = value as string;
        }
      }
    } catch (e) {
      Log.w('Proxy', `parse selections failed: ${Log.err(e as Object)}`);
    }
    return out;
  }

  private static recordSelection(group: string, node: string): void {
    const map = AppBridge.readSelections();
    map[group] = node;
    FsUtil.writeText(AppBridge.selectionPath(), JSON.stringify(map));
  }

  private static forgetSelection(group: string): void {
    // ArkTS 不支持 delete，重建一份
    const map = AppBridge.readSelections();
    const rebuilt: Record<string, string> = {};
    const keys = Object.keys(map);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== group) {
        rebuilt[keys[i]] = map[keys[i]];
      }
    }
    FsUtil.writeText(AppBridge.selectionPath(), JSON.stringify(rebuilt));
  }

  /** 重载后把记下来的选择重新下发（延迟等内核把 group 建好） */
  private static replaySelections(): void {
    const map = AppBridge.readSelections();
    const groups = Object.keys(map);
    if (groups.length === 0) {
      return;
    }
    setTimeout(() => {
      for (let i = 0; i < groups.length; i++) {
        const group = groups[i];
        const body = JSON.stringify({ name: map[group] });
        const url = `http://127.0.0.1:${CONTROLLER_PORT}/proxies/${encodeURIComponent(group)}`;
        HttpClient.request(url, http.RequestMethod.PUT, body, AppBridge.coreHeaders(), 5000)
          .catch((e: Object) => {
            Log.w('Proxy', `replay ${group} failed: ${Log.err(e)}`);
          });
      }
    }, 3000);
  }

  /**
   * 写运行时配置；若 VPN 已在运行，则发重载信号让扩展进程重新 load + start_tun。
   * 这样"换订阅 / 改配置"不需要用户手动关再开。
   */
  private static async applyRuntime(verge: VergeConfig): Promise<string> {
    const current = ProfileStore.current();
    const content = current === null ? '' : ProfileStore.readContent(current.uid);
    const path = RuntimeConfig.write(AppBridge.secret, verge, content);
    if (!RuntimeConfig.lastChanged) {
      // 内容与磁盘一致（前端常在几秒内连触发好几次）→ 不要重载内核。
      // 一次 reload 就是整核重启：监听器全断、现有连接被踢。
      return path;
    }
    // 内核在**独立子进程**里：这里只写 reload.json（带 seq），子进程发现变化后
    // 自己 load；如果 TUN 本来是开着的，子进程会用同一个 tunfd 自动重挂
    // （见 bridge/child.go: childApplyReload）。所以这边不需要再管 fd。
    CoreHost.applyConfig(path);
    AppBridge.replaySelections();
    return path;
  }

  /**
   * 启动时对账：verge 里记着 enable_tun_mode=true 但实际没连上时，
   * 要么把它拉起来，要么把开关修正为 false（避免界面"显示已开启、实际没代理"）。
   */
  static async reconcileRuntime(): Promise<void> {
    const verge = AppBridge.verge;
    const ctx = AppBridge.context;
    if (verge === null || ctx === null) {
      return;
    }
    const wantTun = verge.getBool('enable_tun_mode', false);
    const connected = TunController.connected();
    // 扩展活着 ≠ 内核在收它的 fd：应用重启后旧子进程已死、扩展可能还活着，
    // 这时 connected=true 但新内核的 tun=false，必须重挂，否则界面“已连接”、实际全断。
    const coreTun = CoreHost.tunUp();
    if (wantTun && (!connected || !coreTun)) {
      Log.i('Runtime', `reconcile: want tun but connected=${connected} coreTun=${coreTun}, starting`);
      if (connected) {
        await TunController.stop();
      }
      await AppBridge.toggleTun(true, verge);
    } else if (!wantTun && connected) {
      Log.i('Runtime', 'reconcile: tun running but disabled in config, stopping');
      await TunController.stop();
      await BackgroundKeeper.stop(ctx);
    }
  }

  /** 托盘菜单 → 前端 HashRouter 页面 */
  static navigateTray(path: string): void {
    const bridge = AppBridge.activeBridge;
    if (bridge === null) {
      return;
    }
    bridge.runJs(`window.__cgTrayNavigate && window.__cgTrayNavigate(${JSON.stringify(path)});`);
  }

  private static async copyClashEnv(verge: VergeConfig): Promise<void> {
    let port = verge.getNumber('verge_mixed_port', 7890);
    const core = await AppBridge.readCoreConfig();
    if (core !== null) {
      const live = core['mixed-port'] ?? core['mixedPort'];
      if (typeof live === 'number') {
        port = live as number;
      }
    }
    const ip = verge.getString('proxy_host', '127.0.0.1');
    let envType = verge.getString('env_type', 'sh');
    if (envType.length === 0 || envType === 'stable') {
      envType = 'sh';
    }
    const httpProxy = `http://${ip}:${port}`;
    const socks5Proxy = `socks5://${ip}:${port}`;
    let text = '';
    if (envType === 'sh' || envType === 'bash' || envType === 'zsh') {
      text = `export https_proxy=${httpProxy} http_proxy=${httpProxy} all_proxy=${socks5Proxy}`;
    } else if (envType === 'fish') {
      text = `set -x http_proxy ${httpProxy}; set -x https_proxy ${httpProxy}`;
    } else if (envType === 'nushell') {
      text = `load-env { http_proxy: "${httpProxy}", https_proxy: "${httpProxy}" }`;
    } else if (envType === 'cmd') {
      text = `set http_proxy=${httpProxy}\r\nset https_proxy=${httpProxy}`;
    } else if (envType === 'powershell') {
      text = `$env:HTTP_PROXY="${httpProxy}"; $env:HTTPS_PROXY="${httpProxy}"`;
    } else {
      text = `export https_proxy=${httpProxy} http_proxy=${httpProxy} all_proxy=${socks5Proxy}`;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    // ⚠️ 写剪贴板在个别机型上会长时间不 resolve（真机反馈"点了没反应"），
    // 这里给它 1.2s 上限：超时就当成功（内容其实已经交给系统），别把整条命令挂住，
    // 否则前端的成功提示永远不会弹。
    let wrote = false;
    let pasteErr = '';
    const write = pasteboard.getSystemPasteboard().setData(data).then((): void => {
      wrote = true;
    }).catch((e: Object): void => {
      pasteErr = Log.err(e);
      Log.w('Env', `pasteboard setData failed: ${pasteErr}`);
    });
    await Promise.race([
      write,
      new Promise<void>((resolve: () => void): void => {
        setTimeout((): void => {
          resolve();
        }, 1200);
      }),
    ]);
    if (pasteErr.length > 0) {
      // 写剪贴板真的失败：抛出去，让前端弹错误，而不是假装成功
      throw new Error(`clipboard: ${pasteErr}`);
    }
    Log.i('Env', `copied ${envType} proxy env (port=${port}) resolved=${wrote}`);
  }

  // ---------------- 内核 / 运行时 ----------------

  private static installClash(bridge: JsBridge, verge: VergeConfig): void {
    bridge.register('get_clash_info', async (): Promise<Object | null> => {
      const info: Record<string, Object | null> = {};
      info['mixed_port'] = verge.getNumber('verge_mixed_port', 7890);
      info['socks_port'] = verge.getNumber('verge_socks_port', 7891);
      info['port'] = verge.getNumber('verge_port', 7897);
      info['server'] = `127.0.0.1:${CONTROLLER_PORT}`;
      info['secret'] = AppBridge.secret;
      return info;
    });

    // 复制当前代理环境变量：鸿蒙侧默认 POSIX sh/zsh；Windows 的 cmd/powershell 仍保留兼容。
    bridge.register('copy_clash_env', async (): Promise<Object | null> => {
      await AppBridge.copyClashEnv(verge);
      return null;
    });

    // 前端在 data-tauri-drag-region 元素上按下鼠标 → 拖窗口（详见 startWindowMoving 注释）
    bridge.register('plugin:window|start_dragging', async (): Promise<Object | null> => {
      AppBridge.startWindowMoving();
      return null;
    });

    // 双击标题栏 = 最大化 / 还原（系统标题栏被隐藏后，系统不再处理这个手势）
    bridge.register('plugin:window|toggle_maximize', async (): Promise<Object | null> => {
      AppBridge.toggleWindowMaximize();
      return null;
    });

    bridge.register('get_clash_mode', async (): Promise<Object | null> => {
      const config = await AppBridge.readCoreConfig();
      if (config !== null) {
        const mode = config['mode'];
        if (typeof mode === 'string') {
          AppBridge.clashMode = mode as string;
        }
      }
      return AppBridge.clashMode;
    });

    bridge.register('patch_clash_mode', async (args: Record<string, Object>): Promise<Object | null> => {
      const payload = args['payload'];
      if (typeof payload === 'string') {
        AppBridge.clashMode = payload as string;
        // 落盘：TUN 开关/换订阅都会重载内核，不落盘就会被订阅里的 mode 冲掉
        RuntimeConfig.writeMode(payload as string);
        const patch: Record<string, Object | null> = {};
        patch['mode'] = payload;
        await AppBridge.patchCoreConfig(patch);
        const bridge = AppBridge.activeBridge;
        if (bridge !== null) {
          const empty: Record<string, Object | null> = {};
          bridge.emit('verge://refresh-clash-config', empty);
        }
      }
      return null;
    });

    bridge.register('patch_clash_config', async (args: Record<string, Object>): Promise<Object | null> => {
      const payload = args['payload'];
      if (payload !== undefined && payload !== null) {
        // 前端每次只发「变化的字段」，所以落盘要**合并**而不是覆盖，
        // 否则第二次改设置会把第一次的改动冲掉。
        // 这份文件由 RuntimeConfig.overrides() 合并进运行时配置，重载后仍然生效。
        const patch = payload as Record<string, Object | null>;
        const merged = AppBridge.readClashConfigFile();
        const keys = Object.keys(patch);
        for (let i = 0; i < keys.length; i++) {
          merged[keys[i]] = patch[keys[i]];
        }
        FsUtil.writeText(AppCtx.path('verge/clash-config.json'), JSON.stringify(merged));
        await AppBridge.patchCoreConfig(patch);
      }
      return null;
    });

    // 与上游 runtime.rs 的语义一致：返回**内核运行时配置**（YamlMapping），不是 VPN 状态。
    // 前端 useClash() 会读 clash?.tun[...] / mixed-port / mode 等字段；返回状态对象会
    // 让 TUN 设置弹窗在 `clash.tun['auto-route']` 上直接抛 TypeError。
    bridge.register('get_runtime_config', async (): Promise<Object | null> => {
      const config = await AppBridge.readCoreConfig();
      if (config !== null) {
        return config;
      }
      // 内核尚未起来时返回 null（useClash 会走 `clash ?? {}` 空态）；
      // 启动失败原因由 get_core_startup_error / get_runtime_state 提供。
      return null;
    });

    bridge.register('get_runtime_state', async (): Promise<Object | null> => {
      const status = RuntimeStatusStore.read();
      const state: Record<string, Object | null> = {};
      // 内核常驻子进程 = 上游的 Service 模式；不要用「TUN 是否连着」判断，
      // 否则没开 TUN 时界面认为内核没在跑（系统代理/重启内核等入口的判断会错）。
      state['mode'] = CoreHost.alive() ? 'Service' : 'NotRunning';
      state['service'] = 'ready';
      state['serviceUnavailableReason'] = null;
      state['pendingAction'] = null;
      state['sidecarAllowed'] = false;
      state['isAdmin'] = false;
      state['opInFlight'] = false;
      // 鸿蒙没有桌面端的「服务模式」：serviceUsable=true 会让 TUN 行多出
      // 「卸载服务」图标，并被 shim 的 capability gate 打上「鸿蒙暂不支持」，
      // 看起来像 TUN 本身不支持。TUN 能力由 tunCapable 单独表达。
      state['serviceUsable'] = false;
      state['tunCapable'] = true;
      state['serviceNeedsAttention'] = false;
      return state;
    });

    bridge.register('get_runtime_yaml', async (): Promise<Object | null> => {
      return FsUtil.readText(AppCtx.path(FILE_RUNTIME_YAML));
    });

    // RuntimeLogs 结构：{ [文件名]: [ [时间, 内容], ... ] }
    bridge.register('get_runtime_logs', async (): Promise<Object | null> => {
      const logs: Record<string, Object | null> = {};
      const file = AppCtx.path('verge/logs/app.log');
      const text = FsUtil.readText(file);
      const rows: Object[] = [];
      if (text.length > 0) {
        const lines = text.split('\n');
        const start = lines.length > 400 ? lines.length - 400 : 0;
        for (let i = start; i < lines.length; i++) {
          const line = lines[i];
          if (line.length === 0) {
            continue;
          }
          const pair: string[] = [AppBridge.timeOfLine(line), line];
          rows.push(pair);
        }
      }
      logs['app.log'] = rows;
      return logs;
    });

    bridge.register('restart_core', async (): Promise<Object | null> => {
      // 「重启内核」的实际语义（已核对 core/mihomo/hub/hub.go）：
      //   hub.Parse → ApplyConfig → executor.ApplyConfig(cfg, force=true)
      // force=true 会 ReCreate：关闭所有 inbound / 监听器 / DNS / 现有连接后按新配置重建，
      // 与"换个进程重新起"在隧道层等价；只有 Go 进程与 pid 不换（内存不会立刻归还）。
      //
      // 这里额外等控制器真的回来再返回：ReCreate 期间 9090 会短暂不可用，
      // 之前是 fire-and-forget，前端 toast 立刻弹"已重启"，其实内核还在重建。
      const current = ProfileStore.current();
      const content = current === null ? '' : ProfileStore.readContent(current.uid);
      const path = RuntimeConfig.write(AppBridge.secret, verge, content);
      const started = Date.now();
      CoreHost.forceApplyConfig(path);
      Log.i('CoreHost', 'restart_core: force reload requested (ReCreate)');
      await new Promise<void>((resolve: () => void): void => {
        setTimeout((): void => {
          resolve();
        }, 250);
      });
      let back = false;
      for (let i = 0; i < 25; i++) {
        const cfg = await AppBridge.readCoreConfig();
        if (cfg !== null) {
          back = true;
          break;
        }
        await new Promise<void>((resolve: () => void): void => {
          setTimeout((): void => {
            resolve();
          }, 200);
        });
      }
      Log.i('CoreHost', `restart_core ${back ? 'completed' : 'timeout'} in ${Date.now() - started}ms`);
      return null;
    });

    bridge.register('get_core_startup_error', async (): Promise<Object | null> => {
      // ⚠️ 返回类型是 CoreFailure | null（{kind,detail}），不是字符串。
      // 旧实现读的是 vpn-status.json 的 lastError（上一次扩展销毁时留下
      // "vpn extension destroyed"），页面挂载时就会误报「启动内核失败」，
      // 过几秒内核起来后又自己消失（真机反馈的假告警）。
      const st = CoreHost.status();
      if (st !== null && st.phase === 'load-failed' && st.error.length > 0) {
        const failure: Record<string, Object | null> = {};
        failure['kind'] = 'startFailed';
        failure['detail'] = st.error;
        return failure;
      }
      const startError = CoreHost.lastStartError();
      if (startError.length > 0) {
        const failure: Record<string, Object | null> = {};
        failure['kind'] = 'startFailed';
        failure['detail'] = startError;
        return failure;
      }
      return null;
    });

    bridge.register('test_delay', async (args: Record<string, Object>): Promise<Object | null> => {
      const url = args['url'];
      const target = typeof url === 'string' ? url as string : 'https://www.gstatic.com/generate_204';
      const started = Date.now();
      const result = await HttpClient.request(target, http.RequestMethod.GET, '', {}, 5000);
      const delay = result.error.length > 0 ? 0 : Date.now() - started;
      const out: Record<string, Object | null> = {};
      out['delay'] = delay;
      out['meanDelay'] = delay;
      return out;
    });

    // ---- 节点选择（代理页点击节点走这里，别再当 noop）----

    bridge.register('switch_proxy_node', async (args: Record<string, Object>): Promise<Object | null> => {
      const groupName = args['groupName'];
      const proxyName = args['proxyName'];
      const unfix = args['unfix'] === true;
      if (typeof groupName !== 'string') {
        return null;
      }
      const group = groupName as string;
      if (!unfix && typeof proxyName !== 'string') {
        return null;
      }

      // 本地先记账（重启后回放用），再把 PUT 丢进后台队列 —— 立即返回。
      //
      // 为什么不再 await：测速时内核会被几百个并发探测占满（mihomo 的
      // GroupBase.URLTest 对每个节点开一条 goroutine，无并发上限），
      // PUT /proxies/{group} 实测要 3.4–5s，甚至超时（日志 18:14:08/18:14:25）。
      // 让 UI 等它 = "点了没反应"；现在前端做乐观更新，这里只保证最终落地。
      if (unfix) {
        AppBridge.forgetSelection(group);
      } else {
        AppBridge.recordSelection(group, proxyName as string);
      }
      AppBridge.enqueueProxyTask(group, (): Promise<void> =>
        AppBridge.applyProxySelection(group, proxyName as string, unfix));
      return null;
    });

    bridge.register('record_selected_node', async (args: Record<string, Object>): Promise<Object | null> => {
      const groupName = args['groupName'];
      const node = args['node'];
      if (typeof groupName === 'string' && typeof node === 'string') {
        AppBridge.recordSelection(groupName as string, node as string);
        AppBridge.emitProxyRefresh();
      }
      return null;
    });

    bridge.register('sync_runtime_providers', async (): Promise<Object | null> => null);

    // 应用日志（hilog 同步写内存环形缓冲 + verge/logs/app.log）
    // 行格式与 mihomo 的 logrus 文本一致，前端 getClashLogs 的正则才能解析出内容
    bridge.register('get_clash_logs', async (): Promise<Object | null> => {
      return Log.snapshot();
    });

    // 无 updater：直接告知"已取消"，并给 Channel 补结束帧，避免回调泄漏
    bridge.register('install_update', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['__channels'];
      if (raw !== undefined && raw !== null) {
        const channels = raw as number[];
        const bridge = AppBridge.activeBridge;
        if (bridge !== null) {
          for (let i = 0; i < channels.length; i++) {
            bridge.channelSend(channels[i], 0, '', true);
          }
        }
      }
      const outcome: Record<string, Object | null> = {};
      outcome['status'] = 'cancelled';
      return outcome;
    });
  }

  // ---- 内核控制面（mihomo REST）----

  /**
   * 让前端立刻重拉 `getProxyView`。
   *
   * 为什么要手动发：代理页的数据是 `useQuery(['getProxyView'], { refetchInterval: 15000 })`，
   * 也就是**15 秒才轮询一次**，而且 `refetchIntervalInBackground:false` —— 窗口失焦时
   * 连这个轮询都会停。上游 Tauri 后端切完节点会发事件，我们之前没发，
   * 表现就是「点了节点没反应，过一会儿 / 点别的地方才刷新」。
   */
  /** 同一个组的 PUT/DELETE 串行执行，保证连点时的落点顺序 */
  private static enqueueProxyTask(group: string, task: () => Promise<void>): void {
    const prev = AppBridge.proxyQueue.get(group);
    const start: Promise<void> = prev === undefined ? Promise.resolve() : prev;
    const next: Promise<void> = start.then(task, task).catch((e: Object): void => {
      Log.w('Proxy', `queued task failed: ${Log.err(e)}`);
    }).then((): void => {
      if (AppBridge.proxyQueue.get(group) === next) {
        AppBridge.proxyQueue.delete(group);
      }
    });
    AppBridge.proxyQueue.set(group, next);
  }

  /**
   * 真正把选择写给内核。
   *
   * 超时给到 15s：内核在跑批量测速时响应会慢到 3–5s，原来 5s 会把请求掐掉
   * （日志里 `failed code=0 5051ms` 就是这个），用户看到的是"切不过去"。
   */
  private static async applyProxySelection(group: string, proxyName: string, unfix: boolean): Promise<void> {
    const startedAt = Date.now();
    const url = `http://127.0.0.1:${CONTROLLER_PORT}/proxies/${encodeURIComponent(group)}`;
    if (unfix) {
      const del = await HttpClient.request(url, http.RequestMethod.DELETE, '',
        AppBridge.coreHeaders(), 15000);
      Log.i('Proxy', `unfix ${group}: code=${del.code} ${Date.now() - startedAt}ms`);
      AppBridge.emitProxyRefresh();
      return;
    }
    const body = JSON.stringify({ name: proxyName });
    let result = await HttpClient.request(url, http.RequestMethod.PUT, body,
      AppBridge.coreHeaders(), 15000);
    if (result.code === 0) {
      Log.w('Proxy', `select ${group} -> ${proxyName} timeout, retry once`);
      result = await HttpClient.request(url, http.RequestMethod.PUT, body,
        AppBridge.coreHeaders(), 15000);
    }
    if (result.code < 200 || result.code >= 300) {
      Log.w('Proxy', `select ${group} -> ${proxyName} failed code=${result.code} ${Date.now() - startedAt}ms`);
    } else {
      Log.i('Proxy', `select ${group} -> ${proxyName} ok in ${Date.now() - startedAt}ms`);
    }
    AppBridge.emitProxyRefresh();
  }

  private static emitProxyRefresh(): void {
    const bridge = AppBridge.activeBridge;
    if (bridge === null) {
      return;
    }
    const payload: Record<string, Object | null> = {};
    bridge.emit('verge://refresh-proxy-config', payload);
  }

  private static coreHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['Content-Type'] = 'application/json';
    if (AppBridge.secret.length > 0) {
      headers['Authorization'] = `Bearer ${AppBridge.secret}`;
    }
    return headers;
  }

  private static async patchCoreConfig(payload: Record<string, Object | null>): Promise<void> {
    const url = `http://127.0.0.1:${CONTROLLER_PORT}/configs`;
    // compatibleSdkVersion 已对齐 26，PATCH 枚举合法，直接用原生枚举（有类型保障）
    const result = await HttpClient.request(url, http.RequestMethod.PATCH, JSON.stringify(payload),
      AppBridge.coreHeaders(), 4000);
    if (result.error.length > 0) {
      Log.w('Clash', `PATCH /configs failed: ${result.error}`);
    }
  }

  private static async readCoreConfig(): Promise<Record<string, Object | null> | null> {
    const url = `http://127.0.0.1:${CONTROLLER_PORT}/configs`;
    // 6s：同上，测速期间控制器响应会慢
    const result = await HttpClient.request(url, http.RequestMethod.GET, '', AppBridge.coreHeaders(), 6000);
    if (result.error.length > 0 || result.code !== 200) {
      return null;
    }
    try {
      return JSON.parse(result.body) as Record<string, Object | null>;
    } catch (e) {
      return null;
    }
  }

  // ---------------- 备份（本地；WebDAV 见下一轮） ----------------

  private static installBackup(bridge: JsBridge, verge: VergeConfig): void {
    bridge.register('create_local_backup', async (): Promise<Object | null> => {
      try {
        await BackupService.create();
      } catch (e) {
        Log.e('Backup', `create failed: ${Log.err(e as Object)}`);
      }
      return null;
    });

    bridge.register('list_local_backup', async (): Promise<Object | null> => BackupService.list());

    bridge.register('delete_local_backup', async (args: Record<string, Object>): Promise<Object | null> => {
      const filename = args['filename'];
      if (typeof filename === 'string') {
        BackupService.remove(filename as string);
      }
      return null;
    });

    bridge.register('restore_local_backup', async (args: Record<string, Object>): Promise<Object | null> => {
      const filename = args['filename'];
      if (typeof filename !== 'string') {
        return null;
      }
      const error = await BackupService.restore(filename as string);
      if (error.length === 0) {
        // 恢复后让内存缓存失效，下一次读取拿新数据
        verge.reload();
        ProfileStore.resetCache();
        Log.i('Backup', 'caches invalidated after restore');
      }
      return null;
    });

    bridge.register('import_local_backup', async (args: Record<string, Object>): Promise<Object | null> => {
      const source = args['source'];
      if (typeof source !== 'string') {
        return '';
      }
      return BackupService.importFrom(source as string);
    });

    bridge.register('export_local_backup', async (args: Record<string, Object>): Promise<Object | null> => {
      const filename = args['filename'];
      const destination = args['destination'];
      if (typeof filename !== 'string' || typeof destination !== 'string') {
        return null;
      }
      BackupService.exportTo(filename as string, destination as string);
      return null;
    });

    // ---- WebDAV ----

    bridge.register('save_webdav_config', async (args: Record<string, Object>): Promise<Object | null> => {
      const url = args['url'];
      const username = args['username'];
      const password = args['password'];
      WebDavService.saveConfig(verge,
        typeof url === 'string' ? url as string : '',
        typeof username === 'string' ? username as string : '',
        typeof password === 'string' ? password as string : '');
      return null;
    });

    bridge.register('create_webdav_backup', async (): Promise<Object | null> => {
      const error = await WebDavService.create(verge);
      if (error.length > 0) {
        Log.w('WebDav', `create failed: ${error}`);
        throw new Error(error);
      }
      return null;
    });

    bridge.register('list_webdav_backup', async (): Promise<Object | null> => WebDavService.list(verge));

    bridge.register('delete_webdav_backup', async (args: Record<string, Object>): Promise<Object | null> => {
      const filename = args['filename'];
      if (typeof filename !== 'string') {
        return null;
      }
      const error = await WebDavService.remove(verge, filename as string);
      if (error.length > 0) {
        throw new Error(error);
      }
      return null;
    });

    bridge.register('restore_webdav_backup', async (args: Record<string, Object>): Promise<Object | null> => {
      const filename = args['filename'];
      if (typeof filename !== 'string') {
        return null;
      }
      const error = await WebDavService.restore(verge, filename as string);
      if (error.length > 0) {
        throw new Error(error);
      }
      verge.reload();
      ProfileStore.resetCache();
      return null;
    });
  }

  // ---------------- 配置库 ----------------

  private static installProfiles(bridge: JsBridge, verge: VergeConfig): void {
    bridge.register('get_profiles', async (): Promise<Object | null> => {
      const items: Record<string, Object | null>[] = [];
      const all = ProfileStore.all();
      for (let i = 0; i < all.length; i++) {
        const item = all[i];
        const rec: Record<string, Object | null> = {};
        rec['uid'] = item.uid;
        rec['type'] = item.type;
        rec['name'] = item.name;
        rec['desc'] = item.desc;
        rec['url'] = item.url;
        rec['file'] = item.file;
        rec['updated'] = item.updated;
        rec['option'] = null;
        items.push(rec);
      }
      const current = ProfileStore.currentUid();
      const result: Record<string, Object | null> = {};
      result['current'] = current.length > 0 ? current : null;
      result['items'] = items;
      result['chain'] = [];
      return result;
    });

    bridge.register('patch_profiles_config', async (args: Record<string, Object>): Promise<Object | null> => {
      const current = args['current'];
      const outcome: Record<string, Object | null> = {};
      if (typeof current !== 'string') {
        // 前端会把结果当 ValidationOutcome 读 .status，返回 null 会直接 TypeError
        outcome['status'] = 'skipped';
        outcome['reason'] = 'empty';
        return outcome;
      }
      ProfileStore.setCurrent(current as string);
      // 切换配置后立刻把新配置写盘并通知扩展进程热重载（用户在 TUN 开启状态下切订阅的场景）
      await AppBridge.applyRuntime(verge);
      outcome['status'] = 'valid';
      return outcome;
    });

    bridge.register('view_profile', async (args: Record<string, Object>): Promise<Object | null> => {
      const index = args['index'];
      const item = typeof index === 'string' ? ProfileStore.find(index as string) : null;
      if (item === null) {
        return null;
      }
      const info: Record<string, Object | null> = {};
      info['uid'] = item.uid;
      info['type'] = item.type;
      info['name'] = item.name;
      info['file'] = item.file;
      return info;
    });

    bridge.register('read_profile_file', async (args: Record<string, Object>): Promise<Object | null> => {
      const index = args['index'];
      if (typeof index !== 'string') {
        return '';
      }
      return ProfileStore.readContent(index as string);
    });

    bridge.register('save_profile_file', async (args: Record<string, Object>): Promise<Object | null> => {
      const index = args['index'];
      const fileData = args['fileData'];
      if (typeof index === 'string' && typeof fileData === 'string') {
        ProfileStore.writeContent(index as string, fileData as string);
        const item = ProfileStore.find(index as string);
        if (item !== null) {
          item.updated = Math.floor(Date.now() / 1000);
          ProfileStore.save();
        }
      }
      const outcome: Record<string, Object | null> = {};
      outcome['status'] = 'valid';
      return outcome;
    });

    bridge.register('create_profile', async (args: Record<string, Object>): Promise<Object | null> => {
      const item = args['item'] as Record<string, Object | null>;
      const fileData = args['fileData'];
      if (item === undefined || item === null) {
        return null;
      }
      const type = item['type'];
      const name = item['name'];
      const desc = item['desc'];
      const url = item['url'];
      const option = item['option'];
      const created = ProfileStore.create(
        typeof type === 'string' ? type as string : 'local',
        typeof name === 'string' ? name as string : 'New Profile',
        typeof desc === 'string' ? desc as string : '',
        typeof url === 'string' ? url as string : '',
        typeof fileData === 'string' ? fileData as string : '');
      if (option !== undefined && option !== null) {
        created.option = JSON.stringify(option);
        ProfileStore.save();
      }
      return null;
    });

    bridge.register('import_profile', async (args: Record<string, Object>): Promise<Object | null> => {
      const url = args['url'];
      if (typeof url !== 'string') {
        return null;
      }
      const option = args['option'];
      const created = ProfileStore.create('remote', AppBridge.nameFromUrl(url as string), '', url as string, '');
      if (option !== undefined && option !== null) {
        created.option = JSON.stringify(option);
      }
      const error = await ProfileStore.download(created);
      if (error.length > 0) {
        Log.w('Profiles', `import failed: ${error}`);
        ProfileStore.remove(created.uid);
      }
      return null;
    });

    bridge.register('update_profile', async (args: Record<string, Object>): Promise<Object | null> => {
      const index = args['index'];
      if (typeof index !== 'string') {
        return null;
      }
      const item = ProfileStore.find(index as string);
      if (item === null) {
        return null;
      }
      const error = await ProfileStore.download(item);
      if (error.length > 0) {
        Log.w('Profiles', `update failed: ${error}`);
      }
      return null;
    });

    bridge.register('delete_profile', async (args: Record<string, Object>): Promise<Object | null> => {
      const index = args['index'];
      if (typeof index === 'string') {
        ProfileStore.remove(index as string);
      }
      return null;
    });

    bridge.register('reorder_profile', async (args: Record<string, Object>): Promise<Object | null> => {
      const activeId = args['activeId'];
      const overId = args['overId'];
      if (typeof activeId === 'string' && typeof overId === 'string') {
        ProfileStore.reorder(activeId as string, overId as string);
      }
      return null;
    });

    bridge.register('patch_profile', async (args: Record<string, Object>): Promise<Object | null> => {
      const index = args['index'];
      const profile = args['profile'] as Record<string, Object | null>;
      if (typeof index !== 'string' || profile === undefined || profile === null) {
        return null;
      }
      const item = ProfileStore.find(index as string);
      if (item === null) {
        return null;
      }
      const name = profile['name'];
      if (typeof name === 'string') {
        item.name = name as string;
      }
      const desc = profile['desc'];
      if (typeof desc === 'string') {
        item.desc = desc as string;
      }
      const option = profile['option'];
      if (option !== undefined && option !== null) {
        item.option = JSON.stringify(option);
      }
      ProfileStore.save();
      return null;
    });

    bridge.register('get_next_update_time', async (args: Record<string, Object>): Promise<Object | null> => {
      const uid = args['uid'];
      if (typeof uid !== 'string') {
        return null;
      }
      const next = ProfileScheduler.nextUpdate(uid as string);
      return next === null ? null : next;
    });

    bridge.register('enhance_profiles', async (): Promise<Object | null> => {
      await AppBridge.applyRuntime(verge);
      const outcome: Record<string, Object | null> = {};
      outcome['status'] = 'valid';
      return outcome;
    });
  }

  /** 与上游 clash-verge-media-unlock 的 UnlockCheck::ALL 对齐（13 项） */
  private static unlockNames(): string[] {
    const names: string[] = [
      'Bahamut Anime', '哔哩哔哩大陆', '哔哩哔哩港澳台', 'ChatGPT Web', 'Claude',
      'Disney+', 'Gemini', 'Muse AI', 'Netflix', 'Prime Video', 'Spotify', 'TikTok',
      'YouTube Premium',
    ];
    return names;
  }

  private static unlockItems(): Record<string, Object | null>[] {
    const names = AppBridge.unlockNames();
    const items: Record<string, Object | null>[] = [];
    for (let i = 0; i < names.length; i++) {
      const item: Record<string, Object | null> = {};
      item['name'] = names[i];
      // 检测逻辑尚未移植，返回上游的初始态（Pending），绝不伪造 Yes/No
      item['status'] = 'Pending';
      item['region'] = null;
      item['check_time'] = null;
      items.push(item);
    }
    return items;
  }

  private static emitUnlockProgress(args: Record<string, Object>, items: Record<string, Object | null>[]): void {
    const raw = args['__channels'];
    if (raw === undefined || raw === null) {
      return;
    }
    const channels = raw as number[];
    const bridge = AppBridge.activeBridge;
    if (bridge === null) {
      return;
    }
    for (let c = 0; c < channels.length; c++) {
      const id = channels[c];
      for (let i = 0; i < items.length; i++) {
        bridge.channelSend(id, i, JSON.stringify(items[i]), false);
      }
      bridge.channelSend(id, items.length, '', true);
    }
  }

  /** Tauri 路径变量 → 鸿蒙沙箱；相对路径按 filesDir 解析 */
  private static resolvePath(input: string): string {
    let path = input;
    if (path.startsWith('$APPDATA')) {
      path = `${AppCtx.filesDir}${path.substring('$APPDATA'.length)}`;
    } else if (path.startsWith('$APPLOCALDATA')) {
      path = `${AppCtx.filesDir}${path.substring('$APPLOCALDATA'.length)}`;
    } else if (path.startsWith('$APPCACHE')) {
      path = `${AppCtx.cacheDir}${path.substring('$APPCACHE'.length)}`;
    } else if (path.startsWith('$APPCONFIG')) {
      path = `${AppCtx.filesDir}${path.substring('$APPCONFIG'.length)}`;
    } else if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    } else if (!path.startsWith('/')) {
      path = `${AppCtx.filesDir}/${path}`;
    }
    return path;
  }

  private static nameFromUrl(url: string): string {
    const clean = url.split('?')[0];
    const parts = clean.split('/');
    const last = parts.length > 0 ? parts[parts.length - 1] : 'remote';
    return last.length > 0 ? last : 'remote';
  }

  // ---------------- 代理视图（ProxyViewV1）：从 mihomo /proxies 组装 ----------------

  /** 视为「分组」的 proxy type（与上游 Rust 侧判定一致；注意 Compatible 不是分组） */
  private static readonly GROUP_TYPES: string[] =
    ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay', 'Smart'];

  /** 内置节点/占位项：不作为用户节点展示，GLOBAL 单独走 `global` 字段 */
  private static readonly BUILTIN_NAMES: string[] =
    ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'PASS-RULE', 'COMPATIBLE', 'GLOBAL'];

  private static installProxyView(bridge: JsBridge): void {
    bridge.register('get_proxy_view', async (): Promise<Object | null> => {
      return await AppBridge.buildProxyView();
    });
  }

  /**
   * 组装 ProxyViewV1（结构见 webapp/src/services/bindings.ts）。
   *
   * 上游这份数据由 Rust 侧聚合（含 providers / capabilities / order source），
   * 鸿蒙侧只做「够用」的等价：groups + records + standalone + global + direct。
   * 内核没起来时返回空视图（schemaVersion 仍为 1），避免前端 `view.schemaVersion` 抛异常。
   */
  private static async buildProxyView(): Promise<Object | null> {
    // 内核没起来时直接返回空视图：前端每 15s 轮询一次这个命令，
    // 每次都去连 9090 会白等 4 秒超时并刷满失败日志。
    // 判据必须是「内核子进程活着」，不是「VPN 扩展连着」：
    // 没开 TUN 时内核照样常驻，代理页/节点选择必须可用。
    if (!CoreHost.alive()) {
      return AppBridge.emptyProxyView();
    }
    const headers: Record<string, string> = {};
    if (AppBridge.secret.length > 0) {
      headers['Authorization'] = `Bearer ${AppBridge.secret}`;
    }
    // 8s：内核在跑批量测速时 /proxies 可能被拖到 4s+（真机日志 18:14:08 就超时过），
    // 4s 会让代理页直接变空。
    const res = await HttpClient.request(`http://127.0.0.1:${CONTROLLER_PORT}/proxies`,
      http.RequestMethod.GET, '', headers, 8000);
    if (res.code !== 200 || res.body.length === 0) {
      return AppBridge.emptyProxyView();
    }
    let root: Record<string, Object> | null = null;
    try {
      root = JSON.parse(res.body) as Record<string, Object>;
    } catch (e) {
      root = null;
    }
    if (root === null) {
      return AppBridge.emptyProxyView();
    }
    const rawProxies = root['proxies'];
    if (rawProxies === undefined || rawProxies === null || typeof rawProxies !== 'object') {
      return AppBridge.emptyProxyView();
    }
    const proxies = rawProxies as Record<string, Record<string, Object>>;
    const names = Object.keys(proxies);

    // 第一遍：分出 group 与 node，给每个 node 建 record
    // 内置项（DIRECT/REJECT/PASS/COMPATIBLE…）**也要建 record**：GLOBAL/分组会把它们
    // 当作 member 引用，缺 record 时前端 resolveMember 直接抛
    // `Proxy view record not found: DIRECT`（真机 22:05 切全局模式必现）。
    // GLOBAL 本身单独走 view.global，不建 record。
    const records: Record<string, Object | null> = {};
    const groupNames: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      if (name === 'GLOBAL') {
        continue;
      }
      const item = proxies[name];
      if (item === undefined || item === null) {
        continue;
      }
      const type = AppBridge.strOf(item['type']);
      if (AppBridge.GROUP_TYPES.indexOf(type) >= 0) {
        groupNames.push(name);
        continue;
      }
      records[name] = AppBridge.nodeRecord(name, type, item);
    }

    // 第二遍：建 groups（成员引用需要知道哪些名字是 group，所以分两遍）
    const groups: Record<string, Object | null>[] = [];
    const referenced: Record<string, boolean> = {};
    for (let i = 0; i < groupNames.length; i++) {
      const gname = groupNames[i];
      const g = proxies[gname];
      if (g === undefined || g === null) {
        continue;
      }
      groups.push(AppBridge.groupRecord(gname, g, groupNames, referenced, records));
    }

    // standalone：既不是 group、也没被任何 group 引用的节点
    const standalone: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      if (groupNames.indexOf(name) >= 0) {
        continue;
      }
      if (AppBridge.BUILTIN_NAMES.indexOf(name) >= 0) {
        continue;
      }
      if (referenced[name] !== true) {
        standalone.push(name);
      }
    }

    const view: Record<string, Object | null> = {};
    view['schemaVersion'] = 1;
    view['orderSource'] = 'runtime';
    view['providerState'] = 'ready';
    const globalEntry = proxies['GLOBAL'];
    view['global'] = (globalEntry === undefined || globalEntry === null)
      ? null
      : AppBridge.groupRecord('GLOBAL', globalEntry, groupNames, referenced, records);
    view['direct'] = proxies['DIRECT'] !== undefined ? 'DIRECT' : null;
    view['groups'] = groups;
    view['records'] = records;
    view['standalone'] = standalone;
    const providers: Record<string, Object | null>[] = [];
    view['providers'] = providers;
    return view;
  }

  private static emptyProxyView(): Record<string, Object | null> {
    const view: Record<string, Object | null> = {};
    view['schemaVersion'] = 1;
    view['orderSource'] = 'runtime';
    view['providerState'] = 'ready';
    view['global'] = null;
    view['direct'] = 'DIRECT';
    const groups: Record<string, Object | null>[] = [];
    const records: Record<string, Object | null> = {};
    const standalone: string[] = [];
    const providers: Record<string, Object | null>[] = [];
    view['groups'] = groups;
    view['records'] = records;
    view['standalone'] = standalone;
    view['providers'] = providers;
    return view;
  }

  private static nodeRecord(name: string, type: string, item: Record<string, Object>): Record<string, Object | null> {
    const rec: Record<string, Object | null> = {};
    rec['recordId'] = name;
    rec['name'] = name;
    rec['type'] = type;
    rec['history'] = AppBridge.historyOf(item['history']);
    const source: Record<string, Object | null> = {};
    source['kind'] = 'core';
    source['proxyName'] = name;
    rec['source'] = source;
    rec['udp'] = item['udp'] === true;
    rec['xudp'] = false;
    rec['tfo'] = false;
    rec['mptcp'] = false;
    rec['smux'] = false;
    return rec;
  }

  private static groupRecord(name: string, item: Record<string, Object>, groupNames: string[],
    referenced: Record<string, boolean>, records: Record<string, Object | null>): Record<string, Object | null> {
    const gv: Record<string, Object | null> = {};
    gv['name'] = name;
    gv['type'] = AppBridge.strOf(item['type']);
    const now = AppBridge.strOf(item['now']);
    if (now.length > 0) {
      gv['now'] = now;
    }
    gv['history'] = AppBridge.historyOf(item['history']);

    const members: Record<string, Object | null>[] = [];
    const allRaw = item['all'];
    if (Array.isArray(allRaw)) {
      const arr = allRaw as Object[];
      for (let i = 0; i < arr.length; i++) {
        const memberName = String(arr[i]);
        const member: Record<string, Object | null> = {};
        if (groupNames.indexOf(memberName) >= 0) {
          member['kind'] = 'group';
          member['name'] = memberName;
        } else if (records[memberName] !== undefined && records[memberName] !== null) {
          member['kind'] = 'node';
          member['name'] = memberName;
          member['recordId'] = memberName;
          referenced[memberName] = true;
        } else {
          // 引用了内核里不存在的节点（配置切换/节点消失）：给前端一个可渲染的占位，
          // 不能让 resolveMember 抛异常把整个代理页打成错误弹窗。
          member['kind'] = 'unresolved';
          member['name'] = memberName;
          member['reason'] = 'missing';
        }
        members.push(member);
      }
    }
    gv['members'] = members;
    gv['udp'] = false;
    gv['xudp'] = false;
    gv['tfo'] = false;
    gv['mptcp'] = false;
    gv['smux'] = false;
    return gv;
  }

  private static historyOf(raw: Object | undefined): Record<string, Object | null>[] {
    const out: Record<string, Object | null>[] = [];
    if (!Array.isArray(raw)) {
      return out;
    }
    const arr = raw as Object[];
    for (let i = 0; i < arr.length; i++) {
      const src = arr[i];
      if (src === null || src === undefined || typeof src !== 'object') {
        continue;
      }
      const entry = src as Record<string, Object>;
      const item: Record<string, Object | null> = {};
      item['time'] = AppBridge.strOf(entry['time']);
      const delay = entry['delay'];
      item['delay'] = typeof delay === 'number' ? delay as number : 0;
      out.push(item);
    }
    return out;
  }

  private static strOf(value: Object | undefined | null): string {
    return typeof value === 'string' ? value as string : '';
  }

  /** 从 `time="..." level=... msg="..."` 里抠出时间，供 RuntimeLogs 的 [time, content] 用 */
  private static timeOfLine(line: string): string {
    const marker = 'time="';
    const i = line.indexOf(marker);
    if (i < 0) {
      return '';
    }
    const start = i + marker.length;
    const end = line.indexOf('"', start);
    if (end < 0) {
      return '';
    }
    return line.substring(start, end);
  }

  // ---------------- DNS 覆盖配置 ----------------

  /**
   * 上游这套命令的语义（`src-tauri/src/cmd/clash.rs`）：
   *   `save_dns_config(dnsConfig)` 收的是 **对象**（前端用 js-yaml parse 过 Monaco 里的文本）；
   *   `apply_dns_config(apply)` 只切开关；`validate_dns_config()` 校验的是文件。
   * 我们的合并在 Go 桥里做（ArkTS 无 YAML parser），这里只负责落盘与开关。
   */
  private static installDns(bridge: JsBridge): void {
    bridge.register('get_dns_config_content', async (): Promise<Object | null> => {
      return DnsConfig.read();
    });

    bridge.register('save_dns_config', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['dnsConfig'];
      if (raw === null || raw === undefined || typeof raw !== 'object') {
        throw new Error('invalid dnsConfig');
      }
      DnsConfig.save(raw as Record<string, Object | null>);
      return null;
    });

    bridge.register('apply_dns_config', async (args: Record<string, Object>): Promise<Object | null> => {
      const apply = args['apply'] === true;
      const error = DnsConfig.apply(apply);
      if (error.length > 0) {
        throw new Error(error);
      }
      return null;
    });

    bridge.register('validate_dns_config', async (): Promise<Object | null> => {
      return DnsConfig.validate();
    });

    // DNS 覆写开关是**按订阅**保存的（前端的开关值来自
// verge.profile_dns_settings[uid].enabled）。只切运行时不落盘的话，
// mutateVerge() 会立刻把开关弹回 off，下一次点击又当 enable=true 处理
// （真机 22:18–22:19 连点两次都是 apply=true 的原因）。
    bridge.register('set_dns_override', async (args: Record<string, Object>): Promise<Object | null> => {
      const enabled = args['enabled'] === true;
      const uidRaw = args['profileUid'];
      const uid = typeof uidRaw === 'string' ? uidRaw as string : '';
      const current = ProfileStore.currentUid();
      if (uid.length > 0 && current.length > 0 && uid !== current) {
        throw new Error('The active profile changed; retry the DNS setting');
      }
      const error = DnsConfig.apply(enabled);
      if (error.length > 0) {
        throw new Error(error);
      }
      const cfg = AppBridge.verge;
      if (cfg !== null && uid.length > 0) {
        const all = cfg.get();
        let settings = all['profile_dns_settings'];
        let map: Record<string, Object | null> = {};
        if (settings !== undefined && settings !== null && typeof settings === 'object') {
          map = settings as Record<string, Object | null>;
        }
        const entry: Record<string, Object | null> = {};
        entry['enabled'] = enabled;
        map[uid] = entry;
        const patch: Record<string, Object | null> = {};
        patch['profile_dns_settings'] = map;
        cfg.patch(patch);
      }
      const outcome: Record<string, Object | null> = {};
      outcome['status'] = 'applied';
      return outcome;
    });

    bridge.register('take_dns_override_notice', async (): Promise<Object | null> => false);
  }

  // ---------------- 图标缓存 / 诊断导出 ----------------

  private static installIconAndDiag(bridge: JsBridge): void {
    bridge.register('copy_icon_file', async (args: Record<string, Object>): Promise<Object | null> => {
      const path = args['path'];
      const info = args['iconInfo'];
      if (typeof path !== 'string' || (path as string).length === 0) {
        throw new Error('icon path is empty');
      }
      if (info === null || info === undefined || typeof info !== 'object') {
        throw new Error('invalid iconInfo');
      }
      return IconService.copyIcon(path as string, info as Record<string, Object | null>);
    });

    bridge.register('download_icon_cache', async (args: Record<string, Object>): Promise<Object | null> => {
      const url = args['url'];
      const name = args['name'];
      if (typeof url !== 'string' || (url as string).length === 0) {
        throw new Error('icon url is empty');
      }
      if (typeof name !== 'string' || (name as string).length === 0) {
        throw new Error('icon name is empty');
      }
      return await IconService.download(url as string, name as string);
    });

    // 上游就是「把诊断文本写进剪贴板」，这里照做
    bridge.register('export_diagnostic_info', async (): Promise<Object | null> => {
      await Diagnostic.exportToClipboard();
      return null;
    });
  }

  // ---------------- 未实现命令：返回空值，不阻塞 UI ----------------

  // ---------------- 链式代理 ----------------

  private static chainPath(): string {
    return AppCtx.path('verge/proxy-chain.json');
  }

  private static readChain(): string[] {
    const raw = FsUtil.readText(AppBridge.chainPath());
    const out: string[] = [];
    if (raw.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, Object | null>;
      const chain = parsed['chain'];
      if (chain !== undefined && chain !== null) {
        const arr = chain as string[];
        for (let i = 0; i < arr.length; i++) {
          if (typeof arr[i] === 'string' && arr[i].length > 0) {
            out.push(arr[i]);
          }
        }
      }
    } catch (e) {
      Log.w('Chain', `parse chain failed: ${Log.err(e as Object)}`);
    }
    return out;
  }

  private static installProxyChain(bridge: JsBridge, verge: VergeConfig): void {
    /**
     * 上游语义：从 proxies 里按 dialer-proxy 反查链路并返回 YAML。
     * 鸿蒙侧反过来做：链路本来就存在 verge/proxy-chain.json，直接按它回一份 **JSON**
     * （JSON 是合法 YAML，前端 parseChainConfigItems 用 js-yaml 解析，两者通吃）。
     */
    bridge.register('get_runtime_proxy_chain_config',
      async (args: Record<string, Object>): Promise<Object | null> => {
        const chain = AppBridge.readChain();
        if (chain.length < 2) {
          return '';
        }
        const exit = args['proxyChainExitNode'];
        if (typeof exit === 'string' && (exit as string).length > 0) {
          const tail = chain[chain.length - 1];
          if (tail !== exit && !chain.includes(exit as string)) {
            return '';
          }
        }
        // 类型从内核拿（拿不到就留空，UI 只是少了类型标签）
        const types: Record<string, string> = {};
        const result = await HttpClient.request(`http://127.0.0.1:${CONTROLLER_PORT}/proxies`,
          http.RequestMethod.GET, '', AppBridge.coreHeaders(), 6000);
        if (result.code === 200 && result.body.length > 0) {
          try {
            const parsed = JSON.parse(result.body) as Record<string, Object | null>;
            const proxies = parsed['proxies'];
            if (proxies !== undefined && proxies !== null) {
              const map = proxies as Record<string, Object | null>;
              const names = Object.keys(map);
              for (let i = 0; i < names.length; i++) {
                const node = map[names[i]];
                if (node === null || node === undefined) {
                  continue;
                }
                const rec = node as Record<string, Object | null>;
                const type = rec['type'];
                if (typeof type === 'string') {
                  types[names[i]] = type as string;
                }
              }
            }
          } catch (e) {
            Log.w('Chain', `parse proxies failed: ${Log.err(e as Object)}`);
          }
        }
        const list: Record<string, Object | null>[] = [];
        for (let i = 0; i < chain.length; i++) {
          const item: Record<string, Object | null> = {};
          item['name'] = chain[i];
          item['type'] = types[chain[i]] === undefined ? '' : types[chain[i]];
          list.push(item);
        }
        const payload: Record<string, Object | null> = {};
        payload['proxies'] = list;
        return JSON.stringify(payload);
      });

    bridge.register('update_proxy_chain_config_in_runtime',
      async (args: Record<string, Object>): Promise<Object | null> => {
        const cfg = args['proxyChainConfig'];
        if (cfg === undefined || cfg === null) {
          FsUtil.remove(AppBridge.chainPath());
          Log.i('Chain', 'chain cleared');
        } else {
          const arr = cfg as string[];
          const names: string[] = [];
          for (let i = 0; i < arr.length; i++) {
            if (typeof arr[i] === 'string') {
              names.push(arr[i] as string);
            }
          }
          const payload: Record<string, Object | null> = {};
          payload['chain'] = names;
          FsUtil.writeText(AppBridge.chainPath(), JSON.stringify(payload));
          Log.i('Chain', `chain saved: ${names.join(' -> ')}`);
        }
        // 让内核按新链路重新生成配置并热重载
        await AppBridge.applyRuntime(verge);
        const outcome: Record<string, Object | null> = {};
        outcome['status'] = 'valid';
        return outcome;
      });
  }

  /** HarmonyOS 网络接口列表（给设置页「网络接口」/分组编辑器用） */
  private static networkInterfacesInfo(): Record<string, Object | null>[] {
    const list: Record<string, Object | null>[] = [];
    const seen: Record<string, boolean> = {};
    try {
      const nets = connection.getAllNetsSync();
      for (let i = 0; i < nets.length; i++) {
        let props: connection.ConnectionProperties;
        try {
          props = connection.getConnectionPropertiesSync(nets[i]);
        } catch (e) {
          continue;
        }
        const name = props.interfaceName;
        if (name.length === 0 || seen[name] === true) {
          continue;
        }
        seen[name] = true;
        const item: Record<string, Object | null> = {};
        item['name'] = name;
        const addrs: Object[] = [];
        for (let j = 0; j < props.linkAddresses.length; j++) {
          const link = props.linkAddresses[j];
          const entry: Record<string, Object | null> = {};
          const ipObj: Record<string, Object | null> = {};
          ipObj['ip'] = link.address.address;
          if (link.address.family === 1) {
            entry['V4'] = ipObj;
          } else {
            entry['V6'] = ipObj;
          }
          addrs.push(entry);
        }
        item['addr'] = addrs;
        item['mac_addr'] = null;
        list.push(item);
      }
    } catch (e) {
      Log.w('Network', `list interfaces failed: ${Log.err(e as Object)}`);
    }
    return list;
  }

  private static async openLocalPath(path: string): Promise<void> {
    const ctx = AppBridge.context;
    if (ctx === null) {
      throw new Error('no ability context');
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: fileUri.getUriFromPath(path),
    };
    await ctx.startAbility(want);
  }

  private static patchPortToggle(patch: Record<string, Object | null>, settings: Record<string, Object | null>,
    key: string, enabledKey: string, portKey: string): void {
    const raw = settings[key];
    if (raw === undefined || raw === null || typeof raw !== 'object') {
      return;
    }
    const item = raw as Record<string, Object | null>;
    if (typeof item['enabled'] === 'boolean') {
      patch[enabledKey] = item['enabled'];
    }
    if (typeof item['port'] === 'number') {
      patch[portKey] = item['port'];
    }
  }

  private static installNoops(bridge: JsBridge): void {
    const nullCommands: string[] = [
      'open_app_dir', 'open_logs_dir', 'open_core_dir', 'open_devtools',
      'install_service', 'uninstall_service', 'reinstall_service', 'repair_service',
      'continue_with_sidecar',
      'cancel_update_download', 'upgrade_clash_core', 'change_clash_core',
      'invoke_uwp_tool', 'copy_icon_file',
      'take_service_fallback_notice', 'take_service_repair_notice', 'take_service_owner_notice',
      'take_discarded_keys_notice', 'take_dns_override_notice',
      'save_dns_config', 'apply_dns_config', 'set_dns_override',
      'export_diagnostic_info',
      'download_icon_cache',
      // 主题切换：ArkWeb 里 CSS 变量已经跟着前端走，原生窗口不需要额外动作。
      // 之前不在列表里 → 走 fallback 抛错 → 每次切深浅色都在控制台刷 2 条 Error。
      'plugin:window|set_theme',
    ];
    for (let i = 0; i < nullCommands.length; i++) {
      bridge.register(nullCommands[i], async (): Promise<Object | null> => null);
    }

    // 轻量模式 = 最小化主窗口（鸿蒙没有桌面端的“隐藏到托盘”语义；
    // 托盘/热键/再次点图标都能把窗口拉回来）。
    bridge.register('entry_lightweight_mode', async (): Promise<Object | null> => {
      // 上游语义：**进入**轻量模式 = 把主窗口收起来，内核 + 托盘继续跑。
      // 原来复用了 toggleDashboard（最小化/恢复来回切），窗口已经最小化时点一下反而会弹出来，
      // 与"轻量模式"的语义相反，所以单独实现。
      AppBridge.enterLiteMode();
      return null;
    });

    // @tauri-apps/plugin-opener：打开外部链接/路径（使用手册、GitHub、订阅主页等）。
    // 没有实现时前端会弹 “command not implemented … plugin:opener|open_url”。
    bridge.register('plugin:opener|open_url', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['url'];
      if (typeof raw !== 'string') {
        throw new Error('invalid url');
      }
      const url = raw as string;
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        throw new Error('Only HTTP and HTTPS URLs are allowed');
      }
      const ctx = AppBridge.context;
      if (ctx === null) {
        throw new Error('no ability context');
      }
      await ctx.openLink(url);
      return null;
    });

    bridge.register('plugin:opener|open_path', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['path'];
      if (typeof raw !== 'string' || (raw as string).length === 0) {
        throw new Error('invalid path');
      }
      const ctx = AppBridge.context;
      if (ctx === null) {
        throw new Error('no ability context');
      }
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: fileUri.getUriFromPath(raw as string),
      };
      await ctx.startAbility(want);
      return null;
    });

    bridge.register('plugin:opener|reveal_item_in_dir', async (): Promise<Object | null> => null);

    // 「打开目录」按钮：尽量交给系统文件管理器（fileUri + viewData）。
    bridge.register('open_app_dir', async (): Promise<Object | null> => {
      await AppBridge.openLocalPath(AppCtx.filesDir);
      return null;
    });
    bridge.register('open_logs_dir', async (): Promise<Object | null> => {
      await AppBridge.openLocalPath(AppCtx.path('verge/logs'));
      return null;
    });
    bridge.register('open_core_dir', async (): Promise<Object | null> => {
      await AppBridge.openLocalPath(CoreHost.home());
      return null;
    });

    const emptyListCommands: string[] = [
      'get_pending_failures',
    ];
    for (let i = 0; i < emptyListCommands.length; i++) {
      bridge.register(emptyListCommands[i], async (): Promise<Object | null> => {
        const list: Record<string, Object | null>[] = [];
        return list;
      });
    }

    bridge.register('get_sidecar_failure', async (): Promise<Object | null> => {
      const snapshot: Record<string, Object | null> = {};
      snapshot['revision'] = 0;
      snapshot['detail'] = null;
      return snapshot;
    });
    // get_proxy_view 由 installProxyView 提供真实实现（见上）
    bridge.register('get_runtime_proxy_chain_config', async (): Promise<Object | null> => '');
    bridge.register('get_dns_config_content', async (): Promise<Object | null> => '');
    bridge.register('validate_dns_config', async (): Promise<Object | null> => {
      const outcome: Record<string, Object | null> = {};
      outcome['status'] = 'valid';
      return outcome;
    });
    bridge.register('get_unlock_items', async (): Promise<Object | null> => MediaUnlockService.initialItems());

    bridge.register('check_media_unlock',
      async (args: Record<string, Object>): Promise<Object | null> => {
        const cfg = AppBridge.verge;
        if (cfg === null) {
          return null;
        }
        const names = MediaUnlockService.names();
        const results: Record<string, Object | null>[] = [];
        const raw = args['__channels'];
        const channels = (raw === undefined || raw === null) ? [] as number[] : raw as number[];
        const bridgeRef = AppBridge.activeBridge;
        for (let i = 0; i < names.length; i++) {
          const item = await MediaUnlockService.checkOne(names[i], cfg);
          results.push(item);
          if (bridgeRef !== null) {
            for (let c = 0; c < channels.length; c++) {
              bridgeRef.channelSend(channels[c], i, JSON.stringify(item), false);
            }
          }
        }
        if (bridgeRef !== null) {
          for (let c = 0; c < channels.length; c++) {
            bridgeRef.channelSend(channels[c], names.length, '', true);
          }
        }
        return results;
      });

    bridge.register('check_media_unlock_item',
      async (args: Record<string, Object>): Promise<Object | null> => {
        const cfg = AppBridge.verge;
        if (cfg === null) {
          return null;
        }
        const name = args['name'];
        const label = typeof name === 'string' ? name as string : '';
        return await MediaUnlockService.checkOne(label, cfg);
      });
  }
}
