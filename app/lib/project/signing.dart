import 'dart:math';

import '../editor/fs_bridge.dart';
import '../env/proot_bridge.dart';
import '../toolchain/native_arm64.dart';

/// 正式签名（alpha.93）：keystore 生成 → 构建脚本接线 → 产物签名与验签。
///
/// **不引入任何新依赖**——用的全是容器里已经装好的开源工具：
/// - `keytool`：来自容器 JDK（[NativeArm64.jdkHome]），Apache/Harmony 血统，
///   生成 JKS keystore；
/// - `apksigner`：来自 Android SDK build-tools（AOSP 开源），
///   给 APK 打 v1/v2/v3 签名并校验；
/// - `zipalign`：同一 build-tools 目录，签名前对齐（apksigner 要求）。
///
/// 两条签名路径，UI 上如实并列、不混为一谈：
/// 1. **构建时签名**：写 `android/key.properties` + 给 `build.gradle(.kts)`
///    打补丁让 release 变体用正式 key。之后每次构建自动签好。
///    代价是要改用户的构建脚本——匹配不到已知锚点时**直接拒绝**，
///    而不是瞎改一通（见 [Signing.patchGradle]）。
/// 2. **产物签名**：对已经构建出来的 APK 直接跑 apksigner。
///    不改任何源码，DSL 无关，什么时候都能用；缺点是要多跑一次，
///    且每次出包后都得再点一次。
///
/// 能力边界：
/// - 只生成自用/上架用的**自签**证书（CA 不认，Google Play 认自签，
///   国内商店多数也认，但**不接受**我们从商店后台导出的上传证书场景）；
/// - 不做 APK 签名方案 v4、不做 AAB（.aab 签名走 jarsigner/bundletool 另一套）。
class Signing {
  Signing._();

  /// keystore 存放目录（**不在工程目录里**）。
  ///
  /// 放工程里的话：一是容易被 `git add -A` 提交上去（密钥泄露），
  /// 二是导出源码工程时会把私钥打包送人。放在 /root/keystores 则
  /// 只有本 App 的容器能看到，导出源码工程也不会带走。
  static const String keystoreDir = '/root/keystores';

  /// 有效期（天）。Google Play 要求证书有效期到 2033-10-22 之后，
  /// 10000 天 ≈ 27 年，是 flutter 官方文档给的惯例值。
  static const int defaultValidityDays = 10000;

  // ============================ 纯逻辑 ============================

  static String keystorePathFor(String projectName) =>
      '$keystoreDir/$projectName.jks';

  /// `android/key.properties` 的内容。
  ///
  /// storeFile 写**绝对路径**：gradle 里 `file(keystoreProperties["storeFile"])`
  /// 的相对基准是 android/ 目录，写相对路径容易因 cwd 变化找不到文件。
  static String keyProperties({
    required String storeFile,
    required String storePassword,
    required String keyPassword,
    required String keyAlias,
  }) {
    return 'storePassword=$storePassword\n'
        'keyPassword=$keyPassword\n'
        'keyAlias=$keyAlias\n'
        'storeFile=$storeFile\n';
  }

  /// 生成 keystore 的脚本（keytool，容器 JDK）。
  ///
  /// [force]=false 时 keystore 已存在就跳过——换 alias 重新生成会
  /// 直接覆盖旧密钥，**旧版本的应用再也升不了级**，这是不可逆的。
  static String keytoolScript({
    required String keystorePath,
    required String alias,
    required String storePass,
    required String keyPass,
    required String dname,
    int validityDays = defaultValidityDays,
    bool force = false,
  }) {
    final ks = _q(keystorePath);
    // force=true 时才覆盖：换 alias 重新生成会让**已装出去的旧版本
    // 再也升不了级**（签名对不上），这是不可逆的，默认必须挡住。
    final existsBranch = force
        ? 'echo "REPLACE=$ks"; rm -f $ks; '
        : 'echo "EXISTING=$ks"; exit 0; ';
    return ''
        'mkdir -p $keystoreDir 2>/dev/null\n'
        'if [ ! -x ${NativeArm64.jdkHome}/bin/keytool ]; then '
        'echo "ERR=容器里没有 keytool（JDK 未安装）：${NativeArm64.jdkHome}/bin/keytool"; exit 1; fi\n'
        'if [ -f $ks ]; then $existsBranch fi\n'
        '${NativeArm64.jdkHome}/bin/keytool -genkeypair -v '
        '-keystore $ks -storetype JKS -keyalg RSA -keysize 2048 '
        '-validity $validityDays -alias ${_q(alias)} '
        '-storepass ${_q(storePass)} -keypass ${_q(keyPass)} '
        '-dname ${_q(dname)} 2>&1 | tail -n 6\n'
        'if [ ! -f $ks ]; then echo "ERR=keytool 跑完了但 keystore 没生成"; exit 2; fi\n'
        'echo "CREATED=$ks"\n';
  }

  /// 给 APK 签名（zipalign → apksigner），输出到 `<原名>-signed.apk`。
  static String signApkScript({
    required String apkIn,
    required String keystorePath,
    required String alias,
    required String storePass,
    required String keyPass,
    String? apkOut,
  }) {
    final out = apkOut ?? _signedPath(apkIn);
    return ''
        'export JAVA_HOME=${NativeArm64.jdkHome}\n'
        'export PATH="\$JAVA_HOME/bin:\$PATH"\n'
        'BT=\$(ls -d ${NativeArm64.sdkHome}/build-tools/* 2>/dev/null | sort -V | tail -1)\n'
        'if [ -z "\$BT" ]; then echo "ERR=找不到 build-tools（${NativeArm64.sdkHome}/build-tools）"; exit 1; fi\n'
        'if [ ! -f ${_q(apkIn)} ]; then echo "ERR=APK 不存在：${_q(apkIn)}"; exit 2; fi\n'
        'if [ ! -f ${_q(keystorePath)} ]; then echo "ERR=keystore 不存在：${_q(keystorePath)}"; exit 3; fi\n'
        // 对齐必须在签名**之前**：v2/v3 签名覆盖整个文件的字节，
        // 签完再对齐会把签名弄坏。Gradle 出的 release 包已经是
        // 对齐过的，这里再跑一次是幂等的（zipalign 会自己判断）。
        'if [ -x "\$BT/zipalign" ]; then '
        '\$BT/zipalign -f -p 4 ${_q(apkIn)} ${_q(out)} 2>&1 | tail -n 3 || '
        '{ echo "ERR=zipalign 失败"; exit 4; }; '
        'else cp -f ${_q(apkIn)} ${_q(out)}; fi\n'
        // apksigner 只给一个 APK 参数时是**原地签**（--out 与输入同路径
        // 会被它拒绝），所以这里先对齐/复制到目标文件，再原地签。
        '\$BT/apksigner sign --ks ${_q(keystorePath)} --ks-key-alias ${_q(alias)} '
        '--ks-pass pass:${_q(storePass)} --key-pass pass:${_q(keyPass)} '
        '${_q(out)} 2>&1 | tail -n 8 || { echo "ERR=apksigner sign 失败"; exit 5; }\n'
        '\$BT/apksigner verify --print-certs ${_q(out)} 2>&1 | head -n 12\n'
        'echo "SIGNED=$out"\n';
  }

  /// 验签脚本：打印签名方案与证书主体，用来判断"是不是自己的正式签名"。
  static String verifyScript(String apkPath) {
    return ''
        'export JAVA_HOME=${NativeArm64.jdkHome}\n'
        'export PATH="\$JAVA_HOME/bin:\$PATH"\n'
        'BT=\$(ls -d ${NativeArm64.sdkHome}/build-tools/* 2>/dev/null | sort -V | tail -1)\n'
        'if [ -z "\$BT" ]; then echo "ERR=找不到 build-tools"; exit 1; fi\n'
        'if [ ! -f ${_q(apkPath)} ]; then echo "ERR=APK 不存在：${_q(apkPath)}"; exit 2; fi\n'
        '\$BT/apksigner verify -v --print-certs ${_q(apkPath)} 2>&1 | head -n 20\n';
  }

  /// 验签输出是否是 debug 签名（一眼能看出"忘了配正式签名"）。
  static bool isDebugSignature(String verifyOut) =>
      verifyOut.contains('CN=Android Debug');

  /// 从 `apksigner verify -v` 输出里抽签名方案（v1/v2/v3）。
  static List<String> schemesOf(String verifyOut) {
    final s = <String>[];
    for (final v in ['v1', 'v2', 'v3', 'v4']) {
      if (RegExp('Verifies using $v scheme \\(.*\\): true',
              caseSensitive: false)
          .hasMatch(verifyOut)) {
        s.add(v.toUpperCase());
      }
    }
    return s;
  }

  /// 签名产物路径：`<dir>/<name>-signed.apk`。
  static String _signedPath(String apkIn) {
    final i = apkIn.lastIndexOf('/');
    final dir = i < 0 ? '' : apkIn.substring(0, i);
    final name = i < 0 ? apkIn : apkIn.substring(i + 1);
    final base = name.endsWith('.apk') ? name.substring(0, name.length - 4) : name;
    return dir.isEmpty ? '$base-signed.apk' : '$dir/$base-signed.apk';
  }

  // ============================ 旧补丁修复（alpha.96） ============================

  /// 检测 `plugins {}` 遮蔽 `java` 导致的老写法。
  ///
  /// ## 背景（这是一个**真实发生过的严重 bug**）
  ///
  /// Kotlin DSL 里 `java` 本该解析成 Gradle 注入的 `JavaPluginExtension`。
  /// 但**只要文件里有 `plugins {}` 块，`java` 这个标识符就被遮蔽**，
  /// 于是 `java.util.Properties()` 全限定名会报：
  ///
  /// ```text
  /// e: build.gradle.kts:10:31: Unresolved reference 'util'.
  /// e: build.gradle.kts:13:34: Unresolved reference 'io'.
  /// ```
  ///
  /// 真 gradle 三组对照实测（Gradle 9.3.0，沙箱复现）：
  ///
  /// | 写法 | 结果 |
  /// |---|---|
  /// | 无 `plugins {}` + `java.util.Properties()` | ✅ 通过 |
  /// | **有** `plugins {}` + `java.util.Properties()` | ❌ `5:31 Unresolved 'util'` |
  /// | 有 `plugins {}` + `import` + `Properties()` | ✅ 通过 |
  ///
  /// Flutter 模板**第一行就是 `plugins {}`**，所以老写法 100% 必挂。
  ///
  /// ## 为什么需要这个函数
  ///
  /// alpha.94 修好了**生成器**（[_ktsReadProps] 改用简单名），
  /// 但**已经打过旧补丁的工程不会自动回写** —— 用户反复构建、
  /// 反复报同一个错，而 FOA 这边看起来"早就修了"。
  ///
  /// 这是"修复生成器 ≠ 修复用户现场"的典型缺口。
  static bool hasLegacyJavaFqn(String src) {
    // 只看**用法**，不看 import 行本身（import 当然要写全限定名）。
    final body = src
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('import '))
        .join('\n');
    return body.contains('java.util.') || body.contains('java.io.');
  }

  /// 把老写法的全限定名换成简单名（幂等）。
  ///
  /// ⚠️ 只在 [hasLegacyJavaFqn] 为真时才有意义；调用方应先判断。
  /// 这里不补 `import` —— [patchGradle] 的 [_ktsImports] 已经带了。
  /// 但如果用户是**手工**改的、没有 import，我们会补上。
  static String upgradeLegacyJavaFqn(String src) {
    var out = src
        .replaceAll('java.util.Properties()', 'Properties()')
        .replaceAll('java.io.FileInputStream(', 'FileInputStream(')
        .replaceAll('java.io.FileOutputStream(', 'FileOutputStream(')
        .replaceAll('java.io.File(', 'File(');
    // 补 import（幂等：已经有了就不重复加）。
    if (!RegExp(r'^\s*import\s+java\.util\.Properties\s*$', multiLine: true)
        .hasMatch(out)) {
      out = 'import java.util.Properties\n$out';
    }
    if (!RegExp(r'^\s*import\s+java\.io\.FileInputStream\s*$', multiLine: true)
        .hasMatch(out)) {
      out = 'import java.io.FileInputStream\n$out';
    }
    return out;
  }

  /// 读工程构建脚本、发现老写法就修，返回**人类可读的结论**。
  ///
  /// 设计取向：**能修就修，修不了就说清楚为什么** ——
  /// 不要静默返回"没问题"（那正是这个 bug 拖延至今的原因）。
  static Future<({bool changed, String msg})> repairLegacyPatch(
    FsBridge fs, {
    required String projectName,
  }) async {
    final src = await readBuildScript(fs, projectName);
    if (src.error != null || src.path == null || src.content == null) {
      return (changed: false, msg: src.error ?? '读不到构建脚本');
    }
    if (!src.kotlinDsl) {
      // Groovy DSL 没有这个遮蔽问题（`java.util.Properties()` 在 Groovy 里合法）。
      return (changed: false, msg: 'Groovy DSL，无需修复');
    }
    if (!hasLegacyJavaFqn(src.content!)) {
      return (changed: false, msg: '构建脚本没有老写法');
    }
    final fixed = upgradeLegacyJavaFqn(src.content!);
    final bak = '${src.path}.foa-bak';
    final existsBak = await fs.read(bak);
    if (!existsBak.ok) await fs.write(bak, src.content!);
    final w = await fs.write(src.path!, fixed);
    if (!w.ok) return (changed: false, msg: '写回失败：${w.error}');
    return (
      changed: true,
      msg: '已修复构建脚本里的 `java.util.*` 老写法'
          '（`plugins {}` 会遮蔽 `java` 标识符，导致 Unresolved reference）。'
          '备份在 ${bak.split('/').last}。',
    );
  }

  // ============================ 构建脚本补丁 ============================

  /// 构建脚本补丁结果。
  static GradlePatch patchGradle(String src, {required bool kotlinDsl}) {
    // ⚠️⚠️ alpha.96：先看是不是**老补丁**。
    //
    // 老工程（alpha.94 之前打的补丁）里写着 `java.util.Properties()`，
    // 在 `plugins {}` 存在的情况下**编译必挂**。而下面的守卫会
    // "已有 signingConfigs 就不动" → 直接返回失败 → 用户拿不到任何修复。
    //
    // 所以这里**先修老写法，再走原逻辑**：修完如果还有 signingConfigs，
    // 守卫照常拦住（不重复插入），但至少脚本已经能编译了。
    if (kotlinDsl && hasLegacyJavaFqn(src)) {
      src = upgradeLegacyJavaFqn(src);
    }

    // 已经接过签名就不再动——重复插入会让 gradle 报
    // "signingConfigs 重复定义"，而且用户可能自己手写过一套。
    //
    // ⚠️ 判据必须是**声明块**（`signingConfigs {`），不能只搜
    // `signingConfigs` 这个子串：Flutter 默认模板的 release 变体里
    // 就有 `signingConfigs.getByName("debug")`，用子串判的话
    // **每一个新工程都会被误判成"已配置"**（真机模板实测踩到）。
    if (RegExp(r'^\s*signingConfigs\s*\{', multiLine: true).hasMatch(src)) {
      return const GradlePatch(
          ok: false, text: '', reason: '这个脚本里已经有 signingConfigs 块，不重复改写。');
    }

    final androidAt = src.indexOf(RegExp(r'^android\s*\{', multiLine: true));
    if (androidAt < 0) {
      return const GradlePatch(
          ok: false, text: '', reason: '找不到 `android {` 块，不敢改。');
    }
    final buildTypesAt = src.indexOf(RegExp(r'^\s*buildTypes\s*\{', multiLine: true));
    if (buildTypesAt < 0) {
      return const GradlePatch(
          ok: false, text: '', reason: '找不到 `buildTypes {` 块，不敢改。');
    }

    final debugLine = kotlinDsl
        ? r'signingConfig = signingConfigs.getByName("debug")'
        : 'signingConfig = signingConfigs.debug';
    if (!src.contains(debugLine)) {
      return GradlePatch(
        ok: false,
        text: '',
        reason: '没找到 release 变体里那行 `$debugLine`——'
            '它可能被改过或用了别的写法。脚本不动，请用「给已产出的 APK 签名」。',
      );
    }

    final indent = _indentOf(src, buildTypesAt);
    final props = kotlinDsl ? _ktsProps(indent) : _groovyProps(indent);
    final release = kotlinDsl ? 'getByName("release")' : 'release';

    var out = src;
    // 模板自带的两行注释（"TODO: Add your own signing config" /
    // "Signing with the debug keys for now"）改完之后就是**错的**，
    // 留着会让人以为还是 debug 签名。
    for (final c in const [
      '// TODO: Add your own signing config for the release build.',
      '// Signing with the debug keys for now, so `flutter run --release` works.',
    ]) {
      out = out.replaceAll(RegExp('^[ \\t]*${RegExp.escape(c)}[ \\t]*\\n?',
          multiLine: true), '');
    }
    // 先改后面、再插前面：从前往后插会把后面的下标顶偏。
    out = out.replaceFirst(
        debugLine, 'signingConfig = signingConfigs.$release');
    out = _insertBefore(out, buildTypesAt, props);
    // key.properties 的读取块要落在 `android {` 之外（脚本顶层），
    // 否则 gradle 会把 keystoreProperties 当成 android 扩展的属性。
    out = _insertBefore(
        out, androidAt, kotlinDsl ? _ktsReadProps : _groovyReadProps);
    if (kotlinDsl) {
      // Kotlin 的 import 必须在所有声明之前（含 plugins {} 块）。
      out = _ktsImports + out;
    }
    return GradlePatch(ok: true, text: out, reason: '');
  }

  /// Groovy DSL（build.gradle）的 signingConfigs 块。
  ///
  /// [indent] 取自 `buildTypes {` 那一行的缩进——两者必须同级，
  /// 写死 4 空格的话，缩进风格不同的工程会拼出语法错误。
  static String _groovyProps(String indent) => _lines(indent, const [
        'signingConfigs {',
        '    release {',
        '        keyAlias = keystoreProperties["keyAlias"]',
        '        keyPassword = keystoreProperties["keyPassword"]',
        '        storeFile = keystoreProperties["storeFile"] ? file(keystoreProperties["storeFile"]) : null',
        '        storePassword = keystoreProperties["storePassword"]',
        '    }',
        '}',
      ]);

  /// Kotlin DSL（build.gradle.kts）的 signingConfigs 块。
  static String _ktsProps(String indent) => _lines(indent, const [
        'signingConfigs {',
        '    create("release") {',
        '        keyAlias = keystoreProperties["keyAlias"] as String',
        '        keyPassword = keystoreProperties["keyPassword"] as String',
        '        storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }',
        '        storePassword = keystoreProperties["storePassword"] as String',
        '    }',
        '}',
      ]);

  /// 拼缩进 + 行（避开 `${indent}xxx` 这种插值写法）。
  static String _lines(String indent, List<String> lines) =>
      lines.map((l) => l.isEmpty ? '\n' : '$indent$l\n').join();

  /// 放在 `android {` 之前的属性读取块。
  static String get _groovyReadProps => ''
      'def keystoreProperties = new Properties()\n'
      'def keystorePropertiesFile = rootProject.file("key.properties")\n'
      'if (keystorePropertiesFile.exists()) {\n'
      '    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))\n'
      '}\n\n';

  /// ⚠️⚠️ 这里**必须**用 import 进来的简单名，不能写 `java.util.Properties()`
  /// 这种全限定名 —— 真机实测（alpha.95 修）：
  ///
  /// ```
  /// e: build.gradle.kts:10:31: Unresolved reference 'util'.
  ///    val keystoreProperties = java.util.Properties()
  /// e: build.gradle.kts:13:34: Unresolved reference 'io'.
  /// ```
  ///
  /// 原因是 **`plugins {}` 块会让 `java` 这个标识符失效**：脚本里 `java`
  /// 本来会解析成 `JavaPluginExtension`（Gradle 注入的扩展），全限定名
  /// 因此被连根打断。沙箱对照实测：
  ///
  /// | 脚本内容 | 结果 |
  /// |---|---|
  /// | 只有 `val p = java.util.Properties()`（无 plugins 块） | ✅ 通过 |
  /// | **带 `plugins {}`** + `java.util.Properties()` | ❌ `Unresolved reference 'util'` |
  /// | 带 `plugins {}` + `import java.util.Properties` 后用 `Properties()` | ✅ 通过 |
  ///
  /// 而 Flutter 的 `build.gradle.kts` 模板**第一行就是 `plugins {}`**，
  /// 所以这种写法在真实工程里是 100% 必挂。
  ///
  /// 教训：我（AI）在给 FOA 自己的出包脚本加 `doNotTrackState` 时**已经踩过
  /// 同一个坑并把结论写进了手册**（`java` 被遮蔽 → 改用 `mutableListOf`），
  /// 却没有回头检查这里 —— 手册里躺着一条自己没执行的结论。
  /// ⚠️⚠️ **必须**用 import 进来的简单名，不能写 `java.util.Properties()`。
  ///
  /// 根因：**`plugins {}` 块会让 `java` 这个标识符失效** ——
  /// Kotlin DSL 里 `java` 本该是 Gradle 注入的 `JavaPluginExtension`，
  /// 有 `plugins {}` 时它被遮蔽，于是 `java.util.Properties()`
  /// 报 `Unresolved reference 'util'`。
  ///
  /// 真 gradle 三组对照实测（Gradle 9.3.0）：
  ///
  /// | 写法 | 结果 |
  /// |---|---|
  /// | 无 `plugins {}` + `java.util.Properties()` | ✅ 通过 |
  /// | **有** `plugins {}` + `java.util.Properties()` | ❌ `5:31 Unresolved 'util'` |
  /// | 有 `plugins {}` + `import` + `Properties()` | ✅ 通过 |
  ///
  /// Flutter 模板第一行就是 `plugins {}`，所以老写法 100% 必挂。
  ///
  /// 教训：我在给 FOA 自己的出包脚本加 `doNotTrackState` 时**已经踩过
  /// 同一个坑并把结论写进了手册**，却没回头检查这里的补丁代码。
  /// 而更深的教训是：**修好生成器 ≠ 修好用户现场** ——
  /// 已经打过旧补丁的工程不会自动回写，所以还需要
  /// [hasLegacyJavaFqn] / [repairLegacyPatch] 这套检测修复。
  static String get _ktsReadProps => ''
      'val keystoreProperties = Properties()\n'
      'val keystorePropertiesFile = rootProject.file("key.properties")\n'
      'if (keystorePropertiesFile.exists()) {\n'
      '    keystoreProperties.load(FileInputStream(keystorePropertiesFile))\n'
      '}\n\n';

  /// Kotlin 的 import 必须写在**所有声明之前**（含 `plugins {}` 块），
  /// 所以单独拎出来、由 [patchGradle] 拼到文件最前面。
  static String get _ktsImports => ''
      'import java.util.Properties\n'
      'import java.io.FileInputStream\n\n';

  // ============================ 落盘（走桥） ============================

  /// 写 `android/key.properties`，并把它加进 android/.gitignore。
  ///
  /// 后者不是顺手：明文密码一旦被 `git add -A` 提交——尤其 alpha.93
  /// 刚加的 Git 面板让"全选提交"变成一键操作——就永久留在历史里了。
  static Future<({bool ok, String msg})> writeKeyProperties(
    FsBridge fs, {
    required String projectName,
    required String storeFile,
    required String storePassword,
    required String keyPassword,
    required String keyAlias,
  }) async {
    final path = '$kProjectsRoot/$projectName/android/key.properties';
    final r = await fs.write(
      path,
      keyProperties(
        storeFile: storeFile,
        storePassword: storePassword,
        keyPassword: keyPassword,
        keyAlias: keyAlias,
      ),
    );
    if (!r.ok) return (ok: false, msg: '写 key.properties 失败：${r.error}');
    await _ensureGitIgnored(fs, projectName, 'key.properties');
    return (ok: true, msg: '已写入 android/key.properties');
  }

  /// 读取构建脚本（kts 优先，回落 groovy），返回 (路径, 内容, 是否 kts)。
  static Future<({String? path, String? content, bool kotlinDsl, String? error})>
      readBuildScript(FsBridge fs, String projectName) async {
    final base = '$kProjectsRoot/$projectName/android/app';
    for (final e in [
      ('build.gradle.kts', true),
      ('build.gradle', false),
    ]) {
      final r = await fs.read('$base/${e.$1}');
      if (r.ok) {
        return (
          path: '$base/${e.$1}',
          content: r.content,
          kotlinDsl: e.$2,
          error: null,
        );
      }
    }
    return (
      path: null,
      content: null,
      kotlinDsl: false,
      error: 'android/app/ 下既没有 build.gradle.kts 也没有 build.gradle',
    );
  }

  /// 打补丁并写回（先存一份 .foa-bak 备份，只存第一次）。
  ///
  /// ⚠️ alpha.96：如果工程里是**老补丁**（`java.util.Properties()` 写法，
  /// 在 `plugins {}` 存在时编译必挂），即使 `signingConfigs` 已存在、
  /// 走不了完整补丁流程，也**必须把老写法修掉** ——
  /// 否则用户会反复构建、反复看到同一个 `Unresolved reference`。
  static Future<({bool ok, String msg})> patchBuildScript(
    FsBridge fs, {
    required String projectName,
  }) async {
    final src = await readBuildScript(fs, projectName);
    if (src.error != null || src.path == null || src.content == null) {
      return (ok: false, msg: src.error ?? '读不到构建脚本');
    }

    final hadLegacy = src.kotlinDsl && hasLegacyJavaFqn(src.content!);
    final p = patchGradle(src.content!, kotlinDsl: src.kotlinDsl);

    // 情况一：完整补丁成功 → 写完整结果（里面已经含老写法修复）。
    if (p.ok) {
      final bak = '${src.path}.foa-bak';
      final existsBak = await fs.read(bak);
      if (!existsBak.ok) await fs.write(bak, src.content!);

      final w = await fs.write(src.path!, p.text);
      if (!w.ok) return (ok: false, msg: '写回构建脚本失败：${w.error}');
      return (
        ok: true,
        msg: '已改 ${src.path!.split('/').last}：release 变体现在用正式签名，'
            '原文件备份在 ${bak.split('/').last}。'
            '${hadLegacy ? '（同时修掉了 `java.util.*` 老写法）' : ''}',
      );
    }

    // 情况二：补丁打不了，但**有老写法要修** → 单独修，写成"部分成功"。
    //
    // 这是这个 bug 拖延至今的关键分支：原实现直接 return p.reason，
    // 用户看到"构建脚本没改"，而真正会炸的那两行**原封不动留在文件里**。
    if (hadLegacy) {
      final fixed = upgradeLegacyJavaFqn(src.content!);
      final bak = '${src.path}.foa-bak';
      final existsBak = await fs.read(bak);
      if (!existsBak.ok) await fs.write(bak, src.content!);
      final w = await fs.write(src.path!, fixed);
      if (!w.ok) {
        return (ok: false, msg: '修复老写法时写回失败：${w.error}');
      }
      return (
        ok: true,
        msg: '⚠️ 做了「必要修复」而非完整签名补丁：\n'
            '  · 已修掉 `java.util.*` 老写法（这个不改，构建 100% 报 '
            '`Unresolved reference`）\n'
            '  · 签名接线没做：${p.reason}\n'
            '  备份在 ${bak.split('/').last}。\n'
            '  keystore 与 key.properties 已就绪，可在打包区对 APK 直接签名。',
      );
    }

    // 情况三：既补不了、又没老写法 → 老实说清楚。
    return (ok: false, msg: p.reason);
  }

  /// 把 [entry] 追加进 android/.gitignore（没有该文件就直接建一个）。
  static Future<void> _ensureGitIgnored(
      FsBridge fs, String projectName, String entry) async {
    final path = '$kProjectsRoot/$projectName/android/.gitignore';
    final r = await fs.read(path);
    final cur = r.ok ? r.content : '';
    if (cur.split('\n').any((l) => l.trim() == entry)) return;
    final next = cur.isEmpty
        ? '$entry\n'
        : '${cur.endsWith('\n') ? cur : '$cur\n'}$entry\n';
    await fs.write(path, next);
  }

  // ============================ 容器命令 ============================

  /// 生成 keystore（已存在则复用）。
  static Future<({bool ok, String msg, bool reused})> generateKeystore(
    ProotBridge bridge, {
    required String keystorePath,
    required String alias,
    required String storePass,
    required String keyPass,
    required String dname,
    int validityDays = defaultValidityDays,
    bool force = false,
  }) async {
    final r = await bridge.exec(
      keytoolScript(
        keystorePath: keystorePath,
        alias: alias,
        storePass: storePass,
        keyPass: keyPass,
        dname: dname,
        validityDays: validityDays,
        force: force,
      ),
      timeoutSec: 180,
    );
    final out = '${r.stdout}\n${r.stderr}';
    if (out.contains('EXISTING=')) {
      return (ok: true, msg: '复用已有的 keystore：$keystorePath', reused: true);
    }
    final err = _errOf(out);
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? 'keytool 失败（退出码 ${r.exitCode}）', reused: false);
    }
    return (
      ok: true,
      msg: 'keystore 已生成：$keystorePath\n别名 $alias，有效期 $validityDays 天。',
      reused: false,
    );
  }

  /// 给已产出的 APK 签名并验签。返回签名后的路径。
  static Future<({bool ok, String msg, String? apk})> signApk(
    ProotBridge bridge, {
    required String apkIn,
    required String keystorePath,
    required String alias,
    required String storePass,
    required String keyPass,
  }) async {
    final r = await bridge.exec(
      signApkScript(
        apkIn: apkIn,
        keystorePath: keystorePath,
        alias: alias,
        storePass: storePass,
        keyPass: keyPass,
      ),
      timeoutSec: 300,
    );
    final out = '${r.stdout}\n${r.stderr}';
    final err = _errOf(out);
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? 'apksigner 失败（退出码 ${r.exitCode}）', apk: null);
    }
    final signed = RegExp(r'SIGNED=(\S+)').firstMatch(out)?.group(1);
    final debug = isDebugSignature(out);
    return (
      ok: true,
      msg: debug
          ? '签完了，但验签显示仍是 debug 证书——检查 keystore 与别名是否对得上。\n$out'
          : '已签名：${signed ?? _signedPath(apkIn)}\n验签：${schemesOf(out).join(' / ')}',
      apk: signed,
    );
  }

  /// 只验签，不改文件。
  static Future<({bool ok, String msg})> verify(
      ProotBridge bridge, String apkPath) async {
    final r = await bridge.exec(verifyScript(apkPath), timeoutSec: 120);
    final out = '${r.stdout}\n${r.stderr}';
    final err = _errOf(out);
    if (err != null || !r.ok) {
      return (ok: false, msg: err ?? '验签失败（退出码 ${r.exitCode}）：\n${_tail(out)}');
    }
    final debug = isDebugSignature(out);
    final schemes = schemesOf(out);
    return (
      ok: true,
      msg: '${debug ? '⚠️ debug 签名（不能上架、不能覆盖安装正式版）' : '✅ 正式签名'}\n'
          '签名方案：${schemes.isEmpty ? '未识别' : schemes.join(' / ')}\n\n$out',
    );
  }

  // ============================ 杂项 ============================

  /// 随机密码：keytool 要求 ≥6 位，手写容易太短被拒。
  ///
  /// 用 [Random.secure]——keystore 密码属于凭据，不能图省事用 Random()。
  static String randomPassword({int len = 16}) {
    const cs = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    return List.generate(len, (_) => cs[rnd.nextInt(cs.length)]).join();
  }

  /// 解析 `android/key.properties`（`k=v` 行，忽略空行与 `#` 注释）。
  static Map<String, String> parseKeyProperties(String src) {
    final m = <String, String>{};
    for (final raw in src.split('\n')) {
      final l = raw.trim();
      if (l.isEmpty || l.startsWith('#')) continue;
      final i = l.indexOf('=');
      if (i <= 0) continue;
      m[l.substring(0, i).trim()] = l.substring(i + 1).trim();
    }
    return m;
  }

  /// 从 key.properties 还原出可用配置；四项缺一（或为空）就当没配。
  ///
  /// 不另存一份 JSON：key.properties 已经是 gradle 读的**唯一真源**，
  /// 再存一份就会出现"App 以为配了、gradle 其实读不到"的错位。
  static SigningConfig? configFrom(String keyPropertiesSrc) {
    final m = parseKeyProperties(keyPropertiesSrc);
    String need(String k) => m[k]?.trim() ?? '';
    final f = need('storeFile');
    final a = need('keyAlias');
    final sp = need('storePassword');
    final kp = need('keyPassword');
    if (f.isEmpty || a.isEmpty || sp.isEmpty || kp.isEmpty) return null;
    return SigningConfig(
        storeFile: f, storePassword: sp, keyPassword: kp, keyAlias: a);
  }

  /// 单引号包裹。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String? _errOf(String out) {
    for (final l in out.split('\n')) {
      final t = l.trim();
      if (t.startsWith('ERR=')) return t.substring(4).trim();
    }
    return null;
  }

  static String _tail(String s, {int n = 8}) {
    final ls = s.trim().split('\n');
    if (ls.length <= n) return s.trim();
    return ls.sublist(ls.length - n).join('\n');
  }

  /// 取 [at] 所在行的缩进（buildTypes 与 signingConfigs 同级）。
  static String _indentOf(String src, int at) {
    final start = src.lastIndexOf('\n', at < 0 ? 0 : at) + 1;
    var i = start;
    while (i < src.length && (src[i] == ' ' || src[i] == '\t')) {
      i++;
    }
    return src.substring(start, i);
  }

  /// 在 [at]（某行的行首）之前插入 [block]。
  static String _insertBefore(String src, int at, String block) =>
      src.substring(0, at) + block + src.substring(at);
}

/// 一次"生成 keystore 并接线"所需的全部参数。
class SigningPlan {
  final String alias;
  final String storePass;
  final String keyPass;

  /// 证书主体（keytool 的 -dname）。
  final String cn;
  final String org;
  final String country;

  const SigningPlan({
    required this.alias,
    required this.storePass,
    required this.keyPass,
    required this.cn,
    required this.org,
    required this.country,
  });

  String get dname => 'CN=$cn, O=$org, C=$country';

  /// 密码太短 keytool 会直接拒（要求 ≥6 位），这里给出具体长度原因。
  String? get problem {
    if (storePass.length < 6) return 'keystore 口令至少 6 位（当前 ${storePass.length} 位）';
    if (keyPass.length < 6) return '密钥口令至少 6 位（当前 ${keyPass.length} 位）';
    if (alias.trim().isEmpty) return '别名不能为空';
    if (cn.trim().isEmpty) return '证书名称（CN）不能为空';
    return null;
  }
}

/// 一份读出来的签名配置（来源只有 android/key.properties）。
class SigningConfig {
  final String storeFile;
  final String storePassword;
  final String keyPassword;
  final String keyAlias;

  const SigningConfig({
    required this.storeFile,
    required this.storePassword,
    required this.keyPassword,
    required this.keyAlias,
  });
}

/// 构建脚本补丁结果。
class GradlePatch {
  final bool ok;
  final String text;
  final String reason;

  const GradlePatch({required this.ok, required this.text, required this.reason});
}
