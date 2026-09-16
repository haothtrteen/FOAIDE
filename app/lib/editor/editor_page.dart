import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'code_editor.dart';
import 'file_tree.dart';
import 'fs_bridge.dart';

/// Step 2 · 文件树 + 代码编辑器。
///
/// 布局：文件浏览器以侧边栏形式嵌入编辑器——
/// 横屏常驻左栏（280px），竖屏收纳为 Drawer（AppBar 汉堡键展开），
/// 编辑区始终为主区域。
/// 编辑器单文件模式：切换文件前若有未保存修改会弹确认。
class EditorPage extends StatefulWidget {
  final FsBridge bridge;
  EditorPage({super.key, FsBridge? bridge}) : bridge = bridge ?? FsBridge();

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final GlobalKey<FileTreeState> _treeKey = GlobalKey();

  String? _currentPath; // 当前打开文件（容器内路径）
  String _content = '';
  bool _dirty = false;

  // ---------------- 文件操作 ----------------

  Future<void> _openFile(String path) async {
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
      _dirty = false;
    });
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
    _toast('已保存');
    _treeKey.currentState?.reload();
    return true;
  }

  // ---------------- 树操作菜单 ----------------

  void _showNodeMenu(FsEntry entry, String path, bool isDir) {
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
            if (isDir) ...[
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
                  _openFile(path);
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
              leading: const Icon(Icons.delete_outline,
                  color: Color(0xFFFF7A7A)),
              title: Text('删除',
                  style: TextStyle(color: Colors.red.shade300)),
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
      hint: '文件名（如 hello.dart）',
      confirmLabel: '创建',
      validate: _validName,
    );
    if (name == null) return;
    final path = parent == '/' ? '/$name' : '$parent/$name';
    final r = await widget.bridge.write(path, '');
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '创建失败');
      return;
    }
    _treeKey.currentState?.reload();
    _openFile(path);
  }

  Future<void> _createDir(String parent) async {
    final name = await _promptText(
      title: '新建文件夹',
      hint: '文件夹名称',
      confirmLabel: '创建',
      validate: _validName,
    );
    if (name == null) return;
    final path = parent == '/' ? '/$name' : '$parent/$name';
    final r = await widget.bridge.mkdir(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '创建失败');
      return;
    }
    _treeKey.currentState?.reload();
  }

  Future<void> _rename(String path, String oldName) async {
    final name = await _promptText(
      title: '重命名',
      hint: '新名称',
      initial: oldName,
      confirmLabel: '重命名',
      validate: _validName,
    );
    if (name == null || name == oldName) return;
    final r = await widget.bridge.rename(path, name);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '重命名失败');
      return;
    }
    if (path == _currentPath) {
      final parts = path.split('/')..removeLast();
      setState(() => _currentPath = '${parts.join('/')}/$name');
    }
    _treeKey.currentState?.reload();
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
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
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
    if (path == _currentPath) {
      setState(() {
        _currentPath = null;
        _content = '';
        _dirty = false;
      });
    }
    _treeKey.currentState?.reload();
  }

  /// 名称校验：返回 null 表示合法，否则返回错误提示。
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
    String? Function(String)? validate,
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
              final err = validate?.call(v);
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
                final err = validate?.call(controller.text);
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

  // ---------------- 布局 ----------------

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(
      builder: (context, orientation) {
        final landscape = orientation == Orientation.landscape;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _currentPath == null ? '项目文件' : _currentPath!,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (_currentPath != null)
                IconButton(
                  tooltip: _dirty ? '保存（有未保存修改）' : '保存',
                  onPressed: _save,
                  icon: Icon(
                    Icons.save_outlined,
                    color: _dirty ? const Color(0xFF3DDC84) : null,
                  ),
                ),
            ],
          ),
          // 竖屏：文件浏览器收纳为侧边栏 Drawer（AppBar 自动显示汉堡键）
          drawer: landscape ? null : Drawer(child: _buildTreePanel()),
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

  Widget _buildTreePanel() {
    return Column(
      children: [
        Expanded(
          child: FileTree(
            key: _treeKey,
            bridge: widget.bridge,
            onOpenFile: _openFile,
            onNodeMenu: _showNodeMenu,
            onCreateFile: () => _createFile(kProjectsRoot),
            onCreateDir: () => _createDir(kProjectsRoot),
          ),
        ),
      ],
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
              '从侧边栏选择文件开始编辑',
              style: TextStyle(color: Colors.grey.shade500),
            ),
            if (MediaQuery.of(context).orientation == Orientation.portrait)
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
        key: ValueKey(path),
        path: path,
        initialContent: _content,
        onContentChanged: (t) {
          if (!_dirty) setState(() => _dirty = true);
        },
      ),
    );
  }
}
