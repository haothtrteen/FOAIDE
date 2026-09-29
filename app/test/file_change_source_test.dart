import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/editor/file_change_source.dart';
import 'package:foaide/editor/fs_bridge.dart';

/// 内存盘：轮询要真读一遍，这里用 map 当磁盘。
class _MemBridge extends FsBridge {
  final Map<String, String> files = <String, String>{};
  bool failRead = false;
  int reads = 0;

  @override
  Future<FsReadResult> read(String path) async {
    reads++;
    if (failRead) return const FsReadResult(ok: false, error: 'EIO');
    final c = files[path];
    return c == null
        ? const FsReadResult(ok: false, error: 'ENOENT')
        : FsReadResult(ok: true, content: c);
  }
}

void main() {
  const path = '/root/projects/demo/lib/main.dart';

  /// 这一组钉的是**与 AiFileWatcher 的语义差别**，也就是本轮改造的理由。
  /// 相同的部分（定基线、读失败静默）另有 ai_file_watch_test 守着，
  /// 但这里仍各留一条，因为这是**另一个类**、独立的防线。
  group('PollingFileChangeSource · 常驻不自停（本轮改造的核心）', () {
    test('外部连改 3 次 → 报 3 次（旧实现只有第 1 次）', () async {
      // 这条是本轮改造最直接的回归：alpha.83 的 AiFileWatcher 在第一次
      // 上报后就 `_reported = true; stop();`，外部 AI 连改多轮只感知得到
      // 第一轮。用户"还是要手动从磁盘重新载入"的体感就来自这里。
      final b = _MemBridge()..files[path] = 'v0';
      final hits = <String>[];
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = hits.add;
      expect(await s.start(path), isTrue);

      for (final v in ['v1', 'v2', 'v3']) {
        b.files[path] = v;
        await s.pollNow();
      }

      expect(hits, [path, path, path], reason: '每一次外部变更都要报，不是只报第一次');
      expect(s.active, isTrue, reason: '关键：报完必须还活着，不许自停');
      s.stop();
    });

    test('回调只给路径，不给内容（避免拿到半截内容去覆盖编辑器）', () async {
      final b = _MemBridge()..files[path] = 'v0';
      final hits = <String>[];
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = hits.add;
      await s.start(path);
      b.files[path] = 'v1';
      await s.pollNow();
      expect(hits, [path],
          reason: '来源只报"哪个文件动了"；内容是订阅者自己读的——'
              '推送型实现可能在文件被写一半时收到事件，那时读出来的内容是残缺的');
      s.stop();
    });

    test('磁盘没变 → 一次都不报', () async {
      final b = _MemBridge()..files[path] = 'same';
      final hits = <String>[];
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = hits.add;
      await s.start(path);
      await s.pollNow();
      await s.pollNow();
      expect(hits, isEmpty);
      expect(s.active, isTrue);
      s.stop();
    });
  });

  group('PollingFileChangeSource · 基线语义（继承 alpha.84 结论）', () {
    test('基线取磁盘，不取编辑器 —— 用户有未保存改动不误报', () async {
      // alpha.84 的病灶：拿编辑器内容当基线时，用户只要有未保存改动，
      // 首轮就 `编辑器内容 ≠ 磁盘` → 误报 → （当时还会自停）→ 真改动
      // 永远收不到。这里确认同一坑没有在新类里重踩。
      final b = _MemBridge()..files[path] = 'disk-original';
      final hits = <String>[];
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = hits.add;
      await s.start(path);
      await s.pollNow();
      await s.pollNow();
      expect(hits, isEmpty, reason: '磁盘没动过，编辑器脏不脏与它无关');
      expect(s.active, isTrue);
      s.stop();
    });

    test('bumpBaseline 后磁盘等于该值 → 不报（自己保存不算外部变更）', () async {
      final b = _MemBridge()..files[path] = 'mine';
      final hits = <String>[];
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = hits.add;
      await s.start(path);
      s.bumpBaseline('mine'); // 模拟用户自己保存
      await s.pollNow();
      expect(hits, isEmpty,
          reason: '不推进基线的话，每次自己保存都会给自己弹一个 diff 预览');
      s.stop();
    });

    test('报告后基线立刻推进：回调抛异常也不会下一轮重复报', () async {
      final b = _MemBridge()..files[path] = 'v1';
      var calls = 0;
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = (_) {
        calls++;
        throw StateError('故意炸一下，模拟订阅者处理失败');
      };
      await s.start(path);
      // 回调抛异常不该把 poll 本身带崩（Timer 里没人接这个错）
      await s.pollNow().catchError((_) {});
      await s.pollNow().catchError((_) {});
      // 第二次 pollNow：基线若没推进，会把 'v1' 再报一次
      expect(calls, lessThanOrEqualTo(1),
          reason: '基线必须在回调**之前**推进，否则回调一失败就重复弹');
      s.stop();
    });
  });

  group('PollingFileChangeSource · 生命周期', () {
    test('start 时读不到盘 → 返回 false（调用方据此降级/不启动）', () async {
      final b = _MemBridge(); // 空盘 → ENOENT
      final s = PollingFileChangeSource(bridge: b);
      expect(await s.start(path), isFalse,
          reason: '没有可信基线就启动，第一轮必然误报——宁可返回 false 让调用方自己决定');
      expect(s.active, isFalse);
    });

    test('stop 之后不再回调，且 active 为 false', () async {
      final b = _MemBridge()..files[path] = 'v0';
      final hits = <String>[];
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = hits.add;
      await s.start(path);
      s.stop();
      b.files[path] = 'v1';
      await s.pollNow();
      expect(hits, isEmpty, reason: '页面已销毁还回调 → setState after dispose');
      expect(s.active, isFalse);
    });

    test('重复 start 换目标：旧文件的变化不再报', () async {
      final b = _MemBridge()
        ..files['/a.dart'] = 'A0'
        ..files['/b.dart'] = 'B0';
      final hits = <String>[];
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = hits.add;
      await s.start('/a.dart');
      await s.start('/b.dart');
      b.files['/a.dart'] = 'A1';
      await s.pollNow();
      expect(hits, isEmpty, reason: '已经在盯 /b.dart，/a.dart 与它无关');

      b.files['/b.dart'] = 'B1';
      await s.pollNow();
      expect(hits, ['/b.dart']);
      s.stop();
    });

    test('读失败（文件被删 / 中间态）→ 静默，基线不动', () async {
      final b = _MemBridge()..files[path] = 'v0';
      final hits = <String>[];
      final s = PollingFileChangeSource(bridge: b);
      s.onChanged = hits.add;
      await s.start(path);
      b.failRead = true;
      await s.pollNow();
      expect(hits, isEmpty);
      // 恢复后内容还是 v0 → 仍然不该报（失败期间没有推进基线）
      b.failRead = false;
      await s.pollNow();
      expect(hits, isEmpty, reason: '读失败不能把基线清空，否则恢复后会误报一次');
      s.stop();
    });

    test('未 start 直接 stop / 重复 stop 都不炸', () {
      final s = PollingFileChangeSource(bridge: _MemBridge());
      expect(s.stop, returnsNormally);
      expect(s.stop, returnsNormally);
      expect(s.active, isFalse);
    });
  });
}
