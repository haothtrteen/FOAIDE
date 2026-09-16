import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'code_editor.dart';
import 'file_tree.dart';
import 'fs_bridge.dart';

/// Step 2 · 文件浏览器 + 代码编辑器。
///
/// 布局：文件浏览器以侧边栏形式嵌入编辑器——
/// 横屏常驻左栏（280px），竖屏收纳为 Drawer（AppBar 汉堡键展开），
/// 编辑区始终为主区域。
/// 文件 CRUD（新建/重命名/删除）在 FileTree 内自包含；
/// 本页负责打开文件、编辑、保存。
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

  Widget _buildTreePanel() {
    return FileTree(
      key: _treeKey,
      bridge: widget.bridge,
      onOpenFile: _openFile,
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
