import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'keystore_store.dart';
import 'signing.dart';

/// 「导入已有 keystore」对话框（alpha.94）。
///
/// 按什么顺序问是有讲究的：**先问口令，再问别名**。
/// 因为别名列表得用口令去 keytool 里读出来——先问别名的话用户只能靠猜，
/// 猜错一次就要重来一遍。所以这个表单只收三样：名字、keystore 口令、
/// 密钥口令；别名在口令验证通过之后由代码列出来让用户挑。
Future<KeystoreImportPlan?> showKeystoreImportDialog(
  BuildContext context, {
  required String defaultLabel,
}) {
  return showDialog<KeystoreImportPlan>(
    context: context,
    builder: (ctx) => _ImportDialog(defaultLabel: defaultLabel),
  );
}

/// 导入表单的结果（别名留空 = 由调用方去列出别名再让用户挑）。
class KeystoreImportPlan {
  final String label;
  final String storePass;
  final String keyPass;
  final String alias;

  const KeystoreImportPlan({
    required this.label,
    required this.storePass,
    required this.keyPass,
    this.alias = '',
  });

  /// 表单校验：口令不能空（空口令的 keystore 极罕见，空着多半是忘了填）。
  String? get problem {
    if (label.trim().isEmpty) return '给这把钥匙起个名字（比如「正式」「测试」）。';
    if (storePass.isEmpty) return 'keystore 口令不能为空。';
    if (keyPass.isEmpty) return '密钥口令不能为空。';
    return null;
  }
}

class _ImportDialog extends StatefulWidget {
  final String defaultLabel;
  const _ImportDialog({required this.defaultLabel});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  late final TextEditingController _label;
  late final TextEditingController _storePass;
  late final TextEditingController _keyPass;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.defaultLabel);
    _storePass = TextEditingController();
    _keyPass = TextEditingController();
  }

  @override
  void dispose() {
    _label.dispose();
    _storePass.dispose();
    _keyPass.dispose();
    super.dispose();
  }

  void _submit() {
    final p = KeystoreImportPlan(
      label: _label.text.trim(),
      storePass: _storePass.text,
      keyPass: _keyPass.text,
    );
    final bad = p.problem;
    if (bad != null) {
      setState(() => _err = bad);
      return;
    }
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导入已有 keystore'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: FoaColors.of(context).muted.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '从商店后台导出的上传证书、或电脑上已有的 .jks / '
                  '.keystore 都能直接导入。口令填错的话下面会明确报'
                  '「打不开 keystore」，不会静默失败。',
                  style: TextStyle(fontSize: 11, height: 1.5),
                ),
              ),
              _field(_label, '这把钥匙的名字', hint: '正式 / 测试 / 客户A…'),
              const SizedBox(height: 10),
              _field(_storePass, 'keystore 口令'),
              const SizedBox(height: 10),
              _field(_keyPass, '密钥口令', hint: '通常与上面相同'),
              if (_err.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_err,
                    style: TextStyle(
                        fontSize: 11, color: FoaColors.of(context).danger)),
              ],
              const SizedBox(height: 12),
              Text(
                '文件会被拷进 ${KeystoreStore.dir}/（权限 600），'
                '登记进 ${KeystoreStore.registryPath}。'
                '这两处都在容器 /root 下，不在工程目录里——'
                '所以不会被 git 提交，也不会跟着源码导出走。\n'
                '⚠️ 口令是明文存的：gradle 的 key.properties 本来就要求明文，'
                'AGP 不支持交互式输入，电脑上做 Android 开发也是这么存的。',
                style: TextStyle(
                    fontSize: 10.5,
                    height: 1.5,
                    color: FoaColors.of(context).muted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('导入')),
      ],
    );
  }

  Widget _field(TextEditingController c, String label, {String? hint}) {
    return TextField(
      controller: c,
      obscureText: label.contains('口令'),
      style: const TextStyle(fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        labelStyle: const TextStyle(fontSize: 12),
        hintStyle: const TextStyle(fontSize: 10.5),
        border: const OutlineInputBorder(),
      ),
    );
  }
}

/// 「生成正式签名」对话框（alpha.93）。
///
/// 单独一个文件是因为清单页已经 1400+ 行，而这里是一个**自洽的小表单**：
/// 只有 alias / 两个口令 / 证书主体，返回 [SigningPlan]，不碰任何 IO。
///
/// 设计上刻意做的两件事：
/// 1. **口令默认给随机值**（不是留空）。让用户自己想一个容易太短
///    （keytool 要 ≥6 位），而报错发生在容器里、隔着一层，反馈很差。
///    给一个能用的默认值，想改再改。
/// 2. **把"这密钥丢了会怎样"写在按钮上面**，不是藏在帮助里——
///    换密钥 = 已装出去的版本再也升不了级，这是不可逆的。
Future<SigningPlan?> showSigningDialog(
  BuildContext context, {
  required String projectName,
  required bool replacing,
}) {
  return showDialog<SigningPlan>(
    context: context,
    builder: (ctx) => _SigningDialog(
      projectName: projectName,
      replacing: replacing,
    ),
  );
}

class _SigningDialog extends StatefulWidget {
  final String projectName;
  final bool replacing;

  const _SigningDialog({required this.projectName, required this.replacing});

  @override
  State<_SigningDialog> createState() => _SigningDialogState();
}

class _SigningDialogState extends State<_SigningDialog> {
  late final TextEditingController _alias;
  late final TextEditingController _storePass;
  late final TextEditingController _keyPass;
  late final TextEditingController _cn;
  late final TextEditingController _org;
  late final TextEditingController _country;
  String _err = '';

  @override
  void initState() {
    super.initState();
    final pw = Signing.randomPassword();
    _alias = TextEditingController(text: _safeAlias(widget.projectName));
    _storePass = TextEditingController(text: pw);
    _keyPass = TextEditingController(text: pw);
    _cn = TextEditingController(text: widget.projectName);
    _org = TextEditingController(text: widget.projectName);
    _country = TextEditingController(text: 'CN');
  }

  /// alias 里不能有空格与中文（keytool 会直接报错），项目名常常带这些。
  static String _safeAlias(String name) {
    final s = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return s.isEmpty ? 'key0' : s;
  }

  @override
  void dispose() {
    _alias.dispose();
    _storePass.dispose();
    _keyPass.dispose();
    _cn.dispose();
    _org.dispose();
    _country.dispose();
    super.dispose();
  }

  void _submit() {
    final plan = SigningPlan(
      alias: _alias.text.trim(),
      storePass: _storePass.text,
      keyPass: _keyPass.text,
      cn: _cn.text.trim(),
      org: _org.text.trim(),
      country: _country.text.trim().isEmpty ? 'CN' : _country.text.trim(),
    );
    final p = plan.problem;
    if (p != null) {
      setState(() => _err = p);
      return;
    }
    Navigator.pop(context, plan);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.replacing ? '重新生成签名密钥' : '生成正式签名密钥'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.replacing)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: FoaColors.of(context).danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '重新生成会覆盖旧密钥。用它签过名的旧版本'
                    '将再也升不了级（签名对不上，只能卸载重装）——'
                    '除非你确定还没发布过，否则请先备份现有 keystore。',
                    style: TextStyle(fontSize: 11, height: 1.5),
                  ),
                ),
              _field(_alias, '密钥别名', hint: 'gradle 里的 keyAlias'),
              const SizedBox(height: 10),
              _field(_storePass, 'keystore 口令', hint: '≥6 位，已随机生成'),
              const SizedBox(height: 10),
              _field(_keyPass, '密钥口令', hint: '通常与上面相同'),
              const SizedBox(height: 10),
              _field(_cn, '证书名称 CN', hint: '你的名字或应用名'),
              const SizedBox(height: 10),
              _field(_org, '组织 O', hint: '公司/团队名'),
              const SizedBox(height: 10),
              _field(_country, '国家码 C', hint: '两位，如 CN'),
              if (_err.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_err,
                    style: TextStyle(
                        fontSize: 11, color: FoaColors.of(context).danger)),
              ],
              const SizedBox(height: 12),
              Text(
                '用容器里已有的 keytool 生成 JKS（RSA 2048，有效期 '
                '${Signing.defaultValidityDays} 天），不需要联网、不引入新依赖。'
                '密钥文件放在 ${Signing.keystoreDir}/，不会进工程目录，'
                '也不会被"导出源码工程"带走。',
                style: TextStyle(
                    fontSize: 10.5, height: 1.5, color: FoaColors.of(context).muted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.replacing ? '覆盖并重新生成' : '生成并配置'),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String label, {String? hint}) {
    return TextField(
      controller: c,
      style: const TextStyle(fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        labelStyle: const TextStyle(fontSize: 12),
        hintStyle: const TextStyle(fontSize: 10.5),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
