// dladdr / Dl_info 需要 _GNU_SOURCE（musl 下 dlfcn.h 才声明）
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include "clash_adapter.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <hilog/log.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#undef LOG_TAG
#define LOG_TAG "ClashAdapter"

namespace {
constexpr const char *kCoreLibName = "libclash_core.so";

// redirectStdioToFile 必须在**调用任何 Go 函数之前**执行。
//
// 为什么（真机实测，2026-11-14）：
//   应用进程的 fd 2 通常是个没人读的管道。mihomo 的日志和 Go 的 fatal error 都写 fd 2，
//   管道写满后 write(2) 会永久阻塞 → 整个 coreInit 卡死 → 界面停在"正在加载界面"。
//   而且 Go 是直接写 fd 的，hilog 里看不到任何线索。
//   提前把 fd 1/2 接到 `<home>/logs/core.log`：既不会阻塞，又能把 Go 的 panic 留下来。
void redirectStdioToFile(const std::string &home)
{
    if (home.empty()) {
        return;
    }
    std::string dir = home + "/logs";
    mkdir(dir.c_str(), 0755);
    std::string path = dir + "/core.log";
    int fd = open(path.c_str(), O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) {
        OH_LOG_WARN(LOG_APP, "open %{public}s failed: %{public}d", path.c_str(), errno);
        return;
    }
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2) {
        close(fd);
    }
    OH_LOG_INFO(LOG_APP, "stdio redirected to %{public}s", path.c_str());
}

using core_init_fn = void (*)(const char *, const char *, const char *, int);
using core_load_fn = const char *(*)(const char *);
using core_start_tun_fn = int (*)(int, const char *, const char *, const char *, const char *);
using core_stop_tun_fn = void (*)();
using core_shutdown_fn = void (*)();
using core_version_fn = const char *(*)();
using core_traffic_fn = const char *(*)();
using core_protect_wait_fn = void (*)(void (*)(int));

void *gHandle = nullptr;
bool gLoadAttempted = false;
std::string gLastError = "not attempted";
std::mutex gMutex;

core_init_fn pInit = nullptr;
core_load_fn pLoad = nullptr;
core_start_tun_fn pStartTun = nullptr;
core_stop_tun_fn pStopTun = nullptr;
core_shutdown_fn pShutdown = nullptr;
core_version_fn pVersion = nullptr;
core_traffic_fn pTraffic = nullptr;

// Go 侧 init() 完成后置 1（定义在 clash_core_marker.c，构建时和 Go 归档一起链进 .so）。
// 只在 C 侧读内存，**不需要进入 Go**。
volatile int *gReady = nullptr;

// 异步初始化状态机：0=未开始 1=进行中 2=成功 3=失败（ArkTS 侧轮询）
std::atomic<int> gInitState{0};

bool ReadyNow()
{
    return gReady != nullptr && *gReady != 0;
}

template <typename T>
void resolve(void *handle, const char *name, T &slot)
{
    slot = reinterpret_cast<T>(dlsym(handle, name));
}

/**
 * 本模块自身所在目录（用来兜底找同目录下的 libclash_core.so）。
 *
 * 为什么需要兜底：`dlopen("libclash_core.so")` 是按 **库搜索路径** 找的，
 * 而应用沙箱里 native 库所在目录（`.../haps/<mod>/libs/arm64`）不一定在
 * musl 的默认搜索路径里。实机上如果内核起不来、日志只写
 * `core unavailable: dlopen ...: No such file or directory`，就是这一条。
 */
std::string SelfDir()
{
    Dl_info info;
    std::memset(&info, 0, sizeof(info));
    if (dladdr(reinterpret_cast<void *>(&AdapterLoad), &info) == 0 || info.dli_fname == nullptr) {
        return std::string();
    }
    std::string path(info.dli_fname);
    const size_t slash = path.rfind('/');
    if (slash == std::string::npos) {
        return std::string();
    }
    return path.substr(0, slash);
}
} // namespace

bool AdapterLoad()
{
    std::lock_guard<std::mutex> lock(gMutex);
    if (gLoadAttempted) {
        return gHandle != nullptr;
    }
    gLoadAttempted = true;

    gHandle = dlopen(kCoreLibName, RTLD_NOW | RTLD_GLOBAL);
    if (gHandle == nullptr) {
        const char *err = dlerror();
        std::string firstError = err != nullptr ? err : "dlopen failed";
        // 兜底：按「本模块同目录」的绝对路径再试一次
        const std::string dir = SelfDir();
        if (!dir.empty()) {
            const std::string abs = dir + "/" + kCoreLibName;
            gHandle = dlopen(abs.c_str(), RTLD_NOW | RTLD_GLOBAL);
            if (gHandle != nullptr) {
                OH_LOG_INFO(LOG_APP, "core loaded via absolute path %{public}s", abs.c_str());
            } else {
                const char *err2 = dlerror();
                gLastError = firstError + " | " + (err2 != nullptr ? err2 : "abs path failed") +
                    " | dir=" + dir;
                OH_LOG_ERROR(LOG_APP, "dlopen %{public}s failed: %{public}s", kCoreLibName, gLastError.c_str());
                return false;
            }
        } else {
            gLastError = firstError + " | self dir unknown";
            OH_LOG_ERROR(LOG_APP, "dlopen %{public}s failed: %{public}s", kCoreLibName, gLastError.c_str());
            return false;
        }
    }
    resolve(gHandle, "clash_core_init", pInit);
    resolve(gHandle, "clash_core_load", pLoad);
    resolve(gHandle, "clash_core_start_tun", pStartTun);
    resolve(gHandle, "clash_core_stop_tun", pStopTun);
    resolve(gHandle, "clash_core_shutdown", pShutdown);
    resolve(gHandle, "clash_core_version", pVersion);
    resolve(gHandle, "clash_core_traffic", pTraffic);
    gReady = reinterpret_cast<volatile int *>(dlsym(gHandle, "clash_core_ready"));
    if (pInit == nullptr || pLoad == nullptr || pStartTun == nullptr) {
        gLastError = "core symbols missing";
        OH_LOG_ERROR(LOG_APP, "core symbols missing");
        return false;
    }
    gLastError = "";
    OH_LOG_INFO(LOG_APP, "core loaded (ready flag %{public}s)", gReady != nullptr ? "found" : "MISSING");
    return true;
}

/**
 * 等 Go 初始化完成。
 *
 * 真机实测（2026-11-15）：dlopen 会在**另一个线程**上启动 Go runtime 并跑 doInit，
 * 而 dlopen 自己立刻返回。此时从 ArkTS 线程「立刻」调进 Go，会撞在初始化中间：
 * 进程卡死、界面停在"正在加载界面…"，连一行日志都出不来（调试器里能看到线程停在
 * runtime.doInit1 → runtime.init.* ）。
 *
 * 所以这里轮询 clash_core_ready（纯 C 内存读），等到 1 再允许调用任何 Go 函数。
 */
static bool AdapterWaitReady(int timeoutMs)
{
    if (gReady == nullptr) {
        // 老版本 .so 没有这个符号：只能按原来的方式直接试
        return true;
    }
    const int stepMs = 10;
    int waited = 0;
    int lastLog = -1000;
    // 第一条必须**立刻**打印：上一版要等 1s 才打，结果主线程一卡住就没有任何线索，
    // 只能看到 "core loaded" 之后彻底静默（真机 2026-11-15 10:53）。
    OH_LOG_INFO(LOG_APP, "waiting for go core init (ready=%{public}d, step=%{public}dms)",
                *gReady, stepMs);
    while (*gReady == 0) {
        if (waited >= timeoutMs) {
            OH_LOG_ERROR(LOG_APP, "go core not ready after %{public}dms", waited);
            gLastError = "core init timeout";
            return false;
        }
        usleep(stepMs * 1000);
        waited += stepMs;
        if (waited - lastLog >= 1000) {
            lastLog = waited;
            OH_LOG_INFO(LOG_APP, "waiting for go core init... %{public}dms", waited);
        }
    }
    // 标志是「包 init 完成」，之后 runtime.main 还要收尾（gcenable 等）。
    // 给一个小宽限，避免刚好踩在收尾阶段。
    usleep(50 * 1000);
    OH_LOG_INFO(LOG_APP, "go core ready after %{public}dms", waited);
    return true;
}

bool AdapterAvailable()
{
    return AdapterLoad();
}

std::string AdapterLastError()
{
    return gLastError;
}

std::string AdapterVersion()
{
    if (!AdapterLoad() || pVersion == nullptr) {
        return std::string("unavailable");
    }
    // ⚠️ 这里也是 Go 调用：没就绪就绝对不能调，否则整进程卡死
    if (gReady != nullptr && *gReady == 0) {
        return std::string("initializing");
    }
    const char *v = pVersion();
    return v != nullptr ? std::string(v) : std::string("unknown");
}

void AdapterInit(const std::string &home, const std::string &version, int sdk)
{
    redirectStdioToFile(home);
    // Go 的 inittrace 会逐包打印初始化耗时到 fd 2（已重定向到 core.log），
    // 排查"卡在哪个包的 init"时这是最直接的证据。必须在 dlopen 之前设好。
    setenv("GODEBUG", "inittrace=1", 0);
    setenv("GOTRACEBACK", "system", 0);

    OH_LOG_INFO(LOG_APP, "calling clash_core_init home=%{public}s ver=%{public}s", home.c_str(),
                version.c_str());
    if (!AdapterLoad()) {
        OH_LOG_ERROR(LOG_APP, "clash_core_init skipped: %{public}s", gLastError.c_str());
        return;
    }
    // 必须等 Go runtime 的 doInit 跑完（dlopen 之后它还在另一个线程里跑）
    if (!AdapterWaitReady(60000)) {
        OH_LOG_ERROR(LOG_APP, "clash_core_init aborted: %{public}s", gLastError.c_str());
        return;
    }
    pInit(home.c_str(), version.c_str(), "", sdk);
    OH_LOG_INFO(LOG_APP, "clash_core_init returned");
}

void AdapterInitAsync(const std::string &home, const std::string &version, int sdk)
{
    int expected = 0;
    if (!gInitState.compare_exchange_strong(expected, 1)) {
        OH_LOG_INFO(LOG_APP, "core init already scheduled (state=%{public}d)", expected);
        return;
    }
    OH_LOG_INFO(LOG_APP, "core init scheduled on native thread");
    std::thread([home, version, sdk]() {
        // 线程名方便在 hilog / 调试器里认出这条线程
        AdapterInit(home, version, sdk);
        const bool ok = ReadyNow();
        gInitState.store(ok ? 2 : 3);
        OH_LOG_INFO(LOG_APP, "core init finished state=%{public}d ready=%{public}d", ok ? 2 : 3,
                    ok ? 1 : 0);
    }).detach();
}

int AdapterInitState()
{
    return gInitState.load();
}

int AdapterWaitReadySync(int timeoutMs)
{
    int waited = 0;
    while (waited < timeoutMs) {
        const int state = gInitState.load();
        if (state == 2 || state == 3) {
            OH_LOG_INFO(LOG_APP, "core waitReadySync: state=%{public}d after %{public}dms", state,
                        waited);
            return state;
        }
        usleep(20 * 1000);
        waited += 20;
    }
    const int state = gInitState.load();
    OH_LOG_WARN(LOG_APP, "core waitReadySync timeout after %{public}dms state=%{public}d", waited,
                state);
    return state;
}

std::string AdapterLoadConfig(const std::string &path)
{
    if (!AdapterLoad()) {
        return gLastError;
    }
    const char *err = pLoad(path.c_str());
    return err != nullptr ? std::string(err) : std::string();
}

int AdapterStartTun(int fd, const std::string &stack, const std::string &gateway,
                    const std::string &portal, const std::string &dns)
{
    if (!AdapterLoad() || pStartTun == nullptr) {
        return -1;
    }
    return pStartTun(fd, stack.c_str(), gateway.c_str(), portal.c_str(), dns.c_str());
}

void AdapterStopTun()
{
    if (pStopTun != nullptr) {
        pStopTun();
    }
}

void AdapterShutdown()
{
    if (pShutdown != nullptr) {
        pShutdown();
    }
}

void AdapterRegisterProtect(void (*fn)(int fd))
{
    if (!AdapterLoad()) {
        return;
    }
    auto setter = reinterpret_cast<core_protect_wait_fn>(dlsym(gHandle, "clash_core_set_protect_hook"));
    if (setter != nullptr) {
        setter(fn);
    }
}

void AdapterProtectDone()
{
    if (gHandle == nullptr) {
        return;
    }
    auto done = reinterpret_cast<void (*)()>(dlsym(gHandle, "clash_core_protect_done"));
    if (done != nullptr) {
        done();
    }
}

std::string AdapterTraffic()
{
    if (!AdapterLoad() || pTraffic == nullptr) {
        return std::string("{\"up\":0,\"down\":0}");
    }
    const char *json = pTraffic();
    return json != nullptr ? std::string(json) : std::string("{\"up\":0,\"down\":0}");
}

std::string AdapterConnections()
{
    return std::string("[]");
}
