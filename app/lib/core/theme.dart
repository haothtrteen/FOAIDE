import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全局主题：暗色 IDE 风格，Android 绿为种子色。
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
}
