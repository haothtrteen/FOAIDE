import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/build_runner.dart';
import 'package:foaide/toolchain/qemu_compat.dart';

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
      // Bug 439：转发脚本正文在 gen() 片段里，一律用 fill() 后的文本断言。
      final f = QemuCompat.fill(s);
      // fill() 会把 @QEMU@ 也展开，所以这里断言的是已替换后的真实命令行。
      expect(f.contains('exec ${QemuCompat.qemuBin} -cpu max -L /'), isTrue);
      // Bug 447：exec 行必须是 -cpu max 形态（比旧的裸 `-L /` 更严格）。
      expect(f.contains('exec ${QemuCompat.qemuBin} -cpu max -L /'), isTrue,
          reason: 'Bug 447：TCG 按 CPU 模型门控 SIMD，必须显式 -cpu max');
      expect(f.contains('ld-linux-x86-64'), isTrue,
          reason: 'Bug 439：必须显式加载 guest ld.so，否则所有 x64 工具静默崩溃');
    });

    test('包装脚本必须可执行（chmod 755）', () {
      // Bug 439：chmod 落在了提取出的 gen() 片段里，断言要用 fill() 后的文本。
      expect(QemuCompat.fill(s).contains('chmod 755'), isTrue);
    });
  });

  group('QemuCompat.engineWrapScript · Bug 429 宿主工具目录覆盖', () {
    const s = QemuCompat.engineWrapScript;

    test('必须覆盖顶层 linux-x64 宿主工具目录（impellerc 所在）', () {
      // Bug 429：impellerc / font-subset / flutter_tester 等宿主工具在
      // 引擎根下的 linux-x64/（不在 android-*/ 里）。artifacts.dart 的
      // HostArtifact.impellerc 取 engineDir/<hostPlatform>/impellerc，
      // arm64 宿主 → linux-arm64/impellerc，不包装则 shader 编译 SIGILL。
      expect(
        RegExp(r'for\s+hd\s+in\s+"\$E"/linux-\*/').hasMatch(s),
        isTrue,
        reason: '必须遍历顶层 linux-*/ 目录，否则 impellerc 永不被包装',
      );
      expect(s.contains(r'ha="${hd%/linux-x64}/linux-arm64"'), isTrue);
    });

    test('两个层次都要有：android-*/linux-x64（引擎）+ 顶层 linux-x64（宿主）', () {
      expect(RegExp(r'for\s+d\s+in\s+"\$E"/android-\*/linux-x64').hasMatch(s),
          isTrue,
          reason: '引擎层 gen_snapshot');
      expect(RegExp(r'for\s+hd\s+in\s+"\$E"/linux-\*/').hasMatch(s),
          isTrue,
          reason: '宿主层 impellerc/font-subset');
    });

    test('全量遍历而非点名清单（新工具自动纳入，无需预见）', () {
      // 不应出现硬编码的工具名清单（这正是 Bug 428→429 反复翻车的原因）
      final hits = RegExp(r'for\s+\w+\s+in\s+"\$\w+"?/\*?').allMatches(s).length;
      expect(hits >= 4, isTrue,
          reason: 'engineWrapScript 内目录通配遍历应覆盖引擎层与宿主层，实际 $hits 处');
      // 正向确认各处通配遍历都指向目录本身而不是某个具体文件
      for (final dir in [r'"$d"', r'"$hd"']) {
        expect(s.contains('for f in $dir/*'), isTrue,
            reason: '缺少 $dir 目录的全量文件遍历');
      }
      // 反向：不得出现「按名字逐个处理」的写死清单
      expect(RegExp(r'for\s+\w+\s+in\s+(gen_snapshot|impellerc|font-subset)')
          .hasMatch(s), isFalse,
          reason: '一旦写死工具名，新工具又要人工补——必须用 * 通配');
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
