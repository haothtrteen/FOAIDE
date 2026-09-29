import '../editor/fs_bridge.dart';
import '../mcp/tunnel_service.dart';
import 'ai_backend.dart';
import 'ai_config.dart';

/// AI 助手编排（alpha.82）：读配置 → 选后端 → 跑一次 → 返回**中性结果**。
///
/// ## 为什么 alpha.82 起不再碰 UI
/// alpha.81 是这一层拿到结果后弹预览、再回调编辑器插入。问题是
/// **插入点只有编辑器自己知道**（光标在哪、要预留几行、失败怎么回滚），
/// 绕一圈回来既断又脆。用户要的是"AI 直接写进编辑器，写完再问存不存"，
/// 所以本层退化成纯粹的"跑一次 AI"：只回答**AI 说了什么**，不决定写哪。
///
/// 三态结果由调用方（编辑器页）各自处置：
/// - [AiOutcomeKind.content]：有代码文本，就地写进预留的占位区；
/// - [AiOutcomeKind.dispatched]：已派活（远程 MCP），异步无回执，别占位；
/// - [AiOutcomeKind.failure]：失败，[AiOutcome.message] 可直接给用户看。
class AiAssist {
  AiAssist({FsBridge? bridge, this.projectRoot = ''})
      : bridge = bridge ?? FsBridge();

  final FsBridge bridge;
  final String projectRoot;

  /// 请求期间置 true（MCP 派活是秒级落盘，也会短暂置 true）。
  bool busy = false;

  /// 跑一次 AI。
  ///
  /// **不抛异常**——后端、配置读取的任何意外都转成 failure 带出去，
  /// 否则编辑器页会卡在"只读 + 占位"状态出不来。
  Future<AiOutcome> run(AiJob job) async {
    AiConfig cfg;
    try {
      cfg = await AiConfigStore.load();
    } catch (_) {
      // 配置读不到（通道不可用）也要能继续：按未配置处理，派活路径仍可用
      cfg = AiConfig.unconfigured;
    }
    if (cfg.kind == AiBackendKind.builtinLlm && !cfg.llmReady) {
      return const AiOutcome.failure(
        kAiUnconfiguredMessage,
        remedy: AiRemedy.configureLlm,
      );
    }

    busy = true;
    try {
      final backend = aiBackendFrom(
        cfg,
        bridge: bridge,
        projectRoot: projectRoot,
      );
      return await backend.run(job);
    } catch (e) {
      return AiOutcome.failure('AI 请求异常：$e');
    } finally {
      busy = false;
    }
  }
}

/// 未配置内置 LLM 时的提示文案（UI 侧据此给"去设置"出口）。
const String kAiUnconfiguredMessage = '还没配置内置 LLM 的接口地址与密钥';

/// 派了活但**没人会来领**时的说明（alpha.85）。
///
/// MCP 派活是"写进 inbox 等客户端自己读"，而客户端唯一的入口就是那条
/// cloudflared 隧道。隧道没开 = 这条作业注定烂在磁盘里。这时候如果不拦
/// 一下，用户看到的仍然是"已投递，等已连隧道的 AI 客户端领取"——一句
/// **技术上真、实际上假**的话：确实投递了，但确实没人会领。
const String kAiTunnelDownMessage = '隧道没开：作业投出去也没人领得到。';

/// 隧道是否已就绪（可派活的前提）。
///
/// 抽成纯函数是为了可测：`TunnelService` 是单例 + 带进程状态，测试里
/// 直接读容易互相污染。
bool tunnelReady(TunnelStatus s) => s == TunnelStatus.running;
