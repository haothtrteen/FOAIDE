import 'dart:convert';
import 'dart:io';

import '../env/proot_bridge.dart';

/// 一次性提示的已读标记（Bug 431）。
///
/// 背景：编辑器的字号调节其实一直可用（状态栏的 A-/A+ 与双指捏合），
/// 但用户反馈「只有一个手指不动、另一个手指动才能缩放，这得单独出教程」
/// ——说明功能**存在但发现不了**。与其写一篇用户不会去读的教程，
/// 不如在首次进入时给一条 8 秒的提示，把它变成「自己看得见的功能」。
///
/// 设计约定（与 EditorFontPrefs / EditorLastFile 同模式）：
///   - filesDir 下 JSON 持久化，键为提示 id；
///   - 全异常静默：这只是体验增强，绝不能因读写失败影响编辑；
///   - 「标记已读」必须在**展示之后**立刻写入，避免用户秒退时又弹一次。
class HintPrefs {
  static const String fileName = 'foa-hints.json';

  /// 编辑器字号提示（只弹一次）。
  static const String editorFont = 'editor_font_scale';

  static Future<File> _file() async {
    final env = await ProotBridge().envInfo();
    return File('${env.filesDir}/$fileName');
  }

  static Future<Set<String>> _read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return <String>{};
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return <String>{};
      final list = raw['seen'];
      if (list is! List) return <String>{};
      return list.whereType<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  /// 该提示是否已展示过。
  static Future<bool> seen(String id) async {
    try {
      return (await _read()).contains(id);
    } catch (_) {
      return true; // 读不到就别打扰用户
    }
  }

  /// 标记为已展示（幂等）。
  static Future<void> markSeen(String id) async {
    try {
      final s = await _read();
      if (!s.add(id)) return;
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({'seen': s.toList()}));
    } catch (_) {}
  }
}
