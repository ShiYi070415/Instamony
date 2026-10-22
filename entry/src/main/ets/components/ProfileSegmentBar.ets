/*
 * 「我的」页的**分段按钮**：一条沉浸光感的胶囊，里面四段，只显示图标。
 *
 * ## 为什么单独一个组件（它是被两个宿主共用的）
 * 需求："上滑到分段按钮在页面顶部时让它固定" —— 实现方式是：
 *   1. **页面里**那条（个人信息下方）随列表一起滚；
 *   2. 滚过个人信息之后，分段按钮改由 **HDS 标题栏**显示（`titleBar` 的 `bottomBuilder`，
 *      和搜索页那个搜索框同一套）—— 标题栏是画在内容层之上的，所以固定后不会被任何内容盖住。
 * 两个宿主不可能各写一份（分页号、灰底位置会分叉），所以抽成组件：
 *   - **分页号从外面进来**（`@Prop tab`），点了/拖了通过 `onSelect` 回调出去，
 *     真相仍然只有一个（页面与视图模型那份）；
 *   - 灰底的拖动是组件**自己的**交互状态（内部 `@State dragSeg`），不外泄。
 *
 * ## 观感（历史需求）
 *   - **黑白主题**：图标只用主题的前景/次要前景色，不引强调色；
 *   - **选中态是一块灰色底**（嵌在胶囊里的药丸），选中那一段同时换成填充图标；
 *   - **可以拖动**：按住灰底横向拖，灰底跟着手指走，松手落到那一段并切页（轻点也直接切）；
 *   - **没有底色块**：胶囊自己就是全部（不要再铺一层背景/轨道底色）。
 *
 * ## 材质
 * 挂在 Toggle 上：内容区里只有 Toggle/Slider/Select 的沉浸光感生效
 * （官方《沉浸光感–功耗优化》，见 MaterialSurface 的文件头）。整条胶囊是一个 Toggle，
 * 四段是它的子节点（子节点自己接点击，Toggle 不承载开关语义）。
 * 轮廓阴影交给材质自己（`applyShadow` 默认 true），不自绘 `.shadow()` —— 两者同时设置时
 * 阴影一律呈现为材质自带样式（官方 FAQ），写了那行也没用。
 */

import { MATERIAL_THICKNESS_ULTRA_THIN, SETTING_MATERIAL_THICKNESS } from '../core/AppSettings';
import { SurfaceModifier, trackMaterialTouch } from './MaterialSurface';

/** 胶囊高度（vp）：和全 app 的材质按钮对齐（40）。 */
const SEGMENT_HEIGHT: number = 40;
/** 段内图标字号（vp）。 */
const SEGMENT_ICON: number = 20;
/** 文字模式（Reels 那条）的段内字号（fp）。 */
const SEGMENT_LABEL_SIZE: number = 14;
/** 灰底在段内的上下内缩（vp）：看起来是嵌在胶囊里的一颗药丸。 */
const SEGMENT_THUMB_INSET: number = 4;
/** 横向移动超过这么多 vp 才算"拖动"（PanGesture 的距离阈值）；轻点不满足它，走各段 onClick。 */
const SEGMENT_DRAG_DISTANCE: number = 4;
/** 灰底跟随的时长（毫秒）：拖动时是逐帧定位，落定那一下才需要这段补间。 */
const SEGMENT_SLIDE_MS: number = 160;
/** 分段数量上限（下面两组图标的最大长度）。 */
const SEGMENT_MAX: number = 4;
/** 胶囊（整条）的左右外边距（vp）：一段宽 = (可用宽 − 2×这个数) / 段数。 */
export const SEGMENT_SIDE: number = 16;
/** 量不到可用宽度时的兜底（vp）。 */
const FALLBACK_WIDTH_VP: number = 360;
/**
 * 图标组：**本人**的四个分页（帖子 / 视频 / 收藏 / 被标注）与**别人主页**的三个分页
 * （帖子 / 视频 / 被提及 —— 没有收藏，需求里明确去掉）。
 *
 * 为什么用"模式字符串"而不是把图标数组传进来：`@Prop` 不支持数组/Resource 数组这类复合类型
 * （会编译不过），所以这里只传一个模式，图标在组件内部按它取。
 */
export const SEGMENT_MODE_SELF: string = 'self';
export const SEGMENT_MODE_USER: string = 'user';
/**
 * **Reels 页那条**：两段、**文字**（探索 / 关注），挂在 HDS 标题栏里。
 *
 * 为什么复用这个组件而不是另写一个：需求是"套用用户主页的那款" —— 沉浸光感材质、
 * 会滑动的灰底药丸、点按/横拖切换，这些东西在这里已经调过一轮了（材质必须挂在 Toggle 上、
 * 灰底靠算出来的段宽平移、不能自绘 .shadow()），另写一份必然再踩一遍。
 * 差别只有两条：段里放**文字**而不是图标；胶囊要窄一点（段数只有 2）并居中。
 */
export const SEGMENT_MODE_REELS: string = 'reels';
const ICONS_SELF_NORMAL: Array<Resource> = [
  $r('sys.symbol.square_grid_2x2'),
  $r('sys.symbol.template'),
  $r('sys.symbol.bookmark'),
  $r('sys.symbol.star')
];
const ICONS_SELF_SELECTED: Array<Resource> = [
  $r('sys.symbol.square_fill_grid_2x2'),
  $r('sys.symbol.template_fill'),
  $r('sys.symbol.bookmark_fill'),
  $r('sys.symbol.star_fill')
];
const ICONS_USER_NORMAL: Array<Resource> = [
  $r('sys.symbol.square_grid_2x2'),
  $r('sys.symbol.template'),
  $r('sys.symbol.star')
];
const ICONS_USER_SELECTED: Array<Resource> = [
  $r('sys.symbol.square_fill_grid_2x2'),
  $r('sys.symbol.template_fill'),
  $r('sys.symbol.star_fill')
];

@Component
export struct ProfileSegmentBar {
  /** 当前分页（0..count-1）。真相在外面（页面 / 视图模型），这里只读它。 */
  @Prop tab: number = 0;
  /**
   * 分段数量（本人 4 / 别人主页 3，见 SEGMENT_MODE_*）。
   *
   * 别人主页没有"收藏"那一段（需求），所以段数得能配 —— 段宽、灰底位移、命中判定全都按它算。
   */
  @Prop count: number = SEGMENT_MAX;
  /** 图标组模式（见 SEGMENT_MODE_SELF / SEGMENT_MODE_USER）。 */
  @Prop mode: string = SEGMENT_MODE_SELF;
  /**
   * 可用宽度（vp）的**兜底值**（量到真实宽度之前用）。
   *
   * 灰底靠**算出来的段宽**平移定位（`.offset`），而 Stack 里的百分比是相对父容器、
   * 和"段"的划分不一定同源，所以必须知道真实内宽。这里传进来的只是个起点：
   * 组件自己会用 `onAreaChange` 量出真实宽度（见 measuredWidthVp），量到之后以它为准 ——
   * 两个宿主（页面里 / 标题栏里）的内宽不一样，靠外部传值很容易算偏（实测就是"灰底错位"）。
   */
  @Prop availableWidthVp: number = 0;
  /**
   * 宿主是不是 **HDS 标题栏**。
   *
   * 是的话**不挂沉浸光感材质**：标题栏自己已经是一层材质，官方《沉浸光感功耗优化》明确
   * "避免材质嵌套"（同一子树里只应在最外层设一次），嵌套时内层材质不生效 —— 表现就是胶囊
   * 完全没有玻璃底、只剩那颗灰底孤零零地杵着。所以标题栏那一版改用"低透明度中性底 +
   * 背景模糊"凑出同一层观感（老接口，稳）。
   *
   * 注：需求后来要求"改回沉浸光感样式"，所以这个开关**默认不用**（两版都走材质），
   * 留着是为了万一标题栏里材质真的不生效时能一行切回去。
   */
  @Prop inTitleBar: boolean = false;
  /** 材质厚薄（跟设定页联动）。 */
  @StorageProp(SETTING_MATERIAL_THICKNESS) materialThickness: string = MATERIAL_THICKNESS_ULTRA_THIN;
  /**
   * **标题栏里那一版**：上下不留白（Reels 那条用）。
   *
   * 页面里那版上下各留 8/12 vp（让胶囊和周围内容有呼吸）；标题栏的行高只有 56vp，
   * 再留白会把胶囊挤出那一条。左右仍然内缩 SEGMENT_SIDE（胶囊要比屏幕窄一点、居中）。
   */
  @Prop compact: boolean = false;
  /** 选了某一段（点击或拖动松手）。 */
  onSelect: (index: number) => void = (index: number): void => {
  };
  /** 拖动中手指压在第几段（-1 = 没在拖）。 */
  @State private dragSeg: number = -1;
  /** 组件**自己量出来的**可用宽度（vp）：量到就以它为准，见 availableWidthVp 的说明。 */
  @State private measuredWidthVp: number = 0;

  /** 一段有多宽（vp）：可用宽 ÷ 段数（量不到就用兜底值，别让灰底跑到胶囊外）。 */
  private segmentWidth(): number {
    let total: number = this.measuredWidthVp;
    if (total <= 0) {
      total = this.availableWidthVp > 0 ? this.availableWidthVp : FALLBACK_WIDTH_VP;
    }
    const inner: number = total - SEGMENT_SIDE * 2;
    const count: number = this.segmentCount();
    return inner > 0 ? inner / count : FALLBACK_WIDTH_VP / count;
  }

  /** 实际段数（防呆：夹在 1..SEGMENT_MAX 之间）。 */
  private segmentCount(): number {
    if (this.count < 1) {
      return 1;
    }
    return this.count > SEGMENT_MAX ? SEGMENT_MAX : this.count;
  }

  /** 图标（正常态）。 */
  private iconNormal(index: number): Resource {
    const icons: Array<Resource> = this.mode === SEGMENT_MODE_USER ? ICONS_USER_NORMAL : ICONS_SELF_NORMAL;
    return index >= 0 && index < icons.length ? icons[index] : icons[0];
  }

  /** 图标（选中态，填充版）。 */
  private iconSelected(index: number): Resource {
    const icons: Array<Resource> = this.mode === SEGMENT_MODE_USER ? ICONS_USER_SELECTED : ICONS_SELF_SELECTED;
    return index >= 0 && index < icons.length ? icons[index] : icons[0];
  }

  /** 文字模式（Reels 那条）用的标签：0 = 探索，1 = 关注。 */
  private labelOf(index: number): ResourceStr {
    return index === 1 ? $r('app.string.reels_segment_following') : $r('app.string.reels_segment_explore');
  }

  /** 这一段是文字还是图标（见 SEGMENT_MODE_REELS）。 */
  private textMode(): boolean {
    return this.mode === SEGMENT_MODE_REELS;
  }

  /** ForEach 用的下标表（段数可配，不能写死 [0,1,2,3]）。 */
  private indices(): Array<number> {
    const out: Array<number> = [];
    for (let index: number = 0; index < this.segmentCount(); index++) {
      out.push(index);
    }
    return out;
  }

  /** 灰底现在该落在哪一段（拖动中 = 手指那一段，否则 = 当前分页）。 */
  private thumbIndex(): number {
    return this.dragSeg >= 0 ? this.dragSeg : this.tab;
  }

  /** 灰底的水平位移（vp）：第 n 段 → n × 段宽（再加一点段内缩）。 */
  private thumbOffset(): number {
    return this.thumbIndex() * this.segmentWidth() + SEGMENT_THUMB_INSET;
  }

  /** 手指现在压在第几段（用局部坐标除以段宽）。 */
  private segmentAt(event: GestureEvent): number {
    const fingers: Array<FingerInfo> = event.fingerList;
    if (fingers === undefined || fingers.length === 0) {
      return this.tab;
    }
    const width: number = this.segmentWidth();
    if (width <= 0) {
      return this.tab;
    }
    const index: number = Math.floor(fingers[0].localX / width);
    return Math.min(this.segmentCount() - 1, Math.max(0, index));
  }

  build() {
    Row() {
      Toggle({ type: ToggleType.Button, isOn: false }) {
        Stack({ alignContent: Alignment.Start }) {
          // 选中态的灰底：跟着"拖动中的那一段"（dragSeg ≥ 0），没在拖就跟当前分页。
          // 位置**完全靠 Stack 居中 + offset 平移**：给 margin 会在"剩余空间居中"里
          // 再往下挪一点，看起来就是"灰底有点下沉"（用户报过）。
          Column()
            .width(this.segmentWidth() - SEGMENT_THUMB_INSET * 2)
            .height(SEGMENT_HEIGHT - SEGMENT_THUMB_INSET * 2)
            .borderRadius((SEGMENT_HEIGHT - SEGMENT_THUMB_INSET * 2) / 2)
            // 灰底：**只靠颜色自己的不透明度**（浅色 #99D6D6D6 / 深色 #99454545），
            // 不再靠"换一个资源"来区分宿主 —— 需求："灰底只需要调低它的色彩不透明度"。
            .backgroundColor($r('app.color.segment_thumb'))
            .offset({ x: this.thumbOffset() })
            // 属性一变就按这个参数补间：拖动时逐帧定位（几乎不补），松手落定那一下才有动画。
            .animation({ duration: SEGMENT_SLIDE_MS, curve: Curve.EaseOut })

          Row() {
            ForEach(this.indices(), (index: number): void => {
              Row() {
                if (this.textMode()) {
                  // 文字模式（Reels 那条）：选中态加粗一点，颜色跟图标那套一致（不改背景色）。
                  Text(this.labelOf(index))
                    .fontSize(SEGMENT_LABEL_SIZE)
                    .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Regular)
                    // Text 的 fontColor 收单个颜色（图标那个是数组，见下面的 SymbolGlyph）。
                    .fontColor(this.tab === index
                      ? $r('app.color.primary_text') : $r('app.color.secondary_text'))
                    .maxLines(1)
                } else {
                  SymbolGlyph(this.tab === index ? this.iconSelected(index) : this.iconNormal(index))
                    .fontSize(SEGMENT_ICON)
                    .fontColor([this.tab === index
                      ? $r('app.color.primary_text') : $r('app.color.secondary_text')])
                }
              }
              .layoutWeight(1)
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .onClick((): void => {
                this.onSelect(index);
              })
            }, (index: number): string => `seg-${index}`)
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height(SEGMENT_HEIGHT)
      .padding(0)
      .borderRadius(SEGMENT_HEIGHT / 2)
      .backgroundColor(Color.Transparent)
      // 选中态透明：否则点一下整颗变蓝（同 MaterialSurface 的说明）。
      .selectedColor(Color.Transparent)
      // 材质**两版都挂**（需求："分段按钮改回沉浸光感样式"）。标题栏那一版按官方说法属于
      // 材质嵌套，但实测观感就是要它这层玻璃，所以不再区分宿主；真出问题把 inTitleBar
      // 那个开关接回来即可（见它的说明）。
      .attributeModifier(new SurfaceModifier(this.materialThickness, false, true))
      .onChange((): void => {
        // 纯容器，不接功能（四段各自接点击）。
      })
      .onTouch(trackMaterialTouch)
      // 拖动切换：只认横向（竖着划留给列表滚动）。
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: SEGMENT_DRAG_DISTANCE })
          .onActionStart((event: GestureEvent): void => {
            this.dragSeg = this.segmentAt(event);
          })
          .onActionUpdate((event: GestureEvent): void => {
            const seg: number = this.segmentAt(event);
            if (seg !== this.dragSeg) {
              this.dragSeg = seg;
            }
          })
          .onActionEnd((): void => {
            const target: number = this.dragSeg;
            // 先收掉拖动态（灰底回到"当前分页"），再切页 —— 切页会把灰底带到新那一段。
            this.dragSeg = -1;
            if (target >= 0) {
              this.onSelect(target);
            }
          })
      )
    }
    .width('100%')
    // 只留按钮自己的内边距：**不铺底色块**（需求："把分段按钮的背景色块去掉"）。
    .padding({
      left: SEGMENT_SIDE,
      right: SEGMENT_SIDE,
      top: this.compact ? 0 : 8,
      bottom: this.compact ? 0 : 12
    })
    // 量一次真实可用宽度：两个宿主的内宽不一样，灰底定位必须按**量到的**算（见 availableWidthVp）。
    .onAreaChange((oldArea: Area, newArea: Area): void => {
      const width: number = typeof newArea.width === 'number' ? newArea.width as number : 0;
      if (width > 0 && Math.abs(width - this.measuredWidthVp) > 0.5) {
        this.measuredWidthVp = width;
      }
    })
  }
}
