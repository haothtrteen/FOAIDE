#!/usr/bin/env bash
# ============================================================
# fetch_assets.sh — 下载/准备运行时所需的二进制资产到 assets/
#
# 用法:
#   ./tools/fetch_assets.sh            # proot + rootfs 全部
#   ./tools/fetch_assets.sh proot      # 只准备 proot + loader
#   ./tools/fetch_assets.sh rootfs     # 只准备 rootfs
#
# 说明:
#   - proot 从 Termux 官方 apt 仓库拉 .deb 并解出两个文件:
#       proot-arm64  (proot 本体，bionic 构建，设备上运行)
#       proot-loader (ptrace loader；App 启动时以 PROOT_LOADER 指向它)
#   - rootfs 若已存在（如直接从工作区拿到打包好的）则跳过；
#     否则按文档自建（debootstrap minbase，见 SETUP_ANDROID.md）
#
# 许可证注意:
#   - proot 是 GPL-2.0，分发时必须在 THIRD-PARTY-NOTICES 附源码链接
#   - rootfs 为 Debian 自由软件集合（DFSG），体积大，一律不进 git
# ============================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$APP_DIR/assets/tools"
ROOTFS_DIR="$APP_DIR/assets/rootfs"
TMP="${TMPDIR:-/tmp}/foa-fetch-$$"

# Termux 官方 apt 仓库（版本号升级时改这里）
PROOT_DEB_URL="${PROOT_DEB_URL:-https://packages-cf.termux.dev/apt/termux-main/pool/main/p/proot/proot_5.1.107.92_aarch64.deb}"

mkdir -p "$TOOLS_DIR" "$ROOTFS_DIR"

fetch_proot() {
  if [[ -f "$TOOLS_DIR/proot-arm64" && -f "$TOOLS_DIR/proot-loader" ]]; then
    echo "ℹ️  proot-arm64 / proot-loader 已存在，跳过（删除后重跑可强制更新）"
    return
  fi
  echo "↓ 下载 Termux proot: $PROOT_DEB_URL"
  mkdir -p "$TMP"
  curl -fsSL --retry 3 -o "$TMP/proot.deb" "$PROOT_DEB_URL" \
    || { echo "❌ 下载失败（网络受限？可用 PROOT_DEB_URL 指定镜像）"; exit 1; }

  # 解 deb：优先 dpkg -x，退回 ar + tar
  echo "→ 解包 .deb ..."
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -x "$TMP/proot.deb" "$TMP/pkg"
  elif command -v ar >/dev/null 2>&1; then
    mkdir -p "$TMP/pkg"
    ( cd "$TMP/pkg" && ar p "$TMP/proot.deb" data.tar.xz | tar -xJf - )
  else
    echo "❌ 需要 dpkg 或 ar(binutils)+xz 才能解 .deb；WSL/macOS/Linux 均自带其一"; exit 1
  fi

  B="$TMP/pkg/data/data/com.termux/files/usr"
  cp "$B/bin/proot"              "$TOOLS_DIR/proot-arm64"
  cp "$B/libexec/proot/loader"   "$TOOLS_DIR/proot-loader"
  chmod +x "$TOOLS_DIR/proot-arm64" "$TOOLS_DIR/proot-loader"
  echo "✅ proot-arm64 + proot-loader 已就位"
}

# 真机友好重打包（Bug 209）：
#   Android 应用沙箱不允许 mknod()（/dev 节点）与部分机型的 link()（硬链接），
#   tar 解压会大量报错甚至整体回滚。打包时：
#   1. --hard-dereference：硬链接条目实体化为独立文件副本
#   2. --exclude='./dev/*'：丢弃设备节点（proot -R 运行时绑定宿主 /dev，
#      rootfs 内 dev 只需保留空目录）
#   幂等：仅当检测到硬链接或 dev 条目时才重打。
repack_for_android() {
  local T="$1"
  local bad=0
  if tar -tvzf "$T" 2>/dev/null | grep -q 'link to'; then bad=1; fi
  if tar -tzf  "$T" 2>/dev/null | grep -qE '^\./dev/[^/]+'; then bad=1; fi
  if [[ "$bad" == 0 ]]; then
    echo "✅ tarball 已是 Android 沙箱友好格式（无硬链接/无 dev 节点）"
    return
  fi
  echo "→ 重打包为 Android 沙箱友好格式（硬链接实体化 + 剔除 dev 节点）..."
  local D
  D=$(mktemp -d)
  tar -xzf "$T" -C "$D" 2>/dev/null
  ( cd "$D" && tar --hard-dereference --exclude='./dev/*' \
      --owner=0 --group=0 -czf "$T.new" . )
  mv "$T.new" "$T"
  rm -rf "$D"
  echo "✅ 重打包完成（$(du -h "$T" | cut -f1)）"
}

fetch_rootfs() {
  local R="$ROOTFS_DIR/debian-minbase-arm64.tar.gz"
  if [[ -f "$R" ]]; then
    echo "ℹ️  rootfs tarball 已存在（$(du -h "$R" | cut -f1)），校验格式..."
    repack_for_android "$R"
    return
  fi
  if [[ -n "${ROOTFS_URL:-}" ]]; then
    echo "↓ 下载 rootfs: $ROOTFS_URL"
    curl -fsSL --retry 3 -o "$R.tmp" "$ROOTFS_URL" && mv "$R.tmp" "$R"
    repack_for_android "$R"
    echo "✅ rootfs 已就位（$(du -h "$R" | cut -f1)）"
  else
    cat <<'EOF'
⚠️  rootfs 未配置下载源（ROOTFS_URL）。
自建方式（推荐，与服务器侧 devbox 流程一致）：
  # x86_64 Linux 上：
  apt-get install -y debootstrap qemu-user-static proot
  debootstrap --foreign --arch=arm64 --variant=minbase bookworm rootfs http://mirrors.tuna.tsinghua.edu.cn/debian/
  cp -r /usr/share/debootstrap/. rootfs/usr/share/debootstrap/     # stage2 需要脚本
  proot -q /usr/bin/qemu-aarch64-static -R "$PWD/rootfs" \
      /usr/bin/env DEBOOTSTRAP_DIR=/debootstrap /bin/sh -c '/debootstrap/debootstrap --second-stage'
  rm -rf rootfs/debootstrap rootfs/usr/share/debootstrap rootfs/var/lib/apt/lists/* \
         rootfs/usr/share/doc rootfs/usr/share/man rootfs/usr/share/locale
  # 打包时直接按 Android 友好格式（见 repack_for_android / Bug 209）：
  ( cd rootfs && tar --hard-dereference --exclude='./dev/*' --owner=0 --group=0 \
      -czf ../debian-minbase-arm64.tar.gz . )
详见 SETUP_ANDROID.md「rootfs 的构建」一节。
EOF
    exit 1
  fi
}

case "${1:-all}" in
  proot)  fetch_proot ;;
  rootfs) fetch_rootfs ;;
  all|*)  fetch_proot; fetch_rootfs ;;
esac

echo ""
echo "目录内容:"
ls -lh "$TOOLS_DIR" "$ROOTFS_DIR" | grep -v '^total\|^$'
rm -rf "$TMP"
