#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 构建内存体检
#
# 用途：release 构建前后各跑一次。构建失败报
# 「Gradle build daemon disappeared unexpectedly」时，先跑这个拿证据。
#
# 为什么需要它：这个报错**只有一种可信判据**——cgroup 的 oom_kill 计数器。
# 本项目的 dev-handbook 里曾写过一条错误判据（「free -m 显示 available
# 充足 → JVM 堆耗尽 → 调高堆」），导致 alpha.63 构建白跑 49 分钟。
# 原因是 free -m 读的是**宿主**内存，而 cgroup 配额可能只有 1/15。
#
# 用法：
#   bash tools/mem_check.sh          # 体检
#   bash tools/mem_check.sh --clean  # 体检并清理残留 daemon
# ---------------------------------------------------------------------------
set -uo pipefail

CLEAN=0
[[ "${1:-}" == "--clean" ]] && CLEAN=1

MB() { echo "$(( $1 / 1048576 ))"; }

echo "════════════════════════════════════════════════════════"
echo "  构建内存体检  $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════"

# ---------- 配额 vs 实际 ----------
MAX_F=/sys/fs/cgroup/memory.max
CUR_F=/sys/fs/cgroup/memory.current
PEAK_F=/sys/fs/cgroup/memory.peak

if [[ -f "$MAX_F" ]]; then
  MAX="$(cat $MAX_F)"; CUR="$(cat $CUR_F)"; PEAK="$(cat ${PEAK_F:-$CUR_F})"
  echo
  echo "【配额】cgroup（这才是你能用的量）"
  echo "  上限 : $(MB "$MAX") MB"
  echo "  当前 : $(MB "$CUR") MB   已用 $(( CUR * 100 / MAX ))%"
  echo "  峰值 : $(MB "$PEAK") MB"
else
  echo "  ⚠ 未找到 /sys/fs/cgroup/memory.max（cgroup v2 不可用）"
fi

# ---------- OOM 计数（唯一可信判据） ----------
echo
echo "【判据】OOM 计数器"
EV=/sys/fs/cgroup/memory.events
if [[ -f "$EV" ]]; then
  KILL="$(awk '/^oom_kill/{print $2}' "$EV")"
  echo "  oom_kill = ${KILL:-0}"
  if [[ "${KILL:-0}" -gt 0 ]]; then
    echo "  ⚠ 已被 cgroup OOM killer 击杀过 $KILL 次"
    echo "    → 处置：**调低**堆值（改 android/gradle.properties），不是调高"
    echo "    → 峰值 $(MB "$PEAK")MB vs 上限 $(MB "$MAX")MB，"\
"超了 $(( PEAK - MAX )) 字节" 2>/dev/null || true
  else
    echo "  ✅ 尚未发生 OOM"
  fi
else
  echo "  ⚠ 未找到 memory.events，无法读取"
fi

# ---------- 宿主内存（仅供对照，勿据此决策） ----------
echo
echo "【对照】宿主内存（⚠ 仅供参考，不要用它做判断）"
free -m | awk 'NR==1{print "            "$0} NR==2{print "  宿主："$0}'
echo "  ⚠ 上面这个 available 是**宿主**的。容器里配额可能小得多。"

# ---------- 在跑的 daemon ----------
echo
echo "【现状】在跑的内存大户"
ps aux --sort=-%mem | awk 'NR==1{print "  "$1"  "$6"  "$11} NR>1 && NR<=8{printf "  %-8s %6.0fMB  %s\n", $1, $6/1024, $11}'

# ---------- 堆预算核算 ----------
echo
echo "【核算】JVM 堆预算"
# ⚠️ 路径要从仓库根推，别写死 `/workspace/app/...`（会一直报"未找到"，
# 让人以为没配堆上限）。这里按脚本自身位置回溯到仓库根。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROPS="$REPO_ROOT/app/android/gradle.properties"
if [[ -f "$PROPS" ]]; then
  grep -E '^org\.gradle\.jvmargs|^kotlin\.daemon\.jvmargs' "$PROPS" | sed 's/^/  /'
  echo
  echo "  公式：Σ(所有 daemon 的 -Xmx) + 1.5g(元空间/线程/原生) + 0.5g(页缓存) < cgroup 上限"
  echo "  ⚠ release 构建实测同时存活 3 个 JVM："
  echo "      GradleDaemon + 两个 KotlinCompileDaemon（编译器 2.2.21 / 2.4.0）"
  echo "      漏算任何一个都会翻车（Bug 469）"
else
  echo "  ⚠ 未找到 $PROPS"
fi

# ---------- 可选清理 ----------
if [[ $CLEAN -eq 1 ]]; then
  echo
  echo "【清理】停止残留 daemon"
  ( cd "$REPO_ROOT/app/android" 2>/dev/null && ./gradlew --stop >/dev/null 2>&1 ) || true
  pkill -f KotlinCompileDaemon 2>/dev/null || true
  pkill -f GradleDaemon 2>/dev/null || true
  sleep 4
  echo "  清理后 cgroup: $(MB "$(cat $CUR_F)") MB"
  echo "  ✅ 完成（AOT 产物会保留，重试不重跑 Dart 编译）"
fi

echo
echo "════════════════════════════════════════════════════════"
