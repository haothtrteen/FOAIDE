import 'dart:io';

import 'package:foaide/editor/fs_bridge.dart';
import 'package:foaide/project/design_import.dart';
import 'package:foaide/project/design_model.dart';
import 'package:foaide/project/design_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// alpha.78 的两个真机问题回归测试。
void main() {
  /// 造一个最小可用的 DesignPage。
  Future<DesignPageState> mount(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DesignPage(
          projectName: 'demo',
          bridge: FsBridge(),
          onOpenFile: (_) {},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return tester.state<DesignPageState>(find.byType(DesignPage));
  }

  group('预览渲染：unknown 近似还原不能崩（alpha.77 真机 bug）', () {
    /// ⚠️ 关于【怎么测才算数】的血泪教训，别删：
    ///
    /// 这个 bug 我写了**两版**回归测试，两版都是绿的，而真机上照样崩。
    ///
    /// **第一版**：用"没有 `children` **字段**"的节点 —— 连空列表都不是，
    /// 代码里压根走不到出问题那条分支。加不加修复都绿。**测了个寂寞。**
    ///
    /// **第二版**：改用 `children: const <DesignNode>[]`（空列表），
    /// 单看构造没问题，但测试只调了 `renderPreview(node)` ——
    /// 而崩溃分支 `_previewShell` **只有 `node == _root` 才会走**。
    /// 传进去的节点不是 `_root`，于是又绿了。
    ///
    /// **唯一让测试变红的办法：把 `_root` 换成待测节点**，走真机同一条路。
    /// 测试里现在用 [DesignPageState.debugSetRoot] 做到这一点。
    ///
    /// 结论：防崩溃回归测试写完**必须回退修复验红**。这次一验就发现
    /// 前面两版全是假测试 —— 这个动作不能省。
    testWidgets('空 children + 无图标：真实触发路径（绑定 _root 才能进崩溃分支）',
        (tester) async {
      final state = await mount(tester);

      // 外层 Container 拿不到尺寸（raw 解析不出 width/height）、
      // children 过滤后为空、也没有图标 —— 三个条件同时满足，
      // `inner` 才会是 null，Stack 才会一个定尺寸的孩子都没有。
      final node = DesignNode(
        type: DesignComponentType.unknown,
        props: <String, Object?>{
          'raw': 'X()',
          'sourceName': 'X',
        },
        children: const <DesignNode>[],
      );

      state.debugSetRoot(node);
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'Stack 必须有非 positioned 的定尺寸孩子，'
            '否则 performLayout 抛 "A Stack requires bounded constraints"',
      );
    });

    testWidgets('子节点全是外壳类型（过滤后为空）也不崩', (tester) async {
      final state = await mount(tester);
      final node = DesignNode(
        type: DesignComponentType.unknown,
        props: <String, Object?>{'raw': 'X()', 'sourceName': 'X'},
        children: [
          DesignNode(type: DesignComponentType.appBar, props: {'title': 'x'}),
        ],
      );

      state.debugSetRoot(node);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('unknown 嵌在 Card 里（真实层级）也不崩', (tester) async {
      final state = await mount(tester);
      final root = DesignNode(
        type: DesignComponentType.root,
        props: <String, Object?>{'background': 'none', 'padding': 16.0},
        children: [
          DesignNode(
            type: DesignComponentType.card,
            props: <String, Object?>{},
            children: [
              DesignNode(
                type: DesignComponentType.unknown,
                props: <String, Object?>{'raw': 'X()', 'sourceName': 'X'},
                children: const <DesignNode>[],
              ),
            ],
          ),
        ],
      );

      state.debugSetRoot(root);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    /// 用**用户真实文件**跑一遍 —— 这是最终验收，比手造节点可信。
    ///
    /// 真实文件里那个 unknown 是 `GridView.count`，展开出 6 个子节点，
    /// 走的是 `kids.isNotEmpty` 分支；但它下面的 `_buildActionButton`
    /// 全被展平成 `Container`，一层层叠下来，最终仍有落进
    /// "无定尺寸孩子"的机会。真机上就是这一整棵渲染不出来。
    testWidgets('用户真实文件两个入口都渲染得出内容', (tester) async {
      final f = File('/tmp/user_real.dart');
      if (!f.existsSync()) {
        // 真实样本不在（CI / 别的机器）就跳过，不假装通过。
        return;
      }
      final src = f.readAsStringSync();

      for (final name in ['FOAIDEApp', 'FOAIDEHomePage']) {
        final cand =
            findCandidates(src).firstWhere((x) => x.displayName == name);
        final r = importCandidate(src, cand);

        final state = await mount(tester);
        state.debugSetRoot(r.root);
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: '[$name] 真机上是"黄框没了但啥都不显示"，'
              '就是这里整棵树渲染崩了',
        );
        expect(
          find.byType(Text).evaluate().length,
          greaterThan(10),
          reason: '[$name] 不崩还不够 —— 得真的渲染出内容，'
              '否则测的只是"没报错"',
        );
        // 从 GridView 里展开出来的六个按钮文案，必须真的出现。
        // 它们的位子正是被那坨源码文本挤掉的（见 next 那条 group）。
        expect(find.text('打开终端'), findsWidgets,
            reason: '[$name] 按钮文案被源码文本挤没了 —— '
                '用户看到的就是"啥都不显示"');
        expect(find.text('构建 APK'), findsWidgets);
      }
    });

    testWidgets('用户真实文件里不该出现源码原文', (tester) async {
      final f = File('/tmp/user_real.dart');
      if (!f.existsSync()) return;
      final src = f.readAsStringSync();
      final cand =
          findCandidates(src).firstWhere((x) => x.displayName == 'FOAIDEHomePage');
      final r = importCandidate(src, cand);

      final state = await mount(tester);
      state.debugSetRoot(r.root);
      await tester.pumpAndSettle();

      expect(find.textContaining('GridView.count'), findsNothing,
          reason: '那坨源码文本是 alpha.77 真机上"啥都不显示"的元凶');
      expect(find.textContaining('// 使用 GridView'), findsNothing);
    });
  });

  group('预览渲染：源码文本不该出现在预览里（alpha.78 真机）', () {
    /// 真机现象：用户导入自己的 `main.dart` 后，预览正中间横着一大坨
    /// `GridView.count(...)` 源码，把版面撑爆 —— 原话"啥都不显示了"。
    ///
    /// 根因：`_unknownPlaceholder` 用 `trimLeft().startsWith('//')` 判定
    /// "纯注释节点"，而用户最常见的写法是 **`// 注释` 紧跟组件**。
    /// 旧判定把这个组件节点当成注释，于是把整段源码当文字吐了出来。
    test('纯注释判定：注释 + 紧跟组件 ≠ 纯注释', () {
      expect(
        isPureCommentSource('// 使用 GridView 替代复杂的 Row/Column 嵌套，更灵活\n'
            'GridView.count(\n  shrinkWrap: true,\n)'),
        isFalse,
        reason: '这明明是个组件节点，只是前面带了行注释。'
            '判成纯注释就会把整段源码渲染成文字',
      );
      expect(isPureCommentSource('// 只是一行注释'), isTrue);
      expect(isPureCommentSource('\n\n// 前后有空行\n// 两行注释\n\n'), isTrue);
      expect(isPureCommentSource('Container()'), isFalse);
      expect(isPureCommentSource(''), isTrue, reason: '空也算"没有代码"');
    });

    testWidgets('带前导注释的 unknown 节点，预览里不出现源码原文', (tester) async {
      final state = await mount(tester);
      final node = DesignNode(
        type: DesignComponentType.unknown,
        props: <String, Object?>{
          'raw': '// 使用 GridView 替代复杂的 Row/Column 嵌套\n'
              'GridView.count(crossAxisCount: 2)',
          'sourceName': 'GridView',
        },
      );

      state.debugSetRoot(node);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final srcLeak = find.textContaining('GridView.count');
      expect(srcLeak, findsNothing,
          reason: '整段源码出现在预览里，用户看到的就是"一坨代码"');
    });
  });

  group('导入：参数值类型不该被当成子组件（alpha.78 真机）', () {
    /// 真机现象：`Icon(Icons.check_circle, color: Color(0xFF10B981))` 在
    /// 预览里**图标下面多出一个色块**。
    ///
    /// 根因：`_innerChildren` 拿不到 `child:`/`children:` 时，会**扫所有
    /// 参数**找第一个 widget 构造。而 `Color(...)` / `BoxDecoration(...)`
    /// 这些**属性值构造**长得和 widget 一模一样，于是被收成了子节点。
    test('Icon 的 color 参数不会被收成子节点', () {
      const src = '''
import 'package:flutter/material.dart';
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 28);
  }
}
''';
      final r = importCandidate(src, findCandidates(src).first);

      // 找到那个 Icon 节点，检查它肚子里有没有被塞进参数值
      DesignNode? iconNode;
      void walk(DesignNode n) {
        if ((n.props['sourceName'] as String? ?? '') == 'Icon') iconNode = n;
        for (final c in n.children) {
          walk(c);
        }
      }

      walk(r.root);
      expect(iconNode, isNotNull, reason: '得先确实导入了那个 Icon');
      final kidNames = iconNode!.children
          .map((c) => c.props['sourceName']?.toString() ?? '')
          .toList();
      expect(kidNames, isNot(contains('Color')),
          reason: '`color:` 是参数值不是子组件，'
              '被收进来预览里就会在图标下面多画一个色块');
      expect(iconNode!.children, isEmpty,
          reason: '一个纯 Icon 不该带任何子节点');
    });
  });

  group('UnknownVisual：只提外层自己的视觉属性（alpha.79 真机）', () {
    /// 真机现象（用户导入自己的 main.dart）：`_buildActionButton` 的按钮
    /// 被压成一条横线 —— 尺寸提取在**整段源码**上全局搜 `height:`，
    /// 把子节点 `SizedBox(height: 4)` 的 4 当成了外层按钮的高度；
    /// `GridView.count(children: [..., Icons.terminal])` 里孙节点的
    /// 图标被当成 GridView 自己的。
    ///
    /// 正确语义：外层参数 + 值类型参数（BoxDecoration/Color/EdgeInsets）
    /// 内部**可以**搜；widget 型嵌套调用（Column/Text/_buildXxx）的内部
    /// 是子节点自己的事，一概不能碰。
    test('子节点的 height 不该被当成外层尺寸', () {
      final v = UnknownVisual.parse(
          'Container(child: Column(children: [SizedBox(height: 4)]))');
      expect(v?.height, isNull,
          reason: 'SizedBox(height: 4) 是子节点的尺寸，'
              '提给外层会把按钮压成 4px 高的横线（alpha.78 真机 bug）');
    });

    test('孙子节点的 Icons.xxx 不该被当成外层图标', () {
      final v = UnknownVisual.parse('GridView.count(children: '
          '[_buildActionButton(context, "打开终端", Icons.terminal)])');
      expect(v?.iconName, isNull,
          reason: 'Icons.terminal 是 _buildActionButton 的实参，'
              'GridView 不是图标组件');
    });

    test('外层自己的参数照常提取', () {
      final v = UnknownVisual.parse(
          'Container(width: 100, height: 40, color: Color(0xFF10B981))');
      expect(v?.width, 100.0);
      expect(v?.height, 40.0);
      expect(v?.color, '#10B981');
    });

    test('值类型参数（decoration）内部仍要提取', () {
      final v = UnknownVisual.parse('Container(decoration: BoxDecoration('
          'color: Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(12)), '
          'child: Column(children: [SizedBox(height: 4)]))');
      expect(v?.color, '#F3F4F6', reason: '颜色来自 decoration —— 值类型，能提');
      expect(v?.radius, 12.0, reason: '圆角来自 decoration —— 值类型，能提');
      expect(v?.height, isNull, reason: '但子节点 Column 的内容不能碰');
    });

    test('TextStyle 的 height 是行高倍数，不是像素', () {
      final v = UnknownVisual.parse(
          "Text(title, style: TextStyle(height: 1.4, fontSize: 13))");
      expect(v?.height, isNull,
          reason: 'TextStyle.height 是行高倍数（1.4 倍），'
              '提走会把整块压成 1.4px');
    });

    test('纯文本（无括号）行为不变 —— 全文可提取', () {
      // 没有构造调用就没有"外层/子节点"之分，保持旧的全文提取语义
      // （手工节点的 raw 常是 `width: 80` 这种裸属性写法）。
      final v = UnknownVisual.parse('width: 80');
      expect(v?.width, 80.0);
      expect(UnknownVisual.parse('未识别的组件'), isNull);
    });
  });

  group('unknown 叶子不该被拉成整行（alpha.79 真机）', () {
    /// 真机现象：`Icon(check_circle, color: 绿)` 在预览里成了**一整条
    /// 绿色横幅** —— 页面主体是 `Column(stretch)`，叶子被横向拉满。
    testWidgets('叶子收缩到内容宽度，容器仍拉满', (tester) async {
      final state = await mount(tester);
      final root = DesignNode(
        type: DesignComponentType.root,
        props: <String, Object?>{'background': 'none', 'padding': 16.0},
        children: [
          // 叶子：带颜色的 Icon → 近似还原成绿色小块
          DesignNode(
            type: DesignComponentType.unknown,
            props: <String, Object?>{
              'raw': 'const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 28)',
              'sourceName': 'Icon',
            },
          ),
          // 容器：有子节点 → 保持拉满
          DesignNode(
            type: DesignComponentType.unknown,
            props: <String, Object?>{
              'raw': 'Container(color: Color(0xFF22D3EE))',
              'sourceName': 'Container',
            },
            children: [DesignNode(type: DesignComponentType.text, props: {'text': '内'})],
          ),
        ],
      );

      state.debugSetRoot(root);
      await tester.pumpAndSettle();

      // 注意：DesignPage 的预览区不是全屏宽（旁边/下面还有别的面板），
      // 所以"拉满"不能用屏幕宽做基准 —— 用**相对比较**：
      // 叶子必须远窄于容器，容器必须明显是 stretch 出来的宽度。
      final leaf = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color?.toARGB32() == 0xFF10B981);
      expect(leaf, findsOneWidget);
      final leafWidth = tester.getSize(leaf).width;

      final box = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color?.toARGB32() == 0xFF22D3EE);
      expect(box, findsOneWidget);
      final boxWidth = tester.getSize(box).width;

      expect(leafWidth, lessThan(boxWidth / 3),
          reason: '叶子（Icon 的近似还原）必须远窄于拉满的容器 —— '
              '真机上它是"一条绿色横幅"');
      expect(leafWidth, lessThan(80),
          reason: '28px 图标的近似块就该是几十px宽');
    });
  });

  group('组件库：插入栏固定在底部（alpha.78）', () {
    testWidgets('插入栏不随磁贴列表滚动', (tester) async {
      await mount(tester);
      await tester.pumpAndSettle();

      expect(find.text('插入位置'), findsOneWidget);

      final insertY = tester.getTopLeft(find.text('插入位置')).dy;

      // 滚动磁贴列表
      final listFinder = find.byType(GridView);
      if (listFinder.evaluate().isNotEmpty) {
        await tester.drag(listFinder.first, const Offset(0, -300));
        await tester.pumpAndSettle();
      }

      expect(find.text('插入位置'), findsOneWidget,
          reason: '插入栏固定在底部，滚完列表它还得在');
      expect(tester.getTopLeft(find.text('插入位置')).dy, insertY,
          reason: '位置必须**一模一样** —— 这才叫"固定"，'
              '只是"还在屏幕上"不够');
    });

    testWidgets('两个插入按钮在未长按选中时禁用', (tester) async {
      await mount(tester);
      await tester.pumpAndSettle();

      final upBtn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('上方插入'),
          matching: find.byType(OutlinedButton),
        ),
      );
      final downBtn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('下方插入'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(upBtn.onPressed, isNull);
      expect(downBtn.onPressed, isNull);
    });

    testWidgets('长按磁贴后按钮可用，且插入栏显示"已选：xxx"', (tester) async {
      await mount(tester);
      await tester.pumpAndSettle();

      final tile = find.text('按钮');
      expect(tile, findsWidgets);
      await tester.longPress(tile.first);
      await tester.pumpAndSettle();

      expect(find.textContaining('已选：'), findsOneWidget,
          reason: '固定栏和磁贴列表会滚开，必须写出来用户长按的是哪个');

      final upBtn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('上方插入'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(upBtn.onPressed, isNotNull);
    });
  });
}
