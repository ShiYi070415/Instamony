/*
 * 下载媒体（原图 / 原视频）并保存到相册。
 *
 * 两条路合起来才算"保存成功"：
 *   1) **下载到应用沙盒**：`request.downloadFile` 把原图/原视频落到 filesDir（IG 的 CDN 地址
 *      带签名、时效短，必须先落到本地）；
 *   2) **写进相册**：`photoAccessHelper.showAssetsCreationDialog` 弹系统授权窗拿目标 URI，
 *      再把沙盒文件 `copyFile` 过去。
 *
 * 为什么用授权弹窗而不是直接用 `createAsset`：`ohos.permission.WRITE_IMAGEVIDEO` 是受限权限
 * （应用申请不到），官方给的免权限路径就是"安全控件（SaveButton）或授权弹窗"
 * （见《保存媒体库资源》）。弹窗那条更适合我们现在这个自定义圆形按钮的外观需求。
 *
 * 全程不抛：失败返回一句可展示的状态文案，调用方直接弹出来。
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { request } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;
const TAG: string = 'MediaDownload';
/**
 * 一次下载最多等多久（毫秒）。
 *
 * 必须有这个上限（审计 E11）：`complete` / `fail` 都**可能不来**（网络卡在半路、
 * 任务被系统回收），原来那种"只挂两个监听"的写法下 Promise 永不 settle ——
 * 调用方的 `await` 永远不返回，沙盒里还留着一份半截文件。
 * 取 60 秒：IG 的图几秒、视频十几秒，正常都在里面。
 */
const DOWNLOAD_TIMEOUT_MS: number = 60000;

export class MediaDownloader {
  /**
   * 下载并保存。
   *
   * @param context  UIAbilityContext（页面里用 getUIContext().getHostContext() 取）
   * @param url      **原始**媒体地址（不是降级后的展示地址）
   * @param ext      扩展名（jpg / mp4）
   * @param title    相册里的标题（一般给 shortcode）
   * @param isVideo  true = 视频（决定 photoType 与资源类型）
   */
  static async save(context: common.UIAbilityContext, url: string, ext: string,
                    title: string, isVideo: boolean): Promise<boolean> {
    if (url.length === 0) {
      hilog.warn(DOMAIN, TAG, 'no url to download');
      return false;
    }
    const safeTitle: string = MediaDownloader.safeName(title);
    const path: string = `${context.filesDir}/dl_${safeTitle}_${Date.now()}.${ext}`;
    try {
      await MediaDownloader.download(context, url, path);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'download failed: %{public}s', (error as Error).message);
      return false;
    }
    try {
      await MediaDownloader.writeToGallery(context, path, ext, safeTitle, isVideo);
      hilog.info(DOMAIN, TAG, 'saved to gallery title=%{public}s ext=%{public}s', safeTitle, ext);
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'save to gallery failed: %{public}s', (error as Error).message);
      return false;
    } finally {
      // 沙盒里那份用完就删：不然每下载一次就留一份原图/原视频。
      try {
        fileIo.unlinkSync(path);
      } catch (error) {
      }
    }
  }

  /** 下载到沙盒（覆盖同名文件）。 */
  private static async download(context: common.UIAbilityContext, url: string,
                                path: string): Promise<void> {
    try {
      fileIo.unlinkSync(path);
    } catch (error) {
    }
    const task: request.DownloadTask = await request.downloadFile(context, { url: url, filePath: path });
    /*
     * `downloadFile` 的 promise 在"任务创建"时就会 resolve，真正下完要看事件。
     *
     * 这里必须自己收口（审计 E11）：
     *   - 两个事件都**可能不来** → 必须加超时，否则 Promise 永不 settle（调用方悬死、
     *     沙盒里留半截文件）；
     *   - 监听器原来从不 `off()` → 任务对象回调里闭着页面上下文，泄漏；
     *   - `complete` 与 `fail` 理论上可能都到（或超时后迟到）→ **只认第一个**。
     * 所以：settle 一次、挂掉的监听在 finish 里摘掉、失败/超时把半截文件删掉
     * （成功时由 `save` 的 finally 删）。
     */
    await new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      let settled: boolean = false;
      let timer: number = -1;
      const finish = (error: Error | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        try {
          task.off('complete');
        } catch (error) {
        }
        try {
          task.off('fail');
        } catch (error) {
        }
        if (error !== null) {
          try {
            fileIo.unlinkSync(path);
          } catch (error) {
          }
          reject(error);
          return;
        }
        resolve();
      };
      task.on('complete', (): void => {
        finish(null);
      });
      task.on('fail', (err: number): void => {
        finish(new Error(`download fail ${err}`));
      });
      timer = setTimeout((): void => {
        finish(new Error('download timeout'));
      }, DOWNLOAD_TIMEOUT_MS);
    });
  }

  /** 弹授权窗 → 拿到相册里的目标 URI → 把沙盒文件复制过去。 */
  private static async writeToGallery(context: common.UIAbilityContext, path: string, ext: string,
                                      title: string, isVideo: boolean): Promise<void> {
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    const config: photoAccessHelper.PhotoCreationConfig = {
      title: title,
      fileNameExtension: ext,
      photoType: isVideo ? photoAccessHelper.PhotoType.VIDEO : photoAccessHelper.PhotoType.IMAGE,
      subtype: photoAccessHelper.PhotoSubtype.DEFAULT
    };
    const destUris: Array<string> = await helper.showAssetsCreationDialog([path], [config]);
    if (destUris.length === 0) {
      throw new Error('no destination uri');
    }
    const dest: fileIo.File = await fileIo.open(destUris[0], fileIo.OpenMode.WRITE_ONLY);
    const src: fileIo.File = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    try {
      await fileIo.copyFile(src.fd, dest.fd);
    } finally {
      fileIo.closeSync(src);
      fileIo.closeSync(dest);
    }
  }

  /** 标题里只留字母数字（文件名里带 IG 的 shortcode 就够，别让特殊字符进路径）。 */
  private static safeName(title: string): string {
    const clean: string = title.replace(/[^A-Za-z0-9_-]/g, '');
    return clean.length > 0 ? clean : 'instamony';
  }
}
