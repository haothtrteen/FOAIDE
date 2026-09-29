/// 差异审阅抽屉（alpha.91）。
///
/// ## 为什么把 AlertDialog 换成这个
///
/// 用户真机上的原话：**"感觉这个弹窗预览不是很好"**，追问后确认痛点是
/// **"窗口太小，132 行根本看不过来"**。
///
/// 原来的实现是 `AlertDialog` + `ConstrainedBox(maxHeight: 170)`。
/// 170px 大约能放 12~15 行，却要塞进 132 行改动 —— 用户得在一个邮票大小
/// 的窗口里滚动上百行。**这是容器选型错误，不是样式问题**：
///   - Dialog 的定位是"确认一件简单的事"（是/否）；
///   - "AI 改了 132 行，要不要保存"是**一份需要审阅的内容**。
///
/// 小窗口装大内容，怎么调都别扭。所以换成**接近全屏的底部抽屉**：
///   - 顶部钉住标题 + 统计 + 三个动作（永远可见，不用滚到底找按钮）；
///   - 中间 diff 占满剩余空间，**横向纵向都能滚**；
///   - 显示比例默认 0.88，留一点背景可见，保留"这是个浮层"的感知
///     —— 全屏 1.0 会让人以为已经离开编辑器了。
///
/// ## 为什么按钮钉在顶部而不是底部
///
/// 内容可能很长。按钮放底部的话，用户看完 132 行才发现还要滚下去点保存，
/// 或者更糟：**没滚到底就以为没有保存按钮，直接返回键退出了**。
library;

import 'package:flutter/material.dart';

import '../ai/diff.dart';
import 'diff_view.dart';

/// 抽屉的三种出口。
enum DiffChoice {
  /// 放弃本次改动（回滚到改动前）。
  discard,

  /// 保留改动但不落盘，先让人自己再看一眼。
  later,

  /// 落盘。
  save,
}

/// 弹出差异审阅抽屉，返回用户的选择（点背景/返回键 = [DiffChoice.later]）。
Future<DiffChoice> showDiffSheet(
  BuildContext context, {
  required String title,
  required List<Widget> warnings,
  required DiffResult diff,
  required List<DiffAction> actions,
}) async {
  final r = await showModalBottomSheet<DiffChoice>(
    context: context,
    isScrollControlled: true,
    // 背景可点：内容很长时，给一个"我看够了"的快速出口，别逼人找按钮。
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _DiffSheet(
      title: title,
      warnings: warnings,
      diff: diff,
      actions: actions,
    ),
  );
  return r ?? DiffChoice.later;
}

/// 抽屉的一个动作按钮。
class DiffAction {
  final String label;
  final DiffChoice choice;
  final bool primary;

  const DiffAction(this.label, this.choice, {this.primary = false});
}

class _DiffSheet extends StatelessWidget {
  const _DiffSheet({
    required this.title,
    required this.warnings,
    required this.diff,
    required this.actions,
  });

  final String title;
  final List<Widget> warnings;
  final DiffResult diff;
  final List<DiffAction> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final media = MediaQuery.of(context);
    final p = DiffPalette.of(context);

    final add = diff.added;
    final del = diff.removed;
    final total = add + del;

    return Padding(
      // 避开键盘 / 手势条，并给底部留出安全区。
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: 0.88,
        child: Container(
          decoration: BoxDecoration(
            color: t.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              // ⚠️ 这里必须是 max（默认值），**不能写 min**。
              // 里面有 `Expanded`，它要求父级给出**紧高度约束**；
              // 写 `mainAxisSize: min` 会让 Column 去测"内容高度"，
              // 而内容高度又依赖 Expanded，小屏/横屏下直接溢出崩掉。
              children: [
                // ---- 抓手（暗示可以下拉关闭）----
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: p.muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 10),

                _header(context, add, del, total, p),

                if (warnings.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: warnings,
                    ),
                  ),

                const Divider(height: 16),

                // ---- diff 本体：占满剩余高度 ----
                Expanded(
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                      child: DiffLinesView(diff),
                    ),
                  ),
                ),

                _footer(context, p, total),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 标题 + 统计 + 动作按钮，全部钉在顶部。
  ///
  /// 长内容场景下，按钮必须**一开始就可见**——否则用户看完 132 行
  /// 才发现还要继续往下滚才能保存（甚至以为没有保存按钮，直接退出）。
  Widget _header(
    BuildContext context,
    int add,
    int del,
    int total,
    DiffPalette p,
  ) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: t.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.pop(context, DiffChoice.later),
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (add > 0) ...[
                _pill('新增 $add 行', p.addFg, p.addBg),
                const SizedBox(width: 8),
              ],
              if (del > 0) ...[
                _pill('删除 $del 行', p.delFg, p.delBg),
                const SizedBox(width: 8),
              ],
              if (total == 0) _pill('无改动', p.muted, p.muted.withValues(alpha: 0.12)),
            ],
          ),
          const SizedBox(height: 10),
          // 按钮放这里而不是底部（见文件头注释）。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in actions)
                a.primary
                    ? FilledButton(
                        onPressed: () => Navigator.pop(context, a.choice),
                        child: Text(a.label),
                      )
                    : OutlinedButton(
                        onPressed: () => Navigator.pop(context, a.choice),
                        child: Text(a.label),
                      ),
            ],
          ),
        ],
      ),
    );
  }

  /// 底部一句"能滚"的提示。
  ///
  /// 抽屉一打开，用户看到的只是改动的前一小段，**很容易以为就这么多**。
  /// 明确告诉他下面还有内容，比让他自己发现"原来能滚"强。
  Widget _footer(BuildContext context, DiffPalette p, int total) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: p.muted.withValues(alpha: 0.18)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.swap_vert, size: 14, color: p.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              total == 0
                  ? '没有改动'
                  : '共 $total 处改动 · 可上下滚动，长代码行可左右滑动查看',
              style: TextStyle(fontSize: 11.5, color: p.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(String text, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
