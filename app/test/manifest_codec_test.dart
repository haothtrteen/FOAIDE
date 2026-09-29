import 'dart:io';

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
    namespace = "dev.foa.flutter_on_android"
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
      expect(ManifestCodec.parseGradle(out.code).minify, isFalse);
      expect(out.inserted, isFalse, reason: '原地改写，不算插入');
    });

    // Bug 635：AGP 硬校验"资源缩减必须配合代码缩减"，只要
    // isShrinkResources 还是 true 而 isMinifyEnabled 变成 false，
    // 连 debug 构建都会在配置阶段就失败：
    //   > Removing unused resources requires unused code shrinking ...
    // 也就是说"关掉 R8"这个开关以前会把整个工程搞成构建不了的状态。
    group('Bug 635 · 关混淆必须同步关资源缩减', () {
      test('两者都置 false', () {
        const src = ''
            'buildTypes {\n'
            '    release {\n'
            '        isMinifyEnabled = true\n'
            '        isShrinkResources = true\n'
            '    }\n'
            '}\n';
        final out = ManifestCodec.setMinify(src, false);
        expect(out.code, contains('isMinifyEnabled = false'));
        expect(out.code, contains('isShrinkResources = false'),
            reason: '不改的话 AGP 会拒绝配置工程，构建直接失败');
      });

      test('开启时不反向改动资源缩减', () {
        const src = 'isMinifyEnabled = false\nisShrinkResources = false\n';
        final out = ManifestCodec.setMinify(src, true);
        expect(out.code, contains('isMinifyEnabled = true'));
        expect(out.code, contains('isShrinkResources = false'),
            reason: '开混淆没有"必须配套"的约束，不替用户决定资源缩减');
      });

      test('Groovy 写法的分隔符同样保留', () {
        const src = 'minifyEnabled true\nshrinkResources true\n';
        final out = ManifestCodec.setMinify(src, false);
        expect(out.code, contains('minifyEnabled false'));
        expect(out.code, contains('shrinkResources false'));
        expect(out.code.contains('='), isFalse,
            reason: 'Groovy 写法不该被塞进 = 号');
      });

      test('原文没有 shrinkResources 就不插', () {
        final out = ManifestCodec.setMinify('isMinifyEnabled = true', false);
        expect(out.code, isNot(contains('ShrinkResources')),
            reason: '资源缩减是独立开关，没写就别替用户决定');
      });
    });

    test('开启 R8', () {
      final out = ManifestCodec.setMinify(
          'isMinifyEnabled = false', true);
      expect(ManifestCodec.parseGradle(out.code).minify, isTrue);
      expect(out.inserted, isFalse);
    });

    test('Groovy 写法的分隔符被保留', () {
      final out = ManifestCodec.setMinify('minifyEnabled true', false);
      expect(out.code, contains('minifyEnabled false'));
      expect(out.code.contains('='), isFalse, reason: 'Groovy 写法不该被塞进 = 号');
    });

    // 官方模板的 buildTypes.release 里**根本没有** minifyEnabled ——
    // 这就是"r8无法关闭"的根因。这一组用**真实模板文件**做夹具，
    // 保证"自动插入一行"在真文件上成立，而不只是在我手写的样张上成立。
    group('（真实 Flutter 模板）缺行时自动插入', () {
      File template() => File('/opt/flutter/packages/flutter_tools/templates/'
          'app/android-kotlin.tmpl/app/build.gradle.kts.tmpl');

      test('插入后解析回来真的是关的，且幂等', () {
        final src = template().readAsStringSync();
        // 前提：模板里确实没有这一行（模板一变，这条会先炸，提示夹具失效）
        expect(ManifestCodec.parseGradle(src).minifyExplicit, isFalse,
            reason: '上游模板新增了 minifyEnabled，本夹具需要重写');

        final r = ManifestCodec.setMinify(src, false);
        expect(r.inserted, isTrue);
        expect(r.code, contains('isMinifyEnabled = false'));
        expect(ManifestCodec.parseGradle(r.code).minify, isFalse);
        expect(ManifestCodec.parseGradle(r.code).minifyExplicit, isTrue);

        // 幂等：再来一次不该多插一行
        final r2 = ManifestCodec.setMinify(r.code, false);
        expect(r2.inserted, isFalse);
        expect(r2.code, r.code);

        // 还能开回去
        final r3 = ManifestCodec.setMinify(r.code, true);
        expect(r3.inserted, isFalse, reason: '已有该行，走原地改写');
        expect(ManifestCodec.parseGradle(r3.code).minify, isTrue);
      });

      test('插入的缩进对得上（写进 release 块里，不是顶格）', () {
        final src = template().readAsStringSync();
        final code = ManifestCodec.setMinify(src, false).code;
        final line = code
            .split('\n')
            .firstWhere((l) => l.contains('isMinifyEnabled'));
        expect(line, matches(RegExp(r'^ +isMinifyEnabled = false$')),
            reason: '要有前导缩进且不留尾随空白');
        expect(code, isNot(contains('\n\n\n')), reason: '不要插出多余空行');
      });

      test('没有 release 块时补一个，按 DSL 风格选对键名', () {
        // Kotlin DSL：赋值是 `键 = 值`
        const kts = 'android {\n'
            '    compileSdk = 36\n'
            '    buildTypes {\n'
            '    }\n'
            '}\n';
        final r = ManifestCodec.setMinify(kts, false);
        expect(r.inserted, isTrue);
        expect(r.code, contains('isMinifyEnabled = false'));
        expect(r.code, isNot(contains('minifyEnabled = false')));

        // Groovy DSL：赋值是 `键 值`（无 = 号）
        const groovy = 'android {\n'
            '    compileSdk 36\n'
            '    buildTypes {\n'
            '    }\n'
            '}\n';
        final g = ManifestCodec.setMinify(groovy, false);
        expect(g.inserted, isTrue);
        expect(g.code, contains('minifyEnabled = false'));
      });

      test('连 buildTypes 都没有时如实返回没改，不硬拗', () {
        const weird = 'plugins {\n    id "com.android.application"\n}\n';
        final r = ManifestCodec.setMinify(weird, false);
        expect(r.inserted, isFalse);
        expect(r.code, weird, reason: '不能改坏用户文件');
      });
    });
  });

  group('parseGradle · minifyExplicit', () {
    test('有这一行时为 true，读到的是什么就是什么', () {
      expect(ManifestCodec.parseGradle('isMinifyEnabled = false').minifyExplicit,
          isTrue);
      expect(ManifestCodec.parseGradle('isMinifyEnabled = true').minifyExplicit,
          isTrue);
    });

    test('没这一行时为 false，但 minify 兜底为 true（AGP 默认）', () {
      final r = ManifestCodec.parseGradle('android { }\n');
      expect(r.minifyExplicit, isFalse);
      expect(r.minify, isTrue);
    });
  });

  group('setAppId', () {
    test('Groovy：只改 applicationId，不凭空插入 namespace', () {
      // 这一段是 Groovy 风格 —— 模板里所有可识别的赋值都是 `键 值` 形式，
      // 没有任何 `键 = 值`，此时单方改写是对的（不要无中生有加 namespace）。
      const groovyGradle = '''
android {
    defaultConfig {
        applicationId "dev.foa.flutter_on_android"
        minSdk 26
    }
    buildTypes {
        release {
            minifyEnabled true
        }
    }
}
''';
      final r = ManifestCodec.setAppId(groovyGradle, 'com.acme.newapp');
      expect(r.changed, isTrue);
      expect(r.code, contains('applicationId "com.acme.newapp"'));
      expect(r.code, isNot(contains('namespace')),
          reason: '原文没有 namespace 就不该被插进去');
    });

    test('Kotlin DSL：namespace 与 applicationId 一起改', () {
      final r = ManifestCodec.setAppId(gradle, 'com.acme.newapp');
      expect(r.changed, isTrue);
      expect(ManifestCodec.parseGradle(r.code).appId, 'com.acme.newapp');
      expect(r.code, contains('namespace = "com.acme.newapp"'));
      expect(r.code, contains('applicationId = "com.acme.newapp"'));
    });

    test('真实模板：两处都改，且不误伤注释里的 URL', () {
      final src = File('/opt/flutter/packages/flutter_tools/templates/app/'
              'android-kotlin.tmpl/app/build.gradle.kts.tmpl')
          .readAsStringSync();
      final r = ManifestCodec.setAppId(src, 'com.acme.newapp');
      expect(r.changed, isTrue);
      expect(ManifestCodec.parseGradle(r.code).appId, 'com.acme.newapp');
      expect(r.code, contains('namespace = "com.acme.newapp"'));
      expect(r.code, contains('applicationId = "com.acme.newapp"'));
      expect(r.code, contains('developer.android.com'),
          reason: '注释里那句 TODO 的 URL 不该被误伤');
    });

    test('Groovy 写法（无 = 号）也能改', () {
      final r = ManifestCodec.setAppId(
          'applicationId "com.old.app"\n', 'com.new.app');
      expect(r.changed, isTrue);
      expect(r.code, contains('applicationId "com.new.app"'));
    });

    test('一处都没有时如实返回没改', () {
      final r = ManifestCodec.setAppId('android { }\n', 'com.a.b');
      expect(r.changed, isFalse);
    });
  });

  group('setManifestPackage', () {
    test('只改已有的 package 属性，不新插', () {
      final r = ManifestCodec.setManifestPackage(
          '<manifest package="com.old.app"><application/></manifest>',
          'com.new.app');
      expect(r.changed, isTrue);
      expect(r.code, contains('package="com.new.app"'));
      expect(r.code, isNot(contains('com.old.app')));
    });

    test('没有 package 属性时原样返回（AGP 8 已移除该属性）', () {
      const src =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
          '<application/></manifest>';
      final r = ManifestCodec.setManifestPackage(src, 'com.a.b');
      expect(r.changed, isFalse);
      expect(r.code, src);
    });
  });

  group('validAppId', () {
    test('接受常规包名', () {
      expect(ManifestCodec.validAppId('com.example.app'), isTrue);
      expect(ManifestCodec.validAppId('dev.foa.flutter_on_android'), isTrue);
      expect(ManifestCodec.validAppId('a.b'), isTrue);
    });

    test('拒绝段数不足 / 非法字符 / 数字或下划线开头', () {
      expect(ManifestCodec.validAppId('com'), isFalse, reason: '至少两段');
      expect(ManifestCodec.validAppId(''), isFalse);
      expect(ManifestCodec.validAppId('com.example.my app'), isFalse);
      expect(ManifestCodec.validAppId('com.例子.app'), isFalse);
      expect(ManifestCodec.validAppId('Com.Example.App'), isFalse,
          reason: '大写字母不能用');
      expect(ManifestCodec.validAppId('com.1app'), isFalse);
      expect(ManifestCodec.validAppId('com..app'), isFalse, reason: '空段');
      expect(ManifestCodec.validAppId('com.example.app.'), isFalse);
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
      gr = ManifestCodec.setMinify(gr, false).code;

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

  group('Bug 636 · 非法 shrink 组合（AGP 会拒绝配置工程）', () {
    // 真机报错（alpha.97 用户现场，连 debug 构建都炸）：
    //   A problem occurred configuring project ':app'.
    //   > Removing unused resources requires unused code shrinking to be
    //     turned on.
    //
    // 机制（AGP gradle-8.13.1.jar 反编译实证，非推测）：
    //   getResourcesShrink()==true 且 getMinifiedEnabled()==false
    //     → issueReporter.reportError(...) → 配置期致命失败
    //
    // 为什么会波及 debug：Flutter Gradle 插件（FlutterPlugin.kt:216）
    // 对 release 无条件设 isMinifyEnabled=true + isShrinkResources=true，
    // debug 变体通过 buildType 继承拿到同一组属性。

    test('explicitShrinkResources：没写时返回 null（不是 false）', () {
      const t = 'buildTypes { release { isMinifyEnabled = true } }';
      expect(ManifestCodec.explicitShrinkResources(t), isNull);
      // 这个区分很重要：null=走默认值、我们读到的未必是真实生效值，
      // 拿它当判据会误改用户工程。
    });

    test('explicitShrinkResources：显式 false 与 true 都能读出来', () {
      expect(ManifestCodec.explicitShrinkResources('isShrinkResources = true'),
          isTrue);
      expect(ManifestCodec.explicitShrinkResources('isShrinkResources = false'),
          isFalse);
      // Groovy 形态
      expect(ManifestCodec.explicitShrinkResources('shrinkResources true'),
          isTrue);
    });

    test('explicitMinify：没写时返回 null', () {
      expect(ManifestCodec.explicitMinify('isShrinkResources = true'), isNull);
      expect(ManifestCodec.explicitMinify('isMinifyEnabled = false'), isFalse);
      expect(ManifestCodec.explicitMinify('minifyEnabled true'), isTrue);
    });

    test('检出非法组合：shrink=true 且 minify=false（都显式）', () {
      const bad = """
buildTypes {
    release {
        isMinifyEnabled = false
        isShrinkResources = true
    }
}
""";
      expect(ManifestCodec.hasIllegalShrinkCombo(bad), isTrue);
    });

    test('不误报：只有 shrink=true、minify 没写（走插件默认，合法）', () {
      // Flutter 插件会给 release 同时设 true/true，是合法状态。
      // 若拿"读到的 minify=null"当 false 处理，就会误改用户工程。
      const ok = """
buildTypes {
    release {
        isShrinkResources = true
    }
}
""";
      expect(ManifestCodec.hasIllegalShrinkCombo(ok), isFalse);
    });

    test('不误报：shrink=true 且 minify=true（Flutter 插件默认形态）', () {
      const ok = """
buildTypes {
    release {
        isMinifyEnabled = true
        isShrinkResources = true
    }
}
""";
      expect(ManifestCodec.hasIllegalShrinkCombo(ok), isFalse);
    });

    test('不误报：shrink 没写（官方模板形态）', () {
      const ok = """
buildTypes {
    release {
        isMinifyEnabled = false
    }
}
""";
      expect(ManifestCodec.hasIllegalShrinkCombo(ok), isFalse);
    });

    test('不误报：shrink=false 且 minify=false（合法）', () {
      const ok = """
buildTypes {
    release {
        isMinifyEnabled = false
        isShrinkResources = false
    }
}
""";
      expect(ManifestCodec.hasIllegalShrinkCombo(ok), isFalse);
    });

    test('修复：把 isShrinkResources 改成 false，不碰 minify', () {
      const bad = """
buildTypes {
    release {
        isMinifyEnabled = false
        isShrinkResources = true
    }
}
""";
      final r = ManifestCodec.fixIllegalShrinkCombo(bad);
      expect(r.changed, isTrue);
      expect(r.code.contains('isShrinkResources = false'), isTrue);
      // minify 是用户刚手动设的明确意图 —— 绝不能推翻
      expect(r.code.contains('isMinifyEnabled = false'), isTrue);
      // 修完必须变合法
      expect(ManifestCodec.hasIllegalShrinkCombo(r.code), isFalse);
    });

    test('修复 Groovy 形态（shrinkResources true）', () {
      const bad = """
buildTypes {
    release {
        minifyEnabled false
        shrinkResources true
    }
}
""";
      final r = ManifestCodec.fixIllegalShrinkCombo(bad);
      expect(r.changed, isTrue);
      expect(r.code.contains('shrinkResources false'), isTrue);
      expect(ManifestCodec.hasIllegalShrinkCombo(r.code), isFalse);
    });

    test('修复幂等：合法输入原样返回、changed=false', () {
      const ok = """
buildTypes {
    release {
        isMinifyEnabled = true
        isShrinkResources = true
    }
}
""";
      final r = ManifestCodec.fixIllegalShrinkCombo(ok);
      expect(r.changed, isFalse);
      expect(r.code, ok);
      // 再修一次仍然不动
      expect(ManifestCodec.fixIllegalShrinkCombo(r.code).changed, isFalse);
    });

    test('修复后能读通：parseGradle 仍认得出 minify', () {
      const bad = """
buildTypes {
    release {
        isMinifyEnabled = false
        isShrinkResources = true
    }
}
""";
      final r = ManifestCodec.fixIllegalShrinkCombo(bad);
      final p = ManifestCodec.parseGradle(r.code);
      expect(p.minify, isFalse);
      expect(p.minifyExplicit, isTrue);
    });

    test('接进构建流程：构建前检查 + 修复接线都在', () {
      // 这条是"代码写了但没接进去"的护栏 —— 与 signing_test 的
      // UI 接线断言同一思路。
      final src = File('lib/toolchain/build_runner.dart').readAsStringSync();
      expect(src.contains('ManifestCodec.hasIllegalShrinkCombo'), isTrue);
      expect(src.contains('ManifestCodec.fixIllegalShrinkCombo'), isTrue);
      expect(src.contains('_fixIllegalShrinkCombo'), isTrue);
      // Bug 636 的报错原文要点出来，用户才能对上号
      expect(src.contains('Removing unused resources'), isTrue);
      // 必须在 build 命令发出**之前**修（否则等于没修）
      final fixAt = src.indexOf('await _fixIllegalShrinkCombo(');
      final buildAt = src.indexOf('execStream(cmd');
      expect(fixAt > 0 && buildAt > 0 && fixAt < buildAt, isTrue,
          reason: '修 shrink 组合必须在启动构建之前 —— 晚了 AGP 已经拒绝了');
    });
  });
}
