import 'package:flutter/material.dart';

import 'fs_bridge.dart';
import '../core/theme.dart';

/// 文件浏览器：目录浏览模式（Bug 212 升级）。
///
/// 交互：
/// - 点击目录 → 进入该目录（顶部面包屑显示当前路径，可点任意层级跳回）；
/// - 顶部 [..] 返回上一级目录；
/// - 点击文件 → onOpenFile 回调；
/// - 长按任意条目 → 底部菜单（在此新建/重命名/删除）；
/// - 空目录显示"（空文件夹）"占位，明确"已进入但无内容"。
///
/// CRUD 全部内聚在此组件：操作成功后自动刷新当前目录。
class FileTree extends StatefulWidget {
  final FsBridge bridge;

  /// 点击文件（叶子）回调，参数为文件完整路径。
  final void Function(String path) onOpenFile;

  /// 初始浏览目录（alpha.33 项目工作台传入项目根）；缺省 = projects 根。
  final String? initialDir;

  /// 紧凑模式（alpha.36 工作台抽屉/左栏）：隐藏顶部工具行（↑/面包屑/
  /// 刷新/新建——抽屉里双头部太挤、面包屑截断），锁定 [initialDir]
  /// 为根（子目录可进，↑ 到项目根为止不越界）；新建/重命名/删除仍走
  /// 每行 ⋮ 菜单，刷新与新建由宿主经 [reload]/[promptCreateFile]/
  /// [promptCreateDir] 提供。
  final bool minimal;

  const FileTree({
    super.key,
    required this.bridge,
    required this.onOpenFile,
    this.initialDir,
    this.minimal = false,
  });

  @override
  State<FileTree> createState() => FileTreeState();
}

class FileTreeState extends State<FileTree> {
  String _dir = kProjectsRoot; // 当前浏览目录
  List<FsEntry> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final init = widget.initialDir;
    if (init != null && init.isNotEmpty) _dir = init;
    _load();
  }

  /// 加载当前目录。外部（EditorPage 保存/删除后）可调用刷新。
  Future<void> reload() => _load();

  /// 在当前浏览目录新建文件（minimal 模式宿主按钮入口）。
  Future<void> promptCreateFile() => _createFile(_dir);

  /// 在当前浏览目录新建文件夹（minimal 模式宿主按钮入口）。
  Future<void> promptCreateDir() => _createDir(_dir);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await widget.bridge.list(_dir);
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _loading = false;
        _error = r.error;
      });
      return;
    }
    setState(() {
      _entries = r.entries;
      _loading = false;
    });
  }

  /// 浏览根：常规模式 = projects 根；minimal 模式锁定 initialDir
  ///（项目根）——抽屉里不允许浏览到项目外。
  String get _root =>
      widget.minimal && _hasInit ? widget.initialDir! : kProjectsRoot;
  bool get _hasInit =>
      widget.initialDir != null && widget.initialDir!.isNotEmpty;

  bool get _canGoUp => _dir != _root;

  void _goUp() {
    if (!_canGoUp) return;
    setState(() => _dir = _dir.substring(0, _dir.lastIndexOf('/')));
    _load();
  }

  void _enter(String path) {
    setState(() => _dir = path);
    _load();
  }

  /// 面包屑分段（含根）。如 /root/projects/a/b →
  /// ['/root/projects', '/root/projects/a', '/root/projects/a/b']
  List<String> get _crumbs {
    final parts = _dir.split('/').where((s) => s.isNotEmpty).toList();
    var acc = '';
    return [for (final p in parts) acc = '$acc/$p'];
  }

  void _onTap(FsEntry e) {
    if (e.isDir) {
      _enter(e.pathOf(_dir));
    } else {
      widget.onOpenFile(e.pathOf(_dir));
    }
  }

  // ---------------- CRUD ----------------

  void _showMenu(FsEntry entry) {
    final path = entry.pathOf(_dir);
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.name,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(path),
            ),
            const Divider(height: 1),
            if (entry.isDir) ...[
              ListTile(
                leading: const Icon(Icons.note_add_outlined),
                title: const Text('在此新建文件'),
                onTap: () {
                  Navigator.pop(ctx);
                  _createFile(path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('在此新建文件夹'),
                onTap: () {
                  Navigator.pop(ctx);
                  _createDir(path);
                },
              ),
            ] else
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('打开'),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onOpenFile(path);
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(path, entry.name);
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: Color(0xFFFF7A7A)),
              title: Text('删除', style: TextStyle(color: Colors.red.shade300)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(path, entry.name);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createFile(String parent) async {
    final name = await _promptText(
      title: '新建文件',
      hint: '文件名（如 main.dart）',
      confirmLabel: '创建',
    );
    if (name == null) return;
    final path = parent == '/' ? '/$name' : '$parent/$name';
    final r = await widget.bridge.write(path, '');
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '创建失败');
      return;
    }
    widget.onOpenFile(path);
    _load();
  }

  Future<void> _createDir(String parent) async {
    final name = await _promptText(
      title: '新建文件夹',
      hint: '文件夹名称',
      confirmLabel: '创建',
    );
    if (name == null) return;
    final path = parent == '/' ? '/$name' : '$parent/$name';
    final r = await widget.bridge.mkdir(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '创建失败');
      return;
    }
    _load();
  }

  Future<void> _rename(String path, String oldName) async {
    final name = await _promptText(
      title: '重命名',
      hint: '新名称',
      initial: oldName,
      confirmLabel: '重命名',
    );
    if (name == null || name == oldName) return;
    final r = await widget.bridge.rename(path, name);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '重命名失败');
      return;
    }
    _load();
  }

  Future<void> _delete(String path, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除 "$name"？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final r = await widget.bridge.delete(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '删除失败');
      return;
    }
    _load();
  }

  String? _validName(String s) {
    if (s.trim().isEmpty || s.contains('/') || s == '.' || s == '..') {
      return '名称无效（不能为空、不能含 /、不能为 . 或 ..）';
    }
    return null;
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
    required String confirmLabel,
    String? initial,
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: hint, errorText: error),
            onSubmitted: (v) {
              final err = _validName(v);
              if (err != null) {
                setDialogState(() => error = err);
                return;
              }
              Navigator.pop(ctx, v.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final err = _validName(controller.text);
                if (err != null) {
                  setDialogState(() => error = err);
                  return;
                }
                Navigator.pop(ctx, controller.text.trim());
              },
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
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

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final root = _root;
    final here = _dir == root ? '项目根' : _dir.substring(root.length + 1);
    return Column(
      children: [
        // minimal 模式（工作台抽屉/左栏）：无工具行，宿主提供刷新/新建；
        // 顶部一行迷你路径防"进了子目录迷路"（⋮ 菜单里也有完整路径）
        if (widget.minimal)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(here,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: FoaColors.of(context).muted)),
                ),
              ],
            ),
          ),
        if (!widget.minimal) ...[
          _buildPathBar(),
          const Divider(height: 1),
        ],
        Expanded(child: _buildList()),
      ],
    );
  }

  /// 顶部导航条：返回上级 + 面包屑 + 操作按钮。
  Widget _buildPathBar() {
    final crumbs = _crumbs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // ".." 返回上一级（根目录时禁用置灰）
              IconButton(
                tooltip: '返回上一级',
                onPressed: _canGoUp ? _goUp : null,
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < crumbs.length; i++) ...[
                        if (i > 0)
                          const Icon(Icons.chevron_right,
                              size: 14, color: Colors.grey),
                        InkWell(
                          onTap: () {
                            if (crumbs[i] != _dir) _enter(crumbs[i]);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 6),
                            child: Text(
                              i == 0 ? 'projects' : crumbs[i].split('/').last,
                              style: TextStyle(
                                fontSize: 12,
                                color: crumbs[i] == _dir
                                    ? const Color(0xFF3DDC84)
                                    : Colors.grey.shade400,
                                fontWeight: crumbs[i] == _dir
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _loading ? null : _load,
              ),
              IconButton(
                tooltip: '新建文件',
                icon: const Icon(Icons.note_add_outlined, size: 18),
                onPressed: () => _createFile(_dir),
              ),
              IconButton(
                tooltip: '新建文件夹',
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                onPressed: () => _createDir(_dir),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Color(0xFFFF7A7A)),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 40, color: Colors.grey.shade700),
            const SizedBox(height: 8),
            Text(
              '（空文件夹）',
              style:
                  TextStyle(color: FoaColors.of(context).muted, fontSize: 13),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, i) => _buildEntry(_entries[i]),
    );
  }

  Widget _buildEntry(FsEntry e) {
    return InkWell(
      onTap: () => _onTap(e),
      onLongPress: () => _showMenu(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(
              e.isDir ? Icons.folder_outlined : Icons.description_outlined,
              size: 18,
              color: e.isDir ? Colors.amber.shade300 : Colors.grey.shade400,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                e.name,
                style: const TextStyle(fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!e.isDir && e.size > 0)
              Text(
                _fmtSize(e.size),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            // "..." 入口：明确指示可在此重命名/删除（不再依赖长按发现）
            IconButton(
              tooltip: '更多操作（重命名 / 删除）',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const Icon(Icons.more_vert, size: 16, color: Colors.grey),
              onPressed: () => _showMenu(e),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
