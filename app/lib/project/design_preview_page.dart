/// 设计预览 · 全屏（alpha.73）。
///
/// ## 它为什么存在
///
/// 原来的「实时预览」是把源码推到容器里跑 `flutter build web`，再拿
/// WebView 打开 —— 真机实测首次编译 1-5 分钟、整轮 10 分钟以上
/// （见 `web_preview_service.dart` 里记的那两个数字）。而且它预览的是
/// **用户写的整份 Dart 源码**，改一个标点就得重来一遍。
///
/// 设计区的预览走的是另一条路：设计树 → **真 Flutter Widget** → 直接
/// build。没有编译、没有进程间通信、没有 WebView，改属性下一帧就变。
/// 代价是它只预览设计器里的东西（设计树 + 导入进来的静态界面），
/// 不跑业务逻辑 —— 但"预览"本来就不该负责跑逻辑。
///
/// ## 两种模式，各答一个问题（alpha.73 拆开）
///
/// | | 模拟模式 | 真机全屏 |
/// |---|---|---|
/// | 回答的问题 | "在 390 宽 / 平板上长什么样" | "在我手上这台机器上长什么样" |
/// | 布局约束 | [SizedBox] 硬锁成模拟尺寸 | 真实屏幕尺寸 |
/// | 屏幕占用 | 设备边框 + FittedBox 等比缩放 | 铺满，一个像素不留 |
/// | 系统栏 | 保持 | `immersiveSticky` 隐藏 |
///
/// 早先只有一个模式：把真机全屏做成了"带边框、带说明条、缩放到放得下"
/// 的模拟画布 —— **那不是全屏**。用户点「全屏」的动机是"把它当成真的
/// 跑起来看看"，而一个四周留白、底下还压着两行说明的画布给不了这个。
///
/// ## 设备尺寸是**真的**改约束，不是缩放
///
/// 用 [SizedBox] 把预览框成 390×844 这种真机尺寸，再套
/// [MediaQuery] 覆盖 `size` —— 这样设计树里任何依赖
/// `MediaQuery.sizeOf` 的布局（比如 [LayoutBuilder]、`Wrap` 的换行点）
/// 表现都和真机一致。缩放一个假的画布做不到这点。
///
/// ⚠️ 真机全屏模式下**不覆盖** `MediaQuery`：那一档的卖点就是"真尺寸"，
/// 覆盖了它就跟模拟模式没区别了（而且两个都覆盖的话，用户在平板模拟
/// 手机尺寸后再进真机全屏，会看到一模一样的画面，"修好了"变成"没变化"）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import 'design_model.dart';
import 'design_page.dart';

/// 可模拟的设备尺寸。
///
/// 不是"随便设几个数"—— 这几档覆盖的是**布局会真的变**的宽度断点：
/// - 360/390：主流手机，窄屏下按钮排不下一行
/// - 600：Material 的 small/medium 分界，`NavigationBar` 开始挤
/// - 768：平板竖屏，两栏布局的起点
/// - 844（横向）：手机横屏，`MediaQuery` 的 orientation 变了
enum PreviewDevice {
  phoneNarrow('小屏手机', 360, 800),
  phone('手机', 390, 844),
  phoneLarge('大屏手机', 430, 932),
  tablet('平板', 768, 1024),
  landscape('手机横屏', 844, 390);

  final String label;
  final double width;
  final double height;

  const PreviewDevice(this.label, this.width, this.height);

  String get sizeLabel => '${width.toInt()}×${height.toInt()}';
}

/// 全屏预览页。
///
/// 拿的是 [DesignPageState] 本体而不是树快照 —— 这样打开全屏后
/// 用户在后面的预览区里改了东西，回到全屏看到的还是最新的。
/// （反过来说，全屏期间不会有人改东西，所以不需要监听刷新。）
class DesignPreviewPage extends StatefulWidget {
  /// 渲染源。用 State 而不是 `DesignNode`，理由见类注释。
  final DesignPageState state;

  /// 进来就进真机全屏。
  ///
  /// 默认 false 而是 true 由调用方决定：预览区那个按钮的 tooltip 是
  /// 「全屏预览」，用户按下去期望的就是全屏，不是"再点一次才全屏"。
  final bool startFullscreen;

  const DesignPreviewPage({
    super.key,
    required this.state,
    this.startFullscreen = false,
  });

  @override
  State<DesignPreviewPage> createState() => _DesignPreviewPageState();
}

class _DesignPreviewPageState extends State<DesignPreviewPage> {
  /// 当前模拟的设备。
  PreviewDevice _device = PreviewDevice.phone;

  /// 当前模拟的主题。
  ThemeMode _themeMode = ThemeMode.light;

  /// 是否把画布缩放到刚好放得下。
  ///
  /// 默认开。390×844 在一台 360×640 的手机上是放不下的，不缩就只能
  /// 滚动看 —— 而"一眼看完一屏"正是打开全屏的动机。
  bool _fit = true;

  /// 真机全屏：铺满整块屏幕、隐藏系统栏。
  late bool _fullscreen = widget.startFullscreen;

  /// 工具栏/设备条在真机全屏下的显隐（点一下屏幕切换，不退出全屏）。
  ///
  /// 为什么不是"真机全屏 = 什么都不显示"：那样用户想切回模拟模式
  /// 就只能按返回键退出整个页面，再重新点进来 —— 一个来回。
  /// 留一个可召唤的浮层，退出全屏只是"再点一下"。
  bool _chromeVisible = false;

  @override
  void initState() {
    super.initState();
    if (_fullscreen) _applyImmersive();
  }

  @override
  void dispose() {
    // ⚠️ 必须还原。用户在全屏状态下直接按返回 / 被系统回收的话，
    // 系统栏会一直是隐藏的，整个 App 的界面都会缺一块 ——
    // 那是一个"退出预览页之后才出现"的 bug，最难查。
    if (_fullscreen) _restoreSystemBars();
    super.dispose();
  }

  /// 隐藏系统栏 + 允许横屏。
  ///
  /// 照着 `lib/editor/web_preview_page.dart` 那套来 —— 全屏这件事
  /// 全 App 只有一个正确做法，两处写出两种行为就是 bug。
  void _applyImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
  }

  void _restoreSystemBars() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  }

  void _setFullscreen(bool on) {
    if (on == _fullscreen) return;
    setState(() {
      _fullscreen = on;
      // 进全屏时工具条默认收起：用户要的是"这是我的界面"，
      // 不是"这是我的界面 + 我的工具条"。
      _chromeVisible = false;
    });
    if (on) {
      _applyImmersive();
    } else {
      _restoreSystemBars();
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = widget.state.currentRoot;

    // 真机全屏：**不套 Theme**。
    //
    // 模拟模式套 `Theme(ThemeData.dark())` 是为了"只让预览框变深色，
    // 不换整个 App 的主题"。但真机全屏下预览框就是整块屏幕，
    // 套一层 Theme 反而会让浮层按钮跟着变深色 —— 而浮层属于
    // 预览页自己的 UI，不该被模拟主题染色。
    if (_fullscreen) return _buildDeviceFullscreen(root);

    return Theme(
      // 深色模拟：**只覆盖预览框内部**，不换整个页面的主题。
      // 换整页的话工具栏也跟着变，用户就分不清"我在看深色预览"
      // 还是"这个 App 被切成深色了"。
      data: _themeMode == ThemeMode.dark
          ? ThemeData.dark(useMaterial3: true)
          : ThemeData.light(useMaterial3: true),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('预览', style: TextStyle(fontSize: 16)),
          actions: [
            IconButton(
              tooltip: '真机全屏（铺满屏幕、隐藏系统栏）',
              icon: const Icon(Icons.fullscreen),
              onPressed: () => _setFullscreen(true),
            ),
            IconButton(
              tooltip: _themeMode == ThemeMode.dark ? '切到浅色' : '切到深色',
              icon: Icon(_themeMode == ThemeMode.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined),
              onPressed: () => setState(() {
                _themeMode = _themeMode == ThemeMode.dark
                    ? ThemeMode.light
                    : ThemeMode.dark;
              }),
            ),
            IconButton(
              tooltip: _fit ? '按原始尺寸显示' : '缩放到放得下',
              icon: Icon(_fit ? Icons.fit_screen_outlined : Icons.crop_free),
              onPressed: () => setState(() => _fit = !_fit),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Column(
          children: [
            _deviceBar(context),
            const Divider(height: 1),
            Expanded(child: _canvas(context, root)),
            _legend(context),
          ],
        ),
      ),
    );
  }

  // ---------------- 真机全屏 ----------------

  /// 铺满整块屏幕的预览。
  ///
  /// 这里**没有** `Scaffold`、没有 AppBar、没有 `SafeArea`、没有
  /// `FittedBox` —— 任何一个都会在屏幕边缘留出空白，而"全覆盖"正是
  /// 这个模式存在的唯一理由。
  ///
  /// 用 `Theme` + `Material` 包住是因为设计树里的 `Text` / `Icon`
  /// 需要 Material 祖先和 `Directionality`，这些在裸 `Widget` 里没有。
  Widget _buildDeviceFullscreen(DesignNode root) {
    final preview = Theme(
      data: _themeMode == ThemeMode.dark
          ? ThemeData.dark(useMaterial3: true)
          : ThemeData.light(useMaterial3: true),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: SizedBox.expand(
          child: root.children.isEmpty
              ? _emptyHint(context)
              : SingleChildScrollView(
                  child: widget.state.renderPreview(root),
                ),
        ),
      ),
    );

    return PopScope(
      // 全屏时按返回键先退出全屏，而不是直接关掉整个预览页 ——
      // 否则用户按一下返回就得从设计区重新进来
      // （和 web_preview_page 对齐：同一个交互，两处必须一样）。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setFullscreen(false);
      },
      child: Scaffold(
        // 不放 AppBar / bottomNavigationBar：它们会占掉屏幕的一部分。
        // 背景用黑色 —— 界面没铺满时（比如用户的界面本身就是个居中的
        // 小卡片），露出来的部分应该是"屏幕外"，而不是我们 App 的背景色。
        backgroundColor: Colors.black,
        body: GestureDetector(
          // 点一下：召唤/收起浮层。
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _chromeVisible = !_chromeVisible),
          child: Stack(
            fit: StackFit.expand,
            children: [
              preview,
              if (_chromeVisible) ...[
                Positioned(
                    left: 12, right: 12, bottom: 12, child: _hud(context)),
                Positioned(right: 12, top: 12, child: _exitButton()),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 真机全屏下召唤出来的浮层：换模拟尺寸 / 切主题 / 退回模拟模式。
  ///
  /// 半透明深色 + 白色文字，**不跟随模拟主题** —— 否则模拟深色主题时
  /// 浮层自己也会变深，在深色界面上就看不见了。
  Widget _hud(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '真机全屏 · 按返回键或右上角退出',
              style:
                  TextStyle(fontSize: 11, color: Colors.white70, height: 1.3),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _hudButton(
                  icon: Icons.dark_mode_outlined,
                  label: _themeMode == ThemeMode.dark ? '浅色' : '深色',
                  onTap: () => setState(() {
                    _themeMode = _themeMode == ThemeMode.dark
                        ? ThemeMode.light
                        : ThemeMode.dark;
                  }),
                ),
                const SizedBox(width: 8),
                _hudButton(
                  icon: Icons.straighten,
                  label: '按 ${_device.sizeLabel} 模拟',
                  onTap: () => _setFullscreen(false),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _hudButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(fontSize: 11.5, color: Colors.white)),
          ],
        ),
      ),
    );
  }

  Widget _exitButton() {
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _setFullscreen(false),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.fullscreen_exit, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  Widget _emptyHint(BuildContext context) {
    final c = FoaColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '设计还是空的\n\n回设计区套个模板或加几个组件',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, height: 1.6, color: c.muted),
        ),
      ),
    );
  }

  // ---------------- 模拟模式 ----------------

  /// 顶部设备选择条。
  Widget _deviceBar(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          for (final d in PreviewDevice.values) ...[
            _chip(
              context,
              label: '${d.label}  ${d.sizeLabel}',
              active: d == _device,
              onTap: () => setState(() => _device = d),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required String label,
      required bool active,
      required VoidCallback onTap}) {
    final c = FoaColors.of(context);
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? cs.primaryContainer : c.panelBg,
          border: Border.all(
              color: active ? cs.primary : cs.outlineVariant,
              width: active ? 1.4 : 1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            color: active ? cs.onPrimaryContainer : c.muted,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  /// 画布：设备边框 + 真尺寸约束 + 真的设计树。
  Widget _canvas(BuildContext context, DesignNode root) {
    final cs = Theme.of(context).colorScheme;
    final device = SizedBox(
      width: _device.width,
      height: _device.height,
      child: MediaQuery(
        // 覆盖 size 是这里的**全部意义**：设计树里 `LayoutBuilder`、
        // `MediaQuery.sizeOf(context).width >= 720` 这类判断拿到的
        // 必须是模拟设备的尺寸，不是真机的。少了这一层，"模拟平板"
        // 就只是个被拉宽的小框，断点逻辑根本不会触发。
        data: MediaQuery.of(context).copyWith(
          size: Size(_device.width, _device.height),
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.zero,
          viewInsets: EdgeInsets.zero,
        ),
        // 用 Material 兜底：设计树里可能有 Text/Icon 落在没有
        // Material 祖先的位置（全屏页不是 Scaffold 的 body 子级
        // 那种天然环境），会报 "No Material widget found"。
        child: Material(
          color: cs.surface,
          child: ClipRect(
            child: root.children.isEmpty
                ? _emptyHint(context)
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(0),
                    child: widget.state.renderPreview(root),
                  ),
          ),
        ),
      ),
    );

    final framed = Container(
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant, width: 1.5),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: device,
    );

    if (!_fit) {
      // 原始尺寸：可能比屏幕大，允许双向滚动。
      return InteractiveViewer(
        minScale: 0.2,
        maxScale: 2.5,
        constrained: false,
        boundaryMargin: const EdgeInsets.all(80),
        child: Padding(padding: const EdgeInsets.all(20), child: framed),
      );
    }

    // 缩放到放得下：FittedBox 会**等比**缩，所以比例不会骗人
    // （拉扁的预览比不预览更糟）。
    return Padding(
      padding: const EdgeInsets.all(16),
      child: FittedBox(
        fit: BoxFit.contain,
        child: framed,
      ),
    );
  }

  /// 底部说明：当前在模拟什么，以及"为什么和真机不完全一样"。
  Widget _legend(BuildContext context) {
    final c = FoaColors.of(context);
    return Container(
      width: double.infinity,
      color: c.panelBg,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 13, color: c.muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '模拟 ${_device.label}（${_device.sizeLabel}）· '
                  '${_themeMode == ThemeMode.dark ? "深色" : "浅色"}主题',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '只渲染界面，不跑业务逻辑（点击、网络、路由都不会有反应）',
            style: TextStyle(fontSize: 10.5, color: c.muted),
          ),
        ],
      ),
    );
  }
}

/// 打开全屏预览。
///
/// [fullscreen] 为 true 时**进来就是真机全屏**（铺满屏幕、隐藏系统栏）——
/// 设计区那个按钮的 tooltip 写的是「全屏预览」，用户按下去期望的
/// 就是全屏本身，不该再让他多点一次。
///
/// 独立函数而不是 `DesignPageState` 的方法：调用方需要的就是
/// "打开一个页面"，`Navigator.push` 的细节不该被 State 关心。
Future<void> showFullscreenPreview(
  BuildContext context, {
  required DesignPageState state,
  bool fullscreen = true,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DesignPreviewPage(
        state: state,
        startFullscreen: fullscreen,
      ),
    ),
  );
}
