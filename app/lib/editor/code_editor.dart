import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:code_text_field/code_text_field.dart';
import 'package:dart_style/dart_style.dart';
import 'package:flutter/foundation.dart' show compute, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/github.dart' show githubTheme;
import 'package:flutter_highlight/themes/monokai-sublime.dart'
    show monokaiSublimeTheme;
import 'package:highlight/highlight.dart' show Mode;
import 'package:highlight/languages/bash.dart' as hl_bash;
import 'package:highlight/languages/css.dart' as hl_css;
import 'package:highlight/languages/dart.dart' as hl_dart;
import 'package:highlight/languages/groovy.dart' as hl_groovy;
import 'package:highlight/languages/java.dart' as hl_java;
import 'package:highlight/languages/javascript.dart' as hl_js;
import 'package:highlight/languages/json.dart' as hl_json;
import 'package:highlight/languages/kotlin.dart' as hl_kotlin;
import 'package:highlight/languages/markdown.dart' as hl_md;
import 'package:highlight/languages/python.dart' as hl_py;
import 'package:highlight/languages/typescript.dart' as hl_ts;
import 'package:highlight/languages/xml.dart' as hl_xml;
import 'package:highlight/languages/yaml.dart' as hl_yaml;

import 'completion.dart';
import 'dart_syntax_checker.dart';
import 'hint_prefs.dart';
import '../env/proot_bridge.dart';
import '../core/theme.dart';

/// 编辑器上报给宿主的 AI 请求（alpha.81）。
///
/// 内容只有"路径 + 当前文本 + 光标位置 + 语言"——编辑器依然**不知道
/// AI 是什么**（alpha.61 定下的边界）：宿主拿到它去补全还是派活，
/// 由宿主和用户选的后端决定，编辑器一概不参与。
class EditorAiRequest {
  final String path;
  final String content;
  final int cursorOffset;

  /// 展示/提示词用的语言名（dart、java…），推断不出来就是空串。
  final String language;

  const EditorAiRequest({
    required this.path,
    required this.content,
    required this.cursorOffset,
    this.language = '',
  });
}

/// 代码编辑器：语法高亮 + 行号 + 等宽字体 + 轻量补全/语法检查。
///
/// 基于 CodeField（TextField 子类），IME 中文输入、光标管理、
/// 滚动性能均继承 TextField 原生行为；500 行文件无压力。
///
/// Bug 214：CodeField 必须显式传 `theme`（flutter_highlight 主题映射），
/// 否则 highlight 产出的 span 没有文本样式 → 语法高亮"不生效"。
class CodeEditor extends StatefulWidget {
  final String path;
  final String initialContent;

  /// 内容变化回调（父级用于 dirty 跟踪）。
  final ValueChanged<String> onContentChanged;

  /// 单点 AI 入口（alpha.81）：请宿主「按当前代码补全」。
  /// 与 [onAiInstruct] 一起为 null 时不显示状态栏的 AI 按钮——让
  /// "嵌在别处的小编辑器"可以选择不暴露该入口，不必为此改接口。
  final void Function(EditorAiRequest)? onAiComplete;

  /// 长按 AI 入口（alpha.81）：请宿主「给个输入栏，我要下达指令」。
  /// 输入栏由宿主弹——编辑器连"有没有输入框"都不该知道。
  final void Function(EditorAiRequest)? onAiInstruct;

  /// AI 正在生成（alpha.82）：编辑区**只读** + 顶部一条进度条。
  ///
  /// 为什么不是"等拿到了再插"：用户看不到任何东西时，十几秒的等待会让人
  /// 以为按钮坏了。预留空行（见 [CodeEditorState.beginAiPlaceholder]）让
  /// 他一眼看到"AI 要写在这儿"，只读则保证占位期间文本不会被改乱。
  final bool aiBusy;

  const CodeEditor({
    super.key,
    required this.path,
    required this.initialContent,
    required this.onContentChanged,
    this.onAiComplete,
    this.onAiInstruct,
    this.aiBusy = false,
  });

  @override
  State<CodeEditor> createState() => CodeEditorState();
}

/// 占位插入点：光标所在行的**行末**（alpha.82，纯函数便于单测）。
///
/// 为什么不直接用光标位置：光标常停在一行代码的中间（用户刚敲完半个词），
/// 从那儿插空行会把这行**劈成两半**——`final a = 1;` 变成
/// `final \n\n\n\n a = 1;`。取行末能保证预留出来的永远是整行空行。
int aiPlaceholderInsertAt(String text, int cursor) {
  if (text.isEmpty) return 0;
  final base = cursor < 0 ? 0 : (cursor > text.length ? text.length : cursor);
  final nl = text.indexOf('\n', base);
  return nl < 0 ? text.length : nl;
}

/// 公开 State：EditorPage 通过 GlobalKey<CodeEditorState> 调用
/// 撤销/跳转行/搜索/格式化等顶栏操作（Bug 218）。
class CodeEditorState extends State<CodeEditor> {
  late CodeController _controller;
  final FocusNode _focus = FocusNode();

  final List<CompletionItem> _suggestions = [];
  Timer? _checkTimer;
  List<SyntaxIssue> _issues = const [];
  bool _checking = false;

  // ---- 补全浮层（alpha.80，借鉴 WebIDE 的形态）----
  /// 代码区纵向滚动偏移（vendored CodeField 回调注入）。
  /// 浮层要把「光标行的文本坐标」换算成视口坐标，必须知道滚到哪了。
  ScrollController? _codeScroll;

  /// 文件内标识符缓存（matchCompletionsWithIdentifiers 用）。
  /// 每次按键全文件正则扫描太浪费 → 500ms debounce 重建。
  Set<String> _fileIdents = const {};
  Timer? _identTimer;

  /// 上次触发浮层时的光标行；行变了才需要重设浮层位置。
  int _lastCaretLine = -1;

  /// 编辑区视口尺寸（LayoutBuilder 注入），浮层翻转/clamp 用。
  double _viewportH = 0;
  double _viewportW = 0;

  /// TextField 文本区顶部内边距。vendored CodeField 的 TextField 用
  /// `InputDecoration(border: InputBorder.none, ...)`，M3 默认
  /// contentPadding 是 `fromLTRB(12, 8, 12, 8)` → top = **8**（alpha.80
  /// 实测校准：此前拍脑袋写的 20 会让浮层整体偏下 12px）。
  /// 值由 editor_completion_test 的校准测试锁定——vendored/Flutter 换版本
  /// 若布局变化，校准测试会红提醒重校。
  static const double _kTextTopInset = 8;

  // ---- 字号缩放（alpha.32，Bug 432 重做）----
  /// 当前字号；initState 异步恢复上次偏好（捏合/按钮调整后持久化）。
  double _fontSize = EditorFontPrefs.def;

  /// 捏合起点字号（onScaleStart 快照，onScaleUpdate 按手势倍率乘算）。
  double _scaleBase = EditorFontPrefs.def;
  bool _scaleActive = false;

  /// 捏合判定的间距变化阈值（相对量）。
  ///
  /// Bug 432 背景：不能直接用 `ScaleUpdateDetails.scale`——它是**各向同性**
  /// 的欧氏距离比（见 Flutter scale.dart 的 _pointerScaleFactor =
  /// _currentSpan / _initialSpan，span 取两指到质心的 hypot 平均）。
  /// 双指自然持机时两指在 y 轴错开，上下滑动过程中两指上下异步（人手指
  /// 不可能同步）就会让 hypot 距离变化 → scale 偏离 1.0 → 字号被误改。
  ///
  /// 实测（复刻 Flutter 的 span 公式）：竖直排列的两指，滑动滞后 2px
  /// 造成 1.72% 漂移、滞后 10px 造成 8.56% 漂移；而水平并排的两指同样
  /// 滞后只漂移 0.70% / 3.81%。这就是用户报告的
  /// 「上下划能放大缩小，左右划不能，和几根手指没关系」。
  ///
  /// 因此改为只用**轴向间距**（horizontalScale / verticalScale）判断，
  /// 并要求间距变化超过本阈值才算缩放；否则一律视为平移，放行给
  /// 编辑器滚动/光标。0.15 对应 >15% 的间距变化——实测两指异步 10px
  /// 时轴向倍率偏移约 10%，仍在阈值内，留有安全裕度。
  static const double _kSpanSlop = 0.15;

  /// 手势是否已被判定为缩放；捏合中途为真，回位后复位。
  bool _scaleEngaged = false;

  @override
  void initState() {
    super.initState();
    _controller = CodeController(
      text: widget.initialContent,
      language: _language,
    );
    _controller.addListener(_onChanged);
    // alpha.80：初始标识符缓存同步建（初稿文件也要能补全自定义名）。
    _fileIdents = extractIdentifiers(widget.initialContent);
    _scheduleCheck(immediate: true);
    EditorFontPrefs.load().then((v) {
      if (mounted && v != _fontSize) setState(() => _fontSize = v);
    });
    // Bug 431：字号功能早就可用（状态栏 A-/A+ 与双指捏合），但用户反馈
    // 「要一个手指不动另一个手指动才能缩放，得单独出教程」——是发现性问题。
    // 首次进入给一次短提示，比写教程有效。仅提示一次，且延迟到布局完成。
    _maybeHintFontScale();
  }

  /// 首次进入编辑器时提示字号调节方式（只弹一次，见 HintPrefs）。
  Future<void> _maybeHintFontScale() async {
    try {
      if (await HintPrefs.seen(HintPrefs.editorFont)) return;
      await HintPrefs.markSeen(HintPrefs.editorFont);
      if (!mounted) return;
      // 等首帧渲染完再弹，避免与布局/键盘动画抢焦点
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: const Text(
            '字号调节：点底部状态栏的 A− / A+ 即可；'
            '双指捏合也能缩放，戳中间数字可恢复默认。',
            style: TextStyle(fontSize: 12.5),
          ),
          action: SnackBarAction(
            label: '知道了',
            onPressed: () => messenger.hideCurrentSnackBar(),
          ),
        ),
      );
    } catch (_) {
      // 提示失败不影响任何编辑功能
    }
  }

  @override
  void didUpdateWidget(covariant CodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换文件：以旧控制器内容为准（可能含未保存编辑），重建控制器
    if (oldWidget.path != widget.path) {
      _controller.dispose();
      _controller = CodeController(
        text: widget.initialContent,
        language: _language,
      );
      _controller.addListener(_onChanged);
      _issues = const [];
      // alpha.80：换文件重置补全状态（标识符缓存是新文件的、浮层收起）。
      _fileIdents = extractIdentifiers(widget.initialContent);
      _hideSuggestions();
      _scheduleCheck(immediate: true);
    }
  }

  void _onChanged() {
    widget.onContentChanged(_controller.text);
    _updateSuggestions();
    _scheduleIdentRebuild();
    _scheduleCheck();
  }

  // ---------------- 语法检查 ----------------

  void _scheduleCheck({bool immediate = false}) {
    _checkTimer?.cancel();
    if (immediate) {
      _runCheck();
      return;
    }
    if (!_checking && mounted) setState(() => _checking = true);
    _checkTimer = Timer(const Duration(milliseconds: 600), _runCheck);
  }

  void _runCheck() {
    final issues = checkDartSyntax(_controller.text);
    if (!mounted) return;
    setState(() {
      _issues = issues;
      _checking = false;
    });
  }

  // ---------------- 代码补全 ----------------

  int _wordStart(String text, int offset) {
    var start = offset;
    while (start > 0 && _isIdent(text[start - 1])) {
      start--;
    }
    return start;
  }

  static bool _isIdent(String c) => RegExp(r'[A-Za-z0-9_]').hasMatch(c);

  void _updateSuggestions() {
    final value = _controller.value;
    final off = value.selection.baseOffset;
    final text = value.text;
    if (off < 0 || off > text.length) {
      _hideSuggestions();
      return;
    }
    final start = _wordStart(text, off);
    final word = text.substring(start, off);
    if (word.length < 2) {
      _hideSuggestions();
      return;
    }
    final hits = matchCompletionsWithIdentifiers(word, _fileIdents);
    if (hits.isEmpty) {
      _hideSuggestions();
      return;
    }
    // 光标行变了（上下键/点击移动光标）浮层也要跟着走，
    // 即便候选列表没变。
    final line = _lineOf(text, off);
    final changed = !listEquals(
      List.generate(hits.length, (i) => hits[i].word),
      List.generate(_suggestions.length, (i) => _suggestions[i].word),
    );
    if ((changed || line != _lastCaretLine) && mounted) {
      setState(() {
        _suggestions
          ..clear()
          ..addAll(hits);
        _lastCaretLine = line;
      });
    }
  }

  void _hideSuggestions() {
    if (_suggestions.isNotEmpty && mounted) setState(_suggestions.clear);
    _lastCaretLine = -1;
  }

  /// 光标所在逻辑行（0 基）。
  ///
  /// 本编辑器 CodeField 用 `wrap: false`（长行横向滚动），一个逻辑行
  /// 恰好就是一个视觉行——这是浮层 Y 定位只用行号就够的前提；
  /// 若将来开 wrap，这里必须换 TextPainter 按视觉行计算。
  static int _lineOf(String text, int offset) {
    var line = 0;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) line++;
    }
    return line;
  }

  double get _lineHeight => _fontSize * 1.5;

  /// 光标行顶部的视口 y（编辑区 Stack 坐标系）。
  ///
  /// 文本 y = 行数 × 行高 + TextField 顶部内边距；视口 y = 文本 y - 滚动偏移。
  /// X 不做列级跟随：wrap=false 的横向滚动在 vendored CodeField 里没有
  /// 挂 controller，偏移拿不到；固定贴左侧在窄屏上可用空间也最大。
  double? _caretViewportTop() {
    final sc = _codeScroll;
    if (sc == null) return null;
    final off = _controller.selection.baseOffset;
    final text = _controller.text;
    if (off < 0 || off > text.length) return null;
    final scrollY = sc.hasClients ? sc.offset : 0.0;
    return _kTextTopInset + _lineOf(text, off) * _lineHeight - scrollY;
  }

  /// 滚动时只刷浮层位置（有建议时才值得 setState）。
  void _onCodeScroll() {
    if (_suggestions.isNotEmpty && mounted) setState(() {});
  }

  /// 文件标识符缓存重建（debounce 500ms）：
  /// 每次按键都全文件正则扫描在百 KB 文件上是毫秒级开销，没必要。
  void _scheduleIdentRebuild() {
    _identTimer?.cancel();
    _identTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _fileIdents = extractIdentifiers(_controller.text);
    });
  }

  void _applySuggestion(CompletionItem item) {
    final value = _controller.value;
    final off = value.selection.baseOffset;
    if (off < 0 || off > value.text.length) return;
    final start = _wordStart(value.text, off);
    final newText = value.text.replaceRange(start, off, item.insert);
    _controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: start + item.insert.length),
      composing: TextRange.empty,
    );
    // listener 会刷新补全与检查
  }

  /// 在光标处插入符号（Bug 217 符号栏）。
  void _insertSymbol(String symbol) {
    final value = _controller.value;
    final off = value.selection.baseOffset;
    if (off < 0 || off > value.text.length) {
      _controller.text += symbol;
      return;
    }
    final newText = value.text.replaceRange(off, off, symbol);
    _controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: off + symbol.length),
      composing: TextRange.empty,
    );
    // listener 会刷新补全与检查
  }

  /// 在光标处插入一段文本（alpha.81：AI 结果"应用到光标处"）。
  ///
  /// 与符号栏 [_insertSymbol] 同一套替换逻辑：光标位置非法时退化为
  /// 追加到文件末尾——宁可插错位置，也不能把用户已经写的东西覆盖掉。
  /// 公开给宿主：宿主拿到 AI 预览结果后经 GlobalKey 调它落地。
  void insertAtCursor(String text) {
    if (text.isEmpty) return;
    final value = _controller.value;
    final off = value.selection.baseOffset;
    if (off < 0 || off > value.text.length) {
      _controller.text = value.text + text;
      return;
    }
    final newText = value.text.replaceRange(off, off, text);
    _controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: off + text.length),
      composing: TextRange.empty,
    );
  }

  // ---------------- AI 占位（alpha.82） ----------------

  /// 占位区间 `[_aiSlotStart, _aiSlotEnd)`；-1 表示当前没有占位。
  int _aiSlotStart = -1;
  int _aiSlotEnd = -1;

  /// 是否有待填充的占位。
  bool get hasAiSlot => _aiSlotStart >= 0;

  /// 在光标所在行**下方**预留 [lines] 个空行（alpha.82）。
  ///
  /// 记下区间是为了**可回滚**：AI 失败或用户放弃时原样删掉这几个空行，
  /// 绝不留下垃圾。插入点取"光标所在行的行末"而不是光标本身——否则会把
  /// 一行代码从中间劈成两半。
  ///
  /// 返回占位起始偏移。
  int beginAiPlaceholder({int lines = 4}) {
    final text = _controller.text;
    final at = aiPlaceholderInsertAt(text, _controller.selection.baseOffset);
    final pad = '\n' * lines;
    _controller.value = _controller.value.copyWith(
      text: text.replaceRange(at, at, pad),
      selection: TextSelection.collapsed(offset: at),
      composing: TextRange.empty,
    );
    _aiSlotStart = at;
    _aiSlotEnd = at + pad.length;
    return at;
  }

  /// 用 AI 的真实产出**替换**占位区间。
  ///
  /// 没有占位时退化成 [insertAtCursor]（追加到光标处）——宁可插错位置，
  /// 也绝不覆盖用户已经写的东西。
  void commitAiPlaceholder(String text) {
    if (!hasAiSlot) {
      insertAtCursor(text);
      return;
    }
    final s = _aiSlotStart;
    final e = _aiSlotEnd;
    _aiSlotStart = -1;
    _aiSlotEnd = -1;
    _replaceRange(s, e, text);
  }

  /// 撤销占位（AI 失败 / 用户放弃）：把那几个空行原样删掉。
  void cancelAiPlaceholder() {
    if (!hasAiSlot) return;
    final s = _aiSlotStart;
    final e = _aiSlotEnd;
    _aiSlotStart = -1;
    _aiSlotEnd = -1;
    _replaceRange(s, e, '');
  }

  void _replaceRange(int start, int end, String withText) {
    final v = _controller.value;
    final s = start.clamp(0, v.text.length);
    final e = end.clamp(s, v.text.length);
    _controller.value = v.copyWith(
      text: v.text.replaceRange(s, e, withText),
      selection: TextSelection.collapsed(offset: s + withText.length),
      composing: TextRange.empty,
    );
  }

  /// 把"当前文本 + 光标"报给宿主（编辑器不知道宿主拿去干什么）。
  void _emitAi(void Function(EditorAiRequest)? cb) {
    // 生成中就别再派活了：占位区间只有一个，重复派会让回滚对不上号
    if (widget.aiBusy) return;
    if (cb == null) return;
    final text = _controller.text;
    final off = _controller.selection.baseOffset;
    cb(EditorAiRequest(
      path: widget.path,
      content: text,
      // 光标可能是 -1（没聚焦过），夹到合法范围再报
      cursorOffset: off < 0 ? 0 : (off > text.length ? text.length : off),
      language: _languageName,
    ));
  }

  // ---------------- 外部操作 API（顶栏按钮经 GlobalKey 调用） ----------------

  /// 撤销更改：重置为打开时的初始内容（Bug 218）。
  void reset(String content) {
    _controller.value = TextEditingValue(
      text: content,
      selection: TextSelection.collapsed(offset: content.length),
      composing: TextRange.empty,
    );
    _issues = const [];
    _hideSuggestions();
    _scheduleCheck(immediate: true);
  }

  /// 跳转到第 [line] 行（1 起）：光标置于行首，EditableText 自动滚动到光标。
  void jumpToLine(int line) {
    final lines = _controller.text.split('\n');
    if (lines.isEmpty) return;
    if (line < 1) line = 1;
    final target = line - 1 < lines.length ? line - 1 : lines.length - 1;
    var offset = 0;
    for (var i = 0; i < target; i++) {
      offset += lines[i].length + 1;
    }
    _controller.value = _controller.value.copyWith(
      selection: TextSelection.collapsed(offset: offset),
      composing: TextRange.empty,
    );
  }

  /// 打开文件内搜索对话框（Bug 218）。
  void openSearch() {
    showDialog<void>(
      context: context,
      builder: (_) => _SearchDialog(controller: _controller),
    );
  }

  /// 格式化代码：Dart 用 dart_style（compute 隔离线程防卡 UI）。
  /// 返回 null 表示成功，否则返回错误信息。
  Future<String?> formatCode() async {
    final lang = _languageName;
    if (lang != 'dart') {
      return '仅支持 Dart 文件格式化';
    }
    try {
      final formatted = await compute(_formatDartSource, _controller.text);
      if (formatted != _controller.text) {
        _controller.value = TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: formatted.length),
          composing: TextRange.empty,
        );
      }
      return null;
    } catch (e) {
      return '格式化失败（语法错误？）：$e';
    }
  }

  // ---------------- UI ----------------

  /// 按扩展名选语法高亮语言（highlight 包语言，导出名为小写 Mode 变量）。
  Mode? get _language {
    final name = widget.path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    switch (name.substring(dot + 1).toLowerCase()) {
      case 'dart':
        return hl_dart.dart;
      case 'yaml':
      case 'yml':
        return hl_yaml.yaml;
      case 'json':
        return hl_json.json;
      case 'md':
        return hl_md.markdown;
      case 'sh':
        return hl_bash.bash;
      case 'kt':
      case 'kts':
        return hl_kotlin.kotlin;
      case 'java':
        return hl_java.java;
      case 'py':
        return hl_py.python;
      case 'xml':
      case 'html':
        return hl_xml.xml;
      case 'css':
        return hl_css.css;
      case 'js':
        return hl_js.javascript;
      case 'ts':
        return hl_ts.typescript;
      case 'groovy':
        return hl_groovy.groovy;
      default:
        return null; // 未知类型不高亮
    }
  }

  String get _languageName {
    final name = widget.path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return 'text';
    return name.substring(dot + 1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    // alpha.69：这两处是"控件与主题不一致"的修复入口 ——
    // 语法高亮主题与代码区底色都必须随亮度走，不能固定深色。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c = FoaColors.of(context);
    return Column(
      children: [
        // alpha.82：AI 生成中——放在代码区上方而不是覆盖在代码上，
        // 免得挡住刚预留出来的空行（那几行正是要给用户看的）。
        if (widget.aiBusy)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            color: c.panelBg.withValues(alpha: 0.6),
            child: Row(
              children: [
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI 正在生成…已预留空行，编辑暂时锁定',
                    style: TextStyle(fontSize: 11, color: c.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            // alpha.80：浮层翻转/clamp 需要编辑区视口尺寸，build 期缓存即可。
            _viewportH = constraints.maxHeight;
            _viewportW = constraints.maxWidth;
            return Stack(
              children: [
                Positioned.fill(
                  // Bug 214 修复：1.1.0 起高亮主题由 CodeTheme widget 提供
                  // （CodeController 的 theme 参数已废弃），不包 CodeTheme 则
                  // highlight 产出的 span 无样式 → 语法高亮"不生效"
                  //
                  // alpha.32 引入双指捏合缩放字号；Bug 432 修正为
                  // 只认轴向间距变化，避免双指上下滑动被误判成缩放
                  // （详见 _kSpanSlop 附近的说明）。
                  child: GestureDetector(
                    onScaleStart: (d) {
                      if (d.pointerCount < 2) return;
                      _scaleBase = _fontSize;
                      _scaleEngaged = false;
                      _scaleActive = true;
                    },
                    onScaleUpdate: (d) {
                      if (!_scaleActive || d.pointerCount < 2) return;
                      // 轴向倍率：只取真正在「捏」的那个轴。
                      // ScaleUpdateDetails.scale 是各向同性欧氏比，会把
                      // 双指滑动（异步位移）误算成缩放，故不使用。
                      final fx = d.horizontalScale;
                      final fy = d.verticalScale;
                      final dx = (fx - 1.0).abs();
                      final dy = (fy - 1.0).abs();
                      // 未判定为缩放前，先检查是否真的在捏合：
                      // 任一轴向间距变化超过 slop 才认账。
                      if (!_scaleEngaged) {
                        if (dx < _kSpanSlop && dy < _kSpanSlop) return;
                        _scaleEngaged = true;
                      } else if (dx < _kSpanSlop * 0.5 &&
                          dy < _kSpanSlop * 0.5) {
                        // 已判定为缩放，但间距又回到基准附近——说明刚才那次
                        // 越界只是双指滑动过程中的异步尖峰，而非真捏合。
                        // 撤销本次缩放并停止响应，避免"闪一下又弹回"。
                        _scaleEngaged = false;
                        if ((_fontSize - _scaleBase).abs() >= 0.5) {
                          setState(() => _fontSize = _scaleBase);
                        }
                        return;
                      }
                      // 选变化更显著的那个轴作为缩放倍率。
                      final factor = dx >= dy ? fx : fy;
                      if (factor <= 0) return;
                      final v = (_scaleBase * factor)
                          .clamp(EditorFontPrefs.min, EditorFontPrefs.max);
                      // 0.5px 以下不刷，避免高频 setState
                      if ((v - _fontSize).abs() >= 0.5) {
                        setState(() => _fontSize = v);
                      }
                    },
                    onScaleEnd: (_) {
                      if (_scaleActive) {
                        _scaleActive = false;
                        _scaleEngaged = false;
                        EditorFontPrefs.save(_fontSize);
                      }
                    },
                    child: CodeTheme(
                      // alpha.69：语法高亮主题按亮度切换。
                      //
                      // 此前固定 monokai-sublime（深色）—— 浅色主题下代码区
                      // 仍是黑底，与周围浅色界面割裂。`github` 是
                      // flutter_highlight 自带的浅色主题（root 深字浅底），
                      // 在 highlight.js 官方浅色主题里对标识符/关键字/字符串
                      // 的区分度最稳（atom-one-light 偏灰、vs 对比度略低）。
                      data: CodeThemeData(
                        styles: isDark ? monokaiSublimeTheme : githubTheme,
                      ),
                      child: CodeField(
                        controller: _controller,
                        focusNode: _focus,
                        expands: true,
                        // alpha.82：AI 生成期间只读——占位空行必须保持原样，
                        // 否则提交时区间对不上，回滚会删错内容。
                        readOnly: widget.aiBusy,
                        // 显式声明普通多行文本输入（非密码/数字变体），
                        // 避免厂商 ROM 的安全键盘误判（系统级设置仍需用户关闭）
                        keyboardType: TextInputType.multiline,
                        // alpha.69：**必须显式传 background**。
                        //
                        // CodeField 的取值链是
                        // `widget.background ?? styles['root'].backgroundColor
                        //  ?? Colors.grey.shade900`（见 vendored
                        // third_party/code_text_field/.../code_field.dart）。
                        // 不传的话，浅色下会命中 `githubTheme['root']` 自带的
                        // `#f8f8f8` —— 与项目的 lightSurface(#F5F7F8) 不同调；
                        // 深色下会命中 monokai 的 `#23241f` —— 与 panelBg 不同调。
                        // 传了之后代码区底色由 FoaColors 统一控制，第三方
                        // 主题换代也不会意外改掉它。
                        background: c.codeBg,
                        decoration: const BoxDecoration(),
                        cursorColor: const Color(0xFF3DDC84),
                        textStyle: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: _fontSize,
                          height: 1.5,
                        ),
                        lineNumberStyle: LineNumberStyle(
                          width: _fontSize < 18 ? 46 : 54,
                          // 行号用 muted 而非 Colors.grey：后者在浅色底上
                          // 对比度偏低，且不随主题走。
                          textStyle: TextStyle(
                              fontSize: _fontSize - 2, color: c.muted),
                        ),
                        // alpha.80：透出代码区纵向滚动控制器（vendored CodeField
                        // 新加的回调），补全浮层定位需要滚动偏移。
                        onScrollControllerReady: (c) {
                          _codeScroll?.removeListener(_onCodeScroll);
                          _codeScroll = c;
                          c?.addListener(_onCodeScroll);
                        },
                      ),
                    ),
                  ),
                ),
                if (_suggestions.isNotEmpty) _buildCompletionOverlay(),
              ],
            );
          }),
        ),
        // Bug 217 常用符号快捷栏：常驻显示（v2）。
        // 首版用 viewInsets.bottom > 0 检测键盘弹出才显示，但真机 01:09 截图
        // 证实部分中文输入法（百度/搜狗等带自身工具栏的 IME）不会把 insets
        // 变化传给 Flutter → 符号栏从未渲染。改为常驻：键盘弹出时天然位于
        // 键盘正上方（Column 底部被键盘顶起），收起时贴在编辑区底部，
        // 任何输入法/ROM 下都稳定可见。
        _buildSymbolBar(),
        _buildStatusBar(),
      ],
    );
  }

  /// Bug 217 常用符号栏：横向滚动按钮行，点击在光标处插入符号。
  ///
  /// 覆盖代码高频符号：括号/引号/运算符/比较符/箭头/分号等，
  /// 深色低饱和配色与编辑器一致，按钮热区足够大方便手指点按。
  Widget _buildSymbolBar() {
    const symbols = [
      '(',
      ')',
      '{',
      '}',
      '[',
      ']',
      ';',
      ',',
      ':',
      '.',
      '"',
      "'",
      '=',
      '+',
      '-',
      '*',
      '/',
      '<',
      '>',
      '!',
      '?',
      '_',
      '=>',
      '->',
      '&&',
      '||',
    ];
    // alpha.69：符号条底色与符号块底色改为主题语义色。
    // 此前是 `0xFF14181E` / `0xFF232A35` 两个按深色主题调的字面量，
    // 切浅色主题后不变 → 深色条压在浅色代码区上。
    final c = FoaColors.of(context);
    final cs = Theme.of(context).colorScheme;
    return Container(
      // alpha.80：36 → 30。用户反馈"太占位置"；配合补全浮层化
      // （旧贴底建议条 40px 不再常驻），键盘上方整体净省 ~46px。
      height: 30,
      color: c.panelBg,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        itemCount: symbols.length,
        separatorBuilder: (_, __) => const SizedBox(width: 3),
        itemBuilder: (context, i) {
          final s = symbols[i];
          return Tooltip(
            message: '插入 $s',
            waitDuration: const Duration(milliseconds: 600),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _insertSymbol(s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // 用 M3 的容器色而非再开一个语义位：这里要的就是
                  // "比面板底亮一档"，而这正是 surfaceContainerHighest 的语义。
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  s,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    color: cs.onSurface,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// alpha.80 补全浮层：贴光标行下方弹出，限高滚动、宽 ≤70% 视口。
  ///
  /// 形态借鉴 WebIDE（其用 sora-editor 内置 CompletionPopup）：
  /// 悬浮在代码上、不占布局空间——替代旧版贴底横条（固定 40px 高、
  /// 横向翻找费劲、与符号栏抢底部空间）。底部放不下时翻到光标上方。
  Widget _buildCompletionOverlay() {
    final caretTop = _caretViewportTop();
    if (caretTop == null) return const SizedBox.shrink();
    final c = FoaColors.of(context);
    final cs = Theme.of(context).colorScheme;
    const itemH = 32.0;
    final boxH = math.min(_suggestions.length * itemH + 8, itemH * 4.5);
    final belowY = caretTop + _lineHeight + 4;
    // 底部放不下且上方放得下才翻转；两边都紧就 clamp 在编辑区内。
    final flip = belowY + boxH > _viewportH - 2 && caretTop - boxH - 8 >= 0;
    var top = flip ? caretTop - boxH - 4 : belowY;
    top = top.clamp(0.0, math.max(0.0, _viewportH - boxH));
    return Positioned(
      left: 8,
      top: top,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        color: cs.surfaceContainerHighest,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(_viewportW * 0.7, 320),
            maxHeight: boxH,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final s in _suggestions) _completionRow(s, c, cs),
            ],
          ),
        ),
      ),
    );
  }

  Widget _completionRow(CompletionItem s, FoaColors c, ColorScheme cs) {
    // 片段类补全的插入文本和词不同（如 main → void main() {}），尾缀展示。
    final hint = s.insert == s.word ? null : s.insert;
    return InkWell(
      onTap: () => _applySuggestion(s),
      child: SizedBox(
        height: 32,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(_kindIcon(s.kind), size: 14, color: _kindColor(s.kind)),
              const SizedBox(width: 8),
              Text(
                s.word,
                style: TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    color: cs.onSurface),
              ),
              if (hint != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, fontFamily: 'monospace', color: c.muted),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static IconData _kindIcon(CompletionKind k) => switch (k) {
        CompletionKind.keyword => Icons.code,
        CompletionKind.snippet => Icons.bolt,
        CompletionKind.type => Icons.category_outlined,
        CompletionKind.method => Icons.functions,
        // alpha.80：文件内标识符——区别于静态词库的"自定义名字"。
        CompletionKind.identifier => Icons.text_fields_outlined,
      };

  static Color _kindColor(CompletionKind k) => switch (k) {
        CompletionKind.keyword => const Color(0xFFC586C0),
        CompletionKind.snippet => const Color(0xFFE5C07B),
        CompletionKind.type => const Color(0xFF4EC9B0),
        CompletionKind.method => const Color(0xFF61AFEF),
        CompletionKind.identifier => const Color(0xFF9CDCFE),
      };

  Widget _buildStatusBar() {
    // alpha.69：成功/失败色改走语义位（原 `0xFF3DDC84` / `0xFFFF7A7A` 是
    // 按深色主题调的字面量，浅色下红绿都偏亮、对比度不足）。
    final c = FoaColors.of(context);
    final (Color color, IconData icon, String text) = _checking
        ? (c.muted, Icons.hourglass_empty, '检查中…')
        : _issues.isEmpty
            ? (c.success, Icons.check_circle_outline, '语法 OK')
            : (c.danger, Icons.error_outline, '${_issues.length} 个问题');
    return Material(
      // alpha.69：原 `0xFF161B21` 固定深色 —— 浅色主题下整条状态栏是黑的。
      color: c.panelBg,
      child: InkWell(
        onTap: _issues.isEmpty ? null : _showIssues,
        child: SizedBox(
          height: 24,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              // 字号缩放（alpha.32）：A- / 当前字号 / A+，字号可点回默认；
              // 与双指捏合等效，给不熟悉手势的用户一个可见入口
              _fontButton(Icons.text_decrease, '缩小字号（双指捏合亦可）', -1),
              Tooltip(
                message: '点击恢复默认字号',
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () {
                    if (_fontSize == EditorFontPrefs.def) return;
                    setState(() => _fontSize = EditorFontPrefs.def);
                    EditorFontPrefs.save(_fontSize);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      _fontSize.toStringAsFixed(
                          _fontSize.truncateToDouble() == _fontSize ? 0 : 1),
                      style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                          fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                ),
              ),
              _fontButton(Icons.text_increase, '放大字号（双指捏合亦可）', 1),
              const SizedBox(width: 4),
              // alpha.81：AI 按钮（仍放在字号那一栏——写代码时手就在
              // 这一行附近，且不与"保存/运行"等高频按钮抢位置）。
              // 单点 = 补全；长按 = 弹输入栏下达指令。
              if (widget.onAiComplete != null ||
                  widget.onAiInstruct != null) ...[
                Tooltip(
                  message: 'AI：单点补全代码 · 长按输入要求',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _emitAi(widget.onAiComplete),
                    onLongPress: () => _emitAi(widget.onAiInstruct),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      child: Icon(Icons.auto_awesome,
                          size: 16, color: Color(0xFF4C8DFF)),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                _languageName,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 字号步进按钮（±1，夹在 min/max）。
  ///
  /// 可发现性修复：原先图标仅 14px、灰色、贴在内边距 5px 上，
  /// 手机上看不清也难点（远小于 44px 的最小可点尺寸），用户甚至以为
  /// 「只能靠双指捏合缩放」。现在图标放大到 17px、用正文色提高对比，
  /// 左右各留 8px 内边距，实际可点区域约 33x24——状态栏高度所限已是
  /// 上限，故再加一条 tooltip 之外的可见提示（见 _maybeShowFontHint）。
  Widget _fontButton(IconData icon, String tip, double delta) {
    final atLimit = delta < 0
        ? _fontSize <= EditorFontPrefs.min
        : _fontSize >= EditorFontPrefs.max;
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () {
          final v = (_fontSize + delta)
              .clamp(EditorFontPrefs.min, EditorFontPrefs.max);
          if (v == _fontSize) return;
          setState(() => _fontSize = v);
          EditorFontPrefs.save(_fontSize);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Icon(
            icon,
            size: 17,
            color: atLimit ? Colors.grey.shade700 : Colors.grey.shade300,
          ),
        ),
      ),
    );
  }

  void _showIssues() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('语法问题（${_issues.length}）'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final issue in _issues)
                ListTile(
                  dense: true,
                  leading: Icon(Icons.error_outline,
                      color: FoaColors.of(context).danger, size: 18),
                  title: Text(
                    issue.message,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text('第 ${issue.line} 行',
                      style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    _identTimer?.cancel();
    _codeScroll?.removeListener(_onCodeScroll);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }
}

/// compute 隔离线程内的 Dart 格式化入口（top-level 函数，供 compute 调用）。
/// dart_style 3.x 构造器必填 languageVersion，用其自带的最新版本。
String _formatDartSource(String src) => DartFormatter(
      languageVersion: DartFormatter.latestLanguageVersion,
    ).format(src);

/// 文件内搜索对话框：关键词 → 匹配数 → 上一个/下一个循环跳转（Bug 218）。
/// 直接操作 CodeController 的 selection，EditableText 自动滚动到匹配处。
class _SearchDialog extends StatefulWidget {
  final CodeController controller;
  const _SearchDialog({required this.controller});

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final TextEditingController _kw = TextEditingController();
  List<RegExpMatch> _matches = const [];
  int _index = -1;

  @override
  void dispose() {
    _kw.dispose();
    super.dispose();
  }

  void _search() {
    final q = _kw.text;
    if (q.isEmpty) {
      setState(() {
        _matches = const [];
        _index = -1;
      });
      return;
    }
    final all = RegExp(RegExp.escape(q), caseSensitive: false)
        .allMatches(widget.controller.text)
        .toList();
    setState(() {
      _matches = all;
      _index = all.isEmpty ? -1 : 0;
    });
    if (all.isNotEmpty) _jump(0);
  }

  void _jump(int i) {
    if (_matches.isEmpty) return;
    final m = _matches[i];
    widget.controller.value = widget.controller.value.copyWith(
      selection: TextSelection(baseOffset: m.start, extentOffset: m.end),
      composing: TextRange.empty,
    );
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('搜索'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _kw,
            autofocus: true,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: const InputDecoration(
              hintText: '输入关键词（不区分大小写）',
              isDense: true,
            ),
            onSubmitted: (_) => _search(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                _matches.isEmpty
                    ? (_kw.text.isEmpty ? '' : '无匹配')
                    : '${_index + 1} / ${_matches.length}',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const Spacer(),
              IconButton(
                tooltip: '上一个',
                visualDensity: VisualDensity.compact,
                onPressed: _matches.isEmpty
                    ? null
                    : () =>
                        _jump((_index - 1 + _matches.length) % _matches.length),
                icon: const Icon(Icons.keyboard_arrow_up),
              ),
              IconButton(
                tooltip: '下一个',
                visualDensity: VisualDensity.compact,
                onPressed: _matches.isEmpty
                    ? null
                    : () => _jump((_index + 1) % _matches.length),
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 编辑器字号偏好（alpha.32）：存 filesDir/editor-font.json。
///
/// CodeEditor 不持有 EnvInfo——经 ProotBridge.envInfo() 异步取一次
///（与构建页 BackendPrefs 同款路径布局；解析/IO 失败一律回退默认值，
/// 字号偏好只是体验增强，任何异常都不该拦着打开编辑器）。
class EditorFontPrefs {
  static const double def = 14.0;
  static const double min = 9.0;
  static const double max = 28.0;

  static Future<double> load() async {
    try {
      final env = await ProotBridge().envInfo();
      final f = File('${env.filesDir}/editor-font.json');
      if (!await f.exists()) return def;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return def;
      final v = (raw['fontSize'] as num?)?.toDouble() ?? def;
      return v.clamp(min, max).toDouble();
    } catch (_) {
      return def;
    }
  }

  static Future<void> save(double v) async {
    try {
      final env = await ProotBridge().envInfo();
      final f = File('${env.filesDir}/editor-font.json');
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({'fontSize': v}));
    } catch (_) {}
  }
}
