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
