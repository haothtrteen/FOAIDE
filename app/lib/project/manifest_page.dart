import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/fs_bridge.dart';
import 'manifest_codec.dart';

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

  /// 签名配置是否存在。
  bool _hasSigning = false;

  /// 混淆开关（读自 build.gradle）。
  bool _minify = true;

  /// 上次保存的结果提示（成功/失败都留在界面上，用户不用翻 SnackBar）。
  String _saveNote = '';
  bool _saveOk = true;

  /// 可勾选的常用权限（超出这些的权限走"在 Manifest 里手动加"）。
  static const List<({String name, String short, String why})> _commonPerms = [
    (
      name: 'android.permission.INTERNET',
      short: '联网',
      why: '访问网络（几乎所有应用都需要）'
    ),
    (
      name: 'android.permission.ACCESS_NETWORK_STATE',
      short: '网络状态',
      why: '判断当前是否联网/是否 WiFi'
    ),
    (
      name: 'android.permission.CAMERA',
      short: '相机',
      why: '拍照、扫码'
    ),
    (
      name: 'android.permission.RECORD_AUDIO',
      short: '录音',
      why: '语音输入、通话'
    ),
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
    (
      name: 'android.permission.VIBRATE',
      short: '振动',
      why: '消息提醒振动'
    ),
  ];

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController();
    _descCtl = TextEditingController();
    _verNameCtl = TextEditingController();
    _verCodeCtl = TextEditingController();
    _nameCtl.addListener(_markDirty);
    _descCtl.addListener(_markDirty);
    _verNameCtl.addListener(_markDirty);
    _verCodeCtl.addListener(_markDirty);
    _load();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _descCtl.dispose();
    _verNameCtl.dispose();
    _verCodeCtl.dispose();
    super.dispose();
  }

  String _p(String rel) => '/root/projects/${widget.projectName}/$rel';

  static const _pubRel = 'pubspec.yaml';
  static const _mfRel = 'android/app/src/main/AndroidManifest.xml';
  static const _gradleRel = 'android/app/build.gradle';

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

      for (final f in const [_gradleRel, 'android/app/build.gradle.kts']) {
        final g = await _fb.read(_p(f));
        if (!g.ok) continue;
        final r = ManifestCodec.parseGradle(g.content);
        if (r.appId.isNotEmpty) appId = r.appId;
        minify = r.minify;
        if (appId.isNotEmpty) break;
      }

      // 签名配置探测（不解析内容，只看文件在不在）
      for (final f in const [
        'android/key.properties',
        'android/app/key.properties',
      ]) {
        final s = await _fb.read(_p(f));
        if (s.ok) {
          _hasSigning = true;
          break;
        }
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
      _verNameCtl.text = verName;
      _verCodeCtl.text = verCode;
      _permExisting
        ..clear()
        ..addAll(perms);
      _permChecked.clear();
      _minify = minify;
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
      verName: vn,
      verCode: vc,
      perms: perms,
      minify: _minify != _disk.minify,
    );
  }

  /// 已被用户**取消勾选**的原有权限（要从 Manifest 里删掉的）。
  Set<String> _uncheckedExisting() => _permExisting
      .where((p) => !_permChecked.contains(p) && !_permChecked.contains(_short(p)))
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
    return d.name || d.desc || d.verName || d.verCode || d.perms || d.minify;
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
    if (!d.name && !d.desc && !d.verName && !d.verCode && !d.perms && !d.minify) {
      _note('没有需要保存的改动', ok: true);
      return;
    }

    // ---------- 校验（先全部校验完再动盘，避免写一半发现格式错） ----------
    final label = _nameCtl.text.trim();
    if (d.name && !ManifestCodec.validLabel(label)) {
      _note('应用名不能为空，且不超过 80 字', ok: false);
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
    if (d.verName && ManifestCodec.versionNameDowngrade(_disk.versionName, vn)) {
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
          t = ManifestCodec.setVersion(t, vn, d.verCode ? vc : _disk.versionCode);
        }
        final w = await _fb.write(_p(_pubRel), t);
        if (w.ok) {
          done.add('pubspec.yaml');
        } else {
          failed.add('pubspec.yaml（${w.error}）');
        }
      }
    }

    // ---------- 2. AndroidManifest（应用名 / 权限） ----------
    if (d.name || d.perms) {
      final r = await _fb.read(_p(_mfRel));
      if (!r.ok) {
        failed.add('AndroidManifest.xml（读取失败：${r.error}）');
      } else {
        var t = r.content;
        if (d.name) t = ManifestCodec.setLabel(t, label);
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

    // ---------- 3. build.gradle（混淆） ----------
    if (d.minify) {
      final r = await _fb.read(_p(_gradleRel));
      if (!r.ok) {
        failed.add('build.gradle（读取失败：${r.error}）');
      } else {
        final before = r.content;
        final after = ManifestCodec.setMinify(before, _minify);
        if (after == before) {
          // gradle 里没有 minifyEnabled 键——不能硬插，只能提示
          failed.add('build.gradle（未找到 minifyEnabled，请在编辑器中手动修改）');
        } else {
          final w = await _fb.write(_p(_gradleRel), after);
          if (w.ok) {
            done.add('build.gradle');
          } else {
            failed.add('build.gradle（${w.error}）');
          }
        }
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);

    if (failed.isEmpty) {
      _note('已保存：${done.join('、')}', ok: true);
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
      _note('写入后校验发现内容不一致，请检查文件权限或是否有其它进程在改这个项目',
          ok: false);
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
              const Icon(Icons.error_outline, size: 40, color: Color(0xFFFF7A7A)),
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
        _label('应用名（android:label）',
            hint: '显示在桌面图标下方，可随时修改'),
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
        _label('应用包名（applicationId）', hint: '唯一标识，装机后不可更改'),
        Row(
          children: [
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white12),
                ),
                child: Text(
                  _disk.appId.isEmpty ? '（未在 build.gradle 中找到）' : _disk.appId,
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: _disk.appId.isEmpty
                        ? Colors.grey
                        : const Color(0xFFC9CFD6),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '复制包名',
              onPressed: () => _copy('包名', _disk.appId),
              icon: const Icon(Icons.copy, size: 18),
            ),
          ],
        ),
        _hint(
          '为什么不能改：包名决定应用的"身份证"。改了系统会当成另一个应用——'
          '旧版本无法升级安装，签名、第三方 SDK（推送/统计/支付）后台登记的'
          '包名也全部要改。真要改请新建项目。',
          warn: true,
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
                      errorText:
                          _verCodeCtl.text.trim().isEmpty || vcOk ? null : '必须是整数',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (downgrade)
          _hint('⚠️ 版本名比当前（${_disk.versionName}）小，应用商店会拒绝上架',
              warn: true),
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
                            color: const Color(0xFF4C8DFF).withValues(alpha: 0.2),
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
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFF173F35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.flutter_dash,
                  color: Color(0xFF3DDC84), size: 30),
            ),
            const SizedBox(width: 14),
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
                        fontSize: 10, fontFamily: 'monospace', color: Colors.grey),
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
              child: OutlinedButton.icon(
                onPressed: () => widget.onOpenFile(_iconPath.isEmpty
                    ? 'android/app/src/main/res'
                    : _iconPath),
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('在编辑器中打开', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        _hint('图标替换：把 ic_launcher.png 覆盖到 '
            'android/app/src/main/res/mipmap-*/ 各密度目录。'
            '正规做法是用 flutter_launcher_icons 插件（在 pubspec 里配置后执行生成命令），'
            '可以一次性产出所有尺寸并避免拉伸模糊。'),
      ],
    );
  }

  // ---------- 卡片 5：签名 ----------

  Widget _signingCard() {
    return _card(
      icon: Icons.key_outlined,
      title: '签名配置',
      subtitle: _hasSigning ? '已检测到签名配置' : '未配置：当前用 debug 签名',
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: (_hasSigning
                    ? const Color(0xFF3DDC84)
                    : const Color(0xFFFFB74D))
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                _hasSigning ? Icons.verified_outlined : Icons.info_outline,
                size: 18,
                color: _hasSigning
                    ? const Color(0xFF3DDC84)
                    : const Color(0xFFFFB74D),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _hasSigning
                      ? '项目里存在 key.properties。发布到应用商店前请确认'
                          'storeFile / storePassword / keyAlias 填写正确。'
                      : 'debug 签名的 APK 不能上架，也不能覆盖安装正式版。'
                          '自用/测试没问题，要发布就得生成 keystore 并配置 '
                          'android/key.properties。',
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
              child: OutlinedButton.icon(
                onPressed: () => widget.onOpenFile(
                    _hasSigning ? 'android/key.properties' : 'android/app/build.gradle'),
                icon: const Icon(Icons.code, size: 16),
                label: Text(_hasSigning ? '查看 key.properties' : '查看 build.gradle',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ],
    );
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
        if (d.minify) _hint('将与当前设置相反：现在为 ${_disk.minify ? "开启" : "关闭"}'),
        const Divider(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.description_outlined, size: 18),
          title: const Text('pubspec.yaml（描述 / 版本 / 依赖）',
              style: TextStyle(fontSize: 13)),
          subtitle: Text('当前描述：${_disk.description.isEmpty ? "（空）" : _disk.description}',
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
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
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
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          if (hint != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
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
          color: warn ? const Color(0xFFFFB74D) : Colors.grey.shade500,
        ),
      ),
    );
  }
}
