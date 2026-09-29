#!/usr/bin/env bash
#
# 打一个「可直接推送到远端」的仓库快照 tar.gz。
#
# 用途：把整仓（含 .git）压成一个包，对方解包后 `git remote set-url` 就能推，
# 不需要重新 init，历史完整。
#
# 用法：
#   bash tools/make_release_tarball.sh                 # 默认：含 rootfs/proot（解包即可构建）
#   bash tools/make_release_tarball.sh --slim          # 瘦包：与 git 仓库内容逐字节一致
#   bash tools/make_release_tarball.sh /tmp/out.tar.gz # 指定输出路径
#
# 两种模式的区别只在 `app/assets/` 下的**未跟踪资产**（rootfs 75MB + proot）：
#   - 默认包含：解包的人能立刻构建。
#     **为什么不排除**：`fetch_assets.sh` 的 rootfs 没有默认下载源
#     （ROOTFS_URL 未配置 → 脚本直接 exit 1），丢了只能靠 debootstrap 自建。
#     而且这些文件被 .gitignore 排除 → **不会进 GitHub**，
#     `git push` 只推已跟踪文件，所以带上它们对远端零影响。
#   - --slim：排除它们，体积 ≈ git 仓库实际大小，适合当"远端镜像"存档。
#
# ⚠️ 踩过的坑（别改回去）：
#   1. 用 `--exclude-from=FILE` 或 `-X FILE`。
#      早期写成 `--exclude='FOA/FOA/app/build'` 而 cwd 在 /workspace ——
#      排除路径是**相对于 -C 的目录**，前缀写错 → 静默不生效 →
#      包从 87MB 涨到 590MB 还没报错。
#   2. tar 的排除列表**不能用注释**（没有 `#` 语义），会当成文件名。
#   3. 打包后**必须回读复核 sha256**。overlayfs 下 cp/tar 返回不等于落盘
#      完成，立刻全量回读会撞内核回写的脏页（本仓 Bug 627 同族，已复发 8 次）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

EXCL="$REPO_ROOT/tools/package-excludes.txt"
STAMP="$(date +%Y%m%d)"

SLIM=0
OUT=""
for a in "$@"; do
  case "$a" in
    --slim) SLIM=1 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) OUT="$a" ;;
  esac
done
OUT="${OUT:-$(cd "$REPO_ROOT/.." && pwd)/FOA-github-ready-${STAMP}.tar.gz}"

[ -f "$EXCL" ] || { echo "缺少排除清单: $EXCL" >&2; exit 2; }

# --slim 时在排除清单基础上追加"未跟踪资产"（rootfs + proot）。
# 用临时文件：tar 只接受文件路径，不接受进程替换（且要保持可移植）。
EXCL_EFFECTIVE="$EXCL"
if [ "$SLIM" -eq 1 ]; then
  EXCL_EFFECTIVE="$(mktemp)"
  trap 'rm -f "$EXCL_EFFECTIVE"' EXIT
  grep -v '^#' "$EXCL" > "$EXCL_EFFECTIVE"
  cat >> "$EXCL_EFFECTIVE" <<'EOF'
./app/assets/rootfs/debian-minbase-arm64.tar.gz
./app/assets/tools/proot-arm64
./app/assets/tools/proot-loader
./app/assets/tools/foa_pty
EOF
fi

# --- 前置检查：不该有的东西不能进包 -------------------------------------
if [ -n "$(git status --porcelain)" ]; then
  echo "⚠️  工作区有未提交改动，打出来的包和 HEAD 不一致：" >&2
  git status --porcelain | head -20 >&2
  echo "   要么先 commit，要么确认这是你要的。" >&2
fi

echo "仓库: $REPO_ROOT"
echo "输出: $OUT"
echo "模式: $([ "$SLIM" -eq 1 ] && echo '--slim（不含 rootfs/proot）' || echo '默认（含 rootfs/proot，解包即可构建）')"
echo "排除: $(grep -vc '^#' "$EXCL_EFFECTIVE") 条"

rm -f "$OUT"
tar czf "$OUT" --exclude-from="$EXCL_EFFECTIVE" -C "$REPO_ROOT" .

# --- 落盘时序防护：sync 两次 + 回读复核（Bug 627 同族）-------------------
sync
sleep 2
sync

SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "$SHA  $(basename "$OUT")" > "${OUT}.sha256"

# ⚠️ 用 `--check` 时校验文件里写的是 basename，sha256sum 会**按当前 cwd**
#    去找那个名字 —— 而本脚本的 cwd 是仓库根，不是 $OUT 所在目录。
#    所以这里显式 cd 到 $OUT 的目录再校验，否则永远 "No such file"。
if ! (cd "$(dirname "$OUT")" && sha256sum -c "$(basename "${OUT}.sha256")" --quiet); then
  echo "❌ 回读复核失败：包可能没落盘完整。重跑本脚本。" >&2
  exit 1
fi

# --- 内容自检 ------------------------------------------------------------
# ⚠️ 只解一次 tar 清单缓存起来。**不要**在下面的循环里反复 `tar tzf "$OUT"`：
#    每跑一次就要把整个包重新解压一遍（87MB 还行，误把 dist 打进来时是 2.8GB ×
#    11 条规则 ≈ 5 分钟）。实测：列一次清单 vs 循环内列 11 次。
LISTING="$(tar tzf "$OUT")"
SIZE="$(du -h "$OUT" | cut -f1)"
ENTRIES="$(printf '%s\n' "$LISTING" | wc -l)"
GIT_ENTRIES="$(printf '%s\n' "$LISTING" | grep -c '^\./\.git/' || true)"

echo
echo "=== 打包完成 ==="
printf '体积    : %s\n' "$SIZE"
printf '条目    : %s\n' "$ENTRIES"
printf '.git 项 : %s\n' "$GIT_ENTRIES"
printf 'SHA256  : %s\n' "$SHA"

if [ "$GIT_ENTRIES" -lt 100 ]; then
  echo "❌ .git 不完整（只有 $GIT_ENTRIES 项），这个包不能用来推远端！" >&2
  exit 1
fi

# ⚠️ 校验循环必须用 `done < file` 重定向，**不能**写成 `cat file | while ...`。
#    管道里的 while 跑在子 shell 中，BAD=1 的赋值出了管道就丢了，
#    循环结束后永远读到 BAD=0，"排除失效"会被静默吞掉 —— 门禁等于没有门禁。
#    （本仓对门禁的硬性要求：必须验证它"真的能失败"，见 CONTRIBUTING.md。）
BAD=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in \#*) continue ;; esac
  # ⚠️ 不能裸用 `grep -F "$p"`：那是**子串**匹配，会把同名前缀的无关文件算进来。
  #    实测踩到：`./app/build` 命中 `./app/build_progress_preview.html`、
  #    `./app/android/build` 命中 `./app/android/build.gradle.kts`
  #    —— 两个都是**应当入库**的源码文件，于是门禁报了根本不存在的"排除失效"。
  #    正确判据：条目 == 该路径本身，或 以 该路径 + "/" 开头（即它的子内容）。
  # ⚠️ 用 here-string（`<<<`）**不要**用管道。
  #    `grep -q` 一找到匹配就立刻退出并关闭管道，写端的 printf 会收到
  #    SIGPIPE → 退出 141；而脚本开头是 `set -o pipefail`，于是**整个管道
  #    返回非零** —— 明明"找到了"，却被判成"没找到"。
  #    表现是**间歇性**的：取决于 printf 是否已写完（小清单碰巧通过，
  #    大清单必挂）。实测：84MB 包的 rootfs 校验时有时无就是这个原因。
  if grep -qxF "$p" <<< "$LISTING" || grep -qF "$p/" <<< "$LISTING"; then
    echo "❌ 排除失效: $p 仍在包里" >&2
    BAD=1
  fi
done < "$EXCL_EFFECTIVE"
[ "$BAD" -eq 0 ] || exit 1
echo "✅ 排除规则全部生效"

# --- 默认模式：确认不可再生的资产确实在包里 -------------------------------
if [ "$SLIM" -eq 0 ]; then
  MISSING=0
  for f in './app/assets/rootfs/debian-minbase-arm64.tar.gz' './app/assets/tools/proot-arm64'; do
    if ! grep -qxF "$f" <<< "$LISTING"; then
      echo "❌ 关键资产缺失: $f（rootfs 无公共下载源，丢了就建不起来）" >&2
      MISSING=1
    fi
  done
  [ "$MISSING" -eq 0 ] || exit 1
  echo "✅ 不可再生资产（rootfs / proot）已包含"
fi
echo "✅ 已通过回读复核"
