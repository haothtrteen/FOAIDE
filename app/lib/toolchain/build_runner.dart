import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../editor/fs_bridge.dart';
import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import '../project/manifest_codec.dart';
import '../project/signing.dart';
import 'build_notify.dart';
import 'build_progress.dart';
import 'first_build_notice.dart';
import 'qemu_compat.dart';
import 'termux_backend.dart';
import 'toolchain_ensure.dart';

/// 构建会话状态机（构建页据其渲染）。
enum BuildStatus { idle, building, done, error, cancelled }

/// 构建类型（alpha.93）：决定产物走不走 AOT。
///
/// 这是设备端**唯一能显著提速**的档位，原因在 QEMU 转译：
/// | | release | debug |
/// |---|---|---|
/// | Dart 编译 | AOT（gen_snapshot） | kernel（JIT） |
/// | gen_snapshot | 必需，**官方只发 x86_64** → QEMU 转译，慢 10~50 倍 | **不参与** |
/// | 产物 | 可上架 | 仅自测（体积大、性能低） |
///
/// 真机卡在「AOT 编译（gen_snapshot）」阶段（进度 40~58%）时切 debug
/// 能直接砍掉这一段——它是构建耗时的大头。
///
/// ⚠️ 诚实边界（别当银弹卖）：
/// - **首次 debug 构建要额外下载一套 engine 构件**（`arm64_v8a_debug` +
///   `flutter_embedding_debug`，从 Maven 拉，与 release 那套不是同一批）。
///   沙箱实测确认本地只缓存了 release 构件，debug 的必须联网取。
/// - debug 产物不能上架。
/// - 沙箱实测 **Gradle 配置缓存与 Flutter 插件不兼容**（`:app:ReleaseMinSdkCheck`
///   捕获了不可序列化的 Project/ConfigurationContainer）、**build cache 对
///   本场景零收益**（改 Dart 后输入全变，命中不了；未变的 task 已被增量
///   机制 UP-TO-DATE 跳过）。所以提速只剩这一条路。
enum BuildFlavor {
  /// 发布包：走 AOT，慢，产物可上架。
  release,

  /// 调试包：不走 AOT，快，产物仅供自测。
  debug;

  /// flutter build 的命令行参数。
  String get arg => name; // '--release' / '--debug'

  /// 产物文件名（build/app/outputs/flutter-apk/ 下）。
  String get apkName => 'app-$name.apk';

  /// 是否需要 gen_snapshot（决定要不要 precache AOT 工具链）。
  bool get needsAot => this == BuildFlavor.release;
}

/// 构建类型偏好（写盘持久化，与 BackendPrefs 同风格）。
class FlavorPrefs {
  static const String fileName = 'foa-build-flavor.json';

  static File _file(EnvInfo env) => File('${env.filesDir}/$fileName');

  /// 缺省档位 = **debug**（alpha.94 起）。
  ///
  /// 改这个默认值的依据是设备端的实际耗时结构：release 的 AOT 要跑
  /// `gen_snapshot`，而它是 x86_64 二进制、在手机容器里靠 QEMU 转译执行
  /// （慢 10~50 倍），是整条链路上唯一真正耗时的一档；日常"改代码看效果"
  /// 完全不需要 AOT。代价（debug 包更大、带 JIT、**不能上架/不能覆盖安装
  /// 正式版**）已如实写在打包区的档位切换器旁。
  static const BuildFlavor fallback = BuildFlavor.debug;

  /// 读取偏好；文件不存在 / 内容不合法 → [fallback]。
  static Future<BuildFlavor> load(EnvInfo env) async {
    try {
      final f = _file(env);
      if (!await f.exists()) return fallback;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return fallback;
      return switch (raw['flavor']) {
        'debug' => BuildFlavor.debug,
        'release' => BuildFlavor.release,
        _ => fallback,
      };
    } catch (_) {
      return fallback;
    }
  }

  static Future<void> save(EnvInfo env, BuildFlavor v) async {
    final f = _file(env);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'flavor': v.name}));
  }
}

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

  /// 本次会话的构建类型（alpha.93）。决定命令参数与产物文件名。
  /// start() 时写入，_locateApk 据此挑 `app-debug.apk` / `app-release.apk`。
  BuildFlavor flavor = BuildFlavor.release;

  /// 已构建耗时（秒），供"仍在运行/总耗时"展示。
  int elapsedSec = 0;

  /// 命中的修复建议（去重，最多展示 3 条——截取在 UI 层）。
  final List<String> hints = [];

  int _streamId = -1;
  int _offset = 0;
  DateTime? _startedAt;
  Timer? _timer;

  /// `✓ Built build/app/outputs` 行的命中时刻（alpha.58）：
  /// Built 打印在 Gradle 打包+签名**完成之后**——命中即构建本体已成功。
  /// flutter 工具偶发 Built 后 hang 不退出（dart VM 收尾不退出），
  /// 平台侧 running 恒真 → UI 永远停在「打包与签名 95%」骗用户。
  /// 宽限 [builtGraceSec] 秒后仍不退出则按成功强制收尾。
  DateTime? _builtAt;

  /// Built 后宽限秒数（flutter 收尾通常 <5s）。
  ///
  /// alpha.97：**90 → 20**。改小的依据不是"想快一点"，而是收尾判据
  /// 从「纯计时」升级成了「**双证据自适应**」（见 [builtSettled]）：
  /// 产物已落盘且**连续两次读数稳定**才提前收尾，确认不了才退回来
  /// 等满这个上限。也就是说 20s 是"确认失败时的兜底"，不是"每次要等
  /// 的时间"——真机实测 flutter 收尾 <5s，产物稳定在 <2s 内可确认。
  /// 上限本身也从 90 收紧：90s 是当年判据只有计时时的极宽余量，
  /// 双证据判据下不需要这么大。
  static const int builtGraceSec = 20;

  /// 产物"读数稳定"判定：连续两次探测间隔（秒）。
  ///
  /// 为什么需要它（而不是"文件存在就收尾"）：flutter/Gradle 收尾阶段
  /// 仍可能在写盘（拷贝、fsync、重命名），此刻去看文件是**存在的**，
  /// 但内容还没写全。若据此按成功收尾，用户拿到的是一个半截 APK。
  /// 用「两次读数完全一致」当稳定判据，代价 1~2 秒，换的是不误判。
  static const int builtStableProbeSec = 2;

  /// Built 行标记（flutter build 成功时打印 `✓ Built build/app/outputs/...`）。
  static const String builtMarker = 'Built build/app/outputs';

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

  /// 探测本次会话的目标产物是否已**稳定落盘**（alpha.97）。
  ///
  /// 返回 true 表示「读数连续两次一致，可以提前收尾」。
  ///
  /// 探测路径与 [_locateApk] 同源（`build/app/outputs/flutter-apk`），
  /// 目标文件名取自本次 [flavor]（debug → `app-debug.apk`）。**不猜路径**：
  /// 目录读不到 / 文件不在 → 直接返回 false，交给宽限兜底。
  ///
  /// 设计上刻意"笨"：只读目录、只比两个数字，不做任何推断。原因见
  /// [builtSettled] 的注释——不误判比快更重要。
  Future<bool> _probeSettled() async {
    final name = active;
    if (name == null) return false;
    final dir = '$_projectsDir/$name/build/app/outputs/flutter-apk';
    final list = await _fb.browse(dir);
    if (!list.ok) return false;
    FsBrowserEntry? hit;
    for (final e in list.entries) {
      if (!e.isDir && e.name == flavor.apkName) {
        hit = e;
        break;
      }
    }
    if (hit == null) return false; // 产物还没出现（或名字不是预期）
    final now = DateTime.now();
    final settled = builtSettled(
      builtAt: _builtAt,
      now: now,
      size: hit.size,
      mtime: hit.mtime,
      prevSize: _probeSize,
      prevMtime: _probeMtime,
      lastProbeAt: _lastProbeAt,
    );
    // 记录本次读数供下一轮比对（无论判定结果如何都要记——判据是
    // "连续两次一致"，只记不一致的那次就等于永远比不成）。
    _probeSize = hit.size;
    _probeMtime = hit.mtime;
    _lastProbeAt = now;
    return settled;
  }

  /// Built 后宽限判定（纯函数，可单测）：
  /// 命中 Built 行超过宽限期且会话仍在 building → 应强制按成功收尾。
  static bool builtGraceElapsed({
    required DateTime? builtAt,
    required DateTime now,
    int graceSec = builtGraceSec,
  }) {
    if (builtAt == null) return false;
    return now.difference(builtAt).inSeconds > graceSec;
  }

  /// 本会话的「产物稳定性」探测状态（alpha.97）。
  ///
  /// 只在 Built 命中后才开始探测；每次探测把读数（size+mtime）与上一次
  /// 比对，**连续两次完全一致**才认为落盘完成。任一读数缺失/为 0、
  /// 或两次不一致 → 归零重来（下次再比）。宁可多探一轮，不可误判。
  int _probeSize = -1;
  int _probeMtime = -1;
  DateTime? _lastProbeAt;

  /// Built 后"可以提前收尾"的判据（纯函数，可单测）。
  ///
  /// **alpha.97 的核心**：把原来的「等满 90s」换成「**有证据就立刻收尾**」。
  ///
  /// 输入的含义（全部来自调用方，函数本身不做 IO）：
  /// - [builtAt]：Built 行命中时刻。null = 构建还没到那一步，永不收尾。
  ///   （宽限上限 [builtGraceSec] 不在此处判——那是上一级 [builtGraceElapsed]
  ///   的职责。这个函数只回答"证据够不够充分"。）
  /// - [size] / [mtime]：**当前**读到的产物读数。必须都 > 0 才算"看得见"。
  /// - [prevSize] / [prevMtime]：上一次探测的读数（首次为 -1）。
  /// - [probeGapSec]：距上次探测过了多久。未到 [builtStableProbeSec]
  ///   就不做判断——**两次探测挨太近没有信息量**（读数一样只能说明
  ///   这 0.5s 内没变，不能说明写完了）。
  ///
  /// 三条同时满足才收尾：
  /// 1. 有产物且读数非空（size > 0）；
  /// 2. 两次读数**完全相等**（大小 + mtime 都不变）；
  /// 3. 两次探测间隔 ≥ [builtStableProbeSec]。
  ///
  /// ⚠️ 为什么是"相等"而不是"够大"：APK 大小本就波动（debug/release、
  ///    依赖增减都会变），任何绝对阈值都会在某个项目上失效。稳定性
  ///    是无量纲的，判据不随项目漂移。
  static bool builtSettled({
    required DateTime? builtAt,
    required DateTime now,
    required int size,
    required int mtime,
    required int prevSize,
    required int prevMtime,
    required DateTime? lastProbeAt,
    int probeGapSec = builtStableProbeSec,
  }) {
    if (builtAt == null) return false;
    // 产物必须"看得见"：size=0 可能是目录项已建但内容未写
    if (size <= 0 || mtime <= 0) return false;
    // 首次探测（无上一次读数）→ 只记状态，不判定
    if (prevSize < 0 || prevMtime < 0) return false;
    if (size != prevSize || mtime != prevMtime) return false;
    // 两次探测间隔不足 → 读数一致没有意义，等下一轮
    if (lastProbeAt == null ||
        now.difference(lastProbeAt).inSeconds < probeGapSec) {
      return false;
    }
    return true;
  }

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

  Future<void> start(
    String name,
    EnvInfo env,
    BuildBackend backend, {
    /// 构建类型（alpha.93）。debug 档不走 AOT，是设备端唯一能显著
    /// 提速的档位——详见 [BuildFlavor] 的文档注释。
    BuildFlavor flavor = BuildFlavor.release,
  }) async {
    if (building) return; // 防重入（页面 UI 也不会同时给两个入口）
    final bare = backend == BuildBackend.termux;
    active = name;
    status = BuildStatus.building;
    lines.clear();
    partial = '';
    apkGuest = null;
    this.flavor = flavor;
    // debug 档不走 AOT，进度条要跳过那一段（否则会看到 18% 的跳变）
    prog.skipAot = !flavor.needsAot;
    prog.reset();
    elapsedSec = 0;
    _startedAt = DateTime.now();
    _builtAt = null;
    _probeSize = -1;
    _probeMtime = -1;
    _lastProbeAt = null;
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
      // alpha.97：这里原来还有一条独立的 `test -x /opt/flutter/bin/flutter`
      // exec（+1 次容器往返）。它已被**并入下面的主构建 shell 头部**，
      // 与 stampFix/diag/heal 同批执行（见 buildCommand 的 preflight 段）。
      // 语义完全一致：缺失时 shell 打 `FOA_PREFLIGHT_NOFLUTTER=1` 并
      // exit 65，下面是同一句错误提示。
      //
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

      // Bug 449 附属修复（alpha.55，2026-09-19 真机实证）：NDK 空壳
      // （见上 ndkStub）只有 source.properties，AOT 修通后第一次跑到
      // gradle :app:stripReleaseDebugSymbols 时找不到 llvm-strip 直接
      // 炸。构建前检测补位：Debian llvm symlink 进 NDK 期望路径
      // （arm64 原生、不过 qemu、能剥任意架构 ELF）。llvm 不可用时
      // 不阻断——留给 strip 阶段报错，避免网络问题卡死整个构建入口。
      final sErr = await ToolchainEnsure().ndkStripTools();
      if (sErr != null) lines.add('⚠ $sErr（不阻断构建）');

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

    lines.add('▶ flutter build apk --no-shrink --${flavor.arg}'
        ' --target-platform=android-arm64');
    lines.add('  目录：$projectsDir/$name');
    lines.add('  后端：${bare ? 'Termux 裸原生（不经 proot）' : 'Proot 容器'}');
    lines.add('  类型：${flavor == BuildFlavor.debug ? 'Debug（不走 AOT，快）' : 'Release（走 AOT，可上架）'}');
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

      // 磁盘空间体检（手册 Bug 603 方案第 1 条）：以前只在失败后分诊，
      // 而手机上一次构建 20~30 分钟——等烧完再说"空间不够"等于白等。
      final disk = await ToolchainEnsure().diskSpace();
      if (disk != null && disk.warning) {
        if (disk.blocking) {
          status = BuildStatus.error;
          lines.add('✗ 存储空间不足（剩余 ${disk.human}）——这个量级下构建'
              '几乎必然失败，先清理再开始');
          lines.add('  ${disk.advice}');
          _ui();
          return;
        }
        lines.add('⚠ 存储空间偏紧（剩余 ${disk.human}）：构建可能在中途'
            '因写满而失败');
        lines.add('  ${disk.advice}');
        lines.add('');
        _ui();
      }
    }

    // ---- Bug 636：非法 shrink 组合（AGP 会拒绝配置工程）----
    //
    // 症状（真机，连 debug 构建都炸）：
    //   > A problem occurred configuring project ':app'.
    //   > Removing unused resources requires unused code shrinking
    //     to be turned on.
    //
    // 真因：`isShrinkResources = true` 而 `isMinifyEnabled = false`。
    // AGP 的 `AndroidResourcesCreationConfigImpl` 对这两个值的组合有
    // 硬校验（反编译实证），不满足就是**配置期致命错误**。
    //
    // 为什么 debug 也中招：Flutter Gradle 插件对 release 无条件设
    // `isMinifyEnabled=true` + `isShrinkResources=true`，而 debug 变体
    // 通过 buildType 继承拿到同一组属性。所以在 release 块里手动关掉
    // minify，会连带 debug 一起配置失败。
    //
    // 为什么必须在这里修（而不是只在清单页提供按钮）：
    // 这是**构建期**的致命错误，用户完全可能直接点"打包"、从不打开
    // 清单页 —— 那样就只会看到一句英文报错，无从下手。构建前静默修掉
    // （幂等，合法时零开销），并在日志里**说清楚改了什么**。
    //
    // ⚠️ 只改"两个值都显式写了"的情况。`isShrinkResources` 没写时走的是
    //    Flutter 插件的默认值（release 下 true/true，合法），
    //    **绝不能**拿我们读到的默认值当判据去改用户的文件。
    if (!bare) {
      final fixed = await _fixIllegalShrinkCombo(name);
      if (fixed != null) {
        lines.add('⚠ $fixed');
        lines.add('');
        _ui();
      }
    }

    // ---- Bug 638：老写法签名脚本（`java.util.Properties()`）----
    //
    // 症状（真机）：
    //   e: build.gradle.kts:5:31 Unresolved reference 'util'
    //   e: build.gradle.kts:5:31 Unresolved reference 'io'
    //
    // 真因：Flutter 模板第一行是 `plugins {}`，Kotlin 的 `plugins` 块是
    // **隐式 receiver 作用域**，会遮蔽 `java` 这个**顶层包标识符** ——
    // 于是 `java.util.Properties()` 里的 `java` 被解析成"某个对象的属性"，
    // 找不到 → Unresolved reference。补上 `import java.util.Properties`
    // 之后用**简单名** `Properties()` 就没这个问题。
    //
    // 为什么必须在这里修（而不是只在清单页）：
    // 与 Bug 636 同一个理由 —— alpha.94 修好的是**生成器**，
    // 而**已经打过旧补丁的工程不会自动回写**。用户反复构建、反复报错，
    // 我们这边看起来"早就修了"。README 里这条诚实边界（"检测只在清单页
    // 触发，用户若从不打开清单页……本轮未做"）由这一处补上。
    //
    // 复用 [Signing.repairLegacyPatch]：它已经是"能修就修、修不了说清
    // 为什么"的形态，且**只在 kotlinDsl 且确有老写法时才写文件**
    // （Groovy 没这个遮蔽问题），幂等，合法时零开销。
    if (!bare) {
      final r = await Signing.repairLegacyPatch(
        FsBridge(),
        projectName: name,
      );
      if (r.changed) {
        lines.add('⚠ ${r.msg}');
        lines.add('');
        _ui();
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
      flavor: flavor,
      // alpha.97：proot 后端把 Flutter 存在性检查并入主 shell
      prootFlutterProbeNeeded: !bare,
      // alpha.97：stamp 目录必须与后端匹配（原先写死容器路径，
      // termux 后端因此从来没有真正刷新过自己的 cache 目录）
      cacheDir: bare
          ? '${TermuxPaths.flutterHome(env)}/bin/cache'
          : '${QemuCompat.flutterHome}/bin/cache',
      // alpha.97：diag / heal / reassert 三段的 `@FLUTTER@` / `@ENGINE@` /
      // `@SDK@` 同理（原先全写死容器路径，termux 下等于三段一起空跑）
      flutterHome: bare
          ? TermuxPaths.flutterHome(env)
          : QemuCompat.flutterHome,
      engineDir: bare
          ? '${TermuxPaths.flutterHome(env)}/bin/cache/artifacts/engine'
          : QemuCompat.engineDir,
      sdkHome: bare ? TermuxPaths.sdkHome(env) : QemuCompat.sdkHome,
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
    // alpha.59：标记通知归属——点击跳构建页
    BuildNotify.lastRoute = 'build';
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
  /// 刷新 flutter 的「版本检查时间戳」，跳过它内部的 `git fetch --tags`。
  ///
  /// Bug 436（2026-09-19 真机）：每次构建都出现
  /// ```
  /// Command exited with code 128: fetch --tags
  /// error: RPC failed; HTTP 504 curl 22 ... fatal: the remote end hung up
  /// ```
  /// 并在「准备构建环境」停留很久（4% 就耗掉近 2 分钟）。
  ///
  /// 真因**不在我们的镜像配置**——git URL 重写规则实测正确
  /// （`git ls-remote --get-url` 确认已改写到 gitclone 镜像），
  /// 而是 flutter 工具自身的版本新鲜度检查：
  /// `VersionFreshnessValidator.checkAgeConsideredUpToDate = 3 days`，
  /// 距上次检查超过 3 天就会重新 `_fetchRemoteFrameworkCommitDate()`
  /// （内部即 `git fetch --tags`）。真机上该请求 504，flutter 吞掉异常
  /// 继续跑（`VersionCheckError` 是 best-effort），**但用户要先等满超时**。
  ///
  /// stamp 文件 `<cache>/flutter_version_check.stamp` 是公开的缓存协议
  /// （JSON，字段 `lastTimeVersionWasChecked`）。构建前把它刷新成当前时间，
  /// flutter 就会认为「刚检查过」而跳过网络请求——这是官方机制内的用法，
  /// 不修改 SDK 源码、不影响其它行为。
  ///
  /// 失败静默：这个优化本身不该成为新的失败点。
  static const String refreshVersionCheckStamp = r'''
C=@CACHE@
S="$C/flutter_version_check.stamp"
mkdir -p "$C" 2>/dev/null
printf '{\n  "lastTimeVersionWasChecked": "%s"\n}\n' "$(date '+%Y-%m-%d %H:%M:%S.%6N')" > "$S" 2>/dev/null
exit 0
''';

  /// alpha.97：**并入主 shell 的 Flutter 存在性前置检查**。
  ///
  /// 原实现是在 Dart 侧单独发一次
  /// `bridge.exec('test -x /opt/flutter/bin/flutter')`——每次构建多一次
  /// 容器往返（真机上 proot 起来 + shell 初始化是几百毫秒级的固定开销）。
  /// 既然紧接着就要发一条大 shell，把这条检查挪进去是纯粹的净收益：
  /// 语义不变，往返少一次。
  ///
  /// 探测失败 → exit 65，Dart 侧按退出码给原本那句引导文案。
  /// 只有 **proot** 后端需要（termux 已在前置组件检查里覆盖）。
  static const String prootFlutterProbe = r'''
test -x /opt/flutter/bin/flutter || {
  echo "FOA_PREFLIGHT_NOFLUTTER=1"
  exit 65
}
''';

  /// alpha.97：`pub get` 多源轮换的**指数退避**片段。
  ///
  /// 原来每源固定 `sleep 3`——3 源 × 2 次 = 最坏 18 秒纯等待，而前几秒
  /// 的失败往往只是瞬时抖动。改成 **1s → 3s 递增**，换源时重置回 1s
  /// （换了源等于重新开始）。
  ///
  /// 期望收益：顺利路径 0s 等待（原本也是，成功即 break）；抖动路径
  /// 6s → 2s。**这是"更好"而不是"一定更快"**——老实说，正常网络下
  /// 这条改动几乎看不出差别，它的价值是在弱网抖动时少等几秒。
  ///
  /// ⚠️ 退避偏保守（没上 0/1/2 那种激进序列）：用户的取舍是
  /// 「宁可慢一点也别出错」，弱网是这条链路的主要场景，退避太短会把
  /// "本来第二次就能成功"变成"两次都撞在同一个抖动窗口上"。
  static String pubRetryBackoffLoop({required String flutterCmd}) =>
      'ok=0; '
      'for src in https://pub.flutter-io.cn '
      'https://mirrors.tuna.tsinghua.edu.cn/dart-pub '
      'https://mirrors.ustc.edu.cn/dart-pub; do '
      'b=1; '
      'for i in 1 2; do '
      'if PUB_HOSTED_URL=\$src $flutterCmd pub get; '
      'then ok=1; break 2; fi; '
      'sleep \$b; b=3; '
      'done; done; '
      '[ "\$ok" = 1 ] || exit 69; '
      'export PUB_HOSTED_URL=\$src; ';

  static String buildCommand({
    required String proj,
    required String flutterCmd,
    required String envPart,
    required String aapt2Override,
    BuildFlavor flavor = BuildFlavor.release,
    bool prootFlutterProbeNeeded = false,

    /// flutter 的 `bin/cache` 目录（Bug 436 的版本检查 stamp 写这里）。
    /// 后端感知：proot = `/opt/flutter/bin/cache`；
    /// termux = prefix 下的 flutterHome。默认值保住既有调用方语义。
    String cacheDir = '/opt/flutter/bin/cache',

    /// Flutter 安装根目录，供 diag / heal / reassert 三段脚本填充使用。
    /// 必须后端感知——**proot = `/opt/flutter`，termux = prefix 下**。
    /// 传错不会报错，只会让那三段静默空跑（见 QemuCompat.fill 的注释）。
    String flutterHome = '/opt/flutter',

    /// 引擎构件目录（`<flutterHome>/bin/cache/artifacts/engine`）。
    /// 同上，必须后端感知——reassert 的第一句就是 `[ -d "$E" ] || exit 0`，
    /// 路径错 = 转发层重建静默跳过。
    String engineDir = '/opt/flutter/bin/cache/artifacts/engine',

    /// Android SDK 根目录（heal 用它扫 build-tools / platform-tools
    /// 下的 `.foa-real`）。同样必须后端感知。
    String sdkHome = '/opt/android-sdk',
  }) {
    // Bug 433：pub get 会触发 Flutter 重新下载引擎构件，把 linux-arm64/
    // 下的转发脚本盖回真 x64 二进制（真机表现：AOT 跑到 54% 后
    // shaders/*.frag 编译 SIGILL，exit -4）。因此在 pub get 之后、
    // flutter build 之前，于**同一条 shell 命令内**再断言一次转发层。
    //
    // 注意：不能用 `{ script ; }` 分组——脚本末尾带换行，`\n ; }` 在
    // dash/bash 下都是语法错误。改用 `sh -c '...'` 独立执行，既避开
    // 分组问题，也把它的输出隔离（只留最后 2 行，避免刷屏）。
    final reassert = QemuCompat.fill(
      QemuCompat.wrapReassertScript,
      flutterHomeOverride: flutterHome,
      engineDirOverride: engineDir,
    );
    // Bug 436：跳过 flutter 内部的 git fetch --tags 版本检查。
    //
    // alpha.97：`@CACHE@` 的取值改为**后端感知**——原先写死
    // `QemuCompat.flutterHome`（= 容器的 `/opt/flutter`）。termux 后端
    // 的 Flutter 装在 prefix 下（`TermuxPaths.flutterHome`），写死容器
    // 路径等于每次构建都白白 mkdir/写一个**根本不存在的目录**，而真正
    // 的 cache 目录一次都没被刷新 —— Bug 436 想省的那次 `git fetch --tags`
    // 在 termux 后端从来没被省掉过。
    //
    // 这个 bug 是在给 alpha.97 的"termux 不该出现容器路径"断言时
    // 撞出来的：断言本身是对的，错的是代码。
    final stampFix = refreshVersionCheckStamp.replaceAll('@CACHE@', cacheDir);
    // Bug 438：构建前诊断——把「qemu 能否运行 x64」这件最基础的事实
    // 打进构建日志。真机上 shader 阶段 exit -4（SIGILL）且 stderr 为空
    // （flutter 打印 `impellerc failure: ` 后面什么都没有），说明进程被
    // 信号杀死、来不及输出。这种静默崩溃无法从 flutter 的日志反推原因，
    // 必须在构建前**主动**测一遍 qemu 链路并记录结果。
    //
    // alpha.97：同样要把 flutterHome 传对，否则 `@FLUTTER@` 展开成容器
    // 路径，脚本里 `[ -x @QEMU@ ] || exit 0` 会直接短路——**整段诊断
    // 静默什么都不做**，用户看到的日志里连 QEMU_CHAIN_* 都没有，
    // 却完全不知道为什么。
    final diag = QemuCompat.fill(
      QemuCompat.buildPreflightScript,
      proj: proj,
      flutterHomeOverride: flutterHome,
      engineDirOverride: engineDir,
    );

    // alpha.93：AOT 工具链预取段。debug 档**不跑**这段——
    // `precache --android_gen_snapshot` 预取的是 AOT 工具链
    // （gen_snapshot / impellerc），而 debug 走 kernel（JIT）根本不调用
    // gen_snapshot，跑了纯属浪费，还会触发一轮构件下载（真机弱网下
    // 可能好几分钟）。
    final precachePart = flavor.needsAot
        ? 'echo "---- 预取引擎构件（把 build 内部的下载提前）----"; '
            '$flutterCmd precache --android_gen_snapshot 2>&1 | tail -n 5; '
        : 'echo "---- debug 档：跳过 AOT 工具链预取（不需要 gen_snapshot）----"; ';
    // Bug 441：自愈——把被误包装的文件（如 flutter_tools.snapshot）还原。
    // 放在 reassert 之前：先修好坏文件，再重建转发层，顺序反了会把
    // 刚还原的文件又包一遍。幂等且低代价（只 mv，不动 apt/不删引擎目录），
    // 因此每次构建都跑没有副作用。
    final heal = QemuCompat.fill(
      QemuCompat.healScript,
      flutterHomeOverride: flutterHome,
      engineDirOverride: engineDir,
      sdkHomeOverride: sdkHome,
    );
    return "cd $proj && $envPart"
        'FLUTTER_ALLOW_ROOT=true '
        // Bug 436：proot 路径原先没设该变量（只有 pub get 那行内联了
        // PUB_HOSTED_URL），导致引擎/资产下载回落到官方地址。
        // profile.d/foa-env.sh 里有，但 proot -c 直接执行 sh 不读 profile。
        'FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn '
        // alpha.97：Flutter 存在性前置检查（原为 Dart 侧单独一次 exec）。
        // 只在 proot 需要——termux 前端已查过。放在**最前面**：
        // 缺 SDK 时立刻退出，不浪费后面那段诊断的时间。
        '${prootFlutterProbeNeeded ? 'sh -c ${_shq(prootFlutterProbe)} 2>&1 | tail -n 2; ' : ''}'
        'sh -c ${_shq(stampFix)} 2>&1 | tail -n 1; '
        // Bug 438：qemu 链路预检（输出 QEMU_CHAIN_* 供真机排障）
        //
        // Bug 443：行数上限必须**留足余量**。之前是 tail -n 12，
        // 但预检失败时每行诊断会多带一行原因（Bug 437 加的），
        // 再加 flutter 自身的 stderr 混入，12 行会把**开头几行挤掉**——
        // 而 qemu 版本/加载器状态恰恰在最前面。真机上表现为
        // "日志里没有 REASSERT="，让人以为兜底没跑。
        // 宁可多打几行，也不要丢诊断信息。
        'sh -c ${_shq(diag)} 2>&1 | tail -n 30; '
        // Bug 441：还原被误包装的文件（输出 HEALED=/DART=/SNAPSHOT=）
        // Bug 443：heal 现在会输出 HEALED + DART + SNAPSHOT 三行，
        // 再叠上可能的 stderr，tail -n 3 会截掉前面。放到 10。
        'sh -c ${_shq(heal)} 2>&1 | tail -n 10; '
        // alpha.97：多源轮换 + 指数退避（原为固定 sleep 3）
        '${pubRetryBackoffLoop(flutterCmd: flutterCmd)}'
        // Bug 433 转发层再断言（pub get 后、build 前，同一 shell）
        // Bug 443：reassert 输出 REASSERT= + REASSERT_DART= 两行，
        // 且 `gen` 生成失败时会有 stderr。tail -n 2 太紧（会被 stderr
        // 顶掉正常行），放到 10 确保两行都在。
        // ---------------- Bug 444：把 build 内部的构件下载提前 ----------------
        // 真机链路（已由 flutter_tools 源码 + 沙箱目录结构双向证实）：
        //   AOT 用的 gen_snapshot 路径 = `android-arm64-release/<host>/gen_snapshot`
        //   （artifacts.dart `_getAndroidArtifactPath`：join(engineDir,
        //    hostPlatformName, name)），hostPlatformName 由 `uname -m` 决定，
        //   真机 Android 上 = `linux-arm64`。
        //   而官方**没有** arm64 版的 android gen_snapshot
        //   （artifacts.dart 的 TODO：flutter/flutter#152281），
        //   `linux-arm64/` 目录下放的就是 x86_64 二进制 —— 必须靠转发脚本。
        // 问题：flutter build 在 AOT 之前会检查构件是否就位、缺失则补下载。
        //   （⚠️ 日志里的 `Flutter assets will be downloaded from ...` 是
        //   **常驻提示**，构件已缓存时也会打印 —— 沙箱本次构建就打了这行
        //   而并未真的下载。不能用它判断下载是否发生，别再拿它当证据。）
        //   一旦真的下载，就会把 `linux-arm64/{gen_snapshot,impellerc,...}`
        //   覆写成**裸 x86_64 ELF**，盖掉 reassert 刚放好的转发脚本 → SIGILL。
        //   触发条件 = 构件缓存缺失（卸载重装 / 清数据 / 首次构建），
        //   这也是"之前能构建、卸载重装后必崩"的原因。
        // 修法：先跑 precache 让**下载发生在 reassert 之前**，reassert 再
        //   重建转发层；此时构件已缓存，build 内部不会再下载 → 不会再覆盖。
        //   `--android_gen_snapshot` 精确覆盖 AOT 那两个工具，universal
        //   （impellerc/font-subset）默认 true 会一并带上。
        // ⚠️ 这里的 `| tail -n 5` 是**故意**吞掉退出码做容错：precache
        //   失败（网络/镜像抖动）不该中断构建，后面还有兜底重试。
        //   （对比 Bug 443：那次是无意中被管道吞掉退出码，性质不同。）
        // alpha.93：debug 档**不跑**这一步。precache --android_gen_snapshot
        // 预取的是 AOT 工具链（gen_snapshot / impellerc），而 debug 走
        // kernel（JIT）根本不调用 gen_snapshot——跑了纯属浪费，而且它会
        // 触发一轮构件下载（真机弱网下可能几分钟）。
        // ⚠️ 不能在这里直接写三元：三元整体是条件表达式而不是 STRING
        //    token，**无法参与**相邻字符串字面量的隐式拼接（会报
        //    "Expected to find ';'"）。所以先算成变量再插值进来。
        '$precachePart'
        // ---------------- Bug 445：跑完 precache 立刻重建转发层 ----------------
        // 真机 alpha.50 的日志证明：**下载发生在 build 内部的 AOT 之前**，
        // 我上一版把 precache 放在 reassert 前面**没有拦住它** ——
        // build 自己又下了一遍（它有自己的完整度判定，precache 的精简集
        // 满足不了），照样盖掉 linux-arm64/。所以紧接着 precache 再断言一次，
        // 确保 build 启动时转发层一定是完好的。
        // （⚠️ 这只是"多一道保险"，真正的根治是 build 之后的 heal + 重启构建；
        //   见下面 Bug 445 段。别指望这一步能单独解决问题。）
        'sh -c ${_shq(reassert)} 2>&1 | tail -n 10; '
        '$flutterCmd build apk --no-shrink --${flavor.arg} '
        '--target-platform=android-arm64$aapt2Override; '
        // Bug 443：构建失败时**再快照一次** AOT 工具链指纹。
        // 目的是把「构建前 vs 构建后」的转发层状态摆在一起对比：
        // 若构建前是 wrapper、构建后变 RAW_ELF，就能确证是
        // flutter build 内部下载引擎构件把转发层覆盖了（Bug 428 的
        // 变体：precache 发生在 build 过程中，而不是 pub get 阶段）。
        // 只在失败时跑，成功时不留噪音。
        //
        // ---------------- Bug 445：构建后重新取指纹（不是复用旧变量！）----
        // ⚠️ alpha.50 的一处真 bug：这里原写成
        //     fp=$(sh -c '<diag>' | grep -E "AOT_FP=")
        //   但 `fp` 在**上面第一处诊断**已经赋值过了，而这里取的是
        //   **同样的诊断**，只是没走 tail 截断。真机日志里那对
        //   `AOT_FP=impellerc=wrapper` + `AOT_FP=impellerc=RAW_ELF`
        //   不是"两个不同时刻的值"，而是**一次执行的输出被印了两遍**
        //   （diag 只跑了一次，`tail -n 30` 截掉了前半、完整输出在失败段）。
        //   两个文件的四次出现、以及 `QEMU_CHAIN_*` 行只出现一次，
        //   都与此吻合。
        //   后果：我还是不知道"构建后"到底是不是 RAW_ELF。
        //   **所以必须真的重取一次，而且要把新指纹打进日志做对比。**
        //   判定放到 heal+重启之后（见下），因为重启后的构建才是最终事实。
        'brc=\$?; if [ "\$brc" != 0 ]; then '
        'echo "---- 构建后工具链指纹（重新采集，对比上面的 AOT_FP）----"; '
        // Bug 448：这里原来只 grep "AOT_FP="，把 AOT_LOAD / AOT_LOAD_DEF
        // 裁决行全滤掉了 —— alpha.53 真机失败后本该出现的两个退出码
        // 恰恰是最需要的证据，却被这一层过滤吞了。裁决行必须全量透传。
        'fp=\$(sh -c ${_shq(diag)} 2>&1 | grep -E "AOT_FP=|AOT_LOAD"); '
        'echo "\$fp"; '
        // ---------------- Bug 445：heal + 重启构建 ----------------
        // 真机实测（alpha.50 日志）：
        //   FOA_HEAL=转发层在构建中被覆盖，重建后重试一次
        //   REASSERT=0
        //   REASSERT_DART=0
        // **rebuild（重启构建）两步都返回 0，一个文件都没重建** ——
        // 因为 AOT 失步**没有停掉整个构建**：`Target android_aot_..._failed`
        // 被 flutter 记录后，构建继续跑到 shader/资产阶段才整体失败，
        // 而这个过程中 gen_snapshot 已经**产出**了 app.so（Dart AOT 的
        // 失败是非致命的），把文件恢复成了正常的 x64 ELF 形态。
        // 于是 reassert 一看"已是正常形态"就跳过 → 覆盖状态被固化 →
        // 重启构建仍然崩。
        // 根因：**"看形态判定"的幂等修复，遇上"被覆盖后形态依然合法"
        //   的情况会静默失效。**
        // 修法（两件事缺一不可）：
        //   ① heal：把 linux-arm64/ 下的转发位**无条件**删除并由其
        //      linux-x64/ 对应文件重新生成（该目录里的东西**本来就该
        //      全是转发脚本**，不存在"合法的裸 ELF"，所以无条件删是安全的、
        //      比看形态更可靠）；
        //   ② 重启构建：让 AOT 用重建后的转发层重跑一遍。
        // ⚠️ 为什么是"**重启构建**"而不是"重跑 build"：
        //   flutter 的增量构建会看到 app.so「已存在且比输入新」，直接跳过
        //   AOT target，转发层修好了也不会重新编译。必须造一个输入变化
        //   （删掉 app.dill / app.so）把 AOT 逼出来。
        // ⚠️ 判据只看 **BAD**，不能再 grep "RAW_ELF"（Bug 445）：
        //   `linux-x64/` 下的真身**本来就该是** RAW_ELF，
        //   用 RAW_ELF 当"被覆盖"的判据会**恒为真**、白跑一轮自愈。
        //   现在诊断给每行标了角色与是否合格，只看 BAD 即可。
        'if echo "\$fp" | grep -q "BAD("; then '
        'echo "FOA_HEAL=检测到转发位异常（见上面 BAD 行），重建转发层并重启构建"; '
        '$flutterCmd clean --no-version-check > /dev/null 2>&1; '
        'sh -c ${_shq(reassert)} 2>&1 | tail -n 10; '
        '$flutterCmd build apk --no-shrink --${flavor.arg} '
        '--target-platform=android-arm64$aapt2Override; brc=\$?; '
        'fi; fi; exit \$brc';
  }

  /// 单引号包裹一段 shell 片段（内部单引号用 '\'' 转义）。
  /// 用于把多行脚本安全地塞进 `sh -c '...'`。
  static String _shq(String s) =>
      "'${s.replaceAll("'", "'\\''")}'";

  /// 清理构建缓存（flutter clean，工作台打包配置卡的快捷操作）：
  /// 返回 null = 成功，否则返回错误文案。构建中拒绝（防清掉正在
  /// 使用的 build 目录）。
  Future<String?> clean(
    String name,
    EnvInfo env,
    BuildBackend backend,
  ) async {
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
  /// Bug 636：构建前修掉会让 AGP **拒绝配置工程**的 shrink 组合。
  ///
  /// 返回 null = 无需处理（占绝大多数，零可见开销）；
  /// 非 null = 一行"改了什么"的可读说明，由调用方打进构建日志。
  ///
  /// ## 为什么用 [FsBridge] 而不是 dart:io
  ///
  /// 与 [_gradleMirrorFromDart] 不同：那个只在 termux 后端跑（rootfs 树
  /// 宿主可见，直接 dart:io 就行）。这个方法两后端都要跑，而 proot 后端的
  /// 工程在容器里 —— 必须走容器域文件通道（Kotlin 侧 java.io 直读写
  /// rootfs 真实路径），才能保证"读到的就是构建真正会用的那份文件"。
  ///
  /// ## 三条防护
  ///
  /// 1. **只修那一种组合**：[ManifestCodec.hasIllegalShrinkCombo] 要求
  ///    `isShrinkResources` 与 `isMinifyEnabled` **都显式写了**。
  ///    没写的一侧走 AGP/Flutter 插件默认，我们读到的值与真实生效值
  ///    可能不同，拿它当判据会误改用户工程。
  /// 2. **只改一行**：把 `isShrinkResources` 改成 false，不碰 minify
  ///    （那是用户刚手动设的、明确的意图）。
  /// 3. **失败不阻断**：修不了就只报一行警告、照常构建 —— 让 AGP 自己
  ///    报那个原始错误（至少用户能拿它去搜），比我们静默吞掉好。
  Future<String?> _fixIllegalShrinkCombo(String name) async {
    final fb = FsBridge();
    try {
      for (final rel in _gradleRelCandidates) {
        final path = '$_projectsDir/$name/$rel';
        final r = await fb.read(path);
        if (!r.ok) continue;
        if (!ManifestCodec.hasIllegalShrinkCombo(r.content)) continue;

        final fixed = ManifestCodec.fixIllegalShrinkCombo(r.content);
        if (!fixed.changed) continue;

        final w = await fb.write(path, fixed.code);
        if (!w.ok) {
          return '检测到 $rel 里 isShrinkResources=true 而 '
              'isMinifyEnabled=false（AGP 会拒绝配置工程），但自动修复失败'
              '（${w.error}）——请到「清单」页手动关闭资源缩减';
        }
        return '已自动修复 $rel：isShrinkResources → false。'
            '它原为 true 而 isMinifyEnabled=false，AGP 会因此在配置阶段'
            '直接失败（连 debug 构建也一起挂）。关掉资源缩减只是包大一'
            '点，不影响功能。';
      }
    } catch (e) {
      // 尽力而为：这里失败不该让构建连不起来
      return '⚠ shrink 组合检查异常（忽略，构建继续）：$e';
    }
    return null;
  }

  /// build.gradle 候选（与清单页的 `_gradleCandidates` 同一份口径）。
  ///
  /// ⚠️ 两处必须一致：清单页读的那份文件、构建前修的那份文件、
  /// 构建真正用的那份文件，**必须是同一个**。所以这里单独列一份而不是
  /// 从 UI 层 import —— 但内容要与 `manifest_page.dart` 的对齐。
  static const List<String> _gradleRelCandidates = [
    'android/app/build.gradle.kts',
    'android/app/build.gradle',
  ];

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
    // alpha.58：Built 已命中（构建+签名本体完成）而 flutter 进程 hang
    // 不退出 → 强制按成功收尾（产物路径从日志/文件系统确认）。
    //
    // alpha.97：收尾判据升级为**双证据自适应**，两级：
    //   ① 产物稳定确认（[builtSettled]）—— 命中 Built 后探测 APK 读数，
    //      连续两次一致即认为落盘完成，**立刻**收尾。真机实测这一步
    //      1~3s 内就能成立，原来的「每次都干等满 90s」正是缺了这条。
    //   ② 宽限兜底（[builtGraceElapsed]）—— 探测不到（目录还没出现 /
    //      mtime 一直变 / 平台读不到）时，老实等满 [builtGraceSec]。
    //
    // ⚠️ 用户明确的取舍是「宁可慢一点也别出错」：所以 ① 的证据要求
    //    **严**（size 与 mtime 双双相等、且间隔够），凑不齐就走 ②。
    //    **绝不允许**"没看到产物也按成功收尾"——那正是必须避免的误判。
    if (status == BuildStatus.building && _builtAt != null) {
      final settled = await _probeSettled();
      if (settled) {
        lines.add('✓ 产物落盘确认（读数连续一致）——提前收尾，'
            '不再等满 ${builtGraceSec}s');
        await _finish(0);
        return;
      }
    }
    if (status == BuildStatus.building &&
        builtGraceElapsed(builtAt: _builtAt, now: DateTime.now())) {
      // 走到这里说明探测没确认成功。宽限到期仍然按成功收尾——这是
      // alpha.58 就有的行为，保留：Built 行本身就是"构建成功"的铁证，
      // 后面 _finish → _locateApk 还会再验一次产物路径，找不到会如实
      // 报「构建成功但未找到 APK 产物」。
      lines.add('ℹ flutter 工具 Built 后未退出（偶发 hang，已等待 '
          '$builtGraceSec 秒，产物稳定性探测未确认）——按构建成功收尾');
      await _finish(0);
      return;
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
      // alpha.58：Built = Gradle 打包+签名已完成（Built 打印在签名之后）。
      // 立即提示，避免用户把"flutter 收尾 hang"误读成"卡在签名"。
      if (_builtAt == null && line.contains(builtMarker)) {
        _builtAt = DateTime.now();
        lines.add('✓ Gradle 打包+签名完成，等待 flutter 工具收尾…'
            '（若 ${builtGraceSec}s 内未自动结束将按成功收尾）');
      }
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
    // Bug 441：优先判这个——它是最具体的信号，且和下面 'shared libraries'
    // 的通配提示是同一句话的前缀，必须排在前面才不会被吃掉。
    //
    // `invalid ELF header` 只可能来自动态加载器（ld.so）：说明某个
    // **不是 ELF 的东西**被当成了可执行程序。真机最典型的受害者是
    // `flutter_tools.snapshot`（Dart app-jit 快照，头 dc dc f6 f6）。
    if (l.contains('invalid elf header')) {
      tip = '工具链文件被误包装成转发脚本（非 ELF 被送进加载器）：'
          '构建前会自动还原（HEALED=）；若本条仍出现，到「工具链」页执行'
          '一次「一键应用」重建转发层后重试（Bug 441）';
    } else if (l.contains('illegal instruction')) {
      // Bug 442：**这条必须排在 'exit code -4' 那组之前**。
      // pub get 阶段的 SIGILL 与 AOT 阶段的 SIGILL 是完全不同的两件事：
      //   - AOT/shader 阶段（有 'impellerc' / 'snapshot generator' 上下文）
      //     → 引擎转发层被 precache 覆写，是 Bug 428/437
      //   - 但 `Illegal instruction` 出现在 **pub get 前后、无编译上下文**
      //     → dart-sdk/bin 的转发层丢了，arm64 直接跑 x64 的 dart，是 Bug 442
      // 若不加这个分支，用户看到的是"重新应用兼容层"这种无关建议。
      tip = '工具链入口（dart-sdk/bin）的转发层丢失：arm64 直接执行了 x64 的 '
          'dart。构建前会自动重建（看日志 REASSERT_DART=）——若 REASSERT_DART '
          '为 0 而本条仍出现，到「工具链」页「重新应用」x64 兼容层后重试（Bug 442）';
    } else if (l.contains('exec format error')) {
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
    // alpha.97：exit 65 = 并入主 shell 的 Flutter 存在性前置检查没过。
    // 这条检查原先在 Dart 侧单独 exec、有自己的引导文案；挪进 shell 后
    // 要把那句文案补回来，否则用户只看到一个裸的 "exit 65"。
    if (code == 65) {
      lines.add('✗ 容器内未找到 Flutter SDK（/opt/flutter/bin/flutter）');
      lines.add('  请到「工具链」页安装 Flutter 后再打包');
    }
    final ok = code == 0 && apkGuest != null;
    if (ok) {
      // 只有"成功且产物就位"才授予 100%，不动用插值
      prog.markDone();
    } else {
      prog.markHalted();
    }
    status = ok ? BuildStatus.done : BuildStatus.error;
    // 「首次构建」标记必须成功一次才落 —— 写在这里（而不是某个页面里）
    // 是因为构建 20~30 分钟，用户中途锁屏/切走是常态，页面上的钩子会漏记。
    // 失败与取消不写：那时 Gradle 依赖没下完、daemon 没热起来，
    // 下次**仍然**是冷构建，现在关掉提示等于骗人。
    if (ok) await FirstBuildPrefs.markDone();
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

  /// 在容器内查找 flutter-apk 产物（优先匹配本次会话的构建类型）。
  ///
  /// alpha.93：原来是写死优先 `app-release.apk`，加了 debug 档之后就不
  /// 能这么挑了——debug 构建产出 `app-debug.apk`，而 debug/release 的
  /// 产物**会同时留在** outputs 目录里（不会互相覆盖）。写死 release
  /// 会让"刚构建完 debug 包"却定位到上一次的 release 包，装错版本。
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
      if (a.name == flavor.apkName) {
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
