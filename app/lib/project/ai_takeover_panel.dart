import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ai_backend.dart';
import '../ai/ai_config.dart';
import '../ai/llm_client.dart';
import '../env/proot_bridge.dart';
import '../mcp/cloudflared_install.dart';
import '../mcp/mcp_schema.dart';
import '../mcp/mcp_server.dart';
import '../mcp/tunnel_service.dart';
import '../core/theme.dart';

/// 项目工作台 ·「AI 接管」面板（alpha.60）。
///
/// 与「远程协助」页的分工：
/// - 远程协助页 = **设备级开关**（起/停隧道、看隧道日志、首次风险确认）；
/// - 本面板 = **项目级上下文**（当前项目的接管状态、把这个项目交给 AI 的
///   提示词、远程操作记录）。
///
/// 架构决定：隧道是**设备级**的（一个端口、一个令牌），不是项目级。
/// 因此这里显示全局隧道状态 + 注入当前项目上下文，**不为每个项目开独立
/// 隧道**——多隧道意味着多令牌、多进程、端口管理，收益为零。
///
/// Bug 458（alpha.61）：本面板**不再跳转**「远程协助」页。
/// 用户反馈"点 AI 接管却跳到了远程协助页"，并猜测是 cloudflared 没装成功
/// 所致——猜测方向对，但根因不是安装失败，而是**这个按钮从一开始就是
/// 一个纯跳转**：开启/停止隧道的能力全在另一个页面里，本面板只负责导航。
/// 现已把「开启 / 停止 / 续期 / 复制地址」全部下沉到本面板就地完成，
/// 并就地暴露 cloudflared 的安装状态与安装入口（不再让用户猜"为什么开不了"）。
class AiTakeoverPanel extends StatefulWidget {
  final String projectName;

  const AiTakeoverPanel({super.key, required this.projectName});

  @override
  State<AiTakeoverPanel> createState() => _AiTakeoverPanelState();
}

/// 内置 LLM 三个输入框的**语义**（alpha.86）。
///
/// 存在的理由：以前每个字段的键盘类型是**调用点手写**的
/// （`TextInputType.url` / `TextInputType.text` + `secret: true`），
/// 于是"哪个字段算密钥"这件事散落在 UI 代码里，改一个漏一个。
/// 收进枚举后，[secureText] 与 [keyboardType] 成对定义，语义不再可能跑偏。
enum LlmFieldKind {
  /// 接口地址：必须用**普通**键盘。
  ///
  /// ⚠️ 这里绝不能给 secureText——`TextInputType.url` 在部分输入法上会走
  /// 安全键盘，而安全键盘常常不给 `/` `:` `.`，地址打不全。
  baseUrl,

  /// API Key：唯一需要遮挡的字段。
  ///
  /// 键盘类型用 `visiblePassword`：明确告诉输入法"是密码，但用普通键盘"，
  /// 比 `text` + obscure 的组合稳得多（见 [_aiField] 第 2 条）。
  apiKey,

  /// 模型名：纯标识符，普通键盘。
  model;

  bool get secureText => this == LlmFieldKind.apiKey;

  TextInputType get keyboardType => switch (this) {
        LlmFieldKind.baseUrl => TextInputType.url,
        LlmFieldKind.apiKey => TextInputType.visiblePassword,
        LlmFieldKind.model => TextInputType.text,
      };
}

class _AiTakeoverPanelState extends State<AiTakeoverPanel> {
  TunnelService get t => TunnelService.I;
  McpServer get mcp => McpServer.I;
  final ProotBridge _bridge = ProotBridge();

  /// UI 侧防连点（与 service 的 busy 互补）。
  bool _busy = false;

  /// cloudflared 是否已落位（宿主侧快速判态，不阻塞 UI）。
  bool _cfInstalled = false;
  bool _cfChecked = false;

  // ---- alpha.81 AI 后端配置（编辑器 AI 按钮用哪个后端）----
  AiConfig? _cfg;
  bool _testing = false;
  String _testResult = '';

  // ---- alpha.90 模型列表（不填也能选）----
  /// 拉取中（按钮转圈用）。
  bool _loadingModels = false;

  /// 已拉到的可用模型 id（空 = 还没拉成功过）。
  List<String> _models = const [];

  /// 拉取失败的原因（空 = 没失败）。
  String _modelsError = '';

  final TextEditingController _baseUrlCtl = TextEditingController();
  final TextEditingController _keyCtl = TextEditingController();
  final TextEditingController _modelCtl = TextEditingController();

  /// 用户动过输入框（alpha.82 / Bug 612）。
  ///
  /// 一旦为真，之后异步回来的配置**一律不许回填**——见 [_loadCfg]。
  bool _edited = false;

  /// 密钥是否明文显示。
  ///
  /// ⚠️ 这里只保留**会话内**的开关状态，不落盘：它是"当前这一次要不要
  /// 看一眼"，存下来反而多一份配置要维护。（曾经有过一个按目录存的
  /// `AiSecretPrefs`，删掉了——为一颗眼睛按钮加一个存储不值。）
  ///
  /// 默认仍是**明文**：真机反馈 `obscureText: true` 会触发输入法安全键盘，
  /// 而"打不进字"比"被旁边的人瞥见一眼"更致命——这是刻意的取舍，
  /// 眼睛按钮随时可点。
  bool _showKey = true;

  /// 停手 600ms 后静默保存（替代 onEditingComplete）。
  Timer? _saveTimer;

  String get _projRoot => '$kProjectsRootMcp/${widget.projectName}';

  @override
  void initState() {
    super.initState();
    // 隧道是服务层状态，UI 只是投影——切走再回来要能挂回
    t.onUiChanged = () {
      if (mounted) setState(() {});
    };
    _refreshCfState();
    _loadCfg();
  }

  Future<void> _loadCfg() async {
    final c = await AiConfigStore.load();
    // ⚠️ **用户已动过输入框就绝不回填**（alpha.82 / Bug 612 闪屏主因）：
    // 这个 load 是异步的（envInfo 走 MethodChannel）。用户若在它返回之前
    // 选了"内置 LLM"并开始敲 key，回填会用磁盘旧值把 `_cfg` 的 kind 改回
    // remoteMcp → 整块输入区瞬间消失，controller.text 也被冲掉。
    // 观感就是"闪一下、字没了"。
    if (!mounted || _edited) return;
    setState(() {
      _cfg = c;
      _baseUrlCtl.text = c.baseUrl;
      _keyCtl.text = c.apiKey;
      _modelCtl.text = c.model;
    });
  }

  /// 用户敲了字：标记已编辑 + 排一次静默保存。
  void _markEdited() {
    _edited = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 600),
      () => _persist(silent: true),
    );
  }

  AiConfig get _draft => (_cfg ?? AiConfig.unconfigured).copyWith(
        baseUrl: _baseUrlCtl.text,
        apiKey: _keyCtl.text,
        model: _modelCtl.text,
      );

  /// 保存配置。[silent] 用于"切换单选/输入框失焦"这类高频动作——
  /// 每次都弹 toast 会变成噪音，只有显式点保存才给反馈。
  Future<void> _persist({bool silent = false}) async {
    final c = _draft;
    _cfg = c;
    await AiConfigStore.save(c);
    if (!mounted || silent) return;
    _toast('已保存');
  }

  /// 测试连接：真的发一条最小请求（会消耗少量 token，所以是手动点的）。
  Future<void> _testConnection() async {
    final c = _draft;
    if (!c.llmReady) {
      setState(() => _testResult = '先填接口地址与密钥');
      return;
    }
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final backend = BuiltinLlmBackend(c);
    final res = await backend.run(
      const AiJob(
        kind: AiJobKind.complete,
        path: 'connectivity-test',
        content: 'void main() {}',
        cursorOffset: 0,
        language: 'dart',
      ),
      transport: IoLlmTransport(timeout: const Duration(seconds: 20)),
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      // 失败时把配置也带上一句：真机上"测试失败"最常见的原因就是
      // 地址或密钥本身写错，用户对着提示还得自己回想刚才填了什么。
      _testResult = res.kind == AiOutcomeKind.failure
          ? '失败：${res.message}'
          : '连接正常 · 模型 ${c.model.trim().isEmpty ? "(未填)" : c.model.trim()}';
    });
  }

  /// 拉取可用模型列表（alpha.90）。
  ///
  /// 用户问："别的程序可以不填模型名然后自己选"——这版就做这个。
  ///
  /// 只要求**地址 + 密钥**（不要求模型名）：这正是"不知道该填什么"的
  /// 时候该按的按钮。拉到了就直接让用户从列表里挑。
  Future<void> _loadModels() async {
    final baseUrl = _baseUrlCtl.text.trim();
    final key = _keyCtl.text.trim();
    if (baseUrl.isEmpty || key.isEmpty) {
      setState(() => _modelsError = '先填接口地址与密钥，模型名可以留空');
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelsError = '';
    });
    final r = await fetchModels(
      baseUrl: baseUrl,
      apiKey: key,
      transport: IoLlmTransport(timeout: const Duration(seconds: 20)),
    );
    if (!mounted) return;
    setState(() {
      _loadingModels = false;
      if (r.ok) {
        _models = r.models;
        _modelsError = '';
        // 当前填的模型不在列表里 → 已经能确定它是错的，直接告诉用户。
        // 这正是"deepseek-chat 已弃用"那类问题的即时反馈。
        final cur = _modelCtl.text.trim();
        if (cur.isNotEmpty && !r.models.contains(cur)) {
          _modelsError = '当前填的「$cur」不在该接口的可用列表里，建议换一个';
        }
      } else {
        _models = const [];
        _modelsError = r.error;
      }
    });
  }

  @override
  void dispose() {
    t.onUiChanged = null;
    _saveTimer?.cancel();
    _baseUrlCtl.dispose();
    _keyCtl.dispose();
    _modelCtl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  /// 探测 cloudflared 是否已装（只在装了 rootfs 时有意义）。
  Future<void> _refreshCfState() async {
    try {
      final env = await _bridge.envInfo();
      if (!mounted) return;
      setState(() {
        _cfInstalled =
            env.rootfsInstalled && CloudflaredInstall.installedSync(env);
        _cfChecked = true;
      });
    } catch (_) {
      if (mounted) setState(() => _cfChecked = true);
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已复制$what'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  String _handoff() => buildHandoffPrompt(
        tunnelUrl: t.url,
        token: mcp.token,
        projectName: widget.projectName,
        projectRoot: _projRoot,
      );

  // ---------------- 就地操作（Bug 458） ----------------

  /// 首次启用前的强制风险确认——与远程协助页同一套口径。
  Future<bool> _confirmRisk() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: FoaColors.of(ctx).warning),
          const SizedBox(width: 8),
          const Text('开启前请确认'),
        ]),
        content: const SingleChildScrollView(
          child: Text(
            '开启后，任何拿到【隧道地址 + 令牌】的人都能以本应用的身份，\n'
            '在这台手机的容器内执行任意命令、读写你的项目文件。\n\n'
            '请注意：\n'
            '· 这是「AI 接管」的设计目的，不是漏洞；\n'
            '· 破坏范围限于容器内——Android 宿主文件与系统不受影响；\n'
            '· 会话 30 分钟后自动停止，你也可以随时手动停止；\n'
            '· 所有远程操作都会显示在本面板的「远程操作记录」中。\n\n'
            // Bug 470：用户实测反馈分不清它和「远程协助」（整机级通道）。
            '本功能只作用于**当前这个项目**。若你要整台设备级别的通道，\n'
            '请用首页的「远程协助」。\n\n'
            '请仅在完全信任对方时开启，用完立即停止。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('我了解风险，开启'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _snack(String msg, {bool long = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: long ? 6 : 3),
    ));
  }

  /// 就地在面板内开启接管（原先这里是 push 到另一个页面）。
  Future<void> _startInline() async {
    if (_busy || t.busy || t.status == TunnelStatus.running) return;
    if (!await _confirmRisk()) return;
    if (!mounted) return;

    setState(() => _busy = true);
    try {
      final env = await _bridge.envInfo();
      if (!mounted) return;
      if (!env.rootfsInstalled) {
        _snack('容器环境未就绪：请先完成环境安装');
        return;
      }
      final err = await t.start(projectRoot: _projRoot, env: env);
      if (!mounted) return;
      if (err != null) {
        _snack(err, long: true);
      } else {
        _snack('AI 接管已开启', long: false);
      }
      await _refreshCfState();
    } catch (e) {
      _snack('启动失败：$e', long: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopInline() async {
    setState(() => _busy = true);
    try {
      await t.stop(reason: '用户手动停止');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TunnelStatus>(
      valueListenable: t.statusN,
      builder: (ctx, st, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // alpha.81：先让用户看到"AI 按钮用的是哪个后端"，再讲隧道
          _backendCard(),
          const SizedBox(height: 12),
          _statusCard(st),
          const SizedBox(height: 12),
          _handoffCard(st),
          const SizedBox(height: 12),
          _auditCard(),
          const SizedBox(height: 12),
          _boundaryCard(),
        ],
      ),
    );
  }

  // ---------------- ⓪ AI 后端（alpha.81：编辑器 AI 按钮用哪个） ----------------

  /// AI 后端二选一 + 内置 LLM 的三个参数。
  ///
  /// 放**最上面**：用户从编辑器点 AI 按钮进来第一眼就该看到"我现在用的
  /// 是哪个"，而不是先读一段隧道说明才发现自己没配后端。
  ///
  /// 两种后端的代价必须写在脸上——尤其"内置 LLM 会把代码发到你填的
  /// 那个接口""密钥明文存本机"，这是知情同意，不是免责声明。
  Widget _backendCard() {
    final c = _cfg ?? AiConfig.unconfigured;
    final muted = FoaColors.of(context).muted;
    final llm = c.kind == AiBackendKind.builtinLlm;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_awesome, size: 20, color: Color(0xFF4C8DFF)),
                SizedBox(width: 8),
                Expanded(
                  child: Text('AI 后端',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '决定编辑器里 ✨ 按钮（单点补全 / 长按派活）把活交给谁。',
              style: TextStyle(fontSize: 12, color: muted),
            ),
            const SizedBox(height: 4),
            // RadioGroup + Radio（Flutter 3.32 起的新写法）：
            // RadioListTile 的 groupValue/onChanged 已被标记废弃。
            RadioGroup<AiBackendKind>(
              groupValue: c.kind,
              onChanged: (v) => _setKind(v!),
              child: Column(
                children: [
                  _radioRow(
                    AiBackendKind.remoteMcp,
                    '远程 MCP（走下面的 AI 接管）',
                    '把要求写进项目的 .foa/ai-inbox.md，等已连隧道的 AI 客户端领取。'
                        '异步、不会自动改你的文件，代码不外发到第三方。',
                    muted,
                  ),
                  _radioRow(
                    AiBackendKind.builtinLlm,
                    '内置 LLM（自己填密钥）',
                    'App 直接调 OpenAI 兼容接口，即时返回补全结果。'
                        '代码会发到你填的地址，密钥明文存本机。',
                    muted,
                  ),
                ],
              ),
            ),
            if (llm) ...[
              const SizedBox(height: 4),
              _aiField(_baseUrlCtl, '接口地址', 'https://api.deepseek.com/v1',
                  LlmFieldKind.baseUrl),
              const SizedBox(height: 8),
              _aiField(_keyCtl, 'API Key', 'sk-...', LlmFieldKind.apiKey),
              const SizedBox(height: 8),
              // alpha.90：模型名不再要求用户自己查文档。
              // 布局 = 输入框 + 「获取模型」按钮（同行），拉到之后下方出可选项。
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _aiField(_modelCtl, '模型名', '点右侧「获取模型」自动列出',
                        LlmFieldKind.model),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    // 与输入框文字基线对齐（输入框有 label，自身略高）
                    padding: const EdgeInsets.only(top: 4),
                    child: OutlinedButton.icon(
                      onPressed: _loadingModels ? null : _loadModels,
                      icon: _loadingModels
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_for_offline_outlined,
                              size: 16),
                      label: Text(_loadingModels ? '获取中…' : '获取模型'),
                    ),
                  ),
                ],
              ),
              if (_modelsError.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _modelsError,
                  style: TextStyle(
                    fontSize: 12,
                    color: FoaColors.of(context).danger,
                  ),
                ),
              ],
              if (_models.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '可用模型（点选填入）',
                  style: TextStyle(
                    fontSize: 12,
                    color: FoaColors.of(context).muted,
                  ),
                ),
                const SizedBox(height: 6),
                // 用 Wrap 而不是 Dropdown：手机上手指点选更快，
                // 且模型数量多时会自动换行，不用滚一个长下拉。
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in _models) _modelChip(m),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_tethering, size: 16),
                    label: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _persist(),
                    icon: const Icon(Icons.save_outlined, size: 16),
                    label: const Text('保存'),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await AiConfigStore.clearKey();
                      _keyCtl.clear();
                      // 清空也是"用户动过"，否则下次回填会把旧 key 又写回来
                      _edited = true;
                      if (mounted) setState(() {});
                      _toast('已清空密钥');
                    },
                    icon: const Icon(Icons.key_off, size: 16),
                    label: const Text('清空密钥'),
                  ),
                ],
              ),
              if (_testResult.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _testResult,
                    style: TextStyle(
                      fontSize: 12,
                      color: _testResult.startsWith('失败')
                          ? const Color(0xFFCF6679)
                          : const Color(0xFF3DDC84),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 后端单选行：整行可点（比只点小圆点好按，手机上尤其明显）。
  Widget _radioRow(
    AiBackendKind kind,
    String title,
    String subtitle,
    Color muted,
  ) =>
      InkWell(
        onTap: () => _setKind(kind),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 只给 value：groupValue / onChanged 由 RadioGroup 提供
              Radio<AiBackendKind>(value: kind),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(fontSize: 11, color: muted)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  /// 一个参数输入框。
  ///
  /// ⚠️ 四道反闪屏措施（alpha.82 / Bug 612，真机反馈"输入 API Key 时
  /// 闪屏无法输入"），改这里之前先读一遍：
  /// 1. **必须给 key**：父级会因隧道回调 / 切后端单选而重建，没有稳定身份
  ///    时 Element 身份丢失 → 焦点回收 → 键盘收起再弹出，观感即"闪"。
  /// 2. **密钥默认明文**（[_showKey]）：`obscureText` 触发输入法安全键盘。
  ///    键盘类型用 `visiblePassword`——明确告诉输入法"是密码，但用普通
  ///    键盘"，比 `text` + obscure 的组合稳得多。
  /// 3. **不挂 onEditingComplete**：该回调在部分输入法上会触发"完成/收键盘"
  ///    动作；保存改成停手 600ms 静默写（见 [_markEdited]）。
  /// 4. **关联想 / 自动更正 / 个性化学习**：候选栏反复高度变化也会带动
  ///    布局跳动，且密钥本来就不该被学习。
  ///
  /// [secureText] 必须**只对密钥**开（alpha.86 修正）：非密钥字段被
  /// 标成安全输入时，输入法会切到安全键盘——而安全键盘**常常不提供
  /// `/` `:` `.`**，接口地址根本打不全。这个参数与 [LlmFieldKind] 的
  /// 语义绑在一起，别再手写散落的布尔值。
  Widget _aiField(
    TextEditingController ctl,
    String label,
    String hint,
    LlmFieldKind kind,
  ) {
    final secureText = kind.secureText;
    return TextField(
      key: ValueKey<String>('ai-field-$label'),
      controller: ctl,
      obscureText: secureText && !_showKey,
      keyboardType: kind.keyboardType,
      enableSuggestions: false,
      autocorrect: false,
      enableIMEPersonalizedLearning: false,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11),
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: secureText
            ? IconButton(
                tooltip: _showKey ? '隐藏密钥' : '显示密钥',
                icon: Icon(
                  _showKey ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(() => _showKey = !_showKey),
              )
            : null,
      ),
      onChanged: (_) => _markEdited(),
    );
  }

  /// 一个可点选的模型标签（alpha.90）。
  ///
  /// 点了就填进输入框——比让用户手抄模型名强得多，
  /// 也不会再出现"照着我们给的示例填了个已弃用名字"这种事。
  Widget _modelChip(String id) {
    final selected = _modelCtl.text.trim() == id;
    final c = FoaColors.of(context);
    return InkWell(
      key: ValueKey<String>('model-chip-$id'),
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        setState(() => _modelCtl.text = id);
        _markEdited();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : c.muted,
          ),
        ),
        child: Text(
          id,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
      ),
    );
  }

  void _setKind(AiBackendKind kind) {
    setState(() => _cfg = (_cfg ?? AiConfig.unconfigured).copyWith(kind: kind));
    _persist(silent: true);
  }

  // ---------------- ① 隧道状态 ----------------

  Widget _statusCard(TunnelStatus st) {
    final running = st == TunnelStatus.running;
    final (icon, color, label) = switch (st) {
      TunnelStatus.idle => (Icons.cloud_off, Colors.grey, '未开启'),
      TunnelStatus.installing => (
          Icons.downloading,
          const Color(0xFF64B5F6),
          '正在安装组件…'
        ),
      TunnelStatus.starting => (
          Icons.hourglass_top,
          const Color(0xFFFFA000),
          '正在建立隧道…'
        ),
      TunnelStatus.running => (
          Icons.cloud_done,
          const Color(0xFF3DDC84),
          '已开启'
        ),
      TunnelStatus.error => (
          Icons.error_outline,
          const Color(0xFFCF6679),
          '已中断'
        ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('AI 接管 · $label',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (running && t.remainSec != null)
                  Text('剩余 ${remainLabel(t.remainSec)}',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted)),
              ],
            ),
            const SizedBox(height: 8),
            if (running && t.url != null) ...[
              SelectableText(
                t.url!,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFF3DDC84)),
              ),
              const SizedBox(height: 4),
              Text('这个地址对公网开放，可让你的 AI 接入这台设备。',
                  style: TextStyle(
                      fontSize: 12, color: FoaColors.of(context).muted)),
            ] else
              Text(
                '开启后，你的 AI 客户端就能读取本项目文件、在容器内执行命令、'
                '调用故障诊断——相当于把「这台手机的开发环境」交给它。',
                style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: FoaColors.of(context).muted),
              ),
            // Bug 458：把 cloudflared 状态就地摆明，不让用户猜"为什么开不了"。
            if (_cfChecked && st == TunnelStatus.idle) ...[
              const SizedBox(height: 8),
              _cfStateRow(),
            ],
            if (t.error != null) ...[
              const SizedBox(height: 6),
              Text('错误：${t.error}',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFFCF6679))),
            ],
            const SizedBox(height: 12),
            // Bug 458：全部就地完成，不再跳转「远程协助」页。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!t.busy && !running)
                  FilledButton.icon(
                    onPressed: _busy ? null : _startInline,
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: Text(st == TunnelStatus.error ? '重新开启' : '开启 AI 接管'),
                  ),
                if (t.busy || running) ...[
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _stopInline,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('停止'),
                  ),
                  if (running)
                    OutlinedButton.icon(
                      onPressed: () => t.extend(),
                      icon: const Icon(Icons.timer_outlined, size: 18),
                      label: const Text('续期 30 分钟'),
                    ),
                  if (running && t.url != null)
                    OutlinedButton.icon(
                      onPressed: () => _copy(t.url!, '隧道地址'),
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text('复制地址'),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// cloudflared 组件状态行：已装显示版本位；未装给就地安装入口。
  Widget _cfStateRow() {
    final ok = _cfInstalled;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.info_outline,
          size: 15,
          color: ok ? const Color(0xFF3DDC84) : const Color(0xFFFFA000),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ok
                ? '隧道组件 cloudflared 已就绪'
                : '首次开启会自动下载隧道组件 cloudflared'
                    '（约 36MB，只下一次）',
            style: TextStyle(
                fontSize: 11.5,
                color: FoaColors.of(context).muted,
                height: 1.4),
          ),
        ),
      ],
    );
  }

  // ---------------- ② 交给你的 AI（预填提示词） ----------------

  Widget _handoffCard(TunnelStatus st) {
    final ready = st == TunnelStatus.running;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('把这个项目交给你的 AI',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '复制下面这段粘贴给你的 AI 客户端。里面已经写好：隧道地址、'
              '令牌、项目路径、可用工具、以及「慢是正常的」「构建与预览互斥」'
              '这些它必须知道的事——省掉它自己摸索的几轮往返。',
              style: TextStyle(
                  fontSize: 12,
                  color: FoaColors.of(context).muted,
                  height: 1.45),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF101418),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                ready
                    ? '项目：${widget.projectName}\n'
                        '路径：$_projRoot\n'
                        '地址：${t.url}/mcp\n'
                        '鉴权：Authorization: Bearer ${mcp.token}'
                    : '（开启接管后，这里会显示将要发送给 AI 的完整说明）',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.5,
                  color: Color(0xFFCAD3D5),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: ready ? () => _copy(_handoff(), '完整接入说明') : null,
                  icon: const Icon(Icons.assignment_ind, size: 18),
                  label: const Text('复制接入说明'),
                ),
                OutlinedButton.icon(
                  onPressed: ready ? () => _copy(mcp.token, '令牌') : null,
                  icon: const Icon(Icons.key, size: 18),
                  label: const Text('仅复制令牌'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- ③ 远程操作记录 ----------------

  Widget _auditCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('远程操作记录',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('最近 ${mcp.audit.length} 条 · 实时',
                    style: TextStyle(
                        fontSize: 11, color: FoaColors.of(context).muted)),
              ],
            ),
            const SizedBox(height: 4),
            Text('AI 在你设备上的每次操作都会出现在这里——这是你的监督窗口。',
                style: TextStyle(
                    fontSize: 12, color: FoaColors.of(context).muted)),
            const SizedBox(height: 10),
            ValueListenableBuilder<int>(
              valueListenable: mcp.auditRevisionN,
              builder: (ctx, _, __) {
                if (mcp.audit.isEmpty) {
                  return Text('（暂无记录）',
                      style: TextStyle(
                          fontSize: 12, color: FoaColors.of(context).muted));
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: mcp.audit.reversed
                      .take(30)
                      .map((a) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              '${a.timeLabel}  ${a.tool}  ${a.summary}',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                height: 1.35,
                                color: a.ok
                                    ? const Color(0xFFCAD3D5)
                                    : const Color(0xFFCF6679),
                              ),
                            ),
                          ))
                      .toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- ④ 能力边界 ----------------

  Widget _boundaryCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AI 能做到 / 做不到',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _li(true, '读、写、列本项目文件（含所有子目录）'),
            _li(true, '在容器内执行 shell 命令（单条 ≤600 秒）'),
            _li(true, '调用故障诊断，一次拿到 8 项环境报告'),
            _li(true, '查看设备与 Flutter SDK 信息'),
            _li(false, '访问 Android 宿主文件、相册、其他 App 数据', note: '容器内根本看不到，不是权限问题'),
            _li(false, '直接触发 APK 构建', note: '会抢 Flutter 启动锁并阻塞你，需你亲自操作'),
            _li(false, '同时执行多条命令', note: '容器为单队列，并发返回 DeviceBusy'),
            const SizedBox(height: 6),
            Text(
              '可用工具共 ${kTools.length} 项：'
              '${kTools.map((t) => t.name).join('、')}',
              style: TextStyle(
                  fontSize: 11,
                  color: FoaColors.of(context).muted,
                  height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _li(bool ok, String text, {String? note}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              ok ? Icons.check_circle_outline : Icons.remove_circle_outline,
              size: 15,
              color: ok ? const Color(0xFF3DDC84) : FoaColors.of(context).muted,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12, height: 1.4),
                children: [
                  TextSpan(text: text),
                  if (note != null)
                    TextSpan(
                      text: '（$note）',
                      style: TextStyle(color: FoaColors.of(context).muted),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
