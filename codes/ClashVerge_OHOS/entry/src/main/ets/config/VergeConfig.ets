import { FILE_VERGE_JSON } from '../common/Constants';
import { FsUtil } from '../common/FsUtil';
import { Log } from '../common/Logger';

/**
 * Verge 应用配置（对应上游 src-tauri/src/config/verge.rs 的 IVerge）。
 *
 * 上游把配置存成 verge.yaml；鸿蒙侧后端没有 YAML 解析器，且配置只在本进程内
 * 读写，因此落盘用 JSON（字段名与上游完全一致，导出/导入时再转 YAML）。
 */
export class VergeConfig {
  private path: string = '';
  private data: Record<string, Object | null> = {};

  constructor(filesDir: string) {
    this.path = `${filesDir}/${FILE_VERGE_JSON}`;
    this.data = VergeConfig.defaults();
    this.load();
  }

  /** 前端环境变量类型下拉框的合法值 */
  private static readonly ENV_TYPES: string[] = ['sh', 'bash', 'zsh', 'fish', 'nushell'];

  /** 与上游一致：未显式设置过的字段为 null，由前端兜底 */
  static defaults(): Record<string, Object | null> {
    const cfg: Record<string, Object | null> = {};
    cfg['app_log_level'] = 'info';
    cfg['app_log_max_size'] = 128;
    cfg['app_log_max_count'] = 8;
    cfg['language'] = '';
    cfg['theme_mode'] = 'system';
    cfg['tray_event'] = 'main_window';
    // 鸿蒙终端默认是 POSIX shell；上游 Windows 的 powershell/cmd 不适用。
    cfg['env_type'] = 'sh';
    cfg['start_page'] = '/';
    cfg['startup_script'] = '';
    cfg['traffic_graph'] = true;
    cfg['enable_memory_usage'] = true;
    cfg['enable_group_icon'] = true;
    cfg['pause_render_traffic_stats_on_blur'] = false;
    cfg['common_tray_icon'] = false;
    cfg['menu_icon'] = 'monochrome';
    cfg['menu_order'] = [];
    cfg['proxy_group_tools_position'] = 'right';
    cfg['notice_position'] = 'bottom-left';
    cfg['collapse_navbar'] = false;
    cfg['sysproxy_tray_icon'] = false;
    cfg['tun_tray_icon'] = false;
    cfg['enable_tun_mode'] = false;
    cfg['enable_auto_launch'] = false;
    cfg['enable_silent_start'] = false;
    cfg['enable_system_proxy'] = false;
    cfg['enable_proxy_guard'] = false;
    cfg['enable_bypass_check'] = true;
    cfg['enable_dns_settings'] = false;
    cfg['use_default_bypass'] = true;
    cfg['system_proxy_bypass'] = '';
    cfg['proxy_guard_duration'] = 30;
    cfg['proxy_auto_config'] = false;
    cfg['pac_file_content'] = '';
    cfg['proxy_host'] = '127.0.0.1';
    cfg['theme_setting'] = null;
    cfg['web_ui_list'] = [];
    cfg['clash_core'] = 'mihomo';
    cfg['hotkeys'] = [];
    cfg['enable_global_hotkey'] = false;
    cfg['home_cards'] = null;
    cfg['auto_close_connection'] = false;
    cfg['auto_check_update'] = false;
    cfg['default_latency_test'] = 'https://www.gstatic.com/generate_204';
    cfg['default_latency_timeout'] = 10000;
    cfg['enable_auto_delay_detection'] = false;
    cfg['auto_delay_detection_interval_minutes'] = 5;
    cfg['enable_builtin_enhanced'] = true;
    cfg['proxy_layout_column'] = 2;
    // ⚠️ 必须是 null 而不是 []：前端用 `verge.test_list ?? DEFAULT_TEST_LIST` 取默认值，
    // 空数组是 truthy，会把内置的 Apple/GitHub/Google/YouTube 四项挡掉（真机踩过）。
    cfg['test_list'] = null;
    cfg['auto_log_clean'] = 1;
    cfg['enable_auto_backup_schedule'] = false;
    cfg['auto_backup_interval_hours'] = 24;
    cfg['auto_backup_on_change'] = true;
    cfg['verge_mixed_port'] = 7890;
    cfg['verge_socks_port'] = 7891;
    cfg['verge_socks_enabled'] = false;
    cfg['verge_port'] = 7897;
    cfg['verge_http_enabled'] = false;
    cfg['webdav_url'] = '';
    cfg['webdav_username'] = '';
    cfg['webdav_password'] = '';
    cfg['tray_proxy_groups_display_mode'] = 'default';
    cfg['tray_inline_outbound_modes'] = false;
    cfg['enable_auto_light_weight_mode'] = false;
    cfg['auto_light_weight_minutes'] = 30;
    cfg['enable_hover_jump_navigator'] = false;
    cfg['hover_jump_navigator_delay'] = 300;
    cfg['enable_external_controller'] = true;
    cfg['tray_icon'] = '';
    cfg['verge_redir_port'] = 7895;
    cfg['verge_redir_enabled'] = false;
    cfg['verge_tproxy_port'] = 7896;
    cfg['verge_tproxy_enabled'] = false;
    cfg['enable_tray_speed'] = false;
    return cfg;
  }

  private load(): void {
    const raw = FsUtil.readText(this.path);
    if (raw.length === 0) {
      return;
    }
    try {
      const stored = JSON.parse(raw) as Record<string, Object | null>;
      const keys = Object.keys(stored);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        this.data[key] = stored[key];
      }
      // 旧版本默认值误写成 "stable"（不是任何 shell），空串同样会让前端下拉框显示空白。
      // 合法集合之外的一律回落到 POSIX sh。
      const envType = this.data['env_type'];
      if (typeof envType !== 'string' || VergeConfig.ENV_TYPES.indexOf(envType as string) < 0) {
        this.data['env_type'] = 'sh';
        this.save();
      }
      // 旧版本把 test_list 默认成 []，前端当成"用户已清空" → 首页网站测试是空的。
      // 只迁移一次：迁移后打上标记，用户以后真清空了也不会被重新塞回来。
      if (this.data['test_list_seeded'] !== true) {
        const list = this.data['test_list'];
        if (Array.isArray(list) && (list as Object[]).length === 0) {
          this.data['test_list'] = null;
          Log.i('VergeConfig', 'migrate empty test_list -> null (use built-in four sites)');
        }
        this.data['test_list_seeded'] = true;
        this.save();
      }
    } catch (e) {
      Log.w('VergeConfig', `parse failed: ${Log.err(e as Object)}`);
    }
  }

  /** 备份恢复后重新读盘（清掉内存里的旧配置） */
  reload(): void {
    this.data = VergeConfig.defaults();
    this.load();
  }

  get(): Record<string, Object | null> {
    return this.data;
  }

  /** 局部合并（对应上游 patch_verge_config 的语义） */
  patch(partial: Record<string, Object | null>): Record<string, Object | null> {
    const keys = Object.keys(partial);
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      this.data[key] = partial[key];
    }
    this.save();
    return this.data;
  }

  save(): void {
    try {
      FsUtil.writeText(this.path, JSON.stringify(this.data));
    } catch (e) {
      Log.e('VergeConfig', `save failed: ${Log.err(e as Object)}`);
    }
  }

  getString(key: string, fallback: string): string {
    const value = this.data[key];
    if (typeof value === 'string') {
      return value as string;
    }
    return fallback;
  }

  getNumber(key: string, fallback: number): number {
    const value = this.data[key];
    if (typeof value === 'number') {
      return value as number;
    }
    return fallback;
  }

  getBool(key: string, fallback: boolean): boolean {
    const value = this.data[key];
    if (typeof value === 'boolean') {
      return value as boolean;
    }
    return fallback;
  }
}
