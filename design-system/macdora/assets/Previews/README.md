# 原生渲染示例

这些 PNG 由 `DocumentationAssetsTests` 调用真实 AppKit 管理端组件生成，内容为明确的演示数据，未导入任何用户账号或应用数据。`workspace`、`plugins` 是浅色，`workspace-dark`、`plugins-dark` 是深色，`environment` 展示有实际给定下载进度的准备状态。它们用于说明生产视觉，不代替真实安装应用的使用验收。

重新生成：在项目根目录执行 `MACDORA_README_ASSETS="$PWD/design-system/macdora/assets/Previews" swift test --filter DocumentationAssetsTests`。
