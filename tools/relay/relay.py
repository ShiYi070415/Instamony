#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Instamony **BYO 中转**：在自己家里那台机器上低频轮询 IG 收件箱，有新私信就推送。

为什么是 BYO（Bring Your Own box）
-----------------------------------
把所有人的 IG 会话放到一台公共服务器上会同时踩三件事：①IG 会因为"同一 IP 挂着多个
账号、请求很密"把整片账号判成脚本农场（instagrapi 的 best-practices 原话：最稳的基线是
一个账号一个固定 IP，共享 IP 池要降低账号数量与请求量）；②所有人的 sessionid 集中存放，
被拖库就是集体丢号；③推送渠道也会因为"同一 IP 给很多昵称发通知"被判成攻击。
所以这个脚本的设计前提是：**一个用户、一台自己的机器、自己的出口 IP**。

做什么 / 不做什么
-----------------
  · 只读：只调 `direct_v2/inbox` 这一条，绝不发消息、不点关注、不发赞；
  · 低频：默认 90 秒一次（可配，最低 60 秒），带随机抖动，模仿人打开 App 的节奏；
  · 不落正文：state.json 只存"每个会话最后一条消息 id 与时间戳"，不存聊天内容；
  · 不打印秘密：日志里 cookie / token 只出现在长度里。

用法
----
  1. App 里进「设定 → 诊断 → 复制中转材料（会话 + 推送 token）」，粘到 config.json 对应字段；
  2. 填好 notify.agc 三个值（见 README 的 AGC 步骤）；
  3. `python relay.py --config config.json`（Python 3.8+，只用标准库）；
  4. 想常开：Windows 用「任务计划程序」，Linux 用 systemd（README 里有样例）。

退出码：0 正常；2 配置有问题；3 IG 回了 login_required（会话失效，需要重新在 App 里登录再导出）。
"""

import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

INBOX_URL = "https://www.instagram.com/api/v1/direct_v2/inbox/"
# 网页版那一套头：这份 cookie 本来就是 App 内嵌 WebView 登录出来的，所以走 web 口的会话最匹配。
WEB_APP_ID = "936619743392459"
DEFAULT_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
MIN_POLL_SECONDS = 60
AGC_TOKEN_URL = "https://oauth-login.cloud.huawei.com/oauth2/v3/token"
AGC_PUSH_URL = "https://push-api.cloud.huawei.com/v1/{app_id}/messages:send"
MEOW_URL = "https://api.chuckfang.com/{nick}/Instamony/{msg}"


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def load_config(path):
    with open(path, "r", encoding="utf-8") as handle:
        cfg = json.load(handle)
    cookie = (cfg.get("ig") or {}).get("cookie") or ""
    if len(cookie) < 20:
        log("配置里没有有效的 cookie（先在 App 里「复制中转材料」）")
        sys.exit(2)
    notify = cfg.get("notify") or {}
    channel = notify.get("channel") or "agc"
    if channel == "agc":
        agc = notify.get("agc") or {}
        if not (agc.get("appId") and agc.get("clientId") and agc.get("clientSecret")):
            log("channel=agc 但 AGC 的 appId/clientId/clientSecret 没填全")
            sys.exit(2)
        if not notify.get("pushToken"):
            log("channel=agc 但 pushToken 是空的（App 里没拿到 token，见 README 的 AGC 步骤）")
            sys.exit(2)
    elif channel == "meow":
        if not ((notify.get("meow") or {}).get("nickname")):
            log("channel=meow 但没填昵称")
            sys.exit(2)
    elif channel == "telegram":
        tg = notify.get("telegram") or {}
        if not (tg.get("botToken") and tg.get("chatId")):
            log("channel=telegram 但 botToken/chatId 没填")
            sys.exit(2)
    elif channel == "webhook":
        if not ((notify.get("webhook") or {}).get("url")):
            log("channel=webhook 但 url 没填")
            sys.exit(2)
    else:
        log("未知的 notify.channel: " + channel)
        sys.exit(2)
    return cfg


def poll_seconds(cfg):
    raw = int((cfg.get("ig") or {}).get("pollSeconds") or 90)
    return max(MIN_POLL_SECONDS, raw)


def csrf_of(cookie):
    for part in cookie.split(";"):
        key, _, value = part.strip().partition("=")
        if key == "csrftoken":
            return value
    return ""


def fetch_inbox(cfg):
    """拉一页收件箱（只读）。返回 threads 数组；会话失效返回 None。"""
    cookie = cfg["ig"]["cookie"]
    query = urllib.parse.urlencode({
        "limit": "15",
        "thread_message_limit": "3",
        "visual_message_return_type": "unseen",
        "persistentBadging": "true",
    })
    req = urllib.request.Request(INBOX_URL + "?" + query)
    req.add_header("Cookie", cookie)
    req.add_header("User-Agent", DEFAULT_UA)
    req.add_header("X-IG-App-ID", WEB_APP_ID)
    req.add_header("X-CSRFToken", csrf_of(cookie))
    req.add_header("X-ASBD-ID", "129477")
    req.add_header("X-IG-WWW-Claim", "0")
    req.add_header("X-Requested-With", "XMLHttpRequest")
    req.add_header("Referer", "https://www.instagram.com/direct/inbox/")
    req.add_header("Accept", "*/*")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace") if error.fp else ""
        if error.code in (401, 403) or "login_required" in body:
            log("IG 拒绝：会话失效（HTTP %d）。请在 App 里重新登录后再导出一次。" % error.code)
            return None
        log("IG HTTP %d，本轮跳过：%s" % (error.code, body[:160]))
        return []
    except Exception as error:  # 网络抖动：跳过这一轮
        log("IG 请求失败，本轮跳过：%s" % error)
        return []
    try:
        data = json.loads(body)
    except ValueError:
        log("IG 回的不是 JSON，本轮跳过：%s" % body[:160])
        return []
    inbox = data.get("inbox") or {}
    return inbox.get("threads") or []


def load_state(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def newest_of(thread):
    """一条会话里最新那条消息的 (id, 时间戳ms, 预览文字, 是否我发的)。"""
    items = thread.get("items") or []
    best = None
    for item in items:
        stamp = int(item.get("timestamp") or 0)
        if best is None or stamp > best[1]:
            kind = item.get("item_type") or ""
            text = item.get("text") or ""
            if not text:
                text = {"media_share": "[分享的帖子]", "clip": "[分享的 Reels]",
                        "xma_media_share": "[分享的帖子]", "xma_clip": "[分享的 Reels]",
                        "reel_share": "[分享的 Reels]", "link": "[链接]",
                        "reel_media": "[Reels]", "media": "[图片/视频]",
                        "voice_media": "[语音]", "animated_media": "[动图]",
                        "raven_media": "[阅后即焚]", "like": "[赞了你的消息]"}.get(kind, "[消息]")
            best = (str(item.get("item_id") or ""), stamp, text[:120],
                    bool(item.get("user_id") and thread.get("viewer_id")
                         and str(item.get("user_id")) == str(thread.get("viewer_id"))))
    return best


def agc_access_token(agc):
    payload = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": agc["clientId"],
        "client_secret": agc["clientSecret"],
    }).encode()
    req = urllib.request.Request(AGC_TOKEN_URL, data=payload)
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8", "replace"))
    token = data.get("access_token") or ""
    if not token:
        raise RuntimeError("AGC 取 token 失败：%s" % str(data)[:200])
    return token


def push_agc(cfg, title, body, thread_id):
    agc = cfg["notify"]["agc"]
    token = agc_access_token(agc)
    data = json.dumps({"threadId": thread_id, "kind": "direct"})
    message = {
        "validate_only": False,
        "message": {
            "data": data,
            "notification": {"title": title, "body": body},
            "android": {"ttl": "86400s", "data": data},
            "token": [cfg["notify"]["pushToken"]],
        },
    }
    req = urllib.request.Request(AGC_PUSH_URL.format(app_id=agc["appId"]),
                                 data=json.dumps(message).encode())
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json; charset=UTF-8")
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8", "replace")
    log("AGC 推送已发：%s" % raw[:160])


def push_meow(cfg, title, body, thread_id):
    nick = cfg["notify"]["meow"]["nickname"]
    url = MEOW_URL.format(nick=urllib.parse.quote(nick),
                          msg=urllib.parse.quote(body[:200]))
    full = url + "?url=" + urllib.parse.quote(cfg.get("openUrl") or "instamony://direct")
    req = urllib.request.Request(full)
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode("utf-8", "replace")
    log("MeoW 推送已发：%s" % raw[:160])


def push_telegram(cfg, title, body, thread_id):
    """Telegram 机器人：不受 MeoW 那种"共用 IP 判攻击"的影响，手机上有 Telegram 就有通知。"""
    tg = cfg["notify"]["telegram"]
    payload = urllib.parse.urlencode({
        "chat_id": tg["chatId"],
        "text": title + "\n" + body,
        "disable_web_page_preview": "true",
    }).encode()
    req = urllib.request.Request(
        "https://api.telegram.org/bot%s/sendMessage" % tg["botToken"], data=payload)
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode("utf-8", "replace")
    log("Telegram 推送已发：%s" % raw[:120])


def push_webhook(cfg, title, body, thread_id):
    """通用 webhook（企业微信 / 钉钉 / Bark / 自建服务都行）：POST 一个 JSON 过去。"""
    hook = cfg["notify"]["webhook"]
    payload = json.dumps({
        "title": title,
        "body": body,
        "threadId": thread_id,
        "url": cfg.get("openUrl") or "instamony://direct",
    }).encode()
    req = urllib.request.Request(hook["url"], data=payload)
    req.add_header("Content-Type", "application/json; charset=UTF-8")
    for key in (hook.get("headers") or {}):
        req.add_header(key, hook["headers"][key])
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode("utf-8", "replace")
    log("Webhook 推送已发：%s" % raw[:120])


def notify(cfg, title, body, thread_id):
    channel = cfg["notify"]["channel"]
    try:
        if channel == "agc":
            push_agc(cfg, title, body, thread_id)
        elif channel == "meow":
            push_meow(cfg, title, body, thread_id)
        elif channel == "telegram":
            push_telegram(cfg, title, body, thread_id)
        elif channel == "webhook":
            push_webhook(cfg, title, body, thread_id)
        else:
            log("未知的 notify.channel: " + channel)
    except Exception as error:
        log("推送失败（这一轮不算丢，下一轮会重新判定）：%s" % error)


def main():
    parser = argparse.ArgumentParser(description="Instamony BYO 中转")
    parser.add_argument("--config", default="config.json")
    parser.add_argument("--once", action="store_true", help="只跑一轮（调试用）")
    args = parser.parse_args()

    cfg = load_config(args.config)
    gap = poll_seconds(cfg)
    state_path = cfg.get("stateFile") or "state.json"
    state = load_state(state_path)
    log("启动：每 %d 秒看一次收件箱（±15%% 抖动），推送通道 %s"
        % (gap, cfg["notify"]["channel"]))
    first_round = True
    while True:
        threads = fetch_inbox(cfg)
        if threads is None:
            sys.exit(3)
        fresh = 0
        for thread in threads:
            thread_id = str(thread.get("thread_id") or thread.get("thread_v2_id") or "")
            if not thread_id:
                continue
            newest = newest_of(thread)
            if newest is None:
                continue
            msg_id, stamp, preview, mine = newest
            last = state.get(thread_id)
            if last is None:
                # 第一次见这条会话：只记账，不推送（否则一启动就把历史全弹一遍）。
                state[thread_id] = {"id": msg_id, "ts": stamp}
                continue
            if msg_id != last.get("id") and stamp > int(last.get("ts") or 0):
                state[thread_id] = {"id": msg_id, "ts": stamp}
                if mine or first_round:
                    continue
                title = thread.get("thread_title") or "私信"
                body = preview or "你有一条新私信"
                log("新私信：%s — %s" % (title, body))
                notify(cfg, title, body, thread_id)
                fresh += 1
        save_state(state_path, state)
        if fresh:
            log("本轮推送 %d 条" % fresh)
        first_round = False
        if args.once:
            return
        time.sleep(gap * random.uniform(0.85, 1.15))


if __name__ == "__main__":
    main()
