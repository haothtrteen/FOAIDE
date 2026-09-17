import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../env/env_installer.dart';
import '../editor/editor_page.dart';
import '../filemanager/file_browser_page.dart';
import '../toolchain/toolchain_page.dart';
import 'terminal_page.dart';

/// Step 1 主页：环境状态 + 初始化引导。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final env = context.watch<EnvState>();
    return Scaffold(
      appBar: AppBar(
        title: const SafeArea(
          child: Text('Flutter On Android · Step 1'),
        ),
        actions: [
          IconButton(
            tooltip: '重新检测',
            onPressed: env.installing ? null : () => env.refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(env: env),
          const SizedBox(height: 12),
          _ActionCard(env: env),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final EnvState env;
  const _StatusCard({required this.env});

  @override
  Widget build(BuildContext context) {
    final info = env.info;

    if (info == null && env.error == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (info == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('初始化失败',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Color(0xFFFF7A7A))),
              const SizedBox(height: 8),
              SelectableText(env.error ?? ''),
            ],
          ),
        ),
      );
    }

    final i = info;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  i.rootfsInstalled
                      ? Icons.check_circle
                      : Icons.info_outline,
                  color: i.rootfsInstalled
                      ? const Color(0xFF3DDC84)
                      : Colors.orangeAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  i.rootfsInstalled ? '环境已就绪' : '环境未安装',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 20),
            _kv('设备', '${i.device} · Android API ${i.androidSdk}'),
            _kv('ABI', i.abi ?? '-'),
            _kv('rootfs',
                i.rootfsInstalled ? i.rootfsPath : '未安装（点下方按钮初始化）'),
            _kv('proot', i.prootPath ?? '未找到（jniLibs 与 assets 均无）'),
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
                child: Text(v, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}

class _ActionCard extends StatelessWidget {
  final EnvState env;
  const _ActionCard({required this.env});

  @override
  Widget build(BuildContext context) {
    final installed = env.isInstalled;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!installed) ...[
              const Text('下一步', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                  '初始化会把内置的 Debian rootfs 解压到应用私有目录，仅需一次。'),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: env.installing ? null : () => env.installRootfs(),
                  icon: env.installing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download),
                  label: Text(env.installing ? '正在解压 rootfs…' : '初始化环境'),
                ),
              ),
            ] else ...[
              const Text('环境就绪', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('进入终端执行测试命令，或打开编辑器浏览/编辑项目文件。'),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => GridView.count(
                  crossAxisCount: constraints.maxWidth >= 560 ? 3 : 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 2.2,
                  children: [
                    _ActionTile(
                      icon: Icons.terminal,
                      label: '打开终端',
                      primary: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const TerminalPage()),
                      ),
                    ),
                    _ActionTile(
                      icon: Icons.code,
                      label: '打开编辑器',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => EditorPage()),
                      ),
                    ),
                    _ActionTile(
                      icon: Icons.folder_open,
                      label: '文件浏览器',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const FileBrowserPage()),
                      ),
                    ),
                    _ActionTile(
                      icon: Icons.build,
                      label: '工具链',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ToolchainPage()),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (env.installLog.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(env.installLog,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade400)),
            ],
            if (env.error != null) ...[
              const SizedBox(height: 8),
              Text(env.error!,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
          ],
        ),
      ),
    );
  }
}

/// 宫格操作块：图标置顶、文字居下，主操作高亮。
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: primary ? cs.primary : cs.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 30,
                color: primary ? cs.onPrimary : cs.onSecondaryContainer),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: primary ? cs.onPrimary : cs.onSecondaryContainer)),
          ],
        ),
      ),
    );
  }
}
