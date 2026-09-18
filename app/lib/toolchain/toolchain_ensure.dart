import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'qemu_compat.dart';
import 'sdk_installer.dart';

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

  /// 容器 CA 根证书确保（Bug 425 根因修复，2026-09-18 真机三连卡 4%）。
  ///
  /// debian minbase rootfs **不带 ca-certificates**（实测 tar 内
  /// /etc/ssl 与 CA 相关条目为 0）：dart 的 TLS 证书校验读系统根证书，
  /// 一个都没有 → pub 对**任何** https 源（io.cn/清华/中科大）100%
  /// 握手失败（`Got TLS error`），多源轮换、重试全部无效——真机从
  /// 首次构建起就没成功过 pub get 的真正原因。gradle 不受影响（JDK
  /// 自带 cacerts），apt 能装包（debian 源走 http）。
  ///
  /// 自愈顺序：① 已就位秒过；② apt 在线装（http 源 + JDK 无关）；
  /// ③ apt 失败 → 把 App 内置 Mozilla bundle（assets/ca/ca-bundle.crt，
  /// 147 证书 ~220KB）直接写进容器 /etc/ssl/certs/（rootfs 树宿主可见，
  /// 与 bare 的 gradle 改写同一 IO 路径）。构建命令另带
  /// SSL_CERT_FILE 环境变量双保险（dart 显式读它）。
  ///
  /// [bare]（termux 后端）暂不处理：bionic dart 的证书路径体系不同，
  /// 该后端未投产。成功返回 null，失败返回错误文案。
  Future<String?> caCerts({EnvInfo? env, bool bare = false}) async {
    if (bare) return null;
    const path = '/etc/ssl/certs/ca-certificates.crt';
    final probe = await _bridge.exec(
      'test -s $path && echo CA_OK || echo CA_MISSING',
      timeoutSec: 30,
    );
    if (probe.stdout.contains('CA_OK')) return null;

    // ① apt 在线装（debian 源走 http，不受缺 CA 影响）
    final install = await _bridge.exec(
      'DEBIAN_FRONTEND=noninteractive apt-get update -qq '
      '&& DEBIAN_FRONTEND=noninteractive apt-get install -y -qq '
      '--no-install-recommends ca-certificates '
      '&& update-ca-certificates >/dev/null 2>&1; '
      'test -s $path && echo CA_FIXED || echo CA_STILL_MISSING',
      timeoutSec: 600,
    );
    if (install.stdout.contains('CA_FIXED')) return null;

    // ② App 内置 bundle 直写容器（不经容器网络）
    try {
      final rootfs = env?.rootfsPath ?? (await _bridge.envInfo()).rootfsPath;
      final data = await rootBundle.load('assets/ca/ca-bundle.crt');
      final f = File('$rootfs/etc/ssl/certs/ca-certificates.crt');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      final verify = await _bridge.exec(
        'test -s $path && echo CA_OK || echo CA_MISSING',
        timeoutSec: 30,
      );
      if (verify.stdout.contains('CA_OK')) return null;
      return 'CA bundle 写入后仍不可见（$path）';
    } catch (e) {
      return '容器缺 CA 证书且自动修复失败（apt 与内置 bundle 均未就位）：$e';
    }
  }

  /// Android SDK NDK 占位确保（Bug 427 根因修复，2026-09-18 真机 24%）。
  ///
  /// 兜住"已装 SDK 的老用户"：工具链安装流程里已调
  /// [AndroidSdkInstaller.ensureNdkStub]，但老版本装好的 SDK 不会自动
  /// 补——构建前再确保一次（幂等，已存在秒过），避免插件调 sdkmanager
  /// 触发 arm64 JIT SIGILL（exit 132）。详见 ensureNdkStub 文档。
  ///
  /// 仅在 SDK 目录存在时执行（未装 SDK 的项目走不到 gradle 阶段）。
  /// 失败不阻断构建。
  Future<String?> ndkStub({bool bare = false}) async {
    if (bare) return null; // termux 后端 SDK 布局不同（未投产）
    try {
      final probe = await _bridge.exec(
        'test -d /opt/android-sdk && echo SDK_YES || echo SDK_NO',
        timeoutSec: 30,
      );
      if (!probe.stdout.contains('SDK_YES')) return null;
      await AndroidSdkInstaller.ensureNdkStub(_bridge);
      return null;
    } catch (e) {
      return 'NDK 占位检查失败：$e';
    }
  }

  /// x64 兼容层构建前重新确保（Bug 428 根因修复，2026-09-18 真机 47%）。
  ///
  /// 症状：AOT 编译段 `Dart snapshot generator failed with exit code -4`
  /// （SIGILL），同时 `impellerc`（shader 编译器）也 -4。
  ///
  /// 根因：Flutter 官方 Android gen_snapshot/impellerc **只发布 x86_64
  /// 宿主版**（路径 `android-arm64-release/linux-x64/`），arm64 真机必须
  /// 靠 qemu 转发。而 `artifacts.dart` L510-521 只对 darwin_arm64 做了
  /// x64 回退、**linux_arm64 没做**（flutter/flutter#152281），于是 arm64
  /// 宿主上 Flutter 会去找 `linux-arm64/gen_snapshot`——上游 bug 的表现是
  /// `flutter precache` 往该目录写**真 x64 二进制**，**覆盖掉兼容层先前
  /// 放的 qemu 转发脚本**。旧包装逻辑用 `[ -f "$w" ] || gen ...` 判定，
  /// 「文件存在」即跳过 → 永久卡在错误状态 → 每次构建必 SIGILL。
  ///
  /// 触发条件极常见：**先应用兼容层、后装/升级 Flutter SDK**（precache
  /// 冲掉包装）。真机实证：用户"先应用补丁后下载 SDK"。
  ///
  /// 修复：① 包装判定改为「是否已是转发脚本（`#!` 开头）」而非「是否存在」；
  /// ② 新增本方法在**每次构建前**重新确保（幂等，包装齐备时秒过）——
  /// 与 caCerts / gradleInitSanitize / ndkStub 同一模式：**环境会被后续
  /// 操作覆写，必须在构建前重新确保**。
  ///
  /// [bare]（termux 后端）不经 qemu，直接返回 null。
  /// 返回 null=就位/无需处理，非 null=错误文案（记录但不阻断构建）。
  Future<String?> qemuCompatEnsure({EnvInfo? env, bool bare = false}) async {
    if (bare) return null;
    try {
      // 未启用兼容层则跳过（用户可能用原生 arm64 后端）
      final probe = await _bridge.exec(
        'test -x ${QemuCompat.qemuBin} && echo QEMU_YES || echo QEMU_NO',
        timeoutSec: 30,
      );
      if (!probe.stdout.contains('QEMU_YES')) return null;

      // 检查引擎目录的转发脚本是否仍是脚本形态（被 precache 覆写则重包装）
      final chk = await _bridge.exec(
        'gs=${QemuCompat.engineDir}/android-arm64-release/linux-arm64/gen_snapshot; '
        'if [ -e "\$gs" ] && head -c 2 "\$gs" 2>/dev/null | grep -q "#!"; then '
        'echo WRAP_OK; '
        'elif [ -e "\$gs" ]; then echo WRAP_STALE; '
        'else echo WRAP_MISSING; fi',
        timeoutSec: 30,
      );
      if (chk.stdout.contains('WRAP_OK')) return null;

      // 转发脚本缺失或被覆写 → 重跑引擎包装（幂等，只补缺/纠错）
      final r = await _bridge.exec(
        QemuCompat.engineWrapScript
            .replaceAll('@ENGINE@', QemuCompat.engineDir)
            .replaceAll('@FLUTTER@', QemuCompat.flutterHome)
            .replaceAll('@QEMU@', QemuCompat.qemuBin),
        timeoutSec: 2400,
      );
      if (r.stdout.contains('PRECACHE_FAILED')) {
        return 'x64 兼容层引擎转发重建失败（precache 失败），'
            '请到「工具链」页重新应用 x64 兼容层';
      }
      // 复核
      final v = await _bridge.exec(
        'gs=${QemuCompat.engineDir}/android-arm64-release/linux-arm64/gen_snapshot; '
        'head -c 2 "\$gs" 2>/dev/null | grep -q "#!" '
        '&& echo FIXED || echo STILL_BAD',
        timeoutSec: 30,
      );
      if (v.stdout.contains('FIXED')) return null;
      return 'x64 兼容层引擎转发重建后仍异常（gen_snapshot 非转发脚本），'
          '请到「工具链」页重新应用 x64 兼容层';
    } catch (e) {
      return 'x64 兼容层构建前检查失败：$e';
    }
  }

  /// 容器 init.gradle 旧版注入自愈（Bug 426 根因修复，2026-09-18）。
  ///
  /// 场景：真机工具链「一键应用」曾写入注入型 init.gradle
  /// （allprojects{repositories{maven}} + settingsEvaluated 仓库注入），
  /// Flutter 新模板 settings.gradle.kts 走 PREFER_SETTINGS 仓库模式，
  /// 构建到 22% 配置 Gradle 时报
  /// `prefer settings repositories ... repository 'maven' was added`，
  /// plugin-loader 解析失败、构建中断。
  ///
  /// 自愈：检测容器 /root/.gradle/init.gradle 含注入特征
  /// （allprojects / settingsEvaluated + maven 仓）→ 用新版
  /// beforeSettings 前插形态（MirrorConfigurator.initGradleContent）
  /// 覆写。rootfs 树宿主可见，直接 host 写文件（与 caCerts bundle
  /// 写入同 IO 路径），不经容器命令。新版已就位则秒过。
  ///
  /// [bare]（termux 后端）gradle 目录在 prefix 下结构不同，未投产暂不处理。
  /// 返回 null=无需处理或已自愈，非 null=错误文案（仅记录，不阻断构建——
  /// 若用户已手动修正过 init.gradle，覆写失败不应挡构建）。
  Future<String?> gradleInitSanitize({EnvInfo? env, bool bare = false}) async {
    if (bare) return null;
    const probe = 'test -f /root/.gradle/init.gradle '
        '&& grep -qE "allprojects|settingsEvaluated" '
        '/root/.gradle/init.gradle '
        '&& echo INJECT_FOUND || echo INJECT_CLEAN';
    try {
      final r = await _bridge.exec(probe, timeoutSec: 30);
      if (!r.stdout.contains('INJECT_FOUND')) return null;

      // 旧版注入在场 → host 直写覆写为新版 beforeSettings 形态
      final rootfs = env?.rootfsPath ?? (await _bridge.envInfo()).rootfsPath;
      final f = File('$rootfs/root/.gradle/init.gradle');
      await f.parent.create(recursive: true);
      await f.writeAsString(MirrorConfigurator.initGradleContent(),
          flush: true);
      final verify = await _bridge.exec(probe, timeoutSec: 30);
      if (verify.stdout.contains('INJECT_CLEAN')) return null;
      return 'init.gradle 覆写后仍含旧版注入特征';
    } catch (e) {
      // 不阻断构建：真机报错时分诊 hint 会提示到工具链页重跑「一键应用」
      return 'init.gradle 自愈检测失败：$e';
    }
  }

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
