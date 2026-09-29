import 'package:flutter_test/flutter_test.dart';

import 'package:foaide/toolchain/proroot_option.dart';

/// 容器层加速（proroot）告知卡契约测试。
///
/// 这张卡的全部价值在于**如实告知**——许可原文、收益边界、环境不
/// 匹配。任何一条被"优化"掉（比如删掉"不改善 QEMU 翻译"那句），
/// 它就从告知变成误导。所以把事实钉死在测试里。
void main() {
  group('ProrootOption · 许可与来源', () {
    test('仓库地址逐字正确（写错比不写更糟）', () {
      expect(ProrootOption.repoUrl,
          'https://github.com/coderredlab/proroot');
    });

    test('许可原文照抄上游，不做转述', () {
      expect(ProrootOption.licenseText,
          'Proprietary. Free to use in your projects. '
          'Redistribution of modified binaries is not permitted.');
      // 三条关键事实必须都在：专有、可用、禁分发修改版
      expect(ProrootOption.licenseText.contains('Proprietary'), isTrue);
      expect(ProrootOption.licenseText.contains('Free to use'), isTrue);
      expect(ProrootOption.licenseText.contains('not permitted'), isTrue);
    });

    test('风险清单含源码未公开与禁止分发修改版', () {
      final all = ProrootOption.risks.join('\n');
      expect(all.contains('源码未公开'), isTrue);
      expect(all.contains('禁止分发修改过的二进制'), isTrue);
      expect(ProrootOption.risks.length, greaterThanOrEqualTo(4));
    });
  });

  group('ProrootOption · 默认关闭（alpha.61 起可启用）', () {
    test('二进制不由本项目分发（许可禁止分发修改版）', () {
      // 旧版本这里断言的是 ProrootOption.enabled == false（未集成）。
      // alpha.61 起功能已接入，但**默认仍然是 proot**——理由写在
      // ContainerPrefs 的文档里。这条测试改为守住"我们不代为分发"：
      // 让用户自己从上游取，是许可要求，不是偷懒。
      expect(ProrootOption.downloadHint.contains('仓库'), isTrue);
      expect(ProrootOption.licenseText.contains('not permitted'), isTrue);
    });

    test('二进制清单已清空（alpha.69 方案 A：不代分发）', () {
      // 这条是**防复活门禁**：上游许可 Proprietary 禁止再分发，
      // 五件套已从 APK 移除。谁把文件名加回来，这里立刻红 ——
      // 同时 tools/verify_apk.sh 第 4/5 项也会判红。
      expect(ProrootOption.soFiles, isEmpty);
    });

    // Bug 471：结论翻过**三次**。
    //   第一次（alpha.63）："未验证组合"——那时拿的是上游 main/v1.2.8。
    //   第二次：钉 v1.2.5 后一度以为"版本够"→ 被真机 SIGSEGV 推翻。
    //   第三次（2026-09-21 判别实验）：误判为 `DT_NEEDED` 写了开发名。
    //   本版（2026-09-21 andClaw 对照定案）：真因是**加载方式不对** ——
    //   `libproroot.so` 的 `PT_INTERP` 是 `/system/bin/linker64`，
    //   必须从 `nativeLibraryDir` 直接 exec。**与 glibc 版本无关**。
    //   测试必须跟着真相走，不能守着上一轮的结论。
    test('低门槛提示：说清与 rootfs 的实际情况（尚未接通）', () {
      // ⚠️ 本条被推翻过**三次**：
      //    第 ① 次：断言 `contains('够')`（"版本上是够的"）。
      //    第 ② 次：改断言 `contains('SIGSEGV')` —— 那仍是下游症状。
      //    第 ③ 次：改断言 `contains('libc.so')` —— 解读错了。
      final note = ProrootOption.compatNote(
        rootfsDistro: ProrootOption.foaRootfsDistro,
      );
      expect(note.contains(ProrootOption.rootfsGlibc), isTrue);
      expect(note.contains('libproroot.so'), isTrue,
          reason: '2026-09-21 定案：要指向真实卡点（nativeLibraryDir 直接 exec）');
      expect(note.contains('nativeLibraryDir'), isTrue,
          reason: '要点名真正的出路');
      expect(note.contains('够'), isFalse,
          reason: '"版本够"已被真机证伪，不许回来');
    });
  });

  group('ProrootOption · 收益边界（防止写成提速银弹）', () {
    test('明确写出对 QEMU 指令翻译无改善', () {
      final g = ProrootOption.gainNote();
      expect(g.contains('QEMU'), isTrue);
      expect(g.contains('不改善'), isTrue);
    });

    test('明确点名大头开销来源（gen_snapshot / gradle / aapt2）', () {
      final g = ProrootOption.gainNote();
      expect(g.contains('gen_snapshot'), isTrue);
      expect(g.contains('gradle'), isTrue);
      expect(g.contains('aapt2'), isTrue);
    });

    test('有反对夸大的措辞（不要指望 10 分钟变 2 分钟）', () {
      expect(ProrootOption.gainNote().contains('不要指望'), isTrue);
    });
  });

  group('ProrootOption.compatNote · 环境不匹配', () {
    // Bug 471（第二次更新）：非 Ubuntu 的判定不再一律"不兼容"。
    // 现在钉的 v1.2.5 只要 glibc 2.34，Debian 12 的 2.36 是**高于**它的，
    // 所以提示是"非官方组合，但版本够"。只有"要求 > 本机"才是真不兼容。
    test('Debian（本项目实际）→ 不在验证环境内但硬条件满足 + 尚未接通', () {
      // ⚠️ 本条被推翻过两次，详见 bug471 测试里的详细取证。
      // ⚠️ 2026-09-21 二次更正：原先断言 `contains('未支持')`。
      //    这个措辞过重 —— 官方 Requirements 是 "Ubuntu arm64 rootfs
      //    **with glibc**"，硬条件是 glibc 而非发行版；本项目满足。
      //    而且作者源码里**主动把 os-release 覆写成 Ubuntu**，
      //    说明 proroot 不关心实际发行版。所以不许再说"未支持组合"。
      final n = ProrootOption.compatNote(rootfsDistro: 'Debian 12 bookworm');
      expect(n.contains('Debian'), isTrue);
      expect(n.contains(ProrootOption.rootfsGlibc), isTrue,
          reason: '要写明本机有什么');
      expect(n.contains('硬条件满足'), isTrue,
          reason: '要讲准：不在官方验证环境内，但硬条件（glibc 非 musl）满足');
      expect(n.contains('未支持'), isFalse,
          reason: '"未支持组合"是过重的措辞，把产品配置当成了技术前提');
      expect(n.contains('Ubuntu'), isTrue, reason: '要给出官方验证环境');
      expect(n.contains('nativeLibraryDir'), isTrue,
          reason: '要指向真实卡点（加载方式），而不是下游症状');
      expect(n.contains('够'), isFalse, reason: '同上，已被证伪');
      // 不能再说"版本不匹配"——措辞要求本身没变，但理由变了：
      //   旧理由："版本其实够、别换 rootfs"。
      //   新理由（2026-09-21）：**真正的原因不是版本高低**，
      //     换 rootfs 也已实测证否。所以"版本不匹配"依然会误导。
      expect(n.contains('版本不匹配'), isFalse);
      expect(n.contains('rootfs 不是'), isTrue,
          reason: 'rootfs 不是卡点这件事必须显式说清');
      expect(n.contains('跑通就不必换'), isTrue,
          reason: '要给出正确顺序：先做集成改造，用现有 rootfs 实测决定');
    });

    test('Ubuntu → 提示与官方验证环境一致（不说"未支持"的反面）', () {
      final n = ProrootOption.compatNote(rootfsDistro: 'Ubuntu arm64');
      expect(n.contains('一致'), isTrue);
      expect(n.contains('未验证'), isFalse);
    });

    test('空值不崩且有兜底文案', () {
      final n = ProrootOption.compatNote(rootfsDistro: '  ');
      expect(n.contains('未知'), isTrue);
    });

    test('本项目实际值与官方要求确实不一致（这条断言就是卡片的立身之本）', () {
      expect(
        ProrootOption.foaRootfsDistro
            .toLowerCase()
            .contains('ubuntu'),
        isFalse,
      );
      expect(ProrootOption.requiredRootfs, 'Ubuntu arm64');
    });
  });

  group('ProrootOption · 二进制与启动器契约', () {
    test('二进制清单已清空（与上一条同源，守住 alpha.69 的方案 A）', () {
      expect(ProrootOption.soFiles, isEmpty);
      expect(ProrootOption.soAssets, isEmpty);
      // 清单空了，派生值也不该是"看似有内容"的数字
      expect(ProrootOption.totalBytes, 0);
    });

    test('仅 arm64-v8a，要求 Android 8.0+', () {
      expect(ProrootOption.abi, 'arm64-v8a');
      expect(ProrootOption.minAndroidApi, 26);
    });

    test('启动器形态暴露给用户（argv 与 proot 不一致，不是一键切）', () {
      expect(ProrootOption.launcherUsage.startsWith('libproroot.so -r'),
          isTrue);
      expect(ProrootOption.launcherUsage.contains('--link2symlink'), isTrue);
      // proroot 的 -b 是 host:guest 形式，且不带 -0（见 integration 测试的详述）
      expect(ProrootOption.launcherUsage.contains('-b /dev:/dev'), isTrue);
      expect(ProrootOption.launcherUsage.contains('-0'), isFalse);
    });

    test('风险文案不得再宣称"已打包进 jniLibs"（那是假承诺）', () {
      // alpha.69 前 risks[1] 写"① ✅ 五个 .so 打包进 jniLibs/arm64-v8a/"，
      // 在二进制已移除的当下是明确的事实错误 —— 用户会以为本 App 自带。
      expect(ProrootOption.risks[1], contains('回退'),
          reason: '要说清"该方案已回退"，而不是继续宣称已实施');
      expect(ProrootOption.risks[1], contains('jniLibs'),
          reason: '仍要点名历史打包路径，方便自行导入的用户对照');
      expect(ProrootOption.risks[1], isNot(contains('✅ 五个')),
          reason: '不能保留"已打包"的完成时勾选');
      // 首条要提醒二进制不再内置，否则用户找不到入口
      expect(ProrootOption.risks.first, contains('不再内置'),
          reason: '首条要提醒"二进制不再内置"，否则用户找不到入口');
    });

    test('knownUnusableMessage 也不得宣称已打包（卡片正文，用户直接看）', () {
      final msg = ProrootOption.knownUnusableMessage();
      expect(msg, contains('不再内置'));
      expect(msg, isNot(contains('① ✅ 五个 .so 打包进')));
    });
  });
}
