import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/core/theme.dart';
import 'package:foaide/mcp/cloudflared_install.dart';
import 'package:foaide/toolchain/sdk_downloader.dart';

/// Bug 464：三件事一起修——
/// ① 顶栏与状态栏颜色不同步（Android 15+ 上 Dart 侧设色失效，
///    而 Kotlin 兜底读的是**系统**主题，与 App 主题可不一致）；
/// ② 部分 UI 控件硬编码颜色，切主题后对比度错误；
/// ③ cloudflared 下载失败无法定位（失败原因在 `_probe` 里被吞掉）。
///
/// （原本还有第 ④ 条「proroot 一键拉取」，已随 proroot 功能整体移除而删除。）
///
/// 这组测试守的是**契约**：颜色必须同源、下载源必须 arm64 且带校验。
/// 单测验不了真机渲染，但能拦住"改了 Dart 忘了同步 Kotlin / 忘了同步模板"
/// 这类高复发失误。
void main() {
  // ---------------- ① 主题 → 系统栏同步 ----------------

  group('Bug 464 · 主题同步契约', () {
    // alpha.92：系统栏改用 panelBg（深色 #14181E / 浅色 #FBFCFD），
    // 与 AppBar 背景同源 —— 详见 `FoaTheme.overlayFor` 的注释。
    const darkHex = 0xFF14181E;
    const lightHex = 0xFFFBFCFD;

    test('overlayFor 深色：状态栏与导航栏同色且为深底', () {
      final s = FoaTheme.overlayFor(Brightness.dark);
      expect(s.statusBarColor!.toARGB32(), darkHex);
      expect(s.systemNavigationBarColor!.toARGB32(), darkHex);
      expect(s.statusBarIconBrightness, Brightness.light,
          reason: '深底要配浅色图标');
    });

    test('overlayFor 浅色：状态栏与导航栏同色且为浅底', () {
      final s = FoaTheme.overlayFor(Brightness.light);
      expect(s.statusBarColor!.toARGB32(), lightHex);
      expect(s.systemNavigationBarColor!.toARGB32(), lightHex);
      expect(s.statusBarIconBrightness, Brightness.dark,
          reason: '浅底要配深色图标');
    });

    test('Dart 侧与 Kotlin 兜底用**同一组颜色值**（改一处必须改两处）', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      // applySystemBarColors 里的两个字面量必须与 Dart 侧一致
      expect(kt.contains('0xFF14181E.toInt()'), isTrue,
          reason: 'Kotlin 兜底缺深色值——Android 15+ 上系统栏会回落默认色');
      expect(kt.contains('0xFFFBFCFD.toInt()'), isTrue,
          reason: 'Kotlin 兜底缺浅色值');
    });

    test('Kotlin 侧必须有 syncSystemBarTheme 分支（Dart 推真实亮度过来）', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      expect(kt.contains('"syncSystemBarTheme" ->'), isTrue,
          reason: '没有这条通道，Kotlin 只能读系统主题，'
              'App 主题独立于系统时状态栏就会割裂（这正是本 Bug）');
      expect(kt.contains('applySystemBarColors(dark)'), isTrue);
    });

    test('applySystemBarColors 接受显式亮度参数（不再只读 uiMode）', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      expect(
        RegExp(r'private fun applySystemBarColors\(dark: Boolean\)')
            .hasMatch(kt),
        isTrue,
        reason: '必须能按传入亮度设色；只读 uiMode 是 Bug 464 的根因',
      );
      // 启动兜底仍应保留（冷启动 Dart 未就绪时用系统值）
      expect(kt.contains('applySystemBarColorsForTheme()'), isTrue,
          reason: '冷启动兜底不能丢，否则首帧前系统栏无颜色');
    });

    test('Dart 桥接暴露 syncSystemBarTheme 且失败不抛（纯装饰性调用）', () {
      final src = File('lib/env/proot_bridge.dart').readAsStringSync();
      expect(src.contains("invokeMethod('syncSystemBarTheme'"), isTrue);
      expect(src.contains('Future<void> syncSystemBarTheme'), isTrue);
    });

    test('main.dart 在主题 builder 里推送亮度（唯一推点）', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src.contains('syncSystemBarTheme(dark: dark)'), isTrue,
          reason: 'builder 每次主题变化都重建，是最合适的推点');
    });
  });

  // ---------------- ② 语义色 ----------------

  group('Bug 464 · 语义色随主题变化', () {
    test('muted 深浅两套值不同（否则谈不上"随主题"）', () {
      expect(FoaTheme.muted(Brightness.dark),
          isNot(FoaTheme.muted(Brightness.light)));
    });

    test('warning 在浅色下必须压深（原来固定橙在浅底上对比度不足）', () {
      final dark = FoaTheme.warning(Brightness.dark);
      final light = FoaTheme.warning(Brightness.light);
      expect(dark, isNot(light));
      // 浅色下亮度应更低（更深的字色压在白底上）
      expect(light.computeLuminance(), lessThan(dark.computeLuminance()),
          reason: '浅色主题若沿用深色主题的亮橙，文字对比度会不足');
    });

    test('danger 同样深浅有别', () {
      expect(FoaTheme.danger(Brightness.dark),
          isNot(FoaTheme.danger(Brightness.light)));
    });

    test('warningContainer 深浅都远亮/远暗于纯黑白（是底不是字）', () {
      final darkBg = FoaTheme.warningContainer(Brightness.dark);
      // 深色主题的警告底应当是**暗**底
      expect(darkBg.computeLuminance(), lessThan(0.2),
          reason: '深色主题下用浅色警告底会刺眼——这正是原 orange.shade50 的问题');
    });

    test('codeBg 深浅分明（日志/代码块底）', () {
      expect(FoaTheme.codeBg(Brightness.dark).computeLuminance(),
          lessThan(FoaTheme.codeBg(Brightness.light).computeLuminance()));
    });

    test('success 用种子绿，两主题一致（强调色不需要变）', () {
      expect(FoaTheme.success(Brightness.dark), FoaTheme.seed);
      expect(FoaTheme.success(Brightness.light), FoaTheme.seed);
    });

    test('项目里不再有 orange.shade50 这类固定浅色底（已全面替换）', () {
      // 扫 lib/（排除 theme.dart 自身的注释）
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('core/theme.dart')) continue;
        final src = f.readAsStringSync();
        if (src.contains('Colors.orange.shade50') ||
            src.contains('Colors.orange.shade200')) {
          offenders.add(f.path);
        }
      }
      expect(offenders, isEmpty,
          reason: '固定浅色警告底在深色主题下会刺眼（Bug 464 的 ② 项）');
    });

    test('不再有 Colors.grey.shade500/600 硬编码次要文字色', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('core/theme.dart')) continue;
        final src = f.readAsStringSync();
        if (src.contains('Colors.grey.shade500') ||
            src.contains('Colors.grey.shade600')) {
          offenders.add(f.path);
        }
      }
      expect(offenders, isEmpty,
          reason: '应统一走 FoaColors.of(context).muted');
    });
  });

  // ---------------- ③ cloudflared 下载 ----------------

  group('Bug 464 · cloudflared 下载可诊断', () {
    test('仍固定 arm64 资产（不能回退成 amd64）', () {
      expect(CloudflaredInstall.assetName, 'cloudflared-linux-arm64');
    });

    test('新增 sha256 校验值，且是合法 64 位十六进制', () {
      expect(CloudflaredInstall.sha256, isNotEmpty,
          reason: '没有内容校验时，坏内容要到容器里才炸，报的还是误导信息');
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(CloudflaredInstall.sha256),
          isTrue);
    });

    test('镜像源至少 4 个（用户网络差异大，多留冗余）', () {
      expect(CloudflaredInstall.mirrors.length, greaterThanOrEqualTo(4));
    });

    test('每个源的 URL 都指向固定版本 + arm64 资产', () {
      for (final m in CloudflaredInstall.mirrors) {
        expect(m.url.contains('cloudflared-linux-arm64'), isTrue,
            reason: '${m.name} 不是 arm64 资产');
        expect(m.url.contains(CloudflaredInstall.version), isTrue,
            reason: '${m.name} 未固定版本，latest 漂移会导致行为不可复现');
      }
    });

    test('提供逐源诊断入口（返回可展示文本）', () {
      final src = File('lib/mcp/cloudflared_install.dart').readAsStringSync();
      expect(src.contains('static Future<String> diagnose()'), isTrue);
    });

    test('ghfast 排在首位（唯一经完整下载 + sha256 双重复核的源）', () {
      expect(CloudflaredInstall.mirrors.first.name, 'ghfast',
          reason: '2026-09-20 实测：ghfast 与 gh-proxy.com 完整下载通过，'
              'ghproxy.net 两次截断（9.3MB/6.4MB）。可靠的排前面。');
    });

    test('ghproxy.net 不得排在已验证可靠的源之前', () {
      final names = CloudflaredInstall.mirrors.map((m) => m.name).toList();
      final bad = names.indexOf('ghproxy.net');
      final good = names.indexOf('gh-proxy.com');
      expect(bad, greaterThan(good),
          reason: 'ghproxy.net 实测会中途截断且返回正常状态码，'
              '不该优先于已验证完整的 gh-proxy.com');
    });
  });

  group('Bug 464 · 下载器保留失败原因', () {
    test('MirrorProbe 成功/失败两种摘要都带名字', () {
      const m = MirrorSource('测试源', 'https://example.invalid/x');
      const ok = MirrorProbe(
          mirror: m, ok: true, elapsed: Duration(milliseconds: 42));
      expect(ok.summary.contains('测试源'), isTrue);
      expect(ok.summary.contains('可用'), isTrue);

      const bad = MirrorProbe(
          mirror: m, ok: false, error: '网络：Failed host lookup');
      expect(bad.summary.contains('测试源'), isTrue);
      expect(bad.summary.contains('Failed host lookup'), isTrue,
          reason: '失败原因必须能透出到 UI，否则用户无法判断是 DNS 还是超时');
    });

    test('diagnose 返回每个源一条记录（不吞异常）', () async {
      final probes = await SdkDownloader.diagnose(const [
        MirrorSource('不可能存在的源', 'https://this-host-must-not-exist.invalid/x'),
      ]);
      expect(probes.length, 1);
      expect(probes.first.ok, isFalse);
      expect(probes.first.error, isNotNull,
          reason: '原地实现里 catch(_) 把原因吞了，只剩"全部失败"');
    });
  });
}
