/*
 * **帖子卡片**：一张"这条帖子本体"的卡片（作者 + 关注 / 完整正文 / 发布时间 / 查看翻译）。
 *
 * ## 它现在的角色：评论面板里的**一块**（不是浮层了）
 * 需求最新一版把"点 Reels 正文"和"点动作栏评论图标"重新合到**同一个评论面板**里，靠一个开关区分：
 *   · 点动作栏评论图标 → 评论面板，**不带**卡片（和以前完全一致）；
 *   · 点 Reels 正文     → 同一个评论面板，**带**这张卡片，位置是**评论列表的第一项**
 *     （`ListItem`，随评论一起滚；加载中/空列表这两档没有 List，退回「评论」标题下方）。
 * 开关是 `CommentsPanel.showPostCard`（数据由 pages/Index 的 `commentsWithCard` 给），本组件
 * 因此**只画卡片本身**：没有遮罩、没有关闭按钮、没有自己的定位/入场动画 —— 那些原来是为
 * "独立浮层"服务的（见文件末尾"上一版的浮层那套已经删掉"的说明），现在全归评论面板。
 *
 * ## 呈现方式：**静态玻璃**（沉浸光感材质，但关掉光源与拖拽）
 * 需求一路变过来：
 *   ① 最早是一颗透明 Toggle 承载沉浸光感 —— 材质自带的光源/形变让它在面板里"發亮"；
 *   ② 用户要求"取消卡片的 light 效果"，于是改成纯色表面（`app.color.field_background`）；
 *   ③ 最新一版又要"恢复沉浸光感的玻璃观感，但不要光源、不要拖拽" —— 也就是**静态玻璃**。
 * 所以现在卡片的底色重新走材质（`SurfaceModifier` + `immersiveMaterial`，见 MaterialSurface），
 * 但显式把两个交互开关关掉：
 *   · `lightEffect = false` → `lightEffect: null`（官方：设 null 即关闭光感交互反馈）；
 *   · `interactive = false` → 不做按下/拖动的材质形变。
 * 于是它是一块"贴在那里的玻璃"：看得出材质、有层次，但不会跟着手指动、也不会一碰就发光。
 * 另外两个参数维持原样：`invert = false`（内容用主题色，同评论面板底层那颗材质）、
 * `applyShadow = true`（材质自带那圈很轻的阴影，就是它的轮廓来源）。
 * 外面再补一圈 1vp 的 `app.color.divider` 极轻边框：材质生效时系统会接管底色/边框/阴影，
 * 这圈边框实际只在**降级分支**（API < 26 的兜底）里看得到，用来替卡片兜住轮廓。
 * **用户资讯栏胶囊与关注按钮仍然是材质**（那是组件自身，见 MaterialSurface），不能跟着改。
 *
 * 为什么材质挂在**卡片根节点**上（一颗 Toggle）：内容区里只有 Toggle / Slider / Select 拿得到
 * 沉浸光感（官方《沉浸光感–功耗优化》，见 MaterialSurface 文件头），而这张卡片的高度是**内容
 * 撑出来的** —— "底层空 Toggle + 上层内容"那种写法要求父容器高度已定（评论面板、输入条都是），
 * 这里用不了（详见 build 里的说明）。
 *
 * ## 左对齐 / 头像三边等距（需求："头像左侧间距 = 头像上/下间距"）
 * 胶囊的内缩抽成一个常量 `AVATAR_INSET_VP = (行高 40 - 头像 32) / 2 = 4`：头像在胶囊里
 * **左 / 上 / 下三边等距**（右边是账号名，所以不给）。上一版把胶囊左内边距写成 0（为了让头像
 * 和正文同一条左边界），这一版按新需求改成 4 —— 以最新的需求为准。
 *
 * ## 4-way lock（需求："用户资讯栏整行和关注按钮接同一套四向锁定"）
 * 和 MaterialSurface 里那套完全一致，分两半：
 *   · 按钮侧：`onTouch(trackMaterialTouch)` 记"按住"，再挂一条自己的 `PanGesture(consumePan)`
 *     把落在它上面的滑动**占住**（横向拖动不会误触、也不会带着卡片/面板走）；
 *   · 外层侧：卡片自己的 `Scroll` 挂 `trackScrollTouch` + `onGestureRecognizerJudgeBegin`，
 *     用 `holdsScroll` 在**手势判定那一刻**否掉内建 PAN —— 所以"按下去就划"的竖向拖动仍然
 *     交给外面的滚动（不会出现"手指落在胶囊上就滚不动"的卡手感）。
 * 关注按钮本身是 `MaterialLabelButton`，那两半它自己已经带了，这里不用再包一层。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import {
  MaterialLabelButton, SurfaceModifier, consumePan, holdsScroll, trackMaterialTouch, trackScrollTouch
} from './MaterialSurface';
import { TranslateLabel } from './TranslateLabel';
import { Translator } from '../core/Translator';
import { FollowState, FOLLOW_VERSION_KEY } from '../core/FollowState';
import { NativeFollow } from '../core/NativeFollow';

const DOMAIN = 0xFF00;
const TAG = 'InstarmonyPostCard';

/**
 * 卡片内边距（vp，**四边同一个值**）。
 *
 * 它是卡片正文/时间的**左基准**（见文件头）：头像多内缩了 `AVATAR_INSET_VP`，那是胶囊自己的事。
 */
const CARD_PAD_VP: number = 16;
/**
 * 卡片里**行与行之间**的垂直间距（vp）。
 *
 * 资讯栏 ↔ 正文、正文 ↔ 时间、时间 ↔ 「查看翻译」三处都吃这一个值，节奏才匀。
 */
const CARD_GAP_VP: number = 10;
/**
 * 卡片圆角（vp）：比评论面板（22）小一号，一眼能看出它是"面板里的一张卡"。
 */
const CARD_RADIUS_VP: number = 20;
/**
 * 卡片高度上限（占屏幕高度的比例）。
 *
 * 正文是**完整显示、不截断**的（需求），长配文能把卡片顶穿 —— 但卡片现在活在评论面板里，
 * 上方还有「评论」标题、下方还有评论列表，所以上限比"独立浮层那版"（0.68）收紧到 0.3：
 * 再高就把评论列表挤没了。超过上限的部分交给卡片自己的 `Scroll`。
 */
const CARD_MAX_HEIGHT_RATIO: number = 0.3;
/** 量不到屏幕高度时的兜底上限（vp）。 */
const CARD_MAX_HEIGHT_FALLBACK: number = 220;
/** 头像直径（vp）：和信息流作者行 / 评论行同一档（32）。 */
const AVATAR_SIZE: number = 32;
/**
 * 资讯栏 / 关注按钮那一行的高度（vp）。
 *
 * 40 = 全 app 材质按钮的标准高度（见 MaterialSurface 的 `MATERIAL_PILL_HEIGHT`）。
 */
const ROW_HEIGHT: number = 40;
/**
 * **头像在胶囊里的三边内缩**（vp，需求："头像左侧间距 = 头像上/下间距"）。
 *
 * 由行高与头像直径算出来 —— 改这两个数，左/上/下会一起跟着变，不会出现"改了一边忘另一边"。
 */
const AVATAR_INSET_VP: number = (ROW_HEIGHT - AVATAR_SIZE) / 2;
/** 关注按钮宽度（vp）：两个字 + 内边距（和 Reels 作者行那颗一致）。 */
const FOLLOW_PILL_WIDTH: number = 74;
/** 账号名可占的最大宽度（vp）：太长的名字不许把关注按钮顶出卡片。 */
const NAME_MAX_WIDTH_VP: number = 190;
/** 正文的字号 / 行高（vp）：和信息流卡片正文同一档。 */
const CAPTION_FONT_SIZE: number = 14;
const CAPTION_LINE_HEIGHT: number = 20;
/**
 * 译文切换的线性补间时长（毫秒）。
 *
 * 需求："用 animateTo({ duration: 200, curve: Curve.Linear }) 包住状态切换，不要弹性/缓动"。
 * 曲线**只有这一个来源**（`Curve.Linear`）：切换与节点过渡都读它，改一处两边一起变。
 */
const TRANSLATE_ANIM_MS: number = 200;
/**
 * 译文那层字的阴影。
 *
 * 译文按要求**显式白色**（需求："译文文字颜色必须是白色，卡片里也一样"），而卡片底色是主题色
 * （浅色模式下是浅灰）—— 不加阴影，白字在浅底上会糊成一片。参数同画面上的那层浮字：
 * 半径 6 / 下移 1 / 60% 黑。
 */
const TRANSLATED_TEXT_SHADOW: ShadowOptions = {
  radius: 6, color: '#99000000', offsetX: 0, offsetY: 1
};
/** 相对时间分档（毫秒）—— 和信息流/评论那套 `posted_ago_*` 文案一致（见 FeedList.postedAgo）。 */
const AGO_MINUTE_MS: number = 60 * 1000;
const AGO_HOUR_MS: number = 60 * AGO_MINUTE_MS;
const AGO_DAY_MS: number = 24 * AGO_HOUR_MS;
const AGO_WEEK_MS: number = 7 * AGO_DAY_MS;
const AGO_MONTH_MS: number = 30 * AGO_DAY_MS;
const AGO_YEAR_MS: number = 365 * AGO_DAY_MS;

/**
 * 卡片上的**头像**（加载失败就退回占位图标）。
 *
 * 为什么不写成 @Builder：失败状态要**存在组件里**（`Image` 加载失败时自己会画一个破图，
 * 用户报的"一个无法显示该贴图的组件"就是它）。CDN 直链过一阵会失效，摆一个破图比什么都不画难看。
 */
@Component
struct CardAvatar {
  /** url 变了要把"失败过"的标记清掉（理由同 CommentsPanel.CommentAvatar）。 */
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop boxSize: number = AVATAR_SIZE;
  @State private failed: boolean = false;

  private onUrlChanged(): void {
    this.failed = false;
  }

  build() {
    if (this.url.length > 0 && !this.failed) {
      Image(this.url)
        .draggable(false)
        .width(this.boxSize)
        .height(this.boxSize)
        .borderRadius(this.boxSize / 2)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.field_background'))
        .onError((): void => {
          this.failed = true;
        })
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.person'))
          .fontSize(this.boxSize * 0.56)
          .fontColor([$r('app.color.secondary_text')])
      }
      .width(this.boxSize)
      .height(this.boxSize)
      .borderRadius(this.boxSize / 2)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.field_background'))
    }
  }
}

/**
 * **帖子卡片**（对外只有一个组件，宿主是 `CommentsPanel`：
 * `if (this.showPostCard) { PostCardPanel({...}) }`，见那个文件里的插入位置）。
 */
@Component
export struct PostCardPanel {
  /** 作者账号名（空 = 整张卡片只剩正文那一截）。 */
  @Prop @Watch('onOwnerChanged') ownerUsername: string = '';
  /** 作者头像直链（空就画占位图标）。 */
  @Prop ownerAvatar: string = '';
  /** 这条帖子的**完整正文**（卡片里不截断，见文件头）。 */
  @Prop caption: string = '';
  /**
   * 作者的**数字 id** 与这条的**发布时刻**（毫秒；0 = 未知）。
   *
   * 关注那颗按钮要 id 才点得动（见 NativeFollow），"3小时前"要时刻才算得出。
   * 拿不到（空串 / 0）时对应那截不画 —— 不猜、也不显示 "0"。
   */
  @Prop @Watch('onOwnerChanged') ownerId: string = '';
  @Prop createdAtMs: number = 0;
  /**
   * **我自己的账号名**（宿主传进来）：作者是我自己时不画关注按钮
   * （和 ReelsPage 的 ReelOverlay.isOwnAuthor 同一个判据）。
   */
  @Prop ownAuthor: string = '';
  /** 材质厚度（只给资讯栏胶囊用，跟设定页联动，见 SurfaceModifier）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /**
   * 关注状态是**会话级覆盖表**说了算（在别处点过也要跟着变，见 core/FollowState）。
   *
   * 卡片现在活在评论面板里（面板可能一直开着）：用户在旁边的动作栏点了关注，这里也要刷成「已关注」。
   */
  @StorageLink(FOLLOW_VERSION_KEY) @Watch('onFollowVersion') followVersion: number = 0;
  /** 作者我关注了没有。 */
  @State private following: boolean = false;
  /** 关注请求进行中（防连点）。 */
  @State private followBusy: boolean = false;
  /** 这次打开问过"关注状态"没有（见 ensureFollowState）。 */
  private followAsked: boolean = false;
  /**
   * 正文现在显示的是**译文**吗（「查看翻译 / 显示原文」切换，需求："点击后就地展示译文"）。
   *
   * 用两个字段而不是一个 Map：一张卡片只有一段正文，不需要 CommentsPanel 那套按文本记账。
   */
  @State private showingTranslation: boolean = false;
  /** 翻好的译文（还没翻出来时是空串，正文那一格退回原文）。 */
  private translation: string = '';
  /** 译文到货计数（普通字段 + @State 计数器，理由同 FeedList.translatedCaption）。 */
  @State private translationEpoch: number = 0;
  /**
   * 卡片高度上限（vp）：`aboutToAppear` 里按屏幕高度算好（见 CARD_MAX_HEIGHT_RATIO）。
   *
   * 为什么不直接写 `constraintSize({ maxHeight: '30%' })`：百分比在这个属性上要看宿主链路，
   * 实测不稳；算成一个具体 vp 是确定的。
   */
  @State private cardMaxH: number = CARD_MAX_HEIGHT_FALLBACK;

  /**
   * 关注 —— **功能由宿主实现**（HTTP 直发在 pages/Index，见 followUser）。
   *
   * 关注返回 Promise<boolean>：true = 成功；false 时本组件自己把乐观状态翻回去。
   */
  onFollow: (follow: boolean) => Promise<boolean> =
    (follow: boolean): Promise<boolean> => Promise.resolve(false);
  /**
   * 点头像 / 账号名 → 打开 TA 的主页。
   *
   * 评论面板原样复用同一个回调（宿主那条 `onUserTap` 会先挂起面板再推页面，回来时面板还在），
   * 所以这里不需要再单独一个 `onCardUserTap`。
   */
  onUserTap: (username: string, userId: string) => void =
    (username: string, userId: string): void => {
    };
  /** 翻译失败（宿主弹一句提示；本组件自己已经把状态退回去了）。 */
  onTranslateFailed: () => void = (): void => {
  };
  /*
   * **上一版的 `onClose` / 遮罩 / 贴底定位已经全部删掉**：卡片不再是浮层（需求），
   * 关不关、什么时候关由评论面板说了算（见 CommentsPanel 与 pages/Index.closeComments）。
   */

  aboutToAppear(): void {
    // 卡片高度上限按屏幕实测（量不到就用兜底值）。
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      const screenVp: number = this.getUIContext().px2vp(dsp.height);
      const limit: number = screenVp * CARD_MAX_HEIGHT_RATIO;
      this.cardMaxH = limit > 120 ? limit : CARD_MAX_HEIGHT_FALLBACK;
    } catch (error) {
      this.cardMaxH = CARD_MAX_HEIGHT_FALLBACK;
    }
    this.syncFollow();
    this.ensureFollowState();
  }

  /** 作者是不是**我自己**（是就不画关注按钮 —— 关注自己没有意义）。 */
  private ownerIsMe(): boolean {
    return this.ownAuthor.length > 0
      && this.ownerUsername.length > 0
      && this.ownerUsername.toLowerCase() === this.ownAuthor.toLowerCase();
  }

  /**
   * 关注状态以**会话级覆盖表**为准（本地点过的以本地为准），和 ReelsPage 的
   * ReelOverlay.syncFollow 同一套判据 —— 卡片上和视频页上的状态必须一致。
   */
  private syncFollow(): void {
    this.following = this.ownerUsername.length > 0
      && FollowState.resolve(this.ownerId,
        FollowState.resolveName(this.ownerUsername, false));
  }

  /** 别处改过关注状态：重新算一次（见 FOLLOW_VERSION_KEY）。 */
  private onFollowVersion(): void {
    this.syncFollow();
  }

  /**
   * 宿主换了这一条的数据（换了一条 reel）：关注状态重算，覆盖表里没有就再问一次。
   *
   * 为什么要 @Watch：`aboutToAppear` 只在卡片**创建那一刻**跑一次，而评论面板是"先弹出来、
   * 数据随后写进来"的写法（宿主那边几个 @State 是先后写的）。
   */
  private onOwnerChanged(): void {
    this.syncFollow();
    this.ensureFollowState();
  }

  /**
   * 覆盖表里**没有**这位作者时，单独问一次真实状态（`friendships/show_many`）。
   *
   * 不问的话，已经关注过的人在这里会显示成「关注」，点一下反而变成"取关"。
   */
  private ensureFollowState(): void {
    if (this.followAsked || this.ownerIsMe()) {
      return;
    }
    if (this.ownerId.length === 0 || this.ownerUsername.length === 0) {
      return;
    }
    if (FollowState.has(this.ownerId)) {
      return;
    }
    this.followAsked = true;
    NativeFollow.statesFor([this.ownerId]).then((states: Map<string, boolean>): void => {
      const known: boolean | undefined = states.get(this.ownerId);
      if (known === undefined) {
        return;
      }
      hilog.info(DOMAIN, TAG, 'post card follow looked up user=%{public}s following=%{public}s',
        this.ownerId, `${known}`);
      // 写进覆盖表即可：`@StorageLink` 会把这一格刷过来（不用自己再改 following）。
      FollowState.remember(this.ownerId, this.ownerUsername, known);
    }).catch((): void => {
    });
  }

  /**
   * 点关注：乐观翻转 + 失败回滚（同 ReelsPage.tapFollow）。
   *
   * 成功之后由宿主写覆盖表（见 pages/Index.followUser），于是视频页/信息流上的同一个人
   * 也会跟着变。
   */
  private tapFollow(): void {
    if (this.followBusy || this.ownerUsername.length === 0) {
      return;
    }
    const next: boolean = !this.following;
    this.followBusy = true;
    this.following = next;
    this.onFollow(next).then((ok: boolean): void => {
      this.followBusy = false;
      if (!ok) {
        this.following = !next;
      }
    }).catch((): void => {
      this.followBusy = false;
      this.following = !next;
    });
  }

  /**
   * 译文（还没翻出来时是空串）。
   *
   * 读一下"译文到货"计数，让调用它的 build 登记成依赖（普通字段改了不会重绘，
   * 理由同 FeedList.translatedCaption）。
   */
  private translatedText(): string {
    const tick: number = this.translationEpoch;
    if (tick < 0) {
      return '';
    }
    return this.translation;
  }

  /**
   * 点「查看翻译 / 显示原文」：**先就地切状态**（立刻有反应），译文第一次出现时再补一次网络。
   *
   * 状态切换包在 `animateTo({ duration: TRANSLATE_ANIM_MS, curve: Curve.Linear })` 里
   * （需求：线性展开，不要弹性/缓动）；原文 ↔ 译文两个节点各自带同一条线性 `transition`，
   * 于是"换字"和"高度变化"都是匀速的。
   *
   * 失败就把状态退回去 —— 不能让按钮写着"显示原文"而正文还是原文。
   */
  private toggleTranslation(show: boolean): void {
    if (this.caption.length === 0 || show === this.showingTranslation) {
      return;
    }
    this.getUIContext().animateTo({ duration: TRANSLATE_ANIM_MS, curve: Curve.Linear }, (): void => {
      this.showingTranslation = show;
    });
    if (!show || this.translation.length > 0) {
      return;
    }
    Translator.translate(this.caption).then((translated: string | null): void => {
      if (translated === null || translated.length === 0) {
        hilog.warn(DOMAIN, TAG, 'translate failed why=%{public}s', Translator.lastDetail());
        // 失败直接退回原文（这里不补动画：用户点的那一下"没成功"，硬切回去比慢慢滑更清楚）。
        this.showingTranslation = false;
        this.onTranslateFailed();
        return;
      }
      this.translation = translated;
      // 换引用不够（内容比较不重绘），再加一个计数让 build 真的重跑。
      this.translationEpoch = this.translationEpoch + 1;
    }).catch((): void => {
      this.showingTranslation = false;
      this.onTranslateFailed();
    });
  }

  /**
   * 发布时间（毫秒）→ "多久之前"。
   *
   * 分档文案直接复用信息流那套 `posted_ago_*`（见 FeedList.postedAgo），单位与取整也一致；
   * 拿不到时刻（0）时返回空串 —— 卡片据此不画那一截（不猜、也不显示 "0"）。
   */
  private agoText(createdAtMs: number): ResourceStr {
    if (createdAtMs <= 0) {
      return '';
    }
    const diff: number = Math.max(0, Date.now() - createdAtMs);
    if (diff < AGO_MINUTE_MS) {
      return $r('app.string.posted_ago_now');
    }
    if (diff < AGO_HOUR_MS) {
      return $r('app.string.posted_ago_minutes', Math.floor(diff / AGO_MINUTE_MS));
    }
    if (diff < AGO_DAY_MS) {
      return $r('app.string.posted_ago_hours', Math.floor(diff / AGO_HOUR_MS));
    }
    if (diff < AGO_WEEK_MS) {
      return $r('app.string.posted_ago_days', Math.floor(diff / AGO_DAY_MS));
    }
    if (diff < AGO_MONTH_MS) {
      return $r('app.string.posted_ago_weeks', Math.floor(diff / AGO_WEEK_MS));
    }
    if (diff < AGO_YEAR_MS) {
      return $r('app.string.posted_ago_months', Math.floor(diff / AGO_MONTH_MS));
    }
    return $r('app.string.posted_ago_years', Math.floor(diff / AGO_YEAR_MS));
  }

  /**
   * **用户资讯栏**（头像 + 账号名，沉浸光感胶囊）。
   *
   * 版式和 FeedList.profileRow 一样：胶囊外面套一层 `layoutWeight(1)` 的 Row 吃掉多余宽度，
   * 关注按钮自然排到右边（不用 `SpaceBetween`：那会让左边界跟着账号名长度变）。
   */
  @Builder
  infoPill() {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Row({ space: 8 }) {
        CardAvatar({ url: this.ownerAvatar, boxSize: AVATAR_SIZE })
        Text(this.ownerUsername.length > 0 ? this.ownerUsername : 'instagram')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: NAME_MAX_WIDTH_VP })
      }
    }
    .height(ROW_HEIGHT)
    /*
     * **左 / 上 / 下同一个内缩**（需求："头像左侧间距 = 头像上/下间距"）：
     * 三者都吃 `AVATAR_INSET_VP`，头像在胶囊里就是一块"三边等距"的方形留白。
     * 右边留给账号名的内缩（12）单独给 —— 它不是"留白"，是名字与胶囊边缘的呼吸位。
     */
    .padding({ left: AVATAR_INSET_VP, right: 12, top: AVATAR_INSET_VP, bottom: AVATAR_INSET_VP })
    .borderRadius(ROW_HEIGHT / 2)
    .backgroundColor(Color.Transparent)
    // 选中态透明：Toggle 默认选中色是主题强调色，点一下整颗会变蓝（同 MaterialSurface）。
    // 资讯栏仍然是材质（需求："用户资讯栏保持材质不变"）；autoInvert 传 false 同 Reels 作者行。
    .attributeModifier(new SurfaceModifier(this.thickness, false))
    .onChange((): void => {
      // 纯材质容器，功能由下面的 onClick 接。
    })
    .onClick((): void => {
      this.onUserTap(this.ownerUsername, this.ownerId);
    })
    // ① 记"按住"（见文件头 4-way lock）。
    .onTouch(trackMaterialTouch)
    // ② 占住落在它上面的滑动：横向拖动不误触，纵向由外层 Scroll 的 holdsScroll 放行。
    .gesture(PanGesture().onActionStart(consumePan).onActionUpdate(consumePan))
  }

  /** 资讯栏 + 关注按钮那一行。 */
  @Builder
  infoRow() {
    Row({ space: CARD_GAP_VP }) {
      Row() {
        this.infoPill()
      }
      .layoutWeight(1)
      .height(ROW_HEIGHT)
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Start)
      // 胶囊的材质阴影画在边界之外，这一层不能裁（同 FeedList.profileRow 的说明）。
      .clip(false)

      // 关注按钮：作者是我自己时不画。它自带 4-way lock（见材料文件里的 MaterialLabelButton）。
      if (!this.ownerIsMe()) {
        MaterialLabelButton({ autoInvert: false,
          labelRes: this.following
            ? $r('app.string.action_following') : $r('app.string.action_follow'),
          pillWidth: FOLLOW_PILL_WIDTH,
          pillHeight: ROW_HEIGHT,
          fontSize: 13,
          onTap: (): void => {
            this.tapFollow();
          }
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * **正文**：完整显示（不设 maxLines、不加省略号），可换行；显示译文时就地换成译文。
   *
   * 原文 / 译文是**两个节点**（`if / else`）：只有换成另一个节点，那条线性 `transition`
   * 才会真的跑起来（同一个 Text 只改文字内容是不产生过渡的）。
   */
  @Builder
  captionBlock() {
    if (this.caption.length > 0) {
      if (this.showingTranslation && this.translatedText().length > 0) {
        // 译文**显式白色**（需求）：卡片正文原本走主题色，译文态必须自己指定，不能跟主题走。
        Text(this.translatedText())
          .fontSize(CAPTION_FONT_SIZE)
          .lineHeight(CAPTION_LINE_HEIGHT)
          .fontColor(Color.White)
          .textShadow(TRANSLATED_TEXT_SHADOW)
          .textAlign(TextAlign.Start)
          .width('100%')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: TRANSLATE_ANIM_MS, curve: Curve.Linear }))
      } else {
        Text(this.caption)
          .fontSize(CAPTION_FONT_SIZE)
          .lineHeight(CAPTION_LINE_HEIGHT)
          .fontColor($r('app.color.primary_text'))
          .textAlign(TextAlign.Start)
          .width('100%')
          .transition(TransitionEffect.OPACITY
            .animation({ duration: TRANSLATE_ANIM_MS, curve: Curve.Linear }))
      }
    }
  }

  /** 内容列：用户资讯栏 + 关注按钮 → 正文 → 发布时间 → 「查看翻译」（顺序固定，需求）。 */
  @Builder
  cardBody() {
    Column({ space: CARD_GAP_VP }) {
      this.infoRow()
      this.captionBlock()

      // 发布时间（相对时间，复用 `posted_ago_*` 文案，见 agoText）。
      if (this.createdAtMs > 0) {
        Text(this.agoText(this.createdAtMs))
          .fontSize(12)
          .fontColor($r('app.color.comment_muted'))
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      // 「查看翻译」：只有非中文正文才会真的画出来（见 TranslateLabel）。
      // 左内边距传 0 —— 它的默认值 6 是给"挨着时间排"那几处留的，这里要对齐卡片左边界。
      if (this.caption.length > 0) {
        Row() {
          TranslateLabel({
            source: this.caption,
            showing: this.showingTranslation,
            fontSize: 12,
            padLeft: 0,
            onToggle: (show: boolean): void => {
              this.toggleTranslation(show);
            }
          })
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 四边**同一个值**。
    .padding(CARD_PAD_VP)
  }

  build() {
    /*
     * 卡片 = **一颗 Toggle 承载静态玻璃材质**，它的内容就是那一层 Scroll（见文件头）。
     *
     * ## 为什么材质挂在卡片**根节点**上，而不是像评论面板那样铺一层背景 Toggle
     * 评论面板、输入条那种"底层一颗空 Toggle + 上层内容"的写法，前提是**高度已定**
     * （面板占满屏、输入条是固定 `BAR_HEIGHT`）。而这张卡片的高度是**内容撑出来的**
     * （正文几句、有没有关注按钮都会变）：在自适应高度的 Stack 里给背景层写 `height('100%')`，
     * 百分比会按"父容器的可用空间"算 —— 卡片会一下长到面板剩多少就多高，正文短的时候下面
     * 一大片空玻璃。挂在根节点上则天然是"内容多高、玻璃多高"。
     *
     * 至于"材质嵌套"（官方：同一子树里只宜在最外层设一次）：卡片里那两颗材质（资讯栏胶囊、
     * 关注按钮）确实在它的子树里，但它们是**独立组件自己的材质**，两者都画得出来 ——
     * 这一处是"卡片要玻璃"和"胶囊/按钮保持材质"两个需求同时要的结果，取舍记在这里。
     *
     * ## Scroll
     * 正文完整显示、可能很长，超过 `cardMaxH` 时让它自己滚，卡片不会被裁一截。
     *
     * `onGestureRecognizerJudgeBegin` 是 4-way lock 的**外层那一半**（见文件头）：
     * 手指按住胶囊之后拖动，`holdsScroll` 返回真 → 这里否掉 Scroll 的内建 PAN，
     * 卡片不跟着走、面板也不跟着走；按下去就划的竖向拖动则照常放行（否则就"卡手"）。
     */
    Stack() {
      Scroll() {
        Column() {
          this.cardBody()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.None)
      // 内容裁圆角：长正文滚动时不能溢出到卡片角上（材质那层自己也是同一个半径）。
      .borderRadius(CARD_RADIUS_VP)
      .clip(true)
      // 记下触摸起点 / 第一次移动的时刻（holdsScroll 的判据，见 MaterialSurface）。
      .onTouch(trackScrollTouch)
      .onGestureRecognizerJudgeBegin((event: BaseGestureEvent, current: GestureRecognizer,
                                      others: Array<GestureRecognizer>): GestureJudgeResult => {
        if (holdsScroll(event) && current.isBuiltIn()
          && current.getType() === GestureControl.GestureType.PAN_GESTURE) {
          return GestureJudgeResult.REJECT;
        }
        return GestureJudgeResult.CONTINUE;
      })
    }
    .width('100%')
    .padding(0)
    .borderRadius(CARD_RADIUS_VP)
    .backgroundColor(Color.Transparent)
    // 选中态透明：Toggle 默认选中色是主题强调色，点一下整颗会变蓝（同 MaterialSurface）。
    /*
     * 静态玻璃（需求："恢复沉浸光感，但不要光源、不要拖拽"）。
     * 参数顺序（见 MaterialSurface.SurfaceModifier）：
     *   thickness          材质厚度（跟设定页联动）
     *   invert=false       不跟着背景反色（卡片内容走主题色，同评论面板底层那颗）
     *   applyShadow=true   保留材质自带那圈阴影（它就是卡片的轮廓来源）
     *   forceFallback=false 正常走系统材质
     *   lightEffect=false  **关掉光源**（需求："不要光源"）→ 内部传 `lightEffect: null`
     *   interactive=false  **关掉交互形变**（需求："不要拖拽/按压形变"）→ 静态玻璃
     */
    /*
     * **卡片本体不再铺沉浸光感材质**（官方规范：材质影响的像素越多功耗越高，应避免用在
     * 单个超大区域上，也避免大量小区域重复使用；推荐只用在标题栏 / 底栏 / 需要凸显的局部）。
     *
     * 卡片是"大区域"，于是改成**纯色表面 + 1vp 描边 + 圆角**：轮廓由边框给出，
     * 玻璃收回到内部两颗小控件（资讯胶囊、关注按钮）上 —— 层级也更清楚。
     */
    .borderRadius(CARD_RADIUS_VP)
    .backgroundColor($r('app.color.field_background'))
    .border({ width: 1, color: $r('app.color.divider') })
  }
}
