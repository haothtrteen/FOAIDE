import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/events/native_events.dart';
import 'package:foaide/toolchain/build_notify.dart';

/// 读源码做断言：接线类纪律最容易在后续重构里被悄悄拆掉，
/// 而"拆掉"不会让任何逻辑测试变红——只能用源码断言守住。
String src(String rel) => File(rel).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 递归收集 lib/ 下所有 dart 文件。
  List<File> libFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  /// 剥掉注释，只留代码。
  ///
  /// ⚠️ 这一步不能省。本仓库的注释里大量出现
  /// “不要再写一次 `setMethodCallHandler`”这类**说明性提及**——
  /// 直接对整份文件做文本匹配，会把注释也当成调用，于是
  /// “提醒后人别犯错”的注释本身把测试搞红。
  /// （我第一版就这么写的，实测 3 条红里有 2 条是注释误伤。）
  ///
  /// 另外注意**先剥注释再匹配**的顺序：反过来会把字符串字面量里的
  /// `//` 当注释起点，切掉半行代码。
  String stripComments(String s) {
    // 块注释（含 /// 文档注释，它们都在 /* */ 之外按行处理）
    s = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    // 行注释：删到行尾
    s = s.replaceAll(RegExp(r'//[^\n]*'), '');
    return s;
  }

  /// 某文件里“真正的代码”中是否出现 [needle]。
  bool codeContains(String rel, String needle) =>
      stripComments(File(rel).readAsStringSync()).contains(needle);

  group('唯一分发器 · 全项目只许有一处 setMethodCallHandler', () {
    test('扫描全 lib/：只有 native_events.dart 真的注册反向 handler', () {
      // 这条是整组测试里最重要的一条。
      //
      // `MethodChannel.setMethodCallHandler` 每通道只有一个，**后注册的
      // 直接覆盖前一个，静默、无日志、编译期无警告**。一旦有人在第二个
      // 文件里再注册一次，navigate 或 fsChange 必然有一个失效，而症状
      // 只是"点了没反应"——这是最难查的一类 bug。
      final offenders = <String>[];
      for (final f in libFiles()) {
        if (f.path.endsWith('events/native_events.dart')) continue;
        if (stripComments(f.readAsStringSync()).contains('setMethodCallHandler')) {
          offenders.add(f.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '这些文件也注册了反向 handler：$offenders。'
            'dev.foa/proot 的 setMethodCallHandler 只允许出现在 '
            'lib/events/native_events.dart —— 重复注册会静默顶掉 '
            'navigate / fsChange 之一。要在别处收事件请用 NativeEvents 的'
            '静态回调字段，不要自己注册 handler。',
      );
    });

    test('BuildNotify 不再自己注册 handler（它已改为转调）', () {
      expect(codeContains('lib/toolchain/build_notify.dart', 'setMethodCallHandler'),
          isFalse,
          reason: 'BuildNotify 曾是唯一注册点，alpha.91 已移交 NativeEvents');
      // 但它仍然要转调，免得别处的旧调用点静默失效
      expect(codeContains('lib/toolchain/build_notify.dart',
              'NativeEvents.ensureHandler()'),
          isTrue);
    });

    test('main.dart 启动时调的是 NativeEvents.ensureHandler', () {
      expect(codeContains('lib/main.dart', 'NativeEvents.ensureHandler()'), isTrue,
          reason: '不注册的话所有反向调用（点通知导航 + 文件变更）都收不到');
      expect(codeContains('lib/main.dart', 'BuildNotify.ensureHandler()'), isFalse,
          reason: '旧入口已废弃，别回潮');
    });

    test('ensureHandler 幂等：连调两次不炸', () {
      NativeEvents.resetForTest();
      expect(NativeEvents.ensureHandler, returnsNormally);
      expect(NativeEvents.ensureHandler, returnsNormally);
      NativeEvents.resetForTest();
    });
  });

  group('反向方法名命名空间 · 登记制', () {
    test('登记表与正向方法名不冲突（启动期自检）', () {
      // 反向方法名是一个"无编译期保护的全局命名空间"：Kotlin 侧
      // invoke 一个 Dart 未注册的方法 → 静默丢弃，不报错。
      // 所以名字冲突必须能在开发期被查出来，而不是等真机上"点了没反应"。
      expect(NativeEvents.assertNoCollision, returnsNormally);
    });

    test('两个反向方法名是两个不同的常量，且都非空', () {
      expect(NativeEvents.kNavigateMethod, 'navigate');
      expect(NativeEvents.kFsChangeMethod, 'fsChange');
      expect(NativeEvents.kNavigateMethod,
          isNot(NativeEvents.kFsChangeMethod),
          reason: 'switch 分支要靠它们区分，撞了就是同一个 case');
    });

    test('Kotlin 侧确实存在这两个反向方法的 invoke 点（源码扫描）', () {
      // 项目惯例：Kotlin 零测试，用源码扫描代替。
      // 守的是"Dart 侧等一个永远不会来的事件"这种哑巴亏。
      final kt = src('android/app/src/main/kotlin/dev/foa/'
          'flutter_on_android/MainActivity.kt');

      // 不把 `invokeMethod("navigate"` 当一个整串来匹配：Kotlin 里参数多了
      // 之后会被格式化换行（`invokeMethod(\n  "fsChange",\n  ...`），
      // 那样断言就会因为**排版变化**而红——测的是"有没有这个调用"，
      // 不是"怎么换行"。所以拆成两步：附近有 invokeMethod，且有该名字字面量。
      for (final name in [
        NativeEvents.kNavigateMethod,
        NativeEvents.kFsChangeMethod,
      ]) {
        expect(kt, contains('invokeMethod'),
            reason: 'Kotlin 侧必须能反向推事件');
        expect(kt, contains('"$name"'),
            reason: 'Kotlin 侧没有 invoke 过 "$name" —— Dart 侧会永远等一个'
                '不会来的事件。反向方法名是**无编译期保护的全局命名空间**，'
                '两边名字对不上不会有任何报错');
      }
    });

    test('Kotlin 侧注册了两个正向方法 fsWatchStart / fsWatchStop', () {
      // 反向推事件的前提是 Dart 能先让原生"开始盯"。这两个方法是正向
      //（Dart → Native），Kotlin 侧用 `"名字" ->` 的分支形式注册。
      final kt = src('android/app/src/main/kotlin/dev/foa/'
          'flutter_on_android/MainActivity.kt');
      for (final m in ['fsWatchStart', 'fsWatchStop']) {
        expect(kt, contains('"$m" ->'),
            reason: '$m 没有在 when 分支里注册 —— 调用会走到 notImplemented()');
      }
    });

    test('两边的参数 key 一致：path（不是 filePath / guestPath）', () {
      // 参数名对不上是这类跨语言接线的经典翻车点：Kotlin 用
      // `call.argument<String>("path")`，Dart 发 `{'filePath': ...}`，
      // 结果拿到 null → 空路径 → 静默不监听。**不会抛异常**。
      final kt = src('android/app/src/main/kotlin/dev/foa/'
          'flutter_on_android/MainActivity.kt');
      expect(kt, contains('call.argument<String>("path")'),
          reason: 'fsWatchStart 要从 "path" 取值；Dart 侧发的也必须是 "path"');
    });
  });

  group('NativeEvents · 事件路由', () {
    /// 直接驱动 handler 的辅助：绕过真实平台通道，把一条调用喂进去。
    ///
    /// 用 `TestDefaultBinaryMessengerBinding` 从**平台侧**发消息——
    /// 这样走的是和真机完全相同的路径（handler 注册、参数编解码都真跑），
    /// 只有"消息从哪来"这一点是模拟的。
    Future<void> feed(String method, Object? args) async {
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'dev.foa/proot',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
    }

    tearDown(NativeEvents.resetForTest);

    testWidgets('fsChange 带 path → 回调收到该路径', (tester) async {
      NativeEvents.resetForTest();
      NativeEvents.ensureHandler();
      final got = <String>[];
      NativeEvents.onFsChange = got.add;

      await feed(
          NativeEvents.kFsChangeMethod, {'path': '/root/p/lib/a.dart', 'seq': 1});
      await tester.pump();

      expect(got, ['/root/p/lib/a.dart']);
    });

    testWidgets('fsChange 缺 path / path 类型不对 → 静默忽略，不抛异常',
        (tester) async {
      NativeEvents.resetForTest();
      NativeEvents.ensureHandler();
      final got = <String>[];
      NativeEvents.onFsChange = got.add;

      // handler 里抛异常会让**同一个 handler 的后续所有事件**都收不到，
      // 用一个小功能的缺失换掉整个反向通道，代价完全不成比例。
      await feed(NativeEvents.kFsChangeMethod, <String, Object?>{});
      await feed(NativeEvents.kFsChangeMethod, <String, Object?>{'path': 42});
      await feed(NativeEvents.kFsChangeMethod, null);
      await tester.pump();

      expect(got, isEmpty);
      // 关键：通道还活着，后续正常事件仍能到达
      await feed(
          NativeEvents.kFsChangeMethod, <String, Object?>{'path': '/ok.dart'});
      await tester.pump();
      expect(got, ['/ok.dart'], reason: '前面几条坏消息不该把后面的好消息一起带走');
    });

    testWidgets('navigate 仍能触发 onNavigate（回归：别被 fsChange 顶掉）',
        (tester) async {
      // 这条守的是本组最核心的担忧：新增 fsChange 之后，
      // 点通知回构建页还灵不灵。
      NativeEvents.resetForTest();
      NativeEvents.ensureHandler();
      var nav = 0;
      final fs = <String>[];
      BuildNotify.onNavigate = () => nav++;
      NativeEvents.onFsChange = fs.add;

      await feed(NativeEvents.kNavigateMethod, null);
      await feed(
          NativeEvents.kFsChangeMethod, <String, Object?>{'path': '/x.dart'});
      await tester.pump();

      expect(nav, 1, reason: '两个反向方法必须共存在同一个 handler 下');
      expect(fs, ['/x.dart']);
    });

    testWidgets('未登记的方法 → 静默忽略（原生可能比 Dart 新）', (tester) async {
      NativeEvents.resetForTest();
      NativeEvents.ensureHandler();
      var nav = 0;
      BuildNotify.onNavigate = () => nav++;

      await feed('someFutureEventWeDoNotKnow', {'x': 1});
      await tester.pump();
      expect(nav, 0);

      // 通道仍然可用
      await feed(NativeEvents.kNavigateMethod, null);
      await tester.pump();
      expect(nav, 1);
    });

    testWidgets('没注册回调时收到事件也不炸', (tester) async {
      NativeEvents.resetForTest();
      NativeEvents.ensureHandler();
      // 不设 onFsChange / onNavigate
      await feed(
          NativeEvents.kFsChangeMethod, <String, Object?>{'path': '/a.dart'});
      await feed(NativeEvents.kNavigateMethod, null);
      await tester.pump();
      // 到这里没抛异常就算过
    });
  });
}
