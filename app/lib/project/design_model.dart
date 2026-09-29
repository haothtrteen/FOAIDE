/// 「设计」区的数据模型与代码生成器（alpha.70）。
///
/// **为什么单独一个文件**：这里全是纯函数——组件类型表、默认属性、
/// Dart 源码生成。把它们和 Widget 混在一起的话，测「生成的代码对不对」
/// 就得 `pumpWidget` 一整个页面；分开之后可以直接对着字符串断言。
///
/// ## 定位（照抄 FlutterViz 的自我定位）
///
/// FlutterViz 官网原话：*"NO, it's not yet another NO-CODE or LOW-CODE
/// platform, instead, it is a simple visual builder to create Flutter App
/// Screens.. That's it!"*
///
/// 本项目对齐这条线：**只生成静态界面代码**，不含业务逻辑、状态管理、
/// 数据流、路由。生成物是"起点"不是"成品"——用户拿到后自己接逻辑。
/// 这不是能力不足的妥协，是刻意的边界：一旦承诺"拖一拖就出 App"，
/// 用户第一次发现按钮点了没反应就会觉得被骗。
library;

/// 「参数值类型」名字表 —— 它们**不是** `Widget`，永远不该出现在设计树里。
///
/// 两处使用：
/// 1. 导入器（design_import.dart）的 `_innerChildren` 兜底扫参 —— 跳过
///    属性值构造，防止 `Icon(color: Color(...))` 的颜色被收成子组件；
/// 2. [UnknownVisual._extractScope] —— 决定哪些嵌套调用的内部**可以**
///    继续搜视觉属性（值类型），哪些整体跳过（widget 型子节点）。
///
/// 放 model 层是因为 `_extractScope` 在这里，而本层保持纯 Dart
/// （这个集合只是字符串常量，不引 analyzer / Flutter）。
///
/// 注意只列**值类型**。像 `Padding` / `Center` / `SizedBox` 这些虽然也
/// 常出现在参数位置，但它们确实是 widget，不能列进来。
const Set<String> kNonWidgetTypeNames = <String>{
  // ---- 颜色 ----
  'Color',
  'ColorScheme',
  // ---- 装饰与样式 ----
  'BoxDecoration',
  'ShapeDecoration',
  'DecorationImage',
  'BoxShadow',
  'Border',
  'BorderSide',
  'BorderRadius',
  'OutlineInputBorder',
  'UnderlineInputBorder',
  'RoundedRectangleBorder',
  'LinearGradient',
  'RadialGradient',
  'SweepGradient',
  'TextStyle',
  'TextTheme',
  'IconThemeData',
  'ButtonStyle',
  // ---- 尺寸与偏移 ----
  'EdgeInsets',
  'EdgeInsetsDirectional',
  'Offset',
  'Size',
  'Radius',
  // ---- 动画 ----
  'Duration',
  'Curve',
  'ColorTween',
  'Tween',
  'AlwaysStoppedAnimation',
  // ---- 控制器 ----
  'TextEditingController',
  'ScrollController',
  'PageController',
  'AnimationController',
  'TabController',
  // ---- 其他常见值 ----
  'TextSpan',
  'Locale',
  'MaterialColor',
  'MaterialAccentColor',
  'SliverChildBuilderDelegate',
};

/// 设计树里的一个节点。
///
/// 用可变类而非 immutable：编辑过程中高频改属性，
/// 每改一次重建整棵树的成本没必要付。改完调 `setState` 刷新即可。
class DesignNode {
  DesignNode({
    required this.type,
    String? id,
    Map<String, Object?>? props,
    List<DesignNode>? children,
  })  : id = id ?? nextId(),
        props = <String, Object?>{
          ...type.defaultProps(),
          if (props != null) ...props,
        },
        children = children ?? <DesignNode>[];

  /// 稳定标识：组件树选中态、`ValueKey` 都靠它。
  ///
  /// ⚠️ 不能用 `Object.hashCode`——重建树时会变，选中态会莫名丢失。
  final String id;

  final DesignComponentType type;

  /// 组件属性。键必须是 [DesignComponentType.fields] 里声明过的，
  /// 有单测守着（防止写错键名导致"改了没反应"）。
  final Map<String, Object?> props;

  final List<DesignNode> children;

  static int _seq = 0;
  static String nextId() => 'n${++_seq}';

  /// 重置 id 计数器。
  ///
  /// 只给测试用：不重置的话，同一进程里先后建的两棵树 id 不同，
  /// 断言"生成的代码稳定"就没法写。
  static void resetIdSeq() => _seq = 0;

  String get label => type.label;

  /// 该类型是否接受子节点（叶子组件不能拖东西进去）。
  bool get acceptsChildren => type.acceptsChildren;

  /// 深拷贝（用于"改前的快照"，支持撤销）。
  DesignNode clone() => DesignNode(
        type: type,
        id: id,
        props: Map<String, Object?>.from(props),
        children: children.map((c) => c.clone()).toList(),
      );
}

/// 可用的组件类型。
///
/// 刻意只列这些：**都是"往里放一个就有意义"的组件**。
/// 不做 `Row`/`Column`/`Stack` 这类纯布局容器——在手机触摸下
/// 让用户理解"往 Row 里放两个东西会横排"的交互成本，
/// 远高于直接用组件库里的成品（对照组：FlutterViz 是 Web 端有鼠标，
/// 我们是手机，手势精度差一个量级）。
enum DesignComponentType {
  /// 页面根节点（不可删、不可移）。
  root,
  heading,
  text,
  button,
  textField,
  image,
  icon,
  spacer,
  divider,
  card,
  listTile,

  /// 静态方块（alpha.74 加）。
  ///
  /// ## 为什么需要一个"什么内容都没有的方块"
  ///
  /// 它是给 `AnimatedContainer` 这类**设计器确实表达不了、但形状很明确**
  /// 的组件当落地点的。以前这类东西一律落成 [unknown] 占位节点，
  /// 预览里画的是一条"未识别：xxx"的黄条 —— 用户的原话是
  /// 「这几个 demo 模板强行适配一下」：他允许"不准"，但要求"能显示"。
  /// 一条黄条看不出"那块绿的、方的、200×200 的东西"，一个真方块看得出来。
  ///
  /// ## 为什么不做成 `card`
  ///
  /// `card` 有自己的语义（`Card` + `Padding` + `Column` 的生成模板），
  /// 用它当"方块"会往生成结果里塞用户没写过的 `Card` / `Column`。
  /// 这个类型是**新的一套最小属性**（宽/高/圆角/色位），生成时吐
  /// `Container`，不借用别人的语义。
  box,

  // ---- 页面外壳（alpha.72 加）----
  //
  // 这四个不是"body 里的组件"，而是 `Scaffold(...)` 的**命名参数**：
  // appBar / AppBar.bottom / floatingActionButton / bottomNavigationBar。
  //
  // 为什么做成节点而不是 root 的 props（如 `root.props['appBarTitle']`）：
  // props 方案要把编辑入口从"点组件树那一行"降级成"先选页面、再翻到属性
  // 面板"——6 寸屏上这是明显倒退。做成节点则**零新增 UI 代码**：组件库、
  // 组件树、属性面板全是遍历驱动的，加枚举值自动出现，删除/改文案直接复用
  // 现有的 `_delete`/`_move`。
  //
  // 代价是生成器与预览都要在渲染前把它们从 children 里摘出来（见
  // `DesignCodeGen._buildRoot` 与 `design_page.dart` 的 `_buildPreview`）——
  // 一处集中、两侧对称的逻辑，而这两个函数本来就被注释声明为"刻意重复的
  // 两套实现"。
  //
  // 它们 `acceptsChildren` 全为 false：外壳是装饰，不是容器。同时
  // `design_page.dart` 的 `_addChild` 会拦截重复添加——一页只能有一个顶栏，
  // 理由同 [DesignTemplate.detail] 里那条"嵌套 root 会出现两层 Scaffold"。
  /// 顶栏（`Scaffold.appBar`）。
  appBar,

  /// 标签栏（`AppBar.bottom`）。**只在根节点下有效**。
  ///
  /// TabBar 必须挂在 AppBar 底下才能和 AppBar 拼成一块完整顶栏，独立放进
  /// body 里会变成一行光秃秃的标签。所以生成器只在"根节点同时有 appBar 和
  /// tabBar 子节点"时才生成它，单独存在时忽略（不报错——用户可能正把
  /// appBar 往上加）。
  tabBar,

  /// 悬浮按钮（`Scaffold.floatingActionButton`）。
  fab,

  /// 底部导航（`Scaffold.bottomNavigationBar`）。
  bottomNav,

  /// 未识别的占位节点（alpha.71 导入功能加）。
  ///
  /// 导入已有 UI 时，设计器不认识的 widget（自定义组件、`BlocBuilder`、
  /// `FutureBuilder`……）**不丢弃**，而是原样存成这个类型：`props['raw']`
  /// 里放源码切片，生成代码时原封不动吐回去。
  ///
  /// ⚠️ 它**不该出现在组件库里** —— 空 raw 的占位节点没有任何意义，
  /// 用户点一下只会得到一片空白。组件库的循环必须显式排除它
  /// （`design_page.dart` 的 `_galleryPanel`，有单测守着）。
  unknown;

  /// 组件库/组件树里显示的名字。
  String get label => switch (this) {
        DesignComponentType.root => '页面',
        DesignComponentType.heading => '标题',
        DesignComponentType.text => '文本',
        DesignComponentType.button => '按钮',
        DesignComponentType.textField => '输入框',
        DesignComponentType.image => '图片',
        DesignComponentType.icon => '图标',
        DesignComponentType.spacer => '间距',
        DesignComponentType.divider => '分割线',
        DesignComponentType.card => '卡片',
        DesignComponentType.listTile => '列表项',
        DesignComponentType.box => '方块',
        DesignComponentType.appBar => '顶栏',
        DesignComponentType.tabBar => '标签栏',
        DesignComponentType.fab => '悬浮按钮',
        DesignComponentType.bottomNav => '底部导航',
        DesignComponentType.unknown => '未识别',
      };

  /// 组件库里显示用的图标。
  ///
  /// 故意**不用** `IconData`：这是纯数据层，引 `flutter/material.dart`
  /// 会让本文件没法在纯 Dart 测试里跑。图标映射放在页面层。
  String get iconName => switch (this) {
        DesignComponentType.root => 'root',
        DesignComponentType.heading => 'heading',
        DesignComponentType.text => 'text',
        DesignComponentType.button => 'button',
        DesignComponentType.textField => 'textField',
        DesignComponentType.image => 'image',
        DesignComponentType.icon => 'icon',
        DesignComponentType.spacer => 'spacer',
        DesignComponentType.divider => 'divider',
        DesignComponentType.card => 'card',
        DesignComponentType.listTile => 'listTile',
        DesignComponentType.box => 'box',
        DesignComponentType.appBar => 'appBar',
        DesignComponentType.tabBar => 'tabBar',
        DesignComponentType.fab => 'fab',
        DesignComponentType.bottomNav => 'bottomNav',
        DesignComponentType.unknown => 'unknown',
      };

  /// 是否接受子节点。
  ///
  /// `card` 接受（卡片里放东西），其余叶子不接受。
  /// 根节点接受所有。
  bool get acceptsChildren =>
      this == DesignComponentType.root ||
      this == DesignComponentType.card ||
      this == DesignComponentType.box ||
      // 占位节点可能包着一整棵子树（比如一个 `BlocBuilder`），
      // 不接受子节点的话导入后它的内部结构就全丢了。
      // 它不参与生成代码（raw 整段吐回去），放子节点进去也不影响输出。
      this == DesignComponentType.unknown;

  /// 能否被删除/移动（根节点不能）。
  bool get isDeletable => this != DesignComponentType.root;

  /// 该类型的默认属性。
  Map<String, Object?> defaultProps() => switch (this) {
        DesignComponentType.root => <String, Object?>{
            // 'none' = 不生成 ColoredBox，让 Scaffold 自带背景生效。
            // 默认给个具体色位的话，用户会得到一个"自己没要求过的"底色。
            'background': 'none',
            'padding': 16.0,
            'scroll': true,
          },
        DesignComponentType.heading => <String, Object?>{
            'text': '标题',
            'align': 'left',
            'bold': true,
            'size': 24.0,
            // 'none' = 不生成 color，继承父级文字色。
            // 这是绝大多数情况想要的：标题的颜色通常由它所在的卡片/页面决定。
            'color': 'none',
          },
        DesignComponentType.text => <String, Object?>{
            'text': '正文内容',
            'align': 'left',
            'size': 14.0,
            // 'none' = 不生成 color，继承父级文字色。
            // 给死 onSurfaceVariant 的话，放在 primary 底色的卡片里就糊了。
            'color': 'none',
          },
        DesignComponentType.button => <String, Object?>{
            'text': '按钮',
            'style': 'filled',
            'width': 'full',
          },
        DesignComponentType.textField => <String, Object?>{
            'label': '输入框',
            'hint': '',
            'obscure': false,
          },
        DesignComponentType.image => <String, Object?>{
            'height': 160.0,
            'fit': 'cover',
            'radius': 12.0,
            'label': '图片',
          },
        DesignComponentType.icon => <String, Object?>{
            'name': 'star',
            'size': 32.0,
            'color': 'primary',
          },
        DesignComponentType.spacer => <String, Object?>{'height': 16.0},
        DesignComponentType.divider => <String, Object?>{'thickness': 1.0},
        DesignComponentType.card => <String, Object?>{
            'elevation': 1.0,
            'padding': 12.0,
          },
        // 方块：默认 96×96 的灰块。色位留 `none` = 不生成 color 参数，
        // 由预览层自己给个中性底色（见 design_page 的 `_previewColor` 兜底）。
        DesignComponentType.box => <String, Object?>{
            'width': 96.0,
            'height': 96.0,
            'radius': 8.0,
            'color': 'none',
          },
        DesignComponentType.listTile => <String, Object?>{
            'title': '列表项',
            'subtitle': '',
            'leadingIcon': 'circle',
          },
        DesignComponentType.appBar => <String, Object?>{
            'title': '标题',
            // 默认不给返回箭头：设计器画的都是"首页"，凭空长出一个返回箭头
            // 会让人以为生成了路由——而生成物里根本没有 Navigator。
            'showBack': false,
          },
        DesignComponentType.tabBar => <String, Object?>{
            // 固定三个：TabBar 的标签数在手机上超过 4 个就开始挤成一团，
            // 而"两个标签"的场景用分段控件更合适。三个是覆盖面最广的默认。
            'tab1': '首页',
            'tab2': '收藏',
            'tab3': '设置',
          },
        DesignComponentType.fab => <String, Object?>{
            'icon': 'add',
            'tooltip': '增加',
          },
        DesignComponentType.bottomNav => <String, Object?>{
            // 与 tabBar 同理固定三个。`icons` 是逗号分隔的图标名（见
            // `kIconNames`），而不是一个列表型字段——加列表型字段要引入新的
            // `DesignFieldKind`，那会让白名单校验测试的 switch 编译失败，
            // 收益不值得。
            'nav1': '首页',
            'nav2': '搜索',
            'nav3': '我的',
            'icons': 'home,search,person',
          },
        // `raw` 是**源码切片**（含缩进与注释，见 design_import.dart 的 sliceSource），
        // `sourceName` 只给用户看（树上那一行摘要），不参与生成。
        //
        // `width` / `height` 是 alpha.73 加的：**0 或 null = 不包外层**
        // （生成时原样吐 `raw`，一个字符都不多）。之所以要有这两个，
        // 是因为占位节点里有一类是"源码本身没法在预览里显示"的
        // ——`AnimatedContainer` 的尺寸来自 `_big ? 200 : 100`，
        // 静态展开后是个 100×100 的方块，在手机上并不明显。
        // 能给它一个确定尺寸让用户看见，比"看不见但结构对"有用。
        // 但它**默认是关的**：默认包一层就等于改了用户的布局。
        DesignComponentType.unknown => <String, Object?>{
            'raw': '',
            'sourceName': '未识别组件',
            'width': 0.0,
            'height': 0.0,
          },
      };

  /// 可编辑属性表：[字段名, 显示名, 类型]。
  ///
  /// 页面层按这个表自动渲染属性面板——加组件时只改这里 + [defaultProps]，
  /// 不用碰 UI 代码。**属性表与默认值必须同键**（有单测守着）。
  List<DesignField> get fields => switch (this) {
        DesignComponentType.root => const <DesignField>[
            DesignField('padding', '内边距', DesignFieldKind.number),
            DesignField('scroll', '可滚动', DesignFieldKind.bool_),
            DesignField('background', '背景', DesignFieldKind.colorSlot),
          ],
        DesignComponentType.heading => const <DesignField>[
            DesignField('text', '文字', DesignFieldKind.text),
            DesignField('size', '字号', DesignFieldKind.number),
            DesignField('align', '对齐', DesignFieldKind.align),
            DesignField('bold', '加粗', DesignFieldKind.bool_),
            DesignField('color', '颜色', DesignFieldKind.colorSlot),
          ],
        DesignComponentType.text => const <DesignField>[
            DesignField('text', '文字', DesignFieldKind.text),
            DesignField('size', '字号', DesignFieldKind.number),
            DesignField('align', '对齐', DesignFieldKind.align),
            DesignField('color', '颜色', DesignFieldKind.colorSlot),
          ],
        DesignComponentType.button => const <DesignField>[
            DesignField('text', '文字', DesignFieldKind.text),
            DesignField('style', '样式', DesignFieldKind.buttonStyle),
            DesignField('width', '宽度', DesignFieldKind.buttonWidth),
          ],
        DesignComponentType.textField => const <DesignField>[
            DesignField('label', '标签', DesignFieldKind.text),
            DesignField('hint', '占位提示', DesignFieldKind.text),
            DesignField('obscure', '密码框', DesignFieldKind.bool_),
          ],
        DesignComponentType.image => const <DesignField>[
            DesignField('label', '占位说明', DesignFieldKind.text),
            DesignField('height', '高度', DesignFieldKind.number),
            DesignField('radius', '圆角', DesignFieldKind.number),
            DesignField('fit', '填充', DesignFieldKind.imageFit),
          ],
        DesignComponentType.icon => const <DesignField>[
            DesignField('name', '图标', DesignFieldKind.iconName),
            DesignField('size', '大小', DesignFieldKind.number),
            DesignField('color', '颜色', DesignFieldKind.colorSlot),
          ],
        DesignComponentType.spacer => const <DesignField>[
            DesignField('height', '高度', DesignFieldKind.number),
          ],
        DesignComponentType.divider => const <DesignField>[
            DesignField('thickness', '线宽', DesignFieldKind.number),
          ],
        DesignComponentType.card => const <DesignField>[
            DesignField('elevation', '阴影', DesignFieldKind.number),
            DesignField('padding', '内边距', DesignFieldKind.number),
          ],
        DesignComponentType.box => const <DesignField>[
            DesignField('width', '宽度', DesignFieldKind.number),
            DesignField('height', '高度', DesignFieldKind.number),
            DesignField('radius', '圆角', DesignFieldKind.number),
            DesignField('color', '颜色', DesignFieldKind.colorSlot),
          ],
        DesignComponentType.listTile => const <DesignField>[
            DesignField('title', '标题', DesignFieldKind.text),
            DesignField('subtitle', '副标题', DesignFieldKind.text),
            DesignField('leadingIcon', '前置图标', DesignFieldKind.iconName),
          ],
        DesignComponentType.appBar => const <DesignField>[
            DesignField('title', '标题', DesignFieldKind.text),
            DesignField('showBack', '显示返回箭头', DesignFieldKind.bool_),
          ],
        DesignComponentType.tabBar => const <DesignField>[
            DesignField('tab1', '标签一', DesignFieldKind.text),
            DesignField('tab2', '标签二', DesignFieldKind.text),
            DesignField('tab3', '标签三', DesignFieldKind.text),
          ],
        DesignComponentType.fab => const <DesignField>[
            DesignField('icon', '图标', DesignFieldKind.iconName),
            DesignField('tooltip', '长按提示', DesignFieldKind.text),
          ],
        DesignComponentType.bottomNav => const <DesignField>[
            DesignField('nav1', '第一项', DesignFieldKind.text),
            DesignField('nav2', '第二项', DesignFieldKind.text),
            DesignField('nav3', '第三项', DesignFieldKind.text),
            // 逗号分隔，如 `home,search,person`。不是图标选择器——见
            // `kIconNames` 上那段"给按钮配个符号"的说明。
            DesignField('icons', '图标（逗号分隔 3 个）', DesignFieldKind.text),
          ],
        // 占位节点**没有布局属性**：它的宽高由 `raw` 那段源码自己决定，
        // 属性面板给的是"外面要不要包一层 SizedBox"。
        //
        // ⚠️ 这里刻意**不给** `raw` 本身建字段。`raw` 里是原文源码，
        // 用属性面板改它是改半行代码，改了多半编译不过。
        // 要改就把它删掉换成设计器认识的组件 —— 这是刻意的边界。
        DesignComponentType.unknown => const <DesignField>[
            DesignField('width', '宽度', DesignFieldKind.number),
            DesignField('height', '高度', DesignFieldKind.number),
          ],
      };

  /// 新节点默认给不给子节点。
  ///
  /// `card` 给一个空 `Column` 容器（否则"卡片里放东西"要先手动加容器，
  /// 多一步没必要的操作）；其余空列表。
  List<DesignNode> defaultChildren() => <DesignNode>[];
}

/// 一个可编辑字段。
class DesignField {
  final String key;
  final String label;
  final DesignFieldKind kind;
  const DesignField(this.key, this.label, this.kind);
}

/// 字段编辑控件的类型。
enum DesignFieldKind {
  text,

  /// 数值（用 Slider + 步进，手机上手输数字很痛苦）。
  number,
  bool_,

  /// 三选一对齐（左/中/右）。
  align,

  /// M3 语义色位，不是任意 RGB——保证切主题时跟着走。
  colorSlot,

  buttonStyle,
  buttonWidth,
  imageFit,

  /// 从内置图标名表里选（不引第三方图标包）。
  iconName,
}

/// 可选的对齐值。
const List<String> kAlignOptions = <String>['left', 'center', 'right'];

/// 标签栏的三个属性键，`TabBar` 与 `bottomNav` 的生成/预览/测试都从这里取。
///
/// 抽成常量而不是在三处硬编码 `['tab1','tab2','tab3']`：这三个键的顺序
/// 决定了生成代码里 `Tab(...)` 的排列顺序，写错一处就是"预览里顺序对、
/// 生成的代码里顺序错"—— 而且这种错误在括号配平测试里完全看不出来。
const List<String> kTabKeys = <String>['tab1', 'tab2', 'tab3'];

/// 底部导航的三个属性键。存在的理由同 [kTabKeys]。
const List<String> kNavKeys = <String>['nav1', 'nav2', 'nav3'];

/// 可选的语义色位。
///
/// ⚠️ 刻意不放开任意颜色：手调 RGB 在切换深浅主题时会变成不可读的组合
/// （深色主题下选的黑字，切到浅色就消失了）。语义位由主题派生，
/// 两边都保证可读。
///
/// `'none'` 表示"不生成 color 参数"——留空比给个默认色更好：
/// 组件会继承父级的文字色，这正是用户想要的效果。
const List<String> kColorSlots = <String>[
  'none',
  'onSurface',
  'onSurfaceVariant',
  'primary',
  'secondary',
  'error',
  'outline',
  'surface',
  'surfaceContainerHighest',
];

/// 可用的按钮样式。
const List<String> kButtonStyles = <String>['filled', 'outlined', 'text'];

/// 可用的宽度策略。
const List<String> kButtonWidths = <String>['full', 'hug'];

/// 可用的图片填充方式。
const List<String> kImageFits = <String>['cover', 'contain', 'fill'];

/// 内置图标名 → Material 图标常量名。
///
/// 只放**确实常用**的一小撮。这不是"图标选择器"，是"给按钮/列表项配个符号"。
/// 做成完整图标库需要引第三方包 + 搜索 UI，与本功能的收益不成比例。
const List<String> kIconNames = <String>[
  'star',
  'favorite',
  'home',
  'settings',
  'person',
  'search',
  'add',
  'check',
  'circle',
  'mail',
  'lock',
  'notifications',
  // alpha.73：Flutter 的官方 logo 图标。
  //
  // ⚠️ 它进来不是为了"图标库更全"，而是因为 **官方内置模板自己就在用**：
  // `anim` 模板的 `Icon(Icons.flutter_dash)`、`nav` 模板的
  // `Hero(child: FlutterLogo(...))`。模板是用户第一次接触设计器时
  // 看到的东西，它里面出现「未识别」= 用户认定这个功能是坏的。
  // 白名单少一个名字的代价，在这次的事故里比"图标库不全"高得多。
  'flutter_dash',
];

/// 模板：一键铺一棵初值树，降低"面对空白画布"的启动成本。
enum DesignTemplate {
  blank,
  login,
  list,
  detail,

  // ---- 对齐「新建项目」模板库（alpha.72 加）----
  //
  // 这四项对应 `lib/demo/demo_templates.dart` 里 `kDemoTemplates` 的
  // counter / nav / anim / tabs。**刻意不 import 那个文件**：它引了
  // `flutter/material.dart`（`DemoTemplate.icon` 是 `IconData`），而本文件
  // 的核心可测性保证就是"纯 Dart、不引 material"——引进来会让这里所有的
  // 断言都必须跑在 flutter_test 的 widget 环境里。文案因此是**手写**的，
  // 两边允许措辞不同：项目模板产出完整可运行代码，这里只产出静态骨架。
  //
  // ⚠️ 现有的 [list] 与项目模板的 `list` **不是一回事**，别合并：
  // 这里的 list 是 card + 3×listTile + divider（静态骨架，能直接改）；
  // 项目模板的 list 是 `ListView.separated` + CircleAvatar + onTap SnackBar
  // （真代码，带回调）。同名不同物是历史包袱，改名会打断已有用户的手感。
  counter,
  nav,
  anim,
  tabs;

  String get label => switch (this) {
        DesignTemplate.blank => '空白',
        DesignTemplate.login => '登录页',
        DesignTemplate.list => '列表页',
        DesignTemplate.detail => '详情页',
        DesignTemplate.counter => '计数器',
        DesignTemplate.nav => '导航',
        DesignTemplate.anim => '动画',
        DesignTemplate.tabs => '标签页',
      };

  /// 构造该模板的初值树。
  DesignNode build() {
    DesignNode n(
      DesignComponentType t, [
      Map<String, Object?>? p,
      List<DesignNode>? c,
    ]) =>
        DesignNode(type: t, props: p, children: c);

    switch (this) {
      case DesignTemplate.blank:
        return n(DesignComponentType.root);

      case DesignTemplate.login:
        return n(DesignComponentType.root, {
          'padding': 24.0,
          'scroll': true
        }, [
          n(DesignComponentType.spacer, {'height': 48.0}),
          n(DesignComponentType.icon, {
            'name': 'lock',
            'size': 56.0,
            'color': 'primary',
          }),
          n(DesignComponentType.spacer, {'height': 20.0}),
          n(DesignComponentType.heading, {
            'text': '欢迎回来',
            'align': 'center',
            'size': 26.0,
          }),
          n(DesignComponentType.text, {
            'text': '登录以继续',
            'align': 'center',
            'size': 13.0,
          }),
          n(DesignComponentType.spacer, {'height': 28.0}),
          n(DesignComponentType.textField, {
            'label': '邮箱',
            'hint': 'you@example.com',
          }),
          n(DesignComponentType.spacer, {'height': 12.0}),
          n(DesignComponentType.textField, {
            'label': '密码',
            'obscure': true,
          }),
          n(DesignComponentType.spacer, {'height': 24.0}),
          n(DesignComponentType.button, {'text': '登录'}),
        ]);

      case DesignTemplate.list:
        return n(DesignComponentType.root, {
          'padding': 0.0,
          'scroll': true
        }, [
          n(DesignComponentType.card, {
            'elevation': 0.0,
            'padding': 16.0
          }, [
            n(DesignComponentType.heading, {'text': '消息', 'size': 22.0}),
          ]),
          n(DesignComponentType.listTile, {
            'title': '第一条',
            'subtitle': '点我看看',
            'leadingIcon': 'mail',
          }),
          n(DesignComponentType.divider),
          n(DesignComponentType.listTile, {
            'title': '第二条',
            'subtitle': '再来一条',
            'leadingIcon': 'star',
          }),
          n(DesignComponentType.divider),
          n(DesignComponentType.listTile, {
            'title': '第三条',
            'subtitle': '',
            'leadingIcon': 'home',
          }),
        ]);

      case DesignTemplate.detail:
        // 封面图 + 正文卡 + 底部按钮：三段式，直接对应"详情页"的心智。
        // 用 card 而不是嵌套 root 装正文——root 只有一个（Scaffold 也是），
        // 嵌套 root 会让生成的代码里出现两层 Scaffold。
        return n(DesignComponentType.root, {
          'padding': 0.0,
          'scroll': true
        }, [
          n(DesignComponentType.image, {
            'height': 200.0,
            'radius': 0.0,
            'label': '封面图',
          }),
          n(DesignComponentType.card, {
            'elevation': 0.0,
            'padding': 16.0
          }, [
            n(DesignComponentType.heading, {'text': '标题在这里', 'size': 22.0}),
            n(DesignComponentType.spacer, {'height': 8.0}),
            n(DesignComponentType.text, {
              'text': '这里是一段正文说明。把它换成你自己的内容——'
                  '记得这只是界面骨架，交互逻辑要自己接。',
              'size': 14.0,
            }),
          ]),
          n(DesignComponentType.card, {
            'elevation': 0.0,
            'padding': 16.0
          }, [
            n(DesignComponentType.button, {'text': '立即使用'}),
          ]),
        ]);

      case DesignTemplate.counter:
        // 对齐 kDemoTemplates 的 'counter'。
        //
        // 项目模板那个是 StatefulWidget + setState 累加，这里**只留静态骨架**：
        // 顶栏 + 那行"你点击了按钮：" + 大号数字 + FAB。数字写死 0，
        // FAB 的 onPressed 是空的（生成器统一加 TODO 注释）——用户要的是
        // "摆好的界面"，累加逻辑他自己接。
        return n(
          DesignComponentType.root,
          {'padding': 24.0, 'scroll': false},
          [
            n(DesignComponentType.appBar, {'title': '计数器 Demo'}),
            n(DesignComponentType.heading, {
              'text': '你点击了按钮：',
              'size': 16.0,
              'align': 'center',
            }),
            n(DesignComponentType.spacer, {'height': 8.0}),
            n(DesignComponentType.heading, {
              'text': '0',
              'size': 56.0,
              'align': 'center',
              'color': 'primary',
            }),
            n(DesignComponentType.fab, {'icon': 'add', 'tooltip': '增加'}),
          ],
        );

      case DesignTemplate.nav:
        // 对齐 kDemoTemplates 的 'nav'。
        //
        // 原模板的核心是 Hero 过渡 + Navigator.push，这两样设计器都不生成
        // （没有路由模型）。所以这里给的是"导航页长什么样"：顶栏 + 大图标 +
        // 一个"进入详情页"按钮。用户在预览里看到的就是他要摆的东西，
        // 点按钮不会有反应——文件头已经声明过这一点。
        return n(
          DesignComponentType.root,
          {'padding': 24.0, 'scroll': false},
          [
            n(DesignComponentType.appBar, {'title': '导航 Demo'}),
            n(DesignComponentType.spacer, {'height': 32.0}),
            n(DesignComponentType.icon, {
              'name': 'home',
              'size': 96.0,
              'color': 'primary',
            }),
            n(DesignComponentType.spacer, {'height': 32.0}),
            n(DesignComponentType.button, {'text': '进入详情页'}),
          ],
        );

      case DesignTemplate.anim:
        // 对齐 kDemoTemplates 的 'anim'。
        //
        // ⚠️ 这里**不能**用 image 假装"动画方块"：生成的代码里会变成一个
        // 灰色占位框，用户点开一看是张图，反而更困惑。用 icon 画一个
        // flutter 图标 + 说明文字，如实表达"这里原本有个会动的方块"。
        return n(
          DesignComponentType.root,
          {'padding': 24.0, 'scroll': false},
          [
            n(DesignComponentType.appBar, {'title': '动画 Demo'}),
            n(DesignComponentType.spacer, {'height': 24.0}),
            n(DesignComponentType.icon, {
              'name': 'star',
              'size': 72.0,
              'color': 'primary',
            }),
            n(DesignComponentType.spacer, {'height': 12.0}),
            n(DesignComponentType.text, {
              'text': '原模板这里是一个 AnimatedContainer：点按钮在大小与颜色'
                  '之间缓动切换。设计器不生成动画控制器，'
                  '换成静态方块就是你的事。',
              'size': 13.0,
              'align': 'center',
            }),
            n(DesignComponentType.spacer, {'height': 24.0}),
            n(DesignComponentType.button, {'text': '放大'}),
          ],
        );

      case DesignTemplate.tabs:
        // 对齐 kDemoTemplates 的 'tabs'。
        //
        // 三个标签的正文用 card **铺平**，而不是生成一个空的 TabBarView ——
        // 后者会让用户以为"切标签能工作"，实际上点上去一动不动。
        // 铺平 + 注释说明是更诚实的做法（见生成器里 DefaultTabController
        // 那段注释：TabBar 本身是真的能用，只是内容不跟着切）。
        return n(
          DesignComponentType.root,
          {'padding': 0.0, 'scroll': true},
          [
            n(DesignComponentType.appBar, {'title': '标签页 Demo'}),
            n(DesignComponentType.tabBar, {
              'tab1': '首页',
              'tab2': '收藏',
              'tab3': '设置',
            }),
            for (final t in const ['首页内容', '收藏内容', '设置内容'])
              n(DesignComponentType.card, {
                'elevation': 0.0,
                'padding': 16.0
              }, [
                n(DesignComponentType.heading, {'text': t, 'size': 18.0}),
                n(DesignComponentType.spacer, {'height': 6.0}),
                n(DesignComponentType.text, {
                  'text': '把这里换成「$t」真正要显示的东西。',
                  'size': 13.0,
                }),
              ]),
          ],
        );
    }
  }
}

// ============================ 代码生成 ============================

/// 生成器：把设计树转成 Dart 源码字符串。
///
/// 纯函数、无副作用、不碰文件系统——写盘由页面层调 `FsBridge.write`。
/// 这样"生成的代码对不对"可以纯字符串断言，不需要真机。
class DesignCodeGen {
  const DesignCodeGen._();

  /// 生成完整文件内容。
  ///
  /// [className] 必须是合法 Dart 类名（调用方保证，见 [classNameFor]）。
  static String generate(DesignNode root, {required String className}) {
    final buf = StringBuffer();
    buf.writeln('// 由 FOAIDE「设计」生成 —— 请把它当**起点**，不是成品。');
    buf.writeln('//');
    buf.writeln('// 这里只有**静态界面**：没有业务逻辑、没有状态管理、没有数据流、');
    buf.writeln('// 没有路由。按钮点了不会有反应，输入框的内容也没人读——');
    buf.writeln('// 那些都要你自己接上。');
    buf.writeln('//');
    buf.writeln('// 生成时间：$timestamp');
    buf.writeln('// 改这个文件之前，建议先另存一份，'
        '或者直接用「设计」区重新生成。');
    buf.writeln();
    buf.writeln("import 'package:flutter/material.dart';");
    buf.writeln();
    buf.writeln('class $className extends StatelessWidget {');
    buf.writeln('  const $className({super.key});');
    buf.writeln();
    buf.writeln('  @override');
    buf.writeln('  Widget build(BuildContext context) {');
    // build 方法体内的代码统一缩进 2 层（类 1 层 + 方法 1 层）。
    final body = _indentAll(_build(root, asRoot: true), 2);
    for (final line in body) {
      buf.writeln(line);
    }
    buf.writeln('  }');
    buf.writeln('}');
    return buf.toString();
  }

  /// 生成类名：`Design20260922_160300`。
  ///
  /// 用时间戳而不是"设计1/设计2"：用户会反复生成、反复丢弃，
  /// 序号会让他分不清哪个是新的。时间戳天然有序且唯一。
  static String classNameFor(DateTime t) {
    String p2(int v) => v.toString().padLeft(2, '0');
    return 'Design${t.year}${p2(t.month)}${p2(t.day)}'
        '_${p2(t.hour)}${p2(t.minute)}${p2(t.second)}';
  }

  /// 文件名（不含目录）：与类名同源，便于"类名 ↔ 文件名"对应。
  static String fileNameFor(DateTime t) => '${classNameFor(t)}.dart';

  /// 从已有 UI 导入时的类名：`LoginPage` → `LoginPageDesign20260922_160300`。
  ///
  /// **为什么带上原类名**：用户导入了 `LoginPage`，改完拿到的类如果叫
  /// `Design20260922_...`，他完全看不出这东西是从哪来的。带上原名，
  /// "血缘"一目了然 —— 配合页面顶部那行「来自 login_page.dart:42」，
  /// 用户能立刻建立对应关系。
  ///
  /// ⚠️ 不带下划线分隔原名与时间戳：原名可能以下划线结尾（`Login_Page_`），
  /// 再拼一个下划线会出现连续两个，不好读。
  static String classNameForImport(String sourceClassName, DateTime t) {
    final base = _sanitizeIdentifier(sourceClassName);
    return '$base${classNameFor(t)}';
  }

  /// 从已有 UI 导入时的文件名（不含目录）。
  static String fileNameForImport(String sourceClassName, DateTime t) =>
      '${classNameForImport(sourceClassName, t)}.dart';

  /// 把任意字符串收拾成一个合法 Dart 标识符。
  ///
  /// 正常路径上类名已经是合法的（它来自 AST 的 `ClassDeclaration.name`），
  /// 但导入入口允许用户从文件名推类名，这一步是兜底 ——
  /// 生成一个**编译不过**的类名比报错还糟（错误信息会指向用户看不懂的地方）。
  static String _sanitizeIdentifier(String raw) {
    final buf = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      final ok = RegExp(r'[A-Za-z0-9_]').hasMatch(ch);
      buf.write(ok ? ch : '_');
    }
    var s = buf.toString();
    if (s.isEmpty) return 'Imported';
    // 首字符不能是数字。
    if (RegExp(r'^[0-9]').hasMatch(s)) s = 'X$s';
    return s;
  }

  /// 生成时用的时间戳字符串。
  ///
  /// ⚠️ 测试里要固定它——否则每次生成的注释头都不同，
  /// "生成的代码稳定"这类断言会变成 flaky。
  static String timestamp = '—';

  // ==================== 递归生成（相对缩进） ====================
  //
  // 设计：各分支返回**不含缩进**的行列表，嵌套时由父节点统一加一层。
  // 早先的写法是"把 indent 传下去、各分支自己拼好绝对缩进"，
  // 结果父节点再拼一次就变成双重缩进 —— 生成的代码嵌套层级看着是平的。
  // 相对缩进没有这个问题：层级由嵌套结构本身决定，不可能算错。

  /// 递归生成节点代码，返回**相对缩进**（左对齐）的行列表。
  static List<String> _build(DesignNode node, {bool asRoot = false}) {
    switch (node.type) {
      case DesignComponentType.root:
        return _buildRoot(node, asRoot: asRoot);

      case DesignComponentType.heading:
      case DesignComponentType.text:
        final align = _align(node.props['align']);
        final hasThemeColor = _colorOf(node.props['color']) != null;
        final style = <String>[
          if (_d(node.props['size']) != null)
            'fontSize: ${_num(_d(node.props['size'])!)}',
          if (node.type == DesignComponentType.heading)
            if (node.props['bold'] == true) 'fontWeight: FontWeight.bold',
          if (hasThemeColor) 'color: ${_colorOf(node.props['color'])}',
        ];
        // ⚠️ 带主题色时**不能**加 const：`Theme.of(context)` 不是常量表达式，
        // `const Text('x', style: TextStyle(color: Theme.of(context)...))`
        // 是**编译错误**。没选颜色时才加 const（纯字面量）。
        final c = hasThemeColor ? '' : 'const ';
        final textLines = <String>[
          '${c}Text(',
          "  ${_str(node.props['text'])},",
          if (style.isNotEmpty) '  style: TextStyle(${style.join(', ')}),',
          '),',
        ];
        if (align != null) {
          return <String>[
            'Align(',
            '  alignment: $align,',
            '  child: ${textLines.first}',
            ..._indentAll(textLines.skip(1).toList()),
            '),',
          ];
        }
        return textLines;

      case DesignComponentType.button:
        final styleKey = node.props['style'] as String? ?? 'filled';
        final ctor = switch (styleKey) {
          'outlined' => 'OutlinedButton',
          'text' => 'TextButton',
          _ => 'FilledButton',
        };
        final inner = '$ctor(onPressed: () {}, '
            'child: const Text(${_str(node.props['text'])})),';
        if (node.props['width'] == 'full') {
          return <String>[
            'SizedBox(',
            '  width: double.infinity,',
            '  child: $inner',
            '),',
          ];
        }
        return <String>[inner];

      case DesignComponentType.textField:
        return <String>[
          'TextField(',
          '  decoration: InputDecoration(',
          '    labelText: ${_str(node.props['label'])},',
          if ((node.props['hint'] as String? ?? '').isNotEmpty)
            '    hintText: ${_str(node.props['hint'])},',
          '    border: const OutlineInputBorder(),',
          '  ),',
          if (node.props['obscure'] == true) '  obscureText: true,',
          '),',
        ];

      case DesignComponentType.image:
        final h = _d(node.props['height']) ?? 160;
        final r = _d(node.props['radius']) ?? 12;
        final fit = _fit(node.props['fit']);
        // 占位而不是真图片：设计期没有图片资源，硬写路径用户跑起来会看到
        // "图片加载失败"的红框，比占位更让人困惑。
        return <String>[
          'Container(',
          '  height: ${_num(h)},',
          '  decoration: BoxDecoration(',
          '    color: Theme.of(context).colorScheme.surfaceContainerHighest,',
          '    borderRadius: BorderRadius.circular(${_num(r)}),',
          '  ),',
          '  alignment: Alignment.center,',
          '  child: Column(',
          '    mainAxisSize: MainAxisSize.min,',
          '    children: [',
          '      const Icon(Icons.image_outlined, size: 32),',
          '      const SizedBox(height: 6),',
          '      Text(${_str(node.props['label'])}),',
          '    ],',
          '  ),',
          '),',
          // fit 只在换成真图片后才有效，所以生成成注释而不是参数 ——
          // 写成参数的话 const 会失效（BoxFit 是常量，但整块结构还不是 const），
          // 而且用户会以为"我现在填了 cover 就有图了"。
          if (fit != null) '// 换成真实图片时设置 fit: $fit',
        ];

      case DesignComponentType.icon:
        final size = _d(node.props['size']) ?? 32;
        final color = _colorOf(node.props['color']);
        return <String>[
          'Icon(',
          '  ${_iconConst(node.props['name'])},',
          '  size: ${_num(size)},',
          if (color != null) '  color: $color,',
          '),',
        ];

      case DesignComponentType.spacer:
        final h = _num(_d(node.props['height']) ?? 16);
        return <String>['const SizedBox(height: $h),'];

      case DesignComponentType.divider:
        final t = _num(_d(node.props['thickness']) ?? 1);
        return <String>['const Divider(thickness: $t),'];

      case DesignComponentType.card:
        return _buildCard(node);

      case DesignComponentType.box:
        return _buildBox(node);

      case DesignComponentType.listTile:
        final subtitle = node.props['subtitle'] as String? ?? '';
        return <String>[
          'ListTile(',
          '  leading: const Icon(${_iconConst(node.props['leadingIcon'])}),',
          '  title: const Text(${_str(node.props['title'])}),',
          if (subtitle.isNotEmpty) '  subtitle: const Text(${_str(subtitle)}),',
          '  onTap: () {},',
          '),',
        ];

      case DesignComponentType.unknown:
        // 导入时没认出来的 widget —— **原样吐回去**。
        //
        // `raw` 是源码切片（`source.substring(node.offset, node.end)`），
        // 所以它自带缩进、自带注释、自带用户写的一切。
        // 我们只负责给它补一个逗号（它作为 `children: [...]` 的元素
        // 必须以逗号结尾；源码片段本身通常以 `)` 收尾，不补的话
        // 生成的 .dart **直接编译不过**）。
        final raw = (node.props['raw'] as String? ?? '').trimRight();
        if (raw.isEmpty) {
          // 空占位（理论上不该出现，但属性面板/导入边界都可能漏一个）。
          // 生成一行注释而不是空字符串 —— 空字符串会在 children 列表里
          // 留下一个空白行，用户看到的是"这里怎么空了一块"。
          return <String>['// （未识别组件，已跳过）'];
        }
        final lines = raw.split('\n');
        final body = raw.endsWith(',')
            ? lines
            : <String>[
                ...lines.sublist(0, lines.length - 1),
                '${lines.last},',
              ];
        // 可选的外层尺寸（见 defaultProps 里的说明）。
        // 两个都是 0 / null 时**一个字符都不加** —— 默认必须和"没有这个
        // 功能"完全等价，否则用户升级后会看到生成结果里凭空多出 SizedBox。
        final w = _positive(node.props['width']);
        final h = _positive(node.props['height']);
        if (w == null && h == null) return body;
        // ⚠️ 必须用**命名参数** `child:`，不能图省事写成位置参数
        // `SizedBox(100, 100, child)`：
        // - `child:` 的写法，只要 child 本身是编译期常量，
        //   整个 `SizedBox` 就能加 `const` —— 少一次无谓的重建。
        // - 而且 Flutter 新版本对 `SizedBox` 的首个位置参数已经标了
        //   弃用警告，位置写法会让用户一打开就看见黄色波浪线。
        final child = body.first;
        final isConst = child.startsWith('const ');
        return <String>[
          '${isConst ? 'const ' : ''}SizedBox(',
          if (w != null) '  width: ${_num(w)},',
          if (h != null) '  height: ${_num(h)},',
          '  child: $child',
          ...body.skip(1),
          '),',
        ];

      // ---- 页面外壳 ----
      //
      // 正常情况下这四个**走不到这里**：`_buildRoot` 会先把它们从 children
      // 里摘出去，当 `Scaffold(...)` 的命名参数生成。
      //
      // 能走到这里只有一种情况：用户把它们挂在了**非根节点**下（比如塞进
      // 卡片里）。此时不报错、也不画东西，只留一行注释说明去哪改 —— 用户
      // 多半是刚加完还没来得及往上拖，弹错误框会很烦人；但要是静默吞掉，
      // 他又会找不到自己刚加的东西。
      case DesignComponentType.appBar:
      case DesignComponentType.tabBar:
      case DesignComponentType.fab:
      case DesignComponentType.bottomNav:
        return <String>[
          '// （${node.type.label}只能放在页面根节点下，此处已跳过）',
        ];
    }
  }

  /// 在根节点的直接子节点里找第一个指定类型的节点。
  ///
  /// 只找**直接子节点**，不递归：外壳组件挂在深层没有意义（`Scaffold` 的
  /// 命名参数只认根这一层），递归下去反而会把用户误拖进卡片里的 AppBar
  /// 也提升上来，生成一个他看都没看到的顶栏。
  static DesignNode? _pick(DesignNode root, DesignComponentType t) {
    for (final c in root.children) {
      if (c.type == t) return c;
    }
    return null;
  }

  /// 页面外壳的**唯一判定入口**：哪些子节点该被提升成 `Scaffold` 命名参数。
  ///
  /// 生成器与预览（`design_page.dart` 的 `_buildPreview`）必须用同一套规则，
  /// 否则会出现"预览里有顶栏、生成的代码里没有"这种最难查的不一致。
  /// 两边各调一次本方法——这是刻意保留的唯一共享点。
  static bool isShellType(DesignComponentType t) =>
      t == DesignComponentType.appBar ||
      t == DesignComponentType.tabBar ||
      t == DesignComponentType.fab ||
      t == DesignComponentType.bottomNav;

  /// 根节点：Column → [Padding] → [ColoredBox]，由内向外包，
  /// 最后套 Scaffold + SafeArea（+ 可选 SingleChildScrollView），
  /// 并把外壳节点提升成 `Scaffold` 的命名参数。
  static List<String> _buildRoot(DesignNode node, {required bool asRoot}) {
    final padding = _d(node.props['padding']) ?? 16;
    final bg = _colorOf(node.props['background']);
    final scroll = node.props['scroll'] == true;

    // ⚠️ 外壳节点**不进 Column.children** —— 它们是 `Scaffold(...)` 的命名
    // 参数（appBar / floatingActionButton / bottomNavigationBar），在 widget
    // 树里根本不是 body 的兄弟。先在这里摘干净，后面 Column 只收 body 组件。
    final bodyChildren =
        node.children.where((c) => !isShellType(c.type)).toList();

    // 孩子排成 Column 的 children —— 不做绝对定位。
    // 手机上没有鼠标，"拖到指定坐标"的精度根本不够用；
    // 顺序即布局，用组件树的上移/下移调整，比拖拽可控得多。
    //
    // `children: [` 里的元素要比 `children:` 那行**多缩一层**（见 `  ],`），
    // 否则列表项和它的开括号齐平，读起来像平级语句。
    var lines = <String>[
      'Column(',
      '  crossAxisAlignment: CrossAxisAlignment.stretch,',
      '  mainAxisSize: MainAxisSize.min,',
      '  children: [',
      for (final c in bodyChildren) ..._indentAll(_build(c), 2),
      '  ],',
      '),',
    ];

    // 逐层向外包。每层都是"开几行 + 把里面整体缩进 + 关几行"。
    if (padding > 0) {
      lines = _wrap(lines, 'Padding(',
          args: ['  padding: const EdgeInsets.all(${_num(padding)}),']);
    }

    if (bg != null) {
      lines = _wrap(lines, 'ColoredBox(', args: ['  color: $bg,']);
    }

    if (!asRoot) return lines;

    // Scaffold 的命名参数，顺序与 Flutter 文档一致（appBar → body → fab → bottomNav）。
    final shellArgs = _shellArgs(node);

    // build 的 return 语句。scroll 版本多挑一层 SingleChildScrollView。
    //
    // ⚠️ 这里的 `close` 必须显式写 `);` 而不是用默认的 `),`：
    // `body: SafeArea(` 由 `args` 打开、由 `epilogue` 收尾，`_wrap` 末尾那个
    // `close` 收的是**外层 Scaffold** —— 它同时也是 `return` 语句的结束，
    // 所以必须带分号。早先 shellArgs 恒为空时这两件事碰巧能混过去，
    // shellArgs 一非空就露馅。
    //
    // 另一个坑：这里**不能**先写 `);` 再在下面补分号。`),;` 不是合法 Dart
    // （括号配平测试查不出来，它只数括号），必须一次写对。
    if (scroll) {
      lines = _wrap(lines, 'Scaffold(',
          args: [...shellArgs, '  body: SafeArea('],
          prelude: ['    child: SingleChildScrollView('],
          childDepth: 3,
          epilogue: ['    ),', '  ),'],
          close: ');');
    } else {
      lines = _wrap(lines, 'Scaffold(',
          args: [...shellArgs, '  body: SafeArea('],
          childDepth: 2,
          epilogue: ['  ),'],
          close: ');');
    }

    // ⚠️ TabBar 依赖祖先 `DefaultTabController` —— 没有它会在**运行时**抛
    // "No TabController for TabBar"。这是最阴的一类坑：生成的代码能编译、
    // 能过静态检查，用户装上机一点就崩，而且报错栈指向 Framework 内部。
    // 所以只要有 TabBar，就无条件补一层 DefaultTabController。
    //
    // 上面 Scaffold 那层已经把分号收掉了（`close: ');'`），所以这里**必须**
    // 把那个分号摘掉再套新壳，否则会出现 `);;`。
    if (_pick(node, DesignComponentType.tabBar) != null) {
      final inner = <String>[
        ...lines.sublist(0, lines.length - 1),
        lines.last.endsWith(';')
            ? lines.last.substring(0, lines.last.length - 1)
            : lines.last,
      ];
      lines = _wrap(inner, 'DefaultTabController(',
          args: ['  length: 3,'], childDepth: 1, close: ');');
    }

    return <String>['return ${lines.first}', ...lines.skip(1)];
  }

  /// 生成 `Scaffold` 的命名参数行（不含 `body:`，由调用方拼在其前）。
  ///
  /// 返回的每一行都**自带两格缩进**，因为 `_wrap` 会把整个列表原样塞进
  /// `Scaffold(` 之后的位置。多行参数（AppBar 带 TabBar、NavigationBar 的
  /// destinations）内部再各自递进。
  static List<String> _shellArgs(DesignNode node) {
    final args = <String>[];

    final appBar = _pick(node, DesignComponentType.appBar);
    if (appBar != null) {
      // showBack 用 leading 显式画一个返回箭头，而不是 `automaticallyImply
      // Leading: true` —— 后者只在"确实有上一页"时才画，而这个生成物里
      // 压根没有 Navigator，打开永远是首页，那个开关点了等于没点。
      final showBack = appBar.props['showBack'] == true;
      final title = 'title: Text(${_str(appBar.props['title'])}),';
      final tabs = _pick(node, DesignComponentType.tabBar);

      if (tabs == null) {
        args.add('  appBar: AppBar(');
        args.add('    $title');
        if (showBack) args.add(_backButtonLine);
        args.add('  ),');
      } else {
        args.add('  appBar: AppBar(');
        args.add('    $title');
        if (showBack) args.add(_backButtonLine);
        args.add('    bottom: TabBar(');
        args.add('      tabs: [');
        for (final k in kTabKeys) {
          args.add('        Tab(text: ${_str(tabs.props[k])}),');
        }
        args.add('      ],');
        args.add('    ),');
        args.add('  ),');
      }
    }

    final fab = _pick(node, DesignComponentType.fab);
    if (fab != null) {
      args.add('  floatingActionButton: FloatingActionButton(');
      // 与按钮/列表项同一立场：静态骨架，回调留空但**标明接哪**。
      args.add('    onPressed: () {}, // TODO: 接你的逻辑');
      args.add('    tooltip: ${_str(fab.props['tooltip'])},');
      args.add('    child: const Icon(${_iconConst(fab.props['icon'])}),');
      args.add('  ),');
    }

    final nav = _pick(node, DesignComponentType.bottomNav);
    if (nav != null) {
      // 选 M3 的 NavigationBar 而非 BottomNavigationBar：项目全面 M3。
      final labels = <String>[
        for (final k in kNavKeys) (nav.props[k] ?? '').toString(),
      ];
      final icons = (nav.props['icons'] ?? '').toString().split(',');
      args.add('  bottomNavigationBar: NavigationBar(');
      args.add('    selectedIndex: 0, // TODO: 接状态');
      args.add('    destinations: [');
      for (var i = 0; i < labels.length; i++) {
        final ic = i < icons.length ? icons[i].trim() : 'circle';
        args.add('      NavigationDestination(');
        args.add('        icon: const Icon(${_iconConst(ic)}),');
        args.add('        label: ${_str(labels[i])},');
        args.add('      ),');
      }
      args.add('    ],');
      args.add('  ),');
    }

    return args;
  }

  /// AppBar 的返回箭头。恒 disabled —— 生成物里没有 Navigator。
  static const String _backButtonLine =
      '    leading: const BackButton(onPressed: null),';

  /// 卡片：Card → Padding → Column。
  /// 方块：一个 `Container`，只有尺寸 / 圆角 / 底色三样。
  ///
  /// 子节点会作为 `child:` 塞进去（`AnimatedContainer` 里那个 `Icon` 就是），
  /// 所以它和 `card` 一样是个容器类型。
  static List<String> _buildBox(DesignNode node) {
    final w = _d(node.props['width']);
    final h = _d(node.props['height']);
    final r = _d(node.props['radius']);
    final color = _colorOf(node.props['color']);
    final args = <String>[
      if (w != null) '  width: ${_num(w)},',
      if (h != null) '  height: ${_num(h)},',
      if (r != null && r > 0)
        '  decoration: BoxDecoration('
            'borderRadius: BorderRadius.circular(${_num(r)})),',
      if (color != null) '  color: $color,',
    ];
    if (node.children.isEmpty) {
      return <String>['Container(', ...args, '),'];
    }
    return _wrap(_build(node.children.first), 'Container(', args: args);
  }

  static List<String> _buildCard(DesignNode node) {
    final elevation = _d(node.props['elevation']) ?? 1;
    final padding = _d(node.props['padding']) ?? 12;
    return <String>[
      'Card(',
      '  elevation: ${_num(elevation)},',
      '  child: Padding(',
      '    padding: const EdgeInsets.all(${_num(padding)}),',
      '    child: Column(',
      '      crossAxisAlignment: CrossAxisAlignment.stretch,',
      '      mainAxisSize: MainAxisSize.min,',
      '      children: [',
      for (final c in node.children) ..._indentAll(_build(c), 4),
      '      ],',
      '    ),',
      '  ),',
      '),',
    ];
  }

  // ==================== 缩进/包裹工具 ====================

  /// 给一组行统一加一层缩进（2 空格）。
  static List<String> _indentAll(List<String> lines, [int extra = 1]) {
    if (extra == 0) return lines;
    final pad = '  ' * extra;
    return lines.map((l) => l.isEmpty ? l : '$pad$l').toList();
  }

  /// 通用包裹：把 [inner] 放进一个新容器。
  ///
  /// 产出结构：
  /// ```
  /// open(                       ← open 行
  ///   args...                   ← args 原样（已含自己的缩进）
  ///   prelude...                ← prelude 原样
  ///   child: <inner 第一行>      ← 接上 inner
  ///   <inner 其余行，跟着 child 同样的缩进>
  ///   epilogue...               ← epilogue 原样
  /// )                           ← 收尾
  /// ```
  ///
  /// 之前试过"自动推算该关几个括号"，那套逻辑一旦遇到
  /// `SafeArea` 里再套 `SingleChildScrollView` 这种多层 open 就会错位
  /// （生成的收尾括号和缩进全乱）。现在改成**显式给 epilogue**：
  /// 调用点最清楚自己开了几层、该怎么关，交给它比让工具猜可靠。
  ///
  /// [childDepth] 是 `child:` 那行的缩进层级——由调用点按"自己开了几层
  /// 还没关的容器"给出，不是推算出来的。
  static List<String> _wrap(
    List<String> inner,
    String open, {
    List<String> args = const <String>[],
    List<String> prelude = const <String>[],
    List<String> epilogue = const <String>[],
    int childDepth = 1,

    /// 收尾括号：嵌套在参数里用 `),`，作为语句收尾用 `);`。
    String close = '),',
  }) {
    return <String>[
      open,
      ...args,
      ...prelude,
      '${'  ' * childDepth}child: ${inner.first}',
      ..._indentAll(inner.skip(1).toList(), childDepth),
      ...epilogue,
      close,
    ];
  }

  // ---------------- 小工具 ----------------

  /// `double?` 取值——属性表里数值存的是 `double`，但 JSON 往返后可能是 `int`。
  static double? _d(Object? v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// 数值字面量：整数省略 `.0`（`16.0` 能编译，但 `const EdgeInsets.all(16)`
  /// 比 `all(16.0)` 更像人写的）。
  static String _num(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// 可选尺寸：只有**正数**才算用户设过。
  ///
  /// 0 / null / 负数一律返回 null = "不生成这个参数"。
  /// 用 0 当"没设"而不是用 null 当"没设"，是因为属性面板的 Slider
  /// 需要一个数值起点 —— 让用户在 `null` 和 `0` 之间体会区别是残忍的。
  static double? _positive(Object? v) {
    if (v is num) {
      final d = v.toDouble();
      if (d > 0) return d;
    }
    return null;
  }

  /// Dart 字符串字面量（转义单引号和 `$`）。
  ///
  /// `$` 必须转义：用户输入 "价格 $100" 时不转义会变成插值表达式 → 编译错。
  static String _str(Object? v) {
    final s = (v ?? '').toString();
    final escaped = s
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(r'$', r'\$')
        .replaceAll('\n', r'\n');
    return "'$escaped'";
  }

  /// 对齐 → `Alignment` 表达式；`left` 返回 `null`（默认值不生成多余代码）。
  static String? _align(Object? v) => switch (v) {
        'center' => 'Alignment.center',
        'right' => 'Alignment.centerRight',
        _ => null,
      };

  static String? _fit(Object? v) => switch (v) {
        'contain' => 'BoxFit.contain',
        'fill' => 'BoxFit.fill',
        'cover' => 'BoxFit.cover',
        _ => null,
      };

  /// 语义色位 → `Theme.of(context).colorScheme.xxx`。
  ///
  /// 生成表达式而不是字面色值：这样用户切主题时生成的界面跟着走，
  /// 不会出现"设计时是深色好看，换浅色一片糊"。
  static String? _colorOf(Object? v) {
    final s = v as String?;
    if (s == null || s.isEmpty || s == 'none') return null;
    if (!kColorSlots.contains(s)) return null;
    return 'Theme.of(context).colorScheme.$s';
  }

  /// 内置图标名 → `Icons.xxx`。未知名字退回 `Icons.circle`（不生成编译不过的代码）。
  static String _iconConst(Object? v) {
    const map = <String, String>{
      'star': 'Icons.star_outline',
      'favorite': 'Icons.favorite_outline',
      'home': 'Icons.home_outlined',
      'settings': 'Icons.settings_outlined',
      'person': 'Icons.person_outline',
      'search': 'Icons.search',
      'add': 'Icons.add',
      'check': 'Icons.check',
      'circle': 'Icons.circle_outlined',
      'mail': 'Icons.mail_outline',
      'lock': 'Icons.lock_outline',
      'notifications': 'Icons.notifications_outlined',
      'flutter_dash': 'Icons.flutter_dash',
    };
    return map[v] ?? 'Icons.circle_outlined';
  }

  /// 图标名 → 页面预览用的 `IconData` 常量名（同上表，供页面层反射用）。
  static String iconConstFor(Object? v) => _iconConst(v);
}

/// 从「未识别组件」的源码切片里**尽力**提取视觉属性。
///
/// ## 为什么需要它（alpha.75）
///
/// 用户导入自己的项目后，未识别组件在预览里是清一色的黄框
/// 「未识别：xxx」—— 一屏十几个黄框，看起来像工具坏了。
/// 用户的原话是"设计有控件不适配，能否适配所有原生组件"。
///
/// 「适配所有组件」做不到（Flutter 有 400+ widget，且用户自定义方法
/// 的实现在别处、静态分析推不出来）。但**能做的**是：既然源码就在手里
/// （`unknown` 节点的 `raw` 存了完整切片），就把源码里**一眼能看出来的**
/// 视觉信息提取出来，按它渲染 —— 用户看到的就不是黄框，而是一个
/// 尺寸/颜色/圆角都接近原貌的方块。
///
/// ## 边界（必须说清，不能骗用户）
///
/// 这是**文本启发式**，不是 AST 分析。它只认下面这些直白写法：
/// `width: 100` / `color: Colors.blue` / `BorderRadius.circular(8)` /
/// `EdgeInsets.all(16)` / `Icons.add` / `elevation: 4`。
/// 遇到变量（`width: w`）、表达式（`color: _theme.c`）一律**放弃该项**
/// （返回 null），不用猜测值代替 —— 猜错了比不画更误导。
///
/// 提取不到任何东西时（典型：纯方法调用 `_buildStatusCard(context)`），
/// 调用方仍走原来的提示框路径。这是诚实的：那种情况确实无从知晓。
class UnknownVisual {
  const UnknownVisual({
    this.width,
    this.height,
    this.color,
    this.radius,
    this.padding,
    this.iconName,
    this.elevation,
  });

  /// 从源码切片提取。`raw` 为空或提取不到任何东西时返回 null。
  ///
  /// ⚠️ 只在**最外层构造自己的参数**里找，不扫子节点 —— 全局搜会把
  /// `child: Column(children: [SizedBox(height: 4)])` 里**子节点的**
  /// `height: 4` 误当成外层的尺寸。alpha.78 真机实测：`_buildActionButton`
  /// 的按钮 Container 因此被强设成 4px 高，里面的图标和"打开终端"
  /// 全被裁没了，用户看到的就是一条条压扁的横线。
  static UnknownVisual? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    // 只在「外层自己的参数 + 值类型参数内部」里找，widget 型子节点
    // 的内容被 [_extractScope] 整体跳过。
    final top = _extractScope(s);

    final w = _px(top, 'width');
    final h = _px(top, 'height');
    final r = _radius(top);
    final pad = _padding(top);
    final col = _color(top);
    final icon = _icon(top);
    final elev = _int(top, 'elevation');

    if (w == null &&
        h == null &&
        r == null &&
        pad == null &&
        col == null &&
        icon == null &&
        elev == null) {
      return null;
    }
    return UnknownVisual(
      width: w,
      height: h,
      color: col,
      radius: r,
      padding: pad,
      iconName: icon,
      elevation: elev,
    );
  }

  /// 收集「可提取范围」的文本：外层调用自己的参数 + **值类型**参数
  /// （`BoxDecoration` / `Color` / `EdgeInsets` / `TextStyle` …，见
  /// [kNonWidgetTypeNames]）的内部；**widget 型嵌套调用**（`Column` /
  /// `Text` / `_buildXxx` …）的内容整体跳过，只留 `Name()` 占位。
  ///
  /// 为什么按「值类型 / widget 型」分而不是按括号深度切：
  /// `child: Column(children: [SizedBox(height: 4)])` 里，`child:` 的值
  /// 整个是顶层参数 —— 单纯按深度切段，切段后嵌套内容**仍然在段里**，
  /// `height: 4` 照样被搜出来（第一、二版都栽在这，探针当场抓到）。
  /// 真正可靠的判据是**语义**：值类型参数（decoration 之类）的内部还是
  /// 外层组件自己的视觉属性，可以提；widget 型参数的内部是**子节点**，
  /// 它们的尺寸/颜色属于孩子自己的节点，外层一概不能碰。
  ///
  /// 跳过的调用在输出里留 `Name()` 占位，保证逗号结构不串位。
  ///
  /// 这里只做字符级扫描，不引入 analyzer —— [parse] 所在层保持纯 Dart
  /// （见上方 `color` 字段的注释）。
  static String _extractScope(String s) {
    final open = s.indexOf('(');
    if (open < 0) return s;

    final out = StringBuffer();
    var depth = 1; // 已在（唯一的）外层调用括号内
    var i = open + 1;
    String? quote;
    // `TextStyle(height: 1.4)` 的 height 是**行高倍数**不是像素 ——
    // 进入 TextStyle 后把 `height` 改名，防止被当尺寸提走。
    var styleDepth = -1;
    while (i < s.length) {
      final ch = s[i];
      if (quote != null) {
        if (ch == quote) quote = null;
        out.write(ch);
        i++;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
        out.write(ch);
        i++;
        continue;
      }
      if (ch == '(' || ch == '[' || ch == '{') {
        depth++;
        out.write(ch);
        i++;
        continue;
      }
      if (ch == ')' || ch == ']' || ch == '}') {
        if (ch == ')' && depth == 1) break; // 外层闭括号，扫描结束
        depth--;
        if (styleDepth != -1 && depth <= styleDepth) styleDepth = -1;
        out.write(ch);
        i++;
        continue;
      }
      // 标识符链（含 `.`：`Icons.x` / `BorderRadius.circular` / `const`）
      if (_isIdentStart(ch)) {
        var j = i;
        while (j < s.length && (_isIdentPart(s[j]) || s[j] == '.')) {
          j++;
        }
        var chain = s.substring(i, j);
        while (chain.endsWith('.')) {
          chain = chain.substring(0, chain.length - 1);
          j--;
        }
        var k = j;
        while (k < s.length && s[k] == ' ') {
          k++;
        }
        final isCall = k < s.length && s[k] == '(';

        // TextStyle 内部的 `height:` → 行高，改名防误提
        if (styleDepth != -1 && chain == 'height' && _nextIsColon(s, j)) {
          out.write('_line_height_');
          i = j;
          continue;
        }

        if (isCall) {
          final segments = chain.split('.');
          final isValueType = segments.any(kNonWidgetTypeNames.contains);
          if (isValueType) {
            // 值类型（Color/BoxDecoration/TextStyle…）：内容还是外层
            // 自己的视觉属性，继续扫。TextStyle 单独标记 —— 它内部的
            // `height:` 是行高倍数不是像素。
            // ⚠️ 任何深度都可能遇到（`style: TextStyle(...)` 直接就是
            // 外层的参数值，depth==1），标记不能只写在 depth>=2 分支里。
            // ⚠️ 它的 `(` 必须自己把深度 +1 —— 主循环不会再处理这个字符
            // （i 直接跳过了它），漏加的话里面配对的 `)` 会被当成外层
            // 闭括号，扫描提前终止（第一版就栽在这：`Color(0xFF10B981`
            // 缺了右括号，颜色正则匹配不上）。
            if (segments.contains('TextStyle')) styleDepth = depth;
            depth++;
            out
              ..write(chain)
              ..write('(');
            i = k + 1;
            continue;
          }
          // widget / 未知调用（Column/Text/_buildXxx…）：内容是子节点
          // 的地盘，整体跳过、留占位。**任何深度都跳** —— depth==1 时
          // 它是 `child:` / `children:` 的直接值，内部同样是子节点
          // （`Container(child: SizedBox(width: 99))` 的 99 不是外层的）。
          out
            ..write(chain)
            ..write('()');
          i = _skipBalancedCall(s, k);
          continue;
        }
        out.write(chain);
        i = j;
        continue;
      }
      out.write(ch);
      i++;
    }
    return out.toString();
  }

  static bool _nextIsColon(String s, int from) {
    for (var i = from; i < s.length; i++) {
      final c = s[i];
      if (c == ' ') continue;
      return c == ':';
    }
    return false;
  }

  /// 从 `(` 开始跳过一对平衡的括号内容，返回 `)` 之后的位置。
  /// 字符串字面量里的括号不参与配对。
  static int _skipBalancedCall(String s, int openParen) {
    var depth = 0;
    var i = openParen;
    String? quote;
    while (i < s.length) {
      final c = s[i];
      if (quote != null) {
        if (c == quote) quote = null;
      } else if (c == "'" || c == '"') {
        quote = c;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) return i + 1;
      }
      i++;
    }
    return i; // 没配对上（残缺源码）——扫到尾
  }

  static bool _isIdentStart(String c) => c == '_' || c == r'$' || _isLetter(c);
  static bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);
  static bool _isLetter(String c) =>
      (c.codeUnitAt(0) >= 0x41 && c.codeUnitAt(0) <= 0x5A) ||
      (c.codeUnitAt(0) >= 0x61 && c.codeUnitAt(0) <= 0x7A);
  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  final double? width;
  final double? height;

  /// `Colors.xxx` / `Color(0xFF...)` 还原出的十六进制串（`#RRGGBB`）。
  ///
  /// 用字符串而不是 `int`：这一层不 import Flutter，保持 model 纯 Dart
  /// （现有测试全是不起 widget 的纯逻辑测试，别把它们拖进 UI 依赖）。
  final String? color;
  final double? radius;
  final double? padding;

  /// `Icons.xxx` 里的 `xxx`（供上层映射成 IconData）。
  final String? iconName;
  final int? elevation;

  /// 提取到了视觉信息 —— 调用方据此决定"按原貌画"还是"退回提示框"。
  bool get hasSomething =>
      width != null ||
      height != null ||
      color != null ||
      radius != null ||
      padding != null ||
      iconName != null ||
      elevation != null;

  /// `width: 100` / `height: 12.5`。
  ///
  /// ⚠️ 必须要求冒号后**直接跟数字**：`width: w` 这类变量要返回 null。
  /// 用 `\b` 卡住左边界，否则 `maxWidth:` 也会被 `width` 匹配上。
  static double? _px(String s, String key) {
    final m =
        RegExp('(?<![A-Za-z])$key:\\s*([0-9]+(?:\\.[0-9]+)?)').firstMatch(s);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null || v <= 0) return null;
    // 上限防护：源码里写 `width: 99999` 会把预览撑爆
    return v > 4000 ? null : v;
  }

  static int? _int(String s, String key) {
    final m = RegExp('(?<![A-Za-z])$key:\\s*([0-9]+)').firstMatch(s);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// 圆角：`BorderRadius.circular(8)` / 别名 `borderRadius: BorderRadius.all(Radius.circular(8))`。
  static double? _radius(String s) {
    final m = RegExp(
            r'(?:BorderRadius|Radius)\.circular\(\s*([0-9]+(?:\.[0-9]+)?)\s*\)')
        .firstMatch(s);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null || v < 0) return null;
    return v > 400 ? null : v;
  }

  /// 内边距：只认 `EdgeInsets.all(N)` / `symmetric(horizontal: N)` /
  /// `only(left: N)` 这类**单值**写法，取其中一个数字当四边统一内边距。
  ///
  /// 多值（`fromLTRB`）不精确还原 —— 但取平均都比"当 0"更接近原貌，
  /// 且我们会在角标里说明是估算。
  static double? _padding(String s) {
    final all =
        RegExp(r'EdgeInsets\.all\(\s*([0-9]+(?:\.[0-9]+)?)\s*\)').firstMatch(s);
    if (all != null) {
      final v = double.tryParse(all.group(1)!);
      if (v != null && v >= 0 && v <= 200) return v;
    }
    // symmetric / only / fromLTRB：取出现的第一个数字
    final anyNum =
        RegExp(r'EdgeInsets\.\w+\([^)]*?([0-9]+(?:\.[0-9]+)?)').firstMatch(s);
    if (anyNum != null) {
      final v = double.tryParse(anyNum.group(1)!);
      if (v != null && v >= 0 && v <= 200) return v;
    }
    return null;
  }

  /// `Colors.blueGrey` / `Color(0xFF3DDC84)` → `#RRGGBB`。
  static String? _color(String s) {
    final hex = RegExp(r'Color\(0x[fF]{2}([0-9a-fA-F]{6})\)').firstMatch(s);
    if (hex != null) return '#${hex.group(1)!.toUpperCase()}';
    final named =
        RegExp(r'Colors\.([a-zA-Z]+)(?:\.shade([0-9]+))?').firstMatch(s);
    if (named == null) return null;
    final base = _materialColors[named.group(1)!.toLowerCase()];
    if (base == null) return null;
    // shade 变体不做精确换算（要真 HSL 计算），只回基色 —— 保守近似，
    // 角标里已声明是"尽力还原"。
    return base;
  }

  /// `Icons.add` → `add`。
  static String? _icon(String s) {
    final m = RegExp(r'Icons\.([a-zA-Z_]+)').firstMatch(s);
    return m?.group(1);
  }

  /// Material 主色表（只用得上基色，shade 不细分）。
  ///
  /// 不引 Flutter 的 `Colors.*` 是因为这一层要能被纯 Dart 测试直接跑。
  static const Map<String, String> _materialColors = <String, String>{
    'red': '#F44336',
    'pink': '#E91E63',
    'purple': '#9C27B0',
    'deeppurple': '#673AB7',
    'indigo': '#3F51B5',
    'blue': '#2196F3',
    'lightblue': '#03A9F4',
    'cyan': '#00BCD4',
    'teal': '#009688',
    'green': '#4CAF50',
    'lightgreen': '#8BC34A',
    'lime': '#CDDC39',
    'yellow': '#FFEB3B',
    'amber': '#FFC107',
    'orange': '#FF9800',
    'deeporange': '#FF5722',
    'brown': '#795548',
    'grey': '#9E9E9E',
    'bluegrey': '#607D8B',
    'black': '#000000',
    'white': '#FFFFFF',
    'transparent': '#00000000',
  };
}
