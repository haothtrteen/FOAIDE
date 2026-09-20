import 'dart:async';
import 'package:flutter/foundation.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../toolchain/build_notify.dart';
import '../toolchain/build_runner.dart';
import 'cloudflared_install.dart';
import 'mcp_server.dart';

/// cloudflared 隧道状态。
enum TunnelStatus { idle, installing, starting, running, error }

/// 远程接管 · 隧道服务（alpha.60）。
///
/// 结构照搬 BuildRunner / WebPreviewService（全局单例 + ValueNotifier +
/// execStream 轮询），保证「会话与页面解耦」：退出页面隧道照跑。
///
/// ## 数据流
///
/// ```
/// 远程 AI ──HTTPS──> Cloudflare edge ──> cloudflared（容器内 arm64 原生）
///        ──明文 HTTP 回环──> McpServer（App 进程 127.0.0.1:8977）
/// ```
///
/// **cloudflared 跑容器内而非 App 进程**：它是 Linux arm64 静态二进制，
/// 跑在 Debian 容器里原生执行（零 QEMU 开销），且容器与 App 共享网络
/// 命名空间（proot 不隔离网络）——127.0.0.1:8977 天然可达。
class TunnelService {
  TunnelService._();
  static final TunnelService I = TunnelService._();

  final ProotBridge bridge = ProotBridge();

  final ValueNotifier<TunnelStatus> statusN =
      ValueNotifier<TunnelStatus>(TunnelStatus.idle);

  TunnelStatus get status => statusN.value;
  set status(TunnelStatus s) => statusN.value = s;

  bool get busy =>
      status == TunnelStatus.installing || status == TunnelStatus.starting;

  /// 隧道公网地址（运行中才有值）。
  String? url;

  /// 最近错误。
  String? error;

  /// 剩余时间（秒）；到 0 自动停止。null = 不限时（未运行）。
  int? remainSec;

  /// 已运行耗时（秒）。
  int elapsedSec = 0;

  final List<String> lines = [];
  static const int _maxLines = 800;

  /// 默认自动停止时长（30 分钟）——对外提供 RCE 的时间窗口应尽量短。
  static const int defaultSessionSec = 30 * 60;

  int _streamId = -1;
  int _offset = 0;
  DateTime? _startedAt;
  Timer? _timer;
  bool _stopping = false;
  int? firstUrlSec;

  // ---- UI 钩子 ----
  void Function()? onUiChanged;

  void _ui() => onUiChanged?.call();

  static String fmtDur(int sec) => BuildRunner.fmtDur(sec);

  // ============================ 可测纯函数 ============================

  /// 启动命令（execStream 常驻）。
  ///
  /// 关键点：
  /// - **`2>&1` 必须**：cloudflared 的日志走 **stderr**（含隧道 URL 行），
  ///   不合并到 stdout 就永远解析不到 URL；
  /// - `--protocol http2`：默认走 QUIC，国内网络常被掐断；http2 更稳；
  /// - `--no-autoupdate`：否则后台自更新会写文件、干扰进程回收。
  static String startCommand({required String bin, required int port}) =>
      'test -x $bin || exit 71; '
      'exec $bin tunnel --url http://127.0.0.1:$port '
      '--protocol http2 --no-autoupdate --loglevel info 2>&1';

  /// 从 cloudflared 日志中抽取隧道 URL（纯函数）。
  ///
  /// 只认 `*.trycloudflare.com`——天然排除 `http://127.0.0.1:xxxx/metrics`
  /// 这类同样含 http 的干扰行。
  static final RegExp _tunnelUrlRe =
      RegExp(r'https://[a-zA-Z0-9][a-zA-Z0-9-]*\.trycloudflare\.com');

  static String? extractTunnelUrl(String log) =>
      _tunnelUrlRe.firstMatch(log)?.group(0);

  /// 待机域名（隧道就绪前 cloudflared 也会打印，须排除）。
  static const String _placeholderHost = 'api.trycloudflare.com';

  /// 就绪判定（排除占位域名）。
  static bool isReadyLog(String log) {
    final u = extractTunnelUrl(log);
    return u != null && !u.contains(_placeholderHost);
  }

  /// 启动超时（秒）：境外连通性问题常见，120s 足够判定失败。
  static const int startTimeoutSec = 120;

  // ============================ 启动 ============================

  /// 启动隧道：确保 MCP 服务在跑 → 确保 cloudflared 已装 → 起隧道。
  /// 返回 null = 成功进入 starting；否则错误文案。
  Future<String?> start({
    required String projectRoot,
    required EnvInfo env,
    int sessionSec = defaultSessionSec,
  }) async {
    if (busy || status == TunnelStatus.running) return '隧道已在运行';

    // 会话初始化
    lines.clear();
    error = null;
    url = null;
    elapsedSec = 0;
    remainSec = sessionSec;
    firstUrlSec = null;
    _stopping = false;
    _ui();

    // ① MCP 服务器（App 进程内）
    status = TunnelStatus.starting;
    _log('▶ 启动 MCP 服务器（127.0.0.1:${McpServer.port}）…');
    final mcpErr = await McpServer.I.start(projectRoot: projectRoot);
    if (mcpErr != null) {
      status = TunnelStatus.error;
      error = mcpErr;
      _log('✗ $mcpErr');
      _ui();
      return mcpErr;
    }

    // ② cloudflared（容器内 arm64 原生）
    status = TunnelStatus.installing;
    _log('▶ 检查 cloudflared（arm64，容器内原生执行）…');
    _ui();
    final inst = CloudflaredInstall(bridge);
    final instErr = await inst.ensure(env: env, onLog: _log);
    if (instErr != null) {
      status = TunnelStatus.error;
      error = instErr;
      _log('✗ $instErr');
      _ui();
      await McpServer.I.stop();
      return instErr;
    }

    // ③ 起隧道
    status = TunnelStatus.starting;
    _log('▶ 建立隧道（Cloudflare quick tunnel）…');
    _log('  说明：公网可访问，任何拿到令牌的人都可操作本机容器——用完即停。');
    _ui();

    final cmd = startCommand(bin: CloudflaredInstall.binPath, port: McpServer.port);
    final stream = await bridge.execStream(cmd);
    if (!stream.ok || stream.id <= 0) {
      status = TunnelStatus.error;
      error = '隧道启动失败：${stream.error ?? '未知错误'}';
      _log('✗ $error');
      _ui();
      await McpServer.I.stop();
      return error;
    }
    _streamId = stream.id;
    _offset = 0;
    _startedAt = DateTime.now();

    BuildNotify.lastRoute = 'takeover';
    BuildNotify.start('远程接管 · MCP 已开启');
    BuildNotify.progress('隧道建立中…', 0);

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _poll());
    return null;
  }

  // ============================ 轮询 ============================

  Future<void> _poll() async {
    final poll = await bridge.execStreamPoll(_streamId, _offset);
    if (!poll.ok) {
      _timer?.cancel();
      if (_stopping) return;
      await _fail('隧道日志轮询失败：${poll.error ?? '未知错误'}');
      return;
    }
    _appendChunk(poll.chunk);
    _offset = poll.len;

    final t = _startedAt;
    if (t != null) {
      elapsedSec = DateTime.now().difference(t).inSeconds;
      final r = remainSec;
      if (r != null) remainSec = (r - 1).clamp(0, 1 << 30);
    }

    if (!poll.running) {
      _timer?.cancel();
      if (_stopping) return;
      await _fail('隧道进程已退出（exit ${poll.exitCode}）· '
          '多为境外连通性问题，可重试或换网络');
      return;
    }

    // 自动停止：RCE 窗口不宜常开
    if (remainSec != null && remainSec! <= 0) {
      await stop(reason: '已达会话时限（${fmtDur(defaultSessionSec)}），已自动停止');
      return;
    }
    _ui();
  }

  void _appendChunk(String chunk) {
    final clean = chunk.replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '');
    for (final raw in clean.split('\n')) {
      final line = raw.split('\r').last.trimRight();
      if (line.isEmpty) continue;
      lines.add(line);
      if (status != TunnelStatus.running && isReadyLog(line)) {
        final u = extractTunnelUrl(line)!;
        url = u;
        firstUrlSec = elapsedSec;
        status = TunnelStatus.running;
        _log('');
        _log('✓ 隧道已就绪：$u');
        _log('  外部 AI 已可接入（记得把地址与令牌一起给它）。');
        _log('');
        BuildNotify.progress('运行中 · $u', 100);
      }
    }
    if (lines.length > _maxLines) {
      lines.removeRange(0, lines.length - _maxLines);
      lines[0] = '[日志截断，仅显示最近 $_maxLines 行]';
    }
  }

  Future<void> _fail(String msg) async {
    status = TunnelStatus.error;
    error = msg;
    _log('✗ $msg');
    _ui();
    BuildNotify.finish('✗ 远程接管已中断');
    await McpServer.I.stop();
  }

  // ============================ 停止 ============================

  /// 停止隧道：**两件事都必须做**——关隧道进程 + 关 MCP 服务器。
  /// 只做其一都会留下暴露面（进程活着但服务关了 = 无害；
  /// 服务活着但没隧道 = 局域网仍可直连 127.0.0.1，虽风险低但不应留）。
  Future<void> stop({String? reason}) async {
    if (_stopping) return;
    _stopping = true;
    _timer?.cancel();
    if (_streamId > 0) {
      await bridge.execStreamStop(_streamId);
      _streamId = -1;
    }
    await McpServer.I.stop();
    status = TunnelStatus.idle;
    url = null;
    remainSec = null;
    _startedAt = null;
    if (reason != null) _log('■ $reason');
    _log('■ 隧道与 MCP 服务均已停止（令牌已失效）');
    _ui();
    BuildNotify.finish('远程接管已停止');
  }

  /// 续期（重置剩余时间）。
  void extend([int sec = defaultSessionSec]) {
    if (status != TunnelStatus.running) return;
    remainSec = sec;
    _log('· 会话已续期 ${fmtDur(sec)}');
    _ui();
  }

  void _log(String s) => lines.add(s);
}

/// 会话剩余时间的 mm:ss 文案（纯函数，便于单测/UI 复用）。
String remainLabel(int? sec) {
  if (sec == null) return '--:--';
  final m = sec ~/ 60;
  final s = sec % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 生成「交给你的 AI」的预填提示词（纯函数）。
///
/// 这是“让远程 AI 知道能干什么”最省事也最有效的落地：把环境上下文
/// 直接塞进提示词，而不是指望 AI 从零探索（它探索一次要花好几轮工具调用）。
String buildHandoffPrompt({
  required String? tunnelUrl,
  required String token,
  required String projectName,
  required String projectRoot,
}) {
  final u = tunnelUrl ?? '(隧道尚未就绪)';
  return '''
我给你接了一台**真机上的 Flutter 开发环境（FOA）**，它跑在 Android 手机的
Debian arm64 容器里，已装 Flutter SDK。请通过 MCP 连接并帮我处理这个项目。

【接入方式】
- MCP 地址（Streamable HTTP，POST 到 /mcp）：$u/mcp
- 鉴权：Authorization: Bearer $token
- 若客户端只支持填一个 URL，可用：$u/mcp?token=$token

【当前项目】
- 名称：$projectName
- 容器内路径：$projectRoot

【你可以做什么】
- foa_info：查看设备/环境信息（建议先调）
- foa_diag：一键拿到 8 项环境诊断报告
- read_file / write_file / list_dir：读写项目文件
- list_projects：列出所有项目
- run_command：在容器内执行 shell 命令

【必须注意】
1. 这是真实用户的手机，请勿执行破坏性命令（rm -rf、mkfs、格式化等）。
2. flutter 命令经 QEMU 转发层执行，**比 PC 慢一个数量级是正常的**；
   首次 Web 编译 3-8 分钟不奇怪，不是卡死。
3. 构建 APK 与 Web 预览**互斥**（共用 Flutter 启动锁），
   执行前请先问我。
4. 写入文件是**覆盖写**，改代码前请先 read_file 看清现状。

【建议开场】
先调用 foa_info 建立环境认知；需要排查环境问题时调用 foa_diag；
如需更多细节，读取 resource `foa://guide`。
''';
}
