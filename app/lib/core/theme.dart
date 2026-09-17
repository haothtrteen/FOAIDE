import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全局主题：暗色 IDE 风格 + 浅色主题，Android 绿为种子色。
class FoaTheme {
  static const seed = Color(0xFF3DDC84);
  static const bg = Color(0xFF101418);
  static const consoleBg = Color(0xFF0B0E11);

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
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark, // Android：深色图标
          statusBarBrightness: Brightness.light, // iOS：浅色状态栏背景
        ),
      ),
    );
  }
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
