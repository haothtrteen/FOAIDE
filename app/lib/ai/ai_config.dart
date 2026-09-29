import 'dart:convert';
import 'dart:io';

import '../env/proot_bridge.dart';

/// AI 后端选择（alpha.81）。
///
/// 两条路线的取舍要让用户自己定，所以这里是**显式二选一**，不做自动
/// 猜测（猜错比不选更糟：用户以为在问本地，其实整份文件已经发给别人）：
/// - [remoteMcp]：复用「AI 接管」——把作业写进项目里的 `.foa/ai-inbox.md`，
///   由已连隧道的外部 AI 客户端领取。**异步、无回执、不外发到第三方**，
///   代价是要等对方来取。
/// - [builtinLlm]：App 自己当 LLM 客户端，用户填 baseUrl/key/model，
///   **即时返回**（代价：文件内容会发到你填的那个接口）。
enum AiBackendKind { remoteMcp, builtinLlm }

/// AI 后端配置。
class AiConfig {
  final AiBackendKind kind;

  /// OpenAI 兼容接口的根地址，如 `https://api.deepseek.com/v1`。
  final String baseUrl;
  final String apiKey;
  final String model;

  const AiConfig({
    this.kind = AiBackendKind.remoteMcp,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
  });

  /// 默认（未配置）：走远程 MCP——它不需要任何密钥，也不会把代码外发。
  static const AiConfig unconfigured = AiConfig();

  /// 内置 LLM 是否**可用**（不只是"选了"，还要真的填了地址与密钥）。
  bool get llmReady =>
      kind == AiBackendKind.builtinLlm &&
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty;

  /// 任何情况下能否派活（MCP 派活只要求项目可写，与密钥无关）。
  bool get canDispatch => true;

  AiConfig copyWith({
    AiBackendKind? kind,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) =>
      AiConfig(
        kind: kind ?? this.kind,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      };

  /// 解析：任何脏数据都**不许抛**，逐字段降级。
  ///
  /// 这里是 `load()` 之外也会被 `clearKey()` 这样的路径间接依赖的公共入口，
  /// 一旦 `as String?` 硬转，字段类型不对（旧版本写入、手改文件、别的 App
  /// 写过同名文件）就会把整个读取拖进异常分支。逐字段兜底的好处是
  /// "能救回的字段照常救回"，坏字段退化成空串即可。
  static AiConfig fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return unconfigured;
    final k = raw['kind'];
    return AiConfig(
      kind: k == AiBackendKind.builtinLlm.name
          ? AiBackendKind.builtinLlm
          : AiBackendKind.remoteMcp,
      baseUrl: _str(raw['baseUrl']),
      apiKey: _str(raw['apiKey']),
      model: _str(raw['model']),
    );
  }

  static String _str(Object? v) => v is String ? v : '';
}

/// AI 配置持久化（alpha.81）。
///
/// 与 HintPrefs / EditorFontPrefs 同模式：
///   - `filesDir` 下 JSON，**刻意不用 shared_preferences**；
///   - **全异常静默**：这是体验增强，绝不能因读写失败影响编辑；
///   - 读不到 / 读坏了都回退 [AiConfig.unconfigured]。
///
/// ⚠️ 密钥是**明文**存在的：Android 应用私有目录里其他 App 读不到，
/// 但 root 环境（本项目本身就是容器/rootfs 场景）理论上可及。这是
/// 刻意接受的取舍——引入 keystore/加密存储要带一整套密钥管理，收益
/// 抵不上复杂度；换成代价就是 UI 上必须明说"明文存本机"并提供清空。
class AiConfigStore {
  static const String fileName = 'foa-ai.json';

  static Future<File> _file() async {
    final env = await ProotBridge().envInfo();
    return File('${env.filesDir}/$fileName');
  }

  static Future<AiConfig> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return AiConfig.unconfigured;
      return AiConfig.fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return AiConfig.unconfigured;
    }
  }

  static Future<void> save(AiConfig c) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(c.toJson()));
    } catch (_) {
      // 静默：存不下配置不影响编辑，UI 侧下次打开会回到未配置
    }
  }

  /// 只清密钥（保留后端选择与 baseUrl/model，方便换 key 重试）。
  static Future<void> clearKey() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString());
      if (m is! Map<String, dynamic>) return;
      m['apiKey'] = '';
      await f.writeAsString(jsonEncode(m));
    } catch (_) {}
  }
}
