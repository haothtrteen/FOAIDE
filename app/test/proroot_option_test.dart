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

    test('5 个 .so 清单完整（缺一不可，写少了用户会导入失败）', () {
      expect(ProrootOption.soFiles.length, 5);
      expect(ProrootOption.soFiles.first, 'libproroot.so');
      expect(
        ProrootOption.soFiles.every((f) => f.endsWith('.so')),
        isTrue,
      );
    });

    test('低门槛提示：冒烟测试不可省略（未验证组合）', () {
      final note = ProrootOption.compatNote(
        rootfsDistro: ProrootOption.foaRootfsDistro,
      );
      expect(note.contains('未验证组合'), isTrue);
      expect(note.contains('冒烟测试'), isTrue);
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
    test('Debian（本项目实际）→ 明确"未验证组合"', () {
      final n = ProrootOption.compatNote(rootfsDistro: 'Debian 12 bookworm');
      expect(n.contains('Debian'), isTrue);
      expect(n.contains('未验证'), isTrue);
      expect(n.contains('Ubuntu'), isTrue);
    });

    test('Ubuntu → 提示符合官方要求', () {
      final n = ProrootOption.compatNote(rootfsDistro: 'Ubuntu arm64');
      expect(n.contains('符合'), isTrue);
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
    test('5 个 .so 且含主启动器', () {
      expect(ProrootOption.soFiles.length, 5);
      expect(ProrootOption.soFiles.first, 'libproroot.so');
      for (final f in ProrootOption.soFiles) {
        expect(f.endsWith('.so'), isTrue);
      }
    });

    test('仅 arm64-v8a，要求 Android 8.0+', () {
      expect(ProrootOption.abi, 'arm64-v8a');
      expect(ProrootOption.minAndroidApi, 26);
    });

    test('启动器形态暴露给用户（argv 与 proot 不一致，不是一键切）', () {
      expect(ProrootOption.launcherUsage.startsWith('libproroot.so -r'),
          isTrue);
      expect(ProrootOption.launcherUsage.contains('--link2symlink'), isTrue);
    });
  });
}
