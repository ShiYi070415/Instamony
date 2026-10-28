/*
 * **会话形状转换**（纯函数：不碰磁盘、不发请求）。
 *
 * 为什么要单独一个模块：
 *   1. 目标要求"`--caa-login` 产出的会话与 instagrapi settings.json **等价**"。
 *      "等价"不能靠肉眼，得能被**同一条解析路径**读回来做逐字段比对 —— 那两段逻辑
 *      就必须是纯函数，才能写测试（见 test-caa-parse.js）。
 *   2. `--import-session`（Python 那条路的入口）和 `--caa-login`（Node 这条路的出口）
 *      共用同一份实现，就不会出现"两条路各解释一遍 settings.json"的分叉。
 *
 * 两个方向：
 *   `sessionFromSettings(settings)`  settings.json（instagrapi 形状） → 我们运行时的会话
 *   `settingsShapeOf(result, profile)` CAA 登录结果 → settings.json（instagrapi 形状）
 */

'use strict';

/** `authorization` 的前缀（IG 的设备级授权串）。 */
const IGT_MARKER = 'Bearer IGT:2:';

/** `{sessionid: '…', …}` → `sessionid=…; …`（空值丢掉）。 */
function cookieStringOf(cookieMap) {
  const parts = [];
  const map = cookieMap || {};
  for (const name of Object.keys(map)) {
    const value = map[name];
    if (value !== undefined && value !== null && String(value).length > 0) {
      parts.push(`${name}=${String(value)}`);
    }
  }
  return parts.join('; ');
}

/** `name=value; name=value` → 取某一颗的值（取不到返回空串）。 */
function cookieValueOf(cookieString, name) {
  for (const part of String(cookieString || '').split(';')) {
    const one = part.trim();
    const cut = one.indexOf('=');
    if (cut <= 0) {
      continue;
    }
    if (one.slice(0, cut).trim() === name) {
      return one.slice(cut + 1).trim();
    }
  }
  return '';
}

/**
 * `Bearer IGT:2:<base64(JSON)>` → 那个 JSON 对象（解不开就返回空对象）。
 *
 * settings.json 里存的是**解开的** `authorization_data`，而 IG 下发的是整串
 * `Bearer IGT:2:…` —— 这个转换就是"等价"的关键一步。
 */
function authorizationDataOf(authorization) {
  const text = String(authorization || '');
  if (!text.startsWith(IGT_MARKER)) {
    return {};
  }
  try {
    return JSON.parse(Buffer.from(text.slice(IGT_MARKER.length), 'base64').toString('utf8'));
  } catch (error) {
    return {};
  }
}

/**
 * CAA 登录结果 → **instagrapi settings.json 的形状**。
 *
 * @param result  `caaLogin()` 的返回值（用 `cookies` / `authorization`）
 * @param profile 设备档案（phoneId / uuid / androidId / mid / 版本号 / UA）
 */
function settingsShapeOf(result, profile) {
  const uuids = {
    phone_id: profile.phoneId,
    uuid: profile.uuid,
    android_device_id: 'android-' + String(profile.androidId || '').replace(/^android-/, ''),
    client_session_id: profile.uuid
  };
  // `mid` 用登录响应带回来的那份（没有才退回设备档案）——见 instamony.js 里同名字段的说明。
  const mid = String((result && result.mid) || profile.mid || '');
  return {
    cookies: (result && result.cookies) || {},
    uuids,
    authorization_data: authorizationDataOf(result && result.authorization),
    device_settings: {
      app_version: profile.appVersion,
      version_code: profile.versionCode
    },
    user_agent: profile.userAgent,
    mid,
    last_login: new Date().toISOString()
  };
}

/**
 * settings.json（instagrapi 形状）→ 我们运行时的会话 + 设备三件套。
 *
 * **失败就抛**（不 die、不落盘）—— 调用方自己决定是退出（CLI）还是当自检结论（dry-run）。
 *
 * @returns `{ session, device }`
 */
function sessionFromSettings(settings) {
  if (settings === null || settings === undefined || typeof settings !== 'object') {
    throw new Error('settings 不是对象');
  }
  const cookie = cookieStringOf(settings.cookies || {});
  const sessionid = cookieValueOf(cookie, 'sessionid');
  if (sessionid.length === 0) {
    throw new Error('settings 里没有 sessionid —— 这份会话不算登录成功');
  }
  const uuids = settings.uuids || {};
  const phoneId = String(uuids.phone_id || '');
  const uuid = String(uuids.uuid || '');
  const androidId = String(uuids.android_device_id || '').replace(/^android-/, '');
  if (phoneId.length === 0 || uuid.length === 0 || androidId.length === 0) {
    throw new Error('settings 的 uuids 不全（需要 phone_id / uuid / android_device_id）');
  }
  const authData = settings.authorization_data || {};
  const authorization = Object.keys(authData).length === 0
    ? '' : IGT_MARKER + Buffer.from(JSON.stringify(authData)).toString('base64');
  const session = {
    source: 'instagrapi',
    userId: cookieValueOf(cookie, 'ds_user_id'),
    cookie,
    sessionid,
    csrf: cookieValueOf(cookie, 'csrftoken'),
    authorization,
    appVersion: String((settings.device_settings || {}).app_version || ''),
    userAgent: String(settings.user_agent || ''),
    mid: String(settings.mid || ''),
    savedAt: Date.now()
  };
  return { session, device: { phoneId, uuid, androidId } };
}

module.exports = {
  IGT_MARKER,
  cookieStringOf,
  cookieValueOf,
  authorizationDataOf,
  settingsShapeOf,
  sessionFromSettings
};
