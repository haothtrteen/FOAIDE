/// 导入已有 UI 到「设计」区（alpha.71）。
///
/// **它解决的问题**：用户已经把界面写出来了（`login_page.dart` 里一个
/// 漂漂亮亮的 `LoginPage`），想在设计器里可视化地改，而不是对着设计器
/// 从模板重新拼一遍。需求原话：*"能不能给页面加一个自定义页面，
/// 将已经写好的 UI 显示在这里面改。"*
///
/// ## 为什么用真解析器而不是正则
///
/// 正则干这个活会在第一个多行参数（`Text(\n  'hi',\n  style: ...)`）、
/// 第一个嵌套字符串（`Text('a(')`）、第一个尾随逗号时就散架。
/// `analyzer` 是 Dart 官方解析器，它给出的 `AstNode.offset/end`
/// 让我们能**按字符精确切走一段源码**，这是"不认识的东西原样带回"
/// 能成立的基础。
///
/// ## 纯逻辑层
///
/// 本文件**不引 `flutter/material.dart`**，与 [design_model.dart] 同风格：
/// 解析正确性可以脱离 UI、脱离真机、纯字符串断言。
/// 真机文件遍历那部分（[findDartFiles]）依赖 `FsBridge`，但它接收的是
/// 抽象出来的查目录/读文件回调，测试里塞个假的即可。
library;

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';

import 'design_model.dart';

// ==================== 公开数据结构 ====================

/// 一个可导入的入口：源码里的某个 `build` 方法。
class ImportCandidate {
  /// 拥有这个 build 的类名（`StatefulWidget` 取的是 State 类名）。
  final String className;

  /// `build` 方法所在的类名（用于给用户看："这是 LoginPage"）。
  ///
  /// 对 `StatefulWidget`，[className] 会带上 State 后缀，
  /// 这个字段保留**用户认得的那个名字**。
  final String displayName;

  /// build 方法所在行（1 起）。给用户看在文件里的位置。
  final int line;

  const ImportCandidate({
    required this.className,
    required this.displayName,
    required this.line,
  });

  @override
  String toString() => '$displayName（第 $line 行）';
}

/// 导入结果。
class ImportResult {
  final DesignNode root;

  /// 成功映射成设计器可编辑组件的数量。
  final int converted;

  /// 落成占位节点（原样带回）的数量。
  final int unknown;

  /// 给用户看的说明（摊平了 Row、跳过了某个 widget 之类）。
  final List<String> notes;

  const ImportResult({
    required this.root,
    required this.converted,
    required this.unknown,
    required this.notes,
  });

  /// 有没有需要提醒用户的事。
  bool get hasNotes => notes.isNotEmpty;
}

// ==================== 候选识别 ====================

/// `Widget build(BuildContext context)` 的方法名。
const String _kBuild = 'build';

/// 扫源码里所有可导入的页面类。
///
/// 识别规则：类里有一个叫 `build`、**恰好一个必填位置参数**的方法。
/// 不检查返回类型是不是 `Widget` —— 那需要类型解析（要整个 package 的
/// 上下文），而 `parseString` 只做语法解析。误报的代价很低：
/// 用户在候选列表里看到它、点进去发现不对、退出来，没有副作用。
List<ImportCandidate> findCandidates(String source) {
  final unit = _parse(source);
  if (unit == null) return const <ImportCandidate>[];

  final out = <ImportCandidate>[];
  for (final decl in unit.declarations) {
    if (decl is! ClassDeclaration) continue;
    final className = decl.namePart.typeName.lexeme;
    for (final member in decl.body.members) {
      if (member is! MethodDeclaration) continue;
      if (member.name.lexeme != _kBuild) continue;
      if (!_looksLikeBuild(member)) continue;
      out.add(ImportCandidate(
        className: className,
        // `LoginPage` 的 State 类叫 `_LoginPageState` —— 用户认不出来。
        // 去掉前导下划线和 State 后缀，还原成他写在 `MaterialApp` 里的名字。
        displayName: _friendlyName(className),
        line: _lineOf(source, member.offset),
      ));
    }
  }
  return out;
}

/// `_LoginPageState` → `LoginPage`。
String _friendlyName(String className) {
  var s = className;
  if (s.startsWith('_')) s = s.substring(1);
  if (s.endsWith('State') && s.length > 'State'.length) {
    s = s.substring(0, s.length - 'State'.length);
    // `_HomeViewState` → `HomeView`（尾部的 View 一并去掉不好，
    // 只去 State）。`_LoginState` 这种（原名就叫 Login）不动。
  }
  return s.isEmpty ? className : s;
}

bool _looksLikeBuild(MethodDeclaration m) {
  final params = m.parameters;
  if (params == null) return false;
  // 只要有一个必填位置参数就算（`build(BuildContext context)`）。
  // 不严格要求参数类型是 BuildContext —— 见 findCandidates 的注释。
  return params.parameters.any((p) => !p.isNamed && !p.isOptionalPositional);
}

int _lineOf(String source, int offset) {
  var line = 1;
  final end = offset < source.length ? offset : source.length;
  for (var i = 0; i < end; i++) {
    if (source.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

// ==================== 导入 ====================

/// 把一个候选导入成设计树。
///
/// 找不到该候选时返回一个空 root（而不是抛异常）—— 调用方是 UI 回调，
/// 抛出去只会变成一个红色屏幕，用户完全不知道发生了什么。
ImportResult importCandidate(String source, ImportCandidate candidate) {
  final unit = _parse(source);
  if (unit == null) {
    return ImportResult(
      root: DesignNode(type: DesignComponentType.root),
      converted: 0,
      unknown: 0,
      notes: const <String>['这个文件解析不了（语法错误？），没法导入'],
    );
  }

  final method = _findBuild(unit, candidate);
  if (method == null) {
    return ImportResult(
      root: DesignNode(type: DesignComponentType.root),
      converted: 0,
      unknown: 0,
      notes: <String>['没找到 ${candidate.displayName} 的 build 方法'],
    );
  }

  final body = method.body;
  Expression? expr;
  if (body is ExpressionFunctionBody) {
    // `Widget build(c) => const Text('x');`
    expr = body.expression;
  } else if (body is BlockFunctionBody) {
    expr = _returnedExpression(body.block);
  }
  if (expr == null) {
    return ImportResult(
      root: DesignNode(type: DesignComponentType.root),
      converted: 0,
      unknown: 0,
      notes: <String>[
        '${candidate.displayName} 的 build 方法没有直接 `return` 一个 widget'
            '（是不是把界面写在别的方法里了？）',
      ],
    );
  }

  final ctx = _ImportCtx(
    source,
    unit,
    // ⚠️ 入口类必须在这里告知：候选类的 `build` 是**直接**调
    // [buildChildren] 展开的（不像其他类那样经过 [_localBuildExpr]
    // 的入栈），所以 `_classStack` 全程是空的、`currentOwner` 为
    // null —— 那样本类私有方法（`_buildEnvCard(context)`）会因为
    // "不知道自己在哪个类里"而全部解析失败。这正是真实项目导入时
    // "一整屏全是未识别"的根因。
    entryClass: candidate.className,
  );
  final root = DesignNode(
    type: DesignComponentType.root,
    props: <String, Object?>{
      // 导入时不做"猜"：padding/背景/滚动一律保持"用户没要求过"的状态。
      // 猜错的话用户会以为是自己写的属性丢了。
      'background': 'none',
      'padding': 16.0,
      'scroll': true,
    },
    children: ctx.buildChildren(expr),
  );

  return ImportResult(
    root: root,
    converted: ctx.converted,
    unknown: ctx.unknown,
    notes: ctx.notes,
  );
}

/// 找块体里的第一个顶层 `return` 表达式。
///
/// 只找**顶层**，不进 if/for 的分支 —— 那种返回值取决于运行时条件，
/// 静态选一个分支就是在编造用户没写的东西。找不到就返回 null，
/// 由调用方给一句人话说明。
Expression? _returnedExpression(Block block) {
  for (final stmt in block.statements) {
    if (stmt is ReturnStatement) return stmt.expression;
  }
  return null;
}

MethodDeclaration? _findBuild(CompilationUnit unit, ImportCandidate c) {
  for (final decl in unit.declarations) {
    if (decl is! ClassDeclaration) continue;
    if (decl.namePart.typeName.lexeme != c.className) continue;
    for (final member in decl.body.members) {
      if (member is MethodDeclaration &&
          member.name.lexeme == _kBuild &&
          _looksLikeBuild(member)) {
        return member;
      }
    }
  }
  return null;
}

// ==================== 源码切片 ====================

/// 切出某个 AST 节点对应的源码。
///
/// `AstNode.offset` / `end` 是相对**整个文件**的字符下标，半开区间
/// `[offset, end)` —— 所以 `substring(offset, end)` 恰好切出整段，
/// 不多不少。这是"不认识的 widget 原样带回"能成立的关键。
///
/// ⚠️ 存**源码字符串**而不是 AST 子树：AST 不含注释，
/// 把子树重新打印出来会把注释全丢掉，"原样带回"就成了空话。
/// 切片还能保留用户原本的换行与缩进。
String sliceSource(String source, AstNode node) {
  final start = node.offset.clamp(0, source.length);
  final end = node.end.clamp(start, source.length);
  return source.substring(start, end);
}

/// 切出节点**连同它前后的注释**。
///
/// ## 为什么不能只用 [sliceSource]
///
/// 注释在 Dart AST 里是 **trivia**，不挂在任何节点上 ——
/// `Column(children: [\n  // 这里是图表\n  MyChart(),\n])` 里那句注释
/// 谁的 offset 都不包含它。只切节点本体的话注释会被静默吃掉，
/// 而"原样带回"的承诺就落空了。
///
/// 所以这里从 token 层把注释捞回来：
/// - **前导**：往左吃掉紧邻的空白与注释，直到上一行还有实质代码
///   （不能无限往左吃，否则会把前面那个 widget 也切进来 ——
///   前导取值止于上一个非空白 token 的行尾）
/// - **行尾**：往右吃掉同一行的 `// 注释`
String sliceSourceWithComments(String source, AstNode node) {
  final len = source.length;
  var start = node.offset.clamp(0, len);

  // ---- 前导注释 ----
  //
  // ⚠️ 三个坑，都踩过：
  //
  // 1. `Token.precedingComments` 是一个**单向链表**（靠 `CommentToken.next`
  //    串起来），不是 List —— 直接 for-in 会拿到一个 `Object`，编译不过。
  //    而且 `next` 的静态类型是 `Token?` 而不是 `CommentToken?`。
  //
  // 2. ⚠️ **行尾注释在解析器眼里是"下一个 token 的前导注释"。**
  //    `MyChart(), // 数据源\nQux()` 里那句 `// 数据源` 挂在 `Qux` 上，
  //    **不挂在 `MyChart` 上**。所以往左捞时不能无脑跨行 ——
  //    跨过换行就会把上一个组件的行尾注释重复带回两次。
  //
  // 3. 判别规则（唯一一条）：**注释自己必须独占它前面那部分行**
  //    （从它所在行的行首到它之间只有空白），**且它和节点之间没有
  //    实质代码**。这一条同时挡掉 `a; /* x */ b` 和上一行的行尾注释
  //    —— 后者虽然也独占不了行（行首前面还有 `MyChart(),`），
  //    自然就被排除了。
  Token? c = node.beginToken.precedingComments;
  while (c != null) {
    final s = c.offset.clamp(0, len).toInt();
    final e = c.end.clamp(0, len).toInt();
    if (!_isBlankBetween(source, _lineStartOf(source, s), s)) break;
    if (_hasCodeBetween(source, e, node.offset)) break;
    start = start < s ? start : s;
    final next = c.next;
    if (next == null) break;
    if (_hasCodeBetween(source, e, next.offset.clamp(0, len).toInt())) break;
    c = next;
  }

  // ---- 行尾注释 ----
  //
  // ⚠️ 这里**不用** token 链去捞。实测 `MyChart(data: d), // 数据源` 里
  // 那句话既不在 `MyChart(...)` 的 `endToken`（`)`）上，也不在它 `next`
  // 的 `precedingComments` 上（它是**下一个**节点的前导注释，见上）。
  // 而且沿着 token 链 `next` 遍历会踩到自引用节点、死循环。
  //
  // 改成**直接扫源码**：从节点末尾往右，只要还是同一行且遇到 `//`，
  // 就把这一行剩下的部分带走。简单、可控、不跟解析器的 trivia
  // 存放策略绑死（那是实现细节，换个 analyzer 版本就可能变）。
  var end = node.end.clamp(start, len);
  var i = end;
  while (i < source.length && (source[i] == ' ' || source[i] == '\t')) {
    i++;
  }
  // ⚠️ 列表元素后面还有**逗号**，`node.end` 停在 `)` 上，往后第一个字符
  // 就是 `,` —— 不跳过它的话永远看不到后面那句注释。
  if (i < source.length && source[i] == ',') {
    i++;
    while (i < source.length && (source[i] == ' ' || source[i] == '\t')) {
      i++;
    }
  }
  if (i + 1 < source.length && source[i] == '/' && source[i + 1] == '/') {
    while (i < source.length && source[i] != '\n') {
      i++;
    }
    // 只吃注释本体，逗号留给生成器补（`DesignCodeGen` 会检查 raw
    // 是否以 `,` 结尾再决定加不加）。
    end = i;
  }
  return source.substring(start, end);
}

/// [offset] 所在行的行首下标。
int _lineStartOf(String source, int offset) {
  var i = offset.clamp(0, source.length) - 1;
  while (i >= 0 && source[i] != '\n') {
    i--;
  }
  return i + 1;
}

bool _isBlankBetween(String source, int from, int to) {
  if (to <= from) return true;
  for (var i = from.clamp(0, source.length);
      i < to.clamp(0, source.length);
      i++) {
    final ch = source[i];
    if (ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r') return false;
  }
  return true;
}

/// `from` 到 `to` 之间有没有**实质代码**（注释不算 —— 注释是 trivia，
/// 我们会单独把它捞回来）。
bool _hasCodeBetween(String source, int from, int to) {
  if (to <= from) return false;
  final seg = source.substring(
    from.clamp(0, source.length),
    to.clamp(0, source.length),
  );
  // 剥掉行注释与块注释，剩下的还有非空白就是代码。
  var s = seg
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'//[^\n]*'), '');
  return s.trim().isNotEmpty;
}

// ==================== 解析上下文 ====================

/// 一次导入的状态（计数 + 提醒）。
class _ImportCtx {
  _ImportCtx(this.source, this.unit, {String? entryClass})
      : _entryClass = entryClass;

  final String source;

  /// 整份文件的 AST。用来做**同文件内的自定义组件跳转**
  /// （见 [_localBuildExpr]）—— 只有拿到全量声明才可能知道 `HomePage`
  /// 是这个文件里定义的类。
  final CompilationUnit? unit;

  /// 正在展开的自定义类栈（防 `A → B → A` 互相引用时打转）。
  ///
  /// 用栈而不是"访问过的集合"：同一个类被两个不同地方引用
  /// （菱形引用）是合法的、应该各展开一次，只有**环**才需要挡。
  final List<String> _classStack = <String>[];

  /// 正在展开的**本类私有方法**栈（防 `_a() → _b() → _a()` 打转）。
  ///
  /// 和 [_classStack] 分开维护：两者挡的是不同种类的环，混在一个栈里
  /// 会让"类 A 里调方法 f、方法 f 又 new 了 A"这种**合法**写法被误判成环。
  /// 键带类名前缀（`_HomeState._buildEnvCard`），避免两个类里的同名
  /// 私有方法互相误伤。
  final List<String> _methodStack = <String>[];

  /// 展开私有方法时，**形参名 → 实参表达式**的绑定栈。
  ///
  /// ## 它解决什么
  ///
  /// `_buildSectionTitle(context, '环境状态')` 的方法体是 `Text(title)`，
  /// 而 `title` 是个形参 —— 光看方法体永远求不出值，于是落成未识别。
  /// 但**值就在调用点写着**（`'环境状态'`）。把实参按位置绑给形参，
  /// `Text(title)` 就能求出 `Text('环境状态')`。
  ///
  /// 这是纯静态的对应关系，不是猜 —— Dart 方法调用的位置参数顺序是
  /// 编译期确定的。命名参数（`title: 'x'`）同理。
  ///
  /// ⚠️ 用**栈**而不是单张表：`_buildX(title)` 展开到一半又调了
  /// `_buildY(title)`，两层都有自己的 `title`。栈顶优先，退栈即失效。
  final List<Map<String, Expression>> _paramBindings =
      <Map<String, Expression>>[];

  /// 查形参绑定的值（栈顶优先，逐层往下）。
  ///
  /// 返回 null 表示"这不是个绑定了的形参"，调用方按原逻辑继续求值
  /// （可能是字段、可能是真的求不出来）。
  Expression? boundParam(String name) {
    for (var i = _paramBindings.length - 1; i >= 0; i--) {
      final hit = _paramBindings[i][name];
      if (hit != null) return hit;
    }
    return null;
  }

  int converted = 0;
  int unknown = 0;
  final List<String> notes = <String>[];

  /// 动态列表摊平后的条目暂存区（见 [_flattenDynamicList] 的返回值说明）。
  ///
  /// 填完立刻被取走（`return _dynamicListNodes[i]`），所以复用一块缓冲
  /// 是安全的。用成员而不是返回值，纯粹是因为"多个兄弟节点"塞不进
  /// 单个 `DesignNode?`。
  final List<DesignNode> _dynamicListNodes = <DesignNode>[];

  /// 递归深度上限。
  ///
  /// 源码里的嵌套深度是用户写的，正常不会太深；但**构造出来的**
  /// 深层嵌套（一长串 `Padding(child: Padding(child: ...))`）会让
  /// 递归栈爆掉。超了就当占位节点处理，结构不丢（raw 还在）。
  static const int _maxDepth = 32;

  /// 静态求值的递归上限（`a = b` / `b = a` 这类互相引用会打转）。
  static const int _maxResolveDepth = 8;

  /// 展开**本类私有方法**的递归深度上限。
  ///
  /// 为什么是 8 而不是 [_maxDepth] 的 32：32 是给"用户手写的嵌套 widget"
  /// 用的，那是语法上可见的一层套一层；而方法调用链的深度是**代码组织
  /// 习惯**的体现 —— 拆到第 8 层已经不是"拆方法"而是 RxJava 了。
  /// 限死在这里，超了就当未识别退回（不猜），符合
  /// "解不开就退回黄框"的既定策略。
  static const int _maxMethodDepth = 8;

  /// [_flattenDynamicList]：读不出来，落占位节点。
  static const int _kListUnknown = -2;

  /// [_flattenDynamicList]：铺出来了，但**不要**再落占位节点。
  static const int _kListGiveUp = -1;

  /// [_flattenDynamicList]：铺好了，去 [_dynamicListNodes] 取。
  static const int _kListOK = 0;

  /// 把这些 widget 表达式当"整体"展开出的节点**只用来比对**，不写进结果。
  ///
  /// [buildChildren] 有个副作用：展开过程会往 [notes] 里写提醒。
  /// 「试展开 -> 比对 -> 不满意就丢掉」这套动作如果直接走 [buildChildren]，
  /// 被丢掉的那一版留下的提醒会永远黏在结果里 —— 用户会看到
  /// 一条解释"为什么没铺开"的话，而实际上已经铺开了。
  /// 所以试展开期间把提醒通道掐掉（见 [_probe]）。
  bool _probing = false;

  /// 把一个 widget 表达式转成若干**兄弟**节点。
  ///
  /// 返回列表而不是单个节点，是因为有些 widget 要**摊平**：
  /// `Column` 在设计器里没有对应物（设计器模型本身就是 Column 同构的），
  /// 包成一个 `card` 是**凭空加用户没写过的视觉元素**。
  List<DesignNode> buildChildren(Expression expr, {int depth = 0}) {
    if (depth > _maxDepth) return <DesignNode>[_unknown(expr)];
    final node = _toNode(expr, depth);
    return node == null ? <DesignNode>[] : _flatten(node);
  }

  // ---------------- 同文件里的局部常量/状态初值 ----------------

  /// 从同文件的自定义类里取一个**字段的初值表达式**。
  ///
  /// ## 它解决什么
  ///
  /// 官方模板里满屏都是 `_big ? 200 : 100`、`Text('$_count')`、
  /// `_items[i]` 这类写法。静态展开它们是不可能的（值在运行时变），
  /// 于是全被甩成「未识别」—— 用户看到的是"这个工具连模板都没适配"。
  ///
  /// 但其实**初值是写在源码里的**：`int _count = 0`、`bool _big = false`、
  /// `static const List<String> _items = ['Flutter', ...]`。
  /// 拿它当"这一屏打开时长什么样"的代表值是**有依据的**，不是编造 ——
  /// 前提是**告诉用户这是初值**（见 [_noteModelValue]）。
  ///
  /// 只认四种地方，收窄到"翻不出来"就返回 null：
  /// 无参数的构造方法体（`_count` 的常见写法）、字段声明（`_big` / `_items`）、
  /// 类自己的无参方法（`_HomePageState` 这类写法）。
  ///
  /// ⚠️ **不做类型解析**，所以不知道 `_count` 到底属于哪个类。调用方传进来的
  /// [_owner] 是从展开栈上取的实际类名（有就精确，没有才退化成"同名任取"）。
  Expression? localConstantExpr(String rawName, {String? owner}) {
    final name = _stripThis(rawName);
    if (name.isEmpty) return null;
    final u = unit;
    if (u == null) return null;

    final classes = <ClassDeclaration>[];
    for (final d in u.declarations) {
      if (d is ClassDeclaration) classes.add(d);
    }
    // 先从**正在展开的那个类**里找（最准），再退到"所有类里同名任取"。
    if (owner != null && owner.isNotEmpty) {
      for (final c in classes) {
        if (c.namePart.typeName.lexeme == owner) {
          final hit = _fieldInitIn(c, name) ?? _getterInitIn(c, name);
          if (hit != null) return hit;
        }
      }
    }
    for (final c in classes) {
      final hit = _fieldInitIn(c, name) ?? _getterInitIn(c, name);
      if (hit != null) return hit;
    }
    return null;
  }

  /// 当前正在展开的类名（[buildChildren] 的栈顶）。
  ///
  /// 没有正在展开的类时返回 null —— 那种情况下字段名只可能是页面级的
  /// 全局量，退化成"同名任取"就够了。
  String? get currentOwner =>
      _classStack.isEmpty ? _entryClass : _classStack.last;

  /// 本次导入的**入口类名**（用户选的那个候选）。
  ///
  /// 它不能靠 [_classStack] 表达：入口的 `build` 是直接展开的，
  /// 整个展开过程中都不会入栈。但它恰恰是"本类私有方法"最主要的
  /// 宿主 —— 用户截图里的 `_FOAIDEHomePageState` 就是入口类。
  final String? _entryClass;

  static String _stripThis(String rawName) {
    var s = rawName.trim();
    if (s.startsWith('this.')) s = s.substring('this.'.length);
    return s.trim();
  }

  /// `int _count = 0;` → `0`。
  ///
  /// 只认**没有初始化表达式以外东西**的声明：`late` / `final` / `const`
  /// 都无所谓（初值照旧），但只声明不赋值（`int _count;`）返回 null。
  static Expression? _fieldInitIn(ClassDeclaration cls, String name) {
    for (final m in cls.body.members) {
      if (m is! FieldDeclaration) continue;
      final v = m.fields.variables;
      for (final vv in v) {
        if (vv.name.lexeme == name) return vv.initializer;
      }
    }
    return null;
  }

  /// 无参取值器当成常量读：`int get _count => 0;` / `bool get _big { return false; }`。
  ///
  /// 少见，但 `_items` 这种"模板里放的假数据"确实有人这么写。
  /// ⚠️ 只认**没有参数**的 —— 有参数的方法（`_itemAt(i)`）不是常量。
  static Expression? _getterInitIn(ClassDeclaration cls, String name) {
    for (final m in cls.body.members) {
      if (m is! MethodDeclaration) continue;
      if (m.name.lexeme != name) continue;
      final ps = m.parameters;
      if (ps != null && ps.parameters.isNotEmpty) return null;
      final b = m.body;
      if (b is ExpressionFunctionBody) return b.expression;
      if (b is BlockFunctionBody) return _returnedExpression(b.block);
    }
    return null;
  }

  /// 把一个表达式**静态求值**成字符串（取不到返回 null）。
  ///
  /// 能算的：字符串字面量、相邻拼接、整数/小数、布尔、`!`、`-`、
  /// 以及**名字**（递归翻字段初值，带深度上限防 `a = b` / `b = a` 打转）。
  ///
  /// 算不了的一律返回 null —— 宁可退回占位节点，也不写一个假的值进去：
  /// 生成物是给用户当起点的，一个凭空冒出来的字面量比一段"未识别"更误导。
  String? resolveString(Expression? e, {int depth = 0, String? owner}) {
    if (e == null || depth > _maxResolveDepth) return null;
    final lit = _stringLiteral(e);
    if (lit != null) return lit;
    final num = _numberLiteral(e);
    if (num != null) return _fmtNum(num);
    if (e is BooleanLiteral) return e.value ? 'true' : 'false';
    if (e is PrefixExpression && e.operator.lexeme == '!') {
      final inner = resolveString(e.operand, depth: depth + 1, owner: owner);
      if (inner == 'true') return 'false';
      if (inner == 'false') return 'true';
      return null;
    }
    // `a ?? b` / `a ??= b`：左边求得出就用左边，求不出就用右边。
    //
    // ⚠️ 这里之所以"敢"取右边，是因为语义上**两者都是候选值**，不是
    // 编造 —— `title ?? '默认'` 在 `title` 为 null 时**真的**显示
    // `'默认'`。而形参代入（[_ImportCtx.boundParam]）恰好能让左边
    // 有值可用，于是 `_title(context, '环境状态')` 这种调用能取到
    // 真正的实参，默认值只在参数真没传时才兜底。
    //
    // 若不代入，左边求不出来时的回退是安全的：设计器渲染的是
    // "这一屏打开时的样子"，可选参数没传就必然是默认值。
    if (e is BinaryExpression && e.operator.lexeme == '??') {
      final left = resolveString(e.leftOperand, depth: depth + 1, owner: owner);
      if (left != null) return left;
      return resolveString(e.rightOperand, depth: depth + 1, owner: owner);
    }
    final nm = _identifierName(e);
    if (nm != null) {
      // 形参优先于字段 —— 这正是 Dart 的遮蔽规则（形参在内层，
      // 字段在外层）。`_buildSectionTitle(context, title)` 里
      // `Text(title)` 的 `title` 是形参，不是同名的字段。
      final bound = boundParam(nm);
      if (bound != null) {
        return resolveString(bound, depth: depth + 1, owner: owner);
      }
      return resolveString(
        localConstantExpr(nm, owner: owner ?? currentOwner),
        depth: depth + 1,
        owner: owner,
      );
    }
    return null;
  }

  /// 同上，但求一个数值。
  double? resolveNumber(Expression? e, {int depth = 0, String? owner}) {
    if (e == null || depth > _maxResolveDepth) return null;
    final n = _numberLiteral(e);
    if (n != null) return n;
    final nm = _identifierName(e);
    if (nm != null) {
      final bound = boundParam(nm); // 形参优先于字段，见 resolveString
      if (bound != null) {
        return resolveNumber(bound, depth: depth + 1, owner: owner);
      }
      return resolveNumber(
        localConstantExpr(nm, owner: owner ?? currentOwner),
        depth: depth + 1,
        owner: owner,
      );
    }
    return null;
  }

  /// `true` / `false` 的静态值。三元分支选择靠它。
  bool? resolveBool(Expression? e, {int depth = 0, String? owner}) {
    if (e == null || depth > _maxResolveDepth) return null;
    if (e is BooleanLiteral) return e.value;
    if (e is PrefixExpression && e.operator.lexeme == '!') {
      final inner = resolveBool(e.operand, depth: depth + 1, owner: owner);
      return inner == null ? null : !inner;
    }
    final nm = _identifierName(e);
    if (nm != null) {
      final bound = boundParam(nm); // 形参优先于字段，见 resolveString
      if (bound != null) {
        return resolveBool(bound, depth: depth + 1, owner: owner);
      }
      return resolveBool(
        localConstantExpr(nm, owner: owner ?? currentOwner),
        depth: depth + 1,
        owner: owner,
      );
    }
    return null;
  }

  /// 按名字取一个 `String` 列表字段的**全部**元素（`_items`）。
  ///
  /// 与 [resolveString] 分开是因为信息量不同：`_items[i]` 取哪一条取决于
  /// 运行时的 `i`，光有"第一项"没法回答。整张表拿到手，才能两件事：
  /// 1. `separated` 知道该生成几条静态项（不再是"1 条假数据"）；
  /// 2. `_items[i]` 至少能落到一条**真的写过**的字符串上。
  ///
  /// 收名字而不是表达式：调用点那边已经只剩一个名字了（`_items[i]`
  /// 的下标是 AST 节点，目标名却是剥出来的字符串）。为它造一个假的
  /// `SimpleIdentifier` 不值 —— analyzer 的 AST 节点是 final class，
  /// 外面继承不了。
  List<String>? localStringList(String rawName, {String? owner}) =>
      resolveStringList(
        localConstantExpr(rawName, owner: owner ?? currentOwner),
      );

  /// 字符串列表字面量的静态值（`['a', 'b']` → 两项）。
  List<String>? resolveStringList(Expression? e,
      {int depth = 0, String? owner}) {
    if (e == null || depth > _maxResolveDepth) return null;
    if (e is ListLiteral) {
      final out = <String>[];
      for (final el in e.elements) {
        if (el is! Expression) return null; // 展开/条件元素：整张表不可信
        final v = resolveString(el, depth: depth + 1, owner: owner);
        if (v == null) return null;
        out.add(v);
      }
      return out;
    }
    final nm = _identifierName(e);
    if (nm != null) {
      return resolveStringList(
        localConstantExpr(nm, owner: owner ?? currentOwner),
        depth: depth + 1,
        owner: owner,
      );
    }
    return null;
  }

  /// 字符串插值里的一个"洞"（`$name` / `${i + 1}`）。
  ///
  /// [`index`] 是 `_items[i]` 里那个索引名（可能是 `null`）。
  /// 索引洞能算出**行号**：`'${i + 1}'` 的第 0 行是 `'1'`；
  /// 其余洞（`$_count`）用字段初值。
  ///
  /// ## 读不出来时返回 null，**不**返回 `'?'`
  ///
  /// 早先这里回 `'?'`，理由是"比吞掉诚实"。但那个 `?` 会**真的写进
  /// 用户的界面**：`Text('你好 $name')` 里的 `$name` 如果是没声明的
  /// 局部变量（`name` 不在字段表里），导入结果就是一句
  /// **`你好 ?`** —— 生成出去的代码里也带着这个问号。
  /// 用户看到的是"工具往我的文案里塞了个问号"，这比缺一个值恶劣得多：
  /// 缺值他一眼能看出来，多了个问号他可能上线了才发现。
  ///
  /// 返回 null 让调用方**整条退回占位节点** —— 源码原样带回，
  /// 一个字都不改。
  String? resolveHole(Expression e, {String? index}) {
    final nm = _identifierName(e);
    if (nm != null) {
      final lit = resolveString(e);
      if (lit != null) return lit;
      // `...$name` 里嵌的字符串字面量（`'${'x'}'`）走不到这儿，
      // 上面 resolveString 已经覆盖。
      //
      // 走到这里 = 这个标识符既不是字符串也不是从字段初值里翻出来的
      // （`$name` 里的 `name` 很可能根本没声明）。返回 null 让整条
      // 回退到占位节点 —— 见方法头上那段"不要塞问号"的说明。
      return null;
    }
    // 二元 `i + 1`：插值里的绝大多数写法都是这个。
    if (e is BinaryExpression) {
      final left = _identifierName(e.leftOperand);
      final right = resolveNumber(e.rightOperand);
      if (left != null && right != null) {
        if (index != null && left == index) {
          // 行号：先按 0 起算出下标，再按用户的 `+ 1` 还原。
          final v = e.operator.lexeme == '+'
              ? 0 + right
              : (e.operator.lexeme == '-' ? 0 - right : double.nan);
          if (!v.isNaN) return _fmtNum(v);
        }
        final base = resolveNumber(e.leftOperand);
        if (base != null) {
          final v = e.operator.lexeme == '+'
              ? base + right
              : (e.operator.lexeme == '-' ? base - right : double.nan);
          if (!v.isNaN) return _fmtNum(v);
        }
      }
    }
    final n = resolveNumber(e);
    if (n != null) return _fmtNum(n);
    return resolveString(e);
  }

  /// 报一次"这个值来自源码里的初值/占位"。
  /// ⚠️ 这条提醒是**功能的一部分**，不是装饰：静态展开出来的值和真机
  /// 上跑起来的值可能不一样（`_count` 点一下就变了）。不告诉用户的话，
  /// 他会以为设计器能把运行时状态也画出来 —— 然后对着一个永远显示 `0`
  /// 的计数器想不通。
  void _noteModelValue() {
    _noteOnce('带状态/插值的值是按源码里的**初值**渲染的'
        '（比如 `_count = 0` 显示 0、`_big = false` 取 false 那一支）——'
        '真机上点一下它就变了，设计器只画"刚打开时长什么样"');
  }

  /// 报一次"这条目是我们按你写的静态数据铺的"。
  void _noteListItems(int n) {
    _noteOnce('动态列表按你写的静态数据（$n 项）铺成了静态条目 —— '
        '生成的是写死的界面，接回真实数据源要你自己改');
  }

  /// 拆掉摊平容器：`[fence[a, b]]` → `[a, b]`。
  ///
  /// 为什么要有这一层：`_toNode` 只能返回**一个**节点
  /// （它是个表达式 → 节点的映射），但摊平（Column / Padding 穿透）
  /// 天然产出**多个**兄弟。用一个带标记的临时容器装起来、在这里拆开，
  /// 比让 `_toNode` 的签名变成 `List<DesignNode>` 要简单 ——
  /// 后者会传染给每一个调用点，到处都是 `...` 展开。
  ///
  /// ⚠️ 必须**递归**拆。常见写法 `Scaffold(body: Padding(child: Column(...)))`
  /// 会形成 `fence[ fence[ a, b ] ]` 这样的多层嵌套 ——
  /// 只拆一层的话第二层会作为真节点留在树里，而它的 `raw` 是空的，
  /// 生成时只会吐出一行 `// （未识别组件，已跳过）`，用户写的内容凭空消失。
  List<DesignNode> _flatten(DesignNode n) {
    if (!_isSpliceFence(n)) return <DesignNode>[n];
    final out = <DesignNode>[];
    for (final c in n.children) {
      out.addAll(_flatten(c));
    }
    return out;
  }

  /// 单个 widget 表达式 → 节点（可能返回 null 表示"吞掉"）。
  DesignNode? _toNode(Expression expr, int depth) {
    final call = _asWidgetCall(expr);
    if (call == null) {
      // 不是构造调用：三元表达式、方法调用（`_buildHeader()`）、
      // `.map()` 的结果…… 全部原样带回。
      return _unknown(expr);
    }
    final name = call.name;

    // ---- 同文件内自定义的组件：跳进它的 build ----
    //
    // `MaterialApp(home: const CounterPage())` 是最常见的写法 —— 真正的
    // 界面在**另一个类**里。不跟过去的话，用户导入后看到的第一个东西
    // 就是「未识别：CounterPage」，而那个类明明就在同一个文件里、点开
    // 就能读懂。这种"看着像坏了"的观感，比少导一个组件糟得多。
    //
    // ⚠️ 为什么放在 [_mapKnown] **之前**：名字撞车（用户自己写了个叫
    // `Text` 的类）的代价是展开错一个类，而放在后面则所有自定义组件
    // 都永远导不进来。前者是极端个例，后者是日常。
    final local = _localBuildExpr(name);
    if (local != null) {
      if (_classStack.contains(local.owner)) return null; // A → B → A，别转圈
      _classStack.add(local.owner);
      final List<DesignNode> kids;
      try {
        kids = buildChildren(local.body, depth: depth + 1);
      } finally {
        // 必须 finally：中途抛异常时栈不回滚的话，后续所有同名类
        // 都会被误判成"环"而静默消失。
        _classStack.removeLast();
      }
      return _synthetic(kids);
    }

    // ---- 本类里的私有方法：跳进它的方法体 ----
    //
    // 位置在 [_localBuildExpr] 之后、[_kPassThrough] 之前：
    // ①② 类名优先（`_HomePageState` 这种跨类跳转信息量更大）；
    // ②③ 必须在 [_kPassThrough] 之前 —— 否则用户写了个
    //      `Widget _padding(...)` 之类重名方法时，会被当成框架的
    //      `Padding` 透明穿透掉，静默吞掉整棵子树。
    //
    // ⚠️ 和 [_localBuildExpr] 的关键差别：那边跳进去的是**另一个类**，
    // 展开完要用 [_synthetic] 包一层（因为"类"在设计器里没有对应物）；
    // 这里的私有方法本身就是"这几个 widget 的集合"，展开出来是什么就
    // 是什么，所以直接 [_splice] 提子节点，不多套壳。
    final methodExpr = _localMethod(name, call);
    if (methodExpr != null) {
      final key = '${currentOwner ?? ''}.$name';
      if (_methodStack.contains(key)) return null; // _a → _b → _a，别转圈
      if (_methodStack.length >= _maxMethodDepth) {
        // 超深：退回未识别，不猜。用户如果真是这么写的，
        // 他需要的是重构自己的代码，不是看工具硬猜。
        _noteOnce('自定义方法的展开跳转超过 $_maxMethodDepth 层，'
            '更深的已按原样保留');
        return _unknown(expr);
      }
      _methodStack.add(key);
      _paramBindings.add(methodExpr.bindings);
      final List<DesignNode> kids;
      try {
        kids = buildChildren(methodExpr.body, depth: depth + 1);
      } finally {
        // 同 [_localBuildExpr]：必须 finally，中途抛异常时不回滚的话，
        // 后续所有同名方法都会被误判成"环"而静默消失。
        _paramBindings.removeLast();
        _methodStack.removeLast();
      }
      if (kids.isEmpty) return null;
      return _splice(kids);
    }

    // ---- 透明穿透：布局修饰不是组件 ----
    //
    // `Padding` / `Center` / `Align` / `SafeArea` 在源码里是"把里面那个
    // 东西挪一挪"，在设计器里挪一挪没有意义（属性面板只管组件自身）。
    // 把它们建成节点的话，用户会看到一棵塞满布局包装的树，
    // 想找"那个按钮"要点开五层 —— 而其中四层他都改不了。
    //
    // ⚠️ 因为"外面那层不留节点"，这里必须能返回**多个**节点
    // （`Padding(child: Column(children: [a, b]))` → a、b 两个兄弟），
    // 所以走 [_splice] 而不是直接 return。早先写成
    // `if (kids.length == 1) return kids.first;` 的话，
    // 多出来的那些会被静默丢掉 —— 用户会看到"我写的东西少了半截"。
    if (_kPassThrough.contains(name)) {
      final inner = call.childArgument;
      if (inner == null) return null;
      return _splice(buildChildren(inner, depth: depth + 1));
    }

    // ---- 摊平：Column / Row ----
    if (name == 'Column' || name == 'Row') {
      final kids = call.childrenArgument;
      if (kids == null) return _unknown(expr);
      if (name == 'Row') {
        // ⚠️ 横排变竖排是**真的变了**，必须告诉用户。
        // 设计器的生成器不生成 Row（design_model.dart 明确写了不做
        // 布局容器），所以这里没法保真。静默摊平用户会以为是自己写错了。
        _noteOnce('横排（Row）已摊平成竖排 —— 设计器不生成横向布局，'
            '生成后需要你自己改回去');
      }
      final out = _elementsOf(kids, depth);
      // 空的 Column（占位用）保留成间距，否则用户看到的是"这里什么都没有"。
      if (out.isEmpty) return null;
      return _splice(out);
    }

    // ---- 认识的组件 ----
    final mapped = _mapKnown(name, call, expr, depth);
    if (mapped != null) return mapped;

    // ---- 不认识的：占位 + 源码切片 ----
    return _unknown(expr);
  }

  /// 找同文件里 `name` 这个**自定义类**的 build 返回表达式。
  ///
  /// 两种形态都要认：
  /// - `class HomePage extends StatelessWidget` —— build 直接在它身上；
  /// - `class HomePage extends StatefulWidget` —— build 在 `_HomePageState`
  ///   里（`StatefulWidget` 自己只有 `createState`）。这是大头：内置模板
  ///   里带交互的（计数器、动画）全是这种。
  ///
  /// ⚠️ 返回值带上 `owner`（**真正持有那个 build 的类名**），而不是让
  /// 调用方拿 `name` 去入栈 —— 两者在 StatefulWidget 场景下是**不一样**的
  /// （`FOAIDEHomePage` vs `_FOAIDEHomePageState`）。用错的那个入栈，
  /// 类里所有私有方法（`_buildEnvCard`）都会因为"当前类名对不上"
  /// 而解析失败 —— 这正是导入 `MaterialApp` 包着的页面时"看起来
  /// 什么都没解开"的根因。
  ///
  /// 找不到返回 null，调用方会退回「已知组件表」，再退到占位节点。
  _LocalBuild? _localBuildExpr(String name) {
    final u = unit;
    if (u == null) return null;
    for (final cls in <String>[name, '_${name}State']) {
      final m = _findBuild(
        u,
        ImportCandidate(className: cls, displayName: cls, line: 0),
      );
      if (m == null) continue;
      final b = m.body;
      final Expression? ret;
      if (b is ExpressionFunctionBody) {
        ret = b.expression;
      } else if (b is BlockFunctionBody) {
        ret = _returnedExpression(b.block);
      } else {
        ret = null;
      }
      if (ret == null) continue;
      return _LocalBuild(cls, ret);
    }
    return null;
  }

  /// 找**当前正在展开的类**里 `name` 这个私有方法。
  ///
  /// ## 它解决什么
  ///
  /// 真实项目里最常见的代码组织方式是"把一段界面抽成一个私有方法"：
  ///
  /// ```dart
  /// Column(children: [
  ///   _buildEnvCard(context),                           // ← 本方法
  ///   _buildSectionTitle(context, '环境状态'),
  ///   _buildStatusCard(context),
  /// ])
  /// ```
  ///
  /// 这些方法就写在**同一个 class 里**（`_buildEnvCard` 的定义离调用点
  /// 可能只有 200 行），信息完全够静态解析。不跟进去的话，一整屏真实
  /// 界面会塌成几个「未识别」占位 —— 用户看到的是"这工具连最基本的
  /// 拆方法都不认"。
  ///
  /// ## 为什么只认「本类」+「私有」这两条
  ///
  /// - **本类**：类名从 [currentOwner] 拿。跨类方法（`other.build()`）
  ///   和顶层函数都要处理命名冲突与作用域，收益远小于复杂度，不做。
  /// - **私有**（名字以 `_` 开头）：公开方法名（`build` / `initState` /
  ///   用户自己的 `header()`）撞上 Flutter 框架方法或第三方方法时，
  ///   在**没有类型解析**的前提下无法区分，跳错地方的代价是"展开出
  ///   一段不属于这里的界面"，比不展开糟得多。私有下划线是语法层能
  ///   拿到的最强信号 —— 它保证了这个名字只可能在本文件里被定义。
  ///
  /// 找不到 / 不满足条件返回 null，调用方退回「未识别」占位。
  _LocalMethod? _localMethod(String name, _WidgetCall call) {
    if (!name.startsWith('_')) return null;
    final u = unit;
    if (u == null) return null;
    final owner = currentOwner;
    if (owner == null || owner.isEmpty) return null;

    for (final d in u.declarations) {
      if (d is! ClassDeclaration) continue;
      if (d.namePart.typeName.lexeme != owner) continue;
      for (final m in d.body.members) {
        if (m is! MethodDeclaration) continue;
        if (m.name.lexeme != name) continue;
        final b = m.body;
        final Expression? ret;
        if (b is ExpressionFunctionBody) {
          ret = b.expression;
        } else if (b is BlockFunctionBody) {
          ret = _returnedExpression(b.block);
        } else {
          ret = null;
        }
        if (ret == null) return null;
        return _LocalMethod(ret, _bindParams(m, call));
      }
    }
    return null;
  }

  /// 把调用点的实参按**位置/名字**绑给方法声明的形参。
  ///
  /// `_buildSectionTitle(context, '环境状态')` + 声明
  /// `Widget _buildSectionTitle(BuildContext context, String title)`
  /// → `{title: '环境状态'}`。
  ///
  /// ⚠️ analyzer 14 里所有形参（含 `[x]` / `{x: v}`）都实现了
  /// `FormalParameter.name`，所以**不用**去分辨 `DefaultFormalParameter`
  /// 那套已改名的子类 —— 直接读 `name`，可选性由
  /// `FormalParameterList` 的括号区分（见下）。
  ///
  /// ⚠️ 该跳过的绝不硬塞：
  /// - 位置实参个数**少于必填形参**个数 → 整个放弃，不做部分绑定。
  ///   部分绑定会让某几个形参悄悄拿到错位的值，比全不绑定危险得多。
  /// - `context`、`key` 这类没有界面意义的参数绑上也求不出值，
  ///   但不影响其他参数，所以照常绑。
  static Map<String, Expression> _bindParams(
      MethodDeclaration decl, _WidgetCall call) {
    final out = <String, Expression>{};
    final ps = decl.parameters;
    if (ps == null) return out;

    // 声明侧：必填位置形参（在 `(` 里）与可选位置形参（在 `[` 里）都要，
    // 但只有前者参与"个数够不够"的校验。
    final positional = <String>[];
    var requiredPositional = 0;
    for (final p in ps.parameters) {
      final nm = p.name?.lexeme;
      if (nm == null) {
        // 老写法 `void f(int)`（无名字）：位置对不齐了，放弃绑定。
        if (!p.isNamed) return out;
        continue;
      }
      if (p.isNamed) continue;
      positional.add(nm);
      if (!p.isOptionalPositional) requiredPositional++;
    }

    // 调用侧：按顺序取位置实参（跳过命名实参），再逐个命名实参。
    final args = <Expression>[];
    final named = <String, Expression>{};
    for (final a in call._args) {
      if (a is NamedArgument) {
        named[a.name.lexeme] = a.argumentExpression;
      } else {
        args.add(a.argumentExpression);
      }
    }
    if (args.length < requiredPositional) return out; // 对不上，整个放弃

    for (var i = 0; i < positional.length && i < args.length; i++) {
      out[positional[i]] = args[i];
    }
    out.addAll(named);
    return out;
  }

  /// 摊平的"容器"节点：本身不参与生成，子节点会被提到父级。
  ///
  /// 用来把"展开出的多个节点"临时装成一个节点返回 —— 父级
  /// （[buildChildren]）看到它会立刻拆开，把 children 提到自己名下。
  /// 所以它**永远不会出现在最终的树里**。
  DesignNode _splice(List<DesignNode> kids) => DesignNode(
        type: DesignComponentType.unknown,
        props: <String, Object?>{'raw': '', 'sourceName': ''},
        children: kids,
      );

  /// 这是不是上面那个"提子节点"的临时容器。
  static bool _isSpliceFence(DesignNode n) =>
      n.type == DesignComponentType.unknown &&
      (n.props['raw'] as String? ?? '') == '' &&
      (n.props['sourceName'] as String? ?? '') == '' &&
      n.children.isNotEmpty;

  /// 摊平的结果需要"挂"在某个节点上返回 —— 用一个代理节点承载。
  ///
  /// ⚠️ 这些代理节点**不会被生成**（它们没有对应的 widget），
  /// 所以 type 用 `unknown` 但 `raw` 留空标记它是透明的，
  /// 由 [buildChildren] 拆开、把子节点提到父级。
  DesignNode _synthetic(List<DesignNode> kids) {
    return DesignNode(
      type: DesignComponentType.unknown,
      props: <String, Object?>{'raw': '', 'sourceName': ''},
      children: kids,
    );
  }

  DesignNode? _mapKnown(
      String name, _WidgetCall call, Expression expr, int depth) {
    switch (name) {
      // 应用外壳：页面本体在 `home:` 里，壳本身在设计器里没有对应物
      // （title / theme / 路由都由工程属性决定，不是画布上的组件）。
      //
      // ⚠️ 不能塞进 [_kPassThrough]：那张表读的是 `childArgument`，
      // 而 MaterialApp 用的是 `home:` —— 塞进去会拿到 null，等于没改。
      // 这条也是 alpha.71 六个内置模板"全军覆没"的唯一根因：
      // 它们的 build 全都 `return MaterialApp(...)`，于是导入器第一眼
      // 就撞上不认识的 MaterialApp，甩出一个「未识别」占位，
      // 用户还没看到自己的界面就以为导入坏了。
      //
      // ⚠️ 返回 [_synthetic] 而不是直接返回 home 转出的节点：`home` 可能
      // 展开成多个兄弟（`Scaffold` 的 AppBar 标题 + body 就是两个），
      // 直接返回会丢掉一半。
      case 'MaterialApp':
      case 'CupertinoApp':
      case 'WidgetsApp':
        {
          final home = call.namedArgument('home');
          if (home == null) return null;
          return _synthetic(buildChildren(home, depth: depth + 1));
        }

      // 动态列表：条目是**运行时**由 itemBuilder 生成的。
      //
      // alpha.73 起：如果 `itemCount` 和条目内容**都能从源码里读出来**
      // （`itemCount: _items.length` + `Text(_items[i])`，也就是官方
      // `list` 模板那种写法），就摊成真的静态条目 —— 那才是"更接近真相"。
      // 读不出来（`itemCount: 3` 配 `Text('x')` 这种编出来的例子）仍旧
      // 原样保留：把一条假数据复制三份就是在编造用户没写过的东西。
      case 'ListView':
      case 'GridView':
        {
          // ## ⚠️ 这一段为什么长这样
          //
          // 它要"摊成多个兄弟节点" —— 而 `switch` 的每个分支只能吐一个值，
          // 所以只能包成 [_splice]（`_toNode` 看到会拆开、把子节点提上去）
          // 再 `return`，**不能** `break` 出去。
          //
          // 一开始写成 `nodes = ...; break outer;` 想"交回 `_toNode` 处理"，
          // 结果 Dart 把 `switch` 里的 `break` 当成**穿透**信号——
          // 直接掉进了下一个 case（`TabBarView`），一棵铺好的树被套进
          // 「未识别」里。这类"看着像 break 其实是 fall through"的坑
          // 不会报错，只会让功能静默变形 —— 所以这里彻底不用 `break`。
          // ⚠️ 匹配的是 `_kListOK`（0）而不是 `>= 0` ——
          // `Dart 3` 的 relational pattern（`>= 0`）**不**匹配 `0`，
          // 它匹配的是"严格大于 0 的常量"。因为这个函数只回
          // `0` / `_kListGiveUp` / `_kListUnknown` 三个值，
          // 写成 `>= 0` 就等于永远走最后那条兜底分支 ——
          // 列表项明明铺好了，结果还是落成「未识别」（又踩了一次）。
          return switch (_flattenDynamicList(name, call, depth, expr)) {
            _kListOK => _splice(_dynamicListNodes),
            _kListGiveUp => null,
            // 真读不出来：落占位节点，源码整段带走。
            _ => () {
                _noteOnce('动态列表（$name）已原样保留 —— 条目由代码生成，'
                    '设计器只能编辑静态组件');
                return null;
              }(),
          };
        }

      // 标签页容器：设计器没有多标签结构，TabBar / TabBarView 都留不下。
      // 这里**必须留一句提醒** —— 静默丢掉一整个 tab 栏，用户会以为
      // 是自己没写。能留下的只有 `child:` 里那部分。
      //
      // `TabBarView` 也一并认掉，但是它**必须两手都硬**：
      // 官方 `tabs` 模板写的是"每个标签页都长得一样"
      // （三个 `Center(child: Text('x内容'))`），顺手把三份都铺出来；
      // 而三个标签页**各不相同**才是更常见的情况，那时候替用户选一个
      // 就是在丢掉另外两个 —— 那种情况退回占位节点，整段源码带走。
      case 'TabBarView':
        {
          final kids = call.childrenArgument;
          final parts = _tabsOf(kids);
          if (parts == null) {
            // ⚠️ 措辞要跟下面那条拆开。这句话是**失败路径**：
            // 一个标签页都没铺出来，整段 TabBarView 原样带回。
            _noteOnce('TabBarView 的几个标签页内容不一样，设计器只能挑一个 —— '
                '替你做主会丢掉另外几个，所以整段原样带回了（别在这里删）');
            return null;
          }
          // 成功路径：内容铺出来了，但**多标签结构**没铺。
          // 措辞必须说清"铺开了什么、没铺什么"，否则用户会以为整段丢了。
          _noteOnce('标签页（$name）的内容按标签顺序铺开了，'
              '但多标签切换的结构留不下 —— TabBar 要你自己加回');
          return _splice(parts);
        }

      // `DefaultTabController` 只是个"提供 TabController 的壳"，
      // 它自己不出节点 —— 真正的内容在 `child:` 里。
      //
      // ## 提醒要不要留：看下面的 `TabBarView` 说没说
      //
      // child 通常正是 `TabBarView`，而那条分支自己会留一句
      // "多标签结构留不下、TabBar 要你自己加回"。这里再留一句就成了
      // 一模一样的两句 —— 用户会以为出了两个问题。
      //
      // 但**不能因此一律不留**：`DefaultTabController(length: 2,
      // child: Scaffold(body: ...))` 这种（没有 TabBarView）照样把
      // tab 栏丢掉了，这时候一声不吭，用户会以为是自己没写。
      //
      // 判据：展开 child 前后比一下 `notes` 有没有新增 ——
      // 新增了就说明下面已经解释过了。
      case 'DefaultTabController':
        {
          final child = call.namedArgument('child');
          if (child == null) return null;
          final before = notes.length;
          final kids = buildChildren(child, depth: depth + 1);
          if (notes.length == before) {
            _noteOnce('标签页（DefaultTabController）只导入了内容部分 —— '
                '多标签切换的结构留不下，TabBar 要你自己加回');
          }
          return _synthetic(kids);
        }

      case 'Scaffold':
        // Scaffold 就是页面本身 —— 取 AppBar 的标题 + body，壳交给设计器的 root。
        final out = <DesignNode>[];
        final appBar = call.namedArgument('appBar');
        if (appBar != null) {
          final t = _appBarTitle(appBar);
          if (t != null) {
            converted++;
            out.add(DesignNode(
              type: DesignComponentType.heading,
              props: <String, Object?>{'text': t, 'bold': true},
            ));
          }
        }
        final body = call.namedArgument('body');
        if (body != null) out.addAll(buildChildren(body, depth: depth + 1));
        // ⚠️ `floatingActionButton:` **必须单独读**。
        // 它在 Scaffold 里是一个**具名参数**，不在 `body` 的子树上 ——
        // 早先只读 `appBar` + `body`，于是 FAB 被**静默丢掉**：
        // 用户写了颗悬浮按钮，设计器里没有、生成物里也没有，
        // 而 notes 里一个字都没有。这是"悄悄改用户代码"，最不能接受的一类。
        //
        // 设计器有 `fab` 外壳类型，落在 children 里，生成时会被
        // `_buildRoot` 摘出去当 `Scaffold(floatingActionButton: ...)`。
        final fab = call.namedArgument('floatingActionButton');
        if (fab != null) out.addAll(buildChildren(fab, depth: depth + 1));
        if (out.isEmpty) return null;
        return _synthetic(out);

      case 'AppBar':
        // AppBar 在设计器里没有独立类型，它的 title 就是页面标题。
        // 正常路径由上层 Scaffold 处理；这里兜住"直接把 AppBar 当返回值"
        // 的写法（少见，但用户试的时候会撞上）。
        final t = _appBarTitle(expr);
        if (t == null) return _unknown(expr);
        converted++;
        return DesignNode(
          type: DesignComponentType.heading,
          props: <String, Object?>{'text': t, 'align': 'left', 'bold': true},
        );

      case 'Text':
        // 走 [_textOf] 而不是直接 `_stringLiteral`：`Text('$_count')`
        // 这种插值也在这个分支里被展开（用 `_count` 的初值 0）。
        // alpha.72 及以前这里是 `_stringLiteral(...) ?? _unknown(expr)`，
        // 于是计数器模板那个最显眼的数字变成一个「未识别」框。
        final t = _textOf(call.firstArg, expr);
        if (t == null) return _unknown(expr);
        converted++;
        return DesignNode(
          type: DesignComponentType.text,
          props: <String, Object?>{'text': t},
        );

      case 'ElevatedButton':
      case 'FilledButton':
      case 'OutlinedButton':
      case 'TextButton':
        return _mapButton(name, call, expr);

      case 'TextField':
      case 'TextFormField':
        return _mapTextField(call, expr);

      case 'Icon':
        final iconName = _iconNameOf(call.firstArg);
        // 白名单外的图标（`Icons.qr_code_2`）映射不过去 ——
        // 强行映射会生成 `Icons.star`，把用户的图标换掉了。
        if (iconName == null) return _unknown(expr);
        converted++;
        return DesignNode(
          type: DesignComponentType.icon,
          props: <String, Object?>{'name': iconName},
        );

      case 'Image':
        final label =
            call.firstArg == null ? '图片' : _buttonLabel2(call.firstArg) ?? '图片';
        converted++;
        return DesignNode(
          type: DesignComponentType.image,
          props: <String, Object?>{'label': label},
        );

      case 'SizedBox':
        // ⚠️ `SizedBox` 有两个身份，**必须分开**：
        // - `SizedBox(height: 24)`（无 child）→ 间距组件
        // - `SizedBox(child: Text('x'))`（有 child）→ 布局包装
        //
        // 早期版本把它一律当包装处理 —— 结果裸 `SizedBox(height: 24)`
        // 因为没有 child 而返回 null，被**整个丢掉**。
        // 布局丢失是导入最不能接受的一类错误：预览和原图对不上，
        // 用户却不知道是自己写错了还是工具吃掉了。
        if (call.childArgument == null) {
          // `height: _gap` 这种也要读得出来 —— `_numberLiteral` 只认字面量，
          // 会静默退成默认的 16，而用户明明写了个具名常量。
          final h = resolveNumber(call.namedArgument('height'));
          converted++;
          return DesignNode(
            type: DesignComponentType.spacer,
            props: <String, Object?>{'height': h ?? 16.0},
          );
        }
        converted++;
        return _splice(buildChildren(call.childArgument!, depth: depth + 1));

      case 'Spacer':
        converted++;
        return DesignNode(type: DesignComponentType.spacer);

      // `AnimatedContainer` —— 官方 `anim` 模板的主角。
      //
      // ## 为什么最终摊平了（alpha.74 改主意）
      //
      // 早先这里是**故意**不处理的：摊平会丢三样东西（`duration` /
      // `curve` 的补间、`decoration` 里那个任意 RGB、`_big ? 200 : 100`
      // 那个三元），不如整段原样带回。
      //
      // 那个判断本身没错，但**结论错了**。用户的原话是
      // 「这几个 demo 模板强行适配一下」——他要的是**能显示**。
      // 一个画着"未识别"的灰条摆在预览里，比一个尺寸/颜色略有色差的
      // 方块**更妨碍理解**：前者看不出这是什么，后者一眼就是"那块绿的"。
      //
      // 现在的取舍：**按源码里的初值画成静态块**，三处丢失全部
      // 写进 `notes` 说清楚（不是"没适配"，是"适配后这几样会不一样"）。
      // 生成时用 `raw` 把整段 `AnimatedContainer(...)` 原样写回 ——
      // **代码一个字都不改**，动画在真机上照旧跑，只是设计器里是静的。
      case 'AnimatedContainer':
        {
          final sized = _animatedBox(call);
          if (sized == null) break; // 什么都读不出来 → 退回占位节点
          converted++;
          return sized;
        }

      // `AnimatedContainer` —— 官方 `anim` 模板的主角。
      //
      // ## 为什么**不**把它摊成 `icon`
      //
      // 试过。它有明确的尺寸和颜色，看着完全能落成设计器已有的 `icon`
      // 组件 —— 但那条路会**丢三样东西**，而且丢得很隐蔽：
      //
      // 1. `duration` / `curve` —— 补间动画本身（设计器没有动画概念）
      // 2. `decoration` 里的颜色（设计器的颜色字段只有 9 个**语义位**，
      //    任意 RGB 存不下，见 [kColorSlots]）
      // 3. `width: _big ? 200 : 100` 那个**三元**（只留下初值那一支）
      //
      // 摊平后生成的是一句干巴巴的 `Icon(Icons.x, size: 100)` ——
      // 用户回头一看：动画没了、颜色变了、尺寸写死了。**三处静默丢失**，
      // 而设计器里那条"未识别"提示条至少还诚实地写着"这里有个东西
      // 我看不懂，原样给你带回去了"。
      //
      // 结论：保持占位节点 + 原样带回源码。这不是"没适配"，
      // 是"适配了会发现丢得更多"。
      //
      // ## 但尺寸还是要读出来
      //
      // 占位节点本身有 `width` / `height` 属性（见 `design_model.dart`
      // 里 `unknown` 的 `defaultProps`）：预览按真实尺寸画框，
      // 用户一眼能看出"这块有多大"。这两个值由 [_unknown] 去读，
      // 走的就是下面这个 [_rectSize]。
      // 悬浮按钮：设计器有 `fab` 外壳类型，正好对上。
      //
      // ⚠️ 早先它连"认识"都不算 —— 未识别里那个 `FloatingActionButton`
      // 占位节点，把一整颗按钮（含 tooltip 和图标）当成看不懂的东西带回去，
      // 而设计器明明有现成的悬浮按钮组件。这是"没适配"而不是"适配不了"。
      case 'FloatingActionButton':
        converted++;
        return DesignNode(
          type: DesignComponentType.fab,
          props: <String, Object?>{
            'icon': _iconNameOf(call.childArgument) ?? 'add',
            'tooltip': _buttonLabel2(call.namedArgument('tooltip')) ?? '',
          },
        );

      // Flutter 官方 logo：没有对应组件，但**有对应图标** ——
      // 落成一个 96 的大图标，比一个「未识别」框接近原图得多
      // （`nav` 模板里那个 `Hero(child: FlutterLogo(size: 96))` 就是它）。
      case 'FlutterLogo':
        {
          final size = resolveNumber(call.namedArgument('size')) ?? 96.0;
          converted++;
          return DesignNode(
            type: DesignComponentType.icon,
            props: <String, Object?>{'name': 'flutter_dash', 'size': size},
          );
        }

      case 'Divider':
        converted++;
        return DesignNode(type: DesignComponentType.divider);

      case 'Card':
        converted++;
        return DesignNode(
          type: DesignComponentType.card,
          children: _childrenOf(call, depth),
        );

      case 'ListTile':
        // ⚠️ `ListTile` 的 `title` / `subtitle` / `leading` 都是 **Widget**
        // 而不是字符串 —— `title: Text('首页')`，不是 `title: '首页'`。
        // 早先直接 `_stringLiteral(namedArgument('title'))` 拿到的是 null，
        // 于是每个 ListTile 都被套上默认值「列表项」，用户写的字**全丢了**，
        // 而且不报错。这类"属性静默回落到默认值"是最难发现的 bug：
        // 树是对的、节点在、只有内容是假的。
        final title = _buttonLabel2(call.namedArgument('title'));
        final subtitle = _buttonLabel2(call.namedArgument('subtitle'));
        final leading = _iconNameOf(call.namedArgument('leading'));
        converted++;
        return DesignNode(
          type: DesignComponentType.listTile,
          props: <String, Object?>{
            'title': title ?? '',
            'subtitle': subtitle ?? '',
            'leadingIcon': leading ?? 'circle',
          },
        );
    }
    return null;
  }

  DesignNode? _mapButton(String name, _WidgetCall call, Expression expr) {
    // `.icon` 具名构造把文案放在 `label:` 而不是 `child:` 里 ——
    // `FilledButton.icon(icon: ..., label: Text('下一步'))`。
    // 只认 `child:` 的话整颗按钮会掉进「未识别」，而它明明看得懂。
    final label =
        _buttonLabel(call) ?? _buttonLabel2(call.namedArgument('label'));
    if (label == null) return _unknown(expr);
    const styleOf = <String, String>{
      'ElevatedButton': 'filled',
      'FilledButton': 'filled',
      'OutlinedButton': 'outlined',
      'TextButton': 'text',
    };
    converted++;
    return DesignNode(
      type: DesignComponentType.button,
      props: <String, Object?>{
        'text': label,
        'style': styleOf[name] ?? 'filled',
      },
    );
  }

  DesignNode? _mapTextField(_WidgetCall call, Expression expr) {
    final deco = call.namedArgument('decoration');
    var label = '';
    var hint = '';
    var obscure = false;

    // `obscureText: true`
    if (call.namedArgument('obscureText')?.toSource() == 'true') obscure = true;

    // `decoration: InputDecoration(labelText: '邮箱')`
    final decoCall = deco == null ? null : _asWidgetCall(deco);
    if (decoCall != null) {
      label = _stringLiteral(decoCall.namedArgument('labelText')) ?? '';
      hint = _stringLiteral(decoCall.namedArgument('hintText')) ?? '';
      // `InputDecoration(label: Text('邮箱'))` 也能写，且是更常见的写法。
      if (label.isEmpty) {
        final l = decoCall.namedArgument('label');
        label = _buttonLabel2(l) ?? '';
      }
    }
    if (label.isEmpty && hint.isEmpty) return _unknown(expr);
    converted++;
    return DesignNode(
      type: DesignComponentType.textField,
      props: <String, Object?>{
        'label': label.isEmpty ? hint : label,
        'hint': hint,
        'obscure': obscure,
      },
    );
  }

  /// `AppBar(title: Text('我的页面'))` → `'我的页面'`。
  ///
  /// 处理两种写法：`title: Text(...)`（最常见）和 `title: const Text(...)`。
  String? _appBarTitle(Expression appBar) {
    final call = _asWidgetCall(appBar);
    if (call == null || call.name != 'AppBar') return null;
    final title = call.namedArgument('title');
    if (title == null) return null;
    return _buttonLabel2(title);
  }

  /// 取一个"装着 Text 的表达式"里的文案（`Text('x')` 或直接 `'x'`）。
  ///
  /// 这是**所有**"源码里的字符串 → 设计树里的字符串"的唯一入口。
  /// 中间那条 [_textOf] 分支是为插值加的：`Text('$_count')`
  /// 不是 `StringLiteral` 而是 `StringInterpolation`，
  /// 直接 `_stringLiteral` 拿到 null，整段文字就没了。
  String? _buttonLabel2(Expression? e) {
    if (e == null) return null;
    final inner = _asWidgetCall(e) ?? _asWidgetCall(_unwrapConst(e));
    if (inner != null && inner.name == 'Text') {
      return _textOf(inner.firstArg, e);
    }
    // `child: '文字'`：裸字符串在这个位置不合法（要 Widget），
    // 但 `ListTile(title: null)` 之类会走到这儿，顺带兜一下。
    return _textOf(e, e);
  }

  /// 从"可能带插值的字符串表达式"里取出文案。
  ///
  /// 三层，从最保真往下退：
  /// 1. 纯字面量 → 原样返回（`Text('你好')`）；
  /// 2. 插值 → 把洞换成**源码里的初值**（`Text('$_count')` → `'0'`），
  ///    每展开一次都留一句提醒（见 [_noteModelValue]）；
  /// 3. 都取不到 → 返回 null，由调用方决定是占位还是回默认值。
  ///
  /// [outer] 只用于兜底时判断整个表达式本身是不是个三元/别名。
  String? _textOf(Expression? e, Expression outer) {
    if (e == null) return null;
    final lit = _stringLiteral(e);
    if (lit != null) return lit;

    // `Text(_items[i])`：索引表达式先剥掉，用列表里的真实数据。
    final indexed = _indexedBase(e);
    if (indexed != null) {
      final items = localStringList(indexed.name);
      if (items != null && items.isNotEmpty) {
        _noteListItems(items.length);
        _noteModelValue();
        final v = indexed.index < 0
            ? items.first
            : items[indexed.index.clamp(0, items.length - 1)];
        return v;
      }
    }

    if (e is StringInterpolation) {
      final buf = StringBuffer();
      for (final el in e.elements) {
        if (el is InterpolationString) {
          buf.write(el.value);
          continue;
        }
        if (el is InterpolationExpression) {
          final hole = resolveHole(el.expression, index: indexed?.name);
          // 有一个洞读不出来 → **整条**放弃，退回占位节点。
          // 只填空的洞、把剩下的拼出来，会造出一句"半真半假"的文案
          // （`'一共 ${a + b} 项'` 里 b 读不到就变成 `一共 ? 项`），
          // 那比整条原样带回更难排查 —— 见 [resolveHole] 的说明。
          if (hole == null) return null;
          buf.write(hole);
          continue;
        }
        // `InterpolationExpression` / `InterpolationString` 之外的
        // 元素类型（理论上不该有）—— 认不出来就整条放弃。
        return null;
      }
      _noteModelValue();
      return buf.toString();
    }

    // 三元：分支是**字符串**（`Text(_big ? '缩小' : '放大')`）。
    // 和 `label:` 上那个三元是两回事，这个只有文字。
    final cond = _conditionalOf(e, outer);
    if (cond != null) {
      final want = resolveBool(cond.condition);
      if (want != null) {
        _noteModelValue();
        final branch = want ? cond.thenExpression : cond.elseExpression;
        // ⚠️ 只认字面量分支。分支里再套插值也去算它，但只能靠 resolveString。
        return resolveString(branch) ?? _stringLiteral(branch);
      }
    }

    // 光秃秃的字符串变量（`Text(_title)`，`_title` 是 `String _title = 'x';`）。
    return resolveString(e);
  }

  /// `_items[i]` → (`_items`, 0)；`_items[1 + 1]` → (`_items`, 2)。
  ///
  /// [index] 为 -1 表示"下标记不出来"，调用方会退回第一项
  /// （`_items[_rareFlag]` 这种，总比整段丢掉强，且不会谎报是第几项）。
  _IndexedBase? _indexedBase(Expression e) {
    if (e is! IndexExpression) return null;
    final nm = _identifierName(e.target);
    if (nm == null) return null;
    final idx = resolveNumber(e.index)?.toInt() ?? -1;
    return _IndexedBase(nm, idx);
  }

  /// 找"字符串三元"：`e` 本身是，或它是 `Text(...)` 且第一个位置参数是。
  ///
  /// [outer] 用来兜住 `label: Text(_big ? 'a' : 'b')` ——
  /// 那里拿到的 `e` 已经是 `Text(...)`，三元在它**里面**。
  ConditionalExpression? _conditionalOf(Expression e, Expression outer) {
    if (e is ConditionalExpression) return e;
    final inner = _asWidgetCall(e) ?? _asWidgetCall(_unwrapConst(e));
    if (inner != null && inner.name == 'Text') {
      final a = inner.firstArg;
      if (a is ConditionalExpression) return a;
    }
    // `label: _big ? Text('a') : Text('b')` —— 外面那层自己就是三元。
    if (outer is ConditionalExpression) return outer;
    return null;
  }

  /// `ListView` / `GridView` → 真的静态条目。
  ///
  /// ## 判断标准只有一条：**源码里有没有真数据**
  ///
  /// `list` 模板写的是：
  /// ```dart
  /// static const List<String> _items = [...12 条...];
  /// ListView.separated(
  ///   itemCount: _items.length,
  ///   itemBuilder: (context, i) => ListTile(title: Text(_items[i])),
  /// )
  /// ```
  /// 这里 `itemCount` 和解包出来的数据是**同一个 `_items`**，条数是算出来的
  /// 而不是编的 —— 摊成 12 条静态项是"更接近真相"，不是"编造"。
  ///
  /// 反过来，`itemCount: 3` 配 `Text('x')` 这种（测试里那个例子）里
  /// `'x'` 跟 `i` 毫无关系，复制三份就是在给用户编数据 —— 那种情况
  /// 宁可保持原样带回 + 一句解释。
  ///
  /// ## 返回值是三态，不是"成功/失败"
  ///
  /// 展开出的是**多个**兄弟节点，得 `_splice` 包起来才塞得进
  /// "返回一个节点"的协议。但**不能返回 null 表示成功** ——
  /// 上层会把 null 读成"不认识"，于是列表项被挂进占位节点的 `children`，
  /// 生成时 `raw` 整段覆盖子节点，最后那棵树就是
  /// "未识别框里装着 12 条列表项"的鬼东西（写这版时真踩到了）。
  ///
  /// - `>= 0`：成功，去 [_dynamicListNodes] 取
  /// - [_kListGiveUp]：别落占位节点
  /// - [_kListUnknown]：读不出来，落占位节点原样带回
  int _flattenDynamicList(
      String name, _WidgetCall call, int depth, Expression expr) {
    final builder = call.namedArgument('itemBuilder');
    if (builder == null) return _kListUnknown;
    // `GridView.builder` 也叫 itemBuilder，但它的布局是网格 ——
    // 摊成竖排条目会歪得离谱，只处理 ListView 一族。
    if (name != 'ListView') return _kListUnknown;

    // 1) 找到 itemBuilder 的索引参数名 + 它的返回 widget。
    final parts = _fnParts(builder);
    if (parts == null) return _kListUnknown;
    // ⚠️ **不能取第 0 个参数**。`itemBuilder` 的签名是
    // `(BuildContext context, int index)` —— 第 0 个是 context，
    // 索引在**第 1 个**。取错的话 `'${i + 1}'` 里那个 `i` 谁也认不出来，
    // 于是 `_mapListTileAt` 返回 null、整条列表退回"原样带回"
    // （插桩打了半天才发现，真机上是看不出来的）。
    final idxName = _indexParamName(parts.params);
    final ret = parts.body;

    // 2) 条目模板必须认识，而且得能重复生成 —— 认识不了就别碰。
    final template = _listItemTemplate(ret, idxName);
    if (template == null) return _kListUnknown;

    // 3) 条数：`itemCount: _items.length`（首选）或 `itemCount: 8`。
    //
    // `_items.length` 的判定不走 `_identifierName` —— 那个只吃
    // `SimpleIdentifier` / `PropertyAccess`（`this._items` 那种），
    // 而 `_items.length` 是 `PropertyAccess` 套 `SimpleIdentifier`，
    // 剥出来的是**列表名**。这里直接取 target 的源码当名字用。
    final countExpr = call.namedArgument('itemCount');
    int count;
    // ⚠️ `_items.length` 在 AST 里是 **`PrefixedIdentifier`**
    // （`a.b` 这种没有 target 的形态），**不是** `PropertyAccess`
    // （那是 `a.b.c` / `this.a.b`）。只认后者的话
    // `itemCount: _items.length` 会静默算成 0，整条列表退回"原样带回" ——
    // 功能看着像没做，其实是判定漏了一种节点类型（插桩才看出来）。
    final lenName = _lengthBaseName(countExpr);
    if (lenName != null) {
      count = localStringList(lenName)?.length ?? 0;
    } else {
      // 字面量条数（`itemCount: 8`）。
      count = resolveNumber(countExpr)?.toInt() ?? 0;
      // 或者直接就是一张表（少见，但 `itemCount: [...]` 也合法）。
      if (count == 0) count = resolveStringList(countExpr)?.length ?? 0;
    }
    // 条数上限：静态展开一张长列表会撑爆设计树，而且用户想看的
    // 是"长什么样"不是"到底几条"。超过就只铺前几条并说明。
    const cap = 12;
    var truncated = false;
    if (count > cap) {
      count = cap;
      truncated = true;
    }
    if (count <= 0) return _kListUnknown;

    _noteListItems(count);
    if (truncated) {
      _noteOnce('列表只铺了前 $cap 条 —— 静态展开整张长列表没意义，'
          '真实条数还是由你的代码决定');
    }

    // 4) 逐条生成。
    final sep = call.namedArgument('separatorBuilder');
    final out = <DesignNode>[];
    for (var i = 0; i < count; i++) {
      out.add(template(i));
      // 分割线是**编译期**按 `separatorBuilder` 的形状判断的，
      // 不指望它在预览里真跑起来（预览不跑业务逻辑）。只有朴素的
      // `Divider` 才替你铺 —— 特殊分隔（带文字的、空 24 的）铺错更糟。
      if (_isPlainDivider(sep) && i < count - 1) {
        out.add(DesignNode(type: DesignComponentType.divider));
      }
    }
    if (out.isEmpty) return _kListGiveUp;
    _dynamicListNodes
      ..clear()
      ..addAll(out);
    return _kListOK;
  }

  /// `separatorBuilder` 的详情（用它来判断"每两条之间有没有分割线"）。
  ///
  /// 只要它不是纯 `Divider` 就不铺分割线 —— 常见写法里它就是
  /// `Divider(height: 1)`，而**特殊的**分隔（带文字的、空 24 的）
  /// 铺错比不铺更糟。
  bool _isPlainDivider(Expression? sep) {
    if (sep == null) return false;
    final ret = _fnParts(sep)?.body;
    final c = _asWidgetCall(ret);
    return c != null && c.name == 'Divider';
  }

  /// `TabBarView(children: [...])` → 各标签页的节点。
  ///
  /// ## 判据是"展开出来的形状"，不是"源码长得像不像"
  ///
  /// 一开始这里比的是**去掉字符串字面量后的源码**（`_shapeOf`），
  /// 结果官方 `tabs` 模板的三个标签页被判成"各不相同"——
  /// 因为它们是
  /// `Center(child: Text('首页内容'))` /
  /// `Center(child: Text('收藏内容'))` /
  /// `Center(child: Text('设置内容'))`，
  /// 抹掉字符串以后仍然**只差一个字符串**，源码形态当然各不相同。
  /// 那条判据把"文案不同"错当成了"结构不同"。
  ///
  /// 真正要回答的是：**"这三个标签页在设计器里会不会长得不一样"**。
  /// 所以改成把三个都真的展开一遍（[_probe]，不留痕迹），
  /// 再比展开结果的结构签名（[_shapeOf]）。文案差异在节点树里
  /// 本来就只是 `props['text']` 的值，签名一视同仁地抹掉 ——
  /// 于是三个 `Center(Text)` 判为同形，而
  /// "登录表单 / 设置列表 / 关于页"这种判为不同形。
  ///
  /// 不同形时返回 null —— 替用户挑一个会丢掉另外两个，
  /// 那是比"未识别"更糟的结果。
  List<DesignNode>? _tabsOf(Expression? kids) {
    if (kids is! ListLiteral || kids.elements.isEmpty) return null;
    final exprs = <Expression>[];
    for (final e in kids.elements) {
      if (e is! Expression) return null;
      exprs.add(e);
    }

    // 逐个试展开：只取"每个标签页各自会铺出什么"这个结论。
    final perTab = <List<DesignNode>>[];
    for (final e in exprs) {
      perTab.add(_probe(() => buildChildren(e, depth: 1)));
    }

    // 空标签页 = 没东西可铺，按"不一致"处理（不替用户决定）。
    if (perTab.any((l) => l.isEmpty)) return null;

    final sig0 = _shapeOf(perTab.first);
    for (final l in perTab.skip(1)) {
      if (_shapeOf(l) != sig0) return null;
    }

    // 判据通过 —— 正式展开一遍（这次才留下 converted / 提醒）。
    final out = <DesignNode>[];
    for (final e in exprs) {
      out.addAll(buildChildren(e, depth: 1));
    }
    return out.isEmpty ? null : out;
  }

  /// 节点树的**结构签名**：类型 + 属性**键**，不计属性**值**，也不计子节点顺序。
  ///
  /// 为什么这么设计：
  /// - 抹掉属性值 —— `Text('首页内容')` 与 `Text('设置内容')` 结构相同，
  ///   只是文案不同；文案差异不该让整段被退回去。
  /// - 子节点顺序**计进去** —— 同样的两个控件换个前后就是不同的界面。
  /// - 用 `raw` 的**长度**而不是内容 —— 两个占位节点长得一样就行，
  ///   内容一样说明它们本来就是同一段源码被复制了两遍（那更该铺）。
  String _shapeOf(List<DesignNode> nodes) {
    final buf = StringBuffer();
    for (final n in nodes) {
      buf
        ..write(n.type.name)
        ..write('[');
      final keys = n.props.keys.toList()..sort();
      for (final k in keys) {
        if (k == 'raw') {
          buf.write('raw*');
          continue;
        }
        buf
          ..write(k)
          ..write(',');
      }
      buf.write(']{');
      buf.write(_shapeOf(n.children));
      buf.write('}');
    }
    return buf.toString();
  }

  /// 把一个闭包体拆成「参数名表」+「返回的表达式」。
  ///
  /// `itemBuilder` / `separatorBuilder` / `builder` 这些回调的写法都一样：
  /// `(context, i) => ListTile(...)` 或 `(context, i) { return ListTile(...); }`。
  /// 早先这段拆解在 [_flattenDynamicList] 和 [_isPlainDivider] 里各写了一遍，
  /// 现在还要给 [AnimatedContainer] 用，所以抽出来。
  ///
  /// 返回 null 表示拆不出表达式（参数表为空、或者函数体里根本没 return）。
  ({List<String> params, Expression body})? _fnParts(Expression? e) {
    if (e is! FunctionExpression) return null;
    final names = <String>[];
    for (final p in e.parameters?.parameters ?? const <FormalParameter>[]) {
      final n = p.name?.lexeme;
      if (n != null) names.add(n);
    }
    final b = e.body;
    Expression? ret;
    if (b is ExpressionFunctionBody) {
      ret = b.expression;
    } else if (b is BlockFunctionBody) {
      ret = _returnedExpression(b.block);
    }
    if (ret == null) return null;
    return (params: names, body: ret);
  }

  /// `_items.length` / `this._items.length` → `_items`。
  ///
  /// 两种 AST 形态都要认：
  /// - `_items.length` → [PrefixedIdentifier]（`prefix` 是 `_items`）
  /// - `this._items.length` → [PropertyAccess]（`target` 是 `this._items`）
  ///
  /// 不是"取长度"就返回 null。
  String? _lengthBaseName(Expression? e) {
    if (e is PrefixedIdentifier && e.identifier.name == 'length') {
      return e.prefix.name;
    }
    if (e is PropertyAccess && e.propertyName.name == 'length') {
      final t = e.target;
      if (t is PrefixedIdentifier) return t.identifier.name;
      if (t is SimpleIdentifier) return t.name;
    }
    return null;
  }

  /// 从回调的形参名表里挑出"索引"那个的名字。
  ///
  /// 规则：**跳过 `BuildContext`**，取剩下的第一个。
  /// 常见三种写法：
  /// - `(context, i)` → `i`
  /// - `(_, i)` → `i`（下划线是合法的 Dart 标识符，但认不出来也没关系）
  /// - `(ctx, index)` → `index`
  ///
  /// 只有**一个**参数时（`(i)` —— 语法上不合法，但用户可能正在写）
  /// 就用它。挑不出名字就退回 `i`，不影响下面的模板匹配。
  ///
  /// ⚠️ 参数直接从 [_fnParts] 要名字表，不要在这里再解一遍
  /// `FunctionExpression` —— 那个 parse 只在 `_fnParts` 里有一份。
  String _indexParamName(List<String> named) {
    if (named.isEmpty) return 'i';
    if (named.length == 1) return named.first;

    // ⚠️ **不能靠"类型名是不是 BuildContext"来挑**。
    // `RegularFormalParameterImpl.toSource()` 打印出来的是
    // `BuildContext context`，但一旦类型解析没跑（我们就是不跑的），
    // 打印结果会退化成**光秃秃的参数名** `context` —— 于是那个判断
    // 永远不成立，索引名被错认成 `context`，`'${i + 1}'` 里的 `i`
    // 谁也认不出来（这个坑插了四轮桩才定位到）。
    //
    // 换个不依赖类型的判据：`itemBuilder` 的签名是
    // `(BuildContext context, int index)` —— **索引永远是最后一个参数**。
    // 这条规律比类型名稳，因为它来自 Flutter 的 API 形状本身。
    return named.last;
  }

  /// 把条目模板编成一个"第 i 条 → 节点"的函数。
  /// 认不出来返回 null（调用方退回"原样保留"）。
  DesignNode Function(int)? _listItemTemplate(Expression ret, String idxName) {
    final call = _asWidgetCall(ret);
    if (call == null) return null;
    if (call.name != 'ListTile') return null;
    // 先用第 0 条试一次：试不过就别展开（"先铺了再回滚"会留下半棵树）。
    final probe = _mapListTileAt(call, idxName, 0);
    if (probe == null) return null;
    return (int i) => _mapListTileAt(call, idxName, i) ?? probe;
  }

  /// 生成第 [i] 条的 `ListTile` 节点。
  ///
  /// [idxName] 是 itemBuilder 的索引参数名（`i`）；模板里
  /// `'${i + 1}'` 的洞按它算出 `i + 1` 的真实值。
  DesignNode? _mapListTileAt(_WidgetCall call, String idxName, int i) {
    String? at(Expression? e) => _textAt(e, idxName, i);
    final title = at(call.namedArgument('title'));
    if (title == null) return null;
    return DesignNode(
      type: DesignComponentType.listTile,
      props: <String, Object?>{
        'title': title,
        'subtitle': at(call.namedArgument('subtitle')) ?? '',
        'leadingIcon': _iconNameOf(call.namedArgument('leading')) ?? 'circle',
      },
    );
  }

  /// 第 [i] 条的文案：插值里的索引参数按 [i] 求值。
  String? _textAt(Expression? e, String idxName, int i) {
    if (e == null) return null;
    final lit = _stringLiteral(e);
    if (lit != null) return lit;

    final inner = _asWidgetCall(e) ?? _asWidgetCall(_unwrapConst(e));
    final target = (inner != null && inner.name == 'Text') ? inner.firstArg : e;
    if (target == null) return null;

    // `Text(_items[i])` → 第 i 项（真的那个字符串）。
    final indexed = _indexedBase(target);
    if (indexed != null) {
      final list = localStringList(indexed.name);
      if (list != null && list.isNotEmpty) {
        return list[i.clamp(0, list.length - 1)];
      }
    }

    if (target is StringInterpolation) {
      final buf = StringBuffer();
      for (final el in target.elements) {
        if (el is InterpolationString) {
          buf.write(el.value);
        } else if (el is InterpolationExpression) {
          // 洞里的式子优先按"索引参数"求值（`${i + 1}` → 1,2,3…），
          // 求不到再退回通用的 resolveHole。
          final hole = _holeAt(el.expression, idxName, i);
          // 读不出来就**整条**放弃（同 [_textOf]）——
          // 半截文案 + 一个问号会真的写进用户的界面。
          if (hole == null) return null;
          buf.write(hole);
        } else {
          return null;
        }
      }
      return buf.toString();
    }
    return resolveString(target);
  }

  String? _holeAt(Expression e, String idxName, int i) {
    final nm = _identifierName(e);
    if (nm == idxName) return '$i';
    if (e is BinaryExpression) {
      final left = _identifierName(e.leftOperand);
      final right = resolveNumber(e.rightOperand);
      if (left == idxName && right != null) {
        if (e.operator.lexeme == '+') return _fmtNum(i + right);
        if (e.operator.lexeme == '-') return _fmtNum(i - right);
      }
    }
    return resolveHole(e, index: idxName);
  }

  List<DesignNode> _childrenOf(_WidgetCall call, int depth) {
    final kids = call.childrenArgument;
    if (kids != null) return _elementsOf(kids, depth);
    final single = call.childArgument;
    if (single != null) return buildChildren(single, depth: depth + 1);
    return <DesignNode>[];
  }

  /// `children: [...]` 里的元素 → 若干节点。
  ///
  /// ⚠️ `ListLiteral.elements` 的元素类型是 `CollectionElement`
  /// 而不是 `Expression` —— 里面可能是 `if (...)`（`IfElement`）、
  /// `for (...)`（`ForElement`）、展开 `...list`（`SpreadElement`）。
  /// 只有 `Expression` 才可能是 widget 构造。`if` / `for` 生成的是
  /// **运行时**列表，静态展不开。
  ///
  /// 处置：整段原样带走（不想静默丢掉用户写的东西），并在 `notes` 里说明。
  /// 切片走的是字符下标（[sliceSource] 接 `AstNode`），
  /// `CollectionElement` 也是 `AstNode`，所以不用先转成 `Expression`。
  List<DesignNode> _elementsOf(Expression listExpr, int depth) {
    if (listExpr is! ListLiteral) return <DesignNode>[_unknown(listExpr)];
    final out = <DesignNode>[];
    var hasCollectionElement = false;
    for (final e in listExpr.elements) {
      if (e is Expression) {
        out.addAll(buildChildren(e, depth: depth + 1));
      } else if (e is IfElement) {
        // ⚠️ Dart 里 `[ // 只有注释 ]` 会被解析成一个**空的 collection-if**
        // （`if` 后面什么都没匹配上）。那不是用户写的条件渲染 —— 是**注释**。
        // 当占位带走的话，生成的代码里会冒出半句语法不完整的 `if ()`，
        // 直接编译不过。所以这两种情况要分开：
        //
        // - 空的 `if`（没有 condition / then）→ 其实是注释，取注释文本
        // - 真的 `if (cond) widget` → 整段带走，提示用户展不开
        hasCollectionElement = true;
        final commentText = _commentOnlySlice(listExpr);
        if (_isRealIf(e)) {
          _noteOnce('children 里的 if 条件渲染已整段保留 —— '
              '设计器没法静态展开它，生成时原样带回');
          out.add(_unknownNode(e));
        } else if (commentText.isNotEmpty) {
          out.add(_unknownText(commentText, '注释'));
        }
      } else {
        hasCollectionElement = true;
        _noteOnce('children 里的 if/for/展开写法已整段保留 —— '
            '设计器没法静态展开它，生成时原样带回');
        out.add(_unknownNode(e));
      }
    }
    // ⚠️ 收尾这一下**不能**用 `out.isEmpty` 判断该不该补注释 ——
    // `[Text('x'), if (c) Text('y')]` 这种"有表达式 + 有条件"的常见写法
    // 里 out 不为空，但排在 `if` **前面**那句注释照样会被吃掉。
    // 判断条件要和 `_commentOnlySlice` 本身挂钩，而不是看产出多少。
    //
    // 另外只有在**真的有** `if`/`for`/`...` 元素时才走这条 ——
    // `[Text('x')]` 里 out 不为空，`_commentOnlySlice` 也会返回
    // 注释（`Text('x'), // 说明`），那就重复带走了。
    if (hasCollectionElement) {
      final tail = _commentOnlySlice(listExpr);
      if (tail.isNotEmpty) out.add(_unknownText(tail, '注释'));
    }
    return out;
  }

  /// 这是用户真写的 `if (cond) widget`，还是"只有注释"造成的空 if？
  ///
  /// 判别：`then` 分支的源码切片里有没有实质内容。
  /// 空的 collection-if 的 then 是个空壳（分析器凑出来的），
  /// 真写过的至少有 `Text(...)` 那么多字符。
  ///
  /// ⚠️ `thenElement` 在 analyzer 14 里**非空**（`CollectionElement`），
  /// 所以不能写 `t == null` 判断 —— 编译期就会报"这个条件恒为 false"。
  bool _isRealIf(IfElement e) =>
      sliceSource(source, e.thenElement).trim().isNotEmpty;

  /// 列表字面量里"只有注释"的那部分内容（没有注释就返回空串）。
  ///
  /// ## 为什么必须单独做这件事
  ///
  /// **AST 不含注释。** `ListLiteral.elements` 只包含真正的表达式，
  /// `Column(children: [\n  // 待补：这里放图表\n])` 的 elements 是**空的**，
  /// 注释在 AST 里查不到 —— 只能回头去切源码。
  ///
  /// 不补这一下的话，用户写在 children 里的注释会被**静默吃掉**。
  /// 这类丢失最恶劣：用户不会立刻发现，等他一个月后回头看重构过的代码，
  /// 那些"为什么这么写"的记录已经没了。
  String _commentOnlySlice(ListLiteral list) {
    final ls = list.leftBracket;
    final rs = list.rightBracket;
    if (rs.offset <= ls.end) return '';
    final inner = source.substring(
      ls.end.clamp(0, source.length),
      rs.offset.clamp(0, source.length),
    );
    // 去空白后必须以注释开头才算"只有注释"——
    // 混着表达式的列表已经由 elements 处理过了，不能重复带走。
    final trimmed = inner.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.startsWith('//') && !trimmed.startsWith('/*')) return '';
    return inner.trim();
  }

  DesignNode _unknownText(String raw, String label) {
    return DesignNode(
      type: DesignComponentType.unknown,
      props: <String, Object?>{'raw': raw, 'sourceName': label},
    );
  }

  DesignNode _unknown(Expression expr) {
    unknown++;
    // 用带注释的切片 —— 用户写在组件上下的注释也是他写的东西，
    // 丢掉的话一个月后他回头看重构结果，会奇怪"我当时的备注哪去了"。
    //
    // ⚠️ 建的是「带源码的占位节点」，所以 `sourceName` 走 [_shortLabel]
    // 兜底：sourceName 不是 Widget 名的时候（`_big ? ... : ...`），
    // 一个 24 字以内的表达式摘要比一个空字符串有用得多 ——
    // 树上那一行起码能让人认出"哦，是我那个三元"。
    final src = sliceSourceWithComments(source, expr);
    final name = _asWidgetCall(expr)?.name;
    return DesignNode(
      type: DesignComponentType.unknown,
      props: <String, Object?>{
        'raw': src,
        'sourceName': name ?? _shortLabel(expr),
        // 尺寸走 `box` 之后这里就没用了，但**留着**：属性表里
        // `unknown` 仍有 `width` / `height` 两个字段（历史数据、
        // 手工加的占位节点都用它们），删掉会让老设计文件读不出来。
        'width': 0.0,
        'height': 0.0,
      },
      // 内部结构也导进来：用户能在树上看到它肚子里有什么
      // （生成时用 raw 整段覆盖，子节点不影响输出）。
      children: _innerChildren(expr),
    );
  }

  double? _sizeOf(Expression? e) {
    if (e == null) return null;
    final lit = resolveNumber(e);
    if (lit != null) return lit;
    if (e is ConditionalExpression) {
      final want = resolveBool(e.condition);
      if (want != null) {
        _noteModelValue();
        return resolveNumber(want ? e.thenExpression : e.elseExpression);
      }
      // 条件读不出来：两个分支都算一遍，**一样才敢用**
      // （`_big ? 200 : 200` 这种没有歧义；不一样就宁可不要）。
      final a = resolveNumber(e.thenExpression);
      final b = resolveNumber(e.elseExpression);
      if (a != null && a == b) return a;
    }
    return null;
  }

  // ------------------------------ AnimatedContainer ------------------------------

  /// `AnimatedContainer(...)` → 一个真正画得出来的 `box` 节点。
  ///
  /// ## 为什么落成 `box` 而不是 `unknown`（alpha.74 的第二版）
  ///
  /// 第一版落的是 `unknown` + `raw`：预览里画一条"未识别：AnimatedContainer"
  /// 的黄条，但按真实尺寸框着。**生成是完美的**（`raw` 整段写回），
  /// 可用户打开设计页看到的还是一条黄条 —— 他说的"强行适配一下"指的
  /// 显然不是这个。一个 100×100 的绿方块至少能让他看出"哦，那块绿的"。
  ///
  /// ## 生成的代码会**变**
  ///
  /// 这是这次改动唯一真正需要用户知情的代价：以前是
  /// `AnimatedContainer(...)` 原样写回（动画在真机上照旧跑），
  /// 现在生成的是 `Container(width: 100, height: 100, ...)` +
  /// 注释说明。**动画没了** —— 动画属于 `AnimatedContainer` 这个类型本身，
  /// 而设计器的 `box` 生成 `Container`。要保住动画只有两条路：
  /// 落 `unknown`（用户看不懂），或者给 `box` 加"动画开关"（
  /// 那是设计器要长出一个新概念，超出这次的范围）。
  ///
  /// 所以这里**必须**把这句话写进 `notes`：设计器里是静态方块，
  /// 生成后也是静态容器，想要动画得把它改回 `AnimatedContainer`。
  /// 说清楚了，用户就能自己做决定；不说清楚，他会在某次出包后
  /// 才发现"我的动画什么时候没的"。
  ///
  /// 返回 `null` 表示"连尺寸都没读到" —— 调用方会 `break` 出去走
  /// 通用的 [_unknown]（那种情况整段原样带回才是对的）。一个只有
  /// 生成器看得懂的灰色占位块，比一个尺寸瞎猜的方块好。
  DesignNode? _animatedBox(_WidgetCall call) {
    final w = _sizeOf(call.namedArgument('width'));
    final h = _sizeOf(call.namedArgument('height'));
    if (w == null && h == null) return null;

    final radius = _cornerRadius(call);
    final color = _decorationColorSlot(call);
    if (color != null) _noteColorApprox();
    _noteAnimatedContainer(w, h, radius, color);

    // 子节点（`child: const Icon(Icons.flutter_dash, size: 40)`）照常展开 ——
    // 它在 `AnimatedContainer` 里怎么显示，在 `Container` 里就怎么显示。
    final child = call.namedArgument('child');
    return DesignNode(
      type: DesignComponentType.box,
      props: <String, Object?>{
        'width': w ?? 0.0,
        'height': h ?? 0.0,
        'radius': radius ?? 0.0,
        'color': color ?? 'none',
      },
      children:
          child == null ? const <DesignNode>[] : buildChildren(child, depth: 1),
    );
  }

  /// `borderRadius: BorderRadius.circular(_big ? 32 : 8)` → 圆角半径。
  double? _cornerRadius(_WidgetCall call) {
    final deco = _asWidgetCall(call.namedArgument('decoration'));
    if (deco == null) return null;
    final br = _asWidgetCall(deco.namedArgument('borderRadius'));
    if (br == null) return null;
    // `BorderRadius.circular(r)`（具名构造）或 `BorderRadius.all(Radius.circular(r))`
    final r = br.namedArgument('radius') ??
        br.firstArg ??
        _asWidgetCall(br.firstArg)?.firstArg;
    return _sizeOf(r);
  }

  /// `decoration: BoxDecoration(color: _big ? Color(0xFF3DDC84) : Colors.deepOrangeAccent)`
  /// → 最接近的**语义色位**（设计器只有 9 个，见 [kColorSlots]）。
  ///
  /// 只认一小撮常见常量。认不出来返回 null（色位留 `none`）——
  /// 瞎猜一个色位会让用户得到一个"自己没要求过的颜色"，比没有颜色更糟。
  String? _decorationColorSlot(_WidgetCall call) {
    final deco = _asWidgetCall(call.namedArgument('decoration'));
    if (deco == null) return null;
    final c = deco.namedArgument('color');
    if (c == null) return null;
    // 三元：取条件初值那一支（和尺寸同一个口径）。
    var e = c;
    if (e is ConditionalExpression) {
      final want = resolveBool(e.condition);
      if (want == null) return null;
      e = want ? e.thenExpression : e.elseExpression;
    }
    final src = e.toSource().trim();
    // `Colors.deepOrangeAccent` / `Colors.red` → 色名。
    final m = RegExp(r'^Colors\.([A-Za-z]+?)(Accent)?$').firstMatch(src);
    if (m == null) return null;
    return _kColorNameToSlot[m.group(1)!];
  }

  /// 常见 `Colors.xxx` → 语义色位。
  ///
  /// 故意**不全**：只放"几乎不可能放错"的那几个。`Colors.green` 到底
  /// 该算 `secondary` 还是"没有对应"？这种模糊的判断交给用户更好 ——
  /// 认不出来时色位留空，属性面板里他自己选一个。
  static const Map<String, String> _kColorNameToSlot = <String, String>{
    'red': 'error',
    'pink': 'error',
    'deepOrange': 'error',
    'orange': 'error',
    'green': 'primary',
    'teal': 'primary',
    'blue': 'primary',
    'indigo': 'primary',
    'purple': 'secondary',
    'deepPurple': 'secondary',
    'grey': 'outline',
    'blueGrey': 'outline',
    'black': 'onSurface',
    'white': 'surface',
  };

  /// 颜色被折算成语义色位时的**一次性**说明。
  ///
  /// 和 [_noteModelValue] 分开发：那句讲的是"数值按初值取"，这句讲的是
  /// "颜色被换了"。合成一句用户会分不清哪句在说哪件事。
  void _noteColorApprox() {
    _noteOnce('颜色已折算成最接近的主题色位 —— 设计器只存语义色'
        '（保证深/浅主题下都可读），任意 RGB 存不下。'
        '生成时用的是色位对应的主题色，不是你原来那个具体色值');
  }

  /// 把 `AnimatedContainer` 摊平时**确实会不一样**的地方，逐条说清楚。
  ///
  /// 这段文案是这次改动的**核心交付点**：用户看到的预览是个静态方块，
  /// 他必须立刻知道"哪里和代码不一样"，否则回头发现"我明明写了动画"
  /// 就会以为是导入器吃掉了。每一处丢失都在这里点名。
  void _noteAnimatedContainer(
      double? w, double? h, double? radius, String? color) {
    final size = (w != null && h != null)
        ? ' ${_fmtNum(w)}×${_fmtNum(h)}'
        : (w != null ? ' 宽 ${_fmtNum(w)}' : ' 高 ${_fmtNum(h!)}');
    final r = radius == null ? '' : '，圆角 ${_fmtNum(radius)}';
    _noteOnce('动画容器（AnimatedContainer）已按源码初值画成静态方块$size$r。'
        '两点变化要知道：①动画和切换后的尺寸/颜色在设计器里不体现；'
        '②生成的是普通 Container，想要动画得自己把它改回 AnimatedContainer');
  }

  /// 同上，但接任意 `AstNode`（`children:` 里的 `if` / `for` 元素不是
  /// `Expression`，没法走 [_unknown]）。
  DesignNode _unknownNode(AstNode node) {
    unknown++;
    return DesignNode(
      type: DesignComponentType.unknown,
      props: <String, Object?>{
        'raw': sliceSourceWithComments(source, node),
        'sourceName': '条件/循环片段',
      },
    );
  }

  /// 占位节点内部的结构（尽力而为，失败就空）。
  ///
  /// 找子节点的顺序：`children:` → `child:` → **遍历所有参数找第一个
  /// 列表/构造参数**。最后那一档是给 `BlocBuilder(builder: (c, s) => ...)`
  /// 这类写的 —— 子界面藏在 `builder` 回调里，不通用地找一遍，
  /// 用户在树上看到的就是一个完全展不开的黑盒。
  ///
  /// 找不到也不可惜：`raw` 已经把整段源码带走了，生成时不会丢东西。
  /// 这只是为了**预览时能多看到一点**。
  List<DesignNode> _innerChildren(Expression expr) {
    final call = _asWidgetCall(expr);
    if (call == null) return <DesignNode>[];
    final kids = call.childrenArgument ?? call.childArgument;
    if (kids != null) {
      if (kids is ListLiteral) return _elementsOf(kids, 0);
      return buildChildren(kids);
    }
    // 兜底：扫一遍所有参数，找第一个能解析出 widget 的。
    for (final a in call._args) {
      final v = a.argumentExpression;
      // ⚠️ 跳过「参数值类型」。这些构造调用**长得像 widget**（有名字、
      // 有括号、参数还能嵌套），但它们的产物是**属性值**，不是子组件。
      //
      // 真机实测（alpha.77）：`Icon(Icons.check_circle, color: Color(0xFF10B981))`
      // 没有 child/children，于是扫到 `color:` 的值 `Color(...)`，
      // `_asWidgetCall` 认了 → **颜色被当成图标的子节点**塞进树，
      // 预览里在图标下面渲染出一个色块。同理 `Container(decoration:
      // BoxDecoration(color: ...))` 会把 BoxDecoration 当孩子。
      if (_isValueTypeCall(v)) continue;
      final found = _firstWidgetIn(v);
      if (found != null) return found;
    }
    return <DesignNode>[];
  }

  /// 这个表达式是不是「属性值构造」（`Color(...)` / `BoxDecoration(...)` …）。
  ///
  /// 判定只看最外层的构造名 —— 它们没有一个是 `Widget` 的子类，
  /// 出现在树里一定是被误收的。
  bool _isValueTypeCall(Expression? e) {
    if (e == null) return false;
    final un = _unwrapConst(e);
    final c = _asWidgetCall(un);
    if (c == null) return false;
    return kNonWidgetTypeNames.contains(c.name);
  }

  /// 在一个表达式里找第一个 widget 构造（含闭包体里的）。
  ///
  /// 只找**第一个**：占位节点的 children 是"给用户看一眼结构"用的，
  /// 多找几个的收益很小，而写全（处理所有 `if`/`for`/嵌套闭包）
  /// 的成本很高、还容易引入无限递归。
  List<DesignNode>? _firstWidgetIn(Expression e) {
    // 闭包：`(context, snapshot) => Column(...)` 或 `{ return Column(...); }`
    if (e is FunctionExpression) {
      final body = e.body;
      if (body is ExpressionFunctionBody) {
        return _firstWidgetIn(body.expression);
      }
      if (body is BlockFunctionBody) {
        for (final s in body.block.statements) {
          if (s is ReturnStatement && s.expression != null) {
            return _firstWidgetIn(s.expression!);
          }
        }
      }
      return null;
    }
    final c = _asWidgetCall(e);
    if (c == null) return null;
    return buildChildren(e);
  }

  void _noteOnce(String msg) {
    // 试展开（[_probe]）期间不落提醒 —— 那一版的节点结论可能被丢掉，
    // 配套的提醒留着就成了"解释一件没发生的事"。
    if (_probing) return;
    if (!notes.contains(msg)) notes.add(msg);
  }

  /// 展开 [expr] 但不留任何痕迹（不写 [notes]、不改 [converted] / [unknown]，
  /// 也不碰 [_dynamicListNodes] 这种共享缓冲）。
  ///
  /// 只用来回答"这段展开出来是什么形状"。
  T _probe<T>(T Function() body) {
    final savedNotes = List<String>.from(notes);
    final savedConverted = converted;
    final savedUnknown = unknown;
    final savedLists = List<DesignNode>.from(_dynamicListNodes);
    final savedProbing = _probing;
    _probing = true;
    try {
      return body();
    } finally {
      _probing = savedProbing;
      notes
        ..clear()
        ..addAll(savedNotes);
      converted = savedConverted;
      unknown = savedUnknown;
      _dynamicListNodes
        ..clear()
        ..addAll(savedLists);
    }
  }
}

/// `_items[i]` 拆开后的样子：[name] 是列表名，[index] 是下标。
///
/// [index] 为 -1 = "下标记不出来"（`_items[_flag]` 这种）——
/// 调用方退回第一项，并且**不能说这是第几项**。
class _IndexedBase {
  final String name;
  final int index;

  const _IndexedBase(this.name, this.index);
}

/// 透明的布局修饰 widget：只把它们里面的东西提上来，自己不留节点。
///
/// `Expanded` 在这里面 —— 它在 `Column` 里是"占满剩余空间"，
/// 而设计器的 `Column` 是 `mainAxisSize: MainAxisSize.min`，
/// 本来就不分配剩余空间，`Expanded` 没有可映射的语义。
const Set<String> _kPassThrough = <String>{
  'Padding',
  'Center',
  'Align',
  'SafeArea',
  'SingleChildScrollView',
  'Expanded',
  'Flexible',
  'ConstrainedBox',
  'Material',
  'InkWell',
  'GestureDetector',
  'Semantics',
  // Hero 只加一个"转场标签"，不改变布局也不产生视觉元素 ——
  // 丢掉 tag 的同时把 child 提上来，是这里能做的最诚实的处理
  // （设计器不做转场动画，留一个 Hero 节点也没有可编辑的属性）。
  'Hero',
};

// ==================== 调用点抽象（两类构造） ====================

/// 对一个 widget 构造调用的统一视图。
///
/// ## 为什么要这层抽象（alpha.71 踩过的坑）
///
/// Dart AST 里 **`Text('x')` 和 `const Text('x')` 是两种节点**：
/// - 无前缀的裸名构造 `Text('x')` → `MethodInvocation`（`target == null`）
/// - 带 `const` 的 `const Text('x')` → `InstanceCreationExpression`
/// - 带前缀的 `widgets.Text('x')` → `MethodInvocation`（`target` 非空）
///
/// 只处理其中一种的话，另一种 widget 会**静默变成 unknown**
/// —— 不难看出问题，但很难看出**为什么**只有一半的组件进了树。
/// 这层抽象把分派收敛到一处，两种情况的所有调用点都走同一条路。
/// 解析到的一个自定义类的 build：返回表达式 + **真正持有它的类名**。
///
/// `owner` 不能省成调用方手里的 `name`：StatefulWidget 的 build 写在
/// `_XxxState` 里，两者的私有方法集合完全不同。见 [_ImportCtx._localBuildExpr]。
class _LocalBuild {
  const _LocalBuild(this.owner, this.body);

  /// 真正持有这个 build 的类名（`_FOAIDEHomePageState`）。
  final String owner;

  /// build 的返回表达式。
  final Expression body;
}

/// 解析到的一个本类私有方法：方法体 + 调用点的实参绑定。
///
/// 两个字段必须一起传下去 —— 只给方法体会丢掉 `title` 这类形参的值
/// （落成未识别），只给绑定无从展开。所以不做成两个独立的返回值。
class _LocalMethod {
  const _LocalMethod(this.body, this.bindings);

  /// 方法的返回表达式（`Widget _x() => ...` 的那段 `...`）。
  final Expression body;

  /// 形参名 → 调用点实参。见 [_ImportCtx._bindParams]。
  final Map<String, Expression> bindings;
}

class _WidgetCall {
  _WidgetCall(this.name, this._args, [this._expr]);

  /// 构造名（`Text` / `FilledButton` / ...）。
  final String name;

  /// 这个调用**本身的表达式**（`AnimatedContainer(...)` 那一整段）。
  ///
  /// 用来切源码（`sliceSourceWithComments`）—— 只有参数列表是切不出
  /// 完整构造调用的。`_asWidgetCall` 从哪来的表达式就填哪一个。
  final Expression? _expr;

  /// [_expr] 的公开读法，带中文名字方便调用点读起来顺。
  Expression? get expr => _expr;

  /// 位置参数 + 命名参数，按源码顺序。
  ///
  /// ⚠️ analyzer 14 里 `argumentList.arguments` 的元素类型是 `Argument`
  /// （不是 `Expression`）—— 命名参数是 [NamedArgument]，位置参数是
  /// `ArgumentImpl`。取表达式一律走 `.argumentExpression`。
  final List<Argument> _args;

  /// 第 i 个位置参数（不含命名参数）。
  Expression? get firstArg {
    for (final a in _args) {
      if (a is! NamedArgument) return a.argumentExpression;
    }
    return null;
  }

  /// 取命名参数 `name:` 的值。
  Expression? namedArgument(String name) {
    for (final a in _args) {
      if (a is NamedArgument && a.name.lexeme == name) {
        return a.argumentExpression;
      }
    }
    return null;
  }

  /// 取 `child:`（单个子节点）。
  Expression? get childArgument => namedArgument('child');

  /// 取 `children:` 的值（通常是 `ListLiteral`；调用点自己判类型）。
  Expression? get childrenArgument => namedArgument('children');
}

/// 把一个表达式识别成 widget 构造调用。
_WidgetCall? _asWidgetCall(Expression? expr) {
  if (expr == null) return null;

  // `const X(...)`，或 `X(...)` 出现在常量上下文里被推断为 const 时。
  if (expr is InstanceCreationExpression) {
    return _WidgetCall(
      expr.constructorName.type.name.lexeme,
      expr.argumentList.arguments.toList(),
    );
  }

  if (expr is MethodInvocation) {
    // 裸名构造 `Text('x')` —— target 为 null 的方法调用。
    if (expr.target == null) {
      return _WidgetCall(
        expr.methodName.name,
        expr.argumentList.arguments.toList(),
        expr,
      );
    }
    // 具名构造 `Image.asset('a.png')`：target 是类型名而不是实例。
    //
    // ⚠️ 语法解析分不清 `Image.asset(...)`（具名构造）和
    // `someVar.method(...)`（普通方法调用）—— 那需要类型解析。
    // 白名单是在**语法层**能做的最好近似：只对已知类型名展开。
    // `Icons.star` 这种取值不会被误判（它不带参数列表）。
    if (expr.target is SimpleIdentifier) {
      final t = (expr.target! as SimpleIdentifier).name;
      if (_kKnownTypes.contains(t)) {
        return _WidgetCall(
          t,
          expr.argumentList.arguments.toList(),
          expr,
        );
      }
    }
  }

  return null;
}

/// 已知的、会用"点号具名构造"的 widget 类型。
///
/// `ListView` / `GridView` 进来不是为了能被导入（它们导不了 —— 条目是
/// 运行时生成的），而是为了能**给出一句解释**：`ListView.separated` 不
/// 在这张表里时它连构造调用都不算，用户只会看到一个没有上下文的
/// 「未识别」；进了表才能落到 `_mapKnown` 的 `ListView` 分支，把
/// "为什么原样带回"说清楚。
const Set<String> _kKnownTypes = <String>{
  'Image',
  'ListView',
  'GridView',
  // 三个按钮的 `.icon` 具名构造（`FilledButton.icon(...)`）——
  // 它们是最常见的一类"带图标按钮"，落在白名单外时连构造调用都不算，
  // 于是整颗按钮变成一个「未识别」。
  'ElevatedButton',
  'FilledButton',
  'OutlinedButton',
  'TextButton',
  // alpha.73：设计器现在有 `fab` 外壳类型了，悬浮按钮能真的落成组件
  // （`.small(...)` / `.large(...)` 这些具名构造也一并认）。
  'FloatingActionButton',
  // `TabBarView(children: [...])` —— 认了才可能给出"内容按标签铺开了"
  // 那句说明，否则用户看到的只是个没有上下文的「未识别」。
  'TabBarView',
};

// 「参数值类型」黑名单已上移到 design_model.dart 的 kNonWidgetTypeNames
// （UnknownVisual._extractScope 也要用，放 model 层两边共用）。

String? _shortLabel(Expression expr) {
  final src = expr.toSource().replaceAll(RegExp(r'\s+'), ' ').trim();
  return src.length <= 24 ? src : '${src.substring(0, 24)}…';
}

/// 一个表达式是不是"光秃秃一个名字"（`_count` / `this._big` / `i`）。
///
/// 分四种节点是因为**语法**上它们确实不同，而语义上都是"读一个标识符"：
/// - `_items[i]` 里的 `_items` → [SimpleIdentifier]
/// - `this._big` 里的 `_big` → [PropertyAccess]
/// - `widget.x` 同理
///
/// 返回最后一个点号后面的名字。其余（方法调用、字面量、二元表达式）返回 null
/// —— 那些不是"一个可以顺着字段声明翻出来的名字"。
String? _identifierName(Expression? e) {
  if (e is SimpleIdentifier) return e.name;
  if (e is PropertyAccess) return e.propertyName.name;
  if (e is PrefixedIdentifier) return e.identifier.name;
  return null;
}

/// 数值的显示形式：整数不带 `.0`（和 `DesignCodeGen._num` 同一套规则，
/// 同一件事在两处必须写出同一个样子）。
String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

// ==================== 字面量提取 ====================

/// 取字符串字面量的值（处理相邻字符串拼接 `'a' 'b'`）。
///
/// 不是字面量就返回 null —— 字符串插值（`Text('$name')`）、
/// `Text(widget.title)` 都取不到编译期的值，由调用方决定降级成占位。
String? _stringLiteral(Expression? e) {
  if (e is StringLiteral) return e.stringValue;
  if (e is AdjacentStrings) {
    final buf = StringBuffer();
    for (final s in e.strings) {
      final v = _stringLiteral(s);
      if (v == null) return null;
      buf.write(v);
    }
    return buf.toString();
  }
  return null;
}

double? _numberLiteral(Expression? e) {
  if (e is IntegerLiteral) return e.value?.toDouble();
  if (e is DoubleLiteral) return e.value;
  // `-1` 是 PrefixExpression
  if (e is PrefixExpression && e.operator.lexeme == '-') {
    final v = _numberLiteral(e.operand);
    return v == null ? null : -v;
  }
  return null;
}

/// 从 `Icons.star` 里取出 `star`，且必须在设计器的图标白名单里。
String? _iconNameOf(Expression? e) {
  if (e == null) return null;
  // ⚠️ `ListTile(leading: Icon(Icons.home))` 里拿到的是**整个 Icon 构造**，
  // 不是 `Icons.home` —— 这是 `leading:` 参数本身的形态（它要 Widget）。
  // 不先剥一层的话永远取不到，用户的前置图标会被静默换成默认值。
  final inner = _asWidgetCall(e);
  if (inner != null && inner.name == 'Icon') return _iconNameOf(inner.firstArg);

  // `const Icon(Icons.star)` 里，`Icons.star` 是 PrefixedIdentifier。
  String? raw;
  if (e is PrefixedIdentifier) {
    raw = e.identifier.name;
  } else if (e is PropertyAccess) {
    raw = e.propertyName.name;
  } else if (e is SimpleIdentifier) {
    raw = e.name;
  }
  if (raw == null) return null;
  return kIconNames.contains(raw) ? raw : null;
}

/// 取按钮的文案：`FilledButton(child: Text('登录'))` 或
/// `FilledButton(onPressed: _x, child: Text('登录'))`。
String? _buttonLabel(_WidgetCall call) {
  final child = call.childArgument;
  if (child == null) return null;
  // `child: Text('登录')`
  final inner = _asWidgetCall(child) ?? _asWidgetCall(_unwrapConst(child));
  if (inner != null && inner.name == 'Text') {
    return _stringLiteral(inner.firstArg);
  }
  // `child: const Text('登录')` 里的 Text 也是 MethodInvocation，
  // 上面已经覆盖；这里再试一次直接的字符串（少见但合法）。
  return _stringLiteral(child);
}

/// 剥掉可能包在外面的 const/括号。
///
/// 解析器给出的 `const Text('x')` 是 `InstanceCreationExpression`，
/// 已经是终态，不需要剥。这个函数是为 `(Text('x'))` 这类括号写的 ——
/// 括号在 AST 里是独立的 `ParenthesizedExpression`。
Expression _unwrapConst(Expression e) {
  if (e is ParenthesizedExpression) return _unwrapConst(e.expression);
  return e;
}

// ==================== 解析入口 ====================

CompilationUnit? _parse(String source) {
  try {
    return parseString(
      content: source,
      featureSet: FeatureSet.latestLanguageVersion(),
      // 不抛诊断：用户的项目里可能有语法错误（正在写一半），
      // 我们要的是"能解析出多少算多少"，而不是直接失败。
      throwIfDiagnostics: false,
    ).unit;
  } catch (_) {
    return null;
  }
}

// ==================== 项目文件遍历 ====================

/// 项目文件遍历用的目录/文件读取接口。
///
/// 抽象出来是为了让 [findDartFiles] 能在测试里跑（塞个内存实现），
/// 不依赖 `FsBridge`、不依赖真机。
typedef ListDirFn = Future<List<DirEntry>> Function(String path);
typedef ReadFileFn = Future<String?> Function(String path);

/// 遍历时看到的一个条目。
class DirEntry {
  final String name;
  final bool isDir;
  final int size;

  const DirEntry({required this.name, required this.isDir, this.size = 0});

  String pathOf(String parent) => parent == '/' ? '/$name' : '$parent/$name';
}

/// 找到项目里可导入的 dart 文件。
///
/// 广度优先（BFS）：用户最可能想导入的是 `lib/` 顶层的
/// `login_page.dart`，而不是 `lib/src/features/.../widgets/` 深处的。
/// BFS 让常见的排前面，用户少滚两屏。
///
/// ## 边界
///
/// - `maxDepth: 8` / `maxFiles: 500` —— **防符号链接死循环**。
///   `FsEntry` 没有 `isLink` 字段（拿不到），所以只能靠深度上限兜底。
/// - 跳过 `generated`（我们自己的产出，导进去等于自我复制）、
///   `.dart_tool` / `build`（构建产物，成千上万个文件）、
///   `l10n`（生成的本地化代码，没有界面）。
/// - 用 [DirEntry.size] **预过滤 2MB**：`FsBridge.read` 在 Kotlin 侧有
///   2MB 上限，超了读失败。与其让用户在导入到一半时看到报错，
///   不如列表阶段就标出来（超限的文件仍然返回，但 [maxBytes] 会告诉
///   调用方它不合法 —— 页面层据此标灰）。
Future<List<String>> findDartFiles(
  ListDirFn listDir,
  String root, {
  int maxDepth = 8,
  int maxFiles = 500,
  int maxBytes = 2 * 1024 * 1024,
}) async {
  final out = <String>[];
  final queue = <({String path, int depth})>[(path: root, depth: 0)];
  var seen = 0;

  while (queue.isNotEmpty && out.length < maxFiles) {
    final cur = queue.removeAt(0);
    if (cur.depth > maxDepth) continue;
    // 单次调用失败就跳过这个目录 —— 权限问题、竞态删除都可能发生，
    // 不该让整个导入流程失败。
    final List<DirEntry> entries;
    try {
      entries = await listDir(cur.path);
    } catch (_) {
      continue;
    }
    for (final e in entries) {
      if (++seen > maxFiles * 20) return out;
      if (e.isDir) {
        if (_kSkipDirs.contains(e.name)) continue;
        queue.add((path: e.pathOf(cur.path), depth: cur.depth + 1));
        continue;
      }
      if (!e.name.endsWith('.dart')) continue;
      // `.dart.bak` 结尾不是 `.dart`（`endsWith` 不匹配），备份文件
      // 天然被排除 —— 这是我们选择用 `.dart.bak` 而不是 `.bak` 的原因之一。
      out.add(e.pathOf(cur.path));
      if (out.length >= maxFiles) break;
    }
  }
  return out;
}

// ==================== 项目级扫描 ====================

/// 项目里一个"能预览的页面"：文件路径 + 那个文件里的某个 build 方法。
///
/// 和 [ImportCandidate] 的区别：候选只是"源码里有这么个 build"，
/// 不知道它在哪个文件；项目扫描要把文件路径一起带回来，用户点一下
/// 就能直接预览/导入那个文件里的那个类。
class ProjectPageEntry {
  /// 源文件绝对路径。
  final String path;

  /// 这个文件里的一个可导入入口。
  final ImportCandidate candidate;

  const ProjectPageEntry({required this.path, required this.candidate});

  /// 给用户看的一行：`login_page.dart › LoginPage`。
  ///
  /// 带上文件名是必须的 —— 一个项目里叫 `HomePage` 的类可能有三个，
  /// 只显示类名用户点哪个都是赌。
  String get label {
    final slash = path.lastIndexOf('/');
    final name = slash < 0 ? path : path.substring(slash + 1);
    return '$name › ${candidate.displayName}';
  }

  @override
  String toString() => '$label（${candidate.line} 行）';
}

/// 一次项目扫描的统计。UI 要拿这些数字跟用户说话
/// （"扫了 12 个文件，找到 4 个可预览页面"），不然用户会觉得弹窗是空的、
/// 以为功能坏了。
class ProjectScanResult {
  /// 按"文件名 + 行号"排好序的可预览页面。
  final List<ProjectPageEntry> entries;

  /// 实际读成功并解析过的 dart 文件数。
  final int scannedFiles;

  /// [findDartFiles] 找到的候选文件总数。`scanned - filesFound` 就是
  /// 读失败（超 2MB / 权限）或没有 build 而被跳过的数量。
  final int filesFound;

  /// 解析失败（语法错误读不动）的文件数。
  final int failedFiles;

  /// 扫描过程中碰到的问题（目录读不了之类），给用户看。
  final List<String> notes;

  const ProjectScanResult({
    required this.entries,
    required this.scannedFiles,
    required this.filesFound,
    required this.failedFiles,
    required this.notes,
  });

  static const ProjectScanResult empty = ProjectScanResult(
    entries: <ProjectPageEntry>[],
    scannedFiles: 0,
    filesFound: 0,
    failedFiles: 0,
    notes: <String>[],
  );

  bool get isEmpty => entries.isEmpty;

  /// 一句话总结，UI 直接用。
  String get summary {
    if (filesFound == 0) return '没扫到 dart 文件（目录是不是选错了？）';
    if (entries.isEmpty) {
      final extra = failedFiles > 0 ? '，其中 $failedFiles 个文件解析失败' : '';
      return '扫了 $filesFound 个 dart 文件$extra，没找到带 build 方法的页面类';
    }
    final extra = failedFiles > 0 ? '（$failedFiles 个文件解析失败，已跳过）' : '';
    return '扫了 $filesFound 个 dart 文件，找到 ${entries.length} 个可预览页面$extra';
  }
}

/// 全部答案都在文件里 —— 只是它散在几十个文件、几千行中间。
///
/// 这个函数把 [findDartFiles]（有哪些 dart 文件）和 [findCandidates]
/// （每个文件里有几个 build）串起来，一次性回答"这个项目里
/// 我能预览哪些页面"。
///
/// ## 为什么是"跳过"而不是"报错"
///
/// 用户的项目里一定有正在写一半的文件（少个括号）、有生成代码、
/// 有 `part` 文件。扫描的目的是**找到能预览的东西**，不是做
/// 静态分析。任何一个文件读不了都只是少一条结果，不该让整次扫描失败。
///
/// [read] 返回 null 表示读失败（`FsBridge` 侧 2MB 上限、权限问题）。
Future<ProjectScanResult> scanProjectPages(
  ListDirFn listDir,
  ReadFileFn read,
  String root, {
  int maxDepth = 8,
  int maxFiles = 500,
}) async {
  final files = await findDartFiles(
    listDir,
    root,
    maxDepth: maxDepth,
    maxFiles: maxFiles,
  );
  if (files.isEmpty) {
    return ProjectScanResult(
      entries: const <ProjectPageEntry>[],
      scannedFiles: 0,
      filesFound: 0,
      failedFiles: 0,
      notes: <String>['$root 下没有 dart 文件'],
    );
  }

  final entries = <ProjectPageEntry>[];
  final notes = <String>[];
  var scanned = 0;
  var failed = 0;

  for (final path in files) {
    final String? src;
    try {
      src = await read(path);
    } catch (e) {
      // 读文件抛异常在真机上很常见：文件在遍历和读取之间被删了、
      // FsBridge 的 IO 通道断了、超 2MB 上限。任何一条都不该让
      // 整次扫描崩在用户脸上。
      final msg = _readErrorNote(path, e);
      if (notes.length < 5) notes.add(msg);
      continue;
    }
    if (src == null || src.isEmpty) {
      // read 返回 null 的两种原因（超限 / 读不了）在这里区分不了，
      // 统一带一笔说明，不进 failedFiles —— 那不是"解析失败"。
      if (notes.length < 5) notes.add('读不了：$path（超过 2MB 上限？）');
      continue;
    }
    scanned++;
    List<ImportCandidate> candidates;
    try {
      candidates = findCandidates(src);
    } catch (e) {
      // 真机上 analyzer 内部抛异常不常见，但一旦发生，
      // 用户至少要能在提示里看到"有文件解析失败了"，
      // 而不是对着一个空列表猜。
      failed++;
      if (notes.length < 5) notes.add('解析失败：$path（$e）');
      continue;
    }
    // 一个文件里可能有好几个页面类（`login_page.dart` 里既有
    // `LoginPage` 又有 `RegisterPage`），全都要，别只取第一个。
    for (final c in candidates) {
      entries.add(ProjectPageEntry(path: path, candidate: c));
    }
  }

  entries.sort((a, b) {
    final byPath = a.path.compareTo(b.path);
    return byPath != 0 ? byPath : a.candidate.line.compareTo(b.candidate.line);
  });

  return ProjectScanResult(
    entries: entries,
    scannedFiles: scanned,
    filesFound: files.length,
    failedFiles: failed,
    notes: notes,
  );
}

/// 读文件失败时给用户的一句话。带上异常信息，不然用户
/// 拿着"有个文件读不了"这种提示完全没法定位是哪个。
String _readErrorNote(String path, Object e) {
  final detail = e is Exception || e is Error ? '$e' : e.toString();
  // 单个异常信息可能很长（栈信息），截一下 —— 这是给用户看的一行提示，
  // 不是日志。
  final short = detail.length > 80 ? '${detail.substring(0, 80)}…' : detail;
  return '读不了：$path（$short）';
}

/// 遍历时跳过的目录名。
const Set<String> _kSkipDirs = <String>{
  'generated', // 设计器的产出，导进去是自我复制
  '.dart_tool',
  'build',
  'l10n',
  '.git',
  '.idea',
  'ios',
  'android',
  'linux',
  'macos',
  'windows',
  'web',
  'test',
};
