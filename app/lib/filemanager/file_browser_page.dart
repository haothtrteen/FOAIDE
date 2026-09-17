import 'package:flutter/material.dart';

import '../env/proot_bridge.dart';
import 'fs_browser_bridge.dart';

/// Step 4 · 文件浏览器：浏览当前 app 的完整数据（rootfs 容器视角）。
///
/// 能力：
/// - 浏览：面包屑导航（点任意层级跳回）、返回上级、刷新、空目录占位；
/// - 解压：zip / tar.gz / tgz / tar.xz / tar → 解压到当前目录下的同名子目录
///   （走容器 exec，unzip/tar 已由工具链 apt 安装）；
/// - 导出：任意文件 → 系统保存对话框（SAF ACTION_CREATE_DOCUMENT）；
/// - 导入：系统文件选择器 → 容器 /root/imports（自动跳转过去，可直接解压）；
/// - CRUD：新建文件夹、重命名、删除（二次确认）。
///
/// 根目录 = 容器 /（= filesDir/rootfs/debian，app 的数据主体）；
/// 项目区 /root/projects、SDK /opt、导入区 /root/imports 都在其中。
class FileBrowserPage extends StatefulWidget {
  final FileBrowserBridge? bridge;
  final ProotBridge? proot;

  const FileBrowserPage({super.key, this.bridge, this.proot});

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  late final FileBrowserBridge _bridge = widget.bridge ?? FileBrowserBridge();
  late final ProotBridge _proot = widget.proot ?? ProotBridge();
  String _dir = '/'; // 当前浏览目录（容器内路径）
  List<FsBrowserEntry> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await _bridge.browse(_dir);
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

  bool get _canGoUp => _dir != '/';

  void _goUp() {
    if (!_canGoUp) return;
    setState(() {
      _dir = _dir == '/' ? '/' : _dir.substring(0, _dir.lastIndexOf('/'));
      if (_dir.isEmpty) _dir = '/';
    });
    _load();
  }

  void _enter(String path) {
    setState(() => _dir = path);
    _load();
  }

  /// 面包屑分段（含根）。如 /root/projects/a → ['/', '/root', '/root/projects', ...]。
  List<String> get _crumbs {
    final parts = _dir.split('/').where((s) => s.isNotEmpty).toList();
    final list = <String>['/'];
    var acc = '';
    for (final p in parts) {
      acc = '$acc/$p';
      list.add(acc);
    }
    return list;
  }

  void _onTap(FsBrowserEntry e) {
    if (e.isDir) {
      _enter(e.pathOf(_dir));
    }
  }

  // ---------------- 操作 ----------------

  /// 解压到当前目录下的同名子目录（重名自动加 -1/-2）。
  Future<void> _extract(FsBrowserEntry entry, String path) async {
    final lower = entry.name.toLowerCase();
    final String? tool;
    final String destFlag;
    if (lower.endsWith('.zip')) {
      tool = 'unzip -qo';
      destFlag = '-d';
    } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      tool = 'tar -xzf';
      destFlag = '-C';
    } else if (lower.endsWith('.tar.xz') || lower.endsWith('.txz')) {
      tool = 'tar -xJf';
      destFlag = '-C';
    } else if (lower.endsWith('.tar')) {
      tool = 'tar -xf';
      destFlag = '-C';
    } else {
      _toast('不支持的压缩格式（支持 zip / tar.gz / tar.xz / tar）');
      return;
    }
    // 目标目录：去掉扩展名的文件名；已存在则追加 -1/-2...
    var base = entry.name;
    for (final ext in ['.tar.gz', '.tar.xz', '.tgz', '.txz', '.zip', '.tar']) {
      if (base.toLowerCase().endsWith(ext)) {
        base = base.substring(0, base.length - ext.length);
        break;
      }
    }
    var dest = base.isEmpty ? 'extracted' : base;
    var destPath = _dir == '/' ? '/$dest' : '$_dir/$dest';
    var i = 1;
    while (_entries.any((e) => e.name == dest)) {
      dest = '$base-$i';
      destPath = _dir == '/' ? '/$dest' : '$_dir/$dest';
      i++;
    }

    // 确认对话框（大文件提示耗时）
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解压确认'),
        content: Text('将 "${entry.name}" 解压到\n"$destPath"？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解压'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    // 进度对话框（exec 阻塞期间显示，完成后关闭）
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ProgressDialog(message: '正在解压…'),
    );
    final r = await _proot.exec(
      'mkdir -p ${_q(destPath)} && '
      '$tool ${_q(path)} $destFlag ${_q(destPath)}',
      timeoutSec: 600,
    );
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关进度框
    if (r.exitCode == 0) {
      _toast('解压完成');
      _load();
    } else {
      final lines = r.stderr.trim().split('\n');
      final detail = lines.isEmpty ? '${r.exitCode}' : lines.last;
      _toast('解压失败：$detail');
    }
  }

  /// 导出文件到系统。
  Future<void> _export(FsBrowserEntry entry, String path) async {
    final r = await _bridge.export(path, entry.name);
    if (!mounted) return;
    _toast(r.ok ? '已导出' : (r.error ?? '导出失败'));
  }

  /// 导入文件：SAF 选择 → 落容器 /root/imports → 自动跳转过去。
  Future<void> _import() async {
    final r = await _bridge.pickImport();
    if (!mounted) return;
    if (!r.ok) {
      if (r.error != '已取消选择') _toast(r.error ?? '导入失败');
      return;
    }
    _toast('已导入 ${r.name}');
    setState(() => _dir = '/root/imports');
    _load();
  }

  /// 新建文件夹。
  Future<void> _createDir() async {
    final name = await _promptText(
      title: '新建文件夹',
      hint: '文件夹名称',
      confirmLabel: '创建',
    );
    if (name == null) return;
    final path = _dir == '/' ? '/$name' : '$_dir/$name';
    final r = await _bridge.mkdir(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '创建失败');
      return;
    }
    _load();
  }

  /// 重命名。
  Future<void> _rename(String path, String oldName) async {
    final name = await _promptText(
      title: '重命名',
      hint: '新名称',
      initial: oldName,
      confirmLabel: '重命名',
    );
    if (name == null || name == oldName) return;
    final r = await _bridge.rename(path, name);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '重命名失败');
      return;
    }
    _load();
  }

  /// 删除（二次确认）。
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
    final r = await _bridge.delete(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '删除失败');
      return;
    }
    _load();
  }

  /// 长按/更多菜单：解压、导出、重命名、删除。
  void _showMenu(FsBrowserEntry entry) {
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
            if (!entry.isDir) ...[
              ListTile(
                leading: const Icon(Icons.unarchive_outlined),
                title: const Text('解压到当前目录'),
                onTap: () {
                  Navigator.pop(ctx);
                  _extract(entry, path);
                },
              ),
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('导出到系统'),
                onTap: () {
                  Navigator.pop(ctx);
                  _export(entry, path);
                },
              ),
            ],
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

  // ---------------- 工具 ----------------

  /// shell 双引号转义（文件/目录名可能含空格等特殊字符）。
  String _q(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件浏览器'),
        actions: [
          IconButton(
            tooltip: '导入文件',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _loading ? null : _import,
          ),
          IconButton(
            tooltip: '新建文件夹',
            icon: const Icon(Icons.create_new_folder_outlined),
            onPressed: _loading ? null : _createDir,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildPathBar(),
            const Divider(height: 1),
            Expanded(child: _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildPathBar() {
    final crumbs = _crumbs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
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
                          crumbs[i] == '/' ? '/' : crumbs[i].split('/').last,
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
              '（空目录）',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
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

  Widget _buildEntry(FsBrowserEntry e) {
    return InkWell(
      onTap: () => _onTap(e),
      onLongPress: () => _showMenu(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(
              e.isDir ? Icons.folder_outlined : _fileIcon(e.name),
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
            IconButton(
              tooltip: '更多操作（解压 / 导出 / 重命名 / 删除）',
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

  IconData _fileIcon(String name) {
    final l = name.toLowerCase();
    if (l.endsWith('.zip') ||
        l.endsWith('.tar') ||
        l.endsWith('.tar.gz') ||
        l.endsWith('.tgz') ||
        l.endsWith('.tar.xz') ||
        l.endsWith('.txz')) {
      return Icons.archive_outlined;
    }
    if (l.endsWith('.apk')) return Icons.android;
    if (l.endsWith('.png') || l.endsWith('.jpg') || l.endsWith('.jpeg') || l.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    return Icons.description_outlined;
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 阻塞操作进度对话框（解压等）。
class _ProgressDialog extends StatelessWidget {
  final String message;
  const _ProgressDialog({required this.message});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          const SizedBox(width: 16),
          Text(message),
        ],
      ),
    );
  }
}
