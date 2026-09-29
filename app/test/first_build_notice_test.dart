import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/first_build_notice.dart';

/// 首次构建提示（alpha.71）
///
/// 为什么要专门测：一次冷构建 20~30 分钟，而日志最初几分钟几乎不动。
/// 没有预告的话用户第一反应是"卡死了"然后杀掉进程 —— 于是永远走不到
/// 第一次成功。这条提示防的就是这一次误判，而它**只弹一次**，写错了
/// 几乎没有第二次机会补救。
///
/// 三条最容易被改坏、且改坏了不会报错的语义：
///   1. 标记只在**成功**后写（失败/取消不写）—— 那时 Gradle 依赖没下完，
///      下一次仍然是冷构建，提前关掉提示就是骗人；
///   2. 提示在**启动之前**弹，不是之后；
///   3. 文案里必须有"后面会变快"的解释，否则用户会以为每次都这么慢
///      而放弃使用。
void main() {
  // ---------------- 纯函数层（IO 跑不到，逻辑仍要守） ----------------

  group('FirstBuildPrefs.parseDone', () {
    test('认 true 与字符串 true', () {
      expect(FirstBuildPrefs.parseDone({'done': true}), isTrue);
      expect(FirstBuildPrefs.parseDone({'done': 'true'}), isTrue,
          reason: '手写调试文件时两种都可能，认一种够用、认两种不亏');
    });

    test('其它一律当没构建过（含文件坏掉 / 字段缺失）', () {
      expect(FirstBuildPrefs.parseDone({'done': false}), isFalse);
      expect(FirstBuildPrefs.parseDone({'done': 'false'}), isFalse);
      expect(FirstBuildPrefs.parseDone(<String, dynamic>{}), isFalse);
      expect(FirstBuildPrefs.parseDone(null), isFalse);
      expect(FirstBuildPrefs.parseDone('true'), isFalse,
          reason: '顶层不是 map（JSON 坏了）不能当成已构建');
      expect(FirstBuildPrefs.parseDone([]), isFalse);
    });
  });

  group('FirstBuildPrefs · 存储约定', () {
    test('文件名与键名唯一（与其它 prefs 不撞车）', () {
      expect(FirstBuildPrefs.fileName, 'foa-first-build.json');
      expect(FirstBuildPrefs.key, 'done');
    });
  });

  // ---------------- 接线（源码文本断言） ----------------

  group('首次构建提示 · 接线', () {
    String src(String path) => File(path).readAsStringSync();

    test('标记只写在构建成功分支（失败/取消不写）', () {
      final s = src('lib/toolchain/build_runner.dart');
      final finish = bodyOf(s, 'Future<void> _finish(int? code)');
      expect(finish.contains('FirstBuildPrefs.markDone'), isTrue,
          reason: '完成标记必须写在唯一的收口处 _finish —— '
              '写在页面上的话，用户中途锁屏切走就漏记了');
      // 关键：必须在 `ok` 判定之后，且被 if 包着
      final i = finish.indexOf('final ok = code == 0');
      expect(i, greaterThanOrEqualTo(0));
      expect(
        finish
            .substring(i)
            .indexOf('if (ok) await FirstBuildPrefs.markDone()'),
        greaterThanOrEqualTo(0),
        reason: '失败与取消不能写标记：那时 Gradle 依赖没下完、daemon 没热，'
            '下次仍是冷构建，提前关掉提示等于骗用户"下次就快了"',
      );
    });

    test('弹窗在点「构建」之后、真正启动之前', () {
      final s = src('lib/toolchain/build_page.dart');
      final start = bodyOf(s, 'Future<void> _startBuild(String name)');
      expect(start.contains('showFirstBuildNotice(context)'), isTrue);
      expect(start.contains('_firstBuildDone'), isTrue,
          reason: '必须受"是否已经构建过"限制，否则每次都弹就成了骚扰');
      expect(
        start.indexOf('showFirstBuildNotice') < start.indexOf('r.start('),
        isTrue,
        reason: '顺序反了就失去意义：等日志挂在那儿不动时再说"这会很慢"，'
            '用户那时已经在找取消按钮了',
      );
      // 用户选取消就别开始
      expect(start.contains('if (go != true) return'), isTrue);
    });

    test('进度面板里有一条常驻提示（弹窗只出现一次，但 30 分钟里用户会回来看）',
        () {
      final s = src('lib/toolchain/build_page.dart');
      // 取到文件尾：_buildProgressPanel 是最后一个方法，
      // 给固定 span 会在方法变长时把新加的片段切在外面（假阴性）。
      final panel = bodyOf(s, 'Widget _buildProgressPanel', span: 1 << 20);
      expect(panel.contains('_firstBuildDone'), isTrue);
      expect(panel.contains('第一次构建通常需要 20~30 分钟'), isTrue,
          reason: '横幅要给出量级，不然"慢"这个词没有参照');
    });

    test('提示文件里同时写了"要等多久"和"为什么后面会快"', () {
      final s = src('lib/toolchain/first_build_notice.dart');
      expect(s.contains('20-30 分钟'), isTrue,
          reason: '用户原话就是这个量级，别改成含糊的"较长时间"');
      expect(s.contains('缓存'), isTrue, reason: '要解释清楚快的那个原因');
      expect(s.contains('常驻'), isTrue, reason: 'daemon 常驻是第二大加速来源');
      expect(s.contains('增量'), isTrue, reason: 'Flutter 产物增量复用');
      expect(s.contains('前台服务会保活'), isTrue,
          reason: '很多用户的第一反应是"那我得一直盯着屏幕吗"');
    });

    test('弹窗不可点外部关闭，但必须留明确的取消出口', () {
      final s = src('lib/toolchain/first_build_notice.dart');
      expect(s.contains('barrierDismissible: false'), isTrue,
          reason: '这不是"随便看看"的信息框，用户必须做决定');
      expect(s.contains("pop(false)"), isTrue,
          reason: '没有取消按钮 + 不可点外部 = 用户被困住');
    });
  });

  // ---------------- 弹窗行为 ----------------

  group('首次构建弹窗 · 交互', () {
    testWidgets('弹出来，点「开始构建」返回 true', (tester) async {
      late Future<bool> fut;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) => TextButton(
              onPressed: () => fut = showFirstBuildNotice(ctx),
              child: const Text('go'),
            )),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('第一次构建会比较慢'), findsOneWidget);
      expect(find.textContaining('20-30 分钟'), findsOneWidget);

      await tester.tap(find.text('开始构建'));
      await tester.pumpAndSettle();
      expect(await fut, isTrue, reason: '确认后必须放行，否则构建永远起不来');
      expect(find.text('第一次构建会比较慢'), findsNothing);
    });

    testWidgets('点「取消」返回 false 且不残留弹窗', (tester) async {
      late Future<bool> fut;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) => TextButton(
              onPressed: () => fut = showFirstBuildNotice(ctx),
              child: const Text('go'),
            )),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await fut, isFalse,
          reason: '取消必须真的能取消 —— 构建页靠这个决定要不要启动');
      expect(find.text('第一次构建会比较慢'), findsNothing);
    });

    testWidgets('文案里同时给出"要等多久"和"后面会快"', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) => TextButton(
              onPressed: () => showFirstBuildNotice(ctx),
              child: const Text('go'),
            )),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      // 只说"慢"会让人以为每次都这样，进而放弃使用
      expect(find.textContaining('1~3 分钟'), findsOneWidget);
      expect(find.textContaining('之后就快了'), findsOneWidget);
    });
  });
}

/// 取 [anchor] 起始、长度 [span] 个字符的源码片段。
String bodyOf(String src, String anchor, {int span = 1200}) {
  final i = src.indexOf(anchor);
  if (i < 0) return '';
  final end = (i + span) > src.length ? src.length : i + span;
  return src.substring(i, end);
}
