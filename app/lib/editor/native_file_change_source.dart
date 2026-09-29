import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../events/native_events.dart';
import 'file_change_source.dart';
import 'fs_bridge.dart';

/// 原生 `FileObserver` 驱动的变更来源（alpha.91），**自动降级到轮询**。
///
/// ## 为什么要有这条路径
///
/// 纯轮询有两个固有缺点（见 [PollingFileChangeSource] 的注释）：延迟至少
/// 一个周期，且要一直跑着 Timer。原生 `FileObserver` 是内核 inotify 之上
/// 的封装，真事件驱动——延迟约等于防抖时长（250ms），不产生任何轮询开销。
/// 对"外部 AI 改文件 → 编辑器实时跟上"这个体验来说，差别是能感觉到的。
///
/// ## 为什么要保留降级
///
/// 原生监听**一定会失败**的场合：
///
///   1. **用户装的是旧 APK**（有 `fsWatchStart` 之前的版本）。此时
///      `invokeMethod` 会抛 `MissingPluginException`——注意是抛异常，
///      不是返回 false。这是最容易漏的一条。
///   2. 路径非法（不在 `/root/projects` 内）→ Kotlin 返回 false。
///   3. 目录不可读 / ROM 差异导致 `startWatching()` 抛异常 → 返回 false。
///   4. 目标文件的**父目录不存在**（比如项目刚建、lib 目录还没生成）。
///
/// 任何一条命中都必须能自动退回流。**降级是预期路径，不是异常路径**，
/// 所以全程不往上抛，只在返回值里表达。
///
/// ## 两条路径绝不双跑
///
/// 如果原生监听成功、轮询也在跑，同一个变更会触发两次回调 → 编辑器
/// 弹两次 diff（或者第二次读到内容已一致而静默，但那是碰运气）。
/// 所以这里用 [isNative] 明确记录当前由谁在负责，[start] 里保证互斥，
/// [stop] 里两条都停干净。
///
/// ## 一个诚实的边界：进程被冻结时的事件会丢
///
/// Android 在后台/息屏时可能冻结进程。冻结期间 inotify 事件虽然在内核
/// 队列里，但我们的 Dart 回调不会执行；进程被杀死后队列直接消失。
/// 所以**不承诺"后台也实时同步"**——[onResumed] 提供一次补读来兜底，
/// UI 上也应把这条边界讲清楚，而不是让用户以为"永远同步"。
class NativeFileChangeSource implements FileChangeSource {
  NativeFileChangeSource({
    MethodChannel? channel,
    FsBridge? bridge,
    this.fallbackInterval = const Duration(milliseconds: 2500),
  })  : _channel = channel ?? const MethodChannel('dev.foa/proot'),
        _fallbackBridge = bridge;

  /// 复用 `dev.foa/proot`——**不新增通道**。
  ///
  /// 新增通道意味着原生侧要再写一遍 handler、再维护一套命名，而本通
  /// 道已有反向调用先例（`navigate`）。α.91 还把反向分发统一收进了
  /// `NativeEvents`，新增反向方法只要登记就能用。
  final MethodChannel _channel;

  final FsBridge? _fallbackBridge;

  /// 降级时用的轮询间隔。
  final Duration fallbackInterval;

  void Function(String path)? _onChanged;

  /// 降级实现。只在 [isNative] 为 false 时存在。
  PollingFileChangeSource? _polling;

  String? _path;

  /// 当前是否真的由原生在监听。
  ///
  /// 对外可读（测试断言"降级确实发生了"用），也是"两条不双跑"的凭据。
  bool get isNative => _nativeActive;

  bool _nativeActive = false;

  @override
  bool get active => _nativeActive || (_polling?.active ?? false);

  @override
  set onChanged(void Function(String path)? cb) {
    _onChanged = cb;
    // 降级实现要跟着一起换，否则降级路径下回调丢失
    _polling?.onChanged = cb;
  }

  /// 启动：先试原生，失败就退轮询。**永远不抛异常**。
  @override
  Future<bool> start(String path) async {
    // 先停掉旧的（接口约定 `stop()` 是同步 void，不等返回值）。
    // 不停的话会留下前一个文件的监听：切文件后收到旧文件的事件、
    // 却拿去当当前文件的变更处理。
    stop();
    _path = path;

    if (await _tryStartNative(path)) {
      _nativeActive = true;
      return true;
    }

    // 降级。特别注意：这里的返回值代表"有没有达成监听"，
    // 而**不是**"有没有用上原生" —— 降级成功也算成功，
    // 调用方不需要知道走的是哪条路（它只想知道"磁盘变化我会不会被通知"）。
    final p = PollingFileChangeSource(
      bridge: _fallbackBridge,
      interval: fallbackInterval,
    )..onChanged = _onChanged;
    _polling = p;
    return p.start(path);
  }

  /// 尝试原生监听。返回 false 表示"这条路径不可用，请降级"。
  Future<bool> _tryStartNative(String path) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'fsWatchStart',
        {'path': path},
      );
      if (ok != true) return false;
      // ⚠️ 关键接线：原生推来的事件经 `NativeEvents`（**全项目唯一**的
      // 反向 handler）分发。这里挂上静态回调，把它接到本实例的 onChanged。
      //
      // 为什么必须走 NativeEvents 而不是自己 setMethodCallHandler：
      // 同一通道只能有一个 handler，自己注册会把 navigate 静默顶掉
      // ——详见 `native_events.dart` 类注释与 `native_events_test.dart`
      // 里"全项目只许有一处"的源码扫描断言。
      NativeEvents.onFsChange = (p) => _onChanged?.call(p);
      return true;
    } on MissingPluginException {
      // 旧 APK / 非 Android 宿主（单元测试、桌面调试）没有这个方法。
      // 这是**最常走的一条降级路径**，不能当成错误往上冒。
      return false;
    } on PlatformException {
      // 原生侧返回 notImplemented / ERR_xxx
      return false;
    } catch (_) {
      // 兜底：任何意外都降级，绝不让监听失败变成编辑器打不开的原因
      return false;
    }
  }

  @override
  void stop() {
    if (_nativeActive) {
      // 摘掉回调，避免 stop 之后原生侧仍留着事件余波打到已销毁的页面
      NativeEvents.onFsChange = null;
      // 原生侧 fsWatchStop 是幂等的，但 dartChannel 可能在 Activity
      // 销毁途中失效 —— 异常吞掉，本地状态照清（否则"停不掉"会阻止
      // 后续 start）。
      _channel.invokeMethod('fsWatchStop').catchError((_) => null);
    }
    _nativeActive = false;

    _polling?.stop();
    _polling = null;
  }

  /// 自己刚保存 → 推进基线。
  ///
  /// 原生路径下**没有可推进的基线**（原生只报"文件动了"，不比对内容），
  /// 那怎么避免"自己保存触发一条 fsChange 然后自己弹自己的 diff"？
  ///
  /// 答案是：**交给上层按内容去重**。`EditorPage._onDiskChanged` 会先读盘
  /// 再跟 `_content` 比对，自己保存的场景下两者相等，直接 return。
  /// 这条设计的好处是原生侧不用维护基线（也就不会有"基线和真实文件不同步"
  /// 这类状态 bug），代价是每次自写事件要多读一次盘——单文件、偶发，
  /// 开销可以忽略。
  ///
  /// 降级路径下则真的推进轮询基线（那是它的必要机制）。
  @override
  void bumpBaseline(String content) {
    _polling?.bumpBaseline(content);
  }

  /// 前台恢复时补读一次（alpha.91，由 `EditorPage` 的
  /// `WidgetsBindingObserver.didChangeAppLifecycleState` 调用）。
  ///
  /// 为什么需要：进程被冻结/杀死的期间，原生推的事件我们收不到。
  /// 回到前台时"当前编辑器内容"很可能已经和磁盘不一致了，但没有任何
  /// 事件会来告诉我们——只能主动查一次。
  ///
  /// 语义上是**无条件触发一次变更检查**，由上层读盘后自行比对去重
  ///（内容一致就静默，所以补读不会产生假弹窗）。
  void onResumed() {
    final p = _path;
    if (p == null) return;
    if (!active) return;
    _onChanged?.call(p);
  }

  /// 测试辅助：立刻驱动一次降级轮询。
  ///
  /// 只在降级路径下有实际行为（原生路径没有轮询可驱动）——测试用它来
  /// 在不 `await` 真实 Timer 的情况下验证"降级之后轮询确实在干活"。
  @visibleForTesting
  Future<void> debugPollNow() async => _polling?.pollNow();
}
