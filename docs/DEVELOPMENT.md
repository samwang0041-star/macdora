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

输出位于 `artifacts/Macdora.app`。上面的 `-` 只用于本地 ad-hoc 签名；正式发布包使用维护者自己的 Developer ID 身份。

构建脚本从固定官方地址取得 scrcpy 与 Android SDK 构建输入，校验 SHA-256 后存入忽略的 `.cache/`。MoltenVK 及相关源码在 `.build/` 内独立编译，上游来源、输入补丁与许可证随仓库提供。构建不依赖另一款已安装的 Android 运行产品。

默认只打应用本体和小型组件。运行时所需的 Android 镜像、模拟器与 ADB 由客户端首次按需下载；只为离线开发准备完整包时使用 `MACDORA_BUNDLE_RUNTIME=1`，该全量包不用于正式 Release。

## 测试与截图

```sh
swift test
```

真实网络下载和 Android 启动验收通过测试中的显式环境变量单独启用。公开截图使用全新环境或中性演示数据；原始设备日志、私人应用及认证信息不进入仓库。

## 更新与发布

版本以根目录 `VERSION` 为准。客户端读取 `samwang0041-star/macdora` 的公开 GitHub Releases，匿名检查版本并下载 ZIP 和 SHA-256 清单，不需要 GitHub Key。

```sh
bash scripts/build-macos.sh
bash scripts/release-github.sh
# 在获得明确发布授权、完成测试与签名验证之后：
MACDORA_CONFIRM_RELEASE=1 bash scripts/release-github.sh --publish
```

发布者通过本机 `gh` 的凭据或 CI secrets 认证。凭据不会进入应用包或源码。源码和 Release 位于同一公开仓库；客户端与发布端的认证需求分别处理。

## 插件

内置定位插件的源码、可复现构建说明与签名包位于 [plugins/](../plugins/README.md)。客户端从同一公开仓库读取插件清单并验证固定的 Ed25519 发布者公钥；私钥只保存在维护者本地或 CI secrets。插件构建还需要支持 Ed25519 的 OpenSSL 3。

## 目录

- `Sources/AndroidUse/`：原生界面、运行环境、输入显示、插件与更新。
- `Guest/`：输入辅助组件与摄像头适配。
- `Tests/`：宿主、原生界面和 Android 探针测试。
- `Vendor/`：固定上游版本、补丁与许可证。
- `scripts/`：构建、校验与发布工具。

内部标识中的 `AndroidUse` 是早期实现沿用的名称。产品名称为 Macdora。
