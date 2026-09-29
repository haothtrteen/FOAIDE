// Bug 471 回归测试：proroot 的 glibc 版本门禁。
//
// ## 这个 Bug 的教训
//
// 真机上 5 个 .so 全部就位、sha256 全部相符，冒烟测试却失败：
//
//   proroot-ldso: no offset table for glibc 2.36 - patches skipped
//   reloc: unresolved __isoc23_strtoul in .../libproroot-runtime.so
//   proroot-ldso: failure rc=2
//
// 根因是**版本错配**：上游 runtime 要 glibc 2.38（用 __isoc23_*），
// 我们 rootfs 是 2.36。逐文件哈希校验**永远拦不住这个**——
// 哈希只证明"字节没被改"，不证明"这些字节合在一起能跑"。
//
// 所以本测试守三件事：
//   ① 版本比对逻辑本身正确（含边界）；
//   ② 预检发生在**下载之前**（别让用户白花流量）；
//   ③ 失败文案给版本号、且**不含**历史上那句误导的"缺少 ld-linux"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/proroot_option.dart';
import 'package:foaide/ui/about_info.dart';

void main() {
  group('Bug 471 · glibc 版本比对', () {
    test('rootfs 2.36 vs 要求 2.38 → 不兼容（v1.2.8 的情况）', () {
      expect(
        ProrootOption.isGlibcCompatible(required: '2.38', provided: '2.36'),
        isFalse,
      );
    });

    test('rootfs 2.36 vs 要求 2.34 → 兼容（v1.2.5 的情况）', () {
      expect(
        ProrootOption.isGlibcCompatible(required: '2.34', provided: '2.36'),
        isTrue,
      );
    });

    test('版本相等 → 兼容', () {
      expect(
        ProrootOption.isGlibcCompatible(required: '2.38', provided: '2.38'),
        isTrue,
      );
    });

    test('rootfs 高于要求 → 兼容（向后兼容）', () {
      expect(
        ProrootOption.isGlibcCompatible(required: '2.36', provided: '2.39'),
        isTrue,
      );
    });

    test('主版本号不同要正确比较（2.99 < 3.0）', () {
      // 数值化公式是 major*1000+minor，所以 2.99=2099 < 3.0=3000。
      // 若误用字符串比较会得出相反结论（'2.99' > '3.0'）。
      expect(
        ProrootOption.isGlibcCompatible(required: '3.0', provided: '2.99'),
        isFalse,
      );
      expect(
        ProrootOption.isGlibcCompatible(required: '2.99', provided: '3.0'),
        isTrue,
      );
    });

    test('钉的版本与 rootfs：符号够，但实测跑不起来（Bug 471 修正）', () {
      // 这条是"把现实钉住"：常量变了这里会红，提醒同步核对。
      //
      // ⚠️ **本用例被推翻过三次**，每次都是被更深一层的事实推翻的。
      //
      // 第 ① 次：旧断言 `usableOnCurrentRootfs == true`，理由"版本够"。
      //   真机冒烟（alpha.65）证否：
      //     proroot-ldso: no offset table for glibc 2.36 — patches skipped
      //     [proroot] SIGSEGV ... child exited with code 139
      //
      // 第 ② 次：我把根因归到"linker 没有 2.36 的偏移表"，并给出
      //   "换 rootfs 到 Debian 13"这条出路。**又被证否** ——
      //   换 glibc 2.41 实测报错逐字相同。
      //
      // 第 ③ 次：改成"根因是 DT_NEEDED 写了开发名 `libc.so`/`libdl.so`"。
      //   **仍然错** —— 那是 **bionic 语境下的正常依赖名**，
      //   我这个"开发名"判断是拿 glibc 规则审 Android 二进制得来的。
      //
      // 第 ④ 次（当前，对照作者开源 App andClaw 后定案）：
      //   `libproroot.so` 的 `PT_INTERP` = **`/system/bin/linker64`** ——
      //   它是 Android 原生 launcher，必须从 `nativeLibraryDir` 直接 exec。
      //   **我们之前用 `ld-linux-aarch64.so.1` 加载它，加载器本身就错了**，
      //   所以那些报错全是自己造出来的。
      //
      // 断言仍分两半：把"纸面"和"实测"分开。
      expect(ProrootOption.pinnedVersion, 'v1.2.5');
      expect(ProrootOption.requiredGlibc, '2.34');
      expect(ProrootOption.rootfsGlibc, '2.36');

      // ① 纸面：符号依赖算得过来（这个事实没变，仍是 true）
      expect(ProrootOption.isGlibcCompatible(), isTrue,
          reason: '符号层面确实满足 —— 但见下一条，这不代表能用');

      // ② 实测：真机上跑不起来（这才是门禁真正依据的事实）
      expect(ProrootOption.isKnownUnusable(), isTrue,
          reason: 'alpha.65 真机冒烟失败 + 2026-09-21 判别实验，'
              '这是实测事实，优先级高于任何符号表推断');
    });

    test('⚠️ 「符号够」与「能跑」必须分开表达，不许再合成一个布尔', () {
      // 本 Bug 最贵的教训：我原来只有一个 `usableOnCurrentRootfs`，
      // 它把"readelf 说依赖齐了"直接等同于"能跑"。
      // 两者一旦合成，符号表的盲区就变成了对用户的虚假承诺。
      //
      // ⚠️ 注意这里**不能**断言 `isGlibcCompatible() != isKnownUnusable()`
      // —— 两个方法名都是**肯定式命名**，当前恰好都返回 true
      // （"符号算得过来" = true，"已知不可用" = true，两件不相干的事）。
      // 我第一版就是这么写的，结果断言的是 `isNot(true)`，直接假红。
      //
      // 正确的钉法是：断言**两个独立事实各自的取值**，
      // 这样任何一个被合并/删除/改名，这条都会红。
      expect(ProrootOption.isGlibcCompatible(), isTrue,
          reason: '事实一：符号依赖满足');
      expect(ProrootOption.isKnownUnusable(), isTrue,
          reason: '事实二：真机实测不可用');

      // 两条同时为 true，恰恰说明**不能用同一个布尔表达** ——
      // "可行"与"不行"必须能同时成立、分别取用。
      final compatible = ProrootOption.isGlibcCompatible();
      final knownBad = ProrootOption.isKnownUnusable();
      expect(compatible && knownBad, isTrue,
          reason: '这就是那个反直觉的组合：纸面可行 ∩ 实测不行。'
              '任何"只留一个判据"的重构都会丢掉其中一半信息');

      // 门禁必须以 knownBad 为准（保守优先）
      expect(ProrootOption.isKnownUnusable(), isTrue,
          reason: '下载门禁读的是这个，不是 isGlibcCompatible');
    });

    test('上游 ref 必须是钉死的 tag，不能是 main（Bug 471）', () {
      // 走 main 等于"上游推什么我们拿什么"——正是这个导致了本 Bug。
      expect(ProrootOption.upstreamRef, ProrootOption.pinnedVersion);
      expect(ProrootOption.upstreamRef, isNot('main'));
    });

    test('v1.2.8 要求的 2.38 会被判为不兼容（防上游再回退）', () {
      expect(
        ProrootOption.isGlibcCompatible(required: '2.38', provided: '2.36'),
        isFalse,
        reason: '这正是 v1.2.8 的情况，必须能拦住',
      );
    });

    test('畸形版本串不崩（解析失败退回 0，判为不兼容而非抛异常）', () {
      expect(ProrootOption.isGlibcCompatible(required: '2.38', provided: 'x'), isFalse);
      expect(ProrootOption.isGlibcCompatible(required: '2.38', provided: ''), isFalse);
    });
  });

  group('Bug 471 · 失败文案', () {
    test('同时给出双方版本号（用钉死版本的常量，不是写死数字）', () {
      // 写死 '2.38' 是错的：换版本（v1.2.8 → v1.2.5）后这条会假红，
      // 让人以为"文案坏了"。文案要含的是**当前钉的版本需要什么**，
      // 所以断言也得跟着常量走。
      final m = ProrootOption.glibcMismatchMessage();
      expect(m, contains(ProrootOption.requiredGlibc));
      expect(m, contains(ProrootOption.rootfsGlibc));
      // 且必须是**能对上的那一对**：本机 rootfs 版本要真的出现在里面。
      expect(m, contains('2.36'));
    });

    test('点名真实现场：加载方式不对，而非上游二进制有缺陷', () {
      // ⚠️ 判据口径被修正过**三次**，这里是最终版，改前务必读完。
      //
      // 第 ① 版（证伪）："判据必须是 `reloc: unresolved`，不是 `no offset table`"。
      // 第 ② 版（证伪）："`no offset table` 本身就是死因"。
      // 第 ③ 版（也被推翻）："根因是 DT_NEEDED 写了开发名 `libc.so`/`libdl.so`"。
      //
      // 第 ④ 版（当前，对照作者开源 App andClaw 后）：
      //   `libproroot.so` 的 `PT_INTERP` 是 **`/system/bin/linker64`**
      //   —— 它是 **Android 原生 launcher**，必须从 `nativeLibraryDir`
      //   **直接 exec**。我们之前用 `ld-linux-aarch64.so.1` 去加载它，
      //   **加载器本身就错了**，所以看到的报错全是自己造出来的。
      //   `libc.so` / `libdl.so` 在 bionic 语境下是**正常的依赖名**。
      //
      // 文案必须以"我们的集成方式不对"为主，而不是"上游有缺陷"。
      final m = ProrootOption.knownUnusableMessage();
      expect(m, contains('/system/bin/linker64'),
          reason: '这是判定的关键证据：interp 指向 Android bionic 链接器');
      expect(m, contains('nativeLibraryDir'),
          reason: '要给出正确做法：从 nativeLibraryDir 直接 exec');
      expect(m, contains('直接 exec'),
          reason: '要点明动作，否则用户不知道"该怎么做"');
      // 口径第 ⑥ 版（alpha.69）：**二进制已不再内置**，所以文案里
      // 不能再出现"① ✅ 五个 .so 打包进 jniLibs"——那是假承诺。
      // 但原生侧的改造清单要保留（用户自行导入后仍依赖它们），
      // 所以仍断言 `PROROOT_*` 这族前缀在文案里。
      expect(m, contains('PROROOT_'),
          reason: '要列出环境变量这一项，这是可执行的改造清单');
      expect(m, contains('不再内置'),
          reason: '必须说清二进制已不随 APK 分发，否则用户会以为本 App 自带');
      expect(m, isNot(contains('✅')),
          reason: '不许再有"已打包/已完成"式的勾选承诺（二进制已移除）');
      expect(m, contains('andClaw'),
          reason: '要给出参考实现来源，可复核');
      // 不许再写"我方无解"这类错误论断
      expect(m, isNot(contains('我方无解')),
          reason: '那是我上一轮的误判，有解');
      expect(m, isNot(contains('上游需重新构建')),
          reason: '二进制没问题，不用等上游');
    });

    test('⚠️ 必须说清"rootfs 不是当前卡点"', () {
      // 这是最容易误导用户的一点：看到"官方支持 Ubuntu"，用户会以为
      // "我换个 Ubuntu rootfs 就能用了"。但真正的卡点是**集成方式**，
      // 光换 rootfs 而不做 5 项改造，依然跑不起来。
      final m = ProrootOption.knownUnusableMessage();
      expect(m, contains('尚未'), reason: '要说清是"我们没接通"，不是"没法通"');

      final n = ProrootOption.compatNote(rootfsDistro: 'Debian 12 bookworm');
      expect(n, contains('rootfs 不是当前的卡点'),
          reason: '必须显式纠正"换个 rootfs 就好"的误解');
      expect(n, contains('libproroot.so'),
          reason: '要给出真正的卡点是什么');
    });

    test('必须说清"文件是好的"，避免用户去重装/重下', () {
      final m = ProrootOption.glibcMismatchMessage();
      expect(m, contains('哈希'));
      expect(m.toLowerCase(), contains('不是'), reason: '要明确否定"文件缺失"的猜测');
    });

    test('可以说 ld-linux，但只能出现在"用错了"的语境里', () {
      // ⚠️ 本条 2026-09-21 修正，语义**变了**。
      //
      // 旧版断言"任何文案都不许出现 ld-linux-aarch64.so.1"，理由是
      // 旧文案把它说成"缺少 /lib64/ld-linux-aarch64.so.1"——那是错的，
      // 因为我们的 ld-linux 好端端在 /usr/lib/aarch64-linux-gnu/ 下。
      //
      // 现在反过来了：**必须**点名它。因为加载方式不对这件事，
      // 只有说清"不该用 glibc 的 ld-linux 去加载一个 Android launcher"
      // 才讲得明白。禁令照旧只针对"缺少"这个说法 ——
      // 说"缺了它"是误导（它没缺），说"不该用它"是正确的。
      final all = [
        ProrootOption.glibcMismatchMessage(),
        ProrootOption.compatNote(rootfsDistro: ProrootOption.foaRootfsDistro),
      ].join('\n');
      expect(all, isNot(contains('缺少 /lib64/ld-linux')),
          reason: '"缺少 ld-linux"仍然是错的——它没缺');
      expect(all, isNot(contains('缺少 ld-linux')),
          reason: '同上，换一种写法也不许');
      // 若要提 ld-linux，必须带否定/纠错语境
      if (all.contains('ld-linux-aarch64.so.1')) {
        expect(
            all.contains('而不是用') ||
                all.contains('不该用') ||
                all.contains('不应') ||
                all.contains('不是用'),
            isTrue,
            reason: '点名 ld-linux 时必须是在说"不该用它加载"');
      }
    });

    test('⚠️ 必须说清"真死因是加载方式，不是 glibc 版本"', () {
      // 这条是 2026-09-21 定案后的核心断言：不能让任何一条文案
      // 继续把用户往"glibc 版本/rootfs"这条已经被证否的路上引。
      final m = ProrootOption.glibcMismatchMessage();
      expect(m.contains('PT_INTERP') || m.contains('linker64'), isTrue,
          reason: '要给判据，不能只下结论');
      expect(m.contains('不是') && m.contains('glibc'), isTrue,
          reason: '要显式否认"glibc 版本"这个旧归因');
      expect(m, isNot(contains('DT_NEEDED')),
          reason: '"上游 DT_NEEDED 写错"是已被推翻的结论，不许留在文案里');
      expect(m, isNot(contains('开发名')),
          reason: '同上，这是拿 glibc 规则误审 Android 二进制的产物');
    });

    test('给出可行出路：指向一键下载（钉版本），且不再把换 rootfs 当出路', () {
      // ⚠️ 本条 2026-09-21 修正。原标题是
      //    "优先指向一键下载（钉版本），**才提换 rootfs**" ——
      //    那个"才提"的备选已被判别实验证否，必须彻底移除。
      //
      // ⚠️ 2026-09-21 二次修正：`glibcMismatchMessage` 那条路线
      //    （v1.2.8 要 2.38）**本身还成立**，所以这条测试的对象没变。
      //    但要注意它与 `knownUnusableMessage` 现在是**两件不同的事**：
      //      · `glibcMismatchMessage`：符号依赖算不过来（v1.2.8 那条路）
      //      · `knownUnusableMessage`：集成方式没接通（当前真实卡点）
      final m = ProrootOption.glibcMismatchMessage();
      expect(m, contains(ProrootOption.pinnedVersion),
          reason: '要告诉用户用钉死的版本');
      expect(m, contains('一键下载'), reason: '首选出路是 App 内自带的下拉');
      expect(m, contains(ProrootOption.foaRootfsDistro),
          reason: '要说明本机是什么 rootfs');

      // 提到 rootfs 是**为了劝阻**，不是为了建议 —— 必须带否定语境。
      expect(m, contains('不要试图靠升级 rootfs 解决'),
          reason: '提 rootfs 只能是劝阻，不能是推荐');
    });
  });

  group('Bug 471 · 兼容性提示（卡片文案）', () {
    test('本项目的 Debian 12：必须直说"硬条件满足 + 尚未接通"', () {
      // ⚠️ 这条被推翻过**四次**：
      //    第 ① 版断言 `contains('够')`（"版本够"）—— 实测是崩的。
      //    第 ② 版断言 `contains('SIGSEGV')` —— 只是下游症状。
      //    第 ③ 版断言 `contains('libc.so')`（DT_NEEDED 开发名）—— 解读错了。
      //    第 ④ 版断言 `contains('未支持')` —— 措辞**过重**，把作者的产品
      //      配置（自带 Ubuntu rootfs）当成了技术前提。
      //    第 ⑤ 版（当前）：不在官方验证环境内、但硬条件满足；真实卡点是集成方式。
      final n = ProrootOption.compatNote(rootfsDistro: 'Debian 12 bookworm');
      expect(n, contains('硬条件满足'),
          reason: '官方 Requirements 的硬条件是 glibc（非 musl），本项目满足');
      expect(n, isNot(contains('未支持')),
          reason: '"未支持组合"过重 —— 不能把产品配置当成技术门槛');
      expect(n, contains('libproroot.so'),
          reason: '要给出真正的卡点：libproroot.so 的加载方式');
      expect(n, contains('nativeLibraryDir'),
          reason: '要给出正确做法，否则用户不知道该往哪走');
      expect(n, contains('跑通就不必换'),
          reason: '要给出正确顺序：先做集成改造，用现有 rootfs 实测决定');
      // 不许再出现鼓励性措辞
      expect(n, isNot(contains('版本上是够的')),
          reason: '这句话曾让用户以为"试试看"，实测是必崩');
      expect(n, isNot(contains('建议先跑一次冒烟测试')),
          reason: '已经跑过了、已经知道结果，不该再让用户去试');
    });

    test('Ubuntu rootfs 视为与官方验证环境一致', () {
      final n = ProrootOption.compatNote(rootfsDistro: 'Ubuntu 24.04 arm64');
      expect(n, contains('一致'));
      expect(n, isNot(contains('不兼容')));
    });

    test('空发行版名有兜底，不崩', () {
      expect(ProrootOption.compatNote(rootfsDistro: '  '), isNotEmpty);
    });

    test('风险清单第一条必须是"尚未接通"，而不是"版本钉得对"', () {
      // ⚠️ 本条修正过三次。
      //    2026-09-20：原标题是"讲清为什么不是最新版（防用户手动下新版）"，
      //      那个框架暗示"我们钉的这版能用、只是不最新"，事实是钉的也崩。
      //    2026-09-21（一次）：内容改成指向 DT_NEEDED 开发名 —— 解读错了。
      //    2026-09-21（当前）：指向**集成方式未接通**这个真实卡点。
      expect(ProrootOption.risks.first, contains('未'),
          reason: '要用"尚未接通"这类措辞，而不是笼统的"不可用"');
      expect(ProrootOption.risks.first, contains('libproroot.so'),
          reason: '第一条要点名真正的卡点对象');
      expect(ProrootOption.risks.first, contains('nativeLibraryDir'),
          reason: '第一条就要给出正确做法（直接 exec）');

      // 第二条要给**可执行的改造清单**，而不是"无解"的论断
      expect(ProrootOption.risks[1], contains('PROROOT_'),
          reason: '接通需要的环境变量清单要列出来');
      expect(ProrootOption.risks[1], contains('jniLibs'),
          reason: '打包方式也是必需项');

      // 全文不许再出现"我方无解 / 上游需重新构建"这类论断
      final joined = ProrootOption.risks.join('\n');
      expect(joined, isNot(contains('我方无解')),
          reason: '有解，只是还没做');
      expect(joined, isNot(contains('上游需重新构建')),
          reason: '二进制没问题，不用等上游');
      // 但要给出**可复核的参考实现来源**
      expect(joined, contains('andClaw'),
          reason: '要指向作者的开源参考实现，便于对照');
    });

    test('About 页展示的 proroot 版本必须来自唯一真源，不许写死', () {
      // ⚠️ 出包验证时**真踩到**：换钉 v1.2.5 之后，About 页仍写死着
      //    'v1.2.8'（旧的、已经不能用的那个版本），一直向用户展示错信息。
      //    是 `strings libapp.so` 把两个版本号都揪出来才发现的。
      //
      // 这类"同一事实存两份"的地方迟早打架（Bug 474 的参数名 cmd/command
      // 是同一个病）。所以这里同时断言两件事：
      //   ① 展示值 == 常量值（不漂）
      //   ② 源码里**没有**写死的版本字面量（防止有人改回去）
      final proroot = AboutInfo.components
          .firstWhere((c) => c.name == 'proroot');
      expect(proroot.version, ProrootOption.pinnedVersion,
          reason: 'About 页要与 ProrootOption.pinnedVersion 一致');

      final src = File('lib/ui/about_info.dart').readAsStringSync();
      // 只查 version: 字段那一行，避免误伤注释里提到的历史版本
      final decl = src
          .split('\n')
          .where((l) => l.trimLeft().startsWith('version:'))
          .where((l) => l.contains("'v1."))
          .toList();
      expect(decl, isEmpty,
          reason: 'proroot 的 version 不许写死字面量，要引用 '
              'ProrootOption.pinnedVersion —— 实测漏改过一次');
    });
  });

  group('Bug 471 · 已知不可用时的 UI 门禁', () {
    late String src;

    setUpAll(() {
      src = File('lib/toolchain/proroot_option.dart').readAsStringSync();
    });

    test('开启开关必须硬拦，不能只是"提醒一句"', () {
      // ⚠️ 这是**行为**变更，不只是文案变更，所以要单独钉住。
      //
      // 改动前 `_toggle` 对未冒烟的情况是"提醒但不强制"，注释写着
      // "用户可能就是想在真构建里试"。那时我们**只是没验证过**，
      // 放行是合理的。
      //
      // 现在我们已经**实测确认必崩**，再放行就是让用户把一次注定失败的
      // 构建跑完（几十分钟 + 一堆定位不到根因的 gradle 报错）。
      // 未知风险可以交给用户判断，已知错误不该出现在选项里。
      final toggleIdx = src.indexOf('void _toggle(bool v)');
      expect(toggleIdx, greaterThanOrEqualTo(0));
      final body = src.substring(toggleIdx, toggleIdx + 1200);

      expect(body, contains('isKnownUnusable()'),
          reason: '开启路径必须查这个门禁');
      expect(body, contains('return;'),
          reason: '命中后必须直接返回（拒绝开启），不能只设个提示继续走');

      // 拦在"提醒未冒烟"之前 —— 顺序反了就变成"先提示、再放行"
      final blockIdx = body.indexOf('isKnownUnusable()');
      final probeWarnIdx = body.indexOf('_probeResult?.ok != true');
      expect(probeWarnIdx, greaterThan(blockIdx),
          reason: '硬拦必须排在"建议先冒烟"之前');
    });

    test('硬拦的提示要说清"是什么问题 + 去哪看详情"', () {
      final toggleIdx = src.indexOf('void _toggle(bool v)');
      final body = src.substring(toggleIdx, toggleIdx + 1200);
      expect(body, contains('实测不可用'),
          reason: '要给出结论，不能只说"暂不可用"');
      expect(body, contains('风险说明'),
          reason: '要指个地方让用户看为什么');
      expect(body, contains('冒烟测试结果'),
          reason: '用户自己跑失败过时，要把它和结论连起来');
    });
  });

  group('Bug 471 · 预检必须在下载之前', () {
    late String src;

    setUpAll(() {
      src = File('lib/mcp/proroot_download.dart').readAsStringSync();
    });

    test('fetchAll 里预检位置早于首个下载调用', () {
      final body = _fetchAllBody(src);
      // Bug 471 修正：预检入口换成了 isKnownUnusable（真机实测结论），
      // 它必须排在 isGlibcCompatible 之前 —— 实测结论优先于符号表推断。
      final guardIdx = body.indexOf('isKnownUnusable');
      expect(guardIdx, greaterThanOrEqualTo(0),
          reason: 'fetchAll 必须做"已实测不可用"预检（Bug 471 修正）');

      final symIdx = body.indexOf('isGlibcCompatible');
      expect(symIdx, greaterThan(guardIdx),
          reason: '实测结论检查要排在最前，符号检查退居其次');

      final dlIdx = body.indexOf('downloadMultiSource');
      expect(dlIdx, greaterThan(0));
      expect(guardIdx, lessThan(dlIdx),
          reason: '预检必须在下载**之前**——否则用户白花流量');

      // 也要早于暂存目录创建，做到"一行网络请求都不发"
      final mkdirIdx = body.indexOf('createSync');
      if (mkdirIdx > 0) {
        expect(guardIdx, lessThan(mkdirIdx));
      }
    });

    test('预检失败抛 DownloadException（而非静默返回）', () {
      final body = _fetchAllBody(src);
      final guard = body.substring(
        body.indexOf('isKnownUnusable'),
        body.indexOf('downloadMultiSource'),
      );
      expect(guard, contains('throw DownloadException'));
      // 两个分支都要抛，不能只留一个
      expect('throw DownloadException'.allMatches(guard).length,
          greaterThanOrEqualTo(2),
          reason: '实测不可用 与 符号不兼容 两条路都必须拦下');
    });

    test('保留了逐文件 sha256 校验（组合检查不能替代完整性检查）', () {
      // 两者是**互补**关系：哈希查"字节有没有被改"，
      // 版本门禁查"这些字节能不能一起跑"。谁都不能删。
      expect(src, contains('verifySha256'));
      expect(src, contains('_verify('));
    });
  });

  group('Bug 471 · 原生侧文案分诊', () {
    late String kt;

    setUpAll(() {
      kt = File('android/app/src/main/kotlin/dev/foa/flutter_on_android/'
              'MainActivity.kt')
          .readAsStringSync();
    });

    test('三种失败现场都要认：加载失败 / reloc / no offset table', () {
      final probe = _probeBody(kt);
      // ⚠️ 本用例被真机实测推翻过**四次**，这是第 ④ 版。
      //
      // 第 ① 版："用 reloc: unresolved 作判据，**而不是** no offset table"。
      // 第 ② 版："no offset table 本身就是死因"。→ 只到症状层。
      // 第 ③ 版（2026-09-21 判别实验）：认定"最先发生的是加载失败"，
      //  并把根因写成"上游 DT_NEEDED 写成了开发名"。→ **作废**。
      // 第 ④ 版（2026-09-21 定案）：对照作者开源实现（andClaw）后确认，
      //   这三个现场**都是我们自己用错加载器造出来的** ——
      //
      //     libproroot.so 的 PT_INTERP = /system/bin/linker64
      //     （Android bionic 链接器），它是一个 **Android 原生 launcher**，
      //     必须从 nativeLibraryDir **直接 exec**。
      //     我们却拿 glibc 的 ld-linux-aarch64.so.1 去加载它。
      //
      //   在 Android bionic 下 libc.so / libdl.so 都是真实存在的运行时库，
      //   上游依赖名**没写错**。第 ③ 版是拿 glibc 规则去审 Android 二进制。
      //
      // 这三个字符串判据本身仍然正确（用错加载器时确实会打印它们），
      // 所以**检测逻辑保留**，只是解读改对了。原生侧必须能认出这一层，
      // 否则真机复现时会被归到"进程退出了但没跑通"那句没用的话里。
      expect(
        probe,
        contains('libdl.so: cannot open'),
        reason: '用错加载器的第一症状，必须在代码里真用上',
      );
      expect(
        probe,
        contains("version `LIBC' not found"),
        reason: '用错加载器的第二症状（补齐 libdl 后才浮现）',
      );
      expect(
        probe,
        contains('libc.so: invalid ELF header'),
        reason: '用错加载器的第三症状（glibc 视角下 libc.so 是 ld script）',
      );
      expect(
        probe,
        contains('devNameNeeded'),
        reason: '判定变量要有名字，方便后续分支复用',
      );
      expect(
        probe,
        contains('out.contains("reloc: unresolved")'),
        reason: '重定位失败判据必须保留',
      );
      expect(
        probe,
        contains('out.contains("no offset table")'),
        reason: '补丁跳过判据必须保留',
      );
      expect(
        probe,
        contains('SIGSEGV'),
        reason: '要能认出崩溃现场',
      );
    });

    test('原生侧也不再出现"缺少 /lib64/ld-linux"', () {
      // 只看**面向用户的字符串字面量**：注释里必须留着这句作反面教材
      // （不然下次有人又会照抄回去），所以不能对整个文件做无差别扫描。
      expect(_userFacingStrings(kt), isNot(contains('缺少 /lib64/ld-linux')));
    });

    test('失败文案**不再**写死版本号（版本由 Dart 侧统一给出）', () {
      // 这里以前断言 contains('2.38')。换版本后它变成了"逼着原生侧
      // 跟着改数字"，而原生侧一旦写错就等于复制了一份会过期的常量。
      // 正确做法：原生只给结论，具体数字由 ProrootOption 单点提供。
      //
      // ⚠️ 2026-09-21 修正：这里以前还断言文案含"版本错配"和"一键下载"。
      //    那是"换版本能救"的旧解读 —— 现已推翻：加载方式不对，换哪个
      //    版本都一样。所以那两条断言必须去掉，不能留着一个骗用户
      //    白下一轮的说法。
      final strings = _userFacingStrings(kt);
      expect(strings, isNot(contains('需要 glibc 2.38')),
          reason: '这是 v1.2.8 时代的数字，钉 v1.2.5 后已不成立');
      expect(strings, isNot(contains('版本错配：')),
          reason: '2026-09-21 推翻：不能再把它当作"版本错配"来陈述'
              '（注意：说"这不是版本错配"是纠正，不算违规，所以只禁断言句式）');
      expect(strings, isNot(contains('要求的 glibc 高于本机 rootfs，'
          '运行时重定位无法解析')),
          reason: '旧的"版本错配"解释整句必须消失');
      // 现场判据仍要能点名，分诊不能退化。
      expect(strings, contains('reloc: unresolved'));
      expect(strings, contains('no offset table'),
          reason: '本机实测就是这条路径，文案必须能解释它');
    });

    test('崩溃文案不许引导"换个版本 / 升级 rootfs"，且要点名加载方式', () {
      // 这条路径以前被写成"没有救"，并显式堵掉"一键下载 / 换 rootfs"。
      // 2026-09-21 定案后，堵掉这两个仍然对（它们都不是解药），
      // 但必须补上**真正的**出路：nativeLibraryDir 直接 exec。
      // 只说"没救"不给方向，等于把用户扔在原地。
      final probe = _probeBody(kt);
      final bIdx = probe.indexOf('linkerPatchSkipped || crashed');
      expect(bIdx, greaterThanOrEqualTo(0),
          reason: '崩溃路径必须有自己的独立分支，不能被 else 吞掉');

      // 取到该分支的代码体，直到下一个 else
      final tail = probe.substring(bIdx);
      final branchEnd = tail.indexOf('} else {');
      final branchRaw = branchEnd > 0 ? tail.substring(0, branchEnd) : tail;

      // ⚠️ 必须**去掉注释**再断言：我在这个分支上方写了
      //    "不要再引导用户去一键下载"这句注释，无差别扫描会把它
      //    当成"文案里有一键下载"而假红。测试要看的是真正会执行的部分。
      final branch = branchRaw
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');

      expect(branch, contains('与版本高低无关'),
          reason: '必须明确告诉用户"换版本也没用"，否则他会去试');
      expect(branch, contains('nativeLibraryDir'),
          reason: '2026-09-21 新增：必须点名**真正的**出路');
      // 要给出判据（PT_INTERP 指向 /system/bin/linker64），
      // 否则"加载方式不对"只是一句没有证据的断言。
      expect(branch.contains('PT_INTERP') || branch.contains('linker64'), isTrue,
          reason: '必须给出加载方式的判据');
      // 必须显式为上游澄清 —— 前三轮一直冤枉它
      expect(
          branch.contains('不是上游缺陷') ||
              branch.contains('不是**上游') ||
              branch.contains('不是上游二进制'),
          isTrue,
          reason: '为上游澄清：二进制没问题，是我们加载方式不对');
      expect(branch, isNot(contains('一键下载')),
          reason: '引导一键下载是错的——换个版本照样不通');
    });

    test('加载失败文案要点名 PT_INTERP 与作者参考实现，并堵死"升级 rootfs"', () {
      // 这条分支是用户最可能看到的（用错加载器时最先撞上它）。
      // 如果这里留着"升级 rootfs 试试"的暗示，用户就会去白折腾一轮 ——
      // 而 rootfs 根本不是卡点：真正缺的是 nativeLibraryDir 直接 exec。
      final probe = _probeBody(kt);
      final cIdx = probe.indexOf('if (devNameNeeded)');
      expect(cIdx, greaterThanOrEqualTo(0),
          reason: '加载失败分支必须存在，且排在 reloc 分支之前');

      // 该分支必须**早于** glibcMismatch 分支被判断
      final aIdx = probe.indexOf('if (glibcMismatch)');
      expect(cIdx, lessThan(aIdx),
          reason: '加载失败比重定位失败更靠前，分诊顺序不能反');

      final tail = probe.substring(cIdx);
      final branchEnd = tail.indexOf('} else if (glibcMismatch)');
      final branchRaw = branchEnd > 0 ? tail.substring(0, branchEnd) : tail;
      final branch = branchRaw
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');

      expect(branch, contains('PT_INTERP'),
          reason: '点名决定性证据，不能只说"加载方式不对"');
      expect(branch, contains('/system/bin/linker64'),
          reason: '给出 PT_INTERP 的具体取值');
      expect(branch, contains('nativeLibraryDir'),
          reason: '给出真正的出路');
      // 显式为上游澄清
      expect(
          branch.contains('不是上游二进制') ||
              branch.contains('不是**上游') ||
              branch.contains('不是上游缺陷'),
          isTrue,
          reason: '为上游澄清：二进制没问题');
      expect(branch, contains('andClaw'),
          reason: '指向作者的开源参考实现，用户可自行核对');
      expect(branch, contains('rootfs 不是卡点'),
          reason: '必须显式堵掉"升级 rootfs"这条错误出路');
      expect(branch, contains('PROROOT_'),
          reason: '点名正确的环境变量前缀（旧文案写的是 PROOT_*）');
    });

    test('原生侧不许再断言"上游 DT_NEEDED 写错"这类已被推翻的结论', () {
      // 兜底：防止有人把第 ③ 版的错误归因照抄回来。
      final strings = _userFacingStrings(kt);
      expect(strings, isNot(contains('DT_NEEDED')),
          reason: 'DT_NEEDED 是 bionic 语境下的正常依赖名，不是缺陷');
      expect(strings, isNot(contains('开发名')),
          reason: '"开发名"是拿 glibc 规则误审 Android 二进制的产物');
      expect(strings, isNot(contains('上游需重新构建')),
          reason: '上游没坏，不需要重新构建');
    });

    test('原生侧版本号与 Dart 侧钉的常量不打架', () {
      // 兜底：万一有人手贱把数字写回原生文案，这里会红。
      final strings = _userFacingStrings(kt);
      final stale = ['需要 glibc 2.38', '要求 glibc 2.38'];
      for (final s in stale) {
        expect(strings, isNot(contains(s)),
            reason: '"$s" 与当前钉的 ${ProrootOption.pinnedVersion} 冲突');
      }
    });
  });
}

/// 抽出 Kotlin 源码里**面向用户的字符串字面量**（双引号内容）。
///
/// 为什么要区分：本文件的注释里**故意**留了旧文案作反面教材
/// （"缺少 /lib64/ld-linux-aarch64.so.1"），无差别扫描会把注释也算进去，
/// 于是"修好了"和"没修"看起来一样。测试必须只看真正会显示给用户的部分。
String _userFacingStrings(String kt) {
  final buf = StringBuffer();
  var inBlockComment = false;
  for (final line in kt.split('\n')) {
    final t = line.trimLeft();
    // KDoc 块（/** … */）：整段跳过。**必须做状态跟踪** ——
    // KDoc 的续行只以 `*` 开头，但**收尾行是 `*/`**，不匹配
    // startsWith('*')，于是多行字符串里恰好以 `*` 开头的那一行
    // （如 '**这不是版本错配**…'）就会被当成 KDoc 结尾而漏过，
    // 把注释文字当成用户文案（2026-09-21 实测踩到）。
    if (inBlockComment) {
      if (t.contains('*/')) inBlockComment = false;
      continue;
    }
    if (t.startsWith('/**') || t.startsWith('/*')) {
      if (!t.contains('*/')) inBlockComment = true;
      continue;
    }
    // 跳过注释行（// 与 /// 与 * 开头的 KDoc 续行）
    if (t.startsWith('//') || t.startsWith('*')) continue;
    for (final m in RegExp(r'"([^"\\]*)"').allMatches(line)) {
      buf.writeln(m.group(1));
    }
  }
  return buf.toString();
}

/// 截出 `fetchAll` 的方法体。
String _fetchAllBody(String src) {
  final start = src.indexOf('Future<String> fetchAll(');
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 fetchAll');
  // 下一个同级声明作为结束
  final end = src.indexOf('\n  /// 校验', start);
  return src.substring(start, end > 0 ? end : src.length);
}

/// 截出 Kotlin `prorootProbe` 的方法体。
///
/// 边界用**下一个成员声明**（`proroot` 之后的 `applyProrootEnv` 的 KDoc）
/// 定位，不能用 `applyProrootEnv(pb)`——它在方法体内**中途**就出现
/// （进程启动前调环境），截在那里会把后面所有错误文案切掉。
String _probeBody(String src) {
  final start = src.indexOf('private fun prorootProbe()');
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 prorootProbe');
  final end = src.indexOf(
    'proroot 进程需要的环境',
    start,
  );
  return src.substring(start, end > start ? end : src.length);
}
