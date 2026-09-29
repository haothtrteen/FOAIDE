/// 构建进度解析（纯逻辑，无 Flutter 依赖，可单测）。
///
/// 设计前提：`flutter build apk` 不会输出百分比，只有一个没有终点的
/// 纺锤动画和偶发 `Running Gradle task 'assembleRelease'...`。所以进度条
/// 不能靠"读到某个数"，只能靠**阶段映射 + 阶段内插值**：
///
/// 1. 用已知的阶段关键词把整条流水线切成若干段（阶段识别，单调不回退）；
/// 2. 阶段内部按时间缓慢爬升到该阶段上限的 ~92%，**永不封顶**——
///    这样"看起来还在动"才是真的在动，而不是假的匀速条；
/// 3. 只有真正命中 `BUILD SUCCESS` / 退出码 0 才允许到 100%。
///
/// 阶段权重来自实测：arm64 上 gradle 配置 + aapt2 资源编译（走 qemu）
/// 占了大头，dart kernel 编译很快，AOT（gen_snapshot）中等。
library;

import 'dart:math' as math;

/// 构建阶段。顺序即推进顺序，下标越大越靠后。
class BuildStage {
  /// 阶段显示名（进度条下方展示）。
  final String label;

  /// 该阶段起点的进度（0..1）。
  final double start;

  /// 该阶段终点上限（0..1），到达后停在此值等待下一阶段。
  final double end;

  const BuildStage(this.label, this.start, this.end);

  @override
  String toString() => '$label($start~$end)';
}

/// 全部阶段定义。
class BuildStages {
  /// 未识别到任何关键词时的兜底阶段。
  static const BuildStage bootstrap = BuildStage('准备构建环境', 0.00, 0.04);

  static const BuildStage resolveDeps = BuildStage('解析依赖', 0.04, 0.14);
  static const BuildStage configGradle = BuildStage('配置 Gradle', 0.14, 0.26);
  static const BuildStage compileKernel = BuildStage('编译 Dart 内核', 0.26, 0.40);
  static const BuildStage aot = BuildStage('AOT 编译（gen_snapshot）', 0.40, 0.58);
  static const BuildStage resources = BuildStage('编译资源（aapt2）', 0.58, 0.72);
  static const BuildStage dex = BuildStage('编译 Kotlin / dex（R8）', 0.72, 0.86);
  static const BuildStage packageApk = BuildStage('打包与签名 APK', 0.86, 0.96);
  static const BuildStage locateApk = BuildStage('校验产物', 0.96, 0.99);

  /// 全部阶段（按推进顺序）。
  static const List<BuildStage> ordered = [
    bootstrap,
    resolveDeps,
    configGradle,
    compileKernel,
    aot,
    resources,
    dex,
    packageApk,
    locateApk,
  ];
}

/// 阶段识别规则：正则 → 阶段。**顺序敏感**，先匹配者胜。
///
/// 关键词全部取自真实构建日志（见 dev-handbook §八 服务端构建实录）。
final List<(RegExp, BuildStage)> _rules = [
  // ---- flutter 侧 ----
  (RegExp(r'Running Gradle task', caseSensitive: false),
      BuildStages.configGradle),
  (RegExp(r'Resolving dependencies|Downloading packages|Got dependencies',
          caseSensitive: false),
      BuildStages.resolveDeps),
  (RegExp(r'Target kernel_snapshot|Compiling Dart to kernel', caseSensitive: false),
      BuildStages.compileKernel),
  (RegExp(r'Target android_aot|gen_snapshot|Running AOT', caseSensitive: false),
      BuildStages.aot),
  // ---- gradle / agp 侧 ----
  (RegExp(r'> Task .*compileFlutterBuild', caseSensitive: false),
      BuildStages.compileKernel),
  // ⚠️ alpha.93：下面几条**必须同时匹配 Release 与 Debug 变体**。
  //   原先只写了 `mergeReleaseResources` / `compileReleaseKotlin` /
  //   `packageRelease` / `assembleRelease`，而 debug 构建产出的是
  //   `mergeDebugResources` / `compileDebugKotlin` / `assembleDebug`——
  //   一条都匹配不上，进度会从「编译 Dart 内核」(40%) 一路卡死到构建结束
  //   才突然 100%，看起来就像卡住。这是加 debug 档时最容易漏的地方。
  (RegExp(r'> Task .*(merge(?:Release|Debug)Resources'
          r'|process(?:Release|Debug)Resources)',
          caseSensitive: false),
      BuildStages.resources),
  (RegExp(r'> Task .*(compile(?:Release|Debug)Kotlin'
          r'|compile(?:Release|Debug)JavaWithJavac|'
          r'dexBuilder|dexing|minify(?:Release|Debug)WithR8|shrink)',
          caseSensitive: false),
      BuildStages.dex),
  (RegExp(r'> Task .*(package(?:Release|Debug)|assemble(?:Release|Debug)'
          r'|signingConfigWriter|validateSigning)',
          caseSensitive: false),
      BuildStages.packageApk),
  (RegExp(r'Built build/app/outputs|BUILD SUCCESS', caseSensitive: false),
      BuildStages.packageApk),
];

/// 构建进度追踪器：吃日志行，吐进度值。
///
/// ```dart
/// final t = BuildProgressTracker();
/// t.feed(line);   // 每来一行日志喂一次
/// t.tick();       // 每次 UI 刷新（~500ms）调一次，做阶段内插值
/// t.progress;     // 0..1
/// ```
class BuildProgressTracker {
  /// 已识别的最高阶段下标（单调不回退——日志乱序/重放不会让进度倒退）。
  int _rank = 0;

  /// 进入当前阶段的时间，用于阶段内插值。
  DateTime _stageEnteredAt = DateTime.now();

  /// 阶段内已完成的插值量（0..0.92）。
  double _intraStage = 0.0;

  /// 是否已完成（只有显式 [markDone] 才为真）。
  bool _done = false;

  /// 是否冻结（失败/取消后不再爬升，避免骗用户"还在动"）。
  bool _halted = false;

  /// alpha.93：debug 档跳过 AOT 段。
  ///
  /// debug 构建不走 gen_snapshot，[BuildStages.aot] 那一段（40%~58%）
  /// 永远不会到达。若不处理，进度会从 40% 直接跳到 58%——不算致命，
  /// 但用户能看到明显的跳变。置为 true 时会把 [aotEnd, 1.0] **拉伸**到
  /// [aotStart, 1.0]，进度条保持连续。
  ///
  /// 由 BuildRunner.start(flavor:) 在构建开始前设置，reset() 不重置它
  /// （它是"这次构建是什么类型"的属性，不是进度状态）。
  bool skipAot = false;

  /// 当前阶段。
  BuildStage get stage => BuildStages.ordered[_rank];

  bool get isDone => _done;

  /// 当前进度 0..1。
  double get progress {
    if (_done) return 1.0;
    final s = stage;
    final p = (s.start + (s.end - s.start) * _intraStage).clamp(0.0, 1.0);
    if (!skipAot) return p;
    // debug 档：把 AOT 段（[aot.end, 1.0]）拉伸到 [aot.start, 1.0]，
    // 消掉那 18% 的空档，让进度条连续。
    const a = BuildStages.aot;
    if (p <= a.start) return p;
    final t = (p - a.end) / (1.0 - a.end);
    return (a.start + (1.0 - a.start) * t.clamp(0.0, 1.0)).clamp(0.0, 1.0);
  }

  /// 显示用百分比整数。
  int get percent => (progress * 100).clamp(0, 100).round();

  /// 喂一行日志（已清洗 ANSI / `\r` 的纯文本行）。
  void feed(String line) {
    if (line.trim().isEmpty) return;
    for (final (pattern, target) in _rules) {
      if (pattern.hasMatch(line)) {
        _advanceTo(target);
        return;
      }
    }
  }

  /// 推进到指定阶段（只前进，不后退）。
  void _advanceTo(BuildStage target) {
    // debug 档下 AOT 段不该出现（不走 gen_snapshot）。万一日志里真冒出来
    // （比如 flutter 改版），也别停在一段永不推进的空档上——直接落到
    // 它后面的「编译资源」。
    if (skipAot && target == BuildStages.aot) {
      _advanceTo(BuildStages.resources);
      return;
    }
    final idx = BuildStages.ordered.indexOf(target);
    if (idx <= _rank) return;
    _rank = idx;
    _intraStage = 0.0;
    _stageEnteredAt = DateTime.now();
  }

  /// 时间插值：进入阶段越久，越靠近该阶段上限（渐近，永不封顶）。
  ///
  /// 用 `1 - exp(-t/τ)` 而非线性，是因为长任务实际耗时无法预知：
  /// 线性插值一旦预估偏短就会顶到上限然后"僵住"——又变成用户以为卡死。
  /// 指数渐近则永远在动，越接近上限越慢，视觉上更接近真实进度。
  void tick() {
    if (_done || _halted) return;
    final elapsed = DateTime.now().difference(_stageEnteredAt).inMilliseconds;
    if (elapsed <= 0) return;
    // τ = 12s：约 12s 走完 63%，36s 走完 95%。
    const tauMs = 12000.0;
    final target = 1.0 - math.exp(-elapsed / tauMs);
    // 封顶 0.92：留余量，避免阶段内顶到 end 后卡住看起来像死机
    _intraStage = target.clamp(0.0, 0.92);
  }

  /// 明确标记完成（构建成功 + 找到产物）。
  void markDone() {
    _done = true;
    _halted = false;
    _rank = BuildStages.ordered.length - 1;
    _intraStage = 1.0;
  }

  /// 冻结进度（失败或取消）。
  void markHalted() => _halted = true;

  /// 重置。
  void reset() {
    _rank = 0;
    _intraStage = 0.0;
    _stageEnteredAt = DateTime.now();
    _done = false;
    _halted = false;
  }
}
