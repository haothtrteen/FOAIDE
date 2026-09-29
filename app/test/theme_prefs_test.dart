import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/core/theme.dart';

/// alpha.69：主题默认「跟随系统」+ 用户选择持久化。
///
/// 这组测试守两件**走偏了会造成实质伤害**的事：
///
/// 1. **默认值必须是 `system`**。此前是硬编码 `dark` —— 系统明明是浅色，
///    装完打开却是一片深色，用户得自己找一遍设置才能改对。这是一条
///    很容易在重构里被"顺手改回去"的约定（`ThemeMode.dark` 看着更"稳妥"），
///    所以钉住。
///
/// 2. **持久化必须容错**。主题偏好读不到时只能回默认值，绝不能因为
///    一个 JSON 损坏就把启动拦住。`theme.json` 是用户可见可编辑的文件
///    （在 filesDir 下），被写坏是完全可能的。
///
/// 单测跑在沙箱里没有真实的 `ProotBridge().envInfo()`，所以涉及 IO 的部分
/// 只覆盖**纯函数映射**与**无 IO 的构造语义**；真实文件读写由
/// `bug457` / `bug464` 那两组跨 Dart↔Kotlin↔XML 的契约测试与真机验证兜。
void main() {
  group('alpha.69 · ThemeController 默认值', () {
    test('默认跟随系统，不是硬编码深色', () {
      final tc = ThemeController();
      expect(tc.mode, ThemeMode.system,
          reason: '硬编码 dark 会让浅色系统上的首次启动观感完全错位');
      tc.dispose();
    });

    test('设置值与当前值相同时不通知（避免无谓重建）', () {
      final tc = ThemeController();
      var notified = 0;
      tc.addListener(() => notified++);

      tc.mode = ThemeMode.system; // 与默认值相同
      expect(notified, 0, reason: '值没变就 notify 会造成整树重建');

      tc.mode = ThemeMode.light;
      expect(notified, 1);

      tc.mode = ThemeMode.light; // 重复设同一个值
      expect(notified, 1, reason: '重复设置不该再通知');
      tc.dispose();
    });

    test('dispose 之后再 load 不抛（异步补齐可能晚于页面销毁）', () async {
      final tc = ThemeController();
      tc.dispose();
      // 沙箱里 envInfo 会失败 → ThemePrefs.load 静默回 fallback
      // → 与当前值相同 → 提前 return。即便走到 notify 分支，
      // _disposed 守卫也必须挡住。
      await expectLater(tc.load(), completes);
    });
  });

  group('alpha.69 · ThemePrefs 编解码契约', () {
    test('三态编码是稳定字符串，不依赖 Dart 的 toString', () {
      // 用 toString 的话，枚举改名或 Flutter 升级都可能悄悄换掉字面量，
      // 读回来就成了未知值 → 用户设置静默丢失。
      expect(ThemePrefs.encode(ThemeMode.system), 'system');
      expect(ThemePrefs.encode(ThemeMode.light), 'light');
      expect(ThemePrefs.encode(ThemeMode.dark), 'dark');
    });

    test('编解码 round-trip 一致', () {
      for (final m in ThemeMode.values) {
        expect(ThemePrefs.decode(ThemePrefs.encode(m)), m,
            reason: '$m 存取一轮后必须还是它自己');
      }
    });

    test('默认值是跟随系统', () {
      expect(ThemePrefs.fallback, ThemeMode.system);
    });

    test('未知串 / null / 空 / 大小写不符 一律回默认值', () {
      // 这些都是真实可能出现在 theme.json 里的内容：
      // 用户手改、旧版本写的、或被截断的。
      for (final bad in <String?>[
        null,
        '',
        'System',
        'SYSTEM',
        'auto',
        'ThemeMode.dark', // Dart 的 toString 形式（曾经考虑过的写法）
        '深色',
      ]) {
        expect(ThemePrefs.decode(bad), ThemeMode.system,
            reason: '非法值 "$bad" 必须回默认，不能崩也不能乱猜');
      }
    });

    test('文件名与键名固定（改了等于让老用户设置失效）', () {
      expect(ThemePrefs.fileName, 'theme.json');
      expect(ThemePrefs.key, 'mode');
    });
  });

  group('alpha.69 · 与既有主题常量不冲突', () {
    test('FoaTheme.light() 与 dark() 仍在（ThemeMode 走它们）', () {
      // ThemeMode.system 会让 MaterialApp 按 platformBrightness 选
      // theme / darkTheme 之一，两个都得在，且亮度对得上。
      expect(FoaTheme.light().brightness, Brightness.light);
      expect(FoaTheme.dark().brightness, Brightness.dark);
    });

    test('main.dart 用 ThemeMode 驱动 MaterialApp（不是写死 theme）', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src.contains('themeMode: tc.mode'), isTrue,
          reason: '写死 theme: 会让"跟随系统"失效');
      expect(src.contains('theme: FoaTheme.light()'), isTrue);
      expect(src.contains('darkTheme: FoaTheme.dark()'), isTrue);
      expect(src.contains('ThemeController()..load()'), isTrue,
          reason: '不调 load() 的话持久化等于没有');
    });
  });
}
