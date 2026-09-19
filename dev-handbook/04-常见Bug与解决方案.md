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

### Bug 105 · 容器内 tar 找不到下载文件：`Cannot open: No such file or directory`（v0.1.0-alpha.14 抓到）

**症状**：
```
tar (child): /tmp/OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.20.1_1.tar.gz: Cannot open: No such file or directory
tar: Error is not recoverable: exiting now
```
JDK 下载"已完成"（SHA-256 校验通过）后解压必败；再次点击「下载并安装」又从零开始下载 183MB。

**原因**（两层）：
1. **proot `-R` 把宿主 `/tmp` 绑进容器**。`-R` = `-r` + 推荐绑定列表，官方文档明确包含 `/tmp`、`/etc/*`、`/dev`、`/proc`、`/sys`、`$HOME`、`/run` 等宿主路径。Dart 侧把安装包下载到 `rootfs/tmp/`（容器真实 /tmp），但容器内看到的 `/tmp` 是宿主目录（Android 上为空）→ tar 必然找不到。`/opt` 不在绑定列表内，是可靠的容器内落盘点。
2. **下载器只有单文件 `.part` 续传**：解压失败后安装包还在，但重试时 `.part` 已不存在 → 从头重下。

**解决**：
1. 下载落盘从 `rootfs/tmp/` 改为 `rootfs/opt/foa-dl/`（guest 视角 `/opt/foa-dl`），解压路径同步改为 `/opt/foa-dl/...`；
2. 下载器重构为**多线程分段 + 多镜像并行**（`SdkDownloader.downloadMultiSource`）：文件按 4 个 Range 分片并发下载，分片 i 轮流从镜像 i%n 起步（TUNA/GitHub/Adoptium 同时传），分片失败/15s 卡住自动换下一个镜像；
3. **分片级断点续传**：每个分片独立落盘 `<save>.p<i>`，长度即进度，重开应用/换镜像按长度续传；
4. **快路径**：目标文件已存在且尺寸/SHA-256 校验通过 → 跳过下载直接解压（解压失败重试不再重复下载）。

**验证**：安装失败后再次点击「下载并安装」，直接进入"正在解压"阶段（无下载进度条）；下载中页面镜像栏显示"TUNA 清华 + GitHub 官方"等多个镜像并行。

**教训**：**proot 容器内"能写"不等于"能看到"**——`-R` 绑定目录（/tmp、/etc、$HOME…）里宿主与容器的内容互相遮蔽。容器内文件操作一律避开绑定列表；下载大文件配合"快路径复用 + 分片续传"避免重复拉取。此绑定同样影响终端里用户对 /tmp 的使用（写入会落到宿主），后续如需容器原生 /tmp 语义，应把 `-R` 换成 `-r` + 显式 `-b`（排除 /tmp）。

**补充（2026-09-17，国内源分级 + 本地安装兜底）**：
- 国内镜像实测（`curl -r 0-0`）：TUNA 清华（206 ✓）、南大 NJU（206 ✓）支持 Range 分片；华为云同路径返回 HTML 页（非文件）、阿里云/USTC/交大/腾讯/网易均 404 → 国内源仅收录 TUNA + NJU。全部不可达才回退 GitHub 官方 + Adoptium API（`JdkInstaller._pickFastestDomesticFirst`）。
- 网络全挂时兜底：工具链页底部「从本地存储选择安装」→ `ACTION_OPEN_DOCUMENT` 系统选择器（MainActivity `onActivityResult`，原生层拷贝到 `filesDir/imports/` 再回传真实路径，规避 SAF content:// 在 proot 子进程不可读）→ 大小 + SHA-256 双重校验 → 复用解压流程（`JdkInstaller.installFromLocalFile`）。

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

### Bug 304 · `configureCMakeRelease[arm64-v8a]` 报 CMake '3.22.1' was not found

**症状**：

```
Execution failed for task ':app:configureCMakeRelease[arm64-v8a]'.
> [CXX1300] CMake '3.22.1' was not found in SDK, PATH, or by cmake.dir property.
```

**注意**：本项目**没有任何 native 代码**（无 `.c/.cpp/CMakeLists.txt`，见环境搭建记录 §3），
但 AGP 9.1 仍会为每个 variant × ABI 无条件创建 `configureCMake*` / `buildCMake*` 任务，
并把它们放进 `assembleRelease` 的依赖图（空跑也要先定位到 cmake 可执行文件）。
所以**这是"没有 native 代码也会踩"的坑**，别再按"纯 Dart 项目不需要 cmake"跳过。

**根因**：SDK 目录里没有 cmake（精简安装的 SDK 常缺），且 AGP 只认 SDK 内指定版本 /
`cmake.dir` / PATH 三条路。本沙箱 `/usr/bin/cmake` 是 3.28.3，AGP 要 3.22.1，
单独走 PATH 那条路它不认。

**解决**：造一个符合 AGP 期望布局（`<dir>/bin/cmake`）的 shim，再指过去：

```bash
mkdir -p /opt/cmake-shim/bin
ln -sf /usr/bin/cmake /opt/cmake-shim/bin/cmake
ln -sf /usr/bin/ctest /opt/cmake-shim/bin/ctest

# android/local.properties（机器本地文件，不入库）
cmake.dir=/opt/cmake-shim
```

验证：

```bash
./gradlew ":app:configureCMakeRelease[arm64-v8a]"
# → BUILD SUCCESSFUL（任务空跑，因为没有 CMakeLists.txt）
```

> 更稳的做法是把官方 `cmake-3.22.1-linux-x86_64.zip` 解到 `sdk/cmake/3.22.1/`，
> 但 `dl.google.com` 在国内/沙箱常被 TLS 阻断，shim 是更省事的路径。

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

## 七、架构类问题排查工具箱（2026-09-16 SDK 调研实战总结）

> 适用场景：任何"这个二进制 / SDK / artifact 有没有 arm64 版"、"这个工具能在手机上跑吗"、"为什么服务器能构建手机不能"类问题。
> 产出方法论的环境：Flutter 3.47.4 / engine 06a2e2a1，x86_64 服务器实测。

### 工具 1 · 查远程 artifact 是否存在（Range GET 探测）

```bash
curl -s -o /dev/null -w "%{http_code}\n" -r 0-0 "<url>"
# 206 = 存在；404 = 不存在；403 = 权限/签名问题
```

**坑**：不要用 `curl -I`（HEAD 请求）。实测 HEAD 对 Google 对象存储全部误报 404，Range GET（`-r 0-0` 只取 1 字节）才返回真实状态——部分对象存储 / 镜像对 HEAD 处理不一致。

### 工具 2 · 查官方分发矩阵（flutter_tools 源码，最权威）

镜像 404 ≠ 官方没有。下结论前先读源码里的硬编码下载清单：

- `packages/flutter_tools/lib/src/flutter_cache.dart`：搜 `_linuxBinaryDirs` / `_androidBinaryDirs` / `_dartSdks`——每个 `[本地目录, 下载路径]` 二元组就是官方真实分发范围（本次靠它实锤"Android gen_snapshot 只有 x64 宿主版"）；
- `packages/flutter_tools/lib/src/artifacts.dart`：gen_snapshot 的宿主回退逻辑（如 `darwin_arm64` 强制回退 `darwin_x64`，上游 TODO: flutter/flutter#152281）。

### 工具 3 · 验证单个二进制的"宿主 × 目标"双维度

```bash
file gen_snapshot          # → ELF 64-bit ... x86-64     ← 宿主架构（这个文件在哪种 CPU 上运行）
gen_snapshot --version     # → Dart SDK version ... on "linux_simarm64"  ← 目标架构（它生成哪种代码）
```

Dart 系工具 `--version` 会自报编译目标（`simarm64` = 生成 arm64 代码）。一个 x86-64 ELF 报 `linux_simarm64`，就是"x64 宿主、arm64 目标"交叉编译的铁证。

### 工具 4 · engine artifact URL 构造

```
{FLUTTER_STORAGE_BASE_URL}/flutter_infra_release/flutter/{engineRevision}/{包名}.zip
```

- `engineRevision` 取自 `flutter/bin/cache/flutter.version.json`；
- 路径规律：宿主敏感的包含宿主目录（`android-arm64-release/linux-x64.zip` = x64 宿主构建 arm64 目标）；宿主无关的直接以目标名开头（`android-arm64/artifacts.zip` = libflutter.so debug 版；`dart-sdk-linux-arm64.zip` = arm64 宿主 Dart SDK）。

### 工具 5 · 双源对照定位问题

同一个 URL 同时打 `storage.googleapis.com`（官方）与 `storage.flutter-io.cn`（国内镜像）：

| 官方 | 镜像 | 结论 |
|---|---|---|
| 206 | 206 | 正常可用 |
| 206 | 404 | 镜像未同步，换源或等待 |
| 404 | 404 | 官方没有，走社区构建 / qemu 翻译路线 |

---

## 八、服务器首次构建 arm64 APK 实战记录（2026-09-16，Flutter 3.47.4 / AGP 9.1 / Gradle 9.3.1 / Kotlin 2.4）

> 一次构建踩了 7 个坑，全部解决后产出 84.8MB arm64-v8a APK。按出场顺序记录，
> 换机重建或手机端构建时大概率会再遇到其中一半（已标注"手机端也会遇到"）。

### Bug 201 · Maven 大文件下载无限挂起（代理环境，手机端也会遇到）

**症状**：构建卡在 tree-shaking 日志后 15+ 分钟无输出，CPU 负载 0；jstack 显示 Execution worker 阻塞在 Apache HttpClient 的 SSL read；daemon 与客户端失联后表现为永久挂起。
**原因**：沙箱/代理环境对 `dl.google.com`、`maven.google.com` 的小请求正常，但 aapt2(~60MB)/r8 等大文件传输会无限期挂起（Gradle 无请求级超时）。**注意 `curl -I`(HEAD) 对这些源误报 404，`curl -r 0-0` 才是真相**（见工具 1）。
**解决**：`GRADLE_USER_HOME/init.gradle` 用 aliyun 镜像重写全部仓库（google/central/pluginportal → `maven.aliyun.com`，实测 69ms）；同时 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` 重定向引擎 maven 产物（download.flutter.io）。init.gradle 要点：`allprojects { afterEvaluate { ... } }` 里先 remove 原仓库再 append 镜像（Groovy `instanceof` 不能用变量，用 `getClass().getName()` 比较）。
**验证**：modules-2 缓存出现 `com.android.tools.build/aapt2`，构建推进到编译阶段。

### Bug 202 · Gradle daemon 被 OOM 击杀（手机端必遇，头号大坑）

**症状**：`Gradle build daemon disappeared unexpectedly (it may have been killed or may have crashed)`；或构建静默卡死后 daemon 日志出现 `Daemon vm is shutting down`。
**原因**：Flutter 3.47 模板在 `android/gradle.properties` 默认 `org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G`——面向高配桌面机。内存受限环境（服务器沙箱 5.8GB / 手机 8-16GB 还要分一半给系统）下 cgroup OOM killer 直接杀 daemon。**优先级**：`GRADLE_USER_HOME/gradle.properties` 的 jvmargs **高于**项目内的（本次 daemon 实际按 3G 启动但仍不够：3G 堆+1G 元空间+Kotlin daemon 1G+dart 工具 > 5.8G 总量）。
**解决**：daemon `1.5G 堆 + 512m 元空间`，`kotlin.daemon.jvmargs=-Xmx1024m`；改完必须 `pkill -f org.gradle.launcher.daemon` 让新参数生效（daemon 复用旧 opts）。手机端按设备 RAM 动态下调（见 02 号 init.gradle 注入）。
**验证**：`free -h` 峰值占用 < 总量；构建不再消失。诊断手段：`dmesg | grep -i 'killed process'` 看 cgroup OOM 记录。

### Bug 203 · Flutter 3.47 模板生成 build.gradle.kts 而非 build.gradle

**症状**：`setup_android.sh` 报"未找到 build.gradle，跳过"，targetSdk 补丁没生效。
**原因**：Flutter 3.47 起 `flutter create` 生成 Kotlin DSL（`build.gradle.kts`），旧脚本只认 Groovy DSL 文件名。
**解决**：脚本改为按 `[build.gradle.kts, build.gradle]` 顺序探测（已修复入库）；两 DSL 的 targetSdk 行写法不同（`targetSdk = flutter.targetSdkVersion` vs `targetSdkVersion flutter.targetSdkVersion`），正则都要覆盖。

### Bug 204 · lintVitalRelease 报 ExpiredTargetSdkVersion fatal

**症状**：`Lint found fatal errors while assembling a release target`，指向 `Error: Google Play requires that apps target API level 33 or higher. [ExpiredTargetSdkVersion]`。
**原因**：targetSdk 28 是本项目刻意策略（W^X，见 SETUP_ANDROID.md），但 AGP 的 release 构建 lint 不知道。
**解决**：`android { lint { disable += "ExpiredTargetSdkVersion" } }`（setup_android.sh 已自动注入）。非 Play 分发，豁免合理。

### Bug 205 · AGP 9 拒绝 Manifest 里的 extractNativeLibs

**症状**：`packageRelease` 失败：`android:extractNativeLibs is set to "true" ... instead set android.packagingOptions.jniLibs.useLegacyPackaging to true`。
**原因**：AGP 9.1 起强制该配置走 Gradle DSL，禁用 Manifest 属性。
**解决**：Manifest 删属性，`android { packaging { jniLibs { useLegacyPackaging = true } } }`（语义相同：so 解压成磁盘真实文件，proot 才能从 nativeLibraryDir 执行）。模板与 setup 脚本已同步。

### Bug 206 · Kotlin 2.4：ExecutorService.submit 的 lambda 类型歧义

**症状**：`Initializer type mismatch: expected 'Future<String>', actual 'Future<*>!'`。
**原因**：`pool.submit { ... }` 的 lambda 在 `Callable`/`Runnable` 重载间无法推断（新版 Kotlin 推断更严格）。
**解决**：显式 `pool.submit(Callable { ... })`，import `java.util.concurrent.Callable`。**同步修复了模板 `platform/android/MainActivity.kt`**——只修生成目录会让 bug 在下次重生成时复活。

### Bug 207 · 相对 import 路径错误逃过提交（流程教训）

**症状**：`flutter analyze` 报 `The getter 'AppLogger' isn't defined`，但 import 语句明明存在。
**原因**：`lib/env/env_installer.dart` 写了 `import 'core/logger.dart'`（相对当前目录解析为 `lib/env/core/`），正确应为 `'../core/logger.dart'`。Step 1 提交时只跑了 devbox 集成测试（shell 侧），没跑 Dart 编译，错误直到首次 `flutter build` 才暴露。
**解决**：修 import；`test/widget_test.dart` 模板残留的 `MyApp` 引用换成 `FoaApp` 冒烟测试。
**流程改进**：**提交前必跑 `flutter analyze`（7 秒），构建前必跑 `./tools/check_env.sh`**。已列入 README 核心原则。

### Bug 208 · 原生侧读 Flutter 资产漏了 flutter_assets/ 前缀（首个真机验证抓到的 bug）

**症状**：真机点「初始化环境」报 `读取 rootfs 资产失败（assets/rootfs/debian-minbase-arm64.tar.gz）：assets/rootfs/debian-minbase-arm64.tar.gz`；但 `unzip -l apk` 里资产明明存在（77.6MB 完整打包）。
**原因**：Flutter 打包的所有资产位于 APK 的 `assets/flutter_assets/` 子目录下，而 Android 原生 `AssetManager.open(path)` 的 path 相对 APK 的 `assets/` 根解析。代码里写 `assets.open("assets/rootfs/xxx")`，实际查找的是 `assets/assets/rootfs/xxx` → `FileNotFoundException`，且 **`e.message` 恰好就是传入的路径**（不带 "Unable to load asset" 字样），极易误判为"资产没打包"。
**解决**：原生侧所有资产常量补 `flutter_assets/` 前缀：`"flutter_assets/assets/rootfs/debian-minbase-arm64.tar.gz"`。受影响的还有 proot 本体与 ptrace loader 两个资产（`flutter_assets/assets/tools/...`）——loader 缺失不会在安装时报错（被 jniLibs 的 libproot.so 兜底掩盖），要到 proot 执行时才 fatal，属"延迟爆炸"型，一并修复。
**验证**：真机安装后点「初始化环境」能走完解压流程。
**教训**：Dart 侧 `rootBundle.load('assets/...')` 与原生侧 `assets.open('flutter_assets/assets/...')` 的路径基准不同；原生读 Flutter 资产必须带前缀。devbox 集成测试只覆盖了 shell 链路，MethodChannel → AssetManager 这段只有真机能测到——这正是"每 Step 必真机验证"流程价值的直接证明。

### Bug 209 · 真机解压 rootfs：mknod/link 被 Android 沙箱拒绝（v0.1.0-alpha.2 抓到）

**症状**：真机点「初始化环境」，tar 解压阶段红色报错两类：`tar: can't link './usr/bin/perlthanks' -> './usr/bin/perlbug': Permission denied`（3 条硬链接）与 `tar: can't create './dev/full|console|ptmx|zero|tty': Operation not permitted`（8 条设备节点），退出码非 0 后整体回滚。
**原因**：Android 应用沙箱（untrusted_app SELinux 域）不允许 `mknod()` 创建设备节点——任何机型都如此；`link()` 硬链接在部分机型内核（protected_hardlinks 强化策略）被拒。服务器上以 root 解压永远不会暴露（devbox 测试盲区）。
**解决（生成侧治本 + 运行时兜底）**：
1. **rootfs tarball 生成时重打包为"Android 沙箱友好格式"**（已固化进 `fetch_assets.sh` 的 `repack_for_android`，幂等）：`tar --hard-dereference --exclude='./dev/*' --owner=0 --group=0`——硬链接条目实体化为独立文件副本（体积 +1.3MB）；dev 设备节点全部丢弃（proot -R 运行时绑定宿主 /dev，rootfs 内 dev 只需空目录）。513 个 symlink 保留（Android 沙箱允许 symlink，Termux 同款依赖）。
2. **Kotlin 安装器容错**：tar 退出码非 0 时不再立即判死，改为校验关键文件（`bin/sh` 经 usr-merge symlink 解析 + `usr/bin/dpkg`）存在即视为成功，抵御 toybox tar 对 GNU 扩展头的未知 warning。
**验证**：真机重新初始化，应显示"安装完成：N 个文件，耗时 X 秒"。
**教训**：**凡"服务器验证通过、真机才能暴露"的问题，都应把差异点（权限模型）前移到资产生成阶段消除**，而不是指望运行时环境宽容。rootfs 这类静态资产在打包阶段就能把所有需要特权系统调用的条目消灭掉。

### Bug 210 · proot 动态库缺失：libtalloc.so.2 / libandroid-shmem.so（v0.1.0-alpha.3 抓到）

**症状**：
```
CANNOT LINK EXECUTABLE "/data/app/~~.../dev.foa.flutter_on_android-.../lib/arm64/libproot.so": library "libtalloc.so.2" not found
```
终端执行任何命令（含 `echo hello`）均报此错，退出码 1。rootfs 已正常安装（说明上一 Bug 修复生效），卡在 proot 本体无法启动。

**原因**：
`readelf -d proot` 显示 Termux 构建的 proot 有三个 `DT_NEEDED`：`libc.so`（系统有）+ `libtalloc.so.2`（Samba 项目的内存池分配库）+ `libandroid-shmem.so`（Termux 的 Android System V 共享内存适配层）。后两个是 Termux 专有库，装在 `/data/data/com.termux/files/usr/lib/`，**其他应用的系统目录（/system/lib64、/vendor/lib64）里根本没有**——bionic linker 按默认路径找不到，直接拒绝启动。

**解决**：
1. **资产获取阶段**（`fetch_assets.sh`）：从 Termux apt 仓库拉两个 `.deb` 并解包：
   - `libtalloc_2.4.3_aarch64.deb` → 提取 `libtalloc.so.2.4.3` 重命名为 `libtalloc.so.2`（linker 按 DT_NEEDED 名字查找，文件名必须一致）
   - `libandroid-shmem_0.7_aarch64.deb` → 提取 `libandroid-shmem.so` 原名分发
   - 两者放进 `assets/tools/` 随 APK 分发（46KB，体积可忽略）
2. **运行时部署**（`MainActivity.ensureProotRuntime()`，幂等）：从 assets 拷贝到 `filesDir/tools/`。**关键：同步逻辑必须在每次 exec() 前跑，不能只在 installRootfs() 里做**——installRootfs 对已装用户提前返回 alreadyInstalled，升级用户的库永远补不上。
3. **执行环境**（`exec()` 的 ProcessBuilder）：注入 `LD_LIBRARY_PATH=${filesDir}/tools`，linker 对 execve 主二进制的依赖查找同样读该变量 → 找到两个库。

**验证**：真机终端 `echo hello` 输出 `hello`；`uname -a` 显示 `... aarch64 ... GNU/Linux`。

**教训**：用第三方发行版（Termux）的二进制，`readelf -d` 查依赖是必做步骤——NDK 构建的"标准" bionic 程序只依赖 libc/libm/libdl/liblog，而 Termux 的包在自己前缀目录下链接了专有库，换宿主必缺。同类的还有 `libbsd`、`libiconv`（proot 5.2+ 可能新增）。

### Bug 211 · proot 临时目录硬编码 Termux 路径：can't create glue rootfs（v0.1.0-alpha.4 抓到）

**症状**：
```
$ echo hello
hello
proot warning: can't canonicalize /data/data/com.termux/files/usr/tmp/: Permission denied
proot warning: Unable to create temp directory for f2fs bug probe: Permission denied
proot error: can't create temporary directory: Permission denied
proot info: Please set PROOT_TMP_DIR env. variable to an alternate location (with write permission).
proot error: can't create glue rootfs
```
`echo` 这类不依赖容器的命令能跑（Bug 210 已修复，proot 本体正常加载），但 proot 无法创建 glue rootfs（bind 挂载粘合层），进入容器内的一切命令（`uname`、`apt`）仍然失败。

**原因**：
Termux 构建 proot 时把 `P_tmpdir` 硬编码为 `/data/data/com.termux/files/usr/tmp/`。proot 启动时要做两件事都依赖该目录：
1. **f2fs bug probe**：探测宿主文件系统是否 f2fs（Android 常见），需在 tmp 建临时文件
2. **glue rootfs**：`-R` 的 bind 挂载需要 tmp 作为粘合层工作目录
而 `/data/data/com.termux/` 是 Termux 应用的私有目录，本应用（SELinux untrusted_app 域）无权写入 → Permission denied → 直接 fatal。

**解决**：
`exec()` 的 ProcessBuilder 注入 `PROOT_TMP_DIR=${filesDir}/tmp`（先 `mkdirs()` 确保存在）——这是 proot 官方支持的环境变量，错误日志本身也提示了。与 Bug 210 的 `PROOT_LOADER` 同模式：**Termux 构建的二进制所有硬编码路径都可以用环境变量重定向**。

**验证**：真机终端 `uname -a` 应输出 `Linux ... aarch64 ... GNU/Linux`（能进容器 = glue rootfs 创建成功）。

**教训**：`P_tmpdir` 是 Termux proot 的第二个硬编码路径（第一个是 loader）。排查 Termux 二进制时把"编译期路径常量"全部列为嫌疑：`strings <binary> | grep com.termux` 一条命令就能列全。

---

## 九、编辑器（Step 2）相关（2026-09-17，v0.1.0-alpha.6 → alpha.13）

> Step 2 编辑器（代码浏览/编辑/保存/补全/检查/顶栏操作）全链路踩坑记录。
> 技术栈：`code_text_field` + `flutter_highlight`（vendored 到 `app/third_party/`）+ 自研补全/语法检查 + `dart_style` 格式化。

### Bug 212 · 文件树点击文件夹不显示内容

**症状**：文件树侧边栏点击任意文件夹，内容区空白，无法浏览子目录。
**原因**：初始实现只渲染当前一层，点击文件夹后没有递归展开子目录（空状态也区分不了"未加载"与"真空"）。
**解决**：`_buildSubtree` 懒加载递归渲染——点击目录节点才展开其子节点，目录/文件图标区分，空目录显示"（空文件夹）"占位。
**验证**：真机点击多层目录能逐级展开浏览。
**教训**：树形 UI 的"展开"必须显式实现，不能指望 ListView 自动递归；空态占位是 UX 必需（明确"已进入但无内容"）。

### Bug 213 · 空文件夹无法浏览 + 缺"../"返回 + 顶部被状态栏遮挡

**症状**：1) 空文件夹进入后无任何入口返回；2) 文件树顶部与系统状态栏重叠显示不清。
**原因**：1) 空目录无子项，天然没有可点击项，缺少显式"返回上级"入口；2) 嵌入侧边栏未处理系统安全区（SafeArea）。
**解决**：1) 顶部导航条加".."按钮（根目录置灰）+ 面包屑路径，点击任一级可跳回；2) 侧边栏整体包 `SafeArea`。
**验证**：真机进入空文件夹可用".."返回；顶部文字与状态栏不再重叠。
**教训**：任何"上下级导航"UI 都必须自带返回入口，不能依赖内容区天然存在可点击元素；Android 沉浸式布局第一件事是 SafeArea。

### Bug 214 · 语法高亮不生效

**症状**：编辑器打开 Dart 文件全是纯色文本，无关键字/字符串/注释高亮。
**原因**：`CodeField` 本身不渲染颜色，必须由父级 `CodeTheme` 提供高亮主题——漏包一层 `CodeTheme`。
**解决**：`CodeTheme(data: monokaiSublimeTheme, child: CodeField(...))`（`flutter_highlight/themes/monokai-sublime.dart`）。
**验证**：打开 `.dart` 文件关键字高亮，中文注释正常着色。
**教训**：code_text_field 的高亮依赖 `CodeTheme` 包裹，这是包的使用前提而非可选优化。

### Bug 215 · 保存写入的是打开时的旧内容

**症状**：编辑文件后点保存，重新打开发现改动丢失，保存的是初始内容。
**原因**：`onContentChanged` 回调只置 dirty 标记，没有把最新文本写回 `EditorPage._content`，保存时用的是打开文件时缓存的旧 `_content`。
**解决**：回调首行 `_content = t;`（把最新文本写回 State），再判 dirty。
**验证**：真机编辑→保存→重开，改动保留。
**教训**：State 持有"编辑中内容"时，内容变更回调必须同时更新该缓存——"只标脏不更新数据"是经典状态同步漏点。

### Bug 216 · 编辑器弹系统安全键盘（其他 App 正常，本 App 才触发）

**症状**：荣耀/华为等 ROM 上，编辑器聚焦时弹"安全键盘"（输入法界面受限、无法使用第三方输入法），其他 App 输入正常。
**原因**：`code_text_field` 硬编码 `enableSuggestions: false`。Flutter engine 在 `enableSuggestions: false` 时把 inputType 设为 `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD`（可见密码变体，见 engine 源码 `inputTypeFromTextInputType` 注释：Some devices ignore TYPE_TEXT_FLAG_NO_SUGGESTIONS）。厂商 ROM 的安全键盘检测逻辑识别到"密码变体"→ 强制弹安全键盘。**这是本 App 独有**（普通输入框不设该属性），与用户表述"其它 App 正常键盘"完全吻合。
**解决（三层）**：
1. **vendored 包**：把 `code_text_field` 拷到 `app/third_party/code_text_field`，pubspec 改 `path:` 依赖；删除 `enableSuggestions: false`（保持默认 true），改动处注释 `FOA 修改（Bug 216）`；
2. **显式非密码**：`obscureText: false`（方案 1：明确告知系统非密码输入）；
3. **多行类型**：`CodeField(keyboardType: TextInputType.multiline)`。`autocorrect: false` 不触发密码变体，保留以阻止英文自动纠正干扰代码输入。
**验证**：真机覆盖安装，编辑器聚焦弹普通键盘。
**教训**：Android 上"禁止输入法联想/纠错"不能靠 `enableSuggestions: false`——它会被映射成密码变体并触发厂商安全键盘。要禁纠错用 `autocorrect: false` 即可；vendor 第三方包是修改其行为的正路（pubspec path 依赖 + 注释标记）。

### Bug 217 · 键盘上方符号栏不显示

**症状**：点击符号栏所在版本，键盘弹出后编辑区底部（状态栏下方）没有出现符号快捷栏；截图显示键盘上方是输入法自带的工具栏。
**原因**：首版用 `MediaQuery.of(context).viewInsets.bottom > 0` 检测键盘弹出再显示。但带自身工具栏的中文输入法（百度/搜狗类）在部分 ROM 上**不把 insets 变化传给 Flutter**（厂商 IME 行为），检测恒为 0，符号栏从未渲染。
**解决**：放弃 insets 检测，符号栏**常驻显示**——Column 底部布局，键盘弹出时被顶起天然位于键盘正上方，收起时贴在编辑区底部；高度压缩至 36px 减少占用。
**验证**：真机键盘弹出/收起两种状态符号栏均可见。
**教训**：**"键盘上方 UI"不要依赖 viewInsets 检测**（厂商输入法行为不可靠，真机才暴露），优先常驻布局；想省空间再提供手动折叠。

### Bug 218 · 顶栏改造：文件名 + 撤销/应用/搜索/跳转/格式化/帮助

**症状/需求**：顶栏完整路径过长挤占按钮空间；需要撤销更改、应用更改、搜索、转到行、代码格式化、帮助（Dart 手册 / Flutter API）入口。
**原因/方案**（均为实现要点）：
1. **标题改文件名**：`path.split('/').last` + Tooltip 显示完整路径；
2. **撤销更改**：公开 `CodeEditorState`（原 `_CodeEditorState` 去下划线），EditorPage 用 `GlobalKey<CodeEditorState>` 调用 `reset(_initialContent)`；打开文件时记录初始内容 `_initialContent`；
3. **应用更改**：保存按钮复用，dirty 时图标变绿；
4. **搜索**：`_SearchDialog` 内 `RegExp(RegExp.escape(kw), caseSensitive: false)` 收集匹配，改 selection 选中匹配 → EditableText 自动滚动（零侵入 vendored 包）；
5. **转到行**：算行首 offset，selection 置该处，同上自动滚动；
6. **格式化**：`dart_style` 3.x，`compute(_formatDartSource, text)` 隔离线程防卡 UI。**坑：3.x 构造器必填 `languageVersion`**，用 `DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)`；格式失败（语法错误）捕获返回提示；
7. **帮助**：`url_launcher` 调系统浏览器（`LaunchMode.externalApplication`），INTERNET 权限已有。
**验证**：`flutter analyze` 零问题；真机打开 Dart 文件：撤销恢复、搜索跳转、转到行、格式化、打开官方文档链接均正常。
**教训**：1) 子组件能力对父级开放 = 公开 State + GlobalKey（比回调/继承更直接）；2) 编辑器的"滚动到目标"用 selection 驱动最省事（EditableText 自带 ensureVisible），别去改滚动控制器；3) 第三方 Dart 库 API 变动大（dart_style 3.x 构造签名变化），升级后先看构造器/方法签名再写调用。

---

## 十、工具链 SDK 安装与构建镜像配置（2026-09-17，Step 3 扩展）

> 在 JDK 之外新增：Android SDK / Flutter SDK(arm64) / 构建镜像一键配置 三张卡片（`toolchain_page.dart` 四卡片布局）。
> 实现文件：`lib/toolchain/sdk_installer.dart`（安装编排）、`lib/toolchain/sdk_downloader.dart`（多源分段下载 + SHA-256/SHA-1 双校验）。

### 10.0 · 总览：容器内 apt 链路四层自愈（全链路真机验证通过，2026-09-17）

工具链安装的前置依赖是容器内 apt 装 xz-utils/unzip（rootfs 是 minbase，无这两个 CLI）。这条失败链共四层、经三轮真机报错逐层击破（详记见对应小节）：

| 层 | 症状 | 根因 | 修复 | 详记 |
|---|---|---|---|---|
| DNS | apt/pub/gradle 全部网络失败 | rootfs 烤入构建机内网 resolv.conf | 打包中立化 + exec boot 幂等修正 | 10.6 |
| 账户/签名 | `No sandbox user '_apt'`、源 not signed | proot `-R` 绑定宿主文件 + rootfs 缺 passwd/group | `-0 -r` 显式绑定 + 补 Debian 骨架 + 运行时兜底 | 10.7 |
| 文件系统 | dpkg 解压 `Permission denied` | Android 禁 `link()`，Debian 包内硬链接 | proot `--link2symlink` | 10.11 |
| dpkg 状态 | `E: dpkg was interrupted` | 前次失败留半安装中间态 + 残留锁 | apt 前置恢复三步（清锁 / --configure -a / -f install） | 10.9 |

**2026-09-17 真机复测通过（apt 链 + Android SDK）**：工具链卡片 apt 阶段零报错，Android SDK 组件下载/SHA 校验/解压/`verify()` 全流程通过。注意：**当时 Flutter SDK 未完整装机验证**（1.5GB 下载未跑完），后续真机暴露解压编排 bug（Bug 411，见 10.12，alpha.16 修复）——教训：DoD 必须逐卡片全流程跑完，"大部分通过"不算通过。

**总教训**：多层失败链要靠「报错透传 + 逐层修复 + 每层修完真机回归」推进（402 DNS → 404 passwd → 407 link → 409 dpkg 状态，每修一层才暴露下一层）；包管理器状态自愈必须是安装前置步骤；rootfs 类"构建机生成、用户设备运行"的资产，生成侧中立化与运行时幂等自愈缺一不可。

### 10.1 · Android SDK 安装（`AndroidSdkInstaller`）

**组件清单**（版本与 Flutter 3.47.4 的 compileSdk 36 对齐，清单与大小/SHA-1 来自 `repo2-3.xml`，2026-09-17 抓取）：

| 组件 | 文件 | 大小 | 目标目录 |
|---|---|---|---|
| platform-tools r37.0.1 | `platform-tools_r37.0.1-linux.zip` | 9MB | `platform-tools` |
| platforms;android-36 | `platform-36_r02.zip` | 66MB | `platforms/android-36` |
| build-tools;36.0.0 | `build-tools_r36_linux.zip` | 64MB | `build-tools/36.0.0` |
| cmdline-tools;latest | `commandlinetools-linux-16111833_latest.zip` | 181MB | `cmdline-tools/latest` |

**关键决策**：
- **国内源仅收录腾讯云**（`mirrors.cloud.tencent.com/AndroidSDK/`）：实测四个文件均支持 Range（206）；TUNA AndroidSDK 404、华为云 android_repository 401（存疑）→ 排除；
- **SHA-1 校验**：repo2-3.xml 的 checksum 是 SHA-1（40 位十六进制），`SdkDownloader.verifySha1` 流式计算比对；
- **解压暂存 + 顶层目录归位**：各 zip 顶层目录名不一（`platform-tools/`、`android-36/`、`cmdline-tools/`），先 unzip 到 `/opt/foa-sdk-stage` 再 `ls | head -1` 取顶层 mv 到 `guestDir`；
- **预置 licenses**：写 `android-sdk-license`（含 8933bad1.../d56f5187.../24333f8a... 三行哈希），flutter/gradle 检查到即不再要求接受许可。

### 10.2 · Flutter SDK arm64 方案（`FlutterSdkInstaller`，核心坑）

**铁的事实（2026-09-17 沙箱实测）**：Flutter 官方 Linux 仅发布 x64 构建——`releases_linux.json` 全量检索无任何 arm64 条目。目标设备是 aarch64，直接跑官方包必挂。

**破解思路**：
1. 下载官方 x64 tarball（`flutter_linux_3.47.4-stable.tar.xz`，1.5GB，SHA-256 校验）；
2. 下载**官方 Dart SDK linux-arm64**（`dartsdk-linux-arm64-release.zip`，225MB，与 Flutter 配套的 dart 3.13.3）替换 `/opt/flutter/bin/cache/dart-sdk`；
3. **写回 version 文件**：`printf "3.13.3\n" > bin/cache/dart-sdk/version`——flutter 工具启动时校验该文件与 `flutter.version.json` 的 `dartSdkVersion` 一致，不一致会尝试重新下载 x64 dart-sdk 而失败（这是最隐蔽的坑）；
4. `flutter_tools.snapshot` 是架构无关的 Dart 快照，替换 dart-sdk 后 `flutter build apk` 可正常运行（构建产物面向 Android 目标架构，与宿主架构无关）。

**国内源**：`storage.flutter-io.cn` 同时镜像 `flutter_infra_release` 与 `dart-archive` 且支持 Range（206）；华为云 dart 镜像不支持 Range、TUNA/华为云 flutter 镜像 404 → 仅收录 flutter-io.cn。

### 10.3 · 构建镜像一键配置（`MirrorConfigurator`）

一键完成四步（对应需求文档的「提前下载 Gradle + 配置国内镜像源」）：
1. **环境变量** → host 侧直接写 rootfs 真实文件 `/etc/profile.d/foa-env.sh` + `~/.bashrc`（PUB_HOSTED_URL / FLUTTER_STORAGE_BASE_URL / ANDROID_HOME / JAVA_HOME / GRADLE_USER_HOME / PATH 追加 /opt/flutter/bin）；
2. **Maven 镜像** → `~/.gradle/init.gradle` 写入阿里云三仓
   （public/google/gradle-plugin）。⚠️ 形态已随 Bug 426 改版（alpha.37）：
   **beforeSettings 前插 settings 仓**（settings 仓库正是被 prefer 的
   对象，加仓库合法）。旧版 `allprojects + settingsEvaluated` 双保险
   是**错误指导**——Flutter 新模板 settings.gradle.kts 走 PREFER_SETTINGS
   模式拒绝 project 级仓库，真机 22% 配置 Gradle 必败（见 Bug 426）；
3. **wrapper 镜像** → 递归改写 `/root/projects` 下所有项目的 `gradle-wrapper.properties` distributionUrl 为腾讯云镜像；
4. **Gradle 预下载** → `gradle-9.3.1-all.zip`（224MB）下载到 wrapper 缓存目录，首次构建不再访问国外源。

**Gradle wrapper 缓存目录名（实测确认）**：`base36(MD5(distributionUrl))` 去前导零（Gradle 9.3.1 `PathAssembler` 源码确认）。腾讯云 URL 实测为 `5wooodlkfwsm42ictrailuf0e`，目录结构 `~/.gradle/wrapper/dists/gradle-9.3.1-all/<hash>/`。wrapper 发现 zip 在位即跳过下载、自动解压并写 `.ok` 标记后删除 zip。

### 10.4 · exec 注入环境变量（MainActivity）

`exec()` 的 `/bin/sh -c` 前置注入 `[ -f /etc/profile.d/foa-env.sh ] && . /etc/profile.d/foa-env.sh; `——即使 `env -i` 清空了环境，构建命令（`flutter build apk`、`./gradlew`）也能自动带上国内镜像变量。

### 10.5 · 镜像实测结论汇总（curl -r 0-0，2026-09-17）

| 用途 | 可用国内源 | 实测不可用 |
|---|---|---|
| JDK 17 (Adoptium aarch64) | TUNA 清华、南大 NJU（206 ✓） | 华为云（返回 HTML）、阿里云/USTC/交大/腾讯/网易（404） |
| Android SDK 组件 | 腾讯云 AndroidSDK（206 ✓） | TUNA（404）、华为云 android_repository（401） |
| Flutter tarball / Dart arm64 | flutter-io.cn（206 ✓） | TUNA/华为云 flutter（404）、华为云 dart（不支持 Range） |
| Gradle 分发包 | 腾讯云 gradle（206 ✓） | — |
| Maven 依赖 | 阿里云三仓（69ms 实测） | — |
| pub.dev | pub.flutter-io.cn | — |

---

## 十一、APK 体积优化实战（2026-09-17，103.9MB → 87.3MB，-16%）

> 目标：把"先分析 → 再配置 → 后清理"的方法论落成本项目可复用经验。
> 改动文件：`android/app/build.gradle.kts`（abiFilters + 显式 R8）、`android/app/proguard-rules.pro`（新建）。

### 11.1 · 现状摸底（先分析再动手）

`unzip -l app-release.apk` 拆解（优化前 103,945,959 B）：

| 组成部分 | 体积（未压缩） | 说明 |
|---|---|---|
| rootfs tarball | 78.9MB | **运行时必需**（proot 容器），90% 大头 |
| libflutter.so × 3 ABI | 33.4MB | arm64 + **armeabi-v7a + x86_64 冗余** |
| libapp.so × 3 ABI | 23.6MB | 同上，Dart AOT 机器码随 ABI 翻倍 |
| classes.dex（R8 后） | 0.55MB | 已压缩，Java/Kotlin 面很小 |
| libproot.so + assets/tools | 0.6MB | proot 双路径 + 动态库（必需） |

**结论**：Flutter APK 的代码面（dex）极小，R8 收益有限；**多 ABI 冗余才是纯代码可省的最大头**。

### 11.2 · 关键事实：Flutter 3.47 默认已开 R8

`FlutterPlugin.kt` 的 `shouldShrinkResources()` **默认返回 true**（除非 `--no-shrink` / `-Pshrink=false`），自动给 release 追加：proguard-android-optimize.txt + flutter_proguard_rules.pro + 项目 proguard-rules.pro（**文件存在时**）。证据：`build/app/intermediates/dex/release/minifyReleaseWithR8/` 任务与 `mapping.txt` 一直在生成。
→ 显式写在 build.gradle.kts 只是**确定性保证**（防 `--no-shrink` 或插件默认变更），不会带来额外压缩。

### 11.3 · 核心改动：只保留 arm64-v8a（本次 -16.6MB 全部来源）

```kotlin
defaultConfig {
    ndk {
        abiFilters += listOf("arm64-v8a")
    }
}
```

- 目标设备全为 64 位，proot 本体也只分发 arm64（jniLibs 仅有 arm64-v8a/libproot.so）；
- 移除 armeabi-v7a + x86_64 两套 libapp.so/libflutter.so（未压缩约 37MB，zip 压缩后实际省 16.6MB——so 已是压缩格式，deflate 增益很小）；
- 效果等同 `--split-per-abi` 的单 ABI 结果；本项目分发渠道是 GitHub Releases / F-Droid 直发 APK，比 .aab 更合适（.aab 只在 Google Play 有意义）。

### 11.4 · R8 头号大坑：`-keep class io.flutter.** { *; }` 必炸（Bug 402 补充）

**症状**：启用 minify 后 R8 报 `Compilation failed to complete` + `Missing class com.google.android.play.core.*`（splitinstall / splitcompat 一整套）。

**原因**：网上教程普遍推荐的 `-keep class io.flutter.** { *; }` 会把引擎的可选类 `FlutterPlayStoreSplitApplication` / `PlayStoreDeferredComponentManager` 强制保留，它们引用 Play Store 拆分安装 API（`com.google.android.play.core.*`），本项目不依赖 play-core → R8 缺类。**AGP 9.1 下"缺类被 kept 代码引用" = 硬错误，`-dontwarn` 压不住**（-dontwarn 只压 warning）。

**解决**：proguard-rules.pro 只保留应用自身包，引擎交给 Flutter 自带规则按需保留：

```proguard
-keep class dev.foa.flutter_on_android.** { *; }
```

### 11.5 · 资源/依赖清理结论（本项目）

- **无图片资产**：assets/ 只有 proot 工具与 rootfs，无 PNG/JPEG 可转 WebP；
- **依赖全在用**：provider / code_text_field / highlight / dart_style / url_launcher / crypto 均有引用，无冗余；
- **Tree shaking 已生效**：MaterialIcons-Regular.otf 1645184 → 6572 B（99.6%）；
- **proot 双路径保留**：assets/tools/proot-arm64（244KB）是 jniLibs 的兜底拷贝（Bug 210 教训），不删。

### 11.6 · 验证三件套（每次体积优化后必跑）

1. `aapt2 dump badging <apk>` → 断言 `native-code: 'arm64-v8a'`；
2. `unzip -l <apk>` → 断言 lib/ 只剩目标 ABI、rootfs tarball / 动态库就位；
3. `apksigner verify --print-certs <apk>` → 签名有效。

### 11.7 · 遗留大头与后续方向（未做，风险需单列任务）

- rootfs tarball 78.9MB 占 90%，压缩收益最大但牵一发动全身：gzip→xz 约可再省 30-40MB，但首次解压路径（MainActivity 原生 tar）需同步改造、真机验证首装耗时，**单列任务再动**；
- Debian minbase 裁剪（清 apt lists / man / 多语言 locale）可再省数 MB，同样需回归容器内 apt 可用性。

### 10.6 · apt 安装 xz-utils/unzip 失败：resolv.conf 烤入构建机内网 DNS（2026-09-17 真机抓到）

**症状**：工具链页「Android SDK / Flutter SDK」两张卡片都报 `apt 安装 xz-utils/unzip 失败（请确认容器内网络可用，apt 源为 TUNA 清华）`，错误详情为空。

**原因**（双层）：
1. **根因**：`fetch_assets.sh` 自建 rootfs 走 debootstrap，debootstrap 会把**构建机**的 `/etc/resolv.conf` 拷进目标 rootfs。本沙箱构建出的 tarball 里是内网 DNS `nameserver 10.96.205.180`——用户真机上该地址不可达 → 容器内 glibc 解析 mirrors.tuna.tsinghua.edu.cn 失败 → `apt-get update` 失败 → 安装 xz-utils/unzip 必然失败。**任何构建机打包的 rootfs 都带这个隐患**；
2. **错误详情为空**：`AptTools.ensure()` 把 apt 输出全部重定向到 `/dev/null`，失败时异常里拿不到任何日志，用户无从排查。

**解决**（三层，缺一不可）：
1. **运行时引导（修存量设备）**：MainActivity `exec()` 的 boot 注入在每次执行前幂等修正 `/etc/resolv.conf`——无公共 DNS 则写入 `nameserver 223.5.5.5 / 119.29.29.29 / 8.8.8.8`（阿里/腾讯/谷歌），已有则不动。对所有容器命令生效（apt/pub/gradle 全受益）；
2. **错误可见**：`AptTools.ensure()` 去掉 `/dev/null`，改为 `2>&1 | tail` 捕获 apt 输出透传给异常详情，并加 `-o Acquire::Retries=3`；
3. **源头中立化**：`fetch_assets.sh` 新增 `normalize_resolvconf()`，打包时把 tarball 内 resolv.conf 改写为公共 DNS（幂等，已有公共 DNS 则跳过）。

**验证**：
- 沙箱模拟 boot 逻辑三场景（坏/好/空 resolv.conf）均符合预期；
- 真机复测：工具链卡片安装不再报 apt 失败（xz-utils/unzip 装好后继续下载 SDK）。

**教训**：rootfs 是"在构建机生成、在用户设备运行"的产物，一切**构建机私有的环境信息**（DNS、代理、hosts、路径）都不能烤进去；凡涉网操作都要有幂等的运行时自愈 + 打包时中立化的双保险。

### 10.7 · apt 安装 xz-utils/unzip 失败：proot `-R` 绑定宿主系统文件 + rootfs 缺 /etc/passwd（Bug 404，2026-09-17 真机抓到）

**症状**：工具链页「Android SDK」卡片报 `apt 安装 xz-utils/unzip 失败`，详情含三条连锁错误：
```
W: No sandbox user '_apt' on the system, can not drop privileges
W: GPG error: http://mirrors.tuna.tsinghua.edu.cn/debian bookworm InRelease: Couldn't create temporary file /tmp/apt.conf.yWMfQJ for passing config to apt-key
E: The repository 'http://mirrors.tuna.tsinghua.edu.cn/debian bookworm InRelease' is not signed.
E: Package 'xz-utils' has no installation candidate
E: Unable to locate package unzip
```
（注意：DNS 已正常——上一轮 Bug 402 修复生效，本次错误链与网络无关。）

**原因**（双层叠加）：
1. **proot 参数 `-R` 会绑定宿主系统文件**：proot 官方文档明确 `-R` 自动绑定一组"推荐路径"（含 `/etc/passwd`、`/etc/group` 等），且**不推荐装包时用 -R**（包管理会更新这些绑定文件）。Android 宿主根本没有 `/etc/passwd`、`/etc/group`、可写的 `/tmp` → 容器内这几个路径失效：apt 找不到 `_apt` 用户无法降权、apt-key 写 `/tmp` 临时配置失败 → 源签名验证失败 → 找不到包；
2. **rootfs 打包缺陷**：源 rootfs 打包时 `/etc/passwd`、`/etc/group` 处于 dpkg 重写中间态（tarball 内只剩 `passwd-/+`、`group-/+` 备份），即使换掉 `-R` 容器内也没有用户数据库。

**解决**（三层，缺一不可）：
1. **换 proot 参数（根治）**：MainActivity `exec()` 弃用 `-R`，改用 `-0 -r rootfs -b /dev -b /proc -b /sys`——容器内全部使用 rootfs 自身文件，不绑定任何宿主系统文件（`android/app/.../MainActivity.kt` 与 `platform/android/MainActivity.kt` 同步修改）；
2. **rootfs 资产补账户文件（源头）**：`fetch_assets.sh` 新增 `fix_rootfs_accounts()`，幂等检测 `/etc/passwd`、`/etc/group` 缺失或缺 `_apt` 时补标准 Debian bookworm 骨架（含 `_apt`/`messagebus` 用户）+ `/etc/hosts`，按 Android 友好格式重打包；当前 assets tarball 已重打包（76MB）；
3. **运行时兜底（修存量设备）**：`AptTools.ensure()` 在 apt 前注入 `_fixAccounts` 脚本——补 passwd/group（含 `_apt`）、确保 `/tmp` 1777、建 apt lists/archives partial 目录、补 `/etc/hosts`；对已装旧 rootfs 的用户升级 APK 即生效，无需重装 rootfs。

**验证**：
- 沙箱解包新 tarball：`/etc/passwd` 含 `root`/`_apt`，`/etc/group` 含 `_apt`，`/etc/hosts`、公共 DNS resolv.conf、`/tmp` 1777 全部就位；
- 真机复测：工具链卡片 apt 阶段不再报 `_apt`/签名错误（2026-09-17 装机确认，Android SDK 全流程通过，见 10.0 总览）。

**教训**：proot 的 `-R` 是给"浏览/调试"用的便利选项，**装包场景必须用 `-0 -r` + 显式白名单绑定**；rootfs 这类"随 APK 分发的系统镜像"要按"可运行的最小完整系统"验收（passwd/group/hosts 齐备），不能只看关键二进制在位。

### 10.8 · 网络安装失败后没有"从本地存储安装"兜底入口（Bug 408，2026-09-17）

**症状**：工具链页网络全挂（镜像不可达/超时）时，用户无法离线安装——只有「下载并安装」，点击后反复报下载失败；JDK 卡此前已接本地导入，但 Android SDK / Flutter SDK 卡没有对应按钮。

**原因**：本地安装兜底只实现了 JDK 一条链路（`JdkInstaller.installFromLocalFile` + `LocalInstallPicker` + 原生 `pickInstallFile`）；`AndroidSdkInstaller` / `FlutterSdkInstaller` 没有本地导入方法，`_SdkCard` 也没有按钮位，且平台模板 `platform/android/MainActivity.kt` 缺 `pickInstallFile`（只在生成目录里改了，Bug 206 教训）。

**解决**：
1. **SDK 本地导入**：`sdk_installer.dart` 的 `install` 拆出共用 `_installCommon`，新增 `installFromLocalFile`——按文件名/大小匹配组件（Android SDK 4 组件、Flutter tarball 或 Dart arm64 zip），拷贝进 `/opt/foa-dl` 下载缓存并做 SHA-1/SHA-256 校验，然后并入共用流程：**已本地提供的组件走快路径跳过下载，其余组件仍走网络**（可逐个导入，断网时有多少传多少）；
2. **UI 按钮**：`_SdkCard` 增加 `onInstallLocal`，未安装且非忙碌态时显示整宽「从本地存储选择安装」按钮（与 JDK 卡一致）；`SdkPhase` 增加 `importing` 阶段态；
3. **原生模板同步**：`platform/android/MainActivity.kt` 补齐 `pickInstallFile` 处理器 + `onActivityResult` 拷贝逻辑 + `queryDisplayName`（与生成目录一致，防重新生成时复活）。

**验证**：`flutter analyze` 本项目 `lib/` 零问题；release APK（arm64，87.2MB）构建成功，badging 断言 `arm64-v8a`、资产齐备、签名有效；本地导入路径由真机按序验证（选文件 → importing → 校验 → 解压）。

**教训**：凡新增跨层能力（Dart UI + 原生通道），必须一次性打通"全部卡片入口 + 生成目录与平台模板双写"，并保持模板与生成目录逐字节一致（Bug 206 门禁）。

### 10.9 · apt 安装 xz-utils/unzip 失败：dpkg 数据库半安装中间态（Bug 409，2026-09-17 真机抓到）

**症状**：工具链页「Android SDK」/「Flutter SDK」卡片仍报 `apt 安装 xz-utils/unzip 失败`，详情首行：
```
E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem
```
（DNS 正常、passwd/_apt 已补齐——Bug 402/404 修复均生效，错误链换了主角。）

**原因**：此前失败的安装尝试（Bug 402/404 时期的报错、超时、用户取消杀进程）把 dpkg 数据库留在**半安装中间态**（包解包未配置），apt 检测到后拒绝执行任何操作；同时被杀的 apt/dpkg 进程会残留 lock 文件。也就是说：**修好上一个根因 ≠ 数据库干净**，每轮失败都会留下新的状态污染。

**解决**（`AptTools.ensure()` 在 apt 前的恢复三步，幂等、失败不阻断后续命令）：
1. 清陈旧锁文件：`rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock`（proot 单线程执行无并发风险，锁只可能来自上次被杀进程）；
2. `DEBIAN_FRONTEND=noninteractive dpkg --configure -a` 补完未完成的解包/配置；
3. `DEBIAN_FRONTEND=noninteractive apt-get -f install` 修复破损依赖。
之后才走 `apt-get update` → `apt-get install xz-utils unzip`。各步 `2>&1 | tail` 吞掉非零退出码，恢复失败也继续尝试后续命令；报错文案同时提示用户可先在终端跑 `dpkg --configure -a` 或改走「从本地存储选择安装」。

**验证**：release APK 的 `libapp.so` 中 `strings` 可见 `dpkg --configure -a` / `apt-get -f install` / `APT_TOOLS_OK`（恢复链已编进 AOT 快照）；**真机复测通过（2026-09-17）**：dpkg 中断态恢复生效，工具链 apt 阶段零报错；升级覆盖安装即生效，无需重装 rootfs。

**教训**：包管理器的**状态自愈必须成为安装前置步骤**——任何一次失败安装都会污染 dpkg 状态，下次安装前先恢复；错误详情透传（不丢 /dev/null）是连续三轮 apt 报错能被逐一击破的前提（402 DNS → 404 passwd → 409 dpkg 状态）。

### 10.10 · Android 15+ 真机状态栏纯黑/导航栏纯白：引擎静默跳过运行时设色（Bug 410，2026-09-17 真机确认）

**症状**：顶栏（AppBar）为深色 `#101418`，状态栏却是纯黑、导航栏纯白（浅色模式下尤刺眼）；`SystemChrome.setSystemUIOverlayStyle`（main.dart）与 `AppBarTheme.systemOverlayStyle`（theme.dart）完全无效，且**无任何报错**。

**原因**：反编译 Flutter 3.47.4 引擎 `PlatformPlugin.java` 字节码确认——Android 15+ 设备（`Build.VERSION.SDK_INT >= 35`）上**无条件跳过** `Window.setStatusBarColor` / `setNavigationBarColor`（与 app 的 targetSdk 无关）。运行时设色在这类设备上彻底失效，系统栏回落主题默认值（`Theme.Light.NoTitleBar` → 黑状态栏 + 白导航条）。

**解决**：系统栏初始颜色改走**主题 XML 声明**（OS 在窗口创建时直接应用，不经过 Flutter 引擎）：
1. 新建 `res/values/colors.xml`：`foa_bg = #FF101418`（与 `FoaTheme.bg` 同色）；
2. `values/styles.xml` 与 `values-night/styles.xml` 的 `LaunchTheme`/`NormalTheme` 均加 `android:statusBarColor` / `android:navigationBarColor` = `@color/foa_bg`——targetSdk 28 的应用在**所有** Android 版本生效（edge-to-edge 强制仅限 targetSdk 35+）；
3. 顺带修复：`NormalTheme` 的 `windowBackground` 与启动屏 `launch_background`（drawable + drawable-v21）改 `@color/foa_bg`，消除暗色应用冷启动白闪；
4. main.dart / theme.dart 的运行时设色保留（对 Android < 15 设备仍生效，图标明暗在所有版本生效），注释标注两者分工。

**验证**：`aapt2 dump resources` 断言 APK 内 `color/foa_bg #ff101418` 在位、styles 四处引用（statusBarColor/navigationBarColor 属性）；badging 断言 targetSdk 28；真机复测待装机确认。

**教训**：框架运行时 API 在新版 OS 上可能存在**静默失效**路径（不报错、不生效、无日志）——根因要靠反编译引擎字节码坐实，不能停留在"API 用法不对"的假设；系统级 UI 的**初始态永远优先用平台声明式配置**（主题 XML）兜底，运行时 API 只做增量调整。

### 10.11 · dpkg 解压报 `Permission denied`：Android 禁 `link()` 与 Debian 包内硬链接（Bug 407，2026-09-17）

**症状**：apt 链路修好 DNS/账户后，dpkg 解压 unzip 等包时报 `Permission denied`（`status-old` 备份文件也失败），安装仍走不通。

**原因**：Android 沙箱对应用私有目录禁 `link()`（与 Bug 209 同一类限制）；而 Debian 包大量使用硬链接（如 unzip 的 `zipinfo`→`unzip`，dpkg 的 `status`→`status-old` 备份），dpkg 解包/备份时调用 `link()` 直接被拒。

**解决**：proot 启动参数加 `--link2symlink`——把容器内的硬链接语义转为符号链接实现，apt/dpkg 全流程正常（MainActivity `exec()` 已固化，平台模板同步修改）。

**验证**：2026-09-17 真机：apt 安装 xz-utils/unzip 成功（dpkg 解压含硬链接的 unzip 包零报错），Android SDK 下载安装全流程通过（见 10.0 总览）。

**教训**：与 Bug 209（rootfs tar 解压的 mknod/link 限制，**生成侧重打包**治本）对照——运行时才发生的包管理操作没法靠生成侧预处理，要靠 proot 参数（`--link2symlink`）在容器层抹平文件系统语义差异；rootfs 容器的验收清单必须包含「apt 装一个含硬链接的包」。

### 10.12 · Flutter SDK 解压必失败：`mv: cannot stat '/opt/flutter'`（Bug 411，2026-09-17 真机抓到）

**症状**：Flutter SDK 卡片安装到「解压」阶段必报：
```
Flutter 解压失败: mv: cannot stat '/opt/flutter': No such file or directory
```
（同屏 Android SDK 卡片正常、apt 阶段零报错——四层自愈链全部生效，本次是纯编排逻辑 bug，与前四层无关。）

**原因**：解压命令链**自毁**——
```
d=$(ls -d /opt/flutter* | head -1)   # d = 刚解压出的 /opt/flutter 本身
rm -rf /opt/flutter                  # 把要 mv 的源删了
mv "$d" /opt/flutter                 # 必报 cannot stat
```
官方 Flutter tarball 顶层目录恰好叫 `flutter/`，glob 结果与归位目标同路径，**100% 复现**。该写法本意是防御"tarball 顶层目录名与目标不同（如 `flutter-3.47.4/`）需改名归位"，却没防住"恰好相同"的情形。对照：JDK 安装器无此问题（glob 是 `/opt/jdk-*`，与目标 `/opt/jdk` 不同路径）；Android SDK 安装器因用暂存目录天然免疫。

**解决**：改暂存目录模式（与 `AndroidSdkInstaller` 对齐）：解压到 `/opt/foa-flutter-stage` → 取顶层目录 mv 归位 → 清暂存。源与目标**永不同路径**；旧 `/opt/flutter` 保留到解压成功后才删（中途失败不毁存量安装）。

**验证**：沙箱 mock tarball（顶层 `flutter/`）实测三条——旧链报出与真机**逐字一致**的错误、新链 `FLUTTER_EXTRACT_OK` 且暂存目录清理干净、模拟 tar 中途失败后旧安装存活；release APK（alpha.16）`libapp.so` 断言：新暂存链在位、旧自毁 glob（`ls -d /opt/flutter*`）零残留；真机复测待装机确认。

**教训**：
- **容器内 shell 命令链必须先在沙箱实跑**（mock 一个小 tarball 就够）——代码审查拦不住"glob 命中归位目标自身"这种时序自毁；上一轮"工具链测试通过"实际只覆盖了 apt 链与 Android SDK，Flutter tarball 从未端到端装机过，bug 因此拖到用户手上；
- `rm 旧目录 + mv 新目录` 模式只在**源 ≠ 目标**时成立；源路径来自 glob/`ls` 时，必须解压到独立暂存目录再 mv，保证源目标路径空间隔离；
- 错误透传（Bug 402 起的惯例）再次立功：一行 `cannot stat` 即定位到自毁命令，无需额外日志。

---

### 10.13 · Flutter 工具链 x64 快照不兼容：`Snapshot not compatible ... requires x64 linux ... VM has arm64`（Bug 412，2026-09-17 真机抓到）

**症状**：aarch64 容器内用**官方 x64 Flutter SDK** 执行任何 `flutter` 命令必报：
```
Snapshot not compatible: /opt/flutter/bin/cache/flutter_tools.snapshot
  requires x64 linux, and the current machine is arm64 linux (VM has arm64)
```
（此前误以为换 arm64 dart-sdk 即可，实则 `flutter_tools.snapshot` 是 **app-jit 快照、含 x64 机器码**，与 dart VM 架构强绑定，架构不匹配必炸。）

**原因**：Flutter 官方 Linux 仅发布 x64 宿主构建（`releases_linux.json` 全量检索无 arm64），且 `bin/cache/flutter_tools.snapshot` 为架构相关的 app-jit 快照。`bin/cache/dart-sdk/bin/dart`、`dartaotruntime` 等也是 x64 ELF，arm64 直接 exec 报 `Exec format error`；就算用 arm64 dart 加载 x64 快照也报 `Snapshot not compatible`。引擎宿主产物同理：`gen_snapshot`、`impellerc`、`font-subset` 官方只发布 `linux-x64`（Flutter issue #189724/#168980 已核实）。

**解决**（方案 A：官方 SDK + QEMU 全链转发，`qemu_compat.dart`）：
- 容器内装 `qemu-user-static`（静态 aarch64）+ `libc6:amd64 / libstdc++6:amd64 / libgcc-s1:amd64 / zlib1g:amd64 / libatomic1:amd64` 多架构运行库；
- `bin/cache/dart-sdk/bin/` 下 x64 ELF **原地改名 `.foa-real`**，生成 qemu 转发脚本：`exec qemu-x86_64-static -L / <原二进制> "$@"`。`flutter`（bash 脚本）照常按路径调用 `dart`，经转发脚本进入 qemu 模拟，x64 快照由 x64 dart VM 加载即恢复；qemu 内 fork 的 x64 子进程（frontend_server、gen_snapshot）由 qemu 继续模拟，全链路自洽；
- 引擎产物：为每个 `artifacts/engine/android-*/linux-x64` 生成 `linux-arm64/` 目录，内含指向 `../linux-x64/<tool>` 的转发脚本——不复制大文件、不改官方原件，缓存 stamp 校验不受影响；
- `sdk_installer.dart` 相应**移除 arm64 dart-sdk 替换逻辑**，保留官方 x64 dart-sdk 原样；安装顺序建议先应用兼容层再装 Flutter SDK（装反了可点兼容层「重新应用」补上转发）。

**验证**：`verify()` 内置分步冒烟：qemu-x86_64-static 存在 → qemu 能运行 x86_64 动态链接器（`/lib64/ld-linux-x86-64.so.2`，验多架构 glibc）→ 包装后 gen_snapshot `--help` 无 "cannot execute"/"shared libraries" 报错。真机逐卡片全流程待装机确认。

**教训**：
- **快照是架构相关的**：app-jit / app-aot 快照含目标机器码，换 VM 架构必炸——"换 arm64 dart 就能跑 x64 快照"是想当然，真机复现为准；
- 官方 SDK 宿主工具（gen_snapshot 等）只发 x64 是长期现状，arm64 设备要跑官方工具链必须走翻译层（qemu）或社区重编译（termux-flutter-wsl），二选一不可兼得；
- 架构问题必须真机验证：沙箱是 x86_64，`Exec format error`/`Snapshot not compatible` 只在 arm64 宿主暴露。

---

### 10.14 · x64 兼容层卸载"没效果"：`apt-get purge | tail || true` 管道吞掉退出码（Bug 416，2026-09-17）

**症状**：工具链页点「x64 兼容层」卸载，确认后界面恢复"已启用"，qemu 转发层原样残留——卸载看起来完全没生效。Flutter SDK / Android SDK 的卸载则正常。

**原因**：卸载脚本核心行
```
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq qemu-user-static libc6:amd64 ... 2>&1 | tail -n 5 || true
```
存在双重吞错：管道 `| tail` 使 `$?` 取 tail 的退出码（0），`|| true` 再把任何失败吞掉；apt purge 失败（如依赖残留、包不存在）时脚本照样走到 `echo UNINSTALL_OK`，Dart 侧只看 `ok`/stdout 即认为卸载成功。随后 `verify()` 发现 qemu 二进制仍在 → 卡片显示"已启用" → 用户看到的就是"卸载没效果"。沙箱对照实测：旧写法失败时输出 `UNINSTALL_OK`（exit 0），新写法输出 `PURGE_FAILED rc=100`（exit 2）。

**解决**（`qemu_compat.dart`）：
- 卸载脚本改为**逐条捕获状态**：`apt-get purge ... > /tmp/foa_purge.log 2>&1; rc=$?`，非零即 `echo PURGE_FAILED; exit 2`；再补一道 `[ -x qemu-x86_64-static ] && exit 3`（防 purge 半成功残留）；
- `QemuCompat.uninstall()` 检查 stdout 含 `PURGE_FAILED`/`QEMU_STILL_PRESENT` 或非零退出码即抛 `DownloadException`，UI 显示真实错误而非假装成功；
- 顺手补 `AndroidSdkInstaller.verify`：兼容层卸载后 `adb --version` 报 Exec format error，此前被当成"版本号"显示（"已安装"假象），现在识别为「需先应用兼容层」提示。

**验证**：沙箱 mock `apt-get` 返回 100——旧写法静默 `UNINSTALL_OK`，新写法 `PURGE_FAILED` + exit 2（逐字核对）；`sh -n` 语法通过；真机复测卸载流程待确认。

**教训**：
- **管道会吃掉左侧命令的退出码**——shell 里要拿真实状态必须 `cmd > log 2>&1; rc=$?`，再判断 `rc`；`| tail || true` 这类写法只适合"展示输出、无所谓成败"的场景；
- 卸载这类**破坏性操作必须验后效**（qemu 二进制是否真的消失），不能只信脚本最后一行 echo；
- 安装/卸载流程结束后要重新 verify 并让状态与真实文件系统一致，否则 UI 状态与磁盘状态脱节会造成"没效果"假象。

---

### 10.15 · 工具链安装顺序 UX：兼容层必须先于 SDK（防小白装反，2026-09-17 优化）

**症状**：新手先装 Flutter SDK 再装兼容层时，SDK 安装末尾验证必报 `Snapshot not compatible`（x64 快照无 QEMU 转发），卡片显示"安装失败"，用户困惑（磁盘上其实已装好）。

**解决**（`toolchain_page.dart`）：
- 卡片顺序调整为：**x64 兼容层(QEMU) 置顶** → JDK → Android SDK → Flutter SDK → 构建镜像；
- `_SdkCard` 新增 `orderReady`/`orderHint` 门控：兼容层未应用时，Android SDK / Flutter SDK 的「下载并安装」与「从本地存储选择安装」按钮禁用，并显示黄色门槛提示（含"装反了无需卸载，点兼容层重新应用自动补上"）；
- `SdkPhase` 新增 `uninstalling`，卸载过程有视觉反馈与错误捕获。

**教训**：有强依赖顺序的安装流程，UI 必须把依赖项放在被依赖项之前并做门控——靠 desc 文案"建议先装"拦不住小白，按钮直接禁用 + 提示最有效。

---

### 10.16 · Android SDK 安装报"关键组件缺失"但不知道缺哪个（Bug 417，2026-09-17）

**症状**：Android SDK 四个组件下载/解压后，安装末尾验证报笼统的「Android SDK 验证失败：关键组件缺失」，卡片停在"安装失败"（"下载并安装"可重试但用户无法定位问题）。真机复现，沙箱无法直接复现（x86_64 宿主跑不了 proot 容器）。

**排查**（沙箱取证，`mirrors.cloud.tencent.com/AndroidSDK/`）：
- Range 拉取 4 个 zip 末尾 3MB（中央目录区）列顶层条目：`platform-tools/`、`android-36/`、`android-16/`（!）、`cmdline-tools/`——全部**单顶层目录**；
- **Google 归档怪癖**：`build-tools_r36_linux.zip` 顶层目录是 `android-16`（历史命名沿袭），但内容确实是 build-tools 36.0.0（aapt2/d8/apksigner/zipalind 齐全）；
- 沙箱完整解压 `build-tools` 走现有「取顶层条目 `ls | head -1` → mv 改名归位」逻辑：`android-16` → `build-tools/36.0.0`，aapt2 落位且可执行——**解压算法本身无问题**；
- 结论：结构正常，真机失败点未知（proot/unzip/环境），**错误信息必须能自诊断**。

**解决**（`sdk_installer.dart`）：
- 新增 `AndroidSdkComponent.keyPath/keyTest`（每个组件的关键文件 + 校验方式 x/f）；
- 解压循环**归位后立即校验关键文件**：缺失输出 `KEYFILE_MISSING <路径>` + 暂存目录结构，exit 4，报错精确到「组件 X 解压失败：缺少 Y」；
- 新增 `diagnose()`：逐项 `[ -e ]` 检查 4 个关键文件，返回缺失路径清单；
- `verify()` 改为基于 `diagnose`（缺文件返回 null，兼容相位模型）；`_installCommon` 末尾用 `diagnose` 抛「缺少 …」明细；「重新验证」按钮同样展示缺失清单；
- 报错附处置建议：重试 / 先卸载后重装 / 「从本地存储选择安装」逐个导入。

**验证**：沙箱 mock 正常/缺失两条路径——正常 `SDK_COMPONENT_OK` exit 0，缺失 `KEYFILE_MISSING /opt/android-sdk/build-tools/36.0.0/aapt2` exit 4；`flutter analyze` 零 error；真机复测待装机确认。

**教训**：
- **笼统错误信息是排障的最大障碍**——"关键组件缺失"不如"缺少 build-tools/36.0.0/aapt2"一个词有用；安装这类多组件流程，每个环节都要能自证（逐组件校验关键文件）；
- 沙箱（x86_64）能证伪"算法问题"（解压逻辑正确），但真机环境（proot/权限/存储）的差异只能靠**设备侧自诊断**收敛；
- Google SDK 归档顶层目录名与版本号无关（`android-16` 装的是 36.0.0），代码必须按「取顶层条目改名归位」而非硬编码目录名。

---

## 十一之二、原生 arm64 后端相关（2026-09-18）

### 11-2.1 · bionic 链接的原生二进制在 glibc 容器里跑不起来（Bug 418，2026-09-18）

**症状**：把 Termux 系移植的 aarch64 二进制（如 gen_snapshot）放进 Debian rootfs
后执行，报：

```
/system/bin/linker64: No such file or directory
```
或
```
CANNOT LINK EXECUTABLE "/opt/foa-native/gen_snapshot": library "libc.so" not found
```

注意这两条**都不是**"架构不对"——`readelf -h` 明明是 AArch64，容易误判成
"又是一个 Exec format error"，实际是**动态链接器找不到**。

**原因**：Termux 的编译目标是 Android bionic，ELF 的 INTERP 是
`/system/bin/linker64`，libc 来自 `/apex/com.android.runtime/lib64/bionic`。
而容器 rootfs 是 glibc 的 Debian，压根没有 `/system` 与 `/apex`——
proot 只做路径重定向，不会凭空变出这两个目录。

**解决**（`MainActivity.kt`）：
- `buildProotCmd()` 里按**落位标记**（`rootfs/opt/foa-native/gen_snapshot` 是否存在）
  追加 `-b /system -b /apex -b /linkerconfig`（逐项判存在再加）；
- `libraryPath()` 在原有 `filesDir/tools`（proot 自己的 libtalloc/libandroid-shmem）
  之后追加 bionic 搜索路径：`/apex/com.android.runtime/lib64/bionic`、
  `/apex/com.android.art/lib64`、`/system/lib64`、`/vendor/lib64`；
- 未落位时两条分支都是 false，行为与以前**逐字节一致**（不引入回归）。

**验证**：`flutter analyze` 零 error；真机侧靠导入流程里的 `--help` 冒烟验证——
冒烟不过会**当场删除落位文件**，挂载与库路径随之自动失效，不留半吊子状态。

**教训**：
- 判断"能不能跑"要看 **ELF Machine + INTERP + DT_NEEDED** 三件事，只看 Machine
  会把"链接器缺失"误诊成"架构错误"；
- 判定 bionic / glibc 的廉价指纹：DT_NEEDED 里出现**无版本号**的 `libc.so`
  → bionic；出现 `libc.so.6` → glibc。不用装 binutils 也能从 `grep -a` 粗扫看出来；
- proot 的 `-b` 是"新增挂载点"，不是"替换"——挂 `/system` 不会影响 Debian 程序
  （它们不会去 `/system` 找库），副作用为零。

### 11-2.2 · minbase rootfs 没有 readelf（体检脚本不能依赖 binutils）

**症状**：想用 `readelf -d` 取 DT_NEEDED 判断链接类型，Debian minbase 里
`readelf: not found`（binutils 不在 required 级，minbase 不装）。

**解决**（`native_arm64.dart` 的体检脚本）：
- Machine 判定**不依赖任何工具**：`od -An -tx1 -j 18 -N 2 <file>` 读 e_machine
  （`b700`=aarch64 / `3e00`=x86-64 / `2800`=arm32 / `0300`=i386）；
- 先校验 ELF 魔数 `7f454c46`，非 ELF 归为 data（快照、jar），避免把随机二进制
  误判成"unknown 架构的 ELF"；
- DT_NEEDED 有 readelf 就用 `readelf -d`，没有就退化为 `grep -a` 字符串粗扫，
  并在结果里标记 `approx=yes`，UI 上如实显示"粗扫"。

**教训**：容器内脚本要按"minbase 只有 coreutils + apt"来写；能用 `dd`/`od`
读字节解决的事，不要引入新包（装 binutils 要多几十 MB，为一次体检不值）。

### 11-2.3 · Bug 419：Gradle 解析 `io.flutter:flutter_embedding_release` 失败——引擎 Maven 仓库地址藏在 `FLUTTER_STORAGE_BASE_URL` 里

**症状**（2026-09-18 沙箱实测，出包必踩）：
```
> Could not resolve io.flutter:flutter_embedding_release:1.0.0-<engine-hash>.
  > Could not HEAD 'https://storage.googleapis.com/download.flutter.io/...'
    > Remote host terminated the handshake
```
阿里云镜像齐全、`~/.gradle/init.gradle` 就位，唯独 io.flutter 全挂；
甚至把 jar/pom 提前放进 Gradle 缓存 `files-2.1/`，离线模式仍报
`No cached version available for offline mode`。

**原因**：
- `flutter_embedding_release` / `arm64_v8a_release` 等引擎构件**只发布在
  Flutter 官方 Maven 仓**（`{FLUTTER_STORAGE_BASE_URL}/download.flutter.io`），
  阿里云/腾讯镜像**均不代理**；
- `FlutterPlugin.kt`（flutter_tools/gradle，L91-97）构建期读环境变量
  `FLUTTER_STORAGE_BASE_URL` 拼仓库地址，**缺省值是 storage.googleapis.com**——
  沙箱对 dl.google.com / repo.maven.apache.org / storage.googleapis.com
  都是 TLS 握手层阻断（`SSL_ERROR_SYSCALL`），Gradle 逐仓重试全灭；
- Gradle 缓存条目按"仓库 id"索引，手动塞文件或强开 offline
  （`gradle.startParameter.offline = true` 的 init 脚本）都会因
  仓库 id 不匹配解析不到，且 init 脚本给 allprojects 塞仓库还会顶撞
  settings 的 `repositoriesMode` 报 `prefer settings repositories`——
  **缓存侧怎么绕都绕不过去，必须让构建走可达镜像**。

**解决**（固化进 `.trae/skills/foa-sandbox-build` 固定流程）：
```bash
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn   # 引擎 Maven 仓跟着切到镜像
export PUB_HOSTED_URL=https://pub.flutter-io.cn
flutter build apk --release --target-platform=android-arm64     # 573s 全绿
```
构建日志开头出现 `Flutter assets will be downloaded from
https://storage.flutter-io.cn` 即为生效标志。

**验证**：同条件下复跑构建成功出包；产物验证三件套 +
`classes.dex` 的 kadb 残留 = 0 全部通过（alpha.27）。

**教训**：
- **网络排障先分清"哪个依赖走哪个仓"**：Maven 镜像配得再全，
  引擎构件的仓库地址是 Flutter Gradle 插件在运行时按环境变量拼的，
  这是独立于 init.gradle / settings.gradle 的第三条仓库注入路径；
- 不要用 init 脚本强开 offline 硬闯——失败信息（"No cached version"）
  会把人引向"缓存坏了"的错误方向，实际是仓库 id 不匹配；
- 前置连通性自检只需 4 个 curl：`storage.flutter-io.cn` /
  `maven.aliyun.com` / `dl.google.com` / `storage.googleapis.com`，
  前两个必须通、后两个通不通都行（有镜像就行）。

---

### Bug 420：构建卡死在 4%（startup lock 等待 + pub TLS 瞬断）

**症状**（2026-09-18 真机，proot 后端 my_demo 构建）：
```
Waiting for another flutter command to release the startup lock...
Flutter assets will be downloaded from https://storage.flutter-io.cn...
Got TLS error trying to find package args at https://pub.flutter-io.cn.
Failed to update packages.
✗ 构建失败（exit 69）· 已运行 09:06 · 进度冻结在 4%
```
**原因**（两层叠加）：
1. **启动锁被孤儿进程持有**：上次构建被强杀（App 被杀/取消）后，容器内
   dart 进程（flutter_tools/pub 的宿主）存活，flock 锁不释放；proot 不隔离
   PID、minbase 无 ps/pkill，新构建无限等待。9:06 大半耗在这里；
2. **pub get TLS 瞬断**：弱网（35KB/s）下 pub.flutter-io.cn 握手失败，
   flutter build 内部的自动 pub get 无重试，直接 exit 69。

**解决**（alpha.30，均在 `_startBuild` 前置段）：
1. `ToolchainEnsure.flutterUnlock()`：/proc 遍历 + builtin kill 杀
   cmdline 含 `dart-sdk/bin/dart` 的进程 + 删 `bin/cache/lockfile`。
   ⚠️ 匹配串在脚本文本里必须拆写（`PAT='dart-sdk/bin/''dart'`，shell 层
   拼接），否则 sh -c 的 cmdline 含完整串会**自杀**；只杀 dart 不动
   gradle daemon（java，可复用）；
2. 构建命令前置独立 `pub get` 三次重试（`ok=0; for i in 1 2 3; ...`），
   全败 exit 69；成功后 build 内部自动 pub get 秒过；
3. `_feedErrorBreakdown` 增加 `tls error` / `waiting for another flutter
   command` 两条可执行修复建议。

**教训**：
- 「进度条冻结在 N%」≠ 进程卡死——先看 exit code（69 = pub 网络失败），
  进度条只反映日志阶段，进程已死时它只是不再动；
- 强杀构建（execStreamStop/App 被杀）杀的是 proot 主进程，容器内子进程树
  （dart/gradle）可能存活——**任何持锁型工具链，重入前都要做孤儿清理**；
- 弱网下任何"无重试的在线步骤"都是失败点，pub get 这种幂等操作
  直接套三次重试即可。

### Bug 421：下载卡死在 80.2/91.8MB（熔断检查是死逻辑 + 响应头无超时）

**症状**（2026-09-18 真机，Termux JDK deb 在线下载，镜像"Termux 官方"）：
```
openjdk-17  80.2 MB / 91.8 MB   ← 长时间冻结，无报错、不换源、不重试
```
**原因**（两层叠加，均在 `sdk_downloader.dart`）：
1. **卡死熔断是死逻辑**：`stallTimeout`（15s 无数据 → 换镜像）的检查写在
   读流 `await for` 循环体内——只有数据到达时才执行。服务端 hang
   （TCP 连接还在、一个字节都不吐）时，循环**挂起在等待下一个事件上**，
   检查代码永远轮不到执行，熔断形同虚设。80.2MB 处连接被对端静默挂起，
   就此冻结到天荒地老；
2. **`req.close()` 无响应头超时**：`connectionTimeout` 只管三次握手；
   握手成功后服务器不回响应头，请求同样永久挂起（另一条隐性死路）。

**解决**（alpha.30，`_downloadSegment`）：
1. 卡死熔断改由 `Stream.timeout` 驱动：
   `await for (final chunk in resp.timeout(stallTimeout))` ——
   **事件间隔**超 15s 即抛 TimeoutException → 走既有重试/换源链路。
   看门狗由 `Stream.timeout` 独立计时，不依赖数据到达；
2. 新增 `respHeaderTimeout = 20s`：`await req.close().timeout(respHeaderTimeout)`，
   响应头 hang 也熔断；
3. 慢速熔断（10s 窗口 <64KB/s 涓流，alpha.29 已加）保留，与卡死熔断
   互补：卡死=无数据，涓流=有数据但太慢。

**教训**：
- **看门狗必须独立于被监视的数据流驱动**——"检查写在循环体内"只有
  循环体被执行时才生效，而数据停止时循环体恰恰不执行。这是异步流
  超时最典型的死逻辑写法，Dart 里正确姿势是 `Stream.timeout`（每来
  一个事件重置计时器，超时即抛）；
- `connectionTimeout ≠ 响应头超时`：握手成功后到首字节响应之间
  是另一段无保护窗口，`HttpClientRequest.close()` 本身永不超时；
- 测试难以覆盖"服务端 hang"场景（真机弱网才暴露），代码评审时
  对"循环体内做超时检查"的模式要保持警惕。

### Bug 422：Termux 仓库索引查询一小时不返回（join() 无熔断 + 明文 8MB）

**症状**（2026-09-18 真机，工具链页 Termux 卡片）：
"查询 Termux 仓库索引..." 挂 15:33 → 16:34（一小时）后报
`SocketException: Failed host lookup: 'mirror.iscas.ac.cn'`。

**原因**（两层）：
1. `_fetchText` 的 `resp.transform(...).join()` 无任何数据侧超时——服务端
   hang 时永久挂起（Bug 421 同款死逻辑的第 3 处实例）；
2. 拉的是明文 Packages（8MB+），真机 20~50KB/s 下单镜像就要 5~10 分钟，
   逐镜像试完四个源轻松超过半小时。

**解决**（alpha.32）：拉 `Packages.gz`（~1.5MB，gzip.decode 解压）+
响应头 20s / Stream.timeout stall 15s 熔断 + filesDir 磁盘缓存回退
（全镜像失败用上次成功索引，旧版本可装不阻断）。

**教训**：`join()`/`listen` 的超时检查写在外面等于没有——凡是读流，
一律 `stream.timeout(stall)` 驱动；大文件先想"有没有压缩版本"。

### Bug 423：真机构建 pub TLS 持续失败（同源重试无效）

**症状**（2026-09-18 真机 alpha.31，my_demo 构建 4%）：exit 69，
`Got TLS error trying to find package archive at https://pub.flutter-io.cn`
重试 3 次全败（好消息：alpha.30/31 的清理锁+重试+分诊全部生效——
不再卡死、干净退出、给出可执行建议）。

**原因**：真机 50KB/s 弱网下到 pub.flutter-io.cn 的 TLS 握手**持续**
失败（丢握手包），同源重试 3 次每次都撞同一堵墙。

**解决**（alpha.32）：pub get 改多源轮换——io.cn → 清华 TUNA dart-pub →
中科大，每源 2 次；`break 2` 后 shell 变量 $src 保留成功源，
`export PUB_HOSTED_URL=$src` 供 build 内部自动 pub get 复用。

**教训**：网络重试要区分"瞬断"（同源重试有效）与"持续不可达"
（必须换源）；弱网下 TLS 握手是第一个牺牲品。

### Bug 424：多源轮换转义笔误——`$flutterCmd` 展开为空，`pub: not found` ×6

**症状**（2026-09-18 真机 alpha.33，my_demo 构建 19 秒即败）：

```
/bin/sh: 1: pub: not found     × 6（正好 3 源 × 2 次）
✗ 构建失败（exit 69）· 已运行 00:19
```

**原因**：Bug 423 的多源轮换是 shell 循环拼在 Dart 字符串里，写循环时
把 shell 循环变量（`\$src`/`\$ok`，**必须**转义否则 Dart 插值）和 Dart
侧的 flutter 路径混在同一行，顺手把 `\$flutterCmd` 也转义了——shell 里
没有这个变量 → 展开为空 → 命令变成 `PUB_HOSTED_URL=$src pub get` 裸跑，
`pub` 找不到，6 连败后 `exit 69`。末行的 build 命令用的是正确插值
（`$flutterCmd`），所以 bug 只在 pub get 段。

**为什么沙箱没拦住**：沙箱出包走本地 shell 直跑 flutter，不经过
BuildRunner；analyze 只查语法、test 是单测不真跑构建——shell 字符串
拼接的运行时行为只有真机执行才暴露（"我保证语法正确、真机验证"策略
的已知盲区）。

**解决**（alpha.34）：① `\$flutterCmd` → `$flutterCmd`（Dart 插值）；
② 命令拼接提取为 `BuildRunner.buildCommand()` 纯函数，新增
`build_runner_test.dart` 用文本断言固化转义边界（shell 变量必须保留
`$src`/`$ok` 形态、flutter 命令必须以字面出现）——这是沙箱能拦住此类
bug 的唯一层；③ shell 行为双分支模拟验证（假 flutter 函数：全败 6 次
exit 69 / 第 5 次成功后源保留复用）。

**教训**：同一行混用「shell 层变量」与「Dart 层值」时，逐个问
"这个值在哪一层产生"——shell 产生的必须转义（留 `$x` 给 shell 求值），
Dart 产生的必须插值；纯文本拼接的 shell 命令至少要有文本断言单测。

### Bug 425：容器无 CA 根证书——pub 对任何 https 源 100% 失败（真机三连卡 4%）

**症状**（2026-09-18 真机 alpha.33/34/35 连续三个版本）：构建卡 4%
（pub get 阶段）分钟级到 20 分钟，日志全是：

```
Got TLS error trying to find package archive at https://pub.flutter-io.cn
（随后清华、中科大源同样 TLS error——多源轮换六连败 → exit 69）
```

**根因**（解包 rootfs 实证）：debian minbase rootfs **不含
ca-certificates**——tar 内 `/etc/ssl`、CA 相关条目数为 **0**。dart 的
TLS 证书校验读系统根证书，一个都没有 → **任何** https 源握手必失败。
Bug 423 的多源轮换方向正确但对象错了：这不是"某个源不可达"，是
"所有 https 都不可信"。

**为什么三个信号共同掩盖根因**：
1. gradle 依赖解析正常——JDK 自带 cacerts（不读系统 CA），给人
   "容器 TLS 没问题"的假象；
2. apt 安装正常——debian 源走 http（Bug 419 时代配的镜像），
   根本不做 TLS；
3. 错误文案 `Got TLS error` 与弱网丢握手包**一模一样**，此前
   真机确实是 50KB/s 弱网（Bug 423 的真实案例），先入为主了。

**解决**（alpha.36，三层）：
1. `ToolchainEnsure.caCerts()` 构建前预检+自愈：已就位秒过 →
   apt 在线装 ca-certificates（http 源可用）→ apt 失败时把 App
   内置 Mozilla bundle（assets/ca/ca-bundle.crt，147 证书 220KB，
   随包分发）直接写进容器 `/etc/ssl/certs/`（rootfs 树宿主可见）；
2. proot 构建命令带 `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`
   双保险（dart 显式读此环境变量，默认路径探测偏差也能兜住）；
3. 分诊 hint 更新为"alpha.36 起自动确保根证书"语义。

**教训**：自建最小 rootfs 时列一份"TLS 栈清单"——CA 证书、时钟
（时间错导致证书 not-yet-valid）、DNS 解析；三个"看起来正常"的旁路
信号（JDK 自带 cacerts / http 源 / 弱网历史）叠加时，先怀疑共同
前提（系统级 TLS 材料），别在应用层（换源/重试）打转。

### Bug 426：init.gradle 仓库注入顶撞 Flutter 新模板 PREFER_SETTINGS——22% 配置 Gradle 必败

**症状**（2026-09-18 真机 alpha.36，Bug 425 修复后 pub get 已通、卡点
顺移到 Gradle 配置段 22%）：日志在配置阶段爆出：

```
Error resolving plugin [id: 'dev.flutter.flutter-plugin-loader', version: '1.0.0']
> Build was configured to prefer settings repositories over project
  repositories but repository 'maven' was added by settings file
（plugin-loader 解析失败 → 构建中断）
```

**根因**：真机容器 `/root/.gradle/init.gradle` 由工具链「一键应用」
写入（`MirrorConfigurator._initGradleContent()`），是**注入型**：
`allprojects { repositories { maven 阿里云×3 } }` +
`settingsEvaluated { pluginManagement/dependencyResolutionManagement
注入 }`。Flutter 新模板 `settings.gradle.kts`（app 模板自 alpha 起用
KTS 新形态）经 flutter-plugin-loader 走 **PREFER_SETTINGS** 仓库模式——
该模式拒绝任何 project 级仓库，`allprojects` 注入的 `maven` 仓正好
踩雷，报错里的 `'maven'` 就是注入仓的显示名。

**为什么沙箱没翻车**：沙箱构建机 `/root/.gradle/init.gradle` 早已是
**beforeSettings 前插形态**（只在 settings 仓库里加镜像仓、无
allprojects/settingsEvaluated）——settings 仓库正是被 prefer 的对象，
怎么加都不违规。同一套 skill 流程，沙箱正常、真机必败，差异只在
init.gradle 一份文件的形态。

**解决**（alpha.37，三层）：
1. `MirrorConfigurator.initGradleContent()` 重写为 beforeSettings
   前插版（方法一并公开）：与沙箱验证形态对齐，镜像仓前插最前命中
   即停，模板自带 google()/mavenCentral() 自动成为兜底；
2. `ToolchainEnsure.gradleInitSanitize()` 构建前自愈：检测容器
   init.gradle 含 `allprojects`/`settingsEvaluated` 特征 → 用新版
   覆写（host 直写 rootfs 树，与 caCerts 同 IO 路径）；自愈失败只
   记 warning 不阻断（用户可能已手动修正）；
3. 分诊 hint 新增 `prefer settings repositories` 条目（指向工具链页
   重跑「一键应用」）。

**验证**：新增 `mirror_configurator_test.dart` 文本断言（禁止
allprojects/settingsEvaluated 注入、必须 beforeSettings、镜像域名
齐全、无 project 级 repositories 裸注入——断言前剥离注释行，注释里
提关键词不算）。真机预期：22% 之后正常进入 Gradle 任务段。

**教训**：全局 gradle 钩子改仓库有两个安全形态（beforeSettings 前插
settings 仓 / 改写已有仓库 url），**allprojects/settingsEvaluated
注入是死路**——Flutter 新模板 PREFER_SETTINGS 一票否决。同一份
配置文件在沙箱与真机形态漂移时，"沙箱好的"不构成免检理由，要把
"形态差异"本身当作排查对象。

### Bug 427：Flutter 插件自动补装 NDK → sdkmanager 在 arm64 上 JIT SIGILL（真机 24% 崩）

**症状**（2026-09-18 真机 alpha.37，Bug 426 修好后的下一个卡点）：
「配置 Gradle」24% 崩，两次表现一致（首跑 2m36s、次跑 34s）：

```
FAILURE: Build failed with an exception.
* Where: Build file '/root/projects/my_demo/android/build.gradle.kts' line: 19
* What went wrong:
  A problem occurred configuring project ':app'.
  > Process 'command '/opt/android-sdk/cmdline-tools/latest/bin/sdkmanager''
    finished with non-zero exit value 132
    (this value may indicate that the process was terminated with the SIGILL signal)
```

**根因链**（三段）：
1. 报错行 `build.gradle.kts:19` 是模板的
   `subprojects { project.evaluationDependsOn(":app") }`——触发 :app 配置
   时崩，不是模板自身问题；
2. 崩的是 **Flutter gradle 插件主动调 sdkmanager**：
   `FlutterPluginUtils.forceNdkDownload()` 在 `finalizeDsl` 里判定
   「项目 `ndkVersion = flutter.ndkVersion`（默认 28.2.13676358）不在
   `installedNdkVersions` 中，且 `sdkManagerPath != null`、非 offline」
   → 执行 `sdkmanager --install "ndk;<版本>"` 自动补装 NDK；
3. **sdkmanager 在 Android arm64 上必崩**：它是 sh 脚本
   `exec "$JAVACMD" -classpath ... SdkManagerCli`，即起一个**标准 Linux
   JDK 的 JVM**——Linux 发行版 JDK 的 JIT 在 Android 内核/设备上会触达
   不支持的指令，SIGILL（132 = 128+4）。这与 sdkmanager 自身架构无关
   （它是脚本 + jar，架构无关），是 **JVM-on-Android** 的已知冲突。

**为什么沙箱没翻车**：沙箱构建机 `/data/user/work/sdk/ndk/28.2.13676358/`
**存在**（内含真 NDK + 改名后的 source.properties），插件第一步判定
"已装"直接 return，**从不调 sdkmanager**。真机工具链只装了四个组件
（platform-tools / platforms / build-tools / cmdline-tools），**没有 ndk
目录**——差异仅此一处，又是"沙箱与真机形态漂移"。

**解决**（alpha.38，两层）：
1. `AndroidSdkInstaller.ensureNdkStub()`：写入最小 NDK 占位——
   Flutter 只检查 `ndk/<version>/source.properties` **文件存在**
   （android_sdk.dart `hasNdkVersion`）+ 目录名即版本号（
   gradle.dart `_getInstalledNdkVersionsForGradle` 扫 ndk 子目录）。
   版本号从插件源码 `FlutterExtension.kt` 运行时解析（SDK 升级自动跟随）。
   **不下载 2.2GB 真 NDK**——demo 项目零 native 代码（无 CMakeLists），
   占位即可让插件跳过补装，也不把 NDK 工具链拖进包；
2. 双入口接入：工具链安装流程（licenses 之后）+ `ToolchainEnsure.ndkStub()`
   构建前自愈（兜住已装 SDK 的老用户，幂等）；分诊 hint 识别
   `exit value 132` / `sigill` / `sdkmanager` 指向本 Bug。

**验证**：shell 逻辑双分支模拟（首跑 NDK_STUB_OK / 二跑幂等
NDK_STUB_PRESENT / 解析出的版本 `28.2.13676358` 与插件源码一致）；
`build_runner_ndk_test.dart` 固化分诊识别（132 + sigill 两条）。
真机预期：24% 后进入 gradle 任务执行段（编译 + 打包）。

**教训**：Android 上跑 JVM 工具（sdkmanager / gradle daemon / kotlinc）
有一条隐性红线——**JIT 生成的指令设备可能不支持**（SIGILL），而这类
崩溃的报错位置（模板某行）与真因（三方插件自动补装行为 + JVM 环境）
相隔极远。排查手法：从报错**进程名**入手，反查"谁在什么条件下会调
它"（本例 `forceNdkDownload` 的三个前置条件），再对比沙箱与真机的
**目录形态差异**（ndk 目录有无）。另外：能"让工具判定已装"时，
就用最小桩替代真的去装——桩是可控的，自动补装不是。

### Bug 428：precache 覆写 qemu 转发脚本——AOT 编译段 SIGILL（真机 47% 崩）

**症状**（2026-09-18 真机 alpha.38，Bug 427 修复后推进到 AOT 编译段）：

```
Dart snapshot generator failed with exit code -4
impellerc failure:
Target android_aot_release_android-arm64 failed: Exception:
  AOT snapshotter exited with code -4
Target aot_android_asset_bundle failed: ShaderCompilerException:
  Shader compilation of ".../ink_sparkle.frag" ... failed with exit code -4
BUILD FAILED ... Running Gradle task 'assembleRelease'... 227.7s
```

**根因链**（三段）：
1. `exit code -4` = SIGILL（128+4）。**两个不同工具**（`gen_snapshot`
   AOT 编译器 + `impellerc` shader 编译器）同时挂、同一信号 →
   强烈指向**架构不匹配**而非工具自身 bug；
2. 实证架构：`android-arm64-release/**linux-x64**/gen_snapshot` 与
   `linux-x64/impellerc` 均为 **x86-64 ELF**。路径里的 `linux-x64`
   = **运行在 x86_64 宿主上**。这是 Flutter 官方长期现状（02 号文档
   §7.1 已记录：Android gen_snapshot 全平台只有 x64 宿主版，
   `flutter_cache.dart` 的 `_linuxBinaryDirs` 硬编码只下 `linux-x64`）；
3. arm64 真机必须靠 **qemu 转发**（本仓库 `QemuCompat` 兼容层已有此
   设计）。但 `artifacts.dart` L510-521 只对 **darwin_arm64** 做了 x64
   回退、**linux_arm64 没有**（上游 TODO: flutter/flutter#152281），
   于是 arm64 宿主上 Flutter 去 `linux-arm64/` 找 gen_snapshot——而
   **`flutter precache` 会往该目录写它下载的真 x64 二进制**，
   **覆盖掉兼容层先前放的 qemu 转发脚本**。

**触发条件（真机实证）**：用户"**先应用 x64 兼容层、后下载 SDK**"——
工具链卡片当时验证通过（"gen_snapshot 冒烟通过"），但后续 precache
把 `linux-arm64/` 的转发脚本冲掉，构建时跑到真 x64 二进制 → SIGILL。

**为什么旧逻辑修不回来**：包装脚本用
`[ -f "$w" ] || gen "$w" "$f"` 判定——**「文件存在」即跳过**。precache
覆写后文件**存在但内容是错的**，重应用兼容层也永远跳过 → 永久卡死。
（幂等设计的反面：应判定"是否已是我们的产物"，而非"是否存在"。）

**附带发现**：工具链卡片的 `GEN_SNAPSHOT` 冒烟检查也有漏洞——它只查
输出里有无 `cannot execute`/`Exec format` 字样，而 **SIGILL 是运行时
崩溃、输出为空**，被误判成"通过"，掩盖了问题。

**解决**（alpha.39，两层）：
1. **判定修正**：`engineWrapScript` / `_flutterWrapScript` /
   `_sdkWrapScript` 全部改为「`head -c 2` 是否为 `#!`」判定——已是
   转发脚本才跳过，被覆写/不存在则重建；
2. **构建前自愈**：新增 `ToolchainEnsure.qemuCompatEnsure()`——检测
   `linux-arm64/gen_snapshot` 是否仍为脚本形态，失效则幂等重建
   （`engineWrapScript` 由私有转公开供复用）；BuildRunner 接入
   （CA/init.gradle/NDK 之后）。冒烟检查同步修正（空输出或
   rc ≥ 128 判为未就位）。

**验证**：shell 四场景模拟（全新 WRAPPED=1 / 幂等重跑 =0 /
precache 覆写后 =1 恢复为 `#!` / **旧逻辑同场景 =0 修不回来**）；
`qemu_compat_test.dart` 固化（禁止 `[ -f "$w" ] || gen` 回归、
必须 `#!` 检测、分诊识别 `exit code -4` 三种日志形态）。

**教训**：这是**同一模式第四次重演**——"环境会被后续操作覆写，必须在
构建前重新确保"（Bug 425 CA 证书 / Bug 426 init.gradle / Bug 427 NDK
占位 / Bug 428 转发脚本）。凡是"点一次按钮配好环境"的设计，
都要问一句：**后续哪个操作会把它冲掉？** 另外：幂等判定必须
校验**产物内容特征**，`[ -f ]` 这种"存在性"判定在可被覆写的场景里
是错误的不变量。

### Bug 429：只包装"引擎层"漏了"顶层宿主工具"——impellerc shader 编译 SIGILL（真机 84.2s 崩）

**症状**（2026-09-18 真机 alpha.39，Bug 428 修复后）：

```
Running Gradle task 'assembleRelease'... 84.2s
Dart snapshot generator failed with exit code -4
Shader compilation of ".../ink_sparkle.frag" ... failed with exit code -4
BUILD FAILED in 1m 23s
```

**用户反馈原话（本次的关键）**：

> 报错，这个它要用的东西不能全自动设置好吗？万一用户有什么新东西调用会不会还报错

这句话精准指出 Bug 428 修复的**方法本身**有问题——不是"这次漏了哪个文件"，
而是"**点名检查**"这个策略必然持续漏。

**根因**：Flutter 引擎的 x64 宿主工具分布在**两个层次**：

| 层次 | 路径 | 内容 | Bug 428 是否覆盖 |
|---|---|---|---|
| 引擎层 | `android-*/linux-x64/` | 每个 ABI 各一份 `gen_snapshot`（6 个） | ✅ 已覆盖 |
| **顶层宿主层** | `linux-x64/`（引擎根下） | `impellerc`、`font-subset`、`flutter_tester`、`gen_snapshot`、3 个 `.so`（7 个） | ❌ **从未包装** |

`artifacts.dart` 的 `HostArtifact.impellerc` 取
`engineDir/<hostPlatform>/impellerc` → arm64 宿主解析为
`linux-arm64/impellerc`。该目录在未做宿主层包装时不存在这些工具，
**shader 编译直接 SIGILL**（`impellerc` 正是 ShaderCompilerException
的元凶，与 AOT snapshotter 是两个独立工具、同时挂）。

**为什么 Bug 428 的修法没能覆盖**：`qemuCompatEnsure` 的检查是
**点名式**的——只查 `linux-arm64/gen_snapshot` 一个文件。工具集一变
（或用户用了之前没碰过的功能，比如首次触发 shader 编译），就再次漏。

**解决**（alpha.40，改为全量校验）：

1. `engineWrapScript` 增加**顶层宿主工具目录**包装段：
   `for hd in "$E"/linux-*/` → `ha="${hd%/linux-x64}/linux-arm64"`，
   同样按 `#!` 判定、同样幂等；
2. `ToolchainEnsure.qemuCompatEnsure()` 重写为**全量比对**，三层遍历：
   - 引擎层 `android-*/linux-x64` → `android-*/linux-arm64`
   - 宿主层 `linux-x64` → `linux-arm64`
   - SDK 层 `build-tools/*`、`platform-tools`（原地 `.foa-real` 制）
   
   对每个 x86_64 ELF（魔数 `7f454c46` + `e_machine=3e`）校验其对应
   `linux-arm64/` 同名文件存在**且 `#!` 开头**；输出 `n=`/`ok=`/`miss=`
   统计，任一不就位则整层重建并复核。
3. 关键设计原则落为测试：**禁止点名清单，必须通配遍历**
   （`qemu_compat_test.dart` 有反向断言——出现
   `for X in (gen_snapshot|impellerc|...)` 即判失败）。

**实证**（沙箱 `bug429_sim.sh`，真实引擎目录结构）：

```
android-*/linux-x64 层：6 个
顶层 linux-x64 层（新增覆盖）：7 个  ← impellerc 在此
合计：13 个 x64 宿主工具全部纳入包装
```

**教训（本 Bug 最有价值的部分）**：Bug 428→429 连续两次翻车，
说明**"逐一点名"的检查/修复策略在开放集合上必然失效**。
正确姿势是把不变量写成**全称命题**：

> 对 `linux-x64/` 下**每一个** x86_64 ELF，`linux-arm64/` 里必须
> 存在同名 `#!` 转发脚本。

这样 Flutter 未来新增任何宿主工具（乃至用户从未用过的功能触发的新
工具）都会自动纳入，无需预见。**用户那句"万一用户有什么新东西调用
会不会还报错"正是这个道理**——答案是"会，如果还在点名的话"。

---

### Bug 430：没有可交互终端——PTY 缺失导致诊断只能靠截图猜

**症状**（2026-09-18 用户反馈）：

> 真机容器内，那个app终端好像还没有可交互执行命令的界面

排查确认：原「终端」页是**预设命令跑批**（`hello` / `系统` /
`发行版` / `apt` / `身份` 五个 ChoiceChip + 运行按钮），只能一次跑一条
固定命令。**这不是终端**。

**实际代价**：Bug 425→429 的排障过程中，每一次都只能请用户截图，
再根据屏幕文字猜根因。有 4 次因为无法在设备上直接执行
`ls`/`readelf`/`strace` 而多绕了弯路（`tools/diag_428.sh` 写好了
却没地方跑）。

**技术难点**：Android/JVM **没有 pty API**——`ProcessBuilder` 只能给出
单向管道，拿不到 tty；JNI 也没暴露 `posix_openpt`。于是 `apt` 进度条、
`vim`/`top` 全屏程序、Ctrl+C 中断、方向键历史、tab 补全全部失效。

**解决**（alpha.40，三层）：

1. **C 中继器 `platform/android/pty/foa_pty.c`**（约 10KB，纯 bionic，
   只依赖 `libc.so`/`libdl.so`，随 APK 分发）：
   ```
   Java(ProcessBuilder) ──pipe──▶ foa_pty ──pty──▶ proot / 宿主 sh
   ```
   用 `openpty()` 建真 tty，把本进程 stdin/stdout 与 pty master 双向对接。
2. **原生会话层 `platform/android/PtySession.kt` + MainActivity 五方法**
   （`ptyStart`/`ptyWrite`/`ptyPoll`/`ptyStop`/`ptyResize`）；
3. **UI 换用 `xterm` 包**（完整 VT100 仿真）：`terminal.write()` 灌输出、
   `onOutput` 接按键、`onResize` 报尺寸。软键盘补齐 Ctrl+C/D/Z、
   Esc、Tab、四个方向键、`/ - ~` 常用符号。

**做 shim 时踩的四个坑**（全部已固化为测试，因为沙箱是 x86_64 跑不了
真机 APK，只能靠静态契约防回退）：

| 坑 | 现象 | 正解 |
|---|---|---|
| `c_cc[]` 未赋值 | `stty -a` 显示 `intr = <undef>`，屏幕回显 `^C` 但 `sleep` 照睡 | 显式填 `VINTR=0x03`/`VERASE=0x7f`/`VEOF=0x04` 等 |
| 会话首进程上再 `setpgid(0,0)` | 返回 EPERM 被当致命 → 终端一启动就退出（rc=120） | `setsid()` 后**不要**再 `setpgid` |
| 父进程 `setpgid(child, child)` | 子进程成进程组组长 → 子进程 `setsid()` 失败 → rc=120 | 父进程不插手子进程的会话/进程组 |
| 中继进程未忽略 SIGINT | 按一下 Ctrl+C 整个终端崩掉（BrokenPipe） | `signal(SIGINT/SIGQUIT/SIGTSTP, SIG_IGN)` |

**尺寸热更新**：master fd 只在 shim 手里，Java 改不了 winsize；stdin 内联
控制序列又会污染用户输入。故用**控制文件** `FOA_PTY_SIZE_FILE`
（内容 `"<rows> <cols>"`）+ 主循环 `poll(..., 200)` 超时检查，
变化即 `ioctl(TIOCSWINSZ)`。实测 `stty size` 从 `24 80` → `31 120`。

**验证**：`tools/build_pty_shim.sh --verify` 五项目测
（真 tty / 退出码透传 / exec 失败 127 / 尺寸透传 / `intr=^C`）全过；
Ctrl+C 中断实测（发 0x03 后 `sleep 30` 立即被打断，shell 存活）；
`test/pty_terminal_test.dart` 28 项契约测试。

---

### Bug 431：字号缩放"功能有、发现不了"——用户以为要出教程

**症状**（2026-09-18 用户反馈）：

> "代码编辑器"页面只有一个手指不动一个手指动的时候才能"放大/缩小"
> 我感觉这得单独出个教程告诉用户了（）

**排查结论（与直觉相反）**：功能**早就完整存在**——alpha.32 就做了
双指捏合缩放、`A−`/`A+` 步进按钮、点中间数字恢复默认，且全部持久化
（`EditorFontPrefs`）。tooltip 里甚至写了"双指捏合亦可"。

**真正的问题是可发现性**：
- 按钮图标只有 **14px**、颜色 **`Colors.grey`**（低对比）；
- 水平内边距仅 **5px**，实际可点区域远小于 44px 的最小触控尺寸；
- 状态栏总高只有 24px，视觉上完全被 `A− 14 A+` 淹没。

用户那句"一个手指不动一个手指动"其实就是**系统级无障碍缩放手势**，
说明他压根没看到编辑器自己的入口——**这不是用户不会用，是我们没让人看见**。

**解决**（alpha.40 入口改进，两处，都不是"写教程"）：
1. **把入口做显眼**：图标 14→**17px**、颜色 `Colors.grey`→
   **`Colors.grey.shade300`**、内边距 5→**8px**；新增**到达上下限时
   变暗**（`shade700`）——避免用户反复点击却无反应；
2. **首次进入给一次性提示**（新增 `HintPrefs` 一次性标记）：
   > 字号调节：点底部状态栏的 A− / A+ 即可；双指捏合也能缩放，
   > 戳中间数字可恢复默认。

   带「知道了」关闭入口，只弹一次，先写标记再弹窗（用户秒退也
   不重复打扰）。

**为什么选"提示"而不是"教程"**：需要让用户去读的教程，本身就是设计
失败的补丁。把功能放到用户视线里 + 首用时一句话点明，成本低得多，
也不会被忽略。

**教训**：**"功能存在"与"功能可用"是两件事**。自查清单——
入口的**尺寸**（是否 >= 44px 触控区）、**对比度**（是否淹没在背景里）、
**位置**（是否在用户会看的地方）、**首次可发现性**（用户第一次
打开能不能自己找到）。回顾性验证：把截图缩小到手机实际尺寸看，
14px 灰色图标确实找不到。

> ⚠️ **本条记录后来被证伪了一半**：用户随后澄清"是双指，但是只有
> 上下有效果，左右没效果"。详见 Bug 432——真正的问题是**双指上下
> 滑动被误判成缩放**，与可发现性无关。上面的入口改进仍然有效，
> 但"功能早就完整存在"这个判断是错的。

### Bug 432：双指上下滑动被误判成字号缩放——`ScaleUpdateDetails.scale` 是各向同性的

**症状**（2026-09-18 用户两次反馈，第二次为澄清）：

> 第一次："刚刚的代码编辑器其实是上下划可以放大缩小，左右不可以，
> 和几根手指没关系好像。"
> 第二次澄清："**不是单指，是双指**，但是只有上下有效果，左右没效果。"

**关键教训（先记在前面）**：我第一次把症状理解成"单指上下滑"，
并据此写了同构测试证明"单指不会改字号"，**结论正确但答错了题**。
用户的"和几根手指没关系"是在说"不是手指数的问题"，我却理解成
"单指也能触发"。**症状里的每一个限定词都要当成约束读，不要替
用户简化**。第一次就该直接问"是几根手指"，而不是猜。

**根因**：`ScaleUpdateDetails.scale` 是**各向同性**的欧氏距离比。

```dart
// flutter/lib/src/gestures/scale.dart
double get _pointerScaleFactor => _initialSpan > 0.0
    ? _currentSpan / _initialSpan : 1.0;

// _update() 里 span 的定义：各指到质心的 hypot 距离的平均
_currentSpan = count > 0 ? totalDeviation / count : 0.0;
// totalDeviation += (pointerFocalPoint - _pointerLocations[pointer]!).distance;
```

span 用的是 **`Offset.distance`（hypot，欧氏距离）**，不是轴向距离。
于是：双指自然持机时两指在 **y 轴错开**（一上一下）。上下滑动过程中
两指不可能完全同步（人手指、触摸采样都有先后），这个 y 向异步
**直接改变两指间的 hypot 距离** → `scale` 偏离 1.0 → 字号被改。

**数值验证**（复刻 Flutter 的 span 公式，值得记住这组数字）：

| 双指排列 | 起点 span | 滑动异步 2px | 异步 10px |
|---|---|---|---|
| **竖直排列**（一上一下，自然持机） | 53.85 | 漂移 **1.72%** | 漂移 **8.56%** |
| **水平并排** | — | 漂移 0.70% | 漂移 3.81% |

竖直排列对 y 向异步的敏感度是水平并排的 **2.2 倍**——这就是为什么
**上下划"有效果"、左右划"没效果"**。方向本身不特殊，特殊的是
"两指在哪个轴错开"与"往哪个轴滑动"的组合。

**排查过程的三个弯路（都是方法问题，值得复盘）**：

1. **同构测试证明不了真机行为**：写了逐行复刻 `onScaleStart/Update`
   判定的测试，结论是"单指不改字号"。测试没错，但它验证的是
   *我理解的症状*，不是*用户描述的症状*。**先确认症状，再写测试**。
2. **`startGesture` 连环按下测不出多指手势**：第一个指头在第二指
   按下前就被判成单指拖并抢走手势，四种方向全 0 次回调。改用
   手动派发 `PointerEvent`（精确控制每个事件的时间戳与顺序）
   才复现出真实行为。
3. **`scale` 的抖动幅度太小、容易被当成噪声**：探测输出里
   `scale` 在 `1.000 ↔ 1.005` 之间横跳，第一眼像浮点噪声。
   实际它对应 0.5% 的字号漂移——**放大到 token 级视觉就是可见的
   字号变化**。判据是"最终字号是否变了"，不是"倍率看着大不大"。

**修复**（alpha.41）：改用**轴向倍率** + **间距阈值**双重把关。

```dart
onScaleUpdate: (d) {
  if (!_scaleActive || d.pointerCount < 2) return;
  // 不再使用 d.scale（各向同性欧氏比，会被滑动异步污染）
  final fx = d.horizontalScale;   // 只有横向间距变化
  final fy = d.verticalScale;     // 只有纵向间距变化
  final dx = (fx - 1.0).abs();
  final dy = (fy - 1.0).abs();
  if (!_scaleEngaged) {
    if (dx < _kSpanSlop && dy < _kSpanSlop) return;  // 平移，放行
    _scaleEngaged = true;
  } else if (dx < _kSpanSlop * 0.5 && dy < _kSpanSlop * 0.5) {
    // 间距回到基准附近 → 刚才只是异步尖峰，撤销缩放
    _scaleEngaged = false;
    if ((_fontSize - _scaleBase).abs() >= 0.5) {
      setState(() => _fontSize = _scaleBase);
    }
    return;
  }
  final factor = dx >= dy ? fx : fy;   // 取真正在"捏"的那个轴
  final v = (_scaleBase * factor)
      .clamp(EditorFontPrefs.min, EditorFontPrefs.max);
  if ((v - _fontSize).abs() >= 0.5) setState(() => _fontSize = v);
}
```

**为什么需要 `_kSpanSlop = 0.15`（15%）**：纯滑动时轴向间距理论上
不变（=1.0），但真机总有异步。实测两指异步 10px 时轴向倍率偏移
约 10%，15% 阈值刚好把它挡在门外，同时不影响正常捏合
（捏合时间距变化动辄 50%+）。**这个阈值不能更小**：低于 10%
会把正常滑动判成缩放，正是原 bug。

**为什么需要"回位撤销"分支**：`_scaleEngaged` 一旦为真就锁存，
若某帧出现异步尖峰（比如先放一指再放另一指，错开起手）越过阈值，
后续所有帧都会按 factor 改字号——手指回位后字号又弹回基准，
用户看到"闪一下"。回位检测（间距回到 <50% 阈值）把它判为
滑动意图并撤销，彻底消除闪烁。

**验证**：`test/editor_scale_direction_test.dart`（14 项）——
四个平移方向（上下/左右/斜向/极端 10px 抖动）**必须**不改字号；
三种真实捏合（横向拉开/纵向拉开/横向收拢）**必须**改字号；
单指两个方向一律不改；回位必须还原；捏合中途微抖不得撤销；
外加 4 项源码接线检查（防止后续重构退回 `d.scale` 写法）。

**可迁移的结论**：

| 反模式 | 正确做法 |
|---|---|
| 用各向同性的 `scale` 驱动单向缩放 | 用 `horizontalScale`/`verticalScale` 轴向分量 |
| 只判 `pointerCount >= 2` 就认捏合 | 还要判**间距确实变了**（阈值门） |
| 手势一旦被判为缩放就锁死 | 加**回位检测**，允许撤销误判 |
| 凭症状想象写测试 | 先把症状的每个限定词确认清楚 |

### Bug 433 ①：pub get 在 build 前盖掉转发层——AOT 跑到 54% 后 shader 编译 SIGILL

**症状**（2026-09-19 真机截图）：

```
C AOT 编译 (gen_snapshot)   54%
Dart snapshot generator failed with exit code -4
".../flutter_assets/shaders/ink_sparkle.frag" failed with exit code -4.
BUILD FAILED in 1m 30s
```

**与 Bug 429 的区别（同一个 SIGILL，不同的触发时机）**：
Bug 429 是「**从未包装**顶层宿主工具层」——前置检查就该拦住。
这次前置检查**全过**（否则 build_runner 会提前 return），却仍在
54% 崩，说明包装在检查之后、编译之前**被覆盖了**。

**根因**：`buildCommand` 的执行序列是

```
flutter pub get   ← 先跑（多源轮换重试）
...
flutter build apk ← 后跑
```

`pub get` 在依赖状态变化时会触发 Flutter 的**构件重新下载**，把
`linux-arm64/<tool>` 写回真 x64 二进制（上游 `artifacts.dart` 未对
`linux_arm64` 做 x64 回退，flutter/flutter#152281）。于是
`qemuCompatEnsure` 刚放好的转发脚本被覆盖 → shader 阶段的 `impellerc`
变成真 x64 ELF → arm64 上 SIGILL → exit -4。

**教训**：「构建前检查」挡不住「构建过程中被改」。检查点与使用点
之间有别的动作时，**必须在紧邻使用点处再断言一次**。这是 Bug 429
那条「点名检查 vs 全称命题」的姊妹教训——**时序**维度上的同类错误。

**修复**：新增 `QemuCompat.wrapReassertScript`（压缩版，无 precache
分支——前置检查已确保构件存在），把它内联进 `buildCommand`，位置在
`pub get` 之后、`flutter build` 之前，**同一条 shell 命令里**：

```dart
'sh -c ' + _shq(reassert) + ' 2>&1 | tail -n 2; '
'$flutterCmd build apk --no-shrink --release ...'
```

输出 `REASSERT=<n>`（n=本次修复的文件数），便于构建日志确认生效。

**踩坑一（转义）**：写这个脚本时外层变量误用了 `\$`。Dart 原始字符串
`r'''...'''` 里 `\$` 是**两个字符**（反斜杠 + 美元），会原样传给
shell → dash 报 `Syntax error: "(" unexpected`。规则：
**外层脚本变量用裸 `$`；只有 heredoc 内（要写进转发脚本的）才用
`\$`** 让 shell 在写入时还原。已由单测固化（对比两个脚本的转义风格）。

**踩坑二（分组）**：最初用 `{ $reassert ; } 2>&1 | tail -n 2;` 想只保留
尾部输出，结果脚本末尾带换行时 `\n ; }` 在 dash 和 bash 下**都**报
语法错（`syntax error near unexpected token ';'`）。改用
`sh -c '<脚本>'` 独立执行，并加 `_shq()` 把内部单引号转义成 `'\''`。
教训：**shell 里 `{ ... ; }` 不是"把这段括起来"，它对结尾分隔符有
硬要求**；要复用一段完整脚本，`sh -c` 才是稳的。

**验证**：`test/bug433_build_and_terminal_test.dart` —— 断言再断言
出现在 pub get 之后 / build 之前、不引入新的 pub get、覆盖两个目录层、
按 `#!` 幂等、转义语义正确、用 `sh -c` 而非 `{ ... ; }` 分组。
另用仿真引擎目录实跑：把三个 `linux-arm64/` 文件替换成真 x64 二进制后
跑脚本 → `REASSERT=5`，五个文件全部恢复为转发脚本，且重跑
`REASSERT=0`（幂等）。**真实引擎上跑出 `REASSERT=13`**（13 个 x64
宿主工具全部被正确包装），重跑 `REASSERT=0` 再次确认幂等。

---

### Bug 433 ②：终端永久停在「正在启动终端…」——截断 argv 时残留孤立 `/bin/sh`

**症状**（2026-09-19 真机截图）：终端页转圈不动，只有「正在启动终端…」，
没有任何输出或报错。

**根因**：`ptyStart`（proot 模式）要构造一个**交互式** shell，而
`buildProotCmd` 产出的是 `... /bin/sh -c "<boot><command>"` 形式。
原代码截掉 `-c` 之后的部分：

```kotlin
val tailIdx = base.indexOfLast { it == "-c" }
val head = if (tailIdx > 0) base.subList(0, tailIdx) else base
```

`subList(0, tailIdx)` **只截到 `-c` 之前**，把紧邻其前的 `/bin/sh`
留在了 `head` 末尾。重新拼接后真正传给 proot 的 argv 是：

```
proot -0 -r /rootfs ... /bin/sh  /usr/bin/env -i HOME=/root ... /bin/sh -c "boot; exec /bin/sh -i"
                              ^^^^^^^^ 孤立残留
```

外层 sh 于是把 `/usr/bin/env` 当成**脚本文件路径**去执行（还把它后面的
参数当作位置参数）。必然起不来，PTY 里没有任何输出 → 界面永久转圈。

**修复**：截 `-c` 时把紧邻其前的 `/bin/sh` 一并截掉：

```kotlin
var headEnd = if (tailIdx > 0) tailIdx else base.size
if (headEnd - 1 >= 0 &&
    (base[headEnd - 1] == "/bin/sh" || base[headEnd - 1].endsWith("/sh"))) {
  headEnd -= 1
}
val head = base.subList(0, headEnd)
```

**附带加固（防同类问题再次表现为"无声转圈"）**：`ptyStart` 调用加
45 秒超时（原先**没有任何超时**，原生侧一旦卡住 Dart 就永远 await），
超时后给出可读诊断而非继续转圈；`_pickBackend`（读偏好文件，同样在
启动路径上）加 10 秒超时兜底。

**教训**：**argv 拼接这类"删一段再接一段"的操作，边界要按"参数组"
而不是"单个 token"来切**。`-c` 从来不是独立出现的，它总是带着
前面的解释器路径。同类风险点：任何 `indexOf` + `subList` 的组合，
都要问一句"我要删的是一段协议，还是一个词"。

**另一个教训（观测性）**：这个 bug 的难查之处在于**没有任何错误输出**。
凡是异步启动路径，都应该有超时 + 可读失败态。**沉默的转圈是最贵的
bug 形态**——用户只能截图，开发者只能猜。

---

### Bug 434：x64 兼容层卸载失败——`PURGE_FAILED rc=100`

**症状**（2026-09-19 真机截图）：

```
x64 兼容层卸载失败：PURGE_FAILED rc=100
E: Essential packages were removed and -y was used
   without --allow-remove-essential.
```

**先说好消息**：`PURGE_FAILED rc=100` 这行**是我们自己的兜底在正常工作**。
上一轮修 Bug 429 时把 `purge ... | tail || true` 改成了显式捕获退出码，
所以这次失败被如实报出来了。在此之前，同样的情况会**静默假成功**——
用户以为卸干净了，实际 qemu 还在，兼容层还在拦工具链。**这个报错本身
是一次观测性修复的兑现。**

**根因**：卸载脚本原本一条命令批量删：

```sh
apt-get purge -y -qq qemu-user-static libc6:amd64 libstdc++6:amd64 \
  libgcc-s1:amd64 zlib1g:amd64 libatomic1:amd64
```

apt 的依赖求解逻辑是：`qemu-user-static` 被标记删除后，那些
`:amd64` 运行库就变成**「随它一起装进来的、没有别的主人的依赖」**，
于是被**级联删除**。而宿主是 arm64 + amd64 外来架构的混装状态，
在这套视角下 `libc6` 属于 **essential 包**，`-y` 不允许删 essential
→ apt 整体拒绝 → rc=100。

**一半成功比彻底失败更麻烦**：apt 中途失败**不回滚**。当时 qemu 本体
已经被删了一部分，运行库有的删了有的没删，最终状态是个半拉子——
既不是"装着"，也不是"卸了"。用户看到报错，但真实状态无法从报错
推断。

**修复**：拆成三步，让每步的失败语义独立。

```sh
# ① 只 purge qemu 本体（不带 :amd64 运行库）
apt-get purge -y -qq qemu-user-static > /tmp/foa_purge.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then
  echo "PURGE_FAILED rc=$rc"; tail -n 15 /tmp/foa_purge.log; exit 2
fi
# ② 运行库逐个删，单个失败只记录不中断
libs_fail=""
for p in libatomic1:amd64 zlib1g:amd64 libgcc-s1:amd64 libstdc++6:amd64 libc6:amd64; do
  dpkg -l "$p" 2>/dev/null | grep -q '^ii' || continue
  if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$p" >> /tmp/foa_purge.log 2>&1; then
    libs_fail="$libs_fail $p"
  fi
done
[ -n "$libs_fail" ] && echo "PURGE_LIBS_PARTIAL:$libs_fail"
[ -x @QEMU@ ] && { echo QEMU_STILL_PRESENT; exit 3; }
dpkg --remove-architecture amd64 2>/dev/null || true
echo UNINSTALL_OK
```

关键点：
- **运行库删不掉不是致命错误**，它们可能被别的包依赖；兼容层是否
  卸干净，判据是「**qemu 本体没了 + 转发层已还原**」（后者由脚本前段
  完成），与运行库残留无关。
- Dart 侧判定相应调整：`PURGE_FAILED` / `QEMU_STILL_PRESENT` 抛异常，
  `PURGE_LIBS_PARTIAL` **只写 stderr 提示保留清单**。否则"卸不干净"
  会被误报成"卸载失败"，用户又要怀疑没生效——**观测性修复不能反过来
  制造误报**。
- 逐个删之前先 `dpkg -l | grep -q '^ii'` 探测，跳过未安装的包（对未装
  的包 purge 会返回非零，会污染 `libs_fail`）。

**教训一（apt 多架构）**：**多架构环境下 `apt purge` 的包列表顺序与
分组不是中性的**。promote 成「一条命令批量删」会把无主依赖推断放大成
级联删除，进而踩 essential 保护。凡是跨架构删包，都要先想清楚"删掉
这个之后，谁变成无主"。

**教训二（失败原子性）**：`apt` 这类包管理器**失败不回滚**，所以
"一条大命令"的失败态是**未知的中间态**，无法写进文档、无法让用户
照着排查。把操作拆成**语义独立的小步**，每步要么干净成功要么干净
失败的，才谈得上可诊断。这与 Bug 433 ① 的教训同源——**都是"把多个
动作捆在一个原子单元里"惹的祸**，一个捆在 shell 命令里，一个捆在
apt 事务里。

**验证**：`test/bug434_uninstall_test.dart`（10 项）——断言 purge 命令
不混运行库、运行库走逐个循环、循环体内不含 `exit`、`exit 2` 只属于
qemu 本体失败路径、`PURGE_LIBS_PARTIAL` 不触发异常而走 stderr 提示。

**注**：本想用 arm64 容器真机复现 rc=100，但沙箱内容器访问不了
Debian 源（`qemu-user-static` 装不上），宿主加 arm64 外来架构后
镜像源返回 404。已在 x86_64 容器里复现到 `OLD_RC=100`（机制确认），
完整链路待真机验证。**复现环境受限时，明确区分"机制已确认"与
"端到端已验证"，不要混为一谈。**

---

### Bug 435：清理数据重装后构建报 `E: dpkg was interrupted`

**症状**（2026-09-19 真机截图，构建中断于「准备构建环境」0%）：

```
✗ 自动安装 git 失败：
E: dpkg was interrupted, you must manually run
   'dpkg --configure -a' to correct the problem.
```

**这是 Bug 434 的下游后果。** 卸载兼容层时 apt 在 essential 拒绝下
中途失败 → dpkg 数据库留下未完成事务 → 之后**任何** apt 调用都被
拦下，**包括 `apt-get update`**。用户"清理数据重装"后发现构建还是
不行，看起来像新 bug，其实是一条因果链。

**真正的缺陷不在"有没有自愈代码"**——`AptTools.ensure` 里早就写好
了三步自愈，是 Bug 409 加的。问题在于：

> **自愈只加在了我想到的那条路径上。**

`ToolchainEnsure.git()` 直接 `apt-get update && apt-get install git`，
**没有**自愈。于是同一个故障在 git 路径上原样重现，而且报错文案指向
git ——用户完全不可能顺着"自动安装 git 失败"去想到 dpkg 状态有问题。
**错误信息指错了方向，比没有错误信息更浪费时间。**

**修复**：

1. 把 `AptTools.ensure` 里内联的三步自愈抽成公共常量
   `AptTools.repairDpkg`（清锁 → `dpkg --configure -a` → `apt-get -f install`），
   `ensure` 改为引用，**消灭两份会各自漂移的实现**。
2. `git()` 在 apt 之前先跑 `repairDpkg`；自愈本身失败**不放弃**安装
   （仍给一次机会，避免"修复命令挂了所以什么都装不了"这种更差结果）。
3. 原先 `apt-get update && apt-get install git` 用 `&&` 串联，dpkg
   中间态下 update 一失败 install 根本不执行，报错还停在 update 输出上。
   改为**换行分隔的两条独立命令**（Bug 404 同款：行尾换行，不能用行首 `;`）。
4. 安装成功判定改用显式哨兵 `GIT_INSTALLED`，不再只看退出码
   （proot exec 的退出码语义不可靠，Bug 404 起已确立此规约）。
5. 失败文案**带上真因和自救手段**：
   `（已尝试自动修复 dpkg 中断状态；仍失败可到「终端」手动执行 dpkg --configure -a 后重试）`

**教训一（全称命题，第三次出现）**：Bug 429 是"要检查**全称**而非点名"，
Bug 433 ① 是"检查点与使用点之间**时序**上还会有别的动作"，这次是
**"我在某处修过"≠"所有执行路径都被修复"**。三者同源：**都要问一句
"这个前提，是不是在所有该成立的地方都成立了"**。凡是调用 apt 的地方
都是"dpkg 状态干净"这个前提的消费者，前提必须在**每条路径**上成立。

**教训二（错误信息的指向性）**：`自动安装 git 失败` + `dpkg was
interrupted` 这两句话放在一起，用户的注意力必然被"git"吸走。**报错
文案指向的位置，必须是真的要动手的位置**。做不到时，至少要把真因
一并列出。

**验证**：`test/bug435_dpkg_interrupted_test.dart`（12 项）——断言
`repairDpkg` 三步齐全、每步不阻断后续、`ensure` 改为复用常量（不再有
第二份内联副本）、`git()` 里自愈位置早于 `apt-get update` 与
`apt-get install`、自愈与安装之间无 `return`/`throw`、update 不与
install 用 `&&` 串联、成功判定用哨兵、失败文案包含 `dpkg --configure -a`。

**写测试时的坑**：`git()` 体**注释里**为解释本 bug 提到了
`apt-get update` / `apt-get install` / `return`，导致 `indexOf` 和
`firstWhere` 全部命中注释，三条断言反向失败。**定位代码位置的断言
必须先剔除注释行**——这个坑在 Bug 432 的测试里也踩过一次，
是同一类错误的第二次出现。

---

### Bug 436：构建卡在「准备构建环境」并报 `fetch --tags` / HTTP 504

**症状**（2026-09-19 真机）：构建长时间停在 4%，日志出现

```
Command exited with code 128: fetch --tags
Standard error: error: RPC failed; HTTP 504 curl 22
fatal: the remote end hung up unexpectedly
```

用户追问："为什么之前的版本不会卡在这里，而且比以前慢好多，是不是
没设定国内镜像源？"

**第一件事：先排除最像的嫌疑人。** 直觉上这是镜像配置问题，实测**不是**：

- `git ls-remote --get-url origin` 确认 URL 重写**已生效**，指向 gitclone 镜像；
- 直接 curl 该镜像的 `info/refs`：**HTTP 200 / 1.6s**，服务正常。

**真因是 flutter 工具自身的版本新鲜度检查**：

```dart
// packages/flutter_tools/lib/src/version.dart
static const checkAgeConsideredUpToDate = Duration(days: 3);
```

距 `flutter_version_check.stamp` 里记录的上次检查超过 **3 天**，就会重新
`_fetchRemoteFrameworkCommitDate()`——内部即 `git fetch --tags`。该请求
在真机网络下 504，flutter 捕获 `VersionCheckError` 后**继续构建**
（源码注释明确写了 best-effort），**但用户要先等满超时**。

**"为什么以前不卡"的确切答案**：stamp 写于 9-17，用户 9-19 构建时
**刚好超过 3 天阈值**。而更早的版本根本没走到这一步（卡在 54% 崩溃、
或 pub 装不上）。**不是步骤变了，是一个按时间触发的缓存到期了。**

**复现实验（本机实测）**：

| stamp 状态 | `flutter pub get` 输出 |
|---|---|
| 设为 9 天前 | **出现** 504 / `remote end hung up` |
| 刷新为当前时间 | **消失**，正常输出 `Got dependencies!` |

**修复**：构建前把 stamp 刷新为当前时间（JSON 字段
`lastTimeVersionWasChecked`，与 `VersionCheckStamp.fromJson` 对齐）。
属官方缓存协议内的用法，不改 SDK 源码、不伪造远端版本号
（写 `lastKnownRemoteVersion` 会让 flutter 误判本地落后而提示升级）。

**附带修复（同一区域的隐藏 bug）**：proot 构建路径的 `envPart`
**只设了 `SSL_CERT_FILE`**，没有 `FLUTTER_STORAGE_BASE_URL`。
`pub get` 那行自己内联了 `PUB_HOSTED_URL`（多源轮换），所以 pub 没事；
但 `flutter build` 那段是裸奔的，引擎/资产下载会回落到官方地址。

`foa-env.sh` 里其实写了这些变量——**但它放在 `/etc/profile.d/`，
而 proot 用 `sh -c` 直接执行命令，根本不读 profile.d**。
等于那份配置文件对构建路径**完全无效**。

> **教训**：`/etc/profile.d/*.sh` 只对**登录 shell** 生效。
> 凡是以 `sh -c` / `execve` 直接拉起的方式跑命令，
> 都必须把环境变量**显式写进命令**。别指望 profile.d。

---

### Bug 437：`REASSERT=0` 却仍在 AOT 52% 崩溃——verify 从未测过 impellerc

**症状**（2026-09-19 真机，alpha.44）：

```
REASSERT=0                    ← 转发层完好，没什么需要修的
...
Dart snapshot generator failed with exit code -4
impellerc failure:
ShaderCompilerException: Shader compilation of ".../ink_sparkle.frag" failed
```

**`REASSERT=0` 是本条最有价值的信息。**

- `REASSERT=<n>` 的 n 是「本次修复的文件数」。n=0 说明**转发层全部就位**，
  Bug 433 的修复**正常工作**了——但构建**依然崩**。
- 这直接推翻了「转发层被 pub get 覆盖」的假设：**转发脚本在、且完好**，
  7 个文件都确认是指向 qemu 的 `#!/bin/sh` 脚本。

于是问题转为：**既然转发层是好的，为什么 impellerc 还是跑不起来？**

**根因：`verify` 从来没有测过 `impellerc`。**

原 `_verifyScript` 只冒烟了**一个**工具：

```sh
gs=@ENGINE@/android-arm64-release/linux-arm64/gen_snapshot
```

而真机 AOT 阶段实际崩的是 **`impellerc`**（shader 编译），它在
**顶层 `linux-arm64/`**，**不在 `android-arm64-release/` 里**。

> 「工具链已验证就绪」这个结论，**只对被测过的那个工具有效**。
> 被测集合 ⊊ 被使用集合时，验证通过是一种**假安全感**。

**修复**：

1. `verify` 逐个冒烟 **gen_snapshot / impellerc / font-subset**，
   抽成统一的 `smoke()` 函数；
2. **失败时必须输出具体原因**——原先只输出 `yes/no`，而四种失败形态
   （脚本缺失 / 转发层被覆盖 / 依赖库缺失 / SIGILL）**修法完全不同**，
   只有 `no` 等于没给信息；
3. 新增 `TARGET_BAD=` 检查：**转发脚本指向的目标是否仍是 x86_64 ELF**
   （magic `7f454c46...3e`）。这能抓到最难查的组合——
   「脚本在、`REASSERT=0`、但一跑就崩」：脚本是好的，它指向的
   `linux-x64/` 原件却被换掉了；
4. Dart 侧收集诊断续行，在工具链页一并展示。

**教训（与 Bug 429/433/435 同源的第四次）**：
- Bug 429：要检查**全称**而非点名；
- Bug 433 ①：检查点与使用点之间**时序**上还有别的动作；
- Bug 435：**"我在某处修过"≠"所有执行路径都被修复"**；
- Bug 437：**"我验证过"≠"所有被使用的对象都被验证过"**。

四次都是同一个错误换了个维度：**悄悄把"存在"当成了"全称"**。

**沙箱限制（诚实记录）**：本修复**无法在沙箱端到端验证**。
沙箱是 x86_64 原生环境，`qemu-x86_64-static` 根本不需要也不存在，
`_verifyScript` 直接返回 `__NO_QEMU__`；arm64 容器又因网络受限
装不上 `qemu-user-static`。**能做的只有**：脚本语法检查
（dash/bash）、结构断言（单测 13 项）、以及在 x86_64 上复现 Bug 436
的 504 机制。**真机 `impellerc` 为何 SIGILL，仍需真机诊断数据定夺**
——这正是本次把诊断信息做详细的原因。

---

### Bug 438：`impellerc failure:` 后面一片空白——进程被信号杀死，stderr 是空字符串

**症状**（2026-09-19 真机，alpha.45）：

```
REASSERT=0                    ← Bug 433 的修复生效了，转发层完好
...
Dart snapshot generator failed with exit code -4
impellerc failure:            ← 冒号后面什么都没有
ShaderCompilerException: Shader compilation of ".../ink_sparkle.frag" failed
```

**关键在「冒号后面什么都没有」。**

看 Flutter 源码 `shader_compiler.dart:274`：

```dart
_logger.printError('impellerc failure: ${result.stderr}');
```

`result.stderr` 是**空字符串**。一个程序哪怕参数写错、文件找不到，
也总会往 stderr 吐点东西。**stderr 完全为空 + `exit code -4`，
只有一种解释：进程被信号杀死了，没来得及写任何输出。**
`-4` 是 Dart 对 `ProcessSignal` 的编号，对应 **SIGILL（128+4=132）**。

**为什么这次不能靠"再改一处代码"解决**：

三条排除法把范围压到了墙角：

| 假设 | 反证 |
| --- | --- |
| 依赖库缺失（`libatomic1:amd64` 等） | 那会打印 `error while loading shared libraries: ...`，不是空 |
| 转发层被 pub get 覆盖 | 同轮日志 `REASSERT=0`，7 个转发脚本都在且完好 |
| impellerc 文件损坏 | 文件校验和正常，且**同时**崩的是两个独立程序 |

最后一条是决定性的：**`gen_snapshot` 和 `impellerc` 是两个完全不同的
x86_64 程序，却在同一次构建里同时、静默、以同一个信号退出。**
两个互不相干的可执行文件不会同时出现同一处代码 bug——
**唯一共享的东西就是 qemu 这条链路本身。**

所以本次的修复目标不是"改某一行"，而是**让构建日志自己开口**。
在真机上盲改代码的代价是一个小时等构建，而拿到诊断数据只需要 10 秒。

**修复：构建前主动分层诊断（`QemuCompat.buildPreflightScript`）**

在 pub get 之前插入一段预检（越早越好，别浪费后面几分钟），
逐层输出 `QEMU_CHAIN_*` 前缀的行：

```
QEMU_CHAIN_NONE=1                              ← 没装 qemu（termux 后端会走到这）
QEMU_CHAIN_VER=qemu-x86_64 version 7.2.0       ← 层1：qemu 本体在不在、什么版本
QEMU_CHAIN_LOADER=ok / fail rc=132 / missing   ← 层2：qemu 能不能跑 x64 动态链接器
QEMU_CHAIN_PROBE=impellerc=ok rc=0             ← 层3：转发脚本能不能真的跑起来
QEMU_CHAIN_PROBE=impellerc=FAIL:SIGILL out=EMPTY
QEMU_CHAIN_SRC=impellerc=7f454c46020101...0200 ← 层4：转发目标还是不是 x86_64 ELF
QEMU_CHAIN_DONE=1
```

四层分别对应四种修法，一眼定位：

| 输出 | 含义 | 修什么 |
| --- | --- | --- |
| `NONE=1` | qemu 没装或路径不对 | 工具链页「一键应用」x64 兼容层 |
| `LOADER=fail` | qemu 在，但跑不了 x64 glibc | 多架构运行库装歪了（Bug 434 的残留） |
| `LOADER=ok` + `PROBE=FAIL:SIGILL` | qemu 和链接器都好，转发脚本一跑就崩 | 转发脚本本身有问题 |
| `SRC=...0200` 结尾 | 目标不是 x86_64（`3e` 结尾才是） | 转发目标被换成了 arm64 原件 |
| `PROBE=ok` 但构建仍崩 | qemu 链路没问题 | 问题在 qemu 之外，别再查这里 |

**此处踩到的坑：shell 管道会吞掉退出码（这个坑值得单独记）**

第一版我这么写：

```sh
out=$( "$tool" --help 2>&1 | head -2 )
rc=$?                                    # ← 这是 head 的退出码，永远是 0
```

`rc` 拿到的是**管道最后一个命令**（`head`）的退出码。
于是 SIGILL 被显示成 `rc=0`，诊断信息当场变成误导——
**这个 bug 恰好会掩盖它本要检测的那个 bug**，是最坏的一类。

正确写法是拿临时文件承接输出，让 `rc` 紧邻真正的命令：

```sh
tf=/tmp/.foa_probe_out
: > "$tf"
"$tool" --help > "$tf" 2>&1
rc=$?                                    # ← 这才是 impellerc 的退出码
out=$(head -2 "$tf" 2>/dev/null)
```

同理，`if cmd; then` 里也取不到被吞掉的 `$?`：

```sh
@QEMU@ -L / "$ld" --version > /dev/null 2>&1
lrc=$?
if [ "$lrc" = 0 ]; then ...              # ← 先捕获，再判断
```

这条已固化成单测断言，防止以后改回去。

**验证（沙箱能做到的部分）**：

沙箱是 x86_64 **原生**环境，没有也**不需要** qemu，
所以真机链路无法复现。**改用模拟环境验证「区分能力」**——
造一个假 qemu（`kill -ILL $$`），看预检脚本能不能把两种情况分开：

```
=== 模拟 SIGILL ===
QEMU_CHAIN_LOADER=fail rc=132
QEMU_CHAIN_PROBE=impellerc=FAIL:SIGILL out=EMPTY     ← 正确识别

=== 模拟正常 ===
QEMU_CHAIN_LOADER=ok
QEMU_CHAIN_PROBE=impellerc=ok rc=0                   ← 正确识别
```

**能区分，就说明这套诊断有信息量**——这正是本次交付的核心价值。
配套单测 9 项（`test/bug438_qemu_chain_diag_test.dart`）。

> **诚实说明**：本修复**不保证**构建一定能过。它保证的是——
> **失败时你能知道是哪一层坏了**。真机 SIGILL 的真因仍需真机数据，
> 请把构建日志里的 `QEMU_CHAIN_*` 各行截图反馈。

**教训**：「现象是空的」不是「没有现象」。
`impellerc failure:` 后的空白其实是**最精确的一条线索**
（= 被信号杀死），只是默认没人往那儿读。
当症状本身不提供信息时，**正确的动作是让下次运行产出信息**，
而不是继续盲改代码。

---

### Bug 439：转发脚本 `-L /` 让所有 x64 工具静默崩于栈保护——Bug 438 的真身

**这是 Bug 438 的根因。** 438 交付了「诊断能力」，439 交付出「修复」。

**症状**（与 438 完全一致，因为就是同一个故障）：

```
Dart snapshot generator failed with exit code -4     ← SIGILL
impellerc failure:                                   ← 冒号后为空
```

且 `REASSERT=0`——转发层完好无损，但程序照崩。

**根因：转发脚本用的 qemu 调用形式是错的。**

原转发脚本生成的内容是：

```sh
#!/bin/sh
exec /usr/bin/qemu-x86_64-static -L / <真x64二进制> "$@"
```

`-L /` 的含义是「把 `/` 当作 guest 根」，然后**让 qemu 自己去里面找
ld.so**。正是这个"让 qemu 代劳"的动作触发了 glibc 的栈保护初始化
（`__stack_chk_fail`）：进程在 `main` **之前**就被信号杀死，
**stderr 一个字都没有**。对应真机就是"冒号后面空白 + exit code -4"。

**正确形式**：把 guest 的 ld.so 当**程序**交给 qemu，动态链接全由
guest ld.so 自己完成，qemu 只做指令翻译：

```sh
exec /usr/bin/qemu-x86_64-static -L / /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 <真x64二进制> "$@"
```

**ld.so 路径陷阱**：必须用 Debian multiarch 真身
`/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2`。
**不能**用 `/lib64/ld-linux-x86-64.so.2`——它是一个指向**绝对路径**
`/lib/x86_64-linux-gnu/...` 的符号链接，跨 root（`qemu -L`）解析时会落到
**宿主**，反而崩得更彻底。实测：

| 传给 qemu 的 ld.so | 结果 |
| --- | --- |
| `/lib64/ld-linux-x86-64.so.2` | ❌ stack smashing |
| `/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2` | ✅ 正常 |

**四程序 A/B 矩阵**（沙箱 x86_64 + Debian amd64 libc 2.36，qemu-user-static 7.2）：

| 程序 | 旧 `-L / <bin>` | 新 `-L / <ld.so> <bin>` |
| --- | --- | --- |
| `dart` | ✗ 崩（core dump） | ✓ `Dart SDK version: 3.13.3 ... on "linux_x64"` |
| `impellerc` | ✗ 崩 | ✓ `ImpellerC is an offline shader processor...` |
| `gen_snapshot` | ✗ 崩 | ✓ `Usage: gen_snapshot ...` |
| `font-subset` | ✗ 崩 | ✓ `Usage: ...` |

**旧形式 4/4 崩，新形式 4/4 正常。**

**真实 shader 编译端到端**（`ink_sparkle.frag` 同级，独立 shader）：

| | 旧形式 | 新形式 |
| --- | --- | --- |
| rc | **134**（SIGABRT），无产物 | **0** |
| 产物 | — | `t.glsl` 134 B + `t.spirv` 1160 B |

更关键的对比：编译那个**不独立的** `ink_sparkle.frag`（它是 include 片段，
不能单独编译）时——

| | 旧形式 | 新形式 |
| --- | --- | --- |
| rc | 134，`*** stack smashing detected ***` | 1，`Compilation error. 1 error(s)... syntax error, unexpected LEFT_BRACE` |

新形式**跑到了真正的编译器里**并报出**真实的 GLSL 语法错误**；
旧形式连启动都没完成就死了。**「真错误」vs「静默死亡」就是本次修复的全部意义。**

**修复要点**：

1. 新增 `QemuCompat.x64Loader = '/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2'`。
2. 转发脚本生成片段加显式 ld.so 分支 + **旧形式回退**（保底不回归）：
   ```sh
   if [ -x "@LOADER@" ]; then
     exec @QEMU@ -L / "@LOADER@" "$2" "$@"
   fi
   exec @QEMU@ -L / "$2" "$@"
   ```
   用**运行时探测**而不是生成期写死，因为 rootfs 是「先解压、后装兼容层」，
   生成脚本那一刻 `@LOADER@` 可能还不存在。
3. **`.so` 不能包装**（潜伏 bug）：`.so` 的 ELF magic
   `7f454c46*3e` 与 PIE 可执行文件**完全一致**（`e_machine` 同为 x86_64、
   `e_type` 同为 `ET_DYN`），旧判定会把 `libpath_ops.so` /
   `libtessellator.so` / `libflutter_linux_gtk.so` 一并替换成 shell 脚本。
   必须按 `*.so|*.so.*` 名字排除。`build apk` 不触发（`flutter_tester` 才
   dlopen），属潜伏 bug。
4. **占位符替换收口到 `fill()`**：新增 `@LOADER@` 后，任何一个调用点漏替换，
   `[ -x "@LOADER@" ]` 恒假 → **静默回退到旧的错误形式**，Bug 439 原样复发
   且毫无提示。所有调用点统一走 `QemuCompat.fill()`。
5. 预检（Bug 438 那套诊断）新增 **OLDSTYLE 对照探针**：同时用新旧两种形式
   跑一次，若「旧崩、新正常」就精确命中 439。另补 `134) s=SIGABRT`。

**heredoc 反引号陷阱（修复过程中实际踩到）**：

生成脚本时用的是 `cat > "$1" <<FOAWRAP`。**分隔符没加引号**，导致 body
会被 shell 展开——注释里写一个反引号（如在说明里写 `-L /` 形式）就会被当成
命令替换，**吞掉后面所有行**，报 `Syntax error: end of file unexpected`，
而报错行号指向**脚本第 1 行**，极难定位。

- 验证：`printf 'cat >/tmp/bt.txt <<EOF\nHello `whoami` world\nEOF\ncat /tmp/bt.txt' | dash`
  → 输出 `Hello root world`，证实未加引号的 heredoc 会展开。
- 修复：分隔符改成 **`<<'FOAWRAP'`**（带单引号），body 完全字面量；
  原先 body 里手写的 `\$` 全部改回裸 `$`（否则会残留字面反斜杠）。
- 固化：`test/bug439_loader_wrapper_test.dart` 有专门断言
  「分隔符带单引号」「body 内无裸露反引号」「用裸美元符而非转义形式」，
  并对五个脚本跑 `dash -n` + `bash -n`。

**验证**（本次全部通过）：

| 项 | 结果 |
| --- | --- |
| `flutter analyze` | 7 条 third_party 基线，无新增 |
| `flutter test` | **196 项全绿**（原 180 + Bug 439 新增 16） |
| 五个生成脚本 `dash -n` / `bash -n` | 全部通过 |
| 实际执行 `wrapReassertScript` | `REASSERT=3`，`.so` **未被包装** ✓ |
| 生成的转发脚本跑 `impellerc --help` | ✓ 正常输出 |
| 新老形式同条件 A/B | 旧 `*** stack smashing detected ***` / 新 正常 |
| 真实 shader 编译 | 旧 rc=134 无产物 / 新 rc=0 产出 glsl+spirv |

> **沙箱限制（诚实说明）**：沙箱是 x86_64 原生，无 arm64 硬件。
> 本次通过**下载真实 Debian arm64/amd64 qemu 包 + amd64 libc 做单层/嵌套
> 模拟**，实现了真机链路的等效复现，根因已端到端复现并可 A/B 验证，
> 与真机日志特征一一对应。**最终确认仍需真机**。

**真机确认步骤**：装包 → 工具链页「一键应用」x64 兼容层
（**必须重新应用**，否则仍是旧转发脚本）→ 看 `impellerc 冒烟` 是否通过
→ 构建并检查日志里的 `QEMU_CHAIN_*`（尤其 `QEMU_CHAIN_OLDSTYLE=` 一行）。

**教训**：
- 「转发层在位」不等于「转发层正确」——文件存在、可执行、`REASSERT=0`，
  都只证明脚本在那里，**不证明它调用 qemu 的方式是对的**。
  检查中间层时，要检查它的**内容**，而不只是它的**存在**。
- 一个 **bug 的"现象"和"根因"可以隔着两层**：438 记录了现象（stderr 为空），
  439 才是让现象消失的那一行代码。诊断能力先落地，根因后到，这是正常节奏，
  但要记得**回头把根因补上**——否则诊断只会一直报同一个错。
- 凡是「两个互不相干的程序同时以同一信号静默退出」，答案几乎总在
  **它们共享的那一层**上，而不是它们各自的代码里。

---

### Bug 440：平台模板领先于生成目录——PTY 终端实现根本没编进 APK

**怎么发现的**：出 alpha.47 时执行第 6 步「平台模板双写门禁」，
`diff` 生成目录与 `platform/` 模板，发现 **`platform/MainActivity.kt`
比生成目录多 269 行，而生成目录没有任何一行是模板没有的**
（`diff | grep -c '^>'` = 269，`'^<'` = 0）。

这是一个**单向领先**的信号：模板里有东西，生成目录里没有。
追下去发现两处：

| 文件 | 生成目录 | platform 模板 |
| --- | --- | --- |
| `MainActivity.kt` | 1401 行，**0 处** PTY 代码 | 1670 行，含完整 PTY 五件套 |
| `PtySession.kt` | **不存在** | 存在 |

**影响面是致命的，且和用户反馈对上了**：Dart 侧
`lib/ui/terminal_page.dart` 有 **20 处**调用
`ptyStart` / `ptyWrite` / `ptyPoll` / `ptyStop` / `ptyResize`，
而生成目录的 `MainActivity.kt` 里 **0 个 handler**。
`foa_pty` 二进制**已经打进 APK**（`assets/tools/foa_pty`，11152 B），
但 Java 侧没有实现 —— 一打开终端就是 **`MissingPluginException`**。
这正是用户此前反馈的三张截图之一。

**为什么之前没被发现**：`platform/` 模板是"新工程脚手架"的来源，
但**它不是构建输入**——构建只编译 `android/app/src/main/`。
于是「模板里写好的功能」和「实际编进包的代码」是两条独立的路径，
没有门禁强制它们一致。Bug 430 的 PTY 工作**只落在了模板侧**，
从没进入过构建目录，所以从没被编译、也从没被验证。

**修复过程中的三连编译错误**（模板代码从未编译过，一编译就暴露）：

| 位置 | 错误 | 原因 |
| --- | --- | --- |
| `MainActivity.kt:349` | `None of the following candidates is applicable` + `listFiles`/`name`/`delete` 全部 Unresolved | `File(File(filesDir, "tmp"))` —— **单参数**嵌套时 Kotlin 把外层 `File` 解析成**类构造器引用**而非 `java.io.File` 工厂函数。改用 `java.io.File(...)` 显式限定 |
| `MainActivity.kt:1085` | `Condition type mismatch: inferred type is 'Int' but 'Boolean' was expected` | `Process.waitFor()` 返回**退出码 Int**，不是 Boolean。原写法 `val finished = proc.waitFor()` 再 `if (finished)` 不成立。改为直接取 `code`，用 try/catch 兜 `-500` |
| `PtySession.kt:64` | `Empty character literal` | `var lastCwdHint: String = ''` —— `''` 是空**字符**字面量，字符串初值必须是 `""` |

> **注意一个容易误判的点**：同一个文件里还有 8 处
> `File(File(x, y), z)` 的两参数嵌套写法，那些**是能编译的**——
> 因为外层调用带了第二个参数，Kotlin 能明确解析到构造器。
> 只有**单参数** `File(File(...))` 才会歧义。
> 修的时候要按「是否单参数」筛，不能见 `File(File(` 就改。

**修复**：

```bash
# 单向同步：模板 → 生成目录（模板是权威源）
cp platform/android/MainActivity.kt android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt
cp platform/android/PtySession.kt   android/app/src/main/kotlin/dev/foa/flutter_on_android/PtySession.kt
# 然后修上面三个编译错误，再构建
```

**验证**：

| 项 | alpha.47 首轮（模板未同步） | alpha.47 修复后 |
| --- | --- | --- |
| Kotlin 编译 | — | ✅ 通过 |
| `classes.dex` 里 `ptyStart` | **0** | **3** |
| `classes.dex` 里 `PtyRegistry` | **0** | **2** |
| `classes.dex` 里 `ptyResize` | 0 | 1 |
| 终端功能 | `MissingPluginException` | 可用 |

四件套（badging / 资产 / 签名 / GPL）全过；`analyze` 保持
7 条 third_party 基线；`flutter test` **196 项全绿**。

**教训**：
- **第 6 步双写门禁不是形式主义**——它这次直接拦下了一个
  "功能完全没进包"的致命缺陷。**门禁的价值就在于它会拦下你没想到的事。**
- 判断双写差异时，**要看方向**：`diff | grep -c '^>'` 与 `'^<'` 的
  数量对比能立刻告诉你谁是权威源。单向领先 = 有内容漏同步；
  双向都有 = 两边各自改了，要人工判断。
- **"模板里有" ≠ "包里会有"**。只要模板不是构建输入，
  任何只写在模板里的代码都是**未编译、未验证**的。
  一个功能写完之后**必须过一次构建**才算存在。
- 提前做全仓同类缺陷扫描（这里扫 `= ''` / `File(File(` / `waitFor()`），
  比"改一个→构建 8 分钟→再改下一个"省下大量时间。

---

### Bug 441：修 Bug 439 的引号把 `$2` 锁死了——转发脚本真身路径丢失，`invalid ELF header`

**这是我自己引入的回归**，而且**被我亲手写的 16 个测试全部放行**。
记录下来，因为它的教训比 Bug 本身值钱。

**症状**：用户卸载重装后，构建日志出现

```
error while loading shared libraries: /opt/flutter/bin/cache/flutter_tools.snapshot: invalid ELF header
```

**第一件事：这行报文的来源是唯一的**

`error while loading shared libraries: X: reason` 这个格式**只有动态加载器
（ld.so）会打印**。看到它就等于确认：**有个非 ELF 的文件被当成程序送进了 ld.so**。
（沙箱里用 `/lib64/ld-linux-x86-64.so.2 /etc/hostname` 精确复现了同款报文。）

**第二步：确认 `flutter_tools.snapshot` 是不是 ELF**

不是。它是 Dart 的 **app-jit 快照**：

| 检查项 | 结果 | 说明 |
| --- | --- | --- |
| `head -c 4 \| od -An -tx1` | `dc dc f6 f6` | **不是** ELF 的 `7f454c46` |
| `ls -la` | `-rw-r--r--` | **无 +x 权限** |
| 正文明文 | 含 `x64 linux` | 可读的元数据字符串 |
| 由谁加载 | `shared.sh:273` `exec "$DART" ... "$SNAPSHOT_PATH" "$@"` | **不是**直接执行 |

**这儿我上一轮推断错过一次**：我曾怀疑它是被文本匹配
`grep 'x64'` 误包装了。事实是**包装判定从头到尾都是 ELF 魔数**
（`[ -x "$f" ]` + `case "$m" in 7f454c46*3e)`），
`dcdcf6f6` 头**不可能**通过这一关。
所以它**不是被包装脚本伤的**——是**被当成程序送进加载器**伤的。
**先验证再下结论。**

**真因：Bug 439 的修复改错了 heredoc 分隔符**

Bug 439 为了修反引号陷阱，把生成脚本的分隔符从
`<<FOAWRAP`（无引号）改成了 `<<'FOAWRAP'`（带引号）。
修反引号是对的，但**我漏了它的副作用**：

> **无引号的 heredoc 会展开 body 内的变量**。旧代码正是靠这个副作用，
> 把 `$2`（真身路径）**烘入**了生成的转发脚本。

改成带引号后，`$2` 不再被展开，**原样留在了脚本里**。而脚本运行时，
`$2` 是**调用者的第一个业务参数**（`$1` 才是真身），于是命令错位成：

```sh
qemu -L / <ld.so> <业务参数> <真身> <业务参数>
#                 ^^^^^^^^^^ 这个被当成程序送进 ld.so → invalid ELF header
```

**两张对照证明**（沙箱实测）：

```sh
# 未加引号 heredoc（Bug 439 之前的旧代码）
exec /usr/bin/qemu -L / "/path/to/REAL_BINARY" "$@"    ✅ 正确

# 加了引号 heredoc（Bug 439 引入的回归）
exec /usr/bin/qemu -L / "$2" "$@"                      ❌ 错位
```

**为什么 16 个测试都没抓到**

因为 Bug 439 的 `bug439_loader_wrapper_test.dart` **全是静态文本断言**——
拿字符串 `contains` 一下，检查脚本"长什么样"。
**没有一个是"生成脚本之后真的执行它"**。
文本里含有 `-L /` 和 ld.so 路径，断言就过了，
**参数到底指向谁，测试根本没看**。

**修复：`@REAL@` 占位符 + `sed` 显式写入**

不再依赖 heredoc 的展开副作用（副作用是隐式的、且和引号耦合，
下次谁再动引号又会踩）：

```dart
gen() {
  cat > "$1" <<'FOAWRAP'
...
if [ -x "@LOADER@" ]; then
  exec @QEMU@ -L / "@LOADER@" "@REAL@" "$@"
fi
exec @QEMU@ -L / "@REAL@" "$@"
FOAWRAP
  # Bug 441：真身路径在这里显式写入，不依赖 heredoc 展开
  sed -i "s#@REAL@#$2#g" "$1"
  chmod 755 "$1"
}
```

> `@REAL@` **不走** `fill()` —— 它是 **per-file** 的，
> 每个被包装文件写自己的真身路径；`fill()` 是全局模板替换。

**新增 `bug441_gen_real_path_test.dart`（10 项）——这次真的执行**

与 Bug 439 的做法相反：**真实跑 `gen()`，检查生成出来的脚本**。

```dart
Process.runSync('/bin/sh', ['-c', r'. "$1"; gen "$2" "$3"', wrapper, real, ...]);
```

覆盖五组：真身路径被写进脚本 / **不得残留 `"$2"`** /
两条 exec 都正确 / 带空格的路径 / dash+bash 双 shell 语法。

**并且验证测试本身能失败**：把旧实现喂进去，
两条断言**正确失败**（残留 `$2`、缺真身路径）。
—— 一个从没红过的测试，不能算测试。

**同时落地的两道防线（用户指定方案）**

**① 黑名单扩到 6 类扩展名**（5 个遍历点 + 1 个 put 点）：

```sh
case "$f" in *.so|*.so.*|*.snapshot|*.dill|*.json|*.jar|*.zip) continue ;; esac
```

> **为什么用黑名单不用白名单** —— 用户原话：
> 「白名单一旦漏了新工具，用户卡死无解；**黑名单漏了最坏只是误包一个文件**。」
> 失败模式不对称，就该选代价小的那一边。

两道防线分工要讲清楚：

| 防线 | 拦什么 | 例 |
| --- | --- | --- |
| ELF 魔数 `7f454c46*3e` | 拦"**内容不是 ELF**" | `.json` / 文本脚本 |
| 扩展名黑名单 | 拦"**是 ELF 但不该被当程序执行**" | `.so` 是 ELF，但它是库不是程序；`.snapshot` 是第二道保险 |

**② 构建前自愈 `heal()`**

通用还原逻辑——**不看扩展名，只看 `X.foa-real` 是否存在**：

```sh
[ -f "$f" ] || continue
b="${f%.foa-real}"; rm -f "$b"; mv "$f" "$b"; n=$((n+1))
```

幂等、低代价（只 `mv`，不碰 apt、不删引擎目录），所以**每次构建前都跑**。
覆盖三处：`dart-sdk/bin`、`flutter/bin/cache`（Bug 441 的受害面）、
SDK build-tools/platform-tools。

还带一个头部体检：读 `flutter_tools.snapshot` 前 4 字节，
`dcdcf6f6` → `SNAPSHOT=ok`。

**注入顺序有个坑**：`heal` 必须放在 `reassert` **之前**——
反了会把刚还原的文件**又包一遍**。

**③ 错误驱动兜底提示**

在 `_feedErrorBreakdown` 里优先匹配 `invalid elf header`：

```dart
if (l.contains('invalid elf header')) {
  tip = '工具链文件被误包装成转发脚本（非 ELF 被送进加载器）：'
      '构建前会自动还原（HEALED=）；若本条仍出现，到「工具链」页执行'
      '一次「一键应用」重建转发层后重试（Bug 441）';
}
```

> **分诊表的分支有顺序**：`invalid elf header` 必须排在
> `shared libraries` **之前**——否则会被后者的前缀判断先吃掉。

**验证**

| 验证项 | 结果 |
| --- | --- |
| 生成的转发脚本 exec 行 | `exec qemu -L / "<ld.so>" "<真身>" "$@"` ✅ |
| 实际执行 `impellerc --help` | rc=0，1795 B 正常输出 ✅ |
| 旧实现对照 | 残留 `"$2"`、缺真身路径（测试正确失败）✅ |
| 自愈演练 | `HEALED=1` `SNAPSHOT=ok`，头变回 `dc dc f6 f6` ✅ |
| dash / bash 语法 | 全通过 ✅ |
| `flutter analyze lib/` | `No issues found!` |
| `flutter test` | **206 项全绿** |

自愈演练细节（沙箱）：

```bash
mkdir -p /tmp/e2e441/healtest/bin/cache
cp /opt/flutter/bin/cache/flutter_tools.snapshot  .../flutter_tools.snapshot.foa-real
printf '#!/bin/sh\nexec qemu ...\n' > .../flutter_tools.snapshot && chmod 755 ...
# 修复前：头 = 23 21 2f 62（"#!/b"），存在 .foa-real
sh heal_run.sh     # → HEALED=1 / SNAPSHOT=ok
# 修复后：头 = dc dc f6 f6，.foa-real 已消失，大小 47675168
```

**教训**

- **修一个 Bug 时引入的下一个 Bug，往往藏在"修复手段的副作用"里。**
  改 heredoc 引号是为了修反引号，`$2` 展开是**顺带**丢的。
  改任何"约定/语法糖"时，要问：**它现在替我做了什么隐式的事？**
  隐式行为一旦消失，最好**改成显式的**（`@REAL@` + `sed`），
  而不是换个方式继续依赖它。
- **只做文本断言的测试，挡不住回归。** 16 个测试全绿，
  真机上照样崩。**测试要碰运行结果，不是碰源码字符串。**
  这次的对策是"真实执行 `gen()`"，方向要对。
- **写完测试要验证它会在旧实现上失败**（红-绿验证）。
  从没红过的测试给的是**虚假的安全感**。
- 报错信息格式本身就是线索：`error while loading shared libraries:`
  → 一定是 ld.so 打的 → 一定是"非 ELF 被当成程序"。
  顺着报文的**生产者**反推，比顺着现象猜快得多。
- **失败模式不对称时，选代价小的那一边**（黑名单 vs 白名单）。

---

### Bug 442：修 Bug 441 的自愈把正常包装也还原了——整条工具链瘫痪，`exit 69`

**又是我引入的回归，而且是 Bug 441 的"修复"直接造成的。**
连续两个 Bug（441、442）都是"修 A 引入 B"，值得单独反思。

**症状**（真机 alpha.48 首次构建，3% 冻结，耗时 24 秒就死）：

```
QEMU_CHAIN_VER=qemu-x86_64 version 7.2.22   ← qemu 正常
QEMU_CHAIN_LOADER=ok（ld.so 显式加载方式可用） ← 加载器正常
QEMU_CHAIN_PROBE=impellerc=ok rc=0           ← 真 x64 程序能跑
QEMU_CHAIN_OLDSTYLE=impellerc=ok rc=0        ← 两种加载方式都好
QEMU_CHAIN_SRC=impellerc=7f454c4602...03003e ← 引擎 ELF 头正常
QEMU_CHAIN_DONE=1
HEALED=22        ← ⚠️ 自愈还原了 22 个文件
SNAPSHOT=ok      ← ⚠️ snapshot 是好的
Illegal instruction   ×5
✗ 构建失败 (exit 69)
```

**先看诊断段**：全绿。qemu 本体、ld.so、impellerc（新旧两种加载方式）、
引擎 ELF 头，**每一项都正常**。说明**引擎层完全没问题**。

**再看两个数字**：`HEALED=22` 和 `SNAPSHOT=ok`。
- `SNAPSHOT=ok` → Bug 441 的修复**生效了**，snapshot 头是正常的 `dcdcf6f6`
- `HEALED=22` → **但自愈一口气还原了 22 个文件**

**`exit 69` 只在 build_runner 里出现一次**：`pub get` 三源六次重试全挂的兜底。
而报错是 `Illegal instruction`（SIGILL）= **arm64 上直接执行了 x64 代码**。

把这两个事实拼起来：**`pub get` 调 `dart` 时撞上了 x64 二进制。**

**根因：我的自愈判据从根上就错**

Bug 441 我加的自愈逻辑是这么想的：

> "`X.foa-real` 存在 = X 是个被误包装的坏文件 → 还原它"

**这个假设对 `dart-sdk/bin` 是错的。** 那里的 `.foa-real` 是**正常且必需**的
包装产物：

| | 文件 | 角色 |
| --- | --- | --- |
| 真身 | `dart.foa-real` | x64 的 dart 二进制 |
| 转发 | `dart` | `#!/bin/sh` 脚本，exec qemu 去跑上面那个 |

**两个文件都必须在**，这才是转发层的正常形态。
我的自愈把它当成"坏文件"，**把好好的转发脚本删掉、把 x64 真身搬了回来**。

于是链就断了：

```
heal 还原 22 个工具 → dart 变成裸 x64 ELF
    ↓
reassert 本该重建 —— 但它**只覆盖引擎目录**（$E/android-*/linux-x64、$E/linux-*），
**根本不碰 dart-sdk/bin** → 没有任何东西把它包回去
    ↓
pub get 调 flutter → dart = arm64 上执行 x64 → SIGILL ×5
    ↓
三源六次重试全挂 → exit 69
```

**顺带纠正一个更深的误解**：Bug 441 里我以为 `flutter_tools.snapshot`
"被误包装过"，所以特意加了还原它的逻辑。**这是错的。**

包装器的判据是 `[ -x "$f" ]` **且** ELF 魔数 `7f454c46*3e`。而
`flutter_tools.snapshot` 是 `dcdcf6f6` 且权限 `-rw-r--r--`（**无 +x**）——
**三道关卡全都过不去，它根本不可能被包装**。

Bug 441 里它**只是受害者**：是被错位的转发脚本把它的路径喂进了 ld.so。
我为它写的"还原"逻辑，**从头到尾都在解决一个不存在的问题**，
却顺手制造了一个真实的问题。

**修复（三件事）**

**① 换判据：区分"正常包装"与"孤儿"**

`X.foa-real` 只有在**它的兄弟 X 不是有效 FOA 转发脚本**时才需要处理：

```sh
heal_one() {
  f="$1"; b="${f%.foa-real}"
  # 兄弟是有效 FOA 脚本 → 正常包装，保持原样
  if [ -e "$b" ] && head -c 2 "$b" 2>/dev/null | grep -q '#!' &&
     grep -q 'FOA x86_64 -> qemu-user wrapper' "$b" 2>/dev/null; then
    return 0
  fi
  # 兄弟缺失 / 不是 FOA 脚本 → 还原真身
  rm -f "$b"; mv "$f" "$b"; n=$((n+1))
}
```

> **取舍方向不是随意的，是代价不对称决定的**：
> - 误判"合法"而跳过 → 保持现状，**reassert 会无条件重建**（它不看这个判据）
> - 误判"孤儿"而还原 → **把好好的转发层毁掉**，正是 Bug 442
>
> 代价不对称时，判据要往**保守**那一侧收。

**② `reassert` 补上 `dart-sdk/bin`（这是缺失的兜底）**

`reassert` 之前只有 `E=@ENGINE@`，现在加了 `F=@FLUTTER@`，
并原地重建 `dart-sdk/bin` 的转发层，输出 `REASSERT_DART=` 可观测。

> 为什么必须补：`dart-sdk/bin` 是**所有 flutter 命令的入口**
> （`flutter` bash 脚本第一件事就是 exec dart）。
> 入口一旦坏掉，**一条命令都跑不了**——这就是为什么 Bug 442 是"整条链瘫痪"
> 而不是"某个功能不可用"。**兜底必须覆盖入口。**

**③ 加探针 `DART=ok` / `DART=ELF_BROKEN`**

heal 顺带检查 `dart-sdk/bin/dart` 的头 4 字节：
`2321` = 转发脚本在位；`7f454c46` = 裸 x64 二进制，转发层丢了。

> 这样问题在**构建早期**就报出来，而不是等 `pub get` 报一句
> 让人摸不着头脑的 `Illegal instruction`。

**④ 构建日志分诊新增 `Illegal instruction` 分支**

```
pub get 阶段的 SIGILL（无编译上下文）→ dart-sdk 转发层丢失（Bug 442）
AOT 阶段的 SIGILL（有 impellerc / snapshot generator 上下文）→ Bug 428
```

> **这两件事必须分开**。旧分诊表里 SIGILL 只指向"AOT/shader 编译崩溃 +
> 重新应用兼容层"——对 Bug 442 是完全无关的建议。
> 新分支**排在那组之前**，但**判据不能太宽**：带 `impellerc` 上下文的
> 必须仍然落到 Bug 428（有测试专门守这条边界）。

**验证（红-绿对照）**

在**同一 fixture** 上跑旧逻辑与新逻辑：

| 场景 | 旧 heal | 新 heal | 新 reassert |
| --- | --- | --- | --- |
| **正常包装态**（22 个工具） | `HEALED=22` ❌ 全毁 | `HEALED=0` ✅ 不动 | — |
| **已损坏态** | — | 不误伤，报 `DART=ELF_BROKEN` | `REASSERT_DART=23` ✅ 重建 |

真机数字复现：旧逻辑输出 `HEALED=22`，**与用户日志完全一致**。

门禁：`analyze lib/` → `No issues found!`；`flutter test` → **219 项全绿**。
新增 `bug442_heal_not_destructive_test.dart`（13 项），
并**验证其在旧实现上正确失败**（3 项变红）。

**教训**

- **"修 A 引入 B"连续发生了两次（441、442），根因是同一个：**
  **我加修复逻辑时，没有问'这个假设在别的调用点上成立吗'。**
  Bug 441 的自愈对 `bin/cache/` 也许无害，但我把它**同时**套到了
  `dart-sdk/bin` 上——而那里的文件形态完全不同。
  **一条修复逻辑用到 N 个目录时，必须逐个确认前提成立。**
- **别修不存在的问题。** 我为 `snapshot` 写的还原逻辑基于一个错误推断
  （"它被包装过"），实际它连包装的资格都没有（无 +x、非 ELF）。
  **加防御代码前先确认威胁真实存在**，否则防御本身就成了威胁。
- **兜底必须覆盖"入口"。** reassert 只管引擎目录，漏掉了
  所有命令的入口 `dart-sdk/bin`，导致"局部能修、全局瘫痪"。
  **问自己：这条链上，用户最先碰到的那个文件是哪个？**
- **探针要报"人能看懂的状态"，不要等底层抛出晦涩报错。**
  `DART=ELF_BROKEN` 比 `Illegal instruction` 有用得多。
- **测试夹具写错会伪装成代码错。** 我第一版 fixture 用 `+ b'\x00'*10`
  凑 ELF 长度，把 `e_machine` 挤到 offset 18 之后，19 字节读到 `...0003`，
  包装器**正确地**跳过了它 —— 我一度以为"修复没生效"。
  **夹具也要符合真实数据结构。**
- **对脚本文本做 `contains` 断言很脆。** Bug 442 加的注释里出现了
  "pub get" 字样，导致 Bug 433 的一条测试误报失败。
  **断言的意图是"不得执行"，就该只看可执行行，不看注释。**
- **测试脚本含 `rm -f`/`mv` 时必须有安全闸。** 我调试时占位符替换写错，
  脚本作用到了**真实的 `/opt/flutter`**，把沙箱的 `dart` 换成了指向不存在
  qemu 的转发脚本，`flutter test` 整个跑不起来。
  修法：断言"替换后无残留占位符" + "非注释行不含真实环境路径"。

---

### Bug 443：诊断段全绿、AOT 段照样 SIGILL——`smoke()` 的退出码被管道吞了（死代码）+ 诊断行数上限过紧

**症状**（真机 alpha.49，用户截图）：

构建进度一路走到 **57%**，然后：

```
AOT 编译 (gen_snapshot)                                       57%
Dart snapshot generator failed with exit code -4
impellerc failure:
impellerc failure:
Target android_aot_release_android-arm64 failed
```

但**同一份日志的诊断段里**：

```
impellerc=ok rc=0
DART=ok（转发脚本在位）
SNAPSHOT=ok
HEALED=0
```

—— 诊断说"全部正常"，编译却照样 SIGILL（`exit -4` = 128+(-132) = SIGILL）。
而且用户还反馈：**日志里根本没有 `REASSERT=` 这一行**。

一句话概括这个 Bug 的恶心之处：**探针报了绿灯，路却是断的。**

**原因**：三个问题叠在一起，其中前两个是**纯粹的自我欺骗**，第三个真因**至今未定**。

---

**① `smoke()` 的退出码被管道吞掉了 —— 这段代码从写下那天起就没生效过**

Bug 437 引入的 `smoke()` 长这样：

```sh
o=$( "$t" --help 2>&1 | head -5 )     # ← 管道
r=$?                                  # ← 这是 **head** 的退出码，不是工具的！
...
if [ "$r" -ge 128 ] 2>/dev/null; then    # ← 恒为假，死代码
  echo "$n=no"
  echo "  $n: 信号退出 rc=$r（128+n，n=4 即 SIGILL）"
  return
fi
echo "$n=yes"
```

在 `sh` 里 **`$(cmd | head -5)` 的 `$?` 是管道最后一个命令（也就是 `head`）的退出码。**
`head` 永远成功退出，所以 `r` 恒为 **0**，`[ "$r" -ge 128 ]` **永远不成立**。

后果：**一个被 SIGILL 杀死、输出为空的工具，会被 `smoke()` 判成 `yes`。**
这就是"诊断段 impellerc=ok rc=0，编译段 impellerc 崩"的直接来源 ——
探针不是没跑，是**跑了但看错了结果**。

沙箱最小复现（`bug443_smoke_exitcode_test.dart`）：

| 取退出码的方式 | 结果 |
|---|---|
| 直接 `` `"$t" --help` `` | `direct=132` ✅ 拿到 SIGILL |
| `` `o=$( "$t" --help 2>&1 \| head -5 )` `` 后取 | `piped_head=0` ❌ 被吞 |
| 落盘重定向 `"$t" --help > "$st" 2>&1` 后取 | `rc=132` ✅ 拿到 SIGILL |

**这一点在 Bug 438 修 `QEMU_CHAIN_PROBE` 时已经踩过一次（当时改成"先落盘再读"），
但当时只修了那一个点，没有全仓扫同类写法。** 这次是同一个错误在 `smoke()` 里复发。

---

**② `tail -n` 行数上限过紧 —— 解释了"日志里没有 `REASSERT=`"**

`build_runner.dart` 里三段诊断各自截尾：

| 段 | 原来 | 问题 |
|---|---|---|
| diag | `tail -n 12` | 诊断输出远超 12 行 |
| heal | `tail -n 3` | `HEALED=` 前面还有 `DART=` / `SNAPSHOT=` |
| reassert | `tail -n 2` | **只留最后 2 行**，混进 stderr 时 `REASSERT=` 直接被挤掉 |

`tail` 截的是**尾部**，而 `REASSERT=` 在 reassert 段里不是最后一行。
一旦 `gen()` 或 `sh` 自己往 stderr 吐哪怕两行，关键结论就没了。
用户看到的就是"没有 `REASSERT=` 这行" —— 不是脚本没跑，是**被 tail 吃掉了**。

已放宽到 `30 / 10 / 10`。

---

**③ 真因：诊断时刻 vs 编译时刻，工具链状态可能不一致（未定）**

日志里有一行关键提示：

```
Flutter assets will be downloaded from https://storage.flutter-io.cn
```

这说明 **`flutter build` 内部又会下载一次引擎构件**。
如果下载发生在诊断之后、AOT 之前，就会把转发脚本覆盖成裸 x64 ELF（**Bug 428 的变体**，
只是覆盖点从 `pub get` 挪到了 `build` 内部）。三种可能目前无法区分：

1. 转发脚本压根没重建（`reassert` 没跑 / 没覆盖到）；
2. 转发脚本重建了，但被 `build` 内部的下载覆盖回裸 ELF；
3. 转发脚本在位，但 qemu 跑 `gen_snapshot` 本身就失败（Bug 438 类）。

**在证据不足时我不再猜** —— 猜错就是下一个回归（Bug 441/442 都是这么来的）。
改成加**可观测性**，让下一份真机日志自己把答案说出来。

**解决**：

1. **`smoke()` 改成落盘重定向 + 紧邻取退出码**（`qemu_compat.dart`）：

```sh
st=/tmp/.foa_smoke_out
: > "$st"
"$t" --help > "$st" 2>&1
r=$?                                  # 紧邻调用，拿到真实退出码
o=$(head -5 "$st" 2>/dev/null)
rm -f "$st"
```

同时**前置两道硬判据**（不等执行就先筛掉明显的坏状态）：

```sh
[ -x "$t" ] || { echo "$n=no"; ...; return; }        # 不可执行直接判死
head -c 2 "$t" | grep -q '#!' || { echo "$n=no";     # 不是转发脚本直接判死
  echo "  $n: 不是转发脚本（真 x64 二进制，arm64 上必 SIGILL）"; return; }
```

2. **`tail -n` 放宽**：diag `12→30`、heal `3→10`、reassert `2→10`。

3. **新增 `AOT_FP=` 工具链指纹**（`buildPreflightScript`）——
   对 6 个 AOT 关键工具**判文件头**而不是判文件存在：

```sh
for u in \
  @ENGINE@/linux-arm64/impellerc \
  @ENGINE@/linux-x64/impellerc \
  @ENGINE@/android-arm64-release/linux-arm64/gen_snapshot \
  @ENGINE@/android-arm64-release/linux-x64/gen_snapshot \
  @ENGINE@/linux-arm64/font-subset \
  @FLUTTER@/bin/cache/dart-sdk/bin/dart ; do
  h=$(dd if="$u" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$h" in
    2321*)    echo "AOT_FP=$(basename "$u")=wrapper" ;;
    7f454c46) echo "AOT_FP=$(basename "$u")=RAW_ELF（真 x64 二进制，未经转发 → 必 SIGILL）" ;;
  esac
done
```

   **为什么用文件头而不是"-x 存在"**：转发脚本是 `#!`（`2321`），真 x64 二进制是
   `7f454c46`。文件存在与否在两种状态下都为真，只有**文件头**能区分。

4. **构建失败时二次快照**（`build_runner.dart`）—— 用同一份指纹在**崩完之后**再打一遍：

```sh
brc=$?; if [ "$brc" != 0 ]; then
  echo "---- 构建后工具链指纹（对比上面的 AOT_FP）----"
  sh -c '<diag>' 2>&1 | grep -E "AOT_FP|QEMU_CHAIN_PROBE" | tail -n 12
fi; exit $brc
```

   两份指纹一对比，上面三种可能立即区分：
   - 构建前 `RAW_ELF` → 可能是 ①（reassert 没覆盖到）；
   - 构建前 `wrapper`、构建后 `RAW_ELF` → 确证 ②（build 内部下载覆盖）；
   - 前后都 `wrapper` → 是 ③（转发层没问题，问题在 qemu 本身）。

5. **新增 `bug443_smoke_exitcode_test.dart`（8 项）**，其中一条**结构性反证**会全仓扫
   `$(... | head ...)` 后紧跟取退出码的写法，防止同类再次复发：

```dart
RegExp(r'\$\([^\n]*\|[^\n]*head[^\n]*\)\s*\n\s*\w=\$\?')
```

**验证**：

| 验证项 | 结果 |
|---|---|
| 管道吞退出码最小复现 | `direct=132` / `piped_head=0` / 落盘后 `rc=132` ✅ |
| `smoke()` 已改为落盘取码 | 断言脚本文本含 `> "$st" 2>&1` 且 `r=$?` 紧邻 ✅ |
| 全仓同类写法反证 | 无 `$(...\|head...)` 紧跟取退出码 ✅ |
| 三段 `tail -n` 下限 | diag ≥ 30 / heal ≥ 10 / reassert ≥ 10 ✅ |
| `AOT_FP` 覆盖 6 个 AOT 工具 | 含 `linux-x64` 与 `linux-arm64` 双路径 ✅ |
| `AOT_FP` 用文件头判据 | 区分 `2321*` 与 `7f454c46` ✅ |
| `flutter analyze lib/` | `No issues found!` ✅ |
| `flutter test` | **227 项全绿** ✅ |

**出现版本**：v0.1.0-alpha.49（构建时暴露；代码缺陷自 alpha.47 / Bug 437 起就存在）
**修复版本**：commit `cedb91e`（v0.1.0-alpha.50）

**教训**：

- **`cmd | head` 之后取 `$?` 拿到的不是 `cmd` 的退出码。** 这是 shell 基础，
  但因为它**静默地**把"失败"变成"成功"，写的时候毫无痛感。
  **凡是"取退出码"，前面不许有管道。** 想截断就先落盘再读。
- **修了一个点，要立刻全仓扫同类。** Bug 438 修 `QEMU_CHAIN_PROBE` 时已经踩过这个坑，
  当时只改了那一处，`smoke()` 里的同一写法原封不动留到了 alpha.49。
  **"修过了"不等于"没有了"。**
- **探针报绿灯 ≠ 路是通的。** 一个"永远返回成功"的探针比没有探针更危险 ——
  它会让你排除掉真正的嫌疑方向。这次它让我在 alpha.49 之后一度怀疑
  "转发层是不是在 build 内部被覆盖了"，而实际`smoke()` 根本没在测它以为在测的东西。
- **`tail -n N` 截的是尾部，不是头部。** 把诊断结论放在段首、再用 `tail -n 2`，
  等于**主动把结论扔掉**。诊断输出的行数上限要按"最坏情况 + stderr"来留，
  宁可多打十行给用户，也不要少打一行给自己。
- **证据不足时加可观测性，不要加猜测。** Bug 441/442 都是我在证据不足时推断根因、
  然后引入新回归。这次面对 AOT 崩溃的三种可能，我选择**不改逻辑**，
  只加 `AOT_FP` 指纹 + 失败后二次快照，让下一份真机日志自己给出答案。
  **推断可以大胆，但改动必须建立在已观测的事实上。**
- **注释里的字样会被 `contains` / `indexOf` 命中。** Bug 443 的注释里写了
  "pub get"，把 Bug 438 的`'预检必须在 pub get 之前'`测试打挂了
  （注释在第 3023 字符，真正的命令在第 7500）。
  **断言"某事发生/不发生"时，必须匹配命令形态（如 `flutter pub get;`），
  不能匹配裸字样。**

---

### Bug 444：AOT 用的 `gen_snapshot` 是 `linux-arm64/` 下那份（内容是 x86_64）——build 内部补下载会盖掉转发层

**症状**：与 Bug 443 同一张截图（alpha.49，进度 57%）：

```
AOT 编译 (gen_snapshot)                                       57%
Dart snapshot generator failed with exit code -4
impellerc failure:
impellerc failure:
Target android_aot_release_android-arm64 failed
```

诊断段却全绿（`impellerc=ok rc=0` / `DART=ok` / `SNAPSHOT=ok` / `HEALED=0`）。
**关键背景**：用户**卸载重装**过一次，在此之前同样的包是能构建成功的。

**原因**：真机上 AOT 真正执行的那个文件，和我一直盯着的那两个**不是默认的那一个**。

---

**① 真机 AOT 走的是 `linux-arm64/`，不是 `linux-x64/`**

`flutter_tools` 的 `artifacts.dart` `_getAndroidArtifactPath()`：

```dart
case Artifact.genSnapshot:
  HostPlatform hostPlatform = getCurrentHostPlatform();
  if (hostPlatform == HostPlatform.darwin_arm64) {
    hostPlatform = HostPlatform.darwin_x64;   // 只有 macOS 做了回退！
  }
  final String hostPlatformName = hostPlatform.cliName;
  return path.join(engineDir, hostPlatformName, artifact.getFileName(_platform));
```

而 `getCurrentHostPlatform()`（build_info.dart:857）在 Linux 上直接返回
`globals.os.hostPlatform`，也就是由 **`uname -m`** 决定。

真机 Android 是 arm64 → `uname -m` = `aarch64` → hostPlatformName = **`linux-arm64`**
→ AOT 执行的路径是：

```
bin/cache/artifacts/engine/android-arm64-release/linux-arm64/gen_snapshot
```

**注意那段 TODO**：`// TODO(cbracken): Build Android gen_snapshot as Arm64
binary to run natively on Apple Silicon`（flutter/flutter#152281）。
**官方至今没有 arm64 版的 android gen_snapshot** —— 意思是
`linux-arm64/` 目录下放的那份，**文件内容就是 x86_64 ELF**。
它能不能跑，完全取决于有没有转发脚本罩着。

**沙箱目录结构双向证实了这一点**（本机实测）：

| 路径 | 大小 | 内容 |
|---|---|---|
| `android-arm64-release/linux-x64/gen_snapshot` | 6,154,880 B | `7f454c46 … 3e00` 真 x86_64 ELF（**真身**） |
| `android-arm64-release/linux-arm64/gen_snapshot` | 330 B | `#!/bin/sh` 转发脚本，`exec qemu-x86_64-static … linux-x64/gen_snapshot "$@"` |
| `linux-arm64/impellerc` | 305 B | 转发脚本，指向 `linux-x64/impellerc` |

**② 覆盖发生在 build 内部、在 reassert 之后**

`flutter build` 在 AOT 之前会检查引擎构件是否就位、缺失则补下载。
一下载就把 `linux-arm64/{gen_snapshot,impellerc,font-subset}` 覆写成
**裸 x86_64 ELF**，直接盖掉 reassert 刚放好的转发脚本 → SIGILL。

触发条件 = **构件缓存缺失**：卸载重装 / 清数据 / 首次构建。
这正好解释了"之前能构建、卸载重装后必崩"—— 用户是卸载重装后才翻车的。

> ⚠️ **排障时的一个陷阱**：日志里的
> `Flutter assets will be downloaded from https://storage.flutter-io.cn`
> 是**常驻提示**，构件已缓存时也会打印（沙箱本次构建打了这行但并未下载）。
> **不能用它判断下载是否真的发生** —— 我一开始把它当铁证，是不严谨的。

**解决**：三层，前两层是修复，第三层是兜底。

1. **把下载提前到 reassert 之前**（`build_runner.dart`）：

```sh
echo "---- 预取引擎构件（把 build 内部的下载提前）----";
flutter precache --android_gen_snapshot 2>&1 | tail -n 5;
sh -c '<reassert>' 2>&1 | tail -n 10;
flutter build apk --no-shrink --release --target-platform=android-arm64
```

   顺序改成 **precache → reassert → build**：先让下载把 `linux-arm64/` 覆盖完，
   reassert 再重建转发层；此时构件已缓存，build 内部不会再下载 → 不会再覆盖。
   `--android_gen_snapshot` 精确覆盖 AOT 那两个工具，universal
   （`impellerc`/`font-subset`）默认 `true` 会一并带上。

   ⚠️ 这里的 `| tail -n 5` 是**故意**吞掉退出码做容错：precache 只是把下载
   提前，失败不该中断构建（后面还有兜底）。**性质与 Bug 443 那次完全不同**
   ——那次是无意中被管道吞掉退出码、把失败判成成功。测试里专门有一条
   断言：precache 后面**不许**紧跟取退出码。

2. **失败后指纹确证才自愈重试**（只在真的被覆盖时才重试）：

```sh
brc=$?; if [ "$brc" != 0 ]; then
  echo "---- 构建后工具链指纹（对比上面的 AOT_FP）----";
  fp=$(sh -c '<diag>' 2>&1 | grep -E "AOT_FP=");
  echo "$fp" | tail -n 12;
  if echo "$fp" | grep -q "RAW_ELF"; then
    echo "FOA_HEAL=转发层在构建中被覆盖，重建后重试一次";
    sh -c '<reassert>' 2>&1 | tail -n 10;
    flutter build apk --no-shrink --release --target-platform=android-arm64; brc=$?;
  fi; fi; exit $brc
```

   为什么值得重试：第一次 build 已经把构件下载完了，reassert 重建后再跑
   **不会再次覆盖**（缓存已就位）→ 第二次应当成功。
   为什么用 `RAW_ELF` 当判据：若指纹不含 `RAW_ELF`（转发层完好），说明崩溃
   另有原因，重试没有意义 —— **不重试，不让用户白等一整轮**。
   为什么重试**不跑 pub get**：Bug 433 教训，pub get 会盖掉刚重建的转发层。

3. **AOT_FP 指纹**（Bug 443 加的）现在覆盖到了真机真正执行的路径：
   `android-arm64-release/linux-arm64/gen_snapshot`（真机）+ `…/linux-x64/…`（真身）
   + `linux-arm64/impellerc` + `linux-arm64/font-subset` + `dart-sdk/bin/dart`。

**验证**：

| 验证项 | 结果 |
|---|---|
| flutter_tools 源码：host 由 `uname -m` 定 | `_getAndroidArtifactPath` + `getCurrentHostPlatform` 确认 ✅ |
| 沙箱引擎目录结构对照 | 真身 6,154,880 B x64 ELF / 转发位 330 B 脚本 ✅ |
| `precache --android_gen_snapshot` 存在 | precache.dart 选项表确认 ✅ |
| 构建命令顺序 precache→reassert→build | 位置断言（去注释后）✅ |
| precache 容错且不造死代码 | 断言其后不紧跟取退出码 ✅ |
| 重试判据为 `RAW_ELF`、只重试一次 | `flutter build apk` 出现 2 次 ✅ |
| 重试段不含可执行 `pub get` | 去注释后断言 ✅ |
| AOT_FP 含 `android-arm64-release/linux-arm64/gen_snapshot` | ✅ |
| `flutter analyze lib/ test/` | `No issues found!` ✅ |
| `flutter test` | **243 项全绿**（新增 16 项）✅ |

**出现版本**：v0.1.0-alpha.49（卸载重装后暴露）
**修复版本**：v0.1.0-alpha.50

**教训**：

- **别只盯着"看起来对"的那条路径。** 我一直以为 AOT 用的是
  `android-arm64-release/linux-x64/gen_snapshot`（真身所在），
  实际真机走的是 `linux-arm64/`（host 由 `uname -m` 决定）。
  **路径里带 `x64` 不代表它就是被执行的那个，反过来也一样。**
  这类问题只能靠读上游源码 + 看真实目录结构解决，靠猜会一直错。
- **`uname -m` 这种"环境事实"要显式确认。** 沙箱是 x86_64、真机是 aarch64，
  同一份代码在两端的 host platform 解析结果**不一样**。
  沙箱里跑通的链路，不等于真机上跑的是同一条。
  （这也是 Bug 428/429/433/443 连续四次"沙箱看不出问题"的同一个根。）
- **"之前能用、重装后不行"= 缓存/持久化状态相关的强信号。**
  但凡复现条件里出现"卸载重装""清数据""首次"，先去查**什么东西被重建了**，
  而不是查代码逻辑。
- **别把常驻提示当证据。** `Flutter assets will be downloaded from …`
  每次都打，构件已缓存时也打。我一度拿它当"发生了下载"的铁证，
  这是把"日志里出现了"误当成"事件发生了"。
  **引用日志行之前，先确认这行是"事件"还是"状态"。**
- **`contains` 命中注释——第三次了。** Bug 442（注释里的 "pub get"）、
  Bug 443（注释里的 "pub get"）、这次又是（diag/heal 脚本注释里
  "被 pub get 覆盖后会变回后者"、"pub get 调 dart = arm64 上直接执行 x64 ELF"）。
  **断言"不得执行 X"时，必须先剥掉 `#` 注释行。** 已经栽三次，
  从现在起这类断言一律走 `stripComments`。
- **锚点断言要配"回归哨兵"。** 用 `indexOf` 拿位置再做大小比较时，
  一旦锚点找不到（返回 -1），`greaterThan(-1)` **恒真**，断言会悄悄失效。
  加一条"锚点必须存在"的显式断言，防止测试自己退化成摆设。
- **⚠️ 别拿"二进制里搜字符串"当入包验证。** 出包后我想确认修复是否真的
  编进了 `libapp.so`，于是去搜字符串，结果自相矛盾：

  | 字符串 | 源码里 | libapp.so 里 |
  |---|---|---|
  | `precache --android_gen_snapshot` | 1 | **1** ✅ |
  | `LD_LIBRARY_PATH` / `chmod 755` / `@QEMU@` | 多处 | 1~2 |
  | `d/lib64` / `FOAWRAP` / `gen()` / `@REAL@` | 多处 | **0** ❌ |
  | `#!/bin/sh` | 3 | **0** ❌ |

  一度以为 `_wrapGenFunc` 被 tree-shake 掉了（那真机上 `gen` 就是未定义
  命令）。查证：`fill()` 第 639 行 `.replaceAll('__FOA_GEN__',
  _wrapGenFunc.trim())` 确实引用了它 → 可达，不会被移除；且 Bug 441 的
  测试已经**真实执行**过 `gen()` 的产物（rc=0，1795 B 正常输出）。
  所以这是 **Dart AOT snapshot 的分块/对齐存储**导致的检索假象，
  不是代码缺失。
  **结论：入包验证要靠"构建时序 + 少量唯一哨兵串"，不要指望字节级
  全量比对 —— 搜不到不等于不在。**

---

### Bug 445：诊断探针自己把转发位覆写了 —— 外加两个"静默失效"的判据

**症状**（真机 alpha.50，仍是 AOT 57% 崩，`exit code -4`）：

```
AOT_FP=impellerc=wrapper
AOT_FP=impellerc=RAW_ELF
AOT_FP=gen_snapshot=wrapper
AOT_FP=gen_snapshot=RAW_ELF
AOT_FP=font-subset=wrapper
AOT_FP=dart=wrapper
QEMU_CHAIN_PROBE=impellerc=ok rc=0        ← 注意 out 是空的
FOA_HEAL=转发层在构建中被覆盖，重建后重试一次
REASSERT=0
REASSERT_DART=0
Dart snapshot generator failed with exit code -4
impellerc failure:
impellerc failure:
```

三个数字最刺眼：**`REASSERT=0` / `REASSERT_DART=0`** —— 自愈重建**一个文件都没重建**，
却宣布"重建后重试一次"，然后照样崩。

**原因**：三个独立缺陷叠在一起，**其中两个是"判据静默失效"，一个是我自己的诊断有副作用**。

---

**① 诊断探针有副作用：`--help` 把转发位覆写了（这是根因）**

`buildPreflightScript` 里有这么一段，本意是"跑一个真实 x64 二进制看 qemu 通不通"：

```sh
"$tool" --help > "$tf" 2>&1
```

`$tool` = `linux-arm64/impellerc` = **转发脚本**。转发脚本内部会
`d=$("dirname" "$0")`，x64 进程的**工作目录**与 `argv[0]` 都指向**转发位所在目录**。
于是 `--help` 留下的中间产物**落在转发位自己的路径上**，把转发脚本覆盖掉。

真机日志的**铁证**：`QEMU_CHAIN_PROBE=impellerc=ok rc=0` 这行是空的
（`out=EMPTY`，`--help` 没吐任何输出），退出码是 **4** —— impellerc 被调用时
返回 4 属正常，但它**在转发位留下了 x64 产物**。紧接着 AOT 段就
`impellerc failure:` / `gen_snapshot exit -4`。

> **诊断把被测对象弄坏了。** 这是连崩三版（alpha.48/49/50）最根本的一条：
> 我一直在加诊断，而诊断本身在制造故障。
> 修复方式：在 `/tmp` 建一个只含**软链**的沙盒目录再跑，
> `$0` 变成软链路径 → `dirname` 得到 `/tmp` 下的临时目录 → 产物落在 `/tmp`，
> 真实转发位毫发无损。（软链接照样能被 `[ -x ]` 与 `#!/bin/sh` 执行。）

**② `AOT_FP` 的 `RAW_ELF` 被判成故障 —— 判据恒为真**

`AOT_FP` 循环里**同时列了转发位和真身**，而两者的期望值**相反**：

| 路径 | 角色 | 正常形态 |
|---|---|---|
| `linux-arm64/*`、`android-*/linux-arm64/*`、`dart-sdk/bin/dart` | **转发位** | `#!`（wrapper） |
| `linux-x64/*` | **真身** | `7f454c46`（RAW_ELF） |

我原来的文案把两者写成一个
`=RAW_ELF（真 x64 二进制，未经转发 → 必 SIGILL）`，于是：

- 真身本来就是 RAW_ELF → 这个判据**在正常情况下也为真**；
- 构建命令里的自愈判据 `grep -q "RAW_ELF"` 因此**恒成立**，每次失败都白跑
  一轮"清缓存 + 重建 + 重启构建"。

真机那对 `wrapper` / `RAW_ELF` 也不是"两个时刻的值"——是**同一次执行的 6 行
输出被 `tail -n 30` 从中间截成两段**（前半落在"构建前"、后半落在"构建后"，
且有 3 行重叠）。**所以"构建后到底是不是被覆盖"，我从来没拿到过。**

修法：诊断给每行**标角色与是否合格**（`ok(SLOT)` / `BAD(SLOT,期望 …)`），
判据只看 `BAD(`。

**③ reassert 的"看形态判定"遇上形态合法的坏文件会静默失效**

原来 `put()` 的幂等判据是：

```sh
if [ -f "$2" ] && head -c 2 "$2" | grep -q '#!'; then return 0; fi
```

（"已经是转发脚本就跳过"。）这个判据本身对"位置不存在"和"位置是裸 ELF"两种
情况都能正确处理 —— 沙箱实测旧实现 `REASSERT=0` 是因为**遍历确实没跑到**。

但这里有个更根本的认识：**`linux-arm64/` 这个目录里的东西本来就该全是转发
脚本，不存在"合法的裸 ELF"**。所以"看形态"这个判据是可省的 ——
**无条件重建比看形态更可靠**，代价只是重复写几个几百字节的小文件。

```sh
# Bug 445：不信任转发位的"形态"，无条件重建
mkdir -p "$(dirname "$2")"
gen "$2" "$1"     # gen 内部是覆盖写（cat > "$1"），不需要先删
```

**④ "重启构建"必须真的让输入变化，否则 flutter 会跳过 AOT**

`flutter` 的增量构建会看到 `app.so`「已存在且比输入新」，直接跳过 AOT
target —— 转发层修好了也不会重新编译。所以自愈分支里先
`flutter clean` 造出输入变化，把 AOT 逼出来，再重启构建。

**验证**：沙箱端到端（构造"转发位被覆盖成裸 ELF"的真实场景）。

| 验证项 | 结果 |
|---|---|
| 旧实现（红） | `REASSERT=0` / `REASSERT_DART=0`，执行后头仍是 `7f454c46` ❌ |
| 新实现（绿） | `REASSERT=3` / `REASSERT_DART=4`，执行后 4 个转发位全部 `23212f62` ✅ |
| 诊断角色判定 | `linux-x64/` → `ok(REAL)`；转发位 → `ok(SLOT)` ✅ |
| 覆盖检出 | 修复前 `BAD(` ×4，修复后 `BAD(` = **0** ✅ |
| 回归哨兵 | 不许再用 `grep -q "RAW_ELF"` 当判据 ✅ |
| 探针沙盒 | 断言探针在 `/tmp` 沙盒里跑、且不许退回直接跑 ✅ |
| `flutter analyze lib/` | `No issues found!` ✅ |
| `flutter test` | **244 项全绿** ✅ |

**出现版本**：v0.1.0-alpha.50
**修复版本**：v0.1.0-alpha.51

**教训**：

- **⚠️ 诊断代码必须有"无副作用"这条硬约束。** 我为了排障往构建命令里加了四次
  诊断，其中 `--help` 探针**直接覆写了被测的转发位** —— 于是每一版都在
  "修一个、诊断制造一个"的循环里打转。**加诊断前先问：它会不会改变被测系统的
  状态？** 会的话，必须在隔离副本（软链沙盒 / 临时目录）里跑。
- **"同一个文件报两个值"先怀疑打印重复，别急着解释成"两个时刻"。**
  真机那 6 行 AOT_FP 我第一反应是"构建前/后被覆盖"，为此写了整套自愈逻辑。
  实际是 `tail -n 30` 把**一次输出截成两段**，重叠 3 行。
  **日志行数凑不齐预期的条目数，就是被截断的信号。**
- **判据里出现"两义"的取值，必然写错。** `RAW_ELF` 对真身是正常、对转发位是故障
  —— 同一个取值两种含义，判据就一定恒真或恒假。
  **修法不是改判据，是让输出带上角色、把两义拆开**（`ok(SLOT)` / `BAD(SLOT)`）。
- **"看形态"的幂等判据，在可被外部覆盖的目录里不可靠。**
  这里更可靠的做法是**无条件重建**：`linux-arm64/` 里本该全是转发脚本，
  没有"合法的裸 ELF"，所以重建永远安全，还省掉一整类判据失效的可能。
  （对照 Bug 428 的教训：`[ -f ]` 存在性判定在可被覆写的场景下是错误的不变量。）
- **测试断言也是"代码"，错了会固化成错误的契约。** 这次有 3 条测试直接
  失败了，其中 `bug442` 那条「reassert 幂等：第二轮应当 `REASSERT_DART=0`」
  固化的**正是病灶本身**。修改时我没有"改测试让它过"，而是先确认
  旧断言为什么错、再把语义改成"**最终状态幂等**"。
- **`flutter clean` 才是让 AOT 真正重跑的开关。** 只重建转发层不够 ——
  增量构建看到 `app.so` 比输入新就跳过 AOT，转发层修了也白修。

---

### Bug 446：三层诊断全绿、转发层全程完好，AOT 照样 SIGILL —— "能启动 ≠ 能编译"

**症状**（真机 alpha.51）：

```
QEMU_CHAIN_PROBE=impellerc=ok rc=0          ← 探针正常（上一版这里是空的）
AOT_FP=impellerc=wrapper ok(SLOT)           ← 构建前：全部 ok
AOT_FP=impellerc=raw ok(REAL)
AOT_FP=gen_snapshot=wrapper ok(SLOT)
AOT_FP=gen_snapshot=raw ok(REAL)
AOT_FP=font-subset=wrapper ok(SLOT)
AOT_FP=dart=wrapper ok(SLOT)
HEALED=0 / DART=ok / SNAPSHOT=ok
REASSERT=10                                 ← 重建确实执行了
REASSERT_DART=10
...
Dart snapshot generator failed with exit code -4
impellerc failure:
...
---- 构建后工具链指纹（重新采集）----
AOT_FP=impellerc=wrapper ok(SLOT)           ← 崩完之后：**仍然全 ok**
AOT_FP=gen_snapshot=wrapper ok(SLOT)
...
```

**这份日志的价值在于它证伪了前面几版的假设**：转发层**构建前后都是完好的**，
`REASSERT=10` 也确实重建了 10 个文件 —— 可 AOT 还是 SIGILL。
**所以问题跟转发层无关，Bug 444/445 一直在治一个不存在的病。**

**原因**：一个从未被覆盖的**诊断盲区** —— **所有探针都只测 `--help`**。

| 探针 | 调用形态 | 实际覆盖到的代码路径 |
|---|---|---|
| `QEMU_CHAIN_PROBE` | `impellerc --help` | 打印帮助 → 退出 |
| `smoke()` | `gen_snapshot --help` | 打印帮助 → 退出 |
| **真机 AOT** | `--snapshot_kind=app-aot-elf` | **分配大内存 + 长时间编译 + 向量指令** |

反汇编实测（`objdump`）真机那份 `gen_snapshot` 含大量 VEX 编码的 AVX 指令：

```
32 vpxor    24 vpaddd    20 vpsrld    16 vpsrlq
12 vpshufb  11 vmovdqa    8 vpslld     8 vpshufd
```

`vpshufb`/`vpxor` 这类正是**编译启动阶段算哈希**用的。而 `--help` 打印完就退出，
**根本走不到这些代码路径**。

> **"能启动" ≠ "能编译"。** 三层诊断一直报绿灯，是因为它们测的是一件
> 跟失败无关的事。

**排查过程中被排除的假设**（都靠沙箱实验证伪，避免继续瞎猜）：

| 假设 | 实验 | 结论 |
|---|---|---|
| 转发层被覆盖 | 构建前后 `AOT_FP` 对照 | ❌ 全程 ok |
| 内存不足被 OOM 杀 | 用户确认设备内存 | ❌ 8GB+ |
| 缺 amd64 运行库 | 解析 ELF `NEEDED` | ❌ 只依赖 libc/libm/libdl/libpthread，全已装 |
| qemu 不支持 AVX | 沙箱装 qemu-user 跑 AVX 程序 + CPUID 对照 | ❌ AVX/AVX2/XSAVE 均正常暴露 |
| gen_snapshot 二进制本身坏 | 沙箱原生跑真实 AOT | ❌ 能完整走完编译流程 |

最后一条尤其关键：在沙箱（原生 x86_64）直接跑真机那份 `gen_snapshot` 做真实 AOT，
得到 **`rc=134`（SIGABRT）+ 业务报错**（dill 缺 TFA）——
**它自己主动 abort，不是被信号杀死的**。这证明**二进制没问题**，
且"真实 AOT 负载"在原生环境下能跑。

**解决**：加**真实 AOT 负载探针**（`AOT_LOAD=`），测负载而不是测启动。

```sh
gsw=@ENGINE@/android-arm64-release/linux-arm64/gen_snapshot
ld_dir=/tmp/.foa_aotload_$$
( cd "$ld_dir" && "$gsw" --deterministic --snapshot_kind=app-aot-elf \
    --elf="$ld_dir/probe.so" "$dill" ) > "$ld_dir/out" 2>&1
lrc=$?                              # 紧邻捕获，不许过管道（Bug 443）
case "$lrc" in
  0)   echo "AOT_LOAD=ok（真实 AOT 负载跑通）" ;;
  132) echo "AOT_LOAD=SIGILL（qemu 在编译负载下崩 —— 真机那个 exit -4 就是这个）" ;;
  139) echo "AOT_LOAD=SIGSEGV" ;;
  134) echo "AOT_LOAD=SIGABRT" ;;
  *)   echo "AOT_LOAD=rc$lrc（非信号退出=程序自身报错，执行环境是好的）" ;;
esac
```

设计要点（每一条都是前面踩过的坑的直接产物）：
- **输入用真实的 `app.dill`**（上一次 `KernelSnapshot` 的产物），不是玩具样本；
- **判据用退出码**，且**区分信号退出（128+n）与程序自身报错** ——
  这是本探针的核心价值：`132` = 环境承载不了，`134`/其它 = **环境是好的**；
- **在 `/tmp` 临时目录里跑**（Bug 445 教训：诊断不许有副作用）；
- **rc 紧邻捕获**，不过管道（Bug 443 教训）；
- **失败不阻断构建**（它只是观测）。

沙箱实测探针输出（用真实 dill）：

```
AOT_LOAD=begin dill=...app.dill size=8620880
AOT_LOAD=rc=134
AOT_LOAD=SIGABRT
AOT_LOAD_OUT=...dispatch_table_generator.cc: 432: error: Missing table selector metadata!~
```

**验证**：

| 验证项 | 结果 |
|---|---|
| 探针用真实 AOT 参数（非 `--help`） | `--snapshot_kind=app-aot-elf` ✅ |
| 输入为真实 app.dill | 接受 `@PROJ@/build/app.dill` ✅ |
| 判据用退出码且区分 132/134 | ✅ |
| rc 捕获不过管道 | 正则反证 ✅ |
| 探针无副作用（临时目录 + 清理） | ✅ |
| 端到端真实执行 | 沙箱跑出 `rc=134` + 业务报错 ✅ |
| `flutter analyze lib/ test/` | `No issues found!` ✅ |
| `flutter test` | **251 项全绿**（新增 7 项）✅ |

**出现版本**：v0.1.0-alpha.51（问题自始存在，只是此前被其他故障掩盖）
**修复版本**：v0.1.0-alpha.52（**注意：本版是诊断增强，不是修复**——
根因尚未确定，见下）

**教训**：

- **⚠️ 探针必须覆盖"真实负载"，不能只覆盖"能否启动"。**
  我连加三层诊断都在测 `--help`，而失败发生在 `--help` 走不到的代码路径上。
  **加探针前先问：我测的这件事，跟失败的那件事是同一件吗？**
- **用户的否定性回答能砍掉整片搜索空间。** 我问了两个问题：
  「以前成功过吗」→ **从来没成功过**（推翻"回归"假设，不用去找哪个版本改坏）；
  「内存多少」→ **8GB+**（推翻 OOM 假设）。
  两条信息各自砍掉一半方向，比我自己猜十轮都管用。
  **不确定时先问，别硬猜。**
- **"构建前后状态相同"是极强的证伪信号。** 日志里构建前后 `AOT_FP` 都是 ok ——
  这说明**被测对象根本没变化**，那么"它被破坏"这个假设一定错。
  **看到这种日志要立刻换方向，而不是加更多同方向的诊断。**
- **假设要用实验证伪，不要用推理排除。** 我列的五个假设（转发层/内存/库/
  AVX/二进制）全部做了实验，其中"qemu 不支持 AVX"这条我一度很确信，
  实验做完发现是错的。**确信度不能替代验证。**

---

### Bug 447：真机 SIGILL 真因锁定——qemu TCG 按 CPU 模型门控 SIMD 指令；`-cpu max` 一行修复

**日期**：2026-09-19（alpha.53）
**症状**：真机 alpha.52 构建在 AOT 57% 崩：`gen_snapshot exit -4`（SIGILL）、
`impellerc failure:` ×2（同样 -4）。转发层全程完好（`AOT_FP` 前后全 ok）、
内存 8GB+、诊断探针全绿。`AOT_LOAD=skip(尚无 app.dill)`（这行本身是 Bug 447 的第二病灶，见下）。

**真因（沙箱用真机逐位同版 qemu 复现锁定）**：

1. **qemu TCG 对 SIMD 指令按 CPU 模型特性位门控**。CPU 模型没有 AVX 特性位时，
   翻译器一碰到 VEX 指令就直接给 guest 发 SIGILL（`gen_illegal_opcode`），
   **程序自己根本没机会看到这条指令**。
2. gen_snapshot（objdump 全量清点）含 **10 种裸 AVX 指令**（vpxor/vpshufb/
   vmovdqa/vmovdqu/vpaddd/vpalignr/vpshufd/vpslld/vpsrld/vpsrlq/vzeroupper，
   无 AVX2/AVX-512），AOT 编译主循环必经。
3. x86_64 host 上 qemu-user 的**默认 CPU 模型含 AVX**（实测 CPUID AVX=1/AVX2=1），
   所以沙箱从来没复现过；**arm64 host 构建包的默认模型行为不同**——真机一进
   编译主循环就撞门。

**沙箱复现实验链**（Debian bookworm `qemu-user_7.2+dfsg-7+deb12u18+b3`，
与真机 `QEMU_CHAIN_VER` 显示的版本**逐位一致**）：

| 实验 | 结果 | 结论 |
|---|---|---|
| 裸 AVX 程序（vpxor/vpshufb，无 CPUID 保护），默认参数 | rc=42 通过 | x86 host 默认模型含 AVX |
| 同一程序，`-cpu qemu64` | **rc=132 = SIGILL** | **与真机 exit -4 逐位一致，门控实锤** |
| 同一程序，`-cpu max` | rc=42 通过 | max = TCG 支持全集，门全开 |
| CPUID 探针（默认模型） | AVX=1 AVX2=1 XCR0 含 AVX 位 | 默认 = max 行为 |
| 真机同链路（`-L /` + ld.so 显式加载）真实 AOT | rc=134 业务报错 | 链路形式无关 |
| bookworm glibc 2.36 全链路（ld.so+libc 全 2.36） | rc=134 / avxtest rc=42 | **rootfs glibc 无关** |

顺带证伪：`-cpu qemu64` 下连 `xgetbv` 都 SIGILL（XSAVE 特性位同样被门控）——
门控机制覆盖所有特性相关指令，不止 AVX。

**修复（alpha.53）**：

1. **转发 exec 行显式 `-cpu max`**（`_wrapGenFunc` 两处）：
   `exec @QEMU@ -cpu max -L / "@LOADER@" "@REAL@" "$@"`。
   max 只暴露 TCG **支持**的特性，不会暴露翻译不了的指令；x86 host 上无害
   （沙箱端到端验证过）。**一行级修复，不需要重写、不需要 qiling。**
2. **修探针盲区**：`AOT_LOAD` 找 app.dill 的 glob `ls "$bd"/app.dill
   "$bd"/[a-z]*/app.dill` 只探两层，而 dill 实际在
   `build/app/intermediates/flutter/release/`（四层深）——alpha.52 真机日志
   `AOT_LOAD=skip(尚无 app.dill)` 是**探针瞎，不是 dill 不存在**（kernel_snapshot
   明明已经跑完才走到 AOT）。改 `find "$bd" -maxdepth 6 -name app.dill -type f`。
3. **新增裁决探针 `AOT_LOAD_DEF=`**：绕过 wrapper，用裸 qemu（不带 -cpu）直接跑
   同一真身同一 dill。真机日志上两个 rc 并排：
   - `DEF=132` 且 `AOT_LOAD=0/134` → 门控实锤 + `-cpu max` 修复有效；
   - 两者都 132 → max 也救不了 → arm64 TCG 后端问题，下一步换 Debian trixie
     静态 qemu 9.x（静态二进制可直接放进 rootfs，无依赖）；
   - `DEF=0/134` → 默认模型也没门，SIGILL 另有源头。

**真机裁决树（alpha.53 日志怎么看）**：

```
AOT_LOAD=rc=0        → 真实 AOT 跑通，构建应成功 → 结案
AOT_LOAD=rc=134/其它 → 环境好，程序自身报错（dill 元数据等）→ 看业务错
AOT_LOAD=rc=132      → wrapper(-cpu max) 还 SIGILL → 看 AOT_LOAD_DEF
  DEF=132            → max 也门死 → arm64 TCG bug，换 qemu 9.x 静态版
  DEF=0/134          → 矛盾（不该发生）→ 回来找我
```

**教训**：

- **"版本相同"不等于"行为相同"——host 架构是独立变量。** 同一份 qemu 源码包，
  x86 build 与 arm64 build 的默认 CPU 模型行为不同。复现实验要连 host 一起对齐，
  对不齐就要留一条"真机专属变量"的裁决探针。
- **诊断探针的查找范围必须覆盖真实产物的真实深度。** 两层 glob 在沙箱里看着
  正常（沙箱手工造的目录浅），真机的真实目录树深四层。**探针找不到东西时
  首先怀疑探针瞎，其次才是"东西不存在"。**
- **修复要带"裁决探针"一起发。** `-cpu max` 是基于强证据的修复，但 arm64 默认
  模型这个最后一环只能真机验证——把 DEF 对照探针塞进同一版，若修复无效，
  下一轮诊断信息已经就位，不用再发一版。
- **用户问"要不要换方案"时，先把机制查透。** 本轮用户问"是不是要换 qiling /
  proot 当翻译层"——查完发现 proot 根本不做指令翻译（它管环境，qemu 管翻译，
  两层正交），qiling 与 qemu 同源（Unicorn 是 qemu 的库化 fork）踩同样的门控。
  **概念澄清本身就是方案省。**

---

## 十二、提交 Bug 记录模板

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
