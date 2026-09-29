import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ai/ai_file_watch.dart';
import 'package:foaide/editor/fs_bridge.dart';

/// 可写内存桥：轮询检测要真读一遍"磁盘"，这里用 map 当盘。
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

  group('AiFileWatcher · 只在真的被外部改了时才报告', () {
    test('start 自己读一次盘定基线（不靠调用方喂）', () async {
      final b = _MemBridge()..files[path] = 'disk-v0';
      var hits = 0;
      final w = AiFileWatcher(bridge: b);
      w.onChanged = (_) => hits++;
      await w.start(path: path);
      expect(b.reads, 1, reason: '定基线要读一次');
      await w.pollNow();
      expect(hits, 0, reason: '磁盘没变，别打扰');
      expect(w.active, isTrue);
      w.stop();
    });

    test('磁盘与基线一致 → 不报（AI 还没动，别打扰）', () async {
      final b = _MemBridge()..files[path] = 'same';
      var hits = 0;
      final w = AiFileWatcher(bridge: b);
      w.onChanged = (_) => hits++;
      await w.start(path: path, baseline: 'same');
      await w.pollNow();
      expect(hits, 0);
      expect(w.active, isTrue, reason: '没变化要继续盯着');
      w.stop();
    });

    test('磁盘变了 → 报一次，然后自停（不许弹窗轰炸）', () async {
      final b = _MemBridge()..files[path] = 'v1';
      final got = <String>[];
      final w = AiFileWatcher(bridge: b);
      w.onChanged = got.add;
      await w.start(path: path, baseline: 'v0');
      await w.pollNow();
      expect(got, ['v1']);
      expect(w.active, isFalse, reason: '报过一次就该停');

      // 再改也不报——用户已被告知，想再看有手动重载
      b.files[path] = 'v2';
      await w.pollNow();
      expect(got, ['v1']);
    });

    test('自己保存过（bumpBaseline）→ 不算外部变更', () async {
      final b = _MemBridge()..files[path] = 'mine';
      var hits = 0;
      final w = AiFileWatcher(bridge: b);
      w.onChanged = (_) => hits++;
      await w.start(path: path, baseline: 'old');
      w.bumpBaseline('mine'); // 模拟用户自己保存
      await w.pollNow();
      expect(hits, 0, reason: '自己写的不能报成"远程 AI 改了文件"');
      w.stop();
    });

    test('读失败（文件被删/权限）→ 静默，不误报', () async {
      final b = _MemBridge()..failRead = true;
      var hits = 0;
      final w = AiFileWatcher(bridge: b);
      w.onChanged = (_) => hits++;
      await w.start(path: path, baseline: 'v0');
      await w.pollNow();
      expect(hits, 0);
      w.stop();
    });

    test('stop 之后不再报告（页面已销毁别继续跑）', () async {
      final b = _MemBridge()..files[path] = 'v1';
      var hits = 0;
      final w = AiFileWatcher(bridge: b);
      w.onChanged = (_) => hits++;
      await w.start(path: path, baseline: 'v0');
      w.stop();
      await w.pollNow();
      expect(hits, 0);
      expect(w.active, isFalse);
    });

    test('重复 start 会顶掉上一个（换文件不残留旧监听）', () async {
      final b = _MemBridge()
        ..files['/a.dart'] = 'A-new'
        ..files['/b.dart'] = 'B-new';
      final got = <String>[];
      final w = AiFileWatcher(bridge: b);
      w.onChanged = got.add;
      await w.start(path: '/a.dart', baseline: 'A-old');
      await w.start(path: '/b.dart', baseline: 'B-old');
      await w.pollNow();
      expect(got, ['B-new'], reason: '只该盯最后 start 的那个文件');
    });

    test('默认间隔 2.5s（外部 AI 领活是分钟级，太快没意义）', () {
      expect(AiFileWatcher(bridge: _MemBridge()).interval,
          const Duration(milliseconds: 2500));
    });
  });

  group('AiFileWatcher · 基线语义（alpha.84 回归）', () {
    // 这一组是本轮的真正病灶：拿"编辑器内容"当基线时，用户只要有未保存
    // 改动，首轮就会误报 → 监听自停 → 真改动永远不报。症状是"派活后还
    // 得手动从磁盘重新载入"。
    test('用户的未保存改动 ≠ 外部变更（不许误报）', () async {
      final b = _MemBridge()..files[path] = 'disk-original';
      var hits = 0;
      const editorContent = 'disk-original\n// 我还没保存的新行';
      expect(editorContent, isNot('disk-original'),
          reason: '前提：编辑器脏 = 编辑器内容 ≠ 磁盘内容');
      final w = AiFileWatcher(bridge: b);
      w.onChanged = (_) => hits++;
      await w.start(path: path); // 基线取磁盘，不看编辑器
      await w.pollNow();
      await w.pollNow();
      expect(hits, 0, reason: '磁盘没动过，脏不脏与它无关');
      expect(w.active, isTrue, reason: '关键：监听必须还活着');
      w.stop();
    });

    test('有未保存改动时，外部真改了仍然能报出来', () async {
      final b = _MemBridge()..files[path] = 'disk-original';
      final got = <String>[];
      final w = AiFileWatcher(bridge: b);
      w.onChanged = got.add;
      await w.start(path: path);
      await w.pollNow(); // 用户此刻有未保存改动——旧实现会在这里误报并自停
      expect(got, isEmpty);
      b.files[path] = 'disk-original\n// AI 补的一行';
      await w.pollNow();
      expect(got, ['disk-original\n// AI 补的一行'],
          reason: '这才是修复要保住的：真改动不能被假报警吃掉');
    });

    test('start 时读不到盘 → 不启动（没基线就别盯）', () async {
      final b = _MemBridge(); // 空盘：read 返回 ENOENT
      var hits = 0;
      final w = AiFileWatcher(bridge: b);
      w.onChanged = (_) => hits++;
      await w.start(path: path);
      expect(w.active, isFalse, reason: '没有可信基线就启动，第一轮必然误报——宁可完全不报');
      // 之后文件出现也不该报（没在监听）
      b.files[path] = 'later';
      await w.pollNow();
      expect(hits, 0);
    });

    test('start 前先停旧的：旧监听的文件后续变化不再报', () async {
      final b = _MemBridge()..files['/a.dart'] = 'A0';
      var hits = 0;
      final w = AiFileWatcher(bridge: b);
      w.onChanged = (_) => hits++;
      await w.start(path: '/a.dart');
      b.files['/b.dart'] = 'B0';
      await w.start(path: '/b.dart');
      b.files['/a.dart'] = 'A1'; // 旧文件变了，已经不该管
      await w.pollNow();
      expect(hits, 0, reason: '在盯 /b.dart，/a.dart 的变化与它无关');
      w.stop();
    });

    test('报告后基线推到新值（回调没处理也不连环弹）', () async {
      final b = _MemBridge()..files[path] = 'v1';
      final got = <String>[];
      final w = AiFileWatcher(bridge: b);
      w.onChanged = got.add;
      await w.start(path: path, baseline: 'v0');
      await w.pollNow();
      expect(got, ['v1']);
      // 报过就自停了；即便有人手动重启，基线已是 v1 → 不会把同一版再报一次
      await w.start(path: path);
      await w.pollNow();
      expect(got, ['v1']);
      w.stop();
    });
  });
}
