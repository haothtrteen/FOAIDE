// Bug 433 回归测试：两个真机阻断性问题。
//
// 症状（2026-09-19 用户反馈 + 截图）：
//   ① 构建失败：AOT 跑到 54%，`shaders/ink_sparkle.frag` 编译
//      `Dart snapshot generator failed with exit code -4`
//      → 即 Bug 429 在「pub get 插队」场景下的复发
//   ② 终端永久停在「正在启动终端…」转圈
//
// 根因 ①：buildCommand 在 flutter build 前先跑 `flutter pub get`。
//   pub get 会触发 Flutter 重新下载引擎构件，把 linux-arm64/<tool>
//   写回**真 x64 二进制**，盖掉构建前 qemuCompatEnsure 放的转发脚本。
//   修复：在 pub get 之后、flutter build 之前，于同一条 shell 命令内
//   再断言一次转发层（QemuCompat.wrapReassertScript）。
//
// 根因 ②：ptyStart 里从 buildProotCmd 的输出截掉 `-c` 时，只截到
//   `-c` 之前，head 末尾残留一个孤立 `/bin/sh`。重新拼接后实际执行的是
//     ... /bin/sh /usr/bin/env -i ... /bin/sh -c "boot; exec /bin/sh -i"
//   外层 sh 把 `/usr/bin/env` 当脚本文件执行 → 起不来 → 界面永久转圈。
//   修复：截 `-c` 时把紧邻其前的 `/bin/sh` 一并截掉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_on_android/toolchain/build_runner.dart';
import 'package:flutter_on_android/toolchain/qemu_compat.dart';

void main() {
  group('Bug 433 ① · 构建命令必须在 pub get 之后再断言转发层', () {
    final cmd = BuildRunner.buildCommand(
      proj: '/root/projects/demo',
      flutterCmd: 'flutter',
      envPart: '',
      aapt2Override: '',
    );

    test('命令里包含再断言脚本', () {
      expect(cmd.contains('REASSERT='), isTrue,
          reason: '构建命令必须内联转发层再断言（否则 pub get 盖掉包装）');
    });

    test('再断言出现在 pub get 之后、flutter build 之前', () {
      final pubIdx = cmd.indexOf('pub get');
      final reIdx = cmd.indexOf('REASSERT=');
      final buildIdx = cmd.indexOf('build apk');
      expect(pubIdx, greaterThan(0));
      expect(reIdx, greaterThan(0));
      expect(buildIdx, greaterThan(0));
      expect(reIdx, greaterThan(pubIdx),
          reason: '必须在 pub get 之后（pub get 才是覆盖转发脚本的元凶）');
      expect(reIdx, lessThan(buildIdx),
          reason: '必须在 flutter build 之前（否则来不及生效）');
    });

    test('再断言不得引入新的 pub get / precache（避免递归与耗时）', () {
      // 直接检查再断言脚本本体——比在拼好的命令里按 "sh -c '" 切片稳，
      // 因为 Bug 436 之后命令里还有其它 sh -c 片段（版本检查 stamp），
      // 按位置切片会切错对象。
      const s = QemuCompat.wrapReassertScript;
      expect(s.contains('pub get'), isFalse,
          reason: '再断言脚本内不得再跑 pub get');
      expect(s.contains('precache'), isFalse,
          reason: '前置检查已确保构件存在，再断言不该 precache');
    });

    test('命令里注入的再断言脚本确实是 wrapReassertScript', () {
      // 机械保障：命令里必须出现该脚本的特征串
      expect(cmd.contains('REASSERT='), isTrue);
      expect(QemuCompat.wrapReassertScript.contains('REASSERT='), isTrue);
    });

    test('用 sh -c 而非 { ... ; } 分组（后者遇尾部换行会报语法错）', () {
      // 脚本末尾带换行，`\n ; }` 在 dash/bash 下都非法。
      expect(cmd.contains("sh -c '"), isTrue,
          reason: '必须用 sh -c 内嵌多行脚本');
      expect(RegExp(r'\{\s*\$?reassert').hasMatch(cmd), isFalse,
          reason: '不得用 { script ; } 分组');
    });
  });

  group('Bug 433 ① · 再断言脚本本身', () {
    const s = QemuCompat.wrapReassertScript;

    test('覆盖引擎层与顶层宿主工具层两个目录', () {
      expect(s.contains(r'"$E"/android-*/linux-x64'), isTrue,
          reason: '必须遍历 android-*/linux-x64（引擎层）');
      expect(s.contains(r'"$E"/linux-*/'), isTrue,
          reason: r'必须遍历 $E/linux-*/（顶层宿主工具层，impellerc 在此）');
    });

    test('只包装 x86_64 ELF，且按 #! 幂等跳过', () {
      expect(s.contains('7f454c46*3e'), isTrue,
          reason: '必须按 ELF 魔数+e_machine 判定 x86_64');
      expect(s.contains("grep -q '#!'"), isTrue,
          reason: '必须按「是否已是转发脚本」判定，而非文件是否存在');
    });

    test('生成的转发脚本含 shebang 与 qemu exec', () {
      expect(s.contains('#!/bin/sh'), isTrue);
      expect(s.contains('exec @QEMU@ -L /'), isTrue);
    });

    test(r'外层变量用裸 $（Dart 原始字符串里 \$ 会残留反斜杠给 shell）', () {
      // Dart r'''...''' 中 \$ 是两个字面字符，会原样传给 shell。
      // 外层脚本变量必须写裸 $，只有 heredoc 内（要写进转发脚本的）
      // 才用 \$ 让 shell 求值。
      expect(s.contains(r'm=$(dd if="$1"'),
          isTrue, reason: r'外层变量必须是裸 $，否则 shell 收到 \$ 报语法错');
      expect(s.contains(r'd=\$(dirname "\$0")'), isTrue,
          reason: r'heredoc 内必须用 \$ 才会在写入时还原为 $');
    });
  });

  group('Bug 433 ① · 转义语义固化', () {
    test('engineWrapScript 与 reassert 的转义风格一致', () {
      const e = QemuCompat.engineWrapScript;
      const r = QemuCompat.wrapReassertScript;
      // 两者都必须出现 heredoc 形式的 \$（写入转发脚本用）
      expect(e.contains(r'\$(dirname'), isTrue);
      expect(r.contains(r'\$(dirname'), isTrue);
      // 两者都必须出现裸 $ 形式的 $E（外层变量）
      expect(e.contains(r'E=@ENGINE@'), isTrue);
      expect(r.contains(r'E=@ENGINE@'), isTrue);
    });
  });

  group('Bug 433 ② · 终端 argv 截断', () {
    late String kt;

    setUpAll(() {
      kt = File('platform/android/MainActivity.kt').readAsStringSync();
    });

    String fnBody(String src, String name) {
      final i = src.indexOf('private fun $name');
      if (i < 0) return '';
      final start = src.indexOf('{', i);
      if (start < 0) return '';
      var depth = 0;
      for (var k = start; k < src.length; k++) {
        if (src[k] == '{') depth++;
        if (src[k] == '}') {
          depth--;
          if (depth == 0) return src.substring(start, k + 1);
        }
      }
      return src.substring(start);
    }

    test('截断时必须把 -c 前紧邻的 /bin/sh 一并去掉', () {
      final body = fnBody(kt, 'ptyStart');
      expect(body.isNotEmpty, isTrue, reason: '必须能找到 ptyStart');
      // 必须存在「回退一格」的动作：headEnd -= 1
      expect(body.contains('headEnd'), isTrue,
          reason: '必须引入 headEnd 变量以便回退');
      expect(body.contains('headEnd -= 1'), isTrue,
          reason: '必须把 -c 前紧邻的 /bin/sh 也截掉，否则残留孤立 /bin/sh');
      expect(body.contains('endsWith("/sh")'), isTrue,
          reason: '必须识别 sh 路径形态');
    });

    test('不得再用旧的只截到 -c 的写法', () {
      final body = fnBody(kt, 'ptyStart');
      // 旧写法：val head = if (tailIdx > 0) base.subList(0, tailIdx) else base
      expect(
        RegExp(r'val head = if \(tailIdx > 0\) base\.subList\(0, tailIdx\)')
            .hasMatch(body),
        isFalse,
        reason: '旧写法会把孤立 /bin/sh 留在 head 末尾（Bug 433 根因）',
      );
    });

    test('收尾仍是 /bin/sh -c "<boot>exec /bin/sh -i"', () {
      final body = fnBody(kt, 'ptyStart');
      expect(body.contains('"exec /bin/sh -i"'), isTrue,
          reason: '交互式 shell 必须以 exec 顶替外层进程');
    });
  });

  group('Bug 433 ② · 终端启动必须有超时兜底', () {
    late String page;

    setUpAll(() {
      page = File('lib/ui/terminal_page.dart').readAsStringSync();
    });

    test('ptyStart 调用带 timeout', () {
      final i = page.indexOf('_bridge');
      expect(i, greaterThan(0));
      expect(page.contains('.timeout(const Duration(seconds: 45))'), isTrue,
          reason: '无超时则原生卡住时界面永久转圈（真机症状）');
    });

    test('超时走 TimeoutException 分支并给出可读诊断', () {
      expect(page.contains('on TimeoutException'), isTrue);
      expect(page.contains('启动终端超时'), isTrue,
          reason: '必须告诉用户发生了什么，而不是继续转圈');
      expect(page.contains('_starting = false'), isTrue,
          reason: '超时必须结束 loading 态');
    });

    test('_pickBackend 也有超时（它同样在启动路径上）', () {
      expect(page.contains('_pickBackend(env).timeout('), isTrue,
          reason: '_pickBackend 读偏好文件，异常时同样会挂住启动');
    });
  });
}
