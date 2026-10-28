/*
 * **浏览器登录 → 自动取回 IG 会话**（`node relay.js --login`）。
 *
 * ## 为什么不是"callback 跳转"
 * 常规 OAuth 那套（本地起个端口等 `?code=…` 回调）在这里不成立：Instagram 的网页登录
 * 成功后**不跳到你指定的地址**，它把 `sessionid` 写在 `instagram.com` 域下的 Cookie 里。
 * 同源策略决定了外部（我们）读不到它 —— 除非我们**就是那个浏览器**。
 *
 * ## 所以怎么做
 * 用一个**专属 profile** 启动本机的 Edge / Chrome，并打开远程调试端口（CDP）。
 * 页面还是那个正常的 IG 登录页，你自己输账号、过 2FA、过验证码，什么都行 ——
 * 我们不碰密码、不模拟点击。登录完成后，通过 CDP 的 `Network.getAllCookies`
 * 把 `instagram.com` 下的 Cookie 读出来，拼成 relay 要的那一串。
 *
 * 好处：
 *   · 一次 `--login`，之后会话就存在 `config.json` 里，不用再手工复制粘贴；
 *   · 会话过期（IG 会踢）时重跑一次即可；
 *   · 全程走的是**真浏览器**，登录流程里的 challenge / 2FA 都由你亲手完成，
 *     不存在"自动化登录被风控"的问题（我们压根没自动化）。
 *
 * ## 为什么不装 puppeteer / playwright
 * 只需要两个能力：起浏览器、读 Cookie。CDP 是纯 HTTP + WebSocket，零依赖实现
 * 大约一百行（见下面的 `CdpSocket`）；为此拖进来一个带 Chromium 的 npm 包没有必要。
 */

'use strict';

const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');

/** 调试端口：固定值便于排查；被占用时换一个（见 launchBrowser）。 */
const DEFAULT_DEBUG_PORT = 9333;
/** 登录页。 */
const LOGIN_URL = 'https://www.instagram.com/accounts/login/';

/* ------------------------------------------------------------------ 找浏览器 */

/**
 * 找本机的 Chromium 系浏览器（Edge / Chrome）。
 *
 * 为什么优先 Edge：Windows 上都装着，而且它的调试端口行为和 Chrome 一致。
 * 也支持 Linux / macOS，方便把 relay 挪到小主机上。
 */
function findBrowser() {
  const candidates = [];
  if (process.platform === 'win32') {
    const programFiles = [
      process.env['PROGRAMFILES'] || 'C:\\Program Files',
      process.env['PROGRAMFILES(X86)'] || 'C:\\Program Files (x86)',
      process.env['LOCALAPPDATA'] || ''
    ].filter((dir) => dir.length > 0);
    for (const root of programFiles) {
      candidates.push(path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe'));
      candidates.push(path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'));
    }
  } else if (process.platform === 'darwin') {
    candidates.push('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
    candidates.push('/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge');
    candidates.push('/Applications/Chromium.app/Contents/MacOS/Chromium');
  } else {
    candidates.push('/usr/bin/microsoft-edge', '/usr/bin/google-chrome',
      '/usr/bin/chromium', '/usr/bin/chromium-browser', '/snap/bin/chromium');
  }
  for (const file of candidates) {
    try {
      if (fs.existsSync(file)) return file;
    } catch (error) {
      // 忽略
    }
  }
  return '';
}

/* ------------------------------------------------------- 极简 CDP WebSocket 客户端 */

/**
 * CDP 的命令通道是 WebSocket。这里只实现用到的那点：
 * 客户端握手、发送文本帧（必须掩码）、读服务端文本帧。
 *
 * 不做：分片、扩展协商、压缩。CDP 的单条消息都很小，够用。
 */
class CdpSocket {
  constructor(url) {
    this.url = url;
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.nextId = 1;
    this.pending = new Map();
  }

  connect(timeoutMs = 8000) {
    return new Promise((resolve, reject) => {
      let parsed;
      try {
        parsed = new URL(this.url);
      } catch (error) {
        reject(new Error('调试地址不合法：' + this.url));
        return;
      }
      const key = crypto.randomBytes(16).toString('base64');
      const socket = net.connect({ host: parsed.hostname, port: Number(parsed.port) || 80 });
      this.socket = socket;
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error('CDP 握手超时'));
      }, timeoutMs);

      socket.on('connect', () => {
        const lines = [
          `GET ${parsed.pathname} HTTP/1.1`,
          `Host: ${parsed.hostname}:${parsed.port}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${key}`,
          'Sec-WebSocket-Version: 13',
          '', ''
        ];
        socket.write(lines.join('\r\n'));
      });
      socket.on('data', (chunk) => {
        if (this.handshakeDone === true) {
          this.consume(chunk);
          return;
        }
        this.buffer = Buffer.concat([this.buffer, chunk]);
        const end = this.buffer.indexOf('\r\n\r\n');
        if (end < 0) return;
        const head = this.buffer.subarray(0, end).toString('latin1');
        if (head.indexOf('101') < 0) {
          clearTimeout(timer);
          socket.destroy();
          reject(new Error('CDP 握手被拒：' + head.split('\r\n')[0]));
          return;
        }
        this.handshakeDone = true;
        clearTimeout(timer);
        const rest = this.buffer.subarray(end + 4);
        this.buffer = Buffer.alloc(0);
        if (rest.length > 0) this.consume(rest);
        resolve(true);
      });
      socket.on('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      socket.on('close', () => {
        for (const entry of this.pending.values()) {
          entry.reject(new Error('CDP 连接已关闭'));
        }
        this.pending.clear();
      });
    });
  }

  /** 发一条命令并等它的回复（按 id 配对）。 */
  send(method, params = {}, timeoutMs = 8000) {
    const id = this.nextId++;
    const payload = JSON.stringify({ id, method, params });
    this.writeText(payload);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP ${method} 超时`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        }
      });
    });
  }

  writeText(text) {
    const body = Buffer.from(text, 'utf8');
    const mask = crypto.randomBytes(4);
    const header = [];
    header.push(0x81);                    // FIN + text
    if (body.length < 126) {
      header.push(0x80 | body.length);
    } else if (body.length < 65536) {
      header.push(0x80 | 126, (body.length >> 8) & 0xFF, body.length & 0xFF);
    } else {
      header.push(0x80 | 127);
      const high = Math.floor(body.length / 4294967296);
      header.push((high >> 24) & 0xFF, (high >> 16) & 0xFF, (high >> 8) & 0xFF, high & 0xFF);
      header.push((body.length >>> 24) & 0xFF, (body.length >>> 16) & 0xFF,
        (body.length >>> 8) & 0xFF, body.length & 0xFF);
    }
    const head = Buffer.from(header);
    const masked = Buffer.alloc(body.length);
    for (let index = 0; index < body.length; index++) {
      masked[index] = body[index] ^ mask[index % 4];
    }
    this.socket.write(Buffer.concat([head, mask, masked]));
  }

  consume(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      if (this.buffer.length < 2) return;
      const opcode = this.buffer[0] & 0x0F;
      const masked = (this.buffer[1] & 0x80) !== 0;
      let length = this.buffer[1] & 0x7F;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        length = this.buffer.readUInt32BE(2) * 4294967296 + this.buffer.readUInt32BE(6);
        offset = 10;
      }
      let maskKey = null;
      if (masked) {
        if (this.buffer.length < offset + 4) return;
        maskKey = this.buffer.subarray(offset, offset + 4);
        offset += 4;
      }
      if (this.buffer.length < offset + length) return;
      let payload = Buffer.from(this.buffer.subarray(offset, offset + length));
      if (maskKey !== null) {
        for (let index = 0; index < payload.length; index++) {
          payload[index] = payload[index] ^ maskKey[index % 4];
        }
      }
      this.buffer = this.buffer.subarray(offset + length);
      if (opcode === 1) {
        this.handleMessage(payload.toString('utf8'));
      } else if (opcode === 8) {
        try {
          this.socket.end();
        } catch (error) {
          // 忽略
        }
        return;
      }
      // ping/pong/continuation 不处理
    }
  }

  handleMessage(text) {
    let data;
    try {
      data = JSON.parse(text);
    } catch (error) {
      return;
    }
    if (data.id === undefined) return;      // 事件，不是命令回复
    const entry = this.pending.get(data.id);
    if (entry === undefined) return;
    this.pending.delete(data.id);
    if (data.error !== undefined) {
      entry.reject(new Error(`CDP 报错：${data.error.message || JSON.stringify(data.error)}`));
    } else {
      entry.resolve(data.result);
    }
  }

  close() {
    try {
      this.socket.end();
      this.socket.destroy();
    } catch (error) {
      // 忽略
    }
  }
}

/* ------------------------------------------------------------------ 调试端口 */

/** 取 `/json/list`（页面列表）——纯 HTTP，不需要 WebSocket。 */
function fetchTargets(port, timeoutMs = 4000) {
  return new Promise((resolve) => {
    const req = http.request({
      host: '127.0.0.1',
      port: port,
      path: '/json/list',
      method: 'GET',
      timeout: timeoutMs
    }, (res) => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { raw += chunk; });
      res.on('end', () => {
        try {
          const list = JSON.parse(raw);
          resolve(Array.isArray(list) ? list : []);
        } catch (error) {
          resolve([]);
        }
      });
    });
    req.on('timeout', () => { req.destroy(); resolve([]); });
    req.on('error', () => resolve([]));
    req.end();
  });
}

function portFree(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(false));
    server.once('listening', () => {
      server.close(() => resolve(true));
    });
    server.listen(port, '127.0.0.1');
  });
}

/* ------------------------------------------------------------------ 读 Cookie */

/** IG 认的这些字段拼成 relay 用的 Cookie 串（顺序无关紧要，但字段要齐）。 */
const COOKIE_FIELDS = ['datr', 'ig_did', 'dpr', 'mid', 'csrftoken', 'ds_user_id',
  'sessionid', 'rur', 'ig_nrcb', 'ps_l', 'ps_n', 'wd'];

function buildCookieString(cookies) {
  const map = new Map();
  for (const item of cookies) {
    if (!item || typeof item.name !== 'string') continue;
    map.set(item.name, String(item.value));
  }
  const parts = [];
  for (const name of COOKIE_FIELDS) {
    const value = map.get(name);
    if (value !== undefined && value.length > 0) parts.push(`${name}=${value}`);
  }
  return parts.join('; ');
}

/** 打开调试端口后，连上第一个 page target，取出 instagram.com 的全部 Cookie。 */
async function readInstagramCookies(port, log) {
  const targets = await fetchTargets(port);
  const page = targets.find((item) => item && item.type === 'page' && typeof item.webSocketDebuggerUrl === 'string');
  if (page === undefined) return null;
  const socket = new CdpSocket(page.webSocketDebuggerUrl);
  try {
    await socket.connect();
    await socket.send('Network.enable');
    const result = await socket.send('Network.getAllCookies');
    const cookies = (result && result.cookies) || [];
    const instagram = cookies.filter((item) => String(item.domain || '').indexOf('instagram.com') >= 0);
    return instagram;
  } catch (error) {
    log(`读 Cookie 失败：${error.message}`);
    return null;
  } finally {
    socket.close();
  }
}

/* ----------------------------------------------------------------- 对外入口 */

/**
 * 走一遍"打开浏览器 → 你登录 → 取回 Cookie"。
 *
 * @param options.profileDir 专属 profile 目录（登录状态留在里面，别用日常浏览器的）
 * @param options.port       调试端口
 * @param options.timeoutMs  等多久算超时（默认 5 分钟）
 * @param options.log        日志函数
 * @returns {cookie, userId, browser} —— cookie 为空串表示没登录成功
 */
async function loginWithBrowser(options) {
  const log = options.log || ((text) => console.log(text));
  const profileDir = options.profileDir || path.join(__dirname, '.login-profile');
  const timeoutMs = options.timeoutMs || 5 * 60 * 1000;
  const browser = options.browser || findBrowser();
  if (browser.length === 0) {
    throw new Error('没找到 Edge / Chrome。也可以手动把 cookie 粘进 config.json 的 ig.cookie。');
  }

  let port = options.port || DEFAULT_DEBUG_PORT;
  while (!(await portFree(port))) {
    log(`调试端口 ${port} 被占用，换 ${port + 1}`);
    port++;
    if (port > (options.port || DEFAULT_DEBUG_PORT) + 20) {
      throw new Error('找不到空闲的调试端口。');
    }
  }

  fs.mkdirSync(profileDir, { recursive: true });
  log(`启动浏览器：${path.basename(browser)}（调试端口 ${port}）`);
  log('登录状态会存在这个专属 profile 里，不影响你平时用的浏览器。');
  const child = spawn(browser, [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-features=Translate',
    LOGIN_URL
  ], { detached: false, stdio: 'ignore' });
  child.on('error', (error) => {
    log(`浏览器启动失败：${error.message}`);
  });

  log('请在打开的窗口里登录 Instagram（2FA / 验证码都照常输）。');
  log('登录成功后我这边会自动把会话写进 config.json，不需要你复制任何东西。');

  const startedAt = Date.now();
  let lastHint = 0;
  while (Date.now() - startedAt < timeoutMs) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    const cookies = await readInstagramCookies(port, log);
    if (cookies === null) continue;
    const cookie = buildCookieString(cookies);
    const hasSession = cookie.indexOf('sessionid=') >= 0;
    const hasUser = cookie.indexOf('ds_user_id=') >= 0;
    if (hasSession && hasUser) {
      const userId = /ds_user_id=([^;]+)/.exec(cookie);
      log(`拿到会话了（账号 ${userId === null ? '?' : userId[1]}），Cookie 长度 ${cookie.length}`);
      return { cookie, userId: userId === null ? '' : userId[1], browser, port };
    }
    const elapsed = Math.round((Date.now() - startedAt) / 1000);
    if (elapsed - lastHint >= 20) {
      lastHint = elapsed;
      log(`还在等登录…（已等 ${elapsed} 秒，当前 Cookie 里有 ${cookies.length} 项但还没 sessionid）`);
    }
  }
  return { cookie: '', userId: '', browser, port };
}

module.exports = { loginWithBrowser, findBrowser, buildCookieString, COOKIE_FIELDS, LOGIN_URL };
