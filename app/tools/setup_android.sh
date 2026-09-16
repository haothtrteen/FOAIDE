#!/usr/bin/env bash
# ============================================================
# setup_android.sh — 在装有 Flutter SDK 的桌面机上运行
#
# 作用：
#   1. flutter create 生成 android 平台壳（Gradle 版本与本机 Flutter 匹配）
#   2. 用 platform/android/ 下的定制文件覆盖 MainActivity / Manifest
#   3. 自动把 targetSdk 改为 28（W^X 限制，详见 SETUP_ANDROID.md）
#   4. 把 proot 放入 jniLibs（libproot.so，双保险）
#
# android/ 目录首次生成后纳入 git；本脚本只需运行一次。
# ============================================================
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v flutter >/dev/null 2>&1 || { echo "❌ 未找到 flutter，请先安装 Flutter SDK"; exit 1; }

echo "→ [1/4] flutter create 生成 android 壳..."
flutter create --platforms=android --org dev.foa --project-name flutter_on_android .

echo "→ [2/4] 应用定制 MainActivity / AndroidManifest..."
SRC="$(pwd)/platform/android"
DST="$(pwd)/android/app/src/main"
mkdir -p "$DST/kotlin/dev/foa/flutter_on_android"
cp "$SRC/MainActivity.kt"        "$DST/kotlin/dev/foa/flutter_on_android/MainActivity.kt"
cp "$SRC/AndroidManifest.xml"    "$DST/AndroidManifest.xml"
# 清理可能存在的其他包名路径的 MainActivity（历史遗留）
find android/app/src/main/kotlin -name 'MainActivity.kt' ! -path '*dev/foa/flutter_on_android*' -print -delete 2>/dev/null || true

echo "→ [3/4] build.gradle: targetSdk → 28..."
python3 - <<'PYEOF' || { echo "⚠️ 自动补丁失败，请手动把 android/app/build.gradle 中 targetSdk 改为 28"; }
import re, pathlib
p = pathlib.Path("android/app/build.gradle")
if not p.exists():
    print("   （未找到 build.gradle，跳过）"); raise SystemExit(0)
s = p.read_text()
if re.search(r"targetSdk(Version)?\s*[= ]\s*28\b", s):
    print("   targetSdk 已是 28")
else:
    s2 = re.sub(r"targetSdk\s*=\s*flutter\.targetSdkVersion", "targetSdk = 28", s)
    s2 = re.sub(r"targetSdkVersion\s+flutter\.targetSdkVersion", "targetSdkVersion 28", s2)
    if s2 != s:
        p.write_text(s2); print("   ✅ 已将 targetSdk 改为 28")
    else:
        print("   ⚠️ 未匹配到 targetSdk 行，请手动设置"); raise SystemExit(1)
PYEOF

echo "→ [4/4] jniLibs: 部署 libproot.so..."
JNILIB_DIR="android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNILIB_DIR"
if [[ -f "assets/tools/proot-arm64" ]]; then
  cp "assets/tools/proot-arm64" "$JNILIB_DIR/libproot.so"
  echo "   ✅ 已复制 assets/tools/proot-arm64 → $JNILIB_DIR/libproot.so"
else
  echo "   ⚠️ assets/tools/proot-arm64 不存在，先运行 ./tools/fetch_assets.sh proot 再重跑本脚本"
fi

echo ""
echo "✅ android 壳就绪。下一步："
echo "   1. ./tools/check_env.sh   # 自检（资产/架构/设备）"
echo "   2. flutter run            # 连接真机运行"
echo ""
echo "别忘了把生成的 android/ 目录提交进 git："
echo "   git add android/ && git commit -m 'chore: android scaffold (setup_android.sh)'"
