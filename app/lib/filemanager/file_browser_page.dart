import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'fs_browser_bridge.dart';

/// Step 4 · 文件浏览器：浏览当前 app 的完整数据。
///
/// 三个浏览域（域 = 路径语义空间，切换靠虚拟根入口）：
/// - 容器域（container）：rootfs 视角（/ 开头 = filesDir/rootfs/debian/...），
///   项目区 /root/projects、SDK /opt、导入区 /root/imports 都在其中；解压仅此域；
/// - 宿主域（host）：真实文件系统（filesDir / Android/data/<pkg>），原生白名单校验；
/// - 虚拟根（virtual）：根目录再返回上一级到达，展示各区域入口 + 项目工作区同步。
///
/// Step 5 项目工作区（W^X 限制，见 foa-build-verify §十三）：
/// - 构建位置 = 容器 /root/projects（= filesDir，可执行）；
/// - 用户编辑位置 = 外部存储 Android/data/<pkg>/projects（文件管理器/USB 可见）；
/// - 虚拟根提供双向同步：编辑后「外部 → 容器」再构建；「容器 → 外部」迁移/备份。
///
/// 返回键语义：子目录内系统返回键 → 返回上一级目录；左上角箭头 → 退出浏览器。
///
/// 能力：浏览（面包屑/返回上级/刷新）、解压（zip/tar*，容器 exec）、导出（SAF）、
/// 导入（SAF → 容器 /root/imports）、新建/重命名/删除、复制/移动/粘贴（文件与目录
/// 通用，支持跨域——容器 ↔ 宿主经 rootfsPath 前缀互转）。
class FileBrowserPage extends StatefulWidget {
  final FileBrowserBridge? bridge;
  final ProotBridge? proot;

  const FileBrowserPage({super.key, this.bridge, this.proot});

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

enum _Domain { virtual, container, host }

/// 剪贴板项（复制/移动）。path 为当前域语义路径。
class _Clip {
  final String path;
  final bool isCut;
  const _Clip({required this.path, required this.isCut});
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  static const _virtualRoot = 'virtual://';

  late final FileBrowserBridge _bridge = widget.bridge ?? FileBrowserBridge();
  late final ProotBridge _proot = widget.proot ?? ProotBridge();

  String _dir = '/'; // 当前浏览目录（容器 /… / 宿主真实路径 / virtual://）
  _Domain _domain = _Domain.container;
  List<FsBrowserEntry> _entries = [];
  bool _loading = true;
  String? _error;
  EnvInfo _env = const EnvInfo(
    filesDir: '',
    cacheDir: '',
    nativeLibraryDir: '',
    rootfsPath: '',
    rootfsInstalled: false,
  );
  _Clip? _clip; // 复制/移动剪贴板
  bool _syncing = false; // 项目工作区同步中（禁用按钮 + 进度框）

  bool get _isVirtual => _dir == _virtualRoot;

  @override
  void initState() {
    super.initState();
    _loadEnv();
  }

  Future<void> _loadEnv() async {
    final env = await _proot.envInfo();
    if (!mounted) return;
    setState(() => _env = env);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = _isVirtual
        ? const FsBrowseResult(ok: true)
        : _domain == _Domain.container
            ? await _bridge.browse(_dir)
            : await _bridge.hostBrowse(_dir);
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

  // ---------------- 路径/域导航 ----------------

  bool get _canGoUp {
    if (_isVirtual) return false;
    // 容器域 '/'、宿主域根（filesDir / externalDataDir）再返回 → 虚拟根
    return true;
  }

  List<String> get _hostRoots => [
        _env.filesDir,
        if (_env.externalDataDir != null) _env.externalDataDir!,
      ].where((p) => p.isNotEmpty).toList();

  /// 外部存储项目工作区：Android/data/<pkg>/projects（用户可见；无外部存储为 null）。
  String? get _externalProjects => _env.externalDataDir == null
      ? null
      : '${_env.externalDataDir}/projects';

  void _goUp() {
    if (_isVirtual) return;
    if (_domain == _Domain.container) {
      if (_dir == '/') {
        setState(() {
          _domain = _Domain.virtual;
          _dir = _virtualRoot;
        });
        _load();
        return;
      }
      setState(() {
        _dir = _dir.substring(0, _dir.lastIndexOf('/'));
        if (_dir.isEmpty) _dir = '/';
      });
      _load();
      return;
    }
    // 宿主域
    if (_hostRoots.contains(_dir)) {
      setState(() {
        _domain = _Domain.virtual;
        _dir = _virtualRoot;
      });
      _load();
      return;
    }
    setState(() {
      _dir = _dir.substring(0, _dir.lastIndexOf('/'));
    });
    _load();
  }

  /// 进入子目录（保持当前域）。
  void _enter(FsBrowserEntry e) {
    setState(() {
      _dir = _domain == _Domain.container
          ? e.pathOf(_dir)
          : '$_dir/${e.name}';
    });
    _load();
  }

  /// 虚拟根入口跳转。
  void _jumpTo({required _Domain domain, required String path}) {
    setState(() {
      _domain = domain;
      _dir = path;
    });
    _load();
  }

  // ---------------- 解压 / 导入 / 导出 ----------------

  Future<void> _extract(FsBrowserEntry entry, String path) async {
    if (_domain != _Domain.container) {
      _toast('解压仅支持容器内文件（可在虚拟根进入「根目录」后操作）');
      return;
    }
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
    Navigator.of(context, rootNavigator: true).pop();
    if (r.exitCode == 0) {
      _toast('解压完成');
      _load();
    } else {
      final lines = r.stderr.trim().split('\n');
      final detail = lines.isEmpty ? '${r.exitCode}' : lines.last;
      _toast('解压失败：$detail');
    }
  }

  Future<void> _export(FsBrowserEntry entry, String path) async {
    final r = await _bridge.export(path, entry.name);
    if (!mounted) return;
    _toast(r.ok ? '已导出' : (r.error ?? '导出失败'));
  }

  Future<void> _import() async {
    final r = await _bridge.pickImport();
    if (!mounted) return;
    if (!r.ok) {
      if (r.error != '已取消选择') _toast(r.error ?? '导入失败');
      return;
    }
    _toast('已导入 ${r.name}');
    setState(() {
      _domain = _Domain.container;
      _dir = '/root/imports';
    });
    _load();
  }

  // ---------------- Step 5 · 项目工作区同步 ----------------

  /// 双向同步：toContainer = 外部工作区 → 容器 /root/projects（编辑后构建前）；
  /// toExternal = 容器 → 外部工作区（首次迁移 / 备份到用户可见区）。
  Future<void> _syncProjects(String direction) async {
    final isToContainer = direction == 'toContainer';
    setState(() => _syncing = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProgressDialog(
        message: isToContainer ? '正在同步到容器…' : '正在导出到外部存储…',
      ),
    );
    final r = await _bridge.syncProjects(direction);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关闭进度框
    setState(() => _syncing = false);
    if (!r.ok) {
      _toast(r.error ?? '同步失败');
      return;
    }
    final skipNote = r.skipped > 0 ? '（跳过构建缓存 ${r.skipped} 个）' : '';
    _toast(
      '${isToContainer ? '已同步到容器' : '已导出到外部'}：${r.files} 个文件'
      ' ${_fmtSize(r.bytes)}$skipNote',
    );
    _load();
  }

  // ---------------- 复制 / 移动 / 粘贴 ----------------

  void _copyEntry(FsBrowserEntry entry, String path) {
    setState(() => _clip = _Clip(path: path, isCut: false));
    _toast('已复制：${entry.name}（到目标目录粘贴）');
  }

  void _moveEntry(FsBrowserEntry entry, String path) {
    setState(() => _clip = _Clip(path: path, isCut: true));
    _toast('已剪切：${entry.name}（到目标目录粘贴）');
  }

  void _clearClip() => setState(() => _clip = null);

  /// 容器路径 ↔ 宿主真实路径互转（rootfsPath 前缀）。
  String _containerToHost(String guest) =>
      guest == '/' ? _env.rootfsPath : '${_env.rootfsPath}$guest';

  String? _hostToContainer(String real) {
    final rp = _env.rootfsPath;
    if (real == rp) return '/';
    if (real.startsWith('$rp/')) return real.substring(rp.length);
    return null; // 不在 rootfs 内，无法转容器路径
  }

  /// 粘贴：源（_clip，含其域）→ 当前目录（目标域）。同域直调；跨域先转路径。
  Future<void> _paste() async {
    final clip = _clip;
    if (clip == null || _isVirtual) return;

    final srcDomain = _domainOf(clip.path);
    final dstDomain = _domain;
    final dstDir = _dir;
    final targetName = clip.path.split('/').last;

    String? srcPath; // 原生操作需要的路径（容器路径或真实路径）
    String? dstPath;
    bool useHost = false;
    try {
      if (srcDomain == _Domain.container && dstDomain == _Domain.container) {
        srcPath = clip.path;
        dstPath = '$dstDir/$targetName';
      } else if (srcDomain == _Domain.host && dstDomain == _Domain.host) {
        useHost = true;
        srcPath = clip.path;
        dstPath = '$dstDir/$targetName';
      } else if (srcDomain == _Domain.container && dstDomain == _Domain.host) {
        useHost = true;
        srcPath = _containerToHost(clip.path);
        dstPath = '$dstDir/$targetName';
      } else if (srcDomain == _Domain.host && dstDomain == _Domain.container) {
        final guest = _hostToContainer(clip.path);
        if (guest == null) {
          _toast('该文件不在容器内，无法粘贴到容器（可用「导出」到系统再导入）');
          return;
        }
        srcPath = guest;
        dstPath = '$dstDir/$targetName';
      } else {
        return;
      }
    } catch (_) {
      _toast('路径转换失败');
      return;
    }

    final r = useHost
        ? (clip.isCut
            ? await _bridge.hostMove(srcPath, dstPath)
            : await _bridge.hostCopy(srcPath, dstPath))
        : (clip.isCut
            ? await _bridge.move(srcPath, dstPath)
            : await _bridge.copy(srcPath, dstPath));
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '操作失败');
      return;
    }
    _toast(clip.isCut ? '已移动' : '已复制');
    if (clip.isCut) _clearClip();
    _load();
  }

  _Domain _domainOf(String path) {
    if (path == _virtualRoot) return _Domain.virtual;
    return _hostRoots.any((r) => path == r || path.startsWith('$r/'))
        ? _Domain.host
        : _Domain.container;
  }

  // ---------------- CRUD ----------------

  Future<void> _createDir() async {
    if (_isVirtual) return;
    final name = await _promptText(
      title: '新建文件夹',
      hint: '文件夹名称',
      confirmLabel: '创建',
    );
    if (name == null) return;
    final path = _domain == _Domain.container
        ? (_dir == '/' ? '/$name' : '$_dir/$name')
        : '$_dir/$name';
    final r = _domain == _Domain.container
        ? await _bridge.mkdir(path)
        : await _bridge.hostMkdir(path);
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
    final r = _domain == _Domain.container
        ? await _bridge.rename(path, name)
        : await _bridge.hostRename(path, name);
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
    final r = _domain == _Domain.container
        ? await _bridge.delete(path)
        : await _bridge.hostDelete(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '删除失败');
      return;
    }
    _load();
  }

  void _showMenu(FsBrowserEntry entry) {
    final path = _domain == _Domain.container
        ? entry.pathOf(_dir)
        : '$_dir/${entry.name}';
    final canExtract = !entry.isDir && _domain == _Domain.container;
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
            if (canExtract)
              ListTile(
                leading: const Icon(Icons.unarchive_outlined),
                title: const Text('解压到当前目录'),
                onTap: () {
                  Navigator.pop(ctx);
                  _extract(entry, path);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('复制'),
              onTap: () {
                Navigator.pop(ctx);
                _copyEntry(entry, path);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('移动'),
              onTap: () {
                Navigator.pop(ctx);
                _moveEntry(entry, path);
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
    return PopScope<Object?>(
      // 子目录内：系统返回键 → 返回上一级目录；虚拟根（_canGoUp=false）→ 正常退出。
      // 左上角箭头为显式退出（Navigator.pop 绕过 PopScope，见 SDK navigator.dart）。
      canPop: !_canGoUp,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '退出文件浏览器',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text('文件浏览器'),
          actions: [
            if (_clip != null)
              IconButton(
                tooltip: _clip!.isCut ? '粘贴（移动）' : '粘贴（复制）',
                icon: const Icon(Icons.content_paste_go),
                onPressed: _isVirtual || _loading ? null : _paste,
              ),
            if (_clip != null)
              IconButton(
                tooltip: '取消剪贴板',
                icon: const Icon(Icons.close),
                onPressed: _clearClip,
              ),
            IconButton(
              tooltip: '导入文件（到容器 /root/imports）',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: _loading ? null : _import,
            ),
            IconButton(
              tooltip: '新建文件夹',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: _isVirtual || _loading ? null : _createDir,
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
              Expanded(child: _isVirtual ? _buildVirtualRoot() : _buildList()),
            ],
          ),
        ),
      ),
    );
  }

  /// 虚拟根：根目录再返回上一级后显示的入口页（各数据区域 + 项目工作区同步）。
  Widget _buildVirtualRoot() {
    final extProjects = _externalProjects;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            '虚拟上级目录：从这里可跳转到 app 的不同数据区域',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
        ),
        _VirtualEntryTile(
          icon: Icons.folder_special_outlined,
          title: '根目录',
          subtitle: '容器完整文件系统（rootfs）：项目区 /root/projects、SDK /opt、导入区 /root/imports',
          onTap: () =>
              _jumpTo(domain: _Domain.container, path: '/'),
        ),
        _VirtualEntryTile(
          icon: Icons.code_outlined,
          title: '项目目录',
          subtitle: '一键跳转容器内 /root/projects（编辑器工作区 / 构建位置）',
          onTap: () =>
              _jumpTo(domain: _Domain.container, path: '/root/projects'),
        ),
        if (extProjects != null)
          _VirtualEntryTile(
            icon: Icons.folder_shared_outlined,
            title: '项目工作区（外部存储）',
            subtitle: '$_envDirLabel(extProjects)（文件管理器/USB 可见，可编辑）',
            onTap: () async {
              // 首次进入自动创建外部工作区（mkdirs 幂等；已存在时原生返回「已存在」，忽略）
              await _bridge.hostMkdir(extProjects);
              if (!mounted) return;
              _jumpTo(domain: _Domain.host, path: extProjects);
            },
          ),
        _VirtualEntryTile(
          icon: Icons.storage_outlined,
          title: 'app 自身 /data 目录',
          subtitle: '应用内部私有数据（filesDir）：$_envDirLabel(_env.filesDir)',
          onTap: _env.filesDir.isEmpty
              ? null
              : () => _jumpTo(domain: _Domain.host, path: _env.filesDir),
        ),
        _VirtualEntryTile(
          icon: Icons.sd_storage_outlined,
          title: 'app 自身 Android/data 目录',
          subtitle: _env.externalDataDir == null
              ? '当前设备无外部存储'
              : '外部存储应用目录：$_envDirLabel(_env.externalDataDir!)',
          onTap: _env.externalDataDir == null
              ? null
              : () => _jumpTo(
                    domain: _Domain.host,
                    path: _env.externalDataDir!,
                  ),
        ),
        if (extProjects != null) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '项目工作区同步（W^X 限制：构建必须在容器内执行）',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.upload_file_outlined, size: 16),
                    label: const Text('外部 → 容器（构建前）',
                        style: TextStyle(fontSize: 12)),
                    onPressed: _syncing
                        ? null
                        : () => _syncProjects('toContainer'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: const Text('容器 → 外部（备份）',
                        style: TextStyle(fontSize: 12)),
                    onPressed: _syncing
                        ? null
                        : () => _syncProjects('toExternal'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '在外部工作区（文件管理器/USB 可见）编辑代码后，点「外部 → 容器」同步进容器再构建；'
              '已有项目点「容器 → 外部」迁移到用户可见区。',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            ),
          ),
        ],
      ],
    );
  }

  String _envDirLabel(String real) {
    final f = _env.filesDir;
    if (real == f) return '/data/user/0/<pkg>';
    final e = _env.externalDataDir;
    if (e != null && real == e) return '/storage/emulated/0/Android/data/<pkg>';
    if (e != null && real == '$e/projects') {
      return '/storage/emulated/0/Android/data/<pkg>/projects';
    }
    return real;
  }

  Widget _buildPathBar() {
    if (_isVirtual) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            IconButton(
              tooltip: '返回上一级',
              onPressed: null,
              icon: Icon(Icons.arrow_upward, size: 18),
            ),
            Text(
              '虚拟根',
              style: TextStyle(fontSize: 13, color: Color(0xFF3DDC84)),
            ),
          ],
        ),
      );
    }
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
                        if (crumbs[i] != _dir) _jumpToPath(crumbs[i]);
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

  /// 面包屑：容器域按 / 分段；宿主域整路径显示（前缀已用虚拟根说明，此处
  /// 显示真实路径，便于区分内部/外部存储）。
  List<String> get _crumbs {
    if (_domain == _Domain.container) {
      final parts = _dir.split('/').where((s) => s.isNotEmpty).toList();
      final list = <String>['/'];
      var acc = '';
      for (final p in parts) {
        acc = '$acc/$p';
        list.add(acc);
      }
      return list;
    }
    return [_dir];
  }

  void _jumpToPath(String path) {
    if (path == _dir) return;
    setState(() => _dir = path);
    _load();
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
              tooltip: '更多操作（复制 / 移动 / 导出 / 重命名 / 删除）',
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

  void _onTap(FsBrowserEntry e) {
    if (e.isDir) _enter(e);
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
    if (l.endsWith('.png') ||
        l.endsWith('.jpg') ||
        l.endsWith('.jpeg') ||
        l.endsWith('.webp')) {
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

/// 虚拟根入口卡片。
class _VirtualEntryTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _VirtualEntryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: onTap == null ? Colors.grey : Colors.amber.shade300),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
      ),
      trailing: onTap == null
          ? Icon(Icons.lock_outline, size: 14, color: Colors.grey.shade700)
          : const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
      enabled: onTap != null,
      onTap: onTap,
    );
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
