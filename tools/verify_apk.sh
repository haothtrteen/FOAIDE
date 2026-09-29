#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# APK 出包四件套验证
#
# 用途：release 构建完成后，一键复核这个 APK 是否真的可交付。
#
# 检查项：
#   1. ABI       必须是 arm64-v8a 且仅有它（多 ABI 会让体积翻倍）
#   2. targetSdk 必须是 28（W^X 绕过策略的刻意选择，见构建流程 §2.3）
#   3. 签名      apksigner verify 必须通过
#   4. 合规      APK 内不得含 proroot 的任何 .so（上游许可禁止再分发，
#                见 THIRD-PARTY-NOTICES.md「不代分发二进制的原因」）
#   5. 图标      APK 内必须带上 alpha.69 的新图标（传统 ic_launcher.png +
#                adaptive icon 的 foreground）。这一项防的是「忘记跑
#                `dart run flutter_launcher_icons` 就出包」——那种情况下
#                APK 完全正常、签名也通过，只有装到手机上才发现还是
#                Flutter 默认的蓝色 logo。
#   6. 文案落地  本次改动的关键中文 UI 串必须真的进了 libapp.so。
#                前五项的判据全是"包结构对不对"，跑的是**上一次**的构建
#                产物也照样全绿 —— 只有这一项能证明"你刚写的那几句话
#                真的被编进去了"。
#
# 用法：
#   bash tools/verify_apk.sh dist/FOA-v0.1.0-alpha.72-arm64.apk
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APK="${1:-}"
if [[ -z "$APK" || ! -f "$APK" ]]; then
  echo "用法：bash tools/verify_apk.sh <path-to.apk>" >&2
  exit 2
fi

# 定位 Android SDK 工具（按常见路径依次尝试）
# 注意：`set -u` 下必须用 ${VAR:-} 兜底，否则未定义的 ANDROID_HOME 会直接报错
find_tool() {
  local name="$1"
  local bt
  # 优先级：环境变量 > local.properties > flutter config > 已知路径 > PATH
  local sdk_candidates=()
  [[ -n "${ANDROID_HOME:-}" ]]     && sdk_candidates+=("$ANDROID_HOME")
  [[ -n "${ANDROID_SDK_ROOT:-}" ]] && sdk_candidates+=("$ANDROID_SDK_ROOT")
  # local.properties 的 sdk.dir（仓库自带的权威配置）
  local lp="$REPO_ROOT/app/android/local.properties"
  if [[ -f "$lp" ]]; then
    local d; d="$(grep -E '^sdk\.dir=' "$lp" 2>/dev/null | cut -d= -f2-)"
    [[ -n "$d" ]] && sdk_candidates+=("$d")
  fi
  sdk_candidates+=("$HOME/Android/Sdk" /data/user/work/sdk /opt/android-sdk)

  for sdk in "${sdk_candidates[@]}"; do
    for bt in "$sdk"/build-tools/*/; do
      [[ -x "$bt$name" ]] && { echo "$bt$name"; return 0; }
    done
  done
  command -v "$name" 2>/dev/null && return 0
  return 1
}

AAPT="$(find_tool aapt || true)"
AAPT2="$(find_tool aapt2 || true)"
APKSIGNER="$(find_tool apksigner || true)"

FAIL=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=1; }
# 工具缺失绝不能算通过——「没检查」≠「检查通过」。这是本项目反复踩到的
# 一类错误（探测通过 ≠ 能下完，见 foa-build-verify §八），同样适用。
skip() { echo "  ❌ $1（工具缺失，视为未通过——宁可误报也不要假阳性）"; FAIL=1; }
# 「用不上」而非「没工具」：检查项本身不适用于这个包/环境，
# 记一行提示但**不判红**。与 skip 的区别要守住：
# skip 是"该查却查不了"，warn_hint 是"这一条对这个包无意义"。
warn_hint() { echo "  ℹ️  $1"; }

echo "════════════════════════════════════════════════════════"
echo "  验证：$APK"
echo "  大小：$(du -h "$APK" | cut -f1)"
echo "  sha256：$(sha256sum "$APK" | awk '{print $1}')"
echo "════════════════════════════════════════════════════════"

# ---------- 1. ABI ----------
echo
echo "【1/5】ABI 架构"
if [[ -z "$AAPT" ]]; then
  skip "未找到 aapt，无法验证 ABI"
else
  NATIVE="$("$AAPT" dump badging "$APK" 2>/dev/null | grep '^native-code:' || true)"
  echo "  实际：$NATIVE"
  if echo "$NATIVE" | grep -q "arm64-v8a"; then
    pass "含 arm64-v8a"
  else
    fail "未找到 arm64-v8a"
  fi
  if echo "$NATIVE" | grep -qE "armeabi|x86|mips"; then
    fail "混入了其它 ABI，体积会翻倍"
  else
    pass "无其它 ABI 混入"
  fi
fi

# ---------- 2. targetSdk ----------
echo
echo "【2/5】targetSdk"
if [[ -z "$AAPT" ]]; then
  skip "未找到 aapt，无法验证 targetSdk"
else
  TSDK="$("$AAPT" dump badging "$APK" 2>/dev/null | grep -oP "targetSdkVersion:'\K[0-9]+" || true)"
  echo "  实际：targetSdk=$TSDK"
  if [[ "$TSDK" == "28" ]]; then
    pass "targetSdk 28（W^X 策略所需，勿改）"
  else
    fail "targetSdk 应为 28，实际 $TSDK —— 会破坏 W^X 绕过策略"
  fi
fi

# ---------- 3. 签名 ----------
echo
echo "【3/5】签名"
if [[ -z "$APKSIGNER" ]]; then
  skip "未找到 apksigner，无法验证签名"
else
  if "$APKSIGNER" verify --print-certs "$APK" >/tmp/apksigner.out 2>&1; then
    pass "签名验证通过"
    grep -i "signer #1 certificate DN" /tmp/apksigner.out | head -1 | sed 's/^/     /'
  else
    fail "签名验证失败，见 /tmp/apksigner.out"
  fi
fi

# ---------- 4. 合规：不含 proroot ----------
echo
echo "【4/5】合规：proroot 不得入包"
HITS="$(unzip -l "$APK" 2>/dev/null | grep -i proroot || true)"
if [[ -z "$HITS" ]]; then
  pass "APK 内无 proroot（符合上游许可，见 THIRD-PARTY-NOTICES.md）"
else
  fail "APK 内发现 proroot，违反「不代分发」口径："
  echo "$HITS" | sed 's/^/     /'
fi

# ---------- 5. 图标（alpha.69）----------
echo
echo "【5/5】App 图标已应用"
#
# ⚠️ 这一项**必须走 aapt2 dump resources**，不能按文件名查。
#
# 第一次写的时候用的是 `unzip -l | grep res/mipmap-xxxhdpi/ic_launcher.png`，
# 结果是**假红**：release 构建会开资源名混淆（AGP 默认行为），
# APK 里的实际条目长这样 ——
#
#     res/bB.png   res/yi.png   res/tP.png   res/BM.png   res/CH.png
#
# mipmap 目录名与 `ic_launcher` 文件名全没了。所以：
#   * `unzip -l` 的**文件名字段**在 release 包里不可用；
#   * 只有 `resources.arsc` 里保留的**资源 ID + 逻辑名**才是稳定的。
#
# 同理，第 4 项（proroot）用 `unzip -l | grep` 是**碰巧能work**：
# so 文件名不做混淆，且 "proroot" 这个串没有被哪条路径意外覆盖。
# 换成人名/短串做合规检查就得小心了。
#
# ⚠️ 这条"碰巧"在 alpha.72 被实测确认过一次，别把它扩大成全文 grep：
# `classes.dex` 与 `libapp.so` 里**必然**存在 "proroot" 字样 ——
#   1. Kotlin 侧有一整块 proroot 后端（Pr0otBridge.getPr0otStatus /
#      prorootInstall / libproroot.so 这些方法名与 so 名全是明文字符串），
#      它只是**不随包分发**，不是"代码里不能提它"；
#   2. 工具链页的「选后端」对话框文案要如实告诉用户"proroot 是专有软件、
#      需自备二进制"，这段说明文字也会落进 AOT 字符串表。
# 所以判据只能是「`lib/` 下有没有 proroot 的 .so」，而**不是**"包内有没有
# 出现 proroot 这个词" —— 后者会把一个正确构建判成违规。
LISTING="$(unzip -l "$APK" 2>/dev/null || true)"
if [[ -z "$AAPT2" ]]; then
  skip "未找到 aapt2，无法验证图标（release 包资源名已混淆，必须靠 aapt2）"
else
  RES="$("$AAPT2" dump resources "$APK" 2>/dev/null || true)"
  ICON_MISSING=""
  for entry in \
    "mipmap/ic_launcher" \
    "drawable/ic_launcher_foreground" \
    "color/ic_launcher_background" \
  ; do
    echo "$RES" | grep -q "resource .* $entry\$" || ICON_MISSING="$ICON_MISSING $entry"
  done

  if [[ -n "$ICON_MISSING" ]]; then
    fail "APK 内缺少图标资源：$ICON_MISSING"
    echo "     多半是忘了跑：python3 app/tools/gen_icon.py && dart run flutter_launcher_icons"
  else
    pass "传统图标 / adaptive 前景 / 背景色 三条资源均在 resources.arsc 中"

    # 背景色必须与 FoaTheme.bg 同源（那是图标的底，也是 App 的底）
    BGCOLOR="$(echo "$RES" | grep -A 3 "resource .* color/ic_launcher_background\$" \
               | grep -oE '#[0-9a-fA-F]{8}' | head -1 || true)"
    if [[ "${BGCOLOR,,}" == "#ff101418" ]]; then
      pass "adaptive 背景色 $BGCOLOR == FoaTheme.bg（#101418）"
    elif [[ -z "$BGCOLOR" ]]; then
      warn_hint "未能从 arsc 中读出背景色，跳过同源校验"
    else
      fail "adaptive 背景色是 $BGCOLOR，期望 #ff101418"
    fi

    # 抽一张前景层验色。**文件名要从 arsc 里反查**（已被混淆成 res/xx.png）。
    # 取 xxxhdpi 那档（未降采样，边缘最锐）。
    FG_PATH="$(echo "$RES" | grep -A 8 "resource .* drawable/ic_launcher_foreground\$" \
               | grep '(xxxhdpi)' | grep -oE 'res/[^ ]+\.png' | head -1 || true)"
    if [[ -z "$FG_PATH" ]]; then
      warn_hint "未能定位 xxxhdpi 前景层文件，跳过配色校验"
    else
      TMPD="$(mktemp -d)"
      if unzip -o -q "$APK" "$FG_PATH" -d "$TMPD" 2>/dev/null \
         && [[ -f "$TMPD/$FG_PATH" ]]; then
        COLOR="$(python3 - "$TMPD/$FG_PATH" <<'PY' 2>/dev/null || true
import sys
try:
    from PIL import Image
except ImportError:
    print("NOPIL"); raise SystemExit
im = Image.open(sys.argv[1]).convert("RGBA")
w, h = im.size
# 折点位置（见 app/tools/gen_icon.py 的 CHEVRON_MID）。
# 前景层已缩到安全区，落点要按 SAFE_SCALE 换算，
# 不能直接拿满幅图的 0.64/0.455。
#   实际坐标 = (1 - SAFE_SCALE)/2 + 几何比例 * SAFE_SCALE
SAFE = 0.62
ox = (1 - SAFE) / 2
for gx, gy, label in [(0.64, 0.455, "折点"), (0.44, 0.845, "横线左端")]:
    px = im.getpixel((int((ox + gx * SAFE) * w), int((ox + gy * SAFE) * h)))
    print("%s %02X%02X%02X" % (label, px[0], px[1], px[2]))
PY
)"
        if [[ "$COLOR" == NOPIL* || -z "$COLOR" ]]; then
          warn_hint "未装 Pillow，跳过配色校验（资源存在性已通过）"
        else
          echo "$COLOR" | sed 's/^/     /'
          # 两处采样点都应是品牌绿 #3DDC84。只要有一处不符就判红 ——
          # Flutter 默认 logo 是蓝色，不可能撞上这个绿。
          if echo "$COLOR" | grep -q "3DDC84" \
             && [[ "$(echo "$COLOR" | grep -c '3DDC84')" -eq 2 ]]; then
            pass "图标主色 #3DDC84（品牌绿，非 Flutter 默认蓝）"
          else
            fail "图标配色不符：期望两处采样点都是 3DDC84"
          fi
        fi
      else
        fail "无法从 APK 中解出 $FG_PATH 做配色校验"
      fi
      rm -rf "$TMPD"
    fi
  fi
fi

# ---------- 6. 文案落地（alpha.72 起）----------
echo
echo "【6/6】本次改动的 UI 文案已编进 libapp.so"
#
# ⚠️ AOT 产物里的中文串是 **UTF-16LE**，不是 UTF-8 ——
#    早先按 UTF-8 比对，全绿的字符串一条都搜不到，差点误判成"没编进去"。
#    所以这里一律用 UTF-16LE 的字节去搜。
#
# ⚠️ 改了下面任何一句文案，就要同步改这里 —— 这不是僵化，
#    是让"改文案"这个动作必须经过一次确认：要么更新断言，
#    要么发现自己其实改错了地方。
TMPD6="$(mktemp -d)"
if ! unzip -o -q "$APK" "lib/arm64-v8a/libapp.so" -d "$TMPD6" 2>/dev/null \
   || [[ ! -f "$TMPD6/lib/arm64-v8a/libapp.so" ]]; then
  skip "无法解出 lib/arm64-v8a/libapp.so"
else
  MISSING6="$(python3 - "$TMPD6/lib/arm64-v8a/libapp.so" <<'PY' 2>/dev/null || echo "PYERR"
import sys
needles = [
    # alpha.98（Bug 636 · 非法 shrink 组合）轮换四条：
    # ⚠️ 只挑**不含插值**且**唯一**的**运行期字符串常量**。
    #
    # ⚠️⚠️ 血的教训：第一版我挑了 "Removing unused resources"（AGP 报错原文），
    #     它在源码里**只出现在注释中**。注释被编译器剥掉，AOT 里根本没有 →
    #     脚本报"没进包"，但那明明是**测量选错了对象**，不是代码坏了。
    #     选 needle 前必须先 `grep` 确认它落在**字符串字面量**里，
    #     而不是注释里。判据：grep 匹配行的**行首去掉空白后不是 `//`**。
    "检测到 ",                        # 检测命中的告警（修复/未修复两条共用前缀）
    "已自动修复",                      # 前置检查真的改写了文件时的日志
    "isShrinkResources → false",     # 修复说明里的箭头（含中文 →，走 UTF-16LE）
    "FOA_PREFLIGHT_NOFLUTTER=1",     # 反向护栏：既有前置探测没被改坏
    # ⚠️ alpha.98 的改动在 Dart 侧（manifest_codec 的正则 + build_runner
    #    的前置接线），逻辑正确性钉在 manifest_codec_test（13 条，含 4 条
    #    "不误报" + 1 条接线护栏）。这里这四条只回答一个问题：
    #    **改动有没有真的进到 AOT 里**。
    #
    #    为什么挑这四条：前三条覆盖"检测到 → 修复了 → 修复说明"这条链路的
    #    三段，只要有一段没接进 `_fixIllegalShrinkCombo`，对应串就不进 AOT。
    #    第四条是**反向护栏**：改 shrink 组合时若手滑动到了前置检查那段
    #    shell，这条立刻 MISSING。
    #
    #    ⚠️ 刻意**不**把属性名 `isShrinkResources` 单独当一条：它同时出现在
    #    注释与代码里，命中它不能证明任何事（注释里的也…会被剥掉，但一旦
    #    哪天它进了别的运行期字符串就会假绿）。选 needle 的标准是
    #    **只有那段逻辑才会产生这个串**。
    #
    # 轮换历史（改本轮文案时请把上轮的换掉，别无限加长）：
    #   alpha.97（构建流程三段优化）：
    #             产物落盘确认（读数连续一致） / 产物稳定性探测未确认
    #             FOA_PREFLIGHT_NOFLUTTER=1 / FOA_HEAL=检测到转发位异常
    #   alpha.96（老签名补丁修复入口）：
    #             修复构建脚本 / 构建脚本需要修复
    #             不会动你的密钥 / Unresolved reference: util / io
    #   alpha.95（预取入口 / 图标预览 / 按钮竖排）：
    #             第一次构建前，可以先下好构件 / 已替换为自定义图标
    #             仅 release / 预取 debug 构件
    #   alpha.91（外部改动自动同步）：自动同步外部改动 / 已同步磁盘上的改动
    #             已开启自动同步 / 已关闭自动同步（改用派活后提示）
    #   alpha.90（不填模型名也能自动选模型）：
    #             获取模型 / 可用模型
    #             不在该接口的可用列表里 / 从接口拉回可用列表
    #   alpha.89：服务端拒绝 / 常见原因是模型名不存在
    #             没填模型名 / 无法替你猜
    #   alpha.88：却被当成 latin1/ascii 编码 / 与本机网络无关，属程序缺陷
    #             请求参数被拒绝 / 请求头含非法字符
    #   alpha.87：请求参数在传输层被拒 / 密钥可能混进了换行
    #             未识别的错误类型 / 建议重新粘贴
    #   alpha.86：怎么做 / 不要用猜的改动顶上 / HTTP 层错误 / 原因未记录
    #   alpha.85：隧道没开 / 现在隧道没运行，派出去也没人领得到
    #             只做上面「要求」里写的事 / 只有两种情况你才动手
    #   alpha.84：AI 作业收件箱 / 看派出去的活有没有被处理
    #             会自动弹窗给你看差异
    #   alpha.83：远程 AI 改了文件 / AI 已写入编辑器
    #             还没配置内置 LLM 的接口地址与密钥
    #   alpha.82：AI 没能给结果
    #   alpha.81：AI：单点补全代码 · 长按输入要求 / 从磁盘重新载入
    #             远程 MCP（走下面的 AI 接管）
    #   alpha.72~alpha.80：第一次构建会比较慢 / 第一次构建通常需要 20~30 分钟
    #                      原生 arm64 后端（可选加速） / 未装上（可选）
]
data = open(sys.argv[1], "rb").read()

# ⚠️⚠️ alpha.97 修正：**纯 ASCII 串与含 CJK 的串编码不同**。
#
# 原先一律按 UTF-16LE 搜（下文老注释说"中文串是 UTF-16LE"是对的），
# 但 Dart AOT 对**只含单字节码点的字符串**走 Latin-1 快路径，直接按
# 一个字符一个字节存；只有含 CJK 的串才升成 UTF-16LE。
#
# 后果：任何纯 ASCII 的 needle（如 "FOA_PREFLIGHT_NOFLUTTER=1"）
# 用 UTF-16LE 去搜**永远搜不到**，哪怕它明明在包里 —— 会稳定误报
# "没进包"，把人往"是不是忘记接线了"的错误方向带。
#
# 修法：两种编码都试，命中任一即算在。这不是放宽标准 ——
# 两种编码都找不到才是真的不在包里。
def present(s, d):
    return s.encode("utf-16-le") in d or s.encode("utf-8") in d

out = [s for s in needles if not present(s, data)]
print("\n".join(out))
PY
)"
  if [[ "$MISSING6" == "PYERR" ]]; then
    skip "python3 读取失败，无法核对文案"
  elif [[ -n "$MISSING6" ]]; then
    fail "以下文案没进包（改了文案？同步改本脚本的 needles）："
    echo "$MISSING6" | sed 's/^/     /'
  else
    pass "4 条关键文案均在 libapp.so 中（UTF-16LE / UTF-8 双编码比对）"
  fi
fi
rm -rf "$TMPD6"

# ---------- 汇总 ----------
echo
echo "════════════════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
  echo "  ✅ 六项全部通过，可交付"
else
  echo "  ❌ 存在未通过项，**不要交付**"
fi
echo "════════════════════════════════════════════════════════"
exit $FAIL
