/**
 * 前端 origin 的跨模块传递。
 *
 * LocalServer 在 `EntryAbility.onWindowStageCreate` 里（`loadContent` 之前）启动，
 * 页面构建时直接拿到 URL 作为 `Web({ src })` 的初值 —— 这是关键：
 * 实机日志证明 `WebOptions.src` **只在组件创建时被采纳**，
 * 若先用 `about:blank` 创建、之后再改状态或 `loadUrl`，创建时那次
 * `about:blank` 导航会把真实导航覆盖掉（表现为黑屏且本地服务收不到请求）。
 */
export class WebOrigin {
  /** 形如 http://127.0.0.1:45123/index.html；启动失败时为空串 */
  static url: string = '';
  /** 启动失败原因，供页面显示 */
  static error: string = '';
}
