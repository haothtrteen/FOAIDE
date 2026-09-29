/// 首启判定闸门。
///
/// ## 为什么单独一个 Widget 而不是改 main()
///
/// `main.dart` 的职责是"App 壳 + 通知路由"，已经很清楚了（133 行）。
/// 把"该显示引导还是主页"的异步判定塞进去会让它变成三件事混在一起。
/// 更重要的是：[FoaApp] 的 `home:` 是**同步构造**的，而判定需要
/// 异步读 `filesDir` 下的标记文件 —— 必须有个中间层来承接这个过渡。
///
/// ## 三条不能违背的约束（都由单测盯着）
///
/// ### 1. 不能阻塞首帧
///
/// 项目已确立的哲学（`core/theme.dart` 里 ThemeController.load 那段
/// 长注释写得很清楚）：
/// > "为什么不用'启动先阻塞读完再 runApp'：`envInfo()` 走平台通道，
/// >  阻塞它会把首帧一起拖慢，而主题偏好完全不值得这个代价。"
///
/// 读引导标记**同样**走 `envInfo()` → filesDir，所以**同样**不能
/// 在 `runApp` 前 await。这里用「首帧后异步补齐」。
///
/// ### 2. `info == null` 不等于"没装"
///
/// [EnvState.bootstrap] 是异步的。它跑完之前 `info == null`，
/// 而 `isInstalled` 对 null 返回 false —— 照着这个判断会在**每一次
/// 启动**都弹引导，把已经装好工具链的老用户烦死。
///
/// 所以必须区分三态：加载中 / 未装 / 已装。
///
/// ### 3. 加载中不能先渲染主页再切走
///
/// 那会闪一下主页再跳引导。加载期间渲染一个与主页底色一致的纯色占位
/// （[FoaTheme.bg]，和 HomePage 的 Scaffold 背景同源），用户感知不到
/// 中间态的存在。宁可多一个极简占位屏，也不要"闪一下"。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../env/env_installer.dart';
import 'home_page.dart';
import 'onboarding_page.dart';
import 'onboarding_prefs.dart';

/// 决定首屏显示引导还是主页。
class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key});

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  /// 判定是否完成。false 期间渲染占位。
  bool _decided = false;

  /// 该不该显示引导。
  bool _showOnboarding = false;

  @override
  void initState() {
    super.initState();
    // 首帧后再判定 —— 见类注释的约束 1。
    WidgetsBinding.instance.addPostFrameCallback((_) => _decide());
  }

  Future<void> _decide() async {
    // 等 EnvState.bootstrap() 落地。
    //
    // 不能直接 `await bootstrap()`（那是另一件事，而且 EnvState 由
    // Provider 持有，重复调会造成两次平台通道往返）。这里轮询等它的
    // 结果出现 —— bootstrap 通常几十毫秒回来，最多等 3 秒就放弃判定，
    // 免得某个设备上通道永久挂起导致**卡在占位屏出不来**。
    final env = context.read<EnvState>();
    for (var i = 0; i < 30 && env.info == null && env.error == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
    }
    if (!mounted) return;

    bool seen;
    try {
      seen = await OnboardingPrefs.seen();
    } catch (_) {
      seen = false;
    }
    if (!mounted) return;

    setState(() {
      // 判定规则：没看过引导就显示它。
      //
      // ⚠️ 刻意**不**加"环境已装就跳过"：引导要装的是整个工具链
      // （6 个组件），rootfs 装好只是 1/6。老用户如果没看过引导
      // 这一版，说明他可能一直不知道还有 JDK/SDK 要装 —— 那正是
      // 该给他看的时候。
      _showOnboarding = !seen;
      _decided = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_decided) return const _SplashPlaceholder();

    if (_showOnboarding) {
      // 引导页是**嵌入**在闸门里的（不是 push 出来的新路由）：
      // 它没有可 pop 的上一页（它是 home），所以用回调通知闸门切换。
      // 这也让"跳过"变成一次 setState，而不是一次路由跳转 ——
      // 少一层 Navigator 栈，返回键行为更可预期。
      return OnboardingPage(
        firstRun: true,
        onFinish: () {
          if (mounted) setState(() => _showOnboarding = false);
        },
      );
    }
    return const HomePage();
  }
}

/// 判定期间占位。
///
/// 只要**看起来像主页还没画完**就够了：同一个底色 + 居中的品牌图标。
/// 刻意不放 spinner —— 判定通常几十毫秒，闪一下转圈反而是噪音。
class _SplashPlaceholder extends StatelessWidget {
  const _SplashPlaceholder();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? FoaTheme.bg : FoaTheme.lightSurface,
      body: Center(
        child: Icon(
          Icons.rocket_launch_outlined,
          size: 44,
          color: FoaTheme.seed.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
