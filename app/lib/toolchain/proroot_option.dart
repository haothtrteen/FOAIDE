import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';

/// 容器层加速选项：**proroot**（alpha.61 起可真正启用）。
///
/// ## 这个选项到底是什么
///
/// proot 用 **ptrace** 拦截每一次系统调用做路径翻译，代价是**两次上下文
/// 切换**（进程↔tracer）。proroot 换成 **LD_PRELOAD + 二进制补丁**，
/// 在进程内完成翻译，零上下文切换。
///
/// ## 它**不**改善什么（必须说清，否则用户会以为是提速银弹）
///
/// FOA 构建耗时的大头是 **QEMU 指令翻译**（gen_snapshot / gradle /
/// aapt2 全是 x64 二进制，逐条指令翻译）以及 dart/gradle 自身的计算。
/// **proroot 对这两项没有任何改善**。有感的是 I/O 密集型操作
/// （apt 装包、tar 解压、海量小文件读写）。
///
/// ## 为什么默认关闭
///
/// 1. **专有许可**：可用于你的项目，但禁止分发修改过的二进制；
/// 2. **源码未公开**：无法自行审计；
/// 3. **环境不匹配**：官方要求 Ubuntu arm64（glibc），本项目用
///    Debian 12 bookworm——属**未验证组合**。
///
/// 所以流程设计成"用户自己要开 → 自己导入二进制 → 先冒烟测试再启用"，
/// 而不是给个开关默认打开，出事再让用户猜。
class ProrootOption {
  const ProrootOption._();

  /// 上游仓库（许可与二进制均在此）。
  static const String repoUrl = 'https://github.com/coderredlab/proroot';

  /// 许可**原文**（上游 LICENSE / README 的 License 节逐字照抄）。
  ///
  /// 照抄原文而非概括：这是"能不能用"的唯一依据，转述会失真。
  static const String licenseText =
      'Proprietary. Free to use in your projects. '
      'Redistribution of modified binaries is not permitted.';

  /// 官方要求的最低 Android API（26 = Android 8.0）。
  static const int minAndroidApi = 26;

  /// 仅提供该 ABI 的二进制。
  static const String abi = 'arm64-v8a';

  /// 需要一并落位的 5 个 .so（少了任何一个都无法启动）。
  static const List<String> soFiles = <String>[
    'libproroot.so',
    'libproroot-runtime.so',
    'libproroot-linker.so',
    'libproroot-bridge.so',
    'libproroot-stub-loader.so',
  ];

  /// 官方声明支持的 rootfs 发行版。
  static const String requiredRootfs = 'Ubuntu arm64';

  /// 本项目实际使用的 rootfs 发行版（决定兼容性提示的措辞）。
  static const String foaRootfsDistro = 'Debian 12 bookworm';

  /// proroot 的启动器形态（与现有 proot 的 argv **不一致**）。
  ///
  /// 现有：`proot -0 -r <rootfs> -b /dev -b /proc -b /sys --link2symlink -w /root ...`
  /// proroot：`libproroot.so -r <rootfs> -0 --link2symlink -w /root ...`
  /// → 顺序与取值都不同，原生侧 [buildProrootCmd] 是独立实现。
  static const String launcherUsage =
      'libproroot.so -r <rootfs> -0 --link2symlink -w /root /bin/sh -c \'…\'';

  /// 二进制下载地址（用户自己去上游取——许可禁止我们代为分发）。
  static const String downloadHint =
      '到上方仓库的 Release / 源码树里取 $abi 构建的 5 个 .so，'
      '解压成一个目录后用下面的「导入」按钮选那个目录。';

  /// 兼容性说明（[rootfsDistro] 为本项目的 rootfs 发行版）。
  ///
  /// 抽成纯函数便于单测：这条提示是"别盲目期待"的关键，不能写丢。
  static String compatNote({required String rootfsDistro}) {
    final d = rootfsDistro.trim();
    if (d.isEmpty) return '未知 rootfs 发行版，无法判断兼容性。';
    final same = d.toLowerCase().contains('ubuntu');
    return same
        ? 'rootfs 为 $d，符合官方要求的 $requiredRootfs。'
        : '当前 rootfs 是 **$d**，而 proroot 官方要求 $requiredRootfs'
            '（glibc）——**属未验证组合**，可能直接起不来。'
            '开启前务必先跑一次冒烟测试。';
  }

  /// 收益边界说明（必须写在卡片上，避免用户误以为它是提速银弹）。
  static String gainNote() => 'proroot 优化的是**容器层**：用 LD_PRELOAD + '
      '二进制补丁替代 ptrace，省掉每次系统调用的两次上下文切换。'
      '但 FOA 构建慢的大头是 **QEMU 指令翻译**（gen_snapshot / gradle / '
      'aapt2 都是 x64 二进制）与 dart/gradle 自身的计算——'
      '**这两项 proroot 一点都不改善**。有感的是 I/O 密集型操作'
      '（apt 装包、tar 解压、海量小文件读写）；不要指望构建时间'
      '从 10 分钟变成 2 分钟。';

  /// 风险清单（卡片逐条渲染）。
  static const List<String> risks = <String>[
    '专有许可（Proprietary）：可用于你的项目，但**禁止分发修改过的二进制**。',
    '**源码未公开**——无法自行审计，也无法自行修补，出问题只能等上游。',
    '作者已将重心转向 proroom，本仓库的更新预期会变慢。',
    '只提供 $abi 二进制（5 个 .so），要求 Android 8.0+（API $minAndroidApi）。',
    '启动器 argv 与 proot 不一致，原生侧是独立实现路径——'
        '所以需要**冒烟测试**验证，不能假定它能用。',
  ];
}

/// 「容器层加速（proroot）」卡片（alpha.61：从纯告知卡变成可用功能）。
///
/// 交互设计：**先装才能开**。没导入二进制时开关是禁用的，但按钮可点
/// （引导导入）；导入后可以点"冒烟测试"真跑一次；测试通过才允许打开。
/// 这个顺序不是仪式感——proroot 与 Debian rootfs 的组合没验证过，
/// 直接打开开关去构建，失败了用户只会看到一堆 gradle 报错，
/// 根本定位不到是容器层的问题。
class ProrootCard extends StatefulWidget {
  const ProrootCard({
    super.key,
    this.rootfsDistro = ProrootOption.foaRootfsDistro,
    this.enabled = false,
    this.onChanged,
  });

  /// 当前 rootfs 发行版（用于兼容性提示）。
  final String rootfsDistro;

  /// 当前是否已启用 proroot。
  final bool enabled;

  /// 开关回调（父页负责写 ContainerPrefs）。
  final ValueChanged<bool>? onChanged;

  @override
  State<ProrootCard> createState() => _ProrootCardState();
}

class _ProrootCardState extends State<ProrootCard> {
  final ProotBridge _bridge = ProotBridge();

  ProrootStatus? _status;
  bool _busy = false;
  String _note = '';
  bool _noteOk = false;
  ProrootProbeResult? _probeResult;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final s = await _bridge.prorootStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '无法查询 proroot 状态：$e';
        _noteOk = false;
      });
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _note = '';
    });
    try {
      final r = await _bridge.prorootImport();
      if (!mounted) return;
      if (r == null) {
        setState(() {
          _busy = false;
          _note = '已取消导入';
          _noteOk = false;
        });
        return;
      }
      setState(() {
        _busy = false;
        _noteOk = r.ok;
        _note = r.ok
            ? '已导入 ${r.copied.length} 个文件，可以点「冒烟测试」验证'
            : (r.error ?? '导入未完成');
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '导入失败：$e';
        _noteOk = false;
      });
    }
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _probeResult = null;
      _note = '';
    });
    try {
      final r = await _bridge.prorootProbe();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _probeResult = r;
        _noteOk = r.ok;
        _note = r.ok
            ? '冒烟测试通过：proroot 可以在这个 rootfs 上工作'
            : (r.error ?? '冒烟测试未通过');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '冒烟测试失败：$e';
        _noteOk = false;
      });
    }
  }

  Future<void> _remove() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除 proroot 二进制？'),
        content: const Text(
          '会删除已导入的 5 个 .so。如果开关还开着，请先关掉。\n\n'
          '文件可以随时重新导入，不会有不可逆的损失。',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (go != true) return;
    setState(() => _busy = true);
    try {
      final n = await _bridge.prorootRemove();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _probeResult = null;
        _note = '已移除 $n 个文件';
        _noteOk = true;
      });
      // 二进制没了就不能继续开着，否则下次构建会在启动阶段报错
      if (widget.enabled) widget.onChanged?.call(false);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '移除失败：$e';
        _noteOk = false;
      });
    }
  }

  void _toggle(bool v) {
    if (v) {
      // 开启前先确认二进制齐了；冒烟测试没跑过的话提醒一句，
      // 但不强制——用户可能就是想在真构建里试。
      final s = _status;
      if (s == null || !s.installed) {
        setState(() {
          _note = '还没导入 proroot 二进制，先点上面的「导入」';
          _noteOk = false;
        });
        return;
      }
      if (!s.abiOk) {
        setState(() {
          _note = '设备 ABI 是 ${s.abi}，proroot 只提供 arm64-v8a';
          _noteOk = false;
        });
        return;
      }
      if (_probeResult?.ok != true) {
        setState(() {
          _note = '建议先跑一次「冒烟测试」。没测过也能开，'
              '但构建失败时无法区分是容器层还是项目本身的问题。';
          _noteOk = false;
        });
      }
    }
    widget.onChanged?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Colors.grey.shade500, height: 1.45);
    final s = _status;
    final installed = s?.installed ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune_outlined, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '容器层加速（proroot）',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Chip(
                    label: Text(installed ? '已导入' : '未导入',
                        style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: installed
                        ? const Color(0xFF3DDC84).withValues(alpha: 0.15)
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // 开关：装好才可开
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用 proroot 替代 proot',
                  style: TextStyle(fontSize: 13)),
              subtitle: Text(
                !installed
                    ? '需要先导入 ${ProrootOption.soFiles.length} 个 .so 文件'
                    : (s?.abiOk == false
                        ? '当前设备 ABI（${s?.abi}）不支持'
                        : '构建与终端命令将走 proroot'),
                style: const TextStyle(fontSize: 11),
              ),
              value: widget.enabled,
              onChanged: (installed && (s?.abiOk ?? true)) ? _toggle : null,
            ),

            // 状态明细：缺什么、哪个不是 ELF，都要说清
            if (s != null) ...[
              _statusRow('落位目录', s.dir.isEmpty ? '—' : s.dir),
              _statusRow('已就位', '${s.present.length}/${ProrootOption.soFiles.length}'),
              if (s.missing.isNotEmpty)
                _statusRow('缺少', s.missing.join('、'), warn: true),
              if (s.notElf.isNotEmpty)
                _statusRow('非 ELF（可能损坏）', s.notElf.join('、'), warn: true),
              _statusRow('设备', '${s.abi} · API ${s.api}'
                  '${s.apiOk ? '' : '（需 ${ProrootOption.minAndroidApi}+）'}'),
            ],

            const SizedBox(height: 10),
            // 三个动作：导入 / 测试 / 移除
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.file_download_outlined, size: 16),
                  label: Text(installed ? '重新导入' : '导入 proroot',
                      style: const TextStyle(fontSize: 12)),
                ),
                OutlinedButton.icon(
                  onPressed: (_busy || !installed) ? null : _probe,
                  icon: const Icon(Icons.science_outlined, size: 16),
                  label: const Text('冒烟测试', style: TextStyle(fontSize: 12)),
                ),
                if (installed)
                  TextButton.icon(
                    onPressed: _busy ? null : _remove,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('移除', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFFF7A7A),
                    ),
                  ),
              ],
            ),

            if (_note.isNotEmpty) ...[
              const SizedBox(height: 8),
              _banner(_note, _noteOk),
            ],
            if (_probeResult != null && !_probeResult!.ok && _probeResult!.output.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  _probeResult!.output.trim(),
                  style: const TextStyle(
                      fontSize: 10.5, fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ],

            const SizedBox(height: 10),
            Text(ProrootOption.gainNote(), style: muted),
            const SizedBox(height: 8),
            _warn(ProrootOption.compatNote(rootfsDistro: widget.rootfsDistro)),
            const SizedBox(height: 8),
            Text(ProrootOption.downloadHint, style: muted),
            const SizedBox(height: 10),
            const Text('风险与限制',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final r in ProrootOption.risks) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('· ', style: TextStyle(fontSize: 12)),
                    Expanded(child: Text(_plain(r), style: muted)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text('许可（上游原文）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const SelectableText(
                ProrootOption.licenseText,
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              '仓库：${ProrootOption.repoUrl}\n'
              '形态：${ProrootOption.soFiles.length} 个 ${ProrootOption.abi} '
              '.so，Android ${ProrootOption.minAndroidApi}+ \n'
              '启动器：${ProrootOption.launcherUsage}',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(String k, String v, {bool warn = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(k,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: warn ? const Color(0xFFFF7A7A) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _banner(String text, bool ok) {
    final c = ok ? const Color(0xFF3DDC84) : const Color(0xFFFFB74D);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.info_outline,
              size: 15, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, height: 1.45, color: c),
            ),
          ),
        ],
      ),
    );
  }

  /// 去掉 Markdown 星号（风险条目里的加粗是给正文用的，卡片里用样式表达）。
  static String _plain(String s) => s.replaceAll('**', '');

  Widget _warn(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 16, color: Colors.orange.shade800),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _plain(text),
              style: TextStyle(
                  fontSize: 11.5,
                  height: 1.45,
                  color: Colors.orange.shade900),
            ),
          ),
        ],
      ),
    );
  }
}
