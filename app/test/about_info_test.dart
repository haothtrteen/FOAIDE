import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ui/about_info.dart';

/// alpha.61「关于」页数据源守卫。
///
/// 这组测试针对的是一类**必然复发**的错误：
/// 旧版关于卡片写死 "v0.1.0-alpha.26"，之后一路发到 alpha.60 都没人改——
/// 因为没有任何东西会因为它写错而失败。版本号、作者、邮箱、仓库地址
/// 都属于"错了也照样编译通过"的信息，只能靠断言守住。
void main() {
  group('应用标识', () {
    test('显示名是 FOAIDE（与 Manifest label 一致）', () {
      expect(AboutInfo.appName, 'FOAIDE');
      final mf = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(mf.contains('android:label="${AboutInfo.appName}"'), isTrue,
          reason: '关于页显示名与 AndroidManifest 的 android:label 必须一致');
    });

    test('版本号与 pubspec.yaml 同步', () {
      final pub = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(pub);
      expect(m, isNotNull, reason: 'pubspec.yaml 必须有 version 行');
      final pubVersion = m!.group(1)!.trim();
      // AboutInfo 用 "v" 前缀展示，pubspec 不带；比对时去掉前缀
      final shown = AboutInfo.version.startsWith('v')
          ? AboutInfo.version.substring(1)
          : AboutInfo.version;
      expect(shown, pubVersion,
          reason: '关于页版本号必须等于 pubspec.yaml 的 version，'
              '否则会重演"卡片停在 alpha.26"的旧问题');
    });

    test('版本号格式可解析（vX.Y.Z-...）', () {
      expect(RegExp(r'^v\d+\.\d+\.\d+').hasMatch(AboutInfo.version), isTrue,
          reason: '版本号应带 v 前缀且符合语义版本，方便用户报 bug 时抄');
    });
  });

  group('作者与联系方式', () {
    test('作者与邮箱按用户要求填写', () {
      expect(AboutInfo.author, 'haothtrteen');
      expect(AboutInfo.email, '2557976190@qq.com');
    });

    test('邮箱格式合法（可被复制去发信）', () {
      expect(
        RegExp(r'^[\w.+-]+@[\w-]+\.[\w.]+$').hasMatch(AboutInfo.email),
        isTrue,
      );
    });
  });

  group('第三方组件清单', () {
    test('覆盖核心组件（proot / rootfs / qemu / cloudflared / 构建工具）', () {
      final names = AboutInfo.components.map((c) => c.name).join('|');
      for (final key in ['proot', 'Debian', 'QEMU', 'cloudflared', 'build-tools']) {
        expect(names.contains(key), isTrue,
            reason: '关于页必须交代 $key 的来源——用户有权知道设备上多了什么');
      }
    });

    test('每项都有仓库地址、许可、用途（不留空）', () {
      for (final c in AboutInfo.components) {
        expect(c.name.trim(), isNotEmpty);
        expect(c.license.trim(), isNotEmpty, reason: '${c.name} 缺许可标注');
        expect(c.usage.trim(), isNotEmpty, reason: '${c.name} 缺用途说明');
        expect(c.repoUrl, startsWith('https://'),
            reason: '${c.name} 的仓库地址必须是可点的 https 链接');
      }
    });

    test('仓库地址无重复（防复制粘贴时串行）', () {
      final urls = AboutInfo.components.map((c) => c.repoUrl).toList();
      expect(urls.toSet().length, urls.length,
          reason: '同一地址出现两次通常是复制粘贴出错');
    });

    test('proroot 如实标注为专有许可（不能写成开源）', () {
      final p = AboutInfo.components.firstWhere((c) => c.name == 'proroot');
      expect(p.license.toUpperCase().contains('PROPRIETARY'), isTrue,
          reason: 'proroot 源码未公开、专有许可——标成开源是事实性错误');
      expect(p.usage.contains('默认关闭'), isTrue,
          reason: '应说明默认关闭且需用户自行放置二进制');
    });

    test('cloudflared 标注 Apache-2.0 与"不随 APK 分发"', () {
      final c = AboutInfo.components.firstWhere((c) => c.name == 'cloudflared');
      expect(c.license, 'Apache-2.0');
      expect(c.usage.contains('不随 APK 分发'), isTrue,
          reason: '运行时下载的二进制必须说明分发方式，这关系到合规判断');
    });

    test('与 THIRD-PARTY-NOTICES.md 不脱节（两边都要有 cloudflared 与 proroot）', () {
      final notices = File('THIRD-PARTY-NOTICES.md');
      expect(notices.existsSync(), isTrue);
      final t = notices.readAsStringSync();
      expect(t.contains('cloudflared'), isTrue,
          reason: '新增组件必须同时登记进 THIRD-PARTY-NOTICES.md');
      expect(t.contains('proroot'), isTrue);
    });
  });

  group('GPL 披露', () {
    test('proot 与 QEMU 如实标注 GPL-2.0（有分发义务，不能隐瞒）', () {
      final proot =
          AboutInfo.components.firstWhere((c) => c.name == 'proot');
      final qemu =
          AboutInfo.components.firstWhere((c) => c.name.startsWith('QEMU'));
      expect(proot.license, 'GPL-2.0');
      expect(qemu.license, 'GPL-2.0');
    });

    test('proot 用途说明里点明"独立进程、不链接进 App"', () {
      final p = AboutInfo.components.firstWhere((c) => c.name == 'proot');
      expect(p.usage.contains('独立进程'), isTrue,
          reason: 'GPL 传染性争议点在"链接进同一进程"，必须把边界讲清');
    });
  });
}
