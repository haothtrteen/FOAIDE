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
  static ({String appId, bool minify}) parseGradle(String text) {
    // Kotlin DSL: applicationId = "x"   Groovy: applicationId "x"
    final appId = _firstMatch(text, r'applicationId\s*=?\s*"([^"]*)"') ?? '';
    // 同时兼容 isMinifyEnabled = true 与 minifyEnabled true
    final minifyMatch = RegExp(
      r'(?:isMinifyEnabled|minifyEnabled)\s*=?\s*(true|false)',
    ).firstMatch(text);
    final minify = minifyMatch == null
        ? true // 缺省视为开启（Flutter release 默认 R8）
        : minifyMatch.group(1) == 'true';
    return (appId: appId, minify: minify);
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
  /// 只改第一处（release 块内的那处）。若原文没有该键，则**不插入**——
  /// 往 gradle 文件里塞结构体太冒险，交给用户在编辑器里手动加。
  static String setMinify(String text, bool on) {
    final re = RegExp(r'(isMinifyEnabled|minifyEnabled)(\s*=?\s*)(true|false)');
    return text.replaceFirstMapped(re, (m) {
      final sep = m.group(2)!.contains('=') ? ' = ' : ' ';
      return '${m.group(1)}$sep${on ? 'true' : 'false'}';
    });
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
