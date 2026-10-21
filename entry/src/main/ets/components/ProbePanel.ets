/*
 * 探针面板：只读诊断报告的展示与操作。
 *
 * 报告本身由 probe/InstagramProbe 生成，内容里不含凭据（请求头里的 csrf / cookie /
 * authorization 在页面侧就已经打码）。
 */

@Component
export struct ProbePanel {
  @Prop text: string = '';
  onRefresh: () => void = (): void => {
  };
  onDom: () => void = (): void => {
  };
  onCopy: () => void = (): void => {
  };
  onSave: () => void = (): void => {
  };
  onClear: () => void = (): void => {
  };
  onClose: () => void = (): void => {
  };
  /**
   * 打开某个页面并把网页揭出来（本面板会自动收起）。
   *
   * 为什么放在探针面板里：要挖 reels / 私信 / 搜索 / 我的 的接口，就必须**让网页真的
   * 走一遍那些页面**（接口是页面自己发的），而原生这几页还没实现。这里是唯一现成的
   * 调试入口，点一下就能进那个页面现场抓，不必先发一条帖子再自己找路。
   */
  onOpenReels: () => void = (): void => {
  };
  onOpenSearch: () => void = (): void => {
  };
  onOpenDirect: () => void = (): void => {
  };
  onOpenProfile: () => void = (): void => {
  };
  /**
   * 用信息流第一条帖子走一遍"打开评论"。
   *
   * 为什么要在探针面板里放这个：评论有两条路（回放 / 导航），而信息流卡片那颗评论按钮
   * 在实机上正落在悬浮 tab 栏底下、不好点。从面板点最稳，也方便反复验证"第一次导航存模板、
   * 之后走回放"。
   */
  onCommentsFirst: () => void = (): void => {
  };
  /**
   * 在可见网页里打开第一条图片帖的帖子页（不跑任何读取脚本）。
   *
   * 用途：让**人**在网页里点一下评论图标 —— 那一下才会真正发出评论请求，而只有发过请求，
   * 评论模板才存在（见 ApiRegistry.capture）。这条路径也是"评论回放"日后能否成立的前提。
   */
  onOpenPostPage: () => void = (): void => {
  };
  /** 读当前页面里**内嵌**的评论数据（排查评论到底藏在哪，见 DOM_COMMENTS_PROBE_SCRIPT）。 */
  onCommentsEmbed: () => void = (): void => {
  };
  /** 把已存模板逐个回放并回一份**结构摘要**（写原生页面时照着它写解析）。 */
  onDigest: () => void = (): void => {
  };
  /**
   * 把「我的」那四个分页的接口模板都抓一遍（逐页导航 + capture）。
   *
   * 为什么要单独一个按钮：四个分页在网页上是四个地址（`/用户名/`、`/reels/`、`/saved/`、
   * `/tagged/`），各自发一条查询 —— 不逐个打开一次，那三条模板就永远不存在，
   * 原生 HTTP 那条路也就拿不到它们（见 core/NativeProfile 的说明）。
   */
  onProfileTemplates: () => void = (): void => {
  };
  /**
   * 抓**搜索页**的接口模板（推荐那条 + 结果那条），顺手落一份结构摘要。
   *
   * 和「我的」那四个分页同理：搜索页在网页上是独立地址（`/explore/search/`），
   * 不导航过去抓一次，原生 HTTP 那条路就没有模板可用（见 core/NativeSearch）。
   */
  onSearchTemplates: () => void = (): void => {
  };
  /**
   * 私信**发送握手自检**：把几种"身份"（网页 UA / 安卓 App UA + 安卓 app id + 设备头）
   * 各发一次 `/api/v1/direct_v2/threads/broadcast/text/`，看 IG 认哪一种。
   *
   * 全部发往不存在的 thread id `0`：能看出握手过没过，又**不会真的发消息给别人**
   * （见 core/NativeDirect.probeSendShape）。
   */
  onDirectSelfTest: () => void = (): void => {
  };

  /** 第二排的按钮：统一尺寸，避免每行重复一大串属性。 */
  @Builder
  openButton(label: Resource, action: () => void) {
    Button(label)
      .layoutWeight(1)
      .height(32)
      .fontSize(12)
      .backgroundColor($r('app.color.field_background'))
      .fontColor($r('app.color.primary_text'))
      .borderRadius(16)
      .onClick((): void => {
        action();
      })
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text($r('app.string.probe_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.primary_text'))
        Blank()
        Text($r('app.string.probe_hint'))
          .fontSize(11)
          .fontColor($r('app.color.secondary_text'))
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10 })

      Row({ space: 6 }) {
        Button($r('app.string.probe_refresh'))
          .layoutWeight(1)
          .height(32)
          .fontSize(12)
          .backgroundColor($r('app.color.field_background'))
          .fontColor($r('app.color.primary_text'))
          .borderRadius(16)
          .onClick((): void => {
            this.onRefresh();
          })
        Button($r('app.string.probe_dom'))
          .layoutWeight(1)
          .height(32)
          .fontSize(12)
          .backgroundColor($r('app.color.field_background'))
          .fontColor($r('app.color.primary_text'))
          .borderRadius(16)
          .onClick((): void => {
            this.onDom();
          })
        Button($r('app.string.probe_copy'))
          .layoutWeight(1)
          .height(32)
          .fontSize(12)
          .backgroundColor($r('app.color.field_background'))
          .fontColor($r('app.color.primary_text'))
          .borderRadius(16)
          .onClick((): void => {
            this.onCopy();
          })
        Button($r('app.string.probe_save'))
          .layoutWeight(1)
          .height(32)
          .fontSize(12)
          .backgroundColor($r('app.color.field_background'))
          .fontColor($r('app.color.primary_text'))
          .borderRadius(16)
          .onClick((): void => {
            this.onSave();
          })
        Button($r('app.string.probe_clear'))
          .layoutWeight(1)
          .height(32)
          .fontSize(12)
          .backgroundColor($r('app.color.field_background'))
          .fontColor($r('app.color.primary_text'))
          .borderRadius(16)
          .onClick((): void => {
            this.onClear();
          })
        Button($r('app.string.probe_close'))
          .layoutWeight(1)
          .height(32)
          .fontSize(12)
          .backgroundColor($r('app.color.accent'))
          .fontColor($r('app.color.on_accent'))
          .borderRadius(16)
          .onClick((): void => {
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      // 提示单独一行：原来它和四个按钮挤在同一行，而 `flexShrink(0)` 让提示不肯收缩，
      // 四个按钮就被挤到屏幕外（实测：面板上根本看不到 Reels/搜索/私信/我的 这四颗按钮）。
      Text($r('app.string.probe_open_hint'))
        .fontSize(11)
        .fontColor($r('app.color.secondary_text'))
        .width('100%')
        .padding({ left: 8, right: 8 })

      Row({ space: 6 }) {
        this.openButton($r('app.string.probe_open_reels'), this.onOpenReels)
        this.openButton($r('app.string.probe_open_search'), this.onOpenSearch)
        this.openButton($r('app.string.probe_open_direct'), this.onOpenDirect)
        this.openButton($r('app.string.probe_open_profile'), this.onOpenProfile)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      Row({ space: 6 }) {
        this.openButton($r('app.string.probe_direct_selftest'), this.onDirectSelfTest)
        this.openButton($r('app.string.probe_open_direct'), this.onOpenDirect)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      Row({ space: 6 }) {
        this.openButton($r('app.string.probe_comments_first'), this.onCommentsFirst)
        this.openButton($r('app.string.probe_open_post'), this.onOpenPostPage)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      .padding({ left: 8, right: 8 })

      Row({ space: 6 }) {
        this.openButton($r('app.string.probe_profile_templates'), this.onProfileTemplates)
        this.openButton($r('app.string.probe_search_templates'), this.onSearchTemplates)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      Row({ space: 6 }) {
        this.openButton($r('app.string.probe_comments_embed'), this.onCommentsEmbed)
        this.openButton($r('app.string.probe_digest'), this.onDigest)
      }
      .width('100%')
      .padding({ left: 8, right: 8 })

      Scroll() {
        Text(this.text)
          .fontSize(10)
          .fontColor($r('app.color.primary_text'))
          .textAlign(TextAlign.Start)
          .width('100%')
          .padding(8)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
