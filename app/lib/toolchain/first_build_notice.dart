import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../env/proot_bridge.dart';

/// 「第一次构建很慢」的提示：已提示标记 + 弹窗。
///
/// ## 为什么要专门提示
///
/// 一次冷构建要 20~30 分钟，而日志在最初几分钟里几乎不动（Gradle 在拉
/// 依赖）。没有预告的话，用户的第一反应是"卡死了"，然后杀掉进程 ——
/// 于是永远走不到第一次成功。这个提示防的就是这一次误判。
///
/// ## 标记什么时候写
///
/// **只在构建真正成功之后写**（[FirstBuildPrefs.markDone]），
/// 不在"提示弹过"时写，也不在构建启动时写。理由：
///
/// - 失败的构建没跑完冷启动流程（依赖没下完、daemon 没热起来），
///   下一次**依然会是冷构建**。此时把提示关掉，等于骗他"下次就快了"。
/// - 用户主动取消同理：他连产物都没拿到。
///
/// 代价是"第一次构建失败 → 重试时还会再弹一次"。这是**正确的啰嗦** ——
/// 那一刻它说的仍然就是事实。
///
/// ## 为什么自己存 JSON 而不是用 shared_preferences
///
/// 与 `ThemePrefs` / `OnboardingPrefs` / `HintPrefs` 同一套约定：
/// 本项目刻意不引 `shared_preferences` / `path_provider`，`filesDir` 一律
/// 从 `ProotBridge().envInfo()` 取（理由见 `core/theme.dart` 那段注释）。
class FirstBuildPrefs {
  static const String fileName = 'foa-first-build.json';

  /// 是否已完成过一次构建。
  static const String key = 'done';

  static Future<File> _file() async {
    final env = await ProotBridge().envInfo();
    return File('${env.filesDir}/$fileName');
  }

  /// 这台设备上是否已经成功构建过至少一次。
  ///
  /// 全异常静默、读不到就返回 **false**（= 还没构建过）。
  /// 与 `OnboardingPrefs` 同向：宁可多提示一次，也别漏掉那唯一一次
  /// 真正需要它的时候。提示文案里也写了"可以退到后台"，多弹一次的
  /// 代价很低。
  static Future<bool> done() async {
    try {
      final f = await _file();
      if (!await f.exists()) return false;
      return parseDone(jsonDecode(await f.readAsString()));
    } catch (_) {
      return false;
    }
  }

  /// 纯函数：判断某份 JSON 内容是否表示「已构建过」。
  ///
  /// 抽出来是为了可测 —— 单测沙箱里没有真实 `ProotBridge().envInfo()`，
  /// IO 路径跑不到，但这层映射是最容易写错的地方。
  ///
  /// 同时接受 `true`（bool）与 `'true'`（字符串）：手写调试文件时
  /// 两种都可能出现，认一种就够了，认两种花不了三行。
  static bool parseDone(Object? raw) {
    if (raw is! Map<String, dynamic>) return false;
    final v = raw[key];
    return v == true || v == 'true';
  }

  /// 标记已经成功构建过一次（幂等）。
  ///
  /// 调用点在 `BuildRunner._finish` —— 那是唯一的"构建结束"判定处，
  /// 且不在任何页面上，用户中途切走/锁屏也不会漏记。
  static Future<void> markDone() async {
    try {
      final f = await _file();
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({key: true}));
    } catch (_) {
      // 记不上不影响任何功能，最多是下次再提示一次。
    }
  }

  /// 清掉标记（设置页「重新查看提示」／调试用）。
  static Future<void> reset() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 首次构建前的说明弹窗。返回 `true` = 用户确认继续构建。
///
/// ## 为什么是弹窗而不是页面里的一行小字
///
/// 构建页进度面板里本来就有一句"首次 15~30 分钟"，字号 11、灰色斜体，
/// 夹在计时器右边 —— 实测等于没有：用户点「构建」那一刻根本不看那里，
/// 而那正是他唯一需要这条信息的时候。**在动作发生的那一刻拦一次**，
/// 比把信息摆在旁边有效得多。
///
/// 只拦一次（[FirstBuildPrefs.done] 之后不再出现），所以不构成骚扰。
Future<bool> showFirstBuildNotice(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    // 不可点外部关闭：这不是一个"随便看看"的信息框，用户必须做决定。
    // 但提供明确的「取消」，不存在出不去的情况。
    barrierDismissible: false,
    builder: (ctx) => const _FirstBuildDialog(),
  );
  return r == true;
}

class _FirstBuildDialog extends StatelessWidget {
  const _FirstBuildDialog();

  @override
  Widget build(BuildContext context) {
    final c = FoaColors.of(context);
    return AlertDialog(
      title: const Text('第一次构建会比较慢'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '第一次构建编译打包较慢，可能需要 20-30 分钟，请耐心等待。',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: c.danger,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '慢在三件事上，而且都只发生在第一次：',
              style: TextStyle(fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 6),
            _bullet('Gradle 首次启动要下载插件依赖（几百 MB），'
                '下完会留在 ~/.gradle 缓存里'),
            _bullet('Flutter 要为本机生成 AOT 编译产物并预热引擎'),
            _bullet('Gradle 后台进程冷启动'),
            const SizedBox(height: 12),
            const Text(
              '之后就快了：同一个项目再构建通常 1~3 分钟 —— 依赖已在缓存、'
              '后台进程常驻、Flutter 产物可以增量复用。新建项目也会比第一次'
              '快，因为大部分依赖已经缓存过了。',
              style: TextStyle(fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 12),
            Text(
              '构建期间可以退到桌面或锁屏，前台服务会保活，通知栏能看到进度。',
              style: TextStyle(fontSize: 12, height: 1.5, color: c.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('开始构建'),
        ),
      ],
    );
  }

  Widget _bullet(String s) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Icon(Icons.circle, size: 4),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(s, style: const TextStyle(fontSize: 12, height: 1.45)),
            ),
          ],
        ),
      );
}
