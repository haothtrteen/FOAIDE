/// 原生层（Kotlin MainActivity）回传的环境信息。
class EnvInfo {
  final String filesDir;
  final String cacheDir;
  final String nativeLibraryDir;

  /// 真实 Android 包名（applicationId），由原生侧 `packageName` 运行时返回。
  ///
  /// **不要在 Dart 里拼 `/data/data/<pkg>`**：applicationId 可被
  /// applicationIdSuffix 改变（dev/prod 分身），拼出来的路径会指向另一个
  /// App 的私有目录。需要宿主路径时一律取 [filesDir] / [externalDataDir]。
  final String packageName;
  final String rootfsPath;
  final bool rootfsInstalled;
  // Step 4 文件浏览器宿主域根：外部 Android/data/<pkg>（无外部存储时为 null）
  final String? externalDataDir;
  final String? prootPath;
  final String? abi;
  final int androidSdk;
  final String device;

  // ---- AVF（Android 虚拟化框架）能力检测 ----
  // 仅用于「告知用户可否走 AVF 路线」，不代表 App 能驱动 VM：
  // AVF 的 VM 由特权系统服务 virtmgr 管理，普通 App 无 API 可及。
  // 详见 dev-handbook 与《AVF集成可行性评估.md》。
  final bool avfSupported;
  final bool avfTerminalInstalled;
  final String avfReason;

  const EnvInfo({
    required this.filesDir,
    required this.cacheDir,
    required this.nativeLibraryDir,
    this.packageName = '',
    required this.rootfsPath,
    required this.rootfsInstalled,
    this.externalDataDir,
    this.prootPath,
    this.abi,
    this.androidSdk = 0,
    this.device = '',
    this.avfSupported = false,
    this.avfTerminalInstalled = false,
    this.avfReason = '',
  });

  factory EnvInfo.fromMap(Map<Object?, Object?> m) => EnvInfo(
        filesDir: m['filesDir'] as String? ?? '',
        cacheDir: m['cacheDir'] as String? ?? '',
        nativeLibraryDir: m['nativeLibraryDir'] as String? ?? '',
        packageName: m['packageName'] as String? ?? '',
        rootfsPath: m['rootfsPath'] as String? ?? '',
        rootfsInstalled: m['rootfsInstalled'] as bool? ?? false,
        externalDataDir: m['externalDataDir'] as String?,
        prootPath: m['prootPath'] as String?,
        abi: m['abi'] as String?,
        androidSdk: m['androidSdk'] as int? ?? 0,
        device: m['device'] as String? ?? '',
        avfSupported: m['avfSupported'] as bool? ?? false,
        avfTerminalInstalled: m['avfTerminalInstalled'] as bool? ?? false,
        avfReason: m['avfReason'] as String? ?? '',
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

// ---------------- Bug 430 · 可交互 PTY 终端 ----------------

/// pty 会话启动结果。
class PtyStart {
  final bool ok;
  final int id;
  final String backend; // 'proot' | 'termux'
  final int cols;
  final int rows;
  final String? error;

  const PtyStart({
    required this.ok,
    this.id = -1,
    this.backend = '',
    this.cols = 80,
    this.rows = 24,
    this.error,
  });

  factory PtyStart.fromMap(Map<Object?, Object?> m) => PtyStart(
        ok: m['ok'] == true,
        id: (m['id'] as num?)?.toInt() ?? -1,
        backend: m['backend'] as String? ?? '',
        cols: (m['cols'] as num?)?.toInt() ?? 80,
        rows: (m['rows'] as num?)?.toInt() ?? 24,
        error: m['error'] as String?,
      );
}

/// pty 输出轮询结果：chunk 为自 offset 起的**原样**新增字节（含 ANSI 转义、
/// \r 回车、退格等控制字符），由 UI 侧做终端语义解释。
class PtyPoll {
  final bool ok;
  final bool running;
  final String chunk;
  final int len;
  final int? exitCode;
  final String backend;
  final String? error;

  const PtyPoll({
    required this.ok,
    this.running = false,
    this.chunk = '',
    this.len = 0,
    this.exitCode,
    this.backend = '',
    this.error,
  });

  factory PtyPoll.fromMap(Map<Object?, Object?> m) => PtyPoll(
        ok: m['ok'] == true,
        running: m['running'] == true,
        chunk: m['chunk'] as String? ?? '',
        len: (m['len'] as num?)?.toInt() ?? 0,
        exitCode: (m['exitCode'] as num?)?.toInt(),
        backend: m['backend'] as String? ?? '',
        error: m['error'] as String?,
      );
}

