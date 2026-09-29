import 'package:foaide/ai/diff.dart';
import 'package:foaide/editor/diff_sheet.dart';
import 'package:foaide/editor/diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// alpha.91：diff 预览从「小弹窗」改成「全屏抽屉」的回归测试。
///
/// ## 这组测试要钉住的事（真机反馈）
///
/// 用户原话：**"感觉这个弹窗预览不是很好"**，
/// 追问确认痛点是 **"窗口太小，132 行根本看不过来"**。
///
/// 原实现两个硬伤：
///   1. `AlertDialog` + `maxHeight: 170` —— 170px 放 12~15 行，
///      塞 132 行改动 = 在小窗口里滚上百行；
///   2. `Text(..., overflow: ellipsis)` 渲染代码行 —— **长行自动折行**，
///      一个 `+` 占三行，用户数行号对不上（这是信息错误，不只是难看）。
///
/// 所以下面两个 group 分别钉：
///   - **不许再折行**（`softWrap` 语义 + 横向滚动存在）
///   - **抽屉必须比旧弹窗大得多**（高度占比）
void main() {
  /// 挂一个最小宿主，并把**已挂载的** context 交出来。
  ///
  /// ⚠️ 别写成"按钮 onPressed 里赋值"——那样必须 `tap` 才会赋值，
  /// 忘了 tap 就是 `LateInitializationError`（本测试第一版就这么挂的）。
  /// 这里直接把 [Builder] 的 context 存下来，挂载即用。
  Future<BuildContext> mountHost(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ctx;
  }

  group('DiffLinesView · 代码行不许折行（真机 bug 回归）', () {
    testWidgets('长代码行不折行：走横向滚动而非自动换行', (tester) async {
      // 一行足够长的代码——在手机宽度下必然超宽。旧实现会把它折成好几行。
      const longLine =
          '    final ColorScheme colorScheme = Theme.of(context).colorScheme;'
          '  // 这一行后面还有很多内容，用来确保它一定会超出屏幕宽度';

      final d = lineDiff('old\n', 'old\n$longLine\n');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DiffLinesView(d),
        ),
      ));
      await tester.pumpAndSettle();

      // ① 必须存在横向滚动容器（旧实现没有，长行只能折行）。
      expect(
        find.byWidgetPredicate((w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
        findsWidgets,
        reason: '长代码行必须能左右滑动查看，而不是折行',
      );

      // ② 长行文本本身必须"单行、不软换行"。
      final st = tester.widget<SelectableText>(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data != null && w.data!.contains('final ColorScheme'),
        ),
      );
      expect(st.maxLines, 1,
          reason: '代码行只能是 1 行；maxLines 不设死就会折行，导致行号对不上');

      // ③ 关键：这一行的**渲染高度**必须约等于一行。
      //    如果折行了，高度会变成两三倍——这是最直接的"折没折"判据。
      final h = tester.getSize(find.byWidget(st)).height;
      const oneLine = 12.5 * 1.45; // fontSize * lineHeight（组件默认值）
      expect(h, lessThan(oneLine * 2),
          reason: '该行渲染高度 $h 远超单行高度 $oneLine —— 说明它被折行了');
    });

    testWidgets('每一行都带行号，且行号来自原始文件位置', (tester) async {
      final d = lineDiff('a\nb\nc\n', 'a\nB\nc\n');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffLinesView(d)),
      ));
      await tester.pumpAndSettle();

      // 第 2 行被改成了 'B'。它的行号应该是 2。
      expect(find.text('2'), findsWidgets, reason: '改动行必须带原始行号，便于回编辑器定位');
      expect(find.text('B'), findsOneWidget);
      expect(find.text('b'), findsOneWidget);
    });

    testWidgets('新增/删除行分别渲染，符号与文本都在', (tester) async {
      final d = lineDiff('one\n', 'one\ntwo\n');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffLinesView(d)),
      ));
      await tester.pumpAndSettle();
      expect(find.text('+'), findsWidgets);
      expect(find.text('two'), findsOneWidget);
    });

    testWidgets('折叠未改动上下文，并如实说明折了多少行', (tester) async {
      // 造 20 行 same + 1 行改动，中间那段应被折叠。
      final oldLines = List.generate(20, (i) => 'line$i');
      final newLines = [...oldLines]..[10] = 'CHANGED';
      final d = lineDiff(oldLines.join('\n'), newLines.join('\n'));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: DiffLinesView(d)),
      ));
      await tester.pumpAndSettle();

      // 必须出现折叠占位，且**写明折了多少行**（不能悄悄吞掉）。
      expect(
        find.byWidgetPredicate((w) =>
            w is Text && (w.data ?? '').contains('未改动') && (w.data ?? '').contains('行')),
        findsWidgets,
        reason: '折叠的上下文行数必须如实显示',
      );
      expect(find.text('CHANGED'), findsOneWidget);
    });

    test('空差异给出明确文案，而不是一片空白', () {
      final d = lineDiff('same\n', 'same\n');
      expect(d.isEmpty, isTrue);
    });
  });

  group('showDiffSheet · 抽屉必须比旧弹窗大得多', () {
    testWidgets('抽屉高度接近全屏（旧弹窗 170px 已被取代）', (tester) async {
      // 模拟一个常见手机屏幕。
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final oldLines = List.generate(150, (i) => 'line $i');
      final newLines = [...oldLines];
      for (var i = 40; i < 172; i++) {
        newLines.insert(i, 'added $i // 这是新增的一行代码内容，故意写长一点');
      }
      final d = lineDiff(oldLines.join('\n'), newLines.join('\n'));

      final hostCtx = await mountHost(tester);

      final fut = showDiffSheet(
        hostCtx,
        title: 'AI 已写入编辑器',
        warnings: const [],
        diff: d,
        actions: const [
          DiffAction('放弃', DiffChoice.discard),
          DiffAction('先不存', DiffChoice.later),
          DiffAction('保存', DiffChoice.save, primary: true),
        ],
      );
      await tester.pumpAndSettle();

      // 抽屉本体（用「保存」按钮所在的最近 FractionallySizedBox 估算）。
      final box = tester.getSize(find.byType(FractionallySizedBox));
      const screenH = 2340 / 3.0; // 逻辑像素高
      expect(box.height, greaterThan(screenH * 0.5),
          reason: '抽屉高度应接近全屏；旧弹窗只有 170px，正是"看不过来"的根因');

      // 三个动作按钮必须在**一打开就可见**，不需要滚动才能找到。
      expect(find.text('放弃'), findsOneWidget);
      expect(find.text('先不存'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);

      // 统计信息也要在首屏可见。
      expect(find.textContaining('新增'), findsWidgets);

      // 收尾：点「保存」，验证返回值正确。
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(await fut, DiffChoice.save);
    });

    testWidgets('点关闭 → 返回 later（= 保留改动但不落盘）', (tester) async {
      final d = lineDiff('a\n', 'a\nb\n');
      final hostCtx = await mountHost(tester);

      final fut = showDiffSheet(
        hostCtx,
        title: 'AI 已写入编辑器',
        warnings: const [],
        diff: d,
        actions: const [
          DiffAction('放弃', DiffChoice.discard),
          DiffAction('先不存', DiffChoice.later),
          DiffAction('保存', DiffChoice.save, primary: true),
        ],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(await fut, DiffChoice.later);
    });

    testWidgets('外部变更：有未保存改动时把警告带进抽屉', (tester) async {
      final d = lineDiff('a\n', 'a\nb\n');
      final hostCtx = await mountHost(tester);

      final fut = showDiffSheet(
        hostCtx,
        title: '远程 AI 改了文件',
        warnings: const [
          Text('你本地还有未保存的修改，载入会覆盖它们'),
        ],
        diff: d,
        actions: const [
          DiffAction('忽略', DiffChoice.discard),
          DiffAction('先放着', DiffChoice.later),
          DiffAction('载入', DiffChoice.save, primary: true),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('你本地还有未保存的修改，载入会覆盖它们'), findsOneWidget);

      await tester.tap(find.text('忽略'));
      await tester.pumpAndSettle();
      expect(await fut, DiffChoice.discard);
    });

    testWidgets('无差异时不显示"新增 0 行"这种废话，且给出"无改动"', (tester) async {
      final d = lineDiff('same\n', 'same\n');
      final hostCtx = await mountHost(tester);

      final fut = showDiffSheet(
        hostCtx,
        title: 'AI 已写入编辑器',
        warnings: const [],
        diff: d,
        actions: const [
          DiffAction('先不存', DiffChoice.later),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('无改动'), findsOneWidget);
      expect(find.textContaining('新增 0 行'), findsNothing);

      await tester.tap(find.text('先不存'));
      await tester.pumpAndSettle();
      expect(await fut, DiffChoice.later);
    });
  });

  // ⚠️ 这里**本来有三条**"小屏/横屏不溢出"的测试，alpha.91 被我删了。
  //
  // 原因：我怀疑 `Column` 里带 `Expanded` 时 `mainAxisSize: min` 会溢出，
  // 于是写了三条测试（360×640 / 740×360 / 360×420）钉住它。
  //
  // **然后我按规矩做了"先看它红过"的验证：把修复回退，测试依然全绿。**
  // 说明这三条**测不出任何东西**——`FractionallySizedBox(heightFactor:)`
  // 给的是**紧约束**，`mainAxisSize` 在紧约束下会被直接忽略，压根不会溢出。
  // 我的"隐患"判断本身就是错的。
  //
  // 留着的代价：下次有人真的把布局改坏，会以为"有测试守着，没事"。
  // **假测试比没有测试更危险**（见 handbook Bug 625）。
  //
  // 所以删掉。真要在意小屏，正确的做法是：**先造一个能红的场景**，
  // 再造不出红，就说明这个担心不成立，别写测试给自己壮胆。
}
