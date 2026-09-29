import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/ai_assist.dart';
import '../ai/ai_backend.dart';
import '../core/theme.dart';
import '../editor/editor_page.dart';
import '../editor/file_tree.dart';
import '../editor/fs_bridge.dart';
import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../demo/project_importer.dart';
import '../toolchain/build_runner.dart';
import '../toolchain/termux_backend.dart';
import 'ai_takeover_panel.dart';
import 'build_panel.dart';
import 'design_page.dart';
import 'git_panel.dart';
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

/// 工作台分区。
///
/// ⚠️ **声明顺序即 `IndexedStack` 的 children 顺序**（见 [_buildSections]）。
/// 插入新分区时会平移后面所有成员的 `index`，必须同步改两处 switch 与 children。
enum _Section { overview, code, design, manifest, git, build, ai }

extension _SectionLabel on _Section {
  String get label => switch (this) {
        _Section.overview => '概览',
        _Section.code => '代码',
        // alpha.70：「设计」紧挨「代码」—— 两者都是在写界面，
        // 一个所见即所得、一个直接编辑，相邻才符合心智。
        _Section.design => '设计',
        _Section.manifest => '清单',
        // alpha.93：「版本」紧挨「清单」——改完包名/版本就该存一档，
        // 跟「清单」是同一件事的两半，中间隔着「打包」就接不上。
        _Section.git => '版本',
        _Section.build => '打包',
        _Section.ai => 'AI 接管',
      };

  IconData get icon => switch (this) {
        _Section.overview => Icons.info_outline,
        _Section.code => Icons.code,
        _Section.design => Icons.dashboard_customize_outlined,
        _Section.manifest => Icons.fact_check_outlined,
        _Section.git => Icons.history_outlined,
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

  /// AI 助手（alpha.81）：编辑器只上报「文本 + 光标」，补全还是派活、
  /// 发给谁，全在这一层决定——编辑器继续"不知道 AI 是什么"。
  ///
  /// 项目根必须是**容器内路径**：派活要写 `.foa/ai-inbox.md`，而编辑器
  /// 与 MCP 看到的是同一棵目录树（都是 /root/projects）。
  late final AiAssist _ai = AiAssist(
    bridge: _fb,
    projectRoot: '/root/projects/${widget.projectName}',
  );

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

  /// 设计区句柄（alpha.72）：打包完成后经它把生成的界面送去预览。
  ///
  /// 与 [_editorPageKey] / [_manifestKey] 同款用途 —— 从工作台这一层
  /// 触发内嵌页的动作，而不是让内嵌页自己猜用户想干什么。
  final GlobalKey<DesignPageState> _designKey = GlobalKey();

  // ---- 打包面板轮询（不碰 BuildRunner.onUiChanged——那是 BuildPage 的）----
  Timer? _uiTimer;

  /// 「导出源码工程」进行中（打包 + SAF 保存对话框）。
  bool _exporting = false;

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
    final mf =
        await _fb.read(_guestPath('android/app/src/main/AndroidManifest.xml'));
    if (mf.ok) {
      _label = ManifestCodec.parseManifest(mf.content).label;
    }
    for (final f in const [
      'android/app/build.gradle',
      'android/app/build.gradle.kts'
    ]) {
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

  // ============================ 导出源码工程 ============================

  /// 把当前工程打包成 `.tar.gz` 并保存到手机存储。
  ///
  /// 确认框里**必须列出排除的目录**：一个跑过几次构建的工程，`build/`
  /// 加 `.dart_tool/` 轻易超过 300MB，打包后只有 8MB —— 用户看到体积
  /// 差这么多，第一反应是"导出坏了/丢东西了"。先把话说在前面。
  ///
  /// 导出走 SAF（`ACTION_CREATE_DOCUMENT`），字节 1:1 落到用户选的位置，
  /// 所以排除清单是**正确性**问题不是优化问题 —— 详见
  /// [ProjectImporter.kPackExcludes]。
  Future<void> _exportSource() async {
    if (_exporting) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出源码工程'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('把工程「${widget.projectName}」打包成 .tar.gz 保存到手机。'),
            const SizedBox(height: 10),
            const Text('会排除这些构建缓存/IDE 配置：',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              ProjectImporter.kPackExcludes.map((e) => '· $e').join('\n'),
              style: TextStyle(fontSize: 11, color: FoaColors.of(ctx).muted),
            ),
            const SizedBox(height: 10),
            const Text('导入到本 App 或别的机器后，重新跑一次构建即可恢复这些目录。',
                style: TextStyle(fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('打包并保存'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _exporting = true);
    // 不复用 _ImportProgressDialog（那是 home_page 的私有 widget）：
    // 这里同样不可取消，但文案不同，且打包耗时更可预期。
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Text('正在打包源码…'),
            ],
          ),
        ),
      ),
    );
    final err = await ProjectImporter().packAndExport(widget.projectName);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关进度框
    setState(() => _exporting = false);
    _toast(err ?? '已导出源码工程（.tar.gz）');
  }

  // ============================ 骨架 ============================

  @override
  Widget build(BuildContext context) {
    final r = BuildRunner.I;
    // 打包中 500ms 刷新快照（构建轮询由 BuildRunner 守护 timer 驱动，
    // 这里只读状态；其它 section 不开 timer 零开销）
    final needTimer =
        _section == _Section.build && (r.building || _uiTimer != null);
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
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text(_section.label,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          // 「导出源码工程」：与下面清单保存按钮并列。放在 AppBar 而非
          // 「打包」区，是因为它导出的是**源码**、不是 APK —— 放打包区
          // 会和"构建产物"混为一谈。
          IconButton(
            tooltip: '导出源码工程（.tar.gz）',
            onPressed: _exporting ? null : _exportSource,
            icon: _exporting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share_outlined),
          ),
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
      // ⚠️ Bug 613：**禁止用 OrientationBuilder / MediaQuery.orientation
      // 判"要不要常驻侧栏"**。本 App 是 adjustResize：键盘一弹，
      // 窗口（连 MediaQuery.size 一起）被压矮 → 长宽比翻转成
      // "landscape" → 侧栏闪出又收回，且 body 的树从 `sections`
      // 变成 `Row(sections)`，**IndexedStack 的 Element 位置变了，
      // 六个区（含 AI 设置面板）的 State 全部销毁重建**——真机
      // 表现就是"模式跳回 MCP 又切回来、键盘回收、正在敲的 key 丢失"。
      //
      // 两道修法（都有测试守着）：
      // 1. 用**宽度阈值**判（键盘只压高度不压宽度，天然免疫）；
      // 2. 树结构**恒定**：Row + 条件 children，`sections` 的位置
      //    永远是 Row→Expanded→child，旋转也只增删兄弟，State 不丢。
      body: Builder(
        builder: (context) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_loadError.isNotEmpty) return _buildError();
          final wide = MediaQuery.sizeOf(context).width >= 600;
          return Row(
            children: [
              if (wide) SizedBox(width: 280, child: _buildSideTree()),
              if (wide) const VerticalDivider(width: 1),
              Expanded(child: _buildSections()),
            ],
          );
        },
      ),
    );
  }

  /// 七区 IndexedStack（alpha.35 融合，alpha.60 增「AI 接管」，
  /// alpha.70 增「设计」，alpha.93 增「版本」）：
  /// 全部保活——「代码」就地切换不丢编辑状态（未保存修改跨区保留），
  /// 打包区 timer 由 _section 驱动照常工作。编辑器为 embed 模式。
  ///
  /// ⚠️ children 顺序**必须与 [_Section] 枚举声明顺序一致**
  /// （IndexedStack 用 `_section.index` 定位）。
  /// 改这里的顺序 = 点「设计」跳到「打包」——不会编译错、不会抛异常，
  /// 只会静静地显示错的那一页。`manifest_page_test.dart` 里有断言守着。
  /// 编辑器 AI 按钮的后端实现（alpha.82）：本页只回答"AI 说了什么"，
  /// 写在哪、怎么回滚由编辑器页自己管——插入点只有它知道。
  Future<AiOutcome> _runAi(AiJob job) async {
    final out = await _ai.run(job);
    // 未配置时顺手把人领到设置去：AI 设置卡片就在本页的「AI 接管」区，
    // 内嵌编辑器没有 AppBar，自己摸不过去。
    if (out.kind == AiOutcomeKind.failure &&
        out.message == kAiUnconfiguredMessage &&
        mounted) {
      setState(() => _section = _Section.ai);
    }
    return out;
  }

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
          // alpha.82：状态栏 AI 按钮的两个交互——
          // 单点 = 让 AI 按当前代码补全；长按 = 输入要求派活。
          // [onRunAi] 交给编辑器页主导（预留空行 → 等结果 → 就地写入 →
          // 问存不存）；本页只提供"怎么跑 AI"，不碰插入点。
          onRunAi: _runAi,
          // 输入栏右上角的齿轮：回 AI 接管区（配置也在那）
          onOpenAiSettings: () => setState(() => _section = _Section.ai),
          // alpha.72：预览入口切到设计区。
          // 先切区、再等一帧让 DesignPage 挂上（IndexedStack 全保活，
          // 正常情况下 currentState 已存在）—— 顺序反过来的话
          // currentState 可能还是 null，用户点了没反应。
          onPreviewDesign: (path) => _previewInDesign(path),
          onPreviewProjectPages: () {
            setState(() => _section = _Section.design);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _designKey.currentState?.pickProjectPage();
            });
          },
        ),
        // alpha.70「设计」区：可视化拼界面 → 生成 Dart 代码落进 lib/generated/。
        // onOpenFile 与 manifest 同款——生成完直接跳「代码」区打开它，
        // 让用户能立刻接着改（生成物是起点不是终点）。
        DesignPage(
          key: _designKey,
          projectName: widget.projectName,
          bridge: _fb,
          onOpenFile: _openFile,
        ),
        ManifestPage(
          key: _manifestKey,
          projectName: widget.projectName,
          bridge: _fb,
          controller: _manifestCtl,
          onOpenFile: _openFile,
        ),
        // alpha.93「版本」区：容器内 git 的 status / add / commit / log。
        // 放在「打包」前面——提交完顺手就打包，路径最短。
        GitPanel(projectName: widget.projectName),
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

  /// 把某个文件送进设计区预览（编辑器预览菜单第一项）。
  ///
  /// ## 为什么先切区再等一帧
  ///
  /// `_section` 决定了 IndexedStack 显示哪一页。DesignPage 是保活的
  /// （六个区全在树上），所以切过去之后 `currentState` 立刻可用 ——
  /// 但这是"通常情况"。第一次启动时用户可能没进过设计区，
  /// 而 IndexedStack 的 children 是全量构建的，State 也确实已挂载。
  ///
  /// 仍然用 postFrameCallback 兜底：切区（setState）和读取
  /// `currentState` 如果挨得太近，在极端时序下可能读到切换前的对象。
  /// 一行等待换掉一个"点了没反应"的偶发 bug，值。
  void _previewInDesign(String path) {
    setState(() => _section = _Section.design);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _designKey.currentState?.importFrom(path);
    });
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
      // alpha.69：原为固定 `0xFF14181E` 深色。浅色主题下抽屉里用的是
      // 默认主题文字色（变深），深字压深底 → 文件名看不清（用户截图的
      // 直接症状）。改走 panelBg，浅色分支给 #FBFCFD。
      backgroundColor: FoaColors.of(context).panelBg,
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
                  // alpha.69：这四处的 `0xFF8A939E` 是"中灰"，在深色抽屉上
                  // 是刻意的弱化色；抽屉改走主题后必须跟着走语义位，
                  // 否则浅色底上会变成一块偏亮的灰，对比度不足。
                  Icon(Icons.folder_outlined,
                      size: 14, color: FoaColors.of(context).muted),
                  const SizedBox(width: 6),
                  Text('文件',
                      style: TextStyle(
                          fontSize: 11,
                          color: FoaColors.of(context).muted,
                          letterSpacing: 2)),
                  const Spacer(),
                  IconButton(
                    tooltip: '新建',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.add,
                        size: 16, color: FoaColors.of(context).muted),
                    onPressed: _showTreeCreateMenu,
                  ),
                  IconButton(
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.refresh,
                        size: 16, color: FoaColors.of(context).muted),
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
    final cs = Theme.of(context).colorScheme;
    final c = FoaColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.projectName,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text('项目工作台 · ${_pubName.isNotEmpty ? _pubName : "…"}',
              style: TextStyle(fontSize: 12, color: c.muted)),
        ],
      ),
    );
  }

  Widget _drawerItem(_Section s) {
    final cs = Theme.of(context).colorScheme;
    // alpha.69：选中态原为固定的暗绿 `0xFF173F35`（深色主题专用），
    // 浅色底上会是一块突兀的深绿。改用 M3 的 secondaryContainer ——
    // 它由种子色（同样是 Android 绿）派生，天然是"同色系但按亮度适配"，
    // 比再手调一组深/浅常量更不容易漂移。
    final selected = s == _section;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
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
                    color: selected
                        ? cs.onSecondaryContainer
                        : FoaColors.of(context).muted),
                const SizedBox(width: 16),
                Text(s.label,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color:
                            selected ? cs.onSecondaryContainer : cs.onSurface)),
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
  /// 关键状态（依赖缓存 / 最近构建 / 远程协助入口）都找不到。
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
        backendLabel:
            _backend == BuildBackend.termux ? 'Termux 裸原生（实验性）' : 'Proot 容器',
      ),
      onOpenCode: () => setState(() => _section = _Section.code),
      onOpenBuild: () => setState(() => _section = _Section.build),
      onOpenDesign: () => setState(() => _section = _Section.design),
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
  Future<void> _startBuild(BuildFlavor flavor) async {
    final env = _env;
    if (env == null || BuildRunner.I.building) return;
    await BuildRunner.I.start(widget.projectName, env, _backend,
        flavor: flavor);
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
