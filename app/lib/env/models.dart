/// 原生层（Kotlin MainActivity）回传的环境信息。
class EnvInfo {
  final String filesDir;
  final String cacheDir;
  final String nativeLibraryDir;
  final String rootfsPath;
  final bool rootfsInstalled;
  final String? prootPath;
  final String? abi;
  final int androidSdk;
  final String device;

  const EnvInfo({
    required this.filesDir,
    required this.cacheDir,
    required this.nativeLibraryDir,
    required this.rootfsPath,
    required this.rootfsInstalled,
    this.prootPath,
    this.abi,
    this.androidSdk = 0,
    this.device = '',
  });

  factory EnvInfo.fromMap(Map<Object?, Object?> m) => EnvInfo(
        filesDir: m['filesDir'] as String? ?? '',
        cacheDir: m['cacheDir'] as String? ?? '',
        nativeLibraryDir: m['nativeLibraryDir'] as String? ?? '',
        rootfsPath: m['rootfsPath'] as String? ?? '',
        rootfsInstalled: m['rootfsInstalled'] as bool? ?? false,
        prootPath: m['prootPath'] as String?,
        abi: m['abi'] as String?,
        androidSdk: m['androidSdk'] as int? ?? 0,
        device: m['device'] as String? ?? '',
      );
}

/// 一次 proot 命令执行结果（原生侧结构化返回）。
class ProotResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final int durationMs;

  const ProotResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
  });

  bool get ok => exitCode == 0;

  factory ProotResult.fromMap(Map<Object?, Object?> m) => ProotResult(
        exitCode: m['exitCode'] as int? ?? -1,
        stdout: m['stdout'] as String? ?? '',
        stderr: m['stderr'] as String? ?? '',
        durationMs: m['durationMs'] as int? ?? 0,
      );
}

/// rootfs 安装结果。
class InstallResult {
  final bool ok;
  final bool alreadyInstalled;
  final int files;
  final int durationMs;
  final String? error;

  const InstallResult({
    required this.ok,
    this.alreadyInstalled = false,
    this.files = 0,
    this.durationMs = 0,
    this.error,
  });

  factory InstallResult.fromMap(Map<Object?, Object?> m) => InstallResult(
        ok: m['ok'] as bool? ?? false,
        alreadyInstalled: m['alreadyInstalled'] as bool? ?? false,
        files: m['files'] as int? ?? 0,
        durationMs: m['durationMs'] as int? ?? 0,
        error: m['error'] as String?,
      );
}
