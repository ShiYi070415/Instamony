/*
 * 一条媒体的**视频地址**：按需去 IG 的 REST 取一次。
 *
 * ## 为什么需要它
 * 「用户 / 我的」页面的**视频分页**（`PolarisProfileReelsTabContentQuery`）只给**封面**：
 * 真机实测那条响应里每条媒体的键是
 *   `pk,id,code,media_overlay_info,carousel_media,user,play_count,view_count,like_count,
 *    media_type,image_versions2,preview,original_width,original_height,…`
 * —— `media_type=2`（视频）却**没有 `video_versions`**，也没有任何名字里带 video/url 的键。
 * 也就是说：那一页是"网格"，IG 只下发封面，视频地址要等真正打开时才去拿。
 * 所以点进 Reels 页之后，播之前得按 media id 补一次。
 *
 * ## 端点
 * 用 IG 网页版取单条媒体的那条老接口：
 *   `GET https://www.instagram.com/api/v1/media/{media_id}/info/`
 * 响应形如 `{"items":[{"video_versions":[{"url":…,"width":…,"height":…}],…}],"status":"ok"}`。
 * **真机实测：这条端点上 POST 回 405（方法不允许），GET 才是通的**（200 + 37KB JSON），
 * 所以 GET 是主路、POST 只留作兜底。判据要严：响应里必须真的有 `video_versions` ——
 * IG 对不认识的请求会回 200 + 一整页 HTML，只看 HTTP 码会把失败报成成功。
 *
 * 请求由 core/mobileapi 统一签名（App 身份 + 会话字段），不需要任何网页模板。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MediaQuality, PickedMedia } from './MediaQuality';
import { MobileRequest, MobileResult, MobileOptions } from './mobileapi/MobileRequest';
import { ApiThrottle } from './ApiThrottle';
import { MobileEngage } from './mobileapi/MobileEngage';
// 分享数取证（落盘 files/Instamony_share_probe.txt，见那个文件的头注释）。
import { ShareProbe } from './ShareProbe';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeMediaInfo';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 8000;

/** 取到的视频地址（展示档 + 下载档）；空串 = 没取到。 */
export class MediaVideo {  readonly display: string;
  readonly original: string;
  readonly width: number;
  readonly height: number;
  /**
   * 这条媒体**作者的**头像（`items[0].user.profile_pic_url`）。
   *
   * 顺手带出来：**收藏 / 被标注**那两段帖子里的 `user` 对象只有 `pk/username/id`
   * （真机实测，没有头像字段），而这条 media info 响应里作者对象是全的 —— 一次请求
   * 既补视频地址又补头像，不用再为头像单独发一发（见 pages/Index.loadPostPageVideos）。
   */
  readonly avatarUrl: string;

  constructor(display: string, original: string, width: number, height: number,
              avatarUrl: string = '') {
    this.display = display;
    this.original = original.length > 0 ? original : display;
    this.width = width;
    this.height = height;
    this.avatarUrl = avatarUrl;
  }

  ok(): boolean {
    return this.display.length > 0;
  }
}

/** 一张图的两档（展示 / 原始）。两个都是空串 = 这个节点没有图片候选。 */
class ImagePick {
  readonly display: string;
  readonly original: string;
  /** 这张图的宽高比（w/h；0 = 候选里没带尺寸）。多图帖按它挑"最高那张"。 */
  readonly aspect: number;

  constructor(display: string, original: string, aspect: number = 0) {
    this.display = display;
    this.original = original;
    this.aspect = aspect;
  }

  empty(): boolean {
    return this.display.length === 0 && this.original.length === 0;
  }
}

/**
 * 一条媒体的**整份详情**（帖子页补全用）。
 *
 * 帖子页（从「我的」页的帖子 / 收藏 / 被标注进来那一页）要的东西比"视频地址"多：
 *   - 视频地址（视频帖；收藏 / 被标注那两段的载荷一个都不给）；
 *   - **多图**（多图帖的载荷里同样没有 `carousel_media`，于是"只显示一张"）；
 *   - **发布时间**（载荷没有 `taken_at`，卡片那一行时间就不画，见 FeedList.hasPostedTime）；
 *   - **作者头像**（那两段的 `user` 对象只有 pk/username）。
 * 这四样在这一发 media info 响应里全都有，所以一次请求全带走（见 pages/Index.loadPostPageVideos）。
 */
export class MediaDetail {
  /** 视频展示档（图片帖为空串）。 */
  readonly display: string;
  /** 视频下载档。 */
  readonly original: string;
  readonly width: number;
  readonly height: number;
  readonly avatarUrl: string;
  /** 多图的**展示档**（按顺序；单图帖长度 1，没有图就是 0）。 */
  readonly images: Array<string>;
  /** 多图的下载档（顺序对应 images；拿不到就是空数组）。 */
  readonly originalImages: Array<string>;
  /** 发布时间（毫秒；拿不到 0）。 */
  readonly takenAtMs: number;
  /** 收藏状态（`has_saved`）：`savedKnown` 为假时这个值没有意义。 */
  readonly saved: boolean;
  readonly savedKnown: boolean;
  /** 多图帖里最高那张图的宽高比（w/h；0 = 不知道；见 ImagePick.aspect）。 */
  readonly imageAspectMin: number;
  /** 转发数（`media_repost_count`；0 = 没给）。 */
  readonly repostCount: number;

  constructor(display: string, original: string, width: number, height: number, avatarUrl: string,
              images: Array<string>, originalImages: Array<string>, takenAtMs: number,
              saved: boolean = false, savedKnown: boolean = false, imageAspectMin: number = 0,
              repostCount: number = 0) {
    this.display = display;
    this.original = original.length > 0 ? original : display;
    this.width = width;
    this.height = height;
    this.avatarUrl = avatarUrl;
    this.images = images;
    this.originalImages = originalImages;
    this.takenAtMs = takenAtMs;
    this.saved = saved;
    this.savedKnown = savedKnown;
    this.imageAspectMin = imageAspectMin;
    this.repostCount = repostCount;
  }

  /** 有没有视频地址。 */
  hasVideo(): boolean {
    return this.display.length > 0;
  }

  /** 是不是**多图**（轮播要 `imageUrls.length > 1`，见 FeedList 的媒体盒子）。 */
  hasImages(): boolean {
    return this.images.length > 1;
  }

  /** 这一发到底有没有捞到东西（全是空的就该当失败，别去替换列表）。 */
  useful(): boolean {
    return this.display.length > 0 || this.images.length > 0
      || this.avatarUrl.length > 0 || this.takenAtMs > 0;
  }
}

/** 响应里的一条候选（只要这三个字段）。 */
interface VideoVersionDto {
  url?: string;
  width?: number;
  height?: number;
}

/** 图片候选那一层（`image_versions2.candidates`）。 */
interface ImageVersionsDto {
  candidates?: Array<VideoVersionDto>;
}

interface MediaItemDto {
  video_versions?: Array<VideoVersionDto>;
  /** 图片候选：多图帖里**每个子媒体**各有一份（见 carousel_media）。 */
  image_versions2?: ImageVersionsDto;
  /**
   * 多图帖的子媒体（真机上这条 media info 会整串给出来）。
   *
   * 为什么需要它：IG 的**收藏 / 被标注**那两段查询只给封面（真机实测，见 pages/Index 的说明），
   * 载荷里既没有 `carousel_media` 也没有 `video_versions` —— 帖子页要画轮播、要显示发布时间，
   * 只能拿 media id 到这里来补（见 pages/Index.loadPostPageVideos）。
   */
  carousel_media?: Array<MediaItemDto>;
  original_width?: number;
  original_height?: number;
  /** 发布时间（秒）。 */
  taken_at?: number;
  /** 转发数（`media_repost_count`；有的查询按 `repost_count` 给）。 */
  media_repost_count?: number;
  repost_count?: number;
  /** 本机点赞 / 转发过没有（有的查询给）。 */
  has_liked?: boolean;
  viewer_has_liked?: boolean;
  media_repost_count_viewer?: number;
  /** 本机收藏了没有（IG 有的查询给，有的不给）。 */
  has_saved?: boolean;
  /** 作者（收藏 / 被标注那两段的查询里没有头像，这条响应里有，见 MediaVideo.avatarUrl）。 */
  user?: MediaUserDto;
}

interface MediaUserDto {
  profile_pic_url?: string;
  profile_pic_url_hd?: string;
  hd_profile_pic_url_info?: VideoVersionDto;
}

interface MediaInfoDto {
  status?: string;
  items?: Array<MediaItemDto>;
}

export class NativeMediaInfo {
  /** 最近一次失败的原因（诊断用，界面/日志里能看出是"没会话"还是"IG 回 HTML"）。 */
  private static detail: string = '-';

  static lastDetail(): string {
    return NativeMediaInfo.detail;
  }

  /**
   * 可用的数字 pk（用不了给空串）：这条端点只认数字，短码 / `profile-<code>` 占位串都不行。
   *
   * 但 `"<媒体pk>_<作者pk>"` 这种**规范形状要认**：移动端接口给的媒体 `id` 就是它
   * （真机日志里 `id not numeric, skipped: …_6752`），取 `_` 前面那段正好是端点要的 pk
   * （instagrapi 的 `media_pk` 也是 `id.split('_')[0]`）。
   */
  private static pkOf(raw: string): string {
    const text: string = (raw ?? '').trim();
    if (text.length === 0) {
      return '';
    }
    const cut: number = text.indexOf('_');
    const id: string = cut > 0 ? text.substring(0, cut) : text;
    for (let index: number = 0; index < id.length; index++) {
      const ch: string = id.charAt(index);
      if (ch < '0' || ch > '9') {
        return '';
      }
    }
    return id;
  }

  /**
   * 取一条媒体的视频地址。
   *
   * @param mediaId 媒体数字 id（`ProfilePost.mediaId` / ReelsPage 那条的 `Reel.mediaId`）。
   * @param shortcode 这条的短码（可选）。**个人页那几个分页要带**：那些载荷里的 id 可能只是
   *                短码本身，`/media/{id}/info/` 只认数字 pk —— 这时用短码换一个
   *                （见 core/mobileapi/MobileEngage.mediaPkFor）。
   * @returns 取不到给 null（调用方保持封面、不假装能播）。
   */
  static async videoFor(mediaId: string, shortcode: string = ''): Promise<MediaVideo | null> {
    const detail: MediaDetail | null = await NativeMediaInfo.detailFor(mediaId, shortcode);
    if (detail === null || !detail.hasVideo()) {
      return null;
    }
    return new MediaVideo(detail.display, detail.original, detail.width, detail.height,
      detail.avatarUrl);
  }

  /**
   * 取一条媒体的**整份详情**（视频 + 多图 + 发布时间 + 作者头像 + 收藏状态）。
   *
   * 这是这条端点的主入口（`videoFor` 只是它的一层薄包装）。帖子页用它一次补齐四样东西，
   * 原因见 MediaDetail 的说明。
   */
  static async detailFor(mediaId: string, shortcode: string = ''): Promise<MediaDetail | null> {
    let id: string = NativeMediaInfo.pkOf(mediaId);
    if (id.length === 0 && shortcode.trim().length > 0) {
      // 短码 → 真 pk（个人页 / 视频分页那种"只有短码"的条目走这里）。
      id = await MobileEngage.mediaPkFor(shortcode);
    }
    if (id.length === 0) {
      NativeMediaInfo.detail = 'no-media-id';
      return null;
    }
    /*
     * **只走移动端私有接口**（`media/{pk}/info/`，App 身份 + 会话字段）。
     */
    let out: MediaDetail | null = null;
    try {
      const result: MobileResult = await MobileRequest.send(`media/${encodeURIComponent(id)}/info/`,
        '', '', true, null, new MobileOptions(ApiThrottle.MEDIA_INFO, ApiThrottle.interactive()));
      if (!result.ok) {
        NativeMediaInfo.detail = result.summary();
        hilog.info(DOMAIN, TAG, 'media info miss id=%{public}s %{public}s',
          id, result.summary());
        return null;
      }
      /*
       * 分享数取证（见 core/ShareProbe）：`media/{pk}/info/` 是"单条媒体最全的一份载荷"，
       * 如果分享数在哪个接口里出现，多半也会在这里 —— 顺手落一次盘，作为第四个证据点。
       */
      ShareProbe.noteBody('media/info', result.body);
      out = NativeMediaInfo.parse(result.body);
    } catch (error) {
      NativeMediaInfo.detail = `throw:${(error as Error).message ?? '-'}`.substring(0, 60);
      return null;
    }
    hilog.info(DOMAIN, TAG,
      'detailFor id=%{public}s ok=%{public}s video=%{public}s images=%{public}d time=%{public}s detail=%{public}s',
      id, `${out !== null}`, `${out !== null && out.hasVideo()}`,
      out === null ? 0 : out.images.length,
      `${out !== null && out.takenAtMs > 0}`, NativeMediaInfo.detail);
    return out;
  }

  /** 响应文本 → 整份详情（什么都没有就给 null）。 */
  private static parse(text: string): MediaDetail | null {
    if (text.length === 0) {
      return null;
    }
    let dto: MediaInfoDto;
    try {
      dto = JSON.parse(text) as MediaInfoDto;
    } catch (error) {
      NativeMediaInfo.detail = 'json-parse';
      return null;
    }
    const items: Array<MediaItemDto> = dto.items ?? [];
    if (items.length === 0) {
      NativeMediaInfo.detail = 'no-items';
      return null;
    }
    const item: MediaItemDto = items[0];
    // ---- 视频 ----
    let display: string = '';
    let original: string = '';
    let width: number = item.original_width ?? 0;
    let height: number = item.original_height ?? 0;
    const versions: Array<VideoVersionDto> = item.video_versions ?? [];
    if (versions.length > 0) {
      const urls: Array<string> = [];
      const widths: Array<number> = [];
      const heights: Array<number> = [];
      for (let index: number = 0; index < versions.length; index++) {
        const one: VideoVersionDto = versions[index];
        const url: string = one.url ?? '';
        if (url.length === 0) {
          continue;
        }
        urls.push(url);
        widths.push(one.width ?? 0);
        heights.push(one.height ?? 0);
      }
      if (urls.length > 0) {
        // 展示档按 MediaQuality 那套挑（和视频流/信息流同一个判据），下载档取最大那一档。
        const pickedDisplay: PickedMedia = MediaQuality.displayVideo(urls, widths, heights);
        const pickedOriginal: PickedMedia = MediaQuality.originalVideo(urls, widths, heights);
        display = pickedDisplay.url;
        original = pickedOriginal.url;
        if (width <= 0 || height <= 0) {
          width = pickedDisplay.width;
          height = pickedDisplay.height;
        }
      }
    }
    // ---- 多图（有 carousel_media 就整串收；没有就用外层那份图片候选）----
    const images: Array<string> = [];
    const originalImages: Array<string> = [];
    // 多图帖**最高那张**的宽高比（w/h 取最小；需求："媒体区高度根据高度最高的图片"）。
    let minAspect: number = 0;
    const carousel: Array<MediaItemDto> = item.carousel_media ?? [];
    if (carousel.length > 0) {
      for (let index: number = 0; index < carousel.length && index < 10; index++) {
        const pick: ImagePick = NativeMediaInfo.imageOf(carousel[index]);
        if (pick.aspect > 0 && (minAspect <= 0 || pick.aspect < minAspect)) {
          minAspect = pick.aspect;
        }
        if (pick.display.length > 0 && images.indexOf(pick.display) < 0) {
          images.push(pick.display);
        }
        const full: string = pick.original.length > 0 ? pick.original : pick.display;
        if (full.length > 0 && originalImages.indexOf(full) < 0) {
          originalImages.push(full);
        }
      }
    } else {
      const pick: ImagePick = NativeMediaInfo.imageOf(item);
      if (pick.display.length > 0) {
        images.push(pick.display);
      }
      const full: string = pick.original.length > 0 ? pick.original : pick.display;
      if (full.length > 0) {
        originalImages.push(full);
      }
    }
    if ((width <= 0 || height <= 0) && images.length === 0 && display.length === 0) {
      width = 0;
      height = 0;
    }
    // ---- 时间 / 头像 / 收藏 ----
    const takenAt: number = (item.taken_at ?? 0) * 1000;
    const savedKnown: boolean = item.has_saved !== undefined && item.has_saved !== null;
    // 转发数：两个字段名都试（见 MediaItemDto）。
    const reposts: number = (item.media_repost_count ?? 0) > 0
      ? (item.media_repost_count ?? 0) : (item.repost_count ?? 0);
    const detail: MediaDetail = new MediaDetail(display, original, width, height,
      NativeMediaInfo.avatarOf(item.user), images, originalImages, takenAt,
      item.has_saved === true, savedKnown, images.length > 1 ? minAspect : 0, reposts);
    NativeMediaInfo.detail = detail.useful() ? '-' : 'empty';
    return detail.useful() ? detail : null;
  }

  /**
   * 一个媒体节点的图片候选 → 展示档 + 原始档（两个都是空串 = 这个节点没有图）。
   *
   * 挑档沿用 MediaQuality：展示档给卡片/轮播（1080 那一档），原始档给下载。
   */
  private static imageOf(node: MediaItemDto): ImagePick {
    const versions: ImageVersionsDto | undefined = node.image_versions2;
    const candidates: Array<VideoVersionDto> = versions === undefined
      ? [] : (versions.candidates ?? []);
    const urls: Array<string> = [];
    const widths: Array<number> = [];
    const heights: Array<number> = [];
    for (let index: number = 0; index < candidates.length; index++) {
      const one: VideoVersionDto = candidates[index];
      const url: string = one.url ?? '';
      if (url.length === 0) {
        continue;
      }
      urls.push(url);
      widths.push(one.width ?? 0);
      heights.push(one.height ?? 0);
    }
    if (urls.length === 0) {
      return new ImagePick('', '');
    }
    const display: PickedMedia = MediaQuality.displayImage(urls, widths, heights);
    const original: PickedMedia = MediaQuality.originalImage(urls, widths, heights);
    // 宽高比用**挑中的展示档**量；它没带尺寸时退回原始档（两者一般同比例）。
    const w: number = display.width > 0 ? display.width : original.width;
    const h: number = display.height > 0 ? display.height : original.height;
    const aspect: number = w > 0 && h > 0 ? w / h : 0;
    return new ImagePick(display.url, original.url, aspect);
  }

  /** 响应里作者对象的头像（读不到给空串；字段名同 NativeProfile.avatarOf）。 */
  private static avatarOf(user: MediaUserDto | undefined): string {
    if (user === undefined) {
      return '';
    }
    const direct: string = user.profile_pic_url ?? '';
    if (direct.length > 0) {
      return direct;
    }
    const hd: string = user.profile_pic_url_hd ?? '';
    if (hd.length > 0) {
      return hd;
    }
    const info: VideoVersionDto | undefined = user.hd_profile_pic_url_info;
    return info === undefined ? '' : (info.url ?? '');
  }
}
