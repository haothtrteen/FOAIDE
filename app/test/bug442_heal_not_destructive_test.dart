import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_on_android/toolchain/build_runner.dart';
import 'package:flutter_on_android/toolchain/qemu_compat.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bug 442：alpha.48 的自愈**把正常包装也还原了**，导致整条工具链瘫痪。
///
/// 旧判据是「`X.foa-real` 存在 → 还原」，这个判据**无法区分**两类 `.foa-real`：
///
///   (A) 正常包装产物 —— `dart-sdk/bin/dart` 这类。`dart` 是转发脚本，
///       `dart.foa-real` 是它的 x64 真身。**两个文件都必须在**。
///   (B) 真正的损坏 —— 转发脚本内容坏了，此时正确修复是**重建转发脚本**，
///       而不是把真身搬回来（搬回来只会得到一个 arm64 上跑不了的 x64 二进制）。
///
/// 真机后果：`HEALED=22` → `dart-sdk/bin` 下 22 个工具全被还原成 x64 ELF、
/// 转发脚本全没了 → `pub get` 调 `dart` = arm64 上直接执行 x64 ELF →
/// `Illegal instruction` ×5 → 三源六次重试全挂 → `exit 69`。
///
/// 雪上加霜的是 `reassert` **只覆盖引擎目录**，根本不管 `dart-sdk/bin`，
/// 所以还原之后没有任何东西会把它包回去。
///
/// 本文件用**真实 shell 执行**验证修复（与 Bug 441 测试同思路：跑，不要只看文本）。
void main() {
  /// 真实 x86_64 ELF64 头。**必须是 20 字节且 offset 18 = 0x3e**，
  /// 这样 `dd count=19` 读到的末位才是 `3e`，能命中包装器的
  /// `case "$m" in 7f454c46*3e)` 判据。
  ///
  /// ⚠️ 我第一版 fixture 用 `+ b'\x00'*10` 凑长度，把 `e_machine` 挤到
  /// offset 18 之后 —— 结果 19 字节读到的是 `...0003`，包装器正确地
  /// 跳过了它，我一度误判成"修复没生效"。**fixture 错了会看起来像代码错了。**
  Uint8List x64ElfHeader() {
    final b = BytesBuilder();
    b.add([0x7f, 0x45, 0x4c, 0x46]); // \x7fELF
    b.add([0x02, 0x01, 0x01, 0x00]); // 64-bit, LSB, v1
    b.add(List.filled(8, 0)); // pad 到 16
    b.add([0x03, 0x00]); // e_type = ET_DYN (PIE)
    b.add([0x3e, 0x00]); // e_machine = EM_X86_64
    final r = b.toBytes();
    expect(r.length, 20);
    expect(r.sublist(0, 19).last, 0x3e,
        reason: '19 字节读取的末位必须是 0x3e，否则包装器判据不命中');
    return r;
  }

  /// 一个 FOA 转发脚本（与 gen() 生成物同构，含识别标记）。
  String wrapper(String realPath) => '#!/bin/sh\n'
      '# FOA x86_64 -> qemu-user wrapper (auto-generated, Bug 439/441)\n'
      'exec /usr/bin/qemu-x86_64-static -L / "/lib64/ld-linux-x86-64.so.2" '
      '"$realPath" "\$@"\n';

  /// Dart app-jit 快照头（`flutter_tools.snapshot` 的真实魔数）。
  Uint8List dartSnapshotHeader() =>
      Uint8List.fromList([0xdc, 0xdc, 0xf6, 0xf6, 0, 0, 0, 0]);

  /// 建一个最小但结构真实的工具链目录树，返回根路径。
  Directory makeToolchain() {
    final root = Directory.systemTemp.createTempSync('foa442');
    addTearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });
    Directory('${root.path}/bin/cache/dart-sdk/bin').createSync(recursive: true);
    Directory('${root.path}/engine/android-arm64-release/linux-x64')
        .createSync(recursive: true);
    Directory('${root.path}/sdk/build-tools/36.0.0').createSync(recursive: true);
    return root;
  }

  /// 在 dart-sdk/bin 下造 n 个「正常包装」的工具（真身 + 转发脚本）。
  void makeWrappedTools(Directory root, int n) {
    final dir = '${root.path}/bin/cache/dart-sdk/bin';
    final hdr = x64ElfHeader();
    for (var i = 1; i <= n; i++) {
      final name = i == 1 ? 'dart' : 'tool$i';
      final real = '$dir/$name.foa-real';
      File(real).writeAsBytesSync(hdr);
      File('$dir/$name').writeAsStringSync(wrapper(real));
      Process.runSync('chmod', ['755', '$dir/$name', real]);
    }
    // 引擎层也要有一个真身，让 reassert 的引擎段有活干
    final imp = '${root.path}/engine/android-arm64-release/linux-x64/impellerc';
    File(imp).writeAsBytesSync(hdr);
    Process.runSync('chmod', ['755', imp]);
    // snapshot 是**受害者**不是被包装者，始终是 dart 快照魔数
    File('${root.path}/bin/cache/flutter_tools.snapshot')
        .writeAsBytesSync(dartSnapshotHeader());
  }

  /// 把占位符换成测试用路径。
  ///
  /// ⚠️ 替换顺序很重要：`QemuCompat.fill()` 会先把 `@ENGINE@` / `@FLUTTER@`
  /// 替换成**生产常量**（`engineDir` / `flutterHome`），所以必须
  /// **先拿到这些常量的实际值，再把它换成临时目录** —— 不能指望
  /// 「fill 之前 replace 占位符」，那时 `@ENGINE@` 早就被展开了。
  /// （我第一版就是搞反了顺序，导致脚本里出现真实 `/opt/flutter` 路径。）
  ///
  /// ⚠️⚠️ **安全闸**：这些脚本含 `rm -f` / `mv`，一旦替换写错，就会作用到
  /// **真实的 Flutter 安装目录**上。我调试时真的踩过这个雷：把
  /// `/opt/flutter/bin/cache/dart-sdk/bin/dart` 换成了指向不存在的 qemu 的
  /// 转发脚本，整个 `flutter test` 都跑不起来（手动修回来的）。
  /// 所以下面加两道保险。
  String fillFor(Directory root, String script) {
    final filled = QemuCompat.fill(script)
        .replaceAll(QemuCompat.engineDir, '${root.path}/engine')
        .replaceAll(QemuCompat.flutterHome, root.path)
        .replaceAll(QemuCompat.sdkHome, '${root.path}/sdk')
        .replaceAll(QemuCompat.qemuBin, '/usr/bin/qemu-x86_64-static')
        .replaceAll(QemuCompat.x64Loader, '/lib64/ld-linux-x86-64.so.2');

    // 保险 1：不得残留占位符（`@REAL@` 除外，它由 gen() 内部的 sed 处理）
    final leftover = RegExp(r'@[A-Z_]+@')
        .allMatches(filled)
        .map((m) => m.group(0)!)
        .where((t) => t != '@REAL@')
        .toSet();
    expect(leftover, isEmpty,
        reason: '脚本里残留了未替换的占位符 $leftover —— 会导致操作到错误路径');

    // 保险 2：所有**非注释**行不得引用真实环境路径。
    // 只看非注释行——注释里会提到路径做说明，那是文档不是操作。
    final realRefs = filled
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('#'))
        .where((l) =>
            l.contains(QemuCompat.flutterHome) ||
            l.contains(QemuCompat.engineDir) ||
            l.contains(QemuCompat.sdkHome))
        .toList();
    expect(realRefs, isEmpty,
        reason: '非注释行里出现了真实环境路径 —— 替换写错了，'
            '绝不能拿真实环境做测试。涉及行：$realRefs');
    expect(root.path.startsWith(Directory.systemTemp.path), isTrue,
        reason: '测试根目录必须在 systemTemp 内');
    return filled;
  }

  /// 执行 heal / reassert，返回 stdout。
  String runScript(Directory root, String script) {
    final f = File('${root.path}/_run.sh')..writeAsStringSync(script);
    final r = Process.runSync('/bin/sh', [f.path]);
    expect(r.exitCode, 0,
        reason: '脚本执行失败：${r.stderr}\n---脚本---\n$script');
    return (r.stdout as String);
  }

  /// 数一个目录下还有几个 .foa-real。
  int countReal(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return 0;
    return d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.foa-real'))
        .length;
  }

  /// 判读某文件的头 4 字节（hex）。
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

  group('Bug 442 · 自愈不得破坏正常包装', () {
    test('正常包装态：heal 必须 HEALED=0，22 个包装原样保留', () {
      final root = makeToolchain();
      makeWrappedTools(root, 22);
      const dartDir = '/bin/cache/dart-sdk/bin';
      final d = '${root.path}$dartDir';
      expect(countReal(d), 22);

      final out = runScript(root, fillFor(root, QemuCompat.healScript));

      expect(out, contains('HEALED=0'),
          reason: '正常包装不该被还原。真机旧版本这里输出 HEALED=22，'
              '把 22 个工具全毁掉，直接导致 exit 69');
      expect(countReal(d), 22, reason: '.foa-real 必须全部保留');
      expect(head4('$d/dart'), '23212f62',
          reason: 'dart 必须仍是转发脚本（#!），不能变成裸 ELF');
    });

    test('heal 必须报告 dart 转发层健康（DART=ok 探针）', () {
      final root = makeToolchain();
      makeWrappedTools(root, 22);
      final out = runScript(root, fillFor(root, QemuCompat.healScript));
      expect(out, contains('DART=ok'),
          reason: '这是 Bug 442 的直接探针：转发层若被破坏，'
              '应在构建早期就报出来，而不是等 pub get 报 Illegal instruction');
      expect(out, contains('SNAPSHOT=ok'));
    });

    test('已损坏态：heal 报 DART=ELF_BROKEN 而不是沉默', () {
      final root = makeToolchain();
      makeWrappedTools(root, 22);
      final d = '${root.path}/bin/cache/dart-sdk/bin';
      // 模拟 alpha.48 的破坏：删脚本、真身搬回来
      for (final f in Directory(d).listSync().whereType<File>()) {
        if (!f.path.endsWith('.foa-real')) continue;
        final target = f.path.substring(0, f.path.length - '.foa-real'.length);
        final tf = File(target);
        if (tf.existsSync()) tf.deleteSync();
        f.renameSync(target);
      }
      expect(head4('$d/dart'), '7f454c46', reason: '前置：dart 已是裸 ELF');

      final out = runScript(root, fillFor(root, QemuCompat.healScript));

      expect(out, contains('DART=ELF_BROKEN'),
          reason: '探针必须识别出转发层丢失');
      expect(out, isNot(contains('DART=ok')),
          reason: '不能误报健康');
    });
  });

  group('Bug 442 · reassert 必须能重建 dart-sdk 转发层', () {
    test('reassert 覆盖 dart-sdk/bin（这是之前缺失的兜底）', () {
      final root = makeToolchain();
      makeWrappedTools(root, 22);
      final d = '${root.path}/bin/cache/dart-sdk/bin';
      // 先破坏
      for (final f in Directory(d).listSync().whereType<File>()) {
        if (!f.path.endsWith('.foa-real')) continue;
        final target = f.path.substring(0, f.path.length - '.foa-real'.length);
        final tf = File(target);
        if (tf.existsSync()) tf.deleteSync();
        f.renameSync(target);
      }
      expect(head4('$d/dart'), '7f454c46', reason: '前置：已损坏');

      final out = runScript(root, fillFor(root, QemuCompat.wrapReassertScript));

      expect(out, contains('REASSERT_DART='),
          reason: 'reassert 必须回报 dart-sdk 段的处理数量');
      // 关键断言：dart 被重建为转发脚本
      expect(head4('$d/dart'), '23212f62',
          reason: 'dart 必须被重建为转发脚本；'
              '旧版本 reassert 只管引擎目录，dart-sdk 永远修不回来');
      expect(countReal(d), greaterThanOrEqualTo(20),
          reason: '真身应被搬到 .foa-real 并生成转发脚本');
    });

    test('reassert 幂等：重复执行后最终状态一致（允许重复重建）', () {
      // ⚠️ Bug 445 修改了这条测试的语义，理由很重要：
      //
      // 旧断言是「第二轮 `REASSERT_DART=0` —— 不该被动任何东西」，
      // 它固化的正是 **Bug 445 的病灶**：reassert 靠"看形态"判断要不要重建
      // （`head -c 2 == '#!'` 就跳过）。而真机上 AOT 失步后 gen_snapshot
      // **仍会产出 app.so**，把转发位恢复成**形态合法的 x64 ELF** →
      // reassert 认为"已是好文件"→ 跳过 → 覆盖状态被固化 → 重启构建照样崩。
      //
      // 关键认识：`dart-sdk/bin` 与 `linux-arm64/` 里的转发位**本来就该全是
      // 转发脚本**，不存在"合法的裸 ELF"。所以现在**无条件重建**，
      // 幂等性体现在**最终状态**（dart 永远是转发脚本、.foa-real 不重复
      // 堆积），而不是"第二轮什么都不做"。
      final root = makeToolchain();
      makeWrappedTools(root, 22);
      final d = '${root.path}/bin/cache/dart-sdk/bin';
      final before = head4('$d/dart');
      final script = fillFor(root, QemuCompat.wrapReassertScript);

      runScript(root, script);
      expect(head4('$d/dart'), before, reason: '重建后仍是转发脚本');
      expect(countReal(d), 22, reason: '不该产生重复的 .foa-real');

      final out2 = runScript(root, script);
      // 允许非 0（无条件重建），但**最终状态必须稳定**
      expect(out2, contains('REASSERT_DART='),
          reason: '必须回报处理数量');
      expect(head4('$d/dart'), '23212f62',
          reason: '重复执行后 dart 仍必须是转发脚本');
      expect(countReal(d), 22,
          reason: '重复执行不得堆积 .foa-real（第二次不能再 mv 一次）');
    });

    test('Bug 445：即使转发位是「形态合法的裸 ELF」也必须重建', () {
      // 这是 Bug 445 的精确复现：把转发位换成**形态完全正常的 x64 ELF**
      // （模拟 AOT 失步后 gen_snapshot 产出 app.so 把转发位恢复的情形），
      // 旧判据会跳过它 → REASSERT_DART=0 → 覆盖被固化。
      final root = makeToolchain();
      makeWrappedTools(root, 22);
      final d = '${root.path}/bin/cache/dart-sdk/bin';
      final dart = File('$d/dart');
      // 覆盖成"合法 x64 ELF 形态"
      dart.writeAsBytesSync(x64ElfHeader() + List<int>.filled(128, 0));
      expect(head4('$d/dart'), '7f454c46',
          reason: '前置条件：此刻它是裸 x64 ELF');

      runScript(root, fillFor(root, QemuCompat.wrapReassertScript));

      expect(head4('$d/dart'), '23212f62',
          reason: 'Bug 445：必须以转发脚本覆盖它，'
              '不能因为"形态合法"就跳过（旧判据在此静默失效）');
    });

    test('生成的 dart 转发脚本语法合法（dash 与 bash）', () {
      final root = makeToolchain();
      makeWrappedTools(root, 22);
      final d = '${root.path}/bin/cache/dart-sdk/bin';
      for (final f in Directory(d).listSync().whereType<File>()) {
        if (!f.path.endsWith('.foa-real')) continue;
        final target = f.path.substring(0, f.path.length - '.foa-real'.length);
        final tf = File(target);
        if (tf.existsSync()) tf.deleteSync();
        f.renameSync(target);
      }
      runScript(root, fillFor(root, QemuCompat.wrapReassertScript));

      for (final shell in ['/bin/sh', '/bin/bash']) {
        if (!File(shell).existsSync()) continue;
        final r = Process.runSync(shell, ['-n', '$d/dart']);
        expect(r.exitCode, 0,
            reason: '$shell 语法检查失败：${r.stderr}');
      }
    });
  });

  group('Bug 442 · 结构性约束（防止再次踩坑）', () {
    test('heal 脚本必须带「兄弟是 FOA 脚本则跳过」的判据', () {
      const s = QemuCompat.healScript;
      expect(s.contains('FOA x86_64 -> qemu-user wrapper'), isTrue,
          reason: '必须靠识别标记区分「正常包装」与「孤儿」');
      expect(s.contains('heal_one'), isTrue,
          reason: '还原逻辑必须收敛到一个带判据的函数里，'
              '不能再写成「见 .foa-real 就还原」');
    });

    test('heal 脚本不得出现无判据的一刀切还原', () {
      const s = QemuCompat.healScript;
      // 反证：不应再有无条件的 `rm -f "$b"; mv "$f" "$b"` 直接出现在循环里
      // （必须经由 heal_one 的判据）
      final bad = RegExp(
        r'for f in [^\n]*\.foa-real[^\n]*\n(?:[^\n]*\n)*?[^\n]*rm -f "\$b"',
      );
      expect(bad.hasMatch(s), isFalse,
          reason: '循环里不得直接 rm/mv，必须走 heal_one 的判别');
    });

    test('reassert 脚本必须显式声明 @FLUTTER@ 并遍历 dart-sdk/bin', () {
      const s = QemuCompat.wrapReassertScript;
      expect(s.contains('F=@FLUTTER@'), isTrue,
          reason: 'reassert 之前只有 E=@ENGINE@，是 Bug 442 无法自愈的根因');
      expect(s.contains('dart-sdk/bin'), isTrue,
          reason: '必须覆盖 dart-sdk/bin —— 这是 flutter 命令的入口');
      expect(s.contains('REASSERT_DART='), isTrue,
          reason: '必须有可观测的输出，便于真机排查');
    });

    test('heal 的注释必须记录 Bug 442 的两类 .foa-real 区分', () {
      const s = QemuCompat.healScript;
      expect(s.contains('Bug 442'), isTrue,
          reason: '把教训写在代码里，防止后人再把判据改回一刀切');
      expect(s.contains('正常包装'), isTrue);
    });
  });

  group('Bug 442 · 构建日志分诊', () {
    test('pub get 阶段的 Illegal instruction 指向 Bug 442，而不是 AOT 的 Bug 428',
        () {
      final r = BuildRunner.I..hints.clear();
      r.debugFeedForTest('Illegal instruction');
      expect(r.hints.any((h) => h.contains('Bug 442')), isTrue,
          reason: '这条出现在 pub get 前后、没有编译上下文，'
              '应当指向 dart-sdk 转发层丢失，而不是 shader 编译问题');
    });

    test('AOT 阶段的 SIGILL 上下文仍指向 Bug 428（不能被新分支抢走）', () {
      final r = BuildRunner.I..hints.clear();
      r.debugFeedForTest('impellerc failure:');
      expect(r.hints.any((h) => h.contains('Bug 428')), isTrue,
          reason: '带 impellerc 上下文的必须是 Bug 428 —— 新分支排前面时'
              '如果写得太宽泛，会把这条吃掉，误导排查方向');
      expect(r.hints.any((h) => h.contains('Bug 442')), isFalse);
    });

    test('exit code -4 的 shader 报错仍走 Bug 428', () {
      final r = BuildRunner.I..hints.clear();
      r.debugFeedForTest(
          "Shader compilation of 'ink_sparkle.frag' failed with exit code -4");
      expect(r.hints.any((h) => h.contains('Bug 428')), isTrue);
      expect(r.hints.any((h) => h.contains('Bug 442')), isFalse);
    });
  });
}
