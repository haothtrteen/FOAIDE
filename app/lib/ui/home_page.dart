import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../demo/demo_project_creator.dart';
import '../demo/demo_templates.dart';
import '../env/env_installer.dart';
import '../editor/editor_page.dart';
import '../filemanager/file_browser_page.dart';
import '../filemanager/fs_browser_bridge.dart';
import '../toolchain/build_page.dart';
import '../project/project_page.dart';
import '../toolchain/toolchain_page.dart';
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
              leading: const Icon(Icons.delete_outline, color: Color(0xFFFF7A7A)),
              title: const Text('删除工程', style: TextStyle(color: Color(0xFFFF7A7A))),
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
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF7A7A)),
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
        title: const SafeArea(child: Text('Flutter On Android')),
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          _buildProjectsSection(env),
        ],
      ),
    );
  }

  /// 配置页：环境状态/操作 + 工具链（JDK / Android SDK / Flutter SDK /
  /// x64 兼容层 / 构建镜像）+ 构建 APK 入口 + 方案说明。
  Widget _buildConfigTab(EnvState env) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('环境',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        _StatusCard(env: env),
        const SizedBox(height: 12),
        _ActionCard(env: env),
        const SizedBox(height: 16),
        const Text('工具链',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.build),
                title: const Text('工具链'),
                subtitle: const Text('JDK / Android SDK / Flutter SDK / x64 兼容层(QEMU) / 构建镜像'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ToolchainPage()),
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.phone_android),
                title: const Text('构建 APK'),
                subtitle: const Text('项目列表 · 流式日志 · 安装'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BuildPage()),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text('方案说明',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('两套可切换的构建后端',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(
                  'Flutter 官方 Linux 仅发布 x64 工具链，aarch64 上要跑起来有两条路：\n'
                  '① 转译：由「x64 兼容层」用 qemu 转发 dart / gen_snapshot / aapt2；\n'
                  '② 原生：把关键二进制换成 aarch64 版（工具链页「原生 arm64」可先做体检，'
                  '看清哪些还在模拟）。\n'
                  '两者可切换、可共存，任一就绪即可安装 Flutter / Android SDK。\n'
                  '注意：gen_snapshot 官方不发 arm64 版，是原生化的唯一硬缺口，'
                  '需自备移植产物导入。',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                      height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ],
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
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined, size: 18),
                        label: Text('浅色'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined, size: 18),
                        label: Text('深色'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.settings_brightness_outlined,
                            size: 18),
                        label: Text('跟随系统'),
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
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _syncing ? null : () => _sync('toContainer'),
                        icon: const Icon(Icons.south, size: 18),
                        label: const Text('外部 → 容器'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _syncing ? null : () => _sync('toExternal'),
                        icon: const Icon(Icons.north, size: 18),
                        label: const Text('容器 → 外部'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('关于',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.flutter_dash, size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Flutter On Android',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold)),
                        Text('v0.1.0-alpha.26 · 在 Android 上原生构建 APK',
                            style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '内置 Debian rootfs（proot 模拟 root）+ 本地 JDK / Android SDK / Flutter SDK，'
                  '内置官方 Demo 模板，在设备上完成创建 → 编辑 → 构建 → 安装全流程。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ),
      ],
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
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            const Spacer(),
            IconButton(
              tooltip: '刷新工程列表',
              onPressed: _loadProjects,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (!env.isInstalled)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orangeAccent),
                  SizedBox(width: 10),
                  Expanded(
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
                      size: 40, color: Colors.grey.shade600),
                  const SizedBox(height: 8),
                  const Text('暂无工程',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    '点击右下角「+」选择模板：离线空白工程（免 Git，秒建）或内置 Flutter 官方 Demo。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, p) in _projects.indexed) ...[
                  if (i > 0) const Divider(height: 1, indent: 72),
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
            ),
          ),
      ],
    );
  }
}

/// 工程卡片：圆形首字母图标 + 名称 + 路径（FusionApp 应用卡片风格改良）。
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
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: cs.primaryContainer,
        child: Text(
          project.name[0].toUpperCase(),
          style: TextStyle(
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ),
      title: Text(project.name,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '/root/projects/${project.name} · Flutter Demo',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
      onLongPress: onLongPress,
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
  String _name = '';
  DemoTemplate? _selected;
  bool _creating = false;
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
                    onPressed: _creating ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (!widget.ready) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x33FF7A7A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning_amber, size: 16, color: Color(0xFFFF7A7A)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'rootfs / 工具链未就绪，创建可能失败（需先初始化环境并在工具链页安装 Flutter SDK）',
                          style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl,
                enabled: !_creating,
                onChanged: (v) => setState(() => _name = v.trim()),
                decoration: const InputDecoration(
                  labelText: '项目名（目录名 / 包名）',
                  hintText: '如 my_demo',
                  helperText: '小写字母、数字、下划线，首字符为字母',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
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
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x33FFB74D),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.cloud_download_outlined,
                          size: 16, color: Color(0xFFFFB74D)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '该模板由 flutter create 生成，需连接 Git 自动下载安装（国内镜像，首次约 1 分钟）；「空白工程」完全离线，推荐优先使用。',
                          style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFFFFB74D),
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
                  style: const TextStyle(fontSize: 12, color: Color(0xFFFF7A7A)),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _creating ? null : _create,
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
      onTap: _creating ? null : () => setState(() => _selected = t),
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
            // Step 8：非空白模板（需 git）在图标右上角显示「需Git」角标，
            // 配合选中后的提示横幅提醒联网下载 git 组件。
            Badge(
              label: const Text('需Git', style: TextStyle(fontSize: 9)),
              isLabelVisible: t.needsGit,
              child: Icon(
                t.icon,
                size: 26,
                color: sel ? cs.primary : cs.onSurfaceVariant,
              ),
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
                        fontSize: 10, color: Colors.grey.shade500, height: 1.3),
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
              const Text('初始化失败',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Color(0xFFFF7A7A))),
              const SizedBox(height: 8),
              SelectableText(env.error ?? ''),
            ],
          ),
        ),
      );
    }

    final i = info;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  i.rootfsInstalled
                      ? Icons.check_circle
                      : Icons.info_outline,
                  color: i.rootfsInstalled
                      ? const Color(0xFF3DDC84)
                      : Colors.orangeAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  i.rootfsInstalled ? '环境已就绪' : '环境未安装',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 20),
            _kv('设备', '${i.device} · Android API ${i.androidSdk}'),
            _kv('ABI', i.abi ?? '-'),
            _kv('rootfs',
                i.rootfsInstalled ? i.rootfsPath : '未安装（点下方按钮初始化）'),
            _kv('proot', i.prootPath ?? '未找到（jniLibs 与 assets 均无）'),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(k,
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13)),
            ),
            Expanded(
                child: Text(v, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
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
              const Text('环境就绪', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('进入终端执行测试命令，或打开编辑器浏览/编辑项目文件。'),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => GridView.count(
                  crossAxisCount: constraints.maxWidth >= 560 ? 3 : 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 2.2,
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
                  ],
                ),
              ),
            ],
            if (env.installLog.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(env.installLog,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade400)),
            ],
            if (env.error != null) ...[
              const SizedBox(height: 8),
              Text(env.error!,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
          ],
        ),
      ),
    );
  }
}

/// 宫格操作块：图标置顶、文字居下，主操作高亮。
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
    return Material(
      color: primary ? cs.primary : cs.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 30,
                color: primary ? cs.onPrimary : cs.onSecondaryContainer),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: primary ? cs.onPrimary : cs.onSecondaryContainer)),
          ],
        ),
      ),
    );
  }
}
