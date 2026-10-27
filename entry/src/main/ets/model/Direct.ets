/*
 * 私信（Direct）收件箱的模型。
 *
 * 字段名与页面脚本（WebScripts.directInboxScript）一一对应：脚本在页面里把几百 KB 的响应
 * 抽成十几个字段再回传，原生这边只做映射，不再碰原始 JSON。
 *
 * 收件箱那条**原生 HTTP**（core/NativeDirect，回放原生存下来的 GraphQL 模板）的响应形状和
 * 脚本读的是同一棵树，所以沿用同一个 inboxFromJson。会话详情走的是另一条路（REST
 * `/api/v1/direct_v2/threads/{id}/`），形状完全不同，映射见 threadFromJson。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { JsonRead } from '../core/JsonRead';
// 收件箱解析在 TaskPool 里做（见 workers/InboxParseTask），这里只按它回传的行建对象。
import { InboxParseResult, InboxRow, inboxUnreadCountOf } from '../workers/InboxParseModels';

const DOMAIN: number = 0xFF00;
const TAG: string = 'DirectMapper';

/** 一条私信会话（收件箱里的一行）。 */
export class DirectThread {
  /** thread_id：打开网页里的那条会话要用它。 */
  readonly id: string;
  /** thread_key：同一条会话的另一个标识（备份用，目前只记日志）。 */
  readonly key: string;
  /** 显示名：1:1 用对方的用户名，群聊用 thread_title。 */
  readonly title: string;
  readonly avatarUrl: string;
  readonly isGroup: boolean;
  /** 对方**名字**（ull_name；标题栏第一行用它，用户名留给第二行）。 */
  readonly unread: boolean;
  /**
   * 未读**条数**（列表里 "n 条新消息" 用；0 = 没有未读，界面上只显示最近一条内容）。
   *
   * 由 `last_seen_at`（我看到哪儿了）和最近几条消息的时间戳算出来，**封顶 4**：
   * 需求"一条显示消息内容，超过一条显示 n 条新消息，n 最大等于 4"。
   */
  readonly unreadCount: number;
  readonly muted: boolean;
  readonly pinned: boolean;
  /** 最近活动时间（毫秒）。 */
  readonly tsMs: number;
  /** 账号名（`username`，标题栏第二行用它；名字 `title` 是第一行）。 */
  readonly username: string;
  /** 最近一条消息的文字（没有文字时为空）。 */
  readonly text: string;
  /** 最近一条消息的类型（text / media / voice_media ...），文字为空时用它给个中文占位。 */
  readonly kind: string;

  constructor(id: string, key: string, title: string, avatarUrl: string, isGroup: boolean,
              unread: boolean, muted: boolean, pinned: boolean, tsMs: number,
              text: string, kind: string, username: string = '', unreadCount: number = 0) {
    this.id = id;
    this.key = key;
    this.title = title;
    this.avatarUrl = avatarUrl;
    this.isGroup = isGroup;
    this.unread = unread;
    this.unreadCount = unreadCount;
    this.muted = muted;
    this.pinned = pinned;
    this.tsMs = tsMs;
    this.text = text;
    this.kind = kind;
    this.username = username;
  }

  /** 打开这条会话的网页地址。 */
  threadUrl(): string {
    return `https://www.instagram.com/direct/t/${this.id}/`;
  }
}

/** 一页会话 + 游标。 */
export class DirectInboxPage {
  readonly threads: Array<DirectThread>;
  readonly endCursor: string;
  readonly hasMore: boolean;

  constructor(threads: Array<DirectThread>, endCursor: string, hasMore: boolean) {
    this.threads = threads;
    this.endCursor = endCursor;
    this.hasMore = hasMore;
  }
}

/**
 * 会话里的一条消息。
 *
 * 字段跟着 IG 的 `direct_v2` REST 形状走（`/api/v1/direct_v2/threads/{id}/` 的 `thread.items[]`）：
 * 每条有 `item_id` / `user_id`（谁发的）/ `timestamp`（微秒！）/ `item_type` / `text`。
 */
export class DirectMessage {
  readonly id: string;
  readonly userId: string;
  /** 是不是**我**发的（右侧气泡）。判据是 user_id == 自己，见 DirectMapper。 */
  readonly mine: boolean;
  readonly tsMs: number;
  readonly kind: string;
  readonly text: string;
  /**
   * 这条消息带的**图片**（可直接 `Image()` 的地址；纯文本消息给空串）。
   *
   * 从哪来：直接发的媒体（`media.image_versions2`）、转发的帖子（`media_share.…`）、
   * reel 分享、链接卡片（`link.link_context.link_image_url`）—— 依次找第一个图片候选
   * （见 DirectMapper.mediaUrlOf）。
   */
  readonly mediaUrl: string;
  /** 这条媒体是不是视频（缩略图上要盖一颗播放标记）。 */
  readonly isVideo: boolean;
  /**
   * 分享卡片指向的**帖子短码**（`media_share.code` / `clip.clip.code` / `reel_share.media.code`，
   * 或者从 XMA 的 `target_url` 里拆出来的 `/p/<code>/`、`/reel/<code>/`）。
   * 空串 = 这条消息没有可打开的帖子（纯文本 / 贴纸 / 语音…）。
   */
  readonly shareCode: string;
  /** 分享卡片的外部链接（链接卡片 `link_context.link_url`、XMA 的 `target_url`）。空串 = 没有。 */
  readonly shareUrl: string;
  /** 分享的是不是 Reel（决定用 /reel/ 还是 /p/ 打开）。 */
  readonly shareIsVideo: boolean;
  /**
   * 分享卡片的**形态**：`post`（图文帖子）/ `video`（视频/Reel）/ `link`（外链卡片）/ 空串（不是分享）。
   *
   * 界面上两种卡片长得完全不同（见 components/DirectThreadPage 的 shareCard）：
   *   · 帖子：宽约 2/3 屏，封面在上，底部一块沉浸光感容器放作者行 + 两行正文；
   *   · 视频：宽约 1/3 屏，圆角封面 + 左上角作者栏（带光感底）+ 居中暂停图标。
   */
  readonly shareKind: string;
  /** 卡片封面（XMA 的 preview_url / media_share 的封面；空 = 没有封面）。 */
  readonly shareCover: string;
  /** 卡片的作者名（分享内容的主人，不是发消息的人）。 */
  readonly shareUser: string;
  /** 作者头像（没有就空串，界面上退回占位圆）。 */
  readonly shareAvatar: string;
  /** 卡片正文（帖子 caption / XMA 的 caption_body_text；可能为空）。 */
  readonly shareCaption: string;

  constructor(id: string, userId: string, mine: boolean, tsMs: number, kind: string,
              text: string, mediaUrl: string = '', isVideo: boolean = false,
              shareCode: string = '', shareUrl: string = '', shareIsVideo: boolean = false,
              shareKind: string = '', shareCover: string = '', shareUser: string = '',
              shareAvatar: string = '', shareCaption: string = '') {
    this.id = id;
    this.userId = userId;
    this.mine = mine;
    this.tsMs = tsMs;
    this.kind = kind;
    this.text = text;
    this.mediaUrl = mediaUrl;
    this.isVideo = isVideo;
    this.shareCode = shareCode;
    this.shareUrl = shareUrl;
    this.shareIsVideo = shareIsVideo;
    this.shareKind = shareKind;
    this.shareCover = shareCover;
    this.shareUser = shareUser;
    this.shareAvatar = shareAvatar;
    this.shareCaption = shareCaption;
  }
}

/** 分享卡片要的字段（由 DirectMapper.shareCardOf 从载荷里抠出来）。 */
export class ShareCard {
  /** `post` / `video` / `link` / 空串（不是分享）。 */
  kind: string = '';
  cover: string = '';
  user: string = '';
  avatar: string = '';
  caption: string = '';
  target: string = '';
  video: boolean = false;
}

/** 一条会话的消息页（照 REST 那条的形状给）。 */
export class DirectThreadView {
  readonly id: string;
  readonly title: string;
  /** 参与者（自己以外的那几个）：用户名 + 头像，标题栏/气泡上要用。 */
  readonly withUsername: string;
  readonly withAvatar: string;
  readonly withId: string;
  /** 群聊（标题栏只显示群名，不显示"用户名 + id"那一列）。 */
  readonly isGroup: boolean;
  /** 对方的**名字**（full_name）：标题栏第一行用它，用户名留给第二行。 */
  readonly withFullName: string;
  /** 消息按**时间正序**（老的在前，界面上往下排）。 */
  readonly messages: Array<DirectMessage>;
  /** 还有更老的消息（`has_older`）+ 取更老那批的游标（`oldest_cursor`）。 */
  readonly hasOlder: boolean;
  readonly oldestCursor: string;

  constructor(id: string, title: string, withUsername: string, withAvatar: string, withId: string,
              messages: Array<DirectMessage>, hasOlder: boolean, oldestCursor: string,
              isGroup: boolean = false, withFullName: string = '') {
    this.withFullName = withFullName;
    this.id = id;
    this.title = title;
    this.withUsername = withUsername;
    this.withAvatar = withAvatar;
    this.withId = withId;
    this.isGroup = isGroup;
    this.messages = messages;
    this.hasOlder = hasOlder;
    this.oldestCursor = oldestCursor;
  }
}

/** 脚本回传的一条（字段名要短，见 WebScripts 里的说明）。 */
interface DirectThreadDto {
  id?: string;
  key?: string;
  title?: string;
  avatar?: string;
  group?: boolean;
  unread?: boolean;
  muted?: boolean;
  pinned?: boolean;
  ts?: number;
  text?: string;
  kind?: string;
  items?: number;
}

/** 脚本回传的整包。 */
interface DirectInboxDto {
  state?: string;
  items?: Array<DirectThreadDto>;
  cursor?: string;
  more?: boolean;
  count?: number;
}

/** small JSON → 模型。state 不是 ok 就返回 null，由视图模型决定怎么提示。 */
export class DirectMapper {
  static inboxFromJson(raw: string): DirectInboxPage | null {
    /*
     * **必须用 parseWithBigIds**（不能用下面那种 `JSON.parse(raw) as DirectInboxDto` 的 DTO 直转）：
     * `id` 在网页那棵树里有时是**数字**，19 位的 thread_id 一过 double 就被舍入，
     * 再转成字符串就成了 `340282366841710301281158034919` 这种 30 位错 id ——
     * 点开会话请求 `/api/v1/direct_v2/threads/<错 id>` 被 IG 当未登录回 404
     * （用户报的"打开会话显示 404"，见 JsonRead.parseWithBigIds 的说明）。
     * 这里先把长数字补引号，再按字段名读，id 就原样拿到精确值。
     */
    const root: Record<string, Object> = JsonRead.parseWithBigIds(raw);
    if (JsonRead.strOf(root, 'state') !== 'ok') {
      return null;
    }
    const items: Array<Object> = JsonRead.arrayOf(root, 'items');
    const threads: Array<DirectThread> = [];
    for (let index: number = 0; index < items.length; index++) {
      const item: Record<string, Object> | null = JsonRead.asRecord(items[index]);
      if (item === null) {
        continue;
      }
      const id: string = JsonRead.strOf(item, 'id');
      if (id.length === 0) {
        continue;
      }
      threads.push(new DirectThread(
        id,
        JsonRead.strOf(item, 'key'),
        JsonRead.strOf(item, 'title'),
        JsonRead.strOf(item, 'avatar'),
        JsonRead.boolOf(item, 'group'),
        JsonRead.boolOf(item, 'unread'),
        JsonRead.boolOf(item, 'muted'),
        JsonRead.boolOf(item, 'pinned'),
        JsonRead.numOf(item, 'ts'),
        JsonRead.strOf(item, 'text'),
        JsonRead.strOf(item, 'kind')));
    }
    return new DirectInboxPage(threads, JsonRead.strOf(root, 'cursor'), JsonRead.boolOf(root, 'more'));
  }

  /**
   * `/api/v1/direct_v2/inbox/` 的响应 → 一页会话（**翻页**用，见 NativeDirect.inboxRest）。
   *
   * 为什么不复用上面的 `inboxFromJson`：那条读的是网页 GraphQL 的形状
   * （`data.*.threads_by_folder.edges[]`），REST 这条是 `{inbox:{threads:[…],next_max_id}}`，
   * 字段也全是另一套（`items` 而不是 `slide_messages`、时间戳是微秒、游标叫 `next_max_id`）。
   */
  /**
   * **GraphQL** 版的会话响应 → 一条会话（"抓模板 + 原生 HTTP 回放"那条路用）。
   *
   * 为什么不复用 `threadFromJson`：那条读的是 REST 的平面形状（`{status,thread:{…}}`），
   * 而 GraphQL 是 Relay 树（`data.*.thread.items.edges[].node{}`），键名与层级都不同。
   * 所以这里**按结构找**（和 NativeStories 找托盘数组同一招）：
   *   · 消息数组 = 数组元素带 `timestamp` 或 `item_id` 的那个；
   *   · 参与者数组 = 数组元素带 `username` 的那个。
   * 找到之后就沿用 REST 那条一模一样的字段读法（`mediaUrlOf` / `hasVideoMedia` / 微秒→毫秒），
   * 保证两条路出来的界面完全一致。
   */
  static threadFromGraphql(raw: string, ownId: string): DirectThreadView | null {
    const root: Record<string, Object> = JsonRead.parseWithBigIds(raw);
    if (Object.keys(root).length === 0) {
      hilog.warn(DOMAIN, TAG, 'threadFromGraphql: unparsable len=%{public}d head=%{public}s',
        raw.length, raw.substring(0, 120));
      return null;
    }
    /*
     * 判据要**连 `node` 一起看**：Relay 的连接是 `edges:[{cursor,node:{…}}]`，数组元素本身
     * （那条边）没有 `item_id`/`timestamp`，只有它包着的 `node` 有 —— 只看元素会一条都找不到
     * （真机上就是这么失败的：87KB 的会话响应，解析器却"没找到消息数组"）。
     *
     * 而且 IGD 那条查询的字段名是 `timestamp_ms` / `message_id` / `content_type`，
     * 不是 REST 的 `timestamp` / `item_id` / `item_type` —— 三种都要认（见下面读字段那段）。
     */
    const items: Array<Object> | null = DirectMapper.findArrayBy(root, 0,
      (one: Record<string, Object>): boolean => {
        const inner: Record<string, Object> | null = JsonRead.recordOf(one, 'node');
        const at: Record<string, Object> = inner !== null ? inner : one;
        return JsonRead.has(at, 'timestamp') || JsonRead.has(at, 'item_id')
          || JsonRead.has(at, 'timestamp_ms') || JsonRead.has(at, 'message_id')
          || JsonRead.has(at, 'content_type');
      });
    if (items === null) {
      hilog.warn(DOMAIN, TAG, 'no messages array: %{public}s', DirectMapper.arrays(raw));
      return null;
    }
    /*
     * 诊断：**原始响应里到底给了几条**。
     *
     * `edges=4` → 问题在请求（服务端就只回了这一点）；`edges=20 但下面 msgs=4` → 问题在解析。
     * 会话"只显示 4~5 条"就是这个二分法要先分清的事。
     */
    hilog.info(DOMAIN, TAG, 'graphql raw edges=%{public}d', items.length);
    const users: Array<Object> | null = DirectMapper.findArrayBy(root, 0,
      (one: Record<string, Object>): boolean => {
        const inner: Record<string, Object> | null = JsonRead.recordOf(one, 'node');
        const at: Record<string, Object> = inner !== null ? inner : one;
        return JsonRead.strOf(at, 'username').length > 0;
      });
    const userList: Array<Object> = users === null ? [] : users;
    // 自己：优先响应里的 viewer_id，其次本地存的自己 id。
    let me: string = ownId;
    const viewerKeys: Array<string> = ['viewer_id', 'viewerId'];
    for (let at: number = 0; at < viewerKeys.length && me === ownId; at++) {
      const found: string = DirectMapper.findString(root, 0, viewerKeys[at]);
      if (found.length > 0) {
        me = found;
      }
    }
    /*
     * **自己的 id 还要一份 "fbid 形态"**。
     *
     * 真机实测（自检日志）：`viewer_id` 是 11 位那种（`12345678901`），而消息里的
     * `sender_fbid` 是 17 位那种（`12345678901234567`）—— 拿它对 `viewer_id` 永远不相等，
     * 于是**自己发的消息也会被画成对方发的**（全排到左边）。
     * 会话节点里 `viewer.interop_messaging_user_fbid` 正是本人的 fbid 形态，用它。
     */
    const viewerFbid: string = DirectMapper.findString(root, 0, 'interop_messaging_user_fbid');
    if (viewerFbid.length > 0) {
      me = viewerFbid;
    }
    let withUsername: string = '';
    let withAvatar: string = '';
    let withId: string = '';
    let withFullName: string = '';
    for (let index: number = 0; index < userList.length; index++) {
      const raw: Record<string, Object> | null = JsonRead.asRecord(userList[index]);
      if (raw === null) {
        continue;
      }
      // 用户数组也可能是边（元素包着 node），脱一层再读。
      const wrapped: Record<string, Object> | null = JsonRead.recordOf(raw, 'node');
      const user: Record<string, Object> = wrapped !== null ? wrapped : raw;
      const pk: string = JsonRead.strOf(user, 'pk');
      if (me.length > 0 && pk === me) {
        continue;
      }
      const name: string = JsonRead.strOf(user, 'username');
      const pic: string = DirectMapper.pictureOf(user);
      if (withUsername.length === 0 && name.length > 0) {
        withUsername = name;
      }
      if (withFullName.length === 0) {
        withFullName = JsonRead.strOf(user, 'full_name');
      }
      if (withId.length === 0) {
        withId = pk;
      }
      if (pic.length > 0) {
        withId = pk;
        withUsername = name;
        withAvatar = pic;
        break;
      }
    }
    const messages: Array<DirectMessage> = [];
    const senders: Array<string> = [];
    for (let index: number = 0; index < items.length; index++) {
      const node: Record<string, Object> | null = JsonRead.asRecord(items[index]);
      if (node === null) {
        continue;
      }
      // Relay 的边包一层 node，别的形状可能直接是消息本体：两种都认。
      const inner: Record<string, Object> | null = JsonRead.recordOf(node, 'node');
      const item: Record<string, Object> = inner !== null ? inner : node;
      /*
       * **IGD 那条查询（IGDThreadDetailQuery）的字段名和 REST 那条完全不同**（真机 shape 摘要
       * 里抄下来的）：文字在 **`text_body`**（不是 `content`，`content` 对图片消息是**对象**）、
       * 类型在 `content_type`、发送者在 `sender_fbid`、时间在 `timestamp_ms`（毫秒）、
       * 消息 id 在 `message_id`/`id`。这里几种命名都认，两条路（REST / GraphQL）共用一段映射。
       */
      let kind: string = JsonRead.strOf(item, 'item_type');
      if (kind.length === 0) {
        kind = JsonRead.strOf(item, 'content_type');
      }
      let text: string = JsonRead.strOf(item, 'text');
      if (text.length === 0) {
        text = JsonRead.strOf(item, 'text_body');
      }
      let mediaUrl: string = DirectMapper.mediaUrlOf(item);
      // `content` 两种形态都见过：**对象**（图片/分享消息，里面有媒体地址）或一段 JSON 字符串。
      const packedObj: Record<string, Object> | null = JsonRead.recordOf(item, 'content');
      if (packedObj !== null) {
        if (mediaUrl.length === 0) {
          mediaUrl = DirectMapper.packedUrl(packedObj);
        }
        if (text.length === 0) {
          text = DirectMapper.findString(packedObj, 0, 'text');
        }
        if (kind.length === 0) {
          kind = DirectMapper.findString(packedObj, 0, 'content_type');
        }
      } else {
        const packedRaw: string = JsonRead.strOf(item, 'content');
        if (packedRaw.length > 0 && packedRaw.charAt(0) === '{') {
          const packed: Record<string, Object> = JsonRead.parse(packedRaw);
          if (Object.keys(packed).length > 0) {
            if (mediaUrl.length === 0) {
              mediaUrl = DirectMapper.packedUrl(packed);
            }
            if (text.length === 0) {
              text = DirectMapper.findString(packed, 0, 'text');
            }
            if (kind.length === 0) {
              kind = DirectMapper.findString(packed, 0, 'content_type');
            }
          }
        } else if (text.length === 0 && packedRaw.length > 0) {
          // 纯文本消息：`content` 就是那句话。
          text = packedRaw;
        }
      }
      if (text.length === 0 && mediaUrl.length === 0) {
        continue;
      }
      let userId: string = JsonRead.strOf(item, 'user_id');
      if (userId.length === 0) {
        userId = JsonRead.strOf(item, 'sender_fbid');
      }
      if (userId.length === 0) {
        // 有的形状把发送者包成一个对象（诊断日志里见过 `sender`）。
        const sender: Record<string, Object> | null = JsonRead.recordOf(item, 'sender');
        if (sender !== null) {
          userId = JsonRead.strOf(sender, 'pk');
          if (userId.length === 0) {
            userId = JsonRead.strOf(sender, 'id');
          }
        }
      }
      if (senders.indexOf(userId) < 0) {
        senders.push(userId);
      }
      let stamp: number = JsonRead.numOf(item, 'timestamp');
      if (stamp <= 0) {
        stamp = JsonRead.numOf(item, 'timestamp_ms');
      }
      // GraphQL 这条给的是**微秒**（> 1e14）；已经是毫秒（~1e12）的就别动。
      const tsMs: number = stamp > 1e14 ? Math.round(stamp / 1000) : Math.round(stamp);
      let id: string = JsonRead.strOf(item, 'item_id');
      if (id.length === 0) {
        id = JsonRead.strOf(item, 'message_id');
      }
      if (id.length === 0) {
        id = JsonRead.strOf(item, 'id');
      }
      // GraphQL 这条同理（见 threadFromJson 里的说明）：分享卡片的 share* 字段一个都不能少。
      const gqlCard: ShareCard = DirectMapper.shareCardOf(item);
      messages.push(new DirectMessage(id, userId, me.length > 0 && userId === me, tsMs, kind,
        text, mediaUrl, DirectMapper.hasVideoMedia(item), DirectMapper.shareCodeOf(item),
        DirectMapper.shareUrlOf(item), DirectMapper.shareIsVideoOf(item),
        gqlCard.kind, gqlCard.cover, gqlCard.user, gqlCard.avatar, gqlCard.caption));
    }
    if (messages.length === 0) {
      // 找到数组了但一条都没能用 —— 把第一条的原样键名和几个字段打出来（诊断用）。
      let keys: string = '-';
      let content: string = '-';
      let type: string = '-';
      if (items.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(items[0]);
        if (first !== null) {
          const inner: Record<string, Object> | null = JsonRead.recordOf(first, 'node');
          const at: Record<string, Object> = inner !== null ? inner : first;
          keys = Object.keys(at).slice(0, 22).join(',');
          content = JsonRead.strOf(at, 'content').substring(0, 100);
          type = JsonRead.strOf(at, 'content_type');
        }
      }
      hilog.warn(DOMAIN, TAG, 'items n=%{public}d no usable; keys=%{public}s type=%{public}s content=%{public}s',
        items.length, keys, type, content);
      return null;
    }
    /*
     * 诊断：**"我发的"是靠 `sender_fbid === viewer_id` 判的**，而这两个 id 在 IGD 里不一定是
     * 同一种形式（一个是 pk、一个是 fbid 的情况见过）。打一行就能看出气泡会不会全排到左边。
     */
    hilog.info(DOMAIN, TAG, 'threadFromGraphql me=%{public}s msgs=%{public}d senders=%{public}s',
      me, messages.length, senders.slice(0, 4).join(','));
    // GraphQL 是"新在前"，界面要的是老的在前（和 REST 那条一致）。
    const ordered: Array<DirectMessage> = [];
    for (let index: number = messages.length - 1; index >= 0; index--) {
      ordered.push(messages[index]);
    }
    /*
     * 翻页游标：IGD 的变量叫 `min_uq_seq_id`（"比这个序号更老的"），所以**首选最老那条消息的 id**
     * （测试会话里消息 id 就是那个序号）；拿不到才退回 page_info 的游标（那串 132 字符的
     * end_cursor 喂给 min_uq_seq_id 不一定认）。
     */
    let cursor: string = '';
    /*
     * **优先取最老那条消息的 `id`**（= IG 的 uq_seq_id）：翻页变量 `min_uq_seq_id` 吃的是
     * "比这个序号更老"，而 `page_info.end_cursor` 是一串 132 字符的不透明游标
     * （实测 `AQHTYxzHCg-e-2IQLTGdN8n5tIphsRiZ…`），喂进去服务端直接忽略、把同一页又回一次 ——
     * 真机日志就是 `loadOlder: +0`。
     * 注意要从**原始节点**读 `id`（不是 DirectMessage.id：那个优先取的是 `message_id`，
     * 往往是 `mid.$…` 这种字符串，不是序号）。
     */
    if (items.length > 0) {
      const oldestEdge: Record<string, Object> | null = JsonRead.asRecord(items[items.length - 1]);
      if (oldestEdge !== null) {
        const inner: Record<string, Object> | null = JsonRead.recordOf(oldestEdge, 'node');
        const oldest: Record<string, Object> = inner !== null ? inner : oldestEdge;
        /*
         * **`offline_threading_id` 才是那个"序号"**：它是按时间递增的大整数（19 位），
         * 语义上正好对应 `min_uq_seq_id`（"比这个序号更老的"）。
         * 而 `id` / `message_id` 在这条响应里是 `mid.$…` 这种字符串（喂进去被 IG 忽略），
         * `page_info.end_cursor` 是 132 字符的不透明游标（同样被忽略）。
         */
        const seq: string = JsonRead.strOf(oldest, 'offline_threading_id');
        if (seq.length > 0) {
          cursor = seq;
        } else {
          const mid: string = JsonRead.strOf(oldest, 'id');
          if (mid.length > 0) {
            cursor = mid;
          }
        }
      }
    }
    if (cursor.length === 0 && ordered.length > 0 && /^\d{10,}$/.test(ordered[0].id)) {
      cursor = ordered[0].id;
    }
    if (cursor.length === 0) {
      cursor = DirectMapper.findString(root, 0, 'oldest_cursor');
    }
    if (cursor.length === 0) {
      cursor = DirectMapper.findString(root, 0, 'end_cursor');
    }
    const hasOlder: boolean = DirectMapper.findBool(root, 0, 'has_older')
      || DirectMapper.findBool(root, 0, 'has_next_page')
      || DirectMapper.findBool(root, 0, 'has_previous_page')
      /*
       * **只要拿到游标就允许往前翻**。
       *
       * IGD 那条查询的 `page_info` 常常两个 has_* 都是 false，而且一页并不总是满 20 条
       * （真机上见过 17/18/19 条，但确实还有更老的）—— 按"满一页"判会让界面**永远不触发加载**
       * （用户报的"只能下滑、不触发加载"）。
       * 代价可控：翻页真没多出消息时，DirectThreadViewModel.loadOlder 会把 hasOlder 置回 false，
       * 不会无限重复同一页（那条去重+停止的逻辑就是为此加的）。
       */
      || cursor.length > 0;
    let threadId: string = DirectMapper.findString(root, 0, 'thread_id');
    if (threadId.length === 0) {
      threadId = DirectMapper.findString(root, 0, 'thread_fbid');
    }
    const title: string = withFullName.length > 0 ? withFullName : withUsername;
    return new DirectThreadView(threadId, title, withUsername, withAvatar, withId, ordered,
      hasOlder, cursor, userList.length > 2, withFullName);
  }

  /**
   * **结构摘要**（诊断用）：把响应的形状按路径列出来（数组标出长度、对象列出前几个键名）。
   *
   * 写解析器时唯一的依据就是它 —— 真机上 87KB 的会话响应，光看前 200 字节根本看不出消息
   * 数组挂在哪一层、元素长什么样。上限 80 行，避免把日志刷爆。
   */
  static describe(raw: string): string {
    const root: Record<string, Object> = JsonRead.parseWithBigIds(raw);
    const lines: Array<string> = [];
    DirectMapper.walkShape(root, '', 0, lines);
    return lines.join('\n');
  }

  private static walkShape(host: Record<string, Object>, path: string, depth: number,
                           out: Array<string>): void {
    if (depth > 5 || out.length > 80) {
      return;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const at: string = path.length > 0 ? `${path}.${key}` : key;
      const value: Object = host[key];
      if (Array.isArray(value)) {
        const list: Array<Object> = value as Array<Object>;
        out.push(`${at}[] n=${list.length}`);
        if (list.length > 0 && out.length <= 80) {
          const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
          if (first !== null) {
            DirectMapper.walkShape(first, `${at}[0]`, depth + 1, out);
          }
        }
      } else if (value !== null && typeof value === 'object') {
        const child: Record<string, Object> | null = JsonRead.asRecord(value);
        if (child !== null) {
          out.push(`${at} {${Object.keys(child).slice(0, 14).join(',')}}`);
          DirectMapper.walkShape(child, at, depth + 1, out);
        }
      }
    }
  }

  /**
   * 从一段**打包成 JSON 的 `content`** 里抠出媒体地址（图片/视频消息就是这么给的）。
   *
   * 字段名按见过的几种依次试；都没有就去扫第一个 http(s) 开头的字符串值（够用了 ——
   * 这条只影响气泡里画不画图，抠不到也只是没有图）。
   */
  private static packedUrl(packed: Record<string, Object>): string {
    const keys: Array<string> = ['media_url', 'url', 'video_url', 'preview_url', 'image_url'];
    for (let index: number = 0; index < keys.length; index++) {
      const url: string = DirectMapper.findString(packed, 0, keys[index]);
      if (url.length > 0) {
        return url;
      }
    }
    return '';
  }

  /**
   * **数组清单**（诊断用）：把响应里所有数组的路径和长度列出来（`a.b[] n=3` 一行一个）。
   *
   * 消息数组找不到时，这一行就能看出它到底挂在哪儿、叫什么名字。
   */
  static arrays(raw: string): string {
    const root: Record<string, Object> = JsonRead.parseWithBigIds(raw);
    const out: Array<string> = [];
    DirectMapper.walkArrays(root, '', 0, out);
    return out.length > 0 ? out.join(' ') : '(none)';
  }

  private static walkArrays(host: Record<string, Object>, path: string, depth: number,
                             out: Array<string>): void {
    if (depth > 6 || out.length > 30) {
      return;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const at: string = path.length > 0 ? `${path}.${key}` : key;
      const value: Object = host[key];
      if (Array.isArray(value)) {
        const list: Array<Object> = value as Array<Object>;
        let firstKeys: string = '';
        if (list.length > 0) {
          const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
          if (first !== null) {
            firstKeys = `[0]{${Object.keys(first).slice(0, 8).join(',')}}`;
          }
        }
        out.push(`${at}[] n=${list.length}${firstKeys}`);
      } else if (value !== null && typeof value === 'object') {
        const child: Record<string, Object> | null = JsonRead.asRecord(value);
        if (child !== null) {
          DirectMapper.walkArrays(child, at, depth + 1, out);
        }
      }
    }
  }

  /** 在对象树里找**第一个满足判据的数组**（广度优先，深度封顶）。 */
  private static findArrayBy(host: Record<string, Object>, depth: number,
                             test: (one: Record<string, Object>) => boolean): Array<Object> | null {
    if (depth > 6) {
      return null;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null && test(first)) {
          return list;
        }
      }
    }
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        const hit: Array<Object> | null = DirectMapper.findArrayBy(child, depth + 1, test);
        if (hit !== null) {
          return hit;
        }
      }
    }
    return null;
  }

  /** 在对象树里找某个键的字符串值（广度优先）。 */
  private static findString(host: Record<string, Object>, depth: number, key: string): string {
    if (depth > 6) {
      return '';
    }
    const value: string = JsonRead.strOf(host, key);
    if (value.length > 0) {
      return value;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        const hit: string = DirectMapper.findString(child, depth + 1, key);
        if (hit.length > 0) {
          return hit;
        }
      }
    }
    return '';
  }

  /** 在对象树里找某个布尔键（广度优先）。 */
  private static findBool(host: Record<string, Object>, depth: number, key: string): boolean {
    if (depth > 6) {
      return false;
    }
    if (JsonRead.has(host, key)) {
      return JsonRead.boolOf(host, key);
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null && DirectMapper.findBool(child, depth + 1, key)) {
        return true;
      }
    }
    return false;
  }

  /**
   * **TaskPool 解析结果 → 会话对象**（见 workers/InboxParseTask）。
   *
   * 解析（正则 + JSON.parse + 取字段）已经在别的线程做完，这里只把纯数据拼成 `DirectThread` ——
   * 对象构建在主线程做是有意的：`DirectThread` 带方法（`threadUrl()`），TaskPool 传对象时不带方法，
   * 所以不能让它跨线程。
   */
  static inboxFromParsed(parsed: InboxParseResult): DirectInboxPage | null {
    if (parsed.error.length > 0) {
      return null;
    }
    const threads: Array<DirectThread> = [];
    for (let index: number = 0; index < parsed.rows.length; index++) {
      const row: InboxRow = parsed.rows[index];
      if (row.id.length === 0) {
        continue;
      }
      threads.push(new DirectThread(row.id, row.key, row.title, row.avatar, row.isGroup,
        row.unread, row.muted, row.pinned, row.tsMs, row.text, row.kind, row.username,
        row.unreadCount));
    }
    return new DirectInboxPage(threads, parsed.cursor, parsed.hasOlder);
  }

  static inboxFromRestJson(raw: string): DirectInboxPage | null {
    /*
     * 用 `parseWithBigIds`：REST 里 `thread_id` 是 19~20 位数字，普通 JSON.parse 先把它舍入成
     * double，再转字符串就成了一串错 id —— 点开会话请求 `/threads/<错 id>` 直接 404
     * （用户报的"打开会话显示 404"，见 JsonRead.parseWithBigIds 的说明）。
     */
    const root: Record<string, Object> = JsonRead.parseWithBigIds(raw);
    if (Object.keys(root).length === 0) {
      return null;
    }
    const box: Record<string, Object> | null = JsonRead.recordOf(root, 'inbox');
    if (box === null) {
      return null;
    }
    const list: Array<Object> = JsonRead.arrayOf(box, 'threads');
    const threads: Array<DirectThread> = [];
    for (let index: number = 0; index < list.length; index++) {
      const th: Record<string, Object> | null = JsonRead.asRecord(list[index]);
      if (th === null) {
        continue;
      }
      const id: string = JsonRead.strOf(th, 'thread_id');
      if (id.length === 0) {
        continue;
      }
      const users: Array<Object> = JsonRead.arrayOf(th, 'users');
      let username: string = '';
      let fullName: string = '';
      let avatar: string = '';
      for (let at: number = 0; at < users.length; at++) {
        const u: Record<string, Object> | null = JsonRead.asRecord(users[at]);
        if (u === null) {
          continue;
        }
        const pic: string = DirectMapper.pictureOf(u);
        if (username.length === 0) {
          username = JsonRead.strOf(u, 'username');
        }
        if (fullName.length === 0) {
          fullName = JsonRead.strOf(u, 'full_name');
        }
        if (avatar.length === 0 && pic.length > 0) {
          avatar = pic;
        }
      }
      const groupTitle: string = JsonRead.strOf(th, 'thread_title');
      const isGroup: boolean = JsonRead.boolOf(th, 'is_group');
      let title: string = isGroup
        ? (groupTitle.length > 0 ? groupTitle : (fullName.length > 0 ? fullName : username))
        : (fullName.length > 0 ? fullName : (username.length > 0 ? username : groupTitle));
      if (title === 'Empty' && username.length > 0) {
        title = username;
      }
      // 最近一条消息的文字（REST 的 items 是"新在前"）。
      const items: Array<Object> = JsonRead.arrayOf(th, 'items');
      let text: string = '';
      let kind: string = '';
      if (items.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(items[0]);
        if (first !== null) {
          text = JsonRead.strOf(first, 'text');
          kind = JsonRead.strOf(first, 'item_type');
        }
      }
      // `last_activity_at` 是**微秒**（GraphQL 那条给的是毫秒）。
      const micros: number = JsonRead.numOf(th, 'last_activity_at');
      const ts: number = micros > 0 ? Math.round(micros / 1000) : 0;
      const me: string = JsonRead.strOf(th, 'viewer_id');
      /*
       * **"未读"的判据**（用户报的"全部已读私信都变成未读了"）：
       *
       * 以前只看 `read_state === '0'` —— 而这个字段在真机上是 **0 = 已读**（和直觉相反），
       * 于是所有读过的会话都被画成未读（红点/粗体）。
       * 现在优先用**消息时间戳**算（`last_seen_at` 与 items 比，见 unreadCountOf）：
       * 算得出来就以它为准（-1 = 算不出来）；算不出来才退回 `read_state`，
       * 并且按 **1 = 未读** 来解释。
       */
      const count: number = DirectMapper.unreadCountOf(th, me, items);
      const readState: string = JsonRead.strOf(th, 'read_state').toLowerCase();
      const unread: boolean = count >= 0
        ? count > 0
        : (readState === '1' || readState === 'true' || readState === 'unread');
      threads.push(new DirectThread(id, '', title, isGroup ? '' : avatar, isGroup,
        unread, JsonRead.boolOf(th, 'muted'),
        JsonRead.boolOf(th, 'is_pin'), ts, text, kind, username,
        count > 0 ? count : 0));
    }
    const next: string = JsonRead.strOf(box, 'next_max_id');
    const older: boolean = JsonRead.boolOf(box, 'has_older') || next.length > 0;
    return new DirectInboxPage(threads, next, older);
  }

  /**
   * `/api/v1/direct_v2/threads/{id}/` 的响应 → 一条会话（原生 HTTP 那条路用）。
   *
   * 形状（REST 那条，和 GraphQL 那套完全不同）：
   *   `{status:"ok", thread:{thread_id, thread_title, users:[{pk,username,profile_pic_url}],
   *     items:[{item_id,user_id,timestamp,item_type,text}], has_older, oldest_cursor, viewer_id}}`
   *
   * 三个真机上必须处理的点：
   *   1. `timestamp` 是**微秒**（网页那边给的是毫秒），要 /1000 —— 不处理就会显示成 5 万年后的日期；
   *   2. `items` 是**新在前**的老序（和列表相反），这里翻正序给界面；
   *   3. 判断"是不是我发的"要用 `viewer_id`（响应里就有）；拿不到才退回本地存的自己 id。
   */
  /**
   * 这一条收件箱会话里"我还没看的、别人发来的"消息有几条（**封顶 4**）。
   *
   * **实现只有一份**：`workers/InboxParseModels.inboxUnreadCountOf`。
   * 这里只做转发 —— 收件箱的解析平时走 TaskPool（那边用同一份实现），
   * 线程池不可用时才退回主线程（`inboxFromRestJson` → 本方法）。
   * 以前两边各写一份，判据在"items 为空 / 没有 last_seen_at / 微秒比较"三处不一致，
   * 同一个响应会算出不同的未读数（用户看到的就是"加载更多前后红点跳变"）。
   */
  private static unreadCountOf(th: Record<string, Object>, me: string,
                               items: Array<Object>): number {
    return inboxUnreadCountOf(th, me, items);
  }

  static threadFromJson(raw: string, ownId: string): DirectThreadView | null {
    // 同 inboxFromRestJson：`thread_id` / `pk` 是 19~20 位，必须走 parseWithBigIds 才不丢精度。
    const root: Record<string, Object> = JsonRead.parseWithBigIds(raw);
    if (Object.keys(root).length === 0) {
      return null;
    }
    const status: string = JsonRead.strOf(root, 'status');
    if (status.length > 0 && status !== 'ok') {
      return null;
    }
    const thread: Record<string, Object> | null = JsonRead.recordOf(root, 'thread');
    if (thread === null) {
      return null;
    }
    const id: string = JsonRead.strOf(thread, 'thread_id');
    if (id.length === 0) {
      return null;
    }
    const viewerId: string = JsonRead.strOf(thread, 'viewer_id');
    const me: string = viewerId.length > 0 ? viewerId : ownId;
    // 参与者：自己以外的那几个（1:1 就是对方；群聊取第一个当标题里的名字）。
    const users: Array<Object> = JsonRead.arrayOf(thread, 'users');
    let withUsername: string = '';
    let withAvatar: string = '';
    let withId: string = '';
    let fallbackName: string = '';
    let fullName: string = '';
    let fallbackId: string = '';
    for (let index: number = 0; index < users.length; index++) {
      const user: Record<string, Object> | null = JsonRead.asRecord(users[index]);
      if (user === null) {
        continue;
      }
      const pk: string = JsonRead.strOf(user, 'pk');
      if (me.length > 0 && pk === me) {
        continue;
      }
      const name: string = JsonRead.strOf(user, 'username');
      const pic: string = DirectMapper.pictureOf(user);
      /*
       * 用户名 / 名字**独立于头像**收集（这一条是"标题栏第二行退成数字 id"的修复）：
       * 原来只把 username/full_name 放在"挑中头像"的分支里赋值，挑中的那个用户对象恰好
       * 没有 profile_pic_url 时，标题栏就拿不到用户名、一路退到数字 id（真机现象：
       * 第一行 Alice、第二行一串数字）。名字/用户名跟头像是两件事，各收各的。
       */
      if (name.length > 0 && withUsername.length === 0) {
        withUsername = name;
      }
      const fn: string = JsonRead.strOf(user, 'full_name');
      if (fn.length > 0 && fullName.length === 0) {
        fullName = fn;
      }
      if (fallbackId.length === 0) {
        fallbackId = pk;
        fallbackName = name;
      }
      /*
       * 取**第一个真有头像**的那个当"对方"：真机上 `users[]` 里偶尔有几个条目没有
       * `profile_pic_url`（或只给了 `hd_profile_pic_url_info`），按位置盲取第一个就会
       * 得到"有名字没头像"的标题栏（用户看到的是一块空白头像）。
       */
      if (pic.length > 0) {
        withId = pk;
        withUsername = name;
        fullName = JsonRead.strOf(user, 'full_name');
        withAvatar = pic;
        break;
      }
    }
    if (withId.length === 0) {
      withId = fallbackId;
      withUsername = fallbackName;
    }
    let title: string = JsonRead.strOf(thread, 'thread_title');
    if (title.length === 0 || title === 'Empty') {
      title = withUsername;
    }
    const items: Array<Object> = JsonRead.arrayOf(thread, 'items');
    const messages: Array<DirectMessage> = [];
    // 这一页解析出几张分享卡片（写进 hilog：下次"还是不画卡片"时，一眼看出是解析没认出还是界面没画）。
    let shareCards: number = 0;
    for (let index: number = 0; index < items.length; index++) {
      const item: Record<string, Object> | null = JsonRead.asRecord(items[index]);
      if (item === null) {
        continue;
      }
      const kind: string = JsonRead.strOf(item, 'item_type');
      const text: string = JsonRead.strOf(item, 'text');
      const mediaUrl: string = DirectMapper.mediaUrlOf(item);
      const isVideo: boolean = DirectMapper.hasVideoMedia(item);
      /*
       * **分享卡片字段必须在这里补齐**（用户报："根本没画卡片，还是老样子"）。
       *
       * 这一版之前只有 `messageFromItem`（实时补丁那条）带 share* 字段，而**正常打开会话走的是
       * 本函数**（workers/ThreadParseTask → DirectMapper.threadFromJson）—— 于是 `shareKind` 永远是空串，
       * 界面上 `bubbleContent` 的 `shareKind.length > 0` 分支一次都进不去，画出来的仍是老封面/灰块。
       */
      const card: ShareCard = DirectMapper.shareCardOf(item);
      // 既没文字也没画面的是系统条目（时间戳、加人、已读…）：画出来就是一堆空行，跳过。
      // 分享卡片有封面/正文/目标链接的也留下（外链卡片可能既没有文字也没有预览图以外的画面）。
      if (text.length === 0 && mediaUrl.length === 0 && card.kind.length === 0) {
        continue;
      }
      const userId: string = JsonRead.strOf(item, 'user_id');
      const micros: number = JsonRead.numOf(item, 'timestamp');
      if (card.kind.length > 0) {
        shareCards++;
      }
      messages.push(new DirectMessage(JsonRead.strOf(item, 'item_id'), userId,
        me.length > 0 && userId === me, micros > 0 ? Math.round(micros / 1000) : 0,
        kind, text, mediaUrl, isVideo, DirectMapper.shareCodeOf(item),
        DirectMapper.shareUrlOf(item), DirectMapper.shareIsVideoOf(item),
        card.kind, card.cover, card.user, card.avatar, card.caption));
    }
    // items 是"新在前"，界面上按时间正序排（老的在上）。
    messages.sort((a: DirectMessage, b: DirectMessage): number => a.tsMs - b.tsMs);
    hilog.info(DOMAIN, TAG, 'thread parse items=%{public}d msgs=%{public}d shareCards=%{public}d',
      items.length, messages.length, shareCards);
    return new DirectThreadView(id, title, withUsername, withAvatar, withId, messages,
      JsonRead.boolOf(thread, 'has_older'), JsonRead.strOf(thread, 'oldest_cursor'),
      JsonRead.boolOf(thread, 'is_group'), fullName);
  }

  /**
   * **一条 `items[]` 条目 → `DirectMessage`**（实时补丁用；REST 那两处内联映射保持原样）。
   *
   * 移植自 `threadFromJson` 里那段循环，差别只有两点：
   *   · `item_id` 拿不到就直接放弃（实时补丁里这条 id 可能只出现在 path 里，调用方会先补进去）；
   *   · `timestamp` 缺省时用"现在"而不是 0 —— 推过来的新消息没有时间戳时，排到最下面才对。
   *
   * 返回 null 表示"这条不该画成气泡"（系统条目：已读回执、加人、时间戳…都没有文字也没有画面）。
   */
  static messageFromItem(item: Record<string, Object>, ownId: string): DirectMessage | null {
    const id: string = JsonRead.strOf(item, 'item_id');
    if (id.length === 0) {
      return null;
    }
    const kind: string = JsonRead.strOf(item, 'item_type');
    const text: string = JsonRead.strOf(item, 'text');
    const mediaUrl: string = DirectMapper.mediaUrlOf(item);
    if (text.length === 0 && mediaUrl.length === 0) {
      return null;
    }
    const userId: string = JsonRead.strOf(item, 'user_id');
    const micros: number = JsonRead.numOf(item, 'timestamp');
    const shareCode: string = DirectMapper.shareCodeOf(item);
    const shareUrl: string = DirectMapper.shareUrlOf(item);
    const shareVideo: boolean = DirectMapper.shareIsVideoOf(item);
    const card: ShareCard = DirectMapper.shareCardOf(item);
    return new DirectMessage(id, userId, ownId.length > 0 && userId === ownId,
      micros > 0 ? Math.round(micros / 1000) : Date.now(), kind, text, mediaUrl,
      DirectMapper.hasVideoMedia(item), shareCode, shareUrl, shareVideo,
      card.kind, card.cover, card.user, card.avatar, card.caption);
  }

  /**
   * 一个用户节点的头像（REST 那条路的几种形状依次试；都没有给空串）。
   *
   * 顺序：`profile_pic_url` → `hd_profile_pic_url_info.url` → `profile_pic_url_info.url`
   * （不同时期的响应给的不一样，缺一个就会出现"有名字没头像"的标题栏）。
   */
  private static pictureOf(user: Record<string, Object>): string {
    const direct: string = JsonRead.strOf(user, 'profile_pic_url');
    if (direct.length > 0) {
      return direct;
    }
    const holders: Array<string> = ['hd_profile_pic_url_info', 'profile_pic_url_info'];
    for (let index: number = 0; index < holders.length; index++) {
      const host: Record<string, Object> | null = JsonRead.recordOf(user, holders[index]);
      if (host !== null) {
        const url: string = JsonRead.strOf(host, 'url');
        if (url.length > 0) {
          return url;
        }
      }
    }
    return '';
  }

  /**
   * 一条消息里**图片候选**的最佳地址（拿不到给空串）。
   *
   * IG 把图片放在 `image_versions2.candidates[]`（第一项是最大那张；气泡里够用了，
   * 不折腾档位）。视频消息同样有这个字段 —— 那是它的**封面帧** ✓。
   */
  private static imageUrlOf(host: Record<string, Object> | null): string {
    if (host === null) {
      return '';
    }
    const versions: Record<string, Object> | null = JsonRead.recordOf(host, 'image_versions2');
    if (versions === null) {
      return '';
    }
    const candidates: Array<Object> = JsonRead.arrayOf(versions, 'candidates');
    for (let index: number = 0; index < candidates.length; index++) {
      const candidate: Record<string, Object> | null = JsonRead.asRecord(candidates[index]);
      if (candidate === null) {
        continue;
      }
      const url: string = JsonRead.strOf(candidate, 'url');
      if (url.length > 0) {
        return url;
      }
    }
    return '';
  }

  /**
   * 一条消息的图片地址（依次试几种形状；都没有给空串）。
   *
   * 私信里带画面的消息有好几种来源，形状各不相同（真机响应里都见过）：
   *   `media`        —— 直接发出去的照片/视频；
   *   `media_share`  —— 转发一条帖子；
   *   `clip`         —— 分享一条 reel（里面再套一层 `clip`）；
   *   `reel_share`   —— 分享一条动态；
   *   `link`         —— 链接卡片（缩略图在 `link_context.link_image_url`）；
   *   `xma_*`        —— **新版"分享"消息**（见 xmaImageUrl 的说明）；
   *   `animated_media` —— 贴纸 / GIF。
   */
  private static mediaUrlOf(item: Record<string, Object>): string {
    const direct: string = DirectMapper.imageUrlOf(JsonRead.recordOf(item, 'media'));
    if (direct.length > 0) {
      return direct;
    }
    const share: string = DirectMapper.imageUrlOf(JsonRead.recordOf(item, 'media_share'));
    if (share.length > 0) {
      return share;
    }
    const clip: Record<string, Object> | null = JsonRead.recordOf(item, 'clip');
    if (clip !== null) {
      const inner: string = DirectMapper.imageUrlOf(JsonRead.recordOf(clip, 'clip'));
      if (inner.length > 0) {
        return inner;
      }
      const flat: string = DirectMapper.imageUrlOf(clip);
      if (flat.length > 0) {
        return flat;
      }
    }
    const reel: Record<string, Object> | null = JsonRead.recordOf(item, 'reel_share');
    if (reel !== null) {
      const inner: string = DirectMapper.imageUrlOf(JsonRead.recordOf(reel, 'media'));
      if (inner.length > 0) {
        return inner;
      }
    }
    const link: Record<string, Object> | null = JsonRead.recordOf(item, 'link');
    if (link !== null) {
      const context: Record<string, Object> | null = JsonRead.recordOf(link, 'link_context');
      if (context !== null) {
        const thumb: string = JsonRead.strOf(context, 'link_image_url');
        if (thumb.length > 0) {
          return thumb;
        }
      }
    }
    const xma: string = DirectMapper.xmaImageUrl(item);
    if (xma.length > 0) {
      return xma;
    }
    return DirectMapper.animatedImageUrl(item);
  }

  /**
   * **XMA 那类"分享"消息**的预览图（拿不到给空串）。
   *
   * 为什么单独写一段（实测依据，2026-10-16 真机响应）：
   * 1:1 会话里整条线程可以是 `xma_clip`(18) + `xma_media_share`(2) + `generic_xma`(1)，
   * 而上面那串老字段名（`media` / `media_share` / `clip` …）**一个都不匹配** ——
   * 于是 21 条消息全被当成"既没文字也没画面"丢掉，界面报"读取失败"、
   * 用户看到的就是"这条会话只有几条/打不开"。
   *
   * 形状（实测键清单）：
   *   `item.xma_clip` / `item.xma_media_share` / `item.generic_xma` 都是**数组**（通常 1 个元素），
   *   元素里有 `preview_url`（+ `preview_width/height`、`preview_url_mime_type`）、
   *   `playable_url`（视频时）、`title_text` / `caption_body_text` / `target_url` 等。
   * 键名就是 `item_type` 本身 —— 所以这里按 `item_type` 取，再退回三个已知键名。
   */
  private static xmaImageUrl(item: Record<string, Object>): string {
    const type: string = JsonRead.strOf(item, 'item_type');
    const holders: Array<string> = [];
    if (type.length > 0) {
      holders.push(type);
    }
    const known: Array<string> = ['xma_clip', 'xma_media_share', 'generic_xma', 'xma_share'];
    for (let index: number = 0; index < known.length; index++) {
      if (holders.indexOf(known[index]) < 0) {
        holders.push(known[index]);
      }
    }
    for (let index: number = 0; index < holders.length; index++) {
      const attachments: Array<Object> = JsonRead.arrayOf(item, holders[index]);
      for (let at: number = 0; at < attachments.length && at < 2; at++) {
        const one: Record<string, Object> | null = JsonRead.asRecord(attachments[at]);
        if (one === null) {
          continue;
        }
        const direct: string = JsonRead.strOf(one, 'preview_url');
        if (direct.length > 0) {
          return direct;
        }
        // 另外两种"预览图"挂法（不同模板给的不一样，依次试）。
        const holdersInfo: Array<string> =
          ['preview_url_info', 'accessory_preview_url_info', 'parent_post_preview_url_info'];
        for (let info: number = 0; info < holdersInfo.length; info++) {
          const host: Record<string, Object> | null = JsonRead.recordOf(one, holdersInfo[info]);
          if (host === null) {
            continue;
          }
          const url: string = JsonRead.strOf(host, 'url');
          if (url.length > 0) {
            return url;
          }
        }
      }
    }
    return '';
  }

  /**
   * **贴纸 / GIF**（`animated_media`）的图片地址。
   *
   * 形状是 Giphy 那套：`animated_media.images.{fixed_height,downsized,original,…}.url`。
   * 键名不固定，所以按优先级试几个常见档位，再兜底遍历（只取有 `url` 的第一个）。
   */
  private static animatedImageUrl(item: Record<string, Object>): string {
    const media: Record<string, Object> | null = JsonRead.recordOf(item, 'animated_media');
    if (media === null) {
      return '';
    }
    const images: Record<string, Object> | null = JsonRead.recordOf(media, 'images');
    if (images === null) {
      return '';
    }
    const sizes: Array<string> = ['fixed_height', 'downsized', 'original', 'fixed_height_small',
      'preview'];
    for (let index: number = 0; index < sizes.length; index++) {
      const one: Record<string, Object> | null = JsonRead.recordOf(images, sizes[index]);
      if (one === null) {
        continue;
      }
      const url: string = JsonRead.strOf(one, 'url');
      if (url.length > 0) {
        return url;
      }
    }
    return '';
  }

  /** 这条消息的媒体里有没有视频（缩略图上盖一颗播放标记用）。 */

  /**
   * 依次从这些键里取第一个非空字符串。
   *
   * XMA（`xma_media_share` / `generic_xma` …）的字段名每个 App 版本都不一样 —— 同一个"作者名"，
   * 有的版本写 `header_title_text`、有的写 `title_text`、有的写 `preview_title_text`，
   * 这也是上一版**只画出一张封面、下面一行 `[消息]`** 的原因：只试了一个键名，取不到就成了空串。
   */
  private static firstOf(record: Record<string, Object>, keys: Array<string>): string {
    for (let index: number = 0; index < keys.length; index++) {
      const value: string = JsonRead.strOf(record, keys[index]);
      if (value.length > 0) {
        return value;
      }
    }
    return '';
  }

  /** 分享卡片要的那几样东西（见 DirectMessage.shareKind 的说明）。 */
  private static shareCardOf(item: Record<string, Object>): ShareCard {
    const type: string = JsonRead.strOf(item, 'item_type');
    const share: Record<string, Object> | null = JsonRead.recordOf(item, 'media_share');
    const clip: Record<string, Object> | null = JsonRead.recordOf(item, 'clip');
    const clipInner: Record<string, Object> | null = clip === null ? null
      : JsonRead.recordOf(clip, 'clip');
    const reel: Record<string, Object> | null = JsonRead.recordOf(item, 'reel_share');
    const reelMedia: Record<string, Object> | null = reel === null ? null
      : JsonRead.recordOf(reel, 'media');
    const card: ShareCard = new ShareCard();
    // ---- 内部帖子 / Reel：从 media 对象里取 ----
    const holders: Array<Record<string, Object>> = [];
    if (share !== null) {
      holders.push(share);
    }
    if (clipInner !== null) {
      holders.push(clipInner);
    }
    if (reelMedia !== null) {
      holders.push(reelMedia);
    }
    for (let index: number = 0; index < holders.length; index++) {
      const one: Record<string, Object> = holders[index];
      if (card.cover.length === 0) {
        card.cover = DirectMapper.imageUrlOf(one);
      }
      if (card.caption.length === 0) {
        card.caption = JsonRead.strOf(one, 'caption_text');
        if (card.caption.length === 0) {
          const caption: Record<string, Object> | null = JsonRead.recordOf(one, 'caption');
          if (caption !== null) {
            card.caption = JsonRead.strOf(caption, 'text');
          }
        }
      }
      if (card.user.length === 0) {
        const user: Record<string, Object> | null = JsonRead.recordOf(one, 'user');
        if (user === null) {
          // GraphQL 那条把作者放在 `owner` 里。
          const owner: Record<string, Object> | null = JsonRead.recordOf(one, 'owner');
          if (owner !== null) {
            card.user = DirectMapper.firstOf(owner, ['username', 'full_name']);
            card.avatar = DirectMapper.pictureOf(owner);
          }
        } else {
          card.user = DirectMapper.firstOf(user, ['username', 'full_name']);
          card.avatar = DirectMapper.pictureOf(user);
        }
      }
      if (JsonRead.numOf(one, 'media_type') === 2
        || JsonRead.strOf(one, 'product_type') === 'clips'
        || JsonRead.arrayOf(one, 'video_versions').length > 0) {
        card.video = true;
      }
    }
    // ---- XMA：preview_url + title_text + caption_body_text + target_url ----
    const attachments: Array<Object> = JsonRead.arrayOf(item, type.length > 0 ? type : 'generic_xma');
    for (let at: number = 0; at < attachments.length && at < 2; at++) {
      const one: Record<string, Object> | null = JsonRead.asRecord(attachments[at]);
      if (one === null) {
        continue;
      }
      if (card.cover.length === 0) {
        card.cover = DirectMapper.firstOf(one,
          ['preview_url', 'preview_image_url', 'thumbnail_url', 'header_icon_url']);
      }
      if (card.user.length === 0) {
        // 作者名：IG 自己画在卡片头部那一栏的就是 `header_title_text`，其余按版本依次试。
        card.user = DirectMapper.firstOf(one, ['header_title_text', 'title_text',
          'preview_title_text', 'preview_subtitle_text', 'header_subtitle_text']);
        if (card.user.length === 0) {
          const author: Record<string, Object> | null = JsonRead.recordOf(one, 'user');
          if (author !== null) {
            card.user = DirectMapper.firstOf(author, ['username', 'full_name']);
            card.avatar = DirectMapper.pictureOf(author);
          }
        }
      }
      if (card.caption.length === 0) {
        card.caption = DirectMapper.firstOf(one,
          ['caption_body_text', 'preview_subtitle_text', 'title_text']);
      }
      if (card.target.length === 0) {
        card.target = JsonRead.strOf(one, 'target_url');
      }
      if (JsonRead.strOf(one, 'playable_url').length > 0
        || JsonRead.boolOf(one, 'is_playable')) {
        card.video = true;
      }
    }
    // 少数版本把这几栏放在 item 自己身上（不在附件里）。
    if (card.user.length === 0) {
      card.user = DirectMapper.firstOf(item, ['header_title_text', 'title_text']);
    }
    if (card.caption.length === 0) {
      card.caption = JsonRead.strOf(item, 'caption_body_text');
    }
    // ---- 形态 ----
    const hasTarget: boolean = card.target.length > 0 || DirectMapper.shareCodeOf(item).length > 0;
    if (!hasTarget && card.cover.length === 0 && card.caption.length === 0) {
      card.kind = '';
      return card;
    }
    if (type.indexOf('link') >= 0) {
      card.kind = 'link';
      return card;
    }
    card.kind = card.video ? 'video' : 'post';
    return card;
  }

  /**
   * 分享卡片的**帖子短码**（拿不到给空串）。
   *
   * 覆盖的形状（真机响应里都见过）：
   *   · `media_share.code`      —— 转发一条帖子；
   *   · `clip.clip.code`        —— 分享一条 Reel（外面还套一层 `clip`）；
   *   · `reel_share.media.code` —— 分享一条动态里的媒体；
   *   · XMA（`xma_clip` / `xma_media_share` / `generic_xma`）：没有 code 字段，
   *     但有 `target_url`（形如 `https://www.instagram.com/reel/DAbc123/`）—— 从 URL 里拆。
   */
  private static shareCodeOf(item: Record<string, Object>): string {
    const share: Record<string, Object> | null = JsonRead.recordOf(item, 'media_share');
    if (share !== null) {
      const code: string = JsonRead.strOf(share, 'code');
      if (code.length > 0) {
        return code;
      }
    }
    const clip: Record<string, Object> | null = JsonRead.recordOf(item, 'clip');
    if (clip !== null) {
      const inner: Record<string, Object> | null = JsonRead.recordOf(clip, 'clip');
      if (inner !== null) {
        const code: string = JsonRead.strOf(inner, 'code');
        if (code.length > 0) {
          return code;
        }
      }
    }
    const reel: Record<string, Object> | null = JsonRead.recordOf(item, 'reel_share');
    if (reel !== null) {
      const media: Record<string, Object> | null = JsonRead.recordOf(reel, 'media');
      if (media !== null) {
        const code: string = JsonRead.strOf(media, 'code');
        if (code.length > 0) {
          return code;
        }
      }
    }
    // XMA：从目标链接里拆 /p/<code>/ 或 /reel/<code>/（也认 /reels/<code>/）。
    return DirectMapper.codeFromUrl(DirectMapper.shareUrlOf(item));
  }

  /** 从 Instagram 帖子链接里拆短码（不是帖子链接就给空串）。 */
  private static codeFromUrl(url: string): string {
    if (url.length === 0) {
      return '';
    }
    const markers: Array<string> = ['/reel/', '/reels/', '/p/', '/tv/'];
    for (let index: number = 0; index < markers.length; index++) {
      const at: number = url.indexOf(markers[index]);
      if (at < 0) {
        continue;
      }
      const rest: string = url.substring(at + markers[index].length);
      const slash: number = rest.search(/[/?#]/);
      const code: string = slash < 0 ? rest : rest.substring(0, slash);
      if (code.length > 0) {
        return code;
      }
    }
    return '';
  }

  /**
   * 分享卡片的**可打开链接**（优先帖子链接，其次外部链接）。
   *
   * 顺序：`link.link_context.link_url`（外链卡片）→ XMA 的 `target_url`。
   * 内部的帖子/Reel 也在这里出现（XMA 的 target_url 就是帖子地址）。
   */
  private static shareUrlOf(item: Record<string, Object>): string {
    const link: Record<string, Object> | null = JsonRead.recordOf(item, 'link');
    if (link !== null) {
      const context: Record<string, Object> | null = JsonRead.recordOf(link, 'link_context');
      if (context !== null) {
        const url: string = JsonRead.strOf(context, 'link_url');
        if (url.length > 0) {
          return url;
        }
      }
    }
    // XMA：按 item_type 取数组，再退回几个已知键名（和 xmaImageUrl 同一套遍历）。
    const type: string = JsonRead.strOf(item, 'item_type');
    const holders: Array<string> = [];
    if (type.length > 0) {
      holders.push(type);
    }
    const known: Array<string> = ['xma_clip', 'xma_media_share', 'generic_xma', 'xma_share'];
    for (let index: number = 0; index < known.length; index++) {
      if (holders.indexOf(known[index]) < 0) {
        holders.push(known[index]);
      }
    }
    for (let index: number = 0; index < holders.length; index++) {
      const attachments: Array<Object> = JsonRead.arrayOf(item, holders[index]);
      for (let at: number = 0; at < attachments.length && at < 2; at++) {
        const one: Record<string, Object> | null = JsonRead.asRecord(attachments[at]);
        if (one === null) {
          continue;
        }
        const url: string = JsonRead.strOf(one, 'target_url');
        if (url.length > 0) {
          return url;
        }
      }
    }
    return '';
  }

  /** 分享的是不是 Reel（决定打开 /reel/ 还是 /p/）。 */
  private static shareIsVideoOf(item: Record<string, Object>): boolean {
    const share: Record<string, Object> | null = JsonRead.recordOf(item, 'media_share');
    if (share !== null && JsonRead.numOf(share, 'media_type') === 2) {
      return true;
    }
    const type: string = JsonRead.strOf(item, 'item_type');
    if (type.indexOf('clip') >= 0) {
      return true;
    }
    const url: string = DirectMapper.shareUrlOf(item);
    return url.indexOf('/reel/') >= 0 || url.indexOf('/reels/') >= 0;
  }

  private static hasVideoMedia(item: Record<string, Object>): boolean {
    const holders: Array<string> = ['media', 'media_share'];
    for (let index: number = 0; index < holders.length; index++) {
      const host: Record<string, Object> | null = JsonRead.recordOf(item, holders[index]);
      if (host === null) {
        continue;
      }
      if (JsonRead.arrayOf(host, 'video_versions').length > 0) {
        return true;
      }
      if (JsonRead.strOf(host, 'media_type') === '2') {
        return true;
      }
    }
    /*
     * XMA 那类：视频在 `playable_url`，`preview_url_mime_type` 也会写成 `video/mp4`
     * （实测 `xma_clip` 就是这种）。两条都认，界面上才盖得住那颗播放标记。
     */
    const type: string = JsonRead.strOf(item, 'item_type');
    const xmaHolders: Array<string> = type.length > 0
      ? [type, 'xma_clip', 'xma_media_share'] : ['xma_clip', 'xma_media_share'];
    for (let index: number = 0; index < xmaHolders.length; index++) {
      const attachments: Array<Object> = JsonRead.arrayOf(item, xmaHolders[index]);
      for (let at: number = 0; at < attachments.length && at < 2; at++) {
        const one: Record<string, Object> | null = JsonRead.asRecord(attachments[at]);
        if (one === null) {
          continue;
        }
        if (JsonRead.strOf(one, 'playable_url').length > 0) {
          return true;
        }
        if (JsonRead.strOf(one, 'preview_url_mime_type').indexOf('video') >= 0) {
          return true;
        }
      }
    }
    return false;
  }
}
