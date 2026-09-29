import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/demo/blank_project_template.dart';
import 'package:foaide/demo/demo_project_creator.dart';
import 'package:foaide/demo/demo_templates.dart';
import 'package:foaide/env/models.dart';
import 'package:foaide/project/design_import.dart';
import 'package:foaide/project/design_model.dart';

/// 空白工程模板 · 包名动态化（alpha.62 审计修复）
///
/// 起因：模板脚本原来把包名写成 `com.example.$NAME`，且 Kotlin 源码目录名
/// 也硬编码成 `com/example/$NAME`。当时 [DemoProjectCreator.validateName]
/// 要求首字符是字母，所以"恰好"没事；但这属于**两个文件里的规则靠巧合对齐**，
/// 任一处放宽校验就会炸（`package com.example.1to2` 是非法 Java 包名，gradle
/// 直接编译失败，用户在容器日志里看半天也找不到根）。
///
/// 现在包名由 [demoAndroidIdentifier] 单点推导，脚本只做占位符替换，
/// 并在脚本末尾自查"包名三处一致"。
void main() {
  group('模板 · 包名推导是单点来源', () {
    test('普通名字直接拼前缀', () {
      expect(demoAndroidIdentifier('my_app'), 'com.example.my_app');
      expect(demoAndroidIdLastSegment('my_app'), 'my_app');
    });

    test('数字开头的名字被前置 a（Java 包名段不能以数字开头）', () {
      // 这是本次修复的核心：Dart 包名允许首字符是数字，Java 包名不允许。
      expect(demoAndroidIdentifier('1to2'), 'com.example.a1to2');
      expect(demoAndroidIdLastSegment('1to2'), 'a1to2');
    });

    test('名字里的下划线原样保留（Java 标识符允许）', () {
      expect(demoAndroidIdentifier('a_b_c'), 'com.example.a_b_c');
    });

    test('推导结果在任何输入下都是合法 Java 包名', () {
      // Java 包名段：字母开头，后跟字母/数字/下划线
      final seg = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');
      for (final n in ['a', '1', '1to2', '9_lives', 'z9', 'abc_def_123']) {
        final pkg = demoAndroidIdentifier(n);
        final parts = pkg.split('.');
        expect(parts.length, 3, reason: '$n → $pkg 段数不对');
        expect(parts[0], 'com');
        expect(parts[1], 'example');
        expect(seg.hasMatch(parts[2]), isTrue,
            reason: '$n → ${parts[2]} 不是合法 Java 标识符，'
                '会导致 package 声明编译失败');
      }
    });

    test('空名字不崩（返回裸前缀，调用方 validateName 会先拦）', () {
      expect(demoAndroidIdentifier(''), kDemoAndroidIdPrefix);
      expect(demoAndroidIdentifier('   '), kDemoAndroidIdPrefix);
    });

    test('前后空格被裁掉（否则会拼出 "name " 这样的非法包名）', () {
      expect(demoAndroidIdentifier(' my_app '), 'com.example.my_app');
    });
  });

  group('模板 · 脚本渲染后没有残留占位符', () {
    test('__NAME__ / __PKG__ 全部替换干净', () {
      for (final n in ['my_app', '1to2']) {
        final s = blankProjectScript(n);
        expect(s.contains('__NAME__'), isFalse, reason: '$n 残留 __NAME__');
        expect(s.contains('__PKG__'), isFalse, reason: '$n 残留 __PKG__');
      }
    });

    test('项目名与包名是两个独立变量（不相等时才暴露硬编码）', () {
      final s = blankProjectScript('1to2');
      expect(s.contains("NAME='1to2'"), isTrue);
      expect(s.contains("PKG='com.example.a1to2'"), isTrue,
          reason: r'包名若仍拼 $NAME 会写死成 com.example.1to2');
    });
  });

  group('模板 · Kotlin 源码目录与包名逐段对应', () {
    test('目录用 PKGHEAD/PKGLAST 推导，不硬编码 com/example/<name>', () {
      final s = blankProjectScript('1to2');
      expect(s.contains(r'$PKGHEAD/$PKGLAST'), isTrue,
          reason: '目录必须从包名反推，否则包名改了目录跟不上');
      expect(s.contains(r'com/example/$NAME'), isFalse,
          reason: r'硬编码的 com/example/$NAME 会在包名被改写时错位');
      // 逐行看：只在**代码行**上要求不出现字面量目录（注释里举例子不算）。
      for (final line in s.split('\n')) {
        if (line.trimLeft().startsWith('#')) continue;
        expect(line.contains('com/example/'), isFalse,
            reason: '代码行仍出现字面量目录：$line');
      }
    });

    test('脚本里同步定义了 PKGHEAD / PKGLAST', () {
      final s = blankProjectScript('my_app');
      expect(s.contains(r'PKGHEAD="${PKG%.*}"'), isTrue);
      expect(s.contains(r'PKGLAST="${PKG##*.}"'), isTrue);
    });

    test('脚本自查三处包名一致（构建期才发现就太晚了）', () {
      final s = blankProjectScript('my_app');
      expect(s.contains('MainActivity.kt 路径与包名不符'), isTrue);
      expect(s.contains('MainActivity.kt 包名未生效'), isTrue);
    });
  });

  group('模板 · 与项目名校验规则的边界一致', () {
    test('validateName 当前的严格度下，普通名字不会被加 a', () {
      // 反之：若将来放宽到允许数字开头，这里断言会提醒同步包名规则
      for (final n in ['my_app', 'a1', 'abc']) {
        expect(DemoProjectCreator.validateName(n), isNull);
        expect(demoAndroidIdentifier(n), 'com.example.$n');
      }
    });

    test('即便校验放宽，包名推导也兜得住（防未来回归）', () {
      expect(DemoProjectCreator.validateName('1to2'), isNotNull,
          reason: '当前拒绝数字开头；若这里变 null 说明校验放宽了，'
              '那时 demoAndroidIdentifier 的 a 前缀就是唯一防线');
      expect(demoAndroidIdentifier('1to2'), isNot('com.example.1to2'));
    });
  });

  group('EnvInfo · 包名由原生运行时提供', () {
    test('packageName 从 map 解析（Dart 不自己拼 /data/data/<pkg>）', () {
      final env = EnvInfo.fromMap(const {
        'filesDir': '/data/user/0/com.foo.bar/files',
        'packageName': 'com.foo.bar',
        'rootfsPath': '/data/user/0/com.foo.bar/files/rootfs/debian',
        'rootfsInstalled': true,
      });
      expect(env.packageName, 'com.foo.bar');
    });

    test('缺字段时降级空串而不是崩（老版本原生壳兼容）', () {
      final env = EnvInfo.fromMap(const {'filesDir': '/x'});
      expect(env.packageName, '');
    });
  });

  group('模板 · 脚本保持 POSIX sh 兼容', () {
    test('没有 bashism（脚本跑在容器 dash 下）', () {
      final s = blankProjectScript('my_app');
      expect(s.contains('[['), isFalse, reason: '[[ ]] 是 bash 专有');
      expect(s.contains('&>'), isFalse);
      expect(s.contains('<<<'), isFalse, reason: 'here-string 是 bash 专有');
      expect(RegExp(r'^\s*function\s', multiLine: true).hasMatch(s), isFalse);
      expect(s.contains(r'$RANDOM'), isFalse);
    });

    test('脚本内容里没有未转义的单引号（模板用 r\'\'\' 包裹）', () {
      // replaceAll 只允许替换 __NAME__/__PKG__ 这类占位符，
      // 若项目名含单引号会破坏 shell 引号配对——validateName 已挡住，
      // 这里记录该前提。
      expect(DemoProjectCreator.validateName("o'brien"), isNotNull);
    });
  });

  group('模板 · 脚本不是空壳', () {
    test('关键步骤都在（SDK 模板渲染 + 镜像 + wrapper）', () {
      final s = blankProjectScript('my_app');
      expect(s.contains('/opt/flutter'), isTrue);
      expect(s.contains('gradle_utils.dart'), isTrue, reason: '版本要从 SDK 解析');
      expect(s.contains('mirrors.cloud.tencent.com/gradle'), isTrue);
      expect(s.contains('gradle-wrapper.jar'), isTrue);
      expect(s.contains('BLANK_OK'), isTrue);
    });

    test('渲染出的脚本能被 dash 做语法检查（真机同样跑 dash）', () {
      final s = blankProjectScript('my_app');
      final tmp = File('${Directory.systemTemp.path}/foa_blank_syntax_check.sh')
        ..writeAsStringSync(s);
      final r = Process.runSync('dash', ['-n', tmp.path]);
      expect(r.exitCode, 0,
          reason: 'dash -n 失败说明脚本有 POSIX 语法错误：${r.stderr}');
      tmp.deleteSync();
    });
  });

  // ==================================================================
  //
  // 起因（alpha.71 真机截图）：用户新建「空白工程」→ 设计页导入 →
  // 整棵树第一个节点就是「未识别：MaterialApp（生成时原样带回）」。
  //
  // 根因不在模板、在导入器：6 个模板的 `build` **全都**返回
  // `MaterialApp(...)`，而 `_mapKnown` 的识别表里没有 `MaterialApp`。
  // 于是它们无一例外地在第一层就撞墙 —— 空白模板尤其惨，它只有一个
  // 候选类，100% 显示成警告框。
  //
  // 这一组就是那条验收线：改回来会红，别删。
  // ==================================================================
  group('模板 · 必须能被设计页导入器识别', () {
    ImportResult importFirst(String src) {
      final cs = findCandidates(src);
      expect(cs, isNotEmpty, reason: '连一个 build 都没找到');
      return importCandidate(src, cs.first);
    }

    /// 树里所有 unknown 节点的 sourceName（去重）。
    Set<String> unknownNames(DesignNode root) {
      final out = <String>{};
      void walk(DesignNode n) {
        if (n.type == DesignComponentType.unknown) {
          final raw = n.props['raw'] as String? ?? '';
          final nm = n.props['sourceName'] as String? ?? '';
          // 空 raw + 空 name = 摊平用的临时容器，不是真的未识别
          if (raw.isNotEmpty || nm.isNotEmpty) out.add(nm);
        }
        for (final c in n.children) {
          walk(c);
        }
      }
      for (final c in root.children) {
        walk(c);
      }
      return out;
    }

    test('空白模板导入后 0 个未识别（它只有一个候选，没有退路）', () {
      final t = kDemoTemplates.firstWhere((t) => t.id == kBlankTemplateId);
      final cs = findCandidates(t.mainDart);
      expect(cs.length, 1,
          reason: '空白模板只有一个类，下面的断言才等价于"导入必成功"');
      final r = importCandidate(t.mainDart, cs.first);
      expect(r.converted, greaterThan(0));
      expect(r.unknown, 0,
          reason: '空白工程是最常用的模板，导入结果里出现任何「未识别」'
              '都会被读成"这个模板是坏的"');
      expect(r.root.children, isNotEmpty);
    });

    test('6 个模板的首个候选都至少导入出 1 个组件', () {
      // 修之前这一条 6 个模板全红（converted 全是 0）——
      // 正是"看着没适配成功"的直接成因。
      for (final t in kDemoTemplates) {
        final r = importFirst(t.mainDart);
        expect(r.converted, greaterThan(0),
            reason: '${t.id} 模板导入后一个组件都没认出来');
      }
    });

    // ================================================================
    // 这一条是 alpha.74 的**核心验收线**：用户原话是
    // 「这几个 demo 模板强行适配一下」，明确选了"能显示就行，宁可不准"。
    // 也就是说 —— 设计页预览里**一条「未识别」黄条都不该有**。
    //
    // ⚠️ 用 `importFirst` 不够：`findCandidates` 返回多个候选时
    // （`anim` / `tabs` 这类多类的文件），第一个候选可能是个小页面。
    // 要对**每一个**候选都成立，才算"这个模板怎么点都能看"。
    // ================================================================
    test('6 个模板的**每一个**候选导入后都没有「未识别」黄条', () {
      for (final t in kDemoTemplates) {
        final cs = findCandidates(t.mainDart);
        expect(cs, isNotEmpty, reason: '${t.id} 连候选都没有');
        for (final c in cs) {
          final r = importCandidate(t.mainDart, c);
          final names = unknownNames(r.root);
          expect(names, isEmpty,
              reason: '${t.id} 模板的候选 ${c.displayName} 导入后还有'
                  '未识别节点 $names —— 设计页里会画成黄条。'
                  '用户要的是"能显示就行"，该摊的摊、该近似近似的近似，'
                  '代价写进 notes');
        }
      }
    });

    test('任何模板都不该再出现「未识别：MaterialApp」', () {
      for (final t in kDemoTemplates) {
        final cs = findCandidates(t.mainDart);
        for (final c in cs) {
          final names = unknownNames(importCandidate(t.mainDart, c).root);
          expect(names.contains('MaterialApp'), isFalse,
              reason: '${t.id}/${c.className} 仍把 MaterialApp 当成不认识的组件'
                  ' —— 应用外壳应该被透传到 home:');
        }
      }
    });

    test('MaterialApp 透传到 home:，而不是留下一个壳节点', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'x',
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: Center(child: Text('你好'))),
    );
  }
}
''';
      final r = importFirst(src);
      expect(r.unknown, 0);
      expect(r.converted, 1);
      // theme 不该被当成组件扫进去（它确实是 ThemeData(...) 构造）
      expect(unknownNames(r.root), isEmpty);
      final t = r.root.children.first;
      expect(t.type, DesignComponentType.text);
      expect(t.props['text'], '你好');
    });

    test('CupertinoApp 同样被透传', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return CupertinoApp(home: Center(child: Text('cu')));
  }
}
''';
      expect(importFirst(src).unknown, 0);
    });

    test('home: 指向同文件的 StatelessWidget 时跟进去', () {
      const src = '''
import 'package:flutter/material.dart';
class App extends StatelessWidget {
  Widget build(BuildContext context) {
    return MaterialApp(home: const HomePage());
  }
}
class HomePage extends StatelessWidget {
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text('首页')));
  }
}
''';
      final r = importFirst(src);
      expect(r.unknown, 0);
      expect(r.converted, 1, reason: 'AppBar 标题应变成一个 heading');
      expect(r.root.children.first.props['text'], '首页');
    });

    test('home: 指向 StatefulWidget 时跟到 _XxxState 的 build', () {
      // StatefulWidget 自己只有 createState，build 在 State 类里 ——
      // 内置的计数器 / 动画模板全是这种，认不出来等于白改。
      const src = '''
import 'package:flutter/material.dart';
class App extends StatelessWidget {
  Widget build(BuildContext context) {
    return MaterialApp(home: const CounterPage());
  }
}
class CounterPage extends StatefulWidget {
  State<CounterPage> createState() => _CounterPageState();
}
class _CounterPageState extends State<CounterPage> {
  Widget build(BuildContext context) {
    return Scaffold(appBar: AppBar(title: Text('计数器')));
  }
}
''';
      final r = importFirst(src);
      expect(r.unknown, 0);
      expect(r.root.children.first.props['text'], '计数器');
    });

    test('两个类互相引用时不打转（不栈溢出、不静默丢内容）', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return Column(children: [Text('a'), B()]);
  }
}
class B extends StatelessWidget {
  Widget build(BuildContext context) {
    return Column(children: [Text('b'), A()]);
  }
}
''';
      // 能跑完就是过了 —— 早先没有访问栈的话这里是 StackOverflow
      final r = importFirst(src);
      expect(r.converted, greaterThanOrEqualTo(2));
    });

    test('DefaultTabController 只留内容并给出提醒（不静默丢 TabBar）', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(body: Center(child: Text('tab1'))),
    );
  }
}
''';
      final r = importFirst(src);
      expect(r.root.children.first.props['text'], 'tab1');
      expect(r.notes.join(), contains('TabBar'),
          reason: '标签栏被丢掉了却一声不吭，用户会以为是自己没写');
    });

    test('DefaultTabController + TabBarView 只说一次，不重复提醒', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: const TabBarView(
          children: [
            Center(child: Text('a')),
            Center(child: Text('b')),
          ],
        ),
      ),
    );
  }
}
''';
      final r = importFirst(src);
      final tabBarNotes =
          r.notes.where((n) => n.contains('TabBar')).length;
      expect(tabBarNotes, 1,
          reason: '两层都留提醒的话用户会以为出了两个问题 —— '
              '真正丢东西的是 TabBarView 那一层，由它说就够了');
    });

    test('动态列表原样保留并说明原因', () {
      // ⚠️ 这条和下面那条是一对，别合并：
      // 这个 itemCount 是**读得出来的字面量**，所以现在会摊成静态项；
      // 读不出来（网络请求）才原样带回。见 alpha.73 的
      // `_flattenDynamicList`。
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: 3,
      itemBuilder: (context, i) => ListTile(title: Text('x')),
    );
  }
}
''';
      final r = importFirst(src);
      expect(r.notes.join(), contains('静态数据'),
          reason: '摊平了就必须说明"生成的是写死的界面"');
      expect(r.unknown, 0,
          reason: 'itemCount 是源码里的字面量 3 —— 铺成 3 条静态项'
              '是有依据的，不是编造。这正是用户要的"读用户设定的值"');
      expect(r.root.children.length, 3);
    });

    test('FilledButton.icon 的文案在 label: 里，不是 child:', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: () {},
      icon: const Icon(Icons.add),
      label: const Text('下一步'),
    );
  }
}
''';
      final r = importFirst(src);
      expect(r.unknown, 0);
      expect(r.root.children.first.props['text'], '下一步');
      expect(r.root.children.first.props['style'], 'filled');
    });

    // ---------------- alpha.73：把"读用户设定"落到实处 ----------------

    test('读字段初值：_count / _big 按源码里的初值渲染', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatefulWidget {
  const A({super.key});
  State<A> createState() => _AState();
}
class _AState extends State<A> {
  int _count = 7;
  bool _big = true;
  Widget build(BuildContext context) {
    return Column(children: [
      Text('计数：\$_count'),
      Text(_big ? '大' : '小'),
    ]);
  }
}
''';
      final r = importFirst(src);
      // `$_count` 不该再是「未识别：字符串插值」，而是初值 7。
      expect(r.unknown, 0, reason: '插值和三元都该按初值兜住，而不是落成未识别');
      expect(r.root.children[0].props['text'], '计数：7');
      expect(r.root.children[1].props['text'], '大',
          reason: '_big 初值是 true → 取 `?` 那一支');
      expect(r.notes.join(), contains('初值'),
          reason: '必须告诉用户这是初值渲染 —— 不说明的话他会以为 '
              '设计器读的是真机上的实时值');
    });

    test('读静态列表：ListView.separated 按 itemCount 摊成静态条目', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  const A({super.key});
  static const List<String> _items = ['A', 'B', 'C'];
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => ListTile(title: Text(_items[i])),
    );
  }
}
''';
      final r = importFirst(src);
      expect(r.unknown, 0,
          reason: '数据源是**源码里写死的常量**，摊成静态项是有依据的，'
              '不是编造 —— 这正是用户说的"这些不可以读取用户设定的吗"');
      // 3 个条目 + 2 条分隔线
      expect(r.root.children.length, 5);
      expect(r.root.children[0].props['title'], 'A');
      expect(r.root.children[1].type, DesignComponentType.divider);
      expect(r.root.children[2].props['title'], 'B');
      expect(r.root.children[4].props['title'], 'C');
      expect(r.notes.join(), contains('静态数据'),
          reason: '摊平必须配一句说明：生成的是写死的界面，接回真实数据源'
              '要用户自己改');
    });

    test('itemCount 读不出来时**不**摊平（宁可原样带回也不编造）', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: fetchCountFromNetwork(),
      itemBuilder: (context, i) => ListTile(title: Text('x')),
    );
  }
}
''';
      final r = importFirst(src);
      // 两个占位节点：ListView 本身，以及它肚子里那个读不出值的
      // `fetchCount()`（占位节点的内部结构也会导进来，用户能看到里面有什么）。
      expect(r.unknown, 2,
          reason: '条目数来自网络请求 —— 静态展不开。摊成 N 项就是编造');
      expect(r.notes.join(), contains('动态列表'));
    });

    test('TabBarView 的标签页同形时全铺开，不同形时原样带回', () {
      // 同形：三个 Center(Text)，只是文案不同 —— 官方 tabs 模板的写法。
      const same = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return const TabBarView(
      children: [
        Center(child: Text('首页内容')),
        Center(child: Text('收藏内容')),
        Center(child: Text('设置内容')),
      ],
    );
  }
}
''';
      final r1 = importFirst(same);
      expect(r1.unknown, 0,
          reason: '三个标签页结构一样、只是文案不同 —— '
              '文案差异不该让整段被判成"各不相同"');
      expect(r1.root.children.map((n) => n.props['text']).toList(),
          ['首页内容', '收藏内容', '设置内容']);
      expect(r1.notes.join(), contains('按标签顺序铺开'));

      // 不同形：真的是三个不同界面 —— 替用户挑一个会丢掉另外两个。
      const diff = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return TabBarView(
      children: [
        TextField(decoration: InputDecoration(labelText: '账号')),
        ListTile(title: Text('设置项')),
        Icon(Icons.info),
      ],
    );
  }
}
''';
      final r2 = importFirst(diff);
      // 两个占位节点：TabBarView 整段，以及 `Icons.info`
      // （它不在图标白名单里 —— 硬映射会把用户的图标换成别的）。
      expect(r2.unknown, 2,
          reason: '三个标签页长得完全不一样，挑一个就是丢掉另外两个 —— '
              '那种损失比"未识别"大得多');
      expect(r2.notes.join(), contains('原样带回'));
    });

    test('FloatingActionButton 落成 fab 组件（不再当未识别）', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        tooltip: '增加',
        child: const Icon(Icons.add),
      ),
      body: const Center(child: Text('x')),
    );
  }
}
''';
      final r = importFirst(src);
      expect(r.unknown, 0);
      final fab = r.root.children
          .firstWhere((n) => n.type == DesignComponentType.fab);
      expect(fab.props['icon'], 'add');
      expect(fab.props['tooltip'], '增加');
    });

    test('FlutterLogo 落成 flutter_dash 图标（白名单里有了）', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  Widget build(BuildContext context) {
    return const FlutterLogo(size: 48);
  }
}
''';
      final r = importFirst(src);
      expect(r.unknown, 0,
          reason: '`Icons.flutter_dash` 不在白名单时，硬映射会把用户的图标'
              '换成别的 —— 当时的选择是宁可判成未识别。'
              '把它加进白名单才是正解');
      expect(r.root.children.first.type, DesignComponentType.icon);
      expect(r.root.children.first.props['name'], 'flutter_dash');
      expect(r.root.children.first.props['size'], 48.0);
    });

    test('AnimatedContainer 摊成静态方块，尺寸按初值读出来', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatefulWidget {
  const A({super.key});
  State<A> createState() => _AState();
}
class _AState extends State<A> {
  bool _big = false;
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      width: _big ? 200 : 100,
      height: _big ? 200 : 100,
      child: const Icon(Icons.flutter_dash, size: 40),
    );
  }
}
''';
      final r = importFirst(src);
      // alpha.74 起改成摊成 `box` 静态方块 —— "能显示就行"。
      // 尺寸按 `_big` 的初值取（false → `:` 那一支 = 100）。
      expect(r.unknown, 0, reason: '不再落占位节点，设计页里不该有"未识别"黄条');
      final box = r.root.children
          .firstWhere((n) => n.type == DesignComponentType.box);
      expect(box.props['width'], 100.0,
          reason: '_big 初值 false → 取 `:` 那一支，尺寸读得出来');
      expect(box.props['height'], 100.0);
      // 子节点（`child: const Icon(Icons.flutter_dash, size: 40)`）也铺进来，
      // 否则方块里空空如也，用户看不出"这块是什么"
      expect(box.children, hasLength(1));
      expect(box.children.first.type, DesignComponentType.icon);

      final joined = r.notes.join();
      expect(joined, contains('AnimatedContainer'),
          reason: '官方模板里最显眼的一个容器被改了形状，'
              '不给理由用户会认为这就是没适配');
      // 这两句是"改动代价"的核心披露，缺一条用户就会在出包后才发现
      expect(joined, contains('动画'),
          reason: '必须明说动画在设计器里不体现，而生成物也不再是 AnimatedContainer');
      expect(joined, contains('Container'),
          reason: '必须明说生成的是普通 Container —— 这是真的代码变化');
    });

    test('AnimatedContainer 没写尺寸时仍旧原样带回（不硬猜方块大小）', () {
      const src = '''
import 'package:flutter/material.dart';
class A extends StatelessWidget {
  const A({super.key});
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      child: const Text('x'),
    );
  }
}
''';
      final r = importFirst(src);
      expect(r.unknown, 1,
          reason: '连宽高都没有 → 画不出方块，退回诚实的占位节点');
      expect(r.root.children
          .any((n) => n.type == DesignComponentType.box), isFalse);
    });
  });
}
