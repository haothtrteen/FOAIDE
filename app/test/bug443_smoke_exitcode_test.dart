import 'dart:io';

import 'package:foaide/toolchain/build_runner.dart';
import 'package:foaide/toolchain/qemu_compat.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bug 443：我在 Bug 437 里写的 `smoke()` 退出码捕获是**错的**，
/// 而且这个错误让整条诊断链在最需要它的时候失效。
///
/// 旧写法（错误）：
///   `o=$( "$t" --help 2>&1 | head -5 )` 然后取 `$?`
///
/// 管道会把 `$?` 变成**管道最后一段**（`head`）的退出码，恒为 0。后果：
///   - "信号退出"分支是**死代码**，从没生效过
///   - 真机被 SIGILL 杀死时，只显示"无输出（rc=0）"，
///     既看不出是信号，也看不出是哪个信号 —— 而 SIGILL 正是最需要
///     被识别的那一类（x64 未经 qemu 转发）
///
/// 同一类错误在 Bug 438 的 `QEMU_CHAIN_PROBE` 里已经被修过一次
/// （那里改成了"先落盘再读"）。这次是**同一个错误在另一个函数里复发**——
/// 说明当时只修了那一个点，没有全仓扫同类写法。
void main() {
  /// 执行一段 shell，返回 stdout+stderr。
  String sh(String script) {
    final dir = Directory.systemTemp.createTempSync('foa443');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final f = File('${dir.path}/t.sh')..writeAsStringSync(script);
    final r = Process.runSync('/bin/sh', [f.path]);
    return '${r.stdout}${r.stderr}';
  }

  /// 造一个"跑起来就被 SIGILL 杀死"的可执行文件，返回其路径。
  ///
  /// ⚠️ 不能用 `kill -4 $$` —— 那会杀掉**脚本自己**，脚本直接终止，
  /// 后面取退出码的语句根本执行不到（我第一版就这么写的，
  /// 结果测试失败的原因和被测 bug 完全无关）。必须是一个**子进程**。
  String makeSigglingProgram() {
    final dir = Directory.systemTemp.createTempSync('foa443prog');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final p = File('${dir.path}/crash.sh');
    // 用字符串拼接而不是插值/级联，避免 Dart 把 shell 的 $ 变量当插值。
    // 这里要的就是脚本被 SIGILL 杀死（kill -4 自己）。
    p.writeAsStringSync('#!/bin/sh\n' 'kill -4 \$' '\$\n');
    Process.runSync('chmod', ['755', p.path]);
    return p.path;
  }

  group('Bug 443 · 管道吞掉退出码（可复现的最小验证）', () {
    test('演示缺陷：管道形式拿到的退出码恒为 head 的 0', () {
      final prog = makeSigglingProgram();
      // 原始字符串，避免 Dart 对美元符号做插值
      final out = sh('''
"$prog" > /dev/null 2>&1
printf 'direct=%s\\n' "\$?"
o=\$( "$prog" --help 2>&1 | head -5 )
printf 'piped_head=%s\\n' "\$?"
''');
      expect(out, contains('direct=132'),
          reason: '不带管道时能拿到真实信号退出码（128+4=SIGILL）');
      expect(out, contains('piped_head=0'),
          reason: '管道会把退出码变成 head 的（恒 0）—— '
              '这就是 Bug 443：信号分支永远进不去');
    });

    test('修法：先落盘再读，退出码紧邻被调程序', () {
      final prog = makeSigglingProgram();
      final out = sh('''
st=/tmp/.foa443_probe
: > "\$st"
"$prog" --help > "\$st" 2>&1
r=\$?
printf 'rc=%s\\n' "\$r"
rm -f "\$st"
''');
      expect(out, contains('rc=132'),
          reason: '先落盘再读才能捕到真实信号退出码 132（SIGILL）');
    });
  });

  group('Bug 443 · verify 脚本的 smoke() 必须已修正', () {
    test('不得再用管道形式直接取被调程序的退出码', () {
      final src = qemuCompatSource;
      final bad = RegExp(
        r'o=\$\(\s*"\$t"\s*--help[^\n]*\|\s*head[^\n]*\)\s*\n\s*r=\$\?',
      );
      expect(bad.hasMatch(src), isFalse,
          reason: 'smoke() 里不得用管道形式取退出码 —— head 的退出码恒为 0，'
              '会让 SIGILL 分支变成死代码');
    });

    test('必须用临时文件承接输出，再紧邻取退出码', () {
      final src = qemuCompatSource;
      expect(src.contains('.foa_smoke_out'), isTrue,
          reason: '必须有一个落盘文件承接 --help 输出，'
              '这样退出码才紧邻被调程序');
      final rcAfter = RegExp(r'--help\s*>\s*"\$st"\s*2>&1\s*\n\s*r=\$\?');
      expect(rcAfter.hasMatch(src), isTrue,
          reason: '重定向后必须**立即**取退出码，中间不能插管道');
    });

    test('全仓扫同类写法：不得再有「管道接 head」紧跟取退出码', () {
      final src = qemuCompatSource;
      final anyPipeHead =
          RegExp(r'\$\([^\n]*\|[^\n]*head[^\n]*\)\s*\n\s*\w=\$\?');
      expect(anyPipeHead.hasMatch(src), isFalse,
          reason: '这是 Bug 438 修过一次、Bug 443 又复发一次的同一类错误——'
              '必须整体扫掉，不能只修单点');
    });
  });

  group('Bug 443 · 诊断行数上限必须留足', () {
    final cmd = BuildRunner.buildCommand(
      proj: '/root/projects/demo',
      flutterCmd: 'flutter',
      envPart: '',
      aapt2Override: '',
    );

    /// 取出紧邻某标记**之后**的 tail 行数。
    ///
    /// 为什么按标记找：构建命令是多个 `sh -c '<脚本>' 2>&1 | tail -n N;`
    /// 拼起来的，每个脚本内部会 echo 各自的标记。标记之后最近的那个
    /// `tail -n` 就是该脚本的截断行数。窗口要开得够大——脚本正文
    /// （含注释与函数）可能有几千字符。
    int? tailAfter(String marker) {
      final i = cmd.indexOf(marker);
      if (i < 0) return null;
      final end = (i + 4000).clamp(0, cmd.length);
      final seg = cmd.substring(i, end);
      final m = RegExp(r'tail -n (\d+)').firstMatch(seg);
      return m == null ? null : int.parse(m.group(1)!);
    }

    test('diag 的 tail 要能容纳全部 QEMU_CHAIN 诊断行', () {
      final n = tailAfter('QEMU_CHAIN_DONE=1');
      expect(n, isNotNull, reason: 'diag 片段应有 tail 限制');
      expect(
          n!, greaterThanOrEqualTo(20),
          reason: 'diag 输出行数多（每个失败的冒烟额外带一行原因），'
              'tail 太小会把开头的 qemu 版本/加载器状态挤掉');
    });

    test('heal 的 tail 要能容纳 HEALED/DART/SNAPSHOT 三行', () {
      final n = tailAfter('SNAPSHOT=unexpected');
      expect(n, isNotNull);
      expect(
          n!, greaterThanOrEqualTo(6),
          reason: 'heal 现在输出 3 行（HEALED/DART/SNAPSHOT），'
              'tail 太小会截掉前面的 HEALED');
    });

    test('reassert 的 tail 要能容纳 REASSERT 与 REASSERT_DART 两行', () {
      final n = tailAfter('REASSERT_DART=');
      expect(n, isNotNull);
      final echoes = RegExp(r'echo "REASSERT')
          .allMatches(QemuCompat.wrapReassertScript)
          .length;
      expect(echoes, greaterThanOrEqualTo(2),
          reason: '脚本自身至少输出两行');
      expect(
          n!, greaterThan(echoes),
          reason: 'tail 必须严格大于脚本自身输出行数，'
              '否则一旦有 stderr 混入就会截掉正常诊断'
              '（真机上表现为「日志里没有 REASSERT=」）');
    });
  });
}

/// qemu_compat.dart 的源码文本（用于结构性反证）。
///
/// 读源文件而不是引用公开常量——这些断言针对的是**写法**本身，
/// 而"写法"没有可断言的公开 API。
final String qemuCompatSource =
    File('lib/toolchain/qemu_compat.dart').readAsStringSync();
