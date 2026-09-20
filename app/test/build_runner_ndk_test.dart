import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/build_runner.dart';

/// Bug 427 固化：sdkmanager SIGILL（exit 132）分诊识别。
///
/// 背景（2026-09-18 真机 alpha.37）：Bug 426 修好后构建推进到 24% 配置
/// Gradle，报 `Process 'command '.../sdkmanager'' finished with non-zero
/// exit value 132`。根因：Flutter gradle 插件 `forceNdkDownload()` 在项目
/// ndkVersion 不在已装列表时主动调 sdkmanager 补装 NDK，而 sdkmanager
/// 在 Android arm64 上启 JVM 触发 JIT SIGILL（132 = 128 + 4）。
///
/// 修复：构建前写 NDK 占位（ndk/<version>/source.properties）使插件判定
/// "已装"直接跳过。此处固化分诊文案——沙箱出包不走 BuildRunner，真机
/// 日志识别只能靠 hint 表。
void main() {
  group('BuildRunner · Bug 427 sdkmanager SIGILL 分诊', () {
    test('识别 exit value 132 → 指向 NDK 占位修复', () {
      final r = BuildRunner.I..hints.clear();
      r.debugFeedForTest(
          "> Process 'command '/opt/android-sdk/cmdline-tools/latest/bin/"
          "sdkmanager'' finished with non-zero exit value 132");
      expect(
        r.hints.any((h) => h.contains('exit 132') && h.contains('NDK')),
        isTrue,
        reason: '真机 exit 132 必须给出 NDK 占位方向的引导',
      );
    });

    test('识别 sigill 关键字（大小写不敏感）', () {
      final r = BuildRunner.I..hints.clear();
      r.debugFeedForTest('terminated with the SIGILL signal');
      expect(r.hints.any((h) => h.contains('Bug 427')), isTrue);
    });
  });
}
