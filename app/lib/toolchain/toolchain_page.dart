import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'jdk_installer.dart';
import 'sdk_downloader.dart';

/// Step 3 工具链页：JDK 17 安装 / 卸载 / 验证。
///
/// 状态机：idle → probing → downloading(进度) → extracting → validating
///       → installed；任意阶段失败 → error（可重试）。
class ToolchainPage extends StatefulWidget {
  const ToolchainPage({super.key});

  @override
  State<ToolchainPage> createState() => _ToolchainPageState();
}

enum JdkPhase {
  idle,
  probing,
  downloading,
  extracting,
  validating,
  installed,
  uninstalling,
  error,
}

class _ToolchainPageState extends State<ToolchainPage> {
  final ProotBridge _bridge = ProotBridge();

  JdkPhase _phase = JdkPhase.idle;
  DownloadProgress? _progress;
  String _mirrorName = '';
  String _version = '';
  String _error = '';
  EnvInfo? _env;
  DownloadCancelToken? _token;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final env = await _bridge.envInfo();
      final v = env.rootfsInstalled
          ? await JdkInstaller.installedVersion(_bridge)
          : null;
      if (!mounted) return;
      setState(() {
        _env = env;
        _phase = v == null ? JdkPhase.idle : JdkPhase.installed;
        _version = v ?? '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = JdkPhase.error;
        _error = '检测失败：$e';
      });
    }
  }

  Future<void> _install() async {
    setState(() {
      _phase = JdkPhase.probing;
      _progress = null;
      _error = '';
    });
    _token = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final ver = await JdkInstaller.install(
        _bridge,
        env,
        token: _token,
        onPhase: (p) {
          if (!mounted) return;
          setState(() {
            _phase = switch (p) {
              'probing' => JdkPhase.probing,
              'downloading' => JdkPhase.downloading,
              'extracting' => JdkPhase.extracting,
              'validating' => JdkPhase.validating,
              _ => _phase,
            };
          });
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
        onMirrorSwitch: (m) {
          if (!mounted) return;
          setState(() => _mirrorName = m.name);
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = JdkPhase.installed;
        _version = ver;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = JdkPhase.error;
        _error = e.toString();
      });
    }
  }

  Future<void> _cancel() async {
    _token?.cancel();
    setState(() => _phase = JdkPhase.idle);
  }

  Future<void> _uninstall() async {
    final ok = await _confirm('卸载 JDK', '将删除 /opt/jdk（约 300MB），确定？');
    if (!ok) return;
    setState(() => _phase = JdkPhase.uninstalling);
    await JdkInstaller.uninstall(_bridge);
    await _refresh();
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('工具链 · JDK 17')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _JdkCard(
            phase: _phase,
            progress: _progress,
            mirrorName: _mirrorName,
            version: _version,
            error: _error,
            env: _env,
            onInstall: _install,
            onCancel: _cancel,
            onUninstall: _uninstall,
            onVerify: _refresh,
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('说明',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 8),
                  Text(
                    'JDK 17（Temurin）将安装到容器内 /opt/jdk，供后续构建 APK 使用。\n'
                    '下载走国内镜像（TUNA 清华为主），支持断点续传与 SHA-256 校验，'
                    '失败自动切换镜像。',
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade400),
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

class _JdkCard extends StatelessWidget {
  final JdkPhase phase;
  final DownloadProgress? progress;
  final String mirrorName;
  final String version;
  final String error;
  final EnvInfo? env;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onUninstall;
  final VoidCallback onVerify;

  const _JdkCard({
    required this.phase,
    required this.progress,
    required this.mirrorName,
    required this.version,
    required this.error,
    required this.env,
    required this.onInstall,
    required this.onCancel,
    required this.onUninstall,
    required this.onVerify,
  });

  @override
  Widget build(BuildContext context) {
    final busy = phase == JdkPhase.probing ||
        phase == JdkPhase.downloading ||
        phase == JdkPhase.extracting ||
        phase == JdkPhase.validating ||
        phase == JdkPhase.uninstalling;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (phase) {
                    JdkPhase.installed => Icons.check_circle,
                    JdkPhase.error => Icons.error_outline,
                    _ => Icons.build_circle_outlined,
                  },
                  color: switch (phase) {
                    JdkPhase.installed => const Color(0xFF3DDC84),
                    JdkPhase.error => const Color(0xFFFF7A7A),
                    _ => Colors.orangeAccent,
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  switch (phase) {
                    JdkPhase.installed => 'JDK 已安装',
                    JdkPhase.error => '安装失败',
                    JdkPhase.probing => '正在探测镜像源…',
                    JdkPhase.downloading => '正在下载 JDK…',
                    JdkPhase.extracting => '正在解压到 /opt/jdk…',
                    JdkPhase.validating => '正在验证 java / javac…',
                    JdkPhase.uninstalling => '正在卸载…',
                    JdkPhase.idle => 'JDK 未安装',
                  },
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 20),
            _kv('版本', phase == JdkPhase.installed ? version : JdkInstaller.version),
            _kv('镜像', mirrorName.isEmpty ? '待选源' : mirrorName),
            _kv('大小', '${(JdkInstaller.size / 1048576).toStringAsFixed(0)} MB'),
            if (phase == JdkPhase.downloading && progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress!.fraction,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 6),
              Text(
                '${(progress!.received / 1048576).toStringAsFixed(1)} / '
                '${(progress!.total / 1048576).toStringAsFixed(1)} MB · '
                '${(progress!.speed / 1048576).toStringAsFixed(1)} MB/s',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (phase == JdkPhase.error && error.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(error,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                if (phase == JdkPhase.installed) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onVerify,
                      icon: const Icon(Icons.verified_outlined, size: 18),
                      label: const Text('重新验证'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy ? null : onUninstall,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('卸载'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF7A7A),
                      ),
                    ),
                  ),
                ] else if (busy) ...[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('取消'),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: env?.rootfsInstalled != true ? null : onInstall,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('下载并安装'),
                    ),
                  ),
                ],
              ],
            ),
            if (env?.rootfsInstalled != true) ...[
              const SizedBox(height: 8),
              const Text('请先在主页初始化 rootfs 环境',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(k,
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13)),
            ),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'monospace'))),
          ],
        ),
      );
}
