import 'dart:io';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'sdk_downloader.dart';
import 'sdk_installer.dart' show AptTools;

/// x64 兼容层（qemu-user 静态转发）。
///
/// 背景（2026-09-17 定稿，依据 Flutter issue #189724/#168980 与
/// artifacts.dart 源码核实）：
/// - Flutter 官方 Linux SDK / Android build-tools / platform-tools 只发布
///   x86_64 宿主二进制（gen_snapshot、impellerc、font-subset、aapt2、
///   zipalign、adb…），aarch64 proot 容器直接 exec 会报 Exec format error；
/// - 本层在容器内安装 qemu-user-static（静态 aarch64 二进制）与 x86_64
///   多架构运行库（libc6:amd64 / libstdc++6:amd64 / libgcc-s1:amd64 /
///   zlib1g:amd64 / libatomic1:amd64），然后把关键工具替换为
///   「qemu 转发脚本」：原二进制改名 .foa-real，占位脚本 exec
///   qemu-x86_64-static -L / 运行它。
///
/// 引擎产物特殊处理：flutter_tools 按
///   bin/cache/artifacts/engine/<target>-<mode>/<hostPlatform>/
/// 查找 gen_snapshot 等宿主工具，官方只发布 linux-x64。本层为每个
/// android-*/linux-x64 生成 linux-arm64/ 目录，内含指向 ../linux-x64/<tool>
/// 的 qemu 转发脚本——不复制大文件、不修改官方 linux-x64 原件，
/// 因此 flutter 缓存 stamp 校验不受影响（用户核实的第三个前提成立）。
///
/// Flutter 工具链（2026-09-17 真机补强）：bin/cache/flutter_tools.snapshot
/// 是 app-jit 快照（含 x64 机器码，**架构相关**）——arm64 dart 直接运行
/// 报 "Snapshot not compatible ... requires x64 linux ... VM has arm64"。
/// 本层把 bin/cache/dart-sdk/bin/ 下的 x64 ELF（dart、dartaotruntime…）
/// 原地改名 .foa-real 并生成 qemu 转发脚本；flutter（bash 脚本）照常
/// 调用 dart 路径，经转发脚本进入 qemu 模拟，x64 快照由 x64 dart VM
/// 加载即恢复正常。qemu 内 fork/exec 的 x64 子进程（frontend_server、
/// gen_snapshot 等）由 qemu 继续模拟，全链路自洽。
///
/// 分步验证（用户建议的真机验证流程，内置在 verify()）：
///   1. qemu-x86_64-static 存在；
///   2. qemu 能运行 x86_64 动态链接器（/lib64/ld-linux-x86-64.so.2，
///      验证多架构 glibc 安装成功）；
///   3. 包装后的 gen_snapshot（转发脚本 → qemu → 真实二进制）能跑通
///      --help（输出无 "cannot execute"/"shared libraries" 类错误）。
class QemuCompat {
  static const String qemuBin = '/usr/bin/qemu-x86_64-static';
  static const String sdkHome = '/opt/android-sdk';
  static const String flutterHome = '/opt/flutter';
  static const String engineDir = '$flutterHome/bin/cache/artifacts/engine';
  static const String aapt2Override = '$sdkHome/build-tools/36.0.0/aapt2';
  static const String gradleProps = '/root/.gradle/gradle.properties';

  // ---------------- 容器内 shell 脚本（@TOKEN@ 由 Dart 侧替换）---------------

  static const String _installScript = r'''
dpkg --print-foreign-architectures 2>/dev/null | grep -qx amd64 || dpkg --add-architecture amd64
apt-get update -qq -o Acquire::Retries=3 2>&1 | tail -n 20
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends -o Acquire::Retries=3 qemu-user-static libc6:amd64 libstdc++6:amd64 libgcc-s1:amd64 zlib1g:amd64 libatomic1:amd64 2>&1 | tail -n 40
[ -x @QEMU@ ] && echo QEMU_OK
''';

  /// Flutter 工具链转发：dart-sdk/bin 下 x64 ELF（dart、dartaotruntime 等）
  /// 原地改名 .foa-real，生成 qemu 转发脚本。flutter 工具（bash 脚本）
  /// 照常调用 dart 路径，经转发脚本进入 qemu 模拟，x64 flutter_tools.snapshot
  /// 由 x64 dart VM 加载，解决真机 "Snapshot not compatible" 报错。
  static const String _flutterWrapScript = r'''
F=@FLUTTER@/bin/cache/dart-sdk/bin
[ -d "$F" ] || { echo FLUTTER_MISSING; exit 0; }
gen() {
  cat > "$1" <<FOAWRAP
#!/bin/sh
# FOA x86_64 -> qemu-user wrapper (auto-generated)
d=\$(dirname "\$0")
if [ -d "\$d/lib64" ]; then
  LD_LIBRARY_PATH="\$d/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
  export LD_LIBRARY_PATH
fi
exec @QEMU@ -L / "$2" "\$@"
FOAWRAP
  chmod 755 "$1"
}
n=0
for f in "$F"/*; do
  [ -f "$f" ] || continue
  [ -x "$f" ] || continue
  case "$f" in *.foa-real) continue ;; esac
  m=$(dd if="$f" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in 7f454c46*3e) ;; *) continue ;; esac
  mv "$f" "$f.foa-real"
  gen "$f" "$f.foa-real"
  n=$((n+1))
done
echo "FLUTTER_WRAPPED=$n"
''';

  /// 引擎产物同步：若尚未下载 → flutter precache --android（走 flutter-io.cn），
  /// 再为每个 android-*/linux-x64 生成 linux-arm64/ 转发脚本。
  static const String _engineSyncScript = r'''
E=@ENGINE@
[ -d "$E" ] || { echo ENGINE_MISSING; exit 0; }
if ! ls -d "$E"/android-*/linux-x64 >/dev/null 2>&1; then
  echo PRECACHE
  FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn PUB_HOSTED_URL=https://pub.flutter-io.cn @FLUTTER@/bin/flutter precache --android > /tmp/foa_precache.log 2>&1
  rc=$?
  tail -n 40 /tmp/foa_precache.log
  if [ "$rc" != 0 ]; then echo PRECACHE_FAILED; exit 3; fi
fi
gen() {
  cat > "$1" <<FOAWRAP
#!/bin/sh
# FOA x86_64 -> qemu-user wrapper (auto-generated)
d=\$(dirname "\$0")
if [ -d "\$d/lib64" ]; then
  LD_LIBRARY_PATH="\$d/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
  export LD_LIBRARY_PATH
fi
exec @QEMU@ -L / "$2" "\$@"
FOAWRAP
  chmod 755 "$1"
}
n=0
for d in "$E"/android-*/linux-x64; do
  [ -d "$d" ] || continue
  a="${d%/linux-x64}/linux-arm64"
  mkdir -p "$a"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ -x "$f" ] || continue
    m=$(dd if="$f" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$m" in 7f454c46*3e) ;; *) continue ;; esac
    w="$a/${f##*/}"
    [ -f "$w" ] || gen "$w" "$f"
  done
  n=$((n+1))
done
echo "ENGINE_DIRS=$n"
''';

  /// Android SDK 工具接管：build-tools / platform-tools 顶层 x86_64 ELF
  /// 原地改名 .foa-real，生成 qemu 转发脚本。
  static const String _sdkWrapScript = r'''
S=@SDK@
[ -d "$S" ] || { echo SDK_MISSING; exit 0; }
gen() {
  cat > "$1" <<FOAWRAP
#!/bin/sh
# FOA x86_64 -> qemu-user wrapper (auto-generated)
d=\$(dirname "\$0")
if [ -d "\$d/lib64" ]; then
  LD_LIBRARY_PATH="\$d/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
  export LD_LIBRARY_PATH
fi
exec @QEMU@ -L / "$2" "\$@"
FOAWRAP
  chmod 755 "$1"
}
n=0
for d in "$S"/build-tools/* "$S"/platform-tools; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    [ -x "$f" ] || continue
    case "$f" in *.foa-real) continue ;; esac
    m=$(dd if="$f" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$m" in 7f454c46*3e) ;; *) continue ;; esac
    mv "$f" "$f.foa-real"
    gen "$f" "$f.foa-real"
    n=$((n+1))
  done
done
echo "SDK_WRAPPED=$n"
''';

  static const String _verifyScript = r'''
[ -x @QEMU@ ] || { echo __NO_QEMU__; exit 0; }
echo "QEMU=$(/usr/bin/qemu-x86_64-static --version 2>&1 | head -1)"
# 分步验证 2：qemu 运行 x86_64 动态链接器（多架构 glibc 就绪）
loader=no
if [ -f /lib64/ld-linux-x86-64.so.2 ] && /usr/bin/qemu-x86_64-static -L / /lib64/ld-linux-x86-64.so.2 --version >/dev/null 2>&1; then loader=yes; fi
echo "LOADER=$loader"
# 引擎转发层 + 分步验证 3：包装后的 gen_snapshot 可跑通 --help
gs=@ENGINE@/android-arm64-release/linux-arm64/gen_snapshot
if [ -x "$gs" ]; then
  out=$( "$gs" --help 2>&1 | head -3 )
  case "$out" in
    *'cannot execute'*|*'Exec format'*|*'error while loading shared libraries'*) echo "GEN_SNAPSHOT=no" ;;
    *) echo "GEN_SNAPSHOT=yes" ;;
  esac
else
  echo "GEN_SNAPSHOT=no"
fi
# Flutter 工具链转发（dart 已被 qemu 接管才不会有 Snapshot 不兼容）
if [ -f @FLUTTER@/bin/cache/dart-sdk/bin/dart.foa-real ]; then
  echo "DART=yes"
else
  echo "DART=no"
fi
# SDK 工具接管
if [ -f @SDK@/build-tools/36.0.0/aapt2.foa-real ]; then
  aout=$( @SDK@/build-tools/36.0.0/aapt2 version 2>&1 | head -1 )
  case "$aout" in
    *'cannot execute'*|*'Exec format'*|*'error while loading shared libraries'*) echo "AAPT2=no" ;;
    *) echo "AAPT2=yes" ;;
  esac
else
  echo "AAPT2=no"
fi
grep -q 'aapt2FromMavenOverride' /root/.gradle/gradle.properties 2>/dev/null && echo "GRADLE=yes" || echo "GRADLE=no"
''';

  static const String _uninstallScript = r'''
S=@SDK@
E=@ENGINE@
F=@FLUTTER@
rm -rf "$E"/android-*/linux-arm64 2>/dev/null
if [ -d "$F/bin/cache/dart-sdk/bin" ]; then
  for f in "$F/bin/cache/dart-sdk/bin"/*.foa-real; do
    [ -f "$f" ] || continue
    b="${f%.foa-real}"
    rm -f "$b"
    mv "$f" "$b"
  done
fi
for d in "$S"/build-tools/* "$S"/platform-tools; do
  [ -d "$d" ] || continue
  for f in "$d"/*.foa-real; do
    [ -f "$f" ] || continue
    b="${f%.foa-real}"
    rm -f "$b"
    mv "$f" "$b"
  done
done
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq qemu-user-static libc6:amd64 libstdc++6:amd64 libgcc-s1:amd64 zlib1g:amd64 libatomic1:amd64 2>&1 | tail -n 5 || true
dpkg --remove-architecture amd64 2>/dev/null || true
echo UNINSTALL_OK
''';

  // ---------------- 验证 ----------------

  /// 重新验证：qemu 在位 + 分步冒烟测试 + 各接管点状态。
  static Future<String?> verify(ProotBridge bridge) async {
    final r = await bridge.exec(
      _verifyScript
          .replaceAll('@QEMU@', qemuBin)
          .replaceAll('@ENGINE@', engineDir)
          .replaceAll('@SDK@', sdkHome)
          .replaceAll('@FLUTTER@', flutterHome),
      timeoutSec: 120,
    );
    if (!r.ok || r.stdout.contains('__NO_QEMU__')) return null;

    String? kv(String key) {
      for (final line in r.stdout.split('\n')) {
        if (line.startsWith('$key=')) return line.substring(key.length + 1).trim();
      }
      return null;
    }

    final qemu = kv('QEMU') ?? '';
    if (qemu.isEmpty) return null;
    final loaderOk = kv('LOADER') == 'yes';
    final genOk = kv('GEN_SNAPSHOT') == 'yes';
    final dartOk = kv('DART') == 'yes';
    final aaptOk = kv('AAPT2') == 'yes';
    final gradleOk = kv('GRADLE') == 'yes';

    return [
      'qemu ${qemu.split(' ').last}',
      loaderOk ? 'x86_64 动态链接器可运行' : '多架构库缺失',
      dartOk ? 'flutter 工具链已转发' : 'flutter 工具链未转发（装 Flutter 后重新应用）',
      genOk ? 'gen_snapshot 冒烟通过' : '引擎产物未同步（装 Flutter 后重新应用）',
      aaptOk ? 'aapt2 已接管' : 'SDK 工具未接管',
      gradleOk ? 'AGP 已指向本地 aapt2' : 'gradle 未配置',
    ].join(' · ');
  }

  // ---------------- 安装 / 应用 ----------------

  /// 一键应用：apt 装 qemu + 多架构库 → 引擎产物预下载与转发层 →
  /// SDK 工具接管 + AGP aapt2 指向 → 验证。
  static Future<String> apply(
    ProotBridge bridge,
    EnvInfo env, {
    void Function(String phase)? onPhase,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorUsed,
    DownloadCancelToken? token,
  }) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装，请先在主页初始化环境');
    }

    onPhase?.call('apt');
    await AptTools.ensure(bridge);
    final p = await bridge.exec(
      _installScript.replaceAll('@QEMU@', qemuBin),
      timeoutSec: 1200,
    );
    if (!p.ok || !p.stdout.contains('QEMU_OK')) {
      throw DownloadException(
        '安装 qemu-user + x86_64 运行库失败：'
        '${p.stderr.trim().isEmpty ? p.stdout.trim() : p.stderr.trim()}',
      );
    }

    var engineMsg = 'Flutter 未安装，跳过引擎同步';
    final fe = await bridge.exec('[ -d $flutterHome ] && echo YES', timeoutSec: 30);
    if (fe.ok && fe.stdout.contains('YES')) {
      onPhase?.call('engine');
      // 先转发 x64 dart（flutter precache 依赖 qemu 可执行），再同步引擎产物
      final fw = await bridge.exec(
        _flutterWrapScript
            .replaceAll('@FLUTTER@', flutterHome)
            .replaceAll('@QEMU@', qemuBin),
        timeoutSec: 300,
      );
      if (!fw.ok || fw.stdout.contains('FLUTTER_MISSING')) {
        throw DownloadException('Flutter 工具链转发失败：${fw.stderr}');
      }
      final en = await bridge.exec(
        _engineSyncScript
            .replaceAll('@ENGINE@', engineDir)
            .replaceAll('@FLUTTER@', flutterHome)
            .replaceAll('@QEMU@', qemuBin),
        timeoutSec: 2400,
      );
      if (!en.ok || en.stdout.contains('PRECACHE_FAILED')) {
        throw DownloadException(
          'Flutter 引擎产物预下载/同步失败：'
          '${en.stderr.trim().isEmpty ? en.stdout.trim() : en.stderr.trim()}',
        );
      }
      engineMsg = '${fw.stdout.trim().replaceAll('\n', ' · ')} · '
          '${en.stdout.trim().replaceAll('\n', ' · ')}';
    }

    var sdkMsg = 'Android SDK 未安装，跳过接管';
    final se = await bridge.exec('[ -d $sdkHome ] && echo YES', timeoutSec: 30);
    if (se.ok && se.stdout.contains('YES')) {
      onPhase?.call('sdk');
      final sn = await bridge.exec(
        _sdkWrapScript.replaceAll('@SDK@', sdkHome).replaceAll('@QEMU@', qemuBin),
        timeoutSec: 300,
      );
      if (!sn.ok) {
        throw DownloadException('Android SDK 工具接管失败：${sn.stderr}');
      }
      sdkMsg = sn.stdout.trim().replaceAll('\n', ' · ');
      // AGP 9 仍支持 android.aapt2FromMavenOverride（不在 9.0 移除清单），
      // 指向包装后的 aapt2，避免 AGP 自行下载 x86_64 aapt2 无法执行。
      await _writeGradleOverride(env.rootfsPath);
    }

    onPhase?.call('validating');
    final v = await verify(bridge);
    if (v == null) {
      throw DownloadException('QEMU 兼容层验证失败');
    }
    return '$v\n$engineMsg · $sdkMsg';
  }

  /// 写入 /root/.gradle/gradle.properties 的 aapt2 覆盖项（宿主机直写 rootfs）。
  static Future<void> _writeGradleOverride(String rootfsPath) async {
    final f = File('$rootfsPath$gradleProps');
    await f.parent.create(recursive: true);
    var content = '';
    if (await f.exists()) content = await f.readAsString();
    final lines = content
        .split('\n')
        .where((l) => !l.trim().startsWith('android.aapt2FromMavenOverride'))
        .toList();
    lines.add('android.aapt2FromMavenOverride=$aapt2Override');
    await f.writeAsString('${lines.join('\n')}\n');
  }

  /// 移除 gradle 覆盖项（宿主机直写）。
  static Future<void> _removeGradleOverride(String rootfsPath) async {
    final f = File('$rootfsPath$gradleProps');
    if (!await f.exists()) return;
    final lines = (await f.readAsString())
        .split('\n')
        .where((l) => !l.trim().startsWith('android.aapt2FromMavenOverride'))
        .toList();
    await f.writeAsString('${lines.join('\n')}\n');
  }

  // ---------------- 卸载 ----------------

  static Future<void> uninstall(ProotBridge bridge, EnvInfo env) async {
    await bridge.exec(
      _uninstallScript
          .replaceAll('@SDK@', sdkHome)
          .replaceAll('@ENGINE@', engineDir)
          .replaceAll('@FLUTTER@', flutterHome),
      timeoutSec: 600,
    );
    await _removeGradleOverride(env.rootfsPath);
  }

  // ---------------- SDK 安装器自动接管钩子（幂等，未装兼容层时静默跳过）-------

  /// Flutter SDK 安装完成后调用：若 qemu 兼容层在位，先转发 x64 dart 工具链，
  /// 再预下载引擎产物并生成 linux-arm64 转发层，保证首次 flutter build apk
  /// 直接可用（幂等，未装兼容层时静默跳过）。
  static Future<void> syncEngineIfReady(ProotBridge bridge) async {
    try {
      final c = await bridge.exec('[ -x $qemuBin ] && echo YES', timeoutSec: 30);
      if (!c.ok || !c.stdout.contains('YES')) return;
      await bridge.exec(
        _flutterWrapScript
            .replaceAll('@FLUTTER@', flutterHome)
            .replaceAll('@QEMU@', qemuBin),
        timeoutSec: 300,
      );
      await bridge.exec(
        _engineSyncScript
            .replaceAll('@ENGINE@', engineDir)
            .replaceAll('@FLUTTER@', flutterHome)
            .replaceAll('@QEMU@', qemuBin),
        timeoutSec: 2400,
      );
    } catch (_) {
      // 钩子失败不阻断 SDK 安装；用户可稍后在兼容层卡片点「重新应用」。
    }
  }

  /// Android SDK 安装完成后调用：若 qemu 兼容层在位，接管 aapt2/adb/
  /// zipalign 等（否则验证阶段的 adb --version 会因 Exec format error 失败）。
  static Future<void> wrapSdkIfReady(ProotBridge bridge, EnvInfo env) async {
    try {
      final c = await bridge.exec('[ -x $qemuBin ] && echo YES', timeoutSec: 30);
      if (!c.ok || !c.stdout.contains('YES')) return;
      await bridge.exec(
        _sdkWrapScript.replaceAll('@SDK@', sdkHome).replaceAll('@QEMU@', qemuBin),
        timeoutSec: 300,
      );
      await _writeGradleOverride(env.rootfsPath);
    } catch (_) {
      // 钩子失败不阻断 SDK 安装。
    }
  }
}
