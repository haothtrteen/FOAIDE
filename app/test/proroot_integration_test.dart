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
      // ⚠️ alpha.69 更新：本 App **不再内置也不再分发**这套二进制
      // （上游许可 Proprietary 禁止再分发），清单已清空。
      // 这条从"守住名字与顺序"改为"守住它保持为空" —— 同样是防复活：
      // 一旦有人把五件套加回来，这里会红，tools/verify_apk.sh 的
      // 第 4/5 项合规检查也会红。历史名单（v1.2.5）见
      // PROROOT-许可与分发决策.md。
      expect(ProrootOption.soFiles, isEmpty);
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
    // Bug 471：结论翻过**两次**，每次都是被真机实测推翻的。
    //   alpha.63：断言"未验证组合，可能起不来"。
    //   其后：真机实测 v1.2.8 失败 → 改成"已实测确认不兼容"。
    //   再其后：查明 v1.2.8 要 glibc 2.38，改钉 v1.2.5（只要 2.34），
    //          一度以为"Debian 12 的 2.36 够用" → 又被 SIGSEGV 推翻。
    //   再其后（2026-09-21 判别实验）：误判为 `DT_NEEDED` 写了开发名。
    //   本版（2026-09-21 andClaw 对照定案）：真因是**加载方式不对** ——
    //          `libproroot.so` 的 `PT_INTERP` 是 `/system/bin/linker64`，
    //          必须从 `nativeLibraryDir` 直接 exec。**与 glibc 版本无关**，
    //          也与 rootfs 无关；换 Debian 13 / glibc 2.41 报错逐字相同。
    test('本项目 rootfs（Debian）必须直说"硬条件满足 + 尚未接通"', () {
      // ⚠️ 本条被真机实测推翻过**四次**：
      //    第 ① 次（2026-09-20）：原断言是"非官方组合但版本够、
      //      仍要先跑冒烟测试"。冒烟跑了、结果是崩的，"够"不成立。
      //    第 ② 次（2026-09-21）：改成断言含 'SIGSEGV' —— 但那只
      //      是**下游症状**。
      //    第 ③ 次：改成断言含 'libc.so'（DT_NEEDED 开发名）—— 解读错了，
      //      那是 bionic 语境下的正常依赖名。
      //    第 ④ 次：改成断言含 '未支持' —— 措辞**过重**，把作者的产品
      //      配置当成了技术前提。官方硬条件是 glibc（非 musl），本项目满足。
      //    第 ⑤ 版（当前）：不在官方验证环境内、但硬条件满足；真实卡点是集成方式。
      final n = ProrootOption.compatNote(
          rootfsDistro: ProrootOption.foaRootfsDistro);
      expect(n.contains('Debian 12 bookworm'), isTrue);
      expect(n.contains(ProrootOption.rootfsGlibc), isTrue,
          reason: '要写明本机有什么');
      expect(n.contains('硬条件满足'), isTrue,
          reason: '要讲准：不在官方验证环境内，但硬条件（glibc 非 musl）满足');
      expect(n.contains('未支持'), isFalse,
          reason: '"未支持组合"过重：官方 Requirements 的硬条件是 glibc 而非发行版');
      expect(n.contains('libproroot.so'), isTrue,
          reason: '2026-09-21 定案：要指向真实卡点（nativeLibraryDir 直接 exec），'
              '而不是停在 SIGSEGV / 偏移表这类下游症状');
      expect(n.contains('nativeLibraryDir'), isTrue,
          reason: '要点名真正的出路');
      expect(n.contains('rootfs 不是'), isTrue,
          reason: 'rootfs 不是卡点这件事必须说清，否则用户会去白折腾');
      expect(n.contains('跑通就不必换'), isTrue,
          reason: '要给出正确顺序：先做集成改造，用现有 rootfs 实测决定');
      expect(n.contains('够'), isFalse,
          reason: '不许再说"版本够"——实测证伪过');
      expect(n.contains('DT_NEEDED'), isFalse,
          reason: '"DT_NEEDED 写了开发名"已作废，不许留在文案里');
    });

    test('若换成 Ubuntu rootfs 则提示与验证环境一致（不无脑报警）', () {
      final n = ProrootOption.compatNote(rootfsDistro: 'Ubuntu 24.04 arm64');
      expect(n.contains('一致'), isTrue);
      expect(n.contains('不兼容'), isFalse);
    });

    test('发行版为空时不崩且说不知道', () {
      final n = ProrootOption.compatNote(rootfsDistro: '  ');
      expect(n.contains('未知'), isTrue);
    });
  });

  group('proroot · 启动器形态与 proot 的差异（接入时的核心坑）', () {
    test('launcherUsage 记录的是 proroot 的 argv 形态（-b host:guest，无 -0）', () {
      const u = ProrootOption.launcherUsage;
      expect(u.contains('libproroot.so'), isTrue);
      // ⚠️ 本条 2026-09-21 修正。旧断言要求 `-r` 出现在 `-0` 之前，
      //    依据是"proroot 是 `-r <rootfs> -0`，与 proot 相反"。
      //    对照作者 andClaw（ProrootManager.kt:581-592）后确认：
      //    **proroot 分支根本不带 `-0`**，`-0` 是 proot 分支的事。
      //    旧断言在钉一个不存在的参数。
      expect(u.contains('-0'), isFalse,
          reason: 'proroot 不带 -0（那是 proot 的参数），写进去会跑不起来');
      expect(u.contains('-r <rootfs>'), isTrue);
      // `-b` 必须是 host:guest 冒号对形式 —— 这是 proroot 与 proot 的
      // 真正差异点（proot 用单路径），抄错了就是挂载错位。
      expect(u.contains('-b /dev:/dev'), isTrue,
          reason: 'proroot 的 -b 是 host:guest 形式，这是接入的核心坑之一');
      expect(u.contains('-b /proc:/proc'), isTrue);
      expect(u.contains('-b /sys:/sys'), isTrue);
      expect(u.contains('--link2symlink'), isTrue);
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

  // 桥的键名契约：Kotlin 返回 map 的键 与 Dart 侧 fromMap 读的键 必须对齐。
  // 这类错误**编译能过、测试不跑就发现不了**，只在真机上表现为
  // "点了一下没反应"或"错误信息是空的"。
  group('proroot · 桥接键名契约（Kotlin 返回 ↔ Dart 读取）', () {
    final kt = File('android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt')
        .readAsStringSync();
    final models = File('lib/env/models.dart').readAsStringSync();

    test('proroot 的失败返回用 error 键，不是 exec 那套 stderr', () {
      // 背景：fail() 给 exec/execStream 用，键是 exitCode/stdout/stderr；
      // 而 prorootInstall/prorootProbe 的 Dart 消费者读的是 error。
      // 曾经 prorootProbe 里写 `return built.error!!`（proot 形状），
      // 错误文案在桥上凭空消失，UI 只剩兜底文案。
      expect(kt.contains('private fun prorootFail('), isTrue,
          reason: 'proroot 需要自己的失败构造器，不能复用 exec 的 fail()');
      expect(kt.contains('prorootFail('), isTrue);

      // prorootFail 的 map 必须带 "error" 键
      final at = kt.indexOf('private fun prorootFail(');
      expect(at, greaterThanOrEqualTo(0));
      final body = kt.substring(at, at + 300);
      expect(body.contains('"error" to message'), isTrue,
          reason: 'Dart 侧 ProrootProbeResult/ProrootInstallResult 读 m["error"]，'
              '键名不对错误信息就丢了');
    });

    test('ProrootProbeResult.fromMap 读的键在 Kotlin 侧都产出了', () {
      // 从 Dart 侧反查：它读什么，Kotlin 就必须给什么
      final at = models.indexOf('factory ProrootProbeResult.fromMap');
      expect(at, greaterThanOrEqualTo(0));
      final body = models.substring(at, at + 500);
      for (final k in ['ok', 'exitCode', 'output', 'cmd', 'error']) {
        expect(body.contains("m['$k']"), isTrue,
            reason: 'Dart 读 m["$k"]，这条断言只是防止 fromMap 被改后两边脱节');
      }
      // Kotlin 侧确实产出了这几个键（prorootProbe 内）
      final ps = kt.indexOf('private fun prorootProbe(');
      final pe = kt.indexOf('private fun applyProrootEnv(');
      expect(pe, greaterThan(ps));
      final pbody = kt.substring(ps, pe);
      for (final k in ['ok', 'exitCode', 'output', 'cmd', 'error']) {
        expect(pbody.contains('"$k" to '), isTrue,
            reason: 'prorootProbe 没有产出 "$k"，Dart 侧会永远读到 null');
      }
    });

    test('ProrootInstallResult.fromMap 读的键在 Kotlin 侧都产出了', () {
      final at = models.indexOf('factory ProrootInstallResult.fromMap');
      expect(at, greaterThanOrEqualTo(0));
      final body = models.substring(at, at + 500);
      for (final k in ['ok', 'copied', 'missing', 'notElf', 'error']) {
        expect(body.contains("m['$k']"), isTrue, reason: 'Dart 读 m["$k"]');
      }
      final is0 = kt.indexOf('private fun prorootInstall(');
      final is1 = kt.indexOf('private fun prorootRemove(');
      expect(is1, greaterThan(is0));
      final ibody = kt.substring(is0, is1);
      for (final k in ['ok', 'copied', 'missing', 'notElf', 'error']) {
        expect(ibody.contains('"$k" to '), isTrue,
            reason: 'prorootInstall 没有产出 "$k"');
      }
    });

    test('含可空值的返回 map 必须显式写 Any?（否则 Kotlin 编译不过）', () {
      // Map<String, Any?> 不能赋给 Map<String, Any>：值是"out"位置（协变），
      // 允许空值就打破了非空承诺。Kotlin 会直接报
      // "Return type mismatch: expected 'Map<String, Any>', actual 'Map<String, Any?>'"。
      // 这几处 error 键成功时为 null，所以声明与字面量都必须带 ?。
      for (final sig in [
        'private fun prorootStatus(): Map<String, Any?>',
        'private fun prorootInstall(srcDirPath: String): Map<String, Any?>',
        'private fun prorootRemove(): Map<String, Any?>',
        'private fun prorootProbe(): Map<String, Any?>',
        'private fun prorootFail(code: Int, message: String): Map<String, Any?>',
      ]) {
        expect(kt.contains(sig), isTrue,
            reason: '签名应为可空值类型：$sig（键 error 成功时为 null）');
      }
    });
  });
}
