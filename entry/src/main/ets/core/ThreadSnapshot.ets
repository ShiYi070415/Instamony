/*
 * 会话消息的**内存快照**（同一进程内再进这条会话，画面立刻就有）。
 *
 * ## 为什么需要
 * 用户报："初次加载会话会有点慢"。这条会话只有一条数据来源 ——
 * `direct_v2/threads/{id}/`（几十 KB，还要在全局闸门里排队），读回来之前页面只能空着。
 * 有了快照：**同一进程内**再进同一条会话，先把上一次那一屏直接铺上去（0 毫秒），
 * 网络那一发回来再整份替换（和收件箱的 DirectCache、搜索推荐流同一套做法）。
 *
 * ## 为什么只放内存、不落盘
 * 会话正文是最敏感的内容，而且用户明确要求过「不要文本快照缓存」（见
 * DirectThreadViewModel.open 里那条注释）—— 落盘就等于把它又存回来了。
 * 内存快照在进程结束时自然消失：既不落地，也不影响"点开会话就是一次干净的网络请求"。
 *
 * ## 存什么、留多久
 *   · 存 `DirectThreadView` 本身（消息数组是不可变值，直接复用，不用序列化）；
 *   · 按账号分区（`AccountScope.current()`），换账号不可能读到上一个人的私信；
 *   · 最多留 6 条会话、10 分钟 —— 超出就把整份清掉（只当"加速层"，不值得为它写淘汰算法）。
 */

import { AccountScope } from './AccountScope';
import { DirectThreadView } from '../model/Direct';

/** 最多留几条会话（超出整份清空，见文件头）。 */
const MAX_ENTRIES: number = 6;
/** 有效期（毫秒）：太旧的快照不该再拿来当首屏。 */
const MAX_AGE_MS: number = 10 * 60 * 1000;

export class ThreadSnapshot {
  private static views: Map<string, DirectThreadView> = new Map<string, DirectThreadView>();
  private static stamps: Map<string, number> = new Map<string, number>();

  /** 缓存键：账号 + 会话 id（换账号不会串）。 */
  private static keyOf(threadId: string): string {
    return `${AccountScope.current()}:${threadId}`;
  }

  /** 存一份（读成功的首屏 / 收到新消息 / 翻页合并之后都调，见 DirectThreadViewModel）。 */
  static save(threadId: string, view: DirectThreadView): void {
    if (threadId.length === 0 || view.messages.length === 0) {
      return;
    }
    const key: string = ThreadSnapshot.keyOf(threadId);
    // 重新插入一次：让"最近用过的"排在后面（这里只用容量，不做真正的 LRU）。
    if (ThreadSnapshot.views.has(key)) {
      ThreadSnapshot.views.delete(key);
      ThreadSnapshot.stamps.delete(key);
    }
    if (ThreadSnapshot.views.size >= MAX_ENTRIES) {
      ThreadSnapshot.views.clear();
      ThreadSnapshot.stamps.clear();
    }
    ThreadSnapshot.views.set(key, view);
    ThreadSnapshot.stamps.set(key, Date.now());
  }

  /** 取一份（没有 / 过期 / 空的都给 null，调用方照常等网络）。 */
  static load(threadId: string): DirectThreadView | null {
    if (threadId.length === 0) {
      return null;
    }
    const key: string = ThreadSnapshot.keyOf(threadId);
    const view: DirectThreadView | undefined = ThreadSnapshot.views.get(key);
    if (view === undefined) {
      return null;
    }
    const stamp: number | undefined = ThreadSnapshot.stamps.get(key);
    if (stamp === undefined || Date.now() - stamp > MAX_AGE_MS) {
      ThreadSnapshot.views.delete(key);
      ThreadSnapshot.stamps.delete(key);
      return null;
    }
    return view;
  }

  /** 清干净（切账号 / 退出登录时调，见 pages/Index 的账号切换路径）。 */
  static clear(): void {
    ThreadSnapshot.views.clear();
    ThreadSnapshot.stamps.clear();
  }
}
