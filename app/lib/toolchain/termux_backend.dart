/// Termux 裸原生后端（native-bare）：**不经过 proot**，把 Termux 主仓的
/// bionic 二进制装进 App 私有目录，直接在真机内核上执行。
///
/// 背景（2026-09-18，供应链核实见 dev-handbook/07 §八）：
/// - Termux 主仓有全套现货：openjdk-17/21（bionic 交叉构建）、aapt 包
///   （aidl/aapt/aapt2/zipalign 四件套）、dart、gradle、d8、git……
/// - 构建期只需三样非 JVM 原生件：JDK、aapt2 四件套、Flutter（bionic dart
///   + 配套 gen_snapshot）。Gradle/d8/R8/kotlinc 都是纯 JVM，随 JDK 走；
/// - Android SDK 的 jars / android.jar / 许可**架构无关**，裸模式直接复用
///   容器 SDK 目录（GRADLE_USER_HOME 也复用容器缓存，Maven 依赖零重下）；
/// - W^X 约束不受影响：targetSdk 28 保留 filesDir 子树的 execve 权利，
///   proot 本来就是从 filesDir exec 的，bionic 二进制同理。
///
/// ⚠️ 与 proot 后端的关系：并行后端，可切换、互不污染（工具页顶部切换）。
///
/// 布局（落在 rootfs 目录树内，**容器与宿主看同一目录**）：
/// ```
/// <rootfs>/opt/foa-termux/usr/      ← PREFIX（bionic 二进制树）
/// <rootfs>/opt/foa-termux-dl/       ← deb 下载缓存（容器 dpkg-deb 可直接读）
/// ```
/// 落在 rootfs 内的原因：安装期要用容器里的 `dpkg-deb` 解包 deb（宿主侧
/// 没有 ar/xz），容器路径与宿主路径是**同一物理目录**，解包结果零搬运；
/// 宿主侧照样可以 exec（filesDir 子树 W^X 安全区）。将来引入内置
/// busybox 解包器后，把 [TermuxPaths] 换成 filesDir/termux/… 即可彻底
/// 解耦 rootfs（封装点只有这一处）。
library;

import 'dart:convert';
import 'dart:io';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'sdk_downloader.dart';

// ---------------- 后端枚举与偏好持久化 ----------------

/// 构建后端：proot 容器（稳定）/ termux 裸原生（实验性）。
enum BuildBackend { proot, termux }

/// 容器层实现（alpha.61）：proot（ptrace，稳定）或 proroot（LD_PRELOAD，快）。
///
/// **与 [BuildBackend] 是两个正交维度**：
/// - BuildBackend 决定"在不在容器里"（proot/termux 二选一，termux 不进容器）；
/// - ContainerLayer 决定"进容器时用哪套路径翻译"。
/// 所以 termux 后端下 ContainerLayer 无意义（当前 UI 会把开关置灰）。
enum ContainerLayer { proot, proroot }

/// 容器层偏好的持久化（filesDir/foa-container.json）。
///
/// 默认 **proot**：proroot 是专有软件、要求 Ubuntu rootfs（本项目是
/// Debian，属未验证组合），不该被默认打开。
class ContainerPrefs {
  static const String fileName = 'foa-container.json';

  static File _file(EnvInfo env) => File('${env.filesDir}/$fileName');

  static Future<ContainerLayer> load(EnvInfo env) async {
    try {
      final f = _file(env);
      if (!await f.exists()) return ContainerLayer.proot;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return ContainerLayer.proot;
      return switch (raw['layer']) {
        'proroot' => ContainerLayer.proroot,
        _ => ContainerLayer.proot,
      };
    } catch (_) {
      return ContainerLayer.proot;
    }
  }

  static Future<void> save(EnvInfo env, ContainerLayer layer) async {
    final f = _file(env);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'layer': layer.name}));
  }
}

/// 后端切换的持久化（filesDir/foa-backend.json）。
///
/// null = 用户还没选过（首次进工具链页会弹询问并给推荐）。
class BackendPrefs {
  static const String fileName = 'foa-backend.json';

  static File _file(EnvInfo env) => File('${env.filesDir}/$fileName');

  /// 读取后端偏好；文件不存在 / 内容不合法 → null（视为未选择）。
  static Future<BuildBackend?> load(EnvInfo env) async {
    try {
      final f = _file(env);
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      return switch (raw['backend']) {
        'proot' => BuildBackend.proot,
        'termux' => BuildBackend.termux,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(EnvInfo env, BuildBackend b) async {
    final f = _file(env);
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'backend': b.name}));
  }
}

// ---------------- 路径布局 ----------------

/// Termux 后端的路径集中封装（将来解耦 rootfs 只改这里）。
class TermuxPaths {
  /// 容器内可见的 prefix（dpkg-deb 解包与 shebang 改写都在容器里做）。
  static String containerPrefix(EnvInfo env) => '/opt/foa-termux/usr';

  /// 宿主侧真实 prefix（bare 执行的 LD_LIBRARY_PATH / shebang 指向它）。
  static String prefix(EnvInfo env) =>
      '${env.rootfsPath}${containerPrefix(env)}';

  /// 下载缓存（在 rootfs 树内，容器 dpkg-deb 直接可读）。
  static String containerDlDir() => '/opt/foa-termux-dl';

  static String dlDir(EnvInfo env) => '${env.rootfsPath}${containerDlDir()}';

  static String containerStageDir() => '/opt/foa-termux-stage';

  static String jdkHome(EnvInfo env) => '${prefix(env)}/lib/jvm/java-17-openjdk';

  static String flutterHome(EnvInfo env) => '${prefix(env)}/opt/flutter';

  static String aapt2(EnvInfo env) => '${prefix(env)}/bin/aapt2';

  static bool prefixExists(EnvInfo env) => Directory(prefix(env)).existsSync();

  /// bare 执行的公共环境（与 Kotlin 侧注入保持一致；命令内可覆盖）。
  static Map<String, String> bareEnv(EnvInfo env) {
    final e = <String, String>{
      'TERM': 'dumb',
      'PUB_HOSTED_URL': 'https://pub.flutter-io.cn',
      'FLUTTER_STORAGE_BASE_URL': 'https://storage.flutter-io.cn',
    };
    if (prefixExists(env)) {
      e['PREFIX'] = prefix(env);
      e['LD_LIBRARY_PATH'] = '${prefix(env)}/lib';
      final jdk = jdkHome(env);
      if (Directory(jdk).existsSync()) e['JAVA_HOME'] = jdk;
      final sdk = '${env.rootfsPath}/opt/android-sdk';
      if (Directory(sdk).existsSync()) e['ANDROID_HOME'] = sdk;
      // 与容器共用 Gradle 缓存（仓库 URL 一致 → Maven 依赖/发行包零重下）
      e['GRADLE_USER_HOME'] = '${env.rootfsPath}/root/.gradle';
    }
    return e;
  }

  /// 把环境渲染成 `export K='V'; ` 前缀（verify 用；构建走 Kotlin 注入）。
  static String envPrefix(EnvInfo env) => bareEnv(env).entries
      .map((e) => "export ${e.key}='${e.value.replaceAll("'", "'\\''")}'; ")
      .join();
}

// ---------------- Termux 仓库索引 ----------------

/// 一个 deb 包的解析结果（来自 Packages 索引，均为 aarch64 条目）。
class TermuxPackageSpec {
  final String package;
  final String version;
  final String filename; // 仓库相对路径（pool/...）
  final String sha256;
  final int size;
  const TermuxPackageSpec({
    required this.package,
    required this.version,
    required this.filename,
    required this.sha256,
    required this.size,
  });

  String fileName() => filename.split('/').last;
}

/// 解析 apt Packages 索引文本，取出某包的全部条目（纯函数，可测）。
///
/// 索引格式：空行分隔的段落，`Key: Value` 行。只关心
/// Package / Version / Filename / SHA256 / Size 五个键。
List<TermuxPackageSpec> parsePackagesIndex(String text, String pkg) {
  final specs = <TermuxPackageSpec>[];
  String package = '', version = '', filename = '', sha256 = '';
  var size = 0;
  void flush() {
    if (package == pkg && filename.isNotEmpty) {
      specs.add(TermuxPackageSpec(
        package: package,
        version: version,
        filename: filename,
        sha256: sha256,
        size: size,
      ));
    }
    package = version = filename = sha256 = '';
    size = 0;
  }

  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty) {
      flush();
      continue;
    }
    final i = line.indexOf(': ');
    if (i <= 0) continue;
    final key = line.substring(0, i);
    final value = line.substring(i + 2).trim();
    switch (key) {
      case 'Package':
        package = value;
      case 'Version':
        version = value;
      case 'Filename':
        filename = value;
      case 'SHA256':
        sha256 = value;
      case 'Size':
        size = int.tryParse(value) ?? 0;
    }
  }
  flush();
  return specs;
}

/// 版本比较（apt 风格的简化版）：按字母/数字段切分，数字段按数值、
/// 字母段按字典序；缺段补 0；数字段 > 字母段。够用于"挑最新版"。
int compareVersions(String a, String b) {
  final seg = RegExp(r'[0-9]+|[a-zA-Z]+');
  final sa = seg.allMatches(a).map((m) => m.group(0)!).toList();
  final sb = seg.allMatches(b).map((m) => m.group(0)!).toList();
  final n = sa.length > sb.length ? sa.length : sb.length;
  for (var i = 0; i < n; i++) {
    final x = i < sa.length ? sa[i] : '0';
    final y = i < sb.length ? sb[i] : '0';
    final xi = int.tryParse(x);
    final yi = int.tryParse(y);
    if (xi != null && yi != null) {
      final c = xi.compareTo(yi);
      if (c != 0) return c;
    } else if (xi != null) {
      return 1;
    } else if (yi != null) {
      return -1;
    } else {
      final c = x.compareTo(y);
      if (c != 0) return c;
    }
  }
  return 0;
}

TermuxPackageSpec newest(List<TermuxPackageSpec> specs) {
  var best = specs.first;
  for (final s in specs.skip(1)) {
    if (compareVersions(s.version, best.version) > 0) best = s;
  }
  return best;
}

class TermuxRepo {
  /// 组件 → Termux 主仓包名（openjdk-17 / aapt 即官方包名）。
  static const String jdkPackage = 'openjdk-17';
  static const String buildToolsPackage = 'aapt';

  /// 主仓与国内镜像（debs 与 Packages 索引同源）。
  static List<MirrorSource> repoMirrors() => const [
        MirrorSource('Termux 官方', 'https://packages.termux.dev/apt/termux-main'),
        MirrorSource('清华 TUNA', 'https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main'),
        MirrorSource('中科大', 'https://mirrors.ustc.edu.cn/termux/apt/termux-main'),
        MirrorSource('ISCAS', 'https://mirror.iscas.ac.cn/termux/apt/termux-main'),
      ];

  static String indexPath(String repoBase) =>
      '$repoBase/dists/stable/main/binary-aarch64/Packages';

  /// gz 版索引路径：明文 Packages 有 8MB+，Packages.gz 只有 ~1.5MB——
  /// 弱网（几十 KB/s）下差距 5 倍时间。Bug 422 主修复之一。
  static String indexPathGz(String repoBase) =>
      '$repoBase/dists/stable/main/binary-aarch64/Packages.gz';

  /// 与 SdkDownloader 同语义的超时常量（独立定义避免跨文件耦合）：
  /// 响应头 20s（connectionTimeout 只管到握手）/ 数据间隔 15s。
  static const Duration _respHeaderTimeout = Duration(seconds: 20);
  static const Duration _stallTimeout = Duration(seconds: 15);

  /// 拉取并解析索引，返回目标包的最新条目。逐镜像尝试：404/超时/断网 → 下一个。
  ///
  /// 三重保护（Bug 422，2026-09-18 真机反馈驱动）：
  /// ① 拉 Packages.gz（体积减 5 倍）；② 卡死熔断——原实现
  /// `resp.transform(...).join()` 无任何数据侧超时，服务端 hang 时永久
  /// 挂起，真机弱网下"查询索引"一小时不返回（与 Bug 421 同款死逻辑：
  /// 超时检查必须由 Stream.timeout 独立驱动，不能依赖数据到达）；
  /// ③ 磁盘缓存回退——全镜像失败时用上次成功拉取的索引（版本可能
  /// 略旧，只是非最新，可接受；比"装不了"强）。
  static Future<TermuxPackageSpec> resolve(
    String pkg, {
    void Function(String mirrorName)? onMirror,
    String? cachePath,
  }) async {
    Object? lastErr;
    for (final m in repoMirrors()) {
      try {
        onMirror?.call(m.name);
        final gz = await _fetchIndexGz(indexPathGz(m.url));
        final text = utf8.decode(gzip.decode(gz));
        final specs = parsePackagesIndex(text, pkg);
        if (specs.isEmpty) {
          throw DownloadException('索引里没有 $pkg 的 aarch64 条目');
        }
        if (cachePath != null) _writeCache(cachePath, gz);
        return newest(specs);
      } catch (e) {
        lastErr = e;
      }
    }
    // 全镜像失败 → 缓存回退（indexing 卡一小时的教训：弱网下"旧索引"
    // 远比"查询失败"有用；下载走 SdkDownloader 多源，还有兜底）
    if (cachePath != null) {
      final cached = _readCache(cachePath);
      if (cached != null) {
        final specs = parsePackagesIndex(utf8.decode(gzip.decode(cached)), pkg);
        if (specs.isNotEmpty) return newest(specs);
      }
    }
    throw DownloadException('Termux 仓库索引获取失败（$pkg）：$lastErr');
  }

  /// 全部镜像的 deb 直链（配合 SdkDownloader 多源下载 + 竞速）。
  static List<MirrorSource> debMirrors(TermuxPackageSpec spec) => repoMirrors()
      .map((m) => MirrorSource(m.name, '${m.url}/${spec.filename}'))
      .toList();

  /// 拉 Packages.gz 原始字节。超时三件套：连接 20s（含 DNS 后的握手）/
  /// 响应头 20s / 数据间隔 stall 15s（Stream.timeout 驱动，事件间隔超时
  /// 即抛 → 上层换下一个镜像，不再永久挂起）。
  static Future<List<int>> _fetchIndexGz(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(_respHeaderTimeout);
      if (resp.statusCode != 200) {
        throw DownloadException('HTTP ${resp.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in resp.timeout(_stallTimeout)) {
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) throw DownloadException('空响应');
      return bytes;
    } finally {
      client.close();
    }
  }

  /// 索引缓存（存原始 gz 字节，~1.5MB；写失败静默——缓存只是兜底）。
  static void _writeCache(String path, List<int> gz) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(gz);
    } catch (_) {}
  }

  static List<int>? _readCache(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.readAsBytesSync() : null;
    } catch (_) {
      return null;
    }
  }
}

/// Termux 社区 bionic Flutter 的版本快照（2026-09-18 供应链核实）。
///
/// Flutter 官方不支持 bionic host → **Termux 主仓没有 flutter 包**，社区分发
/// 走 GitHub releases：ImL1s/termux-flutter-wsl（fork 自 mumumusuc/
/// termux-flutter），WSL 交叉编译 engine + dart，deb 内含配套 gen_snapshot。
/// 版本/SHA256/大小在此锁定防漂移；代理源时效性强，pickFastest 竞速会
/// 自动剔除死源，全部失败 → 回退「本地导入」路线。
class TermuxFlutterRelease {
  static const String repo = 'ImL1s/termux-flutter-wsl';
  static const String version = 'v3.44.0'; // Flutter 3.44.0 / Dart 3.12.1
  static const String asset = 'flutter_3.44.0_aarch64.deb';
  static const String sha256 =
      'b8af08d26ee4ae4b3dcf1aab4ee6b05965529587ddf1bc9b936b48b5f01f9846';
  static const int size = 666366556;

  static String githubUrl() =>
      'https://github.com/$repo/releases/download/$version/$asset';

  /// 下载源：GitHub 直链 + gh 加速代理（前缀式代理，拼接规则为
  /// `<proxy><github-url>`）。谁快用谁，分片轮流起步自然分散到多源。
  static List<MirrorSource> mirrors() => const [
        MirrorSource('GitHub 直链', 'https://github.com/$repo/releases/download/$version/$asset'),
        MirrorSource('gh-proxy', 'https://gh-proxy.com/https://github.com/$repo/releases/download/$version/$asset'),
        MirrorSource('ghfast', 'https://ghfast.top/https://github.com/$repo/releases/download/$version/$asset'),
        MirrorSource('ghproxy.net', 'https://ghproxy.net/https://github.com/$repo/releases/download/$version/$asset'),
      ];
}

// ---------------- 安装器 ----------------

/// Termux 组件安装阶段。
enum TermuxPhase {
  idle,
  indexing,
  downloading,
  unpacking,
  importing,
  verifying,
  ready,
  uninstalling,
  error,
}

class TermuxInstaller {
  /// deb 解包 + shebang 改写（容器内执行）。
  ///
  /// @DEB@：容器内可见的 deb 路径；@STAGE@：容器内暂存目录；
  /// @PREFIX@：**宿主** prefix 字符串（shebang 改写目标——bare 执行时
  /// 二进制按宿主路径被 exec，脚本里的绝对路径必须是宿主路径）。
  /// Termux deb 有两种布局：prefix 相对（bin/...）或全路径
  /// （data/data/com.termux/...），两种都识别。
  static const String _unpackScript = r'''
set -e
D=@DEB@
S=@STAGE@
P=@PREFIX@
[ -f "$D" ] || { echo NO_DEB; exit 2; }
rm -rf "$S"; mkdir -p "$S"
dpkg-deb -x "$D" "$S" || { echo UNPACK_FAIL; exit 3; }
if [ -d "$S/data/data/com.termux/files/usr" ]; then
  SRC="$S/data/data/com.termux/files/usr"
else
  SRC="$S"
fi
[ -d "$SRC" ] || { echo NO_USR; exit 4; }
n=0
LIST=$(grep -rlI 'com\.termux' "$SRC" 2>/dev/null | head -500 || true)
for f in $LIST; do
  sed -i 's|/data/data/com.termux/files/usr|'"$P"'|g' "$f" && n=$((n+1))
done
echo "REWROTE:$n"
echo "SRC=$SRC"
''';

  /// 落位：容器 stage 里的 SRC 子树 → /opt/foa-termux/usr。
  /// 同一物理目录的容器视图内 cp -a，零宿主搬运。
  static const String _commitScript = r'''
set -e
SRC=@SRC@
P=/opt/foa-termux/usr
mkdir -p "$P"
cp -a "$SRC/." "$P/"
rm -rf @STAGE@
echo COMMIT_OK
''';

  static Future<TermuxPackageSpec> _downloadDeb(
    String pkg,
    EnvInfo env, {
    void Function(String phase)? onPhase,
    void Function(String mirror)? onMirror,
    void Function(DownloadProgress)? onProgress,
    DownloadCancelToken? token,
  }) async {
    onPhase?.call('indexing');
    // 缓存回退（Bug 422）：索引存 filesDir，全镜像失败时用旧索引兜底
    final spec = await TermuxRepo.resolve(
      pkg,
      onMirror: onMirror,
      cachePath: '${env.filesDir}/termux-packages-index.gz',
    );
    final dl = Directory(TermuxPaths.dlDir(env));
    await dl.create(recursive: true);
    final save = '${dl.path}/${spec.fileName()}';
    onPhase?.call('downloading');
    final ordered = await SdkDownloader.pickFastest(
      TermuxRepo.debMirrors(spec),
      token: token,
    );
    await SdkDownloader.downloadMultiSource(
      ordered,
      save,
      spec.size,
      sha256: spec.sha256,
      onProgress: onProgress,
      onMirrorUsed: (m) => onMirror?.call(m.name),
      token: token,
    );
    return spec;
  }

  /// 通用 deb 安装：下载 → 容器 dpkg-deb 解包 + shebang 改写 → 落位。
  static Future<String> installPackage(
    ProotBridge bridge,
    EnvInfo env,
    String pkg, {
    void Function(String phase)? onPhase,
    void Function(String mirror)? onMirror,
    void Function(DownloadProgress)? onProgress,
    DownloadCancelToken? token,
  }) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装：解包借用容器的 dpkg-deb，请先初始化环境');
    }
    final spec = await _downloadDeb(pkg, env,
        onPhase: onPhase, onMirror: onMirror, onProgress: onProgress, token: token);
    onPhase?.call('unpacking');
    final debInContainer =
        '${TermuxPaths.containerDlDir()}/${spec.fileName()}';
    final stage = TermuxPaths.containerStageDir();
    final s1 = _unpackScript
        .replaceAll('@DEB@', debInContainer)
        .replaceAll('@STAGE@', stage)
        .replaceAll('@PREFIX@', TermuxPaths.prefix(env));
    final r1 = await bridge.exec(s1, timeoutSec: 900);
    if (r1.exitCode != 0 || !r1.stdout.contains('REWROTE:')) {
      throw DownloadException('解包失败：${_tail(r1)}');
    }
    final src = _extractMarker(r1.stdout, 'SRC=') ?? stage;
    final s2 = _commitScript
        .replaceAll('@SRC@', src)
        .replaceAll('@STAGE@', stage);
    final r2 = await bridge.exec(s2, timeoutSec: 600);
    if (r2.exitCode != 0 || !r2.stdout.contains('COMMIT_OK')) {
      throw DownloadException('落位失败：${_tail(r2)}');
    }
    final rewrote = _extractMarker(r1.stdout, 'REWROTE:') ?? '0';
    return '${spec.package} ${spec.version} 已装到 /opt/foa-termux/usr（改写 $rewrote 个文本文件）';
  }

  /// Flutter（bionic）本地导入：ImL1s 系 deb 或 tar.xz/tar.gz。
  ///
  /// 版本以导入包为准（如 3.44.0），与容器 SDK 的 3.47.4 **可能不同**——
  /// termux 模式构建用的就是导入的这套（dart 与 gen_snapshot 配套）。
  /// 本地选择器落点在 filesDir/imports（rootfs 外，容器不可见），
  /// 所以先宿主侧拷进 rootfs 树内的下载区，再走容器解包。
  static Future<String> installFlutterFromLocalFile(
    ProotBridge bridge,
    EnvInfo env,
    String hostFilePath, {
    void Function(String phase)? onPhase,
  }) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装：解包借用容器的 dpkg-deb/tar，请先初始化环境');
    }
    onPhase?.call('importing');
    final f = File(hostFilePath);
    if (!await f.exists()) throw DownloadException('文件不存在：$hostFilePath');
    final name = f.path.split('/').last;
    if (!_isFlutterArchive(name.toLowerCase())) {
      throw DownloadException('仅支持 .deb / .tar.xz / .tar.gz（当前：$name）');
    }
    final dl = Directory(TermuxPaths.dlDir(env));
    await dl.create(recursive: true);
    final copied = '${dl.path}/$name';
    if (copied != hostFilePath) {
      await f.copy(copied);
    }
    return _unpackAndCommitFlutter(bridge, env, name, onPhase: onPhase);
  }

  /// Flutter（bionic）在线下载：ImL1s/termux-flutter-wsl 的 GitHub release
  ///（2026-09 快照锁定于 [TermuxFlutterRelease]，SHA256 校验防漂移）。
  ///
  /// GitHub 直链 + gh 加速代理多源竞速（pickFastest 剔除死源），666MB 用
  /// 8 分片并行；慢速/卡死熔断自动换源续传。下载完与本地导入走同一套
  /// 容器解包落位。全部源失败 → 提示回退本地导入。
  static Future<String> installFlutterOnline(
    ProotBridge bridge,
    EnvInfo env, {
    void Function(String phase)? onPhase,
    void Function(String mirror)? onMirror,
    void Function(DownloadProgress)? onProgress,
    DownloadCancelToken? token,
  }) async {
    if (!env.rootfsInstalled) {
      throw DownloadException('rootfs 未安装：解包借用容器的 dpkg-deb，请先初始化环境');
    }
    onPhase?.call('indexing');
    final dl = Directory(TermuxPaths.dlDir(env));
    await dl.create(recursive: true);
    final save = '${dl.path}/${TermuxFlutterRelease.asset}';
    onPhase?.call('downloading');
    final ordered = await SdkDownloader.pickFastest(
      TermuxFlutterRelease.mirrors(),
      token: token,
    );
    await SdkDownloader.downloadMultiSource(
      ordered,
      save,
      TermuxFlutterRelease.size,
      sha256: TermuxFlutterRelease.sha256,
      segments: 8,
      onProgress: onProgress,
      onMirrorUsed: (m) => onMirror?.call(m.name),
      token: token,
    );
    return _unpackAndCommitFlutter(
        bridge, env, TermuxFlutterRelease.asset, onPhase: onPhase);
  }

  static bool _isFlutterArchive(String lower) =>
      lower.endsWith('.deb') ||
      lower.endsWith('.tar.xz') ||
      lower.endsWith('.txz') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz');

  /// 共享解包落位：下载区（rootfs 树内）里的 [fileName] → 容器解包 →
  /// com.termux 绝对路径改写 → cp 到 /opt/foa-termux/usr/opt/flutter。
  static Future<String> _unpackAndCommitFlutter(
    ProotBridge bridge,
    EnvInfo env,
    String fileName, {
    void Function(String phase)? onPhase,
  }) async {
    onPhase?.call('importing');
    final containerFile = '${TermuxPaths.containerDlDir()}/$fileName';
    final stage = TermuxPaths.containerStageDir();
    final lower = fileName.toLowerCase();
    final bool isDeb = lower.endsWith('.deb');
    final bool isTarXz = lower.endsWith('.tar.xz') || lower.endsWith('.txz');

    // 注意：脚本里 shell 的 $ 变量一律 \$… 转义，$stage 才是 Dart 插值
    final unpack = isDeb
        ? 'dpkg-deb -x "\$F" "\$S" || { echo UNPACK_FAIL; exit 3; }'
        : isTarXz
            ? 'tar -xJf "\$F" -C "\$S" || { echo UNPACK_FAIL; exit 3; }'
            : 'tar -xzf "\$F" -C "\$S" || { echo UNPACK_FAIL; exit 3; }';
    final s = '''
set -e
F=$containerFile
S=$stage
P=${TermuxPaths.prefix(env)}
rm -rf "\$S" && mkdir -p "\$S"
$unpack
FL=\$(find "\$S" -type f -path "*/bin/flutter" | head -1)
[ -n "\$FL" ] || { echo NO_FLUTTER; exit 4; }
SRC=\$(dirname "\$(dirname "\$FL")")
n=0
LIST=\$(grep -rlI 'com\\.termux' "\$SRC" 2>/dev/null | head -800 || true)
for f2 in \$LIST; do
  sed -i 's|/data/data/com.termux/files/usr|'"\$P"'|g' "\$f2" && n=\$((n+1))
done
mkdir -p /opt/foa-termux/usr/opt
rm -rf /opt/foa-termux/usr/opt/flutter
cp -a "\$SRC" /opt/foa-termux/usr/opt/flutter
rm -rf "\$S"
echo "FLUTTER_OK:\$n"
''';
    final r = await bridge.exec(s, timeoutSec: 1800);
    if (r.exitCode != 0 || !r.stdout.contains('FLUTTER_OK')) {
      throw DownloadException('Flutter 导入失败：${_tail(r)}');
    }
    final rewrote = _extractMarker(r.stdout, 'FLUTTER_OK:') ?? '0';
    return 'Flutter（bionic）已导入 /opt/foa-termux/usr/opt/flutter（改写 $rewrote 个文本文件）';
  }

  /// bare 冒烟体检（不经 proot 直跑；验证 W^X + bionic 链接可达性）。
  static Future<String> smoke(ProotBridge bridge, EnvInfo env) async {
    final envPrefix = TermuxPaths.envPrefix(env);
    final results = <String>[];
    if (Directory(TermuxPaths.jdkHome(env)).existsSync()) {
      final r = await bridge.exec(
        '$envPrefix"\$JAVA_HOME/bin/java" -version 2>&1 | head -1',
        timeoutSec: 120,
        bare: true,
      );
      results.add(
          'java: ${r.stdout.trim().isEmpty ? '无输出(exit ${r.exitCode})' : r.stdout.trim()}');
    } else {
      results.add('java: 未安装');
    }
    if (File(TermuxPaths.aapt2(env)).existsSync()) {
      final r = await bridge.exec(
        '$envPrefix"${TermuxPaths.aapt2(env)}" version 2>&1 | head -1',
        timeoutSec: 60,
        bare: true,
      );
      results.add(
          'aapt2: ${r.stdout.trim().isEmpty ? '无输出(exit ${r.exitCode})' : r.stdout.trim()}');
    } else {
      results.add('aapt2: 未安装');
    }
    if (Directory(TermuxPaths.flutterHome(env)).existsSync()) {
      final r = await bridge.exec(
        '$envPrefix"${TermuxPaths.flutterHome(env)}/bin/flutter" --version 2>&1 | head -1',
        timeoutSec: 180,
        bare: true,
      );
      results.add(
          'flutter: ${r.stdout.trim().isEmpty ? '无输出(exit ${r.exitCode})' : r.stdout.trim()}');
    } else {
      results.add('flutter: 未导入');
    }
    return results.join('\n');
  }

  /// 卸载：删 prefix + 暂存目录（宿主侧 Dart IO 即可）。下载缓存保留
  /// （deb 留档，重装秒过）。
  static Future<void> uninstall(EnvInfo env) async {
    final p = Directory(TermuxPaths.prefix(env));
    if (p.existsSync()) await p.delete(recursive: true);
    final stage = Directory('${env.rootfsPath}${TermuxPaths.containerStageDir()}');
    if (stage.existsSync()) await stage.delete(recursive: true);
  }

  // ---------------- 工具 ----------------

  static String _tail(ProotResult r) {
    final t = (r.stderr + r.stdout).trim();
    if (t.isEmpty) return 'exit ${r.exitCode}';
    return t.length > 400 ? '${t.substring(0, 400)}…' : t;
  }

  static String? _extractMarker(String out, String marker) {
    for (final line in out.split('\n')) {
      if (line.startsWith(marker)) return line.substring(marker.length).trim();
    }
    return null;
  }
}
