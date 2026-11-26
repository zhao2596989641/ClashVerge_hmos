#include "fd_relay.h"

#include <hilog/log.h>

#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>
#include <thread>

#undef LOG_TAG
#define LOG_TAG "ClashFdRelay"
#undef LOG_DOMAIN
#define LOG_DOMAIN 0xD002

namespace {

constexpr int kPollStepMs = 100;

bool FillAddr(const std::string &path, sockaddr_un *addr)
{
    if (path.empty() || path.size() >= sizeof(addr->sun_path)) {
        return false;
    }
    std::memset(addr, 0, sizeof(*addr));
    addr->sun_family = AF_UNIX;
    std::memcpy(addr->sun_path, path.c_str(), path.size());
    return true;
}

/** 一次性 server：等到一个客户端 → 把 fd 通过 SCM_RIGHTS 发出去 → 清理 */
int PublishOnce(const std::string &path, int fd, int timeoutMs)
{
    sockaddr_un addr;
    if (!FillAddr(path, &addr)) {
        return -1;
    }
    unlink(path.c_str());
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srv < 0) {
        OH_LOG_ERROR(LOG_APP, "publish: socket failed errno=%{public}d", errno);
        return -1;
    }
    if (bind(srv, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
        OH_LOG_ERROR(LOG_APP, "publish: bind failed errno=%{public}d", errno);
        close(srv);
        return -2;
    }
    if (listen(srv, 1) != 0) {
        close(srv);
        unlink(path.c_str());
        return -3;
    }

    int waited = 0;
    int conn = -1;
    while (waited <= timeoutMs) {
        pollfd pfd = { srv, POLLIN, 0 };
        int ready = poll(&pfd, 1, kPollStepMs);
        if (ready > 0 && (pfd.revents & POLLIN) != 0) {
            conn = accept(srv, nullptr, nullptr);
            break;
        }
        if (ready < 0) {
            break;
        }
        waited += kPollStepMs;
    }
    if (conn < 0) {
        OH_LOG_WARN(LOG_APP, "publish: no client in %{public}dms", timeoutMs);
        close(srv);
        unlink(path.c_str());
        return -4;
    }

    char payload = 'F';
    iovec iov = {};
    iov.iov_base = &payload;
    iov.iov_len = 1;

    // CMSG_* 宏要求控制缓冲区按 cmsghdr 对齐；用裸 char 数组在 aarch64 上是未对齐访问
    alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))];
    std::memset(control, 0, sizeof(control));

    msghdr msg = {};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);

    cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    std::memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));

    ssize_t sent = sendmsg(conn, &msg, 0);
    OH_LOG_INFO(LOG_APP, "publish: fd=%{public}d sent=%{public}zd", fd, sent);

    close(conn);
    close(srv);
    unlink(path.c_str());
    return sent == 1 ? 0 : -5;
}

} // namespace

int RelayPublish(const std::string &socketPath, int fd, int timeoutMs)
{
    if (socketPath.empty() || fd < 0) {
        return -1;
    }
    std::thread worker([socketPath, fd, timeoutMs]() {
        PublishOnce(socketPath, fd, timeoutMs);
    });
    worker.detach();
    return 0;
}

int RelayReceive(const std::string &socketPath, int timeoutMs)
{
    sockaddr_un addr;
    if (!FillAddr(socketPath, &addr)) {
        return -1;
    }

    // 连接失败后**重开 socket** 再试：connect() 失败一次后 socket 状态是未定义的
    // （POSIX 原文），在同一个 socket 上反复 connect 可能一直返回 EALREADY。
    // 上层是 20 次 × 250ms 的轮询，这里每次都新建，成本可以忽略。
    int sock = -1;
    bool connected = false;
    int waited = 0;
    while (waited <= timeoutMs) {
        sock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sock < 0) {
            OH_LOG_ERROR(LOG_APP, "receive: socket failed errno=%{public}d", errno);
            return -1;
        }
        if (connect(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0) {
            connected = true;
            break;
        }
        close(sock);
        sock = -1;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        waited += 20;
    }
    if (!connected || sock < 0) {
        return -2;
    }

    char payload = 0;
    iovec iov = {};
    iov.iov_base = &payload;
    iov.iov_len = 1;

    alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))];
    std::memset(control, 0, sizeof(control));

    msghdr msg = {};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);

    pollfd pfd = { sock, POLLIN, 0 };
    if (poll(&pfd, 1, 500) <= 0) {
        close(sock);
        return -3;
    }

    ssize_t received = recvmsg(sock, &msg, 0);
    close(sock);
    if (received <= 0) {
        return -3;
    }
    if ((msg.msg_flags & MSG_CTRUNC) != 0) {
        OH_LOG_WARN(LOG_APP, "receive: control data truncated");
        return -4;
    }
    cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (cmsg == nullptr || cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS ||
        cmsg->cmsg_len < CMSG_LEN(sizeof(int))) {
        return -4;
    }
    int fd = -1;
    std::memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
    OH_LOG_INFO(LOG_APP, "receive: fd=%{public}d", fd);
    return fd;
}
