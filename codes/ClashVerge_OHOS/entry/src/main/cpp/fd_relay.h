#ifndef CLASH_VERGE_OHOS_FD_RELAY_H
#define CLASH_VERGE_OHOS_FD_RELAY_H

#include <string>

/**
 * 跨进程文件描述符转发（Unix domain socket + SCM_RIGHTS）。
 *
 * 为什么需要：鸿蒙的 VpnConnection 只能在 VpnExtensionAbility 进程里创建，拿到的 tunfd 属于该进程；
 * 而按上游（Windows/mac 的 sidecar/service）语义，内核应当常驻在 UI 进程。两者之间只能靠
 * `sendmsg` 的 `SCM_RIGHTS` 把 fd 递过去（ArkTS 的 `@ohos.net.socket` 没有这个能力）。
 *
 * 用法（同一套 socket 路径，先 serve 后 connect）：
 *   extension: RelayPublish(path, tunfd, timeoutMs)   立即返回，后台线程等一次连接并把 fd 发出去
 *   UI:        RelayReceive(path, timeoutMs)          连接并取回 fd，返回 >=0 即有效 fd
 *
 * 两个进程同属一个应用（同 uid），socket 文件放在沙箱 filesDir 下。
 */

/** 后台起一个只服务一次的 server；成功入队返回 0，参数错误返回负数 */
int RelayPublish(const std::string &socketPath, int fd, int timeoutMs);

/** 连接并收 fd；返回 >=0 为 fd，负数表示失败（-2 连接失败 / -3 收超时 / -4 无控制数据） */
int RelayReceive(const std::string &socketPath, int timeoutMs);

#endif // CLASH_VERGE_OHOS_FD_RELAY_H
