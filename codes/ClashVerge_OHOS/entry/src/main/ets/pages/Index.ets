import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';

import { AppBridge } from '../bridge/AppBridge';
import { JsBridge } from '../bridge/JsBridge';
import { AppCtx } from '../common/AppCtx';
import { Log } from '../common/Logger';
import { WebOrigin } from '../common/WebOrigin';

/** loadUrl 兜底重试参数（模块级常量：@Component struct 内不放 static 成员） */
const NAV_RETRY: number = 6;
const NAV_RETRY_GAP_MS: number = 500;
/**
 * 开屏 logo 的边长（vp）。
 *
 * 尺寸语义：**系统启动页已经不画 logo 了**（startIcon 换成 512×512 全透明，
 * 因为系统启动页只认系统深浅色，做不到"跟应用主题"），开屏这一枚由我们自己画。
 * 上一版系统启动页是 1024px 画布、内容 86% → 881px；`startWindowIcon` 是
 * **按图片像素大小居中显示**（官方明确不随窗口自适应），屏幕密度 1.9 → 视觉 ≈464vp。
 *
 * 调参记录：464 → 75%（348vp）→ 再缩到"现在的 60%"（≈209vp，取 208）。
 * 觉得还大/小了只改这一个数，其余布局都是居中的。
 */
const SPLASH_LOGO_VP: number = 208;

/**
 * 开屏字标（"Clash Verge" 那行）的宽度。
 *
 * 不再用系统字体写文字：上游 `webapp/src/assets/image/logo.svg` 就是首页左上角
 * 那个字标（纯字形路径，viewBox 117×27，宽高比 ≈5.79），和界面里的完全同源。
 * 同样用 logs/tools/svgcat.py 光栅化（多 path 并集），黑白两版跟应用主题。
 * 高度按比例算：200 / 5.79 ≈ 34.5vp。
 */
const SPLASH_WORD_W_VP: number = 200;
const SPLASH_WORD_ASPECT: number = 5.79;

/**
 * 应用唯一页面：一个铺满窗口的 ArkWeb，里面跑上游 Clash Verge 的 React 前端。
 *
 * 地址**在构造 Web 时就是对的**（`EntryAbility` 已先把本地服务起好，见 WebOrigin 注释）。
 * 实机日志（11-14 00:13）证明 `WebOptions.src` 只在组件创建时被采纳：
 * 先用 about:blank 创建、之后再改状态变量，Chromium 只会收到 `LoadUrl url:about:blank`，
 * 真实地址永远不会被导航 —— 表现就是黑屏 + 本地服务收不到任何请求。
 */
/**
 * 窗口拖动 / 双击最大化钩子（注入到 Web 页）。
 *
 * Tauri 的语义是：在 `[data-tauri-drag-region]` 元素上**按下**就发起窗口拖动。
 * 但鸿蒙的 `Window.startMoving()` 对**最大化**窗口的语义是「先还原，再跟着鼠标走」——
 * 于是「在标题栏点一下」（根本没过拖动阈值）也会把窗口还原，而且还原到的矩形不是
 * 原来那个（我们从没设过 normal bounds）→ 主人看到的
 * 「点一下就变小 / 没动画 / 缩不回原来的位置」。
 *
 * 所以这里改成**拖动阈值**：按下只记坐标，移动超过 5px 才真的开始拖；单点什么都不做。
 * 另外补上「双击 = 最大化/还原」：我们隐藏了系统标题栏（setWindowDecorVisible(false)），
 * 系统那套双击手势在这里不生效，得自己接。
 */
const DRAG_HOOK_JS: string = `(function () {
  if (window.__cgDragHooked) { return; }
  window.__cgDragHooked = true;
  var pending = null;

  function isRegion(t) {
    return !!(t && t.getAttribute && t.getAttribute('data-tauri-drag-region') === 'true');
  }
  function cleanup() {
    document.removeEventListener('mousemove', onMove, true);
    document.removeEventListener('mouseup', onUp, true);
    pending = null;
  }
  function onMove(e) {
    if (!pending) { return; }
    if (Math.abs(e.clientX - pending.x) + Math.abs(e.clientY - pending.y) < 5) { return; }
    cleanup();
    try {
      if (window.clashBridge) {
        window.clashBridge.invoke('plugin:window|start_dragging', '{}', '');
      }
    } catch (err) {}
  }
  function onUp() { cleanup(); }

  document.addEventListener('mousedown', function (e) {
    if (e.button !== 0 || !isRegion(e.target)) { return; }
    pending = { x: e.clientX, y: e.clientY };
    document.addEventListener('mousemove', onMove, true);
    document.addEventListener('mouseup', onUp, true);
  }, true);

  document.addEventListener('dblclick', function (e) {
    if (!isRegion(e.target)) { return; }
    try {
      if (window.clashBridge) {
        window.clashBridge.invoke('plugin:window|toggle_maximize', '{}', '');
      }
    } catch (err) {}
  }, true);
})();`;

@Entry
@Component
struct Index {
  /**
   * **应用**是否深色（theme_mode 叠上系统深浅色，EntryAbility 算好写进 AppStorage）。
   *
   * 开屏与 Web 的 darkMode 都跟它走：主人可能在系统浅色下把应用设成深色，
   * 这时开屏应该是深底白猫，而不是跟系统变白；Web 的 prefers-color-scheme
   * 也必须和应用主题一致，否则 index.html 那张纯 CSS 的加载页会闪反色。
   */
  @StorageProp('appDark') appDark: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: JsBridge = new JsBridge('main');
  private srcUrl: string = 'about:blank';
  private navAttempt: number = 0;
  private pageBegun: boolean = false;
  /** 内核只 boot 一次（页面加载完 / 3s 兜底，谁先到谁算） */
  private coreBooted: boolean = false;

  @State statusText: string = '正在加载界面…';
  @State failed: boolean = false;
  /** 文档加载完成（onPageEnd） */
  @State ready: boolean = false;
  /** Web 里真的有画面了（onFirstContentfulPaint / 兜底）—— 撤启动层的唯一依据 */
  @State painted: boolean = false;
  /** 启动层正在淡出（避免重复触发） */
  @State splashDismissing: boolean = false;
  /** 启动层已彻底移除 */
  @State splashGone: boolean = false;
  @State splashOpacity: number = 1;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    // AppCtx 已在 EntryAbility.onCreate 初始化过（幂等），这里再兜一次：
    // 页面被销毁重建时保证路径可用
    AppCtx.init(context.filesDir, context.cacheDir);
    this.bridge.attach(this.controller);
    AppBridge.install(this.bridge, context);
    Log.i('Index', 'AppBridge installed');

    // 内核常驻（UI 进程）：**不要**在 aboutToAppear 里直接同步启动 ——
    // `clash_core_load` 是阻塞的 cgo 调用（解析订阅、起 listener，甚至拉 rule-provider），
    // 跑在 UI 线程上会把首帧一起卡住。放到页面加载完成后再启动（3s 兜底），
    // 让用户先看到界面，前端自己会轮询接口把数据补齐。
    setTimeout(() => {
      if (!this.ready) {
        this.bootCoreOnce('fallback-timer');
      }
    }, 3000);

    const url = WebOrigin.url;
    if (url.length === 0) {
      this.failed = true;
      this.statusText = `本地服务未启动：${WebOrigin.error}`;
      Log.e('Index', this.statusText);
      return;
    }
    this.srcUrl = url;
    Log.i('Index', `web src = ${this.srcUrl}`);

    // 兜底：正常情况 Web 创建即加载；1.5s 还没开始导航说明 src 没生效，用 loadUrl 补
    setTimeout(() => {
      if (!this.pageBegun && !this.ready) {
        Log.w('Index', 'no navigation after 1.5s, falling back to loadUrl');
        this.navigateOnce();
      }
    }, 1500);

    // 看门狗：12s 仍未加载完成就把错误摆到界面上，而不是让用户面对黑屏
    setTimeout(() => {
      if (!this.ready && !this.failed) {
        this.failed = true;
        this.statusText = `界面加载超时：${this.srcUrl}`;
        Log.e('Index', `page not ready in 12s: ${this.srcUrl}`);
      }
    }, 12000);

    // 启动对账：上次退出时 TUN 是开的就自动拉起，否则把开关修正为关闭
    setTimeout(() => {
      AppBridge.reconcileRuntime().catch((e: Object) => {
        Log.w('Index', `reconcile failed: ${Log.err(e)}`);
      });
    }, 1500);
  }

  /**
   * Web 里已经画出内容了。
   *
   * ⚠️ 之前是「onPageEnd 就撤启动层」，但 onPageEnd 只代表**文档加载完**，
   * 内核那张 surface 还没画出东西 —— 撤掉启动层的那一帧露出来的是 WebView 的
   * 默认白底，于是深色模式下会在「启动页」和「主界面」之间闪一下白。
   * 现在必须等到真正首帧绘制（或 1.5s 兜底）才撤，并且淡出 180ms，不再是硬切。
   */
  private markPainted(reason: string): void {
    if (this.painted) {
      return;
    }
    this.painted = true;
    Log.i('Index', `first paint confirmed (${reason})`);
    this.tryDismissSplash();
  }

  private tryDismissSplash(): void {
    if (this.splashDismissing || this.splashGone) {
      return;
    }
    if (!this.ready || !this.painted) {
      return;
    }
    this.splashDismissing = true;
    Log.i('Index', 'dismiss splash (fade 180ms)');
    animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => {
      this.splashOpacity = 0;
    });
    setTimeout((): void => {
      this.splashGone = true;
    }, 220);
  }

  private navigateOnce(): void {
    if (this.srcUrl === 'about:blank') {
      return;
    }
    this.navAttempt++;
    try {
      this.controller.loadUrl(this.srcUrl);
      Log.i('Index', `loadUrl #${this.navAttempt} -> ${this.srcUrl}`);
    } catch (e) {
      Log.w('Index', `loadUrl #${this.navAttempt} threw: ${Log.err(e as Object)}`);
    }
    if (!this.pageBegun && !this.ready) {
      if (this.navAttempt < NAV_RETRY) {
        setTimeout(() => {
          if (!this.pageBegun && !this.ready) {
            this.navigateOnce();
          }
        }, NAV_RETRY_GAP_MS);
      } else {
        this.failed = true;
        this.statusText = `无法加载界面：${this.srcUrl}`;
        Log.e('Index', `navigation never began after ${this.navAttempt} attempts`);
      }
    }
  }

  /**
   * 启动常驻内核（只一次）。
   *
   * 注意：`CoreHost.ensureStarted` 内部是**同步阻塞**的 cgo 调用，会在调用线程上
   * 解析订阅 + 起 9090/7890 监听。这里刻意放在页面加载完之后调用，
   * 并把耗时打进日志 —— 真机上如果 `core boot end in Nms` 很大（比如订阅带远程
   * rule-provider），就说明该考虑挪到 worker 线程了。
   */
  private bootCoreOnce(reason: string): void {
    if (this.coreBooted) {
      return;
    }
    this.coreBooted = true;
    const startedAt = Date.now();
    Log.i('Index', `core boot begin (${reason})`);
    AppBridge.bootCore().then(() => {
      Log.i('Index', `core boot end in ${Date.now() - startedAt}ms (${reason})`);
    }).catch((e: Object) => {
      Log.w('Index', `bootCore failed: ${Log.err(e)}`);
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Web({ src: this.srcUrl, controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .onlineImageAccess(true)
        .databaseAccess(true)
        .mixedMode(MixedMode.All)
        .cacheMode(CacheMode.Default)
        .darkMode(this.appDark ? WebDarkMode.On : WebDarkMode.Off)
        // 底色给主题色：WebView 未绘制内容时默认是白的，深色下会闪
        .backgroundColor(this.appDark ? '#1B1B1B' : '#F5F5F5')
        // 真正的「画出来了」信号，撤启动层靠它（见 markPainted）
        .onFirstContentfulPaint(() => {
          this.markPainted('first-contentful-paint');
        })
        .zoomAccess(false)
        .javaScriptProxy({
          object: this.bridge,
          name: 'clashBridge',
          methodList: ['invoke', 'log'],
          controller: this.controller,
        })
        .onPageBegin((event) => {
          if (event) {
            Log.i('Web', `page begin: ${event.url}`);
            if (event.url.indexOf('127.0.0.1') >= 0) {
              this.pageBegun = true;
            }
          }
        })
        .onConsole((event) => {
          if (event) {
            // 用 info 级：debug 级在部分版本会被 hilog 级别过滤，而这里正是 JS 报错的第一手信息
            // ⚠️ event.message 是 ConsoleMessage 对象，直接 `${event.message}` 只会得到
            // "[object Object]"（实机日志里就是这样，等于没打）。
            try {
              const message = event.message;
              Log.i('WebConsole', `${message.getSourceId()}:${message.getLineNumber()} ${message.getMessage()}`);
            } catch (e) {
              Log.w('WebConsole', `dump failed: ${Log.err(e as Object)}`);
            }
          }
          return false;
        })
        .onPageEnd((event) => {
          if (event) {
            Log.i('Web', `page end: ${event.url}`);
            if (event.url.indexOf('127.0.0.1') >= 0) {
              this.ready = true;
              this.failed = false;
              // 若首帧回调已经先到（ready 晚于 paint），这里立刻撤启动层；
              // 否则等 markPainted 里那一次 tryDismissSplash
              this.tryDismissSplash();
              // 兜底：个别情况下 onFirstContentfulPaint 不回调（页面全透明 / 版本差异），
              // 1.5s 后强制认为已绘制，别让启动层卡住
              setTimeout((): void => {
                this.markPainted('page-end-fallback');
              }, 1500);
              // 界面已经出来了，这时候再启动内核不会卡首帧
              this.bootCoreOnce('page-end');
              // 首帧后把系统深浅色同步给前端（跟随系统模式下靠它确定初始主题）
              AppBridge.syncSystemTheme();
              // 补上 Tauri 的拖动语义：data-tauri-drag-region 元素上按下 = 拖窗口
              this.controller.runJavaScript(DRAG_HOOK_JS).catch((e: Object) => {
                Log.w('Web', `inject drag hook failed: ${Log.err(e)}`);
              });
            }
          }
        })
        .onErrorReceive((event) => {
          if (event) {
            const info = event.error.getErrorInfo();
            const url = event.request.getRequestUrl();
            const mainFrame = event.request.isMainFrame();
            Log.e('Web', `load error: ${info} url=${url} mainFrame=${mainFrame}`);
            // 只有主框架失败才算页面挂了；子资源（字体/图标）失败不该挡住界面
            if (mainFrame) {
              this.failed = true;
              this.statusText = `加载失败：${info}`;
            }
          }
        })
        .onHttpErrorReceive((event) => {
          if (event) {
            Log.w('Web', `http ${event.response.getResponseCode()} ${event.request.getRequestUrl()}`);
          }
        })

      if (!this.splashGone) {
        Column({ space: 12 }) {
          /*
           * 开屏 logo：纯白 / 纯黑两版，**跟应用主题**（appDark）走。
           *
           * 素材来源是前端仓库里的矢量图（webapp/src/assets/image/icon_dark.svg），
           * 用 logs/tools/svgcat.py 自己光栅化到 1024（扫描线填充 + 4×4 超采样），
           * 所以边缘是真正的抗锯齿 —— 上一版是从 144px 位图放大来的，锯齿就在那。
           *
           * ⚠️ 正常加载时这里**只有 logo + 应用名**：不再显示转圈和"正在加载界面…"。
           * 一个一直在转的进度环反而让人觉得"这软件好慢"，开屏本身已经表明了状态；
           * 转圈/状态文案只在**出错**时才有意义（见下面的 failed 分支）。
           */
          Image(this.appDark ? $r('app.media.splashLogoDark') : $r('app.media.splashLogoLight'))
            .width(SPLASH_LOGO_VP)
            .height(SPLASH_LOGO_VP)
            .objectFit(ImageFit.Contain)
            .draggable(false)
          /*
           * 字标改用首页左上角那枚（logo.svg 光栅化），字体与界面完全一致 ——
           * 之前用系统字体写 "Clash Verge"，和界面里的字标对不上，显得不规整。
           */
          Image(this.appDark ? $r('app.media.splashWordDark') : $r('app.media.splashWordLight'))
            .width(SPLASH_WORD_W_VP)
            .height(SPLASH_WORD_W_VP / SPLASH_WORD_ASPECT)
            .objectFit(ImageFit.Contain)
            .draggable(false)
            .margin({ top: 10 })
          if (this.failed) {
            Text('界面没能加载出来')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .margin({ top: 10 })
            Text(this.statusText)
              .fontSize(13)
              .fontColor(this.appDark ? '#99FFFFFF' : '#666666')
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })
            Button('重试')
              .fontSize(15)
              .height(36)
              .padding({ left: 24, right: 24 })
              .onClick(() => {
                this.failed = false;
                this.statusText = '正在重新加载…';
                this.pageBegun = false;
                this.navAttempt = 0;
                // 重试时重新取一次 URL：可能刚才只是本地服务起得慢
                if (WebOrigin.url.length > 0) {
                  this.srcUrl = WebOrigin.url;
                }
                this.navigateOnce();
              })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.appDark ? '#1B1B1B' : '#F5F5F5')
        .opacity(this.splashOpacity)
        // 淡出期间立刻放行点击，别挡住已经出来的界面
        .hitTestBehavior(this.splashDismissing ? HitTestMode.None : HitTestMode.Default)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.appDark ? '#1B1B1B' : '#F5F5F5')
  }
}
