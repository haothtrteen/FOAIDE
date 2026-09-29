import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/core/theme.dart';

/// Bug 457：浅色主题下顶栏与状态栏颜色不一致。
///
/// 成因链条（三处叠加）：
/// 1. `FoaTheme.light()` 把 `statusBarColor` 设为 `Colors.transparent`；
/// 2. AppBar 背景也是 transparent → 透出 Android **窗口背景**
///    （`res/values/colors.xml` 的 `foa_bg = #101418` 深色）；
/// 3. `main.dart` 里硬编码了一份深色 overlay，任何主题下都生效。
///
/// 结果：浅色顶栏下面压着一条深色状态栏。
///
/// 这组测试守住的是"**同一个颜色值被写在 4 个地方，必须同源**"这个约束——
/// 单测无法验证真机渲染，但可以拦住"改了 Dart 忘了改 Kotlin/XML"这类
/// 最容易复发的失误。
void main() {
  // alpha.92：浅色值由 #F5F7F8 改为 #FBFCFD。
  // 原因见 `FoaTheme.lightSurface` 的注释 —— Bug 457 只对齐了
  // "状态栏 vs 顶栏"，顶栏当时是 transparent、透出的是 `surface`
  // （浅色下带绿调的 #F6FBF3），于是顶部仍有三段色。
  // 现在三色统一到 panelBg，这个常量必须跟着走。
  const darkHex = 0xFF14181E;
  const lightHex = 0xFFFBFCFD;

  group('Dart 侧主题常量', () {
    test('浅色主题状态栏必须是实色，不能是 transparent', () {
      final style = FoaTheme.light()
          .appBarTheme
          .systemOverlayStyle!;
      expect(style.statusBarColor, isNotNull,
          reason: 'null/transparent 会透出窗口背景，重新引入 Bug 457');
      expect(style.statusBarColor, isNot(Colors.transparent),
          reason: 'transparent 是 Bug 457 的直接成因');
      expect(style.statusBarColor!.toARGB32(), equals(lightHex));
    });

    test('浅色主题状态栏图标为深色（压在浅底上要看得见）', () {
      final style = FoaTheme.light().appBarTheme.systemOverlayStyle!;
      expect(style.statusBarIconBrightness, Brightness.dark);
    });

    test('深色主题状态栏跟随 panelBg + 浅色图标', () {
      final style = FoaTheme.dark().appBarTheme.systemOverlayStyle!;
      expect(style.statusBarColor!.toARGB32(), equals(darkHex));
      expect(style.statusBarIconBrightness, Brightness.light);
    });

    test('overlayFor 与两个主题的 AppBar overlay 取值一致', () {
      final dark = FoaTheme.overlayFor(Brightness.dark);
      final light = FoaTheme.overlayFor(Brightness.light);
      expect(dark.statusBarColor, FoaTheme.dark().appBarTheme.systemOverlayStyle!.statusBarColor);
      expect(light.statusBarColor, FoaTheme.light().appBarTheme.systemOverlayStyle!.statusBarColor);
      expect(dark.statusBarColor!.toARGB32(), equals(darkHex));
      expect(light.statusBarColor!.toARGB32(), equals(lightHex));
    });

    test('浅色主题导航栏也已适配（同一割裂问题的另一半）', () {
      final style = FoaTheme.light().appBarTheme.systemOverlayStyle!;
      expect(style.systemNavigationBarColor!.toARGB32(), equals(lightHex));
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
    });
  });

  group('跨文件颜色同源（Dart ↔ Kotlin ↔ XML）', () {
    // 相对 app/ 根定位（flutter test 的工作目录即包根）
    File f(String rel) => File(rel);

    // XML 里颜色是 #AARRGGBB（带 alpha FF 前缀），Dart 常量是 0xFFRRGGBB。
    // 比对时统一去掉 alpha：只校验 RGB 主体，避免因写法差异误报。
    String rgb(int argb) =>
        (argb & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0');

    test('values/colors.xml 同时声明深色与浅色两个值', () {
      final xml = f('android/app/src/main/res/values/colors.xml');
      expect(xml.existsSync(), isTrue, reason: '颜色资源文件应存在');
      final t = xml.readAsStringSync().toUpperCase();
      // alpha.92：foa_bg 是**窗口背景**（= FoaTheme.bg 的 #101418），
      // foa_bg_light 是浅色的窗口/系统栏底（= lightSurface）。两者不同源是
      // 刻意的 —— 深色的窗口背景与顶栏差 2.5% 亮度，浅色则同值
      // （浅色下顶栏底下没有"浮起的一块"，同值更干净）。
      expect(t.contains(rgb(0xFF101418)), isTrue,
          reason: 'foa_bg 应为 #FF101418（= FoaTheme.bg，窗口背景）');
      expect(t.contains(rgb(lightHex)), isTrue,
          reason: 'foa_bg_light 应为 lightHex（浅色窗口/系统栏底）');
    });

    test('浅色 styles.xml 用浅色值、night 用深色值', () {
      final light =
          f('android/app/src/main/res/values/styles.xml').readAsStringSync();
      final night =
          f('android/app/src/main/res/values-night/styles.xml').readAsStringSync();
      // 浅色侧：windowBackground / 系统栏都指向 foa_bg_light
      expect(light.contains('foa_bg_light'), isTrue,
          reason: '浅色窗口背景必须是浅色，否则透明状态栏透出深色底');
      expect(light.contains('@color/foa_bg"'), isFalse,
          reason: '浅色 styles 不应直接引用深色 foa_bg');
      // 深色侧：仍是深色
      expect(night.contains('@color/foa_bg'), isTrue);
    });

    test('Kotlin 兜底颜色与 Dart 常量一致', () {
      final kt = f(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      // alpha.92：Kotlin 兜底的目标值从 `FoaTheme.bg` 改成 `FoaTheme.panelBg`
      // —— 它设的是**系统栏**色，而系统栏现在与顶栏同色（panelBg）。
      expect(kt.contains('0xFF14181E.toInt()'), isTrue,
          reason: 'Kotlin 深色兜底应含 0xFF14181E（与 panelBg(dark) 同源）');
      expect(kt.contains('0xFFFBFCFD.toInt()'), isTrue,
          reason: 'Kotlin 浅色兜底应含 0xFFFBFCFD（与 lightSurface 同源）');
      expect(kt.contains('0xFFF5F7F8'), isFalse,
          reason: '0xFFF5F7F8 是 alpha.92 之前的浅色值，改漏了会与顶栏分叉');
    });

    test('main.dart 不再硬编码深色 overlay（改走 FoaTheme.overlayFor）', () {
      final main = f('lib/main.dart').readAsStringSync();
      expect(main.contains('FoaTheme.overlayFor'), isTrue,
          reason: '启动基线必须跟随主题');
      // 旧写法：裸 SystemUiOverlayStyle(... statusBarColor: Color(0xFF101418)
      expect(
        RegExp(r'SystemChrome\.setSystemUIOverlayStyle\(\s*const SystemUiOverlayStyle')
            .hasMatch(main),
        isFalse,
        reason: 'main.dart 曾硬编码深色 overlay，导致浅色主题下不一致',
      );
    });
  });

  group('FileProvider authority 动态化（不写死包名）', () {
    test('Kotlin 用 packageName 推导 authority', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      expect(kt.contains(r'get() = "$packageName$FILE_PROVIDER_SUFFIX"'), isTrue,
          reason: 'authority 必须从真实包名推导，避免改包名后崩在安装');
      expect(
        kt.contains('getUriForFile(this, "dev.foa.flutter_on_android.fileprovider"'),
        isFalse,
        reason: '不应再出现写死的完整 authority 字符串',
      );
    });

    test(r'Manifest 用 ${applicationId} 占位符', () {
      final mf = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(mf.contains(r'android:authorities="${applicationId}.fileprovider"'),
          isTrue);
      expect(mf.contains('authorities="dev.foa.flutter_on_android.fileprovider"'),
          isFalse,
          reason: '写死包名会在改 applicationId 后与 Kotlin 侧不一致');
    });

    test('platform/android 模板副本同样已修正（防把坑复制进用户项目）', () {
      final mf = File('platform/android/AndroidManifest.xml').readAsStringSync();
      final kt = File('platform/android/MainActivity.kt').readAsStringSync();
      expect(mf.contains(r'android:authorities="${applicationId}.fileprovider"'),
          isTrue,
          reason: '模板目录会被拷进新项目，必须与主工程同源');
      expect(kt.contains('getUriForFile(this, fileProviderAuthority, f)'), isTrue);
    });
  });
}
