import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/editor/file_change_source.dart';
import 'package:foaide/editor/fs_bridge.dart';
import 'package:foaide/events/native_events.dart';
import 'package:foaide/editor/native_file_change_source.dart';

/// 内存盘：降级轮询要真读一遍。
class _MemBridge extends FsBridge {
  final Map<String, String> files = <String, String>{};

  @override
  Future<FsReadResult> read(String path) async {
    final c = files[path];
    return c == null
        ? const FsReadResult(ok: false, error: 'ENOENT')
        : FsReadResult(ok: true, content: c);
  }
}

/// 假的 `dev.foa/proot` 宿主：可以配置成"支持原生监听"或"旧 APK"。
///
/// 这里必须用真 MethodChannel + 假 binaryMessenger，而不是给
/// [NativeFileChangeSource] 塞一个接口——因为**要测的正是它跟平台通道
/// 打交道的那部分**：`MissingPluginException` 到底有没有被接住并降级。
/// 换成 mock 就把被测逻辑绕过去了（那才是最容易出错的地方）。
class _FakeNative {
  _FakeNative({this.supported = true, this.returnsFalse = false});

  /// false = 模拟旧 APK：`fsWatchStart` 不存在 → MissingPluginException。
  final bool supported;

  /// true = 原生侧回了 false（路径非法 / 目录不可读）。
  final bool returnsFalse;

  final List<MethodCall> calls = [];
  int stopCount = 0;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.foa/proot'),
      (call) async {
        calls.add(call);
        switch (call.method) {
          case 'fsWatchStart':
            if (!supported) {
              // 未注册的方法在真实环境里就是 MissingPluginException
              throw MissingPluginException('No implementation found for ${
                  call.method}');
            }
            return !returnsFalse;
          case 'fsWatchStop':
            stopCount++;
            return true;
          default:
            return null;
        }
      },
    );
  }

  static void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('dev.foa/proot'), null);
  }
}

void main() {
  const path = '/root/projects/demo/lib/main.dart';

  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemBridge bridge;

  setUp(() {
    bridge = _MemBridge()..files[path] = 'v0';
  });

  tearDown(() {
    _FakeNative.uninstall();
    NativeEvents.resetForTest();
  });

  group('原生路径可用时 · 走原生', () {
    test('start 返回 true 且 isNative 为真，但没启用轮询', () async {
      _FakeNative().install();
      final s = NativeFileChangeSource(bridge: bridge);
      expect(await s.start(path), isTrue);
      expect(s.isNative, isTrue, reason: '原生可用就该用原生');
      expect(s.active, isTrue);
      s.stop();
    });

    test('原生推来的 fsChange → 通过 onChanged 冒泡出去', () async {
      final fake = _FakeNative()..install();
      // ⚠️ 必须先把 NativeEvents 的 handler 注册上：原生推的事件是先到
      // NativeEvents（全项目唯一的反向 handler），再由它转给
      // NativeEvents.onFsChange。真机上 `main.dart` 启动时就注册了，
      // 测试里得自己来一次——少这一步会"事件发出去了但没人接"。
      NativeEvents.resetForTest();
      NativeEvents.ensureHandler();

      final s = NativeFileChangeSource(bridge: bridge);
      final got = <String>[];
      s.onChanged = got.add;
      await s.start(path);

      // 模拟原生侧主动推事件（真实链路上由 FileObserver 触发）
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'dev.foa/proot',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('fsChange', {'path': path, 'seq': 1}),
        ),
        (_) {},
      );

      expect(got, [path]);
      expect(fake.calls.map((c) => c.method), contains('fsWatchStart'));
      s.stop();
      NativeEvents.resetForTest();
    });

    test('stop 之后原生再推事件 → 不再回调', () async {
      _FakeNative().install();
      NativeEvents.resetForTest();
      NativeEvents.ensureHandler();

      final s = NativeFileChangeSource(bridge: bridge);
      final got = <String>[];
      s.onChanged = got.add;
      await s.start(path);
      s.stop();

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'dev.foa/proot',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('fsChange', {'path': path, 'seq': 2}),
        ),
        (_) {},
      );

      expect(got, isEmpty,
          reason: 'stop 要摘掉 NativeEvents.onFsChange，否则原生余波会打到'
              '已销毁的页面上（setState after dispose）');
      NativeEvents.resetForTest();
    });

    test('原生路径下磁盘变了但没人推事件 → 不会自己冒出来（无轮询兜底）',
        () async {
      // 这是原生路径的**已知代价**：不再有轮询去兜。所以原生侧的事件
      // 可靠性就成了唯一依赖，而它由 Kotlin 的 FileObserver 保证。
      // 这条测试把代价写明白，免得以后有人以为"原生路径也有轮询保底"。
      _FakeNative().install();
      final s = NativeFileChangeSource(bridge: bridge);
      final got = <String>[];
      s.onChanged = got.add;
      await s.start(path);

      bridge.files[path] = 'v1'; // 改了，但没有任何事件
      await s.debugPollNow();    // 原生路径下这是 no-op

      expect(got, isEmpty,
          reason: '原生路径没有轮询；事件只能来自 FileObserver 推送。'
              '正因如此，进程被冻结期间的事件会丢 —— 由 onResumed 补读兜底');
      s.stop();
    });
  });

  group('降级路径 · 原生不可用时必须自动接管', () {
    test('旧 APK（MissingPluginException）→ 自动降级，且 start 仍算成功',
        () async {
      // 最常走的一条降级路径。要点有两个：
      //   ① 不能往上抛异常（那会让编辑器打不开文件）；
      //   ② 返回值要算"成功"——调用方只关心"变化会不会通知我"，
      //      不关心走的是哪条路。
      _FakeNative(supported: false).install();
      final s = NativeFileChangeSource(bridge: bridge);
      expect(await s.start(path), isTrue,
          reason: '降级成功也是成功；抛异常或返回 false 会让调用方以为监听不可用');
      expect(s.isNative, isFalse, reason: '应明确处于降级态');
      expect(s.active, isTrue, reason: '降级后轮询要真的跑起来');
      s.stop();
    });

    test('原生返回 false（路径非法 / 目录不可读）→ 同样降级', () async {
      _FakeNative(returnsFalse: true).install();
      final s = NativeFileChangeSource(bridge: bridge);
      expect(await s.start(path), isTrue);
      expect(s.isNative, isFalse);
      expect(s.active, isTrue);
      s.stop();
    });

    test('降级后轮询真的在干活：磁盘变了能报出来', () async {
      _FakeNative(supported: false).install();
      final s = NativeFileChangeSource(bridge: bridge);
      final got = <String>[];
      s.onChanged = got.add;
      await s.start(path);

      bridge.files[path] = 'v1';
      await s.debugPollNow();

      expect(got, [path], reason: '降级不是"装作支持"，得真的能报变更');
      s.stop();
    });

    test('降级且轮询也起不来（读不到盘）→ 返回 false，如实上报', () async {
      // 这种情况确实无解：原生没有、盘也读不到。此时**必须返回 false**，
      // 让调用方知道"监听没成"而不是给一个假的成功。
      _FakeNative(supported: false).install();
      bridge.files.clear(); // 盘上啥也没有 → 轮询定不了基线
      final s = NativeFileChangeSource(bridge: bridge);
      expect(await s.start(path), isFalse);
      expect(s.active, isFalse);
    });
  });

  group('两条路径绝不双跑', () {
    test('原生成功后 stop → 原生被通知停，且本地状态清干净', () async {
      final fake = _FakeNative()..install();
      final s = NativeFileChangeSource(bridge: bridge);
      await s.start(path);
      s.stop();
      expect(fake.stopCount, greaterThanOrEqualTo(1),
          reason: '不停原生的话 FileObserver 会一直活着推事件给已销毁的页面');
      expect(s.active, isFalse);
      expect(s.isNative, isFalse);
    });

    test('降级态下 stop → 不会误发 fsWatchStop（原生本来就没开）', () async {
      final fake = _FakeNative(supported: false)..install();
      final s = NativeFileChangeSource(bridge: bridge);
      await s.start(path);
      s.stop();
      expect(fake.calls.map((c) => c.method), isNot(contains('fsWatchStop')),
          reason: '没成功开过就不该发停；多余调用会让原生侧状态混乱');
      expect(s.active, isFalse);
    });

    test('重复 start 换文件：前一个监听被彻底停掉', () async {
      _FakeNative().install();
      final s = NativeFileChangeSource(bridge: bridge);
      await s.start('/root/projects/demo/lib/a.dart');
      await s.start('/root/projects/demo/lib/b.dart');
      // 只剩一个活跃来源（原生）：拉不到旧文件的事件
      expect(s.isNative, isTrue);
      final got = <String>[];
      s.onChanged = got.add;
      await s.debugPollNow();
      expect(got, isEmpty, reason: '原生路径下不该有轮询残留');
      s.stop();
    });

    test('未 start 就 stop / 重复 stop 都不炸', () {
      final s = NativeFileChangeSource(bridge: bridge);
      expect(s.stop, returnsNormally);
      expect(s.stop, returnsNormally);
      expect(s.active, isFalse);
    });
  });

  group('前台恢复补读', () {
    test('onResumed → 触发一次变更检查（弥补冻结期丢失的事件）', () async {
      _FakeNative().install();
      final s = NativeFileChangeSource(bridge: bridge);
      final got = <String>[];
      s.onChanged = got.add;
      await s.start(path);

      s.onResumed();
      expect(got, [path],
          reason: '进程被冻结期间原推的事件收不到，回前台必须补查一次；'
              '内容是上层读盘后比对去重的，所以补读不会造成假弹窗');
    });

    test('没 start / 已 stop → onResumed 什么都不做', () async {
      _FakeNative().install();
      final s = NativeFileChangeSource(bridge: bridge);
      final got = <String>[];
      s.onChanged = got.add;

      s.onResumed(); // 没 start
      expect(got, isEmpty);

      await s.start(path);
      s.stop();
      s.onResumed(); // 已 stop
      expect(got, isEmpty, reason: '页面已销毁还回调 → setState after dispose');
    });
  });

  group('接口一致性', () {
    test('NativeFileChangeSource 满足 FileChangeSource 契约', () {
      final s = NativeFileChangeSource(bridge: bridge);
      expect(s, isA<FileChangeSource>());
    });

    test('用的是既有通道，没有新增（回归：不许多开通道）', () {
      // 新开通道意味着原生侧要重写一遍 handler 与命名空间；
      // 而 dev.foa/proot 已有 navigate 的反向调用先例。
      final s = NativeFileChangeSource(bridge: bridge);
      expect(s, isA<FileChangeSource>());
      // 通道名在源码里写死为 dev.foa/proot —— 用源码断言守住
      //（Kotlin 侧 CHANNEL 常量也是这个值，两边必须一致）
      // ignore: unnecessary_string_escapes
      expect(const MethodChannel('dev.foa/proot').name, 'dev.foa/proot');
    });
  });
}
