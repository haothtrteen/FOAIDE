import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'editor/web_preview_page.dart';
import 'editor/web_preview_service.dart';
import 'env/env_installer.dart';
import 'env/proot_bridge.dart';
import 'events/native_events.dart';
import 'mcp/remote_takeover_page.dart';
import 'toolchain/build_notify.dart';
import 'toolchain/build_page.dart';
import 'ui/onboarding_gate.dart';

/// 全局导航钥匙：通知点击回构建页（BuildNotify.onNavigate）用，
/// BuildRunner 与通知路径不持有 BuildContext，只能走根 navigator。
final GlobalKey<NavigatorState> foaNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动基线系统栏（Bug 457：跟随**当前主题**，不再硬编码深色）。
  // 之前这里写死深色 overlay，导致浅色主题下状态栏与顶栏割裂——
  // 主题切换时的实时跟随由下方 builder 负责，此处只是首帧前的兜底。
  //
  // Bug 410（2026-09-17 真机确认）：Flutter 引擎在 Android 15+ 设备
  // （SDK_INT>=35，与 targetSdk 无关）上会跳过 setStatusBarColor/
  // setNavigationBarColor——运行时设色在这类设备上无效，系统栏颜色由主题
  // XML 声明兜底（styles.xml 的 android:statusBarColor/navigationBarColor）。
  // 主题切换时 AppBarTheme.systemOverlayStyle 负责各版本的图标明暗。
  final initialBrightness = WidgetsBinding
      .instance.platformDispatcher.platformBrightness;
  SystemChrome.setSystemUIOverlayStyle(FoaTheme.overlayFor(initialBrightness));
  runApp(const FoaApp());
}

class FoaApp extends StatefulWidget {
  const FoaApp({super.key});

  @override
  State<FoaApp> createState() => _FoaAppState();
}

class _FoaAppState extends State<FoaApp> {
  @override
  void initState() {
    super.initState();
    // alpha.31 构建通知：点通知回构建页。
    // 两条路径：① App 前台，原生 onNewIntent 反向 invoke「navigate」；
    // ② 冷启动点通知，Dart handler 未注册时原生先存 pendingNavigate，
    //    这里首帧后主动拉取一次（takeNavigate）。
    //
    // alpha.91：反向 handler 统一由 NativeEvents 注册（全项目唯一一处
    // setMethodCallHandler）。此前是 BuildNotify.ensureHandler 自己注册，
    // 现在新增了 fsChange（文件变更推送），同一个通道再注册第二个 handler
    // 会把 navigate 静默顶掉 —— 详见 native_events.dart 类注释。
    NativeEvents.ensureHandler();
    // alpha.59：通知点击按最近启动的前台任务分流（构建页 / Web 预览控制台）
    BuildNotify.onNavigate = _openNotifyTarget;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (await BuildNotify.takePendingNavigate()) _openNotifyTarget();
    });
  }

  void _openNotifyTarget() {
    // 按「最近启动的任务」分流（原生回发不带类别，见 BuildNotify.lastRoute）：
    // - preview  → Web 预览控制台（项目根由会话单例还原）
    // - takeover → 远程协助页（MCP + 隧道状态）
    // - 其余     → 构建页（含冷启动兜底：会话不在了也回构建页看日志）
    if (BuildNotify.lastRoute == 'preview') {
      final proj = WebPreviewService.I.projName;
      if (proj != null && proj.isNotEmpty && WebPreviewService.I.busy) {
        foaNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => WebPreviewPage(projectRoot: '/root/projects/$proj'),
          ),
        );
        return;
      }
    }
    if (BuildNotify.lastRoute == 'takeover') {
      final proj = WebPreviewService.I.projName;
      foaNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => RemoteTakeoverPage(
            projectName: (proj != null && proj.isNotEmpty) ? proj : null,
          ),
        ),
      );
      return;
    }
    foaNavigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => const BuildPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => EnvState()..bootstrap()),
        // alpha.69：主题默认跟随系统，用户改过的选择由 ThemePrefs 持久化。
        // `..load()` 异步补齐（构造时已是 system），不阻塞首帧 ——
        // 详见 ThemeController.load 的注释。
        ChangeNotifierProvider(create: (_) => ThemeController()..load()),
      ],
      child: Consumer<ThemeController>(
        builder: (context, tc, _) => MaterialApp(
          navigatorKey: foaNavigatorKey,
          title: 'FOAIDE',
          debugShowCheckedModeBanner: false,
          theme: FoaTheme.light(),
          darkTheme: FoaTheme.dark(),
          themeMode: tc.mode,
          // Bug 457：主题一变，系统栏立刻跟随（浅色→深色图标+浅底实色；
          // 深色→浅色图标+深底）。不这样做的话，切主题后系统栏会停留在
          // 上一次的状态，直到某个 AppBar 重新下发 systemOverlayStyle。
          builder: (context, child) {
            final dark = Theme.of(context).brightness == Brightness.dark;
            // Bug 464：Android 15+ 引擎会跳过运行时设色，Dart 侧
            // AnnotatedRegion 在那类设备上不生效——必须把**真实亮度**
            // 推给原生由 Kotlin 设色。这里是最合适的唯一推点：
            // builder 每次主题变化都会重建，且此处已算出 dark。
            // 放到 postFrame 回调里，避免在 build 期间触发平台调用。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              ProotBridge().syncSystemBarTheme(dark: dark);
            });
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: FoaTheme.overlayFor(
                  dark ? Brightness.dark : Brightness.light),
              child: child ?? const SizedBox.shrink(),
            );
          },
          // alpha.72：home 从 HomePage 换成 OnboardingGate ——
          // 首启先判定「这一版引导看过没有」，没看过就显示引导页。
          // 判定本身异步走平台通道，但**不阻塞首帧**（闸门先渲染一个
          // 与主页同底色的占位，首帧后才去读标记文件）——
          // 详见 onboarding_gate.dart 的类注释。
          home: const OnboardingGate(),
        ),
      ),
    );
  }
}
