#!/usr/bin/env bash
# ============================================================
# check_env.sh — 构建前自检（在桌面机 / 本仓库根目录运行）
# 检查：资产齐全性、proot 架构、rootfs 结构、工具链、真机连接
# ============================================================
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
bad()  { echo "❌ $1"; fail=1; }

echo "== 1. 二进制资产 =="
P="assets/tools/proot-arm64"
if [[ -f "$P" ]]; then
  if command -v file >/dev/null 2>&1; then
    if file "$P" | grep -qiE 'aarch64|ARM64'; then
      ok "proot-arm64 存在且为 aarch64"
    else
      bad "proot-arm64 架构可疑：$(file "$P")（需要 aarch64 静态构建）"
    fi
  else
    warn "proot-arm64 存在（无 file 命令，跳过架构校验）"
  fi
else
  bad "缺少 $P —— 运行 ./tools/fetch_assets.sh proot"
fi

R="assets/rootfs/debian-minbase-arm64.tar.gz"
if [[ -f "$R" ]]; then
  if tar -tzf "$R" >/dev/null 2>&1; then
    ok "rootfs tarball 存在且可读取（$(du -h "$R" | cut -f1)）"
    # 兼容 usrmerge：bin/sh 可能是符号链接，真身在 usr/bin/sh
    # 注意：pipefail 下不要用 grep -q（SIGPIPE 会误报失败），用 grep -c 全量读取
    n=$(tar -tzf "$R" 2>/dev/null | grep -cE '^\./(bin/sh|usr/bin/sh)$')
    if [[ "$n" -gt 0 ]]; then
      ok "tarball 内含 shell（usrmerge 结构正确）"
    else
      warn "tarball 中未找到 bin/sh 或 usr/bin/sh，请核对结构"
    fi
  else
    bad "rootfs tarball 损坏或非 gzip 格式"
  fi
else
  bad "缺少 $R —— 运行 ./tools/fetch_assets.sh rootfs（或从工作区直接下载）"
fi

P2="assets/tools/proot-loader"
if [[ -f "$P2" ]]; then
  ok "proot-loader 存在（Termux proot 的 ptrace loader，PROOT_LOADER 用）"
else
  bad "缺少 $P2 —— 与 proot 一起分发，运行 ./tools/fetch_assets.sh proot"
fi

# PTY 中继器（Bug 430，可交互终端）：本仓库自有源码的编译产物。
# 它不进 git，必须由 build_pty_shim.sh 生成后才能打进 APK——缺了它
# 终端页会报「PTY 中继器未落位」，且**构建本身不会失败**（assets 目录
# 整体被 pubspec 收录），所以这里必须显式查。
PTY="assets/tools/foa_pty"
if [[ -f "$PTY" ]]; then
  if command -v file >/dev/null 2>&1; then
    if file "$PTY" | grep -q 'ARM aarch64'; then
      ok "foa_pty 存在且为 aarch64（$(du -h "$PTY" | cut -f1)）"
    else
      bad "foa_pty 架构可疑：$(file "$PTY")（需要 aarch64）"
    fi
  else
    warn "foa_pty 存在（无 file 命令，跳过架构校验）"
  fi
  # 可执行位必须就绪：APK 内 assets 不保留权限，靠 Kotlin 侧 chmod，
  # 但 bin 自身在源码树里保持 755 便于本地测
  [[ -x "$PTY" ]] || warn "foa_pty 无执行位（本地测试受影响；APK 内由 Kotlin 侧 setExecutable 兜底）"
else
  bad "缺少 $PTY —— 运行 ./tools/build_pty_shim.sh（需 NDK）；可交互终端依赖它"
fi

echo "== 2. jniLibs（proot 双保险路径） =="
if [[ -f android/app/src/main/jniLibs/arm64-v8a/libproot.so ]]; then
  ok "jniLibs/libproot.so 已就位"
else
  warn "jniLibs 中无 libproot.so（运行 ./tools/setup_android.sh 可自动部署；targetSdk 28 下 assets 路径也可用）"
fi

echo "== 3. targetSdk（W^X 关键项） =="
# Flutter 3.47 起模板生成 build.gradle.kts；旧版为 build.gradle
BG=""
for f in android/app/build.gradle.kts android/app/build.gradle; do
  [[ -f "$f" ]] && BG="$f" && break
done
if [[ -n "$BG" ]]; then
  if grep -qE 'targetSdk(Version)?\s*[= ]\s*28\b' "$BG"; then
    ok "targetSdk = 28（$BG，允许执行数据目录二进制）"
  else
    bad "targetSdk 不是 28 —— Android 10+ 将禁止 proot 执行 rootfs 内二进制！"
  fi
else
  warn "未找到 android/app/build.gradle(.kts)（还没运行 setup_android.sh？）"
fi

echo "== 4. 工具链与设备 =="
if command -v flutter >/dev/null 2>&1; then
  ok "flutter: $(flutter --version 2>/dev/null | head -1)"
else
  warn "flutter 不可用（构建 App 需要）"
fi
if command -v adb >/dev/null 2>&1; then
  N=$(adb devices 2>/dev/null | grep -cE '\sdevice$' || true)
  if [[ "$N" -gt 0 ]]; then
    ok "adb：已连接 $N 台设备"
    adb devices | grep -E '\sdevice$' | awk '{print "     - " $1}'
  else
    warn "adb 可用但无设备连接（真机验证需要）"
  fi
else
  warn "adb 不可用（真机调试需要）"
fi

echo ""
if [[ $fail -eq 0 ]]; then
  echo "🎉 自检通过，可以 flutter run"
else
  echo "💥 存在阻塞项，请先修复再构建"
  exit 1
fi
