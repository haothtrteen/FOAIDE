import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:foaide/toolchain/sdk_downloader.dart';
import 'package:foaide/toolchain/sdk_installer.dart';
import 'package:foaide/toolchain/toolchain_bootstrap.dart';
import 'package:foaide/ui/onboarding_prefs.dart';

/// alpha.72 固化：首次启动引导页 + 工具链一键安装编排。
///
/// 背景
/// ----
/// FOA 装完不能直接用，要先在设备上落一整套工具链（容器 + JDK +
/// Android SDK + Flutter SDK + 兼容层 + 镜像，约 2GB）。这些原先全压
/// 在「配置」页，新用户打开只看到一堆陌生名词和一个「初始化环境」按钮，
/// 不知道后面还有 5 个组件等着他。
///
/// 本次新增：首次启动的引导页（说清是什么 / 要装什么 / 一键装完）
/// 和它背后的编排器 `ToolchainBootstrap`（项目里**第一个**把 6 个
/// installer 串起来的地方）。
///
/// 这些断言防的是**回归**，尤其是三类在沙箱里跑不出来、只有真机上
/// 才暴露的问题：
///   1. 提示顺序错 → 每次启动都弹引导，烦死老用户；
///   2. 编排查表里写错作者仓库名 → 编译测试全过，用户点开 404；
///   3. 编排顺序错 → 运行时以"某某目录不存在"的形式失败。
void main() {
  final prefs = File('lib/ui/onboarding_prefs.dart');
  final page = File('lib/ui/onboarding_page.dart');
  final gate = File('lib/ui/onboarding_gate.dart');
  final bootstrap = File('lib/toolchain/toolchain_bootstrap.dart');
  final toolchainPage = File('lib/toolchain/toolchain_page.dart');
  final homePage = File('lib/ui/home_page.dart');
  final mainDart = File('lib/main.dart');
  final aboutInfo = File('lib/ui/about_info.dart');

  /// 取某个函数/构造的正文（从签名起往下 `span` 字符）。
  ///
  /// 源码文本断言需要它：全文件 `contains` 太松（别处也会出现同样的串），
  /// 截一段出来才能问"这**里面**有没有"。
  String bodyOf(String src, String anchor, {int span = 1800}) {
    final i = src.indexOf(anchor);
    expect(i, greaterThanOrEqualTo(0), reason: '源码里找不到锚点「$anchor」');
    return src.substring(i, (i + span).clamp(0, src.length));
  }

  /// 去掉整行注释后再判断，避免注释里提到某个词被误判成"代码里有"。
  String codeOnly(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
      .join('\n');

  // ================================================================
  group('引导标记（OnboardingPrefs）', () {
    late String src;
    setUpAll(() {
      expect(prefs.existsSync(), isTrue, reason: '引导标记偏好文件丢失');
      src = prefs.readAsStringSync();
    });

    test('走 filesDir-JSON 模式，不用 shared_preferences', () {
      final code = codeOnly(src);
      expect(code.contains('class OnboardingPrefs'), isTrue);
      expect(code.contains('foa-onboarding.json'), isTrue);
      expect(code.contains('ProotBridge'), isTrue,
          reason: 'filesDir 只能从 ProotBridge().envInfo() 拿');
      expect(code.contains('shared_preferences'), isFalse,
          reason: '项目刻意不用 shared_preferences（见 core/theme.dart 注释）');
      expect(code.contains('path_provider'), isFalse);
      // 同 ThemePrefs / HintPrefs：体验类偏好的 IO 失败一律静默
      expect(RegExp(r'catch \(_\)').hasMatch(src), isTrue,
          reason: '持久化失败必须静默，绝不能把启动拦住');
    });

    test('读失败一律当「没看过」—— 与 HintPrefs 的取舍相反且是有意的', () {
      final seen = bodyOf(src, 'static Future<bool> seen()', span: 400);
      expect(seen.contains('return false'), isTrue,
          reason: '引导读不到标记必须显示引导；'
              '返回 true 会让新用户在一片空白里自己摸索（失职）');
      // 这条注释解释的是"为什么两边不一样"，删掉它下一个人就会"顺手统一"
      expect(src.contains('提示弹多了是骚扰，引导不弹是失职'), isTrue,
          reason: '必须保留与 HintPrefs 取舍相反的理由说明');
    });

    test('版本号判断用「相等」而不是「文件存在」', () {
      final code = codeOnly(src);
      expect(code.contains('static const String currentVersion'), isTrue,
          reason: '引导必须有版本号：改版（新增要装的组件）时要能重弹');
      // isCurrent 是可测的纯函数，别把这段逻辑只留在 seen() 里
      expect(code.contains('static bool isCurrent(String? storedVersion)'), isTrue,
          reason: 'isCurrent 抽出来才能单测（IO 路径在测试里跑不到）');
      expect(code.contains('storedVersion == currentVersion'), isTrue,
          reason: '必须按版本号相等判断，而不是"存过任意值就算看过"');
    });

    test('markSeen 幂等；reset 删文件而不是写空串', () {
      final code = codeOnly(src);
      expect(code.contains('await f.writeAsString(jsonEncode({key: currentVersion}))'),
          isTrue,
          reason: '每次全量覆写，重复调用结果一致 = 幂等');
      expect(code.contains('await f.delete()'), isTrue,
          reason: 'reset 删文件；写空串虽然效果一样，但目录里会留个语义不明的残留');
    });

    test('契约：null / 空串 / 旧版本 / 当前版本', () {
      // 纯函数部分可以直接测，不依赖平台通道
      expect(OnboardingPrefs.isCurrent(null), isFalse,
          reason: '没读过标记 = 没看过，要显示引导');
      expect(OnboardingPrefs.isCurrent(''), isFalse, reason: '空串不算看过');
      expect(OnboardingPrefs.isCurrent('0'), isFalse,
          reason: '旧版本号（引导改过版）应该重弹');
      expect(OnboardingPrefs.isCurrent(OnboardingPrefs.currentVersion), isTrue,
          reason: '当前版本 = 看过，不弹');

      // alpha.72-2：引导页加了权限步骤，版本号必须已升。
      // 不升的话**老用户永远不会看到权限步骤** —— 而他们正是最先撞上
      // "构建完点安装被系统拦下"的那批人。
      expect(OnboardingPrefs.currentVersion, '2',
          reason: '引导实质内容变了必须升版，否则已装好工具链的老用户看不到新步骤');
      expect(OnboardingPrefs.isCurrent('1'), isFalse,
          reason: '看过 v1 引导的老用户这一版要重看（他要补权限知识）');
      expect(OnboardingPrefs.fileName, 'foa-onboarding.json');
      expect(OnboardingPrefs.key, 'seenVersion');
    });
  });

  // ================================================================
  group('编排顺序（BootstrapStep）', () {
    test('rootfs 必须第一、原生后端必须最后、QEMU 在两个 SDK 之后', () {
      const v = BootstrapStep.values;
      expect(v.first, BootstrapStep.rootfs,
          reason: 'rootfs 必须第一：其余几个 installer 第一行都是'
              '「rootfs 未安装 → 抛异常」，顺序错了会连锁失败');
      expect(v.last, BootstrapStep.native,
          reason: '原生后端最后：它是**可选的加速项**（见 isOptional），'
              '要等 Android SDK 的 build-tools 就位才有的可换；'
              '放在最后也保证它装不上时不会挡住前面那串必装组件');

      final qemu = v.indexOf(BootstrapStep.qemu);
      expect(qemu, greaterThan(v.indexOf(BootstrapStep.androidSdk)),
          reason: 'QEMU 会接管 /opt/android-sdk 下的 aapt2，'
              '那些目录还不存在时只能接管一半');
      expect(qemu, greaterThan(v.indexOf(BootstrapStep.flutterSdk)),
          reason: 'QEMU 会接管 /opt/flutter 下的 dart，同理');

      // 原生后端必须在 Android SDK 之后：它换的就是 SDK build-tools 里的
      // 四个二进制，目录不存在时 install() 会直接抛 NO_BUILD_TOOLS。
      expect(v.indexOf(BootstrapStep.native),
          greaterThan(v.indexOf(BootstrapStep.androidSdk)),
          reason: '原生后端要把 /opt/android-sdk/build-tools 下的 aapt2 等'
              '换成 arm64 版，SDK 还没装时它换不了任何东西');
      // 与 QEMU 的前后关系不设断言：两者覆盖的不是同一批文件
      // （原生只管 4 个 build-tools，QEMU 还管 dart/gen_snapshot），
      // 谁先谁后都安全 —— 详见 toolchain_bootstrap.dart 文件头那张表。
    });

    test('原生后端是唯一的可选步骤', () {
      // 这条是软失败语义的开关：它一旦为 false，装不上就会让整条链
      // 判成"安装中断"，而此时 1.5GB 的东西其实都装好了。
      final optional =
          BootstrapStep.values.where((s) => s.isOptional).map((e) => e.name);
      expect(optional, ['native']);
    });

    test('可选步骤失败降级为 skipped、链条继续（源码文本断言）', () {
      final src = File('lib/toolchain/toolchain_bootstrap.dart')
          .readAsStringSync()
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      // `_fail` 是唯一收口处：必装 → failed + 返回 false（停），
      // 可选 → skipped + 返回 true（继续）。
      final f = bodyOf(src, 'bool _fail(BootstrapStep step', span: 900);
      expect(f.contains('step.isOptional'), isTrue,
          reason: '失败处理必须区分可选/必装，否则要么把可选项当致命错误，'
              '要么把必装项的失败也吞掉');
      expect(f.contains('BootstrapStatus.skipped'), isTrue);
      expect(f.contains('return soft'), isTrue,
          reason: '可选步骤要返回 true 让循环继续往下走');
      // 两处 catch 都必须走 _fail，不能有一处直接 _set(failed)
      expect(
          src.indexOf('on DownloadException catch') <
              src.indexOf('bool _fail(BootstrapStep step'),
          isTrue,
          reason: '_fail 得定义在 catch 之前（可读性，顺带确认不是孤立代码）');
    });

    test('轻的在前：JDK 应排在 Flutter SDK 之前', () {
      const v = BootstrapStep.values;
      expect(v.indexOf(BootstrapStep.jdk),
          lessThan(v.indexOf(BootstrapStep.flutterSdk)),
          reason: 'JDK 约 190MB、Flutter SDK 约 1.5GB。'
              '先把小的装完，用户早一点看到"有东西成了"');
    });

    test('声明顺序即执行顺序 —— 枚举字面量顺序要被钉住', () {
      expect(BootstrapStep.values.map((e) => e.name).toList(), [
        'rootfs',
        'jdk',
        'androidSdk',
        'flutterSdk',
        'qemu',
        'mirror',
        'native',
      ], reason: 'start()/retry() 都直接遍历 BootstrapStep.values，'
          '改动枚举顺序等于改动执行顺序，必须有测试挡着');
    });

    test('每步都要有给人看的 label / usage / 非零体积', () {
      for (final s in BootstrapStep.values) {
        expect(s.label.trim().isNotEmpty, isTrue, reason: '${s.name} 缺 label');
        expect(s.usage.trim().isNotEmpty, isTrue, reason: '${s.name} 缺 usage');
        expect(s.approxBytes, greaterThan(0),
            reason: '${s.name}.approxBytes 为 0 会让它在加权进度里不占份额');
        expect(s.sizeLabel.trim().isNotEmpty, isTrue);
      }
    });

    test('每步都要有独立的 label（复制粘贴漏改会撞名）', () {
      final labels = BootstrapStep.values.map((e) => e.label).toSet();
      expect(labels.length, BootstrapStep.values.length,
          reason: '有步骤 label 重复 —— 用户在安装清单里会看到两个同名项');
    });

    test('体积量级要对：Flutter SDK 显著大于 JDK', () {
      // 只钉量级，不钉具体字节（Content-Length 会随版本变）
      expect(BootstrapStep.flutterSdk.approxBytes,
          greaterThan(BootstrapStep.jdk.approxBytes * 5),
          reason: 'Flutter SDK(1.5GB) 与 JDK(190MB) 差近 8 倍；'
              '若两者接近说明有人写错了常量，进度条权重会失真');
    });

    test('体积从真实常量取值，不写死魔数', () {
      final code = codeOnly(bootstrap.readAsStringSync());
      expect(code.contains('JdkInstaller.size'), isTrue,
          reason: 'JDK 体积要读 JdkInstaller.size，写死会在升版本时静默过期');
      expect(code.contains('FlutterSdkInstaller.tarSize'), isTrue,
          reason: 'Flutter SDK 体积要读 tarSize');
      expect(code.contains('AndroidSdkInstaller.components'), isTrue,
          reason: 'Android SDK 是多组件，要实时求和而不是写一个总数');
      expect(code.contains('fold<int>(0, (sum, c) => sum + c.size)'), isTrue,
          reason: '组件表增删时写死的数字不会有任何东西提醒你它错了');
    });
  });

  // ================================================================
  group('加权进度（ToolchainBootstrap.overallFraction）', () {
    /// 造一个可控的编排器（不跑真下载）。
    ToolchainBootstrap withStates(
        Map<BootstrapStep, BootstrapStatus> statuses,
        {Map<BootstrapStep, DownloadProgress>? progresses}) {
      final b = ToolchainBootstrap();
      b.steps = BootstrapStep.values.map((s) {
        return BootstrapStepState(
          step: s,
          status: statuses[s] ?? BootstrapStatus.idle,
          progress: progresses?[s],
        );
      }).toList();
      return b;
    }

    test('全 idle = 0，全 done = 1', () {
      expect(withStates(const {}).overallFraction, 0.0);
      final all = {
        for (final s in BootstrapStep.values) s: BootstrapStatus.done
      };
      expect(withStates(all).overallFraction, 1.0);
    });

    test('不是取平均 —— 装完 JDK 时进度必须明显低于 1/6', () {
      final b = withStates({
        BootstrapStep.rootfs: BootstrapStatus.done,
        BootstrapStep.jdk: BootstrapStatus.done,
      });
      final avg = 2 / BootstrapStep.values.length; // 0.333…
      final total = BootstrapStep.values
          .fold<int>(0, (sum, s) => sum + s.approxBytes);
      final real = (BootstrapStep.rootfs.approxBytes +
              BootstrapStep.jdk.approxBytes) /
          total;

      expect(b.overallFraction, closeTo(real, 1e-9));
      expect(b.overallFraction, lessThan(avg),
          reason: 'rootfs(70MB)+JDK(190MB) 才占总量一小截。'
              '若等于 1/3 说明退回了平均算法，后面几个大块头会挤在最后 '
              '50% 里爬，用户会以为卡住了');
    });

    test('进行中的那一步按自己的下载比例细分（大文件期间进度条是活的）', () {
      final b = withStates(
        {
          BootstrapStep.rootfs: BootstrapStatus.done,
          BootstrapStep.flutterSdk: BootstrapStatus.running,
        },
        progresses: {
          BootstrapStep.flutterSdk:
              const DownloadProgress(received: 500, total: 1000, speed: 0),
        },
      );
      final total = BootstrapStep.values
          .fold<int>(0, (sum, s) => sum + s.approxBytes);
      final expected =
          (BootstrapStep.rootfs.approxBytes + BootstrapStep.flutterSdk.approxBytes * 0.5) /
              total;
      expect(b.overallFraction, closeTo(expected, 1e-9),
          reason: 'running 状态必须把自己 approxBytes 乘以 fraction，'
              '否则下载 1.5GB 的十几分钟里总进度纹丝不动');

      // 半途 → 全下完，进度必须涨
      final b2 = withStates(
        {
          BootstrapStep.rootfs: BootstrapStatus.done,
          BootstrapStep.flutterSdk: BootstrapStatus.running,
        },
        progresses: {
          BootstrapStep.flutterSdk:
              const DownloadProgress(received: 1000, total: 1000, speed: 0),
        },
      );
      expect(b2.overallFraction, greaterThan(b.overallFraction));
    });

    test('没有 progress 的 running 步按 0 计（不虚报）', () {
      final b = withStates({BootstrapStep.jdk: BootstrapStatus.running});
      expect(b.overallFraction, 0.0,
          reason: '下载进度还没报上来时不能凭空给分 —— 宁可停在原地');
    });

    test('failed 不贡献进度（失败那步之前的工作保留、之后的不算）', () {
      final b = withStates({
        BootstrapStep.rootfs: BootstrapStatus.done,
        BootstrapStep.jdk: BootstrapStatus.failed,
        BootstrapStep.flutterSdk: BootstrapStatus.done,
      });
      final total = BootstrapStep.values
          .fold<int>(0, (sum, s) => sum + s.approxBytes);
      // flutterSdk 虽然被标 done，但它是失败步之后的 —— start() 不可能
      // 走到那里。这里只验证 failed 本身不贡献分数。
      final withJdk = (BootstrapStep.rootfs.approxBytes +
              BootstrapStep.jdk.approxBytes +
              BootstrapStep.flutterSdk.approxBytes) /
          total;
      expect(b.overallFraction, lessThan(withJdk),
          reason: 'failed 步骤不能算作"已完成"');
    });

    test('skipped 视为已完成（用户跳过的项不该卡住进度条）', () {
      final skipped = withStates({
        for (final s in BootstrapStep.values) s: BootstrapStatus.skipped
      });
      expect(skipped.overallFraction, 1.0);
      expect(skipped.isAllDone, isTrue,
          reason: '全 skipped 也是"没有待办"，应判定为全部完成');
    });

    test('百分比与 fraction 一致', () {
      final b = withStates({
        for (final s in BootstrapStep.values) s: BootstrapStatus.done
      });
      expect(b.overallPercent, 100);
      expect(withStates(const {}).overallPercent, 0);
    });
  });

  // ================================================================
  group('中断语义（失败即停、重试只补失败步）', () {
    test('hasFailure / failedStep / summary 的取值', () {
      final b = ToolchainBootstrap();
      expect(b.hasFailure, isFalse);
      expect(b.failedStep, isNull);
      expect(b.isAllDone, isFalse, reason: '初始全是 idle，当然没装完');
      expect(b.isRunning, isFalse);

      b.steps = BootstrapStep.values.map((s) {
        return BootstrapStepState(
          step: s,
          status: s == BootstrapStep.androidSdk
              ? BootstrapStatus.failed
              : (s.index < BootstrapStep.androidSdk.index
                  ? BootstrapStatus.done
                  : BootstrapStatus.idle),
          error: s == BootstrapStep.androidSdk ? '网络连接失败，检查网络后重试' : null,
        );
      }).toList();

      expect(b.hasFailure, isTrue);
      expect(b.failedStep, BootstrapStep.androidSdk);
      expect(b.summary, contains('Android SDK'),
          reason: '总状态要说清是哪一步断了，只写"安装失败"用户无从下手');
      expect(b.summary, contains('中断'));
    });

    test('retry 从失败步开始：之前的 done 状态必须保留', () {
      final src = bootstrap.readAsStringSync();
      final retry = bodyOf(src, 'Future<void> retry()', span: 900);
      expect(retry.contains('step.index < from.index'), isTrue,
          reason: 'retry 必须跳过失败步之前的步骤 —— '
              '否则用户点一次重试就要重下已经下好的 1.5GB Flutter SDK');
      expect(retry.contains('BootstrapStepState(step: step)'), isTrue,
          reason: '失败步之后的残留状态要清回 idle，不然 UI 会显示上一轮的鬼影');
    });

    test('start 失败即 return，不继续下一步', () {
      final src = bootstrap.readAsStringSync();
      final start = bodyOf(src, 'Future<void> start()', span: 900);
      expect(start.contains('if (!ok) break'), isTrue,
          reason: '失败即停：不自动重试、不带着一个坏环境继续往下装');
    });

    test('start 前 env 为空要报错而不是静默空跑', () {
      final src = bootstrap.readAsStringSync();
      expect(src.contains('环境信息还没拿到'), isTrue,
          reason: 'env 为空时静默 return 会让用户点了按钮什么都没发生');
    });

    test('start 重复调用要幂等（_running 守卫）', () {
      final src = bootstrap.readAsStringSync();
      final start = bodyOf(src, 'Future<void> start()', span: 200);
      expect(start.contains('if (_running) return'), isTrue,
          reason: '连点两次「全自动安装」不能跑起两套并发下载');
    });

    test('cancel 只停后续步骤，不保证杀掉在跑的下载（注释要说明）', () {
      final src = bootstrap.readAsStringSync();
      expect(src.contains('_token?.cancel()'), isTrue);
      expect(src.contains('不杀在跑的下载'), isTrue,
          reason: '部分 installer 的 token 在解压阶段无效 ——'
              '这个限制必须写在代码里，否则以后有人会以为 cancel 是即时的');
    });

    test('快路径：每步先 verify，已装好的不重下', () {
      final src = bootstrap.readAsStringSync();
      final run = bodyOf(src, 'Future<bool> _runStep', span: 1600);
      final verifyIdx = run.indexOf('await _verify(step, e)');
      final installIdx = run.indexOf('await _install(step, e)');
      expect(verifyIdx, greaterThan(0), reason: '先探测');
      expect(installIdx, greaterThan(0), reason: '再安装');
      expect(verifyIdx < installIdx, isTrue,
          reason: '顺序反了就变成"先下再看" —— 正是要避免的重下');
      expect(run.contains('已经装好'), isTrue, reason: '要有注释说明这是必须而非优化');
    });

    test('异常翻译：网络 / 磁盘满 / 超时 要给人话', () {
      final src = bootstrap.readAsStringSync();
      final humanize = bodyOf(src, 'static String _humanize', span: 900);
      expect(humanize.contains('SocketException'), isTrue);
      expect(humanize.contains('网络连接失败'), isTrue);
      expect(humanize.contains('No space left'), isTrue);
      expect(humanize.contains('存储空间不足'), isTrue);
      expect(humanize.contains('timeout'), isTrue);
      // DownloadException 自带文案更准，优先用它
      expect(bodyOf(src, 'Future<bool> _runStep', span: 1600)
          .contains('on DownloadException'), isTrue,
          reason: 'DownloadException 的 message 是下载器写的，比通用翻译准');
    });

    test('phase 兜底是原样显示而不是「未知」', () {
      final src = bootstrap.readAsStringSync();
      final label = bodyOf(src, 'static String _phaseLabel', span: 700);
      expect(label.contains('_ => phase'), isTrue,
          reason: '显示一个陌生的英文词，好过让用户以为界面坏了');
      expect(label.contains("'downloading'"), isTrue);
      expect(label.contains('下载中'), isTrue);
    });
  });

  // ================================================================
  group('PageView 翻页（alpha.72 真机回归：「下一步」点了不动）', () {
    late String src;
    setUpAll(() {
      expect(page.existsSync(), isTrue);
      src = page.readAsStringSync();
    });

    test('PageController 必须是 State 字段，不能在 build 里 new', () {
      final code = codeOnly(src);
      expect(code.contains('late final PageController _pageCtl'), isTrue,
          reason: 'controller 要跨 build 存活才能在同一个 position 上翻页');

      // 这条是回归本体：当初写的就是 `PageController(initialPage: _page)`。
      // initialPage 只在 ScrollPosition **创建那一刻**生效
      // （page_view.dart 里 applyViewportDimension 的分支是
      // `if (oldPixels == null) page = _pageToUseOnStartup;`），
      // 而 Scrollable 判断要不要重建 position 比的是 controller 的
      // **runtimeType** 不是身份（scrollable.dart:698），
      // 新旧都是 PageController → position 复用 → initialPage 没人读。
      expect(code.contains('PageController(initialPage:'), isFalse,
          reason: '在 build 里 new 一个带 initialPage 的 controller 是无效的：'
              'initialPage 只在 position 创建时生效，重建不会被读取');
      expect(code.contains('controller: _pageCtl'), isTrue,
          reason: 'PageView 必须用那个 State 字段');
    });

    test('controller 必须被释放（传进去的 controller PageView 不会管）', () {
      final dispose = bodyOf(src, 'void dispose()', span: 500);
      expect(dispose.contains('_pageCtl.dispose()'), isTrue,
          reason: '_PageViewState.dispose 只在 widget.controller == null 时'
              '才释放内部 controller；我们传了，就只能自己释放');
    });

    test('_page 只能被 onPageChanged 写，不能手动自增', () {
      final code = codeOnly(src);
      expect(code.contains('_page++'), isFalse,
          reason: '手动自增 _page 会和内容区的 pixels 变成两个真值源 ——'
              '表现是"圆点在动、页面不动"');
      expect(code.contains('onPageChanged: (i) => setState(() => _page = i)'),
          isTrue,
          reason: '_page 必须只做被 onPageChanged 写入的镜像');
      expect(code.contains('onPageChanged'), isTrue);
    });

    test('「下一步」按钮走 controller.nextPage', () {
      final code = codeOnly(src);
      expect(code.contains('_pageCtl.nextPage'), isTrue,
          reason: 'nextPage 内部走 position.animateTo，翻完由 onPageChanged '
              '回写 _page —— 这是唯一的真值流');
      expect(code.contains('curve: Curves.easeInOut'), isTrue,
          reason: '带动画的手感：翻页本身是"移动"的隐喻');
    });

    test('不再有「拿不到稳定引用」那套错误说法', () {
      // 第一版那句注释的三条断言全是错的，且正是它把正确修法挡在门外：
      // ① PageView 的 widget 重建，但 State 从不重建；
      // ② controller 是我们自己 new 的，引用一直在手上；
      // ③ _page==2 换的是 footer 分支，不是 PageView 的子树。
      expect(src.contains('拿不到稳定引用'), isFalse,
          reason: '这条注释是错的，且它挡住了唯一正确的修法');
      expect(src.contains('_page = -1'), isFalse,
          reason: '_page=-1 是死代码：_installing 置 true 后立刻走安装视图');
    });
  });

  // ================================================================
  group('引导页权限步骤（alpha.72）', () {
    late String src;
    setUpAll(() {
      src = page.readAsStringSync();
    });

    test('两项权限都在引导页里，且放在第 3 页', () {
      final code = codeOnly(src);
      expect(code.contains('允许安装应用'), isTrue);
      expect(code.contains('允许发通知'), isTrue);
      final start = bodyOf(src, 'Widget _pageStart', span: 1200);
      expect(start.contains('_permissionCard()'), isTrue,
          reason: '权限卡挂在第 3 页（决定装不装的那页），'
              '放到第 1、2 页会打断"是什么 / 要装什么"的叙事');
    });

    test('权限状态要有三态：null 不能显示成"未开启"', () {
      final code = codeOnly(src);
      expect(code.contains('bool? _canInstall'), isTrue);
      expect(code.contains('bool? _notifyOn'), isTrue);
      expect(code.contains('final pending = granted == null'), isTrue,
          reason: '还没查出来时显示"未开启"是一个假的坏消息，'
              '会让用户白白紧张一次');
      expect(code.contains('检查中'), isTrue);
    });

    test('resume 时复查（用户开完权限回来要看到状态变了）', () {
      final code = codeOnly(src);
      expect(code.contains('with WidgetsBindingObserver'), isTrue);
      expect(code.contains('didChangeAppLifecycleState'), isTrue);
      expect(code.contains('AppLifecycleState.resumed'), isTrue,
          reason: '不复查的话用户会以为开关没生效而反复点');
      expect(code.contains('addObserver(this)'), isTrue);
      expect(code.contains('removeObserver(this)'), isTrue,
          reason: 'observer 必须成对移除');
    });

    test('安装权限未开要先确认一次，但允许"先装工具链"', () {
      final start = bodyOf(src, 'Future<void> _startInstall', span: 700);
      final confirmIdx = start.indexOf('_confirmInstallPermission');
      final installIdx = start.indexOf('_ensureBackendPref');
      expect(confirmIdx, greaterThan(0), reason: '必须先确认');
      expect(installIdx, greaterThan(0));
      expect(confirmIdx < installIdx, isTrue,
          reason: '确认要在真正开始之前');
      expect(start.contains('if (go != true) return'), isTrue,
          reason: '用户选「去开启」时不再往下走安装');
      expect(start.contains('_canInstall == false'), isTrue,
          reason: '只在**明确未开启**时确认（null 是"还没查出来"，不该提示）');

      final dlg = bodyOf(src, 'Future<bool?> _confirmInstallPermission', span: 900);
      expect(dlg.contains('先装工具链'), isTrue,
          reason: '必须留一条不立刻开权限的路 —— 权限随时能补，不该被硬拦');
      expect(dlg.contains('去开启'), isTrue);
    });

    test('通知权限不拦路（只提示）', () {
      final start = bodyOf(src, 'Future<void> _startInstall', span: 700);
      expect(start.contains('_notifyOn'), isFalse,
          reason: '通知不开只影响"退到桌面看进度"，构建本身完全正常 ——'
              '拦它是过度打扰');
      expect(src.contains('不装也行，构建不受影响'), isTrue,
          reason: '文案要如实说明"影响很小"');
    });
  });

  // ================================================================
  group('权限的原生侧（Manifest + Kotlin）', () {
    test('REQUEST_INSTALL_PACKAGES 已声明（两份 manifest）', () {
      for (final p in [
        'android/app/src/main/AndroidManifest.xml',
        'platform/android/AndroidManifest.xml',
      ]) {
        final f = File(p);
        expect(f.existsSync(), isTrue, reason: '$p 不存在');
        expect(f.readAsStringSync().contains('REQUEST_INSTALL_PACKAGES'), isTrue,
            reason: '$p 缺 REQUEST_INSTALL_PACKAGES。'
                'targetSdk 28 ≥ 26，那道 AppOps 闸门对我们是生效的 ——'
                '不声明的话系统设置里连这一项都没有，用户无处可开');
      }
      // 两份必须一致（dev-handbook/06-发布流程.md 的门禁）
      expect(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
        File('platform/android/AndroidManifest.xml').readAsStringSync(),
        reason: '模板与生成目录不一致：下次跑 setup_android.sh 会覆盖掉改动',
      );
    });

    test('MainActivity 三个权限 method 已注册（两份一致）', () {
      for (final p in [
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
        'platform/android/MainActivity.kt',
      ]) {
        final s = File(p).readAsStringSync();
        expect(s.contains('"canInstallPackages"'), isTrue, reason: '$p 缺 canInstallPackages');
        expect(s.contains('"openInstallUnknownSources"'), isTrue,
            reason: '$p 缺 openInstallUnknownSources');
        expect(s.contains('"openNotificationSettings"'), isTrue,
            reason: '$p 缺 openNotificationSettings');
        // 跳设置页必须主线程
        expect(s.contains('runOnUiThread'), isTrue, reason: 'startActivity 只能主线程调');
        expect(s.contains('ACTION_MANAGE_UNKNOWN_APP_SOURCES'), isTrue);
        expect(s.contains('ACTION_APP_NOTIFICATION_SETTINGS'), isTrue);
        // 低版本兜底
        expect(s.contains('ACTION_APPLICATION_DETAILS_SETTINGS'), isTrue,
            reason: 'API<26 没有通知渠道，要退到应用详情页');
      }
      expect(
        File('android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt')
            .readAsStringSync(),
        File('platform/android/MainActivity.kt').readAsStringSync(),
        reason: '两份 MainActivity 不一致',
      );
    });

    test('canInstallPackages 对低版本不能报假警报', () {
      final s = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      final fn = bodyOf(s, 'private fun canInstallPackages()', span: 900);
      expect(fn.contains('SDK_INT < Build.VERSION_CODES.O'), isTrue,
          reason: 'API<26 没有这道闸门，应返回 true 而不是制造假警报');
    });

    test('Dart 侧两个桥都封好了，异常一律不抛', () {
      final fb = File('lib/filemanager/fs_browser_bridge.dart').readAsStringSync();
      expect(fb.contains('canInstallPackages()'), isTrue);
      expect(fb.contains('openInstallUnknownSources()'), isTrue);
      // 查不到状态时返回 true（保守放行），不能把用户拦在可能不存在的问题前
      expect(bodyOf(fb, 'Future<bool> canInstallPackages', span: 500)
          .contains('?? true'), isTrue,
          reason: '权限查询失败要保守放行：让他去装，系统会给明确反馈');

      final bn = File('lib/toolchain/build_notify.dart').readAsStringSync();
      expect(bn.contains('openSettings()'), isTrue);
      expect(bodyOf(bn, 'static Future<bool> openSettings', span: 400)
          .contains('catch (_)'), isTrue,
          reason: '跳设置页失败要静默（同 enabled 的取舍）');
    });

    test('注释如实说明：targetSdk 28 下通知权限弹不了框', () {
      final bn = File('lib/toolchain/build_notify.dart').readAsStringSync();
      expect(bn.contains('targetSdk ≥ 33'), isTrue,
          reason: '必须写明"主动弹框需要 targetSdk>=33"这个平台限制，'
              '否则后来者会以为实现偷懒、去加一个无效的 requestPermissions');
    });
  });

  // ================================================================
  group('SDK 解压加固（alpha.72：「重试似乎无效」）', () {
    late String src;
    setUpAll(() {
      src = File('lib/toolchain/sdk_installer.dart').readAsStringSync();
    });

    test('暂存目录清理必须查退出码，卡住就停', () {
      expect(src.contains('if ! rm -rf /opt/foa-sdk-stage'), isTrue,
          reason: 'rm -rf 对不存在的路径也返回 0，所以它非 0 只能是"真删不干净"，'
              '必须显式处理而不是让它继续往下');
      expect(src.contains('find /opt/foa-sdk-stage -mindepth 1 -delete'), isTrue,
          reason: '兜底再逐项删一次（proot 下 rm 的目录遍历偶有残留）');
      expect(src.contains('STAGE_STUCK'), isTrue,
          reason: '仍然卡住就中止 —— 带着脏目录继续跑会把错误配到错误的组件上');
      expect(src.contains('exit 5'), isTrue);
    });

    test('脚本要回显组件名，防止报错张冠李戴', () {
      // 注意用 raw 字符串：这个字面量里有 `${`，普通单引号串会把它
      // 当成插值（shell 脚本里的 `${c.id}` 是要原样出现的）。
      expect(src.contains(r'echo "COMPONENT ${'), isTrue,
          reason: '真机上出现过「报 platform-tools、实际错在 android-36」：'
              '脚本不查 rm 退出码，带着脏目录继续跑，'
              '报错里于是只有上一条无关的 rm stderr。回显组件名才能对上号');
    });

    test('STAGE_STUCK 优先于 KEYFILE_MISSING 判定', () {
      final fn = bodyOf(src, 'static String explainExtractFailure', span: 2200);
      final stuck = fn.indexOf('STAGE_STUCK');
      final missing = fn.indexOf('KEYFILE_MISSING');
      expect(stuck, greaterThan(0));
      expect(missing, greaterThan(0));
      expect(stuck < missing, isTrue,
          reason: '暂存目录不干净时，后面的关键文件缺失是**后果**不是原因 ——'
              '报"关键文件缺失"会把用户引到错误的方向');
    });

    test('失败信息要给可操作的下一步', () {
      final fn = bodyOf(src, 'static String explainExtractFailure', span: 2200);
      expect(fn.contains('重试失败的那一步'), isTrue,
          reason: '要告诉用户"重试只补失败的这一步"');
      expect(fn.contains('从本地文件导入'), isTrue,
          reason: '要给出绕开这条路的备选方案');
      expect(fn.contains('不会被重下'), isTrue,
          reason: '用户最怕的就是重试要从头再来一次');
    });

    test('stderr 与 stdout 分开呈现', () {
      final fn = bodyOf(src, 'static String explainExtractFailure', span: 2200);
      expect(fn.contains('final err = stderr.trim()'), isTrue);
      expect(fn.contains('final out = stdout.trim()'), isTrue,
          reason: '上一版混成一句，于是那条无关的 rm 报错把真正的原因盖住了');
    });

    test('explainExtractFailure 是静态方法（可测，不依赖平台通道）', () {
      expect(src.contains('static String explainExtractFailure'), isTrue);
      final c = AndroidSdkInstaller.components.first;
      // 纯函数，直接调用即可 —— 这是它抽成静态方法唯一的目的
      final stuck = AndroidSdkInstaller.explainExtractFailure(
          c, 'STAGE_STUCK\n/tmp/x: Directory not empty', '');
      expect(stuck, contains('清不掉'));
      expect(stuck, contains(c.id));
      final missing = AndroidSdkInstaller.explainExtractFailure(
          c, 'KEYFILE_MISSING /opt/android-sdk/platform-tools/adb', '');
      expect(missing, contains('缺少关键文件'));
      expect(missing, contains(c.id));
    });
  });

  // ================================================================
  group('引导页接线（源码文本断言）', () {
    late String src;
    setUpAll(() {
      expect(page.existsSync(), isTrue);
      src = page.readAsStringSync();
    });

    test('作者仓库地址只能取 AboutInfo.authorRepo，绝不硬编码', () {
      final code = codeOnly(src);
      expect(code.contains('AboutInfo.authorRepo'), isTrue,
          reason: '引导页必须用 AboutInfo 这个唯一真源');
      // 这条最要紧：仓库名曾被写错过一次（/haothtrreen vs /haothtrteen），
      // 而那种错误编译、测试、运行全都不报，只有用户点开 404 才知道。
      expect(code.contains('github.com'), isFalse,
          reason: '引导页里出现字面量 github.com 说明有人抄了地址进来 ——'
              '正是要防的 bug');
      expect(code.contains('haothtrteen'), isFalse,
          reason: '作者名不得硬编码在引导页，必须走 AboutInfo.author');
      expect(code.contains('haothtrreen'), isFalse, reason: '拼错的版本更不能出现');
      expect(code.contains('AboutInfo.author'), isTrue,
          reason: '「作者 · xxx」这一行要取 AboutInfo.author');
    });

    test('关于页真源里作者名与仓库地址一致', () {
      final info = aboutInfo.readAsStringSync();
      expect(info.contains("'haothtrteen'"), isTrue,
          reason: 'AboutInfo.author 被改动；仓库用户名是 haothtrteen');
      expect(info.contains('https://github.com/haothtrteen'), isTrue,
          reason: 'AboutInfo.authorRepo 必须指向同一个用户名');
    });

    test('作者入口可点开浏览器 + 可复制（一行两用）', () {
      final card = bodyOf(src, 'Widget _authorCard()', span: 2600);
      expect(card.contains('Clipboard.setData'), isTrue,
          reason: '必须能复制 —— 打不开浏览器的设备上这是唯一出路');
      expect(card.contains('ClipboardData(text: AboutInfo.authorRepo)'), isTrue,
          reason: '复制的必须是真源地址');
      expect(card.contains('launchUrl'), isTrue,
          reason: '必须能点开浏览器（_openRepo 里）');
      expect(card.contains('InkWell'), isTrue, reason: '地址文字本身可点');
      expect(card.contains('复制仓库地址'), isTrue, reason: '要有 tooltip');
      // 打不开浏览器时不能静默失败
      expect(bodyOf(src, 'Future<void> _openRepo()', span: 600)
          .contains('打不开浏览器'), isTrue,
          reason: 'launchUrl 返回 false 时要提示"地址已可复制"，'
              '不能让用户点了一下什么都没发生');
    });

    test('给用户两条路：全自动安装 / 去工具链页手动', () {
      final code = codeOnly(src);
      expect(code.contains('全自动安装'), isTrue);
      expect(code.contains('ToolchainPage'), isTrue,
          reason: '「我手动装」必须真能到工具链页');
      expect(code.contains('_startInstall'), isTrue);
      expect(code.contains('_openToolchainManually'), isTrue);
    });

    test('跳工具链页之前必须先写后端偏好（否则被对话框迎面拦住）', () {
      final manual = bodyOf(src, 'Future<void> _openToolchainManually', span: 900);
      final ensureIdx = manual.indexOf('_ensureBackendPref');
      final pushIdx = manual.indexOf('pushReplacement');
      expect(ensureIdx, greaterThan(0), reason: '必须先保证后端偏好已写');
      expect(pushIdx, greaterThan(0));
      expect(ensureIdx < pushIdx, isTrue,
          reason: '顺序反了的话，用户一进工具链页就会撞上'
              '「选哪个后端」对话框 —— 一个他没听说过的选择题');

      final ensure = bodyOf(src, 'Future<void> _ensureBackendPref', span: 800);
      expect(ensure.contains('BackendPrefs.load(e)'), isTrue);
      expect(ensure.contains('BackendPrefs.save(e, BuildBackend.proot)'), isTrue,
          reason: '默认值必须和 ContainerPrefs 一致（proot），'
              '且只在未设置时才写，不能覆盖用户的选择');
      expect(ensure.contains('existing == null'), isTrue,
          reason: '已有偏好时不得覆盖 —— 用户可能明确选过 termux');
    });

    test('自动安装也开始前写后端偏好', () {
      final start = bodyOf(src, 'Future<void> _startInstall', span: 800);
      expect(start.contains('_ensureBackendPref(env)'), isTrue,
          reason: '装完后用户可能被引导去工具链页，偏好要提前就位');
      expect(start.contains('_boot.start()'), isTrue);
    });

    test('标记已看的时机：只在成功或主动离开时，不在一进页面', () {
      // 截到 initState 的收尾大括号为止 —— 多截一点就会跨进下一个方法，
      // 把"别处有 markSeen"误判成"initState 里写了 markSeen"。
      final initStart = src.indexOf('void initState()');
      expect(initStart, greaterThan(0), reason: '找不到 initState');
      final initEnd = src.indexOf('\n  }', initStart);
      expect(initEnd, greaterThan(initStart));
      final initState = src.substring(initStart, initEnd);
      expect(initState.contains('markSeen'), isFalse,
          reason: '一进页面就写标记 → 用户秒退，下次启动就再也看不到引导了');
      expect(initState.contains('addListener'), isTrue,
          reason: 'initState 里该做的是挂监听');

      final start = bodyOf(src, 'Future<void> _startInstall', span: 900);
      expect(start.contains('if (_boot.isAllDone)'), isTrue,
          reason: '只有真装完了才标记；失败必须不标记，否则他没法重试');
      expect(start.contains('_markSeen()'), isTrue);

      final mark = bodyOf(src, 'Future<void> _markSeen()', span: 250);
      expect(mark.contains('widget.firstRun'), isTrue,
          reason: '从设置页进来的（firstRun=false）不该改动标记');
    });

    test('失败兜底：「去工具链页手动处理」不标记已看', () {
      final footer = bodyOf(src, 'Widget _installFooter', span: 2200);
      expect(footer.contains('ToolchainPage(autoStart: true)'), isTrue,
          reason: '从失败态跳过去要带 autoStart，避免又弹后端选择对话框');
      final failIdx = footer.indexOf('去工具链页手动处理');
      expect(failIdx, greaterThan(0));
      final region = footer.substring((failIdx - 700).clamp(0, footer.length), failIdx);
      expect(region.contains('_markSeen'), isFalse,
          reason: '用户还没装完，下次启动应该还能看到引导才能重试');
      expect(region.contains('不**标记已看') || region.contains('不标记'),
          isTrue,
          reason: '这条取舍要写在代码里，否则后来者会"顺手补上"');
    });

    test('失败态提供重试 + 说明已装部分会保留', () {
      final footer = bodyOf(src, 'Widget _installFooter', span: 2200);
      expect(footer.contains('_boot.retry'), isTrue);
      expect(footer.contains('重试失败的那一步'), isTrue);
      expect(bodyOf(src, 'Widget _failureHint', span: 800)
          .contains('已装好的部分会保留'), isTrue,
          reason: '用户最怕的就是重试要从头再来一次');
    });

    test('如实标注下载体积与流量代价', () {
      // _pageChecklist 比默认 span 长（含 totalGb 计算 + 警告框 + 6 行清单），
      // 取到下一个方法签名为止才完整。
      final start = src.indexOf('Widget _pageChecklist()');
      expect(start, greaterThan(0));
      final end = src.indexOf('Widget _checklistRow', start);
      final checklist = src.substring(start, end);
      expect(checklist.contains('Wi-Fi'), isTrue,
          reason: '1.5GB 是用户的真金白银，代价必须写在按钮之前');
      expect(checklist.contains('不会白费'), isTrue,
          reason: '要安抚"下到一半断了怎么办"');
      expect(checklist.contains('totalGb'), isTrue,
          reason: '要给一个总数，用户才能决定现在装不装');
      expect(checklist.contains('for (final s in BootstrapStep.values)'),
          isTrue,
          reason: '清单必须遍历全部步骤生成 ——'
              '写死几条的话，将来加了组件引导页会漏掉它');

      // 单项的"多大 / 干什么用"在 _checklistRow 里渲染
      // span 要盖住整段 _checklistRow（含"可选"角标），
      // 太短会把 s.sizeLabel 切在外面，测出假阴性。
      final row = bodyOf(src, 'Widget _checklistRow', span: 2400);
      expect(row.contains('s.sizeLabel'), isTrue, reason: '每一项都要标多大');
      expect(row.contains('s.usage'), isTrue, reason: '每一项都要说干什么用');
      expect(row.contains('s.label'), isTrue, reason: '每一项都要有名字');
    });

    test('首启不给返回箭头（没有上一页可回）', () {
      expect(src.contains('automaticallyImplyLeading: !widget.firstRun'), isTrue,
          reason: '首启时给返回箭头会让人以为能退到一个不存在的地方；'
              '出口是「跳过」');
      expect(src.contains('跳过'), isTrue, reason: '必须留一个不装的出口');
    });

    test('onFinish 是首启场景的唯一出口', () {
      expect(src.contains('final VoidCallback? onFinish'), isTrue);
      final enter = bodyOf(src, 'Future<void> _enterHome()', span: 500);
      expect(enter.contains('widget.onFinish!()'), isTrue,
          reason: '引导页是 home，没有可 pop 的上一页，只能靠回调让闸门切主页');
      expect(enter.contains('maybePop()'), isTrue,
          reason: '从设置页进来时要走正常 pop');
      expect(enter.contains('_markSeen()'), isTrue);
    });

    test('安装过程中的取消/完成按钮齐全', () {
      final footer = bodyOf(src, 'Widget _installFooter', span: 2200);
      expect(footer.contains('_boot.cancel'), isTrue, reason: '要能取消');
      expect(footer.contains('开始使用'), isTrue, reason: '装完要有明确下一步');
    });
  });

  // ================================================================
  group('首启闸门（OnboardingGate）', () {
    late String src;
    setUpAll(() {
      expect(gate.existsSync(), isTrue);
      src = gate.readAsStringSync();
    });

    test('main.dart 的 home 已换成闸门', () {
      final m = codeOnly(mainDart.readAsStringSync());
      expect(m.contains('home: const OnboardingGate()'), isTrue,
          reason: '没换的话引导页根本不会出现');
      expect(m.contains("import 'ui/onboarding_gate.dart'"), isTrue);
      expect(m.contains('home: const HomePage()'), isFalse,
          reason: '旧的 home 必须移除，否则两个入口冲突');
    });

    test('不阻塞首帧：判定放在 postFrame 回调里', () {
      final init = bodyOf(src, 'void initState()', span: 400);
      expect(init.contains('addPostFrameCallback'), isTrue,
          reason: '读引导标记走 envInfo() 平台通道，在 runApp 前 await '
              '会把首帧一起拖慢（见 core/theme.dart 的同类注释）');
      // main() 里不许出现 await
      final m = codeOnly(mainDart.readAsStringSync());
      expect(m.contains('await OnboardingPrefs'), isFalse,
          reason: '启动路径上不能有平台通道往返');
      expect(m.contains('await OnboardingPrefs.seen'), isFalse);
    });

    test('加载中渲染与主页同底色的占位，不闪主页', () {
      expect(src.contains('_SplashPlaceholder'), isTrue);
      expect(src.contains('FoaTheme.bg'), isTrue,
          reason: '占位底色要与 HomePage 的 Scaffold 背景同源，用户感知不到中间态');
      final ph = bodyOf(src, 'class _SplashPlaceholder', span: 900);
      expect(ph.contains('CircularProgressIndicator'), isFalse,
          reason: '判定通常几十毫秒，闪一下转圈反而是噪音');
    });

    test('三态判断：不能把 info==null（加载中）当成"没装"', () {
      expect(src.contains('env.info == null'), isTrue,
          reason: '必须轮询等 bootstrap 落地');
      expect(src.contains('30'), isTrue,
          reason: '要有超时上限（30×100ms）——'
              '否则平台通道永久挂起时会卡在占位屏出不来');
      expect(src.contains('error == null'), isTrue,
          reason: 'bootstrap 报错时也要放行判定，不能死等');
    });

    test('读标记失败 → 显示引导（宁可多弹一次）', () {
      expect(src.contains('seen = false'), isTrue,
          reason: '读不到就当没看过，与 OnboardingPrefs.seen 的取舍一致');
      expect(src.contains('_showOnboarding = !seen'), isTrue);
      expect(src.contains('_decided = true'), isTrue,
          reason: '判定完必须置位，否则永远停在占位屏');
    });

    test('刻意不因"环境已装"而跳过引导，且要写明理由', () {
      expect(src.contains('1/6'), isTrue,
          reason: 'rootfs 装好只是 6 个组件里的 1 个。'
              '如果按 isInstalled 跳过，一直在用旧版的老用户'
              '永远不知道还有 JDK/SDK 要装');
    });

    test('引导结束走 onFinish 切回主页（不是路由跳转）', () {
      final build = bodyOf(src, 'Widget build(BuildContext context)', span: 1200);
      expect(build.contains('onFinish:'), isTrue);
      expect(build.contains('_showOnboarding = false'), isTrue);
      expect(build.contains('const HomePage()'), isTrue,
          reason: 'onFinish 之后要落到主页');
      expect(build.contains('firstRun: true'), isTrue,
          reason: '闸门里出来的引导一律是首启模式（走完会写标记）');
    });

    test('闸门没碰 main.dart 的通知路由职责', () {
      final m = mainDart.readAsStringSync();
      expect(m.contains('BuildNotify.lastRoute'), isTrue,
          reason: '通知分流协议（preview/takeover）不在本次改动范围内');
      expect(m.contains("'preview'"), isTrue);
      expect(m.contains("'takeover'"), isTrue);
    });
  });

  // ================================================================
  group('工具链页的 autoStart 开关', () {
    late String src;
    setUpAll(() {
      expect(toolchainPage.existsSync(), isTrue);
      src = toolchainPage.readAsStringSync();
    });

    test('默认 false，既有调用点行为不变', () {
      expect(src.contains('this.autoStart = false'), isTrue,
          reason: '主页「配置」→ 工具链那条路不能被改到');
    });

    test('autoStart 时静默用 proot，否则保留原来的选择对话框', () {
      final init = bodyOf(src, '_initBackendAndRefresh', span: 1800);
      expect(init.contains('widget.autoStart'), isTrue);
      expect(init.contains('BackendPrefs.save(env, BuildBackend.proot)'), isTrue,
          reason: '从引导页来的用户被告知"去手动装"，'
              '迎面撞上一个没听说过的选择题是很糟的体验');
      expect(init.contains('_showBackendChoiceDialog'), isTrue,
          reason: '非 autoStart 路径必须保留对话框（默认行为不变）');
    });
  });

  // ================================================================
  group('设置页留了一个重看引导的入口', () {
    late String src;
    setUpAll(() {
      expect(homePage.existsSync(), isTrue);
      src = homePage.readAsStringSync();
    });

    test('入口存在且文案说得清是什么', () {
      expect(src.contains('重新查看初次引导'), isTrue,
          reason: '引导只在首启出现，没有入口的话这个页面等于被删掉了');
      expect(src.contains('_openOnboarding'), isTrue);
    });

    test('先 reset 再 push，且用 firstRun:false', () {
      final fn = bodyOf(src, 'Future<void> _openOnboarding', span: 900);
      final resetIdx = fn.indexOf('OnboardingPrefs.reset()');
      final pushIdx = fn.indexOf('Navigator.of(context).push');
      expect(resetIdx, greaterThan(0), reason: '必须先清标记');
      expect(pushIdx, greaterThan(0));
      expect(resetIdx < pushIdx, isTrue);
      expect(fn.contains('OnboardingPage(firstRun: false)'), isTrue,
          reason: 'firstRun:false 才不写标记、显示返回箭头 ——'
              '用户可以随时退，不会因为误点把首启体验永久消耗掉');
    });
  });
}
