import { CONTROLLER_PORT } from '../common/Constants';
import { Log } from '../common/Logger';
import { VergeConfig } from '../config/VergeConfig';
import { HttpResult, HttpClient } from './HttpClient';

class UnlockResult {
  name: string = '';
  status: string = 'Pending';
  region: string | null = null;
  checkTime: string | null = null;
}

const DISNEY_AUTH: string =
  'Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84';
const BAHAMUT_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

/**
 * 流媒体解锁检测：13 项全部移植自上游 crates/clash-verge-media-unlock。
 *
 * 判定逻辑逐条对齐 Rust 实现（状态字符串、地区标签、check_time 格式都保持一致），
 * 唯一无法完全对齐的是两处依赖「最终 URL」的判断（reqwest 的 response.url()）：
 *   - Muse 的 `landed_on_aymh`（改判 body 里的 Meta 错误页标记）
 *   - Disney 的 `is_unavailable`（改判 body 里是否出现 unavailable）
 * 两处都在注释里标了。
 */
export class MediaUnlockService {
  // ---------------- 公共入口 ----------------

  static names(): string[] {
    const names: string[] = [
      'Bahamut Anime', '哔哩哔哩大陆', '哔哩哔哩港澳台', 'ChatGPT Web', 'Claude',
      'Disney+', 'Gemini', 'Muse AI', 'Netflix', 'Prime Video', 'Spotify', 'TikTok',
      'YouTube Premium',
    ];
    return names;
  }

  static initialItems(): Record<string, Object | null>[] {
    const names = MediaUnlockService.names();
    const items: Record<string, Object | null>[] = [];
    for (let i = 0; i < names.length; i++) {
      items.push(MediaUnlockService.toRecord(MediaUnlockService.pending(names[i])));
    }
    return items;
  }

  static async checkOne(name: string, verge: VergeConfig): Promise<Record<string, Object | null>> {
    const port = MediaUnlockService.proxyPort(verge);
    let item: UnlockResult;
    try {
      if (name === 'Bahamut Anime') {
        item = await MediaUnlockService.checkBahamut(port);
      } else if (name === '哔哩哔哩大陆') {
        item = await MediaUnlockService.checkBilibili(name,
          'https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json' +
          '&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi', port);
      } else if (name === '哔哩哔哩港澳台') {
        item = await MediaUnlockService.checkBilibili(name,
          'https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json' +
          '&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi', port);
      } else if (name === 'ChatGPT Web') {
        item = await MediaUnlockService.checkChatGpt(port);
      } else if (name === 'Claude') {
        item = await MediaUnlockService.checkClaude(port);
      } else if (name === 'Disney+') {
        item = await MediaUnlockService.checkDisney(port);
      } else if (name === 'Gemini') {
        item = await MediaUnlockService.checkGemini(port);
      } else if (name === 'Muse AI') {
        item = await MediaUnlockService.checkMuse(port);
      } else if (name === 'Netflix') {
        item = await MediaUnlockService.checkNetflix(port);
      } else if (name === 'Prime Video') {
        item = await MediaUnlockService.checkPrime(port);
      } else if (name === 'Spotify') {
        item = await MediaUnlockService.checkSpotify(port);
      } else if (name === 'TikTok') {
        item = await MediaUnlockService.checkTiktok(port);
      } else if (name === 'YouTube Premium') {
        item = await MediaUnlockService.checkYoutube(port);
      } else {
        item = MediaUnlockService.pending(name);
      }
    } catch (e) {
      Log.w('Unlock', `${name} failed: ${Log.err(e as Object)}`);
      item = MediaUnlockService.checked(name, 'Failed', null);
    }
    return MediaUnlockService.toRecord(item);
  }

  static toRecord(item: UnlockResult): Record<string, Object | null> {
    const rec: Record<string, Object | null> = {};
    rec['name'] = item.name;
    rec['status'] = item.status;
    rec['region'] = item.region;
    rec['check_time'] = item.checkTime;
    return rec;
  }

  // ---------------- 基建 ----------------

  private static proxyPort(verge: VergeConfig): number {
    const port = verge.getNumber('verge_mixed_port', 7890);
    return port > 0 ? port : CONTROLLER_PORT;
  }

  private static async get(url: string, port: number): Promise<HttpResult> {
    return HttpClient.requestViaProxy(url, port, 8000);
  }

  private static async post(url: string, body: string, contentType: string,
    extraHeaders: Record<string, string>, port: number): Promise<HttpResult> {
    const headers: Record<string, string> = {};
    headers['Content-Type'] = contentType;
    headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
    const keys = Object.keys(extraHeaders);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = extraHeaders[keys[i]];
    }
    return HttpClient.requestViaProxyPost(url, body, headers, port, 15000);
  }

  private static checked(name: string, status: string, region: string | null): UnlockResult {
    const item = new UnlockResult();
    item.name = name;
    item.status = status;
    item.region = region;
    item.checkTime = MediaUnlockService.timestamp();
    return item;
  }

  private static pending(name: string): UnlockResult {
    const item = new UnlockResult();
    item.name = name;
    item.status = 'Pending';
    return item;
  }

  /** 本地时间 `YYYY-MM-DD HH:mm:ss`，与上游 chrono 的格式一致 */
  private static timestamp(): string {
    const now = new Date();
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ` +
      `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  }

  /** 2 位国家码 → 国旗 emoji；3 位先折成 2 位 */
  private static emoji(code: string): string {
    let alpha2 = code.trim().toUpperCase();
    if (alpha2.length === 3) {
      alpha2 = MediaUnlockService.alpha3To2(alpha2);
    }
    if (alpha2.length !== 2) {
      return '';
    }
    const first = alpha2.charCodeAt(0);
    const second = alpha2.charCodeAt(1);
    if (first < 65 || first > 90 || second < 65 || second > 90) {
      return '';
    }
    try {
      return String.fromCodePoint(0x1F1E6 + first - 65) + String.fromCodePoint(0x1F1E6 + second - 65);
    } catch (e) {
      return '';
    }
  }

  private static alpha3To2(code3: string): string {
    const table: Record<string, string> = {
      'CHN': 'CN', 'RUS': 'RU', 'BLR': 'BY', 'CUB': 'CU', 'IRN': 'IR', 'PRK': 'KP',
      'SYR': 'SY', 'HKG': 'HK', 'MAC': 'MO', 'TWN': 'TW', 'USA': 'US', 'JPN': 'JP',
      'KOR': 'KR', 'SGP': 'SG', 'GBR': 'GB', 'DEU': 'DE', 'FRA': 'FR', 'CAN': 'CA',
      'AUS': 'AU', 'IND': 'IN', 'BRA': 'BR', 'NLD': 'NL', 'TUR': 'TR', 'UKR': 'UA',
    };
    const mapped = table[code3];
    return mapped === undefined ? code3 : mapped;
  }

  private static regionLabel(code: string): string {
    const trimmed = code.trim().toUpperCase();
    return `${MediaUnlockService.emoji(trimmed)}${trimmed}`;
  }

  private static quoteField(body: string, key: string): string | null {
    const marker = `"${key}":"`;
    const idx = body.indexOf(marker);
    if (idx < 0) {
      return null;
    }
    const rest = body.substring(idx + marker.length);
    const end = rest.indexOf('"');
    if (end <= 0) {
      return null;
    }
    return rest.substring(0, end);
  }

  private static traceLoc(body: string): string | null {
    const lines = body.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.startsWith('loc=')) {
        return line.substring(4).trim().toUpperCase();
      }
    }
    return null;
  }

  /** 403 / 451 → No，其它非 2xx → Failed，2xx → null（交给调用方继续判定） */
  private static classify(status: number): string | null {
    if (status === 403 || status === 451) {
      return 'No';
    }
    if (status < 200 || status >= 300) {
      return 'Failed';
    }
    return null;
  }

  // ---------------- 各项检测 ----------------

  private static async checkBilibili(name: string, url: string, port: number): Promise<UnlockResult> {
    const result = await MediaUnlockService.get(url, port);
    if (result.error.length > 0 || result.code === 0) {
      return MediaUnlockService.checked(name, 'Failed', null);
    }
    const idx = result.body.indexOf('"code":');
    if (idx < 0) {
      return MediaUnlockService.checked(name, 'Failed', null);
    }
    const rest = result.body.substring(idx + 7).trim();
    let end = 0;
    while (end < rest.length &&
      (rest.charAt(end) === '-' || (rest.charAt(end) >= '0' && rest.charAt(end) <= '9'))) {
      end++;
    }
    const code = rest.substring(0, end);
    if (code === '0') {
      return MediaUnlockService.checked(name, 'Yes', null);
    }
    if (code === '-10403') {
      return MediaUnlockService.checked(name, 'No', null);
    }
    return MediaUnlockService.checked(name, 'Failed', null);
  }

  private static async checkBahamut(port: number): Promise<UnlockResult> {
    const device = await MediaUnlockService.get('https://ani.gamer.com.tw/ajax/getdeviceid.php', port);
    if (device.code !== 200 || device.body.length === 0) {
      return MediaUnlockService.checked('Bahamut Anime', 'Failed', null);
    }
    const deviceId = MediaUnlockService.quoteField(device.body, 'deviceid');
    if (deviceId === null) {
      return MediaUnlockService.checked('Bahamut Anime', 'Failed', null);
    }
    const tokenUrl = `https://ani.gamer.com.tw/ajax/token.php?adID=89422&sn=37783&device=${deviceId}`;
    const token = await MediaUnlockService.get(tokenUrl, port);
    const unlocked = token.code === 200 && token.body.includes('animeSn');
    if (!unlocked) {
      return MediaUnlockService.checked('Bahamut Anime', 'No', null);
    }
    const home = await MediaUnlockService.get('https://ani.gamer.com.tw/', port);
    let region: string | null = null;
    const idx = home.body.indexOf('data-geo="');
    if (idx >= 0) {
      const rest = home.body.substring(idx + 10);
      const end = rest.indexOf('"');
      if (end > 0) {
        region = MediaUnlockService.regionLabel(rest.substring(0, end));
      }
    }
    return MediaUnlockService.checked('Bahamut Anime', 'Yes', region);
  }

  private static async checkChatGpt(port: number): Promise<UnlockResult> {
    let region: string | null = null;
    const trace = await MediaUnlockService.get('https://chat.openai.com/cdn-cgi/trace', port);
    if (trace.code === 200 && trace.body.length > 0) {
      const code = MediaUnlockService.traceLoc(trace.body);
      if (code !== null) {
        region = MediaUnlockService.regionLabel(code);
      }
    }
    const probe = await MediaUnlockService.get('https://api.openai.com/compliance/cookie_requirements', port);
    let status = 'Failed';
    if (probe.error.length === 0 && probe.code > 0) {
      status = probe.body.includes('unsupported_country') ? 'Unsupported Country/Region' : 'Yes';
    }
    return MediaUnlockService.checked('ChatGPT Web', status, region);
  }

  private static async checkClaude(port: number): Promise<UnlockResult> {
    const trace = await MediaUnlockService.get('https://claude.ai/cdn-cgi/trace', port);
    if (trace.code !== 200 || trace.body.length === 0) {
      return MediaUnlockService.checked('Claude', 'Failed', null);
    }
    const code = MediaUnlockService.traceLoc(trace.body);
    if (code === null) {
      return MediaUnlockService.checked('Claude', 'Failed', null);
    }
    const blocked: string[] = ['AF', 'BY', 'CN', 'CU', 'HK', 'IR', 'KP', 'MO', 'RU', 'SY'];
    const status = blocked.includes(code) ? 'No' : 'Yes';
    return MediaUnlockService.checked('Claude', status, MediaUnlockService.regionLabel(code));
  }

  private static async checkDisney(port: number): Promise<UnlockResult> {
    const name = 'Disney+';
    const jsonHeaders: Record<string, string> = {};
    jsonHeaders['Authorization'] = DISNEY_AUTH;

    // 1) device → assertion
    const deviceBody = '{"deviceFamily":"browser","applicationRuntime":"chrome",' +
      '"deviceProfile":"windows","attributes":{}}';
    const device = await MediaUnlockService.post('https://disney.api.edge.bamgrid.com/devices',
      deviceBody, 'application/json', jsonHeaders, port);
    if (device.code === 403) {
      return MediaUnlockService.checked(name, 'No (IP Banned By Disney+)', null);
    }
    const assertion = MediaUnlockService.quoteField(device.body, 'assertion');
    if (assertion === null) {
      return MediaUnlockService.checked(name, 'Failed (Cannot extract assertion)', null);
    }

    // 2) token 交换
    const form = 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange' +
      '&latitude=0&longitude=0&platform=browser' +
      `&subject_token=${encodeURIComponent(assertion)}` +
      '&subject_token_type=urn%3Abamtech%3Aparams%3Aoauth%3Atoken-type%3Adevice';
    const token = await MediaUnlockService.post('https://disney.api.edge.bamgrid.com/token',
      form, 'application/x-www-form-urlencoded', jsonHeaders, port);
    if (token.code === 403 || token.body.includes('forbidden-location') || token.body.includes('403 ERROR')) {
      return MediaUnlockService.checked(name, 'No (IP Banned By Disney+)', null);
    }
    const refreshToken = MediaUnlockService.quoteField(token.body, 'refresh_token');
    if (refreshToken === null) {
      return MediaUnlockService.checked(name, `Failed (Cannot extract refresh token: ${token.code})`, null);
    }

    // 3) 主站可用性（无最终 URL 可读，退化为 body 判定）
    const home = await MediaUnlockService.get('https://disneyplus.com', port);
    const unavailable = home.body.includes('unavailable') || home.body.includes('preview');

    // 4) graphql 刷新会话
    const gql = '{"query":"mutation refreshToken($input: RefreshTokenInput!) ' +
      '{ refreshToken(refreshToken: $input) { activeSession { sessionId } } }",' +
      `"variables":{"input":{"refreshToken":"${refreshToken}"}}}`;
    const graph = await MediaUnlockService.post('https://disney.api.edge.bamgrid.com/graph/v1/device/graphql',
      gql, 'application/json', jsonHeaders, port);

    if (graph.code < 200 || graph.code >= 300 || graph.body.length === 0) {
      return MediaUnlockService.checked(name, `Failed (GraphQL: ${graph.code})`, null);
    }
    const region = MediaUnlockService.quoteField(graph.body, 'countryCode');
    if (region === null) {
      return MediaUnlockService.checked(name, 'No', null);
    }
    if (region === 'JP') {
      return MediaUnlockService.checked(name, 'Yes', MediaUnlockService.regionLabel(region));
    }
    if (unavailable) {
      return MediaUnlockService.checked(name, 'No', null);
    }
    const supportedIdx = graph.body.indexOf('"inSupportedLocation":');
    if (supportedIdx < 0) {
      return MediaUnlockService.checked(name, `Failed (Unknown region status for ${region})`, null);
    }
    const after = graph.body.substring(supportedIdx + 22).trim();
    if (after.startsWith('true')) {
      return MediaUnlockService.checked(name, 'Yes', MediaUnlockService.regionLabel(region));
    }
    if (after.startsWith('false')) {
      return MediaUnlockService.checked(name, 'Soon',
        `${MediaUnlockService.regionLabel(region)}（即将上线）`);
    }
    return MediaUnlockService.checked(name, `Failed (Unknown region status for ${region})`, null);
  }

  private static async checkGemini(port: number): Promise<UnlockResult> {
    const response = await MediaUnlockService.get('https://gemini.google.com', port);
    if (response.code !== 200 || response.body.length === 0) {
      return MediaUnlockService.checked('Gemini', 'Failed', null);
    }
    const marker = ',2,1,200,"';
    const idx = response.body.indexOf(marker);
    if (idx < 0) {
      return MediaUnlockService.checked('Gemini', 'Failed', null);
    }
    const rest = response.body.substring(idx + marker.length);
    if (rest.length < 3) {
      return MediaUnlockService.checked('Gemini', 'Failed', null);
    }
    const code = rest.substring(0, 3);
    const blocked: string[] = ['CHN', 'RUS', 'BLR', 'CUB', 'IRN', 'PRK', 'SYR', 'HKG', 'MAC'];
    const status = blocked.includes(code) ? 'No' : 'Yes';
    return MediaUnlockService.checked('Gemini', status, MediaUnlockService.regionLabel(code));
  }

  private static async checkMuse(port: number): Promise<UnlockResult> {
    const name = 'Muse AI';
    let region: string | null = null;
    const trace = await MediaUnlockService.get('https://www.cloudflare.com/cdn-cgi/trace', port);
    if (trace.code === 200) {
      const code = MediaUnlockService.traceLoc(trace.body);
      if (code !== null) {
        region = MediaUnlockService.regionLabel(code);
      }
    }
    const response = await MediaUnlockService.get('https://muse.ai', port);
    if (response.code === 0) {
      return MediaUnlockService.checked(name, 'Failed (Network Connection)', region);
    }
    // 拿不到最终 URL，只能靠反机器人网关的错误页标记判断
    const behindAntiBot = response.body.includes('Sorry, something went wrong') ||
      response.body.includes('static.facebook.com/images/logos');
    if (behindAntiBot) {
      return MediaUnlockService.checked(name, 'Risky', region);
    }
    if (response.code >= 200 && response.code < 300) {
      return MediaUnlockService.checked(name, 'Yes', region);
    }
    const restricted = MediaUnlockService.classify(response.code);
    return MediaUnlockService.checked(name, restricted === null ? 'Failed' : restricted, region);
  }

  private static async checkNetflix(port: number): Promise<UnlockResult> {
    const name = 'Netflix';
    // 1) fast.com CDN 探测
    const cdn = await MediaUnlockService.get(
      'https://api.fast.com/netflix/speedtest/v2?https=true' +
      '&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=5', port);
    if (cdn.error.length > 0) {
      return MediaUnlockService.checked(name, 'Failed (CDN API)', null);
    }
    if (cdn.code === 403) {
      return MediaUnlockService.checked(name, 'No (IP Banned By Netflix)', null);
    }
    if (cdn.code >= 200 && cdn.code < 300) {
      const country = MediaUnlockService.quoteField(cdn.body, 'country');
      if (country === null) {
        return MediaUnlockService.checked(name, 'Failed (解析错误)', null);
      }
      return MediaUnlockService.checked(name, 'Yes', MediaUnlockService.regionLabel(country));
    }

    // 2) 两个 title 的状态码
    const title1 = await MediaUnlockService.get('https://www.netflix.com/title/81280792', port);
    const title2 = await MediaUnlockService.get('https://www.netflix.com/title/70143836', port);
    if (title1.code === 0 || title2.code === 0) {
      return MediaUnlockService.checked(name, 'Failed', null);
    }
    if (title1.code === 404 && title2.code === 404) {
      return MediaUnlockService.checked(name, 'Originals Only', null);
    }
    if (title1.code === 403 || title2.code === 403) {
      return MediaUnlockService.checked(name, 'No', null);
    }
    const ok = (code: number): boolean => code === 200 || code === 301 || code === 302;
    if (!ok(title1.code) && !ok(title2.code)) {
      return MediaUnlockService.checked(name, `Failed (状态码: ${title1.code}_${title2.code})`, null);
    }

    // 3) 从 location 头取区域
    const regionResp = await MediaUnlockService.get('https://www.netflix.com/title/80018499', port);
    const location = regionResp.headers['location'];
    let region = 'us';
    if (location !== undefined && location.length > 0) {
      const segments = location.split('/');
      if (segments.length > 3) {
        const first = segments[3].split('-')[0];
        if (first.length > 0) {
          region = first;
        }
      }
    }
    return MediaUnlockService.checked(name, 'Yes', MediaUnlockService.regionLabel(region));
  }

  private static async checkPrime(port: number): Promise<UnlockResult> {
    const response = await MediaUnlockService.get('https://www.primevideo.com', port);
    if (response.code === 0) {
      return MediaUnlockService.checked('Prime Video', 'Failed (Network Connection)', null);
    }
    if (response.body.length === 0) {
      return MediaUnlockService.checked('Prime Video', 'Failed (Cannot Read Response)', null);
    }
    if (response.body.includes('isServiceRestricted')) {
      return MediaUnlockService.checked('Prime Video', 'No (Service Not Available)', null);
    }
    const region = MediaUnlockService.quoteField(response.body, 'currentTerritory');
    if (region === null) {
      return MediaUnlockService.checked('Prime Video', 'Failed (PAGE ERROR)', null);
    }
    return MediaUnlockService.checked('Prime Video', 'Yes', MediaUnlockService.regionLabel(region));
  }

  private static async checkSpotify(port: number): Promise<UnlockResult> {
    const url = 'https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json';
    const response = await MediaUnlockService.get(url, port);
    if (response.code === 0) {
      return MediaUnlockService.checked('Spotify', 'Failed', null);
    }
    let status = 'Yes';
    const restricted = MediaUnlockService.classify(response.code);
    if (restricted !== null) {
      status = restricted;
    } else if (response.body.toLowerCase().includes('not available in your country')) {
      status = 'No';
    }
    // 最终 URL 拿不到，只能从 body 的 countryCode 取地区
    let region: string | null = null;
    const code = MediaUnlockService.quoteField(response.body, 'countryCode');
    if (code !== null && code.length > 0) {
      region = MediaUnlockService.regionLabel(code);
    }
    return MediaUnlockService.checked('Spotify', status, region);
  }

  private static async checkTiktok(port: number): Promise<UnlockResult> {
    const name = 'TikTok';
    const first = await MediaUnlockService.tiktokProbe('https://www.tiktok.com/cdn-cgi/trace', port);
    let status = first[0];
    let region = first[1];
    if (region === null || status === 'Failed') {
      const second = await MediaUnlockService.tiktokProbe('https://www.tiktok.com/', port);
      if (status !== 'No') {
        status = second[0];
      }
      if (region === null) {
        region = second[1];
      }
    }
    return MediaUnlockService.checked(name, status, region);
  }

  /** [status, region] */
  private static async tiktokProbe(url: string, port: number): Promise<[string, string | null]> {
    const response = await MediaUnlockService.get(url, port);
    if (response.code === 0) {
      return ['Failed', null];
    }
    let status = 'Yes';
    const restricted = MediaUnlockService.classify(response.code);
    if (restricted !== null) {
      status = restricted;
    } else {
      const body = response.body.toLowerCase();
      if (body.includes('access denied') || body.includes('not available in your region') ||
        body.includes('tiktok is not available')) {
        status = 'No';
      }
    }
    let region: string | null = null;
    const raw = MediaUnlockService.quoteField(response.body, 'region');
    if (raw !== null) {
      const first = raw.split('-')[0].toUpperCase();
      if (first.length > 0) {
        region = MediaUnlockService.regionLabel(first);
      }
    }
    return [status, region];
  }

  private static async checkYoutube(port: number): Promise<UnlockResult> {
    const response = await MediaUnlockService.get('https://www.youtube.com/premium?hl=en', port);
    if (response.code === 0 || response.body.length === 0) {
      return MediaUnlockService.checked('YouTube Premium', 'Failed', null);
    }
    const body = response.body.toLowerCase();
    const rawRegion = MediaUnlockService.quoteField(response.body, 'GL') ??
      MediaUnlockService.quoteField(response.body, 'countryCode') ??
      MediaUnlockService.quoteField(response.body, 'country_code');
    const region = rawRegion === null ? null : MediaUnlockService.regionLabel(rawRegion);
    const notAvailable = body.includes('youtube premium is not available in your country') ||
      body.includes('premium is not available in your country') ||
      body.includes('premium is not available in your region');
    if (notAvailable) {
      return MediaUnlockService.checked('YouTube Premium', 'No', region);
    }
    const ok = response.code === 200 && (body.includes('youtube premium') || body.includes('ad-free') ||
      body.includes('"browseid":"spunlimited"'));
    return MediaUnlockService.checked('YouTube Premium', ok ? 'Yes' : 'Failed', region);
  }
}
