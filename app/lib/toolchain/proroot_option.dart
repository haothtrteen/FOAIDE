import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../core/theme.dart';
import '../mcp/proroot_download.dart';
import 'sdk_downloader.dart';

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

  // ---------------- Bug 464 · 一键从 GitHub 拉取 ----------------
  //
  // 设计取舍（为什么这么实现）：
  //
  // ① **不用 GitHub API**。`api.github.com` 有匿名速率限制（每小时 60 次，
  //    按 IP 计），手机网络常是共享出口 IP，随时可能 403。改用
  //    `raw.githubusercontent.com` 直取文件——raw 域不计数、不返回元数据，
  //    够用且稳。
  //
  // ② **固定文件清单 + 逐个校验**。5 个文件的名字/大小/SHA 都写死在
  //    [soAssets] 里，不动态发现。理由：proroot 是**专有许可、源码未公开**，
  //    动态发现意味着"上游推什么就装什么"，无法审计变化。钉死版本后，
  //    上游一旦改动，校验会失败并明确报错，而不是静默装上不同内容。
  //
  // ③ **sha256 校验而非只看大小**。子集下载/半截响应都可能凑出相同大小。
  //    这里用 sha256 钉死内容（值是 2026-09-20 实测、并与 GitHub 侧
  //    git blob sha1 交叉验证一致的）。
  //
  // ④ **不修改二进制**。许可原文："Redistribution of modified binaries is
  //    not permitted." —— 我们只做**按字节原样下载**，不做 strip/重打包。
  //    下载后落位到应用私有目录，不经任何改写。

  /// 上游默认分支（raw 下载路径需要）。
  static const String upstreamRef = 'main';

  /// 5 个 .so 的下载清单：文件名 / 字节数 / sha256。
  ///
  /// sha256 为 2026-09-20 实测值，并与 GitHub contents API 返回的
  /// git blob sha1 交叉验证一致（blob sha1 见 gitAssetSha1 注释）。
  static const List<({String name, int size, String sha256})> soAssets = [
    (
      name: 'libproroot.so',
      size: 43624,
      sha256:
          'a4e74d75b66cdc02b080adfe863dbf9951c3b30610d77beddc95488d5fe5de01',
    ),
    (
      name: 'libproroot-runtime.so',
      size: 375120,
      sha256:
          '8c47a0a7db32d84c179ebb5bf3640f655a3181860ece5886ae44d92858730c34',
    ),
    (
      name: 'libproroot-linker.so',
      size: 79408,
      sha256:
          '51a0ec5bfed00e572a0de09e22d9057e2befc386b78e426613d3e0ab03f4ecee',
    ),
    (
      name: 'libproroot-bridge.so',
      size: 23624,
      sha256:
          '1c5bc9537a270e8bf8b1c70222813f57b60b828bfb5503ddf8fe37685092de2f',
    ),
    (
      name: 'libproroot-stub-loader.so',
      size: 144144,
      sha256:
          '06c6624db3bdc45b9ced151cd781df439a37b47731d244b93e9d6a58cd48cde0',
    ),
  ];

  /// 单个资产的原始下载地址（不依赖 API）。
  static String rawUrl(String fileName) =>
      'https://raw.githubusercontent.com/coderredlab/proroot/'
      '$upstreamRef/arm64-v8a/$fileName';

  /// 下载源（国内镜像优先，raw 直链兜底）。
  ///
  /// 与 cloudflared 同款思路：ghfast / gh-proxy 都能代理 raw.githubusercontent，
  /// 国内可达性远好于直连（直连常被 DNS 污染或 TLS 中断）。
  static List<MirrorSource> mirrorsFor(String fileName) => [
        MirrorSource('ghfast',
            'https://ghfast.top/https://raw.githubusercontent.com/'
            'coderredlab/proroot/$upstreamRef/arm64-v8a/$fileName'),
        MirrorSource('gh-proxy.com',
            'https://gh-proxy.com/https://raw.githubusercontent.com/'
            'coderredlab/proroot/$upstreamRef/arm64-v8a/$fileName'),
        MirrorSource('github-raw', rawUrl(fileName)),
      ];

  /// 全部资产合计字节数（UI 显示"约 0.7MB"用）。
  static int get totalBytes =>
      soAssets.fold(0, (a, e) => a + e.size);


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

  /// Bug 464：一键从 GitHub 拉取 5 个 .so → 自动落位 → 刷新状态。
  ///
  /// 与 [_import]（系统文件选择器）并存：选择器对"已自己下好文件"的用户
  /// 更灵活，一键下载对"什么都没准备"的用户更省事。两条路最终都汇到
  /// 原生的 `prorootInstall` 落位逻辑，行为一致。
  Future<void> _download() async {
    final env = await _bridge.envInfo();
    setState(() {
      _busy = true;
      _note = '正在下载 ${ProrootOption.soAssets.length} 个文件…';
      _noteOk = true;
    });
    final logs = <String>[];
    try {
      final dl = ProrootDownload(_bridge);
      final stagingDir = await dl.fetchAll(
        env: env,
        onLog: (l) {
          logs.add(l);
          if (mounted) setState(() => _note = l);
        },
      );
      // 落位（复用原生的递归拷贝 + ELF 校验）
      setState(() => _note = '落位中…');
      final r = await _bridge.prorootInstallFromDir(stagingDir);
      if (!mounted) return;
      if (r.ok) {
        // 成功才清暂存；失败保留，便于用户/我们排查
        await dl.clearStaging(env);
      }
      setState(() {
        _busy = false;
        _noteOk = r.ok;
        _note = r.ok
            ? '已下载并导入 ${r.copied.length} 个文件，可以点「冒烟测试」验证'
            : (r.error ?? '落位未完成');
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _noteOk = false;
        _note = '一键下载失败：$e';
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
        ?.copyWith(color: FoaColors.of(context).muted, height: 1.45);
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
                        ? FoaTheme.seed.withValues(alpha: 0.15)
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
            // 四个动作：一键下载 / 导入 / 测试 / 移除
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Bug 464：一键从 GitHub 拉取（新用户的默认路径）
                FilledButton.icon(
                  onPressed: _busy ? null : _download,
                  icon: const Icon(Icons.cloud_download_outlined, size: 16),
                  label: Text(
                      installed
                          ? '重新下载'
                          : '一键下载（${(ProrootOption.totalBytes / 1024).toStringAsFixed(0)}KB）',
                      style: const TextStyle(fontSize: 12)),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.file_download_outlined, size: 16),
                  label: Text(installed ? '从本地导入' : '导入 proroot',
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
                      foregroundColor: FoaColors.of(context).danger,
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
                  color: FoaColors.of(context).codeBg,
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
                style: TextStyle(fontSize: 11, color: FoaColors.of(context).muted)),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: warn ? FoaColors.of(context).danger : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _banner(String text, bool ok) {
    // Bug 464：改用主题感知语义色（浅色主题下 warning 会压深，避免对比度不足）
    final fc = FoaColors.of(context);
    final c = ok ? fc.success : fc.warning;
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
    // Bug 464：原先用固定的 `orange.shade50/200/800/900`——那是一套**只适合
    // 浅色背景**的橙色阶。深色主题下 shade50 是近白底、shade900 是深褐字，
    // 这块警告框会亮得刺眼且对比度失衡。改用随主题走的语义色。
    final c = FoaColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.warningContainer,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _plain(text),
              style: TextStyle(
                  fontSize: 11.5, height: 1.45, color: c.warning),
            ),
          ),
        ],
      ),
    );
  }
}
