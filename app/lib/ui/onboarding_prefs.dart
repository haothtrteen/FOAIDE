import 'dart:convert';
import 'dart:io';

import '../env/proot_bridge.dart';

/// 首次启动引导的已看标记。
///
/// ## 为什么单独一个文件而不是复用 [HintPrefs]
///
/// 两者看着像，语义不同：
/// - `HintPrefs` 记的是**「这条提示弹过了」**——一次性，永不重来。
/// - 本文件记的是**「这一版引导看过了」**——它带版本号，引导内容改版
///   （比如新增了一个要装的组件）时升 [currentVersion]，老用户能再看一次。
///
/// 混在一起的话，"想重弹引导"就得去动提示的已读集合，两边互相牵制。
///
/// ## 设计约定
///
/// 与 `ThemePrefs` / `EditorFontPrefs` / `EditorLastFile` / `HintPrefs` 同模式：
///   - `filesDir` 下 JSON 持久化（**刻意不用 shared_preferences**，
///     理由见 `core/theme.dart` 里 ThemePrefs 那段注释）；
///   - 全异常静默：引导只是体验，绝不能因读写失败把启动拦住；
///   - 读失败一律返回「没看过」——**宁可多弹一次，也别让新用户
///     在一片空白里自己摸索**。这与 `HintPrefs.seen` 的取舍相反
///     （那里读不到返回 true，因为提示不重要），差别是有意的：
///     提示弹多了是骚扰，引导不弹是失职。
class OnboardingPrefs {
  static const String fileName = 'foa-onboarding.json';

  /// 记录当前已看版本的键。
  static const String key = 'seenVersion';

  /// 当前引导版本。
  ///
  /// 改动引导页的**实质内容**（新增要装的组件、安装流程变了）时 +1，
  /// 老用户会在下次启动时重新看到一遍。
  /// 只改文案/配色**不要**动它 —— 那会让所有老用户被无谓地打扰一次。
  ///
  /// 历史：
  /// - `1`：初版（是什么 / 要装什么 / 开始）。
  /// - `2`：第 3 页增「安装 APK」「通知」两项权限。
  ///   这次**必须**升：权限步骤新老用户都缺，而老用户恰恰是最先撞上
  ///   "构建完点安装被系统拦下"的那批人 —— 他们装过工具链，
  ///   按旧逻辑（已装好就跳过引导）永远看不到这一页。
  static const String currentVersion = '2';

  static Future<File> _file() async {
    final env = await ProotBridge().envInfo();
    return File('${env.filesDir}/$fileName');
  }

  /// 读已看版本号；任何异常（文件不存在 / JSON 坏了 / 平台通道失败）
  /// 一律返回 null（= 没看过）。
  static Future<String?> _read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      final v = raw[key];
      return v is String && v.isNotEmpty ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// 这一版引导是否已看过。
  ///
  /// 用「版本号相等」而不是「文件存在」判断：文件在、版本却更旧，
  /// 说明引导改过版，该再给用户看一次。
  static Future<bool> seen() async {
    try {
      return await _read() == currentVersion;
    } catch (_) {
      return false; // 读不到就当没看过，让引导出现
    }
  }

  /// 标记这一版引导已看过（幂等）。
  ///
  /// ⚠️ 必须在用户**真正走完引导**之后调用，不能一进页面就写 ——
  /// 否则用户秒退，下次启动就再也不会看到引导了。
  static Future<void> markSeen() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({key: currentVersion}));
    } catch (_) {}
  }

  /// 清掉标记（设置页「重新查看引导」用）。
  ///
  /// 删文件而不是写空串：`_read` 对空串返回 null，效果一样，
  /// 但删掉之后目录里不留一个语义不明的残留文件。
  static Future<void> reset() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 纯函数：判断某份 JSON 内容是否表示「这一版已看过」。
  ///
  /// 抽出来是为了可测 —— 单测沙箱里没有真实 `ProotBridge().envInfo()`，
  /// IO 路径跑不到，但这段映射逻辑是最容易写错的地方。
  static bool isCurrent(String? storedVersion) =>
      storedVersion != null && storedVersion == currentVersion;
}
