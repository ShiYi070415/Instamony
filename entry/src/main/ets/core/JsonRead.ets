/*
 * GraphQL / REST 响应的**通用读法**（原来长在 NativeProfile 里，被搜索页也要用，就搬出来共用）。
 *
 * 为什么需要这一层：IG 的响应是"形状会变"的 JSON —— 字段时有时无、数字有时是字符串、
 * 该是数组的地方偶尔给 null。ArkTS 里直接 `obj.a.b.c` 会在一处 null 上炸掉整个取数，
 * 所以统一走这几个"拿不到就给默认值"的读法，调用点只剩业务判据。
 *
 * 全部是静态无状态函数，**不解析业务含义**：认字段名的活儿留给各个 Native* 模块。
 */

export class JsonRead {
  /** 文本 → 对象；不是合法 JSON 就给空对象（调用方按"没读到"处理）。 */
  static parse(text: string): Record<string, Object> {
    try {
      return JSON.parse(text) as Record<string, Object>;
    } catch (error) {
      return {};
    }
  }

  /**
   * 文本 → 对象，但**先把大整数字段改成字符串**再解析。
   *
   * ## 为什么必须有这一条
   * IG 的 `thread_id` / `pk` 是 19~20 位（例如 `3402823668417103012`），**超过 double 能精确
   * 表示的整数范围**（2^53 ≈ 9.0e15）。`JSON.parse` 会先把它舍入成 double，再 `toString` 出来
   * 就是一串错的数字 —— 实测拿到 `340282366841710301281158034919` 这种 30 位 id，
   * 拿去请求 `/api/v1/direct_v2/threads/<错 id>` 直接被 IG 当成未登录回 404
   * （用户报的"打开会话显示 404"就是这个）。
   *
   * 做法：在解析**之前**给这些键的长数字补上引号（`"thread_id":123…` → `"thread_id":"123…"`），
   * 于是解析出来就是精确字符串，`strOf` 原样拿到。只处理已知的 id 类键，别的一律不动。
   */
  static parseWithBigIds(text: string): Record<string, Object> {
    try {
      /*
       * 键名用**白名单**（审计 E2）。
       *
       * 原来最后那个裸 `id` 会连带匹配 `media_id`（`"media_id":123…` 里的 `id"` 尾巴）——
       * 把媒体 id 也改成字符串，属于"顺手改了不该改的东西"。这里换成实际会读的那几个键：
       *   · 会话/用户：`thread_id`、`thread_v2_id`、`thread_fbid`、`thread_key`、`pk`、`user_id`、`strong_id__`
       *   · 消息：`message_id`、`sender_fbid`、`offline_threading_id`（**翻页游标就靠它**，必须精确）
       * 并且要求数字前没有引号（`"?` 那一段只在原本就有引号时命中，不会重复补）。
       */
      const fixed: string = text.replace(
        /("(?:thread_id|thread_v2_id|thread_fbid|thread_key|pk|user_id|strong_id__|message_id|sender_fbid|offline_threading_id)"\s*:\s*)(\d{16,})/g,
        '$1"$2"');
      return JSON.parse(fixed) as Record<string, Object>;
    } catch (error) {
      // 兜底：万一替换后的文本反而解析不了，就按普通解析再来一次。
      return JsonRead.parse(text);
    }
  }

  /** 任意值 → 对象；数组 / 标量 / null 都算"不是对象"。 */
  static asRecord(value: Object | null | undefined): Record<string, Object> | null {
    if (value === undefined || value === null || typeof value !== 'object') {
      return null;
    }
    if (Array.isArray(value)) {
      return null;
    }
    return value as Record<string, Object>;
  }

  /** 取某个键上的对象（拿不到给 null）。 */
  static recordOf(host: Record<string, Object>, key: string): Record<string, Object> | null {
    return JsonRead.asRecord(host[key]);
  }

  /** 取某个键上的数组（不是数组就给空数组，省掉调用点的判空）。 */
  static arrayOf(host: Record<string, Object>, key: string): Array<Object> {
    const value: Object | undefined = host[key];
    if (value === undefined || value === null || !Array.isArray(value)) {
      return [];
    }
    return value as Array<Object>;
  }

  /** 取字符串；数字也转成字符串（IG 有时候把 code 给成数字）。 */
  static strOf(host: Record<string, Object>, key: string): string {
    const value: Object | undefined = host[key];
    if (typeof value === 'string') {
      return value as string;
    }
    if (typeof value === 'number') {
      return `${value as number}`;
    }
    return '';
  }

  /** 取数字；字符串数字也认（"1,234" 这种带千分位的另外处理，见 asCount）。 */
  static numOf(host: Record<string, Object>, key: string): number {
    const value: Object | undefined = host[key];
    if (typeof value === 'number') {
      return value as number;
    }
    if (typeof value === 'string') {
      const parsed: number = Number(value as string);
      return Number.isFinite(parsed) ? parsed : 0;
    }
    return 0;
  }

  /** 取布尔：**只有 true 才算真**（IG 有时给 0/1，调用点按需自己判）。 */
  static boolOf(host: Record<string, Object>, key: string): boolean {
    return host[key] === true;
  }

  /** 键在不在（判断"这个字段有没有出现"比 `!== undefined` 更直白）。 */
  static has(host: Record<string, Object>, key: string): boolean {
    return host[key] !== undefined && host[key] !== null;
  }
}
