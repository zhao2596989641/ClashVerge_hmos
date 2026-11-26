import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { LOG_DOMAIN, LOG_TAG } from './Constants';

/**
 * 统一日志出口。
 *
 * 三层同时输出：
 *   1. hilog  —— `hdc shell hilog | grep ClashVerge`（开发者用）
 *   2. 内存环形缓冲 —— 应用内「日志」页通过 `get_clash_logs` 读取（**主人实机验证时唯一能自救的信息源**）
 *   3. 文件 `verge/logs/app.log` —— 崩溃/被杀后还能捞回来
 *
 * 行格式刻意对齐 mihomo 的 logrus 文本格式，因为前端
 * `services/cmds.ts:getClashLogs` 用 `/time="(.+?)"\s+level=(.+?)\s+msg="(.+?)"/` 解析，
 * 格式不对日志页就是空白（看起来像功能坏了）。
 */
export class Log {
  private static buffer: string[] = [];
  private static pending: string[] = [];
  private static filePath: string = '';
  private static flushTimer: number = -1;
  private static readonly MAX_LINES: number = 600;
  private static readonly MAX_PENDING: number = 40;
  private static readonly MAX_FILE_BYTES: number = 512 * 1024;

  /**
   * 设置日志文件路径（由 AppCtx 在拿到 filesDir 后调用）。
   * 文件过大时先清空，避免无限增长。
   */
  static init(filePath: string): void {
    if (Log.filePath === filePath) {
      return;
    }
    Log.filePath = filePath;
    try {
      const dir = filePath.substring(0, filePath.lastIndexOf('/'));
      if (dir.length > 0 && !fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      if (fs.accessSync(filePath)) {
        const stat = fs.statSync(filePath);
        if (stat.size > Log.MAX_FILE_BYTES) {
          fs.truncateSync(filePath, 0);
        }
      }
    } catch (e) {
      // 打不开就只走 hilog + 内存，不影响主流程
      Log.filePath = '';
    }
  }

  static i(tag: string, message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '[%{public}s] %{public}s', tag, message);
    Log.record('info', tag, message);
  }

  static w(tag: string, message: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '[%{public}s] %{public}s', tag, message);
    Log.record('warning', tag, message);
  }

  static e(tag: string, message: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, '[%{public}s] %{public}s', tag, message);
    Log.record('error', tag, message);
  }

  static d(tag: string, message: string): void {
    hilog.debug(LOG_DOMAIN, LOG_TAG, '[%{public}s] %{public}s', tag, message);
    Log.record('debug', tag, message);
  }

  /** 供 `get_clash_logs` 取快照（返回副本，调用方随便改） */
  static snapshot(): string[] {
    Log.flush();
    return Log.buffer.slice();
  }

  static clear(): void {
    Log.buffer = [];
    Log.pending = [];
    if (Log.filePath.length > 0) {
      try {
        if (fs.accessSync(Log.filePath)) {
          fs.truncateSync(Log.filePath, 0);
        }
      } catch (e) {
        // ignore
      }
    }
  }

  /** 把任意异常转成可读字符串（ArkTS 的 BusinessError 不继承 Error 的 message 展示习惯） */
  static err(e: Object): string {
    try {
      const rec = e as Record<string, Object>;
      const code = rec['code'];
      const msg = rec['message'];
      // ⚠️ 只判断 message 是否存在：普通 `new Error('x')` 没有 code，
      // 之前要求两者都有才走这条分支，结果 Error 落到 JSON.stringify → "{}"，
      // 日志里就只剩 `failed: {}`（本次实机日志里 set_dns_override 就是这样丢的信息）。
      if (typeof msg === 'string' && (msg as string).length > 0) {
        return (code !== undefined && code !== null) ? `code=${code} message=${msg}` : (msg as string);
      }
    } catch (_ignored) {
      // fallthrough
    }
    try {
      const text = JSON.stringify(e);
      if (text !== undefined && text !== null && text.length > 0 && text !== '{}') {
        return text;
      }
    } catch (_ignored) {
      // fallthrough
    }
    try {
      return `${e}`;
    } catch (_ignored) {
      return 'unknown error';
    }
  }

  // ---------------- 内部 ----------------

  private static record(level: string, tag: string, message: string): void {
    const line = `time="${new Date().toISOString()}" level=${level} msg="[${tag}] ${Log.escape(message)}"`;
    Log.buffer.push(line);
    if (Log.buffer.length > Log.MAX_LINES) {
      Log.buffer.splice(0, Log.buffer.length - Log.MAX_LINES);
    }
    Log.pending.push(line);
    if (Log.pending.length >= Log.MAX_PENDING) {
      Log.flush();
      return;
    }
    if (Log.flushTimer < 0) {
      Log.flushTimer = setTimeout(() => {
        Log.flushTimer = -1;
        Log.flush();
      }, 3000);
    }
  }

  /** 换行与引号会破坏「一行一条」和前端正则，统一转义 */
  private static escape(message: string): string {
    let out = message;
    out = out.replace(new RegExp('\\n', 'g'), ' ⏎ ');
    out = out.replace(new RegExp('"', 'g'), `'`);
    out = out.replace(new RegExp('\\\\', 'g'), '/');
    return out;
  }

  private static flush(): void {
    if (Log.pending.length === 0 || Log.filePath.length === 0) {
      Log.pending = [];
      return;
    }
    const chunk = Log.pending.join('\n') + '\n';
    Log.pending = [];
    try {
      const file = fs.openSync(Log.filePath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try {
        fs.writeSync(file.fd, chunk);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      // 写文件失败不影响 hilog 与内存缓冲
    }
  }
}
