import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../env/env_installer.dart';

/// Step 1 终端页：跑测试命令，验证 proot 环境。
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  static const Map<String, String> _commands = {
    'hello': 'echo hello',
    '系统': 'uname -a',
    '发行版': 'cat /etc/os-release',
    'apt': 'apt --version',
    '身份': 'id',
  };

  final ScrollController _scroll = ScrollController();
  String _selected = 'hello';
  bool _running = false;
  final List<String> _lines = [];

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final env = context.read<EnvState>();
    final cmd = _commands[_selected]!;
    if (!env.isInstalled) {
      _append([
        '\$ $cmd',
        '⚠️ 环境未安装：请回主页先「初始化环境」',
        '',
      ]);
      return;
    }
    setState(() => _running = true);
    _append(['\$ $cmd']);
    final r = await env.run(cmd);
    _append([
      if (r.stdout.trim().isNotEmpty) ...r.stdout.trim().split('\n'),
      if (r.stderr.trim().isNotEmpty)
        ...r.stderr.trim().split('\n').map((l) => '⚠ $l'),
      '[exit ${r.exitCode} · ${(r.durationMs / 1000).toStringAsFixed(1)}s]',
      '',
    ]);
    if (mounted) setState(() => _running = false);
  }

  void _append(List<String> newLines) {
    setState(() => _lines.addAll(newLines));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('终端 · 测试命令'),
        actions: [
          IconButton(
            tooltip: '复制全部输出',
            icon: const Icon(Icons.copy),
            onPressed: _lines.isEmpty
                ? null
                : () {
                    Clipboard.setData(
                        ClipboardData(text: _lines.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('已复制'),
                      duration: Duration(seconds: 1),
                    ));
                  },
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(_lines.clear),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Wrap(
              spacing: 8,
              children: [
                for (final entry in _commands.entries)
                  ChoiceChip(
                    label: Text(entry.key),
                    selected: _selected == entry.key,
                    onSelected: _running
                        ? null
                        : (_) => setState(() => _selected = entry.key),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow),
                label: Text(_running ? '执行中…' : '运行'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0E11),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: _lines.isEmpty
                  ? const Center(
                      child: Text(
                        '选择命令并点「运行」\n\n'
                        'Step 1 验证标准：hello → 输出 "hello"',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, height: 1.8),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: _lines.length,
                      itemBuilder: (_, i) => SelectableText(
                        _lines[i],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
