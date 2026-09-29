#!/usr/bin/env bash
# ============================================================
# fetch_assets.sh — 下载/准备运行时所需的二进制资产到 assets/
#
# 用法:
#   ./tools/fetch_assets.sh            # proot + rootfs
#   ./tools/fetch_assets.sh proot      # 只准备 proot + loader
#   ./tools/fetch_assets.sh rootfs     # 只准备 rootfs
#   ./tools/fetch_assets.sh proroot    # ⛔ 已停用（alpha.69），固定报错返回
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
#   - proroot 的 libproroot*.so 为 **Proprietary**（上游 THIRD_PARTY_LICENSES.md
#     明确「Redistribution of modified binaries is not permitted」）。
#     **alpha.69 起本仓库不再分发这五个文件**：既不随 APK 打包，也不提供
#     下载入口。fetch_proroot() 保留但固定报"已停用"。
#     背景与三个候选方案的取舍见 PROROOT-许可与分发决策.md（方案 A 已落地）；
#     门禁是 tools/verify_apk.sh 第 4/5 项（APK 内不得含 proroot）。
# ============================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$APP_DIR/assets/tools"
ROOTFS_DIR="$APP_DIR/assets/rootfs"
TMP="${TMPDIR:-/tmp}/foa-fetch-$$"

# Termux 官方 apt 仓库（版本号升级时改这里）
PROOT_DEB_URL="${PROOT_DEB_URL:-https://packages-cf.termux.dev/apt/termux-main/pool/main/p/proot/proot_5.1.107.92_aarch64.deb}"
# Termux proot 的动态库依赖（Bug 210：readelf -d proot → NEEDED libtalloc.so.2
# / libandroid-shmem.so / libc.so；前两个 Termux 专有，系统目录没有）
LIBTALLOC_DEB_URL="${LIBTALLOC_DEB_URL:-https://packages.termux.dev/apt/termux-main/pool/main/libt/libtalloc/libtalloc_2.4.3_aarch64.deb}"
LIBSHMEM_DEB_URL="${LIBSHMEM_DEB_URL:-https://packages.termux.dev/apt/termux-main/pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb}"

mkdir -p "$TOOLS_DIR" "$ROOTFS_DIR"

# 解 deb 到 $2（复用 proot 的解包逻辑）
extract_deb() {
  local deb="$1" out="$2"
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -x "$deb" "$out"
  elif command -v ar >/dev/null 2>&1; then
    mkdir -p "$out"
    ( cd "$out" && ar p "$deb" data.tar.xz | tar -xJf - )
  else
    echo "❌ 需要 dpkg 或 ar(binutils)+xz 才能解 .deb；WSL/macOS/Linux 均自带其一"; exit 1
  fi
}

fetch_proot() {
  local need_deps=0
  if [[ -f "$TOOLS_DIR/proot-arm64" && -f "$TOOLS_DIR/proot-loader" ]]; then
    echo "ℹ️  proot-arm64 / proot-loader 已存在，跳过（删除后重跑可强制更新）"
  else
    echo "↓ 下载 Termux proot: $PROOT_DEB_URL"
    mkdir -p "$TMP"
    curl -fsSL --retry 3 -o "$TMP/proot.deb" "$PROOT_DEB_URL" \
      || { echo "❌ 下载失败（网络受限？可用 PROOT_DEB_URL 指定镜像）"; exit 1; }
    echo "→ 解包 .deb ..."
    extract_deb "$TMP/proot.deb" "$TMP/pkg"
    B="$TMP/pkg/data/data/com.termux/files/usr"
    cp "$B/bin/proot"              "$TOOLS_DIR/proot-arm64"
    cp "$B/libexec/proot/loader"   "$TOOLS_DIR/proot-loader"
    chmod +x "$TOOLS_DIR/proot-arm64" "$TOOLS_DIR/proot-loader"
    echo "✅ proot-arm64 + proot-loader 已就位"
  fi
  # proot 的运行时动态库依赖（缺任何一个 linker 都会 CANNOT LINK EXECUTABLE）
  if [[ ! -f "$TOOLS_DIR/libtalloc.so.2" || ! -f "$TOOLS_DIR/libandroid-shmem.so" ]]; then
    mkdir -p "$TMP"
    if [[ ! -f "$TOOLS_DIR/libtalloc.so.2" ]]; then
      echo "↓ 下载 Termux libtalloc: $LIBTALLOC_DEB_URL"
      curl -fsSL --retry 3 -o "$TMP/talloc.deb" "$LIBTALLOC_DEB_URL"
      extract_deb "$TMP/talloc.deb" "$TMP/talloc"
      # .so.2.4.3 实体文件直接以 DT_NEEDED 名字分发（linker 按名字找，内容一致）
      cp "$TMP/talloc/data/data/com.termux/files/usr/lib/libtalloc.so.2.4.3" \
         "$TOOLS_DIR/libtalloc.so.2"
    fi
    if [[ ! -f "$TOOLS_DIR/libandroid-shmem.so" ]]; then
      echo "↓ 下载 Termux libandroid-shmem: $LIBSHMEM_DEB_URL"
      curl -fsSL --retry 3 -o "$TMP/shmem.deb" "$LIBSHMEM_DEB_URL"
      extract_deb "$TMP/shmem.deb" "$TMP/shmem"
      cp "$TMP/shmem/data/data/com.termux/files/usr/lib/libandroid-shmem.so" \
         "$TOOLS_DIR/libandroid-shmem.so"
    fi
    chmod +x "$TOOLS_DIR/libtalloc.so.2" "$TOOLS_DIR/libandroid-shmem.so"
    echo "✅ proot 动态库依赖已就位（libtalloc.so.2 / libandroid-shmem.so）"
  fi
}

# ============================================================
# proroot 五件套（Bug 471e 改造①，2026-09-21）
#
# 与 proot 的区别：**直接部署进 jniLibs/arm64-v8a/**，不是 assets/tools/。
#
# 为什么必须走 jniLibs：libproroot.so 的 PT_INTERP 是
# /system/bin/linker64，它是 **Android 原生 launcher**，必须从
# nativeLibraryDir 直接 exec。而 nativeLibraryDir 的内容只来自 APK 的
# lib/<abi>/ 目录 —— 也就是 jniLibs 打包进去的那几个。
#
# 好消息：五件套**原名就是 lib*.so**，全部符合 Android 的 native lib
# 命名规则，直接放进去即可，**不需要像 proot 那样改名**。
#
# 版本来源只有一个真源：lib/toolchain/proroot_option.dart 的
# pinnedVersion / soAssets（含 size + sha256）。这里从该文件解析出来，
# 避免"两处各写一个版本号"（那正是 Bug 476 的成因）。
PROROOT_JNILIB_DIR="$APP_DIR/android/app/src/main/jniLibs/arm64-v8a"

# 从 Dart 常量解析钉死的版本与五个文件名+sha256
proroot_pin() {
  local dart="$APP_DIR/lib/toolchain/proroot_option.dart"
  [[ -f "$dart" ]] || { echo "❌ 找不到 $dart"; exit 1; }
  PROROOT_VERSION="$(sed -n "s/.*static const String pinnedVersion = '\([^']*\)'.*/\1/p" "$dart" | head -1)"
  [[ -n "$PROROOT_VERSION" ]] || { echo "❌ 无法从 proroot_option.dart 解析 pinnedVersion"; exit 1; }
}

fetch_proroot() {
  # ─────────────────────────────────────────────────────────────
  # ⛔ alpha.69 起停用（方案 A 落地）。
  #
  # 上游许可是 Proprietary，明确
  # "Redistribution of modified binaries is not permitted"，
  # 我们不代分发二进制，故五件套已从 APK 移除
  # （tools/verify_apk.sh 第 4/5 项强制检查 APK 内不得含 proroot）。
  #
  # 这里**刻意保留函数并显式报错**，而不是静默什么都不做：
  #   - 旧文档 / 旧习惯里仍可能出现 `fetch_assets.sh proroot`，
  #     给一句明确的"已停用"远比什么都没有有用；
  #   - 若将来许可口径变化，删掉下面这个 if 块即可恢复原逻辑。
  #
  # 用 `return 1` 而非 `exit 1`：不毒化 all 流程的其余部分
  # （proot / rootfs 仍应正常准备）。
  # ─────────────────────────────────────────────────────────────
  echo "❌ proroot 五件套自 alpha.69 起不再内置，也不再自动下载。"
  echo "   原因：上游许可（Proprietary）禁止再分发二进制，故已从 APK 移除。"
  echo "   如你持有合法副本，可自行导入（App 内「从本地导入」，或手工放到"
  echo "   $PROROOT_JNILIB_DIR）。"
  echo "   详见仓库根目录 PROROOT-许可与分发决策.md 的方案 A。"
  return 1
}

fetch_proroot_legacy() {
  local dart="$APP_DIR/lib/toolchain/proroot_option.dart"
  proroot_pin
  mkdir -p "$PROROOT_JNILIB_DIR" "$TMP/proroot"

  echo "ℹ️  proroot 钉死版本：$PROROOT_VERSION（唯一真源：proroot_option.dart）"

  # 文件名与 sha256 同样从 Dart 解析（name: 'x', sha256: 'y' 交替出现）
  local names shas
  names="$(sed -n "s/.*name: '\(libproroot[^']*\.so\)'.*/\1/p" "$dart")"
  shas="$(sed -n "s/^ *'\([0-9a-f]\{64\}\)',*$/\1/p" "$dart")"
  local -a NAME_ARR SHA_ARR
  mapfile -t NAME_ARR <<<"$names"
  mapfile -t SHA_ARR  <<<"$shas"

  if [[ ${#NAME_ARR[@]} -ne 5 || ${#SHA_ARR[@]} -ne 5 ]]; then
    echo "❌ 解析出的条目数不对：文件名 ${#NAME_ARR[@]} 个、sha256 ${#SHA_ARR[@]} 个（应为 5）"
    echo "   请检查 proroot_option.dart 的 soAssets 结构是否被改动。"
    exit 1
  fi

  local ok=0 skip=0 fail=0
  for i in "${!NAME_ARR[@]}"; do
    local name="${NAME_ARR[$i]}" want="${SHA_ARR[$i]}"
    local dst="$PROROOT_JNILIB_DIR/$name"
    local url="https://raw.githubusercontent.com/coderredlab/proroot/$PROROOT_VERSION/arm64-v8a/$name"

    # 已存在且哈希正确 → 跳过（可重复执行）
    if [[ -f "$dst" ]] && [[ "$(sha256sum "$dst" | cut -d' ' -f1)" == "$want" ]]; then
      echo "   ✓ $name 已就位（哈希一致）"
      skip=$((skip+1)); continue
    fi

    echo "↓ 下载 $name ($PROROOT_VERSION) ..."
    local got=0
    # 国内镜像优先，raw 直链兜底（与 Dart 侧 mirrorsFor 同思路）
    for prefix in "https://gh-proxy.com/" "https://ghfast.top/" ""; do
      if curl -fsSL --retry 2 -o "$TMP/proroot/$name" "${prefix}${url}" 2>/dev/null; then
        got=1; break
      fi
    done
    if [[ $got -ne 1 ]]; then
      echo "   ❌ $name 下载失败（三个源都不通）"; fail=$((fail+1)); continue
    fi

    local actual
    actual="$(sha256sum "$TMP/proroot/$name" | cut -d' ' -f1)"
    if [[ "$actual" != "$want" ]]; then
      echo "   ❌ $name 哈希不符！"
      echo "      期望 $want"
      echo "      实际 $actual"
      echo "      → 上游可能已重发版本，或下载被劫持。**不要使用这个文件。**"
      fail=$((fail+1)); continue
    fi
    cp "$TMP/proroot/$name" "$dst"
    chmod 755 "$dst"
    echo "   ✅ $name 校验通过"
    ok=$((ok+1))
  done

  echo ""
  if [[ $fail -gt 0 ]]; then
    echo "❌ proroot 部署有 $fail 个失败（成功 $ok / 跳过 $skip）"
    echo "   提示：沙箱/CI 若无外网，可在有网机器上跑本脚本后把"
    echo "   android/app/src/main/jniLibs/arm64-v8a/ 一并提交。"
    exit 1
  fi
  echo "✅ proroot 五件套就位（$PROROOT_JNILIB_DIR）"
  ls -la "$PROROOT_JNILIB_DIR" | grep libproroot || true
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

# 真机 DNS 中立化（Bug 402 根因，2026-09-17）：
# debootstrap 构建 rootfs 时会从构建机拷入 /etc/resolv.conf（常见内网 10.x/192.168.x），
# 用户真机容器内 glibc 用它解析必然失败 → apt/pub/gradle 全挂。
# 若 tarball 内 resolv.conf 无公共 DNS，则全量重打包为公共 DNS（阿里/腾讯/谷歌三行）。
normalize_resolvconf() {
  local T="$1" D
  D=$(mktemp -d)
  if tar -xzf "$T" -C "$D" ./etc/resolv.conf 2>/dev/null \
     && grep -qE '^nameserver (223\.5\.5\.5|119\.29\.29\.29|8\.8\.8\.8|114\.114\.114\.114|1\.1\.1\.1)' "$D/etc/resolv.conf"; then
    echo "✅ resolv.conf 已是公共 DNS，无需改写"
    rm -rf "$D"
    return
  fi
  echo "→ 改写 resolv.conf 为公共 DNS（构建机内网 DNS 在真机不可达）..."
  rm -rf "$D"; D=$(mktemp -d)
  tar -xzf "$T" -C "$D" 2>/dev/null
  printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' > "$D/etc/resolv.conf"
  ( cd "$D" && tar --hard-dereference --exclude='./dev/*' --owner=0 --group=0 \
      -czf "$T.new" . )
  mv "$T.new" "$T"
  rm -rf "$D"
  echo "✅ resolv.conf 已中立化（$(du -h "$T" | cut -f1)）"
}

# rootfs 账户完整性（Bug 404，2026-09-17 真机抓到）：
# 源 rootfs 打包时 /etc/passwd /etc/group 处于 dpkg 重写中间态（只剩 passwd-/+、
# group-/+ 备份），真机容器内 apt 报 "No sandbox user '_apt'"、apt-key 写 /tmp
# 失败、TUNA 源签名验证失败 → xz-utils/unzip 装不上。
# 幂等检测：缺失或缺 _apt 用户时补标准 Debian bookworm 骨架（含 _apt/messagebus）
# 与 /etc/hosts，再按 Android 友好格式重打包。
fix_rootfs_accounts() {
  local T="$1" D
  D=$(mktemp -d)
  tar -xzf "$T" -C "$D" 2>/dev/null
  local need=0
  if [[ ! -f "$D/etc/passwd" ]] || ! grep -q '^_apt:' "$D/etc/passwd" 2>/dev/null; then need=1; fi
  if [[ ! -f "$D/etc/group" ]] || ! grep -q '^_apt:' "$D/etc/group" 2>/dev/null; then need=1; fi
  if [[ ! -f "$D/etc/hosts" ]]; then need=1; fi
  if [[ "$need" == 0 ]]; then
    echo "✅ /etc/passwd /etc/group /etc/hosts 完整，无需修复"
    rm -rf "$D"
    return
  fi
  echo "→ 修复 rootfs 账户文件（补 /etc/passwd /etc/group /etc/hosts，含 _apt）..."
  cat > "$D/etc/passwd" <<'EOF'
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
EOF
  cat > "$D/etc/group" <<'EOF'
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
EOF
  printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n127.0.1.1 foa\n' > "$D/etc/hosts"
  chmod 644 "$D/etc/passwd" "$D/etc/group" "$D/etc/hosts"
  ( cd "$D" && tar --hard-dereference --exclude='./dev/*' --owner=0 --group=0 \
      -czf "$T.new" . )
  mv "$T.new" "$T"
  rm -rf "$D"
  echo "✅ 账户文件已修复并重打包（$(du -h "$T" | cut -f1)）"
}

fetch_rootfs() {
  local R="$ROOTFS_DIR/debian-minbase-arm64.tar.gz"
  if [[ -f "$R" ]]; then
    echo "ℹ️  rootfs tarball 已存在（$(du -h "$R" | cut -f1)），校验格式..."
    repack_for_android "$R"
    normalize_resolvconf "$R"
    fix_rootfs_accounts "$R"
    return
  fi
  if [[ -n "${ROOTFS_URL:-}" ]]; then
    echo "↓ 下载 rootfs: $ROOTFS_URL"
    curl -fsSL --retry 3 -o "$R.tmp" "$ROOTFS_URL" && mv "$R.tmp" "$R"
    repack_for_android "$R"
    normalize_resolvconf "$R"
    fix_rootfs_accounts "$R"
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
  proot)   fetch_proot ;;
  rootfs)  fetch_rootfs ;;
  proroot) fetch_proroot ;;          # alpha.69 起固定报"已停用"并返回 1
  # ⚠️ 关键：all/默认 分支**刻意不含 fetch_proroot**。
  # 不加参数跑时必须不会把 proroot 五件套灌回来（那正是本次要杜绝的）。
  all|*)   fetch_proot; fetch_rootfs ;;
esac

# PTY 中继器（Bug 430，可交互终端）：本仓库自有源码，不下载而是本地编译。
# 这里顺带尝试一次——有 NDK 就编出来，没有只提示（不阻断，因为纯构建
# 不一定需要真机终端；但缺它设备上终端页会用不了）。
if [[ ! -f "$TOOLS_DIR/foa_pty" ]]; then
  echo ""
  echo "→ 尝试编译 PTY 中继器（可交互终端用）…"
  if [[ -x "$APP_DIR/tools/build_pty_shim.sh" ]]; then
    if "$APP_DIR/tools/build_pty_shim.sh" >/tmp/foa_pty_build.log 2>&1; then
      echo "   ✅ assets/tools/foa_pty 已生成"
    else
      echo "   ⚠️  编译失败（多半是没有 NDK）——详见 /tmp/foa_pty_build.log"
      echo "       仅影响设备上的可交互终端；不影响 proot/rootfs 准备。"
      echo "       NDK 就绪后单独运行：./tools/build_pty_shim.sh"
    fi
  else
    echo "   ⚠️  未找到 tools/build_pty_shim.sh，跳过"
  fi
fi

echo ""
echo "目录内容:"
ls -lh "$TOOLS_DIR" "$ROOTFS_DIR" | grep -v '^total\|^$'
rm -rf "$TMP"
