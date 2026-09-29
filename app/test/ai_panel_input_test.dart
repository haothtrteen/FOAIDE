import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// alpha.82 · Bug 612「AI 设置里输入 API Key 时闪屏、无法输入」的防线。
///
/// 真机输入法的安全键盘冲突**沙箱复现不了**（没真机、没输入法），所以这里
/// 能守住的是"我方确证的那部分"：**异步回填竞态**（能确证、能断言）+ 三道
/// 对症下药的措施不许在后续重构里被悄悄去掉（源码断言）。
/// 输入法那半边只能靠真机验证——测试注释里写清楚，别让人以为测过了就等于好了。
String src(String rel) => File(rel).readAsStringSync();

/// 剥掉注释，只留代码。
///
/// ⚠️ 断言"某种旧写法已不存在"时**必须**先过一遍这里：解释性注释里
/// 常常把旧写法原文抄一遍当反面教材，直接搜全文就会把注释当代码命中
/// （Bug 610 的同类坑，见 handbook）。断言代码就只看代码。
String codeOnly(String s) => s
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '') // 块注释
    .replaceAll(RegExp(r'//.*'), ''); // 行注释

void main() {
  final panel = src('lib/project/ai_takeover_panel.dart');
  final code = codeOnly(panel);

  group('闪屏主因 · 异步回填不许覆盖用户正在敲的内容', () {
    test('_loadCfg 有"用户已编辑"守卫', () {
      final i = panel.indexOf('Future<void> _loadCfg()');
      expect(i, greaterThanOrEqualTo(0));
      final fn = panel.substring(i, i + 600);
      expect(fn, contains('_edited'),
          reason: '没有这个守卫，异步回来的旧配置会把 kind 改回 remoteMcp，'
              '整块输入区瞬间消失——这就是"闪一下、字没了"');
      // 守卫必须是**提前 return**，不是"回填完再修正"
      expect(RegExp(r'_edited\)\s*return;').hasMatch(fn), isTrue,
          reason: '必须是命中就返回，不能在回填之后才判断');
    });

    test('任何输入都会置 _edited（含清空密钥）', () {
      expect(panel, contains('onChanged: (_) => _markEdited()'));
      expect(panel, contains('void _markEdited()'));
      // 清空密钥也是"用户动过"，否则下次回填会把旧 key 又写回来
      final i = panel.indexOf('清空密钥');
      final seg = panel.substring(i - 400, i + 400);
      expect(seg, contains('_edited = true'));
    });
  });

  group('安全键盘 · 密钥默认明文 + visiblePassword', () {
    test('默认明文（_showKey 初值为 true）', () {
      expect(panel, contains('bool _showKey = true'),
          reason: 'obscureText 会触发输入法安全键盘，默认明文是为了先保证能输进去');
    });

    test('密钥字段走 visiblePassword，不是 text + obscure', () {
      expect(panel, contains('LlmFieldKind.apiKey'),
          reason: '字段语义收进枚举，别在调用点手写键盘类型');
      expect(panel,
          contains('LlmFieldKind.apiKey => TextInputType.visiblePassword'),
          reason: 'visiblePassword 明确告诉输入法"是密码但用普通键盘"');
    });

    // ---- alpha.86：安全键盘不许外溢到非密钥字段 ----
    //
    // 用户报"接口地址完全没必要用安全键盘吧"。根因不是这里显式开过 obscure，
    // 而是"哪个字段是密钥"这件事以前散落在调用点，没有单一事实来源。
    // 现在语义由 LlmFieldKind 定义，这几条把边界钉死。

    test('只有密钥字段遮挡，接口地址与模型名不遮挡', () {
      expect(
          panel, contains('bool get secureText => this == LlmFieldKind.apiKey'),
          reason: 'secureText 必须只对 apiKey 为真');
    });

    test('接口地址用普通键盘（安全键盘常缺 / : . 打不全地址）', () {
      expect(panel, contains('LlmFieldKind.baseUrl => TextInputType.url'));
      final i = panel.indexOf('_aiField(_baseUrlCtl');
      final call = panel.substring(i, i + 160);
      expect(call, contains('LlmFieldKind.baseUrl'));
      expect(call, isNot(contains('secret: true')),
          reason: '接口地址被当密钥 → 输入法切安全键盘 → 地址敲不出来');
    });

    test('三个字段的调用点都改用了 LlmFieldKind，没有残留裸键盘类型', () {
      for (final k in ['baseUrl', 'apiKey', 'model']) {
        expect(code, contains('LlmFieldKind.$k'));
      }
      // 旧的调用写法（type + secret 布尔）不许回潮。断言的是**代码**，
      // 注释里抄旧写法当反面教材不算——所以用 codeOnly。
      expect(code, isNot(contains('TextInputType.url)')),
          reason: '仍有人手写裸键盘类型说明枚举没收干净');
      expect(code, isNot(contains('secret: true')),
          reason: '布尔参数会允许"给地址传 secret"这种错法');
    });

    test('遮挡与否由眼睛按钮切换（想要遮的人自己点）', () {
      expect(panel, contains('obscureText: secureText && !_showKey'));
      expect(panel, contains('Icons.visibility_off'));
    });

    test('关掉联想 / 自动更正 / 个性化学习', () {
      final i = panel.indexOf('Widget _aiField(');
      final fn = panel.substring(i, i + 1200);
      expect(fn, contains('enableSuggestions: false'));
      expect(fn, contains('autocorrect: false'));
      expect(fn, contains('enableIMEPersonalizedLearning: false'),
          reason: '候选栏高度反复变化也会带动布局跳动，且密钥本来就不该被学习');
    });
  });

  group('闪屏次因 · 输入框身份稳定 / 不在编辑完成时保存', () {
    test('TextField 带稳定 key（父级重建时不丢 Element 身份）', () {
      expect(panel, contains("key: ValueKey<String>('ai-field-\$label')"));
    });

    test('不挂 onEditingComplete（它会触发收键盘动作）', () {
      final i = panel.indexOf('Widget _aiField(');
      final fn = panel.substring(i, i + 1200);
      expect(fn, isNot(contains('onEditingComplete')),
          reason: '保存改由停手 600ms 静默写，见 _markEdited');
    });

    test('停手 600ms 静默保存，且 timer 在 dispose 里取消', () {
      expect(panel, contains('const Duration(milliseconds: 600)'));
      expect(panel, contains('_persist(silent: true)'));
      final d = panel.substring(panel.indexOf('void dispose()'),
          panel.indexOf('void dispose()') + 300);
      expect(d, contains('_saveTimer?.cancel()'));
    });
  });
}
