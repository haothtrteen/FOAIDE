import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全局主题：暗色 IDE 风格 + 浅色主题，Android 绿为种子色。
class FoaTheme {
  static const seed = Color(0xFF3DDC84);
  static const bg = Color(0xFF101418);
  static const consoleBg = Color(0xFF0B0E11);

  /// 浅色主题下的窗口/系统栏底色。
  ///
  /// Bug 457：不能用 `Colors.transparent`。`AppBarTheme` 背景是 transparent，
  /// 若状态栏也 transparent，透出的就是 **Android 窗口背景**
  /// （`styles.xml` 的 `foa_bg = #101418` 深色）→ 浅色顶栏下面压着一条深色
  /// 状态栏，视觉上像"顶栏和状态栏不是一个颜色"。
  /// 给一个与浅色表面协调的实色，AppBar 与状态栏才是连续的。
  static const lightSurface = Color(0xFFF5F7F8);

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      // 顶栏沉浸：透明背景 + 无阴影；状态栏图标浅色，适配深色背景。
      // 状态栏用实色 #101418（Bug 406）。注意（Bug 410）：Android 15+ 设备上
      // 引擎跳过 setStatusBarColor，实际颜色由 styles.xml 主题声明兜底，
      // 此处 systemOverlayStyle 主要保证图标明暗在各版本一致。
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Color(0xFF101418),
          statusBarIconBrightness: Brightness.light, // Android：浅色图标
          statusBarBrightness: Brightness.dark, // iOS：深色状态栏背景
        ),
      ),
    );
  }

  /// 浅色主题：同一 Android 绿种子，亮色配色；状态栏深色图标。
  ///
  /// Bug 457：状态栏必须是**实色**（[lightSurface]）而非 transparent，
  /// 否则会透出 styles.xml 的深色窗口背景，形成"顶栏浅、状态栏深"的割裂。
  /// 图标亮度同步为 dark（深色图标压在浅色状态栏上）。
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: lightSurface,
          statusBarIconBrightness: Brightness.dark, // Android：深色图标
          statusBarBrightness: Brightness.light, // iOS：浅色状态栏背景
          systemNavigationBarColor: lightSurface,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
      ),
    );
  }

  /// 按主题模式返回系统栏样式（main.dart 与主题切换处共用）。
  ///
  /// 集中一处，避免"主题切了但系统栏没跟着切"这类不一致（Bug 457 的成因之一：
  /// main() 里硬编码了一份深色 overlay，在任何主题下都生效）。
  static SystemUiOverlayStyle overlayFor(Brightness b) =>
      b == Brightness.dark
          ? const SystemUiOverlayStyle(
              statusBarColor: Color(0xFF101418),
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
              systemNavigationBarColor: Color(0xFF101418),
              systemNavigationBarDividerColor: Color(0xFF101418),
              systemNavigationBarIconBrightness: Brightness.light,
            )
          : const SystemUiOverlayStyle(
              statusBarColor: lightSurface,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
              systemNavigationBarColor: lightSurface,
              systemNavigationBarDividerColor: lightSurface,
              systemNavigationBarIconBrightness: Brightness.dark,
            );
}

/// 主题切换控制器：暗色 / 浅色 / 跟随系统。
class ThemeController extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  set mode(ThemeMode m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
  }
}
