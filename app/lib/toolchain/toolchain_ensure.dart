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
/// 磁盘空间体检结果（alpha.93）。
///
/// 两档阈值的依据：
/// - **2GB 以下告警**：手册 Bug 603 定的线。Flutter 首次构建要落
///   Gradle 依赖缓存 + 引擎构件 + 中间产物，2GB 是"还能跑但紧张"；
/// - **800MB 以下阻断**：这个量级下 `No space left on device` 几乎必然
///   发生，而手机上一次构建 20~30 分钟——**让它跑下去纯属浪费时间**，
///   不如拦下来让用户先清空间。
///
/// 只告警不阻断的那档是有意的：空间估算受机型/项目差异影响大，
/// 为了"可能不够"就拒绝构建，比多提示一句更惹人烦。
class DiskSpace {
  final int freeMb;

  const DiskSpace({required this.freeMb});

  static const int warnMb = 2048;
  static const int blockMb = 800;

  bool get blocking => freeMb < blockMb;
  bool get warning => freeMb < warnMb;

  String get human => freeMb >= 1024
      ? '${(freeMb / 1024).toStringAsFixed(1)} GB'
      : '$freeMb MB';

  String get advice =>
      '清理入口：工作台打包区「清理缓存」（flutter clean），'
      '或到「工具链」页删除不用的 SDK 版本与 Gradle 缓存。';
}

class ToolchainEnsure {
  final ProotBridge _bridge = ProotBridge();

  // ---------------- 脚本常量（const 化供单测做语法与契约断言）----------------
  // 教训（Bug 449 收尾时发现）：同一段 shell 在 chk 与复核里各抄一份，
  // 两份已经开始漂移（miss 标签一个带 engine: 前缀一个不带）——
  // 而 buildPreflightScript 的 AOT_FP 段曾因同类复制粘贴产生
  // 「两个 for 头、一个 done」的语法错误。脚本必须收敛到单一定义。

  /// NDK strip 探针：任一 NDK 版本的 llvm-strip 已在位（文件或
  /// symlink、可执行）→ STRIP_OK。glob 不展开时 `[ -e ]` 守卫安全跳过。
  static const String ndkStripProbeScript = 'ok=0; '
      'for s in /opt/android-sdk/ndk/*/toolchains/llvm/prebuilt/'
      'linux-x86_64/bin/llvm-strip; do '
      '  [ -e "\$s" ] || continue; [ -x "\$s" ] && ok=1; '
      'done; '
      '[ "\$ok" = 1 ] && echo STRIP_OK || echo STRIP_MISSING';

  /// NDK strip 补位正文（前置 [AptTools.repairDpkg] 由调用方拼接）：
  /// Debian llvm 已装 → 直接 symlink；没装 → 安装再 symlink。
  /// 遍历 NDK 版本目录再拼路径，而非 glob 整条子路径——空壳 NDK 没有
  /// toolchains 子树，`ndk/*/toolchains/.../bin` 不展开时 mkdir 会
  /// 创建带 `*` 字面量的垃圾目录。`ndk/*/` 层级 ndkStub 已保证存在，
  /// 且 `[ -d ]` 守卫让不展开的字面量安全跳过。
  static const String ndkStripEnsureScript =
      'command -v llvm-strip >/dev/null 2>&1 || '
      'DEBIAN_FRONTEND=noninteractive apt-get update -qq && '
      'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq '
      '--no-install-recommends -o Acquire::Retries=3 llvm '
      '2>&1 | tail -n 5; '
      'command -v llvm-strip >/dev/null 2>&1 || { echo LLVM_UNAVAILABLE; exit 0; }; '
      'for d in /opt/android-sdk/ndk/*/; do '
      '  [ -d "\$d" ] || continue; '
      '  b="\${d}toolchains/llvm/prebuilt/linux-x86_64/bin"; '
      '  mkdir -p "\$b"; '
      '  ln -sf "\$(command -v llvm-strip)" "\$b/llvm-strip"; '
      '  ln -sf "\$(command -v llvm-objcopy)" "\$b/llvm-objcopy"; '
      'done; '
      'echo STRIP_FIXED';

  /// 转发层全量比对脚本（qemuCompatEnsure 的 chk 与复核共用，Bug 449）。
  ///
  /// [tag] 是输出标记（chk 用 WRAP_CHECK，复核用 VERIFY），其余完全一致。
  ///
  /// 契约（Bug 449 修订）：
  /// - 原位包装后 `linux-x64/<tool>` 是 wrapper、真身在 `<tool>.foa-real`；
  ///   真身解析 `<f>.foa-real` 优先，保证读的是真 ELF 而不是 sh 脚本。
  /// - 两个位都必须是 `#!`：① 原位 `<f>`（构建实际调用的路径）
  ///   ② 对称 `<linux-arm64>/<f>`（上游修复 ABI 检测后的兜底路径）。
  /// - SDK 侧本来就是原位制，只查原位一个位。
  /// - 任一不满足记入 miss；n/ok 计数由调用方解析。
  static String wrapCheckScript(String tag) =>
      'miss=""; n=0; ok=0; '
      // 引擎层：android-*/linux-x64（原位）→ android-*/linux-arm64（对称）
      'for d in ${QemuCompat.engineDir}/android-*/linux-x64; do '
      '  [ -d "\$d" ] || continue; '
      '  a="\${d%/linux-x64}/linux-arm64"; '
      '  for f in "\$d"/*; do '
      '    [ -f "\$f" ] || continue; [ -x "\$f" ] || continue; '
      '    case "\$f" in *.foa-real) continue ;; esac; '
      '    case "\$f" in *.so|*.so.*|*.snapshot|*.dill|*.json|*.jar|*.zip) continue ;; esac; '
      '    real="\$f"; [ -f "\$f.foa-real" ] && real="\$f.foa-real"; '
      '    m=\$(dd if="\$real" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d " \\n"); '
      '    case "\$m" in 7f454c46*3e) ;; *) continue ;; esac; '
      '    n=\$((n+1)); w="\$a/\${f##*/}"; '
      '    if [ -f "\$f" ] && head -c 2 "\$f" 2>/dev/null | grep -q "#!" '
      '       && [ -f "\$w" ] && head -c 2 "\$w" 2>/dev/null | grep -q "#!"; then '
      '      ok=\$((ok+1)); '
      '    else miss="\$miss engine:\${f##*/}"; fi; '
      '  done; '
      'done; '
      // 宿主层：顶层 linux-x64 → linux-arm64（impellerc/font-subset 所在）
      'for hd in ${QemuCompat.engineDir}/linux-*/; do '
      '  hd="\${hd%/}"; [ -d "\$hd" ] || continue; '
      '  case "\$hd" in */linux-x64) ;; *) continue ;; esac; '
      '  ha="\${hd%/linux-x64}/linux-arm64"; '
      '  for f in "\$hd"/*; do '
      '    [ -f "\$f" ] || continue; [ -x "\$f" ] || continue; '
      '    case "\$f" in *.foa-real) continue ;; esac; '
      '    case "\$f" in *.so|*.so.*|*.snapshot|*.dill|*.json|*.jar|*.zip) continue ;; esac; '
      '    real="\$f"; [ -f "\$f.foa-real" ] && real="\$f.foa-real"; '
      '    m=\$(dd if="\$real" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d " \\n"); '
      '    case "\$m" in 7f454c46*3e) ;; *) continue ;; esac; '
      '    n=\$((n+1)); w="\$ha/\${f##*/}"; '
      '    if [ -f "\$f" ] && head -c 2 "\$f" 2>/dev/null | grep -q "#!" '
      '       && [ -f "\$w" ] && head -c 2 "\$w" 2>/dev/null | grep -q "#!"; then '
      '      ok=\$((ok+1)); '
      '    else miss="\$miss host:\${f##*/}"; fi; '
      '  done; '
      'done; '
      // SDK 层：build-tools/* 与 platform-tools 顶层 x86_64 ELF（原地包装制）
      'for d in ${QemuCompat.sdkHome}/build-tools/* ${QemuCompat.sdkHome}/platform-tools; do '
      '  [ -d "\$d" ] || continue; '
      '  for f in "\$d"/*; do '
      '    [ -f "\$f" ] || continue; [ -x "\$f" ] || continue; '
      '    case "\$f" in *.foa-real) continue ;; esac; '
      '    m=\$(dd if="\$f" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d " \\n"); '
      '    case "\$m" in 7f454c46*3e) ;; *) continue ;; esac; '
      '    n=\$((n+1)); '
      '    if head -c 2 "\$f" 2>/dev/null | grep -q "#!"; then '
      '      ok=\$((ok+1)); '
      '    else miss="\$miss sdk:\${f##*/}"; fi; '
      '  done; '
      'done; '
      'echo "$tag n=\$n ok=\$ok miss=\$miss"';

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

  /// NDK strip 工具补位（Bug 449 附属，alpha.55，2026-09-19 真机实证）。
  ///
  /// 症状：构建跑到 gradle `:app:stripReleaseDebugSymbols` 报
  /// `A problem occurred starting process 'command '.../llvm-strip''`
  /// ——rootfs 里的 NDK 是**空壳**（只有 source.properties，见
  /// [AndroidSdkInstaller.ensureNdkStub]：专为骗过 AGP 配置期的 NDK
  /// 检测、省下 2GB 完整 NDK）。此前五个版本全部死在更早的 AOT 阶段，
  /// strip 任务从未真正执行过——空壳兜不住执行期的事实一直没暴露。
  /// 工具链全链路打通后第一次摸到 strip → 炸。
  ///
  /// 修复：**不装 NDK**（继续省 2GB），用 Debian 原生 llvm 顶位：
  /// `apt-get install llvm` 后把 /usr/bin/llvm-strip、llvm-objcopy
  /// symlink 进 NDK 的期望路径。llvm 工具是 arm64 原生二进制（native
  /// 跑、不过 qemu），且 llvm-strip 能剥离任意架构的 ELF（包括 x86_64
  /// 的 app.so），比 NDK 自带的 x86_64 版本更合适。
  ///
  /// 注意与 [ndkStub] 的分工：ndkStub 保障「AGP 配置期」不炸（空壳 +
  /// source.properties），本方法保障「strip 执行期」不炸（真工具）。
  /// 两者都要在构建前确保。返回 null=就位/已补位，非 null=错误文案。
  Future<String?> ndkStripTools({bool bare = false}) async {
    if (bare) return null; // termux 后端无此布局（未投产）
    try {
      // 任一 NDK 版本的 llvm-strip 已在位（文件或 symlink、可执行）→ 秒过
      final probe = await _bridge.exec(
        ndkStripProbeScript,
        timeoutSec: 30,
      );
      if (probe.stdout.contains('STRIP_OK')) return null;

      // Debian llvm：已装 → 直接 symlink；没装 → 修 dpkg 后安装再 symlink
      final ensure = await _bridge.exec(
        '${AptTools.repairDpkg}$ndkStripEnsureScript',
        timeoutSec: 900,
      );
      if (ensure.stdout.contains('STRIP_FIXED')) return null;
      final out = ensure.stderr.isNotEmpty ? ensure.stderr : ensure.stdout;
      return 'llvm-strip 补位失败（NDK 空壳无 strip 工具，且 Debian llvm '
          '安装失败——strip 阶段会卡构建）：\n${_tail(out)}';
    } catch (e) {
      return 'llvm-strip 补位检查失败：$e';
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
  /// x64 兼容层构建前全量确保（Bug 428 / 429 根因修复）。
  ///
  /// **设计原则（Bug 429 教训）**：不做"点名检查"。凡是 `linux-x64/` 下的
  /// x86_64 ELF，`linux-arm64/` 就必须有同名 `#!` 转发脚本——**遍历全量
  /// 比对，不从已知工具清单里挑**。理由：
  /// - Flutter 每次升级可能新增宿主工具（历史上有 gen_snapshot、
  ///   impellerc、font-subset、const_finder…，上游随时可能再加）；
  /// - 点名检查（初版只查 gen_snapshot）会漏掉 impellerc 等 → 自愈
  ///   误判"一切正常" → 构建照旧 SIGILL。
  /// 全量比对让"未知的新工具"自动被覆盖，无需预见它们叫什么。
  ///
  /// 检查逻辑：对每个 `android-*/linux-x64/<file>`（x86_64 ELF）：
  /// 验证 `android-*/linux-arm64/<file>` 存在且以 `#!` 开头；任一不满足
  /// 即重跑 [QemuCompat.engineWrapScript]（该脚本本身已是全量遍历，
  /// 幂等）。SDK 侧（build-tools/platform-tools）同样全量比对。
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

      const S = QemuCompat.sdkHome;

      // ---- 全量比对（Bug 449 修订）：原位包装后，linux-x64/<tool> 是
      //      wrapper、真身在 <tool>.foa-real。检查两个位都必须是 #!：
      //      ① 原位 <f>（构建实际调用的路径）
      //      ② 对称 <linux-arm64>/<f>（上游修复 ABI 检测后的兜底路径）
      //      任一不是 #! 即缺口。SDK 侧本来就是原位制，不变。
      //      脚本本体收敛到 wrapCheckScript（chk 与复核共用同一份，
      //      防止两份手抄版漂移——AOT_FP 的 for 不闭合就是这么来的）。----
      final chk = await _bridge.exec(
        wrapCheckScript('WRAP_CHECK'),
        timeoutSec: 120,
      );
      final out = chk.stdout;
      if (out.contains('n=0')) return null; // 无 x64 产物（未 precache）→ 无事
      if (out.contains('n=') && !out.contains('miss= ') && out.contains('miss=')) {
        // 全部就位（miss 为空）
        final line = out.split('\n').firstWhere(
              (l) => l.startsWith('WRAP_CHECK'),
              orElse: () => '',
            );
        final okCount = RegExp(r'ok=(\d+)').firstMatch(line)?.group(1);
        final nCount = RegExp(r'n=(\d+)').firstMatch(line)?.group(1);
        if (okCount != null && nCount != null && okCount == nCount) {
          return null;
        }
      }

      // 有不就位的 → 全量重建（engineWrapScript 本身遍历全量、幂等）
      final r = await _bridge.exec(
        QemuCompat.fill(QemuCompat.engineWrapScript),
        timeoutSec: 2400,
      );
      if (r.stdout.contains('PRECACHE_FAILED')) {
        return 'x64 兼容层引擎转发重建失败（precache 失败），'
            '请到「工具链」页重新应用 x64 兼容层';
      }
      // SDK 侧重建
      await _bridge.exec(
        QemuCompat.fill(QemuCompat.sdkWrapScript, sdk: S),
        timeoutSec: 600,
      );

      // 复核：再跑一次全量比对（与 chk 同一份脚本），仍缺则如实报告缺口名
      final v = await _bridge.exec(
        wrapCheckScript('VERIFY'),
        timeoutSec: 120,
      );
      final vline = v.stdout.split('\n').firstWhere(
            (l) => l.startsWith('VERIFY'),
            orElse: () => '',
          );
      final vOk = RegExp(r'ok=(\d+)').firstMatch(vline)?.group(1);
      final vN = RegExp(r'n=(\d+)').firstMatch(vline)?.group(1);
      if (vOk != null && vN != null && vOk == vN) return null;
      final vMiss = RegExp(r'miss=(.*)$').firstMatch(vline)?.group(1)?.trim();
      return 'x64 兼容层转发层重建后仍有缺口'
          '${vMiss == null || vMiss.isEmpty ? '' : '：$vMiss'}，'
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
  /// 构建前磁盘空间体检（手册 Bug 603 方案第 1 条，alpha.93 落地）。
  ///
  /// 以前只有**失败后**的分诊提示（`no space left` → 建议清理），
  /// 而一次构建在手机上是 20~30 分钟——等它烧完再告诉用户"空间不够"
  /// 等于白等。所以挪到构建前。
  ///
  /// 返回 null = 空间充足；否则返回**给用户的提示文案**，
  /// [DiskSpace.blocking] 表示是否该拦下构建。
  Future<DiskSpace?> diskSpace() async {
    // `df -Pm` 用 POSIX 单行格式（避免长设备名换行导致解析错位），
    // 单位是 MB。取 /root 所在挂载点——rootfs、Gradle 缓存、构建产物
    // 全在这一棵树上，它是唯一会写满的地方。
    final r = await _bridge.exec(
      'df -Pm /root 2>/dev/null | tail -1 || echo DF_FAIL',
      timeoutSec: 30,
    );
    final line = r.stdout.trim();
    if (line.isEmpty || line.startsWith('DF_FAIL')) return null; // 探测不到就不挡路
    final cols = line.split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final free = int.tryParse(cols[3]);
    if (free == null) return null;

    return DiskSpace(freeMb: free);
  }

  Future<String?> git() async {
    final check = await _bridge.exec(
      'command -v git >/dev/null 2>&1 && echo GIT_OK || echo GIT_MISSING',
      timeoutSec: 30,
    );
    if (!(check.exitCode == 0 && check.stdout.contains('GIT_OK'))) {
      // Bug 435（2026-09-19 真机截图）：本路径原先**没有** dpkg 自愈，
      // 而 AptTools.ensure 有。于是「兼容层卸载失败」留下的 dpkg 半安装
      // 中间态会在这里炸成
      //   E: dpkg was interrupted, you must manually run 'dpkg --configure -a'
      // 用户看到的是「自动安装 git 失败」——**错误信息指向 git，真因却在
      // dpkg 状态**，完全没法顺着排查。执行路径上凡是调 apt 的地方，
      // 都必须先修复 dpkg 状态，不能只在"我想到的那条"路径上加。
      //
      // 另一个坑：apt-get update 也会被 dpkg 中间态拦住。原先
      // `apt-get update && apt-get install git` 用 && 串联，update 一失败
      // install 根本不执行，报错还停在 update 的输出上。
      final repair = await _bridge.exec(
        '${AptTools.repairDpkg}echo DPKG_REPAIRED',
        timeoutSec: 600,
      );
      if (!repair.stdout.contains('DPKG_REPAIRED')) {
        // 自愈本身失败不直接放弃——仍试一次安装，失败时把两段输出一起给
        // 用户，避免"修复命令挂了所以什么都装不了"这种更差的结果。
      }

      final install = await _bridge.exec(
        'DEBIAN_FRONTEND=noninteractive apt-get update -qq '
        '-o Acquire::Retries=3 2>&1 | tail -n 20\n'
        'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq '
        '--no-install-recommends -o Acquire::Retries=3 git 2>&1 | tail -n 30\n'
        'command -v git >/dev/null 2>&1 && echo GIT_INSTALLED',
        timeoutSec: 900,
      );
      if (!(install.exitCode == 0 &&
          install.stdout.contains('GIT_INSTALLED'))) {
        final out = install.stderr.isNotEmpty ? install.stderr : install.stdout;
        return '自动安装 git 失败：\n${_tail(out)}\n'
            '（已尝试自动修复 dpkg 中断状态；仍失败可到「终端」手动执行 '
            'dpkg --configure -a 后重试）';
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
