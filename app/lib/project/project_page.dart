import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/editor_page.dart';
import '../editor/fs_bridge.dart';
import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../toolchain/build_notify.dart';
import '../toolchain/build_page.dart';
import '../toolchain/build_runner.dart';
import '../toolchain/termux_backend.dart';

/// 项目工作台（alpha.33）：点工程卡片先到这里，而不是直接构建。
///
/// 布局模仿 FusionApp 风格：左侧抽屉切换「概览 / 代码 / 清单 / 打包」，
/// AppBar 副标题跟随当前区。各职责：
/// - 概览：项目元信息（pubspec + android 清单解析）+ 快捷入口；
/// - 代码：直达编辑器（alpha.34 融合——文件树在编辑器抽屉/左栏内，
///   自动恢复上次编辑文件，无记录回退 lib/main.dart；不再停留文件树页）；
/// - 清单：应用名称 / 包名 / 版本名 / 版本代码 / 权限（版本可编辑，
///   写回 pubspec 的 version 行——applicationId/label 只读防误改）；
/// - 打包：BuildRunner 单例的构建面板（同一会话与构建页/通知互通，
///   前台服务保活照常生效）+ 清理构建缓存（flutter clean）。
///
/// 与 BuildPage 的关系：BuildPage 仍是通知回跳/直达构建的完整页面；
/// 本页是"项目为中心"的工作台视图。构建状态都在 BuildRunner 全局单例，
/// 两边看到的进度一致。
class ProjectPage extends StatefulWidget {
  final String projectName;

  const ProjectPage({super.key, required this.projectName});

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

enum _Section { overview, code, manifest, build }

extension _SectionLabel on _Section {
  String get label => switch (this) {
        _Section.overview => '概览',
        _Section.code => '代码',
        _Section.manifest => '清单',
        _Section.build => '打包',
      };

  IconData get icon => switch (this) {
        _Section.overview => Icons.info_outline,
        _Section.code => Icons.code,
        _Section.manifest => Icons.fact_check_outlined,
        _Section.build => Icons.build_outlined,
      };
}

class _ProjectPageState extends State<ProjectPage> {
  final FsBridge _fb = FsBridge();
  _Section _section = _Section.overview;

  EnvInfo? _env;
  bool _loading = true;
  String _loadError = '';
  BuildBackend _backend = BuildBackend.proot;

  // ---- 清单数据 ----
  String _pubName = '';
  String _description = '';
  String _appId = '';
  String _label = '';
  String _verName = '';
  String _verCode = '';
  int _depCount = 0;
  final List<String> _permissions = [];
  final _verNameCtl = TextEditingController();
  final _verCodeCtl = TextEditingController();
  bool _dirty = false;
  bool _saving = false;

  // ---- 打包面板轮询（不碰 BuildRunner.onUiChanged——那是 BuildPage 的）----
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _verNameCtl.dispose();
    _verCodeCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = '';
    });
    try {
      final env = await ProotBridge().envInfo();
      final backend = await BackendPrefs.load(env);
      if (!env.rootfsInstalled) {
        if (!mounted) return;
        setState(() {
          _env = env;
          if (backend != null) _backend = backend;
          _loading = false;
        });
        return;
      }
      await _readManifest(env);
      if (!mounted) return;
      setState(() {
        _env = env;
        if (backend != null) _backend = backend;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '加载失败：$e';
      });
    }
  }

  String _guestPath(String rel) => '/root/projects/${widget.projectName}/$rel';

  /// 解析 pubspec / AndroidManifest / build.gradle（清单区数据源）。
  Future<void> _readManifest(EnvInfo env) async {
    final pub = await _fb.read(_guestPath('pubspec.yaml'));
    if (pub.ok) {
      final t = pub.content;
      _pubName = RegExp(r'^name:\s*(.+)$', multiLine: true)
          .firstMatch(t)
          ?.group(1)
          ?.trim() ??
          widget.projectName;
      _description = RegExp(r'^description:\s*(.+)$', multiLine: true)
          .firstMatch(t)
          ?.group(1)
          ?.trim() ??
          '';
      final ver = RegExp(r'^version:\s*(.+)$', multiLine: true)
          .firstMatch(t)
          ?.group(1)
          ?.trim();
      final plus = ver?.indexOf('+') ?? -1;
      _verName = (plus >= 0 ? ver?.substring(0, plus) : ver)?.trim() ?? '1.0.0';
      _verCode = (plus >= 0 ? ver?.substring(plus + 1) : '1')?.trim() ?? '1';
      final depStart = t.indexOf('dependencies:');
      _depCount = 0;
      if (depStart >= 0) {
        for (final line in t.substring(depStart).split('\n').skip(1)) {
          if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
            break;
          }
          if (line.trim().isNotEmpty && !line.trim().startsWith('#')) {
            _depCount++;
          }
        }
      }
    }
    final mf = await _fb.read(_guestPath('android/app/src/main/AndroidManifest.xml'));
    if (mf.ok) {
      _label = RegExp(r'android:label="([^"]*)"').firstMatch(mf.content)?.group(1) ?? '';
      _permissions.addAll(
        RegExp(r'android:name="([^"]*)"')
            .allMatches(mf.content)
            .map((m) => m.group(1)!)
            .where((n) => n.contains('permission'))
            .map((n) => n.split('.').last),
      );
    }
    for (final f in const ['android/app/build.gradle', 'android/app/build.gradle.kts']) {
      final g = await _fb.read(_guestPath(f));
      if (g.ok) {
        _appId = RegExp(r'applicationId\s*=?\s*"([^"]*)"')
                .firstMatch(g.content)
                ?.group(1) ??
            '';
        if (_appId.isNotEmpty) break;
      }
    }
    _verNameCtl.text = _verName;
    _verCodeCtl.text = _verCode;
  }

  /// 保存版本：替换 pubspec 的 version 行（唯一允许的写操作——
  /// applicationId 改了会与已装应用冲突，label 涉及 Manifest 多处匹配，
  /// 都保持只读）。
  Future<void> _saveVersion() async {
    final env = _env;
    if (env == null || _saving) return;
    final vn = _verNameCtl.text.trim();
    final vc = _verCodeCtl.text.trim();
    if (vn.isEmpty || !RegExp(r'^\d+\.\d+\.\d+([\-+.\w]*)?$').hasMatch(vn)) {
      _toast('版本名格式应为 x.y.z（如 1.0.0）');
      return;
    }
    if (vc.isEmpty || int.tryParse(vc) == null) {
      _toast('版本代码应为整数');
      return;
    }
    setState(() => _saving = true);
    final r = await _fb.read(_guestPath('pubspec.yaml'));
    if (!r.ok) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('读取 pubspec 失败：${r.error}');
      return;
    }
    final newLine = 'version: $vn+$vc';
    final t = r.content.replaceFirst(
      RegExp(r'^version:.*$', multiLine: true),
      newLine,
    );
    final w = await _fb.write(_guestPath('pubspec.yaml'), t);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (w.ok) {
        _verName = vn;
        _verCode = vc;
        _dirty = false;
      }
    });
    _toast(w.ok ? '已保存 $newLine' : '保存失败：${w.error}');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ============================ 骨架 ============================

  @override
  Widget build(BuildContext context) {
    final r = BuildRunner.I;
    // 打包中 500ms 刷新快照（构建轮询由 BuildRunner 守护 timer 驱动，
    // 这里只读状态；其它 section 不开 timer 零开销）
    final needTimer = _section == _Section.build &&
        (r.building || _uiTimer != null);
    if (needTimer && _uiTimer == null) {
      _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    }
    if (!needTimer && _uiTimer != null) {
      _uiTimer?.cancel();
      _uiTimer = null;
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.projectName,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text(_section.label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          if (_section == _Section.manifest)
            IconButton(
              tooltip: '保存版本',
              onPressed: _dirty && !_saving ? _saveVersion : null,
              icon: _saving
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save_outlined),
            ),
        ],
      ),
      drawer: _buildDrawer(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError.isNotEmpty
              ? _buildError()
              : switch (_section) {
                  _Section.overview => _buildOverview(),
                  _Section.code => _buildCode(),
                  _Section.manifest => _buildManifest(),
                  _Section.build => _buildPanel(),
                },
    );
  }

  Widget _buildError() {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(_loadError,
              style: const TextStyle(color: Color(0xFFFF7A7A))),
        ),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _load,
        icon: const Icon(Icons.refresh),
        label: const Text('重试'),
      ),
    ]);
  }

  // ============================ 抽屉（模仿参考图 1） ============================

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF14181E),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.projectName,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold,
                          color: Color(0xFFE6E6E6)),
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text('项目工作台 · ${_pubName.isNotEmpty ? _pubName : "…"}',
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF8A939E))),
                ],
              ),
            ),
            for (final s in _Section.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Material(
                  color: s == _section
                      ? const Color(0xFF173F35)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      Navigator.of(context).pop(); // 收起抽屉
                      if (s == _Section.code) {
                        // alpha.34 代码区融合：不进工作台停留区，直达
                        // 编辑器（文件树在编辑器抽屉/左栏，少一次跳转）
                        _openEditor();
                        return;
                      }
                      setState(() => _section = s);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      child: Row(
                        children: [
                          Icon(s.icon,
                              size: 20,
                              color: s == _section
                                  ? const Color(0xFF3DDC84)
                                  : const Color(0xFF8A939E)),
                          const SizedBox(width: 16),
                          Text(s.label,
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: s == _section
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: s == _section
                                      ? const Color(0xFF3DDC84)
                                      : const Color(0xFFC9CFD6))),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ============================ 概览 ============================

  Widget _buildOverview() {
    final env = _env;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFF173F35),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.flutter_dash,
                          color: Color(0xFF3DDC84), size: 28),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_pubName,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                          if (_description.isNotEmpty)
                            Text(_description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey.shade500)),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 24),
                _kv('包名', _appId.isEmpty ? '—' : _appId),
                _kv('版本', '$_verName+$_verCode'),
                _kv('依赖', '$_depCount 个'),
                _kv('容器路径', '/root/projects/${widget.projectName}'),
                _kv('构建后端',
                    _backend == BuildBackend.termux ? 'Termux 裸原生（实验性）' : 'Proot 容器'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _quickCard(Icons.code, '写代码', '打开编辑器', _openEditor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _quickCard(
                  Icons.build_outlined, '打包', '构建 APK',
                  () => setState(() => _section = _Section.build)),
            ),
          ],
        ),
        if (env != null && !env.rootfsInstalled) ...[
          const SizedBox(height: 12),
          const Text('rootfs 未初始化：构建/文件浏览需先在主页完成环境安装',
              style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
        ],
      ],
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(k,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ),
          Expanded(
            child: SelectableText(v,
                style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: Color(0xFFD6DEE8))),
          ),
        ],
      ),
    );
  }

  Widget _quickCard(IconData icon, String title, String sub, VoidCallback onTap) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, size: 22, color: const Color(0xFF4C8DFF)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    Text(sub,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================ 代码 ============================

  /// 直达编辑器（抽屉「代码」与概览「写代码」共用）：文件树在编辑器的
  /// 抽屉/左栏内，自动恢复上次编辑的文件（无记录回退 lib/main.dart）。
  void _openEditor() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EditorPage(
        initialDir: '/root/projects/${widget.projectName}',
      ),
    ));
  }

  /// 兜底视图（alpha.34 起抽屉「代码」直达编辑器，此分支正常不可达）。
  Widget _buildCode() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.code, size: 44, color: Color(0xFF3DDC84)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _openEditor,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('打开编辑器'),
          ),
          const SizedBox(height: 8),
          Text('文件树在编辑器左侧抽屉内',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  // ============================ 清单（模仿参考图 2） ============================

  Widget _buildManifest() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: const Color(0xFF173F35),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.flutter_dash,
              color: Color(0xFF3DDC84), size: 40),
        ),
        const SizedBox(height: 20),
        _fieldLabel('应用名称（android:label，只读）'),
        Text(_label.isEmpty ? '—' : _label,
            style: const TextStyle(fontSize: 15, color: Color(0xFFC9CFD6))),
        const Divider(height: 28),
        _fieldLabel('应用包名（applicationId，只读）'),
        Text(_appId.isEmpty ? '—' : _appId,
            style: const TextStyle(
                fontSize: 15,
                fontFamily: 'monospace',
                color: Color(0xFFC9CFD6))),
        const Divider(height: 28),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('版本名'),
                  TextField(
                    controller: _verNameCtl,
                    style: const TextStyle(fontSize: 15),
                    decoration: const InputDecoration(
                      hintText: '1.0.0',
                      isDense: true,
                      border: UnderlineInputBorder(),
                    ),
                    onChanged: (_) => _markDirty(),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _fieldLabel('版本代码'),
                  TextField(
                    controller: _verCodeCtl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(fontSize: 15),
                    decoration: const InputDecoration(
                      hintText: '1',
                      isDense: true,
                      border: UnderlineInputBorder(),
                    ),
                    onChanged: (_) => _markDirty(),
                  ),
                ],
              ),
            ),
          ],
        ),
        const Divider(height: 28),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.extension_outlined,
              color: Color(0xFF4C8DFF)),
          title: Text('依赖（$_depCount 个，pubspec.yaml）',
              style: const TextStyle(fontSize: 14)),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => _openFile('pubspec.yaml'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              const Icon(Icons.verified_user_outlined, color: Color(0xFF4C8DFF)),
          title: Text(
              _permissions.isEmpty
                  ? '权限（未声明）'
                  : '权限（${_permissions.length}）',
              style: const TextStyle(fontSize: 14)),
          subtitle: _permissions.isEmpty
              ? null
              : Text(_permissions.take(4).join('、') +
                  (_permissions.length > 4 ? ' …' : ''),
              style: const TextStyle(fontSize: 11)),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () => _openFile('android/app/src/main/AndroidManifest.xml'),
        ),
        if (_dirty) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _saving ? null : _saveVersion,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存版本（写回 pubspec.yaml）'),
          ),
        ],
      ],
    );
  }

  void _markDirty() {
    final dirty = _verNameCtl.text != _verName || _verCodeCtl.text != _verCode;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _openFile(String rel) async {
    final path = _guestPath(rel);
    final probe = await _fb.read(path);
    if (!mounted) return;
    if (!probe.ok) {
      _toast('读取失败：${probe.error}');
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EditorPage(
        initialDir: '/root/projects/${widget.projectName}',
        initialPath: path,
      ),
    ));
  }

  Widget _fieldLabel(String s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(s,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
    );
  }

  // ============================ 打包 ============================

  Widget _buildPanel() {
    final r = BuildRunner.I;
    final env = _env;
    final mine = r.active == widget.projectName;
    final otherBuilding = r.building && !mine;

    if (env != null && !env.rootfsInstalled) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('rootfs 未初始化：请先在主页完成环境安装',
              style: TextStyle(color: Color(0xFFFF7A7A))),
        ),
      );
    }
    if (otherBuilding) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('「${r.active}」正在构建中——同一时间只能有一个构建任务',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!r.building && r.status != BuildStatus.idle && mine) ...[
          _buildResultCard(r),
          const SizedBox(height: 12),
        ],
        if (!r.building) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('打包配置',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    'flutter build apk --no-shrink --release'
                    ' --target-platform=android-arm64\n'
                    '后端：${_backend == BuildBackend.termux ? 'Termux 裸原生（不经 proot）' : 'Proot 容器'}',
                    style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: Colors.grey.shade500, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _startBuild,
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('开始打包'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _cleaning ? null : _cleanCache,
                          icon: _cleaning
                              ? const SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.cleaning_services,
                                  size: 16),
                          label: const Text('清理缓存',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('缓存导致的"玄学失败"先清再试（flutter clean）',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
          ),
        ] else ...[
          _buildProgressCard(r),
        ],
        if (r.lines.isNotEmpty && mine) ...[
          const SizedBox(height: 12),
          _buildLogCard(r),
        ],
      ],
    );
  }

  Future<void> _startBuild() async {
    final env = _env;
    if (env == null || BuildRunner.I.building) return;
    if (!await BuildNotify.enabled) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('通知已关闭：退到桌面后将看不到构建进度通知'
            '（可在系统设置 → 应用通知中开启）'),
        duration: Duration(seconds: 4),
      ));
    }
    await BuildRunner.I.start(widget.projectName, env, _backend);
    if (mounted) setState(() {});
  }

  bool _cleaning = false;

  /// 清理构建缓存（flutter clean）：BuildRunner.clean 统一两后端命令，
  /// 结果 SnackBar 反馈。构建中按钮已禁用（方法内再拦一层）。
  Future<void> _cleanCache() async {
    final env = _env;
    if (env == null || _cleaning) return;
    setState(() => _cleaning = true);
    final err =
        await BuildRunner.I.clean(widget.projectName, env, _backend);
    if (!mounted) return;
    setState(() => _cleaning = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err ?? '已清理 build/ 与 .dart_tool（flutter clean）'),
      duration: Duration(seconds: err == null ? 2 : 4),
    ));
  }

  Widget _buildResultCard(BuildRunner r) {
    final ok = r.status == BuildStatus.done;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.check_circle : Icons.error_outline,
                  color: ok ? const Color(0xFF3DDC84) : const Color(0xFFFF7A7A),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  ok ? '上次打包成功' : '上次打包未成功',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: ok ? const Color(0xFF3DDC84) : const Color(0xFFFF7A7A)),
                ),
              ],
            ),
            if (ok && r.apkGuest != null) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const BuildPage(),
                )),
                icon: const Icon(Icons.install_mobile, size: 18),
                label: const Text('安装 / 查看详情'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(BuildRunner r) {
    final pct = r.prog.percent;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(r.prog.stage.label,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                Text('$pct%',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF4C8DFF))),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: r.prog.progress,
                minHeight: 8,
                backgroundColor: Colors.white10,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF4C8DFF)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('已用 ${BuildRunner.fmtDur(r.elapsedSec)}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                const SizedBox(width: 10),
                Text('通知栏可见进度 · 退出页面构建继续',
                    style: TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: Colors.grey.shade600)),
                const Spacer(),
                TextButton(
                  onPressed: () => BuildRunner.I.cancel(),
                  child: const Text('取消', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogCard(BuildRunner r) {
    final lines = r.lines.length > 30
        ? r.lines.sublist(r.lines.length - 30)
        : r.lines;
    return Card(
      color: const Color(0xFF0C0F13),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('最近日志（${r.lines.length} 行）',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const BuildPage(),
                  )),
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text('完整日志', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final l in lines)
              Text(l,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      height: 1.5,
                      color: Color(0xFFD6DEE8))),
          ],
        ),
      ),
    );
  }
}
