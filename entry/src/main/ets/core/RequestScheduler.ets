/*
 * **只读请求合并器**：同一个 key 在飞行中时复用同一个 Promise。
 *
 * 调用方负责把账号/代次拼进 key；写请求不要走这里。
 */

export class RequestScheduler {
  private static readonly inflight: Map<string, Promise<Object>> = new Map();

  static share<T extends Object>(key: string, task: () => Promise<T>): Promise<T> {
    const running: Promise<Object> | undefined = RequestScheduler.inflight.get(key);
    if (running !== undefined) {
      return running as Promise<T>;
    }
    const started: Promise<T> = task();
    RequestScheduler.inflight.set(key, started as Promise<Object>);
    started.then((): void => {
      RequestScheduler.inflight.delete(key);
    }).catch((): void => {
      RequestScheduler.inflight.delete(key);
    });
    return started;
  }

  static has(key: string): boolean {
    return RequestScheduler.inflight.has(key);
  }

  static clear(): void {
    RequestScheduler.inflight.clear();
  }
}
