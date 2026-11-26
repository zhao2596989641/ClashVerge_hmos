import { ContentCopyRounded } from '@mui/icons-material'
import { Button, Input, MenuItem, Select } from '@mui/material'
import { open } from '@tauri-apps/plugin-dialog'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'

import { DialogRef, TooltipIcon } from '@/components/base'
import { useVerge } from '@/hooks/use-verge'
import { navigationItems } from '@/pages/_navigation-meta'
import { copyClashEnv } from '@/services/cmds'
import { supportedLanguages } from '@/services/i18n'
import { mutate } from '@/services/mutate'
import { showNotice } from '@/services/notice-service'
import getSystem from '@/utils/get-system'

import { BackupViewer } from './mods/backup-viewer'
import { ConfigViewer } from './mods/config-viewer'
import { GuardState } from './mods/guard-state'
import { HotkeyViewer } from './mods/hotkey-viewer'
import { LayoutViewer } from './mods/layout-viewer'
import { MiscViewer } from './mods/misc-viewer'
import { SettingItem, SettingList } from './mods/setting-comp'
import { ThemeModeSwitch } from './mods/theme-mode-switch'
import { ThemeViewer } from './mods/theme-viewer'
import { UpdateViewer } from './mods/update-viewer'

interface Props {
  onError?: (err: Error) => void
}

const OS = getSystem()

const languageOptions = supportedLanguages.map((code) => {
  const labels: { [key: string]: string } = {
    en: 'English',
    ru: 'Русский',
    zh: '简体中文',
    fa: 'فارسی',
    tt: 'Татар',
    id: 'Bahasa Indonesia',
    ar: 'العربية',
    ko: '한국어',
    tr: 'Türkçe',
    de: 'Deutsch',
    es: 'Español',
    jp: '日本語',
    zhtw: '繁體中文',
    pt: 'Português',
  }
  const label = labels[code] || code
  return { code, label }
})

const ENV_TYPES = ['sh', 'bash', 'zsh', 'fish', 'nushell'] as const
const DEFAULT_ENV_TYPE = IS_OHOS ? 'sh' : OS === 'windows' ? 'powershell' : 'bash'

/**
 * 归一化环境变量类型。
 *
 * 老配置里可能是 `stable` / 空串（甚至从 Windows 导入的 `powershell`），
 * 这些值在 OHOS 的选项里都不存在 → MUI Select 的 value 匹配不到任何 MenuItem，
 * 框里就显示空白，用户完全看不出当前是哪个环境。
 */
const normalizeEnvType = (value?: string | null): string =>
  typeof value === 'string' && (ENV_TYPES as readonly string[]).includes(value)
    ? value
    : DEFAULT_ENV_TYPE

/**
 * 环境变量下拉的选项。
 *
 * ⚠️ 必须是一个**扁平数组**直接喂给 <Select>，不能用 `<>{IS_OHOS ? <>...</> : <>...</>}</>`：
 * MUI 的 SelectInput 里是 `React.Children.toArray(children)` 再逐个读 `props.value`，
 * 而 `Children.toArray` **不会展开 Fragment** —— Fragment 整体被当成一个 value=undefined
 * 的子项，于是 value 永远匹配不到任何 MenuItem，选中后框里一直空着（主人反馈的
 * 「环境变量的框框还是不显示」就是它）。选项列表本身能弹出来，所以更难察觉。
 */
const ENV_OPTIONS = IS_OHOS
  ? [
      { value: 'sh', label: 'sh (POSIX)' },
      { value: 'zsh', label: 'zsh' },
      { value: 'bash', label: 'Bash' },
      { value: 'fish', label: 'Fish' },
      { value: 'nushell', label: 'Nushell' },
    ]
  : [
      { value: 'bash', label: 'Bash' },
      { value: 'fish', label: 'Fish' },
      { value: 'nushell', label: 'Nushell' },
      { value: 'cmd', label: 'CMD' },
      { value: 'powershell', label: 'PowerShell' },
    ]

const SettingVergeBasic = ({ onError }: Props) => {
  const { t } = useTranslation()

  const { verge, patchVerge, mutateVerge } = useVerge()
  const {
    theme_mode,
    language,
    tray_event,
    env_type,
    startup_script,
    start_page,
  } = verge ?? {}
  const configRef = useRef<DialogRef>(null)
  const hotkeyRef = useRef<DialogRef>(null)
  const miscRef = useRef<DialogRef>(null)
  const themeRef = useRef<DialogRef>(null)
  const layoutRef = useRef<DialogRef>(null)
  const updateRef = useRef<DialogRef>(null)
  const backupRef = useRef<DialogRef>(null)

  const onChangeData = (patch: any) => {
    mutateVerge({ ...verge, ...patch })
  }

  // 下拉框用局部状态立即回显：不依赖 patch 往返，点完选项马上能看到
  const envValue = normalizeEnvType(env_type)
  const [envDraft, setEnvDraft] = useState(envValue)
  useEffect(() => {
    setEnvDraft(envValue)
  }, [envValue])

  const onCopyClashEnv = useCallback(async () => {
    try {
      await mutate(copyClashEnv, {
        id: 'copy-clash-env',
        onFulfilled: () =>
          showNotice.success(
            'shared.feedback.notifications.common.copySuccess',
            1000,
          ),
      })
    } catch {
      // The shared mutation boundary reports the failure.
    }
  }, [])

  return (
    <SettingList title={t('settings.components.verge.basic.title')}>
      <ThemeViewer ref={themeRef} />
      <ConfigViewer ref={configRef} />
      <HotkeyViewer ref={hotkeyRef} />
      <MiscViewer ref={miscRef} />
      <LayoutViewer ref={layoutRef} />
      <UpdateViewer ref={updateRef} />
      <BackupViewer ref={backupRef} />

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.language"
        label={t('settings.components.verge.basic.fields.language')}
      >
        <GuardState
          value={language ?? 'en'}
          onCatch={onError}
          onFormat={(e: any) => e.target.value}
          onChange={(e) => onChangeData({ language: e })}
          onGuard={(e) => patchVerge({ language: e })}
        >
          <Select size="small" sx={{ width: 110, '> div': { py: '7.5px' } }}>
            {languageOptions.map(({ code, label }) => (
              <MenuItem key={code} value={code}>
                {label}
              </MenuItem>
            ))}
          </Select>
        </GuardState>
      </SettingItem>

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.themeMode"
        label={t('settings.components.verge.basic.fields.themeMode')}
      >
        <GuardState
          value={theme_mode}
          onCatch={onError}
          onChange={(e) => onChangeData({ theme_mode: e })}
          onGuard={(e) => patchVerge({ theme_mode: e })}
        >
          <ThemeModeSwitch />
        </GuardState>
      </SettingItem>

      {OS !== 'linux' && (
        <SettingItem
          data-setting-target="settings.components.verge.basic.fields.trayClickEvent"
          label={t('settings.components.verge.basic.fields.trayClickEvent')}
        >
          <GuardState
            value={tray_event ?? 'main_window'}
            onCatch={onError}
            onFormat={(e: any) => e.target.value}
            onChange={(e) => onChangeData({ tray_event: e })}
            onGuard={(e) => patchVerge({ tray_event: e })}
          >
            <Select size="small" sx={{ width: 140, '> div': { py: '7.5px' } }}>
              <MenuItem value="main_window">
                {t(
                  'settings.components.verge.basic.trayOptions.showMainWindow',
                )}
              </MenuItem>
              <MenuItem value="tray_menu">
                {t('settings.components.verge.basic.trayOptions.showTrayMenu')}
              </MenuItem>
              <MenuItem value="tun_mode">
                {t('settings.sections.system.toggles.tunMode')}
              </MenuItem>
              <MenuItem value="disable">
                {t('settings.components.verge.basic.trayOptions.disable')}
              </MenuItem>
            </Select>
          </GuardState>
        </SettingItem>
      )}

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.copyEnvType"
        label={t('settings.components.verge.basic.fields.copyEnvType')}
        extra={
          <TooltipIcon icon={ContentCopyRounded} onClick={onCopyClashEnv} />
        }
      >
        <Select
          size="small"
          value={envDraft}
          onChange={(e) => {
            const next = String(e.target.value)
            // 先上屏，再写盘；失败才回滚
            setEnvDraft(next)
            onChangeData({ env_type: next })
            void patchVerge({ env_type: next }).catch(() => setEnvDraft(envValue))
          }}
          sx={{ width: 140, '> div': { py: '7.5px' } }}
        >
          {ENV_OPTIONS.map((option) => (
            <MenuItem key={option.value} value={option.value}>
              {option.label}
            </MenuItem>
          ))}
        </Select>
      </SettingItem>

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.startPage"
        label={t('settings.components.verge.basic.fields.startPage')}
      >
        <GuardState
          value={start_page ?? '/'}
          onCatch={onError}
          onFormat={(e: any) => e.target.value}
          onChange={(e) => onChangeData({ start_page: e })}
          onGuard={(e) => patchVerge({ start_page: e })}
        >
          <Select size="small" sx={{ width: 140, '> div': { py: '7.5px' } }}>
            {Object.values(navigationItems).map((page) => {
              return (
                <MenuItem key={page.path} value={page.path}>
                  {t(page.label)}
                </MenuItem>
              )
            })}
          </Select>
        </GuardState>
      </SettingItem>

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.startupScript"
        label={t('settings.components.verge.basic.fields.startupScript')}
      >
        <GuardState
          value={startup_script ?? ''}
          onCatch={onError}
          onFormat={(e: any) => e.target.value}
          onChange={(e) => onChangeData({ startup_script: e })}
          onGuard={(e) => patchVerge({ startup_script: e })}
        >
          <Input
            value={startup_script}
            disabled
            disableUnderline
            sx={{ width: 230 }}
            endAdornment={
              <>
                <Button
                  data-setting-target="settings.components.verge.basic.actions.browse"
                  onClick={async () => {
                    const selected = await open({
                      directory: false,
                      multiple: false,
                      filters: [
                        {
                          name: 'Shell Script',
                          extensions: ['sh', 'bat', 'ps1'],
                        },
                      ],
                    })
                    if (selected) {
                      onChangeData({ startup_script: `${selected}` })
                      patchVerge({ startup_script: `${selected}` })
                    }
                  }}
                >
                  {t('settings.components.verge.basic.actions.browse')}
                </Button>
                {startup_script && (
                  <Button
                    onClick={async () => {
                      onChangeData({ startup_script: '' })
                      patchVerge({ startup_script: '' })
                    }}
                  >
                    {t('shared.actions.clear')}
                  </Button>
                )}
              </>
            }
          ></Input>
        </GuardState>
      </SettingItem>

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.themeSetting"
        onClick={() => themeRef.current?.open()}
        label={t('settings.components.verge.basic.fields.themeSetting')}
      />

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.layoutSetting"
        onClick={() => layoutRef.current?.open()}
        label={t('settings.components.verge.basic.fields.layoutSetting')}
      />

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.misc"
        onClick={() => miscRef.current?.open()}
        label={t('settings.components.verge.basic.fields.misc')}
      />

      <SettingItem
        data-setting-target="settings.components.verge.basic.fields.hotkeySetting"
        onClick={() => hotkeyRef.current?.open()}
        label={t('settings.components.verge.basic.fields.hotkeySetting')}
      />
    </SettingList>
  )
}

export default SettingVergeBasic
