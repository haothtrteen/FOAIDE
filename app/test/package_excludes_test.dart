import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Bug 639 同族 · 打包排除清单（tools/package-excludes.txt）的回归测试
///
/// 背景：整理 GitHub 上传包时，`tools/make_release_tarball.sh` 的排除校验
/// 报了两个**根本不存在的失败**：
///
///   ❌ 排除失效: ./app/build 仍在包里
///   ❌ 排除失效: ./app/android/build 仍在包里
///
/// 真因：校验用的是 `grep -F "$p"`，那是**子串**匹配 ——
///   - `./app/build`           命中 `./app/build_progress_preview.html`
///   - `./app/android/build`   命中 `./app/android/build.gradle.kts`
/// 这两个都是**必须入库**的源码文件，却被算成"该排除却没排除"。
///
/// 修法：判据改成「条目 == 规则本身」或「条目以 规则 + "/" 开头」。
/// 本文件把这条不变量固化为测试：**任何一条排除规则都不许命中被 git 跟踪的文件**。
///
/// 只做路径比对，不分析语义 —— 语义分析正是当初漏掉它的原因。
void main() {
  final repoRoot = _findRepoRoot();
  final exclFile = File('${repoRoot.path}/tools/package-excludes.txt');
  final scriptFile = File('${repoRoot.path}/tools/make_release_tarball.sh');

  List<String> rules() => exclFile
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'))
      .map((l) => l.trim())
      .toList();

  /// 规则是否命中某个归档条目（与脚本里的判据**必须保持一致**）
  bool hits(String rule, String entry) =>
      entry == rule || entry.startsWith('$rule/');

  group('Bug 639 同族 · 打包排除清单', () {
    test('排除清单与打包脚本都存在', () {
      expect(exclFile.existsSync(), isTrue,
          reason: 'tools/package-excludes.txt 是 make_release_tarball.sh 的输入');
      expect(scriptFile.existsSync(), isTrue,
          reason: '缺少 tools/make_release_tarball.sh');
    });

    test('打包脚本通过 bash -n（会被真正执行，语法必须合法）', () {
      final r = Process.runSync('bash', ['-n', scriptFile.path]);
      expect(r.exitCode, 0, reason: 'bash -n 失败:\n${r.stderr}');
    });

    test('核心不变量：没有任何规则命中 git 跟踪的文件', () {
      // 这是本轮那个假阳性 bug 的直接回归测试。
      // 一旦有人加了 `./app/build` 这类"目录名恰好是别的文件名前缀"的规则，
      // 这里就会失败并点名是哪个文件被误伤。
      final tracked = _trackedFiles(repoRoot);
      expect(tracked, isNotEmpty, reason: 'git ls-files 没查到文件，测试环境有问题');

      final offenders = <String>[];
      for (final rule in rules()) {
        for (final f in tracked) {
          if (hits(rule, './$f')) {
            offenders.add('规则 "$rule" 误伤跟踪文件 "$f"');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '排除规则把源码文件也算进去了（假阳性 bug 复发）：\n'
              '${offenders.take(10).join('\n')}');
    });

    test('历史上踩过的假阳性：build 相关规则不再误伤 build_progress_preview.html', () {
      // 单独钉死这一条：它是真出过事的，不能只靠上面那条泛化测试。
      final tracked = _trackedFiles(repoRoot);
      expect(tracked.contains('app/build_progress_preview.html'), isTrue,
          reason: 'app/build_progress_preview.html 应当入库');

      for (final rule in rules()) {
        expect(hits(rule, './app/build_progress_preview.html'), isFalse,
            reason: '规则 "$rule" 把 build_progress_preview.html 当成了要排除的目录');
      }
    });

    test('该排除的产物目录确实在清单里', () {
      final r = rules();
      for (final must in <String>[
        './dist',
        './app/build',
        './app/.dart_tool',
        './app/android/build',
      ]) {
        expect(r.contains(must), isTrue,
            reason: '"$must" 必须在排除清单里，否则包体会失控膨胀');
      }
    });

    test('不可再生的资产不在清单里（rootfs 没有公共下载源）', () {
      // 见 tools/package-excludes.txt 的头注释：rootfs 被 .gitignore 排除、
      // 且 fetch_assets.sh 没有默认 ROOTFS_URL，丢了只能 debootstrap 自建。
      // 所以默认包**必须带上它**。若有人把它加进排除清单，这里会拦住。
      final r = rules();
      expect(
        r.contains('./app/assets/rootfs/debian-minbase-arm64.tar.gz'),
        isFalse,
        reason: 'rootfs 不可再生，默认包必须包含（要瘦包请用 --slim）',
      );
    });

    test('清单里没有残留的占位/无效路径', () {
      // 排查过程中曾误留过 `./NONEXISTENT_PATH`（中断的测试没回滚干净），
      // 它会让 dist/ 整个被打进包（2.8GB）。
      for (final rule in rules()) {
        expect(rule.startsWith('./'), isTrue,
            reason: '规则必须以 ./ 开头（tar 排除路径相对仓库根）: $rule');
      }
    });
  });
}

/// 向上找仓库根（含 .git 的那一层）
Directory _findRepoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory('${d.path}/.git').existsSync()) return d;
    final p = d.parent;
    if (p.path == d.path) break;
    d = p;
  }
  // 单测从 app/ 目录跑，仓库根在其上一层
  final fromApp = Directory('${Directory.current.path}/..');
  if (Directory('${fromApp.path}/.git').existsSync()) {
    return Directory(fromApp.path);
  }
  throw StateError('找不到仓库根（含 .git）：从 ${Directory.current.path} 向上 8 层未命中');
}

/// git 跟踪的文件列表（相对仓库根，不带 ./ 前缀）
List<String> _trackedFiles(Directory root) {
  final r = Process.runSync('git', ['ls-files'], workingDirectory: root.path);
  if (r.exitCode != 0) return <String>[];
  return (r.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}
