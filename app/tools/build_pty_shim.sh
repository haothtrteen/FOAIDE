#!/usr/bin/env bash
# ============================================================
# build_pty_shim.sh — 编译 FOA 的 PTY 中继器（可交互终端用）
#
# 用法:
#   ./tools/build_pty_shim.sh              # 自动探测 NDK 并编译
#   NDK=/path/to/ndk ./tools/build_pty_shim.sh
#   ./tools/build_pty_shim.sh --verify     # 额外做宿主侧行为自测
#
# 产物: assets/tools/foa_pty  (aarch64, 纯 bionic，仅依赖 libc/libdl)
#
# 背景（为什么需要自己写一个 C 中继器）
# ------------------------------------
# Android/JVM 没有 pty API，ProcessBuilder 只能给出单向管道，
# 于是 apt 进度条 / vim / top / Ctrl+C / 方向键历史 全部失效。
# foa_pty.c 用 bionic 的 openpty() 建真 tty，setsid + TIOCSCTTY +
# tcsetpgrp 建立前台进程组，再把「本进程 stdin/stdout」与
# 「pty master」双向对接。约 10KB，无第三方依赖。
#
# 关键实现点（踩过的坑，详见源码注释与 dev-handbook Bug 430）
#   - c_cc[] 控制字符必须显式赋值，否则 stty 显示 intr=<undef>，
#     Ctrl+C 不生效（屏幕回显 ^C 但进程继续跑）
#   - setsid() 后不能对会话首进程 setpgid()（EPERM）；
#     父进程也不能 setpgid(子进程, 子进程)，否则子进程 setsid() 失败
#   - 中继进程要忽略 SIGINT/SIGQUIT/SIGTSTP，否则 Ctrl+C 会打到自己
#   - 尺寸热更新走 FOA_PTY_SIZE_FILE 控制文件（poll 带 200ms 超时）
# ============================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$APP_DIR/platform/android/pty/foa_pty.c"
OUT_DIR="$APP_DIR/assets/tools"
OUT="$OUT_DIR/foa_pty"

VERIFY=0
for a in "$@"; do
  case "$a" in
    --verify) VERIFY=1 ;;
  esac
done

[ -f "$SRC" ] || { echo "❌ 找不到源码: $SRC"; exit 1; }
mkdir -p "$OUT_DIR"

# ---------- 定位 NDK ----------
find_ndk() {
  if [ -n "${NDK:-}" ] && [ -d "${NDK}" ]; then echo "$NDK"; return; fi
  # flutter 的 android-sdk 配置
  local sdkroot=""
  if command -v flutter >/dev/null 2>&1; then
    sdkroot="$(flutter config --list 2>/dev/null | sed -n 's/^ *android-sdk: *//p' | head -1)"
  fi
  for base in "$sdkroot" "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
              "$HOME/Android/Sdk" /opt/android-sdk /usr/lib/android-sdk; do
    [ -n "$base" ] && [ -d "$base/ndk" ] || continue
    # 取版本号最大的一个
    local best
    best="$(ls -1 "$base/ndk" 2>/dev/null | sort -V | tail -1)"
    [ -n "$best" ] && { echo "$base/ndk/$best"; return; }
  done
}

NDK_DIR="$(find_ndk || true)"
if [ -z "$NDK_DIR" ]; then
  cat <<'EOF'
❌ 未找到 Android NDK。

请二选一：
  1) 装 NDK：sdkmanager --install "ndk;28.2.13676358"
     然后 NDK=/path/to/ndk ./tools/build_pty_shim.sh
  2) 直接复用已编译好的 assets/tools/foa_pty（仓库/发行包内已带）

注意：NDK 只需在**开发机**上存在一次，用户设备完全不需要——
      foa_pty 是编译产物，随 APK 分发。
EOF
  exit 1
fi

CLANG="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang"
if [ ! -x "$CLANG" ]; then
  # 个别 NDK 版本 API level 不同，找一个可用的
  CLANG="$(ls -1 "$NDK_DIR"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android*-clang 2>/dev/null | sort -V | head -1)"
fi
[ -x "$CLANG" ] || { echo "❌ NDK 内找不到 aarch64 clang: $NDK_DIR"; exit 1; }

echo "NDK   : $NDK_DIR"
echo "CLANG : $CLANG"

# ---------- 编译 ----------
# -O2 体积/速度平衡；-Wall -Wextra 保持零警告（历史 bug 都能被它抓到）
# -fPIE -pie：Android 5.0+ 强制 PIE
"$CLANG" -O2 -Wall -Wextra -fPIE -pie "$SRC" -o "$OUT"
chmod 755 "$OUT"

echo "✅ 编译完成: $OUT ($(stat -c%s "$OUT") bytes)"

# ---------- 依赖体检 ----------
READELF="$(dirname "$CLANG")/llvm-readelf"
if [ -x "$READELF" ]; then
  echo "--- 动态依赖（必须只有 bionic 系统库）---"
  "$READELF" -d "$OUT" | grep NEEDED || true
  BAD="$("$READELF" -d "$OUT" | grep NEEDED | grep -Ev 'libc\.so|libdl\.so|libm\.so' || true)"
  if [ -n "$BAD" ]; then
    echo "❌ 出现非 bionic 依赖，设备上会加载失败："
    echo "$BAD"
    exit 1
  fi
  echo "✅ 依赖干净（纯 bionic）"
fi

# ---------- 可选：宿主侧行为自测 ----------
if [ "$VERIFY" = 1 ]; then
  echo
  echo "=== 宿主侧行为自测（同样 POSIX 语义，仅验证中继正确性）==="
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT
  gcc -O2 -Wall -Wextra "$SRC" -o "$TMPD/foa_pty_host" 2>/dev/null \
    || { echo "⚠️  宿主 gcc 不可用，跳过热测"; exit 0; }
  H="$TMPD/foa_pty_host"

  echo -n "  [1] 真 tty 检测 ... "
  R="$(printf 'exit\n' | "$H" 24 80 /bin/sh -c 'if [ -t 0 ]; then echo TTY; else echo NOTTY; fi')"
  echo "$R" | grep -q TTY && echo "✅ isatty=真" || { echo "❌ $R"; exit 1; }

  echo -n "  [2] 退出码透传 ... "
  set +e
  printf '' | "$H" 24 80 /bin/sh -c 'exit 42'
  RC=$?
  set -e
  [ "$RC" -eq 42 ] && echo "✅ 42" || { echo "❌ 期望 42，实得 $RC"; exit 1; }

  echo -n "  [3] exec 失败上报 ... "
  set +e
  printf '' | "$H" 24 80 /no/such/cmd-xyz
  RC=$?
  set -e
  [ "$RC" -eq 127 ] && echo "✅ 127" || { echo "❌ 期望 127，实得 $RC"; exit 1; }

  echo -n "  [4] 尺寸透传 ... "
  printf '24 80' > "$TMPD/sz"
  R="$(FOA_PTY_SIZE_FILE="$TMPD/sz" "$H" 24 80 /bin/sh -c 'stty size')"
  echo "$R" | grep -q '24 80' && echo "✅ 初始 24 80" || { echo "❌ $R"; exit 1; }

  echo -n "  [5] 控制字符定义 ... "
  R="$(printf 'exit\n' | "$H" 24 80 /bin/sh -c 'stty -a' | head -3 | tr '\n' ' ')"
  echo "$R" | grep -q 'intr = \^C' && echo "✅ intr=^C" || { echo "❌ $R"; exit 1; }

  echo "✅ 全部通过"
fi

echo
echo "提示：src 变更后请重跑本脚本；assets/tools/foa_pty 随 APK 分发。"
