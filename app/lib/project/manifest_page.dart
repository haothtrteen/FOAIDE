import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/fs_bridge.dart';
import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import 'icon_replacer.dart';
import 'keystore_store.dart';
import 'manifest_codec.dart';
import 'signing.dart';
import 'signing_dialog.dart';
import '../core/theme.dart';

/// 项目工作台 ·「清单」区（alpha.61 重做）。
///
/// 原实现是**只读展示页**：应用名/包名只能看，版本改了要自己滚回顶部点
/// 保存，权限是一串标签，图标/签名/混淆这些"打包前必须确认的事"根本没入口。
/// 用户反馈要的是一个**能真正改配置的地方**。
///
/// 本次重做的几条原则：
/// 1. **只读的就说清为什么只读**。包名（applicationId）一改就会与已装应用
///    冲突、需要卸载重装，所以保持只读，但给一键复制——用户多半是想粘贴
///    到别处（Firebase / 第三方 SDK 后台），复制比编辑更有用。
/// 2. **要改的就必须能存**。应用名（Manifest label）与描述同步改，
///    版本名/版本代码带格式校验 + 降级告警。
/// 3. **保存是一次性的**。底部悬浮按钮汇总"有哪些改动待保存"，
///    不让用户猜自己改没改过。
/// 4. **保存后静默复查**。写完立刻读回校验，失败要能看见，
///    不能"点了没反应"。
///
/// 所有字符串变换都在 [ManifestCodec] 里（纯函数、有单测），
/// 本文件只负责 IO 与界面。
class ManifestPage extends StatefulWidget {
  /// 项目名（用于拼容器内路径）。
  final String projectName;

  /// 读取/写入项目文件。
  final FsBridge bridge;

  /// 在编辑器中打开某个文件（相对项目根）。
  final void Function(String rel) onOpenFile;

  /// 顶部 AppBar 的保存按钮与底部悬浮按钮要共享保存状态，
  /// 由父页持有回调，这里通过 controller 反向驱动。
  final ManifestPageController controller;

  const ManifestPage({
    super.key,
    required this.projectName,
    required this.bridge,
    required this.onOpenFile,
    required this.controller,
  });

  @override
  State<ManifestPage> createState() => ManifestPageState();
}

/// 让父页（AppBar 保存按钮 / 分区切换）能读到清单页的状态。
class ManifestPageController extends ChangeNotifier {
  bool dirty = false;
  bool saving = false;

  void update({required bool dirty, required bool saving}) {
    if (this.dirty == dirty && this.saving == saving) return;
    this.dirty = dirty;
    this.saving = saving;
    notifyListeners();
  }
}

class ManifestPageState extends State<ManifestPage> {
  final FsBridge _fb = FsBridge();

  // ---- 磁盘上的原值（用于算 dirty / 回滚） ----
  ManifestState _disk = ManifestState();

  // ---- 界面上的当前值 ----
  late final TextEditingController _nameCtl;
  late final TextEditingController _descCtl;

  /// 应用包名（applicationId）。alpha.74 起**可编辑** ——
  /// 之前是只读的，理由是"装机后不可改"。但那是**运行时**的限制：
  /// 还没发布的工程、或者内部测试包，改包名是完全正常的操作
  /// （换个渠道名、把 `com.example.xxx` 改成公司域名）。一刀切成只读，
  /// 用户只能自己去编辑器里翻 build.gradle。
  ///
  /// 风险照旧要讲清楚，但不拦着 —— 见包名卡片里那段提示。
  late final TextEditingController _pkgCtl;
  late final TextEditingController _verNameCtl;
  late final TextEditingController _verCodeCtl;

  bool _loading = true;
  String _loadError = '';
  bool _saving = false;

  /// 权限勾选态（切换后不立即写盘，等用户点保存）。
  final Set<String> _permChecked = {};

  /// Manifest 里当前实际存在的权限全集（勾选列表的数据源）。
  final Set<String> _permExisting = {};

  /// 图标文件的当前状态（相对项目根的路径）。
  String _iconPath = '';
  String _iconNote = '';

  /// alpha.95：图标真实内容的预览字节。
  ///
  /// 之前那一格写死 `Icons.flutter_dash`，换完图标预览照旧 —— 真机反馈
  /// "导入自定义图标但是界面预览没变"。现在真去读那个 PNG（容器 base64），
  /// 读不到才回落默认图标。
  Uint8List? _iconBytes;

  /// alpha.93：图标替换的进行中与结果（替换是秒级但也走容器，给反馈）。
  bool _iconBusy = false;
  String? _iconResult;
  bool _iconOk = false;

  /// 签名配置是否存在（只看文件在不在）。
  bool _hasSigning = false;

  /// alpha.93：key.properties 的**实际内容**（不在就 null）。
  ///
  /// 光知道"文件存在"不够——要看 keystore 路径/别名/口令是否齐全，
  /// 缺一项的话"验签""重签"这些按钮点了也是白点。
  SigningConfig? _signCfg;

  /// 签名操作进行中 / 结果。
  bool _signBusy = false;
  String? _signResult;
  bool _signOk = true;

  /// alpha.94：签名库（容器里登记过的全部 keystore）。
  ///
  /// 与 `_signCfg` 是两件事：这里是"我有哪些钥匙"，那里是
  /// "这个工程现在用哪把"。
  List<KeystoreEntry> _store = const <KeystoreEntry>[];

  /// alpha.96：这个工程的 build.gradle.kts 里还留着**会编译失败的**老写法。
  ///
  /// 背景：`plugins {}` 会遮蔽 `java` 标识符，所以
  /// `java.util.Properties()` 全限定名报 `Unresolved reference 'util'`。
  /// alpha.94 修好了补丁生成器，但**已经打过旧补丁的工程不会自动回写** ——
  /// 用户反复构建、反复报同一个错，而 FOA 这边看起来"早就修了"。
  ///
  /// 这里在打开清单页时就检测一次，检测到就把修复按钮显示出来。
  bool _hasLegacyGradle = false;

  /// 混淆开关（读自 build.gradle）。
  bool _minify = true;

  /// gradle 里**是否显式**写了 `minifyEnabled`。
  ///
  /// 官方模板的 `release {}` 里没有这一行（见
  /// [ManifestCodec.setMinify] 的注释），此时 [\_minify] 是 AGP 的
  /// 默认值 true。UI 分开措辞：显式写了就说"现在是开/关"，
  /// 没写就说"没写这一行（AGP 默认开）"—— 后者用户才会明白
  /// 为什么自己点关闭之后文件里会多出一行。
  bool _minifyExplicit = false;

  /// 上次保存的结果提示（成功/失败都留在界面上，用户不用翻 SnackBar）。
  String _saveNote = '';
  bool _saveOk = true;

  /// 可勾选的常用权限（超出这些的权限走"在 Manifest 里手动加"）。
  static const List<({String name, String short, String why})> _commonPerms = [
    (name: 'android.permission.INTERNET', short: '联网', why: '访问网络（几乎所有应用都需要）'),
    (
      name: 'android.permission.ACCESS_NETWORK_STATE',
      short: '网络状态',
      why: '判断当前是否联网/是否 WiFi'
    ),
    (name: 'android.permission.CAMERA', short: '相机', why: '拍照、扫码'),
    (name: 'android.permission.RECORD_AUDIO', short: '录音', why: '语音输入、通话'),
    (
      name: 'android.permission.READ_EXTERNAL_STORAGE',
      short: '读存储',
      why: '读取用户文件（Android 12 及以下）'
    ),
    (
      name: 'android.permission.WRITE_EXTERNAL_STORAGE',
      short: '写存储',
      why: '写入用户文件（Android 10 及以下）'
    ),
    (
      name: 'android.permission.READ_MEDIA_IMAGES',
      short: '读图片',
      why: '读取相册（Android 13+）'
    ),
    (
      name: 'android.permission.ACCESS_FINE_LOCATION',
      short: '精确定位',
      why: '地图导航、附近服务'
    ),
    (
      name: 'android.permission.POST_NOTIFICATIONS',
      short: '发通知',
      why: '推送通知（Android 13+ 需显式申请）'
    ),
    (name: 'android.permission.VIBRATE', short: '振动', why: '消息提醒振动'),
  ];

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController();
    _descCtl = TextEditingController();
    _pkgCtl = TextEditingController();
    _verNameCtl = TextEditingController();
    _verCodeCtl = TextEditingController();
    _nameCtl.addListener(_markDirty);
    _descCtl.addListener(_markDirty);
    _pkgCtl.addListener(_markDirty);
    _verNameCtl.addListener(_markDirty);
    _verCodeCtl.addListener(_markDirty);
    _load();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _descCtl.dispose();
    _pkgCtl.dispose();
    _verNameCtl.dispose();
    _verCodeCtl.dispose();
    super.dispose();
  }

  String _p(String rel) => '/root/projects/${widget.projectName}/$rel';

  /// 图标缩略图：优先显示**真实文件内容**，拿不到才回落 Flutter 图标。
  ///
  /// alpha.95 之前这里写死 `Icons.flutter_dash`，所以换完图标预览不改，
  /// 用户合理怀疑"替换没生效"。现在读的是容器里的那个 PNG。
  Widget _iconThumb() {
    final bytes = _iconBytes;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: const Color(0xFF173F35),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: bytes == null
          ? const Icon(Icons.flutter_dash, color: Color(0xFF3DDC84), size: 30)
          : Image.memory(
              bytes,
              width: 56,
              height: 56,
              fit: BoxFit.cover,
              // 文件在但解不出来（比如根本不是 PNG）时也要有东西显示，
              // 不能抛异常把整张卡片带下去。
              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                  color: Color(0xFF3DDC84), size: 26),
            ),
    );
  }

  static const _pubRel = 'pubspec.yaml';
  static const _mfRel = 'android/app/src/main/AndroidManifest.xml';
  static const _gradleRel = 'android/app/build.gradle';

  /// alpha.96：老式签名补丁的说明文案。
  ///
  /// 抽成常量是为了避开一个 lint 自相矛盾：
  /// 直接写在 `Text(...)` 里时，`prefer_const_constructors` 建议加 `const`，
  /// 但加了又报 `unnecessary_const`（因为那串是相邻字面量拼接，
  /// 编译器已视为常量）。抽出来当参数引用，两个 lint 都不再响。
  static const String _kLegacyGradleNote =
      '这个工程的 build.gradle.kts 里用了 `java.util.Properties()` '
      '这种全限定写法。Kotlin DSL 里只要文件开头有 `plugins {}` 块，'
      '`java` 这个标识符就会被遮蔽，构建时必然报：\n'
      '  Unresolved reference: util / io\n\n'
      '这是旧版本打签名补丁留下的，FOA 已修复生成逻辑，'
      '但已生成的工程不会自动改写——点下面按钮修一下就好，'
      '不会动你的密钥。';

  /// Gradle 清单文件的**实际路径**（Bug 470）。
  ///
  /// Flutter 新版模板生成的是 `android/app/build.gradle.kts`，
  /// 而旧代码读写不对称：读的时候遍历 `[_gradleRel, _gradleRel + '.kts']`
  /// 两个候选，写的时候却只用写死的 `_gradleRel` → 在 .kts 工程上
  /// 保存时报「读取失败：不是文件 …/build.gradle」。
  ///
  /// 现在统一走这里：读时探测并**记住**命中哪个，写时复用同一个。
  /// 两个都不存在时返回 null，由调用方给出明确文案（而不是抛"不是文件"）。
  String? _gradleActual;

  static const List<String> _gradleCandidates = [
    _gradleRel,
    'android/app/build.gradle.kts',
  ];

  // ============================ 读 ============================

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = '';
    });
    try {
      var pubName = widget.projectName;
      var description = '';
      var verName = '1.0.0';
      var verCode = '1';
      var label = '';
      var appId = '';
      var minify = true;
      // gradle 里到底有没有显式写 minifyEnabled —— 影响 UI 的措辞
      // （"现在是开" vs "没写这一行、AGP 默认开"）。
      var minifyExplicit = false;
      final perms = <String>{};

      final pub = await _fb.read(_p(_pubRel));
      if (pub.ok) {
        final r = ManifestCodec.parsePubspec(pub.content);
        // pubspec 没写 name 时退回项目名（新建项目模板可能缺字段）
        pubName = r.name.isEmpty ? widget.projectName : r.name;
        description = r.description;
        verName = r.verName;
        verCode = r.verCode;
      }

      // 清单：兼容 android/app/build.gradle 与 .kts 两种
      final mf = await _fb.read(_p(_mfRel));
      if (mf.ok) {
        final r = ManifestCodec.parseManifest(mf.content);
        label = r.label;
        perms.addAll(r.permissions);
      }

      // Gradle 清单：兼容 android/app/build.gradle 与 .kts 两种（Bug 470：
      // 探测结果必须**记住**，否则写回时会写到不存在的那一个）
      _gradleActual = null;
      _hasLegacyGradle = false;
      for (final f in _gradleCandidates) {
        final g = await _fb.read(_p(f));
        if (!g.ok) continue;
        _gradleActual = f; // 命中即记住，写回复用
        final r = ManifestCodec.parseGradle(g.content);
        if (r.appId.isNotEmpty) appId = r.appId;
        minify = r.minify;
        minifyExplicit = r.minifyExplicit;
        // alpha.96：老式签名补丁里写着 `java.util.Properties()`，
        // 在 `plugins {}` 存在时**编译必挂**（Unresolved reference 'util'）。
        // 这里顺手检测，检测到就在签名卡上给修复入口。
        if (f.endsWith('.kts')) {
          _hasLegacyGradle = Signing.hasLegacyJavaFqn(g.content);
        }
      }

      // 签名配置探测（alpha.93：除了"在不在"，还要解析出 keystore 与口令，
      // 否则打包区的验签/重签没法用）
      _hasSigning = false;
      _signCfg = null;
      for (final f in const [
        'android/key.properties',
        'android/app/key.properties',
      ]) {
        final s = await _fb.read(_p(f));
        if (!s.ok) continue;
        _hasSigning = true;
        _signCfg = Signing.configFrom(s.content);
        break;
      }

      // alpha.94：签名库。读失败就当空表（容器没装好时 exec 会抛，
      // 不能让整页白屏——签名只是这一张卡的事）。
      try {
        _store = await KeystoreStore(ProotBridge()).load();
      } catch (_) {
        _store = const <KeystoreEntry>[];
      }

      // 图标探测：列 launcher 资源目录，找 ic_launcher
      _iconPath = '';
      _iconNote = '使用 Flutter 默认图标';
      for (final dir in const [
        'android/app/src/main/res/mipmap-xxxhdpi',
        'android/app/src/main/res/mipmap-xxhdpi',
        'android/app/src/main/res/mipmap-xhdpi',
        'android/app/src/main/res/mipmap-hdpi',
        'android/app/src/main/res/mipmap-mdpi',
        'android/app/src/main/res/drawable',
      ]) {
        final ls = await _fb.list(_p(dir));
        if (!ls.ok) continue;
        for (final e in ls.entries) {
          if (e.name.startsWith('ic_launcher') && e.name.endsWith('.png')) {
            _iconPath = '$dir/${e.name}';
            break;
          }
        }
        if (_iconPath.isNotEmpty) break;
      }
      if (_iconPath.isNotEmpty) {
        _iconNote = _iconPath.startsWith('android/app/src/main/res/mipmap')
            ? '已替换为自定义图标'
            : '图标在 drawable 目录（非常规位置）';
      }
      // 读真实图标内容用于预览。失败就 null（回落 Flutter 图标）——
      // 预览读不到不该挡住整张卡片。
      _iconBytes = _iconPath.isEmpty
          ? null
          : await IconReplacer.readAsBytes(ProotBridge(), _p(_iconPath));

      if (!mounted) return;
      _disk = ManifestState(
        pubName: pubName,
        description: description,
        label: label,
        appId: appId,
        versionName: verName,
        versionCode: verCode,
        permissions: perms.toList(),
        minify: minify,
      );
      _nameCtl.text = label;
      _descCtl.text = description;
      _pkgCtl.text = appId;
      _verNameCtl.text = verName;
      _verCodeCtl.text = verCode;
      _permExisting
        ..clear()
        ..addAll(perms);
      _permChecked.clear();
      _minify = minify;
      _minifyExplicit = minifyExplicit;
      setState(() {
        _loading = false;
        _saveNote = '';
      });
      _pushDirty();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '读取清单失败：$e';
      });
    }
  }

  // ============================ 脏检查 ============================

  /// 当前界面态与磁盘态的差异。
  ///
  /// 权限单独算：`_permChecked` 只存"本次要新增的"，
  /// 取消勾选已存在的权限也要能识别出来。
  ({
    bool name,
    bool desc,
    bool pkg,
    bool verName,
    bool verCode,
    bool perms,
    bool minify,
  }) _diff() {
    final name = _nameCtl.text.trim() != _disk.label;
    final desc = _descCtl.text.trim() != _disk.description;
    final vn = _verNameCtl.text.trim() != _disk.versionName;
    final vc = _verCodeCtl.text.trim() != _disk.versionCode;
    final perms = !_setEquals(_permChecked, _uncheckedExisting());
    return (
      name: name,
      desc: desc,
      pkg: _pkgCtl.text.trim() != _disk.appId,
      verName: vn,
      verCode: vc,
      perms: perms,
      minify: _minify != _disk.minify,
    );
  }

  /// 已被用户**取消勾选**的原有权限（要从 Manifest 里删掉的）。
  Set<String> _uncheckedExisting() => _permExisting
      .where(
          (p) => !_permChecked.contains(p) && !_permChecked.contains(_short(p)))
      .toSet();

  /// 勾选集合统一存**短名或全名**都可能，这里统一成全名比较。
  Set<String> _normalizedChecked() => _permChecked
      .map((s) => s.contains('.') ? s : _fullName(s))
      .whereType<String>()
      .toSet();

  static String? _fullName(String short) {
    for (final p in _commonPerms) {
      if (p.short == short) return p.name;
    }
    return null;
  }

  static String _short(String full) => full.split('.').last;

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  bool _anyDirty() {
    final d = _diff();
    return d.name ||
        d.desc ||
        d.pkg ||
        d.verName ||
        d.verCode ||
        d.perms ||
        d.minify;
  }

  void _markDirty() {
    if (_loading) return;
    if (mounted) setState(() {});
    _pushDirty();
  }

  void _pushDirty() {
    widget.controller.update(dirty: _anyDirty(), saving: _saving);
  }

  // ============================ 写 ============================

  /// 保存：把界面态写回 pubspec / Manifest / build.gradle。
  ///
  /// 逐文件检查——**任何一个失败都不静默**。多处写入无法做到真正原子，
  /// 所以按"影响面从小到大"的顺序写：先 pubspec（版本/描述），
  /// 再 Manifest（名称/权限），最后 gradle（混淆）。
  Future<void> save() async {
    if (_saving) return;
    final d = _diff();
    if (!d.name &&
        !d.desc &&
        !d.verName &&
        !d.verCode &&
        !d.perms &&
        !d.minify &&
        !d.pkg) {
      _note('没有需要保存的改动', ok: true);
      return;
    }
    // 新包名（界面上的值，已 trim）。
    final newPkg = _pkgCtl.text.trim();
    // 这一次保存**新插入**了 minifyEnabled 行 —— 影响成功提示的措辞。
    var insertedMinify = false;

    // ---------- 校验（先全部校验完再动盘，避免写一半发现格式错） ----------
    final label = _nameCtl.text.trim();
    if (d.name && !ManifestCodec.validLabel(label)) {
      _note('应用名不能为空，且不超过 80 字', ok: false);
      return;
    }
    if (d.pkg && !ManifestCodec.validAppId(newPkg)) {
      _note(
        '包名格式不对：要像 com.example.myapp 这样，'
        '每段以字母开头、只含字母数字下划线，至少两段。'
        '（大写字母和中文都不能用）',
        ok: false,
      );
      return;
    }
    final vn = _verNameCtl.text.trim();
    if ((d.verName) && !ManifestCodec.validVersionName(vn)) {
      _note('版本名格式应为 x.y.z（如 1.0.0）', ok: false);
      return;
    }
    final vc = _verCodeCtl.text.trim();
    if ((d.verCode) && !ManifestCodec.validVersionCode(vc)) {
      _note('版本代码必须是纯整数（Android 只认整数）', ok: false);
      return;
    }
    // 降级提醒：版本名变小了，应用商店会拒收
    if (d.verName &&
        ManifestCodec.versionNameDowngrade(_disk.versionName, vn)) {
      final go = await _confirm(
        '版本名降级',
        '从 ${_disk.versionName} 降到 $vn。\n\n'
            '应用商店会拒绝版本号变小的包，且已安装用户无法升级。'
            '如果只是本地测试可以继续。',
      );
      if (!go) return;
    }

    setState(() => _saving = true);
    _pushDirty();

    final done = <String>[];
    final failed = <String>[];

    // ---------- 1. pubspec（描述 / 版本） ----------
    if (d.desc || d.verName || d.verCode) {
      final r = await _fb.read(_p(_pubRel));
      if (!r.ok) {
        failed.add('pubspec.yaml（读取失败：${r.error}）');
      } else {
        var t = r.content;
        if (d.desc) {
          t = ManifestCodec.setDescription(t, _descCtl.text.trim());
        }
        if (d.verName || d.verCode) {
          t = ManifestCodec.setVersion(
              t, vn, d.verCode ? vc : _disk.versionCode);
        }
        final w = await _fb.write(_p(_pubRel), t);
        if (w.ok) {
          done.add('pubspec.yaml');
        } else {
          failed.add('pubspec.yaml（${w.error}）');
        }
      }
    }

    // ---------- 2. AndroidManifest（应用名 / 权限 / 老式包名） ----------
    if (d.name || d.perms || d.pkg) {
      final r = await _fb.read(_p(_mfRel));
      if (!r.ok) {
        failed.add('AndroidManifest.xml（读取失败：${r.error}）');
      } else {
        var t = r.content;
        if (d.name) t = ManifestCodec.setLabel(t, label);
        // AGP 8 起 Manifest 里没有 `package="..."` 了（包名由 gradle 的
        // `namespace` 决定）。老工程才有 —— 有就跟着改，没有就跳过。
        if (d.pkg) {
          final mp = ManifestCodec.setManifestPackage(t, newPkg);
          t = mp.code;
        }
        if (d.perms) {
          t = ManifestCodec.applyPermissions(
            t,
            toAdd: _normalizedChecked(),
            toRemove: _uncheckedExisting(),
          );
        }
        final w = await _fb.write(_p(_mfRel), t);
        if (w.ok) {
          done.add('AndroidManifest.xml');
        } else {
          failed.add('AndroidManifest.xml（${w.error}）');
        }
      }
    }

    // ---------- 3. 构建选项：gradle 的包名 / 混淆开关（Bug 470） ----------
    // 用读阶段探测到的实际路径（.gradle 或 .gradle.kts），
    // 不再写死 `_gradleRel` —— 否则 .kts 工程会报「不是文件」。
    if (d.minify || d.pkg) {
      if (_gradleActual == null) {
        failed.add('构建选项（工程内没有 android/app/build.gradle(.kts)，'
            '无法写入${d.pkg ? "包名与" : ""}混淆开关）');
      } else {
        final label =
            _gradleActual == _gradleRel ? 'build.gradle' : 'build.gradle.kts';
        final r = await _fb.read(_p(_gradleActual!));
        if (!r.ok) {
          failed.add('$label（读取失败：${r.error}）');
        } else {
          var before = r.content;
          var touched = false;
          // 3a. 包名：namespace 与 applicationId 一起改。
          //
          // ⚠️ 顺序**必须先包名后混淆** —— 两次都是全字符串替换，
          // 但包名那次用 `replaceFirstMapped` 前后加了内容，
          // 先做谁其实等价；放在前面只是为了让"哪一步失败"更好归因。
          if (d.pkg) {
            final ap = ManifestCodec.setAppId(before, newPkg);
            if (!ap.changed) {
              failed.add('$label（没找到 namespace / applicationId，'
                  '无法写入包名）');
            } else {
              before = ap.code;
              touched = true;
            }
          }
          // 3b. 混淆开关。
          if (d.minify) {
            final mn = ManifestCodec.setMinify(before, _minify);
            if (mn.code == before) {
              // 连 buildTypes 都没有 —— 这种 gradle 我们不敢动结构。
              failed.add('$label（没找到 buildTypes / release 块，'
                  '无法写入混淆开关）');
            } else {
              if (mn.inserted) {
                insertedMinify = true;
              }
              before = mn.code;
              touched = true;
            }
          }
          if (!touched) {
            // 一步都没写成（失败项已经进 failed 了），别写回原内容。
          } else {
            final w = await _fb.write(_p(_gradleActual!), before);
            if (w.ok) {
              done.add(label);
            } else {
              failed.add('$label（${w.error}）');
            }
          }
        }
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);

    if (failed.isEmpty) {
      // 新插了一行 minifyEnabled 的话要**说出来**。用户点的是"关闭混淆"，
      // 结果文件里凭空多了一行 —— 不解释他会怀疑工具乱改了他的 gradle。
      final extra = insertedMinify
          ? '（build.gradle 里原本没有 minifyEnabled 这一行，'
              '已写进 buildTypes.release）'
          : '';
      _note('已保存：${done.join('、')}$extra', ok: true);
      // 静默复查：重新读一遍，确认磁盘上真的是新值（而不是自己以为写成了）
      await _verify();
    } else {
      _note('保存未完成：${failed.join('；')}', ok: false);
    }
    _pushDirty();
  }

  /// 保存后复查：重读三个文件，把磁盘真实值刷回界面。
  ///
  /// 这一步不是"再写一遍"，而是**信任磁盘**——如果文件被别的进程
  /// （终端里的 vim、AI 接管、git checkout）改过，这里能立刻反映出来。
  Future<void> _verify() async {
    await _load();
    if (!mounted) return;
    final d = _diff();
    if (d.name || d.desc || d.verName || d.verCode || d.perms || d.minify) {
      _note('写入后校验发现内容不一致，请检查文件权限或是否有其它进程在改这个项目', ok: false);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body, style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('仍要保存'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  void _note(String msg, {required bool ok}) {
    if (!mounted) return;
    setState(() {
      _saveNote = msg;
      _saveOk = ok;
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _copy(String label, String value) async {
    if (value.isEmpty) {
      _toast('$label为空，无可复制内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    _toast('已复制$label');
  }

  /// 放弃改动，回到磁盘值。
  void revert() {
    _nameCtl.text = _disk.label;
    _descCtl.text = _disk.description;
    _verNameCtl.text = _disk.versionName;
    _verCodeCtl.text = _disk.versionCode;
    _permChecked.clear();
    _minify = _disk.minify;
    setState(() => _saveNote = '');
    _pushDirty();
  }

  // ============================ 界面 ============================

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 40, color: Color(0xFFFF7A7A)),
              const SizedBox(height: 12),
              Text(_loadError, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final d = _diff();
    final dirty = _anyDirty();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          ListView(
            // 底部留出悬浮保存按钮的高度，否则最后一张卡被挡住
            padding: EdgeInsets.fromLTRB(16, 16, 16, dirty ? 96 : 24),
            children: [
              _identityCard(d),
              const SizedBox(height: 12),
              _versionCard(d),
              const SizedBox(height: 12),
              _permissionCard(d),
              const SizedBox(height: 12),
              _iconCard(),
              const SizedBox(height: 12),
              _signingCard(),
              const SizedBox(height: 12),
              _advancedCard(d),
              if (_saveNote.isNotEmpty) ...[
                const SizedBox(height: 12),
                _noteCard(),
              ],
            ],
          ),
          if (dirty) _saveBar(),
        ],
      ),
    );
  }

  /// 悬浮保存条：只在有改动时出现，汇总改了什么。
  Widget _saveBar() {
    final changed = <String>[];
    final d = _diff();
    if (d.name) changed.add('应用名');
    if (d.desc) changed.add('描述');
    if (d.verName) changed.add('版本名');
    if (d.verCode) changed.add('版本代码');
    if (d.perms) changed.add('权限');
    if (d.minify) changed.add('混淆');

    return Positioned(
      left: 12,
      right: 12,
      bottom: 12,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF1D2530),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('待保存：${changed.join('、')}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const Text('改动会写入项目文件，构建时生效',
                        style: TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
              ),
              TextButton(
                onPressed: _saving ? null : revert,
                child: const Text('放弃', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: _saving ? null : save,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save_outlined, size: 16),
                label: Text(_saving ? '保存中' : '保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noteCard() {
    final c = _saveOk ? const Color(0xFF3DDC84) : const Color(0xFFFF7A7A);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_saveOk ? Icons.check_circle_outline : Icons.error_outline,
                size: 18, color: c),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText(
                _saveNote,
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => setState(() => _saveNote = ''),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 卡片 1：身份（应用名 / 包名） ----------

  Widget _identityCard(dynamic d) {
    return _card(
      icon: Icons.badge_outlined,
      title: '应用身份',
      subtitle: '桌面显示的名字，以及应用的唯一标识',
      children: [
        _label('应用名（android:label）', hint: '显示在桌面图标下方，可随时修改'),
        TextField(
          controller: _nameCtl,
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            hintText: '我的应用',
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: _nameCtl.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空',
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () => _nameCtl.clear(),
                  ),
          ),
        ),
        if (d.name) _hint('原名：${_disk.label.isEmpty ? "（未设置）" : _disk.label}'),
        const SizedBox(height: 18),
        _label('应用包名（applicationId）', hint: '唯一标识，装机后不可更换（未发布前可以随便改）'),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pkgCtl,
                style: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  height: 1.3,
                ),
                decoration: InputDecoration(
                  hintText: 'com.example.myapp',
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _pkgCtl.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '恢复为磁盘上的包名',
                          icon: const Icon(Icons.settings_backup_restore,
                              size: 18),
                          onPressed: () {
                            _pkgCtl.text = _disk.appId;
                            _markDirty();
                          },
                        ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '复制包名',
              onPressed: () => _copy('包名', _pkgCtl.text.trim()),
              icon: const Icon(Icons.copy, size: 18),
            ),
          ],
        ),
        if (d.pkg && !ManifestCodec.validAppId(_pkgCtl.text.trim()))
          _hint(
            '格式不对：要像 com.example.myapp 这样，至少两段，'
            '每段以字母开头（首段），只含字母数字下划线。',
            warn: true,
          ),
        if (d.pkg)
          _hint(
            '原包名：'
            '${_disk.appId.isEmpty ? "（未找到）" : _disk.appId}'
            '  ·  保存后会同时改 build.gradle 的 namespace 与 applicationId。',
          ),
        _hint(
          '改包名会发生什么：Android 把包名当应用的"身份证"——'
          '已装过旧包名的手机装不上（系统当它是另一个应用），'
          '第三方 SDK（推送/统计/支付）后台登记的包名也要跟着改。'
          '还没发布过、或者只是内部测试包，随便改。',
          warn: d.pkg,
        ),
        if (d.pkg)
          _hint(
            'Kotlin 源码目录（android/app/src/main/kotlin/...）不会跟着搬 —— '
            '这不影响编译，AGP 允许 Kotlin 的 package 声明与 namespace 不一致。',
          ),
      ],
    );
  }

  // ---------- 卡片 2：版本 ----------

  Widget _versionCard(dynamic d) {
    final vnOk = ManifestCodec.validVersionName(_verNameCtl.text.trim());
    final vcOk = ManifestCodec.validVersionCode(_verCodeCtl.text.trim());
    final downgrade = d.verName &&
        ManifestCodec.validVersionName(_verNameCtl.text.trim()) &&
        ManifestCodec.versionNameDowngrade(
            _disk.versionName, _verNameCtl.text.trim());

    return _card(
      icon: Icons.tag_outlined,
      title: '版本',
      subtitle: '每次发布上架，版本代码必须比上一版大',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('版本名', hint: '给用户看的，如 1.2.0'),
                  TextField(
                    controller: _verNameCtl,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: '1.0.0',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      errorText: _verNameCtl.text.trim().isEmpty || vnOk
                          ? null
                          : '格式应为 x.y.z',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('版本代码', hint: '给系统看的，纯整数'),
                  TextField(
                    controller: _verCodeCtl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: '1',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      errorText: _verCodeCtl.text.trim().isEmpty || vcOk
                          ? null
                          : '必须是整数',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (downgrade)
          _hint('⚠️ 版本名比当前（${_disk.versionName}）小，应用商店会拒绝上架', warn: true),
        if (d.verCode) _hint('当前磁盘上的版本代码：${_disk.versionCode}'),
      ],
    );
  }

  // ---------- 卡片 3：权限 ----------

  Widget _permissionCard(dynamic d) {
    // 实际生效的权限 = 勾选中的 ∪ (原有 - 取消的)
    final unchecked = _uncheckedExisting();
    final effective = <String>{
      ..._normalizedChecked(),
      ..._permExisting.where((p) => !unchecked.contains(p)),
    };
    final extra = _permExisting
        .where((p) => !_normalizedChecked().contains(p))
        .where((p) => !_commonPerms.any((c) => c.name == p))
        .toList();

    return _card(
      icon: Icons.verified_user_outlined,
      title: '权限',
      subtitle: '已在清单声明 ${effective.length} 项（勾选即声明，取消即移除）',
      children: [
        for (final p in _commonPerms)
          _permTile(
            full: p.name,
            short: p.short,
            why: p.why,
            checked: effective.contains(p.name),
            existed: _permExisting.contains(p.name),
          ),
        if (extra.isNotEmpty) ...[
          const Divider(height: 24),
          const Text('项目已有的其它权限',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          for (final p in extra)
            _permTile(
              full: p,
              short: _short(p),
              why: '由项目自身声明',
              checked: !unchecked.contains(p),
              existed: true,
            ),
        ],
        const SizedBox(height: 10),
        _hint('权限勾选后需保存并重新打包才会生效。Android 13+ 的通知、'
            'Android 12+ 的蓝牙等权限还需要在代码里运行时申请。'),
      ],
    );
  }

  Widget _permTile({
    required String full,
    required String short,
    required String why,
    required bool checked,
    required bool existed,
  }) {
    return InkWell(
      onTap: () => setState(() {
        if (checked) {
          _permChecked.remove(full);
          // 记录"要移除"，用空串占位不行——统一用 unchecked 集合推导，
          // 这里只需保证 checked 状态反映到 _permChecked 的差集语义上
          if (existed) _permChecked.remove(short);
        } else {
          _permChecked.add(full);
        }
        _pushDirty();
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Checkbox(
              value: checked,
              onChanged: (_) => setState(() {
                if (checked) {
                  _permChecked.remove(full);
                  if (existed) _permChecked.remove(short);
                } else {
                  _permChecked.add(full);
                }
                _pushDirty();
              }),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(short,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                      if (existed) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF4C8DFF).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('已声明',
                              style: TextStyle(
                                  fontSize: 9, color: Color(0xFF4C8DFF))),
                        ),
                      ],
                    ],
                  ),
                  Text('$why · $full',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 卡片 4：图标 ----------

  Widget _iconCard() {
    final hasIcon = _iconPath.isNotEmpty;
    return _card(
      icon: Icons.image_outlined,
      title: '应用图标',
      subtitle: _iconNote,
      children: [
        Row(
          children: [
            // ⚠️ alpha.95 修：这里原来写死 `Icons.flutter_dash`，
            // 于是**换完图标预览照旧是 Flutter 默认图标**，用户以为没生效。
            // 真机反馈原话："导入自定义图标但是界面预览没变"。
            //
            // 现在真去显示那个 PNG。走的是容器 base64（FsBridge 只走文本），
            // 拿不到就回落 Flutter 图标（宁可显示默认，也不能显示一个
            // 和真实文件无关的假预览）。
            _iconThumb(),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(hasIcon ? '已找到图标资源' : '当前使用 Flutter 默认图标',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    hasIcon ? _iconPath : '替换后需重新打包才会生效',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                // alpha.93：真正的替换入口。以前这里只有"在编辑器中打开"
                // + 一句"把 png 覆盖到 mipmap-*"的提示——用户看完提示还得
                // 自己去文件管理器里操作，等于没做。
                onPressed: _iconBusy ? null : _replaceIcon,
                icon: _iconBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_file, size: 16),
                label: Text(_iconBusy ? '替换中…' : '选择图片替换',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => widget.onOpenFile(
                    _iconPath.isEmpty ? 'android/app/src/main/res' : _iconPath),
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('在编辑器中打开', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        if (_iconResult != null) ...[
          const SizedBox(height: 8),
          Text(
            _iconResult!,
            style: TextStyle(
              fontSize: 11,
              color: _iconOk
                  ? FoaColors.of(context).success
                  : FoaColors.of(context).danger,
            ),
          ),
        ],
        _hint('选一张方形 PNG，建议 ${IconReplacer.recommendedSize}×'
            '${IconReplacer.recommendedSize} 或更大。'
            '容器里有 imagemagick / Pillow 时会按密度生成精确尺寸；'
            '没有则各密度目录放同一张图，由系统按屏幕密度缩放——'
            '能用，但原图太小会在高密度屏上发虚。'
            '替换后需重新打包才会生效。'
            '（在电脑上正规做法是在 pubspec 里配 flutter_launcher_icons '
            '然后跑一次生成；手机上没法跑那个包，这里是用容器里的'
            'imagemagick / Pillow 做等价的事。）'),
      ],
    );
  }

  /// 选择图片并替换项目图标。
  Future<void> _replaceIcon() async {
    setState(() {
      _iconBusy = true;
      _iconResult = null;
    });
    try {
      // SAF 选文件 → 原生侧已复制到容器 /root/imports/
      final picked = await FileBrowserBridge().pickImport();
      if (!picked.ok || picked.path == null) {
        if (mounted) {
          setState(() {
            _iconBusy = false;
            _iconOk = false;
            _iconResult = picked.error ?? '未选择文件';
          });
        }
        return;
      }
      final r = await IconReplacer.apply(
        ProotBridge(),
        widget.projectName,
        picked.path!,
      );
      if (!mounted) return;
      setState(() {
        _iconBusy = false;
        _iconOk = r.ok;
        _iconResult = r.msg;
      });
      if (r.ok) await _load(); // 重读，让"已找到图标资源"状态跟上
    } catch (e) {
      if (mounted) {
        setState(() {
          _iconBusy = false;
          _iconOk = false;
          _iconResult = '替换失败：$e';
        });
      }
    }
  }

  // ---------- 卡片 5：签名 ----------

  Widget _signingCard() {
    final cfg = _signCfg;
    // 三态：读不出内容（有文件但缺项）/ 已配好 / 没配。
    // 分开是因为"文件在但缺项"最容易让人以为配好了——按已配处理的话
    // 构建会在 gradle 里炸，而报错信息根本不会提到 key.properties。
    final broken = _hasSigning && cfg == null;
    final ok = cfg != null;
    final color = ok
        ? const Color(0xFF3DDC84)
        : (broken ? FoaColors.of(context).danger : const Color(0xFFFFB74D));
    return _card(
      icon: Icons.key_outlined,
      title: '正式签名',
      subtitle: ok
          ? '已配置：release 构建用正式密钥'
          : (broken ? 'key.properties 内容不完整' : '未配置：当前用 debug 签名'),
      children: [
        // alpha.96：构建脚本里还留着**会让 gradle 编译失败**的老写法。
        // 这块要显眼且可操作 —— 用户现在大概率就是被这个挡住构建的。
        if (_hasLegacyGradle) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: FoaColors.of(context).danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: FoaColors.of(context).danger.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.build_circle_outlined,
                        size: 18, color: FoaColors.of(context).danger),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '构建脚本需要修复',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: FoaColors.of(context).danger,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  _kLegacyGradleNote,
                  style: TextStyle(fontSize: 11.5, height: 1.5),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _signBusy ? null : _repairGradle,
                    icon: const Icon(Icons.healing_outlined, size: 16),
                    label: const Text('修复构建脚本',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                ok
                    ? Icons.verified_outlined
                    : (broken ? Icons.error_outline : Icons.info_outline),
                size: 18,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  ok
                      ? '别名 ${cfg.keyAlias}，keystore 在 ${cfg.storeFile}。'
                          '密钥丢了就再也发不了升级包，建议导出一份备份。'
                      : (broken
                          ? 'key.properties 里 storeFile / keyAlias / '
                              'storePassword / keyPassword 有缺失，'
                              'gradle 读到一半会失败。点"重新生成"可以重写一份。'
                          : 'debug 签名的 APK 不能上架，也不能覆盖安装正式版。'
                              '自用/测试没问题，要发布就得生成 keystore。'),
                  style: const TextStyle(fontSize: 11, height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                // alpha.93：真正干活的入口。以前这张卡只有"查看 build.gradle"
                // —— 用户看完还得自己去找 keytool、改 gradle，等于没做。
                onPressed: _signBusy ? null : () => _genKeystore(force: false),
                icon: _signBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.vpn_key, size: 16),
                label: Text(_signBusy ? '处理中…' : '生成并配置签名',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_signBusy || cfg == null) ? null : _exportKeystore,
                icon: const Icon(Icons.ios_share_outlined, size: 16),
                label: const Text('备份 keystore',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                // Bug 470：同样要跟随实际存在的 gradle 文件（.gradle / .kts），
                // 否则点了会打开一个不存在的路径
                onPressed: () => widget.onOpenFile(_hasSigning
                    ? 'android/key.properties'
                    : (_gradleActual ?? _gradleRel)),
                icon: const Icon(Icons.code, size: 16),
                label: Text(
                    _hasSigning
                        ? '查看 key.properties'
                        : (_gradleActual?.endsWith('.kts') ?? false
                            ? '查看 build.gradle.kts'
                            : '查看 build.gradle'),
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_signBusy || cfg == null)
                    ? null
                    : () => _genKeystore(force: true),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('重新生成', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        // ---------- alpha.94：签名库（多份钥匙 + 导入） ----------
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(Icons.vpn_key_outlined, size: 15,
                color: FoaColors.of(context).muted),
            const SizedBox(width: 6),
            Text('签名库（${_store.length}）',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton.icon(
              onPressed: _signBusy ? null : _importKeystore,
              icon: const Icon(Icons.upload_file, size: 15),
              label: const Text('导入 keystore',
                  style: TextStyle(fontSize: 11.5)),
            ),
          ],
        ),
        if (_store.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '还没有登记过钥匙。生成或导入之后，这里会列出来，'
              '可以在同一个工程里随时切换用哪一把。',
              style: TextStyle(
                  fontSize: 10.5, color: FoaColors.of(context).muted),
            ),
          )
        else
          ..._store.map((e) {
            final inUse = _signCfg?.storeFile == e.path;
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Icon(
                    inUse ? Icons.check_circle : Icons.vpn_key_outlined,
                    size: 15,
                    color: inUse
                        ? const Color(0xFF3DDC84)
                        : FoaColors.of(context).muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.display,
                            style: const TextStyle(fontSize: 11.5)),
                        Text(e.detail,
                            style: TextStyle(
                                fontSize: 10,
                                color: FoaColors.of(context).muted)),
                      ],
                    ),
                  ),
                  if (inUse)
                    const Text('当前',
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFF3DDC84)))
                  else
                    TextButton(
                      onPressed: _signBusy ? null : () => _useKeystore(e),
                      child: const Text('使用',
                          style: TextStyle(fontSize: 11.5)),
                    ),
                  SizedBox(
                    width: 32,
                    child: IconButton(
                      tooltip: '从库里移除',
                      iconSize: 15,
                      onPressed: _signBusy ? null : () => _removeKeystore(e),
                      icon: Icon(Icons.delete_outline,
                          size: 15, color: FoaColors.of(context).muted),
                    ),
                  ),
                ],
              ),
            );
          }),
        if (_signResult != null) ...[
          const SizedBox(height: 8),
          Text(
            _signResult!,
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: _signOk
                  ? FoaColors.of(context).success
                  : FoaColors.of(context).danger,
            ),
          ),
        ],
        _hint(
          '流程是：容器里的 keytool 生成 JKS 密钥 → 写 android/key.properties '
          '（并把它加进 .gitignore，避免明文口令进版本库）→ 给 '
          'android/app/build.gradle(.kts) 打补丁，让 release 变体改用正式密钥。'
          '构建脚本的模板匹配不到时**不会硬改**，会明确告诉你改用「打包区的验签/重签」。'
          '上架用的自签证书 Google Play 与多数国内商店都接受，'
          '但如果你已经从商店后台导出过上传证书，请直接改 key.properties 指到它。',
        ),
      ],
    );
  }

  /// alpha.96：修掉构建脚本里会让 gradle **编译失败**的老写法。
  ///
  /// 为什么单独做一个按钮，而不是并进"生成并配置签名"：
  /// 那个入口会**重新生成一把新 keystore**。用户现在的诉求只是
  /// "让构建别再报 Unresolved reference"，不该被迫换钥匙
  /// （换了钥匙，已上架的应用就发不了升级包）。
  Future<void> _repairGradle() async {
    setState(() {
      _signBusy = true;
      _signResult = null;
    });
    final log = <String>[];
    final r = await Signing.repairLegacyPatch(
      _fb,
      projectName: widget.projectName,
    );
    log.add(r.msg);
    if (r.changed) {
      log.add('请重新构建。这次不该再看到 '
          '`Unresolved reference: util / io` 了。');
    }
    await _load();
    if (!mounted) return;
    return _finishSign(r.changed, log.join('\n'));
  }

  /// 生成 keystore → 写 key.properties → 给构建脚本接线。
  Future<void> _genKeystore({required bool force}) async {
    final plan = await showSigningDialog(
      context,
      projectName: widget.projectName,
      replacing: force,
    );
    if (plan == null || !mounted) return;
    setState(() {
      _signBusy = true;
      _signResult = null;
    });

    final ksPath = Signing.keystorePathFor(widget.projectName);
    final log = <String>[];

    // 1) keystore
    final gen = await Signing.generateKeystore(
      ProotBridge(),
      keystorePath: ksPath,
      alias: plan.alias,
      storePass: plan.storePass,
      keyPass: plan.keyPass,
      dname: plan.dname,
      force: force,
    );
    log.add(gen.msg);
    if (!gen.ok) return _finishSign(false, log.join('\n'));

    // 2) key.properties（keystore 写成功了才写，否则会留下指不到文件的配置）
    final w = await Signing.writeKeyProperties(
      _fb,
      projectName: widget.projectName,
      storeFile: ksPath,
      storePassword: plan.storePass,
      keyPassword: plan.keyPass,
      keyAlias: plan.alias,
    );
    log.add(w.msg);
    if (!w.ok) return _finishSign(false, log.join('\n'));

    // 3) 构建脚本接线（匹配不到就拒绝，此时上面两步已经生效，
    //    用户仍可在打包区对产物直接签名）
    final p = await Signing.patchBuildScript(_fb, projectName: widget.projectName);
    log.add(p.ok ? p.msg : '构建脚本没改：${p.msg}\n'
        '（keystore 与 key.properties 已就绪，可在打包区对 APK 直接签名）');

    // alpha.94：登记进签名库。不登记的话这把钥匙就"只属于这个工程"——
    // 换个工程要重新生成，想在正式/测试之间切换也没得选。
    final st = KeystoreStore(ProotBridge());
    final id = KeystoreStore.safeId(widget.projectName);
    final entry = KeystoreEntry(
      id: id,
      label: widget.projectName,
      path: ksPath,
      alias: plan.alias,
      storePass: plan.storePass,
      keyPass: plan.keyPass,
    );
    final saved = await st.save(<KeystoreEntry>[
      ..._store.where((e) => e.id != id),
      entry,
    ]);
    log.add(saved.ok ? '已登记进签名库（${saved.msg}）' : '签名库登记失败：${saved.msg}');
    return _finishSign(true, log.join('\n'));
  }

  /// 把库里的某把钥匙接到这个工程（写 key.properties + 给 gradle 接线）。
  Future<void> _useKeystore(KeystoreEntry e) async {
    setState(() {
      _signBusy = true;
      _signResult = null;
    });
    final log = <String>[];
    final w = await Signing.writeKeyProperties(
      _fb,
      projectName: widget.projectName,
      storeFile: e.path,
      storePassword: e.storePass,
      keyPassword: e.keyPass,
      keyAlias: e.alias,
    );
    log.add(w.msg);
    if (!w.ok) return _finishSign(false, log.join('\n'));
    final p =
        await Signing.patchBuildScript(_fb, projectName: widget.projectName);
    log.add(p.ok ? p.msg : '构建脚本没改：${p.msg}\n'
        '（key.properties 已指向 ${e.display}，可在打包区对 APK 直接签名）');
    // 即使 gradle 没改成也算成功：钥匙已经接上，产物签名仍然可用。
    return _finishSign(true, '已切换到「${e.display}」。\n${log.join('\n')}');
  }

  /// 导入一份外部 keystore：选文件 → 填名字与口令 → 读别名 → 入库。
  Future<void> _importKeystore() async {
    setState(() {
      _signBusy = true;
      _signResult = null;
    });
    try {
      final picked = await FileBrowserBridge().pickImport();
      if (!picked.ok || picked.path == null) {
        return _finishSign(false, picked.error ?? '未选择文件');
      }
      if (!mounted) return;
      final plan = await showKeystoreImportDialog(
        context,
        defaultLabel: '导入${_store.length + 1}',
      );
      if (plan == null || !mounted) {
        setState(() => _signBusy = false);
        return;
      }
      final st = KeystoreStore(ProotBridge());
      final id = _uniqueId(KeystoreStore.safeId(plan.label));

      // 1) 拷进签名库
      final imp = await st.importFile(src: picked.path!, id: id);
      if (!imp.ok) return _finishSign(false, imp.msg);
      final path = imp.msg;

      // 2) 用口令去读别名（顺带验证口令对不对）
      final al = await st.aliases(
          keystorePath: path, storePass: plan.storePass);
      if (!al.ok) {
        // 文件已经拷进来了，口令错了用户可以再来一次——但要把这次
        // 拷进去的垃圾清掉，否则签名库里会躺一个打不开的条目。
        await KeystoreStore(ProotBridge()).delete(path);
        return _finishSign(false, al.msg);
      }
      var alias = plan.alias;
      if (al.aliases.isNotEmpty) {
        if (al.aliases.length == 1) {
          alias = al.aliases.first;
        } else if (mounted) {
          final chosen = await _pickAliasDialog(al.aliases);
          if (chosen == null) {
            await KeystoreStore(ProotBridge()).delete(path);
            setState(() => _signBusy = false);
            return;
          }
          alias = chosen;
        }
      }
      // 3) 读证书主体（让用户以后能认出这是谁的钥匙）
      final subj = await st.subject(
          keystorePath: path, alias: alias, storePass: plan.storePass);
      final entry = KeystoreEntry(
        id: id,
        label: plan.label,
        path: path,
        alias: alias,
        storePass: plan.storePass,
        keyPass: plan.keyPass,
        subject: subj,
        imported: true,
      );
      final next = <KeystoreEntry>[
        ..._store.where((e) => e.id != id),
        entry,
      ];
      final saved = await st.save(next);
      if (!saved.ok) return _finishSign(false, saved.msg);
      return _finishSign(true,
          '已导入「${entry.display}」（别名 $alias${subj.isEmpty ? '' : '，$subj'}）。\n'
          '它还没接到这个工程——点它右边的「使用」才会写进 key.properties。');
    } catch (e) {
      return _finishSign(false, '导入失败：$e');
    }
  }

  /// 从库里移除（只删库里的副本与登记，不动工程）。
  Future<void> _removeKeystore(KeystoreEntry e) async {
    final inUse = _signCfg?.storeFile == e.path;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('从签名库移除？'),
            content: Text(
              '会删掉 ${e.path} 以及它在库里的登记。\n'
              '${inUse ? '⚠️ 这个工程正在用它——移除后 key.properties 会指向一个不存在的文件，'
                      'release 构建会失败（除非再选一把或重新生成）。'
                    : '这个工程当前没用它，移除不影响构建。'}',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('移除')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    setState(() {
      _signBusy = true;
      _signResult = null;
    });
    final st = KeystoreStore(ProotBridge());
    final d = await st.delete(e.path);
    if (!d.ok) return _finishSign(false, d.msg);
    final next = _store.where((x) => x.id != e.id).toList();
    final s = await st.save(next);
    return _finishSign(s.ok, s.ok ? '已从签名库移除「${e.display}」。' : s.msg);
  }

  /// 库里已有同名 id 时往后顺延（覆盖别人的钥匙是不可逆的，绝不自动做）。
  String _uniqueId(String base) {
    final taken = _store.map((e) => e.id).toSet();
    if (!taken.contains(base)) return base;
    var i = 2;
    while (taken.contains('${base}_$i')) {
      i++;
    }
    return '${base}_$i';
  }

  /// 一个 keystore 里有多个别名时让用户挑（挑错会签不出来）。
  Future<String?> _pickAliasDialog(List<String> aliases) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('用哪个别名签名？'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '这个文件里有 ${aliases.length} 个条目。签名用的必须是'
              '**私钥**条目（keytool -list 里带 PrivateKeyEntry 的那些）。',
              style: TextStyle(
                  fontSize: 11, color: FoaColors.of(context).muted),
            ),
          ),
          ...aliases.map((a) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, a),
                child: Text(a, style: const TextStyle(fontSize: 12)),
              )),
        ],
      ),
    );
  }

  void _finishSign(bool ok, String msg) {
    if (!mounted) return;
    setState(() {
      _signBusy = false;
      _signOk = ok;
      _signResult = msg;
    });
    _load(); // 重读，让卡片状态跟上
  }

  /// 把 keystore 通过系统保存对话框导出（丢了就发不了升级包）。
  Future<void> _exportKeystore() async {
    final cfg = _signCfg;
    if (cfg == null) return;
    final name = cfg.storeFile.split('/').last;
    final r = await FileBrowserBridge().export(cfg.storeFile, name);
    if (!mounted) return;
    _toast(r.ok ? '已导出 $name（请妥善保管）' : '导出失败：${r.error}');
  }

  // ---------- 卡片 6：构建高级 ----------

  Widget _advancedCard(dynamic d) {
    return _card(
      icon: Icons.tune_outlined,
      title: '构建选项',
      subtitle: '影响 APK 体积与反编译难度',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _minify,
          onChanged: (v) => setState(() {
            _minify = v;
            _pushDirty();
          }),
          title: const Text('代码混淆与压缩（R8）', style: TextStyle(fontSize: 13)),
          subtitle: const Text(
            '开启后 release 包体积更小、更难反编译；'
            '但如果用了反射或 JNI，可能需要额外配置 keep 规则',
            style: TextStyle(fontSize: 10, height: 1.4),
          ),
          dense: true,
        ),
        // ⚠️ 这段话必须区分「文件里真写了」和「文件里没有、靠 AGP 默认」。
        // 官方模板的 buildTypes.release 里**根本没有** minifyEnabled 这一行，
        // 而 AGP 对 release 的默认就是开启 —— 所以缺省时磁盘上的真实状态是
        // 「开启」，但写的是「这一行不存在」。含糊成一句「现在为开启」会让
        // 用户以为文件里已经有 false/true 可改，翻到 gradle 里找不到就懵了。
        if (d.minify)
          _hint(_minifyExplicit
              ? '将与当前设置相反：现在为 ${_disk.minify ? "开启" : "关闭"}'
              : 'gradle 里原本没有 minifyEnabled 这一行（AGP 对 release 默认开启）；'
                  '保存后会写进 buildTypes.release'),
        const Divider(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.description_outlined, size: 18),
          title: const Text('pubspec.yaml（描述 / 版本 / 依赖）',
              style: TextStyle(fontSize: 13)),
          subtitle: Text(
              '当前描述：${_disk.description.isEmpty ? "（空）" : _disk.description}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10)),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => widget.onOpenFile(_pubRel),
        ),
        const SizedBox(height: 8),
        _label('应用描述（pubspec description）', hint: '同步写入 pubspec.yaml'),
        TextField(
          controller: _descCtl,
          style: const TextStyle(fontSize: 14),
          maxLines: 2,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '一句话说明这个应用是做什么的',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => widget.onOpenFile(_mfRel),
                icon: const Icon(Icons.code, size: 16),
                label: const Text('编辑 AndroidManifest.xml',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------- 通用小件 ----------

  Widget _card({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFF4C8DFF)),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(subtitle,
                  style: TextStyle(
                      fontSize: 11, color: FoaColors.of(context).muted)),
            ),
            const Divider(height: 22),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _label(String s, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(s,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10, color: FoaColors.of(context).muted)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hint(String s, {bool warn = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        s,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.5,
          color: warn ? const Color(0xFFFFB74D) : FoaColors.of(context).muted,
        ),
      ),
    );
  }
}
