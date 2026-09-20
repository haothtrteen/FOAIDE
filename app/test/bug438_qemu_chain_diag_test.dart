import 'package:foaide/toolchain/build_runner.dart';
import 'package:foaide/toolchain/qemu_compat.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bug 438：AOT/shader 阶段 `exit -4`（SIGILL）且 **stderr 为空**。
///
/// 真机日志（2026-09-19，alpha.45）：
/// ```
/// Dart snapshot generator failed with exit code -4
/// impellerc failure:            ← 注意：冒号后面什么都没有
/// impellerc failure:            ← 重试一次，仍然空
/// ```
///
/// `impellerc failure: ` 后面为空，来自 flutter 源码：
/// ```dart
/// // build_system/tools/shader_compiler.dart:274
/// _logger.printError('impellerc failure: ${result.stderr}');
/// ```
/// 即 **`result.stderr` 是空字符串**。
///
/// 关键推论：
/// 1. **不是依赖库问题**——那种情况会打印
///    `error while loading shared libraries: ...`，不会是空。
/// 2. **不是转发层被覆盖**——同轮 `REASSERT=0` 且脚本完好（Bug 433 已证）。
/// 3. **两个不同的 x64 程序**（gen_snapshot 与 impellerc）在**同一个 qemu**
///    下同时静默崩溃，说明故障在 **qemu 链路本身**，不在某个程序。
///
/// 这类崩溃最麻烦的地方是**零输出**：无法从 flutter 日志反推，只能
/// 「先产出事实，再判断」。所以本 bug 的修复不是"改某行代码"，
/// 而是**让构建日志自己开口说话**——构建前主动分层诊断 qemu 链路。
///
/// 已用模拟环境验证诊断的区分能力（沙箱本身无 qemu，无法真机复现）：
///   - 模拟 SIGILL（`kill -ILL $$`）→ `LOADER=fail rc=132` /
///     `PROBE=impellerc=FAIL:SIGILL out=EMPTY`
///   - 模拟正常 → `LOADER=ok` / `PROBE=impellerc=ok rc=0`
void main() {
  group('Bug 438 · 构建前 qemu 链路诊断', () {
    test('buildCommand 注入预检脚本', () {
      final cmd = BuildRunner.buildCommand(
        proj: '/root/projects/my_flutter',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(cmd.contains('QEMU_CHAIN_DONE'), isTrue,
          reason: '构建日志必须带上 qemu 链路的真实状态，否则 SIGILL 无从排查');
    });

    test('预检必须在 pub get 之前（尽早暴露，不浪费几分钟构建）', () {
      final cmd = BuildRunner.buildCommand(
        proj: '/p',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      // 判据要落在**实际执行 pub get 的那条语句**上，不能用裸的
      // `indexOf('pub get')` —— 代码注释里也会出现 "pub get" 字样
      // （Bug 423/433/443 的说明都提到它），一旦注释排在预检前面，
      // indexOf 就会命中注释，断言误报失败。
      // 真机上这条测试保护的是"预检早于 pub get 执行"，
      // 所以找真正的命令形态 `flutter pub get;`
      // （`$flutterCmd` 在 Dart 层已插值为 `flutter`）。
      final preflight = cmd.indexOf('QEMU_CHAIN_DONE');
      final pubGetCmd = cmd.indexOf('flutter pub get;');
      expect(preflight, greaterThanOrEqualTo(0));
      expect(pubGetCmd, greaterThanOrEqualTo(0),
          reason: '构建命令里必须有真正的 pub get 调用');
      expect(preflight < pubGetCmd, isTrue,
          reason: '预检必须排在 pub get 命令之前（注释里提及不算）');
    });

    test('分层覆盖：qemu 本体 / 动态链接器 / 真实 x64 二进制 / 目标架构', () {
      const s = QemuCompat.buildPreflightScript;
      expect(s.contains('QEMU_CHAIN_VER='), isTrue, reason: '第 1 层：qemu 能跑');
      expect(s.contains('QEMU_CHAIN_LOADER='), isTrue,
          reason: '第 2 层：能跑 x64 动态链接器');
      expect(s.contains('QEMU_CHAIN_PROBE='), isTrue,
          reason: '第 3 层：能跑真实 x64 程序');
      expect(s.contains('QEMU_CHAIN_SRC='), isTrue,
          reason: '第 4 层：转发目标仍是 x86_64 ELF（排除被覆盖）');
    });

    test('探针优先用 impellerc（真机实际崩的那个工具）', () {
      const s = QemuCompat.buildPreflightScript;
      final imp = s.indexOf('linux-arm64/impellerc');
      final gs = s.indexOf('android-arm64-release/linux-arm64/gen_snapshot');
      expect(imp, greaterThan(0));
      expect(gs, greaterThan(0));
      expect(imp < gs, isTrue, reason: 'impellerc 是主崩溃点，应优先探测');
    });

    test('必须区分信号退出码（SIGILL=132 / SIGSEGV=139）', () {
      const s = QemuCompat.buildPreflightScript;
      expect(s.contains('132) s=SIGILL'), isTrue,
          reason: '132 = 128+4，即 SIGILL（exit -4 的真身）');
      expect(s.contains('139) s=SIGSEGV'), isTrue);
      expect(s.contains('EMPTY_OUTPUT'), isTrue,
          reason: 'rc=0 但无输出也要单独标记（另一种异常）');
    });

    test('status 捕获不能过管道（否则拿到的是 head 的退出码）', () {
      const s = QemuCompat.buildPreflightScript;
      // 反例：out=$(cmd | head -2); rc=$?  → rc 是 head 的
      expect(
        RegExp(r'out=\$\([^)]*\|[^)]*\)\s*\n\s*rc=\$\?').hasMatch(s),
        isFalse,
        reason: '管道会吞掉真实退出码，必须写临时文件再读',
      );
      expect(s.contains(r': > "$tf"'), isTrue, reason: '用临时文件承接输出');
      // Bug 445：探针改为在 /tmp 沙盒目录里跑（原来直接在真实转发位目录
      // 里跑 `--help`，产物会覆盖转发脚本本身——诊断把被测对象弄坏了）。
      // rc 仍必须紧邻真正的命令捕获。
      expect(
        RegExp(r'\( cd "\$probe_dir" && "\$pt" --help \) > "\$tf" 2>&1'
                r'\s*\n\s*rc=\$\?')
            .hasMatch(s),
        isTrue,
        reason: 'rc 必须紧邻真正的命令捕获',
      );
      // 反向断言：不许退回"直接在转发位目录里跑"的写法
      expect(
        RegExp(r'"\$tool" --help > "\$tf" 2>&1').hasMatch(s),
        isFalse,
        reason: 'Bug 445：探针必须在 /tmp 沙盒里跑，'
            '否则 --help 的产物会覆盖真实转发位',
      );
      expect(s.contains('probe_dir'), isTrue,
          reason: 'Bug 445：必须有临时沙盒目录承接产物');
    });

    test('LOADER 的 rc 也要紧邻捕获（同样不能放进 if 条件里）', () {
      const s = QemuCompat.buildPreflightScript;
      expect(RegExp(r'--version > /dev/null 2>&1\s*\n\s*lrc=\$\?').hasMatch(s),
          isTrue);
      expect(s.contains(r'[ "$lrc" = 0 ]'), isTrue);
    });

    test('诊断失败不得阻断构建（它只是观测，不是门禁）', () {
      const s = QemuCompat.buildPreflightScript;
      expect(s.contains('exit 0'), isTrue);
      expect(RegExp(r'exit\s+[1-9]').hasMatch(s), isFalse,
          reason: '预检只是产出事实，绝不能因为自己失败就挡住构建');
    });

    test('无 qemu 时安静退出（termux 后端不经 qemu）', () {
      const s = QemuCompat.buildPreflightScript;
      expect(s.contains('QEMU_CHAIN_NONE=1'), isTrue);
    });
  });
}
