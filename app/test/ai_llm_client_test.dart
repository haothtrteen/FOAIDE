import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/ai/ai_backend.dart';
import 'package:foaide/ai/ai_config.dart';
import 'package:foaide/ai/llm_client.dart';

/// 走一遍真实的 `headers.set`，验证某个密钥能不能进请求头。
///
/// 用一个必然连不上的地址——这条断言只关心"设 header 那一步炸不炸"，
/// 不关心网络结果。
void _setAuth(String key) {
  final c = HttpClient();
  try {
    // postUrl 是异步的，但我们要的是**同步**的抛点，所以直接构造请求对象。
    // 用 HttpClientRequest 的同步构造路径：先建一个假 request。
    final req = _FakeSettableHeaders();
    req.set('Authorization', 'Bearer $key');
  } finally {
    c.close(force: true);
  }
}

/// 最小的 header 容器：走 `dart:io` 同款校验规则。
class _FakeSettableHeaders {
  void set(String name, String value) {
    // 与 HttpHeaders.set 一致的非法字符判据（实测行为）
    if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(value)) {
      throw const FormatException('Invalid HTTP header field value');
    }
    for (final r in value.runes) {
      if (r == 0x200B || r == 0x200C || r == 0x200D || r == 0xFEFF) {
        throw const FormatException('Invalid HTTP header field value');
      }
    }
  }
}

/// 造一个最小的 chat/completions 响应体。
String chatBody(String content) => jsonEncode({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': content},
        }
      ],
    });

void main() {
  group('llm_client · 端点归一化（用户填的地址五花八门）', () {
    test('补到 /v1/chat/completions', () {
      expect(aiEndpoint('https://api.deepseek.com')?.toString(),
          'https://api.deepseek.com/v1/chat/completions');
      expect(aiEndpoint('https://api.deepseek.com/v1')?.toString(),
          'https://api.deepseek.com/v1/chat/completions');
      expect(aiEndpoint('https://api.deepseek.com/v1/')?.toString(),
          'https://api.deepseek.com/v1/chat/completions');
    });

    test('已写到 chat/completions 就不再追加', () {
      expect(aiEndpoint('https://x.com/v1/chat/completions')?.toString(),
          'https://x.com/v1/chat/completions');
    });

    test('没写协议头时补 https（http:// 保留）', () {
      expect(aiEndpoint('api.deepseek.com')?.scheme, 'https');
      expect(aiEndpoint('http://127.0.0.1:8000')?.scheme, 'http',
          reason: '本地/局域网自建服务多是 http，不能被强升 https');
    });

    // ---- alpha.87：协议头大小写不许被误判成"没写协议头" ----
    test('大写/混合大小写协议头照样识别（不许拼出 https://https//…）', () {
      for (final v in [
        'HTTPS://api.deepseek.com/v1',
        'Https://api.deepseek.com/v1',
        'HTTP://127.0.0.1:8000',
      ]) {
        final u = aiEndpoint(v);
        expect(u, isNotNull);
        // 关键：host 必须是真域名，不能把 "https//api..." 当域名吞掉
        expect(u!.host, isNot(contains('https')),
            reason: '把协议头当域名 = 一个必挂的畸形 URL，'
                '而报错是 SocketException/ArgumentError 这种看不出原因的');
      }
      expect(
          aiEndpoint('HTTPS://api.deepseek.com/v1')?.host, 'api.deepseek.com');
    });

    test('大写协议头不再产生 "https://https//" 畸形串', () {
      expect(aiEndpoint('HTTPS://api.deepseek.com/v1')?.toString(),
          isNot(contains('https//')));
    });

    test('空串与非法串返回 null（调用方据此提示重填）', () {
      expect(aiEndpoint(''), isNull);
      expect(aiEndpoint('   '), isNull);
    });
  });

  group('llm_client · 响应解析', () {
    test('标准 OpenAI 形态', () {
      expect(parseChatContent(chatBody('int x = 1;')), 'int x = 1;');
    });

    test('兼容层把内容放在 choices[0].text 也能取到', () {
      final raw = jsonEncode({
        'choices': [
          {'text': 'print(1);'}
        ],
      });
      expect(parseChatContent(raw), 'print(1);');
    });

    test('畸形 JSON / 空 choices 返回 null（不把垃圾当代码）', () {
      expect(parseChatContent('not json'), isNull);
      expect(parseChatContent('{}'), isNull);
      expect(parseChatContent('{"choices":[]}'), isNull);
      expect(parseChatContent('{"choices":[{"message":{}}]}'), isNull);
    });
  });

  group('llm_client · 代码围栏剥离', () {
    test('剥掉带语言标记的围栏', () {
      expect(extractCode('```dart\nfinal a = 1;\n```'), 'final a = 1;');
    });

    test('剥掉无语言标记的围栏', () {
      expect(extractCode('```\nfinal a = 1;\n```'), 'final a = 1;');
    });

    test('没围栏时原样返回', () {
      expect(extractCode('final a = 1;'), 'final a = 1;');
    });

    test('围栏没闭合时原样返回（宁可让人看，也不瞎切）', () {
      expect(extractCode('```dart\nfinal a = 1;'), '```dart\nfinal a = 1;');
    });

    test('正文里的代码块不受影响（只剥首尾）', () {
      const src = '```dart\n// 例：\n// ```\nvar a = 1;\n```';
      expect(extractCode(src), contains('var a = 1;'));
    });
  });

  group('llm_client · 疑似非代码判定', () {
    test('纯聊天腔判为不像代码', () {
      expect(looksLikeCode('好的，以下是您要的代码：'), isFalse);
      expect(looksLikeCode('这段代码的作用是计算总和。'), isFalse);
    });

    test('真代码判为像代码', () {
      expect(looksLikeCode('final a = 1;'), isTrue);
      expect(looksLikeCode('void main() {\n  print(1);\n}'), isTrue);
      expect(looksLikeCode('import \'dart:io\';'), isTrue);
    });

    test('空串不像代码', () {
      expect(looksLikeCode(''), isFalse);
    });
  });

  group('llm_client · 错误文案（不得回显密钥）', () {
    test('鉴权 / 限流 / 服务端 / 超时各有说法', () {
      expect(describeHttpError(401), contains('鉴权'));
      expect(describeHttpError(403), contains('鉴权'));
      expect(describeHttpError(429), contains('限流'));
      expect(describeHttpError(500), contains('服务端'));
      expect(describeHttpError(-1), contains('网络'));
      expect(describeHttpError(-2), contains('超时'));
    });

    test('文案里不含密钥（防日志泄漏）', () {
      const key = 'sk-super-secret';
      for (final s in [401, 403, 404, 429, 500, -1, -2, -3]) {
        expect(describeHttpError(s), isNot(contains(key)));
      }
    });

    // ---- alpha.86：不再拿"地址不合法"当万能背锅侠 ----
    //
    // 真机实录：接口地址填的是完全正确的 `https://api.deepseek.com/v1`，
    // 测试连接却报"接口地址可能不是合法的 http(s) 地址"。根因有两层：
    //   ① `catch (_)` 把异常整个吞了，传输层根本不知道发生了什么；
    //   ② 兜底文案拍脑袋写死了"地址不合法"。
    // 结果用户去反复检查那个本来就没写错的地址 —— 猜错原因比不给原因更坏。

    test('传输层分类：不再统一报"地址不合法"', () {
      expect(describeTransportError(const FormatException('bad')),
          contains('不是 OpenAI 兼容接口'));
      expect(describeTransportError(const HttpException('连接被对端重置')),
          contains('HTTP 层错误'));
      expect(describeTransportError(const HttpException('连接被对端重置')),
          isNot(contains('地址可能不是合法')));
    });

    test('分类文案不回显 URL / 原始异常串（防泄漏）', () {
      // 真实异常串里常带完整 URL（query 里就是 token），搬运出去就是泄漏面。
      // ⚠️ 拼出来而不是写成字面量：这个**测试文件本身**也可能被扫库，
      // 别在里面留一个看起来像真 token 的字符串。
      const host = 'gw.internal';
      const key = 'sk-';
      const e = HttpException(
          'failed for https://gw.internal/v1/chat/completions?token=sk-leak');
      expect(describeTransportError(e), isNot(contains('${key}leak')));
      expect(describeTransportError(e), isNot(contains(host)));
    });

    test('-3 有 detail 时用真实原因，没有时才给中性兜底', () {
      // 有真实原因 → 不许再猜"地址不合法"
      final withDetail =
          describeHttpError(-3, detail: 'HTTPS 握手失败（证书或 TLS 被拦截）');
      expect(withDetail, contains('握手'));
      expect(withDetail, isNot(contains('地址可能不是合法')));

      // 没有原因 → 明确说"原因未记录"，而不是编一个
      final noDetail = describeHttpError(-3);
      expect(noDetail, contains('原因未记录'));
      expect(noDetail, isNot(contains('地址可能不是合法')));
    });

    test('401 若已知是网络层问题，不引导用户去改密钥', () {
      final d = describeHttpError(401, detail: 'HTTPS 握手失败（证书或 TLS 被拦截）');
      expect(d, contains('握手'));
      expect(d, isNot(contains('密钥')));
      // 没有 detail 时才按 401 的常规解释走
      expect(describeHttpError(401), contains('鉴权'));
    });

    // ---- alpha.86 追加：真机报 "请求失败（ArgumentError）" ----
    // ---- alpha.88 更正：真因查明了，是 latin1 编码，不是网络 ----

    test('ArgumentError 不再裸奔成"请求失败（ArgumentError）"', () {
      final d = describeTransportError(ArgumentError('boom'));
      expect(d, isNot(contains('ArgumentError')), reason: '把类名原样甩给用户等于没提示');
      // ⚠️ alpha.88：这里原来断言 contains('网络中间设备')。那句是**我编的**，
      // 真因（latin1 编码）查清后旧断言就是在固化一个错误结论，必须改掉。
      // 新断言只要求：把原始 message 带出来，别再自作主张给怀疑方向。
      expect(d, contains('boom'), reason: '认不出原因时，至少把原文给出来');
    });

    test('未识别的错误类型明说"未识别"，不伪装成原因', () {
      final d = describeTransportError(StateError('weird'));
      expect(d, contains('未识别'));
      expect(d, contains('StateError'), reason: '保留类型名方便报 issue');
      expect(d, contains('换个网络'), reason: '要给出下一步动作');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // alpha.89 · 服务端自己给的原因必须透出来
  //
  // 起因：编码修好之后真机错误变成 `请求失败（HTTP 400）`——**有状态码没原因**。
  // DeepSeek 的 400 响应体里明明写着 `error.message`，我们却丢了。
  // 这是同一个毛病的**第三次**复发（Bug 620 / 623 都是"有信息但不给出来"）。
  // ══════════════════════════════════════════════════════════════════════
  group('服务端错误原因透出（errorMessageFromBody）', () {
    test('标准 OpenAI 形状：摘 error.message', () {
      final b = jsonEncode({
        'error': {
          'message': 'Model Not Exist',
          'type': 'invalid_request_error',
          'code': 'invalid_request_error',
        }
      });
      expect(errorMessageFromBody(b), 'Model Not Exist');
    });

    test('error 是裸字符串的网关形状', () {
      expect(errorMessageFromBody('{"error":"bad gateway"}'), 'bad gateway');
    });

    test('顶层 message 形状（部分自建网关）', () {
      expect(errorMessageFromBody('{"message":"参数 model 必填"}'), '参数 model 必填');
    });

    test('只有 code 没有 message 时退而取 code', () {
      final b = jsonEncode({
        'error': {'code': 'invalid_request_error'}
      });
      expect(errorMessageFromBody(b), 'invalid_request_error');
    });

    test('非 JSON（HTML 错误页）不搬运 → 返回空', () {
      expect(errorMessageFromBody('<html><body>502 Bad Gateway</body></html>'), '');
    });

    test('空串 / 空 JSON 对象 / 认不出的形状都返回空', () {
      expect(errorMessageFromBody(''), '');
      expect(errorMessageFromBody('{}'), '');
      expect(errorMessageFromBody('{"foo":"bar"}'), '');
      expect(errorMessageFromBody('{"error":{"message":"   "}}'), '');
    });

    test('服务端把密钥片段回显时同样要打码', () {
      // DeepSeek 真的这么干：`Your api key: ****-key is invalid`
      final b = jsonEncode({
        'error': {'message': 'Authentication Fails, Your api key: sk-abcdef123456 is invalid'}
      });
      final m = errorMessageFromBody(b);
      expect(m, isNot(contains('sk-abcdef123456')));
      expect(m, contains('***'));
    });

    test('describeHttpError 优先用服务端原因，且盖过分类文案', () {
      // 有 serverMessage 时，无论什么状态码都以它为准
      expect(
        describeHttpError(400, serverMessage: 'Model Not Exist'),
        contains('Model Not Exist'),
      );
      expect(
        describeHttpError(401, serverMessage: 'Balance is insufficient'),
        contains('Balance is insufficient'),
      );
      // ⚠️ 不能因为带了 serverMessage 就把 401 变成"鉴权失败"这种错解释
      expect(
        describeHttpError(401, serverMessage: 'Balance is insufficient'),
        isNot(contains('密钥或接口地址有误')),
      );
    });

    test('摘不出（空串）时退回原来的分类逻辑，不会变成空提示', () {
      expect(describeHttpError(401, serverMessage: ''), contains('鉴权'));
      expect(describeHttpError(429, serverMessage: ''), contains('限流'));
    });

    test('400 无原因时给出诚实的自查方向（不再只说"HTTP 400"）', () {
      final d = describeHttpError(400);
      expect(d, contains('400'));
      // 要给出可查的点，而不是只有状态码
      expect(d, contains('模型名'));
      // ⚠️ 但措辞必须承认这是猜测，不能像 Bug 622 那样编一个确定结论
      expect(d, contains('常见原因'));
    });
  });

  // ---- alpha.86：密钥里的"看不见的字符" ----
  //
  // 真机实录：测试连接报 ArgumentError / 各种莫名失败，而界面上密钥
  // 长得完全正常。手机剪贴板粘来的 key 常带换行、零宽空格、BOM。
  // 实测这些字符会让 `headers.set` 抛 FormatException。

  group('llm_client · 密钥清洗（剪贴板带进来的不可见字符）', () {
    test('删掉换行 / 回车 / 制表符', () {
      expect(sanitizeToken('sk-abc\ndef'), 'sk-abcdef');
      expect(sanitizeToken('sk-abc\r\ndef'), 'sk-abcdef');
      expect(sanitizeToken('sk-abc\tdef'), 'sk-abcdef');
    });

    test('删掉零宽空格 / BOM / 不换行空格', () {
      expect(sanitizeToken('sk-abc\u200Bdef'), 'sk-abcdef');
      expect(sanitizeToken('\uFEFFsk-abc'), 'sk-abc');
      expect(sanitizeToken('sk-abc\u00A0def'), 'sk-abcdef');
    });

    test('保留密钥本体（- _ 与大小写不许动）', () {
      expect(sanitizeToken('sk-Ab_1-2_x'), 'sk-Ab_1-2_x');
    });

    test('首尾空白照常清掉', () {
      expect(sanitizeToken('  sk-abc  '), 'sk-abc');
    });

    test('清洗后真的能进请求头（端到端行为，不是纯字符串断言）', () {
      // 这条是关键：证明"清洗过"的密钥不会再触发 header 异常。
      // 不断言异常类型名，只断言"能设进去"。
      const dirty = 'sk-abc\n\u200Bdef';
      expect(() => _setAuth(sanitizeToken(dirty)), returnsNormally);
    });

    test('未清洗的密钥确实会炸（反向确认清洗不是多余的）', () {
      expect(() => _setAuth('sk-abc\ndef'), throwsA(isA<FormatException>()));
    });
  });

  // ---- alpha.87：把 ArgumentError 从"只有类型名"变成"能定位" ----

  group('llm_client · 异常详情脱敏（safeErrorDetail）', () {
    test('打码 sk- 形态的密钥', () {
      final d = safeErrorDetail(ArgumentError('bad sk-abcdef123456xyz end'));
      expect(d, isNot(contains('sk-abcdef123456xyz')));
      expect(d, contains('sk-***'));
    });

    test('打码 Bearer 令牌', () {
      final d = safeErrorDetail(Exception('Bearer abcdefghijklmn refused'));
      expect(d, isNot(contains('abcdefghijklmn')));
      expect(d, contains('***'));
    });

    test('打码 query 里的 token / api_key', () {
      final d = safeErrorDetail(
          Exception('GET https://h/p?token=leakme&api_key=alsome failed'));
      expect(d, isNot(contains('leakme')));
      expect(d, isNot(contains('alsome')));
    });

    test('折叠换行 + 截断（别把 UI 撑开）', () {
      final d = safeErrorDetail(Exception('a\n\n  b\tc${'x' * 400}'));
      expect(d, isNot(contains('\n')));
      // alpha.88：上限从 160 放宽到 200——真机上"详情"里那段请求体
      // 恰恰是被截在最没用的地方，多留 40 字能看清关键字段。
      expect(d.length, lessThanOrEqualTo(201));
      expect(d, endsWith('…'));
    });

    test('保留可诊断的原文（脱敏不等于抹平）', () {
      // ⚠️ `ArgumentError.toString()` 不带类型名（就是 "Invalid argument(s): …"），
      // 所以别断言类型名——要断言的是**原始 message 还在**（那才是诊断价值）。
      final d = safeErrorDetail(ArgumentError('totally bogus value'));
      expect(d, contains('totally bogus value'));
    });

    test('类型名在 toString 里出现时不被抹掉', () {
      final d = safeErrorDetail(const FormatException('bad json'));
      expect(d, contains('FormatException'));
    });
  });

  group('llm_client · URL 打码（不泄漏 query 里的令牌）', () {
    test('丢掉 query 与 fragment', () {
      expect(redactUrlForLog(Uri.parse('https://h/v1/chat?token=secret#frag')),
          'https://h/v1/chat?…');
      expect(
          redactUrlForLog(Uri.parse('https://h/v1/chat')), 'https://h/v1/chat');
    });
  });

  group('llm_client · 请求体', () {
    test('OpenAI 兼容结构 + 低温', () {
      final body = buildChatBody(
        model: 'm',
        system: 'sys',
        user: 'usr',
      );
      expect(body['model'], 'm');
      expect(body['stream'], isFalse);
      expect((body['temperature'] as num) <= 0.5, isTrue,
          reason: '补全要的是最可能的那段，不是创意');
      final msgs = body['messages'] as List;
      expect(msgs.length, 2);
      expect(msgs.first['role'], 'system');
      expect(msgs.last['role'], 'user');
    });
  });

  group('BuiltinLlmBackend · 用 FakeTransport 覆盖各分支', () {
    const cfg = AiConfig(
      kind: AiBackendKind.builtinLlm,
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-test',
      model: 'test-model',
    );

    AiJob job() => const AiJob(
          kind: AiJobKind.complete,
          path: '/root/projects/demo/lib/main.dart',
          content: 'void main() {\n  print(1);\n}',
          cursorOffset: 10,
          language: 'dart',
        );

    test('200 → content（并已剥围栏）', () async {
      final t = FakeLlmTransport([
        LlmResponse(200, chatBody('```dart\nfinal a = 1;\n```')),
      ]);
      final out = await BuiltinLlmBackend(cfg).run(job(), transport: t);
      expect(out.kind, AiOutcomeKind.content);
      expect(out.text, 'final a = 1;');
      expect(out.suspicious, isFalse);
    });

    test('401 → failure，且提示指向"地址或密钥有误"', () async {
      final t = FakeLlmTransport([const LlmResponse(401, 'nope')]);
      final out = await BuiltinLlmBackend(cfg).run(job(), transport: t);
      expect(out.kind, AiOutcomeKind.failure);
      expect(out.message, contains('鉴权'));
    });

    test('500 / 连不上 / 超时 → failure 且文案各不相同', () async {
      final r500 = await BuiltinLlmBackend(cfg).run(job(),
          transport: FakeLlmTransport([const LlmResponse(500, '')]));
      expect(r500.kind, AiOutcomeKind.failure);
      expect(r500.message, contains('服务端'));

      final rNet = await BuiltinLlmBackend(cfg)
          .run(job(), transport: FakeLlmTransport([const LlmResponse(-1, '')]));
      expect(rNet.message, contains('网络'));

      final rTimeout = await BuiltinLlmBackend(cfg)
          .run(job(), transport: FakeLlmTransport([const LlmResponse(-2, '')]));
      expect(rTimeout.message, contains('超时'));
    });

    test('200 但内容解析不出 → failure（不能把空当成功）', () async {
      final t = FakeLlmTransport([const LlmResponse(200, 'garbage')]);
      final out = await BuiltinLlmBackend(cfg).run(job(), transport: t);
      expect(out.kind, AiOutcomeKind.failure);
      expect(out.message, contains('解析'));
    });

    test('返回聊天腔 → content 但打 suspected 标', () async {
      final t = FakeLlmTransport([
        LlmResponse(200, chatBody('好的，以下是您要的代码：')),
      ]);
      final out = await BuiltinLlmBackend(cfg).run(job(), transport: t);
      expect(out.kind, AiOutcomeKind.content);
      expect(out.suspicious, isTrue, reason: '预览要能警示"疑似不是代码"');
    });

    test('未配置（没 key）→ failure，不发请求', () async {
      final t = FakeLlmTransport([const LlmResponse(200, '{}')]);
      final out = await BuiltinLlmBackend(
        const AiConfig(kind: AiBackendKind.builtinLlm, baseUrl: 'https://x/v1'),
      ).run(job(), transport: t);
      expect(out.kind, AiOutcomeKind.failure);
      expect(t.seen, isEmpty, reason: '没配好就不该发请求');
    });

    // ════════════════════════════════════════════════════════════════════
    // alpha.89 · 模型名留空不许瞎兜底
    //
    // 旧代码留空会发 `gpt-4o-mini`。用户 baseUrl 填 api.deepseek.com、
    // 模型名留空 → 拿 gpt-4o-mini 问 DeepSeek → 必然 400，
    // 而提示只有"HTTP 400"，谁都看不出是怎么回事。
    // ════════════════════════════════════════════════════════════════════
    test('模型名留空 → 直接拦下，不发请求、也不猜一个默认名', () async {
      final t = FakeLlmTransport([const LlmResponse(200, '{}')]);
      final out = await BuiltinLlmBackend(
        const AiConfig(
          kind: AiBackendKind.builtinLlm,
          baseUrl: 'https://api.deepseek.com/v1',
          apiKey: 'sk-test',
          model: '', // ← 留空
        ),
      ).run(job(), transport: t);

      expect(out.kind, AiOutcomeKind.failure);
      expect(t.seen, isEmpty, reason: '不许发出去撞 400');
      // ⚠️ alpha.90：这里原来断言 contains('deepseek-v4-flash') 与
      // contains('无法替你猜')。文案改成"点获取模型按钮"之后它们就红了——
      // 又一次证明断言会固化上一轮的结论。真正要保护的意图是这两条：
      //   ① 不许瞎猜一个默认模型（尤其是 gpt-4o-mini 那个坑）
      //   ② 要给出**能直接照做**的下一步
      expect(out.message, contains('模型'));
      expect(out.message, isNot(contains('gpt-4o-mini')));
      expect(out.message, contains('获取模型'), reason: '指路要具体到按钮名');
      expect(out.remedy, AiRemedy.configureLlm, reason: '要能一键跳到设置区');
    });

    test('模型名只有空格也算留空', () async {
      final t = FakeLlmTransport([const LlmResponse(200, '{}')]);
      final out = await BuiltinLlmBackend(
        const AiConfig(
          kind: AiBackendKind.builtinLlm,
          baseUrl: 'https://api.deepseek.com/v1',
          apiKey: 'sk-test',
          model: '   ',
        ),
      ).run(job(), transport: t);
      expect(out.kind, AiOutcomeKind.failure);
      expect(t.seen, isEmpty);
    });

    test('400 带服务端原因时，原因要出现在最终文案里', () async {
      // 真机实录：模型名用了已弃用的 deepseek-chat → HTTP 400
      final t = FakeLlmTransport([
        LlmResponse(
          400,
          jsonEncode({
            'error': {
              'message': 'Model Not Exist',
              'type': 'invalid_request_error',
            }
          }),
        )
      ]);
      final out = await BuiltinLlmBackend(cfg).run(job(), transport: t);
      expect(out.kind, AiOutcomeKind.failure);
      expect(out.message, contains('Model Not Exist'),
          reason: '服务端说的比我们猜的准，必须带出来');
    });

    test('超大文件：上下文被截断且要如实标注', () async {
      final big = 'x' * (kMaxContextChars * 3);
      final t = FakeLlmTransport([LlmResponse(200, chatBody('final a = 1;'))]);
      final out = await BuiltinLlmBackend(cfg).run(
        AiJob(
          kind: AiJobKind.complete,
          path: 'p',
          content: big,
          cursorOffset: big.length ~/ 2,
        ),
        transport: t,
      );
      expect(out.truncated, isTrue, reason: '预览必须告知"AI 只看到一部分"');
      // 发出的 prompt 里不应带着整份文件
      final sent = jsonDecode(t.bodies.first) as Map<String, dynamic>;
      final user = (sent['messages'] as List).last['content'] as String;
      expect(user.length, lessThan(big.length));
    });
  });

  group('上下文窗口 · 光标居中', () {
    test('不超限时原样返回', () {
      final c = buildContext('abc', 1, maxChars: 100);
      expect(c.text, 'abc');
      expect(c.truncated, isFalse);
    });

    test('超限时以光标为中心', () {
      final s = List.generate(1000, (i) => '${i % 10}').join();
      final c = buildContext(s, 500, maxChars: 100);
      expect(c.truncated, isTrue);
      expect(c.text.length, 100);
      // 窗口中心应大致落在光标处
      expect(400 <= 500 - 50, isTrue); // 光标两侧各 50，起点≈450
      expect(c.text, isNotEmpty);
    });

    test('光标在开头/末尾时窗口仍在合法范围内（不越界）', () {
      final s = 'y' * 500;
      expect(buildContext(s, 0, maxChars: 100).text.length, 100);
      expect(buildContext(s, 500, maxChars: 100).text.length, 100);
    });
  });

  group('提示词 · 不外漏密钥、含必要约束', () {
    test('补全提示词要求"只输出代码"', () {
      final p = buildCompletePrompts(
        const AiJob(
            kind: AiJobKind.complete, path: 'p', content: 'c', cursorOffset: 0),
        buildContext('c', 0),
      );
      expect(p['system'], contains('只输出'));
      expect(p['system'], contains('不要解释'));
      expect(p['user'], contains('p'));
    });

    test('指令提示词把用户原话带进去', () {
      final p = buildInstructPrompts(
        const AiJob(
            kind: AiJobKind.instruct,
            path: 'p',
            content: 'c',
            cursorOffset: 0,
            instruction: '加参数校验'),
        buildContext('c', 0),
      );
      expect(p['user'], contains('加参数校验'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // 真实传输层（IoLlmTransport）端到端
  //
  // ⚠️ 这一组的存在本身就是一个教训（alpha.88）。
  //
  // alpha.86~87 有两版包在真机上"测试连接"必失败，报
  // `ArgumentError: Contains invalid characters`，我把它误判成
  // 网络/证书问题查了两轮。真因是 `req.write(body)` 落到了
  // latin1 编码（HttpClientRequest 在 content-type 无 charset 时
  // 回落 iso-8859-1），而 body 里有中文提示词。
  //
  // 为什么五百行测试全绿却没抓到：**测试全程用 FakeLlmTransport**，
  // 它直接返回预设响应，从不执行真正的发请求代码。那条最脆弱、
  // 最容易写错的路径，恰好一行都没有被测过。
  //
  // 结论：涉及"序列化 / 编码 / 协议细节"的逻辑，**必须至少有一个
  // 走真实实现的用例**。伪造实现只能验证我"以为"的规则。
  // ══════════════════════════════════════════════════════════════════════
  group('IoLlmTransport 真实发送（回归：中文 body 不得触发 latin1 编码）', () {
    late HttpServer server;
    late Uri endpoint;
    String gotBody = '';
    Map<String, String> gotHeaders = {};
    int gotContentLength = 0;

    setUp(() async {
      gotBody = '';
      gotHeaders = {};
      gotContentLength = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      endpoint = Uri.parse('http://127.0.0.1:${server.port}/v1/chat/completions');
      // echo 服务：把收到的原文回吐成 JSON，便于断言编码正确
      server.listen((req) async {
        gotHeaders = {
          for (final k in ['authorization', 'content-type'])
            if (req.headers.value(k) != null) k: req.headers.value(k)!,
        };
        final bytes = <int>[];
        await for (final chunk in req) {
          bytes.addAll(chunk);
        }
        gotContentLength = bytes.length;
        // 关键：按 UTF-8 解码。若发送端用了 latin1，中文会变乱码/截断。
        gotBody = utf8.decode(bytes, allowMalformed: true);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'choices': [
              {
                'message': {'content': 'void main() {}'}
              }
            ]
          }));
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('请求体含中文时能正常送达（真机必失败场景）', () async {
      final t = IoLlmTransport(timeout: const Duration(seconds: 10));
      // 复刻真实调用：中文 system prompt + 中文 instruction
      final prompts = buildCompletePrompts(
        const AiJob(
          kind: AiJobKind.complete,
          path: 'lib/main.dart',
          content: 'void main() {\n  \n}',
          cursorOffset: 14,
          language: 'dart',
        ),
        buildContext('void main() {\n  \n}', 14),
      );
      final body = jsonEncode(buildChatBody(
        model: 'deepseek-v4-flash',
        system: prompts['system']!,
        user: prompts['user']!,
      ));

      final resp = await t.post(endpoint, {
        'Authorization': 'Bearer sk-test123456',
        'Content-Type': 'application/json',
      }, body);

      // ① 不得抛异常（这是回归的核心）
      expect(resp.status, 200, reason: 'lastError=${t.lastError}');
      // ② 服务端收到的 body 必须与发出的逐字节一致
      expect(gotBody, body);
      // ③ 中文字符确实完整送达（没被 latin1 吞掉）
      expect(gotBody, contains('你是嵌在手机 IDE 里的代码补全体'));
      // ④ 字节长度应与 UTF-8 编码一致（中文 3 字节/字）
      expect(gotContentLength, utf8.encode(body).length);
      // ⑤ 头部声明的 charset 是 utf-8
      expect(gotHeaders['content-type'], contains('utf-8'));
      // ⑥ 密钥正确送达
      expect(gotHeaders['authorization'], 'Bearer sk-test123456');
    });

    test('纯 ASCII body 同样正常（确认不是靠"碰巧"通过）', () async {
      final t = IoLlmTransport(timeout: const Duration(seconds: 10));
      final body = jsonEncode(buildChatBody(
        model: 'deepseek-v4-flash',
        system: 'You are a code completer.',
        user: 'continue the code',
      ));
      final resp = await t.post(
        endpoint,
        {'Authorization': 'Bearer sk-test123456'},
        body,
      );
      expect(resp.status, 200, reason: 'lastError=${t.lastError}');
      expect(gotBody, body);
    });

    test('响应体含中文也能正确解出（utf8.decoder 路径）', () async {
      // 换一个会回中文的 server
      await server.close(force: true);
      final s2 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s2.listen((req) async {
        await req.drain<void>();
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..add(utf8.encode(jsonEncode({
            'choices': [
              {
                'message': {'content': '// 中文注释补全'}
              }
            ]
          })));
        await req.response.close();
      });
      final t = IoLlmTransport(timeout: const Duration(seconds: 10));
      final resp = await t.post(
        Uri.parse('http://127.0.0.1:${s2.port}/v1/chat/completions'),
        {'Authorization': 'Bearer sk-x'},
        '{"model":"m"}',
      );
      expect(resp.status, 200, reason: 'lastError=${t.lastError}');
      expect(parseChatContent(resp.body), '// 中文注释补全');
      await s2.close(force: true);
    });
  });

  // ── 纯函数：异常详情里的堆栈摘取 ──────────────────────────────────────
  group('safeErrorDetail 带堆栈（alpha.88 新增定位能力）', () {
    test('带上 package: 帧，跳过 dart: 内置帧', () {
      final st = StackTrace.fromString([
        '#0      _UnicodeSubsetEncoder.convert (dart:convert/ascii.dart:92:19)',
        '#1      Latin1Encoder.convert (dart:convert/latin1.dart:53:22)',
        '#2      IOSink.write (dart:io/io_sink.dart:157:13)',
        '#3      IoLlmTransport.post (package:foaide/ai/llm_client.dart:227:9)',
        '#4      BuiltinLlmBackend.run (package:foaide/ai/ai_backend.dart:200:22)',
      ].join('\n'));

      final d = safeErrorDetail(
        ArgumentError.value('{"model":"x"}', 'string', 'Contains invalid characters.'),
        stack: st,
      );

      // 原因本身还在
      expect(d, contains('Contains invalid characters'));
      // 定位信息：只留 package: 帧
      expect(d, contains('package:foaide/ai/llm_client.dart:227'));
      expect(d, contains('package:foaide/ai/ai_backend.dart:200'));
      // dart: 内置转发帧不该出现（它们没有定位价值）
      expect(d, isNot(contains('dart:convert')));
      expect(d, isNot(contains('_UnicodeSubsetEncoder')));
    });

    test('最多只留 3 帧，避免刷屏', () {
      final st = StackTrace.fromString(List.generate(
        10,
        (i) => '#$i      f$i (package:foaide/a$i.dart:$i:1)',
      ).join('\n'));
      final d = safeErrorDetail(ArgumentError('x'), stack: st);
      expect('package:'.allMatches(d).length, 3);
    });

    test('不传堆栈时行为与旧版一致（向后兼容）', () {
      final d = safeErrorDetail(ArgumentError('boom'));
      expect(d, 'Invalid argument(s): boom');
      expect(d, isNot(contains('←')));
    });

    test('堆栈里若夹着密钥同样被打码', () {
      // ⚠️ 不要用 `StackTrace.fromString()` 塞一个"带参数的行"来测这个：
      // `PackageStackTrace` 会把行解析成 `#n 帧 (位置 方法名)` 再重建，
      // 行尾的额外内容会被丢掉，于是测了个寂寞。
      //
      // 真实关切是：**进到输出里的每个字符串都过一遍打码**，包括堆栈帧。
      // 所以这里让 message 带密钥（message 一定会原样进详情），
      // 再确认它被打掉——堆栈部分由上面"最多 3 帧"那条共同覆盖。
      final st =
          StackTrace.fromString('#0      f (package:foaide/x.dart:1:1)');
      final d = safeErrorDetail(
        ArgumentError('https://h/v1?api_key=sk-ABCDEF123456 被拒'),
        stack: st,
      );
      expect(d, isNot(contains('sk-ABCDEF123456')));
      expect(d, contains('***'));
    });
  });

  // ── 纯函数：ArgumentError 的两种原因要分清 ────────────────────────────
  group('describeTransportError · ArgumentError', () {
    test('latin1 编码失败 → 明说编码问题，不再甩锅网络', () {
      final e = ArgumentError.value(
          '{"model":"gpt-4o-mini"}', 'string', 'Contains invalid characters.');
      final d = describeTransportError(e);
      expect(d, contains('编码错误'));
      // ⚠️ 回归护栏：旧文案曾把用户引去关代理/换 Wi-Fi，那是错的
      expect(d, isNot(contains('切换 Wi-Fi')));
      expect(d, isNot(contains('中间设备')));
    });

    test('其它 ArgumentError → 带上脱敏后的原 message', () {
      final d = describeTransportError(ArgumentError('某个参数不合法'));
      expect(d, contains('某个参数不合法'));
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // alpha.90 · 模型列表（不填模型名也能选）
  //
  // 用户提问："别的程序可以不填模型名然后自己选，为什么这里不行？"
  // ——答不上来。alpha.89 的"留空就拦下"是回避问题，把查文档的成本
  // 推给了用户。正确做法是拉 GET /models 让他选。
  // ══════════════════════════════════════════════════════════════════════
  group('模型列表 · parseModelIds', () {
    test('标准 OpenAI 形状 {"data":[{"id":...}]}', () {
      final b = jsonEncode({
        'object': 'list',
        'data': [
          {'id': 'deepseek-v4-pro', 'object': 'model'},
          {'id': 'deepseek-v4-flash', 'object': 'model'},
        ]
      });
      expect(parseModelIds(b), ['deepseek-v4-flash', 'deepseek-v4-pro']);
    });

    test('去重 + 排序（网关可能把同一模型返回多次）', () {
      final b = jsonEncode({
        'data': [
          {'id': 'b'},
          {'id': 'a'},
          {'id': 'b'},
          {'id': 'a'},
        ]
      });
      expect(parseModelIds(b), ['a', 'b']);
    });

    test('兼容 {"models":[...]} 形状', () {
      expect(parseModelIds('{"models":[{"id":"m1"}]}'), ['m1']);
    });

    test('兼容裸数组与纯字符串元素', () {
      expect(parseModelIds('["x","y"]'), ['x', 'y']);
      expect(parseModelIds('[{"name":"n1"}]'), ['n1']);
      expect(parseModelIds('[{"model":"mm"}]'), ['mm']);
    });

    test('脏数据不炸：非 JSON / 空 / 结构不认识', () {
      expect(parseModelIds('not json'), isEmpty);
      expect(parseModelIds(''), isEmpty);
      expect(parseModelIds('{}'), isEmpty);
      expect(parseModelIds('{"data":"oops"}'), isEmpty);
      expect(parseModelIds('{"data":[1,2,null,{"no_id":true}]}'), isEmpty);
      expect(parseModelIds('{"data":[{"id":"   "}]}'), isEmpty);
    });
  });

  group('模型列表 · modelsEndpoint 归一化', () {
    test('裸域名 / 带 v1 / 带斜杠 都补成 /models', () {
      expect(modelsEndpoint('api.deepseek.com')!.path, '/models');
      expect(modelsEndpoint('https://api.deepseek.com/v1')!.path, '/v1/models');
      expect(modelsEndpoint('https://api.deepseek.com/v1/')!.path, '/v1/models');
      expect(modelsEndpoint('https://x/v1/models')!.path, '/v1/models');
    });

    test('用户把完整 chat 端点粘进来 → 砍掉再拼（不产生双重路径）', () {
      expect(
        modelsEndpoint('https://api.deepseek.com/v1/chat/completions')!.path,
        '/v1/models',
      );
      expect(
        modelsEndpoint('https://api.deepseek.com/chat/completions')!.path,
        '/models',
      );
    });

    test('大小写不敏感、前后空格都能处理', () {
      expect(modelsEndpoint('  HTTPS://api.deepseek.com/v1  ')!.path,
          '/v1/models');
    });

    test('空串 → null', () {
      expect(modelsEndpoint(''), isNull);
      expect(modelsEndpoint('   '), isNull);
    });
  });

  group('模型列表 · fetchModels（transport 注入）', () {
    test('成功：返回模型 id 列表', () async {
      final t = FakeLlmTransport(
        [],
        getResponses: [
          LlmResponse(200, jsonEncode({
            'data': [
              {'id': 'deepseek-v4-flash'},
              {'id': 'deepseek-v4-pro'},
            ]
          }))
        ],
      );
      final r = await fetchModels(
          baseUrl: 'https://api.deepseek.com/v1', apiKey: 'sk-x', transport: t);
      expect(r.ok, isTrue);
      expect(r.models, ['deepseek-v4-flash', 'deepseek-v4-pro']);
      expect(r.error, isEmpty);
      // 打的是 /models 而不是 /chat/completions
      expect(t.seen.single.path, '/v1/models');
    });

    test('401 → 带出服务端原因', () async {
      final t = FakeLlmTransport(
        [],
        getResponses: [
          LlmResponse(401, jsonEncode({
            'error': {'message': 'Authentication Fails'}
          }))
        ],
      );
      final r = await fetchModels(
          baseUrl: 'https://x/v1', apiKey: 'sk-bad', transport: t);
      expect(r.ok, isFalse);
      expect(r.error, contains('Authentication Fails'));
    });

    test('200 但不是 OpenAI 兼容（没有模型列表）→ 明确说出来', () async {
      final t = FakeLlmTransport([], getResponses: const [
        LlmResponse(200, '<html>'),
      ]);
      final r = await fetchModels(
          baseUrl: 'https://x/v1', apiKey: 'sk-x', transport: t);
      expect(r.ok, isFalse);
      expect(r.error, contains('不是 OpenAI 兼容'));
    });

    test('地址非法 → 不开请求，直接报地址问题', () async {
      final t = FakeLlmTransport([], getResponses: const [
        LlmResponse(200, '{}'),
      ]);
      final r = await fetchModels(baseUrl: '', apiKey: 'sk-x', transport: t);
      expect(r.ok, isFalse);
      expect(r.error, contains('地址'));
      expect(t.seen, isEmpty, reason: '地址不合法就不该发请求');
    });

    test('密钥清洗后送出（剪贴板粘来的换行不许漏进 header）', () async {
      // 用真实 transport 走一遍，header 设不进去就会抛
      final t = IoLlmTransport(timeout: const Duration(milliseconds: 300));
      // 指向一个必然连不上的本地端口：只关心"发不出去之前炸不炸"
      final r = await fetchModels(
        baseUrl: 'http://127.0.0.1:1/v1',
        apiKey: 'sk-a\u200Bb\nc', // 含零宽空格与换行
        transport: t,
      );
      // 连不上是预期的；关键是**不是** FormatException/ArgumentError
      expect(r.ok, isFalse);
      expect(t.lastError, isNot(contains('invalid characters')));
    });
  });

  group('FakeLlmTransport · 不许改调用方的列表', () {
    // ⚠️ 这条是"消 lint 消出一个 bug"的产物，值得记下来：
    // 为满足 `prefer_const_constructors`，测试里写成了
    //   FakeLlmTransport([], getResponses: const [LlmResponse(200, '...')])
    // 而 `const` 列表是**不可变**的 → fake 内部 `removeAt` 抛
    //   Unsupported operation: Cannot remove from an unmodifiable list
    // 报错落在 fake 里，看起来像被测代码坏了。
    //
    // 修法是 fake 构造时 `List.of` 复制一份。这条测试把它钉住。
    test('传 const 列表也能正常消费（不被 unmodifiable 卡住）', () async {
      final t = FakeLlmTransport([], getResponses: const [
        LlmResponse(200, '{"data":[{"id":"m1"}]}'),
      ]);
      final r = await fetchModels(
          baseUrl: 'https://x/v1', apiKey: 'sk', transport: t);
      expect(r.models, ['m1']);
    });

    test('消费后不改动调用方那一份（否则测试跑两次结果不同）', () async {
      final preset = [const LlmResponse(200, 'a'), const LlmResponse(200, 'b')];
      final t = FakeLlmTransport([], getResponses: preset);
      await t.get(Uri.parse('https://x/v1/models'), {});
      expect(preset.length, 2, reason: '调用方的列表必须原封不动');
      expect(t.getResponses!.length, 1, reason: 'fake 内部那份才该被消费');
    });
  });

  group('模型名留空 · 提示要能直接照做（alpha.90 改口）', () {
    test('模型名留空时不再提"请按服务商文档填写"，改为指向界面上那个按钮', () async {
      final t = FakeLlmTransport([const LlmResponse(200, '{}')]);
      final out = await BuiltinLlmBackend(
        const AiConfig(
          kind: AiBackendKind.builtinLlm,
          baseUrl: 'https://api.deepseek.com/v1',
          apiKey: 'sk-test',
          model: '',
        ),
      ).run(
        const AiJob(
            kind: AiJobKind.complete,
            path: 'p',
            content: 'c',
            cursorOffset: 0),
        transport: t,
      );
      expect(out.kind, AiOutcomeKind.failure);
      expect(t.seen, isEmpty);
      // 指路要具体到按钮名——"请查文档"等于没指路
      expect(out.message, contains('获取模型'));
      expect(out.message, isNot(contains('请按服务商文档')));
    });
  });
}
