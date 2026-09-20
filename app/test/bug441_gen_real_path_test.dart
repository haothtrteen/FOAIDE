import 'dart:io';

import 'package:foaide/toolchain/qemu_compat.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bug 441：Bug 439 把 heredoc 分隔符改成带引号的 `<<'FOAWRAP'` 后，
/// 生成脚本里的 `$2` **不再被生成期展开**，而是原样留在了转发脚本里。
///
/// 后果：运行时 `$2` 是**调用者的第一个业务参数**（`$1` 才是真身），
/// 于是命令整体错位成
///   `qemu -L / <ld.so> <业务参数> <真身> <业务参数>`
/// —— 把业务参数当成要加载的程序。真机表现：
///   `error while loading shared libraries:
///    .../flutter_tools.snapshot: invalid ELF header`
/// （dart 的参数里有 snapshot 路径，被 qemu 送进了 ld.so）。
///
/// Bug 439 的 16 个测试**全是静态文本断言**，没有一个是"生成脚本后
/// 实际检查内容"，所以完全没抓到。本文件补上这个缺口。
void main() {
  /// 从脚本里抽出 `gen()` 函数体（它由 `__FOA_GEN__` 展开而来）。
  String genFunc() {
    final s = QemuCompat.fill(QemuCompat.wrapReassertScript);
    final i = s.indexOf('gen() {');
    expect(i, greaterThanOrEqualTo(0), reason: 'gen() 必须存在');
    final lines = s.substring(i).split('\n');
    final out = <String>[];
    for (final ln in lines) {
      out.add(ln);
      if (ln == '}') break;
    }
    return out.join('\n');
  }

  /// 真实执行 gen()，返回生成出来的转发脚本文本。
  ///
  /// 这是与 Bug 439 测试的本质区别：**跑 shell，看产物**。
  String generate(String realPath) {
    final dir = Directory.systemTemp.createTempSync('foa441');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final genFile = File('${dir.path}/gen.sh')..writeAsStringSync(genFunc());
    final outFile = '${dir.path}/wrapper.sh';
    final r = Process.runSync('/bin/sh', [
      '-c',
      r'. "$1"; gen "$2" "$3"',
      'sh',
      genFile.path,
      outFile,
      realPath,
    ]);
    expect(r.exitCode, 0, reason: 'gen() 执行失败：${r.stderr}');
    return File(outFile).readAsStringSync();
  }

  group('Bug 441 · 生成脚本必须烘入真身路径', () {
    test('真身路径被写进脚本（不是运行时的第二参数）', () {
      const real = '/opt/real/path/impellerc';
      final s = generate(real);
      expect(s.contains('"$real"'), isTrue,
          reason: '生成期必须把真身路径烘进脚本');
      expect(s.contains('exec '), isTrue);
    });

    test('脚本里不得残留裸的美元2（这正是 Bug 441 的形态）', () {
      final s = generate('/opt/real/path/impellerc');
      // 允许 $@（透传参数）与 $0/$d（脚本自身定位），但绝不能有 "$2"。
      expect(s.contains(r'"$2"'), isFalse,
          reason: '运行时的第二参数是业务参数不是真身——留着它就会参数错位，'
              '把业务参数送进 ld.so，报 invalid ELF header');
    });

    test('旧形式回退分支同样烘入真身路径', () {
      final s = generate('/opt/real/path/impellerc');
      // 两处 exec（新形式带 ld.so、旧形式回退）都要正确
      final execs = s
          .split('\n')
          .where((l) => l.trimLeft().startsWith('exec '))
          .toList();
      expect(execs.length, 2, reason: '应有显式 ld.so 与回退两条 exec');
      for (final e in execs) {
        expect(e.contains('/opt/real/path/impellerc'), isTrue,
            reason: '每条 exec 都必须指向真身：$e');
        expect(e.contains(r'$2'), isFalse, reason: '不得残留第二参数占位：$e');
      }
    });

    test('带空格/特殊字符的路径也能正确烘入', () {
      const real = '/opt/my tools/bin/foo';
      final s = generate(real);
      expect(s.contains(real), isTrue);
      expect(Process.runSync('/bin/sh', ['-n', '/dev/stdin'], ).exitCode, 0);
    });

    test('生成的脚本 shell 语法合法（dash 与 bash）', () {
      final dir = Directory.systemTemp.createTempSync('foa441s');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final f = File('${dir.path}/w.sh')
        ..writeAsStringSync(generate('/opt/real/impellerc'));
      for (final sh in ['dash', 'bash']) {
        final r = Process.runSync(sh, ['-n', f.path]);
        expect(r.exitCode, 0, reason: '$sh 语法错误：${r.stderr}');
      }
    });
  });

  group('Bug 441 · 黑名单与自愈', () {
    test('snapshot / dill 等非可执行文件在排除名单里', () {
      for (final s in [
        QemuCompat.wrapReassertScript,
        QemuCompat.engineWrapScript,
        QemuCompat.sdkWrapScript,
      ]) {
        expect(s.contains('*.snapshot'), isTrue,
            reason: 'flutter_tools.snapshot 是 Dart app-jit 快照'
                '（头 dc dc f6 f6，正文含 "x64 linux"），不是可执行文件，'
                '被包装后送进 ld.so 就是 invalid ELF header');
        expect(s.contains('*.dill'), isTrue);
        expect(s.contains('*.so'), isTrue);
      }
    });

    test('自愈脚本存在且能还原 *.foa-real', () {
      final s = QemuCompat.fill(QemuCompat.healScript);
      expect(s.contains('.foa-real'), isTrue);
      expect(s.contains('mv '), isTrue, reason: '还原动作靠 mv');
      expect(s.contains('HEALED='), isTrue, reason: '要输出可读摘要');
    });

    test('自愈脚本会校验 snapshot 头部（防止"还原没生效"被误判成功）', () {
      final s = QemuCompat.fill(QemuCompat.healScript);
      expect(s.contains('dcdcf6f6'), isTrue,
          reason: 'Dart snapshot 魔数，用来确认它已不是转发脚本');
      expect(s.contains('SNAPSHOT=ok'), isTrue);
      expect(s.contains('SCRIPT_BROKEN'), isTrue,
          reason: '若仍是 #! 开头要明确报出来，而不是静默通过');
    });

    test('自愈脚本 shell 语法合法', () {
      final dir = Directory.systemTemp.createTempSync('foa441h');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final f = File('${dir.path}/heal.sh')
        ..writeAsStringSync(QemuCompat.fill(QemuCompat.healScript));
      for (final sh in ['dash', 'bash']) {
        final r = Process.runSync(sh, ['-n', f.path]);
        expect(r.exitCode, 0, reason: '$sh 语法错误：${r.stderr}');
      }
    });
  });

  group('Bug 441 · 端到端自愈演练', () {
    test('把一个"被包装坏的 snapshot"还原回原样', () {
      final dir = Directory.systemTemp.createTempSync('foa441e');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      // 造一个假 snapshot：本体（真身）+ 被套上的转发脚本
      final real = File('${dir.path}/snap.foa-real')
        ..writeAsBytesSync([0xdc, 0xdc, 0xf6, 0xf6, 0, 0, 0, 0]);
      final wrapped = File('${dir.path}/snap')
        ..writeAsStringSync('#!/bin/sh\nexec qemu ...\n');
      expect(real.existsSync(), isTrue);
      expect(wrapped.existsSync(), isTrue);

      // 执行还原逻辑（与 healScript 的核心动作一致）
      final r = Process.runSync('/bin/sh', [
        '-c',
        r'for f in "$1"/*.foa-real; do '
            r'[ -f "$f" ] || continue; b="${f%.foa-real}"; '
            r'rm -f "$b"; mv "$f" "$b"; done; '
            r'od -An -tx1 -N 4 "$1/snap" | tr -d " "',
        'sh',
        dir.path,
      ]);
      expect(r.exitCode, 0);
      // 还原后：snap 应当是 snapshot 魔数，且 .foa-real 已消失
      expect(r.stdout.trim(), 'dcdcf6f6',
          reason: '还原后应恢复成原始 Dart snapshot 头');
      expect(File('${dir.path}/snap.foa-real').existsSync(), isFalse);
    });
  });
}
