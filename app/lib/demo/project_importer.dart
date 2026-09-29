import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import '../toolchain/sdk_downloader.dart' show DownloadException;
import '../toolchain/sdk_installer.dart' show AptTools;
import 'demo_project_creator.dart';

/// 压缩包内工程根的位置结论。
enum ImportLayout {
  /// 包根即工程根：一级条目里直接躺着 `pubspec.yaml`。
  direct,

  /// 只有一层顶层目录是工程根：`<subDir>/pubspec.yaml`。
  /// GitHub「Download ZIP」与自家导出（`tar -C 父目录 名`）都是这种。
  singleDir,

  /// 任何深度都找不到 `pubspec.yaml` —— 不是 Flutter 工程，拦在解压之前。
  none,
}

/// 探测结论。`topEntries` 只保留给错误提示用（别把 2 万个文件名全塞进去）。
class ImportProbe {
  final ImportLayout layout;

  /// [ImportLayout.singleDir] 时的工程根目录名（已剥掉结尾 `/`）。
  final String? subDir;

  /// 一级条目列表（已过滤 macOS 元数据）。
  final List<String> topEntries;

  const ImportProbe({
    required this.layout,
    this.subDir,
    this.topEntries = const [],
  });

  bool get usable => layout != ImportLayout.none;

  /// 工程根相对包根的路径：`''` / `'my_app'`。
  String get rootPrefix => switch (layout) {
        ImportLayout.direct => '',
        ImportLayout.singleDir => subDir ?? '',
        ImportLayout.none => '',
      };
}

/// 打包结果。[guestTar] 是容器内路径，可直接喂给 [FileBrowserBridge.export]。
class ProjectPackResult {
  final bool ok;
  final String? guestTar;
  final String? suggestName;
  final int bytes;
  final String? error;

  const ProjectPackResult({
    required this.ok,
    this.guestTar,
    this.suggestName,
    this.bytes = 0,
    this.error,
  });
}

/// 「导入 Flutter 源码工程」+「打包成 Flutter 源码工程」的全部业务逻辑。
///
/// ## 为什么零 Kotlin 改动
///
/// 需要的两个原生能力**早就存在**，且都不限定用途：
/// - `pickImportFile` 用 `ACTION_OPEN_DOCUMENT` + `type = "*/*"`，把用户选的
///   任意文件落在容器 `/root/imports/`（`fs_browser_bridge.dart:223`）；
/// - `exportFile` 走 `resolveRootfsPath()` 白名单（rootfs 根内皆合法），
///   所以 `/root/imports/xxx.tar.gz` **天然可导出**（`MainActivity.kt:2521`）。
///
/// 解压/打包本身用容器内的 `tar`/`unzip`（`ProotBridge.exec`），Dart 侧只负责
/// **编排 + 校验 + 落位**。
///
/// ## 为什么把暂存放 `/root/imports/.foa_extract/` 而不是 `/root/projects/`
///
/// 主页 `_loadProjects()` 就是 `browse('/root/projects').where(isDir)` ——
/// 放进去的半成品会**立刻以"工程"的样子出现在用户眼前**，解压到一半就点了
/// 构建，报的错还指不到这里。暂存放在 imports 下，中途失败对工程列表零影响。
///
/// ## 为什么探测阶段就拦 `layout == none`
///
/// 用户选错文件（截屏、APK、别人的压缩包）是高频操作。解压 500MB 才发现
/// 里面没有 `pubspec.yaml`，比在 2 秒内说"这不是 Flutter 工程"差得远。
class ProjectImporter {
  final ProotBridge _bridge;
  final FileBrowserBridge _fb;

  ProjectImporter({ProotBridge? bridge, FileBrowserBridge? fb})
      : _bridge = bridge ?? ProotBridge(),
        _fb = fb ?? FileBrowserBridge();

  // ---------------- 常量（const 化，供单测做契约断言）----------------

  /// 工程根。与主页 `_loadProjects()` 的扫描目录**必须一致**。
  static const String kProjectsRoot = '/root/projects';

  /// 导入源文件的落脚点（原生 `IMPORTS_GUEST`，`MainActivity.kt:54`）。
  static const String kImportsRoot = '/root/imports';

  /// 解压暂存区。**刻意在 imports 下而非 projects 下**，理由见类文档。
  static const String kStagingRoot = '$kImportsRoot/.foa_extract';

  /// 暂存目录名前缀。清理时只删带这个前缀的，绝不波及同名存档。
  static const String kStagingPrefix = '_foa_';

  /// 落位要检查的"这确实是 Flutter 工程"的证据文件。
  static const String kPubspec = 'pubspec.yaml';

  /// 打包排除清单。**这是正确性问题不是优化** —— 导出走 SAF 字节流，
  /// 打进包的每个字节都会 1:1 落到用户手机里。
  ///
  /// 两条设计约束：
  /// - **不能写 `*/build`**：那样会漏掉**工程根**的 `build/`，而它恰恰最大；
  /// - **不含 `lib` / `android` / `pubspec.yaml`**：排除过度会让包不可用
  ///   （单测里有反向断言守着这条）。
  static const List<String> kPackExcludes = [
    '.dart_tool',
    'build',
    '.git',
    '.gradle',
    '.idea',
    '.vscode',
    'android/.gradle',
    'android/build',
    'android/app/build',
    'ios/Pods',
    'macos/Pods',
    '.packages',
    '.flutter-plugins',
    '.flutter-plugins-dependencies',
    '*.iml',
    '.DS_Store',
    '__MACOSX',
  ];

  static const List<String> _archiveExts = [
    '.tar.gz', '.tar.xz', '.tgz', '.txz', '.zip', '.tar',
  ];

  /// 大小写不敏感的扩展名识别（手机上传来的文件常是 `.ZIP`）。
  static bool isArchive(String name) {
    final lower = name.toLowerCase();
    return _archiveExts.any(lower.endsWith);
  }

  // ---------------- 1. 名称推导（纯函数，可单测）----------------

  /// 把任意字符串归一化成能过 [DemoProjectCreator.validateName] 的工程名。
  ///
  /// 中文、空格、连字符一律折成下划线（`我的应用` → `p____` 之类），
  /// 数字开头补 `p`，超长截 30，保留字加 `_app` 后缀。
  ///
  /// **不保证好看，只保证合法** —— 用户在下拉对话框里看到预填值还能改。
  static String normalizeName(String raw) {
    var s = raw.trim().toLowerCase();
    // 只保留 [a-z0-9_]，其余（含中文、连字符、空格、`.`）全部折成 `_`
    s = s.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    // 连续下划线折叠成一个，否则 `my-app` 会变成 `my__app`
    s = s.replaceAll(RegExp(r'_{2,}'), '_');
    s = s.replaceAll(RegExp(r'^_+|_+$'), '');
    if (s.isEmpty) return '';
    if (!RegExp(r'^[a-z]').hasMatch(s)) s = 'p$s';
    if (s.length > 30) s = s.substring(0, 30);
    // 截断可能留下结尾下划线
    s = s.replaceAll(RegExp(r'_+$'), '');
    return s;
  }

  /// 猜一个工程名：优先包内 `pubspec.yaml` 的 `name:`，其次压缩包文件名。
  ///
  /// 返回**一定**能过 `validateName()`（除非两个来源都归一化成了空串，
  /// 此时兜底成 `imported_app` —— 宁可名字难看，也不返回一个用户点了
  /// 「导入」才报错的空值）。
  static String guessName({String? pubName, required String archiveName}) {
    final fromPub = normalizeName(pubName ?? '');
    if (DemoProjectCreator.validateName(fromPub) == null) return fromPub;

    var base = archiveName;
    final lower = base.toLowerCase();
    for (final ext in _archiveExts) {
      if (lower.endsWith(ext)) {
        base = base.substring(0, base.length - ext.length);
        break;
      }
    }
    var fromFile = normalizeName(base);
    if (DemoProjectCreator.validateName(fromFile) != null) {
      // 保留字（android/build/lib/root）或归一化后为空：加后缀绕开
      fromFile = fromFile.isEmpty ? 'imported' : fromFile;
      if (fromFile.length > 26) fromFile = fromFile.substring(0, 26);
      fromFile = '${fromFile}_app';
    }
    return DemoProjectCreator.validateName(fromFile) == null
        ? fromFile
        : 'imported_app';
  }

  /// 从包内 `pubspec.yaml` 文本里抠出 `name:`（不落盘）。
  ///
  /// 手写解析而非引 yaml 包：只要第一层的 `name:`，且必须容忍脏输入
  /// （BOM、CRLF、注释、缩进、引号）。取不到就返回 null，由调用方回退到文件名。
  static String? parsePubspecName(String pubspecText) {
    for (var line in pubspecText.split('\n')) {
      // 去 BOM / 行尾 CR / 首尾空白
      line = line.replaceAll('\uFEFF', '').trimRight();
      // 缩进行是 dependencies 里的子键，不是工程名
      if (line.isEmpty || line.startsWith(' ')) continue;
      if (line.startsWith('#')) continue;
      if (!line.startsWith('name:')) continue;
      var v = line.substring(5).trim();
      // 去掉行内注释（`name: foo # 备注`）
      final hash = v.indexOf(' #');
      if (hash >= 0) v = v.substring(0, hash).trim();
      v = v.replaceAll(RegExp(r'''^['"]|['"]$'''), '').trim();
      return v.isEmpty ? null : v;
    }
    return null;
  }

  // ---------------- 2. 探测（只列名，不解压）----------------

  /// 列出压缩包成员名。
  ///
  /// `.zip` 用 `unzip -Z1`（每行一个名字）；**不能用 `unzip -l`** ——
  /// 后者输出的是给人看的表格，要解析列宽、表头、分隔线，脆得没必要。
  /// `.tar.*` 用 `tar -tf`。
  static String listCommand(String guestArchive, String lowerName) {
    final q = quote(guestArchive);
    if (lowerName.endsWith('.zip')) return 'unzip -Z1 $q';
    if (lowerName.endsWith('.tar.gz') || lowerName.endsWith('.tgz')) {
      return 'tar -tzf $q';
    }
    if (lowerName.endsWith('.tar.xz') || lowerName.endsWith('.txz')) {
      return 'tar -tJf $q';
    }
    return 'tar -tf $q';
  }

  /// 读包内 `pubspec.yaml` 内容（stdout，不落盘）。
  static String readPubspecCommand(
      String guestArchive, String lowerName, String rootPrefix) {
    final member = rootPrefix.isEmpty ? kPubspec : '$rootPrefix/$kPubspec';
    final q = quote(guestArchive);
    final m = quote(member);
    if (lowerName.endsWith('.zip')) return 'unzip -p $q $m';
    if (lowerName.endsWith('.tar.gz') || lowerName.endsWith('.tgz')) {
      return 'tar -xzOf $q $m';
    }
    if (lowerName.endsWith('.tar.xz') || lowerName.endsWith('.txz')) {
      return 'tar -xJOf $q $m';
    }
    return 'tar -xOf $q $m';
  }

  /// 探测包结构。失败（损坏/加密/不支持）时返回 `layout == none` 且
  /// `topEntries` 为空 —— 调用方据此报"读不出内容"，与"不是 Flutter 工程"
  /// 在文案上区分开。
  Future<ImportProbe> probe(String guestArchive) async {
    final lower = guestArchive.toLowerCase();
    final list = await _bridge.exec(
      listCommand(guestArchive, lower),
      timeoutSec: 120,
    );
    if (!list.ok) {
      return const ImportProbe(layout: ImportLayout.none);
    }
    final names = list.stdout
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        // macOS Finder 压缩会塞 `__MACOSX/` 与 `._xxx` 影子文件，全是垃圾
        .where((e) => !e.startsWith('__MACOSX/') && !e.contains('/__MACOSX/'))
        .where((e) {
          final base = e.split('/').last;
          return !base.startsWith('._');
        })
        .toList();
    if (names.isEmpty) return const ImportProbe(layout: ImportLayout.none);

    final tops = <String>[];
    for (final n in names) {
      final clean = n.startsWith('./') ? n.substring(2) : n;
      if (clean.isEmpty) continue;
      final head = clean.split('/').first;
      if (head.isEmpty || tops.contains(head)) continue;
      tops.add(head);
    }

    // (a) 包根即工程根
    if (names.any((n) {
      final c = n.startsWith('./') ? n.substring(2) : n;
      return c == kPubspec;
    })) {
      return ImportProbe(
        layout: ImportLayout.direct,
        topEntries: tops.take(20).toList(),
      );
    }

    // (b) 恰好一层顶层目录
    final topDirs = <String>[];
    for (final n in names) {
      final c = n.startsWith('./') ? n.substring(2) : n;
      final parts = c.split('/');
      if (parts.length < 2) continue;
      if (parts.sublist(1).join('/') == kPubspec && !topDirs.contains(parts[0])) {
        topDirs.add(parts[0]);
      }
    }
    if (topDirs.length == 1) {
      return ImportProbe(
        layout: ImportLayout.singleDir,
        subDir: topDirs.first,
        topEntries: tops.take(20).toList(),
      );
    }

    // (c) 不是 Flutter 工程（或嵌套过深 —— 一律拒，不猜）
    return ImportProbe(layout: ImportLayout.none, topEntries: tops.take(20).toList());
  }

  /// 读包内 pubspec 的 `name:`（探测到布局后调用；失败返回 null）。
  Future<String?> peekPubspecName(String guestArchive, ImportProbe p) async {
    if (!p.usable) return null;
    final r = await _bridge.exec(
      readPubspecCommand(guestArchive, guestArchive.toLowerCase(), p.rootPrefix),
      timeoutSec: 60,
    );
    if (!r.ok) return null;
    return parsePubspecName(r.stdout);
  }

  // ---------------- 3. 清理陈旧暂存 ----------------

  /// 幂等清扫上次导入的残留。
  ///
  /// 为什么必须有：exec 超时/被系统杀掉时，Dart 侧的 `finally` 不一定跑得到
  /// （进程没了就没有 finally）。所以清理不能只依赖"我这轮记得删"，必须
  /// **下一轮开场先扫一遍**。
  ///
  /// `-maxdepth 1` + 前缀过滤：只删 `_foa_*` 的直接子项，绝不动
  /// `/root/imports/` 下用户自己放的其他文件。
  ///
  /// 尾巴上补了两条**不依赖 `find` 的兜底**（`rm -rf` glob + 父目录 `rmdir`）：
  /// 移动端 toybox/busybox 的 `find` 实现的 `-exec` 行为不完全统一（不是所有
  /// 版本都吃 `\;`），真机上"删不掉"的后果是暂存目录无限堆积。
  /// 三条路只要通一条，清理就成立；最后 `rmdir` 只在目录真空时成功，
  /// 安全。
  Future<void> sweepStale() async {
    await _bridge.exec(
      'mkdir -p ${quote(kStagingRoot)} && '
      'find ${quote(kStagingRoot)} -mindepth 1 -maxdepth 1 '
      '-name ${quote('$kStagingPrefix*')} -exec rm -rf {} \\; 2>/dev/null; '
      'rm -rf ${quote('$kStagingRoot/$kStagingPrefix')}* 2>/dev/null; '
      'rmdir ${quote(kStagingRoot)} 2>/dev/null; '
      'echo SWEPT',
      timeoutSec: 120,
    );
  }

  // ---------------- 4. 导入 ----------------

  /// 解压归档并落到 `/root/projects/<name>`。
  ///
  /// 成功返回 `null`，失败返回**可直接展示给用户**的错误文案。
  ///
  /// 步骤与每一步的理由：
  /// 1. 目标已存在 → 拒（不合并。半新半旧的工程比没有工程更难查）
  /// 2. 清残留 + 建暂存（`/root/imports/.foa_extract/<name>`）
  /// 3. 解压（`.zip` → `unzip -qo ... -d`；`tar` → `tar --no-same-owner -xzf ... -C`）
  /// 4. **落地校验**：`test -f <root>/pubspec.yaml` —— **不信任解压退出码**，
  ///    Zip Slip、`-o` 覆盖、空目录都能让解压返回 0 而结果不是我们要的
  /// 5. `sed -i 's/\r$//'` 去 CRLF（Windows 上打的包，`name: foo\r` 会让
  ///    pubspec 解析出畸形包名）
  /// 6. `.zip` 补 `chmod +x`（zip 不存 Unix 权限位，`gradlew` 会变不可执行）
  /// 7. `mv` 落位（跨设备回退 `cp -a`），校验后删暂存
  ///
  /// 任一步失败：暂存与目标**都**清掉，绝不留下半个工程。
  Future<String?> importArchive({
    required String guestArchive,
    required String name,
    required ImportProbe probeResult,
  }) async {
    if (!probeResult.usable) return '这个压缩包里没有找到 pubspec.yaml，不是 Flutter 源码工程';

    final nameErr = DemoProjectCreator.validateName(name);
    if (nameErr != null) return nameErr;

    final safeName = name.trim();
    final lower = guestArchive.toLowerCase();
    final staging = '$kStagingRoot/$kStagingPrefix$safeName';
    final dst = '$kProjectsRoot/$safeName';
    final rootPrefix = probeResult.rootPrefix;

    // 0) 清残留（本轮也清一次：超时残留的暂存名可能和这次同名）
    await sweepStale();

    // 1) 目标必须不存在。不合并 —— 见方法文档
    final exists = await _bridge.exec(
      'test -e ${quote(dst)} && echo DST_EXISTS || echo DST_FREE',
      timeoutSec: 60,
    );
    if (exists.stdout.contains('DST_EXISTS')) {
      return '工程「$safeName」已存在，请换个名字（或先在列表里删掉它）';
    }

    // 2) 建暂存
    final mk = await _bridge.exec(
      'mkdir -p ${quote(staging)} && echo STAGE_OK',
      timeoutSec: 60,
    );
    if (!mk.stdout.contains('STAGE_OK')) {
      return '创建暂存目录失败：${_tail(mk.stderr.isNotEmpty ? mk.stderr : mk.stdout)}';
    }

    final isZip = lower.endsWith('.zip');
    // .zip 需要 unzip：Debian minbase rootfs 只有 tar+gzip，没有 unzip/xz。
    // AptTools.ensure 幂等（已装秒过），失败抛 DownloadException。
    if (isZip) {
      try {
        await AptTools.ensure(_bridge);
      } on DownloadException catch (e) {
        await _rmrf(staging);
        return '这个 .zip 需要容器内安装 unzip，安装失败：${e.message}\n'
            '（可在终端执行 dpkg --configure -a 后重试，'
            '或改用 .tar.gz 格式的源码包）';
      }
    }

    // 3) 解压
    final String tool;
    final String destFlag;
    if (isZip) {
      tool = 'unzip -qo'; // -o 必须：遇同名文件不交互；-n 会静默跳过 → "成功但内容不全"
      destFlag = '-d'; // unzip 用 -d，不是 -C
    } else if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      tool = 'tar --no-same-owner -xzf'; // --no-same-owner：tar 包里带的 uid 无权在手机侧映射
      destFlag = '-C';
    } else if (lower.endsWith('.tar.xz') || lower.endsWith('.txz')) {
      tool = 'tar --no-same-owner -xJf';
      destFlag = '-C';
    } else {
      tool = 'tar --no-same-owner -xf';
      destFlag = '-C';
    }
    final extract = await _bridge.exec(
      '$tool ${quote(guestArchive)} $destFlag ${quote(staging)} && echo EXTRACT_OK',
      timeoutSec: 900,
    );
    if (!extract.stdout.contains('EXTRACT_OK')) {
      await _rmrf(staging);
      final out = extract.stderr.isNotEmpty ? extract.stderr : extract.stdout;
      return '解压失败：${_tail(out)}';
    }

    // 4) 落地校验 —— 不信任解压退出码
    final rootPath = rootPrefix.isEmpty ? staging : '$staging/$rootPrefix';
    final verify = await _bridge.exec(
      'test -f ${quote('$rootPath/$kPubspec')} && echo VERIFY_OK || echo VERIFY_MISS',
      timeoutSec: 60,
    );
    if (!verify.stdout.contains('VERIFY_OK')) {
      await _rmrf(staging);
      return '解压完成但没找到工程根（${rootPrefix.isEmpty ? '包根' : rootPrefix} 下无 $kPubspec）';
    }

    // 5) 去 CRLF + 6) 补可执行位（zip 不存 Unix 权限）
    final fix = isZip
        ? 'sed -i "s/\\r\$//" ${quote('$rootPath/$kPubspec')} 2>/dev/null; '
            'find ${quote(rootPath)} -name "*.sh" -exec chmod +x {} \\; 2>/dev/null; '
            'echo FIXED'
        : 'sed -i "s/\\r\$//" ${quote('$rootPath/$kPubspec')} 2>/dev/null; echo FIXED';
    await _bridge.exec(fix, timeoutSec: 300);

    // 7) 落位。mv 同设备是 rename（瞬间）；跨设备（暂存在 imports、目标在
    // projects，都是 rootfs 内同一挂载，正常同设备）失败时回退 cp -a。
    final move = await _bridge.exec(
      'mkdir -p ${quote(kProjectsRoot)} && '
      'if mv ${quote(rootPath)} ${quote(dst)} 2>/dev/null; then echo MOVED; '
      'elif cp -a ${quote(rootPath)} ${quote(dst)} 2>/dev/null; then echo COPIED; '
      'else echo MOVE_FAIL; fi',
      timeoutSec: 300,
    );
    await _rmrf(staging);
    if (!move.stdout.contains('MOVED') && !move.stdout.contains('COPIED')) {
      await _rmrf(dst);
      return '落位到 $dst 失败：${_tail(move.stderr.isNotEmpty ? move.stderr : move.stdout)}';
    }

    // 8) 终检：落位后工程根必须真的可读
    final finalCheck = await _bridge.exec(
      'test -f ${quote('$dst/$kPubspec')} && echo FINAL_OK || echo FINAL_MISS',
      timeoutSec: 60,
    );
    if (!finalCheck.stdout.contains('FINAL_OK')) {
      await _rmrf(dst);
      return '工程落位后校验失败（$dst/$kPubspec 不存在），已回滚';
    }
    return null;
  }

  // ---------------- 5. 打包 ----------------

  /// 生成打包命令。
  ///
  /// 三个必须遵守的细节（`tar` 的坑，写错了包会静默变大）：
  /// - `--exclude` 必须在 `-C` **之前** —— `tar` 按出现顺序处理，
  ///   放在后面会被当成文件名；
  /// - 用相对模式 `build` 而**不能写 `*/build`** —— 后者漏掉工程根的
  ///   `build/`，而它恰恰是体积大头；
  /// - `-C <父目录> <相对名>` 保证成员是 `my_app/...` 而非绝对路径 ——
  ///   **自家导出的包天然是 [ImportLayout.singleDir]，能被自家导入直接吃**。
  static String packCommand({
    required String name,
    required String guestTar,
    List<String> excludes = kPackExcludes,
  }) {
    final b = StringBuffer('tar ');
    for (final e in excludes) {
      b.write('--exclude=${quote(e)} ');
    }
    b.write('-czf ${quote(guestTar)} -C ${quote(kProjectsRoot)} ${quote(name)}');
    return b.toString();
  }

  /// 把工程打成 `/root/imports/<name>-<yyyyMMdd-HHmm>.tar.gz`。
  ///
  /// 落点选 `/root/imports`（而非 projects）：它在 `resolveRootfsPath()`
  /// 白名单内，**导出时零原生改动**；同时不在主页工程扫描范围，不会
  /// 让用户看到一个"工程"其实是压缩包。
  Future<ProjectPackResult> packProject({
    required String name,
    DateTime? now,
    int timeoutSec = 1800,
  }) async {
    final safeName = name.trim();
    if (DemoProjectCreator.validateName(safeName) != null) {
      return ProjectPackResult(ok: false, error: '工程名不合法：$name');
    }
    // 工程根必须真在（否则 tar 报的错是 "Cannot stat"，用户看不懂）
    final exists = await _bridge.exec(
      'test -f ${quote('$kProjectsRoot/$safeName/$kPubspec')} '
      '&& echo SRC_OK || echo SRC_MISS',
      timeoutSec: 60,
    );
    if (!exists.stdout.contains('SRC_OK')) {
      return ProjectPackResult(
        ok: false,
        error: '工程「$safeName」不完整（缺 $kPubspec），无法打包',
      );    }

    final t = now ?? DateTime.now();
    final stamp = '${t.year.toString().padLeft(4, '0')}'
        '${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}-'
        '${t.hour.toString().padLeft(2, '0')}'
        '${t.minute.toString().padLeft(2, '0')}';
    final fileName = '$safeName-$stamp.tar.gz';
    final guestTar = '$kImportsRoot/$fileName';

    final r = await _bridge.exec(
      'mkdir -p ${quote(kImportsRoot)} && '
      'rm -f ${quote(guestTar)} && '
      '${packCommand(name: safeName, guestTar: guestTar)} && echo PACK_OK',
      timeoutSec: timeoutSec,
    );
    if (!r.stdout.contains('PACK_OK')) {
      await _rmrf(guestTar);
      final out = r.stderr.isNotEmpty ? r.stderr : r.stdout;
      return ProjectPackResult(ok: false, error: '打包失败：${_tail(out)}');
    }

    // 取真实字节数（导出对话框里的建议名不带大小，但 UI 上要显示给用户）
    final sz = await _bridge.exec(
      'wc -c < ${quote(guestTar)}',
      timeoutSec: 60,
    );
    final bytes = int.tryParse(sz.stdout.trim().split('\n').first.trim()) ?? 0;
    if (bytes <= 0) {
      await _rmrf(guestTar);
      return const ProjectPackResult(ok: false, error: '打包产物为空，已清理');
    }
    return ProjectPackResult(
      ok: true,
      guestTar: guestTar,
      suggestName: fileName,
      bytes: bytes,
    );
  }

  /// 打包 + 拉起系统保存对话框，**无论成功/取消都删掉临时 tar**。  ///
  /// 为什么成功也要删：那个 tar 躺在 `/root/imports/` 里，用户打开文件
  /// 浏览器会看到一堆 `xxx-20260921-1430.tar.gz`，而它们的唯一用途
  /// 就是把字节流交给 SAF —— 交完就是垃圾。
  ///
  /// 返回错误文案（`null` = 成功）。用户取消不算失败，返回 `null`。
  Future<String?> packAndExport(String name) async {
    final pack = await packProject(name: name);
    if (!pack.ok) return pack.error;
    try {
      final r = await _fb.export(pack.guestTar!, pack.suggestName!);
      if (!r.ok) {
        final e = r.error ?? '导出失败';
        // 取消是用户意图，不是错误
        return e.contains('已取消') ? null : e;
      }
      return null;
    } finally {
      await _rmrf(pack.guestTar!);
    }
  }

  // ---------------- 6. 选文件 / 删除 ----------------

  /// 选一个源码压缩包到容器（返回原生给的结果，`path` 是**容器路径**）。
  ///
  /// 注意原生的名字清洗：`displayName.replace(Regex("[^A-Za-z0-9._-]"), "_")`
  /// （`MainActivity.kt:550`）—— **中文文件名会被逐字折成下划线**。
  /// 所以工程名不能从这里取，要走 [guessName]（pubspec 优先）。
  Future<ImportedFile> pickArchive() => _fb.pickImport();

  /// 删掉容器内一个文件/目录（导入成功后清理源压缩包用）。
  Future<void> removeFile(String guestPath) => _rmrf(guestPath);

  // ---------------- 工具 ----------------

  /// shell **单引号**转义。
  ///
  /// 刻意不复用 `file_browser_page.dart:551` 的双引号版：那个不处理 `$`
  /// 和反引号，对用户上传的任意文件名不安全（`a$(rm -rf ~).zip` 会执行）。
  /// 单引号里除了 `'` 本身没有任何特殊字符，把 `'` 换成 `'\''` 即任意字节安全。
  static String quote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  Future<void> _rmrf(String guestPath) async {
    await _bridge.exec(
      'rm -rf ${quote(guestPath)} 2>/dev/null; echo DONE',
      timeoutSec: 120,
    );
  }

  static String _tail(String s) {
    final t = s.trim();
    return t.length <= 400 ? t : '…${t.substring(t.length - 400)}';
  }
}
