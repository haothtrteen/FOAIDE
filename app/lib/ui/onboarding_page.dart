/// 首次启动引导页。
///
/// ## 它要解决什么
///
/// FOA 不是装完就能用的 App —— 它需要先在设备上落一整套构建工具链
/// （容器 + JDK + Android SDK + Flutter SDK + 兼容层 + 镜像），
/// 合计约 2GB 下载量、几百个文件。之前这些全压在「配置」页一张卡片里，
/// 新用户打开只看到一堆陌生的名词和一个「初始化环境」按钮，
/// 完全不知道后面还有 5 个组件等着他。
///
/// 这个页面就是那段缺失的**开场白**：说清楚这是什么、要下多少、
/// 然后提供一条「点一下全装完」的路。
///
/// ## 为什么是"介绍 + 一键"而不是纯教程
///
/// 教程用户不会读（`hint_prefs.dart` 开头记着同一条教训：
/// "与其写一篇用户不会去读的教程，不如在首次进入时给一条提示"）。
/// 所以第二页只给**清单**（要装什么、多大、干什么用），
/// 不做原理讲解 —— 讲原理的地方在「方案说明」和「关于」页。
///
/// ## 为什么体积要如实标
///
/// Flutter SDK 一个就 1.5GB。用户在没有 Wi-Fi 的情况下点「全自动安装」，
/// 是要付出真实话费代价的。**把代价写在按钮之前**是基本尊重，
/// 也是这个页面存在的理由之一。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../env/env_installer.dart';
import '../filemanager/fs_browser_bridge.dart';
import '../toolchain/build_notify.dart';
import '../toolchain/sdk_downloader.dart';
import '../toolchain/termux_backend.dart';
import '../toolchain/toolchain_bootstrap.dart';
import '../toolchain/toolchain_page.dart';
import 'about_info.dart';
import 'onboarding_prefs.dart';

/// 引导页。
///
/// [firstRun] 为 true 时是首次启动（走完自动标记已看、不显示返回箭头）；
/// false 时是从设置页「重新查看引导」进来的（可以随时退，不改标记）。
///
/// [onFinish] 由宿主注入的"引导结束"通知。**首启场景下它是唯一的出口**：
/// 引导页是 home，没有可 pop 的上一页，只能靠回调让闸门切回主页。
/// 从设置页进来时（firstRun=false）不传，走 `Navigator.pop` 正常返回。
class OnboardingPage extends StatefulWidget {
  final bool firstRun;

  /// 引导结束（跳过 / 走完 / 装完）时的回调。
  final VoidCallback? onFinish;

  const OnboardingPage({super.key, this.firstRun = true, this.onFinish});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with WidgetsBindingObserver {
  /// 当前页（0=这是什么 1=要装什么 2=开始）。
  ///
  /// ⚠️ 它是**只读镜像**，唯一写入点是 [PageView.onPageChanged]。
  ///
  /// 不要在这里 `_page++` 然后指望 PageView 跟着走 —— 那正是 alpha.72
  /// 第一个版本的 bug：当时写的是 `PageController(initialPage: _page)`，
  /// 而 `initialPage` **只在 ScrollPosition 创建那一刻生效**
  /// （`page_view.dart` 里 `applyViewportDimension` 的分支是
  /// `if (oldPixels == null) page = _pageToUseOnStartup;`）。
  /// 每次 build 传一个新 controller 进来，`Scrollable.didUpdateWidget`
  /// 的 `_shouldUpdatePosition` 比的是 controller 的 **runtimeType**
  /// 而不是身份，新旧都是 `PageController` → position 原地复用，
  /// `initialPage` 根本没人读 → 页面不动，而圆点/按钮却都跟着变了。
  ///
  /// 内容由 `pixels` 驱动、页码由 `_page` 驱动 —— 两个真值源一旦各自
  /// 被写就会失同步。所以现在统一：**只动 controller，`_page` 被动更新**。
  int _page = 0;

  /// PageView 的控制器。
  ///
  /// 必须是 State 字段：`initialPage` 那条路已经证明"每次 new 一个"
  /// 是行不通的，而 `animateToPage` / `nextPage` 需要一个**跨 build
  /// 存活**的对象才能作用在同一个 position 上。
  ///
  /// 由我们自己释放 —— `_PageViewState.dispose` 只在
  /// `widget.controller == null` 时才 dispose 内部 controller
  /// （`page_view.dart:961-962`），我们传了，它就不会管。
  late final PageController _pageCtl;

  bool _installing = false;
  final ToolchainBootstrap _boot = ToolchainBootstrap();

  final FileBrowserBridge _fb = FileBrowserBridge();

  /// 两项权限的当前状态。null = 还没查出来（不要显示成"未开启"，
  /// 那会变成一个假的坏消息）。
  bool? _canInstall;
  bool? _notifyOn;

  @override
  void initState() {
    super.initState();
    _pageCtl = PageController();
    _boot.addListener(_onBootChanged);
    // 监听生命周期：用户去系统设置页开完权限，切回来时要立刻复查。
    // 不复查的话他会看到状态没变，以为开关没生效而反复点。
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageCtl.dispose();
    _boot.removeListener(_onBootChanged);
    _boot.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPermissions();
  }

  /// 复查两项权限（首查 + 从设置页返回时）。
  Future<void> _checkPermissions() async {
    final results = await Future.wait<bool>([
      _fb.canInstallPackages(),
      BuildNotify.enabled,
    ]);
    if (!mounted) return;
    setState(() {
      _canInstall = results[0];
      _notifyOn = results[1];
    });
  }

  void _onBootChanged() {
    if (mounted) setState(() {});
  }

  /// 标记已看过。
  ///
  /// 只在**离开引导页**时调用（走完 / 跳过 / 开始安装后退出），
  /// 不在一进页面就写 —— 否则用户秒退，下次启动就再也看不到引导了。
  Future<void> _markSeen() async {
    if (widget.firstRun) await OnboardingPrefs.markSeen();
  }

  /// 启动全自动安装。
  Future<void> _startInstall(EnvState env) async {
    // 安装权限没开时先确认一次。
    //
    // 只确认**一次**、且只在没开时：这是唯一一项不开就无法交付成果的
    // 权限（构建完装不上 APK，工具链等于白装）。但用户仍然可以选择
    // "我知道，先装工具链" —— 权限随时能在工具链页补，不该被硬拦。
    if (_canInstall == false) {
      final go = await _confirmInstallPermission();
      if (go != true) return; // 用户选择去开权限（或取消），不再往下
    }

    // 先把后端偏好写好。理由见 [_openToolchainManually]。
    await _ensureBackendPref(env);
    if (!mounted) return;

    setState(() {
      _installing = true;
    });
    _boot.env = env.info;
    await _boot.start();
    if (!mounted) return;

    // 一轮结束：成功就标记已看（用户确实完成了这件事）。
    // 失败**不标记** —— 他下次启动还得能看见这个页面才能重试。
    if (_boot.isAllDone) {
      await _markSeen();
      // 让全局环境状态刷新（rootfs 装完后 isInstalled 变了）
      await env.refresh();
    }
  }

  /// 安装权限未开时的确认。
  ///
  /// 返回是否"仍然继续安装"。
  /// 用户选「去开启」时返回 false —— 并**主动跳一次设置页**，别让他
  /// 关掉对话框后还得自己找那个按钮。
  Future<bool?> _confirmInstallPermission() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('还没允许安装应用'),
        content: const Text(
          '工具链装完之后，构建出来的 APK 需要装到手机上才能试。\n'
          '现在没开「安装未知应用」，到时会被系统拦下。\n\n'
          '可以先去开（推荐，几秒钟），也可以先装工具链、之后补。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('先装工具链'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop(false);
              await _fb.openInstallUnknownSources();
            },
            child: const Text('去开启'),
          ),
        ],
      ),
    );
  }

  /// 保证后端偏好已写入。
  ///
  /// ⚠️ 这是必须的：[ToolchainPage] 首次进入时如果读不到后端偏好，
  /// 会弹一个「选后端」对话框且**不选完不进页面内容**
  /// （`toolchain_page.dart` 的 `_initBackendAndRefresh`）。
  /// 引导页如果不先写好，"装完跳过去"的用户会被那个对话框迎面拦住，
  /// 刚建立起来的"一切就绪"感白费。
  ///
  /// 选 proot 而不是 termux：termux 后端是实验性的。
  /// 默认值要和 `BackendPrefs` 一致（proot）。
  Future<void> _ensureBackendPref(EnvState env) async {
    final e = env.info;
    if (e == null) return;
    try {
      final existing = await BackendPrefs.load(e);
      if (existing == null) {
        await BackendPrefs.save(e, BuildBackend.proot);
      }
    } catch (_) {
      // 写不进去也不拦住流程 —— 大不了用户在工具链页选一次
    }
  }

  /// 用户选择手动装：写好后端偏好 → 跳工具链页。
  Future<void> _openToolchainManually(EnvState env) async {
    await _ensureBackendPref(env);
    await _markSeen();
    if (!mounted) return;
    // 用 replace 而不是 push：引导页是一次性的开场白，
    // 用户从工具链页返回时应该落到正常主页，不是又看到引导。
    //
    // 首启场景下 `replace` 会把闸门里的这一页换成工具链页 ——
    // 此时不能调 [onFinish]（那会把闸门切成主页，和刚 push 的
    // 工具链页打架）。用户从工具链页返回时闸门重建成主页，
    // 效果一样，且少一次不必要的重建。
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ToolchainPage()),
    );
  }

  /// 进入主页（跳过 / 看完 / 装完）。
  ///
  /// 两条路：首启时走 [OnboardingPage.onFinish]（闸门切主页），
  /// 从设置页进来时走正常的 `pop`。
  Future<void> _enterHome() async {
    await _markSeen();
    if (!mounted) return;
    if (widget.onFinish != null) {
      widget.onFinish!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  // ============================ 构建 ============================

  @override
  Widget build(BuildContext context) {
    final env = context.watch<EnvState>();

    if (_installing) return _buildInstallView();

    return Scaffold(
      appBar: AppBar(
        // 首次启动不给返回箭头：没有"上一页"可回，给了会让人以为
        // 能退到一个不存在的地方。入口是"跳过"。
        automaticallyImplyLeading: !widget.firstRun,
        title: const Text('欢迎使用', style: TextStyle(fontSize: 16)),
        actions: [
          if (_page < 2)
            TextButton(
              onPressed: _enterHome,
              child: const Text('跳过'),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageCtl,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                _pageIntro(),
                _pageChecklist(),
                _pageStart(env),
              ],
            ),
          ),
          _footer(env),
        ],
      ),
    );
  }

  /// 底部：页码指示 + 主按钮。
  Widget _footer(EnvState env) {
    final c = FoaColors.of(context);
    return Container(
      color: c.panelBg,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page ? c.success : c.muted.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (_page < 2)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                // 驱动 controller 而不是自增 _page。
                //
                // `nextPage` 内部走 `position.animateTo`，翻页完成后
                // PageView 自己的 ScrollNotification 会算出新页码并回调
                // `onPageChanged` → 写回 `_page`。所以这里**不需要**
                // setState：加了就变成两个真值源，又会出现
                // "圆点在动、内容不动"那种失同步。
                //
                // 用带动画的方式而不是 `jumpToPage`：翻页本身就是
                // 一个"移动"的隐喻，300ms 的滑动比瞬间切换更容易理解。
                onPressed: () => _pageCtl.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                ),
                child: const Text('下一步'),
              ),
            )
          else
            Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _startInstall(env),
                    icon: const Icon(Icons.rocket_launch, size: 18),
                    label: const Text('全自动安装'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => _openToolchainManually(env),
                    child: const Text('我手动装（去工具链页）'),
                  ),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _enterHome,
                  child: const Text('先不用，直接进入'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ---------------- 第 1 页：这是什么 ----------------

  Widget _pageIntro() {
    final c = FoaColors.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      children: [
        Center(
          child: Column(
            children: [
              // 用项目自己的图标而不是 Flutter logo —— 后者会让人
              // 以为这是 Flutter 官方 App（同 about_page.dart 的教训）。
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/icon/app_icon.png',
                  width: 76,
                  height: 76,
                  // 资产缺失时不能崩 —— 一个图标不值得让引导页白屏
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.rocket_launch_outlined,
                    size: 60,
                    color: c.success,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(AboutInfo.appName,
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                AboutInfo.tagline,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: c.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _featureCard(
          icon: Icons.shield_outlined,
          title: '不需要 root',
          body: '用 proot 在应用私有目录里跑一个 Debian 容器，'
              '不碰系统分区、不需要解锁 Bootloader。卸载即清理干净。',
        ),
        _featureCard(
          icon: Icons.phone_android,
          title: '在手机上直接出 APK',
          body: '不用电脑、不用数据线。Flutter 编译、Gradle 打包、'
              '安装调试全部在设备内完成。',
        ),
        _featureCard(
          icon: Icons.swap_horiz,
          title: '两套构建后端可切换',
          body: '转译路线（QEMU 转 x64 工具）与原生 arm64 路线可共存、'
              '可切换。工具链页能体检当前哪些还在模拟。',
        ),
        const SizedBox(height: 8),
        Text(
          '下一步会告诉你要下载哪些东西、大概多大。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: c.muted),
        ),
      ],
    );
  }

  Widget _featureCard({
    required IconData icon,
    required String title,
    required String body,
  }) {
    final c = FoaColors.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: c.success),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(body,
                      style: TextStyle(fontSize: 12, height: 1.5, color: c.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 第 2 页：要装什么 ----------------

  Widget _pageChecklist() {
    final c = FoaColors.of(context);
    final total = BootstrapStep.values
        .fold<int>(0, (sum, s) => sum + s.approxBytes);
    final totalGb = (total / (1024 * 1024 * 1024)).toStringAsFixed(1);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      children: [
        const Text('初次使用需要准备这些',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(
          '装一次就行，之后一直可用。总共约 $totalGb GB 下载量。',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: c.muted),
        ),
        const SizedBox(height: 8),
        // 如实提示流量成本。这句不能省 —— 用户可能正用移动网络，
        // 1.5GB 的 Flutter SDK 是他的真金白银。
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: c.warningContainer,
            border: Border.all(color: c.warningBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.wifi, size: 15, color: c.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '建议连上 Wi-Fi 再继续。中途可以暂停重来，已下载的部分不会白费。',
                  style: TextStyle(fontSize: 11.5, height: 1.45, color: c.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final s in BootstrapStep.values) _checklistRow(s),
        const SizedBox(height: 6),
        Text(
          '这些组件的许可与来源都列在「设置 → 关于」里。',
          style: TextStyle(fontSize: 11.5, color: c.muted),
        ),
      ],
    );
  }

  Widget _checklistRow(BootstrapStep s) {
    final c = FoaColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: c.success.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_stepIcon(s), size: 16, color: c.success),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(s.label,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    // 「可选」标记不能省：这一项装不上不影响构建，
                    // 用户有权知道"我可以不管它"。
                    if (s.isOptional)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.muted.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('可选',
                            style: TextStyle(fontSize: 10, color: c.muted)),
                      ),
                    Text(s.sizeLabel,
                        style: TextStyle(fontSize: 11, color: c.muted)),
                  ],
                ),
                const SizedBox(height: 3),
                Text(s.usage,
                    style: TextStyle(fontSize: 11.5, height: 1.4, color: c.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _stepIcon(BootstrapStep s) => switch (s) {
        BootstrapStep.rootfs => Icons.inventory_2_outlined,
        BootstrapStep.jdk => Icons.coffee_outlined,
        BootstrapStep.androidSdk => Icons.android,
        BootstrapStep.flutterSdk => Icons.flutter_dash,
        BootstrapStep.qemu => Icons.swap_horiz,
        BootstrapStep.mirror => Icons.cloud_download_outlined,
        BootstrapStep.native => Icons.memory_outlined,
      };

  // ---------------- 第 3 页：开始 ----------------

  Widget _pageStart(EnvState env) {
    final c = FoaColors.of(context);
    final installed = env.isInstalled;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        const Text('准备好了吗',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(
          installed
              ? '检测到容器已就绪。全自动安装会检查每个组件，'
                  '已装好的会直接跳过，只补缺的。'
              : '全自动安装会依次装完上面 6 项，中途可以取消。'
                  '已经装好的部分不会重复下载。',
          style: TextStyle(fontSize: 12.5, height: 1.6, color: c.muted),
        ),
        const SizedBox(height: 16),
        _permissionCard(),
        const SizedBox(height: 14),
        _authorCard(),
      ],
    );
  }

  /// 权限卡：安装 APK + 通知。
  ///
  /// ## 为什么放在这一页
  ///
  /// 这是「决定装不装」的那一页，而这两项权限**就是工具链能不能交付
  /// 的一部分** —— 只装完工具链、却不能把 APK 装到手机上，等于白装。
  /// 放到第 1、2 页（讲是什么、要装什么）会打断叙事。
  ///
  /// ## 两项权限的"拦不拦路"不一样，是有意的
  ///
  /// - **安装 APK**：不开 → 构建完点「安装」必被系统拦下，核心产出交付不了。
  ///   所以它计入"未完成"，点「全自动安装」前会先确认一次。
  /// - **通知**：不开只是"退到桌面看不见进度"，**构建本身完全正常**。
  ///   拦它是过度打扰，所以只提示、不拦。
  Widget _permissionCard() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _permissionRow(
            icon: Icons.install_mobile_outlined,
            title: '允许安装应用',
            body: '构建出来的 APK 要装到手机上才能试。'
                '不开这个，装的时候会被系统拦下。',
            granted: _canInstall,
            onOpen: () async {
              await _fb.openInstallUnknownSources();
              // 跳过去之后不立刻复查：设置页盖在本页之上，此刻查仍是旧值。
              // 由 didChangeAppLifecycleState 在回来时复查。
            },
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          _permissionRow(
            icon: Icons.notifications_outlined,
            title: '允许发通知',
            body: '退到桌面或锁屏时，还能看到构建进度、点通知直接回来。'
                '(不装也行，构建不受影响)',
            granted: _notifyOn,
            onOpen: () async {
              await BuildNotify.openSettings();
            },
          ),
        ],
      ),
    );
  }

  /// 一行权限。
  ///
  /// [granted] 为 null 时显示"检查中…"——**刻意不显示成"未开启"**：
  /// 那是一个还没查清的事实，显示成坏消息会让用户白白紧张一次。
  Widget _permissionRow({
    required IconData icon,
    required String title,
    required String body,
    required bool? granted,
    required VoidCallback onOpen,
  }) {
    final c = FoaColors.of(context);
    final pending = granted == null;
    final on = granted == true;

    final Color tint = pending
        ? c.muted
        : (on ? c.success : c.warning);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    Icon(
                      pending
                          ? Icons.hourglass_empty
                          : (on ? Icons.check_circle : Icons.error_outline),
                      size: 15,
                      color: tint,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(body,
                    style: TextStyle(fontSize: 11.5, height: 1.45, color: c.muted)),
                // 状态文字不能只靠图标：一个沙漏图标单独摆在那里，
                // 用户分不清是"正在检查"还是"这一项有问题"。
                if (pending) ...[
                  const SizedBox(height: 5),
                  Text('检查中…',
                      style: TextStyle(fontSize: 11, color: c.muted)),
                ],
                if (!pending && !on) ...[
                  const SizedBox(height: 7),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(Icons.settings, size: 14),
                      label: const Text('去开启', style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        foregroundColor: c.warning,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 作者 GitHub —— 可点开浏览器 + 可复制。
  ///
  /// 地址**只能**取 [AboutInfo.authorRepo]，绝不能在这里写字符串。
  /// 仓库用户名曾经被写错过一次（`/haothtrreen` vs `/haothtrteen`），
  /// 而那种错误编译、测试、运行全都不报，只有用户点开发现 404 才知道。
  /// `about_info.dart` 是唯一真源，有单测盯着它和 [AboutInfo.author] 一致。
  Widget _authorCard() {
    final c = FoaColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Icon(Icons.person_outline, size: 18, color: c.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '作者 · ${AboutInfo.author}',
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  // 点击开浏览器
                  InkWell(
                    onTap: _openRepo,
                    child: Text(
                      AboutInfo.authorRepo,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: c.success,
                        decoration: TextDecoration.underline,
                        decorationColor: c.success,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '复制仓库地址',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () async {
                await Clipboard.setData(
                    const ClipboardData(text: AboutInfo.authorRepo));
                if (!mounted) return;
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(const SnackBar(
                    content: Text('仓库地址已复制'),
                    duration: Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ));
              },
            ),
            IconButton(
              tooltip: '用浏览器打开',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_new, size: 16),
              onPressed: _openRepo,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openRepo() async {
    final ok = await launchUrl(
      Uri.parse(AboutInfo.authorRepo),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('打不开浏览器，地址已可复制'),
          duration: Duration(seconds: 2),
        ));
    }
  }

  // ---------------- 安装视图 ----------------

  Widget _buildInstallView() {
    final c = FoaColors.of(context);
    final done = _boot.isAllDone;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(done ? '安装完成' : '正在安装',
            style: const TextStyle(fontSize: 16)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _boot.summary,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text('${_boot.overallPercent}%',
                        style: TextStyle(
                            fontSize: 13,
                            color: c.success,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _boot.overallFraction,
                    minHeight: 6,
                    backgroundColor: c.muted.withValues(alpha: 0.18),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
              children: [
                for (final s in _boot.steps) _installRow(s),
                if (_boot.hasFailure) ...[
                  const SizedBox(height: 10),
                  _failureHint(c),
                ],
              ],
            ),
          ),
          _installFooter(c, done),
        ],
      ),
    );
  }

  Widget _installRow(BootstrapStepState s) {
    final c = FoaColors.of(context);
    final (Widget icon, Color color) = switch (s.status) {
      BootstrapStatus.done => (
          Icon(Icons.check_circle, size: 18, color: c.success),
          c.success
        ),
      BootstrapStatus.failed => (
          Icon(Icons.error_outline, size: 18, color: c.danger),
          c.danger
        ),
      BootstrapStatus.running => (
          const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          c.success
        ),
      BootstrapStatus.skipped => (
          Icon(Icons.remove_circle_outline, size: 18, color: c.muted),
          c.muted
        ),
      BootstrapStatus.idle => (
          Icon(Icons.circle_outlined, size: 18, color: c.muted.withValues(alpha: 0.4)),
          c.muted
        ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: icon,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.step.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: s.status == BootstrapStatus.running
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: s.status == BootstrapStatus.idle ? c.muted : null,
                    )),
                const SizedBox(height: 2),
                Text(
                  s.detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: s.isFailed ? c.danger : c.muted),
                ),
                // 进行中且有下载进度时，给一条细进度条 ——
                // 大文件下载期间"下载中…"三个字挂十几分钟是很糟的反馈。
                if (s.status == BootstrapStatus.running &&
                    s.progress != null) ...[
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: s.progress!.fraction,
                      minHeight: 3,
                      backgroundColor: c.muted.withValues(alpha: 0.15),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _progressText(s.progress!),
                    style: TextStyle(fontSize: 10, color: c.muted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _progressText(DownloadProgress p) {
    String mb(int b) => (b / (1024 * 1024)).toStringAsFixed(1);
    final speed = p.speed > 0 ? ' · ${mb(p.speed.round())} MB/s' : '';
    return '${mb(p.received)} / ${mb(p.total)} MB$speed';
  }

  Widget _failureHint(FoaColors c) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.warningContainer,
        border: Border.all(color: c.warningBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: c.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已装好的部分会保留。可以点「重试」只补失败的那一步，'
              '或者去工具链页手动处理（那里能换镜像、也能从本地文件导入）。',
              style: TextStyle(fontSize: 11.5, height: 1.5, color: c.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _installFooter(FoaColors c, bool done) {
    return Container(
      color: c.panelBg,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        children: [
          if (_boot.isRunning)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _boot.cancel,
                child: const Text('取消'),
              ),
            )
          else if (done)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _enterHome,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('开始使用'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            )
          else ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _boot.retry,
                child: const Text('重试失败的那一步'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () {
                  // 去工具链页：这里**不**标记已看 ——
                  // 用户还没真正装完，下次启动应该还能看到引导。
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(
                        builder: (_) => const ToolchainPage(autoStart: true)),
                  );
                },
                child: const Text('去工具链页手动处理'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
