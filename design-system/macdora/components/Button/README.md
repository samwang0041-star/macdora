# Button

用明确的动词呈现用户当前可以执行的操作。

生产入口为 `ManagementWindow.swift` 中的 `TFButton`。网页入口为 `MacdoraUI.Button(props)`，返回原生 HTML button；两者分别运行，不共享业务状态。

| 变体 | 用途 |
| --- | --- |
| primary | 当前页面的一项主要操作，如安装 |
| secondary | 取消、重试与常规工具操作 |
| tinted | 列表中的打开操作，保持低噪声 |
| subtle / ghost | 低优先级、仍需清楚可见的操作 |
| danger | 卸载等破坏性入口；平时克制，悬停提示危险 |

覆盖默认、悬停、按下、键盘焦点与禁用状态。禁用原因由调用方显示在相关说明中。颜色与文字共同说明用途；危险操作的确认、对象和结果由生产调用方管理。网页示例只展示视觉反馈，不安装或删除数据。

网页 props 为 `label`、`variant`、`disabled`、`ariaLabel` 与 `onClick`。优先使用可见文字；纯图标按钮必须提供可理解的名称。按钮保留浏览器原生键盘行为；原生产品保留 AppKit 的焦点和无障碍行为。
