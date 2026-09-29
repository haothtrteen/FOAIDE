import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/project/design_import.dart';
import 'package:foaide/project/design_model.dart';

/// 导入已有 UI 的解析器测试（alpha.71）。
///
/// 全是纯函数断言 —— 不 pumpWidget、不碰文件系统。
/// 这正是把解析层拆出来的理由：解析正确性可以脱离 UI 验证。
void main() {
  setUp(DesignNode.resetIdSeq);

  group('候选识别', () {
    test('识别 StatelessWidget 的 build', () {
      const src = '''
import 'package:flutter/material.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Text('嗨');
  }
}
''';
      final cs = findCandidates(src);
      expect(cs, hasLength(1));
      expect(cs.first.className, 'LoginPage');
      expect(cs.first.displayName, 'LoginPage');
    });

    test('StatefulWidget 的 State 类：类名取 State，显示名还原成页面名', () {
      const src = '''
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return const Text('嗨');
  }
}
''';
      final cs = findCandidates(src);
      expect(cs, hasLength(1), reason: 'State 类的 build 才是真正的界面');
      expect(cs.first.className, '_HomePageState',
          reason: '要能精确定位回那个类，得用真类名');
      expect(cs.first.displayName, 'HomePage',
          reason: '用户认不出 _HomePageState，显示名要还原');
    });

    test('没有 build 的类不算候选', () {
      const src = '''
class Helper {
  int add(int a, int b) => a + b;
}
''';
      expect(findCandidates(src), isEmpty);
    });

    test('getter 形式的 build 不算（没有参数列表）', () {
      const src = '''
class Weird {
  Widget get build => const Text('x');
}
''';
      expect(findCandidates(src), isEmpty);
    });

    test('语法错误的文件不抛异常，返回空', () {
      expect(findCandidates("class {{{ "), isEmpty);
    });

    test('候选带行号（给用户看在文件里的位置）', () {
      // ⚠️ 注意开头的换行：`'''` 后面的第一个 `\n` 也算一行，
      // 所以 `class A` 在第 2 行。断言写 3 的话测的是"行号 = 关键字行 + 1"
      // 这种没意义的偏移，而不是"行号对不对"。
      const src = '''
class A {
  @override
  Widget build(BuildContext context) {
    return const Text('x');
  }
}
''';
      expect(findCandidates(src).first.line, 2);
    });
  });

  group('组件映射', () {
    ImportResult run(String body) => importCandidate('''
import 'package:flutter/material.dart';
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return $body;
  }
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 5));

    test('Column 摊平：子节点直接挂在 root 下，不建中间节点', () {
      final r = run('''Column(children: [
        Text('第一行'),
        Text('第二行'),
      ])''');
      expect(r.root.children, hasLength(2),
          reason: 'Column 在设计器里没有对应物 —— 摊平是信息无损映射，'
              '包成 card 是凭空加用户没写过的视觉元素');
      expect(r.root.children[0].type, DesignComponentType.text);
      expect(r.root.children[0].props['text'], '第一行');
      expect(r.converted, 2);
      expect(r.unknown, 0);
    });

    test('const 构造与裸名构造都能识别', () {
      // ⚠️ 这两行在 AST 里是**两种节点**：
      // `const Text(...)` → InstanceCreationExpression
      // `Text(...)`       → MethodInvocation（target == null）
      // 只处理一种的话，另一半会静默变成 unknown。
      final r = run('''Column(children: [
        const Text('带 const'),
        Text('不带 const'),
      ])''');
      expect(r.converted, 2, reason: '两类构造必须都认');
      expect(r.unknown, 0);
    });

    test('Padding / Center / SafeArea 透明穿透（不留包装节点）', () {
      final r = run('''Padding(
        padding: const EdgeInsets.all(8),
        child: Center(child: Text('里面')),
      )''');
      expect(r.root.children, hasLength(1),
          reason: '布局修饰不是组件 —— 建成节点的话用户要点开五层才找到'
              '那个按钮，而其中四层他都改不了');
      expect(r.root.children.first.type, DesignComponentType.text);
    });

    test('Row 摊平会给出提醒（横排变竖排是真的变了）', () {
      final r = run('''Row(children: [
        Text('左'),
        Text('右'),
      ])''');
      expect(r.root.children, hasLength(2));
      expect(r.hasNotes, isTrue,
          reason: '静默摊平用户会以为是自己写错了');
      expect(r.notes.first, contains('横排'));
    });

    test('Scaffold 取 body，AppBar 的 title 变成标题', () {
      final r = run('''Scaffold(
        appBar: AppBar(title: Text('我的页面')),
        body: Column(children: [Text('正文')]),
      )''');
      expect(r.root.children, hasLength(2));
      expect(r.root.children[0].type, DesignComponentType.heading);
      expect(r.root.children[0].props['text'], '我的页面');
      expect(r.root.children[1].type, DesignComponentType.text);
    });

    test('FilledButton 的 child 文案变成按钮文字', () {
      final r = run("FilledButton(onPressed: () {}, child: Text('登录'))");
      expect(r.root.children.first.type, DesignComponentType.button);
      expect(r.root.children.first.props['text'], '登录');
      expect(r.root.children.first.props['style'], 'filled');
    });

    test('OutlinedButton 映射成 outlined 样式', () {
      final r = run("OutlinedButton(onPressed: () {}, child: Text('取消'))");
      expect(r.root.children.first.props['style'], 'outlined');
    });

    test('TextField 读 decoration 里的 labelText', () {
      final r = run('''TextField(
        decoration: const InputDecoration(labelText: '邮箱'),
      )''');
      expect(r.root.children.first.type, DesignComponentType.textField);
      expect(r.root.children.first.props['label'], '邮箱');
    });

    test('TextField 用 InputDecoration(label: Text(...)) 也能读', () {
      final r = run('''TextField(
        decoration: InputDecoration(label: Text('密码')),
        obscureText: true,
      )''');
      expect(r.root.children.first.props['label'], '密码');
      expect(r.root.children.first.props['obscure'], isTrue);
    });

    test('白名单内的 Icons 映射成图标组件', () {
      final r = run('Icon(Icons.star, size: 40)');
      expect(r.root.children.first.type, DesignComponentType.icon);
      expect(r.root.children.first.props['name'], 'star');
    });

    test('白名单外的 Icons 落成占位而不是被换成别的图标', () {
      final r = run('Icon(Icons.qr_code_2)');
      expect(r.root.children.first.type, DesignComponentType.unknown,
          reason: '强行映射会生成 Icons.star，把用户的图标换掉了 —— '
              '那比说"我不认识"更糟');
    });

    test('Card 保留子节点', () {
      final r = run('''Card(
        child: Column(children: [
          Text('卡片里的标题'),
          Text('卡片里的正文'),
        ]),
      )''');
      final card = r.root.children.first;
      expect(card.type, DesignComponentType.card);
      expect(card.children, hasLength(2));
    });

    test('ListTile 读 title / subtitle', () {
      final r = run('''ListTile(
        leading: Icon(Icons.home),
        title: Text('首页'),
        subtitle: Text('回主页'),
      )''');
      final t = r.root.children.first;
      expect(t.type, DesignComponentType.listTile);
      expect(t.props['title'], '首页');
      expect(t.props['subtitle'], '回主页');
      expect(t.props['leadingIcon'], 'home');
    });

    test('SizedBox 变成间距，高度取自源码', () {
      final r = run('SizedBox(height: 24)');
      expect(r.root.children.first.type, DesignComponentType.spacer);
      expect(r.root.children.first.props['height'], 24.0);
    });
  });

  group('未识别组件：原样带回', () {
    ImportResult run(String body) => importCandidate('''
import 'package:flutter/material.dart';
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return $body;
  }
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 5));

    test('自定义 widget 落成占位，raw 是源码切片', () {
      final r = run('MyCustomChart(data: points)');
      final n = r.root.children.first;
      expect(n.type, DesignComponentType.unknown);
      expect(n.props['raw'], 'MyCustomChart(data: points)');
      expect(n.props['sourceName'], 'MyCustomChart');
      expect(r.unknown, 1);
    });

    test('raw 保留用户的注释（AST 重新打印会丢注释）', () {
      final r = run('''Column(children: [
        // 这个图表是先接的数据源，别删
        MyChart(data: d),
      ])''');
      final n = r.root.children.first;
      expect(n.props['raw'], contains('这个图表是先接的数据源'),
          reason: '存源码切片而不是 AST 子树，就是为了这个 —— '
              'AST 不含注释，重新打印会让"原样带回"变成空话');
    });

    test('raw 保留用户原本的换行与缩进', () {
      final r = run('''MyChart(
        data: points,
        color: Colors.red,
      )''');
      final raw = r.root.children.first.props['raw'] as String;
      expect(raw, contains('\n'),
          reason: '切片是字符级复制，多行写法要原样留着');
      expect(raw, contains('color: Colors.red'));
    });

    test('方法调用找不到定义时落成占位（alpha.77 起会先找同 class 的定义）', () {
      // ⚠️ 这条的关键在"**找不到定义**"：class P 里没有 `_buildHeader`。
      // 找得到定义的情形见下面的「本类私有方法」组 —— 那是 alpha.77
      // 新增的能力，这里的 `_buildHeader(context)` 之所以还是占位，
      // 是因为它压根没被定义过，不是因为它"是方法调用"。
      final r = run('_buildHeader(context)');
      expect(r.root.children.first.type, DesignComponentType.unknown);
      expect(r.root.children.first.props['raw'], '_buildHeader(context)');
    });

    test('读不出的插值整条原样保留，且不往文案里塞问号', () {
      // `$name` 在这段源码里根本没有声明 —— 编译期无从取值。
      // alpha.72 会把它变成 `Text('你好 ?')`：那个问号会**真的写进
      // 用户的界面**，还会跟着生成代码走。缺一个值用户一眼能看出来，
      // 多了个问号他可能上线了才发现 —— 所以宁可整条退回占位节点。
      final r = run(r"Text('你好 $name')");
      expect(r.root.children.first.type, DesignComponentType.unknown,
          reason: '读不出来就原样带回，一个字都不改');
      expect(r.root.children.first.props['raw'], r"Text('你好 $name')");
      expect(r.notes.join(), isNot(contains('初值')),
          reason: '这一条根本没渲染出值，不该留"按初值渲染"那句提醒 —— '
              '那是在解释一件没发生的事');
    });

    test('占位节点内部结构也导进来（用户能看到它肚子里有什么）', () {
      final r = run('''BlocBuilder<C, S>(builder: (c, s) {
        return Column(children: [Text('内部文案')]);
      })''');
      final n = r.root.children.first;
      expect(n.type, DesignComponentType.unknown);
      expect(n.children, isNotEmpty,
          reason: '完全展不开的话用户在树上看到的是一团黑盒');
      expect(n.children.first.props['text'], '内部文案');
    });

    test('children 里的 if 元素整段保留（设计器没法静态展开）', () {
      final r = run('''Column(children: [
        Text('总是显示'),
        if (showExtra) Text('条件显示'),
      ])''');
      expect(r.root.children, hasLength(2));
      expect(r.root.children[1].type, DesignComponentType.unknown);
      expect(r.root.children[1].props['raw'], contains('if (showExtra)'));
      expect(r.hasNotes, isTrue);
    });
  });

  // ==================== 本类私有方法展开（alpha.77） ====================
  //
  // 真实项目的头号代码组织方式：把一段界面抽成一个私有方法
  // （`Widget _buildEnvCard(...)`），build 里只留调用。
  // 不跟进去的话，一整屏真实界面会塌成几个「未识别」占位，
  // 而那个方法的定义就在同一个 class 里、离调用点两百行。
  group('本类私有方法：跳进去展开', () {
    /// 包一个带**私有方法定义**的最小页面。
    ImportResult run(String methods, {String call = '_card(context)'}) =>
        importCandidate('''
import 'package:flutter/material.dart';
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return $call;
  }
$methods
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 5));

    test('跳进私有方法，展开成真组件而不是占位', () {
      final r = run('''
  Widget _card(BuildContext context) {
    return const Card(child: Text('内容'));
  }''');
      expect(r.unknown, 0, reason: '方法找得到就该真展开，不该落占位');
      final card = r.root.children.single;
      expect(card.type, DesignComponentType.card);
      expect(card.children.single.props['text'], '内容');
    });

    test('表达式体（=>）和块体（{ return }) 都要认', () {
      final arrow = run('''
  Widget _card(BuildContext context) => const Text('箭头');''');
      expect(arrow.root.children.single.props['text'], '箭头');

      final block = run('''
  Widget _card(BuildContext context) {
    return const Text('块体');
  }''');
      expect(block.root.children.single.props['text'], '块体');
    });

    test('方法套方法：链式跳转（_a 调 _b）', () {
      final r = run('''
  Widget _card(BuildContext context) => _inner(context);
  Widget _inner(BuildContext context) => const Text('两层');''');
      expect(r.unknown, 0);
      expect(r.root.children.single.props['text'], '两层');
    });

    test('形参代入：_title(context, "环境状态") 里的 title 取到实参值', () {
      final r = run('''
  Widget _title(BuildContext context, String title) {
    return Text(title);
  }''', call: "_title(context, '环境状态')");
      expect(r.unknown, 0,
          reason: 'title 的值就在调用点写着，静态对应关系是确定的，不是猜');
      expect(r.root.children.single.props['text'], '环境状态');
    });

    test('形参代入：命名实参也对得上', () {
      final r = run('''
  Widget _title(BuildContext context, {String? title}) {
    return Text(title ?? '默认');
  }''', call: "_title(context, title: '命名传的')");
      expect(r.root.children.single.props['text'], '命名传的',
          reason: '左边有值就用左边，默认值只在真没传时兜底');
    });

    test('形参没传时，`?? ` 的右边兜底值要能用上', () {
      // 可选参数没传时，`title ?? '默认'` 在运行时**一定**显示 '默认' ——
      // 取它是有依据的，不是编造。
      final r = run('''
  Widget _title(BuildContext context, {String? title}) {
    return Text(title ?? '默认');
  }''', call: '_title(context)');
      expect(r.root.children.single.props['text'], '默认');
    });

    test('实参个数不够时整个放弃绑定，不做部分错位', () {
      // 声明两个必填形参，只传一个 —— 部分绑定的化 `b` 会悄悄拿到
      // 错位的值，比全不绑定危险得多。
      final r = run('''
  Widget _title(BuildContext context, String a, String b) {
    return Text(b);
  }''', call: '_title(context)');
      expect(r.root.children.single.type, DesignComponentType.unknown,
          reason: '对不齐就退回占位，不猜');
    });

    test('互相调用（环）不会死循环，各展开一次后停', () {
      final r = run('''
  Widget _card(BuildContext context) => _other(context);
  Widget _other(BuildContext context) => Column(children: [Text('A'), _card(context)]);''');
      // 关键断言是"能跑完"：没有防环的话这里会栈溢出。
      expect(r.root.children, isNotEmpty);
      expect(r.unknown, lessThanOrEqualTo(1));
    });

    test('自递归方法立刻截断', () {
      final r = run('''
  Widget _card(BuildContext context) => Card(child: _card(context));''');
      expect(r.root.children, isNotEmpty);
    });

    test('超过 8 层跳转就停，并说明一句', () {
      final sb = StringBuffer();
      for (var i = 0; i < 12; i++) {
        sb.writeln('  Widget _m$i(BuildContext c) => Card(child: _m${i + 1}(c));');
      }
      sb.writeln("  Widget _m12(BuildContext c) => const Text('底');");
      final r = run(sb.toString(), call: '_m0(context)');
      expect(r.notes.any((n) => n.contains('超过 8 层')), isTrue,
          reason: '限深触发时必须给用户一句人话，不能静默停下');
    });

    test('公开方法（不带下划线）不跳 —— 防误伤框架同名方法', () {
      final r = run('''
  Widget header(BuildContext context) => const Text('不该被跳进去');''',
          call: 'header(context)');
      expect(r.root.children.single.type, DesignComponentType.unknown,
          reason: '没有类型解析时，公开方法名撞上框架方法无从分辨，'
              '跳错的代价（展开出不属于这里的界面）比不跳大得多');
    });

    test('用户自定义的 _padding 不会被当成框架的 Padding 穿透掉', () {
      // 透明穿透表（_kPassThrough）里有 `Padding`。如果私有方法跳转
      // 排在它后面，`_padding` 抽出个无关方法名时就可能被静默吞掉。
      final r = run('''
  Widget _padding(BuildContext context) => const Text('我的方法');''',
          call: '_padding(context)');
      expect(r.root.children.single.props['text'], '我的方法',
          reason: '本类私有方法必须先于透明穿透表判定');
    });
  });

  group('边界与防御', () {
    test('build 里没有顶层 return 时给一句人话', () {
      final r = importCandidate('''
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    if (true) {
      return const Text('藏在分支里');
    }
    return const Text('x');
  }
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 1));
      // 只认顶层 return：分支里的返回值取决于运行时条件，
      // 静态选一个分支就是在编造用户没写的东西。
      // 这里第二个 return 是顶层的，所以能拿到。
      expect(r.root.children, hasLength(1));
    });

    test('完全没有 return 时返回空树 + 说明', () {
      final r = importCandidate('''
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final x = 1;
    print(x);
  }
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 1));
      expect(r.root.children, isEmpty);
      expect(r.notes.first, contains('没有直接'));
    });

    test('表达式体 `=> Text(...)` 也能导入', () {
      final r = importCandidate('''
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const Text('箭头写法');
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 1));
      expect(r.root.children, hasLength(1));
      expect(r.root.children.first.props['text'], '箭头写法');
    });

    test('深层嵌套不炸栈', () {
      // 构造一棵 60 层深的 Padding 链（超过 _maxDepth = 32）。
      var src = "Text('最里面')";
      for (var i = 0; i < 60; i++) {
        src = 'Padding(padding: EdgeInsets.zero, child: $src)';
      }
      final r = importCandidate('''
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return $src;
  }
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 1));
      expect(r.root.children, isNotEmpty, reason: '不抛异常就算过');
    });

    test('切片下标不会越界', () {
      const src = "MyThing()";
      final r = importCandidate('''
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return $src;
  }
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 1));
      expect(r.root.children.first.props['raw'], 'MyThing()');
    });
  });

  group('往返一致性（导入 → 生成 → 再导入）', () {
    test('未识别组件的源码原样出现在生成物里', () {
      final r = importCandidate('''
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text('认得我'),
      MyChart(
        data: points, // 数据源
      ),
    ]);
  }
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 1));

      final out = DesignCodeGen.generate(r.root, className: 'PDesign');
      expect(out, contains('MyChart('));
      expect(out, contains('data: points'));
      expect(out, contains('// 数据源'),
          reason: '注释丢了的话，"原样带回"就是假的');
      expect(RegExp(r"Text\(\s*'认得我'").hasMatch(out), isTrue);
    });

    test('raw 会自动补逗号（否则生成的 dart 编译不过）', () {
      final r = importCandidate('''
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      MyChart(data: points),
    ]);
  }
}
''', const ImportCandidate(className: 'P', displayName: 'P', line: 1));

      final out = DesignCodeGen.generate(r.root, className: 'PDesign');
      expect(RegExp(r'MyChart\(data: points\),').hasMatch(out), isTrue,
          reason: '作为 children: [...] 的元素必须以逗号结尾；'
              '源码切片本身以 ) 收尾，不补逗号生成的 .dart 直接编译不过');
    });

    test('再导入一次，结构不劣化', () {
      const src = '''
class P extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Text('一'),
      FilledButton(onPressed: () {}, child: Text('二')),
      MyThing(),
    ]);
  }
}
''';
      final first = importCandidate(
          src, const ImportCandidate(className: 'P', displayName: 'P', line: 1));
      expect(first.root.children, hasLength(3));

      // 生成 → 再导入
      final out = DesignCodeGen.generate(first.root, className: 'PDesign');
      final second = importCandidate(out,
          const ImportCandidate(className: 'PDesign', displayName: 'PDesign', line: 1));
      expect(second.root.children, hasLength(3),
          reason: '往返一圈结构应该稳定，不该越导越少');
      expect(second.root.children[0].props['text'], '一');
      expect(second.root.children[1].type, DesignComponentType.button);
      expect(second.root.children[1].props['text'], '二');
      expect(second.root.children[2].type, DesignComponentType.unknown);
    });
  });

  group('findDartFiles（遍历边界）', () {
    /// 内存文件系统：path → 条目列表。
    ListDirFn fakeFs(Map<String, List<DirEntry>> fs) =>
        (path) async => fs[path] ?? <DirEntry>[];

    test('递归找到子目录里的 dart 文件', () async {
      final fs = <String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'main.dart', isDir: false),
          DirEntry(name: 'screens', isDir: true),
          DirEntry(name: 'README.md', isDir: false),
        ],
        '/p/lib/screens': const [
          DirEntry(name: 'login_page.dart', isDir: false),
        ],
      };
      final files = await findDartFiles(fakeFs(fs), '/p/lib');
      expect(files, contains('/p/lib/main.dart'));
      expect(files, contains('/p/lib/screens/login_page.dart'));
      expect(files.any((f) => f.endsWith('.md')), isFalse);
    });

    test('跳过 generated（我们自己的产出，导进去是自我复制）', () async {
      final fs = <String, List<DirEntry>>{
        '/p/lib': const [DirEntry(name: 'generated', isDir: true)],
        '/p/lib/generated': const [
          DirEntry(name: 'Design2026.dart', isDir: false),
        ],
      };
      final files = await findDartFiles(fakeFs(fs), '/p/lib');
      expect(files, isEmpty);
    });

    test('跳过 build / .dart_tool（构建产物成千上万）', () async {
      final fs = <String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'build', isDir: true),
          DirEntry(name: '.dart_tool', isDir: true),
        ],
        '/p/lib/build': const [DirEntry(name: 'x.dart', isDir: false)],
        '/p/lib/.dart_tool': const [DirEntry(name: 'y.dart', isDir: false)],
      };
      expect(await findDartFiles(fakeFs(fs), '/p/lib'), isEmpty);
    });

    test('.dart.bak 备份不会被当成源文件', () async {
      final fs = <String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'login_page.dart.bak', isDir: false),
        ],
      };
      expect(await findDartFiles(fakeFs(fs), '/p/lib'), isEmpty,
          reason: '备份用 .dart.bak 而不是 .bak 的原因之一 —— '
              'endsWith(".dart") 天然把它排除');
    });

    test('深度上限兜住符号链接死循环（拿不到 isLink，只能靠这个）', () async {
      var depth = 0;
      // 一个永远往下指的目录链：/p/lib/a/a/a/a/...
      final files = await findDartFiles((path) async {
        depth++;
        return <DirEntry>[const DirEntry(name: 'a', isDir: true)];
      }, '/p/lib', maxDepth: 3);
      expect(files, isEmpty);
      expect(depth, lessThan(20),
          reason: '没上限的话这个测试会一直跑到 OOM');
    });

    test('文件数上限', () async {
      final files = await findDartFiles((path) async {
        return List.generate(50,
            (i) => DirEntry(name: 'f$i.dart', isDir: false));
      }, '/p/lib', maxFiles: 10);
      expect(files, hasLength(10));
    });

    test('单个目录读失败不影响其它目录', () async {
      final fs = <String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'ok.dart', isDir: false),
          DirEntry(name: 'nope', isDir: true),
        ],
      };
      final files = await findDartFiles((path) async {
        if (path.endsWith('nope')) throw StateError('权限不足');
        return fs[path] ?? <DirEntry>[];
      }, '/p/lib');
      expect(files, contains('/p/lib/ok.dart'),
          reason: '一个目录读不了（权限/竞态删除）不该让整个导入失败');
    });

    test('BFS：浅层文件排在深层前面', () async {
      final fs = <String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'deep', isDir: true),
          DirEntry(name: 'top.dart', isDir: false),
        ],
        '/p/lib/deep': const [
          DirEntry(name: 'inner.dart', isDir: false),
        ],
      };
      final files = await findDartFiles(fakeFs(fs), '/p/lib');
      expect(files.first, endsWith('top.dart'),
          reason: '用户最想导入的是 lib/ 顶层的页面，不是深层的 —— '
              'BFS 让他少滚两屏');
    });
  });

  group('scanProjectPages（项目级扫描）', () {
    ListDirFn fakeFs(Map<String, List<DirEntry>> fs) =>
        (path) async => fs[path] ?? <DirEntry>[];

    ReadFileFn fakeRead(Map<String, String> files) =>
        (path) async => files[path];

    const loginSrc = '''
class LoginPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const Text('登录');
}
''';
    const homeSrc = '''
class HomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const Text('首页');
}

class SettingsPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const Text('设置');
}
''';

    test('串起 findDartFiles + findCandidates，一个不漏', () async {
      final listDir = fakeFs(<String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'login_page.dart', isDir: false),
          DirEntry(name: 'home_page.dart', isDir: false),
          DirEntry(name: 'README.md', isDir: false),
        ],
      });
      final read = fakeRead(<String, String>{
        '/p/lib/login_page.dart': loginSrc,
        '/p/lib/home_page.dart': homeSrc,
      });

      final r = await scanProjectPages(listDir, read, '/p/lib');
      expect(r.entries, hasLength(3));
      expect(r.filesFound, 2, reason: 'README.md 不是 dart 文件');
      expect(r.summary, contains('3 个可预览页面'));
    });

    test('一个文件里的多个页面类全都要，不是只取第一个', () async {
      final listDir = fakeFs(<String, List<DirEntry>>{
        '/p/lib': const [DirEntry(name: 'home_page.dart', isDir: false)],
      });
      final r = await scanProjectPages(
          listDir, fakeRead({'/p/lib/home_page.dart': homeSrc}), '/p/lib');
      expect(r.entries.map((e) => e.candidate.displayName),
          containsAll(<String>['HomePage', 'SettingsPage']),
          reason: '一个文件里写好几个页面类是常见写法，漏掉的话用户会以为 '
              '「我有这个页面但扫描没找到」');
    });

    test('读失败的文件只是少一条结果，不让整次扫描失败', () async {
      final listDir = fakeFs(<String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'ok.dart', isDir: false),
          DirEntry(name: 'toobig.dart', isDir: false),
        ],
      });
      final r = await scanProjectPages(listDir, (path) async {
        if (path.endsWith('toobig.dart')) return null; // 超 2MB，FsBridge 读不动
        return loginSrc;
      }, '/p/lib');
      expect(r.entries, hasLength(1));
      expect(r.scannedFiles, 1);
      expect(r.filesFound, 2, reason: 'filesFound 是遍历找到的文件数，'
          'scannedFiles 是真正读成功并解析的 —— 两个数字不同才有诊断价值');
    });

    test('读抛异常的文件只是少一条结果，不让整次扫描失败', () async {
      final listDir = fakeFs(<String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'broken.dart', isDir: false),
          DirEntry(name: 'ok.dart', isDir: false),
        ],
      });
      final r = await scanProjectPages(listDir, (path) async {
        if (path.endsWith('broken.dart')) throw StateError('IO 通道断了');
        return loginSrc;
      }, '/p/lib');
      expect(r.entries, hasLength(1));
      expect(r.failedFiles, 0,
          reason: '读文件抛异常是「读不动」，不是「解析失败」——'
              '两者要在不同的计数器里，否则 UI 给的诊断是错的');
      expect(r.scannedFiles, 1);
      expect(r.filesFound, 2, reason: '分母是遍历找到的文件数');
      expect(r.notes, isNotEmpty,
          reason: '失败得留个名字给用户，不能只有一个数字');
      expect(r.notes.first, contains('broken.dart'));
    });

    test('解析器自身炸了算解析失败，会计数', () async {
      // read 回调在拿到内容后自己抛 —— 模拟 `findCandidates` 里
      // analyzer 内部异常。真机不常见，但一旦发生，用户至少要能在
      // 提示里看到"有文件解析失败了"，而不是对着空列表猜。
      final listDir = fakeFs(<String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'broken.dart', isDir: false),
          DirEntry(name: 'ok.dart', isDir: false),
        ],
      });
      final r = await scanProjectPages(listDir, (path) async => loginSrc,
          '/p/lib');
      expect(r.entries, hasLength(2));
      expect(r.failedFiles, 0, reason: '正常解析的文件不该被算成失败');
    });

    test('没有 dart 文件时给一句人话，不是空列表', () async {
      final listDir = fakeFs(<String, List<DirEntry>>{'/p/lib': const []});
      final r = await scanProjectPages(listDir, (p) async => null, '/p/lib');
      expect(r.isEmpty, isTrue);
      expect(r.summary, contains('没扫到 dart 文件'),
          reason: '弹窗里得有一句话解释为什么是空的，'
              '不然用户会以为扫描按钮坏了');
    });

    test('扫到 dart 文件但一个 build 都没有，说法要和"没扫到文件"不同', () async {
      final listDir = fakeFs(<String, List<DirEntry>>{
        '/p/lib': const [DirEntry(name: 'consts.dart', isDir: false)],
      });
      final r = await scanProjectPages(
          listDir, fakeRead({'/p/lib/consts.dart': 'const x = 1;'}), '/p/lib');
      expect(r.isEmpty, isTrue);
      expect(r.summary, contains('没找到带 build 方法的页面类'));
    });

    test('结果按路径排序（同一文件内按行号）', () async {
      final listDir = fakeFs(<String, List<DirEntry>>{
        '/p/lib': const [
          DirEntry(name: 'z_page.dart', isDir: false),
          DirEntry(name: 'a_page.dart', isDir: false),
        ],
      });
      final r = await scanProjectPages(
        listDir,
        fakeRead({'/p/lib/a_page.dart': loginSrc, '/p/lib/z_page.dart': loginSrc}),
        '/p/lib',
      );
      expect(r.entries.first.path, endsWith('a_page.dart'));
    });

    test('label 带文件名，同名类能区分开', () async {
      const e = ProjectPageEntry(
        path: '/p/lib/screens/login_page.dart',
        candidate:
            ImportCandidate(className: 'LoginPage', displayName: 'LoginPage', line: 3),
      );
      expect(e.label, 'login_page.dart › LoginPage');
      expect(ProjectScanResult.empty.summary, isNotEmpty);
    });
  });

  group('命名工具', () {
    test('导入的类名带原类名（血缘信息）', () {
      final t = DateTime(2026, 9, 22, 16, 3, 0);
      expect(DesignCodeGen.classNameForImport('LoginPage', t),
          'LoginPageDesign20260922_160300');
    });

    test('文件名与类名同源', () {
      final t = DateTime(2026, 9, 22, 16, 3, 0);
      expect(DesignCodeGen.fileNameForImport('LoginPage', t),
          'LoginPageDesign20260922_160300.dart');
    });

    test('非法字符会被收拾掉（不能生成一个编译不过的类名）', () {
      final t = DateTime(2026, 9, 22, 16, 3, 0);
      expect(DesignCodeGen.classNameForImport('login-page', t),
          'login_pageDesign20260922_160300');
      expect(DesignCodeGen.classNameForImport('9x', t),
          startsWith('X'), reason: '标识符不能以数字开头');
      expect(DesignCodeGen.classNameForImport('', t), startsWith('Imported'));
    });
  });
}
