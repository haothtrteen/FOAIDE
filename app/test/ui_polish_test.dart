import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/core/theme.dart';

/// alpha.69：主页 / 创建工程界面的排版修复回归护栏。
///
/// 这一组测试守的是**截图里那种"看着别扭但不会报错"的问题**：
/// 折行折在奇怪的位置、两个一模一样的按钮、文字压在一起。
/// 它们全都编译得过、跑得动、也不崩 —— 只有人眼能发现，
/// 所以必须靠源码级断言把"当时为什么这么改"钉住。
///
/// 采用源码级断言而非 widget 测试的理由：这些问题的成因全在
/// **具体的约束写法**（`maxLines` / `isThreeLine` / `Badge` 的 overlay
/// 语义）上，widget 测试要复现它们得先造出同样的窄屏与字体度量，
/// 脆且难读。源码级断言直接盯住"那个写法还在不在"，更贴近真实失效模式。
void main() {
  group('alpha.69 · 主页排版修复（源码级护栏）', () {
    /// 剥掉 `//` 行注释后再比对。
    ///
    /// 必须这么做：这批改动我在每处都写了"原来是什么"的考古注释
    /// （如「原来是一整段 `\n` 拼接」），直接 `contains` 会命中注释里的
    /// 旧写法 —— 把"考古记录"误判成"没改干净"。这是
    /// `theme_semantics_test.dart` 踩过的同一个坑。
    String code(String rel) => File(rel)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    String home() => code('lib/ui/home_page.dart');

    // ── 需求 5：去掉一个刷新按钮 ────────────────────────────────

    test('工程列表标题上那个刷新按钮已删除', () {
      expect(home().contains('刷新工程列表'), isFalse,
          reason: '与 AppBar 的「重新检测」并排出现两个 🔄，用户分不清');
    });

    test('AppBar 的「重新检测」必须保留（那是唯一的环境重检入口）', () {
      // ⚠️ 反向断言：删错了按钮是这次最容易犯的错 ——
      // 工程列表那个只重扫目录，AppBar 那个还会重跑环境检测。
      expect(home().contains('重新检测'), isTrue,
          reason: '删掉它 = 环境检测没有任何手动入口');
      expect(home().contains('env.installing ? null : () => env.refresh()'),
          isTrue);
    });

    test('下拉刷新仍在（删按钮不等于砍掉刷新能力）', () {
      expect(home().contains('RefreshIndicator'), isTrue);
      expect(home().contains('onRefresh: _loadProjects'), isTrue);
    });

    // ── 需求 4.1：主题三档不再折行 ──────────────────────────────

    test('主题分段按钮的第三档文案是「系统」而不是「跟随系统」', () {
      // 三档等分宽度由最窄的一档决定，4 个字必然折成「跟随\n系统」。
      expect(home().contains("Text('系统'"), isTrue);
      expect(home().contains("Text('跟随系统'"), isFalse,
          reason: 'SegmentedButton 里容不下 4 个字');
    });

    test('分段按钮的 label 都兜了 maxLines: 1', () {
      // 万一将来字体放大或本地化变长，宁可省略号也不要静默折行。
      final n = 'maxLines: 1'.allMatches(home()).length;
      expect(n, greaterThanOrEqualTo(4),
          reason: '主题三档 + 同步按钮 + 卡片标题都应显式限行');
    });

    // ── 需求 4.2：关于卡片不再断在版本号中间 ─────────────────────

    test('关于卡片不再用手动 \\n 拼接 subtitle', () {
      expect(home().contains(r'\n引用了'), isFalse,
          reason: '分段拼接会被 ListTile 的固定高度排版折断');
    });

    test('关于卡片改为两行独立 Text，不再用 isThreeLine', () {
      expect(home().contains('AboutInfo.version'), isTrue);
      expect(home().contains('isThreeLine'), isFalse,
          reason: 'subtitle 只吃两行，isThreeLine 会留出多余高度');
      // 版本号那一行必须能 const（它是字面量常量）；
      // 下一行不能 const —— `List<AboutComponent>.length` 不是常量表达式。
      expect(home().contains('const Text(\n                  AboutInfo.version'),
          isTrue);
    });

    // ── 需求 4.3：同步按钮文案不再折行 ───────────────────────────

    test('两个同步按钮都收窄了内边距 / 字号', () {
      // 默认 OutlinedButton.icon 左右内边距各 16 + icon-label 间距 8，
      // 窄屏上把「外部 → 容器」挤成两行。
      expect(home().contains('EdgeInsets.symmetric(horizontal: 8)'), isTrue);
      expect(home().contains('fontSize: 12'), isTrue);
    });

    test('同步按钮保留了完整文案（没有退化成缩写）', () {
      expect(home().contains('外部 → 容器'), isTrue);
      expect(home().contains('容器 → 外部'), isTrue);
    });

    // ── 需求 4.4：工程卡片路径不再折行 ───────────────────────────

    test('_ProjectTile 的 title / subtitle 都限了单行', () {
      final h = home();
      // subtitle 是路径，project.name 一长就会被折成两行、把卡片撑高
      expect(h.contains("'/root/projects/\${project.name}'"), isTrue);
      expect(h.contains('overflow: TextOverflow.ellipsis'), isTrue);
    });

    // ── 需求 6：工程卡片加宽 ────────────────────────────────────
    //
    // ⚠️ alpha.92 补齐了这三条的"下半场"。
    //
    // alpha.69 的思路是"把左右 padding 收窄 + 把 Card 的默认 margin 抵消掉"，
    // 于是出现了 12 / 2 / 12 这组**只在这一页成立**的魔数。用户新一轮反馈
    // （"工程和配置两个界面 UI 更好看一点"）暴露出：这三个值治的是症状
    // —— 卡片看着窄，根因是 `Card` 的默认 margin(4) 与 M3 默认 `surface`
    // 底色让卡片既窄又和背景同色。
    //
    // alpha.92 把根因挪到主题层解决（`FoaTheme._build` 里
    // `cardTheme.margin = EdgeInsets.zero`、`color = surfaceContainerLow`、
    // 加 1px outlineVariant 描边、elevation 归零），于是：
    //   - `margin: symmetric(horizontal: 2)` 这条"逐处抵消"删掉了；
    //   - `ListTile.contentPadding` 也随 `_ProjectTile` 从 ListTile 改成
    //     自绘 `Row` 一起消失了（不再有默认 16 要收窄）；
    //   - 左右内边距回到 16，与配置页/设置页/预览页一致。
    // 对应断言迁到了 `home_ui_alpha92_test.dart`（卡片度量 + 一工程一卡）。
    // 下面两条保留为**反向断言**：那组旧魔数不该以任何形式复活。

    test('alpha.69 的逐处抵消式魔数不再存在', () {
      final h = home();
      expect(h.contains('margin: const EdgeInsets.symmetric(horizontal: 2)'),
          isFalse,
          reason: 'Card 默认 margin 已在主题层归零，页面里不该再逐个抵消');
      expect(
          h.contains(
              'contentPadding: const EdgeInsets.symmetric(horizontal: 12)'),
          isFalse,
          reason: '_ProjectTile 已不用 ListTile，不再有默认 16 要收窄');
    });

    test('工程列表左右留白与其它页对齐（16）', () {
      expect(home().contains('EdgeInsets.fromLTRB(16, 12, 16, 96)'), isTrue,
          reason: '配置页/设置页/预览页都是 16，主页不该是唯一一个 12');
    });

    // ── 需求 7：模板卡片「需Git」不再压住标题 ────────────────────

    test('模板卡片不再用 Badge（它的 label 是不占布局的浮层）', () {
      // Badge 把 child 放进 Stack，label 用 Positioned 浮在 child
      // 右上角**外部**、不参与布局 —— 26dp 图标装不下 4 字标签，
      // 于是右溢压到相邻的模板标题首字上（用户截图的「git 与字重合」）。
      expect(home().contains('Badge('), isFalse,
          reason: 'Badge.label 是 overlay，必然越界到相邻元素上');
      expect(home().contains('_NeedGitTag'), isTrue,
          reason: '应改为占布局的普通 widget');
    });

    test('_NeedGitTag 用警告语义位，不再写死橙色', () {
      final h = home();
      expect(h.contains('c.warningContainer'), isTrue);
      expect(h.contains('c.warningBorder'), isTrue);
      expect(h.contains('c.warning'), isTrue);
      for (final legacy in ['0x33FFB74D', '0xFFFFB74D', '0x33FF7A7A']) {
        expect(h.contains(legacy), isFalse,
            reason: '$legacy 在浅色主题下对比度不足');
      }
    });

    test('「需Git」文案仍在（只是换了承载方式）', () {
      expect(home().contains('需Git'), isTrue);
      expect(home().contains("text: '需Git'") || home().contains("'需Git'"),
          isTrue);
    });

    test('危险色也一并迁到语义位', () {
      final h = home();
      expect(h.contains('0xFFFF7A7A'), isFalse,
          reason: '删除工程的红色在浅色主题下应压深到 0xFFC62828');
      expect(h.contains('Colors.orangeAccent'), isFalse,
          reason: 'orangeAccent 在浅色底上几乎看不见');
      expect(h.contains('FoaColors.of(ctx).danger'), isTrue);
      expect(h.contains('FoaColors.of(context).danger'), isTrue);
      expect(h.contains('FoaColors.of(context).warning'), isTrue);
      // alpha.92：这条原先是 `FoaColors.of(context).success`。
      // 当时的 `_StatusCard` 里是 `i.rootfsInstalled ? FoaColors.of(context)
      // .success : FoaColors.of(context).warning` 三元。现在状态色收敛到了
      // `_StatusSummary`，并且为了避开"同一个 `FoaColors.of(context)` 写四遍"
      // 而先取了 `final c = FoaColors.of(context);` → 于是变成 `c.success`。
      // 断言跟着改成"语义位仍在用"，而不是钉住某一种取用写法 ——
      // 这条测试要守的是"别退回硬编码绿/红"，不是"必须写全限定名"。
      expect(h.contains('c.success') || h.contains('FoaColors.of(context).success'),
          isTrue,
          reason: '品牌绿仍应走语义位，而不是写死 0xFF3DDC84');
      expect(h.contains('0xFF3DDC84'), isFalse,
          reason: '写死品牌绿 = 失去"只改 theme.dart 一处"的能力');
    });
  });

  group('alpha.69 · 语义色在浅色主题下必须可读', () {
    test('警告三档在浅色下都压深了（否则淡底亮字看不见）', () {
      final lightFg = FoaTheme.warning(Brightness.light);
      final darkFg = FoaTheme.warning(Brightness.dark);
      // 浅色前景应该比深色前景"暗"（亮度更低），才压得住浅底
      expect(lightFg.computeLuminance(), lessThan(darkFg.computeLuminance()),
          reason: '浅色主题的警告字必须比深色主题的更深，否则读不清');
    });

    test('危险色同理', () {
      expect(
          FoaTheme.danger(Brightness.light).computeLuminance(),
          lessThan(FoaTheme.danger(Brightness.dark).computeLuminance()));
    });
  });
}
