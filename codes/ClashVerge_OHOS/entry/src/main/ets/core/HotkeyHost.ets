import { BusinessError } from '@kit.BasicServicesKit';
import { inputConsumer, KeyCode } from '@kit.InputKit';

import { Log } from '../common/Logger';

export type HotkeyDispatch = (action: string) => void;

class HotkeyBinding {
  action: string = '';
  options: inputConsumer.HotkeyOptions = { preKeys: [], finalKey: 0, isRepeat: false };
  callback: (opt: inputConsumer.HotkeyOptions) => void = (opt: inputConsumer.HotkeyOptions): void => {
    // 占位，实际注册时替换
  };
}

/**
 * 全局快捷键（HarmonyOS `inputConsumer`，API 14+，Phone/Tablet/PC 三方可用）。
 *
 * 上游 `hotkeys` 的存储格式是 `"action,CTRL+SHIFT+T"`（parse-hotkey.ts 生成），
 * 这里把它翻译成 `HotkeyOptions{preKeys,finalKey}`：
 *   - preKeys 只接受修饰键（Ctrl/Shift/Alt），且必须至少 1 个（系统约束）；
 *   - finalKey 是被修饰键。
 * `inputConsumer` 注册失败（组合键被系统/别的应用占用）只记日志，不影响其它功能。
 */
export class HotkeyHost {
  private static dispatcher: HotkeyDispatch | null = null;
  private static bindings: HotkeyBinding[] = [];

  static setDispatcher(dispatch: HotkeyDispatch): void {
    HotkeyHost.dispatcher = dispatch;
  }

  /** 用最新的 verge.hotkeys + enable_global_hotkey 重建订阅（幂等） */
  static configure(rawHotkeys: string[], enabled: boolean): void {
    HotkeyHost.clear();
    if (!enabled) {
      Log.i('Hotkey', 'global hotkeys disabled');
      return;
    }
    for (let i = 0; i < rawHotkeys.length; i++) {
      HotkeyHost.registerOne(rawHotkeys[i]);
    }
    Log.i('Hotkey', `global hotkeys configured: ${HotkeyHost.bindings.length}/${rawHotkeys.length}`);
  }

  private static registerOne(raw: string): void {
    const comma = raw.indexOf(',');
    if (comma <= 0) {
      return;
    }
    const action = raw.substring(0, comma).trim();
    const combo = raw.substring(comma + 1).trim();
    if (action.length === 0 || combo.length === 0) {
      return;
    }
    const parts = combo.split('+');
    const preKeys: number[] = [];
    let finalKey = -1;
    for (let i = 0; i < parts.length; i++) {
      const name = parts[i].trim();
      if (name.length === 0) {
        continue;
      }
      const code = HotkeyHost.keyCodeOf(name);
      if (code <= 0) {
        Log.w('Hotkey', `unknown key "${name}" in ${combo}`);
        return;
      }
      if (HotkeyHost.isModifier(name)) {
        preKeys.push(code);
      } else {
        finalKey = code;
      }
    }
    // 系统要求 preKeys 数量 [1,4]；没有修饰键的组合（如单 F1）三方应用注册不了。
    if (preKeys.length === 0 || preKeys.length > 4 || finalKey <= 0) {
      Log.w('Hotkey', `unsupported combo "${combo}" (needs 1-4 modifiers + 1 key)`);
      return;
    }
    const binding = new HotkeyBinding();
    binding.action = action;
    binding.options = { preKeys: preKeys, finalKey: finalKey, isRepeat: false };
    binding.callback = (opt: inputConsumer.HotkeyOptions): void => {
      Log.i('Hotkey', `triggered ${binding.action}`);
      const dispatch = HotkeyHost.dispatcher;
      if (dispatch !== null) {
        dispatch(binding.action);
      }
    };
    try {
      inputConsumer.on('hotkeyChange', binding.options, binding.callback);
      HotkeyHost.bindings.push(binding);
      Log.i('Hotkey', `registered ${action} = ${combo}`);
    } catch (e) {
      const err = e as BusinessError;
      Log.w('Hotkey', `register ${combo} failed: code=${err.code} message=${err.message}`);
    }
  }

  private static clear(): void {
    for (let i = 0; i < HotkeyHost.bindings.length; i++) {
      const binding = HotkeyHost.bindings[i];
      try {
        inputConsumer.off('hotkeyChange', binding.options, binding.callback);
      } catch (e) {
        // 取消订阅失败不影响后续重建
      }
    }
    HotkeyHost.bindings = [];
  }

  private static isModifier(name: string): boolean {
    const up = name.toUpperCase();
    return up === 'CTRL' || up === 'CONTROL' || up === 'SHIFT' || up === 'ALT' ||
      up === 'OPTION' || up === 'CMD' || up === 'META';
  }

  private static keyCodeOf(name: string): number {
    const up = name.toUpperCase();
    if (up === 'CTRL' || up === 'CONTROL' || up === 'CMD' || up === 'META') {
      return KeyCode.KEYCODE_CTRL_LEFT as number;
    }
    if (up === 'SHIFT') {
      return KeyCode.KEYCODE_SHIFT_LEFT as number;
    }
    if (up === 'ALT' || up === 'OPTION') {
      return KeyCode.KEYCODE_ALT_LEFT as number;
    }
    if (up.length === 1) {
      const ch = up.charCodeAt(0);
      if (ch >= 65 && ch <= 90) {
        return (KeyCode.KEYCODE_A as number) + (ch - 65);
      }
      if (ch >= 48 && ch <= 57) {
        return (KeyCode.KEYCODE_0 as number) + (ch - 48);
      }
    }
    if (up.length >= 2 && up.length <= 3 && up.charAt(0) === 'F') {
      const n = Number(up.substring(1));
      if (n >= 1 && n <= 12) {
        return (KeyCode.KEYCODE_F1 as number) + (n - 1);
      }
    }
    switch (up) {
      case 'SPACE': return KeyCode.KEYCODE_SPACE as number;
      case 'ENTER': return KeyCode.KEYCODE_ENTER as number;
      case 'ESCAPE': case 'ESC': return KeyCode.KEYCODE_ESCAPE as number;
      case 'TAB': return KeyCode.KEYCODE_TAB as number;
      case 'BACKSPACE': return KeyCode.KEYCODE_DEL as number;
      case 'DELETE': return KeyCode.KEYCODE_FORWARD_DEL as number;
      case 'UP': case 'ARROWUP': return KeyCode.KEYCODE_DPAD_UP as number;
      case 'DOWN': case 'ARROWDOWN': return KeyCode.KEYCODE_DPAD_DOWN as number;
      case 'LEFT': case 'ARROWLEFT': return KeyCode.KEYCODE_DPAD_LEFT as number;
      case 'RIGHT': case 'ARROWRIGHT': return KeyCode.KEYCODE_DPAD_RIGHT as number;
      case 'HOME': return KeyCode.KEYCODE_MOVE_HOME as number;
      case 'END': return KeyCode.KEYCODE_MOVE_END as number;
      case 'PAGEUP': return KeyCode.KEYCODE_PAGE_UP as number;
      case 'PAGEDOWN': return KeyCode.KEYCODE_PAGE_DOWN as number;
      case 'INSERT': return KeyCode.KEYCODE_INSERT as number;
      case 'COMMA': return KeyCode.KEYCODE_COMMA as number;
      case 'PERIOD': return KeyCode.KEYCODE_PERIOD as number;
      case 'SLASH': return KeyCode.KEYCODE_SLASH as number;
      case 'SEMICOLON': return KeyCode.KEYCODE_SEMICOLON as number;
      case 'QUOTE': return KeyCode.KEYCODE_APOSTROPHE as number;
      case 'BRACKETLEFT': return KeyCode.KEYCODE_LEFT_BRACKET as number;
      case 'BRACKETRIGHT': return KeyCode.KEYCODE_RIGHT_BRACKET as number;
      case 'BACKSLASH': return KeyCode.KEYCODE_BACKSLASH as number;
      case 'MINUS': return KeyCode.KEYCODE_MINUS as number;
      case 'EQUAL': case 'EQUALS': return KeyCode.KEYCODE_EQUALS as number;
      case 'BACKQUOTE': return KeyCode.KEYCODE_GRAVE as number;
      default: return -1;
    }
  }
}