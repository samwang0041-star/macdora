# 系统助手（agent.mika）— 原生模式设计记录

## 定位

Macdora 的系统级 App 操作助手。与早期方案的根本区别：**不再安装 Android 应用**。
助手的全部逻辑（任务循环、提示词、模型调用）运行在 Mac 侧；guest 内只使用系统通道。
目标 App 视角下，操作与用户在系统里正常使用应用没有区别。

## 架构

```
Mac 原生工作台 (AssistantPluginWorkspaceView)
        │  JSON-RPC over Unix socket
宿主服务 (bin/mika-host-service, Python)
        │  adb
Android 环境
  ├─ scrcpy 会话 → 后台虚拟显示（不可见，宿主保持视频流）
  ├─ screencap（SurfaceFlinger 显示标识）→ 屏幕画面
  ├─ input -d（点击/滑动/按键）
  ├─ resolve-activity + am start --display（启动应用）
  └─ DirectInput IME（中文等文字提交）
```

### 关键通道与已验证事实（2026-11-03 真机验证）

| 能力 | 实现 | 验证 |
| --- | --- | --- |
| 创建后台显示 | 宿主 `app_process` 启动 scrcpy server（`new_display=WxH/DPI`，`tunnel_forward=true`，`display_ime_policy=local`），按预览/任务需求创建，10 FPS 保持并持续丢弃视频套接字；空闲 5 分钟释放 | 成功创建 display 10/11 |
| 显示标识映射 | DisplayManager id → `uniqueId` → `dumpsys SurfaceFlinger --display-id` 中唯一匹配的 SF display | 截图成功；并发同名 `scrcpy` 显示不会串流 |
| 截图 | `screencap -d <SurfaceFlinger id> -p`（不是 DisplayManager id） | 1080×1920 PNG |
| 输入 | `input -d <DisplayManager id> tap/swipe/keyevent/text` | 点击微信搜索框成功 |
| 启动应用 | `cmd package resolve-activity` 得到入口后 `am start --display <id> -n <component>` | 微信在后台显示启动 |
| 中文输入 | `androiduse_ime_v1`：hello → 焦点帧 → confirm → commit（大端定宽字段） | 「测试」成功写入微信搜索框 |
| 完整循环 | mock 模型驱动 3 步完成任务（启动应用 → 截图 → 完成） | 任务状态 done |

注意事项：
- scrcpy server 的 classes.dex 必须未压缩（STORED）；运行时自带的压缩版本在
  `app_process` 下会 `ClassNotFoundException`。插件使用自己的 jar 路径
  `/data/local/tmp/macdora-assistant-scrcpy.jar`，每次启用校验摘要后按需推送。
- scid 必须落在 31 位以内（服务器按 `Integer.parseInt(hex)` 解析）。
- 显示会话在套接字连接建立后才创建，宿主需等 guest 抽象套接字出现再转发连接。
- 输入法通道一次只服务一个客户端：插件仅在提交文字时短暂连接，macdora 的运行时会自动重连。

## 工具集（宿主侧代理循环）

`phone_screenshot`、`phone_tap`、`phone_swipe`、`phone_type`、`phone_key`、
`phone_launch_app`、`phone_list_apps`、`phone_wait`、`system_shell`、
`need_user`、`task_done`。坐标归一化为 0-999；每步向模型附当前截图。

## 配置与隔离

- 模型走本机 Magpie 网关 `http://127.0.0.1:3425/v1`。宿主服务读取
  `/v1/models`，只保留同时支持图片输入与工具调用的模型；默认优先路由组
  `auto/gemini-4-argon`，并缓存模型目录 30 秒。
- 模型目录里的 `reasoning_levels` 会同步到工作台。选定思考等级后，请求以
  `reasoning_effort` 发送；模型不支持该等级或没有思考能力时回到默认值。
- 同一插件实例只允许一个执行中的任务，避免多个任务争用同一块后台显示。
- 每轮模型返回的全部工具调用会依次执行，并各自写入匹配的 tool result；空响应和
  非法工具参数会结束为失败。`need_user` 会保持任务并等待工作台回答，取消会中断
  模型等待和后续工具执行。
- 工作台不要求填写地址或密钥。用户只选择模型，选择结果与步数上限保存在
  `private/plugin-state/agent.mika/config.json`（0600），不写入 Android 环境。
- 网关凭据由 Magpie 自己管理；如需独立调用方密钥，可用
  `MACDORA_MAGPIE_API_KEY` 或名为 `macdora`/`mika` 的 Magpie caller key，默认本机
  回环调用不带密钥。
- 插件不安装 APK、不开启无障碍服务；guest 侧只保留一次性的后台显示会话。
- `phone_key` 只接受 BACK / HOME / ENTER / APP_SWITCH / DEL；文字经 shell 参数引用后
  交给 `input text`。`system_shell` 是唯一保留的任意命令工具。
- `provision.sh` 会清理早期 APK 引擎的遗留（恢复其写入的无障碍设置、卸载应用），
  随后关闭无线调试和 ADB TLS 广播（系统通道走宿主既有 adb 链路）；任一必需步骤
  失败时宿主服务进入 degraded，不再报告 ready。
- 无线调试状态文件会先归还 shell 所有权；`persist.adb.tls_server.enable` 通过
  `su 0` 读写，避免旧版 root 归属状态文件或 shell 属性权限导致清理失效。
- 停用/删除插件执行 `uninstall.sh`：释放后台显示、移除显示组件，并恢复启用前的
  无线调试开关和 ADB TLS 广播设置。

## 已知边界

- 模型必须支持图片输入（每步截图）。
- 登录、验证码、支付交回用户（`need_user`）。
- 目标 App 若使用自绘界面且截图无法辨认，需要模型具备视觉能力或补充更明确的指令。

## 历史资料

- 早期 APK 引擎方案与检测面分析参考自上游
  [wangzan101/mika v0.1.33](https://github.com/wangzan101/mika)（Apache-2.0，仅作参考，
  不再参与构建或运行）。微信使用知识卡来自该项目的 knowledge 数据，已随插件归档。
