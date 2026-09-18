import 'dart:io';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'qemu_compat.dart' show QemuCompat;
import 'sdk_downloader.dart';
import 'sdk_installer.dart' show AptTools;

/// 原生 arm64 构建后端（Termux 移植产物）的**架构体检**。
///
/// 背景（2026-09-17）：当前构建链是「官方 x64 SDK + QEMU 用户态模拟」，
/// 全链路都有动态翻译开销。若能把关键宿主二进制换成 **aarch64 原生**，
/// 就能去掉 QEMU 这一层。可行性逐项拆分：
///
/// | 组件 | 现状 | 能否原生 |
/// | --- | --- | --- |
/// | `java` / `javac` | JDK 有 aarch64 Linux 发行版 | ✅ 换包即可 |
/// | `gradle` / `d8` / `R8` | 纯 JVM，架构无关 | ✅ 天然原生 |
/// | `dart` | Dart SDK 有 linux_arm64 发行版 | ✅ 换包即可 |
/// | `flutter_tools.snapshot` | x64 app-jit 快照 | ⚠️ 需 arm64 dart 重新生成（或走源码运行） |
/// | `aapt2` / `aidl` / `zipalign` / `split-select` | Google 只发 x86_64 | ✅ 有第三方 arm64 构建（MIT） |
/// | `gen_snapshot` | Google 只发 x86_64 | ⚠️ 唯一硬缺口，需移植版（bionic 或 glibc 需匹配） |
///
/// 本文件**只做只读体检**：把每个关键二进制的 ELF Machine 与 DT_NEEDED
/// 抓出来，让用户在真机上一眼看清「哪些已经原生、哪些还在模拟」，
/// 再决定是否落位原生产物（落位逻辑见同级安装流程）。
///
/// ⚠️ 与 QEMU 兼容层的关系：两者是**可切换的并行后端**，不是替代关系。
/// 体检结果同时会标出哪些文件已被 QEMU 转发脚本接管（.foa-real + wrapper），
/// 方便卸载/回滚。
class NativeArm64 {
  static const String flutterHome = '/opt/flutter';
  static const String sdkHome = '/opt/android-sdk';
  static const String jdkHome = '/opt/jdk';

  /// 原生产物落位目录（bionic 链接的 gen_snapshot 等单独放，避免污染 SDK）。
  static const String nativeDir = '/opt/foa-native';

  /// 需要原生化的 Android build-tools 二进制。
  static const List<String> sdkBinaries = <String>[
    'aapt2',
    'aidl',
    'zipalign',
    'split-select',
  ];

  // ---------------- 容器内体检脚本 ----------------

  /// 体检脚本（@TOKEN@ 由 Dart 侧替换）。
  ///
  /// 输出两类行：
  /// - `KEY=value`：UNAME / READELF / DARTVER / BUILD_TOOLS / NATIVE_DIR
  /// - `P<TAB>name<TAB>path<TAB>kind<TAB>machine<TAB>needed<TAB>approx`
  ///
  /// 实现说明（为什么不用 `readelf` 一把梭）：rootfs 是 Debian minbase，
  /// **不带 binutils**。因此：
  /// - Machine 一律用 `dd` 读 ELF 头第 18～19 字节（e_machine）判定，
  ///   不依赖任何外部工具：0x3e=x86-64，0xb7=aarch64，0x28=arm(32)；
  /// - DT_NEEDED 优先用 `readelf -d`（精确）；没有 readelf 时退化为
  ///   字符串粗扫（`grep -a`），结果标记 approx=yes，UI 上如实标注。
  static const String _auditScript = r'''
echo "UNAME=$(uname -m 2>/dev/null)"
if command -v readelf >/dev/null 2>&1; then echo "READELF=yes"; else echo "READELF=no"; fi
echo "DARTVER=$(timeout 90 @FLUTTER@/bin/cache/dart-sdk/bin/dart --version 2>&1 | head -1)"
BT=$(ls -d @SDK@/build-tools/* 2>/dev/null | sort -V | tail -1)
echo "BUILD_TOOLS=$BT"
if [ -d @NATIVE@ ]; then echo "NATIVE_DIR=yes"; else echo "NATIVE_DIR=no"; fi

probe() {
  n=$1; p=$2
  if [ ! -e "$p" ]; then printf 'P\t%s\t%s\tmissing\t-\t-\tno\n' "$n" "$p"; return; fi
  if [ -d "$p" ]; then printf 'P\t%s\t%s\tdir\t-\t-\tno\n' "$n" "$p"; return; fi
  h=$(dd if="$p" bs=1 count=2 2>/dev/null)
  case "$h" in
    '#!'*)
      if grep -a -q 'qemu' "$p" 2>/dev/null; then
        printf 'P\t%s\t%s\tqemu\t-\t-\tno\n' "$n" "$p"
      else
        printf 'P\t%s\t%s\tscript\t-\t-\tno\n' "$n" "$p"
      fi
      return
      ;;
  esac
  # ELF 魔数 7f 45 4c 46；不是 ELF 就归为数据文件（快照、jar、zip…）
  case "$(od -An -tx1 -N 4 "$p" 2>/dev/null | tr -d ' \n')" in
    7f454c46*) ;;
    *)
      printf 'P\t%s\t%s\tdata\t-\t-\tno\n' "$n" "$p"
      return
      ;;
  esac
  # e_machine 位于偏移 18，小端 2 字节
  m=$(od -An -tx1 -j 18 -N 2 "$p" 2>/dev/null | tr -d ' \n')
  case "$m" in
    b700) mm=aarch64 ;;
    3e00) mm=x86-64 ;;
    0300) mm=i386 ;;
    2800) mm=arm ;;
    *) mm="unknown:$m" ;;
  esac
  if command -v readelf >/dev/null 2>&1; then
    nd=$(readelf -d "$p" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p' | tr '\n' ',')
    apx=no
  else
    nd=$(grep -a -o -E 'lib[A-Za-z0-9_.+-]*\.so(\.[0-9]+)*' "$p" 2>/dev/null | sort -u | head -8 | tr '\n' ',')
    apx=yes
  fi
  [ -n "$nd" ] || nd='-'
  printf 'P\t%s\t%s\telf\t%s\t%s\t%s\n' "$n" "$p" "$mm" "$nd" "$apx"
}

E=@FLUTTER@/bin/cache/artifacts/engine
probe 'dart' '@FLUTTER@/bin/cache/dart-sdk/bin/dart'
probe 'dart(原文件)' '@FLUTTER@/bin/cache/dart-sdk/bin/dart.foa-real'
probe 'gen_snapshot(arm64)' "$E/android-arm64-release/linux-arm64/gen_snapshot"
probe 'gen_snapshot(x64)' "$E/android-arm64-release/linux-x64/gen_snapshot"
probe 'flutter_tools.snapshot' '@FLUTTER@/bin/cache/flutter_tools.snapshot'
probe 'java' '@JDK@/bin/java'
probe 'aapt2' "$BT/aapt2"
probe 'aidl' "$BT/aidl"
probe 'zipalign' "$BT/zipalign"
probe 'split-select' "$BT/split-select"
probe 'adb' '@SDK@/platform-tools/adb'
if [ -d @NATIVE@ ]; then
  for f in @NATIVE@/*; do
    [ -f "$f" ] || continue
    probe "native:${f##*/}" "$f"
  done
fi
''';

  /// 轻量验证：原生产物是否已落位（供工具链页判断「原生后端已启用」）。
  ///
  /// 与 [audit] 的区别：只做一次存在性 + 架构断定，秒级返回；
  /// [audit] 会跑 `dart --version`（qemu 转发下可能十几秒）。
  static const String _verifyScript = r'''
[ -d @NATIVE@ ] || { echo __NOT_INSTALLED__; exit 0; }
n=0; bad=0
for b in aapt2 aidl zipalign split-select gen_snapshot; do
  f=@NATIVE@/$b
  if [ -f "$f" ] && [ "$(od -An -tx1 -j 18 -N 2 "$f" 2>/dev/null | tr -d ' \n')" = 'b700' ]; then
    n=$((n+1))
  else
    [ -f "$f" ] && bad=$((bad+1))
  fi
done
echo "NATIVE_OK=$n"
echo "NATIVE_BAD=$bad"
if [ "$(od -An -tx1 -j 18 -N 2 @FLUTTER@/bin/cache/dart-sdk/bin/dart 2>/dev/null | tr -d ' \n')" = 'b700' ]; then
  echo "DART=arm64"
else
  echo "DART=other"
fi
''';

  // ---------------- 体检入口 ----------------

  /// 跑一遍架构体检（只读，不修改任何文件）。
  static Future<NativeAudit> audit(ProotBridge bridge) async {
    final r = await bridge.exec(
      _auditScript
          .replaceAll('@FLUTTER@', flutterHome)
          .replaceAll('@SDK@', sdkHome)
          .replaceAll('@JDK@', jdkHome)
          .replaceAll('@NATIVE@', nativeDir),
      timeoutSec: 240,
    );
    return NativeAudit.parse(r.stdout, archNote: r.stderr.trim());
  }

  /// 轻量验证：返回一个人类可读摘要；未落位返回 null。
  static Future<String?> verify(ProotBridge bridge) async {
    final r = await bridge.exec(
      _verifyScript
          .replaceAll('@FLUTTER@', flutterHome)
          .replaceAll('@NATIVE@', nativeDir),
      timeoutSec: 60,
    );
    final out = r.stdout;
    if (out.contains('__NOT_INSTALLED__')) return null;

    String kv(String k) {
      for (final line in out.split('\n')) {
        if (line.startsWith('$k=')) return line.substring(k.length + 1).trim();
      }
      return '';
    }

    final ok = int.tryParse(kv('NATIVE_OK')) ?? 0;
    final bad = int.tryParse(kv('NATIVE_BAD')) ?? 0;
    if (ok == 0) return null;
    final dartArm = kv('DART') == 'arm64';
    return '原生产物 $ok 项（aarch64）'
        '${bad > 0 ? ' · $bad 项架构不符' : ''}'
        ' · dart ${dartArm ? 'arm64' : '非 arm64（flutter_tools 仍需重建快照）'}';
  }
}

/// arm64 原生版 Android build-tools 二进制（aapt2 / aidl / zipalign /
/// split-select）的下载、落位与回滚。
///
/// 来源：**Commit451/android-arm-build-tools**（MIT）。
/// 上游用 AOSP Soong 在 Debian 12（glibc 2.36 / GCC 12）上交叉编译出
/// linux-glibc-arm64 的四个二进制——正是 AGP/Gradle 在一次普通 app 构建里
/// 真正会 exec 的那四个（其余 apksigner/dx/d8 都是 Java，本来就不挑架构）。
///
/// 版本为什么钉 `platform-tools-36.0.0`：本项目 Android SDK 装的正是
/// build-tools 36.0.0，取同名 tag 可保证"声明的版本"与"实际二进制"一致，
/// 不给 AGP 留下版本错配的口子。上游还有 36.1.0 / 37.0.0（源自
/// android-17.0.0_r1），需要时改 [tag] 即可，但要同步改 SDK 里的
/// build-tools 目录。
///
/// 兼容性前提（上游 README，2026-09-18 核实）：需要 glibc 2.36+ 与
/// GLIBCXX_3.4.30+。本项目 rootfs 是 **Debian 12 bookworm**（glibc 2.36），
/// 正好踩线满足；但 minbase 只装 required 级包，`libstdc++6` 可能不在，
/// 所以落位前会补一次 apt 安装（见 [_runtimeLibsScript]）。
///
/// **关于镜像与校验**：GitHub Release 直连在国内经常抽风，因此额外挂两个
/// 第三方加速代理参与竞速。它们本质上是不受信任的中转——但下载后会做
/// **SHA-256 逐字节校验**（值取自 GitHub API 的 asset digest），
/// 所以代理即使被劫持也只能让我们"下载失败"，无法注入错误内容。
class NativeBuildTools {
  static const String upstream =
      'https://github.com/Commit451/android-arm-build-tools';
  static const String tag = 'platform-tools-36.0.0';
  static const String tarName =
      'android-build-tools-36.0.0-linux-arm64-20260522.tar.xz';
  static const int tarSize = 3330048; // GitHub API asset size
  static const String tarSha256 =
      'c95050308f13fad7b73a06ce304f474363a2d6b5054f1834109f0e84d980b7fa';
  static const String tarUrl =
      'https://github.com/Commit451/android-arm-build-tools/releases/'
      'download/platform-tools-36.0.0/$tarName';

  /// 竞速候选源（最快者胜；全部失败抛异常）。
  static List<MirrorSource> mirrors() => const [
        MirrorSource('GitHub 官方', tarUrl),
        MirrorSource('ghfast 加速', 'https://ghfast.top/$tarUrl'),
        MirrorSource('gh-proxy 加速', 'https://gh-proxy.com/$tarUrl'),
      ];

  // ---------------- 容器内脚本 ----------------

  /// 原生运行时库：AOSP 宿主二进制是 glibc + libstdc++ 链接的，
  /// minbase rootfs 默认没有 libstdc++6（priority=important，不在 required 里）。
  static const String _runtimeLibsScript = r'''
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock
if ! ldconfig -p 2>/dev/null | grep -q 'libstdc\.so\.6'; then
  apt-get update -qq -o Acquire::Retries=3 2>&1 | tail -n 10
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends -o Acquire::Retries=3 libstdc++6 zlib1g 2>&1 | tail -n 20
fi
ldconfig 2>/dev/null || true
echo LIBS_OK
''';

  /// 解包：tar 顶层目录名上游可能变（out/linux-arm64 或 linux-arm64），
  /// 因此用 `find -name aapt2` 定位，而不是假设路径。
  static const String _extractScript = r'''
set -e
T=@TAR@
D=@NATIVE@
[ -f "$T" ] || { echo NO_TARBALL; exit 2; }
rm -rf "$D/tmp"
mkdir -p "$D/tmp" "$D"
tar -xJf "$T" -C "$D/tmp"
B=$(find "$D/tmp" -name aapt2 -type f | head -1)
[ -n "$B" ] || { echo NO_AAPT2_IN_TARBALL; exit 3; }
BD=$(dirname "$B")
for f in aapt2 aidl zipalign split-select; do
  [ -f "$BD/$f" ] || continue
  install -m 755 "$BD/$f" "$D/$f"
done
# AOSP 宿主二进制可能 dlopen 自带的共享库（上游 out/linux-arm64/lib64）
if [ -d "$BD/lib64" ]; then rm -rf "$D/lib64"; cp -a "$BD/lib64" "$D/lib64"; fi
rm -rf "$D/tmp"
for f in aapt2 aidl zipalign split-select; do
  [ -f "$D/$f" ] || { echo "MISSING:$f"; exit 4; }
  m=$(od -An -tx1 -j 18 -N 2 "$D/$f" 2>/dev/null | tr -d ' \n')
  [ "$m" = 'b700' ] || { echo "NOT_ARM64:$f:$m"; exit 5; }
done
echo EXTRACT_OK
''';

  /// 落位到 build-tools：原件备份为 `.foa-x64`（**复制**而非改名，
  /// 这样 QEMU 兼容层的 `.foa-real` 依然完好，两个后端不会互相踩）。
  static const String _deployScript = r'''
BT=$(ls -d @SDK@/build-tools/* 2>/dev/null | sort -V | tail -1)
if [ -z "$BT" ] || [ ! -d "$BT" ]; then echo NO_BUILD_TOOLS; exit 6; fi
D=@NATIVE@
for f in aapt2 aidl zipalign split-select; do
  [ -f "$D/$f" ] || continue
  if [ -e "$BT/$f" ] && [ ! -e "$BT/$f.foa-x64" ]; then cp -a "$BT/$f" "$BT/$f.foa-x64"; fi
  cp -f "$D/$f" "$BT/$f"
  chmod 755 "$BT/$f"
done
if [ -d "$D/lib64" ]; then mkdir -p "$BT/lib64"; cp -a "$D/lib64/." "$BT/lib64/"; fi
out=$("$BT/aapt2" version 2>&1 | head -1)
case "$out" in
  '') echo 'SMOKE_FAIL:aapt2 无输出' ;;
  *'cannot execute'*|*'Exec format'*|*'error while loading shared libraries'*) echo "SMOKE_FAIL:$out" ;;
  *) echo "SMOKE_OK:$out" ;;
esac
z=$("$BT/zipalign" 2>&1 | head -1)
case "$z" in
  *'cannot execute'*|*'Exec format'*|*'error while loading shared libraries'*) echo "ZIPALIGN_FAIL:$z" ;;
  *) echo "ZIPALIGN_OK" ;;
esac
''';

  /// 回滚：把 `.foa-x64` 原件还原回 build-tools，删掉落位目录与下载缓存。
  static const String _uninstallScript = r'''
BT=$(ls -d @SDK@/build-tools/* 2>/dev/null | sort -V | tail -1)
if [ -n "$BT" ] && [ -d "$BT" ]; then
  for f in aapt2 aidl zipalign split-select; do
    if [ -e "$BT/$f.foa-x64" ]; then
      cp -a "$BT/$f.foa-x64" "$BT/$f"
      rm -f "$BT/$f.foa-x64"
    fi
  done
  rm -rf "$BT/lib64"
fi
rm -rf @NATIVE@ /opt/foa-dl/@TARNAME@
echo UNINSTALL_OK
''';

  // ---------------- 安装 ----------------

  /// 下载 + 落位 + 冒烟；返回一行结果摘要。
  static Future<String> install(
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
    await AptTools.ensure(bridge); // xz-utils（解 .tar.xz）+ unzip
    final libs = await bridge.exec(_runtimeLibsScript, timeoutSec: 600);
    if (!libs.stdout.contains('LIBS_OK')) {
      throw DownloadException(
        '安装原生运行库失败：'
        '${libs.stderr.trim().isEmpty ? libs.stdout.trim() : libs.stderr.trim()}',
      );
    }

    onPhase?.call('downloading');
    final ordered = await SdkDownloader.pickFastest(mirrors(), token: token);
    final dlDir = Directory('${env.rootfsPath}/opt/foa-dl');
    await dlDir.create(recursive: true);
    final save = '${dlDir.path}/$tarName';
    await SdkDownloader.downloadMultiSource(
      ordered,
      save,
      tarSize,
      segments: 2,
      sha256: tarSha256,
      token: token,
      onProgress: onProgress,
      onMirrorUsed: onMirrorUsed,
    );

    onPhase?.call('extracting');
    final ex = await bridge.exec(
      _extractScript
          .replaceAll('@TAR@', '/opt/foa-dl/$tarName')
          .replaceAll('@NATIVE@', NativeArm64.nativeDir),
      timeoutSec: 600,
    );
    if (!ex.stdout.contains('EXTRACT_OK')) {
      throw DownloadException(
        '解包失败：${ex.stdout.trim().isEmpty ? ex.stderr.trim() : ex.stdout.trim()}',
      );
    }

    onPhase?.call('deploying');
    final dp = await bridge.exec(
      _deployScript
          .replaceAll('@SDK@', NativeArm64.sdkHome)
          .replaceAll('@NATIVE@', NativeArm64.nativeDir),
      timeoutSec: 300,
    );
    final out = dp.stdout;
    if (out.contains('NO_BUILD_TOOLS')) {
      throw DownloadException(
          '未找到 Android SDK build-tools，请先安装 Android SDK');
    }
    if (out.contains('SMOKE_FAIL') || out.contains('ZIPALIGN_FAIL')) {
      throw DownloadException('原生二进制冒烟失败：$out');
    }
    // AGP 9.x 默认从 Maven 拉 x86_64 aapt2，必须指回本地；
    // 与 QEMU 后端写的是同一条路径，只是此刻内容是原生 arm64。
    await QemuCompat.writeAapt2Override(env.rootfsPath);

    final smoke = out
        .split('\n')
        .firstWhere((l) => l.startsWith('SMOKE_OK:'), orElse: () => '')
        .replaceFirst('SMOKE_OK:', '');
    return 'aapt2/aidl/zipalign/split-select 已原生化 · ${smoke.trim()}';
  }

  /// 本地导入兜底：用户用系统文件选择器指认已下载好的 tar.xz。
  static Future<String> installFromLocalFile(
    ProotBridge bridge,
    EnvInfo env,
    String localPath, {
    void Function(String phase)? onPhase,
  }) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装，请先在主页初始化环境');
    }
    final src = File(localPath);
    if (!await src.exists()) {
      throw DownloadException('本地文件不存在：$localPath');
    }
    final len = await src.length();
    final name =
        src.uri.pathSegments.isEmpty ? '' : src.uri.pathSegments.last;
    if (name != tarName && len != tarSize) {
      throw DownloadException(
        '无法识别所选文件：需要 $tarName（$tarSize 字节）',
      );
    }
    onPhase?.call('importing');
    final dlDir = Directory('${env.rootfsPath}/opt/foa-dl');
    await dlDir.create(recursive: true);
    final dst = '${dlDir.path}/$tarName';
    await src.copy(dst);
    await src.delete();
    if (!await SdkDownloader.verifySha256(dst, tarSha256)) {
      await File(dst).delete();
      throw DownloadException('SHA-256 校验失败，文件可能损坏');
    }
    onPhase?.call('apt');
    await AptTools.ensure(bridge);
    await bridge.exec(_runtimeLibsScript, timeoutSec: 600);
    onPhase?.call('extracting');
    final ex = await bridge.exec(
      _extractScript
          .replaceAll('@TAR@', '/opt/foa-dl/$tarName')
          .replaceAll('@NATIVE@', NativeArm64.nativeDir),
      timeoutSec: 600,
    );
    if (!ex.stdout.contains('EXTRACT_OK')) {
      throw DownloadException('解包失败：${ex.stdout.trim()}');
    }
    onPhase?.call('deploying');
    final dp = await bridge.exec(
      _deployScript
          .replaceAll('@SDK@', NativeArm64.sdkHome)
          .replaceAll('@NATIVE@', NativeArm64.nativeDir),
      timeoutSec: 300,
    );
    if (dp.stdout.contains('NO_BUILD_TOOLS')) {
      throw DownloadException('未找到 Android SDK build-tools，请先安装 Android SDK');
    }
    if (dp.stdout.contains('SMOKE_FAIL')) {
      throw DownloadException('原生二进制冒烟失败：${dp.stdout.trim()}');
    }
    await QemuCompat.writeAapt2Override(env.rootfsPath);
    return '已从本地文件导入并原生化';
  }

  /// 卸载：还原 build-tools 原件 + 删除落位目录。
  static Future<void> uninstall(ProotBridge bridge, EnvInfo env) async {
    final r = await bridge.exec(
      _uninstallScript
          .replaceAll('@SDK@', NativeArm64.sdkHome)
          .replaceAll('@NATIVE@', NativeArm64.nativeDir)
          .replaceAll('@TARNAME@', tarName),
      timeoutSec: 300,
    );
    if (!r.stdout.contains('UNINSTALL_OK')) {
      throw DownloadException(
        '原生 build-tools 卸载失败：'
        '${r.stdout.trim().isEmpty ? r.stderr.trim() : r.stdout.trim()}',
      );
    }
    // 只有 QEMU 兼容层也没在用的时候才摘掉覆盖项
    final q = await QemuCompat.verify(bridge);
    if (q == null) await QemuCompat.removeAapt2Override(env.rootfsPath);
  }
}

/// 原生 `gen_snapshot` 的导入与验证。
///
/// 这是整条原生链上**唯一的硬缺口**：Google 不发布 linux-arm64 的
/// gen_snapshot（Flutter 的 AOT 编译器前端），所以只能取第三方移植版。
///
/// ⚠️ 两个必须知道的前提：
/// 1. **链接的是 bionic 还是 glibc**：Termux 系移植（如 ImL1s/termux-flutter）
///    是 bionic 链接的，INTERP 为 `/system/bin/linker64`，libc 来自
///    `/apex/com.android.runtime/lib64/bionic`。在 Debian(glibc) 容器里
///    必须能看到 `/system`、`/apex` 才能跑——原生侧已按落位标记自动追加
///    这两个挂载与库搜索路径（见 MainActivity.buildProotCmd / libraryPath）。
/// 2. **Termux 私有库**：若它 NEEDED 了 Termux 的 `libandroid-shmem.so`
///    之类，容器内还得有对应 .so，冒烟测试会把它点名报出来。
///
/// 因此本类**不提供自动下载**（体积 600MB+ 的 deb 且无法在沙箱内校验），
/// 走「用户自己取文件 → 本地导入 → 架构校验 → 实跑冒烟」；
/// 冒烟不过就当场撤销落位（连带 proot 的挂载自动失效，不会留下半吊子状态）。
class NativeGenSnapshot {
  /// 相对 rootfs 的落位路径（同时是原生侧的"是否启用"标记）。
  static const String guestPath = '${NativeArm64.nativeDir}/gen_snapshot';

  /// 校验 + 冒烟。
  static const String _checkScript = r'''
F=@NATIVE@/gen_snapshot
[ -f "$F" ] || { echo NO_FILE; exit 2; }
m=$(od -An -tx1 -j 18 -N 2 "$F" 2>/dev/null | tr -d ' \n')
[ "$m" = 'b700' ] || { echo "NOT_ARM64:$m"; exit 3; }
# ELF INTERP：判断是 bionic（/system/bin/linker64）还是 glibc（/lib/ld-linux-aarch64.so.1）
IT=$(grep -a -o -m1 -E '/(system/bin/linker64|lib/ld-linux-aarch64\.so\.1|lib64/ld-linux-x86-64\.so\.2)' "$F" 2>/dev/null | head -1)
echo "INTERP=${IT:-unknown}"
out=$("$F" --help 2>&1 | head -3)
case "$out" in
  '') echo 'SMOKE_EMPTY' ;;
  *'cannot execute'*|*'Exec format'*|*'No such file or directory'*|*'CANNOT LINK'*|*'not found'*|*'error while loading shared libraries'*) echo "SMOKE_FAIL:$out" ;;
  *) echo "SMOKE_OK:$out" ;;
esac
''';

  /// 导入本地 gen_snapshot 文件：校验 → 冒烟 → 失败即撤销。
  static Future<String> importFromLocalFile(
    ProotBridge bridge,
    EnvInfo env,
    String localPath,
  ) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装，请先在主页初始化环境');
    }
    final src = File(localPath);
    if (!await src.exists()) {
      throw DownloadException('本地文件不存在：$localPath');
    }
    final dir = Directory('${env.rootfsPath}${NativeArm64.nativeDir}');
    await dir.create(recursive: true);
    final dst = '${env.rootfsPath}/$guestPath';
    await src.copy(dst);
    await src.delete();
    await bridge.exec('chmod 755 $guestPath', timeoutSec: 30);

    final r = await bridge.exec(
      _checkScript.replaceAll('@NATIVE@', NativeArm64.nativeDir),
      timeoutSec: 120,
    );
    final out = r.stdout;
    String interp = 'unknown';
    for (final line in out.split('\n')) {
      if (line.startsWith('INTERP=')) interp = line.substring(7).trim();
    }
    if (!out.contains('SMOKE_OK')) {
      // 冒烟不过 → 撤销落位（原生侧的 /system /apex 挂载随之自动失效）
      await bridge.exec('rm -f $guestPath', timeoutSec: 30);
      final detail = out.trim().isEmpty ? r.stderr.trim() : out.trim();
      final hint = switch (interp) {
        'unknown' => '无法确定动态链接器',
        '/system/bin/linker64' =>
          '这是 bionic 链接的二进制，需要容器内可见 /system 与 /apex；'
              '若已自动挂载仍失败，多半是它的 DT_NEEDED 里有 Termux 私有库（见报错里的库名）。',
        _ => '这是 glibc 链接的二进制，应与 Debian 容器兼容；请看下方的原始报错。',
      };
      throw DownloadException('gen_snapshot 冒烟失败（已撤销落位）\n$hint\n$detail');
    }
    final smoke =
        out.split('\n').firstWhere((l) => l.startsWith('SMOKE_OK:'), orElse: () => '');
    return 'gen_snapshot 已原生化（INTERP=$interp）\n'
        '${smoke.replaceFirst('SMOKE_OK:', '').trim()}';
  }

  /// 撤销：删除落位文件（原生侧挂载自动失效）。
  static Future<void> uninstall(ProotBridge bridge) async {
    final r = await bridge.exec(
      'rm -f $guestPath && echo GEN_UNINSTALL_OK',
      timeoutSec: 60,
    );
    if (!r.stdout.contains('GEN_UNINSTALL_OK')) {
      throw DownloadException(
        'gen_snapshot 卸载失败：${r.stderr.trim().isEmpty ? r.stdout.trim() : r.stderr.trim()}',
      );
    }
  }
}

/// 探测项的形态。
enum NativeProbeKind {
  /// 真实 ELF 可执行文件。
  elf,

  /// QEMU 转发脚本（x64 兼容层生成，内部 `exec qemu-x86_64-static …`）。
  qemuWrapper,

  /// 其它脚本（flutter 的 bash 启动器、gradle 的 sh 启动器…）。
  script,

  /// 非 ELF 非脚本的数据文件（如 app-jit 快照）。
  data,

  /// 目录。
  dir,

  /// 不存在。
  missing,
}

extension NativeProbeKindX on NativeProbeKind {
  String get label => switch (this) {
        NativeProbeKind.elf => 'ELF',
        NativeProbeKind.qemuWrapper => 'QEMU 转发',
        NativeProbeKind.script => '脚本',
        NativeProbeKind.data => '数据',
        NativeProbeKind.dir => '目录',
        NativeProbeKind.missing => '缺失',
      };
}

/// 单个体检项。
class NativeProbe {
  /// 展示名（如 `dart`、`gen_snapshot(arm64)`、`native:gen_snapshot`）。
  final String name;

  /// 容器内绝对路径。
  final String path;

  final NativeProbeKind kind;

  /// ELF Machine：`aarch64` / `x86-64` / `i386` / `arm` / `-`。
  final String machine;

  /// DT_NEEDED 列表（readelf 精确，或字符串粗扫的近似结果）。
  final List<String> needed;

  /// true = [needed] 来自字符串粗扫（容器内无 readelf，未装 binutils）。
  final bool neededApprox;

  const NativeProbe({
    required this.name,
    required this.path,
    required this.kind,
    required this.machine,
    required this.needed,
    required this.neededApprox,
  });

  /// 是 aarch64 原生 ELF。
  bool get native => kind == NativeProbeKind.elf && machine == 'aarch64';

  /// 是 x86-64 ELF（在 aarch64 上直跑必然 Exec format error）。
  bool get x64 => kind == NativeProbeKind.elf && machine == 'x86-64';

  /// 链接的是 Android bionic（Termux 产物的典型特征）。
  ///
  /// 判据：DT_NEEDED 里出现**无版本号后缀**的 `libc.so` / `libm.so` /
  /// `libdl.so`——glibc 一律是 `libc.so.6` 这种带版本的形式。
  bool get bionicLink =>
      needed.any((s) => s == 'libc.so' || s == 'libm.so' || s == 'libdl.so');

  /// 链接的是 glibc（`libc.so.6`）。
  bool get glibcLink => needed.any((s) => s.startsWith('libc.so.'));

  /// 一行摘要，如 `aarch64 · bionic · libc.so,libm.so`。
  String get summary {
    if (kind != NativeProbeKind.elf) return kind.label;
    final link = bionicLink
        ? 'bionic'
        : (glibcLink ? 'glibc' : (needed.isEmpty ? '?' : '?'));
    final nd = needed.isEmpty
        ? ''
        : ' · ${needed.take(4).join(',')}${needed.length > 4 ? '…' : ''}';
    return '$machine · $link$nd${neededApprox ? ' · 粗扫' : ''}';
  }
}

/// 一次体检的结果。
class NativeAudit {
  /// `uname -m`（宿主/容器 CPU 架构，应为 aarch64）。
  final String unameMachine;

  /// 容器内是否有 readelf（决定 DT_NEEDED 是否精确）。
  final bool readelfAvailable;

  /// `dart --version` 首行，形如 `Dart SDK version: 3.9.0 (stable) on "linux_x64"`。
  final String dartVersionLine;

  /// 实测到的 build-tools 目录（如 `/opt/android-sdk/build-tools/36.0.0`）。
  final String buildToolsDir;

  /// 原生产物目录是否已存在。
  final bool nativeDirPresent;

  final List<NativeProbe> probes;

  /// 执行过程中的额外说明（stderr 摘要）。
  final String note;

  const NativeAudit({
    required this.unameMachine,
    required this.readelfAvailable,
    required this.dartVersionLine,
    required this.buildToolsDir,
    required this.nativeDirPresent,
    required this.probes,
    this.note = '',
  });

  /// 解析体检脚本输出。
  factory NativeAudit.parse(String out, {String archNote = ''}) {
    String uname = '';
    var readelf = false;
    var dartVer = '';
    var bt = '';
    var nativeDir = false;
    final probes = <NativeProbe>[];

    for (final raw in out.split('\n')) {
      final line = raw.trimRight();
      if (line.startsWith('P\t')) {
        final f = line.split('\t');
        if (f.length < 7) continue;
        final needed = f[5] == '-'
            ? const <String>[]
            : f[5]
                .split(',')
                .where((s) => s.isNotEmpty)
                .toList(growable: false);
        probes.add(NativeProbe(
          name: f[1],
          path: f[2],
          kind: _kindOf(f[3]),
          machine: f[4],
          needed: needed,
          neededApprox: f[6] == 'yes',
        ));
        continue;
      }
      if (line.startsWith('UNAME=')) uname = line.substring(6).trim();
      if (line.startsWith('READELF=')) readelf = line.substring(8).trim() == 'yes';
      if (line.startsWith('DARTVER=')) dartVer = line.substring(8).trim();
      if (line.startsWith('BUILD_TOOLS=')) bt = line.substring(12).trim();
      if (line.startsWith('NATIVE_DIR=')) {
        nativeDir = line.substring(11).trim() == 'yes';
      }
    }
    return NativeAudit(
      unameMachine: uname,
      readelfAvailable: readelf,
      dartVersionLine: dartVer,
      buildToolsDir: bt,
      nativeDirPresent: nativeDir,
      probes: probes,
      note: archNote,
    );
  }

  static NativeProbeKind _kindOf(String s) => switch (s) {
        'elf' => NativeProbeKind.elf,
        'qemu' => NativeProbeKind.qemuWrapper,
        'script' => NativeProbeKind.script,
        'data' => NativeProbeKind.data,
        'dir' => NativeProbeKind.dir,
        _ => NativeProbeKind.missing,
      };

  NativeProbe? probe(String name) {
    for (final p in probes) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// dart VM 报告的目标架构（`linux_arm64` / `linux_x64`），取不到则空串。
  ///
  /// 这是判断 `flutter_tools.snapshot` 能否被当前 dart 加载的关键：
  /// app-jit 快照**内含机器码**，架构必须一致，否则报
  /// "Snapshot not compatible"。
  String get dartTargetArch {
    final m = RegExp(r'on\s+"?([a-z0-9_]+)"?').firstMatch(dartVersionLine);
    return m?.group(1) ?? '';
  }

  /// 总览一行，如 `aarch64 · 原生 3 / x64 4 / QEMU 转发 2 / 缺失 1`。
  String get overview {
    final n = probes.where((p) => p.native).length;
    final x = probes.where((p) => p.x64).length;
    final q = probes.where((p) => p.kind == NativeProbeKind.qemuWrapper).length;
    final m = probes.where((p) => p.kind == NativeProbeKind.missing).length;
    return '${unameMachine.isEmpty ? '?' : unameMachine} · '
        '原生 $n / x64 $x / QEMU 转发 $q / 缺失 $m';
  }

  /// 构建链上**必须原生**的项是否全部就绪。
  ///
  /// 判据（aidl / split-select 不计入：普通 Flutter 工程一般不用 aidl，
  /// split-select 只在多 ABI 拆分时用到，缺失不阻断构建）：
  /// - `dart` 本身是 aarch64 ELF；
  /// - dart 报告的架构是 linux_arm64（意味着快照匹配，或已被 arm64 重建）；
  /// - `gen_snapshot` 有 aarch64 版本（arm64 目录或原生目录均可）；
  /// - `aapt2` / `zipalign` 是 aarch64 ELF。
  bool get buildReady {
    bool ok(String name) => probe(name)?.native == true;
    final dartOk = ok('dart');
    final archOk = dartTargetArch.contains('arm64');
    final gsOk = ok('gen_snapshot(arm64)') || ok('native:gen_snapshot');
    return dartOk && archOk && gsOk && ok('aapt2') && ok('zipalign');
  }
}
