/// Step 8 空白工程模板：容器内离线组装最小 Flutter Android 工程。
///
/// 原理：flutter create 启动时强制 `git --version` 检查（缺 git 直接 exit 1），
/// 而「空白工程」希望零依赖、零网络、秒级创建——因此不走 flutter create，
/// 直接在本脚本里把 Flutter SDK 内建模板（/opt/flutter/.../templates）用
/// sed 渲染占位符后 cp/sed 组装成工程骨架：
///
/// - 版本占位符（{{agpVersion}}/{{kotlinVersion}}/{{gradleVersion}}/
///   {{dartSdkVersionBounds}}）从容器内 SDK 运行时解析，不硬编码；
/// - gradle 发行包 URL 直接写腾讯镜像（与工具链 Step 3 预下载的
///   ~/.gradle/wrapper/dists 缓存哈希一致，构建零下载）；
/// - maven 依赖已由全局 /root/.gradle/init.gradle（阿里云镜像）接管；
/// - pubspec 仅依赖 `flutter` SDK（无外部包），pub get 全程离线；
/// - lib/main.dart 由 DemoProjectCreator 用 base64 写入（唯一内容源）。
///
/// ⚠️ 包名规则（`com.example.<name>`）：Java 包名的段**不能以数字开头**，
/// 而 Dart 包名允许（`1to2` 是合法 pub 包名、合法目录名）。所以必须把名字
/// 换成首字符不是数字的形式再拼包名，否则 `package com.example.1to2` 会让
/// gradle 直接编译失败——而失败点在容器里的 gradle 输出中，用户完全无从
/// 下手。名字与包名由 [demoAndroidIdentifier] 单点推导，此脚本只做替换。
///
/// 本文件用 `library;` 声明收尾：Dart 的 `///` 文档注释必须紧贴被注释的
/// 声明，而下面还有 [demoAndroidIdentifier] 和 [blankProjectScript]，所以
/// 先用 `library;` 把这段文件级说明挂到库上，否则它会被当成某个函数的文档。
///
/// 注意：脚本运行在容器 `/bin/sh`（dash）下，必须保持 POSIX sh 兼容，
/// 禁止 bashism（[[ ]]、数组、&> 等）。
library;

/// 空白工程的 Android 包名前缀。
const String kDemoAndroidIdPrefix = 'com.example';

/// 由项目名推导 Android 包名（**唯一来源**，脚本里的 `__PKG__` 由它渲染）。
///
/// 规则：`com.example.<name>`，但若名字以数字开头则前置一个 `a`
/// （`1to2` → `com.example.a1to2`）。只改包名、**不改项目名**——项目名同时
/// 是目录名和 pub 包名，已经过 `validateName` 校验（`^[a-z][a-z0-9_]*$`），
/// 用户输入什么就是什么才符合预期；只有 Android 侧的 package 声明需要满足
/// Java 标识符规则，两者本该可以不同（`ManifestInfo` 里 pubName/label 也是分开放的）。
///
/// 若将来允许更大自由度的项目名（如允许数字开头），这里同样要保证输出满足
/// `^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$`——因为它的去向是
/// `package com.example.x`、`namespace`、`applicationId` 三个地方，任一处
/// 不合法都是构建期失败。
String demoAndroidIdentifier(String name) {
  final t = name.trim();
  if (t.isEmpty) return kDemoAndroidIdPrefix;
  final head = t[0];
  final safe = RegExp(r'[0-9]').hasMatch(head) ? 'a$t' : t;
  return '$kDemoAndroidIdPrefix.$safe';
}

/// 包名最后一段（Kotlin 源码目录名）。`com.example.a1to2` → `a1to2`。
String demoAndroidIdLastSegment(String name) {
  final pkg = demoAndroidIdentifier(name);
  return pkg.substring(pkg.lastIndexOf('.') + 1);
}

String blankProjectScript(String name) => r'''
set -eu
NAME='__NAME__'
PKG='__PKG__'
# Kotlin 源码目录必须与包名逐段对应（com.example.a1to2 → com/example/a1to2）。
# 包名末段可能被改过（见 demoAndroidIdentifier），所以不能拿 NAME 当目录名。
PKGHEAD="${PKG%.*}"
PKGLAST="${PKG##*.}"
SDK=/opt/flutter
T="$SDK/packages/flutter_tools/templates/app"
D=/root/projects/$NAME
GJAR="$SDK/bin/cache/artifacts/gradle_wrapper"

[ -d "$D" ] && { echo "BLANK_ERR: 目录已存在"; exit 1; }

# 从 SDK 运行时解析模板版本（不硬编码，SDK 升级自动跟随）
AGP=$(sed -n "s/.*templateAndroidGradlePluginVersion = '\([^']*\)'.*/\1/p" "$SDK/packages/flutter_tools/lib/src/android/gradle_utils.dart" | head -1)
KOT=$(sed -n "s/.*templateKotlinGradlePluginVersion = '\([^']*\)'.*/\1/p" "$SDK/packages/flutter_tools/lib/src/android/gradle_utils.dart" | head -1)
GRADLE=$(sed -n "s/.*templateDefaultGradleVersion = '\([^']*\)'.*/\1/p" "$SDK/packages/flutter_tools/lib/src/android/gradle_utils.dart" | head -1)
DARTV=$(tr -d '[:space:]' < "$SDK/bin/cache/dart-sdk/version" 2>/dev/null || true)
[ -n "$AGP" ] || AGP=9.1.0
[ -n "$KOT" ] || KOT=2.4.0
[ -n "$GRADLE" ] || GRADLE=9.3.1
[ -n "$DARTV" ] || DARTV=3.13.3

mkdir -p "$D/lib" \
  "$D/android/app/src/main/kotlin/$PKGHEAD/$PKGLAST" \
  "$D/android/app/src/debug" \
  "$D/android/app/src/profile" \
  "$D/android/gradle/wrapper"

# ---- 根级文件 ----
# pubspec 仅 flutter SDK 依赖：pub get 无需联网（无 cupertino_icons/lints）
cat > "$D/pubspec.yaml" <<EOF
name: $NAME
description: A blank Flutter project.
publish_to: 'none'
version: 0.1.0+1

environment:
  sdk: ^$DARTV

dependencies:
  flutter:
    sdk: flutter

flutter:
  uses-material-design: true
EOF

cp "$T/.gitignore.tmpl" "$D/.gitignore"

# ---- android：模板渲染 + 国内镜像 ----
cp "$T/android.tmpl/.gitignore" "$D/android/.gitignore"
cp "$T/android.tmpl/gradle.properties.tmpl" "$D/android/gradle.properties"

cp "$T/android.tmpl/settings.gradle.kts.tmpl" "$D/android/settings.gradle.kts"
sed -i "s|{{agpVersion}}|$AGP|g; s|{{kotlinVersion}}|$KOT|g" "$D/android/settings.gradle.kts"

cp "$T/android-kotlin.tmpl/build.gradle.kts.tmpl" "$D/android/build.gradle.kts"
cp "$T/android-kotlin.tmpl/app/build.gradle.kts.tmpl" "$D/android/app/build.gradle.kts"
sed -i "s|{{androidIdentifier}}|$PKG|g" "$D/android/app/build.gradle.kts"

cp "$T/android.tmpl/app/src/debug/AndroidManifest.xml.tmpl" "$D/android/app/src/debug/AndroidManifest.xml"
cp "$T/android.tmpl/app/src/profile/AndroidManifest.xml.tmpl" "$D/android/app/src/profile/AndroidManifest.xml"
cp "$T/android.tmpl/app/src/main/AndroidManifest.xml.tmpl" "$D/android/app/src/main/AndroidManifest.xml"
sed -i "s|{{projectName}}|$NAME|g" "$D/android/app/src/main/AndroidManifest.xml"

cp -r "$T/android.tmpl/app/src/main/res/." "$D/android/app/src/main/res/"

cp "$T/android-kotlin.tmpl/app/src/main/kotlin/androidIdentifier/MainActivity.kt.tmpl" \
  "$D/android/app/src/main/kotlin/$PKGHEAD/$PKGLAST/MainActivity.kt"
sed -i "s|{{androidIdentifier}}|$PKG|g" "$D/android/app/src/main/kotlin/$PKGHEAD/$PKGLAST/MainActivity.kt"

# gradle 发行包走腾讯镜像（容器已预下载对应缓存，构建零下载）
cp "$T/android.tmpl/gradle/wrapper/gradle-wrapper.properties.tmpl" "$D/android/gradle/wrapper/gradle-wrapper.properties"
sed -i "s|{{gradleVersion}}|$GRADLE|g" "$D/android/gradle/wrapper/gradle-wrapper.properties"
sed -i 's|services.gradle.org/distributions|mirrors.cloud.tencent.com/gradle|' "$D/android/gradle/wrapper/gradle-wrapper.properties"

cp "$GJAR/gradlew" "$D/android/gradlew"
cp "$GJAR/gradlew.bat" "$D/android/gradlew.bat"
cp "$GJAR/gradle/wrapper/gradle-wrapper.jar" "$D/android/gradle/wrapper/gradle-wrapper.jar"
chmod +x "$D/android/gradlew"

# ---- 校验：无残留占位符 + 关键文件齐全 ----
if grep -rIq '{{' "$D/android" "$D/pubspec.yaml" 2>/dev/null; then
  echo "BLANK_ERR: 模板占位符未替换干净"; exit 1
fi
[ -f "$D/android/gradle/wrapper/gradle-wrapper.jar" ] || { echo "BLANK_ERR: gradle wrapper jar 缺失"; exit 1; }
[ -f "$D/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" ] || { echo "BLANK_ERR: 图标资源缺失"; exit 1; }
# 包名三处一致性：build.gradle.kts 的 namespace/applicationId、Manifest 的 package、
# MainActivity.kt 的 package 声明必须同源，否则 R 类找不到、装机失败。
[ -f "$D/android/app/src/main/kotlin/$PKGHEAD/$PKGLAST/MainActivity.kt" ] || { echo "BLANK_ERR: MainActivity.kt 路径与包名不符"; exit 1; }
grep -q "package $PKG" "$D/android/app/src/main/kotlin/$PKGHEAD/$PKGLAST/MainActivity.kt" || { echo "BLANK_ERR: MainActivity.kt 包名未生效"; exit 1; }
echo BLANK_OK
'''
    .replaceAll('__NAME__', name)
    .replaceAll('__PKG__', demoAndroidIdentifier(name));
