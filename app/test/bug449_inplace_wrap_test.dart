import 'dart:io';
import 'dart:typed_data';

import 'package:foaide/toolchain/qemu_compat.dart';
import 'package:foaide/toolchain/sdk_installer.dart';
import 'package:foaide/toolchain/toolchain_ensure.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bug 449（alpha.55，2026-09-19 真机直控铁证）：**二进制架构自报不可信，
/// 以调用路径埋点实证**。
///
/// ## 真因证据链（五个版本 exit -4 的终点）
///
/// 1. App 部署的 dart 是 x86_64 二进制经 qemu 跑（dart-sdk/bin 原位包装）；
/// 2. dart VM 内 `Abi.current()` 自报 **x64** → flutter_tools
///    `getCurrentHostPlatform()` 判定 **linux_x64**
///    （artifacts.dart 只对 darwin_arm64 做 x64 回退，linux_arm64 没有）；
/// 3. 于是 gen_snapshot（android-{arm,arm64,x64}-release 三个 target）、
///    impellerc、font-subset 全部解析到 **`linux-x64/` 原目录裸真身**；
/// 4. 裸 x64 ELF 在 arm64 内核上 exec → SIGILL = `exit -4`。
/// 5. 此前维护的 `linux-arm64/` 对称 wrapper **从构建第一天起就没被调用过
///    一次**（真机埋点 X64_GEN / X64_IMPELLER 命中、arm64 位零命中）。
///
/// 真机修复实证：linux-x64 位原位包装（真身 `.foa-real` + wrapper）后，
/// 完整 release 构建全绿（app-release.apk 43.0MB 构建成功）。
///
/// ## 本文件固化的契约
///
/// 1. **全脚本 shell 语法门禁**（dash + bash）——AOT_FP 段曾因复制粘贴
///    产生「两个 for 头、一个 done」的语法错误，凡被执行的脚本必须可被
///    单测 `bash -n`；
/// 2. 原位包装（engineWrap 先原位后对称、真身感知）；
/// 3. reassert 的 INPLACE 段（precache 冲掉原位 wrapper 的自愈）；
/// 4. AOT_FP 角色判定（`*.foa-real` → REAL 期望 raw，其余 → SLOT 期望
///    wrapper）；
/// 5. verify 冒烟覆盖原位位、TARGET 检查指向 .foa-real；
/// 6. 卸载还原 linux-x64 原位包装；
/// 7. NDK strip 补位（空壳 NDK 的执行期窟窿 + glob 字面量防护）；
/// 8. build_runner 前置链接线顺序。
///
/// ⚠️ 本文件所有含 `$` 的 shell 断言串**必须用 r''**——否则 `$f`/`$E`
/// 是 Dart 插值，编译期就炸（第一版就这么翻的车）。
void main() {
  /// 真实 x86_64 ELF64 头（20 字节、offset 18 = 0x3e，命中
  /// `7f454c46*3e` 判据）。与 bug442 测试同款 fixture。
  Uint8List x64ElfHeader() {
    final b = BytesBuilder();
    b.add([0x7f, 0x45, 0x4c, 0x46]); // \x7fELF
    b.add([0x02, 0x01, 0x01, 0x00]); // 64-bit, LSB, v1
    b.add(List.filled(8, 0)); // pad 到 16
    b.add([0x03, 0x00]); // e_type = ET_DYN (PIE)
    b.add([0x3e, 0x00]); // e_machine = EM_X86_64
    return b.toBytes();
  }

  String head4(String path) {
    final f = File(path);
    if (!f.existsSync()) return 'MISSING';
    final b = f.readAsBytesSync();
    if (b.length < 4) return 'SHORT';
    return b
        .sublist(0, 4)
        .map((x) => x.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 建最小引擎 fixture：android-arm64-release/linux-x64/ 下一个裸 x64
  /// gen_snapshot（precache 完成后的官方形态）。返回临时根。
  Directory makeEngineFixture() {
    final root = Directory.systemTemp.createTempSync('foa449');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    final dir = '${root.path}/engine/android-arm64-release/linux-x64';
    Directory(dir).createSync(recursive: true);
    File('$dir/gen_snapshot')
        .writeAsBytesSync(x64ElfHeader() + List<int>.filled(64, 0));
    Process.runSync('chmod', ['755', '$dir/gen_snapshot']);
    return root;
  }

  /// 占位符替换成 fixture 路径（与 bug442 的 fillFor 同思路：
  /// 先 fill 展开生产常量，再把常量换成临时目录，并断言无真实路径残留）。
  String fillFor(Directory root, String script) {
    final filled = QemuCompat.fill(script)
        .replaceAll(QemuCompat.engineDir, '${root.path}/engine')
        .replaceAll(QemuCompat.flutterHome, '${root.path}/flutter')
        .replaceAll(QemuCompat.sdkHome, '${root.path}/sdk');
    final realRefs = filled
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('#'))
        .where((l) =>
            l.contains(QemuCompat.flutterHome) ||
            l.contains(QemuCompat.engineDir) ||
            l.contains(QemuCompat.sdkHome))
        .toList();
    expect(realRefs, isEmpty,
        reason: '非注释行出现真实环境路径——替换写错会打到真环境：$realRefs');
    return filled;
  }

  String runSh(Directory root, String script) {
    final f = File('${root.path}/_run.sh')..writeAsStringSync(script);
    final r = Process.runSync('/bin/sh', [f.path]);
    expect(r.exitCode, 0,
        reason: '脚本执行失败：${r.stderr}\n---脚本---\n$script');
    return r.stdout as String;
  }

  Map<String, String> allScripts() => <String, String>{
        'flutterWrap': QemuCompat.fill(QemuCompat.flutterWrapScript),
        'engineWrap': QemuCompat.fill(QemuCompat.engineWrapScript),
        'wrapReassert': QemuCompat.fill(QemuCompat.wrapReassertScript),
        'sdkWrap': QemuCompat.fill(QemuCompat.sdkWrapScript),
        'preflight': QemuCompat.fill(QemuCompat.buildPreflightScript),
        'heal': QemuCompat.fill(QemuCompat.healScript),
        'verify': QemuCompat.fill(QemuCompat.verifyScript),
        'uninstall': QemuCompat.fill(QemuCompat.uninstallScript),
        'ndkStripProbe': ToolchainEnsure.ndkStripProbeScript,
        'ndkStripEnsure':
            '${AptTools.repairDpkg}${ToolchainEnsure.ndkStripEnsureScript}',
        'wrapCheck.chk': ToolchainEnsure.wrapCheckScript('WRAP_CHECK'),
        'wrapCheck.verify': ToolchainEnsure.wrapCheckScript('VERIFY'),
      };

  group('Bug 449 · 全脚本 shell 语法门禁（dash + bash）', () {
    // AOT_FP 段曾出现「两个 for 头、一个 done」的语法错误——脚本只被
    // Dart 字符串拼接、没人看过成品。规矩：**凡被执行的脚本必须可被
    // 单测 bash -n / dash -n**。新增脚本时必须在这里登记。
    test('12 份脚本在 dash 与 bash 下语法均通过', () {
      final dir = Directory.systemTemp.createTempSync('foa449syn');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final scripts = allScripts();
      expect(scripts.length, 12, reason: '登记脚本数变化时同步更新本断言');
      for (final e in scripts.entries) {
        final f = File('${dir.path}/${e.key.replaceAll('.', '_')}.sh')
          ..writeAsStringSync(e.value);
        for (final sh in ['dash', 'bash']) {
          final probe = Process.runSync('sh', ['-c', 'command -v $sh']);
          if (probe.exitCode != 0) continue; // 环境没有该 shell 则跳过
          final r = Process.runSync(sh, ['-n', f.path]);
          expect(r.exitCode, 0,
              reason: '${e.key} 在 $sh 下语法错误：${r.stderr}');
        }
      }
    });
  });

  group('Bug 449 · engineWrapScript 原位包装契约', () {
    const s = QemuCompat.engineWrapScript;

    test('原位段必须 mv 成 .foa-real + gen 指向真身', () {
      expect(s.contains(r'mv "$f" "$f.foa-real"'), isTrue,
          reason: '原位包装：官方名字位放 wrapper，真身挪到 .foa-real');
      expect(s.contains(r'gen "$f" "$f.foa-real"'), isTrue,
          reason: 'wrapper 必须直接指向同目录真身（只过一层 sh）');
    });

    test('原位段必须先于对称段（对称位直接指真身，不过两层 sh）', () {
      final iInplace = s.indexOf('原位包装（先做');
      final iSym = s.indexOf(r'for d in "$E"/android-*/linux-x64; do');
      expect(iInplace, greaterThan(0), reason: '原位段锚点');
      expect(iSym, greaterThan(iInplace),
          reason: '顺序保证对称段 gen 时 .foa-real 已就位，'
              'wrapper 一生成就是「指向真身」的最终形态');
    });

    test('对称段必须真身感知（.foa-real 优先）', () {
      expect(
        s.contains(
            r'real="$f"; [ -f "$f.foa-real" ] && real="$f.foa-real"'),
        isTrue,
        reason: '否则对称 wrapper 指向另一个 wrapper（两层 sh），且'
            '对称段会误把原位 wrapper 当裸 ELF 再包装一遍',
      );
      // dd 必须读真身
      expect(s.contains(r'dd if="$real"'), isTrue);
    });

    test('注释必须记录真因证据链（后人改这里前必须先读）', () {
      expect(s.contains('Bug 449'), isTrue);
      expect(s.contains('Abi.current()'), isTrue,
          reason: 'dart VM 自报 x64 是全链路的起点，必须写在案发现场');
    });

    test('端到端：裸 x64 引擎 → 原位 + 对称双包装（真实执行）', () {
      final root = makeEngineFixture();
      final out = runSh(root, fillFor(root, QemuCompat.engineWrapScript));
      expect(out, contains('ENGINE_DIRS='));

      final base = '${root.path}/engine/android-arm64-release';
      // 原位：gen_snapshot 是 wrapper、真身在 .foa-real
      expect(head4('$base/linux-x64/gen_snapshot'), '23212f62',
          reason: '官方名字位必须是 #! wrapper（构建实际调用的路径）');
      expect(head4('$base/linux-x64/gen_snapshot.foa-real'), '7f454c46',
          reason: '真身必须是裸 x64 ELF');
      // 对称：wrapper 生成，且指向 .foa-real 真身
      expect(head4('$base/linux-arm64/gen_snapshot'), '23212f62',
          reason: '对称位也必须是 wrapper（上游修复 ABI 检测后的兜底）');
      final sym = File('$base/linux-arm64/gen_snapshot').readAsStringSync();
      expect(sym.contains('gen_snapshot.foa-real'), isTrue,
          reason: '对称 wrapper 必须直接指向真身（不过两层 sh）');
    });

    test('Bug 451：旧对称 wrapper（指向已变 #! 的裸位）必须被重建成新形态（真实执行）',
        () {
      // 真机 2026-09-19 工具链页假警报的精确复现：alpha.53 时代生成的
      // 对称 wrapper 真身参数烘死指向 linux-x64/gen_snapshot；Bug 449
      // 原位包装后该位置变成 #! 文本 → qemu+ld.so 加载 shell 文本 →
      // invalid ELF header。旧判据"自己已是 #! 就跳过"永远刷不掉它。
      final root = makeEngineFixture();
      final base = '${root.path}/engine/android-arm64-release';
      // 预置：原位已是 wrapper（旧形态，指裸位）+ 真身 + 旧对称 wrapper
      File('$base/linux-x64/gen_snapshot.foa-real')
          .writeAsBytesSync(x64ElfHeader() + List<int>.filled(16, 0));
      File('$base/linux-x64/gen_snapshot').writeAsStringSync(
          '#!/bin/sh\nexec qemu -cpu max -L / '
          '"$base/linux-x64/gen_snapshot.foa-real" "\$@"\n');
      Process.runSync('chmod', ['755', '$base/linux-x64/gen_snapshot']);
      Directory('$base/linux-arm64').createSync(recursive: true);
      File('$base/linux-arm64/gen_snapshot').writeAsStringSync(
          '#!/bin/sh\nexec qemu -cpu max -L / '
          '"$base/linux-x64/gen_snapshot" "\$@"\n');
      Process.runSync('chmod', ['755', '$base/linux-arm64/gen_snapshot']);
      expect(
        File('$base/linux-arm64/gen_snapshot')
            .readAsStringSync()
            .contains('.foa-real'),
        isFalse,
        reason: '前置：旧对称 wrapper 指向裸位（已被原位包装占位）',
      );

      runSh(root, fillFor(root, QemuCompat.engineWrapScript));

      final sym = File('$base/linux-arm64/gen_snapshot').readAsStringSync();
      expect(sym.contains('gen_snapshot.foa-real'), isTrue,
          reason: '对称段必须无条件重建（Bug 445 同款教训：形态合法不等于'
              '指向正确）——旧"#! 就跳过"短路放过了指向已死的 wrapper');
    });
  });

  group('Bug 449 · reassert 的 INPLACE 段（precache 冲掉原位 wrapper 的自愈）', () {
    const s = QemuCompat.wrapReassertScript;

    test('必须存在 REASSERT_INPLACE 段且复刻原位判据', () {
      expect(s.contains('REASSERT_INPLACE='), isTrue,
          reason: '对称位被冲由 put 兜底；原位被冲此前**无人兜底**——'
              'precache 把官方 ELF 写回 linux-x64/ 时构建直接拿到裸 ELF');
      expect(
        s.contains(r'for d in "$E"/android-*/linux-x64 "$E"/linux-x64; do'),
        isTrue,
      );
    });

    test('端到端：原位 wrapper 被 precache 覆写后 reassert 自愈（真实执行）',
        () {
      final root = makeEngineFixture();
      runSh(root, fillFor(root, QemuCompat.engineWrapScript)); // 先建全包装态
      final base = '${root.path}/engine/android-arm64-release';
      // 模拟 precache：把官方 ELF 写回原位（.foa-real 保留——precache 不认识它）
      File('$base/linux-x64/gen_snapshot')
          .writeAsBytesSync(x64ElfHeader() + List<int>.filled(32, 0));
      expect(head4('$base/linux-x64/gen_snapshot'), '7f454c46',
          reason: '前置：原位已被冲回裸 ELF');

      final out = runSh(root, fillFor(root, QemuCompat.wrapReassertScript));
      // INPLACE 计数与 put 段共用计数器（REASSERT_INPLACE 是累加值），
      // 断言"≥1 重建发生"而不是具体数字，避免和 put 的无条件重建耦合。
      final m = RegExp(r'REASSERT_INPLACE=(\d+)').firstMatch(out);
      expect(m, isNotNull, reason: '必须输出 REASSERT_INPLACE 行：$out');
      expect(int.parse(m!.group(1)!), greaterThanOrEqualTo(1),
          reason: '原位必须至少重建 1 个：$out');
      expect(head4('$base/linux-x64/gen_snapshot'), '23212f62',
          reason: '原位必须恢复成 wrapper');
      expect(head4('$base/linux-x64/gen_snapshot.foa-real'), '7f454c46',
          reason: '.foa-real 仍是真身（mv 覆盖同名也只会以官方 ELF 收尾，等价）');
    });

    test('幂等：全包装态下重复 reassert 不堆积 .foa-real（真实执行）', () {
      final root = makeEngineFixture();
      runSh(root, fillFor(root, QemuCompat.engineWrapScript));
      runSh(root, fillFor(root, QemuCompat.wrapReassertScript));
      runSh(root, fillFor(root, QemuCompat.wrapReassertScript));
      final base = '${root.path}/engine/android-arm64-release';
      expect(
        Directory('$base/linux-x64')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.foa-real'))
            .length,
        1,
        reason: 'INPLACE 反复跑不得把 wrapper 再 mv 一层（堆积 *.foa-real.foa-real）',
      );
      expect(head4('$base/linux-x64/gen_snapshot'), '23212f62');
    });
  });

  group('Bug 449 · AOT_FP 角色判定与 DEF 探针', () {
    const s = QemuCompat.buildPreflightScript;

    test('AOT_FP 的 for 循环只允许出现一次（结构哨兵）', () {
      // Bug 449 收尾时真实发生的错误：复制粘贴留下两个 for 头、一个 done
      // ——bash -n 抓语法，这条抓"同段重复"的形态本身。
      final n = RegExp(r'^for u in', multiLine: true).allMatches(s).length;
      expect(n, 1, reason: 'AOT_FP 段出现 $n 个 for u in 头——复制粘贴漂移');
    });

    test('角色判定：*.foa-real 是 REAL 期望 raw，其余是 SLOT 期望 wrapper', () {
      expect(s.contains(r'*.foa-real)    role=REAL; want=raw ;;'), isTrue,
          reason: '真身期望 raw');
      expect(s.contains(r'*)             role=SLOT; want=wrapper ;;'), isTrue,
          reason: '原位包装后 linux-x64/ 普通名字也是 wrapper（SLOT）');
    });

    test('指纹列表必须含原位真身条目 gen_snapshot.foa-real', () {
      expect(
        s.contains(
            r'@ENGINE@/android-arm64-release/linux-x64/gen_snapshot.foa-real'),
        isTrue,
        reason: '否则指纹看不到真身状态——真身被覆盖时全表照样全绿',
      );
    });

    test('AOT_LOAD_DEF 探针必须指向 .foa-real（裸 qemu 跑不了 sh 脚本）', () {
      expect(
        s.contains(r'dgs=@ENGINE@/android-arm64-release/'
            r'linux-x64/gen_snapshot.foa-real'),
        isTrue,
        reason: '原位包装后 linux-x64/gen_snapshot 是 #! wrapper，'
            '裸 qemu 无法执行 shell 脚本——DEF 对照必须用真身',
      );
    });
  });

  group('Bug 449 · verify 冒烟与 TARGET 检查覆盖原位位', () {
    const s = QemuCompat.verifyScript;

    test('冒烟必须覆盖 GEN_INPLACE / IMPELLERC_INPLACE（构建实际调用的路径）', () {
      expect(s.contains('GEN_INPLACE'), isTrue,
          reason: 'android-arm64-release/linux-x64/gen_snapshot 是 AOT 实际执行位');
      expect(s.contains('IMPELLERC_INPLACE'), isTrue,
          reason: 'linux-x64/impellerc 是 shader 实际执行位（Bug 437 教训的'
              '原位版：验证不到的路径就是会崩的路径）');
      expect(s.contains('FONT_SUBSET_INPLACE'), isTrue,
          reason: 'Bug 451：font-subset 原位位同样要冒烟——评分以 INPLACE 为准');
    });

    test('TARGET 检查必须指向 .foa-real 真身', () {
      expect(s.contains(r'linux-x64/impellerc.foa-real'), isTrue);
      expect(
        s.contains(
            r'android-arm64-release/linux-x64/gen_snapshot.foa-real'),
        isTrue,
        reason: '转发目标一律是真身——检查 wrapper 指向的裸位没有意义'
            '（原位已经是 wrapper 自己）',
      );
    });
  });

  group('Bug 449 · 卸载必须还原 linux-x64 原位包装', () {
    const s = QemuCompat.uninstallScript;

    test('还原循环覆盖 android-*/linux-x64 与顶层 linux-x64', () {
      expect(
        s.contains(r'for d in "$E"/android-*/linux-x64 "$E"/linux-x64; do'),
        isTrue,
        reason: '与 engineWrapScript 的原位段同一份目录清单——卸载漏哪层，'
            '哪层就留下一堆跑不了的 #! 脚本',
      );
      expect(s.contains(r'rm -f "$b"'), isTrue);
      expect(s.contains(r'mv "$f" "$b"'), isTrue);
    });

    test('端到端：卸载后原位恢复裸 ELF、.foa-real 与 wrapper 消失（真实执行）',
        () {
      final root = makeEngineFixture();
      runSh(root, fillFor(root, QemuCompat.engineWrapScript));
      final base = '${root.path}/engine/android-arm64-release';
      expect(head4('$base/linux-x64/gen_snapshot'), '23212f62');

      // 卸载脚本后半是 apt purge（不可在测试环境执行），抽前段还原循环跑。
      // 注意：循环体引用 $E，必须把 E=<engine> 赋值行一起带上。
      final script = fillFor(root, QemuCompat.uninstallScript);
      final eLine = script.split('\n').firstWhere((l) => l.startsWith('E='));
      final start = script.indexOf(r'for d in "$E"');
      expect(start, greaterThan(0), reason: '还原循环锚点丢失');
      // 截到还原循环结束（第二层 done）
      final firstDone = script.indexOf('done', start);
      final segEnd = script.indexOf('done', firstDone + 4) + 4;
      runSh(root, '$eLine\n${script.substring(start, segEnd)}');

      expect(head4('$base/linux-x64/gen_snapshot'), '7f454c46',
          reason: '官方名字位必须还原成真身 ELF');
      expect(File('$base/linux-x64/gen_snapshot.foa-real').existsSync(),
          isFalse, reason: '.foa-real 必须消失');
    });
  });

  group('Bug 449 · wrapCheckScript 全量比对（chk 与复核共用）', () {
    test('契约：真身感知 + 双位 #! 检查 + 分层 miss 标签', () {
      final s = ToolchainEnsure.wrapCheckScript('WRAP_CHECK');
      expect(
        s.contains(
            r'real="$f"; [ -f "$f.foa-real" ] && real="$f.foa-real"'),
        isTrue,
        reason: '读魔数必须读真身——原位已是 wrapper，读它会拿到 #! '
            '然后被魔数判据跳过，缺口永远查不出来',
      );
      expect(s.contains(r'[ -f "$w" ] && head -c 2 "$w"'), isTrue,
          reason: '对称位也必须查（上游修复 ABI 检测后的兜底路径）');
      for (final tag in ['engine:', 'host:', 'sdk:']) {
        expect(s.contains(tag), isTrue, reason: 'miss 标签 $tag 缺失');
      }
      // chk 与复核必须是同一份代码——只许 tag 不同。
      // 比较方式：裁掉末尾 echo 行（唯一含 tag 的位置）后逐字符相同。
      // ⚠️ 不能用 replaceAll(tag) 归一：脚本里的 `od -An` 含 'A'，会被
      // 误换导致假红（第一版就是这么翻的车）。
      String bodyOf(String tag) {
        final s = ToolchainEnsure.wrapCheckScript(tag);
        final i = s.lastIndexOf('echo "');
        expect(i, greaterThan(0), reason: 'echo 行锚点丢失');
        return s.substring(0, i);
      }

      expect(bodyOf('WRAP_CHECK'), bodyOf('VERIFY'),
          reason: '两份手抄脚本已经开始漂移过（miss 标签不一致）——'
              '必须收敛到单一定义，差异只允许在 tag');
      // tag 必须真的插进 echo 行（第一版写成 shell 变量 $tag 恒为空，
      // Dart 侧 startsWith('WRAP_CHECK') 解析失败 → 构建前检查永久误报）
      expect(ToolchainEnsure.wrapCheckScript('WRAP_CHECK')
          .contains('echo "WRAP_CHECK n='), isTrue);
      expect(ToolchainEnsure.wrapCheckScript('VERIFY')
          .contains('echo "VERIFY n='), isTrue);
    });

    test('端到端：全包装态 n=ok；破坏对称位后 miss 带分层标签（真实执行）', () {
      final root = makeEngineFixture();
      runSh(root, fillFor(root, QemuCompat.engineWrapScript));
      // wrapCheckScript 内嵌生产常量路径（engineDir 直接插值），替换后执行
      final chk = ToolchainEnsure.wrapCheckScript('WRAP_CHECK')
          .replaceAll(QemuCompat.engineDir, '${root.path}/engine')
          .replaceAll(QemuCompat.sdkHome, '${root.path}/sdk');
      var out = runSh(root, chk);
      expect(out, contains('n=1 ok=1'), reason: '完整包装态应全绿');

      // 破坏对称位 → 缺口必须被点名
      File('${root.path}/engine/android-arm64-release/linux-arm64/gen_snapshot')
          .deleteSync();
      out = runSh(root, chk);
      expect(out, contains('ok=0'), reason: '对称位缺失必须计数为缺');
      expect(out, contains('engine:gen_snapshot'), reason: '缺口带分层标签');
    });
  });

  group('Bug 449 附属 · NDK strip 补位契约', () {
    test('probe：可执行 llvm-strip 在任一 NDK 版本即 STRIP_OK', () {
      const s = ToolchainEnsure.ndkStripProbeScript;
      expect(s.contains('STRIP_OK'), isTrue);
      expect(s.contains('STRIP_MISSING'), isTrue);
      expect(s.contains(r'[ -e "$s" ] || continue'), isTrue,
          reason: 'glob 不展开时字面量路径必须被 -e 守卫跳过');
    });

    test('ensure：按 NDK 版本目录遍历，不得 glob 整条子路径（字面量垃圾目录）',
        () {
      const s = ToolchainEnsure.ndkStripEnsureScript;
      expect(s.contains(r'for d in /opt/android-sdk/ndk/*/; do'), isTrue,
          reason: '空壳 NDK 没有 toolchains 子树，整条子路径 glob 不展开时 '
              'mkdir 会创建带 * 字面量的垃圾目录');
      expect(s.contains(r'[ -d "$d" ] || continue'), isTrue);
      expect(s.contains(r'ln -sf "$(command -v llvm-strip)"'), isTrue,
          reason: 'Debian llvm 原生 arm64、不过 qemu、能剥任意架构 ELF');
      expect(s.contains(r'ln -sf "$(command -v llvm-objcopy)"'), isTrue);
      expect(s.contains('STRIP_FIXED'), isTrue);
      expect(s.contains('LLVM_UNAVAILABLE'), isTrue,
          reason: 'llvm 装不上时显式早退并 exit 0——错误由 Dart 侧按输出判定');
      // 回归哨兵：不许退回整条子路径 glob 的写法
      expect(
        RegExp(r'for b in /opt/android-sdk/ndk/\*/toolchains').hasMatch(s),
        isFalse,
      );
    });

    test('接线：build_runner 前置链顺序 ndkStub → ndkStripTools → qemuCompatEnsure',
        () {
      final src = File('lib/toolchain/build_runner.dart').readAsStringSync();
      final iStub = src.indexOf('ndkStub()');
      final iStrip = src.indexOf('ndkStripTools()');
      final iQemu = src.indexOf('qemuCompatEnsure(');
      expect(iStub, greaterThan(0), reason: 'ndkStub 调用点');
      expect(iStrip, greaterThan(iStub),
          reason: 'strip 补位依赖 ndkStub 先建出的 NDK 版本目录');
      expect(iQemu, greaterThan(iStrip), reason: '兼容层确保在其后');
      expect(src.contains(r"lines.add('⚠ $sErr（不阻断构建）');"), isTrue,
          reason: 'llvm 不可用时不阻断——留给 strip 阶段报错，'
              '避免网络问题卡死整个构建入口');
    });
  });
}
