#pragma once

#include <cstdint>
#include <string>

/**
 * Go 内核（libclash_core.so）的动态适配层。
 *
 * 内核以 Go c-archive 产出后整体链进 libclash_core.so；本层用 dlopen/dlsym
 * 在运行时按符号表取函数指针，好处是：
 *   1. 内核缺失/损坏时 App 仍能启动并给出可读错误，而不是加载期直接崩溃；
 *   2. NAPI 模块本身保持极薄，避免 Go runtime 的构造函数在 UI 进程里执行。
 */

bool AdapterLoad();
bool AdapterAvailable();
std::string AdapterLastError();
std::string AdapterVersion();

void AdapterInit(const std::string &home, const std::string &version, int sdk);

/**
 * 异步初始化：立刻返回，`dlopen` + 等 Go runtime 初始化都在**独立 native 线程**里做。
 *
 * 为什么必须异步（真机 2026-11-15 10:53 日志）：
 *   `dlopen` 本身会启动 Go runtime 的初始化线程，并在 ~515ms 后才返回；
 *   在这段窗口里调用线程（原来是 UI 线程）一旦继续往下走就会与 Go 线程争 musl 的
 *   loader/TLS 锁，表现为**整个进程所有线程同时静默**、界面停在"正在加载界面"。
 *   改成独立线程后：UI 不被阻塞；`AdapterInitState()` 供 ArkTS 轮询。
 */
void AdapterInitAsync(const std::string &home, const std::string &version, int sdk);

/** 初始化状态：0=未开始 1=进行中 2=成功 3=失败 */
int AdapterInitState();

/**
 * 同步等初始化完成（只轮询状态，不会触发 dlopen）。
 *
 * 用途：`EntryAbility.onWindowStageCreate` 里 `loadContent` **之前**调用 —— 那一刻
 * ArkWeb/CEF 还没创建，可以安全地阻塞几百毫秒，把「Go runtime 初始化」与「CEF 启动」
 * 彻底串行化。返回最终状态（2=成功 3=失败 1=超时仍在进行）。
 */
int AdapterWaitReadySync(int timeoutMs);
std::string AdapterLoadConfig(const std::string &path);
int AdapterStartTun(int fd, const std::string &stack, const std::string &gateway,
                    const std::string &portal, const std::string &dns);
void AdapterStopTun();
void AdapterShutdown();

/** socket 保护回调：mihomo 出站 socket 必须经过 VpnConnection.protect，否则自身流量被自己劫持 */
void AdapterRegisterProtect(void (*fn)(int fd));
void AdapterProtectDone();

/** 运行时信息 */
std::string AdapterTraffic();      // {"up":123,"down":456}
std::string AdapterConnections();  // 预留
