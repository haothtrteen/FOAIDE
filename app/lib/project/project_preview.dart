import 'package:flutter/material.dart';

import '../env/models.dart';
import '../editor/web_preview_page.dart';
import '../editor/web_preview_service.dart';
import '../toolchain/build_page.dart';
import '../toolchain/build_runner.dart';
import '../toolchain/diag_page.dart';
import '../mcp/remote_takeover_page.dart';
import '../filemanager/fs_browser_bridge.dart';
import 'project_stats.dart';

/// 项目工作台 ·「预览」区（alpha.61 重做）。
///
/// 原「概览」区只有一张信息卡 + 两个快捷入口，用户反馈"界面太空"。
/// 本次按反馈补齐为**以"这个项目现在什么状态"为中心**的面板：
///
/// - 顶部仍是项目信息（名称/包名/版本/依赖）；
/// - 一行三个操作卡：Web 预览（热重载）、远程接管、故障排查；
/// - 「依赖管理」卡：pub 缓存里已下载几个包、占多少空间——回答
///   "我依赖到底拉全了没"；
/// - 「构建历史」卡：最近一次构建状态 + 最近几次产物（文件名/大小/时间），
///   回答"我上次打包成功了吗、包在哪"。
///
/// 设计原则：**每一格都要有真数据，没有就显示"暂无"**。空卡片比没有卡片更糟。
class ProjectPreview extends StatefulWidget {
  final String projectName;
  final ManifestInfo info;
  final EnvInfo? env;
  final VoidCallback onOpenCode;
  final VoidCallback onOpenBuild;

  const ProjectPreview({
    super.key,
    required this.projectName,
    required this.info,
    required this.env,
    required this.onOpenCode,
    required this.onOpenBuild,
  });

  @override
  State<ProjectPreview> createState() => _ProjectPreviewState();
}

class _ProjectPreviewState extends State<ProjectPreview> {
  final FileBrowserBridge _fb = FileBrowserBridge();
  late final ProjectStatsReader _reader = ProjectStatsReader(_fb);

  ProjectStats _stats = ProjectStats.empty;
  bool _loadingStats = true;
  bool _depsFetched = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _loadingStats = true);
    try {
      final stats = await _reader.read(widget.projectName, fallback: _stats);
      final deps = await _reader.depsFetched(widget.projectName);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _depsFetched = deps;
        _loadingStats = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingStats = false);
    }
  }

  WebPreviewService get _preview => WebPreviewService.I;

  /// 打开 Web 预览（会话可能已在后台跑，直接挂回）。
  void _openWebPreview() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WebPreviewPage(
        projectRoot: '/root/projects/${widget.projectName}',
        autoStart: !_preview.busy,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _loadStats,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _infoCard(),
          const SizedBox(height: 12),
          _actionRow(),
          const SizedBox(height: 12),
          _depsCard(),
          const SizedBox(height: 12),
          _buildHistoryCard(),
          if (widget.env != null && !widget.env!.rootfsInstalled) ...[
            const SizedBox(height: 12),
            const Text('rootfs 未初始化：构建/文件浏览需先在主页完成环境安装',
                style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
          ],
        ],
      ),
    );
  }

  // ---------------- ① 项目信息 ----------------

  Widget _infoCard() {
    final i = widget.info;
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.flutter_dash,
                      color: cs.onPrimaryContainer, size: 28),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(i.pubName.isEmpty ? widget.projectName : i.pubName,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                      if (i.description.isNotEmpty)
                        Text(i.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新统计',
                  onPressed: _loadingStats ? null : _loadStats,
                  icon: _loadingStats
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            const Divider(height: 24),
            _kv('包名', i.appId.isEmpty ? '—' : i.appId),
            _kv('版本', '${i.versionName}+${i.versionCode}'),
            _kv('依赖声明', '${i.depCount} 个'),
            _kv('容器路径', '/root/projects/${widget.projectName}'),
            _kv('构建后端',
                i.backendLabel),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(k,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ),
          Expanded(
            child: SelectableText(v,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  // ---------------- ② 三个操作入口 ----------------

  Widget _actionRow() {
    return Row(
      children: [
        Expanded(
          child: _actionCard(
            Icons.web,
            'Web 预览',
            _preview.busy ? '运行中 · 点此挂回' : '热重载调试',
            () => _openWebPreview(),
            highlight: _preview.busy,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _actionCard(
            Icons.hub_outlined,
            '远程接管',
            '让 AI 接入',
            () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) =>
                  RemoteTakeoverPage(projectName: widget.projectName),
            )),
            highlight: false,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _actionCard(
            Icons.health_and_safety_outlined,
            '故障排查',
            '环境自检',
            () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const DiagPage(),
            )),
            highlight: false,
          ),
        ),
      ],
    );
  }

  Widget _actionCard(
    IconData icon,
    String title,
    String sub,
    VoidCallback onTap, {
    required bool highlight,
  }) {
    final cs = Theme.of(context).colorScheme;
    final accent = highlight ? const Color(0xFF3DDC84) : cs.primary;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          child: Column(
            children: [
              Icon(icon, size: 26, color: accent),
              const SizedBox(height: 8),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(sub,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10.5, color: Colors.grey.shade500)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- ③ 依赖管理 ----------------

  Widget _depsCard() {
    final s = _stats;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('依赖管理',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  tooltip: '刷新',
                  visualDensity: VisualDensity.compact,
                  onPressed: _loadingStats ? null : _loadStats,
                  icon: const Icon(Icons.refresh, size: 17),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _metric(
                    '已缓存包',
                    _loadingStats && s.cachedPackages == 0
                        ? '…'
                        : '${s.cachedPackages}',
                    '个',
                  ),
                ),
                Container(
                    width: 1, height: 32, color: Colors.grey.withValues(alpha: 0.25)),
                Expanded(
                  child: _metric(
                    '缓存占用',
                    _loadingStats && s.pubCacheBytes == 0
                        ? '…'
                        : fmtBytes(s.pubCacheBytes),
                    '',
                  ),
                ),
                Container(
                    width: 1, height: 32, color: Colors.grey.withValues(alpha: 0.25)),
                Expanded(
                  child: _metric(
                    '本项目',
                    '${widget.info.depCount}',
                    '个声明',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  _depsFetched ? Icons.check_circle : Icons.error_outline,
                  size: 15,
                  color: _depsFetched
                      ? const Color(0xFF3DDC84)
                      : const Color(0xFFFFA000),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _depsFetched
                        ? '本项目依赖已拉取（.dart_tool/package_config.json 存在）'
                        : '本项目依赖尚未拉取——打包前会自动执行 pub get',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.grey.shade600,
                        height: 1.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '缓存目录：${ProjectStatsReader.pubCacheDir}/hosted/pub.dev'
              ' · 多个项目共用，删掉会拖慢下次打包',
              style: TextStyle(
                  fontSize: 11, color: Colors.grey.shade600, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value, String unit) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(unit,
                  style:
                      TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
      ],
    );
  }

  // ---------------- ④ 构建历史 ----------------

  Widget _buildHistoryCard() {
    final r = BuildRunner.I;
    final mine = r.active == widget.projectName;
    final arts = _stats.artifacts;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('构建历史',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (arts.length > 1)
                  Text('${arts.length} 个产物',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
            const SizedBox(height: 10),
            _lastBuildRow(r, mine),
            if (arts.isEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.inbox_outlined,
                      size: 16, color: Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('还没有构建产物——去「打包」页构建第一个 APK',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600)),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 4),
              for (final a in arts.take(3)) _artifactRow(a),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: widget.onOpenBuild,
                  icon: const Icon(Icons.build_outlined, size: 16),
                  label: const Text('去打包', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                if (arts.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const BuildPage()),
                    ),
                    icon: const Icon(Icons.install_mobile, size: 16),
                    label: const Text('安装产物',
                        style: TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「最近一次构建」一行：优先显示**本次会话**的真实状态，
  /// 没有会话状态时退回"产物存在即成功"的推断（并说明依据）。
  Widget _lastBuildRow(BuildRunner r, bool mine) {
    late final IconData icon;
    late final Color color;
    late final String text;

    if (mine && r.building) {
      icon = Icons.hourglass_top;
      color = const Color(0xFF4C8DFF);
      text = '正在构建中… ${r.prog.percent}%'
          '（${r.prog.stage.label}）';
    } else if (mine && r.status == BuildStatus.done) {
      icon = Icons.check_circle;
      color = const Color(0xFF3DDC84);
      text = '最近一次：成功'
          '${r.elapsedSec > 0 ? ' · 耗时 ${BuildRunner.fmtDur(r.elapsedSec)}' : ''}';
    } else if (mine && r.status == BuildStatus.error) {
      icon = Icons.error_outline;
      color = const Color(0xFFFF7A7A);
      text = '最近一次：失败（可在打包页查看日志与修复建议）';
    } else if (mine && r.status == BuildStatus.cancelled) {
      icon = Icons.cancel_outlined;
      color = Colors.grey;
      text = '最近一次：已取消';
    } else if (_stats.artifacts.isNotEmpty) {
      // 本进程没有构建记录，但磁盘上有产物（上次打开 App 时构建的）
      final a = _stats.latest!;
      icon = Icons.check_circle_outline;
      color = const Color(0xFF3DDC84);
      text = '磁盘上有产物：${a.displayName}'
          '（${fmtRelativeTime(a.mtimeMs)}）';
    } else {
      icon = Icons.remove_circle_outline;
      color = Colors.grey;
      text = '本次会话还没有构建记录';
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: const TextStyle(fontSize: 12.5, height: 1.45)),
        ),
      ],
    );
  }

  Widget _artifactRow(ApkArtifact a) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          const Icon(Icons.android, size: 14, color: Color(0xFF3DDC84)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(a.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, fontFamily: 'monospace')),
          ),
          Text('${fmtBytes(a.sizeBytes)} · ${fmtRelativeTime(a.mtimeMs)}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
      ),
    );
  }
}

/// 项目元信息（由 ProjectPage 解析后传入，避免本组件再读一遍文件）。
class ManifestInfo {
  final String pubName;

  /// 桌面显示的应用名（Manifest `android:label`）。
  /// pubName 是 dart 侧的包标识，两者经常不一样，所以分开存。
  final String label;

  final String description;
  final String appId;
  final String versionName;
  final String versionCode;
  final int depCount;
  final String backendLabel;

  const ManifestInfo({
    this.pubName = '',
    this.label = '',
    this.description = '',
    this.appId = '',
    this.versionName = '1.0.0',
    this.versionCode = '1',
    this.depCount = 0,
    this.backendLabel = '',
  });
}
