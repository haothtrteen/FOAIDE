# THIRD-PARTY NOTICES

本文件列出随本应用分发/使用的第三方组件及许可证（合规流程见 dev-handbook/05-许可证合规.md）。

| 组件 | 版本 | 许可证 | 分发方式 | 源码获取 |
|---|---|---|---|---|
| proot（Termux 分支构建） | 按 Release 附注 | GPL-2.0 | APK 内嵌二进制（`jniLibs/libproot.so` 或 `assets/tools/proot-arm64`） | https://github.com/termux/proot |
| Debian rootfs (minbase) | bookworm | 各软件包自有自由许可证（DFSG） | APK 内嵌 tarball，首次运行解压 | https://www.debian.org/distrib/ |

## Java / Kotlin 依赖

**当前：无。**（2026-09-17 起）

这里曾经挂过一整套「无线调试 / ADB」依赖（Kadb + spake2-java + okio + coroutines…），
其中 **spake2-java 是 GPL-3.0 且会被 dex 进 App 进程**——它是本项目闭源商业化的
**唯一真阻塞点**。随着 AVF 路线因设备不支持而暂停、原生 arm64 路线不再需要 adb，
整块已移除（`AdbWireless.kt` / `adb_bridge.dart` / `adb_page.dart` / `vendor_kadb.sh`
全部删除，`build.gradle.kts` 的 dependencies 块清空）。

⚠️ 教训留在 `dev-handbook/05-许可证合规.md`：引入 AAR/JAR 前必须跑「闭源检查清单」，
只要出现 GPL/LGPL/AGPL 的**进程内链接**依赖就一票否决。独立子进程（proot 里的
可执行程序）不在此列——那是「发行义务」而非「传染」。

## 构建期原生工具（不进 App 进程）

这些组件**只在 proot 容器内的构建流程中被下载和执行**，既不被 dex 进 APK，
也不与本项目代码链接，因此对闭源分发没有传染性——但仍需如实登记。

| 组件 | 版本 | 许可证 | 使用方式 | 源码获取 |
|---|---|---|---|---|
| Commit451/android-arm-build-tools | platform-tools-36.0.0（AOSP `platform-tools-36.0.0`） | **MIT** | 运行时下载 tar.xz（3.2MB）→ 解出 `aapt2`/`aidl`/`zipalign`/`split-select` 覆盖进 Android SDK | https://github.com/Commit451/android-arm-build-tools |
| gen_snapshot（arm64 移植版） | 用户自备 | Flutter SDK 为 **BSD-3-Clause**（另有少量组件见上游 licenses） | **不自动下载**：由用户本地导入，落位到 `/opt/foa-native/gen_snapshot` | 例：https://github.com/ImL1s/termux-flutter-wsl |
| **cloudflared**（远程接管隧道，alpha.60 起） | 2026.9.1 | **Apache-2.0** | 用户在「远程接管」页点安装时下载 `cloudflared-linux-arm64`（37,466,252 字节）→ 落位容器 `/opt/foa-bin/cloudflared`（宿主无 chmod，靠容器内补 755）→ 以 `tunnel --url http://127.0.0.1:8977 --protocol http2 --no-autoupdate` 启动 | https://github.com/cloudflare/cloudflared |

说明：

- **cloudflared 必须取 arm64 资产**（`cloudflared-linux-arm64`）。rootfs 是
  aarch64（`debian-minbase-arm64.tar.gz`）；若误取 amd64 版，它只能在容器里
  靠 QEMU 指令翻译运行，又慢又脆（曾用的 `/tmp/cfd_amd64.deb` 就是这条路）。
- Apache-2.0 允许闭源使用，**不随 APK 分发**、不进 App 进程（容器内独立进程
  execve），因此无传染性；按其 §4 要求在此登记并保留上游许可与 NOTICE；

- **Commit451 的产物是 MIT**，可自由用于闭源场景；下载后会做 SHA-256 校验
  （值取自 GitHub API 的 asset digest），因此即便走第三方加速代理也只能让它
  "下载失败"，无法注入错误内容；
- 两个组件都是**在容器内 execve 的独立进程**（与 proot 同性质），不是库调用，
  不构成与本项目代码的链接；GPL 的传染争议点在于"链接进同一进程"，这里不存在；
- 上游 Commit451 的产物构建于 Debian 12（glibc 2.36 / GCC 12），
  要求运行环境 glibc 2.36+ 与 GLIBCXX_3.4.30+——本项目 rootfs 正是 Debian 12 bookworm，
  满足；minbase 缺省没有 `libstdc++6`，落位流程会自动 apt 补上。

## 可选启用（不代分发）

| 组件 | 版本 | 许可证 | 状态 | 来源 |
|---|---|---|---|---|
| proroot（proot 的闭源替代，容器层加速） | v1.2.5 | **Proprietary**：_"Proprietary. Free to use in your projects. Redistribution of modified binaries is not permitted."_ | **不再随包**（alpha.69 起，见下）：五件套 `.so` 已从 APK 移除，「一键下载」入口同时下架。仅保留「从本地导入」——用户自行取得合法副本后落位到 `filesDir`；默认关闭 | https://github.com/coderredlab/proroot |

> **版本号订正（alpha.69）**：此处此前写 `v1.2.8`，与代码里实际钉死的
> `ProrootOption.pinnedVersion = 'v1.2.5'` 不符（`soAssets` 的五条
> sha256 也是按 v1.2.5 的产物算的）。以代码为准 —— 现已同步为 `v1.2.5`。
> 这个不一致本身不造成合规问题（两种情况都不分发二进制），但它会让
> "钉死版本与校验和"这条论证失去可复核性，故一并订正。

**不代分发二进制的原因**（完整论证见 `dev-handbook/05-许可证合规.md`）：
上游许可明确写"Redistribution of modified binaries is not permitted",
且 proroot 的 `.so` 是**打过补丁的**（这正是它绕过 ptrace 的手段），
因此包含在本项目 APK 里再分发属于"分发修改过的二进制"，**不被许可允许**。
故实现为：用户自己从上游取 → 通过系统目录选择器导入到 App 私有目录 →
本 App 只负责调用。许可本身允许最终用户使用——限制的是我们代为分发。

**alpha.69：口径收紧为「方案 A —— 完全不提供二进制」**：

决策全文见仓库根目录 `PROROOT-许可与分发决策.md`。要点：

1. **五件套 `.so` 从 APK 移除**（此前 alpha.63~68 曾打包进
   `jniLibs/arm64-v8a/`）。移除后 `unzip -l` 查不到任何 proroot 条目，
   `tools/verify_apk.sh` 的第 4 项由"必然判红"变为"必然通过"。
2. **「一键下载」入口下架**。此前的口径（下文 alpha.63 段）认为
   "运行时在用户设备上获取"不构成再分发——法律定性本身未被推翻，
   但**判断依据太依赖解释**：一旦上游认为"提供直链引导下载"也算代分发，
   争辩成本远高于收益，而该功能的实际用户极少。故主动收口。
3. **只保留「从本地导入」**。用户若持有合法副本，可按文档放入
   `filesDir`（或手工放回 `jniLibs/arm64-v8a/`），App 侧的集成改造
   （`PROROOT_*` 环境变量、runtime 库复制、`-b host:guest` 参数形式、
   从 `nativeLibraryDir` 直接 exec）**全部保留未回退**，
   原生侧仍是完整可用的一条路径。
4. **加了三道防复活闸**，避免将来有人"顺手"把二进制加回来：
   `ProrootOption.soFiles` / `soAssets` 置空（有单测盯着）、
   `tools/fetch_assets.sh` 的 `fetch_proroot` 改为固定报错返回 1
   且 `all` 分支刻意不调用它、`tools/setup_android.sh` 删除自动补拉。

**alpha.63「一键下载」的历史合规口径**（已随 alpha.69 下架，留档备查）：

当时的论证是——运行时在用户设备上获取、按字节原样下载不做任何修改、
钉死版本与校验和使"传递的就是上游那一份"可被验证，故不改变"不代分发"
的法律定性。这三条本身仍站得住，**下架的理由是风险收益比**，不是推翻它。

另需注意（技术判断，非合规判断）：源码未公开（无法自审自修）、
官方要求 Ubuntu arm64 rootfs 而本项目是 Debian bookworm（未验证组合）、
且它只优化容器层**对 QEMU 指令翻译零改善**，不构成真正的构建提速。
所以默认不启用，并在卡片上如实说明。

## 通用说明

- GPL-2.0 组件（proot）以**独立进程**方式调用，与本项目代码不构成静态/动态链接；
- 按许可证要求，任何对外 Release 均须附 proot 对应版本源码或以上述链接方式提供；
- Debian rootfs 内软件包的许可证清单随包（`/usr/share/doc/*/copyright`）自带，可通过 App 内命令查看；
- 容器内 apt 安装的包（qemu-user-static / libstdc++6 / glibc 多架构库等）同理，
  均只作为容器内独立进程存在。

> 后续引入新组件时必须先更新此表（检查清单见 dev-handbook/05-许可证合规.md）。
> 注意：**传递依赖也要查**。曾经的 spake2-java 就是 Kadb 的传递依赖，第一版登记时
> 想当然写成 Apache-2.0，实际是 GPL-3.0，差点埋下合规事故。
