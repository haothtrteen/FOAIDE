import 'package:flutter/material.dart';

import 'fs_bridge.dart';

/// 文件树节点（懒加载：children == null 表示尚未加载）。
class _Node {
  FsEntry entry;
  final String path;
  List<_Node>? children;
  bool expanded = false;

  _Node(this.entry, this.path);
}

/// 文件树：懒加载目录、点击打开文件、长按触发操作回调。
///
/// 自身不弹对话框——CRUD 操作由父级（EditorPage）统一管理，
/// 通过 [onNodeMenu] 回调把被长按的节点交出去，操作完成后调用 [reload]。
class FileTree extends StatefulWidget {
  final FsBridge bridge;

  /// 点击文件（叶子）回调。
  final void Function(String path) onOpenFile;

  /// 长按任意节点回调（父级弹菜单）。
  final void Function(FsEntry entry, String path, bool isDir) onNodeMenu;

  /// 空区域长按/工具栏新建（父级决定新建位置，默认根）。
  final VoidCallback? onCreateFile;
  final VoidCallback? onCreateDir;

  const FileTree({
    super.key,
    required this.bridge,
    required this.onOpenFile,
    required this.onNodeMenu,
    this.onCreateFile,
    this.onCreateDir,
  });

  @override
  State<FileTree> createState() => FileTreeState();
}

class FileTreeState extends State<FileTree> {
  final List<_Node> _roots = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRoot();
  }

  Future<void> _loadRoot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await widget.bridge.list(kProjectsRoot);
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _loading = false;
        _error = r.error;
      });
      return;
    }
    setState(() {
      _roots
        ..clear()
        ..addAll(r.entries.map((e) => _Node(e, e.pathOf(kProjectsRoot))));
      _loading = false;
    });
  }

  /// 重载根层 + 所有已展开目录（保持展开态）。CRUD 后调用。
  Future<void> reload() async {
    final r = await widget.bridge.list(kProjectsRoot);
    if (!r.ok || !mounted) return;
    final oldByName = {for (final n in _roots) n.entry.name: n};
    setState(() {
      _roots
        ..clear()
        ..addAll(r.entries.map((e) {
          final old = oldByName[e.name];
          if (old != null) {
            old.entry = e;
            return old;
          }
          return _Node(e, e.pathOf(kProjectsRoot));
        }));
    });
    for (final n in List.of(_roots)) {
      await _refreshIfExpanded(n);
    }
  }

  Future<void> _refreshIfExpanded(_Node node) async {
    if (!node.expanded) return;
    if (node.children == null) {
      await _expand(node);
      return;
    }
    final r = await widget.bridge.list(node.path);
    if (!r.ok || !mounted) return;
    final oldByName = {for (final c in node.children!) c.entry.name: c};
    setState(() {
      node.children = r.entries.map((e) {
        final old = oldByName[e.name];
        if (old != null) {
          old.entry = e;
          return old;
        }
        return _Node(e, e.pathOf(node.path));
      }).toList();
    });
    for (final c in List.of(node.children!)) {
      await _refreshIfExpanded(c);
    }
  }

  Future<void> _expand(_Node node) async {
    final r = await widget.bridge.list(node.path);
    if (!mounted) return;
    if (!r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(r.error ?? '加载目录失败')),
      );
      return;
    }
    setState(() {
      node.children =
          r.entries.map((e) => _Node(e, e.pathOf(node.path))).toList();
      node.expanded = true;
    });
  }

  void _toggle(_Node node) {
    if (node.entry.isDir) {
      if (node.expanded) {
        setState(() => node.expanded = false);
      } else if (node.children == null) {
        _expand(node);
      } else {
        setState(() => node.expanded = true);
      }
    } else {
      widget.onOpenFile(node.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _roots.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _roots.isEmpty) {
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
              OutlinedButton(onPressed: _loadRoot, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return ListView(
      children: [
        _buildHeader(),
        for (final node in _roots) ..._buildSubtree(node, 0),
      ],
    );
  }

  /// 递归渲染节点 + 展开的子节点（Bug：曾只渲染节点本身，
  /// node.children 从未输出，导致点击文件夹无内容显示）。
  List<Widget> _buildSubtree(_Node node, int depth) {
    final widgets = <Widget>[_buildNode(node, depth)];
    if (node.entry.isDir && node.expanded && node.children != null) {
      for (final child in node.children!) {
        widgets.addAll(_buildSubtree(child, depth + 1));
      }
    }
    return widgets;
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.folder, size: 18, color: Colors.amber),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              kProjectsRoot,
              style: TextStyle(fontSize: 12, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _loading ? null : reload,
          ),
          if (widget.onCreateFile != null)
            IconButton(
              tooltip: '新建文件',
              icon: const Icon(Icons.note_add_outlined, size: 18),
              onPressed: widget.onCreateFile,
            ),
          if (widget.onCreateDir != null)
            IconButton(
              tooltip: '新建文件夹',
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              onPressed: widget.onCreateDir,
            ),
        ],
      ),
    );
  }

  Widget _buildNode(_Node node, int depth) {
    final e = node.entry;
    return InkWell(
      onTap: () => _toggle(node),
      onLongPress: () => widget.onNodeMenu(e, node.path, e.isDir),
      child: Padding(
        padding: EdgeInsets.only(left: 8.0 + depth * 16.0, right: 4),
        child: Row(
          children: [
            Icon(
              e.isDir
                  ? (node.expanded
                      ? Icons.folder_open
                      : Icons.folder_outlined)
                  : Icons.description_outlined,
              size: 17,
              color: e.isDir ? Colors.amber.shade300 : Colors.grey.shade400,
            ),
            const SizedBox(width: 6),
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
            if (e.isDir && node.children == null)
              const Icon(Icons.chevron_right, size: 16, color: Colors.grey),
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
