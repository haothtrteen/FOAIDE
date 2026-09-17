import 'package:flutter/services.dart';

import 'models.dart';

/// 与 Kotlin 侧 MainActivity（MethodChannel "dev.foa/proot"）的桥。
///
/// 架构约定（Step 1 定稿）：
/// - Dart 不直接 Process.start 二进制，统一走 MethodChannel → Kotlin ProcessBuilder；
/// - 原生侧在单线程执行器中串行处理调用，Dart 侧无需考虑并发；
/// - 三个方法：envInfo（环境信息）/ exec（proot 内执行）/ installRootfs（解压安装）。
class ProotBridge {
  static const MethodChannel _channel = MethodChannel('dev.foa/proot');

  Future<EnvInfo> envInfo() async {
    final raw = await _channel.invokeMethod('envInfo');
    return EnvInfo.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  Future<ProotResult> exec(String command, {int timeoutSec = 180}) async {
    final raw = await _channel.invokeMethod('exec', {
      'command': command,
      'timeoutSec': timeoutSec,
    });
    return ProotResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  // ---------------- Step 6 · 流式执行（构建日志） ----------------

  /// 启动流式命令（输出合并单流，超时默认 2h），返回任务 id。
  Future<ExecStreamStart> execStream(String command,
      {int timeoutSec = 7200}) async {
    final raw = await _channel.invokeMethod('execStream', {
      'command': command,
      'timeoutSec': timeoutSec,
    });
    return ExecStreamStart.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 轮询增量输出（offset = 上次返回的 len）。
  Future<ExecStreamPoll> execStreamPoll(int id, int offset) async {
    final raw = await _channel.invokeMethod('execStreamPoll', {
      'id': id,
      'offset': offset,
    });
    return ExecStreamPoll.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 取消流式命令（SIGTERM → 强杀）。
  Future<bool> execStreamStop(int id) async {
    final raw = await _channel.invokeMethod('execStreamStop', {'id': id});
    return (raw as Map<Object?, Object?>?)?['ok'] == true;
  }

  Future<InstallResult> installRootfs() async {
    final raw = await _channel.invokeMethod('installRootfs');
    return InstallResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }
}
