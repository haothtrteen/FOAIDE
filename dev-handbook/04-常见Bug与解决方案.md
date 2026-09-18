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
2. **Maven 镜像** → `~/.gradle/init.gradle` 写入阿里云三仓（public/google/gradle-plugin），`allprojects` + `settingsEvaluated` 双保险（settings 的 pluginManagement 和 dependencyResolutionManagement 也要覆盖，单写 allprojects 对 AGP 9 不够）；
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
