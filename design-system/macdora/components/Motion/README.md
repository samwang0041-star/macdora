# Motion

用一次短反馈连接用户操作与新的界面状态。

生产入口为 `ManagementVisuals.swift` 中的 `TFMotion` 与 `TFDeviceSceneView`。网页参考仅提供 `MacdoraUI.Motion.reveal(element, reduceMotion)`，使用 `duration-page` 与 `ease-standard` 播放淡入及 3px 位移；它不模拟生产运行状态。

原生切页 200ms、平板入场 450ms、忙碌光晕 480ms 且最多两轮。仅用户切页触发页面入场；数据刷新保留内容、搜索编辑器和焦点。禁止用估算时间冒充下载进度。

网页方法先取消元素已有动画，再读取系统减少动态效果偏好与调用方的 `reduceMotion`。任一项开启时直接呈现最终状态；无常驻循环。原生实现还校验应用前台、窗口可见与遮挡状态，并在离开时移除动画。性能与真实首帧须在原生窗口验收。
