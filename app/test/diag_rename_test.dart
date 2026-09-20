import 'package:flutter_test/flutter_test.dart';

import 'package:foaide/toolchain/diag_page.dart';

/// 故障诊断页（alpha.60 由「远程排障」更名）契约测试。
///
/// 更名本身没有逻辑，但**名称会流进三处产物**：UI 标题、复制给 AI 的
/// 报告正文、MCP `foa_diag` 工具返回给远程 AI 的报告。任一一处残留旧名
/// 都会让用户/AI 看到两个概念打架，所以这里把标题抽成常量后逐条钉死。
void main() {
  group('更名 · 报告标题', () {
    test('报告头必须是「故障诊断」而非旧名「远程排障」', () {
      expect(kDiagReportTitle, '## FOA 故障诊断报告');
      expect(kDiagReportTitle.contains('远程排障'), isFalse);
      expect(kDiagReportTitle.contains('故障诊断'), isTrue);
    });

    test('buildDiagReport 首行即报告头（AI 粘贴后第一眼看到的是什么）',
        () {
      final items = DiagItem.pack();
      final out = buildDiagReport(items, List<String?>.filled(items.length, 'x'));
      expect(out.split('\n').first, kDiagReportTitle);
    });
  });

  group('buildDiagReport · 报告结构', () {
    final items = DiagItem.pack();

    test('未执行的项（null）不进入报告', () {
      final outputs = List<String?>.filled(items.length, null);
      outputs[0] = 'aarch64';
      final out = buildDiagReport(items, outputs);
      expect(out.contains('### ${items[0].name}'), isTrue);
      for (var i = 1; i < items.length; i++) {
        expect(out.contains('### ${items[i].name}'), isFalse,
            reason: '第 $i 项未执行，不该出现在报告里');
      }
    });

    test('每项含名称、以 \$\$ 起始的命令回显与输出', () {
      final outputs = List<String?>.filled(items.length, 'DUMMY_OUT');
      final out = buildDiagReport(items, outputs);
      for (final it in items) {
        expect(out.contains('### ${it.name}'), isTrue);
        expect(out.contains('DUMMY_OUT'), isTrue);
      }
      expect(out.contains('\$\$ '), isTrue);
    });

    test('脚本占位项在报告里展开为可读说明，而不是裸的 SH', () {
      final outputs = List<String?>.filled(items.length, 'ok');
      final out = buildDiagReport(items, outputs);
      expect(out.contains('<x64 兼容层体检脚本>'), isTrue);
      // 占位符裸串绝不能泄漏进报告——AI 会以为真有一条叫 SH 的命令
      expect(out.contains('\$\$ SH'), isFalse);
    });
  });

  group('DiagItem.pack · 命令包契约', () {
    test('项数稳定（MCP foa_diag 与 UI 同源，增删都要同步测试）', () {
      expect(DiagItem.pack().length, 8);
    });

    test('每项都有非空名称与命令', () {
      for (final it in DiagItem.pack()) {
        expect(it.name.trim().isNotEmpty, isTrue);
        expect(it.command.trim().isNotEmpty, isTrue);
      }
    });

    test('超时为正且不超过 5 分钟（诊断不该长时间独占）', () {
      for (final it in DiagItem.pack()) {
        expect(it.timeoutSec, greaterThan(0));
        expect(it.timeoutSec, lessThanOrEqualTo(300));
      }
    });

    test('无破坏性命令（诊断包必须是只读探测）', () {
      for (final it in DiagItem.pack()) {
        final c = it.command.toLowerCase();
        expect(c.contains('rm -rf'), isFalse, reason: it.name);
        expect(c.contains('mkfs'), isFalse, reason: it.name);
        expect(c.contains('> /dev/'), isFalse, reason: it.name);
        expect(c.contains('shutdown'), isFalse, reason: it.name);
      }
    });

    test('恰好一项使用脚本占位符（x64 兼容层体检）', () {
      final ph = DiagItem.pack()
          .where((it) => it.command == DiagItem.scriptPlaceholder)
          .toList();
      expect(ph.length, 1);
      expect(ph.first.name.contains('兼容层'), isTrue);
      // 占位符本身也是一个可被 MCP/UI 复用的常量
      expect(DiagItem.scriptPlaceholder, 'SH');
    });
  });
}
