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

### Bug 604 · `Failed to create MD5 hash for file .../libapp.so` —— 真凶是**没设 `FLUTTER_STORAGE_BASE_URL`**，不是空 ABI 目录、不是权限、不是缓存（2026-09-25，alpha.74 发现 / alpha.77 二修 / **alpha.78 三修定论**）

> ⚠️ **本节被修正过两次，请直接看文末「三修修正」。**
> - 第一版结论："overlayfs EIO 坏副本" → 当天被**推翻**。
> - 第二版结论："`flutter/release/` 下的**空 ABI 目录**" → alpha.78 又被**推翻**。
> - **第三版（当前结论）：根因是 `FLUTTER_STORAGE_BASE_URL` 未设置**，
>   引擎构件 URL 被拼成 `dl.google.com`（本环境 TLS 阻断）→ 依赖解析失败
>   → 下游 task 状态不一致 → 报出这个极具误导性的 MD5 错误。
>
> 前两版内容保留，用于记录误判过程 —— **它们的共同错误是：把"次生现象"
> 当成了根因。**

**症状**（`flutter build apk --no-shrink --release --target-platform=android-arm64`）：

```
Execution failed for task ':app:mergeReleaseJniLibFolders'.
> Cannot access output property 'outputDir' of task ':app:mergeReleaseJniLibFolders'.
  Accessing unreadable inputs or outputs is not supported.
   > Failed to create MD5 hash for file: .../merged_jni_libs/release/
     mergeReleaseJniLibFolders/out/arm64-v8a/libapp.so
```

**三个错误假设**（都实测推翻了，别重走）：

| # | 假设 | 实测反证 |
|---|---|---|
| 1 | `libapp.so` 权限坏了 | `stat` 显示 `0644`；`sudo -u nobody md5sum` **成功**算出正确摘要 |
| 2 | 旁边 `libproot.so` 是 `0711`（`rwx--x--x`，别人不可读）拖垮任务 | 改成 `0644` 后**仍报同样错**。**这个权限确实该修**（见下），但不是本次根因 |
| 3 | Gradle 文件哈希缓存命中坏条目（清目录无用因为 `(path,len,mtime)` 没变） | 清目录 + 改权限后重跑，**文件名却变了**（arm64-v8a → armeabi-v7a）——说明不是一个固定文件的问题 |

**真凶（`--stacktrace` 才能看到，主输出只有一句含糊话）**：

```
Caused by: java.io.UncheckedIOException: Failed to create MD5 hash for file: .../armeabi-v7a/libapp.so
	at org.gradle.internal.hash.DefaultFileHasher.hash(DefaultFileHasher.java:43)
	...
Caused by: java.io.IOException: Input/output error
	at org.gradle.internal.hash.DefaultStreamHasher.doHash(DefaultStreamHasher.java:47)
```

**`java.io.IOException: Input/output error`（EIO）** —— 文件系统层面的**真实读错误**，
不是权限（那是 `AccessDeniedException`）。Gradle 的措辞 `unreadable inputs or outputs`
会把 EIO 和权限错误混在一起说，极具误导性。

**取证判据**（决定性，一条命令区分）：

```bash
dd if=<疑似坏文件> of=/dev/null bs=1M   # EIO → 真损坏；静默成功 → 是权限/缓存问题
```

本次实测：`merged_jni_libs/.../armeabi-v7a/libapp.so` → **EIO**；
而其**源文件** `intermediates/flutter/release/armeabi-v7a/app.so` → **可读**。
→ 结论：**坏在"复制到 merged_jni_libs 之后"，是副本损坏**，不是源文件坏。
环境特征：根文件系统是 **overlayfs**（`metacopy=off`，容器内），
`mergeReleaseJniLibFolders` 的复制步骤在此类挂载上会偶发产生读不出的副本。

**解决**（两条一起做）：

1. **清掉被污染的合并目录**：`rm -rf build/app/intermediates/merged_jni_libs`；
2. **清掉多余 ABI 的 AOT 产物**（本例的真正触发条件）：
   ```bash
   rm -rf build/app/intermediates/flutter/release/{armeabi-v7a,x86_64}
   ```
   `abiFilters += listOf("arm64-v8a")` 只要 arm64，但 Flutter 的 AOT 阶段
   仍产出了三套 `app.so`（共 119MB）；`mergeReleaseJniLibFolders` 会把它们
   **全部**合并再交给 AGP 过滤，于是白白多复制两份、多两个撞 EIO 的机会。
   删掉后只剩 arm64 的 14MB，构建 **141.6s** 通过。

**顺带修掉的隐患**：`android/app/src/main/jniLibs/arm64-v8a/libproot.so`
自 2026-09-16 起权限是 `0711`（`rwx--x--x`）——**其他用户只能执行不能读**，
Gradle 算 MD5 必须读 → 迟早报错（本次虽非主因，但它是同一报错文案的
另一个真实来源）。已 `chmod 644`。**判据**：`jniLibs` 下的 `.so` 必须
对非 owner 可读（`0644`），不要留 `0711` 这种"可执行但不可读"的权限。

**教训**：
- **`unreadable inputs or outputs` 是一句歧义词**，至少对应三种根因（权限 / 哈希缓存 / 文件系统 EIO）。必须先 `--stacktrace` 拿最底层 `Caused by`，再用 `dd` 二分"源文件 vs 副本"，别凭文案猜。
- **报错里点名的文件可能不是坏文件**：Gradle 遍历目录时整个任务失败，报的第一个文件名有随机性（本次 arm64-v8a → armeabi-v7a 变了两次），**"文件名每次都不同"本身就是"环境级/随机性故障"的强信号**，而不是"某个文件坏了"。
- **与 `abiFilters` 配套清理**：凡 `abiFilters` 收敛到单 ABI，构建前顺手删掉其它 ABI 的 `intermediates/flutter/release/*/`，省复制、省体积、少一类随机失败。

#### ⚠️ 二修修正（2026-09-25 当天，alpha.77 出包时复发）

**上面第一版的"EIO 坏副本"结论不完整，必须按本节执行。** 复发时的实测证据链：

| 实验 | 结果 | 推翻/确认了什么 |
|---|---|---|
| `dd if=merged_jni_libs/.../arm64-v8a/libapp.so of=/dev/null bs=1M` | **顺利读完 14MB，45.3 MB/s，无 EIO** | ❌ 推翻"副本一定损坏"——文件本身好得很 |
| `gradlew --stop` 后重跑 | 11s **同样挂** | ❌ 推翻"daemon 状态缓存" |
| 清 `merged_jni_libs` 后构建（第 1 次） | ✅ 成功 **139.1s** | 看似有效 |
| 清 `merged_jni_libs` 后构建（第 2 次） | ❌ 挂 **5.9s** | ❌ 推翻"清目录是稳定解法"——纯属撞运气 |
| 清 `merged_jni_libs` 后构建（第 3 次） | ❌ 挂 **1s** | 同上 |

**关键判据是耗时**：成功的第 1 次跑了 **139 秒**（真的重编了 AOT）；失败的第 2、3 次都是**秒挂**（AOT 被增量跳过，`libapp.so` 没重新生成）。

**真正的触发条件**（本次找到）：

```bash
ls -la build/app/intermediates/flutter/release/
# arm64-v8a/      ← 有 app.so
# armeabi-v7a/    ← **空目录**（0 字节）
# x86_64/         ← **空目录**（0 字节）
```

`flutter build --target-platform=android-arm64` 只编 arm64，但 **Flutter 的 Gradle 插件仍会为
v7a / x86_64 建出目录**（只建目录、不产文件）。`mergeReleaseJniLibFolders` 合并时遇到这两个
**空目录**，按"预期该有文件却没有"处理 → 报 `unreadable` / 算不出 MD5。

> 所以第一版把根因记成"overlayfs 复制出坏副本"是**误判**：那次清完目录恰好成功，
> 被当成了因果。EIO 可能在**某些**场景真实存在，但它**不是**本 bug 的稳定触发因。

**正确的解法（顺序敏感，必须照做）**：

```bash
# 1. 清合并产物
rm -rf build/app/intermediates/merged_jni_libs
# 2. 删掉多余 ABI 的**空目录**（这才是真正的触发条件）
rm -rf build/app/intermediates/flutter/release/{armeabi-v7a,x86_64}
# 注意：-rf 而不是 rmdir —— 有的环境里这些目录里会残留旧 .so
```

实测：清完后构建 **125.3s 一次通过**，六项验证全绿。

**⚠️ 不要尝试的两种解法（已实测无效，别浪费时间）**：

1. `gradlew --stop` 停 daemon 重跑 —— 无效，11s 仍挂。不是状态缓存问题。
2. 在 `build.gradle.kts` 里给 `mergeReleaseJniLibFolders` 加
   `doNotTrackState(...)` —— **反而更糟**：报错会从 `Cannot access output property`
   变成 `Changes are not tracked, unable determine incremental changes`
   （`ResolveInputChangesStep` 直接抛 `IllegalStateException`），
   因为 AGP 的该 task **本身就是增量 task**，Gradle 9 里关掉状态跟踪就
   等于"没法算输入变更"。加 `outputs.upToDateWhen { false }` 也救不回来
   （2s 挂）。**这条路是死的，已回退该改动，勿重试。**

**根治方向（未做，供后续）**：在 `android/app/build.gradle.kts` 里显式声明
`ndk { abiFilters.clear(); abiFilters += "arm64-v8a" }` 之外，可考虑让 Flutter
不要建多余 ABI 目录（`--target-platform` 已是 arm64 却仍建，属 Flutter 插件行为）。
当前用构建前清理脚本兜住即可 —— 已固化进 `SKILL.md` 第 3 步。

**新增教训**：
- **"清理后成功"极易被误认为因果**。判定一个操作是否真的有效，必须**连续重复至少两次**（本次第 2 次就打脸）。单次成功永远不能作为"解法"的证据。
- **报错耗时是重要信号**：秒挂 = 失败发生在早期阶段（增量跳过导致前置产物缺失）；跑满时长才挂 = 失败发生在该阶段真实执行中。两者根因通常不同。
- **报错点名的路径可能是表象**：`libapp.so` 每次都被正常生成（14MB），真正让任务失败的是同级的**空目录**。看到 `unreadable` 要检查**整个目录结构**，不只看点名那个文件。

#### ⚠️ 三修修正（同日晚，alpha.78 出包时复发，真因这才定论）

**alpha.78 出包时照二修正解做了预清理，同一个错误再次出现** —— "空 ABI 目录"
结论被推翻。这轮拿到了一整套可复现的证据链：

| # | 实验 | 结果 |
|---|---|---|
| 1 | **完整执行二修正解**（清 `merged_jni_libs` + 清空 ABI 目录）再构建 | ❌ **32.4s 同样报错** → 清理不是充分解法 |
| 2 | 检查 `flutter/release/` | **只剩 `arm64-v8a`**，没有空目录 → 预清理本身生效了，但没用 |
| 3 | 检查报错点名的 `libapp.so` | 存在、14,316,440 B、刚生成 |
| 4 | `dd` 读全文件 + `md5sum` + **Java（Gradle 同款 API）算 MD5** | **全部成功**（`a7c0f14e…`，2.9 GB/s）→ 文件没坏、读得了 |
| 5 | 单独跑 `gradlew :app:mergeReleaseJniLibFolders` | ✅ **BUILD SUCCESSFUL**（UP-TO-DATE）→ task 本身没病 |
| 6 | 复跑 `flutter build apk` 抓全量日志 | 露出**真实错误**：`Could not resolve io.flutter:arm64_v8a_release … Could not HEAD 'https://dl.google.com/…' … Remote host terminated the handshake` |
| 7 | `curl` 自检 | `dl.google.com` / `storage.googleapis.com` **TLS 阻断**；`storage.flutter-io.cn` 200；**`FLUTTER_STORAGE_BASE_URL` 未设** |
| 8 | `export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn` + 预清理再构建 | ✅ **BUILD SUCCESSFUL 164.2s**，日志出现 `Flutter assets will be downloaded from https://storage.flutter-io.cn` |

**三修结论（当前）**：根因是 **`FLUTTER_STORAGE_BASE_URL` 未设置（或新会话里丢了）**。
引擎构件（`flutter_embedding_release` / `arm64_v8a_release`）只发布在 Flutter 官方仓，
URL 由这个环境变量拼出；未设 = `dl.google.com` = 本环境 TLS 阻断 = 依赖解析失败。
那个吓人的 `Failed to create MD5 hash` 是**次生现象**：依赖解析失败 →
`releaseRuntimeClasspath` 不完整 → Flutter 复制 task 与 merge task 的输入输出
状态不一致 → Gradle 9 做快照时报"无法访问输出 / 算不出 MD5"。

> **为什么二修会误判**：alpha.77 那次"清理后成功"时，引擎构件**在本地缓存里**
> 可直接满足解析，网络根本没被触碰 —— 清理与成功只是**相关**不是**因果**。
> 这恰好印证了二修自己写的教训："清理后成功"极易被误认为因果。
> 空目录是否在**某些**场景也有影响，本轮无法证明也无法证伪 ——
> **预清理照做**（无害的保险），但它**不是**稳定解。

**修正后的正解（第 1 步换人）**：

```bash
# 1️⃣ 先查环境变量（这才是命门，见 SKILL.md 第 1 步 / Bug 419）
echo $FLUTTER_STORAGE_BASE_URL    # 必须是 https://storage.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export PUB_HOSTED_URL=https://pub.flutter-io.cn

# 2️⃣ 预清理照旧（保险，不是解药）
rm -rf build/app/intermediates/merged_jni_libs
rm -rf build/app/intermediates/flutter/release/{armeabi-v7a,x86_64}

# 3️⃣ 正常构建；日志开头必须看到
#    "Flutter assets will be downloaded from https://storage.flutter-io.cn"
```

**判据更新**：看到 `Could not HEAD/GET 'https://dl.google.com/…' …
Remote host terminated the handshake`（或 `The server may not support the client's
requested TLS protocol versions`）= **网络被阻断，先查环境变量**，
别再追那个 MD5。

**三修新增教训**：
- **同一个报错文本可能由多个不同根因触发**，修好一次不代表这个报错从此只有一个解。复发时**先怀疑上次的结论**，重新取证。
- **报错点名的文件要亲手读一遍**：这轮 `dd` / `md5sum` / **Java**（Gradle 同款 API）三路验证都正常 —— 文件没毛病，就该怀疑**报错本身在撒谎**（它是次生现象）。
- **抓全量日志比看 tail 尾巴重要**：`tail -40` 只看得到 MD5 错误，全量日志里才有真正的 `Could not resolve … dl.google.com`。二修时代只看尾部，错过了真凶。
- **环境变量是会话级的**：上个会话设了，这个会话可能就没 —— **构建脚本的成败不能依赖"上次设过"**，第一步永远是自检（skill 里那 4 条 curl + 2 个 echo）。

---

### Bug 605 · 设计器预览"黄框没了但啥都不显示"（2026-09-25，alpha.78）

**症状**：导入自己的 `main.dart` 后，设计器预览区**一片空白** —— 既没有内容，也没有之前的黄色"未识别"提示框。用户原话：「黄框确实没了，但是啥都不显示了」。

**真因**：`_unknownApprox` 里的 `Stack` 缺一个**定尺寸的孩子**。

```dart
// ❌ 旧代码
child: Stack(
  clipBehavior: Clip.none,
  children: [
    if (inner != null) inner,   // ← inner 为 null 时，Stack 一个非 positioned 孩子都没有
    Positioned(...),            // ← 问号角标是 positioned，不参与定尺寸
  ],
),
```

`Stack` 的尺寸由**非 positioned 的孩子**决定。问号角标是 `Positioned`，不算；一旦 `inner` 为 null（既没子节点也没认出的图标），`Stack` 就量不出大小。在 `Column` 这类**不约束孩子**的父级里，`performLayout` 直接断言失败：

```
A Stack requires bounded constraints from its parent.
Failed assertion: 'size.isFinite'
```

**崩在预览区 = 整棵预览树渲染不出来** —— 这就是"啥都不显示"。

**修法**：

```dart
// ✅ 给一个保底的可见尺寸，保证 Stack 永远量得出大小
inner ??= SizedBox(
  width: vis.width ?? 80,
  height: vis.height ?? 32,
);
```

**新增教训（本 Bug 最贵的一课）**：

- ⛔ **我写了两版回归测试，两版都是绿的，而真机上照样崩。**
  - **第 1 版**：用"没有 `children` **字段**"的节点 —— `children` 为 null 根本走不到出问题的分支，**加不加修复都绿**。
  - **第 2 版**：改用 `children: const <DesignNode>[]`（空列表），构造没问题了，但测试只调了 `renderPreview(node)` —— 而崩溃分支 `_previewShell` **只有 `node == _root` 才会走**！传进去的不是 `_root`，于是**又绿了**。
  - ✅ **解法**：给 `DesignPage` 加 `@visibleForTesting debugSetRoot()`，让测试能把待测节点**真的设成 `_root`**，走真机同一条路。
- ✅ **唯一有效的测试有效性检验：写完防崩溃测试后，把修复回退一次，看它变不变红。**
  这个动作不能省。本次一验就发现前两版全是假测试。
- 📌 **手造最小节点可能"构造上就崩不了"**：外层 `Container` 恰好能拿到尺寸时，那条路径永远不崩。真正崩的是**用户真实文件**那条路（`GridView.count` 展开 6 个 `_buildActionButton`，层层叠下来才出现无尺寸的 `Stack`）。**回归测试必须包含一条用真实文件跑的**。
- 📌 **探针报的异常要溯源到具体行**：曾有个探针报"崩溃"，实际是探针**自己的错** —— 它在 `pumpWidget` 之后又 `pumpWidget` 了一次，`state` 已 unmount，再调 `renderPreview` 会在 `_theme` 里抛 `This widget has been unmounted`。别把探针的 bug 当成产品的 bug。

---

### Bug 606 · 预览里横着一大坨源码文本（2026-09-25，alpha.78）

**症状**：设计器预览正中央出现一大段源码原文：

```
// 使用 GridView 替代复杂的 Row/Column 嵌套，更灵活
            GridView.count(
              shrinkWrap: true,
              ...
```

版面被撑爆，用户观感就是"界面没出来 / 啥都不显示"。这个 Bug 和 Bug 605 是**同一个用户反馈的两个叠加成因** —— 只有两个都修掉，预览才真的正常。

**真因**：`_unknownPlaceholder` 判定"纯注释节点"的规则太松。

```dart
// ❌ 旧代码：只看开头是不是 //
final isComment = rawStr.trimLeft().startsWith('//');
```

而用户最常见的写法是 **`// 注释` 紧跟组件**（注释说明这个组件为什么这么写）。旧判定把这个**组件节点**误判成注释节点，于是把**整段源码当文字吐了出来**。

**修法**：判据改成「**删掉所有 `//` 行注释后，还剩不剩代码**」。

```dart
bool isPureCommentSource(String raw) {
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('//')) continue;
    return false; // 有代码 → 不是纯注释
  }
  return true;
}
```

**新增教训**：
- **"以某个字符开头"这类判据，几乎总是不够的**。判"是不是纯 X"要**排除掉 X 的成分后再看剩什么**，而不是只看开头。
- **测试要用真实数据**：这条 bug 用手造节点很难想到（谁会想到给 unknown 节点塞一段带前导注释的源码？），是**把用户真实文件跑一遍**才暴露的。

---

### Bug 607 · `Icon` 的 `color:` 被当成子组件（2026-09-25，alpha.78）

**症状**：`Icon(Icons.check_circle, color: Color(0xFF10B981))` 在预览里，**图标下面多出一个色块**。

**真因**：`_innerChildren` 在拿不到 `child:` / `children:` 时，会**扫所有参数**找第一个能解析成 widget 的：

```dart
// ❌ 旧代码
for (final a in call._args) {
  final found = _firstWidgetIn(a.argumentExpression);
  if (found != null) return found;   // ← 扫到 color: Color(...)，认了
}
```

而 `Color(...)` / `BoxDecoration(...)` 这些**属性值构造**长得和 widget 一模一样（有名字、有括号、参数还能嵌套），`_asWidgetCall` 完全分不出来 —— 于是**参数值被当成了子组件**。

**修法**：加一张「参数值类型」黑名单，扫参时跳过：

```dart
const Set<String> kNonWidgetTypeNames = {
  'Color', 'BoxDecoration', 'EdgeInsets', 'TextStyle', 'Duration', ...
};
// 扫参时：
if (_isValueTypeCall(v)) continue;
```

**新增教训**：
- **"看起来像"不等于"是"**：`Color(...)` 和 `Container(...)` 在语法树上完全同类。靠**结构**判别不了，必须靠**语义白/黑名单**。
- 这个 bug 之前一直**被 Bug 605 的崩溃掩盖着**（树根本渲染不出来，自然看不到多出来的色块）。**修完崩溃类 bug 后要重新看一遍渲染结果**，可能露出下一层问题。

---

### Bug 608 · `Failed to create MD5 hash .../libapp.so` 又来了——环境变量没问题，真凶是 **Gradle VFS watching 在沙箱 overlay fs 上干扰快照读**（2026-09-25，alpha.79 出包，一修误判 / 二修定论）

**症状**：`flutter build apk` 挂在 `:app:mergeReleaseJniLibFolders`：

```
> Cannot access output property 'outputDir' of task ':app:mergeReleaseJniLibFolders'.
  Accessing unreadable inputs or outputs is not supported. Declare the task as
  untracked by using Task.doNotTrackState().
   > Failed to create MD5 hash for file: .../merged_jni_libs/release/
     mergeReleaseJniLibFolders/out/arm64-v8a/libapp.so
```

报错文本与 **Bug 604 一模一样**——但这次 `FLUTTER_STORAGE_BASE_URL` 已设
（构建日志两处出现 `storage.flutter-io.cn`）。**同报错文本的第三个根因登场**。

**定性：不是网络**。`--stacktrace` 拿到底层异常：

```
Caused by: java.io.IOException: Input/output error          ← EIO，内核级读错误
	at org.gradle.internal.hash.DefaultStreamHasher.doHash
	...
	at org.gradle.internal.execution.impl.DefaultOutputSnapshotter$1.visitOutputProperty
```

EIO 发生在 Gradle 给 task **输出做状态快照**（MD5 hash）读文件时——网络/resolve
阶段根本没到。

**排除链**（每步亲手做过，全部正常）：

| 实验 | 结果 | 排除了什么 |
|---|---|---|
| 原样重跑（604 判据：偶发先重跑） | 再挂，4.6s，同位置 | 偶发抖动 |
| `dd` + `md5sum` 全文读报错文件 | 正常，可算 MD5 | 文件损坏 / 权限 |
| `./gradlew --stop` 后重建 | 仍挂 | daemon VFS 缓存脏状态 |
| `flutter clean` 全新 build 重建 | 仍挂 | 半成品 intermediates |
| shell 写 14MB 后立刻读 ×5 轮 | 全过 | 「写后立刻读」竞态 |
| **Java**（`FileInputStream`+`MessageDigest`，Gradle 同款 API）全文读 | **正常**，MD5 与 shell 一致 | Java 进程读不出 |
| `org.gradle.parallel` | 项目本来就是 `false` | 多 task 并行竞态 |

磁盘 242G、内存充足、dmesg 无 I/O error。**文件没毛病，任何进程任何时刻都读得出，
唯独 daemon 的快照读 EIO**——挂点文件还会漂移（arm64-v8a ↔ armeabi-v7a），但总是
当场刚写完的 libapp.so。

**一修（误判）：`doNotTrackState()`**。报错信息自己给了"官方逃生门"，试了：

```kotlin
tasks.matching { it.name.endsWith("JniLibFolders") }.configureEach {
    doNotTrackState("...")   // Gradle 9 此方法必须带 reason 参数
}
```

结果换了个错：**`Changes are not tracked, unable determine incremental changes.`**
—— `MergeSourceSetFolders`（mergeReleaseJniLibFolders 的真身）继承 AGP 的
`NewIncrementalTask`，增量逻辑**依赖先前状态**，与 doNotTrackState 天然不兼容。
此路不通，**撤回**。

**二修（定论）：`org.gradle.vfs.watch=false`**。在 `gradle.properties` 加一行：

```properties
org.gradle.vfs.watch=false
```

撤掉 doNotTrackState、保留正常状态跟踪 → **一次过，BUILD SUCCESSFUL 203.2s**。

根因解释：Gradle 的 VFS 层默认用 inotify 监听构建输出目录。**inotify 与 overlayfs
（lowerdir/upperdir 多层叠合）的组合有历史雷区**：监听状态与真实文件状态错位后，
快照读取拿到坏句柄/坏页 → EIO。这不是文件、不是网络、不是 Gradle 逻辑 bug，
是**文件系统观察器在容器 overlay 上不可靠**。关掉 watching 后 Gradle 每次构建
重新快照（代价：增量判断变保守，构建稍慢，本项目 203s 正常范围）。

**⚠️ 与 alpha.78 成功构建的矛盾**：同一沙箱 alpha.78（当天早些时候）构建成功。
推断 overlay 层状态在两次构建之间发生了变化（沙箱休眠恢复/存储层迁移），
使 inotify 行为由"侥幸正常"变为"稳定出错"。**这类"昨天能跑今天不能"的环境差异，
多数不是项目代码问题，别在代码里找。**

**新增教训**：
- **同报错文本第三个根因**（604: 未设环境变量；608: VFS watching EIO）。判据要记
  **底层异常类型**：`--stacktrace` 的 `Caused by` 一眼定性——`handshake`/`resolve`
  是网络，`Input/output error` 是读文件，两码事。
- **报错信息末尾的"官方建议"未必可用**：`doNotTrackState()` 对普通 task 是逃生门，
  对 AGP 增量 task 是另一个坑。**AGP task 是 IncrementalTask 家族，跳过状态跟踪
  会被增量逻辑反杀**。
- **排除链做完（6 项全正常）仍找不到根因时，换"变量二分"**：这次唯一的自由变量
  是 Gradle 的文件监听开关——一开关、一变量、一次构建，因果立刻清晰。
- **与项目强相关的配置（gradle.properties）是环境类问题的第一嫌疑人**：它不在
  版本库 diff 里显眼处，出了问题也不会报错，只默默改变 daemon 行为。

---

### Bug 609 · 补全浮层定位常量 `_kTextTopInset` 拍脑袋写 20，渲染校准实测 **8**——浮层会整体偏下 12px（2026-09-25，alpha.80 出包前被测试拦住）

**背景**：alpha.80 给编辑器做了补全浮层（替代贴底建议条），浮层 Y 定位公式：

```dart
top = _kTextTopInset + line × lineHeight − scrollY
```

`_kTextTopInset` 当时按"Flutter InputDecoration 默认 contentPadding top"的
记忆写了 **20**，并配了"校准测试锁值"的计划。

**发现过程**：校准测试（真 pump vendored CodeField + 量 `getTopLeft`）一跑：

```
Expected: a numeric value within <1.0> of <20.0>
  Actual: <8.0>          ← 差 12px，浮层会压在光标行下半部
```

**根因**：vendored CodeField 的代码列 TextField 用的是
`InputDecoration(border: InputBorder.none, isDense: false)`——
**M3 下 InputBorder.none 的 contentPadding 是 `fromLTRB(12, 8, 12, 8)`**，
top = 8。"20"的记忆来自 M2 有 border/label 的场景，**抄错了场景**。
app 与测试环境同为 `useMaterial3: true`，实测值即真机值。

**修复**：`_kTextTopInset = 8`，校准测试从源码动态提取声明值与实测比对，
之后 vendored/Flutter 升级布局一变测试即红。

**⚠️ 顺带钉死的三个测量事实**（写校准测试时踩的坑，以后写编辑器类 UI 测试必看）：

1. **EditableText 内部自带 Scrollable，且它是 EditableText 的后代**——
   TextField 把 scrollController 透传给 EditableText，后者在 build 里
   `Scrollable(controller: ... → _Editable)`。所以
   `find.ancestor(of: EditableText, matching: Scrollable)` 找不到它
   （只会撞上 `_wrapInScrollView` 的横向 SingleChildScrollView，
   controller=null），要用 **`find.descendant`**。
2. **滚动不动 EditableText 的 box**：滚动在 RenderEditable 绘制层平移
   （内部 `_paintOffset`），`getTopLeft(EditableText)` 恒为
   `CodeField顶 + 8`。想验证"滚动跟随"，验证 offset 本身 + 合成公式，
   别指望 box 位移。
3. **`getLocalRectForCaret()` 返回的坐标已含滚动偏移**（`+ _paintOffset`
   已在内部应用）。拿它合成视口 y 时**不要再减 scrollY**——否则差值恰好
   等于 scrollOffset，一眼就能看出"扣了两次"（本轮：期望 −13 实测 −76，
   差 63 = jumpTo 的 63px）。

**新增教训**：
- **像素级 UI 常量（inset/行高/间距）禁止拍脑袋**：写死常量必须配渲染校准
  测试（声明值 vs 真实渲染实测值），两边任何一边动过都会红。"我记得 Flutter
  默认是 20"不算证据——先分清场景（M2/M3、border 有无、isDense、label 有无）。
- **校准测试用"源码动态提取声明值"而非再写死一份**：`RegExp(r'_kTextTopInset
  = ([\d.]+)')` 从源码读，断言"声明 == 实测"。若测试里再写死 20，常量改对
  了测试反而还挂着，误导排查。
- 测试文件：`test/editor_completion_test.dart`（25 条：逻辑 14 + 渲染校准
  3 + 源码断言 8）。

---

### Bug 610 · `dart format` 一折行，"源码断言"测试就崩在 `substring(-1)`（2026-09-25，alpha.81 出包前暴露）

**症状**：上一轮整目录跑过一次 `dart format` 后，全量测试冒出一条
**和本次改动毫无关系**的失败：

```
RangeError (start): Invalid value: Not in inclusive range 0..42863: -1
  dart:core                          _StringBase.substring
  test/build_panel_test.dart 251:24
```

**原因**：测试是这么写的——

```dart
final i = src.indexOf('if (otherBuilding) _otherBuildingCard()');
final body = src.substring(i, src.indexOf('// ---------- 别人的构建占着'));
```

`dart format` 把源码里那行 collection-if（超 80 列）折成了两行：

```dart
if (otherBuilding)
  _otherBuildingCard()
else ...[
```

于是 `indexOf` 返回 **-1**，`substring(-1, ...)` 直接抛 RangeError。
测试断言的是**源码排版**，而 format 唯一干的事就是改排版。

**⚠️ 附带教训（同一次的第二个代价）**：那次 format 是**整目录**跑的
（`dart format lib/ai/ lib/editor/ lib/project/ lib/mcp/`），一共动了
34 个文件、26 个有变更，其中**约 18 个是本次根本没改的既有文件**（纯空白）。
这些空白 diff 混在改动里，既污染 review，也埋了这次的雷。

**解决**：
1. 断言改成**容空白的正则**，并**先断言"找到了"再取子串**：
   ```dart
   final m = RegExp(r'if\s*\(otherBuilding\)\s*_otherBuildingCard\(\)')
       .firstMatch(src);
   expect(m, isNotNull, reason: '找不到"别人在构建"的分支');
   final body = src.substring(m!.start, src.indexOf('// ---------- 别人的构建占着'));
   ```
2. 之后 `dart format` **只对自己实际改动的文件**跑。

**验证**：`flutter test test/build_panel_test.dart` 39 条全绿；
`git diff --stat lib/project/build_panel.dart` 显示 52 增 48 删**全是空白**；
全量 **1271** 绿。

**新增教训**：
- **源码断言守住的是"接线不回潮"，不是"这行代码长什么样"**。断言串里
  别塞可折行的完整语句；要么用 `\s*` 容错，要么只断言**不可折行的短标记**
  （方法名 / 常量名 / 字符串字面量）。
- **`indexOf` 的 -1 不许直接喂给 `substring`**：失配时报出来的是
  RangeError + 一串无意义的下标，把人往"文件怎么变短了"的方向带。
  先 `expect(m, isNotNull)`，报错才是人话。
- **`dart format` 之后必须跑全量测试**：它只改空白，但空白能改掉源码断言，
  而这类失败**不会**体现在 analyze 里（两个都合法）。

---

### Bug 611 · AI 模块三个纯函数"写得太自信"：硬转 / 判据太窄 / "空"的语义反了（2026-09-25，alpha.81，全被测试抓出来）

**症状**（三个互不相关、同一天被测试各抓一次）：

1. `AiConfig.fromJson({'baseUrl': 42})` 抛
   `type 'int' is not a subtype of type 'String?' in type cast`
2. `looksLikeCode('final a = 1;')` 返回 **false** —— 内置 LLM 返回的**正确
   代码**被预览标上"疑似不是代码"
3. `lineDiff('a\nb', 'a\nb\n')` 报**有差异**（2 行 same），因为 `isEmpty`
   被定义成 `lines.isEmpty`

**原因**：

1. `fromJson` 里写的是 `(raw['baseUrl'] as String?) ?? ''`——**硬转**。
   字段类型不对（旧版本写的文件、手改过、别的 App 写过同名文件）就直接进
   异常分支。外层 `load()` 有 try/catch 兜得住，但**公共入口不该靠调用方兜**，
   而且兜住的结果是"整份配置作废"，本可以只废那一个字段。
2. `looksLikeCode` 的判据只认几种**开头**（`//`、`import `、
   `标识符+({=`、单行 `}`），漏了"带关键字的声明行"——`final a = 1;`
   一条都不匹配，于是被判成聊天腔。
3. `isEmpty` 我按数据结构随手定义成了"没有行"。可调用方真正要问的是
   **"有没有改动"**——内容相同时快路径返回空列表，而带一堆 same 行时
   （如只差末尾换行）根本"没有行"可言。

**解决**：

1. 逐字段降级：`static String _str(Object? v) => v is String ? v : '';`
   ——能救回的字段照常救回，坏字段退化空串。
2. 判据改成 **"代码行占比 ≥ 一半" + 聊天腔特征词一票否决**，
   并把"像代码"放宽到关键字 / 赋值 / 收尾括号 / 代码标点收尾 / 箭头：
   ```dart
   if (nonEmpty.any((l) => _kChatty.hasMatch(l))) return false; // 裹了解说
   final codeish = nonEmpty.where((l) => _kCodeLine.hasMatch(l.trimLeft())).length;
   return codeish * 2 >= nonEmpty.length;
   ```
3. `isEmpty => added == 0 && removed == 0`；并且**行序列相同也走空差异快路径**
   （`_sameLines(la, lb)`），`'a\nb'` 与 `'a\nb\n'` 从此算同一份内容。

**验证**：新增 5 个测试文件（`ai_config` / `ai_llm_client` / `ai_dispatch` /
`ai_diff` / `ai_editor_wiring`）共 77 条，全量 **1271** 绿。

**新增教训**：
- **纯函数不是"写得短就对"**：边界要在测试里**枚举**（脏类型、空串、单行、
  超阈值、首/末位置），这类函数没有 UI 能替你兜底。
- **启发式判据宁可漏标、不可误标**：`looksLikeCode` 误标会让"补全"这个功能
  看起来是坏的（明明返回了代码却警告"这可能不是代码"）；漏标只让用户多点
  一下预览。**凡"警示类"判据，出错方向要选对用户代价小的那边。**
- **"空"的语义先问调用方想问什么**，不要按数据结构的形状随手定义
  （`lines.isEmpty` ≠ 无改动）。

---

### Bug 612 · AI 设置里输入 API Key 闪屏、打不进字 —— 主因是**异步回填竞态**，输入法只是次要嫌疑（2026-09-26，alpha.82）

**症状**：真机进「AI 后端」选「内置 LLM」，在 API Key 输入框里打字会**闪屏**、
已输内容丢失、根本打不进去。用户第一反应是"安全键盘输入法冲突"。

**排查顺序**（先排除、再定位，别一上来就改 obscureText）：

1. 怀疑"父级高频重建把输入框带走了"——查了两个可能的源头，**都排除**：
   - 隧道 `TunnelService.onUiChanged` 只在启停隧道时 `_ui()`；
   - `project_page` 的 500ms 定时器只在 `_section == _Section.build && building`
     时启动，**AI 区根本不跑**。
2. 于是转去看**回填时序**，才抓到真凶。

**根因（我方确证，不用真机就能坐实）**：`_loadCfg()` 是异步的——
`await ProotBridge().envInfo()` 走 MethodChannel。用户在它返回之前选了
「内置 LLM」并开始敲 key，它回来后无条件 `setState` 用**磁盘旧值**覆盖：

```dart
setState(() {
  _cfg = c;                    // kind 被改回 remoteMcp
  _keyCtl.text = c.apiKey;     // 正在敲的内容被冲掉
});
```

`kind` 一变，`if (llm) ...[三个输入框]` 整块条件渲染**瞬间消失**。
观感就是"闪一下、字没了"——**不崩溃、不报错**，只能靠时序推理抓出来。

**次要嫌疑（沙箱复现不了）**：`obscureText: true` 会让国产输入法切
「安全键盘」，Flutter 上已知反复重建 InputConnection。用户猜的就是这个，
方向没错，但它**不是本例的主因**——主因修掉后若还闪，才是它。

**解决**（四条一起上，都是无害改动）：

1. **`_edited` 守卫**：`_loadCfg()` 开头 `if (!mounted || _edited) return;`
   ——任何输入（含"清空密钥"）都置 `_edited = true`，之后异步回来的配置
   **一律不回填**。
2. **密钥默认明文**（`_showKey = true`）+ 眼睛按钮切换；键盘类型用
   `TextInputType.visiblePassword`（告诉输入法"是密码但用普通键盘"）。
3. **去掉 `onEditingComplete` 自动保存**（它在部分输入法上会触发收键盘），
   改成停手 600ms 静默写（`_markEdited` + Timer，dispose 里取消）。
4. **给 TextField 稳定 key**（`ValueKey('ai-field-$label')`），父级重建时
   不丢 Element 身份；并关掉 `enableSuggestions / autocorrect /
   enableIMEPersonalizedLearning`（候选栏高度抖动也会带动布局跳）。

**验证**：新增 `test/ai_panel_input_test.dart` **10 条**（回填守卫生效、
默认明文、visiblePassword、无 onEditingComplete、timer 有取消）；
全量 **1294** 绿。⚠️ **输入法那半边沙箱测不了**，需要真机确认。

**新增教训**：
- **`await` 之后无条件 `setState` 覆盖输入框 = 定时炸弹**：任何"异步加载
  配置再回填 UI"的地方，回填前先问一句"用户此刻是不是正在编辑"。
- **条件渲染的输入区（`if (x) ... [TextField]`）一旦被父级 setState 带走，
  用户看到的就只是"闪"**——这类 bug 不报错、不留栈，只能靠守卫预防。
- **真机问题要把"我方确证的部分"和"对症下药的部分"分开记录**：测试只守
  前者。写在一起会让人误以为"有测试 = 整体验证过了"，反而更危险。

---

### Bug 613 · 键盘一弹，侧栏闪出又收回、AI 设置"模式自己跳回 MCP"、输入的 key 全丢 —— 真凶是 `OrientationBuilder`（2026-09-26，alpha.83）

**真机观察**（用户原话，这条 bug 完全靠它定位）：
> 点击 key 输入栏后突然闪出侧边栏然后收回，然后模式自动切换了 mcp 然后又
> 切回来了，然后键盘回收，输入栏选中状态消失，无法正常输入

**排查**：第一轮怀疑输入法（用户也是这么猜的）——合理但**错了**。四个现象
同时出现，说明不是键盘层的事，而是**组件树被换掉了**。顺着"什么会让整块
UI 重建"找，在 `project_page.dart` 的 `body` 上抓到：

```dart
OrientationBuilder(builder: (context, orientation) {
  final landscape = orientation == Orientation.landscape;   // ← 只看长宽比
  final sections = _buildSections();
  if (!landscape) return sections;                          // 竖屏：裸树
  return Row([SizedBox(width:280, tree), ..., Expanded(sections)]); // 横屏：包一层
})
```

**根因链**（一步都不能少，全在真机反馈里对得上）：

1. App 的 `android:windowSoftInputMode="adjustResize"` → 键盘弹起时**窗口
   本身被 resize**，`MediaQuery.size` 的高度跟着变小；
2. `OrientationBuilder` 的 orientation 就是**由约束长宽比推的** → body 高度
   被键盘压到小于宽度 → **误判成 landscape** → 280px 侧栏"闪出"；
3. 键盘高度回升 / 收起 → 判回 portrait → 侧栏"收回"；
4. **最致命的一步**：body 的返回值在 `sections` 与 `Row(...sections...)`
   之间切换 → `IndexedStack` 在 Element 树里的**位置变了** → Flutter 认为
   是新 widget，**六个区的 State 全部销毁重建**：
   - `AiTakeoverPanel._cfg == null` → 单选组显示默认 `remoteMcp`
     （"**模式自动切换了 mcp**"）；
   - `_loadCfg()` 异步回来回填磁盘值（"**然后又切回来了**"）；
   - 焦点所在的 `TextField` 的 Element 被销毁 → 注意力被系统收回
     （"**键盘回收、输入栏选中状态消失**"）；
   - 正在敲的内容全丢（"**无法正常输入**"）。

**为什么 alpha.82 的修复没用**：那一轮加的 `_edited` 守卫是防"异步回填
覆盖用户输入"的，但这里 **State 本身都没了**——守卫随 State 一起被销毁，
自然守不住。教训：**怀疑"界面被重建"时，先查组件树结构是否稳定，再查
状态时序**。顺序反了会像本轮一样，先修一个真实但不相干的问题。

**为什么"换输入法"一定没用**：这不是输入法层的事。用户提出的这条建议是
合理的试探，但现象里的"侧栏闪出"已经指向布局层——**遇到多现象并发时，
先找能一次解释全部现象的那个原因**（这里四个现象全由第 4 步解释）。

**解决**（两道，缺一不可）：

1. **判定改宽度阈值**：`MediaQuery.sizeOf(context).width >= 600`。
   键盘只压高度不压宽度 → 对键盘**天然免疫**；真机旋转时宽度确实会变，
   仍然正确。`editor_page` 独立模式的 `Drawer`/常驻左栏同病同治。
2. **树结构恒定**：`Row(children: [if (wide) 侧栏, if (wide) 分隔线,
   Expanded(sections)])` —— `sections` 的位置**永远是 Row→Expanded→child**，
   旋转时只是增删兄弟节点，不换父节点 → **State 保活**。
   > 顺带修掉一个此前没人报的 bug：**旋转屏幕会丢全部未保存内容**，
   > 成因与键盘闪侧栏**完全一样**（树被换掉），只是触发条件更少见。

**验证**：`test/layout_keyboard_orientation_test.dart` **7 条**，其中两条是
真 pump 的**不变式测试**：
- 只压高度（模拟键盘）→ 侧栏不出现；
- **旧写法会翻车**：同尺寸下 `OrientationBuilder` 确实从"竖"翻成"横"
  ——这条故意保留失败路径，让后来者一眼看到判据为什么必须换。
全量 **1308** 绿。

**新增教训**：
- **`OrientationBuilder` / `MediaQuery.orientation` 在 `adjustResize` 的
  App 里不可用于布局分支判定**，因为键盘会改变约束长宽比。要判"够不够宽
  就上侧栏"，直接用**宽度阈值**。（若非要按方向，得读
  `MediaQuery.of(context).orientation` 之外的真实设备方向，或改用
  `MediaQuery.orientationOf` 配合忽略 viewInsets 的尺寸——都不如宽度阈值直接。）
- **"三元/if 换整棵树"是 State 杀手**：`if (x) return A; return Row([B])`
  这种写法在条件翻转时会重建整棵子树。**改成 Row + 条件 children**，
  位置恒定即 State 恒定。
- **多现象并发时，先找那个能一次解释全部现象的原因**——只解释一部分的
  假设（输入法）再合理也要先放一放。
- 源码断言要**剥掉注释**再匹配：本轮两个文件里到处是"为什么不能用
  `OrientationBuilder`"的说明，直接 `contains` 会把解释当成违规命中。

---

### Bug 614 · 派活后"还要手动从磁盘重新载入" —— 基线取错，假报警把真改动吃掉了（2026-09-26，alpha.84）

**用户反馈**（附截图，截图里那句 toast 还是 alpha.82 的文案）：
> 怎么还是要手动"从磁盘重新载入"

**先排掉的**：`_startDiskWatch` 确实接上了 dispatched 分支（grep 确认），
watcher 也确实在轮询。**接线没问题，问题在语义**。

**根因**：alpha.83 把基线定义成"**派活那一刻编辑器里的内容**"，注释还写了
理由——"用户自己未保存的改动不算外部变更"。听起来对，实际会**彻底废掉监听**：

```dart
// alpha.83（错）
_startDiskWatch(req.path, before);   // before = _content（编辑器内容）
```

```dart
Future<void> _poll() async {
  if (!r.ok || r.content == _baseline) return;
  _reported = true;                    // ← 一旦置位
  stop();                              // ← 监听就此结束
  onChanged?.call(r.content);
}
```

用户**只要有未保存改动**（改代码时这是常态），`编辑器内容 ≠ 磁盘内容` →
**第一次轮询（2.5s 后）就判定"磁盘变了"** → 弹一个假报警 → `_reported = true`
+ `stop()` → **之后外部 AI 真改了也永远不会再报**。用户看到的就是"功能没生效，
还得手动重载"，而实际是**假报警把真改动吃掉了**。

**为什么容易写错**：把"编辑器脏不脏"这件事**混进了"磁盘变没变"的判断**。
这是两个正交的问题，硬凑在一起就必然错一边：

| 问题 | 正确的信息源 |
| --- | --- |
| 磁盘被外部改了吗？ | **磁盘的**上一个已知内容 |
| 用户的改动会丢吗？ | 编辑器的内容 vs 磁盘内容（在**弹窗里**再比） |

**解决**（`lib/ai/ai_file_watch.dart`）：
1. `start()` 变成 `Future<void>`，**自己读一次磁盘**当基线（`baseline` 参数
   降级为仅供测试注入的可选值）；
2. 读不到盘 → `_baselineKnown = false` → **干脆不启动**。"没有可信基线就开
   监听"必然首轮误报，宁可完全不报（用户仍有手动重载），也不要弹假报警；
3. `_poll` 里补一道 `if (!r.ok) return;` —— 单次读失败（写入过程中的 0 字节
   中间态）不该算变更；
4. 上报前把基线推到刚读到的内容，避免回调没处理时连环弹。

**顺带修掉的一处"改了行为没改提示"**（`lib/ai/ai_backend.dart`）：派活提示
仍写着"用编辑器的「从磁盘重新载入」查看结果"——**用户截图里那句就是它**。
alpha.83 明明已经自动盯盘，提示却还在教人手动操作，用户自然以为功能没做。
改成"它改完文件后**会自动弹窗给你看差异**，也可以随时点「更多 → 从磁盘重新载入」"。

**教训**：
- **改了行为就必须改提示**。提示是用户判断"功能有没有生效"的唯一依据，
  提示过期 = 功能在用户眼里不存在。这一条是纯疏忽，没有技术难点。
- **基线/去重这类"上次已知值"，语义必须和触发条件同源**。判断"磁盘变了"，
  基线就只能是磁盘内容；拿编辑器内容当基线，等于拿尺子量温度。
- 监听类功能的失败模式要专门想一遍：**"永远不报"和"乱报"哪个更糟？**
  这里是"假报警导致永久静音"，比单纯不报更难发现——**自停（`stop()`）的
  触发条件必须是最可靠的那一个**。

**验证**：`test/ai_file_watch_test.dart` 增到 **13 条**，新增"基线语义
（alpha.84 回归）"组，其中两条直接盯着这个病灶：
- **用户的未保存改动 ≠ 外部变更（不许误报）** —— 且断言 `w.active` 仍为真
  （"关键：监听必须还活着"）；
- **有未保存改动时，外部真改了仍然能报出来** —— 注释里写明"旧实现会在这里
  误报并自停"。
`test/ai_editor_wiring_test.dart` 加源码断言守住 `_startDiskWatch(String path)`
单参数 + 派活提示新文案。全量 **1339** 绿。

---

### Bug 615 · 派活链路是黑盒：用户"不确定外部 AI 干了什么"（2026-09-26，alpha.84）

**用户反馈**（澄清问答里的回答）：
> 不确定外部 AI 干了什么

**问题不在功能，在**可观测性**。alpha.81 把派活设计成"异步无回执"（协议上
最稳，见 `mcp_dispatch.dart` 的说明），但对用户是个黑盒——派完之后只有一句
toast，接下来一个问题都答不上来：作业写进去了吗？有 AI 来领过吗？它改的是
我打开的那个文件吗？它是改了但改错了，还是压根没动？

**解决**：`lib/ai/ai_inbox_view.dart`（新）+ 编辑器"更多 → **AI 作业收件箱**"。

- 只读 `loadAiInbox()`：读 `.foa/ai-inbox.md`（索引）+ `list` 作业目录列出
  最近 20 条作业，正文里出现 `status: done` 才算"对方回执过"；
- 任何一步失败都**降级为"看不到"而不抛异常**——诊断入口自己崩掉比看不到更糟；
- 判定逻辑全在纯函数里（`parseJobFileName` / `jobMarkedDone` / `describeJob`），
  因此完全可测；
- **不在弹窗里"标记完成 / 删作业"**：判断权在外部 AI 手里，App 代它标 done
  就是撒谎。同时如实告知"⏳ 也可能是改了但没写回执"，所以仍保留自动 diff 预览。

**顺带抓到的一个真 bug**：初版排序用 `b.name.compareTo(a.name)`（文件名倒序，
理由"前缀是毫秒时间戳"）。但时间戳是**变长整数**，字符串比较会得出
`'900' > '3000'` 这种荒谬结论，把最旧的顶到最前。改为按 `parseJobFileName`
解析出的 `DateTime` 数值排序，解析不出的排最后。**这条是写测试时被抓出来的**
（`maxJobs 截断` 那条断言"截断也要保住最新的"直接失败）。

**教训**：
- **"异步无回执"是协议约束，不是体验借口**。协议不能给你回执，但磁盘上
  的痕迹（inbox 索引 + `status: done`）本来就在那里——**把它们摊开给用户看，
  成本极低，收益是"从猜变成看"**。
- **凡是"等对方"的流程，都要给用户一个能自己查的地方**。否则用户唯一能做的
  就是反复试、反复猜，然后把"其实在正常工作"的功能当成坏的。
- **数字型字符串不许用字典序比较**。变长时间戳、版本号、`file1/file10`
  全是同一个坑。要么解析成数值，要么**零填充到定长**。

---

### Bug 616 · 出包卡在 `Could not resolve io.flutter:*_release` —— 是**网络**，不是 Bug 608；且镜像其实从没生效过（2026-09-26，alpha.84）

**现象**：alpha.84 出包连挂 3 次，两次报网络错（35s / 1m3s）：

```
> Could not resolve io.flutter:arm64_v8a_release:1.0.0-06a2e2a1...
> Could not resolve io.flutter:flutter_embedding_release:1.0.0-06a2e2a1...
   > Could not HEAD 'https://download.flutter.io/...'
      > The server may not support the client's requested TLS protocol versions
         > Remote host terminated the handshake
```

**第一件事：分诊，别再套 Bug 608 的招**。判据见 SKILL 里的构建分诊表：
- 报 `Could not resolve ... Maven` / `terminated the handshake` → **网络问题**；
- 报 `Gradle build daemon disappeared` / 秒挂 → Bug 608（杀 daemon + 预清理）。

> ⚠️ 本轮我自己踩了：看到"挂"就先按旧经验重跑 + 预清理，**前两次纯属白跑**。
> 错误文本第一眼就该看，它会直接告诉你是哪一类。

**关键排查：镜像根本没被用过**

```bash
grep -c "maven.aliyun.com" /tmp/b.log   # → 0
```

日志里**一条阿里云记录都没有**。原因：Flutter 的 `FlutterPlugin` 会往项目
仓库列表**注入官方地址**（`download.flutter.io` / `dl.google.com` /
`repo.maven.apache.org`），而这些注入项的优先级**高于**
`android/build.gradle.kts` 里写的国内镜像。

**而且镜像配置本来就是废的**：Flutter 自带的
`flutter_tools/gradle/settings.gradle.kts` 里写着
```kotlin
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
```
`FAIL_ON_PROJECT_REPOS` 会让**所有 project 级仓库直接报错**。也就是说本项目
`allprojects { repositories { maven { aliyun } ... } }` 那几行**从来没生效过**
——以前构建能过，纯粹是官方源碰巧通。**这是一个潜伏很久、直到断网才暴露的问题。**

**验证三个源的可达性**：

```bash
curl -s -o /dev/null -w "%{http_code}\n" --max-time 20 \
  https://download.flutter.io/io/flutter/.../x.pom       # → 000（连证书都不给）
curl -s -o /dev/null -w "%{http_code}\n" \
  https://maven.aliyun.com/repository/google/            # → 404（可达）
# 但阿里云里没有 io.flutter:arm64_v8a_release → Flutter engine 只在官方源分发
```

**解法：把本机 Gradle 缓存做成 `file://` 仓库，彻底绕开网络。**

```bash
M2=android/local-maven
for art in arm64_v8a_release flutter_embedding_release; do
  ver=1.0.0-06a2e2a110089dff50fe635cffd2a61e1b24fbcd
  mkdir -p "$M2/io/flutter/$art/$ver"
  find /root/.gradle/caches/modules-2/files-2.1/io.flutter/$art/$ver \
    -type f -exec cp {} "$M2/io/flutter/$art/$ver/" \;
done
```

```kotlin
// android/settings.gradle.kts
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)   // 必须改
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google(); mavenCentral()
        maven { url = uri("${rootDir}/local-maven") }
    }
}
```

**三个坑（全部实测踩过）**：

1. **不能用 `~/.gradle/init.d/*.gradle`**。写 `beforeProject { repositories {} }`
   会被 `FAIL_ON_PROJECT_REPOS` 拒：
   `Build was configured to prefer settings repositories over project repositories`。
   **只能改 settings，不能改 project。**
2. **`flutter build apk` 没有 `--offline`**（`EXIT=64 / Could not find an
   option named "--offline"`）。Gradle 层的 `--offline` 也救不了：缓存在
   `files-2.1` 里，但离线模式还要求"该构件归属于某个已配置仓库"，会报
   `No cached version of io.flutter:... available for offline mode`。
   **`file://` 仓库是唯一可行的路。**
3. 顺手把 `repositoriesMode` 从 `FAIL_ON_PROJECT_REPOS` 调成 `PREFER_SETTINGS`
   ——否则 `build.gradle.kts` 里那两行镜像**永远是错的**（同一个错误），
   有网时也一直没走镜像。

**教训**：
- **构建失败先读错误文本再动手**。"网络"和"daemon 状态坏"的修法完全相反，
  套错招只会浪费两轮时间。
- **"以前能过"不等于"配置是对的"**：镜像配置在有网时被官方源的成功掩盖了，
  断网才把它暴露出来。**排查网络问题时，先确认你配的镜像到底有没有被打到**
  （`grep -c` 一条就行），而不是假设它在生效。
- **本地缓存可以当仓库**：能联网构建过一次，就说明依赖都在本地了；
  把 `files-2.1` 里的 `pom/jar` 按 `groupId/artifactId/version` 摊成
  `file://` maven 布局，是最不依赖外部条件的兜底手段。

#### 补丁（alpha.86）：`--target-platform` 才是首选解，local-maven 只是兜底

alpha.86 出包时**同一个错误又犯了一次，但这次 local-maven 救不了**：
它只摊了 `arm64_v8a_release` + `flutter_embedding_release`，而 Gradle 要的是
**`x86_64_release`**，缓存里根本没有这个构件，报错变成：

```
> Could not resolve io.flutter:x86_64_release:1.0.0-06a2e2a1...
   > Could not GET 'https://dl.google.com/...'
      > The server may not support the client's requested TLS protocol versions
         > Remote host terminated the handshake
```

**为什么我们只出 arm64，Gradle 却要 x86_64？** 读
`flutter_tools/gradle/src/main/kotlin` 源码，两个地方容易混淆：

| 地方 | 作用 | 影响范围 |
|---|---|---|
| `FlutterPlugin.configureAbiWithoutSplits()` → `abiFilters` | **只控制打包**进 APK 哪些 so | 产物内容 |
| `FlutterPluginUtils.getTargetPlatforms()` → `PLATFORM_ABI_LIST` | **决定依赖解析范围** | 要不要下载 |

而 `PLATFORM_ABI_LIST` 来自 `DEFAULT_PLATFORMS`，是 **arm32 + arm64 + x86_64
三个**。所以**只要不传 `target-platform`，Gradle 就会去解析三个引擎构件**——
`abiFilters += listOf("arm64-v8a")` 拦不住它，因为它压根不在那条代码路径上。

**正解：**

```bash
flutter build apk --release --target-platform android-arm64
# 等价于 -Ptarget-platform=android-arm64
```

一次解决，**不需要预填充任何缓存**，比摊 local-maven 干净得多。
（`getTargetPlatforms` 的实现就是读 `target-platform` 属性，逗号分隔。）

**教训**：
- **"打包过滤"和"依赖解析"是两件事**。看到项目里写了 `abiFilters`，不代表
  Gradle 不会去下载别的 ABI 的构件。**构建配置要问"它作用在哪一层"。**
- **兜底手段（local-maven）要写清它兜的是什么**。它兜的是"构件在本地缓存里、
  只是没网"，**兜不了"构件根本不存在"**。alpha.84 写下 README 时没写这条边界，
  alpha.86 就照着它排查了一圈才转向。
- 优先用**官方参数**（`--target-platform`）而不是**自己搭基础设施**
  （摊 maven 仓库）：前者一行、无状态；后者要维护版本号、要防缓存漂移。

---

### Bug 617 · "以前未连接会提示并跳设置，现在只会静静派活" —— 只有一条后端路径有前置检查（2026-09-26，alpha.85）

**用户反馈**（附截图：派活 toast 正常弹出，但隧道根本没开）：
> 之前会弹消息说未链接然后跳到设置页面的，现在只会这样了

**根因**：两条后端路径的失败**长得一模一样**（都是"点了没反应/一句看不出
所以然的提示"），但**只有一条有前置校验**：

| 后端 | 前提 | 有没有前置检查 |
| --- | --- | --- |
| 内置 LLM | 填了地址 + 密钥 | ✅ 有（`AiOutcome.failure` + `project_page` 跳设置区） |
| 远程 MCP | **隧道在跑**（否则没人能连进来领活） | ❌ **完全没有** |

所以隧道没开时点 AI，App 老老实实把作业写进 inbox，然后显示
"已投递到 .foa/ai-inbox.md，等已连隧道的 AI 客户端领取"——
**这句话技术上真（确实写进去了）、实际上假（根本没有客户端连得进来）**。
作业就烂在磁盘里，用户还以为是 AI 没干活。

**修法**：编辑器页新增 `_ensureAiReady()`，**放在 `beginAiPlaceholder()` 之前**：

```dart
Future<void> _runAiFlow(EditorAiRequest req, String instruction) async {
  if (widget.onRunAi == null || _aiBusy) return;
  // 占位是"AI 正在写"的承诺；还没确定能跑就占位，失败了得先撤占位，
  // 白白闪一下。所以检查必须在这之前。
  if (!await _ensureAiReady()) return;
  ...
```

- **内置 LLM** 缺地址/密钥 → `_showAiFailure` + 去 AI 设置区；
- **远程 MCP** 且 `!tunnelReady(TunnelService.I.status)` → 三出口弹窗
  **取消 / 仍然派活 / 去开启隧道**，默认停"取消"（点外部关掉不默默派活）。

**为什么 MCP 是"提示 + 让你选"而不是硬拦**：派活本身有独立价值——用户可能
打算**稍后**起隧道，或者会自己把作业文件拷给别的 AI。硬拦会砍掉这些用法。
**不阻断，但绝不让人以为活已经有人接了。**
而"去开启隧道"这一支**不放行派活**：用户点的是去开隧道，顺手把作业派了
等于违他本意。

**顺带修掉一个更隐蔽的设计缺陷 —— `AiRemedy` 枚举**

原先跳转的唯一判据是字符串比对：

```dart
// project_page.dart（旧）
if (out.kind == AiOutcomeKind.failure &&
    out.message == kAiUnconfiguredMessage && mounted) { ... }
```

**改一个字，跳转就静默失效，且不会有任何测试变红。** 这正是 alpha.83
"改了行为没改提示"的同一个病根。现在给一个显式枚举：

```dart
enum AiRemedy { configureLlm, startTunnel }
```

UI 只认 `out.remedy`，文案随便改都不影响导航，出口文案也跟着换
（缺密钥 → "去设置"，缺隧道 → "去开启隧道"）——**文案说错地方，
比没有出口更浪费时间**。

> **通用教训：凡是"根据提示文案决定走哪条分支"，都是定时炸弹。**
> 文案是给人看的、会变的；分支条件是给机器看的、要稳的。这两者一旦
> 耦合，改文案的人不会知道自己在改逻辑。

---

### Bug 618 · 外部 AI 领了一条补全作业，把整个工程体检了一遍（2026-09-26，alpha.85）

**真机实录**（用户截图）：
> 这些都是同类「补全光标处代码」作业，光标都在 main.dart 偏移 ~11371 处。
> 先读当前 main.dart 看真实现状。［执行 1 条命令］
> 文件 360 行、12095 字节。读前半部分看整体结构和是否有未补全处。［执行 1 条命令］
> …确认有没有额外要求。［执行 1 条命令］
> 作业正文是「补全光标处代码」，但当前 main.dart 看起来已是完整文件。
> 我需要先确认它是否真能编译——重点看 `cardTheme` … 先查 SDK 版本的 API 定义。

一条"补全光标处代码"的作业，被扩散成了：通读全文 → 判断"文件已完整" →
查 API 定义 → 准备验证能否编译。**用户要的是补几行，AI 在给项目做体检。**

**根因不在于 AI 笨，而在于作业里没有"边界"**：`buildJobMarkdown` 只写了
"要做什么"（要求 + 上下文），**完全没写"不要做什么"、"什么情况下该停下"、
"改不动怎么办"**。LLM 在信息不足时的默认行为就是"多做一点显得尽责"。

**修法：三处齐改，把边界写死在提示词里。**

**① `tunnel_service.dart` 的 `buildHandoffPrompt` 新增【工作纪律】**

```
**只有两种情况你才动手：**
1. 收件箱里有**未处理**的作业条目（没有 `status: done` 的）；
2. 用户在本对话里**直接给了你**明确指令。

**除此之外一律停下来等，不要自行发挥：**
- 收件箱空 / 全 done → **只回一句"当前没有待处理作业"就结束**，
  不要顺带看看项目、不要主动分析代码、不要跑 foa_diag。
- 作业指向的文件看起来已经完整 → 这**不是**让你扩建范围的理由。
- 作业要求含糊 → **问清楚再动**，不要用"顺便检查一下"来补全意图。

**关于验证，默认克制：**
- **不要**主动运行编译、构建、`flutter analyze`、测试套件。
- 排查**该作业相关的**报错时读文件是可以的；但**不要**把一次补全作业
  扩大成整个项目的健康检查。
```

并且**解释了代价**（"这是用户的真机，flutter/build 经 QEMU 转发，一次构建
几分钟起、耗电且占满 CPU……**"多做一点"在这里是负分**"）。经验：给 LLM
的约束带上理由，比干巴巴的命令执行率高得多——它需要知道"为什么"，才能在
规则没覆盖到的角落做对判断。

**开局指令也要改**：原文是
`先调用 foa_info 建立环境认知；接着读 .foa/ai-inbox.md …`
——**"先建立环境认知"本身就是在鼓励无作业时到处翻**。改成：

```
读 `.foa/ai-inbox.md`：
- 有未处理作业 → 处理它；
- 没有 → 回一句"当前没有待处理作业"，然后**停下等指令**。
```

**② `mcp_dispatch.dart` 的 `buildJobMarkdown` 新增【边界（请遵守）】**
（作业文件是 AI 逐条真正要读的东西，光在接入说明里写不够）：
- 只做「要求」里写的事；"看起来已完整"不是扩范围的理由；
- 不要主动运行构建 / 测试 / analyze；
- 不要为了"确认现状"通读整个文件再顺带分析；
- **改不动或理解不了 → 直接说明卡在哪，保持文件原样，不要用猜测的改动顶上**。

最后一条尤其重要：**"宁可不动，不要猜着改"**——猜错的改动会让用户以为
AI 干完了，比明说"我卡住了"危害大得多。

**③ inbox 表头**加一句"没有未处理条目时请停下等待，不要自行浏览项目或
做健康检查"，兜住 AI 只读 inbox、没读接入说明的情况。

**验证**：`test/ai_ready_guard_test.dart` **26 条**，其中作业边界 6 条、
提示词纪律 7 条，逐句断言这些约束真的编进去了。全量 **1365** 绿。

**通用教训**：
- **给 AI 的任务书必须同时写"做什么"和"不做什么"**。只写前者，能力越强的
  模型越容易越界——它不是不听话，是在按"帮助用户"的默认策略行事。
- **"停下等"必须是一个明确的、被允许的动作**。原提示词通篇都在讲怎么干活，
  从没说"可以什么都不做"，模型自然默认"总得干点什么"。
- **约束要带上代价**。告诉它"真机上构建一次要几分钟"，比只说"别构建"有效。

---

### Bug 619 · 连点 AI 按钮派出多条重复作业 —— 闸门落在了 `await` 之后（2026-09-26，alpha.86）

**用户报告**：
> 如果同时点了好多次按钮好像会导致重复任务发送。

**根因：闸门字段是"给用户看的"，不是"给防重入用的"。**

旧代码只有一个 `_aiBusy`，检查写成 `if (widget.onRunAi == null || _aiBusy) return;`。
看起来没问题，但 `_aiBusy` 要经过 `setState` 才置真，而它前面横着一个
`await _ensureAiReady()`（读配置 + 可能弹对话框等用户点选）：

```dart
// ❌ 旧写法
if (widget.onRunAi == null || _aiBusy) return;
if (!await _ensureAiReady()) return;   // ← 第二次点击落在这里
setState(() => _aiBusy = true);        // ← 到这里才置真，晚了
```

连点两下时，第二次点击正好落在那个 await 窗口里，读到的 `_aiBusy` **仍是
false** → 两个流程并行跑到派活 → 磁盘上多出重复作业。

而且这动作非常自然：**点了没反应会更用力点**。

**修法：闸门必须是同步字段，且落在所有 `await` 之前，用 `try/finally` 保证
任何出口都解锁。**

```dart
// ✅ 新写法
if (widget.onRunAi == null) return;
if (_aiRunning) return;   // 同步闸门，不依赖 setState
_aiRunning = true;
try {
  if (!await _ensureAiReady()) return;   // 现在才轮到 await
  ...
} finally {
  _aiRunning = false;   // 正常结束 / 提前 return / 内部抛异常，全都解锁
}
```

两个字段分工明确、不可合并：

| 字段 | 用途 | 时机 |
|---|---|---|
| `_aiRunning` | **同步防重入闸门** | 所有 await 之前 |
| `_aiBusy` | 给用户看的状态（进度条、只读） | `setState` 之后 |

**漏掉 `finally` 的后果同样是致命的**：`_showAiFailure` / `_askSaveAiChange`
里任何一次抛异常，按钮就永久点不动了。

**验证**：`test/ai_ready_guard_test.dart` 4 条（闸门存在且与 `_aiBusy` 分开 /
落在所有 await 之前 / `finally` 里解锁 / 旧的 `|| _aiBusy` 短路写法没回潮）。

**通用教训**：
- **用于互斥的标志位，绝不能用"要等一次重绘才生效"的状态**。判断时机与写入
  时机不同源，就会有一段谁都拦不住的窗口。
- **凡是 `await` 之前就该校验的不变量，一个都不能放在 `await` 之后。**
- 断言"闸门在 await 之前"时，**别直接搜 `await ` 字符串**——函数签名上方的
  文档注释里往往就写着这个词（本次就命中注释导致假红）。要先定位函数体起点，
  或以闸门语句为锚点往后找。

---

### Bug 620 · 测试连接报"地址可能不是合法的 http(s) 地址"，而地址完全正确（2026-09-26，alpha.86）

**真机截图**：接口地址填的是 `https://api.deepseek.com/v1`（正确），
点「测试连接」得到：

> 失败：请求失败（接口地址可能不是合法的 http(s) 地址）

用户于是去反复检查那个本来就没写错的地址。

**根因有两层，缺一不可：**

① **传输层把异常整个吞了**：

```dart
} catch (_) {
  return const LlmResponse(-3, '');   // e 被丢掉，什么都没留下
}
```

② **兜底文案拍脑袋写死了一个猜测**：`case -3: return '请求失败（接口地址可能
不是合法的 http(s) 地址）'`。

两层叠在一起：**内部什么都不知道 → 对外却给了一个很具体的错误指向**。
真机上这个 -3 通常是 `api.deepseek.com` 解析成功但连接被重置 / TLS 被掐，
跟"地址不合法"毫无关系。

**修法：不确定就不要猜，改成"报事实 + 报分类"。**

```dart
// ① 传输层留下"最接近原因"的分类，而不是什么都不留
catch (e) {
  lastError = describeTransportError(e);   // 握手失败 / 证书 / 格式异常 / 网络层
  return const LlmResponse(-3, '');
}

// ② 文案层：有真实分类就用它，没有就明说"原因未记录"
case -3:
  return detail.isEmpty ? '请求失败（原因未记录）' : detail;
```

**顺带堵住一个泄漏面**：写 `describeTransportError` 时我第一版搬运了
`HttpException.message`，注释还写着"这是我们自己给的短句，不含 URL"——
**这是错的**。它其实是任意字符串，真机上常常就是
`failed for https://host/...?token=xxx`。测试当场抓出：

> Expected: not contains 'sk-leak'
> Actual: 'HTTP 层错误：failed for https://gw.internal/v1/...?token=sk-leak'

改成只给分类、不搬运原文。同理 `SocketException` 只取 `osError.message`
（系统短句，如 "Connection refused"），**不取** `exception.message`
（形如 `Failed host lookup: 'host'`，会带出域名）。

**通用教训**：
- **"技术上真、实际上假"的错误提示比没有提示更坏**——它把用户引向错误方向，
  且浪费的时间远超一句"我也不知道"。**不确定就说不确定。**
- 错误处理里 `catch (_)` 是最贵的写法：**省下的一行，会在排障时翻倍偿还**。
- **怀疑"是不是地址写错了"之前，先确认程序真的知道地址是错的。**
- 断言"文案不含密钥"时，**注意别用自带真实感的字面量**——测试文件本身也会
  被扫库。用拼接构造，别在源码里留一个 `sk-xxxxx`。

---

### Bug 621 · 接口地址用的是安全键盘（2026-09-26，alpha.86）

**用户报告**：
> 接口地址完全没必要用安全键盘吧

**根因不是这里显式开了 `obscureText`，而是"哪个字段算密钥"这件事散落在
调用点**：

```dart
_aiField(_baseUrlCtl, '接口地址', '...', TextInputType.url);            // 看不出安全与否
_aiField(_keyCtl, 'API Key', '...', TextInputType.text, secret: true);  // 靠一个布尔
```

只要有人日后手滑写成 `_aiField(_baseUrlCtl, ..., secret: true)`，接口地址就
会被当密钥处理 → 输入法切安全键盘 → **安全键盘常常不提供 `/` `:` `.`，
地址根本打不全**。

**修法：把语义收进枚举，`secureText` 与 `keyboardType` 成对定义。**

```dart
enum LlmFieldKind {
  baseUrl,   // 普通键盘：安全键盘打不出 / : .
  apiKey,    // visiblePassword + 遮挡：唯一需要 secureText 的字段
  model;

  bool get secureText => this == LlmFieldKind.apiKey;
  TextInputType get keyboardType => switch (this) { ... };
}
```

调用点变成 `_aiField(_ctl, '接口地址', '...', LlmFieldKind.baseUrl)`——
**"能不能被标成密钥"从"调用者说了算"变成"类型说了算"**。

> 注：`_showKey` 默认明文这条（Bug 612）**保持不变**。默认明文是为了先保证
> 能输进去，眼睛按钮随时可点——这次的改动只是不再让遮挡外溢到非密钥字段。

**通用教训**：
- **当一个布尔参数决定"敏感与否"时，它就迟早会被传错。** 能合并成类型的语义，
  就不要留给调用点。
- 断言"旧写法已不存在"**必须先剥注释**：解释性注释里常常把旧写法原文抄一遍
  当反面教材，直接搜全文就会把注释命中（Bug 610 的同类坑，本次实测复现两次）。

---

### Bug 622 · 测试连接报 `请求失败（ArgumentError）` —— 不可复现的错误，就让它自己说话（2026-09-26，alpha.87）

**真机报错**：接口地址填 `https://api.deepseek.com/v1`，点「测试连接」得到

> 失败：请求失败（ArgumentError）

比上一版的"地址可能不合法"**信息量大一点，但仍然等于没说**。

#### 第一步：先证伪"不是网络、不是证书"

三条独立证据，缺一不可：

| 证据 | 手段 | 结果 |
|---|---|---|
| 服务器可达 | 沙箱同代码路径发真实请求 | **HTTP 401**（请求到达了服务器） |
| 证书链完整 | `openssl s_client -connect api.deepseek.com:443 -showcerts` | 3 层完整，`Verify return code: 0 (ok)` |
| 根证书普及度 | 看 issuer | **DigiCert Global Root G2**（2013 老根，Android 7+ 全内置） |
| 真机网络 | 用户手机浏览器直开该域名 | 拿到服务器返回的 JSON 错误 |

**"证书缺失"这条线到此排除**。这里要记牢一个容易混淆的点：

> Flutter 的 Dart 运行时用**自带的 BoringSSL** 直接读 `/system/etc/security/cacerts`，
> **绕过 Android 的 Conscrypt**。所以 Chrome / 微信能打开的站，Flutter 里
> 不一定能开——这是真坑，但**它有专属报错**：
> `HandshakeException: CERTIFICATE_VERIFY_FAILED` 或
> `Trust anchor for certification path not found`。
> **看到 `ArgumentError` 就别往证书方向查了**，那不是这条路径的错。

#### 第二步：用探针穷举，定位 `ArgumentError` 的触发条件

写个独立 Dart 脚本，把各种非法输入逐个喂给 `HttpClient`，打印 `runtimeType`：

```
① 正常请求                    => 无异常
② 非法 connectionTimeout      => SocketException
③ 非法 scheme                 => ArgumentError   ← 唯一命中
④ 空 header 名                => 无异常
⑤ header 值含中文             => FormatException
```

**`ArgumentError` 只对应"URL 协议头不合法"。** 顺着这条线查 `_endpoint`，
发现一个真 bug：

```dart
// ❌ 旧代码：只认小写
if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
```

用户填 `HTTPS://api.deepseek.com/v1`（大写）→ 被当成"没写协议头"→ 补成

```
https://https//api.deepseek.com/v1/chat/completions
        ^^^^^^ 把协议头当成了域名
```

一个必挂的畸形 URL。**已改成大小写不敏感比较。**

#### 但必须承认：没复现出用户的 `ArgumentError`

穷举了八种 URL 形态（末尾斜杠 / 无协议头 / 前后空格 / 重复 `/v1` / 大写协议头 /
含换行 / 中文冒号），**没有一种能产生 `ArgumentError`**。所以"大写协议头"
只是**最合理的猜测，不是结论**。

#### 第三步：与其继续猜，不如让异常自己说话

这是本轮真正的产出。传输层把**脱敏后的原始异常详情**附到提示后面：

```dart
lastError = '${describeTransportError(e)}'
    '｜详情：${safeErrorDetail(e)}'
    '｜URL：${redactUrlForLog(url)}';
```

**脱敏不是可选项**——异常原文常常带完整 URL（`?token=xxx` 形态，我们自己的接入
说明就是这么教的），直接显示等于把凭证抄进 UI。三层处理：

1. `sk-***` / `Bearer ***` / `?token=***&api_key=***` 正则打码；
2. URL 只留 `scheme://host/path`，**丢掉 query 与 fragment**；
3. 折叠空白 + 截断 160 字（换行会把 UI 撑开）。

**通用教训**：
- **"复现不了"不代表"没法修"**。修不了根因，就先把**观测能力**补上——
  让下一次报错自带定位信息，比再猜三轮强。
- **诊断信息与泄漏面天然冲突，但可以两全**：先脱敏、再截断，而不是
  "为了安全什么都别显示"。
- 真机专属问题，**先做"能一次排除一整类原因"的检验**（这里是 openssl 看证书链 +
  浏览器直连），别一上来就读代码。四条证据把"网络/证书"整类排除掉，
  剩下的才是真该查的。
- **穷举探针比读代码快**：写 20 行脚本把边界值全喂一遍，比盯着
  `HttpClient` 源码猜哪个分支抛什么，效率高一个量级。

---

### Bug 623 · 「测试连接」必失败的真因是 **latin1 编码**，而 Bug 622 的结论是错的（2026-09-26，alpha.88）

> ⚠️ **先读这条**：Bug 622 里我把 `ArgumentError` 归到"URL 协议头不合法"，
> 并给用户写了句「多见于网络中间设备改写连接；可先试切换 Wi-Fi / 关代理后重试」。
> **那是一句我编的、技术上站不住的话**，用户照做只会白折腾。本条是更正。

#### 用户带着截图回来，一切就清楚了

```
失败：请求参数在传输层被拒（多见于网络中间设备改写连接；可先试切换 Wi-Fi / 关代理后重试）
｜详情：Invalid argument (string): Contains invalid characters.:
  "{\"model\":\"gpt-4o-mini\", \"messages\":[{\"role\":\"system\",
   \"content\":\"你是嵌在手机 IDE 里的代码补全体。只输出要补写的… 
｜URL：https://api.deepseek.com/v1/chat/completions
```

`{\"model\":\"gpt-4o-mini\"...` 是个 **JSON 请求体**。而这个报错的 `(string)`
是 `ArgumentError.value()` 的 `name` 参数——全 Dart SDK 里只有两处这么写，
其中一处就在 `lib/convert/ascii.dart`：

```dart
// lib/convert/ascii.dart:92  _UnicodeSubsetEncoder.convert()
if ((codeUnit & ~_subsetMask) != 0) {
  throw ArgumentError.value(string, "string", "Contains invalid characters.");
}
```

**`latin1.encode(含中文的字符串)` 就是它。**

#### 真凶：`HttpClientRequest` 的默认编码是 latin1

```dart
// dart:io http_impl.dart:1191  （旧版写法，新版同逻辑）
Encoding get encoding {
  var contentType = headers.contentType;
  if (contentType != null && contentType.charset != null) {
    charset = contentType.charset!;
  } else {
    charset = "iso-8859-1";        // ← content-type 没 charset 就回落 latin1
  }
  return Encoding.getByName(charset) ?? latin1;
}

void write(Object? obj) {
  if (!_encodingSet) {
    _encoding = encoding;          // ← 第一次 write 就把编码定死
    _encodingSet = true;
  }
  super.write(obj);                // → latin1.encode(obj)
}
```

我们的代码（错误版）：

```dart
req.headers.contentType = ContentType.json;  // "application/json"，无 charset
req.write(body);                             // body 含中文 → latin1.encode → 💥
```

而 `body` 里的 system prompt 是**全中文**的（"你是嵌在手机 IDE 里的代码补全体…"），
所以**只要点「测试连接」就必炸，和模型名、地址、密钥都无关**。

#### 修复（三处顺序都有讲究）

```dart
headers.forEach((k, v) => req.headers.set(k, v));   // ① 先灌 headers
req.headers.contentType =                           // ② 再覆盖成带 charset 的
    ContentType('application', 'json', charset: 'utf-8');
req.add(utf8.encode(body));                         // ③ 最后写字节
```

- **① 必须在 ② 之前**：`headers` 映射里有 `'Content-Type': 'application/json'`，
  走 `headers.set` 是**同名覆盖**——写在 ② 之后会把 charset 冲掉，声明白写。
- **③ 必须是 `add(bytes)`，不能是 `write(String)`**：`add` 收字节，**压根不经过
  encoding getter**，这才是真正兜住的那行。charset 声明只是让对端知道怎么解。
- **③ 必须在 ② 之后**：`add()` 调用后 headers 变为 **immutable**，再设任何
  header 会抛 `HttpException: HTTP headers are not mutable`（实测，被新测试当场抓出）。

#### 为什么五百行测试全绿却漏了它

`test/ai_llm_client_test.dart` 原有 495 行，**`IoLlmTransport` 一次都没被测过**——
全部走 `FakeLlmTransport`（直接返回预设响应）。**那条最容易写错、最脆弱的
真实发送路径，恰好一行都没覆盖。**

修法是加一组**真实 `HttpServer` echo 测试**：

```dart
server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
server.listen((req) async {
  final bytes = <int>[];
  await for (final chunk in req) { bytes.addAll(chunk); }
  gotBody = utf8.decode(bytes, allowMalformed: true);
  ...
});
```

断言服务端收到的 body 与发出的**逐字节一致**、含中文字符串完整、
字节长度 == `utf8.encode(body).length`、`content-type` 含 `utf-8`。

**验证方式（重要）**：先把修复临时回退成旧写法，确认测试**变红**并复现出
与用户截图**一字不差**的报错；再恢复修复确认变绿。**没有"先看到它红过"的
回归测试不算回归测试。**

```
回退后：Actual: <-3>
  lastError=编码错误：…｜详情：Invalid argument (string): Contains invalid
  characters.: "{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"system\",
  \"content\":\"你是嵌在手机 IDE 里的代码补全体。…
✅ 与真机截图一致
```

#### 通用教训

- **`catch (e) { 给一句猜的文案 }` 是毒药**。Bug 622 我专门写过这条，
  自己转头又犯：`ArgumentError` 的兜底文案"多见于网络中间设备改写连接"
  纯属虚构，把用户引向关代理 / 换 Wi-Fi。**认不出就认不出，把原文给出来。**
- **异常 message 里有数据、没有调用点**。真机截图那条 message 只告诉我们
  "某个含中文的字符串被拒"，判不出**是谁**编的码。所以 alpha.88 一并
  `catch (e, st)`，从堆栈里摘 `package:` 帧附在详情后面——
  **定位信息在堆栈里，不在 message 里**。
- **`req.write()` + 中文 = 定时炸弹**。任何发给服务端的字符串，只要可能含
  非 ASCII，就必须 `add(utf8.encode(...))`。这条对 `dart:io` 的所有
  `IOSink` 子类都成立。
- **手工复刻的"同款校验"会漏规则**。测试里的 `_FakeSettableHeaders` 是
  照 `HttpHeaders.set` 的判据手写的，它复刻的只是我**以为**的规则。
  凡是"编码 / 序列化 / 协议细节"，**至少留一个走真实实现的用例**。
- **断言会固化错误结论**。Bug 622 的旧测试写的是
  `expect(d, contains('网络中间设备'))` —— 它把我的错误文案钉死成"期望行为"，
  于是真因查明后它反而成了阻力。**改文案时先问：这个断言是在保护什么？**
  这里保护的是"别只报类型名"，不是"必须提网络"。

---

### Bug 632 · `CodeController.value=` 在"整体替换文本"时越界崩溃（vendored 包，alpha.91 才暴露）

#### 症状

```
RangeError (index): Invalid value: Not in inclusive range 0..28: -1

#1  CodeController.value= (third_party/code_text_field/.../code_controller.dart:165)
#2  CodeEditorState.reset   (lib/editor/code_editor.dart:510)
#3  EditorPageState._applyDiskContent (lib/editor/editor_page.dart:1144)
```

注意第 2 帧：是 `reset()`—— 也就是**"把整份内容换成另一份"**这个操作。

#### 根因（vendored 包的启发式误判）

```dart
// third_party/code_text_field/lib/src/code_field/code_controller.dart
int? _insertedLoc(String a, String b) {
  final sel = selection;

  if (a.length + 1 != b.length || sel.start != sel.end) {
    return null;      // ← 判据：新文本比旧文本长 1 = "插入了一个字符"
  }

  return sel.start;
}

@override
set value(TextEditingValue newValue) {
  final loc = _insertedLoc(text, newValue.text);

  if (loc != null) {
    final char = newValue.text[loc];   // ← :165 越界崩在这
    ...
```

`_insertedLoc` 是为**自动闭合括号**这类 modifier 服务的：它用
"`新文本.length == 旧文本.length + 1`" 这个启发式来判断"用户敲进了一个
字符"。这个判据对逐字符输入是对的。

但 `reset()` 做的是**整体替换**：

```dart
_controller.value = TextEditingValue(
  text: content,                                       // 全新的整份内容
  selection: TextSelection.collapsed(offset: content.length),
  composing: TextRange.empty,
);
```

此时：
- `text`（控制器里的旧文本）与 `newValue.text`（新的整份内容）
  **内容毫无关系**，但**长度可能恰好差 1**；
- `_insertedLoc` 比较时用的 `selection` 是 `this.selection`，即
  **替换之前**的旧选区（不是 `newValue.selection`）；
- 于是它返回一个基于**旧文本**的 `sel.start`，拿这个索引去读
  **新文本** → 越界。

实测触发：编辑器里 29 字符的文件，被外部改成 28 字符 →
自动同步调 `reset()` → 崩。

#### 为什么 alpha.91 才暴露

`reset()` 一直存在（Bug 218 的撤销更改就用它），但**以前没什么人用**：

| 触发路径 | 内容长度差恰好为 1 的概率 |
|---|---|
| 手动「撤销更改」 | 低（用户不太会点，且长度常差很多） |
| 「从磁盘重新载入」 | 低（同上） |
| **alpha.91 自动同步** | **高**——外部 AI 每改一行就可能差 1，且这操作会**频繁自动发生** |

新功能不是"制造了 bug"，而是**把一条从没被走到的代码路径走热了**。

#### 修复（patch vendored 包）

```dart
set value(TextEditingValue newValue) {
  final loc = _insertedLoc(text, newValue.text);

  // ⚠️ FOA patch (alpha.91)：夹住索引。整体替换时 _insertedLoc 的
  // 启发式会误判，且它返回的偏移是基于旧文本的。
  if (loc != null && loc >= 0 && loc < newValue.text.length) {
    final char = newValue.text[loc];
    ...
  }
  super.value = newValue;
}
```

越界时**跳过 modifier 逻辑**直接赋值 —— 整体替换本来也不该触发
"插入一个字符"的语义，跳过是对的，不是妥协。

#### 教训

**vendored 的第三方代码里可能藏着"只有在特定输入模式下才暴露"的崩溃。**
这类问题的特征是：第一次走那条路就炸，但在此之前没人走过。
新功能上线前，值得问一句："**我这条新路径，以前有没有人走过？**"
没有的话，它很可能是第一个踩到某个陈年坑的。

（本条属于 vendored 包，升级上游时**记得重新打这个 patch**。
文件头 `third_party/code_text_field/` 里搜 `FOA patch` 可定位全部改动。）

---

### Bug 631 · `setMethodCallHandler` 每通道只有一个，后者**静默**顶掉前者（2026-09-26，alpha.91）

#### 症状

用户点构建完成的通知，**什么都不发生**。没有崩溃、没有异常、没有日志。
`navigate` 这个反向调用就像从来没注册过一样。

与此同时另一个功能也不灵了（或者反过来，只有另一个灵）。

#### 根因

`MethodChannel.setMethodCallHandler` 在 Dart 侧**每个通道只能有一个
handler，后注册的直接覆盖前一个**——注意是覆盖，不是"两个都收到"。

本项目此前只有 `lib/toolchain/build_notify.dart` 一处注册：

```dart
// build_notify.dart（alpha.91 之前）
static void ensureHandler() {
  if (_hooked) return;
  _hooked = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'navigate') onNavigate?.call();
  });
}
```

这个写法能工作，靠的是一句**注释里的侥幸**：

> 注意：dev.foa/proot 通道原生侧只 invoke 过 `navigate` 一个反向方法，
> 在此 setMethodCallHandler 不会劫持 Dart → Native 的正常调用。

它成立的前提是"永远只有这一个文件注册"。alpha.91 要加 `fsChange`
（文件变更推送），如果在新文件里再写一次 `setMethodCallHandler`：

- 新代码后注册 → **`navigate` 失效**（点通知没反应）
- `BuildNotify` 后注册 → **`fsChange` 失效**（自动同步收不到事件）

两种都不崩溃，都只是"功能没做"。这类 bug 极难查，因为没有任何线索
指向"注册被顶掉了"。

#### 为什么编译期完全无警告

两个 handler 都是合法的 `setMethodCallHandler` 调用，类型也对。
"只能有一个"是**运行时语义**，不是类型系统约束。Kotlin 那边
invoke 一个 Dart 未注册的方法同样是**静默丢弃**，不报错。

也就是说：**反向方法名是一个无任何编译期保护的全局命名空间**。

#### 修复

建立一个**唯一分发器** + **登记制** + **启动期自检**：

`lib/events/native_events.dart`（新建）：

```dart
class NativeEvents {
  static const String kNavigateMethod = 'navigate';
  static const String kFsChangeMethod = 'fsChange';

  /// 反向方法名 → 说明。**新增反向方法必须登记在这里**。
  static const Map<String, String> _reverseMethods = {
    kNavigateMethod: '用户点通知 → 回最近启动的前台任务页',
    kFsChangeMethod: '被监听文件发生变更（参数 {path, seq}）',
  };

  static void Function(String path)? onFsChange;

  /// 开发期自检：反向名不得与正向名重合。
  static void assertNoCollision() { ... }

  /// ⚠️ 全项目**只有这里**可以调 setMethodCallHandler。
  static void ensureHandler() { ... }
}
```

配套改动：
- `build_notify.dart` 移除自己的 `setMethodCallHandler`，改为**转调**
  `NativeEvents.ensureHandler()`（保留旧入口作兼容，标 `@Deprecated`）；
- `main.dart` 改调 `NativeEvents.ensureHandler()`；
- 新增反向方法只需在 `_reverseMethods` 登记 + 加一个 `case`。

#### 防复发：源码扫描断言

`test/native_events_test.dart`：

```dart
test('扫描全 lib/：只有 native_events.dart 真的注册反向 handler', () {
  final offenders = <String>[];
  for (final f in libFiles()) {
    if (f.path.endsWith('events/native_events.dart')) continue;
    if (stripComments(f.readAsStringSync()).contains('setMethodCallHandler')) {
      offenders.add(f.path);
    }
  }
  expect(offenders, isEmpty, reason: '...');
});
```

#### ⚠️ 踩坑：源码扫描必须先剥注释

我第一版直接对整份文件做文本匹配，结果**三条断言里两条红**——
红的不是代码，是**注释**：新写的说明性注释里出现了
"不要再写一次 `setMethodCallHandler`"这句话，被扫描当成了真实调用。

修法是先 `stripComments` 再匹配：

```dart
String stripComments(String s) {
  s = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');  // 块注释
  s = s.replaceAll(RegExp(r'//[^\n]*'), '');        // 行注释
  return s;
}
```

顺序不能反（先剥块注释再剥行注释），否则字符串字面量里的 `//`
会被当成注释起点，切掉半行代码。

**教训：源码扫描断言守的是"代码里有没有"，那么先要把"注释里有没有"
排除掉。**否则你会在注释里写什么、测试就红什么——包括你写的
"别这么写"的提醒。

---

### Bug 630 · 反向方法名两边对不上 → **静默丢弃**，Dart 永远等一个不来的事件（2026-09-26，alpha.91）

#### 症状

自动同步功能"没有反应"。没有报错、没有异常，编辑器就是**不更新**。

#### 根因

反向调用是两个**独立字符串**在跨语言握手：

```kotlin
// Kotlin 侧
dartChannel?.invokeMethod("fsChange", mapOf("path" to guest, ...))
```

```dart
// Dart 侧
case kFsChangeMethod:   // == 'fsChange'
```

这两边的字符串**没有任何机制保证一致**。改名一边、或者手滑打错一个
字母，Kotlin 照样 invoke 成功（引擎返回正常），Dart 侧 `switch` 走到
`default` 分支，**静默忽略**。

同理，正向方法的**参数 key** 也对不上就静默失败：

```kotlin
val guest = call.argument<String>("path") ?: ""   // Kotlin 读 "path"
```

```dart
_channel.invokeMethod('fsWatchStart', {'filePath': path})  // Dart 发 "filePath"
```

→ Kotlin 拿到 `null` → `""` → `resolveGuestPath("")` 返回 null →
`fsWatchStart` 返回 false → **静默降级**（功能"看起来能用"，只是慢）。

#### 为什么难查

整条链路上没有任何一处会报错。你只能观察到"功能没生效"，而错误信息
是空的。

#### 修复（项目惯例：Kotlin 零测试，用源码扫描代替）

```dart
test('Kotlin 侧确实存在这两个反向方法的 invoke 点（源码扫描）', () {
  final kt = src('android/.../MainActivity.kt');
  for (final name in [NativeEvents.kNavigateMethod, NativeEvents.kFsChangeMethod]) {
    expect(kt, contains('invokeMethod'));
    expect(kt, contains('"$name"'));
  }
});

test('两边的参数 key 一致：path（不是 filePath / guestPath）', () {
  expect(src('android/.../MainActivity.kt'),
      contains('call.argument<String>("path")'));
});
```

**注意断言写法**：不要匹配 `invokeMethod("fsChange"` 这个整串。
Kotlin 里参数变多后会被格式化换行：

```kotlin
dartChannel?.invokeMethod(
    "fsChange",
    mapOf("path" to guest, ...),
)
```

匹配整串就会因为**排版变化**而红——那测的是"怎么换行"，不是
"有没有这个调用"。拆成"有 `invokeMethod`"+"有 `"fsChange"`"更稳。

---

### Bug 629 · `reloadFromDisk` 里 `setState` 与 `reset` 顺序反了 → 每次重载后**假脏**（2026-09-26，alpha.91）

#### 症状

点「从磁盘重新载入」，内容正确更新了，**但文件名旁边立刻多出一个
未保存小圆点**。

危害不只是难看：

1. 用户以为自己在脏状态 → 再点一次保存 → 一次无意义的写盘；
2. 更糟：`_confirmSaveIfDirty()` 的守卫是 `if (!_dirty) return true;`，
   于是**切文件时会弹「未保存的修改」对话框**，而其实一个字都没改。
   这正是"同步完立刻切走"这条最自然的操作路径。

#### 根因

```dart
// 错（alpha.91 之前）
setState(() {
  _content = r.content;
  _initialContent = r.content;
  _dirty = false;                 // ← 先置 false
});
_editorKey.currentState?.reset(r.content);   // ← 这行又把它顶回 true
```

`reset()` 内部是 `_controller.value = TextEditingValue(...)`
（`code_editor.dart:510`），而 `CodeController` 上挂着 `_onChanged`
（`:245`）→ `widget.onContentChanged(text)` → EditorPage 的：

```dart
onContentChanged: (t) {
  _content = t;
  if (!_dirty) setState(() => _dirty = true);   // :1349
},
```

守卫 `!_dirty` —— 此刻 `_dirty` 刚被置成 false，**守卫恰好通过**，
于是又变成 true。

#### 修复

对齐同文件里 `_rollbackAi()`（`:1155`）的正确写法：**先 reset 再覆写**。

```dart
_editorKey.currentState?.reset(r.content);   // ① 先 reset（会让 _dirty 变 true）
setState(() {                                 // ② 再显式覆写钉死
  _content = r.content;
  _initialContent = r.content;
  _dirty = false;
});
```

让"复位引发的副作用"先发生，再用显式赋值把最终状态定下来。

#### 这条规则统一适用于三处

| 方法 | 顺序 | 说明 |
|---|---|---|
| `_rollbackAi()` | 先 reset | 一直都是对的 |
| `reloadFromDisk()` | 先 reset | alpha.91 修正 |
| `_applyDiskContent()` | 先 reset | alpha.91 新增（自动同步） |

#### 回归测试必须**先看它红**

`test/editor_reload_dirty_test.dart` 写了三条，全部走过"先红后绿"：

```
（修复前）
重载后不应残留未保存标记 ............ [E]  Found 1 widget（绿点还在）
重载后能干净地切走文件 .............. [E]  Found 1 widget text "未保存的修改"
重载后内容确实换成了磁盘上的版本 .... ✓（这条本来就该过，用来证明测试是有针对性的）
```

第三条特意保留：它证明"测试不是在无差别地失败"，而是**精确指向
状态标记这一个问题**。

---

### Bug 627 · Gradle 报 `Cannot access output property 'outputDir'` / `Failed to create MD5 hash`（2026-09-26，alpha.89）

#### 症状

```
> Cannot access output property 'outputDir' of task ':app:mergeReleaseJniLibFolders'.
  Accessing unreadable inputs or outputs is not supported.
> Failed to create MD5 hash for file:
  .../merged_jni_libs/release/mergeReleaseJniLibFolders/out/arm64-v8a/libapp.so
BUILD FAILED in 55s
```

#### 关键判断：这不是代码问题，别再查代码

出现这条时的**先行检验**：

| 检查 | 结果 |
|---|---|
| 门禁（`flutter analyze` + 全量测试） | **已经全绿**（1419 条） |
| 报错文件是否存在、是否可读 | **存在、`-rw-r--r--` 可读** |

两条都正常，说明**不是我们的代码**——是 Gradle 的**增量构建状态**与残留
中间产物不一致。Gradle 9.3.1 在算 `mergeReleaseJniLibFolders` 产物的 MD5 时，
那个文件正好处于"刚被写入 / 时间戳被刷新"的状态。

#### 解法（**顺序很重要**）

```bash
# 第一步：停掉 Gradle / Kotlin daemon（必须！）
bash tools/mem_check.sh --clean

# 第二步：删中间产物（daemon 停了之后删才有效）
rm -rf app/build/app/intermediates/merged_jni_libs
```

重建即通过。

> ### ⚠️ alpha.90 实测更正：只删目录是**不够**的
>
> alpha.90 出包时这条**连撞两次**：
>
> | 尝试 | 做法 | 结果 |
> |---|---|---|
> | 第一次 | 只 `rm -rf merged_jni_libs app/android/.gradle` | **5 秒就再挂**（比原来还快） |
> | 第二次 | **先 `mem_check.sh --clean` 停 daemon**，再删目录 | ✅ 一次通过 |
>
> **原因**：Gradle daemon 还活着时，它进程里持有 stale 的 task 状态和
> 文件句柄。**你删了磁盘上的文件，daemon 并不知情**，下一次构建它按自己的
> 内存状态认为"这个产物还在"，于是又去算那个已经不完整的文件的 MD5。
> **光删磁盘文件没用，必须先让 daemon 忘掉。**
>
> #### 真身：内存压力下写出的**半截文件**
>
> alpha.90 实测数据：
> - 构建**还没开始**，cgroup 已用 **6.78G / 8G**（GradleDaemon 2.9G +
>   KotlinCompileDaemon 1.1G + others）；
> - `mem_check.sh --clean` 后降到 **2.59G**。
>
> `mergeReleaseJniLibFolders` 要把 Flutter 编出的 AOT `libapp.so`
> （约 14.5 MB）**合并进中间产物目录**。构建期内存已经吃了 4G+，
> 这次写入**被中途掐断，留下一个不完整的文件**。
> 下一次构建算它的 MD5 → 炸。
>
> **所以这不是"时间戳正好在变"，是文件本身是残缺的。**
> 内存紧张 → 写入中断 → 残缺文件 → MD5 失败，是一条完整因果链。
>
> #### 修正后的判断顺序
>
> ```
> ① 门禁是不是绿的？               → 是 → 不是代码问题
> ② cgroup 内存用了多少？           → 偏高 → 先 mem_check.sh --clean
> ③ daemon 停了吗？                 → 没停 → 删文件是白删
> ④ 删中间产物 → 重建
> ```
>
> ⚠️ **不要做的事**：不要加 `--stacktrace` / `--info` 深挖，不要改
> `android/gradle.properties`，不要动 `abiFilters`。这是**状态 + 资源问题，
> 不是逻辑问题**，而报错文案（"Accessing unreadable inputs or outputs"）
> 很容易让人误以为是权限或配置问题。

> ### ⚠️⚠️ alpha.94 实测**再更正**：不是半截文件，`sync` 也不够
>
> alpha.94 出包时这条**第三次出现**，而且照着上面那套做（停 daemon → 删目录
> → sync → 重建）**仍然原样复挂**。重新取证：
>
> | 检验 | 实测结果 |
> |---|---|
> | `stat` 文件大小 | 14,870,416 字节，**完整**（不是半截） |
> | `md5sum` | `Input/output error` |
> | `dd` 读 | **0 字节** |
> | 上游 `merged_native_libs/…/libapp.so` | **能读**，md5 `ddf307cb…` |
> | `generated/jniLibs/…/libapp.so` | **能读**，md5 同上 |
> | **等 20 秒后**再 `md5sum` 那个报错的文件 | **成功，且 md5 与上游完全一致** |
>
> 结论三条，逐条推翻前面的旧说法：
>
> 1. **文件是完好的**（与上游逐字节一致），"半截文件"这个诊断错了；
> 2. **真身是"刚 copy 出来的那份立刻读会 IO error"**——Gradle 的
>    `mergeReleaseJniLibFolders` 是 copy 完**马上**给输出算 MD5，
>    正好撞在这个窗口里；
> 3. **`sync` 不保证返回时脏页已落盘**。alpha.92/93 那两次"sync 后就好了"
>    是碰巧（sync 自己耗掉的那几秒刚好够）。
>
> #### 试过的两条**无效**方案（别再走一遍）
>
> | 方案 | 结果 |
> |---|---|
> | 清完目录后**写个 8MB 探针文件、反复 sync + 等到能读** | 探针**第 1 轮（2s）就通过**，但构建照样挂 → 说明不是"系统整体没落盘"，是这个 task 自己的窗口 |
> | `doNotTrackState()`（Gradle 报错文案里建议的那条） | **`Changes are not tracked, unable determine incremental changes.`** —— 该 task 是增量的，关掉状态跟踪它自己就没法工作了 |
>
> #### 采用的解法：在 task 的 `doLast` 里**读到能读为止**
>
> `doLast` 正好落在"copy 完 ↔ Gradle 做输出快照"之间，所以在这里自己
> 把输出文件读一遍，读不动就等 1s 重试（最多 30s），即可绕过去：
>
> ```kotlin
> // app/android/app/build.gradle.kts
> tasks.configureEach {
>     if (name.startsWith("merge") && name.endsWith("JniLibFolders")) {
>         doLast {
>             val deadline = System.currentTimeMillis() + 30_000
>             while (System.currentTimeMillis() < deadline) {
>                 try {
>                     val stack = mutableListOf<File>()
>                     outputs.files.files.forEach { stack.add(it) }
>                     while (stack.isNotEmpty()) {
>                         val f = stack.removeAt(stack.lastIndex)
>                         if (f.isDirectory) f.listFiles()?.forEach { stack.add(it) }
>                         else f.inputStream().use { s -> s.read(ByteArray(8192)) }
>                     }
>                     return@doLast
>                 } catch (e: java.io.IOException) { Thread.sleep(1000) }
>             }
>         }
>     }
> }
> ```
>
> 两个写法上的坑（都是编译期才炸，且报错指向别处）：
> - **别写 `java.util.ArrayDeque`** —— 脚本里 `java` 是 `JavaPluginExtension`
>   的属性名，会被遮蔽成 `Unresolved reference 'util'`；
> - **别用 `FileTree.visit { }`** —— Kotlin DSL 里这个重载的 lambda 参数
>   解析不出来（`Unresolved reference 'it'`），用显式栈遍历替代。
>
> ⚠️ 这条**只加在 FOA 自己的出包工程**，**不要抄进给用户工程用的 Flutter
> 模板**：这是本沙箱 overlayfs 的现象，手机上是真实 ext4/f2fs，
> 用户的构建脚本该保持干净。

#### 通用教训

- **构建报错先做"是不是我的代码"二分**：门禁全绿 + 报错指向的文件本身正常
  → 优先怀疑构建缓存/状态，而不是改源码。
- **"上次这么做就好了"不等于根因找到了**。这条 bug 三次归因三次被推翻
  （时间戳 → 半截文件 → 落盘慢 → 实际是 copy 后立即 hash 的窗口），
  每次都"当时能复现当时能解决"。记结论时**必须写清当时实测了什么**，
  否则下一个人（很可能就是你自己）会照着错的方法再试一遍。
- **增量构建状态会腐坏**。同一个仓库反复构建、构建被中断、并发跑测试与构建，
  都可能留下不一致的中间态。**"清掉中间产物重建"是最廉价的第一手尝试**，
  比读 Gradle 文档快得多。
- **但"清"的前提是"停"**。daemon 持有状态时，磁盘清理是无效动作——
  第一次 5 秒复挂就是这个原因。**先停进程，再清磁盘。**
- **内存是这类"玄学构建失败"的常见上游**。cgroup 6.78G/8G 时出各种
  写文件失败的怪报错，别只盯着文件系统和 Gradle 版本。
- 报错里带 `libapp.so` 会让人以为 Dart 侧出了问题。**看任务名**
  （`mergeReleaseJniLibFolders`）就知道是**合并 JNI 库**这一步，与 Dart 无关。

> ### ⚠️ alpha.92 / alpha.93 实测更正：「半截文件」这个真身判断是**错的**
>
> 上面那段"内存压力下写出半截文件"的结论，被 alpha.92 的直接测量推翻：
>
> | 检查 | alpha.92 实测结果 |
> |---|---|
> | `ls -l` 文件大小 | **14,774,568 字节，完整** |
> | `dd` 分块读（9 块） | **全部读成功**（我第一版脚本误报 IO ERROR，是 `count=1` 没读满导致非零退出 + 我把 stderr 也吞了） |
> | `md5sum` | **成功**（`sync` 之前失败、之后成功） |
> | `stat` | 正常 |
>
> 真因是 **overlayfs 脏页没落盘**：`cp` 写完文件后**立刻**去读会返回
> `Input/output error`，Gradle 这时正好来算 MD5，就撞在这个瞬时 IO error 上。
> `sync` 之后立刻恢复正常——**文件从头到尾都是好的**。
>
> 因果链修正为：
>
> ```
> 内存紧张 → 构建被掐断（真）
>   └→ 但报错的直接原因是：刚写完的文件脏页未落盘 → 读它得到 IO error（真）
>       而不是：文件被写了一半（假）
> ```
>
> **处置顺序因此必须加一步**（已改进 `tools/release.sh`）：
>
> ```bash
> bash tools/mem_check.sh --clean                                  # 1 停 daemon
> rm -rf app/build/app/intermediates/merged_jni_libs app/android/.gradle  # 2 清产物
> sync                                                              # 3 落盘（缺它就必然复挂）
> ```
>
> alpha.93 出包实测：脚本里只有 1+2（没有 `sync`）→ 自动重试**原地复挂**；
> 手工补 `sync` 后一次通过。**同一个坑两次踩在同一步**。
>
> 教训：**"文件读不了"和"文件内容坏"是两件事**。前者可能是 page cache /
> 文件系统状态问题，用 `sync` 就能验证；直接按后者处理（删文件重编）会
> 让人得出错误的因果解释，并写出一个**永远重试不成功**的兜底分支。

> #### ⚠️⚠️⚠️ alpha.96 第三次更正：`doLast` 也不够，要 `doFirst` + `doLast`
>
> alpha.94 加的 `doLast` 等待（读到能读为止，最多 30s）在 alpha.95 出包时
> **有效**，但 alpha.96 出包时**又挂了**，而且**报错变了**：
>
> ```text
> > Cannot access output property 'outputDir' of task
> >   ':app:mergeReleaseJniLibFolders'. Accessing unreadable inputs or
> >   outputs is not supported.
> > Failed to create MD5 hash for file: .../libapp.so
> ```
>
> **关键在措辞**：报错的是"访问 `outputDir` **这个动作**"失败了，
> 不是某个具体文件读不了。说明：
>
> ```text
> doLast 执行  →  我读通了（这是 alpha.94 保证的）
>      ↓  Gradle 做输出快照
> 再读一次 outputDir  →  又撞进 IO error 窗口   ← 这里挂的
> ```
>
> 也就是 **`doLast` 只保证"我读的时候可读"，保证不了"Gradle 读的时候可读"**。
> 中间隔着一个快照阶段，时间窗又拉开了。**两次生效不代表根因找到了。**
>
> **alpha.96 的解法：两段 hook 组合**
>
> ```kotlin
> fun bug627WaitReadable(files: Iterable<File>, label: String, maxMs: Long) { … }
>
> tasks.configureEach {
>     if (name.startsWith("merge") && name.endsWith("JniLibFolders")) {
>         doFirst { bug627WaitReadable(outputs.files.files, "pre", 15_000) }   // ① 消掉上一轮残留
>         doLast  { bug627WaitReadable(outputs.files.files, "post", 60_000) }  // ② 等新产物
>     }
> }
> ```
>
> - `doFirst`：copy **之前**先把上一轮残留的不可读窗口消掉；
> - `doLast`：copy **之后**读到可读为止（30s → **60s**，多留余量）；
> - 两段都读 `outputs.files.files`，覆盖 Gradle 的两条访问路径。
>
> alpha.96 出包实测：**一次通过**，六项验证全过。
>
> **还是那条元教训**（本次是它的第三次应验）：
>
> > **"上次这么做就好了" ≠ "根因找到了"。**
>
> 三次记录分别推翻了前一次的结论：
> "半截文件"（错）→ "sync 就好"（不完整）→ "doLast 就好"（不完整）。
> 每次都是在**同一个报错的不同措辞**里藏着新信息，而前一次的成功
> 会让人停止追问。

---

### Bug 628 · "别的程序可以不填模型名然后自己选" —— 我把发现成本推给了用户（2026-09-26，alpha.90）

#### 症状

alpha.89 交付后，用户在面板上点了「测试连接」，得到的提示是：

> 还没选模型。请查阅服务商文档确认模型名后填入（**我们无法替你猜**）

用户的反应：

> 我看别的有的程序不是可以不填模型名然后自己选择模型吗？

**这一问没有技术难点，纯粹是设计失职。** 上一版的"留空就拦下"不是解决问题，
是**把本该由程序承担的发现成本原样推给了用户**。用户被叫去"查文档"，
而同类产品是**点一下按钮，模型列表就出来了**。

#### 原因

**没有实现 `GET /models`。**

OpenAI 兼容接口都提供：

```
GET {baseUrl}/models
→ {"object":"list","data":[{"id":"deepseek-v4-flash",...},{"id":"deepseek-v4-pro",...}]}
```

这个端点有两个好处：

1. **它就是一份权威清单**，不需要用户去翻文档、不需要我硬编码任何模型名
   （硬编码的模型名会过期 —— Bug 626 的 `deepseek-chat` 就是这么挂的）。
2. **拉得到列表 = 地址对 + 密钥对**。它**本身即一次连通性 + 密钥校验**，
   而且比"发一条真请求去试"代价低、失败原因更干净
   （拉不到就是拉不到，不会扯上模型名、上下文长度等一堆变量）。

#### 解决

**`llm_client.dart`**

| 新增 | 作用 |
|---|---|
| `LlmTransport.get` | 接口加一个方法；`IoLlmTransport` 与 `FakeLlmTransport` 同步实现 |
| `IoLlmTransport._send(url, headers, body?)` | `post`/`get` 共用；`body == null` 即走 GET |
| `parseModelIds` | 兼容 `data` / `models` / 裸数组；元素支持 `id` / `name` / `model`；**去重 + 排序** |
| `modelsEndpoint` | `/chat/completions` 结尾先砍再拼 `/models`；`/v1` 保留 |
| `ModelListResult` + `fetchModels` | 把"HTTP 状态 / 错误原因 / 模型 id 列表"打包返回 |

**`ai_takeover_panel.dart`**

- 新增 `_loadingModels` / `_models` / `_modelsError` 三态。
- 模型名那行改成 `Row`：输入框 + **「获取模型」按钮**。
- 拉到列表后，下方 `Wrap` 铺开可点选的 `_modelChip`，**点一下即填入**。
- 若当前填的模型不在列表里 →
  `当前填的「$cur」不在该接口的可用列表里，建议换一个`。
- 留空文案改为：
  > 还没选模型。点「获取模型」从接口拉回可用列表再点一个即可（不用自己查文档）

#### 顺带修掉的一个测试坑（Bug 625 的同一家族）

`FakeLlmTransport` 原先直接持有调用方传进来的 `responses` 列表。
为消 `prefer_const_constructors` 给构造参数加 `const` 之后，
调用方传的是 `const [...]`，后续 `removeAt` 直接抛：

```
Unsupported operation: Cannot remove from an unmodifiable list
```

**解法**：构造时 `List.of()` 复制一份，**永远不持有调用方的容器引用**。
顺手加 2 条回归测试钉住这个行为。

#### 教训

> **"无法替你猜"是程序在把自己的活儿外包给用户。**
> 凡是"需要用户去查文档才能填对"的输入框，先问一句：
> **这个值，接口自己有没有提供列表？** 有就把它拉下来让用户点。

这跟 Bug 626 是同一个病根的两面：那次是**硬编码了一个会过期的模型名**，
这次是**干脆不填、让用户自己查**。两头都不对——
**唯一正确的来源是接口本身**。

**出现版本**：alpha.89
**修复版本**：alpha.90

---

### Bug 626 · `deepseek-chat` 已于 2026-07-24 弃用，调用返回 **HTTP 400**（2026-09-26，alpha.89）

#### 症状链

Bug 623（latin1 编码）修好之后，真机错误从 `ArgumentError` 变成：

> 失败：请求失败（HTTP 400）

**编码问题确认解决**（请求真的发出去了、服务端也回话了），但 400 仍然没说为什么。

#### 排查：用探针排掉"URL 形态"与"body 结构"

```
① /v1/chat/completions        → 401
② /v1/v1/chat/completions     → 401
③ /chat/completions           → 401
④ 根路径 /                     → 401
⑤ 非法 JSON body              → 401
⑥ 缺 messages                 → 401
⑦ messages 空数组              → 401
```

**七种形态全是 401。** 关键推论：

> DeepSeek 的**鉴权检查优先于格式检查**。用无效 key 时，
> 无论 body/URL 多离谱都先返回 401，**根本走不到格式校验**。

所以用户拿到 400 只能说明一件事：**他的密钥是有效的**，请求进入了格式校验后被拒。
这也意味着**用假 key 在沙箱里永远复现不出 400**——必须查文档。

#### 真因：模型别名过期

官方文档（`api-docs.deepseek.com`）：

> **The model names `deepseek-chat` and `deepseek-reasoner` will be deprecated on 2026/07/24.**
> **Requests to those legacy model names now return HTTP errors.**

| 旧名（已弃用） | 新名 |
|---|---|
| `deepseek-chat` | `deepseek-v4-flash` |
| `deepseek-reasoner` | `deepseek-v4-pro` |

而我们在 UI 上**拿 `deepseek-chat` 当示例占位符**，等于**引导用户填一个必挂的值**。
这不是用户填错，是**我们的提示误导了他**。

#### 顺带查出的第二个坑：默认模型名写死

```dart
// ❌ 旧代码
final model = cfg.model.trim().isEmpty ? 'gpt-4o-mini' : cfg.model.trim();
```

用户 baseUrl 填 `api.deepseek.com` + 模型名留空 → 拿 `gpt-4o-mini` 去问 DeepSeek
→ **必然 400**，提示还只有"HTTP 400"。

**"猜一个默认模型"在跨服务商场景下根本不成立**：每家模型名不同，猜错就是必挂。
改成留空直接拦下并说清楚：

```dart
if (model.isEmpty) {
  return const AiOutcome.failure(
    '没填模型名。各家模型名不同（如 DeepSeek 是 deepseek-v4-flash、'
    '`deepseek-chat` 已于 2026-07-24 弃用），无法替你猜，请按服务商文档填写',
    remedy: AiRemedy.configureLlm,
  );
}
```

UI 同步改：`模型名（可留空）` → `模型名（必填）`，占位符
`deepseek-chat` → `deepseek-v4-flash`。

#### 第三个问题：把服务端写好的原因丢了

`describeHttpError` 的 `default` 分支只返回 `请求失败（HTTP $status）`，
而 DeepSeek 的 400 响应体里明明写着原因：

```json
{"error":{"message":"Model Not Exist","type":"invalid_request_error"}}
```

新增 `errorMessageFromBody()`，从响应体里**只摘 `error.message`**（不整段回显，
避免账号信息泄漏 + UI 撑爆），摘出的串再过一遍密钥打码——
DeepSeek 真的会把收到的 key 片段回显在错误里（`Your api key: ****-key is invalid`）。

`describeHttpError` 新增 `serverMessage` 参数，**优先级最高**：

```dart
if (serverMessage.isNotEmpty) return '服务端拒绝：$serverMessage';
```

同时给 400 补了诚实版兜底（摘不出原因时才用）：

```
请求被拒（HTTP 400）：常见原因是模型名不存在、上下文超长，
或接口地址多/少了一级 /v1
```

⚠️ 措辞刻意用「常见原因」而非肯定句——Bug 622 就是栽在"编一个确定结论"上。

#### 通用教训

- **第三方 API 的"名称"会过期**。模型名、端点版本、参数名都随时间失效，
  而**过期后往往报一个语焉不详的状态码**（400 而不是"model not exist"）。
  占位符 / 示例 / 默认值里写死的第三方标识，都是**定时炸弹**。
- **鉴权优先级决定了能否用假凭证复现**。发现"怎么试都只返回 401"时，
  要意识到**格式类错误在这条路径上根本测不到**，该转去查文档而不是继续试。
- **`default: return '请求失败（HTTP xxx)'` 是信息黑洞**。状态码是给机器看的，
  服务端的 `error.message` 才是给人看的。**拿到响应体就该摘出来**。
- **"猜默认值"跨服务商必错**。宁可拦下要求用户填，也不要猜——
  猜错的代价是用户对着 400 查半天。


本轮出包时连踩两个脚本坑，都是"脚本本身有问题，不是环境有问题"。

#### ① `release.sh` 在自动化环境里必然中止

```bash
bash tools/mem_check.sh || true
echo
read -r -p "  内存形势看清了吗？继续构建？[y/N] " _ans
[[ "${_ans:-N}" =~ ^[Yy]$ ]] || die "已中止（先按上文处置内存问题）"
```

`read` 是**交互式确认**，本意是"让人看一眼内存再决定"。但在 CI /
后台任务 / `nohup` 里没有 stdin，`read` 立刻返回非零，`_ans` 为空 →
`${_ans:-N}` 兜底成 `N` → 直接 `die`。

**症状有迷惑性**：日志最后停在「❌ 已中止（先按上文处置内存问题）」，
让人以为是内存不够，其实 cgroup 只用了 29%。

**绕过方式**：

```bash
yes y | bash tools/release.sh      # 持续喂 y
# 或
bash tools/release.sh < /dev/null  # 不行！仍然会中止，因为读到 EOF
```

⚠️ 注意 `< /dev/null` **没用**——`read` 读 EOF 同样返回非零。必须真给输入。

#### ② `mem_check.sh` 里 `PROPS` 路径写死

```bash
PROPS="/workspace/app/android/gradle.properties"   # ❌
```

项目实际在 `/workspace/FOA/FOA/app/`，所以这格**永远**打印
「⚠ 未找到 .../gradle.properties」，堆预算核算形同虚设——
而这个体检脚本的存在意义就是算堆预算（Bug 469 那次栽在漏算 daemon）。

**修法**：按脚本自身位置回溯仓库根。

```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPS="$REPO_ROOT/app/android/gradle.properties"
```

修好后能正常读出：

```
org.gradle.jvmargs=-Xmx2560m -XX:MaxMetaspaceSize=768m
kotlin.daemon.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=512m
```

#### ③ 顺带：内存被残余 daemon 占满，先把它们停掉

第一次跑构建时 cgroup **已用 85%（7033/8192 MB）**，元凶是一个
**3.8 GB 的 `java`（GradleDaemon）** 和 845 MB 的 `dartaotruntime`——
都是前一轮 `flutter test` 留下的。处置：

```bash
cd app/android && ./gradlew --stop
pkill -f GradleDaemon; pkill -f KotlinCompileDaemon
```

清理后从 7033 MB 降到 **2363 MB（29%）**。

**通用教训**：
- **交互式确认 = 自动化流程的隐患**。脚本里出现 `read -p` 的那一刻，它就只能
  手动跑了。要么加 `--yes` / `-y` 开关，要么把确认改成"打印证据 + 显式参数"。
- **路径不许写死绝对前缀**。本项目在 `/workspace/FOA/FOA/`，任何
  `/workspace/app/...` 形式的硬编码都会静默失效——**而且失效方式是"打印一句
  警告继续跑"**，比直接报错更难发现。
- **测试进程不退干净会连带下一个任务**。长跑 `flutter test` 之后出包前，
  先跑 `bash tools/mem_check.sh --clean`。

---

### Bug 625 · 测试里的"手工同款校验"漏规则 —— 而且断言会固化错误结论（2026-09-26，alpha.88）

这条从 Bug 623 里单独拎出来，因为它是个**反复出现的模式**，不限于本次。

#### 症状：用假实现替身测了半天，真路径一行没跑

```dart
class _FakeSettableHeaders {
  void set(String name, String value) {
    // 与 HttpHeaders.set 一致的非法字符判据（实测行为）
    if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(value)) {
      throw const FormatException('Invalid HTTP header field value');
    }
  }
}
```

注释写着"与 `HttpHeaders.set` 一致"，但那只复刻了我**以为**的规则。
而 `ai_llm_client_test.dart` 原有 495 行里，**`IoLlmTransport` 一次都没被实例化**——
全部走 `FakeLlmTransport`。于是 `req.write(body)` 落到 latin1 这条最脆弱的路径，
零覆盖，bug 在那里躺了两个版本。

#### 症状：断言把"我编的文案"钉成期望行为

```dart
test('ArgumentError 不再裸奔成"请求失败（ArgumentError）"', () {
  expect(d, isNot(contains('ArgumentError')));
  expect(d, contains('网络中间设备'), reason: '要给出可操作的怀疑方向');
  //                ^^^^^^^^^^^^^^^^ 这句是我编的，纯属虚构
});
```

真因（latin1 编码）查明后，这条断言**反而成了阻力**——它保护的不是
"别只报类型名"这个真实意图，而是"必须提网络中间设备"这个错误结论。

#### 判据与修法

| 场景 | 要求 |
|---|---|
| 编码 / 序列化 / 协议细节 | **必须至少一个走真实实现的用例**（这里是绑 `HttpServer` 到 `127.0.0.1:0` 做 echo） |
| 写"同款校验"假实现 | 注释里必须写**它是近似，不是等价**；且真实路径另有覆盖 |
| 改文案时 | 先问：**这条断言在保护什么意图？** 若保护的是文案措辞而非意图，就该改成断言意图 |

本次加的回归测试（必须"先看到它红过"）：

```
回退修复 → 测试变红，报错与真机截图**一字不差**：
  Invalid argument (string): Contains invalid characters.:
  "{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"system\",
   \"content\":\"你是嵌在手机 IDE 里的代码补全体。…
恢复修复 → 变绿
```

**"没先看到它红过"的回归测试不算回归测试**——你不知道它到底测没测到那条路径。

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

> **⚠️ 2026-09-19 补充（alpha.62 出包时踩到，与上面是**两个不同**的成因）**
>
> 同样的报错文案，但这次**不是 cgroup OOM**：
>
> - `free -m` 显示 **123GB available**、32 核，`dmesg` 里**没有任何** killed process 记录；
> - 失败点在 `assembleRelease` 的 **2474s**（≈41 分钟），而且日志里已经出现
>   `Font asset "MaterialIcons-Regular.otf" was tree-shaken` —— 说明构建已经跑到
>   **后期打包阶段**，不是早期依赖解析。
>
> 真因是 **JVM 自身堆耗尽**。1.5G 这组值是当年按 5.8GB 小机器定的，
> 而 **release 构建**（AOT + R8 混淆 + 全量 dex）的内存曲线比 debug 陡得多。
>
> **判据（一句话区分两者）**：
>
> | 现象 | 成因 | 对策 |
> | --- | --- | --- |
> | `free` 显示内存紧张 / `dmesg` 有 OOM 记录 | cgroup OOM killer 杀进程 | **下调** jvmargs，给系统留空间 |
> | `free` 显示大量 available / `dmesg` 干净 | JVM 堆不够 | **上调** jvmargs |
>
> 本构建机（123GB / 32 核）实测改为
> `org.gradle.jvmargs=-Xmx6g -XX:MaxMetaspaceSize=2g` +
> `kotlin.daemon.jvmargs=-Xmx3g` 后 release 构建通过。
> **手机端不要照抄这组值**——仍按设备 RAM 用 init.gradle 动态下调。
>
> **方法论**：同一个报错文案可以有相反的修法。
> **改之前先看 `free` 和 `dmesg`**，不要见到 "daemon disappeared" 就条件反射去降堆。

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

> **⚠️ 2026-09-19 批注（Bug 449 平反，保留原文作误诊标本）**：
> 本条目的"真因锁定"结论**已被推翻**。真机直控通道打通后做了三组对照
> 实验——`-cpu max` / 默认 / `-cpu qemu64` 跑**同一个真实 AOT dill**
> （47MB，正宗 frontend_server AOT+TFA 产物）——**全部 rc=0**：
> arm64 host 的 qemu 默认模型对 gen_snapshot **并没有门控**（Dart 编译器
> 运行时自己检测 CPU 特性，无 AVX 走标量路径）。当时"沙箱 `-cpu qemu64`
> rc=132 与真机 exit -4 逐位一致"是**不同故障撞出同一个信号码**的巧合
> （SIGILL 是执行域故障的常见终点），这个"逐位一致"把方向带偏了两个版本；
> 沙箱 rc=134 实为 dill 缺 AOT/TFA 元数据（"Missing table selector
> metadata"），当时被误读成"业务报错=环境好"。
> **真因见 Bug 449**：linux-x64/ 裸真身被直接 exec。`-cpu max` 修复本身
> 保留（无害的防御纵深）。gen_snapshot 从第一天起就没毛病。

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

### Bug 449：五个版本的 exit -4 真因——dart 经 qemu 自报 x64，全部工具解析到 linux-x64/ 裸真身

**日期**：2026-09-19（真机直控裁决当日；alpha.55 固化）
**出现版本**：alpha.49 ~ alpha.53（AOT 阶段 `exit -4` 的最终真因；
更早的 alpha.37~48 是它的各层外围：Bug 428/429/433/439/441/442/444/445）

**症状**：构建在 AOT/Shader 阶段 `Dart snapshot generator failed with
exit code -4`（SIGILL）、`impellerc failure:` ×2。转发层全程完好
（AOT_FP 全 ok、REASSERT 正常）、内存充足、所有诊断探针全绿——
Bug 446 的"能启动 ≠ 能编译"结论也错了：连真实 AOT 负载探针都是绿的。

**裁决通道**：cloudflared quick tunnel + HTTP 命令服务直控真机
（wget 无 curl、无 ps/pgrep 用 /proc 遍历、CF 隧道在构建负载下频繁
1033/524 断连，靠用户手动重启换 URL 维持）。

**五轮裁决实验（时间线）**：

| # | 实验 | 结果 | 排除的假设 |
|---|---|---|---|
| 1 | gen_snapshot --version 三 CPU 模型 | 全 rc=0 | qemu 本体/加载方式 |
| 2 | impellerc 最小 GLSL 真编译 | 全 rc=0，产出 1084B SPIRV | qemu + shader 输入 |
| 3 | 沙箱拷来的 8.6MB dill | 全 rc=134 | ——（误读：非"业务报错"，是 dill 缺 AOT/TFA 元数据） |
| 4 | 正宗 AOT dill（dartaotruntime + frontend_server_aot.snapshot --aot --tfa 自编，47.4MB）三模型 | **全部 rc=0**（max 4m58s / def 5m27s / q64 5m27s，产物逐字节同尺寸） | **TCG 门控（Bug 447 被平反）** |
| 5 | 构建自带的 22.6MB dill 手工喂 gen_snapshot | rc=0 | dill 输入 |

→ **gen_snapshot 从第一天起就没毛病；唯一还站着的是"构建流程喂的路径
不对"。给引擎目录埋点（wrapper 里 echo 命中日志），真相出来了。**

**真因证据链（埋点实锤）**：

1. App 部署的 dart 是 **x86_64 二进制经 qemu 运行**（dart-sdk/bin 原位
   包装，Bug 428 系列的产物）→ dart VM 内 `Abi.current()` 自报 **x64**；
2. flutter_tools `getCurrentHostPlatform()` 据此判定 **linux_x64**
   ——artifacts.dart 只对 darwin_arm64 做 x64 回退，**linux_arm64 没做**
   （flutter/flutter#152281）；
3. 于是 gen_snapshot（android-{arm,arm64,x64}-release 三个 target 全部）、
   impellerc、font-subset **全部解析到 `linux-x64/` 原目录**；
4. 该目录下是裸 x64 ELF（兼容层只包了 linux-arm64/ 对称位），arm64 内核
   exec → SIGILL = exit -4；
5. **埋点证据：linux-x64 位命中日志 X64_GEN / X64_IMPELLER 刷屏，
   维护了一个多星期的 linux-arm64/ 对称 wrapper 零命中——从构建第一天起
   就没被调用过一次。**

**修复（真机现场实证 → alpha.55 固化）**：

1. **linux-x64 原位包装**：官方名字位 `gen_snapshot` 改名 `.foa-real`，
   原路径放 wrapper（真身感知：对称段 gen 直接指 `.foa-real`，不过两层
   sh）。覆盖：android-{arm,arm64,x64}-release + 顶层 linux-x64 的
   gen_snapshot ×3、impellerc、font-subset。真机修完 build7 直接产出
   **app-release.apk 43.0MB**（x86_64 工具链经 qemu 在 arm64 真机全链路
   首次全绿）。
2. **precache 自愈**：wrapReassertScript 新增 REASSERT_INPLACE 段——
   precache 会把官方 ELF 写回原位冲掉 wrapper，构建前无条件再断言
   （`*.foa-real` 是私有名，precache 不会碰，mv 覆盖同名真身也安全）。
3. **AOT_FP 角色判定升级**：`*.foa-real` → REAL 期望 raw；其余（含
   linux-x64/ 普通名字）→ SLOT 期望 wrapper；指纹列表补
   `gen_snapshot.foa-real` 条目。
4. **AOT_LOAD_DEF 探针改指 `.foa-real`**（裸 qemu 执行不了 `#!` 脚本）。
5. **verify 冒烟补 GEN_INPLACE / IMPELLERC_INPLACE**（验证不到的路径
   就是会崩的路径——Bug 437 原位版）。
6. **卸载还原**：uninstallScript 增加 linux-x64 位 `.foa-real` → 原名
   循环。
7. **NDK strip 补位（连带暴露）**：AOT 修通后第一次跑到 gradle
   `:app:stripReleaseDebugSymbols` 才发现 NDK 是空壳（只有
   source.properties，Bug 427 的省 2GB 设计）——此前五版全死在 AOT，
   strip 执行期从未到达，窟窿一直没暴露。修复：**不装完整 NDK**，apt 装
   Debian llvm（arm64 原生、不过 qemu、能剥任意架构 ELF），symlink
   llvm-strip/llvm-objcopy 进 NDK 期望路径（`ndkStripTools`，构建前
   探测→补位，失败不阻断）。
8. **chk/复核脚本收敛**：qemuCompatEnsure 的全量比对原先 chk 与复核两份
   手抄已开始漂移（miss 标签不一致），收敛到 `wrapCheckScript(tag)` 单一定义。

**教训**：

- **二进制架构自报不可信，以调用路径埋点实证。** dart 说自己是 x64、
  诊断说转发层完好、负载探针说 AOT 能跑——全都对，但拼出来的"构建应该
  能过"是错的。唯一可靠的是**在真实调用路径上埋点**，看构建那一刻到底
  exec 了哪个文件。这条也写进了 SKILL 排障表。
- **"逐位一致的 rc"不等于"同因"。** Bug 447 的 `-cpu qemu64` rc=132 与
  真机 exit -4 逐位一致，貌似铁证，实为两个不同故障撞同一个信号码。
  SIGILL 是执行域故障的常见终点，用它做"同因"推断之前必须先隔离变量。
- **维护了没人走的路径，等于没修。** 对称 wrapper 精心维护了一个多星期、
  每版都自愈/再断言——而构建根本不经过它。修复的第一步永远是确认
  "真实调用路径是哪条"。
- **空壳设计的窟窿会在最深处暴露。** NDK 空壳骗配置期检测的设计没错，
  但要清楚它只兜住了配置期；每一层"从未被执行过的代码路径"都是隐藏的
  破产点，链路打通是逐层兑现欠账的过程。
- **诊断脚本本身要过 bash -n 门禁。** 本条收尾时 AOT_FP 段因复制粘贴
  产生"两个 for 头、一个 done"的语法错误（bash 直接拒绝整个预检脚本），
  单测 dash/bash 语法门禁（bug449 测试组）由此设立：**凡被执行的脚本
  必须可被单测语法检查**。

---

### Bug 451：工具链页假警报——红字 `invalid ELF header`、INPLACE 却全绿、构建照样成功（2026-09-19，alpha.56 修复）

**症状**：真机工具链页（x64 兼容层已启用）显示：

```
IMPELLERC 不可用（AOT 会在 shader 阶段崩）· font-subset 不可用
error while loading shared libraries: .../linux-x64/impellerc: invalid ELF header
```

而同一页面 `GEN_SNAPSHOT / GEN_INPLACE / IMPELLERC_INPLACE` 全部正常，
**且同一状态下真机一键构建端到端成功出 APK**（15.0MB 用户项目，199.1s）。
用户发截图问："这是不是有问题啊？"

**排查**：绿与红并存、构建又不失败——先按"评分探针 vs 真实调用路径"
脱钩去查，两层病灶：

1. **报警来源**：verify 的评分探针还在测**对称位**
   （`linux-arm64/<tool>`，alpha.53 时代旧对称包装）。而 Bug 449 已实证
   构建走**原位**（`linux-x64/<tool>` → `.foa-real`），不走对称位。
   对称位的旧 wrapper 的真身参数烘死指向 `linux-x64/<tool>`——
   Bug 449 原位包装后，该位置变成了 `#!` 开头的 shell 文本（原位=wrapper）。
   探针执行它：qemu + ld.so 加载 shell 文本 →
   `error while loading shared libraries: <自身路径>: invalid ELF header`。
   （invalid ELF header 的语义不是"ELF 坏了"，是"**喂给加载器的不是 ELF**"。）
2. **为什么一直修不掉**：engineWrapScript 的对称段有
   `#! → continue` 幂等短路——"目标已是脚本形态就跳过重建"。
   旧对称 wrapper 恰好是 `#!` 形态，短路永远命中，新包装永远写不进去。
   **形态合法、指向已死**——Bug 445"形态合法但内容被覆盖"的换位复发。

**修复**（alpha.56，qemu_compat.dart）：

1. engineWrapScript 两处对称段（引擎层 + 顶层）改**无条件重建**：
   `linux-arm64/` 里本来就该全是「指向 `.foa-real` 的转发脚本」，
   不存在合法裸 ELF，不需要看形态——与 heal 无条件删同款逻辑。
2. verify 评分改以 **INPLACE 探针为准**（真实调用路径同源）：
   `kv('GEN_INPLACE') ?? kv('GEN_SNAPSHOT')` 模式，GEN/IMPELLERC/
   FONT_SUBSET 三项全改；对称位探测降级为**观测行**
   （"对称位异常（兜底路径，不影响构建；重新应用兼容层可修）"），
   不再参与合格判定。impellerc 失败文案同步改为
   "构建会在 shader 阶段崩"（web 目标不走 AOT 但 shader 照崩，
   文案别把死因说窄）。
3. 补 `FONT_SUBSET_INPLACE` 冒烟；bug449 测试组新增回归用例：
   旧对称 wrapper 指向 `#!` 位 → engineWrap 后必须重建成
   含 `.foa-real` 的新形态（280 测试全绿）。

**教训**：

- **幂等短路的判据不能只看自身形态。** "已是脚本就跳过"遇上
  "脚本但指向已死"会永久卡死：要么校验指向目标的存活，要么
  无条件重建（当目录的合法形态本来就恒定时，无条件重建更简单）。
- **评分探针必须与真实调用路径同源。** 刚实证"构建走原位不走对称"，
  verify 却还在测对称位——可用性报告与实际链路脱钩，报警必然失真。
- **假警报的真害是让人不敢信任何颜色。** 绿（INPLACE 全）+ 红
  （IMPELLERC 报警）+ 构建成功三者并存，用户只能问"这是不是有问题"。
  观测信息（可修的异常）与合格判定（阻断性的失败）必须分层呈现。

---

### Bug 452：日志已打印 `✓ Built ...`，进度条却停在 95%「打包与签名」不动（2026-09-19，alpha.58 修复）

**症状**：真机构建 25 分钟后，日志最后一行已是
`✓ Built build/app/outputs/flutter-apk/app-release.apk (15.0MB)`，
但进度条停在「打包与签名 APK 95%」转圈不走。用户判读为
"卡在最后一步签名"。

**判读**：`✓ Built` 打印在 Gradle 打包+签名**完成之后**——构建本体
已经成功。卡住的是**收尾判定**：flutter 工具偶发 Built 后 hang 不退出
（dart VM 收尾不退出），平台侧 execStream 的 running 恒真 →
BuildRunner._poll 永远等不到退出事件 → `_finish` 不触发 → 不 markDone。

顺带一个好消息藏在同一份日志里：出现了**两次**
`Running Gradle task 'assembleRelease'`——第一次失败 → 指纹采集
命中 BAD → clean + reassert + 重启构建 → 第二次 66.7s 成功。
这是 Bug 445 的 heal 自愈链路**第一次在真机实战按设计工作**。

**修复**（alpha.58，build_runner.dart）：

1. `_appendChunk` 检测 Built 行（`builtMarker`）→ 记录命中时刻
   `_builtAt`，并立即向日志输出
   "✓ Gradle 打包+签名完成，等待 flutter 工具收尾…"——先止住误读；
2. `_poll` 里纯函数 `builtGraceElapsed`（宽限 90s）到期且仍 building →
   强制 `_finish(0)`：走产物定位 + markDone + 成功状态，与自然退出
   完全同一条收尾路径；
3. 单测固化：宽限判定四态（未命中/未到期/到期/常量合理性）。

**教训**：

- **"成功输出"与"进程退出"是两个事件。** 长任务的完成判定不能只
  依赖退出码——日志里的成功标记（Built / BUILD SUCCESS）是更早、
  更稳的事实，值得作为独立信号锚定。
- **进度条停滞时先看日志尾部。** 95% 不是 gradle 的 95%，是插值器
  的 95%；日志已经宣布成功了，UI 就该同步。

---

### Bug 453：通知栏点「Web 预览」通知却跳到 APK 构建页（2026-09-19，alpha.59 修复）

**症状**：预览运行中，用户点通知栏「Web 预览 · my_flutter 运行中」，
打开的却是 APK 构建页。

**根因**：通知由原生前台服务发出，点击回发 Dart 的只有一个
navigate 信号——**不带类别**。Dart 侧 `_openNotifyTarget` 无法区分
这条通知来自构建还是预览，默认进了构建页。

**修复**（alpha.59，零原生改动）：

1. `BuildNotify` 加 `static String lastRoute = 'build'`——原生不传
   类别，Dart 侧按"最近一次启动的任务"分流；
2. `BuildRunner.start` 置 `'build'`、`WebPreviewService.start` 置
   `'preview'`；
3. `_openNotifyTarget`：`lastRoute == 'preview'` 且有项目名且预览
   busy → 进 WebPreviewPage；否则构建页兜底。

**教训**：

- **单活跃通知场景下，"最近启动者"即事实类别。** 构建与预览本就
  被启动互斥挡住并发，静态字段分流零协议成本，不值得为它改原生
  通道加序列化字段。
- 通知是 App 的"门面导航"：每新增一种前台任务类型，回发路由就要
  分叉一次——加任务类型时把 lastRoute 的赋值一并写进 start。

---

### Bug 454：Web 预览永久停在「正在编译…」——DDC 期间没有任何就绪标志，也没有超时兜底（2026-09-19，alpha.60 修复）

**症状**：点「Web 预览」后日志停在

```
Launching lib/main.dart on Web Server in debug mode...
```

进度条一直是「正在编译…」，左上角计时走到 10 分钟仍无内嵌 WebView
出现。用户合理怀疑："是已经 launching 了但没拉起 webview？还是没
构建好？"

**根因（两条叠在一起）**：

1. **假状态**：`WebPreviewService` 判定"编译完成"只看日志里是否出现
   `readyMarkers` 里的 5 个词。DDC 编译期（`Launching...` /
   `Waiting for connection...`）**不输出其中任何一个**——测试里已
   显式断言这两行 `isReadyLine == false`。于是状态机永远卡在
   `starting`。
2. **无兜底**：唯一的终态出口是"进程退出"。只要进程还活着，无论
   跑多久，UI 都只能继续显示「正在编译…」。而 WebView 只在
   `running` 分支构造——**永不加载**。

即："编译中"是一个**没有超时、没有旁路证据**的状态，任何一次
标志词漂移都会让用户对着进度条干等到天荒地老。

**修复**（alpha.60，三件事，无原生改动）：

1. **端口探测作为旁路证据**：新增 `probePort()`，用 `dart:io`
   `HttpClient` 每 3 秒探 `127.0.0.1:8090`（1.5s 连接超时），
   返回 200/404/503 都算"在听"。
   
   > 这里更正手册 02 的一个错误结论：原写"App 侧 HttpClient 探测
   > 不可用"。实际上 Android 的明文流量拦截发生在 **Java 框架层**
   > （`NetworkSecurityPolicy` / OkHttp / WebView），Dart `dart:io`
   > 的 `HttpClient` 走 **NDK 原生 socket**，不受该策略约束——项目
   > 自身的 `sdk_downloader.dart` 用 HttpClient 直连 http 镜像源
   > 就是活证据。
2. **三段裁决** `readyDecision()`：
   - 命中标志词 → `ready`；
   - 未命中但**端口已通** → 继续等宽限期（DDC 可能还没写完产物），
     宽限期（420s）到仍未命中 → **`degrade` 降级放行**；
   - 端口不通 → `waiting`。
   
   降级的设计取向：宁可让用户看到"可能还没编译完的页面"，也不要
   让他对着「正在编译中」干等——**假进度比真空白更伤信任**。
3. **心跳与埋点**：`starting` 期间每 15 秒打一行
   `[heartbeat] 已运行 Xs（端口：通/未通）`；转入 `running` 时打印
   **首次就绪耗时** `firstReadySec`。慢不怕，怕的是"不知道还要多久"。
4. 附带：`startCommand` 末尾加 `--no-pub`（预览前已确保依赖就位，
   省掉一次 pub 解析）；`_appendChunk` 补对 `partial` 行做
   `isReadyLine` 判定（标志词落在没有尾换行的最后一段时会被永久漏判）。

**验证**：`test/web_preview_test.dart` 新增 11 个测试，覆盖三段裁决
（含 420/3/15 常量契约）、进度文案、心跳行、`--no-pub` 回归防护。

**教训**：

- **"进行中"状态必须有超时或旁路证据。** 只靠"解析日志关键字 +
  等进程退出"的终态设计，等于把可用性押在标志词永不漂移上。
- **降级放行优于永久等待。** 拿不到确定性时，给用户一个可能不完美
  的结果 + 明确告知，好过给他一个完美但永远不来的承诺。
- **先验证"能不能探测"再设计探测。** 这次差点因为手册里一句错误
  结论（HttpClient 不可用）而放弃最直接的旁路证据——结论要能被代码
  反例推翻。

---

## 十二、提交 Bug 记录模板

发现新 Bug 并解决后，按以下格式追加到对应分类：

### Bug 455：cloudflared 下载失败——分片下载强制要求 HTTP 206，遇 200 直接换源（2026-09-19，alpha.61 修复）

**症状**：远程接管页点「启动隧道」，卡在「正在下载 cloudflared」，最后报
「下载失败：所有源都不可用」。

**原因**：
`SdkDownloader._downloadSegment` 对分片请求**强制要求 206**：

```dart
if (resp.statusCode != 206) {
  throw DownloadException('服务器不支持 Range（HTTP 200）');
}
```

cloudflared 当时只配了 2 个源（ghfast + GitHub 直链，后者国内不通）。
ghfast 实测对 Range 是回 206 的，但"源数量不足 + 强依赖 206"这个组合
本身脆弱：任何一个中间层（CDN、反代）把 206 降级成 200，整条链就必失败。

**解决**（`lib/toolchain/sdk_downloader.dart`）：

1. **整包兜底**：Range 不可用时退化为单流整包下载。实现上把整包当覆盖
   `[0, expectedSize)` 的一个分片写入 `.p0`，其余分片清空（长度 0 天然
   "已完成"），拼接与 SHA 校验逻辑**无需改动**。
2. **必须由分片 0 执行**：非 0 分片遇到 200 直接静默返回，否则会与并发
   分片互相踩（重复写同一个文件）。分片布局经静态字段
   `_currentSegsHint` / `_currentPartsHint` 传递。
3. **`rafClosed` 标志位**：整包兜底路径需提前释放 raf，`finally` 二次
   close 会抛 `FileSystemException('File closed')` 把成功变失败。
   —— 这个 Bug 是被单元测试抓出来的，不是真机。
4. **扩镜像源**：cloudflared 加到 3 个源。`github.moeyy.xyz` 实测 DNS
   无法解析，**故不纳入**——宁可少一个源，也不要摆一个永远超时、
   白白拖慢竞速的假选项。

**验证**：`test/bug456_range_fallback_test.dart`（3 用例）起**本地真实
HTTP 服务器**返回 200，断言整包兜底能正确落盘并通过 SHA 校验；
再起一个返回 206 的服务器，断言走原分片路径。不靠断言源码文本来"验"。

**出现版本**：alpha.60 及以前
**修复版本**：alpha.61

---

### Bug 456：浅色主题下顶栏与状态栏颜色割裂（2026-09-19，alpha.61 修复）

**症状**：切换到浅色主题后，AppBar 是浅色，但状态栏/导航栏仍是深色，
看起来像"上面被切掉一块"。

**原因**（**三处叠加**，只改一处不会好）：

1. `FoaTheme.light()` 里 `statusBarColor: Colors.transparent`；
2. AppBar 背景也是 transparent → 于是透出 `styles.xml` 里的
   `foa_bg = #101418`（深色窗口背景）；
3. `main.dart` 硬编码了深色 `SystemUiOverlayStyle`，**在任何主题下都生效**。

**关键实证**：用 `javap -p -c` 反编译 Flutter 3.47.4 的
`PlatformPlugin.class`，看到：

```java
if (SDK_INT < 35 && style.statusBarColor != null) window.setStatusBarColor(color);
```

即 **Java 层该传的颜色是传了的**，但 Android 15（SDK_INT≥35）上被
**无条件跳过**。所以光在 Dart 侧改颜色不够，必须加 Kotlin 原生兜底。

**解决**：

- `theme.dart`：新增 `lightSurface = #F5F7F8`，浅色主题的
  `statusBarColor` 改为它（不再 transparent），补
  `systemNavigationBarColor` / `systemNavigationBarIconBrightness`；
  新增 `FoaTheme.overlayFor(Brightness)` 集中一处。
- `main.dart`：启动基线改为跟随平台亮度；`builder` 里加
  `AnnotatedRegion<SystemUiOverlayStyle>` 使主题切换实时跟随。
- `MainActivity.kt`：新增 `applySystemBarColorsForTheme()`，在
  `configureFlutterEngine` 开头调用（API 35+ 兜底）。
- `colors.xml` 新增 `foa_bg_light`；`styles.xml` 浅色侧全部改用它，
  `values-night/styles.xml` 保持 `foa_bg`。

**验证**：`test/bug457_statusbar_theme_test.dart`（12 用例）。其中一条
是**跨文件同源断言**——`#F5F7F8` 这一个值同时存在于 Dart / Kotlin / XML
四处，任何一处漂移就失败。这类"复制粘贴的常量"没有编译器保护，
只能靠测试守。

**出现版本**：alpha.60 及以前
**修复版本**：alpha.61

---

### Bug 457：AI 接管子页面点「开始」跳去了「远程接管」页（2026-09-19，alpha.61 修复）

**症状**：项目工作台「AI 接管」分区里的按钮，点击后跳到另一个页面
（远程接管页），用户在项目上下文里操作到一半被"弹出去"。

**原因**：这个按钮从一开始就是一个**纯跳转**——`_openTakeover()` 直接
`Navigator.push` 到远程接管页。当时的设计假设是"配置隧道要完整页面"，
但实际使用中用户在项目工作台里点它，期望的是**就地开始**。

**解决**（`lib/project/ai_takeover_panel.dart` 重写）：移除跳转，改为
就地交互——`_startInline()` / `_stopInline()` / `_confirmRisk()` /
`_refreshCfState()` 全部在当前分区内完成：开启/停止/续期/复制地址。
标题也从"远程接管"改成 `AI 接管 · <项目名>`，让用户清楚自己在哪一层。

**教训（写进注释了）**：跨页跳转**丢掉的是上下文**——"我在哪个项目"
这个心理锚点。同类问题在代码页的 AI 按钮上做了同样处理（就地切区而非
弹新页）。

**出现版本**：alpha.62 引入
**修复版本**：alpha.61

---

### Bug 458：包名字符串散落在四处——两处规则靠"巧合"对齐（2026-09-19，alpha.62 修复）

**症状**：不是崩溃，是**维护性隐患**。审计请求来自一句很准的问题：
> "包名可以暂时不改，但是你有逻辑是写死的包名路径吗？这样以后维护会不会有问题，
> 应该动态获取比较好。"

全仓扫描后，真实情况是这样的（**大部分本来就是动态的，但有两处是"巧合"**）：

| 位置 | 写法 | 判定 |
| --- | --- | --- |
| Kotlin `fileProviderAuthority` | `get() = "$packageName$SUFFIX"` | ✅ 运行时取，正确 |
| Manifest authority | `${applicationId}.fileprovider` | ✅ Gradle 占位符，正确 |
| Kotlin 全部路径 | 一律 `File(filesDir, ...)` / `cacheDir` | ✅ 没有一处拼 `/data/data/<pkg>` |
| Dart 路径 | 一律从 `EnvInfo.filesDir` / `rootfsPath` 派生 | ✅ 正确 |
| `PROJECTS_REL` 等 | `"rootfs/debian/..."` | ⚠️ 与包名无关（写死的是发行版名 `debian`），非本轮范围 |
| **文件浏览器路径标签** | `return '/data/user/0/<pkg>'` | ❌ **字面量占位符**，直接显示给用户 |
| **空白工程模板** | `PKG="com.example.$NAME"` + 目录 `com/example/$NAME` | ❌ **两处规则靠巧合对齐** |

**两个真问题的细节**：

1. **路径标签是假的**。`file_browser_page.dart` 的 `_envDirLabel()` 里，
   宿主根路径被显示成 `/data/user/0/<pkg>` 这个**字面量**——用户看到
   `<pkg>` 以为是省略号，复制出去粘贴必然扑空。改为从
   `EnvInfo.packageName`（新增，原生 `packageName` 运行时返回）取真值；
   取不到时才降级为占位符。

2. **包名规则的"巧合对齐"**（这条才是真正的隐患）。
   空白工程模板里包名写的是 `com.example.$NAME`，Kotlin 源码目录写的是
   `com/example/$NAME`。当时**恰好**没问题，因为
   `DemoProjectCreator.validateName` 的正则是 `^[a-z][a-z0-9_]*$`，
   **要求首字符是字母**，所以 `$NAME` 永远合法。
   但这是**两个文件里的规则靠巧合对齐**，不是有依赖关系的设计：
   - Dart 侧的 pub 包名**允许**数字开头（`1to2` 合法）；
   - Java 包名的段**不允许**数字开头；
   - 一旦哪天放宽校验（比如为了对齐 pub 的宽松规则），
     就会生成 `package com.example.1to2`，**gradle 直接编译失败**，
     而失败信息埋在容器的 gradle 输出里，用户完全无从下手。

**解决**：

1. `EnvInfo` 增加 `packageName`（原生 `envInfo()` 回 `packageName`，
   运行时真值而非 `BuildConfig.APPLICATION_ID`——后者在
   `applicationIdSuffix` 场景要额外留意）；
   `file_browser_page.dart` 的 `_envDirLabel()` 改用它。
2. 新增 `demoAndroidIdentifier(name)` 作为包名**唯一推导点**：
   `com.example.<name>`，首字符是数字时前置 `a`（`1to2` → `com.example.a1to2`）。
   **只改包名、不改项目名**——项目名同时是目录名和 pub 包名，用户输入什么
   就是什么；只有 Android 侧的 package 声明需要满足 Java 规则。
3. 模板脚本改成 `PKG='__PKG__'` 占位符 + `PKGHEAD`/`PKGLAST` 从包名
   反推目录（`com/example/a1to2`），**不再出现任何 `com/example/$NAME` 字面量**。
4. 脚本末尾加自查：`MainActivity.kt` 路径与包名不符 / 包名未生效 → 直接
   `exit 1`。**构建期才发现在这个场景下等于永远不发现**。

**验证**（`test/blank_project_template_test.dart`，19 项）：

| 断言 | 说明 |
| --- | --- |
| 推导结果在任何输入下都是合法 Java 包名 | 逐段验 `^[A-Za-z][A-Za-z0-9_]*$` |
| `1to2` → `com.example.a1to2` | 核心用例 |
| 渲染后无 `__NAME__`/`__PKG__` 残留 | 占位符替换完整 |
| 代码行不出现 `com/example/` 字面量 | 只查非注释行（注释里举例子不算） |
| `dash -n` 语法检查通过 | 脚本跑在容器 dash 下，真跑一次 |
| 无 bashism（`[[` / `&> ` / `<<<` / `$RANDOM`） | 保持 POSIX sh 兼容 |

配套：真机不需要跑，`dash -n` + 变量展开实测（`PKGHEAD="${PKG%.*}"` →
`com.example`，`PKGLAST` → `a1to2`）即可确认。

**教训**：

- **"暂时没出问题"和"设计上不会出问题"是两件事**。这里三处包名规则
  互不引用，全靠校验函数的严格度兜着——那道防线一旦松动，
  错误就会以"gradle 编译失败"的形式出现在最难排查的位置。
- **字面量占位符 `<pkg>` 出现在用户可见界面里，就是 bug 不是备注**。
  用户分不清"这是省略写法"还是"我该去找这个路径"。
- 审计这类问题的正确姿势是**先分类再动手**：这次 8 处里 6 处本来就对，
  只有 2 处要改。一上来就"全部改成动态"会平白引入回归。

**出现版本**：alpha.21（空白工程模板）起长期存在
**修复版本**：alpha.62

---

### Bug 459：proroot 许可判断在 α.60 与 α.61 得出**相反结论**——"未修改"前提不成立（2026-09-19，alpha.62 定稿）

**症状**：不是崩溃，是**文档自相矛盾**。同一份 `THIRD-PARTY-NOTICES.md`
里，标题写着"候选但未内置"，表格状态栏写着"可选启用"，
`about_info.dart` 写着"默认关闭、本项目不代为分发"——三处口径打架。
用户看到"未内置"会以为功能根本不存在。

**原因**：α.60 与 α.61 对同一份许可作出了**相反判断**，而文档只改了一部分。

| | α.60 判断 | α.61 复核 |
| --- | --- | --- |
| 上游许可原文 | Proprietary，_"Free to use in your projects. **Redistribution of modified binaries is not permitted.**"_ | 同 |
| 关键前提 | 我们内置的是**未修改**的二进制 → 不属于 "modified binaries" → **允许** | ❌ **前提不成立** |
| 结论 | 不内置是**工程判断**（收益小、未验证） | 不内置是**合规必需** |
| 文档口径 | "候选但未内置" | "可选启用（不代分发）" |

**α.61 复核时想通的那一点**：proroot 用 **LD_PRELOAD + 二进制补丁**
替代 proot 的 ptrace，**补丁就是它的实现手段**——上游发布的就是已补丁
形态。我们把它放进 APK，分发的就是"修改过的二进制"（相对 proot 语义
而言），**正好落在禁止条款里**。

**解决**（统一为"可选启用、不代分发"）：

1. `THIRD-PARTY-NOTICES.md`：标题 `候选但未内置` → `可选启用（不代分发）`；
   正文 `不内置二进制的原因` → `不代分发二进制的原因`。
2. `dev-handbook/05-许可证合规.md`：章节重写，**把 α.60→α.61 的
   判断反转过程保留在文档里**（结论变了，理由更要留痕，否则下一个人
   会再翻一遍）。
3. 实现侧改成：用户自行从上游获取 → 系统目录选择器导入 →
   本 App 只调用。**许可允许最终用户使用，限制的是我们代为分发。**
4. **加断言防漂移**（`test/about_info_test.dart` +2 项）：
   - `THIRD-PARTY-NOTICES.md` 不得再出现"候选但未内置"/"不内置二进制"；
   - 必须出现"不随 APK 分发"；
   - proroot 卡片文案必须点明"不代为分发"**和"许可"**——
     说清是许可限制，用户才不会以为"这功能是不是没做完"。

**为什么值得单开一条 Bug**：这不是技术缺陷，是**判断被推翻**。
三次口径不一致（NOTICES 标题 / NOTICES 表格 / about 卡片）本身
就是一个可复现的失效模式：**改结论时只改了"状态"字段，忘了改标题和
叙述性文字**。人工 review 抓不到，因为没有"标准答案"可比对——
只有写成断言才能守住。

**教训**：

- **许可判断要落到"具体动作"上，而不是停在关键词**。"未修改的二进制
  可以再分发"这句话没错，但 proroot 的二进制**本来就是补丁形态**——
  判断要问的是"我要分发的东西，和上游给的形态一样吗"。
- **结论反转时，必须把旧结论一起写进文档**。只写新结论的话，
  下一个人看到旧结论的残留（比如别的文件里的表述）会以为是矛盾，
  又花一遍时间重新推导。
- **"文档里的一句话"也需要断言**。这次三条口径打架，
  是"没有测试会说文档错了"的典型——把关键措辞（"不代分发"、
  "不随 APK 分发"）写成断言后，同类漂移不可能再发生。

**出现版本**：alpha.60（proroot 告知卡首次落地）
**修复版本**：alpha.62

---

### Bug 460：Kotlin 编译期才发现的 `Map<String, Any?>` 类型错——以及它掩盖的"错误文案静默消失"（2026-09-19，alpha.62 修复）

**症状**：

`flutter analyze` 7 条基线全绿、`flutter test` 589 项全过，
但 `./gradlew :app:compileDebugKotlin` 直接编译失败：

```
e: MainActivity.kt:1016:16 Return type mismatch:
   expected 'Map<String, Any>', actual 'Map<String, Any?>'.
e: MainActivity.kt:1058:16 Return type mismatch:
   expected 'Map<String, Any>', actual 'Map<String, Comparable<*>? & Serializable?>'.
```

**原因**：两层，第二层比第一层严重得多。

**第一层（类型）**：`prorootInstall()` / `prorootProbe()` 声明返回
`Map<String, Any>`，但内部 `mapOf(...)` 里 `"error" to <可空表达式>` ——
成功时是 `null`、失败时是 `String`。Kotlin 把整个 map 推成
`Map<String, Any?>`，而 `Map` 的值在 `out` 位置是**协变**的：
`Map<String, Any?>` 允许空值，赋给承诺"值非空"的 `Map<String, Any>`
就是打破承诺，Kotlin 直接拒绝。

**第二层（语义，真问题）**：`prorootProbe()` 里有一行

```kotlin
if (built.cmd == null) return built.error!!
```

`built` 是 `ProotCmd`，它的 `error` 字段装的是 **`fail()` 的形状**
（键 `exitCode`/`stdout`/`stderr`），而 Dart 侧
`ProrootProbeResult.fromMap` 读的是 **`m['error']`**。也就是说：
proroot 命令构造失败时，返回的 map 里**根本没有 `error` 键**，
Dart 拿到的是一个只有 `exitCode`/`stdout`/`stderr` 的 map →
`error` 恒为 `null` → UI 只能显示兜底文案。

这个缺陷**编译不报错、analyze 不报错、单测不跑就发现不了**，
只在真机上表现为"点了没反应，也没说为什么"。

> 值得记一笔的是：这个类型错误**帮我们逮到了一个语义错误**。
> 如果当初写的是 `Map<String, Any?>`，它会安安静静地编译通过，
> 然后把错误文案吞掉——直到用户来报"proroot 装不上，但没告诉我为什么"。

**解决**：

> 这次修了**两轮**才过，过程本身有信息量，一并记下。

**第一轮**（修掉最初的 2 个 e:）：

1. 新增 `prorootFail(code, message)`：**proroot 专用**的失败构造器，
   产出 `mapOf("ok" to false, "error" to message, "exitCode" to code)`。
2. `prorootStatus` / `prorootInstall` / `prorootRemove` / `prorootProbe`
   四处签名改 `Map<String, Any?>`，`mapOf` 显式写 `mapOf<String, Any?>(...)`。
3. `buildProrootCmd()` 里两处 `fail(...)` 改 `prorootFail(...)`。
4. `prorootProbe()` 里 `return built.error!!` 改了。

**第二轮**（第一轮的改动**连锁**出 3 个新 e:）——这是本题最有价值的部分：

```
e: MainActivity.kt:1085:38 Argument type mismatch:
   actual type is 'Any', but 'String' was expected.
e: MainActivity.kt:1167:17 Argument type mismatch:
   actual type is 'Map<String, Any?>', but 'Map<String, Any>?' was expected.
e: MainActivity.kt:1180:35 同上
```

原因是我只改了 `prorootFail` 的**返回类型**，没改
`ProotCmd.error` 的**字段类型**——它还是 `Map<String, Any>?`。
于是 `prorootFail(...)` 的返回值塞不进 `ProotCmd`。
Kotlin 顺着这条线把**所有**依赖 `ProotCmd.error` 的地方都报了出来：

| 位置 | 报错 | 说明 |
| --- | --- | --- |
| 1085 | `Any` 不是 `String` | `built.error` 从 `Map<String,Any>?` 松成 `Map<String,Any?>?` 后，`?: "兜底"` 的**推导类型变成 `Any`** |
| 1167 / 1180 | `Map<String,Any?>` 塞不进 `Map<String,Any>?` | `prorootFail` 的返回值 vs `ProotCmd.error` 的旧类型 |

对应修法：

- `ProotCmd` 加 `?`：`val error: Map<String, Any?>?`
- 1085 处改成**显式取值**而不是整块 map 当字符串用：
  `built.error?.get("error") as? String ?: "proroot 命令构造失败"`
- 剩下三处 `return built.error!!`（`exec` / `execStream` / `ptyStart`）
  → `return built.error ?: fail(-500, "命令构造失败（无错误详情）")`

> **为什么保留 `built.error!!` 的"透传"语义**：这三个方法走的是
> **proot 路径**（`buildProotCmd`），它给的是 `fail()` 形状，
> 而这三个方法的 Dart 消费者（`ProotResult`）正好读 `stderr`——
> 形状是对上的，透传没问题。真正的问题只在于 `!!` 会在
> "cmd 为 null 但 error 也为 null"（不该发生）时抛 NPE。

**第三轮**（第二轮的改动**再连锁**出 3 个新 e:）——债开始收利息了：

```
e: MainActivity.kt:1226:39 Return type mismatch: expected 'Map<String, Any>', actual 'Map<String, Any?>'.   (exec)
e: MainActivity.kt:1410:39 同上                                                                              (execStream)
e: MainActivity.kt:1525:44 同上                                                                              (ptyStart)
```

`ProotCmd.error` 松成 `Map<String,Any?>?` 后，`exec` / `execStream` /
`ptyStart` 里的 `return built.error ?: fail(...)` 返回的就成了
`Map<String,Any?>`，而这**三个方法自己的返回类型还是 `Map<String, Any>`**。
于是同样的事情发生第二次——类型放宽沿着调用链继续向上传染。

修法：把这三个方法的返回类型也放宽为 `Map<String, Any?>`（其中
`ptyStart` 是**单行签名**，`exec`/`execStream` 是**多行签名**，
批量替换时注意形状不一样）。

> **这里踩了个小坑**：批量改签名时我按"多行签名形状"统一匹配，
> 结果 `ptyStart` 的单行签名匹配不上，脚本在第一处就 assert 失败。
> 好在脚本是**先校验、后写入**，异常直接中断，**文件没被改坏**——
> 所以第二处 `if (built.cmd == null) return built.error!!` 也还原成了
> 带 `!!` 的原样（那三处 `?: fail(...)` 兜底本就是多余的，
> 因为 cmd 为 null 时 error 必然非 null）。

**一句话总结这次的连锁反应**：改一个**跨类型共用的构造器**，
它会沿着"字段类型 → 所有消费者"这条链把隐藏的不一致全炸出来。
这不是坏事——**每一轮 e: 都在指出一个真实的不一致**，
一共炸出三轮、8 个 e:，本质上都是"两种形状共用一个字段"这笔债。
5. `ProotCmd` 的文档注释写清 **`error` 字段装两种形状的 map** 这件事：
   `buildProotCmd()` 走 `fail`（`stderr`），`buildProrootCmd()` 走
   `prorootFail`（`error`），Dart 侧消费者各自知道该读哪个键。

**验证**：

- `./gradlew :app:compileDebugKotlin` 通过（BUILD 无 error 输出）。
- `platform/android/MainActivity.kt` 同步（diff 为空）。
- `test/proroot_integration_test.dart` 新增 4 项「桥接键名契约」断言：
  ①`prorootFail` 存在且 map 含 `"error" to message`；
  ②`ProrootProbeResult.fromMap` 读的 5 个键在 `prorootProbe` 里都有产出；
  ③`ProrootInstallResult.fromMap` 读的 5 个键在 `prorootInstall` 里都有产出；
  ④四处含可空值的签名必须显式 `Any?`。共 **27/27 通过**。
- `flutter test` 全量 **593 项全绿**（改类型没有牵连 Dart 侧）。

**教训**：

- **`flutter analyze` 通过 ≠ Kotlin 能编译**。analyze 只看 Dart，
  Kotlin 的编译期类型检查只有 gradle 会做。改过 `MainActivity.kt` /
  `PtySession.kt` 就必须跑 `:app:compileDebugKotlin`——这条已进 SKILL 第 2 步。
- **跨语言的 map 键名契约是最脆的一类接口**。Kotlin 返回 map、
  Dart 用 `fromMap` 读，两侧都是**字符串**，编译器帮不上任何忙。
  这类接口必须配静态断言测试（本项目已有先例：Dart↔Kotlin 协议一致）。
- **改共用构造器要预期"连锁报错"，那是资产不是麻烦**。`prorootFail`
  的返回类型一变，`ProotCmd.error` 的类型、`exec`/`execStream`/`ptyStart`
  的返回类型全被 K2 编译器重新审了一遍，一共炸出**三轮、8 个 e:**。
  **每一处 e: 都在指出一个真实的不一致**，别急着用 `!!` 或强制转换压回去。
- **批量改签名要区分单行 / 多行形状**。`ptyStart` 是一行写完的，
  `exec`/`execStream` 是参数换行的——按一种形状写正则必然漏。
  **脚本要"先校验、后写入"**：这次 assert 失败时文件完好无损，
  靠的就是先全量检查再统一落盘，而不是边匹配边改。
- **`a ?: b` 的类型推导会被左值"拖宽"**。`built.error` 从
  `Map<String,Any>?` 变成 `Map<String,Any?>?` 后，`built.error ?: "字符串"`
  的推导类型成了 `Any` 而不是 `String`——因为 Kotlin 要同时容纳
  map 和 string 两种可能。**当 `?:` 右边是另一种类型时，往往说明
  你其实想从左边"取一个字段"**，而不是整个值当字符串用。
- **类型错误未必是坏事，要追它暴露了什么**。最初的 `Map<String, Any>`
  报错本身五分钟能修，但顺着它查下去才发现"错误文案在桥上消失"——
  那才是真正会让用户困惑的问题。**别只把编译错误消掉就完事**。
- **两套形状共用一个字段是设计债**。`ProotCmd.error` 现在装两种 map，
  已经用文档注释标注了风险；将来若要彻底了结，应拆成
  `ProotCmd` / `ProrootCmd` 两个类型，让编译期就能区分。
  **这次三个 e: 就是这笔债的利息**。

**出现版本**：alpha.62（proroot 可用化那一批）
**修复版本**：alpha.62

---

### Bug 461：`Gradle build daemon disappeared unexpectedly`——"机器有 123GB 内存"不等于"我能用 123GB"（2026-09-19，alpha.62 出包修复）

**症状**：

`flutter build apk --release --target-platform=android-arm64` 跑到
**2474.7s（约 41 分钟）**后失败：

```
----- Last 20 lines from daemon log file - daemon-362581.out.log -----
... Font asset "MaterialIcons-Regular.otf" was tree-shaken,
    reducing it from 1645184 to 20192 bytes (98.8% reduction).
----- End of the daemon log -----

FAILURE: Build failed with an exception.

* What went wrong:
Gradle build daemon disappeared unexpectedly (it may have been killed or may have crashed)

Running Gradle task 'assembleRelease'...    2474.7s
Gradle task assembleRelease failed with exit code 1
```

日志到"字体 tree-shake"就断了——也就是 **AOT 编译已完成、R8/dex 阶段刚开始**
的位置。

**原因**：

`android/gradle.properties` 里的堆配置是**按 123GB 物理内存的大机器**定的：

```properties
org.gradle.jvmargs=-Xmx6g -XX:MaxMetaspaceSize=2g
kotlin.daemon.jvmargs=-Xmx3g
```

但本沙箱是**容器**，cgroup 上限只有 8 GiB：

```
$ cat /sys/fs/cgroup/memory.max
8589934592          # 8 GiB
$ free -m
               total  used   free  ...
Mem:          126277 30008  9543          # ← 这个数字会误导人
```

`free -m` 报的 `total` 是**宿主机**的 126GB，而进程实际被限制在 8 GiB。
6g + 3g + 元空间/线程栈/原生缓冲早已超顶 → R8 阶段内存冲高时被
cgroup OOM killer 击杀。

> **这个症状有两个成因，处置完全相反**：
> | 成因 | 判据 | 处置 |
> | --- | --- | --- |
> | JVM 自身堆耗尽 | `free -m` 有**大量 available** 却仍消失 | **加**堆 |
> | cgroup OOM 击杀 | `cat /sys/fs/cgroup/memory.max` 已触顶 | **减**堆 |
>
> 前一轮（2026-09-19 早些时候）正是前者——当时按 1.5g 的旧值在大机器上
> 跑 release，属"堆不够"，于是被改成 6g/3g；**结果这次改成"配置超过了
> 容器上限"**。两次症状字符串一模一样，修法却相反。

**解决**：

按公式重定：`gradle 堆 + kotlin 堆 + 1.5g(元空间/线程/原生) < cgroup 上限`

```properties
# 本沙箱 cgroup 8GiB → 4g + 2g + 1.5g ≈ 7.5g，留 0.5g 余量
org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g -XX:+HeapDumpOnOutOfMemoryError
kotlin.daemon.jvmargs=-Xmx2g
```

重试前先释放内存（关键：**不要清 `build/`**）：

```bash
cd android && ./gradlew --stop && pkill -f KotlinCompileDaemon
cat /sys/fs/cgroup/memory.current   # 确认降下来（实测 6.0GiB → 2.24GiB）
```

**验证**：

- 第三次构建通过，`assembleRelease` **1049.0s**，产出
  `dist/FOA-v0.1.0-alpha.62-arm64.apk`（88,176,033 B）。
- 四件套：`native-code: arm64-v8a`（仅此一个）/ `versionName='0.1.0-alpha.62'`
  + `versionCode='62'` + `targetSdkVersion='28'` / `apksigner verify` 通过 /
  无 proroot 二进制。另 `unzip -t` 无错、dex 仅 1 个 771KB 且第三方残留为空。
- `platform/android/gradle.properties` 同步（diff 为空）。

**⚠️ 本轮其实失败了两次，中间那次换了报错 → 见 Bug 462**：

- 第 1 次（2474s）：`daemon disappeared` → 误判为"堆不够"，1.5g 改 **6g/3g**
- 第 2 次（1089.9s）：`compileReleaseArtProfile > Failed requirement.`
- 第 3 次（1049.0s）：6g/3g **下调**为 4g/2g → 通过

**即第 1 次的诊断下错了药**：6g/3g 本身超过 8GiB cgroup 上限。

**教训**：

- **容器里永远以 cgroup 为准，别看 `free -m`**。`free` 读的是宿主机视图，
  与进程实际可用内存可以差一个数量级（本轮 126GB vs 8GiB）。
- **同一个报错文案可能是相反的修法**。"daemon disappeared" 既可能是堆太小、
  也可能是堆配置超过容器上限——**先查上限，再决定加还是减**，
  靠症状关键词条件反射改数字会来回横跳（本轮就横跳了一次）。
- **失败位置能定位成因**。卡在 R8/dex（AOT 之后）= 打包期内存峰值；
  卡在配置期 = 依赖解析/网络。**AOT 已过就排除 Dart 侧**。
- **重试前先想"哪些产物不用重做"**。`build/` 里 AOT 的 `app.so`、
  Kotlin 的 class 都还在，所以"停下来调堆再重试"只要几分钟（R8 阶段），
  而清 `build/` 重来要再花 41 分钟。**失败时保留现场比"重来干净"更值钱。**

**出现版本**：alpha.62（出包阶段）
**修复版本**：alpha.62

---

### Bug 462：`compileReleaseArtProfile > Failed requirement.`——上一轮被击杀留下的半成品中间态（2026-09-19，alpha.62 出包自愈）

**症状**：

Bug 461 第一次失败（daemon 被击杀）后，把堆从 1.5g 调到 6g/3g 重跑，
**换了报错**：

```
FAILURE: Build failed with an exception.

* What went wrong:
Execution failed for task ':app:compileReleaseArtProfile'.
> A failure occurred while executing
  com.android.build.gradle.internal.tasks.CompileArtProfileTask$CompileArtProfileWorkAction
   > Failed requirement.

Running Gradle task 'assembleRelease'...    1089.9s
Gradle task assembleRelease failed with exit code 1
```

注意 `Failed requirement.` 这句是 Guava `Preconditions.checkState` 的
**无信息量断言**——AGP 内部用它表达"某个我以为成立的前提不成立"，
不带任何上下文。`--stacktrace` 也拿不到更多信息。

**原因**：

**不是代码错误，是脏中间态。** 判据来自一个反证实验：

```bash
./gradlew :app:compileReleaseArtProfile --stacktrace
# → 42 分钟后「无输出」（grep 无匹配 = 无 Failed requirement）
# → 即：同一个任务单独跑是**通过的**
```

同一个任务、同一份源码，单独跑能过而串在 `assembleRelease` 里报错，
说明它读到的中间产物不一致——这些产物是**上一轮被 OOM killer 击杀时
写到一半留下的**。AGP 的 ArtProfile 任务要合并
`merged_art_profile` / `combined_art_profile` / `binary_art_profile` 等多级
中间态（见 `build/app/intermediates/art_profile/` 下的 6 个子目录），
被杀进程中开会留下一组自相矛盾的文件，`checkState` 正好撞上。

**解决**：

**不需要任何"修复动作"**——重新触发一次让任务重算即可。本次流程：

```bash
# 1) 先用反证确认"不是代码错"：单独重跑那个任务
cd android && ./gradlew :app:compileReleaseArtProfile --stacktrace
#    无输出 = 通过 → 排除代码问题，问题在中间态

# 2) 释放 daemon 内存（Bug 461 的修法），再跑完整构建
./gradlew --stop && pkill -f KotlinCompileDaemon
cat /sys/fs/cgroup/memory.current

# 3) 重跑 assembleRelease
cd .. && flutter build apk --release --target-platform=android-arm64
# → 1049.0s ✓ Built
```

> ⚠️ **别急着 `./gradlew clean`**。清 `build/` 能治好这类脏状态，
> 但代价是重跑 AOT（41 分钟里的大头）。本题的正确做法是
> **先做反证实验判断"是不是确定性失败"**，再决定动手范围——
> 本次确认非确定性后，重跑一次就过，一分钟额外的清理成本都没花。

**验证**：

- `:app:compileReleaseArtProfile` 单独跑通过；完整 `assembleRelease`
  重跑 **1049.0s 成功**。
- 该任务的全部 6 个中间目录均正常再生成（`r8_art_profile` /
  `binary_art_profile` / `binary_art_profile_metadata` /
  `combined_art_profile` / `dex_metadata_directory` / `merged_art_profile`）。

**教训**：

| 要点 | 说明 |
| --- | --- |
| **无信息量断言要当"状态问题"读** | `Failed requirement.`、`checkState failed` 这类 Guava 断言几乎不指向源码 bug，优先怀疑输入/中间态 |
| **"单独跑通过"是最便宜的反证** | 一条命令就能把"确定性代码错"和"非确定性状态错"分开，省下盲目 `clean` 的 41 分钟 |
| **被杀进程会留半成品** | 上游任务是 OOM 击杀时，下游任务可能报**完全无关**的错——排查要先回顾"前面是不是死过一次" |
| **别用 `clean` 当第一手段** | `clean` 永远"有效"，所以它掩盖诊断；**先判断确定性，再决定清理范围** |

**出现版本**：alpha.62（出包阶段，Bug 461 的次生问题）
**修复版本**：alpha.62

---

### Bug 463（元）：把"实测通过"写早了——错误经验比没有经验更危险（2026-09-19，流程类）

**症状**：

本轮出包过程中，在**构建还没跑完**的时候，就往
`SKILL.md` 的实测记录里写下了这样一段结论：

> 改 `-Xmx6g -XX:MaxMetaspaceSize=2g` + `kotlin.daemon.jvmargs=-Xmx3g`
> 后**一次通过**（18分20秒，比失败的 41 分钟还快）。

**实际结果**：那个配置在第 2 轮就失败了（Bug 462），第 3 轮把堆
**下调**到 4g/2g 才通过。也就是说：**这句"实测通过"是错的**。

**危害**：这比"没写"严重得多。

- 读的人（包括几个月后的自己）会**直接照抄 6g/3g**，
  而它正是超出 8GiB cgroup 上限、会被 OOM killer 击杀的那组值；
- 一旦踩坑，人会先怀疑代码、怀疑缓存，**最后才怀疑"文档里的实测值"**——
  因为"实测通过"这四个字暗示了证据强度，而它实际只是个**进行中的猜测**。

**解决**：

出包完成后回改该段，并把整轮的**三次**构建如实写出：
第 1 次 2474s 失败 / 第 2 次 1089.9s 失败 / 第 3 次 1049.0s 通过，
同时点明"第 1 次的诊断下错了药"。

**教训**：

- **区分"推测"和"实测"的措辞**。没跑完就写 `预计` / `待验证`，
  别写 `实测通过` / `一次通过` / `已确认`。**措辞本身就是证据强度的承诺。**
- **失败链比成功结论更有价值**。只写最终通过值（4g/2g），
  下一个人看到 8GiB 机器可能又想"是不是该调大点"；写出"6g 曾把它跑挂"
  才是真正拦住这次错误的护栏。
- **别在长任务等待期写结论**。等待时手里只有"当前判断"，
  而长任务恰恰是最容易推翻这个判断的场景（本轮就是）。
  等待期适合写**过程记录**（命令、判据、反证实验），不适合写**结论**。
- **本条的元教训**：文档漂移不只会发生在代码注释里（见 Bug 459
  的 proroot 许可口径），**也会发生在"实测记录"里**——
  而后者因为有"实测"二字，更不容易被质疑。**结论一旦落盘就会获得权威性**，
  所以落盘前要确认它真的来自跑完的证据。

**出现版本**：alpha.62（流程类，非代码）
**修复版本**：alpha.62（回改 SKILL.md 实测段）

---

### Bug 464：顶栏与状态栏颜色仍不同步——Kotlin 兜底读错了"主题"（2026-09-20，alpha.63 修复）

**症状**：Bug 457 修过一轮（浅色主题下浅色顶栏 + 深色状态栏），但用户仍报
"顶栏与状态栏颜色不同步"。特点是**只在手动切主题后出现**，重启 App 反而正常。

**原因**：Bug 457 的修复本身是对的，但漏了一个前提——Kotlin 兜底
`applySystemBarColorsForTheme()` 读的是**系统**深色标志：

```kotlin
val night = (resources.configuration.uiMode and UI_MODE_NIGHT_MASK) == UI_MODE_NIGHT_YES
```

而 App 主题由 Dart `ThemeController` 独立控制。两者可以不一致：

| 场景 | 系统 uiMode | App 主题 | Bug 457 修复后的结果 |
|---|---|---|---|
| 系统深色 + App 跟系统 | 深 | 深 | ✅ 正常 |
| 系统深色 + **App 手动切浅色** | 深 | 浅 | ❌ 状态栏按深色画 |
| 系统浅色 + **App 手动切深色** | 浅 | 深 | ❌ 状态栏按浅色画 |

后者只在切换瞬间暴露：`ThemeController` 变了 → Dart 侧 `AnnotatedRegion`
下发新 `systemOverlayStyle` → 但 Android 15+ 引擎**跳过**运行时设色
（Bug 410 已实证）→ 系统栏停留在启动时按系统值设的那一版 → 割裂。

**为什么 Bug 457 没发现**：它的验证是在"系统主题 = App 主题"的前提下做的
（默认都是深色），恰好落在唯一正常的那一格。**测试覆盖的是最不容易出错的分支。**

**解决**（`lib/main.dart` + `MainActivity.kt` + `lib/env/proot_bridge.dart`）：

1. **新增 Dart→Kotlin 同步通道** `syncSystemBarTheme(dark: bool)`：
   由 Dart 把**真实亮度**推给原生，原生据此设色——不再靠原生自己猜。
2. **Kotlin 拆出带参函数** `applySystemBarColors(dark: Boolean)`：
   `applySystemBarColorsForTheme()` 保留（冷启动 Dart 未就绪时的兜底，
   此时读系统值是合理的），但主题切换走带参版本。
3. **唯一推点**：`main.dart` 的 `MaterialApp.builder`——它每次主题变化都
   重建，且此处已算出 `dark`。用 `addPostFrameCallback` 推，避免 build
   期间触发平台调用。
4. **失败静默**：`syncSystemBarTheme` 内部 catch 掉异常。系统栏设色是
   纯装饰性操作，不该因个别 ROM 没实现而中断主题切换。

**验证**：`test/bug464_theme_and_download_test.dart` 共 8 条——断言
Kotlin 有 `syncSystemBarTheme` 分支、`applySystemBarColors(dark)` 签名、
Dart/Kotlin 两侧颜色字面量同源（`0xFF101418` / `0xFFF5F7F8`）、
冷启动兜底未丢。

**教训**：**"兜底"必须在所有降级路径上都成立**。Bug 457 加 Kotlin 兜底时
只考虑了"引擎不设色"，没考虑"原生读不到 App 的真实主题"——于是兜底本身
成了新的错误来源。加兜底时要问一句：**它依据的信息从哪来，可靠吗？**

**出现版本**：alpha.61 – alpha.62
**修复版本**：alpha.63

---

### Bug 465：434 处硬编码颜色——主题切换只切了一半（2026-09-20，alpha.63 修复）

**症状**：切到浅色主题后，部分控件的文字/底色对比度不对：警告框亮得刺眼、
次要说明文字发灰到看不清。不是所有控件都有问题——**只有硬编码颜色的那些**。

**原因**：全项目散落 434 处硬编码颜色，绝大多数是**按深色主题调的**：

| 模式 | 处数 | 问题 |
|---|---|---|
| `Colors.grey.shade500` | 71 | 深色下偏亮、浅色下偏暗，两头不讨好 |
| `Colors.grey.shade600` | 37 | 同上 |
| `Color(0xFF3DDC84)` | 61 | 种子绿，两主题一致，**无害** |
| `Color(0xFFFF7A7A)` | 57 | 深色下的红，浅底上对比度不足 |
| `Color(0xFFFFB74D)` | 17 | 深色下的橙，浅底上对比度不足 |
| `Colors.orange.shade50/200/800/900` | 6 | **最严重**：`shade50` 是近白底，深色主题下是一块刺眼亮橙 |

`ThemeData` 只影响用 `Theme.of(context)` 取色的控件；硬编码的字面量**完全
绕过主题**——这就是"部分控件不同步"的来源。

**解决**（`lib/core/theme.dart` 新增语义色层）：

```dart
class FoaColors {
  static FoaColors of(BuildContext context);
  Color get muted;            // 次要文字（原 grey.shade500/600）
  Color get success;          // 成功（种子绿）
  Color get warning;          // 警告（浅色下压深）
  Color get danger;           // 危险（浅色下压深）
  Color get warningContainer; // 警告底（原 orange.shade50）
  Color get warningBorder;
  Color get codeBg;           // 日志/代码块底（原 black@25%）
}
```

替换 108 处（`grey.shade500` 71 + `grey.shade600` 37），外加 proroot 卡片的
全部橙色阶。**`Color(0xFF3DDC84)` 未动**——种子绿在两主题下都是设计意图，
不属"不同步"。

**批量替换踩的坑**：脚本插入 `import` 时用了 `'$rel'` 单引号字符串，
heredoc 把 `${rel}` 展开成了空 → 生成 12 个 `import '$rel';`（非法 URI）。
**教训：用 shell heredoc 生成 Dart 代码时，`$` 必须转义为 `\$`，或改用 Python
的 f-string 拼接。** analyze 一次性报出来，修起来不难，但要是没跑 analyze
就出包，会得到 12 个编译错误。

**验证**：新增 2 条"清扫型"测试——遍历 `lib/`（排除 `theme.dart`），断言
不再出现 `Colors.grey.shade500/600` 与 `Colors.orange.shade50/200`。
这类测试防的是**回归**：以后谁再写硬编码，测试立刻红。

**出现版本**：alpha.31 起逐步累积
**修复版本**：alpha.63

---

### Bug 466：cloudflared 下载失败无法定位——失败原因在源头被吞掉（2026-09-20，alpha.63 修复）

**症状**：用户反复报"cloudflared 下载不了"，但开发机上几个镜像全通，
本地复现不了。UI 只给一句「所有镜像源探测失败（网络不通或超时）」。

**原因**：`SdkDownloader._probe` 把所有异常一律吞成"不可用"：

```dart
} catch (_) {
  return (m, null);   // ← DNS 失败、TLS 失败、超时、403，全部变成"null"
}
```

于是 `pickFastest` 只能抛"全失败"，**用户和我们都拿不到任何线索**：
是 DNS 没解析？TLS 被中断？还是超时？三者处置方式完全不同。

**根因之外，还查出两件实事**：

**(a) 镜像会截断，且返回 200/206 不报错。**
实测 `ghproxy.net` 完整下载 37,466,252B 的文件，**两次都中途断流**：

| 次 | 收到字节 | 结果 |
|---|---|---|
| 1 | 9,376,643 | 恰好一个分片大小 |
| 2 | 6,399,787 | 与上次不同 |

两次 HTTP 状态码均正常，**截断点还不一样**——说明是该镜像系统性丢连接，
不是固定的尺寸问题。`cmp` 比对确认内容不完整：

```
cmp: EOF on /tmp/cf-test2 after byte 9376643
```

对照：`ghfast.top` 同一文件连测两次，都是完整 37,466,252B、
`sha256 = 3d97437c…faa3` 稳定一致。**所以镜像清单里 ghfast 排第一是对的。**

**这就是"下载失败"最可能的真身**——不是连不上，是**下到一半断了还被当成成功**。

**(b) 此前 cloudflared 没有内容校验**，只比字节数。截断时字节数不符能拦住，
但"字节数对、内容坏"（镜像错误页、CDN 半截缓存）会一路装到容器里，
直到 `--version` 跑不起来才报——报的还是"架构不匹配"，误导性极强。

**解决**（`lib/toolchain/sdk_downloader.dart` + `lib/mcp/cloudflared_install.dart`）：

1. **`MirrorProbe` 留证**：新增类型记录每个镜像的 `ok` / `elapsed` / `error`，
   区分 `SocketException`（DNS/网络）、`HandshakeException`（TLS）、
   `TimeoutException`（超时）、`HTTP xxx`（状态码）。`diagnose()` 返回逐源明细。
2. **cloudflared 加 SHA-256 校验**：在落位**之前**校验内容，值经
   ghfast 与 ghproxy.net 两镜像交叉下载比对。
3. **错误文案带诊断**：下载失败时自动跑一次逐源探测并附在错误里。
4. **UI 加「下载源诊断」按钮**：一键展示每个源的具体状态，可复制。
   并告诉用户怎么读（`Failed host lookup` → DNS；`超时` → 换网络）。
5. **镜像源 3 → 4**：补 `gh-proxy.com`。

**为什么不能靠"再加一个镜像"解决**：开发机上三源全通，说明失败是**用户网络的
点对点可达性问题**。这类问题无法靠堆镜像根治，只能 (a) 多留几条路，
(b) 把原因暴露给用户，让他能判断该换 DNS 还是换网络。

**验证**：新增 7 条契约测试，含一条**真跑 DNS 失败**的用例——
`diagnose` 传入不存在的主机，断言返回 `ok=false` 且 `error` 非空
（旧实现下这里会是 `null`，测不出来）。

**出现版本**：alpha.60 起
**修复版本**：alpha.63（下载与诊断），镜像侧断流问题非本项目可控

---

### Bug 467：proroot 只能手动导入——补一键从 GitHub 拉取（2026-09-20，alpha.63 新增）

**症状**（需求，非缺陷）：proroot 卡片只有「导入」按钮，走系统目录选择器。
用户得自己去 GitHub 翻 release、下载、解压成一目录、再选目录——四步手工操作。

**约束（决定了实现方式）**：

1. **专有许可**："Proprietary. Free to use in your projects. **Redistribution
   of modified binaries is not permitted.**" → 可以**运行时原样下载**到用户
   设备（free to use），但不能改写/重打包/随 APK 分发。
2. **GitHub API 有速率限制**：`api.github.com` 匿名每小时 60 次、按 IP 计。
   手机常走共享出口 IP，随时可能 403（实测已被限流）。
3. **5 个 .so 必须同目录**：启动器按 `/proc/self/exe` 的 dirname 找另外 4 个。

**解决**（新增 `lib/mcp/proroot_download.dart`）：

- **走 `raw.githubusercontent.com`**，绕开 API 限速。raw 域不计数。
- **钉死文件清单**：5 个文件的名字/字节数/SHA-256 全写死在
  `ProrootOption.soAssets`。不动态发现——proroot 源码未公开，动态发现意味着
  "上游推什么就装什么"，无法审计变化。钉死后上游一改，校验就失败并明确报错。
- **逐个 sha256 校验**：值取自 2026-09-20 实测，**并与 GitHub contents API
  返回的 git blob sha1 交叉验证一致**（`git hash-object` 比对，5 个全中）。
- **暂存目录在 rootfs 内**（`${rootfsPath}/opt/proroot-dl`）：与最终落位
  同卷，且容器能 `chmod`（宿主 filesDir 没有可执行位）。
- **复用原生落位**：新增 Kotlin 方法 `prorootInstallFromDir`，内部直接调
  原有的 `prorootInstall(srcDirPath)`——"导入"与"下载"两条路最终汇到同一段
  落位逻辑，行为不会分叉。
- **失败保留暂存**：校验失败时**不清**暂存目录，保留证据供排查。成功才清。

**为什么保留「导入」按钮**：一键下载对"什么都没准备"的用户省事；选择器对
"已自己下好文件"的用户更灵活（比如想用测试版）。两条路并存，不互相替代。

**验证**：新增 6 条契约测试——资产清单与 `ProrootOption.soFiles` 同名同数、
URL 走 raw 不走 api、每文件多镜像、Kotlin 复用 `prorootInstall`、
暂存目录在 rootfs 内。

**出现版本**：alpha.61（仅有手动导入）
**修复版本**：alpha.63（新增一键下载）

---

### Bug 468（元）：Bug 440 的模板门禁在一轮里抓到我两次（2026-09-20，alpha.63）

**现象**：本轮改动 Kotlin `MainActivity.kt` 后跑测试，
`proroot_integration_test.dart` 的「平台模板双写（Bug 440 门禁）」
**两次**报「模板与生成目录逐字节一致」失败——两次都是我只改了构建目录、
忘了 `cp` 回 `platform/android/MainActivity.kt`。

**为什么这是"好事"**：Bug 440 的教训是"`platform/` 模板不是构建输入——
它落后了不会报错，只会让新工程脚手架缺功能（269 行 PTY 代码一个月没进过
构建目录）"。这条门禁**精确地**在每次将要漂移时拦住了我。它抓到我两次，
说明它有效，而不是说明它碍事。

**流程教训**：改 `android/.../MainActivity.kt` 后，**必须**同步模板。
建议直接跑：

```bash
cp android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt \
   platform/android/MainActivity.kt
```

然后 `flutter test`——失败即说明忘了同步（门禁会告诉你）。

**一个改进建议（未实施）**：可以加个 `tools/sync_platform.sh` 或在
`check_env.sh` 里加一行 diff 检查，把"记得同步"从人的自觉变成脚本的职责。
本轮未做，记在这里备选。

**出现版本**：—（流程类）
**修复版本**：—

---

### Bug 469：release 构建 49 分钟后 daemon 静默消失——三个 JVM 的堆预算相加就已等于 cgroup 上限（2026-09-20，alpha.63 修复）

**症状**：

```
FAILURE: Build failed with an exception.
* What went wrong:
Gradle build daemon disappeared unexpectedly (it may have been killed or may have crashed)
Running Gradle task 'assembleRelease'...  2950.0s
Gradle task assembleRelease failed with exit code 1
```

跑了 **49 分钟**（2950s，远超 alpha.62 的 17-18 分钟基线）才死，
死在 **dex/R8 阶段**（无任何 `*.dex` 中间产物落盘）。

**这是第三版堆配置踩的同一个坑**，前三版全部靠"估算"定值：

| 版本 | 配置 | 依据 | 结果 |
|---|---|---|---|
| v1 | gradle 1.5g + kotlin 1g | 按 5.8GB 小机器 | alpha.62 后期不够 |
| v2 | gradle 6g + kotlin 3g | 按 123GB 大机器 | 必超顶，OOM |
| v3 | gradle 4g + kotlin 2g | "留 0.5g 余量" | **仍 OOM** |
| v4 | gradle 2.5g + kotlin 1.5g | **实测 Σ 所有 daemon** | 通过 |

**根因**：前三版都只算了 **gradle daemon 一个 JVM**，漏掉了
**Kotlin 编译器 daemon 其实同时有两个进程**：

```
PID 243614  KotlinCompileDaemon  -Xmx4g   编译器 2.2.21   RSS 1186MB
PID 276445  KotlinCompileDaemon  -Xmx2g   编译器 2.4.0    RSS 1115MB
PID 242983  GradleDaemon         -Xmx4g                RSS  976MB
```

v3 配置下 `4g + 2g = 6g` 只是"看得见的部分"，实际 Σ 堆上限
`4 + 2 + 2 = 8g`，**正好等于 cgroup 上限 8GiB**，再叠加
元空间(1g) + 线程栈 + 原生缓冲 + 页缓存，必然溢出。

**现场证据（不靠估算，靠 cgroup 计数器）**：

```bash
$ cat /sys/fs/cgroup/memory.max        # 8589934592   = 8 GiB
$ cat /sys/fs/cgroup/memory.peak       # 8590462976   ← 超了 528KB
$ cat /sys/fs/cgroup/memory.events
oom 1
oom_kill 1        ← 铁证：不是 JVM 堆耗尽，是 cgroup OOM killer
```

峰值**超出上限仅 528,384 字节（0.5MB）**——精确贴顶后被杀。

**为什么日志"什么都没有"**：OOM killer 是 SIGKILL，进程来不及
flush 日志、来不及抛异常、`-XX:+HeapDumpOnOutOfMemoryError` 也
不会触发（那只管 JVM 自身堆溢出，不管被外部杀）。daemon 日志最后
一条只是常规心跳 `Finished periodic daemon health check.`
——**误以为"构建卡住了"是错的，其实是被静默处决**。

**判据修正（推翻 v2 版写的结论）**：

> v2 写：「`free -m` 有大量 available 却仍报 daemon disappeared → 是 JVM 自身堆耗尽」

**这条是错的，必须作废。** 本机 `free -m` 显示 available 101GB
（宿主 126GB），但 cgroup 只给 8GiB——**`free` 看的是宿主，cgroup 看的是配额**，
两者可以差 15 倍。正确判据只有一个：

```bash
cat /sys/fs/cgroup/memory.events   # oom_kill 计数器，唯一可信来源
```

**解决**：

```properties
org.gradle.jvmargs=-Xmx2560m -XX:MaxMetaspaceSize=768m -XX:+HeapDumpOnOutOfMemoryError
kotlin.daemon.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=512m
org.gradle.workers.max=2
org.gradle.parallel=false
```

定值公式修订为：

```
Σ(所有 daemon 的 -Xmx) + 1.5g(元空间/线程/原生) + 0.5g(页缓存) < cgroup 上限
        ↑ 注意是 Σ 全部，不是只算 gradle 那一个
```

本沙箱：`2.5 + 1.5 + 1.5 + 0.5 = 6g < 8GiB`，留 2g 真实余量。

另加 `org.gradle.workers.max=2` 限制并发 worker 进程数
（每个 worker 都可能膨胀），`org.gradle.parallel=false` 关掉并行工程构建。

**构建前必须先清残留 daemon**（否则旧 daemon 带着旧 -Xmx 继续占内存）：

```bash
cd android && ./gradlew --stop
pkill -f KotlinCompileDaemon; pkill -f GradleDaemon
cat /sys/fs/cgroup/memory.current    # 确认降到 ~3GiB 再开工
```

**验证**：清理后 cgroup 占用从 5.6GiB → 3.0GiB，重新构建通过。

**通用教训**：内存问题**不要估算，要读计数器**。JVM 是预留式的，
`-Xmx` 决定它"敢涨到哪"，与当前 RSS 无关——所以
「现在还有空闲」永远不能推导出「待会儿不会 OOM」。
另外，**别只盯着你启动的那个进程**：工具链会自动拉起子 daemon
（Kotlin 编译器、AAPT2、R8 worker），它们各自吃内存，加起来可能
比你以为的主进程还大。`ps aux --sort=-%mem | head` 是最快的真相来源。

**出现版本**：v0.1.0-alpha.62 / 63 构建过程
**修复版本**：v0.1.0-alpha.63

---

### Bug 471：proroot 冒烟测试失败——二进制要求的 glibc 比我们的 rootfs 高两个版本（2026-09-20，alpha.64 修复）

**症状**（真机，5/5 文件已就位、开关可开）：

```
proroot-ldso: no offset table for glibc 2.36 - patches skipped
reloc: unresolved __isoc23_strtoul in
  /data/user/0/dev.foa.flutter_on_android/files/proroot/libproroot-runtime.so
proroot-ldso: failure rc=2
[proroot] child exited with code 2
```

UI 上「已就位 5/5」显示正常，「冒烟测试」却直接失败。这条日志同时出现
"no offset table for glibc 2.36" 与 "unresolved __isoc23_strtoul"，
两句指向的是**同一件事**，但很容易只看到前一句就以为是 linker 老旧。

**取证（全部在沙箱里实测，不是推测）**：

1. **拉上游 5 个 .so 逐个核 sha256** —— 与 `ProrootOption.soAssets`
   钉死的值**逐个相符**。→ 排除"下载损坏 / 镜像投毒"。
2. **`readelf -sW libproroot-runtime.so`** —— 未定义符号里有：
   ```
   UND __isoc23_strtoul@GLIBC_2.38
   UND __isoc23_strtoull@GLIBC_2.38
   UND __isoc23_strtol@GLIBC_2.38
   ```
   它要求 **GLIBC_2.38**。
3. **解包 rootfs 里的 `libc.so.6`** —— 符号版本最高只到 **GLIBC_2.36**，
   `__isoc23_*` 家族**一个都没有**（实测 `grep -c` = 0）。
4. **`strings libproroot-linker.so`** —— 内置诊断串：
   ```
   proroot-ldso: glibc detect failed, falling back to
   proroot-ldso: glibc <n>
   _rtld_global_ro
   proroot-ldso: _rtld_global_ro off 0x<n>
   proroot-ldso: no offset table for glibc <n> — patches skipped
   ```
   **两个候选分支**：找到 `_rtld_global_ro` 偏移 → 打印 `off 0x<n>`
   并继续；找不到 → 打印 `no offset table ... patches skipped`。
   真机日志走的是后者、且 `<n>` = **2.36**。

   > 注意：glibc 版本是 linker **运行时探出来的**（读 rootfs 的
   > `libc.so.6` / `libc.so.` 符号表），**不是**编译期写死的版本表——
   > 我在 `libproroot-linker.so` 的 `.rodata` 里搜 `2.36`/`2.38` 字面量
   > 是 **0 处**，而在 runtime 里搜到 4 处。这个区别很重要：
   > 说明 linker 本身**没有"支持到 2.36 为止"的上限**，它只是对
   > "2.36 这个具体版本"没有准备偏移表。

**原因（第一层）**：不是"哪个文件坏了"，是**版本错配**：

| 角色 | 版本要求 | 实际 |
|---|---|---|
| `libproroot-runtime.so`（**v1.2.8**） | 需要 glibc **2.38**（用 `__isoc23_*`） | — |
| 我们的 rootfs（Debian 12 bookworm） | — | glibc **2.36** |

`__isoc23_*` 是 **C23 转写函数族**（`strtol`/`strtoul` 等带 `0b` 二进制
字面量支持的版本），glibc **2.38 才引入**。上游用 2.38 的构建环境编了
runtime，却没在 2.36 上验证过。`libc.so.6` 里根本没有
`__isoc23_strtoul` 这个符号 → 重定位无处可解 → `reloc: unresolved`
→ `rc=2`。

**原因（第二层，才是真正的根因）**：**我们把上游版本钉错了。**

第一层只是"哪个版本不兼容"，第二层回答"为什么我们会拿到一个不兼容的
版本"。答案是——**我们当时跟着上游 `main` 走，等于"上游推什么我们拿
什么"**。而上游恰好在这个点上**回退过**：

| 上游 tag | glibc 符号要求 | 5 个资产是否齐全 | 结论 |
|---|---|---|---|
| v1.2.3 | 2.33 | ❌ 不齐（无 stub-loader） | 不可用 |
| **v1.2.5** | **2.34** | **✅ 齐全** | **✅ 选它** |
| v1.2.6 / v1.2.7 / v1.2.8 | **2.38** | ✅ 齐全 | ❌ 我们 rootfs 跑不了 |

决定性证据来自上游自己的 Release note：**v1.2.3 的条目里明写
「glibc 2.36 compat — `__isoc23_strtol@GLIBC_2.38` undefined symbol
제거」**——也就是说**这个坑上游知道、修过、然后从 v1.2.6 起又退回去了**。
我们踩的正是那次回退。

**为什么是 v1.2.5 而不是最新版**：它是"**5 个资产齐全 ∩ glibc ≤ 2.36**"
的**最大交集**。v1.2.3 虽然 glibc 最低，但缺 stub-loader，装了也起不来；
v1.2.6 起资产齐了，glibc 却又回到 2.38。两个条件同时满足的只剩 v1.2.5。

> ⚠️ **这是本项目第二次栽在"跟 main"上**。跟 main 的代价不是"偶尔
> 拿不到新功能"，而是**把上游的一次回退直接变成我们的线上故障**，
> 而且版本号变了、哈希也变了，查起来像"文件损坏"。修法是把
> `upstreamRef` 钉到 tag（`upstreamRef == pinnedVersion`），
> 让"上游改了什么"永远不能悄悄影响我们。

**这里有两件不同的事，别混为一谈**：

| 现象 | 是否致命 | 说明 |
|---|---|---|
| `no offset table for glibc 2.36 — patches skipped` | **不一定** | 只是"没对这个版本打内部结构补丁"。某些情况下仍可能跑（降级路径） |
| `reloc: unresolved __isoc23_strtoul` | **致命** | **符号根本不存在**。就算补丁全打上、linker 完美工作，也没用——rootfs 里没有这个函数 |

换句话说：**我们的失败是两个问题叠加**，而其中**第二个是决定性的**。
偏移表那行只是"WARNING 级别的旁证"，真正拦住我们的是 `__isoc23`。

> ⚠️ **别被 "no offset table for glibc 2.36" 带偏两次**：
> ① 它读起来像"linker 版本太老"——不是，linker 没有版本上限，
>    是"对这个具体版本没有预设偏移表"；
> ② 它读起来像"这就是根因"——也不是，真正的根因是**符号不存在**。
> **有未解析重定位才叫失败**，偏移表落空只是"优化没生效"。

**这也解释了 Bug 467 的一个隐性前提**：一键下载器把 5 个文件当作
**一个不可分的整体**钉死 sha256，但没检查"这套二进制与我们的 rootfs
glibc 是否兼容"——文件全对、组合却跑不起来。

**解决**（alpha.64）：

1. **换版本，而不是换 rootfs**（核心修复）：`pinnedVersion` 从
   `v1.2.8` 改为 **`v1.2.5`**，`requiredGlibc` 从 `2.38` 改为 `2.34`，
   `upstreamRef` 从 `main` 改为**钉 tag**。5 个资产的 `size`/`sha256`
   全部换成 v1.2.5 的实测值（与上游 Release 页公布值逐字节核对一致）。
2. **下载前预检**：`fetchAll()` 在**发出第一个网络请求之前**先做
   组合级兼容性判定，不兼容直接 `throw DownloadException`——
   用户几十 MB 都不用下。逐文件 sha256 与组合级检查是**互补**关系
   （前者查"字节有没有被改"，后者查"这些字节能不能一起跑"），谁都不能删。
3. **失败文案直指版本，不再指向"文件缺失/架构不对"**：原来的文案是
   "glibc 版本不匹配、缺少 /lib64/ld-linux-aarch64.so.1"——后半句是
   **误导**（我们的 `ld-linux-aarch64.so.1` 好端端在
   `/usr/lib/aarch64-linux-gnu/` 下）。同时**引导到「一键下载」**
   （它会取回配套版本），而不是让用户自己去下最新版——那会重新踩坑。
4. **原生侧文案只说结论、不写死数字**：`prorootProbe()` 的失败文案
   只讲"版本错配 + 请用一键下载"，具体版本号由 `ProrootOption`
   单点提供。两处各写一份常量，迟早会各说各话（原生侧一度还写着
   2.38，正是那个已作废的数字）。
5. **风险清单第一条讲清"为什么不是最新版"**：用户有权知道我们钉了
   哪个版本、以及为什么不是最新版——否则他会自己去下最新版、导入、
   然后踩同一个坑。

**为什么不能靠"升级 rootfs 到 glibc 2.38"绕过**：

- 换 Debian 13 trixie / Ubuntu 24.04 意味着整个 rootfs 重做并重测，
  而 FOA 的工具链（qemu 转发、proot、NDK、aapt2）全都建立在当前
  Debian 12 上验证过的**那一份 rootfs** 之上。
- 收益是"让一个实验特性可用"，代价是"动摇整个已验证的构建链路"。
  **这笔账不划算**——尤其当**换版本**就能解决的时候（我们原本就
  误以为只有换 rootfs 一条路）。

**验证**：新增契约测试断言——
① 版本比对函数能在 runtime 需求 > rootfs 提供时判失败；
② 钉死的常量自洽（`pinnedVersion == 'v1.2.5'`、`requiredGlibc == '2.34'`、
   `isGlibcCompatible() == true`）；
③ `upstreamRef` 必须等于 `pinnedVersion` 且不得为 `main`；
④ v1.2.8 的 2.38 仍会被判不兼容（防上游再回退，也防我们改回去）；
⑤ 失败文案含双方版本号、不含"缺少 ld-linux"这类误导表述；
⑥ 预检的位置**早于**第一个下载调用、且抛异常而非静默返回；
⑦ 原生侧文案不含已作废的 `需要 glibc 2.38`。

**通用教训**：**"文件校验通过" ≠ "这套东西能跑"**。哈希只证明
"字节没被改动"，不证明"这些字节合在一起能工作"。凡是要把一个
**多文件组合**装进用户设备的地方，除了逐文件完整性，还得有一项
**组合级的兼容性检查**——而且最好放在**下载阶段**，让用户在花掉
几十 MB 流量之前就知道结果。

**第二条教训**：**遇到"上游二进制不兼容"，先问"我们钉的是哪个版本"，
再问"要不要换 rootfs"**。这次我们差点为了一个实验特性去重做整个
rootfs，而答案只是"把 tag 从错的改成对的"。**换依赖版本的成本，
永远低于换自己基础设施的成本**——先往这个方向找。

**第三条教训**：**测试里的断言会随着真相变化而变化，这很正常，
但要留下痕迹**。这个 Bug 的测试断言改了三轮
（"未验证" → "已实测确认不兼容" → "版本够"），
每一轮都对应着**当时我们对真相的理解**。改的时候写清"为什么变"，
否则下一个人看到断言翻来覆去，会以为是在瞎改。

**出现版本**：alpha.61（proroot 接入）～ alpha.63（一键下载）
**修复版本**：v0.1.0-alpha.64（**部分修复**，见下方 471c）

---

### Bug 471c：钉 v1.2.5 之后**仍然崩**——`no offset table` 不是警告，是死因（2026-09-20，alpha.65 真机推翻 471 的结论）

> ⚠️ **本章的"根因"结论已被后续实验再次修正 —— 请先读 [Bug 471d](#bug-471d真机判别实验升级-rootfs-能不能救-proroot的答案是不能2026-09-21alpha65-后)。**
>
> 本章把 `no offset table` 定为死因，**这个判断只到症状层**。
> 2026-09-21 的判别实验查明：真正的根因是 `libproroot.so` 的
> `DT_NEEDED` 写了开发名 `libc.so`/`libdl.so`，导致它**根本加载不起来**；
> `no offset table` 是绕过加载这一层之后才轮到的下游症状。
> 本章末尾"出路只有换 rootfs"这句也**已被实测证否**（换 glibc 2.41
> 报错逐字相同）。
>
> 保留原文是因为：**它记录了一次真实的误判过程**，其中的取证链、
> 寄存器分析和三条通用教训仍然成立且有价值。只是结论口径要按 471d 读。

**症状**（真机，alpha.65，钉 v1.2.5，5/5 文件就位、sha256 全对）：

```
proroot-ldso: no offset table for glibc 2.36 — patches skipped
[proroot] SIGSEGV pc=0x7e5b332638 lr=0x7e5b32a9c8 fault=0x7e5b458e34 code=2
[proroot] x8 =0x4b5e525852464852  x9 =0x7f7f7f7f7f7f7f7f
[proroot] x10=0xfffffffffffffff0
[proroot] thread_state @x26+0x710..+0x740  → 全部 (read failed)
[proroot] backtrace (fp chain): #0 lr=0x0000007e5b484778 ...
[proroot] child exited with code 139
```

**Bug 471 修的东西没错，但结论下早了。** 471 把 `pinnedVersion` 从
v1.2.8 换成 v1.2.5，理由是"v1.2.5 只需 glibc 2.34，我们 rootfs 有
2.36，版本够"。真机证明：**不够。**

**错在哪**——我在 471 里写下了这句话，它是**错的**：

> `no offset table for glibc 2.36 — patches skipped`：**不一定**致命。
> 只是"没对这个版本打内部结构补丁"。某些情况下仍可能跑（降级路径）。

真机证明这不是"降级路径"，而是**崩溃路径**：`no offset table` 之后
紧跟 SIGSEGV，退出码 139 = 128 + 11。

**为什么没打补丁就会崩**：proroot 的 linker 靠 `LD_PRELOAD` 拦截
glibc 内部行为，很多 hook 需要知道 glibc **内部结构体的字段偏移**
（`_rtld_global_ro` 那类）。这些偏移**每个 glibc 版本都不同**，
所以上游内置了一张"版本 → 偏移表"的映射，逐版本打补丁。
一旦目标版本不在表里，补丁**全部跳过** → linker 按自己的假设布局
去读结构体 → 取到垃圾数据 → 解引用崩溃。

崩溃现场**每一个寄存器都在说这件事**：

| 现场 | 含义 |
|---|---|
| `x8 = 0x4b5e525852464852` | 这是 **ASCII 数据**（`HRFRXR^K` 之类），**不是指针** —— 本该是指针的字段读到了字符串 |
| `x9 = 0x7f7f7f7f7f7f7f7f` | 典型**填充/未初始化模式**，不是地址 |
| `x10 = 0xfffffffffffffff0` | = **-16**，一个"算错了"的小整数 |
| TLS 区（`x26+0x710..+0x740`）全部 `read failed` | 那块内存**根本没映射** —— 按错误布局取到的地址必然指向空洞 |

**取证（沙箱实测，逐条可复现）**：

1. **核对 rootfs glibc**，排除"是我版本判错"：
   ```
   $ strings rootfs/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 | grep stable
   ld.so (Debian GLIBC 2.36-9+deb12u14) stable release version 2.36.
   $ strings .../libc.so.6 | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1
   GLIBC_2.36
   ```
   → `rootfsGlibc = '2.36'` **写对了**，判错版本这条路排除。

2. **核 v1.2.5 的 runtime 依赖** —— 确实最高 `GLIBC_2.34`，
   **没有** `__isoc23_*`。所以 471 说的"符号够"是**真的**。
   → 问题不在符号层。

3. **搜 linker 的 `.rodata`** —— `2.31`/`2.32`/`2.33`/`2.34`/`2.35`/
   `2.36`/`2.38` 这些**版本号字面量一个都没有**（逐个 `grep -c` = 0）。
   → 偏移表**不是**按版本号字符串查的（可能是数值编码或哈希）。
   → 也再次印证 471 的发现：**linker 没有"支持到某版本为止"的上限**，
   它就是"对这个具体版本没准备表"。

4. **上游 Release note 交叉验证**：
   - v1.2.3：`glibc 2.36 compat — __isoc23_strtol@GLIBC_2.38 undefined symbol 제거`
   - v1.2.7：`Adds adaptive glibc internal syscall patching for compatible runtime layout changes`
   → 上游**确实在动这块**，说明它是活跃的适配面，不是"永远支持"的。

5. **上游 README 的要求**：`Requirements: Ubuntu arm64 rootfs with glibc`；
   "Tested with" 一节列的全是 Ubuntu 系。**Debian 从来不在验证范围内。**

**修正后的版本交集表**：

| 版本 | 5 资产齐全 | runtime 最高 GLIBC 需求 | 真机实测 |
|---|---|---|---|
| v1.2.3 | ❌ 无 stub-loader | 2.33 | 资产不齐，未测 |
| **v1.2.5** | ✅ | 2.34 | **❌ SIGSEGV（code 139）** ← 本次 |
| v1.2.6 / 1.2.7 / 1.2.8 | ✅ | 2.38（`__isoc23_*`） | ❌ `reloc: unresolved` → rc=2 |

**两个方向都堵死了**：往下（v1.2.3）资产不齐；往上（≥1.2.6）要 glibc 2.38。
**所有可获得的 proroot 版本，对本项目的 Debian 12 rootfs 都不可用。**

**解决**（alpha.65）：

1. **不再用 `isGlibcCompatible()` 当门禁**。它的判据（符号版本比对）
   已被证伪一次，继续用它 = "预检通过 → 下载 → 冒烟 → 崩溃 → 白折腾"。
   新增 `isKnownUnusable()`（真机实测结论，当前恒为 `true`），
   **排在 `isGlibcCompatible()` 之前**，两者**分开表达**：
   - `isGlibcCompatible()` → "符号依赖算得过来"（仍是 true，事实没变）
   - `isKnownUnusable()` → "实测跑不起来"（true）

   这两个**不能合并成一个布尔**——合并就丢掉"纸面可行 ∩ 实测不行"
   这个反直觉但关键的信息。测试专门钉住这一点。
2. **UI 开关改为硬拦**。原来 `_toggle` 对未冒烟是"提醒但不强制"，
   注释写着"用户可能就是想在真构建里试"。那时我们**只是没验证过**；
   现在已**实测确认必崩**，再放行只是让用户把一次注定失败的构建
   跑完（几十分钟 + 一堆定位不到根因的 gradle 报错）。
   **未知风险可以交给用户判断，已知错误不该出现在选项里。**
3. **失败文案分形态**。原生侧 `prorootProbe()` 原来只认
   `reloc: unresolved`（形态 A），把 `no offset table` 当"没打补丁"。
   现在两种形态**都要认**，且**形态 B 不许再引导"一键下载"**
   ——换了还是崩，那是把人往第二次失败里推。
4. **风险清单第一条改成"实测不可用"**。原来第一条是
   "讲清为什么不是最新版"，那个框架暗示"我们钉的这版能用、只是不是最新",
   而事实是**钉的这版也崩**。第一条是用户最先读到的内容，
   留着旧措辞等于继续给一个已知为假的承诺。
5. **`pinnedVersion` 保留 v1.2.5**（不换回 v1.2.8）：v1.2.8 错得更早
   （`reloc: unresolved` 直接 rc=2），v1.2.5 至少能走到 linker 补丁阶段。
   两者对 Debian 都不可用，保留信息量更大的那个，等上游或换 rootfs 后重估。

**为什么"再试试别的版本"这条思路本身是错的**：
可获得的版本只有 4 档（v1.2.3~v1.2.8），其中 v1.2.3 资产不齐、
v1.2.6+ 要 2.38、v1.2.5 实测崩。**穷举已经做完了。**
继续"换个版本试试"是在一个已知为空的空间里搜索。

**通用教训（本次最贵的三条）**：

1. **"我没有观察到它致死" ≠ "它不致死"。** 471 里我只有 **readelf
   静态推断**，没有真机运行，就断言 `no offset table` 是良性的。
   静态分析能证明"依赖存在/不存在"，**证明不了运行期行为**。
   凡是要对"能不能跑"下结论，**必须真机跑一次**。

2. **一个成功信号的存在，不能推出另一个失败信号不存在。**
   我看到 `reloc: unresolved`（真失败）就以为找到了唯一死因，
   把旁边的 `no offset table` 降级成"旁证"。实际上**那是两条独立的
   死路**：符号层（`reloc`）和布局层（offset table）。
   修掉前者不会自动修掉后者，而我只修了前者就宣布"修好了"。

3. **"版本号算得过来"是纸面推理，不是验证。** 本次两轮修复都栽在
   同一件事：用某个**间接指标**（符号表、版本号比对）代替
   **直接验证**（真机跑）。间接指标能快速排除，**不能用来确认**。
   所以 471 里那句"仍建议先跑一次冒烟测试确认"其实写对了 ——
   错的是我**在没跑之前就把它当成已确认**，还据此改了 UI 门禁。

**验证**：基线 685 → **689**，新增 4 条契约测试——
① 断言"符号够"与"能跑"两个判断**分开存在**且当前**同时为 true**
  （钉住那个反直觉组合，防止有人合并回一个布尔）；
② UI 开关必须**硬拦**（查 `isKnownUnusable()` 且 `return`），
  且硬拦排在"建议冒烟"之前；
③ 原生侧**两种失败形态都要认**，且形态 B 分支**不许出现"一键下载"**
  （防把用户推进第二次失败）；
④ 风险清单第一条必须是"已实测不可用"，且全文不得再出现"够"。

**出现版本**：alpha.64（471 的"修复"实际未生效）
**确认失败**：alpha.65 真机冒烟
**当前状态**：**未解决**。proroot 在 Debian 12 上不可用，
出路只有换 rootfs（代价大）或等上游支持 Debian。

---

### Bug 471d：真机判别实验——"升级 rootfs 能不能救 proroot"的答案是**不能**（2026-09-21，alpha.65 后）

> 🔴 **本章末尾的"根因"与"我方无解"结论已被 [Bug 471e](#bug-471e471d-的根因判断是错的不是上游缺陷是我们用错了加载器2026-09-21-定案) 全部推翻。**
> 本章**仍然有效**的部分：① "升级 rootfs 不能救"这个实测结论；② 判别实验
> 的方法（隔离在 `/tmp`、不动系统）；③ 对"把最先观察到的当成最先发生的"
> 这个错误的反思。
> **已作废**的部分：把 `DT_NEEDED` 写 `libc.so`/`libdl.so` 判为"上游开发名
> 写错"。真相是**在 Android bionic 下这两个名字完全正确**，是我拿 glibc
> 规则审错了二进制；真正的死因是我们用 `ld-linux` 去加载一个
> `PT_INTERP = /system/bin/linker64` 的 Android launcher。**有解**。

**背景**：471c 的结尾给用户留了两条出路——"换 rootfs"或"等上游"。
用户随即追问：**"可以升级 rootfs 升级难道有什么副作用吗？"**

这个问题暴露了我论述里的一个漏洞：我把"换 rootfs"说成一条
**合理的出路**，却从没验证过它**真的有用**。所以我做了这个判别实验。

**实验设计**（关键：**全程不动系统**，所有操作都在 `/tmp` 隔离目录）：

| 步骤 | 做法 |
|---|---|
| ① | 取 Debian 13 trixie 的 `libc6` 包解包到 `/tmp/pexp/tx/`（glibc **2.41-12+deb13u4**，arm64） |
| ② | 用 trixie 的 `ld-linux-aarch64.so.1`（2.41）作 loader |
| ③ | 用 `LD_LIBRARY_PATH` 指向只含软链的 shim 目录，把 NEEDED 名指到真实 `.so.6` |
| ④ | 系统文件一个字节没改（实验后核对：`libc.so` 时间戳 `Apr 27` 未变） |

**结果 —— 两代 glibc 报错逐字相同**：

```
glibc 2.36 (bookworm)：version `LIBC' not found (required by ./libproroot.so)
glibc 2.41 (trixie)  ：version `LIBC' not found (required by ./libproroot.so)
```

**升级 rootfs 对此问题零改善。**

#### 真正的根因：`DT_NEEDED` 写了开发名

容器里没有 `readelf`/`objdump`（`binutils` 未装），所以我**用 python 手写
了一个 ELF 解析器**直接读 `.dynamic` 节。硬证据：

| 文件 | SONAME | `DT_NEEDED` |
|---|---|---|
| `libproroot.so` | (无) | **`libdl.so`, `libc.so`** ← 开发名 |
| `libproroot-runtime.so` | libproroot-runtime.so | `libc.so.6` |
| `libproroot-linker.so` | libproroot-linker.so | (无) |
| `libproroot-stub-loader.so` | libproroot-stub-loader.so | (无) |

**`libproroot.so` 是全套里唯一一个写开发名的**，其余都规规矩矩写 `libc.so.6`。

这两个名字为什么在运行期必然失败：

- **`libdl.so`** —— glibc **2.34 起**已把 libdl 并入 libc，`libdl.so`
  从此不存在（仅保留空壳 `libdl.so.2`）。任何 2.34+ 系统上都没有它。
  **与版本高低无关。**
- **`libc.so`** —— 它是 `libc6-dev` 提供的 **GNU ld script**（291 字节纯文本，
  内容为 `GROUP ( /lib/.../libc.so.6 ... )`），供链接器 `-lc` 使用，
  **永远不是 ELF**。实测 **Debian 12 与 Ubuntu 22.04 的 `libc.so`
  是同一种东西**（283/291 字节 ld script）—— 这是发行版通用约定。

所以 loader 的行为必然是三层的：

```
① 找不到 libdl.so      → cannot open shared object file
② 找到 libc.so 但是文本 → invalid ELF header
③ 强行当 ELF 处理       → version `LIBC' not found
```

**第三层的 `LIBC` version tag 尤其说明问题**：实测扫描 2.36 与 2.41 的
`libc.so.6`，**两代都不存在 `LIBC` 这个 version 定义**。glibc 内部符号用的是
`GLIBC_PRIVATE`（两代都有，`__libc_init` 确实在其内）。
**proroot 索要的 `LIBC` 不是标准 tag。**

#### 为什么会需要"glibc 偏移表"这个机制

自写解析器扫 `libproroot.so` 的导入符号表，64 个导入符号里有 2 个
glibc 内部符号：

```
__cxa_atexit
__libc_init    ← 关键
```

**`__libc_init` 是 glibc 的内部初始化函数，不是公开 API。**
（公开 C 程序入口是 `_start` → `__libc_start_main` → `main`。）

因为 proroot 的加载器要接管后续所有库的加载，它必须调用 glibc 内部
初始化。而内部结构体的布局**每代都变**，所以需要按版本打补丁 ——
`no offset table for glibc 2.36` 是**这条链的第三层症状**，
不是根因。471c 里我把它当成死因，其实是绕过了前两层之后才轮到的。

#### 我在这个 Bug 里犯的三个错

1. **"换 rootfs"当成出路却没验证。** 471/471c 两轮里我都写了
   "出路是换 rootfs（代价大）"，但**从没测过它是否有效**。
   用户一句"升级有什么副作用吗"就问到了这个漏洞。**代价大的方案
   更应该先验证有效性**，否则用户花了代价还是失败。
   教训：**在给用户列"出路"之前，先确认它真的是出路。**

2. **把"最先观察到的"当成"最先发生的"。** 471c 里我把
   `no offset table` 定为死因，因为它出现在崩溃日志里、看着最像原因。
   实际上它前面还有两层（`libdl.so` 缺失、`libc.so` 非 ELF），
   只是当时我用"补个软链"绕过去了，**没意识到绕过的正是根因**。
   教训：**绕过一个问题时，要问"我绕过的是什么"，而不是"我终于过去了"。**

3. **又一次用间接指标代替直接验证。** 471 栽在 readelf 静态推断，
   471c 栽在"崩在哪个阶段看着更靠前"，471d 前我又差点栽在
   "glibc 版本够不够"——**三次都用了间接指标**。
   这次改用手写 ELF 解析器**直读 `.dynamic`**，才拿到硬证据。
   教训：**报错信息是症状，二进制结构才是事实。**

#### 顺带澄清的一个**曾经写错的假设**

我在 471c 里推测过"minbase 精简 rootfs 没装 `libc6-dev`，所以缺
`libc.so`/`libdl.so`"。真机 `dpkg -l` 实测**推翻了它**：

```
ii  libc6-dev:arm64    2.36-9+deb12u14    arm64   GNU C Library: Development Libraries and Header Files
```

**`libc6-dev` 是装了的**，`libc.so` 也确实在 —— 问题不是"缺文件"，
而是"这个文件本来就不是 ELF"。**"文件不存在"和"文件不可用"是两回事**，
我上一轮把后者误判成了前者。

#### 修正后的结论

1. **升级 rootfs 不是出路**（实测：2.41 报错与 2.36 逐字相同）。
   Debian 13 的运行时包 `libc6` 同样**不含** `libc.so`/`libdl.so`
   —— 这两个只有 `libc6-dev` 才带，且 `libc.so` 在任何发行版上都不是 ELF。
2. **根因是上游的构建配置错误**：`DT_NEEDED` 该写运行时名 `libc.so.6`
   却写了开发名 `libc.so`。**这不是我们能通过换 rootfs / 换版本绕过的** ——
   除非上游重新构建。许可又禁止我们修改二进制（`Redistribution of
   modified binaries is not permitted`），所以**我们这边无解**。
3. 因此 UI 文案必须**显式堵掉"升级 rootfs"这条错误引导**，
   而不是继续把它列成出路。

#### 代码变更

- `ProrootOption.knownUnusableMessage()` — 改写为三层加载失败现场，
  显式写"**换 rootfs 不是出路**"并给出 2.41 的证否证据
- `ProrootOption.compatNote()` — 从"linker 偏移表不覆盖"改为
  "根因不在 glibc 版本上"，并堵掉"升级 rootfs 也救不了"
- `ProrootOption.glibcMismatchMessage()` — 删掉"换用官方要求的 rootfs"
  这条出路，改为"**不要试图靠升级 rootfs 解决**"
- `ProrootOption.risks` — 前三条重写：第一条指向加载失败，
  第二条讲 `DT_NEEDED` 根因，第三条明确"两条路都堵死"
- `ProrootOption.linkerSupportedGlibc` — 注释改为"第三层症状，非根因"
- `MainActivity.kt` — 失败分诊新增**形态 C**（加载失败，`devNameNeeded`），
  且**排在 A/B 之前**（它最先发生）；形态 B 文案补上"升级 rootfs 亦已实测无效"

---

### Bug 471e：**471d 的根因判断是错的**——不是上游缺陷，是我们用错了加载器（2026-09-21 定案）

> ⚠️ **本章推翻了 471d 的核心结论。** 471d 说的"根因是上游 `DT_NEEDED`
> 写开发名、我方无解"**全部作废**。请以本章为准。

**触发**：用户追问 —— **"参考作者的 proroom 项目有解吗？作者是怎么在安卓上
用 proroot 的？"**

这一问问到了要害：我从 471 到 471d **折腾了四轮，从没去看过作者自己怎么用
这套二进制的**。所有结论都建立在我自己猜的调用方式上。

**做法**：去找作者的**开源 App**。proroot 本身闭源，但作者另有一个开源项目
[`coderredlab/andClaw`](https://github.com/coderredlab/andClaw)，
里面 `proroot/ProrootManager.kt` 就是完整的集成实现。

#### 决定性证据：`PT_INTERP`

自写 ELF 解析器直读五个文件的 program header，答案一目了然：

| 文件 | `e_type` | `PT_INTERP` |
|---|---|---|
| `libproroot.so` | DYN(3) | **`/system/bin/linker64`** |
| `libproroot-linker.so` | DYN(3) | （无，static-pie） |
| `libproroot-stub-loader.so` | DYN(3) | （无，static-pie） |
| `libproroot-bridge.so` | EXEC(2) | （无，静态） |
| `libproroot-runtime.so` | DYN(3) | （无，LD_PRELOAD 钩子库） |

**`libproroot.so` 的 `PT_INTERP` 是 `/system/bin/linker64`** ——
它是 **Android 原生 launcher**，由 bionic 链接器加载。

而我四轮里一直用的是 `ld-linux-aarch64.so.1`（glibc 的加载器）。
**加载器用错了，那些报错全是我自己造出来的。**

#### 471d 的"硬证据"错在哪

471d 里我扫出 `libproroot.so` 的 `DT_NEEDED` 是 `libdl.so` / `libc.so`，
判为"开发名写错"。**数据是对的，判断是错的**：

- **在 Android bionic 下，`libc.so` / `libdl.so` 都是真实存在的运行时库**
  （`/system/lib64/libc.so`、`libdl.so`），不是 glibc 语境的 ld script，
  也不是"已并入 libc 的历史名"。
- 我是**拿 glibc 的规则去审一个 Android 二进制**，然后判它"写错了不该写的名字"。

同理，471d 说"两代 glibc 都扫不到 `LIBC` version tag，所以 proroot 索要的是
非标准 tag" —— **`LIBC` 本来就是 bionic 的 version tag**，glibc 里当然没有。
它不是"非标准"，只是不属于 glibc。

#### 作者怎么集成（andClaw 源码要点）

`ProrootManager.kt` 给出了六个必须照做的点：

| # | 做法 | 源码位置 |
|---|---|---|
| ① | **五个 .so 打包进 APK 的 `jniLibs/arm64-v8a/`**，安装时由 Android 自动解压到 `nativeLibraryDir` | 注释 18-19 |
| ② | **从 `nativeLibraryDir` 直接 exec**，不经任何 ld-linux | 118-120 |
| ③ | 补 **6 个 `PROROOT_*` 环境变量** | 711-717 |
| ④ | **SELinux**：`nativeLibraryDir` 受保护，guest 的 linker 访问不到 → `libproroot-runtime.so` 要复制到 `filesDir`，**并再放一份进 rootfs 的 `/root/.proroot/`** | 143-152 |
| ⑤ | 启动参数用 **`-b <host>:<guest>`** 形式，**且不带 `-0`** | 581-592 |
| ~~⑥~~ | ~~rootfs 用 Ubuntu 24.04.3 LTS~~ → **已撤销，见下** | — |

> ⚠️ **⑥ 已删除：rootfs 不是硬约束，不必换。**
>
> 我先把作者的**产品选择**当成了**技术门槛**。查证后：
>
> 1. 官方 README 的 Requirements 是 **`Ubuntu arm64 rootfs with glibc`**，
>    硬条件在 **`with glibc`**（即非 musl），"Ubuntu" 是作者的验证环境。
> 2. **决定性反证**：作者在 `ProrootManager.kt:475-495` 的
>    `repairRootfsOsReleaseFiles()` 里**主动覆写** rootfs 的
>    `etc/os-release` / `usr/lib/os-release` / `etc/lsb-release` 成硬编码
>    Ubuntu 字符串，还会**删除 `etc/alpine-release`**（变量名直接叫
>    `alpineExistedBefore`）。**真依赖 Ubuntu 的运行时不需要修这些标记** ——
>    需要覆写恰恰说明 proroot 不关心实际发行版。
> 3. 本项目三条硬条件**全部满足**：arm64-v8a ✓、glibc 2.36（非 musl）✓、
>    API 28 ≥ 26 ✓。
>
> **正确顺序：先做完 ①-⑤，用现有 Debian 12 直接跑冒烟测试。**
> 跑通就完全不用换；只有实测失败且报错指向 glibc 内部结构体布局
> （偏移表机制）时，才考虑换 Ubuntu。
>
> **教训**：判断一个条件是不是硬约束，看"官方最低要求写了什么"，
> 而不是"作者顺手用了什么"；并且要特别注意 ——
> **作者需要额外做的补偿动作（覆写标记、删除文件），
> 往往正是"这不是硬约束"的证据。**

③ 的六个变量（我们**一个都没设**）：

```
PROROOT_TMP_DIR         PROROOT_ROOTFS         PROROOT_GUEST_EXE
PROROOT_LIB_PATH        PROROOT_LINKER_PATH    PROROOT_TRAMPOLINE_PATH
```

⑤ 的正确 argv（对照我们写的）：

```sh
# 作者（正确）
libproroot.so -r <rootfs> \
  -b /dev:/dev -b /proc:/proc -b /sys:/sys \
  -b /dev/urandom:/dev/random -b <cacheDir>/shm:/dev/shm \
  -w /root --link2symlink /bin/sh -c '<cmd>'

# 我们（错误）
libproroot.so -r <rootfs> -0 --link2symlink -w /root ...
```

两处关键差异：**`-b` 是 host:guest 冒号对**（proot 是单路径，抄错就是挂载错位）；
**proroot 分支不带 `-0`**（那是 proot 的参数）。

#### 我犯的错（471 → 471d 共四轮）

| 轮次 | 我的结论 | 实际 |
|---|---|---|
| 471 | 根因是 glibc 版本太低 | 与版本无关 |
| 471c | 根因是 linker 偏移表不覆盖 | 只是下游症状 |
| 471d | 根因是上游 `DT_NEEDED` 写开发名，**我方无解** | **上游没写错，加载器用错** |
| 471e | 根因是**加载方式不对**，有解 | ✓ |

**共同错误：四轮都在"解读报错"，没有一轮去"核对二进制该怎么被启动"。**
`PT_INTERP` 就在 program header 里，五个文件扫一遍就能看到 ——
这个检查直到用户提醒我去看作者的实现才做。

**教训：报错再"硬"，也只是加载器说的话。要判断一个二进制属于哪个运行世界，
先看 `PT_INTERP`，而不是看它报什么错。**

#### 修正后的结论

1. **有解。** 不需要等上游、不需要重新构建、不需要改二进制（许可也不需要破）。
   缺的只是**集成方式**。
2. **rootfs 不是卡点，而且很可能不必换。** 官方硬条件是 **glibc（非 musl）**，
   本项目满足；Ubuntu 只是作者的验证环境。**先做完 ①-⑤ 用现有 Debian 12
   跑冒烟测试** —— 跑通就完全不用换。
3. **"升级 rootfs 也救不了"仍然成立**，但理由变了：不是"版本无关"，
   而是**光换 rootfs 不做集成改造照样跑不起来**。

#### 代码变更

- `ProrootOption.knownUnusableMessage()` — 从"我方无解"改为
  "**该特性尚未接通**"，列出五项改造清单（rootfs 一项已撤除）
- `ProrootOption.compatNote()` — 改为"**硬条件满足 + 尚未接通**"；
  不再说"未支持组合"（那是把产品配置当技术门槛），
  改为"与官方验证环境不同，但硬条件满足"，并补上"跑通就不必换"的顺序
- `ProrootOption.requiredRootfs` — 注释更正：明确"**不要读成非 Ubuntu 就跑不了**"，
  附上作者覆写 `os-release` 的反证
- `ProrootOption.glibcMismatchMessage()` — 删掉"真死因是 `DT_NEEDED` 写开发名"，
  改为 `PT_INTERP` / `linker64` 的解释
- `ProrootOption.launcherUsage` — 修正为正确的 `-b host:guest` 形式，去掉 `-0`
- `ProrootOption.risks` — 前三条重写 + 新增 andClaw 参考实现条目
- `MainActivity.kt` — 分诊注释与三条文案从"DT_NEEDED 根因"改为"加载方式不对"；
  `prorootProbe` 的 KDoc、`buildProrootCmd` 的 argv 注释、
  `applyProrootEnv` 全部更正（并补上 `PROROOT_TMP_DIR`）；
  删掉"本机 Debian 属未支持组合"这句过重的表述
- 测试：471d 的"堵死升级 rootfs"断言改为"**必须说清 rootfs 不是卡点**"；
  新增"文案不许再断言上游 `DT_NEEDED` 写错"的兜底断言
- `platform/android/MainActivity.kt` — 同步（Bug 440 逐字节门禁）

#### 还没做的

**五项集成改造已实施**（见下节 471f），`isKnownUnusable()` 仍返回 `true`
—— 因为**尚未在真机上验证通过**。"做到了"与"验证过了"是两件事，
在冒烟测试通过前不给用户承诺。

**验证**：`flutter test` 693/693 全绿，`flutter analyze` 7 条基线
（全在 `third_party/`），Kotlin `compileDebugKotlin` 通过。

---

### Bug 471f：按作者实现完成五项集成改造（2026-09-21，待真机验证）

**背景**：471e 定案"有解，缺的是集成方式"后，用户拍板：
**"先直接做 5 项改造但是不换底层跑测试"**。

**五项改造与实施位置**：

| # | 改造 | 实施位置 |
|---|---|---|
| ① | 五件套打包进 `jniLibs/arm64-v8a/` | `tools/fetch_assets.sh` 新增 `proroot` 子命令 + `tools/setup_android.sh` 第 ④ 步 |
| ② | 从 `nativeLibraryDir` 直接 exec | `MainActivity.kt` 新增 `findProrootLauncher()` / `prorootLibDir()` / `prorootDirs()` / `resolveProrootFile()` |
| ③ | 补 6 个 `PROROOT_*` 环境变量 | `applyProrootEnv()` 重写 |
| ④ | SELinux 路径处理 | 新增 `syncProrootRuntimeLib()` |
| ⑤ | `-b host:guest` + 去掉 `-0` | `buildProrootCmd()` 的 argv 重写 |

#### 一个被推翻的**前置设计决策**（重要）

代码里原本写着**不走 jniLibs**，理由是：

> "jniLibs 的 .so 会被 Android 校验并当作'库'加载，而 proroot 的 5 个 .so
> 里只有 libproroot.so 是启动器、其余是运行时组件，混在 jniLibs 里反而
> 要靠 rename 绕过（现有 proot 就是这么做的，代价是名字对不上、排查困难）。"

**这个理由不成立。** proot 需要 rename，是因为它下载来的文件叫
`proot-arm64`（不匹配 `lib*.so`，Android 直接忽略不打包）。
而 proroot 五件套**原名就是 `lib*.so`**：

```
libproroot.so              ✓  libproroot-bridge.so        ✓
libproroot-runtime.so      ✓  libproroot-stub-loader.so   ✓
libproroot-linker.so       ✓
```

**全部匹配，一个都不用改名** —— 那条"代价"根本不存在。
所以 ① 的成本从"要设计绕名方案"降到"改两行脚本"。

#### 独立佐证：`libproot.so` 的 interp 也是 linker64

改造记录里对五件套重新扫了一遍 `PT_INTERP`，顺带发现：

```
libproot.so                DYN  interp=/system/bin/linker64   ← 已在用！
libproroot.so              DYN  interp=/system/bin/linker64
libproroot-linker.so       DYN  interp=(none)
libproroot-stub-loader.so  DYN  interp=(none)
libproroot-bridge.so       EXEC interp=(none)
libproroot-runtime.so      DYN  interp=(none)
```

**`libproot.so` 的 interp 同样是 `/system/bin/linker64`，而且它今天就在
`nativeLibraryDir` 里正常工作** —— 这是"必须从 nativeLibraryDir 直接 exec"
这条结论的**现成的、跑得通的佐证**，比任何论证都硬。

#### 关键实现细节

**双路径（与 `findProot` 同一形状）**：

```
nativeLibraryDir/libproroot.so   ← 优先（jniLibs 打包）
filesDir/proroot/libproroot.so   ← 兜底（「导入 proroot」/ 一键下载）
```

`resolveProrootFile()` 是**逐文件**在两个目录里找，而不是整目录二选一 ——
允许"jniLibs 里有一半、用户又手工补了另一半"这种混合状态。

**③ 的注意点**：README 说启动器会从 `/proc/self/exe` 的 dirname
**自动发现**组件，同目录时理论上不必显式设。但作者显式设了六个变量，
我们跟着设 —— 显式路径比依赖自动发现更稳，成本为零。

⚠️ 这五个路径变量是给 **launcher 自己**（宿主侧进程）读的，
**不能跨 SELinux 边界**：指向 nativeLibraryDir 的路径，rootfs 内的
linker 访问不到。guest 要用的那个库由 ④ 单独复制。

**④ 的幂等做法**：源与目标**长度相同**即跳过复制。比时间戳可靠
（Android 上 `copyTo` 后 mtime 未必如预期），也比每次无条件复制省。

**⑤ 的两个易错点**：
- `-b` 必须 `host:guest` 冒号对（proot 是单路径）——
  连 `NATIVE_BIONIC_BINDS` 那条循环也要跟着改成 `"$p:$p"`；
- `/dev/shm` 要绑到**应用可写**目录（`cacheDir/shm`），
  不能直接绑宿主 `/dev/shm`（权限不足）。

#### 验证状态（诚实标注）

| 项目 | 状态 |
|---|---|
| Kotlin 编译（`compileDebugKotlin`） | ✅ 通过（36 tasks executed） |
| `flutter test` | ✅ 693/693 |
| `flutter analyze` | ✅ 7 条基线（全在 `third_party/`） |
| Bug 440 逐字节门禁 | ✅ 两份 sha256 一致 |
| `fetch_assets.sh proroot` 实跑 | ✅ 五个文件下载 + sha256 校验通过 |
| **真机冒烟测试** | ❌ **未做** —— 这是唯一还没验证的一环 |

⚠️ **本轮改动全部是"按作者实现照做"，不是"已验证能跑"**。
真正的判据只有真机冒烟测试。跑通则开放卡片；若失败，
以真机报错为准继续修正 —— **不再靠推测**（这是 Bug 471 四轮误判的教训）。

**出现版本**：alpha.64 起
**定性**：2026-09-21 真机判别实验
**当前状态**：**五项改造已实施，待真机验证**（见上方验证状态表）。
⚠️ 上面那句"已确认我方无解"是 **471e 之前的旧结论，已作废** ——
471e 推翻了它（不是无解，是用错了加载器），471f 已按作者方式重做集成。
保留这行是为了记录"我们曾经这么想过"。

**真机副作用**：已全部还原 —— apt 源回到 bookworm 单行、临时文件清理、
系统 `libc.so` 时间戳未变、`libdl.so` 恢复为不存在、`my_flutter` 项目零改动。

---

### Bug 471g：作者"直接能用"的那个包，为什么我们抄过来也不行（2026-09-22 查证）

**触发**：用户看了截图后问了一句很关键的话 ——

> "不能直接用了是吗？之前作者不是有项目可以直接用吗？具体卡点是哪里"

这个问题**我此前没正面回答过**。答案是：**作者确实有能跑的包，但我们
之前拿的那个版本不对，而这恰恰不是版本号的问题 —— 是 glibc 需求与
rootfs 的匹配问题，并且它解释了"为什么换 rootfs 也没用"。**

#### 查到的事实

把 [andClaw](https://github.com/coderredlab/andClaw) 拉下来（它把
`app/src/main/jniLibs/arm64-v8a/` 入库了，所以能直接对比）：

| 文件 | 作者 (andClaw) | 我们 (v1.2.5) | 差异 |
|---|---|---|---|
| `libproroot.so` | 43,624 | 40,720 | +7% |
| `libproroot-runtime.so` | **376,064** | 228,136 | **+65%** |
| `libproroot-linker.so` | 79,408 | 71,216 | +11% |
| `libproroot-bridge.so` | 23,624 | 23,624 | 相同 |
| `libproroot-stub-loader.so` | 144,144 | 142,576 | +1% |

`libproroot-runtime.so` **大了 65%** —— 差异集中在这里。sha256 全部不同。

#### 卡点的真正位置

`no offset table for glibc X` 这句来自 **`libproroot-linker.so`**
（`grep -a "no offset table" *.so` 可复现定位）。它是 proroot 的
**clean-room linker**（见作者 `THIRD_PARTY_LICENSES.md` 第 13 行：
"The clean-room `libproroot-linker.so` package is the only bundled
proroot linker artifact"）。

这个 linker 干的事：**给 rootfs 里的 glibc 动态链接器打二进制补丁**，
把 ptrace 那套（每次系统调用两次上下文切换）换成 LD_PRELOAD + 直接
改内存布局。要改布局就必须知道 glibc 内部结构体的**字段偏移**，
而这个偏移**每个 glibc 版本都不一样**，只能**逐个版本硬编码**。

于是：

```
proroot-ldso: glibc 2.36  →  表里没有这个版本  →  补丁全部跳过
                          →  结构体布局与预期不符
                          →  运行期取到垃圾数据  →  SIGSEGV (139)
```

**所以 `no offset table` 不是警告，是"我放弃打补丁了"的宣言**，
后面 139 是它的必然结果。

#### 关键对比：两版的 glibc 需求

用 `readelf -V` 读两版 `libproroot-runtime.so` 的符号版本需求：

| | 需要的最低 glibc |
|---|---|
| 作者版 | **GLIBC_2.38** |
| 我们版 (v1.2.5) | GLIBC_2.34 |

而两边的 rootfs：

| | rootfs | 提供的 glibc |
|---|---|---|
| 作者 | Ubuntu 24.04.3 base（`scripts/setup-assets.sh:34` 的 `ROOTFS_URL`） | 2.39 |
| 我们 | Debian 12 bookworm | 2.36 |

**作者的组合能跑，理由是 2.39 ≥ 2.38。** 这不是"Ubuntu 特殊"，
是 Ubuntu 24.04 恰好带了个够新的 glibc。

#### 这解释了两件此前想不通的事

**① 为什么换 rootfs 没用。** 我们试过 Debian 13（glibc 2.41，比作者还新），
配上 **v1.2.5** —— 报错仍是 `no offset table for glibc 2.41`。
因为我们换的是 rootfs，**没换 linker**：老 linker 的表里本来就没有
2.36+ 任何版本，换成 2.41 只是把"表里没有的版本号"从 2.36 变成 2.41。

> **表里没有的版本，换什么 rootfs 都是没有。**

**② 为什么"升版本"也不行（表面上）。** 早前试 v1.2.8 时失败得更早
（`version 'LIBC' not found`），于是我们判"两个方向都堵死"。
现在看，**那个方向其实是对的**：v1.2.8 要 GLIBC_2.38，和我们当时的
Debian 12（2.36）不匹配 —— **但作者证明了配上 2.39 它就能跑**。
当时的错误不是"选错了方向"，而是**只换了版本、没换 rootfs**，
换了个措辞会死得更早的组合，就误以为此路不通。

#### 更正后的结论

proroot 的可用组合是**成对**的，缺一不可：

```
linker 的偏移表 ⊇ rootfs 的 glibc 版本
        ↑ 由 proroot 版本决定        ↑ 由 rootfs 决定
```

| 组合 | linker 表 | rootfs glibc | 结果 |
|---|---|---|---|
| 作者：新版 + Ubuntu 24.04 | 含 2.38+ | 2.39 | ✅ 能跑（已验证，上架 Play） |
| 我们：v1.2.5 + Debian 12 | 到 2.34 为止 | 2.36 | ❌ no offset table |
| 我们：v1.2.5 + Debian 13 | 到 2.34 为止 | 2.41 | ❌ 同样报错（换汤不换药） |
| 我们：v1.2.8 + Debian 12 | 含 2.38+ | 2.36 | ❌ LIBC not found（rootfs 太旧） |
| **未试：新版 + Debian 13** | 含 2.38+ | 2.41 | **理论上可行 —— 但 glibc 2.41 在不在表里仍未知** |

最后一行是**唯一还没试过、且逻辑上说得通的组合**。但它有前提没验证：
新 linker 的表到底覆盖到哪个版本（2.38？2.39？2.41？）。
**在不知道表内容之前，无法保证 2.41 在里面** —— 表里没有 2.41 的话，
换 rootfs 又会回到 `no offset table`。

#### 但我仍然建议先别投这个

三个理由，按重要性排：

1. **收益极小**。proroot 优化的是**容器层**（省掉 ptrace 的上下文切换）。
   而 FOA 构建慢的大头是 **QEMU x64 指令翻译**（`gen_snapshot` /
   `gradle` / `aapt2` 全是 x64 二进制）与 dart/gradle 自身的计算 ——
   **这两项 proroot 一点都不改善**。它只对 I/O 密集型操作（apt 装包、
   tar 解压、海量小文件读写）有感。不要指望构建时间从 10 分钟变 2 分钟。

2. **会引入一个不能自控的依赖**。偏移表是上游**硬编码**的，且
   `libproroot.so` 是 **proprietary**（作者 `THIRD_PARTY_LICENSES.md`
   第 10 行："Proprietary (free to use; redistribution of modified
   binaries is not permitted)"）。我们既不能改它，也不该把 rootfs
   绑死在"某个 Ubuntu 版本"上 —— 那会让 rootfs 升级变成一个
   "先确认 proroot 表里有没有这个 glibc"的**耦合决策**。

3. **验证成本 > 收益**。要试就得：下新版五件套 → 换 Ubuntu 24.04 rootfs
   → 重做五项集成 → 真机冒烟。而且**即使跑通，也只是拿到一个 I/O 优化**，
   对"能不能构建"没有改变 —— 现在的官方 `libproot.so`（纯 ptrace、
   不依赖任何偏移表）已经能构建。

**所以我的建议**：把 proroot 卡片**保持劝退**（`isKnownUnusable() = true`），
在文案里把上面这张"组合矩阵"讲清楚 —— 让想折腾的用户知道**该怎么试**，
而不是我们替他试。想试的人按"新版 + Ubuntu 24.04"这个作者验证过的组合走。

#### 通用教训（第 5 条）

前面四条教训见 `proroot-结论报告.md` 第六节。这是第 5 条：

> **"版本不匹配"这种结论，必须说明是哪两个东西在匹配。**
> 我们前后说了三次"版本不对"（rootfs 版本 / proroot 版本 / 都换），
> 但一直没把**"linker 的偏移表"**列为匹配的一方 —— 于是每次只动一半，
> 每次失败，就误以为"此路不通"。**A 需要 X、B 提供 Y，那就必须
> 同时看 X 和 Y 是否相容，只换 A 或只换 B 都是掷硬币。**
> 作者能跑，不是因为他的包里藏了什么魔法，是因为他的 A 和 B 恰好合得上。

**出现版本**：alpha.66 起（文案更新）
**定性**：2026-09-22 对照作者入库产物查证
**当前状态**：查清卡点，**不投入修复**；文案改为给出"该怎么试"的指引

---

### Bug 472：Web 预览比 APK 构建还慢——两条路径的瓶颈根本不在同一层（2026-09-20，评估）

**现象**（用户实测）："apk 6 分钟就好了，web 要十多分钟。"

这个对比**反直觉**：APK 要过 AOT（`gen_snapshot`）、Gradle、R8、
资源编译（aapt2）——一堆重活；web 只是 DDC 编译 Dart 代码。为什么
更重的那条路反而更快？

**原因：两者被 QEMU 翻译的"代码量"差异极大。**

先明确 FOA 的 x64 兼容层在做什么：Flutter 官方**没有** linux-arm64 版
工具链（`artifacts.dart` 里挂着 `flutter/flutter#152281` 的 TODO），
所以 `bin/cache/dart-sdk/bin/dart`、`linux-arm64/gen_snapshot` 这些
都是 **x86_64 ELF**，靠转发脚本进 qemu-user 跑（见
`lib/toolchain/qemu_compat.dart`）。**所有 Dart 层工具都是被翻译执行的。**

于是关键差别在"谁在被翻译"：

| | APK 构建 | Web 预览 |
|---|---|---|
| Dart 前端（kernel 编译） | 走一次 | 走一次 |
| **后端编译** | **`gen_snapshot`**（x64，**被 qemu 翻译**） | **DDC `dartdevc`**（Dart 写的工具，**同样被 qemu 翻译**） |
| 后端产物的"体量" | AOT 快照，一次成型 | **DDC 按模块产出一堆 `.js` + `.map`，逐模块翻译** |
| Gradle/R8/aapt2 | 有，但**是 JDK 生态，非 dart** | 无 |
| 首次编译的静默期 | 有日志 | **完全无日志**（Bug 454 已记录） |

**核心洞察**：DDC 是**为开发期增量编译设计的**，它把应用切成大量
细粒度模块分别编译，每次还要产出 source map、保留调试信息。
这个"细粒度 × 带调试信息"的组合，在被 QEMU 逐条翻译时**放大了**
——模块数量多、每个模块都要起一次编译动作、还有大量元数据 I/O。
而 `gen_snapshot` 是**一次性的整体编译**，虽然单次重，但架不住
"次数少"。

换句话说：**APK 那条路赢在"后端只干一次"，web 这条路输在
"后端要干很多次、每次都过 QEMU"**。Gradle/R8 那些重活是在
JVM 里跑的**宿主原生代码**，根本不经过 qemu 翻译——所以它们
并不像看上去那么贵。

**已有的正确认识**（`Web预览预热收益评估.md`，alpha.62 周期）：
"预热一个空白项目复用产物"**不成立**，因为 DDC 产物
是项目专属的、不可互换（只引擎运行时那 ~8% 可复用，且那部分只是
`cp`）。这个结论依然有效。

**本轮补充**：那份评估里"引擎运行时 ~8% 可复用"的估算，
**方向对但归因可以更准**——真正的可复用面比 8% 更小，因为
DDC 产物里的模块引用是硬编码路径的，混用会直接运行时报
"找不到模块"。**结论不变，但"不做"的理由更硬了。**

**解决**：本轮**不改实现**，只把三件事写清楚（避免下一轮再走弯路）：

1. **不要试图靠 proroot 提速 web 预览**。proroot 优化的是
   **容器层**（`LD_PRELOAD` 路径翻译替代 ptrace 的两次上下文切换）；
   而 web 预览的瓶颈是 **QEMU 指令翻译**——这两层在栈上完全不相干。
   UI 文案已经写对了这一点（"proroot 一点不改善这两项"），保留。
2. **真要提速，唯一有量级收益的方向是改掉"每次重新构建"这个设计**
   —— 接 VM Service 做真正的 hot reload（增量 patch 而不是整包重编），
   那是另一个量级的工程。
3. **短期可做的仍是那两项**（`pub get` 复用、`--profile` 实测），
   合计预期远不足以让"十多分钟"变成"一两分钟"，**不要在 UI 上
   暗示用户会变快**。

**验证**：本次为评估，无代码改动；结论记入本条目与
`Web预览预热收益评估.md` 的交叉引用。

**通用教训**：**比较两条性能路径之前，先确认它们的瓶颈在不在同一层**。
"更重的构建更快"这种反直觉现象，几乎总是因为——
**你以为的重活根本没在慢的那一层上**。APK 的重活在 JVM（宿主原生），
web 的重活在 Dart（经 QEMU 翻译）——只有后者付翻译税。

**出现版本**：alpha.57（web 预览引入）起一直如此
**修复版本**：本轮不修（评估澄清）

---

### Bug 471b：终端里 `wget` 能装上、UI 里装不上——下载器从不创建父目录（2026-09-20，alpha.65 修复）

**症状**（用户报）：

> "之前我们在终端里不是可以 `wget` 下载安装成功吗？怎么做成 UI 就不行了。"

真机 UI 报：

```
PathNotFoundException: Cannot open file,
  path = '.../files/rootfs/debian/opt/foa-bin/cloudflared.dl.p0'
  (OS Error: No such file or directory, errno = 2)
```

**先分清 errno**：`errno = 2` 是 **ENOENT（打不开）**，
**不是句柄失效**。如果是"文件被别的分片删了、句柄还拿着"，
报的会是 `File closed` 之类。所以这个报错的含义是——
**那个文件连同它的父目录，在 `open()` 的那一刻都不存在**。

这一点直接把排查方向从"竞态"拉到了"目录不存在"。**errno 是这里
最有价值的线索，不要跳过去**。

**原因**：`downloadMultiSource` **从头到尾没有创建过父目录**。
它把"父目录已存在"当成了**调用方的责任**。

那为什么终端能成功？因为终端里那行命令是：

```bash
mkdir -p <dir> && wget -O <dir>/cloudflared ...
```

——**我们自己把目录建好了**，`wget` 才得以成功。而 UI 走的是
`downloadMultiSource` 这段 Dart 代码，它没有那一句 `mkdir -p`。

更绕的是：`cloudflared_install.dart` 里**确实有** `mkdir -p $dirPath`，
所以乍看"代码是建目录的"。但它在**下载成功之后的落位步骤**里
（step ③），而失败发生在**下载**（step ②）——**时序上晚了一步**，
目录还没建，下载先挂了。

**解决**（`lib/toolchain/sdk_downloader.dart`）：让**下载器自己**
保证父目录存在（幂等，已存在则 no-op）：

```dart
final parent = Directory(File(savePath).parent.path);
if (!await parent.exists()) {
  await parent.create(recursive: true);
}
```

位置在分片区间计算**之前**，这样无论走分片还是整文件兜底路径
都已经有目录。

**为什么修在下载器里、而不是在调用方补一句 `mkdir`**：
这类"把前置条件推给调用方"的写法**在本项目里已经坑过多次**
（Bug 464 的 gradle 读写不对称是同一类）。下载器的契约应该是：
**给它一个路径，它负责把文件放进去**——不需要调用方先替它铺路。
调用方越少知道下载器的内部前提，就越不容易漏掉。

**验证**：真机复现路径 —— UI 点「安装 cloudflared」，
容器内 `/opt/foa-bin/` 目录**预先删除**，安装仍应成功。

**通用教训**：**"终端里能跑"不等于"代码里该能跑"——要问"终端里
我做对了哪件代码没做的事"**。终端命令往往把好几个隐含前提
（`cd` 到某处、目录已建、环境变量已设）**显式写在同一行里**，
而代码里这些前提是**隐式**的，只有写的人知道。用户报
"终端能、UI 不行"时，**最高效的动作是把终端那行命令逐段拆开，
找出哪些段落在代码里没有对应物**。

**出现版本**：alpha.60（cloudflared 接入）～ alpha.64
**修复版本**：v0.1.0-alpha.65

---

### Bug 473：终端手工起的隧道公网访问 502——隧道通，但 8977 上没人听（2026-09-21，工具补齐）

**症状**（用户实操）：在真机终端里手工装好 cloudflared 并起隧道，
日志**一切正常**：

```
Your quick Tunnel has been created! Visit it at:
https://position-there-blank-absent.trycloudflare.com
Registered tunnel connection connIndex=0 ... location=lax10
```

但用这个地址访问，返回 **502 Bad gateway**。

**先纠正一个误判**：用户以为"cloudflared 下载又失败了"。**并没有**——
`Length: 37466252` 与保存字节数一致、`--version` 正常输出、
隧道注册成功。**下载和隧道两条都是好的。**

**502 的含义**：Cloudflare 把请求**送到了**你手机，但**回源失败**
（手机上的 cloudflared 连不上 `127.0.0.1:8977`，或那里没人应答）。
502 是"路通了、目的地没人"——**不是**"路不通"。

**原因**：`8977` 是 **App 进程内的 MCP 服务**
（`McpServer`，`HttpServer.bind(InternetAddress.loopbackIPv4, 8977)`），
它**只在 App 里点「远程协助 → 启动隧道」时才被拉起**。

而 UI 那条路的启动顺序是**三步**（`tunnel_service.dart`）：

| # | 步骤 | 手工做时 |
|---|---|---|
| ① | `McpServer.I.start()` → 绑 8977 | ❌ **漏了** |
| ② | `CloudflaredInstall.ensure()` → 下载 | ✅ 做了 |
| ③ | `cloudflared tunnel --url ...` | ✅ 做了 |

手工只做了 ②③。**隧道起来了，但回源目标是个空端口。**

> **这件事的普遍性**：cloudflared 只负责"把公网请求转给 8977"，
> 它**不检查** 8977 上有没有人。所以"隧道建好了"这个信号，
> 完全不蕴含"服务可用"。两个独立的东西，日志里看不出区别。

**解决**：新增 `tools/foa-sh-mcp.sh` —— **纯 shell 的终端版 MCP 服务**，
补上那个缺口。它提供与 App 版**同名同参数**的 7 个工具
（`foa_info` / `foa_diag` / `run_command` / `read_file` / `write_file` /
`list_dir` / `list_projects`），走同一套 MCP 协议。

为什么是 shell 而不是别的：容器 rootfs 是 **Debian minbase**，
**没有 python3、没有 socat、没有 curl**（只有 wget）。能用的只有
POSIX sh + coreutils + `nc`。

**开发中实测踩到的三个坑**（都写进了脚本注释，别删）：

| # | 坑 | 现象 | 修法 |
|---|---|---|---|
| 1 | `nc -l` 遇 stdin EOF 立刻退出 | 客户端发完请求半关闭写端 → nc 死 → 响应发不出去 → `Empty reply from server` | 用 **FIFO 撑住 nc 的 stdin**，并持有读端 fd |
| 2 | "处理完再挂下一个监听"有空窗 | ~1s 窗口内端口没人听 → 连发的第 2 个请求 `Connection refused`，表现为"**第一个成功、后面全失败**" | **先挂下一个 listener，再处理当前请求** |
| 3 | JSON 转义未还原 | `write_file` 写出字面量 `\n` 而不是换行（`od -c` 实锤） | 参数统一过 `json_unescape`；**先还原 `\n`、最后还原 `\\`** |

**已知局限**（脚本头部如实写明，不藏）：

- **同一时刻只服务一个连接**——实测 3 并发只有 1 个成功，另 2 个
  `Connection reset by peer`。顺序请求没问题（连发 10/10 全过）。
  MCP 客户端通常是顺序发的，所以正常用法不会暴露。
- 不支持 chunked / keep-alive；参数解析只认扁平 JSON；
  **没有 App 版那套单飞锁与审计日志**。

**它是应急/排障通道，不是 App 版的替代品。**

**验证**：新增 `test/foa_sh_mcp_test.dart` **15 项** ——
shell 语法（dash+bash）门禁、上述三个坑的防回归断言、
协议契约（端口/路由/鉴权/202/工具清单/isError/黑名单）、
以及"文档与实现不许打架"（说了不并发就必须真写着）。
另在沙箱里做了**真实端到端实测**：健康检查、鉴权 401、
`initialize` / `notifications/initialized` / `tools/list` / `tools/call`
全序列、文件读写（`od -c` 验字节）、黑名单拦截、连发 10 次全过。

**通用教训**：**"隧道建好了" ≠ "服务可用"。** 隧道是**传输层**，
它只保证"公网包能到这台机"；服务是**应用层**，"这个端口有没有人应答"
是另一回事。日志里所有信号都来自传输层，所以**传输层全绿也可能是
端到端全挂**——必须从**外部**真的发起一次请求才算验证过。
（这条与 Bug 466「探测通过 ≠ 能下完」是同一族：**间接信号不能替代
端到端验证**。）

**第二条教训**：**"手工在终端能跑通"和"产品里能跑通"是两条路径，
别假设前者蕴含后者。** 本 Bug 里用户手工做了 ②③、漏了 ①，
而 ① 恰好在 UI 里是自动的。手工验证时要问自己：
**"我这一步，产品里是由谁负责的？"**——Bug 471b 也是同一个形状
（终端那行 `mkdir -p` 是手工补的，UI 里没人补）。

**出现版本**：alpha.60（远程接管引入）～ 今
**修复版本**：本轮补齐工具（`tools/foa-sh-mcp.sh`）

---

### Bug 474：终端版 MCP 脚本"语法全过、实测全错"——四个坑串成一条链（2026-09-21，工具修好）

**背景**：写 `tools/foa-sh-mcp.sh`（见 Bug 473）时，`sh -n` / `bash -n` /
`dash -n` **三个 shell 语法检查全部通过**，但真跑起来**四个问题同时爆**，
而且症状互相掩盖、极难定位。

**总教训（先说最重要的）**：**语法通过 ≠ 能工作。这一轮我在这句话上
栽了四次。** 每个坑单独看都很小，但它们的**表征全是"响应为空/超时"**，
从表象完全无法区分——只能逐层带 `-x` 剥开。
**凡被执行的脚本，必须真发一次请求才算验证过**（已写成单测守住）。

---

#### 坑 1：`--serve-one` 分流的位置——"尽早"不是"最靠前"

**症状**：`run_single_connection: not found`。

**原因**：shell 解析 `if ... fi` 这个**复合命令**时会**整体读入**。
我为了"尽早分流"把它放在文件最前面，此时函数尚未定义 → 找不到。
（shell 确实是"执行到才解析"，但**解析粒度是整个复合命令**，
不是单条语句。）

**第二次踩**：移到文件**最底部**（紧贴函数定义之后，看着很自然）——
函数是有了，但**启动横幅 + 挑监听器**在它前面先跑。socat 拉起的
每个子进程都会：① 打印一遍横幅（日志刷屏）；② 走到"挑监听器"
**卡住不处理连接** → `curl: Operation timed out with 0 bytes received`。

**唯一正确位置**：**函数定义之后 ∩ 横幅之前**。这两个条件之间只有
一个位置。

**教训**：**"尽早"指的是"在不需要的逻辑之前"，不是"在文件最前面"。**
判断这类顺序问题要问：**"这段代码依赖什么已经就位？"**（函数已定义）
+ **"什么不该在它之前跑？"**（横幅/监听器）。

---

#### 坑 2：参数名两端不一致——`cmd` vs `command`

**症状**：`run_command` 返回**空输出 + exit=0**，看起来"成功"；
黑名单**永远命中不了**（`rm -rf /` 直接放过）。

**原因**：脚本里写 `json_str_field "$body" "cmd"`，而 App 版
（`mcp_server.dart` 第 471 行）和 `tools/list` 声明里都是 `command`。
客户端发 `command` → 脚本取 `cmd` → **永远拿到空串** →
`/bin/sh -c ""` → 空输出、退出码 0。

**为什么难查**：它**不报错**。返回的是"成功的空结果"，
而空结果在终端工具里太常见了（命令本来就是 `true`？路径不对？
权限问题？），不会第一时间怀疑参数名。

**修法**：参数名与 App 版**逐字对齐**；并加一条**空 command 直接拒绝**，
让同类错误下次立刻暴露而不是静默。

**教训**：**同一个协议在两个实现里出现两个名字，是 bug 的温床。**
凡是"跨语言/跨进程复述一份契约"的地方（工具名、参数名、字段名），
必须有一处**权威**并写测试锁住（本项目的做法：以 `mcp_server.dart`
为准，脚本跟着它，单测断言两边一致）。

---

#### 坑 3：字段抽取用 `[^"]*` → 在转义引号处**静默截断**

**症状**：`write_file` 写 `a\nb\tc\"d\\e`，落盘只有 9 字节里的前 7 个
（`a\nb\tc\`），**`d\e` 整段丢失**。

**原因**：原来用

```sh
grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
```

`[^"]*` 遇到**转义的引号** `\"` 就停了 —— 它不区分"这个引号是
内容的一部分，还是值的结束符"。于是整个值的后半段**在进入
`json_unescape` 之前就已经没了**。

**为什么难查**：内容"只是短了点"，而且 `json_unescape` 那一层
看起来逻辑是对的（我还专门为它写了转义顺序的注释与测试）。
**我花了很久在 `json_unescape` 里找，实际错在它上游一步。**

**修法**：改成 awk 逐字符扫描，**显式区分转义引号与结束引号**。

**教训**：**正则的"否定字符类"处理不了"带转义的同种字符"。**
只要数据里可能出现 `\"`，`[^"]*` 就一定是错的。
排查这类"内容被截断"问题时，要在**每一层之间**都看一眼长度
（`od -c`），不要只在最终产物上看——**错在哪一层，
和错在哪个函数，经常不是同一个地方。**

---

#### 坑 4：索引偏移 `p + klen + 1` → 全部字符串字段变空

**症状**：修完坑 3 后，`method` 变成空串，启动日志打印
`→  (id=3)`，所有请求都回 `不支持的方法：`。

**原因**：`pat = "\"" key "\""`，**含两侧引号**，长度是 `klen + 2`。
而我把下一个字符的位置写成 `p + klen + 1` —— 那停在 **key 的收尾
引号**上，不是冒号。于是 `!= ":"` 判定失败 → `continue` →
函数**返回空串**。

**修法**：`q = p + klen + 2`。

**为什么难查**：`method` 空 → 报"不支持的方法"，
**看起来像协议解析问题**（客户端发的 body 有问题？）
而不是"字段抽取函数算错了下标"。

**教训**：**`index()` 的下标算法要把"匹配串本身有多长"算进去。**
写 `index()` + `substr()` 组合时，始终问：
**"p 指向的是匹配串的第一个字符，那么匹配串占据 [p, p+len-1]，
下一个字符是 p+len。"** 差一在这里不是差一点，是差全部。

---

**四个坑的共同形状**：

| 坑 | 表层症状 | 真实位置 | 为什么难定位 |
|---|---|---|---|
| 1 分流位置 | `not found` / 超时 | 代码顺序 | 语法检查全过 |
| 2 参数名 | **空输出但 exit=0** | 跨实现的契约 | 不报错，像"成功" |
| 3 转义截断 | 内容短了一截 | 抽取层（非还原层） | 往错误的函数里找 |
| 4 索引偏移 | **全部字段为空** | 下标算术 | 症状像"协议错" |

**它们全部满足**：**语法检查通过、不抛异常、表征收敛到"响应为空"。**
这就是为什么必须**真发起一次请求**、并且**逐层看中间值**。

**落地**：`app/test/foa_sh_mcp_test.dart` 从 15 项增到 18 项，
把这四个坑**各写一条断言钉住**（含"索引必须是 +2 不是 +1"
和"参数名必须是 command"这种精确到字符的检查）。

**出现版本**：本轮开发中（未出包）
**修复版本**：本轮

---

### Bug 475：构建静默挂死 26 分钟 —— 代理黑洞 + "清空重建"误伤框架仓库（2026-09-21，出包受阻）

**症状**：`flutter build apk --release` 输出停在

```
Running Gradle task 'assembleRelease'...
```

然后**再无任何输出**。不是报错，不是超时，就是**不动了**。
实测挂满 **26 分钟**，期间：

| 指标 | 观测值 | 含义 |
|---|---|---|
| 4 个 JVM CPU | **全部 0.0%** | 不是在算，是在等 |
| 内存 | 3.78 / 8 GB | **远未到顶 → 排除 OOM** |
| 中间产物 | 0 个 | 连配置阶段都没走完 |

**第一反应是错的**：我以为是 `gradle.properties` 里那套 OOM 老问题
（Bug 469），因为症状"没输出"很像 daemon 被杀。但 `memory.events`
没有 `oom_kill`、内存峰值离上限很远——**排除**。

**真正的手段：线程栈。** 卡住时抓 `jstack`：

```
"Daemon worker" ... java.lang.Thread.State: WAITING
  at sun.nio.ch.NioSocketImpl.timedRead
  at sun.security.ssl.SSLSocketInputRecord.readHeader
  at org.apache.http.impl.execchain.MainClientExec.execute
  at org.gradle.internal.resource.transport.http.HttpClientHelper.performHttpRequest
  at ...DefaultExternalResourceArtifactResolver.downloadByCoords
  at ...DefaultMavenPomMetadataSource.create
  at ...ExternalResourceResolver.resolveStaticDependency
```

**结论一目了然：卡在一个 HTTPS 请求上**，而且是在解析依赖元数据。

**根因**：沙箱把三个上游仓库解析到了代理黑洞网段 `198.18.0.x`：

```
dl.google.com            → 198.18.0.21
repo.maven.apache.org    → 198.18.0.24
plugins.gradle.org       → 198.18.0.25
```

**TCP 层能连上，但 TLS 握手后永不返回数据。** 不是"拒绝"、不是"超时"，
是**挂住**。Gradle 默认没有针对这种"连上了但不回包"的超时，
于是无限等下去。`ss -tnp` 能看到 java 进程开着到 `198.18.0.21:443` 的
ESTAB 连接，一直不动。

`198.18.0.0/15` 是 RFC 2544 保留网段（基准测试用），被代理软件拿来做
透明转发——**解析到它就说明流量进了代理，而代理没把这个域名接上**。

---

#### 修复过程：两层，缺一不可（第一层单独上反而更糟）

**第一层：让死域名快速失败。** 把黑洞域名指向 `127.0.0.1`
（写进 `~/.user_hosts`，因为 `/etc/hosts` 工作区重启会被还原）：

```
127.0.0.1 dl.google.com
127.0.0.1 repo.maven.apache.org
127.0.0.1 plugins.gradle.org
```

效果：从"挂 26 分钟"变成"**8 秒失败**"。**但构建仍然不过**——
因为失败信息暴露了下一层问题：

```
Could not resolve com.android.tools.build:gradle:8.13.1
  > Could not get resource 'https://dl.google.com/.../gradle-8.13.1.pom'
    > Connect to dl.google.com:443 failed: Connection refused
```

而这两个 artifact **明明已在本地缓存**（pom / module / jar 都在）。

**第二层：摘掉死仓库（但绝不能 clear）。** 项目原本已有
`~/.gradle/init.gradle`（Sep 17 写的，只**前插**阿里云镜像）。
前插不够——项目自己声明的 `google()` 仍在列表末尾，Gradle 没命中镜像
就继续去试它。所以要把死仓库**从列表里摘掉**。

> ⚠️ **这里我踩了本 Bug 最值钱的一跤**：第一版我写的是
> `repositories.clear()` 然后重建为纯镜像。看着更"干净"，结果报：
>
> ```
> Could not resolve io.flutter:arm64_v8a_release:1.0.0-06a2e2a...
> ```
>
> **Flutter 插件会往 `rootProject.allprojects` 注入引擎仓库**
> `$FLUTTER_STORAGE_BASE_URL/download.flutter.io`
> （见 `FlutterPlugin.kt` 第 100 行）。`clear()` 把它一起清掉了——
> 而那个 artifact **只在 Flutter 自己的仓库里有，任何公共镜像都没有**。
>
> **教训：「清空重建」看着干净，实则会误伤框架注入的仓库。**
> 正确姿势是**精确摘除已知不可达的几个，其余原样保留**。

最终修法（`~/.gradle/init.gradle` 追加）：

```groovy
def deadHosts = ['dl.google.com', 'repo.maven.apache.org', 'repo1.maven.org',
                 'plugins.gradle.org', 'jcenter.bintray.com']
def stripDeadRepos = { repos ->
    repos.removeAll { r ->
        def u = (r.hasProperty('url') ? r.url?.toString() : '') ?: ''
        deadHosts.any { u.contains(it) }
    }
}
allprojects { p ->
    // 子项目 buildscript（url_launcher_android 这类插件自带 google()）
    p.buildscript.repositories { repos ->
        stripDeadRepos(repos)
        repos.maven { url 'https://maven.aliyun.com/repository/public' }
        // ... 其余三个阿里云镜像
    }
    p.afterEvaluate { stripDeadRepos(p.repositories) }
}
```

结果：**102 秒构建完成**（对比挂死 26 分钟）。

---

#### 第三个坑：我自己的 `pub get` 污染了 `pubspec.lock`

排查途中我跑了一次**没带 `PUB_HOSTED_URL`** 的 `flutter pub get`，
把 `pubspec.lock` 里 **59 处** `pub.flutter-io.cn` 全改成了 `pub.dev`
（而 `pub.dev` 在本沙箱同样不可达）。这一度让我误判"是依赖版本漂移导致
url_launcher_android 升级"。

**教训**：`pubspec.lock` 是**锁定文件**，跑 `pub get` 前务必确认镜像
环境变量已设；一旦被改写，用 `git checkout pubspec.lock` 还原，
不要顺着它的差异去分析——那是自己制造出来的噪声。

---

**通用教训**：

1. **"没输出"要先分清是"在算"还是"在等"。** 判据是 CPU 与中间产物：
   CPU 0% + 产物不增 = 在等。**别凭症状像什么就下结论**（我第一反应
   猜 OOM，浪费了一轮）。
2. **线程栈是"卡住类"问题的第一手段。** `jstack` 一次就能从
   "不知道为什么不动"跳到"卡在 SSL 读"。**没有栈就别猜。**
3. **"连上了但不回包"比"连不上"难查得多。** 前者无限等、后者立刻报错。
   遇到前者，把域名指向 `127.0.0.1` **把它转成后者**，问题立刻显形。
4. **改仓库配置时，"摘除"优于"清空重建"。** 框架（Flutter/AGP）
   会往你不知情的列表里注入仓库，`clear()` 会连它们一起清掉，
   而报错信息（`Could not resolve io.flutter:...`）完全指不到你的
   `clear()` 上。
5. **别用自己的工具打断构建。** 我用 `timeout 1500` 包了几次构建，
   结果是"构建被杀 + 残留中间产物损坏"（`mergeReleaseJniLibFolders`
   报 `Failed to create MD5 hash`），又引入新噪声。**构建就该在后台跑完。**

**出现版本**：仅影响构建环境（本沙箱），非产品代码
**修复版本**：alpha.65 出包过程

---

### Bug 476：About 页的 proroot 版本停在 v1.2.8 —— 同一事实存两份（2026-09-21，出包验证抓到）

**症状**：出包后做"包里到底是什么版本"的验证，从 `libapp.so` 里
`strings` 出：

```
v1.2.5
v1.2.8      ← 多出来的这个
```

Bug 471 已把钉死版本换成 **v1.2.5**，为什么包里还有 `v1.2.8`？

**根因**：`lib/ui/about_info.dart` 的第三方组件清单里**写死了**版本号：

```dart
AboutComponent(
  name: 'proroot',
  version: 'v1.2.8',     // ← 换版本时漏改这里
  ...
)
```

`ProrootOption.pinnedVersion` 改成了 v1.2.5，About 页那份没人动——
于是**用户看到的版本号与实际下载的版本不一致**，
而且这个不一致只在 About 页可见，**任何测试都不会失败**。

**修法**：不写死，引用唯一真源：

```dart
version: ProrootOption.pinnedVersion,
```

并加一条测试同时钉住两件事：
① 展示值 == 常量值；② `about_info.dart` 里**不存在**写死的版本字面量。

**怎么发现的**：**不是测试发现的，是"包里逐字节核对"发现的。**
685 项测试当时全绿，`flutter analyze` 也只剩基线——
**这个 bug 对整套自动化是隐形的**，只有真去看产物才暴露。

**通用教训**：**"同一事实存两份"迟早打架。**
Bug 474 的 `cmd`/`command` 参数名是同一个病。
凡"版本号 / 字段名 / 端口 / 路径"这类事实，必须有一处权威，
其余地方**引用**它。判断标准很简单：
**"这个值改动时，我需要改几个地方？"** —— 答案是"不止一个"就有隐患。

**第二条教训**：**出包后的"产物核对"不是走过场。**
这次如果只跑测试 + `verify_apk.sh` 四件套就交付，这个 bug 会直接到用户手上
（而且用户看到的是"版本号对不上"，第一反应会是"你根本没改吧"）。
**测试全绿 ≠ 交付物正确**——测试验证代码逻辑，
产物核对验证"装进去的到底是哪一版"。

**出现版本**：本轮开发中（未出包）
**修复版本**：alpha.65

---

### Bug 477：转义分号在 Dart 单引号串里怎么写 —— 三种写法混在一个文件里（2026-09-22，alpha.67 修复）

**症状**：新写的 `project_importer.dart` 静态契约测试里，
「清扫用 `-exec rm -rf {} \;`」与「去 CRLF + 补可执行位」两条断言
**反复红**，改了三次都对不上。而**运行期完全看不出问题** ——
没有报错、没有异常，`flutter analyze` 只给一条 info 级的
`unnecessary_string_escapes`，很容易被当成噪声划过去。

**原因**：这类转义有两层（Dart 编译一层、shell 解析一层），
**叠加之后很难靠肉眼核对**：

| Dart 源码写法 | analyzer | 求值后的字符串 | shell 看到 | 语义 |
|---|---|---|---|---|
| `'{} \\;'` | 无告警 | `{} \;` | `\;` | ✅ find 要的转义分号 |
| `'{} \;'` | info: unnecessary escape | `{} \;` | `\;` | ✅ 也能跑，但提示误导人 |

两者在**单引号字符串里求值结果相同**（Dart 遇到 `\;` 这种非合法转义
会原样保留反斜杠）。真正的问题是**同批代码里三种同类转义写法各不相同**：

```dart
'-exec rm -rf {} \\; 2>/dev/null; '        // 双反斜杠
'sed -i "s/\\r\$//" ...'                  // \r 双、$ 单
'... -exec chmod +x {} \\; ...'            // 双反斜杠
```

而 analyzer 那条 `unnecessary_string_escapes` 会诱导你以为"单反斜杠
就够了" —— 它说的是"写 `\;` 和写不写反斜杠效果一样"，
**不是**"你该删掉一个反斜杠"。按这个直觉去改，就会在需要双反斜杠的
地方写成单反斜杠，然后测试红、运行期照跑。

**解决**：

1. **统一**：所有要传给 shell 的转义分号一律写 `\\;`，
   并在源码里留注释说明"Dart 单引号串里 `\\;` 才是发给 shell 的 `\;`"。
2. **加断言钉住规则本身**，而不是钉住"我这次写对了"：

```dart
// Dart 单引号串里 `\\;` 才是发给 shell 的 `\;`
expect(src.contains(r'-exec rm -rf {} \\;'), isTrue);
```

3. **补一条不依赖 `find` 的兜底**。写到这一步才发现更值得担心的事：
   真机上 `tar`/`find` 来自 **toybox/busybox**，`-exec ... \;`
   的支持并不统一。所以 `sweepStale()` 里补了两条能独立完成清理的路径：

```dart
'find ... -exec rm -rf {} \\; 2>/dev/null; '
'rm -rf <stagingRoot>/<prefix>* 2>/dev/null; '
'rmdir <stagingRoot> 2>/dev/null; '
```

三条路通一条即可清理成立；最后 `rmdir` 只在目录真空时成功，安全。

**验证**：`flutter test test/import_export_project_test.dart` **63 项全绿**；
其中「去 CRLF + 补可执行位」与「清扫用 `-exec rm -rf {} \\;`」
两条直接钉住这两个转义。另用 Python 逐字符 dump（`hex(ord(ch))`）
确认源码里确实是两个 `0x5c`。

**通用教训一**：**当同一类写法在一个文件里出现三种变体时，
说明没人真正搞清哪一种是"对的"。** 这时候该做的是查清规则并统一，
而不是逐条试到测试变绿 —— 试绿的后果是测试钉住的是
"我这次写对了"，不是"规则是什么"，下一个人照样会写错。

**通用教训二（更重要）**：**analyzer 的 info 级提示里藏着重灾区。**
`unnecessary_string_escapes` 读起来是"你多打了个反斜杠，删掉更干净"，
但**跨语言边界（Dart → shell）的转义不适用这个直觉** ——
删掉之后语义可能就变了。这类"info 级告警 + 跨语言语义"的组合，
值得比 error 更认真对待，因为**它不会拦住你**。

**通用教训三**：**这轮 63 条测试里，最有价值的不是"验证功能能跑"
（那本来也验不了），而是这种"改错时不报错、只是行为不对"的契约。**
`unzip -C` 是"忽略大小写"而不是"解压到目录"、`--exclude` 放在 `-C`
之后会被当成文件名、`unzip -n` 遇同名静默跳过后**谎报成功** ——
这三个坑**全都不报错**。静态契约测试是唯一能在沙箱里拦住它们的东西。

**出现版本**：本轮开发中（未出包）
**修复版本**：alpha.68

---

### Bug 478：模板卡片的「需Git」压住了模板名 —— `Badge.label` 是 overlay，不占布局（2026-09-22，alpha.69 修复）

**症状**：创建工程面板里，五张非空白模板的图标右上角有个「需Git」小标签，
它**右溢压到了相邻的模板标题首字上**（用户截图标注：「创建项目界面 git 与字重合」）。
「Flutter 官方 Demo」被压成「**需Git**lutter 官方 Demo」的样子。

**根因**：写的是 Flutter 官方的 `Badge`：

```dart
Badge(
  label: const Text('需Git', style: TextStyle(fontSize: 9)),
  isLabelVisible: t.needsGit,
  child: Icon(t.icon, size: 26, ...),
)
```

`Badge` 的内部实现是 `Stack` + `Positioned`：

```dart
Stack(children: [
  child,
  if (isLabelVisible)
    Positioned(
      top: .., end: ..,                 // alignment: AlignmentDirectional.topEnd
      child: _Badge(...),               // 默认 offset: Offset(4, -4)
    ),
])
```

`Positioned` 在 `Stack` 里**脱离常规布局**，`Badge` 的尺寸就是
`child` 的尺寸（26dp 的图标）。那个 4 字小标签按 `topEnd` 对齐往右上方
**溢出到 child 边界之外**——它不占位、不撑大父容器、不触发换行，
只是**画在外面**。于是正好盖住 `Row` 里的下一个孩子（模板标题）。

**为什么看代码看不出来**：`Badge` 的 API 长得像"给图标加个角标"，
读起来完全合理。`Positioned` 不参与布局这件事**不会报任何错**、
不会 overflow 警告（`Stack` 默认 `clipBehavior: Clip.hardEdge` 只裁剪，
不告警）。**只有真机截图能发现。**

**修法**：换成占布局的普通组合——图标在上、「需Git」标签在下，
纵向排列。标签挤占的是自己那一格的横向空间（26dp 图标改 24dp
后竖排更窄），不再越界。

```dart
Column(mainAxisSize: MainAxisSize.min, children: [
  Icon(t.icon, size: 24, ...),
  if (t.needsGit) ...[const SizedBox(height: 3), const _NeedGitTag()],
])
```

`_NeedGitTag` 另用 `warningContainer` / `warningBorder` / `warning`
三个语义位（原先写死 `0x33FFB74D` / `0xFFFFB74D`，浅色主题下对比度不足）。

**通用教训（这条比 bug 本身有用）**：
**凡是"X 压住了 Y"的报障，第一个要查的是 X 是不是浮层。**
候选名单：`Positioned` / `Stack` 里的非 positioned 孩子 /
`Overlay` / `Badge.label` / `Tooltip` / `Transform` /
`CustomPaint` 画到边界外 / 负 `margin`。
这些的共同点是**不参与常规布局**，所以 `Row`/`Column` 完全不知道
它们存在，该换行时不换行、该缩时不缩。

判断方法：把 X 那层临时换成 `Container(color: red)`——
如果红色块只有 child 那么大、标签是"飘在外面"的，
那就是浮层，改 `Row`/`Column` 的参数一律没用。

**出现版本**：alpha.24 起（Step 8 引入「需Git」角标）
**修复版本**：alpha.69

---

### Bug 479：主题三档的「跟随系统」折成两行 —— 分段控件里 4 个字装不下（2026-09-22，alpha.69 修复）

**症状**：设置页「主题模式」的 `SegmentedButton` 里，第三档显示为
「跟随
系统」两行，与左右两档（「浅色」「深色」各 2 字、单行）视觉不齐。
用户报障：「部分卡片内字分行不好看」。

**根因**：`SegmentedButton` 与 `expandedInsets: EdgeInsets.zero` 配用时，
**三档等分宽度**——每档约 `(屏宽 - 卡片内边距) / 3`。
「跟随系统」4 个字（含两侧 icon 18dp + 间距）需要的宽度超出这一格，
`Text` 就按默认行为折行了。

**为什么不能靠"调小字号"解决**：字号降到能单行放下的程度
（大约 10sp）会比左右两档明显小一号，反而更不齐。
**这不是度量问题，是文案长度问题。**

**修法**：文案 `跟随系统` → `系统`。三档合起来仍读作
「浅色 / 深色 / 系统」，语义不变（`ThemeMode.system` 的中文惯例
就是「跟随系统」，但在空间受限的分段控件里「系统」不会歧义）。
另给三个 label 都补 `maxLines: 1, overflow: TextOverflow.ellipsis`
作为兜底——将来字体放大或本地化变长时，宁可省略号也不要静默折行。

**通用教训**：**在"等分宽度"的容器里，文案长度是最窄那一档的约束。**
`SegmentedButton` / `TabBar`（非 scrollable）/
`BottomNavigationBar` / 固定列数的 `GridView` 都属此类。
往这类容器里放文案前先问一句：**"最长的那一档放得下几个字？"**
放不下就**改文案**，别改度量——度量一改就跟相邻档不齐了，
而"不齐"比"字少"更显眼。

配套地，本轮还顺手把「外部 → 容器」按钮（`OutlinedButton.icon`
默认左右内边距各 16dp + icon-label 间距 8dp）的水平内边距收到 8dp、
字号降到 12，让完整文案单行容纳——**这次是度量问题**，
因为按钮不是等分对齐的，改内边距不影响与谁对齐。

**出现版本**：alpha.61 起（设置页改版时引入三档分段控件）
**修复版本**：alpha.69

---

### Bug 480：About 卡片把版本号折在中间 —— `ListTile.subtitle` + 手动 `\n` + `isThreeLine`（2026-09-22，alpha.69 修复）

**症状**：设置页「关于」卡片的副标题显示成：

```
v0.1.0-alpha.68+68 · 作者 hao
thtrteen
引用了 12 个第三方项目
```

版本号没断，**作者名断了**；而用户的第一眼观感是"版本号那行排版事故"。

**根因**：副标题是一整段拼接串 + 手动 `
`：

```dart
subtitle: Text(
  '${AboutInfo.version} · 作者 ${AboutInfo.author}\n'
  '引用了 ${AboutInfo.components.length} 个第三方项目',
  style: const TextStyle(fontSize: 12, height: 1.4),
),
isThreeLine: true,
```

`ListTile` 在位 `isThreeLine: true` 时给 subtitle 的**高度是固定的**，
但不控制**断点**。拼接串里手动 `
` 只保证"这里是硬换行"，
不保证"这一段放得下"——第一段
`v0.1.0-alpha.68+68 · 作者 haothtrteen` 在副标题可用宽度里放不下，
于是在 `hao` 与 `thtrteen` 之间**再折一次**，变成三行。

**修法**：拆成两个独立 `Text`，各占一行、各带 `maxLines: 1` +
`overflow: ellipsis`；去掉 `isThreeLine`（subtitle 只吃两行）：

```dart
subtitle: Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    const Text(AboutInfo.version, maxLines: 1, overflow: TextOverflow.ellipsis, ...),
    Text('作者 ${AboutInfo.author} · 引用了 ${AboutInfo.components.length} 个第三方项目',
         maxLines: 1, overflow: TextOverflow.ellipsis, ...),
  ],
)
```

**Dart 语法坑（写到这才发现）**：这一对 `Text` **不能都加 `const`**。
第一条能（`AboutInfo.version` 是 `const String`），
第二条不能——`AboutInfo.components` 是 `List`，
`.length` **不是常量表达式**，`const` 化会报：

```
error - The property 'length' can't be accessed on the type
'List<AboutComponent>' in a constant expression. - const_eval_property_access
```

反过来，如果两条都不加 `const`，analyzer 又会给第一条
`prefer_const_constructors`。所以这里**必须混用**，
且最好留一句注释说明"别顺手统一"。

**通用教训**：**手动 `
` 拼接的文案，断点是不可控的。**
`
` 只声明"我要在这里换行"，不声明"这一段一定放得下"。
凡是"已知长度的字段 + 已知长度的字段"拼一行，都该拆成
**独立的 `Text` + `maxLines`**，让每个字段自己决定是被省略
还是完整显示，而不是让渲染器在某个字段中间随机折断。

**出现版本**：alpha.61 起（关于卡片改版时引入）
**修复版本**：alpha.69

---

### Bug 481：工程列表和顶栏两个 🔄 —— 两个按钮覆盖的功能范围不同却长得一样（2026-09-22，alpha.69 修复）

**症状**：主页「工程」标签下，标题行右侧有一个 🔄（tooltip「刷新工程列表」），
顶栏 AppBar 右侧也有一个 🔄（tooltip「重新检测」）。用户报障：
「工程主页卡片和顶栏有两个刷新🔄按钮应去掉一个」——
**两个都有 tooltip，但手机上没有 hover，用户看不到区别。**

**根因**：两个按钮**确实做的是不同的事**：

| 位置 | 回调 | 实际行为 |
| --- | --- | --- |
| 工程标题行 | `_loadProjects` | 只重扫 `/root/projects` 目录 |
| AppBar | `env.refresh()` | 重跑**全套环境检测**（rootfs / 工具链 / 设备信息）+ 内含重扫工程 |

功能上不重复（后者是前者的超集），但**图标完全相同**，
且都在首屏可见 —— 用户没有信息去分辨它们。

**修法**：删掉工程标题行那个。
理由：AppBar 的「重新检测」是**超集**（包含重扫工程），
且它是环境出问题时唯一的恢复入口（必须有）；
工程列表另有 `RefreshIndicator` 下拉刷新，
**删掉这个按钮不减少任何能力**。

**通用教训**：**"功能不重复"不等于"用户能分辨"。**
判断两个按钮该不该并存，不能只比回调函数，
要比**用户能否在 1 秒内说出它们的区别**。
说不出 = 视觉噪音，删一个。

反面做法是"给它们换不同图标/加角标来区分"——
除非两者都是高频操作，否则**减法比加法对**：
需求是"去掉一个"，不是"让它们看起来不一样"。

**另外**：删这类按钮时**必须检查超集/子集关系**。
这次差点删错的是 AppBar 那个（它看起来"更远、更不相关"），
但它是超集；删掉它 = 环境检测失去唯一手动入口。
所以补了一条**反向断言**：

```dart
expect(home().contains('重新检测'), isTrue,
    reason: '删掉它 = 环境检测没有任何手动入口');
```

**出现版本**：alpha.33 起（工程列表改版时引入）
**修复版本**：alpha.69

---

### Bug 482：`unzip -l` 查不到图标 —— release 包会混淆资源文件名（2026-09-22，alpha.69 修复）

**症状**：给 `verify_apk.sh` 新加了第 5 项"图标已应用"，逻辑是遍历
四条预期的资源路径做存在性检查：

```bash
for res in \
  "res/mipmap-mdpi/ic_launcher.png" \
  "res/mipmap-xxxhdpi/ic_launcher.png" \
  "res/drawable-xxxhdpi/ic_launcher_foreground.png" \
  "res/mipmap-anydpi-v26/ic_launcher.xml" \
; do
  echo "$LISTING" | grep -q "$res" || ICON_MISSING="$ICON_MISSING $res"
done
```

跑出来**四项全"缺失"**，直接判红。但那个 APK 明明是刚构建的、
`git status` 里图标资源都改过、手机上装上去图标也对。

**根因**：release 构建**默认会混淆资源文件名**。APK 里实际长这样：

```
res/bB.png   res/yi.png   res/tP.png   res/BM.png   res/CH.png
res/8G.xml   res/BW.xml   res/Zn.xml   res/8K.xml
```

`mipmap-xxxhdpi/` 这层目录名和 `ic_launcher` 这个文件名**都不存在了** ——
AGP 把它们压平成一串短名。**`unzip -l` 的"文件名"字段在 release 包里
没有任何语义**。

唯一稳定的是 `resources.arsc` 里保留的**资源 ID + 逻辑名**，
所以必须换工具：

```bash
aapt2 dump resources "$APK" | grep -E 'resource .* (mipmap/ic_launcher|\
drawable/ic_launcher_foreground|color/ic_launcher_background)$'
```

**顺带发现的第二处**：改完之后想"抽一张图验配色"，
但物理路径同样得从 `arsc` 反查：

```bash
FG_PATH="$(aapt2 dump resources "$APK" \
  | grep -A 8 'resource .* drawable/ic_launcher_foreground$' \
  | grep '(xxxhdpi)' | grep -oE 'res/[^ ]+\.png' | head -1)"
```

**第三处（更隐蔽）**：验配色的采样点坐标。前景层是把内容缩到
中心安全区（`SAFE_SCALE = 0.62`）后画出来的，如果直接拿满幅图的
几何比例（`0.64, 0.455`）去取像素，**会落在透明区域上**，
取到 `000000`（透明黑）—— 又是一次假红。正确写法要做安全区换算：

```python
ox = (1 - SAFE) / 2
px = im.getpixel((int((ox + gx * SAFE) * w), int((ox + gy * SAFE) * h)))
```

**通用教训一（可推广）**：**release 包与 debug 包是两种不同的观测对象。**
凡是"从 APK 里按名字找东西"的检查，都要先问一句：
**这个名字在 release 构建后还在吗？** 受影响的范围：
资源文件名（被混淆）、类名/方法名（被 R8）、
Dart 符号（被 tree-shake / AOT）。
**不受影响**的只有：`AndroidManifest.xml` 的显式字符串、
`resources.arsc` 里的资源逻辑名、`lib/*.so` 的文件名、asset 路径。

> 📌 顺便回头看了第 4 项（proroot 合规检查）——它用的也是
> `unzip -l | grep -i proroot`，**在 release 包上却是能用的**。
> 原因：`.so` 文件名不做混淆，且没有哪条无关路径里含 "proroot"。
> **这是碰巧成立，不是设计成立。** 如果将来查的是"某个短字符串
> （如 `abc`）是否入包"，`unzip -l` 就会给出噪声。
> 这条已写进 `fetch_assets.sh` 的注释里提醒后来者。

**通用教训二**：**新加的门禁要拿真实产物试一次，不能只看逻辑对不对。**
这项检查如果没在出包后实跑，就会一直是"看着很对、实际全红"的状态，
而且因为它是**第 5 项**（原先是四件套），很可能被当成
"新加的检查不稳定，先注释掉"处理掉。

**通用教训三**：**假红比假绿更值得警惕。**
假绿会让人放心地交付错东西；假红会让人**不再相信这个检查**，
进而在真出问题时也忽略它。这里连踩三个假红
（文件名混淆 / 路径未反查 / 采样点未换算），
每一个都长得像"图标真的没打进去"。

**出现版本**：本轮开发中（未出包）
**修复版本**：alpha.69

---

### Bug 483：生成代码里 `const` 包着 `Theme.of(context)` —— 编译错误，但字符串测试发现不了（2026-09-22，alpha.70 修复）

**症状**：

「设计」区生成的 Dart 文件，用户放进项目后 `flutter analyze` 报：

```
error • Const variables must be initialized with a constant value
        • lib/generated/design_20260922_160300.dart:31:18
```

但生成器自己的 41 条单测**全绿**。

**原因**：

代码生成器为了"更像手写代码"给文本节点加了 `const`：

```dart
const Text('标题', style: TextStyle(color: Theme.of(context).colorScheme.primary)),
//                                                       ^^^^^^^^^^^^^^^^^^^
//                                                       Theme.of(context) 不是常量表达式
```

关键点：**单测断言的是字符串内容，不是可编译性**。
`code.contains("const Text('标题'")` 是 `true` —— 测试通过，
而这份代码根本编译不过。**字符串级测试天然看不见语法/类型错误。**

**解决**：

生成器按"有没有主题色"决定加不加 `const`：

```dart
final hasThemeColor = _colorOf(node.props['color']) != null;
// ⚠️ 带主题色时**不能**加 const：Theme.of(context) 不是常量表达式
final c = hasThemeColor ? '' : 'const ';
```

并补两条断言把两个方向都钉死：

```dart
test('选了主题色时不能加 const（Theme.of 不是常量表达式）', () {
  expect(code.contains('const Text('), isFalse);
  expect(RegExp(r"const\s+Text\([^)]*Theme\.of").hasMatch(code), isFalse);
});
test('没选颜色时加 const（纯字面量，省对象也更像手写代码）', () {
  expect(code.contains('const Text('), isTrue);
});
```

**更大的教训**：字符串断言只是**便宜的近似**。真正的验证是
**把生成物喂给 `flutter analyze`**。本轮做了一次性验证：

```bash
# 把各模板的生成物临时放进 lib/ 下（有 package resolution），再分析
flutter analyze lib/_gencheck/
# → 0 error，只有 prefer_const_* 级 info
```

> ⚠️ 别把生成物复制到 `/tmp` 再分析 —— 那里没有 Flutter 包解析，
> 会刷出 140 条 `Target of URI doesn't exist: 'package:flutter/material.dart'`
> 这种与生成物无关的假红。

**验证**：`test/design_model_test.dart` 的两条 const 断言通过；
生成物在项目内 `flutter analyze` 零 error。

**出现版本**：本轮开发中（未出包）
**修复版本**：alpha.70

---

### Bug 484：`'$padText('` 被当成标识符 —— 字符串插值后跟字母要加花括号（2026-09-22，alpha.70 修复）

**症状**：

```
Error: Undefined name 'padText'.
    lines.add('$padText(');
                ^^^^^^^
```

连着 10 处同样的错：`padAlign` / `padSizedBox` / `padTextField` /
`padContainer` / `padIcon` / `padListTile` / `padCard` / `padconst`…

**原因**：

Dart 的 `$name` 简写插值**会贪婪地吃掉后续所有标识符字符**：

```dart
final pad = '  ';
'$padText('   // → 变量名被解析成 `padText`，不是 `pad` + `Text`
'${pad}Text(' // ✅ 正确：显式界定变量名边界
```

这和 Bug 483 是同一类问题：**代码生成器本身也会写错**，
而它错的方式是"生成器源码编译不过"（这次还算幸运，直接报错）。

**解决**：

```bash
# 只替换 $pad 后面紧跟标识符字符的情况，不碰 $pad} / $pad, / 独立的 $pad
python3 -c "
import re
s = open('lib/project/design_model.dart', encoding='utf-8').read()
s = re.sub(r'\$pad(?=[A-Za-z_])', '\${pad}', s)
open('lib/project/design_model.dart', 'w', encoding='utf-8').write(s)"
```

**同一个坑在测试里又踩了一次**：

```dart
reason: '直接拼 Icons.$unknown 会生成编译不过的代码');  // ❌ $unknown 未定义
reason: r'直接拼 Icons.$未知名字 会生成编译不过的代码');  // ✅ raw 字符串，不插值
```

写法：**要输出美元符号本身时用 raw 字符串 `r'...'`**。

**验证**：`flutter analyze` 无 `undefined_identifier`。

**出现版本**：本轮开发中（未出包）
**修复版本**：alpha.70

---

### Bug 485：生成的代码嵌套层级"看着是平的" —— 绝对缩进拼不出来，要用相对缩进（2026-09-22，alpha.70 修复）

**症状**：

生成物语法正确、能编译，但**缩进完全看不出一层套一层**：

```dart
return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
      child: Padding(          // ← 比上一行还浅，看着像平级
        padding: const EdgeInsets.all(24),
```

**原因**：

第一版生成器把 `indent` 层级**当参数传下去，各分支自己拼好绝对缩进**：

```dart
static List<String> _build(DesignNode node, int indent) {
  final pad = '  ' * indent;      // 每个分支自己算绝对缩进
  ...
}
```

父节点包裹子节点时又加一次缩进 → **双重缩进**；
而"自动推算该收几层括号"的逻辑碰到
`SafeArea` 里再套 `SingleChildScrollView` 这种多层 open 必然错位。

**解决**：

改成**相对缩进**：各分支返回**不含缩进**的行列表，
嵌套时由父节点统一加一层。层级由嵌套结构本身决定，**不可能算错**。

```dart
/// 递归生成节点代码，返回**相对缩进**（左对齐）的行列表。
static List<String> _build(DesignNode node, {bool asRoot = false}) { ... }

/// 给一组行统一加一层缩进。
static List<String> _indentAll(List<String> lines, [int extra = 1]) {
  final pad = '  ' * extra;
  return lines.map((l) => l.isEmpty ? l : '$pad$l').toList();
}
```

收尾括号也从"自动推算"改成**调用点显式给** —— 调用点最清楚自己开了几层：

```dart
static List<String> _wrap(
  List<String> inner, String open, {
  List<String> args = const [],
  List<String> prelude = const [],
  List<String> epilogue = const [],   // ← 显式给，不让工具猜
  int childDepth = 1,
  String close = '),',                // ← 嵌套用 `),`、语句收尾用 `);`
}) { ... }
```

**顺带修掉的两处"看不出来但影响可读性"的**：
- `children: [` 里的元素要比开括号多缩一层（否则列表项和括号齐平）
- 分号要并进收尾括号（`);`），不能 `;` 独占一行

**验证**：补了缩进断言 —— 光断言"有没有这个字符串"发现不了缩进全平：

```dart
final cardIndent = _indentOf(code, 'Card(');
final textIndent = _indentOf(code, 'Text(');
expect(textIndent, greaterThan(cardIndent),
    reason: '卡片内子节点的缩进必须比 Card 本身更深');
```

**出现版本**：本轮开发中（未出包）
**修复版本**：alpha.70

---

### Bug 486：组件树永远只有一行「页面（N 项）」—— `ListView` 的 children 只给了根节点（2026-09-22，alpha.71 修复）

**症状**：

设计区右侧「组件树」标签页只有一个根行，点它前面的 `>` 展开箭头**没有任何反应** ——
子节点一个都不出现。但预览区渲染得好好的（图标、欢迎回来、邮箱框、登录按钮全在），
说明树里**确实有内容**，只是树面板没画出来。

```
[组件树]
> 页面（11 项）        ← 点箭头，什么也不发生
                       ← 应该是：页面 → Column → Text / TextField / ...
```

**原因**：

`_treeRow(DesignNode node, int depth)` **早就支持递归所需的全部东西**：
`depth` 参数、缩进计算（`6.0 + depth * 14`）、展开箭头、`_collapsed` 折叠状态。
它写得完全正确。

问题出在**调用点**：

```dart
// alpha.70 的 _treePanel —— 错的
Expanded(
  child: ListView(
    padding: const EdgeInsets.symmetric(vertical: 6),
    children: [
      _treeRow(_root, 0),        // ← 只生成了根节点这一个 Widget
    ],
  ),
),
```

`ListView` 的 `children` 是个**扁平列表**，`_treeRow` 返回的又是一个扁平 `Widget`
（它不嵌 `Column`，缩进靠 `depth` 算）。所以字面上"放根节点进去"就等于
"树上只有一个节点" —— **没有任何一层递归去生成子节点的行**。

这是最典型的一类接线漏项：**编译得过、运行时不抛异常、功能静默失效**。
`_treeRow` 的 `depth` 参数成了摆设，`_collapsed` 永远查不到任何 id
（因为能折叠的那些行压根没被创建）。

**解决**：

补一个前序遍历，产出的**扁平行列表**直接展开进 `children`：

```dart
Expanded(
  child: ListView(
    padding: const EdgeInsets.symmetric(vertical: 6),
    children: [
      ..._treeRows(_root, 0),
    ],
  ),
),
```

```dart
/// 前序遍历设计树，返回可直接塞进 `ListView` 的**扁平行列表**。
///
/// 为什么是扁平的而不是嵌套 Widget：`ListView` 只吃扁平 children，
/// 要嵌套就得换成 `Column` + `ListView` 混排，那会丢掉回收能力
/// （树深了卡）。缩进靠 `depth` 算，不靠嵌套。
///
/// ⚠️ 折叠时必须**提前 return**。写成"跳过不画但继续递归"的话，
/// 子节点的行**照样生成**、只是被藏在下一层，展开时行数就对不上、还会重复。
List<Widget> _treeRows(DesignNode node, int depth) {
  final rows = <Widget>[_treeRow(node, depth)];
  if (_collapsed.contains(node.id)) return rows;
  for (final child in node.children) {
    rows.addAll(_treeRows(child, depth + 1));
  }
  return rows;
}
```

同时给缩进加**钳制**：

```dart
padding: EdgeInsets.fromLTRB(6.0 + depth.clamp(0, 6) * 14, 0, 8, 0),
```

> 为什么要钳：alpha.71 加了「导入已有 UI」之后，树的深度**不再可控** ——
> 用户手写的 `build` 里套十层容器很常见。不钳的话 `depth = 20` 是 286px 缩进，
> 手机窄屏上文字直接被挤出屏幕。**只钳缩进、不钳递归**：第 7 层往后的节点
> 照样渲染，只是不再往右挪。

**验证**：

先**只加断言、跑一次确认它红**（证明断言真的是护栏，不是同义反复），
再改实现。三条断言在 `test/design_wiring_test.dart` 的
「设计区 · 组件树真的会展开」组：

```dart
// 1. children 来自递归展开（`..._treeRows(`），不是单个根节点
expect(RegExp(r'\.\.\._treeRows\(').hasMatch(page), isTrue);
expect(RegExp(r'children:\s*\[\s*_treeRow\(').hasMatch(page), isFalse);

// 2. 折叠必须提前 return（正则精确匹配，不是"跳过不画"）
expect(RegExp(r'if \(_collapsed\.contains\(node\.id\)\)\s*return rows;')
    .hasMatch(body), isTrue);

// 3. 缩进有钳制
expect(page.contains('depth.clamp('), isTrue);
```

改完 17/17 绿。

**出现版本**：alpha.70
**修复版本**：alpha.71

---

### Bug 487：`ListTile` 的文字全变成了「列表项」—— 属性静默回落到默认值，不报错（2026-09-22，alpha.71 修复）

**症状**：

导入已有 UI 时，用户写的每一个 `ListTile` 在树上、在预览里、在生成代码里
标题都成了默认值「列表项」，副标题全空，左侧图标永远是默认的 `circle`。
**整个过程不报错、不抛异常、树结构完全正确** —— 只有内容是假的。

**原因**（三个独立的错，叠在一起）：

**① `ListTile.title` 是 `Widget`，不是 `String`。**

```dart
ListTile(title: Text('首页'), subtitle: Text('12 条新消息'), leading: Icon(Icons.home))
```

导入器里写的是 `_stringLiteral(namedArgument('title'))` ——
它拿到的表达式是 `Text('首页')`（一个 `InstanceCreationExpression`），
不是字符串字面量，于是**恒返回 null**，随后回落到 `defaultProps()` 里的
`'列表项'`。

和 Bug 483 是同一类：**静默回落比崩溃更危险** —— 崩溃你至少知道出了问题。

修法：用 `_buttonLabel2()`（先剥一层 `Text(...)` 再取字面量）：

```dart
final title = _buttonLabel2('title') ?? '列表项';
```

**② `ListTile.leading: Icon(Icons.home)` 拿到的是整个 `Icon` 构造。**

`_iconNameOf` 只认 `PrefixedIdentifier` / `PropertyAccess` / `SimpleIdentifier`，
面对 `Icon(Icons.home)` 一个都不命中 → 恒返回 null → 恒回落到 `'circle'`。

修法：在 `_iconNameOf` **开头**先剥一层 `Icon`，再取 `Icons.xxx`。

**③ 生成器里有一段残留的旧代码，把整段逻辑无条件覆盖了。**

`case 'ListTile'` 之后遗留了三样东西：

```dart
// 一段被 Dart 解析成"空的 collection-if"的注释
// 一个 `if (title != null) ...` 形式的集合元素
// 以及一个无条件的：
return <String>[...];        // ← 直接覆盖前面所有判断
```

因为生成器的 `_str` 会把 `'列表项'` 原样转成 `'列表项'`，
表面上看起来像"用了默认值"，实际是**无条件走了这段旧代码**。

**解决**：删掉残留段，title/subtitle 走 `_buttonLabel2`，leading 走修好的
`_iconNameOf`。

**验证**：`design_import_test.dart` 里补断言，直接对着用户写的字断言：

```dart
expect(node.props['title'], '首页');       // 不是 '列表项'
expect(node.props['subtitle'], '12 条新消息');
expect(node.props['leadingIcon'], 'home'); // 不是 'circle'
```

> 📌 **排查这类"内容不对但不报错"的问题，第一步永远是打印
> `defaultProps()`**。如果日志里的值和 `defaultProps()` 一模一样，
> 那就是解析没命中、回落了 —— 而不是"解析错了"。

**出现版本**：alpha.71 开发中（未出包）
**修复版本**：alpha.71

---

### Bug 488：导入时用户写的注释被静默吃掉 —— AST 里注释是 trivia，不挂在任何节点上（2026-09-22，alpha.71 修复）

**症状**：

「原样带回」承诺了未识别的 widget 会连注释一起吐回去，但实测：

```dart
// 第三方登录：等接了 SDK 再打开      ← 这句丢了
ThirdPartyLoginRow(
  onTap: _onThirdParty,
),

MyChart(), // 数据源                 ← 这句跑到了**下一个**节点身上
Qux(),
```

出现**串位**和**丢失**两种错，都不报错。

**原因**（五个坑，每个都踩了一遍）：

**① 注释不在 AST 里，它是 trivia。**

`node.offset..node.end` 切出来的源码**不含注释**
（前导注释挂在 `node` 的**第一个 token** 上，行尾注释也是 token 属性）。
所以一开始的 `source.substring(node.offset, node.end)` 必然丢注释。

**② 存"源码切片"而不是 AST 子树，是唯一正确的做法。**

AST 重新打印会丢注释、丢格式、丢用户的一切。存
`source.substring(...)` 才能在生成时**原样吐回去**。
（这也是整个"原样带回"设计的立足点。）

**③ 行尾注释在解析器眼里是"下一个 token 的前导注释"。**

```dart
MyChart(), // 数据源
Qux(),
```

`// 数据源` 挂在 **`Qux`** 的前导注释链上，不挂在 `MyChart` 上。
所以"无脑往左捞"会把上一行的行尾注释也带进来 —— 出现**重复**
（`// 数据源` 同时出现在 `MyChart` 和 `Qux` 的 raw 上）。

最终判别规则（**单条**，别加第二条）：

```dart
// 注释必须①自己独占它前面那部分行，且②与节点之间没有实质代码
_isBlankBetween(source, _lineStartOf(source, s), s)   // ①
  && !_hasCodeBetween(source, e, node.offset)          // ②
```

`_hasCodeBetween` 要**剥掉 `/*…*/` 与 `//…`** 再看有没有非空白。

**④ `Token.precedingComments` 是单向链表，不是 `List`。**

```dart
for (final c in firstTok.precedingComments)   // ← 编译不过，迭代出 Object
```

它是靠 `CommentToken.next` 串的链表，且 `Token.next` 的静态类型是
`Token?` 而非 `CommentToken?`。

**⑤ 沿 token 链 `next` 遍历会踩到自引用节点、死循环。**

`main11.dart` 探针就是这么挂的（跑满 3 分钟被迫 kill）。
所以**行尾注释改成直接扫源码**，不跟解析器的 trivia 存放策略绑死
（那是实现细节，换个 analyzer 版本就可能变）：

```dart
// node.end 停在 `)` 上，往后第一个字符是列表元素的 `,` —— 必须先跳过，
// 否则永远看不到注释
var i = node.end;
while (i < source.length && source[i] == ' ') i++;
if (i < source.length && source[i] == ',') i++;
while (i < source.length && source[i] == ' ') i++;
if (source.startsWith('//', i)) { /* 吃到行尾 */ }
```

**⑥ 顺带两个同族的坑：**

- **`ListLiteral.elements` 的元素类型是 `CollectionElement` 而非 `Expression`**
  （可能是 `IfElement` / `ForElement` / `SpreadElement`），
  只有 `Expression` 才可能是 widget 构造。
- **Dart 把 `[ // 只有注释 ]` 解析成一个空的 collection-if**（`IfElement`），
  **不是"空列表"**。当占位带走会生成半句 `if ()` —— **直接编译不过**。
  判别：`sliceSource(source, e.thenElement).trim().isNotEmpty`。
  ⚠️ 配套坑：`IfElement.thenElement` **非空**，写 `t == null` 会被
  `flutter analyze` 报 `unnecessary_null_comparison`。

**解决**：新增 `sliceSourceWithComments()`，前导注释用上面那条单一规则，
行尾注释直接扫源码。

**验证**：`design_import_test.dart` 的「未识别组件：原样带回」组里
断言注释出现在 raw 里、且**不重复**：

```dart
expect(node.props['raw'], contains('// 第三方登录：等接了 SDK 再打开'));
expect(RegExp('// 数据源').allMatches(entireGeneratedCode).length, 1);
```

**另外两条 API 备忘**（analyzer 14.4.0，实测确认，与直觉差异很大）：
- `ClassDeclaration` **没有** `.name` / `.members` —— 是
  `decl.namePart.typeName.lexeme` 与 `decl.body.members`
- **`NamedExpression` 不存在** —— 命名参数是 `NamedArgument`，
  取名字走 `.name.lexeme`（`name` 是 `Token`，不是 `Label`），
  取表达式走 `.argumentExpression`
- `ArgumentList.arguments` 的元素类型是 `NodeList<Argument>`（不是 `Expression`）
- `SimpleIdentifier.name` 是 `String`（**不是** `.lexeme`）
- **裸名构造走 `MethodInvocation`，`const X()` 走 `InstanceCreationExpression`**
  —— `Text('x')` 是前者（`target == null`），`const SizedBox(...)` 是后者。
  **两类都必须处理**，只处理一种会让另一类 widget 静默变成 unknown
- `IfElement.thenElement` 非空（`CollectionElement`）
- `Token` / `CommentToken` 从 `package:analyzer/dart/ast/token.dart` 导入；
  `RecursiveAstVisitor` 从 `package:analyzer/dart/ast/visitor.dart` 导入
  （从 `ast/ast.dart` 导入会报 not found）

**出现版本**：alpha.71 开发中（未出包）
**修复版本**：alpha.71

---

## 十、Flutter / Material 布局与主题（外观类问题）

> 这一类 Bug 的共同特征：**编译通过、静态分析通过、单元测试通过，
> 只有真渲染才暴露**。它们不会崩、不会打日志，只会让界面变丑或不可用。
> 定位手段只有两个：**逐档屏幕宽度渲染** + **捕获 `FlutterError.onError`**。
> 见 `test/home_layout_widths_test.dart` 与 `test/home_ui_alpha92_test.dart`。

### Bug 634 · `Material` 的 `borderRadius` 与 `shape` **互斥**，同传给会运行时断言（2026-09-26，alpha.92）

#### 症状

配置页「快捷入口」的**六个格子全部变成黄黑相间的溢出条纹**，整块区域不可用。
控制台报：

```
'package:flutter/src/material/material.dart': Failed assertion: line 209 pos 15:
'!(shape != null && borderRadius != null)': is not true.
```

同一帧里**报 6 次**（每个格子一次）。`flutter analyze` 无任何提示。

#### 根因

`Material` 的构造参数里，`borderRadius` 与 `shape` 是**两种表达同一件事
（外形）的方式**，框架明确不允许同时给。想同时要"圆角 + 描边"时：

- `borderRadius` 只能表达圆角，**表达不了描边**；
- `shape`（`RoundedRectangleBorder`）**两个都能表达** ——
  `borderRadius` 走它的 `borderRadius` 字段，描边走 `side`。

所以正确写法是**只给 `shape`**。

这次的错误来源很典型：想给格子加一层描边（深色主题下
`secondaryContainer` 与卡片底只差约 4% 亮度，没描边就糊在一起），
于是**在原来 `borderRadius` 的基础上又加了 `shape`**，忘了它俩不能共存。

#### 解决

`lib/ui/home_page.dart` 的 `_ActionTile`：

```dart
// ❌ 错的
return Material(
  color: ...,
  borderRadius: radius,          // ← 与下面的 shape 冲突
  shape: RoundedRectangleBorder(
    borderRadius: radius,
    side: BorderSide(color: border),
  ),
  child: InkWell(borderRadius: radius, ...),
);

// ✅ 对的：形状只由 shape 表达
final shape = RoundedRectangleBorder(
  borderRadius: radius,
  side: border == null ? BorderSide.none : BorderSide(color: border),
);
return Material(
  color: ...,
  shape: shape,
  // ⚠️ InkWell **不**受这条断言约束（它是 Material 的 child，
  // 形状参数不在构造参数里同时给两套），所以水波纹仍用 borderRadius 裁。
  child: InkWell(borderRadius: radius, ...),
);
```

#### 验证

`test/home_layout_widths_test.dart` 逐档宽度（320/360/412/600/800dp）遍历
三个 tab，用 `FlutterError.onError` 收集**全部**渲染期异常并断言为空。

> ⚠️ 必须用 `FlutterError.onError` 而不是 `tester.takeException()`：
> 后者一次只能取到一个异常，这批问题是**同一帧六个格子各报一次**
> —— 只取一个会让"修好一个还剩五个"看起来像通过。

#### 教训

**给已有的 `Material` / `Card` 加视觉参数前，先查一眼它现有的同类参数。**
"圆角"这件事在这两个 widget 上有两套 API，框架选的是互斥而不是合并。

这类错误的可怕之处在于它**不报编译错**：`borderRadius` 和 `shape` 都是
合法参数，IDE 不会飘红，`flutter analyze` 也不管运行时断言。
唯一的防线是**真的把它渲染一遍**。

**出现版本**：alpha.92 开发中（未出包）
**修复版本**：alpha.92

---

### Bug 633 · `GridView.count` 的 `childAspectRatio` 让格子高度随屏宽浮动 → 静默挤压内容（2026-09-26，alpha.92）

#### 症状

「快捷入口」宫格里，格子内容（图标 + 文字）被**压到溢出边缘**。
不报错（`RenderFlex` 把超出的部分压缩了），但：

- 窄屏（320dp / 分屏）上文字被切掉下半截；
- 宽屏上格子被拉成一条扁矩形，图标与文字之间空出一大片。

#### 根因

`childAspectRatio` 定的是格子的**宽/高比**，而格子宽度是**算出来的**：

```
格子宽 = (可用宽 - 间距 × (列数 - 1)) / 列数
格子高 = 格子宽 / aspectRatio
```

于是在 360dp 手机上两列布局：

```
(360 - 20 - 32) / 2 ≈ 154dp 宽   →   154 / 2.2 ≈ 70dp 高
```

而内容恒定需要：

```
图标(28) + 间距(8) + 一行 13px 字(~18) + 上下内边距(16) ≈ 70dp
```

**卡在临界点上**。从 alpha.60 加进第 6 个入口（图标 30 → 28）起，
这个差值就在 ±0 附近来回，任何一侧的字体度量变化都会把它压过去。

#### 解决

改用 `mainAxisExtent`：**高度是给定值，与屏幕宽度无关**。

```dart
GridView.count(
  crossAxisCount: constraints.maxWidth >= 560 ? 3 : 2,
  mainAxisSpacing: 10,
  crossAxisSpacing: 10,
  // ✅ 高度给定 —— 内容需要多少就给多少
  mainAxisExtent: 92,
  // ❌ childAspectRatio: 1.9 —— 高度会随屏宽反比浮动
  children: [...],
)
```

92 = 图标 28 + 间距 8 + 文字行高 ~22 + 上下内边距 16 + 余量 18。

#### 验证

`test/home_layout_widths_test.dart` 里有一条**度量断言**（比截图断言稳）：

```dart
final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
expect(delegate.mainAxisExtent, 92);
```

外加那条逐档宽度的无异常断言。

#### 教训

**凡是"内容尺寸基本固定、只在外层重复 N 次"的宫格，都该用
`mainAxisExtent` 而不是 `childAspectRatio`。**
`childAspectRatio` 适合"等比缩放的图片格"这类场景 —— 那时高度**本来就应该**
跟着宽度走。用错场景的表现就是"某些屏宽下刚好挤爆"。

另外注意：**这个 Bug 在 alpha.60 就埋下了，一直没被发现**。
说明"只在自己手上的那台设备上看一眼"是不够的 ——
必须**逐档宽度**渲染，或者写成测试让 CI 来跑。

**出现版本**：alpha.60（埋下）→ alpha.92（暴露并修复）
**修复版本**：alpha.92

---

### Bug 632b · 顶栏 `transparent` + 状态栏实色 = 顶部一条可见色带（2026-09-26，alpha.92）

> ⚠️ 编号与上文的 **Bug 632**（vendored `CodeController` 越界）**不是同一件事**，
> 只是编号撞了。查这条请认标题里的"顶栏/状态栏"。

#### 症状

浅色主题下，屏幕顶部从上到下是**三段不同的颜色**：

1. 状态栏：中性灰 `#F5F7F8`
2. 顶栏（AppBar）：带一层淡绿的 `#F6FBF3`
3. 内容区 / 卡片：近白 `#FBFCFD`

分界线肉眼可见，像"顶栏没对齐"。深色主题下同理（`#101418` vs `#101510`），
只是差值小、不那么显眼。

#### 根因

**Bug 457 只修了一半。**

当时把状态栏从 `transparent` 改成实色（正确，否则透出的是 `styles.xml` 的
深色窗口背景），但 `AppBarTheme.backgroundColor` **仍然是 `transparent`**。
于是：

| 元素 | 实际颜色 | 来源 |
|---|---|---|
| 状态栏 | `#F5F7F8`（中性灰） | `systemOverlayStyle.statusBarColor` |
| 顶栏 | `#F6FBF3`（带绿调） | transparent → 透出 `scaffoldBackgroundColor` = M3 `surface` |

**两者是两个不同的值，必然有色差。** M3 的 `surface` 由种子色（Android 绿）
派生，所以浅色下带绿调；而手调的 `lightSurface` 是中性灰 —— 这就是那条色带。

深色下更隐蔽：`scaffoldBackgroundColor` 被显式设成 `FoaTheme.bg = #101418`，
而状态栏也是 `#101418`，**看起来是对的**；问题出在"顶栏透出的其实是
`scaffoldBackgroundColor`，一旦有人改了它就会分叉"这个脆弱结构上。

#### 解决

让顶栏、状态栏、导航栏**三者同源**，都取 `panelBg(brightness)`：

```dart
// theme.dart：dark()/light() 合并成一个 _build(Brightness)
final surface = panelBg(b);
return ThemeData(
  appBarTheme: AppBarTheme(
    backgroundColor: surface,        // ✅ 从 Colors.transparent 改成实色
    systemOverlayStyle: overlayFor(b),  // overlayFor 内部也用 panelBg(b)
  ),
);

static SystemUiOverlayStyle overlayFor(Brightness b) => SystemUiOverlayStyle(
      statusBarColor: panelBg(b),
      systemNavigationBarColor: panelBg(b),
      systemNavigationBarDividerColor: panelBg(b),
      // 图标亮度按亮度取反
      statusBarIconBrightness: b == Brightness.dark ? Brightness.light : Brightness.dark,
      ...
    );
```

同时 `lightSurface` 由 `#F5F7F8` 改成 `#FBFCFD` = `panelBg(light)`，
并同步三处跨文件副本：

- `android/app/src/main/res/values/colors.xml` 的 `foa_bg_light`
- `android/app/src/main/kotlin/.../MainActivity.kt` 的 `applySystemBarColors` 兜底
- `app/platform/android/MainActivity.kt`（模板副本，必须逐字节一致）

#### 为什么深色的 `bg` 不跟着改

深色下**刻意保留** `bg = #101418`（页面底）与 `panelBg = #14181E`（顶栏底）
的 2.5% 差值：顶栏是一块"浮在页面上"的横带，同色会让顶栏与内容区糊成一片、
看不出 AppBar 到哪儿结束。浅色下同值则更干净（浅色本来就靠描边分层）。

#### 验证

- `test/home_ui_alpha92_test.dart` 有 6 条：AppBar 背景非 transparent、
  等于 `panelBg`、等于 `statusBarColor`、与 `overlayFor` 同源、
  导航栏同色、`lightSurface == panelBg(light)`。
- `test/bug457_statusbar_theme_test.dart` / `bug464_..._test.dart` 里那组
  **跨文件同源断言**（Dart ↔ Kotlin ↔ XML）已同步到新色值 ——
  这两条测试是本 Bug 最好的守门人，改色时它们会红。

#### 教训

**"沉浸式顶栏"（`backgroundColor: Colors.transparent`）的前提是
"状态栏也透出同一个底色"。** 一旦状态栏被设成实色（而它必须如此，
否则透出的是宿主窗口背景），这个前提就没了，顶栏必须改用同一个实色。

另外：`dark()` / `light()` 各写一份主题时，凡是"两个主题都该有的令牌"
都得写两遍，**漏写一份的表现就是"一边正常、另一边返祖"** ——
Bug 457 正是这个形状。合并成 `_build(Brightness)` 之后，
"两个主题长得不一样"只剩两个有名字的变量（底色 + overlay）。

**出现版本**：alpha.60 ~ alpha.91
**修复版本**：alpha.92

---

### Bug 631b · M3 默认 `Card` 与页面底色几乎同色，且 `elevation: 1` 把卡片压得**比背景更暗**（2026-09-26，alpha.92）

> ⚠️ 编号与上文的 **Bug 631**（`setMethodCallHandler` 覆盖）**不是同一件事**。
> 查这条请认标题里的 "Card"。

#### 症状

整页读起来像"一块没分层的灰板"：卡片与页面底色分不出来，只能靠卡片里的
文字位置猜边界。用户的原话是"UI 更好看一点"、截图里"列表挤在一个大卡片里"。

#### 根因

两个因素叠加：

**① `CardTheme.color` 默认取 `colorScheme.surface`**，而本项目的
`scaffoldBackgroundColor` 也是从 surface 来的 → 两者几乎同值：

| 主题 | 页面底 | Card 默认底 | 差值 |
|---|---|---|---|
| 深色 | `#101418` | `#101510` | 约 0.4% |
| 浅色 | `#F6FBF3` | `#F6FBF3` | **0** |

**② `Card` 默认 `elevation: 1`**，M3 会按 **surfaceTint** 把 5% 的
`colorScheme.primary` 混进卡片色。而本项目的 `primary` 是**深绿**
（深色下 `#12512E`）—— 把它混进一个深色底，结果是**卡片比背景更暗**，
与"卡片应该浮起来"的意图完全相反。

> 这个 5% 很容易记错：M3 文档里 `surfaceTint` 在
> Elevation 1 时是 **5%**，不是常被引用的 8%（8% 是更高 elevation 档）。

#### 解决

在 `FoaTheme._build` 里显式给 `cardTheme`：

```dart
cardTheme: CardThemeData(
  // ① 用 M3 的层级令牌而非手调字面量：surfaceContainerLow 比 surface
  //    高一层，由种子色派生，天然按亮度适配（与 _drawerItem 用
  //    secondaryContainer 同一理由）。
  color: scheme.surfaceContainerLow,   // 深 #181D18 / 浅 #F0F5ED
  // ② 归零：避免 surfaceTint 把卡片压暗，层次改用"提亮底 + 描边"
  elevation: 0,
  // ③ 描边不可省：深色下 #181D18 与 #101418 只差约 5% 亮度，
  //    肉眼分不出边界。outlineVariant 是 M3 专为"弱边界"设计的令牌。
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(14),
    side: BorderSide(color: scheme.outlineVariant),
  ),
  // ④ 默认 margin(4) 会在页面自己给的 padding 之上再吃一层，
  //    让"卡片净宽"永远比设计意图少 8dp。间距改由页面显式给。
  margin: EdgeInsets.zero,
),
```

顺带把 `dividerTheme.color` 也接到 `outlineVariant`（默认的 `outline`
在深浅两边都太重）。

#### 连带修掉的一处历史包袱

`ui_polish_test.dart` 里原本有三条 alpha.69 的断言，写的是：

```dart
expect(home().contains('margin: const EdgeInsets.symmetric(horizontal: 2)'), isTrue);
```

那是"**逐处抵消 `Card` 默认 margin**"的痕迹 —— alpha.69 为了让工程卡片宽一点，
在 ListView padding 上收到 12、又在 Card margin 上压到 2。
alpha.92 把根因挪到主题层之后，这三个魔数全部删除，
断言翻成**反向**（"那组旧魔数不该以任何形式复活"）。

#### 验证

`test/home_ui_alpha92_test.dart` 有 7 条：Card 底色 ≠ 页面底、
= `surfaceContainerLow`、elevation 为 0、有非零描边且色为 `outlineVariant`、
圆角为 14、margin 为 `EdgeInsets.zero`、分隔线色随主题。

#### 教训

**"默认值能用"是个陷阱。** M3 的 `Card` 默认值是在"用一个 M3 派生色做页面底"
的假设下调的；本项目为了控制色温**手调了** `scaffoldBackgroundColor`
（避开种子色带来的绿调），这个手调动作**正好破坏了默认值的前提**。

凡是**手写过主题令牌**的项目，都要顺带检查那些"依赖该令牌的默认值"还成不成立。
具体到 Card：手调了 `scaffoldBackgroundColor` 就必须显式给 `cardTheme.color`。

**出现版本**：alpha.69 起（手调 `scaffoldBackgroundColor` 时埋下）
**修复版本**：alpha.92

---

### Bug 630b · `Colors.grey.shade400` 漏在语义色迁移名单外 → 浅色主题下读不出来（2026-09-26，alpha.92）

> ⚠️ 编号与上文的 **Bug 630**（反向方法名对不上）**不是同一件事**。

#### 症状

浅色主题下，配置页 "设备 / ABI / rootfs / proot" 的**键名**
与安装日志**几乎看不见**（`#BDBDBD` 压在近白底上）。

#### 根因

Bug 464 做语义色迁移时，清理名单是**枚举式**的：

```dart
// bug464_theme_and_download_test.dart
if (src.contains('Colors.grey.shade500') ||
    src.contains('Colors.grey.shade600')) { offenders.add(f.path); }
```

只列了 `shade500` / `shade600`，**`shade400` 不在名单里**，
于是它带着"深色主题专用"的取值活到了浅色主题上。

同时 `bug457`/`bug464` 的断言都是**黑名单式**（"不许出现这些值"）
而不是白名单式（"必须用语义位"），所以漏网的值不会有任何测试报警。

#### 解决

`lib/ui/home_page.dart` 两处改走语义位：

```dart
// _StatusCard._kv 的键
Text(k, style: TextStyle(color: FoaColors.of(context).muted, ...)),

// _ActionCard 的安装日志
Text(env.installLog, style: TextStyle(color: FoaColors.of(context).muted, ...)),
```

#### 验证

`test/home_ui_alpha92_test.dart` 加了一条白名单式断言：

```dart
expect(home().contains('Colors.grey.shade400'), isFalse,
    reason: '应走 FoaColors.of(context).muted');
```

#### 教训

**黑名单式断言只能拦住"已知的坏值"。**
`bug464` 那两条测试守住了 `shade500/600` 不再出现，却让 `shade400`
堂而皇之地留在代码里 —— 而且是以"我已经迁移完了"的名义。

更稳的写法是**白名单**：与其枚举所有不该出现的灰，不如断言
"`lib/ui/` 下不该有任何 `Colors.grey.shade*`"（除非有明确豁免，
如 `code_editor.dart` 里 Bug 431 要求保留的 `shade300`）。
迁移类任务留一条"扫描全目录"的兜底断言，比列具体值可靠得多。

**出现版本**：Bug 464 迁移时（alpha.69）
**修复版本**：alpha.92

---

## 十一、构建提速（2026-09-27，alpha.93）

> 设备端（手机 proot 容器 + QEMU 转译）构建慢的定性与提速尝试。
> 这一章**最有价值的是两条负面结论**——它们都是沙箱实测出来的，
> 能挡掉后来者重复踩坑。别只看"做了什么"，要看**什么被证明无效**。

### 定性：慢在哪

构建分 8 段（`build_progress.dart`），与耗时相关的只有两段，同一个原因：

| 阶段 | 进度 | 是否走 QEMU 转译 |
|---|---|---|
| 配置 Gradle | 14~26% | 否（JVM，arm64 原生） |
| **编译 Dart 内核** | 26~40% | **是**（dart 是 x64） |
| **AOT 编译（gen_snapshot）** | 40~58% | **是**（官方只发 x64，慢 10~50 倍） |
| 编译资源（aapt2） | 58~72% | 否（已原生化） |
| Kotlin / dex（R8） | 72~86% | 否（d8/R8 是 Java） |

**结论：超过三分之一的时间花在 QEMU 翻译 dart 与 gen_snapshot。**
用户真机反馈"卡在 AOT 那一档"，与定性一致。

### ⚠️ 手册内一处自相矛盾（已核实，影响优化方向）

- §七（07 号文档）表格写：`gradle / d8 / R8` 纯 JVM，天然原生；
- §十一（07 号文档 proroot 段）写：`gen_snapshot / gradle / aapt2 都是 x64 二进制`。

**后者不对**。Gradle 主体是 JVM（gradle launcher 是 shell + JVM 进程），
把它算进"QEMU 翻译开销"会误导人去折腾"原生化 Gradle"——那是白费力气。
（`aapt2` 那一项确实曾是 x64，但已被 Commit451 原生件替换。）

同理，**proroot 对构建速度零改善**：它省的是 proot 的 ptrace 开销
（10~30%，只对 I/O 密集操作有感），对 QEMU 指令翻译和 dart/gradle
自身计算无能为力。别把它当提速方案卖。

### 负面结论一：Gradle 配置缓存会让构建**直接失败**（不是慢一点）

实测（沙箱，Flutter 3.47.4 / AGP 9.1 / Gradle 9.3.1）：

```
org.gradle.configuration-cache=true
```

→ `BUILD FAILED in 1m 1s`。报错：

```
Configuration cache state could not be cached: field `queue` of
`java.util.WeakHashMap` ... `com.flutter.gradle.DependencyVersionChecker
$configureMinSdkCheck$1$minSdkCheckTask$1$1` ... task `:app:ReleaseMinSdkCheck`
  error writing value of type 'java.lang.ref.ReferenceQueue'
- Task `:app:ReleaseMinSdkCheck`: cannot serialize object of type
  'org.gradle.api.internal.project.DefaultProject' ...
  'DefaultConfigurationContainer' ... 'DefaultDependencyHandler' ...
  'org.jetbrains.kotlin.gradle.internal.properties.PropertiesBuildService'
```

**根因在 Flutter 官方插件**：`DependencyVersionChecker` 的 task action
捕获了 `Project` / `ConfigurationContainer` / `DependencyHandler` /
`BuildService` 这些配置缓存禁止序列化的对象。本项目改不了，只能等上游。

护栏断言已加在 `test/build_flavor_test.dart`（扫描 `sdk_installer.dart`
不含 `org.gradle.configuration-cache`）。

### 负面结论二：Gradle build cache 对本场景**零收益**

实测同一改动（touch 一个 dart 文件）：

| 配置 | Gradle 阶段耗时 |
|---|---|
| 基线（无缓存） | 121.9s |
| `org.gradle.caching=true` | 121.6s |

**差值 0.3s，噪声范围内。** 原因：

- 改了 dart 文件 → AOT 及下游所有 task 输入全变 → 缓存命中不了；
- 没变的 task 本来就被 Gradle 增量机制的 `UP-TO-DATE` 跳过 → 缓存无处发挥。

build cache 的收益场景是"换工作目录 / clean 后重建"，而 FOA 是同一工程
反复增量构建——增量机制已经覆盖了它想做的事。

### 真正有效的：debug 构建档（alpha.93 落地）

无法绕开的事实：**AOT 的大头是翻译开销，唯一能显著提速的就是不跑 AOT。**

| | release | debug |
|---|---|---|
| Dart 编译 | AOT（gen_snapshot） | kernel（JIT） |
| gen_snapshot | 必需，x64 + 转译 | **不参与** |
| 产物 | 可上架 | 仅自测 |

实现要点（`BuildFlavor`）：

1. `build_runner.dart`：`start(flavor:)`、`buildCommand(flavor:)`，
   生成 `--release` / `--debug`；**两处** build 命令（含 heal 自愈重跑）
   必须同档位，写死一处会让"自愈后的第二次构建"跑回 release；
2. debug 档**跳过** `precache --android_gen_snapshot`（预取的是 AOT 工具链，
   debug 用不到，跑了还会触发一轮构件下载）；
3. `_locateApk` 按 `flavor.apkName` 挑产物——debug/release 的产物
   **会同时留在** `build/app/outputs/flutter-apk/`（不互相覆盖），
   写死 `app-release.apk` 会让用户装上上一次的旧包；
4. 偏好持久化 `FlavorPrefs`，**默认 release**（debug 产物不能上架，
   静默改默认值等于换掉用户的产物性质）；
5. 进度条 `skipAot`：把 `[0.58, 1.0]` 拉伸到 `[0.40, 1.0]`，
   消掉 AOT 段那 18% 的空档，否则进度会跳一下。

### ⚠️ 加 debug 档时**实际漏掉**的一条 bug

进度映射的 Gradle 阶段正则原来只写 Release 变体：

```
mergeReleaseResources / compileReleaseKotlin / packageRelease / assembleRelease
```

而 debug 构建产出的是 `mergeDebugResources` / `compileDebugKotlin` /
`assembleDebug`——**一条都匹配不上**，进度会从 40% 一路卡死到构建结束
才突然 100%，看起来完全像卡住。

已改为 `(?:Release|Debug)` 双变体，并由 `build_flavor_test.dart` 的
"同时匹配 Release 与 Debug 变体"断言守着。这类"加新档位时旧正则漏匹配"
是必然复发的形状，新加任何构建变体都要回头查一遍 `_rules`。

### 仍未解决（诚实边界）

- **首次 debug 构建要额外下载一套 engine 构件**：`arm64_v8a_debug` +
  `flutter_embedding_debug`，从 Maven 拉（不是本地 Flutter SDK 缓存）。
  沙箱实测确认本地只缓存了 release 构件（`find` 无任何 `*arm64_v8a_debug*`）。
  手机上走阿里云镜像能否拉到 `io.flutter:*` **未真机验证**。
- **沙箱无法实测 debug 的完整提速幅度**（`dl.google.com` 在沙箱被 TLS 掐），
  上面的收益是原理推断 + 用户卡点反馈，不是端到端实测数据。
- **根治方案仍未落地**：dart + gen_snapshot 原生化（版本须严格匹配
  engine 06a2e2a1，Termux 现货 3.13.2 对不上）。

## 十二、四项补齐：图标替换 / 磁盘检查 / Git 面板 / 正式签名（2026-09-28，alpha.93）

本轮的四项都是"以前只有提示、没有入口"的功能。共同的实现约束：

- **FsBridge 只走文本**：PNG、keystore 这类二进制既读不进 Dart 也写不回容器，
  所以二进制操作全部在容器里用现成工具做（imagemagick / keytool / apksigner），
  Dart 只负责拼命令与解析输出；
- **App 进程零三方依赖**（alpha.27 移除 Kadb 时定的原则）：不引 `image`、
  不引 Dart 版 git、不引签名库；
- **Kotlin 侧 `/root/projects` 白名单**：因此 keystore 放 `/root/keystores`，
  不放工程目录（顺带避免被 `git add -A` 提交、被"导出源码工程"带走）。

### 12.1 图标替换（`lib/project/icon_replacer.dart`）

渐进增强：先探针查工具，有 imagemagick → `convert -resize`，有 Pillow →
PIL `LANCZOS`，都没有 → 直接 `cp`（能用，但原图太小会在高密度屏发虚）。
UI 上如实写出降级行为，不吹"一定能生成精确尺寸"。

### 12.2 磁盘空间检查（`DiskSpace` + `ToolchainEnsure.diskSpace`）

`<800MB` 直接挡住构建，`<2GB` 继续但给提示。探测不到（`df` 异常）返回 null
不挡路——**检查失败不能变成"禁止构建"**。

### 12.3 Git 面板（`lib/project/git_panel.dart`，工作台新增「版本」区）

只做 init / status / add / commit / log。**刻意不做** push / pull / 远端，
也不做「丢弃改动」（不可逆，误点一次就丢工作），能力边界写在 UI 上。

命令脚本抽成 `statusScript` / `initScript` / `commitScript` 三个纯函数，
输出用固定标记分段，`GitRepo.parse` 是纯函数——解析逻辑因此能被单测覆盖，
真机验证时也能把脚本贴进终端跑。

#### ⚠️ 真机（真 git）跑出来的两个坑

1. **`git log --pretty=format:` 在最后一条之后不换行**。
   实测末条日志与后面的 `--END--` 粘成一行，解析出来 subject 尾巴挂着
   `--END--`。必须用 **`tformat`**（terminator format）。
2. **`git config --global --add safe.directory` 每次刷新都重复追加一条**。
   改成先 `git config --global --get-all safe.directory | grep -Fqx <dir>`
   判存在再 `--add`，否则 `~/.gitconfig` 会随刷新次数线性膨胀。

另外 `git status --porcelain` 默认把未跟踪目录压成一行 `?? lib/`，
面板没法按文件勾选，要加 **`-uall`** 展开。

### 12.4 正式签名（`lib/project/signing.dart`）

用容器里已有的开源工具，**不引任何新依赖**：
`keytool`（容器 JDK）生成 JKS；`apksigner` + `zipalign`（SDK build-tools，AOSP）
签名与验签。

两条路径并列，UI 上不混为一谈：

| 路径 | 做法 | 适用 | 代价 |
|---|---|---|---|
| 构建时签名 | 写 `android/key.properties` + 给 `build.gradle(.kts)` 打补丁 | 常规 | 要改用户的构建脚本 |
| 产物签名 | 对已产出的 APK 直接 `apksigner` | 补丁拒绝时 / 不想改源码 | 每次出包后要再点一次 |

补丁是**保守的**：只认两个已知锚点（`android {` 与 `buildTypes {`）和
release 变体那行 `signingConfig = signingConfigs.getByName("debug")` /
`.debug`，任一条匹配不上就**拒绝改写**并指路"产物签名"，绝不硬改。
支持 Groovy 与 Kotlin DSL 两种（容器 Flutter 3.47 默认生成 `.kts`）。

#### ⚠️ 险些漏网的真 bug：`signingConfigs` 子串误判

"是否已经接过签名"的判据最初写成 `src.contains('signingConfigs')`。
但 Flutter 模板的 release 变体里**本来就有** `signingConfigs.getByName("debug")`，
于是**每一个新工程都会被判成"已配置"**、补丁全部拒绝。

改用正则判**声明块**：`^\s*signingConfigs\s*\{`。
由 `signing_test.dart` 里"本机 Flutter 的 kts 模板能被补丁吃下"这条
**真实模板回归**守着——沙箱里那份 Flutter 模板一变，测试立刻红。

### 仍未解决（诚实边界）

- **补丁后的构建只在真机能验**：沙箱没有容器 JDK/SDK，`patchGradle` 的输出
  是逐行人工核对过（已导出到 /tmp 核对过 kts 与 groovy 两版），
  但**没跑过一次真实 gradle 构建**。
- **key.properties 是明文口令**，落在工程目录里。已自动加进
  `android/.gitignore`，但历史提交里若已有则无解——这是 flutter 官方
  方案本身的形态，不是本实现引入的。
- **自签证书**：Google Play 与多数国内商店接受，但从商店后台导出的
  "上传证书"场景不支持（那种情况请直接改 key.properties 指过去）。
- 不支持 AAB（.aab 签名走 bundletool 另一套）、不做 v4 签名。

## 十三、alpha.94：默认 debug 档 / 预取引擎构件 / Git 远端 / 签名库（2026-09-28）

这一章的四项都来自同一条真机反馈：

> debug 构建好像失败了，这个 debug 构建工具链可以提前下载吗？如果 debug
> 确实可以跳过 aot 编译更快的话建议默认使用 debug 构建。图标替换似乎有 bug。
> git 面板增加远端功能。正式签名可以自选使用签名（有多个签名或有正式签名
> 但想使用 debug 签名）或导入自定义签名。

四项的共同点：**都是"能编译通过但真机上是错的"那类功能**，所以每一项
都在沙箱里用真工具（真 gradle、真 git、真 keytool）跑过一遍才敢写进文档。
下面每一节的"实测"都是本轮跑出来的原始输出，不是推断。

### 13.1 默认档位改成 debug（`FlavorPrefs.fallback`）

alpha.93 加了 debug 档，但默认值是 release —— 等于"能选，但没人会选"。
alpha.94 起 `FlavorPrefs.fallback = BuildFlavor.debug`。

依据是设备端的耗时结构（见第十一章）：release 的 AOT 要跑 `gen_snapshot`，
它是 x86_64 二进制，在手机容器里靠 QEMU 转译执行（慢 10~50 倍），是整条
链路上唯一真正耗时的一档；日常"改代码看效果"根本不需要 AOT。

代价必须在 UI 上如实写出（打包区档位切换器旁），不能靠默认值糊过去：

- debug 包更大（带 JIT 与内核快照）；
- **不能上架**；
- **不能覆盖安装正式版**（签名不同，会 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。

> ⚠️ `build_flavor_test.dart` 里那条"读不到就返回 release"的断言本轮
> **被我改成了返回 debug**。这是**需求变更**，不是测试变松：
> 断言改成钉 `FlavorPrefs.fallback` 这个真源，并另加一条
> "release 仍然可选"，防止"默认 debug"被后人理解成"砍掉 release"。

### 13.2 预取引擎构件（`lib/toolchain/artifact_prefetch.dart`）

#### 两条官方路径都失效（实测，不是猜测）

用户问"debug 工具链可以提前下载吗"，第一反应是官方就有：
`flutter precache --android_maven` + 它配套的
`packages/flutter_tools/gradle/resolve_dependencies.gradle.kts`。
**两条都跑不通**：

1. `flutter precache --android_maven` 在 Flutter 3.47.4 上是**空操作**——
   `AndroidMavenArtifacts` 这个类确实存在
   （`packages/flutter_tools/lib/src/flutter_cache.dart:415`），
   但**从未被实例化**。实测：exit 0、零输出、缓存目录字节数不变。
2. 上面那个 gradle 脚本文档里让用 `gradle -b <file> <task>`，
   而 **`-b` 选项在 Gradle 9 已被删除**，实测：
   `Unknown command-line option '-b'`。

所以自建等价 groovy 脚本，用 `--project-cache-dir` 跑 `resolveDependencies`。
测试里钉死了"脚本不得出现 `android_maven` / `precache` / `gradle -b`"
——免得哪天有人"发现官方有现成的"又换回去。

#### 关键参数（都是实测值）

| 项 | 值 | 说明 |
|---|---|---|
| `io.flutter:arm64_v8a_debug` | 180.6 MB | debug 大头 |
| `io.flutter:flutter_embedding_debug` | 1.6 MB | |
| `io.flutter:arm64_v8a_release` | 42.2 MB | |
| `FLUTTER_STORAGE_BASE_URL` | `https://storage.flutter-io.cn` | **`storage.googleapis.com` 在本沙箱完全不可达**（SSL 握手直接断），必须显式给国内镜像 |
| 仓库列表 | FOA 镜像 + 阿里云 `google` / `public` | `flutter_embedding_*` 会传递依赖 androidx（实测抓 `androidx.exifinterface:1.4.1`），沙箱直连 `dl.google.com` / `mavenCentral` 不通；且 **aliyun-public 对 androidx 是 404，aliyun-google 才是 200**，两个都要写 |

**只拉 arm64 一个 ABI**：FOA 固定 `--target-platform=android-arm64`，
官方脚本还拉 armeabi_v7a / x86 / x86_64。去掉后 debug 从 ~600MB 降到 **182MB**。

#### ⚠️ Bug 635 · gradle 找不到 java 会直接退出，且 proot 的 sh 不读 profile

`env -i PATH=/usr/bin:/bin HOME=/root sh prefetch.sh` 实测报：

```
ERROR: JAVA_HOME is not set and no 'java' command could be found
```

exit 1。原因是 **proot 执行的 sh 不读 `/etc/profile.d`**，脚本里必须自己
`export JAVA_HOME=${JAVA_HOME:-/opt/jdk}` + `export PATH="$JAVA_HOME/bin:$PATH"`，
并在开跑前 `[ -x "$JAVA_HOME/bin/java" ]` 判一次，给得出人话报错（exit 5）。

端到端（真 gradle、真下载）已跑通：`BUILD SUCCESSFUL in 9s` → `PREFETCH_OK`，
182MB 落进 `~/.gradle/caches/modules-2/files-2.1/io.flutter/`。

### 13.3 Git 远端（`lib/project/git_remote.dart`）

只做 **HTTPS + PAT**，不做 SSH（手机上没有 ssh-agent，也没法管 known_hosts）。
能力：配置/删除远端、保存凭据、fetch、push、pull。

#### 凭据安全的三条硬约束

1. **落 `/root/.git-credentials`，绝不落在工程目录**——防 `git add -A` 提交，
   也防"导出源码工程"顺手带走。走 `git credential.helper store`，`chmod 600`。
2. **口令不出现在命令行**——否则会进进程参数、也会出现在 git 的报错原文里。
3. **所有展示给用户的输出先过 `scrub()`**，抹掉 `https://user:pass@`。

#### ⚠️ `GIT_TERMINAL_PROMPT=0` 是必须的，不是优化

手机上没有终端。凭据不对时 git 想在终端问用户名 → 表现为**一直转圈到超时**，
用户只看到"卡住了"。设了这个变量才会立刻失败并给出可诊断的报错。

#### ⚠️ 领先/落后**只在 fetch 之后才准**（实测推翻了我的直觉）

git 的远程跟踪引用（`origin/main`）只有 fetch 才更新。真 git 实测：

```
远端已有新提交，但不 fetch  →  AB=0 0   （UI 显示"与远端一致"）
fetch 之后                  →  AB=1 0
```

所以做成**显式「检查远端更新」按钮**，没 fetch 过就在 UI 上标注「（上次记录）」，
不假装这个数字是实时的。

顺带记一下解析：`git rev-list --left-right --count $up...HEAD` 的输出是
**「落后 领先」**（左=上游，右=HEAD），别写反。

#### 只走 `--ff-only`

分叉状态（实测 `AB=2 1`）下 `git pull --ff-only` 报
`Not possible to fast-forward, aborting`（exit 128）。**不自动 merge/rebase**——
手机上没有冲突解决界面，替用户 merge 只会把仓库搞成他看不懂的状态。
报错翻译成"先在本地处理分叉"，指路而不是硬来。

#### ⚠️ Bug 636 · `grep` 的 pattern 里不能留引号（真 bug，端到端跑出来的）

凭据去重那行最初写成：

```sh
grep -v -F "@'github.com'" /root/.git-credentials > tmp
```

单引号被当成 **pattern 的一部分**，于是一条都匹配不到 → **每次保存凭据都
追加一行**。实测存 github×2 + gitee×1 之后，`/root/.git-credentials` 里
躺着两条相同的 github 凭据。

修法：先把 host 存进变量 `H='github.com'`，pattern 写 `"@$H"`。
测试里钉了两条：`expect(s.contains('@$H'), isTrue)` 与
`expect(s.contains('"@\''), isFalse)`（后者直接禁止任何引号形态回来）。

### 13.4 签名库（`lib/project/keystore_store.dart`）

alpha.93 的签名是"一把钥匙 + 一个 `key.properties`"。用户要的是
"**我有哪些钥匙**"：同一把钥匙可以给多个工程用，一个工程可以在正式/测试之间切。

清单存 **`/root/keystores/registry.json`**（与 keystore 同目录，都在工程外）。
为什么不复用 `key.properties`：它描述的是"这个工程当前用哪把钥匙"，
语义不同，混在一起会丢信息。

#### ⚠️ Bug 637 · `keytool -list` 不加 `-v` 根本没有 `Alias name:` 行

这是本轮最隐蔽的一个。不加 `-v` 时 keytool 只打印一行摘要：

```
key0, Sep 29, 2026, PrivateKeyEntry,
Certificate fingerprint (SHA-256): 6C:10:8F:...
```

**没有 `Alias name:` 行**，于是 `grep -E "^(Alias name|别名)[：:] *"`
一条都匹配不到 → 别名列表永远为空 → 走"单别名直接用"分支 →
写进 `key.properties` 的 `keyAlias` 是**空串** → 到 gradle 里才炸。

而 `Owner:`（证书主体，给用户辨认"这把钥匙是谁的"）同样只在 `-v` 输出里有。

端到端实测（真 keytool，JDK 20）：

```
不带 -v  →  ALIASES_END（一条别名都没有）
带 -v    →  key0 / key1 / ALIASES_END
```

修法：`keytool -list -v`。测试里钉了
`RegExp(r'keytool -list -v')` 与反向的 `r'keytool -list(?! -v)'`。

同时给 `aliases()` 加了防线：**解析出空列表就直接判失败**，
不要静默返回空——空别名到 gradle 才报错，用户在手机上看不懂。

#### 顺带：keytool 报错要翻成中文

`ERR=` 里直接塞英文原话，手机用户看不懂
`Keystore was tampered with, or password was incorrect`。
加 `friendlyError()` 映射成中文结论 + 保留原文尾巴（真排查时原文更有用）。

提取错误行也踩了一下：直接 `tail -n 1` 抓到的是 `... 7 more`
（JDK 的异常堆栈摘要），改成
`grep -m1 -iE "password was incorrect|tampered|java.io.IOException|keystore"`。

#### ⚠️ Bug 638 · shell 脚本里 `\\n` 拼接会把下一行的 `echo` 吃掉

Dart 里写 `'...tail -n 1)\\\\n'` 生成的是**字面 `\\n`**，在 shell 里
`\\` 被转义成一个 `\` 后紧跟 `necho` → 整条报错变成：

```
ERR=: not found
```

（shell 把 `ERR=` 当命令执行了，而 `$d` 是空的）。
修法：那里必须用**真换行** `'\n'`。测试里钉 `expect(s.contains('necho'), isFalse)`
和 `RegExp(r'tail -n 1\)\n')`。

#### 「想用 debug 签名」的正确做法

debug keystore 的参数是**公开且固定**的（AOSP/Gradle 约定）：
alias `androiddebugkey`、口令 `android`、DN `CN=Android Debug,O=Android,C=US`、
路径 `~/.android/debug.keystore`。容器里可以造一份等价的，用 apksigner 重签。

但更要紧的一句话写在 UI 上：**debug 档构建本来就是 debug 签名**
（`signingConfigs.release` 只作用于 release 变体）。所以"想要 debug 签名的包"
最直接的办法是**切到 debug 档构建**，而不是给 release 包换 debug 签名——
后者装不上正式版。产物重签是第二条路，不是第一条。

#### 口令为什么明文存

清单里的 storePass / keyPass 是明文，UI 上明说，不假装加密。
原因：gradle 的 `key.properties` **本来就要求明文**（AGP 不支持交互式输入），
加密等于换个地方存明文，还多一层"以为自己安全了"的错觉。
真正的边界是**文件在 `/root` 下、chmod 600、不在工程目录里**。

### 仍未解决（诚实边界）

- **预取的构件只覆盖 arm64**：换 ABI（`--target-platform` 改）会重新下。
- **预取依赖容器里已有一份 gradle**：三条路都找不到 gradle 时会现搭
  （从腾讯镜像下 `gradle-9.3.1-all.zip`，约 200MB），这一步没有端到端跑过，
  只跑通了"命中已有 wrapper 分发包"那条路。
- **Git 只支持 HTTPS + PAT**：SSH 不做。SCP 形如 `git@host:path` 的 URL
  会被识别出来并明确拒绝，不会静默当 HTTPS 处理。
- **不做冲突解决**：分叉时只报错指路，不 merge、不 rebase。
- **导入 keystore 只认 JKS/PKCS12 的 PrivateKeyEntry**：
  "上传证书"（.pem/.cer，只有公钥）签不了 APK，不是本实现偷懒。
- **keytool 的 `-q` 在本沙箱 JDK 20 上不存在**（实测 `Illegal option: -q`）。
  业务代码不用它，但如果你写 e2e 造数据的脚本，别照抄网上带 `-q` 的例子。

---

## 第十四章 · alpha.96：修好生成器 ≠ 修好用户现场

### 起因

真机反馈：用户工程构建 debug 失败，反复报同一句：

```text
e: file:///root/projects/list/android/app/build.gradle.kts:10:31: Unresolved reference 'util'.
e: file:///root/projects/list/android/app/build.gradle.kts:13:34: Unresolved reference 'io'.
```

而 alpha.94 已经修过这个 bug 了。

### 根因：两层

**第一层（代码写法）**：`plugins {}` 遮蔽 `java` 标识符。

真 gradle 三组对照实测（Gradle 9.3.0）：

| 写法 | 结果 |
|---|---|
| 无 `plugins {}` + `java.util.Properties()` | ✅ `BUILD SUCCESSFUL` |
| **有** `plugins {}` + `java.util.Properties()` | ❌ `5:31 Unresolved reference 'util'` |
| 有 `plugins {}` + `import` + `Properties()` | ✅ `BUILD SUCCESSFUL` |

Flutter 模板第一行就是 `plugins {}`，所以老写法 100% 必挂。

**第二层（流程缺口，这才是真正让人反复踩的原因）**：

- 签名补丁是**写进用户工程文件**的，不是每次构建现生成的；
- `patchGradle` 的守卫是「已有 `signingConfigs {}` 就不动」，
  对老工程直接返回 `ok:false`；
- 于是**老写法原封不动留在用户文件里**，而 FOA 这边看起来"早就修了"。

> **教训**：修好生成器 ≠ 修好用户现场。
> 凡是"由工具写入用户文件"的代码，都要配一条
> **检测 + 升级**路径 —— 因为已生成的文件不会自己变新。

### 修法

三层，缺一不可：

1. **生成器**（alpha.94 已做）：改用 `import` + 简单名。
2. **检测**：`Signing.hasLegacyJavaFqn(src)` —— 只看**用法**，
   排除 `import` 行本身（否则新写的补丁会被误判成老的）。
3. **升级**：`Signing.upgradeLegacyJavaFqn(src)` —— 换简单名 + 补 import，幂等。
4. **接线**：`patchBuildScript` 在「守卫拦住完整补丁」时，
   **仍然把老写法修掉**再返回 —— 这是原实现漏掉的那一步。
5. **UI**：清单页打开时检测，检测到就在签名卡顶部显示红色警告 +
   「修复构建脚本」按钮。

### 为什么修复要独立成按钮

不能并进「生成并配置签名」—— 那个入口会**重新生成一把新 keystore**。
用户的诉求只是"让构建别报错"，不该被迫换钥匙
（换了钥匙，已上架的应用就发不了升级包）。

按钮文案里明写「不会动你的密钥」，就是为了让用户敢点。

### 端到端验证（真 gradle，非单元测试）

```text
老写法             → e: build.gradle.kts:5:31: Unresolved reference 'util'.  BUILD FAILED
upgradeLegacyJavaFqn →
    import java.io.FileInputStream
    import java.util.Properties
    plugins { id("java-library") }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }
                   → BUILD SUCCESSFUL
```

### 附带教训：lint 会自相矛盾

`Text('a' 'b' 'c')` 这种**相邻字面量拼接**会触发两条互斥的 lint：

- `prefer_const_constructors` → 让你加 `const`
- 加了之后 `unnecessary_const` → 让你删掉

解法：把文案抽成 `static const String`，`Text(_kNote, style: ...)` 整体 const。

### 仍未解决（诚实边界）

- **检测只在清单页触发**。如果用户从不打开清单页、直接用打包区构建，
  仍会撞上老写法。理想方案是在**构建前置检查**里也加一道，
  但那要改 `build_runner`，本轮没做。
- **不处理用户手写的其他全限定名**（如 `java.io.File(`）。
  `upgradeLegacyJavaFqn` 覆盖了签名补丁会产出的那几种
  （`Properties` / `FileInputStream` / `FileOutputStream` / `File`），
  别的不管。

---

## 第十五章 · alpha.97：构建流程三段优化（含一个静默 bug）

### 起因

用户一句很朴素的反馈：

> 目前的构建编译流程似乎还有可以优化的空间（例如最后的默认等待 90s）

追问澄清了三件事：

| 问题 | 回答 | 含义 |
|---|---|---|
| 「默认等待 90s」在真机上是哪种情况？ | **每次都干等满 90s** | 说明 flutter 进程**每次**都 hang，90s 是**每次的净损失**，不是偶发兜底 |
| 想优化到什么程度？ | **全流程通盘优化** | 不只盯着 90s |
| 改动时更偏向哪边？ | **宁可慢一点也别出错** | 判据必须有证据，不许为了快而误判 |

第三点的分量最重：它直接决定了 ① 该怎么写——**不能**简单把
`builtGraceSec` 从 90 调成 10 了事（那只是把误判风险调高）。

### 优化点 ①：收尾宽限期 → 产物双证据确认

**原实现的判据是纯计时**：

```dart
static const int builtGraceSec = 90;
static bool builtGraceElapsed({required DateTime? builtAt, required DateTime now, ...}) {
  if (builtAt == null) return false;
  return now.difference(builtAt).inSeconds > graceSec;
}
```

只要 `_builtAt` 非空、时间到了就收尾。**没有"产物到底好了没有"这一问** ——
所以只要 flutter 进程 hang 不退出，就必然等满。

**新判据**（`BuildRunner.builtSettled`，纯函数）：

```dart
static bool builtSettled({
  required DateTime? builtAt, required DateTime now,
  required int size, required int mtime,
  required int prevSize, required int prevMtime,
  required DateTime? lastProbeAt,
  int probeGapSec = builtStableProbeSec,   // 2s
  int graceSec = builtGraceSec,            // 20s
}) {
  if (builtAt == null) return false;
  if (size <= 0 || mtime <= 0) return false;          // 产物得"看得见"
  if (prevSize < 0 || prevMtime < 0) return false;    // 首次探测只记状态
  if (size != prevSize || mtime != prevMtime) return false;  // 还在写
  if (lastProbeAt == null ||
      now.difference(lastProbeAt).inSeconds < probeGapSec) return false;
  return true;
}
```

三条同时成立才提前收尾：

1. **产物看得见**：`size > 0` 且 `mtime > 0`。排除"目录项已建、内容未写"。
2. **两次读数完全相等**：大小 **和** mtime 都不变。
3. **两次探测间隔 ≥ 2s**：挨太近的"一致"没有信息量——0.5s 内没变不能
   说明写完了，只能说这 0.5s 没动。

> **为什么判据是"稳定性"而不是"够大"**：APK 大小本就波动（debug/release、
> 依赖增减都会变），任何绝对阈值都会在某个项目上失效。稳定性是无量纲的，
> 判据不随项目漂移。

`_poll()` 里的两级结构：

```dart
if (status == BuildStatus.building && _builtAt != null) {
  if (await _probeSettled()) {          // ① 证据成立 → 立刻收尾（1~3s）
    await _finish(0); return;
  }
}
if (status == BuildStatus.building &&
    builtGraceElapsed(builtAt: _builtAt, now: DateTime.now())) {
  await _finish(0); return;             // ② 证据凑不齐 → 等满 20s 兜底
}
```

宽限期本身 **90 → 20**：它现在的语义是"确定不了时的上限"，不再是
"每次要等的时间"。真机实测 flutter 收尾 <5s，90s 那个数字是当年判据
只有计时时才需要的极宽余量。

**取舍的落点**：① 的证据要求**严**（size 与 mtime 双双相等 + 间隔够），
凑不齐就走 ②。**绝不允许"没看到产物也按成功收尾"** —— 那正是用户
明确要求避免的误判方向。

### 优化点 ②：前置检查合并进主 shell

原实现在 Dart 侧单独发一次 exec 查 Flutter 是否存在：

```dart
if (!bare) {
  final probe = await bridge.exec(
    'test -x /opt/flutter/bin/flutter && echo __OK__ || echo __NO__',
    timeoutSec: 30,
  );
  ...
}
```

紧接着又要发一条大 shell 跑 stampFix/diag/heal。**两次容器往返**里，
第一次只查一个文件——纯浪费。现在并入主 shell 最前段：

```dart
static const String prootFlutterProbe = r'''
test -x /opt/flutter/bin/flutter || {
  echo "FOA_PREFLIGHT_NOFLUTTER=1"
  exit 65
}
''';
```

放在**最前面**是有意的：缺 SDK 时立刻退出，不浪费后面那段的诊断时间。
`exit 65` 由 `_finish` 翻译回原本那句引导文案（挪进 shell 后要把它补回来，
否则用户只看到一个裸的 `exit 65`）。

### 优化点 ③：pub get 指数退避

原来每源固定 `sleep 3`：3 源 × 2 次 = **最坏 18 秒纯等待**。

```dart
'b=1; '
'for i in 1 2; do '
'if PUB_HOSTED_URL=$src <flutter> pub get; then ok=1; break 2; fi; '
'sleep $b; b=3; '
'done; '
```

`b=1` 必须在 `for src` 循环体内、`for i` 之前 —— 换源时重置回 1s
（换了一个源等于重新开始，第 2 源不该继承第 1 源用过的 3s）。

**诚实说明**：正常网络下这条改动**几乎看不出差别**（顺利路径本来就是
0s 等待，成功即 break）。它的价值只在弱网抖动时少等几秒。退避秒数也
刻意偏保守（没上 0/1/2 那种激进序列）——弱网是这条链路的主要场景，
退避太短会把"本来第二次就能成功"变成"两次都撞在同一个抖动窗口上"。

### 顺带撞出的一个静默 bug（本节最值得记的部分）

给 ③ 写"termux 不该出现容器路径"的断言时，**断言挂了 —— 而挂的是代码**。

`diag` / `heal` / `reassert` / `stampFix` 四段脚本的路径原先**全部写死
容器值**（`QemuCompat.flutterHome` = `/opt/flutter`、
`QemuCompat.sdkHome` = `/opt/android-sdk`），而 **termux 后端的 Flutter
与 SDK 装在 prefix 下**（`TermuxPaths.flutterHome/env`）。

路径错的表现不是报错，而是**整段整段地静默短路**：

| 段 | 短路点 | 静默后果 |
|---|---|---|
| `stampFix` | `mkdir -p "$C"` 写一个不存在的目录 | Bug 436 想省的 `git fetch --tags` 在 termux 下**从未省掉** |
| `diag` | `[ -x @QEMU@ ] \|\| exit 0` 之后的路径判断 | 日志里连 `QEMU_CHAIN_*` 都没有 |
| `heal` | `[ -d "$F/bin/cache" ]` 等判断全不成立 | `HEALED=0`，自愈是**空跑** |
| `reassert` | 第一句就是 `[ -d "$E" ] \|\| exit 0` | 转发层重建是**空跑** |

**为什么藏了这么久**：每一段都"有输出"。`REASSERT=0`、`HEALED=0` 都是
**合法的正常输出**——从日志上完全看不出是"跑了但什么都没做"还是
"本来就没事"。

修法：把 `QemuCompat.fill` 的 `@FLUTTER@` / `@ENGINE@` / `@SDK@` 三个
占位符参数化：

```dart
static String fill(String script, {
  String sdk = sdkHome, String proj = '',
  String? flutterHomeOverride,
  String? engineDirOverride,
  String? sdkHomeOverride,
}) => script
    .replaceAll('@ENGINE@', engineDirOverride ?? engineDir)
    .replaceAll('@FLUTTER@', flutterHomeOverride ?? flutterHome)
    .replaceAll('@SDK@', sdkHomeOverride ?? sdk);
```

`buildCommand` 按后端传入（默认值保持不变，proot 语义完全不受影响）：

```dart
flutterHome: bare ? TermuxPaths.flutterHome(env) : QemuCompat.flutterHome,
engineDir: bare ? '${TermuxPaths.flutterHome(env)}/bin/cache/artifacts/engine'
                : QemuCompat.engineDir,
sdkHome: bare ? TermuxPaths.sdkHome(env) : QemuCompat.sdkHome,
```

### 元教训

> **"有输出"不等于"做了事"。**
>
> 凡是「查一下、没有就跳过」的幂等脚本，都要能区分
> 「检查通过」和「检查根本没跑到」两种情况。
>
> 这两者在日志上长得**一模一样**。项目里已经被这个形态坑过两次
> （Bug 445 的 `REASSERT=0` 是"一个文件都没重建"，第十四章的
> `Unresolved reference` 是"补丁没打上但守卫说没事"）。
>
> 可行的做法：**幂等脚本的"跳过"要说清楚跳过的是什么**。
> 比如 `SKIP=路径不存在(/x/y)` 而不是静默 `n=0`。

### 端到端验证

| 验证项 | 方法 | 结果 |
|---|---|---|
| 生成的 shell 语法 | 导出 proot / termux 两个后端的完整命令，`bash -n` | 均通过 |
| termux 路径后端感知 | 正则扫 `[CFES]=/opt/(flutter\|android-sdk)` | **无残留**（原先 4 处） |
| proot 语义不变 | 默认参数下断言 `C=/opt/flutter/bin/cache` 等 4 条 | 全部保持 |
| 判定逻辑 | `builtSettled` 8 条边界（首探/一致/变大/同大小重写/挨太近/size=0/无 Built） | 全过 |
| 全量回归 | `flutter test --concurrency=1` | **1749 通过 / 0 失败** |

### 仍未解决（诚实边界）

- **改动全在真机链路，沙箱验不了实际耗时**。我能证明的是：生成的 shell
  语法正确、判定逻辑的边界行为正确、termux 路径不再写死。**「90s 变成
  几秒」这个数字需要用户真机对比** —— 我按判据推算典型路径 1~3s
  （探测间隔 2s 是硬下限，500ms 轮询下两次采样要跨过 2s 需 5 个 tick），
  但这是**推算不是实测**。
- **②的收益是"少一次容器往返"**，具体多少毫秒取决于真机 proot 启动
  开销，我没有这个数字。
- **没有做"跳过没脏的 reassert"**（原计划的优化点②的另一半）。评估后
  放弃：reassert 是 Bug 428/433/445 三道防护的落点，而它的"脏检查"
  本身也要遍历同一批目录——**检查成本和执行成本同阶**，省不下什么，
  却要承担"误判为干净而跳过"的风险。与用户的取舍不符，故不做。

---

## 第十六章 · alpha.97 出包时撞出的两个记账问题

出包时六项验证报"五项未通过"（ABI 找不到、签名失败、图标缺失、文案没进包）。
**这不是代码坏了，是两个工具侧的问题叠加**，差点让我重出一版包。

### 16.1 `cp` 返回 ≠ 落盘完成（Bug 627 的同族）

**现象**：

```
$ sha256sum dist/FOA-...-arm64.apk
sha256sum: ...: Input/output error
【1/5】ABI 架构   实际：（空）   ❌ 未找到 arm64-v8a
【3/5】签名        ❌ 签名验证失败
```

**诊断**：先怀疑构建产物坏了。分别读两个文件：

| 文件 | `dd` 全量读 | 结论 |
|---|---|---|
| `build/.../app-release.apk`（源） | 88.7 MB，5.2 GB/s，**无错** | 好的 |
| `dist/FOA-...-arm64.apk`（`cp` 出来的） | 3.6 MB 处 `Input/output error` | **坏的** |

源文件完好、只有拷贝坏了 → 问题在 `cp` 这一步。

**根因**：`cp` 返回成功只代表**数据进了页缓存**，不代表**落到设备**。
紧接着的 `sha256sum` 全量回读时撞上内核仍在回写的脏页 →
这个文件系统（overlayfs，同 Bug 627 的环境）对"正在回写的页"的读取
会直接返回 `EIO`。

**验证**：等一会儿再 `dd` 同一个文件 → **完整读出**（86 MB/s，从盘上读的
速度）。再 `sha256sum` → 与源文件**完全一致**。
也就是说**文件从头到尾都是好的**，只是有那么一个窗口读不得。

**修法**：`cp` 之后加 `sync` 再校验。已写进 `release.sh` 的建议：

```bash
cp "$BUILT" "$APK_OUT"
sync                      # ← 必须：cp 返回 ≠ 落盘完成
sha256sum "$APK_OUT"
```

> 判断"怎么区分？"——**看源文件**。如果源文件能完整读、只有拷贝读不了，
> 那就是落盘时序问题，等一会儿/`sync` 一下即可，**不要重出包**。
> 如果源文件本身也读不了，那才是构建真出了问题。

### 16.2 AOT 里 ASCII 串与 CJK 串编码不同（验证脚本的假阴性）

修好 16.1 后，第 6 项仍然报：

```
【6/6】本次改动的 UI 文案已编进 libapp.so
  ❌ 以下文案没进包：FOA_PREFLIGHT_NOFLUTTER=1
```

**先做的一个关键动作：拿上一版已验证过的包做对照**（`alpha.96`）。
结果对照包**同样"什么都没搜到"** —— 连当年六项全绿的 `修复构建脚本`
都 MISS。

> **这一步救了我**：如果只看新包，我会以为是自己这轮改动把文案弄丢了，
> 然后去翻 `buildCommand` 的接线——方向完全错，而且大概率会"修"坏
> 本来正确的东西。**对照一个已知良好的样本，能立刻把"代码问题"和
> "测量问题"分开。**

**根因**：`verify_apk.sh` 第 6 项一律按 **UTF-16LE** 搜字节
（`s.encode("utf-16-le")`）。这个约定对**中文串**是对的——Dart AOT
把含 CJK 的字符串升成 UTF-16LE。

**但纯 ASCII 串走 Latin-1 快路径，一个字符一个字节**（即 UTF-8/ASCII
形态）。所以：

| 串 | UTF-8 | UTF-16LE |
|---|---|---|
| `产物落盘确认` | MISS | **IN** |
| `FOA_PREFLIGHT_NOFLUTTER=1` | **IN** | MISS |

纯 ASCII 的 needle 用 UTF-16LE 搜**永远搜不到**，哪怕它明明在包里。

**修法**：两种编码都试，命中任一即算在。

```python
def present(s, d):
    return s.encode("utf-16-le") in d or s.encode("utf-8") in d
```

这不是放宽标准——**两种都找不到才是真的不在包里**。

**教训**：`needles` 列表过去**全是中文**，所以这个编码缺口一直没暴露。
本轮我挑了一条 ASCII 串（因为它在 Dart 里是没有插值的字面量，
"唯一且稳定"），正好撞上。**测试用例的输入分布变了，才会暴露
原本就存在的判据缺口。**

### 元教训（两条）

> **① 出包验证失败时，先分清"产物坏了"还是"测量坏了"。**
> 最快的分法：**拿一个已知良好的样本跑同一套测量**。
> 对照样本也挂 → 测量有问题；对照样本正常 → 才是产物有问题。
>
> **② `sync` 是"我刚才写的东西能不能被下一个人读到"的问题，
> 不是"保险措施"。** 凡是"写完立刻全量回读校验"的流程
> （出包归档、校验和、打包），`cp`/写入之后都要 `sync`。

---

## 第十七章 · Bug 636：`Removing unused resources requires unused code shrinking`

### 17.1 用户报障的原话与真实处境

用户贴出 debug 构建日志后说：

> `怎么又出现这个bug了，一直反复是为什么`

**报错原文**：

```
Build file '/root/projects/my_demo/android/build.gradle.kts' line: 19
A problem occurred configuring project ':app'.
> Removing unused resources requires unused code shrinking to be turned on.
  See http://d.android.com/r/tools/shrink-resources.html for more information.
```

"又"和"反复"是本轮最需要先拆掉的认知陷阱。**从技术上看，这和之前的
`Unresolved reference 'util'/'io'` 完全是两个 bug**：

| # | 出问题的地方 | 我们的代码在哪一层 | 用户感知 |
|---|---|---|---|
| ① | `scripts/` 里老写法的构建脚本 | **就是我们自己写的**，alpha.94/96 改的是这里 | "又报错了" |
| ② | 生成器修了 ≠ 用户现场修了 | 我们改了模板，但用户工程里是**旧脚本** | "修了怎么还报" |
| ③ | **本次**：AGP 配置期校验 | **我们连碰都没碰到** —— 是 Gradle/AGP 在读 `build.gradle.kts` | "又报错了" |

**三者是独立的**。用户看到的是"错误提示又出现了"，所以主观上是"同一个
bug 反复"；但从链路看，这是**第三个不同的坑**。诊断的第一步永远是
**把报错原文和上一次的报错原文并排看**，而不是凭主观印象。

### 17.2 根因：三层叠加

#### 第一层 — AGP 的硬校验（字节码实证，不是推测）

反编译 `gradle-8.13.1.jar` 里的
`com/android/build/api/component/impl/features/AndroidResourcesCreationConfigImpl`：

```java
public boolean getUseResourceShrinker() {
    if (!getResourcesShrink()) return false;          // 资源缩减没开 → 无所谓
    if (componentType.isForTesting()) return false;   // ← 注意这条
    if (!getMinifiedEnabled()) {
        issueReporter.reportError(
            "Removing unused resources requires unused code shrinking ...");
        return false;                                 // ← 是 error，不是 warning
    }
    ...
}
```

判据一句话：

> **`shrinkResources = true` 且 `minifyEnabled = false` → 配置期致命错误。**

`reportError` 不是 `reportWarning`——它会直接让 configuration 阶段失败，
**构建根本进不到编译**。这就解释了为什么日志里连一条编译错误都没有。

#### 第二层 — Flutter Gradle 插件**无条件**设值

`/opt/flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt:216-219`：

```kotlin
release {
    isMinifyEnabled = true
    isShrinkResources = isBuiltAsApp()
}
```

注意 **没有 if**。Flutter 插件对 `release` buildType 无条件设这两个值。

`FlutterPluginUtils.kt:39, 226-231`：

```kotlin
const val PROP_SHOULD_SHRINK_RESOURCES = "shrink"
fun shouldShrinkResources(project: Project): Boolean =
    project.findProperty(PROP_SHOULD_SHRINK_RESOURCES)?.let { ... } ?: true
```

默认 `true`。

**所以任何 Flutter 工程，`release` 块的这两个值天生就是
`minify=true, shrink=true`。** 一旦有谁把 `minifyEnabled` 改成 `false`
却没同步改 `shrinkResources`，就踩中第一层的硬校验。

#### 第三层 — 为什么 **debug** 也炸

用户跑的是 `--debug`，报错却在 `configuring project ':app'`。
原因：debug buildType 的属性通过 `initWith(debugBuildType)` / 变体
继承链**拿到了 `buildTypes.release` 的属性**。

> **在 `release` 块里手动关 minify，会把 debug 的配置**一起**搞挂。**

Gradle 在 configuration 阶段就整体失败了，所以"我明明只改过 release"
并不成立——**buildTypes 的属性是会被继承的**。

### 17.3 为什么我们之前的修复"漏了"

我们的 `ManifestCodec._syncShrinkResources` 有个设计前提：
**只在"文件里已经有 `shrinkResources` 这一行"时才改**。

而用户现场是：那一行**是别的机制写进去的**（插件默认 / 模板 / 继承），
我们的 UI 读 `minify` 时通过 `parseGradle` 拿到的是 **`true`**——
但那个 `true` 是 **AGP 的 release 默认值**，不是用户写的。

结果：开关显示"开"，用户看不出问题，**我们什么都不会改**。

> **这里有一个必须说清的判据原则**：`parseGradle` 读到的
> `minify=true` 可能是 AGP 的默认值（`minifyExplicit=false` 时）。
> **拿默认值当判据去改用户的文件 = 误改**。所以检测必须要求
> **两个值都显式写了**。

### 17.4 修法：只改 shrink，绝不碰 minify

新增三个方法（`app/lib/project/manifest_codec.dart`）：

```dart
/// 检测**显式**字面值。返回 null = 文件里没有这一行（不是"值为 false"）。
static bool? explicitShrinkResources(String text) {
  final m = RegExp(r'(?:isShrinkResources|shrinkResources)\s*=?\s*(true|false)')
      .firstMatch(text);
  if (m == null) return null;
  return m.group(1) == 'true';
}

static bool? explicitMinify(String text) { /* 同上，匹配 isMinifyEnabled/minifyEnabled */ }

/// Bug 636 检测：构建脚本是否处在 AGP 会拒绝配置的非法组合上。
static bool hasIllegalShrinkCombo(String text) {
  final shrink = explicitShrinkResources(text);
  final minify = explicitMinify(text);
  return shrink == true && minify == false;
}

/// Bug 636 修复：选的是**改 `shrinkResources` 而不是 `minifyEnabled`**。
static ({String code, bool changed}) fixIllegalShrinkCombo(String text) {
  if (!hasIllegalShrinkCombo(text)) return (code: text, changed: false);
  final sync = _syncShrinkResources(text, false);
  return (code: sync.code, changed: sync.code != text);
}
```

**为什么改 shrink 而不改 minify**：

- `minifyEnabled = false` 是用户**刚刚手动设的**，是他明确的意图 → **不能推翻**；
- `shrinkResources = true` 多半来自 Flutter 插件的默认 → 关掉它代价最小
  （只是包大一点，不影响功能）。

**接线**（`app/lib/toolchain/build_runner.dart`，插在磁盘空间检查之后、
真正启动构建之前）：

```dart
if (!bare) {
  final fixed = await _fixIllegalShrinkCombo(name);
  if (fixed != null) { lines.add('⚠ $fixed'); lines.add(''); _ui(); }
}
```

**为什么必须放在构建前而不只在清单页**：用户可能**从不打开清单页**——
他就直接点打包。前置检查是唯一能救到他的地方。

### 17.5 `--no-shrink` 是空 flag（流传很广的误解）

用户日志里那条命令带 `--no-shrink`，很多人以为它能解决这个问题。
**它不能。** `flutter_command.dart:986` 的 help 原文：

```
'This flag has no effect. Code shrinking is always enabled in release builds.'
```

而且它**不映射**到 `-Pshrink=false`——全仓库只有 deferred components
那条分支会设该属性（`gradle.dart:613`）。所以：

> 构建命令里的 `--no-shrink` 是**装饰性的**，它既不关代码缩减，
> 也不关资源缩减，更不会让 AGP 的配置期校验放过你。

`-Pshrink` 属性确实存在（`FlutterPluginUtils.kt:39`），但那是
**给 deferred components 用的**内部通道。

### 17.6 端到端验证

| 项 | 结果 |
|---|---|
| `flutter analyze lib/` | `No issues found!` |
| `flutter test test/manifest_codec_test.dart` | **66 条全过**（原 53 + 新增 13） |
| 全量门禁 `flutter test` | **1762 全过**（1749 + 13） |

新增 13 条里有 **4 条专门测"不误报"**：

| 输入形态 | 期望 | 理由 |
|---|---|---|
| 只有 `shrink=true`，minify 没写 | **不报** | minify 走插件默认 = true，合法 |
| `shrink=true` + `minify=true` | **不报** | 这正是 Flutter 插件默认形态 |
| shrink 没写 | **不报** | 官方模板形态 |
| `shrink=false` + `minify=false` | **不报** | 合法组合 |

以及一条**接线护栏**（防止将来有人把前置检查挪到构建启动之后）：

```dart
final fixAt = src.indexOf('await _fixIllegalShrinkCombo(');
final buildAt = src.indexOf('execStream(cmd');
expect(fixAt > 0 && buildAt > 0 && fixAt < buildAt, isTrue,
    reason: '修 shrink 组合必须在启动构建之前 —— 晚了 AGP 已经拒绝了');
```

### 元教训（三条）

> **① 用户说"又是这个 bug"时，先把两次报错原文并排贴出来。**
> 主观的"又"和客观的"同一个"经常不符。本轮三个坑分别位于
> scripts 层、流程层、AGP 配置层——**同名感受，不同链路**。
>
> **② 判据要取"显式值"，不要取"读到的值"。**
> `true` 可能是默认值。拿默认值当判据去改用户文件，
> 会把"本来没问题的工程"改坏。**只有用户明确写了，才能当意图。**
>
> **③ 兜底要放在"用户一定会经过"的地方。**
> 清单页的修复只有打开清单页才生效。构建前置检查
> 才是所有路径的交汇点。

### 诚实边界

- **只覆盖 Kotlin DSL / Groovy 两种 `build.gradle` 形态**（`android/app/`），
  没有处理 `buildSrc` 或根工程里定义的 `buildTypes` 变体。
- 检测用**正则**而非解析器。若 `shrinkResources` 出现在注释里，
  正则也会命中。代价可接受（修复是改成 `false`，方向安全），
  但如果将来要做"精确语义分析"，这里需要换成真正的 Gradle 解析。
- **debug 变体继承 release 属性**这一条是从报错现象 + Gradle 继承语义
  反推的，没有单独写一个最小复现工程验证。若要 100% 闭合，需要
  在真机上建一个只有 `release { isMinifyEnabled = false }` 的最小工程跑
  debug 构建。**本轮没做这一步**。

---

## 第十八章 · alpha.98 出包时撞到的两件事（都是**测量**问题）

出包流程本身跑通了（门禁 1762 全过、release 构建 201.9s 出 88.7MB 包），
但归档与验证两步各挂了一次。**两次挂的都不是代码，是测量。**

### 18.1 `cp` 的脏页窗口又来了（Bug 627 / 16.1 的第三次复发）

```
3/5  归档到 dist/
sha256sum: .../dist/FOA-v0.1.0-alpha.98-arm64.apk: Input/output error
❌ 归档文件校验和回读不一致（ vs ）——多半是落盘问题，重跑本步即可
```

注意这次的**报错形状变了**：上一版（16.1）是校验和算出来了但**对不上**；
这次 `sha256sum` 直接 `EIO`，两个变量都是空串，所以才打印出 `（ vs ）`
这种空对空。**同一个根因，两种表现**。

**用 16.1 立下的判断法复核**：

| 文件 | `dd` 全量读 | 结论 |
|---|---|---|
| `app/build/.../app-release.apk`（源） | 88748892 bytes，**22.8 GB/s，无错** | 好的 |
| `dist/FOA-...-arm64.apk`（`cp` 出来的） | **0 bytes copied**（一个字节都读不出） | 坏的 |

源能读、拷贝读 0 字节 → **落盘时序**，不是构建坏了。**不要重出包。**

**处置**：重跑归档步骤，`cp` 前后各 `sync` 一次 + 隔 2s 再 `sync`，然后
`sha256sum` 回读比对 → **两文件哈希完全一致**（`ea511e0d...c5b5`）。

> **为什么 `release.sh` 里明明已经加了 `sync` 还会中招**：
> `sync` 与 `cp` 之间仍有窗口 —— `sync` 返回后内核可能刚开始回写新拷的
> 页。**`sync` 降低概率，不等于消除。** 真正的判据只能是**回读复核**，
> 也就是 `release.sh` 里那段 `[[ "$ACTUAL" == "$EXPECT" ]] || die`。
> **它这次正确地拦住了我** —— 这就是它存在的意义。

**这一条现在是第八次同族**（627 → 16.1 → 18.1）。**结论应该升级为环境常识**：
这个 overlayfs 上"写完立刻全量回读"是不可靠操作，凡此类流程一律
**写入 → sync → 回读复核**，三者缺一不可，且**回读复核是唯一有效的那一步**。

### 18.2 我把**注释**当成了 needle（验证脚本的第二次假阴性）

修好归档后，六项验证报：

```
【6/6】本次改动的 UI 文案已编进 libapp.so
  ❌ 以下文案没进包：Removing unused resources
```

当时的判断路径很关键，记下来：

1. **先看别的三条** —— `isShrinkResources`、`已自动修复`、
   `FOA_PREFLIGHT_NOFLUTTER=1` **都命中了**。这说明：
   - AOT 里确实有我这几轮改的东西；
   - 双编码比对（17.2 那个修正）也工作正常。
2. 于是问题被压缩成一句话："为什么**只有这一条**不在？"
3. `grep` 一下这条串在源码里的位置：

```
app/lib/toolchain/build_runner.dart:508:    //   > Removing unused resources requires unused code shrinking
```

**行首是 `//` —— 它在注释里。** 注释被编译器剥掉，AOT 里当然没有。

> **我犯的错**：挑 needle 时想的是"这是报错原文，最稳定最唯一"，
> 但**我根本没有回到源码去确认它是不是一个运行期字符串**。
> 这是纯粹的选样错误 —— 测量选错了对象。

**修法**：换成真正在字符串字面量里的三条，并且把"选 needle 前先 grep
确认行首不是 `//`"写进脚本注释当规程：

```python
"检测到 ",                        # 检测命中的告警（修复/未修复两条共用前缀）
"已自动修复",                      # 前置检查真的改写了文件的日志
"isShrinkResources → false",     # 修复说明里的箭头（含中文 →，走 UTF-16LE）
"FOA_PREFLIGHT_NOFLUTTER=1",     # 反向护栏
```

重跑 → **六项全部通过**。

**中间还踩了一个自己挖的坑**：第一版修法里我写了
`"检测到 $rel 里 isShrinkResources=true 而 ".replace("$rel ", "")` ——
想用 Python 消掉插值占位符。结果 `replace` 把 `$rel ` 真删了，needle 变成
`"检测到 里 isShrinkResources=true 而 "`（中间一个空格），照样 MISS。

> **教训**：**别用"运行期字符串变形"去构造 needle。** 你以为在"清理"，
> 实际是在把 needle 改成另一个（更不可能存在的）串。needle 应该是
> **源码里逐字出现的、肉眼可核对的那一段**。想省略就直接截短，
> 不要在脚本里做替换运算。

### 元教训

> **① `sync` 降低概率，回读复核才是判据。**
> 任何"写入后立刻全量读"的流程都必须有一步**独立的回读比对**，
> 且它必须能**真的失败**（这次它就失败了，正确拦下了我）。
>
> **② 一条 needle 挂了、其他三条过了 → 先怀疑 needle，别怀疑代码。**
> `grep` 一下它在源码里是**注释**还是**字符串**，一行就能定性。
> 不要因为一条测量失败就去翻接线 —— 那是最容易把正确代码"修"坏的方向。
>
> **③ needle 必须是"只有那段逻辑才会产生"的串。**
> 属性名（如 `isShrinkResources`）在注释和代码里都出现，命中它
> 证明不了任何事。宁可挑带上下文的整句。

---

## 第十九章 · Bug 638 / Bug 639 + 开源化打包（alpha.98 收尾）

这一章记的是"把项目整理成能上传 GitHub 的正式仓库"这一轮撞到的事。
前半是两条 bug 的收尾（638 / 639），后半是**打包本身**踩的三个坑 ——
后一半更值得看，因为那三个坑都表现为"**没报错，但结果是错的**"。

### 19.1 Bug 638：老写法签名脚本的检测要进构建前置检查

**症状**（真机构建）：

```
e: build.gradle.kts:5:31 Unresolved reference 'util'
e: build.gradle.kts:5:31 Unresolved reference 'io'
```

**真因**：Flutter 模板的第一行是 `plugins {}`，而 Kotlin 的 `plugins` 块是
**隐式 receiver 作用域**，会遮蔽 `java` 这个**顶层包标识符** —— 于是
`java.util.Properties()` 里的 `java` 被解析成"某个对象的属性"，找不到。
补 `import java.util.Properties` 再用**简单名** `Properties()` 就没这事。

**为什么这 bug 会"修好了还复发"**：alpha.94 修的是**生成器**（新工程不再
产出老写法），但**已经打过旧补丁的工程不会自动回写**。用户反复构建、反复
报错，我们这边看日志觉得"早就修了" —— **生成器修了 ≠ 用户现场修了**。

**落地**：在 `build_runner.dart` 的前置段（与 Bug 636 的 shrink 检查同一处、
都在 `execStream(cmd` 之前）接上 `Signing.repairLegacyPatch`：

```dart
if (!bare) {
  final r = await Signing.repairLegacyPatch(FsBridge(), projectName: name);
  if (r.changed) { lines.add('⚠ ${r.msg}'); lines.add(''); _ui(); }
}
```

`repairLegacyPatch` 内部已挡掉两种情况：Groovy DSL（没有这个遮蔽问题）、
以及"根本没有老写法"。**按 `r.changed` 判定才打日志**，否则每次构建都刷
无意义警告。

回归测试 5 条（`app/test/signing_test.dart`）：接线存在 / 顺序在构建之前 /
与 636 同处前置段 / 按 `changed` 判定 / Groovy 工程不被改。

> **诚实边界**：`settings.gradle.kts` 不受影响，实测确认过 —— 它的
> `pluginManagement {}`（含 `java.util.Properties()`）与 `plugins {}` 是
> **两个独立的顶层 receiver**，不互相遮蔽。所以修复范围只覆盖
> `android/app/build.gradle*`，正确，无需扩大。

### 19.2 Bug 639：`platform/` 模板与 `android/` 实际文件的漂移门禁

背景是手册 Bug 440：`platform/android/MainActivity.kt`（新工程模板）比
`android/` 里的实际副本落后一个月，而新工程是从 `platform/` 生成的。

**做了两样东西**：

| 工具 | 作用 |
|---|---|
| `tools/sync_platform.sh` | 检查（不一致退出码 1）/ `--fix` 写回 |
| `app/test/platform_drift_test.dart` | 4 条：逐字节相同、非空、映射表与脚本一致、模板目录没被误删 |

**只做逐字节比对，不做语义分析** —— 语义分析正是当初漏掉它的原因。

**映射表只列"两份都该存在的副本"**。`platform/android/pty/foa_pty.c`
**不在表里**：它是 C 源码，编译产物是 `assets/tools/foa_pty`，单向派生，
不是副本。

**门禁自己也被验证过**：人工注入漂移 → 测试报"首个差异在第 64 行"、
脚本 exit 1；`--fix` 能同步回；退出码正确（漂移 1 / 一致 0）。验证后还原。

### 19.3 打包：三个"静默错误"的坑

#### 坑一：`--exclude` 的前缀写错 → 静默失效

```bash
# ❌ 早期写法：cwd 在 /workspace，却写了相对 -C 之后的完整路径
tar czf out.tar.gz -C /workspace --exclude='FOA/FOA/app/build' FOA
```

排除路径是**相对于 `-C` 的目录**的。前缀写错不报错，只是不生效 ——
包从 87MB 涨到 **590MB**，且自检时才发现。

**修法**：cwd 进到仓库根、用 `.` 打包、路径统一 `./xxx`，
并且用 `--exclude-from=FILE`。**清单固化到 `tools/package-excludes.txt`**。

#### 坑二：`grep -F` 是子串匹配 → 假阳性

校验"排除是否生效"时用了 `grep -qF "$p"`，结果报了两个**不存在的失败**：

```
❌ 排除失效: ./app/build 仍在包里
❌ 排除失效: ./app/android/build 仍在包里
```

因为 `./app/build` 命中 `./app/build_progress_preview.html`、
`./app/android/build` 命中 `./app/android/build.gradle.kts` ——
两个都是**必须入库**的源码文件。

**正确判据**：条目 == 规则本身，**或**以 `规则 + "/"` 开头。
不变量固化成测试：**任何排除规则都不许命中 git 跟踪的文件**
（`app/test/package_excludes_test.dart`，7 条）。

#### 坑三：`sha256sum -c` 按 cwd 找文件

校验文件里写的是 basename，`sha256sum -c` 会**按当前 cwd** 去解析，
而脚本的 cwd 是仓库根、不是包所在目录 → 永远 `No such file`。
必须 `cd "$(dirname "$OUT")"` 再校验。

### 19.4 rootfs：**没有公共下载源**（这条影响你敢不敢删它）

整理时差点把 `app/assets/rootfs/debian-minbase-arm64.tar.gz`（75MB）当成
"可以从网上重新下载的资产"给排除掉。**不能。**

`app/tools/fetch_assets.sh` 里：

```bash
if [[ -n "${ROOTFS_URL:-}" ]]; then ... else
  # 打印 debootstrap 自建配方，然后 exit 1
```

`ROOTFS_URL` **没有默认值**。也就是说：

- proot / libtalloc / libandroid-shmem → 有 Termux apt 直链，**可再生**
- rootfs → **没有下载源**，丢了只能 `debootstrap` 自建（需 x86_64 Linux，
  约 20 分钟，还要 qemu-user-static 跑 second-stage）

所以 `tools/make_release_tarball.sh` **默认带上它**，只提供 `--slim` 才排除。
它仍然被 `.gitignore` 排除 → **不会进 GitHub**（`git push` 只推已跟踪文件），
带上它纯粹是"解包即可构建"的便利。

> **顺带纠正我自己的一个错**：整理时我曾说"rootfs 是 git 跟踪的、会推进
> GitHub"。**这是错的**。依据是 `.gitignore:39` 明确排除了它、
> `git ls-files app/assets/rootfs/` 只返回 `.gitkeep`、
> `git cat-file HEAD:app/assets/...` 报 `exists on disk, but not in HEAD`。
> 我当时把"87MB 的包体积"当成了"git 仓库体积"，两者不是一回事：
> git 仓库本身只有 **4.7MB / 406 文件**，最大单个文件 0.55MB。

### 19.5 元教训

> **① "没报错"不等于"对了"。**
> 这一轮三个打包坑全是静默错误：`--exclude` 前缀错（590MB）、
> `grep -F` 子串（假阳性）、`sha256sum -c` 的 cwd（假失败）。
> **凡是"校验"步骤，都要先证明它能真的失败。**
>
> **② 排除清单这类"规则文件"必须配一条不变量测试。**
> 光有清单不够 —— 有人加一条规则就可能把源码文件排掉。
> 钉死"不许命中 git 跟踪文件"这一条，比列一百条具体路径都有效。
>
> **③ 区分"可再生"和"丢了就没了"。**
> 打包时这是唯一的分类标准。产物 2.8GB 全可删；
> 75MB 的 rootfs 反而是最不该删的那个。

### 19.6 移除 proroot：一个"从未投入使用"的抽象该怎么拆（2026-09-30）

**决策依据**（四条同时成立才敢删）：默认关闭、上游 `libproroot.so` 是
**Proprietary**、alpha.69 起下载入口已停用（`fetch_proroot` 固定报错返回 1）、
Debian 12/13 上实测不可用（Bug 471 系列）。**从未投入使用**是决定性的一条。

**删除清单（实测）**：

| 类别 | 内容 | 量 |
| --- | --- | --- |
| 整文件删除 | `proroot_option.dart` / `proroot_download.dart` / 3 个专属测试 / 许可决策文档 | 6 个 |
| lib 引用点 | toolchain_page / about_info / termux_backend / build_runner / proot_bridge / models / native_events / theme / onboarding | 9 个 |
| 原生 | 两份 `MainActivity.kt`（含 5 个 MethodChannel handler + `onActivityResult` 分支） | 约 1500 行 |
| 脚本 | `fetch_assets.sh`（437→305 行）/ `setup_android.sh` | 2 个 |
| 文档 | README 两节 / `THIRD-PARTY-NOTICES.md` 整节 / `.gitignore` | 3 处 |
| 测试 | `about_info_test` / `bug464_...` / `native_events_test` 中的相关用例 | 3 个 |

**关键洞察：抽象是跟着需求来的，需求没了抽象就该消失。**
`BuildBackend`（proot/termux，决定"在不在容器里"）与 `ContainerLayer`
（proot/proroot，决定"进容器用哪套路径翻译"）是**正交**的两个维度 ——
后者只为 proroot 存在。删掉 proroot 后 `ContainerLayer` 只剩一个枚举值，
`ContainerPrefs`（`foa-container.json`）也就没有持久化意义了，**连同删掉**。
如果只删二进制、留着枚举，那份代码会变成"永远走 else 分支"的死路。

**连带死亡代码（不删会报错）**：Kotlin 的 `isElf`、Dart 的 `_strList`
只被 proroot 路径使用，留着直接触发 `unused_element`。
**删大块功能时，最后一轮要专门跑一遍"谁还在用你"的反向搜索。**

**踩坑 ①：改函数签名别只替换参数行。**
`build_runner.dart` 的 `clean()` 把 `ContainerLayer layer = ...,` 删掉后
残留了 `})`，编译报 6 个 error（`Expected to find ')'` / `missing_function_body`）。
正确做法是把整段签名 `replaced` 成 `) async {`。

**踩坑 ②：改 shell 脚本别用跨行贪婪正则。**
`fetch_assets.sh` 用 `(?!#\s+- )[^\n]*\n)*` 这类模式删块，结果把文件
**从 437 行截断到 19 行**。`git checkout --` 还原后改用**逐行锚点切片**
（`find`/`index` 定位 `fetch_proot(`、`case` 等锚点再切），
改完用 `wc -l` + `bash -n` 双验。

**验证（全绿）**：
- `flutter analyze lib/` → No issues found
- `flutter test` → **1691 全过**（原 1781，减 90）
- `sync_platform.sh` → 两份 `MainActivity.kt` 一致
- Kotlin 括号平衡 `{ 377 / } 377`，`grep -ci proroot` = 0
- **真机构建**：`flutter build apk --debug` 成功出包 136MB，
  APK 内 `unzip -l | grep -i proroot` = **0 处**，`libproot.so` 保留

### 19.7 沙箱构建：Gradle `Remote host terminated the handshake` 怎么绕（2026-09-30）

**现象**：`flutter build apk` 挂在依赖解析，报
`Could not resolve io.flutter:arm64_v8a_debug:...` →
`The server may not support the client's requested TLS protocol versions` →
`Remote host terminated the handshake`。

**第一个要排除的误判：这不是代码错误。**
判据是**错误全部发生在依赖解析阶段，压根没进 Kotlin 编译**。
刚删完 1500 行 Kotlin 时看到 BUILD FAILED 很容易往代码上想，先看错误位置。

**定位网络**：
```bash
curl https://repo.maven.apache.org/maven2/ → (35) SSL_ERROR_SYSCALL  # 被掐
curl https://dl.google.com/dl/android/     → (35) SSL_ERROR_SYSCALL  # 被掐
curl https://maven.aliyun.com/repository/  → 404（说明能连通）
```

**坑：换国内镜像救不了这个 artifact。**
阿里云的 `google` / `central` 镜像里**没有** `io.flutter:*`
（Flutter engine 不在 Maven Central 分发），实测 404。

**解法：把 Gradle 缓存里已有的 aar 摊进 `android/local-maven/`**
（`settings.gradle.kts` 已把它挂成兜底仓库，配 `PREFER_SETTINGS`）。
`local-maven/README.md` 里的命令原本只摊了 **release** 两个：

```bash
for art in arm64_v8a_release flutter_embedding_release; do ... done
```

**构建 debug 变体时会缺 debug 两个** → 必须把
`arm64_v8a_debug` / `flutter_embedding_debug` 也摊进去。
注意 debug 的 engine jar 是 **180MB**（release 只有 42MB），
该目录被 `.gitignore` 和打包排除清单双向排除，**不会进仓库也不会进交付包**。
摊完后 `flutter build apk --debug --target-platform=android-arm64` 一次通过。
