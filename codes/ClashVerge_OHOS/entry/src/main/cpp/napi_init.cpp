#include <napi/native_api.h>
#include <hilog/log.h>

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>

#include "clash_adapter.h"
#include "fd_relay.h"

#undef LOG_TAG
#define LOG_TAG "ClashNapi"

namespace {

void SetString(napi_env env, napi_value *out, const std::string &text)
{
    napi_create_string_utf8(env, text.c_str(), text.size(), out);
}

std::string GetString(napi_env env, napi_value value)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return std::string();
    }
    std::string buf(len, '\0');
    size_t copied = 0;
    napi_get_value_string_utf8(env, value, buf.data(), len + 1, &copied);
    buf.resize(copied);
    return buf;
}

int32_t GetInt(napi_env env, napi_value value, int32_t fallback)
{
    int32_t out = fallback;
    if (napi_get_value_int32(env, value, &out) != napi_ok) {
        return fallback;
    }
    return out;
}

// ---- socket protect：Go 线程 → JS 回调（threadsafe function） ----
napi_threadsafe_function gProtectTsfn = nullptr;
std::mutex gProtectMutex;
std::condition_variable gProtectCv;
bool gProtectDoneFlag = false;

void CallJsProtect(napi_env env, napi_value jsCallback, void *, void *data)
{
    if (env == nullptr || jsCallback == nullptr) {
        return;
    }
    int fd = static_cast<int>(reinterpret_cast<intptr_t>(data));
    napi_value argv[1];
    napi_create_int32(env, fd, &argv[0]);
    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_call_function(env, global, jsCallback, 1, argv, nullptr);
}

void OnMarkSocket(int fd)
{
    if (gProtectTsfn != nullptr) {
        napi_call_threadsafe_function(gProtectTsfn, reinterpret_cast<void *>(static_cast<intptr_t>(fd)),
                                      napi_tsfn_blocking);
    }
    std::unique_lock<std::mutex> lock(gProtectMutex);
    gProtectCv.wait_for(lock, std::chrono::milliseconds(3000), [] { return gProtectDoneFlag; });
    gProtectDoneFlag = false;
}

napi_value NapiPing(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    SetString(env, &result, std::string("clash-ohos-napi"));
    return result;
}

napi_value NapiCoreVersion(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    SetString(env, &result, AdapterVersion());
    return result;
}

napi_value NapiCoreAvailable(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_get_boolean(env, AdapterAvailable(), &result);
    return result;
}

napi_value NapiLastError(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    SetString(env, &result, AdapterLastError());
    return result;
}

napi_value NapiCoreInit(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string home;
    std::string variant;
    int32_t sdk = 0;
    if (argc >= 1) {
        home = GetString(env, argv[0]);
    }
    if (argc >= 2) {
        variant = GetString(env, argv[1]);
    }
    if (argc >= 3) {
        sdk = GetInt(env, argv[2], 0);
    }
    AdapterInit(home, variant, sdk);
    return nullptr;
}

napi_value NapiCoreInitAsync(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string home;
    std::string variant;
    int32_t sdk = 0;
    if (argc >= 1) {
        home = GetString(env, argv[0]);
    }
    if (argc >= 2) {
        variant = GetString(env, argv[1]);
    }
    if (argc >= 3) {
        sdk = GetInt(env, argv[2], 0);
    }
    AdapterInitAsync(home, variant, sdk);
    return nullptr;
}

napi_value NapiCoreInitState(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_create_int32(env, AdapterInitState(), &result);
    return result;
}

napi_value NapiCoreWaitReadySync(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t timeoutMs = argc >= 1 ? GetInt(env, argv[0], 5000) : 5000;
    napi_value result = nullptr;
    napi_create_int32(env, AdapterWaitReadySync(timeoutMs), &result);
    return result;
}

napi_value NapiLoadConfig(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string path = argc >= 1 ? GetString(env, argv[0]) : std::string();
    napi_value result = nullptr;
    SetString(env, &result, AdapterLoadConfig(path));
    return result;
}

napi_value NapiStartTun(napi_env env, napi_callback_info info)
{
    size_t argc = 5;
    napi_value argv[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t fd = argc >= 1 ? GetInt(env, argv[0], -1) : -1;
    std::string stack = argc >= 2 ? GetString(env, argv[1]) : std::string("gvisor");
    std::string gateway = argc >= 3 ? GetString(env, argv[2]) : std::string();
    std::string portal = argc >= 4 ? GetString(env, argv[3]) : std::string();
    std::string dns = argc >= 5 ? GetString(env, argv[4]) : std::string();
    int rc = AdapterStartTun(fd, stack, gateway, portal, dns);
    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
}

napi_value NapiStopTun(napi_env env, napi_callback_info info)
{
    AdapterStopTun();
    return nullptr;
}

napi_value NapiShutdown(napi_env env, napi_callback_info info)
{
    AdapterShutdown();
    return nullptr;
}

napi_value NapiSetProtectHook(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        return nullptr;
    }
    napi_value name = nullptr;
    napi_create_string_utf8(env, "ClashProtect", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, argv[0], nullptr, name, 0, 1, nullptr, nullptr, nullptr,
                                    CallJsProtect, &gProtectTsfn);
    AdapterRegisterProtect(OnMarkSocket);
    return nullptr;
}

napi_value NapiProtectDone(napi_env env, napi_callback_info info)
{
    {
        std::lock_guard<std::mutex> lock(gProtectMutex);
        gProtectDoneFlag = true;
    }
    gProtectCv.notify_all();
    AdapterProtectDone();
    return nullptr;
}

napi_value NapiRelayPublish(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value argv[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string path = argc >= 1 ? GetString(env, argv[0]) : std::string();
    int32_t fd = argc >= 2 ? GetInt(env, argv[1], -1) : -1;
    int32_t timeoutMs = argc >= 3 ? GetInt(env, argv[2], 10000) : 10000;
    int rc = RelayPublish(path, fd, timeoutMs);
    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
}

napi_value NapiRelayReceive(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string path = argc >= 1 ? GetString(env, argv[0]) : std::string();
    int32_t timeoutMs = argc >= 2 ? GetInt(env, argv[1], 1500) : 1500;
    int fd = RelayReceive(path, timeoutMs);
    napi_value result = nullptr;
    napi_create_int32(env, fd, &result);
    return result;
}

napi_value NapiTraffic(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    SetString(env, &result, AdapterTraffic());
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"ping", nullptr, NapiPing, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreVersion", nullptr, NapiCoreVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreAvailable", nullptr, NapiCoreAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, NapiLastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreInit", nullptr, NapiCoreInit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreInitAsync", nullptr, NapiCoreInitAsync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreInitState", nullptr, NapiCoreInitState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreWaitReadySync", nullptr, NapiCoreWaitReadySync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadConfig", nullptr, NapiLoadConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startTun", nullptr, NapiStartTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopTun", nullptr, NapiStopTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shutdown", nullptr, NapiShutdown, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProtectHook", nullptr, NapiSetProtectHook, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"protectDone", nullptr, NapiProtectDone, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"traffic", nullptr, NapiTraffic, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"relayPublish", nullptr, NapiRelayPublish, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"relayReceive", nullptr, NapiRelayReceive, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    OH_LOG_INFO(LOG_APP, "clash napi module initialized");
    return exports;
}

napi_module clashModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "clash_ohos",
    .nm_priv = nullptr,
    .reserved = {0},
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterClashModule(void)
{
    napi_module_register(&clashModule);
}
