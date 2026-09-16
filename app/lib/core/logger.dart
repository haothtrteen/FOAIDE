import 'dart:convert';
import 'dart:io';

/// 结构化 JSONL 日志。
///
/// 每行一个事件，写入 filesDir/logs/app-YYYYMMDD.log。
/// 这是排查构建问题的关键证据链（手册 04 的 Bug 记录都从这里取数据）：
/// 原生侧返回 exitCode/stdout/stderr/durationMs，Dart 侧统一落盘。
class AppLogger {
  static File? _file;

  /// 用 filesDir 初始化（路径来自原生 envInfo，单一事实来源）。
  static Future<void> init(String filesDir) async {
    try {
      final dir = Directory('$filesDir/logs');
      await dir.create(recursive: true);
      final now = DateTime.now();
      final day =
          '${now.year}${_p(now.month)}${_p(now.day)}';
      _file = File('${dir.path}/app-$day.log');
    } catch (_) {
      // 日志初始化失败绝不能影响主流程
    }
  }

  static Future<void> event(String tag, Map<String, Object?> data) async {
    final f = _file;
    if (f == null) return;
    try {
      final line = jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'tag': tag,
        ...data,
      });
      await f.writeAsString('$line\n', mode: FileMode.append);
    } catch (_) {
      // 同上：日志失败静默
    }
  }

  static String _p(int v) => v.toString().padLeft(2, '0');
}
