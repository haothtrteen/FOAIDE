#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FOA 源码交付打包（一键构建版）
#
# 用途：把当前仓库打包成"拿到就能一键构建"的 zip。
#
# 打包内容：
#   ✅ app/ 全部源码（dart / kotlin / gradle / 资源 / 测试）
#   ✅ app/.git/          —— 保留完整提交历史
#   ✅ app/rootfs/        —— 预置 rootfs（未跟踪资产，构建/运行需要）
#   ✅ app/**/jniLibs/    —— 预置原生库（未跟踪资产）
#   ✅ dev-handbook/      —— 开发手册
#   ✅ .trae/skills/      —— 构建验证 skill
#   ✅ 构建流程.md / README.md
#
# 排除内容：
#   ❌ app/build/         —— 构建产物（含全部 APK）
#   ❌ app/.dart_tool/    —— Dart 工具缓存
#   ❌ app/android/.gradle/ 、**/.gradle/  —— Gradle 缓存
#   ❌ 所有 *.apk / *.aab
#
# 用法：
#   bash tools/pack_source.sh                # 版本号自动从 pubspec 读
#   bash tools/pack_source.sh v0.1.0-alpha.63
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------- 1. 解析版本号 ----------
VER_ARG="${1:-}"
if [[ -n "$VER_ARG" ]]; then
  VERSION="$VER_ARG"
else
  # 从 pubspec.yaml 读（形如 version: 0.1.0-alpha.63+63）
  RAW="$(grep -E '^version:[[:space:]]*' app/pubspec.yaml | head -1 | sed 's/^version:[[:space:]]*//')"
  VERSION="v${RAW%%+*}"
fi

DATE="$(date +%Y%m%d)"
OUT_NAME="FOA-${VERSION#v}-源码与文档-${DATE}.zip"
OUT_PATH="$REPO_ROOT/dist/$OUT_NAME"

mkdir -p "$REPO_ROOT/dist"

# ---------- 2. 暂存目录 ----------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/FOA"
mkdir -p "$DEST"

echo "▶ 版本：$VERSION"
echo "▶ 输出：$OUT_PATH"
echo

# ---------- 3. 拷贝（带排除） ----------
# ⚠️ 刻意不用 rsync：它不是所有环境都预装（本沙箱就没有，实测踩到）。
# 交付包必须"拿到就能跑"，所以只用最基础的工具（cp + find + zip）。
copy_tree() {
  local src="$1" dst="$2"
  if [[ ! -e "$src" ]]; then
    echo "  ⚠ 跳过（不存在）：$src"
    return 0
  fi
  mkdir -p "$dst"
  # 用 cp -a 拷全量，再用 find 精确删除排除项
  cp -a "$src/." "$dst/" 2>/dev/null || true
  find "$dst" \( \
      -name 'build' -o -name '.dart_tool' -o -name '.gradle' \
      -o -name '.idea' -o -name '.kotlin' \
      -o -name '*.apk' -o -name '*.aab' -o -name '*.hprof' \
      -o -name '.DS_Store' -o -name '*.log' \
    \) -exec rm -rf {} + 2>/dev/null || true
}

echo "▶ 拷贝 app/ ..."
copy_tree "$REPO_ROOT/app" "$DEST/app"

echo "▶ 拷贝 dev-handbook/ ..."
copy_tree "$REPO_ROOT/dev-handbook" "$DEST/dev-handbook"

echo "▶ 拷贝 .trae/ ..."
mkdir -p "$DEST/.trae"
copy_tree "$REPO_ROOT/.trae/skills" "$DEST/.trae/skills"

echo "▶ 拷贝 tools/ ..."
copy_tree "$REPO_ROOT/tools" "$DEST/tools"

echo "▶ 拷贝 docs（技术评估文档）..."
mkdir -p "$DEST/docs"
# docs/ 在上游仓库是散落在根目录的评估文档，此处归拢
for f in "$REPO_ROOT"/*评估*.md "$REPO_ROOT"/*分析*.md "$REPO_ROOT"/环境搭建记录.md; do
  [[ -f "$f" ]] && cp "$f" "$DEST/docs/" 2>/dev/null
done
echo "  ✓ $(ls "$DEST/docs" 2>/dev/null | wc -l) 篇评估文档"

echo "▶ 拷贝顶层文档 ..."
for f in README.md 构建流程.md; do
  [[ -f "$REPO_ROOT/$f" ]] && cp "$REPO_ROOT/$f" "$DEST/$f" && echo "  ✓ $f"
done

# ---------- 3.5 版本校验信息（不含 APK 本体） ----------
echo "▶ 写入版本校验信息 ..."
mkdir -p "$DEST/dist"
VER_SHA="$REPO_ROOT/dist/FOA-${VERSION}-arm64.apk.sha256"
if [[ -f "$VER_SHA" ]]; then
  cp "$VER_SHA" "$DEST/dist/"
  echo "  ✓ 含 $(basename "$VER_SHA")"
else
  cat > "$DEST/dist/README.txt" <<'EOT'
本目录刻意不含 APK 本体（按交付要求剔除全部构建产物）。

如需本版本 APK，请按 构建流程.md §2.5 本地构建，
或向提供本包的人索取对应版本的 FOA-<version>-arm64.apk。
构建后可跑 tools/verify_apk.sh 做四件套验证。
EOT
  echo "  ✓ 写入 dist/README.txt（无同版本 sha256 可带）"
fi

# ---------- 4. 安全兜底：确保没有 APK 混入 ----------
echo
echo "▶ 兜底扫描 APK/AAB ..."
FOUND="$(find "$DEST" -type f \( -name '*.apk' -o -name '*.aab' \) 2>/dev/null || true)"
if [[ -n "$FOUND" ]]; then
  echo "  ⚠ 发现构建产物，删除："
  echo "$FOUND" | sed 's/^/    /'
  echo "$FOUND" | xargs -r rm -f
else
  echo "  ✓ 无 APK/AAB"
fi

# ---------- 5. 打 zip ----------
echo
echo "▶ 压缩 ..."
rm -f "$OUT_PATH"
( cd "$STAGE" && zip -rq "$OUT_PATH" FOA )

# ---------- 6. 校验与报告 ----------
SIZE_H="$(du -h "$OUT_PATH" | cut -f1)"
CNT="$(unzip -l "$OUT_PATH" | tail -1 | awk '{print $2}')"
SHA="$(sha256sum "$OUT_PATH" | awk '{print $1}')"

echo
echo "════════════════════════════════════════════"
echo "  ✅ 打包完成"
echo "  文件：$(basename "$OUT_PATH")"
echo "  大小：$SIZE_H"
echo "  文件数：$CNT"
echo "  sha256：$SHA"
echo "════════════════════════════════════════════"
echo
echo "自检清单（务必人工核对）："
chk() {
  local label="$1" pattern="$2" want="$3"
  # ⚠️ 必须 `|| true`：grep -c 无匹配时返回 1，set -e 会直接杀掉整个脚本
  # （表现为：期望为 0 的那几条检查根本不打印，脚本就没了）
  local got; got="$(unzip -l "$OUT_PATH" 2>/dev/null | grep -c -- "$pattern" || true)"
  got="${got:-0}"
  if [[ "$want" == "0" && "$got" == "0" ]] || [[ "$want" == ">0" && "$got" -gt 0 ]]; then
    echo "  ✅ $label → $got"
  else
    echo "  ❌ $label → $got（期望 $want）"
    SELFCHECK_FAIL=1
  fi
}
# 这两条是不能出错的：rootfs 是"拿到就能构建"的关键资产，
# 而 build/ 与 APK 是明确要排除的。写错路径 = 没检查。
chk ".git/ 已包含        " '\.git/'      ">0"
chk "rootfs 已包含（关键）" 'assets/rootfs/' ">0"
chk "proot 工具已包含   " 'assets/tools/proot' ">0"
# 终端版 MCP 是"插上隧道就能用"的应急通道（见 Bug 473）。它必须跟着
# 源码走：用户拿到包、真机上起不来 App 时，这就是唯一的自救手段。
chk "终端版 MCP 已包含  " 'app/tools/foa-sh-mcp.sh' ">0"
chk "无 build/          " 'app/build/'   "0"
chk "无 .dart_tool      " '\.dart_tool/' "0"
# ⚠️ 模式必须锚定"行尾就是 .apk"：早先写成 '\.apk' 会误匹配
# dist/FOA-*.apk.sha256 校验文件（101 字节），把合格包误判成不合格。
chk "无 APK             " '\.apk$'       "0"
echo
if [[ "${SELFCHECK_FAIL:-0}" == "1" ]]; then
  echo "❌ 自检未通过——这个包不要交付！"
else
  echo "✅ 自检全部通过"
fi
echo
echo "写入 sha256 文件 ..."
echo "$SHA  $(basename "$OUT_PATH")" > "$OUT_PATH.sha256"
cat "$OUT_PATH.sha256"
