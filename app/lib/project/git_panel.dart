import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../env/proot_bridge.dart';
import '../toolchain/toolchain_ensure.dart';
import 'git_remote.dart';

/// 项目 Git 面板（alpha.93）：仓库状态 / 选文件提交 / 提交历史 / 远端同步。
///
/// 为什么要有这一区：以前改代码只能靠「导出源码工程」做备份，
/// 改崩了没法回退；而容器里 `git` 已经在 Step 7 就装好了
/// （flutter 自己构建时要它），只是没暴露给用户。
///
/// 两条硬约束（与 icon_replacer 同源）：
/// 1. **所有命令都走 `ProotBridge.exec`** —— Dart 层不 Process.start，
///    也不自己去读写容器里的文件（FsBridge 只走文本，且 Kotlin 侧有
///    `/root/projects` 白名单）。git 自己会写工作区，Dart 只解析 stdout。
/// 2. **零三方依赖**（仓库原则）：不引 `git` 的 Dart 封装包，
///    直接调容器里那个真 git，输出用 `--porcelain` / `--pretty=format`
///    这类**为机器解析而生**的稳定格式。
///
/// 能力边界（如实写在 UI 上，不吹）：
/// - 本地：只做 init / status / add / commit / log；
/// - 远端（alpha.94 补上）：配置远端 + push / pull，只支持 HTTPS + PAT；
/// - **不做分支管理**（新建/切换/删除分支）：切分支会动工作区文件，
///   和编辑器里打开的文件打架，手机上不好收场。
/// - pull 只走 fast-forward：分叉了就明确报错，不在手机上解冲突。
/// - 不做「丢弃改动」：那是不可逆操作，误点一次就丢工作，宁愿不给。
class GitPanel extends StatefulWidget {
  final String projectName;

  const GitPanel({super.key, required this.projectName});

  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  final ProotBridge _bridge = ProotBridge();
  final TextEditingController _msg = TextEditingController();

  /// 提交身份（第一次提交必须要有，git 否则报
  /// "Please tell me who you are"）。存在仓库的 .git/config 里，
  /// 换项目要重新填——所以本面板把它做成可见可编辑的一行。
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();

  bool _loading = true;
  String _error = '';
  GitSnapshot _snap = const GitSnapshot.empty();

  /// 已勾选的待提交文件（路径集合）。
  final Set<String> _picked = <String>{};

  /// 上一次见过的文件列表：刷新后只保留仍然存在的勾选项，
  /// 否则每次刷新用户的勾选全被清掉。
  Set<String> _seen = <String>{};

  bool _busy = false;
  String _result = '';
  bool _resultOk = true;

  // ---------------- 远端（alpha.94）----------------
  GitRemoteInfo _remote = GitRemoteInfo.empty;
  final TextEditingController _remoteName =
      TextEditingController(text: 'origin');
  final TextEditingController _remoteUrl = TextEditingController();
  final TextEditingController _remoteUser = TextEditingController();
  final TextEditingController _remoteToken = TextEditingController();
  bool _remoteBusy = false;

  /// 本次进面板有没有 fetch 过。没有的话"领先/落后"是**上次 fetch 留下
  /// 的旧数字**（实测：远端有新提交但不 fetch，`origin/main` 不动，
  /// 会显示"与远端一致"）——所以没 fetch 过必须如实标注，不能装作新鲜。
  bool _fetched = false;

  GitRepo get _repo =>
      GitRepo(bridge: _bridge, projectName: widget.projectName);

  GitRemote get _rem => GitRemote(bridge: _bridge, projectName: widget.projectName);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _msg.dispose();
    _name.dispose();
    _email.dispose();
    _remoteName.dispose();
    _remoteUrl.dispose();
    _remoteUser.dispose();
    _remoteToken.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    GitSnapshot s;
    try {
      s = await _repo.status();
    } catch (e) {
      // 容器没装好时 ProotBridge.exec 会直接抛 PlatformException
      // （不是返回 exitCode≠0）——不接住就是一片空白，用户不知道发生了什么。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '执行 git 失败：$e';
      });
      return;
    }
    // 远端信息单独一次 exec：本地状态那趟命令里没有网络相关的东西，
    // 混在一起会让"远端连不上"把"本地状态"也一起拖成失败。
    GitRemoteInfo ri = GitRemoteInfo.empty;
    if (s.isRepo) {
      try {
        ri = await _rem.info();
      } catch (_) {
        // 同上：容器没装好时 exec 直接抛，不该让整个面板白屏
      }
    }
    if (!mounted) return;
    setState(() {
      _snap = s;
      _remote = ri;
      // 仓库已经有远端就把它回填进输入框：用户接下来多半是要改它或
      // 为它配凭据，留空让人重打一遍 HTTPS 地址纯属折磨。
      if (ri.hasRemote && _remoteUrl.text.isEmpty) {
        _remoteUrl.text = ri.remotes.first.url;
        if (_remoteName.text.isEmpty) _remoteName.text = ri.remotes.first.name;
      }
      _loading = false;
      _error = s.error;
      if (s.userName.isNotEmpty && _name.text.isEmpty) {
        _name.text = s.userName;
      }
      if (s.userEmail.isNotEmpty && _email.text.isEmpty) {
        _email.text = s.userEmail;
      }
      _syncPicked();
    });
  }

  /// 勾选集合与最新文件列表对齐：新文件默认勾上，消失的文件移除。
  ///
  /// 第一次进来（_seen 为空）时全部勾上——提交是主路径，
  /// 让用户挨个点是没必要的摩擦。
  void _syncPicked() {
    final now = _snap.files.map((f) => f.path).toSet();
    if (_seen.isEmpty) {
      _picked.addAll(now);
    } else {
      _picked.removeWhere((p) => !now.contains(p));
      for (final p in now) {
        if (!_seen.contains(p)) _picked.add(p);
      }
    }
    _seen = now;
  }

  Future<void> _initRepo() async {
    setState(() {
      _busy = true;
      _result = '';
    });
    final r = await _repo.init(
      name: _name.text.trim().isEmpty ? GitRepo.defaultUserName : _name.text.trim(),
      email:
          _email.text.trim().isEmpty ? GitRepo.defaultUserEmail : _email.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultOk = r.ok;
      _result = r.msg;
    });
    await _load();
  }

  Future<void> _commit() async {
    final msg = _msg.text.trim();
    if (msg.isEmpty) {
      setState(() {
        _resultOk = false;
        _result = '先写一句提交说明，空提交没法回溯。';
      });
      return;
    }
    if (_picked.isEmpty) {
      setState(() {
        _resultOk = false;
        _result = '没有勾选任何文件。';
      });
      return;
    }
    setState(() {
      _busy = true;
      _result = '';
    });
    final r = await _repo.commit(
      message: msg,
      paths: _picked.toList(),
      name: _name.text.trim(),
      email: _email.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultOk = r.ok;
      _result = r.msg;
      if (r.ok) {
        _msg.clear();
        _picked.clear();
      }
    });
    await _load();
  }

  Future<void> _installGit() async {
    setState(() {
      _busy = true;
      _result = '';
    });
    // 复用构建链路里那一套（apt 装 git + 配国内镜像），
    // 不在面板里另写一份安装逻辑。
    final err = await ToolchainEnsure().git();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _resultOk = err == null;
      _result = err ?? 'git 已就绪。';
    });
    await _load();
  }

  // ============================ 远端（alpha.94）============================

  /// 统一的「忙 + 结果 + 刷新」外壳（四个远端操作都一样）。
  Future<void> _remoteOp(Future<({bool ok, String msg})> Function() f) async {
    setState(() {
      _remoteBusy = true;
      _result = '';
    });
    final r = await f();
    if (!mounted) return;
    setState(() {
      _remoteBusy = false;
      _resultOk = r.ok;
      _result = r.msg;
    });
    await _load();
  }

  /// 当前要用的远端名（没填就退回第一个已配的）。
  String get _remoteNameNow {
    final t = _remoteName.text.trim();
    if (t.isNotEmpty) return t;
    return _remote.hasRemote ? _remote.remotes.first.name : 'origin';
  }

  Future<void> _setRemote() async {
    final url = _remoteUrl.text.trim();
    final name = _remoteName.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() {
        _resultOk = false;
        _result = '远端名称和地址都要填。';
      });
      return;
    }
    if (!url.startsWith('https://') && !url.startsWith('http://')) {
      setState(() {
        _resultOk = false;
        _result = '只支持 HTTPS 地址（形如 https://github.com/你/仓库.git）。'
            'SSH 需要密钥，手机上不方便生成也不好登记公钥，本面板不做。';
      });
      return;
    }
    await _remoteOp(() => _rem.setRemote(name: name, url: url));
  }

  Future<void> _removeRemote() async {
    final name = _remoteNameNow;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除远端？'),
            content: Text('只会删掉「$name」这个地址记录，'
                '本地的提交和文件都不会动。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('删除')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await _remoteOp(() => _rem.removeRemote(name));
  }

  Future<void> _saveCredential() async {
    final url = _remoteUrl.text.trim();
    final host = GitRemote.hostOf(url);
    final user = _remoteUser.text.trim();
    final token = _remoteToken.text.trim();
    if (host.isEmpty) {
      setState(() {
        _resultOk = false;
        _result = '没能从地址里解析出主机名，检查一下地址格式。';
      });
      return;
    }
    if (token.isEmpty) {
      setState(() {
        _resultOk = false;
        _result = '口令（PAT）不能为空：现在各平台都不让用账号密码推代码了。';
      });
      return;
    }
    await _remoteOp(
        () => _rem.saveCredential(host: host, user: user, token: token));
  }

  Future<void> _push() async {
    final branch = _snap.branch;
    if (branch.isEmpty) {
      setState(() {
        _resultOk = false;
        _result = '还没有任何提交（HEAD 没指向分支），先提交一次再推送。';
      });
      return;
    }
    await _remoteOp(() => _rem.push(remote: _remoteNameNow, branch: branch));
  }

  Future<void> _fetch() async {
    await _remoteOp(() async {
      final r = await _rem.fetch(_remoteNameNow);
      if (r.ok) _fetched = true;
      return r;
    });
  }

  Future<void> _pull() async {
    final branch = _snap.branch;
    if (branch.isEmpty) {
      setState(() {
        _resultOk = false;
        _result = '还没有任何提交，没有可拉取的分支。';
      });
      return;
    }
    await _remoteOp(() => _rem.pull(remote: _remoteNameNow, branch: branch));
  }

  // ============================ UI ============================

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _snap.isRepo ? '仓库：${_snap.branch}' : '还不是 Git 仓库',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_error.isNotEmpty) _banner(_error, ok: false),
          if (!_snap.gitFound) _noGitCard(),
          if (_snap.gitFound && !_snap.isRepo) _initCard(),
          if (_snap.isRepo) ...[
            _statusCard(),
            const SizedBox(height: 12),
            _changesCard(),
            const SizedBox(height: 12),
            _remoteCard(),
            const SizedBox(height: 12),
            _logCard(),
          ],
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 12),
            _banner(_result, ok: _resultOk),
          ],
        ],
      ),
    );
  }

  Widget _banner(String s, {required bool ok}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (ok ? FoaColors.of(context).success : FoaColors.of(context).danger)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(s, style: const TextStyle(fontSize: 11.5, height: 1.5)),
    );
  }

  Widget _noGitCard() {
    return _card(
      icon: Icons.downloading_outlined,
      title: '容器里还没有 git',
      subtitle: 'flutter 构建本来就要它，构建前会自动补装',
      children: [
        const Text(
          '面板里的所有操作都要容器内的 git。点下面按钮会走和构建前'
          '相同的安装流程（apt + 国内镜像源），装完自动刷新。',
          style: TextStyle(fontSize: 11.5, height: 1.5),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy ? null : _installGit,
            icon: const Icon(Icons.download_outlined, size: 16),
            label: Text(_busy ? '安装中…' : '安装 git',
                style: const TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _initCard() {
    return _card(
      icon: Icons.account_tree_outlined,
      title: '初始化仓库',
      subtitle: '在当前工程目录建 .git，之后就能随时回退',
      children: [
        _field(_name, '提交者名称', hint: GitRepo.defaultUserName),
        const SizedBox(height: 10),
        _field(_email, '提交者邮箱', hint: GitRepo.defaultUserEmail),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy ? null : _initRepo,
            icon: const Icon(Icons.create_new_folder_outlined, size: 16),
            label: Text(_busy ? '初始化中…' : 'git init',
                style: const TextStyle(fontSize: 12)),
          ),
        ),
        _hint('初始化只会做三件事：建 .git、写入上面的提交者身份、'
            '如果工程里没有 .gitignore 就补一份（忽略 .dart_tool/ 与 build/，'
            '否则一次 add -A 会把构建产物全塞进仓库）。'
            '不会碰你的任何源码文件。'),
      ],
    );
  }

  Widget _statusCard() {
    final dirty = _snap.files.length;
    return _card(
      icon: Icons.info_outline,
      title: '仓库状态',
      // alpha.94：远端已经能用了，这句"不涉及远端"是过时的，留着会让人
      // 以为下面那张远端卡不存在。
      subtitle: '本地状态；远端同步在下面单独一区',
      children: [
        _row('当前分支', _snap.branch.isEmpty ? '（无提交，HEAD 未指向分支）' : _snap.branch),
        const SizedBox(height: 6),
        _row('未提交改动', dirty == 0 ? '工作区干净' : '$dirty 个文件'),
        const SizedBox(height: 6),
        _row('提交历史', _snap.log.isEmpty ? '还没有提交' : '${_snap.log.length} 条（最多显示 ${GitRepo.logLimit} 条）'),
        const SizedBox(height: 12),
        _field(_name, '提交者名称', hint: GitRepo.defaultUserName),
        const SizedBox(height: 10),
        _field(_email, '提交者邮箱', hint: GitRepo.defaultUserEmail),
      ],
    );
  }

  Widget _changesCard() {
    final files = _snap.files;
    return _card(
      icon: Icons.rule_outlined,
      title: '改动与提交',
      subtitle: files.isEmpty ? '工作区干净，没有可提交的内容' : '勾选要提交的文件，写一句说明',
      children: [
        if (files.isEmpty)
          const Text('没有改动。改完代码回到这一区刷新即可。',
              style: TextStyle(fontSize: 11.5, height: 1.5))
        else ...[
          Row(
            children: [
              TextButton(
                onPressed: () => setState(
                    () => _picked.addAll(files.map((f) => f.path))),
                child: const Text('全选', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: () => setState(() => _picked.clear()),
                child: const Text('全不选', style: TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              Text('已选 ${_picked.length}/${files.length}',
                  style: TextStyle(
                      fontSize: 11, color: FoaColors.of(context).muted)),
            ],
          ),
          Container(
            constraints: const BoxConstraints(maxHeight: 240),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: files.length,
              itemBuilder: (context, i) {
                final f = files[i];
                return CheckboxListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  value: _picked.contains(f.path),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _picked.add(f.path);
                    } else {
                      _picked.remove(f.path);
                    }
                  }),
                  title: Text(f.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace')),
                  subtitle: Text(f.label,
                      style: TextStyle(
                          fontSize: 10, color: FoaColors.of(context).muted)),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _field(_msg, '提交说明', hint: '例如：修了首页空列表的崩溃', maxLines: 2),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _commit,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check, size: 16),
              label: Text(_busy ? '提交中…' : '提交勾选的文件',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _logCard() {
    return _card(
      icon: Icons.history_outlined,
      title: '提交历史',
      subtitle: '最近 ${GitRepo.logLimit} 条，回退请在电脑上用完整 git 客户端',
      children: [
        if (_snap.log.isEmpty)
          const Text('还没有任何提交。', style: TextStyle(fontSize: 11.5))
        else
          ..._snap.log.map((e) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.hash,
                        style: const TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            color: Color(0xFF4C8DFF))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.subject,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5)),
                          Text('${e.date} · ${e.author}',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: FoaColors.of(context).muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
      ],
    );
  }

  /// 远端与同步（alpha.94）。
  ///
  /// 放在「改动与提交」之后、「提交历史」之前：提交完下一步自然就是"推上去"，
  /// 而历史是回看用的，不该挡在这条主路径中间。
  Widget _remoteCard() {
    final host = GitRemote.hostOf(_remoteUrl.text.trim());
    final branch = _snap.branch;
    final busy = _remoteBusy || _busy;
    return _card(
      icon: Icons.cloud_outlined,
      title: '远端与同步',
      subtitle: _remote.hasRemote ? _remote.syncLabel : '还没配远端，只能本地版本管理',
      children: [
        if (_remote.hasRemote) ...[
          ..._remote.remotes.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.name,
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(GitRemote.scrub(r.url),
                          style: const TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
              )),
          const SizedBox(height: 4),
        ],
        _row('当前分支', branch.isEmpty ? '（还没有提交）' : branch),
        const SizedBox(height: 6),
        _row('与远端', _remote.hasUpstream
            ? '${_remote.syncLabel}${_fetched ? '' : '（上次记录）'}'
            : '未跟踪远端分支'),
        const SizedBox(height: 6),
        // 领先/落后只在 fetch 之后才准（git 的远程跟踪引用要被更新），
        // 所以给一个显式入口，而不是让面板每次刷新都偷偷联网。
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: busy ? null : _fetch,
            icon: const Icon(Icons.sync_outlined, size: 15),
            label: const Text('检查远端更新', style: TextStyle(fontSize: 11.5)),
          ),
        ),
        const SizedBox(height: 12),
        _field(_remoteName, '远端名称', hint: 'origin'),
        const SizedBox(height: 10),
        _field(_remoteUrl, '远端地址（HTTPS）',
            hint: 'https://github.com/你/仓库.git'),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _setRemote,
                icon: const Icon(Icons.link, size: 16),
                label: Text(
                    _remote.hasRemote ? '保存地址' : '添加远端',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            if (_remote.hasRemote) ...[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _removeRemote,
                  icon: const Icon(Icons.link_off, size: 16),
                  label: const Text('删除远端', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ],
        ),
        const Divider(height: 22),
        Text('凭据（只存在容器里，不会进仓库，也不会跟着源码导出）',
            style: TextStyle(fontSize: 11.5, color: FoaColors.of(context).muted)),
        const SizedBox(height: 10),
        _field(_remoteUser, '用户名', hint: 'GitHub/Gitee 填账号名，GitLab 填 oauth2'),
        const SizedBox(height: 10),
        _field(_remoteToken, '口令 / PAT', hint: '在平台设置里生成的访问令牌'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: busy ? null : _saveCredential,
            icon: const Icon(Icons.key_outlined, size: 16),
            label: Text(
                host.isEmpty ? '保存凭据' : '保存凭据（$host）',
                style: const TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : _push,
                icon: const Icon(Icons.upload_outlined, size: 16),
                label: Text(_remoteBusy ? '进行中…' : '推送',
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: busy ? null : _pull,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('拉取', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
        _hint('「领先/落后」是 fetch 之后才准的数字——git 的远程跟踪引用'
            '（origin/main）只有 fetch 才会更新，不 fetch 的话远端有了新提交'
            '也显示"与远端一致"。所以这里不做自动联网，要点「检查远端更新」。\n'
            '只支持 HTTPS + PAT：SSH 要在手机上生成密钥、再去平台登记公钥，'
            '步骤长且失败点分散。\n'
            '拉取只走 fast-forward——本地和远端分叉时不自动合并：'
            '手机上没有能用的冲突解决界面，自动合并出冲突会把仓库卡在'
            '「合并中」，那比直接报错难收拾得多。分叉了请在电脑上处理。\n'
            '凭据走 git 官方的 credential store，落在 /root/.git-credentials'
            '（权限 600），不在工程目录里，所以 `git add -A` 不会把它提交上去。'),
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

  Widget _row(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(k,
              style: TextStyle(fontSize: 11.5, color: FoaColors.of(context).muted)),
        ),
        Expanded(
          child: Text(v, style: const TextStyle(fontSize: 11.5)),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String label,
      {String? hint, int maxLines = 1}) {
    return TextField(
      controller: c,
      maxLines: maxLines,
      style: const TextStyle(fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        labelStyle: const TextStyle(fontSize: 12),
        hintStyle: const TextStyle(fontSize: 11),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _hint(String s) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(s,
          style: TextStyle(
              fontSize: 10.5, height: 1.5, color: FoaColors.of(context).muted)),
    );
  }
}

// ============================================================================
// 以下是不依赖 Flutter 的纯逻辑：命令拼装 + 输出解析。
// 拆出来是为了能在 `flutter test` 里直接验证解析，**不用起 MethodChannel**。
// ============================================================================

/// 一条 `git status --porcelain` 记录。
class GitFileEntry {
  /// porcelain 的两字符状态码（XY：X=暂存区，Y=工作区）。
  final String code;

  /// 工作区相对路径（已还原空格转义与重命名箭头）。
  final String path;

  const GitFileEntry({required this.code, required this.path});

  bool get untracked => code.trim() == '??';

  /// 是否已进暂存区（X 位不是空格也不是 ?）。
  bool get staged => code.isNotEmpty && code[0] != ' ' && code[0] != '?';

  /// 给用户看的一句人话（比 `M ` 好懂）。
  String get label {
    if (untracked) return '未跟踪';
    final x = code[0];
    final y = code.length > 1 ? code[1] : ' ';
    if (x == 'R') return '重命名（已暂存）';
    if (x == 'A') return '新增（已暂存）';
    if (x == 'D') return '删除（已暂存）';
    if (x == 'M') return '修改（已暂存）';
    if (y == 'D') return '删除（未暂存）';
    if (y == 'M') return '修改（未暂存）';
    return '有改动';
  }
}

/// 一条提交历史。
class GitLogEntry {
  final String hash;
  final String date;
  final String author;
  final String subject;

  const GitLogEntry({
    required this.hash,
    required this.date,
    required this.author,
    required this.subject,
  });
}

/// 一次状态刷新的结果。
class GitSnapshot {
  /// 容器里能找到 git。
  final bool gitFound;

  /// 工程目录存在。
  final bool dirExists;

  /// 是 git 仓库（可能在上级目录，git rev-parse 会往上找）。
  final bool isRepo;

  final String branch;
  final String userName;
  final String userEmail;
  final List<GitFileEntry> files;
  final List<GitLogEntry> log;
  final String error;

  const GitSnapshot({
    required this.gitFound,
    required this.dirExists,
    required this.isRepo,
    required this.branch,
    required this.userName,
    required this.userEmail,
    required this.files,
    required this.log,
    required this.error,
  });

  const GitSnapshot.empty()
      : gitFound = true,
        dirExists = true,
        isRepo = false,
        branch = '',
        userName = '',
        userEmail = '',
        files = const <GitFileEntry>[],
        log = const <GitLogEntry>[],
        error = '';
}

/// 工程目录上的 git 操作。
///
/// 每个方法都是「拼一段 sh → ProotBridge.exec → 解析输出」；
/// 输出用固定标记分段，解析函数 [GitRepo.parse] 是纯函数，
/// 因此解析逻辑可被单测覆盖（真 git 行为在真机验证清单里）。
class GitRepo {
  static const int logLimit = 20;

  /// 文件太多时状态列表的截断上限（够看，也不至于让面板卡住）。
  static const int fileLimit = 300;

  static const String defaultUserName = 'FOA';
  static const String defaultUserEmail = 'foa@localhost';

  final ProotBridge bridge;
  final String projectName;

  GitRepo({required this.bridge, required this.projectName});

  /// 容器内工程路径（与编辑器 / MCP 看到的是同一棵目录树）。
  String get dir => '/root/projects/$projectName';

  /// 单引号包裹：shell 里单引号串内除单引号本身外全部字面量。
  ///
  /// 路径来自 git 输出，可能含空格、括号、`$`；不引号化的话
  /// `git add` 会把一个文件拆成好几个 pathspec。
  static String q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// 状态脚本（纯函数，可单测、也可拷进容器里手工跑）。
  ///
  /// 抽出来而不是内联在 [status] 里，是为了：
  /// - 测试能直接断言脚本内容（不含 push、含身份兜底…）；
  /// - 真机验证时能把它贴到终端里跑，看真实 git 的输出对不对得上解析。
  String get statusScript {
    final d = q(dir);
    return ''
        'command -v git >/dev/null 2>&1 || { echo NOGIT; exit 0; }\n'
        'if [ ! -d $d ]; then echo NOTDIR; exit 0; fi\n'
        'cd $d 2>/dev/null || { echo NOTDIR; exit 0; }\n'
        'if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then echo REPO=0; exit 0; fi\n'
        'echo REPO=1\n'
        // 容器里 git 是 root 跑的，工程目录也归 root——但 Android 的
        // sdcard 同步可能把属主改成别的 uid，git 的 "dubious ownership"
        // 检查会直接拒绝执行，这里先放行（只加本工程，不用 '*'）。
        // ⚠️ 必须先 grep 判存在再加：无脑 --add 的话每次刷新都往
        // ~/.gitconfig 里堆一条重复项。
        'git config --global --get-all safe.directory 2>/dev/null | grep -Fqx $d '
        '|| git config --global --add safe.directory $d >/dev/null 2>&1\n'
        'b=\$(git branch --show-current 2>/dev/null); '
        '[ -z "\$b" ] && b=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null); '
        'echo "BRANCH=\$b"\n'
        'echo "NAME=\$(git config user.name 2>/dev/null)"\n'
        'echo "EMAIL=\$(git config user.email 2>/dev/null)"\n'
        'echo --FILES--\n'
        // -uall：默认 porcelain 把未跟踪目录压成一行 `?? lib/`，
        // 面板里就没法按文件勾选；展开成具体文件才好用。
        'git status --porcelain -uall 2>/dev/null | head -n $fileLimit\n'
        'echo --LOG--\n'
        // ⚠️ 必须是 tformat 不是 format：format 在**最后一条之后不换行**，
        // 会把末条日志和后面的 --END-- 粘成一行（真机实测踩到），
        // 解析出来 subject 尾巴上挂着 "--END--"。
        "git log --pretty=tformat:'%h|%ad|%an|%s' --date=short -n $logLimit 2>/dev/null\n"
        'echo --END--\n';
  }

  Future<GitSnapshot> status() async {
    final r = await bridge.exec(statusScript, timeoutSec: 60);
    if (!r.ok && r.stdout.trim().isEmpty) {
      return GitSnapshot(
        gitFound: true,
        dirExists: false,
        isRepo: false,
        branch: '',
        userName: '',
        userEmail: '',
        files: const <GitFileEntry>[],
        log: const <GitLogEntry>[],
        error: '执行 git 失败（退出码 ${r.exitCode}）：${_tail(r.stderr)}',
      );
    }
    return parse(r.stdout);
  }

  /// 解析 [status] 脚本的输出（纯函数，便于单测）。
  static GitSnapshot parse(String out) {
    final lines = out.split('\n');
    if (lines.any((l) => l.trim() == 'NOGIT')) {
      return const GitSnapshot(
        gitFound: false,
        dirExists: true,
        isRepo: false,
        branch: '',
        userName: '',
        userEmail: '',
        files: <GitFileEntry>[],
        log: <GitLogEntry>[],
        error: '',
      );
    }
    if (lines.any((l) => l.trim() == 'NOTDIR')) {
      return const GitSnapshot(
        gitFound: true,
        dirExists: false,
        isRepo: false,
        branch: '',
        userName: '',
        userEmail: '',
        files: <GitFileEntry>[],
        log: <GitLogEntry>[],
        error: '工程目录不存在（/root/projects 下找不到这个工程）。',
      );
    }

    String branch = '', name = '', email = '';
    var repo = false;
    final files = <GitFileEntry>[];
    final log = <GitLogEntry>[];
    var zone = '';

    for (final raw in lines) {
      final l = raw.replaceAll('\r', '');
      if (l.startsWith('--')) {
        zone = l.trim();
        continue;
      }
      switch (zone) {
        case '--FILES--':
          if (l.length > 3) files.add(_parsePorcelain(l));
          break;
        case '--LOG--':
          if (l.contains('|')) {
            final p = l.split('|');
            log.add(GitLogEntry(
              hash: p[0],
              date: p.length > 1 ? p[1] : '',
              author: p.length > 2 ? p[2] : '',
              // subject 里可能带 |，所以剩下的要拼回去
              subject: p.length > 3 ? p.sublist(3).join('|') : '',
            ));
          }
          break;
        default:
          if (l.startsWith('REPO=')) repo = l.substring(5).trim() == '1';
          if (l.startsWith('BRANCH=')) branch = l.substring(7).trim();
          if (l.startsWith('NAME=')) name = l.substring(5).trim();
          if (l.startsWith('EMAIL=')) email = l.substring(6).trim();
      }
    }
    return GitSnapshot(
      gitFound: true,
      dirExists: true,
      isRepo: repo,
      branch: branch,
      userName: name,
      userEmail: email,
      files: files,
      log: log,
      error: '',
    );
  }

  /// 解析一行 porcelain：`XY path`（路径可能带引号，重命名是 `old -> new`）。
  static GitFileEntry _parsePorcelain(String line) {
    final code = line.substring(0, 2);
    var rest = line.substring(3);
    if (rest.contains(' -> ')) rest = rest.split(' -> ').last;
    if (rest.startsWith('"') && rest.endsWith('"') && rest.length > 2) {
      rest = rest.substring(1, rest.length - 1)
          .replaceAll('\\"', '"')
          .replaceAll('\\\\', '\\');
    }
    return GitFileEntry(code: code, path: rest);
  }

  /// `git init` + 写身份 + 补 .gitignore。
  ///
  /// [name] / [email] 为空时回落到默认值——否则第一次提交必然卡在
  /// "Please tell me who you are"，而用户根本看不到这句在哪报的。
  String initScript({required String name, required String email}) {
    final d = q(dir);
    final n = q(name.isEmpty ? defaultUserName : name);
    final e = q(email.isEmpty ? defaultUserEmail : email);
    return ''
        'if [ ! -d $d ]; then echo "ERR=工程目录不存在"; exit 1; fi\n'
        'cd $d 2>/dev/null || { echo "ERR=进不去工程目录"; exit 1; }\n'
        // -b 需要 git ≥ 2.28；老版本直接整条失败，回落到默认分支名。
        'git init -q -b main 2>/dev/null || git init -q 2>&1 || '
        '{ echo "ERR=git init 失败"; exit 2; }\n'
        'git config --global --get-all safe.directory 2>/dev/null | grep -Fqx $d '
        '|| git config --global --add safe.directory $d >/dev/null 2>&1\n'
        'git config user.name $n 2>&1 || { echo "ERR=写 user.name 失败"; exit 3; }\n'
        'git config user.email $e 2>&1 || { echo "ERR=写 user.email 失败"; exit 4; }\n'
        // 没有 .gitignore 时补一份：flutter create 生成的工程自带，
        // 但手拷进来的源码树常常没有，一次 add -A 会把 build/ 全塞进去。
        'if [ ! -f .gitignore ]; then '
        "printf '%s\\n' '.dart_tool/' 'build/' '.idea/' '*.iml' 'android/.gradle/' > .gitignore; "
        'echo GITIGNORE=created; else echo GITIGNORE=exists; fi\n'
        'echo OK\n';
  }

  Future<({bool ok, String msg})> init({
    required String name,
    required String email,
  }) async {
    final r = await bridge.exec(initScript(name: name, email: email),
        timeoutSec: 120);
    final err = _errOf(r.stdout);
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? 'git init 失败（退出码 ${r.exitCode}）');
    }
    final created = r.stdout.contains('GITIGNORE=created');
    return (
      ok: true,
      msg: created
          ? '仓库已初始化，并补了一份 .gitignore（忽略 .dart_tool/、build/ 等）。'
          : '仓库已初始化（工程里已有 .gitignore，未改动）。',
    );
  }

  /// 暂存 + 提交 [paths]（相对工程根的路径）。
  String commitScript({
    required String message,
    required List<String> paths,
    String name = '',
    String email = '',
  }) {
    final d = q(dir);
    final add = paths.map(q).join(' ');
    // 多行说明拆成多个 -m：第一个是标题，后面是正文。
    final ms = message
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map(q)
        .map((s) => '-m $s')
        .join(' ');
    return ''
        'if [ ! -d $d ]; then echo "ERR=工程目录不存在"; exit 1; fi\n'
        'cd $d 2>/dev/null || { echo "ERR=进不去工程目录"; exit 1; }\n'
        // 只跑一次并接住输出：早先写成"失败后再跑一遍取错误信息"，
        // 既多跑一次 git，实测还取不到内容（错误信息已被第一次吞掉）。
        'aout=\$(git add -- $add 2>&1) || { echo "ERR=git add 失败：\$aout"; exit 2; }\n'
        // 身份可能没写（比如仓库是别处拷来的），提交前补一次更稳。
        'if [ -z "\$(git config user.email 2>/dev/null)" ]; then '
        'git config user.name ${q(name.isEmpty ? defaultUserName : name)}; '
        'git config user.email ${q(email.isEmpty ? defaultUserEmail : email)}; fi\n'
        'out=\$(git commit $ms 2>&1) || { echo "ERR=\$out"; exit 3; }\n'
        'echo "OK=\$out"\n';
  }

  Future<({bool ok, String msg})> commit({
    required String message,
    required List<String> paths,
    String name = '',
    String email = '',
  }) async {
    final r = await bridge.exec(
      commitScript(message: message, paths: paths, name: name, email: email),
      timeoutSec: 180,
    );
    if (r.ok) {
      final okLine = r.stdout
          .split('\n')
          .firstWhere((l) => l.startsWith('OK='),
              orElse: () => 'OK=已提交');
      return (ok: true, msg: commitSummary(okLine.substring(3)));
    }
    final err = _errOf(r.stdout);
    final text = err ?? r.stderr;
    // ⚠️ 两种文案都要认：git 对"暂存区空"说的是
    // `nothing added to commit`，对"暂存区有但无改动"才是
    // `nothing to commit`。只认后者的话前者会落到"提交失败"那条
    // 兜底里，用户看到一堆 git 原文却不知道该怎么办。
    if (text.contains('nothing to commit') ||
        text.contains('nothing added to commit')) {
      return (ok: false, msg: '这些文件没有实际改动，git 拒绝了空提交。');
    }
    return (ok: false, msg: '提交失败：${_tail(text.isEmpty ? r.stdout : text)}');
  }

  /// 把 `git commit` 那一坨输出压成一句人话。
  static String commitSummary(String raw) {
    final line = raw.replaceAll('\r', '').split('\n').first.trim();
    // 形如 `[main a1b2c3d] 提交说明` 或 `[main (root-commit) a1b2c3d] 说明`
    final m = RegExp(r'^\[(\S+)(?: \(root-commit\))? (\w+)\] (.*)$')
        .firstMatch(line);
    if (m != null) {
      final branch = m.group(1)!;
      final hash = m.group(2)!;
      final rest = m.group(3)!;
      final files = RegExp(r'(\d+) files? changed').firstMatch(raw);
      final changed = files == null ? '' : '，${files.group(1)} 个文件';
      return '已提交到 $branch（$hash）：$rest$changed';
    }
    return line.isEmpty ? '已提交' : line;
  }

  /// 从输出里捞 `ERR=` 开头的错误行（脚本约定：出错先打 ERR= 再 exit）。
  static String? _errOf(String stdout) {
    for (final l in stdout.split('\n')) {
      final t = l.trim();
      if (t.startsWith('ERR=')) return t.substring(4).trim();
    }
    return null;
  }

  /// 只留最后几行——git 的长输出（hint: ...）会把真正的错误顶出屏幕。
  static String _tail(String s, {int n = 6}) {
    final ls = s.trim().split('\n');
    if (ls.length <= n) return s.trim();
    return ls.sublist(ls.length - n).join('\n');
  }
}
