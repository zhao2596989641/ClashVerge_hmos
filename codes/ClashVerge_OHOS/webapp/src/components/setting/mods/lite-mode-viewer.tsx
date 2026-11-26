import {
  InputAdornment,
  List,
  ListItem,
  ListItemText,
  TextField,
  Typography,
} from '@mui/material'
import { useLockFn } from 'ahooks'
import type { Ref } from 'react'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { BaseDialog, DialogRef, Switch, TooltipIcon } from '@/components/base'
import { useVerge } from '@/hooks/use-verge'
import { entry_lightweight_mode } from '@/services/cmds'
import { mutate } from '@/services/mutate'
import { showNotice } from '@/services/notice-service'

import { useSettingDialog } from '../settings-search-context'

export function LiteModeViewer({ ref }: { ref?: Ref<DialogRef> }) {
  const { t } = useTranslation()
  const { verge, patchVerge } = useVerge()

  const [open, setOpen] = useState(false)
  /** 延迟分钟数的写盘防抖（鸿蒙式：不点保存，改完即生效） */
  const delayTimerRef = useRef<number | null>(null)
  const [values, setValues] = useState({
    autoEnterLiteMode: false,
    autoEnterLiteModeDelay: 10, // 默认10分钟
  })

  useSettingDialog(ref, 'lite-mode-viewer', open, () => ({
    open: () => {
      setOpen(true)
      setValues({
        autoEnterLiteMode: verge?.enable_auto_light_weight_mode ?? false,
        autoEnterLiteModeDelay: verge?.auto_light_weight_minutes ?? 10,
      })
    },
    close: () => setOpen(false),
  }))

  // 鸿蒙式交互：开关拨了就写盘，不走"保存"。延迟分钟数做 600ms 防抖。
  const applySwitch = useLockFn(async (enabled: boolean) => {
    try {
      await patchVerge({ enable_auto_light_weight_mode: enabled })
    } catch (err) {
      showNotice.error(err)
    }
  })

  const applyDelay = useLockFn(async (minutes: number) => {
    try {
      await patchVerge({ auto_light_weight_minutes: minutes })
    } catch (err) {
      showNotice.error(err)
    }
  })

  return (
    <BaseDialog
      open={open}
      title={t('settings.modals.liteMode.title')}
      contentSx={{ width: 440 }}
      // 鸿蒙设置页的惯例：开关即时生效，底部只留一个「关闭」，没有 OK/取消。
      disableOk
      cancelBtn={t('shared.actions.close')}
      onClose={() => setOpen(false)}
      onCancel={() => setOpen(false)}
    >
      <span data-settings-dialog="lite-mode-viewer" />
      <Typography
        variant="body2"
        color="text.secondary"
        sx={{ fontSize: 14, lineHeight: 1.6, px: 0.5, pt: 0.5, pb: 1 }}
      >
        轻量模式会把主窗口收进 Dock，内核与托盘图标继续运行；
        点托盘图标或 Dock 图标即可恢复。
      </Typography>
      <List sx={{ py: 0 }}>
        <ListItem
          data-setting-target="settings.modals.liteMode.actions.enterNow"
          sx={{ minHeight: 48, px: 0.5, py: 1 }}
        >
          <ListItemText
            primary={t('settings.modals.liteMode.actions.enterNow')}
            slotProps={{ primary: { sx: { fontSize: 16 } } }}
          />
          <Typography
            variant="button"
            sx={{
              cursor: 'pointer',
              color: 'primary.main',
              fontSize: 14,
              '&:hover': { textDecoration: 'underline' },
            }}
            onClick={async () =>
              await mutate(() => entry_lightweight_mode(), {
                id: 'entry-lightweight-mode',
                errorNotice: false,
              })
            }
          >
            {t('shared.actions.enable')}
          </Typography>
        </ListItem>

        <ListItem
          data-setting-target="settings.modals.liteMode.toggles.autoEnter"
          sx={{ minHeight: 48, px: 0.5, py: 1 }}
        >
          <ListItemText
            primary={t('settings.modals.liteMode.toggles.autoEnter')}
            slotProps={{ primary: { sx: { fontSize: 16 } } }}
            sx={{ maxWidth: 'fit-content' }}
          />
          <TooltipIcon
            title={t('settings.modals.liteMode.tooltips.autoEnter')}
            sx={{ opacity: '0.7' }}
          />
          <Switch
            edge="end"
            checked={values.autoEnterLiteMode}
            onChange={(_, c) => {
              setValues((v) => ({ ...v, autoEnterLiteMode: c }))
              void applySwitch(c)
            }}
            sx={{ marginLeft: 'auto' }}
          />
        </ListItem>

        {values.autoEnterLiteMode && (
          <>
            <ListItem
              data-setting-target="settings.modals.liteMode.fields.delay"
              sx={{ minHeight: 48, px: 0.5, py: 1 }}
            >
              <ListItemText
                primary={t('settings.modals.liteMode.fields.delay')}
                slotProps={{ primary: { sx: { fontSize: 16 } } }}
              />
              <TextField
                autoComplete="off"
                size="small"
                type="number"
                autoCorrect="off"
                autoCapitalize="off"
                spellCheck="false"
                sx={{ width: 150 }}
                value={values.autoEnterLiteModeDelay}
                onChange={(e) => {
                  const next = parseInt(e.target.value) || 1
                  setValues((v) => ({ ...v, autoEnterLiteModeDelay: next }))
                  if (delayTimerRef.current !== null) {
                    window.clearTimeout(delayTimerRef.current)
                  }
                  delayTimerRef.current = window.setTimeout(() => {
                    delayTimerRef.current = null
                    void applyDelay(next)
                  }, 600)
                }}
                slotProps={{
                  input: {
                    endAdornment: (
                      <InputAdornment position="end">
                        {t('shared.units.minutes')}
                      </InputAdornment>
                    ),
                  },
                }}
              />
            </ListItem>

            <ListItem sx={{ px: 0.5, py: 0.5 }}>
              <Typography
                variant="body2"
                color="text.secondary"
                sx={{ fontSize: 14, lineHeight: 1.5 }}
              >
                {t('settings.modals.liteMode.messages.autoEnterHint', {
                  n: values.autoEnterLiteModeDelay,
                })}
              </Typography>
            </ListItem>
          </>
        )}
      </List>
    </BaseDialog>
  )
}
