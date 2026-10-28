#!/usr/bin/env node
/*
 * **实时通道验证器** —— 连上 IG 的 MQTToT broker，订阅私信，把收到的帧打出来。
 *
 * 为什么单独一个文件：实时通道有太多东西会安静地失败（协议名、Thrift 字段、
 * `snapshot_app_version`、topic 号），混在 relay 主循环里排查会很痛苦。
 * 这里只做一件事：连上 → 订阅 → 打日志，**不推通知、不写 state**。
 *
 * 用法：
 *   node realtime-test.js             # 连上并订阅，持续打印（Ctrl+C 停）
 *   node realtime-test.js 120         # 跑 120 秒后自动退出
 *
 * 期望输出：
 *   [realtime] CONNACK rc=0 …
 *   [realtime] iris_subscribe seq=… snapshot=… sent=true
 *   [realtime] topic=135 {"succeeded":true,…}      ← 订阅成功
 *   [realtime] topic=150 …（你发一条私信就会来）
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { RealtimeClient, APP_VERSION } = require('./realtime.js');
const { fetchInboxRaw } = require('./relay.js');

const CONFIG = path.join(__dirname, 'config.json');

function pick(cookie, name) {
  for (const part of cookie.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return '';
}

function clock() {
  return new Date().toTimeString().slice(0, 8);
}

function log(text) {
  console.log(`[${clock()}] ${text}`);
}

async function main() {
  const seconds = Number(process.argv[2] || 0);
  const cfg = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  const cookie = (cfg.ig && cfg.ig.cookie) || '';
  const userId = pick(cookie, 'ds_user_id');
  const sessionId = decodeURIComponent(pick(cookie, 'sessionid'));
  if (userId.length === 0 || sessionId.length === 0) {
    console.error('config.json 里的 cookie 缺少 ds_user_id / sessionid。');
    process.exit(2);
  }

  log('先从收件箱拿订阅位点（seq_id / snapshot_at_ms）…');
  const inbox = await fetchInboxRaw(cfg);
  if (inbox.seqId <= 0 || inbox.snapshotAtMs <= 0) {
    console.error(`收件箱没给 seq_id/snapshot_at_ms（seqId=${inbox.seqId} snapshot=${inbox.snapshotAtMs}）——`
      + '没有它们订阅不了实时通道。');
    process.exit(3);
  }
  log(`会话 ${inbox.threads.length} 条，seq_id=${inbox.seqId} snapshot_at_ms=${inbox.snapshotAtMs}`);

  const client = new RealtimeClient({
    sessionId: sessionId,
    userId: userId,
    deviceDir: __dirname,
    log: log
  });

  client.on('up', () => {
    log('CONNACK rc=0，通道已建立，开始订阅私信');
    client.subscribeDirect(inbox.seqId, inbox.snapshotAtMs, APP_VERSION);
  });
  client.on('down', (reason) => {
    log(`通道断开：${reason}`);
  });
  client.on('subscribe', (text) => {
    log(`topic=135 订阅结果 ${text.slice(0, 200)}`);
  });
  client.on('event', (topic, text) => {
    log(`topic=${topic} 收到帧 ${text.length} 字节：${text.slice(0, 240)}`);
  });

  await client.connect();
  log('已连接。现在用另一个账号发一条私信，观察这里是否出现 topic=150。');

  const stop = () => {
    log(`统计：报文 ${client.stats.packets}，事件 ${client.stats.events}`);
    client.close();
    process.exit(0);
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
  if (seconds > 0) {
    setTimeout(stop, seconds * 1000);
  }
}

main().catch((error) => {
  console.error('失败：' + (error && error.message ? error.message : error));
  process.exit(1);
});
