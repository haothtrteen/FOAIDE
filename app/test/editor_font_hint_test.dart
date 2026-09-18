import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Bug 431 固化：字号调节的**可发现性**。
///
/// 背景
/// ----
/// 用户反馈：「代码编辑器页面只有一个手指不动、另一个手指动的时候才能
/// 放大/缩小，我感觉这得单独出个教程告诉用户了」。
///
/// 排查结论：功能**早就存在**（状态栏 A-/A+ 按钮 + 双指捏合 + 点数字
/// 恢复默认，且都持久化），真正的问题是**发现不了**——按钮只有 14px
/// 灰色小图标、贴在内边距 5px 上，手机上看不清也难点。
///
/// 因此修法不是写教程，而是：
///   1. 把按钮做得看得清、点得着（图标放大、提高对比、加大可点区域）；
///   2. 首次进入给一条一次性提示，把「隐藏功能」变成「看得见的功能」。
///
/// 这些断言防的是**回退**：后来者重构状态栏时很容易把按钮删掉或缩小，
/// 而这类回归在沙箱里跑不出来（要真机上用手指试才知道）。
void main() {
  final codeEditor = File('lib/editor/code_editor.dart');
  final hintPrefs = File('lib/editor/hint_prefs.dart');

  group('Bug 431 · 字号调节入口必须可见可点', () {
    late String src;
    setUpAll(() {
      expect(codeEditor.existsSync(), isTrue);
      src = codeEditor.readAsStringSync();
    });

    test('A- / A+ 按钮仍在（含步进 delta ±1）', () {
      expect(src.contains('_fontButton(Icons.text_decrease'), isTrue,
          reason: '缩小字号入口丢失');
      expect(src.contains('_fontButton(Icons.text_increase'), isTrue,
          reason: '放大字号入口丢失');
      expect(src.contains('-1)'), isTrue);
      expect(src.contains('1)'), isTrue);
    });

    test('图标足够大且对比度够（14px 灰色是本次可发现性问题的根因）', () {
      // 图标尺寸：放宽到 >= 16 方能看清
      final size = RegExp(r'size:\s*(\d+)').allMatches(src).map(
            (m) => int.parse(m.group(1)!),
          );
      expect(size.any((s) => s >= 16), isTrue,
          reason: '字号按钮图标必须 >=16px（原先 14px 在手机上难辨）');
      // 颜色不得再用低对比的 Colors.grey（应为 grey.shade300 等）
      final btn = _fnBody(src, 'Widget _fontButton');
      expect(btn.contains('Colors.grey.shade300'), isTrue,
          reason: '按钮颜色要够亮，灰色低对比是发现不了的直接原因');
      expect(btn.contains('Colors.grey,'), isFalse,
          reason: '退回纯 Colors.grey 会再次变得几乎看不见');
    });

    test('可点区域要足够宽（原 5px 内边距太小）', () {
      final btn = _fnBody(src, 'Widget _fontButton');
      final m = RegExp(r'horizontal:\s*(\d+)').firstMatch(btn);
      expect(m, isNotNull, reason: '未找到水平内边距');
      final pad = int.parse(m!.group(1)!);
      expect(pad >= 8, isTrue,
          reason: '水平内边距 >=8px，否则触摸命中区过小（实测 5px 偏小）');
    });

    test('到达上下限时要有视觉区分（不再误导为可继续点）', () {
      final btn = _fnBody(src, 'Widget _fontButton');
      expect(btn.contains('atLimit'), isTrue,
          reason: '到极限仍显示亮色会让用户反复点击却无反应');
      expect(btn.contains('shade700'), isTrue);
    });

    test('双指捏合缩放必须保留（单指手势要留给 CodeField）', () {
      expect(src.contains('onScaleStart'), isTrue);
      // Bug 432 起改为早返回式守卫：单指直接 return，放行给 CodeField
      // 的光标/滚动/长按选择。
      expect(src.contains('pointerCount < 2'), isTrue,
          reason: '单指手势必须放行给 CodeField 的光标/滚动/长按选择');
      expect(src.contains('onScaleEnd'), isTrue,
          reason: 'onScaleEnd 里要持久化字号');
    });
  });

  group('Bug 431 · 首次提示（把隐藏功能变成看得见的功能）', () {
    test('存在一次性提示偏好，且全异常静默', () {
      expect(hintPrefs.existsSync(), isTrue);
      final s = hintPrefs.readAsStringSync();
      expect(s.contains('class HintPrefs'), isTrue);
      expect(s.contains('editorFont'), isTrue);
      expect(s.contains('seen('), isTrue);
      expect(s.contains('markSeen('), isTrue);
      // 体验增强类功能一律不得因 IO 失败而抛错
      expect(RegExp(r'catch \(_\)').hasMatch(s), isTrue,
          reason: '持久化失败必须静默，不能影响编辑');
    });

    test('先标记已读再展示，避免秒退后重复弹', () {
      final s = codeEditor.readAsStringSync();
      final idx = s.indexOf('_maybeHintFontScale');
      expect(idx, greaterThan(0));
      final body = s.substring(idx, (idx + 1400).clamp(0, s.length));
      final markIdx = body.indexOf('markSeen(');
      final showIdx = body.indexOf('showSnackBar');
      expect(markIdx, greaterThan(0), reason: '必须标记已读');
      expect(showIdx, greaterThan(0), reason: '必须真的展示提示');
      expect(markIdx < showIdx, isTrue,
          reason: '先写标记再弹窗：用户秒退也不会重复打扰');
    });

    test('提示文案要同时说清按钮与手势两条路径', () {
      final s = codeEditor.readAsStringSync();
      final idx = s.indexOf('_maybeHintFontScale');
      final body = s.substring(idx, (idx + 1400).clamp(0, s.length));
      expect(body.contains('A−') || body.contains('A-'), isTrue,
          reason: '要指出按钮位置，用户才知道去哪点');
      expect(body.contains('捏合'), isTrue,
          reason: '用户本来就是从手势角度提问的，必须正面回应手势');
    });

    test('提示要有「知道了」关闭入口（不强迫等待）', () {
      final s = codeEditor.readAsStringSync();
      final idx = s.indexOf('_maybeHintFontScale');
      final body = s.substring(idx, (idx + 1400).clamp(0, s.length));
      expect(body.contains('SnackBarAction'), isTrue);
      expect(body.contains('知道了'), isTrue);
    });

    test('只在编辑器 initState 挂一次（不得每帧/每次 build 触发）', () {
      final s = codeEditor.readAsStringSync();
      final init = _fnBody(s, 'void initState');
      expect(init.contains('_maybeHintFontScale()'), isTrue,
          reason: '应挂载在 initState');
      final build = _fnBody(s, 'Widget build');
      expect(build.contains('_maybeHintFontScale'), isFalse,
          reason: '放 build 里会反复弹');
    });

    test('弹窗要检查 mounted（异步返回后 context 可能已失效）', () {
      final s = codeEditor.readAsStringSync();
      final idx = s.indexOf('_maybeHintFontScale');
      final body = s.substring(idx, (idx + 1400).clamp(0, s.length));
      expect(body.contains('mounted'), isTrue);
      // 异步 + context 场景应用 maybeOf 或先取 messenger，避免 use_build_context
      expect(body.contains('maybeOf') || body.contains('ScaffoldMessenger'),
          isTrue);
    });
  });
}

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
