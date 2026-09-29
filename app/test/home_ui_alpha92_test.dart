import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/core/theme.dart';

/// alpha.92：「工程」「配置」两个界面的观感整改护栏。
///
/// 用户给的截图里暴露了三个**不报错、不崩、只有人眼能看出来**的问题：
///
/// 1. **状态栏与顶栏不是一个颜色**。`AppBarTheme.backgroundColor` 是
///    `Colors.transparent`、状态栏走 `overlayFor` 给的实色，两者取值不同源
///    → 顶部出现一条肉眼可见的色带（浅色主题下尤其刺眼）。
/// 2. **卡片彼此分不开**。M3 默认 `CardTheme.color = colorScheme.surface`，
///    而本项目的 `scaffoldBackgroundColor` 也贴近 `surface`，
///    于是"卡片"和"页面底色"几乎同色（深色下 #101510 vs #101418），
///    整页读起来像一块没分层的灰板；同时 `Card` 默认 elevation 1
///    会叠一层 M3 的 **surfaceTint 变暗**（Card 的 tint 用 5%，
///    不是文档里那个 8%），把卡片压得比背景还暗。
/// 3. **工程列表挤在一张大卡片里**。所有 `ListTile` 共用一个 `Card`，
///    层级只靠一根细 `Divider` 撑，一眼看不出"有几个工程"。
///
/// 这组测试采用**源码级断言 + 令牌断言**混合，理由是前两类问题的成因
/// 全在"具体的约束写法/取值"上（transparent、elevation、surfaceTint），
/// widget 测试要复现它们得先造出真机的渲染管线，脆且难读。
/// 这与 `ui_polish_test.dart` / `bug457_statusbar_theme_test.dart`
/// 的取舍一致。
void main() {
  // ---------------- ① 顶栏 / 状态栏同色 ----------------

  group('alpha.92 · 顶栏与状态栏必须同色', () {
    test('AppBar 背景不再是 transparent（透明才会透出状态栏实色）', () {
      for (final t in {'dark': FoaTheme.dark(), 'light': FoaTheme.light()}
          .entries) {
        expect(t.value.appBarTheme.backgroundColor, isNot(Colors.transparent),
            reason: '${t.key}：AppBar 透明 + 状态栏实色 = 顶部一条色带');
        expect(t.value.appBarTheme.backgroundColor, isNotNull);
      }
    });

    test('AppBar 背景与该主题的 panelBg 同值（单一真源）', () {
      // 不是"再挑一个好看的颜色"，而是让顶栏复用面板底：
      // panelBg 已经是"IDE 工作面板"这个语义位，顶栏属于同一层。
      expect(FoaTheme.dark().appBarTheme.backgroundColor,
          FoaTheme.panelBg(Brightness.dark));
      expect(FoaTheme.light().appBarTheme.backgroundColor,
          FoaTheme.panelBg(Brightness.light));
    });

    test('AppBar 背景 == 状态栏颜色（这才是"同色"的字面意思）', () {
      for (final (name, t) in [
        ('dark', FoaTheme.dark()),
        ('light', FoaTheme.light()),
      ]) {
        final s = t.appBarTheme.systemOverlayStyle!;
        expect(t.appBarTheme.backgroundColor, s.statusBarColor,
            reason: '$name：两者不等就会有可见的顶部分界线');
      }
    });

    test('overlayFor 与 AppBar 的 overlay 仍然同源（Bug 457 不能复发）', () {
      for (final b in Brightness.values) {
        final t = b == Brightness.dark ? FoaTheme.dark() : FoaTheme.light();
        final s = t.appBarTheme.systemOverlayStyle!;
        final o = FoaTheme.overlayFor(b);
        expect(o.statusBarColor, s.statusBarColor);
        expect(o.statusBarColor, t.appBarTheme.backgroundColor);
      }
    });

    test('导航栏也跟着走同一个底（底部不能另起一段色）', () {
      for (final b in Brightness.values) {
        final s = FoaTheme.overlayFor(b);
        expect(s.systemNavigationBarColor, s.statusBarColor,
            reason: '顶底系统栏同色，中间才是内容');
      }
    });

    test('lightSurface 与 panelBg(light) 同源（跨文件四处的锚点）', () {
      // lightSurface 同时被 theme.dart / colors.xml(foa_bg_light) /
      // styles.xml / MainActivity.kt 引用。它必须等于浅色面板底，
      // 否则"窗口背景"会和"顶栏/面板"重新分叉 —— 正是 Bug 457 的形状。
      expect(FoaTheme.lightSurface, FoaTheme.panelBg(Brightness.light));
    });
  });

  // ---------------- ② Card 的层次感 ----------------

  group('alpha.92 · 卡片必须与页面底色分得开', () {
    test('Card 底色不能再等于页面底色（否则等于没有卡片）', () {
      for (final b in Brightness.values) {
        final t = b == Brightness.dark ? FoaTheme.dark() : FoaTheme.light();
        final cardColor = t.cardTheme.color;
        expect(cardColor, isNotNull,
            reason: 'M3 默认 Card 色 = surface，与本项目手调的 scaffold 底色几乎同值');
        expect(cardColor, isNot(t.scaffoldBackgroundColor));
      }
    });

    test('Card 底色与该亮度的 surfaceContainerLow 同源', () {
      // 用 M3 的层级令牌而不是再手调一个字面量：surfaceContainerLow
      // 由 seed 派生，天然"同色系但按亮度适配"，比手写一对深/浅常量
      // 更不容易在换种子色时漂移（与 `_drawerItem` 用 secondaryContainer
      // 的理由一致）。
      for (final b in Brightness.values) {
        final t = b == Brightness.dark ? FoaTheme.dark() : FoaTheme.light();
        expect(t.cardTheme.color, t.colorScheme.surfaceContainerLow);
      }
    });

    test('Card elevation 为 0（M3 的 surfaceTint 会把卡片压暗）', () {
      for (final b in Brightness.values) {
        final t = b == Brightness.dark ? FoaTheme.dark() : FoaTheme.light();
        expect(t.cardTheme.elevation, 0,
            reason: 'Card 的 surfaceTint 按 5% 混入，深色主题下卡片比背景更暗；'
                '层次改用"提亮底 + 1px 描边"表达');
      }
    });

    test('Card 有可见描边（深色主题下"提亮"的对比很弱，需要边界）', () {
      for (final b in Brightness.values) {
        final t = b == Brightness.dark ? FoaTheme.dark() : FoaTheme.light();
        final shape = t.cardTheme.shape;
        expect(shape, isA<RoundedRectangleBorder>());
        final side = (shape! as RoundedRectangleBorder).side;
        expect(side.width, greaterThan(0),
            reason: '没有描边时，深色主题下卡片像"一块稍微亮一点的矩形"');
        expect(side.color, t.colorScheme.outlineVariant);
      }
    });

    test('Card 圆角与项目页/抽屉的既有度量对齐（不再各写一套）', () {
      final shape = FoaTheme.dark().cardTheme.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(14));
    });

    test('Card 默认 margin 归零（由页面自己给间距，避免隐形外缩进）', () {
      // Card 默认 margin 是 4（四边）。页面已经在 ListView 上给了 padding，
      // 再叠 4×2 会让"卡片净宽"与"设计意图"永远差 8dp ——
      // alpha.69 为此在工程卡片上单独写了 margin: symmetric(horizontal: 2)，
      // 那种"逐处抵消"的写法正是应该被全局收敛掉的。
      for (final b in Brightness.values) {
        final t = b == Brightness.dark ? FoaTheme.dark() : FoaTheme.light();
        expect(t.cardTheme.margin, EdgeInsets.zero);
      }
    });

    test('分隔线颜色随主题（默认的 outline 在深浅两边都太重）', () {
      for (final b in Brightness.values) {
        final t = b == Brightness.dark ? FoaTheme.dark() : FoaTheme.light();
        expect(t.dividerTheme.color, t.colorScheme.outlineVariant);
      }
    });
  });

  // ---------------- ③④⑤ 源码级护栏 ----------------

  group('alpha.92 · 界面结构的源码级护栏', () {
    String home() => code('lib/ui/home_page.dart');

    test('工程列表不再是"一个大 Card 包一个 Column"', () {
      final h = home();
      expect(h.contains('for (final (i, p) in _projects.indexed)'), isFalse,
          reason: 'indexed + 手动插 Divider 是"大卡片列表"的形状');
      expect(h.contains('indent: _kProjectTileIndent'), isFalse,
          reason: '没有大卡片就不需要"分隔线对齐首字母右侧"这个魔数了');
    });

    test('每个工程渲染成独立卡片', () {
      final h = home();
      expect(h.contains('_ProjectTile('), isTrue);
      // 独立卡片 = 每项自己一个 Card（而不是外层包一个 Card）
      expect(h.contains('for (final p in _projects)'), isTrue,
          reason: '逐项渲染才是"一工程一卡"');
    });

    test('工程区标题行有可发现的刷新入口（下拉刷新是隐式的）', () {
      final h = home();
      expect(h.contains('onRefresh: _loadProjects'), isTrue,
          reason: '下拉刷新不能丢');
      // alpha.69 删掉了与 AppBar「重新检测」并排的第二个 🔄；这次换成
      // 标题行右侧一个语义明确的图标按钮，tooltip 必须说清它只重扫
      // 项目目录（与 AppBar 那个重跑环境检测的区别）。
      expect(h.contains('重新扫描工程目录'), isTrue);
    });

    test('工程卡片用圆角方形图标块，与项目页/预览页同构', () {
      final h = home();
      // 预览页 _infoCard 用的就是 48x48 / radius 12 的图标块。
      // 主页工程项改成同一族度量，才不会"两个页面两个风格"。
      expect(h.contains('_ProjectAvatar'), isTrue);
    });

    test('配置页工具链条目也用图标块（与工程/预览页一致）', () {
      final h = home();
      // `EntryIcon` 在前面**不带**下划线：它是刻意做成"跨页面同构"的度量，
      // 名字里带下划线会让人以为它只是本文件的私有小部件而随手改数值。
      // （它仍是 library-private —— Dart 没有"跨文件但非 public"的粒度。）
      expect(h.contains('EntryIcon('), isTrue);
      expect(h.contains('class EntryIcon'), isTrue);
    });

    test('KV 的键不再写死 Colors.grey.shade400', () {
      // shade400 不在 bug464 的 shade500/600 名单里，是一处漏网的硬编码：
      // 浅色主题下 #BDBDBD 压在近白底上几乎读不出来。
      final h = home();
      expect(h.contains('Colors.grey.shade400'), isFalse,
          reason: '应走 FoaColors.of(context).muted');
    });

    test('状态卡有"现状摘要"块而不是只有一行标题', () {
      expect(home().contains('_StatusSummary'), isTrue);
    });
  });
}

/// 剥掉 `//` 行注释后再比对。
///
/// 必须这么做：本轮的改动在每处都留了"原来是什么"的考古注释，
/// 直接 `contains` 会命中注释里的旧写法 —— 那是把"考古记录"误判成
/// "没改干净"。`ui_polish_test` / `theme_semantics_test` 踩过同一个坑。
///
/// 注意这里只剥行注释、不剥块注释：本文件断言的都是缩进良好的构造，
/// 而行注释剥离是最不容易误伤代码的一种；块注释剥除需要更复杂的
/// 字符串字面量处理，收益不抵风险。
String code(String rel) => File(rel)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');
