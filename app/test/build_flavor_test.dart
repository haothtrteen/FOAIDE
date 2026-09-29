import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/env/models.dart';
import 'package:foaide/toolchain/build_progress.dart';
import 'package:foaide/toolchain/build_runner.dart';

/// alpha.93 构建类型（debug / release）固化。
///
/// 背景：设备端构建慢的**大头是 AOT**——`gen_snapshot` 官方只发 x86_64
/// 二进制，在手机容器里靠转译执行，慢 10~50 倍（真机实测卡在进度
/// 40~58%）。debug 档走 kernel（JIT）根本不调用 gen_snapshot，是唯一
/// 能显著提速的档位。
///
/// 这组测试守的是三件**编译期和 analyze 都抓不到**的事：
/// 1. 命令参数随档位变化（写死 `--release` 会让 debug 档静默失效）；
/// 2. debug 档不要跑 AOT 工具链预取（真机弱网下白等几分钟）；
/// 3. 产物定位要跟着档位走（debug/release 产物**会同时留在** outputs 里，
///    写死 app-release.apk 会让用户装上上一次的旧包）。
///
/// 另有一条负面结论的护栏（见末尾 group）：Gradle 配置缓存与 Flutter
/// 插件不兼容、build cache 对本场景零收益——这两条是沙箱实测出来的，
/// 别让后来者再走一遍。
void main() {
  group('BuildFlavor · 档位语义', () {
    test('release：走 AOT，产物 app-release.apk', () {
      expect(BuildFlavor.release.arg, 'release');
      expect(BuildFlavor.release.apkName, 'app-release.apk');
      expect(BuildFlavor.release.needsAot, isTrue);
    });

    test('debug：不走 AOT，产物 app-debug.apk', () {
      expect(BuildFlavor.debug.arg, 'debug');
      expect(BuildFlavor.debug.apkName, 'app-debug.apk');
      expect(BuildFlavor.debug.needsAot, isFalse,
          reason: 'debug 走 kernel（JIT），不调用 gen_snapshot——'
              '这是它快的全部原因');
    });

    test('默认档位是 release（加这个开关不改变既有行为）', () {
      // buildCommand 的默认参数必须仍是 release，否则老用户升级后
      // 默默从"能上架的包"变成"不能上架的包"，这是不能接受的静默变更。
      final cmd = BuildRunner.buildCommand(
        proj: '/p',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(cmd.contains('--release'), isTrue);
      expect(cmd.contains('--debug'), isFalse);
    });
  });

  group('BuildRunner.buildCommand · 档位差异', () {
    String cmd(BuildFlavor f) => BuildRunner.buildCommand(
          proj: '/root/projects/demo',
          flutterCmd: 'flutter',
          envPart: '',
          aapt2Override: '',
          flavor: f,
        );

    test('release 档：预取 AOT 工具链 + --release', () {
      final c = cmd(BuildFlavor.release);
      expect(c.contains('flutter precache --android_gen_snapshot'), isTrue);
      expect(c.contains('flutter build apk --no-shrink --release'), isTrue);
      expect(c.contains('--debug'), isFalse);
    });

    test('debug 档：--debug 且不预取 AOT 工具链', () {
      final c = cmd(BuildFlavor.debug);
      expect(c.contains('flutter build apk --no-shrink --debug'), isTrue);
      expect(c.contains('--release'), isFalse);
      expect(c.contains('precache --android_gen_snapshot'), isFalse,
          reason: 'debug 不用 gen_snapshot，预取它只会白白触发一轮构件下载');
    });

    test('两处 build 命令（含自愈重跑）都用同一个档位', () {
      // heal 分支里还有一次重跑，那里的档位写死是最容易漏的地方：
      // 它会让"自愈后的第二次构建"跑回 release，用户看着日志完全懵。
      for (final f in BuildFlavor.values) {
        final c = cmd(f);
        final hits = RegExp(
                r'flutter build apk --no-shrink --([a-z]+)')
            .allMatches(c)
            .map((m) => m.group(1))
            .toList();
        expect(hits.length, greaterThanOrEqualTo(2),
            reason: '构建命令本体 + heal 后的重跑，至少两处');
        expect(hits.toSet(), {f.arg},
            reason: '${f.name} 档下所有 build 命令必须同档位，实际：$hits');
      }
    });

    test('档位切换不影响 Bug 424 的转义边界', () {
      // 老回归：循环变量必须转义，Dart 插值不能转义。
      for (final f in BuildFlavor.values) {
        final c = cmd(f);
        expect(c.contains(r'\$flutterCmd'), isFalse);
        expect(c.contains('flutter pub get'), isTrue);
      }
    });
  });

  group('产物定位 · 跟着档位走', () {
    test('_locateApk 用 flavor.apkName，不再写死 app-release.apk', () {
      final src = File('lib/toolchain/build_runner.dart').readAsStringSync();
      // 这是加 debug 档时最阴的一条：debug 与 release 的产物会**同时**
      // 留在 build/app/outputs/flutter-apk/ 里（不会互相覆盖），写死
      // release 就会让"刚构建完 debug 包"却定位到上一次的 release 包。
      expect(src.contains("a.name == flavor.apkName"), isTrue,
          reason: '产物必须按本次会话的档位挑，不能写死 app-release.apk');
      expect(
          src.contains("if (a.name == 'app-release.apk')"),
          isFalse,
          reason: '写死的 app-release.apk 会让 debug 档定位到错误产物');
    });
  });

  group('进度映射 · debug 档没有 AOT 段', () {
    test('Gradle 阶段正则同时匹配 Release 与 Debug 变体', () {
      // 这条是加 debug 档时**实际漏掉**的 bug：原正则只写
      // mergeReleaseResources / compileReleaseKotlin / packageRelease /
      // assembleRelease，而 debug 构建产出的是 mergeDebugResources /
      // compileDebugKotlin / assembleDebug —— 一条都匹配不上，
      // 进度会从 40% 一路卡死到构建结束才突然 100%。
      void feed(String line, double expectAtLeast) {
        final t = BuildProgressTracker();
        t.feed(line);
        expect(t.stage.start, greaterThanOrEqualTo(expectAtLeast),
            reason: '「$line」必须被识别（debug 变体也得认）');
      }

      // debug 变体
      feed('> Task :app:mergeDebugResources', 0.58);
      feed('> Task :app:compileDebugKotlin', 0.72);
      feed('> Task :app:packageDebug', 0.86);
      feed('> Task :app:assembleDebug', 0.86);
      // release 变体（老行为不能坏）
      feed('> Task :app:mergeReleaseResources', 0.58);
      feed('> Task :app:compileReleaseKotlin', 0.72);
      feed('> Task :app:packageRelease', 0.86);
      feed('> Task :app:assembleRelease', 0.86);
    });

    test('skipAot：AOT 段被跳过且进度不出现空档', () {
      final t = BuildProgressTracker()..skipAot = true;
      // debug 档即便收到 AOT 关键词（不该发生，但防一手）也不该停在那段
      t.feed('Target android_aot_bundle_release_android_arm64');
      expect(t.stage, isNot(BuildStages.aot),
          reason: 'debug 档不该停在永不推进的 AOT 段上');

      final t2 = BuildProgressTracker()..skipAot = true;
      t2.feed('> Task :app:mergeDebugResources');
      // 拉伸后：resources 段的起点应从 0.58 回到 0.40（消掉 18% 空档）
      expect(t2.stage, BuildStages.resources);
      expect(t2.progress, lessThan(0.58),
          reason: 'skipAot 下 0.58~1.0 被拉伸到 0.40~1.0，'
              '否则进度条会在 40% 和 58% 之间跳一下');
      expect(t2.progress, greaterThanOrEqualTo(0.40));
    });

    test('不设 skipAot 时行为与以前完全一致', () {
      final t = BuildProgressTracker();
      t.feed('> Task :app:mergeReleaseResources');
      expect(t.stage, BuildStages.resources);
      expect(t.progress, greaterThanOrEqualTo(0.58));
    });
  });

  group('FlavorPrefs · 默认档位', () {
    /// EnvInfo 有多个 required 字段，这里只需要 filesDir。
    EnvInfo envOf(String filesDir) => EnvInfo(
          filesDir: filesDir,
          cacheDir: filesDir,
          nativeLibraryDir: filesDir,
          rootfsPath: filesDir,
          rootfsInstalled: true,
        );

    test('读不到就返回 debug（alpha.94 起默认档，不是 release）', () async {
      // 这一条在 alpha.93 时是反过来的（默认 release），alpha.94 用户明确
      // 要求改成默认 debug：日常改代码看效果不需要 AOT，而 AOT 的
      // gen_snapshot 在手机容器里是 QEMU 转译执行，慢 10~50 倍。
      // 代价（debug 包大、带 JIT、不能上架、不能覆盖安装正式版）
      // 必须在打包区的档位切换器旁如实写出，不能靠"默认"糊过去。
      expect(
          await FlavorPrefs.load(
              envOf('${Directory.systemTemp.path}/foa-flavor-none')),
          FlavorPrefs.fallback,
          reason: '默认档位与 FlavorPrefs.fallback 必须是同一个真源');
      expect(FlavorPrefs.fallback, BuildFlavor.debug,
          reason: 'alpha.94 起默认 debug');
    });

    test('release 仍然可选（默认 debug 不等于砍掉 release）', () async {
      final dir = Directory.systemTemp.createTempSync('foa-flavor-rel');
      await FlavorPrefs.save(envOf(dir.path), BuildFlavor.release);
      expect(await FlavorPrefs.load(envOf(dir.path)), BuildFlavor.release);
      dir.deleteSync(recursive: true);
    });

    test('写入后能读回', () async {
      final dir = Directory.systemTemp.createTempSync('foa-flavor-probe');
      final env = envOf(dir.path);
      await FlavorPrefs.save(env, BuildFlavor.debug);
      expect(await FlavorPrefs.load(env), BuildFlavor.debug);
      await FlavorPrefs.save(env, BuildFlavor.release);
      expect(await FlavorPrefs.load(env), BuildFlavor.release);
      dir.deleteSync(recursive: true);
    });
  });

  group('负面结论护栏（别再走一遍）', () {
    test('沙箱实测：Gradle 配置缓存与 Flutter 插件不兼容', () {
      // 实测报错（2026-09-27）：
      //   Task `:app:ReleaseMinSdkCheck` of type DefaultTask: cannot serialize
      //   ... com.flutter.gradle.DependencyVersionChecker ...
      // 开了会直接构建失败（61s 就挂），不是"慢一点"。
      // 这条断言守的是：别有人看到"配置缓存能提速"就加回去。
      final src = File('lib/toolchain/sdk_installer.dart').readAsStringSync();
      expect(src.contains('org.gradle.configuration-cache'), isFalse,
          reason: '配置缓存会让 Flutter 工程的构建直接失败');
    });
  });
}
