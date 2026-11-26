import { http } from '@kit.NetworkKit';

import { CONTROLLER_HOST, CONTROLLER_PORT, MIHOMO_VERSION } from '../common/Constants';
import { Log } from '../common/Logger';
import { HttpClient, HttpResult } from '../core/HttpClient';
import { MihomoWsHost } from '../core/MihomoWsHost';
import { JsBridge } from './JsBridge';

/**
 * `plugin:mihomo|*` 命令族 → mihomo REST 的等价实现。
 *
 * 上游这些命令由 Rust 插件（tauri-plugin-mihomo）完成；鸿蒙侧没有 Rust 层，
 * 直接由 ArkTS 转发到 127.0.0.1:<controller>。内核没起来时返回"空结构"而不是报错，
 * 保证界面能渲染（HANDOFF H1）。
 */
export class MihomoBridge {
  private static host: string = CONTROLLER_HOST;
  private static port: number = CONTROLLER_PORT;
  private static secret: string = '';

  static setController(host: string, port: number): void {
    if (host.length > 0) {
      MihomoBridge.host = host;
    }
    if (port > 0) {
      MihomoBridge.port = port;
    }
    Log.i('Mihomo', `controller -> ${MihomoBridge.host}:${MihomoBridge.port}`);
  }

  static setSecret(secret: string): void {
    MihomoBridge.secret = secret;
  }

  static baseUrl(): string {
    return `http://${MihomoBridge.host}:${MihomoBridge.port}`;
  }

  /** 托盘菜单切模式用（和 plugin:mihomo|* 走同一套鉴权） */
  static async setMode(mode: string): Promise<void> {
    const body = JSON.stringify({ mode: mode });
    await MihomoBridge.call(http.RequestMethod.PATCH, '/configs', body);
  }

  private static async call(method: http.RequestMethod, path: string, body: string,
    timeoutMs: number = 5000): Promise<HttpResult> {
    const headers: Record<string, string> = {};
    headers['Content-Type'] = 'application/json';
    if (MihomoBridge.secret.length > 0) {
      headers['Authorization'] = `Bearer ${MihomoBridge.secret}`;
    }
    return HttpClient.request(`${MihomoBridge.baseUrl()}${path}`, method, body, headers, timeoutMs);
  }

  // ---- 测速并发闸门 ----
  //
  // 为什么需要：测速时前端会**一次性并发**打几十个 `/proxies/{name}/delay`，全部走
  // ArkTS 的 `@ohos.net.http`。实测（2026-11-19 12:11 日志）：
  //   平时点节点切换 14–17ms；测速批次进行中切同一个节点要 **902 / 1204 / 1208ms**。
  //   同一时刻还有两条 delay 被 5s 超时截断（`code=2300028 Operation timeout`）。
  // 说明本地 http 通道的连接槽被测速请求占满，切换请求排在后面。
  // 这里给测速加一个并发上限，把槽位留给切换 / 刷新这类交互请求。
  private static delayActive: number = 0;
  private static delayWaiting: Array<() => void> = [];
  /**
   * 同时最多 6 个测速请求。
   *
   * 之前是 8；真机日志显示内核在批量测速时会把控制器拖到 3–5s 不响应，
   * 进一步压低并发，给切换/刷新留出 CPU 与连接槽。
   */
  private static readonly DELAY_MAX: number = 6;

  private static async enterDelayGate(): Promise<void> {
    if (MihomoBridge.delayActive < MihomoBridge.DELAY_MAX) {
      MihomoBridge.delayActive++;
      return;
    }
    await new Promise<void>((resolve: (value: void) => void): void => {
      MihomoBridge.delayWaiting.push((): void => {
        resolve();
      });
    });
    MihomoBridge.delayActive++;
  }

  private static leaveDelayGate(): void {
    MihomoBridge.delayActive--;
    if (MihomoBridge.delayActive < 0) {
      MihomoBridge.delayActive = 0;
    }
    const next = MihomoBridge.delayWaiting.shift();
    if (next !== undefined) {
      next();
    }
  }

  /**
   * 内核 `/version` 返回的是 `constant.Version`，**默认值就是 "1.10.0"**
   * （上游靠 `go build -ldflags "-X .../constant.Version=v1.19.34"` 注入真版本）。
   * 我们的 c-archive 构建早期没加这条 ldflags，于是内核自报 1.10.0，
   * 设置页/首页就显示成 1.10.0。这里用 App 侧声明的 MIHOMO_VERSION 兜底，
   * 同时 build-core.sh 已补上 ldflags（下次重编内核就直接是对的）。
   */
  private static normalizeCoreVersion(parsed: Object | null): Object | null {
    if (parsed === null || typeof parsed !== 'object') {
      return parsed;
    }
    const data = parsed as Record<string, Object | null>;
    const raw = data['version'];
    const text = typeof raw === 'string' ? raw as string : '';
    if (text.length === 0 || text === '1.10.0' || text === 'v1.10.0') {
      data['version'] = MIHOMO_VERSION;
      Log.i('Mihomo', `core reports placeholder version "${text}", show ${MIHOMO_VERSION}`);
    }
    return data;
  }

  private static parse(result: HttpResult): Object | null {
    if (result.error.length > 0 || result.code === 0) {
      return null;
    }
    const text = result.body.trim();
    if (text.length === 0) {
      return null;
    }
    try {
      return JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
  }

  private static emptyObject(): Record<string, Object | null> {
    return {};
  }

  static install(bridge: JsBridge, secret: string): void {
    MihomoBridge.secret = secret;

    bridge.register('plugin:mihomo|update_controller', async (args: Record<string, Object>): Promise<Object | null> => {
      const host = args['host'];
      const port = args['port'];
      MihomoBridge.setController(typeof host === 'string' ? host as string : '',
        typeof port === 'number' ? port as number : 0);
      return null;
    });

    bridge.register('plugin:mihomo|update_secret', async (args: Record<string, Object>): Promise<Object | null> => {
      const secretArg = args['secret'];
      MihomoBridge.setSecret(typeof secretArg === 'string' ? secretArg as string : '');
      return null;
    });

    bridge.register('plugin:mihomo|get_version', async (): Promise<Object | null> => {
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET, '/version', ''));
      if (parsed !== null) {
        return MihomoBridge.normalizeCoreVersion(parsed);
      }
      const fallback: Record<string, Object | null> = {};
      fallback['version'] = '';
      fallback['meta'] = true;
      return fallback;
    });

    bridge.register('plugin:mihomo|get_proxies', async (): Promise<Object | null> => {
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET, '/proxies', ''));
      if (parsed !== null) {
        return parsed;
      }
      const empty: Record<string, Object | null> = {};
      empty['proxies'] = MihomoBridge.emptyObject();
      return empty;
    });

    bridge.register('plugin:mihomo|get_groups', async (): Promise<Object | null> => {
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET, '/proxies', ''));
      const groups: Record<string, Object | null>[] = [];
      if (parsed !== null) {
        const data = parsed as Record<string, Object | null>;
        const proxies = data['proxies'];
        if (proxies !== undefined && proxies !== null) {
          const map = proxies as Record<string, Object | null>;
          const names = Object.keys(map);
          for (let i = 0; i < names.length; i++) {
            const item = map[names[i]];
            if (item === undefined || item === null) {
              continue;
            }
            const node = item as Record<string, Object | null>;
            const type = node['type'];
            if (typeof type !== 'string') {
              continue;
            }
            const t = type as string;
            if (t === 'Selector' || t === 'URLTest' || t === 'Fallback' || t === 'LoadBalance' || t === 'Relay') {
              groups.push(node);
            }
          }
        }
      }
      return groups;
    });

    bridge.register('plugin:mihomo|get_group_by_name', async (args: Record<string, Object>): Promise<Object | null> => {
      // 前端（vendor/tauri-plugin-mihomo-api）传的是 groupName
      const raw = args['groupName'] ?? args['name'];
      if (typeof raw !== 'string') {
        return null;
      }
      const name = raw as string;
      const parsed = MihomoBridge.parse(
        await MihomoBridge.call(http.RequestMethod.GET, `/proxies/${encodeURIComponent(name as string)}`, ''));
      return parsed;
    });

    bridge.register('plugin:mihomo|get_proxy_by_name', async (args: Record<string, Object>): Promise<Object | null> => {
      // 前端传的是 proxiesName（历史拼写，不能改契约）
      const raw = args['proxiesName'] ?? args['name'];
      if (typeof raw !== 'string') {
        return null;
      }
      const name = raw as string;
      return MihomoBridge.parse(
        await MihomoBridge.call(http.RequestMethod.GET, `/proxies/${encodeURIComponent(name as string)}`, ''));
    });

    bridge.register('plugin:mihomo|get_connections', async (): Promise<Object | null> => {
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET, '/connections', ''));
      if (parsed !== null) {
        return parsed;
      }
      const empty: Record<string, Object | null> = {};
      empty['downloadTotal'] = 0;
      empty['uploadTotal'] = 0;
      empty['memory'] = 0;
      empty['connections'] = [];
      return empty;
    });

    bridge.register('plugin:mihomo|get_rules', async (): Promise<Object | null> => {
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET, '/rules', ''));
      if (parsed !== null) {
        return parsed;
      }
      const empty: Record<string, Object | null> = {};
      empty['rules'] = [];
      return empty;
    });

    bridge.register('plugin:mihomo|get_proxy_providers', async (): Promise<Object | null> => {
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET, '/providers/proxies', ''));
      if (parsed !== null) {
        return parsed;
      }
      const empty: Record<string, Object | null> = {};
      empty['providers'] = MihomoBridge.emptyObject();
      return empty;
    });

    bridge.register('plugin:mihomo|get_proxy_provider_by_name',
      async (args: Record<string, Object>): Promise<Object | null> => {
        const raw = args['providerName'] ?? args['name'];
        if (typeof raw !== 'string') {
          return null;
        }
        return MihomoBridge.parse(
          await MihomoBridge.call(http.RequestMethod.GET, `/providers/proxies/${encodeURIComponent(raw as string)}`, ''));
      });

    bridge.register('plugin:mihomo|get_rule_providers', async (): Promise<Object | null> => {
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET, '/providers/rules', ''));
      if (parsed !== null) {
        return parsed;
      }
      const empty: Record<string, Object | null> = {};
      empty['providers'] = MihomoBridge.emptyObject();
      return empty;
    });

    bridge.register('plugin:mihomo|get_base_config', async (): Promise<Object | null> => {
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET, '/configs', ''));
      if (parsed !== null) {
        return parsed;
      }
      const fallback: Record<string, Object | null> = {};
      fallback['port'] = 0;
      fallback['socks-port'] = 0;
      fallback['mixed-port'] = 7890;
      fallback['mode'] = 'rule';
      fallback['log-level'] = 'info';
      return fallback;
    });

    bridge.register('plugin:mihomo|patch_base_config', async (args: Record<string, Object>): Promise<Object | null> => {
      const payload = args['payload'];
      const body = payload === undefined || payload === null ? '{}' : JSON.stringify(payload);
      await MihomoBridge.call(http.RequestMethod.PATCH, '/configs', body);
      return null;
    });

    bridge.register('plugin:mihomo|select_node_for_group', async (args: Record<string, Object>): Promise<Object | null> => {
      // 前端传 { groupName, node }
      const rawGroup = args['groupName'] ?? args['group'];
      const rawNode = args['node'] ?? args['name'];
      if (typeof rawGroup !== 'string' || typeof rawNode !== 'string') {
        return null;
      }
      const body = JSON.stringify({ name: rawNode as string });
      await MihomoBridge.call(http.RequestMethod.PUT, `/proxies/${encodeURIComponent(rawGroup as string)}`, body);
      return null;
    });

    bridge.register('plugin:mihomo|delay_proxy_by_name', async (args: Record<string, Object>): Promise<Object | null> => {
      // 前端传 { proxyName, testUrl, timeout }；之前读 name/url 导致每次都返回 null，
      // 前端 measureDelay 取 result.delay 时崩（真机 22:39 的延迟测试 TypeError）。
      const rawName = args['proxyName'] ?? args['name'];
      const rawUrl = args['testUrl'] ?? args['url'];
      const timeout = args['timeout'];
      if (typeof rawName !== 'string') {
        return null;
      }
      const target = typeof rawUrl === 'string' ? rawUrl as string : 'https://www.gstatic.com/generate_204';
      const ms = typeof timeout === 'number' ? timeout as number : 5000;
      await MihomoBridge.enterDelayGate();
      let parsed: Object | null = null;
      try {
        // 客户端超时必须比节点 timeout 大一档：原来固定 5000，节点却按 10000 在测，
        // 结果慢节点还没测完我们就先 timeout 了（日志里的 code=2300028）。
        parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET,
          `/proxies/${encodeURIComponent(rawName as string)}/delay?timeout=${ms}&url=${encodeURIComponent(target)}`,
          '', ms + 1000));
      } finally {
        MihomoBridge.leaveDelayGate();
      }
      if (parsed !== null) {
        return parsed;
      }
      const failed: Record<string, Object | null> = {};
      failed['delay'] = 0;
      return failed;
    });

    bridge.register('plugin:mihomo|delay_group', async (args: Record<string, Object>): Promise<Object | null> => {
      // 前端传 { groupName, testUrl, timeout, keepFixed }
      const rawGroup = args['groupName'] ?? args['group'];
      if (typeof rawGroup !== 'string') {
        return null;
      }
      const rawUrl = args['testUrl'] ?? args['url'];
      const target = typeof rawUrl === 'string' ? rawUrl as string : 'https://www.gstatic.com/generate_204';
      const timeout = args['timeout'];
      const ms = typeof timeout === 'number' ? timeout as number : 5000;
      const parsed = MihomoBridge.parse(
        await MihomoBridge.call(http.RequestMethod.GET,
          `/group/${encodeURIComponent(rawGroup as string)}/delay?url=${encodeURIComponent(target)}&timeout=${ms}`, ''));
      return parsed !== null ? parsed : MihomoBridge.emptyObject();
    });

    bridge.register('plugin:mihomo|close_connection', async (args: Record<string, Object>): Promise<Object | null> => {
      // 前端传 { connectionId }
      const raw = args['connectionId'] ?? args['id'];
      if (typeof raw !== 'string') {
        return null;
      }
      await MihomoBridge.call(http.RequestMethod.DELETE, `/connections/${encodeURIComponent(raw as string)}`, '');
      return null;
    });

    bridge.register('plugin:mihomo|close_all_connections', async (): Promise<Object | null> => {
      await MihomoBridge.call(http.RequestMethod.DELETE, '/connections', '');
      return null;
    });

    bridge.register('plugin:mihomo|flush_fakeip', async (): Promise<Object | null> => {
      await MihomoBridge.call(http.RequestMethod.POST, '/cache/fakeip/flush', '');
      return null;
    });

    bridge.register('plugin:mihomo|flush_dns', async (): Promise<Object | null> => {
      await MihomoBridge.call(http.RequestMethod.POST, '/cache/dns/flush', '');
      return null;
    });

    bridge.register('plugin:mihomo|reload_config', async (): Promise<Object | null> => {
      await MihomoBridge.call(http.RequestMethod.PUT, '/configs?force=true', '{"path":""}');
      return null;
    });

    // WebSocket 组（ws_traffic / ws_memory / ws_connections* / ws_logs / ws_disconnect）
    MihomoWsHost.setController(MihomoBridge.host, MihomoBridge.port);
    MihomoWsHost.setSecret(MihomoBridge.secret);
    MihomoWsHost.install(bridge);

    // 代理提供者 / 取消固定节点：mihomo REST 都有对应端点，不能当 noop
    bridge.register('plugin:mihomo|unfixed_proxy', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['groupName'] ?? args['group'];
      if (typeof raw === 'string') {
        await MihomoBridge.call(http.RequestMethod.DELETE, `/proxies/${encodeURIComponent(raw as string)}`, '');
      }
      return null;
    });

    bridge.register('plugin:mihomo|update_proxy_provider', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['providerName'] ?? args['name'];
      if (typeof raw === 'string') {
        await MihomoBridge.call(http.RequestMethod.PUT, `/providers/proxies/${encodeURIComponent(raw as string)}`, '');
      }
      return null;
    });

    bridge.register('plugin:mihomo|update_rule_provider', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['providerName'] ?? args['name'];
      if (typeof raw === 'string') {
        await MihomoBridge.call(http.RequestMethod.PUT, `/providers/rules/${encodeURIComponent(raw as string)}`, '');
      }
      return null;
    });

    bridge.register('plugin:mihomo|healthcheck_proxy_provider', async (args: Record<string, Object>): Promise<Object | null> => {
      const raw = args['providerName'] ?? args['name'];
      if (typeof raw === 'string') {
        await MihomoBridge.call(http.RequestMethod.GET, `/providers/proxies/${encodeURIComponent(raw as string)}/healthcheck`, '');
      }
      return null;
    });

    bridge.register('plugin:mihomo|healthcheck_node_in_provider', async (args: Record<string, Object>): Promise<Object | null> => {
      const rawProvider = args['providerName'];
      const rawProxy = args['proxyName'];
      if (typeof rawProvider !== 'string' || typeof rawProxy !== 'string') {
        return null;
      }
      const rawUrl = args['testUrl'] ?? args['url'];
      const target = typeof rawUrl === 'string' ? rawUrl as string : 'https://www.gstatic.com/generate_204';
      const timeout = args['timeout'];
      const ms = typeof timeout === 'number' ? timeout as number : 5000;
      const parsed = MihomoBridge.parse(await MihomoBridge.call(http.RequestMethod.GET,
        `/providers/proxies/${encodeURIComponent(rawProvider as string)}/${encodeURIComponent(rawProxy as string)}/healthcheck?url=${encodeURIComponent(target)}&timeout=${ms}`, ''));
      if (parsed !== null) {
        return parsed;
      }
      const failed: Record<string, Object | null> = {};
      failed['delay'] = 0;
      return failed;
    });

    // 以下命令在鸿蒙侧没有等价物：明确返回 null，UI 侧无需处理
    const noops: string[] = [
      'plugin:mihomo|update_geo',
      'plugin:mihomo|upgrade_core',
      'plugin:mihomo|upgrade_geo',
      'plugin:mihomo|upgrade_ui',
      'plugin:mihomo|restart',
    ];
    for (let i = 0; i < noops.length; i++) {
      bridge.register(noops[i], async (): Promise<Object | null> => null);
    }
    Log.i('Mihomo', 'plugin:mihomo|* handlers installed');
  }
}
