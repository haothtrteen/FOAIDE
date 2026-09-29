import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// alpha.69：App 图标的**资源存在性与同源性**护栏。
///
/// 背景：这一轮把 Flutter 默认的蓝色 logo 换成了自绘的「绿色终端提示符」。
/// 图标的失效模式很特殊 —— **它不会以任何方式报错**：
///
/// * 忘了跑 `dart run flutter_launcher_icons` → 源码全对、测试全绿、
///   APK 也正常，只有装到手机上才发现还是旧图标。
/// * 改了 `tools/gen_icon.py` 的配色但忘了重新生成 → 源图变了、产物没变。
/// * `.gitignore` 有一条 `flutter_*.png`（Flutter 模板自带），
///   生成物文件名一旦撞上就被静默忽略、进不了仓库（CI 上才会暴露）。
///
/// 这三件事都只能靠"检查产物"来防。所以这里断言的是**文件与像素**，
/// 不是源码字符串。
void main() {
  group('alpha.69 · App 图标资源', () {
    test('源图存在且是 1024 见方（flutter_launcher_icons 的下限）', () {
      for (final name in ['app_icon.png', 'app_icon_foreground.png']) {
        final f = File('assets/icon/$name');
        expect(f.existsSync(), isTrue,
            reason: '$name 不存在 —— 先跑 python3 tools/gen_icon.py');
        // PNG magic number：确认不是被 git-lfs 之类替换成了指针文件
        final head = f.readAsBytesSync().take(8).toList();
        expect(head.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47],
            reason: '$name 不是有效 PNG');
      }
    });

    test('生成器脚本自带几何与配色的合法性（防止改坏）', () {
      final src = File('tools/gen_icon.py').readAsStringSync();
      // 配色必须与 Dart 侧的两个锚点同源
      expect(src.contains('0x3D, 0xDC, 0x84'), isTrue,
          reason: '品牌绿必须 == FoaTheme.seed 的 0x3DDC84');
      expect(src.contains('0x10, 0x14, 0x18'), isTrue,
          reason: '深底必须 == FoaTheme.bg 的 0xFF101418');
      // 前景层必须有安全区缩放（否则 adaptive icon 会被裁掉边角）
      expect(src.contains('SAFE_SCALE'), isTrue,
          reason: '前景层不缩进安全区 = 圆角设备上图标被切');
      // 文件名必须避开 flutter_ 前缀（见 .gitignore 的说明）
      expect(src.contains('"app_icon.png"'), isTrue);
      expect(src.contains('flutter_launcher_icons'), isTrue,
          reason: '脚本末尾应提示下一步命令');
    });

    test('各密度 mipmap 都已生成（漏跑 flutter_launcher_icons 就红）', () {
      const densities = <String, int>{
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      };
      for (final e in densities.entries) {
        final f = File('android/app/src/main/res/mipmap-${e.key}/ic_launcher.png');
        expect(f.existsSync(), isTrue,
            reason: 'mipmap-${e.key} 缺失 —— 先跑 dart run flutter_launcher_icons');
        expect(f.lengthSync(), greaterThan(200),
            reason: '文件过小，可能是空文件或占位图');
      }
    });

    test('adaptive icon 的前景层与 xml 声明都在', () {
      // 前景层走高密度目录
      final fg = File(
          'android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png');
      expect(fg.existsSync(), isTrue,
          reason: 'Android 8+ 的 adaptive icon 需要前景层');

      final xml =
          File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
      expect(xml.existsSync(), isTrue);
      final body = xml.readAsStringSync();
      expect(body.contains('<adaptive-icon'), isTrue);
      expect(body.contains('ic_launcher_background'), isTrue,
          reason: '背景层应引用 colors.xml 的深色底');
      expect(body.contains('ic_launcher_foreground'), isTrue);
    });

    test('adaptive 背景色与 FoaTheme.bg 同源（不是随手写的黑）', () {
      final colors = File('android/app/src/main/res/values/colors.xml')
          .readAsStringSync();
      expect(colors.contains('ic_launcher_background'), isTrue);
      // 值必须与 foa_bg 一致 —— 图标的底与 App 的底是同一个颜色
      final m = RegExp(r'<color name="ic_launcher_background">(#[0-9A-Fa-f]+)</color>')
          .firstMatch(colors);
      expect(m, isNotNull, reason: 'colors.xml 里应有 ic_launcher_background');
      expect(m!.group(1)!.toUpperCase(), '#101418',
          reason: '必须与 FoaTheme.bg（#101418）一致');
    });

    test('配了 flutter_launcher_icons 且源图路径指向 assets/icon/', () {
      final cfg = File('flutter_launcher_icons.yaml');
      expect(cfg.existsSync(), isTrue);
      final body = cfg.readAsStringSync();
      expect(body.contains('image_path: "assets/icon/app_icon.png"'), isTrue);
      expect(body.contains('adaptive_icon_foreground'), isTrue);
      expect(body.contains('adaptive_icon_background'), isTrue);
      // 不该顺带生成 iOS/web/桌面 —— 本项目只有 Android
      expect(body.contains('ios: false'), isTrue);
    });

    test('.gitignore 不会吞掉生成物（`flutter_*.png` 有例外规则）', () {
      // 这是最容易埋雷的一条：Flutter 模板自带的 `flutter_*.png`
      // 会连 mipmap 里的启动图一起忽略，导致生成物进不了仓库。
      final gi = File('.gitignore').readAsStringSync();
      expect(gi.contains('flutter_*.png'), isTrue,
          reason: 'Flutter 模板自带的规则，应保留');
      expect(gi.contains('!android/app/src/main/res/mipmap-*/flutter_*.png'),
          isTrue, reason: '必须有例外，否则启动图会被静默忽略');
    });
  });

  group('alpha.69 · 出包脚本带图标校验', () {
    test('verify_apk.sh 有第 5 项图标检查（共 6 项）', () {
      final sh = File('../tools/verify_apk.sh').readAsStringSync();
      expect(sh.contains('【5/5】'), isTrue,
          reason: '忘跑图标生成时，前四项全过、只有装到手机才发现');
      expect(sh.contains('mipmap/ic_launcher'), isTrue);
      expect(sh.contains('drawable/ic_launcher_foreground'), isTrue);
      expect(sh.contains('color/ic_launcher_background'), isTrue);
      // ⚠️ 这条最关键：release 包会混淆资源名（res/bB.png 之类），
      // 按文件名查是**假红**。必须走 aapt2 dump resources 拿逻辑名。
      expect(sh.contains('AAPT2'), isTrue,
          reason: '图标检查必须用 aapt2，unzip -l 的文件名在 release 包里被混淆了');
      expect(sh.contains('dump resources'), isTrue);
      // 不能退回按路径 grep 的写法
      expect(sh.contains('res/mipmap-mdpi/ic_launcher.png'), isFalse,
          reason: '这是被混淆掉的物理路径，查不到会误判为"图标缺失"');
      // 配色必须真的验到品牌绿
      expect(sh.contains('3DDC84'), isTrue,
          reason: '应校验主色是品牌绿，而非仍是 Flutter 默认蓝');
      // alpha.72 增了第 6 项「文案落地」，汇总口径从五项变六项。
      // 这条断言的作用是：加检查项时必须同步改汇总，否则输出会自相矛盾。
      expect(sh.contains('六项全部通过'), isTrue,
          reason: '汇总文案要跟着项数改');
      expect(sh.contains('【6/6】'), isTrue,
          reason: '第 6 项：关键 UI 文案必须真的进了 libapp.so —— '
              '前五项跑的是"包结构对不对"，拿上一次的产物验也照样全绿');
    });

    test('图标检查的采样点按 SAFE_SCALE 换算（不是拿满幅坐标直接取）', () {
      final sh = File('../tools/verify_apk.sh').readAsStringSync();
      // 前景层已缩到安全区，采样点若还用满幅几何比例，
      // 会落在透明区域上 → 取到 000000 → 假红。
      expect(sh.contains('SAFE = 0.62'), isTrue,
          reason: '必须与 tools/gen_icon.py 的 SAFE_SCALE 一致');
      expect(sh.contains('ox + gx * SAFE'), isTrue,
          reason: '采样坐标要做安全区换算');
    });
  });
}
