import 'dart:async';

import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import 'toolchain_ensure.dart';

/// Step 6 构建页：项目列表 → 流式构建日志 → 取消 → 安装 APK。
///
/// 架构：
/// - 项目 = /root/projects 下的目录（容器内，W^X 安全区，可执行）；
/// - 构建走 ProotBridge 的流式通道（execStream 启动 / execStreamPoll 轮询增量 /
///   execStreamStop 取消），日志合并单流在 Dart 侧清洗 ANSI 与 \r 进度条；
/// - 产物路径 /root/projects/<name>/build/app/outputs/flutter-apk/*.apk，
///   安装时用真实宿主路径（rootfsPath + 容器路径）走 FileProvider 拉起系统安装器；
/// - 离开本页即中止构建（防 gradle daemon 管道泄漏）。
class BuildPage extends StatefulWidget {
  /// 传入后加载完成即自动开始构建该项目（主页工程卡片直达）。
  final String? initialProject;

  const BuildPage({super.key, this.initialProject});

  @override
  State<BuildPage> createState() => _BuildPageState();
}

enum _BuildStatus { idle, building, done, error, cancelled }

class _BuildPageState extends State<BuildPage> {
  final ProotBridge _bridge = ProotBridge();
  final FileBrowserBridge _fb = FileBrowserBridge();
  final ScrollController _scroll = ScrollController();

  EnvInfo? _env;
  List<FsBrowserEntry> _projects = const [];
  bool _loading = true;
  String _loadError = '';
  bool _syncing = false;

  _BuildStatus _status = _BuildStatus.idle;
  String? _active; // 正在构建/已构建的项目名
  final List<String> _lines = [];
  String _partial = '';
  Timer? _timer;
  int _streamId = -1;
  int _offset = 0;
  String? _apkGuest; // 产物容器路径（rootfs 内）

  static const int _maxLines = 3000;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 离开页面即中止构建：流式进程持有 gradle daemon 管道，不杀会泄漏
    if (_status == _BuildStatus.building && _streamId > 0) {
      _bridge.execStreamStop(_streamId);
    }
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = '';
    });
    try {
      final env = await _bridge.envInfo();
      final list = env.rootfsInstalled
          ? await _fb.browse('/root/projects')
          : null;
      if (!mounted) return;
      setState(() {
        _env = env;
        _projects = (list?.entries ?? const []).where((e) => e.isDir).toList();
        _loading = false;
      });
      // 直达构建：主页卡片点入时，列表就绪后自动开始
      final init = widget.initialProject;
      if (init != null && env.rootfsInstalled &&
          _projects.any((p) => p.name == init)) {
        _startBuild(init);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '加载失败：$e';
      });
    }
  }

  /// 外部工作区 → 容器 同步（Step 5 桥），构建前把用户编辑拉进容器。
  Future<void> _syncExternal() async {
    setState(() => _syncing = true);
    final r = await _fb.syncProjects('toContainer');
    if (!mounted) return;
    setState(() => _syncing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r.ok
              ? '同步完成：${r.files} 个文件（${_mb(r.bytes)} MB）'
              : '同步失败：${r.error}',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
    if (r.ok) _load();
  }

  static String _mb(int bytes) =>
      (bytes / 1048576).toStringAsFixed(1);

  /// shell 单引号转义（项目名可能含空格/特殊字符）。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  String get _projectsDir => '/root/projects';

  Future<void> _startBuild(String name) async {
    setState(() {
      _active = name;
      _status = _BuildStatus.building;
      _lines.clear();
      _partial = '';
      _apkGuest = null;
    });

    final proj = '$_projectsDir/${_q(name)}';
    // 前置校验：不是 Flutter 项目就快速失败，省一次 2h 级长任务
    final check = await _bridge.exec(
      'test -f $proj/pubspec.yaml && echo __OK__ || echo __NO__',
      timeoutSec: 30,
    );
    if (!mounted) return;
    if (!check.stdout.contains('__OK__')) {
      setState(() {
        _status = _BuildStatus.error;
        _lines.add('✗ 不是 Flutter 项目：$proj/pubspec.yaml 不存在');
      });
      return;
    }

    _lines.add('▶ flutter build apk --release --target-platform=android-arm64');
    _lines.add('  目录：$_projectsDir/$name');
    _lines.add('');

    // flutter 工具硬依赖 git，缺失时先自动安装（幂等；已装秒过）
    final gitErr = await ToolchainEnsure().git();
    if (!mounted) return;
    if (gitErr != null) {
      setState(() {
        _status = _BuildStatus.error;
        _lines.add('✗ $gitErr');
      });
      return;
    }

    // gradle 发行包统一走腾讯镜像（Step 8）：老工程仍是官方源 URL，哈希
    // 与 Step 3 预下载缓存不匹配会直连 services.gradle.org；幂等改写，
    // 失败仅警告不阻断（构建仍可尝试直连）。
    final mirrorErr = await ToolchainEnsure().projectGradleMirror(name);
    if (mirrorErr != null && mounted) {
      setState(() => _lines.add('⚠ $mirrorErr'));
    }

    final cmd =
        'cd $_projectsDir/${_q(name)} && FLUTTER_ALLOW_ROOT=true '
        'flutter build apk --release --target-platform=android-arm64';
    final start = await _bridge.execStream(cmd);
    if (!mounted) return;
    if (!start.ok || start.id <= 0) {
      setState(() {
        _status = _BuildStatus.error;
        _lines.add('✗ 启动失败：${start.error ?? '未知错误'}');
      });
      return;
    }
    _streamId = start.id;
    _offset = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  Future<void> _poll() async {
    final poll = await _bridge.execStreamPoll(_streamId, _offset);
    if (!mounted) return;
    if (!poll.ok) {
      _timer?.cancel();
      setState(() {
        _status = _BuildStatus.error;
        _lines.add('✗ 轮询失败：${poll.error ?? '未知错误'}');
      });
      return;
    }
    _appendChunk(poll.chunk);
    _offset = poll.len;
    if (!poll.running) {
      _timer?.cancel();
      final code = poll.exitCode;
      _finish(code);
    } else {
      setState(() {});
      _scrollToBottom();
    }
  }

  void _appendChunk(String chunk) {
    final clean = chunk.replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '');
    _partial += clean;
    final parts = _partial.split('\n');
    _partial = parts.removeLast();
    for (final p in parts) {
      // 进度条用 \r 原地刷新：只保留最后一段
      final segs = p.split('\r');
      _lines.add(segs.last);
    }
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
      _lines[0] = '[日志截断，仅显示最近 $_maxLines 行]';
    }
  }

  Future<void> _finish(int? code) async {
    if (code == 0) {
      await _locateApk(_active!);
    }
    if (!mounted) return;
    setState(() {
      _status = code == 0
          ? (_apkGuest == null ? _BuildStatus.error : _BuildStatus.done)
          : _BuildStatus.error;
      if (_apkGuest == null && code == 0) {
        _lines.add('✗ 构建成功但未找到 APK 产物');
      } else if (code != 0) {
        _lines.add('✗ 构建失败（exit ${code ?? -1}）');
      } else {
        _lines.add('');
        _lines.add('✓ 构建成功：$_apkGuest');
      }
    });
    _scrollToBottom();
  }

  /// 在容器内查找 flutter-apk 产物（优先 app-release.apk）。
  Future<void> _locateApk(String name) async {
    final dir = '$_projectsDir/$name/build/app/outputs/flutter-apk';
    final list = await _fb.browse(dir);
    if (!list.ok) return;
    final apks = list.entries
        .where((e) => !e.isDir && e.name.endsWith('.apk'))
        .toList();
    if (apks.isEmpty) return;
    FsBrowserEntry? pick;
    for (final a in apks) {
      if (a.name == 'app-release.apk') {
        pick = a;
        break;
      }
    }
    pick ??= apks.first;
    _apkGuest = '$dir/${pick.name}';
  }

  Future<void> _cancel() async {
    _timer?.cancel();
    await _bridge.execStreamStop(_streamId);
    if (!mounted) return;
    setState(() {
      _status = _BuildStatus.cancelled;
      _lines.add('');
      _lines.add('⏹ 已取消（用户中止）');
    });
    _scrollToBottom();
  }

  Future<void> _install() async {
    final env = _env;
    final guest = _apkGuest;
    if (env == null || guest == null) return;
    // 容器路径 → 真实宿主路径（rootfs 位于 filesDir，FileProvider 授权范围内）
    final real = '${env.rootfsPath}$guest';
    final r = await _fb.installApk(real);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r.ok ? '已拉起系统安装器' : '安装失败：${r.error}',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('构建 APK')),
      body: _status == _BuildStatus.idle ? _buildProjectList() : _buildLogView(),
    );
  }

  // ============================ 项目列表 ============================

  Widget _buildProjectList() {
    final ready = _env?.rootfsInstalled == true;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('构建流程',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  '1. 项目位于容器 /root/projects（需已装 JDK / Android SDK / Flutter SDK / 构建镜像，见「工具链」页）\n'
                  '2. 点击项目 → flutter build apk --release（arm64，日志流式输出，可随时取消）\n'
                  '3. 构建成功 → 一键拉起系统安装器安装 APK',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: ready && !_syncing ? _syncExternal : null,
                        icon: _syncing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.sync, size: 18),
                        label: Text(_syncing ? '同步中…' : '外部工作区 → 容器'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '刷新',
                      onPressed: _loading ? null : _load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (!ready) ...[
                  const SizedBox(height: 8),
                  const Text('请先在主页初始化 rootfs 环境，并在工具链页安装构建组件',
                      style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_loadError.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(_loadError,
                  style: const TextStyle(color: Color(0xFFFF7A7A))),
            ),
          )
        else if (_projects.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.folder_off_outlined,
                      size: 40, color: Colors.grey.shade600),
                  const SizedBox(height: 8),
                  const Text('暂无项目'),
                  const SizedBox(height: 4),
                  Text(
                    '在「文件浏览器」/「编辑器」创建项目，或把文件放入外部工作区\n'
                    '（/sdcard/Android/data/<包名>/projects）后点「外部工作区 → 容器」。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final (i, p) in _projects.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(p.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: const Text('flutter build apk --release'),
                    trailing: ready
                        ? FilledButton.tonalIcon(
                            onPressed: () => _startBuild(p.name),
                            icon: const Icon(Icons.play_arrow, size: 18),
                            label: const Text('构建'),
                          )
                        : null,
                    onTap: ready ? () => _startBuild(p.name) : null,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  // ============================ 构建日志 ============================

  Widget _buildLogView() {
    final building = _status == _BuildStatus.building;
    final done = _status == _BuildStatus.done;
    final cancelled = _status == _BuildStatus.cancelled;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(
                building
                    ? Icons.hourglass_top
                    : done
                        ? Icons.check_circle
                        : cancelled
                            ? Icons.stop_circle_outlined
                            : Icons.error_outline,
                color: building
                    ? Colors.orangeAccent
                    : done
                        ? const Color(0xFF3DDC84)
                        : const Color(0xFFFF7A7A),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _active ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
              if (building)
                FilledButton.tonalIcon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('取消'),
                )
              else ...[
                OutlinedButton.icon(
                  onPressed: done ? _install : null,
                  icon: const Icon(Icons.install_mobile, size: 18),
                  label: const Text('安装'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: () => setState(() {
                    _status = _BuildStatus.idle;
                    _active = null;
                  }),
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('返回列表'),
                ),
              ],
            ],
          ),
        ),
        if (!building && !done)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                done ? '构建成功，可安装或返回列表' : '构建未成功：可返回列表重试',
                style: TextStyle(
                    fontSize: 12,
                    color: done ? const Color(0xFF3DDC84) : Colors.grey.shade500),
              ),
            ),
          ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0C0F13),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: _lines.isEmpty && building
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(10),
                    itemCount: _lines.length,
                    itemBuilder: (context, i) => Text(
                      _lines[i],
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        height: 1.4,
                        color: Color(0xFFD6DEE8),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
