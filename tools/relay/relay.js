#!/usr/bin/env node
/*
 * Instamony BYO 中转 —— **跨平台低功耗版**（Windows / Linux / Android-Termux 同一份文件）
 *
 * 干什么：低频、只读地看一眼 IG 收件箱；有新私信就推到你手机。
 * 不干什么：不发消息、不点赞、不关注；不存聊天正文（state.json 只有"每条会话最后一条消息 id + 时间戳"）。
 *
 * 为什么省电（这几条是本版的重点，改之前请先看）：
 *   1. **连接复用**：一个 keepAlive Agent 走到底 —— 每轮不再重新 TLS 握手（这是长时间轮询里
 *      最费电的一步，握手比一次小响应贵得多）；
 *   2. **gzip**：带 `Accept-Encoding: gzip`，几十 KB 的收件箱压到几 KB，无线电唤醒时间更短；
 *   3. **自适应间隔**：有动静就按 `activeSeconds`（默认 90 秒），一直没动静就逐步退到
 *      `idleMaxSeconds`（默认 5 分钟）—— 深夜没人发消息时几乎不耗电；
 *   4. **不做无谓的磁盘写**：state 只在真的变了才落盘（并且是 tmp+rename 原子替换）；
 *   5. **一轮一批**：同一轮里有多条新私信只推一条汇总，避免手机被连续唤醒 N 次；
 *   6. **安静时段**：`quietHours` 内只记账不推送（也不会攒着早上一次性弹出来）。
 *
 * 用法：
 *   node relay.js            # 常驻
 *   node relay.js --once     # 只跑一轮，验配置
 *   node relay.js --quiet    # 只打警告和错误
 *
 * 依赖：只要 Node ≥ 14（零 npm 依赖）。Android 上装在 Termux 里（见 README）。
 */

'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const zlib = require('zlib');
const querystring = require('querystring');

/*
 * 收件箱地址：**移动端私有接口**（`i.instagram.com`），不是网页那条。
 *
 * 为什么会换：网页的 `www.instagram.com/api/v1/direct_v2/inbox/` 用这套会话会话
 * 直接回 **HTTP 404 + `class="no-js not-logged-in"` 的 HTML**（不是 401，很有迷惑性）——
 * 也就是说网页那条路对这个会话已经关了。而移动端接口 + `Authorization: IGT:2:<base64>`
 * 一次就 200，返回完整收件箱。
 *
 * 依据：App 自己早就走这条路（`core/mobileapi/*`，从 instagrapi 移植），
 * `INSTAGRAPI_PORT.md` 里也写明「用网页会话打移动 API 是一等公民」：
 * 把 `{ds_user_id, sessionid, should_use_header_over_cookies:true}` base64 进
 * `Authorization: Bearer IGT:2:`，就等价于移动端登录态。
 */
const INBOX_URL = 'https://i.instagram.com/api/v1/direct_v2/inbox/';
/** instagrapi 的 `app_id`（移动端 Instagram 的 X-IG-App-ID）。 */
const MOBILE_APP_ID = '567067343352427';
/** 移动端 UA 模板（instagrapi 同款；网页 UA 打这个接口会被认成伪造）。 */
const MOBILE_UA =
  'Instagram 448.0.0.52.84 Android (34/14; 480dpi; 1080x2400; samsung; SM-G991B; ' +
  'o1s; exynos2100; en_US; 269890874)';
/** 网页 UA（只在排错时用得到，正常路径不用）。 */
const DEFAULT_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const MIN_POLL_SECONDS = 60;
/** 官方文档：HarmonyOS 5+ 只认服务账号 JWT + v3 接口（v2 只服务 3.x/4.x）。 */
const PUSH_SEND = 'https://push-api.cloud.huawei.com/v3/%s/messages:send';
const SA_SCOPE_AUD = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
/** 默认去隔壁 agc 工具目录找服务账号密钥，省得每处都配一遍。 */
const DEFAULT_SA_FILE = path.join(__dirname, '..', 'agc', 'private.json');

/** keepAlive Agent：整轮轮询只建一次连接（省电的主要来源，别改成每发新建）。 */
const agent = new https.Agent({ keepAlive: true, keepAliveMsecs: 120000, maxSockets: 2 });

let quiet = false;

function log(msg) {
  if (quiet) return;
  const stamp = new Date().toTimeString().slice(0, 8);
  console.log('[' + stamp + '] ' + msg);
}

function warn(msg) {
  const stamp = new Date().toTimeString().slice(0, 8);
  console.error('[' + stamp + '] ' + msg);
}

function die(msg) {
  console.error(msg);
  process.exit(2);
}

/* ------------------------------------------------------------------ 配置 */

function configPath() {
  const at = process.argv.indexOf('--config');
  if (at >= 0 && process.argv[at + 1]) return path.resolve(process.argv[at + 1]);
  return path.join(__dirname, 'config.json');
}

function loadConfig() {
  const file = configPath();
  if (!fs.existsSync(file)) {
    /*
     * `--report-only` 是"只收 token"的调试模式，不碰 IG、不需要 cookie/通道配置。
     * 所以没 config.json 也让它跑起来（否则想验证上报还得先抄一份配置模板，太绕）。
     */
    if (process.argv.indexOf('--report-only') >= 0) {
      warn('没有 ' + file + '，按 --report-only 的空配置跑（只验上报，不推任何东西）。');
      return { notify: { channel: 'agc' }, listen: {}, ig: {} };
    }
    die('找不到 ' + file + ' —— 先 cp config.example.json config.json 再填。');
  }
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  const notify = cfg.notify || {};
  const channel = notify.channel || 'agc';
  if (channel === 'agc') {
    const agc = notify.agc || {};
    if (agc.clientId || agc.clientSecret) {
      warn('notify.agc 里的 clientId/clientSecret 已经作废（HarmonyOS 5+ 不再支持 OAuth 2.0 开放鉴权，'
        + 'v1 接口也停用了）。这两个字段会被忽略，请改用 serviceAccountFile。');
    }
    if (!notify.pushToken && readTokenFile() === null) {
      // 配了上报端口就不算错：先起来，等 App 把 token 报上来。
      const canReport = Number((cfg.listen && cfg.listen.port) || 0) > 0
        || process.argv.indexOf('--listen') >= 0;
      if (!canReport) {
        die('channel=agc 但既没有 pushToken，也没有 App 上报过的 token。'
          + '\n要么先把 App 里复制出来的 token 填进 notify.pushToken，'
          + '\n要么配 listen.port 让 App 自己上报。');
      }
      log('还没有 pushToken：等 App 上报（POST /token）之后才能推。');
    }
    const saFile = resolveServiceAccountFile(agc);
    if (!fs.existsSync(saFile)) {
      die('找不到服务账号密钥文件 ' + saFile
        + '\n去 AGC → API Console 创建「服务账号密钥」凭证，下载推送服务 API 的 json。');
    }
  } else if (channel === 'meow') {
    if (!(notify.meow && notify.meow.nickname)) die('channel=meow 但没填昵称。');
  } else if (channel === 'telegram') {
    if (!(notify.telegram && notify.telegram.botToken && notify.telegram.chatId)) {
      die('channel=telegram 但 botToken/chatId 没填。');
    }
  } else if (channel === 'webhook') {
    if (!(notify.webhook && notify.webhook.url)) die('channel=webhook 但 url 没填。');
  } else {
    die('未知的 notify.channel: ' + channel);
  }
  return cfg;
}

/** IG cookie 只有"真的要轮询"时才需要，--test-push 不碰它。 */
function requireIgCookie(cfg) {
  const cookie = (cfg.ig && cfg.ig.cookie) || '';
  if (cookie.length < 20) {
    die('config.ig.cookie 无效：先到 App「设定 → 诊断 → 复制中转材料」。');
  }
}

/* ------------------------------------------------------------- HTTP 小工具 */

function request(url, options, body) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const headers = Object.assign({ 'Accept-Encoding': 'gzip' }, (options && options.headers) || {});
    const req = https.request({
      hostname: target.hostname,
      path: target.pathname + target.search,
      method: (options && options.method) || 'GET',
      headers: headers,
      agent: agent,
      timeout: 30000
    }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const raw = Buffer.concat(chunks);
        const gz = String(res.headers['content-encoding'] || '').indexOf('gzip') >= 0;
        const done = (buf) => resolve({ status: res.statusCode || 0, body: buf.toString('utf8') });
        if (gz) {
          zlib.gunzip(raw, (error, out) => done(error ? raw : out));
        } else {
          done(raw);
        }
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function csrfOf(cookie) {
  return cookieValueOf(cookie, 'csrftoken');
}

/** 从 Cookie 串里取一个字段（`name=value; name2=value2` 那种）。 */
function cookieValueOf(cookie, name) {
  for (const part of cookie.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return '';
}

/**
 * `Authorization: Bearer IGT:2:<base64url({ds_user_id,sessionid,should_use_header_over_cookies})>`
 *
 * 这就是"网页会话当移动会话用"的那把钥匙：`should_use_header_over_cookies` 必须是
 * **真布尔**，意思是"请优先认这个头，别只认 Cookie 罐"。
 * （App 侧同一个构造见 `core/mobileapi/MobileSession.buildAuthorization`。）
 */
function mobileAuthorization(cookie) {
  const userId = cookieValueOf(cookie, 'ds_user_id');
  const sessionId = decodeURIComponent(cookieValueOf(cookie, 'sessionid'));
  if (userId.length === 0 || sessionId.length === 0) {
    return '';
  }
  const payload = JSON.stringify({
    ds_user_id: userId,
    sessionid: sessionId,
    should_use_header_over_cookies: true
  });
  return 'Bearer IGT:2:' + Buffer.from(payload).toString('base64url');
}

/* --------------------------------------------------------------- 拉收件箱 */

/** 本机这套"移动设备身份"的缓存（首次生成、之后稳定，见 realtime.js）。 */
let deviceIdentityCache = null;

/**
 * 本机这套"移动设备身份"（`mqtt-device.json`）。
 *
 * 实时通道和 HTTP 请求必须共用同一套，否则 iris 订阅会因为"快照不是这台设备报的"被拒。
 */
function deviceIdentity() {
  if (deviceIdentityCache === null) {
    deviceIdentityCache = require('./realtime.js').loadDeviceIdentity(__dirname);
  }
  return deviceIdentityCache;
}

/**
 * 拉一次收件箱，**连订阅位点一起**返回。
 *
 * `seq_id` / `snapshot_at_ms` 是实时通道的唯一门槛（instagrapi 的
 * `direct_subscribe` 就是从收件箱响应顶层读这两个值），所以顺手带出来，
 * 免得为了拿它们再打一次请求。
 */
async function fetchInboxRaw(cfg, options) {
  const cookie = cfg.ig.cookie;
  const ig = cfg.ig || {};
  const opts = options || {};
  const query = querystring.stringify({
    /*
     * **窗口大小决定会不会"吞消息"**。
     *
     * 原来 `limit=15 / thread_message_limit=2`：只回 15 个会话、每个会话最后 2~3 条。
     * 于是"两轮之间连发 5 条"只能看到最后几条，前面的永久看不到 —— 这就是吞消息。
     * 现在默认 30 个会话 / 每个会话 20 条；另外把"窗口里最旧一条比上次记录还新"
     * 当作**可能有空洞**，去该会话详情页回填（见 backfillThread / neededBackfill）。
     */
    limit: String(Number(opts.limit || ig.inboxLimit || 30)),
    thread_message_limit: String(Number(opts.messageLimit || ig.threadMessageLimit || 20)),
    visual_message_return_type: 'unseen',
    persistentBadging: 'true'
  });
  const authorization = mobileAuthorization(cookie);
  if (authorization.length === 0) {
    warn('Cookie 里缺 ds_user_id / sessionid —— 这不是一份完整的 IG 会话，'
      + '请在 App「设定 → 诊断 → 复制中转材料」重新导出。');
    process.exit(3);
  }
  let res;
  try {
    const headers = {
      Cookie: cookie,
      Authorization: authorization,
      'User-Agent': MOBILE_UA,
      'X-IG-App-ID': MOBILE_APP_ID,
      // 移动端身份里几条"固定串"：缺了 IG 会当成伪造客户端。
      'X-IG-Capabilities': '3brTv10=',
      'X-IG-Connection-Type': 'WIFI',
      'X-IG-WWW-Claim': '0',
      'X-CSRFToken': csrfOf(cookie),
      Accept: '*/*'
    };
    /*
     * **设备身份要跟实时通道那边用同一套**（`mqtt-device.json`）。
     *
     * 真实客户端有三条不同的 id：`X-IG-Device-ID`=uuid、`X-IG-Android-ID`=16 位十六进制、
     * `X-IG-Family-Device-ID`=phoneId（MQTT 的 deviceId 也是它）。
     * 第一次我把三条填成同一个值，iris 订阅直接被拒；改成各按各的才有希望。
     */
    const device = deviceIdentity();
    headers['X-IG-Device-ID'] = device.uuid;
    headers['X-IG-Android-ID'] = device.androidId;
    headers['X-IG-Family-Device-ID'] = device.phoneId;
    const mid = cookieValueOf(cookie, 'mid');
    if (mid.length > 0) {
      headers['X-MID'] = mid;
    }
    // 移动端身份的其余几条"固定串"（缺了容易被判伪造客户端）
    headers['X-IG-App-Locale'] = 'en_US';
    headers['X-IG-Device-Locale'] = 'en_US';
    headers['X-IG-Mapped-Locale'] = 'en_US';
    headers['X-IG-Timezone-Offset'] = String(-new Date().getTimezoneOffset() * 60);
    headers['X-Bloks-Version-Id'] =
      '799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b';
    headers['X-Bloks-Is-Layout-RTL'] = 'false';
    headers['X-Bloks-Is-Panorama-Enabled'] = 'true';
    headers['X-FB-HTTP-Engine'] = 'Tigon/MNS/TCP';
    headers['X-Tigon-Is-Retry'] = 'False';
    headers['X-Zero-Balance'] = 'INIT';
    headers['X-Zero-State'] = 'unknown';
    headers['Priority'] = 'u=3';
    res = await request(INBOX_URL + '?' + query, { headers: headers });
  } catch (error) {
    log('IG 请求失败，本轮跳过：' + error.message);
    return { threads: [], seqId: 0, snapshotAtMs: 0 };
  }
  if (res.status === 401 || res.status === 403 || res.body.indexOf('login_required') >= 0) {
    warn('IG 拒绝：会话失效（HTTP ' + res.status + '）。'
      + '重跑 `node relay.js --login` 即可（会开浏览器让你重新登录并自动写回配置）；'
      + '也可以去手机 App「复制中转材料」手工粘贴。');
    process.exit(3);
  }
  if (res.status === 404 && res.body.indexOf('not-logged-in') >= 0) {
    // 这是"网页那条路"的特征响应。走移动端接口不该再出现，出现基本就是地址写错了。
    warn('IG 回 404 + not-logged-in：请求打到网页接口了（应该是 i.instagram.com 的移动端接口）。');
    return { threads: [], seqId: 0, snapshotAtMs: 0 };
  }
  if (res.status !== 200) {
    log('IG HTTP ' + res.status + '，本轮跳过：' + res.body.slice(0, 140));
    return { threads: [], seqId: 0, snapshotAtMs: 0 };
  }
  let data;
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    log('IG 回的不是 JSON，本轮跳过：' + res.body.slice(0, 140));
    return { threads: [], seqId: 0, snapshotAtMs: 0 };
  }
  return {
    threads: (data.inbox || {}).threads || [],
    seqId: Number(data.seq_id || 0),
    snapshotAtMs: Number(data.snapshot_at_ms || 0)
  };
}

/**
 * **轻量探测**：只取最近 3 个会话、每会话 3 条（实测 13KB / 316ms）。
 *
 * 为什么这样也能发现新消息：IG 的收件箱是**按最后活跃时间排序**的，
 * 任何会话来了新消息都会顶到最前面 —— 所以只看前几个就能判断"有没有动静"，
 * 不用每次拉 30×20 的大响应（261KB）。体积约是它的 1/20。
 */
async function probeInbox(cfg) {
  const raw = await fetchInboxRaw(cfg, { limit: 3, messageLimit: 3 });
  return raw.threads;
}

/** 探测结果里有没有"比记录更新的东西"（含从没见过的会话）。 */
function probeChanged(threads, state) {
  for (const thread of threads) {
    const threadId = String(thread.thread_id || thread.thread_v2_id || '');
    if (threadId.length === 0) continue;
    const items = thread.items || [];
    if (items.length === 0) continue;
    const last = state[threadId];
    if (last === undefined) return true;        // 新会话
    const lastTs = Number(last.ts || 0);
    for (const item of items) {
      if (Number(item.timestamp || 0) > lastTs) return true;
    }
  }
  return false;
}

/** 只要会话列表（老的调用方式）。 */
async function fetchInbox(cfg) {
  const raw = await fetchInboxRaw(cfg);
  return raw.threads;
}

/**
 * 拉某个会话的一页消息 —— **只用于回填空洞**。
 *
 * 什么时候需要：两轮之间同一个人连发 N 条，而 N 超过了收件箱窗口里的
 * `thread_message_limit`（尽管已提到 20，仍可能超）。这时收件箱里最旧的一条
 * 都比我们上次记录的更新，说明中间有消息没看到 —— 到会话详情页补一页。
 *
 * 失败一律返回空数组：回填是"锦上添花"，不能因为它把一轮搞崩。
 */
async function fetchThreadItems(cfg, threadId, limit) {
  const cookie = cfg.ig.cookie || '';
  const authorization = mobileAuthorization(cookie);
  if (authorization.length === 0) return [];
  const query = querystring.stringify({
    limit: String(Number(limit || (cfg.ig && cfg.ig.backfillLimit) || 50)),
    visual_message_return_type: 'unseen'
  });
  const device = deviceIdentity();
  const headers = {
    Cookie: cookie,
    Authorization: authorization,
    'User-Agent': MOBILE_UA,
    'X-IG-App-ID': MOBILE_APP_ID,
    'X-IG-Capabilities': '3brTv10=',
    'X-IG-Connection-Type': 'WIFI',
    'X-IG-WWW-Claim': '0',
    'X-CSRFToken': csrfOf(cookie),
    'X-IG-Device-ID': device.uuid,
    'X-IG-Android-ID': device.androidId,
    'X-IG-Family-Device-ID': device.phoneId,
    Accept: '*/*'
  };
  try {
    const res = await request(
      `https://i.instagram.com/api/v1/direct_v2/threads/${encodeURIComponent(threadId)}/?${query}`,
      { headers: headers });
    if (res.status !== 200) {
      log('回填失败（HTTP ' + res.status + '）：' + res.body.slice(0, 120));
      return [];
    }
    const data = JSON.parse(res.body);
    const thread = data.thread || {};
    const items = thread.items || [];
    log('回填到 ' + items.length + ' 条');
    return items;
  } catch (error) {
    log('回填异常：' + error.message);
    return [];
  }
}

/* ------------------------------------------------------------------ 状态 */

function loadState(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return {};
  }
}

function saveState(file, state) {
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

const KIND_TEXT = {
  media_share: '[分享的帖子]',
  xma_media_share: '[分享的帖子]',
  clip: '[分享的 Reels]',
  xma_clip: '[分享的 Reels]',
  reel_share: '[分享的 Reels]',
  reel_media: '[Reels]',
  link: '[链接]',
  media: '[图片/视频]',
  voice_media: '[语音]',
  animated_media: '[动图]',
  raven_media: '[阅后即焚]',
  like: '[赞了你的消息]'
};

/**
 * 一条会话里**最新的一条消息**（顺带带上判重需要的标识）。
 *
 * ## 为什么要 `otid`
 * IG 的私信有"双发"机制（`is_ae_dual_send`，端到端加密迁移期的兼容措施）：
 * **同一条消息**会生成两个 item，`item_id` 不同但 `otid`（operation id）相同。
 * 只按 `item_id` 判重就会把同一条消息推两次 —— 这就是"同一消息推两遍"的根因。
 * 所以判重键用 `otid || item_id`，并且把它一起带出去（服务端 `appMessageId` 也用这个）。
 */
function newestOf(thread) {
  const items = thread.items || [];
  let best = null;
  for (const item of items) {
    const stamp = Number(item.timestamp || 0);
    if (best !== null && stamp <= best.ts) continue;
    let text = item.text || '';
    if (!text) text = KIND_TEXT[item.item_type] || '[消息]';
    const viewerId = thread.viewer_id ? String(thread.viewer_id) : '';
    const mine = !!(viewerId && item.user_id && String(item.user_id) === viewerId);
    const itemId = String(item.item_id || '');
    const otid = String(item.otid || '');
    best = {
      id: itemId,
      // 判重键：同一条消息的双发共享 otid（没有 otid 时退回 item_id）
      key: otid.length > 0 ? otid : itemId,
      ts: stamp,
      text: text.slice(0, 120),
      mine: mine,
      userId: String(item.user_id || '')
    };
  }
  return best;
}

/* ------------------------------------------------- 自分类 IM 合规过滤 */

/**
 * 为什么要"过滤"而不是"能发就发"：
 * 我们给通知消息申请的 category 是 IM（即时聊天）。官方对 IM 的硬性承诺是
 * **只包含互相关注用户之间的点对点私信**，明确排除：未关注人的私信请求
 * （message request / 首次搭话）、官方号或商家批量推送、任何广告内容。
 * 违反分类标准会按《通知违规处罚标准》处理（轻则收回权益、重则判违规），
 * 所以宁可不推，也不要为了一条陌生人的私信把 IM 权益搞掉。
 *
 * 判据都是"保守方向"的：拿不准就当消息请求，不推。
 */

/**
 * 线程标了 pending / 需要审批 —— Instagram 对陌生人首条的处理方式。
 *
 * 字段名是**实测**的（`i.instagram.com` 移动端收件箱返回体，2026-10 抓的）：
 * 有 `pending`（布尔）、`pending_user_ids`、`pending_users`、`total_pending_users`、
 * `has_reached_message_request_limit`、`spam`；**没有** `is_pending`（网页版老字段，留着兜底）。
 */
function looksLikeMessageRequest(thread) {
  if (thread.pending === true) return true;
  if (thread.is_pending === true) return true;
  if (thread.approval_factor !== undefined && thread.approval_factor !== null) return true;
  if (Array.isArray(thread.pending_user_ids) && thread.pending_user_ids.length > 0) return true;
  return false;
}

/**
 * 已被 IG 判为垃圾/骚扰的会话。
 *
 * 对应 IM 分类里"不得推送官方号/商家批量、广告"那半句：落进 spam 的会话
 * 不是用户想收的对话，宁可不推。
 */
function looksLikeSpam(thread) {
  return thread.spam === true || thread.is_spam === true;
}

/**
 * 是否"已有历史往来"。
 * 收件箱请求带 thread_message_limit=2，最多回两条消息：
 *   - 回来的只有 1 条 → 这就是这条会话的第一条消息（首次搭话 / 消息请求），不推；
 *   - 回来 2 条 → 说明前面还有消息，属正常往来，可以推。
 */
function hasConversationHistory(thread) {
  return (thread.items || []).length >= 2;
}

/**
 * 返回空串表示可以推，否则返回跳过原因（会打进日志，便于事后核对）。
 * 顺序有意义：先认消息请求，再认"没有历史"。
 */
function complianceVerdict(thread) {
  if (looksLikeSpam(thread)) return 'spam';
  if (looksLikeMessageRequest(thread)) return 'message-request';
  if (!hasConversationHistory(thread)) return 'no-history';
  return '';
}

/* ------------------------------------------------------------- 安静时段 */

function inQuietHours(cfg) {
  const q = cfg.notify && cfg.notify.quietHours;
  if (!q || !Array.isArray(q) || q.length !== 2) return false;
  const hour = new Date().getHours();
  const from = Number(q[0]);
  const to = Number(q[1]);
  if (from === to) return false;
  return from < to ? (hour >= from && hour < to) : (hour >= from || hour < to);
}

/* ------------------------------------------------------------------ 推送 */

/** 服务账号密钥文件路径：配置优先，否则用 tools/agc/private.json。 */
function resolveServiceAccountFile(agc) {
  const name = (agc && agc.serviceAccountFile) || DEFAULT_SA_FILE;
  return path.isAbsolute(name) ? name : path.resolve(__dirname, name);
}

function loadServiceAccount(agc) {
  const file = resolveServiceAccountFile(agc);
  const sa = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!sa.private_key) throw new Error(file + ' 里找不到 private_key');
  return sa;
}

/**
 * 服务账号 JWT（PS256）——按官方文档：header 带 kid=key_id、alg=PS256，
 * payload 的 iss=sub_account、aud 固定、exp=iat+3600。这个 JWT 本身**就是**
 * Authorization 里的 Bearer，不用再换 access_token。
 *
 * 有效期一小时，所以缓存起来：轮询每分钟一轮，没必要每轮都 RSA 签一次。
 */
let jwtCache = { value: '', exp: 0 };

function serviceJwt(sa) {
  const crypto = require('crypto');
  const now = Math.floor(Date.now() / 1000);
  if (jwtCache.value && jwtCache.exp - 60 > now) return jwtCache.value;
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const signingInput = b64({ kid: sa.key_id, typ: 'JWT', alg: 'PS256' })
    + '.' + b64({ aud: SA_SCOPE_AUD, iss: sa.sub_account, iat: now, exp: now + 3600 });
  const signature = crypto.sign('sha256', Buffer.from(signingInput), {
    key: String(sa.private_key).replace(/\\n/g, '\n'),
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST
  }).toString('base64url');
  jwtCache = { value: signingInput + '.' + signature, exp: now + 3600 };
  return jwtCache.value;
}

/**
 * 判重键 → 稳定的**通知 id**（0 ~ 2^31-1）。
 *
 * 需求："每条通知都要显示，堆叠可展开"。所以**每条消息一个 notifyId**：
 * 不同消息 = 不同通知，在通知中心里一条条堆起来；同一条消息下次再来也只会覆盖
 * 自己那一条，不会重复堆。
 *
 * （早先按"会话"算 notifyId，同会话的新消息会覆盖旧通知 —— 那正是"只显示最新一条"的原因。）
 */
function notifyIdOf(itemKey) {
  let sum = 0;
  const text = String(itemKey || '');
  for (let index = 0; index < text.length; index++) {
    sum = (sum * 31 + text.charCodeAt(index)) % 2147483647;
  }
  return sum > 0 ? sum : 1;
}

async function pushAgc(cfg, title, body, threadId, itemKey) {
  const agc = cfg.notify.agc || {};
  const sa = loadServiceAccount(agc);
  const projectId = sa.project_id || agc.projectId;
  if (!projectId) throw new Error('服务账号密钥文件里没有 project_id，拼不出 v3 地址');
  /*
   * `appMessageId` 是**服务端的 24 小时去重**：同一 appMessageId 的消息只展示最早一条。
   * 用它兜住"客户端状态丢了再推一次"（比如 relay 重启、state 被清）。
   *
   * ⚠️ 字符集有硬限制：官方只允许**大小写字母、数字、`+`、`/`、`=`、`-`、`_` 和空白**，
   * 长度 [1,64]。我第一次写成 `会话:otid`，冒号不合法，被服务端整条拒收：
   *   `80100003 Illegal payload, payload.notification invalid appMessageId`
   * 表现是"完全收不到消息"—— 这种错只能靠看回包发现（HTTP 200 但 code 非 80000000）。
   */
  const rawMessageId = `${threadId}_${itemKey}`;
  const messageKey = /^[A-Za-z0-9+/=_\-\s]{1,64}$/.test(rawMessageId)
    ? rawMessageId : String(notifyIdOf(rawMessageId));
  const payload = JSON.stringify({
    payload: {
      notification: {
        category: agc.category || 'IM',
        title: title,
        body: body,
        clickAction: { actionType: 0, data: { threadId: threadId } },
        style: 0,
        // 每条消息各自一条通知（堆叠），见 notifyIdOf。
        notifyId: notifyIdOf(rawMessageId),
        appMessageId: messageKey
      }
    },
    target: { token: [pushTokenNow()] },
    // collapseKey: -1 = 离线消息都缓存，不做同组覆盖（否则离线期间的几条会并成一条）
    pushOptions: { testMessage: agc.testMessage !== false, ttl: 3600, collapseKey: -1 }
  });
  const res = await request(PUSH_SEND.replace('%s', projectId), {
    method: 'POST',
    headers: {
      Authorization: 'Bearer ' + serviceJwt(sa),
      'Content-Type': 'application/json; charset=UTF-8',
      'Content-Length': Buffer.byteLength(payload),
      'push-type': '0'
    }
  }, payload);
  let data = {};
  try {
    data = JSON.parse(res.body);
  } catch (error) {
    data = {};
  }
  if (data.code === '80000000') {
    log('AGC 推送成功：' + (data.requestId || ''));
    return;
  }
  /*
   * 这里必须**抛错**，不能只 warn 一句就完事：
   * 调用方已经把这条消息记成"看过了"，静默失败就等于**永久丢掉这条消息**
   * （`80100003 invalid appMessageId` 就是这么发生的：接口 HTTP 200、code 非成功，
   * 于是"完全收不到消息"）。抛出去让上层回滚 state、下一轮重推。
   */
  const detail = res.body.slice(0, 220);
  if (data.code === '80100003') {
    throw new Error('payload 参数非法（80100003）：' + detail
      + ' —— 检查 appMessageId / notifyId 的字符集与长度');
  }
  if (res.status === 401 || res.status === 403) {
    throw new Error('鉴权失败（' + res.status + '）：服务账号 JWT 不对（alg/aud/key_id/project_id）');
  }
  throw new Error('AGC 推送失败（HTTP ' + res.status + '）：' + detail
    + ' —— 若反复失败，先在 App 里「复制中转材料」重新取一次 pushToken');
}

async function pushMeow(cfg, title, body) {
  const nick = cfg.notify.meow.nickname;
  const url = 'https://api.chuckfang.com/' + encodeURIComponent(nick) +
    '/Instamony/' + encodeURIComponent(body.slice(0, 200)) +
    '?url=' + encodeURIComponent(cfg.openUrl || 'instamony://direct');
  const res = await request(url, {});
  log('MeoW 推送：' + res.body.slice(0, 160));
}

async function pushTelegram(cfg, title, body) {
  const tg = cfg.notify.telegram;
  const payload = querystring.stringify({
    chat_id: tg.chatId,
    text: title + '\n' + body,
    disable_web_page_preview: 'true'
  });
  const res = await request('https://api.telegram.org/bot' + tg.botToken + '/sendMessage', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': Buffer.byteLength(payload)
    }
  }, payload);
  log('Telegram 推送：' + res.body.slice(0, 120));
}

/**
 * 通用 webhook —— 顺手支持几种**不需要向华为申请任何权限**的 IM 机器人。
 *
 * 为什么要这几个格式：HarmonyOS 原生推送（Push Kit）要走 AGC 审核，走不通时最实际的办法
 * 是"推到手机上一个本来就有通知能力的 App"。企业微信 / 飞书在 HarmonyOS 上都有原生客户端，
 * 群机器人只要一个 webhook URL，零审批、零费用，所以这里按它们的报文格式发：
 *   format = "wecom"  企业微信群机器人      {"msgtype":"text","text":{"content":"…"}}
 *   format = "feishu" 飞书自定义机器人      {"msg_type":"text","content":{"text":"…"}}
 *   format = "bark"   Bark（iOS 用）        GET /{key}/{text}
 *   format = "generic" 默认，原样 POST {title, body, threadId, url}
 */
async function pushWebhook(cfg, title, body, threadId) {
  const hook = cfg.notify.webhook;
  const format = String(hook.format || 'generic');
  const text = title + '\n' + body;
  const link = cfg.openUrl || 'instamony://direct';

  if (format === 'bark') {
    const base = hook.url.replace(/\/+$/, '');
    const url = base + '/' + encodeURIComponent(title) + '/' + encodeURIComponent(body) +
      '?url=' + encodeURIComponent(link);
    const res = await request(url, {});
    log('Bark 推送：' + res.body.slice(0, 120));
    return;
  }

  let payload;
  if (format === 'wecom') {
    payload = JSON.stringify({ msgtype: 'text', text: { content: text } });
  } else if (format === 'feishu') {
    payload = JSON.stringify({ msg_type: 'text', content: { text: text } });
  } else {
    payload = JSON.stringify({ title: title, body: body, threadId: threadId, url: link });
  }
  const headers = {
    'Content-Type': 'application/json; charset=UTF-8',
    'Content-Length': Buffer.byteLength(payload)
  };
  const extra = hook.headers || {};
  for (const key of Object.keys(extra)) headers[key] = String(extra[key]);
  const res = await request(hook.url, { method: 'POST', headers: headers }, payload);
  log('Webhook(' + format + ') 推送：' + res.body.slice(0, 120));
}

async function send(cfg, title, body, threadId, itemKey) {
  const channel = cfg.notify.channel;
  if (channel === 'agc') return pushAgc(cfg, title, body, threadId, itemKey || threadId);
  if (channel === 'meow') return pushMeow(cfg, title, body);
  if (channel === 'telegram') return pushTelegram(cfg, title, body);
  return pushWebhook(cfg, title, body, threadId);
}

/* --------------------------------------------- token 上报（App → 中转） */

/**
 * 为什么要有这个：pushToken 会变 —— 重装 App、清数据、系统更新 HMS、恢复出厂，
 * 每次变都等于"中转手上那条是废的"，表现是**推送静默失败**（接口还回成功，
 * 因为华为收下了，只是这个 token 不再对应任何设备）。
 * 以前靠人手在设置页「复制中转材料」再粘进配置，几乎必然忘。
 *
 * 现在的路：App 启动和 `tokenUpdate` 时 POST 到这个中转，中转落盘即用。
 * 协议极简（一条 JSON + 一个共享密钥），够用就好，别把它做成一门 RPC。
 *
 *   POST /token   {"token":"…","reason":"startup|tokenUpdate|manual","bundle":"…","version":"…"}
 *   GET  /health  → 中转自报状态（有没有 token、多旧、走哪个通道）
 *
 * 只在配了 `listen.port`（或命令行 `--listen`）时才开端口：不配就完全不开，
 * 免得默认给本机多开一个监听。
 */

const TOKEN_FILE = path.join(__dirname, 'token.json');
/** App 上报的 token（优先于 config.json 里那条）。 */
let liveToken = { token: '', at: 0, reason: '', source: 'config' };
let liveTokenLoaded = false;

function readTokenFile() {
  try {
    const data = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
    if (data && typeof data.token === 'string' && data.token.length > 0) {
      return data;
    }
  } catch (error) {
    // 没有就是第一次跑
  }
  return null;
}

function saveTokenFile(state) {
  const tmp = TOKEN_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), 'utf8');
  fs.renameSync(tmp, TOKEN_FILE);
}

/** 启动时定一次"当前该用哪个 token"，之后由上报端口更新。 */
function initToken(cfg) {
  if (liveTokenLoaded) return;
  liveTokenLoaded = true;
  const reported = readTokenFile();
  if (reported !== null) {
    liveToken = Object.assign({ source: 'report' }, reported);
    log('pushToken 用 App 上报的那条（' + new Date(Number(reported.at) || 0).toLocaleString() + '）');
    return;
  }
  liveToken = { token: (cfg.notify && cfg.notify.pushToken) || '', at: 0, reason: 'config', source: 'config' };
}

/** 实际发推送用的 token。 */
function pushTokenNow() {
  return liveToken.token || '';
}

/** App 上报进来一条 token：落盘 + 立刻生效（下一轮推送就用新的）。 */
function acceptToken(body) {
  const token = String(body.token || '').trim();
  if (token.length < 20) {
    return { ok: false, error: 'token 太短，不像 Push Kit 的 token' };
  }
  const state = {
    token: token,
    at: Date.now(),
    reason: String(body.reason || 'unknown'),
    bundle: String(body.bundle || ''),
    version: String(body.version || '')
  };
  liveToken = Object.assign({ source: 'report' }, state);
  try {
    saveTokenFile(state);
  } catch (error) {
    warn('token 落盘失败：' + error.message + '（本次运行内仍生效）');
  }
  log('收到 App 上报的 pushToken：长度 ' + token.length + '，原因 ' + state.reason
    + '，版本 ' + (state.version || '-') + '（已生效）');
  return { ok: true, at: state.at, tokenLength: token.length };
}

function maskedToken() {
  const token = pushTokenNow();
  if (token.length === 0) return '';
  return token.slice(0, 8) + '…' + token.slice(-4) + '（' + token.length + '）';
}

/** 读请求体（限长，别让一个畸形请求把内存吃了）。 */
function readBody(req, limit) {
  return new Promise((resolve) => {
    let raw = '';
    let tooBig = false;
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      if (tooBig) return;
      raw += chunk;
      if (raw.length > limit) {
        tooBig = true;
        req.destroy();
      }
    });
    req.on('end', () => resolve(tooBig ? null : raw));
    req.on('error', () => resolve(null));
  });
}

function listenPortOf(cfg) {
  const at = process.argv.indexOf('--listen');
  if (at >= 0 && process.argv[at + 1]) return Number(process.argv[at + 1]);
  return Number((cfg.listen && cfg.listen.port) || 0);
}

function listenKeyOf(cfg) {
  const at = process.argv.indexOf('--key');
  if (at >= 0 && process.argv[at + 1]) return String(process.argv[at + 1]);
  return String((cfg.listen && cfg.listen.key) || '');
}

/**
 * 开上报端口。没配端口就返回 null（不监听）。
 *
 * 安全：配了 key 就必须带 `X-Relay-Key`（或 `?key=`）—— 这个端口只该在内网，
 * 但它能改"往哪台设备推送"，所以别裸奔在公网上。
 */
function startReportServer(cfg) {
  const port = listenPortOf(cfg);
  if (!port) return null;
  const key = listenKeyOf(cfg);
  if (key.length < 8) {
    warn('上报端口没设 key（或太短）：局域网里谁都能改推送目标。建议 --key 一串随机字符。');
  }
  const server = http.createServer((req, res) => {
    const send2xx = (code, obj) => {
      const text = JSON.stringify(obj);
      res.writeHead(code, { 'Content-Type': 'application/json; charset=UTF-8' });
      res.end(text);
    };
    const url = new URL(req.url || '/', 'http://127.0.0.1');
    if (req.method === 'GET' && url.pathname === '/health') {
      const age = liveToken.at > 0 ? Math.round((Date.now() - liveToken.at) / 1000) : -1;
      send2xx(200, {
        ok: true,
        tokenSet: pushTokenNow().length > 0,
        tokenAgeSeconds: age,
        tokenSource: liveToken.source || '',
        tokenPreview: maskedToken(),
        channel: (cfg.notify && cfg.notify.channel) || '',
        now: Date.now()
      });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/token') {
      const given = String(req.headers['x-relay-key'] || url.searchParams.get('key') || '');
      if (key.length >= 8 && given !== key) {
        warn('上报被拒：key 不对（来源 ' + (req.socket.remoteAddress || '-') + '）');
        send2xx(401, { ok: false, error: 'bad key' });
        return;
      }
      readBody(req, 8192).then((raw) => {
        if (raw === null) {
          send2xx(413, { ok: false, error: 'body too large' });
          return;
        }
        let body = {};
        try {
          body = JSON.parse(raw || '{}');
        } catch (error) {
          send2xx(400, { ok: false, error: 'body is not json' });
          return;
        }
        const result = acceptToken(body);
        send2xx(result.ok ? 200 : 400, result);
      });
      return;
    }
    send2xx(404, { ok: false, error: 'not found' });
  });
  server.on('error', (error) => {
    warn('上报端口开不起来（' + port + '）：' + error.message);
  });
  server.listen(port, '0.0.0.0', () => {
    log('上报端口已开：http://<本机IP>:' + port + '（POST /token，GET /health）');
    log('在 App 里「设定 → 中转上报」填 http://<本机IP>:' + port + ' 和同一串 key');
  });
  return server;
}

/* --------------------------------------------------------- 单实例 + 收尾 */

function lockFile() {
  return path.join(__dirname, '.relay.lock');
}

/**
 * 单实例互斥 —— **用本地端口占位，不再只靠 pid 文件**。
 *
 * 为什么要换：pid 文件挡不住"锁文件被删掉之后再起一个"——我实测同时跑起过**三个**
 * relay（各推一遍，于是"同一条消息多发"）。端口占位是内核级的：第二个进程 bind 同一个
 * 端口必然失败，谁清了文件都没用。
 */
let mutexServer = null;

function acquireLock(cfg) {
  const file = lockFile();
  const port = Number((cfg && cfg.lockPort) || 47999);
  try {
    const old = Number(fs.readFileSync(file, 'utf8').trim());
    if (old > 0 && old !== process.pid) {
      try {
        process.kill(old, 0);
        warn('锁文件里写着 pid ' + old + '，它还在（下面再用端口判一次）。');
      } catch (error) {
        // 进程不在了：把旧锁当垃圾清掉
        try {
          fs.unlinkSync(file);
        } catch (ignored) {
        }
      }
    }
  } catch (error) {
    // 没有锁文件：正常
  }
  return new Promise((resolve) => {
    const net = require('net');
    const server = net.createServer();
    server.once('error', (error) => {
      if (error.code === 'EADDRINUSE') {
        die('已经有一个中转在跑（本地端口 ' + port + ' 被占用）。'
          + '\n先停掉它（Windows: 任务管理器里结束那个 node，或 `Get-Process node` 找 relay.js），再启动。'
          + '\n这条检查是为了防止两个实例同时推送，导致同一条消息收到两遍。');
      } else {
        warn('单实例端口检查异常（' + error.code + '）：' + error.message + '，继续启动。');
        resolve(false);
      }
    });
    server.listen(port, '127.0.0.1', () => {
      mutexServer = server;
      fs.writeFileSync(file, String(process.pid), 'utf8');
      resolve(true);
    });
  });
}

function releaseLock() {
  if (mutexServer !== null) {
    try {
      mutexServer.close();
    } catch (error) {
      // 忽略
    }
    mutexServer = null;
  }
  try {
    fs.unlinkSync(lockFile());
  } catch (error) {
    // 忽略
  }
}

/**
 * `--login`：浏览器登录 → 自动写 config.json。
 *
 * 为什么要有这条路：原来拿会话得去手机 App 里「复制中转材料」再粘进配置，
 * 会话一过期（IG 会踢）就得再来一遍。现在 relay 自己开一个专属浏览器窗口，
 * 你在里面正常登录，它从调试协议里把 Cookie 读回来写进配置 —— 不碰密码，
 * 也不需要你复制粘贴（机制见 browser-login.js 文件头）。
 */
async function runBrowserLogin() {
  const { loginWithBrowser } = require('./browser-login.js');
  const timeoutArg = process.argv.indexOf('--login-timeout');
  const timeoutMs = timeoutArg >= 0 && process.argv[timeoutArg + 1]
    ? Math.max(30, Number(process.argv[timeoutArg + 1])) * 1000 : 5 * 60 * 1000;
  const result = await loginWithBrowser({
    profileDir: path.join(__dirname, '.login-profile'),
    timeoutMs: timeoutMs,
    log: (text) => log(text)
  });
  if (result.cookie.length === 0) {
    warn('这次没有拿到会话（窗口关太早 / 没登录成功 / 只登了一半）。');
    warn('可以重跑 node relay.js --login，或者手动把 cookie 粘进 config.json 的 ig.cookie。');
    process.exit(4);
  }
  const file = configPath();
  let cfg = {};
  try {
    cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    cfg = { ig: {}, notify: { channel: 'agc' } };
  }
  cfg.ig = cfg.ig || {};
  cfg.ig.cookie = result.cookie;
  fs.writeFileSync(file, JSON.stringify(cfg, null, 2), 'utf8');
  log(`已写入 ${file}（ig.cookie 长度 ${result.cookie.length}，账号 ${result.userId || '?'}）`);
  log('下一步：node relay.js          # 60 秒一轮，聊天中即时推');
  log('      或 node relay.js --once  # 先跑一轮验一下（只记账不推送）');
}

/* ------------------------------------------------------------------ 主循环 */

/**
 * `--interval <秒>`：只在**人工验证时**用，把轮询压到 15 秒以上。
 *
 * 常驻时别用：`MIN_POLL_SECONDS`（60）是给账号上的保险，别为了"测得快"去踩 IG 限流。
 * 但验证时一轮等 60 秒实在难受，所以给一个下限 15 的显式开关，验完就撤。
 */
function intervalOverride() {
  const at = process.argv.indexOf('--interval');
  if (at >= 0 && process.argv[at + 1]) {
    const seconds = Math.max(15, Number(process.argv[at + 1]) || 0);
    warn('用 --interval ' + seconds + 's 快速轮询：只用于验证，验证完别再带这个参数。');
    return seconds;
  }
  return 0;
}

async function main() {
  quiet = process.argv.indexOf('--quiet') >= 0;
  const once = process.argv.indexOf('--once') >= 0;
  /*
   * `--login`：打开浏览器让你登录，登完自动把会话写进 config.json。
   * 放在 loadConfig 之前 —— 这一步的意义正是"还没有 cookie 的时候把 cookie 弄到手"。
   */
  if (process.argv.indexOf('--login') >= 0) {
    await runBrowserLogin();
    return;
  }
  const cfg = loadConfig();
  // 先定"当前用哪个 token"：App 上报过就用那条，否则用配置里那条。
  initToken(cfg);
  const reportServer = startReportServer(cfg);
  const testAt = process.argv.indexOf('--test-push');
  if (testAt >= 0) {
    // 只验通道：不看 IG、不占锁、不写 state —— 让"手机到底能不能收到"独立成一步。
    const text = process.argv[testAt + 1] || '中转通道自检';
    try {
      await send(cfg, 'Instamony', text, 'channel-test');
    } finally {
      if (reportServer !== null) reportServer.close();
    }
    return;
  }
  /*
   * 只开上报端口、不轮询：用来"先把 token 收上来"（还没拿到 IG cookie，
   * 或者只想单独确定上报这条路通不通）。进程靠 server 的 handle 活着。
   */
  if (process.argv.indexOf('--report-only') >= 0) {
    if (reportServer === null) {
      die('--report-only 需要配 listen.port 或带 --listen <端口>。');
    }
    log('只开上报端口，不轮询（Ctrl+C 停）');
    return;
  }
  requireIgCookie(cfg);
  const ig = cfg.ig || {};
  const fast = intervalOverride();
  const activeGap = fast > 0 ? fast : Math.max(MIN_POLL_SECONDS, Number(ig.pollSeconds || 60));
  const idleMax = Math.max(activeGap, Number(ig.idleMaxSeconds || 300));
  /** 连续安静几轮之后一步跳到安静档（默认 2 轮）。 */
  const quietAfterRounds = Math.max(1, Number(ig.quietRoundsBeforeJump || 2));
  /** 安静档的间隔：不超过 idleMax，也不低于活跃档。 */
  const quietJump = Math.min(idleMax, Math.max(activeGap,
    Number(ig.quietJumpSeconds || 240)));
  /*
   * **热档**：刚才有人发消息，说明正在聊天 —— 这时候延迟比请求量重要。
   *
   * 为什么不是一直这么快：IG 的收件箱响应很大（解开后 300KB 以上，gzip 后几十 KB），
   * 一直 15 秒一轮既费电也容易被风控。但"聊天那几分钟"才是真正在意延迟的时段，
   * 所以只在 `hotMinutes`（默认 10 分钟）内用 `hotSeconds`（默认 15 秒）。
   */
  const hotSeconds = Math.max(10, Math.min(activeGap, Number(ig.hotSeconds || 15)));
  const hotWindowMs = Math.max(1, Number(ig.hotMinutes || 10)) * 60 * 1000;
  const probeSeconds = Math.max(1, Number(ig.probeSeconds || 2));
  const hotProbeSeconds = Math.max(1, Number(ig.hotProbeSeconds || 1));
  /** 无条件拉全量的兜底间隔（秒）。 */
  const fullEverySeconds = Math.max(30, Number(ig.fullEverySeconds || 300));
  const stateFile = path.resolve(__dirname, cfg.stateFile || 'state.json');
  if (!once) await acquireLock(cfg);

  let state = loadState(stateFile);
  let dirty = false;
  let firstRound = true;
  let gap = activeGap;
  let quietRounds = 0;
  let lastActivityAt = 0;
  /** 上一次打过的"下一轮间隔"（只在变化时打，避免刷屏）。 */
  let lastLoggedGap = -1;
  /** 上一次拉全量的时间（毫秒）。 */
  let lastFullAt = 0;
  /** 探测到变化后暂存的那批会话（下一轮直接用，省一次往返）。 */
  let probeResult = null;
  /** 实时通道客户端（null = 没连，靠轮询）。 */
  let realtime = null;

  const finish = () => {
    if (dirty) saveState(stateFile, state);
    if (reportServer !== null) reportServer.close();
    if (realtime !== null) realtime.close();
    if (!once) releaseLock();
    process.exit(0);
  };
  process.on('SIGINT', finish);
  process.on('SIGTERM', finish);
  process.on('SIGHUP', finish);

  log('启动：发起间隔 ' + activeGap + 's → 空闲退到 ' + idleMax + 's，通道 ' + cfg.notify.channel);

  /*
   * **实时通道当触发器**（不是数据源）。
   *
   * IG 会把 `message_sync`（topic 146）推给"声明在前台"的客户端（见 realtime.js 的
   * buildForegroundState）。我们不去解析那些补丁，只在**收到任何 DM 相关帧**时
   * 立刻插一次收件箱 —— 这样延迟从"最多 hotSeconds"降到"一次 HTTP 往返（几百毫秒）"，
   * 而请求量并没有增加（只有真有事时才多发这一次）。
   *
   * 实时通道挂了也不影响主流程：轮询照旧（降级就是三档间隔）。
   */
  let wakeUp = null;
  realtime = (function () {
    const { RealtimeClient } = require('./realtime.js');
    const cookie = (cfg.ig && cfg.ig.cookie) || '';
    const userId = cookieValueOf(cookie, 'ds_user_id');
    const sessionId = decodeURIComponent(cookieValueOf(cookie, 'sessionid'));
    if (userId.length === 0 || sessionId.length === 0) return null;
    const client = new RealtimeClient({
      sessionId: sessionId,
      userId: userId,
      deviceDir: __dirname,
      log: (text) => log(text)
    });
    client.on('up', () => {
      log('实时通道已连上（IG 事件会立刻触发一次收件箱）');
    });
    client.on('down', (reason) => {
      log('实时通道断开：' + reason + '（下次自动重连，期间靠轮询）');
    });
    client.on('event', (topic) => {
      log('实时事件 topic=' + topic + ' → 立即拉一次收件箱');
      if (wakeUp !== null) wakeUp();
    });
    const loop = () => {
      client.connect().catch((error) => {
        log('实时通道连接失败：' + error.message + '（30 秒后重试，期间靠轮询）');
      });
    };
    loop();
    // 断线重连：简单固定间隔，比指数退避更好预测
    const reconnect = setInterval(() => {
      if (!client.up) loop();
    }, 30000);
    if (typeof reconnect.unref === 'function') reconnect.unref();
    return client;
  })();

  /** 短睡（可被实时事件叫醒）。 */
  const nap = (ms) => new Promise((resolve) => {
    const timer = setTimeout(() => {
      wakeUp = null;
      resolve();
    }, Math.max(0, Math.round(ms)));
    wakeUp = () => {
      clearTimeout(timer);
      wakeUp = null;
      resolve();
    };
  });

  for (;;) {
    /*
     * **常态轻量探测**（需求："延迟还要更低"）。
     *
     * 结构改成"探测器 + 全量"两级：
     *   · 每一轮先打一次**很小的请求**（前 5 个会话 × 5 条，约全量的 1/10）；
     *   · 没变化 → 短睡再探（聊天中 `hotProbeSeconds` 默认 3 秒，平时 `probeSeconds` 默认 10 秒）；
     *   · 有变化 → 才拉 30×20 的全量、逐条推。
     *   · 另外每 `fullEverySeconds`（默认 300 秒）无条件拉一次全量兜底：
     *     万一某条消息没把会话顶到最前（归档、置顶等边角情况），也能在 5 分钟内补上。
     *
     * 为什么敢这么勤：探测响应只有全量的十分之一左右（gzip 后几 KB），
     * 3 秒一次也只相当于每 30 秒拉一次全量的带宽。
     */
    const hotNow = lastActivityAt > 0 && (Date.now() - lastActivityAt) < hotWindowMs;
    const probeGap = hotNow ? hotProbeSeconds : probeSeconds;
    if (!firstRound) {
      const probed = await probeInbox(cfg);
      const changed = probeChanged(probed, state);
      const stale = (Date.now() - lastFullAt) > fullEverySeconds * 1000;
      if (!changed && !stale) {
        await nap(probeGap * 1000 * (0.8 + Math.random() * 0.4));
        continue;
      }
      if (changed && !stale) {
        /*
         * **省一次往返**：探测结果里已经带着那个会话的最新 5 条，直接拿它去推，
         * 不再回头拉 30×20 的全量。
         *
         * 为什么这一下很关键：实测 IG 收件箱接口**光服务端响应就要 1.5 秒**
         * （探测 32KB/1.6s、全量 261KB/1.5s）。省掉一次全量 = 少等 1.5 秒，
         * 相当于把整体延迟砍掉三分之一。
         */
        probeResult = probed;
        log('探测到新动静 → 直接用探测结果推送（省一次往返）');
      } else {
        probeResult = null;
        if (changed) log('有新动静且到全量兜底时间 → 拉全量');
      }
    }
    /*
     * 一轮：把拿到的那批会话里**所有没推过的条目**逐条推出去。
     *
     * 为什么不用 MQTToT 直接收消息：IG 不给我们推（iris 订阅被拒，
     * `Iris_IrisValidationException`，见 REALTIME.md），MQTT 只能当"有新动静"的触发器。
     */
    let threads;
    if (probeResult !== null) {
      threads = probeResult;
      probeResult = null;
    } else {
      lastFullAt = Date.now();
      threads = (await fetchInboxRaw(cfg)).threads;
    }
    /*
     * **窗口空洞检测**：如果某个会话返回的最旧一条都比我们上次记录的新，
     * 说明两轮之间来的消息超过了窗口大小（已经丢了）。这时去该会话详情页回填。
     */
    if (cfg.ig && cfg.ig.backfill !== false) {
      const filled = [];
      for (const thread of threads) {
        const threadId = String(thread.thread_id || thread.thread_v2_id || '');
        const last = threadId.length > 0 ? state[threadId] : undefined;
        if (last === undefined) {
          filled.push(thread);
          continue;
        }
        const items = thread.items || [];
        if (items.length === 0) {
          filled.push(thread);
          continue;
        }
        let oldest = Infinity;
        for (const item of items) {
          oldest = Math.min(oldest, Number(item.timestamp || 0));
        }
        if (Number(last.ts || 0) > 0 && oldest > Number(last.ts || 0)) {
          log(`会话 ${thread.thread_title || threadId} 可能有空洞（窗口最旧 ${oldest} > 记录 ${last.ts}）→ 回填一页`);
          const extra = await fetchThreadItems(cfg, threadId);
          if (extra.length > 0) {
            const merged = thread;
            merged.items = extra.concat(items);
            filled.push(merged);
            continue;
          }
        }
        filled.push(thread);
      }
      threads = filled;
    }
    const fresh = [];
    const skipped = [];
    for (const thread of threads) {
      const threadId = String(thread.thread_id || thread.thread_v2_id || '');
      if (!threadId) continue;
      const items = thread.items || [];
      if (items.length === 0) continue;
      const viewerId = thread.viewer_id ? String(thread.viewer_id) : '';
      const last = state[threadId];
      // 按时间升序：这样"两轮之间来的 3 条"会按顺序各推一条，而不是只推最后一条。
      const ordered = items.slice().sort((left, right) =>
        Number(left.timestamp || 0) - Number(right.timestamp || 0));
      if (!last) {
        // 第一次见这条会话：只记账不推送（否则一启动就把历史全弹一遍）。
        const newest = newestOf(thread);
        if (newest !== null) {
          const all = [];
          for (const item of ordered) {
            all.push(String(item.otid || item.item_id || ''));
          }
          state[threadId] = {
            key: newest.key, id: newest.id, ts: newest.ts, recent: [],
            pushed: all.slice(-40)
          };
          dirty = true;
        }
        continue;
      }
      /*
       * **判重改成确定性的"已推 id 名单"**。
       *
       * `pushed` 里是该会话最近 40 条的 `otid || item_id`，只要在里面就绝不重推 ——
       * 不再靠"文本相似 + 时间窗"去猜（那个既可能漏判、也可能误杀）。
       * 名单随 state 落盘，所以 relay 重启后也不会把老消息重推一遍。
       *
       * 另外 `is_ae_dual_send === true` 的那一份直接跳过（IG 的端到端双发副本）。
       */
      const lastTs = Number(last.ts || 0);
      const pushedIds = Array.isArray(last.pushed) ? last.pushed.slice() : [];
      const known = new Set(pushedIds);
      const recent = Array.isArray(last.recent) ? last.recent.slice() : [];
      const freshReasons = [];
      for (const item of ordered) {
        if (item.is_ae_dual_send === true) continue;
        const stamp = Number(item.timestamp || 0);
        const itemId = String(item.item_id || '');
        const otid = String(item.otid || '');
        const key = otid.length > 0 ? otid : itemId;
        if (key.length === 0) continue;
        if (known.has(key) || (itemId.length > 0 && known.has(itemId))) continue;
        known.add(key);
        if (itemId.length > 0) known.add(itemId);
        pushedIds.push(key);
        let text = item.text || '';
        if (!text) text = KIND_TEXT[item.item_type] || '[消息]';
        text = text.slice(0, 120);
        recent.push({ key: key, ts: stamp, text: text });
        const mine = !!(viewerId && item.user_id && String(item.user_id) === viewerId);
        if (mine || firstRound || stamp <= lastTs) continue;
        // IM 分类的合规红线：消息请求 / 没有历史往来的一律不推。
        const verdict = complianceVerdict(thread);
        if (verdict) {
          freshReasons.push(verdict);
          continue;
        }
        fresh.push({
          id: threadId,
          key: key,
          title: thread.thread_title || '私信',
          text: text,
          timestamp: stamp,
          // 成功才真的算"看过了"；失败要回滚到这一份（见下面的 catch）。
          prev: last
        });
      }
      if (freshReasons.length > 0) {
        skipped.push(`${freshReasons[0]}:${thread.thread_title || threadId}`);
      }
      const newest = newestOf(thread);
      if (newest !== null) {
        state[threadId] = {
          key: newest.key,
          id: newest.id,
          ts: newest.ts,
          recent: recent.slice(-8),
          // 已推 id 名单（最近 40 条），落盘后重启也不会重推老消息
          pushed: pushedIds.slice(-40)
        };
        dirty = true;
      }
    }

    if (skipped.length > 0) {
      log('合规过滤跳过 ' + skipped.length + ' 条（不推 IM 类以外的场景）：' + skipped.join('，'));
    }

    if (fresh.length > 0) {
      if (inQuietHours(cfg)) {
        log('安静时段：' + fresh.length + ' 条新私信只记账不推送');
      } else {
        /*
         * **每条消息一条通知**（需求："堆叠可展开，每一条都要显示"）。
         *
         * 通知 id 按"这条消息"算（见 notifyIdOf）：不同消息各自堆在通知中心里，
         * 不会被后一条覆盖；服务端再用 `appMessageId` 兜住重复投递。
         */
        for (const item of fresh) {
          const pushStart = Date.now();
          /*
           * **延迟拆解**（回答"能不能做到收到消息就收到通知"这个问题的唯一办法是量出来）：
           *   · `IG 记录 → 我们察觉`：item.timestamp 是**服务端**时间（微秒），
           *     差值是"消息进了 IG 之后，我们多久才看见" —— 这段等于探测间隔 + 响应时间；
           *   · `察觉 → 推送成功`：从发出 HTTP 到华为回 requestId 的时间（下发本身在之后）。
           */
          const igStampMs = Math.round(Number(item.timestamp || 0) / 1000);
          const detectMs = igStampMs > 0 ? pushStart - igStampMs : -1;
          try {
            await send(cfg, item.title, item.text || '你有一条新私信', item.id, item.key);
            log(`时延拆解：IG记录→察觉 ${detectMs}ms，察觉→华为受理 ${Date.now() - pushStart}ms`);
          } catch (error) {
            /*
             * **失败必须回滚**：上面进循环前已经把 state 更新成"这条看过了"，
             * 若不回滚，这条消息就再也不会被推（用户看到的就是"彻底没收到"）。
             */
            state[item.id] = item.prev;
            dirty = true;
            warn('推送失败（' + item.title + '）：' + error.message + ' —— 已回滚，下一轮重推');
          }
        }
      }
      log('本轮 ' + fresh.length + ' 条新私信（每条各一条通知）');
    }

    if (dirty) {
      saveState(stateFile, state);
      dirty = false;
    }
    firstRound = false;

    /*
     * **下一轮等多短 = 下一次探测多短**（这里以前是"三档睡眠 15/60/240 秒"）。
     *
     * 那正是延迟 15 秒的真凶：探测分支里已经省掉了一次往返，但推完一轮又睡了 15 秒
     * 才去探测，于是"探测间隔 3 秒"完全被这层睡眠盖掉（实测推送间隔 17~31 秒）。
     *
     * 现在：刚有新消息时用 `hotProbeSeconds`（默认 3 秒）；空闲时用 `probeSeconds`
     * （默认 10 秒）；两者都是**轻量探测**（32KB），不是全量（261KB）。
     */
    if (fresh.length > 0) {
      quietRounds = 0;
      lastActivityAt = Date.now();
    } else {
      quietRounds++;
    }
    const hot = lastActivityAt > 0 && (Date.now() - lastActivityAt) < hotWindowMs;
    gap = hot ? hotProbeSeconds : probeSeconds;
    if (gap !== lastLoggedGap) {
      lastLoggedGap = gap;
      log(`下一轮探测间隔 ${gap}s` + (hot ? '（热档：刚有新消息）' : ''));
    }
    if (once) {
      if (!quiet) {
        let total = 0;
        for (const key of Object.keys(state)) total++;
        log('一轮跑完：记了 ' + total + ' 条会话的时间点（state 已落盘）');
      }
      // --once 也连了实时通道（为了让这一轮和常驻行为一致），这里必须关掉，
      // 否则 socket 和定时器会把进程吊住（实测：--once 跑完不退出，卡到超时）。
      if (realtime !== null) realtime.close();
      releaseLock();
      return;
    }
    /*
     * 睡到下ー轮，但**可以被实时事件提前叫醒** —— 这是把延迟从"最多 hotSeconds"
     * 压到"一次 HTTP 往返"的关键：IG 一来事件就醒来立刻拉一次。
     */
    await new Promise((resolve) => {
      const delay = Math.round(gap * 1000 * (0.85 + Math.random() * 0.3));
      const timer = setTimeout(() => {
        wakeUp = null;
        resolve();
      }, delay);
      wakeUp = () => {
        clearTimeout(timer);
        wakeUp = null;
        resolve();
      };
    });
  }
}

if (require.main === module) {
  main().catch((error) => {
    warn('中转异常退出：' + (error && error.stack ? error.stack : error));
    if (process.argv.indexOf('--once') < 0) releaseLock();
    process.exit(1);
  });
}

module.exports = {
  complianceVerdict,
  looksLikeMessageRequest,
  hasConversationHistory,
  fetchInbox,
  fetchInboxRaw,
  loadState,
  saveState
};
