/// 行级 diff（纯函数），供 AI 结果预览折叠展示（alpha.81）。
///
/// 为什么自己写而不用 package:diff：就为了"展示几十行改动"这一个用途，
/// 引一个包不划算；而且我们只需要行级、不需要字符级高亮。
///
/// 复杂度是有边界的：LCS 是 O(n×m)，几千行的文件会到几百万次比较。
/// 超过 [maxLines] 就主动放弃细粒度比对，退化成"整段替换"——宁可
/// 展示得粗一点，也不能让 UI 卡在那儿算 diff。
enum DiffKind { same, add, del }

class DiffLine {
  final DiffKind kind;
  final String text;

  const DiffLine(this.kind, this.text);
}

class DiffResult {
  /// 差异行序列（含 same 行，便于带上下文展示）。
  final List<DiffLine> lines;

  /// true 表示文件太大，已退化为整段替换（UI 应如实说明）。
  final bool tooLarge;

  const DiffResult(this.lines, {this.tooLarge = false});

  int get added => lines.where((l) => l.kind == DiffKind.add).length;
  int get removed => lines.where((l) => l.kind == DiffKind.del).length;

  /// "没有改动"。
  ///
  /// 注意不是"没有行"：内容相同时 [lineDiff] 会直接返回空列表（快路径），
  /// 但调用方真正要问的是"要不要提示用户有差异"，所以这里以**增删计数**
  /// 为准——哪怕带一堆 same 行，只要没有增删就是没改动。
  bool get isEmpty => added == 0 && removed == 0;
}

/// 比对两段文本的**行**差异。
DiffResult lineDiff(String a, String b, {int maxLines = 1200}) {
  final la = _splitLines(a);
  final lb = _splitLines(b);
  if (la.length > maxLines || lb.length > maxLines) {
    return DiffResult(
      [
        ...la.map((t) => DiffLine(DiffKind.del, t)),
        ...lb.map((t) => DiffLine(DiffKind.add, t)),
      ],
      tooLarge: true,
    );
  }
  // 完全相同是最常见的情况（AI 返回的就是原文），先走快路径。
  if (a == b) return const DiffResult(<DiffLine>[]);
  // 行序列相同也算相同：'a\nb' 与 'a\nb\n' 是同一份内容，
  // 不该因为末尾有没有换行就刷出一屏"未改动"的行。
  if (_sameLines(la, lb)) return const DiffResult(<DiffLine>[]);
  return DiffResult(_lcsDiff(la, lb));
}

List<String> _splitLines(String s) {
  if (s.isEmpty) return const [];
  final out = s.split('\n');
  // 'a\n' split 后尾巴会多一个空串，它不是真实的一行
  if (out.isNotEmpty && out.last.isEmpty) out.removeLast();
  return out;
}

bool _sameLines(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 经典 LCS：先算最长公共子序列的长度表，再回溯出增/删/相同行。
List<DiffLine> _lcsDiff(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final dp = List.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
    growable: false,
  );
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(DiffLine(DiffKind.same, a[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add(DiffLine(DiffKind.del, a[i]));
      i++;
    } else {
      out.add(DiffLine(DiffKind.add, b[j]));
      j++;
    }
  }
  while (i < n) {
    out.add(DiffLine(DiffKind.del, a[i]));
    i++;
  }
  while (j < m) {
    out.add(DiffLine(DiffKind.add, b[j]));
    j++;
  }
  return out;
}
