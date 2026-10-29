/*
 * 按用户 id 取**头像**（只在"收藏 / 被标注"那两段需要用，见下）。
 *
 * ## 为什么需要
 * 收藏 / 被标注那两段查询里的 `user` 对象**只有 `pk / username / id`**
 * （真机实测：`avatar missing on user keys=pk,username,id,aigm_account_label_info`）——
 * 连一个头像字段都没有。于是那些帖子打开帖子页时，资料行左边就是一块空底色圆
 * （用户报的"需要正确显示用户头像"）。
 *
 * 视频帖的头像由 core/NativeMediaInfo 顺带带回来（那条 media info 响应里作者对象是全的），
 * 而**图片帖**没有这条请求，只能拿 id 单独问一次：
 *   `GET https://www.instagram.com/api/v1/users/{id}/info/` → `{ "user": { "profile_pic_url": … } }`
 *
 * ## 缓存与节流
 * 同一个人可能在一页里出现好几次（也可能连着几页都是他），所以**按 id 记住**，一次进程内
 * 只问一次。请求串行、由调用方限量（见 pages/Index.loadPostPageVideos），撞上限流就退避
 * （见 core/ApiThrottle）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { MobileRequest, MobileResult, MobileOptions } from './mobileapi/MobileRequest';
import { ApiThrottle } from './ApiThrottle';
// 读头像字段用的 JSON 取值工具（`users/{id}/info/` 的响应体）。
import { JsonRead } from './JsonRead';

const DOMAIN: number = 0xFF00;
const TAG: string = 'NativeUserInfo';

/** 一个用户对象里我们只要头像。 */
interface UserDto {
  profile_pic_url?: string;
  profile_pic_url_hd?: string;
  hd_profile_pic_url_info?: PicDto;
}

interface PicDto {
  url?: string;
}

interface UserInfoDto {
  status?: string;
  user?: UserDto;
}

export class NativeUserInfo {
  /** id → 头像（空串 = 问过了但没有）。一次进程内只问一次。 */
  private static readonly avatars: Map<string, string> = new Map<string, string>();

  /** 已经拿到的头像（没有给空串）。 */
  static cached(userId: string): string {
    const one: string | undefined = NativeUserInfo.avatars.get(userId.trim());
    return one === undefined ? '' : one;
  }

  /**
   * 取一个用户的头像。
   *
   * @returns 头像地址；没取到给空串（调用方保持空位，不假装有）。
   */
  static async avatarFor(userId: string): Promise<string> {
    const id: string = userId.trim();
    if (id.length === 0) {
      return '';
    }
    const known: string | undefined = NativeUserInfo.avatars.get(id);
    if (known !== undefined) {
      return known;
    }
    if (ApiThrottle.blocked(ApiThrottle.MEDIA_INFO)) {
      return '';
    }
    /*
     * **只走移动端私有接口**（`users/{pk}/info/`，App 身份）——
     * 原先那条"网页 REST + RestSession 模板头"已随模板机制删除。
     */
    let text: string = '';
    try {
      const result: MobileResult = await MobileRequest.send(
        `users/${encodeURIComponent(id)}/info/`, '', '', true, null,
        new MobileOptions(ApiThrottle.MEDIA_INFO, ApiThrottle.interactive()));
      if (result.ok) {
        text = result.body;
      } else {
        hilog.info(DOMAIN, TAG, 'user info miss id=%{public}s %{public}s', id, result.summary());
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'user info failed: %{public}s', (error as Error).message);
      text = '';
    }
    const avatar: string = NativeUserInfo.parse(text);
    // 问过就记住（包括"确实没有"），免得同一个人反复问。
    NativeUserInfo.avatars.set(id, avatar);
    hilog.info(DOMAIN, TAG, 'avatar id=%{public}s ok=%{public}s', id, `${avatar.length > 0}`);
    return avatar;
  }

  /** 响应 → 头像（字段名与 NativeProfile.avatarOf 一致：direct → hd → hd_info）。 */
  private static parse(text: string): string {
    if (text.length === 0) {
      return '';
    }
    let dto: UserInfoDto;
    try {
      dto = JSON.parse(text) as UserInfoDto;
    } catch (error) {
      return '';
    }
    const user: UserDto | undefined = dto.user;
    if (user === undefined) {
      return '';
    }
    const direct: string = user.profile_pic_url ?? '';
    if (direct.length > 0) {
      return direct;
    }
    const hd: string = user.profile_pic_url_hd ?? '';
    if (hd.length > 0) {
      return hd;
    }
    const info: PicDto | undefined = user.hd_profile_pic_url_info;
    return info === undefined ? '' : (info.url ?? '');
  }
}
