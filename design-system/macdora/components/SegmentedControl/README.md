# SegmentedControl

让用户在少量互斥且可直接理解的选项间切换。

生产入口为 `ManagementWindow.swift` 中的 `TFSegmentedControl`。网页入口为 `MacdoraUI.SegmentedControl(props)`，返回带 legend 的 fieldset，内部使用同名原生 radio。props 为 `label`、`options`、`value`、`disabled` 与 `onChange(value)`。

横屏与竖屏只表示显示布局，始终使用同一平板设备身份。该约束由生产运行时保持；网页示例只更新文档中的选中状态。

选择状态使用底板、文字颜色和原生 checked 共同表达。组名称可由辅助技术读取。使用 Tab 进入选项组、方向键切换选项；禁用组不改变值。容器缩窄时优先压缩旁边的说明，保留选项名称。
