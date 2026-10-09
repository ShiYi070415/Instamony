/*
 * 限时快拍托盘（主页 feeds 流上方那条）的**原生取数**。
 *
 * 数据来源：包里预置的 `PolarisStoriesV3TrayContainerQuery` 模板（`resources/rawfile/api_templates.json`
 * 里有它）。和私信/个人页一样：**模板直发**（一次 HTTP、不碰隐藏网页），失败再让调用方决定退回回放。
 *
 * 解析**不写死键名**：托盘的键名与"看过没有"的字段名各版本不一样（`tray` / `reels_tray`、
 * `seen` / `is_seen` / `view_state`…），所以这里按结构特征找 —— 在 data 里找第一个
 * **元素带 `user` 对象的数组**，每个元素再按候选字段名逐个试；认不出来就把键树打进日志
 * （`story tray miss …`），照着日志补一处候选名即可。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { NativeFeed } from './NativeFeed';
import { JsonRead } from './JsonRead';
import { StoryItem, StoryReel, StoryTray, StoryTrayItem } from '../model/Story';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeStories';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 15000;
const SITE: string = 'https://www.instagram.com';
/**
 * 点开某个人快拍时那条私有 REST 用的是**手机 App 的身份**（安卓 UA + 安卓 app id）。
 *
 * 和私信收件箱同一条经验（见 NativeDirect.inboxRest）：这类 `/api/v1/feed/…` 是 App 接口，
 * 拿 Web 那套头打过去，IG 常常当成"未登录"回 404 + 一页 HTML。所以这两条常量在这里各留一份
 * （和 NativeDirect 里的同名常量值一致，都来自抓到的安卓端请求）。
 *
 * **但身份要多试几种**：模拟器实测这一串旧版本号被 IG 顶回来
 * （`400` + `{"message":"challenge_required","challenge":{"url":"…/web/unsupported_version/"}}`，
 * 就是嫌客户端太旧），所以 `reel()` 会依次试 [网页头, 安卓新版本号, 安卓旧版本号, 网页头]，
 * 哪一发通就用哪一发 —— 日志里 `reel http id=…` 会写清是哪种身份通的。
 */
const ANDROID_UA: string =
  'Instagram 275.0.0.27.98 Android (30/11; 420dpi; 1080x2340; samsung; SM-G991B; o1s; exynos2100; en_US; 303244333)';
/** 较新的一串安卓 UA（旧串被判"版本不支持"时用它试）。 */
const ANDROID_UA_NEW: string =
  'Instagram 334.0.0.32.93 Android (33/13; 420dpi; 1080x2340; samsung; SM-G991B; o1s; exynos2100; en_US; 303244333)';
/** 安卓 App 的 app id（和 NativeDirect.ANDROID_APP_ID 一致）。 */
const ANDROID_APP_ID: string = '567067343352427';
/** 发请求用的身份（见 ANDROID_UA 的说明）。 */
const IDENTITY_WEB: number = 0;
const IDENTITY_ANDROID_NEW: number = 1;
const IDENTITY_ANDROID_OLD: number = 2;
/** 图片快拍没有时长，按 5 秒播（和 Instagram 自己的默认一致）。 */
const IMAGE_DURATION_MS: number = 5000;
/** 视频快拍的候选时长键（秒，浮点）。 */
const DURATION_KEYS: Array<string> = ['video_duration', 'duration'];
/** 快拍数组元素的候选"媒体类型"键（2 = 视频）。 */
const MEDIA_TYPE_KEYS: Array<string> = ['media_type', 'mediaType'];
/** 托盘那条查询的操作名片段（按片段匹配，IG 改后缀也认得出）。 */
const OP_TRAY: string = 'PolarisStoriesV3';
/** "看过没有"的候选键（顺序即优先级）。 */
const SEEN_KEYS: Array<string> = ['seen', 'is_seen', 'all_seen', 'viewed', 'is_viewed'];
/** 用户名 / 头像 / id 的候选键。 */
const NAME_KEYS: Array<string> = ['username', 'user_name'];
const AVATAR_KEYS: Array<string> = ['profile_pic_url', 'profile_pic_url_hd'];
const ID_KEYS: Array<string> = ['pk', 'id', 'user_id', 'strong_id__'];

export class NativeStories {
  private static detail: string = '-';

  static lastDetail(): string {
    return NativeStories.detail;
  }

  /** 托盘那条模板在不在（按原生那条 TTL，见 NativeProfile.hasTemplate 的说明）。 */
  static hasTrayTemplate(): boolean {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    const names: Array<string> = registry.storedNames();
    for (let index: number = 0; index < names.length; index++) {
      if (names[index].indexOf(OP_TRAY) >= 0) {
        return registry.storedForNative(OP_TRAY) !== null;
      }
    }
    return false;
  }

  /**
   * 拉一次托盘（拿不到给 null）。
   *
   * 请求体**原样重发**（模板就是网页自己发过的那一发，不动它的 variables —— 托盘没有分页需求）。
   */
  static async tray(): Promise<StoryTray | null> {
    const tpl: ApiTemplate | null = ApiRegistry.getInstance().storedForNative(OP_TRAY);
    if (tpl === null) {
      NativeStories.detail = 'no-template';
      hilog.warn(DOMAIN, TAG, 'no tray template stored=%{public}s',
        ApiRegistry.getInstance().storedSummary());
      return null;
    }
    let headers: Record<string, string> = await NativeFeed.headersFor(OP_TRAY);
    if (Object.keys(headers).length === 0) {
      headers = await NativeFeed.sessionOrBrowserHeaders();
    }
    if (Object.keys(headers).length === 0) {
      NativeStories.detail = 'no-session';
      return null;
    }
    const url: string = tpl.url.startsWith('http') ? tpl.url : `${SITE}${tpl.url}`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: tpl.body ?? '',
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const json: boolean = text.indexOf('"data"') >= 0 || text.indexOf('"errors"') >= 0;
      hilog.info(DOMAIN, TAG, 'tray http code=%{public}d json=%{public}s len=%{public}d',
        response.responseCode, `${json}`, text.length);
      if (response.responseCode !== 200 || !json) {
        NativeStories.detail = `http-${response.responseCode}${json ? '' : '/non-json'}`;
        hilog.warn(DOMAIN, TAG, 'tray body: %{public}s',
          text.substring(0, 160).replace(/[\r\n]+/g, ' '));
        return null;
      }
      const tray: StoryTray | null = NativeStories.parse(text);
      if (tray === null) {
        NativeStories.detail = 'parse';
        return null;
      }
      if (tray.items.length === 0) {
        NativeStories.detail = 'empty';
        return null;
      }
      NativeStories.detail = '-';
      hilog.info(DOMAIN, TAG, 'tray ok n=%{public}d first=%{public}s seen=%{public}s',
        tray.items.length, tray.items[0].username, `${tray.items[0].seen}`);
      return tray;
    } catch (error) {
      NativeStories.detail = `throw:${(error as Error).message ?? 'request-threw'}`.substring(0, 60);
      hilog.warn(DOMAIN, TAG, 'tray failed: %{public}s', NativeStories.detail);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 响应文本 → 托盘（按结构找，见文件头）。 */
  private static parse(text: string): StoryTray | null {
    const root: Record<string, Object> = JsonRead.parse(text);
    const data: Record<string, Object> | null = JsonRead.recordOf(root, 'data');
    if (data === null) {
      NativeStories.logMiss(root, 'no-data');
      return null;
    }
    const found: Array<Object> | null = NativeStories.findTrayArray(data, 0);
    if (found === null) {
      NativeStories.logMiss(data, 'no-tray-array');
      return null;
    }
    const items: Array<StoryTrayItem> = [];
    for (let index: number = 0; index < found.length; index++) {
      const node: Record<string, Object> | null = JsonRead.asRecord(found[index]);
      if (node === null) {
        continue;
      }
      const user: Record<string, Object> | null = JsonRead.recordOf(node, 'user');
      const host: Record<string, Object> = user !== null ? user : node;
      const id: string = NativeStories.pickStr(host, ID_KEYS, '');
      if (id.length === 0) {
        continue;
      }
      const username: string = NativeStories.pickStr(host, NAME_KEYS, '');
      let avatar: string = NativeStories.pickStr(host, AVATAR_KEYS, '');
      if (avatar.length === 0) {
        const hd: Record<string, Object> | null = JsonRead.recordOf(host, 'hd_profile_pic_url_info');
        if (hd !== null) {
          avatar = JsonRead.strOf(hd, 'url');
        }
      }
      // "看过没有"：先看这一项自己，再看 user 上有没有。
      let seen: boolean = false;
      for (let at: number = 0; at < SEEN_KEYS.length; at++) {
        if (JsonRead.has(node, SEEN_KEYS[at])) {
          seen = JsonRead.boolOf(node, SEEN_KEYS[at]);
          break;
        }
        if (JsonRead.has(host, SEEN_KEYS[at])) {
          seen = JsonRead.boolOf(host, SEEN_KEYS[at]);
          break;
        }
      }
      const count: number = JsonRead.arrayOf(node, 'items').length;
      items.push(new StoryTrayItem(id, username, avatar, seen, count));
    }
    return new StoryTray(items);
  }

  /**
   * 在 data 里找"托盘数组"：元素是对象、且**带 user 对象**的那个数组（广度优先，深度封顶）。
   *
   * 不认键名（`tray` / `reels_tray` / `edges` 都可能），认结构。
   */
  private static findTrayArray(host: Record<string, Object>, depth: number): Array<Object> | null {
    if (depth > 4) {
      return null;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null && JsonRead.recordOf(first, 'user') !== null) {
          return list;
        }
      }
    }
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        const hit: Array<Object> | null = NativeStories.findTrayArray(child, depth + 1);
        if (hit !== null) {
          return hit;
        }
      }
    }
    return null;
  }

  /** 按候选键取第一个非空字符串。 */
  private static pickStr(host: Record<string, Object>, keys: Array<string>,
                         fallback: string): string {
    for (let index: number = 0; index < keys.length; index++) {
      const value: string = JsonRead.strOf(host, keys[index]);
      if (value.length > 0) {
        return value;
      }
    }
    return fallback;
  }

  /** 认不出结构时把键树打出来（照着它补候选键名）。 */
  private static logMiss(host: Record<string, Object>, why: string): void {
    const keys: Array<string> = Object.keys(host);
    const lines: Array<string> = [];
    for (let index: number = 0; index < keys.length && index < 8; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        lines.push(`${keys[index]}{${Object.keys(child).slice(0, 6).join(',')}}`);
        continue;
      }
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        lines.push(`${keys[index]}[${list.length}]${first === null ? ''
          : '{' + Object.keys(first).slice(0, 6).join(',') + '}'}`);
        continue;
      }
      lines.push(keys[index]);
    }
    hilog.info(DOMAIN, TAG, 'story tray miss why=%{public}s tree=%{public}s',
      why, lines.join(' '));
  }

  // ---------------------------------------------------------------- 播放页取数

  /**
   * 拉某个用户**当前未过期**的全部快拍（点开托盘里那一项时用；拿不到给 null）。
   *
   * 为什么不用模板：网页版那条"快拍播放页"的查询（doc_id）只有网页真的点开过某个人的快拍
   * 才会被抓到，而托盘是从首页进的 —— 手里只有托盘那条模板。所以这里走**私有 REST**
   * （App 接口），它一次就把 media 列表给全（见 fetchText / parseReel）。
   */
  static async reel(userId: string): Promise<StoryReel | null> {
    if (userId.length === 0) {
      NativeStories.detail = 'no-user';
      return null;
    }
    /*
     * 四个候选 = **两条 URL × 三种身份**（见文件头 ANDROID_UA 的说明）：
     *   ① 整体 reels + 网页身份（模板里那条，最常见能成）
     *   ② 整体 reels + 安卓新版本号
     *   ③ 整体 reels + 安卓旧版本号
     *   ④ **单用户 story** + 网页身份（老接口，纯粹当兜底）
     *
     * 审计 E8 里写的"第 4 个候选与第 1 个同 URL 同身份、纯重复请求"**在这一版代码里不成立**
     * （`urls[3]` 是 `storyUrl`，`urls[0]` 是 `reelUrl`；`git log` 显示这个数组从 init 起没改过）。
     * 那句判断是照着**上面那段旧注释**（"前四发都是那条整体 reels"）读出来的 —— 旧注释留在
     * 这里会继续误导下一次审计，所以按代码重写成现在这段。
     */
    const reelUrl: string = `${SITE}/api/v1/feed/reels_media/?reel_ids=${encodeURIComponent(userId)}&source=raven`;
    const storyUrl: string = `${SITE}/api/v1/feed/user/${encodeURIComponent(userId)}/story/`;
    const urls: Array<string> = [reelUrl, reelUrl, reelUrl, storyUrl];
    const identities: Array<number> =
      [IDENTITY_WEB, IDENTITY_ANDROID_NEW, IDENTITY_ANDROID_OLD, IDENTITY_WEB];
    for (let at: number = 0; at < urls.length; at++) {
      const text: string | null = await NativeStories.fetchText(urls[at], identities[at]);
      if (text === null) {
        continue;
      }
      const reel: StoryReel | null = NativeStories.parseReel(text, userId);
      if (reel !== null && reel.items.length > 0) {
        NativeStories.detail = '-';
        hilog.info(DOMAIN, TAG,
          'reel ok try=%{public}d id=%{public}s uid=%{public}s n=%{public}d video=%{public}s size=%{public}dx%{public}d',
          at, NativeStories.identityName(identities[at]), userId, reel.items.length,
          `${reel.items[0].isVideo()}`, reel.items[0].width, reel.items[0].height);
        return reel;
      }
      // 结构没认出来：把响应开头打出来（照着它补候选键名，见文件头）。
      hilog.info(DOMAIN, TAG, 'reel shape miss try=%{public}d body=%{public}s',
        at, text.substring(0, 220).replace(/[\r\n]+/g, ' '));
    }
    NativeStories.detail = 'empty';
    return null;
  }

  /** 身份的名字（只给日志用）。 */
  private static identityName(identity: number): string {
    if (identity === IDENTITY_ANDROID_NEW) {
      return 'android-new';
    }
    if (identity === IDENTITY_ANDROID_OLD) {
      return 'android-old';
    }
    return 'web';
  }

  /**
   * 发一发 GET，拿响应文本；非 200 / 不是 JSON 给 null。
   *
   * @param identity 用哪套身份（见 ANDROID_UA 的说明）：网页头 / 安卓新版本号 / 安卓旧版本号。
   */
  private static async fetchText(url: string, identity: number): Promise<string | null> {
    const headers: Record<string, string> = await NativeFeed.sessionOrBrowserHeaders();
    if (Object.keys(headers).length === 0) {
      NativeStories.detail = 'no-session';
      return null;
    }
    if (identity === IDENTITY_ANDROID_NEW || identity === IDENTITY_ANDROID_OLD) {
      headers['user-agent'] = identity === IDENTITY_ANDROID_NEW ? ANDROID_UA_NEW : ANDROID_UA;
      headers['x-ig-app-id'] = ANDROID_APP_ID;
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      const head: string = text.length > 0 ? text.charAt(0) : '';
      const json: boolean = head === '{' || head === '[';
      hilog.info(DOMAIN, TAG, 'reel http id=%{public}s %{public}s code=%{public}d json=%{public}s len=%{public}d',
        NativeStories.identityName(identity), url.substring(url.indexOf('/api/')),
        response.responseCode, `${json}`, text.length);
      if (response.responseCode !== 200 || !json) {
        NativeStories.detail = `http-${response.responseCode}${json ? '' : '/non-json'}`;
        hilog.info(DOMAIN, TAG, 'reel body=%{public}s',
          text.substring(0, 160).replace(/[\r\n]+/g, ' '));
        return null;
      }
      return text;
    } catch (error) {
      NativeStories.detail = `throw:${(error as Error).message ?? 'request-threw'}`.substring(0, 60);
      hilog.warn(DOMAIN, TAG, 'reel failed: %{public}s', NativeStories.detail);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 响应文本 → 某个用户的快拍（media 数组按结构找，见文件头）。 */
  private static parseReel(text: string, userId: string): StoryReel | null {
    const root: Record<string, Object> = JsonRead.parse(text);
    /*
     * 两条接口的外壳不一样：
     *   · `/feed/reels_media/`       → `{reels: {"<uid>": {items: […]}}}`
     *   · `/feed/user/<uid>/story/`  → `{reel: {items: […]}}`
     * 所以外壳不认键名，直接从根上按"结构像媒体"的数组找（findMediaArray）。
     */
    const nodes: Array<Object> | null = NativeStories.findMediaArray(root, 0);
    if (nodes === null) {
      NativeStories.logMiss(root, 'reel-no-media-array');
      return null;
    }
    const items: Array<StoryItem> = [];
    for (let index: number = 0; index < nodes.length; index++) {
      const node: Record<string, Object> | null = JsonRead.asRecord(nodes[index]);
      if (node === null) {
        continue;
      }
      const item: StoryItem | null = NativeStories.itemOf(node);
      if (item !== null) {
        items.push(item);
      }
    }
    if (items.length === 0) {
      return null;
    }
    let username: string = '';
    let avatar: string = '';
    const first: Record<string, Object> | null = JsonRead.asRecord(nodes[0]);
    if (first !== null) {
      const user: Record<string, Object> | null = JsonRead.recordOf(first, 'user');
      if (user !== null) {
        username = NativeStories.pickStr(user, NAME_KEYS, '');
        avatar = NativeStories.avatarOf(user);
      }
    }
    return new StoryReel(userId, username, avatar, items);
  }

  /** 找"媒体数组"：元素看着像一条 media 的那个数组（广度优先，深度封顶）。 */
  private static findMediaArray(host: Record<string, Object>, depth: number): Array<Object> | null {
    if (depth > 4) {
      return null;
    }
    const keys: Array<string> = Object.keys(host);
    for (let index: number = 0; index < keys.length; index++) {
      const list: Array<Object> = JsonRead.arrayOf(host, keys[index]);
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null && NativeStories.looksLikeMedia(first)) {
          return list;
        }
      }
    }
    for (let index: number = 0; index < keys.length; index++) {
      const child: Record<string, Object> | null = JsonRead.recordOf(host, keys[index]);
      if (child !== null) {
        const hit: Array<Object> | null = NativeStories.findMediaArray(child, depth + 1);
        if (hit !== null) {
          return hit;
        }
      }
    }
    return null;
  }

  /** 一个对象"像不像一条 media"（有图候选 / 有图地址 / 有 media_type）。 */
  private static looksLikeMedia(node: Record<string, Object>): boolean {
    if (JsonRead.recordOf(node, 'image_versions2') !== null) {
      return true;
    }
    if (JsonRead.strOf(node, 'display_url').length > 0) {
      return true;
    }
    for (let at: number = 0; at < MEDIA_TYPE_KEYS.length; at++) {
      if (JsonRead.has(node, MEDIA_TYPE_KEYS[at])) {
        return true;
      }
    }
    return false;
  }

  /** 一条 media → StoryItem（认不出来给 null）。 */
  private static itemOf(node: Record<string, Object>): StoryItem | null {
    let image: string = '';
    /*
     * 顺手把**这张图（或视频封面）的真实宽高**记下来：媒体区的比例要按它算，
     * 不然媒体区定死 9:16 而媒体是别的比例时，`Contain` 会在卡片里留出黑边（用户报过）。
     */
    let width: number = JsonRead.numOf(node, 'original_width');
    let height: number = JsonRead.numOf(node, 'original_height');
    const versions: Record<string, Object> | null = JsonRead.recordOf(node, 'image_versions2');
    if (versions !== null) {
      const list: Array<Object> = JsonRead.arrayOf(versions, 'candidates');
      if (list.length > 0) {
        const first: Record<string, Object> | null = JsonRead.asRecord(list[0]);
        if (first !== null) {
          image = JsonRead.strOf(first, 'url');
          if (width <= 0 || height <= 0) {
            width = JsonRead.numOf(first, 'width');
            height = JsonRead.numOf(first, 'height');
          }
        }
      }
    }
    if (image.length === 0) {
      image = NativeStories.pickStr(node, ['display_url', 'image_url', 'thumbnail_url'], '');
    }
    let video: string = '';
    const videos: Array<Object> = JsonRead.arrayOf(node, 'video_versions');
    if (videos.length > 0) {
      const first: Record<string, Object> | null = JsonRead.asRecord(videos[0]);
      if (first !== null) {
        video = JsonRead.strOf(first, 'url');
      }
    }
    if (image.length === 0 && video.length === 0) {
      return null;
    }
    let durationMs: number = IMAGE_DURATION_MS;
    if (video.length > 0) {
      let seconds: number = 0;
      for (let at: number = 0; at < DURATION_KEYS.length; at++) {
        if (JsonRead.has(node, DURATION_KEYS[at])) {
          seconds = JsonRead.numOf(node, DURATION_KEYS[at]);
          break;
        }
      }
      // 时长离谱（0 / 超大）就按默认走：宁可多停一会儿，也别让进度条一闪而过。
      if (seconds > 0.2 && seconds < 120) {
        durationMs = Math.round(seconds * 1000);
      }
    }
    const id: string = NativeStories.pickStr(node, ID_KEYS, '');
    const takenAt: number = JsonRead.numOf(node, 'taken_at');
    return new StoryItem(id.length > 0 ? id : `story-${takenAt}`, image, video, takenAt, durationMs,
      width, height);
  }

  /** 头像地址：先试直接的几个键，再试 `hd_profile_pic_url_info.url`。 */
  private static avatarOf(host: Record<string, Object>): string {
    const direct: string = NativeStories.pickStr(host, AVATAR_KEYS, '');
    if (direct.length > 0) {
      return direct;
    }
    const hd: Record<string, Object> | null = JsonRead.recordOf(host, 'hd_profile_pic_url_info');
    return hd === null ? '' : JsonRead.strOf(hd, 'url');
  }
}
