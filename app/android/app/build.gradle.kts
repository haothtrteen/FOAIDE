plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.foa.flutter_on_android"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.foa.flutter_on_android"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // targetSdk 28：Android 10+ 的 W^X 策略禁止 targetSdk>=29 的应用 execve 数据目录下的
        // 二进制，而 rootfs 内 guest 程序正是内核真实执行、位于 filesDir 下。Termux 同款策略。
        // 详见 SETUP_ANDROID.md 与 dev-handbook/04 Bug 104。
        targetSdk = 28
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // APK 体积优化（2026-09-17）：只打包 arm64-v8a。
        // 目标设备全为 64 位（proot 本体也仅分发 arm64，见 jniLibs/arm64-v8a），
        // 移除 armeabi-v7a / x86_64 冗余库约 -38MB（libapp.so + libflutter.so × 2 套）。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // R8 代码压缩 + 资源缩减（APK 体积优化核心，2026-09-17）：
            // Flutter 3.47 插件默认已对 release 开启（FlutterPlugin.kt shouldShrinkResources
            // 默认 true），此处显式声明保证确定性（防 --no-shrink / 插件默认变更）；
            // proguard-rules.pro 被插件自动追加（文件存在时）。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    lint {
        // targetSdk 28 是本项目的刻意选择（W^X 策略，见 SETUP_ANDROID.md），
        // 分发渠道为 GitHub Releases / 官网 / F-Droid，不上 Google Play，
        // 关闭"Play 要求 API 33+"的 fatal lint 检查。
        disable += "ExpiredTargetSdkVersion"
    }

    packaging {
        jniLibs {
            // 等价旧 Manifest 属性 extractNativeLibs="true"（AGP 9 起必须走 DSL）：
            // 让 libproot.so 解压成磁盘真实文件，proot 才能经 nativeLibraryDir 执行
            useLegacyPackaging = true
        }
    }
}

// 依赖说明（2026-09-17）：本模块**没有任何第三方依赖**，是有意为之。
//
// 曾短暂引入过 Kadb（com.flyfishxu:kadb，Apache-2.0）做无线调试 adb，
// 但它拖进一个 **GPL-3.0** 的传递依赖 spake2-java（且只在 JitPack 发布），
// 会被 dex 进 App 进程——那是本项目闭源商业化的唯一真阻塞点。
// 现在 AVF 路线因设备不支持而暂缓、原生 arm64 路线不需要 adb，
// 整块已移除（含 AdbWireless.kt / adb_bridge.dart / adb_page.dart / vendor_kadb.sh）。
//
// ⚠️ 若将来要重新引入任何 AAR/JAR，先跑一遍 dev-handbook/05-许可证合规.md
// 的「闭源检查清单」：只要出现 GPL/LGPL/AGPL 的**进程内链接**依赖就否决。
// 独立子进程（proot 里的可执行程序）不在此列——那是「发行义务」而非「传染」。

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ---------------------------------------------------------------------------
// Bug 627 的**出包侧** workaround（alpha.94）
//
// 现象：`mergeReleaseJniLibFolders` 必挂
//   Failed to create MD5 hash for file: .../merged_jni_libs/.../libapp.so
//
// 实测结论（alpha.94 重新取证，推翻了 alpha.92 的"sync 后就恢复"）：
//   · 文件是**完好的** —— 等约 20s 后 md5sum 立刻成功，且与上游
//     merged_native_libs / generated/jniLibs 两处同名文件 md5 **完全一致**；
//   · 只有 gradle **刚 copy 出来的那一份**立刻读会 `Input/output error`
//     （`dd` 读出 0 字节，`stat` 大小正常）；
//   · `sync` 之后**仍然复挂**（sync 只是发起回写，返回≠落盘完成）。
//
// 也就是说：Gradle 在这个 overlayfs 上"写完马上 hash"撞进一个窗口。
//
// ⚠️⚠️ alpha.96 **第二次更正** —— alpha.94 的 `doLast` 解法**不够**。
//
// alpha.96 出包时复现，报错变了：
//
//   > Cannot access output property 'outputDir' of task
//   >   ':app:mergeReleaseJniLibFolders'. Accessing unreadable inputs or
//   >   outputs is not supported.
//   > Failed to create MD5 hash for file: .../libapp.so
//
// 关键：**报错的是"访问 outputDir"这个动作本身**，不是某个具体文件。
// 说明 `doLast` 里读通之后，Gradle 自己的快照阶段**又读了一次**
// （这次走的是 `outputDir` 属性），而那一下又撞进 IO error 窗口。
//
// 也就是说：`doLast` 只保证了"我读的时候可读"，**保证不了"Gradle 读的时候可读"**。
// 中间隔了一个快照阶段，时间窗又拉开了。
//
// 试过 **`doNotTrackState()`**（Gradle 报错里建议的那条），**不行**：
//   > Changes are not tracked, unable determine incremental changes.
//   这个 task 是增量的，关掉状态跟踪后它自己就没法工作了。
//
// alpha.96 采用的解法：**加 `doFirst` 预热 + 延长 `doLast` 重试**。
//
//   · `doFirst`：copy 之前先等**上一轮的残留产物**可读（如果有），
//     把"上一次留下的不可读窗口"在 task 开始前就消掉；
//   · `doLast`：copy 之后读到可读为止（最多 60s，alpha.94 是 30s）；
//   · 两段都读 `outputs.files.files`，覆盖 Gradle 两条访问路径。
//
// ⚠️ 这条**只加在 FOA 自己的出包工程**里，不要抄进给用户工程用的 Flutter
// 模板：这个 IO error 是本沙箱 overlayfs 的现象，手机上是真实 ext4/f2fs，
// 且用户的构建脚本该保持干净。
// ---------------------------------------------------------------------------

/// Bug 627 的等待助手：把所有输出文件读到"读得动"为止。
///
/// 抽成函数是因为 `doFirst` / `doLast` 两处要用同一套逻辑。
///
/// ⚠️ 别写 `java.util.*`：脚本里 `java` 是 JavaPluginExtension 的属性名，
/// 会被 `plugins {}` 遮蔽成 `Unresolved reference`（这个坑本项目踩过两次）。
fun bug627WaitReadable(
    files: Iterable<File>,
    label: String,
    maxMs: Long,
) {
    val deadline = System.currentTimeMillis() + maxMs
    var waited = 0
    while (System.currentTimeMillis() < deadline) {
        try {
            var n = 0
            // 显式栈遍历：Kotlin DSL 里 FileTree.visit {} 的重载
            // 解析不出 lambda 参数（会报 Unresolved reference 'it'）。
            val stack = mutableListOf<File>()
            files.forEach { stack.add(it) }
            while (stack.isNotEmpty()) {
                val f = stack.removeAt(stack.lastIndex)
                if (f.isDirectory) {
                    f.listFiles()?.forEach { stack.add(it) }
                } else {
                    // 读一小段就够触发 overlayfs 的 IO error
                    f.inputStream().use { s -> s.read(ByteArray(8192)) }
                    n++
                }
            }
            if (waited > 0) {
                logger.lifecycle("Bug 627[$label]：等 ${waited}s 后 $n 个文件可读")
            }
            return
        } catch (e: java.io.IOException) {
            Thread.sleep(1000)
            waited++
        }
    }
    logger.warn("Bug 627[$label]：等了 ${maxMs / 1000}s 仍不可读")
}

tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("JniLibFolders")) {
        // ① copy 之前：把上一轮残留的不可读窗口消掉
        doFirst {
            bug627WaitReadable(outputs.files.files, "pre", 15_000)
        }
        // ② copy 之后：等新产物可读
        doLast {
            bug627WaitReadable(outputs.files.files, "post", 60_000)
        }
    }
}

