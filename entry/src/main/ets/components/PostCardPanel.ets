/*
 * **帖子卡片面板**：一张"这条帖子本体"的卡片（作者 + 关注 / 完整正文 / 发布时间 / 查看翻译）。
 *
 * ## 为什么是独立组件
 * 这张卡原来钉在评论面板顶部（「评论」标题下方、第一条评论上方），需求后来改了：
 *   · 评论面板**回到原样**（只有小横条 + 「评论」标题 + 评论列表）；
 *   · 卡片抽成一个**独立面板**，**只有点 Reels 正文**才出现（点动作栏那颗气泡仍然进评论面板）。
 * 于是"点正文"和"点评论"在 ReelsPage 那一层就分流成两个回调（ReelsPage.onOpenPostCard /
 * ReelsPage.onComments），宿主分别接到本面板和评论面板（见 pages/Index）。
 *
 * ## 呈现方式
 * 和评论浮层同一套做法（自己画的一层，不用系统半模态）：
 *   ① 半透明遮罩（颜色走 `comments_scrim`，深浅色自动切），**点一下关掉**；
 *   ② 卡片贴在屏幕底部（离底边 CARD_BOTTOM_VP），左右留 CARD_SIDE_VP；
 *   ③ 返回键由宿主的 onBackPress / NavDestination.onBackPressed 接（见 pages/Index）。
 * 遮罩 `expandSafeArea` 扩到状态栏/输入法避让区 —— 只扩绘制、不动布局，卡片位置不受影响。
 *
 * ## 材质
 * "沉浸光感"由**一颗透明 Toggle 承载**（`SurfaceModifier`）：官方《沉浸光感–功耗优化》里，
 * 内容区只有 Toggle / Slider / Select 拿得到材质，普通容器挂上去不生效（见 MaterialSurface
 * 的文件头）。所以卡片是"Toggle 当底色、内容放里面"，而不是自己画一个圆角矩形。
 * 关注按钮用 `MaterialLabelButton`（和 Feeds / Reels 作者行同一套）。
 *
 * ## 左对齐（需求："全部内容左对齐"）
 * 卡片内容列只有一个左基准 = Toggle 的内边距 `CARD_PAD_VP`：
 *   · **头像**是资讯栏胶囊的**第一个子节点、胶囊左内边距为 0**；
 *   · 正文 / 发布时间 / 「查看翻译」都是内容列的**直接子节点**（各自再没有左内边距）。
 * 上一版头像看起来"偏"了，根因就是它待在一颗 `padding({ left: 2 })` 的胶囊里，而正文/时间是
 * 直接贴在卡片内边距上的 —— 两条基准差 2vp；另外那一行用 `justifyContent(SpaceBetween)`，
 * 左边界还取决于"账号名有多长"。这里把左内边距清零、间距全部交给常量的 `space`，
 * 三者的左边界在**布局层面**就相同，不靠肉眼调。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { MaterialLabelButton, SurfaceModifier, trackMaterialTouch } from './MaterialSurface';
import { TranslateLabel } from './TranslateLabel';
import { Translator } from '../core/Translator';
import { FollowState, FOLLOW_VERSION_KEY } from '../core/FollowState';
import { NativeFollow } from '../core/NativeFollow';

const DOMAIN = 0xFF00;
const TAG = 'InstarmonyPostCard';

/** 卡片左右留白（vp）：和评论浮层/输入条那套一致，视觉上是"同一档浮层"。 */
const CARD_SIDE_VP: number = 16;
/** 卡片离屏幕底边的距离（vp）：窗口内容区已经避开了手势条，这里只留一点呼吸位。 */
const CARD_BOTTOM_VP: number = 28;
/**
 * 卡片内边距（vp，**四边同一个值**，需求："卡片 padding 也左右一致"）。
 *
 * 它是整个卡片**唯一的左基准**：头像 / 正文 / 时间 / 查看翻译的左边界都从这里算起（见文件头）。
 */
const CARD_PAD_VP: number = 16;
/**
 * 卡片里**行与行之间**的垂直间距（vp，需求："卡片内上下间距一致……用同一个值"）。
 *
 * 头像那行 ↔ 正文、正文 ↔ 时间、时间 ↔ 「查看翻译」三处都吃这一个值，
 * 所以卡片的节奏是匀的，不会出现"上紧下松"。
 */
const CARD_GAP_VP: number = 10;
/** 卡片圆角（vp）：比评论面板（22）小一号，一眼能看出它是"一张卡"而不是第二层面板。 */
const CARD_RADIUS_VP: number = 20;
/**
 * 卡片高度上限（占屏幕高度的比例）。
 *
 * 正文是**完整显示、不截断**的（需求），长配文能把卡片顶穿屏幕 —— 超过这个比例就交给
 * `Scroll` 让它自己滚，卡片本身不会被裁掉一截。
 */
const CARD_MAX_HEIGHT_RATIO: number = 0.68;
/** 量不到屏幕高度时的兜底上限（vp）：大约是一屏的中下部分。 */
const CARD_MAX_HEIGHT_FALLBACK: number = 460;
/** 头像直径（vp）：和信息流作者行同一档（34 太大、24 太小，32 与评论行一致）。 */
const AVATAR_SIZE: number = 32;
/**
 * 资讯栏 / 关注按钮那一行的高度（vp）。
 *
 * 40 = 全 app 材质按钮的标准高度（见 MaterialSurface 的 `MATERIAL_PILL_HEIGHT`），
 * 胶囊、关注按钮、头像（32）在这一行里垂直居中，看上去才是同一条线上的东西。
 */
const ROW_HEIGHT: number = 40;
/** 关注按钮宽度（vp）：两个字 + 内边距（和 Reels 作者行那颗一致）。 */
const FOLLOW_PILL_WIDTH: number = 74;
/** 账号名可占的最大宽度（vp）：太长的名字不许把关注按钮顶出卡片。 */
const NAME_MAX_WIDTH_VP: number = 190;
/** 正文的字号 / 行高（vp）：和信息流卡片正文同一档。 */
const CAPTION_FONT_SIZE: number = 14;
const CAPTION_LINE_HEIGHT: number = 20;
/** 相对时间分档（毫秒）—— 和信息流/评论那套 `posted_ago_*` 文案一致（见 FeedList.postedAgo）。 */
const AGO_MINUTE_MS: number = 60 * 1000;
const AGO_HOUR_MS: number = 60 * AGO_MINUTE_MS;
const AGO_DAY_MS: number = 24 * AGO_HOUR_MS;
const AGO_WEEK_MS: number = 7 * AGO_DAY_MS;
const AGO_MONTH_MS: number = 30 * AGO_DAY_MS;
const AGO_YEAR_MS: number = 365 * AGO_DAY_MS;
/**
 * 账号名胶囊**左内边距为 0** 的原因见文件头：头像要顶在胶囊最左边，
 * 才能和正文/时间共用同一个左边界。
 */
const NAME_PILL_LEFT_PAD_VP: number = 0;

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
 * **帖子卡片面板**（对外只有一个组件，宿主把它挂在页面根 Stack 里，
 * `if (postCardVisible)` 控制开关，见 pages/Index）。
 */
@Component
export struct PostCardPanel {
  /** 作者账号名（空 = 整张卡片不画，宿主不该在这时候打开面板）。 */
  @Prop @Watch('onOwnerChanged') ownerUsername: string = '';
  /** 作者头像直链（空就画占位图标）。 */
  @Prop ownerAvatar: string = '';
  /** 这条帖子的**完整正文**（卡片里不截断，见文件头）。 */
  @Prop caption: string = '';
  /**
   * 作者的**数字 id** 与这条的**发布时刻**（毫秒；0 = 未知）。
   *
   * 关注那颗按钮要 id 才点得动（见 NativeFollow），"3小时前"要时刻才算得出。
   * 拿不到（空串 / 0）时对应那截不画 —— 不猜、也不显示 "0"
   * （reels 载荷不带 `taken_at`，见 pages/Index.openReelPostCard）。
   */
  @Prop @Watch('onOwnerChanged') ownerId: string = '';
  @Prop createdAtMs: number = 0;
  /**
   * **我自己的账号名**（宿主传进来）：作者是我自己时不画关注按钮
   * （和 ReelsPage 的 ReelOverlay.isOwnAuthor 同一个判据）。
   */
  @Prop ownAuthor: string = '';
  /** 材质厚度（跟设定页联动，见 SurfaceModifier）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) thickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /**
   * 关注状态是**会话级覆盖表**说了算（在别处点过也要跟着变，见 core/FollowState）。
   *
   * 面板是浮层，可能一直开着：用户在旁边的动作栏点了关注，这里也要刷成「已关注」。
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
  /** 翻好的译文（还没翻出来时先用原文占着）。 */
  private translation: string = '';
  /** 译文到货计数（普通字段 + @State 计数器，理由同 FeedList.translatedCaption）。 */
  @State private translationEpoch: number = 0;
  /**
   * 卡片高度上限（vp）：`aboutToAppear` 里按屏幕高度算好（见 CARD_MAX_HEIGHT_RATIO）。
   *
   * 为什么不直接写 `constraintSize({ maxHeight: '68%' })`：百分比在这个属性上要看宿主链路，
   * 实测不稳；算成一个具体 vp 是确定的。
   */
  @State private cardMaxH: number = CARD_MAX_HEIGHT_FALLBACK;

  /**
   * 关注 / 不看 / 关掉 —— **功能都由宿主实现**（HTTP 直发在 pages/Index）。
   *
   * 关注返回 Promise<boolean>：true = 成功；false 时本组件自己把乐观状态翻回去。
   */
  onFollow: (follow: boolean) => Promise<boolean> =
    (follow: boolean): Promise<boolean> => Promise.resolve(false);
  /** 点头像 / 账号名 → 打开 TA 的主页（宿主先关掉本面板再推页面）。 */
  onUserTap: (username: string, userId: string) => void =
    (username: string, userId: string): void => {
    };
  /** 关掉面板（点遮罩 / 返回键都走这里）。 */
  onClose: () => void = (): void => {
  };
  /** 翻译失败（宿主弹一句提示；面板自己已经把状态退回去了）。 */
  onTranslateFailed: () => void = (): void => {
  };

  aboutToAppear(): void {
    // 卡片高度上限按屏幕实测（量不到就用兜底值）。
    try {
      const dsp: display.Display = display.getDefaultDisplaySync();
      const screenVp: number = this.getUIContext().px2vp(dsp.height);
      const limit: number = screenVp * CARD_MAX_HEIGHT_RATIO;
      this.cardMaxH = limit > 200 ? limit : CARD_MAX_HEIGHT_FALLBACK;
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
   * 为什么要 @Watch：`aboutToAppear` 只在卡片**创建那一刻**跑一次，而面板是"先弹出来、
   * 数据随后写进来"的写法也完全可能（宿主那边两个 @State 是先后写的）。
   */
  private onOwnerChanged(): void {
    this.syncFollow();
    this.ensureFollowState();
  }

  /**
   * 覆盖表里**没有**这位作者时，单独问一次真实状态（`friendships/show_many`）。
   *
   * 不问的话，已经关注过的人在这里会显示成「关注」，点一下反而变成"取关"。
   * 覆盖表里有时不重复问 —— Reels 信息层刚刚问过同一个人（见 ReelOverlay.ensureFollowState）。
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

  /** 正文这一格现在要显示的文字（显示译文且译文已到货时用译文，否则原文）。 */
  private captionShown(): string {
    // 读一下"译文到货"计数，让调用它的 build 登记成依赖（理由同 FeedList.translatedCaption）。
    const tick: number = this.translationEpoch;
    if (tick < 0) {
      return this.caption;
    }
    return this.showingTranslation && this.translation.length > 0 ? this.translation : this.caption;
  }

  /**
   * 点「查看翻译 / 显示原文」：**先就地切状态**（立刻有反应），译文第一次出现时再补一次网络。
   *
   * 失败就把状态退回去 —— 不能让按钮写着"显示原文"而正文还是原文。
   */
  private toggleTranslation(show: boolean): void {
    if (this.caption.length === 0 || show === this.showingTranslation) {
      return;
    }
    this.showingTranslation = show;
    if (!show || this.translation.length > 0) {
      return;
    }
    Translator.translate(this.caption).then((translated: string | null): void => {
      if (translated === null || translated.length === 0) {
        hilog.warn(DOMAIN, TAG, 'translate failed why=%{public}s', Translator.lastDetail());
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
   * **卡片本体**：材质底色（Toggle）+ 内容列。
   *
   * 内容列的顺序固定（需求）：用户资讯栏 + 关注按钮 → 正文（完整）→ 发布时间 → 「查看翻译」。
   */
  @Builder
  cardBody() {
    Toggle({ type: ToggleType.Button, isOn: false }) {
      Column({ space: CARD_GAP_VP }) {
        /*
         * ① 用户资讯栏（头像 + 账号名，沉浸光感胶囊）+ 关注按钮。
         *
         * 版式和 FeedList.profileRow 一样：胶囊外面套一层 `layoutWeight(1)` 的 Row 吃掉多余宽度，
         * 关注按钮自然排到右边（不用 `SpaceBetween`：那会让左边界跟着账号名长度变，见文件头）。
         */
        Row({ space: CARD_GAP_VP }) {
          Row() {
            Toggle({ type: ToggleType.Button, isOn: false }) {
              Row({ space: 8 }) {
                // 头像：胶囊里**第一个节点**，胶囊左内边距 0 —— 左边界和正文/时间完全同一条线。
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
            // 左边 0（见 NAME_PILL_LEFT_PAD_VP）：这 2vp 就是上一版"头像比正文偏"的来源。
            .padding({ left: NAME_PILL_LEFT_PAD_VP, right: 12, top: 4, bottom: 4 })
            .borderRadius(ROW_HEIGHT / 2)
            .backgroundColor(Color.Transparent)
            // 选中态透明：Toggle 默认选中色是主题强调色，点一下整颗会变蓝（同 MaterialSurface）。
            .selectedColor(Color.Transparent)
            .attributeModifier(new SurfaceModifier(this.thickness, false))
            .onChange((): void => {
              // 纯材质容器，功能由下面的 onClick 接。
            })
            .onClick((): void => {
              this.onUserTap(this.ownerUsername, this.ownerId);
            })
            // 按住它时"咬住"外层手势（判据见 MaterialSurface 的 holdsScroll）。
            .onTouch(trackMaterialTouch)
          }
          .layoutWeight(1)
          .height(ROW_HEIGHT)
          .alignItems(VerticalAlign.Center)
          .justifyContent(FlexAlign.Start)
          // 胶囊的材质阴影画在边界之外，这一层不能裁（同 FeedList.profileRow 的说明）。
          .clip(false)

          // 关注按钮：作者是我自己时不画。
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

        // ② 正文：**完整显示**（不设 maxLines、不加省略号），可换行；显示译文时就地换成译文。
        if (this.caption.length > 0) {
          Text(this.captionShown())
            .fontSize(CAPTION_FONT_SIZE)
            .lineHeight(CAPTION_LINE_HEIGHT)
            .fontColor(this.showingTranslation
              ? $r('app.color.secondary_text') : $r('app.color.primary_text'))
            .textAlign(TextAlign.Start)
            .width('100%')
        }

        // ③ 发布时间（相对时间，复用 `posted_ago_*` 文案，见 agoText）。
        if (this.createdAtMs > 0) {
          Text(this.agoText(this.createdAtMs))
            .fontSize(12)
            .fontColor($r('app.color.comment_muted'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }

        // ④ 「查看翻译」：只有非中文正文才会真的画出来（见 TranslateLabel）。
        //    左内边距传 0 —— 它的默认值 6 是给"挨着时间排"那几处留的，这里要对齐卡片左边界。
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
      // 四边**同一个值**（需求："卡片 padding 也左右一致"）。
      .padding(CARD_PAD_VP)
    }
    .width('100%')
    .borderRadius(CARD_RADIUS_VP)
    // Toggle 自带一点内容内边距，不清掉的话卡片左右会多出一圈看不见的白（见 MaterialLabelButton）。
    // 卡片的内边距**只认 CARD_PAD_VP**，全局左边界才唯一。
    .padding(0)
    .backgroundColor(Color.Transparent)
    .selectedColor(Color.Transparent)
    // 玻璃底；低版本设备自动退化成"低透明度中性底 + 背景模糊"（见 SurfaceModifier）。
    .attributeModifier(new SurfaceModifier(this.thickness, false))
    .onChange((): void => {
      // 卡片本身不是一个按钮：点击交给里面的资讯栏 / 关注按钮 / 查看翻译。
    })
    .onClick((): void => {
    })
    .onTouch(trackMaterialTouch)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ① 遮罩：点一下收起（和评论浮层同一个颜色、同一种手感）。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.comments_scrim'))
        /*
         * 遮罩要盖满整屏：浮层所在的那一层是"窗口内容区"，上下各比屏幕少一条系统避让区。
         * `expandSafeArea` 只扩**绘制**区域、不动布局，所以卡片位置一点不变。
         */
        .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.KEYBOARD],
          [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onClick((): void => {
          this.onClose();
        })

      // ② 卡片：贴底 + 左右留白；长配文超过高度上限时由 Scroll 自己滚（见 CARD_MAX_HEIGHT_RATIO）。
      Column() {
        Scroll() {
          Column() {
            this.cardBody()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .constraintSize({ maxHeight: this.cardMaxH })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
      }
      .width('100%')
      .padding({ left: CARD_SIDE_VP, right: CARD_SIDE_VP, bottom: CARD_BOTTOM_VP })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
