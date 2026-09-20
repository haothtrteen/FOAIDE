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

// ---------------- proroot 容器层（alpha.61） ----------------

/// proroot 落位状态。
///
/// 特意保留 [missing] / [notElf] 这两个**可操作**的明细而不是一个 bool：
/// 用户看到"缺 libproroot-bridge.so"才知道该去补哪个文件；
/// 只告诉他"没装好"等于没说。
class ProrootStatus {
  final bool installed;

  /// 落位目录（展示给用户，说明文件该放哪）。
  final String dir;

  /// 已就位的文件名。
  final List<String> present;

  /// 还缺的文件名。
  final List<String> missing;

  /// 存在但不是 ELF 的文件名（下载损坏/架构不对）。
  final List<String> notElf;

  /// 设备首选 ABI（proroot 只有 arm64-v8a）。
  final String abi;

  /// 系统 API level（proroot 要求 26+）。
  final int api;

  /// rootfs 是否就绪（没 rootfs 就无法冒烟测试）。
  final bool rootfsReady;

  const ProrootStatus({
    this.installed = false,
    this.dir = '',
    this.present = const [],
    this.missing = const [],
    this.notElf = const [],
    this.abi = '',
    this.api = 0,
    this.rootfsReady = false,
  });

  /// ABI 是否匹配（proroot 只提供 arm64-v8a）。
  bool get abiOk => abi.startsWith('arm64');

  /// API 是否达标。
  bool get apiOk => api >= 26;

  /// 能否开启 proroot：文件齐、ABI 对、API 够。
  bool get usable => installed && abiOk && apiOk;

  factory ProrootStatus.fromMap(Map<Object?, Object?> m) => ProrootStatus(
        installed: m['installed'] == true,
        dir: m['dir'] as String? ?? '',
        present: _strList(m['present']),
        missing: _strList(m['missing']),
        notElf: _strList(m['notElf']),
        abi: m['abi'] as String? ?? '',
        api: (m['api'] as num?)?.toInt() ?? 0,
        rootfsReady: m['rootfsReady'] == true,
      );
}

/// proroot 导入结果。
class ProrootInstallResult {
  final bool ok;
  final List<String> copied;
  final List<String> missing;
  final List<String> notElf;
  final String? error;

  const ProrootInstallResult({
    required this.ok,
    this.copied = const [],
    this.missing = const [],
    this.notElf = const [],
    this.error,
  });

  factory ProrootInstallResult.fromMap(Map<Object?, Object?> m) =>
      ProrootInstallResult(
        ok: m['ok'] == true,
        copied: _strList(m['copied']),
        missing: _strList(m['missing']),
        notElf: _strList(m['notElf']),
        error: m['error'] as String?,
      );
}

/// proroot 冒烟测试结果。
class ProrootProbeResult {
  final bool ok;
  final int exitCode;
  final String output;
  final String cmd;
  final String? error;

  const ProrootProbeResult({
    required this.ok,
    this.exitCode = 0,
    this.output = '',
    this.cmd = '',
    this.error,
  });

  factory ProrootProbeResult.fromMap(Map<Object?, Object?> m) =>
      ProrootProbeResult(
        ok: m['ok'] == true,
        exitCode: (m['exitCode'] as num?)?.toInt() ?? 0,
        output: m['output'] as String? ?? '',
        cmd: m['cmd'] as String? ?? '',
        error: m['error'] as String?,
      );
}

/// 把 `List<Object?>` 稳妥转成 `List<String>`（原生侧可能给 List<dynamic>）。
List<String> _strList(Object? v) => v is List
    ? v.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList()
    : const [];
