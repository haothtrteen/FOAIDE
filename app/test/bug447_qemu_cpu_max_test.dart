// Bug 447（alpha.53）：qemu TCG 按 CPU 模型特性位门控 SIMD 指令。
//
// 现象：真机（arm64 host）AOT 57% `exit -4`（SIGILL），转发层全程完好、
// 内存充足、glibc 齐全——五个假设全部被实验证伪后仍崩。
//
// 沙箱复现（与真机逐位同版的 Debian qemu 7.2 `7.2+dfsg-7+deb12u18+b3`）：
//   - 默认参数跑裸 AVX 程序（vpxor/vpshufb，无 CPUID 保护）→ rc=42 通过
//   - `-cpu qemu64` 跑同一程序 → **rc=132 = SIGILL**（与真机 exit -4 逐位一致）
//   - `-cpu max` 跑 → rc=42 通过
//   - CPUID 探针：x86 host 默认模型 AVX=1/AVX2=1（= max 行为）
//   - 真机同链路（-L / + ld.so 显式加载）→ rc=134 业务报错，非 SIGILL
//   - bookworm glibc 2.36 全链路 → rc=134，avxtest rc=42（glibc 无关）
//
// 机制：qemu TCG 翻译 VEX 指令时检查 CPU 模型的特性位（gen_illegal_opcode），
// CPUID 不含 AVX → 一执行到 gen_snapshot 里的 10 种裸 AVX 指令
// （vpxor/vpshufb/vmovdqa/vmovdqu/vpaddd/vpalignr/vpshufd/vpslld/vpsrld/
// vpsrlq/vzeroupper，objdump 全量清点，无 AVX2/AVX-512）就 SIGILL。
// x86_64 host 的 qemu-user 默认模型含 AVX；arm64 host 构建包默认行为不同。
//
// 修复：转发 exec 行显式 `-cpu max`（暴露 TCG 支持的特性全集）。
// 附带修复：AOT_LOAD 探针找 app.dill 的 glob 只探两层，真机 dill 在
// build/app/intermediates/flutter/release/（四层深）→ alpha.52 真机日志
// `AOT_LOAD=skip(尚无 app.dill)` 实为探针盲区，改 find 深探。
import 'package:flutter_on_android/toolchain/qemu_compat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Bug 447 · 转发 exec 行必须带 -cpu max', () {
    // 注意：exec 行在 gen() 片段（_wrapGenFunc）里，只有含 __FOA_GEN__
    // 占位的脚本（engineWrapScript / wrapReassertScript 等）经 fill() 后
    // 才带 exec 行；buildPreflightScript 不含 gen 片段，不能拿来断言 exec。
    const script = QemuCompat.engineWrapScript;

    test('gen() 片段生成的 exec 行是 -cpu max 形态', () {
      final f = QemuCompat.fill(script);
      // 带 ld.so 的主路径
      final main = f.indexOf(
          'exec ${QemuCompat.qemuBin} -cpu max -L / "${QemuCompat.x64Loader}"');
      expect(main, greaterThan(0),
          reason: r'exec 行应为「qemu -cpu max -L / <ld.so> <real> "$@"」');
      // 回归哨兵（Bug 443 教训：indexOf -1 时 greaterThan(-1) 恒真）
      expect(f.contains('exec ${QemuCompat.qemuBin} -cpu max'), isTrue);
    });

    test('wrapReassertScript 生成的 exec 行同样带 -cpu max', () {
      final f = QemuCompat.fill(QemuCompat.wrapReassertScript);
      expect(
        f.contains('exec ${QemuCompat.qemuBin} -cpu max -L /'),
        isTrue,
        reason: '两条 exec 行都必须显式 -cpu max，不能只改主路径',
      );
    });

    test('不能退回无 -cpu 的旧形态', () {
      final f = QemuCompat.fill(script);
      // 旧形态：exec ...qemu-x86_64... -L / 且行内无 -cpu max。
      // 用负向断言锁死：任何 `exec @QEMU@ -L /`（-cpu 缺席）都不允许。
      final lines = f.split('\n');
      for (final l in lines) {
        if (l.trimLeft().startsWith('#')) continue; // 剥掉注释
        if (l.contains('exec ${QemuCompat.qemuBin}') &&
            l.contains('-L /') &&
            !l.contains('-cpu max')) {
          fail('发现无 -cpu max 的 exec 行：$l');
        }
      }
    });
  });

  group('Bug 447 · AOT_LOAD 探针必须深探 app.dill', () {
    const script = QemuCompat.buildPreflightScript;

    test('dill 查找用 find（-maxdepth 6），不再用两层 glob', () {
      // 直接对原文断言（脚本是 const，不做 fill——@PROJ@ 展开不影响 find 行）
      expect(script.contains(r'find "$bd" -maxdepth 6 -name app.dill -type f'),
          isTrue,
          reason: 'app.dill 在 build/app/intermediates/flutter/release/ 四层深');
    });

    test('旧的两层 glob 写法必须消失', () {
      // 旧写法：ls "$bd"/app.dill "$bd"/[a-z]*/app.dill —— 只探两层，探针盲区
      final lines = script.split('\n');
      for (final l in lines) {
        if (l.trimLeft().startsWith('#')) continue;
        expect(l.contains(r'"$bd"/[a-z]*/app.dill'), isFalse,
            reason: '两层 glob 是 Bug 447 病灶，不允许回归：$l');
      }
    });

    test('必须带默认模型对照探针 AOT_LOAD_DEF（裸 qemu，不带 -cpu）', () {
      // 裁决探针：AOT_LOAD 走 wrapper（-cpu max），DEF 绕过 wrapper 裸跑。
      // 并排两个 rc 才能在真机日志上直接裁决「默认模型门控」假设。
      expect(script.contains('AOT_LOAD_DEF=rc='), isTrue);
      expect(script.contains(r'AOT_LOAD_DEF=SIGILL'), isTrue,
          reason: '132 分支必须显式打出门控语义，别让人再猜');
      // DEF 必须绕过 wrapper：直接 qemu + ld.so + 真身（linux-x64）。
      // 回归哨兵：indexOf -1 恒真的坑（Bug 443）。
      final i = script.indexOf(
          r'@QEMU@ -L / @LOADER@ "$dgs" --deterministic');
      expect(i, greaterThan(0),
          reason: 'DEF 探针必须是裸 qemu 形态（不经 wrapper）');
    });
  });
}
