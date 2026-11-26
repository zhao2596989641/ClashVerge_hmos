import { http } from '@kit.NetworkKit';

import { Log } from '../common/Logger';

export class HttpResult {
  code: number = 0;
  body: string = '';
  error: string = '';
  /** 响应头（小写 key）；Netflix 的区域要从 location 头里取 */
  headers: Record<string, string> = {};
}

export class BinaryResult {
  code: number = 0;
  body: ArrayBuffer = new ArrayBuffer(0);
  error: string = '';
}

/** 极简 HTTP 客户端（mihomo 控制面 + WebDAV） */
export class HttpClient {
  /**
   * 允许任意 HTTP 方法名（WebDAV 的 PROPFIND 不在 `http.RequestMethod` 枚举里）。
   *
   * `RequestMethod` 底层就是字符串 enum，运行时 ArkTS 只把它当字符串传给底层 netstack，
   * 所以这里用显式断言绕过编译期枚举限制。**已在本地编译验证通过。**
   * 若某天编译不过，退路是改用 `socket.constructTLSSocketInstance` 手写请求。
   */
  static async requestRaw(method: string, url: string, body: string,
    headers: Record<string, string>, timeoutMs: number): Promise<HttpResult> {
    return HttpClient.request(url, method as http.RequestMethod, body, headers, timeoutMs);
  }

  static async requestBinaryRaw(method: string, url: string, body: ArrayBuffer | null,
    headers: Record<string, string>, timeoutMs: number): Promise<BinaryResult> {
    const result = new BinaryResult();
    let client: http.HttpRequest | null = null;
    try {
      client = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: method as http.RequestMethod,
        header: headers,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      };
      if (body !== null && body.byteLength > 0) {
        options.extraData = body;
      }
      const response = await client.request(url, options);
      result.code = response.responseCode;
      const payload = response.result;
      if (payload instanceof ArrayBuffer) {
        result.body = payload;
      }
    } catch (e) {
      result.error = Log.err(e as Object);
      Log.w('Http', `${method} ${url} failed: ${result.error}`);
    } finally {
      if (client !== null) {
        try {
          client.destroy();
        } catch (e) {
          // ignore
        }
      }
    }
    return result;
  }

  /** 走本地 mixed-port 代理取文本（流媒体解锁检测必须经代理，才能反映节点地区） */
  static async requestViaProxy(url: string, proxyPort: number, timeoutMs: number): Promise<HttpResult> {
    const result = new HttpResult();
    let client: http.HttpRequest | null = null;
    try {
      client = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING,
        header: {
          'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
            '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        },
      };
      if (proxyPort > 0) {
        const proxy: http.HttpProxy = { host: '127.0.0.1', port: proxyPort, exclusionList: [] };
        options.usingProxy = proxy;
      }
      const response = await client.request(url, options);
      result.code = response.responseCode;
      HttpClient.collectHeaders(response, result);
      const payload = response.result;
      if (typeof payload === 'string') {
        result.body = payload as string;
      }
    } catch (e) {
      result.error = Log.err(e as Object);
    } finally {
      if (client !== null) {
        try {
          client.destroy();
        } catch (e) {
          // ignore
        }
      }
    }
    return result;
  }

  private static collectHeaders(response: http.HttpResponse, result: HttpResult): void {
    try {
      const raw = response.header as Record<string, Object>;
      if (raw === undefined || raw === null) {
        return;
      }
      const keys = Object.keys(raw);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i].toLowerCase();
        const value = raw[keys[i]];
        if (typeof value === 'string') {
          result.headers[key] = value as string;
        } else if (Array.isArray(value)) {
          const arr = value as string[];
          if (arr.length > 0) {
            result.headers[key] = arr[0];
          }
        }
      }
    } catch (e) {
      // 头信息拿不到不影响主流程
    }
  }

  /** 走本地代理发 POST（Disney 的 token/graphql 需要） */
  static async requestViaProxyPost(url: string, body: string, headers: Record<string, string>,
    proxyPort: number, timeoutMs: number): Promise<HttpResult> {
    const result = new HttpResult();
    let client: http.HttpRequest | null = null;
    try {
      client = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING,
        extraData: body,
      };
      if (proxyPort > 0) {
        const proxy: http.HttpProxy = { host: '127.0.0.1', port: proxyPort, exclusionList: [] };
        options.usingProxy = proxy;
      }
      const response = await client.request(url, options);
      result.code = response.responseCode;
      HttpClient.collectHeaders(response, result);
      const payload = response.result;
      if (typeof payload === 'string') {
        result.body = payload as string;
      }
    } catch (e) {
      result.error = Log.err(e as Object);
    } finally {
      if (client !== null) {
        try {
          client.destroy();
        } catch (e) {
          // ignore
        }
      }
    }
    return result;
  }

  static async request(url: string, method: http.RequestMethod, body: string,
    headers: Record<string, string>, timeoutMs: number): Promise<HttpResult> {
    const result = new HttpResult();
    let client: http.HttpRequest | null = null;
    try {
      client = http.createHttp();
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        expectDataType: http.HttpDataType.STRING,
      };
      if (body.length > 0) {
        options.extraData = body;
      }
      const response = await client.request(url, options);
      result.code = response.responseCode;
      HttpClient.collectHeaders(response, result);
      const payload = response.result;
      if (typeof payload === 'string') {
        result.body = payload as string;
      } else {
        result.body = JSON.stringify(payload);
      }
    } catch (e) {
      result.error = Log.err(e as Object);
      Log.w('Http', `${method} ${url} failed: ${result.error}`);
    } finally {
      if (client !== null) {
        try {
          client.destroy();
        } catch (e) {
          // ignore
        }
      }
    }
    return result;
  }
}
