import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Bug 440 / Bug 639：**platform/ 模板漂移门禁**。
///
/// ## 为什么需要这条门禁
///
/// `platform/` 下的文件是新工程脚手架的模板；FOA 自己的 `android/` 是
/// **同一份代码的活样本**。改一边**不会**让另一边报错。
///
/// 手册里记着这段：`platform/` 的 MainActivity.kt 落后了整整一个月，
/// 269 行 PTY 代码**一次都没进过构建目录**，而整个测试套件全绿。
///
/// 根因很朴素：当时的测试是**分别**断言两个文件"各含某些字符串"，
/// 而不是断言**两者相同**。一个文件多了东西、另一个没有——
/// 两边各自的断言都还是过的。
///
/// 所以这个文件**只做一件事**：逐字节比对。不分析语义、不看内容，
/// 因为"语义分析"正是当初漏掉它的原因。
///
/// ## 双保险
///
/// 同一份映射表也在 `tools/sync_platform.sh` 里（供手动修复用）。
/// 改映射表时**两边都要改**；下面有一条断言专门防止两者脱节。
void main() {
  group('Bug 639 · platform/ 模板不得漂移', () {
    /// 模板 → 实际被编译的那份。
    ///
    /// ⚠️ 只列**两份都应该存在的副本**：
    /// `platform/android/pty/foa_pty.c` 不在表里——它是 C 源码，编译产物
    /// 是 `assets/tools/foa_pty`（二进制，单向派生），没有第二份源码副本。
    const pairs = <({String tpl, String real, String why})>[
      (
        tpl: 'platform/android/MainActivity.kt',
        real: 'android/app/src/main/kotlin/dev/foa/flutter_on_android/'
            'MainActivity.kt',
        why: '主干 Kotlin 代码。Bug 440 就是它落后一个月',
      ),
      (
        tpl: 'platform/android/PtySession.kt',
        real: 'android/app/src/main/kotlin/dev/foa/flutter_on_android/'
            'PtySession.kt',
        why: 'PTY 会话封装，与 MainActivity 成对改动',
      ),
      (
        tpl: 'platform/android/AndroidManifest.xml',
        real: 'android/app/src/main/AndroidManifest.xml',
        why: '权限/组件声明。漂移会让新工程缺权限或组件',
      ),
      (
        tpl: 'platform/android/gradle.properties',
        real: 'android/gradle.properties',
        why: '堆预算与 JVM 参数。漂移会让新工程直接 OOM（Bug 469）',
      ),
    ];

    test('每一对都必须逐字节相同', () {
      for (final p in pairs) {
        final t = File(p.tpl);
        final r = File(p.real);
        expect(t.existsSync(), isTrue, reason: '模板缺失：${p.tpl}');
        expect(r.existsSync(), isTrue, reason: '实际文件缺失：${p.real}');

        final tc = t.readAsStringSync();
        final rc = r.readAsStringSync();
        if (tc == rc) continue;

        // 不一致时给出**定位信息**而不是干巴巴一句"不相等"——
        // 否则看到失败的人还得自己 diff。
        final tl = tc.split('\n');
        final rl = rc.split('\n');
        final n = tl.length < rl.length ? tl.length : rl.length;
        var firstDiff = -1;
        for (var i = 0; i < n; i++) {
          if (tl[i] != rl[i]) {
            firstDiff = i;
            break;
          }
        }
        final detail = firstDiff < 0
            ? '行数不同：模板 ${tl.length} 行，实际 ${rl.length} 行'
            : '首个差异在第 ${firstDiff + 1} 行：\n'
                '    模板： ${tl[firstDiff]}\n'
                '    实际： ${rl[firstDiff]}';
        fail('❌ ${p.why}\n'
            '  模板 ${p.tpl}\n'
            '  实际 ${p.real}\n'
            '  $detail\n'
            '  → 若改动是对的，跑：bash tools/sync_platform.sh --fix');
      }
    });

    test('两份文件都不能是空的（防空文件让 diff 假绿）', () {
      for (final p in pairs) {
        expect(File(p.tpl).readAsStringSync().trim().isNotEmpty, isTrue,
            reason: '${p.tpl} 是空文件——比"不一致"更糟，是误删');
        expect(File(p.real).readAsStringSync().trim().isNotEmpty, isTrue,
            reason: '${p.real} 是空文件');
      }
    });

    test('映射表与 tools/sync_platform.sh 保持一致（防两边脱节）', () {
      final sh = File('../tools/sync_platform.sh');
      expect(sh.existsSync(), isTrue,
          reason: 'tools/sync_platform.sh 不见了——它是手动修复入口，'
              '不该被删');
      final body = sh.readAsStringSync();
      for (final p in pairs) {
        expect(body.contains(p.tpl), isTrue,
            reason: 'sync_platform.sh 缺了 ${p.tpl} —— '
                '测试拦住了，脚本却修不了，两边必须同表');
        expect(body.contains(p.real), isTrue,
            reason: 'sync_platform.sh 缺了 ${p.real}');
      }
    });

    test('平台模板目录本身没被误删（防"把整棵树挪走"式事故）', () {
      // Bug 440 的反面：有人可能觉得"模板没用"就删掉。
      // 新工程脚手架依赖它，删了不会立刻报错——只是新建的工程缺功能。
      expect(Directory('platform/android').existsSync(), isTrue,
          reason: 'platform/android/ 是新建工程的模板来源，不能删');
      for (final f in ['MainActivity.kt', 'PtySession.kt', 'AndroidManifest.xml',
        'gradle.properties']) {
        expect(File('platform/android/$f').existsSync(), isTrue,
            reason: 'platform/android/$f 缺失 —— 新建的工程会少这个文件');
      }
    });
  });
}
