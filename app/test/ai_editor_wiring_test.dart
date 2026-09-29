import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ai/ai_backend.dart';
import 'package:foaide/ai/ai_config.dart';
import 'package:foaide/ai/mcp_dispatch.dart';
import 'package:foaide/editor/fs_bridge.dart';

/// 读源码做断言：接线类改动最容易在后续重构里被悄悄拆掉，
/// 而"拆掉"不会让任何逻辑测试变红——只能用源码断言守住。
String src(String rel) => File(rel).readAsStringSync();

void main() {
  group('AI 按钮 · 单点补全 / 长按派活', () {
    test('按钮同时挂了 onTap 与 onLongPress，且分别走两个回调', () {
      final s = src('lib/editor/code_editor.dart');
      expect(s, contains('onTap: () => _emitAi(widget.onAiComplete)'));
      expect(s, contains('onLongPress: () => _emitAi(widget.onAiInstruct)'));
      // 两个回调都声明在 CodeEditor 上（宿主注入，编辑器不认识 AI）
      expect(
          s, contains('final void Function(EditorAiRequest)? onAiComplete;'));
      expect(
          s, contains('final void Function(EditorAiRequest)? onAiInstruct;'));
    });

    test('旧的单回调 onAiAssist 没有回潮', () {
      for (final f in [
        'lib/editor/code_editor.dart',
        'lib/editor/editor_page.dart',
        'lib/project/project_page.dart',
      ]) {
        expect(src(f), isNot(contains('onAiAssist')), reason: '$f 不该再有旧回调');
      }
    });

    test('长按路径：EditorPage 先收指令再交宿主（带 String 参数）', () {
      final s = src('lib/editor/editor_page.dart');
      expect(
          s,
          contains(
              'final void Function(EditorAiRequest, String)? onAiInstruct;'));
      expect(s, contains('_showAiInstructSheet'));
      // 结果落回编辑器
      expect(s, contains('void applyAiResult(String text)'));
      expect(s, contains('Future<void> reloadFromDisk('));
    });

    test('宿主把"怎么跑 AI"注入编辑器页（alpha.82：插入点回到编辑器侧）', () {
      final s = src('lib/project/project_page.dart');
      expect(s, contains('onRunAi: _runAi'),
          reason: 'alpha.82 起宿主只回答"AI 说了什么"，写在哪由编辑器页决定');
      expect(s, contains('Future<AiOutcome> _runAi(AiJob job)'));
      // 未配置时顺手把人领到 AI 设置区（内嵌编辑器没有 AppBar，自己摸不过去）
      expect(s, contains('_Section.ai'));
      expect(s, contains('kAiUnconfiguredMessage'));
    });

    test('编辑器暴露 insertAtCursor（供宿主把 AI 结果插到光标处）', () {
      final s = src('lib/editor/code_editor.dart');
      expect(s, contains('void insertAtCursor(String text)'),
          reason: '必须是公开方法，私有的话宿主无法调用');
    });
  });

  group('依赖洁癖 · 不为此引新包', () {
    test('lib/ai 下没有 import package:http（只用 dart:io HttpClient）', () {
      for (final f in Directory('lib/ai').listSync().whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains("import 'package:http")),
            reason: '${f.path} 不该引 http');
      }
    });

    test('pubspec 没有新增 http / shared_preferences', () {
      final s = src('pubspec.yaml');
      expect(RegExp(r'^\s{2}http:', multiLine: true).hasMatch(s), isFalse);
      expect(s, isNot(contains('shared_preferences')));
    });

    test('AI 配置走 filesDir JSON，不用 shared_preferences', () {
      final s = src('lib/ai/ai_config.dart');
      expect(s, contains('ProotBridge()'));
      expect(s, isNot(contains('SharedPreferences')));
    });
  });

  group('远程 MCP 后端 · 永不伪造回执', () {
    test('派活只返回 dispatched，绝不带代码文本', () async {
      final b = _MemBridge();
      final out = await RemoteMcpBackend(
        bridge: b,
        projectRoot: '/root/projects/demo',
      ).run(
        const AiJob(
          kind: AiJobKind.complete,
          path: 'lib/main.dart',
          content: 'void main() {}',
          cursorOffset: 5,
        ),
      );
      expect(out.kind, AiOutcomeKind.dispatched);
      expect(out.text, isEmpty, reason: '异步无回执，不许拿原文/占位内容冒充 AI 结果');
      expect(out.message, contains(kAiInboxFile));
      expect(out.message, contains('重新载入'), reason: '必须告诉用户怎么看到结果');
    });

    test('派活提示先讲"会自动弹预览"，不再只让人手动重载（alpha.84）', () {
      // alpha.83 起已自动盯盘，提示却还写着"用编辑器的「从磁盘重新载入」
      // 查看结果"——改了行为没改提示，用户会以为功能没生效。
      final s = src('lib/ai/ai_backend.dart');
      expect(s, contains('会自动弹窗给你看差异'), reason: '主路径是自动预览，手动重载只是兜底');
      expect(s, isNot(contains('它改完文件后，用编辑器的「从磁盘重新载入」查看结果')),
          reason: '旧的"只能手动重载"文案不许回潮');
    });

    test('派活后盯盘：基线交给 watcher 自己读盘（alpha.84 回归）', () {
      final s = src('lib/editor/editor_page.dart');
      expect(s, contains('void _startDiskWatch(String path)'),
          reason: '基线参数已删除：编辑器内容当基线会引发假报警并吃掉真改动');
      expect(s, contains('unawaited(w.start(path: path))'));
      expect(
        RegExp(r'_startDiskWatch\([^)]*,[^)]*\)').hasMatch(s),
        isFalse,
        reason: '不许再把第二个参数（编辑器内容）传下去',
      );
    });

    test('派活黑盒有可观测出口（alpha.84：菜单里能看作业收件箱）', () {
      final s = src('lib/editor/editor_page.dart');
      expect(s, contains("value: 'ai_inbox'"), reason: '更多菜单要有入口');
      expect(s, contains('Future<void> _showAiInbox()'));
      expect(s, contains("case 'ai_inbox':"));
      expect(s, contains('loadAiInbox(bridge: widget.bridge'),
          reason: '必须走真实快照，不许硬编码一句"没有作业"糊弄');
      // 收件箱只读：判断"完成"的权利在外部 AI 手里，App 代它标 done 就是撒谎
      expect(s, isNot(contains('jobMarkedDone(')),
          reason: '回执判定属于 ai_inbox_view，UI 不该自己造一份');
    });

    test('写不进去 → failure，不静默假装成功', () async {
      // 作业文件名带时间戳，这里直接让"任何写入都失败"模拟目录不可写
      final b = _MemBridge()..failAll = true;
      final out = await RemoteMcpBackend(
        bridge: b,
        projectRoot: '/root/projects/demo',
      ).run(
        const AiJob(
          kind: AiJobKind.complete,
          path: 'lib/main.dart',
          content: 'a',
          cursorOffset: 0,
        ),
      );
      expect(out.kind, AiOutcomeKind.failure);
      expect(out.message, isNotEmpty);
    });

    test('aiBackendFrom：选了内置 LLM 才走 LLM，否则一律派活', () {
      expect(
        aiBackendFrom(const AiConfig()).id,
        'remoteMcp',
        reason: '未配置时默认派活（不外发代码）',
      );
      expect(
        aiBackendFrom(const AiConfig(
          kind: AiBackendKind.builtinLlm,
          baseUrl: 'https://x/v1',
          apiKey: 'sk-1',
        )).id,
        'builtinLlm',
      );
    });
  });

  group('交接提示词 · 要能引导外部 AI 去收件箱', () {
    test('buildHandoffPrompt 提到 ai-inbox.md', () {
      // 交接提示词在隧道服务里，这里只断言它确实指向收件箱，
      // 否则用户派了活、外部 AI 却根本不知道有活。
      final s = src('lib/mcp/tunnel_service.dart');
      expect(s, contains(kAiInboxFile));
      expect(s, contains('status: done'));
    });
  });
}

/// 内存版 FsBridge（与 ai_dispatch_test 同思路，这里只关心成功/失败两态）。
class _MemBridge extends FsBridge {
  final Map<String, String> files = <String, String>{};
  final Set<String> failWrite = <String>{};
  bool failAll = false;

  @override
  Future<FsReadResult> read(String path) async {
    final c = files[path];
    return c == null
        ? const FsReadResult(ok: false, error: 'ENOENT')
        : FsReadResult(ok: true, content: c);
  }

  @override
  Future<FsResult> write(String path, String content) async {
    if (failAll || failWrite.contains(path)) {
      return const FsResult(ok: false, error: 'EACCES');
    }
    files[path] = content;
    return const FsResult(ok: true);
  }
}
