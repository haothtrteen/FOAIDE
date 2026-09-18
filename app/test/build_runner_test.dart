import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_on_android/toolchain/build_runner.dart';

/// Bug 424 固化：buildCommand 的 shell 变量 / Dart 插值转义边界。
///
/// 背景（alpha.33 真机实翻车）：循环体里把 `\$flutterCmd` 误转义成 shell
/// 变量，shell 展开为空 → 命令变成 `pub get` 裸跑 → `pub: not found` ×6
/// （3 源 × 2 次）→ exit 69。沙箱出包不走 BuildRunner，analyze/test 都
/// 覆盖不到 shell 运行时行为——只能靠这里的**文本断言**拦住回归。
void main() {
  group('BuildRunner.buildCommand · Bug 424 转义边界', () {
    test('proot 后端：flutter 必须以字面形式出现，不得残留 shell 变量引用', () {
      final cmd = BuildRunner.buildCommand(
        proj: "'/root/projects/my_demo'",
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      // 任何 shell 层的 $flutterCmd 引用都是 Bug 424 复发
      expect(cmd.contains(r'\$flutterCmd'), isFalse,
          reason: '\$flutterCmd 在 shell 展开为空 → pub: not found');
      expect(cmd.contains('flutter pub get'), isTrue);
      expect(cmd.contains('flutter build apk'), isTrue);
      expect(cmd.contains('cd \'/root/projects/my_demo\' && '), isTrue);
    });

    test('termux bare 后端：带引号绝对路径同样插入 pub get 与 build', () {
      const fl = "'/data/termux/files/usr/opt/flutter/bin/flutter'";
      final cmd = BuildRunner.buildCommand(
        proj: "'/data/termux/files/home/rootfs/root/projects/my_demo'",
        flutterCmd: fl,
        envPart: 'LD_PRELOAD=/x/libtermux-exec.so ',
        aapt2Override: " -Pandroid.aapt2FromMavenOverride='/x/aapt2'",
      );
      expect(cmd.contains(r'\$flutterCmd'), isFalse);
      expect(cmd.contains('$fl pub get'), isTrue);
      expect(cmd.contains('$fl build apk'), isTrue);
      expect(cmd.contains('aapt2FromMavenOverride'), isTrue);
    });

    test('shell 循环变量必须保留转义（值在 shell 层产生）', () {
      final cmd = BuildRunner.buildCommand(
        proj: '/root/projects/x',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      // 输出文本必须是 shell 变量形式 $src/$ok（Dart 源码里的 \$_ 转义
      // 只是不让 Dart 插值，输出无反斜杠）——若被 Dart 插值，轮换与
      // 成功判断会静默失效（buildCommand 无同名参数，编译期已拦一层，
      // 这里再固化输出文本形态）
      expect(cmd.contains(r'$src'), isTrue);
      expect(cmd.contains(r'$ok'), isTrue);
      // 三源两试结构完整
      expect(cmd.contains('https://pub.flutter-io.cn'), isTrue);
      expect(cmd.contains('mirrors.tuna.tsinghua.edu.cn/dart-pub'), isTrue);
      expect(cmd.contains('mirrors.ustc.edu.cn/dart-pub'), isTrue);
      expect(cmd.contains('exit 69'), isTrue);
    });

    test('迭代包带 --no-shrink（双轨策略：最终发布包才用 R8）', () {
      final cmd = BuildRunner.buildCommand(
        proj: '/root/projects/x',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(cmd.contains('build apk --no-shrink --release'), isTrue);
      expect(cmd.contains('--target-platform=android-arm64'), isTrue);
    });
  });
}
