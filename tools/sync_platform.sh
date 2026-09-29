#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# platform/ 模板漂移检测与同步（Bug 440 / Bug 639）
#
# ## 为什么需要这个脚本
#
# `platform/` 下的文件是**新工程脚手架的模板**：用户新建工程时，FOA 把
# 它们拷进工程的 android/ 里。而 FOA 自己这套 `android/` 是**同一份代码的
# 活样本**。
#
# 问题在于：**改一边不会让另一边报错**。手册里记着一段血泪——
# `platform/` 的 MainActivity.kt 落后了整整一个月，269 行 PTY 代码
# **一次都没进过构建目录**，而整个测试套件全绿。
#
# 原因很朴素：测试当时是**分别**断言两个文件"各含某些字符串"，
# 而不是断言**两者相同**。一个文件多了东西、另一个没有，两边各自的
# 断言都还是过的。
#
# ## 用法
#
#   bash tools/sync_platform.sh          # 检查（不一致则退出码 1）
#   bash tools/sync_platform.sh --fix    # 把 android/ 的实际文件写回 platform/
#
# 方向说明：**以 android/ 下正在编译的那份为准**，回写到 platform/。
# 因为能编译、能跑的那份才是事实；模板只是它的一个副本。
#
# 注意：`flutter test` 里也有一道同名门禁（test/platform_drift_test.dart），
# 用的是同一份映射表。两者是**双保险**：测试拦 CI，脚本方便手动修。
# 改映射表时两边都要改。
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/app" || exit 1

FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

# 模板  →  实际编译的那份
# （与 test/platform_drift_test.dart 的 _pairs 保持一致）
#
# ⚠️ 只列**两份都应该存在的副本**。
#    `platform/android/pty/foa_pty.c` **不在表里**，因为它没有第二份：
#    它是 C 源码，编译产物是 `assets/tools/foa_pty`（二进制，单向派生）。
#    把它塞进这张表会让本脚本永远报"实际文件不存在"。
PAIRS=(
  "platform/android/AndroidManifest.xml|android/app/src/main/AndroidManifest.xml"
  "platform/android/gradle.properties|android/gradle.properties"
  "platform/android/MainActivity.kt|android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt"
  "platform/android/PtySession.kt|android/app/src/main/kotlin/dev/foa/flutter_on_android/PtySession.kt"
)

drift=0
missing=0

for p in "${PAIRS[@]}"; do
  tpl="${p%%|*}"
  real="${p##*|}"

  if [[ ! -f "$tpl" ]]; then
    echo "⚠ 模板不存在（映射表过期？）：$tpl"
    missing=$((missing+1))
    continue
  fi
  if [[ ! -f "$real" ]]; then
    echo "⚠ 实际文件不存在（映射表过期？）：$real"
    missing=$((missing+1))
    continue
  fi

  if diff -q "$tpl" "$real" >/dev/null 2>&1; then
    echo "✅ $(basename "$tpl")  一致"
  else
    echo "❌ $(basename "$tpl")  **漂移**"
    diff -u "$tpl" "$real" | head -30 | sed 's/^/     /'
    drift=$((drift+1))
    if [[ $FIX -eq 1 ]]; then
      cp "$real" "$tpl"
      echo "     → 已用 $real 覆盖模板"
    fi
  fi
done

echo
if [[ $missing -gt 0 ]]; then
  echo "❌ 有 $missing 条映射对不上文件 —— 请更新本脚本与测试里的映射表"
  exit 2
fi

if [[ $drift -eq 0 ]]; then
  echo "✅ platform/ 模板与 android/ 实际文件全部一致"
  exit 0
fi

if [[ $FIX -eq 1 ]]; then
  echo "✅ 已同步 $drift 个文件（记得重跑 flutter test 确认）"
  exit 0
fi

echo "❌ 检测到 $drift 处漂移。"
echo "   若这份改动是"改好了 android/ 的代码"，跑：bash tools/sync_platform.sh --fix"
echo "   若这份改动是"只想改模板不动自己"，那你多半改错地方了 —— "
echo "   platform/ 只是副本，真正被编译的是 android/ 下那份。"
exit 1
