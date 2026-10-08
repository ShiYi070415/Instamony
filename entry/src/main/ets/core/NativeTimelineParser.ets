/*
 * 原生解析首页信息流的 GraphQL 响应（网页那条脚本做过的同一件事，搬到原生来做）。
 *
 * 为什么要搬到原生：走 core/NativeFeed 那条路时，我们**没有网页**可以注入脚本 ——
 * 响应体就在原生手里，直接 `JSON.parse` 出结构、映射成原生卡片要的字段（FeedItemDto），
 * 是唯一的选择，也顺带省掉了"整包响应过桥"的开销（实测这一包 68KB）。
 *
 * 映射规则**刻意和页面脚本（WebScripts.timelineScript）保持一致**：同样的字段名兜底、
 * 同样的"取最大尺寸图"、同样的 original_width/height 优先。两边不一致就会出现
 * "走网页时排版对、走原生时不对"这种最难查的问题。
 */

import { FeedItemDto } from '../model/FeedDto';
import { MediaQuality, PickedMedia } from './MediaQuality';

/** 连接键：响应 `.data` 里放首页信息流的那个键。 */
const FEED_KEY: string = 'xdt_api__v1__feed__timeline__connection';
/**
 * 首屏封面预解码用的**低一档宽度**（px）。
 *
 * 网格/信息流的展示档是 1080（见 MediaQuality），一百多 KB；冷启动时先用 360 这一档
 * （几十 KB，几十毫秒就到）解出一张小图垫在下面，真图加载完自然盖住（见 core/PosterCache）。
 */
const THUMB_WIDTH: number = 360;

/** 图片候选（image_versions2.candidates）。 */
interface IgCandidate {
  url?: string | null;
  width?: number | null;
  height?: number | null;
}

interface IgImageVersions {
  candidates?: Array<IgCandidate> | null;
}

interface IgVideoVersion {
  url?: string | null;
  width?: number | null;
  height?: number | null;
}

interface IgUser {
  pk?: string | number | null;
  id?: string | null;
  username?: string | null;
  profile_pic_url?: string | null;
  friendship_status?: IgFriendship | null;
}

/**
 * 关注状态。
 *
 * 信息流那条 GraphQL 不一定带它（带就带上，不带就当作"未知"，由关注按钮自己记状态，
 * 见 viewmodel/FeedViewModel.followStates）。
 */
interface IgFriendship {
  following?: boolean | null;
  outgoing_request?: boolean | null;
}

interface IgCaption {
  text?: string | null;
}

/**
 * 一条媒体（帖子）。
 *
 * 注意每个字段都可能是 **null**（不是 undefined）：GraphQL 对"没有这个字段"就是回 null，
 * 而 `null.length` / `for (x of null)` 会直接抛 —— 实测踩过（解析整包时
 * `Cannot read property carousel_media of null`，整条首屏链路在重试里空转）。
 * 所以下面一律走 `?? []` / `?? {}`，绝不直接取属性。
 */
interface IgMedia {
  id?: string | null;
  code?: string | null;
  media_type?: number | null;
  original_width?: number | null;
  original_height?: number | null;
  image_versions2?: IgImageVersions | null;
  video_versions?: Array<IgVideoVersion> | null;
  carousel_media?: Array<IgMedia> | null;
  user?: IgUser | null;
  caption?: IgCaption | null;
  like_count?: number | null;
  comment_count?: number | null;
  view_count?: number | null;
  play_count?: number | null;
  ig_play_count?: number | null;
  has_liked?: boolean | null;
  taken_at?: number | null;
  /**
   * 转发 / 分享计数。
   *
   * IG 的字段名**不确定**（网页界面根本不渲染这两个数字，只能去节点里翻），所以这里像页面
   * 脚本那样多列几个候选名，谁先有值用谁：`repost_count` / `media_repost_count` /
   * `reposts_count` / `reshare_count` / `reshares_count`。
   * 只认这几个**明确含 repost/reshare 的整型计数**，不会误抓到别的东西。
   */
  reshare_count?: number | null;
  share_count?: number | null;
  shares_count?: number | null;
  media_share_count?: number | null;
  repost_count?: number | null;
  media_repost_count?: number | null;
  reposts_count?: number | null;
  reshares_count?: number | null;
}

interface IgNode {
  media?: IgMedia | null;
  explore_story?: IgNode | null;
}

interface IgEdge {
  node?: IgNode | null;
}

interface IgPageInfo {
  end_cursor?: string | null;
  has_next_page?: boolean | null;
}

interface IgConnection {
  edges?: Array<IgEdge> | null;
  page_info?: IgPageInfo | null;
}

interface IgResponse {
  data?: Record<string, IgConnection> | null;
}

/** 选出的一张图（url 一定非空：调用方不用再判 null）。 */
class PickedImage {
  readonly url: string;
  readonly width: number;
  readonly height: number;

  constructor(url: string, width: number, height: number) {
    this.url = url;
    this.width = width;
    this.height = height;
  }
}

/** 解析结果：条目 + 游标（游标只用于诊断/日志，翻页仍走网页那条路）。 */
export class NativeTimeline {
  readonly items: Array<FeedItemDto>;
  readonly nextCursor: string;
  readonly hasNext: boolean;

  constructor(items: Array<FeedItemDto>, nextCursor: string, hasNext: boolean) {
    this.items = items;
    this.nextCursor = nextCursor;
    this.hasNext = hasNext;
  }
}

export class NativeTimelineParser {
  /**
   * 把整包响应解析成卡片 DTO。
   *
   * 解析不了（不是 JSON / 没有连接 / 一条媒体都没有）返回 null，调用方直接退回网页路径。
   */
  static parse(body: string): NativeTimeline | null {
    if (body.length === 0 || body.indexOf(FEED_KEY) < 0) {
      return null;
    }
    let response: IgResponse;
    try {
      response = JSON.parse(body) as IgResponse;
    } catch (error) {
      return null;
    }
    const data: Record<string, IgConnection> | null = response.data ?? null;
    if (data === null) {
      return null;
    }
    const conn: IgConnection | null = data[FEED_KEY] ?? null;
    if (conn === null) {
      return null;
    }
    const edges: Array<IgEdge> = conn.edges ?? [];
    const items: Array<FeedItemDto> = [];
    for (let index: number = 0; index < edges.length; index++) {
      const node: IgNode | null = edges[index].node ?? null;
      if (node === null) {
        continue;
      }
      // 信息流里混着"推荐"卡片：node.media 是 null，真正的帖子挂在 node.explore_story.media。
      let media: IgMedia | null = node.media ?? null;
      if (media === null && node.explore_story !== null && node.explore_story !== undefined) {
        media = node.explore_story.media ?? null;
      }
      if (media === null) {
        continue;
      }
      items.push(NativeTimelineParser.toItem(media));
    }
    if (items.length === 0) {
      return null;
    }
    const info: IgPageInfo = conn.page_info ?? {};
    const cursor: string = (info.end_cursor ?? '').trim();
    const hasNext: boolean = info.has_next_page === true;
    return new NativeTimeline(items, cursor, hasNext);
  }

  /**
   * 媒体 → FeedItemDto（字段与页面脚本一一对应）。
   *
   * 图片/视频都取**两份**：展示用按 core/MediaQuality 降到 1080 档（省流量），
   * 下载用的原图/原视频留在 originalImages / originalVideo 里。
   */
  private static toItem(media: IgMedia): FeedItemDto {
    const images: Array<string> = [];
    const originalImages: Array<string> = [];
    let video: string = '';
    let originalVideo: string = '';
    // 首屏封面预解码用的**低一档**封面地址（见 core/PosterCache）：只取展示那张图的小档，
    // 几十 KB，冷启动时先把它解出来垫在真图下面，首屏不用对着空框等。
    let thumb: string = '';
    let imageW: number = 0;
    let imageH: number = 0;
    let videoW: number = 0;
    let videoH: number = 0;
    const carousel: Array<IgMedia> = media.carousel_media ?? [];
    if (carousel.length > 0) {
      for (let index: number = 0; index < carousel.length && index < 10; index++) {
        const child: IgMedia = carousel[index];
        const picked: PickedImage = NativeTimelineParser.pickImage(child.image_versions2);
        const original: PickedImage = NativeTimelineParser.pickImage(child.image_versions2, true);
        if (picked.url.length > 0) {
          images.push(picked.url);
          originalImages.push(original.url.length > 0 ? original.url : picked.url);
          if (imageW === 0) {
            imageW = picked.width;
            imageH = picked.height;
          }
        }
        if (video.length === 0) {
          const version: IgVideoVersion | undefined = NativeTimelineParser.pickVideo(child);
          if (version !== undefined) {
            video = version.url ?? '';
            videoW = version.width ?? 0;
            videoH = version.height ?? 0;
          }
          const best: IgVideoVersion | undefined = NativeTimelineParser.pickVideo(child, true);
          if (best !== undefined) {
            originalVideo = best.url ?? '';
          }
        }
      }
    } else {
      const picked: PickedImage = NativeTimelineParser.pickImage(media.image_versions2);
      const original: PickedImage = NativeTimelineParser.pickImage(media.image_versions2, true);
      if (picked.url.length > 0) {
        images.push(picked.url);
        originalImages.push(original.url.length > 0 ? original.url : picked.url);
        imageW = picked.width;
        imageH = picked.height;
        thumb = NativeTimelineParser.pickImage(media.image_versions2, false, true).url;
      }
      const version: IgVideoVersion | undefined = NativeTimelineParser.pickVideo(media);
      if (version !== undefined) {
        video = version.url ?? '';
        videoW = version.width ?? 0;
        videoH = version.height ?? 0;
      }
      const best: IgVideoVersion | undefined = NativeTimelineParser.pickVideo(media, true);
      if (best !== undefined) {
        originalVideo = best.url ?? '';
      }
    }
    // 帖子的 original_width/height 才是这条媒体的真实比例，优先用它；没有才退回图片/视频尺寸。
    let width: number = media.original_width ?? 0;
    let height: number = media.original_height ?? 0;
    if (width <= 0 || height <= 0) {
      width = imageW;
      height = imageH;
    }
    if (width <= 0 || height <= 0) {
      width = videoW;
      height = videoH;
    }
    const code: string = (media.code ?? '').trim();
    const mediaType: number = media.media_type ?? 1;
    const kind: string = (mediaType === 2 || video.length > 0) ? 'reel' : 'p';
    const user: IgUser = media.user ?? {};
    const caption: IgCaption = media.caption ?? {};
    // 作者 id：`pk` 优先（GraphQL 都用它），退回 `id`；数字要转成字符串。
    const rawId: string | number | null | undefined = user.pk ?? user.id ?? '';
    const friend: IgFriendship = user.friendship_status ?? {};
    const item: FeedItemDto = {
      id: (media.id ?? code).trim(),
      shortcode: code,
      username: (user.username ?? '').trim(),
      avatar: (user.profile_pic_url ?? '').trim(),
      caption: caption.text ?? '',
      images: images,
      videoUrl: video,
      poster: images.length > 0 ? images[0] : '',
      permalink: code.length > 0 ? `https://www.instagram.com/${kind}/${code}/` : '',
      likes: media.like_count ?? 0,
      comments: media.comment_count ?? 0,
      views: media.view_count ?? media.play_count ?? media.ig_play_count ?? 0,
      liked: media.has_liked === true,
      takenAt: (media.taken_at ?? 0) * 1000,
      w: width,
      h: height
    };
    if (thumb.length > 0) {
      item.thumb = thumb;
    }
    // 关注按钮要用作者 id（关注/取关接口的路径参数）；没有就不下发，按钮那侧自然不显示。
    const userId: string = `${rawId}`.trim();
    if (userId.length > 0 && userId !== 'null' && userId !== 'undefined') {
      item.userId = userId;
    }
    if (friend.following !== undefined && friend.following !== null) {
      item.following = friend.following === true;
    }
    // 下载用的原始地址（最大的一档）：展示用的那份已经降级过了。
    if (originalImages.length > 0) {
      item.originalImages = originalImages;
    }
    if (originalVideo.length > 0) {
      item.originalVideo = originalVideo;
    }
    // 转发/分享计数：网页界面不渲染它们，只能按字段名在节点里找（和页面脚本同一套判据）。
    // 字段名不确定，所以**按候选名依次取第一个有值的**（见 IgMedia 上那段说明）——
    // 只认 repost_count 一个名字的话，接口换个叫法（media_repost_count 之类）就永远读不到，
    // 表现就是"转发数量没有显示"。
    const repost: number = NativeTimelineParser.firstCount([
      media.repost_count, media.media_repost_count, media.reposts_count,
      media.reshare_count, media.reshares_count
    ]);
    const share: number = NativeTimelineParser.firstCount([
      media.share_count, media.shares_count, media.media_share_count
    ]);
    if (repost > 0) {
      item.reposts = repost;
    }
    if (share > 0) {
      item.shares = share;
    }
    return item;
  }

  /** 取第一个正的计数（字符串数字也认，字段名不定时用；都不认就 0）。 */
  private static firstCount(values: Array<number | string | null | undefined>): number {
    for (let index: number = 0; index < values.length; index++) {
      const raw: number | string | null | undefined = values[index];
      let value: number = 0;
      if (typeof raw === 'number') {
        value = raw;
      } else if (typeof raw === 'string') {
        // "1,234" / "1.2K" 这种格式化过的值也认（少见，但真出现过）。
        const text: string = raw.replace(/,/g, '').trim();
        const match: RegExpMatchArray | null = text.match(/^([0-9]+(?:\.[0-9]+)?)([KkMmBb])?$/);
        if (match !== null) {
          value = Number(match[1]);
          const unit: string = (match[2] ?? '').toLowerCase();
          if (unit === 'k') {
            value = value * 1000;
          } else if (unit === 'm') {
            value = value * 1000000;
          } else if (unit === 'b') {
            value = value * 1000000000;
          }
        }
      }
      if (value > 0) {
        return Math.round(value);
      }
    }
    return 0;
  }

  /**
   * 图片候选 → 一张图。
   *
   * @param original true = 取最大的一档（下载用）；false = 按 core/MediaQuality 降到 1080 档（展示用）。
   */
  private static pickImage(versions: IgImageVersions | null | undefined,
                           original: boolean = false,
                           thumb: boolean = false): PickedImage {
    const empty: PickedImage = new PickedImage('', 0, 0);
    if (versions === null || versions === undefined) {
      return empty;
    }
    const candidates: Array<IgCandidate> = versions.candidates ?? [];
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const url: string = (candidates[index].url ?? '').trim();
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(candidates[index].width ?? 0);
      heights.push(candidates[index].height ?? 0);
    }
    const picked: PickedMedia = original
      ? MediaQuality.originalImage(urls, widths, heights)
      : thumb
        ? MediaQuality.displayImageAt(urls, widths, heights, THUMB_WIDTH)
        : MediaQuality.displayImage(urls, widths, heights);
    return new PickedImage(picked.url, picked.width, picked.height);
  }

  /** 视频候选 → 一档；original=true 取最大的一档（下载），false 取 1080 档（展示）。 */
  private static pickVideo(media: IgMedia, original: boolean = false): IgVideoVersion | undefined {
    const versions: Array<IgVideoVersion> = media.video_versions ?? [];
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < versions.length; index++) {
      const url: string = (versions[index].url ?? '').trim();
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(versions[index].width ?? 0);
      heights.push(versions[index].height ?? 0);
    }
    const picked: PickedMedia = original
      ? MediaQuality.originalVideo(urls, widths, heights)
      : MediaQuality.displayVideo(urls, widths, heights);
    if (picked.url.length === 0) {
      return undefined;
    }
    const hit: IgVideoVersion = { url: picked.url, width: picked.width, height: picked.height };
    return hit;
  }
}
