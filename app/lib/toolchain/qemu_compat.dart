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
  # Bug 428：已是转发脚本（#! 开头）则跳过——重应用时不再误动已包装项
  if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then continue; fi
  m=$(dd if="$f" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in 7f454c46*3e) ;; *) continue ;; esac
  mv "$f" "$f.foa-real"
  gen "$f" "$f.foa-real"
  n=$((n+1))
done
echo "FLUTTER_WRAPPED=$n"
''';

  /// Bug 433：构建命令内联的**转发层再断言**脚本（压缩版，无 precache）。
  ///
  /// 为什么需要它：`buildCommand` 在 `flutter build` 之前先跑
  /// `flutter pub get`。pub get 在依赖状态变化时会触发 Flutter 的
  /// **构件重新下载**，把 `linux-arm64/<tool>` 写回真 x64 二进制——
  /// 盖掉构建前 `qemuCompatEnsure` 刚放好的转发脚本（上游 artifacts.dart
  /// 未对 linux_arm64 做 x64 回退，见 flutter/flutter#152281）。
  ///
  /// 于是真机表现为：前置检查全过 → AOT 编译跑到 54% → shader 编译
  /// 阶段 `impellerc` SIGILL（`Dart snapshot generator failed with
  /// exit code -4` / `shaders/ink_sparkle.frag failed with exit code -4`）。
  /// 这正是 Bug 429 在「pub get 插队」场景下的复发。
  ///
  /// 兜底不变量：**在真正调用 flutter build 的同一条 shell 命令里、
  /// 紧邻其前**再断言一次。此处已确认构件存在（前置检查过了），
  /// 所以不需要 precache 分支，脚本很小、秒级完成。
  static const String wrapReassertScript = r'''
E=@ENGINE@
[ -d "$E" ] || exit 0
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
put() {
  [ -f "$1" ] || return 0
  [ -x "$1" ] || return 0
  m=$(dd if="$1" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in 7f454c46*3e) ;; *) return 0 ;; esac
  if [ -f "$2" ] && head -c 2 "$2" 2>/dev/null | grep -q '#!'; then
    return 0
  fi
  mkdir -p "$(dirname "$2")"
  gen "$2" "$1"
  n=$((n+1))
}
n=0
for d in "$E"/android-*/linux-x64; do
  [ -d "$d" ] || continue
  a="${d%/linux-x64}/linux-arm64"
  for f in "$d"/*; do put "$f" "$a/${f##*/}"; done
done
for hd in "$E"/linux-*/; do
  hd="${hd%/}"; [ -d "$hd" ] || continue
  case "$hd" in */linux-x64) ;; *) continue ;; esac
  ha="${hd%/linux-x64}/linux-arm64"
  for f in "$hd"/*; do put "$f" "$ha/${f##*/}"; done
done
echo "REASSERT=$n"
''';

  /// 引擎产物同步：若尚未下载 → flutter precache --android（走 flutter-io.cn），
  /// 再为每个 android-*/linux-x64 生成 linux-arm64/ 转发脚本。
  ///
  /// 公开（原 `_engineSyncScript`）供 [ToolchainEnsure.qemuCompatEnsure]
  /// 在构建前幂等重建转发层（Bug 428：precache 会覆写 linux-arm64/）。
  static const String engineWrapScript = r'''
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
    # Bug 428 关键修复：判定"是否已是转发脚本"，而非"文件是否存在"。
    # flutter precache 在 arm64 宿主上会往 linux-arm64/ 写它下载的
    # **真 x64 二进制**（上游 artifacts.dart 未对 linux_arm64 做 x64
    # 回退，见 flutter/flutter#152281），覆盖掉我们先前放的包装脚本。
    # 旧逻辑 [ -f "$w" ] 见文件存在就跳过 → 永久卡在错误状态 → SIGILL。
    if [ -f "$w" ] && head -c 2 "$w" 2>/dev/null | grep -q '#!'; then
      continue   # 已是转发脚本，幂等跳过
    fi
    gen "$w" "$f"
    n=$((n+1))
  done
done
# ---- Bug 429：顶层宿主工具目录（$E/linux-x64 → $E/linux-arm64）----
# impellerc / font-subset / flutter_tester 等**宿主工具**在引擎根下的
# linux-x64/（不在 android-*/ 里）。artifacts.dart 的 HostArtifact.
# impellerc 取 engineDir/<hostPlatform>/impellerc，arm64 宿主 →
# linux-arm64/impellerc。不包装则 shader 编译直接 SIGILL（真机 57%
# "impellerc failure"）。同样全量遍历、按 #! 判定、幂等。
for hd in "$E"/linux-*/; do
  hd="${hd%/}"
  [ -d "$hd" ] || continue
  case "$hd" in */linux-x64) ;; *) continue ;; esac
  ha="${hd%/linux-x64}/linux-arm64"
  mkdir -p "$ha"
  for f in "$hd"/*; do
    [ -f "$f" ] || continue
    [ -x "$f" ] || continue
    m=$(dd if="$f" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$m" in 7f454c46*3e) ;; *) continue ;; esac
    w="$ha/${f##*/}"
    if [ -f "$w" ] && head -c 2 "$w" 2>/dev/null | grep -q '#!'; then
      continue
    fi
    gen "$w" "$f"
    n=$((n+1))
  done
done
echo "ENGINE_DIRS=$n"
''';

  /// Android SDK 工具接管：build-tools / platform-tools 顶层 x86_64 ELF
  /// 原地改名 .foa-real，生成 qemu 转发脚本。
  static const String sdkWrapScript = r'''
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
    # Bug 428：已是转发脚本则跳过（同 flutter/engine 层修复）
    if head -c 2 "$f" 2>/dev/null | grep -q '#!'; then continue; fi
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
#
# Bug 437：原先只测 android-arm64-release/linux-arm64/gen_snapshot，
# 漏掉了 **顶层 linux-arm64/ 的 impellerc**——而真机 AOT 崩的恰恰是它
# （`impellerc failure:` / shader 编译 exit -4）。REASSERT=0（转发层完好）
# 却仍崩，就是因为**这个工具从来没被验证过**。
# 现在逐个测：顶层与各 android-*/ 下的 impellerc / gen_snapshot 都要过。
smoke() {
  # $1=工具路径 $2=标签  => 输出 "<标签>=yes|no"，失败时附一行诊断
  #
  # Bug 437：失败时必须输出**具体原因**。原先只输出 yes/no，
  # 真机上无法区分「脚本缺失」「目标 x64 二进制被覆盖」「依赖库找不到」
  # 「SIGILL」——而这四种的修法完全不同。诊断信息才是这条命令的价值。
  t="$1"; n="$2"
  if [ ! -x "$t" ]; then echo "$n=no"; echo "  $n: 文件不存在或不可执行"; return; fi
  if ! head -c 2 "$t" 2>/dev/null | grep -q '#!'; then
    echo "$n=no"
    echo "  $n: 不是转发脚本（真 x64 二进制，arm64 上必 SIGILL）"
    return
  fi
  o=$( "$t" --help 2>&1 | head -5 )
  r=$?
  case "$o" in
    *'cannot execute'*|*'Exec format'*)
      echo "$n=no"; echo "  $n: Exec format error（qemu 未生效或未安装）"; return ;;
    *'error while loading shared libraries'*|*'No such file'*)
      echo "$n=no"; echo "  $n: 依赖库缺失 → ${o%%$'\n'*}"; return ;;
    *'Permission denied'*)
      echo "$n=no"; echo "  $n: 无执行权限"; return ;;
  esac
  if [ -z "$o" ]; then
    echo "$n=no"; echo "  $n: 无输出（rc=$r）——多为 SIGILL（qemu 跑 x64 失败）"
    return
  fi
  if [ "$r" -ge 128 ] 2>/dev/null; then
    echo "$n=no"; echo "  $n: 信号退出 rc=$r（128+n，n=4 即 SIGILL）"; return
  fi
  echo "$n=yes"
  echo "  $n: 正常"
}
# Bug 437：逐个冒烟——gen_snapshot（AOT）+ impellerc（shader）都在真机崩过
smoke @ENGINE@/android-arm64-release/linux-arm64/gen_snapshot GEN_SNAPSHOT
smoke @ENGINE@/linux-arm64/impellerc IMPELLERC
smoke @ENGINE@/linux-arm64/font-subset FONT_SUBSET
# Bug 437：报告转发脚本指向的目标是否仍是 x64 ELF（被 pub get 覆盖会变成
# arm64 或损坏文件，此时脚本还在、REASSERT 也是 0，但一跑就崩）
for pair in \
  "@ENGINE@/linux-arm64/impellerc:@ENGINE@/linux-x64/impellerc" \
  "@ENGINE@/android-arm64-release/linux-arm64/gen_snapshot:@ENGINE@/android-arm64-release/linux-x64/gen_snapshot" ; do
  s="${pair%%:*}"; d="${pair##*:}"
  [ -f "$d" ] || { echo "TARGET_MISSING=$(basename "$s") 目标 $d 不存在"; continue; }
  m=$(dd if="$d" bs=1 count=19 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$m" in
    7f454c46*3e) ;;
    *) echo "TARGET_BAD=$(basename "$s") 目标不是 x86_64 ELF（magic=$m）→ 已被覆盖" ;;
  esac
done
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
# 卸载核心：apt purge 失败会残留 qemu → 出现"卸载没效果"。此前
# `purge ... | tail || true` 管道吞掉 apt 退出码，失败也报成功。
# 现在逐条捕获状态：purge 非零 → 报错退出；qemu 仍在 → 报错退出。
#
# Bug 434（真机 rc=100 "Essential packages were removed"）：
# 一条命令里同时 purge qemu-user-static **和** libc6:amd64 等运行库时，
# apt 会把这些运行库当成"随 qemu 一起装的无主依赖"级联删除；而本机是
# arm64 宿主 + amd64 外来架构，删 libc6:amd64 会被判定为移除 essential
# 包，`-y` 下直接拒绝 → rc=100，整个卸载失败（qemu 反而一个都没删）。
# 因此改成分步：① 只 purge qemu 本体（不带 :amd64 运行库）；
# ② 运行库**逐个**删，单个失败不影响其它，也不触发 essential 拒绝；
# ③ 最后清 amd64 外来架构，让宿主回到纯净单架构状态。
DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq qemu-user-static > /tmp/foa_purge.log 2>&1
rc=$?
if [ "$rc" != 0 ]; then
  echo "PURGE_FAILED rc=$rc"
  tail -n 15 /tmp/foa_purge.log
  exit 2
fi
# 运行库逐个删：任一失败只记录，不中断（它们可能被别的包依赖）
libs_fail=""
for p in libatomic1:amd64 zlib1g:amd64 libgcc-s1:amd64 libstdc++6:amd64 libc6:amd64; do
  dpkg -l "$p" 2>/dev/null | grep -q '^ii' || continue
  if ! DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$p" >> /tmp/foa_purge.log 2>&1; then
    libs_fail="$libs_fail $p"
  fi
done
if [ -n "$libs_fail" ]; then
  echo "PURGE_LIBS_PARTIAL:$libs_fail"
fi
[ -x @QEMU@ ] && { echo QEMU_STILL_PRESENT; exit 3; }
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
    // Bug 437：impellerc / font-subset 也纳入判定——它们才是真机 AOT
    // 阶段实际执行、也确实崩过的工具
    final impOk = kv('IMPELLERC') == 'yes';
    final fsOk = kv('FONT_SUBSET') == 'yes';
    final dartOk = kv('DART') == 'yes';
    final aaptOk = kv('AAPT2') == 'yes';
    final gradleOk = kv('GRADLE') == 'yes';

    // Bug 437：收集失败工具的诊断行（以两个空格开头的续行），
    // 以及转发目标被覆盖的告警——这些才是真机排障的关键信息
    final diags = <String>[];
    for (final line in r.stdout.split('\n')) {
      final t = line.trimRight();
      if (t.startsWith('  ') && t.trim().isNotEmpty) {
        diags.add(t.trim());
      } else if (t.startsWith('TARGET_BAD=') || t.startsWith('TARGET_MISSING=')) {
        diags.add(t);
      }
    }

    final buf = StringBuffer()
      ..write('qemu ${qemu.split(' ').last}')
      ..write(loaderOk ? ' · x86_64 动态链接器可运行' : ' · 多架构库缺失')
      ..write(dartOk ? ' · flutter 工具链已转发' : ' · flutter 工具链未转发（装 Flutter 后重新应用）')
      ..write(genOk ? ' · gen_snapshot 冒烟通过' : ' · gen_snapshot 不可用')
      ..write(impOk ? ' · impellerc 冒烟通过' : ' · impellerc 不可用（AOT 会在 shader 阶段崩）')
      ..write(fsOk ? ' · font-subset 冒烟通过' : ' · font-subset 不可用')
      ..write(aaptOk ? ' · aapt2 已接管' : ' · SDK 工具未接管')
      ..write(gradleOk ? ' · AGP 已指向本地 aapt2' : ' · gradle 未配置');
    if (diags.isNotEmpty) {
      buf.write('\n诊断详情：\n${diags.map((d) => '  • $d').join('\n')}');
    }
    return buf.toString();
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
        engineWrapScript
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
        sdkWrapScript.replaceAll('@SDK@', sdkHome).replaceAll('@QEMU@', qemuBin),
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
  ///
  /// 公开给**原生 arm64 后端**复用：AGP 9.x 默认从 Maven 拉
  /// `com.android.tools.build:aapt2::<ver>:linux`（x86_64-only），
  /// 无论走 QEMU 转发还是原生 arm64，都必须把 AGP 指回 SDK 里那个
  /// 能在本机跑起来的 aapt2（同一条路径，只是内容不同）。
  static Future<void> writeAapt2Override(String rootfsPath) =>
      _writeGradleOverride(rootfsPath);

  /// 移除 gradle 覆盖项（宿主机直写）。
  static Future<void> removeAapt2Override(String rootfsPath) =>
      _removeGradleOverride(rootfsPath);

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
    final r = await bridge.exec(
      _uninstallScript
          .replaceAll('@SDK@', sdkHome)
          .replaceAll('@ENGINE@', engineDir)
          .replaceAll('@FLUTTER@', flutterHome),
      timeoutSec: 600,
    );
    final out = r.stdout.trim();
    if (!r.ok ||
        out.contains('PURGE_FAILED') ||
        out.contains('QEMU_STILL_PRESENT')) {
      throw DownloadException(
        'x64 兼容层卸载失败：${out.isEmpty ? r.stderr.trim() : out}',
      );
    }
    // Bug 434：多架构运行库可能被其它包依赖，删不掉不算致命——兼容层的
    // 判定标准是「qemu 本体已移除且转发层已还原」，上面已经保证了这一点。
    // 这里只提示，不抛异常，否则"卸不干净"会被误报成"卸载失败"。
    if (out.contains('PURGE_LIBS_PARTIAL:')) {
      final libs =
          out.split('PURGE_LIBS_PARTIAL:').last.split('\n').first.trim();
      stderr.writeln('[QemuCompat] 兼容层已卸载，以下多架构库被其它包依赖、保留：$libs');
    }
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
        engineWrapScript
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
        sdkWrapScript.replaceAll('@SDK@', sdkHome).replaceAll('@QEMU@', qemuBin),
        timeoutSec: 300,
      );
      await _writeGradleOverride(env.rootfsPath);
    } catch (_) {
      // 钩子失败不阻断 SDK 安装。
    }
  }
}
