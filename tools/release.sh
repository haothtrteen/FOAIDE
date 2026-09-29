#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FOA 一键出包（门禁 → 构建 → 五项 → 归档）
#
# 把本项目散落的出包步骤串成一条命令。步骤刻意保持"可中断、可重入"：
# 每步都会先自检，失败即停并给出处置提示，不会带着问题往下走。
#
# 用法：
#   bash tools/release.sh              # 完整跑（含 analyze + test 门禁）
#   bash tools/release.sh --skip-gate  # 跳过门禁（代码没动时省时间）
#
# 注意：本脚本**不做** git commit / push，交付判断留给人。
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_GATE=0
[[ "${1:-}" == "--skip-gate" ]] && SKIP_GATE=1

step() { echo; echo "════════════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════════════"; }
die()  { echo; echo "❌ $1" >&2; exit 1; }

cd "$REPO_ROOT"

# ---------- 版本号 ----------
VER_RAW="$(grep -E '^version:[[:space:]]*' app/pubspec.yaml | head -1 | sed 's/^version:[[:space:]]*//')"
VERSION="v${VER_RAW%%+*}"
APK_OUT="$REPO_ROOT/dist/FOA-${VERSION}-arm64.apk"
echo "▶ 目标版本：$VERSION"

# ---------- 0. 内存体检 ----------
step "0/5  内存体检"
bash tools/mem_check.sh || true
echo
read -r -p "  内存形势看清了吗？继续构建？[y/N] " _ans
[[ "${_ans:-N}" =~ ^[Yy]$ ]] || die "已中止（先按上文处置内存问题）"

# ---------- 1. 门禁 ----------
if [[ $SKIP_GATE -eq 1 ]]; then
  step "1/5  门禁（已跳过）"
else
  step "1/5  门禁：flutter analyze + flutter test"
  ( cd app
    export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
    export PUB_HOSTED_URL=https://pub.flutter-io.cn
    echo "--- analyze ---"
    ANALYZE_OUT="$(flutter analyze 2>&1)" || true
    echo "$ANALYZE_OUT" | tail -5
    # 基线：只允许 third_party/ 下的问题
    OUTSIDE="$(echo "$ANALYZE_OUT" | grep -E '^\s+(error|warning|info)' | grep -v 'third_party/' || true)"
    if [[ -n "$OUTSIDE" ]]; then
      echo "$OUTSIDE"
      die "analyze 在 third_party/ 之外报出问题——这是新增缺陷，不是基线，不要出包"
    fi
    echo "✅ analyze 仅 third_party/ 基线问题"

    echo "--- test ---"
    flutter test 2>&1 | tail -6 || die "测试未全绿，不要出包"
  )
fi

# ---------- 2. 构建 ----------
step "2/5  release 构建"

# Bug 627：构建会在 mergeReleaseJniLibFolders 这一步炸：
#   Failed to create MD5 hash for file: .../merged_jni_libs/.../libapp.so
#   Cannot access output property 'outputDir' ... Declare the task as untracked
#
# ⚠️ **"libapp.so 半截文件"这个诊断是错的**（alpha.92 实测推翻）：
#    文件好好的——`dd` 分块读完整、`md5sum` 成功、`stat` 大小正常。
#    真因是 **overlayfs 脏页没落盘**：刚写完的文件立刻读会返回
#    `Input/output error`，Gradle 算 MD5 时就撞在这个 IO error 上。
#    `sync` 之后立刻恢复正常（两次出包都是同一处、同一个原因）。
#
# ⚠️⚠️ **"sync 之后立刻恢复"这句话也不够准**（alpha.94 实测推翻）：
#    本轮出包**照着重试分支做了全套（停 daemon → 删目录 → sync）仍然原样复挂**，
#    实测那条报错文件：
#      md5sum → Input/output error；dd 读出 0 字节；stat 大小正常（14.8MB）
#      **等 20 秒后同一个文件 md5sum 立刻成功**（ddf307cb…）
#    结论：**`sync` 只是发起回写，返回≠落盘完成**。alpha.92/93 那两次
#    "sync 后就好了"是碰巧（sync 本身耗掉的那几秒刚好够）。
#    所以重试分支必须**真的等**，而且要**等完验证能读**——见 `_wait_writable`。
#
# 因此重试分支的硬要求（缺一条就必然原地复挂）：
#   1. **先停 daemon 再删目录**：daemon 手里握着 stale 的 task 状态，
#      光删磁盘文件它不知情（alpha.90 实测只删目录 5 秒内复挂）；
#   2. **删完必须 `sync` + 等待落盘 + 验证可读**（只 sync 不够，alpha.94 实测）。

# 写一个探针文件，反复 `sync`+等，直到它**真能读出 md5**。
#
# ⚠️ 诚实说明：这个探针**对 Bug 627 其实是无效的**（alpha.94 实测：探针
# 第 1 轮 2s 就通过，但构建照样挂在同一个文件上——探针能读 ≠ 那个刚被
# Gradle copy 出来的文件能读）。真正解掉 627 的是
# `app/android/app/build.gradle.kts` 里给 merge*JniLibFolders 加的
# `doLast` 等待（见手册 Bug 627 的 alpha.94 更正）。
# 这里保留它，是因为它仍能告诉你"overlayfs 现在是不是整体不正常"，
# 而且比 `sleep 20` 诚实：直接测量"写进去的东西现在读得出来吗"。
_wait_writable() {
  local probe="$REPO_ROOT/app/build/.foa-sync-probe"
  rm -f "$probe" 2>/dev/null
  dd if=/dev/zero of="$probe" bs=1M count=8 2>/dev/null || return 1
  local i
  for i in $(seq 1 20); do
    sync
    sleep 2
    if md5sum "$probe" >/dev/null 2>&1; then
      rm -f "$probe" 2>/dev/null
      echo "   ✅ 落盘已稳定（第 $i 轮，约 $((i * 2))s）"
      return 0
    fi
  done
  rm -f "$probe" 2>/dev/null
  return 1
}
_build_once() {
  ( cd app
    export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
    export PUB_HOSTED_URL=https://pub.flutter-io.cn
    flutter build apk --release --target-platform=android-arm64 2>&1 | tail -12
  )
}

BUILD_LOG="$(mktemp)"
if ! _build_once >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG"
  if grep -q "Failed to create MD5 hash\|Cannot access output property 'outputDir'" "$BUILD_LOG"; then
    echo ""
    echo "⚠️  命中 Bug 627（overlayfs 脏页导致 libapp.so 读不了）。"
    echo "   按「停 daemon → 清产物 → sync 落盘 → 重建」自动重试一次…"
    bash tools/mem_check.sh --clean
    rm -rf app/build/app/intermediates/merged_jni_libs app/android/.gradle
    # 光 sync 不够（alpha.94 实测），要等脏页真落下去并验证能读
    _wait_writable || echo "   ⚠️ 探针一直读不出来：overlayfs 整体状态异常，" \
      "仍尝试重建（627 的真解在 build.gradle.kts 的 doLast，不靠这个探针）"
    echo "   ✅ 已清理并落盘，重建中…"
    if ! _build_once; then
      rm -f "$BUILD_LOG"
      die "自动重试后仍构建失败。看上面最后 12 行，别再盲目重跑。"
    fi
  else
    rm -f "$BUILD_LOG"
    die "构建失败。若报 daemon disappeared → 重跑 bash tools/mem_check.sh --clean 后重试"
  fi
else
  cat "$BUILD_LOG"
fi
rm -f "$BUILD_LOG"

BUILT="$REPO_ROOT/app/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$BUILT" ]] || die "构建报成功但找不到产物：$BUILT"

# ---------- 3. 归档 ----------
step "3/5  归档到 dist/"
cp "$BUILT" "$APK_OUT"

# ⚠️⚠️ alpha.97：`cp` 返回 ≠ 落盘完成 ⚠️⚠️
#
# 真机实测（overlayfs，与 Bug 627 同一环境）：`cp` 返回后**立刻**全量
# 回读，会撞上内核仍在回写的脏页 → 该文件系统对这种读取直接返回
# `Input/output error`。后果是**后续所有校验一起挂**：
#   sha256sum: dist/FOA-...apk: Input/output error
#   【1/5】ABI 架构 实际：（空）  ❌ 未找到 arm64-v8a
#   【3/5】签名      ❌ 签名验证失败
# 看上去像"构建产物坏了"，其实**只是那一个窗口读不得**——等一会儿再读
# 就完整了，sha256 与源文件一模一样。
#
# 差点因此重出一版包。所以这里必须 sync。
#
# 怎么区分"产物真坏"和"只是没落盘"：**去读源文件**（$BUILT）。
# 源文件能完整读 + 只有 dist 拷贝读不了 → 落盘时序问题，不要重出包。
sync

sha256sum "$APK_OUT" | awk '{print $1"  "$2}' > "$APK_OUT.sha256"
# 回读复核：确认校验和真的落盘了、且能对上
ACTUAL="$(sha256sum "$APK_OUT" | awk '{print $1}')"
EXPECT="$(awk '{print $1}' "$APK_OUT.sha256")"
[[ -n "$ACTUAL" && "$ACTUAL" == "$EXPECT" ]] \
  || die "归档文件校验和回读不一致（$ACTUAL vs $EXPECT）——多半是落盘问题，重跑本步即可"
echo "  ✅ $APK_OUT"
echo "     $(du -h "$APK_OUT" | cut -f1)"
cat "$APK_OUT.sha256" | sed 's/^/     /'

# ---------- 4. 五项 ----------
step "4/5  五项验证"
bash tools/verify_apk.sh "$APK_OUT" || die "五项验证未通过，**不要交付**"

# ---------- 5. 源码包 ----------
step "5/5  源码交付包"
read -r -p "  同时生成源码 zip？[y/N] " _zip
if [[ "${_zip:-N}" =~ ^[Yy]$ ]]; then
  bash tools/pack_source.sh "$VERSION"
else
  echo "  已跳过"
fi

echo
echo "════════════════════════════════════════════════════"
echo "  ✅ 出包完成：$VERSION"
echo "════════════════════════════════════════════════════"
