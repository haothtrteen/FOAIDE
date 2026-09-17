import 'dart:convert';

import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import '../toolchain/toolchain_ensure.dart';
import 'demo_templates.dart';

/// Step 7 Demo 工程创建器：容器内 flutter create 生成基础工程，再覆盖
/// main.dart 为所选模板代码。
///
/// 原理：
/// - flutter create（SDK 内建模板，不联网）生成最小 android 工程，保证后续
///   flutter build apk 可构建——手工复制 android/ 工程脆弱且易过时；
/// - 模板代码经 base64 管道写入（base64 字母表无单引号，杜绝 shell 转义）；
/// - 项目名即目录名与 Dart 包名（flutter create --project-name），严格校验。
class DemoProjectCreator {
  final ProotBridge _bridge = ProotBridge();
  final FileBrowserBridge _fb = FileBrowserBridge();

  static final RegExp _nameRe = RegExp(r'^[a-z][a-z0-9_]*$');
  static const List<String> _reserved = ['android', 'build', 'lib', 'root'];

  /// 校验项目名（目录名 + Dart 包名），返回错误文案或 null。
  static String? validateName(String name) {
    final t = name.trim();
    if (t.isEmpty) return '请输入项目名';
    if (t.length > 30) return '项目名最长 30 个字符';
    if (!_nameRe.hasMatch(t)) {
      return '仅支持小写字母、数字、下划线，且首字符必须为字母';
    }
    if (_reserved.contains(t)) return '该名称不可用';
    return null;
  }

  /// 创建工程：成功返回 null，失败返回错误文案（取命令输出尾部）。
  Future<String?> create(String name, DemoTemplate tpl) async {
    final err = validateName(name);
    if (err != null) return err;
    final q = _q(name.trim());

    // 0) flutter 工具硬依赖 git，缺失时先自动安装（幂等）
    final gitErr = await ToolchainEnsure().git();
    if (gitErr != null) return gitErr;

    // 1) 生成基础工程（含 android 平台；首次可能较慢，给足超时）。
    // FLUTTER_ALLOW_ROOT=true：proot 模拟 root，flutter 仅打印警告不阻断，
    // 显式声明避免把警告混入错误判断。
    final r1 = await _bridge.exec(
      'cd /root/projects && FLUTTER_ALLOW_ROOT=true flutter create '
      '--template=app --platforms=android --project-name $q $q',
      timeoutSec: 300,
    );
    if (r1.exitCode != 0) {
      final out = r1.stderr.isNotEmpty ? r1.stderr : r1.stdout;
      return 'flutter create 失败（exit ${r1.exitCode}）：\n${_tail(out)}';
    }

    // 2) 覆盖 main.dart 为模板代码（base64 无 shell 特殊字符）
    final b64 = base64Encode(utf8.encode(tpl.mainDart));
    final r2 = await _bridge.exec(
      "printf '%s' '$b64' | base64 -d > /root/projects/$q/lib/main.dart "
      '&& echo MAIN_DART_OK',
      timeoutSec: 60,
    );
    if (r2.exitCode != 0) {
      final out = r2.stderr.isNotEmpty ? r2.stderr : r2.stdout;
      return '写入 main.dart 失败：\n${_tail(out)}';
    }
    return null;
  }

  /// 删除工程（容器 /root/projects/<name>）。
  Future<FsOpResult> delete(String name) {
    return _fb.delete('/root/projects/${name.trim()}');
  }

  /// shell 单引号转义。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static String _tail(String s) {
    final t = s.trim();
    return t.length <= 400 ? t : '…${t.substring(t.length - 400)}';
  }
}
