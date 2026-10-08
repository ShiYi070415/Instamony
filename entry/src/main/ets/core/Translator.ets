/*
 * 正文翻译（"翻译 / 显示原文"那一颗按钮背后的东西）。
 *
 * 需求：帖子发布时间旁、评论"回复"旁、Reels 正文最后各放一个"翻译"；
 * **只有非中文文本才显示**；点了把正文翻成**系统语言**，按钮变成"显示原文"。
 *
 * ## 翻译从哪来
 * 这个 SDK 里**没有**可调用的端侧翻译 API（只有系统文本选择菜单里那个"翻译"项，那是系统自己的
 * 界面，App 调不到）。所以这里走**在线翻译**：Google 的公开 gtx 端点（`translate_a/single`）。
 * 请求体很小、返回是纯 JSON 数组，解析稳。
 *
 * ⚠️ 这意味着**待翻译的文本会发到第三方**。要换成别的服务（自建接口、别的云），只改
 * `ENDPOINT` 与 `parse()` 两个地方；要彻底关掉，把 `enabled()` 改成恒 false 即可（按钮不出现）。
 *
 * ## 为什么带缓存
 * 同一条正文会被反复求值（列表重建、展开/收起、翻页回来）。缓存按"原文"存，`CACHE_MAX` 之后
 * 从头淘汰（FIFO），避免无限涨。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { i18n } from '@kit.LocalizationKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'Translator';
/** 在线翻译端点（见文件头：换成别的服务只改这里和 parse）。 */
const ENDPOINT: string = 'https://translate.googleapis.com/translate_a/single';
const CONNECT_TIMEOUT_MS: number = 6000;
const READ_TIMEOUT_MS: number = 9000;
/** 一页最多翻这么多字符（URL 别太长；正文本来也短）。 */
const MAX_CHARS: number = 1200;
/** 缓存多少条原文。 */
const CACHE_MAX: number = 64;

export class Translator {
  /** 原文 → 译文（FIFO 淘汰）。 */
  private static cache: Map<string, string> = new Map<string, string>();
  /** 最近一次失败的原因（给日志/提示用）。 */
  private static detail: string = '-';

  static lastDetail(): string {
    return Translator.detail;
  }

  /** 功能有没有被关掉（要停用就返回 false）。 */
  static enabled(): boolean {
    return true;
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
    if (trimmed.length < 2 || Translator.hasChinese(trimmed)) {
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
    const cached: string | undefined = Translator.cache.get(source);
    if (cached !== undefined) {
      return cached;
    }
    const target: string = Translator.targetLang();
    const clipped: string = source.length > MAX_CHARS ? source.substring(0, MAX_CHARS) : source;
    const url: string = `${ENDPOINT}?client=gtx&sl=auto&tl=${encodeURIComponent(target)}`
      + `&dt=t&q=${encodeURIComponent(clipped)}`;
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const body: string = typeof response.result === 'string'
        ? response.result as string : JSON.stringify(response.result);
      if (response.responseCode !== 200) {
        Translator.detail = `http-${response.responseCode}`;
        hilog.warn(DOMAIN, TAG, 'translate failed: %{public}s', Translator.detail);
        return null;
      }
      const translated: string = Translator.parse(body);
      if (translated.length === 0) {
        Translator.detail = 'parse';
        hilog.warn(DOMAIN, TAG, 'translate parse failed body=%{public}s', body.substring(0, 120));
        return null;
      }
      Translator.detail = '-';
      Translator.remember(source, translated);
      hilog.info(DOMAIN, TAG, 'translate ok %{public}s→%{public}s len=%{public}d',
        'auto', target, translated.length);
      return translated;
    } catch (error) {
      Translator.detail = `throw:${(error as Error).message ?? '-'}`.substring(0, 60);
      hilog.warn(DOMAIN, TAG, 'translate threw: %{public}s', Translator.detail);
      return null;
    } finally {
      try {
        request.destroy();
      } catch (error) {
      }
    }
  }

  /** 记进缓存（超了从头淘汰一条）。 */
  private static remember(source: string, translated: string): void {
    if (Translator.cache.size >= CACHE_MAX) {
      const keys: Array<string> = Array.from(Translator.cache.keys());
      if (keys.length > 0) {
        Translator.cache.delete(keys[0]);
      }
    }
    Translator.cache.set(source, translated);
  }

  /**
   * 解析 gtx 的返回：`[[["译文","原文",…],[下一段…]],null,"en",…]`。
   *
   * 长文本会被切成多段，所以要**把所有段拼起来**（只取第一段会翻一半）。
   */
  private static parse(body: string): string {
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
}
