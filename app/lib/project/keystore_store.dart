import 'dart:convert';

import '../env/proot_bridge.dart';
import '../toolchain/native_arm64.dart';

/// 签名库里的一条记录。
///
/// 为什么要单独存一份清单（而不是只靠 `android/key.properties` 反推）：
/// key.properties 描述的是"**这个工程当前用哪把钥匙**"，
/// 而用户要的是"**我有哪些钥匙**"——同一把钥匙可以给好几个工程用，
/// 一个工程也可以在正式/测试两把钥匙之间来回切。
/// 这两件事不是一个维度，硬塞进一个文件里就会出现
/// "删了这个工程的 key.properties，钥匙本身也没了"这种事。
class KeystoreEntry {
  /// 唯一 id（同时也是文件名主体：`/root/keystores/<id>.jks`）。
  final String id;

  /// 用户给的名字（「正式」「测试」「客户的」…）。
  final String label;
  final String path;
  final String alias;
  final String storePass;
  final String keyPass;

  /// 证书主体（`CN=…`），从 keystore 里读出来的，给用户辨认用。
  final String subject;

  /// 是导入进来的（不是本 App 生成的）。
  final bool imported;

  const KeystoreEntry({
    required this.id,
    required this.label,
    required this.path,
    required this.alias,
    required this.storePass,
    required this.keyPass,
    this.subject = '',
    this.imported = false,
  });

  String get display => label.trim().isEmpty ? id : label.trim();

  /// 卡片上一行看得懂的说明。
  String get detail {
    final s = subject.trim();
    final who = s.isEmpty ? alias : s;
    final p = path.split('/').last;
    return '${imported ? '导入' : '生成'} · $p · $who';
  }

  KeystoreEntry copyWith({
    String? label,
    String? alias,
    String? storePass,
    String? keyPass,
    String? subject,
  }) =>
      KeystoreEntry(
        id: id,
        label: label ?? this.label,
        path: path,
        alias: alias ?? this.alias,
        storePass: storePass ?? this.storePass,
        keyPass: keyPass ?? this.keyPass,
        subject: subject ?? this.subject,
        imported: imported,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'path': path,
        'alias': alias,
        'storePass': storePass,
        'keyPass': keyPass,
        'subject': subject,
        'imported': imported,
      };

  static KeystoreEntry? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = (raw['id'] ?? '').toString();
    final path = (raw['path'] ?? '').toString();
    // id 与 path 是这条记录的身份，缺了就没法在 UI 里被"使用"
    if (id.isEmpty || path.isEmpty) return null;
    return KeystoreEntry(
      id: id,
      label: (raw['label'] ?? '').toString(),
      path: path,
      alias: (raw['alias'] ?? '').toString(),
      storePass: (raw['storePass'] ?? '').toString(),
      keyPass: (raw['keyPass'] ?? '').toString(),
      subject: (raw['subject'] ?? '').toString(),
      imported: raw['imported'] == true,
    );
  }
}

/// 签名库（alpha.94）：多份 keystore 的登记与导入。
///
/// ## 为什么清单放在 /root/keystores 而不是工程里
///
/// 和 keystore 本身同一个理由：放工程里会被 `git add -A` 提交
/// （alpha.93 刚加的 Git 面板让"全选提交"变成一键操作），
/// 也会被「导出源码工程」打包带走——那等于把私钥明文送人。
///
/// ## 口令为什么明文存
///
/// 因为**构建必须要**：gradle 的 `key.properties` 里本来就要求明文
/// storePassword/keyPassword（AGP 不支持交互式输入），
/// 用户在电脑上做 Android 开发也是这么存的。
/// 能做的是把它放在容器 /root 下、权限 600、不进仓库、不随导出带走，
/// 而不是假装加密（密钥放哪儿？又回到同一个问题）。
/// 这一点在 UI 上明说，不藏着。
class KeystoreStore {
  KeystoreStore(this._bridge);

  final ProotBridge _bridge;

  /// keystore 存放目录（与 Signing.keystoreDir 同一个）。
  static const String dir = '/root/keystores';

  /// 清单文件。
  static const String registryPath = '/root/keystores/registry.json';

  /// Android 官方 debug keystore 的落位与口令（不是我们定的，
  /// 是 AOSP/Gradle 的约定值：alias `androiddebugkey`，口令 `android`）。
  static const String debugKeystorePath = '/root/.android/debug.keystore';
  static const String debugAlias = 'androiddebugkey';
  static const String debugPass = 'android';

  // ============================ 纯函数 ============================

  static String pathFor(String id) => '$dir/$id.jks';

  /// 把用户输入压成安全的文件名主体（去空格、中文、路径分隔符）。
  ///
  /// 不去的话 `cp` 到一半会因为路径里有空格被拆成好几个参数，
  /// 或者把 `/` 当成子目录——keystore 路径会直接写坏。
  static String safeId(String s) {
    final t = s.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final c = t.replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_|_$'), '');
    return c.isEmpty ? 'key' : c;
  }

  /// 解析清单（坏 JSON / 空文件 → 空表，不抛）。
  static List<KeystoreEntry> parse(String text) {
    if (text.trim().isEmpty) return const <KeystoreEntry>[];
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const <KeystoreEntry>[];
    }
    final list = decoded is List
        ? decoded
        : (decoded is Map ? (decoded['keystores'] as List?) : null);
    if (list == null) return const <KeystoreEntry>[];
    return list
        .map(KeystoreEntry.fromJson)
        .whereType<KeystoreEntry>()
        .toList(growable: false);
  }

  static String encode(List<KeystoreEntry> items) =>
      const JsonEncoder.withIndent('  ').convert(items.map((e) => e.toJson()).toList());

  /// 写清单（chmod 600）。
  static String saveScript(List<KeystoreEntry> items) => ''
      'mkdir -p $dir 2>/dev/null\n'
      'cat > $registryPath <<\'FOA_KS_EOF\'\n'
      '${encode(items)}\n'
      'FOA_KS_EOF\n'
      'chmod 600 $registryPath\n'
      'echo "SAVED=${items.length}"\n';

  /// 列 keystore 里的别名。
  ///
  /// `LC_ALL=C` 是必须的：keytool 的输出**随 locale 变**
  /// （中文环境下是「别名:」，英文是「Alias name:」），
  /// 不固定 locale 的话解析在部分机型上会一条都取不到。
  ///
  /// `-v` 同样是必须的：不带 `-v` 时 keytool 只打印
  /// `key0, Sep 29, 2026, PrivateKeyEntry,` 这种一行摘要，
  /// **根本没有 `Alias name:` 行**（实测 JDK 20，见手册 Bug 记录），
  /// 结果就是别名列出来永远是空的、导入后的 keyAlias 是空串。
  static String listAliasesScript({
    required String keystorePath,
    required String storePass,
  }) {
    final ks = _q(keystorePath);
    return ''
        'export JAVA_HOME=${NativeArm64.jdkHome}\n'
        'export PATH="\$JAVA_HOME/bin:\$PATH"\n'
        'if [ ! -f $ks ]; then echo "ERR=keystore 不存在：$keystorePath"; exit 1; fi\n'
        'out=\$(LC_ALL=C \$JAVA_HOME/bin/keytool -list -v -keystore $ks '
        '-storepass ${_q(storePass)} 2>&1); rc=\$?\n'
        'if [ \$rc -ne 0 ]; then '
        'd=\$(printf %s\\\\n "\$out" | grep -m1 -iE "password was incorrect|'
        'tampered|java.io.IOException|keystore" || '
        'printf %s\\\\n "\$out" | tail -n 1)\n'
        // 这里必须是**真换行**：写成字面 `\\n` 的话 shell 会把它吃掉，
        // 下一行的 echo 被拼成 `necho`，整条报错变成 `ERR=: not found`。
        '[ -n "\$d" ] || d="keytool 执行失败（exit \$rc）"\n'
        'echo "ERR=\$d"; exit 2; fi\n'
        // 别名行形如 `Alias name: key0`；`Certificate fingerprint` 之类不带
        'printf %s\\\\n "\$out" | grep -E "^(Alias name|别名)[：:] *" | '
        'sed -E "s/^(Alias name|别名)[：:] *//"\n'
        'echo "ALIASES_END"\n';
  }

  /// 从 `keytool -list` 输出里取别名。
  static List<String> parseAliases(String out) {
    final r = <String>[];
    for (final l in out.split('\n')) {
      final t = l.trim();
      if (t.isEmpty || t == 'ALIASES_END') continue;
      // 上面 sed 已经剥掉前缀；这里再兜一层（防止 sed 版本差异）
      final v = t.replaceFirst(RegExp(r'^(Alias name|别名)\s*[：:]\s*'), '');
      if (v.isNotEmpty) r.add(v);
    }
    return r;
  }

  /// 取证书主体（`Owner: CN=…`），给用户辨认"这把钥匙是谁的"。
  static String subjectOf(String out) {
    final m = RegExp(r'^Owner:\s*(.+)$', multiLine: true).firstMatch(out);
    return m == null ? '' : m.group(1)!.trim();
  }

  /// 从容器别处拷一份 keystore 进签名库。
  ///
  /// 用 `cp` 而不是 `mv`：源文件是 SAF 导入进来的临时文件，
  /// 移动走的话用户想重新导一次就得再选一遍。
  static String importScript({required String src, required String dst}) {
    final s = _q(src), d = _q(dst);
    return ''
        'if [ ! -f $s ]; then echo "ERR=找不到这个文件：$src"; exit 1; fi\n'
        'mkdir -p $dir 2>/dev/null\n'
        'cp -f $s $d 2>&1 | tail -n 2\n'
        'if [ ! -s $d ]; then echo "ERR=拷贝后目标为空：$dst"; exit 2; fi\n'
        'chmod 600 $d\n'
        'echo "IMPORTED=$dst"\n';
  }

  /// 删库里的一个 keystore 文件（清单由 [save] 单独重写）。
  static String deleteScript(String path) => ''
      'if [ -f ${_q(path)} ]; then rm -f ${_q(path)}; echo "DELETED=$path"; '
      'else echo "DELETED_MISSING=$path"; fi\n';

  /// 确保有一份 Android 官方约定的 debug keystore（没有就按官方参数生成）。
  ///
  /// 「想用 debug 签名」这条需求的实现方式：Android 的 debug keystore
  /// 参数是**公开且固定**的（alias `androiddebugkey`、口令 `android`、
  /// DN `CN=Android Debug,O=Android,C=US`）——Gradle 自己也是用这套参数
  /// 在 `~/.android/debug.keystore` 生成它的。所以我们能在容器里造一份
  /// 等价的，用 apksigner 给产物签名，签出来和 gradle 打 debug 包的
  /// 结果一样（都是 `CN=Android Debug`）。
  ///
  /// ⚠️ 顺带说清一件事：**debug 档构建本来就是 debug 签名**
  /// （`signingConfigs.release` 只作用于 release 变体），
  /// 所以"想要 debug 签名的包"最直接的办法是切到 debug 档构建，
  /// 而不是给 release 包换 debug 签名——后者装不上正式版。
  static String debugKeystoreScript() => ''
      'export JAVA_HOME=${NativeArm64.jdkHome}\n'
      'export PATH="\$JAVA_HOME/bin:\$PATH"\n'
      'mkdir -p /root/.android 2>/dev/null\n'
      'DK=$debugKeystorePath\n'
      'if [ ! -f \$DK ]; then '
      '\$JAVA_HOME/bin/keytool -genkeypair -v -keystore \$DK -storetype JKS '
      '-alias $debugAlias -storepass $debugPass -keypass $debugPass '
      '-keyalg RSA -keysize 2048 -validity 10000 '
      '-dname "CN=Android Debug,O=Android,C=US" 2>&1 | tail -n 4; fi\n'
      'if [ ! -f \$DK ]; then echo "ERR=debug keystore 没生成出来"; exit 1; fi\n'
      'echo "DEBUG_KS=\$DK"\n';

  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  // ============================ 走桥 ============================

  Future<List<KeystoreEntry>> load() async {
    final r = await _bridge.exec(
      'cat $registryPath 2>/dev/null || true',
      timeoutSec: 30,
    );
    return parse(r.stdout);
  }

  Future<({bool ok, String msg})> save(List<KeystoreEntry> items) async {
    final r = await _bridge.exec(saveScript(items), timeoutSec: 30);
    if (!r.ok) {
      return (ok: false, msg: '写签名库清单失败（退出码 ${r.exitCode}）');
    }
    return (ok: true, msg: '签名库已保存（共 ${items.length} 份）。');
  }

  /// 列别名（导入时让用户挑一个，也顺带验证口令对不对）。
  Future<({bool ok, String msg, List<String> aliases})> aliases({
    required String keystorePath,
    required String storePass,
  }) async {
    final r = await _bridge.exec(
      listAliasesScript(keystorePath: keystorePath, storePass: storePass),
      timeoutSec: 60,
    );
    final out = '${r.stdout}\n${r.stderr}';
    final err = _errOf(out);
    if (err != null || !r.ok) {
      return (
        ok: false,
        msg: err == null ? '读取 keystore 失败' : friendlyError(err),
        aliases: const <String>[],
      );
    }
    final aliases = parseAliases(r.stdout);
    // 宁可报错也不要静默返回空：空别名会被写进 key.properties 的 keyAlias，
    // 到 gradle 里才炸（报 "keyAlias 不能为空"），用户在手机上根本看不懂。
    if (aliases.isEmpty) {
      return (
        ok: false,
        msg: 'keystore 能打开，但没解析出私钥别名'
            '（可能是 keytool 输出格式特殊，或这把钥匙里没有 PrivateKeyEntry）',
        aliases: const <String>[],
      );
    }
    return (ok: true, msg: '', aliases: aliases);
  }

  /// 取证书主体（存进清单，便于用户辨认）。
  Future<String> subject({
    required String keystorePath,
    required String alias,
    required String storePass,
  }) async {
    final r = await _bridge.exec(
      'export JAVA_HOME=${NativeArm64.jdkHome}; '
      'export PATH="\$JAVA_HOME/bin:\$PATH"; '
      'LC_ALL=C \$JAVA_HOME/bin/keytool -list -v -alias ${_q(alias)} '
      '-keystore ${_q(keystorePath)} -storepass ${_q(storePass)} 2>/dev/null | '
      'grep -m1 "Owner:"',
      timeoutSec: 60,
    );
    return subjectOf(r.stdout);
  }

  /// 导入一份外部 keystore 进库。
  Future<({bool ok, String msg})> importFile({
    required String src,
    required String id,
  }) async {
    final dst = pathFor(id);
    final r = await _bridge.exec(
      importScript(src: src, dst: dst),
      timeoutSec: 60,
    );
    final err = _errOf('${r.stdout}\n${r.stderr}');
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? '导入失败（退出码 ${r.exitCode}）');
    }
    return (ok: true, msg: dst);
  }

  /// 确保 debug keystore 存在，返回路径。
  Future<({bool ok, String msg, String path})> ensureDebugKeystore() async {
    final r = await _bridge.exec(debugKeystoreScript(), timeoutSec: 180);
    final out = '${r.stdout}\n${r.stderr}';
    final err = _errOf(out);
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? '生成 debug keystore 失败', path: '');
    }
    return (ok: true, msg: '', path: debugKeystorePath);
  }

  Future<({bool ok, String msg})> delete(String path) async {
    final r = await _bridge.exec(deleteScript(path), timeoutSec: 30);
    if (!r.ok) return (ok: false, msg: '删除失败（退出码 ${r.exitCode}）');
    return (ok: true, msg: '已删除 ${path.split('/').last}');
  }

  /// keytool 的英文报错翻成中文——手机上看不懂 `Keystore was tampered`。
  ///
  /// 保留原文尾巴：真要排查的时候，英文原文比我的转述有用。
  static String friendlyError(String raw) {
    final r = raw.trim();
    if (RegExp(r'password was incorrect|tampered|java\.io\.IOException',
            caseSensitive: false)
        .hasMatch(r)) {
      return 'keystore 口令不对（也可能这文件根本不是 keystore）\n原文：$r';
    }
    // 只认"keystore/文件不存在"——keytool 里 `Certificate for <x> does not
    // exist` 也带 does not exist，那是另一回事，不能误翻成"找不到文件"。
    if (RegExp(r'(keystore|file)[^,]{0,40}does not exist'
                r'|NoSuchFile|FileNotFound',
            caseSensitive: false)
        .hasMatch(r)) {
      return '找不到 keystore 文件\n原文：$r';
    }
    if (RegExp(r'Alias .*does not exist', caseSensitive: false).hasMatch(r)) {
      return '这个别名在 keystore 里不存在\n原文：$r';
    }
    return r;
  }

  static String? _errOf(String out) {
    for (final l in out.split('\n')) {
      final t = l.trim();
      if (t.startsWith('ERR=')) return t.substring(4).trim();
    }
    return null;
  }
}
