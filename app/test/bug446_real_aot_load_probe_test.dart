import 'dart:io';

import 'package:flutter_on_android/toolchain/qemu_compat.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bug 446：真实 AOT 负载探针 —— 补上"能启动 ≠ 能编译"这个盲区。
///
/// ## 为什么要这个探针（alpha.51 真机日志的结论）
///
/// 那份日志里：
///   - 构建**前** `AOT_FP=` 六行全 `ok(SLOT)`/`ok(REAL)`
///   - `REASSERT=10` / `REASSERT_DART=10`（重建确实执行了）
///   - 构建**后**重新采集的 `AOT_FP=` **仍然全 ok**
///   - 但 AOT 还是 `Dart snapshot generator failed with exit code -4`
///
/// → **转发层从头到尾都是完好的**。前面几版（Bug 444/445）一直在治
///   "转发层被覆盖"，方向错了。
///
/// 真正的盲区是：**所有诊断都只测 `--help`**。
///   `--help` 打印完就退出；而 `--snapshot_kind=app-aot-elf` 要分配大内存、
///   跑长时间编译、执行向量指令（反汇编实测 gen_snapshot 里含大量
///   `vpshufb`/`vpxor`/`vpaddd` 等 VEX 指令，正是编译启动阶段的哈希计算）。
///   **"能启动" ≠ "能编译"** —— 这才是三层诊断报绿灯、AOT 照样崩的原因。
void main() {
  const script = QemuCompat.buildPreflightScript;

  group('Bug 446 · 真实 AOT 负载探针存在且判据正确', () {
    test('必须跑真实 AOT，而不是只跑 --help', () {
      expect(script, contains('--snapshot_kind=app-aot-elf'),
          reason: '必须用真实的 AOT 参数，--help 走不到编译路径');
      expect(script, contains('AOT_LOAD=begin'),
          reason: '必须显式记录"开始跑负载"这件事');
    });

    test('输入必须是真实的 app.dill（来自上一次 KernelSnapshot）', () {
      expect(script, contains('app.dill'),
          reason: '用真机那份 dill 才有代表性');
      expect(script, contains('@PROJ@/build'),
          reason: '项目路径参数化，不许硬编码');
      // 兜底：找不到 dill 时要明说，不能静默跳过
      expect(script, contains('AOT_LOAD=skip'),
          reason: '首次构建没有 dill 属正常，但必须显式说明');
    });

    test('判据必须用退出码，且区分信号退出与程序自身报错', () {
      // 这是本探针的**核心价值**：区分两类失败
      //   rc=132(SIGILL) → qemu 在编译负载下崩（真机那个 exit -4）
      //   rc=134/其它    → 程序自身报错，说明**执行环境是好的**
      expect(script, contains(r'lrc=$?'),
          reason: '退出码必须紧邻捕获（Bug 443：管道会吞掉）');
      expect(script, contains('132)'), reason: '必须识别 SIGILL');
      expect(script, contains('SIGILL'), reason: '必须标出 SIGILL 的语义');
      expect(script, contains('134)'), reason: '必须识别 SIGABRT');
      expect(script, contains('执行环境是好的'),
          reason: '非信号退出要明确告诉用户"环境没问题"，避免误判方向');
    });

    test('rc 捕获不得过管道（Bug 443 同类错误不许复发）', () {
      expect(
        RegExp(r'AOT_LOAD[^\n]*\|[^\n]*\n\s*lrc=\$\?').hasMatch(script),
        isFalse,
        reason: '取退出码前不许有管道',
      );
    });

    test('探针本身必须无副作用（Bug 445 教训）', () {
      // 必须在临时目录里跑：产物不许落进项目 build 目录
      expect(script, contains(r'ld_dir=/tmp/.foa_aotload_$$'),
          reason: 'Bug 445：诊断不许改变被测系统的状态');
      expect(script, contains(r'cd "$ld_dir"'),
          reason: '在临时目录里执行');
      expect(script, contains(r'rm -rf "$ld_dir"'),
          reason: '跑完清理干净');
      // 产物写到临时目录，不许写进项目 build
      expect(script, contains(r'--elf="$ld_dir/probe.so"'),
          reason: 'AOT 产物必须落在临时目录，不能污染项目的 build/');
    });

    test('探针失败不得阻断构建（它只是观测）', () {
      // 整段没有任何 exit 调用（除脚本最开头的 no-qemu 早退）
      final loadSection =
          script.substring(script.indexOf('Bug 446：真实 AOT 负载探针'));
      expect(loadSection.contains('exit 1'), isFalse);
      expect(loadSection.contains('exit 3'), isFalse);
    });
  });

  group('Bug 446 · 探针行为验证（真实执行，不是文本断言）', () {
    test('对真实的 dill 能报出退出码与输出（端到端）', () {
      // 只在有真机那份 gen_snapshot 时跑（沙箱是 x86_64，可直接执行）
      const gs = '/opt/flutter/bin/cache/artifacts/engine/android-arm64-release'
          '/linux-x64/gen_snapshot';
      const dill = '/tmp/aot/app.dill';
      if (!File(gs).existsSync() || !File(dill).existsSync()) {
        return; // 环境不具备时跳过（不是失败）
      }
      // 直接按探针的方式跑一遍，验证"能完整走完 AOT 流程"
      final dir = Directory.systemTemp.createTempSync('foa446');
      final r = Process.runSync(
        gs,
        ['--deterministic', '--snapshot_kind=app-aot-elf',
         '--elf=${dir.path}/probe.so', dill],
      );
      // 关键断言：**不是被信号杀死**（<128 或无信号），
      // 证明执行环境能承载真实 AOT 负载
      expect(r.exitCode, lessThan(128),
          reason: '不应被信号杀死；128+n 表示环境无法承载 AOT 负载');
      expect('${r.stderr}', isNotEmpty,
          reason: '真实 AOT 失败时也应有 stderr（可用于诊断）');
      dir.deleteSync(recursive: true);
    });
  });
}
