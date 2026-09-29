import '../env/proot_bridge.dart';

/// 一条远端（`git remote -v` 的一行）。
class GitRemoteEntry {
  final String name;
  final String url;

  const GitRemoteEntry({required this.name, required this.url});

  /// 是不是 HTTPS（本面板唯一支持的协议）。
  bool get isHttps => url.startsWith('https://') || url.startsWith('http://');

  /// 凭据归属的主机名（凭据是按 host 存的）。
  String get host => GitRemote.hostOf(url);
}

/// 远端与同步状态的一次快照。
class GitRemoteInfo {
  final bool repo;
  final String branch;
  final List<GitRemoteEntry> remotes;
  final String upstream;

  /// 本地领先远端的提交数。
  final int ahead;

  /// 本地落后远端的提交数。
  final int behind;
  final String error;

  const GitRemoteInfo({
    required this.repo,
    required this.branch,
    required this.remotes,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.error,
  });

  static const GitRemoteInfo empty = GitRemoteInfo(
    repo: false,
    branch: '',
    remotes: <GitRemoteEntry>[],
    upstream: '',
    ahead: 0,
    behind: 0,
    error: '',
  );

  bool get hasRemote => remotes.isNotEmpty;

  bool get hasUpstream => upstream.isNotEmpty;

  /// 「领先 2 · 落后 1」这类人话（都为 0 时说明完全同步）。
  String get syncLabel {
    if (!hasUpstream) return '未跟踪远端分支';
    if (ahead == 0 && behind == 0) return '与远端一致';
    final parts = <String>[];
    if (ahead > 0) parts.add('领先 $ahead');
    if (behind > 0) parts.add('落后 $behind');
    return parts.join(' · ');
  }
}

/// 工程目录上的 git **远端**操作（alpha.94）。
///
/// 与 [GitRepo]（本地的 init/status/add/commit/log）分工：那边不动网络，
/// 这边只管远端。这样拆分是因为两者的失败模式完全不同——本地操作失败
/// 几乎都是"用法问题"，远端操作失败多半是凭据/网络，需要完全不同的提示。
///
/// ## 能力边界（如实写，不吹）
///
/// - **只支持 HTTPS + 用户名/口令（PAT）**。不做 SSH：密钥要在手机上
///   生成、还得去平台侧登记公钥，步骤长且失败点分散；而 PAT 是所有
///   主流平台（GitHub / GitLab / Gitee / 腾讯云 CODING…）都给的通用能力。
/// - **不做分支管理**（新建/切换/删除分支）：切换分支会动工作区文件，
///   和编辑器里打开的文件打架，手机上不好处理。
/// - **pull 只走 fast-forward**：本地与远端分叉时不自动合并——在手机上
///   解冲突是灾难，宁可明确报"请在电脑上处理"。
///
/// ## 凭据怎么存
///
/// 走 git 自己的 `credential.helper store`，落在 `/root/.git-credentials`
/// （权限 600）。选它是因为：
/// - 凭据**不在工程目录里**，不会被 `git add -A` 提交，也不随导出源码
///   工程带走；
/// - 凭据**不出现在命令行里**（对比 `git push https://user:token@host/…`：
///   那会让 token 出现在进程参数和 git 的报错原文里）；
/// - 是 git 官方机制，不引入任何三方依赖（仓库原则）。
class GitRemote {
  final ProotBridge bridge;
  final String projectName;

  GitRemote({required this.bridge, required this.projectName});

  /// 容器内工程路径（与 GitRepo 同一个）。
  String get dir => '/root/projects/$projectName';

  /// 凭据文件路径（容器 /root 下，不在工程里）。
  static const String credentialFile = '/root/.git-credentials';

  /// 单引号包裹（与 GitRepo.q 同一套规则）。
  static String q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  // ============================ 纯函数 ============================

  /// 从远端 URL 取主机名（凭据按 host 存放）。
  ///
  /// 支持 `https://host/path.git` 与 `ssh://git@host/path`；
  /// `git@host:path` 这种 SCP 写法也认（虽然我们不支持 SSH，但至少要
  /// 能把它识别成"非 HTTPS"，好给出正确的提示）。
  static String hostOf(String url) {
    var s = url.trim();
    if (s.contains('@')) {
      // git@github.com:foo/bar.git → 去掉 user@ 与可能的 scheme
      final at = s.indexOf('@');
      s = s.substring(at + 1);
      s = s.replaceFirst(':', '/');
      if (!s.startsWith('http')) s = 'https://$s';
    }
    final m = RegExp(r'^[a-z]+://([^/:?#]+)', caseSensitive: false)
        .firstMatch(s);
    return m == null ? '' : m.group(1)!;
  }

  /// 抹掉输出里可能夹带的 `https://user:pass@host`。
  ///
  /// 凭据走 store 之后 URL 里本不该有口令，但用户可能自己配了个带 token
  /// 的远端地址；一旦配错，git 的报错原文会把整条 URL 打印出来。
  /// 任何要显示给用户（或进日志）的文本都先过一遍这里。
  static String scrub(String s) =>
      s.replaceAllMapped(RegExp(r'(https?://)[^/@\s]+:[^/@\s]+@'),
          (m) => '${m.group(1)}***@');

  /// 把 URL 里的用户名/口令段做百分号编码（放进凭据行之前必须做—
  /// PAT 里常有 `+` `/` `=` 甚至 `@`，不编码会被 git 解析错）。
  static String enc(String s) => Uri.encodeComponent(s);

  // ============================ 脚本（纯函数） ============================

  /// 远端状态脚本：远端列表 + 上游 + 领先/落后。
  String get remoteScript {
    final d = q(dir);
    return ''
        'command -v git >/dev/null 2>&1 || { echo NOGIT; exit 0; }\n'
        'if [ ! -d $d ]; then echo NOTDIR; exit 0; fi\n'
        'cd $d 2>/dev/null || { echo NOTDIR; exit 0; }\n'
        'if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; '
        'then echo REPO=0; exit 0; fi\n'
        'echo REPO=1\n'
        'b=\$(git branch --show-current 2>/dev/null); '
        '[ -z "\$b" ] && b=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null); '
        'echo "BRANCH=\$b"\n'
        'echo --REMOTES--\n'
        // `git remote -v` 一行两个（fetch/push）会重复，用 `git remote`
        // 取名字 + `get-url` 取值，天然去重且不用解析 `(fetch)` 后缀。
        'for r in \$(git remote 2>/dev/null); do '
        'echo "R=\$r|\$(git remote get-url \$r 2>/dev/null)"; done\n'
        'echo --SYNC--\n'
        // @{u} 展开失败（没有上游）时 git 会把原文打进 stderr，
        // 所以先判一次，避免把 "fatal: no such branch" 混进解析。
        'up=\$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)\n'
        'if [ -n "\$up" ]; then echo "UPSTREAM=\$up"; '
        // --left-right --count 输出 "落后 领先"（左=上游，右=HEAD）
        'echo "AB=\$(git rev-list --left-right --count \$up...HEAD 2>/dev/null)"; '
        'else echo "UPSTREAM="; fi\n'
        'echo --END--\n';
  }

  /// 新增 / 修改远端。
  String setRemoteScript({required String name, required String url}) {
    final d = q(dir);
    return ''
        'if [ ! -d $d ]; then echo "ERR=工程目录不存在"; exit 1; fi\n'
        'cd $d 2>/dev/null || { echo "ERR=进不去工程目录"; exit 1; }\n'
        'if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then '
        'echo "ERR=这个工程还不是 Git 仓库"; exit 2; fi\n'
        'if git remote 2>/dev/null | grep -Fxq ${q(name)}; then '
        'git remote set-url ${q(name)} ${q(url)} 2>&1 | tail -n 3; '
        'echo "SET=updated"; '
        'else git remote add ${q(name)} ${q(url)} 2>&1 | tail -n 3; '
        'echo "SET=added"; fi\n'
        'echo "URL=\$(git remote get-url ${q(name)} 2>/dev/null)"\n';
  }

  /// 删除远端（只删指针，不动任何文件）。
  String removeRemoteScript(String name) {
    final d = q(dir);
    return ''
        'if [ ! -d $d ]; then echo "ERR=工程目录不存在"; exit 1; fi\n'
        'cd $d 2>/dev/null || { echo "ERR=进不去工程目录"; exit 1; }\n'
        'git remote remove ${q(name)} 2>&1 | tail -n 3\n'
        'echo "REMOVED=${q(name)}"\n';
  }

  /// 写入凭据（git credential store）。
  ///
  /// 同一 host 的旧行会被**替换**而不是追加——不然改一次 PAT 就多一行，
  /// git 取到旧的就一直鉴权失败，而用户看文件只看到"我明明改了"。
  String credentialScript({
    required String host,
    required String user,
    required String token,
  }) {
    final line = 'https://${enc(user)}:${enc(token)}@$host';
    const cf = credentialFile;
    return ''
        'if [ -z ${q(host)} ]; then echo "ERR=没能从远端地址里解析出主机名"; exit 1; fi\n'
        // ⚠️ host 必须先进变量再进 grep 的 pattern：直接把 q() 的结果塞进
        // 双引号里，单引号会变成 pattern 的一部分（`@'github.com'`），
        // 于是 grep 一条都匹配不到 → 每次保存都追加一行，真机实测
        // 第二次运行后文件里躺着两行一模一样的凭据。
        'H=${q(host)}\n'
        'touch $cf 2>/dev/null || { echo "ERR=写不了凭据文件：$cf"; exit 2; }\n'
        'chmod 600 $cf 2>/dev/null\n'
        // grep -v 在文件为空时返回 1，不能让它中断脚本
        'grep -v -F "@\$H" $cf 2>/dev/null > $cf.tmp || true\n'
        'printf %s\\\\n ${q(line)} >> $cf.tmp\n'
        'mv -f $cf.tmp $cf\n'
        'chmod 600 $cf\n'
        // 同样的"先判再加"：无脑 --add 会把 helper 堆重复
        'git config --global --get-all credential.helper 2>/dev/null | '
        'grep -Fxq store || git config --global --add credential.helper store\n'
        'echo "CRED=\$H"\n';
  }

  /// 推送。
  ///
  /// `GIT_TERMINAL_PROMPT=0` 是关键：凭据不对时 git 默认会**在终端里问
  /// 用户名**，而我们没有终端——不设这个变量，手机上的表现就是卡住不动
  /// 直到超时。设了的话它会立刻失败并给出可诊断的报错。
  String pushScript(
      {required String remote, required String branch, bool setUpstream = true}) {
    final d = q(dir);
    final u = setUpstream ? '-u ' : '';
    return ''
        'if [ ! -d $d ]; then echo "ERR=工程目录不存在"; exit 1; fi\n'
        'cd $d 2>/dev/null || { echo "ERR=进不去工程目录"; exit 1; }\n'
        'export GIT_TERMINAL_PROMPT=0\n'
        'if [ -z "\$(git remote 2>/dev/null)" ]; then '
        'echo "ERR=还没有配置远端"; exit 2; fi\n'
        'out=\$(git push $u${q(remote)} ${q(branch)} 2>&1); rc=\$?\n'
        'printf %s\\\\n "\$out" | tail -n 12\n'
        'if [ \$rc -ne 0 ]; then echo "ERR=推送失败（git exit \$rc）"; exit \$rc; fi\n'
        'echo "PUSH_OK"\n';
  }

  /// 只取远端最新状态（不动工作区任何文件）。
  ///
  /// 为什么它是显式动作、而不是塞进 [remoteScript] 里顺手做：
  /// 面板每次刷新都跑状态脚本，而 fetch 要走网络——弱网下几十秒的等待
  /// 会把"只是想看一眼本地有没有改动"也一起拖垮。
  /// 更关键的是**领先/落后这两个数字只在 fetch 之后才准**（实测：
  /// 远端有了新提交，没 fetch 时 `origin/main` 还是旧的，显示"与远端一致"）。
  /// 所以做成按钮，跑完再刷新。
  String fetchScript(String remote) {
    final d = q(dir);
    return ''
        'if [ ! -d $d ]; then echo "ERR=工程目录不存在"; exit 1; fi\n'
        'cd $d 2>/dev/null || { echo "ERR=进不去工程目录"; exit 1; }\n'
        'export GIT_TERMINAL_PROMPT=0\n'
        // timeout 不是所有 rootfs 都有（busybox 版可能缺），缺了就裸跑
        'T=""; command -v timeout >/dev/null 2>&1 && T="timeout 40"\n'
        'out=\$(eval \$T git fetch --quiet ${q(remote)} 2>&1); rc=\$?\n'
        'printf %s\\\\n "\$out" | tail -n 8\n'
        'if [ \$rc -ne 0 ]; then echo "ERR=取远端状态失败（git exit \$rc）"; exit \$rc; fi\n'
        'echo "FETCH_OK"\n';
  }

  /// 拉取（**只允许 fast-forward**）。
  ///
  /// 为什么不加 `--rebase` / 不自动合并：手机上没有可用的冲突解决界面，
  /// 一旦自动合并出冲突，仓库会停在"合并中"状态，用户既不会解也退不出去。
  /// fast-forward 是唯一"绝不会产生冲突"的拉取方式；分叉了就明确报错，
  /// 让用户去电脑上处理。
  String pullScript({required String remote, required String branch}) {
    final d = q(dir);
    return ''
        'if [ ! -d $d ]; then echo "ERR=工程目录不存在"; exit 1; fi\n'
        'cd $d 2>/dev/null || { echo "ERR=进不去工程目录"; exit 1; }\n'
        'export GIT_TERMINAL_PROMPT=0\n'
        // git 自己也会拒绝（"Your local changes would be overwritten"），
        // 但那句话不说该怎么办；这里提前挡一次并给出明确动作。
        'if [ -n "\$(git status --porcelain -uall 2>/dev/null)" ]; then '
        'echo "ERR=工作区有未提交的改动，先提交再拉取"; exit 2; fi\n'
        'out=\$(git pull --ff-only ${q(remote)} ${q(branch)} 2>&1); rc=\$?\n'
        'printf %s\\\\n "\$out" | tail -n 12\n'
        'if [ \$rc -ne 0 ]; then echo "ERR=拉取失败（git exit \$rc）"; exit \$rc; fi\n'
        'echo "PULL_OK"\n';
  }

  // ============================ 解析（纯函数） ============================

  static GitRemoteInfo parse(String raw) {
    final out = scrub(raw);
    final lines = out.split('\n');
    String branch = '', upstream = '', ab = '';
    var repo = false;
    final remotes = <GitRemoteEntry>[];
    var zone = '';
    for (final l0 in lines) {
      final l = l0.replaceAll('\r', '');
      if (l == 'NOGIT' || l == 'NOTDIR') {
        return GitRemoteInfo.empty.copyWith(error: '');
      }
      if (l.startsWith('--')) {
        zone = l.trim();
        continue;
      }
      switch (zone) {
        case '--REMOTES--':
          if (l.startsWith('R=')) {
            final v = l.substring(2);
            final i = v.indexOf('|');
            if (i > 0) {
              remotes.add(GitRemoteEntry(
                  name: v.substring(0, i), url: v.substring(i + 1)));
            }
          }
          break;
        case '--SYNC--':
          if (l.startsWith('UPSTREAM=')) upstream = l.substring(9).trim();
          if (l.startsWith('AB=')) ab = l.substring(3).trim();
          break;
        default:
          if (l.startsWith('REPO=')) repo = l.substring(5).trim() == '1';
          if (l.startsWith('BRANCH=')) branch = l.substring(7).trim();
      }
    }
    var ahead = 0, behind = 0;
    final m = RegExp(r'^(\d+)\s+(\d+)$').firstMatch(ab.trim());
    if (m != null) {
      behind = int.tryParse(m.group(1)!) ?? 0;
      ahead = int.tryParse(m.group(2)!) ?? 0;
    }
    return GitRemoteInfo(
      repo: repo,
      branch: branch,
      remotes: remotes,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      error: '',
    );
  }

  /// 把推送的失败原文翻成人话（并给出下一步动作）。
  ///
  /// 不把 git 原文直接丢给用户——"fatal: unable to access …: The requested
  /// URL returned error: 403" 这句话在手机上等于没说。
  static String pushFailure(String raw) {
    final s = scrub(raw).toLowerCase();
    if (s.contains('terminal prompts disabled') ||
        s.contains('could not read username') ||
        s.contains('authentication failed') ||
        s.contains('403') ||
        s.contains('401') ||
        s.contains('invalid username or password')) {
      return '凭据不对或没填：去平台生成一个 PAT（仓库写权限），'
          '填在下面的「用户名 / 口令」里再推一次。';
    }
    if (s.contains('could not resolve host') ||
        s.contains('failed to connect') ||
        s.contains('timed out') ||
        s.contains('unable to access') && s.contains('couldn')) {
      return '连不上远端：检查网络，或确认这个地址在手机上能访问。';
    }
    if (s.contains('non-fast-forward') || s.contains('rejected')) {
      return '远端有你本地没有的提交：先点「拉取」，再推送。';
    }
    if (s.contains('src refspec') || s.contains('does not match any')) {
      return '这个分支在本地还不存在（可能一次都没提交过），先提交一次。';
    }
    if (s.contains('没有配置远端') || s.contains('还没有配置远端')) {
      return '还没配远端地址：先填一个（形如 https://github.com/你/仓库.git）。';
    }
    return '推送失败：${_tail(raw)}';
  }

  /// 拉取失败的人话翻译。
  static String pullFailure(String raw) {
    final s = scrub(raw).toLowerCase();
    if (s.contains('not possible to fast-forward') ||
        s.contains('diverging') ||
        s.contains('would overwrite')) {
      return '本地和远端已经分叉（两边都有对方没有的提交）。'
          '手机上不自动合并——请在电脑上处理，或先把本地改动提交后再拉取。';
    }
    if (s.contains('terminal prompts disabled') ||
        s.contains('could not read username') ||
        s.contains('authentication failed') ||
        s.contains('403') ||
        s.contains('401')) {
      return '凭据不对或没填：去平台生成一个 PAT 填进来。';
    }
    if (s.contains('could not resolve host') ||
        s.contains('failed to connect') ||
        s.contains('timed out')) {
      return '连不上远端：检查网络。';
    }
    if (s.contains('未提交的改动')) {
      return '工作区有未提交的改动：先提交，再拉取。';
    }
    if (s.contains("couldn't find remote ref") ||
        s.contains('no such ref was fetched')) {
      return '远端还没有这个分支（仓库是空的或分支名不对）。';
    }
    return '拉取失败：${_tail(raw)}';
  }

  static String _tail(String s) {
    final ls = scrub(s).trim().split('\n');
    if (ls.length <= 3) return ls.join(' ');
    return ls.sublist(ls.length - 3).join(' ');
  }

  // ============================ 走桥 ============================

  Future<GitRemoteInfo> info() async {
    final r = await bridge.exec(remoteScript, timeoutSec: 60);
    if (!r.ok && r.stdout.trim().isEmpty) {
      return GitRemoteInfo.empty.copyWith(
          error: '执行 git 失败（退出码 ${r.exitCode}）');
    }
    return parse(r.stdout);
  }

  Future<({bool ok, String msg})> setRemote({
    required String name,
    required String url,
  }) async {
    final r = await bridge.exec(
        setRemoteScript(name: name, url: url), timeoutSec: 60);
    final out = scrub(r.stdout);
    final err = _errOf(out);
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? '设置远端失败（退出码 ${r.exitCode}）');
    }
    return (
      ok: true,
      msg: out.contains('SET=added') ? '已添加远端 $name。' : '已更新远端 $name 的地址。',
    );
  }

  Future<({bool ok, String msg})> removeRemote(String name) async {
    final r = await bridge.exec(removeRemoteScript(name), timeoutSec: 60);
    final err = _errOf(scrub(r.stdout));
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? '删除远端失败（退出码 ${r.exitCode}）');
    }
    return (ok: true, msg: '已删除远端 $name（只是删了地址，本地提交都还在）。');
  }

  Future<({bool ok, String msg})> saveCredential({
    required String host,
    required String user,
    required String token,
  }) async {
    final r = await bridge.exec(
        credentialScript(host: host, user: user, token: token),
        timeoutSec: 60);
    final err = _errOf(scrub(r.stdout));
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? '保存凭据失败（退出码 ${r.exitCode}）');
    }
    return (ok: true, msg: '凭据已保存到 $host（只存在容器里，不会进仓库）。');
  }

  Future<({bool ok, String msg})> push({
    required String remote,
    required String branch,
  }) async {
    final r = await bridge.exec(
        pushScript(remote: remote, branch: branch),
        timeoutSec: 600,
    );
    final out = scrub(r.stdout);
    if (r.ok && out.contains('PUSH_OK')) {
      return (ok: true, msg: '已推送 $branch 到 $remote。');
    }
    final err = _errOf(out);
    return (ok: false, msg: pushFailure(err ?? out));
  }

  /// 取远端最新状态（成功后领先/落后的数字才是新的）。
  Future<({bool ok, String msg})> fetch(String remote) async {
    final r = await bridge.exec(fetchScript(remote), timeoutSec: 120);
    final out = scrub(r.stdout);
    if (r.ok && out.contains('FETCH_OK')) {
      return (ok: true, msg: '已取回远端最新状态。');
    }
    final err = _errOf(out);
    final s = (err ?? out).toLowerCase();
    if (s.contains('could not resolve host') ||
        s.contains('failed to connect') ||
        s.contains('timed out')) {
      return (ok: false, msg: '连不上远端：检查网络，或确认地址在手机上能访问。');
    }
    if (s.contains('terminal prompts disabled') ||
        s.contains('could not read username') ||
        s.contains('authentication failed')) {
      return (ok: false, msg: '凭据不对或没填：生成一个 PAT 填进来再试。');
    }
    return (ok: false, msg: '取远端状态失败：${_tail(err ?? out)}');
  }

  Future<({bool ok, String msg})> pull({
    required String remote,
    required String branch,
  }) async {
    final r = await bridge.exec(
        pullScript(remote: remote, branch: branch),
        timeoutSec: 600,
    );
    final out = scrub(r.stdout);
    if (r.ok && out.contains('PULL_OK')) {
      return (ok: true, msg: out.contains('Already up to date')
          ? '已经是最新的，没有要拉的提交。'
          : '已从 $remote 拉取 $branch。');
    }
    final err = _errOf(out);
    return (ok: false, msg: pullFailure(err ?? out));
  }

  /// 从输出里捞 `ERR=` 行。
  static String? _errOf(String stdout) {
    for (final l in stdout.split('\n')) {
      final t = l.trim();
      if (t.startsWith('ERR=')) return t.substring(4).trim();
    }
    return null;
  }
}

extension _Copy on GitRemoteInfo {
  GitRemoteInfo copyWith({String? error}) => GitRemoteInfo(
        repo: repo,
        branch: branch,
        remotes: remotes,
        upstream: upstream,
        ahead: ahead,
        behind: behind,
        error: error ?? '',
      );
}
