/*
 * 「通知」页面的内容（装在 NavDestination 里，见 pages/Index.ets 的 destinationBuilder）。
 *
 * 结构（对照 IG 活动页）：
 *   标题栏 由 HdsNavDestination 提供（标题「通知」+ 返回键 + 沉浸光感材质）
 *   正文   List，分段：今天 / 本月 / 更早 / 为你推荐（空的分段不显示）
 *          - 通知项：头像（1~2 张叠放）+ 富文本（用户名加粗、动作文案、灰色日期）
 *                    + 右侧二选一：缩略图 或 关注状态按钮
 *          - 推荐项：头像 + 用户 id / 用户名称 / 粉丝文案 + 右侧「关注」按钮
 *
 * 数据由页面的 Index 抓取后以 @Prop 传进来（见 pages/Index.ets 的 loadNotifications），
 * 这个组件只负责画，不认识网页；返回也由 NavDestination 自己处理。
 */

import { NotifyItem, NotifyGroup, NOTIFY_GROUPS } from '../model/Notification';
import { MaterialLabelButton } from './MaterialSurface';

/** 通知项头像大小（vp）。 */
const AVATAR_SIZE: number = 44;
/** 推荐项头像略大一点，和参考图一致。 */
const SUGGEST_AVATAR_SIZE: number = 48;
/** 右侧缩略图大小（vp）。 */
const THUMB_SIZE: number = 46;
/** 两行都是列表行，行内左右留白统一 16。 */
const SIDE_PADDING: number = 16;
/**
 * 顶部让出标题栏的高度（vp），做法与**首页信息流完全一致**。
 *
 * 为什么从 `List.contentStartOffset` 换成"上面垫一层透明占位"：内缩内容起点时，`Refresh`
 * 自己也贴在列表顶边（也就是屏幕顶端），系统那颗**原生下拉刷新图标会被标题栏压住看不见**；
 * 首页早就踩过这个坑，解法是把 `Refresh` 整体下移到标题栏之下（见 FeedList.build 的说明）。
 * 通知页这里照同一套来 —— 代价一样：列表可视区顶边下移，内容不再从标题栏下面穿过去。
 *
 * 取值**和首页的 FEED_START_OFFSET 保持一致（94）**，两页的避让高度才一样。
 */
const LIST_TOP_OFFSET: number = 94;
/**
 * 打招呼弹窗里输入框的 id。
 *
 * 弹窗一出来就要把焦点交给它、并且把输入法弹起来 —— 用 id 才能在 onAppear 里
 * requestFocus（见 openMessage）。
 */
const MESSAGE_INPUT_ID: string = 'notifyMessageInput';

@Component
export struct NotificationsPanel {
  /** 抓回来并按分组排好序的通知/推荐。 */
  @Prop items: NotifyItem[] = [];
  /** 还在读网页。 */
  @Prop loading: boolean = false;
  /** 读不到时的原因（'' 表示没出错）；文案由这里映射。 */
  @Prop state: string = '';
  /** 诊断摘要（网页侧回的结构信息），读不到评论时显示出来便于定位。 */
  @Prop diag: string = '';
  /**
   * 下拉刷新的状态（与页面**双向**绑定）。
   *
   * 两个方向都用它：页面去网页取数时置 true（原生刷新动画转起来，用户知道在取数据），
   * 用户自己下拉时 Refresh 置 true 并回调 onRefresh（见 build 里的 Refresh）。
   */
  @Link refreshing: boolean;
  /** 用户下拉时通知页面重新取一次（页面自己去防重入）。 */
  onRefresh: () => void = (): void => {
  };
  /** 点「回关 / 关注」。真正去网页里点由页面负责（这里只把动作转出去）。 */
  onFollow: (item: NotifyItem) => void = (item: NotifyItem): void => {
  };
  /** 「发消息」弹窗是否显示（bindSheet 双向绑定，用户拖走时自己会变回 false）。 */
  @State messageShown: boolean = false;
  /** 正在打招呼的人：用户 id、头像、以及那句招呼语（推荐位和通知位的说法不同）。 */
  @State messageName: string = '';
  @State messageAvatar: string = '';
  @State messageSuggested: boolean = false;
  /** 输入框里的草稿（当前只留在本地，发送还没接）。 */
  @State messageDraft: string = '';

  /** 某个分组下面的条目（保持原顺序）。 */
  private groupItems(group: NotifyGroup): NotifyItem[] {
    const out: NotifyItem[] = [];
    for (let i: number = 0; i < this.items.length; i++) {
      if (this.items[i].group === group) {
        out.push(this.items[i]);
      }
    }
    return out;
  }

  /** 分组标题文案。 */
  private groupLabel(group: NotifyGroup): ResourceStr {
    if (group === 'today') {
      return $r('app.string.notify_today');
    }
    if (group === 'month') {
      return $r('app.string.notify_month');
    }
    if (group === 'suggested') {
      return $r('app.string.notify_suggested');
    }
    return $r('app.string.notify_earlier');
  }

  build() {
    // 标题栏由外层的 HdsNavDestination 提供（见 pages/Index.ets 的 destinationBuilder），
    // 这里只管正文。NavDestination 是页面级承载，安全区/底部由它负责 ——
    // 之前用 bindContentCover 时底部总露一条主页，就是因为模态的内容区不到屏幕底。
    //
    // 结构**和主页 FeedList 一样**（需求：还原成最初那套，不再折腾 list 视口）：
    //   外层 Column { 透明 Stack(94vp) ; Refresh { List } }
    //   · 透明 Stack 把列表整体推到标题栏之下 → 原生刷新图标天然避让；
    //   · List/Refresh 的 `.clip(false)` 保留（内容能画到标题栏底下，和主页一致）。
    Column() {
      Stack()
        .width('100%')
        .height(LIST_TOP_OFFSET)

      // 有内容就直接显示列表：**不要**因为"正在刷新"把已有内容换成转圈 ——
      // 第二次打开通知时旧列表要一直留着，直到新数据回来（见 Index.loadNotifications）。
      if (this.loading && this.items.length === 0) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color($r('app.color.secondary_text'))
          Text($r('app.string.notify_loading'))
            .fontSize(14)
            .fontColor($r('app.color.secondary_text'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.heart'))
              .fontSize(40)
              .fontColor([$r('app.color.secondary_text')])
            Text($r('app.string.notify_empty'))
              .fontSize(15)
              .fontColor($r('app.color.secondary_text'))
            if (this.diag.length > 0) {
              Text(this.diag)
                .fontSize(11)
                .fontColor($r('app.color.secondary_text'))
                .maxLines(3)
                .padding({ left: 24, right: 24 })
            }
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          // 下拉刷新：包住列表（列表是它的可滚动子节点）。
          //
          // `refreshing` 与页面**双向**绑定（@Link）：页面去网页取数时把它置 true，系统的
          // 原生刷新动画就转起来 —— 用户看得到"正在取数据"，而不是一个静悄悄不动的列表；
          // 用户自己下拉时 Refresh 会把它置 true 并回调 onRefresh，页面再跑一次取数。
          Refresh({ refreshing: $$this.refreshing }) {
            List() {
              ForEach(NOTIFY_GROUPS, (group: NotifyGroup): void => {
                if (this.groupItems(group).length > 0) {
                  ListItemGroup({ header: this.sectionHeader(group) }) {
                    ForEach(this.groupItems(group), (item: NotifyItem, index: number): void => {
                      ListItem() {
                        if (item.isSuggested()) {
                          this.suggestRow(item)
                        } else {
                          this.notifyRow(item)
                        }
                      }
                      // key 里必须带上 following：点了关注之后换回来的是一条"只有关注状态变了"
                      // 的新对象，key 不变的话 ForEach 认成同一项、直接复用旧节点，按钮文案就
                      // 永远停在"回关"。
                    }, (item: NotifyItem, index: number): string =>
                    `${group}-${index}-${item.username}-${item.text}-${item.following ? 1 : 0}`)
                  }
                }
              }, (group: NotifyGroup): string => group)
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            // 和首页一样：列表回弹用弹簧，滚到顶再拉就是下拉刷新。
            .edgeEffect(EdgeEffect.Spring)
            // 顶部避让由父层 Scroll 负责（见 build 开头的 NestedScroll 说明），这里不再内缩。
            // **别裁内容**：关掉裁剪后滚动的行才会画到标题栏底下。
            .clip(false)
            .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 72, endMargin: 0 })
          }
          .width('100%')
          // 和主页一样：占满剩余高度（上方透明 Stack 已经把整块推到标题栏之下）。
          .layoutWeight(1)
          // Refresh 也别裁：内容要能从它顶边越出去。
          .clip(false)
          .onRefreshing((): void => {
            this.onRefresh();
          })
        }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    // 打招呼弹窗：高度按内容收（就一行招呼语 + 一个输入框），顶部那条可以拖的小横条
    // 由系统的 dragBar 提供；$$ 双向绑定，用户往下拖走时 messageShown 自己变回 false。
    .bindSheet($$this.messageShown, this.messageSheet(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.page_background')
    })
  }

  /** 分段标题（今天 / 本月 / 更早 / 为你推荐）。 */
  @Builder
  sectionHeader(group: NotifyGroup) {
    Text(this.groupLabel(group))
      .fontSize(18)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.primary_text'))
      .width('100%')
      .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 18, bottom: 8 })
      .backgroundColor($r('app.color.page_background'))
  }

  /**
   * 两张头像时每张的直径（单人时就是原尺寸）—— 见 avatarStack 的说明。
   *
   * 单独写成方法而不是在 @Builder 里声明局部变量：@Builder 只允许 UI 语法，
   * 局部变量会编译报错（"Only UI component syntax can be written here"）。
   */
  private unitAvatar(item: NotifyItem, size: number): number {
    return item.avatars.length > 1 ? size / 1.5 : size;
  }

  /**
   * 头像：1~2 张。
   *
   * 两张时按**左上 / 右下对角线叠放**（需求），并且**整组不超过单人头像的大小**：
   * 两人各自缩到 `size / 1.5`——斜对角构图的总跨度是"一张的直径 + 半个身位的偏移"
   * = 1.5 倍单张直径，正好等于单人时那一格，行首对位才不会比别的行宽出去。
   */
  @Builder
  avatarStack(item: NotifyItem, size: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      if (item.avatars.length > 0) {
        Image(item.avatars[0])
          .draggable(false)
          .width(this.unitAvatar(item, size))
          .height(this.unitAvatar(item, size))
          .borderRadius(this.unitAvatar(item, size) / 2)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('app.color.field_background'))
      } else {
        Column()
          .width(this.unitAvatar(item, size))
          .height(this.unitAvatar(item, size))
          .borderRadius(this.unitAvatar(item, size) / 2)
          .backgroundColor($r('app.color.field_background'))
      }
      if (item.avatars.length > 1) {
        Image(item.avatars[1])
          .draggable(false)
          .width(this.unitAvatar(item, size))
          .height(this.unitAvatar(item, size))
          .borderRadius(this.unitAvatar(item, size) / 2)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('app.color.field_background'))
          // 描边用页面底色：两张叠在一起时第二张的边能"切"出第一张的轮廓。
          .border({ width: 2, color: $r('app.color.page_background') })
          // 往右下挪半个身位（对角线）。用 offset 而不是 margin：offset 只挪位置、
          // 不参与 Stack 的尺寸计算，整组的边界才能由外面那层定死。
          .offset({ x: this.unitAvatar(item, size) * 0.5, y: this.unitAvatar(item, size) * 0.5 })
      }
    }
    .width(size)
    .height(size)
  }

  /**
   * 右侧那颗关注按钮。
   *
   * 只在**未关注**时出现（回关 / 关注）。已关注的那一档换成「发消息」——原因见
   * messageButton：网页侧的取关要点一个二次确认菜单，脚本合成点击触发不了。
   * 样式：文字白色（底色由沉浸光感材质给，全 app 按钮统一，见 MaterialSurface）。
   */
  @Builder
  followButton(item: NotifyItem, compact: boolean) {
    MaterialLabelButton({
      labelRes: this.followLabel(item),
      pillWidth: compact ? 74 : 78,
      fontSize: 14,
      // 文字用**白色**（需求）：不传 tone 就走 MaterialLabelButton 的默认档
      // （系统可反色资源色，深色主题下就是白色）；强调色那档只在登录/搜索这类
      // 主行动按钮上用。
      onTap: (): void => {
        this.onFollow(item);
      }
    })
  }

  /**
   * 右侧那颗「发消息」按钮：**已关注**的条目用它顶替关注按钮。
   *
   * 为什么不是「已关注」按钮：网页侧的取关要点「已关注」→ 再点菜单里的「取消关注」，
   * 而那个菜单只认真实用户的触摸手势 —— 实测用脚本合成点击（含 pointer 事件）
   * 菜单始终不弹（`dlg=0 hasUnfollow=false`，整页文字里根本没有"取消关注"），
   * 所以通知页上根本触发不了取关。与其放一颗点了没反应的按钮，不如给一个真能用的动作：
   * 打开打招呼弹窗（人已经关注你了，回消息是最自然的下一步）。
   * 样式沿用原来"已关注"那颗：描边、不加色 —— 现在描边由材质边缘给。
   */
  @Builder
  messageButton(item: NotifyItem, compact: boolean) {
    MaterialLabelButton({
      labelRes: $r('app.string.notify_message'),
      pillWidth: compact ? 74 : 78,
      fontSize: 14,
      onTap: (): void => {
        this.openMessage(item);
      }
    })
  }

  /**
   * 打开打招呼弹窗，并把焦点交给输入框（输入法随之弹出）。
   *
   * 焦点要**等弹窗真正上屏**再要：onAppear 里立刻 requestFocus 偶尔会出现
   * "焦点要到了但输入法不弹"，所以延一小会儿再要一次。
   */
  private openMessage(item: NotifyItem): void {
    this.messageName = item.accountName();
    this.messageAvatar = item.avatars.length > 0 ? item.avatars[0] : '';
    this.messageSuggested = item.isSuggested();
    this.messageDraft = '';
    this.messageShown = true;
    setTimeout((): void => {
      try {
        this.getUIContext().getFocusController().requestFocus(MESSAGE_INPUT_ID);
      } catch (error) {
      }
    }, 260);
  }

  /** 关注按钮的文案：未关注时通知项说"回关"、推荐项说"关注"。 */
  private followLabel(item: NotifyItem): Resource {
    return item.isSuggested() ? $r('app.string.notify_follow') : $r('app.string.notify_follow_back');
  }

  /** 招呼语：通知项（对方关注了你）与推荐项说法不同。 */
  private greetText(): ResourceStr {
    return this.messageSuggested
      ? $r('app.string.notify_greet_suggest', this.messageName)
      : $r('app.string.notify_greet', this.messageName);
  }

  /**
   * 打招呼弹窗的内容（由 build 里的 bindSheet 调用）。
   *
   * 顶部那条可以拖的小横条由系统的 bindSheet（dragBar: true）提供，这里只管内容：
   *   第一行：头像 + 「{用户 id} 回关了你。打个招呼吧！」
   *   第二行：消息输入框（弹窗一出来就聚焦、弹输入法，见 openMessage）
   */
  @Builder
  messageSheet() {
    Column({ space: 14 }) {
      // 顶部那条"可以拖"的小横条：系统在 FIT_CONTENT 的弹窗上不会画（实测没有），
      // 所以自己画一条 —— 尺寸和系统那条一致（36 × 4，居中）。
      Column()
        .width(36)
        .height(4)
        .borderRadius(2)
        .backgroundColor($r('app.color.divider'))

      Row({ space: 12 }) {
        if (this.messageAvatar.length > 0) {
          Image(this.messageAvatar)
            .draggable(false)
            .width(SUGGEST_AVATAR_SIZE)
            .height(SUGGEST_AVATAR_SIZE)
            .borderRadius(SUGGEST_AVATAR_SIZE / 2)
            .objectFit(ImageFit.Cover)
            .backgroundColor($r('app.color.field_background'))
        } else {
          Column()
            .width(SUGGEST_AVATAR_SIZE)
            .height(SUGGEST_AVATAR_SIZE)
            .borderRadius(SUGGEST_AVATAR_SIZE / 2)
            .backgroundColor($r('app.color.field_background'))
        }

        Text(this.greetText())
          .fontSize(15)
          .fontColor($r('app.color.primary_text'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextInput({ placeholder: $r('app.string.notify_message_hint'), text: this.messageDraft })
        .id(MESSAGE_INPUT_ID)
        .defaultFocus(true)
        .fontSize(15)
        .placeholderFont({ size: 15 })
        .placeholderColor($r('app.color.secondary_text'))
        .fontColor($r('app.color.primary_text'))
        .backgroundColor($r('app.color.field_background'))
        .borderRadius(20)
        .height(42)
        .width('100%')
        .padding({ left: 14, right: 14 })
        .onChange((value: string): void => {
          this.messageDraft = value;
        })
    }
    .width('100%')
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 6, bottom: 18 })
    .onAppear((): void => {
      try {
        this.getUIContext().getFocusController().requestFocus(MESSAGE_INPUT_ID);
      } catch (error) {
      }
    })
  }

  /** 一条通知（今天 / 本月 / 更早）。 */
  @Builder
  notifyRow(item: NotifyItem) {
    Row({ space: 12 }) {
      this.avatarStack(item, AVATAR_SIZE)

      // 富文本：用户名**加粗** → 动作文案 → 灰色日期。两行以内，超出省略。
      Text() {
        ForEach(item.usernames, (name: string, index: number): void => {
          Span(index === 0 ? name : ` 和 ${name}`)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary_text'))
        }, (name: string, index: number): string => `${index}-${name}`)
        if (item.text.length > 0) {
          Span(` ${item.text}`)
            .fontColor($r('app.color.primary_text'))
        }
        if (item.dateText.length > 0) {
          Span(`  ${item.dateText}`)
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
        }
      }
      .fontSize(15)
      .lineHeight(21)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .layoutWeight(1)
      .textAlign(TextAlign.Start)

      // 右侧二选一：有缩略图就显示缩略图；否则已关注 →「发消息」，未关注 →「回关/关注」。
      if (item.thumbUrl.length > 0) {
        Image(item.thumbUrl)
          .draggable(false)
          .width(THUMB_SIZE)
          .height(THUMB_SIZE)
          .borderRadius(6)
          .objectFit(ImageFit.Cover)
          .backgroundColor($r('app.color.field_background'))
      } else if (item.buttonLabel.length > 0) {
        if (item.following) {
          this.messageButton(item, true)
        } else {
          this.followButton(item, true)
        }
      }
    }
    .width('100%')
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  /** 一条推荐（为你推荐）。 */
  @Builder
  suggestRow(item: NotifyItem) {
    Row({ space: 12 }) {
      Image(item.avatars.length > 0 ? item.avatars[0] : '')
        .draggable(false)
        .width(SUGGEST_AVATAR_SIZE)
        .height(SUGGEST_AVATAR_SIZE)
        .borderRadius(SUGGEST_AVATAR_SIZE / 2)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.field_background'))

      Column({ space: 2 }) {
        Text(item.username)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.displayName.length > 0) {
          Text(item.displayName)
            .fontSize(14)
            .fontColor($r('app.color.primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (item.socialText.length > 0) {
          Text(item.socialText)
            .fontSize(13)
            .fontColor($r('app.color.secondary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 推荐位也一样：已关注之后那颗按钮换成「发消息」（未关注才是「关注」）。
      if (item.following) {
        this.messageButton(item, false)
      } else {
        this.followButton(item, false)
      }
    }
    .width('100%')
    .padding({ left: SIDE_PADDING, right: SIDE_PADDING, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}
