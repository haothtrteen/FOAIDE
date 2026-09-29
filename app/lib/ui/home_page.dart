import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../demo/demo_project_creator.dart';
import '../demo/demo_templates.dart';
import '../demo/project_importer.dart';
import '../env/env_installer.dart';
import '../editor/editor_page.dart';
import '../filemanager/file_browser_page.dart';
import '../filemanager/fs_browser_bridge.dart';
import '../mcp/remote_takeover_page.dart';
import '../toolchain/build_page.dart';
import '../project/project_page.dart';
import '../toolchain/toolchain_page.dart';
import 'about_info.dart';
import 'about_page.dart';
import 'onboarding_page.dart';
import 'onboarding_prefs.dart';
import 'terminal_page.dart';

/// Step 7 主页：环境状态 + 工具入口宫格 + 工程列表（FusionApp 式卡片 + FAB 创建）。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FileBrowserBridge _fb = FileBrowserBridge();

  List<FsBrowserEntry> _projects = const [];
  bool _didLoad = false; // 防重复加载标志
  int _tab = 0; // 0 工程 / 1 配置 / 2 设置（底部导航）
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProjects());
  }

  /// 加载容器 /root/projects 工程列表。
  Future<void> _loadProjects() async {
    final env = context.read<EnvState>();
    if (!env.isInstalled) {
      if (mounted) setState(() => _projects = const []);
      return;
    }
    try {
      final r = await _fb.browse('/root/projects');
      if (!mounted) return;
      setState(() {
        _projects = r.entries.where((e) => e.isDir).toList()
          ..sort((a, b) => b.mtime.compareTo(a.mtime));
      });
    } catch (_) {
      // 加载失败静默：下一次下拉/刷新重试
    }
  }

  // ============================ 创建 / 删除 ============================

  Future<void> _showCreateSheet() async {
    final env = context.read<EnvState>();
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CreateDemoSheet(ready: env.isInstalled),
    );
    if (created == true && mounted) {
      await _loadProjects();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('工程已创建，点卡片可直接开始构建')),
        );
      }
    }
  }

  Future<void> _showProjectMenu(FsBrowserEntry p) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(p.name,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('/root/projects/${p.name}',
                  style: const TextStyle(fontSize: 12)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: FoaColors.of(ctx).danger),
              title: Text('删除工程',
                  style: TextStyle(color: FoaColors.of(ctx).danger)),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );
    if (action != 'delete' || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除工程'),
        content: Text('删除 /root/projects/${p.name} 及其全部文件？\n（外部工作区同步的副本不受影响）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: FoaColors.of(ctx).danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final r = await DemoProjectCreator().delete(p.name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(r.ok ? '已删除 ${p.name}' : '删除失败：${r.error}'),
        duration: const Duration(seconds: 3),
      ),
    );
    _loadProjects();
  }

  /// 外部工作区 ↔ 容器 双向同步（设置页）。
  Future<void> _sync(String direction) async {
    setState(() => _syncing = true);
    final r = await _fb.syncProjects(direction);
    if (!mounted) return;
    setState(() => _syncing = false);
    final label = direction == 'toContainer' ? '同步到容器' : '同步到外部';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r.ok
              ? '$label完成：${r.files} 个文件'
              : '$label失败：${r.error}',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
    if (r.ok && direction == 'toContainer') _loadProjects();
  }

  // ============================ 构建 ============================

  @override
  Widget build(BuildContext context) {
    final env = context.watch<EnvState>();
    // rootfs 就绪后自动补一次工程列表（环境由未装 → 已装）
    if (env.isInstalled && !_didLoad) {
      _didLoad = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadProjects());
    }
    return Scaffold(
      appBar: AppBar(
        // alpha.61：应用更名 FOAIDE。走 AboutInfo 常量而非字面量——
        // 名称在 Manifest / 主页标题 / 关于页三处出现，同源才不会改漏。
        title: const SafeArea(child: Text(AboutInfo.appName)),
        actions: [
          IconButton(
            tooltip: '重新检测',
            onPressed: env.installing ? null : () => env.refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _tab == 0
          ? FloatingActionButton(
              onPressed: _showCreateSheet,
              tooltip: '创建工程',
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: '工程',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune),
            selectedIcon: Icon(Icons.tune),
            label: '配置',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
      body: switch (_tab) {
        0 => _buildProjectsTab(env),
        1 => _buildConfigTab(env),
        _ => _buildSettingsTab(),
      },
    );
  }

  Widget _buildProjectsTab(EnvState env) {
    return RefreshIndicator(
      onRefresh: _loadProjects,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        // alpha.92：左右留白 12 → 16，并给每张卡片之间留 10dp 间距。
        //
        // alpha.69 曾为了"让卡片宽一点"把这里收到 12、同时把 Card 的
        // margin 压到 2 —— 那是在跟 Card 默认的 4dp 外缩进做对抗。
        // 现在 Card 的默认 margin 已在主题层归零（见 `FoaTheme._build`），
        // 不再需要逐处抵消，于是左右回到 16（与配置页 / 设置页 /
        // 项目预览页的 `EdgeInsets.all(16)` 一致），间距由 `SizedBox` 显式给。
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          _buildProjectsSection(env),
        ],
      ),
    );
  }

  /// 配置页：环境状态/操作 + 工具链 + 构建 APK 入口 + 方案说明。
  ///
  /// alpha.92 的排版改动（用户截图里"上边距奇怪、文字挤在左边缘"）：
  /// - 左右内边距 16 → 20，与设置页/预览页的卡片度量拉开一档；
  /// - 每组标题（环境 / 工具链 / 方案说明）改成 [_SectionLabel]，
  ///   带图标与统一的下间距 —— 此前是三处各写一个 `Text` +
  ///   各写一个 `SizedBox(height: 8)`，改一处漏两处是迟早的事；
  /// - 卡片之间的间距统一 10（原来是 12/16 混用，读起来像"有些东西
  ///   属于上一组、有些属于下一组"，而实际上它们全是平级的）。
  Widget _buildConfigTab(EnvState env) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
      children: [
        const _SectionLabel(icon: Icons.checklist_rtl, text: '环境'),
        _StatusCard(env: env),
        const SizedBox(height: 10),
        _ActionCard(env: env),
        const SizedBox(height: 20),
        const _SectionLabel(icon: Icons.handyman_outlined, text: '工具链'),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _entryTile(
                icon: Icons.build,
                title: '工具链',
                subtitle: 'JDK / Android SDK / Flutter SDK / x64 兼容层(QEMU) / 构建镜像',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ToolchainPage()),
                ),
              ),
              const Divider(height: 1, indent: 68),
              _entryTile(
                icon: Icons.phone_android,
                title: '构建 APK',
                subtitle: '项目列表 · 流式日志 · 安装',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BuildPage()),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const _SectionLabel(icon: Icons.architecture_outlined, text: '方案说明'),
        const _BuildBackendNote(),
      ],
    );
  }

  /// 工具链 / 构建入口的一行：图标块 + 标题 + 副标题 + 箭头。
  ///
  /// 不用 `ListTile` 的理由与 `_ProjectTile` 相同（要控制 leading 与 title
  /// 的间距，并且要让箭头与副标题用同一档弱化色，而不是各自的默认色）。
  Widget _entryTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final c = FoaColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            EntryIcon(icon: icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: c.muted)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: c.muted),
          ],
        ),
      ),
    );
  }

  /// 设置页：外观主题 + 工作区同步 + 关于（环境状态已移至「配置」页）。
  Widget _buildSettingsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('外观',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.brightness_6_outlined, size: 20),
                    SizedBox(width: 10),
                    Text('主题模式',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 12),
                Consumer<ThemeController>(
                  builder: (context, tc, _) => SegmentedButton<ThemeMode>(
                    // alpha.69：三档等分宽度是「跟随系统」最窄的那一档决定的，
                    // 4 个字在这里必然折成「跟随\n系统」两行 —— 与左右两档
                    // （「浅色」「深色」各 2 字、单行）视觉不齐。改文案为
                    // 「系统」是唯一能保证三档都单行的写法；语义不变，
                    // 三档合起来仍读作「浅色 / 深色 / 系统」。
                    // 同时给 label 兜一个 maxLines —— 万一将来字体放大或
                    // 本地化变长，宁可省略号也不要静默折行。
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined, size: 18),
                        label: Text('浅色',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined, size: 18),
                        label: Text('深色',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.settings_brightness_outlined,
                            size: 18),
                        label: Text('系统',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                    selected: {tc.mode},
                    onSelectionChanged: (s) => tc.mode = s.first,
                    showSelectedIcon: false,
                    expandedInsets: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('项目工作区',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '容器 /root/projects ↔ 外部 /sdcard/Android/data/<包名>/projects 双向同步，'
                  '让系统文件管理器 / 电脑可以直接读写项目文件。',
                  style: TextStyle(fontSize: 12, color: FoaColors.of(context).muted),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _syncing ? null : () => _sync('toContainer'),
                        icon: const Icon(Icons.south, size: 18),
                        // alpha.69：默认 OutlinedButton.icon 的左右内边距各
                        // 16dp + icon-label 间距 8dp，在窄屏上把
                        // 「外部 → 容器」挤成两行。这里把水平内边距收到 8dp、
                        // 字号降到 12，让两个按钮都能单行容纳 —— 保留完整
                        // 文案（「外部」「容器」的方向语义比缩写清楚）。
                        // textStyle 用 styleFrom 而非直接传 Text，是为了让
                        // 它同样作用于 icon 侧的默认度量。
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        label: const Text('外部 → 容器',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _syncing ? null : () => _sync('toExternal'),
                        icon: const Icon(Icons.north, size: 18),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        label: const Text('容器 → 外部',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('引导',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        // alpha.72：首启引导只在第一次出现，之后入口收敛到这里。
        // 老用户想再看一遍「要装什么」的清单、或想确认工具链还剩哪几项
        // 没装，都能从这里回去 —— 不给入口的话，这个页面就等于被删掉了。
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: const Icon(Icons.waving_hand_outlined),
            title: const Text('重新查看初次引导'),
            subtitle: const Text('工具链清单 · 全自动安装 · 作者仓库'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openOnboarding,
          ),
        ),
        const SizedBox(height: 16),
        const Text('关于',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        // alpha.61：改成一张可点卡片，进入独立的「关于」页
        // （作者 / 联系方式 / 引用的其它项目仓库 / 许可说明）。
        // 旧版是设置页里写死 "v0.1.0-alpha.26" 的三行小卡片——版本号早已
        // 过期，且第三方组件来源无处可查。数据源统一在 AboutInfo。
        Card(
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.info_outline, size: 22),
            ),
            title: const Text(AboutInfo.appName,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            // alpha.69：原来是一整段 `'$version · 作者 $author\n引用了 N 个…'`
            // 塞进 subtitle，`ListTile` 按 `isThreeLine` 给的固定高度去排，
            // 版本号一长就被折在「·」和版本号尾号之间，看着像排版事故
            // （当时的版本号本身有 19 个字符）。
            // 改为两个独立 `Text`：版本号独占一行（它是这一行里最长、
            // 也最不该被折断的元素），作者与第三方数量另起一行。
            // subtitle 只吃两行，所以 `isThreeLine` 随之取消。
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ⚠️ 这一条能 const，下一条不能：`AboutInfo.components` 是
                // `List`，`.length` 不是常量表达式（const_eval_property_access）。
                // 混用是没办法的事 —— 别把这里"统一"成 const。
                const Text(
                  AboutInfo.version,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, height: 1.4),
                ),
                Text(
                  '作者 ${AboutInfo.author} · 引用了 '
                  '${AboutInfo.components.length} 个第三方项目',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AboutPage()),
            ),
          ),
        ),
      ],
    );
  }

  /// 从设置页重新打开引导。
  ///
  /// 两件事**顺序不能反**：
  ///   1. 先清掉「已看过」标记 —— 否则用户从这里走完一遍引导、
  ///      下次启动时 `OnboardingGate` 仍然认为他看过；
  ///   2. 再以 `firstRun: false` 打开 —— 这个模式下引导页会显示返回箭头
  ///      并且**不写**标记，用户可以随时退出去，不会因为误点就把
  ///      "首启体验"永久消耗掉。
  ///
  /// 之所以 `await reset()` 之后再 push：reset 是文件 IO，和 push 之间
  /// 没有依赖，但不 await 的话两件事会交错 —— 万一 push 出来的页面
  /// 立刻触发一次 `seen()` 读取，可能读到旧值。代价只是几毫秒，
  /// 不值得为省这点时间引入一个竞态。
  Future<void> _openOnboarding() async {
    await OnboardingPrefs.reset();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const OnboardingPage(firstRun: false),
      ),
    );
  }

  Widget _buildProjectsSection(EnvState env) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('工程',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            Text('${_projects.length} 个',
                style: TextStyle(fontSize: 12, color: FoaColors.of(context).muted)),
            const Spacer(),
            // alpha.92：把「重新扫描工程目录」重新做成一个图标按钮。
            //
            // alpha.69 删掉过这里的一个 🔄，理由是"与 AppBar 的「重新检测」
            // 并排出现两个 🔄，用户无法分辨二者区别"。那个判断在**两个图标
            // 并排且都没有文字说明**时成立；现在的做法是：放到标题行右侧
            // （离 AppBar 那个足够远、视觉上归属于"工程列表"），并且给一个
            // 说清区别的 tooltip —— 前者只重扫 /root/projects，后者还会
            // 重跑环境检测。可发现性回来了，歧义没有回来。
            IconButton(
              tooltip: '重新扫描工程目录（不重跑环境检测）',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.refresh),
              // ⚠️ 判据是 `env.installing` 而不是"正在扫项目"：`_loadProjects`
              // 自己不做转圈反馈（下拉刷新有 RefreshIndicator 兜着），
              // 这里只是避免在环境安装期间让用户重复触发。
              onPressed: env.installing ? null : _loadProjects,
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (!env.isInstalled)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      color: FoaColors.of(context).warning),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('rootfs 未安装，请先初始化环境后再创建工程。'),
                  ),
                ],
              ),
            ),
          )
        else if (_projects.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(Icons.folder_open_outlined,
                      size: 40, color: FoaColors.of(context).muted),
                  const SizedBox(height: 8),
                  const Text('暂无工程',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    '点击右下角「+」选择模板：离线空白工程（免 Git，秒建）或内置 Flutter 官方 Demo。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: FoaColors.of(context).muted),
                  ),
                ],
              ),
            ),
          )
        else
          // alpha.92：一工程一卡，不再"一个大 Card 装 N 个 ListTile"。
          //
          // 原来那种写法有两个问题：
          //   1. **数不出有几个工程**。整块看着像一张卡，数量只能靠读标题
          //      右侧那个「4 个」，或者去数圆头像；
          //   2. **层次表达不出来**。卡片内只有一根 1px 的 Divider 分隔，
          //      而 M3 里"卡片"本身就是一级层次 —— 用一层卡片装多个平级
          //      条目，等于把两级层次压成了一级。
          // 拆开后每张卡自带边界（主题层给了 outlineVariant 描边），
          // 数量、点击目标、列表滚动位置都变得一目了然。
          //
          // 间距 10（不是 8/12）：8 在视觉上会让相邻卡片"粘"在一起，
          // 12 又接近列表内边距 16、读起来像分组之间；10 是"同一列表内
          // 的兄弟项"这个层级的合适距离。
          for (final p in _projects) ...[
            if (p != _projects.first) const SizedBox(height: 10),
            _ProjectTile(
              project: p,
              // alpha.33：点工程先入项目工作台（概览/代码/清单/打包），
              // 构建改为工作台内的一个入口；直达构建页保留给
              // 通知回跳与长按菜单
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProjectPage(projectName: p.name),
                ),
              ),
              onLongPress: () => _showProjectMenu(p),
            ),
          ],
      ],
    );
  }
}

/// 工程卡片：圆角方形首字母图标块 + 名称 + 路径。
///
/// alpha.92 起**自己就是一张卡**（此前是"外层一个大 Card + 若干个 ListTile"，
/// 见 `_buildProjectsSection` 里的说明）。原来那个与分隔线联动的
/// `_kProjectTileIndent` 常量已随外层 Card 一起删除 —— 每项独立成卡后
/// 不再需要"分隔线从图标右侧起画"这种对齐技巧。
class _ProjectTile extends StatelessWidget {
  final FsBrowserEntry project;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ProjectTile({
    required this.project,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = FoaColors.of(context);
    return Card(
      // Card 自带 Clip 后 InkWell 的水波纹/高亮才会被圆角裁掉。
      // 主题层已把 shape 设为 RoundedRectangleBorder，与这里的圆角同源。
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          // contentPadding 由 ListTile 的 `symmetric(horizontal: 12)` 改成
          // 自己给的 12/12：不再用 ListTile 是因为要控制 leading 与 title
          // 之间的间距（ListTile 的 horizontalTitleGap 默认 16，配 44dp 的
          // 图标块会显得松散），并且要自定义 trailing 的弱化样式。
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          child: Row(
            children: [
              _ProjectAvatar(name: project.name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    // alpha.69 的教训仍在：路径一长会折成两行、把卡片撑高
                    // 且高度参差，所以 maxLines/ellipsis 必须留着。
                    // alpha.92 把「· Flutter Demo」去掉换成等宽字体：
                    // 那半句是**所有工程都一样**的常量（本 App 只有一种
                    // 工程类型），占着这一行最容易被截断的位置却不携带信息；
                    // 换成等宽后路径本身的层级（/ 与 _）更容易扫读，
                    // 也和项目预览页 KV 里的 [等宽路径] 风格对上。
                    Text(
                      '/root/projects/${project.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: c.muted,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// 工程首字母图标块（44×44 / 圆角 12）。
///
/// 为什么不是 `CircleAvatar`：项目预览页的项目信息卡用的是
/// **圆角方形**图标块（48×48 / radius 12），抽屉条目、配置页工具链条目
/// 用的也是同一族。圆形头像在这套语言里是唯一一个"异形"，从主页点进
/// 项目再看到预览页，同一件事（这个项目）会有两种图标形状。
///
/// 为什么单独抽出来：配置页的工具链条目需要完全相同的度量
/// （见 [EntryIcon] 的说明），抽出来才能让"改一处、两边同时变"。
class _ProjectAvatar extends StatelessWidget {
  final String name;
  const _ProjectAvatar({required this.name});

  /// 图标块边长。抽成常量是因为 [EntryIcon] 要用同一族度量 ——
  /// 两处各写 44 / 40 的话，"同构"这件事就只剩注释里的一句话。
  static const double size = 44;
  static const double radius = 12;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      // ⚠️ `name` 理论上可能为空（`FsBrowserEntry` 由原生列目录产生，
      // 空名目录在 Linux 上不合法，但真机出现过带空白字符的目录名）。
      // 空串取 [0] 会抛 RangeError 并**带走整个 build**，比显示一个
      // 占位符严重得多。这里退化成 '?'。
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(
          color: cs.onPrimaryContainer,
          fontWeight: FontWeight.bold,
          fontSize: 17,
        ),
      ),
    );
  }
}

/// 创建 Demo 工程 Bottom Sheet：项目名 + 模板 2 列网格 + 创建。
class _CreateDemoSheet extends StatefulWidget {
  final bool ready;
  const _CreateDemoSheet({required this.ready});

  @override
  State<_CreateDemoSheet> createState() => _CreateDemoSheetState();
}

class _CreateDemoSheetState extends State<_CreateDemoSheet> {
  final TextEditingController _ctrl = TextEditingController();
  final ProjectImporter _importer = ProjectImporter();
  String _name = '';
  DemoTemplate? _selected;
  bool _creating = false;

  /// 「导入源码工程」是否正在跑（**与 [_creating] 分开**：创建失败后用户
  /// 仍可能直接点导入，反之亦然；共用一个标志会让两个按钮互相锁死）。
  bool _importing = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    // Step 8：空白工程为默认模板（离线生成、无需 git），打开即选中。
    _selected = kDemoTemplates.first;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final err = DemoProjectCreator.validateName(_name);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    if (_selected == null) {
      setState(() => _error = '请先选择一个模板');
      return;
    }
    setState(() {
      _creating = true;
      _error = '';
    });
    final result = await DemoProjectCreator().create(_name, _selected!);
    if (!mounted) return;
    if (result != null) {
      setState(() {
        _creating = false;
        _error = result;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  // ============================ 导入源码工程 ============================

  /// 导入外部 Flutter 源码工程（`.zip` / `.tar.gz` / `.tar.xz` / `.tar`）。
  ///
  /// 六步，每步失败都**在用户还能看懂的地方**停下来：
  /// 1. 系统文件选择器 → 包落到容器 `/root/imports/`（原生负责，任意格式）
  /// 2. `probe()` 只列成员名，**不解压**，先判定有没有 `pubspec.yaml`
  ///    —— 选错文件（截屏、APK）是高频误操作，不该让用户等 500MB 解压完
  /// 3. 读包内 `pubspec.yaml` 的 `name:` 猜工程名（不回退到文件名：
  ///    原生的名字清洗会把中文折成下划线，`我的应用.zip` → `_____.zip`）
  /// 4. 弹名字对话框，**预填猜出来的名字**，实时跑 `validateName` 校验
  /// 5. 不可关闭的进度框里跑 `importArchive()`（解压+校验+落位）
  /// 6. `pop(true)` —— 复用 `_showCreateSheet` 现成的刷新链路，零改动
  Future<void> _import() async {
    setState(() {
      _importing = true;
      _error = '';
    });

    try {
      final picked = await _importer.pickArchive();
      if (!mounted) return;
      if (!picked.ok || picked.path == null) {
        setState(() {
          _importing = false;
          if (picked.error != '已取消选择') {
            _error = picked.error ?? '导入失败';
          }
        });
        return;
      }
      final guestArchive = picked.path!;

      // 表里没有的格式早拦（原生 `type = "*/*"`，用户能选到任何文件）
      if (!ProjectImporter.isArchive(picked.name ?? guestArchive)) {
        setState(() {
          _importing = false;
          _error = '只支持 .zip / .tar.gz / .tar.xz / .tar，'
              '你选的是「${picked.name ?? guestArchive}」';
        });
        return;
      }

      // 探测：一句话说明"这个包长什么样"
      final probe = await _importer.probe(guestArchive);
      if (!mounted) return;
      if (!probe.usable) {
        setState(() {
          _importing = false;
          _error = probe.topEntries.isEmpty
              ? '读不出压缩包内容（文件可能损坏、加密或格式不符）：${picked.name}'
              : '这个包里没有 pubspec.yaml，不是 Flutter 源码工程。\n'
                  '包内顶层内容是：${probe.topEntries.take(8).join('、')}';
        });
        return;
      }

      final pubName = await _importer.peekPubspecName(guestArchive, probe);
      if (!mounted) return;
      final suggested = ProjectImporter.guessName(
        pubName: pubName,
        archiveName: picked.name ?? guestArchive.split('/').last,
      );

      // 问名字（预设值可直接确认）
      final name = await _askImportName(suggested);
      if (!mounted) return;
      if (name == null) {
        setState(() => _importing = false);
        return;
      }

      // 不可关闭的进度框：exec 是阻塞的，给"取消"按钮等于骗人
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _ImportProgressDialog(),
      );
      final err = await _importer.importArchive(
        guestArchive: guestArchive,
        name: name,
        probeResult: probe,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // 关进度框

      if (err != null) {
        setState(() {
          _importing = false;
          _error = err;
        });
        return;
      }

      // 源压缩包用完就删：它躺在 /root/imports，用户打开文件浏览器会看到
      // 一个几十 MB 的僵尸（且导入本身不承诺保留原包）
      await _importer.removeFile(guestArchive);
      if (!mounted) return;
      Navigator.of(context).pop(true); // 触发外层 _loadProjects()
    } catch (e) {
      if (!mounted) return;
      // 进度框可能开着，先尝试关掉再报错
      Navigator.of(context, rootNavigator: true).maybePop();
      setState(() {
        _importing = false;
        _error = '导入失败：$e';
      });
    }
  }

  /// 问工程名。返回 null = 取消。
  Future<String?> _askImportName(String suggested) async {
    final ctrl = TextEditingController(text: suggested);
    String? err = DemoProjectCreator.validateName(suggested);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('导入为工程'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                onChanged: (v) => setDlg(
                    () => err = DemoProjectCreator.validateName(v.trim())),
                decoration: InputDecoration(
                  labelText: '工程名',
                  helperText: '目录名 / 包名',
                  errorText: err,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '源码会解压到 /root/projects/${ctrl.text.trim().isEmpty ? '…' : ctrl.text.trim()}',
                style: TextStyle(
                  fontSize: 11,
                  color: FoaColors.of(ctx).muted,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: err == null
                  ? () => Navigator.pop(ctx, ctrl.text.trim())
                  : null,
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: cs.primary,
                    child: Icon(Icons.add, size: 18, color: cs.onPrimary),
                  ),
                  const SizedBox(width: 10),
                  const Text('创建工程',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(
                    onPressed:
                        (_creating || _importing) ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (!widget.ready) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: FoaColors.of(context).warningContainer,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: FoaColors.of(context).warningBorder),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber,
                          size: 16, color: FoaColors.of(context).warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'rootfs / 工具链未就绪，创建可能失败（需先初始化环境并在工具链页安装 Flutter SDK）',
                          style: TextStyle(
                              fontSize: 12,
                              color: FoaColors.of(context).warning),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl,
                enabled: !_creating && !_importing,
                onChanged: (v) => setState(() => _name = v.trim()),
                decoration: const InputDecoration(
                  labelText: '项目名（目录名 / 包名）',
                  hintText: '如 my_demo',
                  helperText: '小写字母、数字、下划线，首字符为字母',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              // ---------------- 导入现有源码工程 ----------------
              // 放在项目名之后、模板之前：语义上"导入"与"新建"是并列的
              // 两条来源，但模板网格占满宽度，插在中间会把两个流程割开。
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(child: Divider(color: cs.outlineVariant)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text('或',
                        style: TextStyle(
                            fontSize: 12, color: FoaColors.of(context).muted)),
                  ),
                  Expanded(child: Divider(color: cs.outlineVariant)),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      (_creating || _importing) ? null : _import,
                  icon: _importing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.unarchive_outlined, size: 18),
                  label: Text(_importing
                      ? '正在导入…'
                      : '导入 Flutter 源码工程（.zip / .tar.gz）'),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '支持 .zip / .tar.gz / .tar.xz / .tar；包内须含 pubspec.yaml'
                '（GitHub「Download ZIP」可直传，外层多一层目录会自动识别）',
                style: TextStyle(
                    fontSize: 11, color: FoaColors.of(context).muted, height: 1.4),
              ),
              const SizedBox(height: 14),
              const Text('选择模板',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.1,
                children: [
                  for (final t in kDemoTemplates) _templateCard(t),
                ],
              ),
              if (_selected?.needsGit == true) ...[
                const SizedBox(height: 10),
                // alpha.69：横幅改用警告语义位。原来底色是
                // `0x33FFB74D`（固定橙的 20% 透明），文字是 `0xFFFFB74D`
                // —— 这套在浅色主题下是「淡橙底 + 亮橙字」，对比度不足；
                // `warningContainer` / `warningBorder` / `warning` 三档
                // 在浅色下会各自换成深色版本，两边主题都读得清。
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: FoaColors.of(context).warningContainer,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: FoaColors.of(context).warningBorder),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_download_outlined,
                          size: 16, color: FoaColors.of(context).warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '该模板由 flutter create 生成，需连接 Git 自动下载安装（国内镜像，首次约 1 分钟）；「空白工程」完全离线，推荐优先使用。',
                          style: TextStyle(
                              fontSize: 12,
                              color: FoaColors.of(context).warning,
                              height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 10),
                SelectableText(
                  _error,
                  style: TextStyle(
                      fontSize: 12, color: FoaColors.of(context).danger),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (_creating || _importing) ? null : _create,
                  icon: _creating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.rocket_launch_outlined, size: 18),
                  label: Text(_creating ? '正在创建…' : '创建工程'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _templateCard(DemoTemplate t) {
    final cs = Theme.of(context).colorScheme;
    final sel = _selected?.id == t.id;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: (_creating || _importing) ? null : () => setState(() => _selected = t),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: sel ? cs.primaryContainer.withValues(alpha: 0.35) : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: sel ? cs.primary : Colors.transparent,
            width: 1.6,
          ),
        ),
        child: Row(
          children: [
            // alpha.69：这里原本是 `Badge(label: Text('需Git'))` 包着 26dp 的
            // 图标。`Badge` 的 label 是 `Positioned` 浮层（默认
            // `Offset(4, -4)`、对齐 topEnd），**不参与布局**，于是那个
            // 4 字小标签直接右溢、压到相邻的模板标题首字上 ——
            // 就是用户截图里「创建项目界面 git 与字重合」。
            // 改为普通 Icon + 下方标签的纵向组合：角标挤占的是自己那一格
            // 的横向空间（26dp 的图标改成竖排更窄），不再越界。
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  t.icon,
                  size: 24,
                  color: sel ? cs.primary : cs.onSurfaceVariant,
                ),
                if (t.needsGit) ...[
                  const SizedBox(height: 3),
                  const _NeedGitTag(),
                ],
              ],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.name,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    t.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10, color: FoaColors.of(context).muted, height: 1.3),
                  ),
                ],
              ),
            ),
            if (sel)
              Icon(Icons.check_circle, size: 18, color: cs.primary),
          ],
        ),
      ),
    );
  }
}

/// 模板卡片上的「需Git」小标签（alpha.69 新增）。
///
/// 替代原来的 `Badge.label`：那个是 `Positioned` 浮层、不占布局，
/// 会溢出到相邻的模板标题上（详见 `_templateCard` 里的说明）。
///
/// 这里用 `FoaTheme` 的警告语义位而不是原先的固定橙色 —— 浅色主题下
/// `warning` 会压深到 `0xFFB26A00`，`warningContainer` / `warningBorder`
/// 也随之换成浅底，否则浅色主题下这块会是一坨深橙底上的浅橙字。
///
/// 为什么单独抽一个 widget 而不是内联：`_templateCard` 里的图标是
/// `Column` 的第一个孩子，把四行装饰内联进去会让那个 `Row` 的
/// 可读性垮掉；顺带这里也是唯二需要 `FoaColors.of(context)` 的地方。
class _NeedGitTag extends StatelessWidget {
  const _NeedGitTag();

  @override
  Widget build(BuildContext context) {
    final c = FoaColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.warningContainer,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.warningBorder),
      ),
      child: Text(
        '需Git',
        maxLines: 1,
        style: TextStyle(
          fontSize: 9,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: c.warning,
        ),
      ),
    );
  }
}

/// [ProjectImporter.importArchive] 执行期间的进度框。
///
/// **必须定义在顶层**：`showDialog` 的 builder 在路由层重建，挂在 State 里
/// 的私有 widget 会随 BottomSheet 一起被卸载。
///
/// `PopScope(canPop: false)` 是刻意的：解压走 `ProotBridge.exec`，那是
/// **阻塞式**调用（原生侧串行执行器），中途根本没有取消的途径。
/// 摆一个"取消"按钮只会让用户以为点了就能停 —— 与其骗人，不如说清楚
/// 现在不能退出。
class _ImportProgressDialog extends StatelessWidget {
  const _ImportProgressDialog();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('正在解压并导入工程…'),
                  const SizedBox(height: 4),
                  Text(
                    '大工程可能需要几分钟，请勿退出',
                    style: TextStyle(
                      fontSize: 11,
                      color: FoaColors.of(context).muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final EnvState env;
  const _StatusCard({required this.env});

  @override
  Widget build(BuildContext context) {
    final info = env.info;

    if (info == null && env.error == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (info == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('初始化失败',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: FoaColors.of(context).danger)),
              const SizedBox(height: 8),
              SelectableText(env.error ?? ''),
            ],
          ),
        ),
      );
    }

    final i = info;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // alpha.92：顶部一块「现状摘要」。
          //
          // 原来这里只有一行「✅ 环境已就绪」，下面直接跟一条 Divider 和
          // 四行 KV —— 用户扫一眼只能得到"就绪/未就绪"这一个 bit，而这一页
          // 真正要回答的是"我现在能干什么、还差什么"。摘要块把这两件事
          // 摆到最显眼的位置：一个状态徽标 + 一句"该做什么"。
          _StatusSummary(env: env),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv(context, '设备', '${i.device} · Android API ${i.androidSdk}'),
                _kv(context, 'ABI', i.abi ?? '-'),
                _kv(context, 'rootfs', i.rootfsInstalled ? i.rootfsPath : '未安装'),
                _kv(context, 'proot',
                    i.prootPath ?? '未找到（jniLibs 与 assets 均无）'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 一行 KV。键宽 72（对齐 [ProjectPreview] 的 76 减去 4dp 的卡片内边距差）。
  ///
  /// alpha.92：键色从写死的 `Colors.grey.shade400` 改成 [FoaColors.muted]。
  /// 那是 Bug 464 那轮漏掉的一处硬编码（当时清的是 shade500/600，400 没进
  /// 名单）：`#BDBDBD` 压在浅色主题的近白卡片上几乎读不出来。
  /// 值改用 `SelectableText`：`rootfs` / `proot` 是**路径**，
  /// 用户经常需要复制出来；顺手本行也去掉了多余的花括号。
  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(k,
                  style: TextStyle(
                      color: FoaColors.of(context).muted, fontSize: 12.5)),
            ),
            Expanded(
              child: SelectableText(v,
                  style: const TextStyle(fontSize: 12.5, height: 1.35)),
            ),
          ],
        ),
      );
}

/// 环境「现状摘要」块：状态徽标 + 一句话结论 + 一行关键指标。
///
/// 为什么单独抽：这段在两个状态下（就绪 / 未就绪）结构相同、只是配色与
/// 文案不同，写成一组 `if/else` 的三元表达式塞进 `_StatusCard` 会让那个
/// `build` 长到读不动。抽出来后还能让"就绪"与"未就绪"两套样式**并排**
/// 摆在这里，一眼看得出它们刻意共用同一套骨架。
class _StatusSummary extends StatelessWidget {
  final EnvState env;
  const _StatusSummary({required this.env});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = FoaColors.of(context);
    final ready = env.isInstalled;
    // 状态色：就绪用品牌绿（`FoaColors.success`，与 AppBar 的勾、编辑器
    // 状态一致），未就绪用警告色。注意不能用 `danger` —— 没装 rootfs 是
    // **初始状态**，不是出错；用红色会让第一次打开 App 的人以为出了故障。
    final accent = ready ? c.success : c.warning;

    return Container(
      // 底色用 M3 的 primaryContainer 派生而不是再写一对深浅常量：
      // 它在深色下是暗绿、浅色下是淡绿，天然"同色系按亮度适配"。
      // 用 `withValues(alpha: …)` 而不是 `withOpacity`（后者已废弃）。
      color: cs.primaryContainer.withValues(alpha: 0.35),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 徽标：圆底 + 图标。它是这一块里唯一"高饱和"的元素，
              // 用户的视线应该先落在这里。
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  ready ? Icons.check_circle : Icons.priority_high_rounded,
                  size: 19,
                  color: accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(ready ? '环境已就绪' : '环境未安装',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    // 一句话说清"现在能做什么 / 还差什么"。
                    // 这两句是这一页真正的结论，所以放在摘要里而不是
                    // 埋在下方的 KV 中。
                    Text(
                      ready
                          ? '可以用终端、编辑器和构建了；下面还有 6 个快捷入口。'
                          : '先点下方「初始化环境」解压内置 rootfs，再装 Flutter SDK。',
                      style: TextStyle(fontSize: 11.5, color: c.muted, height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 就绪时不重复显示"未安装"这个否命题 —— 空状态只留一句行动指引。
          if (!ready) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.touch_app_outlined, size: 13, color: c.muted),
                const SizedBox(width: 5),
                Expanded(
                  child: Text('仅需一次，解压到应用私有目录',
                      style: TextStyle(fontSize: 11, color: c.muted)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 分组标题：图标 + 文字（alpha.92）。
///
/// 原来三处标题各写一个裸 `Text(fontSize: 16, bold)`，各自跟一个
/// `SizedBox(height: 8)`。抽出来之后有三个好处：
/// 1. 间距与字号只有一处定义 —— 改一处三处同时变；
/// 2. 加了图标，扫读时"这一组是什么"不用读字；
/// 3. 上下间距不对称（上方 20、下方 6）：标题与它所辖的内容更近，
///    与上一组更远。这是分组视觉最基本的一条，此前三个标题全是
///    上下等距的 8/8，所以"分组"这件事其实没表达出来。
class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SectionLabel({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = FoaColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: c.muted),
          const SizedBox(width: 7),
          Text(text,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3)),
        ],
      ),
    );
  }
}

/// 工具链条目 / 工程卡片共用的图标块（40×40 / 圆角 10）。
///
/// 命名不带下划线前缀是刻意的：它是**跨页面同构**的度量，
/// `home_ui_alpha92_test.dart` 有一条源码断言盯着它存在。
/// （仍在本文件内可见性为 library-private —— Dart 没有 "package-private
/// 但跨文件可见" 的粒度，真要跨文件共享得提升到 `core/theme.dart`，
/// 但那样会为两个使用点引入一个公共 API，不划算。）
class EntryIcon extends StatelessWidget {
  final IconData icon;
  const EntryIcon({super.key, required this.icon});

  static const double size = 40;
  static const double radius = 10;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, size: 20, color: cs.onSecondaryContainer),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final EnvState env;
  const _ActionCard({required this.env});

  @override
  Widget build(BuildContext context) {
    final installed = env.isInstalled;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!installed) ...[
              const Text('下一步', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                  '初始化会把内置的 Debian rootfs 解压到应用私有目录，仅需一次。'),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: env.installing ? null : () => env.installRootfs(),
                  icon: env.installing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download),
                  label: Text(env.installing ? '正在解压 rootfs…' : '初始化环境'),
                ),
              ),
            ] else ...[
              // alpha.92：标题从「环境状态」改成「快捷入口」。
              // 状态已经在上面那张卡的摘要块里说过了，这里重复一次
              // 只会让用户再读一遍同样的字；这一块的职责就是六个入口。
              const Text('快捷入口', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                '终端 / 编辑器 / 文件浏览器，以及工具链、打包与远程协助。',
                style: TextStyle(
                    fontSize: 12.5,
                    color: FoaColors.of(context).muted,
                    height: 1.4),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => GridView.count(
                  // 阈值 560 保留：平板上排三列，手机排两列。
                  crossAxisCount: constraints.maxWidth >= 560 ? 3 : 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  // ⚠️ alpha.92（Bug 634）：**不要用 `childAspectRatio`**。
                  //
                  // 原来的 2.2 与我这轮先试的 1.9 都栽在同一件事上：
                  // aspectRatio 定的是"格子的宽/高比"，而格子宽度是**算出来**
                  // 的（`(可用宽 - 间距) / 列数`）—— 于是格子高度随屏幕宽度
                  // 反比浮动。在 360dp 的手机上，两列格子约 135dp 宽，
                  // 2.2 → 高 61dp；而内容恒定需要
                  // `图标(28) + 间距(8) + 一行 13px 字(~18) + 上下内边距(16)`
                  // ≈ 70dp。**从 alpha.60 加进第 6 个入口起，这一格就一直
                  // 差着 9dp**，只是溢出在 RenderFlex 里被压缩到不报错。
                  //
                  // 改用 `mainAxisExtent`：高度是**给定值**，与屏幕宽度无关。
                  // 内容需要多少就给多少 —— 窄屏不会把字挤没，宽屏也不会
                  // 把格子拉成一条。
                  mainAxisExtent: 92,
                  children: [
                    _ActionTile(
                      icon: Icons.terminal,
                      label: '打开终端',
                      primary: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const TerminalPage()),
                      ),
                    ),
                    _ActionTile(
                      icon: Icons.code,
                      label: '打开编辑器',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => EditorPage()),
                      ),
                    ),
                    _ActionTile(
                      icon: Icons.folder_open,
                      label: '文件浏览器',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const FileBrowserPage()),
                      ),
                    ),
                    _ActionTile(
                      icon: Icons.build,
                      label: '工具链',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ToolchainPage()),
                      ),
                    ),
                    _ActionTile(
                      icon: Icons.phone_android,
                      label: '构建 APK',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const BuildPage()),
                      ),
                    ),
                    // alpha.60：远程协助（MCP + cloudflared 隧道）
                    _ActionTile(
                      icon: Icons.hub,
                      label: '远程协助',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const RemoteTakeoverPage()),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (env.installLog.isNotEmpty) ...[
              const SizedBox(height: 8),
              // alpha.92：`Colors.grey.shade400` → [FoaColors.muted]。
              // 同一处漏网的硬编码（Bug 464 只清了 shade500/600）：
              // 安装日志是**浅色主题下最需要读的一段字**，用固定灰
              // 压在近白底上正好读不出来。
              Text(env.installLog,
                  style: TextStyle(
                      fontSize: 12, color: FoaColors.of(context).muted)),
            ],
            if (env.error != null) ...[
              const SizedBox(height: 8),
              Text(env.error!,
                  style: TextStyle(
                      fontSize: 12, color: FoaColors.of(context).danger)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 宫格操作块：图标置顶、文字居下，主操作高亮。
///
/// alpha.92：圆角 16 → 14（与主题层的卡片圆角同源，让"卡片里的块"
/// 读起来是卡片的子级）；加一层 1px 描边 —— 深色主题下
/// `secondaryContainer` 与 `surfaceContainerLow` 的差值只有约 4% 亮度，
/// 手机在户外亮度下这两块会糊在一起。
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 描边色：主操作本身就是高饱和的实色块，不需要描边；
    // 其余用 outlineVariant（M3 专为"弱边界"设计的令牌）。
    final border = primary ? null : cs.outlineVariant;
    final radius = BorderRadius.circular(14);
    // ⚠️ Bug 634：`Material` 的断言 `!(shape != null && borderRadius != null)`
    // 意味着这两者**互斥** —— 想同时要圆角和描边，就只能用 `shape`
    // （`RoundedRectangleBorder` 两个字段都能表达），绝不能两个都传。
    // 这个错误的表现是**运行时断言**（`Failed assertion: line 209`），
    // 不是编译错误，所以静态分析抓不到。
    final shape = RoundedRectangleBorder(
      borderRadius: radius,
      side: border == null ? BorderSide.none : BorderSide(color: border),
    );
    return Material(
      color: primary ? cs.primary : cs.secondaryContainer,
      shape: shape,
      child: InkWell(
        // InkWell 不受这条断言约束（它是 Material 的 child，不在构造参数里
        // 同时给形状的两套表达），所以这里仍然用 borderRadius 来裁水波纹。
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 28,
                  color: primary ? cs.onPrimary : cs.onSecondaryContainer),
              const SizedBox(height: 8),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: primary ? cs.onPrimary : cs.onSecondaryContainer)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「方案说明」卡片（alpha.92 从内联的 `Text` 提取）。
///
/// 原来是一整段用 `\n` 拼起来的文本，里面用 ①② 做列表标记。问题是：
/// 在窄屏上这段文字会折行，而折行后 `①` 与 `②` **不再对齐**（它们只是
/// 行首的两个字符，不是真正的列表项），读起来像一段散文里冒出来的符号。
/// 改成结构化之后，每条有自己的图标与标题，折行与对齐都由布局负责。
class _BuildBackendNote extends StatelessWidget {
  const _BuildBackendNote();

  @override
  Widget build(BuildContext context) {
    final c = FoaColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('两套可切换的构建后端',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Flutter 官方 Linux 仅发布 x64 工具链，aarch64 上要跑起来有两条路。'
              '两者可切换、可共存，任一就绪即可安装 Flutter / Android SDK。',
              style: TextStyle(fontSize: 12, color: c.muted, height: 1.5),
            ),
            const SizedBox(height: 12),
            const _BackendOption(
              icon: Icons.swap_horiz,
              title: '转译',
              body: '由「x64 兼容层」用 qemu 转发 dart / gen_snapshot / aapt2。',
            ),
            const SizedBox(height: 10),
            const _BackendOption(
              icon: Icons.memory,
              title: '原生 arm64',
              body: '把关键二进制换成 aarch64 版（工具链页「原生 arm64」可先做体检，'
                  '看清哪些还在模拟）。',
            ),
            const SizedBox(height: 12),
            // 唯一的硬缺口单独拎出来并改用警告语义位：它不是一个"选项"，
            // 而是"选原生这条路必然会撞上的墙"，混在正文里会被读漏。
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: c.warningContainer,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: c.warningBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.report_gmailerrorred_outlined,
                      size: 15, color: c.warning),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'gen_snapshot 官方不发 arm64 版，是原生化的唯一硬缺口，'
                      '需自备移植产物导入。',
                      style:
                          TextStyle(fontSize: 11.5, color: c.warning, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一条构建后端说明：小图标 + 标题 + 正文。
class _BackendOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _BackendOption({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = FoaColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 15, color: cs.onSecondaryContainer),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(body,
                  style: TextStyle(fontSize: 11.5, color: c.muted, height: 1.45)),
            ],
          ),
        ),
      ],
    );
  }
}
