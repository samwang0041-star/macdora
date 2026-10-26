# Macdora

原生界面与动效规范。

这套规范服务于 Macdora 的真实 AppKit 管理端。它借鉴 CleanMyMac 5.7.2 的空间层级、通透选中态、立体主视觉与状态动效；颜色、品牌素材、原生组件和页面行为以 Macdora 自己的实现为准。阅读本文件后，再按需读取 `tokens.json`、组件指南和 `REFERENCE.md`。

## 来源与使用

`tokens.json` 是生产源码的文档镜像：47 个颜色参数、10 个文字样式、浅色与深色两套主题。颜色从 `TFTheme` 与 `ManagementVisualPalette` 自动导出；布局、文字层级和动效来自已核对的原生入口。AppKit 的真实字号单位为 pt，文档预览用相同数值的 CSS px；CSS 行高与阴影是文档中的映射，不声称等同于 AppKit 的排版和模糊内核。

生产实现位于项目根目录的 `Sources/AndroidUse/ManagementWindow.swift`、`ManagementVisuals.swift` 与 `LocationPluginWorkspaceView.swift`。修改生产样式后，在项目根目录运行 `python3 design-system/macdora/tools/export-native-tokens.py`，同步生成 `tokens.json` 与 `tokens.css`。导出文件不要手动改值；字阶和布局调整还须同步检查导出脚本中的明确映射。

`references/cleanmymac-5.7.2.json` 仅保存逆向研究结果：30 个已追到初始化函数的颜色输入、26 个字号/字重初始化项和 7 个布局/动效默认值。它不参与 Macdora 的渲染。来源、方法和未恢复项见 `REFERENCE.md`。

## 内容原则

每个页面只有一个标题，说明交代当前用途。操作文字使用动词：打开、安装、重试、停止。首次下载、准备、启动、就绪、运行、停止与失败分别显示真实状态。只有取得实际字节进度时显示确定进度；没有测量的性能指标使用 `—`，未检查更新时只显示版本号。

设置解释用户能做的事。横屏、竖屏始终表示窗口布局；设备身份保持同一平板。缓存清理说明保留应用数据。摄像头设置禁用时说明何时可改。诊断先给一句结果，再列出有用的检查项。

## 视觉基础

- 深蓝侧栏固定承载导航，使用 `sidebar-ink`、`sidebar-ink2`。选中状态组合 `sidebar-selection`、`sidebar-selection-line`、`sidebar-accent` 和加粗文字。
- 工作区使用 `canvas`，卡片使用 `card`，次级控件使用 `card2`。正文依次使用 `ink`、`ink2`、`ink3`。说明文字不再叠加降低透明度。
- 主要操作使用 `accent-fill` 与 `on-fill`。列表中的常规打开操作使用 `accent-soft` 与 `accent-ink`。卸载平时保持克制，悬停后使用 `danger-soft` 与 `danger`，文字始终说明操作。
- 成功、提醒、错误由文字和颜色共同表达。原生焦点环使用系统焦点行为；文档预览以实色 `accent` 描边显示键盘焦点。
- 主标题 21pt，环境状态 15pt，列表名称 14.5pt，正文 12.5pt，说明 12pt。指标使用等宽数字。使用 macOS 系统字体与系统中文回退；不打包或复制系统字体。
- 控件、标签、卡片分别采用 `radius-button`、`radius-badge`、`radius-card`。卡片间距使用 `space-18`，组内操作使用 `space-8`，卡片横向留白使用 `space-16`，主工作区至少保留 `space-32`。

## 动效

页面由用户切换时，使用 `duration-page`（200ms）淡入和 3pt 轻微位移；平板主视觉以 `duration-scene`（450ms）进入。真实忙碌状态最多播放两轮 `duration-busy`（480ms）光晕。后台刷新保留页面与搜索编辑器，不触发整页入场动画。

系统开启“减少动态效果”时，主视觉与切页动画静止，地图调整直接到达目标区域。窗口隐藏、遮挡、最小化或应用退出前台时停止主视觉动效；运行结束后移除忙碌提示。所有动画最终状态先写入 model layer，不依赖动画保留界面状态。

## 组件

生产组件是 AppKit 控件。`components/` 中的 Button、Toggle、SegmentedControl 和 Motion 是可交互的网页参考组件，用于设计文档与后续界面探索；它们不是管理端的替代运行时。使用网页参考组件时先加载 `tokens.css`，再加载 `components/bundle.css` 与 `components/bundle.js`，入口为 `window.MacdoraUI`，无外部依赖。

组件指南说明用途、状态、调用方数据与原生入口。`preview.html` 汇总基础、交互和原生渲染示例。`assets/Previews/` 来自实际 AppKit 控件的离屏渲染，使用“便笺”“浏览器”等明确演示数据；真实使用验收保存在任务的私有证据目录中。

在本目录运行 `python3 -m http.server 8766 --bind 127.0.0.1`，然后打开 `http://127.0.0.1:8766/preview.html` 可查看交互总览。预览只从本目录读取资源，没有外部字体或运行时依赖。单个组件预览也可从 `components/<Comp>/preview.html` 访问。

## 品牌与图标

`assets/Brand/` 直接复用项目现有 Macdora 字标与图标，未重画标志。深色底使用 `wordmark-dark.png`，浅色底使用 `wordmark-light.png`。界面功能图标使用现有 SF Symbols 入口；平板主视觉是独立创作的 CALayer 图形。品牌素材用法见该目录 README。

## 验证范围

检查每个主题声明的文字/底色组合及强调按钮的对比度；检查原生 900×600 与常规窗口、搜索中文组合输入、焦点、禁用状态和真实打开应用。字体回退、系统焦点颜色、第三方应用内部页面及地图在线数据仍由目标系统与对应应用负责，不能通过 token 文件推断其实际表现。
