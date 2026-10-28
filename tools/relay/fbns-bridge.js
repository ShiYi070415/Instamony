/*
 * `fbns.js` 里那几个报文组装函数的**薄封装**，只给 `test-fbns-arkts.js` 用。
 *
 * 为什么单独一层：`fbns.js` 是运行时脚本（连 socket、读落盘凭据），而测试只需要那几个
 * 纯函数（`buildConnectThrift` 等）。直接 require 也行 —— 这一层只是让测试读起来更清楚，
 * 顺带把"哪些是纯函数"这件事固定下来。
 */
'use strict';

const fbns = require('./fbns.js');

module.exports = {
  buildConnectThrift: fbns.buildConnectThrift,
  buildSubscribe: fbns.buildSubscribe,
  buildPublish: fbns.buildPublish,
  buildPuback: fbns.buildPuback,
  buildPingreq: fbns.buildPingreq
};
