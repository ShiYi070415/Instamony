/*
 * 「收藏 / 取消收藏」一条媒体（IG 的 Save，落到账号的收藏夹里）。
 *
 * ## 端点：**在 App 的主机上**（`i.instagram.com`，不是 `www.instagram.com`）
 *   `POST https://i.instagram.com/api/v1/media/{media_id}/save/`   收藏
 *   `POST https://i.instagram.com/api/v1/media/{media_id}/unsave/` 取消收藏
 * 成功响应形如 `{"status":"ok"}`（判据与点赞/评论点赞那条一致）。
 *
 * 这条是**真机 + PC 实测**出来的（别的写法都会拿到登录页 HTML，看起来像"没登录"）：
 *   - `POST i.instagram.com/api/v1/media/1/save/`   → `200 {"message":"…","status":"fail"}`
 *     —— 路由**存在**（拿一个不存在的媒体 id 去打，服务端如实回 fail）；
 *   - `POST www.instagram.com/api/v1/media/1/save/` → `404` + 一整页 `not-logged-in` 的 HTML
 *     —— 这个路由在**网页主机上根本没有**（app 先按 App 身份打 www、又按网页身份打 www，
 *       两次都是这页 HTML，所以第一版实现报的是 `http-404`）。
 *
 * 表单体带会话令牌（`_uuid` / `_csrftoken`，见 core/RestSession.formTokens）+ 几个模块参数
 * —— 模块参数是 IG 自己客户端会带的那两个（`module_name` / `radio_type`），
 * 参考非官方实现（instagrapi 的 `media_save`：`{"module_name":"feed_timeline","radio_type":"wifi-none"}`）。
 *
 * ## 为什么要试两种身份
 * 这条端点也是**双身份**的（和评论点赞那条同一个套路，见 core/NativeComments.likeComment）：
 * 带网页 UA 打过去，IG 会回 `400 {"message":"useragent mismatch"}`；
 * 换成 App 的 UA + `x-ig-app-id` 才认。所以 **App 身份放第一个**，网页会话留作候选；
 * 谁成功记谁（`lastVia()`）。
 *
 * 会话材料走 core/RestSession：和关注 / 评论点赞 / 媒体详情完全同一套。
 */

import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RestSession } from './RestSession';
import { ApiThrottle } from './ApiThrottle';
import { ApiRegistry, ApiTemplate } from '../bridge/ApiRegistry';
import { NativeFeed } from './NativeFeed';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeSave';
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 8000;

/**
 * App 身份（和 core/NativeComments 里那条**必须一致**：IG 按 UA + app-id 认客户端）。
 *
 * 为什么不去共享一个常量：NativeComments 那份是私有的、且注释绑定在那条端点上；
 * 这里独立一份、注释写明"和评论点赞同一套身份"，改的时候两处一起改。
 */
const APP_UA: string = 'Instagram 448.0.0.52.84 Android (34/14; 480dpi; 1080x2340; '
  + 'samsung; SM-G988N; ko_KR; 483385731; 480)';
const APP_ID: string = '567067343352427';

/** 结果（`saved` 是**请求的目标状态**，失败时调用方据此回滚界面）。 */
export class SaveResult {
  readonly ok: boolean;
  readonly saved: boolean;
  readonly detail: string;

  constructor(ok: boolean, saved: boolean, detail: string) {
    this.ok = ok;
    this.saved = saved;
    this.detail = detail;
  }
}

/** 一次"改模板体"的结果：`found` = 找到了可替换的媒体 id（值可能**本来就是这个**），`text` = 改后的段。 */
class PatchResult {
  readonly text: string;
  readonly found: boolean;

  constructor(text: string, found: boolean) {
    this.text = text;
    this.found = found;
  }
}

export class NativeSave {
  /** 上一次走通的是哪条路（诊断：`appUA:save` / `web:unsave` …）。 */
  private static via: string = '-';

  static lastVia(): string {
    return NativeSave.via;
  }

  /**
   * 用**探针抓到的模板**发一次收藏 / 取消收藏（需求："所有收藏按钮都走 http 请求用探针抓模板"）。
   *
   * 为什么这是首选：页面自己发过一次之后，模板里带着**它当时用的整条请求**（URL、方法、头、
   * 完整表单体 —— 包括这条路由真正需要的会话材料）。我们只把其中的**媒体 id 换成这一条**，
   * 原样 POST 回去，和页面自己点那次一模一样。
   *
   * @returns 没有可用模板 / 发失败时给 **null**（调用方接着走下一候选）；
   *          有模板且发出去了就给 SaveResult（成功与否看 `ok`）。
   */
  static async byTemplate(mediaId: string, save: boolean): Promise<SaveResult | null> {
    NativeSave.detail = '-';
    const id: string = NativeSave.mediaIdOf(mediaId);
    if (id.length === 0) {
      return null;
    }
    // 冷却期内**直接退**（见 core/ApiThrottle）：写接口被限流时再打只会把窗口拉长。
    const cooled: string = NativeSave.cooling();
    if (cooled.length > 0) {
      NativeSave.note(cooled);
      return null;
    }
    const tpl: ApiTemplate | null = NativeSave.templateFor(save);
    if (tpl === null) {
      NativeSave.note('no-template');
      return null;
    }
    const url: string = NativeSave.patchUrl(tpl.url, id);
    const body: string = NativeSave.patchBody(tpl.body, id, save);
    if (body.length === 0 && tpl.body.length > 0) {
      // 模板体里找不到媒体 id（结构变了）：不敢乱发，交给下一候选。
      hilog.info(DOMAIN, TAG,
        'template bail: no media id in tpl=%{public}s len=%{public}d parts=%{public}d vars=%{public}d head=%{public}s',
        tpl.name, tpl.body.length, tpl.body.split('&').length,
        NativeSave.countVariables(tpl.body), tpl.body.substring(0, 160));
      NativeSave.note('template-no-media-id');
      return null;
    }
    // 头用模板里那份 + 现取的 Cookie/csrftoken（见 NativeFeed.headersFor）。
    const headers: Record<string, string> = await NativeFeed.headersFor(tpl.name);
    if (Object.keys(headers).length === 0) {
      hilog.info(DOMAIN, TAG, 'template bail: no session for tpl=%{public}s', tpl.name);
      NativeSave.note('template-no-session');
      return null;
    }
    const text: string = await NativeSave.postText(url, headers, body, 'template');
    const ok: boolean = NativeSave.looksSaved(text);
    NativeSave.via = `template:${save ? 'save' : 'unsave'}`;
    if (!ok && text.length > 0) {
      NativeSave.note('template-fail');
    }
    hilog.info(DOMAIN, TAG, 'template save ok=%{public}s tpl=%{public}s id=%{public}s detail=%{public}s',
      `${ok}`, tpl.name, id, NativeSave.detail);
    return new SaveResult(ok, save, ok ? '' : NativeSave.detail);
  }

  /**
   * 模板表里挑一条能用的收藏 / 取消收藏模板。
   *
   * 名字有两种来源（见 bridge/WebScripts 的网络钩子）：
   *   - GraphQL 那条按 `x-fb-friendly-name` 命名（形如 `usePolaris…SaveMedia…Mutation`）；
   *   - REST 那条按**路径**命名（`rest_/api/v1/media/{id}/save/`）。
   * 所以判据只看名字里有没有 `save`：**取关/取消收藏那种名字里带 `unsave` 的要排除**
   * （`'unsave'.indexOf('save') >= 0`，光看 `save` 会张冠李戴）。
   */
  private static templateFor(save: boolean): ApiTemplate | null {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    /*
     * 名字来源用 `storedNames()`（= 模板表本身的键）而**不是** `names()`（= 索引顺序表）：
     * `capture(filter)` 只往模板表里塞（`templates.set`），不维护那份顺序表 ——
     * 用 `names()` 扫的话，刚抓到的收藏模板一个都看不见（真机上就是这么"抓到了却用不上"）。
     *
     * 匹配要**收紧**：光看 `save` 会撞上 `PolarisProfileSavedPostsTabContentQuery`（"收藏分页"
     * 那条查询，名字里也有 Saved）——拿它去发收藏请求当然发不出去。判据只认
     * "媒体保存"这条变更的三种命名（真机抓到的是 `usePolarisSaveMediaSaveMutation`）。
     */
    const names: Array<string> = registry.storedNames();
    for (let index: number = 0; index < names.length; index++) {
      const name: string = names[index];
      const lower: string = name.toLowerCase();
      const isUnsave: boolean = lower.indexOf('unsave') >= 0;
      if (save === isUnsave) {
        // 要收藏却只有取消收藏的模板（或反过来）：跳过。
        continue;
      }
      const isSaveTemplate: boolean = lower.indexOf('savemedia') >= 0
        || lower.indexOf('mediasave') >= 0 || lower.indexOf('/save/') >= 0;
      const isUnsaveTemplate: boolean = lower.indexOf('unsavemedia') >= 0
        || lower.indexOf('mediaunsave') >= 0 || lower.indexOf('/unsave/') >= 0;
      if (save ? !isSaveTemplate : !isUnsaveTemplate) {
        continue;
      }
      const hit: ApiTemplate | null = registry.storedForNative(name);
      if (hit !== null) {
        return hit;
      }
    }
    return null;
  }

  /** 诊断：现在模板表里有哪些收藏相关的模板（日志里一眼看出抓没抓到）。 */
  static describeTemplates(): string {
    const registry: ApiRegistry = ApiRegistry.getInstance();
    const names: Array<string> = registry.storedNames();
    const hits: Array<string> = [];
    for (let index: number = 0; index < names.length; index++) {
      const lower: string = names[index].toLowerCase();
      if (lower.indexOf('save') >= 0) {
        hits.push(names[index]);
      }
    }
    return hits.length === 0 ? '(none)' : hits.join('|');
  }

  /** 把模板 URL 里的媒体 id 换成这一条（GraphQL 那类 URL 里没有 id，原样返回）。 */
  private static patchUrl(url: string, mediaId: string): string {
    const marker: string = '/media/';
    const at: number = url.indexOf(marker);
    if (at < 0) {
      return url;
    }
    const start: number = at + marker.length;
    let end: number = start;
    while (end < url.length) {
      const ch: string = url.charAt(end);
      if (ch < '0' || ch > '9') {
        break;
      }
      end++;
    }
    if (end === start) {
      return url;
    }
    return `${url.substring(0, start)}${mediaId}${url.substring(end)}`;
  }

  /** 诊断：模板体里有几个 `variables=` 段（见 byTemplate 的说明）。 */
  private static countVariables(body: string): number {
    const parts: Array<string> = body.split('&');
    let count: number = 0;
    for (let index: number = 0; index < parts.length; index++) {
      if (parts[index].indexOf('variables=') === 0) {
        count++;
      }
    }
    return count;
  }

  /**
   * 把模板请求体里的媒体 id 换成这一条。
   *
   * 两种形状：
   *   - REST 表单：`…&media_id=123&…` → 换掉那个值；
   *   - GraphQL 表单：`variables=<urlencoded JSON>` → 解析出来，把里面任何名字叫
   *     `media_id` / `mediaId` 的字段改成这一条（`NativeEngage` 的点赞/转发同款做法）。
   *
   * 一个都没找到时返回**空串**：宁可让调用方退到下一候选，也不要拿别人的 id 去发。
   */
  private static patchBody(body: string, mediaId: string, save: boolean): string {
    if (body.length === 0) {
      // 有的 REST 写法把参数放在 query 里，体是空的：那就没有可换的东西，照发。
      return body;
    }
    const parts: Array<string> = body.split('&');
    let patched: boolean = false;
    const out: Array<string> = [];
    for (let index: number = 0; index < parts.length; index++) {
      const part: string = parts[index];
      if (part.indexOf('media_id=') === 0) {
        out.push(`media_id=${encodeURIComponent(mediaId)}`);
        patched = true;
        continue;
      }
      if (part.indexOf('variables=') === 0) {
        const replaced: PatchResult = NativeSave.patchVariables(part, mediaId);
        // **判据是"找到了媒体 id"而不是"值变了"**：模板本来就是这条媒体抓的时，
        // 换出来的串和原来一模一样（`replaced === part`），按"变了没有"判会把这一发
        // 白扔掉 —— 真机上就是这么"抓到了模板却用不上"的（见 byTemplate 的 bail 分支）。
        if (replaced.found) {
          patched = true;
        }
        out.push(replaced.text);
        continue;
      }
      out.push(part);
    }
    return patched ? out.join('&') : '';
  }

  /** `variables=<urlencoded JSON>` 里把所有 `media_id` / `mediaId` 换成这一条。 */
  private static patchVariables(part: string, mediaId: string): PatchResult {
    try {
      const raw: string = decodeURIComponent(part.substring('variables='.length));
      const src: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const found: boolean = NativeSave.patchRecord(src, mediaId);
      if (!found) {
        return new PatchResult(part, false);
      }
      return new PatchResult(`variables=${encodeURIComponent(JSON.stringify(src))}`, true);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'patch vars failed: %{public}s', (error as Error).message);
      return new PatchResult(part, false);
    }
  }

  /** 递归把媒体 id 字段换掉（返回有没有改过）。 */
  private static patchRecord(node: Record<string, Object>, mediaId: string): boolean {
    let changed: boolean = false;
    const keys: Array<string> = Object.keys(node);
    for (let index: number = 0; index < keys.length; index++) {
      const key: string = keys[index];
      const lower: string = key.toLowerCase();
      if (lower === 'media_id' || lower === 'mediaid') {
        node[key] = mediaId;
        changed = true;
        continue;
      }
      const value: Object = node[key];
      if (Array.isArray(value)) {
        const list: Array<Object> = value as Array<Object>;
        for (let at: number = 0; at < list.length; at++) {
          const one: Record<string, Object> | null = NativeSave.asRecord(list[at]);
          if (one !== null && NativeSave.patchRecord(one, mediaId)) {
            changed = true;
          }
        }
        continue;
      }
      const child: Record<string, Object> | null = NativeSave.asRecord(value);
      if (child !== null && NativeSave.patchRecord(child, mediaId)) {
        changed = true;
      }
    }
    return changed;
  }

  /** 只是 JSON 值 → Record 的小工具（ArkTS 里 `as` 不够安全，这里判一下）。 */
  private static asRecord(value: Object | null | undefined): Record<string, Object> | null {
    if (value === null || value === undefined) {
      return null;
    }
    if (typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  /** 收藏成功没有：REST 看 `"status":"ok"`，GraphQL 看有 `"data"` 且没有 `"errors"`。 */
  private static looksSaved(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    if (text.indexOf('"status":"ok"') >= 0) {
      return true;
    }
    return text.indexOf('"data"') >= 0 && text.indexOf('"errors"') < 0;
  }

  /**
   * 收藏 / 取消收藏。
   *
   * @param mediaId 媒体数字 id（`Reel.mediaId` / `MediaPost.id` 的那一段数字）。
   * @param save    true = 收藏，false = 取消收藏。
   */
  static async setSaved(mediaId: string, save: boolean): Promise<SaveResult> {
    NativeSave.detail = '-';
    const id: string = NativeSave.mediaIdOf(mediaId);
    if (id.length === 0) {
      return new SaveResult(false, save, 'no-media-id');
    }
    /*
     * 冷却期内不发（审计 E5/E6）：以前这里会**照样打三发**（App 主机 → App 主机网页身份
     * → 网页主机），三发都撞在同一把限流锁上，只会把 12 分钟的窗口越拖越长；
     * 调用方看到的原因还是最后一发的 `http-404`，和"被限流"完全分不清。
     */
    const cooled: string = NativeSave.cooling();
    if (cooled.length > 0) {
      hilog.warn(DOMAIN, TAG, 'setSaved skipped: save family throttled %{public}dmin left',
        ApiThrottle.remainingMinutes(ApiThrottle.SAVE));
      return new SaveResult(false, save, cooled);
    }
    const headers: Record<string, string> = await RestSession.headers();
    if (Object.keys(headers).length === 0) {
      return new SaveResult(false, save, 'no-session');
    }
    const tokens: string = await RestSession.formTokens();
    const action: string = save ? 'save' : 'unsave';
    const extra: string = `media_id=${encodeURIComponent(id)}`
      + '&module_name=feed_timeline&radio_type=wifi-none';
    const body: string = tokens.length > 0 ? `${tokens}&${extra}` : extra;
    // ① App 主机 + App 身份（真机实测这条端点的正主，见文件头）。
    const appHeaders: Record<string, string> = {};
    const keys: Array<string> = Object.keys(headers);
    for (let index: number = 0; index < keys.length; index++) {
      appHeaders[keys[index]] = headers[keys[index]];
    }
    appHeaders['user-agent'] = APP_UA;
    appHeaders['x-ig-app-id'] = APP_ID;
    const appUrl: string = `https://i.instagram.com/api/v1/media/${encodeURIComponent(id)}/${action}/`;
    if (await NativeSave.post(appUrl, appHeaders, body, 'app-host')) {
      NativeSave.via = `app:${action}`;
      return new SaveResult(true, save, '');
    }
    // ② 同一个 App 主机、但用网页会话（IG 把这条收回网页实现时用）。
    //    第一发要是**当场认出了限流**，后面两发就别打了（同一把锁，打也是白挨）。
    if (NativeSave.cooling().length > 0) {
      return new SaveResult(false, save, NativeSave.detail);
    }
    if (await NativeSave.post(appUrl, headers, body, 'app-host-web')) {
      NativeSave.via = `app-web:${action}`;
      return new SaveResult(true, save, '');
    }
    // ③ 网页主机 + App 身份（今天实测是 404，留着以防 IG 挪回去）。
    if (NativeSave.cooling().length > 0) {
      return new SaveResult(false, save, NativeSave.detail);
    }
    const webUrl: string = `https://www.instagram.com/api/v1/media/${encodeURIComponent(id)}/${action}/`;
    if (await NativeSave.post(webUrl, appHeaders, body, 'web-host-app')) {
      NativeSave.via = `web-app:${action}`;
      return new SaveResult(true, save, '');
    }
    hilog.info(DOMAIN, TAG, 'setSaved failed id=%{public}s save=%{public}s', id, `${save}`);
    return new SaveResult(false, save, NativeSave.detail);
  }

  /** 媒体 id 规整：`3991085364986982562_7419457815` 这种带下划线的只取前半段。 */
  private static mediaIdOf(raw: string): string {
    const text: string = raw.trim();
    const cut: number = text.indexOf('_');
    return cut > 0 ? text.substring(0, cut) : text;
  }

  /**
   * 上一次失败的细节（诊断）。
   *
   * **每次入口（byTemplate / setSaved）先清成 `'-'`**，并且写入走 `note()`（先到先得）：
   * 一条收藏要依次试"模板 → App 主机 → 网页主机"几个候选，每个候选内部又会写自己的原因；
   * 直接赋值会让**最后一个**候选那句信息量最低的 `http-404` 盖掉前面更有用的
   * `template-no-media-id` / `rate-limited`（审计 E6：真机日志上看到的就是这个假象）。
   * 而且它是 static：不重置的话，上一次调用的原因会**串**到这一次。
   */
  private static detail: string = '-';

  /** 记下一次失败的细节：**先到先得**（已经有具体原因就不再覆盖）。 */
  private static note(detail: string): void {
    if (NativeSave.detail !== '-') {
      return;
    }
    NativeSave.detail = detail;
  }

  /**
   * 这个家族还在限流冷却里吗（见 core/ApiThrottle）。
   *
   * @returns 空串 = 可以发；非空 = 给调用方当失败原因的那句话。
   */
  private static cooling(): string {
    if (!ApiThrottle.blocked(ApiThrottle.SAVE)) {
      return '';
    }
    return `throttled-${ApiThrottle.remainingMinutes(ApiThrottle.SAVE)}min`;
  }

  /** 发一次写请求（POST，表单体）；成功 = HTTP 200 + 响应里有 `"status":"ok"`。 */
  private static async post(url: string, headers: Record<string, string>, body: string,
                            tag: string): Promise<boolean> {
    const text: string = await NativeSave.postText(url, headers, body, tag);
    if (text.length === 0) {
      return false;
    }
    return text.indexOf('"status":"ok"') >= 0;
  }

  /** 发一次 POST（表单体），返回响应文本（失败给空串）。 */
  private static async postText(url0: string, headers: Record<string, string>, body: string,
                                tag: string): Promise<string> {
    /*
     * 模板里的 URL 是**页面视角的相对路径**（`/api/graphql`、`/api/v1/media/…/save/`）：
     * 直接交给 `http.request` 会抛（invalid url），表现就是"模板明明抓到了却发不出去"。
     * 这里补成绝对地址（同 NativeEngage.postRaw 的做法）。
     */
    const url: string = url0.indexOf('http') === 0
      ? url0 : `https://www.instagram.com${url0.charAt(0) === '/' ? '' : '/'}${url0}`;
    const merged: Record<string, string> = {};
    const keys: Array<string> = Object.keys(headers);
    for (let index: number = 0; index < keys.length; index++) {
      merged[keys[index]] = headers[keys[index]];
    }
    merged['content-type'] = 'application/x-www-form-urlencoded';
    merged['x-requested-with'] = 'XMLHttpRequest';
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.POST,
        header: merged,
        extraData: body,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const text: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      hilog.info(DOMAIN, TAG, 'rsp %{public}s code=%{public}d len=%{public}d body=%{public}s',
        tag, response.responseCode, text.length,
        text.substring(0, 120).replace(/[\r\n]+/g, ' '));
      // 被限流：认出来就退避（见 core/ApiThrottle）。
      if (ApiThrottle.looksLimited(text)) {
        ApiThrottle.note(ApiThrottle.SAVE);
        NativeSave.note('rate-limited');
        return '';
      }
      if (response.responseCode === 200) {
        return text;
      }
      NativeSave.note(`http-${response.responseCode}`);
      return '';
    } catch (error) {
      NativeSave.note(`throw:${(error as Error).message ?? 'request-threw'}`.substring(0, 60));
      return '';
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }
}
