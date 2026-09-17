import 'dart:io';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'sdk_downloader.dart';

/// JDK 17（Temurin，linux-aarch64）安装编排。
///
/// 版本固定 17.0.20.1+1（2026-09-17 探测的 TUNA/官方最新 LTS）：
/// - 镜像分两级：**国内优先**（TUNA 清华 + 南大 NJU，2026-09-17 curl 实测
///   支持 Range 且收录该版本），全部不可达才退境外兜底（GitHub + Adoptium
///   API）；探测并发竞速，取最快者下载；
/// - SHA-256 来自 Adoptium 官方 API（checksum 字段），内置常量防漂移；
/// - 下载到容器内 /opt/foa-dl（⚠️ 不用 /tmp：proot `-R` 会把宿主 /tmp
///   绑进容器，容器内 /tmp 指向宿主目录，看不到 rootfs/tmp 里的文件，
///   曾导致 tar 报 "Cannot open: No such file or directory"，见 Bug 105）；
/// - 下载走多线程分段 + 多镜像并行（SdkDownloader.downloadMultiSource）；
/// - 已下载未解压的包保留在 /opt/foa-dl，重试时快路径跳过下载直接解压；
/// - 兜底：网络全挂时用户可走 [installFromLocalFile]，用系统文件选择器
///   从本地存储选包安装（大小 + SHA-256 双重校验）。
class JdkInstaller {
  static const String version = '17.0.20.1+1';
  static const String fileName =
      'OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.20.1_1.tar.gz';
  static const int size = 191962709; // Content-Length（TUNA 实测）
  static const String sha256 =
      '457b57af8f9c93ec39080bb8c764f559dc8c89a6da1a39d718a400b7890d3e41';
  static const int downloadSegments = 4; // 分段并发线程数

  /// 国内镜像（优先探测；2026-09-17 curl -r 0-0 实测均返回 206 支持分片）。
  /// 华为云同路径返回 HTML 页、阿里云/USTC/交大/腾讯/网易均 404，故不收录。
  static List<MirrorSource> domesticMirrors() => [
        const MirrorSource(
          'TUNA 清华',
          'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/aarch64/linux/$fileName',
        ),
        const MirrorSource(
          '南大 NJU',
          'https://mirrors.nju.edu.cn/adoptium/17/jdk/aarch64/linux/$fileName',
        ),
      ];

  /// 境外兜底（仅在国内源全部探测失败时使用）。
  static List<MirrorSource> foreignMirrors() => [
        const MirrorSource(
          'GitHub 官方',
          'https://github.com/adoptium/temurin17-binaries/releases/download/'
          'jdk-17.0.20.1%2B1/$fileName',
        ),
        const MirrorSource(
          'Adoptium API',
          'https://api.adoptium.net/v3/binary/version/jdk-17.0.20.1%2B1/'
          'linux/aarch64/jdk/hotspot/normal/eclipse',
        ),
      ];

  /// 容器内下载目录（真实路径 = rootfs/opt/foa-dl，guest 视角 /opt/foa-dl）。
  /// /opt 不在 proot `-R` 的推荐绑定列表内（该列表含 /tmp、/etc/*、$HOME 等），
  /// 是可靠的容器内落盘点；`-R` 绑定的宿主 /tmp 会遮蔽容器自身 /tmp。
  static String _dlDir(EnvInfo env) => '${env.rootfsPath}/opt/foa-dl';

  /// 重新验证：java 与 javac 版本双查（存在性 + 版本号），返回两行版本串
  /// （如 "openjdk version \"17.0.20.1\" 2026-08-18\njavac 17.0.20.1"）。
  /// 任一缺失或执行失败返回 null。
  static Future<String?> verify(ProotBridge bridge) async {
    final r = await bridge.exec(
      'if [ -x /opt/jdk/bin/java ] && [ -x /opt/jdk/bin/javac ]; then '
      '/opt/jdk/bin/java -version 2>&1 | head -1; '
      '/opt/jdk/bin/javac -version 2>&1 | head -1; '
      'else echo __NOT_INSTALLED__; fi',
      timeoutSec: 60,
    );
    if (r.exitCode != 0 || r.stdout.contains('__NOT_INSTALLED__')) {
      return null;
    }
    final v = r.stdout.trim();
    return v.isEmpty ? null : v;
  }

  /// 完整安装：快路径（已下载则跳过）→ 国内优先竞速选源 → 分段并发下载
  /// → SHA-256 → 容器内解压 → java/javac 验证。
  ///
  /// [onPhase]/[onProgress]/[onMirrorUsed] 供 UI 展示状态；
  /// [token] 可在任意阶段取消（解压阶段 token 无效，按容错处理）。
  static Future<String> install(
    ProotBridge bridge,
    EnvInfo env, {
    void Function(String phase)? onPhase,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorUsed,
    DownloadCancelToken? token,
  }) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装，请先初始化环境');
    }
    final dlDir = Directory(_dlDir(env));
    await dlDir.create(recursive: true);
    final tarPath = '${dlDir.path}/$fileName';

    // 0. 快路径：安装包已下载且校验通过 → 跳过下载（解压失败重试不再重复下载）
    var needDownload = true;
    final tar = File(tarPath);
    if (await tar.exists() && await tar.length() == size) {
      if (await SdkDownloader.verifySha256(tarPath, sha256)) {
        needDownload = false;
      } else {
        await tar.delete(); // 尺寸对但校验失败：清掉重下
      }
    }

    if (needDownload) {
      // 1. 国内优先探测：国内镜像取最快；全部不可达才退境外兜底
      onPhase?.call('probing');
      final ordered = await _pickFastestDomesticFirst(token: token);

      // 2. 分段并发下载（多镜像并行 + 分片续传 + SHA-256 校验）
      onPhase?.call('downloading');
      await SdkDownloader.downloadMultiSource(
        ordered,
        tarPath,
        size,
        segments: downloadSegments,
        sha256: sha256,
        token: token,
        onMirrorUsed: onMirrorUsed,
        onProgress: onProgress,
      );
    }

    return _extractAndValidate(bridge, env, onPhase: onPhase);
  }

  /// 本地安装兜底：用户通过系统文件选择器指定安装包（须为同一 Temurin
  /// 版本，大小 + SHA-256 双重校验），拷贝进 /opt/foa-dl 后走共用解压流程。
  static Future<String> installFromLocalFile(
    ProotBridge bridge,
    EnvInfo env,
    String localPath, {
    void Function(String phase)? onPhase,
    DownloadCancelToken? token,
  }) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装，请先初始化环境');
    }
    final src = File(localPath);
    if (!await src.exists()) {
      throw DownloadException('本地文件不存在：$localPath');
    }
    final len = await src.length();
    if (len != size) {
      throw DownloadException(
        '文件大小不符：期望 $size 字节（$fileName），实际 $len 字节',
      );
    }
    onPhase?.call('importing');
    final dlDir = Directory(_dlDir(env));
    await dlDir.create(recursive: true);
    final tarPath = '${dlDir.path}/$fileName';
    await src.copy(tarPath);
    await src.delete(); // 释放 filesDir/imports 空间
    final ok = await SdkDownloader.verifySha256(tarPath, sha256);
    if (!ok) {
      await File(tarPath).delete();
      throw DownloadException(
        'SHA-256 校验失败：所选文件不是 Temurin $version 安装包，或文件已损坏',
      );
    }
    return _extractAndValidate(bridge, env, onPhase: onPhase);
  }

  /// 共用的容器内解压 + 验证 + 清理步骤（下载与本地导入两条路径共用）。
  /// 解压用 /opt/foa-dl 而非 /tmp，规避 proot -R 对宿主 /tmp 的绑定（Bug 105）。
  static Future<String> _extractAndValidate(
    ProotBridge bridge,
    EnvInfo env, {
    void Function(String phase)? onPhase,
  }) async {
    onPhase?.call('extracting');
    final extract = await bridge.exec(
      'mkdir -p /opt && '
      'tar -xzf /opt/foa-dl/$fileName -C /opt && '
      'd=\$(ls -d /opt/jdk-* 2>/dev/null | head -1) && '
      'rm -rf /opt/jdk && mv "\$d" /opt/jdk && '
      'echo JDK_EXTRACT_OK',
      timeoutSec: 600,
    );
    if (extract.exitCode != 0 ||
        !extract.stdout.contains('JDK_EXTRACT_OK')) {
      throw DownloadException('解压失败：${extract.stderr.isNotEmpty ? extract.stderr : extract.stdout}');
    }

    onPhase?.call('validating');
    final ver = await bridge.exec(
      '/opt/jdk/bin/java -version 2>&1 | head -1; '
      '/opt/jdk/bin/javac -version 2>&1 | head -1',
      timeoutSec: 60,
    );
    if (ver.exitCode != 0) {
      throw DownloadException('JDK 验证失败：${ver.stderr}');
    }
    // 清理下载缓存（解压成功后可释放 ~183MB）
    await bridge.exec('rm -rf /opt/foa-dl', timeoutSec: 60);
    return ver.stdout.trim();
  }

  /// 国内优先分级探测：国内全部不可达才回退境外（境外也挂则继续抛异常）。
  static Future<List<MirrorSource>> _pickFastestDomesticFirst({
    DownloadCancelToken? token,
  }) async {
    try {
      return await SdkDownloader.pickFastest(domesticMirrors(), token: token);
    } on DownloadException {
      return await SdkDownloader.pickFastest(foreignMirrors(), token: token);
    }
  }

  /// 卸载：删除 /opt/jdk 与下载缓存。
  static Future<void> uninstall(
    ProotBridge bridge, {
    void Function(String phase)? onPhase,
  }) async {
    onPhase?.call('uninstalling');
    await bridge.exec('rm -rf /opt/jdk /opt/foa-dl', timeoutSec: 120);
  }
}
