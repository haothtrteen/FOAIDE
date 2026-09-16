# 04 · 常见 Bug 与解决方案

> 按症状索引的 Bug 知识库。遇到报错先搜这里，没有的话**解决后必须补充进来**。
>
> 每条记录格式：**症状 → 原因 → 解决 → 验证方法**

---

## 一、proot / rootfs 相关

### Bug 101 · proot 启动报错：`error: No such file or directory`

**症状**：
```
proot error: '/bin/sh': No such file or directory
```

**原因**：
rootfs 解压不完整或路径错误，导致 proot 找不到 shell。

**解决**：
1. 检查 rootfs 解压路径是否正确（应包含 `bin/`、`lib/`、`etc/` 等目录）；
2. 验证 tarball 的 SHA-256，重新下载解压；
3. 确认 proot 二进制架构与设备匹配（arm64 vs armv7）。

**验证**：`ls <rootfs_path>/bin/sh` 能找到文件。

---

### Bug 102 · apt 安装软件时 `Temporary failure resolving`

**症状**：
```
apt update 失败，报域名解析错误
```

**原因**：
proot 环境内 `/etc/resolv.conf` 未正确配置，DNS 解析不通。

**解决**：
在 rootfs 的 `/etc/resolv.conf` 中写入 DNS：
```
nameserver 223.5.5.5
nameserver 119.29.29.29
```
proot 启动参数中添加 `-b /etc/resolv.conf:/etc/resolv.conf` 绑定挂载。

---

### Bug 103 · proot 内执行二进制 `Exec format error`

**症状**：
```
bash: ./some_binary: cannot execute binary file: Exec format error
```

**原因**：
二进制架构不对（把 x86_64 的二进制放到了 arm64 环境，或反过来）。

**解决**：
1. 用 `file <binary>` 查看架构；
2. 如果是必须用的 x86_64 工具，考虑 box64 翻译；
3. 能找到 ARM64 版就换 ARM64 版。

---

### Bug 104 · 二进制执行报 `Permission denied`（W^X 限制）

**症状**：
```
exec failed: Permission denied    # 启动 proot 或执行 rootfs 内命令失败，退出码 126
```

**原因**：
Android 10 起，`targetSdkVersion ≥ 29` 的应用被禁止 `execve()` 自身数据目录（`/data/data/<pkg>/`）下的文件（W^X 策略：不允许"可写又可执行"）。rootfs 内的 guest 二进制（/bin/sh、apt、将来的 dart/java）由内核真实执行、路径就在 filesDir 下，必被拦截。

**解决**：
1. `android/app/build.gradle` 中 `targetSdk` 改为 **28**（Termux 同款方案，进入向后兼容 SELinux 域）；
2. proot 本体优先放 jniLibs（`libproot.so`，原生库目录不受 W^X 限制）——`setup_android.sh` 自动完成；
3. 改完必须**重新构建安装**，热重载不生效。

**验证**：`./tools/check_env.sh` 第 3 项显示 `targetSdk = 28`；App 内 `echo hello` 正常输出。

**出现版本**：Step 1 预防性记录（2026-09-16）

---

## 二、Flutter SDK 相关

### Bug 201 · `flutter` 命令直接 `Killed` / 闪退

**症状**：
在 proot 里执行 `flutter --version`，直接被 kill，无错误输出。

**原因**：
内存不足，Dart VM 被 OOM killer 干掉；或 proot 环境下 Dart VM 的某些系统调用不兼容。

**解决**：
1. 确认手机可用内存 ≥ 2GB（杀掉后台其他 App 再试）；
2. 设置 `export JAVA_OPTS="-Xmx512m"` 限制 JVM 堆；
3. 检查 `dmesg` 或 `logcat` 中是否有 `lowmemorykiller` 相关日志；
4. 在 `gradle.properties` 中调低 `org.gradle.jvmargs` 的 Xmx 值。

---

### Bug 202 · `flutter pub get` 超时 / 连接失败

**症状**：
```
Got socket error trying to find package xxx at https://pub.dev
```

**原因**：
国内网络访问 pub.dev 不稳定，或环境变量未配置镜像。

**解决**：
确认 proot 环境内已配置：
```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
```
写在 `/etc/profile.d/flutter_env.sh` 里确保每次登录都生效。

---

### Bug 203 · `flutter doctor` 报 `cmdline-tools component is missing`

**症状**：
```
[!] Android toolchain - develop for Android devices
    ✗ cmdline-tools component is missing
```

**原因**：
Android cmdline-tools 未安装或路径不对。

**解决**：
1. 下载 cmdline-tools latest；
2. 解压到 `$ANDROID_HOME/cmdline-tools/latest/`（注意目录层级必须是 `cmdline-tools/latest/bin/sdkmanager`）；
3. 执行 `sdkmanager --version` 验证；
4. 再跑 `flutter doctor`。

---

## 三、aapt2 / 构建工具相关

### Bug 301 · aapt2 报错 `Syntax error: ")" unexpected`

**症状**：
```
AAPT2 aapt2-9.0.1-xxx-linux Daemon #0: Unexpected error output:
.../aapt2: 1: Syntax error: ")" unexpected
```

**原因**：
Gradle 从 Maven 拉的 aapt2 是 x86_64 版，在 ARM64 上无法执行，被当成 shell 脚本解析了。

**解决**：
配置 `gradle.properties` 使用本地 ARM64 版 aapt2：
```properties
android.aapt2FromMavenOverride=/opt/android-tools/aapt2
```
确保路径下的 aapt2 是 ARM64 架构（用 `file aapt2` 验证）。

**验证**：构建时不再报此错误，资源编译阶段正常通过。

---

### Bug 302 · aapt2 替换后 Gradle 仍然下载官方版

**症状**：
明明配了 `aapt2FromMavenOverride`，但构建时还是报 x86_64 相关错误。

**原因**：
- `gradle.properties` 放错位置（应放 `~/.gradle/` 或项目根目录）；
- AGP 版本过旧不支持此参数；
- 有多个 Gradle 用户目录（不同用户执行）。

**解决**：
1. 确认 `~/.gradle/gradle.properties` 中有该配置；
2. 用 `./gradlew properties` 检查属性是否被加载；
3. 清理 Gradle 缓存：`./gradlew cleanBuildCache` 和删除 `~/.gradle/caches/` 中 aapt2 相关缓存。

---

### Bug 303 · cmake 无法执行（native 插件项目）

**症状**：
```
CMake Error: Could not find CMAKE_ROOT
```
或 cmake 报 `Exec format error`。

**原因**：
Android SDK 自带的 cmake 是 x86_64 版。

**解决**：
1. 在 Debian 内安装 apt 版 cmake：`apt install cmake`；
2. 在项目 `local.properties` 中指定：
   ```
   cmake.dir=/usr/bin/
   ```
3. 纯 Dart 项目不需要 cmake，可忽略此问题。

---

## 四、APK 构建产物相关

### Bug 401 · Release 包安装后启动崩溃：`Flag dedup_instructions is false in snapshot`

**症状**：
```
E/flutter: [ERROR:flutter/runtime/dart_vm_initializer.cc(41)]
Unhandled Exception: Flag dedup_instructions is false in snapshot
```
App 打开即闪退。

**原因**：
Flutter SDK 自带的 `gen_snapshot`（生成 Dart AOT 快照的工具）是 x86_64 版或架构不匹配，导致生成的 release 快照与设备上的 Dart VM 不兼容。

**解决**：
1. 使用与 Flutter SDK 版本严格匹配的 ARM64 版 `gen_snapshot`；
2. 替换 `bin/cache/artifacts/engine/android-arm64-release/linux-arm64/` 下的 `gen_snapshot`；
3. Release 构建前执行 `flutter clean`，确保缓存是新的。

**验证**：`flutter build apk --release` 出包后安装能正常启动。

---

### Bug 402 · 构建成功但 APK 安装失败：`INSTALL_FAILED_NO_MATCHING_ABIS`

**症状**：
```
Failure [INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries, res=-113]
```

**原因**：
APK 里的 native 库架构与设备不匹配。通常是因为只编了 armeabi-v7a 但设备是 arm64，或反之。

**解决**：
1. 确认构建参数：`--target-platform=android-arm64`；
2. 检查 `android/app/build.gradle` 中的 `ndk.abiFilters` 配置；
3. 用 `aapt dump badging app.apk` 查看 APK 支持的架构。

---

### Bug 403 · APK 签名验证失败

**症状**：
```
DOES NOT VERIFY
ERROR: Missing META-INF/MANIFEST.MF
```

**原因**：
APK 未签名，或签名文件损坏。

**解决**：
1. Debug 构建使用 debug keystore（自动生成在 `~/.android/debug.keystore`）；
2. Release 构建需配置签名：在 `android/app/build.gradle` 中配置 `signingConfigs`；
3. 或手动签名：
   ```bash
   apksigner sign --ks my.keystore --out app-signed.apk app-unsigned.apk
   ```

---

## 五、Web 预览相关

### Bug 501 · WebView 打不开 localhost:8080

**症状**：
`flutter run -d web-server` 启动成功，但 App 内 WebView 显示 `ERR_CONNECTION_REFUSED`。

**原因**：
- Web 服务器绑定了 `0.0.0.0` 但有防火墙；
- 或绑定了 `localhost` 但 WebView 走的是不同网络命名空间；
- 或服务尚未完全启动就打开了 WebView。

**解决**：
1. 启动参数加 `--web-hostname=127.0.0.1`；
2. 监听 stdout 中出现 `Serving at http://127.0.0.1:8080` 后再加载 WebView；
3. 确保 `android:usesCleartextTraffic="true"`（http 本地服务需要）。

---

### Bug 502 · 热重载不生效

**症状**：
改了 Dart 代码保存，Web 端没反应。

**原因**：
- 热重载需在 `flutter run` 的交互终端输入 `r`，不是自动的；
- 或 Flutter 版本较旧（< 3.32 Web 热重载为实验性，< 3.35 非默认开启）。

**解决**：
1. 确认 Flutter 版本 ≥ 3.35（Web 热重载默认开启 [$TRAE_REF](https://docs.flutter.dev/platform-integration/web/building)）；
2. 构建编排器在检测到文件变化时，向 `flutter run` 进程的 stdin 写入 `r\n` 触发热重载；
3. 如果仍不行，用 `R`（大写）触发热重启兜底。

---

## 六、性能 & 稳定性相关

### Bug 601 · 构建到一半 App 被系统杀掉

**症状**：
构建过程中 App 突然消失，回到桌面，logcat 有 `I/ActivityManager: Killing` 字样。

**原因**：
内存不足被系统 lowmemorykiller 杀掉，或构建时未用前台服务。

**解决**：
1. 构建时启动 Foreground Service，显示常驻通知；
2. 持有 WakeLock + WifiLock；
3. 在 `AndroidManifest.xml` 中声明 `android:largeHeap="true"`；
4. 调低 Gradle JVM 堆大小（`org.gradle.jvmargs=-Xmx1g` 或更低）；
5. 引导用户关闭电池优化。

---

### Bug 602 · 手机严重发烫 / 降频

**症状**：
构建时手机背面明显发烫，后续构建越来越慢（温控降频）。

**原因**：
Dart AOT 编译 + Gradle 是 CPU 密集型任务，手机被动散热扛不住持续满载。

**解决**：
1. 构建进度中提示用户"建议放置在散热良好的地方"；
2. 提供"省电模式"构建选项（单线程、关闭并行编译，速度换温度）；
3. 监测电池温度，超过阈值（如 45°C）时自动降低并行度。

---

### Bug 603 · 存储空间不足导致构建失败

**症状**：
```
No space left on device
```

**解决**：
1. 构建前检查剩余空间，不足 2GB 时警告用户；
2. 提供"清理空间"入口：Gradle 缓存、build 目录、旧版 SDK；
3. 支持将 rootfs / SDK 迁移到外置存储（Android 11+ 用 Storage Access Framework）。

---

## 七、提交 Bug 记录模板

发现新 Bug 并解决后，按以下格式追加到对应分类：

```
### Bug XXX · <一句话描述症状>

**症状**：
```
<关键错误日志 / 报错信息>
```

**原因**：
<根本原因分析>

**解决**：
<具体解决步骤>

**验证**：
<如何确认问题已修复>

**出现版本**：<tag / commit>
**修复版本**：<tag / commit>
```
