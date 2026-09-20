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

  // ---------------- Bug 464 · 主题感知语义色 ----------------
  //
  // 背景：此前全项目散落了 434 处硬编码颜色（`Colors.grey.shade500` 71 处、
  // `Color(0xFFFFB74D)` 14 处…）。这些是**按深色主题调的**，切到浅色主题后
  // 对比度就不对了（最典型：proroot 卡片用固定的 `Colors.orange.shade50`
  // 做警告底，深色主题下是一块刺眼的亮橙）。
  //
  // 这里集中定义"随主题走"的语义色。用法：
  //   final c = FoaColors.of(context);
  //   Text('…', style: TextStyle(color: c.muted));

  /// 次要文字/图标（原 `Colors.grey.shade500` 的语义位）。
  static Color muted(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF9AA3AB) : const Color(0xFF6B7378);

  /// 成功（原多数 `Color(0xFF3DDC84)` 的语义位，与种子色一致）。
  static Color success(Brightness b) => seed;

  /// 警告（原 `Color(0xFFFFB74D)`，浅色下需压深才够对比度）。
  static Color warning(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFFFB74D) : const Color(0xFFB26A00);

  /// 危险/错误（原 `Color(0xFFFF7A7A)`，浅色下同样需压深）。
  static Color danger(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFFF7A7A) : const Color(0xFFC62828);

  /// 警告底色（替代固定 `Colors.orange.shade50`）。
  static Color warningContainer(Brightness b) =>
      b == Brightness.dark
          ? const Color(0xFF3A2A12)
          : const Color(0xFFFFF3E0);

  /// 警告描边。
  static Color warningBorder(Brightness b) =>
      b == Brightness.dark
          ? const Color(0xFF7A5A22)
          : const Color(0xFFFFCC80);

  /// 代码块/日志底（原 `Colors.black.withValues(alpha: 0.25)`）。
  static Color codeBg(Brightness b) =>
      b == Brightness.dark
          ? const Color(0xFF0B0E11)
          : const Color(0xFFEEF1F3);
}

/// `FoaColors.of(context)` —— 主题感知语义色的便捷取用。
///
/// 用法：`final c = FoaColors.of(context);` 之后 `c.muted` / `c.warning` …
/// 这些值都随当前 `Theme.of(context).brightness` 变化，切主题即生效。
class FoaColors {
  const FoaColors(this._b);
  final Brightness _b;

  static FoaColors of(BuildContext context) =>
      FoaColors(Theme.of(context).brightness);

  Brightness get brightness => _b;
  Color get muted => FoaTheme.muted(_b);
  Color get success => FoaTheme.success(_b);
  Color get warning => FoaTheme.warning(_b);
  Color get danger => FoaTheme.danger(_b);
  Color get warningContainer => FoaTheme.warningContainer(_b);
  Color get warningBorder => FoaTheme.warningBorder(_b);
  Color get codeBg => FoaTheme.codeBg(_b);
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
