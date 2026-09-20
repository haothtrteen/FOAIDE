import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/proroot_option.dart';
import 'package:foaide/toolchain/termux_backend.dart';

/// proroot 接入（alpha.61）的守卫测试。
///
/// 这一组测试守的不是"代码能跑"（那要靠真机冒烟测试），而是
/// **几条一旦走偏就会造成实质伤害的约定**：
///
/// 1. 我们不替用户分发 proroot 二进制（许可禁止分发修改版）——
///    接口设计上就没有"从我们的服务器下载"这条路；
/// 2. 原生侧默认走 proot（proroot 是未验证组合，不能是默认值）；
/// 3. `ContainerLayer` 与 `BuildBackend` 是两个正交维度，
///    不能因为图省事把它们合并成一个枚举（合并了就表达不了
///    "termux 裸原生 + 无容器层"这种组合）。
void main() {
  group('proroot · 二进制来源（许可边界）', () {
    test('5 个 .so 的文件名与上游一致且顺序固定', () {
      // 顺序固定很重要：导入逻辑是按名单认领的，
      // 改顺序不会崩但会让"加载顺序"的注释变成谎话。
      expect(ProrootOption.soFiles, const [
        'libproroot.so',
        'libproroot-runtime.so',
        'libproroot-linker.so',
        'libproroot-bridge.so',
        'libproroot-stub-loader.so',
      ]);
    });

    test('不提供下载地址——只给"上游仓库 + 让你自己去取"的引导', () {
      // 反面断言：如果哪天有人加了一个直链下载字段，
      // 这条会失败，逼他先想清楚许可问题。
      const hint = ProrootOption.downloadHint;
      expect(hint.contains('仓库'), isTrue);
      expect(hint.contains('导入'), isTrue);
      // 不能给一个"点这儿下载"的直链（那就是代为分发）
      expect(RegExp(r'https?://\S+\.(so|zip|tar|deb)').hasMatch(hint), isFalse,
          reason: '不能提供二进制直链——许可是"Free to use"，'
              '但"Redistribution of modified binaries is not permitted"');
    });

    test('许可原文逐字保留（转述会失真）', () {
      expect(ProrootOption.licenseText, contains('Proprietary'));
      expect(ProrootOption.licenseText, contains('Free to use in your projects'));
      expect(ProrootOption.licenseText,
          contains('Redistribution of modified binaries is not permitted'));
    });
  });

  group('proroot · 收益边界（防止被当成提速银弹）', () {
    test('明确写出对 QEMU 指令翻译与 dart/gradle 计算零改善', () {
      final g = ProrootOption.gainNote();
      expect(g.contains('QEMU'), isTrue);
      expect(g.contains('不改善'), isTrue);
      expect(g.contains('dart/gradle'), isTrue);
    });

    test('明确说清它优化的是什么（方便用户自己判断值不值）', () {
      final g = ProrootOption.gainNote();
      expect(g.contains('LD_PRELOAD'), isTrue);
      expect(g.contains('ptrace'), isTrue);
      expect(g.contains('上下文切换'), isTrue);
    });

    test('点名 I/O 密集场景才是受益面', () {
      final g = ProrootOption.gainNote();
      expect(g.contains('I/O'), isTrue);
      expect(g.contains('apt'), isTrue);
    });

    test('有反对夸大的措辞', () {
      expect(ProrootOption.gainNote().contains('不要指望'), isTrue);
    });
  });

  group('proroot · 兼容性提示', () {
    test('本项目 rootfs（Debian）判为未验证组合，并指向冒烟测试', () {
      final n = ProrootOption.compatNote(
          rootfsDistro: ProrootOption.foaRootfsDistro);
      expect(n.contains('Debian 12 bookworm'), isTrue);
      expect(n.contains('未验证组合'), isTrue);
      expect(n.contains('冒烟测试'), isTrue);
    });

    test('若换成 Ubuntu rootfs 则提示符合要求（不无脑报警）', () {
      final n = ProrootOption.compatNote(rootfsDistro: 'Ubuntu 24.04 arm64');
      expect(n.contains('符合官方要求'), isTrue);
      expect(n.contains('未验证组合'), isFalse);
    });

    test('发行版为空时不崩且说不知道', () {
      final n = ProrootOption.compatNote(rootfsDistro: '  ');
      expect(n.contains('未知'), isTrue);
    });
  });

  group('proroot · 启动器形态与 proot 的差异（接入时的核心坑）', () {
    test('launcherUsage 记录的是 proroot 的 argv 顺序', () {
      const u = ProrootOption.launcherUsage;
      expect(u.contains('libproroot.so'), isTrue);
      // proroot 是 `-r <rootfs> -0`，proot 是 `-0 -r <rootfs>`
      final pr = u.indexOf('-r <rootfs>');
      final pz = u.indexOf('-0');
      expect(pr, lessThan(pz),
          reason: 'proroot 的 -r 在 -0 之前（与 proot 相反）——'
              '顺序写错会得到一个跑不起来的启动器');
    });

    test('Kotlin 侧确实有独立的 buildProrootCmd 实现（不是复用 buildProotCmd）', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      expect(kt.contains('private fun buildProrootCmd('), isTrue,
          reason: 'proroot 的 argv 与 proot 不同，必须是独立函数');
      // 独立实现里必须出现 proroot 特有的顺序
      final body = kt.substring(kt.indexOf('private fun buildProrootCmd('));
      final end = body.indexOf('\n    private fun ', 10);
      final fn = end > 0 ? body.substring(0, end) : body;
      expect(fn.contains('launcher.absolutePath'), isTrue);
      expect(fn.contains('"-r", rootfs.absolutePath'), isTrue);
    });

    test('冒烟测试命令能自证跑通（有可断言的标记词）', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      expect(kt.contains('FOA_PROBE_OK'), isTrue,
          reason: '冒烟测试必须有确定性的成功标记，'
              '"输出非空即成功"会把 lderror 也当成成功');
    });
  });

  group('ContainerLayer · 与 BuildBackend 正交', () {
    test('两个枚举各自独立，不共享成员语义', () {
      // 如果哪天有人把它们合并成一个 enum，这里会编译失败——
      // 这正是目的：合并了就表达不了 "termux + 不适用容器层"。
      expect(ContainerLayer.values.length, 2);
      expect(ContainerLayer.values, contains(ContainerLayer.proot));
      expect(ContainerLayer.values, contains(ContainerLayer.proroot));
      expect(BuildBackend.values.length, 2);
      expect(BuildBackend.values, contains(BuildBackend.proot));
      expect(BuildBackend.values, contains(BuildBackend.termux));
    });

    test('默认值必须是 proot（proroot 是未验证组合，不能当默认）', () {
      // ContainerPrefs.load 在文件不存在/损坏时返回 proot。
      // 这里守的是"默认值本身"，靠读源码断言——
      // 因为 load 需要 EnvInfo（要真机通道），单测里造不出来。
      final src = File('lib/toolchain/termux_backend.dart').readAsStringSync();
      final i = src.indexOf('class ContainerPrefs');
      final body = src.substring(i, src.indexOf('\n}', i));
      expect(
        RegExp(r'return ContainerLayer\.proot;').allMatches(body).length,
        greaterThanOrEqualTo(3),
        reason: '文件不存在/JSON 不合法/值不认识，三条兜底都要回到 proot',
      );
    });

    test('prefs 落盘文件名与 backend 分开（互不覆盖）', () {
      expect(ContainerPrefs.fileName, isNot(BackendPrefs.fileName));
      expect(ContainerPrefs.fileName, endsWith('.json'));
    });
  });

  group('Dart ↔ Kotlin 协议一致', () {
    test('exec / execStream 都传 proroot 标志', () {
      final dart = File('lib/env/proot_bridge.dart').readAsStringSync();
      expect(RegExp(r"'proroot': proroot").allMatches(dart).length, 2,
          reason: 'exec 与 execStream 两个入口都要传，漏一个就会出现'
              '"终端走 proroot 但构建走 proot"的诡异不一致');
    });

    test('Kotlin 侧四个 proroot 方法都已注册', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      for (final m in const [
        'prorootStatus',
        'prorootImport',
        'prorootRemove',
        'prorootProbe',
      ]) {
        expect(kt.contains('"$m" ->'), isTrue, reason: '$m 未注册到 MethodChannel');
      }
    });

    test('Kotlin 侧 exec/execStream 都有 proroot 形参且读取该参数', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      expect(
        RegExp(r'proroot: Boolean = false,').allMatches(kt).length,
        2,
        reason: 'exec 与 execStream 都要有形参',
      );
      expect(
        RegExp(r'call\.argument<Boolean>\("proroot"\) == true').allMatches(kt).length,
        2,
        reason: '两个入口都要读取 Dart 传来的标志',
      );
    });

    test('非 proroot 路径不受影响（仍走原 proot 分支）', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      expect(
        kt.contains('val built = if (proroot) buildProrootCmd(command) else buildProotCmd(command)'),
        isTrue,
        reason: '必须是二选一，不能改成"总是 proroot"——'
            '没导入二进制的用户会全部构建失败',
      );
    });
  });
  group('平台模板双写（Bug 440 门禁）', () {
    const gen = 'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt';
    const tpl = 'platform/android/MainActivity.kt';

    test('模板与生成目录逐字节一致', () {
      final g = File(gen).readAsStringSync();
      final t = File(tpl).readAsStringSync();
      expect(
        t,
        g,
        reason: r'platform/ 模板不是构建输入——它落后了不会报错，'
            r'只会让"新工程脚手架"缺功能（Bug 440：269 行 PTY 代码'
            r'一个月没进过构建目录）。改了生成目录就必须 cp 回模板。',
      );
    });

    test('proroot 的四件套两边都在（不能只改一边）', () {
      for (final f in [gen, tpl]) {
        final src = File(f).readAsStringSync();
        for (final k in [
          'PROROOT_DIR',
          'PROROOT_SO_FILES',
          'buildProrootCmd',
          'applyProrootEnv',
          'prorootStatus',
          'prorootInstall',
          'prorootProbe',
          'prorootRemove',
          'copyTree',
        ]) {
          expect(src.contains(k), isTrue, reason: '$f 缺 $k');
        }
      }
    });

    test('PtySession.kt 两边也一致（同一门禁，别只盯 MainActivity）', () {
      final g = File('android/app/src/main/kotlin/dev/foa/flutter_on_android/PtySession.kt');
      final t = File('platform/android/PtySession.kt');
      if (g.existsSync() && t.existsSync()) {
        expect(t.readAsStringSync(), g.readAsStringSync(),
            reason: 'PtySession 同样是非构建输入，会一起落后');
      } else {
        // 两边都不存在也算一致（但一边有一边没有 = 落后）
        expect(g.existsSync(), t.existsSync(),
            reason: 'PtySession.kt 只有一边存在，说明同步漏了');
      }
    });
  });
}
