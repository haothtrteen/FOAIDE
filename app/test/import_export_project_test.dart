import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/demo/demo_project_creator.dart';
import 'package:foaide/demo/project_importer.dart';

/// 「导入 Flutter 源码工程」+「打包成 Flutter 源码工程」的契约测试。
///
/// 按项目惯例（见 dev-handbook/03）：**不 mock MethodChannel**。
/// 这几条测试守的是能在沙箱里真验的东西：
/// - 纯函数（命名归一化、pubspec 解析）—— 真跑，真断言；
/// - 排错清单 / 命令拼写 —— 静态读源码断言，拦"改一处忘一处"；
/// - 原生通道名 —— 反向断言"没引入不存在的通道"，正向断言"用到的分支真在
///   Kotlin 里"。
///
/// 真机行为（解压、大包、SAF 落盘）单测验不了，见 dev-handbook/03 的真机清单。
void main() {
  // ==================================================================
  // ① 名称归一化 —— 必须保证结果能过 DemoProjectCreator.validateName
  // ==================================================================

  group('导入 · 工程名归一化', () {
    /// 所有 guessName 的输出都必须过校验 —— 这是硬约束：
    /// 预填一个点「导入」才报错的名字，比不预填还糟。
    void expectValid(String got) {
      expect(DemoProjectCreator.validateName(got), isNull,
          reason: '「$got」过不了 validateName —— 预填值必须是合法工程名');
    }

    test('中文工程名折成下划线（不能留下非法字符）', () {
      final got = ProjectImporter.guessName(
        pubName: '我的应用',
        archiveName: 'x.zip',
      );
      expectValid(got);
      expect(RegExp(r'^[a-z0-9_]+$').hasMatch(got), isTrue,
          reason: '归一化后只该剩小写字母/数字/下划线：$got');
    });

    test('连字符与空格折成下划线（不产生连续下划线）', () {
      final got = ProjectImporter.guessName(
        pubName: 'my-cool app',
        archiveName: 'x.zip',
      );
      expect(got, 'my_cool_app');
      expectValid(got);
    });

    test('数字开头补 p 前缀（Dart 包名不许数字开头）', () {
      final got = ProjectImporter.guessName(
        pubName: '2048_game',
        archiveName: 'x.zip',
      );
      expect(got.startsWith('p'), isTrue, reason: '数字开头必须补前缀：$got');
      expectValid(got);
    });

    test('保留字（android/build/lib/root）加后缀绕开', () {
      for (final reserved in ['android', 'build', 'lib', 'root']) {
        final got = ProjectImporter.guessName(
          pubName: reserved,
          archiveName: 'x.zip',
        );
        expectValid(got);
        expect(got == reserved, isFalse,
            reason: '保留字「$reserved」必须被改写：$got');
      }
    });

    test('超长名字截到 30 字符以内且仍合法', () {
      final long = 'a' * 80;
      final got = ProjectImporter.guessName(pubName: long, archiveName: 'x.zip');
      expect(got.length, lessThanOrEqualTo(30));
      expectValid(got);
    });

    test('pubspec 拿不到时回退到压缩包文件名（剥扩展名）', () {
      final got = ProjectImporter.guessName(
        pubName: null,
        archiveName: 'awesome_app-master.zip',
      );
      // `-` 折 `_`，故 `awesome_app_master`
      expect(got, 'awesome_app_master');
      expectValid(got);
    });

    test('文件名也是中文 → 归一化后不能为空（必须兜底）', () {
      for (final archive in ['我的应用.zip', '工程.tar.gz', '---.zip']) {
        final got = ProjectImporter.guessName(
          pubName: null,
          archiveName: archive,
        );
        expectValid(got);
        expect(got.isNotEmpty, isTrue);
      }
    });

    test('两条来源全废时兜底 imported_app', () {
      final got = ProjectImporter.guessName(pubName: null, archiveName: '.zip');
      expect(got, 'imported_app');
      expectValid(got);
    });

    test('guessName 对身份输入幂等（合法名原样返回）', () {
      for (final n in ['my_app', 'app123', 'a']) {
        expect(ProjectImporter.guessName(pubName: n, archiveName: 'x.zip'), n);
      }
    });
  });

  // ==================================================================
  // ② pubspec 文本解析（脏输入容忍）
  // ==================================================================

  group('导入 · 包内 pubspec 解析', () {
    test('取第一层的 name:', () {
      final t = ProjectImporter.parsePubspecName(
        'name: my_app\ndescription: 示例\nversion: 1.0.0+1\n',
      );
      expect(t, 'my_app');
    });

    test('忽略 dependencies 里缩进的子键（缩进即非顶层）', () {
      final t = ProjectImporter.parsePubspecName(
        'name: outer\n'
        'dependencies:\n'
        '  name: inner_not_this\n',
      );
      expect(t, 'outer');
    });

    test('容忍 BOM / CRLF / 注释 / 引号（Windows 打的包）', () {
      final t = ProjectImporter.parsePubspecName(
        '\uFEFFname: "quoted_app"\r\n# 注释行\r\nname: 后面的不算\r\n',
      );
      expect(t, 'quoted_app');
    });

    test('行内注释要剥掉', () {
      final t = ProjectImporter.parsePubspecName('name: real_app # 备注\n');
      expect(t, 'real_app');
    });

    test('没有 name: 时返回 null（不能瞎猜）', () {
      expect(ProjectImporter.parsePubspecName('description: 无名字\n'), isNull);
      expect(ProjectImporter.parsePubspecName(''), isNull);
    });

    test('解析结果直接喂 guessName 仍合法', () {
      final raw = ProjectImporter.parsePubspecName('\uFEFFname: 中文工程\r\n');
      final got =
          ProjectImporter.guessName(pubName: raw, archiveName: 'x.zip');
      expect(DemoProjectCreator.validateName(got), isNull);
    });
  });

  // ==================================================================
  // ③ 支持的格式判定
  // ==================================================================

  group('导入 · 格式识别', () {
    test('四种扩展名都认，且大小写不敏感（手机上传常是 .ZIP）', () {
      for (final n in [
        'a.zip', 'a.ZIP',
        'a.tar.gz', 'a.TAR.GZ',
        'a.tgz', 'a.tar.xz', 'a.txz', 'a.tar',
      ]) {
        expect(ProjectImporter.isArchive(n), isTrue, reason: '$n 应被识别');
      }
    });

    test('非压缩包不认（防止用户选了 APK/截图就直接开解压）', () {
      for (final n in ['a.apk', 'app-release.aab', 'shot.png', 'pubspec.yaml']) {
        expect(ProjectImporter.isArchive(n), isFalse, reason: '$n 不该被识别');
      }
    });
  });

  // ==================================================================
  // ④ 排除清单 —— 打包正确性
  // ==================================================================

  group('导出 · 排除清单', () {
    test('必须排除体积大头（构建缓存 / VCS / IDE）', () {
      const must = [
        '.dart_tool', 'build', '.git', '.gradle', '.idea', '.vscode',
        'android/.gradle', 'android/build', 'android/app/build',
      ];
      for (final e in must) {
        expect(ProjectImporter.kPackExcludes, contains(e),
            reason: '不排除「$e」会让导出包虚胖');
      }
    });

    test('必须排除 macOS 垃圾（自家包被自家吃得干净）', () {
      expect(ProjectImporter.kPackExcludes, contains('__MACOSX'));
      expect(ProjectImporter.kPackExcludes, contains('.DS_Store'));
    });

    test('**不得**排除 lib / android / pubspec —— 排除过度包就废了', () {
      // 这条是反向断言的核心：排除清单是"可调优"的，但一旦有人图省事
      // 写了个宽泛模式把源码目录也干掉，导出的包就不可用了。
      for (final bad in ['lib', 'android', 'ios', 'test', 'pubspec.yaml']) {
        expect(ProjectImporter.kPackExcludes, isNot(contains(bad)),
            reason: '「$bad」是源码工程的一部分，排除掉导入后无法构建');
      }
    });

    test('不得出现 `*/build` 这种写法（会漏掉工程根的 build/）', () {
      for (final e in ProjectImporter.kPackExcludes) {
        expect(e.startsWith('*/'), isFalse,
            reason: '「$e」用了 `*/` 通配——tar 的相对模式本该匹配任意层级的 '
                'build/，写成 `*/build` 反而漏掉工程根那一份（最大的一份）');
      }
    });
  });

  // ==================================================================
  // ⑤ 命令拼写契约
  // ==================================================================

  group('契约 · 列成员命令', () {
    test('.zip 用 `unzip -Z1` 而非 `unzip -l`', () {
      final cmd = ProjectImporter.listCommand('/root/imports/a.zip', 'a.zip');
      expect(cmd.contains('unzip -Z1'), isTrue,
          reason: '-Z1 每行一个名字；-l 是给人看的表格，要解析列宽表头，脆');
      expect(cmd.contains('unzip -l'), isFalse);
    });

    test('各扩展名的 list 命令分派正确', () {
      final cases = {
        'a.tar.gz': 'tar -tzf',
        'a.tgz': 'tar -tzf',
        'a.tar.xz': 'tar -tJf',
        'a.txz': 'tar -tJf',
        'a.tar': 'tar -tf',
      };
      cases.forEach((name, expectCmd) {
        final cmd = ProjectImporter.listCommand('/root/imports/$name', name);
        expect(cmd.contains(expectCmd), isTrue,
            reason: '$name 应走 `$expectCmd`，实得：$cmd');
      });
    });

    test('包名一律单引号包裹（防命令替换注入）', () {
      // 构造一个含 `$()` 的文件名。**不能用 raw string** —— 那样 `\$` 是
      // 字面量反斜杠加美元符，与真实输入不符。
      const evil = '/root/imports/a\$(rm -rf ~).zip';
      final cmd = ProjectImporter.listCommand(evil, 'a.zip');
      expect(cmd, contains("'/root/imports/a\$(rm -rf ~).zip'"),
          reason: '必须是单引号版转义，否则用户上传的奇怪文件名会被 shell 执行');
      expect(cmd.contains('"'), isFalse, reason: '不该出现双引号');
    });

    test("单引号本身被正确转义（拼成 '\\'' 形式）", () {
      expect(ProjectImporter.quote("it's"), r"'it'\''s'");
    });
  });

  group('契约 · 读 pubspec 命令', () {
    test('.zip 用 `unzip -p`（输出到 stdout，不落盘）', () {
      final cmd = ProjectImporter.readPubspecCommand(
          '/root/imports/a.zip', 'a.zip', '');
      expect(cmd.contains('unzip -p'), isTrue);
      expect(cmd.contains('pubspec.yaml'), isTrue);
    });

    test('单层目录前缀要拼进成员名（GitHub ZIP 的 xxx-main/）', () {
      final cmd = ProjectImporter.readPubspecCommand(
          '/root/imports/a.zip', 'a.zip', 'awesome-main');
      expect(cmd.contains('awesome-main/pubspec.yaml'), isTrue,
          reason: '少了这一层就读不到内容，pubspec 名字会永远回退到文件名');
    });

    test('tar 走 -O 输出到 stdout（三个变体都对）', () {
      final cases = {
        'a.tar.gz': 'tar -xzOf',
        'a.tar.xz': 'tar -xJOf',
        'a.tar': 'tar -xOf',
      };
      cases.forEach((name, expectCmd) {
        final cmd = ProjectImporter.readPubspecCommand(
            '/root/imports/$name', name, '');
        expect(cmd.contains(expectCmd), isTrue, reason: '$name → $cmd');
      });
    });
  });

  group('契约 · 打包命令', () {
    final cmd = ProjectImporter.packCommand(
      name: 'my_app',
      guestTar: '/root/imports/my_app-20260921-1430.tar.gz',
    );

    test('--exclude 出现在 -C 之前（tar 按出现顺序处理）', () {
      final ex = cmd.indexOf('--exclude');
      final dashC = cmd.indexOf(' -C ');
      expect(ex, greaterThan(0));
      expect(dashC, greaterThan(ex),
          reason: '--exclude 写到 -C 后面会被 tar 当成文件名');
    });

    test('以 `-C <工程根父目录> <工程名>` 结尾（成员是 my_app/... 而非绝对路径）', () {
      expect(cmd.trimRight().endsWith("-C '/root/projects' 'my_app'"), isTrue,
          reason: '实得：$cmd');
    });

    test('压缩器是 -czf（gzip，手机端 tar 一定能解）', () {
      expect(cmd.contains('-czf'), isTrue);
    });

    test('排除项逐个用单引号包裹（不靠 shell 分词）', () {
      expect(cmd.contains("--exclude='.dart_tool'"), isTrue);
      expect(cmd.contains("--exclude='build'"), isTrue);
    });

    test('工程名含单引号时整体转义（不破坏后续参数）', () {
      final c = ProjectImporter.packCommand(
        name: "o'brien",
        guestTar: '/root/imports/x.tar.gz',
      );
      expect(c.contains(r"'o'\''brien'"), isTrue);
    });
  });

  // ==================================================================
  // ⑥ 路径常量 —— 与主页扫描目录、原生落脚点必须对齐
  // ==================================================================

  group('契约 · 路径常量', () {
    test('工程根与主页 _loadProjects 的扫描目录一致', () {
      final home = File('lib/ui/home_page.dart').readAsStringSync();
      expect(home.contains("browse('${ProjectImporter.kProjectsRoot}')"), isTrue,
          reason: '主页扫的不是 /root/projects 的话，导入的工程不会出现在列表里');
      expect(ProjectImporter.kProjectsRoot, '/root/projects');
    });

    test('暂存区在 imports 下、**不在 projects 下**（半成品不能进工程列表）', () {
      expect(ProjectImporter.kStagingRoot.startsWith(ProjectImporter.kImportsRoot),
          isTrue);
      expect(ProjectImporter.kStagingRoot.startsWith(ProjectImporter.kProjectsRoot),
          isFalse,
          reason: '暂存放 projects 下的话，解压到一半就出现在用户眼前，'
              '点了构建会报一个指不到这里的错');
    });

    test('暂存区是 imports 的隐藏子目录（文件浏览器里不刺眼）', () {
      expect(ProjectImporter.kStagingRoot, '.foa_extract'.isEmpty
          ? ''
          : '${ProjectImporter.kImportsRoot}/.foa_extract');
      expect(ProjectImporter.kStagingPrefix, '_foa_');
      expect(ProjectImporter.kStagingPrefix.startsWith('_'), isTrue,
          reason: '前缀用于清扫过滤，必须能与用户自己的文件区分开');
    });

    test('导入源落脚点与原生 IMPORTS_GUEST 一致', () {
      final kt = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
      expect(kt.contains('IMPORTS_GUEST = "${ProjectImporter.kImportsRoot}"'),
          isTrue,
          reason: 'Dart 侧算出来的导入路径必须与原生落点同源');
    });
  });

  // ==================================================================
  // ⑦ 原生通道契约 —— 反向 + 正向
  // ==================================================================

  group('契约 · 不多调一个原生方法，也不漏一个', () {
    late String importerSrc;
    late String ktSrc;

    setUpAll(() {
      importerSrc = File('lib/demo/project_importer.dart').readAsStringSync();
      ktSrc = File(
        'android/app/src/main/kotlin/dev/foa/flutter_on_android/MainActivity.kt',
      ).readAsStringSync();
    });

    test('**反向**：本模块不得出现任何 invokeMethod（通道全在既有桥里）', () {
      expect(importerSrc.contains('invokeMethod'), isFalse,
          reason: 'project_importer 只该用 ProotBridge / FileBrowserBridge，'
              '直接 invokeMethod 意味着有人加了个原生不存在的通道名');
    });

    test('**反向**：不得引入 MethodChannel 新实例', () {
      expect(importerSrc.contains('MethodChannel'), isFalse);
    });

    test('**正向**：用到的三个原生分支都真实存在', () {
      for (final branch in ['"pickImportFile" ->', '"exportFile" ->']) {
        expect(ktSrc.contains(branch), isTrue,
            reason: 'Kotlin 里没有 $branch 分支，功能在真机上会直接缺一块');
      }
      // 删除走 fsDelete（FileBrowserBridge.delete）
      expect(ktSrc.contains('"fsDelete" ->'), isTrue);
    });

    test('**正向**：导出的源路径落在 resolveRootfsPath 白名单内', () {
      // /root/imports 在 rootfs 根内 → exportFile 的 resolveRootfsPath 放行，
      // 这就是"零 Kotlin 改动"成立的理由。若哪天白名单收紧到
      // /root/projects，这条会红，提醒必须同步改原生。
      final walk = ktSrc.indexOf('private fun resolveRootfsPath');
      expect(walk, greaterThan(0));
      final body = ktSrc.substring(walk, walk + 400);
      expect(body.contains('ROOTFS_REL'), isTrue,
          reason: '白名单锚在 rootfs 根，而 /root/imports 就在其下');
      expect(ProjectImporter.kImportsRoot.startsWith('/root/'), isTrue);
    });

    test('**正向**：exportFile 强制 isFile（打包产物必须是文件）', () {
      expect(ktSrc.contains('if (f == null || !f.isFile)'), isTrue,
          reason: '导出源若是个目录，SAF 会失败——原生这层守卫是前提');
    });
  });

  // ==================================================================
  // ⑧ UI 接线契约
  // ==================================================================

  group('契约 · 主页导入入口', () {
    late String src;
    setUpAll(() => src = File('lib/ui/home_page.dart').readAsStringSync());

    test('创建面板里有导入按钮且文案点明格式', () {
      expect(src.contains('导入 Flutter 源码工程'), isTrue);
      expect(src.contains('.zip / .tar.gz'), isTrue,
          reason: '不写格式，用户会拿 .7z / .rar 来试');
    });

    test('导入成功走 pop(true) —— 复用外层刷新链路', () {
      // 不弹自己的 SnackBar、不自己调 _loadProjects，交给 _showCreateSheet
      expect(src.contains('Navigator.of(context).pop(true); // 触发外层 _loadProjects()'),
          isTrue,
          reason: '导入了工程但列表不刷新，用户会以为失败然后重复导入');
    });

    test('进度框 canPop: false（exec 阻塞期间无法取消，给按钮等于骗人）', () {
      final i = src.indexOf('class _ImportProgressDialog');
      expect(i, greaterThan(0));
      final body = src.substring(i, i + 300);
      expect(body.contains('canPop: false'), isTrue);
      expect(body.contains('PopScope'), isTrue);
    });

    test('导入/创建互斥：三个交互点的禁用条件都带 _importing', () {
      // TextField / 模板卡 / 关闭按钮 —— 漏一个就会出现"导入中点创建"
      final n = RegExp(r'_importing').allMatches(src).length;
      expect(n, greaterThanOrEqualTo(6),
          reason: '_importing 出现次数太少（$n），多半漏了某处禁用条件');
    });

    test('入口用 ProjectImporter，不自己拼 shell', () {
      expect(src.contains('ProjectImporter()'), isTrue);
      expect(src.contains('importArchive('), isTrue);
    });

    test('非压缩包 / 非 Flutter 工程在**解压前**就被拦下', () {
      expect(src.contains('ProjectImporter.isArchive('), isTrue,
          reason: '不拦的话，用户选了个 APK 会先解压 500MB 再报错');
      expect(src.contains('probe('), isTrue,
          reason: 'probe 只列成员名，必须在 importArchive 之前跑');
      final iProbe = src.indexOf('_importer.probe(');
      final iImport = src.indexOf('_importer.importArchive(');
      expect(iProbe, greaterThan(0));
      expect(iProbe, lessThan(iImport), reason: '顺序反了就等于没拦');
    });

    test('进度框在 State 之外定义（showDialog builder 会重建）', () {
      final cls = src.indexOf('class _ImportProgressDialog');
      final state = src.indexOf('class _CreateDemoSheetState');
      expect(cls, greaterThan(0));
      expect(state, greaterThan(0));
      // 挂在 State 里的私有 widget 会随 BottomSheet 一起被卸载，
      // 而 showDialog 的 builder 在路由层重建 —— 必须是顶层类。
      expect(cls, greaterThan(state),
          reason: '_ImportProgressDialog 必须在 _CreateDemoSheetState 之后，'
              '且是顶层类（不能是 State 的成员）');
      expect(src.contains('const _ImportProgressDialog()'), isTrue);
    });
  });

  group('契约 · 工程页导出按钮', () {
    late String src;
    setUpAll(() => src = File('lib/project/project_page.dart').readAsStringSync());

    test('AppBar 有导出按钮且 tooltip 点明产物格式', () {
      expect(src.contains('Icons.ios_share_outlined'), isTrue);
      expect(src.contains('导出源码工程（.tar.gz）'), isTrue);
    });

    test('导出中禁用（防连点造成并发打包）', () {
      expect(src.contains('_exporting'), isTrue);
      expect(src.contains('if (_exporting) return;'), isTrue,
          reason: '没有早退守卫，连点会并行跑两个 tar');
    });

    test('确认框列出排除清单（用户看到 300MB→8MB 才不会以为坏了）', () {
      expect(src.contains('ProjectImporter.kPackExcludes'), isTrue,
          reason: '文案硬编码一份清单，改常量时会漂移');
    });

    test('按钮在 AppBar actions 内、与清单保存按钮并列', () {
      final iActions = src.indexOf('actions: [', src.indexOf('appBar: AppBar('));
      final iExport = src.indexOf('Icons.ios_share_outlined');
      final iSave = src.indexOf('Icons.save_outlined');
      expect(iActions, greaterThan(0));
      expect(iExport, greaterThan(iActions));
      expect(iExport, lessThan(iSave),
          reason: '导出按钮应排在清单保存按钮之前（后者只在清单区可见）');
    });

    test('打包 + 导出一并在 packAndExport 里（成功/取消都删临时 tar）', () {
      expect(src.contains('packAndExport('), isTrue);
      final imp = File('lib/demo/project_importer.dart').readAsStringSync();
      final i = imp.indexOf('Future<String?> packAndExport(');
      expect(i, greaterThan(0));
      final body = imp.substring(i, i + 900);
      expect(body.contains('finally'), isTrue,
          reason: '没有 finally，取消保存时临时 tar 会永远留在 /root/imports');
      expect(body.contains('_rmrf('), isTrue);
    });
  });

  // ==================================================================
  // ⑨ 清理与回滚（静态契约）
  // ==================================================================

  group('契约 · 失败清理与幂等清扫', () {
    late String src;
    setUpAll(() => src = File('lib/demo/project_importer.dart').readAsStringSync());

    test('落位失败时暂存与目标都清掉（不留半个工程）', () {
      final i = src.indexOf('Future<String?> importArchive(');
      final body = src.substring(i);
      // 目标已存在 → 拒（不合并）
      expect(body.contains('工程「\$safeName」已存在'), isTrue,
          reason: '合并半新半旧的工程比拒绝更难查');
      // 至少 4 处 _rmrf 兜底（建暂存失败后、解压失败、校验失败、落位失败）
      expect(RegExp(r'await _rmrf\(').allMatches(body).length,
          greaterThanOrEqualTo(4));
    });

    test('落地校验不信任解压退出码（Zip Slip / -o 覆盖都能返回 0）', () {
      expect(src.contains('VERIFY_OK'), isTrue);
      expect(src.contains('test -f'), isTrue,
          reason: '必须真去 stat 那个 pubspec.yaml，而不是只看 exitCode');
    });

    test('清扫用 -exec rm -rf {} \\; 而非 +（避免 find 报错退出）', () {
      // Dart 单引号串里 `\\;` 才是发给 shell 的 `\;`（`\;` 会告警且只剩 `;`）
      expect(src.contains(r'-exec rm -rf {} \\;'), isTrue,
          reason: '必须双反斜杠——单反斜杠到了 shell 只剩分号，语义会变');
      expect(src.contains(r'-exec rm -rf {} +'), isFalse,
          reason: '+ 是批量传参，删父目录后子目录失效会让 find 报错');
      // 兜底：真机上 toybox/busybox 的 find -exec 行为不统一（不是所有版本
      // 都吃 `\;`），只走 find 一条路，删不掉时暂存目录会无限堆积。
      expect(src.contains(r"rm -rf ${quote('$kStagingRoot/$kStagingPrefix')}*"),
          isTrue,
          reason: '需要一条不依赖 find 的 glob 兜底');
      expect(src.contains(r'rmdir ${quote(kStagingRoot)}'), isTrue,
          reason: '目录真空时顺手删掉（rmdir 对非空目录会失败，安全）');
    });

    test('清扫只动带前缀的直接子项（不波及用户自己的文件）', () {
      expect(src.contains('-mindepth 1 -maxdepth 1'), isTrue);
      expect(src.contains(r'$kStagingPrefix*'), isTrue);
    });

    test('去 CRLF + 补可执行位（Windows 包 / zip 不存权限位）', () {
      // 源码里是 `sed -i "s/\\r\$//"`（Dart 单引号串中的 `\$` 是字面 `$`，
      // 即 shell 看到的 `$`）—— 断言它去掉了行尾 CR。
      expect(src.contains(r'sed -i "s/\\r\$//"'), isTrue,
          reason: 'CRLF 会让 pubspec 解析出带 \\r 的畸形包名');
      expect(src.contains(r'-exec chmod +x {} \\;'), isTrue,
          reason: 'zip 不保存 Unix 权限位，gradlew 会变不可执行；'
              '分号形式而非 + 号（避免 find 批量处理时报错退出）');
    });

    test('unzip 用 -o 而非 -n（-n 静默跳过 → "成功但内容不全"）', () {
      expect(src.contains('unzip -qo'), isTrue);
      expect(src.contains('unzip -qn'), isFalse);
    });

    test('unzip 用 -d，tar 用 -C（两个工具的落点参数不同名）', () {
      // 这是最容易写错的一处：`unzip -C` 在 unzip 里是"匹配忽略大小写"，
      // 不是"解压到目录"—— 写错不会报错，只会把文件铺到 CWD。
      final i = src.indexOf('final String destFlag;');
      expect(i, greaterThan(0), reason: 'destFlag 的声明与赋值应该在一起');
      final body = src.substring(i, i + 400);
      expect(body.contains("destFlag = '-d'"), isTrue,
          reason: 'unzip 的落点参数是 -d');
      expect(body.contains("destFlag = '-C'"), isTrue,
          reason: 'tar 的落点参数是 -C');
      // 反向：整个文件里不该出现 `unzip ... -C`（会被当成忽略大小写）
      expect(RegExp(r'unzip[^\n]*-C ').hasMatch(src), isFalse,
          reason: 'unzip -C 是"忽略大小写"，不是解压目录，写错会静默铺到 CWD');
    });

    test('.zip 路径先确保 unzip 存在（rootfs 只有 tar+gzip）', () {
      expect(src.contains('AptTools.ensure'), isTrue);
      expect(src.contains('DownloadException'), isTrue,
          reason: '装不上要给可执行的建议（换 .tar.gz），不能只抛堆栈');
    });

    test('tar 解压带 --no-same-owner（包里的 uid 在手机侧无意义）', () {
      expect(src.contains('--no-same-owner'), isTrue);
    });
  });
}
