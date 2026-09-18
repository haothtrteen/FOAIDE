import 'dart:io';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'sdk_downloader.dart';

/// Android SDK 组件（版本/文件名/大小/SHA-1 来自 repo2-3.xml，2026-09-17 抓取）。
class AndroidSdkComponent {
  final String id; // 显示名，如 'platforms;android-36'
  final String file; // zip 文件名
  final int size; // 字节
  final String sha1; // repo2-3.xml checksum（SHA-1）
  final String guestDir; // $ANDROID_HOME 下的目标目录
  final String keyPath; // 解压后关键文件（相对 $sdkHome），逐组件校验用
  final String keyTest; // 校验方式：'x' 可执行 / 'f' 普通文件

  const AndroidSdkComponent({
    required this.id,
    required this.file,
    required this.size,
    required this.sha1,
    required this.guestDir,
    required this.keyPath,
    required this.keyTest,
  });
}

/// 容器内 apt 工具保障：rootfs（Debian minbase）自带 tar 但无 xz/unzip。
/// rootfs 内置 TUNA 清华 apt 源（2026-09-17 沙箱解包确认），
/// 因此 `apt-get install -y xz-utils unzip` 走国内镜像，无需额外配置。
class AptTools {
  /// Bug 404 兜底（2026-09-17 真机抓到）：旧 rootfs 打包时 /etc/passwd、/etc/group
  /// 处于 dpkg 重写中间态（缺失），apt 报 "No sandbox user '_apt'"、无法降权、
  /// 源签名验证失败 → xz-utils/unzip 装不上。每次幂等补齐标准 Debian 骨架
  /// （含 _apt/messagebus 用户）与 /etc/hosts，并确保 /tmp、apt lists 目录可写。
  /// 新 rootfs 资产已含这些文件，此段对存量用户生效。
  static const String _fixAccounts = '''
mkdir -p /tmp && chmod 1777 /tmp
mkdir -p /var/lib/apt/lists/partial /var/cache/apt/archives/partial
if [ ! -f /etc/passwd ] || ! grep -q '^_apt:' /etc/passwd 2>/dev/null; then
  cat > /etc/passwd <<'PASSWD'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
sync:x:4:65534:sync:/bin:/bin/sync
games:x:5:60:games:/usr/games:/usr/sbin/nologin
man:x:6:12:man:/var/cache/man:/usr/sbin/nologin
lp:x:7:7:lp:/var/spool/lpd:/usr/sbin/nologin
mail:x:8:8:mail:/var/mail:/usr/sbin/nologin
news:x:9:9:news:/var/spool/news:/usr/sbin/nologin
uucp:x:10:10:uucp:/var/spool/uucp:/usr/sbin/nologin
proxy:x:13:13:proxy:/bin:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
backup:x:34:34:backup:/var/backups:/usr/sbin/nologin
list:x:38:38:Mailing List Manager:/var/list:/usr/sbin/nologin
irc:x:39:39:ircd:/run/ircd:/usr/sbin/nologin
gnats:x:41:41:Gnats Bug-Reporting System (admin):/var/lib/gnats:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
_apt:x:100:65534::/nonexistent:/usr/sbin/nologin
systemd-network:x:101:102:systemd Network Management,,,:/run/systemd:/usr/sbin/nologin
systemd-resolve:x:102:103:systemd Resolver,,,:/run/systemd:/usr/sbin/nologin
messagebus:x:103:104::/nonexistent:/usr/sbin/nologin
PASSWD
fi
if [ ! -f /etc/group ] || ! grep -q '^_apt:' /etc/group 2>/dev/null; then
  cat > /etc/group <<'GROUP'
root:x:0:
daemon:x:1:
bin:x:2:
sys:x:3:
adm:x:4:
tty:x:5:
disk:x:6:
lp:x:7:
mail:x:8:
news:x:9:
uucp:x:10:
man:x:12:
proxy:x:13:
kmem:x:15:
dialout:x:20:
fax:x:21:
voice:x:22:
cdrom:x:24:
floppy:x:25:
tape:x:26:
sudo:x:27:
audio:x:29:
dip:x:30:
www-data:x:33:
backup:x:34:
operator:x:37:
list:x:38:
irc:x:39:
src:x:40:
gnats:x:41:
shadow:x:42:
utmp:x:43:
video:x:44:
sasl:x:45:
plugdev:x:46:
staff:x:50:
games:x:60:
users:x:100:
nogroup:x:65534:
systemd-journal:x:101:
systemd-network:x:102:
systemd-resolve:x:103:
messagebus:x:104:
_apt:x:105:
GROUP
fi
[ -f /etc/hosts ] || printf '127.0.0.1 localhost\\n::1 localhost ip6-localhost ip6-loopback\\n127.0.1.1 foa\\n' > /etc/hosts
''';

  static Future<void> ensure(ProotBridge bridge) async {
    final check = await bridge.exec(
      'command -v xz >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 '
      '&& echo APT_TOOLS_OK',
      timeoutSec: 30,
    );
    if (check.ok && check.stdout.contains('APT_TOOLS_OK')) return;
    // Bug 402（2026-09-17 真机抓到）：rootfs 内 resolv.conf 是构建机内网 DNS，
    // 真机容器 DNS 不通 → apt 失败。MainActivity exec 引导已幂等修正 resolv.conf；
    // 这里不再把 apt 输出丢进 /dev/null——失败详情（2>&1 | tail）要能透传给用户。
    // Bug 404 修复（2026-09-17）：命令间用换行分隔，不能用行首 `;`——
    // POSIX sh 里 `;` 前必须紧跟命令，`fi\n; apt-get` 会报
    // "Syntax error: ";" unexpected"（用户真机抓到的第 78 行语法错误）。
    // Bug 409 修复（2026-09-17 真机抓到）：此前失败的安装尝试把 dpkg 数据库留在
    // 半安装中间态，apt 报 "E: dpkg was interrupted, you must manually run
    // 'dpkg --configure -a'"。恢复三步（幂等、失败不阻断后续命令）：
    //   1. 清陈旧锁文件（exec 超时/取消杀进程后残留；proot 单线程执行无并发风险）
    //   2. dpkg --configure -a 补完未完成的解包/配置
    //   3. apt-get -f install 修复破损依赖
    final r = await bridge.exec(
      '$_fixAccounts\n'
      'rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock '
      '/var/cache/apt/archives/lock /var/lib/apt/lists/lock\n'
      'DEBIAN_FRONTEND=noninteractive dpkg --configure -a 2>&1 | tail -n 20\n'
      'DEBIAN_FRONTEND=noninteractive apt-get -f install -y -qq '
      '--no-install-recommends 2>&1 | tail -n 20\n'
      'apt-get update -qq -o Acquire::Retries=3 2>&1 | tail -n 30\n'
      'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq '
      '--no-install-recommends -o Acquire::Retries=3 xz-utils unzip 2>&1 | tail -n 40\n'
      'command -v xz >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 '
      '&& echo APT_TOOLS_OK',
      timeoutSec: 600,
    );
    if (!r.ok || !r.stdout.contains('APT_TOOLS_OK')) {
      throw DownloadException(
        'apt 安装 xz-utils/unzip 失败（请确认容器内网络可用，apt 源为 TUNA 清华；'
        '若反复失败可先在终端跑 dpkg --configure -a 后重试，或用「从本地存储选择安装」兜底）：'
        '${r.stderr.trim().isEmpty ? r.stdout.trim() : r.stderr.trim()}',
      );
    }
  }
}

/// Android SDK 安装编排：4 个组件逐个「腾讯云镜像优先 → dl.google.com 兜底」
/// 竞速选源 → 分段并发下载（SHA-1 校验）→ 容器内 unzip 解压归位 → 预置 licenses。
///
/// 版本选择（与 Flutter 3.47.4 的 compileSdk 36 对齐）：
/// - platform-tools r37.0.1（adb 等）
/// - platforms;android-36（compileSdk 36 需要 android.jar）
/// - build-tools;36.0.0（aapt2/d8/zipalign 等）
/// - cmdline-tools;latest（sdkmanager 等，flutter doctor 需要）
///
/// 2026-09-17 沙箱实测镜像可用性：腾讯云 `mirrors.cloud.tencent.com/AndroidSDK/`
/// 四个文件均支持 Range（206）；TUNA AndroidSDK 404、华为云 android_repository
/// 对本沙箱返回 401（存疑），故国内源仅收录腾讯云。
class AndroidSdkInstaller {
  static const String sdkHome = '/opt/android-sdk';

  static const List<AndroidSdkComponent> components = [
    AndroidSdkComponent(
      id: 'platform-tools',
      file: 'platform-tools_r37.0.1-linux.zip',
      size: 9054187,
      sha1: '477254aa5f903c15cf51001717bdf347fb6b53e0',
      guestDir: 'platform-tools',
      keyPath: 'platform-tools/adb',
      keyTest: 'x',
    ),
    AndroidSdkComponent(
      id: 'platforms;android-36',
      file: 'platform-36_r02.zip',
      size: 65878410,
      sha1: '2c1a80dd4d9f7d0e6dd336ec603d9b5c55a6f576',
      guestDir: 'platforms/android-36',
      keyPath: 'platforms/android-36/android.jar',
      keyTest: 'f',
    ),
    AndroidSdkComponent(
      id: 'build-tools;36.0.0',
      file: 'build-tools_r36_linux.zip',
      size: 63737259,
      sha1: 'b0b6376977657e8ad9b969bacf4093601da2c6fb',
      guestDir: 'build-tools/36.0.0',
      // ⚠️ Google 归档怪癖（2026-09-17 实测）：build-tools_r36_linux.zip
      // 顶层目录是 android-16（历史命名沿袭），解压后靠「取顶层条目改名归位」
      // 落到 build-tools/36.0.0；关键文件 aapt2 在 zip 内为 android-16/aapt2。
      keyPath: 'build-tools/36.0.0/aapt2',
      keyTest: 'x',
    ),
    AndroidSdkComponent(
      id: 'cmdline-tools;latest',
      file: 'commandlinetools-linux-16111833_latest.zip',
      size: 181052239,
      sha1: 'e025545c62a8e64c7559119566a569fb1dec5f60',
      guestDir: 'cmdline-tools/latest',
      keyPath: 'cmdline-tools/latest/bin/sdkmanager',
      keyTest: 'x',
    ),
  ];

  static int get totalSize => components.fold(0, (s, c) => s + c.size);

  static List<MirrorSource> domesticMirrors(String file) => [
        MirrorSource(
          '腾讯云',
          'https://mirrors.cloud.tencent.com/AndroidSDK/$file',
        ),
      ];

  static List<MirrorSource> foreignMirrors(String file) => [
        MirrorSource(
          'Google 官方',
          'https://dl.google.com/android/repository/$file',
        ),
      ];

  /// 诊断：逐项检查 4 个关键文件，返回缺失路径清单（空 = 全部就位）。
  /// 把「关键组件缺失」从笼统报错升级为精确到文件的缺失列表，
  /// 便于用户一眼定位缺哪个组件（Bug 417，2026-09-17 真机）。
  static Future<List<String>> diagnose(ProotBridge bridge) async {
    final r = await bridge.exec(
      'for p in '
      '$sdkHome/platform-tools/adb '
      '$sdkHome/build-tools/36.0.0/aapt2 '
      '$sdkHome/platforms/android-36/android.jar '
      '$sdkHome/licenses/android-sdk-license; do '
      '[ -e "\$p" ] && echo "OK \$p" || echo "MISS \$p"; done',
      timeoutSec: 60,
    );
    final missing = <String>[];
    for (final line in r.stdout.split('\n')) {
      final t = line.trim();
      if (t.startsWith('MISS ')) missing.add(t.substring(5));
    }
    return missing;
  }

  /// 重新验证：四查关键文件 + adb 版本冒烟。
  /// 返回 null 表示未完整安装（缺文件），与相位模型兼容；
  /// 缺失明细用 [diagnose] 获取。
  static Future<String?> verify(ProotBridge bridge) async {
    final miss = await diagnose(bridge);
    if (miss.isNotEmpty) return null;
    final r = await bridge.exec(
      '$sdkHome/platform-tools/adb --version 2>&1 | head -1',
      timeoutSec: 60,
    );
    final v = r.stdout.trim();
    if (v.isEmpty) return 'Android SDK 已安装（adb 版本未知）';
    // aapt2/adb 为 x64 宿主二进制：兼容层未装/已卸载时 Exec format error，
    // 返回「需兼容层」提示而非把报错当版本号（避免"已安装"假象）。
    if (v.contains('cannot execute') ||
        v.contains('Exec format') ||
        v.contains('error while loading shared libraries')) {
      return 'Android SDK 已安装（x64 工具需先应用「x64 兼容层(QEMU)」）';
    }
    return v;
  }

  /// 完整安装：apt 工具 → 逐组件下载（快路径跳过）→ unzip 归位 → licenses → 验证。
  static Future<String> install(
    ProotBridge bridge,
    EnvInfo env, {
    void Function(String phase)? onPhase,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorUsed,
    DownloadCancelToken? token,
  }) {
    return _installCommon(bridge, env,
        onPhase: onPhase,
        onProgress: onProgress,
        onMirrorUsed: onMirrorUsed,
        token: token);
  }

  /// 本地安装兜底（2026-09-17）：用户用系统文件选择器指定某个组件 zip
  /// （Android SDK 共 4 个组件，可逐个导入）。按文件名/大小匹配组件，
  /// SHA-1 校验通过后拷贝进下载缓存，其余组件仍走网络下载。
  static Future<String> installFromLocalFile(
    ProotBridge bridge,
    EnvInfo env,
    String localPath, {
    void Function(String phase)? onPhase,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorUsed,
    DownloadCancelToken? token,
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
    AndroidSdkComponent? c;
    for (final x in components) {
      if (x.file == name) {
        c = x;
        break;
      }
    }
    if (c == null) {
      for (final x in components) {
        if (x.size == len) {
          c = x;
          break;
        }
      }
    }
    if (c == null) {
      throw DownloadException(
        '无法识别所选文件：需要 Android SDK 组件 zip（platform-tools / '
        'platforms;android-36 / build-tools 36.0.0 / cmdline-tools）。\n'
        '期望大小：${components.map((x) => '${x.file}=${x.size}B').join('，')}',
      );
    }
    onPhase?.call('importing');
    final dlDir = Directory('${env.rootfsPath}/opt/foa-dl');
    await dlDir.create(recursive: true);
    final zipPath = '${dlDir.path}/${c.file}';
    await src.copy(zipPath);
    await src.delete(); // 释放 filesDir/imports 空间
    final ok = await SdkDownloader.verifySha1(zipPath, c.sha1);
    if (!ok) {
      await File(zipPath).delete();
      throw DownloadException(
        'SHA-1 校验失败：所选文件不是 ${c.id}（${c.file}），或文件已损坏',
      );
    }
    return _installCommon(bridge, env,
        onPhase: onPhase,
        onProgress: onProgress,
        onMirrorUsed: onMirrorUsed,
        token: token);
  }

  /// 安装主流程（网络下载 / 本地导入共用）：apt 工具保障 → 逐组件处理
  /// （已就位且校验通过的组件走快路径跳过下载）→ licenses → 验证。
  static Future<String> _installCommon(
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

    final dlDir = Directory('${env.rootfsPath}/opt/foa-dl');
    await dlDir.create(recursive: true);

    for (var i = 0; i < components.length; i++) {
      final c = components[i];
      final zipPath = '${dlDir.path}/${c.file}';

      // 快路径：已下载且校验通过 → 跳过下载（解压失败重试不再重复下载）
      var needDownload = true;
      final zip = File(zipPath);
      if (await zip.exists() && await zip.length() == c.size) {
        if (await SdkDownloader.verifySha1(zipPath, c.sha1)) {
          needDownload = false;
        } else {
          await zip.delete();
        }
      }

      if (needDownload) {
        onPhase?.call('probing');
        final ordered = await _pickFastestDomesticFirst(c.file, token: token);
        onPhase?.call('downloading');
        await SdkDownloader.downloadMultiSource(
          ordered,
          zipPath,
          c.size,
          segments: 4,
          sha1: c.sha1,
          token: token,
          onMirrorUsed: onMirrorUsed,
          onProgress: onProgress,
        );
      }

      // 解压：先到 /opt/foa-sdk-stage 暂存，再取顶层目录 mv 归位（各 zip
      // 顶层目录名不一：platform-tools/、android-36/、build-tools 的
      // android-16/、cmdline-tools/ 等——统一「取顶层条目改名归位」）。
      // 归位后立即校验该组件关键文件，缺失即报错并输出暂存目录结构，
      // 精确暴露「哪个组件、缺哪个文件」，不再笼统"关键组件缺失"（Bug 417）。
      onPhase?.call('extracting');
      final slash = c.guestDir.lastIndexOf('/');
      final parent =
          slash < 0 ? sdkHome : '$sdkHome/${c.guestDir.substring(0, slash)}';
      final ex = await bridge.exec(
        'rm -rf /opt/foa-sdk-stage && mkdir -p /opt/foa-sdk-stage && '
        'unzip -qo /opt/foa-dl/${c.file} -d /opt/foa-sdk-stage && '
        'd=\$(ls -d /opt/foa-sdk-stage/* 2>/dev/null | head -1) && '
        'mkdir -p $parent && '
        'rm -rf $sdkHome/${c.guestDir} && '
        'mv "\$d" $sdkHome/${c.guestDir} && '
        'if [ -${c.keyTest} $sdkHome/${c.keyPath} ]; then '
        'rm -rf /opt/foa-sdk-stage; echo SDK_COMPONENT_OK; '
        'else '
        'echo "KEYFILE_MISSING $sdkHome/${c.keyPath}"; '
        'echo STAGE_TOP; ls -d /opt/foa-sdk-stage/* 2>/dev/null; '
        'exit 4; fi',
        timeoutSec: 300,
      );
      if (ex.exitCode != 0 || !ex.stdout.contains('SDK_COMPONENT_OK')) {
        if (ex.stdout.contains('KEYFILE_MISSING')) {
          throw DownloadException(
            '组件 ${c.id} 解压失败：${ex.stdout.trim()}',
          );
        }
        throw DownloadException(
          '组件 ${c.id} 解压失败：'
          '${ex.stderr.trim().isEmpty ? ex.stdout.trim() : ex.stderr.trim()}',
        );
      }
    }

    // 预置许可文件（flutter/gradle 检查 ANDROID_HOME/licenses/android-sdk-license）
    final lic = await bridge.exec(
      'mkdir -p $sdkHome/licenses && '
      'printf \'8933bad161af4178b1185d1a37fbf41ea5269c55\n'
      'd56f5187479451eabf01fb78af6dfcb131a6481e\n'
      '24333f8a63b6825ea9c5514f83c2829b004d1fee\n\' '
      '> $sdkHome/licenses/android-sdk-license && echo LIC_OK',
      timeoutSec: 60,
    );
    if (lic.exitCode != 0 || !lic.stdout.contains('LIC_OK')) {
      throw DownloadException('写入 Android SDK 许可失败：${lic.stderr}');
    }

    // NDK 占位（Bug 427，2026-09-18 真机 24% SIGILL）
    await ensureNdkStub(bridge);

    onPhase?.call('validating');
    // 用 diagnose 精确报缺失路径（不再笼统"关键组件缺失"，Bug 417）
    final miss = await diagnose(bridge);
    if (miss.isNotEmpty) {
      throw DownloadException(
        'Android SDK 验证失败：缺少 ${miss.join('、')}（组件已解压但关键文件未就位）。\n'
        '可点「下载并安装」重试；仍失败建议先卸载 Android SDK 后重装，'
        '或用「从本地存储选择安装」逐个导入组件 zip。',
      );
    }
    final v = await verify(bridge);
    // 清理下载缓存（4 个 zip 约 320MB）
    await bridge.exec('rm -f /opt/foa-dl/*.zip', timeoutSec: 60);
    return v ?? 'Android SDK 已安装';
  }

  /// NDK 占位确保（Bug 427 根因修复，2026-09-18 真机 24% SIGILL）。
  ///
  /// 症状：真机构建到「配置 Gradle」24% 报
  /// `Process 'command '/opt/android-sdk/cmdline-tools/latest/bin/
  /// sdkmanager'' finished with non-zero exit value 132`（132 = 128+4 =
  /// SIGILL），位置是根 build.gradle.kts 的 `evaluationDependsOn(":app")`。
  ///
  /// 根因链：Flutter gradle 插件 `FlutterPluginUtils.forceNdkDownload()`
  /// 在 `finalizeDsl` 里判定——项目 `ndkVersion = flutter.ndkVersion`
  /// （默认 28.2.13676358）不在 `installedNdkVersions` 中，且
  /// `sdkManagerPath != null`、gradle 非 offline → 主动调 **sdkmanager
  /// --install "ndk;<版本>"** 自动补装 NDK。而 sdkmanager 是 sh 脚本
  /// `exec "$JAVACMD"` 起 JVM，**Android arm64 上标准 Linux JDK 的 JIT
  /// 触达设备不支持的指令 → SIGILL**（JVM 在 Android 上运行的已知冲突，
  /// 与 sdkmanager 自身架构无关）。沙箱能过是因为构建机人工放了
  /// `ndk/28.2.13676358/source.properties`（真 NDK 改名占位），插件
  /// 判定"已装"直接 return，从不调 sdkmanager。
  ///
  /// 修复：写入最小 NDK 占位——Flutter 只检查
  /// `ndk/<version>/source.properties` **文件存在**（android_sdk.dart
  /// `hasNdkVersion`），NDK 目录名的即版本号。demo 项目零 native 代码
  /// （无 CMakeLists），占位即可让插件跳过 sdkmanager；同时避免拖
  /// 2.2GB 真 NDK 进包（本机构建不需要 NDK 工具链）。
  ///
  /// 版本号动态解析：从 Flutter gradle 插件源码读 `ndkVersion` 默认值，
  /// SDK 升级自动跟随，不硬编码。幂等，已存在真 NDK 时跳过不覆盖。
  static Future<void> ensureNdkStub(ProotBridge bridge) async {
    // 版本号优先从 Flutter 插件源码解析（SDK 升级自动跟随），失败回退默认值；
    // 字符串拼接处避免行内注释，全部 \\$ 转义留给 shell 求值（Bug 424 同类风险）
    const script = 'V=\$(sed -n "s/.*ndkVersion: String = \\"([^\\"]*)\\".*/\\1/p" '
        '/opt/flutter/packages/flutter_tools/gradle/src/main/kotlin/'
        'FlutterExtension.kt 2>/dev/null | head -1); '
        '[ -n "\$V" ] || V=28.2.13676358; '
        'if [ -f $sdkHome/ndk/\$V/source.properties ]; then '
        'echo NDK_STUB_PRESENT; exit 0; fi; '
        'mkdir -p $sdkHome/ndk/\$V && '
        'printf "Pkg.Desc = Android NDK\\nPkg.Revision = %s\\n" "\$V" '
        '> $sdkHome/ndk/\$V/source.properties && '
        '[ -f $sdkHome/ndk/\$V/source.properties ] && echo NDK_STUB_OK';
    final r = await bridge.exec(script, timeoutSec: 60);
    if (!r.stdout.contains('NDK_STUB_OK') &&
        !r.stdout.contains('NDK_STUB_PRESENT')) {
      // 不阻断安装：占位失败时插件仍会尝试 sdkmanager，真机会报 SIGILL——
      // 分诊 hint 已覆盖该症状（提示重装 Android SDK 组件）
      return;
    }
  }

  /// 国内优先分级探测：国内全部不可达才回退境外。
  static Future<List<MirrorSource>> _pickFastestDomesticFirst(
    String file, {
    DownloadCancelToken? token,
  }) async {
    try {
      return await SdkDownloader.pickFastest(
        domesticMirrors(file),
        token: token,
      );
    } on DownloadException {
      return await SdkDownloader.pickFastest(
        foreignMirrors(file),
        token: token,
      );
    }
  }

  static Future<void> uninstall(ProotBridge bridge) async {
    await bridge.exec('rm -rf /opt/android-sdk', timeoutSec: 120);
  }
}

/// Flutter SDK（官方 x64 + QEMU 兼容层转发）安装编排。
///
/// ⚠️ 关键事实（2026-09-17 真机核实）：
/// - Flutter 官方 Linux 仅发布 x64 构建（releases_linux.json 全量检索无
///   arm64），且 bin/cache/flutter_tools.snapshot 是 **app-jit 快照，
///   含 x64 机器码（架构相关）**——真机用 arm64 dart 运行报
///   "Snapshot not compatible ... requires x64 linux ... VM has arm64"；
/// - 因此本安装器**保留官方 x64 dart-sdk 原样**（不再替换 arm64），
///   x64 工具链由「x64 兼容层(QEMU)」统一转发：qemu-x86_64 模拟执行
///   dart / dartaotruntime / gen_snapshot / aapt2 等 x64 ELF；
/// - 安装顺序建议：先应用 x64 兼容层，再装本 SDK（验证阶段依赖 dart
///   已被 qemu 转发）；顺序反了也能用——兼容层卡片「重新应用」会自动
///   补上 dart 转发与引擎产物同步；
/// - 国内分段源：storage.flutter-io.cn 同时镜像 flutter_infra_release 与
///   dart-archive 且支持 Range（206）；华为云 dart 镜像不支持 Range、
///   TUNA/华为云 flutter 镜像 404，故国内源仅收录 flutter-io.cn；
/// - 解压需要 xz-utils（rootfs 无 xz CLI），与 Android SDK 共用
///   [AptTools.ensure]。
class FlutterSdkInstaller {
  static const String version = '3.47.4';
  static const String tarFile = 'flutter_linux_$version-stable.tar.xz';
  static const int tarSize = 1576174568; // Content-Length（flutter-io.cn）
  static const String tarSha256 =
      '5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3';
  static const String flutterHome = '/opt/flutter';

  static List<MirrorSource> domesticMirrors() => const [
        MirrorSource(
          'Flutter 官方中国',
          'https://storage.flutter-io.cn/flutter_infra_release/'
          'releases/stable/linux/$tarFile',
        ),
      ];

  static List<MirrorSource> foreignMirrors() => const [
        MirrorSource(
          'Google 官方',
          'https://storage.googleapis.com/flutter_infra_release/'
          'releases/stable/linux/$tarFile',
        ),
      ];

  /// 重新验证：flutter + dart 在位，输出 `flutter --version`。
  /// 若 x64 dart 尚未被 QEMU 兼容层转发（Exec format error / 快照不兼容），
  /// 返回「已安装但需启用兼容层」提示而非 null，避免误导为未安装。
  static Future<String?> verify(ProotBridge bridge) async {
    final r = await bridge.exec(
      'if [ ! -x $flutterHome/bin/flutter ] '
      '|| [ ! -x $flutterHome/bin/cache/dart-sdk/bin/dart ]; then '
      'echo __NOT_INSTALLED__; exit 0; fi; '
      'out=\$( $flutterHome/bin/flutter --version 2>&1 | head -1 ); '
      'case "\$out" in '
      '*"cannot execute"*|*"Exec format"*|*"Snapshot not compatible"*'
      '|*"error while loading shared libraries"*) '
      'echo __NEED_QEMU__ ;; '
      '*) echo "\$out" ;; '
      'esac',
      timeoutSec: 300,
    );
    if (r.exitCode != 0 || r.stdout.contains('__NOT_INSTALLED__')) {
      return null;
    }
    if (r.stdout.contains('__NEED_QEMU__')) {
      return 'Flutter $version 已安装（x64 工具链需先应用「x64 兼容层(QEMU)」）';
    }
    final v = r.stdout.trim();
    return v.isEmpty ? null : v;
  }

  /// 完整安装：apt 工具 → flutter tarball（SHA-256）→ dart arm64 →
  /// 解压 + 替换 dart-sdk + 写 version → `flutter --version` 验证。
  static Future<String> install(
    ProotBridge bridge,
    EnvInfo env, {
    void Function(String phase)? onPhase,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorUsed,
    DownloadCancelToken? token,
  }) {
    return _installCommon(bridge, env,
        onPhase: onPhase,
        onProgress: onProgress,
        onMirrorUsed: onMirrorUsed,
        token: token);
  }

  /// 本地安装兜底（2026-09-17）：用户用系统文件选择器指定 Flutter tarball
  /// （$tarFile）；按文件名/大小匹配，SHA-256 校验后拷贝进下载缓存。
  /// x64 工具链由 QEMU 兼容层转发，无需单独导入 Dart SDK。
  static Future<String> installFromLocalFile(
    ProotBridge bridge,
    EnvInfo env,
    String localPath, {
    void Function(String phase)? onPhase,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorUsed,
    DownloadCancelToken? token,
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
    String? dlName;
    if (name == tarFile || len == tarSize) {
      dlName = tarFile;
    } else {
      throw DownloadException(
        '无法识别所选文件：需要 Flutter tarball（$tarFile，$tarSize 字节）。\n'
        '（x64 工具链由 QEMU 兼容层转发，无需单独导入 Dart SDK）',
      );
    }
    onPhase?.call('importing');
    final dlDir = Directory('${env.rootfsPath}/opt/foa-dl');
    await dlDir.create(recursive: true);
    final dstPath = '${dlDir.path}/$dlName';
    await src.copy(dstPath);
    await src.delete(); // 释放 filesDir/imports 空间
    if (dlName == tarFile) {
      final ok = await SdkDownloader.verifySha256(dstPath, tarSha256);
      if (!ok) {
        await File(dstPath).delete();
        throw DownloadException(
          'SHA-256 校验失败：所选文件不是 Flutter $version tarball，'
          '或文件已损坏',
        );
      }
    }
    return _installCommon(bridge, env,
        onPhase: onPhase,
        onProgress: onProgress,
        onMirrorUsed: onMirrorUsed,
        token: token);
  }

  /// 安装主流程（网络下载 / 本地导入共用）：apt 工具保障 → tarball
  /// （快路径跳过已就位文件）→ 解压归位（保留官方 x64 dart-sdk）→ 验证。
  static Future<String> _installCommon(
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

    final dlDir = Directory('${env.rootfsPath}/opt/foa-dl');
    await dlDir.create(recursive: true);

    // 1. Flutter tarball（快路径：已下载且 SHA-256 通过 → 跳过）
    final tarPath = '${dlDir.path}/$tarFile';
    var needTar = true;
    final tar = File(tarPath);
    if (await tar.exists() && await tar.length() == tarSize) {
      if (await SdkDownloader.verifySha256(tarPath, tarSha256)) {
        needTar = false;
      } else {
        await tar.delete();
      }
    }
    if (needTar) {
      onPhase?.call('probing');
      final ordered = await _pickFastestDomesticFirst(
        domesticMirrors(),
        foreignMirrors(),
        token: token,
      );
      onPhase?.call('downloading');
      await SdkDownloader.downloadMultiSource(
        ordered,
        tarPath,
        tarSize,
        segments: 4,
        sha256: tarSha256,
        token: token,
        onMirrorUsed: onMirrorUsed,
        onProgress: onProgress,
      );
    }

    // 2. 解压 tarball → 归位（保留官方 x64 dart-sdk，由 QEMU 兼容层转发）→ 验证
    // Bug 411（2026-09-17 真机抓到）：原命令 d=$(ls -d /opt/flutter*) 取到的
    // 就是刚解压出的 /opt/flutter 本身，紧接着 rm -rf /opt/flutter 把它删掉，
    // mv "$d" /opt/flutter 必报 "cannot stat"——官方 tarball 顶层目录恰好叫
    // flutter/，100% 复现。改为暂存目录模式（与 AndroidSdkInstaller 一致）：
    // 先解压到 /opt/foa-flutter-stage 再 mv 归位，源与目标永不同路径；
    // 旧 /opt/flutter 保留到解压成功后才删（中途失败不毁存量安装）。
    onPhase?.call('extracting');
    final ex = await bridge.exec(
      'rm -rf /opt/foa-flutter-stage && mkdir -p /opt/foa-flutter-stage && '
      'tar -xJf /opt/foa-dl/$tarFile -C /opt/foa-flutter-stage && '
      'd=\$(ls -d /opt/foa-flutter-stage/* 2>/dev/null | head -1) && '
      'rm -rf $flutterHome && mv "\$d" $flutterHome && '
      'rm -rf /opt/foa-flutter-stage && '
      'chmod -R a+rX $flutterHome && '
      'echo FLUTTER_EXTRACT_OK',
      timeoutSec: 900,
    );
    if (ex.exitCode != 0 || !ex.stdout.contains('FLUTTER_EXTRACT_OK')) {
      throw DownloadException(
        'Flutter 解压失败：'
        '${ex.stderr.trim().isEmpty ? ex.stdout.trim() : ex.stderr.trim()}',
      );
    }

    onPhase?.call('validating');
    final v = await bridge.exec(
      'out=\$( $flutterHome/bin/flutter --version 2>&1 | head -1 ); '
      'echo "\$out"',
      timeoutSec: 600,
    );
    if (v.exitCode != 0 ||
        v.stdout.contains('cannot execute') ||
        v.stdout.contains('Exec format') ||
        v.stdout.contains('Snapshot not compatible')) {
      throw DownloadException(
        'Flutter 验证失败（x64 工具链未就绪）：${v.stdout.trim()}\n'
        '请先在工具链页应用「x64 兼容层(QEMU)」后重试',
      );
    }
    // 清理下载缓存（tarball 约 1.5GB）
    await bridge.exec('rm -rf /opt/foa-dl', timeoutSec: 60);
    return v.stdout.trim();
  }

  static Future<List<MirrorSource>> _pickFastestDomesticFirst(
    List<MirrorSource> domestic,
    List<MirrorSource> foreign, {
    DownloadCancelToken? token,
  }) async {
    try {
      return await SdkDownloader.pickFastest(domestic, token: token);
    } on DownloadException {
      return await SdkDownloader.pickFastest(foreign, token: token);
    }
  }

  static Future<void> uninstall(ProotBridge bridge) async {
    await bridge.exec('rm -rf /opt/flutter /opt/foa-dl', timeoutSec: 120);
  }
}

/// 构建镜像一键配置（2026-09-17 实测后收录的国内源）：
/// 1. 环境变量 → /etc/profile.d/foa-env.sh + /root/.bashrc（Flutter/Dart
///    镜像、ANDROID_HOME、JAVA_HOME、GRADLE_USER_HOME、PATH）；
/// 2. ~/.gradle/init.gradle → 阿里云 Maven 三仓（public/google/gradle-plugin），
///    对所有项目生效（allprojects + settingsEvaluated 双保险）；
/// 3. 项目 gradle-wrapper.properties → distributionUrl 指向腾讯云 Gradle 镜像；
/// 4. 预下载 Gradle 分发包到 wrapper 缓存目录（Gradle 9.3.1，224MB）。
///
/// Gradle Wrapper 缓存目录名 = base36(MD5(distributionUrl))（Gradle 9.3.1
/// 源码 PathAssembler 确认，去前导零），对腾讯云 URL 实测为
/// `5wooodlkfwsm42ictrailuf0e`；wrapper 首次构建发现 zip 在位即跳过下载、
/// 自动解压并写 .ok 标记后删除 zip。
class MirrorConfigurator {
  static const String gradleVersion = '9.3.1';
  static const String gradleUrl =
      'https://mirrors.cloud.tencent.com/gradle/gradle-$gradleVersion-all.zip';
  static const int gradleSize = 234893460; // Content-Length（腾讯云实测）
  static const String gradleHash =
      '5wooodlkfwsm42ictrailuf0e'; // base36(MD5(gradleUrl))

  static List<MirrorSource> domesticMirrors() => const [
        MirrorSource(
          '腾讯云',
          'https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip',
        ),
      ];

  static List<MirrorSource> foreignMirrors() => const [
        MirrorSource(
          'Gradle 官方',
          'https://services.gradle.org/distributions/gradle-9.3.1-all.zip',
        ),
      ];

  /// 环境变量文件（宿主机直接写入 rootfs 真实目录，规避 shell 转义）。
  static String _envContent() => '''
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export ANDROID_HOME=${AndroidSdkInstaller.sdkHome}
export JAVA_HOME=/opt/jdk
export GRADLE_USER_HOME=/root/.gradle
export PATH=${FlutterSdkInstaller.flutterHome}/bin:\$PATH
''';

  /// ~/.gradle/init.gradle（阿里云 Maven 镜像，全局生效）。
  ///
  /// Bug 426（2026-09-18 真机 22% 配置 Gradle 报错）重写：旧版用
  /// `allprojects{repositories{maven}}` + `settingsEvaluated` 注入仓库，
  /// 与 Flutter 新模板 settings.gradle.kts（flutter-plugin-loader 走
  /// PREFER_SETTINGS 仓库模式）冲突——PREFER_SETTINGS 拒绝任何 project
  /// 仓库，报 `prefer settings repositories ... repository 'maven' was
  /// added`，plugin-loader 解析直接失败。新版改为 **beforeSettings 在
  /// settings 仓库前插镜像**：settings 仓库正是被 prefer 的对象、加仓库
  /// 合法；镜像排最前命中即停，官方源（模板自带 google()/mavenCentral()）
  /// 自动成为兜底。形态与沙箱构建机一致（沙箱构建正常的实证）。
  ///
  /// 注意：Groovy 闭包内不引用外部 def 变量（作用域不跨越
  /// beforeSettings 边界，沙箱踩过）。
  static String initGradleContent() => '''
// FOA 一键生成：阿里云 Maven 镜像（beforeSettings 前插版，2026-09-18）
// 无旧版注入——Flutter 新模板 settings.gradle.kts 走 PREFER_SETTINGS
// 模式，project 级仓库注入会被拒绝（真机 alpha.36 的 22% 报错根因）。
beforeSettings { settings ->
    settings.pluginManagement.repositories {
        maven { url 'https://maven.aliyun.com/repository/public' }
        maven { url 'https://maven.aliyun.com/repository/google' }
        maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }
    }
    settings.dependencyResolutionManagement.repositories {
        maven { url 'https://maven.aliyun.com/repository/public' }
        maven { url 'https://maven.aliyun.com/repository/google' }
        maven { url 'https://maven.aliyun.com/repository/gradle-plugin' }
    }
}
''';

  /// 重新验证：env 文件 + init.gradle + gradle zip 是否就绪。
  static Future<String?> verify(ProotBridge bridge, EnvInfo env) async {
    final r = await bridge.exec(
      '[ -f /etc/profile.d/foa-env.sh ] '
      '&& [ -f /root/.gradle/init.gradle ] '
      '&& [ -f /root/.gradle/wrapper/dists/'
      'gradle-$gradleVersion-all/$gradleHash/gradle-$gradleVersion-all.zip ] '
      '&& echo MIRROR_OK',
      timeoutSec: 30,
    );
    if (!r.ok || !r.stdout.contains('MIRROR_OK')) return null;
    return '镜像环境已配置 · Gradle $gradleVersion 已预下载';
  }

  /// 一键应用：环境变量 → init.gradle → wrapper 镜像 → Gradle 预下载。
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
    final rootfs = env.rootfsPath;

    // 1. 环境变量（host 侧写 rootfs 真实文件）
    onPhase?.call('env');
    final envFile = File('$rootfs/etc/profile.d/foa-env.sh');
    await envFile.parent.create(recursive: true);
    await envFile.writeAsString(_envContent());
    final bashrc = File('$rootfs/root/.bashrc');
    if (await bashrc.exists()) {
      final cur = await bashrc.readAsString();
      if (!cur.contains('PUB_HOSTED_URL')) {
        await bashrc.writeAsString('\n${_envContent()}\n',
            mode: FileMode.append);
      }
    } else {
      await bashrc.parent.create(recursive: true);
      await bashrc.writeAsString(_envContent());
    }

    // 2. init.gradle（阿里云 Maven 镜像，beforeSettings 前插版）
    onPhase?.call('init-gradle');
    final gradleHome = File('$rootfs/root/.gradle/init.gradle');
    await gradleHome.parent.create(recursive: true);
    await gradleHome.writeAsString(initGradleContent());

    // 3. 改写 /root/projects 下所有项目的 wrapper distributionUrl
    onPhase?.call('wrapper');
    var patched = 0;
    final projects = Directory('$rootfs/root/projects');
    if (await projects.exists()) {
      await for (final f in projects.list(
        recursive: true,
        followLinks: false,
      )) {
        if (f is File &&
            f.path.endsWith('gradle/wrapper/gradle-wrapper.properties')) {
          final before = await f.readAsString();
          final next = before.replaceAllMapped(
            RegExp(r'^distributionUrl=.*$', multiLine: true),
            (_) =>
                'distributionUrl=https\\://mirrors.cloud.tencent.com/gradle/'
                'gradle-$gradleVersion-all.zip',
          );
          if (next != before) {
            await f.writeAsString(next);
            patched++;
          }
        }
      }
    }

    // 4. Gradle 分发包预下载（wrapper 缓存目录）
    onPhase?.call('probing');
    final distDir = Directory(
      '$rootfs/root/.gradle/wrapper/dists/gradle-$gradleVersion-all/$gradleHash',
    );
    await distDir.create(recursive: true);
    final zipPath = '${distDir.path}/gradle-$gradleVersion-all.zip';
    final zip = File(zipPath);
    if (!(await zip.exists() && await zip.length() == gradleSize)) {
      if (await zip.exists()) await zip.delete();
      final ordered = await _pickFastestDomesticFirst(token: token);
      onPhase?.call('downloading');
      await SdkDownloader.downloadMultiSource(
        ordered,
        zipPath,
        gradleSize,
        segments: 4,
        token: token,
        onMirrorUsed: onMirrorUsed,
        onProgress: onProgress,
      );
    }
    return '镜像环境已配置 · 已改写 $patched 个项目 wrapper · '
        'Gradle $gradleVersion 已预下载';
  }

  static Future<List<MirrorSource>> _pickFastestDomesticFirst({
    DownloadCancelToken? token,
  }) async {
    try {
      return await SdkDownloader.pickFastest(
        domesticMirrors(),
        token: token,
      );
    } on DownloadException {
      return await SdkDownloader.pickFastest(
        foreignMirrors(),
        token: token,
      );
    }
  }
}
