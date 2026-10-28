/*
 * iris_subscribe 变体探针：逐个改变量，看哪个能让订阅成功。
 * 只读、只订阅，不推任何东西。跑法：node subscribe-probe.js
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (t) => console.log(`[${new Date().toTimeString().slice(0, 8)}] ${t}`);

async function main() {
  const cfg = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  const cookie = cfg.ig.cookie;
  const userId = pick(cookie, 'ds_user_id');
  const sessionId = decodeURIComponent(pick(cookie, 'sessionid'));

  const client = new RealtimeClient({
    sessionId, userId, deviceDir: __dirname, log: (t) => log('  ' + t)
  });
  // 先把设备身份定下来（和 MQTT CONNECT 里那条一致），再拉收件箱。
  const deviceId = require('./realtime.js').loadDeviceId(__dirname);
  cfg.ig.deviceId = deviceId;
  log(`设备 id = ${deviceId}`);

  const first = await fetchInboxRaw(cfg);
  log(`收件箱(连接前)：seq=${first.seqId} snapshot=${first.snapshotAtMs}`);

  const results = [];
  client.on('subscribe', (text) => {
    results.push(text);
    log(`  ← 135: ${text.slice(0, 180)}`);
  });
  client.on('event', (topic, text) => {
    log(`  ← event topic=${topic} ${text.slice(0, 120)}`);
  });

  await client.connect();
  log('CONNACK rc=0');

  const trySubscribe = async (label, body) => {
    log(`试 ${label}: ${body}`);
    client.publishJson('134', body);
    await sleep(2500);
  };

  await trySubscribe('A 原样（重复一次看是否偶发）',
    JSON.stringify({ seq_id: first.seqId, snapshot_at_ms: first.snapshotAtMs,
      snapshot_app_version: APP_VERSION }));
  await trySubscribe('A2 完全一样再来一次',
    JSON.stringify({ seq_id: first.seqId, snapshot_at_ms: first.snapshotAtMs,
      snapshot_app_version: APP_VERSION }));
  await trySubscribe('B 不带 snapshot_app_version',
    JSON.stringify({ seq_id: first.seqId, snapshot_at_ms: first.snapshotAtMs }));
  await trySubscribe('C 版本号用 269.0.0.18.75',
    JSON.stringify({ seq_id: first.seqId, snapshot_at_ms: first.snapshotAtMs,
      snapshot_app_version: '269.0.0.18.75' }));
  await trySubscribe('E seq_id 用字符串',
    JSON.stringify({ seq_id: String(first.seqId), snapshot_at_ms: first.snapshotAtMs,
      snapshot_app_version: APP_VERSION }));
  await trySubscribe('F seq_id 与 snapshot 都用字符串',
    JSON.stringify({ seq_id: String(first.seqId), snapshot_at_ms: String(first.snapshotAtMs),
      snapshot_app_version: APP_VERSION }));
  await trySubscribe('G 老版本位点（seq-1, snapshot 减 1000）',
    JSON.stringify({ seq_id: first.seqId - 1, snapshot_at_ms: first.snapshotAtMs - 1000,
      snapshot_app_version: APP_VERSION }));

  // D：连接后再拉一次收件箱，用"更新"的位点
  const second = await fetchInboxRaw(cfg);
  log(`收件箱(连接后)：seq=${second.seqId} snapshot=${second.snapshotAtMs}`);
  await trySubscribe('D 连接后重新取的位点',
    JSON.stringify({ seq_id: second.seqId, snapshot_at_ms: second.snapshotAtMs,
      snapshot_app_version: APP_VERSION }));

  log(`共 ${results.length} 条订阅结果`);
  client.close();
  process.exit(0);
}

main().catch((error) => {
  console.error('探针失败：' + error.message);
  process.exit(1);
});
