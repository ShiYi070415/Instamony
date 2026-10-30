/*
 * **reels 解析用的纯数据模型**（给 workers/ReelsParseTask 的 `@Concurrent` 用）。
 *
 * 为什么单独一个文件：这些类型原来都在 `core/NativeReels` 里，而 `NativeReels` 又 import 了
 * `model/Reel`（那个类带 `@Observed` 装饰器）。TaskPool 线程里没有 ArkUI 的状态管理运行时：
 * worker 的模块图一旦把 `Reel` 拖进来，就会在 worker 里炸 ——
 *   `uncaught ReferenceError: Observed is not defined @Taskpool Thread func_main_0`
 * （2026-10-30 真机 reels 闪退就是它，堆栈指到 model/Reel.ts:75）。
 *
 * 所以：**纯字段类型全放这里**（只依赖彼此，不 import 任何 UI/装饰器模块），
 * worker 与 NativeReels 都从这里取。
 */
export interface IgCandidate {
  url?: string | null;
  width?: number | null;
  height?: number | null;
}

export interface IgImageVersions {
  candidates?: Array<IgCandidate> | null;
}

export interface IgVideoVersion {
  url?: string | null;
  width?: number | null;
  height?: number | null;
}

/** 浣滆€呯殑鍏虫敞鐘舵€侊紙Reels 椤甸偅棰楁寜閽寜 `following` 鐢伙級銆?*/
export interface IgFriendship {
  following?: boolean | null;
  followed_by_viewer?: boolean | null;
}

export interface IgUser {
  username?: string | null;
  profile_pic_url?: string | null;
  is_verified?: boolean | null;
  /** 浣滆€呯殑鏁板瓧 id锛圧eels 椤甸偅棰楀叧娉ㄦ寜閽鐢紝瑙?Reel.authorId锛夈€?*/
  pk?: string | number | null;
  id?: string | number | null;
  /** 鏈満鍏虫敞浠?濂逛簡娌℃湁锛堢湡鏈轰笂鎸傚湪 user 涓婏紝瑙?NativeTimelineParser 鍚屽悕缁撴瀯锛夈€?*/
  friendship_status?: IgFriendship | null;
}

export interface IgCaption {
  text?: string | null;
}

/** `edge_media_to_xxx { count }` 杩欑 GraphQL 鑰佸舰鐘讹紙瑙?IgClipsMedia 閲屽垎浜?鏀惰棌閭ｇ粍鍊欓€夊悕锛夈€?*/
export interface IgCountEdge {
  count?: number | null;
}

export interface IgSoundInfo {
  original_audio_title?: string | null;
}

export interface IgClipsMetadata {
  original_sound_info?: IgSoundInfo | null;
}

export interface IgClipsMedia {
  code?: string | null;
  /** 瀛楃涓插舰寮忕殑濯掍綋 id锛?9 浣嶆暟瀛楃殑绮剧‘褰㈠紡锛岃 mediaId 鐨勮鏄庯級銆?*/
  strong_id__?: string | null;
  /** 濯掍綋鏁板瓧 id锛坈liploader 涓庣偣璧?杞彂閮借瀹冿紝瑙?Reel.mediaId锛夈€?*/
  pk?: string | number | null;
  id?: string | number | null;
  original_width?: number | null;
  original_height?: number | null;
  video_versions?: Array<IgVideoVersion> | null;
  image_versions2?: IgImageVersions | null;
  user?: IgUser | null;
  caption?: IgCaption | null;
  clips_metadata?: IgClipsMetadata | null;
  like_count?: number | null;
  comment_count?: number | null;
  play_count?: number | null;
  ig_play_count?: number | null;
  /** 杞彂鏁帮紙鍙充晶鍔ㄤ綔鍖洪偅棰楄浆鍙戜笅闈㈢殑鏁板瓧锛夈€?*/
  media_repost_count?: number | null;
  /**
   * 鍒嗕韩鏁帮紙鍙充晶鍔ㄤ綔鍖洪偅棰?`share` 涓嬮潰鐨勬暟瀛楋級銆?
   *
   * 鐪熸満涓?clips 杩欐潯鏌ヨ**涓嶄竴瀹氱粰**锛屽瓧娈靛悕涔熶笉绋冲畾锛堝拰"涓嶇粰澶村儚 / 涓嶇粰 taken_at"
   * 鏄悓涓€绫荤█鐤忥級锛屾墍浠ヨ繖閲屽垪鍑犱釜鍊欓€夊悕锛屾寜椤哄簭鍙栫涓€涓湁鍊肩殑锛?
   *   `share_count` / `shares_count` / `media_share_count`锛?
   *   澶栧姞 GraphQL 鑰佸舰鐘?`edge_media_to_share { count }`銆?
   * 閮芥嬁涓嶅埌灏辨槸 0 鈥斺€?鐣岄潰閭ｄ竴棰楁暟瀛?*鏁撮涓嶇敾**锛堣 model/Reel.shareCount锛夈€?
   */
  share_count?: number | null;
  shares_count?: number | null;
  media_share_count?: number | null;
  /** IG 鍏紑杞借嵎閲岀湡瀹炲瓨鍦ㄧ殑"杞彂/鍒嗕韩"璁℃暟锛堣鍙栬瘉鏂囦欢锛歝lips 閲屽嚭鐜拌繃 12307锛夈€?*/
  reshare_count?: number | null;
  /**
   * "鍏抽棴鍒嗕韩"鐨?*寮€鍏?*锛屼笉鏄鏁帮紙甯冨皵鍊硷級锛涘垪鍦ㄨ繖閲屽彧鏄彁閱掑埆鎶婂畠褰撴垚鏁般€?
   */
  share_count_disabled?: boolean | null;
  edge_media_to_share?: IgCountEdge | null;
  /**
   * 鏀惰棌鏁帮紙鍙充晶鍔ㄤ綔鍖洪偅棰?`bookmark` 涓嬮潰鐨勬暟瀛楋級銆?
   *
   * IG 渚?*鍩烘湰涓嶅叕寮€**杩欎釜鏁板瓧锛堢綉椤典笉娓叉煋銆乧lips 杞借嵎閲岄€氬父杩炲瓧娈甸兘娌℃湁锛夛紝
   * 鎵€浠ュ嚑涔庢€绘槸 0 鈫?閭ｄ竴棰楁暟瀛椾笉鐢汇€傚€欓€夊悕鍚屽垎浜細`save_count` / `saves_count` /
   * `media_save_count` / `edge_media_to_save { count }`銆?
   */
  save_count?: number | null;
  saves_count?: number | null;
  media_save_count?: number | null;
  edge_media_to_save?: IgCountEdge | null;
  /** 鏈満鐐硅繃璧炴病鏈夛紙Reels 椤靛彸渚ч偅棰楀績鎸夊畠鐢伙級銆?*/
  has_liked?: boolean | null;
  viewer_has_liked?: boolean | null;
  /** 鏈満鏀惰棌浜嗘病鏈夛紙鐪熸満涓婅繖鏉?clips 鏌ヨ涓€鑸笉缁欙紝瑙?Reel.saved / core/SaveState锛夈€?*/
  has_saved?: boolean | null;
  viewer_has_saved?: boolean | null;
  /**
   * 鍙戝竷鏃堕棿锛氱Щ鍔ㄧ v1 濯掍綋瀵硅薄閲屾槸 **Unix 绉?*锛堝拰 `NativeTimelineParser` / `NativeSearch`
   * 璇荤殑鍚屼竴涓瓧娈碉級銆傜湡鏈鸿浇鑽?*涓嶄竴瀹氱粰**锛屾嬁涓嶅埌灏辨槸 0銆?
   */
  taken_at?: number | null;
  /** 鍚屼竴涓椂闂寸殑鍙︿竴绉嶅啓娉曪紙閮ㄥ垎杞借嵎鐢ㄦ绉掞紝瑙?NativeReels.takenAtMsOf 鐨勫吋瀹瑰鐞嗭級銆?*/
  taken_at_timestamp?: number | null;
}

export interface IgClipsNode {
  media?: IgClipsMedia | null;
}

export interface IgClipsEdge {
  node?: IgClipsNode | null;
}

export interface IgClipsPageInfo {
  end_cursor?: string | null;
  has_next_page?: boolean | null;
}

export interface IgClipsConnection {
  edges?: Array<IgClipsEdge> | null;
  page_info?: IgClipsPageInfo | null;
}

export interface IgClipsResponse {
  data?: Record<string, IgClipsConnection> | null;
}

/** 鍘熺敓鍙栧ソ鐨勪竴椤?reels銆?*/
/**
 * **璺ㄧ嚎绋嬪洖浼犵殑绾暟鎹?*锛圓1 鎵规锛夈€?
 *
 * 绾跨▼姹犻噷鍙兘鍥炰紶"绾瓧娈靛璞?锛屾墍浠ヨ繖閲屾樉寮忓０鏄庝竴涓被锛岃€屼笉鏄洖浼犲甫鏂规硶鐨勯〉闈㈠璞°€?
 */
export class ReelsPageRaw {
  media: Array<IgClipsMedia> = [];
  cursor: string = '';
  more: boolean = false;
}
