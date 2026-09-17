import 'package:flutter/services.dart';

/// 文件浏览器条目（Step 4）。
class FsBrowserEntry {
  final String name;
  final bool isDir;
  final int size;
  final int mtime;

  const FsBrowserEntry({
    required this.name,
    required this.isDir,
    this.size = 0,
    this.mtime = 0,
  });

  /// 容器内完整路径。
  String pathOf(String parent) =>
      parent == '/' ? '/$name' : '$parent/$name';

  factory FsBrowserEntry.fromMap(Map<Object?, Object?> m) => FsBrowserEntry(
        name: m['name'] as String? ?? '',
        isDir: m['isDir'] as bool? ?? false,
        size: m['size'] as int? ?? 0,
        mtime: m['mtime'] as int? ?? 0,
      );
}

/// 目录列表结果。
class FsBrowseResult {
  final bool ok;
  final String? error;
  final List<FsBrowserEntry> entries;

  const FsBrowseResult({
    required this.ok,
    this.error,
    this.entries = const [],
  });

  factory FsBrowseResult.fromMap(Map<Object?, Object?> m) => FsBrowseResult(
        ok: m['ok'] == true,
        error: m['error'] as String?,
        entries: ((m['entries'] as List<Object?>?) ?? const [])
            .map((e) => FsBrowserEntry.fromMap((e as Map<Object?, Object?>?) ?? {}))
            .toList(),
      );
}

/// 通用操作结果。
class FsOpResult {
  final bool ok;
  final String? error;

  const FsOpResult({required this.ok, this.error});

  factory FsOpResult.fromMap(Map<Object?, Object?> m) => FsOpResult(
        ok: m['ok'] == true,
        error: m['error'] as String?,
      );
}

/// 导入结果（文件已落到容器 /root/imports）。
class ImportedFile {
  final bool ok;
  final String? path; // 容器内路径
  final String? name;
  final int? size;
  final String? error;

  const ImportedFile({
    required this.ok,
    this.path,
    this.name,
    this.size,
    this.error,
  });

  factory ImportedFile.fromMap(Map<Object?, Object?> m) => ImportedFile(
        ok: m['ok'] == true,
        path: m['path'] as String?,
        name: m['name'] as String?,
        size: (m['size'] as num?)?.toInt(),
        error: m['error'] as String?,
      );
}

/// 与 Kotlin 侧 MainActivity 的文件浏览器通道（同一 MethodChannel "dev.foa/proot"）。
///
/// 约定（Step 4 定稿）：
/// - 路径一律容器内路径（/ 开头，rootfs 视角），Kotlin 侧白名单 = rootfs 根内
///   （resolveRootfsPath，canonicalize 防逃逸），与编辑器 file* 的 /root/projects
///   严格白名单独立——文件浏览器是浏览整个 app 数据的入口；
/// - 浏览/删除/重命名/新建走原生 java.io.File（快、结构化、无 shell 转义）；
/// - 解压不走原生（tar.xz Java 无内置），统一走容器 exec（ProotBridge，xz-utils/unzip/tar
///   工具链已装），源文件在容器内路径可见；
/// - 导入文件落容器 /root/imports（= filesDir/rootfs/debian/root/imports），导入后
///   浏览器可直接看到、解压、导出；SDK 本地安装的 filesDir/imports 是内部缓存不展示。
class FileBrowserBridge {
  static const MethodChannel _channel = MethodChannel('dev.foa/proot');

  /// 列出容器内目录内容（不递归）。
  Future<FsBrowseResult> browse(String path) async {
    final raw = await _channel.invokeMethod('fsBrowse', {'path': path});
    return FsBrowseResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 创建目录（含父目录）。
  Future<FsOpResult> mkdir(String path) async {
    final raw = await _channel.invokeMethod('fsMkdir', {'path': path});
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 重命名/移动（newName 仅限同级文件名，不含路径分隔符）。
  Future<FsOpResult> rename(String path, String newName) async {
    final raw = await _channel.invokeMethod('fsRename', {
      'path': path,
      'newName': newName,
    });
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 删除文件或目录（目录递归删除；Dart 侧负责二次确认）。
  Future<FsOpResult> delete(String path) async {
    final raw = await _channel.invokeMethod('fsDelete', {'path': path});
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 复制文件或目录（容器域，递归；目标不得已存在/不得在源内部）。
  Future<FsOpResult> copy(String src, String dst) async {
    final raw = await _channel
        .invokeMethod('fsCopy', {'src': src, 'dst': dst});
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 移动文件或目录（容器域，递归；跨分区由原生回退复制+删除）。
  Future<FsOpResult> move(String src, String dst) async {
    final raw = await _channel
        .invokeMethod('fsMove', {'src': src, 'dst': dst});
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  // ---------------- 宿主域（真实路径：filesDir / Android/data/<pkg>）----------------

  /// 列出宿主域真实路径目录内容（白名单：app 自有目录）。
  Future<FsBrowseResult> hostBrowse(String realPath) async {
    final raw = await _channel
        .invokeMethod('hostBrowse', {'path': realPath});
    return FsBrowseResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  Future<FsOpResult> hostMkdir(String realPath) async {
    final raw = await _channel
        .invokeMethod('hostMkdir', {'path': realPath});
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  Future<FsOpResult> hostRename(String realPath, String newName) async {
    final raw = await _channel.invokeMethod(
      'hostRename',
      {'path': realPath, 'newName': newName},
    );
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  Future<FsOpResult> hostDelete(String realPath) async {
    final raw = await _channel
        .invokeMethod('hostDelete', {'path': realPath});
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  Future<FsOpResult> hostCopy(String srcReal, String dstReal) async {
    final raw = await _channel.invokeMethod(
      'hostCopy',
      {'src': srcReal, 'dst': dstReal},
    );
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  Future<FsOpResult> hostMove(String srcReal, String dstReal) async {
    final raw = await _channel.invokeMethod(
      'hostMove',
      {'src': srcReal, 'dst': dstReal},
    );
    return FsOpResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 系统文件选择器导入任意文件到容器 /root/imports，返回容器路径。
  Future<ImportedFile> pickImport() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('pickImportFile');
      return ImportedFile.fromMap(raw ?? const {});
    } on PlatformException catch (e) {
      return ImportedFile(ok: false, error: '打开文件选择器失败：${e.message}');
    } catch (e) {
      return ImportedFile(ok: false, error: '打开文件选择器失败：$e');
    }
  }

  /// 导出容器内文件到系统（SAF 保存对话框），displayName 为建议文件名。
  Future<FsOpResult> export(String path, String displayName) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'exportFile',
        {'path': path, 'displayName': displayName},
      );
      return FsOpResult.fromMap(raw ?? const {});
    } on PlatformException catch (e) {
      return FsOpResult(ok: false, error: '导出失败：${e.message}');
    } catch (e) {
      return FsOpResult(ok: false, error: '导出失败：$e');
    }
  }
}
