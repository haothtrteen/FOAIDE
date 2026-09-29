import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ai/diff.dart';

/// 把 diff 结果还原成"新文本"（same + add 行）。
String applyNew(DiffResult r) =>
    r.lines.where((l) => l.kind != DiffKind.del).map((l) => l.text).join('\n');

/// 还原成"旧文本"（same + del 行）。
String applyOld(DiffResult r) =>
    r.lines.where((l) => l.kind != DiffKind.add).map((l) => l.text).join('\n');

void main() {
  group('diff · 基本情形', () {
    test('完全相同 → 空差异（AI 原样返回原文时别刷一堆 same 行）', () {
      const a = 'one\ntwo\nthree\n';
      final r = lineDiff(a, a);
      expect(r.isEmpty, isTrue);
      expect(r.added, 0);
      expect(r.removed, 0);
    });

    test('尾部换行差异不算差异', () {
      final r = lineDiff('a\nb', 'a\nb\n');
      expect(r.isEmpty, isTrue, reason: "'a\\nb' 与 'a\\nb\\n' 是同一份内容");
    });

    test('纯新增：只标 add，不带 del', () {
      const a = 'one\nthree\n';
      const b = 'one\ntwo\nthree\n';
      final r = lineDiff(a, b);
      expect(r.removed, 0);
      expect(r.added, 1);
      expect(applyNew(r), 'one\ntwo\nthree');
    });

    test('纯删除：只标 del，不带 add', () {
      const a = 'one\ntwo\nthree\n';
      const b = 'one\nthree\n';
      final r = lineDiff(a, b);
      expect(r.added, 0);
      expect(r.removed, 1);
      expect(applyOld(r), 'one\ntwo\nthree');
    });

    test('改写一行：拆成 del + add，且不牵连相邻行', () {
      const a = 'a\nb\nc\n';
      const b = 'a\nB\nc\n';
      final r = lineDiff(a, b);
      expect(r.added, 1);
      expect(r.removed, 1);
      // 首尾两行必须标成 same，否则预览会误导用户"整段都动了"
      expect(r.lines.first.kind, DiffKind.same);
      expect(r.lines.last.kind, DiffKind.same);
      expect(applyNew(r), 'a\nB\nc');
      expect(applyOld(r), 'a\nb\nc');
    });

    test('清空文件：全标 del', () {
      final r = lineDiff('a\nb\n', '');
      expect(r.removed, 2);
      expect(r.added, 0);
    });

    test('空文件写入内容：全标 add', () {
      final r = lineDiff('', 'a\nb\n');
      expect(r.added, 2);
      expect(r.removed, 0);
    });
  });

  group('diff · 还原不变式（无论怎么比对，都能还原回原文）', () {
    const cases = <List<String>>[
      ['a', 'a'],
      ['', 'x'],
      ['x', ''],
      ['a\nb\nc\n', 'c\nb\na\n'],
      ['1\n2\n3\n4\n', '1\n3\n5\n4\n'],
      ['same\n', 'same\nsame\n'],
      ['x\ny\n', 'y\nx\nz\n'],
    ];

    for (final c in cases) {
      test('${c[0]} → ${c[1]} 可双向还原', () {
        final r = lineDiff(c[0], c[1]);
        if (r.lines.isEmpty) {
          // 快路径：判定为无改动，那就必须真的是同一份内容
          expect(_norm(c[0]), _norm(c[1]));
          return;
        }
        expect(applyOld(r), _norm(c[0]), reason: '旧文本还原');
        expect(applyNew(r), _norm(c[1]), reason: '新文本还原');
      });
    }
  });

  group('diff · 大文件保护', () {
    test('超过阈值 → 退化整段替换并打 tooLarge', () {
      final a = List.generate(10, (i) => 'old $i').join('\n');
      final b = List.generate(10, (i) => 'new $i').join('\n');
      final r = lineDiff(a, b, maxLines: 5);
      expect(r.tooLarge, isTrue, reason: 'UI 要靠这个如实说明"只显示了整段替换"');
      // 退化形态必须仍是"旧的删光 + 新的全加"，不能是残缺比对
      expect(r.removed, 10);
      expect(r.added, 10);
      expect(applyNew(r), b);
      expect(applyOld(r), a);
    });

    test('阈值内不做退化（默认 1200 行够日常文件）', () {
      final a = List.generate(100, (i) => 'l$i').join('\n');
      final b = a.replaceFirst('l50', 'L50');
      final r = lineDiff(a, b);
      expect(r.tooLarge, isFalse);
      expect(r.added, 1);
      expect(r.removed, 1);
    });
  });

  group('diff · 性能护栏', () {
    test('几千行不至于算到卡死（阈值内 LCS 也要能跑完）', () {
      final a = List.generate(900, (i) => 'line $i').join('\n');
      final b = List.generate(900, (i) => i == 450 ? 'CHANGED' : 'line $i')
          .join('\n');
      final sw = Stopwatch()..start();
      final r = lineDiff(a, b);
      sw.stop();
      expect(r.added, 1);
      expect(r.removed, 1);
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: 'O(n×m) 在 900×900 内应当秒级完成');
    });
  });
}

/// 去掉末尾换行后的规范化文本（与 _splitLines 的口径一致）。
String _norm(String s) {
  var t = s;
  while (t.endsWith('\n')) {
    t = t.substring(0, t.length - 1);
  }
  return t;
}
