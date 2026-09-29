/// 工具链一键安装编排（首次引导页「全自动安装」的后端）。
///
/// ## 为什么需要这个文件
///
/// 工具链有 6 个独立组件（rootfs / JDK / Android SDK / Flutter SDK /
/// QEMU 兼容层 / 构建镜像），各自有完整的 `install()` 静态方法，但
/// **在此之前没有任何一处把它们串起来** —— 用户必须在工具链页一个卡片
/// 一个卡片地点过去，还得自己知道该按什么顺序点。
///
/// 这里补的就是那个"顺序"。
///
/// ## 六者签名为什么长得一样
///
/// ```
/// static Future<String> install(
///   ProotBridge bridge, EnvInfo env, {
///   void Function(String phase)? onPhase,
///   void Function(DownloadProgress)? onProgress,
///   void Function(MirrorSource)? onMirrorUsed,
///   DownloadCancelToken? token,
/// })
/// ```
/// 六个组件全都是这个形状，失败一律抛 [DownloadException]。这是能编排的
/// 前提，不是巧合：写这些 installer 时就按"将来会被串起来"设计的。
///
/// ## 顺序不是随便排的
///
/// ```
/// rootfs → JDK → Android SDK → Flutter SDK → QEMU → 镜像 → 原生后端
/// ```
///
/// - **rootfs 必须第一**：其余几个的 `install()` 第一行都是
///   `if (!env.rootfsInstalled) throw DownloadException('rootfs 未安装…')`。
/// - **轻的在前**：JDK 190MB 先装完能让用户早一点看到"有东西成了"，
///   比一上来就等 1.5GB 的 Flutter SDK 体验好得多。
/// - **QEMU 放 SDK 之后**：[QemuCompat.apply] 会去接管 `/opt/android-sdk`
///   下的 aapt2、`/opt/flutter` 下的 dart —— 那些目录还不存在时它只能做
///   一半。所以放在两个 SDK 后面，并在之后重跑一次"补齐接管点"。
/// - **镜像靠后**：`MirrorConfigurator.apply` 要写 `foa-env.sh` 里的
///   Flutter/Android 路径变量，得等 SDK 都就位。
/// - **原生后端最后，且是唯一的可选步**（见 [BootstrapStep.isOptional]）：
///   它要把 Android SDK build-tools 里的 aapt2 / aidl / zipalign /
///   split-select 换成 arm64 原生版，所以必须在 androidSdk 之后；而它对
///   主链没有依赖，放在最后才不会挡住"必须先装好"的那一堆。
///
/// ## 原生后端与 QEMU 不是互斥的（别把它做成二选一）
///
/// 两者都在解决"官方只发 x86_64 二进制"这同一件事，但覆盖的**不是同一批
/// 文件**，所以是叠加而非替代：
///
/// | 二进制 | QEMU 兼容层 | 原生后端 |
/// | --- | --- | --- |
/// | aapt2 / aidl / zipalign / split-select | 转发脚本 | **换成真 arm64**（更快的那个生效） |
/// | dart / gen_snapshot / impellerc | 转发脚本 | 管不了（gen_snapshot 无公开 arm64 分发） |
///
/// 落位脚本也刻意做成了互不踩：QEMU 把原件备份成 `.foa-real`，
/// 原生后端备份成 `.foa-x64`（见 `native_arm64.dart` 的 `_deployScript`）。
/// 所以先装 QEMU 再装原生是安全的 —— 前四个走原生、其余仍靠 QEMU。
/// 反过来（先原生后补 QEMU）也安全：`sdkWrapScript` 会跳过非 x86-64 的
/// 文件（机器码判定），不会把已经原生化的 aapt2 再套一层转发。
library;

import 'package:flutter/foundation.dart';

import '../env/env_installer.dart';
import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'jdk_installer.dart';
import 'native_arm64.dart';
import 'qemu_compat.dart';
import 'sdk_downloader.dart';
import 'sdk_installer.dart'; // AndroidSdkInstaller / FlutterSdkInstaller / MirrorConfigurator

// ==================== 步骤定义 ====================

/// 一键安装的全套步骤，**声明顺序即执行顺序**。
///
/// 单测守着这个顺序（`test/onboarding_test.dart`）：rootfs 必须第一、
/// QEMU 必须在两个 SDK 之后、原生后端必须最后。改顺序会编译通过、测试
/// 也可能照过，但真机上会以"某某目录不存在"的形式失败 —— 所以钉住。
enum BootstrapStep {
  rootfs,
  jdk,
  androidSdk,
  flutterSdk,
  qemu,
  mirror,
  native;

  /// 给用户看的名字。
  String get label => switch (this) {
        BootstrapStep.rootfs => '容器环境（Debian rootfs）',
        BootstrapStep.jdk => 'JDK 17',
        BootstrapStep.androidSdk => 'Android SDK',
        BootstrapStep.flutterSdk => 'Flutter SDK',
        BootstrapStep.qemu => 'x64 兼容层（QEMU）',
        BootstrapStep.mirror => '构建镜像配置',
        BootstrapStep.native => '原生 arm64 后端（可选加速）',
      };

  /// 这一步是不是"可装可不装"的。
  ///
  /// 只有原生后端是。它与 [BootstrapStep.qemu] 不是替代关系（见文件头
  /// 那张表），装不上**不影响构建能不能跑** —— 只是 aapt2 那几个二进制
  /// 继续走 QEMU 翻译，慢一点而已。
  ///
  /// 语义差别体现在失败处理上：必装步骤失败 → 整条链 `failed` 并停下；
  /// 可选步骤失败 → 记成 `skipped`（带上原因），**链条继续走完、整体仍算
  /// 成功**。这个区分不是洁癖：原生后端的产物在 GitHub Release 上，国内
  /// 直连经常抽风；若按硬失败处理，用户会在 1.5GB Flutter SDK 都装完之后
  /// 看到一个"安装中断"，而实际上工具链已经可以构建了。
  bool get isOptional => this == BootstrapStep.native;

  /// 预估下载体积（字节）。**只用于给进度条配权重**，不是精确值。
  ///
  /// 数量级对了就够 —— 目的是让进度条别骗人（见 [ToolchainBootstrap.overallFraction]）。
  /// rootfs 与 qemu / mirror 的"下载"发生在容器内 apt，拿不到准确的
  /// Content-Length，这里取实测经验值。
  int get approxBytes => switch (this) {
        // 内置资产，不下载。给一个非零值只是为了让它在加权里占一档。
        BootstrapStep.rootfs => 70 * 1024 * 1024,
        BootstrapStep.jdk => JdkInstaller.size,
        // 从组件表实时求和，别写死 —— 组件增删时写死的数字会静默过期，
        // 而它只影响进度条权重，没有任何东西会因为它错了而失败。
        BootstrapStep.androidSdk => AndroidSdkInstaller.components
            .fold<int>(0, (sum, c) => sum + c.size),
        BootstrapStep.flutterSdk => FlutterSdkInstaller.tarSize,
        BootstrapStep.qemu => 120 * 1024 * 1024, // apt 拉 qemu-user + 运行库
        BootstrapStep.mirror => 130 * 1024 * 1024, // Gradle all zip 预下载
        // tar 只有 3.2MB，但前面还要 apt 补 libstdc++6 / zlib1g
        // （minbase rootfs 不带），这部分拿不到 Content-Length，取经验值。
        BootstrapStep.native =>
          NativeBuildTools.tarSize + 20 * 1024 * 1024,
      };

  /// 一句话说明它是什么（引导页「要装什么」清单用）。
  String get usage => switch (this) {
        BootstrapStep.rootfs =>
          '解压应用内置的 Debian 容器，所有构建工具都装在里面',
        BootstrapStep.jdk => 'Gradle 编译 Android 侧代码需要的 Java 运行时',
        BootstrapStep.androidSdk =>
          'aapt2 / D8 / R8 等打包工具，把 Dart 产物封装成 APK',
        BootstrapStep.flutterSdk =>
          'Flutter 编译器和 Dart SDK，你写的代码靠它变成 APK',
        BootstrapStep.qemu =>
          '把 x86-64 的构建工具翻译到 arm64 执行（官方只发 x64 版）',
        BootstrapStep.mirror => '配置国内镜像并预下载 Gradle，避免构建时卡在拉依赖',
        BootstrapStep.native =>
          '把 aapt2 / aidl / zipalign / split-select 换成 arm64 原生版，'
              '少一层指令翻译（装不上不影响构建，只是慢一点）',
      };

  /// 体积的人话表示（引导页展示用）。
  String get sizeLabel {
    final mb = approxBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.round()} MB';
  }
}

/// 单步的执行状态。
enum BootstrapStatus { idle, running, done, failed, skipped }

/// 一个步骤的完整快照。**不可变** —— 每次变化产生新实例，配合
/// [ChangeNotifier] 让 UI 的比较逻辑简单（引用变了就是变了）。
@immutable
class BootstrapStepState {
  final BootstrapStep step;
  final BootstrapStatus status;

  /// installer 通过 `onPhase` 报的子阶段（`probing` / `downloading` /
  /// `extracting` / `apt` …）。给用户看"现在具体在干什么"。
  final String phase;

  /// 下载进度。非下载阶段为 null。
  final DownloadProgress? progress;

  /// 完成后的版本描述（`verify()` 或 `install()` 的返回值）。
  final String? result;

  /// 失败原因（人话）。只有 [BootstrapStatus.failed] 时非空。
  final String? error;

  const BootstrapStepState({
    required this.step,
    this.status = BootstrapStatus.idle,
    this.phase = '',
    this.progress,
    this.result,
    this.error,
  });

  BootstrapStepState copyWith({
    BootstrapStatus? status,
    String? phase,
    DownloadProgress? progress,
    String? result,
    String? error,
  }) {
    return BootstrapStepState(
      step: step,
      status: status ?? this.status,
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      result: result ?? this.result,
      error: error ?? this.error,
    );
  }

  bool get isDone => status == BootstrapStatus.done;
  bool get isFailed => status == BootstrapStatus.failed;

  /// 这一行给用户看的一句话状态。
  String get detail {
    return switch (status) {
      BootstrapStatus.idle => '待安装 · ${step.sizeLabel}',
      BootstrapStatus.running => phase.isEmpty ? '正在处理…' : _phaseLabel(phase),
      BootstrapStatus.done => result == null || result!.isEmpty ? '已完成' : result!,
      BootstrapStatus.failed => error ?? '失败',
      BootstrapStatus.skipped => switch (error) {
          null => '已跳过',
          // 可选步骤尝试过但没装上：这里必须说"未装上"而不是"已跳过"
          // —— 后者会让用户以为是程序主动跳过的（"那我怎么开启？"），
          // 而真相是"试了、失败了、但不影响你构建"。
          final e when step.isOptional => '未装上（可选）：$e',
          final e => '已跳过：$e',
        },
    };
  }

  /// 把 installer 的内部 phase 串翻译成人话。
  ///
  /// 这些串是各 installer 自己 call 出来的（`onPhase?.call('downloading')`
  /// 之类），值集合不固定。**兜底是原样显示而不是"未知"** ——
  /// 显示一个陌生的英文词，好过让用户以为界面坏了。
  static String _phaseLabel(String phase) {
    return switch (phase) {
      'probing' => '正在挑选最快的镜像…',
      'downloading' => '下载中…',
      'extracting' => '解压中…',
      'verify' || 'verifying' => '校验中…',
      'apt' => '安装系统依赖…',
      'env' => '写入环境变量…',
      'init' || 'gradle' => '配置 Gradle…',
      'flutter' => '配置 Flutter 路径…',
      // 原生后端（以及 QEMU 的引擎同步）会报这两个，落到 UI 上不能
      // 让用户看见裸的英文 —— 那看起来像界面坏了。
      'engine' => '同步 Flutter 引擎…',
      'deploying' => '落位到 SDK 并冒烟…',
      _ => phase,
    };
  }
}

// ==================== 编排控制器 ====================

/// 一次性安装完 6 个组件。
///
/// 用法：
/// ```dart
/// final b = ToolchainBootstrap();
/// b.addListener(() => setState(() {}));
/// await b.start();          // 跑到底（成功或失败）
/// ```
class ToolchainBootstrap extends ChangeNotifier {
  final ProotBridge bridge = ProotBridge();

  /// 从 [EnvState] 拿到的环境信息。[start] 之前必须由调用方塞进来
  /// （引导页从 Provider 里取），避免这里自己再调一次平台通道。
  EnvInfo? env;

  /// 6 步的状态，顺序同 [BootstrapStep.values]。
  List<BootstrapStepState> steps = BootstrapStep.values
      .map((s) => BootstrapStepState(step: s))
      .toList();

  bool _running = false;
  DownloadCancelToken? _token;
  BootstrapStep? _current;

  bool get isRunning => _running;

  /// 当前正在跑的步骤。
  BootstrapStep? get current => _current;

  /// 有没有步骤失败了（决定是否显示"重试"）。
  bool get hasFailure => steps.any((s) => s.isFailed);

  BootstrapStepState get _failedStep =>
      steps.firstWhere((s) => s.isFailed,
          orElse: () => const BootstrapStepState(step: BootstrapStep.rootfs));

  /// 失败的那一步（给「重试」按钮用）。
  BootstrapStep? get failedStep => hasFailure ? _failedStep.step : null;

  /// 全部装完了吗。
  bool get isAllDone =>
      steps.every((s) => s.isDone || s.status == BootstrapStatus.skipped);

  /// 加权总进度 0.0–1.0。
  ///
  /// ## 为什么不能取平均
  ///
  /// Flutter SDK 是 1.5GB，JDK 是 190MB。6 步各占 1/6 的话，装完 JDK 时
  /// 进度条已经走到 16%，而实际字节数才下了 10% —— 后面 3 个"大块头"
  /// 会挤在最后 50% 里慢慢爬。**进度条骗人比没有进度条更糟**：
  /// 用户会以为卡住了。
  ///
  /// 所以按 [BootstrapStep.approxBytes] 加权，并且**进行中的那一步
  /// 用它自己的 `progress.fraction` 细分**，让大文件下载期间进度条是活的。
  double get overallFraction {
    final totalBytes = BootstrapStep.values
        .fold<int>(0, (sum, s) => sum + s.approxBytes);
    if (totalBytes == 0) return 0;

    var done = 0.0;
    for (final st in steps) {
      switch (st.status) {
        case BootstrapStatus.done:
        case BootstrapStatus.skipped:
          done += st.step.approxBytes;
        case BootstrapStatus.running:
          // 细粒度：这一档内部再按下载比例切
          done += st.step.approxBytes * (st.progress?.fraction ?? 0.0);
        case BootstrapStatus.idle:
        case BootstrapStatus.failed:
          break;
      }
    }
    return (done / totalBytes).clamp(0.0, 1.0);
  }

  /// 总进度的人类可读百分比。
  int get overallPercent => (overallFraction * 100).round();

  /// 一句话总状态，直接显示在顶部。
  String get summary {
    if (_running) {
      final cur = _current;
      if (cur == null) return '准备中…';
      final i = steps.indexWhere((s) => s.step == cur) + 1;
      final st = steps.firstWhere((s) => s.step == cur);
      // 带上下标让用户知道"还剩几步"，不然一条进度条看不出终点
      return '（$i/${steps.length}）${cur.label}：${st.detail}';
    }
    if (hasFailure) return '安装中断：${_failedStep.step.label} 失败';
    if (isAllDone) {
      // 可选步骤没装上不该伪装成"一切完美"——用户会以为原生后端也在跑。
      // 但也不要用"失败"这个词（链条没失败），说清可去哪里补。
      final soft = _stateOf(BootstrapStep.native);
      if (soft.status == BootstrapStatus.skipped && soft.error != null) {
        return '工具链已就绪（原生后端没装上，不影响构建 —— '
            '可在「工具链」页手动启用）';
      }
      return '全部就绪，可以开始构建了';
    }
    return '准备安装工具链';
  }

  void _set(BootstrapStep step, BootstrapStepState next) {
    final i = steps.indexWhere((s) => s.step == step);
    if (i < 0) return;
    steps = List<BootstrapStepState>.from(steps)..[i] = next;
    notifyListeners();
  }

  BootstrapStepState _stateOf(BootstrapStep step) =>
      steps.firstWhere((s) => s.step == step);

  /// 开始全自动安装。
  ///
  /// [env] 必须已设置（[EnvInfo]）。重复调用时若已在跑，直接返回。
  ///
  /// ## 中断语义
  ///
  /// 任何一步失败 → **立刻停，不继续下一步，也不自动重试**。
  /// 已装好的步骤状态保留 —— 用户点「重试」时只重跑失败那一步，
  /// 不会把已经下好的 1.5GB Flutter SDK 再下一遍。
  Future<void> start() async {
    if (_running) return;
    final e = env;
    if (e == null) {
      _set(BootstrapStep.rootfs,
          _stateOf(BootstrapStep.rootfs).copyWith(
        status: BootstrapStatus.failed,
        error: '环境信息还没拿到（EnvState 未就绪），请稍后重试',
      ));
      return;
    }

    _running = true;
    _token = DownloadCancelToken();
    notifyListeners();

    try {
      for (final step in BootstrapStep.values) {
        if (_token!.isCancelled) break;
        final ok = await _runStep(step, e);
        if (!ok) break; // 失败即停，不往下走
      }
    } finally {
      _running = false;
      _current = null;
      notifyListeners();
    }
  }

  /// 只重跑失败的那一步（以及它之后的）。
  ///
  /// 不从头来：失败的常见原因是网络，而前面几步的产物还在磁盘上，
  /// 重下几百 MB 是不可接受的。
  Future<void> retry() async {
    final from = failedStep;
    if (from == null || _running) return;
    // 把失败那步之后的步骤状态清回 idle —— 它们还没跑过，
    // 留着上一次的残留状态会让 UI 显示得莫名其妙。
    for (final step in BootstrapStep.values) {
      if (step.index < from.index) continue;
      _set(step, BootstrapStepState(step: step));
    }
    final e = env;
    if (e == null) return;

    _running = true;
    _token = DownloadCancelToken();
    notifyListeners();
    try {
      for (final step in BootstrapStep.values) {
        if (step.index < from.index) continue;
        if (_token!.isCancelled) break;
        final ok = await _runStep(step, e);
        if (!ok) break;
      }
    } finally {
      _running = false;
      _current = null;
      notifyListeners();
    }
  }

  /// 取消。**不杀在跑的下载**（部分 installer 的 token 在解压阶段无效），
  /// 只保证不再进入下一步。
  void cancel() {
    _token?.cancel();
    _running = false;
    _current = null;
    notifyListeners();
  }

  /// 跑一步。返回是否成功继续。
  Future<bool> _runStep(BootstrapStep step, EnvInfo e) async {
    _current = step;
    _set(step, _stateOf(step).copyWith(
      status: BootstrapStatus.running,
      phase: '',
    ));

    try {
      // ---- 快路径：已经装好了就跳过 ----
      //
      // 这不是优化，是**必须**：用户可能上次装到一半退了、或者手动在
      // 工具链页装过几个。每步先 verify，才不会把已经下好的东西再下一遍。
      //
      // ⚠️ 不能反过来（先装再看）—— 那正是我们要避免的。
      final already = await _verify(step, e);
      if (already != null) {
        _set(step, _stateOf(step).copyWith(
          status: BootstrapStatus.done,
          result: '已装：$already',
        ));
        return true;
      }

      final result = await _install(step, e);
      _set(step, _stateOf(step).copyWith(
        status: BootstrapStatus.done,
        result: result.isEmpty ? '已完成' : result,
      ));
      return true;
    } on DownloadException catch (err) {
      // 下载器自己的文案最准（它知道是网络、校验失败还是磁盘满）
      return _fail(step, err.message);
    } catch (err) {
      return _fail(step, _humanize(err));
    }
  }

  /// 记一步失败。**可选步骤降级为 skipped 并继续走**。
  ///
  /// 为什么不统一 failed：见 [BootstrapStep.isOptional] 那段注释。
  /// 一句话概括 —— 已经装完 1.5GB 的东西之后，因为一个"装不上也能用"
  /// 的加速项而把整条链判成失败，是最糟的那类误导。
  bool _fail(BootstrapStep step, String message) {
    final soft = step.isOptional;
    _set(step, _stateOf(step).copyWith(
      status: soft ? BootstrapStatus.skipped : BootstrapStatus.failed,
      error: message,
    ));
    return soft; // 可选步骤返回 true = 链条继续
  }

  /// 探测某步是否已完成。返回版本描述或 null。
  ///
  /// 各 installer 的 verify 契约统一：**返回非 null = 已装**。
  Future<String?> _verify(BootstrapStep step, EnvInfo e) async {
    switch (step) {
      // rootfs 没有独立的 Installer.verify —— 真相在 EnvInfo 里
      case BootstrapStep.rootfs:
        return e.rootfsInstalled ? '容器已就绪' : null;
      case BootstrapStep.jdk:
        return JdkInstaller.verify(bridge);
      case BootstrapStep.androidSdk:
        return AndroidSdkInstaller.verify(bridge);
      case BootstrapStep.flutterSdk:
        return FlutterSdkInstaller.verify(bridge);
      case BootstrapStep.qemu:
        return QemuCompat.verify(bridge);
      case BootstrapStep.mirror:
        return MirrorConfigurator.verify(bridge, e);
      case BootstrapStep.native:
        // ⚠️ 注意是 `NativeArm64.verify`（看 /opt/foa-native 里有几个
        // aarch64 产物），**不是** NativeBuildTools.verify —— 后者不存在。
        // 装完 4 个 build-tools 后它返回 "原生产物 4 项（aarch64）"。
        return NativeArm64.verify(bridge);
    }
  }

  /// 真正执行安装。
  Future<String> _install(BootstrapStep step, EnvInfo e) async {
    void onPhase(String p) => _set(step, _stateOf(step).copyWith(phase: p));
    void onProgress(DownloadProgress p) =>
        _set(step, _stateOf(step).copyWith(progress: p));

    switch (step) {
      case BootstrapStep.rootfs:
        // rootfs 走 EnvState（它负责解压内置 tar + 重新 bootstrap）。
        // 这里用一个临时实例，不碰全局那个 —— 全局 EnvState 的状态刷新
        // 由调用方在整轮结束后自己 refresh()。
        final s = EnvState()..info = e;
        final ok = await s.installRootfs();
        if (!ok) {
          throw DownloadException(s.error ?? '解压容器失败');
        }
        return s.installLog;

      case BootstrapStep.jdk:
        return JdkInstaller.install(bridge, e,
            token: _token, onPhase: onPhase, onProgress: onProgress,
            onMirrorUsed: (_) {});

      case BootstrapStep.androidSdk:
        return AndroidSdkInstaller.install(bridge, e,
            token: _token, onPhase: onPhase, onProgress: onProgress,
            onMirrorUsed: (_) {});

      case BootstrapStep.flutterSdk:
        return FlutterSdkInstaller.install(bridge, e,
            token: _token, onPhase: onPhase, onProgress: onProgress,
            onMirrorUsed: (_) {});

      case BootstrapStep.qemu:
        final r = await QemuCompat.apply(bridge, e,
            token: _token, onPhase: onPhase, onProgress: onProgress,
            onMirrorUsed: (_) {});
        // QEMU 是**接管**而非新增目录：SDK 刚装好时它的接管点可能还没补全，
        // 这里立刻补一次。两个方法内部都自带"没装就跳过"，安全。
        await QemuCompat.syncEngineIfReady(bridge);
        await QemuCompat.wrapSdkIfReady(bridge, e);
        return r;

      case BootstrapStep.mirror:
        return MirrorConfigurator.apply(bridge, e,
            token: _token, onPhase: onPhase, onProgress: onProgress,
            onMirrorUsed: (_) {});

      case BootstrapStep.native:
        // 不再额外调 writeAapt2Override —— install() 内部已经写了同一条
        // `android.aapt2FromMavenOverride`（与 QEMU 后端写的是同一个值、
        // 同一个文件），重复写只是多一次文件 IO。
        return NativeBuildTools.install(bridge, e,
            token: _token, onPhase: onPhase, onProgress: onProgress,
            onMirrorUsed: (_) {});
    }
  }

  /// 把异常翻成用户能看懂的一句话。
  ///
  /// 直接把 `$e` 甩给用户是很糟的体验 —— 常见的是
  /// `Exception: PlatformException(...)` 这种只有开发者看得懂的东西。
  /// 这里只挑几种**用户能采取行动**的情况做翻译，其余原样带上
  /// （至少保留了排查线索，比换成"未知错误"强）。
  static String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('Connection')) {
      return '网络连接失败，检查网络后重试';
    }
    if (s.contains('No space left')) {
      return '设备存储空间不足，清理后重试';
    }
    if (s.contains('SocketTimeout') || s.contains('timeout')) {
      return '连接超时，可能是镜像不可达，稍后重试';
    }
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}
