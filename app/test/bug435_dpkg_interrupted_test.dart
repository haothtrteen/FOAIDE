import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Bug 435：清理数据重装后构建报 `E: dpkg was interrupted`
///
/// 真机报错原文（2026-09-19 截图，构建中断于「准备构建环境」0%）：
/// ```
/// ✗ 自动安装 git 失败：
/// E: dpkg was interrupted, you must manually run
///    'dpkg --configure -a' to correct the problem.
/// ```
///
/// 这是 **Bug 434 的下游后果**：卸载兼容层时 apt 在 essential 拒绝下
/// 中途失败，dpkg 数据库留下未完成事务。之后**任何** apt 调用都会被
/// 拦下——包括 `apt-get update`。
///
/// 关键缺陷不在"有没有自愈代码"（`AptTools.ensure` 早就有），而在于
/// **自愈只加在了我想到的那条路径上**：`ToolchainEnsure.git()` 直接
/// `apt-get install git`，没有自愈。同一个故障因此在 git 路径上重现，
/// 且报错文案指向 git，真因（dpkg 状态）完全不可见。
///
/// 教训（与 Bug 429/433 同源）：**"我在某处修过"不代表"所有执行路径
/// 都被修复"**。凡是调用 apt 的地方都是同一个前置条件的消费者，
/// 前置条件必须**在每条路径上**成立，而不是在一条路径上。
void main() {
  late String toolchain;
  late String installer;

  setUpAll(() {
    toolchain = File('lib/toolchain/toolchain_ensure.dart').readAsStringSync();
    installer = File('lib/toolchain/sdk_installer.dart').readAsStringSync();
  });

  group('Bug 435 · dpkg 自愈抽成公共常量', () {    test('repairDpkg 常量存在且暴露在 AptTools 上', () {
      expect(installer.contains('static const String repairDpkg'), isTrue,
          reason: '自愈逻辑必须可被其它路径复用，不能再写死在内联字符串里');
    });

    test('repairDpkg 含清锁 / configure -a / -f install 三步', () {
      final m = RegExp(r"static const String repairDpkg = '''(.*?)''';",
              dotAll: true)
          .firstMatch(installer);
      expect(m, isNotNull, reason: '找不到 repairDpkg 定义');
      final body = m!.group(1)!;

      expect(body.contains('/var/lib/dpkg/lock-frontend'), isTrue,
          reason: '第 1 步：清陈旧锁（exec 超时/取消杀进程后残留）');
      expect(body.contains('dpkg --configure -a'), isTrue,
          reason: '第 2 步：补完未完成的解包/配置');
      expect(body.contains('apt-get -f install'), isTrue,
          reason: '第 3 步：修复破损依赖');
    });

    test('repairDpkg 每步都不阻断后续（自愈不该成为新的失败点）', () {
      final m = RegExp(r"static const String repairDpkg = '''(.*?)''';",
              dotAll: true)
          .firstMatch(installer);
      final body = m!.group(1)!;
      // 不得出现裸 exit
      expect(body.contains('exit'), isFalse,
          reason: '自愈失败必须继续往下走，仍给真正的安装一次机会');
      // 不得用 && 串联（前一步失败会让后一步不执行）
      expect(body.contains('&&'), isFalse,
          reason: '三步之间不能用 && 串联——那正是原先 git 路径的坑');
    });

    test('AptTools.ensure 改为引用 repairDpkg（不再内联一份）', () {
      final ensureIdx = installer.indexOf('static Future<void> ensure(');
      expect(ensureIdx, greaterThan(0));
      final body = installer.substring(ensureIdx, ensureIdx + 1200);
      expect(body.contains(r'$repairDpkg'), isTrue,
          reason: 'ensure 应复用公共常量，避免两份实现各自漂移');
      // 不应再有一份内联的清锁命令
      expect(
        body.contains(
            'rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock '),
        isFalse,
        reason: '内联副本已抽出，ensure 里不该再有第二份',
      );
    });
  });

  group('Bug 435 · git 安装路径必须在 apt 之前自愈', () {
    late String gitBody;

    setUpAll(() {
      // 按大括号配对切出 git() 方法体——比找「下一个方法声明」稳，
      // 方法内部的泛型 / 字符串都能正确处理。
      const sig = "Future<String?> git() async {";
      final idx = toolchain.indexOf(sig);
      expect(idx, greaterThan(0), reason: '找不到 git() 方法');
      var i = idx + sig.length - 1; // 指向 '{'
      var depth = 0;
      var end = toolchain.length;
      for (; i < toolchain.length; i++) {
        final c = toolchain[i];
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) {
            end = i + 1;
            break;
          }
        }
      }
      gitBody = toolchain.substring(idx, end);
      expect(gitBody.contains('apt-get install'), isTrue,
          reason: '切片失败：git() 体内应含 apt-get install');
    });

    /// git() 方法体的**代码行**（剔除 // 注释）。
    ///
    /// 必须剔除：本方法的注释里为了解释 Bug 435 提到了 `apt-get update`
    /// 和 `apt-get install`，直接 indexOf 会命中注释，导致断言全部落空
    /// 或反向失败——这个坑在 Bug 432 的测试里也踩过一次。
    List<String> codeLines() => gitBody
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .toList();

    /// 在代码行里找位置（返回行号），找不到返回 -1。
    int lineOf(String needle) =>
        codeLines().indexWhere((l) => l.contains(needle));

    test('git 缺失时先跑 dpkg 自愈，再 apt 安装', () {
      final repairLine = lineOf('AptTools.repairDpkg');
      final installLine = lineOf('apt-get install');
      final updateLine = lineOf('apt-get update');
      expect(repairLine, greaterThan(0),
          reason: 'Bug 435 回归点：git 路径原先没有自愈，导致 dpkg 中间态'
              '在这里炸成"自动安装 git 失败"');
      expect(installLine, greaterThan(0), reason: '应有真正的安装命令（非注释）');
      expect(repairLine < installLine, isTrue,
          reason: '必须在 apt 之前自愈——dpkg 中间态会连 update 都拦下');
      expect(repairLine < updateLine, isTrue,
          reason: '自愈必须早于 apt-get update（update 也会被中间态拦住）');
    });

    test('自愈失败不放弃安装（仍给一次机会）', () {
      final repairLine = lineOf('AptTools.repairDpkg');
      final installLine = lineOf('apt-get install');
      expect(repairLine, greaterThan(0));
      expect(installLine, greaterThan(repairLine));

      // 在**非注释代码行**之间找 return/throw
      final between = codeLines()
          .sublist(repairLine, installLine)
          .join('\n');
      expect(RegExp(r'\breturn\b').hasMatch(between), isFalse,
          reason: '自愈失败就 return 放弃安装，会比原问题更糟');
      expect(RegExp(r'\bthrow\b').hasMatch(between), isFalse);
    });

    test('apt update 与 install 不用 && 串联（update 失败仍能尝试、报错不误导）', () {
      final lines = codeLines();
      final updIdx = lines.indexWhere((l) => l.contains('apt-get update'));
      final instIdx = lines.indexWhere((l) => l.contains('apt-get install'));
      expect(updIdx, greaterThan(0), reason: 'git() 内应有真正的 apt-get update');
      expect(instIdx, greaterThan(updIdx), reason: 'install 应在 update 之后');

      // update 命令由多行相邻字符串字面量拼成：从 update 行起到 install
      // 行之前，整体作为一个 shell 命令看，不得出现 `&&` 连接 install
      final updBlock = lines.sublist(updIdx, instIdx).join(' ');
      expect(updBlock.contains('&&'), isFalse,
          reason: '原先 `update && install`：dpkg 中间态下 update 失败，'
              'install 根本不执行，报错停在 update 输出上，用户以为是 git 的问题');

      // 该块的末尾必须以下一个命令的分隔符收束（\n），而不是紧接 install
      expect(updBlock.contains(r'\n'), isTrue,
          reason: 'update 必须以 \\n 收束成独立命令（Bug 404：不能靠 && 或行首 ;）');
    });

    test('update 与 install 是两条独立命令（各自独立字符串）', () {
      final updIdx = lineOf('apt-get update');
      final instIdx = lineOf('apt-get install');
      expect(updIdx, greaterThan(0));
      expect(instIdx, greaterThan(updIdx),
          reason: 'update 与 install 必须分属两行、各自独立成命令');
    });

    test('安装成功判定用显式哨兵，而非只看退出码', () {
      expect(gitBody.contains('GIT_INSTALLED'), isTrue,
          reason: 'proot exec 的退出码不可靠（中继进程语义），必须用哨兵字符串');
      expect(gitBody.contains(r"command -v git >/dev/null 2>&1 && echo"), isTrue);
    });

    test('失败文案要把真因（dpkg）和自救手段一起给出', () {
      final failIdx = gitBody.indexOf("'自动安装 git 失败：");
      expect(failIdx, greaterThan(0));
      final msg = gitBody.substring(failIdx, failIdx + 400);
      expect(msg.contains('dpkg --configure -a'), isTrue,
          reason: '用户看到 git 失败时，必须能顺着提示找到真因与手动补救方式');
    });
  });

  group('Bug 435 · 覆盖性：所有 apt 调用路径都经自愈', () {
    test('各 apt 入口（qemu / sdk / native / 内置工具）都先过 AptTools.ensure', () {
      // AptTools.ensure 内含 repairDpkg，是统一的 apt 前置守卫
      final files = [
        'lib/toolchain/qemu_compat.dart',
        'lib/toolchain/sdk_installer.dart',
        'lib/toolchain/native_arm64.dart',
      ];
      for (final f in files) {
        final src = File(f).readAsStringSync();
        expect(src.contains('AptTools.ensure'), isTrue,
            reason: '$f 调用 apt 前必须先过统一守卫');
      }
    });

    test('git() 是唯一绕过 AptTools.ensure 的 apt 路径，已单独补自愈', () {
      // 这条测试的意义是"记录住这个例外"：将来若新增 apt 路径，
      // 要么走 AptTools.ensure，要么像 git() 一样自己带 repairDpkg。
      expect(toolchain.contains('AptTools.repairDpkg'), isTrue);
    });
  });
}
