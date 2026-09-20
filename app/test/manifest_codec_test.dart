import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/project/manifest_codec.dart';

/// alpha.61 清单页重构：解析/改写纯函数的测试。
///
/// 这一层是"改了 A 文件、忘了 B 文件"这类问题的第一道防线。
/// 清单页要同时维护 pubspec.yaml / AndroidManifest.xml / build.gradle
/// 三个文件，任何一处正则写歪都会静默改坏用户的工程——所以每个
/// 变换函数都必须有正向用例 + 边界用例（找不到、重复、注释干扰）。
void main() {
  // 贴近真实工程的最小样例
  const pubspec = '''
name: my_app
description: A new Flutter project.
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.3.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  http: ^1.2.0

dev_dependencies:
  flutter_test:
    sdk: flutter
''';

  const manifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />

    <application
        android:name="\${applicationName}"
        android:label="FlutterOnAndroid"
        android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true">
        </activity>
    </application>
</manifest>
''';

  const gradle = '''
android {
    defaultConfig {
        applicationId = "dev.foa.flutter_on_android"
        minSdk = 26
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}
''';

  group('parsePubspec', () {
    test('解析出 name / description / version 三段', () {
      final r = ManifestCodec.parsePubspec(pubspec);
      expect(r.name, 'my_app');
      expect(r.description, 'A new Flutter project.');
      expect(r.verName, '1.0.0');
      expect(r.verCode, '1');
    });

    test('version 无 +code 时版本代码兜底为 1', () {
      final r = ManifestCodec.parsePubspec('name: a\nversion: 2.3.4\n');
      expect(r.verName, '2.3.4');
      expect(r.verCode, '1');
    });

    test('description 带引号时去掉引号（不要残留在 UI 上）', () {
      final r = ManifestCodec.parsePubspec('name: a\ndescription: "带引号的描述"\n');
      expect(r.description, '带引号的描述');
    });

    test('空文件不崩，且给出可用兜底', () {
      final r = ManifestCodec.parsePubspec('');
      expect(r.name, '');
      expect(r.verName, '1.0.0');
      expect(r.verCode, '1');
    });
  });

  group('parseManifest', () {
    test('解析 label 与权限清单', () {
      final r = ManifestCodec.parseManifest(manifest);
      expect(r.label, 'FlutterOnAndroid');
      expect(r.permissions, containsAll([
        'android.permission.INTERNET',
        'android.permission.FOREGROUND_SERVICE',
      ]));
      expect(r.permissions.length, 2,
          reason: '不应把 activity 的 android:name 误当权限');
    });

    test('无权限标签时返回空列表而非崩', () {
      final r = ManifestCodec.parseManifest('<application android:label="X"/>');
      expect(r.permissions, isEmpty);
      expect(r.label, 'X');
    });
  });

  group('parseGradle', () {
    test('解析 applicationId 与 isMinifyEnabled（Kotlin DSL）', () {
      final r = ManifestCodec.parseGradle(gradle);
      expect(r.appId, 'dev.foa.flutter_on_android');
      expect(r.minify, isTrue);
    });

    test('兼容 Groovy 写法（无 = 号）', () {
      final r = ManifestCodec.parseGradle(
          'applicationId "com.example.app"\nminifyEnabled false\n');
      expect(r.appId, 'com.example.app');
      expect(r.minify, isFalse);
    });

    test('缺 minifyEnabled 时视为开启（Flutter release 默认 R8）', () {
      final r = ManifestCodec.parseGradle('applicationId = "a.b"');
      expect(r.minify, isTrue);
    });
  });

  group('countDependencies', () {
    test('只数 dependencies 段的一级键（flutter / cupertino_icons / http）', () {
      // flutter（SDK 依赖）本身也是一条依赖，故为 3；
      // 4 空格缩进的 "sdk: flutter" 是 flutter 项的子键，不计入；
      // dev_dependencies 段的 flutter_test 不计入。
      expect(ManifestCodec.countDependencies(pubspec), 3);
    });

    test('dev_dependencies 的条目不计入（不能被子串匹配骗到）', () {
      const onlyDev = '''
dependencies:
  http: ^1.2.0

dev_dependencies:
  flutter_test:
    sdk: flutter
''';
      expect(ManifestCodec.countDependencies(onlyDev), 1);
    });

    test('没有 dependencies 段时返回 0', () {
      expect(ManifestCodec.countDependencies('name: a\n'), 0);
    });

    test('文件开头的 dependencies 行也能被匹配（行锚定，不依赖前导换行）', () {
      const head = 'dependencies:\n  http: ^1.2.0\n';
      expect(ManifestCodec.countDependencies(head), 1);
    });
  });

  group('setPubName / setDescription / setVersion', () {
    test('改 name 只动 name 行', () {
      final out = ManifestCodec.setPubName(pubspec, 'foa_ide');
      expect(ManifestCodec.parsePubspec(out).name, 'foa_ide');
      // 其它字段不受影响
      expect(ManifestCodec.parsePubspec(out).verName, '1.0.0');
      expect(out.contains('cupertino_icons'), isTrue);
    });

    test('改 version 保留其它内容', () {
      final out = ManifestCodec.setVersion(pubspec, '2.1.0', '42');
      final r = ManifestCodec.parsePubspec(out);
      expect(r.verName, '2.1.0');
      expect(r.verCode, '42');
      expect(r.name, 'my_app', reason: '不应误伤 name 行');
    });

    test('description 含冒号时自动加引号（否则 YAML 会解析错）', () {
      final out = ManifestCodec.setDescription(pubspec, '我的应用: 很好用');
      // 加引号后能被原样解析回来
      expect(ManifestCodec.parsePubspec(out).description, '我的应用: 很好用');
      expect(out.contains('"我的应用: 很好用"'), isTrue);
    });

    test('description 含 # 时也加引号', () {
      final out = ManifestCodec.setDescription(pubspec, '标签 # 说明');
      expect(ManifestCodec.parsePubspec(out).description, '标签 # 说明');
    });

    test('找不到目标行时原样返回（调用方应比对结果判断失败）', () {
      const t = 'foo: bar\n';
      expect(ManifestCodec.setPubName(t, 'x'), t);
      expect(ManifestCodec.setVersion(t, '1.0.0', '1'), t);
    });
  });

  group('setLabel', () {
    test('改 android:label 的值', () {
      final out = ManifestCodec.setLabel(manifest, '我的应用');
      expect(ManifestCodec.parseManifest(out).label, '我的应用');
    });

    test('只改第一个 label（application 上的那个）', () {
      const two = '<application android:label="A">'
          '<activity android:label="B"/></application>';
      final out = ManifestCodec.setLabel(two, 'X');
      expect(ManifestCodec.parseManifest(out).label, 'X');
      expect(out.contains('android:label="B"'), isTrue,
          reason: 'activity 自己的 label 不该被动');
    });

    test('无 label 时原样返回', () {
      const t = '<manifest></manifest>';
      expect(ManifestCodec.setLabel(t, 'X'), t);
    });
  });

  group('applyPermissions', () {
    test('新增权限插入到现有权限之后（保持成组）', () {
      final out = ManifestCodec.applyPermissions(
        manifest,
        toAdd: {'android.permission.POST_NOTIFICATIONS'},
        toRemove: {},
      );
      final perms = ManifestCodec.parseManifest(out).permissions;
      expect(perms, contains('android.permission.POST_NOTIFICATIONS'));
      expect(perms.length, 3);
      // 仍排在 application 之前
      expect(out.indexOf('POST_NOTIFICATIONS'), lessThan(out.indexOf('<application')));
    });

    test('已存在的权限不重复插入（幂等）', () {
      final out = ManifestCodec.applyPermissions(
        manifest,
        toAdd: {'android.permission.INTERNET'},
        toRemove: {},
      );
      final perms = ManifestCodec.parseManifest(out).permissions;
      expect(perms.where((p) => p == 'android.permission.INTERNET').length, 1);
    });

    test('删除权限会连整行一起删（不留空行）', () {
      final out = ManifestCodec.applyPermissions(
        manifest,
        toAdd: {},
        toRemove: {'android.permission.FOREGROUND_SERVICE'},
      );
      expect(out.contains('FOREGROUND_SERVICE'), isFalse);
      expect(ManifestCodec.parseManifest(out).permissions.length, 1);
      // 不应产生连续空行堆积
      expect(out.contains('\n\n\n'), isFalse);
    });

    test('同时增删互不干扰', () {
      final out = ManifestCodec.applyPermissions(
        manifest,
        toAdd: {'android.permission.CAMERA'},
        toRemove: {'android.permission.INTERNET'},
      );
      final perms = ManifestCodec.parseManifest(out).permissions;
      expect(perms, contains('android.permission.CAMERA'));
      expect(perms, isNot(contains('android.permission.INTERNET')));
      expect(perms, contains('android.permission.FOREGROUND_SERVICE'));
    });

    test('无任何权限标签时插入到 <application 之前', () {
      const bare = '<manifest>\n<application android:label="X"/>\n</manifest>';
      final out = ManifestCodec.applyPermissions(
        bare,
        toAdd: {'android.permission.INTERNET'},
        toRemove: {},
      );
      expect(ManifestCodec.parseManifest(out).permissions,
          contains('android.permission.INTERNET'));
      expect(out.indexOf('INTERNET'), lessThan(out.indexOf('<application')));
    });
  });

  group('setMinify', () {
    test('关闭 R8', () {
      final out = ManifestCodec.setMinify(gradle, false);
      expect(ManifestCodec.parseGradle(out).minify, isFalse);
      expect(out.contains('isShrinkResources = true'), isTrue,
          reason: '不应误伤相邻的 isShrinkResources（前缀重叠）');
    });

    test('开启 R8', () {
      final out = ManifestCodec.setMinify(
          'isMinifyEnabled = false', true);
      expect(ManifestCodec.parseGradle(out).minify, isTrue);
    });

    test('Groovy 写法的分隔符被保留', () {
      final out = ManifestCodec.setMinify('minifyEnabled true', false);
      expect(out, contains('minifyEnabled false'));
      expect(out.contains('='), isFalse, reason: 'Groovy 写法不该被塞进 = 号');
    });
  });

  group('校验函数', () {
    test('版本名：接受语义版本，拒绝残缺格式', () {
      expect(ManifestCodec.validVersionName('1.0.0'), isTrue);
      expect(ManifestCodec.validVersionName('2.1.0-beta.1'), isTrue);
      expect(ManifestCodec.validVersionName('1.0'), isFalse);
      expect(ManifestCodec.validVersionName('v1.0.0'), isFalse);
      expect(ManifestCodec.validVersionName(''), isFalse);
    });

    test('版本代码：只接受纯整数（用户明确要求）', () {
      expect(ManifestCodec.validVersionCode('1'), isTrue);
      expect(ManifestCodec.validVersionCode('42'), isTrue);
      expect(ManifestCodec.validVersionCode('1.0'), isFalse);
      expect(ManifestCodec.validVersionCode('-1'), isFalse);
      expect(ManifestCodec.validVersionCode('abc'), isFalse);
      expect(ManifestCodec.validVersionCode(''), isFalse);
    });

    test('版本降级能被识别（上架会被拒，值得提示）', () {
      expect(ManifestCodec.versionNameDowngrade('1.2.0', '1.1.9'), isTrue);
      expect(ManifestCodec.versionNameDowngrade('1.2.0', '1.2.0'), isFalse);
      expect(ManifestCodec.versionNameDowngrade('1.2.0', '1.3.0'), isFalse);
      expect(ManifestCodec.versionNameDowngrade('2.0.0', '1.99.99'), isTrue);
    });

    test('应用名：空值不合法（桌面图标会没名字）', () {
      expect(ManifestCodec.validLabel('我的应用'), isTrue);
      expect(ManifestCodec.validLabel('   '), isFalse);
      expect(ManifestCodec.validLabel(''), isFalse);
    });
  });

  group('端到端：一串编辑后三个文件都自洽', () {
    test('改名 + 改版本 + 加权限 + 关混淆', () {
      var mf = manifest;
      var pub = pubspec;
      var gr = gradle;

      pub = ManifestCodec.setPubName(pub, 'foaide');
      pub = ManifestCodec.setDescription(pub, 'FOAIDE 演示工程');
      pub = ManifestCodec.setVersion(pub, '0.2.0', '7');
      mf = ManifestCodec.setLabel(mf, 'FOAIDE 演示');
      mf = ManifestCodec.applyPermissions(mf,
          toAdd: {'android.permission.CAMERA'}, toRemove: {});
      gr = ManifestCodec.setMinify(gr, false);

      expect(ManifestCodec.parsePubspec(pub).name, 'foaide');
      expect(ManifestCodec.parsePubspec(pub).description, 'FOAIDE 演示工程');
      expect(ManifestCodec.parsePubspec(pub).verName, '0.2.0');
      expect(ManifestCodec.parsePubspec(pub).verCode, '7');
      expect(ManifestCodec.parseManifest(mf).label, 'FOAIDE 演示');
      expect(ManifestCodec.parseManifest(mf).permissions,
          contains('android.permission.CAMERA'));
      expect(ManifestCodec.parseGradle(gr).minify, isFalse);
    });
  });
}
