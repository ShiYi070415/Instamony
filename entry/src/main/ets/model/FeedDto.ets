/*
 * 网页桥回传的信息流 DTO。
 *
 * 对应注入脚本（bridge/WebScripts.ets）返回的 JSON：
 *   TIMELINE_SCRIPT — 回放页面自己那条首页 GraphQL，字段最全（视频地址、多图、精确计数）
 *   FEED_SCRIPT     — DOM 兜底抽取，字段较少
 *
 * 保留为 interface 是因为它们只用于 `JSON.parse` 的类型断言，没有行为。
 */

/** 单条帖子的桥回传结构。 */
export interface FeedItemDto {
  id: string;
  shortcode: string;
  username: string;
  avatar: string;
  caption: string;
  images: string[];
  videoUrl: string;
  poster: string;
  permalink: string;
  likes: number;
  comments: number;
  views?: number;
  liked?: boolean;
  takenAt?: number;
  hasVideo?: boolean;
  /** 转发数 / 分享数：网页没有专门渲染，脚本会按字段名在接口节点里找。 */
  reposts?: number;
  shares?: number;
  /**
   * 媒体原始宽高（像素），来自接口节点的 original_width/height。
   *
   * 原生侧按 w/h 算出真实宽高比来排版，不再把媒体裁成正方形；
   * 拿不到时这两项缺失，原生侧退回正方形。
   */
  w?: number;
  h?: number;
  /**
   * **下载用**的原始地址（最大的一档）：多图逐张对应 images，视频帖为原视频。
   *
   * 展示用的 images/videoUrl 已经按 core/MediaQuality 降级到 1080 档（省流量），
   * 下载要原图/原视频，所以解析时把最大的一档一并带出来。
   */
  originalImages?: string[];
  originalVideo?: string;
  /**
   * 封面**低一档**地址（约 360px 宽）：首屏封面预解码用（见 core/PosterCache）。
   *
   * 只有原生解析那条路会给（页面脚本那条路没有这一档，缺了就是没有 → 那就不预热，不影响显示）。
   */
  thumb?: string;
  /**
   * 作者的用户 id（关注/取关接口的路径参数）。
   *
   * IG 的 GraphQL 节点里叫 `pk`（部分接口给 `id`），两处解析层都会带上；缺了就是没抓到，
   * 这种帖子的「关注」按钮不显示（没有 id 发不出请求）。
   */
  userId?: string;
  /** 是否已关注该作者（`friendship_status.following`）；字段缺失时不下发。 */
  following?: boolean;
}

/** 桥回传的整体载荷。 */
export interface FeedPayloadDto {
  state: string;
  message?: string;
  url?: string;
  items?: FeedItemDto[];
  debug?: string;
  /** 回放脚本会带上 src（"replay" / "ssr"），用来判断走的是哪条路径。 */
  src?: string;
  /** 页面侧 page_info.end_cursor：下一页游标；空串表示没有下一页。 */
  nextCursor?: string;
  /** 页面侧 page_info.has_next_page 的推算值（没有明确依据时会退回看游标）。 */
  hasMore?: boolean;
  /**
   * 仅在服务端**明确**给出 page_info.has_next_page 时才存在。
   *
   * 与 hasMore 分开是为了区分「服务端说没有了」和「这次响应里根本没有 page_info」：
   * 后者（常见于 SSR 内嵌数据）绝不能被当成「没有下一页」，否则翻页会被永久锁死。
   */
  hasNext?: boolean;
}

/**
 * 桥与脚本之间约定的 state 取值。
 *
 * 其中 NOT_READY / INJECT_FAILED / TIMEOUT 由 PageBridge.runBridge 在没法拿到页面
 * 结果时直接给出（见 bridge/PageBridge.ets），其余来自注入脚本自身。
 */
export class PayloadState {
  static readonly OK: string = 'ok';
  static readonly EMPTY: string = 'empty';
  static readonly ERROR: string = 'error';
  static readonly NOT_READY: string = 'not-ready';
  static readonly INJECT_FAILED: string = 'inject-failed';
  static readonly TIMEOUT: string = 'timeout';
}
