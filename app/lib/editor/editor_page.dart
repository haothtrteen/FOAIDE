import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import 'code_editor.dart';
import 'editor_last_file.dart';
import 'file_tree.dart';
import 'fs_bridge.dart';
import 'web_preview_page.dart';
import 'web_preview_service.dart';

/// Step 2 · 文件浏览器 + 代码编辑器。
///
/// 布局：文件浏览器以侧边栏形式嵌入编辑器——
/// 横屏常驻左栏（280px），竖屏收纳为 Drawer（AppBar 汉堡键展开），
/// 编辑区始终为主区域。
/// 文件 CRUD（新建/重命名/删除）在 FileTree 内自包含；
/// 本页负责打开文件、编辑、保存。
class EditorPage extends StatefulWidget {
  final FsBridge bridge;

  /// 初始浏览目录（alpha.33 项目工作台传入项目根）；缺省 = projects 根。
  final String? initialDir;

  /// 初始打开的文件（容器内路径）；缺省不打开。
  final String? initialPath;

  /// 内嵌模式（alpha.35 工作台融合）：不建 Scaffold/AppBar/Drawer，
  /// 输出「紧凑工具行 + 编辑面板」，供工作台内容区就地切换；
  /// 文件树由宿主提供（抽屉/横屏左栏），经 [EditorPageState.openFile]
  /// 联动。独立页模式（主页「编辑器」入口）完全不变。
  final bool embed;

  /// AI 助手入口（alpha.61）：透传给 [CodeEditor]，显示在状态栏字号那一栏。
  /// 由宿主注入回调（工作台把它接到 AI 接管面板），避免编辑器反向依赖
  /// 项目/MCP 等上层模块——编辑器保持"不知道 AI 是什么"的纯粹性。
  final VoidCallback? onAiAssist;

  EditorPage(
      {super.key, FsBridge? bridge, this.initialDir, this.initialPath,
      this.embed = false, this.onAiAssist})
      : bridge = bridge ?? FsBridge();

  @override
  State<EditorPage> createState() => EditorPageState();
}

class EditorPageState extends State<EditorPage> {
  final GlobalKey<FileTreeState> _treeKey = GlobalKey();
  final GlobalKey<CodeEditorState> _editorKey = GlobalKey();

  String? _currentPath; // 当前打开文件（容器内路径）
  String _content = '';
  String _initialContent = ''; // 打开时的初始内容（撤销更改恢复点）
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    // alpha.33 项目工作台：从指定文件直接进入编辑（首帧后打开，避免
    // build 前改状态；失败静默——编辑器照常空态展示）
    final p = widget.initialPath;
    if (p != null && p.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => openFile(p));
    } else if ((widget.initialDir ?? '').isNotEmpty) {
      // alpha.34 代码区融合：工作台「代码」直达编辑器时自动恢复——
      // 优先上次编辑的文件，无记录（或已删除）回退 lib/main.dart
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreLast());
    }
  }

  /// 恢复上次编辑位置：EditorLastFile 记录 → lib/main.dart 兜底。
  /// 先探测可读再打开（不弹"读取失败"toast——恢复失败静默降级）。
  Future<void> _restoreLast() async {
    final dir = widget.initialDir!;
    final last = await EditorLastFile.get(dir);
    if (last != null && last.isNotEmpty) {
      final probe = await widget.bridge.read(last);
      if (probe.ok) {
        if (mounted) await openFile(last);
        return;
      }
    }
    // 无记录（或上次文件已删）→ lib/main.dart 兜底；再没有就空态展示
    final fallbackPath = '$dir/lib/main.dart';
    final fallback = await widget.bridge.read(fallbackPath);
    if (fallback.ok && mounted) await openFile(fallbackPath);
  }

  // ---------------- 文件操作 ----------------

  Future<void> openFile(String path) async {
    if (path == _currentPath) return;
    final proceed = await _confirmSaveIfDirty();
    if (!proceed) return;
    final r = await widget.bridge.read(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '读取失败');
      return;
    }
    setState(() {
      _currentPath = path;
      _content = r.content;
      _initialContent = r.content;
      _dirty = false;
    });
    // 记住最后打开的文件（alpha.34）：下次直达编辑器自动恢复此位置
    final dir = widget.initialDir;
    if (dir != null && dir.isNotEmpty) EditorLastFile.set(dir, path);
    // 若从 Drawer（竖屏侧边栏）打开文件，收起抽屉让编辑器全屏可见
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isDrawerOpen) {
      Navigator.of(context).pop();
    }
  }

  Future<bool> _confirmSaveIfDirty() async {
    if (!_dirty) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: const Text('当前文件有未保存的修改，是否先保存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('放弃修改'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (choice == 'cancel') return false;
    if (choice == 'save') return await _save();
    return true; // discard
  }

  Future<bool> _save() async {
    if (_currentPath == null) return false;
    final r = await widget.bridge.write(_currentPath!, _content);
    if (!mounted) return false;
    if (!r.ok) {
      _toast(r.error ?? '保存失败');
      return false;
    }
    setState(() => _dirty = false);
    // alpha.59「保存即刷新」：预览运行中，保存本身就是最可靠的"文件
    // 变更"信号——直接热重载，替代手动按键/第三方文件监控工具
    //（flutsim 卖点的零成本实现：挂到保存动作上，无轮询）
    var msg = '已保存';
    if (WebPreviewService.I.status == WebPreviewStatus.running) {
      final err = await WebPreviewService.I.hotReload();
      if (err == null) msg = '已保存 · 已触发热重载';
    }
    _toast(msg);
    _treeKey.currentState?.reload();
    return true;
  }

  // ---------------- 顶栏操作（Bug 218） ----------------

  /// 撤销更改：编辑器内容与 dirty 状态恢复为打开时。
  void _revert() {
    if (_currentPath == null) return;
    _editorKey.currentState?.reset(_initialContent);
    setState(() {
      _content = _initialContent;
      _dirty = false;
    });
    _toast('已撤销更改');
  }

  /// 转到行：对话框输入行号 → 编辑器跳转。
  Future<void> _showGoToLine() async {
    final lineStr = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('转到行'),
          content: TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: const InputDecoration(
              hintText: '输入行号',
              isDense: true,
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('跳转'),
            ),
          ],
        );
      },
    );
    final line = int.tryParse(lineStr ?? '');
    if (line != null && line > 0) {
      _editorKey.currentState?.jumpToLine(line);
    }
  }

  /// 更多菜单：格式化 / 帮助链接。
  Future<void> _onMenuSelected(String value) async {
    switch (value) {
      case 'format':
        final err = await _editorKey.currentState?.formatCode();
        _toast(err ?? '格式化完成');
        break;
      case 'dart_docs':
        await _launchUrl('https://dart.dev/guides');
        break;
      case 'flutter_api':
        await _launchUrl('https://api.flutter.dev/');
        break;
    }
  }

  Future<void> _launchUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) _toast('无法打开链接');
  }

  // ---------------- 实时运行预览（alpha.57） ----------------

  /// 预览按钮：运行中单击 = 直达热重载（改代码后最短路径），
  /// 控制台入口放 SnackBar action；否则打开预览控制台页（idle 自动启动）。
  Future<void> _onPreviewTap() async {
    final svc = WebPreviewService.I;
    if (svc.status == WebPreviewStatus.running) {
      final err = await svc.hotReload();
      if (!mounted) return;
      if (err != null) {
        _toast(err);
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: const Text('已触发热重载'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '预览控制台',
            onPressed: () => _openPreviewPage(),
          ),
        ));
      return;
    }
    await _openPreviewPage();
  }

  Future<void> _openPreviewPage() async {
    final root = await _resolveProjectRoot();
    if (!mounted) return;
    if (root == null) {
      _toast('未定位到项目根（需先打开项目内文件）');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WebPreviewPage(projectRoot: root),
    ));
  }

  /// 定位当前编辑文件所属 Flutter 项目根（预览入口用）：
  /// 优先工作台传入的 initialDir（pubspec 校验），否则从当前文件
  /// 向上找 pubspec.yaml。探测走 Kotlin 文件通道（FsBridge.read），
  /// 不占 proot executor——预览/构建运行时该入口仍可用。
  Future<String?> _resolveProjectRoot() async {
    final dir = widget.initialDir;
    if (dir != null && dir.isNotEmpty) {
      final probe = await widget.bridge.read('$dir/pubspec.yaml');
      if (probe.ok) return dir;
    }
    final p = _currentPath;
    if (p == null) return null;
    const projectsRoot = '/root/projects';
    var d = p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : p;
    while (d.startsWith('$projectsRoot/') && d != projectsRoot) {
      final probe = await widget.bridge.read('$d/pubspec.yaml');
      if (probe.ok) return d;
      final idx = d.lastIndexOf('/');
      if (idx <= projectsRoot.length) break;
      d = d.substring(0, idx);
    }
    return null;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ---------------- 布局 ----------------

  @override
  Widget build(BuildContext context) {
    if (widget.embed) {
      // 内嵌模式（alpha.35 工作台融合）：无 Scaffold/AppBar/Drawer，
      // 输出「紧凑工具行 + 编辑面板」；文件树由宿主（工作台抽屉/
      // 横屏左栏）提供，openFile 跨组件联动。
      return _buildEmbedBody();
    }
    return OrientationBuilder(
      builder: (context, orientation) {
        final landscape = orientation == Orientation.landscape;
        return Scaffold(
          appBar: AppBar(
            // Bug 218：顶栏只显示当前文件名（完整路径放长按提示），
            // 长路径不再把按钮挤掉
            title: _currentPath == null
                ? const Text('项目文件')
                : Tooltip(
                    message: _currentPath!,
                    child: Text(
                      _currentPath!.split('/').last,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
            actions: _editorActions(),
          ),
          // 竖屏：文件浏览器收纳为侧边栏 Drawer（AppBar 自动显示汉堡键）。
          // 注意：Drawer 是全高浮层（从屏幕顶端开始），内容必须 SafeArea
          // 避让状态栏，否则顶部导航条与状态栏重叠（真机 Bug 213）。
          drawer: landscape
              ? null
              : Drawer(child: SafeArea(child: _buildTreePanel())),
          body: landscape
              ? Row(
                  children: [
                    SizedBox(width: 280, child: _buildTreePanel()),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildEditorPanel()),
                  ],
                )
              : _buildEditorPanel(),
        );
      },
    );
  }

  /// 编辑器动作组（独立页 AppBar 与内嵌工具行共用）。
  List<Widget> _editorActions({double iconSize = 24}) {
    return [
      if (_currentPath != null) ...[
        // 实时运行预览（alpha.57）：Web 预览入口；运行中变直达热重载键
        //（statusN 驱动变脸：绿 = 预览在跑）
        ValueListenableBuilder<WebPreviewStatus>(
          valueListenable: WebPreviewService.I.statusN,
          builder: (ctx, st, _) {
            final running = st == WebPreviewStatus.running;
            return IconButton(
              iconSize: iconSize,
              tooltip: running ? '热重载（Web 预览运行中）' : '实时运行预览（Web）',
              onPressed: _onPreviewTap,
              icon: Icon(
                running ? Icons.refresh : Icons.play_circle_outline,
                color: running ? const Color(0xFF3DDC84) : null,
              ),
            );
          },
        ),
        IconButton(
          iconSize: iconSize,
          tooltip: '撤销更改',
          onPressed: _dirty ? _revert : null,
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          iconSize: iconSize,
          tooltip: _dirty ? '应用更改（有未保存修改）' : '应用更改',
          onPressed: _save,
          icon: Icon(
            Icons.save_outlined,
            color: _dirty ? const Color(0xFF3DDC84) : null,
          ),
        ),
        IconButton(
          iconSize: iconSize,
          tooltip: '搜索',
          onPressed: () => _editorKey.currentState?.openSearch(),
          icon: const Icon(Icons.search),
        ),
        IconButton(
          iconSize: iconSize,
          tooltip: '转到行',
          onPressed: _showGoToLine,
          icon: const Icon(Icons.my_location),
        ),
        // 更多：格式化 / 帮助（Dart 手册、Flutter API）
        PopupMenuButton<String>(
          tooltip: '更多操作',
          onSelected: _onMenuSelected,
          itemBuilder: (ctx) => const [
            PopupMenuItem(
              value: 'format',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.auto_fix_high, size: 20),
                title: Text('格式化代码'),
              ),
            ),
            PopupMenuDivider(),
            PopupMenuItem(
              value: 'dart_docs',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.menu_book, size: 20),
                title: Text('Dart 官方手册'),
              ),
            ),
            PopupMenuItem(
              value: 'flutter_api',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.language, size: 20),
                title: Text('Flutter API 浏览器'),
              ),
            ),
          ],
        ),
      ],
    ];
  }

  /// 内嵌模式主体：紧凑工具行（文件名 + dirty 标记 + 动作组）+ 编辑面板。
  Widget _buildEmbedBody() {
    final path = _currentPath;
    return Column(
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: FoaTheme.consoleBg,
          child: Row(
            children: [
              Expanded(
                child: path == null
                    ? Text('未打开文件',
                        style:
                            TextStyle(fontSize: 13, color: Colors.grey.shade500))
                    : Tooltip(
                        message: path,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(path.split('/').last,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                            ),
                            if (_dirty) ...[
                              const SizedBox(width: 6),
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                    color: Color(0xFF3DDC84),
                                    shape: BoxShape.circle),
                              ),
                            ],
                          ],
                        ),
                      ),
              ),
              ..._editorActions(iconSize: 20),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildEditorPanel()),
      ],
    );
  }

  Widget _buildTreePanel() {
    return FileTree(
      key: _treeKey,
      bridge: widget.bridge,
      onOpenFile: openFile,
      initialDir: widget.initialDir,
    );
  }

  Widget _buildEditorPanel() {
    final path = _currentPath;
    if (path == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.code, size: 56, color: Colors.grey.shade700),
            const SizedBox(height: 12),
            Text(
              // 内嵌模式没有自己的 ☰：树在工作台抽屉/横屏左栏
              widget.embed ? '从工作台侧边文件树选择文件' : '从侧边栏选择文件开始编辑',
              style: TextStyle(color: Colors.grey.shade500),
            ),
            if (!widget.embed &&
                MediaQuery.of(context).orientation == Orientation.portrait)
              Text(
                '（点左上角 ☰ 打开文件浏览）',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
          ],
        ),
      );
    }
    return Container(
      color: FoaTheme.consoleBg,
      child: CodeEditor(
        // GlobalKey：顶栏撤销/搜索/跳转/格式化经 CodeEditorState 调用；
        // 切换文件由 didUpdateWidget（old.path != path）重建 controller
        key: _editorKey,
        path: path,
        initialContent: _content,
        onContentChanged: (t) {
          // 关键：把最新文本写回 EditorPage._content，保存时才有新内容
          // （Bug 215：此前只标记 dirty，保存写的是打开时的旧内容）
          _content = t;
          if (!_dirty) setState(() => _dirty = true);
        },
        // alpha.61：AI 入口由宿主注入；为 null 时编辑器不渲染该按钮
        onAiAssist: widget.onAiAssist,
      ),
    );
  }
}
