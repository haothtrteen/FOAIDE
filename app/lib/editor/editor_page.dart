import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai/ai_assist.dart';
import '../ai/ai_backend.dart';
import '../ai/ai_config.dart';
import '../ai/ai_file_watch.dart';
import '../ai/ai_inbox_view.dart';
import '../ai/diff.dart';
import '../ai/mcp_dispatch.dart';
import '../core/theme.dart';
import '../mcp/tunnel_service.dart';
import 'auto_sync_pref.dart';
import 'code_editor.dart';
import 'diff_sheet.dart';
import 'editor_last_file.dart';
import 'file_change_source.dart';
import 'file_tree.dart';
import 'fs_bridge.dart';
import 'native_file_change_source.dart';
import 'web_preview_page.dart';
import 'web_preview_service.dart';

/// Step 2 · 文件浏览器 + 代码编辑器。
///
/// 布局：文件浏览器以侧边栏形式嵌入编辑器——
/// 横屏常驻左栏（280px），竖屏收纳为 Drawer（AppBar 汉堡键展开），
/// 编辑区始终为主区域。
/// 文件 CRUD（新建/重命名/删除）在 FileTree 内自包含；
/// 本页负责打开文件、编辑、保存。
class EditorPage extends StatefulWidget {
  final FsBridge bridge;

  /// 初始浏览目录（alpha.33 项目工作台传入项目根）；缺省 = projects 根。
  final String? initialDir;

  /// 初始打开的文件（容器内路径）；缺省不打开。
  final String? initialPath;

  /// 内嵌模式（alpha.35 工作台融合）：不建 Scaffold/AppBar/Drawer，
  /// 输出「紧凑工具行 + 编辑面板」，供工作台内容区就地切换；
  /// 文件树由宿主提供（抽屉/横屏左栏），经 [EditorPageState.openFile]
  /// 联动。独立页模式（主页「编辑器」入口）完全不变。
  final bool embed;

  /// 单点 AI 补全入口（alpha.81）：编辑器把「当前文件 + 光标」报上来，
  /// 宿主拿去补全。由宿主注入，避免编辑器反向依赖
  /// 项目/MCP 等上层模块——编辑器保持"不知道 AI 是什么"的纯粹性。
  final void Function(EditorAiRequest)? onAiComplete;

  /// 长按 AI 入口（alpha.81）：编辑器报上来「用户想下达一条指令」，
  /// 本页负责弹输入栏收集指令文本，再把 (请求, 指令) 交给宿主。
  /// 输入栏留在编辑器页（它是输入体验的一部分），AI 仍在宿主侧。
  final void Function(EditorAiRequest, String)? onAiInstruct;

  /// 预览当前项目里某个页面的入口（alpha.72）。
  ///
  /// 参数是**容器内绝对路径**（`/root/projects/x/lib/login_page.dart`）——
  /// 就是当前正在编辑的这个文件。和 [onAiComplete] 同一个模式：
  /// 编辑器不知道"设计区"是什么，只负责把"用户想预览这个文件"这件事
  /// 报给宿主；宿主决定是切区、还是弹页面。
  final void Function(String path)? onPreviewDesign;

  /// 扫描项目所有页面并挑一个预览（alpha.72）。同上，由宿主注入。
  final VoidCallback? onPreviewProjectPages;

  /// 打开 AI 设置（alpha.81）：长按输入栏右上角的齿轮。内嵌模式没有
  /// 自己的 AppBar，这个入口是它唯一能进 AI 配置的地方。
  final VoidCallback? onOpenAiSettings;

  /// 跑一次 AI（alpha.82）：编辑器把「当前文件 + 光标 + 指令」打包成
  /// [AiJob] 交出去，宿主回一个 [AiOutcome]（内容 / 已派活 / 失败）。
  ///
  /// 为什么改成这个形状：alpha.81 是"宿主拿到结果后回调本页插入"，
  /// 宿主得回头找编辑器要插入点，流程是断的。alpha.82 要"AI 直接写进
  /// 编辑器、写完再问用户存不存"，**插入点只有编辑器自己知道**，所以
  /// 由本页主导：先预留占位，再向宿主要结果，最后自己落地。
  ///
  /// 边界仍然成立：本页认得的是 [AiJob] / [AiOutcome] 这两个**中性**
  /// 数据结构，不知道背后是内置 LLM 还是远程 MCP。
  final Future<AiOutcome> Function(AiJob job)? onRunAi;

  EditorPage(
      {super.key,
      FsBridge? bridge,
      this.initialDir,
      this.initialPath,
      this.embed = false,
      this.onAiComplete,
      this.onAiInstruct,
      this.onPreviewDesign,
      this.onPreviewProjectPages,
      this.onOpenAiSettings,
      this.onRunAi})
      : bridge = bridge ?? FsBridge();

  @override
  State<EditorPage> createState() => EditorPageState();
}

class EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  final GlobalKey<FileTreeState> _treeKey = GlobalKey();
  final GlobalKey<CodeEditorState> _editorKey = GlobalKey();

  String? _currentPath; // 当前打开文件（容器内路径）
  String _content = '';
  String _initialContent = ''; // 打开时的初始内容（撤销更改恢复点）
  bool _dirty = false;

  // ---- alpha.82 AI 生成中 ----
  /// 生成期间：编辑区只读 + 顶部进度条（见 CodeEditor.aiBusy）。
  ///
  /// ⚠️ 这是**给用户看**的状态（进度条、只读），要等 `setState` 才生效，
  /// 因此**不能拿它当防重入闸门**——见 [_aiRunning]。
  bool _aiBusy = false;

  /// AI 流程的**同步防重入闸门**（alpha.86）。
  ///
  /// 与 [_aiBusy] 分开是必须的：`_aiBusy` 要经过 `setState` 才置真，
  /// 而 `_runAiFlow` 在它之前还横着 `await _ensureAiReady()`（读配置 +
  /// 可能弹对话框）。连点两下时第二次点击正好落在那个 await 里，
  /// 看到 `_aiBusy` 仍是 false → 两个流程并行跑到派活 → 磁盘上多出
  /// 一条重复作业。同步字段在**任何 await 之前**就落闸，才挡得住。
  bool _aiRunning = false;

  /// AI 改之前的全文与 dirty 状态——用户点「放弃」时整体回滚到这两个值。
  String _aiBefore = '';
  bool _aiBeforeDirty = false;

  /// 派活后的磁盘监听（alpha.83）：远程 AI 经 MCP `write_file` 改文件
  /// 不会通知 App——轮询检测到外部变更就弹 diff 预览，让人像内置 LLM
  /// 一样「实时看到改动再决定要不要」。换文件 / 离开页面即停。
  ///
  /// alpha.91：这仍是**兜底**路径，只在自动同步被关掉、或原生监听
  /// 不可用时才接管。主路径见 [_diskSource]。
  AiFileWatcher? _aiWatch;

  /// alpha.91 自动同步：磁盘变更来源（原生 FileObserver，失败自动降级轮询）。
  ///
  /// 与 [_aiWatch] 是**两套独立机制**，别混淆：
  ///
  /// | | [_aiWatch]（alpha.83） | [_diskSource]（alpha.91） |
  /// |---|---|---|
  /// | 触发次数 | 报一次就自停 | 常驻，每次都报 |
  /// | 回调给什么 | 磁盘新内容 | 只有路径 |
  /// | 无脏改动时 | 也弹 diff 问一句 | **静默自动更新** |
  /// | 用途 | 派活后的一次性提示 | 常态化的实时同步 |
  ///
  /// 两者**同时只会有一个在跑**：[_startDiskWatch] 会先停掉本字段
  /// （见那里的注释）。
  FileChangeSource? _diskSource;

  /// alpha.91「自动同步」开关的用户选择。null = 还没读出来（默认视为开）。
  bool? _autoSyncPref;

  @override
  void initState() {
    super.initState();
    // alpha.91：前台恢复时补读一次（进程冻结期间原生推的事件会丢，
    // 见 NativeFileChangeSource.onResumed 的注释）。
    WidgetsBinding.instance.addObserver(this);
    AutoSyncPref.load().then((v) {
      if (!mounted) return;
      setState(() => _autoSyncPref = v);
      // ⚠️ 读盘是异步的，可能**晚于** openFile 返回。若那时
      // `_startAutoSync` 已经因为在跑（用默认值"开"启动过），这里是
      // 幂等的重复启动；若用户实际设的是"关"，则要把已经起来的监听停掉。
      // 少了这一段，"用户关掉自动同步"这个偏好对**本次启动的第一个文件**
      // 会失效——第二次打开文件才生效，表现为"设置时灵时不灵"。
      final p = _currentPath;
      if (p == null) return;
      if (v) {
        _startAutoSync(p);
      } else {
        _diskSource?.stop();
        _diskSource = null;
      }
    });
    // alpha.33 项目工作台：从指定文件直接进入编辑（首帧后打开，避免
    // build 前改状态；失败静默——编辑器照常空态展示）
    final p = widget.initialPath;
    if (p != null && p.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => openFile(p));
    } else if ((widget.initialDir ?? '').isNotEmpty) {
      // alpha.34 代码区融合：工作台「代码」直达编辑器时自动恢复——
      // 优先上次编辑的文件，无记录（或已删除）回退 lib/main.dart
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreLast());
    }
  }

  /// alpha.91：回到前台时补读。冻结/被杀期间的事件收不到，只能主动查一次。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    (_diskSource as NativeFileChangeSource?)?.onResumed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _aiWatch?.stop();
    _diskSource?.stop();
    super.dispose();
  }

  /// 恢复上次编辑位置：EditorLastFile 记录 → lib/main.dart 兜底。
  /// 先探测可读再打开（不弹"读取失败"toast——恢复失败静默降级）。
  Future<void> _restoreLast() async {
    final dir = widget.initialDir!;
    final last = await EditorLastFile.get(dir);
    if (last != null && last.isNotEmpty) {
      final probe = await widget.bridge.read(last);
      if (probe.ok) {
        if (mounted) await openFile(last);
        return;
      }
    }
    // 无记录（或上次文件已删）→ lib/main.dart 兜底；再没有就空态展示
    final fallbackPath = '$dir/lib/main.dart';
    final fallback = await widget.bridge.read(fallbackPath);
    if (fallback.ok && mounted) await openFile(fallbackPath);
  }

  // ---------------- 文件操作 ----------------

  Future<void> openFile(String path) async {
    if (path == _currentPath) return;
    final proceed = await _confirmSaveIfDirty();
    if (!proceed) return;
    final r = await widget.bridge.read(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '读取失败');
      return;
    }
    // 换文件：旧文件的磁盘监听没有意义了（外部 AI 改的也是旧文件）
    _aiWatch?.stop();
    _diskSource?.stop();
    setState(() {
      _currentPath = path;
      _content = r.content;
      _initialContent = r.content;
      _dirty = false;
    });
    // alpha.91：打开文件就挂上常驻同步（不再只在 MCP 派活后）。
    // 用户要的是"外部改了不用手动加载"，那监听就得是常态的，而不是
    // 猜"这次改动是不是派活引起的"。
    _startAutoSync(path);
    // 记住最后打开的文件（alpha.34）：下次直达编辑器自动恢复此位置
    final dir = widget.initialDir;
    if (dir != null && dir.isNotEmpty) EditorLastFile.set(dir, path);
    // 若从 Drawer（竖屏侧边栏）打开文件，收起抽屉让编辑器全屏可见
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isDrawerOpen) {
      Navigator.of(context).pop();
    }
  }

  Future<bool> _confirmSaveIfDirty() async {
    if (!_dirty) return true;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的修改'),
        content: const Text('当前文件有未保存的修改，是否先保存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('放弃修改'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (choice == 'cancel') return false;
    if (choice == 'save') return await _save();
    return true; // discard
  }

  Future<bool> _save() async {
    if (_currentPath == null) return false;
    final r = await widget.bridge.write(_currentPath!, _content);
    if (!mounted) return false;
    if (!r.ok) {
      _toast(r.error ?? '保存失败');
      return false;
    }
    setState(() => _dirty = false);
    // 自己保存的不算"远程 AI 改动"——推进监听基线，否则下一轮轮询
    // 会把刚保存的内容误报成外部变更
    _aiWatch?.bumpBaseline(_content);
    // alpha.59「保存即刷新」：预览运行中，保存本身就是最可靠的"文件
    // 变更"信号——直接热重载，替代手动按键/第三方文件监控工具
    //（flutsim 卖点的零成本实现：挂到保存动作上，无轮询）
    var msg = '已保存';
    if (WebPreviewService.I.status == WebPreviewStatus.running) {
      final err = await WebPreviewService.I.hotReload();
      if (err == null) msg = '已保存 · 已触发热重载';
    }
    _toast(msg);
    _treeKey.currentState?.reload();
    return true;
  }

  // ---------------- 顶栏操作（Bug 218） ----------------

  /// 撤销更改：编辑器内容与 dirty 状态恢复为打开时。
  void _revert() {
    if (_currentPath == null) return;
    _editorKey.currentState?.reset(_initialContent);
    setState(() {
      _content = _initialContent;
      _dirty = false;
    });
    _toast('已撤销更改');
  }

  /// 转到行：对话框输入行号 → 编辑器跳转。
  Future<void> _showGoToLine() async {
    final lineStr = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('转到行'),
          content: TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: const InputDecoration(
              hintText: '输入行号',
              isDense: true,
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('跳转'),
            ),
          ],
        );
      },
    );
    final line = int.tryParse(lineStr ?? '');
    if (line != null && line > 0) {
      _editorKey.currentState?.jumpToLine(line);
    }
  }

  /// 更多菜单：格式化 / 帮助链接。
  Future<void> _onMenuSelected(String value) async {
    switch (value) {
      case 'format':
        final err = await _editorKey.currentState?.formatCode();
        _toast(err ?? '格式化完成');
        break;
      case 'reload':
        await reloadFromDisk();
        break;
      case 'auto_sync':
        await _toggleAutoSync();
        break;
      case 'ai_inbox':
        await _showAiInbox();
        break;
      case 'dart_docs':
        await _launchUrl('https://dart.dev/guides');
        break;
      case 'flutter_api':
        await _launchUrl('https://api.flutter.dev/');
        break;
    }
  }

  Future<void> _launchUrl(String url) async {
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) _toast('无法打开链接');
  }

  // ---------------- 实时运行预览（alpha.57） ----------------

  /// 预览按钮：运行中单击 = 直达热重载（改代码后最短路径），
  /// 控制台入口放 SnackBar action；否则打开预览控制台页（idle 自动启动）。
  Future<void> _onPreviewTap() async {
    final svc = WebPreviewService.I;
    if (svc.status == WebPreviewStatus.running) {
      final err = await svc.hotReload();
      if (!mounted) return;
      if (err != null) {
        _toast(err);
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: const Text('已触发热重载'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: '预览控制台',
            onPressed: () => _openPreviewPage(),
          ),
        ));
      return;
    }
    await _openPreviewPage();
  }

  Future<void> _openPreviewPage() async {
    final root = await _resolveProjectRoot();
    if (!mounted) return;
    if (root == null) {
      _toast('未定位到项目根（需先打开项目内文件）');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WebPreviewPage(projectRoot: root),
    ));
  }

  /// 设计预览（alpha.72）：把当前编辑的这个文件送进设计区预览。
  ///
  /// ## 为什么是"当前文件"而不是整个项目
  ///
  /// 用户此刻的注意力就在这个文件上 —— 他刚改完 `login_page.dart`
  /// 想看效果，最可能想看的就是它。整项目扫描作为菜单里的第二项，
  /// 需要跨文件的时候再用。
  ///
  /// 宿主没注入回调时（编辑器独立页模式）退回 Web 预览 ——
  /// 独立页没有设计区可切，硬弹一个 toast 说"不支持"不如给他
  /// 唯一一条真能出东西的路。
  void _openDesignPreview() {
    final path = _currentPath;
    if (path == null) {
      _toast('先打开一个文件');
      return;
    }
    final cb = widget.onPreviewDesign;
    if (cb == null) {
      _openPreviewPage();
      return;
    }
    cb(path);
  }

  /// 扫描项目页面并挑一个预览（alpha.72）。
  void _openProjectPagePreview() {
    final cb = widget.onPreviewProjectPages;
    if (cb == null) {
      _openPreviewPage();
      return;
    }
    cb();
  }

  /// 定位当前编辑文件所属 Flutter 项目根（预览入口用）：
  /// 优先工作台传入的 initialDir（pubspec 校验），否则从当前文件
  /// 向上找 pubspec.yaml。探测走 Kotlin 文件通道（FsBridge.read），
  /// 不占 proot executor——预览/构建运行时该入口仍可用。
  Future<String?> _resolveProjectRoot() async {
    final dir = widget.initialDir;
    if (dir != null && dir.isNotEmpty) {
      final probe = await widget.bridge.read('$dir/pubspec.yaml');
      if (probe.ok) return dir;
    }
    final p = _currentPath;
    if (p == null) return null;
    const projectsRoot = '/root/projects';
    var d = p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : p;
    while (d.startsWith('$projectsRoot/') && d != projectsRoot) {
      final probe = await widget.bridge.read('$d/pubspec.yaml');
      if (probe.ok) return d;
      final idx = d.lastIndexOf('/');
      if (idx <= projectsRoot.length) break;
      d = d.substring(0, idx);
    }
    return null;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ---------------- 布局 ----------------

  @override
  Widget build(BuildContext context) {
    if (widget.embed) {
      // 内嵌模式（alpha.35 工作台融合）：无 Scaffold/AppBar/Drawer，
      // 输出「紧凑工具行 + 编辑面板」；文件树由宿主（工作台抽屉/
      // 横屏左栏）提供，openFile 跨组件联动。
      return _buildEmbedBody();
    }
    // Bug 613：宽度阈值判"常驻侧栏"，不用 OrientationBuilder（详见
    // drawer 处的注释——键盘会把窗口压矮导致 orientation 误翻转）。
    return Builder(
      builder: (context) {
        final wide = MediaQuery.sizeOf(context).width >= 600;
        return Scaffold(
          appBar: AppBar(
            // Bug 218：顶栏只显示当前文件名（完整路径放长按提示），
            // 长路径不再把按钮挤掉
            title: _currentPath == null
                ? const Text('项目文件')
                : Tooltip(
                    message: _currentPath!,
                    child: Text(
                      _currentPath!.split('/').last,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
            actions: _editorActions(),
          ),
          // 竖屏：文件浏览器收纳为侧边栏 Drawer（AppBar 自动显示汉堡键）。
          // 注意：Drawer 是全高浮层（从屏幕顶端开始），内容必须 SafeArea
          // 避让状态栏，否则顶部导航条与状态栏重叠（真机 Bug 213）。
          //
          // ⚠️ Bug 613（与 project_page 同病）：此处**不许再用
          // OrientationBuilder/MediaQuery.orientation** 判断。adjustResize 下
          // 键盘弹出会把窗口压矮 → orientation 翻转 → 文件树 Drawer 与常驻
          // 左栏来回切换、编辑区 State 销毁（正在编辑的内容/光标/补全状态
          // 全丢）。用**宽度阈值**：键盘只压高度不压宽度，天然免疫。
          drawer:
              wide ? null : Drawer(child: SafeArea(child: _buildTreePanel())),
          // 树结构恒定（Row + 条件 children）：旋转时编辑面板的位置不变，
          // Element/State 保活——否则旋转一次，未保存内容与滚动位置全丢。
          body: Row(
            children: [
              if (wide) SizedBox(width: 280, child: _buildTreePanel()),
              if (wide) const VerticalDivider(width: 1),
              Expanded(child: _buildEditorPanel()),
            ],
          ),
        );
      },
    );
  }

  /// 编辑器动作组（独立页 AppBar 与内嵌工具行共用）。
  List<Widget> _editorActions({double iconSize = 24}) {
    return [
      if (_currentPath != null) ...[
        // 预览入口（alpha.72 改）：从「单一 Web 预览按钮」改成菜单。
        //
        // ## 为什么不再默认走 Web
        //
        // Web 预览要先把源码推给容器里的 Flutter SDK 跑一次
        // `flutter build web`，真机实测首次 1-5 分钟、整轮 10 分钟以上
        // （数字记在 `web_preview_service.dart`）。用户点"预览"想要的是
        // **看一眼界面**，不是等一次完整构建。
        //
        // 菜单里第一项是设计预览（零编译、帧级），Web 降为备选 ——
        // 它仍然是唯一能看**真跑起来的效果**的路径（点击、网络、
        // 路由都会真发生），只是不该站在第一位。
        //
        // 保留单按钮的外观而不是拆成两个图标：工具栏本来就挤
        // （这个按钮旁边还有 5 个图标），多一个必定换行。
        ValueListenableBuilder<WebPreviewStatus>(
          valueListenable: WebPreviewService.I.statusN,
          builder: (ctx, st, _) {
            final running = st == WebPreviewStatus.running;
            return PopupMenuButton<String>(
              tooltip: running ? '预览（Web 运行中）' : '预览',
              iconSize: iconSize,
              onSelected: (v) {
                switch (v) {
                  case 'design':
                    _openDesignPreview();
                  case 'project':
                    _openProjectPagePreview();
                  case 'web':
                    if (running) {
                      _onPreviewTap();
                    } else {
                      _openPreviewPage();
                    }
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'design',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.design_services_outlined, size: 20),
                    title: Text('设计预览', style: TextStyle(fontSize: 13.5)),
                    subtitle: Text('零编译，即时', style: TextStyle(fontSize: 10.5)),
                  ),
                ),
                const PopupMenuItem(
                  value: 'project',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.travel_explore_outlined, size: 20),
                    title: Text('预览项目里的页面', style: TextStyle(fontSize: 13.5)),
                    subtitle:
                        Text('扫描 lib/ 下所有页面', style: TextStyle(fontSize: 10.5)),
                  ),
                ),
                PopupMenuItem(
                  value: 'web',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      running ? Icons.refresh : Icons.play_circle_outline,
                      size: 20,
                      color: running ? const Color(0xFF3DDC84) : null,
                    ),
                    title: Text(running ? '热重载（Web 预览运行中）' : 'Web 预览',
                        style: const TextStyle(fontSize: 13.5)),
                    subtitle: Text(
                      running ? '改完代码点这个' : '真跑一遍，但首次要等几分钟',
                      style: const TextStyle(fontSize: 10.5),
                    ),
                  ),
                ),
              ],
              icon: Icon(
                running ? Icons.refresh : Icons.play_circle_outline,
                size: iconSize,
                color: running ? const Color(0xFF3DDC84) : null,
              ),
            );
          },
        ),
        IconButton(
          iconSize: iconSize,
          tooltip: '撤销更改',
          onPressed: _dirty ? _revert : null,
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          iconSize: iconSize,
          tooltip: _dirty ? '应用更改（有未保存修改）' : '应用更改',
          onPressed: _save,
          icon: Icon(
            Icons.save_outlined,
            color: _dirty ? const Color(0xFF3DDC84) : null,
          ),
        ),
        IconButton(
          iconSize: iconSize,
          tooltip: '搜索',
          onPressed: () => _editorKey.currentState?.openSearch(),
          icon: const Icon(Icons.search),
        ),
        IconButton(
          iconSize: iconSize,
          tooltip: '转到行',
          onPressed: _showGoToLine,
          icon: const Icon(Icons.my_location),
        ),
        // 更多：格式化 / 帮助（Dart 手册、Flutter API）
        PopupMenuButton<String>(
          tooltip: '更多操作',
          onSelected: _onMenuSelected,
          itemBuilder: (ctx) => [
            const PopupMenuItem(
              value: 'format',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.auto_fix_high, size: 20),
                title: Text('格式化代码'),
              ),
            ),
            // alpha.91：自动同步开关。默认开——这个功能的全部意义就是
            // "不用手动从磁盘加载覆盖"，默认关掉的话用户得先发现开关
            // 才能得到他要的行为。有未保存改动时仍有 diff 抽屉兜着。
            PopupMenuItem(
              value: 'auto_sync',
              child: ListTile(
                dense: true,
                leading: Icon(
                  (_autoSyncPref ?? true)
                      ? Icons.sync_alt
                      : Icons.sync_disabled,
                  size: 20,
                ),
                title: Row(
                  children: [
                    const Text('自动同步外部改动'),
                    const SizedBox(width: 8),
                    Text(
                      (_autoSyncPref ?? true) ? '开' : '关',
                      style: TextStyle(
                        fontSize: 11,
                        color: (_autoSyncPref ?? true)
                            ? const Color(0xFF3DDC84)
                            : Colors.grey,
                      ),
                    ),
                  ],
                ),
                subtitle: Text(
                  (_autoSyncPref ?? true)
                      ? '外部改了文件就自动更新，不用手动载入'
                      : '已关闭：只在派活后提示一次',
                  style: const TextStyle(fontSize: 10.5),
                ),
              ),
            ),
            // alpha.81：远程 AI 经 MCP 改文件不会通知编辑器，手动拉一次
            // （alpha.91 起自动同步接管了主路径，这个入口降级为兜底）
            const PopupMenuItem(
              value: 'reload',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.sync, size: 20),
                title: Text('从磁盘重新载入'),
                subtitle:
                    Text('手动拉一次（自动同步关闭时用）', style: TextStyle(fontSize: 10.5)),
              ),
            ),
            // alpha.84：派活是黑盒（谁领了？改没改？），给一个能自己看的地方
            const PopupMenuItem(
              value: 'ai_inbox',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.inbox_outlined, size: 20),
                title: Text('AI 作业收件箱'),
                subtitle:
                    Text('看派出去的活有没有被处理', style: TextStyle(fontSize: 10.5)),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'dart_docs',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.menu_book, size: 20),
                title: Text('Dart 官方手册'),
              ),
            ),
            const PopupMenuItem(
              value: 'flutter_api',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.language, size: 20),
                title: Text('Flutter API 浏览器'),
              ),
            ),
          ],
        ),
      ],
    ];
  }

  /// 内嵌模式主体：紧凑工具行（文件名 + dirty 标记 + 动作组）+ 编辑面板。
  Widget _buildEmbedBody() {
    final path = _currentPath;
    return Column(
      children: [
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          // alpha.69：`FoaTheme.consoleBg` 是固定深色，浅色主题下这条工具行
          // 会是黑的。`codeBg` 与它**深色值完全相同**（都是 #0B0E11），
          // 但浅色分支会给出 #EEF1F3 —— 同源改一处即可（见 theme.dart 注释）。
          color: FoaColors.of(context).codeBg,
          child: Row(
            children: [
              Expanded(
                child: path == null
                    ? Text('未打开文件',
                        style: TextStyle(
                            fontSize: 13, color: FoaColors.of(context).muted))
                    : Tooltip(
                        message: path,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(path.split('/').last,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                            ),
                            if (_dirty) ...[
                              const SizedBox(width: 6),
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                    color: Color(0xFF3DDC84),
                                    shape: BoxShape.circle),
                              ),
                            ],
                          ],
                        ),
                      ),
              ),
              ..._editorActions(iconSize: 20),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildEditorPanel()),
      ],
    );
  }

  Widget _buildTreePanel() {
    return FileTree(
      key: _treeKey,
      bridge: widget.bridge,
      onOpenFile: openFile,
      initialDir: widget.initialDir,
    );
  }

  /// 把 AI 结果应用到光标处（alpha.81 老路径）：宿主（工作台）在预览里点了
  /// 「应用到光标处」后经 GlobalKey 调到这。编辑器自己不知道 AI。
  void applyAiResult(String text) =>
      _editorKey.currentState?.insertAtCursor(text);

  // ---------------- AI 就地生成（alpha.82） ----------------

  /// 单点 AI：按当前代码补全。
  Future<void> _onAiTap(EditorAiRequest req) => _runAiFlow(req, '');

  /// 整条 AI 流程：收键盘 → 预留空行 → 等结果 → 落位 → 询问保存。
  ///
  /// 顺序是刻意的，改之前先想清楚每一步在防什么：
  /// 1. **先收键盘**：不收的话键盘会压住刚预留出来的空行，用户根本看不
  ///    见"AI 要写在哪"，等于白预留；
  /// 2. **预留空行 + 锁编辑**：让人一眼看到落点，也保证占位区间在等待期间
  ///    不会被改乱（提交/回滚都依赖这个区间）；
  /// 3. **派活（MCP）不占位**：它是异步无回执的，占着空行只会一直卡在那，
  ///    所以这类结果直接回滚占位 + 如实提示"已投递，等远端领取"；
  /// 4. **成功不落盘**：写进编辑器只是变成未保存改动，**最后问一句存不存**
  ///    ——AI 写错时不该替用户做保存这个决定。
  Future<void> _runAiFlow(EditorAiRequest req, String instruction) async {
    if (widget.onRunAi == null) return;
    // ⚠️ 防重入闸门必须**同步**落下（alpha.86）。
    //
    // 旧写法只靠 `if (_aiBusy) return;`，而 `_aiBusy` 要等下面
    // `setState` 才置真——它前面还横着一个 `await _ensureAiReady()`
    // （读配置 + 可能弹对话框）。连点两下时，第二次点击正好落在那个
    // await 里，看到 `_aiBusy` 仍是 false，于是**两个流程并行跑到派活**，
    // 磁盘上就多出一条重复作业。
    //
    // 连点 AI 按钮是很自然的动作（尤其中文输入法下，点了没反应会更用力点），
    // 所以这道闸门要挡在所有 await 之前，且用**同步字段**，不依赖
    // setState 的时机。
    if (_aiRunning) return;
    _aiRunning = true;
    try {
      // 前置就绪检查（alpha.85）：后端没准备好就别让用户白点。
      // 放在**占位之前**——占位是"AI 正在写"的承诺，还没确定能跑就占位，
      // 失败了得先撤占位再说，白白闪一下。
      if (!await _ensureAiReady()) return;
      if (!mounted) return;

      final before = _content;
      final beforeDirty = _dirty;

      FocusScope.of(context).unfocus();
      if (!mounted) return;
      setState(() {
        _aiBusy = true;
        _aiBefore = before;
        _aiBeforeDirty = beforeDirty;
      });
      _editorKey.currentState?.beginAiPlaceholder();

      AiOutcome out;
      try {
        out = await widget.onRunAi!(AiJob(
          kind: instruction.trim().isEmpty
              ? AiJobKind.complete
              : AiJobKind.instruct,
          path: req.path,
          content: req.content,
          cursorOffset: req.cursorOffset,
          instruction: instruction,
          language: req.language,
        ));
      } catch (e) {
        // 宿主那侧抛了就是真异常（比如通道炸了），一样要走回滚，
        // 不能把编辑区永久锁在只读状态。
        out = AiOutcome.failure('AI 请求异常：$e');
      }
      if (!mounted) return;

      if (out.kind != AiOutcomeKind.content) {
        _editorKey.currentState?.cancelAiPlaceholder();
        setState(() => _aiBusy = false);
        if (out.kind == AiOutcomeKind.dispatched) {
          _toast(out.message);
          // alpha.83：派活后盯着磁盘——外部 AI 改完（write_file 落盘）就弹
          // diff 预览，让 MCP 路径也能"实时看到改动再决定"。
          //
          // ⚠️ alpha.84 修正：基线是**派活时磁盘上的内容**，由 watcher 自己
          // 读一次得到，**不是** `before`（编辑器内容）。拿编辑器内容当基线
          // 时，用户只要有未保存改动，首轮轮询就会误判"磁盘变了"→ 弹假
          // 报警 → 监听自停 → 真改动永远不报（症状：还得手动重载）。
          _startDiskWatch(req.path);
        } else {
          await _showAiFailure(out.message, remedy: out.remedy);
        }
        return;
      }

      _editorKey.currentState?.commitAiPlaceholder(out.text);
      setState(() => _aiBusy = false);
      await _askSaveAiChange(before, out);
    } finally {
      // 闸门必须在**所有**出口都打开：正常结束、提前 return、
      // 以及 _showAiFailure / _askSaveAiChange 里抛异常。
      // 漏一条，AI 按钮就永久点不动了。
      _aiRunning = false;
    }
  }

  /// 点 AI 之前先确认"后端真的能干活"（alpha.85）。
  ///
  /// ## 为什么要单独拦一道
  /// 两条后端各有自己的前提，而**两条路径的失败长得一模一样**——都是
  /// "点了没反应/一句看不出所以然的提示"：
  /// - **内置 LLM**：选了但没填地址/密钥 → 现在靠 `AiOutcome.failure` 兜，
  ///   但要等"跑一次"才知道，白造一个占位再撤销；
  /// - **远程 MCP**：**它没有任何前置校验**，隧道没开也照写 inbox。用户
  ///   看到的是"已投递，等已连隧道的 AI 客户端领取"——技术上真（确实写进去了）、
  ///   实际上假（根本没有客户端能连进来）。作业就烂在磁盘里。
  ///
  /// 后者是本轮用户报的问题：**以前会提示未连接并跳设置，现在只会静静派活**。
  ///
  /// ## 为什么 MCP 是"提示 + 让你选"而不是硬拦
  /// 派活本身有独立价值：用户可能打算**稍后**起隧道，或者会自己把作业
  /// 文件拷给别的 AI。硬拦会砍掉这些用法。所以给三个出口，
  /// 默认停在"取消"上——**不阻断，但绝不让人以为活已经有人接了**。
  Future<bool> _ensureAiReady() async {
    AiConfig cfg;
    try {
      cfg = await AiConfigStore.load();
    } catch (_) {
      cfg = AiConfig.unconfigured;
    }
    if (!mounted) return false;

    // ① 内置 LLM：缺地址/密钥 → 直接领去设置（与失败分支同一个出口）
    if (cfg.kind == AiBackendKind.builtinLlm && !cfg.llmReady) {
      await _showAiFailure(kAiUnconfiguredMessage);
      return false;
    }

    // ② 远程 MCP：隧道没开 → 提示 + 三出口
    if (cfg.kind == AiBackendKind.remoteMcp &&
        !tunnelReady(TunnelService.I.status)) {
      final choice = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('隧道没开'),
              content: const Text(
                '当前 AI 后端是「远程 MCP」，它把作业写进项目的收件箱，'
                '等**连了隧道**的 AI 客户端来领取。\n\n'
                '现在隧道没运行，派出去也没人领得到——'
                '作业只会静静躺在 .foa/ai-inbox.md 里。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'cancel'),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'send'),
                  child: const Text('仍然派活'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'tunnel'),
                  child: const Text('去开启隧道'),
                ),
              ],
            ),
          ) ??
          'cancel';
      if (!mounted) return false;
      if (choice == 'cancel') return false;
      if (choice == 'tunnel') {
        // 领到远程协助页（隧道开关在那里）。**不放行派活**：用户点的是
        // "去开启隧道"，说明他不想让作业在没隧道时先落盘，硬放行等于
        // 违他本意。起完隧道回来再点一次 AI 是正常预期。
        widget.onOpenAiSettings?.call();
        return false;
      }
      // 'send'：用户明知没人领也要留个作业（比如稍后自己起隧道），放行。
      return true;
    }
    return true;
  }

  /// 派活后盯磁盘（alpha.83）：外部 AI 改完就弹 diff 预览。
  ///
  /// 为什么值得做：MCP 派活是"异步无回执"的，alpha.81/82 只能让人自己
  /// 去点「从磁盘重新载入」，中间那段全靠猜。轮询一条文件成本极低
  /// （见 [AiFileWatcher]），却能把 MCP 的体验拉平到内置 LLM 那条线：
  /// **改动先给你看，要不要收下你说了算**。
  ///
  /// 基线不由这里给：watcher 自己读一次磁盘当基线（alpha.84）。这样
  /// "用户有未保存改动"不会被误当成"磁盘被外部改了"。
  void _startDiskWatch(String path) {
    // alpha.91：自动同步开着的话，常驻来源已经在盯这个文件了，
    // 再启动一个 = 同一次外部改动弹两次 diff（两个机制各有各的回调，
    // 谁也不知道对方存在）。直接让常驻的那个负责。
    if (_diskSource?.active == true) return;
    _aiWatch?.stop();
    final w = AiFileWatcher(bridge: widget.bridge);
    w.onChanged = (disk) {
      if (mounted) _showExternalChange(disk);
    };
    _aiWatch = w;
    // start 是异步的（要读一次盘），故意不 await：它是"开始了没"的
    // 语义，不是"结果已到"，await 只会阻塞后面的 UI 收尾。
    unawaited(w.start(path: path));
  }

  // ---------------- alpha.91 自动同步 ----------------

  /// 打开文件后挂上常驻的磁盘变更监听。
  ///
  /// ## 为什么不再只在"派活后"启动
  ///
  /// alpha.83 只在 MCP 派活之后开监听，理由是"只有外部 AI 会改文件"。
  /// 但现实里外部改动不止派活一条路：远程 AI 直接在隧道里改、用户在
  /// 电脑上同步过来、另一个 App 写同一个共享目录……用户的原话是
  /// **"不需要用户手动从磁盘加载覆盖"**——那就得常态盯着，而不是
  /// 猜"这次改动是不是派活引起的"。
  ///
  /// ## 与 [_startDiskWatch] 的互斥
  ///
  /// 两个机制都会在磁盘变化时弹 diff。同时跑的话同一次改动会弹两次。
  /// 所以这里的约定是：
  ///   - 自动同步开着 → 只跑 [_diskSource]，[_aiWatch] 不启动；
  ///   - 自动同步关着 → 退回 alpha.83 的老行为（只在派活后 [_aiWatch]）。
  ///
  /// 两边都写成"先停对方"，这样无论从哪个入口进来都不会双跑。
  /// 打开文件后挂上常驻的磁盘变更监听。
  ///
  /// ## 为什么不再只在"派活后"启动
  ///
  /// alpha.83 只在 MCP 派活之后开监听，理由是"只有外部 AI 会改文件"。
  /// 但现实里外部改动不止派活一条路：远程 AI 直接在隧道里改、用户在
  /// 电脑上同步过来、另一个 App 写同一个共享目录……用户的原话是
  /// **"不需要用户手动从磁盘加载覆盖"**——那就得常态盯着，而不是
  /// 猜"这次改动是不是派活引起的"。
  ///
  /// ## 与 [_startDiskWatch] 的互斥
  ///
  /// 两个机制都会在磁盘变化时弹 diff。同时跑的话同一次改动会弹两次。
  /// 所以这里的约定是：
  ///   - 自动同步开着 → 只跑 [_diskSource]，[_aiWatch] 不启动；
  ///   - 自动同步关着 → 退回 alpha.83 的老行为（只在派活后 [_aiWatch]）。
  ///
  /// 两边都写成"先停对方"，这样无论从哪个入口进来都不会双跑。
  void _startAutoSync(String path) {
    // ⚠️ 判据必须是 `?? true` 而不是 `!= true`。
    //
    // `_autoSyncPref` 初值是 **null**（`AutoSyncPref.load()` 是异步的，
    // 打开文件时它多半还没回来）。用 `!= true` 就会把"还没读出来"当成
    // "用户关掉了"，于是**自动同步永远不启动**——而且完全不报错。
    // 这个功能的默认值是**开**（见 AutoSyncPref 类注释），null 必须走开。
    if (!(_autoSyncPref ?? true)) return; // 用户明确关了：什么都不做，退回老路径
    _aiWatch?.stop(); // ← 关键：别和 alpha.83 那条路同时活着
    _aiWatch = null;

    _diskSource?.stop();
    final src = NativeFileChangeSource(bridge: widget.bridge);
    src.onChanged = (p) {
      // onChanged 可能来自 Timer/原生回调，此时页面可能已经销毁
      if (mounted) unawaited(_onDiskChanged(p));
    };
    _diskSource = src;
    unawaited(src.start(path));
  }

  /// 磁盘可能变了：判断该怎么处理。
  ///
  /// 三条出口（按优先级）：
  ///   1. **不是当前文件 / 正在 AI 生成中** → 忽略。前者是别处的事件，
  ///      后者会把 AI 的占位内容冲掉（占位区间一旦错位，回滚会删错行）。
  ///   2. **内容与编辑器一致** → 忽略。覆盖"用户自己保存"这条最常走的路：
  ///      原生监听会把自写也报上来（它只看 inode 事件，分不清谁写的），
  ///      靠这次内容比对兜住。不做这一步的话，**每次保存都会给自己弹一次
  ///      diff 预览**。
  ///   3. **有脏改动** → 弹 diff 让用户决定（不静默覆盖他正在写的东西）。
  ///      **无脏改动** → 静默更新，这正是用户要的"不用手动加载"。
  ///
  /// 读失败（文件被删 / 写到一半）一律静默返回：下一次事件还会来。
  Future<void> _onDiskChanged(String path) async {
    if (!mounted) return;
    if (path != _currentPath) return;
    if (_aiBusy) return;

    final r = await widget.bridge.read(path);
    if (!mounted || !r.ok) return;
    if (r.content == _content) return; // 自己刚保存 / 内容没变

    if (_dirty) {
      await _showExternalChange(r.content);
      return;
    }
    _applyDiskContent(r.content);
  }

  /// 无脏改动时把磁盘内容静默装进编辑器。
  ///
  /// ⚠️ 顺序必须是**先 reset 再 setState**，理由与 [reloadFromDisk] 相同：
  /// `reset()` 会经 `onContentChanged` 把 `_dirty` 置真（`code_editor.dart:245`
  /// → 本文件 `:1349` 的 `if (!_dirty)` 守卫），顺序反了就留下一个假的
  /// 未保存标记。这里比 [reloadFromDisk] 更容易踩，因为"自动同步"发生得
  /// 频繁且没有用户操作做掩护，假脏会静默堆积成"切文件老被拦"。
  ///
  /// `_initialContent` 也跟到磁盘版本：此刻用户没有任何未保存改动，
  /// 磁盘版就是他的"当前版本"，"撤销更改"恢复到它才符合直觉。
  void _applyDiskContent(String disk) {
    _editorKey.currentState?.reset(disk);
    setState(() {
      _content = disk;
      _initialContent = disk;
      _dirty = false;
    });
    _diskSource?.bumpBaseline(disk);
    _toast('已同步磁盘上的改动');
  }

  /// 测试辅助：进入「AI 正在生成」状态。
  ///
  /// 生产路径上这个状态由 `_runAiFlow` 设置（`_aiBusy = true` +
  /// 编辑器占位）。测试要验证"AI 生成期间外部事件不打扰"这条边界，
  /// 但没法在测试里真的跑一遍 AI（要隧道、要后端）。所以开一个钩子
  /// 直接置位——它只改状态，不碰任何业务逻辑。
  @visibleForTesting
  void beginAiPlaceholderForTest() {
    setState(() => _aiBusy = true);
    _editorKey.currentState?.beginAiPlaceholder();
  }

  /// 切换「自动同步」开关。
  Future<void> _toggleAutoSync() async {
    final next = !(_autoSyncPref ?? true);
    await AutoSyncPref.save(next);
    if (!mounted) return;
    setState(() => _autoSyncPref = next);

    if (next) {
      final p = _currentPath;
      if (p != null) _startAutoSync(p);
    } else {
      // 关掉：停常驻来源，回到 alpha.83 的"只在派活后盯一次"
      _diskSource?.stop();
      _diskSource = null;
    }
    _toast(next ? '已开启自动同步' : '已关闭自动同步（改用派活后提示）');
  }

  /// 派活的"作业收件箱"（alpha.84）：把黑盒摊开给用户看。
  ///
  /// 回答的正是用户那句"**不确定外部 AI 干了什么**"——派活是异步无回执
  /// 的设计，能观测的只有磁盘上的两处痕迹：`ai-inbox.md`（索引）与
  /// `ai-jobs/` 下的作业文件（`status: done` 表示对方回执过）。
  ///
  /// 这里**只读不写**：不在这个弹窗里"标记完成 / 删作业"，因为判断权在
  /// 外部 AI 手里，App 代它标 done 就是撒谎。
  Future<void> _showAiInbox() async {
    final root = await _resolveProjectRoot();
    if (!mounted) return;
    if (root == null) {
      _toast('未定位到项目根（需先打开项目内文件）');
      return;
    }
    final snap = await loadAiInbox(bridge: widget.bridge, projectRoot: root);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 作业收件箱'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '目录：$root/$kAiJobsDir',
                  style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                if (snap.error != null) ...[
                  Text('⚠️ ${snap.error}',
                      style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                ],
                if (snap.jobs.isEmpty)
                  const Text(
                    '还没有派过活（或作业文件已清掉）。\n'
                    'AI 后端选「远程 MCP」时，每次点 AI 按钮都会在这里留下一条。',
                    style: TextStyle(fontSize: 12.5),
                  )
                else ...[
                  Text(
                    '共 ${snap.jobs.length} 条，'
                    '待处理 ${snap.pendingCount} 条',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  ...snap.jobs.map(
                    (j) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        describeJob(j),
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: j.done
                              ? const Color(0xFF3DDC84)
                              : const Color(0xFFE0A800),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '⏳ = 作业还在，没看到 status: done 回执。\n'
                    '对方可能还没来领，也可能改了但没写回执——'
                    '所以派活之后仍建议盯着编辑区，磁盘一变就会自动弹 diff。',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ],
            ),
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

  /// 外部 AI 改了磁盘：diff 预览 + 收下 / 忽略 / 先看看。
  ///
  /// 不直接覆盖编辑区——用户可能自己也在改（有未保存改动），静默替换
  /// 会吞掉他的东西。「忽略」只对**这一次**生效，之后他仍可手动重载。
  ///
  /// alpha.91：同样换成全屏抽屉（理由见 [_askSaveAiChange]）。
  Future<void> _showExternalChange(String disk) async {
    final d = lineDiff(_content, disk);

    final warnings = <Widget>[
      if (_dirty) _warnLine('你本地还有未保存的修改，载入会覆盖它们'),
    ];

    final choice = await showDiffSheet(
      context,
      title: '远程 AI 改了文件',
      warnings: warnings,
      diff: d,
      actions: const [
        DiffAction('忽略', DiffChoice.discard),
        DiffAction('先放着', DiffChoice.later),
        DiffAction('载入', DiffChoice.save, primary: true),
      ],
    );

    if (!mounted || choice != DiffChoice.save) return;
    // 走既有的重载路径（它有 dirty 二次确认 + 复位编辑器）
    await reloadFromDisk(skipConfirm: true);
  }

  /// 失败提示：带一个"去设置"的出口（没配置 / 填错 key 是最常见的失败）。
  ///
  /// [remedy] 决定出口文案（alpha.85）：以前不论什么失败都只写"去设置"，
  /// 但用户真正要去的地方不一样——缺密钥是去 AI 设置区，缺隧道是去
  /// 远程协助页。文案说错地方，比没有出口更浪费时间。
  Future<void> _showAiFailure(String msg, {AiRemedy? remedy}) =>
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('AI 没能给结果'),
          content: Text(msg.isEmpty ? '未知错误' : msg),
          actions: [
            if (widget.onOpenAiSettings != null)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onOpenAiSettings!();
                },
                child: Text(
                  remedy == AiRemedy.startTunnel ? '去开启隧道' : '去设置',
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  /// 写完之后问一句"存不存"（alpha.82 → alpha.91 改全屏抽屉）。
  ///
  /// 三个出口都有理由：**保存**落盘；**放弃**整体回滚到 AI 之前的文本
  ///（含 dirty 状态，不能因为放弃就把用户自己之前的未保存改动也弄丢）；
  /// **先不存**保持编辑器里的改动但先不落盘，让人自己再看一眼。
  ///
  /// alpha.91：真机反馈"弹窗预览不好，132 行根本看不过来"。原实现是
  /// `AlertDialog` + `maxHeight: 170`，**小窗口装大内容属于容器选型错误**，
  /// 换成接近全屏的抽屉，统计与按钮钉顶，diff 占满其余空间。
  Future<void> _askSaveAiChange(String before, AiOutcome out) async {
    final d = lineDiff(before, _content);

    final warnings = <Widget>[];
    if (out.truncated) {
      warnings.add(_warnLine('AI 只看到了部分上下文，改动可能不完整'));
    }
    if (out.suspicious) {
      warnings.add(_warnLine('返回内容疑似不是纯代码，请先确认'));
    }

    final choice = await showDiffSheet(
      context,
      title: 'AI 已写入编辑器',
      warnings: warnings,
      diff: d,
      actions: const [
        DiffAction('放弃', DiffChoice.discard),
        DiffAction('先不存', DiffChoice.later),
        DiffAction('保存', DiffChoice.save, primary: true),
      ],
    );

    if (!mounted) return;
    if (choice == DiffChoice.discard) {
      _rollbackAi();
    } else if (choice == DiffChoice.save) {
      await _save();
    }
  }

  Widget _warnLine(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded,
                size: 15, color: Color(0xFFE0A800)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(fontSize: 12, color: Color(0xFFE0A800)),
              ),
            ),
          ],
        ),
      );

  /// 放弃 AI 的改动：整体回滚（含 AI 之前的 dirty 状态）。
  ///
  /// ⚠️ 顺序不能反：`reset()` 会触发 `onContentChanged` 把 dirty 置真，
  /// 所以必须**先 reset 再覆写** dirty 状态，否则会把"用户本来没保存的
  /// 改动"错误地标成已保存。
  void _rollbackAi() {
    _editorKey.currentState?.reset(_aiBefore);
    setState(() {
      _content = _aiBefore;
      _dirty = _aiBeforeDirty;
    });
    _toast('已放弃 AI 的改动');
  }

  /// 差异预览。
  ///
  /// alpha.91 起改用 `diff_view.dart` 的 [DiffLinesView]——原来的本地实现
  /// 用 `Text` + `overflow: ellipsis`，**长代码行会自动折行**，一个 `+`
  /// 号占掉三行，用户数行号时对不上（这是信息错误，不只是不好看）。
  ///
  /// 从磁盘重新载入当前文件（alpha.81）。
  ///
  /// 为什么需要它：远程 AI 经 MCP `write_file` 改文件时**不会通知编辑器**
  /// ——现有的"保存即刷新"只挂在自己保存这个动作上，没有外部变更监听
  ///（真做文件监听要常驻 watcher，成本不值）。所以派活之后给一个手动
  /// 拉取的入口，比让人猜"到底改没改"强。
  ///
  /// 有未保存改动时**先确认再载**——否则用户正在写的东西会被无声吞掉。
  ///
  /// [skipConfirm] 供"外部变更"流程用：那边已经用 diff 明确问过用户了，
  /// 再弹一次同一个问题只是重复打扰。
  Future<void> reloadFromDisk({bool skipConfirm = false}) async {
    final path = _currentPath;
    if (path == null) return;
    if (_dirty && !skipConfirm) {
      final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('放弃未保存的修改？'),
              content: const Text(
                '重新载入会用磁盘上的内容覆盖当前编辑区，未保存的修改将丢失。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('放弃并载入'),
                ),
              ],
            ),
          ) ??
          false;
      if (!ok) return;
    }
    final r = await widget.bridge.read(path);
    if (!mounted) return;
    if (!r.ok) {
      _toast(r.error ?? '读取失败');
      return;
    }
    // ⚠️ 顺序不能反（alpha.91 修）：`reset()` 会经 `onContentChanged`
    // 把 `_dirty` 置真 —— 见 `code_editor.dart:245` 的 `_onChanged` 与
    // 本文件 :1349 的 `if (!_dirty) setState(() => _dirty = true)`。
    //
    // 之前的写法是"先 setState(dirty=false) 再 reset"，于是 reset 触发的
    // 回调恰好通过 `!_dirty` 守卫，把刚落下的 false 又顶回 true：
    // 每次重载后都留下一个**假的未保存标记**。它不报错、不崩溃、无日志，
    // 只在用户切文件时冒出一个「未保存的修改」对话框 —— 而其实一个字
    // 都没改。回归测试见 `test/editor_reload_dirty_test.dart`。
    //
    // 和 `_rollbackAi:1155` 是同一个写法、同一个理由。
    _editorKey.currentState?.reset(r.content);
    setState(() {
      _content = r.content;
      _initialContent = r.content;
      _dirty = false;
    });
    _toast('已从磁盘重新载入');
  }

  /// 长按 AI 按钮的输入栏（alpha.81）：收集用户指令后交给宿主。
  ///
  /// 用**底部 sheet 而不是居中 AlertDialog**：弹窗要贴着键盘上来，且不遮
  /// 住正在写的代码——用户写要求时往往还要回头看一眼上下文。
  Future<void> _showAiInstructSheet(
    EditorAiRequest req,
    void Function(EditorAiRequest, String) submit,
  ) async {
    final ctrl = TextEditingController();
    final instruction = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        // 键盘顶起（viewInsets）+ 底部安全区，否则输入框会被键盘盖住
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
          left: 12,
          right: 12,
          top: 4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome,
                    size: 16, color: Color(0xFF4C8DFF)),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '让 AI 做什么？',
                    style:
                        TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.onOpenAiSettings != null)
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    tooltip: 'AI 设置',
                    onPressed: () {
                      Navigator.pop(ctx);
                      widget.onOpenAiSettings!();
                    },
                  ),
              ],
            ),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: '例如：给这个函数加参数校验、把这段改成 Builder',
                hintStyle: const TextStyle(fontSize: 12),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, ctrl.text),
                  icon: const Icon(Icons.send, size: 16),
                  label: const Text('发送'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (instruction == null || instruction.trim().isEmpty) return;
    submit(req, instruction.trim());
  }

  Widget _buildEditorPanel() {
    final path = _currentPath;
    if (path == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.code, size: 56, color: Colors.grey.shade700),
            const SizedBox(height: 12),
            Text(
              // 内嵌模式没有自己的 ☰：树在工作台抽屉/横屏左栏
              widget.embed ? '从工作台侧边文件树选择文件' : '从侧边栏选择文件开始编辑',
              style: TextStyle(color: FoaColors.of(context).muted),
            ),
            if (!widget.embed && MediaQuery.sizeOf(context).width < 600)
              Text(
                '（点左上角 ☰ 打开文件浏览）',
                style:
                    TextStyle(color: FoaColors.of(context).muted, fontSize: 12),
              ),
          ],
        ),
      );
    }
    return Container(
      // alpha.69：同上 —— 这里包住整个代码编辑器，固定深色会让浅色主题下
      // 代码区仍是黑底（用户截图里的直接症状）。
      color: FoaColors.of(context).codeBg,
      child: CodeEditor(
        // GlobalKey：顶栏撤销/搜索/跳转/格式化经 CodeEditorState 调用；
        // 切换文件由 didUpdateWidget（old.path != path）重建 controller
        key: _editorKey,
        path: path,
        initialContent: _content,
        onContentChanged: (t) {
          // 关键：把最新文本写回 EditorPage._content，保存时才有新内容
          // （Bug 215：此前只标记 dirty，保存写的是打开时的旧内容）
          _content = t;
          if (!_dirty) setState(() => _dirty = true);
        },
        // alpha.82：给了 [onRunAi] 就由本页主导整条 AI 流程（占位 → 写入
        // → 询问保存），**单点与长按两条都要接上**——只接单点的话长按会
        // 静默失效（按钮还在，按了没反应）。
        // 没给 onRunAi 则退回 alpha.81 的"报给宿主"老路，保证其它调用点
        //（未来可能有的只读编辑器）不受影响。
        onAiComplete: widget.onRunAi == null ? widget.onAiComplete : _onAiTap,
        onAiInstruct: widget.onRunAi != null
            ? (req) => _showAiInstructSheet(req, _runAiFlow)
            : (widget.onAiInstruct == null
                ? null
                : (req) => _showAiInstructSheet(req, widget.onAiInstruct!)),
        aiBusy: _aiBusy,
      ),
    );
  }
}
