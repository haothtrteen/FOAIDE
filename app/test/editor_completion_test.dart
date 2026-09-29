// alpha.80 · 编辑器补全三件套的回归防线。
//
// 覆盖范围（与本轮改造一一对应）：
//   1. completion.dart 逻辑单测——标识符提取（0xFF 伪标识符修复、obj.method
//      保留、最短 3、上限 400）+ 词库/文件标识符合并匹配（去重、排序、上限）；
//   2. CodeField 渲染校准——浮层定位公式
//      `top = _kTextTopInset + line * lineHeight - scrollY` 的两大前提：
//      顶部 inset 与行高，用**真实渲染**实测。Flutter/vendored 换版本导致
//      布局变化时本组变红，提醒重校 `_kTextTopInset = 20`；
//   3. 源码断言——防回退（仿 editor_font_hint_test.dart 模式）：
//      浮层替代贴底条、符号栏 30px、滚动接线、debounce、负向后顾正则。
import 'dart:io';

import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/github.dart' show githubTheme;
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/editor/completion.dart';

/// 取指定函数名的函数体（粗略按花括号配对，找不到返回空串）。
String _fnBody(String s, String name) {
  final i = s.indexOf(name);
  if (i < 0) return '';
  final open = s.indexOf('{', i);
  if (open < 0) return '';
  var depth = 0;
  for (var k = open; k < s.length; k++) {
    if (s[k] == '{') depth++;
    if (s[k] == '}') {
      depth--;
      if (depth == 0) return s.substring(open, k + 1);
    }
  }
  return '';
}

void main() {
  // 从源码动态提取 _kTextTopInset 声明值：校准测试断言"声明 == 实测"，
  // 任何一边单方面改动（含 Flutter 版本升级改变默认 contentPadding）都会变红。
  final declaredInset = double.parse(RegExp(r'_kTextTopInset = ([\d.]+)')
      .firstMatch(File('lib/editor/code_editor.dart').readAsStringSync())!
      .group(1)!);

  // ---------- 1. 标识符提取 ----------
  group('completion.dart · extractIdentifiers（文件内标识符提取）', () {
    test('数字字面量不切出伪标识符（0xFF → xFF 本轮修复的回归点）', () {
      final ids = extractIdentifiers('final color = 0xFF3DDC84;');
      expect(ids.contains('xFF'), isFalse,
          reason: '负向后顾 (?<![A-Za-z0-9_\$]) 必须挡住 0xFF 切出的 xFF');
      expect(ids.contains('final'), isTrue);
      expect(ids.contains('color'), isTrue);
    });

    test('数字周边的常见碎片全部不出现，合法标识符照收', () {
      final ids =
          extractIdentifiers('var a = 0xFFEE; var c = 1.5e10; double ab1 = 2;');
      expect(ids, isNot(contains('xFF')));
      expect(ids, isNot(contains('xFFEE')));
      expect(ids, isNot(contains('e10')), reason: '1.5e10 的 e 前是数字，必须挡');
      expect(ids.contains('ab1'), isTrue, reason: '首字符为字母的 ab1 是合法标识符');
    });

    test('obj.method 的属性名照收（提取器故意不含点）', () {
      final ids =
          extractIdentifiers('obj.method(); widget.controller.dispose();');
      expect(ids.contains('obj'), isTrue);
      expect(ids.contains('method'), isTrue);
      expect(ids.contains('controller'), isTrue);
      expect(ids.contains('dispose'), isTrue);
    });

    test('短于 3 字符的名字不收（补全没意义）', () {
      final ids = extractIdentifiers('x ab _a foo');
      expect(ids.toList(), ['foo'], reason: 'x/ab/_a 均 <3，只有 foo 入选');
    });

    test('去重且保出现序（LinkedHashSet 语义）', () {
      final ids = extractIdentifiers('foo bar foo baz foo');
      expect(ids.toList(), ['foo', 'bar', 'baz']);
    });

    test('上限 kMaxFileIdentifiers=400（超大文件候选不爆炸）', () {
      final src = List.generate(600, (i) => 'ident$i').join(' ');
      expect(extractIdentifiers(src).length, kMaxFileIdentifiers);
    });

    test('空串安全', () {
      expect(extractIdentifiers(''), isEmpty);
    });
  });

  // ---------- 2. 合并匹配 ----------
  group('completion.dart · matchCompletionsWithIdentifiers（词库+文件标识符）', () {
    test('文件自定义名进入候选并标为 identifier', () {
      final hits = matchCompletionsWithIdentifiers('_build', {
        '_buildStatusCard',
      });
      expect(
        hits.any((c) =>
            c.word == '_buildStatusCard' &&
            c.kind == CompletionKind.identifier),
        isTrue,
        reason: '静态词库覆盖不到用户自定义名，这正是文件标识符补全的价值',
      );
    });

    test('与词库重名（大小写不敏感）不重复收录', () {
      // 词库 Stack(type) 对 'sta' 前缀命中；文件里同名的大小写变体 STACK
      // 应被排除，不得出现两条 "stack"。
      final hits = matchCompletionsWithIdentifiers('sta', {'STACK'});
      final words = hits.map((c) => c.word).toList();
      expect(words.where((w) => w.toLowerCase() == 'stack'), hasLength(1),
          reason: '词库 Stack 已占位，文件里的 STACK（大小写变体）不得重复收录');
    });

    test('词库冷门前缀时文件标识符照常进入候选', () {
      // '_bu' 在词库无命中（词库不带下划线开头的名字），候选应来自文件。
      final hits = matchCompletionsWithIdentifiers('_bu', {
        '_buildStatusCard',
        '_buildRow',
      });
      final words = hits.map((c) => c.word).toList();
      expect(words, ['_buildRow', '_buildStatusCard']);
    });

    test('正在输入的词自己不补自己', () {
      expect(matchCompletionsWithIdentifiers('foo', {'foo'}), isEmpty);
    });

    test('排序：精确前缀 > 关键字 > 字母序', () {
      // 精确命中第一
      final exact = matchCompletionsWithIdentifiers('add', {'addValue'});
      expect(exact.first.word, 'add', reason: '词库 add(method) 是精确命中，必须排最前');
      // 关键字优先于文件标识符
      final kw = matchCompletionsWithIdentifiers('fi', {'fieldOne'});
      expect(kw.first.word, 'final', reason: 'keyword 优先级高于 identifier');
      // 纯标识符按字母序
      final alpha = matchCompletionsWithIdentifiers(
          '_bu', {'_buildB', '_buildA', '_buildC'}).map((c) => c.word).toList();
      expect(alpha, ['_buildA', '_buildB', '_buildC']);
    });

    test('候选上限 8 条', () {
      final ids = {for (var i = 0; i < 30; i++) 'zzitem$i'};
      expect(matchCompletionsWithIdentifiers('zz', ids), hasLength(8));
    });

    test('matchCompletions 旧签名行为不变（空标识符集合等价）', () {
      expect(matchCompletions('zzz'), isEmpty);
      expect(
          matchCompletions('setstate').any((c) => c.word == 'setState'), isTrue,
          reason: '大小写不敏感匹配不能丢');
      final all = matchCompletions('');
      expect(all, hasLength(8));
      expect(all.every((c) => c.kind == CompletionKind.keyword), isTrue,
          reason: '空前缀 + 精确命中为空时，keyword 优先排序下前 8 条应全为关键字'
              '（改词库后若此断言失败属预期，请同步更新期望）');
    });

    test('matchCompletionsInSource 端到端：从源码提取并匹配', () {
      const src = 'class _DemoPage extends StatelessWidget {\n'
          '  Widget _buildStatusCard() { return Container(); }\n'
          '}\n';
      final hits = matchCompletionsInSource('_build', src);
      expect(hits.any((c) => c.word == '_buildStatusCard'), isTrue);
    });
  });

  // ---------- 3. CodeField 渲染校准 ----------
  group('alpha.80 · CodeField 渲染校准（浮层定位公式的两大前提）', () {
    // 公式：top = _kTextTopInset + line * lineHeight - scrollY。
    // 用真实渲染实测顶部 inset 与行高；Flutter/vendored 换版本布局一变即红。
    ScrollController? captured;

    Future<TextEditingController> pumpField(WidgetTester tester,
        {required String text}) async {
      captured = null;
      final controller = CodeController(text: text);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CodeTheme(
            data: const CodeThemeData(styles: githubTheme),
            child: CodeField(
              controller: controller,
              focusNode: FocusNode(),
              expands: true,
              background: Colors.white,
              cursorColor: Colors.black,
              textStyle: const TextStyle(
                  fontFamily: 'monospace', fontSize: 14, height: 1.5),
              onScrollControllerReady: (c) => captured = c,
            ),
          ),
        ),
      ));
      await tester.pump();
      return controller;
    }

    // vendored CodeField 内部有行号列 + 代码列两个 EditableText，
    // 必须按 controller 区分出代码列。
    Finder codeEditable(TextEditingController controller) =>
        find.byWidgetPredicate(
            (w) => w is EditableText && identical(w.controller, controller));

    testWidgets('① 顶部 inset 实测 == _kTextTopInset 声明（现 $declaredInset）',
        (tester) async {
      final controller = await pumpField(tester, text: 'line0\nline1\n');
      final fieldTop = tester.getTopLeft(find.byType(CodeField)).dy;
      final editableTop = tester.getTopLeft(codeEditable(controller)).dy;
      expect(editableTop - fieldTop, closeTo(declaredInset, 1.0),
          reason: 'EditableText 相对 CodeField 顶部的实测距离必须等于声明的 '
              '_kTextTopInset。Flutter 升级改变默认 contentPadding 时本测试变红：'
              '请重校 code_editor.dart 的 _kTextTopInset，否则浮层整体错位');
    });

    testWidgets('② 行高实测 = fontSize × 1.5（_lineHeight 公式）', (tester) async {
      final controller = await pumpField(tester, text: 'line0\nline1\nline2\n');
      final state = tester.state<EditableTextState>(codeEditable(controller));
      final caret0 = state.renderEditable
          .getLocalRectForCaret(const TextPosition(offset: 0));
      // offset 12 = 'line0\nline1\n'.length → 第 2 行行首
      final caret2 = state.renderEditable
          .getLocalRectForCaret(const TextPosition(offset: 12));
      expect(caret2.top - caret0.top, closeTo(2 * 14 * 1.5, 1.0),
          reason: '_caretViewportTop 按 line × (fontSize×1.5) 算 y；'
              '若 CodeField 行为变化（如加 strut）本测试变红，浮层会逐行漂移');
    });

    testWidgets('③ 透出的 controller 就是代码列滚动控制器，jumpTo 直接生效', (tester) async {
      final controller = await pumpField(tester,
          text: List.generate(60, (i) => 'line$i').join('\n'));
      expect(captured, isNotNull,
          reason: 'vendored CodeField 的 onScrollControllerReady 必须透出'
              '纵向滚动控制器——浮层跟随滚动全靠它');
      // 注意：EditableText 内部自带 Scrollable（是它的**后代**，不是祖先），
      // 滚动在 RenderEditable 绘制层平移，box 位置不随 offset 变——所以这里
      // 验证「读到的 offset 就是真实滚动位置」，而不是 box 位移。
      final scrollControllers = find
          .descendant(
              of: codeEditable(controller), matching: find.byType(Scrollable))
          .evaluate()
          .map((e) => (e.widget as Scrollable).controller)
          .toList();
      expect(
        scrollControllers
            .whereType<ScrollController>()
            .any((c) => identical(c, captured)),
        isTrue,
        reason: '浮层定位读到的滚动偏移必须来自代码列真实渲染的滚动位置',
      );
      captured!.jumpTo(63);
      await tester.pump();
      expect(captured!.offset, 63.0, reason: 'jumpTo 必须生效（有滚动空间时）');
      // 合成验证：getLocalRectForCaret 返回的坐标**已含滚动偏移**
      // （Flutter 内部加 _paintOffset），故视口内光标 y
      //   = EditableText box 顶 + caret 视口内 y
      //   = fieldTop + inset + 2×行高 − scrollY
      // 与 _caretViewportTop 公式（inset + line×行高 − scrollY）两端吻合。
      final state = tester.state<EditableTextState>(codeEditable(controller));
      final caretLocalTop = state.renderEditable
          .getLocalRectForCaret(const TextPosition(offset: 12))
          .top; // offset 12 = 第 2 行行首；返回值已扣掉滚动 63
      final fieldTop = tester.getTopLeft(find.byType(CodeField)).dy;
      final editableBoxTop = tester.getTopLeft(codeEditable(controller)).dy;
      expect(
        editableBoxTop + caretLocalTop,
        closeTo(
            fieldTop + declaredInset + 2 * 14 * 1.5 - captured!.offset, 1.5),
        reason: '滚动 63px 后第 2 行光标的视口 y = fieldTop + inset + 2×行高 − 63：'
            '渲染端（box顶+caret视口内y）与 _caretViewportTop 公式必须吻合',
      );
    });
  });

  // ---------- 4. 源码断言（防回退） ----------
  group('alpha.80 · 源码断言（仿 editor_font_hint_test 模式）', () {
    late String editorSrc;
    late String vendoredSrc;
    setUpAll(() {
      editorSrc = File('lib/editor/code_editor.dart').readAsStringSync();
      vendoredSrc =
          File('third_party/code_text_field/lib/src/code_field/code_field.dart')
              .readAsStringSync();
    });

    test('浮层补全已替代贴底建议条', () {
      expect(editorSrc.contains('_buildCompletionOverlay'), isTrue,
          reason: '补全浮层（跟随光标、不占布局）必须存在');
      expect(editorSrc.contains('_buildSuggestionBar'), isFalse,
          reason: '旧贴底建议条（固定 40px、横向翻找）已删除，不得回潮');
    });

    test('符号栏压窄到 30px', () {
      final bar = _fnBody(editorSrc, 'Widget _buildSymbolBar');
      expect(RegExp(r'height:\s*30\b').hasMatch(bar), isTrue,
          reason: '用户反馈"太占位置"，符号栏 36→30；回 36 会再次挤占键盘上方空间');
      expect(RegExp(r'height:\s*36\b').hasMatch(bar), isFalse);
    });

    test('滚动控制器接线完整（vendored 与编辑器两端都在）', () {
      expect(vendoredSrc.contains('onScrollControllerReady'), isTrue,
          reason: 'vendored CodeField 的回调参数不能丢');
      expect(editorSrc.contains('onScrollControllerReady'), isTrue,
          reason: 'code_editor.dart 必须接收并挂滚动监听');
      expect(editorSrc.contains('_onCodeScroll'), isTrue,
          reason: '滚动时刷新浮层位置的监听器必须存在');
    });

    test('定位公式依赖光标行，且换行也要刷位置', () {
      final fn = _fnBody(editorSrc, 'double? _caretViewportTop');
      expect(fn.contains('_lineOf'), isTrue, reason: '按光标行计算 y');
      expect(editorSrc.contains('line != _lastCaretLine'), isTrue,
          reason: '光标行变化（上下键/点击）时浮层也要跟着走，即便候选没变');
    });

    test('标识符重建必须 debounce（防每次按键全文件扫描）', () {
      final fn = _fnBody(editorSrc, 'void _scheduleIdentRebuild');
      expect(fn.contains('Timer'), isTrue);
      expect(fn.contains('Duration(milliseconds: 500)'), isTrue);
      expect(editorSrc.contains('_scheduleIdentRebuild()'), isTrue,
          reason: '输入变化时要调度重建');
    });

    test('提取器必须带负向后顾（0xFF → xFF 修复点）', () {
      final compSrc = File('lib/editor/completion.dart').readAsStringSync();
      expect(compSrc.contains(r'(?<![A-Za-z0-9_$])'), isTrue,
          reason: '去掉负向后顾会让 0xFF 切出 xFF 伪标识符');
    });

    test('行高公式与 textStyle 的 height:1.5 绑定（改一个必须同步另一个）', () {
      expect(editorSrc.contains('height: 1.5'), isTrue,
          reason: 'CodeField textStyle 的行高倍数');
      expect(editorSrc.contains('_fontSize * 1.5'), isTrue,
          reason: '_lineHeight 必须与 textStyle.height 一致，否则浮层逐行漂移');
    });
  });
}
