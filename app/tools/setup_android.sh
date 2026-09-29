#!/usr/bin/env bash
# ============================================================
# setup_android.sh — 在装有 Flutter SDK 的桌面机上运行
#
# 作用：
#   1. flutter create 生成 android 平台壳（Gradle 版本与本机 Flutter 匹配）
#   2. 用 platform/android/ 下的定制文件覆盖 MainActivity / Manifest
#   3. 自动把 targetSdk 改为 28（W^X 限制，详见 SETUP_ANDROID.md）
#   4. 把 proot 放入 jniLibs（lib*.so，必须走 nativeLibraryDir）
#      ⚠️ proroot 五件套自 alpha.69 起不再内置（上游许可禁止再分发）
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

echo "→ [3/4] build.gradle(.kts): targetSdk → 28..."
python3 - <<'PYEOF' || { echo "⚠️ 自动补丁失败，请手动把 android/app/build.gradle(.kts) 中 targetSdk 改为 28"; }
import re, pathlib
# Flutter 3.47 起模板默认生成 build.gradle.kts（Kotlin DSL）；旧版为 build.gradle
candidates = [pathlib.Path("android/app/build.gradle.kts"), pathlib.Path("android/app/build.gradle")]
p = next((c for c in candidates if c.exists()), None)
if p is None:
    print("   （未找到 build.gradle / build.gradle.kts，跳过）"); raise SystemExit(0)
s = p.read_text()
if re.search(r"targetSdk(Version)?\s*[= ]\s*28\b", s):
    print("   targetSdk 已是 28")
else:
    # Groovy DSL: targetSdkVersion flutter.targetSdkVersion / targetSdk = flutter.targetSdkVersion
    # Kotlin DSL:  targetSdk = flutter.targetSdkVersion
    s2 = re.sub(r"targetSdk\s*=\s*flutter\.targetSdkVersion", "targetSdk = 28", s)
    s2 = re.sub(r"targetSdkVersion\s+flutter\.targetSdkVersion", "targetSdkVersion 28", s2)
    if s2 != s:
        p.write_text(s2); print(f"   ✅ 已将 {p.name} 中 targetSdk 改为 28")
    else:
        print("   ⚠️ 未匹配到 targetSdk 行，请手动设置"); raise SystemExit(1)

# targetSdk 28 会触发 lintVitalRelease 的 ExpiredTargetSdkVersion fatal 错误
# （Play 要求 API 33+；本项目不走 Play 分发，属刻意豁免）；
# 同时注入 useLegacyPackaging（等价旧 extractNativeLibs="true"，AGP 9 起必须走 DSL，
# 让 libproot.so 落地为真实文件）
s = p.read_text()
if "ExpiredTargetSdkVersion" not in s:
    if "android {" in s:
        s2 = s.replace(
            "android {",
            "android {\n"
            "    lint {\n"
            "        // targetSdk 28 为刻意选择（W^X 策略），非 Play 分发，豁免该 fatal lint\n"
            "        disable += \"ExpiredTargetSdkVersion\"\n"
            "    }\n"
            "    packaging {\n"
            "        jniLibs {\n"
            "            useLegacyPackaging = true\n"
            "        }\n"
            "    }\n",
            1,
        )
        p.write_text(s2); print("   ✅ 已注入 lint 豁免 + useLegacyPackaging")
    else:
        print("   ⚠️ 未找到 android { 块，请手动配置 lint 豁免与 packaging")
PYEOF

echo "→ [4/4] jniLibs: 部署 libproot.so ..."
JNILIB_DIR="android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNILIB_DIR"
if [[ -f "assets/tools/proot-arm64" ]]; then
  cp "assets/tools/proot-arm64" "$JNILIB_DIR/libproot.so"
  echo "   ✅ 已复制 assets/tools/proot-arm64 → $JNILIB_DIR/libproot.so"
else
  echo "   ⚠️ assets/tools/proot-arm64 不存在，先运行 ./tools/fetch_assets.sh proot 再重跑本脚本"
fi

# proroot 五件套（Bug 471e）**alpha.69 起不再内置**。
#
# 原因：上游许可是 Proprietary，禁止再分发二进制，故五件套已从 APK 移除
# （tools/verify_apk.sh 第 4/5 项会检查 APK 内不得含 proroot）。
#
# 这里**刻意不再自动补拉** —— 原逻辑是"检测缺失就调 fetch_assets.sh proroot"，
# 那会把不该分发的二进制灌回 jniLibs/ 并随 APK 打包。
# 注意本块**不能 exit 1**：proroot 缺失在新方案下是**正常状态**，
# 不该阻断任何人搭环境（proot 路径完全不受影响）。
#
# 用户如持有合法副本，可自行导入：App 内卡片「从本地导入」，
# 或手工放到 $JNILIB_DIR。详见 PROROOT-许可与分发决策.md 方案 A。
echo "   ℹ️  proroot 五件套不再内置打包（方案 A：用户自行导入）；proot 路径不受影响。"

echo ""
echo "✅ android 壳就绪。下一步："
echo "   1. ./tools/check_env.sh   # 自检（资产/架构/设备）"
echo "   2. flutter run            # 连接真机运行"
echo ""
echo "别忘了把生成的 android/ 目录提交进 git："
echo "   git add android/ && git commit -m 'chore: android scaffold (setup_android.sh)'"
