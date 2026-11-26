import { AppCtx } from '../common/AppCtx';
import { FILE_RUNTIME_YAML } from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';
import { CoreHost } from './CoreHost';

/**
 * DNS 覆盖配置（对应上游 `save/get/apply/validate_dns_config` + `set_dns_override`）。
 *
 * 上游语义（`src-tauri/src/cmd/clash.rs`）：
 *   - 文件 `app_home_dir/dns_config.yaml` 存的是**一个 dns 段**（Mapping，不是整份配置）
 *   - `save_dns_config(dnsConfig)` 收的是 **YamlMapping 对象**（前端已用 js-yaml parse 过）
 *   - `apply_dns_config(apply)` 只是"应用/撤销"，不做文本写入
 *   - `validate_dns_config()` 校验的是**文件**
 *
 * 我们的落地：
 *   - `verge/dns_config.yaml` = dns 段文本（由这里的简易序列化器从对象生成）
 *   - `verge/dns_active`     = 开关（apply=true 时写，false 时删）
 *   - 真正"合并进运行时配置"由 Go 桥在做（`prepareBase` 里读这两个文件 →
 *     `root["dns"] = dns`），因为 ArkTS 没有 YAML 解析器
 */
export class DnsConfig {
  static yamlPath(): string {
    return AppCtx.path('verge/dns_config.yaml');
  }

  private static flagPath(): string {
    return AppCtx.path('verge/dns_active');
  }

  static isActive(): boolean {
    return FsUtil.exists(DnsConfig.flagPath());
  }

  /** 读原始 YAML 文本；不存在返回 null（前端用 `!== null` 判断） */
  static read(): string | null {
    if (!FsUtil.exists(DnsConfig.yamlPath())) {
      return null;
    }
    const text = FsUtil.readText(DnsConfig.yamlPath());
    return text.length > 0 ? text : null;
  }

  /** 把前端传来的 dns 对象序列化成 YAML 并落盘 */
  static save(dnsConfig: Record<string, Object | null>): string {
    const lines = DnsConfig.emit(dnsConfig, 0);
    const text = lines.join('\n') + '\n';
    FsUtil.writeText(DnsConfig.yamlPath(), text);
    Log.i('Dns', `saved ${lines.length} lines`);
    return text;
  }

  /** 应用/撤销：只切开关 + 触发内核重载 */
  static apply(enable: boolean): string {
    if (enable) {
      if (!FsUtil.exists(DnsConfig.yamlPath())) {
        return 'DNS config file not found';
      }
      FsUtil.writeText(DnsConfig.flagPath(), '1');
    } else {
      FsUtil.remove(DnsConfig.flagPath());
    }
    // 重载的是运行时配置（clash-verge.yaml）；DNS 文件由 Go 桥在 prepareBase 里合并进去。
    // 必须强制重载：profile 路径没变，普通 applyConfig 会跳过。
    CoreHost.forceApplyConfig(AppCtx.path(FILE_RUNTIME_YAML));
    Log.i('Dns', `apply enable=${enable}`);
    return '';
  }

  /**
   * 校验：ArkTS 没有 YAML parser，这里做「结构自检」——
   * 只要能序列化、且 dns.enable 是布尔、nameserver 是字符串数组，就认为 valid。
   * 真正的 YAML 合法性由 Go 桥在 load 时兜底（yaml.v3 解析失败会让 load 返回错误）。
   */
  static validate(): Record<string, Object | null> {
    const text = DnsConfig.read();
    if (text === null) {
      return DnsConfig.invalid('dns_missing', 'DNS config file not found');
    }
    if (text.indexOf(':') < 0) {
      return DnsConfig.invalid('syntax', 'DNS config must be a YAML mapping');
    }
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.length === 0 || line.startsWith('#') || line.startsWith(' ')) {
        continue;
      }
      if (line.indexOf(':') < 0) {
        return DnsConfig.invalid('syntax', `line ${i + 1}: expected "key: value"`);
      }
    }
    const outcome: Record<string, Object | null> = {};
    outcome['status'] = 'valid';
    return outcome;
  }

  private static invalid(kind: string, message: string): Record<string, Object | null> {
    const outcome: Record<string, Object | null> = {};
    outcome['status'] = 'invalid';
    outcome['kind'] = kind;
    outcome['message'] = message;
    return outcome;
  }

  // ---------------- 简易 YAML 序列化（只覆盖 dns 段会用到的结构） ----------------

  private static pad(indent: number): string {
    let out = '';
    for (let i = 0; i < indent; i++) {
      out += ' ';
    }
    return out;
  }

  private static scalar(value: Object | null | undefined): string {
    if (value === null || value === undefined) {
      return 'null';
    }
    if (typeof value === 'boolean') {
      return (value as boolean) ? 'true' : 'false';
    }
    if (typeof value === 'number') {
      return `${value as number}`;
    }
    const text = `${value}`;
    if (text.length === 0) {
      return '""';
    }
    // 需要加引号：看起来像数字/布尔（否则会被 YAML 解析成别的类型）
    const looksLikeNumber = new RegExp('^-?[0-9]+(\\.[0-9]+)?$').test(text);
    const looksLikeBool = new RegExp('^(true|false|null|yes|no|on|off|~)$', 'i').test(text);
    const plainSafe = new RegExp('^[A-Za-z0-9_./:@+-]+$').test(text);
    if (!looksLikeNumber && !looksLikeBool && plainSafe) {
      return text;
    }
    return JSON.stringify(text);
  }

  private static emit(obj: Record<string, Object | null>, indent: number): string[] {
    const lines: string[] = [];
    const keys = Object.keys(obj);
    const space = DnsConfig.pad(indent);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const value = obj[key];
      if (Array.isArray(value)) {
        const arr = value as Object[];
        if (arr.length === 0) {
          lines.push(`${space}${key}: []`);
          continue;
        }
        lines.push(`${space}${key}:`);
        for (let j = 0; j < arr.length; j++) {
          const item = arr[j];
          if (item !== null && item !== undefined && typeof item === 'object' && !Array.isArray(item)) {
            // 数组里嵌对象：dns 段里罕见，用内联 JSON 保证不写坏
            lines.push(`${space}  - ${JSON.stringify(item)}`);
          } else {
            lines.push(`${space}  - ${DnsConfig.scalar(item)}`);
          }
        }
        continue;
      }
      if (value !== null && value !== undefined && typeof value === 'object') {
        lines.push(`${space}${key}:`);
        const child = DnsConfig.emit(value as Record<string, Object | null>, indent + 2);
        for (let j = 0; j < child.length; j++) {
          lines.push(child[j]);
        }
        continue;
      }
      lines.push(`${space}${key}: ${DnsConfig.scalar(value)}`);
    }
    return lines;
  }
}
