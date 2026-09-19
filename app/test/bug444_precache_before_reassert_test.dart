import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_on_android/toolchain/build_runner.dart';
import 'package:flutter_on_android/toolchain/qemu_compat.dart';

/// Bug 444：把 flutter build 内部的构件下载**提前**到 reassert 之前。
///
/// 这条链路的事实已经由两处独立证据坐实，测试必须把它们钉住：
///
/// 1. **flutter_tools 源码**（artifacts.dart `_getAndroidArtifactPath`）：
///    AOT 用的 gen_snapshot 路径 = `join(engineDir, hostPlatformName,
///    'gen_snapshot')`，其中 engineDir = `android-arm64-release`、
///    hostPlatformName 由 `uname -m` 决定。**真机 Android 是 arm64 →
///    hostPlatformName = `linux-arm64`**。
/// 2. **沙箱目录结构**（本机实测）：
///    `android-arm64-release/linux-x64/gen_snapshot` = 6,154,880 B 真
///    x86_64 ELF（`7f454c46...3e00`）；
///    `android-arm64-release/linux-arm64/gen_snapshot` = 330 B 转发脚本。
///
/// 合起来：官方**没有** arm64 版的 android gen_snapshot
/// （artifacts.dart 里那个 TODO：flutter/flutter#152281），
/// `linux-arm64/` 目录下放的就是 x86_64 二进制 —— 只能靠转发脚本跑。
/// 一旦 build 内部补下载，就会把它覆写成裸 x64 ELF → AOT SIGILL。
///
/// 本测试与 Bug 439/441/442 的测试是同一路数：**断言真实产物/真实顺序**，
/// 不做"注释里有就算"的宽断言（Bug 442/443 都栽在过宽的 contains 上）。
/// 剥掉 shell 注释行。
///
/// ⚠️ **这是第三次栽在同一个坑上**（Bug 442 → 443 → 444）：
/// cmd 里塞了 diag / heal / reassert 三份 shell 脚本，它们的**注释**里
/// 写满了 `pub get`、`REASSERT_DART=0` 之类的字样。用裸 `contains` /
/// `indexOf` 断言"有没有执行某命令"会直接命中注释，得到假阴性/假阳性。
/// 断言的意图是"不得**执行**"，那就只看可执行行。
String stripComments(String s) =>
    s.split('\n').where((l) => !l.trimLeft().startsWith('#')).join('\n');

void main() {
  final raw = BuildRunner.buildCommand(
    proj: '/tmp/proj',
    flutterCmd: 'flutter',
    envPart: '',
    aapt2Override: '',
  );
  final cmd = stripComments(raw);

  /// 命令里出现的位置锚点（基于**去注释后**的文本）。
  ///
  /// 注意：`REASSERT=` 这个字样来自被 `sh -c '...'` 包裹的 reassert
  /// 脚本**内容**，所以可以直接拿来定位 reassert 段的位置。
  final iPrecache = cmd.indexOf('precache');
  final iReassert1 = cmd.indexOf('REASSERT=');
  final iBuild1 = cmd.indexOf('flutter build apk');
  final iBuild2 = cmd.lastIndexOf('flutter build apk');
  final iReassert2 = cmd.lastIndexOf('REASSERT=');

  group('Bug 444 · 下载必须提前到 reassert 之前', () {
    test('构建命令里必须包含 precache', () {
      // 红-绿验证：这条断言在当前修复之前是**失败**的（旧命令没有
      // precache 这一行），说明它真的在测新行为而不是走过场。
      expect(iPrecache, greaterThanOrEqualTo(0),
          reason: 'precache 缺失：build 内部的补下载会盖掉转发层');
    });

    test('precache 必须精确只取 android_gen_snapshot（不连带无关大包）', () {
      expect(cmd, contains('precache --android_gen_snapshot'),
          reason: '应当是 --android_gen_snapshot，'
              'universal（impellerc/font-subset）默认 true 会一并带上');
      // 不带 --force：强制重下会让每次构建都付一遍下载代价
      expect(cmd, isNot(contains('precache --force')));
      expect(cmd, isNot(contains('precache -f')));
    });

    test('顺序必须是 precache → reassert → build', () {
      expect(iPrecache, greaterThanOrEqualTo(0));
      expect(iReassert1, greaterThan(iPrecache),
          reason: 'precache 必须在 reassert 之前：先让它下载覆盖，'
              '再由 reassert 重建转发层');
      expect(iBuild1, greaterThan(iReassert1),
          reason: 'reassert 必须在 build 之前');
    });

    test('precache 必须容错（失败不得中断构建）', () {
      // 这里 `| tail -n 5` 吞掉退出码是**有意为之**：precache 只是把
      // 下载提前，失败（网络/镜像抖动）不该让整条构建命令挂掉，
      // 后面还有指纹确证后的兜底重试。
      //
      // ⚠️ 与 Bug 443 的区别：那次是**无意**中被管道吞掉退出码
      // （`o=$( cmd | head -5 ); r=$?`），把失败判成成功；
      // 这里是主动容错，**且后面没有跟着取退出码**。
      final i = iPrecache;
      final seg = cmd.substring(i, i + 80);
      expect(seg, contains('| tail -n'),
          reason: 'precache 的输出要截断（可能很长），顺带吞掉退出码做容错');
    });

    test('precache 的容错不得伪装成 Bug 443 的同类死代码', () {
      // Bug 443 的反证正则是「$( ... | head ... ) 紧跟一行取退出码」。
      // precache 这行后面**不能**出现取退出码的语句，否则就又造了一个
      // "退出码恒为 0" 的死分支。
      expect(
        RegExp(r'precache[^\n]*\|[^\n]*tail[^\n]*\n\s*\w+=\$\?').hasMatch(cmd),
        isFalse,
        reason: 'precache 后面不许紧跟取退出码 —— 那拿到的会是 tail 的退出码',
      );
    });
  });

  group('Bug 444 · 失败后指纹确证才自愈重试', () {
    test('构建失败时必须二次快照 AOT 指纹', () {
      expect(cmd, contains('brc=\$?'),
          reason: '必须先接住 build 的退出码');
      expect(cmd, contains(r'fp=$(sh -c '),
          reason: '必须把构建后的 AOT_FP 抓进变量，供后面判断与打印');
      // Bug 445：这里**必须真的重新执行一次诊断**。
      // alpha.50 的教训：原本写成复用上面那次 diag 的输出，结果真机日志里
      // 出现两对 `AOT_FP=xxx=wrapper` + `AOT_FP=xxx=RAW_ELF`——
      // 那不是"两个时刻"的值，而是**同一次执行被印了两遍**
      // （第一次走 tail -n 30 被截断、这里是完整输出），
      // 导致我根本没拿到"构建后"的真实状态。
      expect(cmd, contains('grep "AOT_FP="'),
          reason: '二次快照只看 AOT_FP，别把整份诊断刷屏');
      expect(cmd, contains(r'echo "$fp";'),
          reason: 'Bug 445：重新采集的指纹必须完整打印，'
              '否则无法与构建前的 AOT_FP 对比');
    });

    test('重试的判据必须是「指纹出现 BAD」，不能无条件重试', () {
      // ⚠️ Bug 445 纠正了一个**我自己写错的判据**：
      //   原判据是 `grep -q "RAW_ELF"`，理由是"转发层被覆盖成裸 x64"。
      //   但 AOT_FP 循环里同时列了**真身**（`linux-x64/`），
      //   而真身**本来就该是** RAW_ELF —— 这个判据**恒为真**，
      //   于是每次失败都白跑一轮"清缓存 + 重建 + 重启构建"。
      //   现在诊断给每行标了角色（SLOT/REAL）与是否合格（ok/BAD），
      //   判据只看 BAD。
      expect(cmd, contains(r'grep -q "BAD("'),
          reason: '只在转发位真的异常时才重试；'
              '否则用户要多等一整轮却毫无收益');
      // 回归哨兵：不许退回用 RAW_ELF 当判据
      expect(RegExp(r'grep -q "RAW_ELF"').hasMatch(cmd), isFalse,
          reason: 'Bug 445：RAW_ELF 在 linux-x64/ 真身上是正常状态，'
              '拿它当"被覆盖"的判据会恒为真');
    });

    test('重试前必须重新 reassert，且 reassert 在第二次 build 之前', () {
      expect(iBuild2, greaterThan(iBuild1), reason: '确实存在第二次 build');
      expect(iReassert2, greaterThan(iBuild1),
          reason: '第二次的 reassert 必须发生在第一次 build 之后');
      expect(iReassert2, lessThan(iBuild2),
          reason: '重建转发层必须在第二次 build 之前');
    });

    test('最多只重试一次（不得死循环）', () {
      final n = 'flutter build apk'.allMatches(cmd).length;
      expect(n, 2, reason: '应当只有 1 次正常 + 1 次重试，实际出现 $n 次');
    });

    test('重试段不得再跑 pub get（Bug 433：pub get 会盖掉转发层）', () {
      // ⚠️ 必须基于**去注释**的文本：diag/heal 脚本的注释里就写着
      // "被 pub get 覆盖后会变回后者"、"pub get 调 dart = arm64 上直接
      // 执行 x64 ELF"——裸 contains 会命中注释，断言直接失效。
      final afterFirstBuild = cmd.substring(iBuild1);
      expect(afterFirstBuild.contains('pub get'), isFalse,
          reason: '重试时再跑 pub get 会把刚重建的转发层又盖掉，'
              '等于白重试');
    });

    test('回归哨兵：去注释后仍要能找到全部锚点（防断言自己失效）', () {
      // 如果哪天 cmd 的结构变了、锚点找不到（indexOf 返回 -1），
      // 上面的位置断言会退化成 `greaterThan(-1)` 恒真而悄悄失效。
      // 这条把"锚点必须存在"显式钉住。
      expect(iPrecache, greaterThan(0), reason: 'precache 锚点丢失');
      expect(iReassert1, greaterThan(0), reason: '第一次 reassert 锚点丢失');
      expect(iBuild1, greaterThan(0), reason: '第一次 build 锚点丢失');
      expect(iBuild2, greaterThan(iBuild1), reason: '第二次 build 锚点丢失');
      expect(iReassert2, greaterThan(iBuild1), reason: '重试 reassert 锚点丢失');
    });

    test('重试之后必须更新退出码再 exit', () {
      // 第二次 build 之后必须重新 `brc=$?`，否则 exit 的是第一次的失败码，
      // 重试成功也会被判失败。
      final afterRetry = cmd.substring(iBuild2);
      expect(afterRetry, contains('brc=\$?'),
          reason: '第二次 build 后必须重新捕获退出码');
      expect(cmd.trimRight(), endsWith('exit \$brc'));
    });
  });

  group('Bug 444 · AOT 指纹必须覆盖真机真正执行的路径', () {
    final fp = QemuCompat.fill(QemuCompat.buildPreflightScript);

    test('必须含 android-arm64-release/linux-arm64/gen_snapshot（真机实际路径）',
        () {
      // 这是本轮最关键的发现：`uname -m` 在真机上返回 aarch64，
      // 所以 AOT 走的是 linux-arm64 而不是 linux-x64。
      // 只测 linux-x64 会漏掉真正被执行的那一个。
      expect(fp, contains('android-arm64-release/linux-arm64/gen_snapshot'),
          reason: '真机 host=linux_arm64，AOT 执行的就是这个路径');
    });

    test('必须含 android-arm64-release/linux-x64/gen_snapshot（真身路径）', () {
      expect(fp, contains('android-arm64-release/linux-x64/gen_snapshot'),
          reason: '真身（6MB x86_64 ELF）在这里，转发脚本指向它');
    });

    test('必须含顶层 linux-arm64/impellerc（shader 阶段实际路径）', () {
      expect(fp, contains('linux-arm64/impellerc'),
          reason: 'impellerc 是 host artifact，同样落在 linux-arm64/');
    });

    test('AOT_FP 判据用文件头而不是文件存在', () {
      // 转发脚本 = `#!`(2321)，裸 x64 二进制 = 7f454c46。
      // 「文件存在」在两种状态下都为真，区分不了。
      expect(fp, contains('2321*'), reason: 'wrapper 判据');
      expect(fp, contains('7f454c46'), reason: 'RAW_ELF 判据');
    });
  });
}
