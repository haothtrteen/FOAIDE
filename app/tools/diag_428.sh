#!/bin/bash
# Bug 428 真机诊断脚本：AOT 编译 (gen_snapshot) SIGILL 定位
# 用法：在容器内执行  sh /root/foa-diag-428.sh
echo "===== 1. qemu 是否存在 ====="
ls -l /usr/bin/qemu-x86_64-static 2>&1
/usr/bin/qemu-x86_64-static --version 2>&1 | head -1

echo ""
echo "===== 2. gen_snapshot 实际形态（Flutter 真正会用的那个） ====="
E=/opt/flutter/bin/cache/artifacts/engine
for p in android-arm64-release/linux-x64 android-arm64-release/linux-arm64; do
  f="$E/$p/gen_snapshot"
  echo "--- $p ---"
  if [ -e "$f" ]; then
    ls -l "$f"
    echo -n "  文件类型: "; head -c 4 "$f" | od -An -tx1 | tr -d ' \n'; echo ""
    echo -n "  是否脚本: "; head -c 2 "$f" | grep -q '#!' && echo "是转发脚本" || echo "否(真二进制)"
    echo -n "  ELF arch: "; dd if="$f" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n'
    echo "    (_3e=x86_64, _b7=arm64)"
  else
    echo "  不存在"
  fi
done

echo ""
echo "===== 3. 直接跑 gen_snapshot --help ====="
gs="$E/android-arm64-release/linux-arm64/gen_snapshot"
[ -x "$gs" ] || gs="$E/android-arm64-release/linux-x64/gen_snapshot"
echo "测试: $gs"
"$gs" --help 2>&1 | head -5
echo "退出码: $?"

echo ""
echo "===== 4. impellerc 形态 ====="
for p in linux-x64 linux-arm64; do
  f="$E/$p/impellerc"
  echo "--- $p ---"
  if [ -e "$f" ]; then
    head -c 2 "$f" | grep -q '#!' && echo "  转发脚本" || echo "  真二进制"
    echo -n "  arch: "; dd if="$f" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n'; echo ""
    "$f" --help >/dev/null 2>&1; echo "  退出码: $?"
  else
    echo "  不存在"
  fi
done

echo ""
echo "===== 5. 多架构 glibc（qemu 依赖） ====="
ls /lib64/ld-linux-x86-64.so.2 2>&1
dpkg --print-foreign-architectures 2>&1
