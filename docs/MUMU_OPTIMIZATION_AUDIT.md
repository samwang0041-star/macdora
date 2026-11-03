# MuMuPlayer 环境优化审计

审计对象为本机 `MuMuPlayer.app` 的 Android 12 实例及其 guest vendor 层。证据来自
`init.comm.rc`、`nemu_sys_opt`、`nemuinit`、`setting/vm.json`、host 渲染器字符串、
`dumpsys display` 和实际冷启动。文中设备身份均为 Macdora 的合成 profile，不包含
账号或网络凭据。

## 已移植到 Macdora 的机制

| MuMu 机制 | MuMu 证据 | Macdora 实现 |
| --- | --- | --- |
| 后台 App Nap 抑制 | `NemuxAppNap`、`settingAppEnergyCheckInfo`：后台运行时不进入 App Nap | 窗口全部隐藏时持有 `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`，恢复显示或退出时释放 |
| 后台动态帧率 | `dynamicFpsEnable`、`dynamicFpsLimitToLow=15`、`fpsLimitLowList` | `ContainerPreferences.effectiveTargetFPS` 在渲染通道隐藏时降到 15 FPS；重新显示恢复偏好帧率 |
| 后台虚拟显示休眠 | host renderer 的 `fps_limit_low` 与后台降帧 | 连续隐藏 3 秒后向该窗口的 scrcpy 虚拟显示发送 `SET_DISPLAY_POWER(false)`，恢复时 `true`；使用 `/system/bin/cmd display power-off/power-reset <id>`，不影响其他窗口 |
| GPU fast math | `gpuFastMathEnable=true` | emulator 环境变量 `MVK_CONFIG_FAST_MATH_ENABLED=1` |
| 前台应用调度级 | host 日志 `set_performance have 6 performance cpu`；MuMu 主进程与关键线程 `PRI=46–47` | 通过 `/usr/sbin/taskpolicy -a /usr/bin/env` 启动 emulator；`env` 保留 `DYLD_INSERT_LIBRARIES` 相机同步注入；实测 qemu 进程 `PRI=46`，相机同步库正常加载 |
| 磁盘回收 | `cleanDisk` | 管理台清理入口执行 `pm trim-caches` 与 `sm fstrim`，保留应用数据 |
| 多机型身份 | `phonePropBrand/Model/Miit`；实测 Xiaomi `2308CPXD0C` | `GuestDeviceProfile` 提供三星折叠屏与小米折叠屏两套身份；profile 自带稳定序列号；环境停止时可切换，启动时重写 early-boot identity hook |
| 系统级 ANGLE/Vulkan | guest GLES 报告 `Qualcomm / Adreno (TM) 740`；host 使用 MoltenVK | 默认启用 `GuestAngle`；early-boot hook 在 SurfaceFlinger 和 zygote 前切换 `ro.hardware.egl=angle`；系统合成器实测为 `SkiaVk Backend (Ganesh)`，应用 `Pipeline=Skia (Vulkan)`；没有 ANGLE 库时回退 qcom EGL/GLES/Vulkan 别名 |
| 持久着色器缓存 | host `gles_blob_cache_v3.db`：13,553 条、约 88.5 MB | early-boot hook 在图形服务启动前设置 `debug.egl.blobcache.multifile=true` 和 128 MB 上限；guest 创建 `com.android.opengl.shaders_cache.multifile`，跨进程复用 ANGLE pipeline cache |
| 高性能主机预算 | `vmCpuCount=6`、`vmMemoryOfMB=12288`；32 GB 主机档为 12 GB；CPU preset 在高档主机使用 6 核 | `HostPerformanceProfile` 按物理内存与性能核数在启动参数中设置 guest RAM/CPU：32 GB+ 使用 12 GB，24–31 GB 使用 9 GB，10–23 GB 使用 6 GB；CPU 核数跟随性能核拓扑，16 GB / 6 性能核的 Pro 机器使用 6 核，低配 base 芯片仍为 4 核；不重写 AVD，不清空 guest 数据 |
| 高刷新率 | `supportedModes` 120 Hz、`maxFpsLimit=120` | 32 GB+ 且至少 6 个性能核的 Mac 使用 `-vsync-rate 120`，其余回到 60；UI 提供 30/45/60/90/120，guest `peak_refresh_rate` 跟随主机 profile，实际帧率由应用和宿主链路选择 |
| Release/Build 属性一致性 | Xiaomi 实例：`ro.build.type=user`、`ro.build.tags=release-keys`、`ro.product.first_api_level=32`、`ro.board.platform=Xiaomi`；Zygote 日志有 `fakeProductInfoIfNeed` | 机型身份脚本同时写入 `user`/`release-keys`、first API、SoC platform、`ro.build.product/id/flavor/description/display.id`；同步 `Settings.Global.DEVICE_NAME` 和蓝牙名；应用启动时把 `ro.kernel.qemu`/`ro.boot.qemu` 置空，并把 `ro.hardware`/`ro.boot.hardware` 收为 `qcom`；`ro.debuggable` 保留 1，避免关闭 Macdora 的 `adb root` 管理通道 |
| 显示密度 | Xiaomi 实例：`wm density=360`、`ro.sf.lcd_density=360`、无 display cutout | profile 的真实密度同时写入 boot 属性和 scrcpy 虚拟显示：三星 240、小米 360；应用窗口实测 `new_display=…/240`、`…/360` |
| host 音频 | 实例支持扬声器/麦克风通路；`vibration*` 配置独立 | 启动参数改为 CoreAudio 后端并允许 host audio input；guest 实测有 48 kHz 输出线程和 speaker 设备，真实播放/录音仍需验收 |

## 未移植的 MuMu 内核能力

MuMu 的 guest 内核暴露 `pagecache_limit_policy=elastic` 和 `pagecache_limit_mb=800`，
并通过 `nemu_sys_opt` 把 `kpclimitd` 放入 15% CPU 的 cgroup。这些能力依赖 MuMu 自带
内核和 `kpclimitd`，AOSP/Stock 内核没有对应接口；Macdora 不伪造这些文件，也不把
普通应用放入限速 cgroup。

MuMu 使用 12 GB RAM + 8 GB swap；Macdora 的高配 profile 将 guest RAM 提升到 12 GB，
保留现有 zram 配置，避免同时改写用户数据分区和 swap 布局。

## 实测

- Apple M5 Max / 128 GB：guest `MemTotal` 为 `12230548 kB`，可见 6 个 CPU；emulator
  启动参数包含 `-memory 12288 -cores 6`，启动和网络就绪正常。
- 多轮冷启动后 `ro.product.model`、`android_id`、`ro.serialno` 保持一致，微信
  `.auth_cache`、`autoauth.cfg` 和认证偏好文件保留；框架没有清理应用数据。账号是否
  仍有效由微信服务端决定。
- 身份脚本 v9 冷启动实测：三星 `SM-F926U` 为
  `first_api=30 / board=lahaina / type=user / tags=release-keys`；小米
  `2308CPXD0C` 为 `first_api=32 / board=kalama / density=360 / nosdcard`。
  两套 profile 都能在 early-boot 阶段完成，`androiduse.device_identity_ok=1`；
  `ro.debuggable` 保持 1，`adb root` 仍可用。
- 身份脚本 v9 冷启动实测：`ro.build.product=SM-F926U`、
  `ro.build.id=V417IR`、`ro.build.flavor=SM-F926U-user`，Settings 的
  `DEVICE_NAME`/蓝牙名同步为 `SM-F926U`；虚拟显示截图中的设备摘要不再显示
  `Android SDK built for arm64`。
- v9 身份命名空间实测：`ro.build`、`ro.system.build`、`ro.product.build`、
  `ro.system_ext.build`、`ro.vendor.build`、`ro.vendor_dlkm.build`、
  `ro.system_dlkm.build`、`ro.odm.build` 的 fingerprint 全部为同一三星 profile；
  `ro.product.system_dlkm.model=SM-F926U`，`ro.boot.hardware.vulkan=qcom`，
  `ro.soc.manufacturer=Qualcomm`、`ro.soc.model=SM8350`；运营商为
  `CHINA MOBILE / 46000 / China Mobile GSM / 460000`。运营商来自持久化的
  modem simulator SIM profile，而不是仅靠启动后覆盖属性；第二次冷启动后保持
  `46000 / 460000`，序列号和 Android ID 未变化。
- 序列号实测：三星 profile 下 `ro.serialno` 与 `ro.boot.serialno` 保持同一固定值，
  Android ID 仍为原来的稳定值；没有清理应用数据。
- 虚拟显示控制：`ON → OFF → ON`；Settings 任务仍在，scrcpy server 不退出。
- 刷新率实测：guest `supportedRefreshRates=[120,60,40,30,24,20]`，scrcpy
  `max_fps=120`，`peak_refresh_rate=120`；Settings 当前内容仍选择 60 Hz，属于
  应用帧率选择而非显示能力缺失。
- MuMu Xiaomi 冷启动实测：`wm size=1440x2560`、`wm density=360`、`DisplayCutout` 为空；
  guest 身份为 `ro.build.type=user`、`ro.build.tags=release-keys`、`ro.debuggable=0`。
- Macdora 音频实测：QEMU 已使用 `-audio coreaudio -allow-host-audio`；guest
  `media.audio_flinger` 有 48 kHz 输出线程，`media.audio_policy` 有内置麦克风端口；
  实际扬声器播放和录音仍需真实应用与 macOS 权限验收。
- QEMU 标记热替换实测：置空 `ro.kernel.qemu`/`ro.boot.qemu` 后新启动的 Settings
  仍正常渲染；冷启动由 recovery script 在应用启动前再置空。
- 硬件属性热替换实测：`ro.hardware`/`ro.boot.hardware=qcom` 后新启动的 Settings
  仍正常渲染，虚拟显示 240 DPI 不变；没有 ANGLE 库时 qcom EGL/GLES/Vulkan 别名可
  回退到 emulator/Vulkan 实现。
- ANGLE 实测：默认路径下 SurfaceFlinger 使用 SkiaVk，Settings 和微信登录页均正常，
  日志报告 `ANGLE Renderer (Vulkan 1.3.0 (Virtio-GPU GFXStream (Apple M5 Max)))`。
- Mika 后台观察器：从 20 FPS 改为按需创建、默认 10 FPS、空闲 5 分钟释放；停止观察器
  后 host qemu 的短时 CPU 采样由约 47% 降到约 17%（采样有波动，仅作方向性证据）。
- `swift test --skip ApplicationWindowTests`：179 个 XCTest 通过（3 个按设计跳过），
  129 个 Swift Testing 通过。完整 `swift test` 另执行 19 个窗口测试，其中 15 个通过；
  锁屏会话中 4 个依赖 `NSApp.isActive` 的断言无法完成前台激活，解锁后需复跑。
- 启动调度实测：默认启动后 qemu 进程 `PRI=46`（改动前 `PRI=31`），
  `libmaccamera_frame_sync.dylib` 仍由 qemu 加载；`ps -M` 中主线程同样为 46，子线程
  由 QEMU 自己创建，保留默认调度级。
- 系统图形路径实测：SurfaceFlinger 日志为 `Threaded RenderEngine with SkiaVk Backend
  (Ganesh)`；Settings `dumpsys gfxinfo` 为 `Pipeline=Skia (Vulkan)`；ANGLE 报告
  `Renderer (Vulkan 1.3.0 (Virtio-GPU GFXStream (Apple M5 Max)))`。设置页冷启动后
  连续三次固定滚动采样：60–61 帧、每次 1 帧 jank（1.64%–1.67%），CPU 50th/90th
  为 5/8 ms，GPU 50th/90th 均为 1 ms。
- 早启动着色器缓存实测：identity hook 版本 9 在 `post-fs` 完成后再启动 zygote；
  新 boot 的 system_server 不再打印 `EGL blobcache multifile is not enabled`，
  Settings 已创建 `com.android.opengl.shaders_cache.multifile`。
- Mac 芯片适配不维护营销型号表：`HostPerformanceProfile` 读取实际物理内存与
  `hw.perflevel0.logicalcpu`，M1–M5 的 base/Pro/Max/Ultra 都按同一规则落到
  4/6/8 个 guest 核与 4/6/9/12 GB 预算；16 GB / 6 性能核的 Pro 使用 6 核，
  32 GB+ 且 6 性能核以上才暴露 120 Hz。该规则覆盖本机 M5 Max（6 性能核）
  以及低配 M1 base（4 性能核），不依赖芯片名称。
- 冷启动后 Android ID、`ro.serialno`/`ro.boot.serialno`、`ro.product.model` 与微信
  `.auth_cache`/`autoauth.cfg` 仍保留；服务端登录有效性不在本机可验证范围内。
- 微信冷启动进入 `LoginPasswordUI`，已保留账号输入与密码登录页，`Pipeline=Skia
  (Vulkan)`；未输入凭据。工行办公应用冷启动进入 `MainActivity` 工作台，281 帧中
  12 帧 jank（4.27%），未出现进程崩溃；未执行登录后的业务操作。
- ADB transport 自愈：空实例冷启动曾出现 `emulator-5584` 停在 `offline`，手动
  `adb reconnect offline` 立即恢复；启动等待逻辑已加入同一恢复动作，并覆盖单元测试。

## 边界

- 当前发布物仍是 Apple Silicon / arm64 运行时；Intel Mac 需要独立的 x86_64 镜像与
  emulator 产物，不能靠参数切换。
- 120 Hz 能力由 QEMU `-vsync-rate` 按主机 profile 暴露；具体应用是否使用 120 取决于其
  `preferredDisplayModeId`/内容请求；默认 target FPS 仍为 60。隐藏窗口仍通过显示
  电源关闭降低合成开销，而不是重建显示。
- MuMu 的 Adreno 字符串伪装尚未移植：MuMu 向应用报告
  `Qualcomm / Adreno (TM) 740 / OpenGL ES 3.2 v334 R`。Macdora 的新应用进程可走
  ANGLE/Vulkan 渲染，系统合成器走 Vulkan Ganesh；当前不伪造 Adreno/Qualcomm
  GL renderer 字符串。
- MuMu 的“高画质适配”是按包下载的 DLC 叠加层，`.dlc-config` 加密且当前实例未下载
  对应游戏资源；没有可复用的通用适配数据，Macdora 不伪造该能力。
- MuMu 的机型预设只替换 `phonePropBrand/Model/Miit`；实测切换到 Galaxy S23 Ultra
  后，fingerprint、build id、characteristics、density、board 等仍复用 Xiaomi 实例的
  值。Macdora 的两个 profile 会同时改写八组 fingerprint、board/SoC、构建字段、
  序列号与显示密度，因此没有把 MuMu 的浅层机型列表照搬成更多 profile。
- AOSP Settings 的“关于模拟设备”标题是资源字符串，不随 Build 属性变化；本轮已
  修正其 `SM-F926U` 摘要，未替换 Settings APK。
- Guest ANGLE 已是默认路径，SurfaceFlinger 与 Settings 均走 Vulkan/Ganesh；
  还没有完成与 translator 在游戏、微信、银行应用上的同条件帧率/输入延迟对比，
  极端应用若出现黑屏可通过 `ANDROID_USE_FORCE_GUEST_ANGLE=0` 回到 translator。
- host audio 已启用 CoreAudio 和 host input 通路，但真实扬声器播放、麦克风授权后的录音、振动效果仍需用真实应用验收。
- 真实微信登录态仍由微信服务端和设备风控决定；框架层只保证应用数据与 boot identity
  不被清理。账号登录/退出必须用真实账号单独验收。
- 首次使用摄像头时 macOS 会弹出系统级 TCC 授权；这是操作系统权限边界，Macdora
  不读取或改写 TCC 数据库。授权请求已改为不阻塞应用窗口打开，拒绝后应用仍可使用，
  但摄像头功能需要用户在系统设置中重新授权。
- 8–9 GB 主机现在使用 4 GB guest 预算，避免把宿主压到 swap；该档位未在真实 8 GB
  Apple Silicon 上做长时压力验收。

## 第二轮深挖（MuMu 1.9.13，2026-11-03）

这一轮从运行中的 MuMu 实例、宿主导出字符串和 guest 配置入手，目标不是复制 MuMu
的外观功能，而是找出它如何把“VM 不可见、状态可恢复、不同 App 不互相拖死”拆成
可执行机制。证据来自 `MuMuEmulator` 进程、`vm.json`、guest `/system` 与
`/data/system/etc/mumu-configs`，以及 `mumu` 实例日志。

### 新发现

| 机制 | MuMu 证据 | 与 Macdora 的差异 | 结论 |
| --- | --- | --- | --- |
| 单进程嵌入 QEMU | `MuMuEmulator` 直接加载 `libqemu-aarch64-softmmu.dylib`、`libRenderer.dylib`、MoltenVK；宿主只看到一个仿真进程 | Macdora 另起 Google `qemu-system-aarch64`，再通过 scrcpy 建显示；链路更多但故障边界更清楚 | 不重写成单进程；可学习它把渲染、输入、VM 控制放在同一生命周期内 |
| QMP 控制面 | QEMU 使用 `qmp.pipe.in/out`；字符串包含 `system_powerdown`、`stop`、`quit` 和父进程 watchdog | Macdora 在 `adb shell sync` 后执行 `adb emu kill`，已有落盘保护，但没有 ACPI/QMP 级的分阶段关机 | 优先验证 QMP/ACPI 关机；不要直接替换现有已验证的 `emu kill` 回退 |
| 分层磁盘 | `system.qcow2` 只读，`data.qcow2` 可写，`swap.qcow2` 独立；drive 参数统一 `discard=unmap,detect-zeroes=unmap` | Macdora 使用 Google emulator 的 `system/vendor/userdata/cache` QCOW 层，已有镜像升级和数据保留 | 继续用现有 QCOW 模型；把“读写分层、稀疏丢弃、独立 swap”作为设计约束，不自行重写镜像层 |
| 内存治理 | `nemu_sys_opt` 监视 PSI，写 `cpu.max` / `cgroup.procs`，执行 `compact_memory`，并有 `pagecache_limit_policy=elastic`；guest 有约 8 GB swap，无 zram | Macdora 12 GB profile 无 swap；4 GB profile 实测自动启用 `/dev/block/zram0`，SwapTotal 约 3.0 GB | 低内存档已有 zram 保护；先做 PSI/RSS/Swap 的量化，不要重复手动塞 swap 或 pagecache 限制 |
| guest 服务面 | `nemuinit`、`nemu_sys_opt`、`nemuinput`、`opengl-gc`、`powerbtnd`、`nemu-vapi-android-pack` | Macdora 频繁操作主要走 ADB shell；速度快时受 shell、权限和启动开销限制 | 长期值得做一个小的内部 guest helper；短期先用现有 ADB，避免为了性能复制一整套私有服务 |
| 固定网络身份 | `vm.json` 固定 `macAddress`、ADB/frontend 端口；QEMU 使用固定 MAC 和 hostfwd | Macdora 固定 ADB/emulator 端口，但 guest MAC/部分网络身份未纳入 profile | 将 MAC、ADB 端口、网络身份纳入 runtime profile；先验证 Android API 实际读到的值 |
| 共享目录 | 9p 挂载 `MuMu12Shared`、`global_shared`、`private_shared`，并映射 Download、Camera、Movies、Pictures、Screenshots、Music | Macdora 当前没有宿主-Android 共享目录；APK 仍走 ADB push | 高价值、可先做 ADB 版本（导入/导出 Download 与照片），验证使用频率后再考虑 9p |
| 按 App 渲染适配 | `renderer.config` 对包名配置 `IgnoreGLError`、`CustomizedRendererString`、GLES 扩展、`DoNotUseRDR`、LOD | Macdora 目前只有全局 ANGLE/translator 开关，无法只对某个 App 回退 | 先建立少量真实问题包名的兼容表；不要照搬游戏专用字符串和 OpFlag |
| 按 App 输入/窗口策略 | `vinput.config` 的 fullscreen、inputView、ignore_start_input；`force-orientation-apps.json` | Macdora 已有显示布局和部分 per-package preference，但输入焦点/方向策略没有统一注册表 | 统一成 per-package policy，避免每个功能各写一套判断 |
| 启动与内存预取 | `prefetch.config` 按 APK/OBB 逻辑区间预取；`pre_fetch.json` 按包预热 | Macdora 主要依赖 Android 自己的 page cache | 低优先级；先测冷启动耗时，再决定是否做通用区间预取 |
| 操作录制/手柄映射 | `OperationRecorder`、`shell.recorder.*`、keymap 管理、gamepad 振动/轴映射 | Macdora 面向鼠标键盘与 Agent，未做游戏手柄和录制回放 | 不属于当前产品主线；除非游戏场景成为明确目标 |
| 私有内核/图形层 | `vaddress.ko`、`/dev/vaddress`、`opengl-gc`、`kpclimitd`、`nemuinput` | 依赖 MuMu 定制内核与专有 HAL，AOSP 镜像没有对应接口 | 不伪造、不硬拷贝；只学习其“内存/输入流与图形回收独立治理”的边界 |
| 热更新与兼容配置 | `/data/system/etc/mumu-configs/java_patch`、`file-update.config`、`harden` | Macdora 用 early-boot vendor hook 和应用自身更新；没有通用 guest patch 层 | 不做通用 Java patch；保留现有可验证的 early hook 和原子升级 |

### 应该优先补的三件事

1. **先做共享目录 MVP。** 用户价值最高，且不需要改 QEMU：提供“导入文件到
   Download/相册”和“从 Download/相册导出”，底层先复用现有 ADB push/pull。
   只有确认大量文件、目录挂载和实时可见性确实是瓶颈后，再评估 9p。
2. **做 per-App policy。** 把 renderer fallback、方向和输入策略收进一个按包名索引的
   注册表，避免一个 App 的兼容开关影响整个环境。先用真实出问题的包名和可复现实验，
   不照搬 MuMu 的游戏配置。
3. **做 VM 资源观测，再决定 balloon/swap。** 记录 host RSS、guest PSI、MemAvailable、
   Swap、磁盘 actual-size 和关机耗时；如果低内存主机出现明显 pressure，再验证
   `virtio-balloon` + QMP 的可行性。没有观测数据时不要把 12 GB guest 再叠加大 swap。

#### QMP 实测边界

用只读 AVD、独立端口和 `-qemu -qmp unix:…,server=on,wait=off -device virtio-balloon-pci`
启动 Google emulator 后，QMP 握手成功，`query-status`、`query-balloon`、`balloon`、
`system_powerdown`、`stop`、`quit` 都存在；实测 guest `virtio25` 没有绑定驱动，
`balloon 2 GiB` 返回成功后 `query-balloon.actual` 仍为 `4 GiB`。`system_powerdown`
返回 `POWERDOWN` 事件后 guest 仍保持运行，`adb shell reboot -p` 后 ADB 变为 offline，
QEMU 仍未退出，最终仍需停止 QEMU 进程。guest 内核配置有 `CONFIG_VIRTIO_BALLOON=m`，
但 `/system`、`/vendor`、`/odm`、`/apex` 都没有随镜像提供 `virtio_balloon.ko`，所以
不是只补 QMP 客户端就能生效。结论：QMP 可用于观测和控制，但不能在没有 guest
`virtio_balloon`/ACPI power handler 的情况下替代现在的 `sync + adb emu kill`；
优先做 guest 内核/服务支持，不要把 QMP 当成现成优化。

#### 已落地：共享目录双向 MVP

应用页拖拽区现在接受任意文件：APK 继续走安装流程，其他文件通过 ADB 写入
`/sdcard/Download/Macdora/`，导入后按文件触发 MediaStore 扫描，图片/视频可在相册
中看到；同页“导出…”可把该目录拉回 Mac 选择的文件夹。
两个方向都使用 300 秒传输预算，避免大文件沿用显示组件的 30 秒超时。该版本不依赖
9p，也不改变 QEMU 参数；目录双向挂载、照片/相机目录映射和实时可见性仍属于后续
工作。新增 `RuntimeLifecycleTests.testImportFileCopiesToDownloadFolderWithLongTransferBudget`
和 `testExportDownloadFolderUsesLongTransferBudget` 验证目标路径、传输超时和双向请求。

9p 本身也做了宿主可行性验证：给 Google emulator 追加 `-qemu -virtfs` 后，内置 QEMU
直接返回 `There is no option group 'virtfs'` 和 `virtfs support is disabled`，说明
不是 guest 挂载参数问题，而是当前 emulator 的 QEMU 构建没有编译 virtfs。要获得
MuMu 那种实时目录映射，必须更换/重编 QEMU；在当前产品边界内，ADB 双向迁移是正确
取舍。

### 不应直接复制

- 单进程嵌入 QEMU、私有 `vaddress.ko`/`opengl-gc`/`kpclimitd`：会把 Macdora 绑到
  不可替代的内核和图形二进制，破坏现有镜像升级与故障隔离。
- 游戏专用的 renderer 字符串、OpFlag、DLC、预取区间和录制脚本：属于按游戏逐项维护的
  兼容资产，不是通用运行时优化。
- 计费、遥测、账号风控和商业 License 流程：与运行环境质量无关。

### 验收指标

后续每项改动必须同时记录：冷启动到 `sys.boot_completed` 的时间、首页可交互时间、
host qemu RSS/峰值、guest PSI 和 swap、显示帧时间/jank、共享文件传输耗时、停止时
qcow2 写入是否完整，以及失败后能否从原有镜像和数据恢复。没有这组前后数据，不把
“更接近 MuMu”当成优化完成。
