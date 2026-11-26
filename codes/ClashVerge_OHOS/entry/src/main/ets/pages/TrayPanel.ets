import { common, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { connection, http } from '@kit.NetworkKit';
import { commonEventManager, BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';

import { BUNDLE_NAME, CONTROLLER_HOST, CONTROLLER_PORT } from '../common/Constants';
import { AppTheme } from '../common/AppTheme';
import { HttpClient } from '../core/HttpClient';
import { TrayWs } from '../core/TrayWs';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';

/**
 * 托盘面板配色 Token —— 全部取自 HarmonyOS 系统色，深浅色各一套。
 *
 * 依据：《色彩》设计规范 + 《系统资源》ts-appendix-system-resources
 *   Primary（文本/图标基色）：浅 #000000 / 深 #FFFFFF，靠透明度分四级（90/60/40/20%）
 *   Container（页面底）      ：浅 #FFFFFF / 深 #000000
 *   辅助背景                 ：浅 #F1F3F5 / 深 #000000
 *   组件通用背景             ：深 #19FFFFFF（白 10%）
 *   分割线                   ：#33FFFFFF（深）/ #1A000000（浅）
 *   品牌色（宇宙蓝）         ：浅 #0A59F7 / 深 #317AF7
 *   功能色                   ：warning #E84026 / confirm #64BB5C（深 #5BA854）
 *
 * ⚠️ 上一版把这些写成了「浅灰底 + 深色字」的硬编码，深色系统下就成了灰蒙蒙一片、
 *    和系统顶栏的深色材质对不上 —— 所以这里必须按深浅色分两套。
 */
class TrayPalette {
  dark: boolean = true;
  /**
   * 面板底：近实色（96%）。
   *
   * ⚠️ 结论已由华为侧确认（2026-11-16，见 docs/ASK-DEVAI-BACKGROUND.md）：
   *   组件级 backgroundBlurStyle / backgroundEffect / backdropBlur 的采样范围**只到本窗口渲染管线内的内容**，
   *   采样不到窗口背后的桌面；系统顶栏的"玻璃"是系统合成器在窗口层级做的实时模糊，应用侧无公开接口可复现。
   *   ⇒ 透明窗口里降 alpha 只会把**未经模糊的桌面原始像素**放进面板：
   *     实测降到 68% 时，彩虹壁纸整片糊进卡片，看着像"彩色凝胶"，比实色更脏。
   *   所以这里取近实色，靠"顶栏玻璃 + 下方实色内容区"这个正常窗口结构来读，而不是硬凑玻璃。
   */
  panel: string = '#F51B1B1B';
  /** 卡片：官方 id_color_component_normal（深色白 10%），底已经是实色，不用再加厚 */
  card: string = '#1AFFFFFF';
  /** 卡片内的指标块底：只提亮一档，保证 12fp 三级文本对比度 ≥3:1 */
  tile: string = '#17FFFFFF';
  /** 未选中按钮 / 次级胶囊底 */
  btnRest: string = '#1AFFFFFF';
  divider: string = '#33FFFFFF';
  border: string = '#14FFFFFF';
  font1: string = '#E5FFFFFF';
  font2: string = '#99FFFFFF';
  font3: string = '#7AFFFFFF';
  brand: string = '#317AF7';
  onBrand: string = '#FFFFFF';
  up: string = '#ED6F21';
  down: string = '#317AF7';
  ok: string = '#5BA854';
  okFill: string = 'rgba(91,168,84,0.18)';
  grid: string = '#1FFFFFFF';

  constructor(dark: boolean) {
    this.dark = dark;
    if (dark) {
      return;
    }
    this.panel = '#F7F1F3F5';
    this.card = '#FFFFFFFF';
    this.tile = '#0A000000';
    this.btnRest = '#0D000000';
    this.divider = '#1A000000';
    this.border = '#1A000000';
    this.font1 = '#E5000000';
    this.font2 = '#99000000';
    this.font3 = '#75000000';
    this.brand = '#0A59F7';
    this.onBrand = '#FFFFFF';
    this.up = '#ED6F21';
    this.down = '#0A59F7';
    this.ok = '#64BB5C';
    this.okFill = 'rgba(100,187,92,0.16)';
    this.grid = '#14000000';
  }
}

/**
 * 托盘左键面板（StatusBarViewExtensionAbility）。
 *
 * 版式与主界面首页一一对应：当前节点 / 代理模式 / 网络设置 / 流量统计 / IP 信息。
 * 字号只允许用下面这四个层级（华为五类文本的 PC 档，相邻层级差 ≥2fp）：
 *   L1 20 Medium —— 焦点数值（IP 卡片的国家名）
 *   L2 16 Medium —— 卡片标题 + 主值（节点名、各项统计数值）
 *   L3 14 Regular —— 次级内容（节点类型、IP 明细行）
 *   L4 12 Regular —— 辅助（更新时间、单位、连接数、说明）
 * 禁止再出现 13/15/17/19 这种「随手调」的字号。
 */
@Entry
@Component
struct TrayPanel {
  // 字阶
  private fsL1: number = 20;
  private fsL2: number = 16;
  private fsL3: number = 14;
  private fsL4: number = 12;
  /**
   * 元信息行（节点类型 + UDP 胶囊 + 延迟）的统一行高。
   *
   * 14fp 的类型文字和 12fp 的胶囊如果用各自默认行高，行盒高度差约 1vp，
   * Row 按盒子居中后基线就差半像素 —— 2x 屏上就是「UDP 比 Vless 高一点」。
   * 三处统一 lineHeight 后，行盒完全等高，视觉上必然对齐。
   */
  private metaH: number = 20;
  // 间距（8vp 网格）
  private gapCard: number = 8;
  private padCard: number = 16;
  private padPage: number = 16;
  private hMenuRow: number = 40;

  @State running: boolean = false;
  @State mode: string = '规则';
  @State node: string = '未连接';
  @State nodeType: string = '';
  @State nodeUdp: boolean = false;
  @State nodeDelay: number = 0;
  @State tunOn: boolean = false;
  @State subName: string = '未选择订阅';
  @State subUpdated: string = '';
  @State downSpeed: number = 0;
  @State upSpeed: number = 0;
  @State downTotal: number = 0;
  @State upTotal: number = 0;
  @State connectionCount: number = 0;
  @State memInuse: number = 0;
  @State memOk: boolean = false;
  @State downHistory: number[] = [];
  @State upHistory: number[] = [];
  @State ip: string = '--';
  @State country: string = '--';
  @State countryCode: string = '';
  @State isp: string = '--';
  @State org: string = '--';
  @State location: string = '--';
  @State timezone: string = '--';
  @State asn: string = '--';
  @State ipError: string = '';
  @State proxyPort: number = 7890;

  @State pal: TrayPalette = new TrayPalette(true);
  private timer: number = -1;
  private timerSlow: number = -1;
  private stateSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private firstShow: boolean = true;
  private busy: boolean = false;
  private busySlow: boolean = false;
  private wsTraffic: TrayWs | null = null;
  private wsMemory: TrayWs | null = null;
  private wsConnections: TrayWs | null = null;
  private lastIpFetch: number = 0;
  private chartW: number = 300;
  private chartH: number = 96;
  /**
   * 玻璃模式（主人 21:06 拍板）：面板本身 alpha 0，只有卡片留一层薄纱，
   * 其余（指标块/按钮/描边/分割线）全部透明 —— 和系统顶栏大标题那种观感一致。
   * 想回到实色方案：把这里改 false。
   */
  private glassMode: boolean = true;
  private canvasReady: boolean = false;
  private chartSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private chartCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.chartSettings);

  aboutToAppear(): void {
    this.pal = this.buildPalette();
    this.setupWindow();
    this.loadLocalInfo();
    this.loadIpCache();
    this.startStreams();
    this.subscribeStateEvents();
    this.pollFast();
    this.pollSlow();
    // 立即拉一次 IP（不再等在前两个 HTTP 请求后面）
    this.lastIpFetch = Date.now();
    this.fetchIp();
    // 1s：本地开关（verge.json）+ 内核模式（/configs）—— 都是小请求，面板是秒级交互，5s 太钝
    this.timer = setInterval((): void => {
      this.pollFast();
    }, 1000);
    // 5s：/proxies 体积大，单独一档
    this.timerSlow = setInterval((): void => {
      this.pollSlow();
    }, 5000);
  }

  /**
   * 订阅主进程推来的"状态变了"（模式 / TUN / 节点 / 订阅）。
   *
   * 轮询只是兜底：主进程一改状态就 publishTrayState()，这里收到立刻重拉，
   * 用户从主界面切完模式再点开菜单，看到的就是新状态，不用等下一个 tick。
   */
  private subscribeStateEvents(): void {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: ['com.lyldeer.clashverge.TRAY_STATE'],
    };
    commonEventManager.createSubscriber(info,
      (err: BusinessError, subscriber: commonEventManager.CommonEventSubscriber): void => {
        if (err) {
          Log.w('TrayPanel', `create state subscriber failed: ${err.code}`);
          return;
        }
        this.stateSubscriber = subscriber;
        commonEventManager.subscribe(subscriber,
          (subErr: BusinessError, data: commonEventManager.CommonEventData): void => {
            if (subErr) {
              Log.w('TrayPanel', `state event failed: ${subErr.code}`);
              return;
            }
            Log.i('TrayPanel', `state pushed (${data.data}) -> refresh now`);
            this.loadLocalInfo();
            this.syncLocalFlags();
            this.pollFast();
            this.pollSlow();
          });
      });
  }

  /**
   * 面板重新显示（被复用、或从后台切回来）时先立刻对一次状态。
   *
   * ⚠️ 这是"打开菜单发现按钮是旧状态"的关键：扩展窗口的页面实例会被复用，
   *    不一定会重新走 aboutToAppear，之前只能等 5s 的轮询把它纠回来。
   */
  onPageShow(): void {
    if (this.firstShow) {
      this.firstShow = false;
      return;
    }
    Log.i('TrayPanel', 'page show again -> refresh now');
    this.loadLocalInfo();
    this.pollFast();
    this.pollSlow();
    this.lastIpFetch = Date.now();
    this.fetchIp();
  }

  /** 面板被系统收起时也会走这里；用来区分"我们主动关"还是"系统收" */
  onPageHide(): void {
    Log.i('TrayPanel', 'onPageHide (panel hidden by system)');
  }

  aboutToDisappear(): void {
    Log.i('TrayPanel', 'aboutToDisappear');
    if (this.stateSubscriber !== null) {
      try {
        // 注意：这个重载返回 void，不能 .catch()
        commonEventManager.unsubscribe(this.stateSubscriber);
      } catch (e) {
        Log.w('TrayPanel', `unsubscribe state failed: ${Log.err(e as Object)}`);
      }
      this.stateSubscriber = null;
    }
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.timerSlow !== -1) {
      clearInterval(this.timerSlow);
      this.timerSlow = -1;
    }
    this.stopStreams();
  }

  /**
   * 玻璃模式：面板 alpha 0，只有卡片挂一层薄纱。
   *
   * 不是所有东西都该透明 —— 这几样必须留，否则会「看不见」：
   *   · 未选中按钮的底（`btnRest`）：否则三个模式按钮只剩文字，点哪儿都不知道
   *   · 分割线（`divider`）：内容区和底部「打开 Clash Verge」之间要有分隔
   *   · 图表坐标线（`grid`）：网速图没有网格就只剩两条飘着的折线
   * 深色用白系（#1F/#33/#26），浅色用黑系，保证在任意壁纸上都立得住。
   */
  private applyGlassMode(p: TrayPalette): void {
    if (!this.glassMode) {
      return;
    }
    p.panel = '#00000000';
    p.card = p.dark ? '#1AFFFFFF' : '#1A000000';
    p.tile = '#00000000';
    p.btnRest = p.dark ? '#1FFFFFFF' : '#14000000';
    p.border = '#00000000';
    p.divider = p.dark ? '#33FFFFFF' : '#1F000000';
    p.grid = p.dark ? '#26FFFFFF' : '#1F000000';
    Log.i('TrayPanel', `glass mode: card=${p.card} btnRest=${p.btnRest} grid=${p.grid}`);
  }

  /** 造一套调色板（含玻璃模式覆盖） */
  private buildPalette(): TrayPalette {
    const next = new TrayPalette(this.detectDark());
    this.applyGlassMode(next);
    return next;
  }

  /**
   * 系统深浅色变了就整体换一套 token。
   * 托盘面板是扩展进程里的独立页面，主界面切主题不会通知到它；
   * 这里在数据流（1s）与慢轮询（5s）里各查一次 `config.colorMode`，
   * 变了就重建调色板 —— `pal` 是 @State，赋值即触发整页重绘，文字颜色才会跟着换。
   */
  private syncPalette(): void {
    const dark = this.detectDark();
    if (dark === this.pal.dark) {
      return;
    }
    this.pal = this.buildPalette();
    this.drawChart();
    Log.i('TrayPanel', `color mode changed at runtime: dark=${dark}`);
  }

  /**
   * 深浅色判据 = **应用主题**（verge.json 的 theme_mode）叠上系统深浅色。
   *
   * 托盘面板是扩展进程，拿不到主进程的 AppStorage，所以直接读同一个 verge.json；
   * 这样「系统浅色 + 应用强制深色」时，面板和主界面是一套配色，不会一黑一白。
   */
  private detectDark(): boolean {
    try {
      const ctx = getContext(this) as common.UIExtensionContext;
      const systemDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      return AppTheme.resolveDark(this.filesDir(), systemDark);
    } catch (e) {
      Log.w('TrayPanel', `detect color mode failed: ${Log.err(e as Object)}`);
      return true;
    }
  }

  private async setupWindow(): Promise<void> {
    let lastWin: window.Window | null = null;
    try {
      lastWin = await window.getLastWindow(getContext(this));
    } catch (e) {
      Log.w('TrayPanel', `get window failed: ${Log.err(e as Object)}`);
      return;
    }
    if (lastWin === null) {
      return;
    }
    const win: window.Window = lastWin;
    // 窗口必须透明，圆角与投影交给系统；底色由页面根节点提供。
    // 三个 API 各自单独兜错：setWindowContainerColor 在 tablet/2in1 上是不可用的
    // （编译器会报 "This API is unavailable to tablet, 2in1"），
    // 塞在同一个 try 里会把后面的 setWindowDecorVisible 一起废掉。
    try {
      await win.setWindowBackgroundColor('#00000000');
    } catch (e) {
      Log.w('TrayPanel', `setWindowBackgroundColor failed: ${Log.err(e as Object)}`);
    }
    try {
      await win.setWindowContainerColor('#00000000', '#00000000');
    } catch (e) {
      Log.w('TrayPanel', `setWindowContainerColor skipped (2in1): ${Log.err(e as Object)}`);
    }
    try {
      win.setWindowDecorVisible(false);
    } catch (e) {
      Log.w('TrayPanel', `setWindowDecorVisible failed: ${Log.err(e as Object)}`);
    }
    Log.i('TrayPanel', `transparent window ready, dark=${this.pal.dark}`);
  }

  private filesDir(): string {
    const ctx = getContext(this) as common.UIExtensionContext;
    return ctx.filesDir;
  }

  private readText(relative: string): string {
    try {
      return fs.readTextSync(`${this.filesDir()}/${relative}`);
    } catch (e) {
      return '';
    }
  }

  private readSecret(): string {
    return this.readText('verge/core-secret.txt').trim();
  }

  private loadLocalInfo(): void {
    try {
      const verge = JSON.parse(this.readText('verge/verge.json')) as Record<string, Object | null>;
      this.tunOn = verge['enable_tun_mode'] === true;
      const port = verge['verge_mixed_port'];
      if (typeof port === 'number') {
        this.proxyPort = port as number;
      }
      // TUN 关闭时必须清掉 app 级代理，否则 IP 检测会错误地走 mixed-port。
      this.syncAppProxy();
      const profiles = JSON.parse(this.readText('verge/profiles.json')) as Record<string, Object | null>;
      const current = profiles['current'];
      const items = profiles['items'];
      if (typeof current === 'string' && Array.isArray(items)) {
        const list = items as Record<string, Object | null>[];
        for (let i = 0; i < list.length; i++) {
          const item = list[i];
          if (item['uid'] === current) {
            const name = item['name'];
            if (typeof name === 'string') {
              this.subName = name as string;
            }
            const updated = item['updated'];
            if (typeof updated === 'number') {
              this.subUpdated = this.timeText(updated as number);
            }
            break;
          }
        }
      }
    } catch (e) {
      Log.w('TrayPanel', `load local info failed: ${Log.err(e as Object)}`);
    }
  }

  /** TUN 开：app 请求走本地 mixed-port；TUN 关：清空，直连真实出口。 */
  private syncAppProxy(): void {
    try {
      if (!this.tunOn || this.proxyPort <= 0) {
        const empty: connection.HttpProxy = { host: '', port: 0, exclusionList: [] };
        connection.setAppHttpProxy(empty);
        return;
      }
      const proxy: connection.HttpProxy = {
        host: '127.0.0.1',
        port: this.proxyPort,
        exclusionList: ['127.0.0.1', 'localhost'],
      };
      connection.setAppHttpProxy(proxy);
    } catch (e) {
      Log.w('TrayPanel', `sync app proxy failed: ${Log.err(e as Object)}`);
    }
  }

  /** 订阅更新时间：完整年月日，配合「更新于」才是通顺的中文 */
  private timeText(seconds: number): string {
    const date = new Date(seconds * 1000);
    const year = date.getFullYear();
    const month = `${date.getMonth() + 1}`.padStart(2, '0');
    const day = `${date.getDate()}`.padStart(2, '0');
    const hour = `${date.getHours()}`.padStart(2, '0');
    const minute = `${date.getMinutes()}`.padStart(2, '0');
    return `${year}-${month}-${day} ${hour}:${minute}`;
  }

  private async getCore(path: string, secret: string): Promise<Record<string, Object | null> | null> {
    const headers: Record<string, string> = {};
    if (secret.length > 0) {
      headers['Authorization'] = `Bearer ${secret}`;
    }
    const url = `http://${CONTROLLER_HOST}:${CONTROLLER_PORT}${path}`;
    try {
      const result = await HttpClient.request(url, http.RequestMethod.GET, '', headers, 2500);
      if (result.error.length > 0 || result.code !== 200) {
        return null;
      }
      return JSON.parse(result.body) as Record<string, Object | null>;
    } catch (e) {
      return null;
    }
  }

  /**
   * 数据源两路，和首页完全一致：
   *   ① 流式（WS，内核每秒推一帧）：/traffic 速度与累计、/memory 内核占用、/connections 活跃连接；
   *   ② 轮询（5s）：/configs 取模式、/proxies 取当前节点 —— 这两个没有流式接口且变化慢。
   *
   * ⚠️ 上一版把 /memory、/traffic 当普通 HTTP GET 轮询：内核那两个 handler 是**流式**的
   * （每秒 write+flush，永不 return），请求会一直挂到 2.5s 超时 → 内核占用永远 "--"，
   * 并且把同一轮里排在后面的 /proxies 拖慢，所以整个面板显得又慢又不同步。
   */
  private startStreams(): void {
    const secretOf: () => string = (): string => this.readSecret();

    const traffic = new TrayWs('/traffic', secretOf, (text: string): void => {
      this.onTrafficFrame(text);
    });
    traffic.start();
    this.wsTraffic = traffic;

    const memory = new TrayWs('/memory', secretOf, (text: string): void => {
      this.onMemoryFrame(text);
    });
    memory.start();
    this.wsMemory = memory;

    const connections = new TrayWs('/connections', secretOf, (text: string): void => {
      this.onConnectionsFrame(text);
    });
    connections.start();
    this.wsConnections = connections;

    Log.i('TrayPanel', 'streams started: /traffic /memory /connections');
  }

  private stopStreams(): void {
    if (this.wsTraffic !== null) {
      this.wsTraffic.stop();
      this.wsTraffic = null;
    }
    if (this.wsMemory !== null) {
      this.wsMemory.stop();
      this.wsMemory = null;
    }
    if (this.wsConnections !== null) {
      this.wsConnections.stop();
      this.wsConnections = null;
    }
  }

  /** 每秒一帧：{"up":B/s,"down":B/s,"upTotal":B,"downTotal":B} */
  private onTrafficFrame(text: string): void {
    try {
      this.syncPalette();
      const data = JSON.parse(text) as Record<string, Object | null>;
      this.running = true;
      this.upSpeed = this.numOf(data['up']);
      this.downSpeed = this.numOf(data['down']);
      const upTotal = data['upTotal'];
      if (typeof upTotal === 'number') {
        this.upTotal = upTotal as number;
      }
      const downTotal = data['downTotal'];
      if (typeof downTotal === 'number') {
        this.downTotal = downTotal as number;
      }
      this.pushHistory(this.downSpeed, this.upSpeed);
      this.drawChart();
    } catch (e) {
      Log.w('TrayPanel', `traffic frame parse failed: ${Log.err(e as Object)}`);
    }
  }

  /** 每秒一帧：{"inuse":RSS,"oslimit":0}；注意首帧固定是 0，不能当成"取不到" */
  private onMemoryFrame(text: string): void {
    try {
      const data = JSON.parse(text) as Record<string, Object | null>;
      const inuse = this.numOf(data['inuse']);
      if (inuse > 0) {
        this.memInuse = inuse;
        this.memOk = true;
      }
    } catch (e) {
      Log.w('TrayPanel', `memory frame parse failed: ${Log.err(e as Object)}`);
    }
  }

  /** 每秒一帧全量快照，只取活跃条数 */
  private onConnectionsFrame(text: string): void {
    try {
      const data = JSON.parse(text) as Record<string, Object | null>;
      const list = data['connections'];
      if (Array.isArray(list)) {
        this.connectionCount = (list as Object[]).length;
      }
    } catch (e) {
      Log.w('TrayPanel', `connections frame parse failed: ${Log.err(e as Object)}`);
    }
  }

  /**
   * 1s 档：本地开关位 + 内核模式。
   *
   * 面板是"点开就要看到当前状态"的交互，5s 轮询太钝（主人反馈：在主界面切了直连/TUN，
   * 回头点开菜单还是旧状态，要等几秒）。这两样都是小请求/小文件，1s 一次没负担。
   */
  private async pollFast(): Promise<void> {
    this.syncPalette();
    this.syncLocalFlags();
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const secret = this.readSecret();
      const config = await this.getCore('/configs', secret);
      if (config === null) {
        this.running = false;
      } else {
        this.running = true;
        const rawMode = config['mode'];
        if (typeof rawMode === 'string') {
          this.mode = this.modeText(rawMode as string);
        }
        const mixed = config['mixed-port'] ?? config['mixedPort'];
        if (typeof mixed === 'number' && (mixed as number) > 0) {
          this.proxyPort = mixed as number;
        }
      }
    } catch (e) {
      Log.w('TrayPanel', `poll fast failed: ${Log.err(e as Object)}`);
    } finally {
      this.busy = false;
    }
  }

  /** 5s 档：/proxies 体积大（几百个节点），单独降频；IP 顺带 30s 节流 */
  private async pollSlow(): Promise<void> {
    if (this.busySlow) {
      return;
    }
    this.busySlow = true;
    try {
      const secret = this.readSecret();
      const proxies = await this.getCore('/proxies', secret);
      if (proxies !== null) {
        this.readNode(proxies);
      }
      if (Date.now() - this.lastIpFetch > 30000) {
        this.lastIpFetch = Date.now();
        this.fetchIp();
      }
    } catch (e) {
      Log.w('TrayPanel', `poll slow failed: ${Log.err(e as Object)}`);
    } finally {
      this.busySlow = false;
    }
  }

  /** 只读 verge.json 里的开关位（TUN / 端口），保证面板开关与主界面一致 */
  private syncLocalFlags(): void {
    try {
      const verge = JSON.parse(this.readText('verge/verge.json')) as Record<string, Object | null>;
      const tun = verge['enable_tun_mode'] === true;
      if (tun !== this.tunOn) {
        this.tunOn = tun;
        this.syncAppProxy();
      }
      const port = verge['verge_mixed_port'];
      if (typeof port === 'number' && (port as number) > 0 && (port as number) !== this.proxyPort) {
        this.proxyPort = port as number;
      }
    } catch (e) {
      // 主进程可能正在重写这个文件，下一轮再读
    }
  }

  /** IP 缓存：面板复用/二次打开时先把上次的结果画出来，后台再刷新 */
  private loadIpCache(): void {
    const raw = this.readText('verge/tray-ip-cache.json');
    if (raw.length === 0) {
      return;
    }
    try {
      const cache = JSON.parse(raw) as Record<string, Object | null>;
      this.ip = this.textOf(cache['ip'], '--');
      this.country = this.textOf(cache['country'], '--');
      this.countryCode = this.textOf(cache['countryCode'], '');
      this.isp = this.textOf(cache['isp'], '--');
      this.org = this.textOf(cache['org'], '--');
      this.location = this.textOf(cache['location'], '--');
      this.timezone = this.textOf(cache['timezone'], '--');
      this.asn = this.textOf(cache['asn'], '--');
      this.ipError = '';
      Log.i('TrayPanel', `ip cache restored: ${this.ip}`);
    } catch (e) {
      Log.w('TrayPanel', `ip cache parse failed: ${Log.err(e as Object)}`);
    }
  }

  private saveIpCache(): void {
    try {
      const cache: Record<string, Object | null> = {};
      cache['ip'] = this.ip;
      cache['country'] = this.country;
      cache['countryCode'] = this.countryCode;
      cache['isp'] = this.isp;
      cache['org'] = this.org;
      cache['location'] = this.location;
      cache['timezone'] = this.timezone;
      cache['asn'] = this.asn;
      FsUtil.writeText(`${this.filesDir()}/verge/tray-ip-cache.json`, JSON.stringify(cache));
    } catch (e) {
      Log.w('TrayPanel', `ip cache save failed: ${Log.err(e as Object)}`);
    }
  }

  private pushHistory(down: number, up: number): void {
    const downNext = this.downHistory.slice();
    const upNext = this.upHistory.slice();
    downNext.push(down);
    upNext.push(up);
    while (downNext.length > 60) {
      downNext.shift();
    }
    while (upNext.length > 60) {
      upNext.shift();
    }
    this.downHistory = downNext;
    this.upHistory = upNext;
  }

  private numOf(value: Object | null | undefined): number {
    return typeof value === 'number' ? value as number : 0;
  }

  private modeText(raw: string): string {
    if (raw === 'global') {
      return '全局';
    }
    if (raw === 'direct') {
      return '直连';
    }
    if (raw === 'rule') {
      return '规则';
    }
    return raw;
  }

  /**
   * 和首页 CurrentProxyCard 的选组逻辑对齐：
   * - 全局模式取 GLOBAL；
   * - 直连模式显示 DIRECT；
   * - 规则模式优先取 自动选择/节点选择/select/auto/proxy，而不是 JSON 里的第一个组。
   */
  private pickGroup(map: Record<string, Object | null>): string {
    if (this.mode === '全局') {
      return map['GLOBAL'] !== undefined ? 'GLOBAL' : '';
    }
    if (this.mode === '直连') {
      return '';
    }
    const names = Object.keys(map);
    let fallback = '';
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      if (name === 'GLOBAL' || name === 'DIRECT' || name === 'REJECT') {
        continue;
      }
      const item = map[name];
      if (item === undefined || item === null || typeof item !== 'object') {
        continue;
      }
      const record = item as Record<string, Object | null>;
      const type = record['type'];
      if (type !== 'Selector' && type !== 'URLTest') {
        continue;
      }
      if (record['hidden'] === true) {
        continue;
      }
      if (fallback.length === 0) {
        fallback = name;
      }
      const lower = name.toLowerCase();
      if (lower.includes('auto') || lower.includes('select') || lower.includes('proxy') ||
        name.includes('自动选择') || name.includes('节点选择')) {
        return name;
      }
    }
    return fallback;
  }

  private readNode(proxies: Record<string, Object | null>): void {
    const group = proxies['proxies'];
    if (group === undefined || group === null || typeof group !== 'object') {
      return;
    }
    const map = group as Record<string, Object | null>;
    if (this.mode === '直连') {
      this.node = 'DIRECT';
      this.nodeType = 'DIRECT';
      this.nodeUdp = false;
      this.nodeDelay = 0;
      return;
    }
    const groupName = this.pickGroup(map);
    if (groupName.length === 0) {
      return;
    }
    const groupItem = map[groupName];
    if (groupItem === undefined || groupItem === null || typeof groupItem !== 'object') {
      return;
    }
    const record = groupItem as Record<string, Object | null>;
    const now = record['now'];
    if (typeof now !== 'string' || now.length === 0) {
      return;
    }
    this.node = now as string;
    const selected = map[now];
    if (selected !== undefined && selected !== null && typeof selected === 'object') {
      const detail = selected as Record<string, Object | null>;
      const type = detail['type'];
      this.nodeType = typeof type === 'string' ? type as string : '';
      this.nodeUdp = detail['udp'] === true;
      this.nodeDelay = this.lastDelay(detail['history']);
    }
  }

  private lastDelay(history: Object | null | undefined): number {
    if (!Array.isArray(history)) {
      return 0;
    }
    const list = history as Record<string, Object | null>[];
    if (list.length === 0) {
      return 0;
    }
    const delay = list[list.length - 1]['delay'];
    return typeof delay === 'number' ? delay as number : 0;
  }

  private async fetchIp(): Promise<void> {
    try {
      // TUN 关：直连真实出口；TUN 开：走本地 mixed-port，和 Windows 的行为一致。
      this.syncAppProxy();
      let result = await HttpClient.request('https://api.ip.sb/geoip', http.RequestMethod.GET, '', {}, 6000);
      if (this.tunOn && (result.error.length > 0 || result.code !== 200)) {
        result = await HttpClient.requestViaProxy('https://api.ip.sb/geoip', this.proxyPort, 6000);
      }
      if (result.error.length > 0 || result.code !== 200) {
        // 已经有 IP（缓存或上一次成功）时不要再报错：
        // 否则会出现"上面明明显示着 IP、旁边却写获取失败"，而且要等下一轮才消。
        if (this.ip === '--') {
          this.ipError = 'IP 信息获取失败';
        }
        return;
      }
      const data = JSON.parse(result.body) as Record<string, Object | null>;
      const ip = data['ip'];
      if (typeof ip !== 'string') {
        if (this.ip === '--') {
          this.ipError = 'IP 信息获取失败';
        }
        return;
      }
      this.ipError = '';
      this.ip = ip as string;
      this.country = this.textOf(data['country'], '未知');
      this.countryCode = this.textOf(data['country_code'], '');
      this.isp = this.textOf(data['isp'], this.textOf(data['organization'], '--'));
      this.org = this.textOf(data['organization'], this.textOf(data['asn_organization'], '--'));
      const city = this.textOf(data['city'], '');
      const region = this.textOf(data['region'], '');
      this.location = [this.country, region, city].filter((v: string): boolean => v.length > 0).join(' · ');
      this.timezone = this.textOf(data['timezone'], '--');
      const asn = data['asn'];
      this.asn = typeof asn === 'number' ? `AS${asn as number}` : this.textOf(data['asn_organization'], '--');
      this.saveIpCache();
    } catch (e) {
      if (this.ip === '--') {
        this.ipError = 'IP 信息获取失败';
      }
    }
  }

  private textOf(value: Object | null | undefined, fallback: string): string {
    if (typeof value === 'string' && (value as string).length > 0) {
      return value as string;
    }
    return fallback;
  }

  private async setMode(mode: string): Promise<void> {
    const secret = this.readSecret();
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (secret.length > 0) {
      headers['Authorization'] = `Bearer ${secret}`;
    }
    const body = JSON.stringify({ mode: mode });
    const result = await HttpClient.request(
      `http://${CONTROLLER_HOST}:${CONTROLLER_PORT}/configs`,
      http.RequestMethod.PATCH, body, headers, 2500);
    Log.i('TrayPanel', `set mode ${mode}: code=${result.code} error=${result.error}`);
    if (result.code === 204 || result.code === 200) {
      this.mode = this.modeText(mode);
      // 落盘：面板与主进程是两个进程，但共用同一个沙箱目录。
      // 不落盘的话，主进程那边一开/关 TUN（重载整核）就会把模式冲回订阅里的 rule。
      this.saveMode(mode);
      // 主界面是独立进程：通过公共事件让它 invalidate getClashMode/getRuntimeConfig。
      this.notifyMain();
      if (this.tunOn) {
        this.lastIpFetch = 0;
        this.fetchIp();
      }
    }
  }

  /** 把模式写进与 RuntimeConfig 约定同一个文件（verge/clash-mode.txt） */
  private saveMode(mode: string): void {
    if (mode !== 'rule' && mode !== 'global' && mode !== 'direct') {
      return;
    }
    try {
      FsUtil.writeText(`${this.filesDir()}/verge/clash-mode.txt`, mode);
      Log.i('TrayPanel', `mode saved: ${mode}`);
    } catch (e) {
      Log.w('TrayPanel', `save mode failed: ${Log.err(e as Object)}`);
    }
  }

  private notifyMain(): void {
    // 公共事件不会把主窗拉到前台，面板可以继续留在桌面上。
    try {
      commonEventManager.publish('com.lyldeer.clashverge.TRAY_REFRESH', (err: BusinessError): void => {
        if (err) {
          Log.w('TrayPanel', `notify main event failed: ${err.code}`);
        }
      });
    } catch (e) {
      Log.w('TrayPanel', `notify main publish failed: ${Log.err(e as Object)}`);
    }
  }

  /**
   * 托盘面板与主进程是两个进程，TUN 只能靠 IPC 下发。
   *
   * ⚠️ 这里**不能**用 startAbility：它会把主窗口拉到前台（主人反馈"点虚拟网卡开关会弹出主界面"）。
   * 改成公共事件后：主进程在后台把 TUN 起好，面板保持打开、开关就地翻过去。
   */
  private toggleTun(enabled: boolean): void {
    this.tunOn = enabled;
    try {
      // publish 没有「字符串 data」的重载：第二个参数必须是 CommonEventPublishData，
      // 指令字符串放在 .data 里（EntryAbility 侧读 CommonEventData.data）
      const options: commonEventManager.CommonEventPublishData = {
        data: enabled ? 'tun-on' : 'tun-off',
      };
      commonEventManager.publish('com.lyldeer.clashverge.TRAY_COMMAND', options,
        (err: BusinessError): void => {
          if (err) {
            Log.w('TrayPanel', `publish tun command failed: ${err.code}`);
          }
        });
      Log.i('TrayPanel', `tun command sent: ${enabled}`);
    } catch (e) {
      this.tunOn = !enabled;
      Log.w('TrayPanel', `tun command throw: ${Log.err(e as Object)}`);
    }
  }

  private openPage(path: string): void {
    const ctx = getContext(this) as common.UIExtensionContext;
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: 'EntryAbility',
      parameters: { trayPage: path },
    };
    ctx.startAbility(want).then((): void => {
      ctx.terminateSelf().catch((e: Object) => {
        Log.w('TrayPanel', `terminate self failed: ${Log.err(e)}`);
      });
    }).catch((e: Object) => {
      Log.w('TrayPanel', `open page failed: ${Log.err(e)}`);
    });
  }

  /** 数值与单位分开返回：版式上数值 L2、单位 L4，和主页 CompactStatCard 一致 */
  private formatValue(bytes: number): string {
    if (bytes < 1024) {
      return `${Math.round(bytes)}`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)}`;
    }
    if (bytes < 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(1)}`;
    }
    return `${(bytes / 1024 / 1024 / 1024).toFixed(2)}`;
  }

  private formatUnit(bytes: number): string {
    if (bytes < 1024) {
      return 'B';
    }
    if (bytes < 1024 * 1024) {
      return 'KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return 'MB';
    }
    return 'GB';
  }

  private drawChart(): void {
    if (!this.canvasReady) {
      return;
    }
    const w = this.chartW;
    const h = this.chartH;
    if (w < 20 || h < 20) {
      return;
    }
    try {
      const ctx = this.chartCtx;
      ctx.clearRect(0, 0, w, h);
      const top = 8;
      const bottom = 8;
      const left = 2;
      const right = 2;
      const innerH = h - top - bottom;
      const innerW = w - left - right;
      ctx.strokeStyle = this.pal.grid;
      ctx.lineWidth = 1;
      for (let i = 0; i <= 3; i++) {
        const y = top + (innerH * i) / 3;
        ctx.beginPath();
        ctx.moveTo(left, y);
        ctx.lineTo(left + innerW, y);
        ctx.stroke();
      }

      const count = Math.max(this.downHistory.length, this.upHistory.length);
      if (count < 2) {
        return;
      }
      let max = 1;
      for (let i = 0; i < this.downHistory.length; i++) {
        if (this.downHistory[i] > max) {
          max = this.downHistory[i];
        }
      }
      for (let i = 0; i < this.upHistory.length; i++) {
        if (this.upHistory[i] > max) {
          max = this.upHistory[i];
        }
      }

      // 下载面积
      ctx.beginPath();
      for (let i = 0; i < this.downHistory.length; i++) {
        const value = this.downHistory[i];
        const x = left + (innerW * i) / (count - 1);
        const y = top + innerH - (value / max) * innerH;
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      const lastDownX = left + (innerW * (this.downHistory.length - 1)) / (count - 1);
      ctx.lineTo(lastDownX, top + innerH);
      ctx.lineTo(left, top + innerH);
      ctx.closePath();
      const gradient = ctx.createLinearGradient(0, top, 0, top + innerH);
      gradient.addColorStop(0, this.pal.dark ? 'rgba(49,122,247,0.34)' : 'rgba(10,89,247,0.30)');
      gradient.addColorStop(1, this.pal.dark ? 'rgba(49,122,247,0.02)' : 'rgba(10,89,247,0.02)');
      ctx.fillStyle = gradient;
      ctx.fill();

      // 下载折线
      ctx.beginPath();
      for (let i = 0; i < this.downHistory.length; i++) {
        const value = this.downHistory[i];
        const x = left + (innerW * i) / (count - 1);
        const y = top + innerH - (value / max) * innerH;
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.strokeStyle = this.pal.down;
      ctx.lineWidth = 2;
      ctx.stroke();

      // 上传折线
      ctx.beginPath();
      for (let i = 0; i < this.upHistory.length; i++) {
        const value = this.upHistory[i];
        const x = left + (innerW * i) / (count - 1);
        const y = top + innerH - (value / max) * innerH;
        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
      }
      ctx.strokeStyle = this.pal.up;
      ctx.lineWidth = 1.5;
      ctx.stroke();
    } catch (e) {
      Log.w('TrayPanel', `draw chart failed: ${Log.err(e as Object)}`);
    }
  }

  // ───────────────────────── 视觉构件 ─────────────────────────
  // ⚠️ 只保留「参数与状态无关」的 @Builder。ArkUI 的 @Builder 是**按值传递**：
  //    当参数来自状态变量时，状态变化不一定触发 Builder 内 UI 刷新（官方文档明确提示）。
  //    流量数字、IP、模式选中态都是每秒变的，必须直接在 build() 里读 this.xxx
  //    才能建立依赖，所以这些内容一律内联，不要图省事抽 Builder。

  @Builder
  legendDot(label: string, color: string) {
    Row() {
      Row()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(color)
      Text(label)
        .fontSize(this.fsL4)
        .fontColor(this.pal.font3)
        .margin({ left: 4 })
    }
    .margin({ left: 10 })
  }

  build() {
    Column() {
      // ── 面板本体：只有这一层铺底色，下面的透明测试带才能真的透出桌面 ──
      Column() {
        // ── 顶部：当前订阅 ──
        Row() {
          Text(this.subName)
            .fontSize(this.fsL2)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal.font1)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subUpdated.length > 0 ? `更新于 ${this.subUpdated}` : '')
            .fontSize(this.fsL4)
            .fontColor(this.pal.font3)
            .margin({ left: 8 })
        }
        .width('100%')
        .padding({ left: this.padPage, right: this.padPage, top: 12, bottom: 14 })

        Scroll() {
          Column() {
            // ── 卡片 1：当前节点 ──
            Column() {
              Row() {
                Text('当前节点')
                  .fontSize(this.fsL2)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal.font1)
                Blank()
                Button('代理 >')
                  .type(ButtonType.Capsule)
                  .height(28)
                  .fontSize(this.fsL4)
                  .fontColor(this.pal.font1)
                  .backgroundColor(this.pal.btnRest)
                  .padding({ left: 12, right: 12 })
                  .onClick((): void => {
                    this.openPage('/proxies');
                  })
              }
              .width('100%')

              Text(this.node)
                .fontSize(this.fsL2)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.pal.font1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 8 })
                .width('100%')

              Row() {
                Text(this.nodeType.length > 0 ? this.nodeType : '--')
                  .fontSize(this.fsL3)
                  .lineHeight(this.metaH)
                  .fontColor(this.pal.font2)
                if (this.nodeUdp) {
                  // 胶囊只加左右内边距：上下留 0，高度就严格等于 lineHeight，
                  // 和左边的类型文字是同一个行盒，不会再错位。
                  Text('UDP')
                    .fontSize(this.fsL4)
                    .lineHeight(this.metaH)
                    .fontColor(this.pal.font2)
                    .padding({ left: 7, right: 7 })
                    .backgroundColor(this.pal.btnRest)
                    .borderRadius(this.metaH / 2)
                    .margin({ left: 8 })
                }
                Blank()
                if (this.nodeDelay > 0) {
                  Text(`${this.nodeDelay} ms`)
                    .fontSize(this.fsL3)
                    .lineHeight(this.metaH)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.pal.ok)
                    .padding({ left: 8, right: 8 })
                    .backgroundColor(this.pal.okFill)
                    .borderRadius(this.metaH / 2)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .margin({ top: 8 })
            }
            .width('100%')
            .padding(this.padCard)
            .borderRadius(16)
            .backgroundColor(this.pal.card)
            .border({ width: 1, color: this.pal.border })
            .margin({ bottom: this.gapCard })

            // ── 卡片 2：代理模式 ──
            Column() {
              Row() {
                Text('代理模式')
                  .fontSize(this.fsL2)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal.font1)
                Blank()
              }
              .width('100%')

              Row({ space: 8 }) {
                Button('规则')
                  .type(ButtonType.Capsule)
                  .height(40)
                  .layoutWeight(1)
                  .fontSize(this.fsL2)
                  .fontWeight(this.mode === '规则' ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor(this.mode === '规则' ? this.pal.onBrand : this.pal.font1)
                  .backgroundColor(this.mode === '规则' ? this.pal.brand : this.pal.btnRest)
                  .onClick((): void => {
                    this.setMode('rule');
                  })
                Button('全局')
                  .type(ButtonType.Capsule)
                  .height(40)
                  .layoutWeight(1)
                  .fontSize(this.fsL2)
                  .fontWeight(this.mode === '全局' ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor(this.mode === '全局' ? this.pal.onBrand : this.pal.font1)
                  .backgroundColor(this.mode === '全局' ? this.pal.brand : this.pal.btnRest)
                  .onClick((): void => {
                    this.setMode('global');
                  })
                Button('直连')
                  .type(ButtonType.Capsule)
                  .height(40)
                  .layoutWeight(1)
                  .fontSize(this.fsL2)
                  .fontWeight(this.mode === '直连' ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor(this.mode === '直连' ? this.pal.onBrand : this.pal.font1)
                  .backgroundColor(this.mode === '直连' ? this.pal.brand : this.pal.btnRest)
                  .onClick((): void => {
                    this.setMode('direct');
                  })
              }
              .width('100%')
              .margin({ top: 12 })
            }
            .width('100%')
            .padding(this.padCard)
            .borderRadius(16)
            .backgroundColor(this.pal.card)
            .border({ width: 1, color: this.pal.border })
            .margin({ bottom: this.gapCard })

            // ── 卡片 3：网络设置（此前漏了卡片标题） ──
            Column() {
              Row() {
                Text('网络设置')
                  .fontSize(this.fsL2)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal.font1)
                Blank()
                Text(this.tunOn ? '已开启' : '已关闭')
                  .fontSize(this.fsL4)
                  .fontColor(this.pal.font3)
              }
              .width('100%')

              Row() {
                Column() {
                  Text('虚拟网卡模式')
                    .fontSize(this.fsL2)
                    .fontColor(this.pal.font1)
                  Text('TUN 模式可接管全部应用流量')
                    .fontSize(this.fsL4)
                    .fontColor(this.pal.font3)
                    .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.tunOn })
                  .onChange((isOn: boolean): void => {
                    this.toggleTun(isOn);
                  })
              }
              .width('100%')
              .margin({ top: 12 })
            }
            .width('100%')
            .padding(this.padCard)
            .borderRadius(16)
            .backgroundColor(this.pal.card)
            .border({ width: 1, color: this.pal.border })
            .margin({ bottom: this.gapCard })

            // ── 卡片 4：流量统计（与主页一致：图 + 六项指标 = 共七项） ──
            Column() {
              Row() {
                Text('流量统计')
                  .fontSize(this.fsL2)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal.font1)
                Blank()
                Text(`${this.connectionCount} 连接`)
                  .fontSize(this.fsL4)
                  .fontColor(this.pal.font3)
              }
              .width('100%')

              Stack({ alignContent: Alignment.TopEnd }) {
                Canvas(this.chartCtx)
                  .width('100%')
                  .height(this.chartH)
                  .onReady((): void => {
                    this.canvasReady = true;
                    this.drawChart();
                  })
                  .onAreaChange((_oldValue: Area, newValue: Area): void => {
                    const nextW = Number(newValue.width);
                    const nextH = Number(newValue.height);
                    if (!Number.isNaN(nextW) && nextW > 0) {
                      this.chartW = nextW;
                    }
                    if (!Number.isNaN(nextH) && nextH > 0) {
                      this.chartH = nextH;
                    }
                    this.drawChart();
                  })
                Row() {
                  this.legendDot('上传', this.pal.up)
                  this.legendDot('下载', this.pal.down)
                }
                .margin({ top: 2, right: 2 })
              }
              .width('100%')
              .height(this.chartH)
              .margin({ top: 8 })

              // ① 上传速度 / ② 下载速度
              Row({ space: 8 }) {
                Column() {
                  Row() {
                    Row()
                      .width(6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.pal.up)
                    Text('上传速度')
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 6 })
                  }
                  .width('100%')

                  Row() {
                    Text(this.formatValue(this.upSpeed))
                      .fontSize(this.fsL2)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.pal.font1)
                    Text(`${this.formatUnit(this.upSpeed)}/s`)
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 2, bottom: 1 })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Bottom)
                  .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .padding(8)
                .borderRadius(12)
                .backgroundColor(this.pal.tile)

                Column() {
                  Row() {
                    Row()
                      .width(6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.pal.down)
                    Text('下载速度')
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 6 })
                  }
                  .width('100%')

                  Row() {
                    Text(this.formatValue(this.downSpeed))
                      .fontSize(this.fsL2)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.pal.font1)
                    Text(`${this.formatUnit(this.downSpeed)}/s`)
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 2, bottom: 1 })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Bottom)
                  .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .padding(8)
                .borderRadius(12)
                .backgroundColor(this.pal.tile)
              }
              .width('100%')
              .margin({ top: 8 })

              // ③ 上传量 / ④ 下载量
              Row({ space: 8 }) {
                Column() {
                  Row() {
                    Row()
                      .width(6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.pal.up)
                    Text('上传量')
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 6 })
                  }
                  .width('100%')

                  Row() {
                    Text(this.formatValue(this.upTotal))
                      .fontSize(this.fsL2)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.pal.font1)
                    Text(this.formatUnit(this.upTotal))
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 2, bottom: 1 })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Bottom)
                  .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .padding(8)
                .borderRadius(12)
                .backgroundColor(this.pal.tile)

                Column() {
                  Row() {
                    Row()
                      .width(6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.pal.down)
                    Text('下载量')
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 6 })
                  }
                  .width('100%')

                  Row() {
                    Text(this.formatValue(this.downTotal))
                      .fontSize(this.fsL2)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.pal.font1)
                    Text(this.formatUnit(this.downTotal))
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 2, bottom: 1 })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Bottom)
                  .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .padding(8)
                .borderRadius(12)
                .backgroundColor(this.pal.tile)
              }
              .width('100%')
              .margin({ top: 8 })

              // ⑤ 活跃连接 / ⑥ 内核占用
              Row({ space: 8 }) {
                Column() {
                  Row() {
                    Row()
                      .width(6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.pal.ok)
                    Text('活跃连接')
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 6 })
                  }
                  .width('100%')

                  Row() {
                    Text(`${this.connectionCount}`)
                      .fontSize(this.fsL2)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.pal.font1)
                    Text('个')
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 2, bottom: 1 })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Bottom)
                  .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .padding(8)
                .borderRadius(12)
                .backgroundColor(this.pal.tile)

                Column() {
                  Row() {
                    Row()
                      .width(6)
                      .height(6)
                      .borderRadius(3)
                      .backgroundColor(this.pal.up)
                    Text('内核占用')
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 6 })
                  }
                  .width('100%')

                  Row() {
                    Text(this.memOk ? this.formatValue(this.memInuse) : '--')
                      .fontSize(this.fsL2)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.pal.font1)
                    Text(this.memOk ? this.formatUnit(this.memInuse) : '')
                      .fontSize(this.fsL4)
                      .fontColor(this.pal.font3)
                      .margin({ left: 2, bottom: 1 })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Bottom)
                  .margin({ top: 4 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .padding(8)
                .borderRadius(12)
                .backgroundColor(this.pal.tile)
              }
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
            .padding(this.padCard)
            .borderRadius(16)
            .backgroundColor(this.pal.card)
            .border({ width: 1, color: this.pal.border })
            .margin({ bottom: this.gapCard })

            // ── 卡片 5：IP 信息 ──
            Column() {
              Row() {
                Text('IP 信息')
                  .fontSize(this.fsL2)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal.font1)
                Blank()
                if (this.countryCode.length > 0) {
                  Text(this.countryCode)
                    .fontSize(this.fsL4)
                    .fontColor(this.pal.font2)
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .backgroundColor(this.pal.tile)
                    .borderRadius(8)
                }
              }
              .width('100%')

              Row() {
                Text(this.country)
                  .fontSize(this.fsL1)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal.font1)
                if (this.ipError.length > 0) {
                  Text(this.ipError)
                    .fontSize(this.fsL4)
                    .fontColor('#E84026')
                    .margin({ left: 8 })
                }
              }
              .width('100%')
              .margin({ top: 8, bottom: 8 })

              Row() {
                Text('IP')
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font2)
                  .width(56)
                Text(this.ip)
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font1)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .margin({ bottom: 4 })

              Row() {
                Text('服务商')
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font2)
                  .width(56)
                Text(this.isp)
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font1)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .margin({ bottom: 4 })

              Row() {
                Text('组织')
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font2)
                  .width(56)
                Text(this.org)
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font1)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .margin({ bottom: 4 })

              Row() {
                Text('位置')
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font2)
                  .width(56)
                Text(this.location)
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font1)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .margin({ bottom: 4 })

              Row() {
                Text('时区')
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font2)
                  .width(56)
                Text(this.timezone)
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font1)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .margin({ bottom: 4 })

              Row() {
                Text('自治域')
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font2)
                  .width(56)
                Text(this.asn)
                  .fontSize(this.fsL3)
                  .fontColor(this.pal.font1)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
            }
            .width('100%')
            .padding(this.padCard)
            .borderRadius(16)
            .backgroundColor(this.pal.card)
            .border({ width: 1, color: this.pal.border })
            .margin({ bottom: this.gapCard })
          }
          .width('100%')
          .padding({ left: this.padPage, right: this.padPage, bottom: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Fade)

        // ── 底部动作：菜单行（官方 NORMAL 控件高度 40vp / 16fp），此前是 19fp/52vp 的大字 ──
        Divider()
          .strokeWidth(1)
          .color(this.pal.divider)
        Row() {
          Text('打开 Clash Verge')
            .fontSize(this.fsL2)
            .fontColor(this.pal.font1)
          Blank()
        }
        .width('100%')
        .height(this.hMenuRow)
        .padding({ left: this.padPage, right: this.padPage })
        .borderRadius(12)
        .hoverEffect(HoverEffect.Highlight)
        .onClick((): void => {
          this.openPage('/');
        })
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(this.pal.panel)
      .border({ width: 1, color: this.pal.border })

    }
    .width('100%')
    .height('100%')
    // 根节点故意不铺任何底色：窗口本身就是透明的，玻璃模式下面板才能真的透出桌面。
    // 面板底色挂在内层 Column 上，想调透出量只改 pal.panel 一处。

  }
}
