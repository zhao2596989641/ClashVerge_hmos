import { util } from '@kit.ArkTS';

import { AppCtx } from '../common/AppCtx';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';
import { VergeConfig } from '../config/VergeConfig';
import { BackupService } from './BackupService';
import { BinaryResult, HttpClient } from './HttpClient';

/**
 * WebDAV 备份（对应上游 feat/backup.rs 的 WebDavClient）。
 *
 * 四个动作：
 *   create → PROPPATCH 不需要，直接 PUT
 *   list   → PROPFIND + Depth: 1，解析 multistatus
 *   delete → DELETE
 *   restore→ GET 二进制 → 落盘 → 解压
 *
 * ⚠️ `http.RequestMethod` 枚举里没有 PROPFIND，`HttpClient.requestRaw` 用字符串断言绕过；
 * 上传/下载必须走 `requestBinaryRaw`（ARRAY_BUFFER），用 STRING 会把 zip 字节解坏。
 */
export class WebDavService {
  private static readonly PROPFIND_BODY: string =
    '<?xml version="1.0" encoding="utf-8"?>' +
    '<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:getlastmodified/><d:resourcetype/></d:prop></d:propfind>';

  private static baseUrl(verge: VergeConfig): string {
    let url = verge.getString('webdav_url', '').trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  static configured(verge: VergeConfig): boolean {
    return WebDavService.baseUrl(verge).length > 0;
  }

  private static headers(verge: VergeConfig): Record<string, string> {
    const headers: Record<string, string> = {};
    const user = verge.getString('webdav_username', '');
    const password = verge.getString('webdav_password', '');
    if (user.length > 0) {
      const raw = `${user}:${password}`;
      const encoder = new util.TextEncoder();
      const bytes = encoder.encodeInto(raw);
      const base64 = new util.Base64Helper().encodeToStringSync(bytes);
      headers['Authorization'] = `Basic ${base64}`;
    }
    return headers;
  }

  /** url 可能收到文件名或完整 href，两种都要兼容 */
  private static resolveUrl(verge: VergeConfig, nameOrHref: string): string {
    if (nameOrHref.startsWith('http://') || nameOrHref.startsWith('https://')) {
      return nameOrHref;
    }
    const base = WebDavService.baseUrl(verge);
    const name = nameOrHref.startsWith('/') ? nameOrHref.substring(1) : nameOrHref;
    return `${base}/${name}`;
  }

  /** 上传当前配置；返回空串=成功 */
  static async create(verge: VergeConfig): Promise<string> {
    if (!WebDavService.configured(verge)) {
      return 'webdav url not configured';
    }
    let tempPath = '';
    try {
      tempPath = await BackupService.createTemp();
      const bytes = FsUtil.readBytes(tempPath);
      if (bytes === null) {
        return 'read temp zip failed';
      }
      const now = new Date();
      const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
      const stamp = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}` +
        `_${pad(now.getHours())}-${pad(now.getMinutes())}-${pad(now.getSeconds())}`;
      const filename = `harmonyos-backup-${stamp}.zip`;
      const headers = WebDavService.headers(verge);
      headers['Content-Type'] = 'application/zip';
      const result = await HttpClient.requestBinaryRaw('PUT',
        `${WebDavService.baseUrl(verge)}/${filename}`, bytes, headers, 30000);
      if (result.error.length > 0) {
        return result.error;
      }
      if (result.code < 200 || result.code >= 300) {
        return `PUT failed: ${result.code}`;
      }
      Log.i('WebDav', `uploaded ${filename}`);
      return '';
    } catch (e) {
      const message = Log.err(e as Object);
      Log.e('WebDav', `create failed: ${message}`);
      return message;
    } finally {
      if (tempPath.length > 0) {
        BackupService.removeTemp(tempPath);
      }
    }
  }

  static async list(verge: VergeConfig): Promise<Record<string, Object | null>[]> {
    const items: Record<string, Object | null>[] = [];
    if (!WebDavService.configured(verge)) {
      return items;
    }
    const headers = WebDavService.headers(verge);
    headers['Depth'] = '1';
    headers['Content-Type'] = 'application/xml; charset=utf-8';
    const result = await HttpClient.requestRaw('PROPFIND', WebDavService.baseUrl(verge),
      WebDavService.PROPFIND_BODY, headers, 15000);
    if (result.error.length > 0 || result.code < 200 || result.code >= 300) {
      Log.w('WebDav', `PROPFIND failed code=${result.code} err=${result.error}`);
      return items;
    }
    return WebDavService.parseMultiStatus(result.body);
  }

  /** 解析 multistatus：按 href 出现顺序，向后找最近的 getlastmodified */
  private static parseMultiStatus(xml: string): Record<string, Object | null>[] {
    const items: Record<string, Object | null>[] = [];
    const hrefRe = /<[a-zA-Z0-9]*:?href>([^<]*)<\/[a-zA-Z0-9]*:?href>/g;
    let match: RegExpExecArray | null = hrefRe.exec(xml);
    while (match !== null) {
      const href = match[1];
      const cursor = match.index + match[0].length;
      let lastModified = '';
      const tail = xml.substring(cursor);
      const lmRe = /<[a-zA-Z0-9]*:?getlastmodified>([^<]*)<\/[a-zA-Z0-9]*:?getlastmodified>/;
      let lmMatch: RegExpMatchArray | null = tail.match(lmRe);
      if (lmMatch !== null) {
        lastModified = lmMatch[1];
      }
      const isCollection = href.endsWith('/');
      const isZip = href.toLowerCase().endsWith('.zip');
      if (!isCollection && isZip) {
        const item: Record<string, Object | null> = {};
        item['href'] = href;
        item['last_modified'] = WebDavService.toIso(lastModified);
        items.push(item);
      }
      match = hrefRe.exec(xml);
    }
    return items;
  }

  private static toIso(raw: string): string {
    const text = raw.trim();
    if (text.length === 0) {
      return '';
    }
    const parsed = new Date(text);
    if (isNaN(parsed.getTime())) {
      return text;
    }
    return parsed.toISOString();
  }

  static async remove(verge: VergeConfig, nameOrHref: string): Promise<string> {
    if (!WebDavService.configured(verge) || nameOrHref.length === 0) {
      return 'not configured';
    }
    const result = await HttpClient.requestRaw('DELETE',
      WebDavService.resolveUrl(verge, nameOrHref), '', WebDavService.headers(verge), 15000);
    if (result.error.length > 0) {
      return result.error;
    }
    if (result.code < 200 || result.code >= 300) {
      return `DELETE failed: ${result.code}`;
    }
    return '';
  }

  /** 下载 + 覆盖恢复；返回空串=成功 */
  static async restore(verge: VergeConfig, nameOrHref: string): Promise<string> {
    if (!WebDavService.configured(verge) || nameOrHref.length === 0) {
      return 'not configured';
    }
    const result: BinaryResult = await HttpClient.requestBinaryRaw('GET',
      WebDavService.resolveUrl(verge, nameOrHref), null, WebDavService.headers(verge), 60000);
    if (result.error.length > 0) {
      return result.error;
    }
    if (result.code < 200 || result.code >= 300) {
      return `GET failed: ${result.code}`;
    }
    if (result.body.byteLength === 0) {
      return 'empty response';
    }
    const filename = BackupService.saveBytes(result.body, 'webdav');
    if (filename.length === 0) {
      return 'save downloaded zip failed';
    }
    Log.i('WebDav', `downloaded ${filename} (${result.body.byteLength} bytes)`);
    return await BackupService.restore(filename);
  }

  /** 保存 WebDAV 账号配置（写进 verge 配置，与上游一致） */
  static saveConfig(verge: VergeConfig, url: string, username: string, password: string): void {
    const patch: Record<string, Object | null> = {};
    patch['webdav_url'] = url;
    patch['webdav_username'] = username;
    patch['webdav_password'] = password;
    verge.patch(patch);
    Log.i('WebDav', `config saved url=${url}`);
  }

  /** 供排障：当前是否会写进备份目录 */
  static backupDir(): string {
    return AppCtx.path('backups');
  }
}
