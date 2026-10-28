#!/usr/bin/env node
/*
 * 合规过滤自测 —— 不需要 IG cookie，也不需要手机。
 *
 * 为什么值得单独测：这段逻辑决定"哪些私信允许推"，判错了直接踩 IM 分类的
 * 合规红线（未关注人私信 / 消息请求一律不得推送）。以前它埋在轮询循环里，
 * 没法单独验证；现在抽成 complianceVerdict() 就可以用假数据跑。
 *
 * 跑法：node filter-test.js
 */

'use strict';

const { complianceVerdict } = require('./relay.js');

const cases = [
  {
    name: '陌生人首条私信（消息请求）',
    thread: {
      is_pending: true,
      items: [
        { item_id: '1', timestamp: 1700000200, user_id: '999', text: '嗨，看到你的主页…' },
        { item_id: '0', timestamp: 1700000100, user_id: '999', text: '' }
      ]
    },
    expect: 'message-request'
  },
  {
    name: '带审批标记的线程',
    thread: {
      approval_factor: 'approval_required',
      items: [
        { item_id: '2', timestamp: 1700000200, user_id: '999', text: '买粉吗' },
        { item_id: '1', timestamp: 1700000100, user_id: '999', text: '在吗' }
      ]
    },
    expect: 'message-request'
  },
  {
    name: '首次搭话（只有一条消息，没有历史）',
    thread: {
      items: [{ item_id: '1', timestamp: 1700000100, user_id: '999', text: '你好' }]
    },
    expect: 'no-history'
  },
  {
    name: '正常往来（两条消息，说明前面还有历史）',
    thread: {
      items: [
        { item_id: '3', timestamp: 1700000300, user_id: '999', text: '今晚有空聊两句吗？' },
        { item_id: '2', timestamp: 1700000200, user_id: '111', text: '刚下班' }
      ]
    },
    expect: ''
  },
  {
    name: '互关好友的老会话（两条且都不是首条）',
    thread: {
      items: [
        { item_id: '9', timestamp: 1700000900, user_id: '999', text: '照片收到了' },
        { item_id: '8', timestamp: 1700000800, user_id: '999', text: '' }
      ]
    },
    expect: ''
  }
];

let failed = 0;
for (const item of cases) {
  const got = complianceVerdict(item.thread);
  const ok = got === item.expect;
  if (!ok) failed++;
  console.log((ok ? '✓' : '✗') + ' ' + item.name
    + ' → ' + (got || '允许推送')
    + (ok ? '' : '（期望：' + (item.expect || '允许推送') + '）'));
}

if (failed > 0) {
  console.error('\n' + failed + ' 个用例不符合预期');
  process.exit(1);
}
console.log('\n全部通过：消息请求与无历史的私信都会被拦下，正常往来放行。');
