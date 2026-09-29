import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/theme.dart';
import '../env/proot_bridge.dart';
import 'web_preview_service.dart';

/// Web 实时预览控制台页（alpha.57 引入，alpha.58 内嵌 WebView）。
///
/// 薄视图：会话全部在全局单例 [WebPreviewService]，本页只渲染状态 +
/// 提供操作按钮。退出页面预览照跑（前台服务保活），重进无缝挂回。
///
/// 视图（alpha.58）：running 时用 **IndexedStack 内嵌 WebView 直接加载
/// 预览页**——不切系统浏览器；WebView 常驻保活，dwds 的 WebSocket
/// 连接不断，热重载时页面即时自动刷新（「保持浏览器会话」）。
/// 切到日志 tab 看编译/重载输出；系统浏览器入口保留。
///
/// cleartext：targetSdk 28 默认禁明文 HTTP——manifest 的
/// networkSecurityConfig（res/xml/network_security_config.xml）精确放行
/// 127.0.0.1/localhost，WebView 才能加载 http 预览地址。
class WebPreviewPage extends StatefulWidget {
  /// 项目根（容器内路径，编辑器页已解析好）。
  final String projectRoot;

  /// 进入即自动启动（idle 状态时）；从运行中会话挂回时为 false。
  final bool autoStart;

  const WebPreviewPage({
    super.key,
    required this.projectRoot,
    this.autoStart = true,
  });

  @override
  State<WebPreviewPage> createState() => _WebPreviewPageState();
}

class _WebPreviewPageState extends State<WebPreviewPage> {
  WebPreviewService get s => WebPreviewService.I;
  final ProotBridge _bridge = ProotBridge();
  final ScrollController _scroll = ScrollController();
  bool _autoScroll = true;
  bool _starting = false;

  // ---- alpha.58 内嵌 WebView ----
  WebViewController? _web;
  int _view = 0; // 0=预览（WebView） 1=日志

  // ---- alpha.61 全屏 ----
  /// 全屏：隐藏 AppBar/状态卡/底部按钮，仅留一个浮动的退出按钮。
  /// 只作用于**预览视图**（日志视图全屏没有意义）。
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom = _scroll.offset >= _scroll.position.maxScrollExtent - 24;
      if (atBottom != _autoScroll) {
        setState(() => _autoScroll = atBottom);
      }
    });
    // 挂回：预览可能在后台跑着（切走再回来自动续显）
    s.onUiChanged = () {
      if (mounted) setState(() {});
    };
    s.onAutoScroll = () {
      if (_autoScroll) _scrollToBottom();
    };
    if (widget.autoStart && s.status == WebPreviewStatus.idle && !s.busy) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    // 只解绑 UI 钩子——预览继续跑（前台服务保活）
    s.onUiChanged = null;
    s.onAutoScroll = null;
    // 全屏状态下直接退出页面：必须恢复系统栏，否则会带着沉浸状态回到别的页
    if (_fullscreen) _restoreSystemBars();
    _scroll.dispose();
    super.dispose();
  }

  /// 进入/退出全屏。
  ///
  /// 全屏时隐藏系统 UI（沉浸式边缘到边缘）并允许横屏——Web 预览多数是
  /// 页面型内容，横屏能多看到一倍宽度；退出时把方向锁回竖屏，
  /// 否则从预览返回后整个 App 会停在横屏。
  void _setFullscreen(bool on) {
    setState(() => _fullscreen = on);
    if (on) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
      ]);
    } else {
      _restoreSystemBars();
    }
  }

  void _restoreSystemBars() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  /// running 状态下确保 WebView 已创建并加载预览地址。
  /// 服务器常驻 → 重复 loadRequest 也只是快速重载（DDC 产物在内存）。
  void _ensureWebView() {
    if (_web != null) return;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          final uri = Uri.tryParse(req.url);
          final host = uri?.host ?? '';
          // 只在 WebView 内放行本机预览地址；其余链接交系统浏览器
          if (host == '127.0.0.1' || host == 'localhost') {
            return NavigationDecision.navigate;
          }
          if (req.url.startsWith('http')) {
            launchUrl(Uri.parse(req.url), mode: LaunchMode.externalApplication);
          }
          return NavigationDecision.prevent;
        },
      ));
    c.loadRequest(Uri.parse(WebPreviewService.url));
    _web = c;
  }

  Future<void> _start() async {
    if (s.busy || _starting) return;
    setState(() => _starting = true);
    try {
      final env = await _bridge.envInfo();
      if (!mounted) return;
      if (!env.rootfsInstalled) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('容器环境未就绪：请先完成环境安装'),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      final name = widget.projectRoot.split('/').last;
      final err = await s.start(name, env);
      if (!mounted) return;
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(err),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('启动失败：$e'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _openBrowser() async {
    final ok = await launchUrl(
      Uri.parse(WebPreviewService.url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('无法打开浏览器'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _reload(bool restart) async {
    final err = restart ? await s.hotRestart() : await s.hotReload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err ?? (restart ? '已触发热重启' : '已触发热重载')),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _stop() async {
    await s.stop();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('预览已停止'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final running = s.status == WebPreviewStatus.running;
    if (running) _ensureWebView();

    // 全屏只对预览视图有意义：日志在全屏里反而是灾难
    final full = _fullscreen && running && _view == 0;

    final body = Column(
      children: [
        if (!full) ...[
          _statusCard(),
          const Divider(height: 1),
        ],
        Expanded(
          child: running
              // IndexedStack 保活：WebView 常驻（dwds WebSocket 不断，
              // 热重载即时推送到页面），切日志 tab 不销毁预览
              ? IndexedStack(
                  index: _view,
                  children: [
                    Stack(
                      children: [
                        _webViewPane(),
                        // 全屏时唯一的操作入口：浮动退出按钮
                        if (full)
                          Positioned(
                            right: 12,
                            top: 12,
                            child: _exitFullscreenButton(),
                          ),
                      ],
                    ),
                    _logView(),
                  ],
                )
              : _logView(),
        ),
      ],
    );

    return PopScope(
      // 全屏时按返回键先退出全屏，而不是直接退出页面——
      // 否则用户按一下返回就把预览页关了，得重新进来
      canPop: !full,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && full) _setFullscreen(false);
      },
      child: Scaffold(
        // 全屏时连 AppBar 一起去掉，让 WebView 顶到状态栏
        appBar: full
            ? null
            : AppBar(
                title: const Text('实时运行预览（Web）'),
                actions: [
                  if (running && _view == 0)
                    IconButton(
                      tooltip: '全屏',
                      onPressed: () => _setFullscreen(true),
                      icon: const Icon(Icons.fullscreen),
                    ),
                ],
              ),
        body: SafeArea(
          // 全屏时不要 SafeArea 内边距，否则刘海/手势条会留白
          top: !full,
          bottom: !full,
          left: !full,
          right: !full,
          child: body,
        ),
        // 运行中主操作（热重载）放底部大按钮——核心高频动作。
        // 全屏时隐藏（要沉浸就别塞按钮，退出全屏后有）。
        bottomNavigationBar: (running && !full)
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: () => _reload(false),
                    icon: const Icon(Icons.flash_on),
                    label: const Text('热重载（保存的代码即时生效）'),
                  ),
                ),
              )
            : null,
      ),
    );
  }

  /// 全屏下的浮动退出按钮（半透明、贴右上角，不挡内容）。
  Widget _exitFullscreenButton() {
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

  // ---------------- 状态卡 ----------------

  Widget _statusCard() {
    final st = s.status;
    // Bug 454（alpha.60）：starting 不再是笼统的「编译中…」，而是按真实
    // 阶段显示（端口是否已通）。UI 不撒谎——这是本次修复的核心教训。
    final startingText = WebPreviewService.stageLabel(
        portOpen: s.portOpen, elapsedSec: s.elapsedSec);
    final (icon, color, text) = switch (st) {
      WebPreviewStatus.idle => (Icons.stop_circle_outlined, Colors.grey, '未启动'),
      WebPreviewStatus.starting => (
          Icons.hourglass_top,
          const Color(0xFFFFA000),
          startingText
        ),
      WebPreviewStatus.running => (
          Icons.check_circle,
          const Color(0xFF3DDC84),
          '运行中'
        ),
      WebPreviewStatus.error => (
          Icons.error_outline,
          const Color(0xFFCF6679),
          '已退出'
        ),
    };
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(text,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (s.busy || st == WebPreviewStatus.error)
                  Text('已运行 ${WebPreviewService.fmtDur(s.elapsedSec)}',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted)),
              ],
            ),
            // 进度条真实化（Bug 454）：准备中 30% / 已监听待编译 70% / 就绪 100%
            if (st == WebPreviewStatus.starting) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: s.portOpen ? 0.7 : 0.3,
                minHeight: 4,
                backgroundColor: Colors.white12,
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '项目：${s.projName ?? widget.projectRoot.split('/').last}'
              ' · ${WebPreviewService.url}',
              style:
                  TextStyle(fontSize: 12, color: FoaColors.of(context).muted),
            ),
            if (s.error != null) ...[
              const SizedBox(height: 4),
              Text('错误：${s.error}',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFFCF6679))),
            ],
            const SizedBox(height: 10),
            _actions(st),
          ],
        ),
      ),
    );
  }

  Widget _actions(WebPreviewStatus st) {
    final running = st == WebPreviewStatus.running;
    final children = <Widget>[
      if (running) ...[
        // 预览/日志视图切换（IndexedStack 保活，互不销毁）
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
                value: 0, icon: Icon(Icons.web, size: 18), label: Text('预览')),
            ButtonSegment(
                value: 1,
                icon: Icon(Icons.terminal, size: 18),
                label: Text('日志')),
          ],
          selected: {_view},
          onSelectionChanged: (sel) => setState(() => _view = sel.first),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: '重载页面',
          onPressed: () => _web?.reload(),
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '在系统浏览器打开',
          onPressed: _openBrowser,
          icon: const Icon(Icons.open_in_browser),
        ),
        IconButton(
          tooltip: '热重启（改了 main()/全局状态用）',
          onPressed: () => _reload(true),
          icon: const Icon(Icons.restart_alt),
        ),
        IconButton(
          tooltip: '停止预览',
          onPressed: _stop,
          icon: const Icon(Icons.stop),
        ),
      ] else if (st == WebPreviewStatus.starting) ...[
        OutlinedButton.icon(
          onPressed: _stop,
          icon: const Icon(Icons.stop, size: 18),
          label: const Text('停止'),
        ),
        const SizedBox(width: 8),
        // Bug 454：编译期也允许开系统浏览器——端口固定 8090，编译没完
        // 也能打开（dwds 会给加载页），比干等一个不确定的时间强。
        if (s.portOpen)
          OutlinedButton.icon(
            onPressed: _openBrowser,
            icon: const Icon(Icons.open_in_browser, size: 18),
            label: const Text('系统浏览器打开'),
          ),
        const SizedBox(width: 8),
        Text(
          s.portOpen ? '就绪后自动进入内嵌预览' : '服务器起来后即可打开',
          style: TextStyle(fontSize: 12, color: FoaColors.of(context).muted),
        ),
      ] else ...[
        FilledButton.icon(
          onPressed: _starting ? null : _start,
          icon: const Icon(Icons.play_circle_outline),
          label: Text(st == WebPreviewStatus.error ? '重新启动' : '启动预览'),
        ),
      ],
    ];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0,
      runSpacing: 8,
      children: children,
    );
  }

  // ---------------- 内嵌 WebView 预览 ----------------

  Widget _webViewPane() {
    final web = _web;
    if (web == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return WebViewWidget(
        key: const ValueKey('foa_web_preview'), controller: web);
  }

  // ---------------- 日志区 ----------------

  Widget _logView() {
    return Container(
      // alpha.69：日志区原本固定 `FoaTheme.consoleBg` 深色，
      // 浅色主题下整块日志是黑的。改走语义位（深色值不变）。
      color: FoaColors.of(context).codeBg,
      child: s.lines.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.web, size: 56, color: Colors.grey.shade700),
                  const SizedBox(height: 12),
                  Text(
                    '以 web 形式在后台运行项目，\n'
                    '改代码 → 热重载，省去反复出包',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: FoaColors.of(context).muted),
                  ),
                ],
              ),
            )
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: s.lines.length,
              itemBuilder: (ctx, i) => Text(
                s.lines[i],
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                  color: Color(0xFFCAD3D5),
                ),
              ),
            ),
    );
  }
}
