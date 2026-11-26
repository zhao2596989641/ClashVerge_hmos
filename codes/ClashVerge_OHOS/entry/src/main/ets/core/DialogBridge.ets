import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';

import { Log } from '../common/Logger';
import { JsBridge } from '../bridge/JsBridge';

/**
 * `plugin:dialog|*` 的鸿蒙实现。
 *
 * Tauri 的 dialog 插件在备份导入/导出、选择文件等场景被前端调用；
 * 鸿蒙侧对应 `@ohos.file.picker`（系统文档选择器）与 `promptAction`（提示框）。
 */
export class DialogBridge {
  static install(bridge: JsBridge, context: common.UIAbilityContext): void {
    bridge.register('plugin:dialog|save', async (args: Record<string, Object>): Promise<Object | null> => {
      const options = args['options'] as Record<string, Object | null>;
      const defaultPath = DialogBridge.optionString(options, 'defaultPath');
      const fileName = DialogBridge.baseName(defaultPath, 'backup.zip');
      try {
        const saveOptions = new picker.DocumentSaveOptions();
        saveOptions.newFileNames = [fileName];
        const saveFilters = DialogBridge.suffixes(options);
        saveOptions.fileSuffixChoices = saveFilters.length > 0 ? saveFilters : ['.zip'];
        const documentPicker = new picker.DocumentViewPicker(context);
        const uris = await documentPicker.save(saveOptions);
        if (uris === undefined || uris.length === 0) {
          return null;
        }
        Log.i('Dialog', `save -> ${uris[0]}`);
        return uris[0];
      } catch (e) {
        Log.w('Dialog', `save failed: ${Log.err(e as Object)}`);
        return null;
      }
    });

    bridge.register('plugin:dialog|open', async (args: Record<string, Object>): Promise<Object | null> => {
      const options = args['options'] as Record<string, Object | null>;
      const multiple = DialogBridge.optionBool(options, 'multiple');
      try {
        const selectOptions = new picker.DocumentSelectOptions();
        selectOptions.maxSelectNumber = multiple ? 20 : 1;
        const selectFilters = DialogBridge.suffixes(options);
        if (selectFilters.length > 0) {
          selectOptions.fileSuffixFilters = selectFilters;
        }
        const documentPicker = new picker.DocumentViewPicker(context);
        const uris = await documentPicker.select(selectOptions);
        if (uris === undefined || uris.length === 0) {
          return null;
        }
        Log.i('Dialog', `open -> ${uris.length} file(s)`);
        if (!multiple) {
          return uris[0];
        }
        const list: string[] = [];
        for (let i = 0; i < uris.length; i++) {
          list.push(uris[i]);
        }
        return list;
      } catch (e) {
        Log.w('Dialog', `open failed: ${Log.err(e as Object)}`);
        return null;
      }
    });

    bridge.register('plugin:dialog|message', async (args: Record<string, Object>): Promise<Object | null> => {
      const message = args['message'];
      const title = args['title'];
      try {
        const dialogOptions: promptAction.ShowDialogOptions = {
          title: typeof title === 'string' ? title as string : 'Clash Verge',
          message: typeof message === 'string' ? message as string : '',
          buttons: [
            { text: '取消', color: '#666666' },
            { text: '确定', color: '#0A59F7' },
          ],
        };
        const result = await promptAction.showDialog(dialogOptions);
        return result.index === 1;
      } catch (e) {
        Log.w('Dialog', `message failed: ${Log.err(e as Object)}`);
        // 弹不出来时按"确认"处理，避免用户卡在无法关闭的确认框
        return true;
      }
    });
  }

  private static optionString(options: Record<string, Object | null> | undefined, key: string): string {
    if (options === undefined || options === null) {
      return '';
    }
    const value = options[key];
    return typeof value === 'string' ? value as string : '';
  }

  private static optionBool(options: Record<string, Object | null> | undefined, key: string): boolean {
    if (options === undefined || options === null) {
      return false;
    }
    return options[key] === true;
  }

  /** Tauri 的 filters 是 [{name, extensions:['zip']}]，鸿蒙要 ['.zip'] */
  private static suffixes(options: Record<string, Object | null> | undefined): string[] {
    const out: string[] = [];
    if (options === undefined || options === null) {
      return out;
    }
    const filters = options['filters'];
    if (filters !== undefined && filters !== null) {
      const list = filters as Record<string, Object | null>[];
      for (let i = 0; i < list.length; i++) {
        const exts = list[i]['extensions'];
        if (exts === undefined || exts === null) {
          continue;
        }
        const arr = exts as string[];
        for (let j = 0; j < arr.length; j++) {
          const ext = arr[j];
          if (typeof ext !== 'string' || ext.length === 0) {
            continue;
          }
          out.push(ext.startsWith('.') ? ext : `.${ext}`);
        }
      }
    }
    const direct = DialogBridge.optionStringArray(options, 'fileSuffixChoices');
    for (let i = 0; i < direct.length; i++) {
      out.push(direct[i]);
    }
    return out;
  }

  private static optionStringArray(options: Record<string, Object | null> | undefined, key: string): string[] {
    const out: string[] = [];
    if (options === undefined || options === null) {
      return out;
    }
    const value = options[key];
    if (value === undefined || value === null) {
      return out;
    }
    const arr = value as string[];
    for (let i = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string') {
        out.push(arr[i]);
      }
    }
    return out;
  }

  private static baseName(path: string, fallback: string): string {
    if (path.length === 0) {
      return fallback;
    }
    const parts = path.split('/');
    const last = parts.length > 0 ? parts[parts.length - 1] : '';
    return last.length > 0 ? last : fallback;
  }
}
