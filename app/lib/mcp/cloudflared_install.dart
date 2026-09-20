import 'dart:io';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../toolchain/sdk_downloader.dart';

/// cloudflared 安装器（alpha.60）。
///
/// ## 为什么必须是 arm64 版
///
/// FOA 的 rootfs 是 **aarch64**（`debian-minbase-arm64.tar.gz`），
/// 容器内的进程是 arm64 原生的。若用 amd64 版 cloudflared，它必须经
/// QEMU 转发层执行——一个**长驻网络进程**挂在 QEMU 翻译层上，既慢又脆
/// （链路抖动/被平台回收的概率都更高）。
/// 因此这里固定下载 `cloudflared-linux-arm64`。
///
/// ## 为什么落在容器内（而不是 filesDir）
///
/// App 通过 Dart 写出的文件**没有可执行位**，而 Android 宿主侧没有
/// `chmod` 可用（这是 termux_backend 已验证的同款技巧）。落在 rootfs 里
/// 就能用容器内的 `chmod 755` 修好——且容器路径与宿主路径是**同一物理
/// 目录**（`${rootfsPath}/opt/...` ↔ 容器内 `/opt/...`）。
///
/// ## 许可
///
/// cloudflared 是 **Apache-2.0**，且本方案是**运行时下载、不随 APK 分发**，
/// 合规负担极小；仍在 THIRD-PARTY-NOTICES 中声明。
class CloudflaredInstall {
  CloudflaredInstall(this.bridge);

  final ProotBridge bridge;

  /// 容器内路径。
  static const String binPath = '/opt/foa-bin/cloudflared';
  static const String dirPath = '/opt/foa-bin';

  /// 固定版本（避免 latest 漂移导致行为不可复现）。
  /// 升级时同步更新 [expectedSize] 与 [sha256]（若启用校验）。
  static const String version = '2026.9.1';

  /// 资产名——**契约：必须是 arm64**（单测断言，防有人改回 amd64）。
  static const String assetName = 'cloudflared-linux-arm64';

  /// 期望字节数（GitHub Releases 元数据；用于分片下载）。
  static const int expectedSize = 37466252;

  /// 期望 SHA-256（Bug 464 新增）。
  ///
  /// 在此之前 cloudflared **没有内容校验**——只比字节数。字节数对但内容坏
  /// （镜像返回错误页、被中间层注入、CDN 缓存了半截文件）时，下载会"成功"，
  /// 直到容器里 `--version` 跑不起来才报错，且报的是"架构不匹配"这种误导
  /// 信息。加上 sha256 后，坏内容在下载阶段就被拦下。
  ///
  /// 值取自 2026-09-20 实测（ghfast.top 与 ghproxy.net 两个镜像下载后
  /// `sha256sum` 结果一致，交叉验证过）。
  static const String sha256 =
      '3d97437c71848bd8df68041e12436b484a661d95073ea1937f01a845ce88faa3';

  /// 下载源（国内镜像优先，GitHub 直链兜底）。
  ///
  /// Bug 456 教训：这里原本只有 2 个源，而 `SdkDownloader` 当时要求分片必须
  /// 回 206——一旦唯一可用的镜像回 200，整条链就断了。现在下载器已支持
  /// 「Range 不可用 → 整包兜底」，但**源的数量仍应留冗余**：国内网络对
  /// GitHub 系域名的连通性波动很大，多一个镜像就多一条活路。
  ///
  /// 本列表的每个源都在 2026-09-20 实测过 Range 可达性（206 + 正确字节数）：
  /// ghfast / ghproxy.net / gh-proxy.com 均通，GitHub 直链作为兜底保留。
  /// 曾尝试加入 `github.moeyy.xyz`，实测 DNS 无法解析，**故不纳入**——
  /// 宁可少一个源，也不要摆一个永远超时、白白拖慢竞速的假选项。
  ///
  /// Bug 464：源从 3 个扩到 4 个。用户反复报"下载不了"，而本地实测三个源
  /// 全通——说明失败是**特定网络下的可达性问题**。这类问题无法靠"换个源"
  /// 根治，只能：(a) 多留几条路，(b) 把每个源的具体失败原因暴露给用户
  /// （见 [diagnose]），让用户能判断是 DNS 还是超时。
  static const List<MirrorSource> mirrors = [
    MirrorSource('ghfast', 'https://ghfast.top/https://github.com/'
        'cloudflare/cloudflared/releases/download/$version/$assetName'),
    MirrorSource('ghproxy.net', 'https://ghproxy.net/https://github.com/'
        'cloudflare/cloudflared/releases/download/$version/$assetName'),
    MirrorSource('gh-proxy.com', 'https://gh-proxy.com/https://github.com/'
        'cloudflare/cloudflared/releases/download/$version/$assetName'),
    MirrorSource('github', 'https://github.com/cloudflare/cloudflared/'
        'releases/download/$version/$assetName'),
  ];

  /// Bug 464：逐镜像探测并汇报**具体失败原因**（供 UI「下载诊断」用）。
  ///
  /// 存在的理由：cloudflared 下载失败的用户反馈无法定位——三源在开发机上
  /// 全通，说明是用户网络的点对点问题。不给原因，用户只能反复重试。
  /// 返回可直接展示的多行文本。
  static Future<String> diagnose() async {
    try {
      final probes = await SdkDownloader.diagnose(mirrors);
      final okCount = probes.where((p) => p.ok).length;
      final head = okCount > 0
          ? '✓ $okCount/${probes.length} 个镜像可达'
          : '✗ 所有镜像都不可达（网络问题，非本 App 故障）';
      return '$head\n${probes.map((p) => '· ${p.summary}').join('\n')}';
    } catch (e) {
      return '诊断本身失败：$e';
    }
  }

  /// 确保 cloudflared 可用（幂等）。
  /// 返回 null = 就绪；否则错误文案。
  Future<String?> ensure({
    required EnvInfo env,
    void Function(String)? onLog,
  }) async {
    // ① 已装且能跑 → 直接复用（幂等快路径，`--version` 是真验证而非只看文件在）
    final probe = await bridge.exec('$binPath --version 2>&1', timeoutSec: 30);
    if (probe.exitCode == 0 && probe.stdout.contains('cloudflared')) {
      onLog?.call('✓ cloudflared 已就绪：${probe.stdout.trim()}');
      return null;
    }

    // ② 下载到宿主可见路径（rootfs 内 → 容器内也在同一位置）
    final savePath = '${env.rootfsPath}/opt/foa-bin/cloudflared.dl';
    onLog?.call('· 下载 $assetName（约 ${(expectedSize / 1024 / 1024).toStringAsFixed(0)}MB）…');
    try {
      final fastest = await SdkDownloader.pickFastest(mirrors);
      await SdkDownloader.downloadMultiSource(
        fastest,
        savePath,
        expectedSize,
        onProgress: (p) {
          if (p.total > 0 && p.received % (4 * 1024 * 1024) < 65536) {
            final pct = (p.received * 100 / p.total).toStringAsFixed(0);
            onLog?.call('· 下载中 $pct%（${(p.received / 1024 / 1024).toStringAsFixed(1)}MB）');
          }
        },
        onMirrorUsed: (m) => onLog?.call('· 使用镜像源：${m.name}'),
      );
    } catch (e) {
      // Bug 464：失败文案带上**逐源诊断**，让用户能区分"网络不通"与
      // "程序 bug"。原文案（"下载失败：… 国内网络可稍后重试"）等于没说。
      final diag = await diagnose();
      return 'cloudflared 下载失败：$e\n\n各镜像探测结果：\n$diag\n\n'
          '若全部不可达：多为网络问题（DNS/防火墙），可换网络后重试；'
          '或手动下载后放入容器 /opt/foa-bin/。';
    }

    // ②.5 SHA-256 校验（Bug 464 新增）
    // 必须在落位**之前**：字节数相同但内容损坏（镜像错误页、半截缓存）
    // 到了容器里才炸，报的还是"架构不匹配"这种误导信息。
    try {
      final ok = await SdkDownloader.verifySha256(savePath, sha256);
      if (!ok) {
        return 'cloudflared 校验失败（内容与官方不一致，可能镜像损坏或被篡改）：\n'
            '期望 $sha256\n路径 $savePath\n'
            '已保留可疑文件供排查；重试会重新下载。';
      }
    } catch (e) {
      return 'cloudflared 校验时出错：$e';
    }

    // ③ 落位 + 校验可执行（在容器内做——宿主侧没有 chmod）
    final setup = await bridge.exec(
      'mkdir -p $dirPath && '
      'mv -f $dirPath/cloudflared.dl $binPath && '
      'chmod 755 $binPath && '
      'test -x $binPath && echo __OK__ || echo __FAIL__',
      timeoutSec: 60,
    );
    if (!setup.stdout.contains('__OK__')) {
      return 'cloudflared 落位失败：${setup.stderr.trim().isEmpty ? setup.stdout.trim() : setup.stderr.trim()}';
    }

    // ④ 真实验证：能跑起来才算装好
    final verify = await bridge.exec('$binPath --version 2>&1', timeoutSec: 60);
    if (verify.exitCode != 0 || !verify.stdout.contains('cloudflared')) {
      return 'cloudflared 校验失败（下载不完整或架构不匹配）：'
          '${verify.stderr.trim().isEmpty ? verify.stdout.trim() : verify.stderr.trim()}';
    }
    onLog?.call('✓ cloudflared 安装完成：${verify.stdout.trim()}');
    return null;
  }

  /// 卸载（供 UI「清理」用；幂等）。
  Future<void> uninstall() async {
    await bridge.exec('rm -f $binPath; rmdir $dirPath 2>/dev/null; true',
        timeoutSec: 30);
  }

  /// 宿主侧文件是否存在（不做 exec，供 UI 快速判态）。
  static bool installedSync(EnvInfo env) =>
      File('${env.rootfsPath}/opt/foa-bin/cloudflared').existsSync();
}
