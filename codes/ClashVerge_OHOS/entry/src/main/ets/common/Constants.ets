/**
 * 全局常量：日志、版本、路径、TUN 与控制器参数。
 * 与 webapp（上游前端）共享的数值必须保持字符串一致，避免前端断言失败。
 */

export const LOG_DOMAIN: number = 0x0C00;
export const LOG_TAG: string = 'ClashVerge';

/** 与 AppScope/app.json5 保持一致 */
export const APP_VERSION_NAME: string = '2.6.0';
export const APP_VERSION_CODE: number = 2600000;
export const BUNDLE_NAME: string = 'com.lyldeer.clashverge';

/** 内置 mihomo 内核版本（与 core/mihomo-1.19.34 源码树一致，改版本时两边同步） */
export const MIHOMO_VERSION: string = 'v1.19.34';

/** VPN 扩展 Ability 名（module.json5 中必须存在同名 extensionAbility） */
export const VPN_ABILITY_NAME: string = 'ClashVpnExtensionAbility';

/** 主进程内静态资源服务端口（前端 origin） */
export const LOCAL_SERVER_PORT: number = 45123;

/** mihomo external-controller（仅本机回环） */
export const CONTROLLER_HOST: string = '127.0.0.1';
export const CONTROLLER_PORT: number = 9090;

/** TUN 网段参数（与 ClashOhos 实机验证值一致） */
export const TUN_ADDRESS: string = '172.19.0.1';
export const TUN_PREFIX: number = 30;
export const TUN_PORTAL: string = '172.19.0.2';
export const TUN_DNS: string = '172.19.0.2';
export const TUN_MTU: number = 1400;
export const TUN_IPV6: string = 'fdfe:dcba:9876::1';
export const TUN_IPV6_PREFIX: number = 126;

/** 扩展 → UI 的 tunfd 传递 socket（相对 filesDir） */
export const TUN_RELAY_SOCKET: string = 'verge/runtime/tun.sock';

/** 运行时目录（相对 filesDir） */
export const DIR_VERGE: string = 'verge';
export const DIR_PROFILES: string = 'verge/profiles';
export const DIR_LOGS: string = 'verge/logs';
export const DIR_RUNTIME: string = 'verge/runtime';
export const DIR_WEB: string = 'web';

/** rawfile 内前端产物目录 */
export const RAWFILE_WEB: string = 'web';

export const FILE_PROFILES: string = 'verge/profiles.yaml';
export const FILE_VERGE: string = 'verge/verge.yaml';
/** 鸿蒙侧后端以 JSON 落盘 Verge 配置（字段名与上游一致） */
export const FILE_VERGE_JSON: string = 'verge/verge.json';
export const FILE_RUNTIME_YAML: string = 'verge/clash-verge.yaml';
