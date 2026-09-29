import 'dart:io';

import '../env/models.dart';
import '../toolchain/proroot_option.dart';
import '../toolchain/sdk_downloader.dart';

/// proroot 一键下载（Bug 464）。
///
/// ## 为什么不复用 cloudflared 的安装器
///
/// cloudflared 是**单个文件**，下载完 chmod 就能用；proroot 是**5 个 .so
/// 必须同目录**（启动器按 `/proc/self/exe` 的 dirname 自动找同级的另外 4 个）。
/// 所以流程不同：先下载 5 个到暂存目录 → 整体落位 → 冒烟测试。
///
/// ## 暂存目录选在哪
///
/// 必须在 **rootfs 内**（宿主路径 `${rootfsPath}/opt/proroot-dl`）：
/// ① 与最终落位目录同物理卷，拷贝是廉价的 rename 量级；
/// ② 宿主 `filesDir` 下的文件没有可执行位，而 rootfs 内可由容器 chmod。
///
/// ## 校验策略
///
/// 逐个文件比对 **字节数 + sha256**（[ProrootOption.soAssets] 里钉死）。
/// 任一项不符即整体失败并**保留已下载文件**供排查——不静默重试，
/// 因为内容不符往往意味着上游改了东西或镜像被篡改，属于要人看一眼的情况。
///
/// ## 许可边界
///
/// proroot 许可是 "Proprietary. Free to use in your projects. Redistribution
/// of modified binaries is not permitted." —— 我们是**运行时按字节原样下载
/// 到用户设备**，不改写、不重打包、不随 APK 分发，符合"free to use"。
class ProrootDownload {
  ProrootDownload(this.bridge);

  final dynamic bridge; // ProotBridge（避免循环依赖，用 dynamic 接）

  /// 暂存目录名（rootfs 内）。
  static const String stagingRelDir = 'opt/proroot-dl';

  /// 下载全部 5 个 .so 到暂存目录，逐个校验。
  ///
  /// 返回暂存目录的**宿主路径**（交给 `prorootInstallFromDir` 落位），
  /// 失败抛 [DownloadException] 并带上具体是哪个文件、什么原因。
  Future<String> fetchAll({
    required EnvInfo env,
    void Function(String)? onLog,
  }) async {
    // Bug 471（**已修正**）：**先做组合级兼容性判定**，再决定要不要花流量下载。
    //
    // 逐文件 sha256 只能证明"字节没被改动"，证明不了"这些字节合在一起
    // 能跑"。这一点当初判断对了，但**判据选错了**：
    //
    //  · 一开始只查 glibc 符号依赖 → 拦住了 v1.2.8（需 2.38，报
    //    `reloc: unresolved`），但**放过了 v1.2.5**（只需 2.34，
    //    纸面满足）—— 真机实测 v1.2.5 同样崩：`no offset table for
    //    glibc 2.36` → SIGSEGV → code 139。
    //
    //  · 教训：**符号依赖满足 ≠ 能跑**。linker 还需要为目标 glibc
    //    准备内部结构体偏移表，这个信息完全不在 ELF 符号表里，
    //    `readelf -V` 看不到，只能靠真机跑。
    //
    // 所以现在改成查 [isKnownUnusable]（真机实测结论），而不是
    // 查"版本号算得过来"。宁可多劝退，也不要让用户走完
    // "预检通过 → 下载 → 冒烟 → 崩溃 → 白折腾"这一整轮。
    if (ProrootOption.isKnownUnusable()) {
      final msg = ProrootOption.knownUnusableMessage();
      onLog?.call('[预检] 该组合已被真机证实不可用，跳过下载');
      throw DownloadException(msg);
    }
    if (!ProrootOption.isGlibcCompatible()) {
      final msg = ProrootOption.glibcMismatchMessage();
      onLog?.call('[预检] 不兼容，跳过下载');
      throw DownloadException(msg);
    }

    final staging = '${env.rootfsPath}/$stagingRelDir';
    final dir = Directory(staging);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final total = ProrootOption.soAssets.length;
    for (var i = 0; i < total; i++) {
      final a = ProrootOption.soAssets[i];
      final dst = '$staging/${a.name}';
      final tag = '[${i + 1}/$total]';

      // 幂等快路径：已下载且校验通过 → 跳过（重试时不重复下载）
      if (await _verify(dst, a.size, a.sha256)) {
        onLog?.call('$tag ${a.name} 已就绪，跳过');
        continue;
      }

      onLog?.call('$tag 下载 ${a.name}（${_kb(a.size)}）…');
      try {
        final fastest = await SdkDownloader.pickFastest(
          ProrootOption.mirrorsFor(a.name),
        );
        await SdkDownloader.downloadMultiSource(
          fastest,
          dst,
          a.size,
          onMirrorUsed: (m) => onLog?.call('$tag 使用镜像：${m.name}'),
        );
      } catch (e) {
        throw DownloadException('${a.name} 下载失败：$e\n可稍后重试（已下载的文件会保留，重试只补缺的）。');
      }

      if (!await _verify(dst, a.size, a.sha256)) {
        final got = File(dst).existsSync() ? File(dst).lengthSync() : -1;
        throw DownloadException(
            '${a.name} 校验失败：期望 ${a.size}B / ${a.sha256.substring(0, 12)}…，'
            '实际 ${got}B。\n'
            '可能原因：上游已发新版（本 App 曾钉死特定版本的文件）、'
            '或镜像返回了错误内容。已保留文件供排查，不会静默装上。');
      }
      onLog?.call('$tag ${a.name} ✓');
    }

    onLog?.call('全部 $total 个文件校验通过');
    return staging;
  }

  /// 校验：文件存在 + 字节数相符 + sha256 相符。
  static Future<bool> _verify(String path, int size, String sha256) async {
    final f = File(path);
    if (!f.existsSync()) return false;
    if (f.lengthSync() != size) return false;
    return SdkDownloader.verifySha256(path, sha256);
  }

  /// 清理暂存目录（落位成功后调用；失败时**保留**供排查）。
  Future<void> clearStaging(EnvInfo env) async {
    final dir = Directory('${env.rootfsPath}/$stagingRelDir');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  static String _kb(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)}KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}
