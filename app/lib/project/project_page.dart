import 'dart:async';

import 'package:flutter/material.dart';

import '../editor/editor_page.dart';
import '../editor/file_tree.dart';
import '../editor/fs_bridge.dart';
import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../toolchain/build_runner.dart';
import '../toolchain/termux_backend.dart';
import 'ai_takeover_panel.dart';
import 'build_panel.dart';
import 'manifest_codec.dart';
import 'manifest_page.dart';
import 'project_preview.dart';

/// 项目工作台（alpha.33）：点工程卡片先到这里，而不是直接构建。
///
/// 布局模仿 FusionApp 风格：左侧抽屉切换「概览 / 代码 / 清单 / 打包」，
/// AppBar 副标题跟随当前区。各职责：
/// - 概览：项目元信息（pubspec + android 清单解析）+ 快捷入口；
/// - 代码：直达编辑器（alpha.34 融合——文件树在编辑器抽屉/左栏内，
///   自动恢复上次编辑文件，无记录回退 lib/main.dart；不再停留文件树页）；
/// - 清单：应用名称 / 包名 / 版本名 / 版本代码 / 权限（版本可编辑，
///   写回 pubspec 的 version 行——applicationId/label 只读防误改）；
/// - 打包：BuildRunner 单例的构建面板（同一会话与构建页/通知互通，
///   前台服务保活照常生效）+ 清理构建缓存（flutter clean）。
///
/// 与 BuildPage 的关系：BuildPage 仍是通知回跳/直达构建的完整页面；
/// 本页是"项目为中心"的工作台视图。构建状态都在 BuildRunner 全局单例，
/// 两边看到的进度一致。
class ProjectPage extends StatefulWidget {
  final String projectName;

  const ProjectPage({super.key, required this.projectName});

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

enum _Section { overview, code, manifest, build, ai }

extension _SectionLabel on _Section {
  String get label => switch (this) {
        _Section.overview => '概览',
        _Section.code => '代码',
        _Section.manifest => '清单',
        _Section.build => '打包',
        _Section.ai => 'AI 接管',
      };

  IconData get icon => switch (this) {
        _Section.overview => Icons.info_outline,
        _Section.code => Icons.code,
        _Section.manifest => Icons.fact_check_outlined,
        _Section.build => Icons.build_outlined,
        _Section.ai => Icons.smart_toy_outlined,
      };
}

class _ProjectPageState extends State<ProjectPage> {
  final FsBridge _fb = FsBridge();
  _Section _section = _Section.overview;

  /// 内嵌编辑器句柄（alpha.35 融合）：抽屉/左栏文件树经
  /// openFile 就地打开文件，页面不跳转。
  final GlobalKey<EditorPageState> _editorPageKey = GlobalKey();

  /// 文件树句柄（alpha.36）：抽屉标题行的刷新/新建经它操作列表。
  final GlobalKey<FileTreeState> _treeKey = GlobalKey();

  EnvInfo? _env;
  bool _loading = true;
  String _loadError = '';
  BuildBackend _backend = BuildBackend.proot;

  // ---- 清单快照（只读，供「预览」卡展示；编辑在 ManifestPage 内自持）----
  String _pubName = '';
  String _description = '';
  String _appId = '';
  String _label = '';
  String _verName = '';
  String _verCode = '';
  int _depCount = 0;

  /// 清单页状态句柄：驱动 AppBar 的保存按钮与跳区确认。
  final ManifestPageController _manifestCtl = ManifestPageController();

  /// 清单页句柄：AppBar 的保存按钮要触发页面内的保存流程。
  final GlobalKey<ManifestPageState> _manifestKey = GlobalKey();

  // ---- 打包面板轮询（不碰 BuildRunner.onUiChanged——那是 BuildPage 的）----
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    // 清单页保存成功后要立刻反映到「预览」卡（版本号/应用名），
    // 否则用户在两个区之间来回切会看到过期数据。
    _manifestCtl.addListener(_onManifestChanged);
    _load();
  }

  void _onManifestChanged() {
    // 从"脏"变"干净"= 刚保存完 → 重读快照
    if (!_manifestCtl.dirty && !_manifestCtl.saving && _manifestLoaded) {
      _refreshManifestSnapshot();
    }
    _manifestLoaded = true;
  }

  bool _manifestLoaded = false;

  @override
  void dispose() {
    _uiTimer?.cancel();
    _manifestCtl.removeListener(_onManifestChanged);
    _manifestCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = '';
    });
    try {
      final env = await ProotBridge().envInfo();
      final backend = await BackendPrefs.load(env);
      if (!env.rootfsInstalled) {
        if (!mounted) return;
        setState(() {
          _env = env;
          if (backend != null) _backend = backend;
          _loading = false;
        });
        return;
      }
      await _readManifest(env);
      if (!mounted) return;
      setState(() {
        _env = env;
        if (backend != null) _backend = backend;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '加载失败：$e';
      });
    }
  }

  String _guestPath(String rel) => '/root/projects/${widget.projectName}/$rel';

  /// 读取清单快照（只读），供「预览」卡展示。
  ///
  /// alpha.61：解析逻辑全部委托给 [ManifestCodec]（纯函数、有单测）。
  /// 这里以前是一堆就地写的正则，既没测过又和清单页各写一份、
  /// 容易改一处漏一处——现在两处共用同一套解析。
  Future<void> _readManifest(EnvInfo env) async {
    final pub = await _fb.read(_guestPath('pubspec.yaml'));
    if (pub.ok) {
      final r = ManifestCodec.parsePubspec(pub.content);
      _pubName = r.name.isEmpty ? widget.projectName : r.name;
      _description = r.description;
      _verName = r.verName;
      _verCode = r.verCode;
      _depCount = ManifestCodec.countDependencies(pub.content);
    }
    final mf = await _fb.read(_guestPath('android/app/src/main/AndroidManifest.xml'));
    if (mf.ok) {
      _label = ManifestCodec.parseManifest(mf.content).label;
    }
    for (final f in const ['android/app/build.gradle', 'android/app/build.gradle.kts']) {
      final g = await _fb.read(_guestPath(f));
      if (!g.ok) continue;
      final appId = ManifestCodec.parseGradle(g.content).appId;
      if (appId.isNotEmpty) {
        _appId = appId;
        break;
      }
    }
  }

  /// 清单页保存完成后刷新父页的快照（预览卡要立刻反映新版本号/新名字）。
  Future<void> _refreshManifestSnapshot() async {
    final env = _env;
    if (env == null) return;
    await _readManifest(env);
    if (mounted) setState(() {});
  }

  /// 在内嵌编辑器中打开文件（文件树/清单入口共用）。
  ///
  /// 先探测可读：路径不存在时直接提示，而不是打开一个空白编辑器
  /// 让用户以为"文件坏了"。
  Future<void> _openFile(String rel) async {
    final path = rel.startsWith('/') ? rel : _guestPath(rel);
    final probe = await _fb.read(path);
    if (!mounted) return;
    if (!probe.ok) {
      // 目录不可 read，交由编辑器自己处理（图标卡会传目录路径）
      if (rel.startsWith('/') || !rel.contains('.')) {
        setState(() => _section = _Section.code);
        _openInEmbed(path);
        return;
      }
      _toast('读取失败：${probe.error}');
      return;
    }
    _openInEmbed(path); // alpha.35：就地进内嵌编辑器，不跳页
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ============================ 骨架 ============================

  @override
  Widget build(BuildContext context) {
    final r = BuildRunner.I;
    // 打包中 500ms 刷新快照（构建轮询由 BuildRunner 守护 timer 驱动，
    // 这里只读状态；其它 section 不开 timer 零开销）
    final needTimer = _section == _Section.build &&
        (r.building || _uiTimer != null);
    if (needTimer && _uiTimer == null) {
      _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    }
    if (!needTimer && _uiTimer != null) {
      _uiTimer?.cancel();
      _uiTimer = null;
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.projectName,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text(_section.label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          // AppBar 的保存按钮与清单页底部悬浮条是同一件事的两个入口：
          // 大屏/横屏时底部条可能被键盘顶住，顶部这个更顺手。
          // 状态由 ManifestPageController 反向驱动（本页不持有清单数据）。
          if (_section == _Section.manifest)
            AnimatedBuilder(
              animation: _manifestCtl,
              builder: (context, _) => IconButton(
                tooltip: _manifestCtl.dirty ? '保存清单改动' : '没有未保存的改动',
                onPressed: _manifestCtl.dirty && !_manifestCtl.saving
                    ? () => _manifestKey.currentState?.save()
                    : null,
                icon: _manifestCtl.saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined),
              ),
            ),
        ],
      ),
      drawer: _buildDrawer(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError.isNotEmpty
              ? _buildError()
              : OrientationBuilder(
                  builder: (context, orientation) {
                    final landscape = orientation == Orientation.landscape;
                    final sections = _buildSections();
                    if (!landscape) return sections;
                    // 横屏：左栏常驻文件树（与编辑器页同一布局语言）
                    return Row(
                      children: [
                        SizedBox(width: 280, child: _buildSideTree()),
                        const VerticalDivider(width: 1),
                        Expanded(child: sections),
                      ],
                    );
                  },
                ),
    );
  }

  /// 五区 IndexedStack（alpha.35 融合，alpha.60 增「AI 接管」）：
  /// 全部保活——「代码」就地切换不丢编辑状态（未保存修改跨区保留），
  /// 打包区 timer 由 _section 驱动照常工作。编辑器为 embed 模式。
  ///
  /// ⚠️ children 顺序**必须与 [_Section] 枚举声明顺序一致**
  /// （IndexedStack 用 `_section.index` 定位）。
  Widget _buildSections() {
    return IndexedStack(
      index: _section.index,
      children: [
        _buildOverview(),
        EditorPage(
          key: _editorPageKey,
          embed: true,
          bridge: _fb,
          initialDir: '/root/projects/${widget.projectName}',
          // alpha.61：代码页状态栏的 AI 按钮 → 切到「AI 接管」区。
          // 就地切区而非弹新页：用户要的是"在当前上下文里用 AI"，
          // 跳出去会丢掉"我在哪个项目"的心理锚点（同 Bug 458 的教训）。
          onAiAssist: () => setState(() => _section = _Section.ai),
        ),
        ManifestPage(
          key: _manifestKey,
          projectName: widget.projectName,
          bridge: _fb,
          controller: _manifestCtl,
          onOpenFile: _openFile,
        ),
        _buildPanel(),
        AiTakeoverPanel(projectName: widget.projectName),
      ],
    );
  }

  /// 文件树面板（抽屉区块 / 横屏左栏共用）：点文件就地打开进内嵌
  /// 编辑器，不跳页。minimal 模式：无工具行、锁定项目根——
  /// 刷新/新建由上方标题行提供（经 _treeKey）。
  Widget _buildSideTree() {
    return FileTree(
      key: _treeKey,
      bridge: _fb,
      initialDir: '/root/projects/${widget.projectName}',
      minimal: true,
      onOpenFile: (path) {
        // 先收抽屉（横屏左栏无 Scaffold drawer，pop 无副作用由
        // maybeOf 判空兜住）——openFile 内的收抽屉逻辑只兜编辑器自身
        final scaffold = Scaffold.maybeOf(context);
        if (scaffold != null && scaffold.isDrawerOpen) {
          Navigator.of(context).pop();
        }
        _openInEmbed(path);
      },
    );
  }

  /// 文件树「新建」菜单（新建文件/文件夹，作用于当前浏览目录）。
  void _showTreeCreateMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('新建文件'),
            onTap: () {
              Navigator.pop(ctx);
              _treeKey.currentState?.promptCreateFile();
            },
          ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('新建文件夹'),
            onTap: () {
              Navigator.pop(ctx);
              _treeKey.currentState?.promptCreateDir();
            },
          ),
        ]),
      ),
    );
  }

  /// 在内嵌编辑器中打开文件（文件树/清单入口共用）。
  void _openInEmbed(String path) {
    setState(() => _section = _Section.code);
    _editorPageKey.currentState?.openFile(path);
  }

  Widget _buildError() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(_loadError,
              style: const TextStyle(color: Color(0xFFFF7A7A))),
        ),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _load,
        icon: const Icon(Icons.refresh),
        label: const Text('重试'),
      ),
    ]);
  }

  // ============================ 抽屉（模仿参考图 1） ============================

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF14181E),
      child: SafeArea(
        // alpha.35：上半导航 + 下半文件树（侧边栏单开一档）——
        // 抽屉里直接浏览项目文件，点文件就地进内嵌编辑器
        child: Column(
          children: [
            Expanded(
              flex: 4,
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  _drawerHeader(),
                  for (final s in _Section.values) _drawerItem(s),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 4, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.folder_outlined,
                      size: 14, color: Color(0xFF8A939E)),
                  const SizedBox(width: 6),
                  const Text('文件',
                      style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8A939E),
                          letterSpacing: 2)),
                  const Spacer(),
                  IconButton(
                    tooltip: '新建',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add, size: 16,
                        color: Color(0xFF8A939E)),
                    onPressed: _showTreeCreateMenu,
                  ),
                  IconButton(
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 16,
                        color: Color(0xFF8A939E)),
                    onPressed: () => _treeKey.currentState?.reload(),
                  ),
                ],
              ),
            ),
            Expanded(flex: 6, child: _buildSideTree()),
          ],
        ),
      ),
    );
  }

  Widget _drawerHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.projectName,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold,
                  color: Color(0xFFE6E6E6)),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text('项目工作台 · ${_pubName.isNotEmpty ? _pubName : "…"}',
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF8A939E))),
        ],
      ),
    );
  }

  Widget _drawerItem(_Section s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: s == _section
            ? const Color(0xFF173F35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            // alpha.35：「代码」与其他区统一——IndexedStack
            // 就地切换到内嵌编辑器，不再跳页
            setState(() => _section = s);
            Navigator.of(context).pop(); // 收起抽屉
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(s.icon,
                    size: 20,
                    color: s == _section
                        ? const Color(0xFF3DDC84)
                        : const Color(0xFF8A939E)),
                const SizedBox(width: 16),
                Text(s.label,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: s == _section
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: s == _section
                            ? const Color(0xFF3DDC84)
                            : const Color(0xFFC9CFD6))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================ 概览 ============================

  /// 概览区（alpha.61 重做）：委托给 [ProjectPreview]。
  ///
  /// 原实现只有「一张信息卡 + 两个快捷入口」，用户反馈界面太空、
  /// 关键状态（依赖缓存 / 最近构建 / 远程接管入口）都找不到。
  /// 现在把状态面板独立成文件，本页只负责喂数据 + 接管跳区。
  Widget _buildOverview() {
    return ProjectPreview(
      projectName: widget.projectName,
      env: _env,
      info: ManifestInfo(
        pubName: _pubName,
        label: _label,
        description: _description,
        appId: _appId,
        versionName: _verName,
        versionCode: _verCode,
        depCount: _depCount,
        backendLabel: _backend == BuildBackend.termux
            ? 'Termux 裸原生（实验性）'
            : 'Proot 容器',
      ),
      onOpenCode: () => setState(() => _section = _Section.code),
      onOpenBuild: () => setState(() => _section = _Section.build),
    );
  }

  // ============================ 代码 ============================
  // alpha.35 融合：代码区即 IndexedStack 里的内嵌 EditorPage（embed），
  // 文件树在抽屉下半区/横屏左栏（_buildSideTree），点文件就地打开；
  // 本节不再有自己的构建函数。


  // ============================ 打包 ============================

  /// 打包区（alpha.61 优化）：委托给 [BuildPanel]。
  ///
  /// 原实现把 UI 和构建控制混在一起（800 行的一个 State），
  /// 现在拆出去——本页只负责喂 env / backend 和转发"开始构建"。
  Widget _buildPanel() {
    return BuildPanel(
      projectName: widget.projectName,
      env: _env,
      backend: _backend,
      onStartBuild: _startBuild,
      onBackendChanged: _switchBackend,
    );
  }

  /// 开始构建。
  ///
  /// alpha.61：通知开关的提示移到了 BuildPanel（那是它的界面责任），
  /// 这里只做真正的事——交给 BuildRunner。
  Future<void> _startBuild() async {
    final env = _env;
    if (env == null || BuildRunner.I.building) return;
    await BuildRunner.I.start(widget.projectName, env, _backend);
    if (mounted) setState(() {});
  }

  /// 切换构建后端（写盘持久化，下次进来还是这个）。
  Future<void> _switchBackend(BuildBackend b) async {
    final env = _env;
    if (b == _backend || env == null) return;
    setState(() => _backend = b);
    await BackendPrefs.save(env, b);
  }

}
