import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/editor/editor_page.dart';
import 'package:foaide/editor/fs_bridge.dart';
import 'package:foaide/events/native_events.dart';

/// alpha.91 端到端：**外部改了文件，编辑器自己跟上，用户不用手动加载**。
///
/// ## 这组测试要钉住的用户诉求
///
/// 用户原话：**"不需要用户手动从磁盘加载覆盖"**。
///
/// 改造前的问题是 MCP 路径下"还是要手动从磁盘重新载入"，原因有两层：
///   1. 监听只在"派活之后"才开，别的外部改动完全感知不到；
///   2. 即便开着，也是**报一次就自停**，第二轮起就哑了。
///
/// 现在：打开任意文件就常驻监听 → 外部一改就自动同步（无脏改动时）。
///
/// ## 为什么这组测试能真的证明功能可用
///
/// 它走**完整的真实链路**：真 `EditorPage` → 真 `NativeFileChangeSource`
/// → 假的原生通道（发一条真 `fsChange` 事件）→ 真的读盘 → 真的更新 UI。
/// 从"事件到达"到"编辑器内容变了"每一步都是生产代码。
///
/// 唯一被替换的是"原生 FileObserver 什么时候发事件"这件事本身——
/// 那部分逻辑在 Kotlin 里，Dart 侧无法测（项目惯例：Kotlin 侧零测试，
/// 用源码扫描代替，见 native_events_test.dart）。
void main() {
  const path = '/root/projects/demo/lib/main.dart';

  TestWidgetsFlutterBinding.ensureInitialized();

  late _MemBridge bridge;

  setUp(() {
    bridge = _MemBridge()..files[path] = 'void main() {\n  print(1);\n}\n';
    // 自动同步默认开，但持久化读的是假 env；这里直接让原生监听可用，
    // 走主路径（降级路径另有 native_file_change_source_test 覆盖）。
    _FakeNative(available: true).install();
    NativeEvents.resetForTest();
    NativeEvents.ensureHandler();
  });

  tearDown(() {
    _FakeNative.uninstall();
    NativeEvents.resetForTest();
  });

  /// vendored CodeField 内部有**两个** EditableText（行号列 + 代码列），
  /// 必须按 controller 区分出代码列 —— 否则 enterText 打在只读的行号列上。
  Finder codeEditable(WidgetTester tester) {
    final field = tester.widget<CodeField>(find.byType(CodeField));
    final c = field.controller;
    return find.byWidgetPredicate(
        (w) => w is EditableText && identical(w.controller, c));
  }

  Future<EditorPageState> pumpEditor(WidgetTester tester) async {
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
          embed: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return tester.state<EditorPageState>(find.byType(EditorPage));
  }

  /// 模拟原生侧推来一条文件变更事件（真实链路上由 FileObserver 触发）。
  Future<void> emitFsChange(String p) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'dev.foa/proot',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('fsChange', {'path': p, 'seq': 1}),
      ),
      (_) {},
    );
  }

  Finder dirtyDot() => find.byWidgetPredicate((w) =>
      w is Container &&
      w.constraints?.maxWidth == 7 &&
      w.constraints?.maxHeight == 7);

  group('核心诉求：外部改了 → 编辑器自己跟上，不用手动加载', () {
    testWidgets('无脏改动：外部写文件 → 编辑器内容自动更新（零手动操作）',
        (tester) async {
      await pumpEditor(tester);
      expect(find.textContaining('print(1)'), findsWidgets);

      // 磁盘被人改了（远程 AI / 别的进程）
      bridge.files[path] = 'void main() {\n  print(42);\n}\n';
      await emitFsChange(path);
      await tester.pumpAndSettle();

      expect(find.textContaining('print(42)'), findsWidgets,
          reason: '这就是用户要的：外部改完编辑器自己就更新了，'
              '不需要他去点「从磁盘重新载入」');
      expect(find.textContaining('print(1)'), findsNothing);
    });

    testWidgets('自动同步之后不该留下未保存标记（顺序 bug 的回归）',
        (tester) async {
      // 自动同步比手动重载更容易踩"先 setState 再 reset"那个坑：
      // 它发生得频繁且没有用户操作做掩护，假脏会静默堆积。
      await pumpEditor(tester);
      expect(dirtyDot(), findsNothing);

      bridge.files[path] = 'void main() {\n  print(7);\n}\n';
      await emitFsChange(path);
      await tester.pumpAndSettle();

      expect(dirtyDot(), findsNothing,
          reason: '同步完内容与磁盘一致，不该显示未保存标记');
    });

    testWidgets('外部连改 3 次 → 3 次都跟上（修掉"只报一次就自停"）',
        (tester) async {
      // alpha.83 的 AiFileWatcher 报一次就 stop()，外部 AI 连改多轮
      // 只有第一轮看得见。这是本轮改造要修掉的第二个病灶。
      await pumpEditor(tester);

      for (final v in ['11', '22', '33']) {
        bridge.files[path] = 'void main() {\n  print($v);\n}\n';
        await emitFsChange(path);
        await tester.pumpAndSettle();
        expect(find.textContaining('print($v)'), findsWidgets,
            reason: '第 $v 轮改动也要跟得上，不能只有第一次生效');
      }
    });

    testWidgets('自己保存不算外部变更：不该给自己弹 diff', (tester) async {
      // 原生监听只看 inode 事件，**分不清谁写的**——自己保存同样会
      // 触发 fsChange。若不按内容去重，用户每保存一次就给自己弹一个
      // diff 预览，非常荒唐。靠 _onDiskChanged 里的内容比对兜住。
      await pumpEditor(tester);

      // 模拟"用户编辑 + 保存"：编辑器内容与磁盘一致，然后收到事件
      await tester.tap(codeEditable(tester));
      await tester.pump();
      await tester.enterText(codeEditable(tester), 'void main() {\n  print(9);\n}\n');
      await tester.pumpAndSettle();
      bridge.files[path] = 'void main() {\n  print(9);\n}\n'; // 保存落盘

      await emitFsChange(path);
      await tester.pumpAndSettle();

      expect(find.text('远程 AI 改了文件'), findsNothing,
          reason: '内容一致 → 自己刚保存的 → 不该弹 diff 打扰');
      expect(find.textContaining('print(9)'), findsWidgets);
    });

    testWidgets('不是当前文件的事件 → 忽略（别串台）', (tester) async {
      await pumpEditor(tester);

      bridge.files[path] = 'void main() {\n  print(1);\n}\n'; // 保持不变
      await emitFsChange('/root/projects/demo/lib/other.dart');
      await tester.pumpAndSettle();

      expect(find.textContaining('print(1)'), findsWidgets);
      expect(dirtyDot(), findsNothing);
    });

    testWidgets('事件指向的文件读不到（被删 / 写到一半）→ 静默，不炸',
        (tester) async {
      await pumpEditor(tester);

      bridge.files.remove(path); // 文件没了
      await emitFsChange(path);
      await tester.pumpAndSettle();

      // 没崩就算过；编辑器保持原样（不清空、不报错弹窗）
      expect(find.byType(CodeField), findsOneWidget);
    });
  });

  group('有脏改动时 → 弹 diff 让用户决定（不静默覆盖他的东西）', () {
    testWidgets('本地有未保存改动 + 外部改文件 → 弹 diff 抽屉，不自动覆盖',
        (tester) async {
      await pumpEditor(tester);

      // 用户正在写，尚未保存
      await tester.tap(codeEditable(tester));
      await tester.pump();
      await tester.enterText(codeEditable(tester), '我的未保存改动\n');
      await tester.pumpAndSettle();
      expect(dirtyDot(), findsOneWidget, reason: '前置条件：应处于脏状态');

      // 此时外部改了同一个文件
      bridge.files[path] = 'void main() {\n  print(1234);\n}\n';
      await emitFsChange(path);
      await tester.pumpAndSettle();

      // 关键：**不能**静默覆盖用户正在写的东西
      expect(find.text('远程 AI 改了文件'), findsOneWidget,
          reason: '有脏改动必须问一句；静默覆盖会吞掉用户没保存的工作');
      expect(find.textContaining('我的未保存改动'), findsWidgets,
          reason: '在用户做决定之前，他写的内容必须原样还在');

      // 抽屉里应该有"你本地还有未保存的修改"的警告
      expect(find.textContaining('未保存的修改'), findsWidgets);
    });

    testWidgets('点「忽略」→ 保留本地改动，磁盘版不进来', (tester) async {
      await pumpEditor(tester);

      await tester.tap(codeEditable(tester));
      await tester.pump();
      await tester.enterText(codeEditable(tester), '我的未保存改动\n');
      await tester.pumpAndSettle();

      bridge.files[path] = 'void main() {\n  print(1234);\n}\n';
      await emitFsChange(path);
      await tester.pumpAndSettle();

      await tester.tap(find.text('忽略'));
      await tester.pumpAndSettle();

      expect(find.textContaining('我的未保存改动'), findsWidgets,
          reason: '选"忽略"就该保住用户的东西');
      expect(find.textContaining('1234'), findsNothing);
    });

    testWidgets('点「载入」→ 盖上磁盘版，且不残留假脏', (tester) async {
      await pumpEditor(tester);

      await tester.tap(codeEditable(tester));
      await tester.pump();
      await tester.enterText(codeEditable(tester), '我的未保存改动\n');
      await tester.pumpAndSettle();

      bridge.files[path] = 'void main() {\n  print(1234);\n}\n';
      await emitFsChange(path);
      await tester.pumpAndSettle();

      await tester.tap(find.text('载入'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1234'), findsWidgets,
          reason: '选"载入"就该用磁盘版覆盖');
      expect(dirtyDot(), findsNothing,
          reason: '载入后内容与磁盘一致，不该留未保存标记');
    });
  });

  group('边界：AI 生成中不打扰', () {
    testWidgets('AI 占位期间外部事件到达 → 不弹 diff（会冲掉占位）',
        (tester) async {
      // AI 生成期间编辑区里有占位空行，此时的"外部改动"若触发载入，
      // 占位区间会错位 —— 而回滚是按区间删的，会**删错内容**。
      final st = await pumpEditor(tester);

      // 进入 AI 占位态（生产路径上由 _runAiFlow 设置）。
      st.beginAiPlaceholderForTest();

      // ⚠️ 这里**不能用 pumpAndSettle**：AI 生成期间顶部有进度条
      // （`CodeEditor.aiBusy` 驱动的 indeterminate 动画），它永不结束，
      // `pumpAndSettle` 会一直等到超时。用有界的 `pump` 驱动足够——
      // 要验证的只是"事件处理有没有弹窗"，不是"动画跑完没有"。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      bridge.files[path] = 'void main() {\n  print(555);\n}\n';
      await emitFsChange(path);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('远程 AI 改了文件'), findsNothing,
          reason: 'AI 正在写的时候别插一脚；事件丢了没关系，'
              'AI 流程结束后还有下一次事件 / 手动重载兜底');
      expect(find.textContaining('555'), findsNothing);
    });
  });
}

/// 内存盘。
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

/// 假的 `dev.foa/proot`：只回答 fsWatchStart / fsWatchStop。
class _FakeNative {
  _FakeNative({required this.available});

  /// false = 模拟旧 APK（MissingPluginException）→ 触发降级。
  final bool available;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dev.foa/proot'),
      (call) async {
        switch (call.method) {
          case 'fsWatchStart':
            if (!available) {
              throw MissingPluginException('no impl for ${call.method}');
            }
            return true;
          case 'fsWatchStop':
            return true;
          default:
            return null;
        }
      },
    );
  }

  static void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.foa/proot'), null);
  }
}
