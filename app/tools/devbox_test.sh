#!/usr/bin/env bash
# ============================================================
# devbox_test.sh — 服务器侧（x86_64）同步验证 harness
#
# 用途：在你把真机测试交给用户前，先在 x86 服务器上验证
#       rootfs 的内容/结构/命令行为与真机预期一致。
#
# 原理：x86_64 proot 原生运行（ptrace 不受影响），
#       rootfs 内的 arm64 二进制由 qemu-aarch64-static 翻译执行：
#         proot -q /usr/bin/qemu-aarch64-static -R <rootfs> <cmd>
#       rootfs 与真机用的是同一个 tarball —— 这就是同步点。
#
# 依赖（Ubuntu/Debian x86_64 + root）：
#   apt-get install -y qemu-user-static proot
#   （本沙箱已装好）
#
# 用法：
#   ./tools/devbox_test.sh                    # 完整流程（解压+测试）
#   ./tools/devbox_test.sh test               # 只跑测试（rootfs 已解压）
#   ROOTFS_TAR=/path/to/x.tar.gz ./tools/devbox_test.sh   # 指定别的 tarball
# ============================================================
set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${DEVBOX_WORK:-/data/user/work/devbox}"
QEMU=/usr/bin/qemu-aarch64-static
ROOTFS_TAR="${ROOTFS_TAR:-$APP_DIR/assets/rootfs/debian-minbase-arm64.tar.gz}"
ROOTFS_DIR="$WORK/rootfs"

# 与 App 终端页（lib/ui/terminal_page.dart）保持一致的命令集
CMDS=(
  "hello|echo hello|hello"
  "uname|uname -m|aarch64"
  "os|head -1 /etc/os-release|GNU/Linux 12"
  "apt|apt --version|apt 2"
  "id|id -u|0"
)

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ 缺少 $1"; exit 1; }; }
need proot; need qemu-aarch64-static; [[ -f $QEMU ]] || QEMU=$(command -v qemu-aarch64-static)

prepare() {
  [[ -f "$ROOTFS_TAR" ]] || { echo "❌ 未找到 rootfs tarball: $ROOTFS_TAR"; exit 1; }
  if [[ -x "$ROOTFS_DIR/bin/sh" ]]; then echo "ℹ️  rootfs 已解压，跳过"; return; fi
  mkdir -p "$ROOTFS_DIR"
  echo "→ 解压 $ROOTFS_TAR ..."
  tar -xJf "$ROOTFS_TAR" -C "$ROOTFS_DIR" 2>/dev/null || tar -xzf "$ROOTFS_TAR" -C "$ROOTFS_DIR"
  # 层级兼容（与 MainActivity.installRootfs 相同的规则）
  if [[ ! -e "$ROOTFS_DIR/bin" && -e "$ROOTFS_DIR/debian/bin" ]]; then
    mv "$ROOTFS_DIR/debian" "$WORK/rootfs-moved" && rm -rf "$ROOTFS_DIR" && mv "$WORK/rootfs-moved" "$ROOTFS_DIR"
  fi
}

run_tests() {
  [[ -e "$ROOTFS_DIR/bin/sh" ]] || { echo "❌ rootfs 无 bin/sh"; exit 1; }
  echo "→ proot -q qemu-aarch64 -R rootfs  执行命令集（与 App 终端页一致）"
  echo "============================================================"
  pass=0; fail=0
  for entry in "${CMDS[@]}"; do
    IFS='|' read -r name cmd expect <<<"$entry"
    out=$(proot -q "$QEMU" -R "$ROOTFS_DIR" -w /root /bin/sh -c "$cmd" 2>&1 || true)
    if echo "$out" | grep -q "$expect"; then
      echo "✅ $name: $(echo "$out" | head -1)"
      pass=$((pass+1))
    else
      echo "❌ $name: 期望含「$expect」，实际:"
      echo "$out" | head -3 | sed 's/^/     /'
      fail=$((fail+1))
    fi
  done
  echo "============================================================"
  echo "结果: $pass 通过 / $fail 失败"
  [[ $fail -eq 0 ]] || exit 1
}

case "${1:-all}" in
  test) run_tests ;;
  all|*) prepare; run_tests ;;
esac
