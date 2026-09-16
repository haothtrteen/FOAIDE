#!/usr/bin/env bash
# ============================================================
# fetch_assets.sh — 下载运行时所需的二进制资产到 assets/
#
# 用法:
#   ./tools/fetch_assets.sh            # 下载全部（proot + rootfs）
#   ./tools/fetch_assets.sh proot      # 只下载 proot
#   ./tools/fetch_assets.sh rootfs     # 只下载 rootfs
#
# 可用环境变量覆盖默认源（默认源失效或需走镜像时）:
#   PROOT_URL=...  ROOTFS_URL=...
#
# 许可证注意:
#   - proot 是 GPL-2.0，分发时必须在 THIRD-PARTY-NOTICES
#     附源码获取链接（见 README）
#   - rootfs 为 Debian 自由软件集合，体积大，一律不进 git
# ============================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$APP_DIR/assets/tools"
ROOTFS_DIR="$APP_DIR/assets/rootfs"

# ---- 默认下载源（可被环境变量覆盖）------------------------
# proot: Termux 维护的 proot 分支发布页（含 Android 可用的静态构建）
# 具体版本文件名请在发布页确认后填入:
#   https://github.com/termux/proot/releases
PROOT_URL="${PROOT_URL:-}"

# rootfs: Debian arm64 minbase
# 推荐用 Docker 导出（保证纯度）:
#   docker pull --platform=linux/arm64 debian:bookworm-slim
#   docker run --platform=linux/arm64 debian:bookworm-slim tar cf - . | gzip > debian-minbase-arm64.tar.gz
# 或使用 proot-distro 支持的 Debian 发行版 tarball
ROOTFS_URL="${ROOTFS_URL:-}"

mkdir -p "$TOOLS_DIR" "$ROOTFS_DIR"

fetch() {
  local url="$1" dest="$2"
  if [[ -z "$url" ]]; then
    echo "❌ 未配置下载地址。请设置环境变量或编辑本脚本:"
    echo "   export PROOT_URL=...  /  export ROOTFS_URL=..."
    exit 1
  fi
  echo "↓ 下载: $url"
  if command -v wget >/dev/null 2>&1; then
    wget -c -O "$dest.tmp" "$url"
  else
    curl -L -C - -o "$dest.tmp" "$url"
  fi
  mv "$dest.tmp" "$dest"
  echo "✅ 已保存: $dest ($(du -h "$dest" | cut -f1))"
}

case "${1:-all}" in
  proot)
    fetch "$PROOT_URL" "$TOOLS_DIR/proot-arm64"
    chmod +x "$TOOLS_DIR/proot-arm64"
    ;;
  rootfs)
    fetch "$ROOTFS_URL" "$ROOTFS_DIR/debian-minbase-arm64.tar.gz"
    ;;
  all|*)
    fetch "$PROOT_URL" "$TOOLS_DIR/proot-arm64"
    chmod +x "$TOOLS_DIR/proot-arm64"
    fetch "$ROOTFS_URL" "$ROOTFS_DIR/debian-minbase-arm64.tar.gz"
    ;;
esac

echo ""
echo "完成。目录内容:"
ls -lh "$TOOLS_DIR" "$ROOTFS_DIR"
