import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import 'build_notify.dart';
import 'build_runner.dart';
import 'termux_backend.dart';

/// Step 6 构建页：项目列表 → 流式构建日志 → 取消 → 安装 APK。
///
/// 架构：
/// - 项目 = /root/projects 下的目录（容器内，W^X 安全区，可执行）；
/// - 构建走 ProotBridge 的流式通道（execStream 启动 / execStreamPoll 轮询增量 /
///   execStreamStop 取消），日志合并单流在 Dart 侧清洗 ANSI 与 \r 进度条；
/// - 产物路径 /root/projects/<name>/build/app/outputs/flutter-apk/*.apk，
///   安装时用真实宿主路径（rootfsPath + 容器路径）走 FileProvider 拉起系统安装器；
/// - **本页是薄视图**（alpha.31）：构建会话全部在全局单例 BuildRunner——
///   退出页面（dispose）不再杀构建，前台服务（原生 BuildService）保活，
///   通知栏可见进度，点通知回本页；重进页面从 Runner 无缝挂回；
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

class _BuildPageState extends State<BuildPage> {
  /// 构建会话全局单例：状态与执行逻辑都在这里，页面只是视图。
  /// 本页所有构建相关渲染均读 `r.`，刷新由 r.onUiChanged 回调驱动。
  BuildRunner get r => BuildRunner.I;

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

  /// 滚动是否跟随到底部。用户手动上滑看历史时自动关闭，避免被强行拽回。
  bool _autoScroll = true;
  bool _showJumpToBottom = false;

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
    // alpha.31 挂回：构建可能在别的页面/后台跑着（点通知回来、或上次
    // 退出页面没杀）——把 UI 钩子接回 Runner，日志进度无缝续显。
    r.onUiChanged = () => setState(() {});
    r.onAutoScroll = () {
      if (_autoScroll) _scrollToBottom();
    };
    _load();
  }

  @override
  void dispose() {
    // alpha.31：离开页面不再杀构建——原「离页即中止」是防 gradle daemon
    // 管道泄漏，代价是锁屏/切走必断构建。现在全局单例继续轮询 + 原生
    // 前台服务保活，通知栏可见进度，点通知回本页。只解绑 UI 钩子。
    r.onUiChanged = null;
    r.onAutoScroll = null;
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

  /// 点构建：通知可用性提示（不阻断）→ 全局 Runner 启动。
  Future<void> _startBuild(String name) async {
    final env = _env;
    if (env == null || r.building) return;
    // Android 13+ 用户可关通知：关了也能构建，只是退到桌面看不到进度，
    // 给一次性引导（设置里开启），不弹系统权限框（targetSdk 28 也弹不出）
    if (!await BuildNotify.enabled) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('通知已关闭：退到桌面后将看不到构建进度通知'
              '（可在系统设置 → 应用通知中开启）'),
          duration: Duration(seconds: 4),
        ),
      );
    }
    await r.start(name, env, _backend);
  }

  Future<void> _cancel() => r.cancel();

  Future<void> _install() async {
    final env = _env;
    final guest = r.apkGuest;
    if (env == null || guest == null) return;
    // 容器路径 → 真实宿主路径（rootfs 位于 filesDir，FileProvider 授权范围内）
    final real = '${env.rootfsPath}$guest';
    final res = await _fb.installApk(real);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok ? '已拉起系统安装器' : '安装失败：${res.error}',
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
      body: r.status == BuildStatus.idle ? _buildProjectList() : _buildLogView(),
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
                  '2. 点击项目 → flutter build apk --no-shrink --release（arm64，日志流式输出，可随时取消）\n'
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
                    subtitle: const Text('flutter build apk --no-shrink --release'),
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
    final building = r.status == BuildStatus.building;
    final done = r.status == BuildStatus.done;
    final cancelled = r.status == BuildStatus.cancelled;
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
                  r.active ?? '',
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
                  onPressed: r.resetUi,
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
                child: r.lines.isEmpty && building
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(10),
                        itemCount: r.lines.length,
                        itemBuilder: (context, i) => Text(
                          r.lines[i],
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
              if (_showJumpToBottom && r.lines.isNotEmpty)
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
    final pct = r.prog.percent;
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
                              ? r.prog.stage.label
                              : '构建中断于：${r.prog.stage.label}',
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
              value: r.prog.progress,
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
                    ? '已用 ${BuildRunner.fmtDur(r.elapsedSec)}'
                    : '耗时 ${BuildRunner.fmtDur(r.elapsedSec)}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              if (building) ...[
                const SizedBox(width: 10),
                Text(
                  '构建为长任务（首次 15~30 分钟），退到桌面/锁屏后由前台服务保活，'
                      '通知栏可见进度',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
          if (!building && r.hints.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            for (final h in r.hints.take(3))
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
