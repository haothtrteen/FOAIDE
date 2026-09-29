import 'package:flutter/services.dart';

import '../events/native_events.dart';

/// 构建通知桥（alpha.31）：前台服务保活 + 通知栏进度 + 点击回构建页。
///
/// 通道复用 dev.foa/proot（MainActivity 同一 handler 分发），消息一览：
/// - Dart → Native：`notificationsEnabled` / `notifyStart` / `notifyProgress` /
///   `notifyStop` / `takeNavigate`；
/// - Native → Dart：`navigate`（用户点通知，原生在 onNewIntent 里 invoke）
///   —— **alpha.91 起该反向调用由 [NativeEvents] 统一分发**，本类只提供
///   [onNavigate] 回调点。
///
/// 为什么不引 flutter_local_notifications：App 进程三方依赖归零是本仓库
/// 原则（alpha.27 移除 Kadb 同因）；这里只需「渠道 + 进度 + 点击跳转」
/// 三件套，原生百行内做完，不值得为一个通知拖整个插件。
///
/// 所有 invoke 都吞异常：通知只是进度展示渠道，任何失败都不能阻断构建。
class BuildNotify {
  BuildNotify._();

  static const MethodChannel _channel = MethodChannel('dev.foa/proot');

  /// 点击通知 → 回构建页的回调（FoaApp 启动时注册；原生 navigate 触发）。
  static void Function()? onNavigate;

  /// 最近一次启动的前台任务归属（alpha.59 引入，alpha.60 扩展）：
  /// 'build' = 构建页 / 'preview' = Web 预览控制台 / 'takeover' = 远程协助。
  /// 原生侧只回发 navigate 信号（不带类别），点击跳转由 Dart 按此字段分流
  /// ——默认构建页（冷启动兜底语义不变）。
  static String lastRoute = 'build';

  static bool _hooked = false;

  /// 注册原生 → Dart 的反向调用（幂等）。
  ///
  /// ## alpha.91 起已移交 [NativeEvents]，此处仅保留兼容转发（**待删**）
  ///
  /// 背景：本方法此前自己调 `_channel.setMethodCallHandler`。同一个通道
  /// **只能有一个 handler，后注册的直接覆盖前一个**，且**静默无提示**。
  /// alpha.91 要新增 `fsChange`（文件变更推送），如果在新文件里再注册一次，
  /// `navigate` 与 `fsChange` 必然有一个收不到——而且不崩溃、不报错，
  /// 只表现为"功能没做"。
  ///
  /// 所以反向分发统一收到 `lib/events/native_events.dart` 的
  /// [NativeEvents.ensureHandler]：一处注册、方法名登记制、启动期查重。
  ///
  /// 保留这个方法是因为仓库里可能还有调用点；它的行为已变成"转调"，
  /// 不再自己注册 handler，因此**不会**与 [NativeEvents] 抢 handler。
  /// 新代码请直接调 [NativeEvents.ensureHandler]。
  @Deprecated('改用 NativeEvents.ensureHandler（alpha.91 统一反向分发）')
  static void ensureHandler() {
    if (_hooked) return;
    _hooked = true;
    NativeEvents.ensureHandler();
  }

  /// 冷启动兜底：用户在 App 未运行时点通知 → MainActivity.onCreate 的
  /// intent 已带导航意图，但 Dart handler 那时还没注册——原生先存着，
  /// Dart 就绪后主动取一次。返回 true 表示需要打开构建页。
  static Future<bool> takePendingNavigate() async {
    try {
      return await _channel.invokeMethod<bool>('takeNavigate') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 通知是否可用（Android 13+ 用户可手动关）。异常一律 true：
  /// 通知不可用只影响"退到桌面看进度"，不该拦着用户构建。
  static Future<bool> get enabled async {
    try {
      return await _channel.invokeMethod<bool>('notificationsEnabled') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// 跳系统「通知」设置页（本应用那一项）。
  ///
  /// ## 为什么只能跳设置页，不能弹授权框
  ///
  /// 通知运行时权限（POST_NOTIFICATIONS）是 API 33 引入的，**主动弹出需要
  /// targetSdk ≥ 33**。本项目 targetSdk=28，弹框时机完全由系统掌握
  /// （只在"建过通知渠道之后的某次启动"自动问一次），而且用户点一次
  /// 「不允许」就再也不会被问 —— 除非卸载重装、或把 targetSdk 升到 33。
  ///
  /// 所以应用侧能做的只有"检查（[enabled]）+ 引导去设置页"，这是平台限制，
  /// 不是实现偷懒。别在这里加 `requestPermissions` 之类的调用 —— 对
  /// targetSdk<33 的应用，系统会直接忽略。
  ///
  /// 返回是否成功拉起设置页。
  static Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openNotificationSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 构建开始：启动前台服务（保活）+ 常驻进度通知。
  static Future<void> start(String title) async {
    try {
      await _channel.invokeMethod('notifyStart', {'title': title});
    } catch (_) {}
  }

  /// 进度更新（Dart 侧已按「阶段/百分比变化」节流，Kotlin 侧再限频）。
  static Future<void> progress(String text, int percent) async {
    try {
      await _channel.invokeMethod(
        'notifyProgress',
        {'text': text, 'percent': percent},
      );
    } catch (_) {}
  }

  /// 构建结束/取消：更新为结果文案，服务停止但通知留给用户（可滑除，
  /// 点它回构建页看完整日志）。
  static Future<void> finish(String text) async {
    try {
      await _channel.invokeMethod('notifyStop', {'text': text});
    } catch (_) {}
  }
}
