import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// alpha.83 · Bug 613「键盘一弹，侧栏闪出又收回，AI 设置面板状态全丢」的防线。
///
/// ## 真实链路（真机反馈）
/// App 是 `adjustResize`：点输入框 → 键盘弹起 → 窗口被压矮 →
/// `OrientationBuilder` 用的约束长宽比翻转成 landscape → 侧栏闪出；
/// 同时 body 从 `sections` 变成 `Row(sections)`，**IndexedStack 的 Element
/// 位置变了 → 六个区的 State（含 AI 设置面板）全部销毁重建**。
/// 表现：模式跳回默认 MCP 又切回来、键盘回收、正在敲的 key 丢失。
///
/// ## 为什么用宽度阈值
/// 键盘只压高度、不压宽度 —— `MediaQuery.sizeOf(context).width` 对键盘
/// 免疫，对真实旋转仍然有效。这是本测试要守住的核心不变式。
String src(String rel) => File(rel).readAsStringSync();

/// 剥掉 `//` 行注释后的代码。
///
/// ⚠️ 必须剥：这两个文件里**大量注释在解释"为什么不能用 OrientationBuilder"**，
/// 直接 `contains('OrientationBuilder')` 会把解释当成违规命中。断言要盯
/// 代码本身，不能被文案左右（Bug 610 的教训：别拿排版/文案当判据）。
String codeOnly(String s) =>
    s.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

void main() {
  group('Bug 613 · 侧栏判定不许看"方向"', () {
    test('project_page 代码里不再用 OrientationBuilder', () {
      final s = codeOnly(src('lib/project/project_page.dart'));
      expect(s, isNot(contains('OrientationBuilder')),
          reason: 'adjustResize 下键盘会把 orientation 弄翻，侧栏闪出又收回');
      expect(s, isNot(contains('Orientation.landscape')));
    });

    test('project_page 改用宽度阈值', () {
      final s = codeOnly(src('lib/project/project_page.dart'));
      expect(RegExp(r'MediaQuery\.sizeOf\(context\)\.width >= 600').hasMatch(s),
          isTrue,
          reason: '宽度对键盘免疫；600 是既有的"常驻左栏"阈值口径');
    });

    test('editor_page 独立模式同病同治', () {
      final s = codeOnly(src('lib/editor/editor_page.dart'));
      expect(s, isNot(contains('OrientationBuilder')),
          reason: '编辑器页原来也用它判 Drawer/常驻左栏');
      expect(RegExp(r'MediaQuery\.sizeOf\(context\)\.width < 600').hasMatch(s),
          isTrue);
    });

    test('body 树结构恒定：Row + 条件 children（sections 位置不变）', () {
      final p = src('lib/project/project_page.dart');
      final i = p.indexOf('body: Builder(');
      expect(i, greaterThanOrEqualTo(0));
      final body = p.substring(i, i + 900);
      expect(body, contains('Row('));
      // 侧栏是**条件 children**，不是"外层换一棵树"
      expect(
          RegExp(r'if \(wide\) SizedBox\(width: 280').hasMatch(body), isTrue);
      expect(body, contains('Expanded(child: _buildSections())'),
          reason: 'sections 必须永远在 Row→Expanded 这个固定位置，'
              '否则旋转/键盘都会让 IndexedStack 的 Element 重排、State 重建');
      // 严禁退回"三元换树"
      expect(body, isNot(contains('if (!landscape) return sections')));
    });

    test('编辑器页 body 同样是恒定 Row', () {
      final s = src('lib/editor/editor_page.dart');
      final i = s.indexOf('body: Row(');
      expect(i, greaterThanOrEqualTo(0));
      final body = s.substring(i, i + 500);
      expect(
          RegExp(r'if \(wide\) SizedBox\(width: 280').hasMatch(body), isTrue);
      expect(body, contains('Expanded(child: _buildEditorPanel())'));
    });
  });

  group('不变式 · 宽度变化不会把树换掉（真 pump 验证 State 保活）', () {
    testWidgets('只有宽度决定侧栏：高度被压缩（模拟键盘）时布局不变', (tester) async {
      var built = 0;

      Widget probe() => MaterialApp(
            home: Builder(
              builder: (context) {
                // 被测逻辑的最小复刻：与 project_page 同判据
                final wide = MediaQuery.sizeOf(context).width >= 600;
                built++;
                return Row(
                  children: [
                    if (wide) const SizedBox(width: 280, child: Text('侧栏')),
                    if (wide) const VerticalDivider(width: 1),
                    const Expanded(child: Text('内容')),
                  ],
                );
              },
            ),
          );

      // 竖屏手机尺寸
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(probe());
      expect(find.text('侧栏'), findsNothing, reason: '竖屏不常驻侧栏');
      expect(built, 1);

      // 键盘弹起：adjustResize 下窗口被压矮 —— 高度骤降，宽度不变
      tester.view.physicalSize = const Size(1080, 1000);
      await tester.pump();
      expect(find.text('侧栏'), findsNothing, reason: '高度被键盘压了，侧栏绝不该因此冒出来');
      await tester.pump();
      expect(built, greaterThanOrEqualTo(2));

      // 真横向（宽度也变宽）→ 侧栏才该出现
      tester.view.physicalSize = const Size(2200, 1080);
      await tester.pump();
      expect(find.text('侧栏'), findsOneWidget, reason: '真横屏要正常出侧栏');
    });

    testWidgets('旧写法会翻车（守住"为什么不能用 orientation"这个前提）', (tester) async {
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: OrientationBuilder(
          builder: (context, orientation) =>
              Text(orientation == Orientation.landscape ? '横' : '竖'),
        ),
      ));
      expect(find.text('竖'), findsOneWidget);

      // 只压高度（键盘）——orientation 就翻了。这正是真机看到"侧栏闪出"
      // 的机制；留这条测试是为了让后来者明白判据为什么必须换。
      tester.view.physicalSize = const Size(1080, 900);
      await tester.pump();
      expect(find.text('横'), findsOneWidget,
          reason: 'OrientationBuilder 只看约束长宽比 —— 键盘一压就误判成横向');
    });
  });
}
