# Instamony 1.6.0-mirrorfix

- 翻页超过 90° 后立即用黑底盖住正面，消除镜像内容闪现
- 背面提前渲染下一位用户；无数据时居中加载图标
- 翻页状态增加兜底计时器，动画 onFinish 丢失时也会解锁，不会卡死
- 加载层不吞手势，仍可下滑收起/继续操作
- Bundle: `com.yijin.instamony`
