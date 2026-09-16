import 'package:flutter/material.dart';

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
    );
  }
}
