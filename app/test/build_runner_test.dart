import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/build_runner.dart';

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

  group('BuildRunner · Built 后宽限收尾（alpha.58，真机 95% 卡住判读）', () {
    // 真机实证（2026-09-19 22:06 截图）：日志已打印
    // `✓ Built build/app/outputs/flutter-apk/app-release.apk (15.0MB)`
    // ——Built 在 Gradle 打包+签名完成之后打印，构建本体已成功——
    // 但 flutter 工具偶发 hang 不退出，running 恒真，UI 永远停在
    // 「打包与签名 APK 95%」。修复：Built 命中后宽限 90s 强制按成功收尾。
    test('builtMarker 与真实 flutter 输出对齐（Build 行前缀）', () {
      // flutter 输出形如 `✓ Built build/app/outputs/flutter-apk/app-release.apk (15.0MB)`
      expect('✓ ${BuildRunner.builtMarker}-apk/app-release.apk (15.0MB)',
          contains(BuildRunner.builtMarker));
    });

    test('未命中 Built 行 → 永不强制收尾', () {
      expect(
        BuildRunner.builtGraceElapsed(builtAt: null, now: DateTime.now()),
        isFalse,
      );
    });

    test('命中 Built 行但未超宽限期 → 不收尾（给 flutter 留足收尾时间）', () {
      final now = DateTime.now();
      // alpha.97：宽限期从 90 收紧到 20，断言跟着改到 19s
      expect(
        BuildRunner.builtGraceElapsed(
            builtAt: now.subtract(const Duration(seconds: 19)), now: now),
        isFalse,
      );
    });

    test('命中 Built 行超过宽限期 → 强制按成功收尾', () {
      final now = DateTime.now();
      expect(
        BuildRunner.builtGraceElapsed(
            builtAt: now.subtract(const Duration(seconds: 21)), now: now),
        isTrue,
      );
    });

    test('宽限期常量合理（alpha.97 收紧到 20s，兜底而非每次必等）', () {
      // alpha.97 把收尾判据从「纯计时」升级成「双证据自适应」：
      // 产物稳定确认成立就立刻收尾，这个常量只作探测失败时的上限。
      // 因此从 90 收紧到 20 —— 真机实测 flutter 收尾 <5s。
      expect(BuildRunner.builtGraceSec, 20);
    });
  });

  group('alpha.97 · Built 后自适应收尾（产物双证据确认）', () {
    // 真机现象：用户确认「每次都干等满 90s」。根因不是 90s 本身太大，
    // 而是**判据只有计时、没有证据** —— 只要 flutter 进程 hang 不退出，
    // 就一定等满。改成「产物读数连续两次一致就立刻收尾」后，典型路径
    // 从 90s 降到 1~3s。
    final now = DateTime.now();
    final built = now.subtract(const Duration(seconds: 3));

    test('只探测一轮（无上一次读数）→ 不收尾，先记状态', () {
      expect(
        BuildRunner.builtSettled(
          builtAt: built,
          now: now,
          size: 88000000,
          mtime: 1000,
          prevSize: -1,
          prevMtime: -1,
          lastProbeAt: null,
        ),
        isFalse,
      );
    });

    test('两次读数完全一致且间隔足够 → 确认落盘，立刻收尾', () {
      expect(
        BuildRunner.builtSettled(
          builtAt: built,
          now: now,
          size: 88000000,
          mtime: 1000,
          prevSize: 88000000,
          prevMtime: 1000,
          lastProbeAt: now.subtract(const Duration(seconds: 3)),
        ),
        isTrue,
      );
    });

    test('大小仍在变 → 说明还在写盘，不收尾（宁可慢也别出错）', () {
      expect(
        BuildRunner.builtSettled(
          builtAt: built,
          now: now,
          size: 88100000,
          mtime: 1001,
          prevSize: 88000000,
          prevMtime: 1000,
          lastProbeAt: now.subtract(const Duration(seconds: 3)),
        ),
        isFalse,
      );
    });

    test('mtime 变了（同大小重写）→ 同样不收尾', () {
      expect(
        BuildRunner.builtSettled(
          builtAt: built,
          now: now,
          size: 88000000,
          mtime: 1001,
          prevSize: 88000000,
          prevMtime: 1000,
          lastProbeAt: now.subtract(const Duration(seconds: 3)),
        ),
        isFalse,
      );
    });

    test('两次探测挨太近 → 读数一致没有信息量，不收尾', () {
      expect(
        BuildRunner.builtSettled(
          builtAt: built,
          now: now,
          size: 88000000,
          mtime: 1000,
          prevSize: 88000000,
          prevMtime: 1000,
          // 间隔 0s < builtStableProbeSec（2s）
          lastProbeAt: now,
        ),
        isFalse,
      );
    });

    test('size 为 0（目录项已建、内容未写）→ 不收尾', () {
      expect(
        BuildRunner.builtSettled(
          builtAt: built,
          now: now,
          size: 0,
          mtime: 1000,
          prevSize: 0,
          prevMtime: 1000,
          lastProbeAt: now.subtract(const Duration(seconds: 3)),
        ),
        isFalse,
      );
    });

    test('未命中 Built 行 → 探测永不成立', () {
      expect(
        BuildRunner.builtSettled(
          builtAt: null,
          now: now,
          size: 88000000,
          mtime: 1000,
          prevSize: 88000000,
          prevMtime: 1000,
          lastProbeAt: now.subtract(const Duration(seconds: 3)),
        ),
        isFalse,
      );
    });

    test('探测间隔常量 = 2s（稳定性判据的最小观测窗）', () {
      expect(BuildRunner.builtStableProbeSec, 2);
    });
  });

  group('alpha.97 · 前置检查合并 + pub get 指数退避', () {
    test('proot：Flutter 存在性检查并入主 shell，且在最前', () {
      final cmd = BuildRunner.buildCommand(
        proj: "'/root/projects/x'",
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
        prootFlutterProbeNeeded: true,
      );
      expect(cmd.contains('FOA_PREFLIGHT_NOFLUTTER=1'), isTrue);
      expect(cmd.contains('test -x /opt/flutter/bin/flutter'), isTrue);
      expect(cmd.contains('exit 65'), isTrue);
      // 位置：必须在 stampFix（第一个 sh -c）之前
      expect(
        cmd.indexOf('test -x /opt/flutter/bin/flutter') <
            cmd.indexOf('flutter_version_check.stamp'),
        isTrue,
        reason: '缺 SDK 时应最先退出，不浪费后面的诊断时间',
      );
    });

    test('termux：不带 proot 专用探测，且 stamp 目录跟随后端', () {
      // 这条测试在 alpha.97 撞出一个**真 bug**：
      // stampFix 的 `@CACHE@` 原先写死 `${QemuCompat.flutterHome}/bin/cache`
      // （容器路径）。termux 后端的 Flutter 在 prefix 下，于是每次构建都
      // 往一个不存在的容器路径写 stamp，真正的 cache 目录从没被刷新过
      // —— Bug 436 想省的 `git fetch --tags` 在 termux 后端从未省掉。
      // 断言先立在这，代码再跟上（见 buildCommand 的 cacheDir 参数）。
      const flHome = '/data/data/com.termux/files/usr/opt/flutter';
      final cmd = BuildRunner.buildCommand(
        proj: "'/x/rootfs/root/projects/y'",
        flutterCmd: "'$flHome/bin/flutter'",
        envPart: 'LD_PRELOAD=/x/libtermux-exec.so ',
        aapt2Override: '',
        cacheDir: '$flHome/bin/cache',
      );
      expect(cmd.contains('FOA_PREFLIGHT_NOFLUTTER=1'), isFalse);
      expect(cmd.contains('test -x /opt/flutter/bin/flutter'), isFalse);
      // stamp 必须指向 termux 自己的 cache，而不是容器路径
      expect(cmd.contains('C=$flHome/bin/cache'), isTrue);
      expect(cmd.contains('C=/opt/flutter/bin/cache'), isFalse);
    });

    test('pub get 退避：1s → 3s，且不再有固定 sleep 3', () {
      final cmd = BuildRunner.buildCommand(
        proj: "'/root/projects/x'",
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(cmd.contains('b=1;'), isTrue);
      expect(cmd.contains(r'sleep $b; b=3;'), isTrue);
      // 旧写法必须彻底消失：固定 sleep 3 在 3 源 × 2 次下最坏纯等 18s
      expect(
        cmd.contains('sleep 3;'),
        isFalse,
        reason: '固定 sleep 3 应已被退避循环取代',
      );
    });

    test('退避不牺牲重试次数与源轮换（三源两试结构完整）', () {
      final cmd = BuildRunner.buildCommand(
        proj: "'/root/projects/x'",
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(cmd.contains('for i in 1 2; do'), isTrue);
      expect(cmd.contains('break 2'), isTrue);
      expect(cmd.contains('exit 69'), isTrue);
      // 换源时退避重置回 1s → b=1 必须在 for src 循环体内、for i 之前
      expect(
        cmd.indexOf('b=1;') < cmd.indexOf('for i in 1 2; do'),
        isTrue,
        reason: 'b=1 必须在换源时重新赋值，否则第 2 源会继承 3s',
      );
    });

    test('脚本内嵌路径必须后端感知（防回退到容器路径）', () {
      // 这条测试固化 alpha.97 撞出的一个**静默 bug**：diag / heal /
      // reassert / stampFix 四段脚本的路径原先全部写死容器值
      // （/opt/flutter、/opt/android-sdk）。termux 后端的 Flutter 与
      // SDK 在 prefix 下，路径错的表现是**整段脚本静默短路**
      // （`[ -d "$E" ] || exit 0`），日志里连一行提示都没有。
      // 断言：传 termux 路径时，命令里不得再出现容器前缀的赋值。
      const fl = '/data/data/com.termux/files/usr/opt/flutter';
      const px = '/data/data/com.termux/files/usr';
      final cmd = BuildRunner.buildCommand(
        proj: "'/x/rootfs/root/projects/y'",
        flutterCmd: "'$fl/bin/flutter'",
        envPart: '',
        aapt2Override: '',
        cacheDir: '$fl/bin/cache',
        flutterHome: fl,
        engineDir: '$fl/bin/cache/artifacts/engine',
        sdkHome: px,
      );
      // 四段脚本各自的变量赋值都必须是 termux 路径
      expect(cmd.contains('C=$fl/bin/cache'), isTrue);
      expect(cmd.contains('F=$fl'), isTrue);
      expect(cmd.contains('E=$fl/bin/cache/artifacts/engine'), isTrue);
      expect(cmd.contains('S=$px'), isTrue);
      // 反向断言：不能残留容器路径赋值（只看变量赋值形态，避免
      // 误伤注释文本）
      for (final k in ['C', 'F', 'E', 'S']) {
        expect(
          RegExp('$k=/opt/(flutter|android-sdk)').hasMatch(cmd),
          isFalse,
          reason: '$k 仍指向容器路径 → 该段脚本会静默短路',
        );
      }
    });

    test('默认参数保持 proot 语义（既有调用方不受影响）', () {
      final cmd = BuildRunner.buildCommand(
        proj: "'/root/projects/x'",
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(cmd.contains('C=/opt/flutter/bin/cache'), isTrue);
      expect(cmd.contains('F=/opt/flutter'), isTrue);
      expect(
        cmd.contains('E=/opt/flutter/bin/cache/artifacts/engine'),
        isTrue,
      );
      expect(cmd.contains('S=/opt/android-sdk'), isTrue);
    });
  });
}
