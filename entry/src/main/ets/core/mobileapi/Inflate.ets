/*
 * **纯 TS 的 zlib 解压**（MQTToT 收到的 PUBLISH 载荷是 zlib 压缩的 JSON）。
 *
 * ## 为什么要自己写
 * ArkTS 的 `@ohos.zlib` 只有**文件级**接口（`decompressFile` / `createGZip` 全是路径或 fd），
 * 没有内存 buffer 版；而 `GZip` 只认 gzip 容器，IG 发来的是 **zlib 容器**（头两字节 `78 01/9c/da`）。
 * 也没法绕道文件：一个私信推送几百字节，为它落一次盘再解压，代价和可靠性都不划算。
 *
 * ## 实现来源
 * 按 RFC 1950（zlib 容器）+ RFC 1951（deflate）写的，思路沿用 Mark Adler 的 `puff.c`：
 * 用"每个码长的个数 + 符号表"做**规范 Huffman 解码**（不建查找表），代码短、边界清楚。
 * 只需要**解压**，所以没有压缩那一半。
 *
 * ## 覆盖范围
 *   · stored（未压缩块）、固定 Huffman、动态 Huffman —— 三种块类型全覆盖；
 *   · zlib 头（CMF/FLG）校验、以及可选的 preset dictionary 跳过（IG 不用，但格式上要有）；
 *   · 尾部 Adler-32 **不校验**（省一遍全量累加；真要查错看返回的 null 就行）。
 *
 * 出错一律返回 `null`（不抛）：实时通道里一条坏包不该把整个连接带下来。
 */

/** 一个 Huffman 表（码长计数 + 按码长排好的符号）。 */
class HuffTable {
  /** `count[len]` = 长度为 len 的码有几个（len 1..15，下标 0 不用）。 */
  readonly count: Array<number> = new Array<number>(16).fill(0);
  /** 按"码长从小到大、同长按符号升序"排好的符号表。 */
  readonly symbol: Array<number> = [];
}

/** 长度码（257..285）的基准值与额外位数。 */
const LEN_BASE: Array<number> = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA: Array<number> = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
/** 距离码（0..29）的基准值与额外位数。 */
const DIST_BASE: Array<number> = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DIST_EXTRA: Array<number> = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
/** 动态块里"码长码"的发送顺序（RFC 1951 §3.2.7）。 */
const CODE_LENGTH_ORDER: Array<number> = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/** 固定 Huffman 表（RFC 1951 §3.2.6），建一次复用。 */
class FixedTables {
  static lit: HuffTable | null = null;
  static dist: HuffTable | null = null;

  static literal(): HuffTable {
    if (FixedTables.lit === null) {
      const lengths: Array<number> = [];
      for (let index: number = 0; index < 288; index++) {
        lengths.push(index < 144 ? 8 : index < 256 ? 9 : index < 280 ? 7 : 8);
      }
      FixedTables.lit = Inflate.build(lengths, 288);
    }
    return FixedTables.lit as HuffTable;
  }

  static distance(): HuffTable {
    if (FixedTables.dist === null) {
      const lengths: Array<number> = [];
      for (let index: number = 0; index < 30; index++) {
        lengths.push(5);
      }
      FixedTables.dist = Inflate.build(lengths, 30);
    }
    return FixedTables.dist as HuffTable;
  }
}

export class Inflate {
  /** 输入与读位状态。 */
  private data: Uint8Array;
  private pos: number = 0;
  private bitBuf: number = 0;
  private bitCnt: number = 0;
  /** 输出（用普通数组累加，最后一次性转 Uint8Array）。 */
  private out: Array<number> = [];
  /** 解压失败的标记（返回 null 用）。 */
  private bad: boolean = false;

  private constructor(data: Uint8Array) {
    this.data = data;
  }

  /**
   * 解压一个 **zlib 容器**（`78 xx` 开头）。
   *
   * 不是 zlib 容器（比如直接是 deflate 或纯 JSON）时返回 `null` —— 调用方据此回退到"当明文用"。
   */
  static zlibDecompress(bytes: Uint8Array): Uint8Array | null {
    if (bytes.length < 6) {
      return null;
    }
    const cmf: number = bytes[0];
    const flg: number = bytes[1];
    // CMF 低 4 位是压缩方法（8 = deflate），(CMF<<8|FLG) 必须是 31 的倍数。
    if ((cmf & 0x0F) !== 8 || ((cmf << 8) | flg) % 31 !== 0) {
      return null;
    }
    let offset: number = 2;
    if ((flg & 0x20) !== 0) {
      // 有 preset dictionary：跳过 4 字节字典 id（IG 不会用，格式上留着）。
      offset += 4;
    }
    if (offset >= bytes.length) {
      return null;
    }
    return Inflate.deflate(bytes.subarray(offset));
  }

  /** 解压一段裸 deflate 流。 */
  static deflate(bytes: Uint8Array): Uint8Array | null {
    const inflater: Inflate = new Inflate(bytes);
    inflater.run();
    if (inflater.bad) {
      return null;
    }
    const result: Uint8Array = new Uint8Array(inflater.out.length);
    for (let index: number = 0; index < inflater.out.length; index++) {
      result[index] = inflater.out[index];
    }
    return result;
  }

  /**
   * 把"可能是 zlib / 可能是明文"的载荷变成字节：能解压就解压，不能就原样返回。
   *
   * 对应 instagrapi 的 `try_decompress_payload`（它也是先看首字节是不是 0x78）。
   */
  static tryDecompress(bytes: Uint8Array): Uint8Array {
    if (bytes.length > 2 && bytes[0] === 0x78) {
      const out: Uint8Array | null = Inflate.zlibDecompress(bytes);
      if (out !== null) {
        return out;
      }
    }
    return bytes;
  }

  // ------------------------------------------------------------------ 解码主体

  /** 逐块解码，直到遇到 BFINAL 或出错。 */
  private run(): void {
    let last: boolean = false;
    while (!last && !this.bad) {
      last = this.bits(1) === 1;
      const type: number = this.bits(2);
      if (type === 0) {
        this.stored();
      } else if (type === 1) {
        this.codes(FixedTables.literal(), FixedTables.distance());
      } else if (type === 2) {
        this.dynamic();
      } else {
        this.bad = true;
      }
    }
  }

  /** 读 n 位（低位在前）。 */
  private bits(need: number): number {
    let value: number = this.bitBuf;
    while (this.bitCnt < need) {
      if (this.pos >= this.data.length) {
        this.bad = true;
        return 0;
      }
      value |= this.data[this.pos++] << this.bitCnt;
      this.bitCnt += 8;
    }
    this.bitBuf = value >> need;
    this.bitCnt -= need;
    return value & ((1 << need) - 1);
  }

  /** 丢掉当前字节里剩下的位（stored 块要字节对齐）。 */
  private align(): void {
    this.bitBuf = 0;
    this.bitCnt = 0;
  }

  /** 块类型 0：未压缩，原样拷贝。 */
  private stored(): void {
    this.align();
    if (this.pos + 4 > this.data.length) {
      this.bad = true;
      return;
    }
    const len: number = this.data[this.pos] | (this.data[this.pos + 1] << 8);
    const nlen: number = this.data[this.pos + 2] | (this.data[this.pos + 3] << 8);
    this.pos += 4;
    if ((len ^ 0xFFFF) !== nlen) {
      this.bad = true;
      return;
    }
    if (this.pos + len > this.data.length) {
      this.bad = true;
      return;
    }
    for (let index: number = 0; index < len; index++) {
      this.out.push(this.data[this.pos + index]);
    }
    this.pos += len;
  }

  /** 块类型 2：动态 Huffman（先读码长表，再解数据）。 */
  private dynamic(): void {
    const nlen: number = this.bits(5) + 257;
    const ndist: number = this.bits(5) + 1;
    const ncode: number = this.bits(4) + 4;
    if (nlen > 286 || ndist > 30) {
      this.bad = true;
      return;
    }
    const lengths: Array<number> = new Array<number>(19).fill(0);
    for (let index: number = 0; index < ncode; index++) {
      lengths[CODE_LENGTH_ORDER[index]] = this.bits(3);
    }
    const lengthTable: HuffTable | null = Inflate.build(lengths, 19);
    if (lengthTable === null) {
      this.bad = true;
      return;
    }
    // 码长本身也是 Huffman 编码的：16/17/18 是"重复"指令。
    const all: Array<number> = [];
    while (all.length < nlen + ndist) {
      const symbol: number = this.decode(lengthTable);
      if (symbol < 0) {
        this.bad = true;
        return;
      }
      if (symbol < 16) {
        all.push(symbol);
      } else if (symbol === 16) {
        if (all.length === 0) {
          this.bad = true;
          return;
        }
        const prev: number = all[all.length - 1];
        const repeat: number = 3 + this.bits(2);
        for (let index: number = 0; index < repeat; index++) {
          all.push(prev);
        }
      } else if (symbol === 17) {
        const repeat: number = 3 + this.bits(3);
        for (let index: number = 0; index < repeat; index++) {
          all.push(0);
        }
      } else {
        const repeat: number = 11 + this.bits(7);
        for (let index: number = 0; index < repeat; index++) {
          all.push(0);
        }
      }
    }
    const lit: HuffTable | null = Inflate.build(all.slice(0, nlen), nlen);
    const dist: HuffTable | null = Inflate.build(all.slice(nlen, nlen + ndist), ndist);
    if (lit === null || dist === null) {
      this.bad = true;
      return;
    }
    this.codes(lit, dist);
  }

  /** 用两张表解一段数据（长度码 + 距离码）。 */
  private codes(lit: HuffTable, dist: HuffTable): void {
    while (!this.bad) {
      const symbol: number = this.decode(lit);
      if (symbol < 0) {
        this.bad = true;
        return;
      }
      if (symbol < 256) {
        this.out.push(symbol);
        continue;
      }
      if (symbol === 256) {
        return;                       // 块结束
      }
      const lenIndex: number = symbol - 257;
      if (lenIndex >= LEN_BASE.length) {
        this.bad = true;
        return;
      }
      const length: number = LEN_BASE[lenIndex] + this.bits(LEN_EXTRA[lenIndex]);
      const distSymbol: number = this.decode(dist);
      if (distSymbol < 0 || distSymbol >= DIST_BASE.length) {
        this.bad = true;
        return;
      }
      const distance: number = DIST_BASE[distSymbol] + this.bits(DIST_EXTRA[distSymbol]);
      if (distance > this.out.length) {
        this.bad = true;
        return;
      }
      // 逐字节拷贝（距离可能小于长度，必须一字节一字节来）。
      const from: number = this.out.length - distance;
      for (let index: number = 0; index < length; index++) {
        this.out.push(this.out[from + index]);
      }
    }
  }

  /**
   * 规范 Huffman 解码（puff.c 的算法）：一位一位读，靠"码长计数"定位符号。
   *
   * @returns 符号下标；-1 = 码表不合法或输入提前用完。
   */
  private decode(table: HuffTable): number {
    let code: number = 0;
    let first: number = 0;
    let index: number = 0;
    for (let len: number = 1; len <= 15; len++) {
      code |= this.bits(1);
      if (this.bad) {
        return -1;
      }
      const count: number = table.count[len];
      if (code - count < first) {
        return table.symbol[index + (code - first)];
      }
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    return -1;
  }

  /**
   * 由"每个符号的码长"建出规范 Huffman 表。
   *
   * @param lengths 各符号的码长（0 = 该符号不出现）
   * @param count 符号个数
   */
  static build(lengths: Array<number>, count: number): HuffTable | null {
    const table: HuffTable = new HuffTable();
    for (let index: number = 0; index < count; index++) {
      const len: number = index < lengths.length ? lengths[index] : 0;
      if (len > 0) {
        table.count[len]++;
      }
    }
    // 不完整码表（只有 1 个符号 / 全空）在 deflate 里是合法的特例，这里按 puff 的做法放行。
    let left: number = 1;
    for (let len: number = 1; len <= 15; len++) {
      left <<= 1;
      left -= table.count[len];
      if (left < 0) {
        return null;                  // 码长超订（over-subscribed）
      }
    }
    const offsets: Array<number> = new Array<number>(16).fill(0);
    for (let len: number = 1; len < 15; len++) {
      offsets[len + 1] = offsets[len] + table.count[len];
    }
    // 先把符号表按总量铺满（按下标赋值，不能靠 push 的顺序）。
    let total: number = 0;
    for (let len: number = 1; len <= 15; len++) {
      total += table.count[len];
    }
    for (let index: number = 0; index < total; index++) {
      table.symbol.push(0);
    }
    for (let symbol: number = 0; symbol < count; symbol++) {
      const len: number = symbol < lengths.length ? lengths[symbol] : 0;
      if (len !== 0) {
        table.symbol[offsets[len]] = symbol;
        offsets[len] = offsets[len] + 1;
      }
    }
    return table;
  }
}
