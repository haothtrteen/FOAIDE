import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/core/theme.dart';

/// alpha.69：主题语义色的**结构性**契约。
///
/// 背景：全项目曾有 434 处硬编码颜色（`theme.dart` 的注释里记着），
/// Bug 464 建了 `FoaTheme.xxx(Brightness)` + `FoaColors.of(context)` 这层
/// 语义位来治理。本轮新增 `panelBg`，并把手写 `0xFF0B0E11` 收敛回 `codeBg`。
///
/// 这组测试守两类**静默失效**：
///
/// 1. **语义位两个分支同值** —— 那就等于没加语义位。这类错误不会报错、
///    不会崩，只在切主题时"看起来没变化"，最难发现。
/// 2. **同源关系破裂** —— `codeBg(dark)` 与 `FoaTheme.consoleBg` 说的是
///    同一个颜色。如果有人各改一处，旧的 `consoleBg` 会变成孤儿，
///    而迁移到 `codeBg` 的控件与仍用常量的控件就会不同色。
void main() {
  group('alpha.69 · 语义位必须真的随亮度分叉', () {
    test('panelBg 深浅两值不同', () {
      expect(FoaTheme.panelBg(Brightness.dark),
          isNot(FoaTheme.panelBg(Brightness.light)),
          reason: '两个分支同值 = 白加了语义位，切主题不会有任何变化');
    });

    test('全部语义位在两个亮度下都取到不同的值', () {
      // 逐位写死"必须不同"——新增语义位若忘了给浅色分支赋值，
      // 这里会红（而不是等到真机切主题才发现）。
      final pairs = <String, (Color, Color)>{
        'muted': (FoaTheme.muted(Brightness.dark), FoaTheme.muted(Brightness.light)),
        'warning': (
          FoaTheme.warning(Brightness.dark),
          FoaTheme.warning(Brightness.light),
        ),
        'danger': (
          FoaTheme.danger(Brightness.dark),
          FoaTheme.danger(Brightness.light),
        ),
        'warningContainer': (
          FoaTheme.warningContainer(Brightness.dark),
          FoaTheme.warningContainer(Brightness.light),
        ),
        'warningBorder': (
          FoaTheme.warningBorder(Brightness.dark),
          FoaTheme.warningBorder(Brightness.light),
        ),
        'codeBg': (FoaTheme.codeBg(Brightness.dark), FoaTheme.codeBg(Brightness.light)),
        'panelBg': (
          FoaTheme.panelBg(Brightness.dark),
          FoaTheme.panelBg(Brightness.light),
        ),
      };
      for (final e in pairs.entries) {
        expect(e.value.$1, isNot(e.value.$2),
            reason: '${e.key} 的深/浅两值相同，等于没有主题适配');
      }
    });

    test('success 是刻意的例外：品牌绿在两个亮度下同值', () {
      // 种子色不随主题变（与 cursorColor 同理由：它是品牌锚点）。
      // 写成显式断言，避免后来者"顺手"把它也改成两值而失去品牌一致性。
      expect(FoaTheme.success(Brightness.dark),
          FoaTheme.success(Brightness.light));
      expect(FoaTheme.success(Brightness.light), FoaTheme.seed);
    });
  });

  group('alpha.69 · 同源关系（改一处必须改两处的地方）', () {
    test('codeBg(dark) 与 consoleBg 同值 —— 它们是同一个颜色', () {
      // 这条是"只留一个真源"的守门人：`editor_page` / `web_preview_page`
      // 已从 FoaTheme.consoleBg 迁到 FoaColors.codeBg，两者深色值必须一致，
      // 否则那几处的观感会与迁移前不同（且没人会发现）。
      expect(FoaTheme.codeBg(Brightness.dark), FoaTheme.consoleBg,
          reason: 'codeBg 的 dark 分支应直接复用 consoleBg 常量');
    });

    test('panelBg(dark) 与抽屉/代码区原字面量一致（迁移不改变深色观感）', () {
      // 0xFF14181E 是 project_page 抽屉与 code_editor 符号条的原值。
      // 迁移到语义位后深色主题下的观感必须**完全不变**，
      // 否则这轮"修浅色"会顺带改坏深色。
      expect(FoaTheme.panelBg(Brightness.dark).toARGB32(), 0xFF14181E);
    });

    test('bg 与 lightSurface 未被本轮改动（它们是系统栏同源的锚点）', () {
      // alpha.92：lightSurface 由 #F5F7F8 改为 #FBFCFD，与 panelBg(light)
      // 合流 —— 原因见 `FoaTheme.lightSurface` 的注释（顶部三段色）。
      // 这条断言的价值在于"锚点值不许无声漂移"：它同时被
      // colors.xml / styles.xml / MainActivity.kt 引用，
      // 改了 Dart 不改那三处就会出现"冷启动一色、运行时另一色"。
      // 与 lightSurface 的同源关系另在 `home_ui_alpha92_test` 里断言。
      expect(FoaTheme.bg.toARGB32(), 0xFF101418);
      expect(FoaTheme.lightSurface.toARGB32(), 0xFFFBFCFD);
      expect(FoaTheme.consoleBg.toARGB32(), 0xFF0B0E11);
      expect(FoaTheme.seed.toARGB32(), 0xFF3DDC84);
    });
  });

  group('alpha.69 · FoaColors 暴露了新语义位', () {
    test('panelBg 在 FoaColors 上可取得（否则控件用不了）', () {
      const c = FoaColors(Brightness.dark);
      expect(c.panelBg, FoaTheme.panelBg(Brightness.dark));
      expect(c.codeBg, FoaTheme.codeBg(Brightness.dark));
      expect(c.brightness, Brightness.dark);
    });

    test('FoaColors 的取色完全由传入的 brightness 决定', () {
      const dark = FoaColors(Brightness.dark);
      const light = FoaColors(Brightness.light);
      expect(dark.panelBg, isNot(light.panelBg));
      expect(dark.codeBg, isNot(light.codeBg));
      expect(dark.muted, isNot(light.muted));
    });
  });

  group('alpha.69 · 硬编码色迁移的回归护栏（源码级）', () {
    File f(String rel) => File(rel);

    /// 剥掉 `//` 行注释后再比对。
    ///
    /// 必须这么做：迁移时我在每处都写了"原来是什么"的注释
    /// （如「原 `0xFF161B21` 固定深色」），直接 `contains` 会命中注释里的
    /// 旧字面量 —— 那是把"考古记录"误判成"没改干净"。
    String code(String rel) => f(rel)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('三处 consoleBg 已迁到语义位（否则浅色主题下仍是黑块）', () {
      // 这几个位置正是用户截图里"浅色主题下代码区/日志区还是黑的"。
      expect(code('lib/editor/editor_page.dart').contains('FoaTheme.consoleBg'),
          isFalse,
          reason: 'editor_page 的代码区外层与工具行都必须走 FoaColors.codeBg');
      expect(
          code('lib/editor/web_preview_page.dart')
              .contains('FoaTheme.consoleBg'),
          isFalse,
          reason: 'web_preview 日志区同上');
      // 正向断言：确实换成了语义位（只删不加也算"通过"，那就漏了）
      expect(code('lib/editor/editor_page.dart')
          .contains('FoaColors.of(context).codeBg'), isTrue);
      expect(code('lib/editor/web_preview_page.dart')
          .contains('FoaColors.of(context).codeBg'), isTrue);
    });

    test('抽屉底已走 panelBg，且内部文字不再用固定浅色', () {
      final pp = code('lib/project/project_page.dart');
      expect(pp.contains('FoaColors.of(context).panelBg'), isTrue,
          reason: '抽屉底必须随主题');
      // 0xFFE6E6E6 / 0xFF8A939E / 0xFFC9CFD6 是"深色主题专用的浅字"，
      // 抽屉改浅底后它们会失效 —— 迁移时必须一起清掉。
      for (final legacy in ['0xFFE6E6E6', '0xFF8A939E', '0xFFC9CFD6']) {
        expect(pp.contains(legacy), isFalse,
            reason: '$legacy 是深色专用浅字，浅色抽屉上对比度不足');
      }
      expect(pp.contains('0xFF173F35'), isFalse,
          reason: '选中态暗绿是深色专用，应改用 M3 secondaryContainer');
    });

    test('code_editor 的代码区底色与高亮主题都随亮度走', () {
      final ce = code('lib/editor/code_editor.dart');
      // 高亮主题必须二选一，不能只剩 monokai
      expect(ce.contains('monokaiSublimeTheme'), isTrue);
      expect(ce.contains('githubTheme'), isTrue,
          reason: '浅色主题需要一套浅色高亮配色');
      expect(ce.contains('isDark ? monokaiSublimeTheme : githubTheme'), isTrue,
          reason: '必须是按亮度二选一，而不是无条件用某一个');
      // 代码区底色必须显式传，不能靠第三方主题的 root.backgroundColor
      expect(ce.contains('background: c.codeBg'), isTrue,
          reason: 'CodeField 不传 background 会命中 monokai 的 #23241f / '
              'github 的 #f8f8f8，都不随项目主题走');
      // 三处面板底不再用固定深色
      for (final legacy in ['0xFF1C222B', '0xFF232A35', '0xFF161B21']) {
        expect(ce.contains(legacy), isFalse,
            reason: '$legacy 是按深色主题调的面板底，浅色下不会变');
      }
    });

    test('编辑器字号按钮的灰色被刻意保留（Bug 431 门禁要求）', () {
      // ⚠️ 反向断言：`_fontButton` 的 `Colors.grey.shade300` **不能**被
      // "顺手去硬编码"清掉 —— `editor_font_hint_test.dart` 明确要求它存在
      // （Bug 431：14px 低对比灰是"功能存在但发现不了"的根因）。
      // 把它列进"待迁移硬编码"是这轮最容易犯的错。
      final ce = code('lib/editor/code_editor.dart');
      expect(ce.contains('Colors.grey.shade300'), isTrue,
          reason: '这是 Bug 431 刻意保留的高对比灰，不是待清理的硬编码');
      expect(ce.contains('atLimit ? Colors.grey.shade700'), isTrue,
          reason: '禁用态同理');
    });
  });
}
