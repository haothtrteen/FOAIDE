import 'dart:convert';
import 'dart:io';

import '../env/proot_bridge.dart';

/// 记住每个项目根目录最后打开的文件（alpha.34 代码区融合）：
/// 工作台「代码」直达编辑器时自动恢复上次编辑位置；无记录时由
/// EditorPage 回退打开 lib/main.dart（新项目起点）。与 EditorFontPrefs
/// 同模式：filesDir JSON 持久化，全异常静默（体验增强，绝不阻断编辑）。
class EditorLastFile {
  static Future<Map<String, dynamic>> _read() async {
    final env = await ProotBridge().envInfo();
    final f = File('${env.filesDir}/editor-last-file.json');
    if (!await f.exists()) return {};
    final raw = jsonDecode(await f.readAsString());
    return raw is Map<String, dynamic> ? raw : {};
  }

  static Future<void> _write(Map<String, dynamic> m) async {
    final env = await ProotBridge().envInfo();
    final f = File('${env.filesDir}/editor-last-file.json');
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(m));
  }

  /// 项目根（容器路径）→ 上次打开的文件路径；无记录返回 null。
  static Future<String?> get(String projectDir) async {
    try {
      final v = (await _read())[projectDir];
      return v is String && v.isNotEmpty ? v : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> set(String projectDir, String path) async {
    try {
      final m = await _read();
      m[projectDir] = path;
      await _write(m);
    } catch (_) {}
  }
}
