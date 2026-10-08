/*
 * 互动接口的**包内骨架**（URL / 方法 / 操作名 / doc_id / 变量结构）。
 *
 * ## 它解决什么
 * 点赞、取消赞、转发、取消转发在 IG 上是私有 GraphQL 变更。以前它们的请求只能靠
 * "页面自己发过一次 → 原样存成模板"（core/NativeEngage），于是**新装或换会话后必须先
 * 手动做一次同类动作**才能走原生。现在骨架把"不会话相关"的那一半随包带进来，另一半
 * （lsd / fb_dtsg / jazoest / 整页指纹 / 账号 id）在需要时由 core/WebTokens 从当前页面读，
 * 两者拼起来就是一条完整请求 —— 第一次点赞就能原生直发。
 *
 * ## 哪些能预置、哪些不能
 *   能：URL、方法、`fb_api_req_friendly_name`、`doc_id`、`variables` 的字段结构；
 *   不能（会话/页面级，必须现读）：`x-csrftoken`、`x-fb-lsd`、`fb_dtsg`、`jazoest`、
 *   `__hs/__dyn/__csr/__s/__rev/__hsi`、`av`（= cookie 的 ds_user_id），
 *   以及 `/api/v1/` 那类 POST 还需要的 `x-ig-www-claim`（会话级 hmac，页面上拿不到）。
 *
 * ## doc_id 会轮换
 * `doc_id` 跟 IG 前端发版走（几天到几周）。这里预置的是真机探针抓到的值；一旦某个操作
 * 失败（服务端回错误/非 JSON），调用方会**自动回退**到"抓模板"那条路，并在抓到新模板后
 * 覆盖本地骨架（见 NativeEngage 的缓存与回写），所以过期只会让一次操作慢一点，不会失效。
 *
 * 真机样本见 .tmp/engagediag3.txt 与 .tmp/tokendiag3.txt。
 */

import { WebTokens } from './WebTokens';

/** 四个互动操作 + ayml 的骨架（值为真机探针抓到的）。 */
export class EngageSkeleton {
  /** 点赞（`/api/graphql`）。 */
  static readonly LIKE_NAME: string = 'usePolarisLikeMediaXIGLikeMutation';
  static readonly LIKE_DOC: string = '27182485238052618';
  /** 取消赞。 */
  static readonly UNLIKE_NAME: string = 'usePolarisLikeMediaXIGUnlikeMutation';
  static readonly UNLIKE_DOC: string = '27345296031770102';
  /** 转发（注意这条路是 `/graphql/query`，不是 `/api/graphql`）。 */
  static readonly REPOST_NAME: string = 'usePolarisCreateMediaRepostMutation';
  static readonly REPOST_DOC: string = '38542997498680691';
  /** 取消转发（只要 note_id）。 */
  static readonly UNREPOST_NAME: string = 'usePolarisDeleteMediaRepostMutation';
  static readonly UNREPOST_DOC: string = '26656683127335602';

  /** 三个 `/api/graphql` 变更共用的地址；转发那条单独用 /graphql/query。 */
  static readonly API_GRAPHQL: string = 'https://www.instagram.com/api/graphql';
  static readonly GRAPHQL: string = 'https://www.instagram.com/graphql/query';

  /** 网页端的 app id（探针里每个请求都带它；和信息流模板里那个一致）。 */
  static readonly WEB_APP_ID: string = '1217981644879628';
  static readonly ASBD_ID: string = '359341';

  /** 本地 doc_id 覆盖（抓到新模板时写进来；只活在内存里，进程重启回到预置值）。 */
  private static readonly docOverrides: Map<string, string> = new Map<string, string>();

  static urlOf(name: string): string {
    return name === EngageSkeleton.REPOST_NAME ? EngageSkeleton.GRAPHQL : EngageSkeleton.API_GRAPHQL;
  }

  static docOf(name: string): string {
    const hit: string | undefined = EngageSkeleton.docOverrides.get(name);
    if (hit !== undefined && hit.length > 0) {
      return hit;
    }
    if (name === EngageSkeleton.LIKE_NAME) {
      return EngageSkeleton.LIKE_DOC;
    }
    if (name === EngageSkeleton.UNLIKE_NAME) {
      return EngageSkeleton.UNLIKE_DOC;
    }
    if (name === EngageSkeleton.REPOST_NAME) {
      return EngageSkeleton.REPOST_DOC;
    }
    if (name === EngageSkeleton.UNREPOST_NAME) {
      return EngageSkeleton.UNREPOST_DOC;
    }
    return '';
  }

  /**
   * 记下"从刚抓到的模板里读到的新 doc_id/操作名"。
   *
   * 为什么要回写：IG 改前端时 doc_id 会换，模板是**唯一可靠的新值来源**；
   * 抓到时顺手更新本地骨架，之后即使模板过期（24 小时）也还能直接用骨架发。
   */
  static rememberDoc(name: string, docId: string): void {
    const key: string = name.trim();
    const doc: string = docId.trim();
    if (key.length > 0 && doc.length > 0) {
      EngageSkeleton.docOverrides.set(key, doc);
    }
  }

  /** 点赞 / 取消赞的 variables。 */
  static likeVariables(actorId: string, mediaId: string, seq: number): string {
    const input: Record<string, string> = {};
    input['actor_id'] = actorId;
    input['client_mutation_id'] = `${seq}`;
    input['container_module'] = 'feed_timeline';
    input['media_id'] = mediaId;
    const vars: Record<string, Object> = {};
    vars['input'] = input;
    return JSON.stringify(vars);
  }

  /**
   * 取消赞的 variables。
   *
   * 和点赞的差别只有 `container_module` 一项（真机抓到的取消赞样本里没有它）——
   * 多带一个字段反而可能被 Relay 的参数校验拦下，所以两边分别构造。
   */
  static unlikeVariables(actorId: string, mediaId: string, seq: number): string {
    const input: Record<string, string> = {};
    input['actor_id'] = actorId;
    input['client_mutation_id'] = `${seq}`;
    input['media_id'] = mediaId;
    const vars: Record<string, Object> = {};
    vars['input'] = input;
    return JSON.stringify(vars);
  }

  /** 转发 / 取消转发的 variables（取消转发只认 note_id）。 */
  static repostVariables(actorId: string, mediaId: string, noteId: string, seq: number): string {
    const input: Record<string, Object> = {};
    input['actor_id'] = actorId;
    input['client_mutation_id'] = `${seq}`;
    if (noteId.length > 0) {
      input['note_id'] = noteId;
    } else {
      // 转发：audience=7 / note_style=13 是网页自己发的那两个值（真机样本）。
      input['audience'] = 7;
      input['media_id'] = mediaId;
      input['note_style'] = 13;
      input['text'] = '';
    }
    const vars: Record<string, Object> = {};
    vars['input'] = input;
    return JSON.stringify(vars);
  }

  /**
   * 拼一条 GraphQL 表单请求体（字段顺序与真机抓到的样本一致）。
   *
   * 缺的指纹字段直接跳过：这些值 IG 侧大多是可选的，缺了顶多某次被拒 ——
   * 调用方失败后会回退抓模板那条路，不会卡死。
   */
  static graphqlBody(name: string, docId: string, variablesJson: string,
                     actorId: string): string {
    const parts: Array<string> = [];
    const add = (key: string, value: string): void => {
      if (value.length > 0) {
        parts.push(`${key}=${encodeURIComponent(value)}`);
      }
    };
    const req: string = Math.random().toString(36).substring(2, 4);
    add('av', actorId);
    add('__d', 'www');
    add('__user', '0');
    add('__a', '1');
    add('__req', req);
    add('__hs', WebTokens.hsValue());
    add('dpr', '3');
    add('__ccg', 'EXCELLENT');
    add('__rev', WebTokens.revValue());
    add('__s', WebTokens.sValue());
    add('__hsi', WebTokens.hsiValue());
    add('__dyn', WebTokens.dynValue());
    add('__csr', WebTokens.csrValue());
    add('__comet_req', '7');
    add('fb_dtsg', WebTokens.dtsgValue());
    add('jazoest', WebTokens.jazoest());
    add('lsd', WebTokens.lsdValue());
    add('__spin_r', WebTokens.revValue());
    add('__spin_b', WebTokens.spinBValue());
    add('__spin_t', `${Math.floor(Date.now() / 1000)}`);
    add('fb_api_caller_class', 'RelayModern');
    add('fb_api_req_friendly_name', name);
    add('server_timestamps', 'true');
    add('variables', variablesJson);
    add('doc_id', docId);
    return parts.join('&');
  }

  /**
   * 这些变更要带的请求头。
   *
   * **必须建立在 `NativeFeed.sessionHeaders()` 之上**（模板头 + Cookie + csrftoken + UA +
   * `sec-fetch-*` / `accept-language`）：真机踩过 —— 少了 `user-agent` / `sec-fetch-*`
   * 这几个"浏览器一定会带"的头，IG 会把请求当成**页面导航**，回一整个 HTML（不是 JSON），
   * 表现就是"接口明明拼对了却拿不到数据"。
   */
  private static baseHeaders(base: Record<string, string>, name: string,
                             csrf: string, cookie: string): Record<string, string> {
    const out: Record<string, string> = {};
    const keys: Array<string> = Object.keys(base);
    for (let i: number = 0; i < keys.length; i++) {
      out[keys[i]] = base[keys[i]];
    }
    out['content-type'] = 'application/x-www-form-urlencoded';
    if (cookie.length > 0) {
      out['cookie'] = cookie;
    }
    const csrfValue: string = csrf.length > 0 ? csrf : (out['x-csrftoken'] ?? '');
    if (csrfValue.length > 0) {
      out['x-csrftoken'] = csrfValue;
    }
    if (name.length > 0) {
      out['x-fb-friendly-name'] = name;
    }
    if (WebTokens.lsdValue().length > 0) {
      out['x-fb-lsd'] = WebTokens.lsdValue();
    }
    out['x-ig-app-id'] = EngageSkeleton.WEB_APP_ID;
    out['x-asbd-id'] = EngageSkeleton.ASBD_ID;
    out['x-ig-max-touch-points'] = '10';
    out['x-requested-with'] = 'XMLHttpRequest';
    out['accept'] = out['accept'] ?? '*/*';
    return out;
  }

  /** GraphQL 变更（点赞/转发）的请求头。 */
  static headers(base: Record<string, string>, name: string, csrf: string,
                 cookie: string): Record<string, string> {
    return EngageSkeleton.baseHeaders(base, name, csrf, cookie);
  }

  /** ayml（为你推荐）只要两个令牌：jazoest + fb_dtsg（真机样本就是这么短）。 */
  static aymlBody(actorId: string): string {
    const parts: Array<string> = [];
    parts.push('max_id=%5B%5D');
    parts.push('max_number_to_display=30');
    parts.push('module=discover_people');
    parts.push('paginate=true');
    parts.push(`jazoest=${WebTokens.jazoest()}`);
    parts.push(`fb_dtsg=${encodeURIComponent(WebTokens.dtsgValue())}`);
    return parts.join('&');
  }

  /** ayml 的请求头（真机样本：csrf + ajax(rev) + app-id + asbd + web-session-id + claim）。 */
  static aymlHeaders(base: Record<string, string>, csrf: string,
                     cookie: string): Record<string, string> {
    const out: Record<string, string> = EngageSkeleton.baseHeaders(base, '', csrf, cookie);
    if (WebTokens.revValue().length > 0) {
      out['x-instagram-ajax'] = WebTokens.revValue();
    }
    return out;
  }
}
