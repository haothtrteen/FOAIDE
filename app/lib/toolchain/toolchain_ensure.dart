import '../env/proot_bridge.dart';

/// 工具链前置确保（Step 7 修复：容器内 flutter create/build 依赖 git）。
///
/// flutter 工具启动时强制 `git --version` 检查，容器 rootfs 只装了
/// xz-utils/unzip，git 缺失 → `Error: Unable to find git in your PATH`，
/// 创建工程/构建 APK 全部 exit 1。此处幂等确保：已装秒过，缺失走 apt 镜像
/// 安装（镜像已在 Step 3 配好，国内源可用）。
class ToolchainEnsure {
  final ProotBridge _bridge = ProotBridge();

  /// 确保容器内 git 可用；成功返回 null，失败返回错误文案。
  Future<String?> git() async {
    final check = await _bridge.exec(
      'command -v git >/dev/null 2>&1 && echo GIT_OK || echo GIT_MISSING',
      timeoutSec: 30,
    );
    if (check.exitCode == 0 && check.stdout.contains('GIT_OK')) return null;

    final install = await _bridge.exec(
      'DEBIAN_FRONTEND=noninteractive apt-get update -qq '
      '&& DEBIAN_FRONTEND=noninteractive apt-get install -y -qq '
      '--no-install-recommends git',
      timeoutSec: 900,
    );
    if (install.exitCode != 0) {
      final out = install.stderr.isNotEmpty ? install.stderr : install.stdout;
      return '自动安装 git 失败：\n${_tail(out)}';
    }
    return null;
  }

  static String _tail(String s) {
    final t = s.trim();
    return t.length <= 400 ? t : '…${t.substring(t.length - 400)}';
  }
}
