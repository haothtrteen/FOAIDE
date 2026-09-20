import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../env/proot_bridge.dart';
import '../mcp/cloudflared_install.dart';
import '../mcp/mcp_schema.dart';
import '../mcp/mcp_server.dart';
import '../mcp/tunnel_service.dart';
import '../core/theme.dart';

/// 项目工作台 ·「AI 接管」面板（alpha.60）。
///
/// 与「远程接管」页的分工：
/// - 远程接管页 = **设备级开关**（起/停隧道、看隧道日志、首次风险确认）；
/// - 本面板 = **项目级上下文**（当前项目的接管状态、把这个项目交给 AI 的
///   提示词、远程操作记录）。
///
/// 架构决定：隧道是**设备级**的（一个端口、一个令牌），不是项目级。
/// 因此这里显示全局隧道状态 + 注入当前项目上下文，**不为每个项目开独立
/// 隧道**——多隧道意味着多令牌、多进程、端口管理，收益为零。
///
/// Bug 458（alpha.61）：本面板**不再跳转**「远程接管」页。
/// 用户反馈"点 AI 接管却跳到了远程接管页"，并猜测是 cloudflared 没装成功
/// 所致——猜测方向对，但根因不是安装失败，而是**这个按钮从一开始就是
/// 一个纯跳转**：开启/停止隧道的能力全在另一个页面里，本面板只负责导航。
/// 现已把「开启 / 停止 / 续期 / 复制地址」全部下沉到本面板就地完成，
/// 并就地暴露 cloudflared 的安装状态与安装入口（不再让用户猜"为什么开不了"）。
class AiTakeoverPanel extends StatefulWidget {
  final String projectName;

  const AiTakeoverPanel({super.key, required this.projectName});

  @override
  State<AiTakeoverPanel> createState() => _AiTakeoverPanelState();
}

class _AiTakeoverPanelState extends State<AiTakeoverPanel> {
  TunnelService get t => TunnelService.I;
  McpServer get mcp => McpServer.I;
  final ProotBridge _bridge = ProotBridge();

  /// UI 侧防连点（与 service 的 busy 互补）。
  bool _busy = false;

  /// cloudflared 是否已落位（宿主侧快速判态，不阻塞 UI）。
  bool _cfInstalled = false;
  bool _cfChecked = false;

  String get _projRoot => '$kProjectsRootMcp/${widget.projectName}';

  @override
  void initState() {
    super.initState();
    // 隧道是服务层状态，UI 只是投影——切走再回来要能挂回
    t.onUiChanged = () {
      if (mounted) setState(() {});
    };
    _refreshCfState();
  }

  @override
  void dispose() {
    t.onUiChanged = null;
    super.dispose();
  }

  /// 探测 cloudflared 是否已装（只在装了 rootfs 时有意义）。
  Future<void> _refreshCfState() async {
    try {
      final env = await _bridge.envInfo();
      if (!mounted) return;
      setState(() {
        _cfInstalled = env.rootfsInstalled &&
            CloudflaredInstall.installedSync(env);
        _cfChecked = true;
      });
    } catch (_) {
      if (mounted) setState(() => _cfChecked = true);
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已复制$what'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  String _handoff() => buildHandoffPrompt(
        tunnelUrl: t.url,
        token: mcp.token,
        projectName: widget.projectName,
        projectRoot: _projRoot,
      );

  // ---------------- 就地操作（Bug 458） ----------------

  /// 首次启用前的强制风险确认——与远程接管页同一套口径。
  Future<bool> _confirmRisk() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Color(0xFFFFA000)),
          SizedBox(width: 8),
          Text('开启前请确认'),
        ]),
        content: const SingleChildScrollView(
          child: Text(
            '开启后，任何拿到【隧道地址 + 令牌】的人都能以本应用的身份，\n'
            '在这台手机的容器内执行任意命令、读写你的项目文件。\n\n'
            '请注意：\n'
            '· 这是「AI 接管」的设计目的，不是漏洞；\n'
            '· 破坏范围限于容器内——Android 宿主文件与系统不受影响；\n'
            '· 会话 30 分钟后自动停止，你也可以随时手动停止；\n'
            '· 所有远程操作都会显示在本面板的「远程操作记录」中。\n\n'
            '请仅在完全信任对方时开启，用完立即停止。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('我了解风险，开启'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _snack(String msg, {bool long = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: long ? 6 : 3),
    ));
  }

  /// 就地在面板内开启接管（原先这里是 push 到另一个页面）。
  Future<void> _startInline() async {
    if (_busy || t.busy || t.status == TunnelStatus.running) return;
    if (!await _confirmRisk()) return;
    if (!mounted) return;

    setState(() => _busy = true);
    try {
      final env = await _bridge.envInfo();
      if (!mounted) return;
      if (!env.rootfsInstalled) {
        _snack('容器环境未就绪：请先完成环境安装');
        return;
      }
      final err = await t.start(projectRoot: _projRoot, env: env);
      if (!mounted) return;
      if (err != null) {
        _snack(err, long: true);
      } else {
        _snack('AI 接管已开启', long: false);
      }
      await _refreshCfState();
    } catch (e) {
      _snack('启动失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopInline() async {
    setState(() => _busy = true);
    try {
      await t.stop(reason: '用户手动停止');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TunnelStatus>(
      valueListenable: t.statusN,
      builder: (ctx, st, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusCard(st),
          const SizedBox(height: 12),
          _handoffCard(st),
          const SizedBox(height: 12),
          _auditCard(),
          const SizedBox(height: 12),
          _boundaryCard(),
        ],
      ),
    );
  }

  // ---------------- ① 隧道状态 ----------------

  Widget _statusCard(TunnelStatus st) {
    final running = st == TunnelStatus.running;
    final (icon, color, label) = switch (st) {
      TunnelStatus.idle => (Icons.cloud_off, Colors.grey, '未开启'),
      TunnelStatus.installing => (
          Icons.downloading,
          const Color(0xFF64B5F6),
          '正在安装组件…'
        ),
      TunnelStatus.starting => (
          Icons.hourglass_top,
          const Color(0xFFFFA000),
          '正在建立隧道…'
        ),
      TunnelStatus.running => (
          Icons.cloud_done,
          const Color(0xFF3DDC84),
          '已开启'
        ),
      TunnelStatus.error => (
          Icons.error_outline,
          const Color(0xFFCF6679),
          '已中断'
        ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('AI 接管 · $label',
                      style:
                          const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (running && t.remainSec != null)
                  Text('剩余 ${remainLabel(t.remainSec)}',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted)),
              ],
            ),
            const SizedBox(height: 8),
            if (running && t.url != null) ...[
              SelectableText(
                t.url!,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFF3DDC84)),
              ),
              const SizedBox(height: 4),
              Text('这个地址对公网开放，可让你的 AI 接入这台设备。',
                  style: TextStyle(
                      fontSize: 12, color: FoaColors.of(context).muted)),
            ] else
              Text(
                '开启后，你的 AI 客户端就能读取本项目文件、在容器内执行命令、'
                '调用故障诊断——相当于把「这台手机的开发环境」交给它。',
                style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: FoaColors.of(context).muted),
              ),
            // Bug 458：把 cloudflared 状态就地摆明，不让用户猜"为什么开不了"。
            if (_cfChecked && st == TunnelStatus.idle) ...[
              const SizedBox(height: 8),
              _cfStateRow(),
            ],
            if (t.error != null) ...[
              const SizedBox(height: 6),
              Text('错误：${t.error}',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFCF6679))),
            ],
            const SizedBox(height: 12),
            // Bug 458：全部就地完成，不再跳转「远程接管」页。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!t.busy && !running)
                  FilledButton.icon(
                    onPressed: _busy ? null : _startInline,
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: Text(st == TunnelStatus.error ? '重新开启' : '开启 AI 接管'),
                  ),
                if (t.busy || running) ...[
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _stopInline,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('停止'),
                  ),
                  if (running)
                    OutlinedButton.icon(
                      onPressed: () => t.extend(),
                      icon: const Icon(Icons.timer_outlined, size: 18),
                      label: const Text('续期 30 分钟'),
                    ),
                  if (running && t.url != null)
                    OutlinedButton.icon(
                      onPressed: () => _copy(t.url!, '隧道地址'),
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('复制地址'),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// cloudflared 组件状态行：已装显示版本位；未装给就地安装入口。
  Widget _cfStateRow() {
    final ok = _cfInstalled;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.info_outline,
          size: 15,
          color: ok ? const Color(0xFF3DDC84) : const Color(0xFFFFA000),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ok
                ? '隧道组件 cloudflared 已就绪'
                : '首次开启会自动下载隧道组件 cloudflared'
                    '（约 36MB，只下一次）',
            style: TextStyle(
                fontSize: 11.5, color: FoaColors.of(context).muted, height: 1.4),
          ),
        ),
      ],
    );
  }

  // ---------------- ② 交给你的 AI（预填提示词） ----------------

  Widget _handoffCard(TunnelStatus st) {
    final ready = st == TunnelStatus.running;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('把这个项目交给你的 AI',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '复制下面这段粘贴给你的 AI 客户端。里面已经写好：隧道地址、'
              '令牌、项目路径、可用工具、以及「慢是正常的」「构建与预览互斥」'
              '这些它必须知道的事——省掉它自己摸索的几轮往返。',
              style: TextStyle(
                  fontSize: 12, color: FoaColors.of(context).muted, height: 1.45),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF101418),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                ready
                    ? '项目：${widget.projectName}\n'
                        '路径：$_projRoot\n'
                        '地址：${t.url}/mcp\n'
                        '鉴权：Authorization: Bearer ${mcp.token}'
                    : '（开启接管后，这里会显示将要发送给 AI 的完整说明）',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.5,
                  color: Color(0xFFCAD3D5),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed:
                      ready ? () => _copy(_handoff(), '完整接入说明') : null,
                  icon: const Icon(Icons.assignment_ind, size: 18),
                  label: const Text('复制接入说明'),
                ),
                OutlinedButton.icon(
                  onPressed: ready ? () => _copy(mcp.token, '令牌') : null,
                  icon: const Icon(Icons.key, size: 18),
                  label: const Text('仅复制令牌'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- ③ 远程操作记录 ----------------

  Widget _auditCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('远程操作记录',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('最近 ${mcp.audit.length} 条 · 实时',
                    style: TextStyle(
                        fontSize: 11, color: FoaColors.of(context).muted)),
              ],
            ),
            const SizedBox(height: 4),
            Text('AI 在你设备上的每次操作都会出现在这里——这是你的监督窗口。',
                style: TextStyle(
                    fontSize: 12, color: FoaColors.of(context).muted)),
            const SizedBox(height: 10),
            ValueListenableBuilder<int>(
              valueListenable: mcp.auditRevisionN,
              builder: (ctx, _, __) {
                if (mcp.audit.isEmpty) {
                  return Text('（暂无记录）',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted));
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: mcp.audit.reversed
                      .take(30)
                      .map((a) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              '${a.timeLabel}  ${a.tool}  ${a.summary}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                height: 1.35,
                                color: a.ok
                                    ? const Color(0xFFCAD3D5)
                                    : const Color(0xFFCF6679),
                              ),
                            ),
                          ))
                      .toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- ④ 能力边界 ----------------

  Widget _boundaryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AI 能做到 / 做不到',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _li(true, '读、写、列本项目文件（含所有子目录）'),
            _li(true, '在容器内执行 shell 命令（单条 ≤600 秒）'),
            _li(true, '调用故障诊断，一次拿到 8 项环境报告'),
            _li(true, '查看设备与 Flutter SDK 信息'),
            _li(false, '访问 Android 宿主文件、相册、其他 App 数据',
                note: '容器内根本看不到，不是权限问题'),
            _li(false, '直接触发 APK 构建',
                note: '会抢 Flutter 启动锁并阻塞你，需你亲自操作'),
            _li(false, '同时执行多条命令', note: '容器为单队列，并发返回 DeviceBusy'),
            const SizedBox(height: 6),
            Text(
              '可用工具共 ${kTools.length} 项：'
              '${kTools.map((t) => t.name).join('、')}',
              style: TextStyle(
                  fontSize: 11, color: FoaColors.of(context).muted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _li(bool ok, String text, {String? note}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              ok ? Icons.check_circle_outline : Icons.remove_circle_outline,
              size: 15,
              color: ok ? const Color(0xFF3DDC84) : FoaColors.of(context).muted,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12, height: 1.4),
                children: [
                  TextSpan(text: text),
                  if (note != null)
                    TextSpan(
                      text: '（$note）',
                      style: TextStyle(color: FoaColors.of(context).muted),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
