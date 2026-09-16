# SETUP_ANDROID.md — android 平台壳的生成与定制

## 为什么 android/ 不直接写在仓库里

`android/` 下的 Gradle Wrapper、AGP 版本必须与你本机的 Flutter SDK 匹配，手工固定版本容易踩兼容坑。因此仓库只保存**我们要定制的文件**（`platform/android/`），首次克隆后用脚本生成壳并打补丁：

```bash
cd app
flutter pub get
./tools/setup_android.sh        # 一键：flutter create + 覆盖定制文件 + targetSdk 28 + jniLibs
```

运行后把生成的 `android/` 目录提交进 git，以后就不再需要本脚本（除非换机器）。

## 关键定制点说明

### 1. targetSdk = 28（本项目最重要的构建配置）

Android 10 起，`targetSdkVersion ≥ 29` 的应用被禁止 `execve()` 自身数据目录（`/data/data/<pkg>/`）下的任何文件——这是 W^X（不可写又可执行）安全策略。而我们的架构里，rootfs 内所有 guest 二进制（`/bin/sh`、apt、将来的 dart/java）都由**内核真实执行**，路径就在 filesDir 下，必然被拦。

Termux 官方同样采用 `targetSdkVersion = 28` 以运行在向后兼容域解决此问题。**后果**：

- 无法上架 Google Play（Play 要求 targetSdk ≥ 34+，且禁止执行运行时下载的二进制）——这与我们的分发策略（GitHub Releases / 官网 / F-Droid）一致，本来就不走 Play；
- F-Droid 接受 targetSdk 28 的应用（Termux 亦如此分发），会带"面向旧版 Android"标注；
- 新 Android 版本如果收紧策略，需要跟进社区方案（届时 AndroidIDE/Termux 社区必然先行踩坑）。

### 2. proot 双路径部署 + PROOT_LOADER

| 文件 | 路径 | 说明 |
|---|---|---|
| `proot-arm64` | `jniLibs/arm64-v8a/libproot.so`（首选）或 `assets/tools/proot-arm64` → `filesDir/tools/proot` | proot 本体，Termux 仓库的 aarch64 构建（bionic） |
| `proot-loader` | `assets/tools/proot-loader` → `filesDir/tools/loader` | proot 的 ptrace loader，**必须随 proot 一起分发** |

关键机制：Termux 构建的 proot，其 loader 默认路径硬编码指向 `com.termux` 包。实测 proot 认
`PROOT_LOADER` 环境变量（指向不存在的 loader 会直接 fatal error），因此**无需重编译 proot**：
Kotlin 侧启动时设 `PROOT_LOADER=<filesDir>/tools/loader` 即可（`MainActivity.findLoader()`）。

两个文件均由 `tools/fetch_assets.sh` 从 Termux apt 仓库的 .deb 自动解出。

`AndroidManifest.xml` 中 `android:extractNativeLibs="true"` 确保 so 被解压成真实文件（而非仅存于 APK 内）。

### 3. rootfs 用系统 tar 解压（不用 Dart archive 包）

rootfs 必须保留 Unix 权限位与符号链接，toybox `tar`（Android 6.0.1+ 自带）天然支持，Dart 的 `archive` 包不保证。Kotlin 侧 `installRootfs()` 负责此事。

### 4. MethodChannel 架构

Dart 不直接 `Process.start` 二进制；统一走 `dev.foa/proot` 通道 → Kotlin `ProcessBuilder`。命令执行结果（exitCode/stdout/stderr/durationMs）结构化返回，Dart 侧写入 `filesDir/logs/app-YYYYMMDD.log`（JSONL）。

## 资产获取（构建前必做）

```bash
./tools/fetch_assets.sh           # 下载 proot + rootfs tarball 到 assets/（不进 git）
./tools/setup_android.sh          # 首次：生成 android 壳 + 打补丁
./tools/check_env.sh              # 自检
flutter run                       # 连接真机
```

## rootfs 的构建（服务器侧配方）

当前 `assets/rootfs/debian-minbase-arm64.tar.gz`（约 75MB）由以下流程在 x86_64 服务器构建，
产物已放入工作区，可直接取用；自建命令也收录在 `tools/fetch_assets.sh` 的提示里：

```bash
apt-get install -y debootstrap qemu-user-static proot
debootstrap --foreign --arch=arm64 --variant=minbase bookworm rootfs \
    http://mirrors.tuna.tsinghua.edu.cn/debian/
# stage2 需要宿主机的脚本（纯 shell，架构无关）
cp -r /usr/share/debootstrap/. rootfs/usr/share/debootstrap/
# 第二阶段：arm64 二进制由 qemu 翻译执行
proot -q /usr/bin/qemu-aarch64-static -R "$PWD/rootfs" \
    /usr/bin/env DEBOOTSTRAP_DIR=/debootstrap /bin/sh -c '/debootstrap/debootstrap --second-stage'
# 清理引导残留与文档，控制体积
rm -rf rootfs/debootstrap rootfs/usr/share/debootstrap rootfs/var/lib/apt/lists/* \
       rootfs/usr/share/doc rootfs/usr/share/man rootfs/usr/share/locale
( cd rootfs && tar -czf ../debian-minbase-arm64.tar.gz . )
```

## 服务器侧同步验证（devbox）

**问题**：真机在你手上，服务器是 x86_64——如何让服务器先跑一遍再交给你真机验证？

**方案**：x86_64 proot 原生运行（ptrace 不受影响），rootfs 内 arm64 二进制由
`qemu-aarch64-static` 翻译执行：

```bash
./tools/devbox_test.sh        # 从 assets 的 tarball 解压 + 跑命令集
```

命令集与 App 终端页（`lib/ui/terminal_page.dart`）完全一致：hello / uname -a /
os-release / apt --version / id。**rootfs 与真机用的是同一个 tarball，这就是同步点**。

已验证（2026-09-16，服务器侧）：5/5 通过，`uname -m` 返回 `aarch64`，`apt 2.6.1 (arm64)`。

**边界（诚实声明）**：服务器侧验证的是 *rootfs 内容与命令行为*；proot 的 ptrace 层在服务器
上是 x86_64 原生执行、设备上是 aarch64 原生执行——**ptrace/Android 内核相关的差异只有真机能
覆盖**。因此流水线是：服务器 devbox 预验证（快、可反复）→ 真机终验（每个 Step 一次）。

## 常见问题

- **`exec: Permission denied`（退出码 126）**：十有八九是 targetSdk 没改成 28，或改完没重新构建。见 dev-handbook/04-常见Bug与解决方案.md Bug 104。
- **proot 报 `proot warning: can't sanitize binding`**：通常是 `/proc` 绑定问题，确认用的是 Termux 分支构建的 proot（含 Android 补丁），不是上游 vanilla 版。
- **tar 解压失败**：设备 Android < 6.0.1 或厂商精简了 toybox，换 `--min-sdk` 更高的设备或在 Kotlin 侧引入 Apache Commons Compress（暂未需要）。
