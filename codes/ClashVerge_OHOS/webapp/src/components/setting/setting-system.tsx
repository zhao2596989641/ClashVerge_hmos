import { Box, Button } from '@mui/material'
import React from 'react'
import { useTranslation } from 'react-i18next'

import { Switch, TooltipIcon } from '@/components/base'
import ProxyControlSwitches from '@/components/shared/proxy-control-switches'
import { useVerge } from '@/hooks/use-verge'
import { openAutoStartSettings } from '@/services/cmds'

import { GuardState } from './mods/guard-state'
import { SettingList, SettingItem } from './mods/setting-comp'

interface Props {
  onError?: (err: Error) => void
}

const SettingSystem = ({ onError }: Props) => {
  const { t } = useTranslation()

  const { verge, mutateVerge, patchVerge } = useVerge()

  const { enable_silent_start } = verge ?? {}

  const onSwitchFormat = (
    _e: React.ChangeEvent<HTMLInputElement>,
    value: boolean,
  ) => value
  const onChangeData = (patch: Partial<IVergeConfig>) => {
    mutateVerge({ ...verge, ...patch })
  }

  return (
    <SettingList title={t('settings.sections.system.title')}>
      <Box data-setting-target="settings.sections.system.toggles.tunMode">
        <ProxyControlSwitches
          label={t('settings.sections.system.toggles.tunMode')}
          onError={onError}
        />
      </Box>

      {!IS_OHOS && (
        <Box data-setting-target="settings.sections.system.toggles.systemProxy">
          <ProxyControlSwitches
            label={t('settings.sections.system.toggles.systemProxy')}
            onError={onError}
          />
        </Box>
      )}

      <SettingItem
        data-setting-target="settings.sections.system.fields.autoLaunch"
        label={t('settings.sections.system.fields.autoLaunch')}
      >
        {/* 鸿蒙三方应用不能改系统开机自启；只能引导用户去系统设置 */}
        <Button
          variant="outlined"
          size="small"
          onClick={() => {
            void openAutoStartSettings().catch((e: Error) => {
              onError?.(e)
            })
          }}
        >
          转到设置
        </Button>
      </SettingItem>

      <SettingItem
        data-setting-target="settings.sections.system.fields.silentStart"
        label={t('settings.sections.system.fields.silentStart')}
        extra={
          <TooltipIcon
            title={t('settings.sections.system.tooltips.silentStart')}
            sx={{ opacity: '0.7' }}
          />
        }
      >
        <GuardState
          value={enable_silent_start ?? false}
          valueProps="checked"
          onCatch={onError}
          onFormat={onSwitchFormat}
          onChange={(e) => onChangeData({ enable_silent_start: e })}
          onGuard={(e) => patchVerge({ enable_silent_start: e })}
        >
          <Switch edge="end" />
        </GuardState>
      </SettingItem>
    </SettingList>
  )
}

export default SettingSystem
