import 'dart:io';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'sdk_downloader.dart';

/// JDK 17（Temurin，linux-aarch64）安装编排。
///
/// 版本固定 17.0.20.1+1（2026-09-17 探测的 TUNA/官方最新 LTS）：
/// - 镜像：TUNA 清华主源 + GitHub 官方 + Adoptium 固定版本 API 兜底；
/// - SHA-256 来自 Adoptium 官方 API（checksum 字段），内置常量防漂移；
/// - 下载到容器内 /tmp（= rootfsPath/tmp），proot 内 tar 解压到 /opt/jdk。
class JdkInstaller {
  static const String version = '17.0.20.1+1';
  static const String fileName =
      'OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.20.1_1.tar.gz';
  static const int size = 191962709; // Content-Length（TUNA 实测）
  static const String sha256 =
      '457b57af8f9c93ec39080bb8c764f559dc8c89a6da1a39d718a400b7890d3e41';

  static List<MirrorSource> mirrors() => [
        const MirrorSource(
          'TUNA 清华',
          'https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/aarch64/linux/$fileName',
        ),
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

  /// 检查 rootfs 内 JDK 是否已安装；已装则返回版本串（如
  /// "openjdk version \"17.0.20\" 2025-07-15"），否则返回 null。
  /// 需要 proot 可运行（rootfs 已安装）。
  static Future<String?> installedVersion(ProotBridge bridge) async {
    final r = await bridge.exec(
      'if [ -x /opt/jdk/bin/java ]; then /opt/jdk/bin/java -version 2>&1 | head -1; '
      'else echo __NOT_INSTALLED__; fi',
      timeoutSec: 60,
    );
    if (r.exitCode != 0 || r.stdout.contains('__NOT_INSTALLED__')) {
      return null;
    }
    final v = r.stdout.trim();
    return v.isEmpty ? null : v;
  }

  /// 完整安装：竞速选源 → 断点续传下载 → SHA-256 → 容器内解压 → java/javac 验证。
  ///
  /// [onPhase]/[onProgress]/[onMirrorSwitch] 供 UI 展示状态；
  /// [token] 可在任意阶段取消（解压阶段 token 无效，按容错处理）。
  static Future<String> install(
    ProotBridge bridge,
    EnvInfo env, {
    void Function(String phase)? onPhase,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorSwitch,
    DownloadCancelToken? token,
  }) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装，请先初始化环境');
    }
    final rootfs = env.rootfsPath;
    final tmpDir = Directory('$rootfs/tmp');
    await tmpDir.create(recursive: true);
    final tarPath = '$rootfs/tmp/$fileName';

    // 1. 竞速选源（返回最快在前）
    onPhase?.call('probing');
    final ordered =
        await SdkDownloader.pickFastest(mirrors(), token: token);

    // 2. 下载（含 SHA-256 校验，失败自动换镜像）
    onPhase?.call('downloading');
    await SdkDownloader.downloadWithFailover(
      ordered,
      tarPath,
      size,
      sha256: sha256,
      token: token,
      onMirrorSwitch: onMirrorSwitch,
      onProgress: onProgress,
    );

    // 3. 容器内解压到 /opt/jdk（tar 处理符号链接/权限，比 Dart 解压省内存）
    onPhase?.call('extracting');
    final extract = await bridge.exec(
      'mkdir -p /opt && '
      'tar -xzf /tmp/$fileName -C /opt && '
      'd=\$(ls -d /opt/jdk-* 2>/dev/null | head -1) && '
      'rm -rf /opt/jdk && mv "\$d" /opt/jdk && '
      'echo JDK_EXTRACT_OK',
      timeoutSec: 600,
    );
    if (extract.exitCode != 0 ||
        !extract.stdout.contains('JDK_EXTRACT_OK')) {
      throw DownloadException('解压失败：${extract.stderr.isNotEmpty ? extract.stderr : extract.stdout}');
    }

    // 4. 验证 java + javac
    onPhase?.call('validating');
    final ver = await bridge.exec(
      '/opt/jdk/bin/java -version 2>&1 | head -1; '
      '/opt/jdk/bin/javac -version 2>&1 | head -1',
      timeoutSec: 60,
    );
    if (ver.exitCode != 0) {
      throw DownloadException('JDK 验证失败：${ver.stderr}');
    }
    // 清理安装包（解压成功后可释放 ~183MB）
    await bridge.exec('rm -f /tmp/$fileName /tmp/$fileName.part',
        timeoutSec: 60);
    return ver.stdout.trim();
  }

  /// 卸载：删除 /opt/jdk 与残留安装包。
  static Future<void> uninstall(
    ProotBridge bridge, {
    void Function(String phase)? onPhase,
  }) async {
    onPhase?.call('uninstalling');
    await bridge.exec('rm -rf /opt/jdk /tmp/$fileName /tmp/$fileName.part',
        timeoutSec: 120);
  }
}
