import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../toolchain/build_notify.dart';

/// `dev.foa/proot` 通道上 **Native → Dart 反向调用的唯一分发器**（alpha.91）。
///
/// ## 为什么必须"唯一"
///
/// `MethodChannel.setMethodCallHandler` 在 Dart 侧**每个通道只能有一个
/// handler，后注册的会直接覆盖前一个**。这不是"两个都能收到"，是
/// **前一个被静默摘掉**——没有异常、没有日志、编译期也不会有任何提示。
///
/// 本通道此前只有 `BuildNotify.ensureHandler()`（`build_notify.dart:35`）
/// 一处注册，靠的是当时的一句注释：
///
/// > 原生侧只 invoke 过 `navigate` 一个反向方法，在此 setMethodCallHandler
/// > 不会劫持 Dart → Native 的正常调用。
///
/// 这句话描述的是一个**侥幸**，不是一个约束：它成立的前提是"永远只有
/// 一个文件注册 handler"。本轮要加 `fsChange`（文件变更推送），如果
/// 图省事在新文件里再写一次 `setMethodCallHandler`，那么**谁后注册谁生效**，
/// 另一个方法的调用会静默消失。后果具体是：
///
/// - 若新代码后注册 → 用户点通知回构建页**失效**；
/// - 若 `BuildNotify` 后注册 → 文件同步**失效**。
///
/// 两种都不是崩溃，都是"用户觉得功能没做"。这类 bug 极难查。
///
/// ## 这里怎么把侥幸变成契约
///
/// 1. **只此一处** `setMethodCallHandler`（全项目唯一），由
///    [ensureHandler] 在 `main.dart` 启动时调一次，幂等。
/// 2. **反向方法名登记制**：[_reverseMethods] 把"名字 → 处理逻辑"
///    写成一张表，新增必须登记在此。
/// 3. **启动期自检**：[ensureHandler] 会检查登记表与正向方法名有无冲突，
///    以及有没有重复登记 —— 冲突直接 `assert` 炸在开发期，而不是让用户
///    在真机上遇到"点了没反应"。
///
/// ## 反向 vs 正向：命名空间必须分开
///
/// 本通道上**正向**（Dart → Native）方法名目前有：
/// `fileList` / `fileRead` / `fileWrite` / `fileMkdir` / `fileRename` /
/// `fileDelete` / `pickInstallFile` / `notificationsEnabled` /
/// `notifyStart` / `notifyProgress` / `notifyStop` / `takeNavigate` /
/// `openNotificationSettings` / `fsWatchStart` / `fsWatchStop` / …
///
/// 反向（Native → Dart）目前有：[kNavigateMethod]、[kFsChangeMethod]。
///
/// **两组名字不得重合**。重合时会发生什么：原生侧 `invokeMethod('xxx')`
/// 走的是 Native→Dart 方向，Dart 侧 `_channel.invokeMethod('xxx')` 走
/// Dart→Native 方向，两者其实**不会互相干扰**（方向不同），但重合会让
/// 代码极难读——看到 `'xxx'` 无法判断说的是哪个方向，因此列为禁止项并由
/// [assertNoCollision] 在开发期拦住。
class NativeEvents {
  NativeEvents._();

  static const MethodChannel _channel = MethodChannel('dev.foa/proot');

  /// 反向方法名：用户点通知 → 回目标页。原生侧 `MainActivity.onNewIntent` 发。
  static const String kNavigateMethod = 'navigate';

  /// 反向方法名：磁盘上的被监听文件变了。
  ///
  /// 参数（Map）：`{'path': String, 'seq': int}`
  /// - `path` = 容器内路径，**只报路径不带内容**（理由见
  ///   `file_change_source.dart` 的接口注释：事件到达时文件可能正被写一半，
  ///   那时候读出来的内容是残缺的，拿它覆盖编辑器就是丢代码）；
  /// - `seq` = 原生侧单调递增的事件序号。Dart 侧目前不依赖它做排序，
  ///   但留着可观测——排查"事件到底有没有到"时是唯一的抓手（打印出来
  ///   就知道是原生没发、还是 Dart 没接）。
  static const String kFsChangeMethod = 'fsChange';

  /// 反向方法名 → 说明。**新增反向方法必须登记在这里**，否则
  /// [ensureHandler] 的启动自检会炸。
  ///
  /// 用表而不是 `switch` + 注释的原因：表可以被**遍历**，于是
  /// "有没有重复""有没有和正向重名"能在启动期自动查出来；散在
  /// `switch` 的分支里就只能靠人眼。
  static const Map<String, String> _reverseMethods = {
    kNavigateMethod: '用户点通知 → 回最近启动的前台任务页',
    kFsChangeMethod: '被监听文件发生变更（参数 {path, seq}）',
  };

  /// 正向（Dart → Native）方法名，仅用于启动期查重。
  ///
  /// ⚠️ 这份清单**不是**权威来源，只是给 [assertNoCollision] 一个比对基准。
  /// 加正向方法时忘了同步这里，最坏结果是"少查了一条重名"，不会造成
  /// 任何运行时错误——所以它的维护紧迫性低于 [_reverseMethods]。
  static const Set<String> _forwardMethods = {
    'fileList', 'fileRead', 'fileWrite', 'fileMkdir', 'fileRename', 'fileDelete',
    'pickInstallFile', 'notificationsEnabled',
    'notifyStart', 'notifyProgress', 'notifyStop', 'takeNavigate',
    'openNotificationSettings', 'fsWatchStart', 'fsWatchStop',
  };

  /// 文件变更回调。参数 = 容器内路径，**只有路径**。
  ///
  /// 谁注册：`EditorPage`（它知道当前打开哪个文件、要不要弹 diff）。
  /// 用静态字段而不是让 EditorPage 自己注册 handler —— 那正是要避免的
  /// "第二个 setMethodCallHandler"。
  ///
  /// 只允许一个订阅者：编辑器一次只打开一个文件，天然只有一个。若将来
  /// 需要多订阅者，在这里改成 List 并广播，**不要在别处再注册 handler**。
  static void Function(String path)? onFsChange;

  static bool _hooked = false;

  /// 供测试复位（`NativeEvents` 是静态状态，跨测试会串）。
  @visibleForTesting
  static void resetForTest() {
    _hooked = false;
    onFsChange = null;
    BuildNotify.onNavigate = null;
  }

  /// 开发期自检：反向方法名不得与正向方法名重合，登记表不得有重复键。
  ///
  /// 做成静态可调用（而不只藏在 [ensureHandler] 里）是为了让测试能直接
  /// 断言这张表本身是干净的——否则"表脏了"这件事只有真跑起来才知道。
  static void assertNoCollision() {
    // Map 字面量本身不允许重复键（编译期报错），这里防的是"表里某个
    // 名字恰好也是正向方法名"——那种情况编译器不管。
    for (final name in _reverseMethods.keys) {
      assert(
        !_forwardMethods.contains(name),
        '反向方法名 "$name" 与正向方法名重名。'
        '同一通道上两个方向用同一个名字会让代码无法判读，'
        '请给反向方法换一个名字（约定：反向用动词短语，如 fsChange / navigate）。',
      );
    }
  }

  /// 注册 Native → Dart 的反向调用（幂等；`main.dart` 启动时调一次）。
  ///
  /// ⚠️ 全项目**只有这里**可以调 `setMethodCallHandler`。在别处再调一次，
  /// 这个方法注册的 handler 会被**静默覆盖**，[kNavigateMethod] 或
  /// [kFsChangeMethod] 之一随之失效。`native_events_test.dart` 有一条
  /// 源码扫描断言在守这条纪律。
  static void ensureHandler() {
    if (_hooked) return;
    assertNoCollision();
    _hooked = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case kNavigateMethod:
          // 参数一直是 null（原生只发信号，类别靠 BuildNotify.lastRoute
          // 从 Dart 侧取），所以这里不解析 arguments。
          BuildNotify.onNavigate?.call();
          break;
        case kFsChangeMethod:
          // 参数是 Map，但**防御性取值**：事件来自原生，字段缺失/类型不符
          // 时应该安静地忽略这一条，而不是抛异常把整个 handler 带崩
          // （handler 抛异常会让后续事件也收不到）。
          final args = call.arguments;
          if (args is Map) {
            final p = args['path'];
            if (p is String && p.isNotEmpty) onFsChange?.call(p);
          }
          break;
        default:
          // 未登记的方法：静默忽略。
          //
          // 为什么不报错：原生侧可能比 Dart 侧新（用户装了新 APK 但 Dart
          // 代码是旧的发布版），或者只是新增了一个 Dart 暂时不关心的事件。
          // 抛异常会让**同一个 handler 的后续所有事件**都收不到——
          // 用一个小功能的缺失换掉整个反向通道，代价完全不成比例。
          break;
      }
    });
  }
}
