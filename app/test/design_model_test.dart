import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/project/design_model.dart';

/// 设计区**纯逻辑层**测试（alpha.70）。
///
/// 单独测模型 + 生成器而不 pumpWidget：生成器是纯字符串函数，
/// 直接对着输出断言比"渲染一整个页面再看效果"精确得多，
/// 也快一个量级。
/// 取 [code] 里第一行包含 [needle] 的行的前导空格数。
///
/// 用于断言嵌套层级 —— 光看"有没有这个字符串"发现不了
/// "缩进全平"这种问题（生成物语法正确，但读起来像一堆平级语句）。
int _indentOf(String code, String needle) {
  for (final line in code.split('\n')) {
    if (line.contains(needle)) {
      return line.length - line.trimLeft().length;
    }
  }
  fail('生成的代码里找不到 $needle');
}

void main() {
  setUp(() {
    DesignNode.resetIdSeq();
    DesignCodeGen.timestamp = '2026-09-22 16:03';
  });
  group('组件类型表', () {
    test('默认属性与可编辑字段表同键（防"属性面板改了个不存在的键"）', () {
      for (final t in DesignComponentType.values) {
        final defaults = t.defaultProps().keys.toSet();
        final fields = t.fields.map((f) => f.key).toSet();
        expect(
          fields.difference(defaults),
          isEmpty,
          reason: '${t.name}：字段表里有 ${fields.difference(defaults)} '
              '但在 defaultProps 里没有 —— 用户改它不会有任何效果',
        );
      }
    });

    test('字段表不含重复键', () {
      for (final t in DesignComponentType.values) {
        final keys = t.fields.map((f) => f.key).toList();
        expect(keys.toSet().length, keys.length,
            reason: '${t.name} 的 fields 有重复键，面板会渲染两个一样的输入框');
      }
    });

    test('接受子节点的是 root、card、box、unknown 四个', () {
      final accepting = DesignComponentType.values
          .where((t) => t.acceptsChildren)
          .toSet();
      // `unknown` 是 alpha.71 导入功能加的：占位节点可能包着一整棵子树
      // （比如一个 `BlocBuilder`），不接受子节点的话导入后它的内部
      // 结构就全丢了。它不参与生成（raw 整段吐回去），
      // 放子节点进去也不影响输出。
      //
      // `box` 是 alpha.74 加的：`AnimatedContainer` 摊平成的静态方块，
      // `child:` 里那个图标要能挂进去。
      expect(accepting, {
        DesignComponentType.root,
        DesignComponentType.card,
        DesignComponentType.box,
        DesignComponentType.unknown,
      });
    });

    test('unknown 不出现在组件库里能点的地方', () {
      // 这条断言是"加枚举成员时最容易漏的一处"的哨兵：
      // 组件库用的是 `for (values)`，新成员会**自动**出现 ——
      // 而空 raw 的占位节点点了只会得到一片空白。
      // 真正的排除写在 design_page.dart，这里只确认"确实排除了"。
      final page =
          File('lib/project/design_page.dart').readAsStringSync();
      expect(
        RegExp(r'DesignComponentType\.unknown').allMatches(page).length,
        greaterThanOrEqualTo(3),
        reason: 'design_page 里至少要处理 unknown（预览/树摘要/组件库排除）',
      );
      expect(page.contains('if (t != DesignComponentType.root &&'), isTrue,
          reason: '组件库网格必须显式排除 unknown');
    });

    test('root 不可删除，其余都可删', () {
      expect(DesignComponentType.root.isDeletable, isFalse,
          reason: '根节点是可删的话，用户误删就整页空白且无法恢复');
      for (final t in DesignComponentType.values) {
        if (t == DesignComponentType.root) continue;
        expect(t.isDeletable, isTrue);
      }
    });

    test('每个类型都有非空 label 与 iconName', () {
      for (final t in DesignComponentType.values) {
        expect(t.label.isNotEmpty, isTrue);
        expect(t.iconName.isNotEmpty, isTrue);
      }
    });
  });

  group('设计树节点', () {
    test('构造时填入该类型的默认属性', () {
      final n = DesignNode(type: DesignComponentType.heading);
      expect(n.props['text'], '标题');
      expect(n.props['size'], 24.0);
    });

    test('显式属性覆盖默认值', () {
      final n = DesignNode(
          type: DesignComponentType.heading, props: {'text': '你好'});
      expect(n.props['text'], '你好');
      expect(n.props['size'], 24.0, reason: '没覆盖的键要保留默认值');
    });

    test('id 稳定：同一节点重复访问不变（选中态靠它）', () {
      final n = DesignNode(type: DesignComponentType.text);
      final first = n.id;
      expect(n.id, first);
      expect(n.id, first);
    });

    test('clone 是深拷贝（改副本不影响原件）', () {
      final root = DesignNode(type: DesignComponentType.root, children: [
        DesignNode(type: DesignComponentType.text, props: {'text': '原来'}),
      ]);
      final copy = root.clone();
      copy.children.first.props['text'] = '改了';
      expect(root.children.first.props['text'], '原来',
          reason: '浅拷贝的话"撤销"功能会连原件一起改掉');
      expect(copy.children.first.id, root.children.first.id,
          reason: 'clone 要保留 id，否则撤销后选中态会跳到别的节点');
    });
  });

  group('模板', () {
    test('所有模板都能生成非空树，且根是 root 类型', () {
      for (final t in DesignTemplate.values) {
        final root = t.build();
        expect(root.type, DesignComponentType.root, reason: t.name);
        expect(root.label, isNotEmpty);
      }
    });

    test('空白模板没有子节点', () {
      expect(DesignTemplate.blank.build().children, isEmpty);
    });

    test('非空模板至少有 3 个子节点（否则不叫模板）', () {
      for (final t in DesignTemplate.values) {
        if (t == DesignTemplate.blank) continue;
        expect(t.build().children.length, greaterThanOrEqualTo(3),
            reason: '${t.name} 太单薄，起不到"降低空白画布成本"的作用');
      }
    });

    test('模板里的属性值合法（对齐/颜色/图标名都在白名单内）', () {
      void walk(DesignNode n) {
        for (final f in n.type.fields) {
          final v = n.props[f.key];
          switch (f.kind) {
            case DesignFieldKind.align:
              expect(kAlignOptions, contains(v),
                  reason: '${n.type.name}.${f.key} = $v 不在对齐白名单');
            case DesignFieldKind.colorSlot:
              expect(kColorSlots, contains(v),
                  reason: '${n.type.name}.${f.key} = $v 不在语义色白名单');
            case DesignFieldKind.iconName:
              expect(kIconNames, contains(v),
                  reason: '${n.type.name}.${f.key} = $v 不在图标白名单');
            case DesignFieldKind.buttonStyle:
              expect(kButtonStyles, contains(v));
            case DesignFieldKind.buttonWidth:
              expect(kButtonWidths, contains(v));
            case DesignFieldKind.imageFit:
              expect(kImageFits, contains(v));
            case DesignFieldKind.text:
            case DesignFieldKind.number:
            case DesignFieldKind.bool_:
              break;
          }
        }
        n.children.forEach(walk);
      }

      for (final t in DesignTemplate.values) {
        walk(t.build());
      }
    });
  });

  group('Scaffold 命名参数（外壳组件）', () {
    String gen(DesignTemplate t) =>
        DesignCodeGen.generate(t.build(), className: 'X');

    test('计数器模板生成 floatingActionButton', () {
      final code = gen(DesignTemplate.counter);
      expect(code.contains('floatingActionButton: FloatingActionButton('), isTrue);
      expect(code.contains('child: const Icon(Icons.add)'), isTrue);
      // 回调留空但标明接哪 —— 与按钮/列表项同一立场。
      expect(code.contains('// TODO: 接你的逻辑'), isTrue);
    });

    test('标签页模板生成 appBar + TabBar，且外面包了 DefaultTabController', () {
      final code = gen(DesignTemplate.tabs);
      expect(code.contains('appBar: AppBar('), isTrue);
      expect(code.contains('bottom: TabBar('), isTrue);
      // ⚠️ 这条是防"能编译但一跑就崩"：TabBar 没有祖先 DefaultTabController
      // 会直接抛 "No TabController for TabBar"，而且报错栈指向 Framework，
      // 用户根本看不出是生成器少写了一层。
      expect(code.contains('DefaultTabController('), isTrue);
      expect(code.contains('length: 3,'), isTrue);
      // DefaultTabController 必须在 Scaffold **外面**，反过来包是没用的。
      final dc = _indentOf(code, 'DefaultTabController(');
      final sc = _indentOf(code, 'child: Scaffold(');
      expect(dc, lessThan(sc), reason: 'DefaultTabController 得是祖先，不能塞在 Scaffold 里');
    });

    test('三个标签的文字都来自 kTabKeys（顺序不能乱）', () {
      final code = gen(DesignTemplate.tabs);
      final i1 = code.indexOf("Tab(text: '首页')");
      final i2 = code.indexOf("Tab(text: '收藏')");
      final i3 = code.indexOf("Tab(text: '设置')");
      expect(i1, greaterThan(-1));
      expect(i2, greaterThan(i1), reason: 'kTabKeys 的顺序决定生成顺序');
      expect(i3, greaterThan(i2));
    });

    test('外壳节点不出现在 Column 的 children 里', () {
      final code = gen(DesignTemplate.counter);
      // 取 `children: [` 之后的部分 —— 外壳参数都排在它前面。
      final bodyStart = code.indexOf('children: [');
      expect(bodyStart, greaterThan(-1));
      final body = code.substring(bodyStart);
      expect(body.contains('floatingActionButton:'), isFalse,
          reason: 'FAB 是 Scaffold 的参数，不该混进 body 的 Column');
      expect(body.contains('appBar:'), isFalse);
    });

    test('被放到非根节点下的外壳组件：跳过 + 留注释，而不是静默消失', () {
      // 手工造一棵"把 appBar 塞进卡片里"的树 —— 模拟用户拖错位置。
      final card = DesignNode(
        type: DesignComponentType.card,
        children: [DesignNode(type: DesignComponentType.appBar)],
      );
      final root = DesignNode(
        type: DesignComponentType.root,
        children: [card],
      );
      final code = DesignCodeGen.generate(root, className: 'X');
      expect(code.contains('只能放在页面根节点下'), isTrue,
          reason: '静默吞掉的话用户会找不到自己刚加的东西');
      // 而且不能真的生成一个 AppBar —— 那会变成卡片里横着一条灰条。
      expect(code.contains('appBar: AppBar('), isFalse);
    });

    test('没有外壳组件时，不生成任何 Scaffold 参数（老模板不受影响）', () {
      final code = gen(DesignTemplate.login);
      expect(code.contains('appBar:'), isFalse);
      expect(code.contains('floatingActionButton:'), isFalse);
      expect(code.contains('bottomNavigationBar:'), isFalse);
      expect(code.contains('DefaultTabController('), isFalse);
    });
  });

  group('代码生成 · 文件骨架', () {
    test('包含 import、类声明、build 方法、Scaffold', () {
      final code =
          DesignCodeGen.generate(DesignTemplate.login.build(), className: 'X');
      expect(code.contains("import 'package:flutter/material.dart';"), isTrue);
      expect(code.contains('class X extends StatelessWidget {'), isTrue);
      expect(code.contains('const X({super.key});'), isTrue);
      expect(code.contains('Widget build(BuildContext context) {'), isTrue);
      expect(code.contains('return Scaffold('), isTrue);
      expect(code.contains('SafeArea('), isTrue);
    });

    test('文件头明确声明"不含业务逻辑"（防用户以为按钮能用）', () {
      final code =
          DesignCodeGen.generate(DesignTemplate.login.build(), className: 'X');
      expect(code.contains('没有业务逻辑'), isTrue);
      expect(code.contains('按钮点了不会有反应'), isTrue,
          reason: '这条不是客套话 —— 缺了它用户第一次发现按钮没用会觉得被骗');
    });

    test('同输入生成同输出（生成器无隐藏状态）', () {
      final a = DesignCodeGen.generate(DesignTemplate.list.build(),
          className: 'X');
      DesignNode.resetIdSeq();
      final b = DesignCodeGen.generate(DesignTemplate.list.build(),
          className: 'X');
      expect(a, b);
    });

    test('类名与文件名同源', () {
      final t = DateTime(2026, 9, 22, 16, 3, 0);
      expect(DesignCodeGen.classNameFor(t), 'Design20260922_160300');
      expect(DesignCodeGen.fileNameFor(t), 'Design20260922_160300.dart');
    });

    test('类名月份/日期补零（9 月不能写成 Design20269_...）', () {
      expect(DesignCodeGen.classNameFor(DateTime(2026, 1, 5, 8, 7, 6)),
          'Design20260105_080706');
    });

    test('导入来的类名带上原类名（否则用户看不出它是从哪来的）', () {
      final t = DateTime(2026, 9, 22, 16, 3, 0);
      expect(DesignCodeGen.classNameForImport('LoginPage', t),
          'LoginPageDesign20260922_160300');
      expect(DesignCodeGen.fileNameForImport('LoginPage', t),
          'LoginPageDesign20260922_160300.dart');
    });

    test('原类名不是合法标识符时被收拾干净（否则生成的代码编译不过）', () {
      final t = DateTime(2026, 9, 22, 16, 3, 0);
      // `_HomePageState` → 前导下划线在类名里合法，但导入时我们已经
      // 把 State 后缀去掉了；这里只测**非法字符**与**数字开头**两种
      // 真正会生成编译不过的代码的情况。
      expect(DesignCodeGen.classNameForImport('my-page', t),
          'my_pageDesign20260922_160300');
      expect(DesignCodeGen.classNameForImport('2Col', t),
          'X2ColDesign20260922_160300',
          reason: '数字开头的标识符在 Dart 里非法');
      expect(DesignCodeGen.classNameForImport('', t),
          'ImportedDesign20260922_160300',
          reason: '空名字不能生成 `Design2026...` 前面粘一个空字符串就完事 —— '
              '那样虽然也能编译，但用户看不出这是导入来的');
      // ⚠️ 中文类名在 Dart 里其实是合法的，但我们**不**主动保留 ——
      // 它会被 `_sanitizeIdentifier` 换成下划线。这是有意的：
      // 中文标识符虽然合法，但生成的文件名（`中文设计.dart`）在
      // 不同平台/工具链上的处理不一致（git 乱码、CI 上 shell 转义），
      // 代价远大于收益。
      expect(DesignCodeGen.classNameForImport('页面', t),
          '__Design20260922_160300');
    });
  });

  group('代码生成 · 各组件', () {
    String gen(List<DesignNode> children, {String pad = '2'}) {
      final root = DesignNode(
        type: DesignComponentType.root,
        props: {'padding': 0.0, 'scroll': false},
        children: children,
      );
      return DesignCodeGen.generate(root, className: 'X');
    }

    test('标题带 fontSize 与 bold，非左对齐会包 Align', () {
      final code = gen([
        DesignNode(type: DesignComponentType.heading, props: {'text': '嗨'}),
        DesignNode(type: DesignComponentType.heading,
            props: {'text': '中间', 'align': 'center'}),
      ]);
      // ⚠️ 不能写 `const Text('嗨'` —— 生成器把参数换行排布了
      // （`const Text(\n  '嗨',`），单行断言会假红。
      // 用 `\s*` 吃掉换行，断言的是"语义"而不是"排版"。
      expect(RegExp(r"const Text\(\s*'嗨'").hasMatch(code), isTrue,
          reason: '默认无主题色，应该能加 const');
      expect(code.contains('fontSize: 24'), isTrue);
      expect(code.contains('fontWeight: FontWeight.bold'), isTrue);
      expect(code.contains('Alignment.center'), isTrue);
    });

    test('左对齐不生成多余的 Align（少一层嵌套）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.heading,
            props: {'text': '左', 'align': 'left'}),
      ]);
      expect(code.contains('Align('), isFalse,
          reason: '默认值不该生成代码 —— 每多一层 Container/Align，'
              '用户读生成物时就多一分"这层是干嘛的"的困惑');
    });

    test('三种按钮样式映射到正确的构造函数', () {
      for (final entry in {
        'filled': 'FilledButton',
        'outlined': 'OutlinedButton',
        'text': 'TextButton',
      }.entries) {
        final code = gen([
          DesignNode(type: DesignComponentType.button,
              props: {'text': 'B', 'style': entry.key, 'width': 'hug'}),
        ]);
        expect(code.contains(entry.value), isTrue,
            reason: '${entry.key} 应生成 ${entry.value}');
      }
    });

    test('全宽按钮包 SizedBox(width: double.infinity)', () {
      final code = gen([
        DesignNode(type: DesignComponentType.button, props: {'width': 'full'}),
      ]);
      expect(code.contains('width: double.infinity'), isTrue);
    });

    // ---------------- box（alpha.74 为 AnimatedContainer 加） ----------------
    test('box 生成 Container，尺寸/圆角/底色都落进参数', () {
      final code = gen([
        DesignNode(type: DesignComponentType.box, props: {
          'width': 100.0,
          'height': 200.0,
          'radius': 16.0,
          'color': 'primary',
        }),
      ]);
      expect(code.contains('Container('), isTrue);
      expect(code.contains('width: 100'), isTrue);
      expect(code.contains('height: 200'), isTrue);
      expect(code.contains('BorderRadius.circular(16)'), isTrue);
      // 色位要变成**主题色**，不能是裸 RGB —— 这是 kColorSlots 的约定
      expect(code.contains('colorScheme.primary'), isTrue);
      expect(code.contains('0xFF'), isFalse,
          reason: '设计器只存语义色位，生成时不许冒出硬编码色值');
    });

    test('box 的色位是 none 时不生成 color（继承，而不是写死一个色）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.box,
            props: {'width': 10.0, 'height': 10.0, 'color': 'none'}),
      ]);
      expect(RegExp(r'\bcolor:').hasMatch(code), isFalse,
          reason: 'none = 不生成 color 参数');
    });

    test('box 圆角为 0 时不生成 decoration（少一层嵌套）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.box,
            props: {'width': 10.0, 'height': 10.0, 'radius': 0.0}),
      ]);
      expect(code.contains('BorderRadius'), isFalse);
    });

    test('box 的子节点落成 child:（AnimatedContainer 里那个图标）', () {
      final code = gen([
        DesignNode(
          type: DesignComponentType.box,
          props: {'width': 100.0, 'height': 100.0},
          children: [
            DesignNode(type: DesignComponentType.icon, props: {'name': 'home'}),
          ],
        ),
      ]);
      expect(code.contains('child:'), isTrue);
      expect(code.contains('Icons.home'), isTrue);
    });

    test('按钮带空 onPressed（不是 null）', () {
      final code = gen([DesignNode(type: DesignComponentType.button)]);
      expect(code.contains('onPressed: () {}'), isTrue,
          reason: 'onPressed: null 会让按钮变灰（禁用态），'              '看起来像"生成坏了"。空回调至少样子是对的');
    });

    test('密码框生成 obscureText', () {
      final withObscure = gen([
        DesignNode(type: DesignComponentType.textField,
            props: {'obscure': true}),
      ]);
      final without = gen([DesignNode(type: DesignComponentType.textField)]);
      expect(withObscure.contains('obscureText: true'), isTrue);
      expect(without.contains('obscureText'), isFalse);
    });

    test('列表项副标题为空时不生成 subtitle', () {
      final code = gen([
        DesignNode(type: DesignComponentType.listTile,
            props: {'title': 'A', 'subtitle': ''}),
      ]);
      expect(code.contains('subtitle'), isFalse);
    });

    test('间距/分割线是 const（数值也是整数字面量）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.spacer, props: {'height': 16.0}),
        DesignNode(type: DesignComponentType.divider,
            props: {'thickness': 1.0}),
      ]);
      expect(code.contains('const SizedBox(height: 16)'), isTrue);
      expect(code.contains('const Divider(thickness: 1)'), isTrue);
    });

    test('小数数值不丢精度（2.5 不能变成 2）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.spacer, props: {'height': 2.5}),
      ]);
      expect(code.contains('height: 2.5'), isTrue);
    });

    test('颜色生成语义位表达式而非字面色值（切主题跟着走）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.text,
            props: {'text': 'x', 'color': 'primary'}),
      ]);
      expect(code.contains('Theme.of(context).colorScheme.primary'), isTrue);
      expect(RegExp(r'0x[fF][fF][0-9a-fA-F]{6}').hasMatch(code), isFalse,
          reason: '写死色值的话，深浅主题切换时会变成不可读的组合');
    });

    // 这条守的是一个**编译错误**级别的坑：Theme.of(context) 不是常量表达式，
    // 一旦写成 `const Text('x', style: TextStyle(color: Theme.of(context)...))`
    // 就是 "Const variables must be initialized with a constant value"。
    // 生成器自己编译不过、测试也发现不了（测的是字符串），
    // 只有用户把生成物放进项目里才会炸——所以必须在这里钉死。
    test('选了主题色时不能加 const（Theme.of 不是常量表达式）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.text,
            props: {'text': 'x', 'color': 'primary'}),
      ]);
      expect(code.contains('const Text('), isFalse,
          reason: 'const 包着 Theme.of(context) 是编译错误');
      expect(
        RegExp(r"const\s+Text\([^)]*Theme\.of").hasMatch(code),
        isFalse,
        reason: '同上：const 与 Theme.of 不能同框',
      );
    });

    test('没选颜色时加 const（纯字面量，省对象也更像手写代码）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.text,
            props: {'text': 'x', 'color': 'none'}),
      ]);
      expect(code.contains('const Text('), isTrue);
    });

    test('非法颜色位不生成 color 参数（而不是生成编译不过的代码）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.text,
            props: {'text': 'x', 'color': 'hotpink'}),
      ]);
      expect(code.contains('hotpink'), isFalse);
    });

    test('卡片内的子节点缩进正确（比卡片多一层）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.card, children: [
          DesignNode(type: DesignComponentType.text, props: {'text': '内'}),
        ]),
      ]);
      expect(code.contains('Card('), isTrue);
      expect(code.contains('Padding('), isTrue);
      expect(RegExp(r"Text\(\s*'内'").hasMatch(code), isTrue);

      // 这条才是这个用例真正要守的：卡片里那层 Text 的缩进
      // 必须**严格大于** Card 那行 —— 否则生成的代码嵌套层级看着是平的，
      // 用户读起来完全分不清谁在谁里面。
      final cardIndent = _indentOf(code, 'Card(');
      final textIndent = _indentOf(code, 'Text(');
      expect(textIndent, greaterThan(cardIndent),
          reason: '卡片内子节点的缩进必须比 Card 本身更深，'
              'Card=$cardIndent Text=$textIndent');
    });

    test('图片生成占位而非图片路径（设计期没有图片资源）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.image, props: {'label': '封面'}),
      ]);
      expect(code.contains('Icons.image_outlined'), isTrue);
      expect(RegExp(r"Text\(\s*'封面'").hasMatch(code), isTrue);
      expect(code.contains('Image.asset'), isFalse,
          reason: '硬写一个不存在的路径，用户跑起来看到"图片加载失败"的红框，'
              '比占位图更困惑');
    });

    test('图片的 fit 属性生成成注释而非参数（占位阶段它不生效）', () {
      final code = gen([
        DesignNode(type: DesignComponentType.image, props: {'fit': 'cover'}),
      ]);
      expect(code.contains('// 换成真实图片时设置 fit: BoxFit.cover'), isTrue);
      expect(RegExp(r'fit:\s*BoxFit\.cover,').hasMatch(code), isFalse,
          reason: '写成真参数会让用户以为"填了 cover 就有图了"');
    });

    test('图标名走白名单映射，未知名字退回中性图标', () {
      final ok = gen([
        DesignNode(type: DesignComponentType.icon, props: {'name': 'star'}),
      ]);
      final bad = gen([
        DesignNode(type: DesignComponentType.icon, props: {'name': '不存在'}),
      ]);
      expect(ok.contains('Icons.star_outline'), isTrue);
      expect(bad.contains('Icons.circle_outlined'), isTrue,
          reason: r'直接拼 Icons.$未知名字 会生成编译不过的代码');
    });
  });

  group('代码生成 · 未识别组件（导入时原样带回）', () {
    String genUnknown(List<DesignNode> children) {
      final root = DesignNode(
        type: DesignComponentType.root,
        props: {'padding': 0.0, 'scroll': false},
        children: children,
      );
      return DesignCodeGen.generate(root, className: 'X');
    }

    test('raw 原样吐出：缩进、注释、用户写的一切都还在', () {
      const raw = '// 第三方登录：等接了 SDK 再打开\n'
          'ThirdPartyLoginRow(\n'
          '  onTap: _onThirdParty,\n'
          ')';
      final code = genUnknown([
        DesignNode(
          type: DesignComponentType.unknown,
          props: {'raw': raw, 'sourceName': 'ThirdPartyLoginRow'},
        ),
      ]);
      // ⚠️ 逐行断言而不是整段 contains：整段断言在"缩进被重排过"
      // 的时候照样通过（生成器会整体缩进），那正是最需要发现的问题。
      expect(code.contains('ThirdPartyLoginRow('), isTrue);
      expect(code.contains('onTap: _onThirdParty,'), isTrue);
      expect(code.contains('// 第三方登录：等接了 SDK 再打开'), isTrue,
          reason: '注释在 AST 里是 trivia、不挂在节点上；'
              '我们存的是**源码切片**，所以注释必须还在 —— '
              '这正是当初决定不用 AST 重新打印的原因');
    });

    test('自动补一个逗号（不补的话整个 .dart 编译不过）', () {
      final code = genUnknown([
        DesignNode(
          type: DesignComponentType.unknown,
          props: {'raw': 'BlocBuilder<X, Y>(\n  builder: _b,\n)'},
        ),
      ]);
      // 它作为 `children: [...]` 的元素必须以逗号结尾。
      // 源码切片本身以 `)` 收尾，不补的话是 `)\n]` —— 语法错。
      expect(RegExp(r'\)\s*,\s*\n\s*\]').hasMatch(code), isTrue,
          reason: 'unknown 节点后面必须跟着逗号再接列表的收尾括号');
    });

    test('raw 已经以逗号结尾时不重复补（`),,` 也是语法错）', () {
      final code = genUnknown([
        DesignNode(
          type: DesignComponentType.unknown,
          props: {'raw': 'MyChart(), // 数据源'},
        ),
      ]);
      expect(code.contains(',,'), isFalse);
      expect(code.contains('// 数据源'), isTrue,
          reason: '行尾注释在 AST 里挂在**下一个 token** 上，'
              '但我们的切片是纯文本扫描 —— 所以它跟逗号一起被带走了');
    });

    test('空 raw 生成一行注释而不是空字符串', () {
      final code = genUnknown([
        DesignNode(
          type: DesignComponentType.unknown,
          props: {'raw': '', 'sourceName': '未识别组件'},
        ),
      ]);
      expect(code.contains('// （未识别组件，已跳过）'), isTrue);
      // 空字符串会在 children 里留下一个空白行，用户看到的是
      // "这里怎么空了一块"，比明说"跳过了"更让人困惑。
      expect(RegExp(r'children: \[\s*\n\s*\n').hasMatch(code), isFalse);
    });

    test('只有空白的 raw 也走"已跳过"分支（trim 之后为空）', () {
      final code = genUnknown([
        DesignNode(
          type: DesignComponentType.unknown,
          props: {'raw': '   \n  \n'},
        ),
      ]);
      expect(code.contains('// （未识别组件，已跳过）'), isTrue);
    });

    test('补逗号不会破坏多行 raw 的缩进', () {
      final code = genUnknown([
        DesignNode(
          type: DesignComponentType.unknown,
          props: {'raw': 'Wrap(\n  spacing: 8,\n  children: _tags,\n)'},
        ),
      ]);
      // 最后一行是 `)`，补完是 `),` —— 断言它们仍在**同一行**。
      // 写成先换行再加逗号的话，`Wrap(\n  ...\n)\n,` 在 Dart 里
      // 其实也合法，但读起来莫名其妙，而且会和"原样带回"的承诺
      // 出现肉眼可见的偏差。
      expect(RegExp(r'\)\s*,').hasMatch(code), isTrue);
      expect(RegExp(r'\)\n\s*,').hasMatch(code), isFalse,
          reason: '逗号必须跟右括号同行');
    });

    test('占位节点的子节点不参与生成（raw 已经包含它们了）', () {
      final code = genUnknown([
        DesignNode(
          type: DesignComponentType.unknown,
          props: {'raw': 'BlocBuilder(\n  builder: _b,\n)'},
          children: [
            DesignNode(type: DesignComponentType.text, props: {'text': '不该出现'}),
          ],
        ),
      ]);
      expect(code.contains('不该出现'), isFalse,
          reason: 'raw 整段吐回去，再吐一遍子节点就是把用户的内容'
              '在生成物里**写了两遍**');
    });
  });

  group('代码生成 · 字符串转义（用户输入会进来）', () {
    String gen1(Map<String, Object?> props) => DesignCodeGen.generate(
          DesignNode(type: DesignComponentType.root, props: {'padding': 0.0},
              children: [
                DesignNode(type: DesignComponentType.text, props: props),
              ]),
          className: 'X',
        );

    test('单引号被转义（否则字符串提前结束、语法错）', () {
      final code = gen1({'text': "it's"});
      expect(code.contains(r"it\'s"), isTrue);
      expect(code.contains("'it's'"), isFalse);
    });

    test(r'美元符号被转义（否则被当成插值表达式）', () {
      final code = gen1({'text': r'价格 $100'});
      expect(code.contains(r'\$100'), isTrue,
          reason: r'不转义的话 $100 会被 Dart 当成变量插值 → 编译不过');
    });

    test('反斜杠被转义', () {
      final code = gen1({'text': r'C:\path'});
      expect(code.contains(r'C:\\path'), isTrue);
    });

    test('换行被转成 \\n 而不是真换行（否则字符串跨行语法错）', () {
      final code = gen1({'text': '第一行\n第二行'});
      expect(code.contains(r'第一行\n第二行'), isTrue);
    });

    test('中文与 emoji 原样保留', () {
      final code = gen1({'text': '你好 🚀'});
      expect(code.contains('你好 🚀'), isTrue);
    });
  });

  group('代码生成 · 合法 Dart 结构', () {
    test('括号配平（各模板都验一遍）', () {
      for (final t in DesignTemplate.values) {
        final code =
            DesignCodeGen.generate(t.build(), className: 'X');
        var depth = 0;
        // 跳过字符串字面量，否则转义过的引号会打乱计数
        var inStr = false;
        for (var i = 0; i < code.length; i++) {
          final ch = code[i];
          if (ch == r'\') {
            i++;
            continue;
          }
          if (ch == "'") {
            inStr = !inStr;
            continue;
          }
          if (inStr) continue;
          if (ch == '(' || ch == '[' || ch == '{') depth++;
          if (ch == ')' || ch == ']' || ch == '}') depth--;
          expect(depth, greaterThanOrEqualTo(0),
              reason: '${t.name}：第 $i 个字符处闭括号多于开括号');
        }
        expect(depth, 0, reason: '${t.name}：括号不配平，生成的代码编译不过');
      }
    });

    test('生成的每一行都不含制表符（缩进统一空格）', () {
      final code = DesignCodeGen.generate(DesignTemplate.detail.build(),
          className: 'X');
      expect(code.contains('\t'), isFalse);
    });

    test('生成物是**语法正确**的 Dart（不只括号配平）', () async {
      // ⚠️ 这条是真机交付前最后的防线，别删。
      //
      // 上面那条"括号配平"只数括号，查不出 `),;` 这种**配平但非法**的写法
      // ——`( )` 数量对得上，可是 Dart 解析器直接报 "Expected to find ';'"。
      // 这个 bug 真的发生过：给 Scaffold 加命名参数时，body 的收尾括号和
      // 语句分号撞在一起，生成了 `),;`，而括号配平测试全绿放行。
      //
      // 所以这里把每个模板的生成物写到磁盘，交给 `dart format` 真解析一遍。
      // 能 parse 才说明用户拿到的是能编译的代码。
      final dir = Directory.systemTemp.createTempSync('foa_gen_');
      addTearDown(() => dir.deleteSync(recursive: true));

      // 找 dart 二进制。不写死路径：不同环境下 Flutter SDK 位置不同
      // （本地 /opt/flutter、CI 在别处），靠 `FLUTTER_ROOT` 是唯一稳的办法。
      final candidates = <String>[
        if (Platform.environment['FLUTTER_ROOT'] != null)
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart',
        '/opt/flutter/bin/cache/dart-sdk/bin/dart',
      ];
      String? dartPath;
      for (final c in candidates) {
        if (File(c).existsSync()) {
          dartPath = c;
          break;
        }
      }
      if (dartPath == null) {
        // 拿不到 dart 二进制时跳过而不是误报失败 —— 这条测试的价值在于
        // 本地/CI 真跑一遍，不在于让环境不合适的人红一片。
        markTestSkipped('找不到 dart-sdk（试过 $candidates），跳过语法校验');
        return;
      }

      for (final t in DesignTemplate.values) {
        DesignNode.resetIdSeq();
        final code =
            DesignCodeGen.generate(t.build(), className: 'T_${t.name}');
        final f = File('${dir.path}/${t.name}.dart')
          ..writeAsStringSync(code);
        final r = await Process.run(
            dartPath, ['format', '--output=none', f.path]);
        expect(r.exitCode, 0,
            reason: '${t.name} 模板生成的代码语法错误：\n${r.stderr}');
      }
    });
  });
}
