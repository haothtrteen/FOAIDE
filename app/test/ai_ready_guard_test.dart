import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ai/ai_assist.dart';
import 'package:foaide/ai/ai_backend.dart';
import 'package:foaide/ai/ai_config.dart';
import 'package:foaide/ai/mcp_dispatch.dart';
import 'package:foaide/mcp/tunnel_service.dart';

String src(String rel) => File(rel).readAsStringSync();

void main() {
  group('AiRemedy · 失败要有明确去处（不靠比对文案）', () {
    test('未配置内置 LLM → remedy = configureLlm', () async {
      // 直接调真后端，不在测试里复刻判定：复刻的话后端改了测试不会红
      final o = await BuiltinLlmBackend(const AiConfig(
        kind: AiBackendKind.builtinLlm,
      )).run(const AiJob(
        kind: AiJobKind.complete,
        path: 'a.dart',
        content: '',
        cursorOffset: 0,
      ));
      expect(o.kind, AiOutcomeKind.failure);
      expect(o.remedy, AiRemedy.configureLlm);
    });

    test('普通失败没有 remedy（不该乱指路）', () {
      const o = AiOutcome.failure('接口返回 500');
      expect(o.remedy, isNull);
    });

    test('content / dispatched 恒为 null remedy', () {
      expect(const AiOutcome.content('a').remedy, isNull);
      expect(const AiOutcome.dispatched('已投递').remedy, isNull);
    });

    test('编辑器页不再靠文案比对选出口（alpha.85 回归）', () {
      final s = src('lib/editor/editor_page.dart');
      // 以前唯一的判据是 out.message == kAiUnconfiguredMessage，
      // 改一个字跳转就静默失效。现在走 remedy 枚举。
      expect(s, contains('remedy: out.remedy'));
      expect(s, contains('AiRemedy.startTunnel'));
    });
  });

  group('tunnelReady · 只有 running 才算就绪', () {
    test('running → true', () {
      expect(tunnelReady(TunnelStatus.running), isTrue);
    });

    test('其余所有状态 → false（含 starting/installing）', () {
      for (final s in [
        TunnelStatus.idle,
        TunnelStatus.installing,
        TunnelStatus.starting,
        TunnelStatus.error,
      ]) {
        expect(tunnelReady(s), isFalse, reason: '$s 不该被当成可用');
      }
    });
  });

  group('MCP 派活前置检查 · 隧道没开不许静静派活', () {
    test('编辑器页有 _ensureAiReady 且先于占位执行', () {
      final s = src('lib/editor/editor_page.dart');
      expect(s, contains('Future<bool> _ensureAiReady()'));
      final guard = s.indexOf('if (!await _ensureAiReady()) return;');
      final placeholder = s.indexOf('beginAiPlaceholder()');
      expect(guard, greaterThan(-1), reason: '必须真的调用它');
      expect(placeholder, greaterThan(guard),
          reason: '检查必须在预留空行之前——占位是"AI 正在写"的承诺，'
              '还没确定能跑就占位，失败要撤占位，白闪一下');
    });

    test('隧道没开时给三个出口，且默认停在不派活上', () {
      final s = src('lib/editor/editor_page.dart');
      expect(s, contains("'隧道没开'"));
      expect(s, contains("Navigator.pop(ctx, 'cancel')"));
      expect(s, contains("Navigator.pop(ctx, 'send')"));
      expect(s, contains("Navigator.pop(ctx, 'tunnel')"));
      // ⚠️ 容空白：`dart format` 会把 `?? 'cancel';` 折到下一行。
      // 断言逻辑不断言排版（见 handbook Bug 610）。
      expect(
        RegExp(r"\?\?\s*'cancel'").hasMatch(s),
        isTrue,
        reason: '点外部关掉弹窗时不能默默派活',
      );
    });

    test('「去开启隧道」不放行派活（用户点的是去开隧道）', () {
      final s = src('lib/editor/editor_page.dart');
      final i = s.indexOf("if (choice == 'tunnel')");
      expect(i, greaterThan(-1));
      final body = s.substring(i, i + 400);
      expect(body, contains('onOpenAiSettings'));
      expect(body, contains('return false'), reason: '点"去开启隧道"却顺手把作业派了，等于违他本意');
    });

    test('「仍然派活」放行（有人就是要先留作业）', () {
      final s = src('lib/editor/editor_page.dart');
      final i = s.indexOf("// 'send'：用户明知没人领也要留个作业");
      expect(i, greaterThan(-1));
      expect(s.substring(i, i + 120), contains('return true'));
    });

    test('内置 LLM 缺 key 也走同一条前置检查', () {
      final s = src('lib/editor/editor_page.dart');
      final i = s.indexOf('_ensureAiReady() async {');
      final body = s.substring(i, i + 900);
      expect(body, contains('!cfg.llmReady'));
      expect(body, contains('kAiUnconfiguredMessage'));
    });

    test('失败对话框按 remedy 换出口文案', () {
      final s = src('lib/editor/editor_page.dart');
      expect(s, contains("remedy == AiRemedy.startTunnel ? '去开启隧道' : '去设置'"));
    });
  });

  group('作业文件 · 「怎么做」一节要写死三件事', () {
    final md = buildJobMarkdown(
      file: 'lib/main.dart',
      cursor: 100,
      kindName: 'complete',
      instruction: '',
      contextSnippet: 'void main() {}',
      stamp: '2026-09-26 12:00:00',
    );

    test('交付方式与边界合并在「怎么做」一节（alpha.86 去噪）', () {
      expect(md, contains('## 怎么做'));
      // 去噪把原来分开的「## 交付方式」「## 边界（请遵守）」并成了一节，
      // 但内容一条都不许丢 —— 见下面三条。
      expect(md, isNot(contains('## 边界（请遵守）')), reason: '两节合并后不该再留着旧标题');
    });

    test('① 不许扩范围', () {
      expect(md, contains('只做「要求」里写的事'));
      expect(md, contains('都不是**扩大范围的理由'), reason: '"文件看起来已完整"正是真机上发生的越界起点');
    });

    test('② 不许主动跑构建/测试/analyze', () {
      expect(md, contains('不要主动运行构建 / 测试'));
      expect(md, contains('flutter analyze'));
    });

    test('③ 不许通读全文顺带分析', () {
      expect(md, contains('不要为了"确认现状"通读整个文件再顺带分析'));
    });

    test('改不动就保持原样，不许猜着改', () {
      expect(md, contains('保持文件原样'));
      expect(md, contains('不要用猜的改动顶上'));
    });

    test('原有的交付方式仍在（不回退既有约定）', () {
      expect(md, contains('write_file'));
      expect(md, contains('status: done'));
    });

    test('作业文件里不许出现开发过程用语（用户明确要去噪）', () {
      // 用户原话："接入提示简洁一点，不要把不必要的东西写进去了
      // （例如：xxxx新增）"。作业文件是给外部 AI 读的，它不需要知道
      // 我们是哪个版本改的这条规则。
      for (final junk in ['alpha.', '新增', '回归', '本轮']) {
        expect(md, isNot(contains(junk)), reason: '作业文件混进了"$junk"');
      }
    });
  });

  group('接入说明提示词 · 明确"没活就等着"', () {
    final p = buildHandoffPrompt(
      tunnelUrl: 'https://x.trycloudflare.com',
      token: 'tok',
      projectName: 'my_flutter',
      projectRoot: '/root/projects/my_flutter',
    );

    test('给了"只有两种情况才动手"的正面清单', () {
      expect(p, contains('只有两种情况你才动手'));
      expect(p, contains('未处理'));
    });

    test('收件箱空/全 done → 只回一句就停，不许自行发挥', () {
      expect(p, contains('当前没有待处理作业'));
      expect(p, contains('除此之外一律停下来等'));
      expect(p, contains('不要顺带看看项目'));
    });

    test('"看起来已完整"不是扩范围的理由（真机踩过的坑）', () {
      expect(p, contains('看起来已经完整'));
      expect(p, contains('扩大范围的理由'));
    });

    test('默认不跑构建/analyze/测试', () {
      expect(p, contains('不要**主动跑编译、构建'));
      expect(p, contains('flutter analyze'));
    });

    test('解释了为什么（真机+QEMU 慢），不是干巴巴的命令', () {
      expect(p, contains('QEMU'));
      expect(p, contains('负分'));
    });

    test('开场建议已改：不再是"先 foa_info 建立环境认知"', () {
      expect(p, isNot(contains('先调用 foa_info 建立环境认知')),
          reason: '这句在鼓励无作业时到处翻，正是"乱分析测试"的源头');
      expect(p, contains('停下等指令'));
    });

    test('顺手把"改完要点从磁盘重新载入"的过期说法也去掉了', () {
      expect(p, isNot(contains('用户点\n「从磁盘重新载入」就能看到')),
          reason: 'alpha.83 起已自动弹 diff，提示不该还教人手动操作');
    });

    test('不许出现开发过程用语 / 版本号（用户明确要去噪）', () {
      // 用户原话："接入提示简洁一点，不要把不必要的东西写进去了
      // （例如：xxxx新增）"。这段是发给外部 AI 的任务书，不是 changelog。
      for (final junk in ['alpha.', '新增', 'alpha.81', 'alpha.84', '回归']) {
        expect(p, isNot(contains(junk)), reason: '接入说明混进了"$junk"');
      }
      // 中文粗体「**新增 xx**」这种排版也别留
      expect(p, isNot(contains('新增')), reason: '段落小标题式的"新增"也要去掉');
    });

    test('去噪之后该讲的仍然讲（别把功能说明一起删了）', () {
      expect(p, contains('接入方式'));
      expect(p, contains('Authorization: Bearer'));
      expect(p, contains('QEMU'));
      expect(p, contains('.foa/ai-inbox.md'));
      expect(p, contains('工作纪律'));
    });

    test('"可用工具（建议先调）"这种与纪律矛盾的引导已去掉', () {
      expect(p, isNot(contains('建议先调')),
          reason: '一边说"没事别乱跑"，一边建议先调 foa_info，自相矛盾');
    });
  });

  group('收件箱表头 · 空的时候要劝住 AI', () {
    test('新建的 inbox 带"没有条目就停下"的说明', () {
      final s = src('lib/ai/mcp_dispatch.dart');
      expect(s, contains('没有未处理条目时请停下等待'));
      expect(s, contains('不要自行浏览项目或做健康检查'));
    });
  });

  group('防重入 · 连点 AI 按钮不许派出重复作业', () {
    test('同步闸门 _aiRunning 存在，且与给用户看的 _aiBusy 分开', () {
      final s = src('lib/editor/editor_page.dart');
      expect(s, contains('bool _aiRunning = false'),
          reason: '_aiBusy 要等 setState 才置真，挡不住 await 窗口期');
      // 两个字段都要有：一个管"能不能点"，一个管"界面怎么显示"
      expect(s, contains('bool _aiBusy = false'));
    });

    test('闸门在所有 await 之前就落下', () {
      final s = src('lib/editor/editor_page.dart');
      final i = s.indexOf('Future<void> _runAiFlow(');
      expect(i, greaterThan(-1));

      // ⚠️ 不能直接搜 `await `：函数签名之前的文档注释里就写着
      // "await"（讲的就是这个 await 窗口期的坑），会命中注释而不是代码。
      // 先拿函数体起点（签名后的第一个 `{`），再以闸门为锚点往后找 await。
      final bodyStart = s.indexOf('{', i);
      expect(bodyStart, greaterThan(i));

      final latch = s.indexOf('if (_aiRunning) return;', bodyStart);
      final setLatch = s.indexOf('_aiRunning = true;', bodyStart);
      expect(latch, greaterThan(-1), reason: '必须有重入检查');
      expect(setLatch, greaterThan(latch));

      // 闸门函数体里、闸门之后的第一个真正 await 语句。
      final body = s.substring(bodyStart, bodyStart + 4000);
      final relSet = setLatch - bodyStart;
      final firstAwait = body.indexOf('await ', relSet);
      expect(firstAwait, greaterThan(relSet),
          reason: '闸门必须落在第一个 await 之前，否则 await 期间第二次点击'
              '仍会看到闸门开着 —— 这正是重复派活的成因');
      expect(body, contains('if (!await _ensureAiReady()) return;'),
          reason: '挡住重入之后才轮到前置检查');
    });

    test('闸门在 finally 里打开（任何出口都不许把按钮永久锁死）', () {
      final s = src('lib/editor/editor_page.dart');
      final i = s.indexOf('Future<void> _runAiFlow(');
      final body = s.substring(i, i + 3500);
      expect(body, contains('} finally {'));
      expect(body, contains('_aiRunning = false;'),
          reason: '提前 return / 弹窗抛异常都得解锁，否则 AI 按钮点不动了');
    });

    test('旧的 `|| _aiBusy` 短路写法没有回潮', () {
      final s = src('lib/editor/editor_page.dart');
      expect(
          s, isNot(contains('if (widget.onRunAi == null || _aiBusy) return;')),
          reason: '_aiBusy 在 await 窗口期仍为 false，那正是漏点');
      expect(s, contains('if (widget.onRunAi == null) return;'));
    });
  });
}
