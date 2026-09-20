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

  Future<ProotResult> exec(String command,
      {int timeoutSec = 180, bool bare = false, bool proroot = false}) async {
    final raw = await _channel.invokeMethod('exec', {
      'command': command,
      'timeoutSec': timeoutSec,
      // bare=true：**不经 proot**，宿主 /system/bin/sh 直跑（Termux 裸原生后端）
      'bare': bare,
      // proroot=true：容器层换成 proroot（LD_PRELOAD 路径翻译，
      // 免掉 proot 每次系统调用的两次上下文切换）。
      // 与 bare 互斥——bare 根本不进容器，此时该参数被原生侧忽略。
      'proroot': proroot,
    });
    return ProotResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  // ---------------- proroot 容器层（alpha.61） ----------------

  /// 查询 proroot 落位状态（缺哪些文件、abi、api、rootfs 是否就绪）。
  Future<ProrootStatus> prorootStatus() async {
    final raw = await _channel.invokeMethod('prorootStatus');
    return ProrootStatus.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 打开系统目录选择器导入 proroot 的 5 个 .so（用户选目录，原生递归拷贝）。
  /// 返回 null 表示用户取消。
  Future<ProrootInstallResult?> prorootImport() async {
    final raw = await _channel.invokeMethod('prorootImport');
    final m = (raw as Map<Object?, Object?>?) ?? {};
    if (m['ok'] == false && (m['error'] as String? ?? '').contains('已取消')) {
      return null;
    }
    return ProrootInstallResult.fromMap(m);
  }

  /// 清空 proroot 落位目录，返回删除的文件数。
  Future<int> prorootRemove() async {
    final raw = await _channel.invokeMethod('prorootRemove');
    final m = (raw as Map<Object?, Object?>?) ?? {};
    return (m['removed'] as num?)?.toInt() ?? 0;
  }

  /// 冒烟测试：在容器里真跑一次 proroot。
  ///
  /// 之所以必须有这一步：proroot 官方要求 Ubuntu arm64 rootfs，
  /// 本项目用 Debian 12 bookworm——**未验证组合**。文件在不在、
  /// 是不是 ELF 都判断不了能不能跑，只能真跑。
  Future<ProrootProbeResult> prorootProbe() async {
    final raw = await _channel.invokeMethod('prorootProbe');
    return ProrootProbeResult.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  // ---------------- Step 6 · 流式执行（构建日志） ----------------

  /// 启动流式命令（输出合并单流，超时默认 2h），返回任务 id。
  /// bare=true：Termux 裸原生模式，命令里的路径必须是**宿主路径**。
  Future<ExecStreamStart> execStream(String command,
      {int timeoutSec = 7200, bool bare = false, bool proroot = false}) async {
    final raw = await _channel.invokeMethod('execStream', {
      'command': command,
      'timeoutSec': timeoutSec,
      'bare': bare,
      'proroot': proroot,
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

  // ---------------- Bug 430 · 可交互 PTY 终端 ----------------

  /// 启动一个真正的 pty 会话（foa_pty 中继器 → proot/宿主 shell）。
  /// bare=true 走宿主 /system/bin/sh（Termux 裸原生后端）。
  Future<PtyStart> ptyStart(
      {bool bare = false, int cols = 80, int rows = 24}) async {
    final raw = await _channel.invokeMethod('ptyStart', {
      'bare': bare,
      'cols': cols,
      'rows': rows,
    });
    return PtyStart.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  /// 把按键/粘贴文本写进 pty（原样透传，0x03 等控制字节照发）。
  Future<bool> ptyWrite(int id, String text) async {
    final raw = await _channel.invokeMethod('ptyWrite', {
      'id': id,
      'text': text,
    });
    return (raw as Map<Object?, Object?>?)?['ok'] == true;
  }

  /// 轮询增量屏幕输出（offset = 上次返回的 len）。
  Future<PtyPoll> ptyPoll(int id, int offset) async {
    final raw = await _channel.invokeMethod('ptyPoll', {
      'id': id,
      'offset': offset,
    });
    return PtyPoll.fromMap((raw as Map<Object?, Object?>?) ?? {});
  }

  Future<bool> ptyStop(int id) async {
    final raw = await _channel.invokeMethod('ptyStop', {'id': id});
    return (raw as Map<Object?, Object?>?)?['ok'] == true;
  }

  /// 终端尺寸变化：vim/top 等全屏程序据此重排。
  Future<bool> ptyResize(int id, {required int cols, required int rows}) async {
    final raw = await _channel.invokeMethod('ptyResize', {
      'id': id,
      'cols': cols,
      'rows': rows,
    });
    return (raw as Map<Object?, Object?>?)?['ok'] == true;
  }
}
