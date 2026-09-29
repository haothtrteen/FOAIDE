import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/project/keystore_store.dart';

/// 签名库（alpha.94）的守卫测试。
///
/// 这一组盯的是三件"写错了也能编译、但会造成实际损失"的事：
/// 1. 清单与 keystore **不在工程目录里**（进了工程会被 git 提交、
///    被源码导出带走——那是把私钥明文送人）；
/// 2. 导入流程**先验证口令再入库**（口令错就清掉刚拷进去的文件，
///    否则库里会躺一个永远打不开的条目）；
/// 3. keytool 的输出**随 locale 变化**，解析必须固定 locale 并兼容中英。
void main() {
  group('安全边界', () {
    test('清单与 keystore 都在 /root 下，不在工程目录', () {
      expect(KeystoreStore.dir.startsWith('/root/'), isTrue);
      expect(KeystoreStore.registryPath.startsWith('/root/'), isTrue);
      expect(KeystoreStore.dir.contains('/root/projects'), isFalse);
      expect(KeystoreStore.registryPath.contains('/root/projects'), isFalse);
    });

    test('清单写盘后 chmod 600', () {
      expect(KeystoreStore.saveScript(const []).contains('chmod 600'), isTrue);
    });

    test('导入的文件也 chmod 600', () {
      expect(KeystoreStore.importScript(src: '/root/imports/a.jks', dst: '/root/keystores/a.jks')
          .contains('chmod 600'), isTrue);
    });
  });

  group('id 安全化', () {
    test('空格与中文会被压掉（否则 cp 的路径会被拆词）', () {
      expect(KeystoreStore.safeId('正式 签名'), isNotEmpty);
      expect(KeystoreStore.safeId('正式 签名'), isNot(contains(' ')));
    });

    test('路径分隔符不能留（会变成子目录）', () {
      expect(KeystoreStore.safeId('../../etc/passwd'), isNot(contains('/')));
    });

    test('全被压空时给个兜底名', () {
      expect(KeystoreStore.safeId('！！！'), 'key');
    });
  });

  group('清单解析', () {
    test('空文本 / 坏 JSON 返回空表，不抛', () {
      expect(KeystoreStore.parse(''), isEmpty);
      expect(KeystoreStore.parse('not json at all'), isEmpty);
      expect(KeystoreStore.parse('{"a":1}'), isEmpty);
    });

    test('正常解析', () {
      final items = KeystoreStore.parse('''
[
  {"id":"demo","label":"正式","path":"/root/keystores/demo.jks",
   "alias":"key0","storePass":"p1","keyPass":"p2",
   "subject":"CN=demo","imported":false}
]
''');
      expect(items.length, 1);
      expect(items.first.display, '正式');
      expect(items.first.alias, 'key0');
      expect(items.first.imported, isFalse);
    });

    test('缺 id 或 path 的记录被丢掉（没有身份就用不了）', () {
      final items = KeystoreStore.parse('''
[
  {"id":"","path":"/x/a.jks"},
  {"id":"b","path":""},
  {"id":"c","path":"/x/c.jks","alias":"k"}
]
''');
      expect(items.length, 1);
      expect(items.first.id, 'c');
    });

    test('没有 label 时用 id 顶上', () {
      final items = KeystoreStore.parse(
          '[{"id":"abc","path":"/x/a.jks","alias":"k"}]');
      expect(items.first.display, 'abc');
    });
  });

  group('keytool 输出解析', () {
    test('英文 locale（Alias name:）', () {
      expect(KeystoreStore.parseAliases('Alias name: key0\nALIASES_END'),
          ['key0']);
    });

    test('中文 locale（别名：）也要认', () {
      // 不固定 locale 的话，中文环境下 sed 的英文前缀匹配不到，
      // 别名列表会整个空掉——用户看到"这个 keystore 里没有条目"。
      expect(KeystoreStore.parseAliases('别名: key0\nALIASES_END'), ['key0']);
      expect(KeystoreStore.parseAliases('别名：key0'), ['key0']);
    });

    test('多个别名都保留（让用户挑，别替他猜第一个）', () {
      expect(KeystoreStore.parseAliases('Alias name: a\nAlias name: b'),
          ['a', 'b']);
    });

    test('列别名的脚本必须带 -v（不带 -v 就没有 Alias name 行）', () {
      // 真机踩过的坑：keytool -list 不带 -v 时只打印
      // `key0, Sep 29, 2026, PrivateKeyEntry,` 这种一行摘要，
      // 根本没有 `Alias name:` 行 → grep 一条都匹配不到 →
      // 别名列表永远为空 → 写进 key.properties 的 keyAlias 是空串。
      // 这一条就是钉死回归：谁把 -v 删了，测试立刻红。
      final s = KeystoreStore.listAliasesScript(
          keystorePath: '/root/keystores/a.jks', storePass: 'p');
      expect(RegExp(r'keytool -list -v').hasMatch(s), isTrue);
      expect(RegExp(r'keytool -list(?! -v)').hasMatch(s), isFalse);
    });

    test('取证书主体 Owner', () {
      expect(KeystoreStore.subjectOf('Owner: CN=Android Debug, O=Android, C=US'),
          'CN=Android Debug, O=Android, C=US');
    });

    test('列别名的脚本固定了 LC_ALL=C', () {
      expect(KeystoreStore.listAliasesScript(
              keystorePath: '/root/keystores/a.jks', storePass: 'p')
          .contains('LC_ALL=C'), isTrue);
    });

    test('口令不对时报得出来（不静默失败）', () {
      final s = KeystoreStore.listAliasesScript(
          keystorePath: '/root/keystores/a.jks', storePass: 'p');
      // 脚本侧：rc 非 0 就 exit 2，并且把 keytool 的关键错误行摘出来
      // （直接 tail -n 1 会抓到 `... 7 more` 这种没用的尾巴）。
      expect(s.contains('exit 2'), isTrue);
      expect(s.contains('password was incorrect'), isTrue);
      // 报错那行必须**另起一行**。写成字面 `\\n` 的话 shell 会吃掉它，
      // echo 被拼成 `necho`，实测报错变成 `ERR=: not found`（没法看）。
      expect(s.contains('necho'), isFalse);
      expect(RegExp(r'tail -n 1\)\n').hasMatch(s), isTrue);
      // Dart 侧：英文原话翻成中文，手机用户才看得懂
      expect(
          KeystoreStore.friendlyError(
              'keytool error: java.io.IOException: Keystore was tampered with, '
              'or password was incorrect'),
          contains('口令不对'));
    });

    test('friendlyError 认得"口令不对"和"文件不存在"', () {
      expect(KeystoreStore.friendlyError('Keystore was tampered with, or '
          'password was incorrect'), contains('原文'));
      expect(
          KeystoreStore.friendlyError(
              'keytool error: java.io.FileNotFoundException: /x/a.jks '
              '(No such file or directory)'),
          contains('找不到'));
      expect(KeystoreStore.friendlyError('Certificate for <a> does not exist'),
          isNot(contains('找不到 keystore 文件')));
    });
  });

  group('debug keystore', () {
    final s = KeystoreStore.debugKeystoreScript();

    test('用 AOSP/Gradle 的公开约定参数', () {
      expect(s.contains('androiddebugkey'), isTrue);
      expect(s.contains('storepass android'), isTrue);
      expect(s.contains('CN=Android Debug'), isTrue);
    });

    test('已存在就不重新生成（否则会把别人正在用的 debug 钥匙换掉）', () {
      expect(RegExp(r'if \[ ! -f \$DK \]').hasMatch(s), isTrue);
      // 生成命令必须被这个判断包着，不能无条件跑
      expect(s.indexOf(RegExp(r'if \[ ! -f \$DK \]')),
          lessThan(s.indexOf('keytool -genkeypair')));
    });
  });

  group('UI 接线', () {
    final page = File('lib/project/manifest_page.dart').readAsStringSync();
    final panel = File('lib/project/build_panel.dart').readAsStringSync();
    final dlg = File('lib/project/signing_dialog.dart').readAsStringSync();

    test('清单页有签名库区与导入入口', () {
      expect(page.contains("import 'keystore_store.dart';"), isTrue);
      expect(page.contains('签名库（'), isTrue);
      expect(page.contains('_importKeystore'), isTrue);
      expect(page.contains('_useKeystore'), isTrue);
    });

    test('导入表单先问口令、别名由代码列（先问别名用户只能靠猜）', () {
      // 只看导入对话框那一段（同一个文件里还有"生成签名"对话框，
      // 那个**是要**问别名的，别把它算进来）
      final imp = dlg.split('class _SigningDialog').first;
      expect(imp.contains('showKeystoreImportDialog'), isTrue);
      expect(imp.contains('keystore 口令'), isTrue);
      expect(imp.contains('密钥口令'), isTrue);
      // 表单里不该有别名的输入框：别名要用口令从 keytool 读出来
      expect(imp.contains('_field(_alias'), isFalse);
      expect(imp.contains("'密钥别名'"), isFalse,
          reason: '别名不在表单里问——要用口令从 keytool 读出来');
    });

    test('口令输了错会清掉刚拷进去的文件（不留打不开的条目）', () {
      expect(page.contains('await KeystoreStore(ProotBridge()).delete(path)'),
          isTrue);
    });

    test('同 id 不覆盖（覆盖别人的钥匙不可逆）', () {
      expect(page.contains('_uniqueId'), isTrue);
    });

    test('打包区有「用 debug 签名重签」，且说明 debug 档本来就是 debug 签名', () {
      expect(panel.contains('用 debug 签名重签'), isTrue);
      expect(panel.contains('_resignDebug'), isTrue);
      expect(panel.contains('debug 档本来就是'), isTrue);
    });

    test('UI 上明说口令是明文存的（不假装加密）', () {
      expect(dlg.contains('明文'), isTrue);
    });
  });
}
