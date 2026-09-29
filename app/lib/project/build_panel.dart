import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../editor/fs_bridge.dart';
import '../toolchain/build_notify.dart';
import '../toolchain/build_page.dart';
import '../toolchain/build_progress.dart';
import '../toolchain/build_runner.dart';
import '../toolchain/termux_backend.dart';
import '../filemanager/fs_browser_bridge.dart';
import '../core/theme.dart';
import 'keystore_store.dart';
import 'signing.dart';

/// 项目工作台 ·「打包」区（alpha.61 优化）。
///
/// 原实现的几个具体问题（都是用户实际踩到的）：
/// 1. **日志只有 30 行，还不能展开**。构建失败了用户看不到出错上下文，
///    只能跳去另一个页面。→ 改为可下拉展开的 BottomSheet，全屏看。
/// 2. **进度只有一根条**，用户不知道"现在到哪一步了"。→ 加阶段清单，
///    已经过的阶段打勾，当前阶段高亮，未到的灰掉。
/// 3. **重复提交**：按钮点了没反应（因为构建中会禁用），
///    但用户不知道"是禁用了还是我没点到"。→ 明确显示"构建中"并禁用。
/// 4. **前置检查不可见**：环境缺东西时要等构建跑一半才报错。→ 先检查再构建。
/// 5. **构建参数是死的**：用户不知道自己要构建的到底是什么。→ 可视化展示。
/// 6. **失败日志和普通日志一个颜色**，一眼看不出问题在哪。→ 高亮错误行。
class BuildPanel extends StatefulWidget {
  final String projectName;
  final EnvInfo? env;
  final BuildBackend backend;
  /// 开始构建（alpha.93：带上构建类型，父页据此传给 BuildRunner）。
  final Future<void> Function(BuildFlavor flavor) onStartBuild;

  /// 构建后端切换（写回 BackendPrefs 由父页负责）。
  final ValueChanged<BuildBackend>? onBackendChanged;

  const BuildPanel({
    super.key,
    required this.projectName,
    required this.env,
    required this.backend,
    required this.onStartBuild,
    this.onBackendChanged,
  });

  @override
  State<BuildPanel> createState() => _BuildPanelState();
}

class _BuildPanelState extends State<BuildPanel> {
  final FsBridge _fb = FsBridge();

  /// 只有 installApk 走这个桥（该方法在文件浏览器桥里，
  /// 因为它复用同一套 FileProvider 授权与 Intent 逻辑）。
  final FileBrowserBridge _fbb = FileBrowserBridge();
  final ProotBridge _bridge = ProotBridge();

  BuildRunner get r => BuildRunner.I;

  /// 前置检查结果。
  List<({String name, bool ok, String note, bool blocking})> _pre = [];

  bool _checking = false;
  bool _checked = false;
  bool _cleaning = false;

  /// alpha.93：验签进行中（apksigner 在容器里跑，QEMU 下要几秒）。
  bool _signBusy = false;

  /// alpha.93：构建类型（debug 档不走 AOT，是设备端唯一显著提速的档位）。
  /// 默认 release——与加这个开关之前的行为完全一致，不擅改用户预期。
  BuildFlavor _flavor = BuildFlavor.release;

  @override
  void initState() {
    super.initState();
    // 首次进入就做一次静默检查（不阻塞界面）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preflight(silent: true);
      _loadFlavor();
    });
  }

  /// 读回上次选择的构建类型（写盘持久化，与后端偏好同风格）。
  Future<void> _loadFlavor() async {
    final env = widget.env;
    if (env == null) return;
    final v = await FlavorPrefs.load(env);
    if (mounted) setState(() => _flavor = v);
  }

  /// 切换构建类型（写盘持久化，下次进来还是这个）。
  Future<void> _switchFlavor(BuildFlavor v) async {
    final env = widget.env;
    setState(() => _flavor = v);
    if (env != null) await FlavorPrefs.save(env, v);
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ============================ 前置检查 ============================

  /// 构建前置检查（alpha.61）。
  ///
  /// 为什么要在构建**之前**做：这些检查里任何一条不满足，
  /// 构建都会在跑了几分钟、烧掉大量内存之后才失败，用户还看不懂
  /// gradle 的报错。提前拦下来能把"等 5 分钟得到一句 error"变成
  /// "一眼知道缺什么"。
  ///
  /// [silent] 为 true 时不显示 loading（首次进页面的后台检查）。
  Future<void> _preflight({bool silent = false}) async {
    final env = widget.env;
    if (env == null) return;
    if (!silent) setState(() => _checking = true);

    final out = <({String name, bool ok, String note, bool blocking})>[];

    // 1. rootfs
    if (!env.rootfsInstalled) {
      out.add((
        name: '运行环境（rootfs）',
        ok: false,
        note: '未初始化，请先在主页完成环境安装',
        blocking: true,
      ));
    } else {
      out.add((
        name: '运行环境（rootfs）',
        ok: true,
        note: '已安装',
        blocking: true,
      ));
    }

    if (!env.rootfsInstalled) {
      if (!mounted) return;
      setState(() {
        _pre = out;
        _checking = false;
        _checked = true;
      });
      return;
    }

    // 2. 项目目录 / pubspec
    final proj = '/root/projects/${widget.projectName}';
    final pub = await _fb.read('$proj/pubspec.yaml');
    out.add((
      name: '项目 pubspec.yaml',
      ok: pub.ok,
      note: pub.ok ? '可读' : '读取失败：${pub.error}',
      blocking: true,
    ));

    // 3. android 宿主目录（没有就跑不了 gradle）
    final gradle = await _fb.read('$proj/android/app/build.gradle');
    final gradleKts = gradle.ok
        ? gradle
        : await _fb.read('$proj/android/app/build.gradle.kts');
    out.add((
      name: 'Android 宿主工程',
      ok: gradle.ok || gradleKts.ok,
      note: gradle.ok || gradleKts.ok
          ? '已就绪'
          : '未找到 android/ 目录——这个项目可能不是 Flutter 应用',
      blocking: true,
    ));

    // 4. 是否已有 AndroidManifest（模板缺这个 gradle 会失败）
    final mf = await _fb.read('$proj/android/app/src/main/AndroidManifest.xml');
    out.add((
      name: 'AndroidManifest.xml',
      ok: mf.ok,
      note: mf.ok ? '已就绪' : '缺失（构建会失败）',
      blocking: true,
    ));

    // 5. 后端可用性（Termux 裸原生需要 prefix 存在）
    if (widget.backend == BuildBackend.termux) {
      final hasPrefix = TermuxPaths.prefixExists(env);
      out.add((
        name: 'Termux 前缀',
        ok: hasPrefix,
        note: hasPrefix ? '已安装' : '未安装——请切回 Proot 后端或先安装 Termux 环境',
        blocking: true,
      ));
    } else {
      out.add((
        name: '构建后端',
        ok: true,
        note: 'Proot 容器（推荐）',
        blocking: false,
      ));
    }

    // 6. 磁盘空间粗检（构建要解压大量中间产物，空间不足会在中途失败）
    //
    // 用 df 而不是 StatFs：rootfs 在 filesDir 下，StatFs 拿到的是整个
    // 数据分区，而 df -P 报的是同一件事且单位可控、易解析。
    final df = await _bridge.exec(
      "df -P -k '${env.rootfsPath}' 2>/dev/null | tail -1 | awk '{print \$4}'",
      timeoutSec: 20,
    );
    if (df.ok) {
      final kb = int.tryParse(df.stdout.trim());
      if (kb != null) {
        final freeMb = kb ~/ 1024;
        final ok = freeMb > 1024;
        out.add((
          name: '可用空间',
          ok: ok,
          note: ok
              ? '约 ${(freeMb / 1024).toStringAsFixed(1)} GB 可用'
              : '仅约 $freeMb MB，构建可能中途失败',
          blocking: false,
        ));
      }
    }

    if (!mounted) return;
    setState(() {
      _pre = out;
      _checking = false;
      _checked = true;
    });
  }

  bool get _hasBlocking => _pre.any((e) => e.blocking && !e.ok);

  // ============================ 动作 ============================

  Future<void> _start() async {
    if (r.building) return; // 防重复提交
    await _preflight();
    if (!mounted) return;
    if (_hasBlocking) {
      final go = await _confirm(
        '前置检查未通过',
        '有 ${_pre.where((e) => e.blocking && !e.ok).length} 项检查未通过：\n\n'
            '${_pre.where((e) => e.blocking && !e.ok).map((e) => '· ${e.name}：${e.note}').join('\n')}\n\n'
            '继续构建很可能在几分钟后失败。仍要继续吗？',
      );
      if (!go) return;
    }
    if (!await BuildNotify.enabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('通知已关闭：退到桌面后将看不到构建进度通知'
            '（可在系统设置 → 应用通知中开启）'),
        duration: Duration(seconds: 4),
      ));
    }
    await widget.onStartBuild(_flavor);
    if (mounted) setState(() {});
  }

  Future<void> _confirmClean() async {
    final go = await _confirm(
      '清理构建缓存？',
      '将执行 flutter clean，删除 build/ 与 .dart_tool/。\n\n'
          '下次构建会重新下载依赖、重新编译全部产物（时间明显变长），'
          '但能解决"缓存导致的玄学失败"。\n\n'
          '你的源码和配置不会被改动。',
    );
    if (go) await _clean();
  }

  Future<void> _clean() async {
    final env = widget.env;
    if (env == null || _cleaning || r.building) return;
    setState(() => _cleaning = true);
    final err = await r.clean(widget.projectName, env, widget.backend);
    if (!mounted) return;
    setState(() => _cleaning = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err ?? '已清理 build/ 与 .dart_tool'),
      duration: Duration(seconds: err == null ? 2 : 4),
    ));
  }

  Future<bool> _confirm(String title, String body) async {
    final v = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body, style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    return v ?? false;
  }

  void _openLog() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0C0F13),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _LogSheet(
        getRunner: () => r,
        onClosed: () {},
      ),
    );
  }

  // ============================ 界面 ============================

  @override
  Widget build(BuildContext context) {
    final env = widget.env;
    final mine = r.active == widget.projectName;
    final otherBuilding = r.building && !mine;

    if (env != null && !env.rootfsInstalled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.folder_off_outlined,
                  size: 40, color: Color(0xFFFF7A7A)),
              const SizedBox(height: 12),
              const Text('rootfs 未初始化',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('构建需要容器环境，请先在主页完成环境安装',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12, color: FoaColors.of(context).muted)),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (otherBuilding)
          _otherBuildingCard()
        else ...[
          if (r.building && mine)
            _buildingCard()
          else ...[
            _preflightCard(),
            const SizedBox(height: 12),
            _paramsCard(),
            const SizedBox(height: 12),
            _actionsCard(),
          ],
          if (!r.building && mine && r.status != BuildStatus.idle) ...[
            const SizedBox(height: 12),
            _resultCard(),
          ],
          if (r.lines.isNotEmpty && mine) ...[
            const SizedBox(height: 12),
            _logPreviewCard(),
          ],
        ],
      ],
    );
  }

  // ---------- 别人的构建占着 ----------

  Widget _otherBuildingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            const Icon(Icons.hourglass_top, size: 34, color: Color(0xFFFFB74D)),
            const SizedBox(height: 12),
            Text('「${r.active}」正在构建中',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '同一时间只能有一个构建任务——同时构建两个项目会\n'
              '把 CPU 和内存打满，两边都跑不完。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: FoaColors.of(context).muted),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => setState(() {}),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新状态'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 构建中 ----------

  Widget _buildingCard() {
    final prog = r.prog;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(prog.stage.label,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                Text('${prog.percent}%',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF4C8DFF))),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: prog.progress,
                minHeight: 8,
                backgroundColor: Colors.white10,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF4C8DFF)),
              ),
            ),
            const SizedBox(height: 14),
            _stageList(active: prog.stage),
            const Divider(height: 26),
            Row(
              children: [
                Text('已用 ${BuildRunner.fmtDur(r.elapsedSec)}',
                    style: TextStyle(
                        fontSize: 11, color: FoaColors.of(context).muted)),
                const SizedBox(width: 10),
                Icon(Icons.notifications_active_outlined,
                    size: 12, color: FoaColors.of(context).muted),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('可退出页面，构建继续',
                      style: TextStyle(
                          fontSize: 11, color: FoaColors.of(context).muted)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openLog,
                    icon: const Icon(Icons.terminal, size: 16),
                    label: const Text('查看日志', style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final go = await _confirm(
                          '取消构建？', '将终止当前构建进程。已经完成的部分不会保留，\n下次构建需要重新开始。');
                      if (go) await r.cancel();
                    },
                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                    label: const Text('取消', style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF7A7A),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 阶段清单：让"做到哪一步了"一眼可见。
  ///
  /// 数据源是 [BuildStages.ordered]——和进度条用的是同一份定义，
  /// 不会出现"进度条说在编译资源、清单说在编译内核"这种自相矛盾。
  Widget _stageList({required BuildStage active}) {
    const list = BuildStages.ordered;
    final activeIdx = list.indexOf(active);
    final doneAll = r.status == BuildStatus.done;
    final failed = r.status == BuildStatus.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < list.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                _stageDot(i, activeIdx, doneAll, failed),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    list[i].label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          i == activeIdx ? FontWeight.w600 : FontWeight.w400,
                      color: i < activeIdx || doneAll
                          ? const Color(0xFF3DDC84)
                          : i == activeIdx
                              ? (failed
                                  ? const Color(0xFFFF7A7A)
                                  : const Color(0xFF4C8DFF))
                              : FoaColors.of(context).muted,
                    ),
                  ),
                ),
                if (i == activeIdx && !doneAll && !failed)
                  Text('进行中',
                      style: TextStyle(
                          fontSize: 10, color: FoaColors.of(context).muted)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _stageDot(int i, int activeIdx, bool doneAll, bool failed) {
    final done = doneAll || i < activeIdx;
    final activeNow = !doneAll && i == activeIdx;
    final color = done
        ? const Color(0xFF3DDC84)
        : activeNow
            ? (failed ? const Color(0xFFFF7A7A) : const Color(0xFF4C8DFF))
            : Colors.grey.shade800;
    if (activeNow && !failed) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
    }
    return Icon(done ? Icons.check_circle : Icons.circle,
        size: 14, color: color);
  }

  // ---------- 前置检查 ----------

  Widget _preflightCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.checklist_outlined,
                    size: 18, color: Color(0xFF4C8DFF)),
                const SizedBox(width: 8),
                const Text('构建前检查',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_checking)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '重新检查',
                    onPressed: () => _preflight(),
                    icon: const Icon(Icons.refresh, size: 16),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _checked
                  ? (_hasBlocking ? '有未通过项，构建大概率会失败' : '全部通过，可以开始构建')
                  : '正在检查…',
              style: TextStyle(
                fontSize: 11,
                color: !_checked
                    ? FoaColors.of(context).muted
                    : _hasBlocking
                        ? const Color(0xFFFFB74D)
                        : const Color(0xFF3DDC84),
              ),
            ),
            if (_pre.isNotEmpty) const Divider(height: 20),
            for (final e in _pre)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      e.ok
                          ? Icons.check_circle_outline
                          : (e.blocking
                              ? Icons.error_outline
                              : Icons.warning_amber_outlined),
                      size: 15,
                      color: e.ok
                          ? const Color(0xFF3DDC84)
                          : (e.blocking
                              ? const Color(0xFFFF7A7A)
                              : const Color(0xFFFFB74D)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.name,
                              style: const TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w500)),
                          Text(e.note,
                              style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.4,
                                  color: FoaColors.of(context).muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------- 构建参数可视化 ----------

  Widget _paramsCard() {
    final env = widget.env;
    final backendLabel =
        widget.backend == BuildBackend.termux ? 'Termux 裸原生' : 'Proot 容器';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.tune, size: 18, color: Color(0xFF4C8DFF)),
                SizedBox(width: 8),
                Text('本次构建参数',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Text('开始前确认一下，构建中不可更改',
                style: TextStyle(
                    fontSize: 11, color: FoaColors.of(context).muted)),
            const Divider(height: 20),
            _paramRow('项目', widget.projectName),
            _paramRow('构建目标',
                '${_flavor == BuildFlavor.debug ? 'debug' : 'release'} APK（arm64-v8a）'),
            _paramRow('构建后端', backendLabel,
                note: widget.backend == BuildBackend.termux
                    ? '实验性，更快但兼容性差'
                    : '稳定'),
            _paramRow('容器路径', '/root/projects/${widget.projectName}'),
            if (env != null) _paramRow('ABI', env.abi ?? '未知'),
            if (env != null)
              _paramRow('Android SDK',
                  env.androidSdk > 0 ? 'API ${env.androidSdk}' : '未知'),
            const Divider(height: 20),
            // alpha.93：构建类型切换。debug 档不走 AOT——真机卡在
            // 「AOT 编译（gen_snapshot）」时切它能直接砍掉最慢的一段。
            Row(
              children: [
                Expanded(
                  child: Text('构建类型',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted)),
                ),
                SegmentedButton<BuildFlavor>(
                  segments: const [
                    ButtonSegment(
                      value: BuildFlavor.release,
                      label: Text('Release', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: BuildFlavor.debug,
                      label: Text('Debug', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  selected: {_flavor},
                  onSelectionChanged: r.building ? null : (s) => _switchFlavor(s.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 如实标注代价：debug 不是"更好"，是"更快但有条件"
            Text(
              _flavor == BuildFlavor.debug
                  ? '不走 AOT（gen_snapshot），跳过最慢的一段，明显更快。'
                      '首次需下载一批 debug 引擎构件；产物仅用于自测，不能上架。'
                  : '走 AOT 编译，产物可上架。gen_snapshot 是 x86_64 二进制、'
                      '靠转译执行，这是构建慢的主要原因。',
              style:
                  TextStyle(fontSize: 10.5, color: FoaColors.of(context).muted),
            ),
            const Divider(height: 20),
            // 后端切换：直接在这里改，不用跑去工具链页
            Row(
              children: [
                Expanded(
                  child: Text('切换后端',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted)),
                ),
                SegmentedButton<BuildBackend>(
                  segments: const [
                    ButtonSegment(
                      value: BuildBackend.proot,
                      label: Text('Proot', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: BuildBackend.termux,
                      label: Text('Termux', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  selected: {widget.backend},
                  onSelectionChanged: r.building
                      ? null
                      : (s) => widget.onBackendChanged?.call(s.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _paramRow(String k, String v, {String? note}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(k,
                style: TextStyle(
                    fontSize: 12, color: FoaColors.of(context).muted)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(v,
                    style: const TextStyle(
                        fontSize: 12.5, fontFamily: 'monospace')),
                if (note != null)
                  Text(note,
                      style: TextStyle(
                          fontSize: 10, color: FoaColors.of(context).muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 操作区 ----------

  Widget _actionsCard() {
    final building = r.building;
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            // 防重复：构建中禁用（并且方法内还有一层拦截，
            // 防止快速双击在同一帧内进入两次）
            onPressed: building ? null : _start,
            icon: Icon(
                _hasBlocking && _checked
                    ? Icons.warning_amber_outlined
                    : Icons.play_arrow_rounded,
                size: 20),
            label: Text(
              building
                  ? '构建中…'
                  : (_hasBlocking && _checked ? '仍然开始构建' : '开始构建 APK'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (building || _cleaning) ? null : _confirmClean,
                icon: _cleaning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cleaning_services_outlined, size: 16),
                label: Text(_cleaning ? '清理中…' : '清理缓存',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _preflight(),
                icon: const Icon(Icons.fact_check_outlined, size: 16),
                label: const Text('重新检查', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '清理缓存会删除 build/ 与 .dart_tool/，下次构建更慢但能解决'
          '"缓存导致的玄学失败"',
          style: TextStyle(
              fontSize: 10.5, height: 1.5, color: FoaColors.of(context).muted),
        ),
      ],
    );
  }

  // ---------- 结果卡 ----------

  Widget _resultCard() {
    final ok = r.status == BuildStatus.done;
    final cancelled = r.status == BuildStatus.cancelled;
    final color = ok
        ? const Color(0xFF3DDC84)
        : cancelled
            ? Colors.grey
            : const Color(0xFFFF7A7A);
    final title = ok
        ? '构建成功'
        : cancelled
            ? '已取消'
            : '构建失败';
    final icon = ok
        ? Icons.check_circle
        : cancelled
            ? Icons.cancel_outlined
            : Icons.error_outline;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: color)),
                const Spacer(),
                if (r.elapsedSec > 0)
                  Text('耗时 ${BuildRunner.fmtDur(r.elapsedSec)}',
                      style: TextStyle(
                          fontSize: 11, color: FoaColors.of(context).muted)),
              ],
            ),
            if (ok && r.apkGuest != null) ...[
              const SizedBox(height: 12),
              _artifactCard(),
            ],
            if (!ok && !cancelled) ...[
              const SizedBox(height: 10),
              _failureHints(),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openLog,
                    icon: const Icon(Icons.terminal, size: 16),
                    label: const Text('查看日志', style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const BuildPage()),
                    ),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('构建台详情', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 产物卡：构建成功后的关键信息 + 常用动作。
  Widget _artifactCard() {
    final guest = r.apkGuest!;
    final name = guest.split('/').last;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3DDC84).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: const Color(0xFF3DDC84).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.android, size: 18, color: Color(0xFF3DDC84)),
              const Spacer(),
              // alpha.93：签完名到底是不是正式签名，以前只能靠猜
              // （"我没配过签名，应该是 debug 的吧"）。
              TextButton.icon(
                onPressed: _signBusy ? null : _verifySignature,
                icon: _signBusy
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_outlined, size: 15),
                label: Text(_signBusy ? '检查中…' : '验签',
                    style: const TextStyle(fontSize: 11)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('容器内路径：$guest',
              maxLines: 2,
              style:
                  TextStyle(fontSize: 10, color: FoaColors.of(context).muted)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _install,
                  icon: const Icon(Icons.install_mobile, size: 16),
                  label: const Text('安装', style: TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3DDC84),
                    foregroundColor: Colors.black,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '复制产物路径',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: guest));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('已复制产物路径'),
                    duration: Duration(seconds: 2),
                  ));
                },
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _signBusy ? null : () => _resign(),
                  icon: const Icon(Icons.draw_outlined, size: 16),
                  label: const Text('用正式签名重签',
                      style: TextStyle(fontSize: 11.5)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  // alpha.94：想拿 debug 签名的包，两条路都给：
                  // ① 切到 debug 档构建（release 变体才走 signingConfigs，
                  //    debug 档本来就是 debug 签名）；
                  // ② 对已产出的包直接换 debug 签名（这条按钮）。
                  onPressed: _signBusy ? null : _resignDebug,
                  icon: const Icon(Icons.bug_report_outlined, size: 16),
                  label: const Text('用 debug 签名重签',
                      style: TextStyle(fontSize: 11.5)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
    ));
  }

  /// 读这个工程的签名配置（唯一真源是 android/key.properties）。
  Future<SigningConfig?> _signingConfig() async {
    for (final f in const [
      'android/key.properties',
      'android/app/key.properties',
    ]) {
      final s = await _fb.read('/root/projects/${widget.projectName}/$f');
      if (!s.ok) continue;
      final c = Signing.configFrom(s.content);
      if (c != null) return c;
    }
    return null;
  }

  /// 用 Android 官方约定的 debug keystore 重签（alpha.94）。
  ///
  /// 「有正式签名但想用 debug 签名」的正解其实是**切到 debug 档构建**——
  /// `signingConfigs.release` 只作用于 release 变体，debug 档本来就是
  /// debug 签名。但有时用户手上只有一个已经打好的 release 包
  /// （比如换回 debug 签名做本地对照测试），所以这里也留一条产物级出口。
  ///
  /// debug keystore 的参数是 AOSP/Gradle 的公开约定（alias
  /// `androiddebugkey`、口令 `android`、DN `CN=Android Debug`），
  /// Gradle 自己在 ~/.android/debug.keystore 生成的也是这一套。
  Future<void> _resignDebug() async {
    final guest = r.apkGuest;
    if (guest == null || _signBusy) return;
    setState(() => _signBusy = true);
    final st = KeystoreStore(_bridge);
    final dk = await st.ensureDebugKeystore();
    if (!mounted) return;
    if (!dk.ok) {
      setState(() => _signBusy = false);
      _toast(dk.msg);
      return;
    }
    final res = await Signing.signApk(
      _bridge,
      apkIn: guest,
      keystorePath: dk.path,
      alias: KeystoreStore.debugAlias,
      storePass: KeystoreStore.debugPass,
      keyPass: KeystoreStore.debugPass,
    );
    if (!mounted) return;
    setState(() => _signBusy = false);
    // ⚠️ Signing.signApk 会把"仍是 debug 证书"当成异常提示（那是给正式
    // 签名准备的判断），这里本来就是要 debug 签，别拿那条文案吓人。
    _toast(res.ok ? '已用 debug 签名重签：${res.apk ?? ''}' : res.msg);
    if (!res.ok) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('签名失败'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: SelectableText(res.msg,
                  style: const TextStyle(
                      fontSize: 11, height: 1.5, fontFamily: 'monospace')),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了')),
          ],
        ),
      );
    }
  }

  /// 对已产出的 APK 直接签名（不改任何源码，DSL 无关）。
  ///
  /// 存在的理由：构建脚本补丁匹配不到模板时会**拒绝硬改**，
  /// 那时"构建即签名"走不通，这条路仍然可用。
  Future<void> _resign() async {
    final guest = r.apkGuest;
    if (guest == null || _signBusy) return;
    setState(() => _signBusy = true);
    final cfg = await _signingConfig();
    if (!mounted) return;
    if (cfg == null) {
      setState(() => _signBusy = false);
      _toast('还没配置正式签名：请先在「清单」区点"生成并配置签名"');
      return;
    }
    final res = await Signing.signApk(
      _bridge,
      apkIn: guest,
      keystorePath: cfg.storeFile,
      alias: cfg.keyAlias,
      storePass: cfg.storePassword,
      keyPass: cfg.keyPassword,
    );
    if (!mounted) return;
    setState(() => _signBusy = false);
    _toast(res.ok ? '已签名：${res.apk ?? ''}' : res.msg);
    if (res.ok) return;
    // 失败时把容器原文拿出来看——apksigner 的报错只在终端里看得全。
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('签名失败'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(res.msg,
                style: const TextStyle(
                    fontSize: 11, height: 1.5, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 验签：这个包到底是正式签名还是 debug 签名。
  ///
  /// 用 apksigner（容器 build-tools 自带，AOSP 开源），不引任何新依赖。
  Future<void> _verifySignature() async {
    final guest = r.apkGuest;
    if (guest == null || _signBusy) return;
    setState(() => _signBusy = true);
    final res = await Signing.verify(_bridge, guest);
    if (!mounted) return;
    setState(() => _signBusy = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('签名检查结果'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(res.msg,
                style: const TextStyle(
                    fontSize: 11, height: 1.5, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _install() async {
    final env = widget.env;
    final guest = r.apkGuest;
    if (env == null || guest == null) return;
    final real = '${env.rootfsPath}$guest';
    final res = await _fbb.installApk(real);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res.ok ? '已拉起系统安装器' : '安装失败：${res.error}'),
      duration: const Duration(seconds: 4),
    ));
  }

  /// 失败时的修复提示（BuildRunner 已经攒了 hints，这里只做展示）。
  Widget _failureHints() {
    final hints = r.hints;
    if (hints.isEmpty) {
      return Text(
        '打开日志看最后 20 行，通常能看到真正的错误原因。'
        '如果是莫名其妙的失败，先试"清理缓存"再构建。',
        style: TextStyle(
            fontSize: 11, height: 1.6, color: FoaColors.of(context).muted),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFB74D).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lightbulb_outline, size: 16, color: Color(0xFFFFB74D)),
              SizedBox(width: 6),
              Text('可能的修复方向',
                  style:
                      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ),
          // ignore: prefer_const_literals_to_create_immutables
          const SizedBox(height: 6),
          for (final h in hints)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('· ', style: TextStyle(fontSize: 11)),
                  Expanded(
                    child: Text(h,
                        style: const TextStyle(fontSize: 11, height: 1.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------- 日志预览 ----------

  Widget _logPreviewCard() {
    final lines =
        r.lines.length > 6 ? r.lines.sublist(r.lines.length - 6) : r.lines;
    return Card(
      color: const Color(0xFF0C0F13),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openLog,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('日志预览（共 ${r.lines.length} 行）',
                      style: TextStyle(
                          fontSize: 11, color: FoaColors.of(context).muted)),
                  const Spacer(),
                  const Icon(Icons.unfold_more, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  const Text('展开',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
              const SizedBox(height: 6),
              for (final l in lines) _logLine(l, fontSize: 11),
            ],
          ),
        ),
      ),
    );
  }

  /// 一行日志：识别 error / 成功 / 警告，给不同颜色。
  ///
  /// "失败日志高亮"这条要求的关键不是染色，而是**别把关键词埋在
  /// 3000 行里**——所以除了颜色，错误行还会加左侧竖条。
  Widget _logLine(String l, {double fontSize = 11}) {
    final low = l.toLowerCase();
    final isErr = low.contains('error') ||
        low.contains('✗') ||
        low.contains('failed') ||
        low.contains('exception') ||
        low.contains('cannot find');
    final isOk = low.contains('✓') ||
        low.contains('build success') ||
        low.contains('built build/app/outputs');
    final isWarn = !isErr && (low.contains('warn') || low.contains('警告'));

    final color = isErr
        ? const Color(0xFFFF7A7A)
        : isOk
            ? const Color(0xFF3DDC84)
            : isWarn
                ? const Color(0xFFFFB74D)
                : const Color(0xFFD6DEE8);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isErr || isOk)
            Container(
              width: 2,
              height: fontSize * 1.4,
              margin: const EdgeInsets.only(right: 6, top: 1),
              color: color,
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Text(
              l,
              style: TextStyle(
                fontSize: fontSize,
                fontFamily: 'monospace',
                height: 1.4,
                color: color,
                fontWeight:
                    (isErr || isOk) ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 全屏日志 BottomSheet。
///
/// 单独一个 widget 是为了能自己订阅 BuildRunner 的刷新回调——
/// 如果在父页里渲染，构建中的每次刷新会把整个打包区重建一遍。
class _LogSheet extends StatefulWidget {
  final BuildRunner Function() getRunner;
  final VoidCallback onClosed;

  const _LogSheet({required this.getRunner, required this.onClosed});

  @override
  State<_LogSheet> createState() => _LogSheetState();
}

class _LogSheetState extends State<_LogSheet> {
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;
  bool _onlyErrors = false;

  BuildRunner get r => widget.getRunner();

  @override
  void initState() {
    super.initState();
    // 接管 UI 刷新回调（原回调属于父页，这里叠加一层）
    final prev = r.onUiChanged;
    r.onUiChanged = () {
      prev?.call();
      if (mounted) setState(() {});
      if (_autoScroll) _toBottom();
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
  }

  @override
  void dispose() {
    // 还原：不清掉的话 BottomSheet 关掉后回调还指着已销毁的 State
    r.onUiChanged = null;
    _scroll.dispose();
    widget.onClosed();
    super.dispose();
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  List<String> get _lines {
    if (!_onlyErrors) return r.lines;
    const low = ['error', '✗', 'failed', 'exception', 'cannot find'];
    return r.lines
        .where((l) => low.any((k) => l.toLowerCase().contains(k)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final maxH = MediaQuery.of(context).size.height * 0.85;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 抓手
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 16, color: Color(0xFF4C8DFF)),
                const SizedBox(width: 8),
                const Text('构建日志',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text('${lines.length} 行',
                    style: TextStyle(
                        fontSize: 11, color: FoaColors.of(context).muted)),
                const Spacer(),
                IconButton(
                  tooltip: _onlyErrors ? '显示全部' : '只看错误',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _onlyErrors = !_onlyErrors),
                  icon: Icon(
                    _onlyErrors ? Icons.filter_alt : Icons.filter_alt_off,
                    size: 18,
                    color: _onlyErrors ? const Color(0xFFFF7A7A) : Colors.grey,
                  ),
                ),
                IconButton(
                  tooltip: _autoScroll ? '停止自动滚动' : '跟随最新日志',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    setState(() => _autoScroll = !_autoScroll);
                    if (_autoScroll) _toBottom();
                  },
                  icon: Icon(
                    _autoScroll
                        ? Icons.vertical_align_bottom
                        : Icons.pause_circle_outline,
                    size: 18,
                    color: _autoScroll ? const Color(0xFF4C8DFF) : Colors.grey,
                  ),
                ),
                IconButton(
                  tooltip: '复制全部日志',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: r.lines.join('\n')));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制全部日志'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_all, size: 18),
                ),
              ],
            ),
          ),
          const Divider(height: 16),
          if (r.building)
            LinearProgressIndicator(
              value: r.prog.progress,
              minHeight: 2,
              backgroundColor: Colors.white10,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Color(0xFF4C8DFF)),
            ),
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Text(
                      _onlyErrors ? '没有匹配的错误行' : '暂无日志',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted),
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      // 用户手动上滑 → 关掉自动跟随（否则会被一直拽回底部）
                      if (n is UserScrollNotification) {
                        final atBottom = _scroll.hasClients &&
                            _scroll.position.pixels >=
                                _scroll.position.maxScrollExtent - 24;
                        if (_autoScroll != atBottom) {
                          setState(() => _autoScroll = atBottom);
                        }
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => _line(lines[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _line(String l) {
    final low = l.toLowerCase();
    final isErr = low.contains('error') ||
        low.contains('✗') ||
        low.contains('failed') ||
        low.contains('exception');
    final isOk = low.contains('✓') || low.contains('build success');
    final color = isErr
        ? const Color(0xFFFF7A7A)
        : isOk
            ? const Color(0xFF3DDC84)
            : const Color(0xFFD6DEE8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: SelectableText(
        l,
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: 'monospace',
          height: 1.45,
          color: color,
          fontWeight: isErr || isOk ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
    );
  }
}
