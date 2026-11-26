import { useCallback } from 'react'

import { switchProxyNode } from '@/services/cmds'
import { mutate } from '@/services/mutate'
import {
  clearPendingSelection,
  setPendingSelection,
} from '@/services/pending-selection'

interface ProxySelectionOptions {
  onError?: (error: any) => void
}

interface ProxyChangeRequest {
  groupName: string
  proxyName: string
  fixed?: string
}

export const useProxySelection = (options: ProxySelectionOptions = {}) => {
  const { onError } = options

  const executeChange = useCallback(
    async ({ groupName, proxyName, fixed }: ProxyChangeRequest) => {
      try {
        await mutate(
          () => switchProxyNode(groupName, proxyName, fixed === proxyName),
          { id: `select-proxy-node:${groupName}`, errorNotice: false },
        )
      } catch (error) {
        console.error(
          `[ProxySelection] Failed to switch proxy: ${groupName} -> ${proxyName}`,
          error,
        )
        clearPendingSelection(groupName)
        onError?.(error)
      }
    },
    [onError],
  )

  const select = useCallback(
    (groupName: string, proxyName: string, fixed?: string) => {
      // 先乐观上屏：后端现在立即返回，PUT 在后台串行落地（见 AppBridge.proxyQueue）
      setPendingSelection(groupName, proxyName)
      void executeChange({
        groupName,
        proxyName,
        fixed,
      })
    },
    [executeChange],
  )

  return { select }
}
