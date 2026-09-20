import 'package:flutter/services.dart';

/// 构建通知桥（alpha.31）：前台服务保活 + 通知栏进度 + 点击回构建页。
///
/// 通道复用 dev.foa/proot（MainActivity 同一 handler 分发），消息一览：
/// - Dart → Native：`notificationsEnabled` / `notifyStart` / `notifyProgress` /
///   `notifyStop` / `takeNavigate`；
/// - Native → Dart：`navigate`（用户点通知，原生在 onNewIntent 里 invoke）。
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
  /// 'build' = 构建页 / 'preview' = Web 预览控制台 / 'takeover' = 远程接管。
  /// 原生侧只回发 navigate 信号（不带类别），点击跳转由 Dart 按此字段分流
  /// ——默认构建页（冷启动兜底语义不变）。
  static String lastRoute = 'build';

  static bool _hooked = false;

  /// 注册原生 → Dart 的反向调用（幂等，main.dart 启动时调一次）。
  ///
  /// 注意：dev.foa/proot 通道原生侧只 invoke 过 `navigate` 一个反向方法，
  /// 在此 setMethodCallHandler 不会劫持 Dart → Native 的正常调用。
  static void ensureHandler() {
    if (_hooked) return;
    _hooked = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'navigate') onNavigate?.call();
    });
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
