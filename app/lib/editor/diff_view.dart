/// 差异预览组件（可复用的独立文件，alpha.91）。
///
/// 从 `editor_page.dart` 里抽出来，原因有两个：
///   1. **它以前是错的**——用 `Text` + `overflow: ellipsis` 渲染代码行，
///      长行会被**自动折行**，于是一个 `+` 号占了三行显示，用户数行号时
///      根本对不上。代码行不该折行，该横向滚动。
///   2. 它要在**全屏抽屉**里复用，放在页面里当私有方法已经不合适了。
///
/// 三条设计约束（都是踩过坑换来的）：
///   - **不折行**：`softWrap: false` + 横向 `SingleChildScrollView`。
///   - **行号取自原始文件**，不是"第几个差异行"——用户要拿它回文件里定位。
///   - **`SelectableText`**：看到可疑的改动，能直接复制出来去搜。
library;

import 'package:flutter/material.dart';

import '../ai/diff.dart';

/// 差异行列表。
///
/// [lines] 传 `DiffResult.lines`（**含 same 行**），由本组件负责折叠上下文。
class DiffLinesView extends StatelessWidget {
  const DiffLinesView(
    this.diff, {
    super.key,
    this.foldContext = true,
    this.fontSize = 12.5,
    this.lineHeight = 1.45,
  });

  final DiffResult diff;

  /// 是否把连续未改动行折叠成「… 未改动 N 行 …」。
  ///
  /// 默认开：几十行的改动里夹着上百行 same 行，全展开就没法看了。
  /// 但要**如实显示折叠了多少行**，不能悄悄吞掉。
  final bool foldContext;

  final double fontSize;
  final double lineHeight;

  @override
  Widget build(BuildContext context) {
    final p = DiffPalette.of(context);

    if (diff.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '（与改动前无差异）',
          style: TextStyle(fontSize: fontSize, color: p.muted),
        ),
      );
    }

    // tooLarge：文件超出比对上限，已退化成"整段删 + 整段加"。
    // 必须说清楚，否则用户会以为 AI 把整个文件重写了。
    final items = _buildItems(diff.lines, foldContext);

    // 行号宽度按最大行号算，避免每行宽度不一导致代码区跳动。
    final maxNo = diff.lines.length + 1;
    final gutter = '${maxNo + 1}'.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (diff.tooLarge)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: p.warnBg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '文件较大，已退化为整体对照（不再逐行匹配）。'
              '下面看到的删除/新增不一定对应真实改动，请以编辑区内容为准。',
              style: TextStyle(fontSize: fontSize - 1, color: p.warnFg),
            ),
          ),
        // 横向滚动包住整个列表：长代码行**整体左右滑**，而不是折行。
        // 这样 `+/-` 号永远贴在最左边，行号对得上。
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final it in items) _row(it, p, gutter),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(_Item it, DiffPalette p, int gutter) {
    if (it.foldedTo != null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: fontSize * 0.5),
        child: Row(
          children: [
            SizedBox(width: (gutter + 1) * fontSize * 0.62),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: p.muted.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '⋯ 未改动 ${it.foldedTo} 行 ⋯',
                style: TextStyle(fontSize: fontSize - 1.5, color: p.muted),
              ),
            ),
          ],
        ),
      );
    }

    final l = it.line!;
    final isAdd = l.kind == DiffKind.add;
    final isDel = l.kind == DiffKind.del;
    final fg = isAdd ? p.addFg : (isDel ? p.delFg : p.normal);
    final bg = isAdd ? p.addBg : (isDel ? p.delBg : Colors.transparent);
    final no = it.lineNo;

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 行号：保留原始文件里的位置，方便回编辑器定位。
          SizedBox(
            width: gutter * fontSize * 0.62,
            child: Text(
              no == null ? '' : '$no',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: fontSize - 1,
                fontFamily: 'monospace',
                height: lineHeight,
                color: p.muted,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // +/- 标记列：固定宽度，保证所有行的代码起始位置对齐。
          SizedBox(
            width: 11,
            child: Text(
              isAdd ? '+' : (isDel ? '-' : ' '),
              style: TextStyle(
                fontSize: fontSize,
                fontFamily: 'monospace',
                height: lineHeight,
                fontWeight: isAdd || isDel ? FontWeight.w700 : FontWeight.w400,
                color: isAdd || isDel ? fg : p.muted,
              ),
            ),
          ),
          const SizedBox(width: 4),
          SelectableText(
            l.text.isEmpty ? ' ' : l.text,
            maxLines: 1,
            style: TextStyle(
              fontSize: fontSize,
              fontFamily: 'monospace',
              height: lineHeight,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Item {
  final DiffLine? line;
  final int? lineNo;

  /// 非空表示这是一个折叠占位，值是"折掉了多少行"。
  final int? foldedTo;

  const _Item.line(this.line, this.lineNo) : foldedTo = null;
  const _Item.fold(this.foldedTo)
      : line = null,
        lineNo = null;
}

/// 把带 same 行的完整序列整理成"该显示的条目"。
///
/// [foldContext] 为真时，把连续未改动行折叠成一个占位条目。
List<_Item> _buildItems(List<DiffLine> lines, bool foldContext) {
  final out = <_Item>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].kind == DiffKind.same) {
      var j = i;
      while (j < lines.length && lines[j].kind == DiffKind.same) {
        j++;
      }
      final n = j - i;
      // 少量 same 行直接显示（夹在两处改动之间时，它们就是上下文）。
      if (!foldContext || n <= 4) {
        for (var k = i; k < j; k++) {
          out.add(_Item.line(lines[k], k + 1));
        }
      } else {
        out.add(_Item.fold(n));
      }
      i = j;
    } else {
      out.add(_Item.line(lines[i], i + 1));
      i++;
    }
  }
  return out;
}

/// diff 的配色。深浅两套，跟着主题走。
class DiffPalette {
  final Color addFg;
  final Color addBg;
  final Color delFg;
  final Color delBg;
  final Color normal;
  final Color muted;
  final Color warnFg;
  final Color warnBg;

  const DiffPalette({
    required this.addFg,
    required this.addBg,
    required this.delFg,
    required this.delBg,
    required this.normal,
    required this.muted,
    required this.warnFg,
    required this.warnBg,
  });

  static DiffPalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark) {
      return const DiffPalette(
        // 品牌绿给"新增"；删除用柔和的暖红，别用刺眼的纯红。
        addFg: Color(0xFF3DDC84),
        addBg: Color(0x1A3DDC84),
        delFg: Color(0xFFE88B8B),
        delBg: Color(0x1AE88B8B),
        normal: Color(0xFFD0D6DD),
        muted: Color(0xFF7C8794),
        warnFg: Color(0xFFE0A800),
        warnBg: Color(0x1AE0A800),
      );
    }
    return const DiffPalette(
      addFg: Color(0xFF1B7F4B),
      addBg: Color(0x143DDC84),
      delFg: Color(0xFFB3261E),
      delBg: Color(0x14B3261E),
      normal: Color(0xFF2B3138),
      muted: Color(0xFF6B7580),
      warnFg: Color(0xFF8A6100),
      warnBg: Color(0x14E0A800),
    );
  }
}
