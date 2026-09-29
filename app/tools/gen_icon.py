#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 FOAIDE 的 App 图标源图（alpha.69）。

设计说明
--------
**为什么是「终端提示符」**：这个 App 干的事就是在 Android 上跑一个
Linux 容器、在里面调 flutter/gradle。它的身份标识不是「Flutter」也不是
「Android」，而是「一个能敲命令的终端」——那是用户与它交互的唯一方式。
所以取最通用、最一眼可辨的终端符号：`>_` 提示符。

**配色**：品牌绿 `#3DDC84`（= 项目里的 `FoaTheme.seed`，也是编辑器
光标色、代码区成功色的取值）× 深底 `#101418`（= `FoaTheme.bg`）。
用项目自己的两个锚点色，而不是另调一套 —— 图标与主题天然同源。

**两种尺寸各画一遍，这不是冗余**：
`flutter_launcher_icons` 的 `adaptive_icon_foreground` 会被 Android
按各家 OEM 的形状（圆 / 方 / 水滴 / 圆角方）裁切，安全区只有中心的
约定比例（通常按 66% 直径的圆来设计）。所以：

* `--full`   1024×1024 满幅 —— 给传统 `ic_launcher.png`（自带圆角遮罩）
* `--safe`   前景层     —— 内容整体缩到中心 66%，四周留白给系统裁切

如果只有满幅一张，adaptive icon 会把这套几何按比例放大到裁切区，
`>` 的折线两端就会顶到甚至超出裁切圆 —— 圆角设备上看着像被切掉一角。

**几何全部按边长比例表示**（而不是绝对像素），这样同一个函数既能画
1024 也能画 432，不需要维护两套数值。

用法
----
    python3 tools/gen_icon.py            # 生成到 assets/icon/
    python3 tools/gen_icon.py --out DIR  # 指定输出目录

生成后由 `flutter_launcher_icons` 消费（见 `flutter_launcher_icons.yaml`）：

    dart run flutter_launcher_icons

⚠️ 输出文件名刻意**不带 `flutter_` 前缀** —— `.gitignore:10` 有一条
Flutter 模板自带的 `flutter_*.png`，撞上就被忽略、进不了仓库。
"""

from __future__ import annotations

import argparse
import os
import sys

from PIL import Image, ImageDraw

# ── 与 Dart 侧同源的品牌色（见 lib/core/theme.dart）────────────────
BG = (0x10, 0x14, 0x18)      # FoaTheme.bg        深底
GREEN = (0x3D, 0xDC, 0x84)   # FoaTheme.seed      品牌绿
CURSOR = (0x3D, 0xDC, 0x84)  # 光标块与提示符同色

# ── 几何（全部是「占边长的比例」，与分辨率无关）────────────────────
#
# 坐标系原点在左上、(0,0)→(1,1)：
#
#     ┌──────────────────────┐
#     │            ╱         │   `>` 上半笔：左下 → 右中尖
#     │          ╱           │
#     │        ╱             │
#     │      ╱               │   `>` 下半笔：右中尖 → 左下
#     │        ╲             │
#     │          ╲           │
#     │            ╲         │
#     │              ▬▬▬     │   输入横线（右下方，与折线**不接触**）
#     └──────────────────────┘
#
# ⚠️ 折点与横线必须留出间隙。第一版把横线画在 `>` 左下端点同一高度
# （y=0.76）、且左端只隔 0.14 —— 在图标尺寸下两者糊成一条，整个符号
# 会被读成字母「Z」而不是提示符。改成横线整体下沉到 y=0.84 起笔、
# 左端从 0.44 开始之后才读得出「`>` + 光标」。
CHEVRON_TOP = (0.20, 0.16)   # 上半笔起点（左上）
CHEVRON_MID = (0.64, 0.455)  # 折点（右中）—— 略高于几何中点，
                             # 给下方横线让出视觉重心
CHEVRON_BOT = (0.20, 0.75)   # 下半笔终点（左下）
UNDERLINE_A = (0.44, 0.845)  # 横线左端（与折线下端错开约 0.095）
UNDERLINE_B = (0.86, 0.845)  # 横线右端

# 线宽占边长比例。0.10 是试出来的：再细在 48dp 的启动图标上会糊成一团，
# 再粗则 `>` 的两笔会糊在一起、失去"折线"的辨识度。
STROKE = 0.10

# adaptive icon 前景层的安全区比例。
#
# Android 的 adaptive icon 是「背景层 108dp + 前景层 108dp」，但只有中心
# **72dp** 是保证不被裁掉的（66.7%）。这里留得更保守一点取 0.62，
# 因为圆角矩形的内切圆比正方形更小，各家 OEM 的遮罩半径也不完全一致 ——
# 宁可图标看起来小一号，也不要被切掉。
SAFE_SCALE = 0.62


def _draw_prompt(
    draw: ImageDraw.ImageDraw,
    size: int,
    origin: float,
    scale: float,
    stroke: int,
) -> None:
    """把提示符几何画到 `draw` 上。

    Args:
        size: 画布边长（像素）。
        origin: 内容框左上角在画布中的位置比例（0 = 贴左上）。
        scale: 内容框占画布的比例（1.0 = 满幅）。
        stroke: 线宽（像素）。
    """

    def pt(x: float, y: float) -> tuple[float, float]:
        """比例坐标 → 画布像素坐标。"""
        return (origin + x * scale) * size, (origin + y * scale) * size

    # `>` 是一个两段的折线，`joint="curve"` 让折点处自然圆接，
    # 而不是两笔各画一条线、在尖角处留个缺口。
    draw.line(
        [pt(*CHEVRON_TOP), pt(*CHEVRON_MID), pt(*CHEVRON_BOT)],
        fill=GREEN,
        width=stroke,
        joint="curve",
    )

    # 下划线。它代表"光标等着你输入"，是这个符号读作「终端」而不是
    # 「上一页」的关键 —— 只有 `>` 的话，在图标尺寸下很容易被看成返回箭头。
    draw.line(
        [pt(*UNDERLINE_A), pt(*UNDERLINE_B)],
        fill=CURSOR,
        width=stroke,
    )

    # 三个端点补圆头。PIL 的 `line` 端点是平头（butt cap），
    # 在粗线上平头会显得很"硬"，与圆润的折点不搭。
    radius = stroke / 2
    for x, y in (CHEVRON_TOP, CHEVRON_MID, CHEVRON_BOT, UNDERLINE_A, UNDERLINE_B):
        cx, cy = pt(x, y)
        draw.ellipse(
            [cx - radius, cy - radius, cx + radius, cy + radius],
            fill=GREEN,
        )


def render(size: int, *, safe: bool, transparent_bg: bool = True) -> Image.Image:
    """渲染一张图标。

    Args:
        size: 输出边长（像素）。
        safe: True = 前景层（内容缩到安全区、背景透明）；
              False = 满幅图（内容铺满、带深色底）。
        transparent_bg: 仅 `safe=False` 时有效。False 时铺 `BG` 深底。
    """
    mode = "RGBA"
    if safe or transparent_bg:
        img = Image.new(mode, (size, size), (0, 0, 0, 0))
    else:
        img = Image.new(mode, (size, size), BG + (255,))

    draw = ImageDraw.Draw(img)

    if safe:
        # 前景层：内容缩到中心，四周透明留白交给系统裁切
        origin = (1.0 - SAFE_SCALE) / 2
        scale = SAFE_SCALE
    else:
        # 满幅：内容铺满整张图，但仍留一点点边距 —— 完全贴边会让
        # 折线两端的圆头被切掉半个。
        origin = 0.04
        scale = 0.92

    # 线宽在两种模式下都按**内容框**算，否则前景层的线会显得比满幅细。
    stroke = max(2, round(STROKE * scale * size))

    _draw_prompt(draw, size, origin, scale, stroke)
    return img


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    app_root = os.path.dirname(here)
    default_out = os.path.join(app_root, "assets", "icon")

    ap = argparse.ArgumentParser(description="生成 FOAIDE App 图标源图")
    ap.add_argument(
        "--out",
        default=default_out,
        help=f"输出目录（默认 {default_out}）",
    )
    ap.add_argument(
        "--size",
        type=int,
        default=1024,
        help="源图边长（默认 1024，flutter_launcher_icons 要求 ≥1024）",
    )
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    targets = [
        # 文件名刻意避开 `flutter_` 前缀（见模块 docstring 末尾的说明）
        ("app_icon.png", dict(safe=False, transparent_bg=False)),
        ("app_icon_foreground.png", dict(safe=True)),
    ]

    for name, kwargs in targets:
        img = render(args.size, **kwargs)
        path = os.path.join(out, name)
        img.save(path, "PNG", optimize=True)
        print(f"  ✓ {os.path.relpath(path, app_root)}  {args.size}×{args.size}")

    # 附带一张 512 的预览，方便在不装 App 的情况下肉眼确认
    preview = render(512, safe=False, transparent_bg=False)
    prev_path = os.path.join(out, "app_icon_preview.png")
    preview.save(prev_path, "PNG", optimize=True)
    print(f"  ✓ {os.path.relpath(prev_path, app_root)}  512×512（预览用）")

    print()
    print("下一步：dart run flutter_launcher_icons")
    return 0


if __name__ == "__main__":
    sys.exit(main())
