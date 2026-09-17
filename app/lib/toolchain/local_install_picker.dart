import 'package:flutter/services.dart';

/// 系统文件选择器选中的安装包（原生层已把 content:// URI 拷贝到
/// filesDir/imports/ 下的真实文件，Dart 侧拿到的是本地绝对路径）。
class PickedInstallFile {
  final bool ok;
  final String? path; // 本地绝对路径（filesDir/imports/...）
  final String? name; // 原文件名（已做安全化）
  final int? size; // 字节数
  final String? error; // ok=false 时的原因

  const PickedInstallFile({
    required this.ok,
    this.path,
    this.name,
    this.size,
    this.error,
  });

  factory PickedInstallFile.fromMap(Map<Object?, Object?> m) =>
      PickedInstallFile(
        ok: m['ok'] == true,
        path: m['path'] as String?,
        name: m['name'] as String?,
        size: (m['size'] as num?)?.toInt(),
        error: m['error'] as String?,
      );
}

/// 本地安装兜底：调用系统文件选择器（SAF，ACTION_OPEN_DOCUMENT），
/// 让用户从本地存储直接选择安装包体。与 proot 桥共用同一 MethodChannel。
class LocalInstallPicker {
  static const MethodChannel _channel = MethodChannel('dev.foa/proot');

  /// 弹出系统文件选择器；用户确认后返回拷贝到应用私有目录的本地文件。
  /// 用户取消或原生层失败时返回 ok=false + error。
  static Future<PickedInstallFile> pickInstallFile() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('pickInstallFile');
      return PickedInstallFile.fromMap(raw ?? const {});
    } on PlatformException catch (e) {
      return PickedInstallFile(ok: false, error: '打开文件选择器失败：${e.message}');
    } catch (e) {
      return PickedInstallFile(ok: false, error: '打开文件选择器失败：$e');
    }
  }
}
