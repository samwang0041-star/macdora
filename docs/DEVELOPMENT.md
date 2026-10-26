# 开发与构建

当前目标为 Apple Silicon / macOS 15+。宿主代码使用 Swift 和 AppKit，输入辅助组件使用 Java，图形与摄像头适配按各自目录构建。

## 工具

需要完整 Xcode、Python 3.12+、JDK 21 和 CMake。JDK 可通过 `JAVA_HOME` 指定；脚本也识别 Homebrew 的 OpenJDK 21 默认位置。

## 构建

```sh
git clone https://github.com/samwang0041-star/macdora.git
cd macdora
swift test
ANDROID_USE_SIGN_IDENTITY=- bash scripts/build-macos.sh
```

输出位于 `artifacts/Macdora.app`。上面的 `-` 只用于本地 ad-hoc 签名，使用 `--timestamp=none`，产物只能用于开发，发布脚本会拒绝它。正式包省略 `ANDROID_USE_SIGN_IDENTITY`，或传入本机唯一的 Developer ID Application 身份；脚本会从最内层 Mach-O 开始签名，最后签 app，并对所有 Mach-O 使用 hardened runtime 和安全时间戳。不要把证书名称、Team ID 或私钥写入仓库。

构建脚本从固定官方地址取得 scrcpy 与 Android SDK 构建输入，校验 SHA-256 后存入忽略的 `.cache/`。MoltenVK 及相关源码在 `.build/` 内独立编译，上游来源、输入补丁与许可证随仓库提供。构建不依赖另一款已安装的 Android 运行产品。

默认只打应用本体和小型组件。运行时所需的 Android 镜像、模拟器与 ADB 由客户端首次按需下载；只为离线开发准备完整包时使用 `MACDORA_BUNDLE_RUNTIME=1`，该全量包不用于正式 Release。

正式构建会移除分发主程序的调试符号；开发目录图标回退仅在 Debug 构建启用。摄像头组件使用相对安装标识，安装包不包含维护者的本机构建路径。

## 测试与截图

```sh
swift test
```

真实网络下载和 Android 启动验收通过测试中的显式环境变量单独启用。公开截图使用全新环境或中性演示数据；原始设备日志、私人应用及认证信息不进入仓库。

显示性能使用 `scripts/build-android-probe.sh`、`scripts/build-probe-host.sh` 与
`scripts/gpu-render-benchmark.py` 在独立验收环境测量。保持同一 APK、分辨率、码率和运行环境，
用 `--display 1920x1200/240` 覆盖平板场景，分别传入 `--display-sync on` / `off`
比较宿主显示同步。报告记录实际同步开关、颜色渲染路径、唯一呈现帧率、帧间隔和输入到画面响应延迟；
静态页面的低刷新率不能代替滚动或动画场景的帧率。颜色路径的优化必须通过 Metal 与 Core Image 的像素对照，
未支持的视频元数据继续走色彩管理回退。

跨应用数据保留验收使用 `python3 scripts/build-persistence-probes.py` 构建两份独立应用，输出在
`.build/android-persistence-probes/a/` 和 `b/`。只在独立验收环境安装并各点击一次“创建中性测试数据”，
随后检查重开、应用切换、布局切换、原位更新与冷启动。探针分别验证文件、SQLite、偏好设置、Android Keystore 解密和
Android ID 稳定性；检查不会自动重建数据，导出报告仅包含测试结果、包名、UID 与检查时间，不包含密钥或设备标识原文。
底层兼容设备固定为同一平板身份，默认横屏。横屏与竖屏只交换平板显示尺寸的宽高，保持相同密度和 800dp 最小逻辑宽度；旧偏好键 `tabletMode` 继续保留，不能再用于选择硬件身份。
宿主默认关闭额外的显示同步，并用最小 8.33 毫秒呈现间隔限制突发提交；Android 采集仍为 60 FPS。
`ANDROID_USE_DISPLAY_SYNC=1` 可恢复同步，`ANDROID_USE_PACED_PRESENTATION=0` 可关闭节奏控制作对照。
单独关闭同步可能增大帧间隔波动，因此验收必须同时检查帧间隔与输入延迟。
性能采样时保持测试窗口在前台；失去激活状态后，系统可能返回无效的 drawable 呈现时间，
应结合 `windowStateEvents` 判定测试条件，保留失败报告，不能用不完整采样推算稳定帧率。
可用 `--connection-delay 10` 先准备窗口焦点，完整 32 秒测量从连接后开始，门槛与输入次数不变。

默认 Dock 入口随当前前台 Android 应用显示其图标，点击可恢复最小化的窗口，
右键菜单显示当前应用名称，并提供返回该应用和打开 Macdora 的入口。当前产品只有一个前台应用窗口，
该选项不创建额外运行环境或独立应用进程。退出后可用
`open -a Macdora --args --dock-icon macdora` 保留 Macdora 品牌图标；
`--dock-icon app` 为默认方式。关闭当前应用会话或停止环境后恢复 Macdora 图标。

## 更新与发布

版本以根目录 `VERSION` 为准。客户端读取 `samwang0041-star/macdora` 的公开 GitHub Releases，匿名检查版本并下载 ZIP 和 SHA-256 清单，不需要 GitHub Key。

```sh
# 正式签名构建（需要 Developer ID Application 身份）
MACDORA_BUILD_NUMBER=4 bash scripts/build-macos.sh

# 先用本机 notarytool Keychain profile 提交、等待、staple，并生成验收日志
MACDORA_NOTARY_PROFILE='<keychain-profile>' bash scripts/notarize-macos.sh

# 仅获得明确发布授权后；发布门直接验证 Stapled 票据和 Gatekeeper
MACDORA_CONFIRM_RELEASE=1 bash scripts/release-github.sh --publish
```

`notarize-macos.sh` 只从环境变量读取 `MACDORA_NOTARY_PROFILE`，不保存 Apple ID、密码或 profile 名称。它先验证所有 Mach-O 的 Developer ID 证书、Team、安全时间戳和 hardened runtime，再用 `ditto` 创建提交 ZIP；`notarytool submit --output-format json` 只调用一次，超时后使用返回的 submission UUID 查询，不重复提交。只有状态为 `Accepted` 才允许 `stapler`，然后在 app 内钉附票据、重新创建分发 ZIP。JSON、日志和 ZIP 都写入被忽略的 `artifacts/notarization/`。

`submit` 返回 UUID 后，若在时限内尚未完成，脚本会保留 UUID 和 JSON 并退出。保持原构建不变，通过同一个 UUID 继续查询和完成钉附，避免重复上传：

```sh
MACDORA_NOTARY_PROFILE='<keychain-profile>' bash scripts/notarize-macos.sh --resume '<submission-uuid>'
```

发布脚本在任何 GitHub 写操作之前会再次验证 Developer ID、Team、安全时间戳、hardened runtime、嵌套签名、签名后更新过的 RuntimeSeed 哈希、已钉附票据、Gatekeeper 和 `syspolicy_check distribution`。正式发布还要求 `MACDORA_CONFIRM_RELEASE=1` 和固定公开仓库 `samwang0041-star/macdora`。本地同名 ZIP 会通过临时文件原子替换，便于先 package 再 publish；已存在的 GitHub Release 会被拒绝，请升版本，不要覆盖已发布资产。未公证的开发包可以本地打包，但 `--publish` 会拒绝。

`runtime-manifest.json` 在签名完成后记录分发副本的 `cameraSyncHelperSHA256`。MoltenVK 的 `graphicsDriver.librarySHA256` 继续保留源码构建 provenance，`graphicsDriver.distributionLibrarySHA256` 单独记录签名后分发副本，二者不能混用。

发布者通过本机 `gh` 的凭据或 CI secrets 认证。凭据不会进入应用包或源码。源码和 Release 位于同一公开仓库；客户端与发布端的认证需求分别处理。发布说明只会在上述公证和 Gatekeeper 门通过后声明“已完成 Apple 公证”。

## 插件

内置定位插件的源码、可复现构建说明与签名包位于 [plugins/](../plugins/README.md)。客户端从同一公开仓库读取插件清单并验证固定的 Ed25519 发布者公钥；私钥只保存在维护者本地或 CI secrets。插件构建还需要支持 Ed25519 的 OpenSSL 3。

## 目录

- `Sources/AndroidUse/`：原生界面、运行环境、输入显示、插件与更新。
- `Guest/`：输入辅助组件与摄像头适配。
- `Tests/`：宿主、原生界面和 Android 探针测试。
- `Vendor/`：固定上游版本、补丁与许可证。
- `scripts/`：构建、校验与发布工具。

内部标识中的 `AndroidUse` 是早期实现沿用的名称。产品名称为 Macdora。
