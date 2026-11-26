/**
 * 乐观选择：点节点后立刻把 UI 画成"已选中"，不等内核回包。
 *
 * 为什么需要：测速时内核会被批量探测占满，`PUT /proxies/{group}` 实测要 3–5s
 * （真机日志 18:14: 3445ms / 5051ms 超时），前端如果等它，用户看到的就是
 * "点了没反应 / 切不过去"。这里只负责观感，真正的落点由后端串行队列保证；
 * 内核回包后 `getProxyView` 会带着真实的 `now` 回来，两者一致时这条记录自然失效。
 */

type Pending = { name: string; at: number }

const TTL = 8000

const pending = new Map<string, Pending>()
const listeners = new Set<() => void>()
let version = 0

function notify(): void {
  version += 1
  listeners.forEach((listener) => listener())
}

/** 记一条"正在切过去"的选择；同组的新选择直接覆盖旧的 */
export function setPendingSelection(group: string, name: string): void {
  const at = Date.now()
  pending.set(group, { name, at })
  notify()
  // 兜底过期：内核那边一直没成功时，别让 UI 永远显示一个假选中
  window.setTimeout(() => {
    const current = pending.get(group)
    if (current && current.at === at) {
      pending.delete(group)
      notify()
    }
  }, TTL)
}

export function clearPendingSelection(group: string): void {
  if (pending.delete(group)) {
    notify()
  }
}

export function getPendingSelection(group: string): string | undefined {
  const entry = pending.get(group)
  if (!entry) return undefined
  if (Date.now() - entry.at > TTL) {
    pending.delete(group)
    return undefined
  }
  return entry.name
}

export function getPendingVersion(): number {
  return version
}

export function subscribePending(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
