import 'dart:convert';

import '../editor/fs_bridge.dart';
import 'ai_config.dart';
import 'llm_client.dart';
import 'mcp_dispatch.dart';

/// 作业类型：单点补全 / 长按指令。
enum AiJobKind { complete, instruct }

/// 一次 AI 作业的输入（编辑器上报的全部信息就这些）。
class AiJob {
  final AiJobKind kind;

  /// 容器内路径（编辑器与 MCP 同一棵目录树）。
  final String path;
  final String content;
  final int cursorOffset;

  /// 仅 [AiJobKind.instruct] 使用：用户在输入栏里写的要求。
  final String instruction;

  /// 展示用的语言名（dart/java/...），用于提示词与预览标题。
  final String language;

  const AiJob({
    required this.kind,
    required this.path,
    required this.content,
    required this.cursorOffset,
    this.instruction = '',
    this.language = '',
  });

  String get kindName => kind == AiJobKind.complete ? 'complete' : 'instruct';
}

/// 光标居中的上下文窗口。
class AiContext {
  final String text;
  final bool truncated;
  const AiContext(this.text, {this.truncated = false});
}

/// 以光标为中心截取上下文（纯函数）。
///
/// 补全要的是"光标附近在干什么"，从文件头截 24k 字符对第 800 行的光标
/// 毫无帮助，还白烧 token。所以前后各取一半，一侧不够就把额度让给另一侧。
AiContext buildContext(String content, int cursorOffset,
    {int maxChars = kMaxContextChars}) {
  if (content.length <= maxChars) return AiContext(content);
  final half = maxChars ~/ 2;
  final off = cursorOffset.clamp(0, content.length);
  var start = off - half;
  var end = off + half;
  if (start < 0) {
    // 光标靠前：把前面省下的额度补给后面
    end += -start;
    start = 0;
  }
  if (end > content.length) {
    start -= end - content.length;
    end = content.length;
  }
  if (start < 0) start = 0;
  return AiContext(content.substring(start, end), truncated: true);
}

/// 补全的 system/user 提示词（纯函数）。
///
/// 关键约束写死在 system 里：只输出要补的那段代码、不要解释、不要围栏
/// ——LLM 最爱干的事就是热心地加一句"以下是补全后的代码"。
Map<String, String> buildCompletePrompts(AiJob job, AiContext ctx) {
  final lang = job.language.isEmpty ? '' : '${job.language} ';
  return {
    'system': '你是嵌在手机 IDE 里的代码补全体。'
        '只输出要补写的$lang 代码片段本身：不要解释、不要 Markdown 围栏、'
        '不要复述上下文、不要省略号占位。'
        '保持与上下文一致的缩进与风格。',
    'user': '下面是光标附近的代码（已标注光标位置），请续写光标处应该出现的代码：\n\n'
        '```\n${ctx.text}\n```\n\n'
        '文件：${job.path}\n'
        '只输出补写内容。',
  };
}

/// 指令作业的提示词（纯函数）：把用户原话原样转达。
Map<String, String> buildInstructPrompts(AiJob job, AiContext ctx) {
  final lang = job.language.isEmpty ? '' : '${job.language} ';
  return {
    'system': '你是嵌在手机 IDE 里的代码助手。用户会给出一段$lang 代码'
        '和一条要求，请按要求给出**改动后的代码片段**（不是整份文件），'
        '不要解释、不要 Markdown 围栏。',
    'user': '文件：${job.path}\n\n要求：${job.instruction}\n\n'
        '光标附近代码：\n\n```\n${ctx.text}\n```\n\n'
        '只输出改动后的代码片段。',
  };
}

enum AiOutcomeKind { content, dispatched, failure }

/// AI 没能跑起来时**该往哪儿走**（alpha.85）。
///
/// 为什么不靠比对 [AiOutcome.message] 字符串：文案一改，跳转逻辑就悄悄
/// 失效，而且不会有任何测试变红。给一个显式枚举，UI 只认它，文案随便改。
enum AiRemedy {
  /// 内置 LLM 缺地址或密钥 → 去 AI 设置区填。
  configureLlm,

  /// 远程 MCP 但隧道没开 → 去远程协助页起隧道。
  startTunnel,
}

/// 后端产出的**中性结果**：UI 只认这个，不关心背后是 LLM 还是 MCP。
class AiOutcome {
  final AiOutcomeKind kind;

  /// [AiOutcomeKind.content] 时的代码文本（已剥围栏）。
  final String text;

  /// 给用户的说明（派活路径 / 失败原因）。
  final String message;

  /// 上下文被截断过 → 预览要如实标注"AI 只看到了一部分"。
  final bool truncated;

  /// 返回内容疑似不是代码 → 预览标警示，但不拦着（人能自己判断）。
  final bool suspicious;

  /// 失败时建议的下一步（null = 只提示，没有明确去处）。
  final AiRemedy? remedy;

  const AiOutcome({
    required this.kind,
    this.text = '',
    this.message = '',
    this.truncated = false,
    this.suspicious = false,
    this.remedy,
  });

  const AiOutcome.content(this.text,
      {this.truncated = false, this.suspicious = false})
      : kind = AiOutcomeKind.content,
        message = '',
        remedy = null;

  const AiOutcome.dispatched(this.message)
      : kind = AiOutcomeKind.dispatched,
        text = '',
        truncated = false,
        suspicious = false,
        remedy = null;

  const AiOutcome.failure(this.message, {this.remedy})
      : kind = AiOutcomeKind.failure,
        text = '',
        truncated = false,
        suspicious = false;
}

/// 后端抽象：两条交互（补全 / 指令）都走它。
abstract class AiBackend {
  String get id;
  Future<AiOutcome> run(AiJob job, {LlmTransport? transport});
}

/// 内置 LLM 后端：即时返回代码文本。
class BuiltinLlmBackend implements AiBackend {
  BuiltinLlmBackend(this.cfg);

  final AiConfig cfg;

  @override
  String get id => 'builtinLlm';

  @override
  Future<AiOutcome> run(AiJob job, {LlmTransport? transport}) async {
    if (!cfg.llmReady) {
      return const AiOutcome.failure(
        '未配置内置 LLM：请先填接口地址与密钥',
        remedy: AiRemedy.configureLlm,
      );
    }
    final ctx = buildContext(job.content, job.cursorOffset);
    final p = job.kind == AiJobKind.complete
        ? buildCompletePrompts(job, ctx)
        : buildInstructPrompts(job, ctx);
    // ⚠️ 模型名留空的两难，以及为什么最后既不"猜"也不"死拦"（alpha.90）。
    //
    // alpha.88 及以前：留空发 `gpt-4o-mini`。baseUrl 填 api.deepseek.com
    // 时拿 gpt 的名字去问 DeepSeek → 必然 400，而提示只有"HTTP 400"。
    //
    // alpha.89：改成留空直接拦下。**这是回避问题**——把"该填什么"的成本
    // 推回给用户（用户原话："别的程序可以不填模型名然后自己选"）。
    //
    // alpha.90：正解是做**模型列表**。UI 上（[_loadModels]）拉
    // `GET /models` 让用户点选；这里作为**兜底**——万一用户就是没点那个
    // 按钮直接发作业，也不该静默失败，而要给出**能直接照做**的指引。
    final model = cfg.model.trim();
    if (model.isEmpty) {
      return const AiOutcome.failure(
        '还没选模型。点「获取模型」从接口拉回可用列表再点一个即可'
        '（不用自己查文档）',
        remedy: AiRemedy.configureLlm,
      );
    }
    final body = jsonEncode(buildChatBody(
      model: model,
      system: p['system']!,
      user: p['user']!,
    ));
    final url = _endpoint(cfg.baseUrl);
    if (url == null) {
      return const AiOutcome.failure('接口地址不是合法的 http(s) 地址');
    }
    final t = transport ?? IoLlmTransport();
    final resp = await t.post(
      url,
      {
        // ⚠️ 必须 sanitize 而不只是 trim()：从手机剪贴板粘来的密钥常带
        // 换行 / 零宽空格 / BOM，**界面上完全看不出来**，但会让
        // `headers.set` 直接抛异常。trim() 只清首尾，删不掉句子中间的
        // 这类字符——见 [sanitizeToken]。
        'Authorization': 'Bearer ${sanitizeToken(cfg.apiKey)}',
        'Content-Type': 'application/json',
      },
      body,
    );
    if (resp.status != 200) {
      // ⚠️ 只回显状态码与分类文案，绝不回显**整段**响应体（可能带账号信息）。
      //
      // 传输层自己（IoLlmTransport）会有比状态码更精确的原因，比如
      // "HTTPS 握手失败"——那时按状态码猜"密钥有误"会把用户引偏。
      final detail = t is IoLlmTransport ? t.lastError : '';
      // alpha.89：**服务端自己写的原因最准**，优先用它。
      // 之前 400 只报 "请求失败（HTTP 400）"，而 DeepSeek 的响应体里
      // 明明写着 `error.message`（具体哪个字段不对）——有信息却丢掉了。
      // 注意 [errorMessageFromBody] 只摘 `error.message` 这一个字段，
      // 且内部已做密钥打码，不会把整段 JSON 搬进 UI。
      final serverMsg = errorMessageFromBody(resp.body);
      return AiOutcome.failure(describeHttpError(
        resp.status,
        detail: detail,
        serverMessage: serverMsg,
      ));
    }
    final raw = parseChatContent(resp.body);
    if (raw == null) {
      return const AiOutcome.failure('接口返回了 200，但解析不出内容（模型名是否正确？）');
    }
    final code = extractCode(raw);
    if (code.trim().isEmpty) {
      return const AiOutcome.failure('模型返回了空内容');
    }
    return AiOutcome.content(
      code,
      truncated: ctx.truncated,
      suspicious: !looksLikeCode(code),
    );
  }
}

/// 远程 MCP 后端：**只派活**，永远不返回代码文本。
class RemoteMcpBackend implements AiBackend {
  RemoteMcpBackend({required this.bridge, required this.projectRoot});

  final FsBridge bridge;
  final String projectRoot;

  @override
  String get id => 'remoteMcp';

  @override
  Future<AiOutcome> run(AiJob job, {LlmTransport? transport}) async {
    final ctx = buildContext(job.content, job.cursorOffset, maxChars: 8000);
    final instruction = job.kind == AiJobKind.complete
        ? '补全光标处的代码（文件与光标位置见下）'
        : job.instruction;
    final r = await dispatchJob(
      bridge: bridge,
      projectRoot: projectRoot,
      file: job.path,
      cursor: job.cursorOffset,
      kindName: job.kindName,
      instruction: instruction,
      contextSnippet: ctx.text,
    );
    if (!r.ok) {
      return AiOutcome.failure(r.error ?? '派活失败：写不进项目目录');
    }
    final tail = r.error == null ? '' : '\n（${r.error}）';
    return AiOutcome.dispatched(
      '已投递到 $kAiInboxFile，等已连隧道的 AI 客户端领取。'
      '这是异步的：它改完文件后会自动弹窗给你看差异，'
      '也可以随时点「更多 → 从磁盘重新载入」。$tail',
    );
  }
}

/// 按配置选后端。
AiBackend aiBackendFrom(
  AiConfig cfg, {
  FsBridge? bridge,
  String projectRoot = '',
}) =>
    cfg.kind == AiBackendKind.builtinLlm
        ? BuiltinLlmBackend(cfg)
        : RemoteMcpBackend(
            bridge: bridge ?? FsBridge(),
            projectRoot: projectRoot,
          );

/// 把 baseUrl 归一化成 `/chat/completions` 端点（纯函数）。
///
/// 用户填的地址五花八门：`https://x/v1`、`https://x/v1/`、`https://x`。
/// 统一补到 chat/completions，避免"填了却 404"这种最伤的首次体验。
///
/// ⚠️ 大小写不敏感（alpha.87 修）：原来只认小写 `https://`，用户填
/// `HTTPS://api.deepseek.com/v1` 时会被当成"没有协议头"，补成
/// `https://https//api.deepseek.com/...` —— 一个必挂的畸形 URL，
/// 而报错又是 `SocketException`/`ArgumentError` 这种看不出原因的。
Uri? _endpoint(String baseUrl) {
  var s = baseUrl.trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    s = 'https://$s';
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (!s.endsWith('/chat/completions')) {
    s = s.endsWith('/v1') ? '$s/chat/completions' : '$s/v1/chat/completions';
  }
  return Uri.tryParse(s);
}

/// 对外暴露（便于单测端点归一化逻辑）。
Uri? aiEndpoint(String baseUrl) => _endpoint(baseUrl);
