import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/project/design_model.dart';

/// 「未识别组件尽力还原」的提取器测试（alpha.75）。
///
/// 背景：用户导入自己的项目后，未识别组件在预览里全是黄框
/// 「未识别：xxx」，一屏十几个像工具坏了。诉求原话是
/// "设计有控件不适配，能否适配所有原生组件"。
///
/// 「适配所有组件」做不到（Flutter 400+ widget + 自定义方法实现在别处），
/// 但**能从源码里读出来的视觉信息就用它渲染**。这个文件测的就是
/// "读得准不准、该放弃时有没有放弃"。
void main() {
  group('UnknownVisual · 能读出来的就读出来', () {
    test('尺寸：裸数字', () {
      final v = UnknownVisual.parse('SizedBox(width: 120, height: 48)')!;
      expect(v.width, 120);
      expect(v.height, 48);
    });

    test('尺寸：小数也认', () {
      final v = UnknownVisual.parse('Container(width: 12.5)')!;
      expect(v.width, 12.5);
    });

    test('尺寸：不会把 maxWidth 误当 width', () {
      // 这是最容易出的错：`maxWidth` 里含 `width`，
      // 不做左边界约束就会把约束值当成实际宽度。
      final v = UnknownVisual.parse(
          'ConstrainedBox(constraints: BoxConstraints(maxWidth: 300))');
      expect(v, isNull, reason: '只有 maxWidth 时不该提取出 width');
      // 再验一次带 width 的场景：应该只取 width，不取 maxWidth
      final v2 = UnknownVisual
          .parse('Container(width: 80, constraints: BoxConstraints(maxWidth: 300))')!;
      expect(v2.width, 80, reason: '有 width 时必须取它，不是取 maxWidth 的 300');
    });

    test('颜色：Colors.xxx 命名色', () {
      expect(UnknownVisual.parse('Container(color: Colors.blue)')!.color,
          '#2196F3');
      expect(UnknownVisual.parse('Card(color: Colors.white)')!.color,
          '#FFFFFF');
    });

    test('颜色：命名风格不敏感（blueGrey / bluegrey 都认）', () {
      expect(
          UnknownVisual.parse('Box(color: Colors.blueGrey)')!.color, '#607D8B');
    });

    test('颜色：Color(0xFF...) 十六进制', () {
      final v = UnknownVisual.parse('Container(color: Color(0xFF3DDC84))')!;
      expect(v.color, '#3DDC84');
    });

    test('圆角：BorderRadius.circular', () {
      expect(
          UnknownVisual.parse('Container(decoration: BoxDecoration('
              'borderRadius: BorderRadius.circular(14)))')!.radius,
          14);
    });

    test('内边距：EdgeInsets.all 优先', () {
      expect(UnknownVisual.parse('Padding(padding: EdgeInsets.all(16))')!.padding,
          16);
    });

    test('内边距：symmetric / only 也能取到一个值', () {
      expect(
          UnknownVisual.parse(
              'Padding(padding: EdgeInsets.symmetric(horizontal: 24))')!.padding,
          24);
      expect(
          UnknownVisual
              .parse('Padding(padding: EdgeInsets.only(left: 8))')!.padding,
          8);
    });

    test('图标：Icons.xxx 取到名字', () {
      expect(UnknownVisual.parse("Icon(Icons.add)")!.iconName, 'add');
      // alpha.79 起：参数位置上的 `Icon(...)` 是**子节点**，它的图标归
      // 子节点自己的节点提取（导入器会为它建 icon 子节点），外层不再
      // 越权拿走 —— 与 width/height 同一条语义（子节点的东西不归外层）。
      // IconButton 外层没有任何自己的视觉参数 → 整体提取不到东西，
      // 按「读不出来必须放弃」返回 null（图标由 Icon 子节点自己渲染）。
      expect(
        UnknownVisual.parse("IconButton(icon: Icon(Icons.favorite))"),
        isNull,
        reason: '外层 IconButton 无自己的视觉参数；favorite 属于 Icon 子节点',
      );
    });

    test('阴影：elevation 整数', () {
      expect(UnknownVisual.parse('Card(elevation: 4)')!.elevation, 4);
    });

    test('综合：一次全提取（真实 Container 写法）', () {
      final v = UnknownVisual.parse(
          'Container(width: 100, height: 100, '
          "decoration: BoxDecoration(color: Colors.green, "
          'borderRadius: BorderRadius.circular(12)), '
          'padding: EdgeInsets.all(8), child: Icon(Icons.star))')!;
      expect(v.width, 100);
      expect(v.height, 100);
      expect(v.color, '#4CAF50');
      expect(v.radius, 12);
      expect(v.padding, 8);
      // alpha.79：`child: Icon(Icons.star)` 的 Icon 是子节点，star 归它
      // 自己的节点提取，外层不再越权。
      expect(v.iconName, isNull,
          reason: 'child: 参数的值是子组件，star 属于那个 Icon 子节点');
      expect(v.hasSomething, isTrue);
    });
  });

  group('UnknownVisual · 读不出来时必须放弃（不能猜）', () {
    test('纯方法调用 → null（这就是用户截图里那种）', () {
      // `_buildStatusCard(context)` 的实现在别处，源码里没有任何线索。
      // 这种情况必须老实返回 null，让上层继续画提示框。
      expect(UnknownVisual.parse('_buildStatusCard(context)'), isNull);
      expect(UnknownVisual.parse('_buildEnvCard(context)'), isNull);
    });

    test('变量当尺寸 → 放弃该项，而不是猜个数', () {
      // `width: w` 里 w 是运行时才知道的，猜个值画出来就是骗人。
      final v = UnknownVisual.parse('Container(width: w, height: h)');
      expect(v, isNull, reason: '变量尺寸应整体判为"没提取到"');
    });

    test('表达式当颜色 → 放弃颜色', () {
      final v = UnknownVisual.parse('Container(color: theme.primaryColor)');
      expect(v, isNull);
    });

    test('空串 / 空白 → null', () {
      expect(UnknownVisual.parse(''), isNull);
      expect(UnknownVisual.parse('   \n  '), isNull);
    });

    test('超大的尺寸当没读到（防撑爆预览）', () {
      expect(UnknownVisual.parse('Container(width: 99999)'), isNull);
      expect(UnknownVisual.parse('SizedBox(height: 50000)'), isNull);
    });

    test('负尺寸 / 负圆角 不认', () {
      expect(UnknownVisual.parse('SizedBox(width: -5)'), isNull);
      expect(UnknownVisual.parse('Container(width: 0)'), isNull,
          reason: '0 宽度在预览里等于不可见，无意义');
    });

    test('未收录的颜色名不猜', () {
      // 用的是自定义颜色（不是 Material 标准名）→ 取不到，返回 null，
      // 让上层用兜底中性色，而不是随便配一个相近色。
      final v = UnknownVisual.parse('Container(color: Colors.myCustomColor)');
      expect(v, isNull);
    });
  });

  group('UnknownVisual · hasSomething 与 parse 的一致性', () {
    test('parse 返回非 null 时 hasSomething 必为 true', () {
      const samples = <String>[
        'SizedBox(width: 20)',
        'Container(color: Colors.red)',
        'Container(elevation: 2)',
        "Icon(Icons.home)",
        'Padding(padding: EdgeInsets.all(4))',
      ];
      for (final s in samples) {
        final v = UnknownVisual.parse(s);
        expect(v, isNotNull, reason: '「$s」应该能提取到东西');
        expect(v!.hasSomething, isTrue, reason: '「$s」的 hasSomething 应为 true');
      }
    });

    test('不含任何视觉信息的源码不返回对象', () {
      // 只有一个裸 widget 名，没有参数 —— 提取不到任何东西。
      expect(UnknownVisual.parse('MyCustomWidget()'), isNull);
      expect(UnknownVisual.parse('Foo(child: Bar())'), isNull);
    });
  });
}
