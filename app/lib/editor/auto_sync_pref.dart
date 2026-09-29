import 'dart:convert';
import 'dart:io';

import '../env/proot_bridge.dart';

/// 「自动同步」开关的持久化（alpha.91）。
///
/// 与 `EditorFontPrefs` / `EditorLastFile` / `HintPrefs` 同一模式：
/// filesDir 下 JSON、全异常静默、读不到就退回默认值。
///
/// ## 默认值是「开」
///
/// 因为这个功能的全部意义就是**"不需要用户手动从磁盘加载覆盖"**——
/// 默认关掉的话，用户得先发现这个开关、再打开，才能得到他要的行为。
/// 而默认开着最坏情况是什么？外部改了文件，编辑器自己更新了。那正是
/// 用户要的。真正的风险场景（本地有未保存改动）已经有 diff 抽屉兜着，
/// 不会被静默覆盖。
///
/// 所以：[load] 在任何不确定的情况下都返回 true。
class AutoSyncPref {
  static const String fileName = 'foa-editor-prefs.json';
  static const String key = 'autoSyncDisk';

  static Future<File> _file() async {
    final env = await ProotBridge().envInfo();
    return File('${env.filesDir}/$fileName');
  }

  /// 读取开关。**任何失败都返回 true**（默认开）。
  static Future<bool> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return true;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return true;
      final v = raw[key];
      return v is bool ? v : true;
    } catch (_) {
      return true; // 读不到 = 没设置过 = 用默认（开）
    }
  }

  /// 保存开关（幂等）。失败静默——持久化不了不该拦住这次操作生效。
  static Future<void> save(bool value) async {
    try {
      final f = await _file();
      Map<String, dynamic> all = {};
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        if (raw is Map) all = Map<String, dynamic>.from(raw);
      }
      all[key] = value;
      await f.parent.create(recursive: true);
      // ⚠️ 读-改-写整体是竞态的（若将来这个文件有别的键、且有并发写入）。
      // 当前只有一个键、只在用户点开关时写，实际不会撞。等真有第二个键
      // 再引入合并锁，别提前上复杂度。
      await f.writeAsString(jsonEncode(all));
    } catch (_) {}
  }
}
