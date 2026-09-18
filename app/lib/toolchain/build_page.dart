import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import 'build_progress.dart';
import 'termux_backend.dart';
import 'toolchain_ensure.dart';

/// Step 6 构建页：项目列表 → 流式构建日志 → 取消 → 安装 APK。
///
/// 架构：
/// - 项目 = /root/projects 下的目录（容器内，W^X 安全区，可执行）；
/// - 构建走 ProotBridge 的流式通道（execStream 启动 / execStreamPoll 轮询增量 /
///   execStreamStop 取消），日志合并单流在 Dart 侧清洗 ANSI 与 \r 进度条；
/// - 产物路径 /root/projects/<name>/build/app/outputs/flutter-apk/*.apk，
///   安装时用真实宿主路径（rootfsPath + 容器路径）走 FileProvider 拉起系统安装器；
/// - 离开本页即中止构建（防 gradle daemon 管道泄漏）；
/// - 双后端（2026-09-18）：proot 容器模式 = proot 内执行 + 容器路径；
///   termux 裸原生模式 = bare 直跑（/system/bin/sh，不经 proot）+ 宿主路径
///   （rootfsPath + 容器路径，同一物理目录）+ termux prefix 的 bionic
///   flutter 全路径。产物定位与安装统一用容器路径，两模式映射相同。
///
/// ⚠️ 进度条说明（2026-09-17 增补）：flutter build apk 不输出百分比，
/// 只能靠日志关键词做「阶段识别 + 阶段内时间插值」——见 build_progress.dart。
/// 进度条本身不做假匀速，永不封顶，只有真正成功才到 100%。
///
/// ⚠️ 长任务与保活：ProotBridge 的 executor 是原生侧单线程队列
/// （MainActivity.executor = newSingleThreadExecutor），构建期间**整个应用
/// 所有 proot 调用都会排队**——包括文件浏览器、编辑器格式化、终端。
/// 这是"长时间占用主界面"的真正根因，详见 dev-handbook 新增章节。
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

  /// 构建后端（工具链页切换，filesDir/foa-backend.json 持久化）；
  /// 未选择过 = proot（构建页不弹询问，默认值）。
  BuildBackend _backend = BuildBackend.proot;

  _BuildStatus _status = _BuildStatus.idle;
  String? _active; // 正在构建/已构建的项目名
  final List<String> _lines = [];
  String _partial = '';
  Timer? _timer;
  int _streamId = -1;
  int _offset = 0;
  String? _apkGuest; // 产物容器路径（rootfs 内）

  /// 进度追踪：吃日志行 → 出阶段与百分比（见 build_progress.dart）。
  final BuildProgressTracker _prog = BuildProgressTracker();

  /// 已构建耗时（秒），用于"仍在运行"提示里的 `已用 mm:ss`。
  int _elapsedSec = 0;
  DateTime? _startedAt;

  /// 滚动是否跟随到底部。用户手动上滑看历史时自动关闭，避免被强行拽回。
  bool _autoScroll = true;
  bool _showJumpToBottom = false;

  /// 命中的修复建议（去重，最多保留 3 条）。
  final List<String> _hints = [];

  static const int _maxLines = 3000;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom = _scroll.offset >=
          _scroll.position.maxScrollExtent - 24;
      if (atBottom && !_autoScroll) {
        setState(() {
          _autoScroll = true;
          _showJumpToBottom = false;
        });
      } else if (!atBottom && _autoScroll) {
        // 用户主动上滑：暂停自动跟随
        setState(() {
          _autoScroll = false;
          _showJumpToBottom = true;
        });
      }
    });
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
      final backend = await BackendPrefs.load(env);
      final list = env.rootfsInstalled
          ? await _fb.browse('/root/projects')
          : null;
      if (!mounted) return;
      setState(() {
        _env = env;
        if (backend != null) _backend = backend;
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
    final env = _env;
    if (env == null) return;
    final bare = _backend == BuildBackend.termux;
    setState(() {
      _active = name;
      _status = _BuildStatus.building;
      _lines.clear();
      _partial = '';
      _apkGuest = null;
      _prog.reset();
      _elapsedSec = 0;
      _startedAt = DateTime.now();
      _autoScroll = true;
      _showJumpToBottom = false;
    });

    // shell 命令里的项目目录：proot = 容器路径；termux bare = 宿主路径
    //（bare 执行不经 proot，容器路径 /root/projects 对宿主不存在）。
    final projectsDir = bare
        ? '${env.rootfsPath}/root/projects'
        : _projectsDir;
    final proj = '$projectsDir/${_q(name)}';

    // termux 后端前置组件检查（缺了就快速失败，别等 flutter 脚本报错）：
    // bionic Flutter（含 bin/flutter）与 bionic git——容器里的 git 是
    // glibc 二进制，bare 直跑不了，不能用 ToolchainEnsure 兜底。
    if (bare) {
      final miss = <String>[];
      final flDir = TermuxPaths.flutterHome(env);
      if (!Directory(flDir).existsSync() ||
          !File('$flDir/bin/flutter').existsSync()) {
        miss.add('Flutter（bionic）');
      }
      if (!File('${TermuxPaths.prefix(env)}/bin/git').existsSync()) {
        miss.add('git（bionic）');
      }
      if (miss.isNotEmpty && mounted) {
        setState(() {
          _status = _BuildStatus.error;
          _lines.add('✗ termux 后端缺组件：${miss.join('、')}');
          _lines.add('  请到「工具链」页 → Termux 卡片安装后再构建');
        });
        return;
      }
    }

    // 前置校验：不是 Flutter 项目就快速失败，省一次 2h 级长任务
    final check = await _bridge.exec(
      'test -f $proj/pubspec.yaml && echo __OK__ || echo __NO__',
      timeoutSec: 30,
      bare: bare,
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
    _lines.add('  目录：$projectsDir/$name');
    _lines.add('  后端：${bare ? 'Termux 裸原生（不经 proot）' : 'Proot 容器'}');
    _lines.add('');

    // 前置清理（Bug 420）：上次构建被强杀的孤儿 dart 进程仍持有 flutter
    // 启动锁时，新构建会永远卡在 "Waiting for another flutter command..."。
    // proot 清容器 SDK 锁；termux 清 prefix 锁（dart 路径两后端都匹配）。
    final flutterDir = bare ? TermuxPaths.flutterHome(env) : '/opt/flutter';
    final killed = await ToolchainEnsure().flutterUnlock(
      _bridge,
      flutterDir,
      bare: bare,
    );
    if (!mounted) return;
    _lines.add(killed > 0
        ? '🧹 已清理残留 flutter 进程 $killed 个（启动锁已释放）'
        : '🧹 无残留 flutter 进程，锁干净');
    _lines.add('');

    // flutter 工具硬依赖 git，缺失时先自动安装（幂等；已装秒过）。
    // termux 后端跳过：前置检查已确保 bionic git 就位。
    if (!bare) {
      final gitErr = await ToolchainEnsure().git();
      if (!mounted) return;
      if (gitErr != null) {
        setState(() {
          _status = _BuildStatus.error;
          _lines.add('✗ $gitErr');
        });
        return;
      }
    }

    // gradle 发行包统一走腾讯镜像（Step 8）：老工程仍是官方源 URL，哈希
    // 与 Step 3 预下载缓存不匹配会直连 services.gradle.org；幂等改写，
    // 失败仅警告不阻断（构建仍可尝试直连）。
    // termux 后端不经容器 shell，用 Dart 文件 IO 直接改写（rootfs 树内
    // 文件宿主可见可写，与容器改写同一份文件）。
    if (bare) {
      final warn = _gradleMirrorFromDart(env, name);
      if (warn != null && mounted) {
        setState(() => _lines.add('⚠ $warn'));
      }
    } else {
      final mirrorErr = await ToolchainEnsure().projectGradleMirror(name);
      if (mirrorErr != null && mounted) {
        setState(() => _lines.add('⚠ $mirrorErr'));
      }
    }

    // aapt2 覆盖（仅 termux）：AGP 默认从 Maven 拉 x86_64 aapt2；termux
    // aapt 组件装好后把 build 期的 aapt2 指回 prefix 里的 bionic arm64 版
    //（-P 优先级高于 gradle.properties，不污染工程文件）。
    String aapt2Override = '';
    if (bare) {
      final aapt2 = TermuxPaths.aapt2(env);
      if (File(aapt2).existsSync()) {
        aapt2Override = " -Pandroid.aapt2FromMavenOverride='$aapt2'";
      }
    }

    // pub get 三次重试（Bug 420 第二层）：弱网下 pub 的 TLS 瞬断会让
    // flutter build 内部的自动 pub get 直接 exit 69。提前独立 pub get
    // 并重试，成功后 build 内部的自动 pub get 秒过（pubspec 未变）。
    final flutterCmd =
        bare ? "'${TermuxPaths.flutterHome(env)}/bin/flutter'" : 'flutter';
    final envPart = bare ? TermuxPaths.envPrefix(env) : '';
    final cmd = "cd $proj && $envPart"
        'FLUTTER_ALLOW_ROOT=true '
        'ok=0; for i in 1 2 3; do '
        'if $flutterCmd pub get; then ok=1; break; fi; '
        'sleep 3; done; '
        '[ "\$ok" = 1 ] || exit 69; '
        '$flutterCmd build apk --release '
        '--target-platform=android-arm64$aapt2Override';
    final start = await _bridge.execStream(cmd, bare: bare);
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

  /// termux 后端的 gradle wrapper 镜像改写：不经 shell，Dart 直接读写
  ///（rootfs 树内文件宿主可见）。幂等；非 Flutter 工程静默跳过。
  String? _gradleMirrorFromDart(EnvInfo env, String name) {
    try {
      final f = File('${env.rootfsPath}/root/projects/$name'
          '/android/gradle/wrapper/gradle-wrapper.properties');
      if (!f.existsSync()) return null;
      final t = f.readAsStringSync();
      if (t.contains('mirrors.cloud.tencent.com')) return null;
      f.writeAsStringSync(t.replaceAll(
          'services.gradle.org/distributions',
          'mirrors.cloud.tencent.com/gradle'));
      return null;
    } catch (e) {
      return 'gradle 镜像配置失败：$e';
    }
  }

  Future<void> _poll() async {
    final poll = await _bridge.execStreamPoll(_streamId, _offset);
    if (!mounted) return;
    if (!poll.ok) {
      _timer?.cancel();
      setState(() {
        _status = _BuildStatus.error;
        _prog.markHalted();
        _lines.add('✗ 轮询失败：${poll.error ?? '未知错误'}');
        _lines.add('  进度已冻结在 ${_prog.percent}%（任务已失联，请重试）');
      });
      return;
    }
    _appendChunk(poll.chunk);
    _offset = poll.len;
    // 进度插值：日志推进阶段，时间推进阶段内百分比
    _prog.tick();
    final started = _startedAt;
    if (started != null) {
      _elapsedSec = DateTime.now().difference(started).inSeconds;
    }
    if (!poll.running) {
      _timer?.cancel();
      final code = poll.exitCode;
      _finish(code);
    } else {
      setState(() {});
      if (_autoScroll) _scrollToBottom();
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
      final line = segs.last;
      _lines.add(line);
      // 进度识别吃"清洗后"的行：ANSI 已去、\r 段已取末段
      _prog.feed(line);
      _feedErrorBreakdown(line);
    }
    if (_lines.length > _maxLines) {
      _lines.removeRange(0, _lines.length - _maxLines);
      _lines[0] = '[日志截断，仅显示最近 $_maxLines 行]';
    }
  }

  /// 从日志里提取"失败类型"，供进度条下方给出可执行的修复建议。
  /// 只识别本仓库已知的失败模式（见 dev-handbook §十 工具链 / §十一 体积）。
  void _feedErrorBreakdown(String line) {
    final l = line.toLowerCase();
    String? tip;
    if (l.contains('exec format error')) {
      tip = '架构不匹配：x64 工具未经 qemu 转发（工具链页 → x64 兼容层 → 重新应用）';
    } else if (l.contains('shared libraries')) {
      tip = '多架构运行库缺失：x64 兼容层 → 重新应用';
    } else if (l.contains('no space left')) {
      tip = '磁盘空间不足：清理 build/ 与 .gradle 缓存后重试';
    } else if (l.contains('could not resolve') || l.contains('sslhandshake')) {
      tip = '依赖下载失败：检查镜像源（工具链页 → Gradle 镜像）';
    } else if (l.contains('tls error') || l.contains('failed to update packages')) {
      tip = 'pub 拉取 TLS 失败（多为弱网瞬断）：构建已自动重试 3 次，'
          '仍失败请切换网络后重试；若反复出现，检查「Gradle 镜像」页的源配置';
    } else if (l.contains('waiting for another flutter command')) {
      tip = 'Flutter 启动锁被占用：残留进程未清干净——完全杀掉 App 重开再试'
          '（alpha.30 起构建前会自动清理）';
    } else if (l.contains('snapshot not compatible')) {
      tip = 'flutter_tools.snapshot 架构不匹配：x64 兼容层未接管 dart-sdk';
    }
    if (tip != null && !_hints.contains(tip)) _hints.add(tip);
  }

  Future<void> _finish(int? code) async {
    if (code == 0) {
      await _locateApk(_active!);
    }
    if (!mounted) return;
    final ok = code == 0 && _apkGuest != null;
    setState(() {
      if (ok) {
        // 只有"成功且产物就位"才授予 100%，不动用插值
        _prog.markDone();
      } else {
        _prog.markHalted();
      }
      _status = ok ? _BuildStatus.done : _BuildStatus.error;
      if (code == 0 && _apkGuest == null) {
        _lines.add('✗ 构建成功但未找到 APK 产物');
      } else if (code != 0) {
        _lines.add('✗ 构建失败（exit ${code ?? -1}）· 已运行 ${_fmtDur(_elapsedSec)}'
            ' · 进度冻结在 ${_prog.percent}%');
      } else {
        _lines.add('');
        _lines.add('✓ 构建成功：$_apkGuest');
        _lines.add('  总耗时 ${_fmtDur(_elapsedSec)}');
      }
    });
    if (_autoScroll) _scrollToBottom();
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
      _prog.markHalted();
      _lines.add('');
      _lines.add('⏹ 已取消（用户中止）· 已运行 ${_fmtDur(_elapsedSec)}');
    });
    _scrollToBottom();
  }

  /// 秒 → `mm:ss` / `h:mm:ss`。
  static String _fmtDur(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
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
                const SizedBox(height: 4),
                Text(
                  _backend == BuildBackend.termux
                      ? '当前后端：Termux 裸原生（实验性）· 构建不经 proot，'
                          '宿主直接执行 bionic 工具链'
                      : '当前后端：Proot 容器（稳定）',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600,
                      color: Color(0xFF4C8DFF)),
                ),
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
        _buildProgressPanel(building, done, cancelled),
        Expanded(
          child: Stack(
            children: [
              Container(
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
              // 用户上滑看历史时出现"回到底部"，避免被自动滚动拽走
              if (_showJumpToBottom && _lines.isNotEmpty)
                Positioned(
                  right: 22,
                  bottom: 22,
                  child: FloatingActionButton.small(
                    heroTag: 'foa_jump_bottom',
                    tooltip: '回到底部',
                    onPressed: () {
                      setState(() {
                        _autoScroll = true;
                        _showJumpToBottom = false;
                      });
                      _scrollToBottom();
                    },
                    child: const Icon(Icons.arrow_downward, size: 18),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ============================ 进度面板 ============================

  /// 进度条 + 阶段名 + 计时 + 失败建议。
  ///
  /// 为什么不是普通 `LinearProgressIndicator(value: x)`：构建是 20 分钟级
  /// 长任务，用户最容易误判"卡死"。所以面板同时给出四层信息：百分比、
  /// 当前阶段、已用时间、"仍在运行"的实时证明（脉冲圆点 + 递增计时）。
  Widget _buildProgressPanel(bool building, bool done, bool cancelled) {
    final pct = _prog.percent;
    final color = done
        ? const Color(0xFF3DDC84)
        : building
            ? const Color(0xFF4C8DFF)
            : const Color(0xFFFF7A7A);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF11151B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (building)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              if (building) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  done
                      ? '构建完成'
                      : cancelled
                          ? '已取消'
                          : building
                              ? _prog.stage.label
                              : '构建中断于：${_prog.stage.label}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: color),
                ),
              ),
              Text(
                '$pct%',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: color),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _prog.progress,
              minHeight: 8,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.schedule, size: 13, color: Colors.grey.shade500),
              const SizedBox(width: 4),
              Text(
                building
                    ? '已用 ${_fmtDur(_elapsedSec)}'
                    : '耗时 ${_fmtDur(_elapsedSec)}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              if (building) ...[
                const SizedBox(width: 10),
                Text(
                  '构建为长任务（首次 15~30 分钟），后台仍在运行',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
          if (!building && _hints.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            for (final h in _hints.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.lightbulb_outline,
                        size: 13, color: Color(0xFFFFC46B)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        h,
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFFFFC46B)),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
