import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/editor/editor_page.dart';
import 'package:foaide/editor/fs_bridge.dart';

/// alpha.91 回归：`reloadFromDisk` 之后 `_dirty` 必须为 **false**。
///
/// ## 这个 bug 是什么
///
/// `reloadFromDisk()` 原本把两件事的顺序写反了：
///
/// ```dart
/// setState(() { _content = r.content; _initialContent = r.content; _dirty = false; });
/// _editorKey.currentState?.reset(r.content);   // ← 这一行会反过来把 _dirty 置真
/// ```
///
/// `reset()` 内部走的是 `_controller.value = TextEditingValue(...)`
///（`code_editor.dart:509`），而 `CodeController` 上挂着 `_onChanged`
///（`code_editor.dart:245`）→ `widget.onContentChanged(text)` →
/// EditorPage 的 `if (!_dirty) setState(() => _dirty = true)`（`:1349`）。
/// 因为此时 `_dirty` 刚被置成 false，守卫 `!_dirty` **恰好通过**，
/// 于是 `_dirty` 又被顶回 true。
///
/// ## 为什么这个 bug 值得专门写测试
///
/// 它**不报错、不崩溃、无日志**，症状只有一个：每次「从磁盘重新载入」后，
/// 文件名旁边立刻多出一个未保存小圆点。危害不是"看着别扭"：
///
///   1. 用户以为自己打开了脏文件 → 再点一次保存 → 一次无意义的写盘；
///   2. 更糟的是 `_confirmSaveIfDirty()`（`:203`）的守卫是
///      `if (!_dirty) return true;` —— 假脏会在**用户切文件**时
///      弹「未保存的修改」对话框，而其实一个字都没改。
///      这正是"同步完立刻切走"这条最自然的操作路径。
///
/// 正确顺序见同文件的 `_rollbackAi()`（`:1150-1162`）：**先 `reset`
/// 再 `setState`**，让复位引发的回调先发生，再用显式赋值把状态钉死。
///
/// ## 这个测试为什么是"真"的
///
/// 挂**真的 `EditorPage`**、用**真的输入**制造脏状态、走**真的
/// `reloadFromDisk()`**，断言**用户看得见的东西**（标题旁那个绿点 /
/// 切文件时到底弹不弹框）。不是源码字符串匹配，所以把顺序改回去它
/// **一定会红**——这是它区别于"假测试"的地方。
void main() {
  const path = '/root/projects/demo/lib/main.dart';
  const otherPath = '/root/projects/demo/lib/other.dart';

  late _MemBridge bridge;

  setUp(() {
    bridge = _MemBridge()
      ..files[path] = 'void main() {\n  print(1);\n}\n'
      ..files[otherPath] = '// other\n';
  });

  /// ⚠️ vendored `CodeField` 内部有**两个** `EditableText`：
  /// 行号列（`LineNumberController`，readOnly、右对齐）和代码列。
  /// `find.byType(EditableText).first` 命中的是**行号列**——它 readOnly，
  /// `enterText` 根本打不进去，而且 `tap` 会报 hit-test 警告。
  /// 必须按 controller 区分（同 `editor_completion_test.dart:200` 的做法）。
  Finder codeEditable(WidgetTester tester) {
    final field = tester.widget<CodeField>(find.byType(CodeField));
    final c = field.controller;
    return find.byWidgetPredicate(
        (w) => w is EditableText && identical(w.controller, c));
  }

  /// 挂 EditorPage 并等到文件真正打开。
  Future<EditorPageState> pumpEditor(WidgetTester tester) async {
    // 给足高度，避免编辑区被压扁导致命中失败
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorPage(
          bridge: bridge,
          initialDir: '/root/projects/demo',
          initialPath: path,
          embed: true, // 内嵌：不建 Scaffold/AppBar/Drawer，宿主最小
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(CodeField), findsOneWidget, reason: '前置条件：编辑器应已打开文件');
    return tester.state<EditorPageState>(find.byType(EditorPage));
  }

  /// 往代码列真的打字，把编辑器弄脏。
  Future<void> typeIntoCode(WidgetTester tester, String text) async {
    await tester.enterText(codeEditable(tester), text);
    await tester.pumpAndSettle();
  }

  /// 未保存标记：文件名旁边那个 7×7 的绿点（`editor_page.dart:710-716`）。
  ///
  /// 用**可见 UI** 当判据，而不是去读私有 `_dirty`：测的正是
  /// "用户会不会看到一个假的未保存圆点"，这才是这个 bug 的实际危害。
  Finder dirtyDot() => find.byWidgetPredicate((w) =>
      w is Container &&
      w.constraints?.maxWidth == 7 &&
      w.constraints?.maxHeight == 7);

  testWidgets('重载后不应残留未保存标记（回归：reset 会反过来把 _dirty 置真）',
      (tester) async {
    final st = await pumpEditor(tester);

    // ① 先弄脏。
    await typeIntoCode(tester, 'void main() {\n  print(2);\n}\n');
    expect(dirtyDot(), findsOneWidget,
        reason: '前置条件不成立：打完字应处于"未保存"状态，否则后面的断言没有意义');

    // ② 从磁盘重新载入。
    await st.reloadFromDisk(skipConfirm: true);
    await tester.pumpAndSettle();

    // ③ 核心断言。
    expect(dirtyDot(), findsNothing,
        reason: '重载后编辑器内容 == 磁盘内容，不该再显示未保存标记。'
            '出现说明 reloadFromDisk 里 reset() 与 setState() 的顺序反了：'
            'reset 触发的 onContentChanged 把刚落下的 _dirty=false 又顶回 true。');
  });

  testWidgets('重载后内容确实换成了磁盘上的版本', (tester) async {
    final st = await pumpEditor(tester);

    await typeIntoCode(tester, '本地乱改的内容\n');

    // 磁盘上被人（远程 AI / 别的进程）改了。
    bridge.files[path] = 'void main() {\n  print(999);\n}\n';
    await st.reloadFromDisk(skipConfirm: true);
    await tester.pumpAndSettle();

    expect(find.textContaining('999'), findsWidgets,
        reason: '重载必须把磁盘内容读进来（否则这个入口本身就是坏的）');
    expect(find.textContaining('本地乱改的内容'), findsNothing,
        reason: '重载要把本地未保存的改动丢弃掉');
  });

  testWidgets('重载后能干净地切走文件：不该弹「未保存的修改」', (tester) async {
    final st = await pumpEditor(tester);

    await typeIntoCode(tester, 'dirty content\n');

    await st.reloadFromDisk(skipConfirm: true);
    await tester.pumpAndSettle();

    // 换文件。`_confirmSaveIfDirty()` 的守卫是 `if (!_dirty) return true;`，
    // 所以假脏状态会在这里拦下一个完全没有改动需要保存的切换。
    // 直接用 `unawaited` 风格起这个 future 再 pump：若弹了对话框，
    // openFile 会停在那里等用户点击，正好能把"弹了"这件事断出来。
    final opening = st.openFile(otherPath);
    await tester.pumpAndSettle();

    expect(find.text('未保存的修改'), findsNothing,
        reason: '重载之后没有任何未保存改动，切文件不该被拦；'
            '被拦住说明 _dirty 是假脏（这正是本 bug 的真实用户可见危害）');

    // 没有弹框时 openFile 应该已经跑完并切过去了。
    await opening;
    await tester.pumpAndSettle();
    expect(find.textContaining('// other'), findsWidgets,
        reason: '应该已经顺利切到另一个文件');
  });
}

/// 内存版 FsBridge（与 `ai_editor_wiring_test` 的 `_MemBridge` 同思路）。
class _MemBridge extends FsBridge {
  final Map<String, String> files = <String, String>{};

  @override
  Future<FsReadResult> read(String path) async {
    final c = files[path];
    return c == null
        ? const FsReadResult(ok: false, error: 'ENOENT')
        : FsReadResult(ok: true, content: c);
  }

  @override
  Future<FsResult> write(String path, String content) async {
    files[path] = content;
    return const FsResult(ok: true);
  }

  @override
  Future<FsListResult> list(String path) async =>
      const FsListResult(ok: true, entries: []);
}
