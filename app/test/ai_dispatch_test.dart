import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ai/mcp_dispatch.dart';
import 'package:foaide/editor/fs_bridge.dart';

/// 内存版 FsBridge：派活逻辑值得真跑一遍落盘与索引合并，
/// 但不必（也无法在测试里）碰真实文件系统与 MethodChannel。
class _MemBridge extends FsBridge {
  final Map<String, String> files = <String, String>{};
  final Set<String> failWrite = <String>{};

  @override
  Future<FsReadResult> read(String path) async {
    final c = files[path];
    return c == null
        ? const FsReadResult(ok: false, error: 'ENOENT')
        : FsReadResult(ok: true, content: c);
  }

  @override
  Future<FsResult> write(String path, String content) async {
    if (failWrite.contains(path)) {
      return const FsResult(ok: false, error: 'EACCES');
    }
    files[path] = content;
    return const FsResult(ok: true);
  }
}

void main() {
  const root = '/root/projects/demo';
  final when = DateTime(2026, 9, 25, 16, 3, 7);

  group('派活 · 作业 Markdown', () {
    test('含文件 / 光标 / 要求 / 上下文，且指明交付方式', () {
      final md = buildJobMarkdown(
        file: 'lib/main.dart',
        cursor: 42,
        kindName: 'instruct',
        instruction: '把这段改成异步',
        contextSnippet: 'void main() {}',
        stamp: '2026-09-25 16:03:07',
      );
      expect(md, contains('lib/main.dart'));
      expect(md, contains('42'));
      expect(md, contains('把这段改成异步'));
      expect(md, contains('void main() {}'));
      // 最关键的一句：告诉外部 AI 直接改写同一个文件
      expect(md, contains('write_file'));
      expect(md, contains('status: done'));
    });

    test('要求为空时写"（无附加要求）"，不留空段落', () {
      final md = buildJobMarkdown(
        file: 'a.dart',
        cursor: 0,
        kindName: 'complete',
        instruction: '   \n  ',
        contextSnippet: 'x',
        stamp: 's',
      );
      expect(md, contains('（无附加要求）'));
    });

    test('上下文用围栏包住（避免 Markdown 把代码吞掉）', () {
      final md = buildJobMarkdown(
        file: 'a.dart',
        cursor: 0,
        kindName: 'complete',
        instruction: '',
        contextSnippet: 'final a = 1;',
        stamp: 's',
      );
      expect(md, contains('```\nfinal a = 1;\n```'));
    });
  });

  group('派活 · 收件箱索引', () {
    test('一行含时间 / 类型 / 文件 / 作业相对路径', () {
      final line = buildInboxLine(
        jobRelPath: '.foa/ai-jobs/1-instruct.md',
        kindName: 'instruct',
        file: 'lib/main.dart',
        stamp: '2026-09-25 16:03:07',
      );
      expect(line, contains('2026-09-25 16:03:07'));
      expect(line, contains('instruct'));
      expect(line, contains('lib/main.dart'));
      expect(line, contains('.foa/ai-jobs/1-instruct.md'));
    });
  });

  group('派活 · dispatchJob 落盘', () {
    test('作业落在 .foa/ai-jobs 下，文件名带时间戳与类型', () async {
      final b = _MemBridge();
      final r = await dispatchJob(
        bridge: b,
        projectRoot: root,
        file: 'lib/main.dart',
        cursor: 7,
        kindName: 'instruct',
        instruction: '补个注释',
        contextSnippet: 'void main() {}',
        now: when,
      );
      expect(r.ok, isTrue);
      expect(r.error, isNull);
      expect(r.jobPath,
          '$root/.foa/ai-jobs/${when.millisecondsSinceEpoch}-instruct.md');
      expect(b.files.containsKey(r.jobPath), isTrue);
      expect(r.inboxPath, '$root/.foa/ai-inbox.md');
    });

    test('首次投递会建收件箱表头，且索引指向刚写的作业', () async {
      final b = _MemBridge();
      final r = await dispatchJob(
        bridge: b,
        projectRoot: root,
        file: 'lib/main.dart',
        cursor: 7,
        kindName: 'instruct',
        instruction: '补个注释',
        contextSnippet: 'void main() {}',
        now: when,
      );
      final inbox = b.files[r.inboxPath]!;
      expect(inbox, contains('AI 作业收件箱'));
      expect(inbox,
          contains('.foa/ai-jobs/${when.millisecondsSinceEpoch}-instruct.md'));
      // 表头与索引之间不能糊成一坨
      expect(inbox.trim().split('\n').last, startsWith('- ['));
    });

    test('第二次投递是追加，不覆盖已有条目', () async {
      final b = _MemBridge();
      final first = await dispatchJob(
        bridge: b,
        projectRoot: root,
        file: 'a.dart',
        cursor: 1,
        kindName: 'complete',
        instruction: '',
        contextSnippet: 'a',
        now: when,
      );
      final second = await dispatchJob(
        bridge: b,
        projectRoot: root,
        file: 'b.dart',
        cursor: 2,
        kindName: 'instruct',
        instruction: '改',
        contextSnippet: 'b',
        now: when.add(const Duration(seconds: 1)),
      );
      final inbox = b.files[first.inboxPath]!;
      expect(inbox, contains('a.dart'));
      expect(inbox, contains('b.dart'));
      expect(second.ok, isTrue);
      expect(
        b.files.keys.where((k) => k.contains('ai-jobs')).length,
        2,
        reason: '两次作业各占一个文件',
      );
    });

    test('作业写失败 → ok=false 且带错误（不抛）', () async {
      final b = _MemBridge()
        ..failWrite.add(
            '$root/.foa/ai-jobs/${when.millisecondsSinceEpoch}-instruct.md');
      final r = await dispatchJob(
        bridge: b,
        projectRoot: root,
        file: 'a.dart',
        cursor: 1,
        kindName: 'instruct',
        instruction: 'x',
        contextSnippet: 'a',
        now: when,
      );
      expect(r.ok, isFalse);
      expect(r.error, isNotNull);
      // 作业都没落盘，就不该声称投递成功
      expect(b.files.containsKey(r.inboxPath), isFalse);
    });

    test('索引写失败 → 仍报 ok（作业已落盘），但如实带出错误', () async {
      final b = _MemBridge()..failWrite.add('$root/.foa/ai-inbox.md');
      final r = await dispatchJob(
        bridge: b,
        projectRoot: root,
        file: 'a.dart',
        cursor: 1,
        kindName: 'instruct',
        instruction: 'x',
        contextSnippet: 'a',
        now: when,
      );
      expect(r.ok, isTrue, reason: '作业本身写成功了，不该报失败');
      expect(r.error, contains('收件箱'));
      expect(b.files.containsKey(r.jobPath), isTrue);
    });

    test('已有收件箱内容是"无尾换行"时也不会把索引粘在上一行', () async {
      final b = _MemBridge();
      b.files['$root/.foa/ai-inbox.md'] = '# inbox\n\n- [old] 老作业';
      await dispatchJob(
        bridge: b,
        projectRoot: root,
        file: 'a.dart',
        cursor: 1,
        kindName: 'complete',
        instruction: '',
        contextSnippet: 'a',
        now: when,
      );
      final lines = b.files['$root/.foa/ai-inbox.md']!.split('\n');
      expect(lines.where((l) => l.startsWith('- [')).length, 2);
      expect(lines.any((l) => l.startsWith('- [old] 老作业-')), isFalse,
          reason: '索引必须落在独立一行');
    });
  });
}
