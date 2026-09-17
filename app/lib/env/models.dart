/// 原生层（Kotlin MainActivity）回传的环境信息。
class EnvInfo {
  final String filesDir;
  final String cacheDir;
  final String nativeLibraryDir;
  final String rootfsPath;
  final bool rootfsInstalled;
  // Step 4 文件浏览器宿主域根：外部 Android/data/<pkg>（无外部存储时为 null）
  final String? externalDataDir;
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
    this.externalDataDir,
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
        externalDataDir: m['externalDataDir'] as String?,
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

/// Step 6 流式命令启动结果（构建用长任务）。
class ExecStreamStart {
  final bool ok;
  final int id;
  final String? error;

  const ExecStreamStart({required this.ok, this.id = -1, this.error});

  factory ExecStreamStart.fromMap(Map<Object?, Object?> m) => ExecStreamStart(
        ok: m['ok'] == true,
        id: (m['id'] as num?)?.toInt() ?? -1,
        error: m['error'] as String?,
      );
}

/// Step 6 流式命令轮询结果：自 offset 起的新增输出快照。
class ExecStreamPoll {
  final bool ok;
  final bool running;
  final String chunk; // 本次新增文本（原样，含 ANSI/\r，Dart 侧清洗）
  final int len; // 缓冲总长度（下次轮询的 offset）
  final int? exitCode; // 已结束时非空
  final String? error;

  const ExecStreamPoll({
    required this.ok,
    required this.running,
    this.chunk = '',
    this.len = 0,
    this.exitCode,
    this.error,
  });

  factory ExecStreamPoll.fromMap(Map<Object?, Object?> m) => ExecStreamPoll(
        ok: m['ok'] == true,
        running: m['running'] == true,
        chunk: m['chunk'] as String? ?? '',
        len: (m['len'] as num?)?.toInt() ?? 0,
        exitCode: (m['exitCode'] as num?)?.toInt(),
        error: m['error'] as String?,
      );
}
