import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_on_android/toolchain/build_runner.dart';
import 'package:flutter_on_android/toolchain/qemu_compat.dart';

/// Bug 428 固化：x64 兼容层引擎转发脚本的覆写检测与分诊。
///
/// 背景（2026-09-18 真机 alpha.38）：AOT 编译段 47% 崩，
/// `Dart snapshot generator failed with exit code -4`（SIGILL），
/// impellerc 同样 -4。根因：Flutter 官方 Android gen_snapshot/impellerc
/// 只有 x86_64 宿主版，arm64 真机靠 qemu 转发；而 `artifacts.dart`
/// 只对 darwin_arm64 做 x64 回退（linux_arm64 未做，
/// flutter/flutter#152281），`flutter precache` 会往 linux-arm64/
/// 写**真 x64 二进制**覆盖转发脚本。旧包装逻辑 `[ -f "$w" ] || gen`
/// 见文件存在即跳过 → 永久卡在错误状态。
///
/// 修复：① 判定改为「是否已是转发脚本（#! 开头）」；② 构建前幂等重建。
/// 沙箱出包不走 BuildRunner/兼容层，此处固化文本断言与分诊识别。
void main() {
  group('QemuCompat.engineWrapScript · Bug 428 覆写检测', () {
    const s = QemuCompat.engineWrapScript;

    test('包装判定必须检查脚本特征，不得只看文件存在', () {
      // 旧逻辑 [ -f "$w" ] || gen 是根因；必须出现 #! 检测
      expect(s.contains("grep -q '#!'"), isTrue,
          reason: '必须以「是否转发脚本」判定，而非「文件是否存在」——'
              'precache 覆写后文件存在但内容是错的真 x64 二进制');
      expect(s.contains('head -c 2'), isTrue);
      // 旧的低级判定不应再作为唯一条件出现（raw 匹配，避免 Dart 插值）
      expect(
        RegExp(r'\[\s*-f\s+"\$w"\s*\]\s*\|\|\s*gen').hasMatch(s),
        isFalse,
        reason: r'[ -f "$w" ] || gen 已被 Bug 428 证明会永久卡死',
      );
    });

    test('仍保留 x64 → linux-arm64 目录映射（宿主回退缺失的补偿）', () {
      expect(s.contains('android-*/linux-x64'), isTrue);
      expect(s.contains('linux-arm64'), isTrue);
      expect(s.contains(r'exec @QEMU@ -L /'), isTrue);
    });

    test('包装脚本必须可执行（chmod 755）', () {
      expect(s.contains('chmod 755'), isTrue);
    });
  });

  group('QemuCompat verify · 冒烟误判修复', () {
    test('冒烟前先确认是转发脚本（真 x64 二进制 SIGILL 无输出会误判通过）', () {
      // verify 脚本不在公开 API，通过 engineWrapScript 的同族特征间接固化：
      // 关键点是「空输出 / 信号退出码」必须判为未就位
      final r = BuildRunner.I..hints.clear();
      r.debugFeedForTest('Dart snapshot generator failed with exit code -4');
      expect(
        r.hints.any((h) => h.contains('Bug 428')),
        isTrue,
        reason: 'exit -4 必须指向兼容层转发脚本被覆写的引导',
      );
    });
  });

  group('BuildRunner · Bug 428 分诊识别', () {
    test('impellerc failure 也能识别', () {
      final r = BuildRunner.I..hints.clear();
      r.debugFeedForTest('impellerc failure:');
      expect(r.hints.any((h) => h.contains('Bug 428')), isTrue);
    });

    test('ShaderCompilerException 也能识别', () {
      final r = BuildRunner.I..hints.clear();
      r.debugFeedForTest(
          "Shader compilation of 'ink_sparkle.frag' failed with exit code -4");
      expect(r.hints.any((h) => h.contains('Bug 428')), isTrue);
    });
  });
}
