import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/core/theme.dart';
import 'package:foaide/env/env_installer.dart';
import 'package:foaide/env/models.dart';
import 'package:foaide/ui/home_page.dart';
import 'package:provider/provider.dart';

/// alpha.92：主页三个 tab 在**逐档屏幕宽度**下都不许有布局异常。
///
/// 这组测试是写完这轮 UI 改动后**为了验证才建的**，而它第一次跑就抓到了
/// 两个真问题：
///
/// * **Bug 634a：`Material` 的 `borderRadius` 与 `shape` 互斥。**
///   `_ActionTile` 想同时要圆角和描边，两个都传了 → 运行时断言
///   `!(shape != null && borderRadius != null)`。编译期完全正常，
///   `flutter analyze` 也报不出来，只有真渲染才炸 —— 而且炸的是
///   **六个快捷入口全部变成溢出条纹**，整块区域不可用。
/// * **Bug 634b：`GridView.count` 的 `childAspectRatio` 让格子高度随屏宽浮动。**
///   格子宽 = `(可用宽 - 间距) / 列数`，配 aspectRatio 2.2 时在 360dp 手机上
///   算出 61dp 高，而内容恒定需要约 70dp。从 alpha.60 加进第 6 个入口起
///   就一直差着这点高度。改用 `mainAxisExtent`（高度给定、与宽度无关）后
///   问题从根上消失。
///
/// 为什么用 `FlutterError.onError` 而不是 `tester.takeException()`：
/// 后者在一次测试里只能取到一个异常，而这批问题是**同一帧里六个格子各报一次**
/// —— 只取一个会让"修好一个还剩五个"看起来像通过。
/// 换来的是必须先过滤掉与本次断言无关的异常：本文件只关心渲染期错误，
/// 所以只断言 `caught` 为空，不做分类。
void main() {
  /// 已安装状态的环境信息（让配置页走"就绪"分支、工程页走非空分支）。
  const info = EnvInfo(
    filesDir: '/f',
    cacheDir: '/c',
    nativeLibraryDir: '/n',
    rootfsPath: '/f/rootfs',
    rootfsInstalled: true,
    prootPath: '/f/proot',
    abi: 'arm64-v8a',
    androidSdk: 34,
    device: 'Pixel 7',
  );

  /// 覆盖窄到宽：320（旧小屏 / 分屏）→ 800（平板）。
  /// 320 那一档是刻意留的：`_ActionTile` 的格子在那里最窄，
  /// aspectRatio 时代的溢出就是在这类设备上最先肉眼可见。
  const widths = <(String, double)>[
    ('320dp', 320),
    ('360dp', 360),
    ('412dp', 412),
    ('600dp', 600),
    ('800dp', 800),
  ];

  for (final (label, w) in widths) {
    testWidgets('主页三个 tab 在 $label 宽度下无布局异常', (t) async {
      // 捕获**全部**渲染期错误（takeException 一次只能取一个）。
      final caught = <String>[];
      final prev = FlutterError.onError;
      FlutterError.onError = (d) => caught.add(d.exceptionAsString().split('\n').first);
      addTearDown(() => FlutterError.onError = prev);

      t.view.physicalSize = Size(w * 3, 2280);
      t.view.devicePixelRatio = 3.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);

      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: EnvState()..info = info),
          // 「设置」tab 里有 `Consumer<ThemeController>`，不给会报
          // "Could not find the correct Provider" —— 那是本测试的搭建问题，
          // 不是被测量代码的问题，所以要补上而不是把它排除在断言之外。
          ChangeNotifierProvider(create: (_) => ThemeController()),
        ],
        child: MaterialApp(theme: FoaTheme.dark(), home: const HomePage()),
      ));
      await t.pump(const Duration(milliseconds: 300));

      // 三个 tab 都渲染一遍：只测当前 tab 会漏掉另外两个的布局问题。
      for (final tab in ['配置', '设置', '工程']) {
        await t.tap(find.text(tab));
        // 有界 pump（不用 pumpAndSettle）：工程页的 RefreshIndicator 与
        // 配置页的 CircularProgressIndicator 在测试环境里可能一直有动画，
        // pumpAndSettle 会超时。这与 `editor_auto_sync_test` 里踩过的坑同源。
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));
      }

      expect(caught, isEmpty,
          reason: '$label 下有渲染期异常：\n${caught.join('\n')}');
    });
  }

  testWidgets('六个快捷入口的格子高度与屏幕宽度无关（Bug 634b 的回归）', (t) async {
    // 这条守的是"别再退回 childAspectRatio"。度量断言比截图断言更稳：
    // 它直接说"高度必须是这个数"，而截图会在字体度量变化时抖动。
    for (final w in [320.0, 412.0, 800.0]) {
      t.view.physicalSize = Size(w * 3, 2280);
      t.view.devicePixelRatio = 3.0;
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();

      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: EnvState()..info = info),
          ChangeNotifierProvider(create: (_) => ThemeController()),
        ],
        child: MaterialApp(theme: FoaTheme.dark(), home: const HomePage()),
      ));
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.text('配置'));
      await t.pump(const Duration(milliseconds: 300));

      final grid = t.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.mainAxisExtent, 92,
          reason: '高度必须由 mainAxisExtent 给定；用 childAspectRatio '
              '会让 $w 宽度下的格子高度随屏宽浮动（Bug 634b）');
    }
  });
}
