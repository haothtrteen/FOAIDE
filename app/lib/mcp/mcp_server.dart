import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../editor/fs_bridge.dart';
import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../toolchain/diag_page.dart';
import '../toolchain/qemu_compat.dart';
import 'mcp_schema.dart';

/// 远程接管 · MCP 服务器（alpha.60）。
///
/// ## 为什么跑在 App 进程内
///
/// 容器里的 dart 是 x64（须经 QEMU 转发），跑长驻 HTTP 服务会让每个请求
/// 都付指令翻译开销，且 dart JIT + qemu 正是本项目最脆的一环（Bug 438/441/
/// 445/447/449 全在这条链上）；minbase 也没有 python3/socat。
/// **更关键的是**：只有跑在 App 进程内，才能把 FsBridge（Kotlin 文件通道，
/// 不占 proot executor）、diag 命令包等**结构化能力**包装成带 schema 的
/// tool —— 放容器里只能暴露一层 run_command。
///
/// ## 数据流
///
/// ```
/// 远程 AI ──HTTPS──> Cloudflare edge ──> cloudflared(容器内, arm64)
///        ──明文 HTTP 回环──> 本服务器 127.0.0.1:8977
/// ```
///
/// ## 安全姿态（本功能的设计目的就是远程代码执行，必须正视）
///
/// - **只绑 127.0.0.1**，绝不 0.0.0.0（否则局域网内任何人都可 RCE）；
/// - 令牌鉴权（32 位 hex，每次启动轮换，停止即失效）；
/// - 命令黑名单预检（[rejectReason]）；
/// - 单飞锁（[McpExecGuard]）：并发命令返回 DeviceBusy 而非排队——
///   否则用户自己敲命令会莫名卡住，等于引入一类新 Bug；
/// - 审计日志（UI 实时可见，比弹窗告知更有效）；
/// - 天然隔离：容器 / 即 rootfs，宿主文件系统不可见，破坏半径有限。
class McpServer {
  McpServer._();
  static final McpServer I = McpServer._();

  static const int port = 8977;

  /// 服务器内部地址（cloudflared 反代目标）。
  static const String localUrl = 'http://127.0.0.1:$port';

  /// 运行状态（UI 订阅）。
  final ValueNotifier<bool> runningN = ValueNotifier<bool>(false);
  bool get running => runningN.value;

  /// 当前令牌（每次 start 轮换）。
  String _token = '';
  String get token => _token;

  HttpServer? _http;

  /// 审计日志（环形缓冲；UI 实时渲染）。
  final List<McpAudit> audit = [];
  static const int maxAudit = 200;
  final ValueNotifier<int> auditRevisionN = ValueNotifier<int>(0);

  /// 单飞锁：同一时刻只跑一条 MCP 命令。
  final McpExecGuard guard = McpExecGuard();

  /// 默认工作目录（由 UI 在启动时设为当前项目根）。
  String defaultCwd = kProjectsRootMcp;

  /// 启动（幂等）。返回 null = 成功；否则错误文案。
  Future<String?> start({String? projectRoot}) async {
    if (running) return null;
    if (projectRoot != null) defaultCwd = projectRoot;
    _token = generateToken();
    try {
      // 只绑回环：这是本功能最重要的安全边界，务必不要改成 anyIPv4
      _http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } catch (e) {
      return 'MCP 服务启动失败（端口 $port 可能被占用）：$e';
    }
    runningN.value = true;
    _http!.listen(_handle, onError: (Object e) {
      addAudit('server', '连接异常：$e', ok: false);
    });
    addAudit('server', 'MCP 服务已启动 · $localUrl');
    return null;
  }

  /// 停止：先关服务器（顺带令牌失效），由调用方再停隧道。
  Future<void> stop() async {
    if (!running) return;
    runningN.value = false;
    final h = _http;
    _http = null;
    await h?.close(force: true);
    _token = '';
    addAudit('server', 'MCP 服务已停止（令牌已失效）');
  }

  void addAudit(String tool, String summary, {bool ok = true}) {
    audit.add(McpAudit(
      at: DateTime.now(),
      tool: tool,
      summary: summary,
      ok: ok,
    ));
    if (audit.length > maxAudit) {
      audit.removeRange(0, audit.length - maxAudit);
    }
    auditRevisionN.value++;
  }

  // ============================ HTTP 处理 ============================

  Future<void> _handle(HttpRequest req) async {
    try {
      await _route(req);
    } catch (e) {
      // 任何异常都必须回响应，否则隧道侧会看到悬挂连接
      try {
        _json(req.response, 500, {
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32603, 'message': '内部错误：$e'},
        });
      } catch (_) {/* 响应可能已发出 */}
    }
  }

  Future<void> _route(HttpRequest req) async {
    // 浏览器直接打开时给一句人话（GET 不是 MCP 的用法）
    if (req.method != 'POST') {
      req.response
        ..statusCode = 405
        ..headers.contentType = ContentType.text
        ..write('FOA MCP 服务器：请用 MCP 客户端以 POST 方式访问 /mcp，'
            '并携带 Authorization: Bearer <token>。');
      await req.response.close();
      return;
    }
    if (!req.uri.path.startsWith('/mcp')) {
      _json(req.response, 404, {'error': 'not found，请访问 /mcp'});
      return;
    }

    // 鉴权（三层任一命中）
    if (!isAuthorized(
      authHeader: req.headers.value('authorization'),
      altHeader: req.headers.value('x-foa-token'),
      queryToken: req.uri.queryParameters['token'],
      token: _token,
    )) {
      addAudit('auth', '鉴权失败（${req.connectionInfo?.remoteAddress.address}）',
          ok: false);
      _json(req.response, 401, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32001, 'message': 'unauthorized：令牌无效或缺失'},
      });
      return;
    }

    final body = await utf8.decoder.bind(req).join();
    final res = await dispatch(body, host: _liveHost());
    _json(req.response, res.status, res.body);
  }

  void _json(HttpResponse r, int status, Object? body) {
    r
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    r.close();
  }

  /// 真实宿主实现（生产路径）：把 JSON-RPC 落到平台桥。
  McpHost _liveHost() => McpHost(
        info: () async {
          final env = await ProotBridge().envInfo();
          return env;
        },
        runCommand: (cmd, cwd, timeoutSec) async {
          final full = 'cd ${_q(cwd)} && $cmd';
          return ProotBridge().exec(full, timeoutSec: timeoutSec);
        },
        fsList: (path) => FsBridge().list(path),
        fsRead: (path) => FsBridge().read(path),
        fsWrite: (path, content) => FsBridge().write(path, content),
        diagItems: () => DiagItem.pack(),
        qemuFill: (tpl) => QemuCompat.fill(tpl),
      );

  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  // ============================ 可测纯函数 ============================

  /// 生成 32 位 hex 令牌（`Random.secure()`，不可预测）。
  static String generateToken([Random? rnd]) {
    final r = rnd ?? Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < 32; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }

  /// 鉴权（三层任一命中即通过）。
  ///
  /// - [authHeader]：`Authorization: Bearer <token>`（首选）
  /// - [altHeader]：`X-FOA-Token: <token>`（部分客户端只让配 header）
  /// - [queryToken]：`?token=<token>`（降级项——令牌会留在对方日志里，
  ///   UI 上已标注风险，仅信任对方时使用）
  static bool isAuthorized({
    required String? authHeader,
    required String? queryToken,
    required String token,
    String? altHeader,
  }) {
    if (token.isEmpty) return false; // 未启动 → 一律拒绝
    final h = authHeader?.trim();
    if (h != null && h.isNotEmpty) {
      final v =
          h.toLowerCase().startsWith('bearer ') ? h.substring(7).trim() : h;
      if (_constEq(v, token)) return true;
    }
    final a = altHeader?.trim();
    if (a != null && a.isNotEmpty && _constEq(a, token)) return true;
    final q = queryToken?.trim();
    if (q != null && q.isNotEmpty && _constEq(q, token)) return true;
    return false;
  }

  /// 定长比较（避免按字符短路带来的时序差异；本场景风险低，
  /// 但成本几乎为零，顺手做对）。
  static bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// 破坏性命令黑名单预检。返回 null = 允许；否则返回拒绝原因。
  ///
  /// 这是**纵深防御的一层**，不是安全边界——真正的边界是「只绑回环 +
  /// 令牌 + 容器隔离」。黑名单只拦最明显的手滑与恶意指令。
  static String? rejectReason(String cmd) {
    final c = cmd.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    if (c.isEmpty) return '命令为空';

    const patterns = <String, String>{
      r'rm -rf /$': '拒绝：删除根目录',
      r'rm -rf /\s': '拒绝：删除根目录',
      r'rm -rf /root(\s|$)': '拒绝：删除用户目录根',
      r'rm -rf ~(\s|$)': '拒绝：删除用户目录根',
      r'--no-preserve-root': '拒绝：绕过根目录保护',
      r'\bmkfs': '拒绝：格式化文件系统',
      r'\bdd\s+if=': '拒绝：块设备直写',
      r'>\s*/dev/': '拒绝：直接写入块设备',
      r'chmod\s+-R\s+777\s+/': '拒绝：全盘提权',
      r':\(\)\s*\{': '拒绝：fork 炸弹',
      r'\b(wget|curl)\b[^|]*\|\s*(sh|bash)': '拒绝：管道执行下载脚本',
      r'\b(reboot|shutdown|halt|poweroff)\b': '拒绝：重启/关机指令',
    };
    for (final e in patterns.entries) {
      // caseSensitive: false —— 上面已把命令整体小写，但模式里保留了 `-R`
      // 这类习惯性大写写法；若用默认的大小写敏感匹配，`chmod -R 777 /`
      // 会被漏掉（真实事故：黑名单静默失效比没有黑名单更危险）。
      if (RegExp(e.key, caseSensitive: false).hasMatch(c)) return e.value;
    }
    return null;
  }

  /// 输出截断（>32KB 时保留头尾）。
  static const int maxOutputBytes = 32 * 1024;

  static String truncateOutput(String s, {int limit = maxOutputBytes}) {
    if (s.length <= limit) return s;
    const headLen = 16 * 1024;
    final tailLen = limit - headLen;
    final omitted = s.length - limit;
    return '${s.substring(0, headLen)}\n'
        '…[已截断 $omitted 字符]…\n'
        '${s.substring(s.length - tailLen)}';
  }

  /// JSON-RPC 分发（**纯函数式**：宿主能力经 [host] 注入，便于单测）。
  static Future<McpResponse> dispatch(
    String rawBody, {
    required McpHost host,
    McpExecGuard? guardLk,
  }) async {
    Object? msg;
    try {
      msg = jsonDecode(rawBody);
    } catch (_) {
      return McpResponse(400, _rpcError(null, -32700, 'parse error'));
    }
    if (msg is! Map) {
      return McpResponse(400, _rpcError(null, -32600, 'invalid request'));
    }
    final m = msg.cast<String, Object?>();
    final id = m['id'];
    final method = m['method'] as String? ?? '';
    final params = (m['params'] as Map?)?.cast<String, Object?>() ?? const {};

    switch (method) {
      case 'initialize':
        return McpResponse(200, {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': '2024-11-05',
            'capabilities': {
              'tools': {},
              'resources': {},
            },
            'serverInfo': {
              'name': 'foa-remote-takeover',
              'version': '0.1.0',
            },
            // 可发现性核心：AI 接入即看到环境心智模型
            'instructions': kInstructions,
          },
        });

      case 'notifications/initialized':
      case 'initialized':
        return const McpResponse(200, null); // 通知无响应体

      case 'ping':
        return McpResponse(200, {
          'jsonrpc': '2.0',
          'id': id,
          'result': {},
        });

      case 'tools/list':
        return McpResponse(200, {
          'jsonrpc': '2.0',
          'id': id,
          'result': {'tools': kTools.map((t) => t.toJson()).toList()},
        });

      case 'resources/list':
        return McpResponse(200, {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'resources': [
              {
                'uri': 'foa://guide',
                'name': 'FOA 环境指南',
                'description': '设备容器拓扑、目录结构、已知现象判读与协作约定',
                'mimeType': 'text/markdown',
              }
            ]
          },
        });

      case 'resources/read':
        final uri = params['uri'] as String? ?? '';
        if (uri != 'foa://guide') {
          return McpResponse(
              200, _rpcError(id, -32602, 'unknown resource: $uri'));
        }
        return McpResponse(200, {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'contents': [
              {
                'uri': 'foa://guide',
                'mimeType': 'text/markdown',
                'text': kGuideMarkdown,
              }
            ]
          },
        });

      case 'tools/call':
        final name = params['name'] as String? ?? '';
        final args =
            (params['arguments'] as Map?)?.cast<String, Object?>() ?? const {};
        return _callTool(id, name, args, host, guardLk);

      default:
        return McpResponse(
            200, _rpcError(id, -32601, 'method not found: $method'));
    }
  }

  static Future<McpResponse> _callTool(
    Object? id,
    String name,
    Map<String, Object?> args,
    McpHost host,
    McpExecGuard? guardLk,
  ) async {
    try {
      switch (name) {
        case 'foa_info':
          final env = await host.info();
          return McpResponse(200, _toolOk(id, _infoText(env)));

        case 'foa_diag':
          final buf = StringBuffer('## FOA 故障诊断报告\n');
          for (final it in host.diagItems()) {
            final cmd = it.command == DiagItem.scriptPlaceholder
                ? host.qemuFill(QemuCompat.verifyScript)
                : it.command;
            buf.writeln('\n### ${it.name}');
            buf.writeln('\$\$ $cmd');
            try {
              final r = await host.runCommand(cmd, '/root', it.timeoutSec);
              final out =
                  (r.stdout.trim().isNotEmpty ? r.stdout : r.stderr).trim();
              buf.writeln(out.isEmpty ? '（无输出）' : out);
              if (r.exitCode != 0) buf.writeln('[exit ${r.exitCode}]');
            } catch (e) {
              buf.writeln('执行异常：$e');
            }
          }
          return McpResponse(200, _toolOk(id, buf.toString()));

        case 'list_projects':
          final r = await host.runCommand(
              'ls -1 $kProjectsRootMcp 2>/dev/null', '/root', 30);
          final out = r.stdout.trim().isEmpty ? '(无项目)' : r.stdout.trim();
          return McpResponse(200, _toolOk(id, out));

        case 'list_dir':
          final path = args['path'] as String? ?? '';
          if (path.isEmpty) return McpResponse(200, _toolErr(id, '缺少 path'));
          final lr = await host.fsList(path);
          if (!lr.ok) {
            return McpResponse(200, _toolErr(id, lr.error ?? '列目录失败'));
          }
          final b = StringBuffer('$path\n');
          for (final e in lr.entries) {
            b.writeln('${e.isDir ? 'd' : '-'} '
                '${e.size.toString().padLeft(9)} ${e.name}${e.isDir ? '/' : ''}');
          }
          return McpResponse(200, _toolOk(id, b.toString()));

        case 'read_file':
          final path = args['path'] as String? ?? '';
          if (path.isEmpty) return McpResponse(200, _toolErr(id, '缺少 path'));
          final rr = await host.fsRead(path);
          if (!rr.ok) {
            return McpResponse(200, _toolErr(id, rr.error ?? '读取失败'));
          }
          return McpResponse(200, _toolOk(id, rr.content));

        case 'write_file':
          final path = args['path'] as String? ?? '';
          final content = args['content'] as String? ?? '';
          if (path.isEmpty) return McpResponse(200, _toolErr(id, '缺少 path'));
          final wr = await host.fsWrite(path, content);
          if (!wr.ok) {
            return McpResponse(200, _toolErr(id, wr.error ?? '写入失败'));
          }
          return McpResponse(
              200, _toolOk(id, '已写入 $path（${content.length} 字符）'));

        case 'run_command':
          final cmd = args['command'] as String? ?? '';
          if (cmd.isEmpty) {
            return McpResponse(200, _toolErr(id, '缺少 command'));
          }
          final reason = rejectReason(cmd);
          if (reason != null) {
            return McpResponse(200, _toolErr(id, reason));
          }
          final cwd = (args['cwd'] as String?)?.trim().isNotEmpty == true
              ? (args['cwd'] as String).trim()
              : '/root';
          var t = args['timeoutSec'] as int? ?? 60;
          if (t < 1) t = 1;
          if (t > 600) t = 600;

          // 单飞锁：并发直接 DeviceBusy（不排队——排队会让用户的操作莫名卡住）
          final lk = guardLk;
          if (lk != null && !lk.tryAcquire()) {
            return McpResponse(
                200,
                _toolErr(
                    id,
                    'DeviceBusy：设备上已有另一条命令正在执行'
                    '（容器为单队列执行）。请稍后重试。'));
          }
          try {
            final r = await host.runCommand(cmd, cwd, t);
            final b = StringBuffer();
            b.writeln('[exit ${r.exitCode}]  (${r.durationMs} ms)');
            if (r.stdout.trim().isNotEmpty) {
              b
                ..writeln('--- stdout ---')
                ..writeln(truncateOutput(r.stdout));
            }
            if (r.stderr.trim().isNotEmpty) {
              b
                ..writeln('--- stderr ---')
                ..writeln(truncateOutput(r.stderr));
            }
            return McpResponse(200, _toolOk(id, b.toString()));
          } finally {
            lk?.release();
          }

        default:
          return McpResponse(
              200,
              _toolErr(
                  id,
                  '未知工具：$name（可用：'
                  '${kTools.map((t) => t.name).join(', ')}）'));
      }
    } catch (e) {
      return McpResponse(200, _toolErr(id, '执行异常：$e'));
    }
  }

  static String _infoText(EnvInfo env) {
    final b = StringBuffer('## FOA 设备环境\n');
    b.writeln('- 宿主 ABI：${env.abi ?? '(未知)'}');
    b.writeln('- Android API：${env.androidSdk}');
    b.writeln('- 设备：${env.device.isEmpty ? '(未知)' : env.device}');
    b.writeln('- rootfs 已安装：${env.rootfsInstalled}');
    b.writeln('- rootfs 路径：${env.rootfsPath}');
    b.writeln('- proot 路径：${env.prootPath ?? '(未定位)'}');
    b.writeln('- Flutter SDK：/opt/flutter（x64，经 QEMU 转发）');
    b.writeln('- 项目根：$kProjectsRootMcp');
    return b.toString();
  }

  static Map<String, Object?> _toolOk(Object? id, String text) => {
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'content': [
            {'type': 'text', 'text': text}
          ],
          'isError': false,
        },
      };

  static Map<String, Object?> _toolErr(Object? id, String msg) => {
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'content': [
            {'type': 'text', 'text': msg}
          ],
          'isError': true,
        },
      };

  static Map<String, Object?> _rpcError(Object? id, int code, String msg) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': msg},
      };
}

/// JSON-RPC 响应包装（status + body；body=null 表示无响应体的通知）。
class McpResponse {
  final int status;
  final Object? body;
  const McpResponse(this.status, this.body);
}

/// 宿主能力注入（生产 = 平台桥；测试 = fake）。
///
/// 把平台交互全部收敛到这里，是 [McpServer.dispatch] 能纯函数化、
/// 进而可单测的关键。
class McpHost {
  final Future<EnvInfo> Function() info;
  final Future<ProotResult> Function(String cmd, String cwd, int timeoutSec)
      runCommand;
  final Future<FsListResult> Function(String path) fsList;
  final Future<FsReadResult> Function(String path) fsRead;
  final Future<FsResult> Function(String path, String content) fsWrite;
  final List<DiagItem> Function() diagItems;
  final String Function(String template) qemuFill;

  const McpHost({
    required this.info,
    required this.runCommand,
    required this.fsList,
    required this.fsRead,
    required this.fsWrite,
    required this.diagItems,
    required this.qemuFill,
  });
}

/// 单飞锁：同一时刻只允许一条 MCP 命令（不排队，返回 DeviceBusy）。
class McpExecGuard {
  bool _busy = false;
  bool get busy => _busy;

  /// 尝试获取；false = 已被占用。
  bool tryAcquire() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  void release() => _busy = false;
}

/// 审计记录（UI 渲染用）。
class McpAudit {
  final DateTime at;
  final String tool;
  final String summary;
  final bool ok;

  const McpAudit({
    required this.at,
    required this.tool,
    required this.summary,
    this.ok = true,
  });

  String get timeLabel {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }
}
