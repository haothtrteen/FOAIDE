import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ai/ai_config.dart';

void main() {
  group('AiConfig · 数据结构', () {
    test('默认未配置走远程 MCP（不需要密钥、不外发代码）', () {
      expect(AiConfig.unconfigured.kind, AiBackendKind.remoteMcp);
      expect(AiConfig.unconfigured.llmReady, isFalse);
    });

    test('内置 LLM 的"可用"要地址与密钥都填了才算', () {
      const onlyUrl = AiConfig(
        kind: AiBackendKind.builtinLlm,
        baseUrl: 'https://x/v1',
      );
      expect(onlyUrl.llmReady, isFalse, reason: '没填 key 不能算配好');
      const both = AiConfig(
        kind: AiBackendKind.builtinLlm,
        baseUrl: 'https://x/v1',
        apiKey: 'sk-1',
      );
      expect(both.llmReady, isTrue);
      // 选了远程 MCP 时即便填了 key 也不该被当成可用 LLM
      const mcpWithKey = AiConfig(
        kind: AiBackendKind.remoteMcp,
        baseUrl: 'https://x/v1',
        apiKey: 'sk-1',
      );
      expect(mcpWithKey.llmReady, isFalse);
    });

    test('纯空格不算填（用户复制粘贴常带空格/换行）', () {
      const c = AiConfig(
        kind: AiBackendKind.builtinLlm,
        baseUrl: '  ',
        apiKey: ' \n ',
      );
      expect(c.llmReady, isFalse);
    });

    test('JSON 往返一致', () {
      const c = AiConfig(
        kind: AiBackendKind.builtinLlm,
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-abc',
        model: 'deepseek-chat',
      );
      final back = AiConfig.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(back.kind, c.kind);
      expect(back.baseUrl, c.baseUrl);
      expect(back.apiKey, c.apiKey);
      expect(back.model, c.model);
    });

    test('脏 JSON / 未知 kind 一律回退未配置（不许抛）', () {
      expect(AiConfig.fromJson(null).kind, AiBackendKind.remoteMcp);
      expect(AiConfig.fromJson('not a map').kind, AiBackendKind.remoteMcp);
      // 未知 kind 落回 remoteMcp，而不是崩掉或默认成会外发代码的 LLM
      expect(
        AiConfig.fromJson({'kind': 'whoKnows'}).kind,
        AiBackendKind.remoteMcp,
      );
      // 字段类型不对也不能抛
      expect(AiConfig.fromJson({'baseUrl': 42}).baseUrl, '');
    });

    test('copyWith 只改指定字段', () {
      const c = AiConfig(
        kind: AiBackendKind.builtinLlm,
        baseUrl: 'https://x/v1',
        apiKey: 'sk-1',
        model: 'm',
      );
      final cleared = c.copyWith(apiKey: '');
      expect(cleared.apiKey, isEmpty);
      expect(cleared.baseUrl, 'https://x/v1', reason: '其余字段保持');
      expect(cleared.model, 'm');
    });
  });

  group('AiConfigStore · 全异常静默', () {
    test('读不到（测试环境无原生通道）→ 回退未配置，不抛', () async {
      // 测试里 ProotBridge 的 MethodChannel 没有原生实现 → envInfo 会抛
      // MissingPluginException。这正是"通道不可用"的真实场景，
      // 配置层必须静默回退，绝不能让编辑器因为读不到 AI 配置而崩。
      final c = await AiConfigStore.load();
      expect(c, isNotNull);
      expect(c.kind, AiBackendKind.remoteMcp);
    });

    test('保存 / 清空密钥失败也不抛（通道不可用时）', () async {
      await AiConfigStore.save(
          const AiConfig(kind: AiBackendKind.builtinLlm, apiKey: 'sk-x'));
      await AiConfigStore.clearKey();
      // 走到这里没抛即通过
    });
  });
}
