import 'dart:async';

import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
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

  const CodeEditor({
    super.key,
    required this.path,
    required this.initialContent,
    required this.onContentChanged,
  });

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late CodeController _controller;
  final FocusNode _focus = FocusNode();

  final List<CompletionItem> _suggestions = [];
  Timer? _checkTimer;
  List<SyntaxIssue> _issues = const [];
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _controller = CodeController(
      text: widget.initialContent,
      language: _language,
    );
    _controller.addListener(_onChanged);
    _scheduleCheck(immediate: true);
  }

  @override
  void didUpdateWidget(covariant CodeEditor old) {
    super.didUpdateWidget(old);
    // 切换文件：以旧控制器内容为准（可能含未保存编辑），重建控制器
    if (old.path != widget.path) {
      _controller.dispose();
      _controller = CodeController(
        text: widget.initialContent,
        language: _language,
      );
      _controller.addListener(_onChanged);
      _issues = const [];
      _scheduleCheck(immediate: true);
    }
  }

  void _onChanged() {
    widget.onContentChanged(_controller.text);
    _updateSuggestions();
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
    final hits = matchCompletions(word);
    if (hits.isEmpty) {
      _hideSuggestions();
      return;
    }
    final changed = !listEquals(
      List.generate(hits.length, (i) => hits[i].word),
      List.generate(_suggestions.length, (i) => _suggestions[i].word),
    );
    if (changed && mounted) {
      setState(() => _suggestions
        ..clear()
        ..addAll(hits));
    }
  }

  void _hideSuggestions() {
    if (_suggestions.isNotEmpty && mounted) setState(_suggestions.clear);
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
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                // Bug 214 修复：1.1.0 起高亮主题由 CodeTheme widget 提供
                // （CodeController 的 theme 参数已废弃），不包 CodeTheme 则
                // highlight 产出的 span 无样式 → 语法高亮"不生效"
                child: CodeTheme(
                  data: const CodeThemeData(styles: monokaiSublimeTheme),
                  child: CodeField(
                    controller: _controller,
                    focusNode: _focus,
                    expands: true,
                    // 显式声明普通多行文本输入（非密码/数字变体），
                    // 避免厂商 ROM 的安全键盘误判（系统级设置仍需用户关闭）
                    keyboardType: TextInputType.multiline,
                    decoration: const BoxDecoration(),
                    cursorColor: const Color(0xFF3DDC84),
                    textStyle: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      height: 1.5,
                    ),
                    lineNumberStyle: const LineNumberStyle(
                      width: 46,
                      textStyle: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ),
              ),
              if (_suggestions.isNotEmpty)
                Positioned(left: 0, right: 0, bottom: 0, child: _buildSuggestionBar()),
            ],
          ),
        ),
        _buildStatusBar(),
      ],
    );
  }

  Widget _buildSuggestionBar() {
    return Container(
      height: 40,
      color: const Color(0xFF1C222B),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final s = _suggestions[i];
          return ActionChip(
            visualDensity: VisualDensity.compact,
            backgroundColor: const Color(0xFF232A35),
            side: BorderSide.none,
            avatar: Icon(_kindIcon(s.kind), size: 13, color: _kindColor(s.kind)),
            label: Text(
              s.word,
              style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Color(0xFFE6E6E6)),
            ),
            onPressed: () => _applySuggestion(s),
          );
        },
      ),
    );
  }

  static IconData _kindIcon(CompletionKind k) => switch (k) {
        CompletionKind.keyword => Icons.code,
        CompletionKind.snippet => Icons.bolt,
        CompletionKind.type => Icons.category_outlined,
        CompletionKind.method => Icons.functions,
      };

  static Color _kindColor(CompletionKind k) => switch (k) {
        CompletionKind.keyword => const Color(0xFFC586C0),
        CompletionKind.snippet => const Color(0xFFE5C07B),
        CompletionKind.type => const Color(0xFF4EC9B0),
        CompletionKind.method => const Color(0xFF61AFEF),
      };

  Widget _buildStatusBar() {
    final (Color color, IconData icon, String text) = _checking
        ? (Colors.grey.shade500, Icons.hourglass_empty, '检查中…')
        : _issues.isEmpty
            ? (const Color(0xFF3DDC84), Icons.check_circle_outline, '语法 OK')
            : (const Color(0xFFFF7A7A), Icons.error_outline, '${_issues.length} 个问题');
    return Material(
      color: const Color(0xFF161B21),
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
                  leading: const Icon(Icons.error_outline,
                      color: Color(0xFFFF7A7A), size: 18),
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
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }
}
