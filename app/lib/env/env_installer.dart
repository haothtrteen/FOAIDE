import 'package:flutter/foundation.dart';

import '../core/logger.dart';
import 'models.dart';
import 'proot_bridge.dart';

/// 全局环境状态（ChangeNotifier）。
///
/// 所有对 proot 环境的操作都经过这里，并统一写 JSONL 日志：
/// `<filesDir>/logs/app-YYYYMMDD.log`
class EnvState extends ChangeNotifier {
  final ProotBridge bridge = ProotBridge();

  EnvInfo? info;
  bool installing = false;
  String installLog = '';
  String? error;

  bool get isInstalled => info?.rootfsInstalled ?? false;

  /// 启动时调用：拉取环境信息 + 初始化日志。
  Future<void> bootstrap() async {
    try {
      info = await bridge.envInfo();
      await AppLogger.init(info!.filesDir);
      await AppLogger.event('app_start', {
        'device': info!.device,
        'androidSdk': info!.androidSdk,
        'abi': info!.abi,
        'prootPath': info!.prootPath,
        'rootfsInstalled': info!.rootfsInstalled,
      });
      if (info!.abi != null && !info!.abi!.contains('arm64')) {
        error = '设备 ABI 为 ${info!.abi}，Step 1 仅支持 arm64 设备'
            '（proot 与 rootfs 均为 aarch64 构建）';
      }
    } catch (e) {
      error = '原生桥初始化失败: $e';
    }
    notifyListeners();
  }

  Future<void> refresh() => bootstrap();

  /// 解压安装 rootfs（幂等），返回是否成功。
  Future<bool> installRootfs() async {
    if (installing) return false;
    installing = true;
    installLog = '正在解压 rootfs（首次约 10-60 秒，取决于闪存速度）…';
    error = null;
    notifyListeners();
    try {
      final r = await bridge.installRootfs();
      if (r.ok) {
        installLog = r.alreadyInstalled
            ? '环境已存在，无需重复安装'
            : '安装完成：${r.files} 个文件，'
                '耗时 ${(r.durationMs / 1000).toStringAsFixed(1)}s';
        await AppLogger.event('rootfs_install',
            {'ok': true, 'files': r.files, 'durationMs': r.durationMs});
      } else {
        error = r.error ?? '未知错误';
        await AppLogger.event('rootfs_install',
            {'ok': false, 'error': r.error});
      }
      await bootstrap();
      return r.ok;
    } catch (e) {
      error = '安装异常: $e';
      await AppLogger.event(
          'rootfs_install', {'ok': false, 'error': e.toString()});
      return false;
    } finally {
      installing = false;
      notifyListeners();
    }
  }

  /// 在 proot 环境中执行命令（结构化日志在此统一记录）。
  Future<ProotResult> run(String command, {int timeoutSec = 180}) async {
    final r = await bridge.exec(command, timeoutSec: timeoutSec);
    await AppLogger.event('exec', {
      'cmd': command,
      'exitCode': r.exitCode,
      'durationMs': r.durationMs,
      'stdoutHead': r.stdout.length > 300 ? r.stdout.substring(0, 300) : r.stdout,
      'stderrHead': r.stderr.length > 300 ? r.stderr.substring(0, 300) : r.stderr,
    });
    return r;
  }
}
