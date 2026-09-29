import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ai/ai_inbox_view.dart';
import 'package:foaide/ai/mcp_dispatch.dart';
import 'package:foaide/editor/fs_bridge.dart';

/// 内存盘：list 支持子目录，用来喂 loadAiInbox。
class _MemBridge extends FsBridge {
  final Map<String, String> files = <String, String>{};
  bool failJobsDir = false;

  @override
  Future<FsListResult> list(String path) async {
    if (failJobsDir) {
      return const FsListResult(ok: false, error: 'EACCES');
    }
    final prefix = '$path/';
    final entries = <FsEntry>[];
    for (final k in files.keys) {
      if (!k.startsWith(prefix)) continue;
      final rest = k.substring(prefix.length);
      if (rest.contains('/')) continue; // 只看本层
      entries.add(FsEntry(name: rest, isDir: false, size: files[k]!.length));
    }
    return FsListResult(ok: true, entries: entries);
  }

  @override
  Future<FsReadResult> read(String path) async {
    final c = files[path];
    return c == null
        ? const FsReadResult(ok: false, error: 'ENOENT')
        : FsReadResult(ok: true, content: c);
  }
}

void main() {
  const root = '/root/projects/demo';

  group('parseJobFileName · 宽容解析（诊断信息不该因脏文件名整个挂掉）', () {
    test('标准名：毫秒时间戳-类型.md', () {
      final t = DateTime(2026, 9, 26, 10, 30, 5);
      final p = parseJobFileName('${t.millisecondsSinceEpoch}-complete.md');
      expect(p.kindName, 'complete');
      expect(p.createdAt, t);
    });

    test('instruct 类型', () {
      final p = parseJobFileName('1758800000000-instruct.md');
      expect(p.kindName, 'instruct');
      expect(p.createdAt, isNotNull);
    });

    test('没有时间戳前缀 → createdAt 为 null，类型照留', () {
      final p = parseJobFileName('note.md');
      expect(p.createdAt, isNull);
      expect(p.kindName, 'note');
    });

    test('时间戳不是数字 → createdAt 为 null 而不抛异常', () {
      final p = parseJobFileName('abc-complete.md');
      expect(p.createdAt, isNull);
      expect(p.kindName, 'complete');
    });

    test('没有 .md 后缀也能解析', () {
      expect(parseJobFileName('1758800000000-complete').kindName, 'complete');
    });
  });

  group('jobMarkedDone · 回执识别要宽松', () {
    test('行首纯 status: done', () {
      expect(jobMarkedDone('status: done'), isTrue);
    });

    test('带列表符号 / 缩进 / 大小写差异都算', () {
      expect(jobMarkedDone('- status: done'), isTrue);
      expect(jobMarkedDone('  *   Status :  DONE  '), isTrue);
    });

    test('夹在正文中（前面有别的行）也要认出来', () {
      expect(jobMarkedDone('# 作业\n\n- 文件：`a.dart`\nstatus: done\n'), isTrue);
    });

    test('status: pending / 提到 done 但不是回执行 → 不算', () {
      expect(jobMarkedDone('status: pending'), isFalse);
      expect(jobMarkedDone('完成后追加一行 status: done 便于回看'), isFalse,
          reason: '这是作业模板里的说明文字，不能被当成回执');
      expect(jobMarkedDone(''), isFalse);
    });
  });

  group('loadAiInbox · 快照语义', () {
    test('从没派过活：不报错，只是空（目录不存在是正常情况）', () async {
      final b = _MemBridge();
      final s = await loadAiInbox(bridge: b, projectRoot: root);
      expect(s.jobs, isEmpty);
      expect(s.isEmpty, isTrue);
      expect(s.error, isNull, reason: '没派过活不是错误');
    });

    test('列出作业，新的在前（用户最关心刚派的那条）', () async {
      final b = _MemBridge();
      // 时间戳故意用变长数字（100 / 200 / 300 与真实毫秒数同为"数字"，
      // 但注意 900 vs 3000 —— 字符串倒序会把 900 顶到最前，必须按数值排）
      b.files['$root/$kAiJobsDir/1758800000100-complete.md'] = 'status: done';
      b.files['$root/$kAiJobsDir/1758800000300-instruct.md'] = '（没回执）';
      b.files['$root/$kAiJobsDir/1758800000200-complete.md'] = 'status: done';
      final s = await loadAiInbox(bridge: b, projectRoot: root);
      expect(s.jobs.map((j) => j.name).toList(), [
        '1758800000300-instruct.md',
        '1758800000200-complete.md',
        '1758800000100-complete.md'
      ]);
    });

    test('时间戳长度不等时仍按数值倒序（900 不能排到 3000 前面）', () async {
      final b = _MemBridge();
      b.files['$root/$kAiJobsDir/900-complete.md'] = '';
      b.files['$root/$kAiJobsDir/3000-complete.md'] = '';
      final s = await loadAiInbox(bridge: b, projectRoot: root);
      expect(s.jobs.map((j) => j.name).toList(),
          ['3000-complete.md', '900-complete.md'],
          reason: '字符串倒序会给出相反结果，这是真实踩过的坑');
    });

    test('解析不出时间戳的排最后（连时间都不知道，不该插队）', () async {
      final b = _MemBridge();
      b.files['$root/$kAiJobsDir/manual-notes.md'] = '';
      b.files['$root/$kAiJobsDir/1758800000000-complete.md'] = '';
      final s = await loadAiInbox(bridge: b, projectRoot: root);
      expect(s.jobs.map((j) => j.name).toList(),
          ['1758800000000-complete.md', 'manual-notes.md']);
    });

    test('有 status: done 才算已完成；读不到正文保守算未完成', () async {
      final b = _MemBridge();
      b.files['$root/$kAiJobsDir/100-complete.md'] = 'status: done';
      b.files['$root/$kAiJobsDir/200-complete.md'] = '# 作业\n（还没动）';
      final s = await loadAiInbox(bridge: b, projectRoot: root);
      expect(s.jobs.firstWhere((j) => j.name.startsWith('100')).done, isTrue);
      expect(s.jobs.firstWhere((j) => j.name.startsWith('200')).done, isFalse);
      expect(s.pendingCount, 1);
    });

    test('只算 .md，目录项与其它文件不算作业', () async {
      final b = _MemBridge();
      b.files['$root/$kAiJobsDir/100-complete.md'] = 'status: done';
      b.files['$root/$kAiJobsDir/notes.txt'] = '杂物';
      final s = await loadAiInbox(bridge: b, projectRoot: root);
      expect(s.jobs.length, 1);
    });

    test('maxJobs 截断（作业可能积很多，弹窗不该被撑爆）', () async {
      final b = _MemBridge();
      for (var i = 1; i <= 30; i++) {
        b.files['$root/$kAiJobsDir/${i * 100}-complete.md'] = 'status: done';
      }
      final s = await loadAiInbox(bridge: b, projectRoot: root, maxJobs: 5);
      expect(s.jobs.length, 5);
      expect(s.jobs.first.name, '3000-complete.md', reason: '截断也要保住最新的');
    });

    test('inbox 索引一起读出来', () async {
      final b = _MemBridge();
      b.files['$root/$kAiInboxFile'] = '# AI 作业收件箱\n- [x] 一条';
      final s = await loadAiInbox(bridge: b, projectRoot: root);
      expect(s.inboxExists, isTrue);
      expect(s.inbox, contains('收件箱'));
    });

    test('作业目录不可读 → 带 error 但不抛（诊断入口自己崩了最糟）', () async {
      final b = _MemBridge()..failJobsDir = true;
      final s = await loadAiInbox(bridge: b, projectRoot: root);
      expect(s.jobs, isEmpty);
      expect(s.error, isNotNull);
    });

    test('项目根为空 → 直接给出可读原因，不瞎拼路径', () async {
      final s = await loadAiInbox(bridge: _MemBridge(), projectRoot: '');
      expect(s.error, contains('项目根'));
    });
  });

  group('describeJob · 一行说清状态', () {
    test('未完成是沙漏，完成是勾', () {
      const pend = AiJobEntry(
        path: '/a',
        name: '1-complete.md',
        kindName: 'complete',
        createdAt: null,
        status: AiJobStatus.pending,
      );
      const done = AiJobEntry(
        path: '/a',
        name: '1-complete.md',
        kindName: 'complete',
        createdAt: null,
        status: AiJobStatus.done,
      );
      expect(describeJob(pend), contains('⏳'));
      expect(describeJob(done), contains('✅'));
      expect(describeJob(pend), contains('complete'));
    });

    test('有时间戳就带上，方便对上"我刚才那次派活"', () {
      final e = AiJobEntry(
        path: '/a',
        name: '1-complete.md',
        kindName: 'complete',
        createdAt: DateTime(2026, 9, 26, 8, 5, 3),
        status: AiJobStatus.pending,
      );
      expect(describeJob(e), contains('09-26 08:05:03'));
    });

    test('类型为空时回落到"作业"', () {
      const e = AiJobEntry(
        path: '/a',
        name: 'x.md',
        kindName: '',
        createdAt: null,
        status: AiJobStatus.pending,
      );
      expect(describeJob(e), contains('作业'));
    });
  });
}
