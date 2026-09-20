// termux_backend.dart 的纯逻辑单测（2026-09-18，native-bare 后端）。
//
// 覆盖：Packages 索引解析 / 版本比较 / 最新版挑选 / 后端偏好持久化
// round-trip / Termux 路径拼接 / deb 直链构造。
// 不联网、不走 MethodChannel，全部可在 CI 秒级跑完。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/env/models.dart';
import 'package:foaide/toolchain/termux_backend.dart';

void main() {
  // ---------------- parsePackagesIndex ----------------
  group('parsePackagesIndex', () {
    const index = '''
Package: openjdk-17
Version: 17.0.20
Depends: libandroid-spawn
Filename: pool/main/o/openjdk-17/openjdk-17_17.0.20_aarch64.deb
SHA256: aaa111
Size: 123456

Package: aapt
Version: 14.0.0-1
Filename: pool/main/a/aapt/aapt_14.0.0-1_aarch64.deb
SHA256: bbb222
Size: 999
''';

    test('解析目标包的全部字段', () {
      final r = parsePackagesIndex(index, 'openjdk-17');
      expect(r, hasLength(1));
      expect(r.first.package, 'openjdk-17');
      expect(r.first.version, '17.0.20');
      expect(r.first.filename,
          'pool/main/o/openjdk-17/openjdk-17_17.0.20_aarch64.deb');
      expect(r.first.sha256, 'aaa111');
      expect(r.first.size, 123456);
    });

    test('只返回指定包（多包索引）', () {
      final r = parsePackagesIndex(index, 'aapt');
      expect(r, hasLength(1));
      expect(r.first.package, 'aapt');
      expect(r.first.fileName(), 'aapt_14.0.0-1_aarch64.deb');
    });

    test('末段无空行结尾也能收段', () {
      final r = parsePackagesIndex(
          'Package: git\nVersion: 2.42.0\nFilename: pool/g/git.deb', 'git');
      expect(r, hasLength(1));
      expect(r.first.version, '2.42.0');
      expect(r.first.filename, 'pool/g/git.deb');
    });

    test('目标包不存在 → 空列表', () {
      expect(parsePackagesIndex(index, 'dart'), isEmpty);
      expect(parsePackagesIndex('', 'openjdk-17'), isEmpty);
    });

    test('同名包多版本全部返回（供 newest 挑选）', () {
      final r = parsePackagesIndex(
          'Package: openjdk-17\nVersion: 17.0.10\nFilename: a.deb\n\n'
          'Package: openjdk-17\nVersion: 17.0.20\nFilename: b.deb\n',
          'openjdk-17');
      expect(r, hasLength(2));
      expect(r.map((s) => s.filename), containsAll(['a.deb', 'b.deb']));
    });

    test('忽略不含 ": " 的杂行', () {
      // 杂行只可能出现在段落之间（apt 索引续行以空格开头，不会截断段内字段）
      final r = parsePackagesIndex(
          '# comment\nPackage: git\nVersion: 1.0\nFilename: x.deb\n\n'
          'odd line without colon\n\nPackage: dart\nFilename: d.deb\n',
          'git');
      expect(r, hasLength(1));
      expect(r.first.version, '1.0');
      expect(r.first.filename, 'x.deb');
    });
  });

  // ---------------- compareVersions ----------------
  group('compareVersions', () {
    test('数字段按数值比较（9 < 10）', () {
      expect(compareVersions('17.0.9', '17.0.10'), isNegative);
      expect(compareVersions('2.42.0', '2.4.0'), isPositive);
    });

    test('相等返回 0', () {
      expect(compareVersions('17.0.20', '17.0.20'), 0);
    });

    test('缺段补 0（1.0 == 1.0.0）', () {
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('14', '14.0'), 0);
    });

    test('字母段按字典序', () {
      expect(compareVersions('1.0a', '1.0b'), isNegative);
      expect(compareVersions('1.0beta', '1.0alpha'), isPositive);
    });

    test('数字段优先于字母段（实现语义的文档化）', () {
      // 缺段一侧补 '0'（数字），与字母段比较时数字胜出
      expect(compareVersions('1.0', '1.0a'), isPositive);
    });

    test('修订号 -1 后缀参与比较', () {
      expect(compareVersions('14.0.0-1', '14.0.0'), isPositive);
      expect(compareVersions('14.0.0-1', '14.0.0-2'), isNegative);
    });
  });

  // ---------------- newest ----------------
  group('newest', () {
    test('多版本挑选最新', () {
      final specs = [
        const TermuxPackageSpec(
            package: 'p',
            version: '17.0.10',
            filename: 'a.deb',
            sha256: 'h1',
            size: 1),
        const TermuxPackageSpec(
            package: 'p',
            version: '17.0.20',
            filename: 'b.deb',
            sha256: 'h2',
            size: 2),
        const TermuxPackageSpec(
            package: 'p',
            version: '17.0.3',
            filename: 'c.deb',
            sha256: 'h3',
            size: 3),
      ];
      expect(newest(specs).filename, 'b.deb');
    });

    test('单元素原样返回', () {
      final specs = [
        const TermuxPackageSpec(
            package: 'p', version: '1.0', filename: 'x.deb', sha256: 'h', size: 1),
      ];
      expect(newest(specs).filename, 'x.deb');
    });
  });

  // ---------------- BackendPrefs ----------------
  group('BackendPrefs', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('foa_backend_prefs_test');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('文件不存在 → load 返回 null（未选择）', () async {
      final e = _withFilesDir(tmp.path);
      expect(await BackendPrefs.load(e), isNull);
    });

    test('save(proot) → load 往返', () async {
      final e = _withFilesDir(tmp.path);
      await BackendPrefs.save(e, BuildBackend.proot);
      expect(await BackendPrefs.load(e), BuildBackend.proot);
    });

    test('save(termux) → load 往返（覆盖写）', () async {
      final e = _withFilesDir(tmp.path);
      await BackendPrefs.save(e, BuildBackend.proot);
      await BackendPrefs.save(e, BuildBackend.termux);
      expect(await BackendPrefs.load(e), BuildBackend.termux);
    });

    test('损坏内容 → load 返回 null 而不抛', () async {
      final e = _withFilesDir(tmp.path);
      File('${tmp.path}/${BackendPrefs.fileName}')
          .writeAsStringSync('not json{{{');
      expect(await BackendPrefs.load(e), isNull);
      File('${tmp.path}/${BackendPrefs.fileName}')
          .writeAsStringSync('{"backend":"unknown"}');
      expect(await BackendPrefs.load(e), isNull);
    });
  });

  // ---------------- TermuxPaths ----------------
  group('TermuxPaths', () {
    const env = EnvInfo(
      filesDir: '/data/user/0/dev.foa/files',
      cacheDir: '/data/user/0/dev.foa/cache',
      nativeLibraryDir: '/data/user/0/dev.foa/lib',
      rootfsPath: '/data/user/0/dev.foa/files/rootfs',
      rootfsInstalled: true,
    );

    test('容器 prefix 固定、宿主 prefix = rootfsPath + 容器 prefix', () {
      expect(TermuxPaths.containerPrefix(env), '/opt/foa-termux/usr');
      expect(TermuxPaths.prefix(env),
          '/data/user/0/dev.foa/files/rootfs/opt/foa-termux/usr');
    });

    test('组件路径都落在 prefix 内', () {
      final p = TermuxPaths.prefix(env);
      expect(TermuxPaths.jdkHome(env), '$p/lib/jvm/java-17-openjdk');
      expect(TermuxPaths.flutterHome(env), '$p/opt/flutter');
      expect(TermuxPaths.aapt2(env), '$p/bin/aapt2');
    });

    test('下载/暂存目录在 rootfs 树内（容器可见）', () {
      expect(TermuxPaths.containerDlDir(), '/opt/foa-termux-dl');
      expect(TermuxPaths.containerStageDir(), '/opt/foa-termux-stage');
      expect(TermuxPaths.dlDir(env),
          '/data/user/0/dev.foa/files/rootfs/opt/foa-termux-dl');
    });

    test('bareEnv 始终含镜像变量；prefix 不存在时不含组件变量', () {
      final e = TermuxPaths.bareEnv(env);
      expect(e['PUB_HOSTED_URL'], 'https://pub.flutter-io.cn');
      expect(e['FLUTTER_STORAGE_BASE_URL'], 'https://storage.flutter-io.cn');
      expect(e.containsKey('PREFIX'), isFalse); // 测试环境 prefix 必不存在
      expect(e.containsKey('JAVA_HOME'), isFalse);
      expect(e.containsKey('GRADLE_USER_HOME'), isFalse);
    });

    test('envPrefix 渲染成 export 前缀且含镜像', () {
      final s = TermuxPaths.envPrefix(env);
      expect(s, contains("export PUB_HOSTED_URL='https://pub.flutter-io.cn'; "));
      expect(s,
          contains("export FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'; "));
    });
  });

  // ---------------- TermuxRepo ----------------
  group('TermuxRepo', () {
    test('索引路径拼接', () {
      expect(TermuxRepo.indexPathGz('https://example.com/apt/termux-main'),
          'https://example.com/apt/termux-main/dists/stable/main/binary-aarch64/Packages.gz');
    });

    test('deb 直链 = 每个镜像 + filename', () {
      const spec = TermuxPackageSpec(
        package: 'openjdk-17',
        version: '17.0.20',
        filename: 'pool/main/o/openjdk-17/openjdk-17_17.0.20_aarch64.deb',
        sha256: 'h',
        size: 1,
      );
      final mirrors = TermuxRepo.debMirrors(spec);
      expect(mirrors, hasLength(TermuxRepo.repoMirrors().length));
      for (final m in mirrors) {
        expect(m.url, endsWith('/${spec.filename}'));
      }
      // 至少含官方仓与一个国内镜像
      expect(mirrors.any((m) => m.url.contains('packages.termux.dev')), isTrue);
      expect(mirrors.any((m) => m.url.contains('tuna.tsinghua')), isTrue);
    });

    test('组件包名常量', () {
      expect(TermuxRepo.jdkPackage, 'openjdk-17');
      expect(TermuxRepo.buildToolsPackage, 'aapt');
    });
  });
}

/// filesDir 指向临时目录的 EnvInfo（BackendPrefs 持久化落点）。
EnvInfo _withFilesDir(String dir) => EnvInfo(
      filesDir: dir,
      cacheDir: '$dir/cache',
      nativeLibraryDir: '$dir/lib',
      rootfsPath: '$dir/rootfs',
      rootfsInstalled: true,
    );
