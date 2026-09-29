import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 内置 LLM 客户端（alpha.81）：OpenAI 兼容 `/chat/completions`。
///
/// ## 为什么不用 `package:http`
/// 项目至今没有该依赖，且对依赖一贯挑剔（见 pubspec 里逐条写理由的注释）。
/// `dart:io` 的 HttpClient 对"发一个 POST 拿一段 JSON"完全够用，没必要
/// 为此多拉一个包。
///
/// ## 为什么只抽象一层 transport
/// HttpClient **不可注入**（没有可替换的接口），而 prompt 构造 / 响应解析
/// / 错误分类这些才是真正需要单测的逻辑。所以这里把"发请求"抽成
/// [LlmTransport]，其余全是**纯函数**——测试用 FakeLlmTransport 覆盖
/// 200/401/500/超时/畸形 JSON，不碰网络也能测完分支。

/// 单次上下文窗口的字符上限（约 6~8k token）。
///
/// 整份文件动辄几万字符，全发既烧钱又容易超上下文；编辑器场景的补全
/// 需要的只是光标附近。**以光标为中心取窗口**，比"从头截"有用得多。
const int kMaxContextChars = 24000;

/// HTTP 响应（transport 层的中性表示，不含任何业务语义）。
class LlmResponse {
  final int status;
  final String body;
  const LlmResponse(this.status, this.body);
}

/// 传输层抽象：真实实现走 HttpClient，测试注入 Fake。
///
/// [get] 是 alpha.90 加的：`GET /models` 拉可用模型列表需要它。
/// ⚠️ 不要为了"少一个方法"把 GET 塞进 post —— body 无内容是 GET 的**语义**
/// 区别，不是可选参数。
abstract class LlmTransport {
  Future<LlmResponse> post(
    Uri url,
    Map<String, String> headers,
    String body,
  );

  /// 发一个不带请求体的 GET（用于 `/models` 这类查询接口）。
  Future<LlmResponse> get(
    Uri url,
    Map<String, String> headers,
  );
}

/// 传输层能给出的"最接近原因"的一句话（纯函数）。
///
/// ⚠️ 别回显 `SocketException.message` / `HandshakeException.toString()`：
/// 里面可能带完整 URL（含 query 里的 token）与内网地址。所以只做
/// **分类**，不搬运原文——见 [_netHint]。
String describeTransportError(Object error) {
  if (error is HandshakeException) {
    return 'HTTPS 握手失败（证书或 TLS 被拦截；运营商/公司网络/VPN 常见）';
  }
  if (error is CertificateException) {
    return '证书校验失败（代理或自签证书）';
  }
  if (error is HttpException) {
    // ⚠️ 绝不回显 `HttpException.message`：它是**任意字符串**，真机上常常
    // 就是"failed for https://host/...?token=xxx" —— 搬运出去等于把地址与
    // 令牌抄进 UI 和日志。这里只给分类，不搬运原文。
    return 'HTTP 层错误（对端拒绝或连接中断）';
  }
  if (error is FormatException) {
    // ⚠️ 这里有两种**完全不同**的原因，不能混为一谈（都抛 FormatException）：
    //   ① 密钥/首部里混进换行、零宽空格、BOM（`headers.set` 抛
    //      "Invalid HTTP header field value"）—— 手机上粘贴极易发生；
    //   ② 响应体不是合法 JSON（地址指向的可能不是 OpenAI 兼容接口）。
    // 按 message 区分，猜不出时优先提示①（更常见且用户自己能修）。
    final m = error.message;
    if (m.contains('header')) {
      return '请求头含非法字符（密钥可能混进了换行或零宽空格，建议重新粘贴）';
    }
    return '响应格式异常（接口地址指向的可能不是 OpenAI 兼容接口）';
  }
  if (error is ArgumentError) {
    // 真机实录（alpha.86）：用户测试连接报 "请求失败（ArgumentError）"。
    //
    // ⚠️ alpha.88 更正：这里原来写的是"多见于网络中间设备改写连接；
    // 可先试切换 Wi-Fi / 关代理后重试"——**那是错的，是我拍的**。
    // 拿到用户截图后才查清真因：`ArgumentError.value(string, "string",
    // "Contains invalid characters.")` 唯一来自 `lib/convert/ascii.dart`
    // 的 `_UnicodeSubsetEncoder.convert()` —— 也就是 **`latin1.encode()`
    // 或 `ascii.encode()` 拿到了含非 ASCII 字符的字符串**（我们的 body 里
    // 有中文提示词）。跟网络、代理、证书全部无关。
    //
    // 「技术上真、实际上假」的错误提示比没有提示更坏：用户会照着它去
    // 关代理、换 Wi-Fi，白折腾一圈。
    final m = error.message.toString();
    if (m.contains('Contains invalid characters')) {
      return '编码错误：请求体里有非 ASCII 字符，却被当成 latin1/ascii 编码'
          '（中文提示词触发；与本机网络无关，属程序缺陷）';
    }
    return '请求参数被拒绝（${_redactSecrets(m)}）';
  }
  if (error is OSError) {
    return '网络层错误（${error.message}）';
  }
  // 兜底：连类型名都不伪装成"原因"，明说没认出来。
  return '请求失败（未识别的错误类型 ${error.runtimeType}，'
      '可先试换个网络重试）';
}

/// 清掉从剪贴板粘进来的"看不见的字符"（纯函数）。
///
/// 手机复制 API Key 时极易带上换行、零宽空格（U+200B）、BOM（U+FEFF）、
/// 不换行空格（U+00A0）——它们在界面上**完全看不出来**，但会让
/// `HttpClient.headers.set` 直接抛异常，用户面对"测试连接失败"却怎么检查
/// 都发现不了问题。
///
/// ⚠️ 只删**空白/格式类**字符，绝不改动密钥本体：密钥里可能有 `-` `_`，
/// 那些必须原样保留。
String sanitizeToken(String raw) {
  final b = StringBuffer();
  for (final r in raw.runes) {
    // 控制字符（含 \n \r \t）、零宽字符、不换行空格、BOM 一律丢弃
    if (r < 0x20 || r == 0x7F) continue;
    if (r == 0x200B || r == 0x200C || r == 0x200D || r == 0xFEFF) continue;
    if (r == 0x00A0 || r == 0x2028 || r == 0x2029) continue;
    b.writeCharCode(r);
  }
  return b.toString().trim();
}

/// 打码：各种 token 形态一律替换成 `***`（纯函数）。
///
/// 单独抽出来是因为它要被用在**两处**：异常 message 和堆栈帧。
/// 堆栈里同样可能夹着带 token 的 URL。
String _redactSecrets(String s) {
  var out = s;
  // sk-xxx / Bearer xxx / ?token=xxx / api_key=xxx
  out = out.replaceAll(RegExp(r'sk-[A-Za-z0-9_\-]{4,}'), 'sk-***');
  out = out.replaceAll(
      RegExp(r'(Bearer\s+)[A-Za-z0-9_\-\.]{6,}', caseSensitive: false),
      r'$1***');
  out = out.replaceAll(
      RegExp(r'((?:token|api[_-]?key|apikey)=)[^&\s]+', caseSensitive: false),
      r'$1***');
  return out;
}

/// 把异常压成一行**可安全展示**的诊断文本（纯函数）。
///
/// 为什么需要它：`ArgumentError` 这类异常光看类型名等于没信息，用户与开发者
/// 都无从下手。但直接 `toString()` 又会带出 URL（含 query 里的 token）、
/// 内网地址、文件路径——**不能原样显示**。
///
/// 折中：**先脱敏、再截断**。密钥形状的串一律打码，长串只留头部。
/// 宁可信息少一点，也不让它变成新的泄漏面。
///
/// ## alpha.88：为什么要带上堆栈
/// alpha.87 真机上这条提示长这样：
/// ```
/// 详情：Invalid argument (string): Contains invalid characters.: "{\"model\":...
/// ```
/// —— 光看 message 根本判不出**是谁**把请求体交给了 `latin1.encode()`：
/// 异常文本里只有**数据**，没有**调用点**。而堆栈恰好只有调用点。
/// 所以这里保留堆栈里**最上层若干个 `package:` 帧**（跳过 `dart:` 内置帧，
/// 那些只会是 `convert` 的转发层，没有定位价值）。
String safeErrorDetail(Object error, {StackTrace? stack}) {
  var s = _redactSecrets(error.toString());

  // ① 折叠空白（换行会把 UI 撑开）
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  const max = 200;
  if (s.length > max) s = '${s.substring(0, max)}…';

  // ② 附上堆栈里的业务帧（跳过 dart: 内置帧）
  final frames = _topFrames(stack);
  if (frames.isNotEmpty) s = '$s ← ${frames.join(' ← ')}';
  return s;
}

/// 从堆栈里摘出**最上层的几个 `package:` 帧**（纯函数）。
///
/// 为什么只认 `package:`：出问题的调用点必然在某个包里（我们自己的代码也
/// 以 `package:foaide/...` 形式出现）。`dart:` 帧是 SDK 内部的转发层，
/// 报出来也是 `_UnicodeSubsetEncoder.convert` 这种，帮不上定位。
///
/// ⚠️ 堆栈行的形状是 `#3      IoLlmTransport.post (package:foaide/...)`——
/// `package:` 在**行中间**，不在行首。第一版写成 `t.startsWith('package:')`
/// 于是一帧都摘不到（测试当场抓出）。这里改为找 `package:` 的出现位置。
///
/// 只取**前 3 个**：第一帧就是案发现场，后面的是调用链，够还原路径了。
List<String> _topFrames(StackTrace? stack, {int keep = 3}) {
  if (stack == null) return const [];
  final out = <String>[];
  for (final raw in stack.toString().split('\n')) {
    final t = raw.trim();
    final at = t.indexOf('package:');
    if (at < 0) continue;
    // 从 `package:` 开始，取到方法名之前的 `路径:行:列`
    var frame = t.substring(at);
    // 同一行可能带 "  methodName"（两空格分隔），只留位置部分
    final sp = frame.indexOf(RegExp(r'\s'));
    if (sp > 0) frame = frame.substring(0, sp);
    out.add(_redactSecrets(frame));
    if (out.length >= keep) break;
  }
  return out;
}

/// 连不上时的一句补充说明（纯函数）。
///
/// 真机实录（alpha.86）：`api.deepseek.com` 在国内网络下会解析成功但
/// 连接被重置 / TLS 被掐，落到 `catch (_)` 后曾经统一报"接口地址可能不是
/// 合法的 http(s) 地址"——**地址明明是对的**，这句猜测把用户引向错误方向。
/// 所以：解析不出原因时就**不要猜**，改说"可能连不上、也可能是别的原因"，
/// 并把地址原样带出来让用户自己核对。
String _netHint(String baseUrl, String detail) => detail.isEmpty
    ? '连不上 $baseUrl —— 常见原因是手机网络到不了该地址'
        '（被墙 / 需要代理），其次才是地址或密钥有误'
    : '连不上 $baseUrl：$detail';

/// `dart:io` HttpClient 实现。
class IoLlmTransport implements LlmTransport {
  IoLlmTransport({this.timeout = const Duration(seconds: 60)});

  final Duration timeout;

  /// 最近一次失败的原因（只读，供 UI 在错误文案后面补一句）。
  ///
  /// 存成字段而不是返回码：返回码只有 5 个位置，塞不下"握手失败 / 格式异常 /
  /// 证书错误"这些**不该被合并**的区分。
  String lastError = '';

  @override
  Future<LlmResponse> post(
    Uri url,
    Map<String, String> headers,
    String body,
  ) =>
      _send(url, headers, body);

  @override
  Future<LlmResponse> get(
    Uri url,
    Map<String, String> headers,
  ) =>
      _send(url, headers, null);

  /// 真正发请求（post/get 共用）。
  ///
  /// [body] 为 null 表示 GET（无请求体）。
  ///
  /// ⚠️ 抽成一个方法而不是写两遍：编码那套修复（见下方大段注释）极其
  /// 容易在复制时漏掉一半。`GET /models` 也会 400/401，同样需要
  /// `lastError` 的诊断能力。
  Future<LlmResponse> _send(
    Uri url,
    Map<String, String> headers,
    String? body,
  ) async {
    lastError = '';
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final req = body == null
          ? await client.getUrl(url).timeout(timeout)
          : await client.postUrl(url).timeout(timeout);

      // ⚠️⚠️ 这里是 alpha.86~87 真机一直"测试连接失败"的**真正原因**，
      // 详见下方 `req.add(utf8.encode(body))` 的注释。别改回去。
      //
      // 顺序要紧：先灌 headers，**最后**再设 contentType。
      // 反过来的话，headers 里的 `Content-Type: application/json`
      // 会把带 charset 的那份覆盖掉（`headers.set` 是同名覆盖），
      // charset 声明就白写了。
      headers.forEach((k, v) => req.headers.set(k, v));

      // GET 不需要 content-type（没有请求体），也别去动它——
      // 给无 body 的请求挂 `application/json` 只是噪音。
      if (body != null) {
        // 覆盖 headers 里那份不带 charset 的 `Content-Type`。
        // 必须放在 add() **之前**——add 之后 headers 变 immutable。
        req.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');

        // ⚠️ 必须用 UTF-8 字节写，**不能用 `req.write(body)`**。
        //
        // 缘由（alpha.88 查明，此前长期误判为网络/证书问题）：
        // `HttpClientRequest` 的 `encoding` getter 在 content-type **没有
        // charset** 时会回落到 `"iso-8859-1"`（即 latin1，见 dart:io
        // http_impl.dart:1191）。而 `write()` 的第一次调用会把这个编码定死，
        // 再调 `latin1.encode(body)`。
        //
        // 我们的请求体里有中文提示词（"你是嵌在手机 IDE 里的代码补全体…"），
        // latin1 收不下 → `_UnicodeSubsetEncoder.convert()` 抛
        //   ArgumentError.value(string, "string", "Contains invalid characters.")
        // 也就是真机截图里那条错误。**入口是编码，不是网络**。
        //
        // 两个都做（charset 声明 + 显式 utf8 字节）：前者让服务端正确解码，
        // 后者从根上绕开 latin1 回落。只做前者也能避开崩溃，但显式写字节
        // 更不容易被以后改动"顺手改回去"。
        //
        // ⚠️ 注意 `req.add(utf8.encode(...))` 才是**真正兜住**这一条的那行：
        // `add()` 收的是字节，压根不经过 encoding getter。charset 声明只是
        // 让对端知道怎么解。
        //
        // ⚠️ 顺序链条（三处都会炸 / 失效，别乱动）：
        //   ① `headers.forEach` 先灌 → 里面有 `Content-Type: application/json`
        //   ② 再设 contentType（带 charset）→ 覆盖①那份，charset 才留得住
        //   ③ 最后 `add()` → **此后 headers 就 immutable 了**
        //      （实测：在 add 之后再设任何 header 会抛
        //       `HttpException: HTTP headers are not mutable`）
        req.add(utf8.encode(body));
      }

      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join();
      return LlmResponse(resp.statusCode, text);
    } on SocketException catch (e) {
      // 连不上（DNS 失败 / 无网络 / 被墙）：单独归类，别和"鉴权失败"混为一谈。
      //
      // ⚠️ 只取 `osError.message`（"Connection refused" 这种**系统**消息），
      // 不取 `exception.message`——后者是 "Failed host lookup: 'host'" 之类，
      // 会把域名带出去。分类足够定位问题，原文没必要搬运。
      lastError = e.osError?.message ?? '';
      return const LlmResponse(-1, '');
    } on TimeoutException {
      lastError = '连接或响应超时（${timeout.inSeconds}s）';
      return const LlmResponse(-2, '');
    } catch (e, st) {
      // ⚠️ 以前这里**把 `e` 整个吞掉**，UI 只能显示一句写死的
      // "接口地址可能不是合法的 http(s) 地址"——地址是对的也会这么报。
      //
      // alpha.87：真机报过 `ArgumentError`，光有类型名谁都没法定位
      // （沙箱穷举了 URL/header/超时各种非法输入，**都复现不出来**）。
      // 所以这里额外附上**脱敏后**的原始异常详情——既让用户看到真正原因，
      // 又不把密钥/URL 带出去（见 [safeErrorDetail]）。
      //
      // alpha.88：再加上 `st`。alpha.87 的详情只有 message，而 message 里
      // 只有**数据**（那段被拒的请求体），没有**调用点**；真机反馈回来的
      // 信息因此仍然不足以定位。堆栈才有调用点。
      lastError = '${describeTransportError(e)}'
          '｜详情：${safeErrorDetail(e, stack: st)}'
          '｜URL：${redactUrlForLog(url)}';
      return const LlmResponse(-3, '');
    } finally {
      client?.close(force: true);
    }
  }
}

/// URL 打码：保留 scheme/host/path，**丢掉 query 与 fragment**。
///
/// query 里可能带 `?token=xxx`（我们接入说明里就给了这种连法），
/// 原样显示等于把凭证抄进 UI。
String redactUrlForLog(Uri url) {
  final base = '${url.scheme}://${url.host}${url.path}';
  return url.hasQuery || url.hasFragment ? '$base?…' : base;
}

/// 测试用：按队列返回预设响应（也能预设抛异常）。
///
/// ⚠️ 构造时**把传入的列表复制一份**（`List.of`），不要直接改调用方的列表。
///
/// 为什么：调用方常常写 `getResponses: [LlmResponse(200, '{}')]` 这样的
/// **字面量**；若外面再套了 `const`（消 lint 时会），拿到的是**不可变列表**，
/// `removeAt` 会抛 `Unsupported operation: Cannot remove from an unmodifiable
/// list`——报错还落在 fake 内部，看起来像被测代码坏了。
/// 复制一份既支持 `const` 字面量，也不会有"测试跑两次结果不同"的副作用。
class FakeLlmTransport implements LlmTransport {
  FakeLlmTransport(List<LlmResponse> responses, {List<LlmResponse>? getResponses})
      : responses = List.of(responses),
        getResponses = getResponses == null ? null : List.of(getResponses);

  final List<LlmResponse> responses;

  /// GET 的预设响应（与 post 分开，避免两种请求互相吃掉队列）。
  /// 传 null 表示"这个 fake 不支持 GET"，会退化成 -1。
  final List<LlmResponse>? getResponses;

  final List<Uri> seen = [];
  final List<String> bodies = [];

  @override
  Future<LlmResponse> post(
    Uri url,
    Map<String, String> headers,
    String body,
  ) async {
    seen.add(url);
    bodies.add(body);
    if (responses.isEmpty) return const LlmResponse(-1, '');
    return responses.removeAt(0);
  }

  @override
  Future<LlmResponse> get(
    Uri url,
    Map<String, String> headers,
  ) async {
    seen.add(url);
    final q = getResponses;
    if (q == null || q.isEmpty) return const LlmResponse(-1, '');
    return q.removeAt(0);
  }
}

/// 从 `/models` 响应体里解出模型 id 列表（纯函数）。
///
/// 标准 OpenAI 兼容形状：
/// ```json
/// {"object":"list","data":[{"id":"deepseek-v4-flash","object":"model"}, ...]}
/// ```
/// 少数网关直接给 `["a","b"]` 或 `{"models":[...]}`，一并兼容——
/// 这个接口各家实现参差，**多认几种形状比严格只认一种更实用**。
///
/// ⚠️ 返回时**去重 + 排序**：列表要直接喂给下拉框，重复项会让用户困惑
/// （有些网关会把同一个模型以不同 owner 返回多次）。
List<String> parseModelIds(String raw) {
  try {
    final m = jsonDecode(raw);
    List<dynamic>? list;
    if (m is Map) {
      final d = m['data'] ?? m['models'];
      if (d is List) list = d;
    } else if (m is List) {
      list = m;
    }
    if (list == null) return const [];

    final ids = <String>{};
    for (final item in list) {
      if (item is String) {
        if (item.trim().isNotEmpty) ids.add(item.trim());
      } else if (item is Map) {
        final id = item['id'] ?? item['name'] ?? item['model'];
        if (id is String && id.trim().isNotEmpty) ids.add(id.trim());
      }
    }
    final out = ids.toList()..sort();
    return out;
  } catch (_) {
    // 不是 JSON / 结构不认识：返回空，交给调用方提示
    return const [];
  }
}

/// 把 baseUrl 归一化成 `/models` 端点（纯函数）。
///
/// 与 [_endpoint] 是姊妹函数，但**不能复用**：`/models` 挂在 base 上，
/// 而 `/chat/completions` 要保留 `/v1`。规则：
/// - 已以 `/models` 结尾 → 原样；
/// - 已以 `/chat/completions` 结尾 → 砍掉它再拼 `/models`
///   （用户可能直接把完整端点粘进 baseUrl）；
/// - 其余 → 在末尾拼 `/models`（`/v1` 保留，DeepSeek/OpenAI 都认）。
Uri? modelsEndpoint(String baseUrl) {
  var s = baseUrl.trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    s = 'https://$s';
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('/chat/completions')) {
    s = s.substring(0, s.length - '/chat/completions'.length);
  }
  if (!s.endsWith('/models')) s = '$s/models';
  return Uri.tryParse(s);
}

/// 拉取可用模型列表的结果。
class ModelListResult {
  final List<String> models;

  /// 失败原因（成功时为 ''）。
  final String error;

  const ModelListResult(this.models, this.error);

  bool get ok => models.isNotEmpty;
}

/// 拉取 `GET {baseUrl}/models`（纯逻辑，transport 可注入）。
///
/// ## 为什么要有这个（alpha.90）
/// 用户问得很好："别的程序可以不填模型名然后自己选，为什么这里不行？"
/// ——**答不上来，因为我上一版就是在回避问题**：把"留空"拦下让用户自己
/// 查文档，等于把成本推给人。正确做法是拉列表让他选。
///
/// 额外好处：**这个请求本身就是一次连通性 + 密钥校验**。
/// 能拉到列表 → 地址对、密钥对、网络通。比让用户盲填强得多。
Future<ModelListResult> fetchModels({
  required String baseUrl,
  required String apiKey,
  LlmTransport? transport,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final url = modelsEndpoint(baseUrl);
  if (url == null) {
    return const ModelListResult([], '接口地址不是合法的 http(s) 地址');
  }
  final t = transport ?? IoLlmTransport(timeout: timeout);
  final resp = await t.get(url, {
    // 与 post 走同一套清洗，理由见 [sanitizeToken]
    'Authorization': 'Bearer ${sanitizeToken(apiKey)}',
  });

  if (resp.status != 200) {
    final detail = t is IoLlmTransport ? t.lastError : '';
    return ModelListResult(
      [],
      describeHttpError(
        resp.status,
        detail: detail,
        serverMessage: errorMessageFromBody(resp.body),
      ),
    );
  }

  final ids = parseModelIds(resp.body);
  if (ids.isEmpty) {
    // 200 但解不出模型：接口可能不是 OpenAI 兼容的
    return const ModelListResult(
      [],
      '接口返回了 200，但里面没有模型列表'
      '（该地址可能不是 OpenAI 兼容接口）',
    );
  }
  return ModelListResult(ids, '');
}

/// 构造 chat/completions 请求体（纯函数）。
///
/// 温度压到 0.2：补全代码要的是"最可能的那段"，不是创意写作。
Map<String, dynamic> buildChatBody({
  required String model,
  required String system,
  required String user,
  int maxTokens = 2048,
  double temperature = 0.2,
}) =>
    {
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'max_tokens': maxTokens,
      'temperature': temperature,
      'stream': false,
    };

/// 从响应体取 `choices[0].message.content`（纯函数）。
///
/// 返回 null 表示"解析不出内容"——调用方据此走"疑似非代码"分支，
/// 而不是把整段 JSON 当成代码插进编辑器。
String? parseChatContent(String raw) {
  try {
    final m = jsonDecode(raw);
    if (m is! Map<String, dynamic>) return null;
    final choices = m['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, dynamic>) return null;
    final msg = first['message'];
    final content = msg is Map ? msg['content'] : null;
    if (content is String) return content;
    // 少数兼容层把内容直接放在 choices[0].text
    final text = first['text'];
    if (text is String) return text;
    return null;
  } catch (_) {
    return null;
  }
}

/// 从**错误响应体**里摘出服务端给的原因（纯函数，返回 '' 表示摘不出）。
///
/// ## 为什么要这么做（alpha.89）
/// 真机实录：编码修好之后错误变成 `请求失败（HTTP 400）`——
/// **有状态码，没有原因**。而服务端其实写得很清楚，DeepSeek 的 400 长这样：
/// ```json
/// {"error":{"message":"...具体哪里不对...","type":"invalid_request_error"}}
/// ```
/// 只报状态码等于把最有用的那段丢了。这是同一个毛病的**第三次**复发
/// （前两次见 Bug 620 / 623）：**有信息，但不给出来**。
///
/// ## 为什么只取 `error.message`，不整段回显
/// 整段 JSON 回显有两个风险：
/// ① 401 的响应体可能带组织 / 账号标识，是泄漏面；
/// ② 长 JSON 会把 UI 撑爆。
/// 所以只认标准 OpenAI 兼容形状的 `error.message`，其余一律返回 ''，
/// 交给调用方走"只说状态码"的老路。
///
/// ⚠️ 摘出来的串**仍要过一遍 [redactSecrets]**：服务端可能把它收到的
/// 密钥片段回显在错误里（DeepSeek 就是这么干的：`Your api key: ****-key`）。
String errorMessageFromBody(String body) {
  if (body.isEmpty) return '';
  try {
    final m = jsonDecode(body);
    if (m is! Map) return '';
    final err = m['error'];
    // 形状 A：{"error": {"message": "..."}}（OpenAI / DeepSeek / 多数兼容层）
    if (err is Map) {
      final msg = err['message'];
      if (msg is String && msg.trim().isNotEmpty) {
        return _redactSecrets(msg.trim());
      }
      final code = err['code'];
      if (code is String && code.trim().isNotEmpty) {
        return _redactSecrets(code.trim());
      }
      return '';
    }
    // 形状 B：{"error": "some string"}（少数网关）
    if (err is String && err.trim().isNotEmpty) {
      return _redactSecrets(err.trim());
    }
    // 形状 C：{"message": "..."}（部分自建网关直接放顶层）
    final top = m['message'];
    if (top is String && top.trim().isNotEmpty) {
      return _redactSecrets(top.trim());
    }
    return '';
  } catch (_) {
    // 不是 JSON（HTML 错误页 / 纯文本）：**不搬运**。
    // 这类内容常含网关地址与内部信息，且没有稳定的结构可摘。
    return '';
  }
}

/// 剥掉 Markdown 代码围栏（纯函数）。
///
/// LLM 几乎一定会用 ```` ```dart ```` 包代码，直接插入会把围栏一起写进
/// 源文件。只剥**首尾成对**的围栏，正文里出现的代码块保持不动。
String extractCode(String raw) {
  final s = raw.trim();
  final fence = RegExp(r'^```[A-Za-z0-9_+.-]*\r?\n');
  final m = fence.firstMatch(s);
  if (m == null) return s;
  final body = s.substring(m.end);
  final closing = body.lastIndexOf('```');
  if (closing < 0) return s; // 没闭合——宁可原样返回让人看，也别瞎切
  return body.substring(0, closing).replaceAll(RegExp(r'\s+$'), '');
}

/// 一行"像代码"的宽松判据。
///
/// 判据宁可放宽：漏标（该警示却没警示）只会让人多点一下预览，误标
/// （把 `final a = 1;` 当成聊天腔）会让整个补全功能看起来是坏的。
/// 所以这里把"关键字 / 赋值 / 收尾括号 / 代码标点收尾"都算上，而不是
/// 只认少数几种开头。
final RegExp _kCodeLine = RegExp(
  r'^(//|#|/\*|\*|@|import |from |package |using |require\()' // 注释·导入·注解
  r'|^(if|else|for|while|do|switch|case|return|class|struct|enum|interface'
  r'|func|function|def|void|int|var|val|let|const|final|static|public'
  r'|private|new|try|catch|throw|async|await|yield|print|println)\b'
  r'|^[\w$<>.\[\]()]+\s*[-+*/%|&^]?=(?!=)' // 赋值（排除 == 比较也算）
  r'|^[}\])>]' // 收尾括号
  r'|[;{}(),]$' // 以典型代码标点收尾
  r'|=>|->', // 箭头（Dart/C++/JS 都有）
);

/// 聊天腔特征：出现一个就认为"外面裹了解说"。
///
/// 这些词几乎不会出现在纯代码里（若真出现在字符串里，代价只是多一个
/// 警示标，用户点开预览一眼就能放行）。
final RegExp _kChatty = RegExp(
  r'(好的|以下是|这是您|希望|如果|请问|抱歉|当然|需要注意的是|如上所述|说明[:：])',
);

/// 粗判"这像不像代码"（纯函数，用于给预览打警示标）。
///
/// 要点是拦住"好的，以下是您要的代码："这类聊天腔——它一旦被当成代码
/// 插入，整份文件就废了。判据是**代码行占比 ≥ 一半**，且只要裹了解说
/// 就直接判否：宁可让用户多看一眼，也别静默写坏文件。
bool looksLikeCode(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  final lines = t.split('\n');
  final nonEmpty = lines.where((l) => l.trim().isNotEmpty).toList();
  if (nonEmpty.isEmpty) return false;
  // 裹了解说：哪怕里面夹着代码，也要提示用户先看一眼
  if (nonEmpty.any((l) => _kChatty.hasMatch(l))) return false;
  final codeish =
      nonEmpty.where((l) => _kCodeLine.hasMatch(l.trimLeft())).length;
  return codeish * 2 >= nonEmpty.length;
}

/// HTTP 错误的中文解释（纯函数）。
///
/// ⚠️ 这里的文案**绝不能回显请求体或密钥**：401 的响应体里可能带
/// 组织信息，日志/提示里打出来就是一个泄漏面。
///
/// [detail] 是传输层留下的分类说明（见 [IoLlmTransport.lastError]）。
/// 传进来时会**替换**掉下面那句猜测文案——猜错原因比不给原因更坏：
/// 真机实录里地址完全正确，却被告知"地址可能不是合法的 http(s) 地址"。
///
/// [serverMessage] 是**服务端自己给的原因**（见 [errorMessageFromBody]）。
/// 它比我们任何猜测都准，所以**优先级最高**：只要拿到了，就用它。
/// alpha.89 之前只报 `请求失败（HTTP 400）`，把 DeepSeek 写好的
/// `error.message` 丢了——那是能直接定位问题的一句话。
String describeHttpError(
  int status, {
  String detail = '',
  String serverMessage = '',
}) {
  // ⚠️ 服务端给的原因优先。它知道具体哪个字段不合法，我们不知道。
  // 但**空串不算**——摘不出就继续走下面的分类。
  if (serverMessage.isNotEmpty) return '服务端拒绝：$serverMessage';

  switch (status) {
    case -1:
      return detail.isEmpty
          ? '连不上接口（检查网络，内置 LLM 需要外网）'
          : _netHint('', detail).replaceFirst('连不上 ', '连不上接口 ');
    case -2:
      return detail.isEmpty ? '请求超时（可适当缩短上下文或换个模型重试）' : detail;
    case -3:
      // detail 非空时直接采用：那是传输层给的**真实分类**，不是猜测
      return detail.isEmpty ? '请求失败（原因未记录）' : detail;
    case 400:
      // 400 且**摘不出**服务端原因时才走这里。给几个最常见的自查点，
      // 但措辞必须诚实——这仍是猜测，不是结论。
      return '请求被拒（HTTP 400）：常见原因是模型名不存在、'
          '上下文超长，或接口地址多/少了一级 /v1';
    case 401:
      // 带 detail 说明是网络/握手问题而非密钥问题——这时别引导用户去改密钥
      return detail.isEmpty ? '鉴权失败：密钥或接口地址有误' : detail;
    case 403:
      return detail.isEmpty ? '鉴权失败：密钥或接口地址有误' : detail;
    case 404:
      return '接口 404：地址通常要写到 /v1 这一级';
    case 429:
      return '被限流了（429）：稍后再试';
    default:
      if (status >= 500) return '服务端错误 $status：对方接口暂时不可用';
      return '请求失败（HTTP $status）';
  }
}
