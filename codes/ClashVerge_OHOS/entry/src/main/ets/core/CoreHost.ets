import { childProcessManager } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { fileIo as fs } from '@kit.CoreFileKit';

import { process } from '@kit.ArkTS';

import { AppCtx } from '../common/AppCtx';
import { MIHOMO_VERSION, TUN_ADDRESS, TUN_DNS, TUN_PORTAL, TUN_PREFIX } from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';

/** 子进程写的状态文件（verge/runtime/status.json） */
interface CoreChildStatus {
  pid: number;
  phase: string;
  ready: boolean;
  tun: boolean;
  error: string;
  config: string;
  updatedAt: number;
}

/**
 * 内核宿主：**独立 native 子进程**（不是 UI 进程，也不是 VPN 扩展进程）。
 *
 * 为什么必须这样（真机 2026-11-15 两轮日志 + 调试器栈）：
 *   把 Go 内核 dlopen 进 UI 进程后，Go runtime 初始化会在 `newm(sysmon)` 的
 *   `pthread_sigmask/pthread_create` 上卡住（栈：`newm1 → _cgo_thread_start`），
 *   并把**整个进程**一起拖停 —— 界面停在开屏图标/加载页，连 CEF 日志都断掉。
 *   而两套能跑的参考实现，内核都不与 CEF 同进程：ClashBox 的 UI 是纯 ArkUI（无 ArkWeb），
 *   ClashOhos 把内核放在 VpnExtension 进程。
 *   这里选第三条：`childProcessManager` 拉起的 native 子进程 —— 没有 CEF、不需要 VPN 授权，
 *   控制器 9090/7890 常驻，界面重建也不会杀掉内核。
 *
 * 通信：
 *   - UI → 内核：`verge/runtime/{reload,tun}.json`（带 seq，子进程发现变化才生效）
 *   - 内核 → UI：`verge/runtime/status.json`（500ms 心跳）
 *   - 前端 ↔ 内核：仍是 `127.0.0.1:9090` 的 REST/WS，**前端零改动**
 */
export class CoreHost {
  private static bootKicked: boolean = false;
  private static childPid: number = -1;
  private static startError: string = '';
  private static lastReloadSeq: number = 0;
  private static sentConfig: string = '';
  private static tunActive: boolean = false;
  private static rm: resourceManager.ResourceManager | null = null;

  static home(): string {
    return `${AppCtx.filesDir}/verge/core`;
  }

  private static controlDir(): string {
    return AppCtx.path('verge/runtime');
  }

  private static statusPath(): string {
    return `${CoreHost.controlDir()}/status.json`;
  }

  static setResourceManager(rm: resourceManager.ResourceManager): void {
    CoreHost.rm = rm;
  }

  /**
   * 把**内置**的 geo 数据释放到 `<home>`。
   *
   * 为什么要内置（真机 2026-11-15 20:30 的 core.log）：
   *   mihomo 在 `<home>` 找不到 `GeoSite.dat` 时会去 GitHub 下载：
   *     `Can't find GeoSite.dat, start download`
   *   而 GitHub 在这里不可达 → `hub.Parse` 卡 30s+ 后失败 → **控制器 9090 起不来**，
   *   界面表现就是"一直未连接 / 代理页全空"。
   *   把 geosite/geoip/mmdb 打进 rawfile 再释放，首次启动就能离线起内核。
   */
  private static async provisionGeoAsync(): Promise<void> {
    const rm = CoreHost.rm;
    if (rm === null) {
      Log.w('CoreHost', 'resourceManager missing, skip geo provisioning');
      return;
    }
    const started = Date.now();
    const home = CoreHost.home();
    FsUtil.ensureDir(home);
    await Promise.all([
      CoreHost.copyRawAsync(rm, 'geo/geosite.dat', `${home}/GeoSite.dat`),
      CoreHost.copyRawAsync(rm, 'geo/country.mmdb', `${home}/Country.mmdb`)
    ]);
    // geoip.dat（16MB）没有打包：运行时已用 geodata-mode=false + Country.mmdb 走 GEOIP。
    Log.i('CoreHost', `geo provision total ${Date.now() - started}ms`);
  }

  private static async copyRawAsync(rm: resourceManager.ResourceManager, rawPath: string, dst: string): Promise<void> {
    if (FsUtil.exists(dst) && FsUtil.size(dst) > 4096) {
      return;
    }
    const started = Date.now();
    try {
      // 首次启动要释放 12MB geo；同步读 rawfile 会阻塞 UI 线程十几秒，
      // 改成异步读 + 异步写，EntryAbility 先把界面挂出来，再后台释放。
      const data: Uint8Array = await rm.getRawFileContent(rawPath);
      if (data === undefined || data === null || data.length === 0) {
        Log.w('CoreHost', `raw geo empty: ${rawPath}`);
        return;
      }
      const buf = data.buffer as ArrayBuffer;
      const file = await fs.open(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        await fs.write(file.fd, buf);
      } finally {
        await fs.close(file);
      }
      Log.i('CoreHost', `geo provisioned ${dst} bytes=${data.length} in ${Date.now() - started}ms`);
    } catch (e) {
      Log.w('CoreHost', `geo provision failed ${rawPath}: ${Log.err(e as Object)}`);
    }
  }

  /**
   * 启动内核子进程（幂等）。可在 `EntryAbility.onCreate` 里先踢一脚。
   *
   * `config` 传空：子进程只做 init；真正的订阅由 `ensureStarted(path)` 通过 `reload.json` 下发
   * （onCreate 阶段还算不出当前订阅路径）。
   */
  static bootEarly(): void {
    if (CoreHost.bootKicked) {
      return;
    }
    CoreHost.bootKicked = true;
    FsUtil.ensureDir(CoreHost.controlDir());
    // 清掉上一次运行留下的控制文件：陈旧 status.json 会让 waitReady 立刻误判「已就绪」，
    // 陈旧 tun.json 会让新子进程去连一个早已不存在的 socket。
    FsUtil.remove(CoreHost.statusPath());
    FsUtil.remove(`${CoreHost.controlDir()}/tun.json`);
    FsUtil.remove(`${CoreHost.controlDir()}/reload.json`);
    // 异步释放 geo，避免首次启动阻塞 UI 线程（同步读 12MB rawfile 在真机上要十几秒）。
    CoreHost.provisionGeoAsync().then(() => {
      CoreHost.startChild();
    }).catch((e: Object) => {
      CoreHost.startError = Log.err(e);
      Log.e('CoreHost', `geo provisioning failed, start child anyway: ${CoreHost.startError}`);
      CoreHost.startChild();
    });
  }

  private static startChild(): void {
    const params: Record<string, Object> = {};
    params['home'] = CoreHost.home();
    params['config'] = '';
    params['control'] = CoreHost.controlDir();
    params['version'] = MIHOMO_VERSION;
    params['sdk'] = 26;
    const payload = JSON.stringify(params);
    Log.i('CoreHost', `starting core child process, ui pid=${process.pid}`);
    try {
      // ChildProcessArgs 在自己的模块里导出，不在 namespace 下；这里用对象字面量让编译器推断
      childProcessManager.startNativeChildProcess('libclash_core.so:ClashCoreChildMain',
        { entryParams: payload })
        .then((pid: number) => {
          CoreHost.childPid = pid;
          Log.i('CoreHost', `core child started pid=${pid}`);
        })
        .catch((e: Object) => {
          CoreHost.startError = Log.err(e);
          Log.e('CoreHost', `core child start failed: ${CoreHost.startError}`);
        });
    } catch (e) {
      CoreHost.startError = Log.err(e as Object);
      Log.e('CoreHost', `core child start threw: ${CoreHost.startError}`);
    }
  }

  /** 读子进程状态文件；不存在/损坏/旧格式返回 null */
  static status(): CoreChildStatus | null {
    const raw = FsUtil.readText(CoreHost.statusPath());
    if (raw.length === 0) {
      return null;
    }
    try {
      // 不要直接 as CoreChildStatus：升级后磁盘上可能还留着旧 schema（缺 phase/ready），
      // 后面 st.error.length / st.phase.indexOf 会在运行时抛 TypeError。
      const obj = JSON.parse(raw) as Record<string, Object | null>;
      const st: CoreChildStatus = {
        pid: typeof obj['pid'] === 'number' ? obj['pid'] as number : -1,
        phase: typeof obj['phase'] === 'string' ? obj['phase'] as string : '',
        ready: obj['ready'] === true,
        tun: obj['tun'] === true,
        error: typeof obj['error'] === 'string' ? obj['error'] as string : '',
        config: typeof obj['config'] === 'string' ? obj['config'] as string : '',
        updatedAt: typeof obj['updatedAt'] === 'number' ? obj['updatedAt'] as number : 0
      };
      if (st.updatedAt <= 0) {
        return null;
      }
      return st;
    } catch (e) {
      return null;
    }
  }

  /** 子进程是否活着（ready 且心跳不超 5s） */
  static alive(): boolean {
    const st = CoreHost.status();
    if (st === null || !st.ready || st.updatedAt <= 0) {
      return false;
    }
    return Date.now() - st.updatedAt < 5000;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 轮询等子进程 ready（不阻塞 UI 线程） */
  static async waitReady(timeoutMs: number): Promise<string> {
    CoreHost.bootEarly();
    const started = Date.now();
    let lastLog = 0;
    while (true) {
      const st = CoreHost.status();
      if (st !== null && st.ready) {
        Log.i('CoreHost', `core child ready after ${Date.now() - started}ms pid=${st.pid}`);
        return '';
      }
      if (st !== null && st.error.length > 0 && st.phase.indexOf('failed') >= 0) {
        return `core child error: ${st.error}`;
      }
      if (CoreHost.startError.length > 0) {
        return `core child start failed: ${CoreHost.startError}`;
      }
      const waited = Date.now() - started;
      if (waited >= timeoutMs) {
        const phase = st === null ? 'no-status' : st.phase;
        return `core child not ready after ${waited}ms (phase=${phase})`;
      }
      if (waited - lastLog >= 2000) {
        lastLog = waited;
        const phase = st === null ? 'none' : st.phase;
        Log.i('CoreHost', `waiting core child... ${waited}ms phase=${phase}`);
      }
      await CoreHost.sleep(200);
    }
  }

  /** 把配置下发给子进程（写 reload.json，seq 递增） */
  static applyConfig(profilePath: string): void {
    if (profilePath.length === 0 || profilePath === CoreHost.sentConfig) {
      return;
    }
    CoreHost.forceApplyConfig(profilePath);
  }

  /**
   * 强制重载（路径不变也要重载）：DNS 覆写开关、扩展覆写等只改
   * `dns_active`/overrides 文件，profile 路径不变，`applyConfig` 会把它当重复跳过。
   * 注意必须走 seq 契约（child.go 只认 `seq`，旧的 ReloadChannel 写的是 `ts`，
   * 第二次起会被子进程忽略 —— 真机 22:19 复现）。
   */
  static forceApplyConfig(profilePath: string): void {
    if (profilePath.length === 0) {
      return;
    }
    CoreHost.lastReloadSeq++;
    const payload: Record<string, Object> = {};
    payload['seq'] = CoreHost.lastReloadSeq;
    payload['path'] = profilePath;
    const ok = FsUtil.writeText(`${CoreHost.controlDir()}/reload.json`, JSON.stringify(payload));
    if (ok) {
      CoreHost.sentConfig = profilePath;
      Log.i('CoreHost', `reload sent seq=${CoreHost.lastReloadSeq} path=${profilePath}`);
    } else {
      Log.e('CoreHost', 'reload.json write failed');
    }
  }

  /** 确保内核在跑，并把订阅装好（等子进程确认 loaded） */
  static async ensureStarted(profilePath: string): Promise<string> {
    const error = await CoreHost.waitReady(90000);
    if (error.length > 0) {
      return error;
    }
    CoreHost.applyConfig(profilePath);
    if (profilePath.length === 0) {
      return '';
    }
    const started = Date.now();
    // 首次加载会给 geo 数据做索引，配置大时 30s 不够，放宽到 90s
    while (Date.now() - started < 90000) {
      const st = CoreHost.status();
      if (st !== null) {
        // 出错时子进程**不会**更新 config 字段，所以错误检查必须放在 config 匹配之外，
        // 否则真实原因会被掩盖成 "config load timeout"（真机 20:31 就吃过这个亏）。
        if (st.error.length > 0) {
          return st.error;
        }
      }
      if (st !== null && st.config === profilePath) {
        const phase = st.phase;
        if (phase === 'loaded' || phase === 'ready' || phase === 'tun-on' || phase === 'tun-off') {
          Log.i('CoreHost', `config loaded by child: ${profilePath}`);
          return '';
        }
      }
      await CoreHost.sleep(200);
    }
    return 'config load timeout';
  }

  /** 兼容旧调用：只下发配置，不等 */
  static reload(profilePath: string): string {
    CoreHost.applyConfig(profilePath);
    return '';
  }

  /**
   * 开 TUN：把扩展递出的 socket 路径交给子进程，由**子进程自己**用 SCM_RIGHTS 收 fd。
   * fd 号跨进程没有意义，必须传 fd 本身（这就是为什么不能像以前那样在 UI 进程收）。
   */
  static async startTun(socketPath: string, stack: string): Promise<string> {
    const payload: Record<string, Object> = {};
    payload['seq'] = Date.now();
    payload['on'] = true;
    payload['socket'] = socketPath;
    payload['stack'] = stack.length > 0 ? stack : 'mips';
    payload['gateway'] = `${TUN_ADDRESS}/${TUN_PREFIX}`;
    payload['portal'] = TUN_PORTAL;
    payload['dns'] = TUN_DNS;
    if (!FsUtil.writeText(`${CoreHost.controlDir()}/tun.json`, JSON.stringify(payload))) {
      return 'tun.json write failed';
    }
    Log.i('CoreHost', `tun request sent socket=${socketPath}`);
    const started = Date.now();
    let lastPhase = '';
    while (Date.now() - started < 30000) {
      const st = CoreHost.status();
      if (st !== null) {
        if (st.tun) {
          CoreHost.tunActive = true;
          Log.i('CoreHost', 'tun is up (child)');
          return '';
        }
        if (st.phase === 'tun-fd-failed' || st.phase === 'tun-start-failed') {
          CoreHost.tunActive = false;
          return `${st.phase}: ${st.error}`;
        }
        if (st.phase !== lastPhase) {
          lastPhase = st.phase;
          Log.i('CoreHost', `tun phase=${st.phase}`);
        }
      }
      await CoreHost.sleep(200);
    }
    return 'tun start timeout';
  }

  static async stopTun(): Promise<void> {
    if (!CoreHost.bootKicked) {
      return;
    }
    const payload: Record<string, Object> = {};
    payload['seq'] = Date.now();
    payload['on'] = false;
    FsUtil.writeText(`${CoreHost.controlDir()}/tun.json`, JSON.stringify(payload));
    CoreHost.tunActive = false;
    Log.i('CoreHost', 'tun stop requested');
  }

  static isTunActive(): boolean {
    return CoreHost.tunActive;
  }

  /** 以子进程状态文件为准：TUN 是否真的挂着（心跳过期也算 false） */
  static tunUp(): boolean {
    const st = CoreHost.status();
    if (st === null || !st.ready || !st.tun || st.updatedAt <= 0) {
      return false;
    }
    return Date.now() - st.updatedAt < 5000;
  }

  static pid(): number {
    return CoreHost.childPid;
  }

  /** 子进程拉起阶段的错误（status.json 还不存在时用） */
  static lastStartError(): string {
    return CoreHost.startError;
  }
}
