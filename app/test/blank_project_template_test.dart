import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/demo/blank_project_template.dart';
import 'package:foaide/demo/demo_project_creator.dart';
import 'package:foaide/env/models.dart';

/// 空白工程模板 · 包名动态化（alpha.62 审计修复）
///
/// 起因：模板脚本原来把包名写成 `com.example.$NAME`，且 Kotlin 源码目录名
/// 也硬编码成 `com/example/$NAME`。当时 [DemoProjectCreator.validateName]
/// 要求首字符是字母，所以"恰好"没事；但这属于**两个文件里的规则靠巧合对齐**，
/// 任一处放宽校验就会炸（`package com.example.1to2` 是非法 Java 包名，gradle
/// 直接编译失败，用户在容器日志里看半天也找不到根）。
///
/// 现在包名由 [demoAndroidIdentifier] 单点推导，脚本只做占位符替换，
/// 并在脚本末尾自查"包名三处一致"。
void main() {
  group('模板 · 包名推导是单点来源', () {
    test('普通名字直接拼前缀', () {
      expect(demoAndroidIdentifier('my_app'), 'com.example.my_app');
      expect(demoAndroidIdLastSegment('my_app'), 'my_app');
    });

    test('数字开头的名字被前置 a（Java 包名段不能以数字开头）', () {
      // 这是本次修复的核心：Dart 包名允许首字符是数字，Java 包名不允许。
      expect(demoAndroidIdentifier('1to2'), 'com.example.a1to2');
      expect(demoAndroidIdLastSegment('1to2'), 'a1to2');
    });

    test('名字里的下划线原样保留（Java 标识符允许）', () {
      expect(demoAndroidIdentifier('a_b_c'), 'com.example.a_b_c');
    });

    test('推导结果在任何输入下都是合法 Java 包名', () {
      // Java 包名段：字母开头，后跟字母/数字/下划线
      final seg = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');
      for (final n in ['a', '1', '1to2', '9_lives', 'z9', 'abc_def_123']) {
        final pkg = demoAndroidIdentifier(n);
        final parts = pkg.split('.');
        expect(parts.length, 3, reason: '$n → $pkg 段数不对');
        expect(parts[0], 'com');
        expect(parts[1], 'example');
        expect(seg.hasMatch(parts[2]), isTrue,
            reason: '$n → ${parts[2]} 不是合法 Java 标识符，'
                '会导致 package 声明编译失败');
      }
    });

    test('空名字不崩（返回裸前缀，调用方 validateName 会先拦）', () {
      expect(demoAndroidIdentifier(''), kDemoAndroidIdPrefix);
      expect(demoAndroidIdentifier('   '), kDemoAndroidIdPrefix);
    });

    test('前后空格被裁掉（否则会拼出 "name " 这样的非法包名）', () {
      expect(demoAndroidIdentifier(' my_app '), 'com.example.my_app');
    });
  });

  group('模板 · 脚本渲染后没有残留占位符', () {
    test('__NAME__ / __PKG__ 全部替换干净', () {
      for (final n in ['my_app', '1to2']) {
        final s = blankProjectScript(n);
        expect(s.contains('__NAME__'), isFalse, reason: '$n 残留 __NAME__');
        expect(s.contains('__PKG__'), isFalse, reason: '$n 残留 __PKG__');
      }
    });

    test('项目名与包名是两个独立变量（不相等时才暴露硬编码）', () {
      final s = blankProjectScript('1to2');
      expect(s.contains("NAME='1to2'"), isTrue);
      expect(s.contains("PKG='com.example.a1to2'"), isTrue,
          reason: r'包名若仍拼 $NAME 会写死成 com.example.1to2');
    });
  });

  group('模板 · Kotlin 源码目录与包名逐段对应', () {
    test('目录用 PKGHEAD/PKGLAST 推导，不硬编码 com/example/<name>', () {
      final s = blankProjectScript('1to2');
      expect(s.contains(r'$PKGHEAD/$PKGLAST'), isTrue,
          reason: '目录必须从包名反推，否则包名改了目录跟不上');
      expect(s.contains(r'com/example/$NAME'), isFalse,
          reason: r'硬编码的 com/example/$NAME 会在包名被改写时错位');
      // 逐行看：只在**代码行**上要求不出现字面量目录（注释里举例子不算）。
      for (final line in s.split('\n')) {
        if (line.trimLeft().startsWith('#')) continue;
        expect(line.contains('com/example/'), isFalse,
            reason: '代码行仍出现字面量目录：$line');
      }
    });

    test('脚本里同步定义了 PKGHEAD / PKGLAST', () {
      final s = blankProjectScript('my_app');
      expect(s.contains(r'PKGHEAD="${PKG%.*}"'), isTrue);
      expect(s.contains(r'PKGLAST="${PKG##*.}"'), isTrue);
    });

    test('脚本自查三处包名一致（构建期才发现就太晚了）', () {
      final s = blankProjectScript('my_app');
      expect(s.contains('MainActivity.kt 路径与包名不符'), isTrue);
      expect(s.contains('MainActivity.kt 包名未生效'), isTrue);
    });
  });

  group('模板 · 与项目名校验规则的边界一致', () {
    test('validateName 当前的严格度下，普通名字不会被加 a', () {
      // 反之：若将来放宽到允许数字开头，这里断言会提醒同步包名规则
      for (final n in ['my_app', 'a1', 'abc']) {
        expect(DemoProjectCreator.validateName(n), isNull);
        expect(demoAndroidIdentifier(n), 'com.example.$n');
      }
    });

    test('即便校验放宽，包名推导也兜得住（防未来回归）', () {
      expect(DemoProjectCreator.validateName('1to2'), isNotNull,
          reason: '当前拒绝数字开头；若这里变 null 说明校验放宽了，'
              '那时 demoAndroidIdentifier 的 a 前缀就是唯一防线');
      expect(demoAndroidIdentifier('1to2'), isNot('com.example.1to2'));
    });
  });

  group('EnvInfo · 包名由原生运行时提供', () {
    test('packageName 从 map 解析（Dart 不自己拼 /data/data/<pkg>）', () {
      final env = EnvInfo.fromMap(const {
        'filesDir': '/data/user/0/com.foo.bar/files',
        'packageName': 'com.foo.bar',
        'rootfsPath': '/data/user/0/com.foo.bar/files/rootfs/debian',
        'rootfsInstalled': true,
      });
      expect(env.packageName, 'com.foo.bar');
    });

    test('缺字段时降级空串而不是崩（老版本原生壳兼容）', () {
      final env = EnvInfo.fromMap(const {'filesDir': '/x'});
      expect(env.packageName, '');
    });
  });

  group('模板 · 脚本保持 POSIX sh 兼容', () {
    test('没有 bashism（脚本跑在容器 dash 下）', () {
      final s = blankProjectScript('my_app');
      expect(s.contains('[['), isFalse, reason: '[[ ]] 是 bash 专有');
      expect(s.contains('&>'), isFalse);
      expect(s.contains('<<<'), isFalse, reason: 'here-string 是 bash 专有');
      expect(RegExp(r'^\s*function\s', multiLine: true).hasMatch(s), isFalse);
      expect(s.contains(r'$RANDOM'), isFalse);
    });

    test('脚本内容里没有未转义的单引号（模板用 r\'\'\' 包裹）', () {
      // replaceAll 只允许替换 __NAME__/__PKG__ 这类占位符，
      // 若项目名含单引号会破坏 shell 引号配对——validateName 已挡住，
      // 这里记录该前提。
      expect(DemoProjectCreator.validateName("o'brien"), isNotNull);
    });
  });

  group('模板 · 脚本不是空壳', () {
    test('关键步骤都在（SDK 模板渲染 + 镜像 + wrapper）', () {
      final s = blankProjectScript('my_app');
      expect(s.contains('/opt/flutter'), isTrue);
      expect(s.contains('gradle_utils.dart'), isTrue, reason: '版本要从 SDK 解析');
      expect(s.contains('mirrors.cloud.tencent.com/gradle'), isTrue);
      expect(s.contains('gradle-wrapper.jar'), isTrue);
      expect(s.contains('BLANK_OK'), isTrue);
    });

    test('渲染出的脚本能被 dash 做语法检查（真机同样跑 dash）', () {
      final s = blankProjectScript('my_app');
      final tmp = File('${Directory.systemTemp.path}/foa_blank_syntax_check.sh')
        ..writeAsStringSync(s);
      final r = Process.runSync('dash', ['-n', tmp.path]);
      expect(r.exitCode, 0,
          reason: 'dash -n 失败说明脚本有 POSIX 语法错误：${r.stderr}');
      tmp.deleteSync();
    });
  });
}
