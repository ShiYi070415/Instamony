/*
 * 移动 API 客户端的**配置常量**（对应 instagrapi 的 `config.py`）。
 *
 * 这一层是"照抄"过来的：instagrapi 把设备型号、App 版本、bloks 版本号写死在配置里，
 * 请求头里那一大串 `X-IG-*` 都从这些值派生。我们同样需要一个默认设备档案 ——
 * 只不过 Instarmony 的**会话来自网页 Cookie 罐**（见 MobileSession），
 * 所以这些值的角色是"让请求看起来像一个真实的安卓客户端"，而不是"我们真的登录了这个设备"。
 *
 * ## 为什么要抄这么多版本号
 * IG 对 `unsupported_version` 很敏感（本项目在 core/NativeComments 已经踩过一次：
 * UA 里的版本号太旧会被判不支持）。instagrapi 保留多组 `APP_SETTINGS` 是为了在
 * 不同账号上轮换、降低指纹一致性；我们这里保留同样的多组，默认用最新的那组。
 */

/** 私有 API 的主机（instagrapi 的 `API_DOMAIN`）——**不是** www.instagram.com。 */
export const API_DOMAIN: string = 'i.instagram.com';

/**
 * User-Agent 模板（instagrapi 的 `USER_AGENT_BASE`）。
 *
 * 占位顺序与 instagrapi 逐字一致：app_version / android_version / android_release /
 * dpi / resolution / manufacturer / model / device / cpu / locale / version_code。
 */
export const USER_AGENT_BASE: string = 'Instagram {app_version} Android ({android_version}/'
  + '{android_release}; {dpi}; {resolution}; {manufacturer}; {model}; {device}; {cpu}; '
  + '{locale}; {version_code})';

/** App id：**安卓客户端**那个（网页那个是 1217981644879628，见 core/NativeFeed）。 */
export const APP_ID: string = '567067343352427';

/**
 * 默认设备档案（instagrapi 的 `DEVICE_SETTINGS`：Pixel 8 Pro / Android 14）。
 *
 * 和项目里既有那几处安卓身份（`NativeComments.APP_UA` 是 samsung SM-S918B）**故意不同**：
 * 那些是"网页会话冒充安卓"的临时身份，这里是"移动 API 客户端"的完整档案，
 * 除了 UA 还带 device/cpu/bloks 等一串头，混用会让两组头自相矛盾。
 */
export class DeviceProfile {
  readonly androidVersion: string;
  readonly androidRelease: string;
  readonly dpi: string;
  readonly resolution: string;
  readonly manufacturer: string;
  readonly model: string;
  readonly device: string;
  readonly cpu: string;

  constructor(androidVersion: string, androidRelease: string, dpi: string, resolution: string,
              manufacturer: string, model: string, device: string, cpu: string) {
    this.androidVersion = androidVersion;
    this.androidRelease = androidRelease;
    this.dpi = dpi;
    this.resolution = resolution;
    this.manufacturer = manufacturer;
    this.model = model;
    this.device = device;
    this.cpu = cpu;
  }

  static readonly DEFAULT: DeviceProfile = new DeviceProfile(
    '34', '14', '480dpi', '1344x2992', 'Google/google', 'Pixel 8 Pro', 'husky', 'husky');
}

/** 一组 App 版本配置（instagrapi 的 `APP_SETTINGS[...]`）。 */
export class AppProfile {
  readonly appVersion: string;
  readonly versionCode: string;
  readonly bloksVersioningId: string;

  constructor(appVersion: string, versionCode: string, bloksVersioningId: string) {
    this.appVersion = appVersion;
    this.versionCode = versionCode;
    this.bloksVersioningId = bloksVersioningId;
  }
}

/** 默认 App 版本（instagrapi 的 `DEFAULT_APP_VERSION`：449.0.0.52.84）。 */
export const DEFAULT_APP_VERSION: string = '449.0.0.52.84';

/**
 * App 版本表：键 = app_version（instagrapi 的 `APP_SETTINGS`）。
 *
 * 用 `Map` 而不是对象字面量：ArkTS 里用字符串索引对象不是强类型写法，
 * 而这里确实需要"按键查、查不到回退默认"的语义。
 *
 * 构造写在**声明之前**的工厂函数里：ArkTS 的类不做提升（和 TypeScript 不同），
 * 模块级拿一个后面才声明的类去 new 会直接编译不过。
 */
function buildAppSettings(): Map<string, AppProfile> {
  const map: Map<string, AppProfile> = new Map<string, AppProfile>();
  const list: Array<AppProfile> = [
    new AppProfile('449.0.0.52.84', '1079242191',
      '799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b'),
    new AppProfile('448.0.0.0.20', '1065560286',
      '0bc46a03e177bfc9bc8d611918815acf248fa9c77754d807d6a5951dc9ce9432'),
    new AppProfile('446.0.0.49.77', '385211303',
      '935a519904e9017324cdedb64a283a3c2c1a3d5b0bbc698b451f5aef72cc11df'),
    new AppProfile('428.0.0.47.67', '961145276',
      '7189b949425f9bf80ea8bd880cf5a3080b292d9b1c4b38a18d112f7c4b71e7a8'),
    new AppProfile('385.0.0.47.74', '378906843',
      'a8973d49a9cc6a6f65a4997c10216ce2a06f65a517010e64885e92029bb19221'),
    new AppProfile('364.0.0.35.86', '374010953',
      '8ccf54aad76788a6ca03ddfc33afcdcf692f2f5a3ba814ea73d5facba7fa2c2d')
  ];
  for (let index: number = 0; index < list.length; index++) {
    map.set(list[index].appVersion, list[index]);
  }
  return map;
}

export const APP_SETTINGS: Map<string, AppProfile> = buildAppSettings();

/**
 * 登录/托盘要用的一组"支持能力"（instagrapi 的 `SUPPORTED_CAPABILITIES`）。
 *
 * 只在少数端点（`feed/reels_tray/` 等）的表单体里出现，但它是**固定串**，
 * 照抄比自造安全 —— IG 会拿它判断客户端能力集。
 */
export const SUPPORTED_CAPABILITIES: string = '[{"value":"119.0,120.0,121.0,122.0,123.0,'
  + '124.0,125.0,126.0,127.0,128.0,129.0,130.0,131.0,132.0,133.0,134.0,135.0,136.0,137.0,'
  + '138.0,139.0,140.0,141.0,142.0","name":"SUPPORTED_SDK_VERSIONS"},'
  + '{"value":"14","name":"FACE_TRACKER_VERSION"},'
  + '{"value":"ETC2_COMPRESSION","name":"COMPRESSION"},'
  + '{"value":"gyroscope_enabled","name":"gyroscope"}]';

/**
 * 请求头里那几个**硬编码的固定串**（instagrapi 的 `base_headers` 里写死的那几项）。
 *
 * 为什么原样抄：这几个 `IG-U-*` / `X-IG-Nav-Chain` 在 instagrapi 里也是常量
 * （它并没有真的算它们），说明 IG 对其中内容并不严格校验 —— 但**缺了不行**。
 * 每个值里都嵌了自己的 user id 与一年后的时间戳，所以是**函数**而不是常量。
 */
export class FixedHeaders {
  /** 见 MobileConfig 的说明。 */
  static directRegionHint(userId: string): string {
    const nextYear: number = Math.floor(Date.now() / 1000) + 31536000;
    return `LLA,${userId},${nextYear}:`
      + '01f7bae7d8b131877d8e0ae1493252280d72f6d0d554447cb1dc9049b6b2c507c08605b7';
  }

  static shbid(userId: string): string {
    const nextYear: number = Math.floor(Date.now() / 1000) + 31536000;
    return `12695,${userId},${nextYear}:`
      + '01f778d9c9f7546cf3722578fbf9b85143cd6e5132723e5c93f40f55ca0459c8ef8a0d9f';
  }

  static shbts(userId: string): string {
    const now: number = Math.floor(Date.now() / 1000);
    const nextYear: number = now + 31536000;
    return `${now},${userId},${nextYear}:`
      + '01f7ace11925d0388080078d0282b75b8059844855da27e23c90a362270fddfb3fae7e28';
  }

  static rur(userId: string): string {
    const nextYear: number = Math.floor(Date.now() / 1000) + 31536000;
    return `RVA,${userId},${nextYear}:`
      + '01f7f627f9ae4ce2874b2e04463efdb184340968b1b006fa88cb4cc69a942a04201e544c';
  }
}

/** 请求头里另外几个固定值（见 FixedHeaders 的说明）。 */
export const NAV_CHAIN: string =
  '9MV:self_profile:2,ProfileMediaTabFragment:self_profile:3,9Xf:self_following:4';
export const IG_CAPABILITIES: string = '3brTv10=';
export const FB_HTTP_ENGINE: string = 'Tigon/MNS/TCP';

/** 网络超时（毫秒）。instagrapi 侧是 requests 的 read_timeout=25s，这里取同一量级。 */
export const CONNECT_TIMEOUT_MS: number = 10000;
export const READ_TIMEOUT_MS: number = 25000;

/** 默认语言与国家（instagrapi 的 `locale` / `country`）。 */
export const DEFAULT_LOCALE: string = 'en_US';
export const DEFAULT_COUNTRY: string = 'US';

/**
 * 时区（instagrapi 默认纽约，`-14400` 秒）。
 *
 * 为什么保留这个"不对"的默认值：它只是一个**上报字段**，而且 instagrapi 一直这么发；
 * 跟着系统时区走反而让"我们看起来像什么客户端"变得不稳定。要改就整体改。
 */
export const DEFAULT_TIMEZONE_OFFSET: number = -14400;
export const DEFAULT_TIMEZONE_NAME: string = 'GMT-04:00';
