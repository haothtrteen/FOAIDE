import 'dart:async';
import 'dart:io' show HttpClient;

import 'package:flutter/foundation.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../toolchain/build_notify.dart';
import '../toolchain/build_runner.dart';
import '../toolchain/qemu_compat.dart';
import '../toolchain/toolchain_ensure.dart';

/// Web 实时预览会话状态。
enum WebPreviewStatus { idle, starting, running, error }

/// Bug 454 · 就绪裁决结果（alpha.60）。
///
/// - [waiting]：还没就绪，继续等（UI 显示 stageLabel 的真实阶段）；
/// - [ready]：命中日志 marker，最可靠的信号，正常进 WebView；
/// - [degrade]：端口已通但宽限期内没等到 marker → **降级放行**，
///   宁可让用户看到页面（哪怕是空白页 + 提示用系统浏览器），
///   也不要他对着「编译中」无限干等。
enum WebReadyDecision { waiting, ready, degrade }

/// Web 实时预览执行器：全局单例（alpha.57）。
///
/// 设计照搬 BuildRunner（构建页同款「会话与页面生命周期解耦」）：
/// - 编辑器顶栏只是入口，预览控制台页只是视图——退出页面/锁屏预览照跑
///   （前台服务 BuildNotify 保活）；用户切到浏览器看效果，回 App 一键热重载；
/// - 通道复用 ProotBridge 的 execStream 三件套（启动/轮询/停止），
///   **无任何新平台代码**；
/// - 与构建互斥：两者共用 Flutter 工具链的启动锁（bin/cache/lockfile），
///   并发必然互相卡「Waiting for another flutter command」。
///
/// 原理（alpha.57 定稿）：
/// - `flutter run -d web-server` 是常驻进程；web 编译走 DDC/kernel，
///   只依赖 dart（qemu 转发链路，pub get 同款已验证路径）——绕开
///   AOT gen_snapshot / Gradle / NDK 三大重器，是全工具链里最轻的路径；
/// - 热重载不用「切终端按 r」：flutter_tools 注册了 POSIX 信号处理
///   （SIGUSR1=热重载 / SIGUSR2=热重启）。启动命令先 `echo $$ > pidFile`
///   再 `exec flutter run`（exec 进程内替换，pid 不变），之后任意时刻
///   `kill -USR1 $(cat pidFile)` 即触发——全程普通 exec 通道即可，
///   无需 PTY；
/// - 端口固定 8090 → URL 恒定，浏览器打开不依赖日志解析（日志解析只做
///   ready 判定的辅助信号，见 [isReadyLine]）。
///
/// 边界：
/// - proot 容器后端限定（termux bionic flutter 的 web 目标未验证，不开放）；
/// - execStream 默认超时 7200s = 预览最长 2 小时，到时进程被平台侧回收，
///   UI 提示重新启动即可；
/// - proot executor 是单线程队列：热重载的 kill 命令会与日志 poll 错峰
///   排队执行（毫秒级），不构成等待问题。
class WebPreviewService {
  WebPreviewService._();
  static final WebPreviewService I = WebPreviewService._();

  final ProotBridge bridge = ProotBridge();

  /// 状态通知器：编辑器顶栏按钮据其变脸（运行中变热重载键）。
  final ValueNotifier<WebPreviewStatus> statusN =
      ValueNotifier<WebPreviewStatus>(WebPreviewStatus.idle);

  WebPreviewStatus get status => statusN.value;
  set status(WebPreviewStatus s) => statusN.value = s;

  bool get busy =>
      status == WebPreviewStatus.starting || status == WebPreviewStatus.running;

  /// 预览地址（固定端口，编译完成前后恒定——Android 浏览器与容器共享
  /// 网络命名空间，proot 不隔离网络，127.0.0.1 直接可达）。
  static const int port = 8090;
  static const String url = 'http://127.0.0.1:$port';

  /// flutter run 进程 pid 文件（容器内路径）。
  static const String pidFile = '/tmp/foa_web_preview.pid';

  // ---- 会话状态（预览页读这些渲染）----
  String? projName;
  final List<String> lines = [];
  String partial = '';
  String? error;

  /// 已运行耗时（秒）。
  int elapsedSec = 0;

  int _streamId = -1;
  int _offset = 0;
  DateTime? _startedAt;
  Timer? _timer;
  bool _stopping = false;
  bool _reloadBusy = false; // 热重载防抖（连点）

  // ---- Bug 454（alpha.60）：三段式就绪判定的运行时状态 ----
  /// 端口探测结果（true = 8090 已在监听）。
  bool portOpen = false;

  /// 上次端口探测时刻（节流用）。
  DateTime? _lastProbeAt;

  /// 是否已放行（ready / degrade 都算），防止重复触发。
  bool _released = false;

  /// 首次就绪耗时（秒）——埋点：用于后续决定是否投入「预热」优化。
  int? firstReadySec;

  // ---- UI 钩子（页面 attach 注入，dispose 解绑；null = 预览在后台跑）----
  void Function()? onUiChanged;
  void Function()? onAutoScroll;

  static const int _maxLines = 2000;

  void _ui() => onUiChanged?.call();
  void _scroll() => onAutoScroll?.call();

  /// 秒 → mm:ss / h:mm:ss（复用构建页同款格式）。
  static String fmtDur(int sec) => BuildRunner.fmtDur(sec);

  /// shell 单引号转义（项目名可能含空格/特殊字符）。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  // ============================ 可测纯函数 ============================

  /// 启动互斥判定（UI 与 service 双侧共用同一文案）。
  /// 返回 null = 允许启动；否则返回给用户的错误文案。
  static String? mutexError({
    required bool building,
    required bool previewBusy,
    required bool bare,
  }) {
    if (bare) return 'Web 预览暂仅支持容器（proot）后端';
    if (building) {
      return '正在构建中：构建与预览共用 Flutter 工具链（启动锁），'
          '请等构建完成或取消后再启动预览';
    }
    if (previewBusy) return '预览已在运行';
    return null;
  }

  /// 残留会话清理（幂等）：上次预览若因 App 被强杀留下孤儿 flutter run，
  /// 端口会被占死 → 新预览必败。启动命令内联在同一条 shell 里先清场。
  static String staleCleanupCommand(String pidFilePath) =>
      'if [ -f $pidFilePath ]; then '
      'n=\$(cat $pidFilePath 2>/dev/null); '
      'if [ -n "\$n" ] && kill -0 \$n 2>/dev/null; then '
      'kill \$n 2>/dev/null; sleep 1; kill -9 \$n 2>/dev/null; fi; '
      'rm -f $pidFilePath; fi; ';

  /// 热重载/热重启信号命令（经普通 exec 通道执行，毫秒级）。
  /// [signal] 传 '-USR1'（热重载）或 '-USR2'（热重启）。
  /// 进程已不在时输出 GONE（供上层判定会话已死）。
  static String signalCommand(String pidFilePath, String signal) =>
      'n=\$(cat $pidFilePath 2>/dev/null); '
      'if [ -n "\$n" ] && kill -0 \$n 2>/dev/null; then '
      'kill $signal \$n && echo RELOADED; else echo GONE; fi';

  /// ready 信号词（多信号 OR，命中任一即认为 serve 已就绪）。
  /// 不赌单一日志格式：不同 Flutter 版本 web-server 的 URL 行措辞不一，
  /// 但 VM service / debug service / key commands 必然其一出现。
  static const List<String> readyMarkers = <String>[
    'running on http',
    'is being served at',
    'dart vm service',
    'debug service listening',
    'flutter run key commands',
  ];

  /// ready 判定（行级；大小写不敏感——flutter 日志大小写有版本差异）。
  static bool isReadyLine(String line) {
    final l = line.toLowerCase();
    for (final m in readyMarkers) {
      if (l.contains(m)) return true;
    }
    return false;
  }

  // ---- Bug 454：ready 三段式判定（真机「假编译中」修复，alpha.60）----
  //
  // 症状：日志已打印 `Launching lib/main.dart on Web Server in debug mode...`，
  // 进度卡却永远停在「编译中…」（真机实测 10 分钟+）。
  //
  // 真因：DDC 首次编译期**不输出任何 marker 行**（只有 Launching/Waiting，
  // 两者均不命中 readyMarkers——见 web_preview_test.dart 的显式断言），
  // 而 ready 判定只在 status==starting 时跑且**没有任何超时兜底**，
  // 唯一终态是进程退出。WebView 又只在 running 时构造 → 永不加载。
  //
  // 修复：把「就绪」拆成三重信号——
  //   ① 日志 marker（原有，最快）；
  //   ② 端口探测（**最硬的事实**：服务器真的在监听 8090）；
  //   ③ 宽限兜底（端口通但迟迟无 marker → 也放行，绝不永久卡死）。
  //
  // 注：dart:io HttpClient 走 NDK 原生 socket，**不经 Android 的 Java 层
  // 明文拦截**（NetworkSecurityPolicy/OkHttp/WebView 才受限），故 127.0.0.1
  // 回环探测完全可行——无需改 network_security_config。
  // 本项目 sdk_downloader.dart 用 HttpClient 直连 http 镜像源即是活证据。

  /// 就绪裁决。
  static WebReadyDecision readyDecision({
    required bool markerHit,
    required bool portOpen,
    required int elapsedSec,
    int degradeAfterSec = degradeAfterSec_,
  }) {
    if (markerHit) return WebReadyDecision.ready;
    // 端口通 = 开发服务器确实在跑；marker 抓不到多半是措辞差异/分片丢失。
    // 宽限到期即放行（宁可让用户看到页面，也不要他对着「编译中」干等）。
    if (portOpen && elapsedSec >= degradeAfterSec) {
      return WebReadyDecision.degrade;
    }
    return WebReadyDecision.waiting;
  }

  /// 宽限阈值（秒）：端口通了但 7 分钟还没等到 marker 就放行。
  static const int degradeAfterSec_ = 420;

  /// 端口探测节流间隔（秒）——500ms 轮询里不要每次都打网络。
  static const int probeIntervalSec = 3;

  /// 心跳间隔（秒）：DDC 编译静默期定期追加一行，让日志"活着"。
  static const int heartbeatIntervalSec = 15;

  /// 阶段文案：如实告诉用户「现在在干什么」，而不是笼统的「编译中」。
  /// 三段都必须是真话——这是本 Bug 的核心教训（UI 不能撒谎）。
  static String stageLabel({
    required bool portOpen,
    required int elapsedSec,
  }) {
    if (portOpen) {
      return '开发服务器已就绪，正在编译应用'
          '（DDC 首次编译 1-5 分钟，此阶段无日志输出属正常）';
    }
    return '准备中：解析依赖 / 断言 x64 转发层…';
  }

  /// 静默期心跳行（纯函数，便于单测）。
  static String heartbeatLine(int elapsedSec) => '· 已等待 ${fmtDur(elapsedSec)}'
      '（${elapsedSec >= 60 ? 'DDC 编译中' : '启动中'}，无输出属正常）';

  /// 端口探测：返回 true = 开发服务器已在 8090 监听。
  /// 200/404/503 都算「在听」——我们只关心 TCP 是否可达 + 有无 HTTP 响应。
  Future<bool> probePort() async {
    final c = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 1500);
    try {
      final req = await c
          .getUrl(Uri.parse('$url/'))
          .timeout(const Duration(milliseconds: 1500));
      final res = await req.close().timeout(const Duration(milliseconds: 1500));
      await res.drain<void>();
      return true;
    } catch (_) {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  /// 拼接启动命令（execStream 常驻执行；结构对齐 BuildRunner.buildCommand）。
  ///
  /// 转义边界（同 Bug 424 教训，单测固化在 web_preview_test.dart）：
  /// - `\$src` / `\$ok` / `\$n` **必须**转义——shell 层变量；
  /// - `$pidFilePath` / `$proj` / `$port` **必须** Dart 插值——Dart 层产生；
  /// - `$$` 是 shell 的当前 pid（写 pid 文件用），写成 Dart 插值会变成
  ///   空串 → pid 文件恒空 → 热重载永远 GONE。
  ///
  /// 流程：残留清理 → 版本检查 stamp（Bug 436）→ web 平台自检（缺则
  /// flutter create 补建）→ pub 多源轮换（Bug 423 同款）→ 转发层再断言
  /// （Bug 433：pub get 可能触发引擎构件下载覆盖转发脚本）→ 记 pid →
  /// exec flutter run 常驻。
  static String startCommand({
    required String proj,
    required String envPart,
    required String pidFilePath,
    required int webPort,
  }) {
    // Bug 436：跳过 flutter 内部的 git fetch --tags 版本检查
    //（web 预览同样会触发 3 天一次的版本新鲜度检查，真机 504 白等 2 分钟）
    final stamp = BuildRunner.refreshVersionCheckStamp
        .replaceAll('@CACHE@', '${QemuCompat.flutterHome}/bin/cache');
    // Bug 433：pub get 之后、run 之前重建转发层（同构建命令的双保险位）
    final reassert = QemuCompat.fill(QemuCompat.wrapReassertScript);
    return '${staleCleanupCommand(pidFilePath)}'
        "cd $proj && $envPart"
        'FLUTTER_ALLOW_ROOT=true '
        'FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn '
        'sh -c ${_shq(stamp)} 2>&1 | tail -n 1; '
        // web 平台自检：老项目缺 web/ 时补建（幂等；--no-pub 避免双重 get）
        'if [ ! -f web/index.html ]; then '
        'echo "---- 首次运行：补建 web 平台（flutter create --platforms=web）----"; '
        'if ! flutter create --platforms=web --no-pub . 2>/tmp/foa_create_web.err; '
        'then tail -n 5 /tmp/foa_create_web.err; exit 71; fi; fi; '
        // pub 依赖：多源轮换（与构建同款），失败交由 run 内部兜底
        'ok=0; '
        'for src in https://pub.flutter-io.cn '
        'https://mirrors.tuna.tsinghua.edu.cn/dart-pub '
        'https://mirrors.ustc.edu.cn/dart-pub; do '
        'for i in 1 2; do '
        'if PUB_HOSTED_URL=\$src flutter pub get; '
        'then ok=1; break 2; fi; sleep 2; done; done; '
        '[ "\$ok" = 1 ] || exit 69; '
        'export PUB_HOSTED_URL=\$src; '
        // 转发层再断言（web 编译的 dart/kernel 工具全靠 qemu 链路）
        'sh -c ${_shq(reassert)} 2>&1 | tail -n 4; '
        // 记录 pid 后 exec：exec 是进程内替换，pid 文件即 flutter run 进程
        //（\$\$ 是 shell 的当前 pid——此处若写成 Dart 插值会变空串）
        'echo \$\$ > $pidFilePath; '
        // --no-pub（alpha.60）：上面已显式跑过三源轮换的 pub get，flutter run
        // 内部还会再跑一次隐式 pub get（且用默认 Google 源，国内又慢又易失败）
        // ——直接省掉这一轮，是本次唯一的确定提速项。
        'exec flutter run -d web-server '
        '--web-hostname=127.0.0.1 --web-port=$webPort --no-pub';
  }

  /// 单引号包裹一段 shell 片段（内部单引号用 '\'' 转义）。
  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  // ============================ 启动 ============================

  /// 启动预览会话。返回 null = 已进入 starting；否则返回错误文案。
  ///
  /// 前置失败（缺组件等）不入会话，直接返回文案（UI 以 SnackBar 呈现）；
  /// 运行期失败（进程退出）入会话（status=error + 日志）。
  Future<String?> start(String name, EnvInfo env) async {
    final mutex = mutexError(
      building: BuildRunner.I.building,
      previewBusy: busy,
      bare: false, // 第一版仅 proot 后端（页面入口已拦截 termux）
    );
    if (mutex != null) return mutex;

    final proj = '/root/projects/${_q(name)}';

    // 前置快速失败：不是 Flutter 项目就别浪费一次常驻任务
    final check = await bridge.exec(
      'test -f $proj/pubspec.yaml && echo __OK__ || echo __NO__',
      timeoutSec: 30,
    );
    if (!check.stdout.contains('__OK__')) {
      return '不是 Flutter 项目：/root/projects/$name/pubspec.yaml 不存在';
    }

    // 容器 CA 证书（Bug 425：minbase rootfs 缺 CA → pub https 必失败）
    final caErr = await ToolchainEnsure().caCerts(env: env);
    if (caErr != null) return '证书自愈失败：$caErr';

    // flutter 硬依赖 git（幂等，已装秒过）
    final gitErr = await ToolchainEnsure().git();
    if (gitErr != null) return gitErr;

    // qemu 兼容层（dart 必须经 qemu 跑；幂等快，真机已验证）
    final qErr = await ToolchainEnsure().qemuCompatEnsure(env: env);
    if (qErr != null) {
      return '$qErr（到「工具链」页 → x64 兼容层 → 重新应用后重试）';
    }

    // 启动锁清理（Bug 420：残留 dart 进程持有锁会让 run 卡死在等待）
    await ToolchainEnsure().flutterUnlock(bridge, QemuCompat.flutterHome);

    // 会话初始化
    projName = name;
    lines.clear();
    partial = '';
    error = null;
    elapsedSec = 0;
    portOpen = false;
    _lastProbeAt = null;
    _released = false;
    firstReadySec = null;
    _lastHeartbeatSec = -1;
    _startedAt = DateTime.now();
    status = WebPreviewStatus.starting;
    lines.add('▶ flutter run -d web-server --web-hostname=127.0.0.1 '
        '--web-port=$port --no-pub');
    lines.add('  项目：/root/projects/$name');
    lines.add('  预览地址：$url（编译完成后自动进入内嵌预览）');
    lines.add('');
    _ui();

    final cmd = startCommand(
      proj: proj,
      envPart: 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt ',
      pidFilePath: pidFile,
      webPort: port,
    );
    final stream = await bridge.execStream(cmd);
    if (!stream.ok || stream.id <= 0) {
      status = WebPreviewStatus.idle;
      projName = null;
      _ui();
      return '启动失败：${stream.error ?? '未知错误'}';
    }
    _streamId = stream.id;
    _offset = 0;

    // 前台服务保活（切浏览器/锁屏预览不中断，通知栏可见状态）
    // alpha.59：标记通知归属——点击跳 Web 预览控制台（修复跳到构建页）
    BuildNotify.lastRoute = 'preview';
    BuildNotify.start('Web 预览 · $name');
    BuildNotify.progress('编译中（首次约 1-5 分钟）…', 0);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
    return null;
  }

  // ============================ 轮询循环 ============================

  /// 500ms 守护轮询（结构与 BuildRunner._poll 一致）。
  Future<void> _poll() async {
    final poll = await bridge.execStreamPoll(_streamId, _offset);
    if (!poll.ok) {
      _timer?.cancel();
      if (_stopping) return; // stop() 已主动收尾，任务消失属预期
      status = WebPreviewStatus.error;
      error = '日志轮询失败：${poll.error ?? '未知错误'}（会话已失联，请重启预览）';
      lines.add('✗ $error');
      _ui();
      BuildNotify.finish('✗ Web 预览失联');
      return;
    }
    _appendChunk(poll.chunk);
    _offset = poll.len;
    final started = _startedAt;
    if (started != null) {
      elapsedSec = DateTime.now().difference(started).inSeconds;
    }

    // Bug 454：starting 期间做端口探测（节流）+ 心跳，双信号补齐 ready 判定。
    if (status == WebPreviewStatus.starting) {
      await _tickStarting();
    }

    if (!poll.running) {
      _timer?.cancel();
      await _finish(poll.exitCode);
    } else {
      _ui();
      _scroll();
    }
  }

  /// starting 状态每个轮询周期的附加动作：端口探测（节流 3s）、
  /// 宽限兜底放行、静默期心跳。
  Future<void> _tickStarting() async {
    if (_released) return;

    // ① 端口探测（节流：probeIntervalSec 秒一次，不要每 500ms 打网络）
    final now = DateTime.now();
    final last = _lastProbeAt;
    if (last == null ||
        now.difference(last).inSeconds >= probeIntervalSec ||
        !portOpen) {
      _lastProbeAt = now;
      final wasOpen = portOpen;
      portOpen = await probePort();
      if (portOpen && !wasOpen) {
        // 服务器起来了：立刻把真相写给用户（不再笼统说「编译中」）
        _heartbeat('✓ 开发服务器已就绪（$url 已在监听）');
      }
    }
    if (_released) return; // 探测期间可能已被 marker 放行

    // ② 宽限兜底：端口通但迟迟无 marker → 降级放行，绝不永久卡死
    final d = readyDecision(
      markerHit: false,
      portOpen: portOpen,
      elapsedSec: elapsedSec,
    );
    if (d == WebReadyDecision.degrade) {
      _release(
        degrade: true,
        note: '未在日志中捕获就绪信号，但端口 $port 已通，已放行加载；'
            '若页面空白请用「系统浏览器」打开 $url',
      );
      return;
    }

    // ③ 静默期心跳：每 heartbeatIntervalSec 秒补一行，让用户知道没死
    if (elapsedSec > 0 &&
        elapsedSec % heartbeatIntervalSec == 0 &&
        elapsedSec != _lastHeartbeatSec) {
      _lastHeartbeatSec = elapsedSec;
      _heartbeat(heartbeatLine(elapsedSec));
    }
  }

  /// 追加心跳/提示行（不改变状态）。
  void _heartbeat(String line) {
    lines.add(line);
    _ui();
    _scroll();
  }

  /// 放行：status → running，WebView 得以构造。
  /// [degrade] = 靠端口兜底放行（非 marker 命中），日志要如实说明。
  void _release({required bool degrade, String? note}) {
    if (_released) return;
    _released = true;
    firstReadySec = elapsedSec;
    status = WebPreviewStatus.running;
    lines.add('');
    if (degrade && note != null) {
      lines.add('⚠ $note');
    } else {
      lines.add('✓ 预览已就绪：$url（改代码后点热重载即时生效）');
    }
    // 埋点：首次就绪耗时——后续决定是否投入「预热」优化的唯一依据
    lines.add('  首次就绪耗时 ${fmtDur(elapsedSec)}');
    lines.add('');
    BuildNotify.progress('运行中 · $url', 100);
    _ui();
    _scroll();
  }

  int _lastHeartbeatSec = -1;

  void _appendChunk(String chunk) {
    final clean = chunk.replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '');
    partial += clean;
    final parts = partial.split('\n');
    partial = parts.removeLast();
    for (final p in parts) {
      final segs = p.split('\r');
      final line = segs.last; // 进度条 \r 原地刷新：只留末段
      lines.add(line);
      // ready 判定：starting 状态下命中信号词 → 放行（marker 是最快路径）
      if (status == WebPreviewStatus.starting && isReadyLine(line)) {
        _release(degrade: false);
      }
    }
    // Bug 454：partial 也参与判定——marker 若落在「还没等到换行」的最后一段里，
    // 会被完整行循环永久漏判。前缀误判的代价（提前放行，WebView 自动重试）
    // 远小于漏判的代价（用户无限期看着「编译中」）。
    if (status == WebPreviewStatus.starting && isReadyLine(partial)) {
      _release(degrade: false);
    }
    if (lines.length > _maxLines) {
      lines.removeRange(0, lines.length - _maxLines);
      lines[0] = '[日志截断，仅显示最近 $_maxLines 行]';
    }
  }

  Future<void> _finish(int? exitCode) async {
    if (_stopping) {
      // stop() 已收尾（status=idle），这里只补一行运行时长
      return;
    }
    status = WebPreviewStatus.error;
    error = exitCode == null
        ? '预览进程已退出（可能达到 2 小时上限被平台回收），请重新启动'
        : '预览进程退出（exit $exitCode）';
    lines.add('');
    lines.add('✗ $error');
    lines.add('  已运行 ${fmtDur(elapsedSec)} · 可查看上方日志定位原因');
    _ui();
    _scroll();
    BuildNotify.finish('✗ Web 预览已退出 · 点开查看日志');
  }

  // ============================ 操作 ============================

  /// 热重载（SIGUSR1）：保存过的代码重新生效，浏览器页面无感刷新。
  /// 返回 null = 已触发；否则返回错误文案。
  Future<String?> hotReload() => _signal('-USR1', '热重载');

  /// 热重启（SIGUSR2）：改了 main()/全局状态等热重载覆盖不到的地方用。
  Future<String?> hotRestart() => _signal('-USR2', '热重启');

  Future<String?> _signal(String signal, String label) async {
    if (status != WebPreviewStatus.running) return '预览未在运行';
    if (_reloadBusy) return null; // 连点防抖：第一次触发已在路上
    _reloadBusy = true;
    try {
      final r = await bridge.exec(
        signalCommand(pidFile, signal),
        timeoutSec: 30,
      );
      if (r.stdout.contains('GONE')) {
        status = WebPreviewStatus.error;
        error = '预览进程已不在（会话可能已超时），请重新启动';
        lines.add('✗ $error');
        _ui();
        BuildNotify.finish('✗ Web 预览已退出');
        return error;
      }
      lines.add('↻ 已触发$label（${DateTime.now().toString().substring(11, 19)}）');
      _ui();
      _scroll();
      return null;
    } finally {
      _reloadBusy = false;
    }
  }

  /// 停止预览：杀流式进程树 + 收尾。
  Future<void> stop() async {
    if (!busy) return;
    _stopping = true;
    _timer?.cancel();
    await bridge.execStreamStop(_streamId);
    _stopping = false;
    status = WebPreviewStatus.idle;
    lines.add('');
    lines.add('⏹ 预览已停止（用户中止）· 已运行 ${fmtDur(elapsedSec)}');
    projName = null;
    _ui();
    _scroll();
    BuildNotify.finish('⏹ Web 预览已停止');
  }
}
