import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/env/proot_bridge.dart';
import 'package:foaide/project/git_panel.dart';

/// Git 面板守卫（alpha.93）。
///
/// 分两类：
/// - **纯逻辑**：命令输出的解析全在 `GitRepo.parse` 这类静态函数里，
///   不用起 MethodChannel 就能测，覆盖了最容易出错的部分——
///   porcelain 的转义路径、重命名箭头、日志里 subject 带 `|`。
/// - **源码级接线**：与 design_wiring_test 同款套路。
///   「枚举加了成员但 children 没加」编译得过、运行时不抛异常，
///   只是点了「版本」显示别的区，只能靠断言拦。
void main() {
  group('输出解析 · 三种前置状态', () {
    test('容器里没有 git', () {
      final s = GitRepo.parse('NOGIT\n');
      expect(s.gitFound, isFalse);
      expect(s.isRepo, isFalse);
    });

    test('工程目录不存在', () {
      final s = GitRepo.parse('NOTDIR\n');
      expect(s.dirExists, isFalse);
      expect(s.error, isNotEmpty, reason: '要给人一句能看懂的话，不是空白面板');
    });

    test('目录存在但还没 init', () {
      final s = GitRepo.parse('REPO=0\n');
      expect(s.isRepo, isFalse);
      expect(s.files, isEmpty);
      expect(s.log, isEmpty);
    });
  });

  group('输出解析 · 正常仓库', () {
    test('分支 / 身份 / 文件 / 历史都能对上', () {
      const out = 'REPO=1\n'
          'BRANCH=main\n'
          'NAME=FOA\n'
          'EMAIL=foa@localhost\n'
          '--FILES--\n'
          ' M lib/main.dart\n'
          '?? test/a_test.dart\n'
          'A  lib/new.dart\n'
          '--LOG--\n'
          'a1b2c3d|2026-09-26|FOA|init\n'
          '--END--\n';
      final s = GitRepo.parse(out);
      expect(s.isRepo, isTrue);
      expect(s.branch, 'main');
      expect(s.userName, 'FOA');
      expect(s.userEmail, 'foa@localhost');
      expect(s.files.length, 3);
      expect(s.files.map((f) => f.path).toList(),
          ['lib/main.dart', 'test/a_test.dart', 'lib/new.dart']);
      expect(s.log.length, 1);
      expect(s.log.first.hash, 'a1b2c3d');
      expect(s.log.first.date, '2026-09-26');
      expect(s.log.first.subject, 'init');
    });

    test('分支取不到时留空，不把 "HEAD" 当分支名', () {
      final s = GitRepo.parse('REPO=1\nBRANCH=\n--FILES--\n--LOG--\n');
      expect(s.branch, isEmpty);
    });

    test('日志 subject 里有竖线也不会被截断', () {
      final s = GitRepo.parse(
          'REPO=1\n--FILES--\n--LOG--\nabc1234|2026-09-26|FOA|a|b|c\n');
      expect(s.log.first.subject, 'a|b|c',
          reason: 'subject 用 split 会只剩第一段');
    });

    test('空仓库（没有任何提交）不炸', () {
      final s = GitRepo.parse('REPO=1\nBRANCH=main\n--FILES--\n--LOG--\n--END--\n');
      expect(s.files, isEmpty);
      expect(s.log, isEmpty);
      expect(s.isRepo, isTrue);
    });
  });

  group('porcelain 行解析', () {
    GitFileEntry one(String line) => GitRepo.parse(
        'REPO=1\n--FILES--\n$line\n--LOG--\n').files.single;

    test('普通路径', () {
      expect(one(' M lib/main.dart').path, 'lib/main.dart');
    });

    test('未跟踪', () {
      final f = one('?? notes.md');
      expect(f.untracked, isTrue);
      expect(f.label, '未跟踪');
    });

    test('带空格的路径（git 会加引号）', () {
      expect(one('?? "my file.dart"').path, 'my file.dart',
          reason: '不还原引号的话 git add 会拿到被拆开的 pathspec');
    });

    test('重命名只取新名字', () {
      expect(one('R  old/name.dart -> lib/name.dart').path, 'lib/name.dart');
      expect(one('R  old/name.dart -> lib/name.dart').label, contains('重命名'));
    });

    test('已暂存与未暂存的区分', () {
      expect(one('M  a.dart').staged, isTrue);
      expect(one(' M a.dart').staged, isFalse);
      expect(one('?? a.dart').staged, isFalse);
    });
  });

  group('提交结果摘要', () {
    test('常规提交压成一句人话', () {
      final s = GitRepo.commitSummary(
          '[main a1b2c3d] 修了首页崩溃\n 2 files changed, 5 insertions(+)');
      expect(s, contains('main'));
      expect(s, contains('a1b2c3d'));
      expect(s, contains('2 个文件'));
    });

    test('首次提交（root-commit）也能认', () {
      final s = GitRepo.commitSummary('[main (root-commit) abc1234] init');
      expect(s, contains('abc1234'));
    });

    test('认不出来时原样回传，不丢信息', () {
      expect(GitRepo.commitSummary('some other output'), 'some other output');
      expect(GitRepo.commitSummary(''), '已提交');
    });
  });

  group('shell 引号', () {
    test('包单引号并对内部单引号转义', () {
      expect(GitRepo.q('a b'), "'a b'");
      expect(GitRepo.q("it's"), "'it'\\''s'",
          reason: "不转义的话 git add 会拿到半个字符串，"
              '后面的路径全变成命令');
      expect(GitRepo.q('p\$(rm -rf /)'), "'p\$(rm -rf /)'",
          reason: '单引号串内不做命令替换');
    });
  });

  group('面板接线 · 三处联动', () {
    /// 剥注释行：本文件的断言多是 contains，注释里引用旧写法会假绿。
    String code(String rel) => File(rel)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    test('_Section 有 git 成员且紧挨 manifest 之后', () {
      final page = code('lib/project/project_page.dart');
      final m = RegExp(r'enum _Section \{([^}]*)\}').firstMatch(page);
      expect(m, isNotNull);
      final members = m!
          .group(1)!
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      expect(members, contains('git'));
      expect(members.indexOf('git'), members.indexOf('manifest') + 1,
          reason: '改完清单就该存一档，两区必须相邻');
    });

    test('label 与 icon 两个 switch 都有 git 臂', () {
      final page = code('lib/project/project_page.dart');
      expect(RegExp(r"_Section\.git\s*=>\s*'版本'").hasMatch(page), isTrue);
      expect(RegExp(r'_Section\.git\s*=>\s*Icons\.\w+').hasMatch(page), isTrue);
    });

    test('GitPanel 已 import 且接进 _buildSections', () {
      final page = code('lib/project/project_page.dart');
      expect(page.contains("import 'git_panel.dart';"), isTrue);
      final i = page.indexOf('Widget _buildSections()');
      final body = page.substring(i, page.indexOf('Widget _buildSideTree()', i));
      expect(body.contains('GitPanel('), isTrue,
          reason: 'import 了没接进 children = 点「版本」看到的是别的区');
    });
  });

  group('生成的脚本（真机跑出来的坑都在这）', () {
    GitRepo repo() => GitRepo(bridge: ProotBridge(), projectName: 'demo');

    test('日志用 tformat，不是 format', () {
      // 实测：format 在最后一条之后不换行，末条日志会和 --END-- 粘成一行，
      // 解析出来 subject 尾巴挂着 "--END--"。
      expect(repo().statusScript.contains('tformat'), isTrue);
      expect(RegExp(r"--pretty=(?!tformat)").hasMatch(repo().statusScript), isFalse);
    });

    test('safe.directory 加了存在性判断，不会每次刷新重复追加', () {
      final s = repo().statusScript;
      expect(s.contains('grep -Fqx'), isTrue,
          reason: '无脑 --add 会把 ~/.gitconfig 堆满重复项');
      expect(s.contains('--add safe.directory'), isTrue);
    });

    test('未跟踪目录要展开成文件（-uall）', () {
      expect(repo().statusScript.contains('--porcelain -uall'), isTrue,
          reason: '默认会把整个目录压成一行 ?? lib/，面板没法按文件勾选');
    });

    test('commit 脚本：路径逐个单引号包裹，多行说明拆成多个 -m', () {
      final s = repo().commitScript(
        message: '标题\n正文',
        paths: ['lib/a.dart', "my file.dart"],
        name: 'FOA',
        email: 'foa@localhost',
      );
      expect(s, contains("'lib/a.dart'"));
      expect(s, contains("'my file.dart'"));
      expect(s, contains("-m '标题' -m '正文'"));
      expect(s, contains('git config user.email'),
          reason: '仓库身份可能没写，提交前必须补');
    });

    test('init 脚本：分支 -b 有回落、补 .gitignore 只在缺失时', () {
      final s = repo().initScript(name: 'FOA', email: 'foa@localhost');
      expect(s, contains('git init -q -b main 2>/dev/null || git init -q'),
          reason: '-b 需要 git ≥ 2.28，老版本整条失败要能回落');
      expect(s, contains("if [ ! -f .gitignore ]; then"),
          reason: '已有 .gitignore 的工程不能被覆盖');
      expect(s, contains('.dart_tool/'));
    });
  });

  group('能力边界（不吹牛）', () {
    test('脚本里没有 push / pull / 远端操作', () {
      final src = File('lib/project/git_panel.dart').readAsStringSync();
      for (final op in ['git push', 'git pull', 'git remote']) {
        expect(src.contains(op), isFalse,
            reason: '面板对外声明只做本地版本管理，代码里就不该出现 $op');
      }
    });

    test('没有「丢弃改动 / 回滚」这类不可逆入口', () {
      final src = File('lib/project/git_panel.dart').readAsStringSync();
      expect(src.contains('git checkout --'), isFalse);
      expect(src.contains('git reset --hard'), isFalse);
      expect(src.contains('git clean'), isFalse,
          reason: '误点一次就丢工作，宁可不给，需要回退请用户在电脑上做');
    });

    test('git 缺失时有兜底安装入口，而不是空白页', () {
      final src = File('lib/project/git_panel.dart').readAsStringSync();
      expect(src.contains('NOGIT'), isTrue);
      expect(src.contains('ToolchainEnsure().git()'), isTrue,
          reason: '复用构建链路的安装流程，不要另写一份');
    });

    test('提交前会补身份，否则第一次提交必卡在 who you are', () {
      final src = File('lib/project/git_panel.dart').readAsStringSync();
      expect(src.contains('git config user.email'), isTrue);
      expect(src.contains('defaultUserEmail'), isTrue);
    });
  });
}
