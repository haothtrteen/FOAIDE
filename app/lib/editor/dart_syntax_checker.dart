// 轻量 Dart 语法检查（MVP，不依赖 rootfs 内的 Dart SDK）。
//
// 扫描状态机检查：
// - 括号配对 () [] {}（含嵌套与跨行）
// - 字符串闭合（' "、三引号、raw 前缀 r、\\ 转义）
// - 块注释闭合 /* */（行注释 // 正确跳过）
//
// 不做语义检查（类型、未定义符号等）——那是 `dart analyze` 的职责，
// 待工具链阶段在 rootfs 内装好 SDK 后接入真检查器。

class SyntaxIssue {
  final int line; // 1 起
  final String message;
  const SyntaxIssue(this.line, this.message);

  @override
  String toString() => '第 $line 行: $message';
}

List<SyntaxIssue> checkDartSyntax(String src) {
  final issues = <SyntaxIssue>[];
  final stack = <(String open, int line)>[];
  var i = 0;
  var line = 1;

  var inBlockComment = false;
  var blockStartLine = 0;
  var inString = false;
  var strChar = '';
  var strStartLine = 0;
  var tripleQuote = false;
  var rawString = false;

  void checkStringEnd(int pos) {
    if (tripleQuote) {
      if (src.startsWith(strChar * 3, pos)) {
        inString = false;
        i = pos + 3;
        return;
      }
    } else if (src[pos] == strChar) {
      inString = false;
      i = pos + 1;
      return;
    }
    i = pos + 1;
  }

  while (i < src.length) {
    final c = src[i];
    if (c == '\n') line++;

    if (inString) {
      if (!rawString && c == r'\' && i + 1 < src.length) {
        i += 2; // 跳过转义字符
        continue;
      }
      checkStringEnd(i);
      continue;
    }

    if (inBlockComment) {
      if (c == '*' && i + 1 < src.length && src[i + 1] == '/') {
        inBlockComment = false;
        i += 2;
      } else {
        i++;
      }
      continue;
    }

    // 行注释：跳过到行尾（\n 交给循环计数）
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      final nl = src.indexOf('\n', i);
      i = nl < 0 ? src.length : nl;
      continue;
    }

    // 块注释开始
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      inBlockComment = true;
      blockStartLine = line;
      i += 2;
      continue;
    }

    // 字符串开始（支持 ' "、三引号、raw 前缀）
    if (c == "'" || c == '"') {
      inString = true;
      strChar = c;
      strStartLine = line;
      tripleQuote = src.startsWith(c * 3, i);
      rawString = i > 0 &&
          (src[i - 1] == 'r' || src[i - 1] == 'R') &&
          (i < 2 || !_isIdentChar(src[i - 2]));
      i += tripleQuote ? 3 : 1;
      continue;
    }

    if (c == '(' || c == '[' || c == '{') {
      stack.add((c, line));
    } else if (c == ')' || c == ']' || c == '}') {
      final expect = _pairOf(c);
      if (stack.isEmpty) {
        issues.add(SyntaxIssue(line, '多余的 "$c"，前面没有与之配对的 "$expect"'));
      } else {
        final (open, openLine) = stack.removeLast();
        if (open != expect) {
          issues.add(SyntaxIssue(
              line, '括号不匹配：第 $openLine 行的 "$open" 期望 "$expect"，实际遇到 "$c"'));
        }
      }
    }
    i++;
  }

  if (inBlockComment) {
    issues.add(SyntaxIssue(blockStartLine, '块注释未闭合（缺少 */）'));
  }
  if (inString) {
    final missing = tripleQuote ? strChar * 3 : strChar;
    issues.add(SyntaxIssue(strStartLine, '字符串未闭合（缺少 $missing）'));
  }
  for (final (open, openLine) in stack.reversed) {
    issues.add(SyntaxIssue(openLine, '缺少 "${_pairOf(open)}" 来闭合 "$open"'));
  }
  return issues;
}

bool _isIdentChar(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);

String _pairOf(String ch) => switch (ch) {
      '(' => ')',
      '[' => ']',
      '{' => '}',
      ')' => '(',
      ']' => '[',
      '}' => '{',
      _ => ch,
    };
