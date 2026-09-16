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

### 2. proot 双路径部署

| 路径 | 说明 |
|---|---|
| `android/app/src/main/jniLibs/arm64-v8a/libproot.so` | **首选**。APK 原生库目录，不受 W^X 限制；`setup_android.sh` 会自动把 `assets/tools/proot-arm64` 复制过去 |
| `assets/tools/proot-arm64` → 首次运行拷到 `filesDir/tools/proot` | 兜底。targetSdk 28 下可执行 |

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

## 常见问题

- **`exec: Permission denied`（退出码 126）**：十有八九是 targetSdk 没改成 28，或改完没重新构建。见 dev-handbook/04-常见Bug与解决方案.md Bug 104。
- **proot 报 `proot warning: can't sanitize binding`**：通常是 `/proc` 绑定问题，确认用的是 Termux 分支构建的 proot（含 Android 补丁），不是上游 vanilla 版。
- **tar 解压失败**：设备 Android < 6.0.1 或厂商精简了 toybox，换 `--min-sdk` 更高的设备或在 Kotlin 侧引入 Apache Commons Compress（暂未需要）。
