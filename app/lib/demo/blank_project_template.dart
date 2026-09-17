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
/// 注意：脚本运行在容器 `/bin/sh`（dash）下，必须保持 POSIX sh 兼容，
/// 禁止 bashism（[[ ]]、数组、&> 等）。
String blankProjectScript(String name) => r'''
set -eu
NAME='__NAME__'
PKG="com.example.$NAME"
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
  "$D/android/app/src/main/kotlin/com/example/$NAME" \
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
  "$D/android/app/src/main/kotlin/com/example/$NAME/MainActivity.kt"
sed -i "s|{{androidIdentifier}}|$PKG|g" "$D/android/app/src/main/kotlin/com/example/$NAME/MainActivity.kt"

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
echo BLANK_OK
'''.replaceAll('__NAME__', name);
