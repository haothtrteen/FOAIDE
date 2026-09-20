import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../env/proot_bridge.dart';
import 'qemu_compat.dart';

/// 故障诊断（alpha.59 引入，原名「远程排障」；alpha.60 更名）：
/// 一键跑诊断命令包 → 结果一键复制 → 粘贴给 AI。
///
/// 更名原因：真正的「远程」语义（远程 AI 接入执行）由 alpha.60 的
/// 「远程接管」页承担；本页只是**本机采集**信息交给 AI，叫「远程排障」
/// 名不副实，且两页同带 "remote" 会造成歧义。
///
/// 背景：真机上 AI 看不到设备（无法 ls/readelf/strace），排障只能靠
/// 用户截图猜。本页把 SKILL/手册排障表里的锚点查询固化成一键流程：
/// 用户点「一键执行」，跑完点「复制全部」，粘进与 AI 的对话即可获得
/// 针对性建议——把"远程指导"的第一手信息采集标准化。
///
/// 设计约束：
/// - 命令全部走 ProotBridge.exec（容器内，普通通道，毫秒~秒级），
///   **不与构建/预览抢锁**（无 flutter 命令，只剩只读探测）；
/// - 每项独立超时、失败不阻断后续（排障信息多多益善）；
/// - 输出清洗 ANSI 后按 section 拼接，复制即完整报告。
class DiagPage extends StatefulWidget {
  const DiagPage({super.key});

  @override
  State<DiagPage> createState() => _DiagPageState();
}

/// 诊断项定义。
class DiagItem {
  final String name;
  final String command;
  final int timeoutSec;
  final String hint;

  const DiagItem(this.name, this.command,
      {this.timeoutSec = 30, this.hint = ''});

  /// 命令占位符：表示该项需由调用方用 QemuCompat.fill 展开脚本。
  /// （声明为常量而非散落的字面量 'SH'，避免两处漂移。）
  static const String scriptPlaceholder = 'SH';

  /// 诊断命令包（顺序即报告顺序；全部只读，无副作用）。
  ///
  /// 公开静态方法（alpha.60）：远程接管页与 MCP 的 `foa_diag` 工具
  /// **复用同一份命令包**——AI 一次调用即可拿到与人工点「一键执行」
  /// 完全一致的报告，不必自己猜该查什么。
  static List<DiagItem> pack() => const [
        DiagItem(
          '系统架构 / 内核',
          'uname -m; uname -r',
          hint: '确认 arm64 宿主与内核版本（qemu 链路前提）',
        ),
        DiagItem(
          'Dart 版本（经转发层执行）',
          'dart --version 2>&1 || echo "dart 不可用（转发层/dart-sdk 异常）"',
          hint: 'dart 能跑 = REASSERT_DART 链路存活',
        ),
        DiagItem(
          'Flutter SDK 完整性',
          'ls /opt/flutter/bin/flutter >/dev/null 2>&1 && echo FLUTTER_OK '
              '|| echo FLUTTER_MISSING; '
              'ls /opt/flutter/bin/cache/dart-sdk/bin/dart >/dev/null 2>&1 '
              '&& echo DART_SDK_OK || echo DART_SDK_MISSING',
          hint: 'SDK 入口与 dart-sdk 就位检查',
        ),
        DiagItem(
          'x64 兼容层体检（转发层指纹）',
          scriptPlaceholder,
          timeoutSec: 180,
          hint: 'gen_snapshot/impellerc/font-subset 原位与对称位形态 + 冒烟',
        ),
        DiagItem(
          'JDK',
          'java -version 2>&1 | head -2 || echo "java 不可用"',
        ),
        DiagItem(
          '磁盘空间',
          'df -h 2>/dev/null | head -8 || echo "df 不可用"',
          hint: 'no space left 的第一现场',
        ),
        DiagItem(
          '内存',
          'free -m 2>/dev/null | head -3 || echo "free 不可用"',
          hint: 'gradle OOM / JVM 堆不足排查',
        ),
        DiagItem(
          '残留进程（dart/gradle/qemu）',
          'ps ax 2>/dev/null | grep -E "dart|gradle|qemu" | grep -v grep '
              '|| echo "（无残留或 ps 不可用）"',
          hint: '启动锁占用（Waiting for another flutter command）排查',
        ),
      ];
}

/// 报告标题（alpha.60 由「远程排障」更名而来）。
///
/// 抽成常量而非内联字面量：更名后 UI、报告、MCP `foa_diag` 三处共用，
/// 避免任一处遗漏导致用户拿到的报告仍写着旧名。
const String kDiagReportTitle = '## FOA 故障诊断报告';

/// 组装完整报告文本（**纯函数**，便于单测）。
///
/// [outputs] 中 null 表示该诊断项尚未执行，不进入报告。
String buildDiagReport(List<DiagItem> items, List<String?> outputs) {
  final buf = StringBuffer('$kDiagReportTitle\n');
  for (var i = 0; i < items.length; i++) {
    final out = outputs[i];
    if (out == null) continue;
    final cmd = items[i].command == DiagItem.scriptPlaceholder
        ? '<x64 兼容层体检脚本>'
        : items[i].command;
    buf
      ..writeln('\n### ${items[i].name}')
      ..writeln('\$\$ $cmd')
      ..writeln(out);
  }
  return buf.toString();
}

class _DiagPageState extends State<DiagPage> {
  final ProotBridge _bridge = ProotBridge();

  bool _running = false;
  int _current = -1; // 正在执行的下标（进度指示）

  /// 每项的输出（null = 未执行；空串 = 无输出）。
  final List<String?> _outputs = List<String?>.filled(_items.length, null);
  final List<bool> _failed = List<bool>.filled(_items.length, false);

  /// 诊断命令包（与 [DiagItem.pack] 同源）。
  static final List<DiagItem> _items = DiagItem.pack();

  /// 跑一遍全部诊断项（串行；单项失败不阻断）。
  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      for (var i = 0; i < _outputs.length; i++) {
        _outputs[i] = null;
        _failed[i] = false;
      }
    });
    for (var i = 0; i < _items.length; i++) {
      if (!mounted) return;
      setState(() => _current = i);
      final item = _items[i];
      final cmd = item.command == DiagItem.scriptPlaceholder
          ? QemuCompat.fill(QemuCompat.verifyScript)
          : item.command;
      String out;
      var fail = false;
      try {
        final r = await _bridge.exec(cmd, timeoutSec: item.timeoutSec);
        out = (r.stdout.trim().isNotEmpty ? r.stdout : r.stderr).trim();
        if (r.exitCode != 0) {
          fail = true;
          out = '$out\n[exit ${r.exitCode}]';
        }
      } catch (e) {
        fail = true;
        out = '执行异常：$e';
      }
      if (!mounted) return;
      setState(() {
        _outputs[i] = out.isEmpty ? '（无输出）' : out;
        _failed[i] = fail;
      });
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _current = -1;
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('诊断完成：点「复制全部」后粘贴给 AI 分析'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// 组装完整报告文本（复制给 AI 的形态：带命令与输出的分节报告）。
  String _report() => buildDiagReport(_items, _outputs);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('已复制完整报告，粘贴给 AI 即可'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final anyDone = _outputs.any((o) => o != null);
    return Scaffold(
      appBar: AppBar(title: const Text('故障诊断')),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('一键采集设备诊断信息',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    '跑完点「复制全部」，粘贴到与 AI 的对话里，'
                    '即可获得针对性修复建议（替代截图猜谜）。\n'
                    '全部为只读探测命令，不影响构建/预览。',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _items.length,
              itemBuilder: (ctx, i) => _tile(i),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _running ? null : _run,
                  icon: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow),
                  label: Text(_running
                      ? '执行中 ${_current + 1}/${_items.length}…'
                      : '一键执行'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: anyDone && !_running ? _copy : null,
                  icon: const Icon(Icons.copy_all),
                  label: const Text('复制全部'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(int i) {
    final item = _items[i];
    final out = _outputs[i];
    final running = _running && _current == i;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (running)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (out == null)
                  Icon(Icons.circle_outlined,
                      size: 16, color: Colors.grey.shade500)
                else
                  Icon(
                    _failed[i] ? Icons.error_outline : Icons.check_circle,
                    size: 16,
                    color: _failed[i]
                        ? const Color(0xFFCF6679)
                        : const Color(0xFF3DDC84),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(item.name,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            if (item.hint.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(item.hint,
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade500)),
            ],
            if (out != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF101418),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  out,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.4,
                    color: Color(0xFFCAD3D5),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
