# FOA 应用 R8 保留规则（APK 体积优化配套，2026-09-17）
#
# Flutter 3.47 的 Gradle 插件会自动追加两套规则：
#  1. proguard-android-optimize.txt（AGP 内置）
#  2. flutter_proguard_rules.pro（Flutter SDK 自带：dontwarn io.flutter.plugin./android.，
#     保留 FlutterPlugin 实现类；注意它【不】整体保留 io.flutter.**）
#
# ⚠️ 关键教训（R8 实测踩坑）：不要写 `-keep class io.flutter.** { *; }`。
# 该规则会把 FlutterPlayStoreSplitApplication / PlayStoreDeferredComponentManager 等
# 可选引擎类强制保留，它们引用了 com.google.android.play.core.*（Play Store 拆分安装
# API），而本项目不依赖 play-core → R8 报 "Missing class" 编译失败
# （AGP 9.1 下缺类引用 kept 代码 = 错误，-dontwarn 无法压住错误）。
# 引擎类应交给 Flutter 自带规则按需保留，应用只需保留自己的包。

# ---- 本应用包（MainActivity 已由 AndroidManifest 引用，R8 自动保留；
#       MethodChannel 回调类走反射风险面小，整包保留最稳妥）----
-keep class dev.foa.flutter_on_android.** { *; }

# ---- 第三方插件（v2 embedding 经 GeneratedPluginRegistrant 静态注册，
#      通常无需规则；如有反射调用插件类再补）----
# -keep class com.example.some_plugin.** { *; }

# ---- 曾为无线调试 adb 保留 Kadb / spake2 / Elisabeth 的规则已于 2026-09-17 移除 ----
# （整块功能下线，见 app/build.gradle.kts 顶部的依赖说明）

# ---- 可选：压掉对可选依赖的缺类提示（仅 warning 场景有效，errors 无效）----
# -dontwarn com.google.android.play.core.**
