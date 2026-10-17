/*
 * 通知（Instagram 活动页）的数据模型。
 *
 * 字段与网页侧抓取脚本一一对应（见 bridge/WebScripts 的 NOTIFICATIONS_SCRIPT）。
 * 设计原则：**一条结构装两种卡片**——
 *   - 通知项（今天 / 昨天 / 过去 7 天 / 过去 30 天 / 更早）：avatars + usernames + text + dateText
 *     +（右侧二选一）thumbUrl 或 buttonLabel；
 *   - 推荐项（为你推荐）：avatar + username + displayName + socialText + buttonLabel。
 * 抓不到的字段一律留空/空数组，由 UI 决定显不显示，而不是在映射阶段猜一个默认值。
 */

/**
 * 通知分组。字符串而不是数字枚举：网页侧返回的也是字符串，省一层映射，日志里也直白。
 *
 * 分组按**日历天**切（需求："通知需要区分今天/昨天/过去7天/过去30天/更早/为你推荐"）：
 *   today     = 今天
 *   yesterday = 昨天
 *   past7     = 过去 7 天（2~7 天前；昨天已经单独成组，不再重复）
 *   past30    = 过去 30 天（8~30 天前）
 *   earlier   = 更早（超过 30 天，以及拿不到时间戳的）
 *   suggested = 为你推荐（ayml / 未回关用户那一段）
 *
 * 以前只有 `today / month / earlier` 三档，一个月里的东西全挤在一组（"本月"），
 * 昨天的和三十天前的看起来一样新。
 */
export type NotifyGroup = 'today' | 'yesterday' | 'past7' | 'past30' | 'earlier' | 'suggested';

/** 网页侧抓回来的一条（原始形状，字段名与脚本里的键一致）。 */
export interface NotifyPayloadItem {
  group?: string;
  avatars?: string[];
  usernames?: string[];
  text?: string;
  /** 日期文案（网页直接给了就用它；一般没有，改用 ts 在原生侧算）。 */
  date?: string;
  /** 通知时间（毫秒）。0 = 网页没给。 */
  ts?: number;
  /** 动作类型（like / follow / comment …），当前只用于诊断。 */
  type?: string;
  thumb?: string;
  button?: string;
  following?: boolean;
  /**
   * 作者用户 id（**原生取数**时从 `args.profile_id` 带出来）。
   *
   * 只用于原生侧补关注状态：`friendships/show_many` 一次问一批人的 following，
   * 问完就地写回 `following`（见 core/NativeNotifications）。
   */
  userId?: string;
  username?: string;
  displayName?: string;
  social?: string;
}

/** 脚本的整包回报。 */
export interface NotificationsPayload {
  state: string;
  items?: NotifyPayloadItem[];
  diag?: string;
  message?: string;
  /**
   * 这次扫到几行 DOM（0 = 没扫到）。
   *
   * 只有完整脚本会扫活动页的 DOM，而**关注状态只在 DOM 上**（接口里没有）：
   * rows=0 时 items 里的 following 一律是 false，代表"没读到"而不是"都没关注"。
   */
  rows?: number;
  /** 这次读到几颗「已关注」状态的按钮（诊断用）。 */
  on?: number;
}

/**
 * 「读对方主页关注状态」脚本的回报（见 bridge/WebScripts 的 followStateScript）。
 *
 * state：ok（找到按钮了）/ no-button（页面上还没有）/ error。
 */
export interface FollowPageState {
  state: string;
  /** URL 里的人名，用来确认真的到了这个人的主页。 */
  path?: string;
  /** 按钮当前文案（「关注/回关/已关注/Following」…）。 */
  label?: string;
  /** 当前是不是已关注。 */
  following?: boolean;
  /** 页面上按钮文案的样本，找不到按钮时用来排查。 */
  seen?: string;
  message?: string;
}

/**
 * 「点主页关注按钮」脚本的回报（见 followClickScript）。
 *
 * state：clicked / already（本来就是已关注）/ no-button / wrong-page / error。
 */
export interface FollowClickResult {
  state: string;
  before?: string;
  path?: string;
  seen?: string;
  /** 点到的那颗节点的 tag/role/class，排查用。 */
  node?: string;
  message?: string;
}

/**
 * 一次关注的结果。
 *
 * `following` 是**网页上的实际状态**（界面照它校正）；`clicked` 表示这次真的点了按钮，
 * 用来决定要不要弹"已关注"——页面本来就是已关注时不该弹。
 */
export class FollowOutcome {
  readonly following: boolean;
  readonly clicked: boolean;

  constructor(following: boolean, clicked: boolean) {
    this.following = following;
    this.clicked = clicked;
  }
}

/** UI 用的一条：把网页侧的松散字段收紧成确定类型（缺的给空值）。 */
export class NotifyItem {
  readonly group: NotifyGroup;
  /** 头像：通知项最多两张（"A 和 B 赞了…"），推荐项一张。 */
  readonly avatars: string[];
  /** 文案里高亮的用户 id。 */
  readonly usernames: string[];
  /** 动作文案，例如"赞了你的快拍。"。 */
  readonly text: string;
  /** 日期文案，例如"9月19日"；网页没给就是空串。 */
  readonly dateText: string;
  /** 右侧缩略图（帖子/快拍封面）；空则不显示。 */
  readonly thumbUrl: string;
  /** 右侧按钮文案（"已关注"/"关注"）；空则不显示按钮。 */
  readonly buttonLabel: string;
  /** 按钮当前状态：true = 已关注（描边样式），false = 可关注（实心样式）。 */
  readonly following: boolean;
  /** 推荐项：用户 id（账号名）。 */
  readonly username: string;
  /** 推荐项：用户名称（昵称）。 */
  readonly displayName: string;
  /** 推荐项：粉丝文案，例如"粉丝: xxx 和其他 1 位用户"。 */
  readonly socialText: string;
  /**
   * 对方的用户 id（原生取数时从 `args.profile_id` / `pk` 带出来）。
   *
   * 「回关」按钮要用它发 HTTP：`POST /api/v1/friendships/create/{id}/`。
   * 空串 = 这条没有可用的 id（例如 Meta 账户那类系统通告），按钮不该出现。
   */
  readonly userId: string;

  constructor(group: NotifyGroup, avatars: string[], usernames: string[], text: string,
    dateText: string, thumbUrl: string, buttonLabel: string, following: boolean,
    username: string, displayName: string, socialText: string, userId: string) {
    this.group = group;
    this.avatars = avatars;
    this.usernames = usernames;
    this.text = text;
    this.dateText = dateText;
    this.thumbUrl = thumbUrl;
    this.buttonLabel = buttonLabel;
    this.following = following;
    this.username = username;
    this.displayName = displayName;
    this.socialText = socialText;
    this.userId = userId;
  }

  /** 这条是不是"为你推荐"里的推荐账号（卡片布局完全不同）。 */
  isSuggested(): boolean {
    return this.group === 'suggested';
  }

  /**
   * 这条的"对方账号名"。
   *
   * 通知项是文案里第一个高亮用户名；推荐项就是 username。取不到返回空串。
   */
  accountName(): string {
    if (this.username.length > 0) {
      return this.username;
    }
    return this.usernames.length > 0 ? this.usernames[0] : '';
  }

  /**
   * 造一条只改了关注状态的新条目。
   *
   * 字段是只读的、列表又是整体替换语义（和 FeedMapper.withLiked 同一个道理），
   * 所以点完关注要换一条新对象，UI 才会重绘。
   */
  withFollowing(following: boolean): NotifyItem {
    return new NotifyItem(
      this.group,
      this.avatars,
      this.usernames,
      this.text,
      this.dateText,
      this.thumbUrl,
      this.isSuggested() ? '' : (following ? 'following' : 'follow'),
      following,
      this.username,
      this.displayName,
      this.socialText,
      this.userId
    );
  }
}

/** 分组顺序 = 界面从上到下的顺序（需求给的顺序，见 NotifyGroup 的说明）。 */
export const NOTIFY_GROUPS: NotifyGroup[] =
  ['today', 'yesterday', 'past7', 'past30', 'earlier', 'suggested'];

/** 网页侧的分组字符串 → 枚举；认不出来就落到"更早"。 */
export function toNotifyGroup(raw: string | undefined): NotifyGroup {
  const value: string = (raw ?? '').toLowerCase();
  if (value === 'today') {
    return 'today';
  }
  if (value === 'yesterday') {
    return 'yesterday';
  }
  if (value === 'past7' || value === 'week' || value === 'lastweek') {
    return 'past7';
  }
  // 老接口把整月那一档叫 `month`：现在语义是"过去 30 天"。
  if (value === 'past30' || value === 'month') {
    return 'past30';
  }
  if (value === 'suggested') {
    return 'suggested';
  }
  return 'earlier';
}
