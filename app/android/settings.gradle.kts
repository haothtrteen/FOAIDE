pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // FOA 国内镜像优先（阿里云 google/central/gradle-plugin 代理），
        // 官方仓库兜底。构建机需配 ~/.gradle/gradle.properties 的 JVM 代理。
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google()
        mavenCentral()
        // 本地兜底仓库（仅构建沙箱用，见同目录 local-maven/README）：
        // 本沙箱对外网封闭，而 Flutter 的 FlutterPlugin 会把
        // io.flutter:arm64_v8a_release / io.flutter:flutter_embedding_release
        // 指向官方地址（download.flutter.io / dl.google.com / repo.maven.apache.org），
        // 三者均 TLS 握手失败。这两个构件已在本机 Gradle 缓存里，`flutter build`
        // 的 project 级 `allprojects { repositories }` 又因 FAIL_ON_PROJECT_REPOS
        // 被拒，所以只能放在这里、并让 settings 仓库优先。
        // 该目录不存在或为空时对正常（有网）构建无影响。
        maven {
            url = uri("${rootDir}/local-maven")
            isAllowInsecureProtocol = true
        }
    }
}

include(":app")
