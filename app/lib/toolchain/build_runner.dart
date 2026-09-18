import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import 'build_notify.dart';
import 'build_progress.dart';
import 'qemu_compat.dart';
import 'termux_backend.dart';
import 'toolchain_ensure.dart';

/// 构建会话状态机（构建页据其渲染）。
enum BuildStatus { idle, building, done, error, cancelled }

/// 构建执行器：全局单例，构建会话与构建页生命周期解耦。
///
/// 为什么抽单例（alpha.31）：原实现构建状态全是 BuildPage 的 State 字段，
/// 离开页面即 dispose 杀构建——用户锁屏/切走必断，还可能留下持锁孤儿
/// （Bug 420 的源头之一）。改为全局单例后：
/// - 页面退出只解绑 UI 钩子（onUiChanged/onAutoScroll），轮询由单例的
///   守护 timer 继续，进度同步喂前台服务通知（BuildNotify）；
/// - 重进页面 attach 回来，日志/进度/产物无缝续显；
/// - 原生 BuildService 前台服务保活 App 进程树，退出界面构建不中断。
///
/// 线程模型：所有方法都在主 isolate（与页面同）；poll 循环 500ms 一次，
/// 通道往返是异步的，天然串行（上一轮未返回时 timer 回调排队）。
class BuildRunner {
  BuildRunner._();
  static final BuildRunner I = BuildRunner._();

  final ProotBridge bridge = ProotBridge();
  final FileBrowserBridge _fb = FileBrowserBridge();

  // ---- 会话状态（构建页读这些渲染）----
  String? active; // 正在构建/已构建的项目名
  BuildStatus status = BuildStatus.idle;
  final List<String> lines = [];
  String partial = '';
  String? apkGuest; // 产物容器路径（rootfs 内）
  final BuildProgressTracker prog = BuildProgressTracker();

  /// 已构建耗时（秒），供"仍在运行/总耗时"展示。
  int elapsedSec = 0;

  /// 命中的修复建议（去重，最多展示 3 条——截取在 UI 层）。
  final List<String> hints = [];

  int _streamId = -1;
  int _offset = 0;
  DateTime? _startedAt;
  Timer? _timer;

  // ---- UI 钩子（页面 attach 时注入，dispose 置空；null = 构建在后台跑）----
  void Function()? onUiChanged;
  void Function()? onAutoScroll;

  bool get building => status == BuildStatus.building;

  // 通知节流：阶段与百分比都没变就不推（Kotlin 侧还有 800ms 限频兜底）
  int _lastNotifPct = -1;
  String _lastNotifStage = '';

  static const int _maxLines = 3000;

  void _ui() => onUiChanged?.call();
  void _scroll() => onAutoScroll?.call();

  /// 秒 → `mm:ss` / `h:mm:ss`（UI 层与通知共用）。
  static String fmtDur(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// 「返回列表」：清会话到 idle（日志保留到下次构建 start 时 clear）。
  void resetUi() {
    if (building) return; // 构建中不允许（UI 上该按钮也不出现）
    status = BuildStatus.idle;
    active = null;
    _ui();
  }

  /// shell 单引号转义（项目名可能含空格/特殊字符）。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static const String _projectsDir = '/root/projects';

  // ============================ 启动构建 ============================

  Future<void> start(String name, EnvInfo env, BuildBackend backend) async {
    if (building) return; // 防重入（页面 UI 也不会同时给两个入口）
    final bare = backend == BuildBackend.termux;
    active = name;
    status = BuildStatus.building;
    lines.clear();
    partial = '';
    apkGuest = null;
    prog.reset();
    elapsedSec = 0;
    _startedAt = DateTime.now();
    _lastNotifPct = -1;
    _lastNotifStage = '';
    hints.clear();
    _ui();

    // shell 命令里的项目目录：proot = 容器路径；termux bare = 宿主路径
    //（bare 执行不经 proot，容器路径 /root/projects 对宿主不存在）。
    final projectsDir = bare ? '${env.rootfsPath}/root/projects' : _projectsDir;
    final proj = '$projectsDir/${_q(name)}';

    // termux 后端前置组件检查（缺了就快速失败，别等 flutter 脚本报错）：
    // bionic Flutter（含 bin/flutter）与 bionic git——容器里的 git 是
    // glibc 二进制，bare 直跑不了，不能用 ToolchainEnsure 兜底。
    if (bare) {
      final miss = <String>[];
      final flDir = TermuxPaths.flutterHome(env);
      if (!Directory(flDir).existsSync() ||
          !File('$flDir/bin/flutter').existsSync()) {
        miss.add('Flutter（bionic）');
      }
      if (!File('${TermuxPaths.prefix(env)}/bin/git').existsSync()) {
        miss.add('git（bionic）');
      }
      if (miss.isNotEmpty) {
        status = BuildStatus.error;
        lines.add('✗ termux 后端缺组件：${miss.join('、')}');
        lines.add('  请到「工具链」页 → Termux 卡片安装后再构建');
        _ui();
        return;
      }
    }

    // 前置校验：不是 Flutter 项目就快速失败，省一次 2h 级长任务
    final check = await bridge.exec(
      'test -f $proj/pubspec.yaml && echo __OK__ || echo __NO__',
      timeoutSec: 30,
      bare: bare,
    );
    if (!check.stdout.contains('__OK__')) {
      status = BuildStatus.error;
      lines.add('✗ 不是 Flutter 项目：$proj/pubspec.yaml 不存在');
      _ui();
      return;
    }

    // proot 后端补一项 Flutter 存在性检查（termux 已在上方前置检查里
    // 覆盖）：快速失败给引导，别等 shell 报 `flutter: not found`
    if (!bare) {
      final probe = await bridge.exec(
        'test -x /opt/flutter/bin/flutter && echo __OK__ || echo __NO__',
        timeoutSec: 30,
      );
      if (!probe.stdout.contains('__OK__')) {
        status = BuildStatus.error;
        lines.add('✗ 容器内未找到 Flutter SDK（/opt/flutter/bin/flutter）');
        lines.add('  请到「工具链」页安装 Flutter 后再打包');
        _ui();
        return;
      }

      // Bug 425 根因修复：容器 CA 证书预检+自愈——minbase rootfs 无
      // ca-certificates 时 pub 对任何 https 源 100% 握手失败（真机
      // 三连卡 4% 的元凶），apt/内置 bundle 双路自愈
      final caErr = await ToolchainEnsure().caCerts(env: env);
      if (caErr != null) {
        status = BuildStatus.error;
        lines.add('✗ $caErr');
        lines.add('  修复后重新打包即可');
        _ui();
        return;
      }

      // Bug 426 根因修复：容器 init.gradle 旧版仓库注入与 Flutter 新模板
      // PREFER_SETTINGS 冲突 → 22% 配置 Gradle 报 "repository 'maven'
      // was added"。检测到旧版则覆写为 beforeSettings 前插形态。
      final gErr = await ToolchainEnsure().gradleInitSanitize(env: env);
      if (gErr != null) lines.add('⚠ $gErr（不阻断构建）');

      // Bug 427 根因修复：Flutter gradle 插件会主动调 sdkmanager 补装
      // NDK（项目 ndkVersion 不在已装列表时），而 sdkmanager 在 Android
      // arm64 上启 JVM 触发 JIT SIGILL（exit 132，真机 24% 配置 Gradle
      // 崩）。构建前写入最小 NDK 占位使插件判定"已装"直接跳过。
      final nErr = await ToolchainEnsure().ndkStub();
      if (nErr != null) lines.add('⚠ $nErr（不阻断构建）');

      // Bug 428 根因修复：flutter precache 会往 linux-arm64/ 写真 x64
      // gen_snapshot/impellerc，覆盖兼容层先前放的 qemu 转发脚本
      // （上游 artifacts.dart 未对 linux_arm64 做 x64 回退）。
      // 「先应用兼容层、后装 Flutter」必踩。构建前幂等重建转发层。
      final qErr = await ToolchainEnsure().qemuCompatEnsure(env: env);
      if (qErr != null) {
        lines.add('✗ $qErr');
        lines.add('  到「工具链」页 → x64 兼容层 → 重新应用后重试');
        status = BuildStatus.error;
        _ui();
        return;
      }
    }

    lines.add('▶ flutter build apk --no-shrink --release'
        ' --target-platform=android-arm64');
    lines.add('  目录：$projectsDir/$name');
    lines.add('  后端：${bare ? 'Termux 裸原生（不经 proot）' : 'Proot 容器'}');
    lines.add('');
    _ui();

    // 前置清理（Bug 420）：上次构建被强杀的孤儿 dart 进程仍持有 flutter
    // 启动锁时，新构建会永远卡在 "Waiting for another flutter command..."。
    // proot 清容器 SDK 锁；termux 清 prefix 锁（dart 路径两后端都匹配）。
    final flutterDir = bare ? TermuxPaths.flutterHome(env) : '/opt/flutter';
    final killed = await ToolchainEnsure().flutterUnlock(
      bridge,
      flutterDir,
      bare: bare,
    );
    lines.add(killed > 0
        ? '🧹 已清理残留 flutter 进程 $killed 个（启动锁已释放）'
        : '🧹 无残留 flutter 进程，锁干净');
    lines.add('');
    _ui();

    // flutter 工具硬依赖 git，缺失时先自动安装（幂等；已装秒过）。
    // termux 后端跳过：前置检查已确保 bionic git 就位。
    if (!bare) {
      final gitErr = await ToolchainEnsure().git();
      if (gitErr != null) {
        status = BuildStatus.error;
        lines.add('✗ $gitErr');
        _ui();
        return;
      }
    }

    // gradle 发行包统一走腾讯镜像（Step 8）：老工程仍是官方源 URL，哈希
    // 与 Step 3 预下载缓存不匹配会直连 services.gradle.org；幂等改写，
    // 失败仅警告不阻断（构建仍可尝试直连）。
    // termux 后端不经容器 shell，用 Dart 文件 IO 直接改写（rootfs 树内
    // 文件宿主可见可写，与容器改写同一份文件）。
    if (bare) {
      final warn = _gradleMirrorFromDart(env, name);
      if (warn != null) lines.add('⚠ $warn');
    } else {
      final mirrorErr = await ToolchainEnsure().projectGradleMirror(name);
      if (mirrorErr != null) lines.add('⚠ $mirrorErr');
    }

    // aapt2 覆盖（仅 termux）：AGP 默认从 Maven 拉 x86_64 aapt2；termux
    // aapt 组件装好后把 build 期的 aapt2 指回 prefix 里的 bionic arm64 版
    //（-P 优先级高于 gradle.properties，不污染工程文件）。
    String aapt2Override = '';
    if (bare) {
      final aapt2 = TermuxPaths.aapt2(env);
      if (File(aapt2).existsSync()) {
        aapt2Override = " -Pandroid.aapt2FromMavenOverride='$aapt2'";
      }
    }

    // pub get 多源轮换重试（Bug 423）：真机弱网（~50KB/s）下到
    // pub.flutter-io.cn 的 TLS 握手会**持续**失败——同源重试 3 次
    // （alpha.30）救不了，改为 pub 镜像逐源轮换（io.cn → 清华 → 中科大），
    // 每源 2 次，成功源 export 后供 build 内部自动 pub get 复用。
    // storage 镜像不变：engine artifacts 只有 flutter-io.cn 有代理。
    final flutterCmd =
        bare ? "'${TermuxPaths.flutterHome(env)}/bin/flutter'" : 'flutter';
    // proot：SSL_CERT_FILE 显式指向容器 CA bundle（Bug 425 双保险——
    // dart 优先读此环境变量，即使默认路径探测有偏差也能找到根证书）
    final envPart = bare
        ? TermuxPaths.envPrefix(env)
        : 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt ';
    final cmd = buildCommand(
      proj: proj,
      flutterCmd: flutterCmd,
      envPart: envPart,
      aapt2Override: aapt2Override,
    );
    final stream = await bridge.execStream(cmd, bare: bare);
    if (!stream.ok || stream.id <= 0) {
      status = BuildStatus.error;
      lines.add('✗ 启动失败：${stream.error ?? '未知错误'}');
      _ui();
      return;
    }
    _streamId = stream.id;
    _offset = 0;

    // 前台服务 + 常驻通知（alpha.31）：此后用户可自由退出页面/锁屏
    BuildNotify.start('构建中 · $name');
    BuildNotify.progress('正在启动构建…', 0);

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  /// 拼接构建命令：pub 多源轮换（Bug 423）+ flutter build（迭代包
  /// --no-shrink 跳过 R8，双轨策略——最终版发布包才用 R8）。
  ///
  /// 转义边界（Bug 424 教训，单测固化在 build_runner_test.dart）：
  /// - `\$src` / `\$ok` **必须**转义——shell for 循环变量，值在 shell 层
  ///   产生，Dart 插值会变成字面字符串；
  /// - `$flutterCmd` **必须** Dart 插值——值在 Dart 层产生，误转义后
  ///   shell 里没有这个变量 → 展开为空 → `pub: not found` ×6 → exit 69
  ///   （alpha.33 真机实翻车）。同一行混用两层变量时，逐个问
  ///   「这个值在哪一层产生」。
  static String buildCommand({
    required String proj,
    required String flutterCmd,
    required String envPart,
    required String aapt2Override,
  }) {
    // Bug 433：pub get 会触发 Flutter 重新下载引擎构件，把 linux-arm64/
    // 下的转发脚本盖回真 x64 二进制（真机表现：AOT 跑到 54% 后
    // shaders/*.frag 编译 SIGILL，exit -4）。因此在 pub get 之后、
    // flutter build 之前，于**同一条 shell 命令内**再断言一次转发层。
    //
    // 注意：不能用 `{ script ; }` 分组——脚本末尾带换行，`\n ; }` 在
    // dash/bash 下都是语法错误。改用 `sh -c '...'` 独立执行，既避开
    // 分组问题，也把它的输出隔离（只留最后 2 行，避免刷屏）。
    final reassert = QemuCompat.wrapReassertScript
        .replaceAll('@ENGINE@', QemuCompat.engineDir)
        .replaceAll('@QEMU@', QemuCompat.qemuBin);
    return "cd $proj && $envPart"
        'FLUTTER_ALLOW_ROOT=true '
        'ok=0; '
        'for src in https://pub.flutter-io.cn '
        'https://mirrors.tuna.tsinghua.edu.cn/dart-pub '
        'https://mirrors.ustc.edu.cn/dart-pub; do '
        'for i in 1 2; do '
        'if PUB_HOSTED_URL=\$src $flutterCmd pub get; '
        'then ok=1; break 2; fi; sleep 3; done; done; '
        '[ "\$ok" = 1 ] || exit 69; '
        'export PUB_HOSTED_URL=\$src; '
        // Bug 433 转发层再断言（pub get 后、build 前，同一 shell）
        'sh -c ${_shq(reassert)} 2>&1 | tail -n 2; '
        '$flutterCmd build apk --no-shrink --release '
        '--target-platform=android-arm64$aapt2Override';
  }

  /// 单引号包裹一段 shell 片段（内部单引号用 '\'' 转义）。
  /// 用于把多行脚本安全地塞进 `sh -c '...'`。
  static String _shq(String s) =>
      "'${s.replaceAll("'", "'\\''")}'";

  /// 清理构建缓存（flutter clean，工作台打包配置卡的快捷操作）：
  /// 返回 null = 成功，否则返回错误文案。构建中拒绝（防清掉正在
  /// 使用的 build 目录）。
  Future<String?> clean(String name, EnvInfo env, BuildBackend backend) async {
    if (building) return '正在构建中，不能清理缓存';
    final bare = backend == BuildBackend.termux;
    final projectsDir = bare ? '${env.rootfsPath}/root/projects' : _projectsDir;
    final flutterDir = bare ? TermuxPaths.flutterHome(env) : '/opt/flutter';
    final flutterCmd =
        bare ? "'$flutterDir/bin/flutter'" : 'flutter';
    final envPart = bare ? TermuxPaths.envPrefix(env) : '';
    final r = await bridge.exec(
      'cd $projectsDir/${_q(name)} && $envPart'
      'FLUTTER_ALLOW_ROOT=true $flutterCmd clean',
      timeoutSec: 300,
      bare: bare,
    );
    if (r.exitCode != 0) {
      final out = (r.stdout.isNotEmpty ? r.stdout : r.stderr).trim();
      return 'flutter clean 失败（exit ${r.exitCode}）'
          '${out.isEmpty ? '' : '：${out.split('\n').last}'}';
    }
    return null;
  }

  /// termux 后端的 gradle wrapper 镜像改写：不经 shell，Dart 直接读写
  ///（rootfs 树内文件宿主可见）。幂等；非 Flutter 工程静默跳过。
  String? _gradleMirrorFromDart(EnvInfo env, String name) {
    try {
      final f = File('${env.rootfsPath}/root/projects/$name'
          '/android/gradle/wrapper/gradle-wrapper.properties');
      if (!f.existsSync()) return null;
      final t = f.readAsStringSync();
      if (t.contains('mirrors.cloud.tencent.com')) return null;
      f.writeAsStringSync(t.replaceAll(
          'services.gradle.org/distributions',
          'mirrors.cloud.tencent.com/gradle'));
      return null;
    } catch (e) {
      return 'gradle 镜像配置失败：$e';
    }
  }

  // ============================ 轮询循环 ============================

  /// 500ms 守护轮询：页面在时同步刷 UI，页面不在时只喂通知。
  Future<void> _poll() async {
    final poll = await bridge.execStreamPoll(_streamId, _offset);
    if (!poll.ok) {
      _timer?.cancel();
      status = BuildStatus.error;
      prog.markHalted();
      lines.add('✗ 轮询失败：${poll.error ?? '未知错误'}');
      lines.add('  进度已冻结在 ${prog.percent}%（任务已失联，请重试）');
      _ui();
      BuildNotify.finish('✗ 构建失联（exit 未知）· 点开查看日志');
      return;
    }
    _appendChunk(poll.chunk);
    _offset = poll.len;
    // 进度插值：日志推进阶段，时间推进阶段内百分比
    prog.tick();
    final started = _startedAt;
    if (started != null) {
      elapsedSec = DateTime.now().difference(started).inSeconds;
    }
    if (!poll.running) {
      _timer?.cancel();
      await _finish(poll.exitCode);
    } else {
      _ui();
      _notifyProgress();
      _scroll();
    }
  }

  void _appendChunk(String chunk) {
    final clean = chunk.replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '');
    partial += clean;
    final parts = partial.split('\n');
    partial = parts.removeLast();
    for (final p in parts) {
      // 进度条用 \r 原地刷新：只保留最后一段
      final segs = p.split('\r');
      final line = segs.last;
      lines.add(line);
      // 进度识别吃"清洗后"的行：ANSI 已去、\r 段已取末段
      prog.feed(line);
      _feedErrorBreakdown(line);
    }
    if (lines.length > _maxLines) {
      lines.removeRange(0, lines.length - _maxLines);
      lines[0] = '[日志截断，仅显示最近 $_maxLines 行]';
    }
  }

  /// 通知进度（节流：阶段与百分比都没变就跳过）。
  void _notifyProgress() {
    final pct = prog.percent;
    final stage = prog.stage.label;
    if (pct == _lastNotifPct && stage == _lastNotifStage) return;
    _lastNotifPct = pct;
    _lastNotifStage = stage;
    BuildNotify.progress('$stage · $pct% · 已用 ${fmtDur(elapsedSec)}', pct);
  }

  /// 从日志里提取"失败类型"，供进度条下方给出可执行的修复建议。
  /// 只识别本仓库已知的失败模式（见 dev-handbook §十 工具链 / §十一 体积）。
  ///
  /// [exposeFeedForTest] 为仅测试可见的转发入口：分诊表是纯文本匹配逻辑，
  /// 沙箱出包不走 BuildRunner、analyze 覆盖不到运行时识别，只能靠单测
  /// 固化（同 Bug 424 的 buildCommand 文本断言思路）。
  @visibleForTesting
  void debugFeedForTest(String line) => _feedErrorBreakdown(line);

  void _feedErrorBreakdown(String line) {
    final l = line.toLowerCase();
    String? tip;
    if (l.contains('exec format error')) {
      tip = '架构不匹配：x64 工具未经 qemu 转发（工具链页 → x64 兼容层 → 重新应用）';
    } else if (l.contains(': not found')) {
      tip = '命令缺失（sh: xxx: not found）：容器组件不全——到「工具链」页'
          '核对 Flutter / JDK / SDK 组件后重试（alpha.33 的 pub: not found '
          '属构建器自身 bug，alpha.34 已修）';
    } else if (l.contains('shared libraries')) {
      tip = '多架构运行库缺失：x64 兼容层 → 重新应用';
    } else if (l.contains('no space left')) {
      tip = '磁盘空间不足：清理 build/ 与 .gradle 缓存后重试';
    } else if (l.contains('snapshot generator failed') ||
        l.contains('aot snapshotter exited') ||
        l.contains('impellerc failure') ||
        l.contains('shadercompilerexception') ||
        l.contains('failed with exit code -4')) {
      tip = 'AOT/shader 编译崩溃（exit -4 = SIGILL）：Flutter 只发 x86_64 '
          '宿主版 gen_snapshot/impellerc，arm64 真机需 qemu 转发；'
          'flutter precache 会覆写转发脚本（Bug 428）。alpha.39 起构建前'
          '自动重建转发层。若本条仍出现：到「工具链」页重新应用 x64 兼容层';
    } else if (l.contains('exit value 132') ||
        l.contains('sigill') ||
        l.contains('sdkmanager')) {
      tip = 'sdkmanager 崩溃（exit 132 = SIGILL）：Flutter 插件自动补装 '
          'NDK 时在 Android arm64 上启 JVM 触发非法指令。alpha.38 起构建前'
          '自动写 NDK 占位使插件跳过补装（Bug 427）。若本条仍出现：到'
          '「工具链」页卸载并重装 Android SDK 组件后重试';
    } else if (l.contains('prefer settings repositories') ||
        l.contains('was added by settings file')) {
      tip = 'Gradle 仓库注入与 Flutter 新模板 PREFER_SETTINGS 冲突：'
          'alpha.37 起构建前会自动把旧版 init.gradle 覆写为无注入形态'
          '（Bug 426）。若本条仍出现：到「工具链」页 → Gradle 镜像 → '
          '重新「一键应用」后重试';
    } else if (l.contains('could not resolve') || l.contains('sslhandshake')) {
      tip = '依赖下载失败：检查镜像源（工具链页 → Gradle 镜像）';
    } else if (l.contains('tls error') || l.contains('failed to update packages')) {
      tip = 'pub 拉取 TLS 失败：alpha.36 起构建前会自动确保容器根证书'
          '（此前 minbase rootfs 缺 CA 导致所有 https 源必失败——Bug 425）。'
          '若本条仍出现：已自动按 pub 镜像轮换重试（官方 io.cn → 清华 → '
          '中科大），仍全败多为网络到镜像站丢包——切换网络（WiFi/流量互换）'
          '后重试效果最好';
    } else if (l.contains('waiting for another flutter command')) {
      tip = 'Flutter 启动锁被占用：残留进程未清干净——完全杀掉 App 重开再试'
          '（alpha.30 起构建前会自动清理）';
    } else if (l.contains('snapshot not compatible')) {
      tip = 'flutter_tools.snapshot 架构不匹配：x64 兼容层未接管 dart-sdk';
    }
    if (tip != null && !hints.contains(tip)) hints.add(tip);
  }

  Future<void> _finish(int? code) async {
    if (code == 0 && active != null) await _locateApk(active!);
    final ok = code == 0 && apkGuest != null;
    if (ok) {
      // 只有"成功且产物就位"才授予 100%，不动用插值
      prog.markDone();
    } else {
      prog.markHalted();
    }
    status = ok ? BuildStatus.done : BuildStatus.error;
    if (code == 0 && apkGuest == null) {
      lines.add('✗ 构建成功但未找到 APK 产物');
    } else if (code != 0) {
      lines.add('✗ 构建失败（exit ${code ?? -1}）· 已运行 ${fmtDur(elapsedSec)}'
          ' · 进度冻结在 ${prog.percent}%');
    } else {
      lines.add('');
      lines.add('✓ 构建成功：$apkGuest');
      lines.add('  总耗时 ${fmtDur(elapsedSec)}');
    }
    _ui();
    _scroll();
    // 结果通知（服务停、通知留给用户，点击回构建页）
    BuildNotify.finish(ok
        ? '✓ 构建成功 · 总耗时 ${fmtDur(elapsedSec)}'
        : '✗ 构建失败（exit ${code ?? -1}）· 点开查看日志');
  }

  /// 在容器内查找 flutter-apk 产物（优先 app-release.apk）。
  Future<void> _locateApk(String name) async {
    final dir = '$_projectsDir/$name/build/app/outputs/flutter-apk';
    final list = await _fb.browse(dir);
    if (!list.ok) return;
    final apks = list.entries
        .where((e) => !e.isDir && e.name.endsWith('.apk'))
        .toList();
    if (apks.isEmpty) return;
    FsBrowserEntry? pick;
    for (final a in apks) {
      if (a.name == 'app-release.apk') {
        pick = a;
        break;
      }
    }
    pick ??= apks.first;
    apkGuest = '$dir/${pick.name}';
  }

  /// 用户取消：杀流式进程 + 终态落日志 + 结果通知。
  Future<void> cancel() async {
    _timer?.cancel();
    await bridge.execStreamStop(_streamId);
    status = BuildStatus.cancelled;
    prog.markHalted();
    lines.add('');
    lines.add('⏹ 已取消（用户中止）· 已运行 ${fmtDur(elapsedSec)}');
    _ui();
    _scroll();
    BuildNotify.finish('⏹ 已取消 · 已运行 ${fmtDur(elapsedSec)}');
  }
}
