// Dart 代码补全：轻量词库方案（MVP）。
//
// 不做语义分析，只做前缀匹配 + 内置词库（Dart 关键字 + 常用片段 +
// Flutter 高频类型/方法）。够 Step 2 编辑体验用，
// 后续工具链阶段可替换为真实 Dart analysis server 补全。

enum CompletionKind { keyword, snippet, type, method, identifier }

class CompletionItem {
  final String word; // 匹配用的名称
  final String insert; // 实际插入文本
  final CompletionKind kind;
  const CompletionItem(this.word, this.kind, {String? insert})
      : insert = insert ?? word;
}

const List<CompletionItem> kDartCompletions = [
  // ---- 片段 ----
  CompletionItem('print', CompletionKind.snippet, insert: "print('');"),
  CompletionItem('main', CompletionKind.snippet, insert: 'void main() {}'),
  CompletionItem('import', CompletionKind.snippet, insert: "import '';"),
  CompletionItem('class', CompletionKind.snippet, insert: 'class  {}'),
  CompletionItem('void', CompletionKind.keyword),
  CompletionItem('var', CompletionKind.keyword),
  CompletionItem('final', CompletionKind.keyword),
  CompletionItem('const', CompletionKind.keyword),
  CompletionItem('late', CompletionKind.keyword),
  CompletionItem('new', CompletionKind.keyword),
  CompletionItem('return', CompletionKind.keyword),
  CompletionItem('if', CompletionKind.keyword),
  CompletionItem('else', CompletionKind.keyword),
  CompletionItem('for', CompletionKind.keyword),
  CompletionItem('while', CompletionKind.keyword),
  CompletionItem('do', CompletionKind.keyword),
  CompletionItem('switch', CompletionKind.keyword),
  CompletionItem('case', CompletionKind.keyword),
  CompletionItem('break', CompletionKind.keyword),
  CompletionItem('continue', CompletionKind.keyword),
  CompletionItem('try', CompletionKind.keyword),
  CompletionItem('catch', CompletionKind.keyword),
  CompletionItem('throw', CompletionKind.keyword),
  CompletionItem('rethrow', CompletionKind.keyword),
  CompletionItem('async', CompletionKind.keyword),
  CompletionItem('await', CompletionKind.keyword),
  CompletionItem('yield', CompletionKind.keyword),
  CompletionItem('sync', CompletionKind.keyword),
  CompletionItem('abstract', CompletionKind.keyword),
  CompletionItem('extends', CompletionKind.keyword),
  CompletionItem('implements', CompletionKind.keyword),
  CompletionItem('with', CompletionKind.keyword),
  CompletionItem('mixin', CompletionKind.keyword),
  CompletionItem('enum', CompletionKind.keyword),
  CompletionItem('extension', CompletionKind.keyword),
  CompletionItem('factory', CompletionKind.keyword),
  CompletionItem('get', CompletionKind.keyword),
  CompletionItem('set', CompletionKind.keyword),
  CompletionItem('operator', CompletionKind.keyword),
  CompletionItem('static', CompletionKind.keyword),
  CompletionItem('typedef', CompletionKind.keyword),
  CompletionItem('library', CompletionKind.keyword),
  CompletionItem('part', CompletionKind.keyword),
  CompletionItem('export', CompletionKind.keyword),
  CompletionItem('show', CompletionKind.keyword),
  CompletionItem('hide', CompletionKind.keyword),
  CompletionItem('required', CompletionKind.keyword),
  CompletionItem('covariant', CompletionKind.keyword),
  CompletionItem('external', CompletionKind.keyword),
  CompletionItem('deferred', CompletionKind.keyword),
  CompletionItem('true', CompletionKind.keyword),
  CompletionItem('false', CompletionKind.keyword),
  CompletionItem('null', CompletionKind.keyword),
  CompletionItem('this', CompletionKind.keyword),
  CompletionItem('super', CompletionKind.keyword),
  CompletionItem('dynamic', CompletionKind.keyword),
  CompletionItem('Function', CompletionKind.type),
  // ---- 类型 ----
  CompletionItem('String', CompletionKind.type),
  CompletionItem('int', CompletionKind.type),
  CompletionItem('double', CompletionKind.type),
  CompletionItem('bool', CompletionKind.type),
  CompletionItem('List', CompletionKind.type),
  CompletionItem('Map', CompletionKind.type),
  CompletionItem('Set', CompletionKind.type),
  CompletionItem('Future', CompletionKind.type),
  CompletionItem('Stream', CompletionKind.type),
  CompletionItem('Object', CompletionKind.type),
  CompletionItem('num', CompletionKind.type),
  CompletionItem('Never', CompletionKind.type),
  CompletionItem('Duration', CompletionKind.type),
  CompletionItem('DateTime', CompletionKind.type),
  // ---- Flutter 高频 ----
  CompletionItem('Widget', CompletionKind.type),
  CompletionItem('StatelessWidget', CompletionKind.type),
  CompletionItem('StatefulWidget', CompletionKind.type),
  CompletionItem('State', CompletionKind.type),
  CompletionItem('BuildContext', CompletionKind.type),
  CompletionItem('MaterialApp', CompletionKind.type),
  CompletionItem('Scaffold', CompletionKind.type),
  CompletionItem('AppBar', CompletionKind.type),
  CompletionItem('Container', CompletionKind.type),
  CompletionItem('Column', CompletionKind.type),
  CompletionItem('Row', CompletionKind.type),
  CompletionItem('Center', CompletionKind.type),
  CompletionItem('Padding', CompletionKind.type),
  CompletionItem('SizedBox', CompletionKind.type),
  CompletionItem('Expanded', CompletionKind.type),
  CompletionItem('Text', CompletionKind.type),
  CompletionItem('Icon', CompletionKind.type),
  CompletionItem('IconButton', CompletionKind.type),
  CompletionItem('TextButton', CompletionKind.type),
  CompletionItem('FilledButton', CompletionKind.type),
  CompletionItem('ListView', CompletionKind.type),
  CompletionItem('GridView', CompletionKind.type),
  CompletionItem('Stack', CompletionKind.type),
  CompletionItem('Positioned', CompletionKind.type),
  CompletionItem('GestureDetector', CompletionKind.type),
  CompletionItem('Navigator', CompletionKind.type),
  CompletionItem('MediaQuery', CompletionKind.type),
  CompletionItem('Theme', CompletionKind.type),
  CompletionItem('EdgeInsets', CompletionKind.type),
  CompletionItem('Colors', CompletionKind.type),
  CompletionItem('TextStyle', CompletionKind.type),
  CompletionItem('FontWeight', CompletionKind.type),
  CompletionItem('BoxDecoration', CompletionKind.type),
  CompletionItem('BorderRadius', CompletionKind.type),
  CompletionItem('MaterialPageRoute', CompletionKind.type),
  CompletionItem('InkWell', CompletionKind.type),
  // ---- 方法 ----
  CompletionItem('build', CompletionKind.method),
  CompletionItem('initState', CompletionKind.method),
  CompletionItem('dispose', CompletionKind.method),
  CompletionItem('setState', CompletionKind.method),
  CompletionItem('didUpdateWidget', CompletionKind.method),
  CompletionItem('didChangeDependencies', CompletionKind.method),
  CompletionItem('toList', CompletionKind.method),
  CompletionItem('toString', CompletionKind.method),
  CompletionItem('toInt', CompletionKind.method),
  CompletionItem('toDouble', CompletionKind.method),
  CompletionItem('map', CompletionKind.method),
  CompletionItem('where', CompletionKind.method),
  CompletionItem('forEach', CompletionKind.method),
  CompletionItem('add', CompletionKind.method),
  CompletionItem('remove', CompletionKind.method),
  CompletionItem('contains', CompletionKind.method),
  CompletionItem('split', CompletionKind.method),
  CompletionItem('trim', CompletionKind.method),
  CompletionItem('toUpperCase', CompletionKind.method),
  CompletionItem('toLowerCase', CompletionKind.method),
  CompletionItem('substring', CompletionKind.method),
  CompletionItem('indexOf', CompletionKind.method),
  CompletionItem('lastIndexOf', CompletionKind.method),
  CompletionItem('replaceAll', CompletionKind.method),
  CompletionItem('startsWith', CompletionKind.method),
  CompletionItem('endsWith', CompletionKind.method),
  CompletionItem('length', CompletionKind.method),
];

/// 前缀匹配：精确前缀优先，关键字其次，其余按字母序；最多 8 条。
List<CompletionItem> matchCompletions(String prefix) =>
    matchCompletionsWithIdentifiers(prefix, const <String>{});

/// alpha.80：词库 + 当前文件标识符合并匹配（全文提取版）。
///
/// 借鉴 WebIDE 的 LocalCompletionLanguage 思路（零依赖本地补全）：
/// 静态词库覆盖不到用户自定义的 `_buildActionButton` 这类名字，
/// 扫一遍当前文件的标识符并进候选，补全实用度立刻上一个台阶。
List<CompletionItem> matchCompletionsInSource(String prefix, String source) =>
    matchCompletionsWithIdentifiers(prefix, extractIdentifiers(source));

/// 核心版：标识符集合由调用方提供（编辑器侧对提取结果做 debounce 缓存，
/// 避免每次按键都全文件正则扫描）。
List<CompletionItem> matchCompletionsWithIdentifiers(
    String prefix, Set<String> identifiers) {
  final p = prefix.toLowerCase();
  final hits = kDartCompletions
      .where((c) => c.word.toLowerCase().startsWith(p))
      .toList();
  // 文件标识符：排除与词库重名（大小写不敏感）与正在输入的词本身。
  final known = hits.map((c) => c.word.toLowerCase()).toSet();
  for (final id in identifiers) {
    if (id == prefix) continue; // 自己不补自己
    if (known.contains(id.toLowerCase())) continue;
    if (id.toLowerCase().startsWith(p)) {
      hits.add(CompletionItem(id, CompletionKind.identifier));
    }
  }
  if (hits.isEmpty) return const [];
  hits.sort((a, b) {
    final ae = a.word.toLowerCase() == p ? 0 : 1;
    final be = b.word.toLowerCase() == p ? 0 : 1;
    if (ae != be) return ae - be;
    final ak = a.kind == CompletionKind.keyword ? 0 : 1;
    final bk = b.kind == CompletionKind.keyword ? 0 : 1;
    if (ak != bk) return ak - bk;
    return a.word.compareTo(b.word);
  });
  return hits.take(8).toList();
}

/// 从源码里提取标识符（去重、保出现序），供文件内补全。
///
/// - 最小长度 3：`x`/`ab` 这类短名补全没意义；
/// - 首字符限字母/下划线（正则天然排除纯数字字面量）；
/// - 上限 [kMaxFileIdentifiers]：防超大文件候选爆炸。
const int kMaxFileIdentifiers = 400;

/// 负向后顾：标识符前不能是字母/数字/下划线/$。
/// 排除 `0xFF` 切出的伪标识符 `xFF`、`a1b` 内部重复匹配等数字字面量碎片；
/// 故意**不含点**——`obj.method` 的属性名是常见补全需求，照收。
final RegExp _identRegExp =
    RegExp(r'(?<![A-Za-z0-9_$])[A-Za-z_$][A-Za-z0-9_$]*');

Set<String> extractIdentifiers(String source) {
  final out = <String>{};
  if (source.isEmpty) return out;
  for (final m in _identRegExp.allMatches(source)) {
    final w = m.group(0)!;
    if (w.length >= 3) out.add(w);
    if (out.length >= kMaxFileIdentifiers) break;
  }
  return out;
}
