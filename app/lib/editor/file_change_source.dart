import 'dart:async';

import 'fs_bridge.dart';

/// 磁盘变更来源的抽象（alpha.91）。
///
/// ## 为什么要有这层
///
/// alpha.83 起只有一种实现：`AiFileWatcher` 每 2.5s 轮询一次。它有两个
/// 固有缺点，当时是接受的：
///
///   1. **有延迟**——最快也要一个轮询周期才看得到；
///   2. **只报一次就自停**（`ai_file_watch.dart:108-112`）——因为当时的
///      设计目标是"派活后告诉你 AI 动了"，报过一次使命就完成了。
///
/// alpha.91 要把它变成**常驻的双向同步**（外部改 → 编辑器实时跟上），
/// 这两条就都变成缺陷了：
///
///   - 每次都要等 2.5s 才刷新，用户会以为功能没生效；
///   - **只报第一次**，外部 AI 连改三轮就只感知得到第一轮。
///
/// 所以本轮加一条原生监听路径（Kotlin `FileObserver` → MethodChannel），
/// 轮询降级为**兜底**（旧 APK、原生监听不可用时接手）。两条路径语义不同
/// （推送 vs 拉取），但调用方只关心"磁盘变了告诉我"，于是抽这个接口把
/// 差异挡在后面。
///
/// ## 契约（两条实现都必须满足）
///
/// - **[start] 是幂等的"换目标"**：重复调用等于"停掉旧的、盯新的"，
///   不许出现两个来源同时盯着不同文件。
/// - **常驻不自停**：直到调用方 [stop] 为止，每一次外部变更都要报。
///   这与 [AiFileWatcher] 的"报一次就停"**刻意相反**。
/// - **[onChanged] 只给路径，不给内容**。
///
/// ### 为什么只给路径
///
/// 推送型实现（FileObserver）拿到事件时文件**可能正被写一半**
/// （编辑器保存常见"截断 + 分多次 write"）。如果原生侧顺手把内容读出来
/// 一起推，Dart 侧就会拿到半截内容，然后拿它去覆盖编辑器——**丢代码**。
///
/// 所以约定：来源只负责"哪个文件动了"，**内容由订阅者自己去读**，
/// 且订阅者有权做防抖/去重/内容比对。读的时机由订阅者掌握，它才知道
/// 此刻是否适合读（比如正在弹 diff 时不该读）。
///
/// 附带好处：原生侧不用管大文件、不用管编码、不用管读取失败，
/// 事件载荷永远只有 {path, seq}。
///
/// ## 与 [AiFileWatcher] 的关系
///
/// `AiFileWatcher` **原样保留、不删不改**（用户已确认）。它带着 13 条
/// alpha.84 回归测试，是历史资产；同时它的"报一次就停 + 内容一起给"
/// 的语义与之并不冲突——本轮新增的 [PollingFileChangeSource] 是**另一个
/// 类**，专门实现上面的常驻契约，不复用 AiFileWatcher。
abstract class FileChangeSource {
  /// 开始监听 [path]（容器内路径）。
  ///
  /// 返回 `false` 表示**这条来源无法工作**，调用方应当降级到别的实现。
  /// 返回 `true` 才算接管成功。
  ///
  /// 为什么用返回值而不是抛异常：降级是**预期路径**而非异常路径
  /// （旧 APK 没有原生监听、目录不存在、权限不足都属正常情况），
  /// 用返回值表达更直白，也不会在日志里刷一堆红。
  Future<bool> start(String path);

  /// 停止监听。幂等——重复调用、没 start 就调，都不该出错。
  void stop();

  /// 是否正在监听。
  bool get active;

  /// 检测到外部变更时回调，**参数只有路径**（理由见类注释）。
  ///
  /// 实现方必须保证：**在 [stop] 之后不再触发**（页面已销毁时回调会炸）。
  set onChanged(void Function(String path)? cb);

  /// 把基线推进到 [content]。
  ///
  /// 用途：**自己刚保存了文件**时调用。否则下一轮读盘会看到
  /// `磁盘 ≠ 基线`，把"自己写的"误报成"外部改的"——表现就是用户
  /// 每次保存都给自己弹一个 diff 预览，非常荒唐。
  ///
  /// 轮询型实现用它直接改写基线字符串；推送型实现用它丢弃"刚刚那次
  /// 还在路上的自写事件"。
  void bumpBaseline(String content);
}

/// 轮询型实现（alpha.91）：**持续轮询，不自停**。
///
/// 与 [AiFileWatcher] 的关键差别只有一个，但影响很大：
///
/// | | AiFileWatcher | PollingFileChangeSource |
/// |---|---|---|
/// | 报了几次 | 1 次然后自停 | 每次变更都报 |
/// | 回调给什么 | 磁盘新内容 | 只有路径 |
/// | 用途 | 派活后一次性提示 | 常驻同步 / 原生监听的兜底 |
///
/// 因为"基线 = 磁盘自己的上一版"这条核心语义在 alpha.84 已经踩过坑
/// （拿编辑器内容当基线 → 用户有未保存改动就首轮误报 → 自停 → 真改动
/// 永远收不到），这里**完整继承**那条结论，见 [start]。
class PollingFileChangeSource implements FileChangeSource {
  PollingFileChangeSource({
    FsBridge? bridge,
    this.interval = const Duration(milliseconds: 2500),
  }) : _bridge = bridge ?? FsBridge();

  final FsBridge _bridge;

  /// 轮询间隔。默认沿用 [AiFileWatcher] 的 2.5s——作为兜底路径没必要更勤，
  /// 而且它只在原生监听不可用时才会跑。
  final Duration interval;

  void Function(String path)? _onChanged;

  Timer? _timer;
  String _path = '';
  String _baseline = '';

  /// 磁盘内容是否已知。
  ///
  /// 读失败时置 false —— 此时**不能把空串当基线**，否则下一轮读到真实
  /// 内容会被当成"外部变更"误报（alpha.84 的教训，见 [AiFileWatcher]）。
  bool _baselineKnown = false;
  bool _starting = false;

  /// 是否在监听中。
  @override
  bool get active => _timer != null;

  @override
  set onChanged(void Function(String path)? cb) => _onChanged = cb;

  /// 见 [FileChangeSource.bumpBaseline]。
  @override
  void bumpBaseline(String content) {
    _baseline = content;
    _baselineKnown = true;
  }

  /// 返回 `false` 表示"没有可信基线，无法监听"。
  ///
  /// 宁可返回 false 让调用方去降级，也不要带着假基线启动——那样第一轮
  /// 必然误报，而误报的代价是把真改动盖过去。
  @override
  Future<bool> start(String path) async {
    if (_starting) return active; // 连点两次时只认第一次，避免两个 start 赛跑
    _starting = true;
    try {
      stop();
      _path = path;
      final r = await _bridge.read(path);
      if (!r.ok) {
        _baseline = '';
        _baselineKnown = false;
        return false;
      }
      _baseline = r.content;
      _baselineKnown = true;
      _timer = Timer.periodic(interval, (_) => _poll());
      return true;
    } finally {
      _starting = false;
    }
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_timer == null || !_baselineKnown) return;
    final r = await _bridge.read(_path);
    // 读盘期间可能已被 stop（换文件 / 退出页面）
    if (_timer == null || !_baselineKnown) return;
    // 单次读失败不算变更：保存常见"写 tmp + rename"，中间态读不到很正常
    if (!r.ok) return;
    if (r.content == _baseline) return;
    // ⚠️ 基线**立刻**推进到刚读到的内容，再去回调。顺序反了的话：
    // 回调里如果触发了读盘失败/异常，基线会停在旧值，下一轮把同一版
    // 再报一次；而"每次保存给自己弹一次 diff"就是这么来的。
    _baseline = r.content;
    // 且**不自停**——这是与 AiFileWatcher 的核心差别。
    _onChanged?.call(_path);
  }

  /// 测试辅助：不等 [interval] 立即轮一次。
  ///
  /// `@visibleForTesting` 的语义是"只许测试用"，但它**不跨文件失效**——
  /// `native_file_change_source.dart` 里也要转调它（把降级轮的
  /// `debugPollNow` 透出去），那个文件属于同一个库内的邻近模块而非测试，
  /// 所以这里不加注解，改由本类的使用约定约束：生产代码不要调它。
  Future<void> pollNow() => _poll();
}
