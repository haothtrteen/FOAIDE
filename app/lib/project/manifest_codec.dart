/// 清单（AndroidManifest / pubspec / build.gradle）读写模型（alpha.61）。
///
/// 这一层刻意做成**纯字符串变换**、不碰任何 IO：清单页要从"只读展示"
/// 变成"可编辑并同步多个文件"，最容易出错的就是正则替换的边界
/// （匹配到注释、匹配到别的标签、替换后 YAML 缩进坏掉）。
/// 把变换抽出来就能逐条单测，而不是靠真机上点一遍看看有没有崩。
///
/// 涉及的文件与字段：
/// - `pubspec.yaml`   → `name` / `description` / `version`
/// - `AndroidManifest.xml` → `android:label` / `uses-permission`
/// - `android/app/build.gradle(.kts)` → `applicationId` / `minifyEnabled`
library;

import 'dart:convert';

/// 清单页当前编辑的全部状态。
class ManifestState {
  /// pubspec `name:`（包名，dart 侧标识）。
  String pubName;

  /// pubspec `description:`（应用描述，与应用名联动）。
  String description;

  /// Manifest 的 `android:label`（桌面显示的应用名）。
  String label;

  /// `applicationId`（真正的 Android 包名，只读 + 可复制）。
  String appId;

  /// pubspec `version:` 的版本名部分（`1.0.0`）。
  String versionName;

  /// pubspec `version:` 的版本代码部分（`1`，整数）。
  String versionCode;

  /// Manifest 中声明的权限（完整名，如 `android.permission.INTERNET`）。
  List<String> permissions;

  /// R8/ProGuard 是否开启（读自 build.gradle 的 `isMinifyEnabled`）。
  bool minify;

  /// 版本代码是否需要自增（改名/改内容后提示用户）。
  /// 不自动改——发布节奏是用户的决定。
  ManifestState({
    this.pubName = '',
    this.description = '',
    this.label = '',
    this.appId = '',
    this.versionName = '1.0.0',
    this.versionCode = '1',
    this.permissions = const [],
    this.minify = true,
  });

  ManifestState copy() => ManifestState(
        pubName: pubName,
        description: description,
        label: label,
        appId: appId,
        versionName: versionName,
        versionCode: versionCode,
        permissions: List.of(permissions),
        minify: minify,
      );
}

/// pubspec / Manifest / gradle 的解析与改写（纯函数，可单测）。
class ManifestCodec {
  const ManifestCodec._();

  // ============================ 解析 ============================

  /// 解析 pubspec.yaml 的 name / description / version。
  static ({String name, String description, String verName, String verCode})
      parsePubspec(String text) {
    final name = _firstMatch(text, r'^name:\s*(.+)$') ?? '';
    // description 可能带引号，去掉首尾引号
    var desc = _firstMatch(text, r'^description:\s*(.+)$') ?? '';
    desc = _unquote(desc);
    final ver = _firstMatch(text, r'^version:\s*(.+)$') ?? '1.0.0+1';
    final plus = ver.indexOf('+');
    final verName = (plus >= 0 ? ver.substring(0, plus) : ver).trim();
    final verCode = (plus >= 0 ? ver.substring(plus + 1) : '1').trim();
    return (
      name: name,
      description: desc,
      verName: verName.isEmpty ? '1.0.0' : verName,
      verCode: verCode.isEmpty ? '1' : verCode,
    );
  }

  /// 解析 AndroidManifest.xml 的 label 与权限清单。
  ///
  /// 权限只收 `uses-permission` 标签内的 `android:name`——
  /// 原实现用 `android:name="..."` 全局匹配再筛含 "permission" 的，
  /// 会把 `<activity android:name=".MainActivity">` 之类误伤（虽然被
  /// 后面的 filter 挡掉，但语义不清）；按标签匹配更准。
  static ({String label, List<String> permissions}) parseManifest(String text) {
    final label = _firstMatch(text, r'android:label="([^"]*)"') ?? '';
    final perms = <String>[];
    // 匹配整个 <uses-permission ... /> 元素，取其 android:name
    final tagRe = RegExp(
      r'<uses-permission\b[^>]*?android:name="([^"]+)"[^>]*/?>',
      multiLine: true,
    );
    for (final m in tagRe.allMatches(text)) {
      perms.add(m.group(1)!);
    }
    return (label: label, permissions: perms);
  }

  /// 解析 build.gradle(.kts) 的 applicationId 与 minifyEnabled。
  ///
  /// ## `minify` 的语义：**文件里到底写了什么**
  ///
  /// 返回的 [minify] 是"gradle 里显式写的值"，缺键时为 `true`。
  /// 但**缺键 ≠ 写了 true** —— Flutter 官方模板的 `release {}` 块里
  /// 根本没有这一行，此时 AGP 的默认值确实是"开"（R8 跑），
  /// 所以把 `minify` 当 `true` 显示是对的；但 UI 必须知道
  /// "这是默认值、不是用户写的"，否则点了关闭又去改的时候会以为
  /// 匹配到了什么。所以额外返回 [minifyExplicit] 说明来源。
  static ({String appId, bool minify, bool minifyExplicit}) parseGradle(
      String text) {
    // Kotlin DSL: applicationId = "x"   Groovy: applicationId "x"
    final appId = _firstMatch(text, r'applicationId\s*=?\s*"([^"]*)"') ?? '';
    // 同时兼容 isMinifyEnabled = true 与 minifyEnabled true
    final minifyMatch = RegExp(
      r'(?:isMinifyEnabled|minifyEnabled)\s*=?\s*(true|false)',
    ).firstMatch(text);
    final explicit = minifyMatch != null;
    // 缺省视为开启 —— 这是 AGP 的真实默认（release 会跑 R8）。
    final minify = minifyMatch == null ? true : minifyMatch.group(1) == 'true';
    return (appId: appId, minify: minify, minifyExplicit: explicit);
  }

  /// 统计 pubspec 的依赖条数（dependencies 段内的一级键）。
  ///
  /// 用途从"依赖（N 个）"的展示升级为"依赖缓存 N 个包"的对比基准。
  static int countDependencies(String text) {
    // 必须匹配行首的 `dependencies:` 且**排除 dev_dependencies**：
    // 用 `\ndependencies:` 会漏掉文件开头的同名行；用无锚定的
    // `dependencies:` 又会命中 `dev_dependencies:`（子串匹配）。
    final m = RegExp(r'^dependencies:\s*$', multiLine: true).firstMatch(text);
    if (m == null) return 0;
    var count = 0;
    // 从该行的**下一行**开始扫（此前写成 start+1 偏移，在 start=0 时
    // 会把表头行自己当成一条依赖，导致计数恒多 1）
    final lines = text.substring(m.end).split('\n');
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      // 缩进为 0 的非空行 = 进入下一个顶级键 → 依赖段结束
      if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
        break;
      }
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      // 一级依赖形如 "  cupertino_icons: ^1.0.8"（恰好 2 空格缩进）；
      // 4 空格的 "    sdk: flutter" 是上一项的属性，不计入
      if (line.startsWith('  ') && !line.startsWith('   ')) count++;
    }
    return count;
  }

  // ============================ 改写 ============================

  /// 改 pubspec 的 `name:`。找不到该行时返回原文本（调用方应比对结果）。
  static String setPubName(String text, String name) =>
      _replaceLine(text, 'name', name);

  /// 改 pubspec 的 `description:`（YAML 值含特殊字符时加引号）。
  static String setDescription(String text, String desc) =>
      _replaceLine(text, 'description', _quoteIfNeeded(desc));

  /// 改 pubspec 的 `version: X.Y.Z+N`。
  static String setVersion(String text, String verName, String verCode) =>
      _replaceLine(text, 'version', '$verName+$verCode');

  /// 改 Manifest 的 `android:label`。
  ///
  /// 只替换**第一个** android:label——Manifest 里 label 通常只出现在
  /// `<application>` 上；若将来 activity 也加了 label，第一个仍是
  /// application 的（它最先出现），语义正确。
  static String setLabel(String text, String label) {
    final re = RegExp(r'android:label="[^"]*"');
    final m = re.firstMatch(text);
    if (m == null) return text;
    return text.replaceRange(m.start, m.end, 'android:label="$label"');
  }

  /// 增删权限：返回新的 Manifest 文本。
  ///
  /// [toAdd] 中已存在的权限不会重复插入；[toRemove] 里的权限会被整行删掉
  /// （连同其独占的一行，避免留下空行堆积）。
  /// 插入位置固定在各权限标签的**末尾**，保持既有顺序不被打乱。
  static String applyPermissions(
    String text, {
    required Set<String> toAdd,
    required Set<String> toRemove,
  }) {
    var out = text;
    // 先删
    for (final p in toRemove) {
      final re = RegExp(
        r'[ \t]*<uses-permission\b[^>]*?android:name="' +
            RegExp.escape(p) +
            r'"[^>]*/?>[ \t]*\r?\n?',
      );
      out = out.replaceAll(re, '');
    }
    // 再增（找最后一个 uses-permission 之后插入，保持成组）
    final existing = parseManifest(out).permissions.toSet();
    final adds = toAdd.where((p) => !existing.contains(p)).toList();
    if (adds.isNotEmpty) {
      final tagRe = RegExp(r'[ \t]*<uses-permission\b[^>]*/?>[ \t]*\r?\n?');
      final matches = tagRe.allMatches(out).toList();
      const indent = '    ';
      final block = adds
          .map((p) => '$indent<uses-permission android:name="$p" />\n')
          .join();
      if (matches.isEmpty) {
        // 没有权限标签：插到 <application 之前
        final appIdx = out.indexOf('<application');
        if (appIdx < 0) return out;
        return out.substring(0, appIdx) + block + out.substring(appIdx);
      }
      final last = matches.last;
      return out.substring(0, last.end) + block + out.substring(last.end);
    }
    return out;
  }

  /// 改 build.gradle 的 `isMinifyEnabled`。
  ///
  /// ## 为什么必须能**插一行**
  ///
  /// 早先这里只做替换，原文没有该键就返回原文本、让 UI 报"未找到
  /// minifyEnabled，请手动改"。但 Flutter 官方模板
  /// （`templates/app/android-kotlin.tmpl/app/build.gradle.kts.tmpl`）
  /// 的 `buildTypes { release { ... } }` 里**本来就没有这一行** ——
  /// 于是对**任何**新建工程，这个开关都关不掉：用户点了"关闭"、保存、
  /// 提示"请手动改"，进编辑器一看根本没有可改的行。
  /// 一个"开关"拧不动就是坏的，不是"保守"。
  ///
  /// ## 插在哪
  ///
  /// `buildTypes { release { ... } }` 的第一行。这是模板里唯一
  /// 语义正确的位置（`isMinifyEnabled` 只在 buildType 块里合法）。
  ///
  /// 三级兜底，越往后越保守：
  /// 1. 已有 `release {` → 插在它后面（**绝大多数情况**，模板就是这个形状）
  /// 2. 有 `buildTypes {` 但没有 `release` → 在 buildTypes 里补一个
  ///    `release { isMinifyEnabled = ... }` 块
  /// 3. 连 `buildTypes` 都没有（用户手写/裁剪过的 gradle）→ 返回原文本，
  ///    UI 照旧提示手动改 —— 这种文件我们不敢动
  ///
  /// 返回 `(code, inserted)`：[inserted] 为 true 说明这次是**新增**的，
  /// UI 可以据此提示"已为你加上这一行"。返回记录而不是只返回字符串，
  /// 是因为"改掉了"和"加上了"对用户是两件事，提示语不一样。
  static ({String code, bool inserted}) setMinify(String text, bool on) {
    final re = RegExp(r'(isMinifyEnabled|minifyEnabled)(\s*=?\s*)(true|false)');
    if (re.hasMatch(text)) {
      // 已经有一行了 —— 只改值，别动结构。
      var code = text.replaceFirstMapped(re, (m) {
        final sep = m.group(2)!.contains('=') ? ' = ' : ' ';
        return '${m.group(1)}$sep${on ? 'true' : 'false'}';
      });
      var inserted = false;
      // ⚠️ Bug 635：关闭混淆时必须**同时**关掉资源缩减。
      // AGP 有一条硬校验："Removing unused resources requires unused code
      // shrinking to be turned on."——只要 isShrinkResources 还是 true 而
      // isMinifyEnabled 变成 false，**连 debug 构建都会直接失败**：
      //   > A problem occurred configuring project ':app'.
      //   > Removing unused resources requires unused code shrinking ...
      // 也就是说"关掉 R8"这个开关以前会把整个工程搞成构建不了的状态。
      if (!on) {
        final sync = _syncShrinkResources(code, false);
        code = sync.code;
        inserted = sync.inserted;
      }
      return (code: code, inserted: inserted);
    }

    final value = on ? 'true' : 'false';

    // 一级：找 `release {`，插在它的下一行。
    //
    // ⚠️ 用 `releaseConfig` / `release` 开头的词边界匹配，别把
    // `releaseSigningConfig` 之类误当块头 —— 所以要求 `{` 紧跟其后。
    final releaseRe =
        RegExp(r'^([ \t]*)release[ \t]*\{[ \t]*$', multiLine: true);
    final rm = releaseRe.firstMatch(text);
    if (rm != null) {
      // 块头缩进 + 4 空格 = 块内第一层的缩进（Gradle 惯例，Flutter 模板也是）。
      final indent = '${rm.group(1)}    ';
      const comment = '// 由 FOAIDE 清单页写入：关闭 R8 混淆与压缩';
      // 收尾**只补一个** `\n`：`release {` 后面本来跟着一个换行 +
      // 一个空行（模板里 `{` 与 `// TODO` 之间是空的）。插入内容以
      // `\n` 结尾，正好顶替掉被我们挤走的那一行，空行数量不变。
      final block = '$indent$comment\n${indent}isMinifyEnabled = $value\n';
      return (
        code: '${text.substring(0, rm.end)}\n$block${text.substring(rm.end)}',
        inserted: true,
      );
    }

    // 二级：有 `buildTypes {` 但没有独立的 `release {` ——
    // 补一个块。用 Groovy 的 `minifyEnabled`（Groovy DSL 里没有
    // `isMinifyEnabled` 这个前缀写法；Kotlin DSL 里两种都能认）。
    final buildTypesRe =
        RegExp(r'^([ \t]*)buildTypes[ \t]*\{[ \t]*$', multiLine: true);
    final bm = buildTypesRe.firstMatch(text);
    if (bm != null) {
      final inner = '${bm.group(1)}    ';
      final isKts = text.contains('.kts') || _looksLikeKotlinDsl(text);
      final key = isKts ? 'isMinifyEnabled' : 'minifyEnabled';
      const comment = '// 由 FOAIDE 清单页写入：关闭 R8 混淆与压缩';
      final block = '\n$inner release {\n'
          '$inner    $comment\n'
          '$inner    $key = $value\n'
          '$inner}\n';
      return (
        code: '${text.substring(0, bm.end)}$block${text.substring(bm.end)}',
        inserted: true,
      );
    }

    // 三级：动不了 —— 如实返回。
    return (code: text, inserted: false);
  }

  /// 同步 `isShrinkResources` / `shrinkResources` 的值（Bug 635）。
  ///
  /// 只在**已有该行**时改值——没有就不插。理由：资源缩减是独立开关，
  /// 用户（或模板）没写就别替他决定；真正必须处理的是"写了 true、
  /// 而 minify 被关掉"这个**非法组合**（AGP 会拒绝配置工程）。
  /// 返回 [inserted] 恒为 false，签名与 [setMinify] 对齐只为调用方便。
  static ({String code, bool inserted}) _syncShrinkResources(
      String text, bool on) {
    final re = RegExp(
        r'(isShrinkResources|shrinkResources)(\s*=?\s*)(true|false)');
    if (!re.hasMatch(text)) return (code: text, inserted: false);
    final code = text.replaceFirstMapped(re, (m) {
      final sep = m.group(2)!.contains('=') ? ' = ' : ' ';
      return '${m.group(1)}$sep${on ? 'true' : 'false'}';
    });
    return (code: code, inserted: false);
  }

  // ==================== Bug 636：非法组合的检测与修复 ====================

  /// 检测 `isShrinkResources` / `shrinkResources` 的**显式**字面值。
  ///
  /// 返回 null = 文件里没有这一行（不是"值为 false"）。
  /// 这个区分很重要：没有这一行时是 AGP/Flutter 插件的默认值在起作用，
  /// 用户无从判断；而"显式写了 false"是用户自己的选择，不该被我们改。
  static bool? explicitShrinkResources(String text) {
    final m = RegExp(r'(?:isShrinkResources|shrinkResources)\s*=?\s*(true|false)')
        .firstMatch(text);
    if (m == null) return null;
    return m.group(1) == 'true';
  }

  /// 检测 `isMinifyEnabled` / `minifyEnabled` 的**显式**字面值。
  /// 语义同上：null = 没写（走 AGP 默认）。
  static bool? explicitMinify(String text) {
    final m = RegExp(r'(?:isMinifyEnabled|minifyEnabled)\s*=?\s*(true|false)')
        .firstMatch(text);
    if (m == null) return null;
    return m.group(1) == 'true';
  }

  /// **Bug 636 检测**：构建脚本是否处在 AGP 会拒绝配置的非法组合上。
  ///
  /// ## 这是报错
  ///
  /// ```
  /// A problem occurred configuring project ':app'.
  /// > Removing unused resources requires unused code shrinking
  ///   to be turned on.
  /// ```
  ///
  /// ## 真因（字节码 + SDK 源码双实证，别再靠猜）
  ///
  /// AGP `AndroidResourcesCreationConfigImpl.getUseResourceShrinker()`
  /// 的反编译逻辑：
  ///
  /// ```
  /// if (!getResourcesShrink()) return false;        // 资源缩减没开 → 无所谓
  /// if (componentType.isForTesting()) return false; // ← 注意这条
  /// if (!getMinifiedEnabled()) {
  ///     issueReporter.reportError(
  ///         "Removing unused resources requires unused code shrinking ...");
  ///     return false;                                // ← 且是 error，非警告
  /// }
  /// ```
  ///
  /// 即：**资源缩减开着、代码缩减关着 → 配置期致命错误。**
  ///
  /// ## 为什么 debug 构建也会炸（这条最反直觉）
  ///
  /// 两件事叠加：
  ///
  /// 1. **Flutter Gradle 插件**（`FlutterPlugin.kt:216`）对 `release`
  ///    无条件设 `isMinifyEnabled = true` **且** `isShrinkResources = true`
  ///    （`shouldShrinkResources()` 默认 `true`，`-Pshrink` 没传时就是它）。
  /// 2. `debug` buildType 是通过 `initWith(debugBuildType)` /
  ///    变体继承拿到 `buildTypes.release` 的属性的。
  ///
  /// 于是"在 release 块里写 `isShrinkResources = true`、又手动关掉
  /// minify"这个动作，会**连 debug 变体一起配置失败**。
  ///
  /// ## ⚠️ `--no-shrink` 救不了（这是个流传很广的误解）
  ///
  /// Flutter 自己的 help 文本原话（`flutter_command.dart:988`）：
  /// > `This flag has no effect. Code shrinking is always enabled in
  /// > release builds.`
  ///
  /// 它**不映射**到 `-Pshrink=false`（全仓库只有 deferred components
  /// 那条分支会设该属性）。所以 FOA 的构建命令里那个 `--no-shrink`
  /// 是**装饰性的**，既不关 R8、也不关资源缩减。
  ///
  /// ## 判据为什么是"两个都显式"
  ///
  /// - `shrink == true` 且 `minify == false`（**都显式写了**）→ 铁定非法。
  /// - `shrink == null`（没写）→ 走 Flutter 插件默认，插件给 release
  ///   同时设 true/true，合法，**不要动**。
  /// - `minify == null` 或为 true → 合法。
  ///
  /// 只看"显式"这两种，是为了**绝不误改我们看不懂的工程**：
  /// 有 [parseGradle] 的 `minifyExplicit` 同款考虑 —— 我们读到的
  /// "minify = true" 可能是 AGP 的默认值，拿它当判据会误判。
  static bool hasIllegalShrinkCombo(String text) {
    final shrink = explicitShrinkResources(text);
    final minify = explicitMinify(text);
    return shrink == true && minify == false;
  }

  /// **Bug 636 修复**：把非法组合改成合法。
  ///
  /// ## 两种修法，按"改哪个更尊重用户意图"排序
  ///
  /// 用户的目标状态有两种可能，我们**不该替他选**，但必须选一个能
  /// 立刻构建的。选的是**改 `shrinkResources` 而不是 `minifyEnabled`**：
  ///
  /// - `minifyEnabled = false` 是用户**刚刚手动设的**（这就是它出现在
  ///   文件里的原因），是他明确的意图 → 不能推翻；
  /// - `shrinkResources = true` 多半来自 Flutter 插件的默认或模板，
  ///   不是深思熟虑的选择 → 关掉它代价最小（只是包大一点，不会崩）。
  ///
  /// 返回 `(code, changed)`。**幂等**：合法时原样返回、`changed = false`。
  static ({String code, bool changed}) fixIllegalShrinkCombo(String text) {
    if (!hasIllegalShrinkCombo(text)) return (code: text, changed: false);
    final sync = _syncShrinkResources(text, false);
    return (code: sync.code, changed: sync.code != text);
  }

  /// 粗判这是不是 Kotlin DSL 的 gradle 文件。
  ///
  /// ## 判据不能是裸的行数比
  ///
  /// 第一版写成"数 `^\s*\w+\s*=\s*\S` 的行数与 `^\s*\w+\s+\S` 的行数，
  /// 谁多信谁"—— 这不成立：`android {` / `buildTypes {` / `release {`
  /// 这些**块头行**同时满足两条正则，会两边各计一票，最后退化成比
  /// 哪个正则"更宽松"，跟 DSL 风格毫无关系。实测 Groovy 的
  /// `android { buildTypes { } }` 就被判成了 Kotlin。
  ///
  /// 现在的判据只数**赋值行**，且互斥：
  /// - Kotlin：`键 = 值`（`minSdk = 24`）
  /// - Groovy：`键 值`（`minSdk 24`），**值不能以 `{` 开头**（那是块头）
  ///
  /// 一条也只算一条，凭计数定论。真判错了也只是多写一行键名 ——
  /// `minifyEnabled` 与 `isMinifyEnabled` 各自都能被 [parseGradle] 认回来，
  /// 不会把开关写成一个读不出的状态。
  static bool _looksLikeKotlinDsl(String text) {
    var kotlin = 0;
    var groovy = 0;
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('//') || t.startsWith('*')) continue;
      if (RegExp(r'^[A-Za-z_]\w*\s*=\s*[^=]').hasMatch(t)) {
        kotlin++;
      } else if (RegExp(r'^[A-Za-z_]\w*\s+[^={]').hasMatch(t)) {
        groovy++;
      }
    }
    return kotlin >= groovy;
  }

  /// 改 build.gradle 的 `applicationId` **和** `namespace`。
  ///
  /// ## 为什么两个一起改
  ///
  /// AGP 7.3+ 把包名拆成两个字段：
  /// - `namespace` —— **R 类与 BuildConfig 的生成位置**，编译期用；
  /// - `applicationId` —— 装机后的**唯一标识**，运行时用。
  ///
  /// 只改 `applicationId` 不改 `namespace` 也能编译、也能装，但工程里
  /// 的 `package` 声明会和 namespace 长期不一致，用户下一次导出到
  /// Android Studio 就会看到"文件位置与包名对不上"的警告。
  /// 两个一起改是**最小的一致性**。
  ///
  /// ## 不改什么（重要）
  ///
  /// **不动 Kotlin 源码目录、也不动 `.kt` 里的 `package` 声明。**
  /// Kotlin 的 `package` 与 Android 的 `namespace` 不一致**完全合法**
  /// （AGP 明确支持），改了反而可能因为目录名不匹配而编译不过。
  /// 收益（少一个警告）远小于风险（用户整个工程编不过），所以不做 ——
  /// UI 上会把这句说清楚。
  ///
  /// 返回 `(code, changed)`：[changed] 为 false 说明原文一个都没匹配上
  /// （可能不是标准工程），UI 应如实提示而不是假报成功。
  static ({String code, bool changed}) setAppId(String text, String appId) {
    var out = text;
    var changed = false;
    // Kotlin DSL: namespace = "x"   Groovy: namespace "x"
    for (final key in <String>['namespace', 'applicationId']) {
      final re = RegExp('($key\\s*=?\\s*)"[^"]*"');
      if (!re.hasMatch(out)) continue;
      out = out.replaceFirstMapped(re, (m) => '${m.group(1)}"$appId"');
      changed = true;
    }
    return (code: out, changed: changed);
  }

  /// 改 AndroidManifest 的 `package="..."`（老式工程才有）。
  ///
  /// AGP 8 起 Manifest 里的 `package` 属性已被移除（包名统一由 gradle 的
  /// `namespace` 决定），Flutter 新模板里根本没有这一行 —— 所以这里
  /// **有就改、没有就跳过**，绝不主动插入。
  static ({String code, bool changed}) setManifestPackage(
      String text, String appId) {
    final re = RegExp(r'package="[^"]*"');
    if (!re.hasMatch(text)) return (code: text, changed: false);
    return (
      code: text.replaceFirstMapped(re, (_) => 'package="$appId"'),
      changed: true,
    );
  }

  // ============================ 校验 ============================

  /// 版本名校验：`x.y.z` 后允许 `-` / `+` / 点分段（与 pub 的语义版本一致）。
  static bool validVersionName(String s) =>
      RegExp(r'^\d+\.\d+\.\d+([-+.][0-9A-Za-z.-]+)*$').hasMatch(s.trim());

  /// 版本代码校验：**纯整数**（用户要求"做纯整数/格式校验"）。
  /// 上架后版本代码必须单调递增，故不接受负数与小数。
  static bool validVersionCode(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    final v = int.tryParse(t);
    return v != null && v >= 0;
  }

  /// 版本名是否比原来"更大"（语义版本比较，仅用于提示）。
  ///
  /// 上架后降版本号会被 Play 拒绝，值得在保存前提醒（不强制阻止——
  /// 用户可能就是在做本地测试包）。
  static bool versionNameDowngrade(String from, String to) {
    int cmp(List<int> a, List<int> b) {
      for (var i = 0; i < 3; i++) {
        final x = i < a.length ? a[i] : 0;
        final y = i < b.length ? b[i] : 0;
        if (x != y) return x.compareTo(y);
      }
      return 0;
    }

    List<int> nums(String s) => s
        .split(RegExp(r'[-+]'))
        .first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    return cmp(nums(to), nums(from)) < 0;
  }

  /// 应用名校验（android:label / description）。
  /// 空值会让桌面图标没名字，属明显的配置错误。
  static bool validLabel(String s) => s.trim().isNotEmpty && s.length <= 80;

  /// 包名（applicationId）校验。
  ///
  /// ## 规则来自 AGP / Java 包名，不是我们发明的
  ///
  /// - **至少两段**（`com.example`）：单段包名在 Android 上装不上，
  ///   `aapt` 会直接报 "Package 'x' must have at least two segments"；
  /// - 每段是合法 Java 标识符：**字母或下划线开头**，后跟字母/数字/下划线；
  /// - 段与段之间用 `.` 分隔；
  /// - 总体长度 ≤ 255（Android 的硬限制）。
  ///
  /// ## 为什么允许下划线开头
  ///
  /// Java 标识符确实允许 `_` 开头，AGP 也不拦。但 `com.example._1` 这种
  /// 在 Kotlin 里会和 backing field 的约定撞语义，所以只允许**首段之后**
  /// 的段以下划线开头 —— 首段仍要求字母开头。这是收紧，不是放宽。
  ///
  /// ## 为什么不拦保留字
  ///
  /// `com.example.new` 里的 `new` 在 Java 里是关键字，理论上该拦。
  /// 但 AGP 自己都不查这个，而且用户真这么写也编得过（Kotlin 里
  /// 用反引号）。多一条规则就多一种"我明明能编过你为什么不让存"，
  /// 不值得 —— 所以**不查**，这里只保证"格式不会让 gradle 报错"。
  /// 包名校验。
  ///
  /// ## 为什么禁大写
  ///
  /// `applicationId` 本身是大写敏感的，`com.Example.App` 语法上装得上。
  /// 但 Android 生态的实际约定是**全小写**（`namespace` 会参与 R 类路径，
  /// 部分旧工具链在大写路径上出过解析问题，商店侧也普遍按小写登记）。
  /// 这里按约定收紧，把问题挡在用户点保存之前 —— 报错文案里会写清
  /// "大写字母不能用"，不会让人对着一个装不上的包名猜。
  static bool validAppId(String s) {
    final t = s.trim();
    if (t.isEmpty || t.length > 255) return false;
    final parts = t.split('.');
    if (parts.length < 2) return false;
    // 首段：小写字母开头（Android 的常见约定，也避免 aapt 的边角问题）
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(parts.first)) return false;
    // 其余段：小写字母或下划线开头
    for (final p in parts.skip(1)) {
      if (!RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(p)) return false;
    }
    return true;
  }

  // ============================ 内部 ============================

  static String? _firstMatch(String text, String pattern) =>
      RegExp(pattern, multiLine: true).firstMatch(text)?.group(1)?.trim();

  /// 替换 `key: value` 这一行（保留原有缩进风格与行尾）。
  static String _replaceLine(String text, String key, String value) {
    final re = RegExp('^(\\s*$key:\\s*)(.*)\$', multiLine: true);
    if (!re.hasMatch(text)) return text;
    return text.replaceFirstMapped(
      re,
      (m) => '${m.group(1)}$value',
    );
  }

  static String _unquote(String s) {
    final t = s.trim();
    if (t.length >= 2 &&
        ((t.startsWith('"') && t.endsWith('"')) ||
            (t.startsWith("'") && t.endsWith("'")))) {
      return t.substring(1, t.length - 1);
    }
    return t;
  }

  /// YAML 值含 `:` / `#` / 引号 / 前后空格时加双引号，避免解析错。
  static String _quoteIfNeeded(String s) {
    final t = s.trim();
    if (t.isEmpty) return '""';
    final needs = t.contains(':') ||
        t.contains('#') ||
        t.contains('"') ||
        t.contains("'") ||
        t != s ||
        RegExp(r'^[\[{&*!|>%@`]').hasMatch(t);
    if (!needs) return t;
    return '"${t.replaceAll('"', r'\"')}"';
  }

  /// 便捷：把整份清单状态序列化成调试字符串（日志/单测用）。
  static String debugDump(ManifestState s) => jsonEncode({
        'pubName': s.pubName,
        'description': s.description,
        'label': s.label,
        'appId': s.appId,
        'version': '${s.versionName}+${s.versionCode}',
        'permissions': s.permissions,
        'minify': s.minify,
      });
}
