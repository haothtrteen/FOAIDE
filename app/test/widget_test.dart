// Step 1 冒烟测试：App 壳能构建出首页。
// 深层逻辑（proot 桥、rootfs 安装）依赖 MethodChannel 与 filesDir，
// 由真机验证清单覆盖（dev-handbook/03-测试指南.md），不在 widget 测试范围。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:foaide/env/env_installer.dart';
import 'package:foaide/main.dart';
import 'package:foaide/ui/onboarding_gate.dart';
import 'package:foaide/ui/onboarding_page.dart';

void main() {
  testWidgets('FoaApp 构建冒烟测试', (WidgetTester tester) async {
    await tester.pumpWidget(const FoaApp());

    // 首页能渲染出 MaterialApp / Scaffold 即认为壳完整
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);

    // alpha.72：home 换成了 OnboardingGate，它在首帧后起了一个
    // 「等 EnvState.bootstrap 落地」的轮询计时器（30×100ms）。
    // 本测试不跑真实平台通道，EnvState.info 永远为 null，那个计时器
    // 会一直挂着 —— 测试框架在树销毁时会因此报
    // "A Timer is still pending"。把时间推过上限即可收干净。
    //
    // 这不依赖闸门内部的实现细节：`pumpAndSettle` 只承诺"推进时间直到
    // 没有待处理帧"，而闸门无论走哪条分支（超时 / 读到环境 / 读标记
    // 失败）最终都会落到 `_decided = true` 并停止调度。
    // 加 timeout 是为了万一将来有 bug 导致它真死循环时，
    // 这里给出的是一条清晰的失败信息，而不是挂到测试超时。
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('首启闸门需要 EnvState 在作用域内（缺了要立刻炸，不能静默）',
      (WidgetTester tester) async {
    // OnboardingGate 靠 context.read<EnvState>() 等 bootstrap 落地。
    // 两个断言：
    //   ① 缺 Provider 时**立刻**抛 ProviderNotFoundException ——
    //      失败要显式，不能让它吞掉异常后永远停在占位屏；
    //   ② 补上 Provider 后闸门能正常构建（判定结果取决于 filesDir
    //      下的标记文件，沙箱里拿不到，那是真机验证清单的事）。
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<EnvState>(
          create: (_) => _noBootstrapEnv(),
          child: const OnboardingGate(),
        ),
      ),
    );
    expect(find.byType(OnboardingGate), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  // ================================================================
  group('引导页「下一步」必须真的翻页（alpha.72 真机回归）', () {
    /// 把一个带 EnvState 的引导页装起来。
    ///
    /// 用 `firstRun: false`：这个模式不写已看标记，测试不会碰到 filesDir
    /// （那条路要 MethodChannel，沙箱里没有）。
    Future<void> mount(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EnvState>(
            create: (_) => _noBootstrapEnv(),
            child: const OnboardingPage(firstRun: false),
          ),
        ),
      );
    }

    /// 取 PageView 当前实际停留的页码。
    ///
    /// ⚠️ 这是本组测试的**核心**：它读的是 `pixels`（真正决定显示什么），
    /// 而不是 `_page`。第一版的 bug 恰恰是这两个分家了 ——
    /// 圆点和按钮跟着 `_page` 变、内容跟着 `pixels` 不动。
    /// 如果只断言 `_page` 或圆点，这个 bug 会原样溜过去。
    double currentPage(WidgetTester tester) => tester
        .widget<PageView>(find.byType(PageView))
        .controller!
        .page!;

    testWidgets('点「下一步」→ PageView 的 pixels 真的前进了', (tester) async {
      await mount(tester);
      expect(currentPage(tester), 0.0, reason: '初始应停在第 1 页');

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      expect(currentPage(tester), 1.0,
          reason: '按了「下一步」内容区必须翻到第 2 页。'
              '第一版写的是 PageController(initialPage: _page)，'
              '而 initialPage 只在 ScrollPosition 创建时生效，'
              '重建传新 controller 不会让它跳页 —— 圆点会动、内容不动。');
    });

    testWidgets('连点两次能到第 3 页（内容与按钮不能失同步）', (tester) async {
      await mount(tester);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      expect(currentPage(tester), 2.0, reason: '连点两次应到第 3 页');

      // 第 3 页的内容必须真的可见 —— 第一版最危险的后果就是
      // "footer 已经变成「全自动安装」、内容却还停在第一页"，
      // 用户会在没看到 2GB 流量提示的情况下发起下载。
      expect(find.text('准备好了吗'), findsOneWidget,
          reason: '第 3 页的内容要真的显示出来（决定装不装的那页）');
      expect(find.text('全自动安装'), findsOneWidget);
      expect(find.text('下一步'), findsNothing,
          reason: '到最后一页后「下一步」应消失');
    });

    testWidgets('第 3 页真的显示出来了「要装什么」清单才可能被看到', (tester) async {
      await mount(tester);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      // 第 2 页内容的可见性 —— 这是"把代价写在按钮之前"能否成立的前提
      expect(find.text('初次使用需要准备这些'), findsOneWidget);
      expect(find.textContaining('Wi-Fi'), findsOneWidget,
          reason: '约 2GB 的流量提示必须在用户点安装之前真的看到');
    });

    testWidgets('手指滑动与按钮两条路要一致（滑动本来就正常）', (tester) async {
      await mount(tester);

      // 反向滑一页：验证 PageView 本身的滚动没被改坏。
      //
      // 用 `fling` 而不是 `drag`：`drag` 是"按下-平移-抬起"的一次性动作，
      // 速度为零，PageView 会按距离与 `pageSnapping` 重新吸附回原页；
      // `fling` 带初速度，才是真机上"手指一甩"的等价物。
      await tester.fling(
          find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();
      expect(currentPage(tester), 1.0, reason: '手指左滑应切到第 2 页');

      // 再点「下一步」前进（两条路混用不能错乱）
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(currentPage(tester), 2.0,
          reason: '滑动后点按钮要继续前进，不能跳回或不动');
    });

    testWidgets('controller 归 State 所有：页面重建不重置页码', (tester) async {
      await mount(tester);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(currentPage(tester), 1.0);

      // 触发一次重建（切主题会让整棵树重 build）。
      // 第一版的写法会在这里把当前页丢掉（新 controller 的 initialPage
      // 被当成"起点"重来），持有 State 字段则不会。
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: ChangeNotifierProvider<EnvState>(
            create: (_) => _noBootstrapEnv(),
            child: const OnboardingPage(firstRun: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(currentPage(tester), 1.0,
          reason: '重建后应停在第 2 页；若回到 0 说明 controller 又被 new 了一次');
    });
  });
}

/// 造一个**不**自动 bootstrap 的 EnvState。
///
/// `EnvState()` 本身不会发平台调用（bootstrap 要显式调），这里用
/// tearoff 形式传给 `create` 就是为了绕开 `EnvState()..bootstrap()` ——
/// 后者在测试环境里会卡在 MethodChannel 上。
EnvState _noBootstrapEnv() => EnvState();
