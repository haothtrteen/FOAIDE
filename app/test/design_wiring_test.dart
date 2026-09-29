import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「设计」区接线守卫（alpha.70）。
///
/// 只做**源码级断言**，不 pumpWidget。这套测试要拦的是"接线漏了一处"
/// 这类错误 —— 它们全都编译得过、运行时不抛异常，只是功能静默失效：
/// - 枚举加了成员但 `_buildSections()` 没加 → 点「设计」显示别的区
/// - `_SectionLabel` 的 switch 漏了臂 → 其实编译不过（唯一安全的那个）
/// - 页面没接进 import → 编译不过
///
/// 真正需要跑 UI 的部分（点组件库能加进树、导出能写文件）
/// 依赖 MethodChannel 与真机文件系统，放在真机验证清单里。
void main() {
  /// 读源码并剥掉注释行。
  ///
  /// ⚠️ 必须剥：本文件里的断言全是 `contains`，
  /// 而代码里的注释经常引用被删掉的写法（"原来是 Icons.flutter_dash"），
  /// 不剥的话注释会让断言**假绿**（以为改干净了其实没有）。
  String code(String rel) => File(rel)
      .readAsLinesSync()
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  group('设计区 · 三处联动', () {
    test('_Section 枚举有 design 成员，且排在 code 之后', () {
      final page = code('lib/project/project_page.dart');
      final m = RegExp(r'enum _Section \{([^}]*)\}').firstMatch(page);
      expect(m, isNotNull, reason: '找不到 _Section 枚举声明');
      final members =
          m!.group(1)!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      expect(members, contains('design'));
      expect(members.indexOf('design'), members.indexOf('code') + 1,
          reason: '「设计」要紧挨「代码」—— 两者都是在写界面，相邻才符合心智');
    });

    test('label 与 icon 两个 switch 都有 design 臂', () {
      final page = code('lib/project/project_page.dart');
      // switch 是穷尽式的，漏了臂编译不过 —— 这条断言的价值是
      // 让"改了枚举但没改 switch"在**测试阶段**就暴露，而不是等编译。
      expect(RegExp(r"_Section\.design\s*=>\s*'设计'").hasMatch(page), isTrue,
          reason: 'label switch 缺 design 臂');
      expect(RegExp(r'_Section\.design\s*=>\s*Icons\.\w+').hasMatch(page), isTrue,
          reason: 'icon switch 缺 design 臂');
    });

    test('DesignPage 已 import 且接进了 _buildSections', () {
      final page = code('lib/project/project_page.dart');
      expect(page.contains("import 'design_page.dart';"), isTrue);
      expect(page.contains('DesignPage('), isTrue,
          reason: 'import 了但没接进 children = 用户点「设计」看不到东西');
    });

    test('DesignPage 拿到了 onOpenFile（导出后能跳代码区）', () {
      final page = code('lib/project/project_page.dart');
      final i = page.indexOf('DesignPage(');
      expect(i, greaterThanOrEqualTo(0));
      final body = page.substring(i, page.indexOf(')', i) + 1);
      expect(body.contains('onOpenFile'), isTrue,
          reason: '没传 onOpenFile 的话，生成完代码没法一键跳过去看');
      expect(body.contains('bridge: _fb'), isTrue,
          reason: '没传 bridge 就没法写文件，导出会静默失败');
    });
  });

  group('设计区 · 能力完整性（防"加了组件忘了某个环节"）', () {
    test('DesignPage 有实时预览（不是只有代码输出）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('_buildPreview'), isTrue,
          reason: '预览是"可用雏形"的核心 —— 没有它退化成代码生成器');
      expect(page.contains('实时预览'), isTrue);
    });

    test('DesignPage 用 FsBridge 写盘，且路径在 lib/generated/ 下', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('bridge.write('), isTrue);
      expect(page.contains('lib/generated/'), isTrue,
          reason: '生成物要落在 lib/ 下才算"进了项目"，否则用户还要手动搬');
    });

    test('导出前拦住空设计（不让用户导出个空 Scaffold 还以为是坏了）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('_root.children.isEmpty'), isTrue);
      expect(page.contains('设计还是空的'), isTrue);
    });

    test('有撤销（改错了要能退回去）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('_undo'), isTrue);
      expect(page.contains('Icons.undo'), isTrue);
      expect(page.contains('_kUndoLimit'), isTrue,
          reason: '撤销栈要有上限 —— 深拷贝整棵树，不封顶会吃内存');
    });

    test('所有树修改都走 _mutate（否则撤销时灵时不灵）', () {
      final page = code('lib/project/design_page.dart');
      // 直接往 children 里塞但没走 _mutate 的写法会绕过撤销栈。
      // 这里断言几个必须存在的调用点存在且经由 _mutate。
      expect(page.contains('_mutate(() => sel.children.add(child))'), isTrue,
          reason: '加组件必须压撤销栈');
      expect(page.contains('parent.children.remove(found.node!)'), isTrue);
      // 上面这行必须在 _mutate 里 —— 简单校验它前面出现过 _mutate
      final i = page.indexOf('parent.children.remove(found.node!)');
      final before = page.substring((i - 60).clamp(0, i), i);
      expect(before.contains('_mutate'), isTrue,
          reason: '删除没走 _mutate，撤销会退不回来');
    });

    test('套用模板前弹确认（会覆盖当前设计）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('showDialog'), isTrue);
      expect(page.contains('会替换掉当前设计'), isTrue);
    });
  });

  group('设计区 · 触摸优先的交互选择', () {
    test('没有用拖拽（手机拖拽精度不够）', () {
      final page = code('lib/project/design_page.dart');
      // ⚠️ 不能用 `contains('Draggable')` —— 会命中 `DraggableScrollableSheet`
      // （那是"可拖动的底部弹层"，跟拖拽放组件没关系）而假红。
      // 要按单词边界匹配 widget 构造调用。
      expect(RegExp(r'\bDraggable\s*\(').hasMatch(page), isFalse,
          reason: '手机上没有鼠标，"拖到指定坐标"的精度根本不够用；'
              '顺序调整走组件树的上移/下移');
      expect(RegExp(r'\bDragTarget\s*[<(]').hasMatch(page), isFalse);
      expect(RegExp(r'\bLongPressDraggable\s*\(').hasMatch(page), isFalse);
    });

    test('组件树有上移/下移/删除三个操作', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('上移'), isTrue);
      expect(page.contains('下移'), isTrue);
      expect(page.contains('删除'), isTrue);
    });
  });

  group('设计区 · 组件树真的会展开（alpha.71 修的 bug）', () {
    // alpha.70 的树只有一行 `页面（N 项）`，点箭头也不出子节点：
    // `_treeRow` 早就支持 depth 参数（缩进 / 展开箭头 / 折叠状态全写好了），
    // 但 `_treePanel` 的 ListView children 里**只放了根节点**，子节点从未
    // 被生成过。编译得过、运行不抛异常、功能静默失效 —— 正是本文件
    // 存在的理由。下面三条断言锁死"必须递归"这件事。
    test('ListView 的 children 来自递归展开，不是单个根节点', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('_treeRows('), isTrue,
          reason: '没有 _treeRows：树只会渲染根一行（alpha.70 的 bug）');
      expect(RegExp(r'\.\.\._treeRows\(').hasMatch(page), isTrue,
          reason: 'children 里要展开 _treeRows 的结果，光定义不调用等于没写');
      expect(RegExp(r'children:\s*\[\s*_treeRow\(').hasMatch(page), isFalse,
          reason: 'children 里直接放 _treeRow(...) 就是不递归的老写法');
    });

    test('_treeRows 是前序遍历且折叠时提前 return', () {
      final page = code('lib/project/design_page.dart');
      final i = page.indexOf('List<Widget> _treeRows(');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 _treeRows 定义');
      final body = page.substring(i, i + 900);
      expect(body.contains('for (final'), isTrue, reason: '没有遍历 children');
      expect(body.contains('_treeRows(child'), isTrue,
          reason: '没递归：子节点的子节点会断在第二层');
      // ⚠️ 折叠必须是 return，不能只是"不画"。
      // 用 continue / 空 if 的话，子节点照样递归出来、只是被藏起来，
      // 展开时又冒出一批，行数对不上。
      expect(RegExp(r'if \(_collapsed\.contains\(node\.id\)\)\s*return rows;')
          .hasMatch(body), isTrue,
          reason: '折叠要提前 return，不能只跳过不画');
    });

    test('深层缩进有钳制（导入树可以很深）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('depth.clamp('), isTrue,
          reason: '导入的树深度不可控，不钳的话深层节点在手机窄屏上'
              '缩进能到几百 px，文字直接被挤出屏幕');
    });
  });

  group('设计区 · 导入已有 UI 的接线（alpha.71）', () {
    // 导入这条路有五个环节，任何一个没接上，用户看到的现象都是
    // 「点了按钮没反应」或「导入成功了但树上什么都没有」——
    // 全都不抛异常。这个分组把五个环节各钉一条。

    test('工具栏有导入入口，且调的是 _pickDartFile', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains("'导入已有 UI'"), isTrue,
          reason: 'tooltip 是手机上唯一的说明 —— 没有它就是个无字图标');
      expect(page.contains('_pickDartFile'), isTrue);
      expect(RegExp(r'onPressed:\s*_importing\s*\?\s*null\s*:\s*_pickDartFile')
          .hasMatch(page), isTrue,
          reason: '解析是异步的，不锁按钮的话连点两次会弹两个文件选择器');
    });

    test('页面接了 design_import（否则整条路编译不过 —— 这条是便宜的保险）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains("import 'design_import.dart';"), isTrue);
    });

    test('三段式：选文件 → 选候选类 → 应用导入', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('findDartFiles('), isTrue,
          reason: '第一步要真的去扫项目目录，不能只列一个写死的路径');
      expect(page.contains('findCandidates('), isTrue,
          reason: '一个 .dart 里可能有多个 build（页面 + 组件），'
              '不列出来让用户选就得猜');
      expect(page.contains('_applyImport('), isTrue);
    });

    test('导入失败时不动用户当前设计（这是最要紧的一条）', () {
      final page = code('lib/project/design_page.dart');
      final i = page.indexOf('void _applyImport(');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 _applyImport');
      // ⚠️ 取 700 字符而不是更多：`_applyImport` 后面紧跟 `_showNotesSheet`，
      // 而 `_showNotesSheet` 里有 `_mutate` 之外的东西 —— 窗口开太大会
      // 把下一个方法的代码当成这个方法的方法体，断言就测错了对象。
      final body = page.substring(i, i + 700);
      // 失败分支必须**先 return**，再轮到替换设计树的代码。
      // 反过来写的话，解析失败会把用户画了半天的页面清空。
      final failReturn = body.indexOf('return;');
      final replace = body.indexOf('_mutate');
      expect(failReturn, greaterThanOrEqualTo(0),
          reason: '失败路径没有 return，会继续往下走');
      expect(replace, greaterThan(failReturn),
          reason: '替换设计树的代码必须排在失败 return **之后**');
    });

    test('导入成功后记住来源（工具栏要显示"从哪来的"）', () {
      final page = code('lib/project/design_page.dart');
      for (final f in ['_importedFrom', '_importedClassName', '_importedPath']) {
        expect(page.contains(f), isTrue, reason: '缺 $f');
      }
      // `_importedPath` 是"覆盖原文件"的唯一依据 —— 它没被赋上的话，
      // 保存弹窗里永远不会出现覆盖选项（静默降级，看不出错）。
      final i = page.indexOf('void _applyImport(');
      expect(i, greaterThanOrEqualTo(0), reason: '找不到 _applyImport');
      final body = page.substring(i, i + 700);
      expect(body.contains('_importedPath = '), isTrue,
          reason: '_importedPath 必须在导入成功时写入');
    });

    test('notes 用弹层而不是 toast（toast 两秒就没了）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('_showNotesSheet'), isTrue);
      expect(page.contains('addPostFrameCallback'), isTrue,
          reason: '解析刚结束时还在 setState 的构建周期里，'
              '直接 showModalBottomSheet 会抛异常');
    });

    test('导出改成"先看代码再保存"（写盘不可逆）', () {
      final page = code('lib/project/design_page.dart');
      final i = page.indexOf('Future<void> _export(');
      expect(i, greaterThanOrEqualTo(0));
      final body = page.substring(i, i + 1200);
      final show = body.indexOf('_showCodeSheet');
      final write = body.indexOf('bridge.write(');
      expect(show, greaterThanOrEqualTo(0), reason: '_export 里没有预览环节');
      // `bridge.write(` 在 `_export` 里出现 = 又变成"先写盘再问"了。
      // 但 indexOf 找不到时返回 -1，而 -1 < show 恒成立 —— 写成
      // `greaterThan(show)` 的话"写盘语句被删光了"会**假绿**。
      // 所以先显式判 -1。
      expect(write, -1,
          reason: '_export 里不该再有写盘 —— 写盘已挪到 _saveNew / '
              '_saveOverwrite，由用户在弹窗里选择之后才发生');
    });

    test('保存去向弹窗：覆盖 / 存为新文件', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('_askSaveTarget'), isTrue);
      expect(page.contains('_saveOverwrite'), isTrue);
      expect(page.contains('_saveNew'), isTrue);
      // 覆盖是**破坏性**动作，弹窗里必须把代价写出来。
      // 只说"覆盖原文件"的话，用户以为只是改了界面，
      // 结果业务逻辑被整段替换掉 —— 这是本功能最危险的一处。
      //
      // ⚠️ 这句在源码里是**跨行拼接的相邻字符串字面量**：
      //   '覆盖 ... 会把它的'
      //   '业务逻辑、状态管理、路由全部替换掉，只剩静态界面。'
      // 所以断言只能取到分片边界为止的那一段。这里断言"每个分片都在"
      // 而不是拼成一个整句 —— 后者会因为中间那对引号而永远匹配不上，
      // 变成一条假红（假红比假绿好，但同样是错）。
      expect(page.contains('会把它的'), isTrue,
          reason: '不说清楚就让他点，等于设了个陷阱');
      expect(page.contains('业务逻辑、状态管理、路由全部替换掉'), isTrue,
          reason: '只说"会替换掉"太轻 —— 用户得看到"业务逻辑"三个字'
              '才会停下来想一下');
    });

    test('覆盖前先备份成 .dart.bak', () {
      final page = code('lib/project/design_page.dart');
      // ⚠️ 断言的是**备份路径的构造方式**而不是一个字面量：
      // 源码里写的是 `'$_importedPath.bak'`（注释里提了 `.dart.bak`，
      // 但注释已经被 `code()` 剥掉了）。断言 `'.dart.bak'` 字面量的话
      // 只能匹配到注释 —— 剥完注释就假红。
      // 断言的是**整条路径的构造**："$变量 + .bak"。
      // 只断言后缀 `.bak`（三个字符）太弱：生成器里任何一处
      // `.bak` 都能让它通过。带上前缀变量才是"备份文件就是
      // 原文件路径加个后缀"这个**行为**。
      expect(page.contains("'\$_importedPath.bak'"), isTrue,
          reason: '备份后缀不能是 .dart —— 那样它会被 findDartFiles 扫到、'
              '被 dart analyze 当源文件分析，用户会看到两份重复的类名报错');
      expect(page.contains('final backup ='), isTrue);
      // 备份失败必须中止：没有备份的覆盖是不可回复的。
      expect(page.contains('备份失败'), isTrue);
    });

    test('覆盖只在导入来的设计上提供（手搭的没有"原文件"）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('canOverwrite'), isTrue,
          reason: '手搭的设计没有来源文件，给个灰色的覆盖按钮只会让人困惑');
      expect(page.contains('_importedPath.isNotEmpty'), isTrue);
    });

    test('生成的文件名带上原类名', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('classNameForImport'), isTrue);
      expect(page.contains('fileNameForImport'), isTrue);
    });
  });

  group('预览入口 · Web 降为备选（alpha.72）', () {
    // 这一组盯的是"换了一半"：入口菜单里加了设计预览，但某个老入口
    // 仍然直接跳 Web。那种半吊子状态用户最难理解 —— 同样的按钮
    // 在他手机上的不同位置给出完全不同的等待时间。

    test('编辑器预览按钮是菜单，三个选项都在', () {
      final page = code('lib/editor/editor_page.dart');
      expect(page.contains('PopupMenuButton<String>'), isTrue,
          reason: '单按钮直达 Web 的话，用户点"预览"必然等一次完整构建');
      expect(page.contains("value: 'design'"), isTrue);
      expect(page.contains("value: 'project'"), isTrue);
      expect(page.contains("value: 'web'"), isTrue);
    });

    test('编辑器不再用单个 IconButton 直达 Web 预览', () {
      final page = code('lib/editor/editor_page.dart');
      // 老写法是 `onPressed: _onPreviewTap` 挂在一个 IconButton 上。
      // 换菜单之后 `_onPreviewTap` 只该出现在 onSelected 的分支里。
      expect(page.contains('onPressed: _onPreviewTap'), isFalse,
          reason: '还有地方直达 Web = 用户还是会撞上十分钟等待');
    });

    test('Web 预览的文案说明了代价（不让用户以为又卡了）', () {
      final page = code('lib/editor/editor_page.dart');
      expect(page.contains('首次要等几分钟'), isTrue,
          reason: '菜单里得把"这个慢"写在选项上 —— '
              '不然用户选了它、等了五分钟，只会以为 App 卡死了');
    });

    test('编辑器通过回调把预览请求报给宿主（不反向依赖项目层）', () {
      final page = code('lib/editor/editor_page.dart');
      expect(page.contains('onPreviewDesign'), isTrue);
      expect(page.contains('onPreviewProjectPages'), isTrue);
      expect(page.contains("import '../project/"), isFalse,
          reason: '编辑器不能 import 项目层 —— 那会形成反向依赖，'
              '独立页模式下会连带拉进整个工作台');
    });

    test('宿主把预览请求接成"切到设计区"', () {
      final page = code('lib/project/project_page.dart');
      expect(page.contains('_previewInDesign'), isTrue,
          reason: '编辑器把路径报上来了，宿主没接 = 点了没反应');
      expect(page.contains('onPreviewDesign: (path) => _previewInDesign(path)'),
          isTrue);
    });

    test('预览卡多了设计预览入口，且 Web 仍在（备选不能丢）', () {
      final page = code('lib/project/project_preview.dart');
      expect(page.contains('设计预览'), isTrue);
      expect(page.contains('零编译'), isTrue,
          reason: '把"即时"写在卡片上，用户才会先点它');
      expect(page.contains('Web 预览'), isTrue,
          reason: 'Web 预览是唯一能看真跑起来效果的路径，不能删');
      expect(page.contains('onOpenDesign'), isTrue);
    });

    test('宿主给 ProjectPreview 传了 onOpenDesign', () {
      final page = code('lib/project/project_page.dart');
      expect(page.contains('onOpenDesign: () => setState(() => _section = _Section.design)'),
          isTrue);
    });

    test('全屏预览存在，且默认开了设备尺寸模拟', () {
      final page = code('lib/project/design_preview_page.dart');
      expect(page.contains('PreviewDevice'), isTrue);
      expect(page.contains('MediaQuery.of(context).copyWith'), isTrue,
          reason: '不覆盖 MediaQuery 的话"模拟平板"只是个被拉宽的框，'
              '树里的宽度断点根本不会触发 —— 那就不叫模拟');
      expect(page.contains('SizedBox('), isTrue);
      expect(page.contains('BoxFit.contain'), isTrue,
          reason: '等比缩放：拉扁的预览比不预览更害人');
    });

    test('全屏预览复用了设计区同一个渲染实现（不各写一份）', () {
      final page = code('lib/project/design_preview_page.dart');
      expect(page.contains('widget.state.renderPreview'), isTrue,
          reason: '两套渲染必然长歪，"小窗对的、全屏错了"是最难查的 bug');
      final dp = code('lib/project/design_page.dart');
      expect(dp.contains('Widget renderPreview(DesignNode node) => _buildPreview(node)'),
          isTrue);
    });

    test('全屏预览只覆盖预览框的主题，不换整个页面', () {
      final page = code('lib/project/design_preview_page.dart');
      expect(page.contains('ThemeData.dark'), isTrue);
      expect(page.contains('ThemeData.light'), isTrue);
      // 用 Theme 包住预览框而不是改 MaterialApp 的 themeMode ——
      // 后者会让工具栏也跟着变，用户分不清在看预览还是 App 被切了主题。
      expect(page.contains('MaterialApp'), isFalse,
          reason: '全屏页里不该出现第二个 MaterialApp');
    });

    test('设计区预览头显示了"零编译"，且全屏按钮在', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('零编译'), isTrue);
      expect(page.contains('Icons.fullscreen'), isTrue);
      expect(page.contains('openFullscreenPreview'), isTrue);
    });

    test('空设计时全屏按钮不可点（点进去只能看到"设计还是空的"）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('_root.children.isEmpty'), isTrue);
    });

    test('项目页面扫描有独立的进行中标志', () {
      final page = code('lib/project/design_page.dart');
      // 整项目扫描会嵌套调用单文件导入，共用一个标志的话
      // 前者结束时会顺手把后者的状态清掉。
      expect(page.contains('_scanning'), isTrue);
      expect(page.contains('_importing'), isTrue);
    });

    test('扫描空了要给具体的话，不是"没找到"三个字', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('result.summary'), isTrue,
          reason: 'summary 里带"扫了几个文件"，用户才能判断是自己目录不对');
    });
  });

  group('关于页 · 图标与仓库地址（alpha.70）', () {
    test('关于页用项目图标而非 Flutter logo', () {
      final page = code('lib/ui/about_page.dart');
      expect(page.contains('Icons.flutter_dash'), isFalse);
      expect(page.contains("assets/icon/app_icon.png"), isTrue);
    });

    test('关于页有 GitHub 一行，且用 _copyRow（要能一键复制）', () {
      final page = code('lib/ui/about_page.dart');
      expect(page.contains('AboutInfo.authorRepo'), isTrue);
      final i = page.indexOf('AboutInfo.authorRepo');
      final around = page.substring((i - 200).clamp(0, i), i + 100);
      expect(around.contains('_copyRow'), isTrue,
          reason: '地址是要粘到浏览器的，长按选中不如一键复制');
    });
  });

  // ================================================================
  // alpha.74：保存入口可见性 + 组件库长按选中插入
  // ================================================================

  group('设计区 · 保存入口必须看得见（alpha.74 修的 bug）', () {
    test('导出按钮不是被左侧文字挤出去的普通子节点', () {
      final page = code('lib/project/design_page.dart');
      // 病根：工具栏是 Row，Spacer 之后依次是路径文字 + 导出按钮。
      // 路径文字在窄屏上先占满，把按钮推到屏幕外 —— 用户报
      // "设计改了没看到保存按钮"就是这么来的。
      //
      // 断言路径文字与「上次：」**都被 Flexible 包住**（可收缩），
      // 这是让按钮始终有位置的结构性保证。
      expect(page.contains('Flexible('), isTrue,
          reason: '路径文字不包 Flexible 就会把保存按钮挤出屏幕');
      // `_importedFrom` 那一整块必须是 Flexible 的直接子节点。
      //
      // ⚠️ 窗口不能用 `substring(i, i + 40)` 这种小值：
      // `if (...)` 之后是 12 个空格的缩进，`Flexible` 落在第 41 位
      // —— 我第一版就是这么写错的，测试红了但代码是好的。
      // 改为按行取"下一非空行"，与缩进宽度解耦。
      final i = page.indexOf('if (_importedFrom.isNotEmpty)');
      expect(i, isNot(-1), reason: '找不到导入来源那一段');
      final linesAfter = page.substring(i).split('\n').skip(1);
      final firstCodeLine =
          linesAfter.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      expect(firstCodeLine.contains('Flexible'), isTrue,
          reason: '导入来源那行是挤压按钮的元凶，必须可收缩'
              '（实际下一行是：$firstCodeLine）');
    });

    test('导出按钮本体不被 Flexible/Expanded 包住（要永远占位）', () {
      final page = code('lib/project/design_page.dart');
      // 按钮若自己也被 Flexible 包住，收缩时会先牺牲按钮 —— 反了。
      // 定位到 FilledButton.icon( 前面那段，断言没有 Flexible 紧邻。
      final i = page.indexOf("label: const Text('生成代码')");
      expect(i, isNot(-1));
      final before = page.substring((i - 400).clamp(0, i), i);
      expect(before.contains('onPressed: _exporting ? null : _export'), isTrue);
    });

    test('导出按钮补了 tooltip 说明能落盘（图标语义不够直白）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('生成代码后可保存到项目'), isTrue,
          reason: '用户找不到"保存"字样时，tooltip 是最后的线索');
    });
  });

  group('设计区 · 组件库长按选中 → 上下方插入（alpha.74）', () {
    test('有 _pendingType 独立状态（不复用 _selectedId）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('DesignComponentType? _pendingType'), isTrue,
          reason: '树选中节点与库选中类型是两个维度，合并会互相污染');
    });

    test('磁贴接了 onLongPress，且切换式选中（可取消）', () {
      final page = code('lib/project/design_page.dart');
      final i = page.indexOf('onLongPress');
      expect(i, isNot(-1), reason: '组件库磁贴没有长按 = 需求没实现');
      // 再长按一次要能取消 —— 否则"选了就取消不掉"。
      final around = page.substring(i, i + 300);
      expect(around.contains('setState'), isTrue);
      expect(around.contains('_pendingType'), isTrue);
    });

    test('长按选中时有可见反馈（边框/底色/勾）', () {
      final page = code('lib/project/design_page.dart');
      // 只改状态不给视觉反馈等于没选中。
      expect(page.contains('primaryContainer'), isTrue,
          reason: '选中态要有底色变化');
      expect(page.contains('Icons.check_circle'), isTrue,
          reason: '深色底上细边框不够显眼，补一个勾');
    });

    test('插入按钮用选中的类型，不再硬编码 text', () {
      final page = code('lib/project/design_page.dart');
      // 这是本需求的核心：长按选中「按钮」就该插按钮。
      expect(page.contains('_insertSibling(_pendingType!, before: true)'),
          isTrue);
      expect(page.contains('_insertSibling(_pendingType!, before: false)'),
          isTrue);
      // 旧写法必须彻底消失。
      expect(
          page.contains('_insertSibling(DesignComponentType.text, before:'),
          isFalse,
          reason: '硬编码插 text 会让"长按选中"变成骗人的交互');
    });

    test('没选中类型时插入按钮禁用（不是点了没反应）', () {
      final page = code('lib/project/design_page.dart');
      final i = page.indexOf('_pendingType == null');
      expect(i, isNot(-1), reason: '缺少"未选中则禁用"的判断');
      // 两个按钮（上方/下方）各要一处 `onPressed` 判空 —— 数
      // `onPressed: _pendingType == null` 的裸出现次数，比匹配缩进稳。
      final n = RegExp(r'onPressed:\s*_pendingType == null').allMatches(page).length;
      expect(n, 2,
          reason: '上方/下方两个插入按钮都要在未选中时禁用，实际只找到 $n 处');
    });

    test('插入前会拦外壳组件重复（与 _addChild 同一道闸）', () {
      final page = code('lib/project/design_page.dart');
      // _insertSibling 里必须有 isShellType 检查 —— 两条入口都通到
      // 生成器，只在 _addChild 上拦等于没拦（两个 AppBar 编译不过）。
      final i = page.indexOf('void _insertSibling(');
      expect(i, isNot(-1));
      final body = page.substring(i, i + 1800);
      expect(body.contains('isShellType'), isTrue,
          reason: '_insertSibling 漏了外壳去重，会导致生成出两个 AppBar');
    });

    test('插入前会说清这一下会发生什么（位置不同）', () {
      final page = code('lib/project/design_page.dart');
      expect(page.contains('_insertHint'), isTrue,
          reason: '未选节点会退化成"加到页面里"，与"插在节点前后"不同，必须提前说');
    });

    test('长按不改变设计树（只写 _pendingType）', () {
      final page = code('lib/project/design_page.dart');
      final i = page.indexOf('onLongPress');
      final body = page.substring(i, i + 400);
      // 长按里不得出现 _mutate / _addChild —— 长按是"选择意图"，
      // 不是"修改内容"，混进去会让撤销栈出现莫名其妙的条目。
      expect(body.contains('_mutate'), isFalse);
      expect(body.contains('_addChild'), isFalse);
    });
  });
}
