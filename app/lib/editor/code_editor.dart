import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/material.dart';
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

/// 代码编辑器：语法高亮 + 行号 + 等宽字体。
///
/// 基于 CodeField（TextField 子类），IME 中文输入、光标管理、
/// 滚动性能均继承 TextField 原生行为；500 行文件无压力。
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

  @override
  void initState() {
    super.initState();
    _controller = CodeController(text: widget.initialContent, language: _language);
    _controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant CodeEditor old) {
    super.didUpdateWidget(old);
    // 切换文件：以旧控制器内容为准（可能含未保存编辑），重建控制器
    if (old.path != widget.path) {
      _controller.dispose();
      _controller = CodeController(text: widget.initialContent, language: _language);
      _controller.addListener(_onChanged);
    }
  }

  void _onChanged() {
    widget.onContentChanged(_controller.text);
  }

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

  @override
  Widget build(BuildContext context) {
    return CodeField(
      controller: _controller,
      focusNode: _focus,
      expands: true,
      decoration: const BoxDecoration(),
      cursorColor: const Color(0xFF3DDC84),
      textStyle: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 14,
        height: 1.5,
        color: Color(0xFFE6E6E6),
      ),
      lineNumberStyle: const LineNumberStyle(
        width: 46,
        textStyle: TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }
}
