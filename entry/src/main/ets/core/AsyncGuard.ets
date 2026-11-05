/*
 * **写请求 busy 门**：同一个业务 key 正在请求时，拒绝第二次进入。
 *
 * 只做去重，不做重试/取消；调用方负责在 finally 里 end()。
 */

export class AsyncGuard {
  private readonly keys: Set<string> = new Set<string>();

  /** 尝试进入：false = 已有同名请求在飞。 */
  tryBegin(key: string): boolean {
    if (this.keys.has(key)) {
      return false;
    }
    this.keys.add(key);
    return true;
  }

  end(key: string): void {
    this.keys.delete(key);
  }

  has(key: string): boolean {
    return this.keys.has(key);
  }

  clear(): void {
    this.keys.clear();
  }
}
