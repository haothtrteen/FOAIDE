import 'dart:io';

import '../filemanager/fs_browser_bridge.dart';

/// 项目统计快照（alpha.61）——预览子页与打包子页共用的数据源。
///
/// 用户反馈"预览页太空"，要求补上：依赖缓存了几个包、最近一次构建状态、
/// 最近构建记录。这些数据分散在三处：
/// - pub 缓存 → 容器内 `${PUB_CACHE:-/root/.pub-cache}/hosted/pub.dev/` 下的目录数；
/// - 构建产物 → `build/app/outputs/flutter-apk/*.apk`（文件大小 / 时间）；
/// - 构建状态 → `BuildRunner` 的内存态（本次进程内）。
///
/// 抽成数据类 + 纯函数的好处：**可单测**。目录遍历与字节格式化是
/// "看着对但边界容易错"的代码（0 字节、GB 级、时间戳为 0 等）。
class ProjectStats {
  /// pub 缓存里已下载的包数量（`hosted/pub.dev/<pkg>-<ver>/` 的目录数）。
  final int cachedPackages;

  /// pub 缓存占用（字节）。缓存大是"磁盘被吃掉"的常见原因，值得可见。
  final int pubCacheBytes;

  /// 已构建的 APK 产物（按时间倒序，最新的在前）。
  final List<ApkArtifact> artifacts;

  const ProjectStats({
    this.cachedPackages = 0,
    this.pubCacheBytes = 0,
    this.artifacts = const [],
  });

  static const ProjectStats empty = ProjectStats();

  /// 最近一次产物（无产物时为 null）。
  ApkArtifact? get latest => artifacts.isEmpty ? null : artifacts.first;

  /// 是否拿到了有意义的数据（全 0 时 UI 应显示"暂无"而不是"0 个包"）。
  bool get hasAnyData =>
      cachedPackages > 0 || artifacts.isNotEmpty || pubCacheBytes > 0;
}

/// 一个已构建的 APK 产物。
class ApkArtifact {
  final String name;

  /// 容器内完整路径（用于安装/分享/下载）。
  final String guestPath;
  final int sizeBytes;

  /// 修改时间戳（毫秒；0 = 未知）。
  final int mtimeMs;

  const ApkArtifact({
    required this.name,
    required this.guestPath,
    this.sizeBytes = 0,
    this.mtimeMs = 0,
  });

  /// 产物的"干净名字"：把 flutter 的默认名转成用户能认出的样式。
  /// `app-release.apk` → `app-release.apk`（原样保留，不做改名——
  /// 用户可能已经习惯这个名字，改了反而认不出）。
  String get displayName => name;

  DateTime? get modifiedAt =>
      mtimeMs <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(mtimeMs);
}

/// 采集项目统计。所有 IO 都容错——统计失败不该让页面挂掉。
class ProjectStatsReader {
  ProjectStatsReader(this._fb);

  final FileBrowserBridge _fb;

  /// 容器内 pub 缓存根。与 `termux_backend` 的约定一致：优先 `PUB_CACHE`，
  /// 缺省 `/root/.pub-cache`（pub 在 root 用户下的默认位置）。
  static const String pubCacheDir = '/root/.pub-cache';

  /// 读取完整统计。
  ///
  /// [projectName] 用于定位产物目录；[fallback] 在无法读取时返回
  /// （通常是上一次的快照，避免页面闪成空态）。
  Future<ProjectStats> read(
    String projectName, {
    ProjectStats? fallback,
  }) async {
    final cached = await _readPubCache();
    final arts = await _readArtifacts(projectName);
    if (cached == null && arts == null) {
      return fallback ?? ProjectStats.empty;
    }
    return ProjectStats(
      cachedPackages: cached?.$1 ?? fallback?.cachedPackages ?? 0,
      pubCacheBytes: cached?.$2 ?? fallback?.pubCacheBytes ?? 0,
      artifacts: arts ?? fallback?.artifacts ?? const [],
    );
  }

  /// pub 缓存：(包数量, 总字节数)。目录不存在时返回 null。
  Future<(int, int)?> _readPubCache() async {
    // hosted/pub.dev 下每个 `<name>-<version>` 目录就是一个已缓存包
    const hosted = '$pubCacheDir/hosted/pub.dev';
    final r = await _fb.browse(hosted);
    if (!r.ok) return null;
    var count = 0;
    var bytes = 0;
    for (final e in r.entries) {
      if (!e.isDir) continue;
      count++;
      bytes += e.size; // 目录 size 由原生侧给出（递归或 0，容错即可）
    }
    return (count, bytes);
  }

  /// 构建产物列表（时间倒序）。目录不存在时返回 null。
  Future<List<ApkArtifact>?> _readArtifacts(String projectName) async {
    final dir = '/root/projects/$projectName/build/app/outputs/flutter-apk';
    final r = await _fb.browse(dir);
    if (!r.ok) return null;
    final list = r.entries
        .where((e) => !e.isDir && e.name.endsWith('.apk'))
        .map((e) => ApkArtifact(
              name: e.name,
              guestPath: e.pathOf(dir),
              sizeBytes: e.size,
              mtimeMs: e.mtime,
            ))
        .toList()
      ..sort((a, b) => b.mtimeMs.compareTo(a.mtimeMs));
    return list;
  }

  /// 依赖是否已拉取（``.dart_tool/package_config.json`` 存在即视为已 pub get）。
  ///
  /// 用途：打包前置检查要让用户看到"依赖没拉"，而不是等他点了打包
  /// 再在日志里发现。走一次 browse 比 exec 便宜得多。
  Future<bool> depsFetched(String projectName) async {
    final dir = '/root/projects/$projectName/.dart_tool';
    final r = await _fb.browse(dir);
    if (!r.ok) return false;
    return r.entries.any((e) => !e.isDir && e.name == 'package_config.json');
  }

  /// 宿主侧读文件大小（用于"下载"前确认空间/展示）。
  static int fileSizeSync(String hostPath) {
    try {
      final f = File(hostPath);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }
}

/// 字节数的人类可读格式（1024 进制）。
///
/// 抽成顶层函数便于单测边界：0、不到 1KB、刚好 1024、GB 级。
String fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  // 整数不显示小数点（"512 KB" 而非 "512.0 KB"）
  final s = v == v.roundToDouble()
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(v < 10 ? 1 : 0);
  return '$s ${units[i]}';
}

/// 相对时间（"3 分钟前"），用于构建记录。
///
/// [now] 可注入，便于测试；mtime 未知（<=0）时返回 "未知时间"。
String fmtRelativeTime(int mtimeMs, {DateTime? now}) {
  if (mtimeMs <= 0) return '未知时间';
  final t = DateTime.fromMillisecondsSinceEpoch(mtimeMs);
  final cur = now ?? DateTime.now();
  final d = cur.difference(t);
  if (d.isNegative) return '刚刚';
  if (d.inSeconds < 60) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  // 超过一个月用绝对日期更直观
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}';
}
