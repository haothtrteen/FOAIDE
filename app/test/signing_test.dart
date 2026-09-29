import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/project/signing.dart';

/// 正式签名守卫（alpha.93）。
///
/// 重点在两处**改了就出事**的地方：
/// 1. 构建脚本补丁——改错了不会编译报错，只会让用户下次构建炸在
///    gradle 里，而那时他早忘了是自己点了"配置签名"；
/// 2. 脚本拼装——keytool/apksigner 的失败分支如果没接住，
///    用户看到的就是一句无意义的"退出码 1"。
void main() {
  /// Flutter 3.47 `flutter create` 真模板（android-kotlin，去掉注释后）。
  const ktsTemplate = '''
plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.demo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.example.demo"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
''';

  /// 老版本 Flutter（Groovy DSL）模板的对应片段。
  const groovyTemplate = '''
android {
    namespace "com.example.demo"
    compileSdk flutter.compileSdkVersion

    defaultConfig {
        applicationId "com.example.demo"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.debug
        }
    }
}
''';

  group('key.properties', () {
    test('四行都在，storeFile 是绝对路径', () {
      final s = Signing.keyProperties(
        storeFile: '/root/keystores/demo.jks',
        storePassword: 'sp',
        keyPassword: 'kp',
        keyAlias: 'demo',
      );
      expect(s, contains('storePassword=sp'));
      expect(s, contains('keyPassword=kp'));
      expect(s, contains('keyAlias=demo'));
      expect(s, contains('storeFile=/root/keystores/demo.jks'));
      expect(s.startsWith('storeFile='), isFalse,
          reason: 'gradle 的 file() 相对基准是 android/，必须绝对路径');
    });

    test('keystore 放在 /root/keystores，不在工程目录里', () {
      expect(Signing.keystorePathFor('demo'), '/root/keystores/demo.jks');
      expect(Signing.keystorePathFor('demo'), isNot(contains('/root/projects')),
          reason: '放工程里会被 git add -A 提交、会被导出源码工程带走');
    });
  });

  group('随机密码', () {
    test('长度够、两次不一样、不含易混字符', () {
      final a = Signing.randomPassword();
      final b = Signing.randomPassword();
      expect(a.length, 16);
      expect(a, isNot(b));
      expect(Signing.randomPassword(len: 24).length, 24);
      for (final c in ['0', '1', 'l', 'I', 'O']) {
        expect(a.contains(c), isFalse, reason: '去掉 $c 这类手抄容易错的字符');
      }
    });
  });

  group('构建脚本补丁 · Kotlin DSL（3.47 默认）', () {
    test('三处都改到位', () {
      final p = Signing.patchGradle(ktsTemplate, kotlinDsl: true);
      expect(p.ok, isTrue, reason: p.reason);
      // 1) 属性读取块插在 android { 之前
      expect(p.text.indexOf('val keystoreProperties'),
          lessThan(p.text.indexOf('android {')));
      // 2) signingConfigs 插在 buildTypes 之前（要先定义才能引用）
      expect(p.text.indexOf('signingConfigs {'),
          lessThan(p.text.indexOf('buildTypes {')));
      // 3) release 变体换成正式签名
      expect(p.text, isNot(contains('getByName("debug")')));
      expect(p.text, contains('signingConfig = signingConfigs.getByName("release")'));
    });

    test('import 写在文件最前面（Kotlin 的硬性要求）', () {
      final p = Signing.patchGradle(ktsTemplate, kotlinDsl: true);
      expect(p.text, startsWith('import java.util.Properties'));
      expect(p.text.indexOf('import java.io.FileInputStream'),
          lessThan(p.text.indexOf('plugins {')));
    });

    // ⚠️ alpha.95 回归：**全限定名 `java.util.*` 在带 plugins {} 的脚本里必挂**。
    //
    // 真机报错（用户工程 /root/projects/list）：
    //   e: build.gradle.kts:10:31: Unresolved reference 'util'.
    //      val keystoreProperties = java.util.Properties()
    //   e: build.gradle.kts:13:34: Unresolved reference 'io'.
    //
    // 沙箱对照实测（三种写法）：
    //   无 plugins 块 + java.util.Properties()          → ✅
    //   有 plugins 块 + java.util.Properties()          → ❌ Unresolved 'util'
    //   有 plugins 块 + import 后写 Properties()        → ✅
    //
    // 而 Flutter 模板第一行就是 plugins {}，所以旧写法 100% 必挂。
    // 这条断言把"不许再用全限定名"钉死。
    test('补丁里不得出现 java.util / java.io 全限定名（会 Unresolved）', () {
      final p = Signing.patchGradle(ktsTemplate, kotlinDsl: true);
      // 只看**用法**，不看 import 行本身（import 当然要写全限定名）。
      final body = p.text
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('import '))
          .join('\n');
      expect(body.contains('java.util.'), isFalse,
          reason: 'java 在 plugins {} 之后会被当成 JavaPluginExtension，'
              '全限定名解析不了 —— 必须靠文件顶部的 import 用简单名');
      expect(body.contains('java.io.'), isFalse,
          reason: '同上（这条 bug 让用户工程的 debug 构建 100% 失败）');
      // 用简单名，且 import 在位
      expect(p.text, contains('val keystoreProperties = Properties()'));
      expect(p.text, contains('keystoreProperties.load(FileInputStream('));
    });

    // ========================================================================
    // alpha.96：修好生成器 ≠ 修好用户现场。
    //
    // 真机反馈：用户用 alpha.94 之前的版本打过补丁，之后**反复构建**
    // 都报同一句 `Unresolved reference 'util'`，而 FOA 这边看起来
    // "早就修了"。因为：
    //   ① 补丁是**写进用户工程文件**的，不是每次构建现生成的；
    //   ② `patchGradle` 的守卫是"已有 signingConfigs 就不动"，
    //      对老工程直接返回失败 → 老写法原封不动留在文件里。
    //
    // 所以加了这套「检测 + 升级」。
    // ========================================================================

    /// 老补丁的长相（alpha.94 之前生成的）。
    const legacyPatched = '''
plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = java.util.Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(java.io.FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.demo"
    signingConfigs {
        release {
            keyAlias = keystoreProperties["keyAlias"] as String
        }
    }
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}
''';

    group('alpha.96 · 老补丁（java.util 全限定名）能被识别并修好', () {
      test('hasLegacyJavaFqn 认得出来', () {
        expect(Signing.hasLegacyJavaFqn(legacyPatched), isTrue);
        // 光有 import 行不算"老写法"（import 里当然写全限定名）
        expect(
          Signing.hasLegacyJavaFqn('import java.util.Properties\n'
              'val p = Properties()\n'),
          isFalse,
          reason: '只看用法不看 import 行 —— 否则新写的补丁也会被误判成老的',
        );
        expect(Signing.hasLegacyJavaFqn(ktsTemplate), isFalse);
      });

      test('upgradeLegacyJavaFqn 换成简单名 + 补 import（幂等）', () {
        final fixed = Signing.upgradeLegacyJavaFqn(legacyPatched);
        final body = fixed
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('import '))
            .join('\n');
        expect(body.contains('java.util.'), isFalse);
        expect(body.contains('java.io.'), isFalse);
        expect(fixed, contains('val keystoreProperties = Properties()'));
        expect(fixed, contains('keystoreProperties.load(FileInputStream('));
        // import 必须补上，否则简单名也解析不了
        expect(fixed, contains('import java.util.Properties'));
        expect(fixed, contains('import java.io.FileInputStream'));
        // 幂等：再跑一遍不该长出第二份 import
        final twice = Signing.upgradeLegacyJavaFqn(fixed);
        expect('import java.util.Properties'.allMatches(twice).length, 1);
        expect('import java.io.FileInputStream'.allMatches(twice).length, 1);
      });

      test('patchGradle 先修老写法再走原逻辑（不因守卫而漏修）', () {
        final p = Signing.patchGradle(legacyPatched, kotlinDsl: true);
        // 已有 signingConfigs → 守卫照常拦住完整补丁
        expect(p.ok, isFalse,
            reason: '不重复插入 signingConfigs 这条守卫要保留');
        // 但**老写法必须在返回的文本里已经被修掉**
        //
        // ⚠️ 这一条是本次修复的核心：原实现遇到守卫就直接 return，
        //    老写法原封不动 —— 那正是用户反复报错的根源。
        final body = p.text
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('import '))
            .join('\n');
        expect(body.contains('java.util.'), isFalse,
            reason: '守卫拦住完整补丁时，也**不能**把老写法留着');
      });

      test('Groovy DSL 不碰（那边 java.util.Properties() 合法）', () {
        const g = '''
plugins { id 'com.android.application' }
val keystoreProperties = java.util.Properties()
''';
        // Groovy 里这么写是合法的，不该被"修"
        expect(Signing.hasLegacyJavaFqn(g), isTrue, reason: '检测函数只看文本');
        // 但 patchGradle 在 groovy 分支不该改写它
        final p = Signing.patchGradle(groovyTemplate, kotlinDsl: false);
        expect(p.text.contains('java.util.'), isFalse,
            reason: 'Groovy 模板本来就没有全限定名，这里只是确认没被引入');
      });

      // UI 接线：检测到老补丁要给**可点的修复入口**。
      // 不给入口的话，用户仍然只能"重新生成签名"（会换掉密钥），
      // 或者自己去找 build.gradle.kts 手改 —— 两条路都很糟。
      test('UI：清单页检测老补丁并给出「修复构建脚本」入口', () {
        final page = File('lib/project/manifest_page.dart').readAsStringSync();
        expect(page.contains('Signing.hasLegacyJavaFqn'), isTrue,
            reason: '打开清单页时要检测，不能等用户自己发现');
        expect(page.contains('_hasLegacyGradle'), isTrue);
        expect(page.contains('_repairGradle'), isTrue);
        expect(page.contains('修复构建脚本'), isTrue);
        // 修复走的是**独立**方法，不能并进 _genKeystore ——
        // 那个会重新生成 keystore，等于逼用户换钥匙。
        expect(page.contains('Signing.repairLegacyPatch'), isTrue);
        expect(page.contains('不会动你的密钥'), isTrue,
            reason: '要让用户放心点：这不是换钥匙');
      });
    });

    test('缩进跟随 buildTypes，不写死', () {
      final p = Signing.patchGradle(ktsTemplate, kotlinDsl: true);
      expect(p.text, contains('    signingConfigs {\n'));
      expect(p.text, contains('        create("release") {\n'));
    });

    test('create("release") 而不是 getByName', () {
      final p = Signing.patchGradle(ktsTemplate, kotlinDsl: true);
      expect(p.text, contains('create("release")'),
          reason: 'kts 里 signingConfigs 是 NamedDomainObjectContainer，'
              '新增必须用 create');
    });
  });

  group('构建脚本补丁 · Groovy DSL（老工程）', () {
    test('同样改到位，且不掺 Kotlin 语法', () {
      final p = Signing.patchGradle(groovyTemplate, kotlinDsl: false);
      expect(p.ok, isTrue, reason: p.reason);
      expect(p.text, contains('def keystoreProperties = new Properties()'));
      expect(p.text, contains('signingConfigs {\n        release {'));
      expect(p.text, contains('signingConfig = signingConfigs.release'));
      expect(p.text, isNot(contains('import ')));
      expect(p.text, isNot(contains('create("release")')));
    });
  });

  group('构建脚本补丁 · 不敢改就直接拒绝', () {
    test('已经接过签名的不重复改', () {
      final once = Signing.patchGradle(ktsTemplate, kotlinDsl: true).text;
      final twice = Signing.patchGradle(once, kotlinDsl: true);
      expect(twice.ok, isFalse);
      expect(twice.reason, contains('已经有 signingConfigs'),
          reason: '重复插入会让 gradle 报重复定义');
    });

    test('找不到 android 块就不动', () {
      final p = Signing.patchGradle('plugins { }\n', kotlinDsl: true);
      expect(p.ok, isFalse);
      expect(p.reason, contains('android'));
    });

    test('找不到 buildTypes 就不动', () {
      final src = ktsTemplate.replaceAll('buildTypes', 'productFlavors');
      final p = Signing.patchGradle(src, kotlinDsl: true);
      expect(p.ok, isFalse);
      expect(p.reason, contains('buildTypes'));
    });

    test('release 那行被改过写法的就拒绝，并指路产物签名', () {
      final src = ktsTemplate.replaceAll(
          'signingConfig = signingConfigs.getByName("debug")',
          'signingConfig = null');
      final p = Signing.patchGradle(src, kotlinDsl: true);
      expect(p.ok, isFalse);
      expect(p.reason, contains('已产出的 APK 签名'),
          reason: '拒绝的同时必须给一条能走通的替代路径');
    });

    test('DSL 认错也会拒绝（kts 内容按 groovy 处理）', () {
      final p = Signing.patchGradle(ktsTemplate, kotlinDsl: false);
      expect(p.ok, isFalse,
          reason: '拿 kts 找 groovy 的锚点必然找不到，宁可不动也不能瞎改');
    });
  });

  group('keytool 脚本', () {
    String script({bool force = false}) => Signing.keytoolScript(
          keystorePath: '/root/keystores/demo.jks',
          alias: 'demo',
          storePass: 'sp',
          keyPass: 'kp',
          dname: 'CN=FOA, O=FOA, C=CN',
          force: force,
        );

    test('默认不覆盖已有 keystore', () {
      expect(script(), contains('EXISTING='));
      expect(script(), contains('exit 0'),
          reason: '覆盖会让已装出去的旧版本再也升不了级，必须默认挡住');
    });

    test('force 才删除重建', () {
      expect(script(force: true), contains('rm -f'));
      expect(script(force: true), isNot(contains('EXISTING=')));
    });

    test('口令与路径都走单引号，且用容器 JDK', () {
      expect(script(), contains('/opt/jdk/bin/keytool'));
      expect(script(), contains("-storepass 'sp'"));
      expect(script(), contains("-dname 'CN=FOA, O=FOA, C=CN'"));
      expect(script(), contains("-alias 'demo'"));
    });

    test('JDK 缺失时报的是人话', () {
      expect(script(), contains('ERR=容器里没有 keytool'));
    });

    test('RSA 2048 + 长有效期', () {
      expect(script(), contains('-keyalg RSA -keysize 2048'));
      expect(script(), contains('-validity 10000'),
          reason: 'Google Play 要求证书有效期到 2033 年之后');
    });
  });

  group('apksigner 脚本', () {
    String script() => Signing.signApkScript(
          apkIn: '/root/projects/demo/build/app.apk',
          keystorePath: '/root/keystores/demo.jks',
          alias: 'demo',
          storePass: 'sp',
          keyPass: 'kp',
        );

    test('顺序必须是 zipalign → sign → verify', () {
      final s = script();
      final z = s.indexOf('zipalign');
      final g = s.indexOf('apksigner sign');
      final v = s.indexOf('apksigner verify');
      expect(z, lessThan(g), reason: '签完再对齐会把 v2/v3 签名弄坏');
      expect(g, lessThan(v));
    });

    test('apksigner 是原地签（--out 与输入同路径会被拒）', () {
      expect(script(), isNot(contains('--out')),
          reason: '先对齐复制到目标文件，再原地签');
    });

    test('输出落到 -signed.apk，不覆盖原包', () {
      expect(script(), contains('/root/projects/demo/build/app-signed.apk'));
    });

    test('口令走 pass: 前缀，不弹交互', () {
      expect(script(), contains('--ks-pass pass:\'sp\''));
      expect(script(), contains('--key-pass pass:\'kp\''));
    });

    test('验签脚本带 -v 才能看出用了哪些签名方案', () {
      expect(Signing.verifyScript('/x.apk'), contains('apksigner verify -v'));
    });
  });

  group('key.properties 解析（唯一真源）', () {
    test('四项齐全才认', () {
      final c = Signing.configFrom(''
          'storePassword=sp\n'
          'keyPassword=kp\n'
          'keyAlias=demo\n'
          'storeFile=/root/keystores/demo.jks\n');
      expect(c, isNotNull);
      expect(c!.keyAlias, 'demo');
      expect(c.storeFile, '/root/keystores/demo.jks');
      expect(c.storePassword, 'sp');
      expect(c.keyPassword, 'kp');
    });

    test('缺一项就当没配', () {
      expect(Signing.configFrom('keyAlias=demo\nstoreFile=/x.jks\n'), isNull,
          reason: '少口令的话 gradle 读到一半会失败，'
              '宁可显示"未配置"也不能让按钮点了白点');
      expect(Signing.configFrom(''), isNull);
    });

    test('忽略注释与空行，等号两边去空格', () {
      final m = Signing.parseKeyProperties(
          '# 注释\n\nkeyAlias = demo \nstoreFile=/x.jks\n');
      expect(m['keyAlias'], 'demo');
      expect(m['storeFile'], '/x.jks');
      expect(m.containsKey('# 注释'), isFalse);
    });
  });

  group('生成参数校验', () {
    SigningPlan plan({String alias = 'demo', String sp = 'abcdef', String kp = 'abcdef', String cn = 'demo'}) =>
        SigningPlan(alias: alias, storePass: sp, keyPass: kp, cn: cn, org: 'demo', country: 'CN');

    test('合法参数无问题', () {
      expect(plan().problem, isNull);
    });

    test('口令太短要给出具体长度', () {
      expect(plan(sp: '123').problem, contains('6'));
      expect(plan(kp: '12345').problem, contains('密钥口令'));
    });

    test('别名与 CN 不能为空', () {
      expect(plan(alias: '  ').problem, contains('别名'));
      expect(plan(cn: '').problem, contains('CN'));
    });

    test('dname 拼成 keytool 要的格式', () {
      expect(plan().dname, 'CN=demo, O=demo, C=CN');
    });
  });

  group('验签结果判读', () {
    test('认得出 debug 证书', () {
      expect(Signing.isDebugSignature('Signer #1 certificate DN: CN=Android Debug, O=Android, C=US'),
          isTrue);
      expect(Signing.isDebugSignature('CN=FOA, O=FOA, C=CN'), isFalse);
    });

    test('抽得出签名方案', () {
      const out = 'Verifies using v1 scheme (JAR signing): true\n'
          'Verifies using v2 scheme (APK Signature Scheme v2): true\n'
          'Verifies using v3 scheme (APK Signature Scheme v3): false';
      expect(Signing.schemesOf(out), ['V1', 'V2']);
      expect(Signing.schemesOf('nothing'), isEmpty);
    });
  });

  group('UI 接线（编译得过但功能静默失效的那类）', () {
    String code(String rel) => File(rel)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('清单页的签名卡有真正的生成入口，不只是"查看 build.gradle"', () {
      final s = code('lib/project/manifest_page.dart');
      expect(s, contains('生成并配置签名'));
      expect(s, contains('_genKeystore'));
      expect(s, contains('Signing.generateKeystore'),
          reason: '以前这张卡只会打开文件，等于让用户自己去跑 keytool');
    });

    test('清单页能备份 keystore（丢了就发不了升级包）', () {
      final s = code('lib/project/manifest_page.dart');
      expect(s, contains('_exportKeystore'));
      expect(s, contains('FileBrowserBridge().export'));
    });

    test('写入 key.properties 会把明文口令挡在版本库外', () {
      final s = File('lib/project/signing.dart').readAsStringSync();
      expect(s, contains('_ensureGitIgnored'),
          reason: 'alpha.93 刚加了"一键全选提交"的 Git 面板，'
              '明文口令被提交的风险从"可能"变成"迟早"');
    });

    test('打包区有验签入口', () {
      final s = code('lib/project/build_panel.dart');
      expect(s, contains('_verifySignature'));
      expect(s, contains("验签"));
    });

    test('打包区有"对产物重签"入口（补丁拒绝时的替代路径）', () {
      final s = code('lib/project/build_panel.dart');
      expect(s, contains('_resign'));
      expect(s, contains('Signing.signApk'));
    });

    test('生成对话框存在且接进清单页', () {
      final s = code('lib/project/manifest_page.dart');
      expect(s, contains("import 'signing_dialog.dart';"));
      expect(s, contains('showSigningDialog'));
    });
  });

  group('真实模板回归（防止以后改模板/改补丁两边脱节）', () {
    test('本机 Flutter 的 kts 模板能被补丁吃下', () {
      // 沙箱里装的那份 Flutter 就是容器里同一系列；模板变了我们能立刻知道。
      const candidates = [
        '/opt/flutter/packages/flutter_tools/templates/app/android-kotlin.tmpl/app/build.gradle.kts.tmpl',
        '/opt/flutter/packages/flutter_tools/templates/app/android-java.tmpl/app/build.gradle.kts.tmpl',
      ];
      final f = candidates.map(File.new).firstWhere(
        (f) => f.existsSync(),
        orElse: () => File(candidates.first),
      );
      if (!f.existsSync()) {
        // 找不到模板就跳过（不假绿：markTestSkipped 而不是 expect(true)）。
        markTestSkipped('本机没有 Flutter 模板，跳过');
        return;
      }
      final src = f
          .readAsStringSync()
          .replaceAll('{{androidIdentifier}}', 'com.example.demo');
      final p = Signing.patchGradle(src, kotlinDsl: true);
      expect(p.ok, isTrue, reason: '真模板都过不了，说明补丁和模板脱节了：${p.reason}');
      expect(p.text, contains('getByName("release")'));
    });
  });

  // ========================================================================
  // Bug 638（alpha.99）：老写法检测必须也进**构建前置检查**
  // ========================================================================
  //
  // 背景：alpha.96 把检测/升级做成了清单页的按钮。但 README 自己承认过一条
  // 诚实边界 —— "用户若从不打开清单页、直接用打包区构建，仍会撞上老写法"。
  // 本轮把这个缺口补上：构建前也检测一次。
  //
  // 这个组存在的意义：**纯逻辑（hasLegacyJavaFqn 那套）早有 5 条断言覆盖，
  // 但它"有没有被接进构建"从来没被钉过** —— 这正是它拖到现在的形式。
  group('Bug 638 · 老写法检测接入构建前置检查', () {
    final src = File('lib/toolchain/build_runner.dart').readAsStringSync();

    test('构建前的检查链上必须有 repairLegacyPatch', () {
      final at = src.indexOf('Signing.repairLegacyPatch');
      expect(at > 0, isTrue,
          reason: '构建前置检查里没有老写法修复 —— 用户直接点打包仍会撞 '
              "Unresolved reference 'util'");
    });

    test('顺序：必须在 execStream(cmd 之前（晚了 gradle 已经开始跑了）', () {
      final fixAt = src.indexOf('Signing.repairLegacyPatch');
      final runAt = src.indexOf('execStream(cmd');
      expect(runAt > 0, isTrue);
      expect(fixAt < runAt, isTrue,
          reason: '修复必须在启动构建之前 —— 晚了 gradle 已经报错了');
    });

    test('与 Bug 636 的 shrink 检查同处前置段，且都在构建之前', () {
      final shrinkAt = src.indexOf('_fixIllegalShrinkCombo(');
      final legacyAt = src.indexOf('Signing.repairLegacyPatch');
      final runAt = src.indexOf('execStream(cmd');
      expect(shrinkAt > 0 && legacyAt > 0, isTrue);
      // 两个检查谁先谁后无所谓，但都必须早于构建启动
      expect(shrinkAt < runAt, isTrue);
      expect(legacyAt < runAt, isTrue);
    });

    test('无变化时不产生日志噪音（changed == false 才静默）', () {
      // 判据必须是 r.changed，不能只看 r.msg 非空 ——
      // repairLegacyPatch 在"没事"时会返回 msg（如 '构建脚本没有老写法'），
      // 若按 msg 判就会**每次构建都打一行警告**。
      expect(
        RegExp(r'if\s*\(\s*r\.changed\s*\)').hasMatch(src),
        isTrue,
        reason: '必须按 changed 判定，否则每次构建都会刷无意义警告',
      );
    });

    test('Groovy 工程不该被改（repairLegacyPatch 内部已挡，此处固化契约）', () {
      // Groovy 里 `java.util.Properties()` 是合法写法，没有 Kotlin 的遮蔽问题。
      // 这条固化"我们不误改 Groovy 工程"的契约。
      const groovy = "android {\n  signingConfigs {\n"
          "    release {\n      storeFile file('a.jks')\n    }\n  }\n}\n";
      expect(Signing.hasLegacyJavaFqn(groovy), isFalse);
    });
  });
}
