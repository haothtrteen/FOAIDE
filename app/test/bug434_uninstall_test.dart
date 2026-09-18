import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Bug 434：x64 兼容层卸载失败 `PURGE_FAILED rc=100`
///
/// 真机报错原文：
/// ```
/// x64 兼容层卸载失败：PURGE_FAILED rc=100
/// E: Essential packages were removed and -y was used
///    without --allow-remove-essential.
/// ```
///
/// 根因：一条命令里同时 `purge qemu-user-static` **和**
/// `libc6:amd64` 等运行库时，apt 把这些运行库当成「随 qemu 装进来的
/// 无主依赖」级联删除；而宿主是 arm64 + amd64 外来架构，删
/// `libc6:amd64` 被判定为移除 essential 包，`-y` 下直接拒绝 →
/// rc=100。**更糟的是 apt 中途失败不回滚**，已删的部分保持已删，
/// 于是表现为「报了个错，但状态半半拉拉」。
///
/// 修复：分两步——① 只 purge qemu 本体；② 运行库逐个删，单个失败
/// 只记录不中断；③ 最后清外来架构。判定标准从「所有包都没了」改成
/// 「qemu 本体没了 + 转发层已还原」（后者由脚本前段完成）。
///
/// 本测试直接读源码文本做结构断言——卸载脚本是跑在 proot 容器里的
/// shell，无法在 Dart 单测里真实执行，所以固化「命令形态」这一层
/// 契约（与 Bug 428/429/433 的测试策略一致）。
void main() {
  late String src;
  late String script;

  setUpAll(() {
    src = File('lib/toolchain/qemu_compat.dart').readAsStringSync();
    final m = RegExp(
      r"static const String _uninstallScript = r'''(.*?)''';",
      dotAll: true,
    ).firstMatch(src);
    expect(m, isNotNull, reason: '找不到 _uninstallScript 定义');
    script = m!.group(1)!;
  });

  group('Bug 434 · 卸载不再触发 essential 拒绝', () {
    test('purge 命令只带 qemu 本体，不与运行库混在同一条命令', () {
      final purgeLines = script
          .split('\n')
          .where((l) => l.contains('apt-get purge'))
          .toList();
      expect(purgeLines, isNotEmpty, reason: '必须有 purge 调用');

      // 第一条 purge（qemu 本体）后面不能跟着 :amd64 运行库
      final first = purgeLines.first;
      expect(first, contains('qemu-user-static'));
      expect(
        RegExp(r'libc6:amd64|libstdc\+\+6:amd64|zlib1g:amd64').hasMatch(first),
        isFalse,
        reason: 'Bug 434 回归：qemu 与运行库混删会让 apt 判定移除 essential '
            '包 → rc=100，且中途失败不回滚',
      );
    });

    test('运行库逐个删，而不是一条命令批量删', () {
      // 循环形态
      expect(
        script.contains('for p in libatomic1:amd64 zlib1g:amd64 '
            'libgcc-s1:amd64 libstdc++6:amd64 libc6:amd64; do'),
        isTrue,
        reason: '运行库必须逐个处理，才能在单个失败时继续处理其余',
      );
      // 循环体内确实是 purge 单个包
      expect(RegExp(r'apt-get purge[^\n]*"\$p"').hasMatch(script), isTrue,
          reason: r'循环体必须 purge "$p"');
    });

    test('删之前先确认包处于已安装态（跳过未安装，避免无谓失败）', () {
      expect(
        script.contains(r'''dpkg -l "$p" 2>/dev/null | grep -q '^ii' ||'''),
        isTrue,
        reason: '对未安装的包执行 purge 会返回非零，必须先探测',
      );
    });

    test('单个运行库删失败只记录，不中断整个卸载', () {
      expect(script.contains(r'libs_fail="$libs_fail $p"'), isTrue,
          reason: '失败包收集进 libs_fail');
      // 循环体必须是 if ! ... ; then 记录 fi —— 不能是裸命令 + set -e
      expect(RegExp(r'if ! DEBIAN_FRONTEND=noninteractive apt-get purge')
          .hasMatch(script), isTrue);
      // 且不得对运行库使用 exit
      final libLoop = script.substring(
          script.indexOf('for p in libatomic1:amd64'));
      final loopBody = libLoop.substring(0, libLoop.indexOf('done'));
      expect(loopBody.contains('exit'), isFalse,
          reason: '运行库删除失败绝不能 exit——那不是致命错误');
    });

    test('部分失败上报为 PURGE_LIBS_PARTIAL，而非 PURGE_FAILED', () {
      expect(script.contains('PURGE_LIBS_PARTIAL'), isTrue);
      // PURGE_FAILED 只属于 qemu 本体失败那条路径
      expect(script.contains('PURGE_FAILED'), isTrue);
      expect(script.contains('exit 2'), isTrue,
          reason: 'qemu 本体删失败才是致命错误');
      // 确认 exit 2 只出现在 qemu purge 之后、运行库循环之前
      final failPos = script.indexOf('PURGE_FAILED');
      final loopPos = script.indexOf('for p in libatomic1:amd64');
      final exitPos = script.indexOf('exit 2');
      expect(failPos < exitPos && exitPos < loopPos, isTrue,
          reason: 'exit 2 必须只属于 qemu 本体失败路径');
    });

    test('qemu 二进制仍在则报 QEMU_STILL_PRESENT（卸载真实生效的判据）', () {
      expect(script.contains(r'[ -x @QEMU@ ] && { echo QEMU_STILL_PRESENT'),
          isTrue);
    });

    test('最后清理 amd64 外来架构注册', () {
      expect(script.contains('dpkg --remove-architecture amd64'), isTrue);
      // 必须在 qemu 删除之后
      expect(
        script.indexOf('dpkg --remove-architecture') >
            script.indexOf('apt-get purge'),
        isTrue,
      );
    });

    test('成功标志 UNINSTALL_OK 仍在最后', () {
      final okPos = script.indexOf('UNINSTALL_OK');
      expect(okPos, greaterThan(0));
      expect(okPos > script.indexOf('QEMU_STILL_PRESENT'), isTrue);
    });
  });

  group('Bug 434 · Dart 侧判定与提示', () {
    test('PURGE_LIBS_PARTIAL 不应导致抛异常（卸不干净≠卸载失败）', () {
      final uninstallIdx = src.indexOf('static Future<void> uninstall(');
      expect(uninstallIdx, greaterThan(0));
      final body = src.substring(uninstallIdx, uninstallIdx + 1400);

      // 抛异常的三个条件里不得包含 PURGE_LIBS_PARTIAL
      final throwBlock = body.substring(
        body.indexOf('if (!r.ok'),
        body.indexOf('throw DownloadException'),
      );
      expect(throwBlock.contains('PURGE_LIBS_PARTIAL'), isFalse,
          reason: '运行库残留不该报"卸载失败"，否则用户以为没生效');
      expect(throwBlock.contains('PURGE_FAILED'), isTrue);
      expect(throwBlock.contains('QEMU_STILL_PRESENT'), isTrue);
    });

    test('部分残留走提示路径（写 stderr，不弹错误）', () {
      final uninstallIdx = src.indexOf('static Future<void> uninstall(');
      final body = src.substring(uninstallIdx, uninstallIdx + 1800);
      expect(body.contains('PURGE_LIBS_PARTIAL:'), isTrue,
          reason: '要解析出具体保留了哪些库用于提示');
      expect(body.contains('stderr.writeln'), isTrue);
    });
  });
}
