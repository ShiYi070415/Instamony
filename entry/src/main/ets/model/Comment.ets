/*
 * 互动（点赞 / 评论）DTO。
 *
 * 两者都不是通过原生请求完成的：原生侧只是让隐藏网页去点它自己的按钮、用页面自己
 * 的会话与 csrf 完成写操作，再把结果读回来（见 bridge/WebScripts.ets 的
 * likePostScript / commentsScript）。所以这里的字段刻意保持最少，只放网页里稳定
 * 能拿到的内容。
 */

/** 一条评论。 */
export interface CommentItem {
  /** 作者用户名；网页里没取到时为空串。 */
  username: string;
  /**
   * 作者的数字 id（`user.pk`）。
   *
   * 用途：评论面板里点头像 / 用户名要打开 TA 的主页，而主页头部那几条查询要数字 id
   * （见 pages/Index.openUserProfile）；拿不到就传空串，主页仍然会按用户名打开。
   */
  userId?: string;
  /** 评论正文。 */
  text: string;
  /**
   * 作者头像地址；取不到就是空串。
   *
   * 这几项都来自页面自己的评论接口 JSON（见 bridge/WebScripts 的 COMMENTS_JSON_JS），
   * 所以是网页里的原值，不是从 DOM 里猜的。
   */
  avatar?: string;
  /** 点赞数；接口没给就是 0。 */
  likes?: number;
  /**
   * 这条评论的**数字 id**（`pk`）：点赞 / 取消点赞要拿它当路径参数
   * （见 core/NativeComments.like）。空 = 这条响应没给，那颗心点了也不发请求。
   */
  pk?: string;
  /** 本机点过赞没有（右侧那颗心按它画，点一下乐观翻转）。 */
  liked?: boolean;
  /**
   * **图片评论**（贴图）里的那张图；普通文字评论为空串。
   *
   * IG 的图片评论在接口里 `text` 是**空串**、图在另一个字段里（见 NativeComments.findImage）——
   * 所以"只有头像和 id、没有正文"的那些评论就是它们，界面要把这张图画出来。
   */
  imageUrl?: string;
  /**
   * 贴图自己的宽高（接口给了才有；Giphy 的档位对象与 `candidates` 都带）。
   *
   * 用途：**方图/横图不加上下黑边**（需求："不超过 1:1 的不用添加上下黑边，横向沾满正文区"）——
   * 只有知道比例才能让盒子按比例铺满宽度，不然只能塞进一个方盒子里留黑边。
   */
  mediaW?: number;
  mediaH?: number;
  /**
   * 这条评论**下面挂了多少条回复**（IG 的 `child_comment_count`）。
   *
   * 0 / undefined = 没有回复 —— 面板就不显示"查看另外 n 条回复"那一行。
   */
  repliesCount?: number;
  /**
   * 已经取回来的**回复**（先放接口自带的预览那几条；展开时不够再补，
   * 见 pages/Index.loadCommentReplies）。
   *
   * 只挂一层（回复的回复不再展开）—— IG 的评论线程也只有一层。
   */
  replies?: CommentItem[];
  /** 回复是不是已经**取全**了（true 之后不再发请求）。 */
  repliesLoaded?: boolean;
  /**
   * 发布时间（**Unix 秒**，接口的 `created_at`）。
   *
   * 面板在用户 id 旁边用灰色小字显示"多久之前"（见 CommentsPanel.agoText）；
   * 接口没给就是 0/undefined，那就不显示（不猜）。
   */
  createdAt?: number;
}

/**
 * 评论读取结果。
 *
 * state: ok（读到了）/ empty（页面开了但没有可读条目）/ not-found（网页当前信息流里
 * 没有这条帖子，需要改成导航到帖子页再读）/ no-button（没找到评论按钮）/ error。
 * diag 是一份结构摘要，读不到时凭它定位。
 */
export interface CommentsPayload {
  state: string;
  items?: CommentItem[];
  diag?: string;
  message?: string;
  /** 下一页的游标（REST 的 `next_max_id` / `next_min_id` / GraphQL 的 `page_info.end_cursor`）。 */
  nextMaxId?: string;
  /** 上面的游标是不是"头部加载"那种（要拼成 `min_id=` 而不是 `max_id=`，见 NativeComments）。 */
  nextMin?: boolean;
  /** 还有没有下一页（触底加载用）。 */
  hasMore?: boolean;
}

/**
 * 点赞结果。
 *
 * state: liked / unliked（已按新状态读回）/ not-found / no-button / error。
 * assumed 为 true 表示点击已发出但没等到 DOM 翻转，按取反值回报。
 */
export interface LikePayload {
  state: string;
  assumed?: boolean;
  message?: string;
}



