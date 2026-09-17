import 'package:flutter/material.dart';

/// Step 7 内置 Flutter Demo 模板库。
///
/// 每个模板 = 一份自包含的 lib/main.dart（仅依赖 flutter material，创建时
/// 无需 pub get / 网络），风格取自 Flutter 官方示例：计数器、列表、导航、
/// 动画、标签页。模板代码以 raw string 内置（编译期零依赖），创建时经
/// base64 写入容器 /root/projects/<name>/lib/main.dart。
class DemoTemplate {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final String mainDart;

  /// 是否依赖 git：空白工程为 false（本地离线组装，秒级创建）；
  /// 其余模板走 flutter create（工具启动强制 git 检查），为 true。
  final bool needsGit;

  const DemoTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.mainDart,
    this.needsGit = true,
  });
}

const String kBlankTemplateId = 'blank';

const List<DemoTemplate> kDemoTemplates = [
  // Step 8：空白默认模板——离线生成（无需 git / 网络），默认选中，构建最快。
  DemoTemplate(
    id: kBlankTemplateId,
    name: '空白工程',
    description: '最小空白工程：本地离线生成，无需 Git，构建最快',
    icon: Icons.auto_awesome_outlined,
    needsGit: false,
    mainDart: r'''
import 'package:flutter/material.dart';

void main() => runApp(const BlankApp());

class BlankApp extends StatelessWidget {
  const BlankApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '空白工程',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3DDC84)),
      ),
      home: const Scaffold(
        body: Center(child: Text('Hello, Flutter!')),
      ),
    );
  }
}
''',
  ),
  DemoTemplate(
    id: 'counter',
    name: '计数器',
    description: '官方 Hello World 风格：FAB 累加 + 状态管理',
    icon: Icons.add_circle_outline,
    mainDart: r'''
import 'package:flutter/material.dart';

void main() => runApp(const CounterApp());

class CounterApp extends StatelessWidget {
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '计数器 Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3DDC84)),
      ),
      home: const CounterPage(),
    );
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int _count = 0;

  void _increment() => setState(() => _count++);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('计数器 Demo')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('你点击了按钮：'),
            Text(
              '$_count',
              style: Theme.of(context).textTheme.displayLarge,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _increment,
        tooltip: '增加',
        child: const Icon(Icons.add),
      ),
    );
  }
}
''',
  ),
  DemoTemplate(
    id: 'list',
    name: '列表',
    description: 'ListView.separated 长列表 + 点击反馈',
    icon: Icons.view_list_outlined,
    mainDart: r'''
import 'package:flutter/material.dart';

void main() => runApp(const ListDemoApp());

class ListDemoApp extends StatelessWidget {
  const ListDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '列表 Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3DDC84)),
      ),
      home: const ListDemoPage(),
    );
  }
}

class ListDemoPage extends StatelessWidget {
  const ListDemoPage({super.key});

  static const List<String> _items = [
    'Flutter', 'Dart', 'Android', 'Linux', 'proot', 'Debian',
    'Gradle', 'Kotlin', 'Material 3', 'Terminal', 'Editor', 'APK',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('列表 Demo')),
      body: ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) => ListTile(
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(_items[i]),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('点击了 ${_items[i]}')),
            );
          },
        ),
      ),
    );
  }
}
''',
  ),
  DemoTemplate(
    id: 'nav',
    name: '导航',
    description: '页面跳转 + Hero 过渡动画',
    icon: Icons.navigation_outlined,
    mainDart: r'''
import 'package:flutter/material.dart';

void main() => runApp(const NavDemoApp());

class NavDemoApp extends StatelessWidget {
  const NavDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '导航 Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3DDC84)),
      ),
      home: const NavHomePage(),
    );
  }
}

class NavHomePage extends StatelessWidget {
  const NavHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('导航 Demo')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Hero(
              tag: 'logo',
              child: FlutterLogo(size: 96),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NavDetailPage(),
                  ),
                );
              },
              icon: const Icon(Icons.arrow_forward),
              label: const Text('进入详情页'),
            ),
          ],
        ),
      ),
    );
  }
}

class NavDetailPage extends StatelessWidget {
  const NavDetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('详情页')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Hero(
              tag: 'logo',
              child: FlutterLogo(size: 48),
            ),
            const SizedBox(height: 16),
            const Text('Hero 过渡：返回时 logo 会飞回上一页'),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
''',
  ),
  DemoTemplate(
    id: 'anim',
    name: '动画',
    description: 'AnimatedContainer 缓动切换尺寸/颜色',
    icon: Icons.animation_outlined,
    mainDart: r'''
import 'package:flutter/material.dart';

void main() => runApp(const AnimDemoApp());

class AnimDemoApp extends StatelessWidget {
  const AnimDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '动画 Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3DDC84)),
      ),
      home: const AnimDemoPage(),
    );
  }
}

class AnimDemoPage extends StatefulWidget {
  const AnimDemoPage({super.key});

  @override
  State<AnimDemoPage> createState() => _AnimDemoPageState();
}

class _AnimDemoPageState extends State<AnimDemoPage> {
  bool _big = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('动画 Demo')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOutCubic,
              width: _big ? 200 : 100,
              height: _big ? 200 : 100,
              decoration: BoxDecoration(
                color: _big
                    ? const Color(0xFF3DDC84)
                    : Colors.deepOrangeAccent,
                borderRadius: BorderRadius.circular(_big ? 32 : 8),
              ),
              child: const Icon(Icons.flutter_dash, size: 40),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => setState(() => _big = !_big),
              icon: Icon(_big ? Icons.zoom_out : Icons.zoom_in),
              label: Text(_big ? '缩小' : '放大'),
            ),
          ],
        ),
      ),
    );
  }
}
''',
  ),
  DemoTemplate(
    id: 'tabs',
    name: '标签页',
    description: 'TabBar + TabBarView 三个页面切换',
    icon: Icons.tab_outlined,
    mainDart: r'''
import 'package:flutter/material.dart';

void main() => runApp(const TabsDemoApp());

class TabsDemoApp extends StatelessWidget {
  const TabsDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '标签页 Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3DDC84)),
      ),
      home: const TabsDemoPage(),
    );
  }
}

class TabsDemoPage extends StatelessWidget {
  const TabsDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('标签页 Demo'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.home_outlined), text: '首页'),
              Tab(icon: Icon(Icons.favorite_outline), text: '收藏'),
              Tab(icon: Icon(Icons.settings_outlined), text: '设置'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            Center(child: Text('首页内容')),
            Center(child: Text('收藏内容')),
            Center(child: Text('设置内容')),
          ],
        ),
      ),
    );
  }
}
''',
  ),
];
