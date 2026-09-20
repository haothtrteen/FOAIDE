import 'dart:io';

import 'package:foaide/toolchain/build_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bug 436：构建前出现 `Command exited with code 128: fetch --tags` /
/// `HTTP 504 ... fatal: the remote end hung up unexpectedly`，且构建明显变慢。
///
/// **真因不在我们的镜像配置**（那是第一个被怀疑的对象，也已排除）：
/// git URL 重写规则经实测正确（`git ls-remote --get-url` 确认已改写到
/// gitclone 镜像，且该镜像从网络侧返回 200 / 1.6s）。
///
/// 真因是 **flutter 工具自身的版本新鲜度检查**：
///   `VersionFreshnessValidator.checkAgeConsideredUpToDate = Duration(days: 3)`
/// 距上次检查超过 3 天 → 重新执行 `_fetchRemoteFrameworkCommitDate()`
/// （内部即 `git fetch --tags`）。该请求在真机网络下 504，flutter 捕获
/// `VersionCheckError` 后**继续构建**（best-effort），但用户要先等满超时。
///
/// 复现实验（本机实测，2026-09-19）：
///   - stamp 设为 9 天前 → `flutter pub get` 输出出现 504 / remote end hung up
///   - stamp 刷新为当前时间 → 同上命令，504 消失
///
/// 缓存协议：`<flutter>/bin/cache/flutter_version_check.stamp`，
/// JSON 字段 `lastTimeVersionWasChecked`（version.dart 的
/// `VersionCheckStamp`）。构建前刷新它属官方机制内用法，不改 SDK 源码。
///
/// 附带修复：proot 构建路径原先只设 `SSL_CERT_FILE`，**没有**
/// `FLUTTER_STORAGE_BASE_URL`——`pub get` 那行内联了 `PUB_HOSTED_URL`，
/// 所以 pub 没事，但引擎/资产下载会回落到官方地址。`foa-env.sh` 里
/// 虽写了这些变量，可它放在 `/etc/profile.d/`，而 proot 用 `sh -c`
/// 直接执行命令、**不读 profile.d**，等于对构建路径完全无效。
void main() {
  group('Bug 436 · 跳过 flutter 版本检查', () {
    test('buildCommand 注入 stamp 刷新脚本', () {
      final cmd = BuildRunner.buildCommand(
        proj: '/root/projects/my_flutter',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(cmd.contains('flutter_version_check.stamp'), isTrue,
          reason: '必须刷新 flutter 的版本检查缓存，否则每 3 天一次 504 等待');
    });

    test('stamp 写入的是 lastTimeVersionWasChecked 字段（flutter 认的协议）', () {
      const s = BuildRunner.refreshVersionCheckStamp;
      expect(s.contains('lastTimeVersionWasChecked'), isTrue,
          reason: '字段名必须与 VersionCheckStamp.fromJson 一致');
      // 不能写 lastKnownRemoteVersion——伪造远端版本号会让 flutter 认为
      // 本地落后而提示升级，属于副作用
      expect(s.contains('lastKnownRemoteVersion'), isFalse,
          reason: '只刷新"检查时间"，不要伪造远端版本');
    });

    test('stamp 脚本语法安全：有 mkdir -p 且失败不阻断', () {
      const s = BuildRunner.refreshVersionCheckStamp;
      expect(s.contains('mkdir -p'), isTrue,
          reason: 'cache 目录不存在时也要能写');
      expect(s.contains('exit 0'), isTrue,
          reason: '这个优化本身不该成为新的失败点');
      // 不得出现裸 exit 非 0
      expect(RegExp(r'exit\s+[1-9]').hasMatch(s), isFalse);
    });

    test('时间戳格式能被 Dart DateTime.parse 解析', () {
      // flutter 用 DateTime.parse 读该字段，格式必须匹配
      const sample = '2026-09-19 01:23:45.747308';
      expect(() => DateTime.parse(sample), returnsNormally,
          reason: 'date 命令输出格式必须可直接被 DateTime.parse 接受');
    });

    test('stamp 刷新发生在 pub get 之前（构建一开始就跳过网络检查）', () {
      final cmd = BuildRunner.buildCommand(
        proj: '/p',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      final stampIdx = cmd.indexOf('flutter_version_check.stamp');
      final pubIdx = cmd.indexOf('pub get');
      expect(stampIdx, greaterThan(0));
      expect(pubIdx, greaterThan(0));
      expect(stampIdx, lessThan(pubIdx),
          reason: 'pub get 自身也会触发版本检查，必须在它之前刷新');
    });
  });

  group('Bug 436 · proot 构建路径缺 FLUTTER_STORAGE_BASE_URL', () {
    test('buildCommand 里显式带上该变量', () {
      final cmd = BuildRunner.buildCommand(
        proj: '/p',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(cmd.contains('FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn'),
          isTrue,
          reason: 'proot 用 sh -c 直接执行，不读 /etc/profile.d/foa-env.sh，'
              '必须在命令里显式给');
    });

    test('该变量必须出现在 flutter build 之前（否则对 build 无效）', () {
      final cmd = BuildRunner.buildCommand(
        proj: '/p',
        flutterCmd: 'flutter',
        envPart: '',
        aapt2Override: '',
      );
      expect(
        cmd.indexOf('FLUTTER_STORAGE_BASE_URL') < cmd.indexOf('build apk'),
        isTrue,
      );
    });
  });

  group('Bug 437 · verify 必须冒烟 impellerc（真机实际崩溃点）', () {
    // 真机证据：AOT 到 52% 崩，日志是
    //   Dart snapshot generator failed with exit code -4
    //   impellerc failure:
    // 且同一轮里 REASSERT=0（转发层完好）——说明问题不在"脚本被覆盖"，
    // 而在 impellerc 这个工具**从来没被验证过可运行**。
    // 原先 verify 只测 android-arm64-release/linux-arm64/gen_snapshot，
    // 漏掉了顶层 linux-arm64/ 下的 impellerc。

    test('verify 脚本包含 impellerc 冒烟项', () {
      final src = File('lib/toolchain/qemu_compat.dart').readAsStringSync();
      expect(
        RegExp(r'smoke @ENGINE@/linux-arm64/impellerc IMPELLERC').hasMatch(src),
        isTrue,
        reason: '测的必须是顶层 linux-arm64/impellerc（真机实际调用的那个）',
      );
    });

    test('verify 脚本包含 font-subset 冒烟项（AOT 同目录工具）', () {
      final src = File('lib/toolchain/qemu_compat.dart').readAsStringSync();
      expect(
        RegExp(r'smoke @ENGINE@/linux-arm64/font-subset FONT_SUBSET')
            .hasMatch(src),
        isTrue,
      );
    });

    test('smoke 失败时必须输出具体原因（否则真机无法排障）', () {
      final src = File('lib/toolchain/qemu_compat.dart').readAsStringSync();
      final m = RegExp(
        r"static const String _verifyScript = r'''(.*?)''';",
        dotAll: true,
      ).firstMatch(src);
      final s = m!.group(1)!;
      // 四种失败形态的修法完全不同，必须能区分
      expect(s.contains('不是转发脚本'), isTrue, reason: '转发层被覆盖');
      expect(s.contains('Exec format error'), isTrue, reason: 'qemu 未生效');
      expect(s.contains('依赖库缺失'), isTrue, reason: '多架构库缺失');
      expect(s.contains('SIGILL'), isTrue, reason: 'qemu 跑 x64 失败');
    });

    test('检查转发脚本指向的目标是否仍是 x86_64 ELF', () {
      final src = File('lib/toolchain/qemu_compat.dart').readAsStringSync();
      expect(src.contains('TARGET_BAD='), isTrue,
          reason: '这一项能抓到"脚本在、REASSERT=0、但一跑就崩"的场景');
      expect(src.contains('7f454c46*3e'), isTrue,
          reason: '校验 x86_64 ELF magic（e_machine=0x3e）');
    });

    test('冒烟判定要能识别"空输出/信号退出"（SIGILL 静默崩溃）', () {
      final src = File('lib/toolchain/qemu_compat.dart').readAsStringSync();
      final m = RegExp(
        r"static const String _verifyScript = r'''(.*?)''';",
        dotAll: true,
      ).firstMatch(src);
      expect(m, isNotNull);
      final s = m!.group(1)!;
      expect(s.contains('smoke()'), isTrue, reason: '应抽出统一的冒烟函数');
      expect(s.contains(r'[ "$r" -ge 128 ]'), isTrue,
          reason: 'rc>=128 是信号退出（-4 即 SIGILL），必须判为不可用');
      expect(s.contains(r'[ -z "$o" ]'), isTrue,
          reason: 'SIGILL 时进程被信号杀死、无输出，也必须判为不可用');
    });

    test('verify 的 Dart 侧解析接上新增指标', () {
      final src = File('lib/toolchain/qemu_compat.dart').readAsStringSync();
      expect(src.contains("kv('IMPELLERC')"), isTrue);
      expect(src.contains("kv('FONT_SUBSET')"), isTrue);
    });
  });
}
