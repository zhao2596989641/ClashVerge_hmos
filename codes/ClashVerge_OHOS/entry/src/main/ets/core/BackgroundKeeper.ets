import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

import { BUNDLE_NAME } from '../common/Constants';
import { Log } from '../common/Logger';

/**
 * 长时任务保活。
 *
 * ⚠️ 两个容易踩错的地方（2026-11-13 复核轮按 d.ts 原文修正）：
 *
 * 1. **主进程必须活着**。官方《连接 VPN》服务生命周期明确：「当调用
 *    startVpnExtensionAbility 接口的应用进程退出时，系统会主动停止 VPN」。
 *    所以这里不是"锦上添花"，而是代理能不能持续工作的前提。
 *
 * 2. **优先用 TASK_KEEPING，不要一上来用 DATA_TRANSFER**。
 *    d.ts 原文：DATA_TRANSFER「若超过 10 分钟未更新进度，该类型的连续任务会被取消」，
 *    且要求进度更新必须是 live view 通知 —— 我们做代理并不发进度通知，
 *    用 DATA_TRANSFER 等于内置了一个 10 分钟后自动断线的定时炸弹。
 *    而 TASK_KEEPING（计算任务）从 API 21 起对 **PC/2in1 设备**直接可用，没有进度限制，
 *    正是我们这种「后台常驻转发」的场景。
 */
export class BackgroundKeeper {
  private static running: boolean = false;
  private static mode: string = '';

  static isRunning(): boolean {
    return BackgroundKeeper.running;
  }

  static activeMode(): string {
    return BackgroundKeeper.mode;
  }

  static async start(context: common.UIAbilityContext): Promise<boolean> {
    if (BackgroundKeeper.running) {
      return true;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: BUNDLE_NAME,
            abilityName: 'EntryAbility',
          },
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);

      // PC/2in1 优先 TASK_KEEPING（无进度限制）；其它设备退回 DATA_TRANSFER
      // （DATA_TRANSFER 需要持续更新进度，否则 10 分钟被取消，见类注释）
      const candidates: backgroundTaskManager.BackgroundMode[] = [
        backgroundTaskManager.BackgroundMode.TASK_KEEPING,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
      ];
      let lastError = '';
      for (let i = 0; i < candidates.length; i++) {
        const mode = candidates[i];
        try {
          await backgroundTaskManager.startBackgroundRunning(context, mode, agent);
          BackgroundKeeper.running = true;
          BackgroundKeeper.mode = mode === backgroundTaskManager.BackgroundMode.TASK_KEEPING
            ? 'TASK_KEEPING' : 'DATA_TRANSFER';
          Log.i('Background', `continuous task started (${BackgroundKeeper.mode})`);
          return true;
        } catch (e) {
          lastError = Log.err(e as Object);
          Log.w('Background', `mode ${mode} rejected: ${lastError}`);
        }
      }
      Log.w('Background', `start continuous task failed: ${lastError}`);
      return false;
    } catch (e) {
      Log.w('Background', `start continuous task failed: ${Log.err(e as Object)}`);
      return false;
    }
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (!BackgroundKeeper.running) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      Log.i('Background', 'continuous task stopped');
    } catch (e) {
      Log.w('Background', `stop continuous task failed: ${Log.err(e as Object)}`);
    }
    BackgroundKeeper.running = false;
  }

  /** 由 Ability 在进入后台时调用：仅在代理运行中才保活 */
  static keepAliveIfNeeded(context: common.UIAbilityContext): void {
    if (!BackgroundKeeper.running) {
      return;
    }
    BackgroundKeeper.start(context).catch((e: Object) => {
      Log.w('Background', `keepAlive failed: ${Log.err(e)}`);
    });
  }
}
