import '../env/proot_bridge.dart';

/// 工具链前置确保（Step 7 修复：容器内 flutter create/build 依赖 git；
/// Step 8 增强：git 走国内镜像源 + 项目 gradle 发行包走腾讯镜像）。
///
/// flutter 工具启动时强制 `git --version` 检查，容器 rootfs 只装了
/// xz-utils/unzip，git 缺失 → `Error: Unable to find git in your PATH`，
/// 创建工程/构建 APK 全部 exit 1。此处幂等确保：已装秒过，缺失走 apt 镜像
/// 安装（镜像已在 Step 3 配好，国内源可用）；装好后再把 git 的 github
/// 克隆改写为国内镜像（gitclone.com），避免直连 github 超时。
class ToolchainEnsure {
  final ProotBridge _bridge = ProotBridge();

  /// 确保容器内 git 可用并完成国内镜像配置；成功返回 null，失败返回错误文案。
  Future<String?> git() async {
    final check = await _bridge.exec(
      'command -v git >/dev/null 2>&1 && echo GIT_OK || echo GIT_MISSING',
      timeoutSec: 30,
    );
    if (!(check.exitCode == 0 && check.stdout.contains('GIT_OK'))) {
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
    }

    // 国内镜像源：github 克隆改写为 gitclone.com（幂等，直接覆盖写）。
    // 仅影响显式 git clone https://github.com/...（flutter create 用
    // SDK 内建模板不联网；pub 包走 foa-env.sh 的 flutter-io.cn 镜像）。
    final mirror = await _bridge.exec(
      'git config --global url."https://gitclone.com/github.com/".insteadOf '
      '"https://github.com/" && echo GIT_MIRROR_OK',
      timeoutSec: 30,
    );
    if (mirror.exitCode != 0) {
      final out = mirror.stderr.isNotEmpty ? mirror.stderr : mirror.stdout;
      return 'git 镜像源配置失败：\n${_tail(out)}';
    }
    return null;
  }

  /// 把项目 gradle 发行包改为腾讯镜像（Step 8）。
  ///
  /// 工具链安装时已按腾讯 URL 预下载 gradle 发行包到
  /// ~/.gradle/wrapper/dists/<hash(腾讯URL)>；flutter create 生成的工程
  /// wrapper 默认指向 services.gradle.org，哈希不匹配 → 构建时直连官方源
  /// 下载（国内超时/失败）。此方法幂等改 URL 为腾讯镜像，构建零下载。
  /// 非 Flutter 工程/目录缺失时静默跳过，返回 null。
  Future<String?> projectGradleMirror(String projectName) async {
    final r = await _bridge.exec(
      'cd /root/projects/${_q(projectName)} 2>/dev/null || exit 0; '
      "sed -i 's|services.gradle.org/distributions|"
      'mirrors.cloud.tencent.com/gradle|\' '
      'android/gradle/wrapper/gradle-wrapper.properties 2>/dev/null || true; '
      "grep -q 'mirrors.cloud.tencent.com' "
      'android/gradle/wrapper/gradle-wrapper.properties 2>/dev/null '
      '&& echo WRAPPER_MIRROR_OK || echo WRAPPER_MIRROR_SKIP',
      timeoutSec: 30,
    );
    if (r.exitCode != 0) {
      final out = r.stderr.isNotEmpty ? r.stderr : r.stdout;
      return 'gradle 镜像配置失败：\n${_tail(out)}';
    }
    return null;
  }

  static String _tail(String s) {
    final t = s.trim();
    return t.length <= 400 ? t : '…${t.substring(t.length - 400)}';
  }

  /// shell 单引号转义。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";
}
