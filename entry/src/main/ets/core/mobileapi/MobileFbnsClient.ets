/*
 * **FBNS 客户端（连接层）**：两段式握手 → 订阅 → 拿 push token → 交给 IG 注册。
 *
 * 对应 `tools/relay/fbns.js` 的 `FbnsClient`；报文/解码在 `MobileFbns.ets`（已离线对拍到逐字节一致）。
 *
 * 为什么 App 需要这条连接：iris 的 `edge-mqtt` 认的是**网页会话**（`cookie_auth` + sessionid）；
 * 设备级会话（只有 `Authorization: Bearer IGT:2:…`）走那条路会 `CONNACK rc=5`。FBNS 是 IG
 * 给设备推消息的另一条连接（`mqtt-mini.facebook.com`，`clientType="device_auth"`）。
 *
 * 关键顺序（照 relay，别改）：
 *   1. 没有设备凭据时先**用空身份**连一次，CONNACK 载荷里下发 `ck/cs/di/ds`；
 *   2. 用这份凭据重连；
 *   3. 订阅 topic 76，往 79 发 `{pkg_name, appid}`（zlib 压缩），token 从 80 回来；
 *   4. 把 token 交给 IG（`push/register/`），之后新私信才会推过来。
 */

import { socket } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FBNS_APP_ID, FBNS_HOST, FBNS_KEEPALIVE_S, FBNS_PACKAGE, FBNS_PORT, FBNS_TOPIC_PUSH, FBNS_TOPIC_REGISTER, FBNS_TOPIC_REQUEST, FbnsAuth, FbnsPacket, FbnsThrift, FbnsWire, MobileFbns } from './MobileFbns';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MobileFbnsClient';
const STORE_NAME: string = 'instarmony_fbns';
const STORE_KEY: string = 'auth_v1';

/** CONNACK 结果（引导阶段要用 `payload`）。 */
class FbnsConnack {
  returnCode: number = -1;
  payload: Uint8Array = new Uint8Array(0);

  constructor(returnCode: number, payload: Uint8Array) {
    this.returnCode = returnCode;
    this.payload = payload;
  }
}

/**
 * FBNS 设备凭据的落盘（等价于 relay 的 `fbns-auth.json`）。
 *
 * 为什么要落盘：这份凭据是"这台设备"的身份，IG 按它认人；每次启动重新握手会让
 * 服务端把我们当成"天天换设备的新机器"，推送 token 也跟着变。
 */
export class FbnsAuthStore {
  private static store: preferences.Preferences | null = null;

  static init(context: common.Context): void {
    if (FbnsAuthStore.store !== null) {
      return;
    }
    try {
      FbnsAuthStore.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'open fbns store failed: %{public}s', (error as Error).message);
    }
  }

  static load(): FbnsAuth {
    const out: FbnsAuth = new FbnsAuth();
    const store: preferences.Preferences | null = FbnsAuthStore.store;
    if (store === null) {
      return out;
    }
    const text: string = String(store.getSync(STORE_KEY, '') as string);
    if (text.length === 0) {
      return out;
    }
    try {
      const record: Record<string, ESObject> = JSON.parse(text) as Record<string, ESObject>;
      out.clientId = `${record['clientId'] === undefined ? '' : record['clientId']}`;
      out.userId = Number(`${record['userId'] === undefined ? 0 : record['userId']}`) || 0;
      out.password = `${record['password'] === undefined ? '' : record['password']}`;
      out.deviceId = `${record['deviceId'] === undefined ? '' : record['deviceId']}`;
      out.deviceSecret = `${record['deviceSecret'] === undefined ? '' : record['deviceSecret']}`;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'parse fbns auth failed: %{public}s', (error as Error).message);
    }
    return out;
  }

  static save(auth: FbnsAuth): void {
    const store: preferences.Preferences | null = FbnsAuthStore.store;
    if (store === null) {
      return;
    }
    const record: Record<string, ESObject> = {
      'clientId': auth.clientId,
      'userId': auth.userId,
      'password': auth.password,
      'deviceId': auth.deviceId,
      'deviceSecret': auth.deviceSecret,
      'savedAt': Date.now()
    };
    try {
      store.putSync(STORE_KEY, JSON.stringify(record));
      store.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save fbns auth failed: %{public}s', (error as Error).message);
    }
  }

  static clear(): void {
    const store: preferences.Preferences | null = FbnsAuthStore.store;
    if (store === null) {
      return;
    }
    try {
      store.putSync(STORE_KEY, '');
      store.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clear fbns auth failed: %{public}s', (error as Error).message);
    }
  }
}

/** push token 到手后的回调（由会话层负责 `push/register/`）。 */
type FbnsTokenHandler = (token: string) => void;
/** 收到一条 FBNS 推送（topic 76）时的回调。 */
type FbnsPushHandler = (push: ESObject) => void;

export class MobileFbnsClient {
  private sock: socket.TLSSocket | null = null;
  /** 收包缓冲（MQTT 会拆包，必须自己拼）。 */
  private buffer: Array<number> = [];
  private auth: FbnsAuth = new FbnsAuth();
  private packetId: number = 1;
  private up: boolean = false;
  private pingTimer: number = -1;
  /** 断线重连定时器（-1 = 没有排程）。 */
  private reconnectTimer: number = -1;
  /** 当前重连退避（毫秒）。 */
  private reconnectDelay: number = 1000;
  /** 是否已经被显式 stop()（stop 之后不再自动重连）。 */
  private stopped: boolean = true;
  private connackWaiter: ((result: FbnsConnack) => void) | null = null;
  private onToken: FbnsTokenHandler | null = null;
  private onPush: FbnsPushHandler | null = null;
  private clientId: string = '';

  constructor(clientId: string = '') {
    this.clientId = clientId;
  }

  /** 是否已连上（`up` 为假时可以重连）。 */
  isUp(): boolean {
    return this.up;
  }

  /**
   * 连上 FBNS 并拿到 push token（两段式）。
   *
   * @param clientId 设备级会话的客户端 id（relay 用 sessionid 前 20 字符；这里用设备 uuid）
   */
  async start(clientId: string, onToken: FbnsTokenHandler,
              onPush: FbnsPushHandler): Promise<boolean> {
    this.stopped = false;
    this.onToken = onToken;
    this.onPush = onPush;
    this.clientId = clientId.length > 0 ? clientId : this.clientId;
    this.auth = FbnsAuthStore.load();
    if (this.auth.clientId.length === 0) {
      this.auth.clientId = this.clientId.substring(0, 20);
    }
    if (!this.auth.hasCredentials()) {
      hilog.info(DOMAIN, TAG, 'no device credentials -> bootstrap with empty identity');
      const bootAuth: FbnsAuth = new FbnsAuth(this.auth.clientId, 0);
      const boot: FbnsConnack = await this.connectOnce(bootAuth);
      if (boot.returnCode !== 0) {
        hilog.warn(DOMAIN, TAG, 'bootstrap failed rc=%{public}d', boot.returnCode);
        this.closeSocket();
        return false;
      }
      this.absorb(boot.payload);
      this.closeSocket();
      if (!this.auth.hasCredentials()) {
        hilog.warn(DOMAIN, TAG, 'bootstrap gave no credentials');
        return false;
      }
      FbnsAuthStore.save(this.auth);
      hilog.info(DOMAIN, TAG, 'device credentials absorbed (device=%{public}db)',
        this.auth.deviceId.length);
    }
    const connack: FbnsConnack = await this.connectOnce(this.auth);
    if (connack.returnCode !== 0) {
      hilog.warn(DOMAIN, TAG, 'connect failed rc=%{public}d', connack.returnCode);
      this.closeSocket();
      return false;
    }
    this.up = true;
    hilog.info(DOMAIN, TAG, 'fbns up (user=%{public}d)', this.auth.userId);
    this.requestPushToken();
    this.startPing();
    return true;
  }

  /** 一次 CONNECT + 等 CONNACK（成功时 socket 保持连接）。 */
  private connectOnce(auth: FbnsAuth): Promise<FbnsConnack> {
    return new Promise<FbnsConnack>((resolve: (value: FbnsConnack) => void): void => {
      let settled: boolean = false;
      const finish = (result: FbnsConnack): void => {
        if (settled) {
          return;
        }
        settled = true;
        this.connackWaiter = null;
        resolve(result);
      };
      (async (): Promise<void> => {
        try {
          const ref: socket.TLSSocket = socket.constructTLSSocketInstance();
          this.sock = ref;
          this.buffer = [];
          this.connackWaiter = finish;
          await ref.bind({ address: '0.0.0.0', port: 0 });
          await ref.connect({
            address: { address: FBNS_HOST, port: FBNS_PORT },
            secureOptions: {},
            timeout: 15000
          });
          ref.on('message', (info: socket.SocketMessageInfo): void => {
            if (this.sock !== ref) {
              return;
            }
            this.onBytes(new Uint8Array(info.message));
          });
          ref.on('close', (): void => {
            // **只有当前这条连接**的关闭才影响状态：引导阶段那条 socket 用完就关，
            // 它的 close 事件晚到时如果直接 `up = false`，会把手上的正式连接判成"掉线"，
            // 于是心跳不再发、服务端 60 秒后把我们踢掉（真机就是这么丢的）。
            if (this.sock !== ref) {
              return;
            }
            this.up = false;
            hilog.info(DOMAIN, TAG, 'fbns closed');
            this.scheduleReconnect('closed');
          });
          ref.on('error', (err: BusinessError): void => {
            const detail: string = `${err === undefined || err === null ? 'unknown' : err.code}`
              + '/' + `${err === undefined || err === null || err.message === undefined
                ? 'no-message' : err.message}`;
            hilog.warn(DOMAIN, TAG, 'fbns socket error: %{public}s', detail);
            if (this.sock !== ref) {
              return;
            }
            this.up = false;
            finish(new FbnsConnack(-1, new Uint8Array(0)));
            this.scheduleReconnect('error');
          });
          const packet: Uint8Array = MobileFbns.buildConnect(auth, FBNS_KEEPALIVE_S, Date.now());
          await ref.send(packet.buffer as ArrayBuffer);
          hilog.info(DOMAIN, TAG, 'CONNECT sent len=%{public}d user=%{public}d',
            packet.length, auth.userId);
          setTimeout((): void => {
            finish(new FbnsConnack(-2, new Uint8Array(0)));
          }, 15000);
        } catch (error) {
          hilog.warn(DOMAIN, TAG, 'connect error: %{public}s', (error as Error).message);
          finish(new FbnsConnack(-1, new Uint8Array(0)));
        }
      })();
    });
  }

  /** 从 CONNACK 载荷里吸收设备凭据（`ck/cs/di/ds`）。 */
  private absorb(payload: Uint8Array): void {
    const parsed: ESObject = MobileFbns.parsePayload(payload);
    if (parsed === null || parsed === undefined || typeof parsed !== 'object') {
      return;
    }
    const record: Record<string, ESObject> = parsed as Record<string, ESObject>;
    const read = (name: string): string => {
      const value: ESObject = record[name];
      return value === undefined || value === null ? '' : `${value}`;
    };
    const ck: string = read('ck');
    const cs: string = read('cs');
    const di: string = read('di');
    const ds: string = read('ds');
    if (ck.length > 0) {
      this.auth.userId = Number(ck) || this.auth.userId;
    }
    if (cs.length > 0) {
      this.auth.password = cs;
    }
    if (di.length > 0) {
      this.auth.deviceId = di;
      this.auth.clientId = di.substring(0, 20);
    }
    if (ds.length > 0) {
      this.auth.deviceSecret = ds;
    }
  }

  /** 申请 push token：先订阅 76，再往 79 发注册请求（响应在 80）。 */
  private requestPushToken(): void {
    const ref: socket.TLSSocket | null = this.sock;
    if (ref === null) {
      return;
    }
    this.packetId += 1;
    const subscribe: Uint8Array = MobileFbns.buildSubscribe(FBNS_TOPIC_PUSH, this.packetId);
    this.packetId += 1;
    const body: string = JSON.stringify({
      'pkg_name': FBNS_PACKAGE,
      'appid': FBNS_APP_ID
    });
    const compressed: Array<number> = FbnsWire.zlibStored(FbnsThrift.utf8(body));
    const publish: Uint8Array = MobileFbns.buildPublish(FBNS_TOPIC_REQUEST,
      new Uint8Array(compressed), this.packetId);
    this.sendBytes(subscribe);
    this.sendBytes(publish);
    hilog.info(DOMAIN, TAG, 'push token requested (subscribe+publish sent)');
  }

  private sendBytes(bytes: Uint8Array): void {
    const ref: socket.TLSSocket | null = this.sock;
    if (ref === null) {
      return;
    }
    ref.send(bytes.buffer as ArrayBuffer).catch((error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'send failed: %{public}s', error.message);
    });
  }

  /** 收字节 → 拆帧 → 分发。 */
  private onBytes(chunk: Uint8Array): void {
    for (let index: number = 0; index < chunk.length; index++) {
      this.buffer.push(chunk[index]);
    }
    for (;;) {
      if (this.buffer.length < 2) {
        return;
      }
      let multiplier: number = 1;
      let remaining: number = 0;
      let offset: number = 1;
      let complete: boolean = false;
      while (offset < this.buffer.length && offset <= 4) {
        const one: number = this.buffer[offset];
        remaining += (one & 0x7F) * multiplier;
        multiplier *= 128;
        offset++;
        if ((one & 0x80) === 0) {
          complete = true;
          break;
        }
      }
      if (!complete) {
        return;
      }
      const total: number = offset + remaining;
      if (this.buffer.length < total) {
        return;
      }
      const frame: Uint8Array = new Uint8Array(this.buffer.slice(0, total));
      this.buffer = this.buffer.slice(total);
      this.handleFrame(frame);
    }
  }

  private handleFrame(frame: Uint8Array): void {
    const packet: FbnsPacket = MobileFbns.decodePacket(frame);
    if (packet.kind === 'connack') {
      const waiter: ((result: FbnsConnack) => void) | null = this.connackWaiter;
      if (waiter !== null) {
        waiter(new FbnsConnack(packet.returnCode, packet.payload));
      }
      return;
    }
    if (packet.kind === 'publish') {
      if (packet.packetId >= 0) {
        this.sendBytes(MobileFbns.buildPuback(packet.packetId));
      }
      this.handlePublish(packet);
      return;
    }
    if (packet.kind === 'pingresp') {
      return;
    }
    hilog.info(DOMAIN, TAG, 'fbns frame type=%{public}d', packet.code);
  }

  private handlePublish(packet: FbnsPacket): void {
    const parsed: ESObject = MobileFbns.parsePayload(packet.payload);
    if (packet.topic === FBNS_TOPIC_REGISTER) {
      let token: string = '';
      if (parsed !== null && parsed !== undefined && typeof parsed === 'object') {
        const record: Record<string, ESObject> = parsed as Record<string, ESObject>;
        const value: ESObject = record['token'];
        token = value === undefined || value === null ? '' : `${value}`;
      }
      hilog.info(DOMAIN, TAG, 'push token received (%{public}d chars)', token.length);
      const handler: FbnsTokenHandler | null = this.onToken;
      if (handler !== null && token.length > 0) {
        handler(token);
      }
      return;
    }
    if (packet.topic === FBNS_TOPIC_PUSH) {
      let push: ESObject = parsed;
      if (parsed !== null && parsed !== undefined && typeof parsed === 'object') {
        const record: Record<string, ESObject> = parsed as Record<string, ESObject>;
        const inner: ESObject = record['fbpushnotif'];
        if (inner !== undefined && inner !== null) {
          if (typeof inner === 'string') {
            try {
              push = JSON.parse(inner as string) as ESObject;
            } catch (error) {
              push = parsed;
            }
          } else {
            push = inner;
          }
        }
      }
      const handler: FbnsPushHandler | null = this.onPush;
      if (handler !== null) {
        handler(push);
      }
      return;
    }
    hilog.info(DOMAIN, TAG, 'fbns topic=%{public}s (ignored)', packet.topic);
  }

  private startPing(): void {
    this.stopPing();
    this.pingTimer = setInterval((): void => {
      if (!this.up) {
        return;
      }
      this.sendBytes(MobileFbns.buildPingreq());
    }, 30 * 1000);
  }

  private stopPing(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
  }

  /**
   * 断线后自动重连（指数退避，封顶 30 秒）。
   *
   * 为什么必须有：FBNS 的 socket 会在服务端换连接、网络切换、静默超时等情况下被动断开
   * （真机上首条私信之后 26 秒就收到过一次 `socket error`）。没有重连 = **此后一条推送都收不到**，
   * 表现正是"通知突然没反应"，而且没有任何可见提示。
   */
  private scheduleReconnect(reason: string): void {
    if (this.stopped || this.reconnectTimer >= 0) {
      return;
    }
    const delay: number = this.reconnectDelay;
    this.reconnectDelay = Math.min(30000, this.reconnectDelay * 2);
    hilog.info(DOMAIN, TAG, 'reconnect in %{public}dms (%{public}s)', delay, reason);
    this.reconnectTimer = setTimeout((): void => {
      this.reconnectTimer = -1;
      if (this.stopped) {
        return;
      }
      const token: FbnsTokenHandler | null = this.onToken;
      const push: FbnsPushHandler | null = this.onPush;
      if (token === null || push === null) {
        return;
      }
      this.start(this.clientId, token, push).then((ok: boolean): void => {
        if (ok) {
          this.reconnectDelay = 1000;
          hilog.info(DOMAIN, TAG, 'reconnect ok');
        } else {
          this.scheduleReconnect('retry-failed');
        }
      }).catch((): void => {
        this.scheduleReconnect('retry-threw');
      });
    }, delay);
  }

  /** 只关 socket（引导连接用完就走这里）。 */
  private closeSocket(): void {
    const ref: socket.TLSSocket | null = this.sock;
    if (ref === null) {
      return;
    }
    this.sock = null;
    this.up = false;
    try {
      ref.close();
    } catch (error) {
      // 忽略
    }
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.stopPing();
    this.closeSocket();
    this.buffer = [];
  }
}
