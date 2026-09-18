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

  /// 构建前清理 Flutter 启动锁与孤儿进程（Bug 420，2026-09-18 真机）。
  ///
  /// 场景：上次构建被强杀（App 被杀/取消）后，容器内的 dart 孤儿进程
  /// 仍持有 flutter 启动锁（flock，进程活着锁就在），新构建永远停在
  /// `Waiting for another flutter command to release the startup lock...`
  /// ——真机实测干等 9 分钟直到 pub 超时。proot 不隔离 PID、minbase 里
  /// 没有 ps/pkill，用 /proc 遍历 + shell builtin kill。
  ///
  /// 匹配串故意拆写（'dart-sdk/bin/''dart'）：脚本文本自身（sh -c 的
  /// cmdline）不含完整串，不会自杀；只杀 dart 解释器进程（flutter_tools/
  /// pub 的宿主），gradle daemon（java）不受影响、可复用。
  ///
  /// [flutterDir]：proot 模式传 /opt/flutter；termux 模式传宿主 prefix 的
  /// flutter 路径。返回杀掉的进程数。
  Future<int> flutterUnlock(
    ProotBridge bridge,
    String flutterDir, {
    bool bare = false,
  }) async {
    final r = await _bridge.exec('''
PAT='dart-sdk/bin/''dart'
n=0
for d in /proc/[0-9]*; do
  if grep -qa "\$PAT" "\$d/cmdline" 2>/dev/null; then
    kill -9 "\${d#/proc/}" 2>/dev/null && n=\$((n+1))
  fi
done
rm -f "$flutterDir/bin/cache/lockfile" 2>/dev/null
echo "UNLOCK:\$n"
''', timeoutSec: 30, bare: bare);
    final m = RegExp(r'UNLOCK:(\d+)').firstMatch(r.stdout);
    return m != null ? int.parse(m.group(1)!) : 0;
  }

  static String _tail(String s) {
    final t = s.trim();
    return t.length <= 400 ? t : '…${t.substring(t.length - 400)}';
  }

  /// shell 单引号转义。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";
}
