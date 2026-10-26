/*
 * 正文翻译（"翻译 / 显示原文"那一颗按钮背后的东西）。
 *
 * 需求：帖子发布时间旁、评论"回复"旁、Reels 正文最后各放一个"翻译"；
 * **只有非中文文本才显示**；点了把正文翻成**系统语言**，按钮变成"显示原文"。
 *
 * ## 翻译从哪来
 * 这个 SDK 里**没有**可调用的端侧翻译 API（只有系统文本选择菜单里那个"翻译"项，那是系统自己的
 * 界面，App 调不到）。所以这里走**在线翻译**，而且**三个端点依次兜底**
 * （用户报"全部文本点翻译都失败"—— 真机自检落盘的结果是 `http-429`：
 *  gtx 那条被 Google 按 IP 限流了，只备一个端点等于功能随时整体挂掉）：
 *
 *   ① `translate.googleapis.com/translate_a/single`（gtx）——
 *      返回 `[[["译文","原文",…],[段2…]],null,"en"]`，长文本会切成多段，要拼起来；
 *   ② `clients5.google.com/translate_a/t?client=dict-chrome-ex` ——
 *      返回 `[["译文","en"]]`，整段一次给完（形状最简单，被限流的概率也更低）；
 *   ③ `api.mymemory.translated.net/get` —— 第三方免费接口（MyMemory），
 *      `langpair=Autodetect|<目标>`，返回 `{"responseData":{"translatedText":"…"}}`。
 *
 * 每一发都带**浏览器风格的请求头**（UA + Accept-Language + Accept）：不带 UA 的裸请求
 * 更容易被当成机器人，Google 那边直接 429。
 *
 * 谁先成功就把谁记成这个会话的首选（`preferred`），后面的调用直接走它 —— 避免每次都
 * 先吃一发 429 再降级。
 *
 * ⚠️ 这意味着**待翻译的文本会发到第三方**。要换成别的服务（自建接口、别的云），
 * 在 `attempt()` 里加一个分支即可；要彻底关掉，把 `enabled()` 改成恒 false（按钮不出现）。
 *
 * ## 为什么带缓存
 * 同一条正文会被反复求值（列表重建、展开/收起、翻页回来）。缓存按"目标语言 + 原文"存，
 * `CACHE_MAX` 之后从头淘汰（FIFO），避免无限涨。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { i18n } from '@kit.LocalizationKit';
import { common } from '@kit.AbilityKit';
import { InstagramProbe } from '../probe/InstagramProbe';

const DOMAIN: number = 0xFF00;
const TAG: string = 'Translator';
const CONNECT_TIMEOUT_MS: number = 6000;
const READ_TIMEOUT_MS: number = 9000;
/** 一页最多翻这么多字符（URL 别太长；正文本来也短）。 */
const MAX_CHARS: number = 1200;
/** 缓存多少条原文。 */
const CACHE_MAX: number = 64;
/**
 * 浏览器风格的请求头。**必须带**：自检落盘的结果是 gtx 回 `http-429`
 * （不带 UA 的裸请求会被当成机器人），带上以后同一台设备就恢复正常。
 */
const BROWSER_UA: string =
  'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) '
    + 'Chrome/124.0.0.0 Mobile Safari/537.36';
/** 三个引擎（顺序就是兜底顺序，见文件头）。 */
const ENGINE_GTX: number = 0;
const ENGINE_CLIENTS5: number = 1;
const ENGINE_MYMEMORY: number = 2;
/** MyMemory 把错误也塞在 `translatedText` 里返回，这些字样要当失败。 */
const MYMEMORY_BAD: Array<string> = ['INVALID SOURCE LANGUAGE', 'MYMEMORY WARNING', 'QUERY LENGTH LIMIT'];

/**
 * 启动自检（诊断用）：启动后把三个引擎各打一发，结果写日志 + 落盘
 * `filesDir/Instamony_translate.txt`。
 *
 * 为什么要有：用户报"全部文本点翻译都失败"时，界面里只弹一句"翻译失败"，点不出结论；
 * 而真机上 chromium 的日志会把 hilog 环形缓冲冲掉。一次自检把**每个端点的 http 码回原话**
 * 都记下来，就能立刻分清是"网络不通 / 被端点限流 / 解析不出"哪一种。
 * 平时可以关掉（置 false），不影响任何用户路径。
 */
const SELF_TEST_ON_START: boolean = true;
const SELF_TEST_DELAY_MS: number = 5000;
const SELF_TEST_TEXT: string = 'hello world';
/** 自检落盘的文件名（`InstagramProbe.dumpFixed` 会补 `.txt`）。 */
const REPORT_NAME: string = 'Instamony_translate';

/** 一发的尝试结果（成功/失败 + 原因）。 */
class TranslateTry {
  ok: boolean = false;
  text: string = '';
  detail: string = '-';

  constructor(ok: boolean, text: string, detail: string) {
    this.ok = ok;
    this.text = text;
    this.detail = detail;
  }
}

export class Translator {
  /** 原文 → 译文（FIFO 淘汰）。 */
  private static cache: Map<string, string> = new Map<string, string>();
  /** 最近一次失败的原因（给日志/提示用）。 */
  private static detail: string = '-';
  /** 启动自检只排一次（见 scheduleSelfTest）。 */
  private static selfTestScheduled: boolean = false;
  /** 这个会话里已经证实能用的引擎（-1 = 还不知道，按 ①②③ 的顺序试）。 */
  private static preferred: number = -1;

  /**
   * 清空译文缓存（退出登录 / 换账号时调）。
   *
   * 译文是按正文文本缓存的，里面全是被翻过的帖子文案 —— 属于"上一个人的内容"，
   * 清掉最省心（下次用到再翻一遍，成本也就是一次接口调用）。
   */
  static clear(): void {
    Translator.cache.clear();
    Translator.detail = '-';
    Translator.preferred = -1;
  }

  static lastDetail(): string {
    return Translator.detail;
  }

  /** 功能有没有被关掉（要停用就返回 false）。 */
  static enabled(): boolean {
    return true;
  }

  /**
   * 文本里有没有**日文假名**（平假名/片假名，含长音符 `ー`）。
   *
   * 为什么要单独判：日文是"假名 + 漢字"混排，而下面的 `hasChinese` 把整个 CJK 表意区
   * （\u4e00-\u9fff）都算成中文 —— 于是一句 "今日はいい天気ですね" 被判成中文，
   * 翻译按钮直接不出现（用户报的就是这个）。有假名就一定是日文，轮不到"含中文"那条判据。
   */
  static hasKana(text: string): boolean {
    return /[\u3040-\u30ff\u31f0-\u31ff]/.test(text);
  }

  /** 文本里有没有中文（有 → 不给翻译按钮，需求："只有非中文文本才显示该按钮"）。 */
  static hasChinese(text: string): boolean {
    return /[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef]/.test(text);
  }

  /**
   * 这段文字要不要显示"翻译"。
   *
   * 判据：**不是中文** ＋ 里面有**拉丁/西里尔/阿拉伯/日文假名/韩文**之类的字母（≥2 个）。
   * 这样纯数字、纯表情、纯标点不会冒出一颗按钮。
   */
  static needsTranslation(text: string): boolean {
    if (!Translator.enabled()) {
      return false;
    }
    const trimmed: string = text.trim();
    /*
     * 顺序很重要：**先看假名**，再看"含中文"。
     * 日文必然带漢字，若先走 `hasChinese` 就会被当成中文、按钮永不出现（日语用户报的 bug）；
     * 而中文从不含假名，所以"有假名 → 是日文"这条判据不会误伤中文。
     */
    if (trimmed.length < 2) {
      return false;
    }
    if (!Translator.hasKana(trimmed) && Translator.hasChinese(trimmed)) {
      return false;
    }
    const letters: RegExpMatchArray | null =
      trimmed.match(/[A-Za-z\u00c0-\u024f\u0370-\u03ff\u0400-\u04ff\u0600-\u06ff\u3040-\u30ff\uac00-\ud7af]/g);
    return letters !== null && letters.length >= 2;
  }

  /**
   * 目标语言 = **系统语言**（需求）。
   *
   * `getSystemLanguage()` 给的是 'zh-Hans-CN' / 'en-US' 这种；在线端点认 'zh-CN' / 'zh-TW' / 'en'，
   * 所以这里归一一下（简繁要分开，不然繁体用户会被翻成简体）。
   */
  static targetLang(): string {
    let lang: string = '';
    try {
      lang = i18n.System.getSystemLanguage();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'system language failed: %{public}s', (error as Error).message ?? '-');
    }
    return Translator.normalizeLang(lang);
  }

  /** 系统语言原话（自检里用来区分"目标语言取错了"和"网络不通"）。 */
  static systemLanguageRaw(): string {
    try {
      return i18n.System.getSystemLanguage();
    } catch (error) {
      return `-(${(error as Error).message ?? '-'})`;
    }
  }

  /** 'zh-Hans-CN' → 'zh-CN'，'en-US' → 'en'（端点只认这种）。 */
  private static normalizeLang(lang: string): string {
    if (lang.length === 0) {
      return 'zh-CN';
    }
    const lower: string = lang.toLowerCase();
    if (lower.startsWith('zh')) {
      return lower.indexOf('hant') >= 0 || lower.indexOf('tw') >= 0 || lower.indexOf('hk') >= 0
        ? 'zh-TW' : 'zh-CN';
    }
    // 其余取主语言（'en-US' → 'en'）：目标语言只要大语种就够。
    const dash: number = lower.indexOf('-');
    return dash > 0 ? lower.substring(0, dash) : lower;
  }

  /**
   * 翻译（带缓存）。失败给 null（调用方弹一句提示即可）。
   *
   * 命中缓存是**同步返回**的（Promise.resolve），所以第二次点"翻译"不会再有网络等待。
   */
  static async translate(text: string): Promise<string | null> {
    const source: string = text.trim();
    if (source.length === 0 || Translator.hasChinese(source)) {
      return null;
    }
    /*
     * **缓存键要带目标语言**（审计 E9）：原来只用原文当键，用户改了系统语言之后
     * 同一句原文会直接命中上一次那种语言的译文（界面上就是"切了语言还是旧语种"）。
     * `\u0000` 当分隔符：原文里不会出现它，不会和别的键撞。
     */
    const target: string = Translator.targetLang();
    const key: string = `${target}\u0000${source}`;
    const cached: string | undefined = Translator.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const clipped: string = source.length > MAX_CHARS ? source.substring(0, MAX_CHARS) : source;
    const order: Array<number> = Translator.engineOrder();
    const failures: Array<string> = [];
    for (let index: number = 0; index < order.length; index++) {
      const engine: number = order[index];
      const one: TranslateTry = await Translator.attempt(engine, clipped, target);
      if (one.ok) {
        if (Translator.preferred !== engine) {
          hilog.info(DOMAIN, TAG, 'engine %{public}s works → pinned', Translator.engineName(engine));
        }
        Translator.preferred = engine;
        Translator.detail = '-';
        Translator.remember(key, one.text);
        hilog.info(DOMAIN, TAG, 'translate ok %{public}s→%{public}s len=%{public}d via=%{public}s',
          'auto', target, one.text.length, Translator.engineName(engine));
        return one.text;
      }
      failures.push(`${Translator.engineName(engine)}=${one.detail}`);
      hilog.warn(DOMAIN, TAG, 'translate engine %{public}s failed: %{public}s',
        Translator.engineName(engine), one.detail);
    }
    // 三个都不行：把三份原因都留着（日志 + 提示来源），别只留最后一个。
    Translator.detail = failures.join(' | ').substring(0, 400);
    return null;
  }

  /** 要试的引擎顺序：已证实能用的排第一，其余按文件头的顺序。 */
  private static engineOrder(): Array<number> {
    const all: Array<number> = [ENGINE_GTX, ENGINE_CLIENTS5, ENGINE_MYMEMORY];
    if (Translator.preferred < 0) {
      return all;
    }
    const out: Array<number> = [Translator.preferred];
    for (let index: number = 0; index < all.length; index++) {
      if (all[index] !== Translator.preferred) {
        out.push(all[index]);
      }
    }
    return out;
  }

  private static engineName(engine: number): string {
    if (engine === ENGINE_CLIENTS5) {
      return 'clients5';
    }
    return engine === ENGINE_MYMEMORY ? 'mymemory' : 'gtx';
  }

  /** 公共请求头（见 BROWSER_UA 的说明：不带 UA 更容易被 429）。 */
  private static headersFor(target: string): Record<string, string> {
    const header: Record<string, string> = {};
    header['User-Agent'] = BROWSER_UA;
    header['Accept'] = '*/*';
    header['Accept-Language'] = `${target},${target};q=0.9,en;q=0.8`;
    return header;
  }

  /** 打一发（按 engine 选端点和解析方式，见文件头）。 */
  private static async attempt(engine: number, text: string, target: string): Promise<TranslateTry> {
    let url: string = '';
    if (engine === ENGINE_GTX) {
      url = `https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto`
        + `&tl=${encodeURIComponent(target)}&dt=t&q=${encodeURIComponent(text)}`;
    } else if (engine === ENGINE_CLIENTS5) {
      url = `https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl=auto`
        + `&tl=${encodeURIComponent(target)}&q=${encodeURIComponent(text)}`;
    } else {
      url = `https://api.mymemory.translated.net/get?q=${encodeURIComponent(text)}`
        + `&langpair=${encodeURIComponent(`Autodetect|${target}`)}`;
    }
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: Translator.headersFor(target),
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const body: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      if (response.responseCode !== 200) {
        return new TranslateTry(false, '', `http-${response.responseCode}:${Translator.plain(body)}`);
      }
      const translated: string = engine === ENGINE_MYMEMORY
        ? Translator.parseMyMemory(body) : (engine === ENGINE_CLIENTS5
          ? Translator.parseClients5(body) : Translator.parseGtx(body));
      if (translated.length === 0) {
        return new TranslateTry(false, '', `parse:${Translator.plain(body)}`);
      }
      /*
       * **"译文"等于原文**要当失败：MyMemory 的 `Autodetect` 经常认不出语种、
       * 直接把原文返回（真机自检里就见过 `hello world → hello world`）。
       * 不挡的话界面上会出现"点了翻译，正文一个字没变，按钮却变成显示原文"。
       */
      if (translated.trim().toLowerCase() === text.trim().toLowerCase()) {
        return new TranslateTry(false, '', 'same-text');
      }
      return new TranslateTry(true, translated, '-');
    } catch (error) {
      return new TranslateTry(false, '', `throw:${(error as Error).message ?? '-'}`.substring(0, 120));
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 响应体压成一行（日志/落盘用；HTML 换行会毁掉一行一条的格式）。 */
  private static plain(body: string): string {
    return body.replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim().substring(0, 160);
  }

  /**
   * 启动自检（诊断用，见 SELF_TEST_ON_START 的说明）。
   *
   * 三个引擎**各打一发**（不走缓存、不写缓存），把每一发的结果落盘：
   * `hdc file recv /data/app/el2/100/base/com.fanha.instarmony/haps/entry/files/Instamony_translate.txt`。
   */
  static scheduleSelfTest(context: common.UIAbilityContext): void {
    if (!SELF_TEST_ON_START || Translator.selfTestScheduled) {
      return;
    }
    Translator.selfTestScheduled = true;
    setTimeout((): void => {
      Translator.runSelfTest(context).catch((error: Error): void => {
        hilog.warn(DOMAIN, TAG, 'selftest threw: %{public}s', error.message ?? '-');
      });
    }, SELF_TEST_DELAY_MS);
  }

  private static async runSelfTest(context: common.UIAbilityContext): Promise<void> {
    const target: string = Translator.targetLang();
    const lines: Array<string> = [];
    const now: Date = new Date();
    lines.push(`Instamony 翻译自检 ${now.toISOString()}`);
    lines.push(`系统语言 ${Translator.systemLanguageRaw()} → 目标 ${target}`);
    let firstOk: string = '-';
    for (let index: number = 0; index < 3; index++) {
      const started: number = Date.now();
      const one: TranslateTry = await Translator.attempt(index, SELF_TEST_TEXT, target);
      const spent: number = Date.now() - started;
      lines.push(`${Translator.engineName(index)} ${one.ok ? 'ok' : 'FAIL'} ${spent}ms`
        + ` out=${one.ok ? one.text : one.detail}`);
      hilog.info(DOMAIN, TAG, 'selftest %{public}s ok=%{public}s %{public}dms %{public}s',
        Translator.engineName(index), `${one.ok}`, spent, one.ok ? one.text : one.detail);
      if (one.ok && firstOk === '-') {
        firstOk = Translator.engineName(index);
      }
    }
    lines.push(`结论 ${firstOk === '-' ? '全部失败' : `可用引擎 ${firstOk}`}`);
    /*
     * 把"哪一个能用"直接钉在**这个会话的首选**上：不然每次点翻译都要先吃一发 429
     * （真机上 gtx 那发要 400ms+），用户感知就是"点了要等一下才有反应"。
     */
    if (firstOk !== '-') {
      for (let index: number = 0; index < 3; index++) {
        if (Translator.engineName(index) === firstOk) {
          Translator.preferred = index;
        }
      }
    }
    lines.push(`首选 ${Translator.engineName(Translator.preferred)}`);
    try {
      const path: string = InstagramProbe.dumpFixed(context, REPORT_NAME, lines.join('\n'));
      hilog.info(DOMAIN, TAG, 'selftest report written %{public}s', path);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'selftest report failed: %{public}s', (error as Error).message ?? '-');
    }
  }

  /** 记进缓存（超了从头淘汰一条）。`key` 已经是 `目标语言\0原文`（见 translate）。 */
  private static remember(key: string, translated: string): void {
    if (Translator.cache.size >= CACHE_MAX) {
      const keys: Array<string> = Array.from(Translator.cache.keys());
      if (keys.length > 0) {
        Translator.cache.delete(keys[0]);
      }
    }
    Translator.cache.set(key, translated);
  }

  /**
   * 解析 gtx 的返回：`[[["译文","原文",…],[下一段…]],null,"en",…]`。
   *
   * 长文本会被切成多段，所以要**把所有段拼起来**（只取第一段会翻一半）。
   */
  private static parseGtx(body: string): string {
    try {
      const root: Object = JSON.parse(body);
      const outer: Array<Object> = root as Array<Object>;
      if (outer.length === 0) {
        return '';
      }
      const segments: Array<Object> = outer[0] as Array<Object>;
      let text: string = '';
      for (let index: number = 0; index < segments.length; index++) {
        const segment: Array<Object> = segments[index] as Array<Object>;
        if (segment.length === 0) {
          continue;
        }
        const piece: Object = segment[0];
        if (typeof piece === 'string') {
          text += piece as string;
        }
      }
      return text;
    } catch (error) {
      return '';
    }
  }

  /** `clients5` 的返回：`[["译文","en"]]`（整段一次给完，见文件头）。 */
  private static parseClients5(body: string): string {
    try {
      const root: Object = JSON.parse(body);
      const outer: Array<Object> = root as Array<Object>;
      if (outer.length === 0) {
        return '';
      }
      const first: Object = outer[0];
      // 正常是 `[["译文","en"]]`；个别情况下直接给字符串。
      if (typeof first === 'string') {
        return first as string;
      }
      const pair: Array<Object> = first as Array<Object>;
      if (pair.length === 0) {
        return '';
      }
      const piece: Object = pair[0];
      return typeof piece === 'string' ? piece as string : '';
    } catch (error) {
      return '';
    }
  }

  /**
   * MyMemory 的返回：`{"responseData":{"translatedText":"…"}}`。
   *
   * 它把**错误也当译文**塞在 `translatedText` 里（"INVALID SOURCE LANGUAGE" 之类），
   * 所以命中这些字样要按失败处理，否则界面上会显示一行英文报错。
   */
  private static parseMyMemory(body: string): string {
    try {
      const root: Object = JSON.parse(body);
      const box: Record<string, Object> = root as Record<string, Object>;
      const data: Object | undefined = box['responseData'];
      if (data === undefined || data === null) {
        return '';
      }
      const inner: Record<string, Object> = data as Record<string, Object>;
      const text: Object | undefined = inner['translatedText'];
      if (typeof text !== 'string') {
        return '';
      }
      const out: string = (text as string).trim();
      const upper: string = out.toUpperCase();
      for (let index: number = 0; index < MYMEMORY_BAD.length; index++) {
        if (upper.indexOf(MYMEMORY_BAD[index]) >= 0) {
          return '';
        }
      }
      return out;
    } catch (error) {
      return '';
    }
  }
}
