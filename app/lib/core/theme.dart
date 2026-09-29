import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../env/proot_bridge.dart';

/// 全局主题：暗色 IDE 风格 + 浅色主题，Android 绿为种子色。
class FoaTheme {
  static const seed = Color(0xFF3DDC84);

  /// 深色主题的页面底色（几乎接近黑的中性蓝灰）。
  ///
  /// alpha.92：仍是 `#101418`。**别把它和顶栏混为一谈** —— 顶栏/状态栏走
  /// [panelBg]（深色 `#14181E`），页面底色走本常量。两者的差值（约 2.5%
  /// 亮度）刻意保留：顶栏是一块"浮在页面上"的横带，同色会让顶栏与内容区
  /// 糊成一片、看不出 AppBar 到哪儿结束。
  ///
  /// ⚠️ 本值同时是 `res/values/colors.xml` 的 `foa_bg`、`styles.xml` 的
  /// 窗口背景、以及 App 图标的底色（`app_icon_test.dart` 有断言）。
  /// 改这里要连带改那一串，而不是"顺手换个更好看的黑"。
  static const bg = Color(0xFF101418);

  static const consoleBg = Color(0xFF0B0E11);

  /// 浅色主题下的窗口/系统栏底色。
  ///
  /// Bug 457：不能用 `Colors.transparent`。`AppBarTheme` 背景是 transparent，
  /// 若状态栏也 transparent，透出的就是 **Android 窗口背景**
  /// （`styles.xml` 的 `foa_bg = #101418` 深色）→ 浅色顶栏下面压着一条深色
  /// 状态栏，视觉上像"顶栏和状态栏不是一个颜色"。
  /// 给一个与浅色表面协调的实色，AppBar 与状态栏才是连续的。
  ///
  /// alpha.92：由 `#F5F7F8` 改为 `#FBFCFD`，与 [panelBg] 的浅色分支**同值**。
  /// 原因是 Bug 457 只解决了"状态栏 vs 顶栏"，没解决"顶栏 vs 内容区"——
  /// 当时顶栏是 `transparent`，透出的其实是 `scaffoldBackgroundColor`
  /// （M3 `surface`，浅色下 `#F6FBF3`，带一层淡绿），而状态栏是中性灰
  /// `#F5F7F8` → 顶部三段色（状态栏偏灰、顶栏偏绿、卡片近白）。
  /// 现在把顶栏也改成实色 [panelBg]，三者归到同一族中性色上。
  /// `theme_semantics_test` / `bug457` 有一组跨文件同源断言盯着这个值。
  static const lightSurface = Color(0xFFFBFCFD);

  // ---------------- Bug 464 · 主题感知语义色 ----------------
  //
  // 背景：此前全项目散落了 434 处硬编码颜色（`Colors.grey.shade500` 71 处、
  // `Color(0xFFFFB74D)` 14 处…）。这些是**按深色主题调的**，切到浅色主题后
  // 对比度就不对了（最典型：某个卡片用固定的 `Colors.orange.shade50`
  // 做警告底，深色主题下是一块刺眼的亮橙）。
  //
  // 这里集中定义"随主题走"的语义色。用法：
  //   final c = FoaColors.of(context);
  //   Text('…', style: TextStyle(color: c.muted));

  /// IDE 工作面板底 / 顶栏 / 系统栏底（alpha.69 新增，alpha.92 扩用）。
  ///
  /// 覆盖对象：编辑器代码区外层容器、文件树 / 抽屉面板、各级工具条、
  /// **顶栏与状态栏**（alpha.92）。这些位置此前散落着 `0xFF14181E` /
  /// `0xFF1C222B` / `0xFF232A35` / `0xFF161B21` 四个**按深色主题调的**
  /// 字面量 —— 切到浅色主题后它们不会跟着变，于是"浅色主题下代码区还是
  /// 黑的、文件名看不清"。
  ///
  /// 为什么收敛成一档而不是保留四个层次：这四个值的差异（约 4%~7% 亮度）
  /// 在手机上肉眼几乎分不出层次，但每多一个语义位就多一处要记得改的地方。
  /// 真需要层次时用 `Theme.of(context).colorScheme.surfaceContainerHighest`
  /// 这类 M3 令牌叠加，而不是再开一个 `panelBgElevated`。
  ///
  /// 为什么不直接用 M3 的 `colorScheme.surface`：它由 seed 派生，
  /// 浅色下会带一层淡绿调，与项目手调的 `bg` / [lightSurface]
  /// 中性灰蓝打架。alpha.92 把顶栏也接到这里之后，这个取舍变得更要紧 ——
  /// 顶栏一旦带绿调，整页会显得"发黄"。
  static Color panelBg(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF14181E) : lightSurface;

  static ThemeData dark() => _build(Brightness.dark);

  /// 浅色主题：同一 Android 绿种子，亮色配色；状态栏深色图标。
  ///
  /// Bug 457：状态栏必须是**实色**（[lightSurface]）而非 transparent，
  /// 否则会透出 styles.xml 的深色窗口背景，形成"顶栏浅、状态栏深"的割裂。
  /// 图标亮度同步为 dark（深色图标压在浅色状态栏上）。
  static ThemeData light() => _build(Brightness.light);

  /// 两个主题的**唯一构造入口**（alpha.92 起）。
  ///
  /// 为什么合并成一处：此前 dark() / light() 各写一份，凡是"两个主题都该有"
  /// 的令牌（顶栏、卡片、分隔线…）都要写两遍 —— 而漏写一份的表现恰恰是
  /// **一边正常、另一边返祖**（Bug 457 就是这个形状：浅色的状态栏改对了、
  /// 顶栏还是 transparent）。合并后，"两个主题长得不一样"这件事只剩两个
  /// 有名字的变量：底色与 [overlayFor]。
  static ThemeData _build(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    // alpha.92：顶栏走**实色** panelBg，不再 transparent。
    //
    // 原来 transparent 是"沉浸式顶栏"的经典写法 —— 让 AppBar 直接透出
    // 页面底色。但它有一个前提：状态栏也得透出同一个底色。而状态栏颜色
    // 由 systemOverlayStyle 给的是**另一个值**（深色 #101418 / 浅色
    // #F5F7F8），于是顶栏与状态栏天然不同源 → 顶部一条可见色带。
    // 改实色后两者都等于 panelBg，"顶栏 + 状态栏"读作一整块。
    //
    // ⚠️ 不改 `elevation: 0` 与 `scrolledUnderElevation: 0`：M3 的 AppBar
    // 在内容滚到下方时会按 scrolledUnderElevation 混入 surfaceTint，
    // 出现"一滚就变色"。既然现在顶栏是实色，保持恒定即可。
    final surface = panelBg(b);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 深色主题显式指定底色（保留既有的 #101418，它同时是 App 图标底、
      // styles.xml 的 foa_bg）；浅色沿用 M3 由种子派生的 surface。
      scaffoldBackgroundColor: dark ? bg : null,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: overlayFor(b),
      ),
      cardTheme: CardThemeData(
        // alpha.92：M3 默认 CardTheme.color = colorScheme.surface，而本项目的
        // 页面底色也贴近 surface → 卡片与背景在深色下几乎同色
        // （#101510 vs #101418），整页读起来像一块没分层的灰板。
        // 改用 surfaceContainerLow：它是 M3 的"比 surface 略高一层"，
        // 由种子色派生，天然按亮度适配，比手写一对深浅常量更不易漂移
        // （理由与 `project_page._drawerItem` 用 secondaryContainer 相同）。
        color: scheme.surfaceContainerLow,
        // elevation 归零：Card 的默认 elevation 是 1，M3 会按 surfaceTint
        // 把 5% 的 primary 混进卡片色 —— 而 primary 在本项目是**深绿**
        // （dark 下 #12512E），混进去的结果是**卡片比背景更暗**，
        // 与"卡片应该浮起来"的意图完全相反。层次改用"提亮底 + 描边"表达。
        elevation: 0,
        // 描边不可省：深色下 surfaceContainerLow(#181D18) 与
        // scaffold(#101418) 的差值只有约 5% 亮度，肉眼几乎分不出卡片边界。
        // outlineVariant 是 M3 专为"分隔/描边"设计的令牌，两边主题都够弱。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_kCardRadius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        // margin 归零：默认 4（四边）会在页面自己给的 padding 之上再吃一层，
        // 让"卡片净宽"永远比设计意图少 8dp。alpha.69 为了抵消它，在工程卡片
        // 上单独写了 `margin: symmetric(horizontal: 2)` —— 那种逐处抵消的
        // 写法正是应该被全局收敛掉的。间距改由页面显式给（`SizedBox`）。
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
    );
  }

  /// 卡片与图标块的统一圆角。
  ///
  /// 14 是对齐既有度量的结果：`project_preview._infoCard` 的图标块是 12、
  /// 抽屉条目是 10、`_ActionTile` 是 16。取 14 让"卡片"比"卡片里的图标块"
  /// 略圆一点，视觉上构成父子关系，而不是各写一套。
  static const double _kCardRadius = 14;

  /// 按主题模式返回系统栏样式（main.dart 与主题切换处共用）。
  ///
  /// 集中一处，避免"主题切了但系统栏没跟着切"这类不一致（Bug 457 的成因之一：
  /// main() 里硬编码了一份深色 overlay，在任何主题下都生效）。
  ///
  /// alpha.92：三色（状态栏 / 顶栏 / 导航栏）统一取自 [panelBg]。
  /// 此前深色状态栏是 `#101418`（= [bg]）而顶栏透出的是 `surface`，
  /// 浅色状态栏是 `#F5F7F8` 而顶栏透出的是 `#F6FBF3` —— 两边都差一点点，
  /// 那"一点点"正是截图里顶部那条色带。
  ///
  /// ⚠️ 这三个值同时存在于 `android/app/src/main/res/values/colors.xml`
  /// （`foa_bg` / `foa_bg_light`）与 `MainActivity.kt` 的
  /// `applySystemBarColors` 兜底里 —— 改这里必须同步那两处，
  /// `bug457_statusbar_theme_test.dart` 有跨文件同源断言守着。
  static SystemUiOverlayStyle overlayFor(Brightness b) => SystemUiOverlayStyle(
        statusBarColor: panelBg(b),
        statusBarIconBrightness:
            b == Brightness.dark ? Brightness.light : Brightness.dark,
        statusBarBrightness:
            b == Brightness.dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: panelBg(b),
        systemNavigationBarDividerColor: panelBg(b),
        systemNavigationBarIconBrightness:
            b == Brightness.dark ? Brightness.light : Brightness.dark,
      );

  // ---------------- Bug 464 · 主题感知语义色 ----------------
  //
  // 背景：此前全项目散落了 434 处硬编码颜色（`Colors.grey.shade500` 71 处、
  // `Color(0xFFFFB74D)` 14 处…）。这些是**按深色主题调的**，切到浅色主题后
  // 对比度就不对了（最典型：某个卡片用固定的 `Colors.orange.shade50`
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
  ///
  /// ⚠️ dark 分支刻意复用 [consoleBg] 而不是再写一遍 `0xFF0B0E11` ——
  /// 这两处说的是同一个颜色，字面量写两份迟早会漂移。
  /// `test/theme_semantics_test.dart` 有条断言盯着这个同源关系。
  static Color codeBg(Brightness b) =>
      b == Brightness.dark ? consoleBg : const Color(0xFFEEF1F3);
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
  Color get panelBg => FoaTheme.panelBg(_b);
}

/// 主题切换控制器：暗色 / 浅色 / 跟随系统。
///
/// **默认值 `ThemeMode.system`**（alpha.69 起）。
/// 改成跟随系统不是审美偏好，是修一个真实的落差：此前硬编码
/// `ThemeMode.dark`，系统明明是浅色、用户装完打开却是一片深色，
/// 得自己去设置里找一遍才能改对 —— 而"默认跟随系统"是不用解释的。
///
/// 与 [ThemePrefs] 的分工：本类只管内存态与通知；持久化全在
/// [ThemePrefs]（`filesDir/theme.json`），异常一律静默回
/// `ThemeMode.system` —— 主题偏好丢了顶多是"回到默认"，不该影响启动。
class ThemeController extends ChangeNotifier {
  /// **同步构造、异步补齐**（Bug/设计决策见 [load]）。
  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  /// `notifyListeners()` 在 dispose 之后调用会抛。
  /// `ChangeNotifier` 没有公开的"已释放"查询（Flutter 3.19），自己记一个。
  bool _disposed = false;

  /// 从磁盘恢复用户上次的选择。
  ///
  /// **不阻塞首帧**：构造时已经是 [ThemeMode.system]，这里只做"补齐"。
  /// 这样做有个额外好处 —— 首次安装（无 theme.json）时读到的仍是
  /// `system`，与当前值相同 → **不触发 notifyListeners → 零重建、零闪烁**。
  ///
  /// 为什么不用"启动先阻塞读完再 runApp"：`envInfo()` 走平台通道，
  /// 阻塞它会把首帧一起拖慢，而主题偏好完全不值得这个代价。
  Future<void> load() async {
    final loaded = await ThemePrefs.load();
    if (_disposed) return;
    // 值没变就不通知：避免无谓的整树重建（也是"零闪烁"的实现要点）
    if (loaded == _mode) return;
    _mode = loaded;
    notifyListeners();
  }

  set mode(ThemeMode m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
    // fire-and-forget：与 EditorFontPrefs.save 在 onScaleEnd 的写法一致。
    // 刻意不 await —— 写盘失败不影响本次切换的即时生效。
    ThemePrefs.save(m);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 主题模式偏好（`filesDir/theme.json`）。
///
/// 沿用项目既有的偏好持久化惯例（与 `EditorFontPrefs` / `EditorLastFile` /
/// `HintPrefs` 同款）：filesDir 下一个小 JSON，**全异常静默**，
/// 读不到/读坏了都回退默认值。刻意不引 shared_preferences ——
/// 为一个三态枚举多一个插件依赖不划算，且项目已有四个同构实现。
///
/// 存的是字符串（`'system'`/`'light'`/`'dark'`）而不是 Dart 的
/// `ThemeMode.system.toString()`：后者是"对象表示"，改枚举名或
/// 升级 Flutter 都可能悄悄变，读回来就成了未知值。
class ThemePrefs {
  static const String fileName = 'theme.json';
  static const String key = 'mode';

  /// 默认值：跟随系统。
  static const ThemeMode fallback = ThemeMode.system;

  static String encode(ThemeMode m) => switch (m) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  /// 未知串一律回 [fallback]（含大小写不符、历史遗留值）。
  static ThemeMode decode(String? s) => switch (s) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => fallback,
      };

  static Future<File> _file() async {
    final env = await ProotBridge().envInfo();
    return File('${env.filesDir}/$fileName');
  }

  /// 读不到 / 解析失败 / 值非法 → 一律 [fallback]，绝不抛。
  static Future<ThemeMode> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return fallback;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return fallback;
      return decode(raw[key] as String?);
    } catch (_) {
      return fallback;
    }
  }

  /// 幂等写入；失败静默（偏好丢失不该影响使用）。
  static Future<void> save(ThemeMode m) async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({key: encode(m)}));
    } catch (_) {}
  }
}
