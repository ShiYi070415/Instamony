/*
 * **Reels 的 LazyForEach 数据源**：只把当前 Swiper 需要的那几页交给框架。
 *
 * 逻辑仍以 ReelsPage.reels 数组为准；每次整体替换时调 setAll() 同步到这里。
 */

import { Reel } from '../model/Reel';

export class ReelsDataSource implements IDataSource {
  private items: Array<Reel> = [];
  private listeners: Array<DataChangeListener> = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Object {
    return this.items[index];
  }

  setAll(items: Array<Reel>): void {
    this.items = items;
    for (let index: number = 0; index < this.listeners.length; index++) {
      this.listeners[index].onDataReloaded();
    }
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }
}
