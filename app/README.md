# Flutter on Android

在安卓设备上本地构建 Flutter 应用的 IDE。纯本地，不依赖云端构建。

> 当前阶段：**Step 1 · proot + rootfs Hello World**
>
> 目标：验证地基——proot 能正常启动最小 Debian rootfs 并执行命令。

## 当前功能（Step 1）

- ✅ App 壳 + Material 暗色主题
- ✅ 原生桥（MethodChannel → Kotlin ProcessBuilder 启动 proot）
- ✅ proot 双路径定位（jniLibs `libproot.so` 优先，assets 兜底）
- ✅ 最小 Debian rootfs 解压（toybox tar，保留权限/符号链接）
- ✅ 终端页执行测试命令并回显（exit code + 耗时）
- ✅ 结构化 JSONL 日志（`filesDir/logs/app-YYYYMMDD.log`）
- ✅ 环境状态检测（rootfs / proot / ABI / Android 版本）

## 项目结构

```
lib/
  main.dart                    # 应用入口
  core/
    theme.dart                 # 主题
    logger.dart                # JSONL 结构化日志
  env/
    models.dart                # EnvInfo / ProotResult / InstallResult
    proot_bridge.dart          # MethodChannel 桥（Dart 侧）
    env_installer.dart         # EnvState：环境状态 + 安装编排
  ui/
    home_page.dart             # 主页：状态 + 初始化引导
    terminal_page.dart         # 终端：测试命令执行
platform/android/              # 定制文件（setup_android.sh 应用到 android/）
  MainActivity.kt              #   proot 启动 / rootfs 安装 / envInfo
  AndroidManifest.xml          #   extractNativeLibs 等
tools/
  fetch_assets.sh              # 下载 proot + rootfs 到 assets/（不进 git）
  setup_android.sh             # 生成 android 壳 + 打补丁（首次）
  check_env.sh                 # 构建前自检
assets/
  tools/                       # proot-arm64（fetch_assets.sh 下载）
  rootfs/                      # debian-minbase-arm64.tar.gz（同上）
```

## 快速开始

```bash
cd app
flutter pub get

# 1. 下载二进制资产（proot + rootfs，不进 git）
./tools/fetch_assets.sh

# 2. 生成 android 壳并应用定制（首次；详见 SETUP_ANDROID.md）
./tools/setup_android.sh

# 3. 自检：资产/架构/targetSdk/设备
./tools/check_env.sh

# 4. 真机运行
flutter run
```

> rootfs 获取方式（fetch_assets.sh 需要配 URL 或手动放置）：
> - `docker pull --platform=linux/arm64 debian:bookworm-slim` 后 `docker export` 导出；
> - 或 `debootstrap --variant=minbase`；
> - 或用 proot-distro 的 Debian 发行版 tarball。
> 详见 `tools/fetch_assets.sh` 内注释。

## Step 1 验证

打开 App → 点「初始化环境」→ 等解压完成 → 「打开终端」→ 选 `hello` → 运行 →
看到输出 `hello` 与 `[exit 0]` 即通过。

完整验证清单（含杀进程重进、`uname -a`、`apt --version`）见
[dev-handbook/03-测试指南.md](../dev-handbook/03-测试指南.md)。

## 关键构建约束

**targetSdk 必须为 28**（`setup_android.sh` 会自动改）：Android 10+ 禁止
targetSdk≥29 的应用执行自身数据目录里的二进制（W^X 限制），而 rootfs 内的
guest 二进制由内核真实执行。Termux 亦采用此方案。详见 [SETUP_ANDROID.md](SETUP_ANDROID.md)。

## 许可证

本项目核心代码采用 **AGPL-3.0** 许可。
第三方组件许可证见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
