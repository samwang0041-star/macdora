# 办公实例保持唤醒

设置入口：管理台 → 偏好设置 → 交互与权限 →「办公实例保持唤醒」。默认关闭。

## 范围与状态

Macdora 当前没有独立的办公账号或办公配置档模型。用户在某个环境中显式开启该选项，即把**当前环境目录**指定为需要后台唤醒的办公环境；设置和恢复记录按规范化、解析符号链接后的目录散列保存，不复用全局 `ContainerPreferences`。其他目录不会继承该选项。

Android 的缓存进程冻结开关作用于该 Android 环境的所有进程，包括其 WebView 子进程；这不是单一应用的白名单。同一环境里的其他应用也可能增加后台活动。需要只覆盖办公应用时，应将其放在独立环境目录中。

未启动时只保存选择，不启动环境。界面区分「已保存，启动后应用」「正在应用」「已应用」和「未能确认」。仅保存开关或仅写入 Android 设置，均不等于生效。开关展示保存的选择；失败时单独的「重试」按钮重试原来的开启或恢复操作，也可用开关改变选择。

## 冻结机制与实现

现有「后台常驻」只控制实际关闭应用窗口后是否停止 Macdora 自己拥有的虚拟机。`ApplicationWindow.windowShouldClose` 的普通关闭动作会先最小化并回到管理台；显式关闭才进入 `ProductAppDelegate.closedApplicationWindow` 的资源关闭路径。最小化不会向 guest 发出冻结/停网命令，`AndroidSurfaceView` 只跳过不可见画面的呈现。Macdora 源码没有对办公应用执行 `SIGSTOP` 或缓存进程冻结的现有逻辑。

真正的 Android 缓存进程冻结由系统 ActivityManager / OomAdjuster 根据进程重要性触发：应用不可见、进入 cached 状态后，CachedAppOptimizer 延迟冻结线程与 Binder。切回可交互状态通常由系统解冻。它用于减少缓存应用的 CPU 和电量消耗；缓存进程仍占用内存，冻结不等于退出。Android 14 及以后，冻结 UID 还可能导致已有 TCP 连接被清理。

现有 `RuntimeSoftwareDefaults.guestSetupScript` 已禁用 Doze 和后台流量限制，但这两项不能替代缓存进程冻结控制。macOS App Nap、Android Doze、cached-process freezer、应用自己的后台策略、WebView 页面可见性与计时器节流是不同机制。

开启时：

1. 只通过 `RuntimeController` 已拥有且仍存活的 ADB 与模拟器句柄执行操作；检查运行代次，禁止借用其他实例。
2. 首次变更前保存原 `cached_apps_freezer` 值及实际 `use_freezer` 状态。只接受已知枚举值和严格的状态输出；恢复记录不包含账号、应用数据或凭据。
3. 设置当前 guest 的 `cached_apps_freezer=disabled`，等待系统实际报告 `use_freezer=false`。
4. 经严格名称校验，对系统进程记录尝试 `am unfreeze`，处理旧冻结或待冻结记录。进程名称和系统 dump 留在 guest 临时 shell 内存中，不返回主机日志。
5. 只有实际报告 `use_freezer=false`、`Apps frozen: 0`，且进程 dump 明确提供 `isPendingFreeze` 字段并不存在待冻结记录时，才显示「已应用」。部分 Android 版本无法用 `am unfreeze` 命中带冒号的子进程，或不提供该命令/字段；残留冻结、待冻结或无法识别时均报失败并尝试恢复原策略，不自动重启或切前台。
6. 生效后用 `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` 避免宿主 App Nap；允许 Mac 自身闲置睡眠，不改变系统睡眠或显示器设置。关闭应用窗口时，生效意图与原「后台常驻」取 OR，保留该环境，但仍关闭原显示流与解码资源。

启动时在既有 guest 环境准备完成后、插件 ready 回调之前应用。身份、认证、平板行为和应用数据准备流程保持原契约。某些已有或自动启动的子进程可能已冻结，因此启动时也以实际验证结果为准。

关闭选项或停止环境时，先恢复原 guest 设置，再停止拥有的模拟器和 ADB；宿主 App Nap 活动在关闭、停止、异常退出或失败时释放。停止先取消并等待未完成的设置操作，禁止陈旧操作在停止后重新施加策略。开关选择保留到下次启动。

恢复采用比较后写回：当前设置仍是本功能写入的 `disabled` 时才恢复原值（原值不存在则删除）；若其他操作者已改成不同值，则保留其新值。若其他操作者也写入同一个 `disabled` 值，无法区分这两次写入。恢复要核对设置和实际状态；失败保留恢复记录，下次拥有环境启动时重试。宿主崩溃后同样依靠该记录恢复。恢复记录损坏时不覆盖未知原值，也不假报成功。

## 能耗、内存及服务器可见性

- 缓存应用和虚拟机可继续执行，CPU、网络、发热及电池消耗可能增加；尚无真实功耗数据，不提供虚构估算。
- 保留环境会延长模拟器、应用与 WebView 的内存驻留；不会给虚拟机新增内存配额，也不保证避免 Android 的内存压力回收或应用崩溃。
- 应用自己的后台同步、心跳、重连和在线状态可能继续。服务器通常仍按既有登录会话归属到用户本人；对方看到的在线状态取决于应用协议。本选项不创建独立自动化身份，也不隐匿访问。
- 本功能不操作邮箱/聊天接口、不模拟焦点、不导航页面。但解除冻结后，应用本身可以恢复既有后台逻辑；不能据此保证应用自己的同步或回执完全没有服务器写入。
- 实际关闭应用窗口仍释放原显示流与解码资源；最小化保留既有不可见画面呈现策略，不额外安排隐藏画面刷新任务。Mac 睡眠、断网、登录过期、WebView 销毁/暂停、应用服务端策略仍可能使插件读取失败。防冻结不等于邮件读取端到端成功。

## 本轮验证边界与下一步

本轮只运行隔离测试与合成 AppKit 界面截图；不连接正在运行的办公环境，不读取真实邮件/聊天，不访问私有插件目录或凭据，不安装、不重启、不合并、不推送。

既有只读尝试返回 `MAIL_NETWORK_ERROR`，缺少错误发生时的冻结状态、待冻结队列、连接及服务端证据，不能认定是冻结导致网络停止。冻结机制与网络失败存在合理关联，但这不是该次故障的已证实根因。

下一阶段需用户决定是否接受资源与在线活动增加，并另行授权安装到指定办公环境及启用。真实验收应分别覆盖前台、最小化、切后台和关闭显示窗口，先核对冻结/待冻结状态与网络，再在独立授权下检查插件读取；继续遵守 `markRead=false`、读取前后服务器 flags 一致、无发送/回执/附件、聊天接口无法保证无已读上报则不读等原验收条件。无法保证后台 WebView 可用时，应明确失败原因，再决定是否需要应用/插件层支持，不能通过模拟焦点绕过。

## 机制依据

- [AOSP 缓存应用冻结说明](https://source.android.com/docs/core/perf/cached-apps-freezer)
- [CachedAppOptimizer：设置观察、冻结与解冻实现（固定提交）](https://android.googlesource.com/platform/frameworks/base/+/7bc94f50131093a1e2eb58a10b260ca72b17466a/services/core/java/com/android/server/am/CachedAppOptimizer.java)
- [ActivityManagerShellCommand：unfreeze 的进程查找限制（固定提交）](https://android.googlesource.com/platform/frameworks/base/+/6122f0ed1ec662067d83f0bf2b2ab6ac299ab63a/services/core/java/com/android/server/am/ActivityManagerShellCommand.java)
- [ProcessCachedOptimizerRecord：待冻结状态输出（固定提交）](https://android.googlesource.com/platform/frameworks/base/+/7bc94f50131093a1e2eb58a10b260ca72b17466a/services/core/java/com/android/server/am/ProcessCachedOptimizerRecord.java)
- [Apple ProcessInfo 活动选项](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/userinitiatedallowingidlesystemsleep)
