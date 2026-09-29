import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../editor/fs_bridge.dart';
import 'design_import.dart';
import 'design_model.dart';
import 'design_preview_page.dart';

/// 项目工作台 ·「设计」区（alpha.70）。
///
/// ## 这是什么
///
/// 可视化拼界面 → 生成 Dart 代码，落进项目的 `lib/generated/`。
/// 对齐 [design_model.dart] 里写的那条边界：**只生成静态界面**，
/// 不含业务逻辑/状态管理/数据流/路由。
///
/// ## 为什么不做拖拽
///
/// 参考对象 FlutterViz 是 Web 端（有鼠标），我们是手机（触摸）。
/// "把组件拖到指定坐标"在 6 寸屏上精度根本不够，用户会更频繁地
/// 拖歪、再拖回来，比直接点选慢。
///
/// 所以这里的交互模型是：
/// - **点组件库** → 追加到当前选中节点下（卡片/根节点才能接）
/// - **点组件树** → 选中，然后「上移/下移」调顺序、「删除」移除
/// - **点属性面板** → 改文案/尺寸/颜色
///
/// 顺序即布局（生成的代码是一串 `Column.children`）。这在手机上
/// 比自由摆位可控得多，也不会出现"两个组件叠在一起"的坏状态。
///
/// ## 布局
///
/// 竖屏：顶部工具栏 → 预览（自适应高度）→ 三个可折叠面板（组件库/树/属性）
/// 横屏：左栏预览，右栏三个面板（避免预览被面板挤成一条缝）
class DesignPage extends StatefulWidget {
  /// 项目名（用于拼容器内路径）。
  final String projectName;

  /// 读写项目文件。
  final FsBridge bridge;

  /// 在编辑器中打开某个文件（相对项目根）—— 导出后跳「代码」区看生成物。
  final void Function(String rel) onOpenFile;

  const DesignPage({
    super.key,
    required this.projectName,
    required this.bridge,
    required this.onOpenFile,
  });

  @override
  State<DesignPage> createState() => DesignPageState();
}

class DesignPageState extends State<DesignPage> {
  /// 设计树的根（不可删、不可移）。
  late DesignNode _root = DesignTemplate.blank.build();

  /// 当前选中的节点 id。空串 = 没选中（属性面板显示提示）。
  String _selectedId = '';

  /// 组件库里**长按选中**的类型（"长按选中控件"的落点）。
  ///
  /// 与 [_selectedId] 是**两个独立维度**，别合并：
  /// - [_selectedId] = 组件树里选中的节点（"往哪加"、"改谁的属性"）；
  /// - [_pendingType] = 组件库里选中的**类型**（"要加什么"）。
  ///
  /// 用途只有一个：给「上方插入 / 下方插入」提供要插入的类型。
  /// null = 没长按过，此时两个插入按钮禁用（硬编码塞 text 会让人困惑：
  /// 明明长按选中了「按钮」，插出来的却是文本框）。
  DesignComponentType? _pendingType;

  /// 已选模板（用于工具栏显示"当前模板"）。
  DesignTemplate _template = DesignTemplate.blank;

  /// 撤销栈（存的是改前快照）。上限见 [_kUndoLimit]。
  final List<DesignNode> _undo = <DesignNode>[];

  /// 展开状态：id 集合（默认全展开 —— 组件不多，折叠反而要多点一次）。
  final Set<String> _collapsed = <String>{};

  /// 是否正在导出（防连点）。
  bool _exporting = false;

  /// 撤销栈上限。
  ///
  /// 不做无限栈：设计树 clone 是深拷贝，一个稍复杂的页面几十个节点，
  /// 无限攒着会明显吃内存。20 步足够覆盖"改错了想退回去"的真实场景。
  static const int _kUndoLimit = 20;

  /// 上次导出的文件相对路径（用于"再点一次导出"时提示去哪找）。
  String _lastExport = '';

  /// 是否正在导入（扫描项目文件 + 解析）。
  bool _importing = false;

  /// 是否正在整项目扫描（比 [_importing] 范围大：扫全部 dart 文件）。
  ///
  /// 和 [_importing] 分开是因为它们会**嵌套**：`pickProjectPage` 先
  /// 整项目扫描（[_scanning]），选中后再走单个文件的导入（[_importing]）。
  /// 合成一个变量的话，前者结束时会顺手把后者的状态也清掉。
  bool _scanning = false;

  /// 上一次项目扫描的结果。重复点扫描按钮时直接用缓存起手，
  /// 用户先看到一个列表（可能已经过期），再被刷新 —— 比盯着转圈好。
  ProjectScanResult? _lastScan;

  /// 当前设计的来源（导入时设置），形如 `lib/login_page.dart:42 · LoginPage`。
  ///
  /// 空串 = 不是导入来的（模板或手搭的）。
  /// 它有两个用处：工具栏上给用户看"这东西是从哪来的"；
  /// 生成时据此决定默认类名/文件名（`LoginPageDesign_...`）。
  String _importedFrom = '';

  /// 导入来源的原始类名（`LoginPage`）—— 只取类名部分，不带路径。
  /// 用于生成 `<原名>Design<时间戳>.dart` 这个文件名。
  String _importedClassName = '';

  /// 导入来源文件的**项目内绝对路径**（`/root/projects/x/lib/login_page.dart`）。
  ///
  /// 保存时"覆盖原文件"这个选项要写回它 —— 只在导入后才有值。
  String _importedPath = '';

  @override
  void initState() {
    super.initState();
    // 空白模板起步——但工具栏上有三个成品模板，一键铺开。
    // 刻意不默认给"登录页"：用户点进来看到一屏已经排好的东西，
    // 第一反应是"这不是我要的"，还得先全删掉。
  }

  // ============================ 树操作 ============================

  /// 按 id 找节点（含父节点，便于删除/移动）。
  ({DesignNode? parent, DesignNode? node}) _find(String id) {
    DesignNode? parent;
    DesignNode? node;
    void walk(DesignNode n, DesignNode? p) {
      if (node != null) return;
      if (n.id == id) {
        parent = p;
        node = n;
        return;
      }
      for (final c in n.children) {
        walk(c, n);
      }
    }

    walk(_root, null);
    return (parent: parent, node: node);
  }

  DesignNode? get _selected =>
      _selectedId.isEmpty ? null : _find(_selectedId).node;

  /// 改树之前的统一入口：压撤销栈 + 刷新。
  ///
  /// 所有修改都必须走这里 —— 直接改 + setState 的话，
  /// "撤销"会时灵时不灵（某些操作没入栈），用户会觉得这功能是坏的。
  void _mutate(void Function() change) {
    _undo.add(_root.clone());
    if (_undo.length > _kUndoLimit) _undo.removeAt(0);
    change();
    setState(() {});
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    setState(() {
      _root = _undo.removeLast();
      // 选中节点可能已经不存在了（被撤销掉的那次改动加进去的），
      // 留着的话属性面板会指向一个找不到的节点，显示成空白。
      if (_selectedId.isNotEmpty && _find(_selectedId).node == null) {
        _selectedId = '';
      }
    });
  }

  /// 往当前选中节点追加一个子节点。
  void _addChild(DesignComponentType type) {
    final sel = _selected ?? _root;
    if (!sel.acceptsChildren) {
      _toast('「${sel.label}」不能再往里放东西，请先选页面或卡片');
      return;
    }
    // 外壳组件一页只能有一个 —— 两个 AppBar 生成出来是编译错误
    // （`Scaffold` 只有一个 appBar 参数），两个 FAB 则是叠在一起。
    // 这里提前拦住，比让用户生成完再对着编译错误发呆好。
    //
    // 排除根节点自己：`_addChild` 的 sel 可能就是 root，而 root 不是外壳。
    if (DesignCodeGen.isShellType(type) && _hasShellInRoot(type)) {
      _toast('「${type.label}」一页只能有一个');
      return;
    }
    final child = DesignNode(type: type);
    _mutate(() => sel.children.add(child));
    setState(() => _selectedId = child.id);
  }

  /// 根节点的直接子节点里是否已经有该外壳类型。
  ///
  /// 只查**直接子节点**，与生成器的 `_pick` 保持一致：被误拖进卡片里的
  /// AppBar 不会被生成，也就不该占住"已经有一个了"的名额。
  bool _hasShellInRoot(DesignComponentType t) {
    for (final c in _root.children) {
      if (c.type == t) return true;
    }
    return false;
  }

  /// 在当前选中节点**前面/后面**插入同级节点。
  ///
  /// 这是"往根节点加东西"的主要路径：选中根节点的第一个子节点，
  /// 点「上移」位置插入 —— 不然想在最上面加一个标题，
  /// 得先加到最后再一路移上去。
  ///
  /// ## 两个入口，共用这一条实现
  ///
  /// 1. **组件库「上方/下方插入」**：先在组件库**长按**选中一个类型
  ///    （写入 [_pendingType]），再点插入按钮 —— 此时 `type` 传的就是
  ///    长按的那个类型，"长按选中控件 → 上下方插入"的字面语义成立。
  /// 2. 其它调用点（如有）可显式指定类型。
  ///
  /// 没有长按选中时**不做硬编码兜底**：早期版本这里恒插 `text`，
  /// 结果用户长按选中「按钮」、点「上方插入」却插出文本框 —— 交互与
  /// 结果对不上。现在改为在 UI 层禁用按钮（见 [_galleryPanel]），
  /// 让"能不能点"直接反映"有没有选中"。
  void _insertSibling(DesignComponentType type, {required bool before}) {
    final id = _selectedId;
    if (id.isEmpty) {
      // 没选中任何节点 = 没有"同级"概念 → 退化成往根节点追加。
      _addChild(type);
      return;
    }
    final found = _find(id);
    final parent = found.parent;
    if (parent == null) {
      // 选中的是根节点 → 没有同级概念，退化成追加
      _addChild(type);
      return;
    }
    // 外壳组件（AppBar/FAB/TabBar/BottomNav）一页只能有一个，
    // 与 `_addChild` 保持同一道闸 —— 两条入口都通到生成器，
    // 只在一条上拦等于没拦。
    if (DesignCodeGen.isShellType(type) && _hasShellInRoot(type)) {
      _toast('「${type.label}」一页只能有一个');
      return;
    }
    final child = DesignNode(type: type);
    _mutate(() {
      final at = parent.children.indexOf(found.node!);
      parent.children.insert(before ? at : at + 1, child);
    });
    setState(() => _selectedId = child.id);
  }

  void _delete() {
    final id = _selectedId;
    if (id.isEmpty) return;
    final found = _find(id);
    if (found.node == null || found.node!.type == DesignComponentType.root) {
      _toast('页面根节点不能删除');
      return;
    }
    final parent = found.parent;
    if (parent == null) return;
    _mutate(() => parent.children.remove(found.node!));
    setState(() => _selectedId = parent.id);
  }

  void _move({required int delta}) {
    final id = _selectedId;
    if (id.isEmpty) return;
    final found = _find(id);
    final parent = found.parent;
    if (parent == null || found.node == null) {
      _toast('页面根节点不能移动');
      return;
    }
    final at = parent.children.indexOf(found.node!);
    final to = at + delta;
    if (to < 0 || to >= parent.children.length) return;
    _mutate(() {
      parent.children.removeAt(at);
      parent.children.insert(to, found.node!);
    });
  }

  /// 应用模板（会覆盖当前设计）。
  Future<void> _applyTemplate(DesignTemplate t) async {
    // 空白模板 + 没改过 → 不值得弹确认框，直接换
    final needsConfirm = _root.children.isNotEmpty;
    if (needsConfirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('套用模板'),
          content: Text('「${t.label}」会替换掉当前设计。\n'
              '（可以用「撤销」退回来）'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    _mutate(() {
      _root = t.build();
      _template = t;
      _selectedId = '';
      _collapsed.clear();
    });
  }

  // ============================ 导入已有 UI ============================
  //
  // 用户需求原话：*"能不能给页面加一个自定义页面，将已经写好的 UI
  // 显示在这里面改。"*
  //
  // 流程：扫项目 → 选 dart 文件 → 选里面的 build → 解析成设计树。
  // 解析逻辑全在 `design_import.dart`（纯函数，可脱机测试），
  // 这里只负责"选什么"和"失败怎么说话"。

  /// 第一步：列项目里的 dart 文件，让用户挑一个。
  Future<void> _pickDartFile() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final root = '/root/projects/${widget.projectName}/lib';
      final files = await findDartFiles(_listDir, root);
      if (!mounted) return;
      setState(() => _importing = false);
      if (files.isEmpty) {
        _toast('这个项目的 lib/ 下没找到 dart 文件');
        return;
      }
      final picked = await _showFilePicker(files, root);
      if (picked == null || !mounted) return;
      await _pickBuildIn(picked);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      _toast('读取项目文件失败：$e');
    }
  }

  /// 文件选择弹层。
  Future<String?> _showFilePicker(List<String> files, String root) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final c = FoaColors.of(ctx);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (ctx, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('选一个页面文件',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    Text('${files.length} 个',
                        style: TextStyle(fontSize: 11, color: c.muted)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemCount: files.length,
                  itemBuilder: (ctx, i) {
                    final f = files[i];
                    final rel = f.startsWith('$root/')
                        ? f.substring(root.length + 1)
                        : f;
                    // 深目录用「父目录/文件名」两行显示，一行塞不下。
                    final slash = rel.lastIndexOf('/');
                    final dir = slash < 0 ? '' : rel.substring(0, slash);
                    final name = slash < 0 ? rel : rel.substring(slash + 1);
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.description_outlined, size: 20),
                      title: Text(name, style: const TextStyle(fontSize: 13.5)),
                      subtitle: dir.isEmpty
                          ? null
                          : Text(dir,
                              style: TextStyle(fontSize: 10.5, color: c.muted)),
                      onTap: () => Navigator.of(ctx).pop(f),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 第二步：读文件、列里面的 build，让用户挑一个。
  Future<void> _pickBuildIn(String path) async {
    setState(() => _importing = true);
    try {
      final read = await widget.bridge.read(path);
      if (!mounted) return;
      if (!read.ok) {
        setState(() => _importing = false);
        // 2MB 上限是 Kotlin 侧的硬限制，把话说清楚，
        // 否则用户会以为是这个文件"坏了"。
        _toast('读不了这个文件：${read.error ?? "未知错误"}'
            '（超过 2MB 的大文件读不了）');
        return;
      }
      final candidates = findCandidates(read.content);
      setState(() => _importing = false);
      if (candidates.isEmpty) {
        _toast('这个文件里没找到 build 方法 —— 界面可能写在别的方法里');
        return;
      }
      if (!mounted) return;
      final picked = await _showCandidatePicker(path, candidates);
      if (picked == null || !mounted) return;
      _applyImport(path, read.content, picked);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      _toast('导入失败：$e');
    }
  }

  Future<ImportCandidate?> _showCandidatePicker(
      String path, List<ImportCandidate> cs) {
    return showModalBottomSheet<ImportCandidate>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final c = FoaColors.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '导入哪个界面？',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  path.split('/').last,
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: cs.length,
                  itemBuilder: (ctx, i) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.widgets_outlined, size: 20),
                    title: Text(cs[i].displayName,
                        style: const TextStyle(fontSize: 13.5)),
                    subtitle: Text('第 ${cs[i].line} 行',
                        style: TextStyle(fontSize: 10.5, color: c.muted)),
                    onTap: () => Navigator.of(ctx).pop(cs[i]),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 第三步：真的导入（解析 + 落进设计树）。
  void _applyImport(String path, String source, ImportCandidate c) {
    final result = importCandidate(source, c);
    if (result.root.children.isEmpty) {
      // 解析不出来时**不要**动用户当前的设计 ——
      // 导入失败还把他辛苦搭的东西清掉，是最恼人的失败方式。
      _toast(result.hasNotes ? result.notes.first : '没解析出界面内容');
      return;
    }
    final rel = path.startsWith('/root/projects/${widget.projectName}/')
        ? path.substring('/root/projects/${widget.projectName}/'.length)
        : path;
    _mutate(() {
      _root = result.root;
      _selectedId = '';
      _collapsed.clear();
      _importedFrom = '$rel:${c.line} · ${c.displayName}';
      _importedClassName = c.displayName;
      _importedPath = path;
    });
    final parts = <String>['导入成功：${result.converted} 个组件'];
    if (result.unknown > 0) {
      // alpha.75：不再一律叫"原样带回"。能提取出视觉信息的那些是
      // **近似还原**（预览里画得出接近的样子），提取不到的才是纯兜底。
      // 用户看到"近似还原"就知道预览里那些方块不是乱画的。
      parts.add('${result.unknown} 个未识别组件（已尽力还原外观，生成时原样带回）');
    }
    _toast(parts.join('，'));
    if (result.hasNotes) {
      // 提醒（比如"Row 摊平成竖排了"）不能只塞在 toast 里 ——
      // toast 两秒就没了，用户很可能没看见就已经开始改了。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showNotesSheet(result.notes);
      });
    }
  }

  void _showNotesSheet(List<String> notes) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final c = FoaColors.of(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 17, color: c.warning),
                    const SizedBox(width: 8),
                    const Text('导入时的调整',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 10),
                for (final n in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('· ', style: TextStyle(color: c.muted)),
                        Expanded(
                          child: Text(n,
                              style: TextStyle(
                                  fontSize: 12.5, height: 1.5, color: c.muted)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('知道了'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ============================ 导出 ============================

  /// 生成代码 → **先给用户看** → 他点「保存」才落盘。
  ///
  /// ## 为什么把顺序倒过来（alpha.71 改）
  ///
  /// alpha.70 是"先写 `lib/generated/` 再弹预览"。两个问题：
  ///
  /// 1. **写盘是不可逆的**，而用户此时还没看过生成物。他点一下按钮，
  ///    项目里就多了一个文件 —— 万一不满意，还得自己去删。
  /// 2. 从「保存为新文件」变成可能之后，**保存目标本身就是要问的**
  ///    （覆盖原文件？还是新建？）。先写再问的顺序说不通。
  ///
  /// 现在的顺序：预览 → 用户看过觉得行 → 点「保存」→ 弹去向 → 落盘。
  /// 破坏性操作留在验证之后。
  Future<void> _export() async {
    if (_exporting) return;
    // 空设计导出一个空 Scaffold 没意义，先拦一下（不然用户会以为导出坏了）
    if (_root.children.isEmpty) {
      _toast('设计还是空的，先从组件库加几个组件或套个模板');
      return;
    }
    setState(() => _exporting = true);
    final now = DateTime.now();
    // 导入来的用 `<原名>Design<时间戳>`，手搭的用 `Design<时间戳>` ——
    // 带原名用户一眼看得出血缘（"这个是从 LoginPage 改出来的"）。
    final className = _importedClassName.isEmpty
        ? DesignCodeGen.classNameFor(now)
        : DesignCodeGen.classNameForImport(_importedClassName, now);
    final fileName = _importedClassName.isEmpty
        ? DesignCodeGen.fileNameFor(now)
        : DesignCodeGen.fileNameForImport(_importedClassName, now);
    DesignCodeGen.timestamp = _fmt(now);
    final code = DesignCodeGen.generate(_root, className: className);
    final defaultRel = 'lib/generated/$fileName';
    setState(() => _exporting = false);
    await _showCodeSheet(code, defaultRel);
  }

  String _fmt(DateTime t) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} '
        '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }

  /// 代码预览弹层：看 → 复制 → 打开 → **保存**。
  Future<void> _showCodeSheet(String code, String rel) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final c = FoaColors.of(ctx);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (ctx, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(rel,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                    IconButton(
                      tooltip: '复制代码',
                      icon: const Icon(Icons.copy, size: 20),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: code));
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('代码已复制')),
                          );
                        }
                      },
                    ),
                    IconButton(
                      tooltip: '在代码区打开',
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        widget.onOpenFile(
                            _lastExport.isEmpty ? rel : _lastExport);
                      },
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _askSaveTarget(code, rel);
                      },
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: const Text('保存'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsets.all(14),
                  child: SelectableText(
                    code,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.45,
                      color: c.muted,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============================ 保存去向 ============================

  /// 保存时问：覆盖原文件，还是存成新文件？
  ///
  /// 只有**导入来的**设计才给"覆盖"这个选项 —— 手搭的设计没有
  /// "原文件"可覆盖，给个假选项只会让人困惑。
  Future<void> _askSaveTarget(String code, String defaultRel) async {
    final canOverwrite = _importedPath.isNotEmpty;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存到哪里'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (canOverwrite) ...[
              // ⚠️ 这句话必须说。用户以为"我改的界面覆盖回去"是天经地义的，
              // 他不知道设计器**只生成静态界面** —— 选覆盖会把原文件里的
              // 业务逻辑、状态、路由**全部删掉**。
              // 不说清楚就让他点，等于设了个陷阱。
              Text(
                '覆盖 ${_importedPath.split('/').last} 会把它的'
                '业务逻辑、状态管理、路由全部替换掉，只剩静态界面。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: FoaColors.of(ctx).danger,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              canOverwrite ? '或者存成新文件（推荐）：' : '存成新文件：',
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 4),
            SelectableText(
              defaultRel,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('取消'),
          ),
          if (canOverwrite)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('overwrite'),
              style: TextButton.styleFrom(
                  foregroundColor: FoaColors.of(ctx).danger),
              child: const Text('覆盖原文件'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('new'),
            child: const Text('存为新文件'),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel' || !mounted) return;

    if (choice == 'overwrite') {
      await _saveOverwrite(code);
    } else {
      await _saveNew(code, defaultRel);
    }
  }

  /// 覆盖原文件（先备份）。
  Future<void> _saveOverwrite(String code) async {
    final backup = '$_importedPath.bak';
    try {
      // 先读原文备份。
      //
      // ⚠️ 用 `.dart.bak` 而不是 `.bak`：前者不以 `.dart` 结尾，
      // `findDartFiles` 不会把它当源文件扫出来、`dart analyze` 也不会
      // 把它当源文件 —— 否则用户会看到一个"永远报错的幽灵文件"
      // （备份里可能有半截代码）。这是选 `.dart.bak` 的唯一原因。
      final old = await widget.bridge.read(_importedPath);
      if (old.ok) {
        final b = await widget.bridge.write(backup, old.content);
        if (!b.ok && mounted) {
          // 备份失败就**不能**继续覆盖 —— 那是真的会丢代码的。
          _toast('备份失败，已中止：${b.error ?? "未知错误"}');
          return;
        }
      }
      final res = await widget.bridge.write(_importedPath, code);
      if (!mounted) return;
      if (!res.ok) {
        _toast('写入失败：${res.error ?? "未知错误"}');
        return;
      }
      final rel =
          _importedPath.startsWith('/root/projects/${widget.projectName}/')
              ? _importedPath
                  .substring('/root/projects/${widget.projectName}/'.length)
              : _importedPath;
      setState(() => _lastExport = rel);
      _toast('已覆盖 $rel（原文件备份为 .dart.bak）');
    } catch (e) {
      if (!mounted) return;
      _toast('写入失败：$e');
    }
  }

  /// 存成新文件（默认路径，不动原文件）。
  Future<void> _saveNew(String code, String rel) async {
    final path = '/root/projects/${widget.projectName}/$rel';
    try {
      final res = await widget.bridge.write(path, code);
      if (!mounted) return;
      if (!res.ok) {
        _toast('写入失败：${res.error ?? "未知错误"}');
        return;
      }
      setState(() => _lastExport = rel);
      _toast('已生成 $rel');
      widget.onOpenFile(rel);
    } catch (e) {
      if (!mounted) return;
      _toast('写入失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ==================== 对外接口（给编辑器/工作台用）====================
  //
  // 从 alpha.72 起，「实时预览」不再走 Web 编译，而是直接用设计区这套
  // 渲染管线 —— 它本来就是把设计树 build 成**真 Flutter Widget**，
  // 帧级速度、零编译、零等待。
  //
  // 编辑器工具栏、工作台动作卡片、构建通知路由都通过下面三个方法
  // 把用户送进来。它们只做"切视图 + 载数据"，不做任何 UI 决策 ——
  // 三个入口的交互差异（弹菜单还是直接跳）留在各自的页面里。

  /// 外部入口：把某个文件里的界面直接导入设计树并切到设计区。
  ///
  /// [path] 是容器内的绝对路径（`/root/projects/x/lib/login_page.dart`）。
  ///
  /// ## 为什么不复用 [_pickDartFile]
  ///
  /// 那个方法从"列目录"开始，是给**还在选文件**的用户用的。
  /// 这里路径已经确定了，再让他从一堆文件里找一遍自己刚点的那个
  /// 是纯粹的浪费。所以这条路径直接从 [_pickBuildIn] 开始 ——
  /// 仍有一步"选哪个 build"的弹窗，因为一个文件里可能有多个页面类，
  /// 那是**必须**问的（猜错的话用户会看到完全不相干的界面）。
  Future<void> importFrom(String path) async {
    if (_importing) return;
    await _pickBuildIn(path);
  }

  /// 外部入口：打开全屏预览（设备尺寸 + 主题模拟）。
  ///
  /// 复用同一个 [DesignPageState]，所以打开的是**当前正在编辑的这棵树**，
  /// 不是快照 —— 全屏里看到的就是预览区里看到的。
  Future<void> openFullscreenPreview() async {
    if (!mounted) return;
    await showFullscreenPreview(context, state: this);
  }

  /// 外部入口：重新扫描项目，看看多了/少了哪些可预览的页面。
  ///
  /// 返回结果而不是直接弹窗，让调用方能自己决定怎么呈现
  /// （工具栏按钮弹选择器、构建卡片只显示个数）。
  Future<ProjectScanResult> refreshPreview() => scanProject();

  /// 扫描整个项目的可预览页面。
  ///
  /// 与 [_pickDartFile] 的区别：那个**只扫 `lib/` 且只列文件**，
  /// 用户拿到的是一个文件列表，还得再点一层才知道里面有什么。
  /// 这个直接把「文件 + 类名」摊平成一个列表 —— 用户看到的
  /// 是"LoginPage""HomePage"，而不是"login_page.dart""home_page.dart"。
  ///
  /// 入口更多不等于更慢：一次 BFS 遍历 + 每文件一次 parse，
  /// 一个中等项目（几十个文件）在真机上是一秒级的事。
  Future<ProjectScanResult> scanProject({bool notify = true}) async {
    if (_scanning) return _lastScan ?? ProjectScanResult.empty;
    _scanning = true;
    if (notify && mounted) setState(() {});
    try {
      final result = await scanProjectPages(
        _listDir,
        _readFile,
        '/root/projects/${widget.projectName}/lib',
      );
      _lastScan = result;
      return result;
    } catch (e) {
      final result = ProjectScanResult(
        entries: const <ProjectPageEntry>[],
        scannedFiles: 0,
        filesFound: 0,
        failedFiles: 0,
        notes: <String>['扫描失败：$e'],
      );
      _lastScan = result;
      return result;
    } finally {
      _scanning = false;
      if (notify && mounted) setState(() {});
    }
  }

  /// 把 [FsBridge] 的 list 包成 [ListDirFn]。
  ///
  /// 抽出来是因为 [_pickDartFile] 和 [scanProject] 都要用同一份
  /// 错误处理（列目录失败要抛，让 `findDartFiles` 跳过这个目录，
  /// 而不是把整次扫描带崩）。
  ListDirFn get _listDir => (path) async {
        final r = await widget.bridge.list(path);
        if (!r.ok) throw StateError(r.error ?? '列目录失败');
        return r.entries
            .map((e) => DirEntry(name: e.name, isDir: e.isDir, size: e.size))
            .toList();
      };

  /// 把 [FsBridge] 的 read 包成 [ReadFileFn]。
  ///
  /// 读失败返回 null（而不是抛）：`scanProjectPages` 把 null 当作
  /// "这个文件跳过"，抛异常会变成"这次扫描失败" —— 对用户的区别是
  /// "少一个页面"和"什么都没扫出来"。
  ReadFileFn get _readFile => (path) async {
        final r = await widget.bridge.read(path);
        return r.ok ? r.content : null;
      };

  /// 弹出「项目里能预览的页面」选择器，选中的直接导入设计树。
  ///
  /// 给不经过 [_pickDartFile] 的入口用（构建完成通知、编辑器菜单）。
  Future<void> pickProjectPage() async {
    if (_scanning) return;
    final result = await scanProject();
    if (!mounted) return;
    if (result.isEmpty) {
      // 扫描空了要给一句**具体**的话。只说"没找到"用户没法判断
      // 是自己目录不对、还是项目真没页面 —— `summary` 里带了
      // 扫了多少个文件。
      _toast(result.summary);
      return;
    }
    final picked = await _showProjectPagePicker(result);
    if (picked == null || !mounted) return;
    await importFrom(picked.path);
  }

  /// 项目页面选择器：一行一个「文件名 › 类名」，带扫描统计。
  Future<ProjectPageEntry?> _showProjectPagePicker(ProjectScanResult r) {
    return showModalBottomSheet<ProjectPageEntry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final c = FoaColors.of(ctx);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.65,
          maxChildSize: 0.9,
          builder: (ctx, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('预览项目里的页面',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    Text('${r.entries.length} 个',
                        style: TextStyle(fontSize: 11, color: c.muted)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(r.summary,
                      style: TextStyle(fontSize: 11, color: c.muted)),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  itemCount: r.entries.length,
                  itemBuilder: (ctx, i) {
                    final e = r.entries[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.widgets_outlined, size: 20),
                      title: Text(e.candidate.displayName,
                          style: const TextStyle(fontSize: 13.5)),
                      subtitle: Text(
                        '${e.label.split(' › ').first} · 第 ${e.candidate.line} 行',
                        style: TextStyle(fontSize: 10.5, color: c.muted),
                      ),
                      onTap: () => Navigator.of(ctx).pop(e),
                    );
                  },
                ),
              ),
              if (r.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      r.notes.first,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: c.warning),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 当前设计树的根（全屏预览要拿它去渲染）。
  DesignNode get currentRoot => _root;

  /// 有没有内容可预览。
  bool get hasContent => _root.children.isNotEmpty;

  /// 全屏预览用的渲染函数。
  ///
  /// 直接把 State 的 [_buildPreview] 借出去 —— 全屏页和预览区
  /// **必须是同一个渲染实现**。各写一份的话两边会长歪
  /// （"小窗里对的，全屏里错了"是最难查的那种 bug）。
  Widget renderPreview(DesignNode node) => _buildPreview(node);

  /// 测试专用：把外部造好的设计树直接设成当前根。
  ///
  /// 存在的理由：预览里有一条**只有 `node == _root` 才会走**的分支
  /// （[_previewShell]，套 Scaffold）。测试若只调 [renderPreview]，
  /// 拿到的是别人的节点、永远进不去那条分支 —— 真机上必崩的路径
  /// 在测试里却是绿的。这个口子就是为了让测试能走**真机同一条路**。
  @visibleForTesting
  void debugSetRoot(DesignNode root) {
    _mutate(() {
      _root = root;
      _selectedId = '';
      _collapsed.clear();
    });
  }

  // ============================ 构建 ============================

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    if (wide) {
      return Column(
        children: [
          _toolbar(),
          const Divider(height: 1),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 5, child: _previewArea()),
                const VerticalDivider(width: 1),
                Expanded(flex: 4, child: _panelColumn()),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        _toolbar(),
        const Divider(height: 1),
        // 预览给固定高度而不是 Expanded：下方三个面板需要确定的空间，
        // 全给 Expanded 的话面板会被压到几乎看不见。
        SizedBox(height: 240, child: _previewArea()),
        const Divider(height: 1),
        Expanded(child: _panelColumn()),
      ],
    );
  }

  // ---------------- 工具栏 ----------------

  Widget _toolbar() {
    final c = FoaColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          // 模板入口。用 PopupMenuButton 而不是三个按钮：
          // 模板会越来越多，按钮排不下会折行（Bug 479 的教训）。
          PopupMenuButton<DesignTemplate>(
            tooltip: '套用模板',
            onSelected: _applyTemplate,
            itemBuilder: (ctx) => [
              for (final t in DesignTemplate.values)
                PopupMenuItem(value: t, child: Text(t.label)),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.dashboard_customize_outlined,
                    size: 18, color: c.muted),
                const SizedBox(width: 6),
                Text(_template.label, style: const TextStyle(fontSize: 13)),
                Icon(Icons.arrow_drop_down, size: 18, color: c.muted),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '撤销',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.undo, size: 18),
            onPressed: _undo.isEmpty ? null : _undoLast,
          ),
          IconButton(
            tooltip: '删除选中',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: _selectedId.isEmpty ? null : _delete,
          ),
          // alpha.71：把项目里已经写好的界面导进来改。
          //
          // 放在撤销/删除旁边而不是最右：它不是"结束动作"
          // （最右的「生成代码」才是），它是"开始动作" ——
          // 用户进来第一件事可能就是导入一个已有页面。
          IconButton(
            tooltip: '导入已有 UI',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.file_download_outlined, size: 18),
            onPressed: _importing ? null : _pickDartFile,
          ),
          const Spacer(),
          // alpha.74 修：导入路径文字**曾把右侧的保存按钮挤出屏幕**。
          //
          // 原因：这一行是 `Row`，`Spacer()` 之后依次是路径文字（maxWidth
          // 180）和「生成代码」按钮。窄屏上路径文字先占满，按钮被推到
          // 屏幕外 —— 用户看到的工具栏没有保存入口，只能干瞪眼。
          // 更糟的是旁边那个「导入已有 UI」用的也是下载箭头图标，
          // 用户会误以为它就是保存。
          //
          // 修法：路径文字降级为**短标签**（只显示文件名，不显示行号），
          // 并让它可收缩（Flexible + ellipsis）；按钮保持 `FilledButton`
          // 且**永不省略**——它现在是工具栏上唯一有文字的实心按钮，
          // 视觉上就是主操作。
          if (_importedFrom.isNotEmpty)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link, size: 13, color: c.muted),
                    const SizedBox(width: 4),
                    // 显示"来自哪个文件" —— 用户改到一半忘了这东西是从
                    // 哪来的、要存回哪去，这行是他唯一的线索。
                    // 但**只给文件名**（去掉路径与行号）：完整路径在窄屏上
                    // 会把按钮挤掉，而文件名已足够唤起记忆。
                    Flexible(
                      child: Text(
                        _importedFrom.split('·').first.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(fontSize: 11, color: c.muted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_lastExport.isNotEmpty)
            // 「上次：xxx」同样会挤压按钮 —— 只留文件名且允许收缩。
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text('上次：${_lastExport.split('/').last}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(fontSize: 11, color: c.muted)),
              ),
            ),
          // 工具栏上唯一的保存入口。
          //
          // alpha.74 修：它之前会被左侧文字挤出屏幕。除了压缩左侧文字，
          // 这里再给按钮加一道保险 —— 文字更直白（「生成代码」不改名，
          // 因为用户点进去看到的确实是代码预览，改名「保存」会与
          // "先预览再保存"的实际流程不符），但补 tooltip 说明它能落盘。
          Tooltip(
            message: '生成代码后可保存到项目',
            child: FilledButton.icon(
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.code, size: 16),
              label: const Text('生成代码'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 预览 ----------------

  Widget _previewArea() {
    final c = FoaColors.of(context);
    return Container(
      color: c.panelBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 4, 0),
            child: Row(
              children: [
                Icon(Icons.visibility_outlined, size: 13, color: c.muted),
                const SizedBox(width: 6),
                Text('实时预览',
                    style: TextStyle(
                        fontSize: 11, color: c.muted, letterSpacing: 1)),
                const SizedBox(width: 8),
                // 把"零编译"这件事说出来。用户习惯了 Web 预览要等几分钟，
                // 不给个说法他不会相信这里是即时的 —— 尤其在 app 卡了一下的
                // 时候（第一反应必然是"又编译上了"）。
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: c.success.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '零编译',
                    style: TextStyle(
                        fontSize: 9.5,
                        color: c.success,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                const Spacer(),
                if (_scanning)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                // 扫描项目页面：从"文件列表"升级成"页面列表"。
                IconButton(
                  tooltip: '预览项目里的页面',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  icon: const Icon(Icons.travel_explore_outlined),
                  onPressed: _scanning ? null : pickProjectPage,
                ),
                // 全屏预览：这是"预览"这件事真正的主场 ——
                // 240px 高的缝里验不了布局，全屏 + 设备尺寸才行。
                //
                // alpha.73：按钮点下去直接进**真机全屏**（铺满整块屏幕）。
                // 早先它打开的是一个"带边框、带说明条、缩放到放得下"的
                // 模拟画布 —— 那不是全屏。模拟尺寸那一档仍在页面里，
                // 从全屏浮层可以切过去。
                IconButton(
                  tooltip: '全屏预览（铺满屏幕，可切回模拟尺寸）',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  icon: const Icon(Icons.fullscreen),
                  onPressed:
                      _root.children.isEmpty ? null : openFullscreenPreview,
                ),
                const SizedBox(width: 2),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('点树里的节点可选中',
                  style: TextStyle(fontSize: 10, color: c.muted)),
            ),
          ),
          Expanded(
            child: _root.children.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        '还没有组件\n\n从下面「组件库」点一个加进来，\n或者用左上角套个模板',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, height: 1.6, color: c.muted),
                      ),
                    ),
                  )
                // 真渲染而不是画个示意：我们本来就是 Flutter，
                // 把树转成真 Widget 直接 build，所见即所得没有中间层。
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: _buildPreview(_root),
                  ),
          ),
        ],
      ),
    );
  }

  /// 把设计节点渲染成**真实 Widget**（预览用）。
  ///
  /// 与 [DesignCodeGen] 是两条独立实现（一条出 Widget、一条出字符串），
  /// 看起来有重复 —— 但这是刻意的：
  /// 让预览去"执行生成的代码字符串"需要 `eval`（Dart 没有）或热重载，
  /// 代价远超收益。两边都由 [DesignComponentType] 的属性表驱动，
  /// 加组件时同步改两处即可（有单测盯着两边的字段键一致）。
  ///
  /// ⚠️ 唯一的例外是"哪些节点算页面外壳"这个判定：两边**必须**共用
  /// `DesignCodeGen.isShellType`。各写一份的话，一旦漏改就会出现
  /// "预览里有顶栏、生成的代码里没有" —— 这种不一致用户几乎不可能自查出来。
  Widget _buildPreview(DesignNode node) {
    Widget real;
    switch (node.type) {
      case DesignComponentType.root:
        // 外壳节点（顶栏/标签栏/悬浮按钮/底部导航）不参与 body 的 Column ——
        // 它们在 Flutter 里是 `Scaffold(...)` 的命名参数。这里先摘出来，
        // 判定规则与生成器共用 `isShellType`。
        final bodyChildren = node.children
            .where((c) => !DesignCodeGen.isShellType(c.type))
            .toList();
        final children = bodyChildren.map(_buildPreview).toList();
        final pad = (node.props['padding'] as num?)?.toDouble() ?? 16;
        Widget col = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: children,
        );
        if (pad > 0) {
          col = Padding(padding: EdgeInsets.all(pad), child: col);
        }
        final bg = _previewColor(node.props['background']);
        real = bg == null
            ? col
            : ColoredBox(
                color: bg, child: SizedBox(width: double.infinity, child: col));
        // 根节点：把外壳参数真的套上 Scaffold。
        //
        // 不套的话，用户加了顶栏却在预览里什么都看不到，只会以为"点了没生效"，
        // 然后去点第二次、第三次。所见即所得在这里不是锦上添花，是防误操作。
        if (node == _root) {
          real = _previewShell(node, real);
          return _selectedWrap(node, real);
        }

      case DesignComponentType.heading:
      case DesignComponentType.text:
        final align = node.props['align'] as String? ?? 'left';
        final size = (node.props['size'] as num?)?.toDouble() ?? 14;
        final color = _previewColor(node.props['color']) ?? _cs.onSurface;
        final t = Text(
          (node.props['text'] ?? '').toString(),
          textAlign: switch (align) {
            'center' => TextAlign.center,
            'right' => TextAlign.right,
            _ => TextAlign.left,
          },
          style: TextStyle(
            fontSize: size,
            color: color,
            fontWeight: node.type == DesignComponentType.heading &&
                    node.props['bold'] == true
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        );
        real = Container(
          alignment: switch (align) {
            'center' => Alignment.center,
            'right' => Alignment.centerRight,
            _ => Alignment.centerLeft,
          },
          width: double.infinity,
          child: t,
        );

      case DesignComponentType.button:
        final txt = (node.props['text'] ?? '').toString();
        final style = node.props['style'] as String? ?? 'filled';
        final btn = switch (style) {
          'outlined' => OutlinedButton(onPressed: () {}, child: Text(txt)),
          'text' => TextButton(onPressed: () {}, child: Text(txt)),
          _ => FilledButton(onPressed: () {}, child: Text(txt)),
        };
        real = node.props['width'] == 'full'
            ? SizedBox(width: double.infinity, child: btn)
            : Align(alignment: Alignment.centerLeft, child: btn);

      case DesignComponentType.textField:
        real = TextField(
          enabled: false,
          obscureText: node.props['obscure'] == true,
          decoration: InputDecoration(
            labelText: (node.props['label'] ?? '').toString(),
            hintText: (node.props['hint'] ?? '').toString(),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        );

      case DesignComponentType.image:
        final h = (node.props['height'] as num?)?.toDouble() ?? 160;
        final r = (node.props['radius'] as num?)?.toDouble() ?? 12;
        real = Container(
          height: h,
          decoration: BoxDecoration(
            color: _cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(r),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_outlined, size: 28, color: _c.muted),
              const SizedBox(height: 4),
              Text((node.props['label'] ?? '').toString(),
                  style: TextStyle(fontSize: 11, color: _c.muted)),
            ],
          ),
        );

      case DesignComponentType.icon:
        real = Align(
          alignment: Alignment.centerLeft,
          child: Icon(
            _previewIcon(node.props['name']),
            size: (node.props['size'] as num?)?.toDouble() ?? 32,
            color: _previewColor(node.props['color']) ?? _cs.primary,
          ),
        );

      case DesignComponentType.spacer:
        real =
            SizedBox(height: (node.props['height'] as num?)?.toDouble() ?? 16);

      case DesignComponentType.divider:
        real = Divider(
            thickness: (node.props['thickness'] as num?)?.toDouble() ?? 1);

      case DesignComponentType.box:
        {
          final w = (node.props['width'] as num?)?.toDouble();
          final h = (node.props['height'] as num?)?.toDouble();
          final r = (node.props['radius'] as num?)?.toDouble() ?? 0;
          // 色位 `none` = 不生成 color 参数（和生成器一致）。但预览里
          // 什么都不画就真的看不见了，所以这里给一个中性底 —— 预览的
          // 职责是"让用户看见这里有块东西"，不是复刻 Flutter 的默认色。
          final color =
              _previewColor(node.props['color']) ?? _cs.surfaceContainerHighest;
          real = Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: color,
              borderRadius: r > 0 ? BorderRadius.circular(r) : null,
            ),
            child: node.children.isEmpty
                ? null
                : Align(
                    alignment: Alignment.center,
                    child: _buildPreview(node.children.first),
                  ),
          );
          break;
        }

      case DesignComponentType.card:
        real = Card(
          elevation: (node.props['elevation'] as num?)?.toDouble() ?? 1,
          child: Padding(
            padding: EdgeInsets.all(
                (node.props['padding'] as num?)?.toDouble() ?? 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: node.children.map(_buildPreview).toList(),
            ),
          ),
        );

      case DesignComponentType.listTile:
        final subtitle = (node.props['subtitle'] ?? '').toString();
        real = ListTile(
          dense: true,
          leading: Icon(_previewIcon(node.props['leadingIcon']), size: 20),
          title: Text((node.props['title'] ?? '').toString()),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          onTap: () {},
        );

      case DesignComponentType.unknown:
        // 导入时没认出来的 widget。**不能什么也不画** ——
        // 空白会让用户以为"导入把它弄丢了"，然后去改本来没错的东西。
        //
        // alpha.75：优先**尽力还原**（源码里能读出来的尺寸/颜色/圆角
        // 就用它画），读不出来才退回提示框。详见 [_unknownPlaceholder]。
        //
        // 用户在属性面板手动设的宽高优先于源码提取值 —— 那是用户的
        // 显式意图，且生成时确实会包一层 `SizedBox`，预览与产出一致。
        real = _unknownSized(node) ?? _unknownPlaceholder(node);

      // 外壳节点的预览由 [_previewShell] 统一渲染（它们是 `Scaffold` 的
      // 命名参数，不在 body 里）。能走到这几个分支只有一种情况：用户把
      // 它们挂在了**非根节点**下（比如卡片里）。此时画一行提示而不是
      // 静默留白 —— 和生成器那条"只能放在页面根节点下"的注释对齐。
      case DesignComponentType.appBar:
      case DesignComponentType.tabBar:
      case DesignComponentType.fab:
      case DesignComponentType.bottomNav:
        real = _misplacedShellHint(node.type);
    }

    // 选中高亮：用一个细边框而不是改颜色 —— 改背景色会让用户
    // 分不清"这是预览的效果"还是"这是我选中造成的"。
    return _selectedWrap(node, real);
  }

  /// 给预览加"选中"高亮（根节点的提前返回也走这里，避免两处写法不一致）。
  Widget _selectedWrap(DesignNode node, Widget child) {
    if (node.id != _selectedId) return child;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: _cs.primary, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: child,
    );
  }

  /// 把根节点渲染成 `Scaffold`，并套上外壳节点（顶栏/标签栏/浮动按钮/底部导航）。
  ///
  /// 与 [DesignCodeGen._shellArgs] 一一对应，是刻意重复的第二套实现
  /// （见 [_buildPreview] 的说明）。**判定规则共用 `isShellType`**。
  ///
  /// 预览里用真 `Scaffold` 而不是把 AppBar 画成一行方块：用户要判断的正是
  /// "顶栏标题这么长会不会被截断""底部导航三个字挤不挤"，画方块等于没预览。
  Widget _previewShell(DesignNode root, Widget body) {
    DesignNode? pick(DesignComponentType t) {
      for (final c in root.children) {
        if (c.type == t) return c;
      }
      return null;
    }

    // 用不用 Scaffold，取决于有没有外壳。
    //
    // ⚠️ 不能无条件包 Scaffold：预览区是嵌在详情页布局里的一个小框，
    // Scaffold 会自带一层背景色和 MediaQuery 处理，把预览框撑成"另一个页面"
    // 的观感，和下面那三个面板抢视觉重心。没外壳时就保持原来的裸 Column。
    final appBar = pick(DesignComponentType.appBar);
    final fab = pick(DesignComponentType.fab);
    final nav = pick(DesignComponentType.bottomNav);
    final tabs = pick(DesignComponentType.tabBar);
    if (appBar == null && fab == null && nav == null) return body;

    // TabBar 要在 AppBar.bottom 里才有意义；没有 AppBar 时单独一个 TabBar
    // 也没法渲染（需要 TabController），所以只在有 appBar 时画。
    final tabBar = (tabs != null && appBar != null)
        ? TabBar(
            labelStyle: const TextStyle(fontSize: 12),
            tabs: [
              for (final k in kTabKeys)
                Tab(height: 34, text: (tabs.props[k] ?? '').toString()),
            ],
          )
        : null;

    return Scaffold(
      // 预览用的 Scaffold 不该自带 AppBar 的系统栏留白 —— 它在一个小框里，
      // 跟随外层即可。这里只关心内容的长相。
      appBar: appBar == null
          ? null
          : AppBar(
              title: Text(
                (appBar.props['title'] ?? '').toString(),
                style: const TextStyle(fontSize: 15),
              ),
              toolbarHeight: 44,
              leading: appBar.props['showBack'] == true
                  // disabled：生成物里没有 Navigator。给 null 而不是
                  // `() {}`，让返回箭头呈现灰色不可点 —— 这比"能点但没反应"
                  // 更早地告诉用户真相。
                  ? const BackButton(onPressed: null)
                  : null,
              bottom: tabBar,
            ),
      floatingActionButton: fab == null
          ? null
          : FloatingActionButton.small(
              onPressed: () {},
              tooltip: (fab.props['tooltip'] ?? '').toString(),
              child: Icon(_previewIcon(fab.props['icon'])),
            ),
      bottomNavigationBar: nav == null
          ? null
          : NavigationBar(
              height: 56,
              selectedIndex: 0,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                for (var i = 0; i < kNavKeys.length; i++)
                  NavigationDestination(
                    icon: Icon(_previewIconNav(nav.props['icons'], i)),
                    label: (nav.props[kNavKeys[i]] ?? '').toString(),
                  ),
              ],
            ),
      body: SafeArea(child: body),
    );
  }

  /// 从逗号分隔的 `icons` 串里取第 [i] 个图标名，直接给出 IconData。
  ///
  /// 越界时退回 `circle` 而不是抛异常：用户正在文本框里敲逗号，
  /// 中间态（`home,` 只有一个图标）必须能渲染，否则预览会在输入过程中崩掉。
  IconData _previewIconNav(Object? raw, int i) {
    final parts = (raw ?? '').toString().split(',');
    return _previewIcon(i < parts.length ? parts[i].trim() : 'circle');
  }

  ThemeData get _theme => Theme.of(context);
  ColorScheme get _cs => _theme.colorScheme;
  FoaColors get _c => FoaColors.of(context);

  /// 被放到非根节点下的外壳组件（顶栏塞进卡片里之类）在预览里的样子。
  ///
  /// 不画真的 AppBar：那个位置渲染 AppBar 会得到一条横在卡片里的灰条，
  /// 看起来像"它生效了"，但生成的代码里它其实被跳过了。如实说清楚更好。
  Widget _misplacedShellHint(DesignComponentType t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        '「${t.label}」只能放在页面根节点下\n把它拖到最外层，或用「上移」移到顶层',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 10.5, height: 1.5, color: _c.muted),
      ),
    );
  }

  /// 未识别组件在预览里的样子。
  ///
  /// ## alpha.75：从「一律画黄框」改成「**尽力还原**」
  ///
  /// 之前不管源码里有什么，一律画虚线框 + 组件名。用户导入自己的项目
  /// 后一屏十几个黄框，观感是"这工具坏了"（原话："设计有控件不适配，
  /// 能否适配所有原生组件"）。
  ///
  /// 现在先问 [UnknownVisual] 能不能从源码里提取出视觉信息：
  /// - **能提取**（`Container(width: 100, color: Colors.blue, ...)`）→
  ///   按提取到的尺寸/颜色/圆角/padding 画一个接近原貌的方块，
  ///   子节点照常渲染进去，右上角挂一个小问号角标说明"是尽力还原"。
  /// - **提取不到**（纯方法调用 `_buildStatusCard(context)`）→
  ///   仍画提示框。这种情况确实无从知晓，画个假方块才是骗人。
  ///
  /// 判断依据只有一条：**源码里有没有可读的视觉信息**。
  Widget _unknownPlaceholder(DesignNode node) {
    final name = (node.props['sourceName'] ?? '').toString();
    final rawStr = (node.props['raw'] as String? ?? '');
    // ⚠️ 必须是「**整段就是一条注释**」，不能只看开头是不是 `//`。
    //
    // 真机实测（alpha.77，用户真实的 `main.dart`）：他写的是
    //
    //     // 使用 GridView 替代复杂的 Row/Column 嵌套，更灵活
    //     GridView.count(
    //       ...
    //
    // 一个**注释 + 紧跟组件**的节点。旧判定 `trimLeft().startsWith('//')`
    // 直接判成"注释节点"，于是把整段源码（注释 + 完整的
    // `GridView.count(...)`）当文字吐在预览里 —— 一大坨代码横在版面中央，
    // 用户的原话是"啥都不显示了"。
    //
    // 正确的判据：**把所有注释行删掉之后，还剩不剩代码**。
    // 剩代码 → 是组件（前面只是带了行注释）；不剩 → 才是纯注释节点。
    final isComment = _isPureComment(rawStr);
    if (isComment) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          rawStr.trim(),
          style: TextStyle(
            fontSize: 10.5,
            height: 1.4,
            color: _c.muted,
            fontFamily: 'monospace',
          ),
        ),
      );
    }

    // ---------- 尽力还原 ----------
    final vis = UnknownVisual.parse(rawStr);
    // 提取不到视觉信息时分两种情况（alpha.79）：
    // - **有孩子** → 照样画近似块、孩子照常渲染。`GridView.count(...)`
    //   就是这种：颜色尺寸一样都提不出来（都该归子节点），但六个按钮的
    //   结构是解析出来了的 —— 落回提示框会把它们整个藏掉，用户看到的就是
    //   "按钮没了"。
    // - **没孩子** → 真的一无所知（`_buildStatusCard(context)` 解析不到
    //   定义之类），画个假方块才是骗人，保持提示框。
    if (vis == null && node.children.isEmpty) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(color: _c.warningBorder),
          borderRadius: BorderRadius.circular(6),
          color: _c.warningContainer,
        ),
        child: Row(
          children: [
            Icon(Icons.help_outline, size: 14, color: _c.muted),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                '未识别：$name（生成时原样带回）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, height: 1.35, color: _c.muted),
              ),
            ),
          ],
        ),
      );
    }
    return _unknownApprox(node, name, vis ?? const UnknownVisual());
  }

  /// 「尽力还原」的渲染：按从源码里提取到的视觉属性画一个方块。
  ///
  /// 设计要点：
  /// - **不再用警告黄**：这不是错误状态，是一个"我看懂了一部分"的东西。
  ///   用中性底色 + 细虚线边，视觉上退到背景里，让真正的界面内容站出来；
  /// - **角标用问号小图标**而不是长文案：占位符不该抢内容的位置。
  ///   完整说明放在属性面板里（用户点中它才需要知道细节）；
  /// - **子节点照常渲染**：`unknown` 节点的 `children` 是导入时递归解析
  ///   出来的（见 design_import 的 `_innerChildren`），让它们显示出来，
  ///   用户能看到"这坨没认出来的东西里面有啥"。
  Widget _unknownApprox(DesignNode node, String name, UnknownVisual vis) {
    // 提取不到颜色时给一个中性底 —— 不能透明，否则用户分不清
    // "这里有个占位"和"这里是空白"。用很淡的一层，不喧宾夺主。
    final extracted = _hexToColor(vis.color);
    final bg = extracted ?? _cs.surfaceContainerHighest.withValues(alpha: 0.45);
    final radius = vis.radius ?? 6.0;
    final pad = vis.padding ?? 8.0;

    // 图标优先：源码里写了 `Icon(Icons.add)` 就直接画那个图标，
    // 比一个问号有用得多。
    //
    // 子节点过滤掉外壳类型（AppBar/FAB/TabBar/BottomNav）：它们是
    // `Scaffold` 的命名参数，挂在一个未识别容器里渲染出来只会是
    // 一行"位置不对"的提示，反而干扰 —— 与 `_buildPreview` 的 root
    // 分支保持同一套过滤规则（共用 `isShellType`）。
    final kids =
        node.children.where((c) => !DesignCodeGen.isShellType(c.type)).toList();
    Widget? inner;
    if (kids.isNotEmpty) {
      inner = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final c in kids) _buildPreview(c)],
      );
    } else if (vis.iconName != null) {
      inner = Icon(_galleryIconFor(vis.iconName!), size: 24, color: _c.muted);
    }

    // ⚠️ `Stack` 的尺寸由**非 positioned 的孩子**决定。下面那个问号角标
    // 是 `Positioned`，不参与定尺寸；所以一旦 `inner` 为 null（既没子节点
    // 也没认出的图标），`Stack` 就一个定尺寸的孩子都没有 —— 在 Column 这类
    // **不约束孩子**的父级里，`performLayout` 会直接断言失败：
    //
    //     A Stack requires bounded constraints from its parent.
    //     Failed assertion: 'size.isFinite'
    //
    // 这个崩在预览区意味着**整棵树渲染不出来**，用户看到的就是"黄框没了
    // 但啥都不显示"（alpha.77 真机实测，源码里 GridView 那段展开出的
    // `_buildActionButton` 全是 Container，正好一个图标都没有）。
    // 所以这里必须给一个**保底的可见尺寸**，保证 Stack 永远量得出大小。
    inner ??= SizedBox(
      width: vis.width ?? 80,
      height: vis.height ?? 32,
    );

    // ⚠️ 叶子（没有可渲染的孩子）不该被拉成整行。
    //
    // 预览的页面主体是 `Column(crossAxisAlignment: stretch)`，里面的孩子
    // 默认**横向拉满**。对"容器类"unknown（有子节点）这合理 —— 容器本来
    // 就常是全宽的；但对叶子（`Icon(...)` 这类）就是灾难：alpha.78 真机
    // 实测，`Icon(check_circle, color: 绿色)` 被渲染成**一整条绿色横幅**
    // 横在页面上，它本来只是个 28px 的状态图标。
    //
    // 包一层 `Align(centerLeft)`：宽度收缩回内容本身，靠左放 ——
    // 跟它在 Row 里"占自己那点位置"的真实样子最接近。
    final Widget box = Opacity(
      // 未识别的东西整体压暗一点：它是"我看懂了一部分"的近似物，
      // 不该和真实识别成功的组件一样醒目。
      opacity: 0.92,
      child: Container(
        width: vis.width,
        height: vis.height,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: EdgeInsets.all(pad),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: _cs.outlineVariant,
            width: 1,
            // 实线——它是在尽力还原，不是在报错
          ),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            inner,

            // 角标：一个小问号，说明"这块是尽力还原的近似"。
            // 只在悬浮/选中时才展开文字说明会更好，但手机没有 hover，
            // 所以统一用 tooltip + 属性面板承载细节。
            Positioned(
              top: -6,
              right: -6,
              child: Tooltip(
                message: '$name\n（未识别，按源码尽力还原，生成时原样带回）',
                child: Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(
                    color: _c.panelBg,
                    shape: BoxShape.circle,
                    border: Border.all(color: _cs.outlineVariant),
                  ),
                  child: Icon(Icons.help_outline, size: 10, color: _c.muted),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return kids.isEmpty
        ? Align(alignment: Alignment.centerLeft, child: box)
        : box;
  }

  /// `UnknownVisual.iconName`（如 `add`）→ 页面预览用的 IconData。
  ///
  /// 复用设计模型里那张 `kIconNames` 表的反向查找；表里没有的
  /// （用户写的冷门图标）退化成 `help_outline`，不抛异常。
  IconData _galleryIconFor(String name) {
    for (final k in kIconNames) {
      if (DesignCodeGen.iconConstFor(k) == 'Icons.$name') {
        return _previewIcon(k);
      }
    }
    return Icons.help_outline;
  }

  /// `#RRGGBB` / `#AARRGGBB` → `Color`。
  ///
  /// 解析失败返回 null（调用方用自己的兜底色），**不抛异常** ——
  /// 源码里的颜色串是外部输入，不能让它把预览搞崩。
  Color? _hexToColor(String? hex) {
    if (hex == null) return null;
    final s = hex.replaceFirst('#', '');
    if (s.length != 6 && s.length != 8) return null;
    final v = int.tryParse(s, radix: 16);
    if (v == null) return null;
    // 6 位补不透明 alpha；8 位已经是 AARRGGBB
    return Color(s.length == 6 ? (0xFF000000 | v) : v);
  }

  /// 占位节点在预览里的可见尺寸。
  ///
  /// ## 为什么需要它
  ///
  /// 占位节点在预览里画的是一条"未识别"的提示条 —— 提示条只说明
  /// **这里有个东西**，不说明**它有多大**。而用户真正想确认的恰恰是
  /// 布局：`AnimatedContainer` 静态展开成一个 100×100 的小方块，
  /// 在 390 宽的预览里是"一块小贴纸"还是"占了半屏"，差别很大。
  ///
  /// 属性面板里可以给它设宽高（设置后生成时也会包一层 `SizedBox`，
  /// 所以**预览和产出是一致的**，不是画饼）。
  ///
  /// 没设时返回 null = 保持原来的"占满宽度的一行"。
  Widget? _unknownSized(DesignNode node) {
    double? pos(Object? v) {
      if (v is num && v > 0) return v.toDouble();
      return null;
    }

    final w = pos(node.props['width']);
    final h = pos(node.props['height']);
    if (w == null && h == null) return null;
    return SizedBox(width: w, height: h, child: _unknownPlaceholder(node));
  }

  /// 语义色位 → 预览用的真实颜色。
  Color? _previewColor(Object? v) {
    final s = v as String?;
    return switch (s) {
      'onSurface' => _cs.onSurface,
      'onSurfaceVariant' => _cs.onSurfaceVariant,
      'primary' => _cs.primary,
      'secondary' => _cs.secondary,
      'error' => _cs.error,
      'outline' => _cs.outline,
      'surface' => _cs.surface,
      'surfaceContainerHighest' => _cs.surfaceContainerHighest,
      _ => null,
    };
  }

  IconData _previewIcon(Object? v) {
    const map = <String, IconData>{
      'star': Icons.star_outline,
      'favorite': Icons.favorite_outline,
      'home': Icons.home_outlined,
      'settings': Icons.settings_outlined,
      'person': Icons.person_outline,
      'search': Icons.search,
      'add': Icons.add,
      'check': Icons.check,
      'circle': Icons.circle_outlined,
      'mail': Icons.mail_outline,
      'lock': Icons.lock_outline,
      'notifications': Icons.notifications_outlined,
      'flutter_dash': Icons.flutter_dash,
    };
    return map[v] ?? Icons.circle_outlined;
  }

  IconData _typeIcon(DesignComponentType t) {
    const map = <DesignComponentType, IconData>{
      DesignComponentType.root: Icons.crop_square,
      DesignComponentType.heading: Icons.title,
      DesignComponentType.text: Icons.subject,
      DesignComponentType.button: Icons.smart_button,
      DesignComponentType.textField: Icons.edit_note,
      DesignComponentType.image: Icons.image_outlined,
      DesignComponentType.icon: Icons.emoji_symbols,
      DesignComponentType.spacer: Icons.height,
      DesignComponentType.divider: Icons.horizontal_rule,
      DesignComponentType.card: Icons.credit_card,
      DesignComponentType.listTile: Icons.list_alt,
      DesignComponentType.box: Icons.crop_16_9,
      DesignComponentType.appBar: Icons.web_asset,
      DesignComponentType.tabBar: Icons.tab,
      DesignComponentType.fab: Icons.radio_button_checked,
      DesignComponentType.bottomNav: Icons.menu_open,
      DesignComponentType.unknown: Icons.help_outline,
    };
    return map[t] ?? Icons.help_outline;
  }

  // ---------------- 右侧三面板 ----------------

  Widget _panelColumn() {
    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (ctx) {
          return Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(height: 40, text: '组件库', icon: null),
                  Tab(height: 40, text: '组件树'),
                  Tab(height: 40, text: '属性'),
                ],
                labelPadding: EdgeInsets.zero,
                labelStyle: TextStyle(fontSize: 13),
                unselectedLabelStyle: TextStyle(fontSize: 13),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _galleryPanel(),
                    _treePanel(),
                    _propsPanel(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 组件库：点一下加到选中节点下。
  ///
  /// 版面分两段（alpha.78）：
  /// - **上半**：可滚动的磁贴列表（"新组件会加到哪"的提示 + 18 个磁贴）；
  /// - **下半**：`插入位置` 一栏，**固定在底部不动**。
  ///
  /// ⚠️ 为什么必须固定：早先整块都在同一个 `ListView` 里，插入按钮排在
  /// 18 个磁贴**后面** —— 用户长按选中一个类型后，还得把列表翻到底才能
  /// 按到按钮，而长按选中的那个磁贴很可能就在顶部（翻到底意味着刚才
  /// 选的那个已经滚出视野，"我到底选了啥"要凭记忆）。固定住之后
  /// "长按选 → 立刻点"成了一个不用移动视线的动作。
  Widget _galleryPanel() {
    final c = FoaColors.of(context);
    // 根节点恒存在，所以"能不能加"总是有答案的
    final sel = _selected ?? _root;
    final canAdd = sel.acceptsChildren;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: canAdd ? c.panelBg : c.warningContainer,
                  border: Border.all(
                      color: canAdd ? _cs.outlineVariant : c.warningBorder),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.my_location, size: 14, color: c.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        canAdd
                            ? '新组件会加到「${sel.label}」里'
                            : '「${sel.label}」不能放子组件',
                        style: TextStyle(fontSize: 11, color: c.muted),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // 3 列网格：手机上两列太空、四列字挤
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.35,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  // ⚠️ 这里必须**同时**排除 root 和 unknown。
                  //
                  // `unknown` 是 alpha.71 导入功能加的类型，它是"从用户源码里
                  // 原样带回的未识别组件"的载体 —— 只有导入时才会产生。
                  // 组件库里点它的话会得到一个 `raw` 为空的占位节点：
                  // 预览里一个提示框、生成时一行 `// （未识别组件，已跳过）`，
                  // 对用户**完全没用**。
                  //
                  // 这是加枚举成员时最容易漏的一处：`for (values)` 会自动让它
                  // 出现在组件库里，不报错、不警告，只是多了一个点了没用的按钮。
                  for (final t in DesignComponentType.values)
                    if (t != DesignComponentType.root &&
                        t != DesignComponentType.unknown)
                      _galleryTile(t, enabled: canAdd),
                ],
              ),
            ],
          ),
        ),
        _galleryInsertBar(),
      ],
    );
  }

  /// 「插入位置」栏 —— 固定在组件库面板底部（见 [_galleryPanel] 的说明）。
  ///
  /// 短按磁贴 = 加组件；长按磁贴选中类型后 → 用这里决定**插在哪**。
  /// 未长按选中时两个按钮禁用："能不能点"直接反映"有没有选中"，
  /// 比点了没反应或偷偷插个 text 好懂。
  Widget _galleryInsertBar() {
    final c = FoaColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.panelBg,
        border: Border(top: BorderSide(color: _cs.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('插入位置',
                  style: TextStyle(
                      fontSize: 11, color: c.muted, letterSpacing: 1)),
              const Spacer(),
              // 选中的类型直接标在这里：固定栏和磁贴列表会滚开，
              // 不写出来用户就得回想"我刚才长按的是哪个"。
              if (_pendingType != null)
                Flexible(
                  child: Text(
                    '已选：${_pendingType!.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _cs.primary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pendingType == null
                      ? null
                      : () => _insertSibling(_pendingType!, before: true),
                  icon: const Icon(Icons.vertical_align_top, size: 15),
                  label: const Text('上方插入', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pendingType == null
                      ? null
                      : () => _insertSibling(_pendingType!, before: false),
                  icon: const Icon(Icons.vertical_align_bottom, size: 15),
                  label: const Text('下方插入', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _pendingType == null ? '长按上面任一组件选中它，再点「上方/下方插入」。' : _insertHint(),
            style: TextStyle(
              fontSize: 10.5,
              height: 1.5,
              color: _pendingType == null ? c.muted : _cs.primary,
            ),
          ),
        ],
      ),
    );
  }

  /// 「插入位置」下方的实时提示：告诉用户**这一下点下去会发生什么**。
  ///
  /// 两种情况分开说，因为它们插入的位置真的不同（根节点没有同级概念）：
  /// - 组件树里选了节点 → 插在它的前/后；
  /// - 没选节点 → 退化成往页面根节点追加。
  /// 提前说清楚，比点完发现"位置不对"再撤销好。
  String _insertHint() {
    final t = _pendingType!.label;
    if (_selectedId.isEmpty) {
      return '将插入「$t」 —— 未选中节点，会加到页面里。';
    }
    final found = _find(_selectedId);
    if (found.parent == null) {
      return '将插入「$t」 —— 选中的是页面根节点，会加到页面里。';
    }
    return '将插入「$t」：点在选中节点（${found.node!.label}）的前面或后面。';
  }

  /// 组件库磁贴：**短按**=加到选中节点里，**长按**=选中它作为插入参照。
  ///
  /// 两个手势分工明确，互不抢：
  /// - 短按（原有行为，不改）→ [_addChild]，立刻得到一个组件；
  /// - 长按（本次新增）→ 只写 [_pendingType]，不动设计树。
  ///
  /// 长按为什么不是"直接插入"：插入要选前/后两个位置，长按弹菜单会
  /// 多一层弹窗，而且弹窗里的按钮离磁贴远、手指够不着。改成"长按选中
  /// → 点下方按钮"，位置选择留在下面那排按钮上，手势更连贯。
  ///
  /// 长按**不受 [enabled] 限制**：即使当前选中节点接不了子组件，
  /// 用户仍可能想"选中某个类型，去别处插"——长按不改变设计树，无害。
  Widget _galleryTile(DesignComponentType t, {required bool enabled}) {
    final c = FoaColors.of(context);
    final picked = _pendingType == t;
    return InkWell(
      onTap: enabled ? () => _addChild(t) : null,
      onLongPress: () {
        // 再长按一次取消选中（可逆，避免"选了就取消不掉"）
        final next = picked ? null : t;
        setState(() => _pendingType = next);
        _toast(next == null ? '已取消选择' : '已选中「${t.label}」，往下点「上方/下方插入」');
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: picked ? _cs.primaryContainer : c.panelBg,
          border: Border.all(
            color: picked ? _cs.primary : _cs.outlineVariant,
            width: picked ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_typeIcon(t), size: 22, color: _cs.primary),
                    const SizedBox(height: 6),
                    Text(t.label, style: const TextStyle(fontSize: 11.5)),
                  ],
                ),
              ),
              // 选中角标：颜色边框在深色底上不够显眼，补一个勾。
              if (picked)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(Icons.check_circle, size: 14, color: _cs.primary),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 组件树：点选 + 上下移。
  Widget _treePanel() {
    final c = FoaColors.of(context);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: [
              ..._treeRows(_root, 0),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      _selectedId.isEmpty ? null : () => _move(delta: -1),
                  icon: const Icon(Icons.arrow_upward, size: 15),
                  label: const Text('上移', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectedId.isEmpty ? null : () => _move(delta: 1),
                  icon: const Icon(Icons.arrow_downward, size: 15),
                  label: const Text('下移', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '删除',
                onPressed: _selectedId.isEmpty ? null : _delete,
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Text(
            _selectedId.isEmpty
                ? '点一个节点选中，然后用「上移/下移」调顺序'
                : '顺序 = 页面里的上下顺序（手机上没有鼠标，拖拽定不准位置）',
            style: TextStyle(fontSize: 10.5, height: 1.45, color: c.muted),
          ),
        ),
      ],
    );
  }

  /// 前序遍历设计树，返回可直接塞进 `ListView` 的**扁平行列表**。
  ///
  /// 为什么是扁平的而不是嵌套 Widget：`ListView` 只吃扁平 children，
  /// 要嵌套就得换成 `Column` + `ListView` 混排，那会丢掉回收能力
  /// （树深了卡）。缩进靠 `depth` 算，不靠嵌套。
  ///
  /// ⚠️ 折叠时必须**提前 return**。写成"跳过不画但继续递归"的话，
  /// 子节点的行**照样生成**、只是被藏在下一层（子节点还在 `_collapsed` 里的
  /// 那些行反而会正常渲染出来），展开时行数就对不上、还会重复。
  ///
  /// ⚠️ 这个方法是 alpha.71 补的。alpha.70 的 `_treePanel` 里写的是
  /// `children: [_treeRow(_root, 0)]` —— `_treeRow` 的 `depth` 参数、
  /// 展开箭头、`_collapsed` 全都备好了，就是**没人生成子节点**。
  /// 编译得过、运行不抛异常、树里永远只有一行。接线漏一处的典型。
  List<Widget> _treeRows(DesignNode node, int depth) {
    final rows = <Widget>[_treeRow(node, depth)];
    if (_collapsed.contains(node.id)) return rows;
    for (final child in node.children) {
      rows.addAll(_treeRows(child, depth + 1));
    }
    return rows;
  }

  Widget _treeRow(DesignNode node, int depth) {
    final c = FoaColors.of(context);
    final selected = node.id == _selectedId;
    final hasChildren = node.children.isNotEmpty;
    final collapsed = _collapsed.contains(node.id);
    return Material(
      color: selected ? _cs.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedId = node.id),
        child: Padding(
          // ⚠️ 缩进钳到 6 层：导入的树深度不可控（用户写的 build 里
          // 套十层容器很正常），不钳的话 depth=20 是 286px，
          // 手机窄屏上文字直接被挤出屏幕。
          // 只钳**缩进**，不钳递归 —— 第 7 层往后的节点照样渲染，
          // 只是不再往右挪。
          padding: EdgeInsets.fromLTRB(6.0 + depth.clamp(0, 6) * 14, 0, 8, 0),
          child: Row(
            children: [
              // 展开/折叠箭头（没有子节点时占位对齐，避免文字左右跳）
              SizedBox(
                width: 20,
                height: 34,
                child: !hasChildren
                    ? null
                    : IconButton(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        icon: Icon(collapsed
                            ? Icons.chevron_right
                            : Icons.expand_more),
                        onPressed: () => setState(() {
                          if (collapsed) {
                            _collapsed.remove(node.id);
                          } else {
                            _collapsed.add(node.id);
                          }
                        }),
                      ),
              ),
              Icon(_typeIcon(node.type),
                  size: 15,
                  color: selected ? _cs.onSecondaryContainer : c.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.type == DesignComponentType.root
                      ? '页面（${node.children.length} 项）'
                      : _nodeSummary(node),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? _cs.onSecondaryContainer : _cs.onSurface,
                  ),
                ),
              ),
              if (node.type != DesignComponentType.root)
                Icon(Icons.chevron_right, size: 14, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }

  /// 树里显示的一行摘要：优先显示用户填的文案，没有就显示类型名。
  String _nodeSummary(DesignNode n) {
    // 占位节点优先显示**它的真实名字** —— 用户在树上扫一眼就能
    // 认出"哦，我那行 ThirdPartyLoginRow 在这儿"。显示"未识别"这种
    // 泛称对他没有信息量。
    if (n.type == DesignComponentType.unknown) {
      final name = (n.props['sourceName'] ?? '').toString().trim();
      final raw = (n.props['raw'] as String? ?? '').trim();
      // alpha.75：区分两档 —— 能还原的标「近似」，不能的标「原样带回」。
      // 用户在树上就能分辨"这个我还能看懂大概"和"这个完全靠原码兜底"。
      final approx = UnknownVisual.parse(raw) != null ? '近似' : '原样带回';
      if (name.isNotEmpty) return '$name（$approx）';
      if (raw.isNotEmpty) return '未识别（$approx）';
      return n.label;
    }
    for (final key in const ['text', 'title', 'label']) {
      final v = n.props[key];
      if (v is String && v.trim().isNotEmpty) return '${n.label} · $v';
    }
    return n.label;
  }

  /// 属性面板：按选中节点的字段表自动渲染。
  Widget _propsPanel() {
    final c = FoaColors.of(context);
    final sel = _selected;
    if (sel == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('先在「组件树」里选一个节点',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.muted)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        Row(
          children: [
            Icon(_typeIcon(sel.type), size: 15, color: c.muted),
            const SizedBox(width: 6),
            Text(sel.label,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 12),
        if (sel.type.fields.isEmpty)
          Text('这种组件没有可调属性', style: TextStyle(fontSize: 12, color: c.muted))
        else
          for (final f in sel.type.fields) ...[
            _fieldEditor(sel, f),
            const SizedBox(height: 12),
          ],
      ],
    );
  }

  /// 按字段类型渲染对应的编辑控件（控件种类与 [DesignFieldKind] 一一对应）。
  Widget _fieldEditor(DesignNode node, DesignField f) {
    final v = node.props[f.key];
    void set(Object? nv) => _mutate(() => node.props[f.key] = nv);

    switch (f.kind) {
      case DesignFieldKind.text:
        return TextFormField(
          initialValue: (v ?? '').toString(),
          decoration: InputDecoration(
            labelText: f.label,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 13),
          // 用 onChanged 而不是 controller：输入法组合期也要实时看到预览，
          // 只有 onFieldSubmitted 的话用户得按回车才动，很别扭。
          onChanged: (s) => _mutate(() => node.props[f.key] = s),
        );

      case DesignFieldKind.number:
        // ⚠️ 变量别叫 `num` —— 会在它自己的初始化式里遮蔽 `num` 类型，
        // 导致 `(v as num?)` 编译不过（"the name 'num' isn't a type"）。
        final value = (v as num?)?.toDouble() ?? 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(f.label, style: const TextStyle(fontSize: 12)),
                const Spacer(),
                Text(_fmtNum(value),
                    style: TextStyle(
                        fontSize: 12,
                        color: FoaColors.of(context).muted,
                        fontFamily: 'monospace')),
              ],
            ),
            // 滑条而不是输入框：手机上手输数字要切键盘，
            // 而这类属性（高度/字号/圆角）都是"试出来"的，滑着看预览最快。
            Slider(
              value: value.clamp(0, _maxFor(f.key)).toDouble(),
              max: _maxFor(f.key),
              divisions: (_maxFor(f.key) / _stepFor(f.key)).round(),
              label: _fmtNum(value),
              onChanged: (d) => set(d),
            ),
          ],
        );

      case DesignFieldKind.bool_:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(f.label, style: const TextStyle(fontSize: 12.5)),
          value: v == true,
          onChanged: set,
        );

      case DesignFieldKind.align:
        return _chooser(f.label, kAlignOptions, v, _alignLabel, set);

      case DesignFieldKind.colorSlot:
        return _chooser(f.label, kColorSlots, v, _colorLabel, set);

      case DesignFieldKind.buttonStyle:
        return _chooser(f.label, kButtonStyles, v, (s) => _styleLabel(s), set);

      case DesignFieldKind.buttonWidth:
        return _chooser(
            f.label, kButtonWidths, v, (s) => s == 'full' ? '占满' : '按内容', set);

      case DesignFieldKind.imageFit:
        return _chooser(f.label, kImageFits, v, (s) => s, set);

      case DesignFieldKind.iconName:
        return _chooser(f.label, kIconNames, v, (s) => s, set, wrap: true);
    }
  }

  /// 数值字段的取值范围。
  ///
  /// 每个键单独给上限：所有数值共用一个 [0, 200] 的话，
  /// 「字号」调到 200 是个没意义的操作，而「图片高度」200 又不够用。
  double _maxFor(String key) => switch (key) {
        'size' => 64,
        'height' => 400,
        'thickness' => 8,
        'elevation' => 12,
        'radius' => 48,
        'padding' => 48,
        _ => 64,
      };

  double _stepFor(String key) => switch (key) {
        'height' => 4,
        'thickness' => 0.5,
        'elevation' => 1,
        'radius' => 1,
        'padding' => 2,
        _ => 1,
      };

  String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  String _alignLabel(String s) => switch (s) {
        'center' => '居中',
        'right' => '右对齐',
        _ => '左对齐',
      };

  String _colorLabel(String s) => switch (s) {
        'none' => '继承（默认）',
        'onSurface' => '主文字',
        'onSurfaceVariant' => '次文字',
        'primary' => '主题色',
        'secondary' => '次级色',
        'error' => '错误色',
        'outline' => '描边',
        'surface' => '表面',
        'surfaceContainerHighest' => '浅层表面',
        _ => s,
      };

  String _styleLabel(String s) => switch (s) {
        'outlined' => '描边',
        'text' => '纯文字',
        _ => '填充',
      };

  /// 一组固定选项 → 一排 ChoiceChip。
  ///
  /// 用 Chip 而不是 DropdownButton：选项少（3~9 个）时一眼能看到全部，
  /// 少一次"点开→找→点"的操作。
  Widget _chooser(
    String label,
    List<String> options,
    Object? current,
    String Function(String) display,
    void Function(Object?) set, {
    bool wrap = false,
  }) {
    final children = <Widget>[
      for (final o in options)
        ChoiceChip(
          label: Text(display(o), style: const TextStyle(fontSize: 11.5)),
          selected: current == o,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onSelected: (_) => set(o),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        if (wrap)
          Wrap(spacing: 6, runSpacing: 6, children: children)
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  children[i],
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// 这段源码是不是**纯注释**（删掉所有注释行后一行代码都不剩）。
///
/// 为什么要单独拎出来：`// 注释\nGridView.count(...)` 这种"注释 + 紧跟组件"
/// 是最常见的写法之一。旧判定只看开头是不是 `//`，会把这类节点误判成
/// 注释节点，然后把**整段源码**当文字渲染进预览 —— alpha.77 真机上
/// 用户看到的那一大坨 `GridView` 源码就是这么来的。
///
/// 注意只处理 `//` 行注释。`/* */` 块注释在 Dart 里少见得多，且要正确
/// 处理嵌套必须写词法扫描，收益不成比例 —— 遇到 `/*` 开头的会当成代码，
/// 退化成"画个占位框"，不会崩、也不会吐一堆源码。
@visibleForTesting
bool isPureCommentSource(String raw) {
  var sawCode = false;
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('//')) continue;
    sawCode = true;
    break;
  }
  return !sawCode;
}

bool _isPureComment(String raw) => isPureCommentSource(raw);
