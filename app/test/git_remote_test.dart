import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/env/proot_bridge.dart';
import 'package:foaide/project/git_remote.dart';

/// Git 远端（alpha.94）的守卫测试。
///
/// 重点盯两类东西：
/// 1. **凭据不能被泄漏**——口令一旦出现在命令行里，就会进进程参数、
///    进 git 的报错原文、进日志；这里的所有脚本都必须走 credential store。
/// 2. **不能卡住**——手机上没有终端，git 一旦想在终端里问用户名，
///    表现就是一直转圈到超时；推送/拉取必须带 GIT_TERMINAL_PROMPT=0。
void main() {
  GitRemote rem() => GitRemote(bridge: ProotBridge(), projectName: 'demo');

  group('主机名解析', () {
    test('https 地址', () {
      expect(GitRemote.hostOf('https://github.com/a/b.git'), 'github.com');
    });

    test('带端口的自建 GitLab', () {
      expect(GitRemote.hostOf('https://git.example.com:8443/a/b.git'),
          'git.example.com');
    });

    test('SCP 写法（git@host:path）也认得出 host', () {
      expect(GitRemote.hostOf('git@github.com:a/b.git'), 'github.com');
    });

    test('认不出来就返回空（调用方据此报错，不要瞎存）', () {
      expect(GitRemote.hostOf('不是一个地址'), isEmpty);
    });
  });

  group('脱敏', () {
    test('抹掉 URL 里的 用户名:口令@', () {
      expect(GitRemote.scrub('fatal: unable to access '
          "'https://alice:ghp_xxx@github.com/a/b.git': 403"),
          isNot(contains('ghp_xxx')));
    });

    test('普通文本不受影响', () {
      expect(GitRemote.scrub('Everything up-to-date'),
          'Everything up-to-date');
    });

    test('不带 @ 的 https 链接不动（只抹凭据段）', () {
      expect(GitRemote.scrub('https://github.com/a/b.git'),
          'https://github.com/a/b.git');
    });
  });

  group('百分号编码', () {
    test('PAT 里的特殊字符会被编码', () {
      // 真实 PAT 里 + / = 都很常见，不编码会被 git 解析错行
      expect(GitRemote.enc('a+b/c=d'), 'a%2Bb%2Fc%3Dd');
    });
  });

  group('状态脚本', () {
    test('远端列表用 get-url 取值，不解析 -v 的 (fetch)/(push) 后缀', () {
      expect(rem().remoteScript.contains('git remote get-url'), isTrue);
      expect(rem().remoteScript.contains('remote -v'), isFalse);
    });

    test('领先/落后用 --left-right --count', () {
      expect(rem().remoteScript.contains('--left-right --count'), isTrue);
    });

    test('没有上游时不会把 git 的 fatal 混进解析', () {
      // @{u} 展开失败会往 stderr 打 "fatal: no such branch"，
      // 这里先判空再取，避免把它当成 UPSTREAM。
      expect(rem().remoteScript.contains('@{u} 2>/dev/null'), isTrue);
      expect(rem().remoteScript.contains(r'if [ -n "$up" ]'), isTrue);
    });
  });

  group('凭据脚本', () {
    final s = rem().credentialScript(
        host: 'github.com', user: 'alice', token: 'ghp_abc+def');

    test('写进 /root/.git-credentials（不在工程目录里）', () {
      expect(s.contains('/root/.git-credentials'), isTrue);
      expect(s.contains('/root/projects'), isFalse,
          reason: '凭据落在工程里会被 git add -A 提交上去，也会随源码导出带走');
    });

    test('权限 600', () {
      expect(s.contains('chmod 600'), isTrue);
    });

    test('同 host 的旧行被替换，不是追加', () {
      expect(s.contains('grep -v -F'), isTrue,
          reason: '只追加的话改一次 PAT 就多一行，git 取到旧的会一直鉴权失败');
      expect(s.contains('mv -f'), isTrue);
    });

    test('grep 的 pattern 里不能有引号（真机实测：会一条都匹配不到）', () {
      // Bug：早先写成 `grep -v -F "@'github.com'"` —— q() 的单引号成了
      // pattern 的一部分，结果每次保存都追加一行，文件里躺着两行相同凭据。
      // 修法：host 先赋给变量，pattern 写 "@$H"。
      expect(s.contains(r'@$H'), isTrue);
      expect(s.contains('"@\''), isFalse, reason: 'pattern 里留下单引号 = '
          '匹配不到任何一行');
    });

    test('口令做了百分号编码', () {
      expect(s.contains('ghp_abc%2Bdef'), isTrue);
      expect(s.contains('ghp_abc+def'), isFalse);
    });

    test('credential.helper 先判再加（无脑 --add 会堆重复项）', () {
      expect(s.contains('grep -Fxq store'), isTrue);
      expect(s.contains('--add credential.helper store'), isTrue);
    });

    test('host 为空直接报错退出', () {
      expect(rem().credentialScript(host: '', user: 'a', token: 'b')
          .contains('ERR='), isTrue);
    });
  });

  group('取远端状态（fetch）', () {
    test('是显式脚本，不塞进状态脚本里（否则每次刷新都要联网）', () {
      expect(rem().remoteScript.contains('git fetch'), isFalse,
          reason: '面板每次刷新都跑状态脚本，顺手 fetch 会把弱网下的'
              '几十秒等待加进"只是看一眼本地改动"');
    });

    test('带 GIT_TERMINAL_PROMPT=0', () {
      expect(rem().fetchScript('origin').contains('GIT_TERMINAL_PROMPT=0'),
          isTrue);
    });

    test('timeout 不存在时也能跑（busybox 环境可能没这个命令）', () {
      final s = rem().fetchScript('origin');
      expect(s.contains('command -v timeout'), isTrue);
    });
  });

  group('推送 / 拉取脚本', () {
    test('都设了 GIT_TERMINAL_PROMPT=0（否则没终端时会卡到超时）', () {
      expect(rem().pushScript(remote: 'origin', branch: 'main')
          .contains('GIT_TERMINAL_PROMPT=0'), isTrue);
      expect(rem().pullScript(remote: 'origin', branch: 'main')
          .contains('GIT_TERMINAL_PROMPT=0'), isTrue);
    });

    test('推送带 -u 建立上游跟踪', () {
      expect(rem().pushScript(remote: 'origin', branch: 'main')
          .contains('-u'), isTrue);
    });

    test('拉取只允许 fast-forward', () {
      expect(rem().pullScript(remote: 'origin', branch: 'main')
          .contains('--ff-only'), isTrue);
      expect(rem().pullScript(remote: 'origin', branch: 'main')
          .contains('--rebase'), isFalse);
    });

    test('拉取前挡住未提交改动（git 自己的报错不说该怎么办）', () {
      final s = rem().pullScript(remote: 'origin', branch: 'main');
      expect(s.contains('--porcelain'), isTrue);
      expect(s.contains('工作区有未提交的改动'), isTrue);
    });

    test('远端名/分支名都引号化（防空格与注入）', () {
      final s = rem().pushScript(remote: 'my remote', branch: 'a b');
      expect(s.contains("'my remote'"), isTrue);
      expect(s.contains("'a b'"), isTrue);
    });

    test('引号里的单引号被转义', () {
      final s = rem().pushScript(remote: "o'brien", branch: 'main');
      expect(s.contains("'o'\\''brien'"), isTrue);
    });

    test('脚本里没有裸的口令（凭据一律走 store）', () {
      final s = rem().pushScript(remote: 'origin', branch: 'main');
      expect(s.contains('https://'), isFalse);
      expect(s.contains('@github'), isFalse);
    });
  });

  group('输出解析', () {
    test('解析远端列表与领先/落后', () {
      const out = 'REPO=1\n'
          'BRANCH=main\n'
          '--REMOTES--\n'
          'R=origin|https://github.com/a/b.git\n'
          '--SYNC--\n'
          'UPSTREAM=origin/main\n'
          'AB=1 2\n'
          '--END--\n';
      final i = GitRemote.parse(out);
      expect(i.repo, isTrue);
      expect(i.branch, 'main');
      expect(i.remotes.single.name, 'origin');
      expect(i.remotes.single.url, 'https://github.com/a/b.git');
      expect(i.upstream, 'origin/main');
      // --left-right --count 的输出是「落后 领先」
      expect(i.behind, 1);
      expect(i.ahead, 2);
      expect(i.syncLabel, '领先 2 · 落后 1');
    });

    test('没有上游时 syncLabel 说清楚', () {
      final i = GitRemote.parse('REPO=1\nBRANCH=main\n'
          '--REMOTES--\n--SYNC--\nUPSTREAM=\n--END--\n');
      expect(i.hasUpstream, isFalse);
      expect(i.syncLabel, '未跟踪远端分支');
    });

    test('完全同步', () {
      final i = GitRemote.parse('--REMOTES--\n--SYNC--\n'
          'UPSTREAM=origin/main\nAB=0 0\n--END--\n');
      expect(i.syncLabel, '与远端一致');
    });

    test('解析时顺手脱敏（远端地址里可能被人塞了 token）', () {
      final i = GitRemote.parse('--REMOTES--\n'
          'R=origin|https://alice:ghp_xxx@github.com/a/b.git\n'
          '--SYNC--\n--END--\n');
      expect(i.remotes.single.url, isNot(contains('ghp_xxx')));
    });
  });

  group('失败原因翻译（不把 git 原文直接丢给用户）', () {
    test('凭据问题', () {
      expect(GitRemote.pushFailure('fatal: Authentication failed'),
          contains('PAT'));
      expect(GitRemote.pushFailure('could not read Username'), contains('PAT'));
      expect(GitRemote.pushFailure('terminal prompts disabled'),
          contains('PAT'));
    });

    test('非快进（远端有本地没有的提交）', () {
      expect(GitRemote.pushFailure('! [rejected] main -> main '
          '(non-fast-forward)'), contains('拉取'));
    });

    test('网络不通', () {
      expect(GitRemote.pushFailure('Could not resolve host: github.com'),
          contains('连不上'));
    });

    test('分支不存在', () {
      expect(GitRemote.pushFailure("src refspec main does not match any"),
          contains('提交'));
    });

    test('拉取遇到分叉 → 明确说不在手机上合并', () {
      expect(GitRemote.pullFailure('fatal: Not possible to fast-forward, '
          'aborting'), contains('手机'));
    });

    test('拉取遇到未提交改动', () {
      expect(GitRemote.pullFailure('ERR=工作区有未提交的改动'),
          contains('提交'));
    });

    test('认不出来时至少带上原文尾巴（不留空白提示）', () {
      expect(GitRemote.pushFailure('一些没见过的报错'), contains('推送失败'));
    });
  });

  group('UI 接线', () {
    final src = File('lib/project/git_panel.dart').readAsStringSync();

    test('远端卡已接进面板', () {
      expect(src.contains("import 'git_remote.dart';"), isTrue);
      expect(src.contains('_remoteCard()'), isTrue);
    });

    test('五个动作都有按钮', () {
      expect(src.contains('_setRemote'), isTrue);
      expect(src.contains('_saveCredential'), isTrue);
      expect(src.contains('_fetch'), isTrue);
      expect(src.contains('_push'), isTrue);
      expect(src.contains('_pull'), isTrue);
    });

    test('没 fetch 过时如实标注数字是旧的（不能装作新鲜）', () {
      expect(src.contains('（上次记录）'), isTrue,
          reason: '实测：不 fetch 的话远端有新提交也显示"与远端一致"');
      expect(src.contains('检查远端更新'), isTrue);
    });

    test('远端区写在 UI 上说明只支持 HTTPS、不做 SSH', () {
      expect(src.contains('只支持 HTTPS'), isTrue);
      expect(src.contains('SSH'), isTrue);
    });

    test('旧的那句"不涉及远端"已经改掉（留着会自相矛盾）', () {
      expect(src.contains('只做本地版本管理，不涉及远端'), isFalse);
    });
  });
}
