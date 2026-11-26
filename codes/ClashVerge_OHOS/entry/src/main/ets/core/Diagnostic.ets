import { deviceInfo } from '@kit.BasicServicesKit';
import { pasteboard } from '@kit.BasicServicesKit';

import { AppCtx } from '../common/AppCtx';
import { APP_VERSION_NAME, MIHOMO_VERSION } from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';
import { RuntimeStatusStore } from './RuntimeStatus';

/**
 * 诊断信息导出（对应上游 `export_diagnostic_info`）。
 *
 * 上游实现（`crates/tauri-plugin-clash-verge-sysinfo/src/commands.rs`）：
 * ```rust
 * let info = state.inner().read().to_string();   // SystemInfo 的 Display
 * clipboard.write_text(info)                      // 就只是写入剪贴板
 * ```
 * 也就是说这条命令**不生成文件**，只是把诊断文本塞进剪贴板，让用户自己粘出来。
 * 这里照做：拼一段可读文本 → 写系统剪贴板 → 返回 null。
 */
export class Diagnostic {
  static buildText(): string {
    const lines: string[] = [];
    lines.push('=== Clash Verge for HarmonyOS · 诊断信息 ===');
    lines.push(`generated_at: ${new Date().toISOString()}`);
    lines.push('');

    lines.push('[App]');
    lines.push(`version: ${APP_VERSION_NAME}`);
    lines.push(`uptime_ms: ${AppCtx.uptimeMs}`);
    lines.push(`filesDir: ${AppCtx.filesDir}`);
    lines.push(`cacheDir: ${AppCtx.cacheDir}`);
    lines.push('');

    lines.push('[Device]');
    lines.push(`brand: ${deviceInfo.brand}`);
    lines.push(`marketName: ${deviceInfo.marketName}`);
    lines.push(`productModel: ${deviceInfo.productModel}`);
    lines.push(`osFullName: ${deviceInfo.osFullName}`);
    lines.push(`sdkApiVersion: ${deviceInfo.sdkApiVersion}`);
    // 这三项能直接告诉运维「设备到底是什么系统版本」，比猜 compatibleSdkVersion 靠谱
    lines.push(`distributionOSName: ${safe(() => deviceInfo.distributionOSName)}`);
    lines.push(`distributionOSVersion: ${safe(() => deviceInfo.distributionOSVersion)}`);
    lines.push(`distributionOSApiVersion: ${deviceInfo.distributionOSApiVersion}`);
    lines.push(`deviceType: ${deviceInfo.deviceType}`);
    lines.push(`abi: ${deviceInfo.abiList}`);
    lines.push('');

    lines.push('[Core]');
    lines.push(`mihomo: ${MIHOMO_VERSION}`);
    const status = RuntimeStatusStore.read();
    lines.push(`connected: ${status.connected}`);
    lines.push(`tunFd: ${status.tunFd}`);
    lines.push(`stack: ${status.stack}`);
    lines.push(`controller: ${status.controller}`);
    lines.push(`coreVersion: ${status.coreVersion}`);
    lines.push(`lastError: ${status.lastError}`);
    lines.push(`statusUpdatedAt: ${status.updatedAt}`);
    lines.push('');

    lines.push('[Files]');
    const probes: string[] = [
      'verge/verge.json',
      'verge/profiles.json',
      'verge/clash-verge.yaml',
      'verge/runtime-overrides.json',
      'verge/runtime/status.json',
      'verge/runtime/vpn-status.json',
      'verge/dns_config.yaml',
      'verge/logs/app.log',
    ];
    for (let i = 0; i < probes.length; i++) {
      const path = AppCtx.path(probes[i]);
      const exists = FsUtil.exists(path);
      const size = exists ? FsUtil.size(path) : 0;
      lines.push(`${probes[i]}: ${exists ? `${size} bytes` : 'missing'}`);
    }
    lines.push('');

    lines.push('[RecentLogs]');
    const logs = Log.snapshot();
    const start = logs.length > 80 ? logs.length - 80 : 0;
    for (let i = start; i < logs.length; i++) {
      lines.push(logs[i]);
    }
    return lines.join('\n');
  }

  /** 写系统剪贴板；失败抛错让前端弹提示 */
  static async exportToClipboard(): Promise<void> {
    const text = Diagnostic.buildText();
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    const board = pasteboard.getSystemPasteboard();
    await board.setData(data);
    Log.i('Diagnostic', `copied ${text.length} chars to clipboard`);
  }
}

function safe(read: () => string): string {
  try {
    return read();
  } catch (e) {
    return 'n/a';
  }
}
