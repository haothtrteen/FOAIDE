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

## 通用说明

- GPL-2.0 组件（proot）以**独立进程**方式调用，与本项目代码不构成静态/动态链接；
- 按许可证要求，任何对外 Release 均须附 proot 对应版本源码或以上述链接方式提供；
- Debian rootfs 内软件包的许可证清单随包（`/usr/share/doc/*/copyright`）自带，可通过 App 内命令查看；
- 容器内 apt 安装的包（qemu-user-static / libstdc++6 / glibc 多架构库等）同理，
  均只作为容器内独立进程存在。

> 后续引入新组件时必须先更新此表（检查清单见 dev-handbook/05-许可证合规.md）。
> 注意：**传递依赖也要查**。曾经的 spake2-java 就是 Kadb 的传递依赖，第一版登记时
> 想当然写成 Apache-2.0，实际是 GPL-3.0，差点埋下合规事故。
