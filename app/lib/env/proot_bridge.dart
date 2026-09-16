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

  Future<InstallResult> installRootfs() async {
    final raw = await _channel.invokeMethod('installRootfs');
    return InstallResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }
}
