import 'package:flutter/services.dart';

/// 项目代码区根（容器内路径，与 Kotlin 侧 PROJECTS_REL 对应）。
const String kProjectsRoot = '/root/projects';

/// 目录/文件条目。
class FsEntry {
  final String name;
  final bool isDir;
  final int size;
  final int mtime;

  const FsEntry({
    required this.name,
    required this.isDir,
    this.size = 0,
    this.mtime = 0,
  });

  /// 容器内完整路径。
  String pathOf(String parent) =>
      parent == '/' ? '/$name' : '$parent/$name';

  factory FsEntry.fromMap(Map<Object?, Object?> m) => FsEntry(
        name: m['name'] as String? ?? '',
        isDir: m['isDir'] as bool? ?? false,
        size: m['size'] as int? ?? 0,
        mtime: m['mtime'] as int? ?? 0,
      );
}

/// 文件操作结果（成功时 ok=true）。
class FsResult {
  final bool ok;
  final String? error;

  const FsResult({required this.ok, this.error});

  factory FsResult.fromMap(Map<Object?, Object?> m) => FsResult(
        ok: m['ok'] as bool? ?? false,
        error: m['error'] as String?,
      );
}

/// 目录列表结果。
class FsListResult extends FsResult {
  final List<FsEntry> entries;
  const FsListResult({required super.ok, super.error, this.entries = const []});

  factory FsListResult.fromMap(Map<Object?, Object?> m) => FsListResult(
        ok: m['ok'] as bool? ?? false,
        error: m['error'] as String?,
        entries: ((m['entries'] as List<Object?>?) ?? const [])
            .map((e) => FsEntry.fromMap((e as Map<Object?, Object?>?) ?? {}))
            .toList(),
      );
}

/// 文件读取结果。
class FsReadResult extends FsResult {
  final String content;
  const FsReadResult({required super.ok, super.error, this.content = ''});

  factory FsReadResult.fromMap(Map<Object?, Object?> m) => FsReadResult(
        ok: m['ok'] as bool? ?? false,
        error: m['error'] as String?,
        content: m['content'] as String? ?? '',
      );
}

/// 与 Kotlin 侧 MainActivity 文件操作通道的桥（同一 MethodChannel "dev.foa/proot"）。
///
/// 约定（Step 2 定稿）：
/// - 路径一律用容器内路径（/root/projects/...），Kotlin 侧做白名单校验与映射；
/// - 文件操作不走 proot 进程，Kotlin 用 java.io.File 直接读写真实路径
///   （filesDir/rootfs/debian/root/projects），性能好、无 shell 转义风险；
/// - 目录列表返回按名称排序，目录在前。
class FsBridge {
  static const MethodChannel _channel = MethodChannel('dev.foa/proot');

  /// 列出目录内容（不递归）。
  Future<FsListResult> list(String path) async {
    final raw = await _channel.invokeMethod('fileList', {'path': path});
    return FsListResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 读取文本文件（Kotlin 侧上限 2MB）。
  Future<FsReadResult> read(String path) async {
    final raw = await _channel.invokeMethod('fileRead', {'path': path});
    return FsReadResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 写入文本文件（覆盖；目录不存在时自动创建）。
  Future<FsResult> write(String path, String content) async {
    final raw = await _channel.invokeMethod('fileWrite', {
      'path': path,
      'content': content,
    });
    return FsResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 创建目录（含父目录）。
  Future<FsResult> mkdir(String path) async {
    final raw = await _channel.invokeMethod('fileMkdir', {'path': path});
    return FsResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 重命名/移动（newName 仅限同级文件名，不含路径分隔符）。
  Future<FsResult> rename(String path, String newName) async {
    final raw = await _channel.invokeMethod('fileRename', {
      'path': path,
      'newName': newName,
    });
    return FsResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 删除文件或目录（目录递归删除）。
  Future<FsResult> delete(String path) async {
    final raw = await _channel.invokeMethod('fileDelete', {'path': path});
    return FsResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }
}
