# Toggle

表达可立即生效的二元设置，同时提供明确的设置名称。

生产入口为 `ManagementWindow.swift` 中的 `TFToggleSwitch`。网页入口为 `MacdoraUI.Toggle(props)`，返回包含原生 checkbox 的 label。网页参考不写入产品设置。

props 为 `label`、`checked`、`disabled` 和 `onChange(checked)`。调用方持有真实设置，处理保存失败与回退；不能把本地切换动画当成后端保存成功。需要重启或运行时不可改的设置，由相关说明交代生效时机与禁用原因。

关闭与开启同时由轨道位置、颜色和原生 checked 状态表达。键盘可聚焦并使用空格切换；禁用项不触发回调。预览提供开、关与禁用状态，不播放持续装饰动画。
