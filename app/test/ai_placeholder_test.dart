import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/editor/code_editor.dart';

String src(String rel) => File(rel).readAsStringSync();

void main() {
  group('占位插入点 · 必须落在光标所在行的行末', () {
    test('光标停在一行中间 → 取该行末尾（不许把代码劈成两半）', () {
      const text = 'final a = 1;\nnext();';
      // 'final a = 1;' 占 0..11，'\n' 在 12；光标停在 7（'final a' 之后）
      expect(aiPlaceholderInsertAt(text, 7), 12,
          reason: '插在 12 才是整行空行；插在 7 会把这行劈成 "final a" + " = 1;"');
    });

    test('光标在首行开头 → 取首行末尾', () {
      expect(aiPlaceholderInsertAt('abc\ndef', 0), 3);
    });

    test('光标在最后一行且最后没有换行 → 取文本末尾', () {
      expect(aiPlaceholderInsertAt('abc\ndef', 6), 7);
      expect(aiPlaceholderInsertAt('abc\ndef', 99), 7, reason: '越界光标要夹住');
    });

    test('空文本 / 负光标不崩', () {
      expect(aiPlaceholderInsertAt('', 0), 0);
      expect(aiPlaceholderInsertAt('abc', -1), 3);
      expect(aiPlaceholderInsertAt('abc', -99), 3);
    });

    test('插入点一定是"换行符位置或文本末尾"——永不落在行中间', () {
      const text = 'one\ntwo\nthree';
      for (var cursor = 0; cursor <= text.length; cursor++) {
        final at = aiPlaceholderInsertAt(text, cursor);
        expect(at == text.length || text[at] == '\n', isTrue,
            reason: 'cursor=$cursor 算出的插入点 $at 落在行中间了');
      }
    });
  });

  group('AI 占位 · 接线（源码断言）', () {
    final editor = src('lib/editor/code_editor.dart');
    final page = src('lib/editor/editor_page.dart');

    test('三个占位方法都在，且成对（有 begin 就必须有 commit/cancel）', () {
      expect(editor, contains('int beginAiPlaceholder('));
      expect(editor, contains('void commitAiPlaceholder('));
      expect(editor, contains('void cancelAiPlaceholder('),
          reason: '没有撤销，失败时会把空行永久留在用户文件里');
    });

    test('生成期间编辑器只读（readOnly 接 aiBusy）', () {
      expect(editor, contains('readOnly: widget.aiBusy'),
          reason: '占位区间在等待期间被改动，提交/回滚就会删错内容');
      expect(editor, contains('final bool aiBusy'));
    });

    test('生成中不再派活（防重复占位）', () {
      final i = editor.indexOf('void _emitAi(');
      expect(i, greaterThanOrEqualTo(0));
      final body = editor.substring(i, i + 400);
      expect(body, contains('widget.aiBusy'), reason: '占位区间只有一个，重复派活会让回滚对不上号');
    });

    test('编辑器页：先收键盘，再占位', () {
      final i = page.indexOf('FocusScope.of(context).unfocus()');
      final j = page.indexOf('beginAiPlaceholder()');
      expect(i, greaterThanOrEqualTo(0), reason: '必须先收键盘');
      expect(j, greaterThan(i), reason: '顺序反了的话键盘会压住刚预留出来的空行，用户根本看不见');
    });

    test('编辑器页：拿到内容才 commit，其余两种结果都回滚', () {
      expect(page, contains('cancelAiPlaceholder()'));
      expect(page, contains('commitAiPlaceholder(out.text)'));
      // 派活（dispatched）不许占位——异步无回执，空行会一直卡在那。
      // 断言按**位置关系**而不是正则缩进（Bug 610 教训：排版会变，语义不会）。
      final guard = page.indexOf('if (out.kind != AiOutcomeKind.content)');
      expect(guard, greaterThanOrEqualTo(0), reason: '缺少"非 content 就回滚"的分支');
      final seg = page.substring(guard, guard + 600);
      expect(seg, contains('cancelAiPlaceholder'),
          reason: '非 content 分支必须回滚占位');
      final commit = page.indexOf('commitAiPlaceholder(out.text)');
      expect(commit, greaterThan(guard), reason: 'commit 只能在"确认拿到内容"之后发生');
    });

    test('编辑器页：写完问存不存（保存 / 放弃 / 先不存 三个出口）', () {
      final i = page.indexOf('Future<void> _askSaveAiChange(');
      expect(i, greaterThanOrEqualTo(0), reason: '写完必须问一句存不存');
      final fn = page.substring(i, i + 2500);
      // alpha.91：出口从裸字符串改成 DiffChoice 枚举（弹窗换全屏抽屉）。
      // 断言跟着改成枚举——比裸字符串更难被"随便写个 'save' 字样"蒙过去。
      for (final c in [
        'DiffChoice.discard',
        'DiffChoice.later',
        'DiffChoice.save',
      ]) {
        expect(fn, contains(c), reason: '缺少出口 $c');
      }
      // 三个出口的**按钮**也得真的挂上（只定义枚举不算数）。
      expect(fn, contains('DiffAction('), reason: '出口必须作为按钮交给抽屉');
    });

    test('放弃要连 dirty 状态一起回滚（不能把用户自己的未保存改动标成已存）', () {
      final i = page.indexOf('void _rollbackAi()');
      expect(i, greaterThanOrEqualTo(0));
      final fn = page.substring(i, i + 400);
      expect(fn, contains('_dirty = _aiBeforeDirty'));
    });
  });

  group('AI 流程 · 宿主只提供"怎么跑"，插入点仍在编辑器侧', () {
    test('project_page 注入 onRunAi 而不是自己算插入点', () {
      final p = src('lib/project/project_page.dart');
      expect(p, contains('onRunAi: _runAi'));
      expect(p, isNot(contains('applyAiResult')), reason: '宿主不该再回头找编辑器要插入点');
    });

    test('AiAssist 只返回结果，不再弹预览（预览 sheet 已随新流程删除）', () {
      final a = src('lib/ai/ai_assist.dart');
      expect(a, contains('Future<AiOutcome> run(AiJob job)'));
      expect(a, isNot(contains('showAiPreviewSheet')));
      expect(File('lib/ai/ai_preview.dart').existsSync(), isFalse,
          reason: '没人调用的 sheet 是死代码，不留');
    });
  });
}
