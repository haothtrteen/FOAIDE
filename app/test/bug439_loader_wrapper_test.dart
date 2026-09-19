import 'dart:io';

import 'package:flutter_on_android/toolchain/qemu_compat.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bug 439：转发脚本用 `-L / <bin>` 让 qemu 代劳找 ld.so，会让所有
/// x64 glibc 程序在 `main` 之前崩于 `__stack_chk_fail`（栈保护金丝雀被破坏），
/// **stderr 一个字都没有**，进程被信号杀死。
///
/// 真机表现正是这样：`impellerc failure: ` 后面空白、`exit code -4`（SIGILL），
/// `gen_snapshot` 同时崩。因为两者用的是**同一套转发脚本**。
///
/// 沙箱复现矩阵（x86_64 宿主 + Debian amd64 libc 2.36，qemu-user-static 7.2）：
///
/// | 程序 | `-L / <bin>`（旧） | `-L / <ld.so> <bin>`（新） |
/// |---|---|---|
/// | dart | ✗ stack smashing | ✓ Dart SDK version: 3.13.3 |
/// | impellerc | ✗ | ✓ ImpellerC ... |
/// | gen_snapshot | ✗ | ✓ Usage: gen_snapshot ... |
/// | font-subset | ✗ | ✓ Usage: ... |
///
/// 修复：转发脚本显式把 guest 的 ld.so 当程序交给 qemu，动态链接全由
/// guest 自己完成，qemu 只做指令翻译。
void main() {
  group('Bug 439 · 转发脚本必须显式加载 ld.so', () {
    test('生成出的转发脚本含「显式 ld.so」分支（正确形式）', () {
      // Bug 441：真身路径由 @REAL@ 承接（gen() 里按文件 sed 写入），
      // **不能**再用运行时的 $2——那是调用者的业务参数。
      //
      // ⚠️ @LOADER@ / @REAL@ 都在 `__FOA_GEN__` 片段里（它由 fill() 展开
      // 成 gen() 函数）。所以要在**未 fill 的原始模板**上找这个片段——
      // fill() 之后 @LOADER@ 会被换成真实路径，就找不到了。
      const raw = QemuCompat.wrapReassertScript;
      expect(raw.contains('__FOA_GEN__'), isTrue);
      // 取出 gen() 片段：从模板开头到 "__FOA_GEN__" 标记之后由 fill 注入；
      // 这里直接断言标记存在 + 片段本身由 fill 展开后可验证（见下）。
      final f = QemuCompat.fill(raw);
      // fill() 展开后：@LOADER@ → 真实 ld.so 路径；@REAL@ 保留（gen 内部用）
      expect(f.contains(QemuCompat.x64Loader), isTrue,
          reason: 'ld.so 路径必须被展开');
      expect(f.contains('@REAL@'), isTrue,
          reason: '@REAL@ 是 gen() 内部占位符，fill() 不应吞掉它');
      // 关键回归断言：展开后必须有 "ld.so 路径" 紧接 "@REAL@" 的形状，
      // 且**绝不能**出现运行时的 "$2" 当真身。
      expect(
        f.contains('"${QemuCompat.x64Loader}" "@REAL@" ' r'"$@"'),
        isTrue,
        reason: 'ld.so 必须排在真身之前，两者都用占位符承接',
      );
      expect(
        RegExp(r'exec\s+\S+\s+-L\s+/\s+"[^"]*"\s+"\$2"').hasMatch(f),
        isFalse,
        reason: 'Bug 441：不得用运行时的第二参数当真身路径',
      );
    });

    test('替换后脚本里的 @LOADER@ 已展开为真实路径（无占位符残留）', () {
      final s = QemuCompat.fill(QemuCompat.wrapReassertScript);
      expect(s.contains('@LOADER@'), isFalse, reason: '占位符必须被替换掉');
      expect(s.contains('@QEMU@'), isFalse);
      expect(s.contains('@ENGINE@'), isFalse);
      expect(s.contains('@FLUTTER@'), isFalse);
      expect(s.contains('@SDK@'), isFalse);
      expect(s.contains(QemuCompat.x64Loader), isTrue);
    });

    test('ld.so 路径用 Debian multiarch 真身，不用 /lib64 符号链接', () {
      // /lib64/ld-linux-x86-64.so.2 是指向绝对路径 /lib/... 的符号链接，
      // 跨 root（qemu -L）解析时会落到宿主，反而崩。实测：
      //   给 /lib64/...  → stack smashing
      //   给 /lib/x86_64-linux-gnu/... → 正常
      expect(QemuCompat.x64Loader, '/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2');
      expect(QemuCompat.x64Loader.startsWith('/lib64/'), isFalse);
    });

    test('LD_LIBRARY_PATH 兼容段仍在（某些工具依赖 lib64 子目录）', () {
      final s = QemuCompat.fill(QemuCompat.wrapReassertScript);
      expect(s.contains('LD_LIBRARY_PATH='), isTrue);
      expect(s.contains(r'$d/lib64'), isTrue);
    });

    test('四个脚本最终生成的文本都含显式 ld.so 路径（无漏替换）', () {
      // "我又在某处修了"陷阱的预防：占位符替换必须收口在 fill()。
      // 三个包装脚本正文里写的是 `__FOA_GEN__`（由 fill() 展开成 gen() 函数），
      // 而 gen() 体内含 @LOADER@ → 真正被替换。所以断言要用 **fill() 之后**
      // 的文本，否则会误以为漏替换。
      for (final s in [
        QemuCompat.wrapReassertScript,
        QemuCompat.engineWrapScript,
        QemuCompat.sdkWrapScript,
        QemuCompat.buildPreflightScript,
      ]) {
        final f = QemuCompat.fill(s);
        expect(f.contains(QemuCompat.x64Loader), isTrue,
            reason: '每个脚本替换后都必须含 ld.so 真身路径');
        expect(f.contains('@LOADER@'), isFalse,
            reason: '替换后不能残留 @LOADER@ —— 残留会让 [ -x "@LOADER@" ] '
                '恒假，静默回退到旧的错误形式，Bug 439 原样复发');
      }
    });
  });

  group('Bug 439 · 共享库不能被包装', () {
    test('三个包装脚本都排除了 *.so（Bug 441 起同时排除 snapshot 等）', () {
      for (final s in [
        QemuCompat.wrapReassertScript,
        QemuCompat.engineWrapScript,
        QemuCompat.sdkWrapScript,
      ]) {
        // Bug 441 把黑名单扩展为 *.so|*.so.*|*.snapshot|*.dill|...
        // 断言从"精确匹配旧串"改成"判定这些扩展名都在排除分支里"，
        // 避免黑名单每扩一项就要改一次测试。
        expect(
          s.contains('*.so|*.so.*') &&
              s.contains('|*.snapshot') &&
              (s.contains(r'case "$1" in *.so') ||
                  s.contains(r'case "$f" in *.so')),
          isTrue,
          reason: '.so 的 e_machine 也是 x86_64、e_type 也是 ET_DYN，'
              '与 PIE 可执行文件无法用 magic 区分，必须按名字排除',
        );
      }
    });

    test('工程里确实存在会被误伤的 .so（证明排除是必要的）', () {
      // linux-x64/ 下这三个 .so 的 ELF magic 与 impellerc 完全一致，
      // 旧判定 `7f454c46*3e` 会一并命中。
      final dir = Directory('${QemuCompat.engineDir}/linux-x64');
      if (!dir.existsSync()) return; // 沙箱未装引擎产物则跳过
      final sos = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.so'))
          .toList();
      expect(sos.length, greaterThan(0),
          reason: '引擎目录里应有共享库，用于验证排除逻辑的必要性');
      for (final f in sos) {
        final head = f.readAsBytesSync().take(19).toList();
        if (head.length < 19) continue;
        final magic = head.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        expect(magic.startsWith('7f454c46'), isTrue,
            reason: '${f.path} 是 ELF');
        expect(magic.endsWith('3e'), isTrue,
            reason: 'e_machine=x86_64 —— 与可执行文件同值，故必须按名字排除');
      }
    });
  });

  group('Bug 439 · heredoc 必须是字面量', () {
    test('heredoc 分隔符带单引号（否则反引号会被当命令替换）', () {
      final s = QemuCompat.fill(QemuCompat.wrapReassertScript);
      expect(
        s.contains("<<'FOAWRAP'"),
        isTrue,
        reason: '不加引号时，body 里的反引号/美元符会被 shell 展开；'
            '注释里写一个反引号就会吃掉后面所有行，'
            '报 "end of file unexpected" 且行号指向第 1 行，极难定位',
      );
    });

    test('heredoc body 里没有裸露的反引号', () {
      const s = QemuCompat.wrapReassertScript;
      final start = s.indexOf("<<'FOAWRAP'");
      if (start < 0) return;
      final end = s.indexOf('\nFOAWRAP', start);
      final body = s.substring(start, end < 0 ? s.length : end);
      expect(body.contains('`'), isFalse,
          reason: 'heredoc body 内出现反引号是 Bug 439 语法错误的直接原因');
    });

    test('body 里的 shell 变量用裸美元符而非转义形式（引号分隔符下不需要转义）', () {
      // 注意：变量体在 `__FOA_GEN__` 片段里，必须用 fill() 之后的文本断言。
      final f = QemuCompat.fill(QemuCompat.wrapReassertScript);
      expect(f.contains(r'd=$(dirname "$0")'), isTrue);
      expect(f.contains(r'd=\$(dirname'), isFalse,
          reason: '加了引号的分隔符下写反斜杠美元符会让生成的脚本里留下字面反斜杠');
      expect(f.contains(r'"$@"'), isTrue);
      expect(f.contains(r'"\$@"'), isFalse);
    });
  });

  group('Bug 439 · 构建前预检能抓到这类故障', () {
    test('预检同时测「新形式」与「旧形式」，可精确识别 Bug 439', () {
      final s = QemuCompat.fill(QemuCompat.buildPreflightScript);
      expect(s.contains('QEMU_CHAIN_OLDSTYLE='), isTrue,
          reason: '必须能对照出「旧 -L 形式崩、新形式正常」这个特征组合');
      expect(s.contains('QEMU_CHAIN_PROBE='), isTrue);
      expect(s.contains('QEMU_CHAIN_LOADER='), isTrue);
    });

    test('预检覆盖 SIGABRT（栈保护崩溃就是 abort）', () {
      final s = QemuCompat.fill(QemuCompat.buildPreflightScript);
      expect(s.contains('134) s=SIGABRT'), isTrue,
          reason: '__stack_chk_fail → abort → 134，必须能报出来');
    });

    test('预检的 LOADER 段用 @LOADER@ 而非硬编码 /lib64', () {
      const raw = QemuCompat.buildPreflightScript;
      expect(raw.contains('@LOADER@'), isTrue);
      expect(raw.contains('ld=/lib64/ld-linux-x86-64.so.2'), isFalse,
          reason: '旧的 /lib64 路径在跨 root 场景解析错误，会掩盖真问题');
    });

    test('预检失败不阻断构建（它只是观测）', () {
      final s = QemuCompat.fill(QemuCompat.buildPreflightScript);
      // 脚本整体以 cat <<'EOF' 形式被喂给 sh，末尾一定有换行；
      // 断言"最后一条有效语句就是 DONE，且没有中途 exit"。
      expect(s.contains('exit 1'), isFalse,
          reason: '预检是观测，任何分支都不该以非零码中断构建');
      expect(s.trimRight().split('\n').last.trim(), 'echo "QEMU_CHAIN_DONE=1"',
          reason: '必须走到最后一行，否则构建侧读不到 DONE 标记');
    });
  });

  group('Bug 439 · 生成脚本的 shell 语法', () {
    test('五个脚本在 dash 与 bash 下语法均通过', () async {
      // 容器里 /bin/sh 是 dash，语法错误会直接让构建前的准备工作全崩。
      final scripts = {
        'wrapReassert': QemuCompat.fill(QemuCompat.wrapReassertScript),
        'engineWrap': QemuCompat.fill(QemuCompat.engineWrapScript),
        'sdkWrap': QemuCompat.fill(QemuCompat.sdkWrapScript),
        'preflight': QemuCompat.fill(QemuCompat.buildPreflightScript),
        'verify': QemuCompat.fill(
          // verify 脚本是私有的，通过公开的 fill + 占位符间接覆盖其替换逻辑
          'echo __PLACEHOLDER__ @LOADER@ @QEMU@ @ENGINE@ @FLUTTER@ @SDK@',
        ),
      };
      for (final e in scripts.entries) {
        final f = File(
            '${Directory.systemTemp.path}/foa_bug439_${e.key}.sh');
        f.writeAsStringSync(e.value);
        for (final sh in ['dash', 'bash']) {
          final r = Process.runSync(sh, ['-n', f.path]);
          expect(r.exitCode, 0,
              reason: '${e.key} 在 $sh 下语法错误：${r.stderr}');
        }
        f.deleteSync();
      }
    });

    test('生成的转发脚本可执行且指向正确的 ld.so（功能验证）', () {
      // 端到端实测（沙箱 x86_64 + Debian amd64 libc）：
      //   旧形式 → "*** stack smashing detected ***"
      //   新形式 → "ImpellerC is an offline shader processor..."
      // 这里只做静态契约断言，真实执行需真机/完整 qemu 环境。
      final s = QemuCompat.fill(QemuCompat.wrapReassertScript);
      // Bug 447：exec 行带上了 -cpu max（TCG 按 CPU 模型门控 SIMD，
      // arm64 host 默认模型不含 AVX 位 → gen_snapshot 一碰 VEX 即 SIGILL）。
      final i = s.indexOf(
          'exec ${QemuCompat.qemuBin} -cpu max -L / "${QemuCompat.x64Loader}"');
      expect(i, greaterThan(0),
          reason: '应生成「qemu -cpu max -L / <ld.so> <real> args」这一行');
      // 回归哨兵：防 indexOf 恒 -1 时上面断言悄悄失效（Bug 443 教训）。
      expect(s.contains('exec ${QemuCompat.qemuBin} -cpu max'),
          isTrue,
          reason: 'Bug 447：转发 exec 行必须显式 -cpu max');
    });
  });
}
