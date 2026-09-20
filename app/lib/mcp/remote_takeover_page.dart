import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../env/proot_bridge.dart';
import 'cloudflared_install.dart';
import 'mcp_schema.dart';
import 'mcp_server.dart';
import 'tunnel_service.dart';
import '../core/theme.dart';

/// 远程接管页（alpha.60）。
///
/// 做三件事（对应用户原始需求）：
/// 1. **内置一个可远程执行命令的 MCP 服务** —— 跑在 App 进程内
///    （`McpServer`，127.0.0.1:8977），暴露 7 个结构化工具；
/// 2. **引导安装 cloudflared + 一键起隧道** —— 容器内 arm64 原生执行，
///    输出 `*.trycloudflare.com` 公网地址；
/// 3. **讲清楚它有什么用** —— 页面上有安全警告、能力清单、
///    「交给你的 AI」预填提示词、以及**实时审计日志**。
///
/// 安全立场（必须对用户诚实）：本功能的设计目的**就是让远程方能在本机
/// 执行命令**。因此：默认 30 分钟自动停止、随时可停、令牌每次轮换、
/// 所有远程操作实时可见。真正的隔离边界是「容器 ≠ Android 宿主」。
class RemoteTakeoverPage extends StatefulWidget {
  /// 当前项目（用于预填提示词与默认工作目录）；可为 null。
  final String? projectName;

  const RemoteTakeoverPage({super.key, this.projectName});

  @override
  State<RemoteTakeoverPage> createState() => _RemoteTakeoverPageState();
}

class _RemoteTakeoverPageState extends State<RemoteTakeoverPage> {
  TunnelService get t => TunnelService.I;
  McpServer get mcp => McpServer.I;
  final ProotBridge _bridge = ProotBridge();
  final ScrollController _scroll = ScrollController();

  bool _busy = false; // UI 侧防连点（与 service 的 busy 互补）

  @override
  void initState() {
    super.initState();
    t.onUiChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    t.onUiChanged = null;
    _scroll.dispose();
    super.dispose();
  }

  String get _projName => widget.projectName ?? 'my_app';
  String get _projRoot => '$kProjectsRootMcp/$_projName';

  // ============================ 操作 ============================

  /// 首次启用前的强制确认（本功能对外提供 RCE，必须显式告知）。
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
            '· 这是「远程接管」的设计目的，不是漏洞；\n'
            '· 破坏范围限于容器内——Android 宿主文件与系统不受影响；\n'
            '· 会话 30 分钟后自动停止，你也可以随时手动停止；\n'
            '· 所有远程操作都会显示在本页的「远程操作记录」中。\n\n'
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

  Future<void> _start() async {
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
      if (err != null) _snack(err, long: true);
    } catch (e) {
      if (mounted) _snack('启动失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await t.stop(reason: '用户手动停止');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg, {bool long = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: long ? 6 : 3),
    ));
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _snack('已复制$what');
  }

  /// Bug 464：下载诊断——逐个镜像探测并展示**具体失败原因**。
  ///
  /// 为什么值得做成按钮：cloudflared 下载失败的用户反馈无法复现——开发机
  /// 上几个镜像全通，说明是用户网络的点对点问题。不把 DNS/超时/TLS 的
  /// 区别摆出来，用户只能盲目重试，我们也没法判断该修哪里。
  Future<void> _diagnoseDownload() async {
    setState(() => _busy = true);
    final text = await CloudflaredInstall.diagnose();
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('cloudflared 下载源诊断'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '逐个探测 ${CloudflaredInstall.mirrors.length} 个下载源'
                '（${CloudflaredInstall.assetName}，'
                '${(CloudflaredInstall.expectedSize / 1024 / 1024).toStringAsFixed(0)}MB）。',
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: FoaColors.of(ctx).codeBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  text,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 11, height: 1.5),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '若显示"网络：Failed host lookup"→ DNS 解析问题，可换 DNS；\n'
                '若显示"超时"→ 该源被限速或不通，换网络重试；\n'
                '若显示"HTTP 404"→ 版本号可能已失效，请反馈。',
                style: TextStyle(
                    fontSize: 11, height: 1.5, color: FoaColors.of(ctx).muted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(ctx);
              _snack('诊断结果已复制');
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  /// 生成给 AI 的接入说明（含令牌，故要提示用户注意）。
  String _handoff() => buildHandoffPrompt(
        tunnelUrl: t.url,
        token: mcp.token,
        projectName: _projName,
        projectRoot: _projRoot,
      );

  // ============================ build ============================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('远程接管')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _riskCard(),
                _statusCard(),
                _handoffCard(),
                _capabilityCard(),
                _thirdPartyCard(),
                _auditCard(),
                if (t.lines.isNotEmpty) _logCard(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 第三方组件告知（cloudflared）。
  ///
  /// 存在的理由不是合规走形式，而是**用户有权知道手机上会多出什么**：
  /// 这是运行时下载的外部二进制（不随 APK 分发），用谁的、什么许可、
  /// 从哪来，都得摆明。
  Widget _thirdPartyCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('本功能用到的第三方组件',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            Text(
              'cloudflared ${CloudflaredInstall.version}（${CloudflaredInstall.assetName}）'
              ' · Apache-2.0\n'
              '首次使用时下载到容器内 ${CloudflaredInstall.binPath}，'
              '不随本 App 分发、不进 App 进程，仅由容器调用。\n'
              '来源：https://github.com/cloudflare/cloudflared',
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.45,
                  color: FoaColors.of(context).muted),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部安全警告（常驻，不可关闭——这是本功能的性质决定的）。
  Widget _riskCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: const Color(0xFF3A2416),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.shield_outlined,
                color: Color(0xFFFFA000), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('这是「交出去」的能力',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(
                    '开启后可让远程 AI 在这台手机的容器内执行命令、改你的代码。'
                    '破坏范围限于容器（看不到 Android 系统与相册），'
                    '但仍请只对你信任的对象开启，并在用完后立即停止。',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: Colors.orange.shade100),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    final st = t.status;
    final (icon, color, text) = switch (st) {
      TunnelStatus.idle => (
          Icons.cloud_off,
          Colors.grey,
          '未开启'
        ),
      TunnelStatus.installing => (
          Icons.downloading,
          const Color(0xFF64B5F6),
          '正在安装 cloudflared…'
        ),
      TunnelStatus.starting => (
          Icons.hourglass_top,
          const Color(0xFFFFA000),
          '正在建立隧道…'
        ),
      TunnelStatus.running => (
          Icons.cloud_done,
          const Color(0xFF3DDC84),
          '已开启 · 外部可接入'
        ),
      TunnelStatus.error => (
          Icons.error_outline,
          const Color(0xFFCF6679),
          '已中断'
        ),
    };
    final running = st == TunnelStatus.running;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(text,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (t.remainSec != null && running)
                  Text('剩余 ${remainLabel(t.remainSec)}',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted)),
              ],
            ),
            if (t.busy) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 3),
            ],
            if (running && t.url != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF101418),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  t.url!,
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Color(0xFF8AE9B0)),
                ),
              ),
            ],
            if (t.error != null) ...[
              const SizedBox(height: 6),
              Text('错误：${t.error}',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFCF6679))),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!t.busy && !running)
                  FilledButton.icon(
                    onPressed: _busy ? null : _start,
                    icon: const Icon(Icons.play_circle_outline),
                    label: Text(st == TunnelStatus.error ? '重新开启' : '开启远程接管'),
                  ),
                if (t.busy || running) ...[
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _stop,
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
                // Bug 464：下载失败时给用户一个能自查的入口
                OutlinedButton.icon(
                  onPressed: _busy ? null : _diagnoseDownload,
                  icon: const Icon(Icons.network_check, size: 18),
                  label: const Text('下载源诊断'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「把这个交给你的 AI」——把上下文塞进提示词，而不是指望 AI 自己探索。
  Widget _handoffCard() {
    final ready = t.status == TunnelStatus.running;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('把这个交给你的 AI',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              ready
                  ? '复制下面这段发给你的 AI 客户端。它已包含地址、令牌、'
                      '项目路径与注意事项——AI 无需自己摸索环境。'
                  : '隧道就绪后这里会生成一段可直接粘贴给 AI 的接入说明。',
              style: TextStyle(
                  fontSize: 12, color: FoaColors.of(context).muted, height: 1.4),
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
                  label: const Text('复制完整接入说明'),
                ),
                OutlinedButton.icon(
                  onPressed: ready
                      ? () => _copy(
                            '${t.url}/mcp?token=${mcp.token}',
                            '带令牌的地址（注意：令牌会留在对方日志中）',
                          )
                      : null,
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('仅复制地址+令牌'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '令牌：${mcp.token.isEmpty ? '(未开启)' : mcp.token}',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: FoaColors.of(context).muted),
            ),
            const SizedBox(height: 4),
            Text(
              '· 令牌每次开启都会轮换，停止后立即失效。\n'
              '· 「地址+令牌」组合等同于这台机器的钥匙，请勿发到公开场合。',
              style: TextStyle(
                  fontSize: 11, color: FoaColors.of(context).muted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  /// 能力清单（与 mcp_schema 同源渲染——文档不会与实现漂移）。
  Widget _capabilityCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('远程 AI 能做什么',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '以下能力通过 MCP 协议暴露给远程 AI，共 ${kTools.length} 项：',
              style:
                  TextStyle(fontSize: 12, color: FoaColors.of(context).muted),
            ),
            const SizedBox(height: 8),
            ...kTools.map((tool) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Icon(Icons.chevron_right,
                            size: 16, color: Color(0xFF8A939E)),
                      ),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: const TextStyle(fontSize: 12, height: 1.4),
                            children: [
                              TextSpan(
                                text: '${tool.name}  ',
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF9CC7F0),
                                ),
                              ),
                              TextSpan(
                                text: tool.description.split('。').first,
                                style: TextStyle(
                                    color: Colors.grey.shade400),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                )),
            const Divider(height: 20),
            Text(
              '受限说明：① 命令最长 600 秒；② 同一时刻只允许一条命令'
              '（并发返回 DeviceBusy）；③ 破坏性命令被拒绝；'
              '④ 容器内看不到 Android 宿主的文件与相册；'
              '⑤ AI 无法直接触发 APK 构建（会抢锁并阻塞你，需你自己操作）。',
              style: TextStyle(
                  fontSize: 11, color: FoaColors.of(context).muted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  /// 远程操作记录（审计日志实时可见——比弹窗告知更有效）。
  Widget _auditCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('远程操作记录',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('最近 ${mcp.audit.length} 条',
                    style: TextStyle(
                        fontSize: 11, color: FoaColors.of(context).muted)),
              ],
            ),
            const SizedBox(height: 6),
            ValueListenableBuilder<int>(
              valueListenable: mcp.auditRevisionN,
              builder: (ctx, _, __) {
                if (mcp.audit.isEmpty) {
                  return Text('（暂无记录——AI 的每次操作都会出现在这里）',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted));
                }
                final recent = mcp.audit.reversed.take(30).toList();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: recent
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

  Widget _logCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('隧道日志',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              height: 220,
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF101418),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView.builder(
                controller: _scroll,
                itemCount: t.lines.length,
                itemBuilder: (ctx, i) => Text(
                  t.lines[i],
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.4,
                    color: Color(0xFFCAD3D5),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
