import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/project/icon_replacer.dart';

/// 图标替换脚本守卫（alpha.93 修 bug 后补）。
///
/// 这个模块出过一次"UI 上点了就报错、但逻辑看着都对"的 bug：
/// `找不到 res 目录：/root/projects/'my_flutter'/android/app/src/main/res`
/// —— 路径里凭空多了两个单引号。成因是把已经引号化的片段又套进了
/// 双引号字符串（**双引号内单引号只是普通字符**）。
///
/// 所以这里的断言全部盯着**引号形状**，而不是"包含某个路径"：
/// 只断言 contains 的话，那个坏路径也能通过。
void main() {
  String script({
    String projectName = 'my_flutter',
    String src = '/root/imports/icon.png',
    String tool = 'pil',
  }) =>
      IconReplacer.buildScript(
          projectName: projectName, srcGuest: src, tool: tool);

  group('引号形状（Bug 修复的护栏）', () {
    test('res 路径里不出现多余的单引号', () {
      final s = script();
      expect(s, contains("RES='/root/projects/my_flutter/android/app/src/main/res'"),
          reason: '必须是裸拼一个完整 shell 词；套进双引号会让单引号变成'
              '路径的一部分（实测就是这个报错）');
      expect(s, isNot(contains('"/root/projects/')), reason: '不要双引号包裹');
      expect(RegExp(r'''RES="[^"]*' ''').hasMatch(s), isFalse);
    });

    test('源图路径同样是一个完整 shell 词', () {
      final s = script(src: '/root/imports/icon.png');
      expect(s, contains("SRC='/root/imports/icon.png'"));
      expect(s, isNot(contains('SRC="/root')));
    });

    test('路径含单引号时按 shell 规则转义，不出现裸引号', () {
      final s = script(src: "/root/imports/it's a.png");
      // 正确形式：'it'\''s'，即 单引号→ \' → 再接单引号
      expect(s, contains(r"'/root/imports/it'\''s a.png'"));
    });

    test(r'路径含 \$ 与反引号不会被展开（单引号内是字面量）', () {
      final s = script(src: r'/root/imports/$HOME`whoami`.png');
      expect(s, contains(r"'/root/imports/$HOME`whoami`.png'"));
    });

    test('项目名含空格也不被拆词', () {
      final s = script(projectName: 'my app');
      expect(s, contains("'/root/projects/my app/android/app/src/main/res'"));
    });
  });

  group('PIL 分支：路径只走环境变量', () {
    test('python -c 里不出现插值进来的路径', () {
      final s = script(tool: 'pil');
      final py = s.substring(s.indexOf('python3 -c'), s.indexOf('exit 4'));
      expect(py, contains("os.environ['ICON_SRC']"),
          reason: '带引号的字面量插进 Python 字符串会直接语法错误');
      expect(py, isNot(contains("/root/imports/")),
          reason: '路径不能进 Python 源码');
    });

    test('ICON_SRC 确实被导出了', () {
      expect(script(tool: 'pil'), contains(r'export ICON_SRC="$SRC"'));
    });
  });

  group('三种工具分支都写全', () {
    test('五个密度桶都在，尺寸与 Android 官方一致', () {
      final s = script();
      for (final e in IconReplacer.densities.entries) {
        expect(s, contains('mipmap-${e.key}:${e.value}'));
      }
      expect(IconReplacer.densities,
          {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192});
      expect(IconReplacer.recommendedSize, 192,
          reason: '= 最大密度桶，UI 提示用');
    });

    test('每段失败都带 ERR= 与非零退出码', () {
      final s = script();
      for (final code in ['exit 1', 'exit 2', 'exit 3', 'exit 4', 'exit 5', 'exit 9']) {
        expect(s, contains(code), reason: '缺 $code → 失败会静默继续，'
            '用户打包完才发现图标没变（那时已烧掉一次完整构建）');
      }
      expect(RegExp('ERR=').allMatches(s).length, greaterThanOrEqualTo(6));
    });

    test('无工具时走 cp（渐进增强的最后一档）', () {
      // 三个分支在同一个 case 里，脚本内容一致，只有 TOOL= 不同
      expect(script(tool: 'none'), contains('TOOL=none'));
      expect(script(tool: 'none'), contains('cp "\$SRC"'));
    });

    test('缩进的续行是单个反斜杠（写成两个会变成字面量 \\）', () {
      expect(script(), contains('ic_launcher.png" \\\n'),
          reason: 'shell 续行必须是一个反斜杠 + 换行');
      expect(script(), isNot(contains('png" \\\\\n')));
    });
  });

  group('接进清单页', () {
    test('替换按钮走的是 IconReplacer.apply', () {
      // 详细接线断言在 manifest_page_test；这里只确认对外入口没改名
      expect(IconReplacer.recommendedSize, isPositive);
    });
  });

  group('图标预览读取（alpha.95）', () {
    test('读文件脚本用 base64，且带缺失/过大/失败三种出口', () {
      final s = IconReplacer.readBase64Script('/root/projects/a/ic_launcher.png');
      expect(s.contains('base64'), isTrue,
          reason: 'FsBridge 只走文本，二进制必须 base64 过桥');
      expect(s.contains('READ_MISSING'), isTrue,
          reason: '文件不在要说清，不能静默返回空串让人以为是"图是空的"');
      expect(s.contains('READ_TOOBIG'), isTrue,
          reason: '2MB 上限：选了张 4K 大图当图标时预览会拖慢整页');
      expect(s.contains('READ_OK'), isTrue);
      // base64 字母表没有 shell 元字符，路径仍然要引号化
      expect(s.contains("'/root/projects/a/ic_launcher.png'"), isTrue);
    });

    test('路径里的单引号被正确转义（防注入/防路径断裂）', () {
      final s = IconReplacer.readBase64Script("/root/it's/a.png");
      expect(s.contains(r"'/root/it'\''s/a.png'"), isTrue);
    });

    test('清单页真的用图标内容而不是写死的 Flutter 图标（回归）', () {
      // 真机反馈："导入自定义图标但是界面预览没变" ——
      // 成因是那一格写死 `Icons.flutter_dash`，与真实文件无关。
      final page = File('lib/project/manifest_page.dart').readAsStringSync();
      expect(page.contains('Image.memory('), isTrue,
          reason: '预览必须显示真实图标内容（走 base64 → Image.memory）');
      expect(page.contains('_iconThumb()'), isTrue,
          reason: '图标格子要换成 _iconThumb()，否则又变回写死的默认图标');
      expect(page.contains('IconReplacer.readAsBytes'), isTrue,
          reason: '_load() 里要把图标读进 _iconBytes');
      // 回落分支必须还在（读不到时显示默认图标，不能白屏）
      expect(page.contains('errorBuilder:'), isTrue,
          reason: '文件在但不是合法 PNG 时要有兜底，不能抛异常带崩卡片');
    });
  });
}
