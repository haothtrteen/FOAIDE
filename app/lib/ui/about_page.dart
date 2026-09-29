import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'about_info.dart';
import '../core/theme.dart';

/// 「关于」独立页（alpha.61）。
///
/// 从「设置 → 关于」卡片点击进入。原先关于信息是设置页里一张 3 行小卡片，
/// 版本号还停在 alpha.26（早已过期）——用户明确提出要独立成页，并交代：
/// 1. 作者与联系方式；
/// 2. **引用到的其它项目仓库**（第三方组件来源）。
///
/// 第 2 点是本页存在的主要理由：这个 App 的构建链路里跑着十几个外部组件
/// （proot、QEMU、Debian rootfs、aapt2、cloudflared…），用户有权知道
/// 手机上到底多了什么、从哪来、什么许可。这些信息此前散落在
/// `THIRD-PARTY-NOTICES.md` 里——文档很好，但用户不会去翻仓库。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _header(context),
          const SizedBox(height: 16),
          _authorCard(context),
          const SizedBox(height: 16),
          _whatItDoesCard(context),
          const SizedBox(height: 16),
          _thirdPartyCard(context),
          const SizedBox(height: 16),
          _licenseNoteCard(context),
        ],
      ),
    );
  }

  // ---------------- 头部：图标 + 名称 + 版本 ----------------

  Widget _header(BuildContext context) {
    return Column(
      children: [
        // alpha.70：原为 `Icon(Icons.flutter_dash)`，那是 Flutter 官方
        // logo——放在"关于 FOAIDE"页里，读者会以为是本项目的图标，
        // 也就是用户说的"图标还没改"。
        //
        // 直接复用启动器那张源图（assets/icon/app_icon.png），不另画一份：
        // 两份几何一定会漂移，最后变成"关于页图标和桌面图标不一样"。
        // 也去掉了外层 primaryContainer 底 —— 图标自带 #101418 深底，
        // 再套一层主题容器会在浅色主题下露出一圈浅色边。
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.asset(
            'assets/icon/app_icon.png',
            width: 84,
            height: 84,
            fit: BoxFit.cover,
            // 图标缺失不能白屏整页（asset 拼错是运行时才发现的那类错误）。
            errorBuilder: (context, error, stack) => Container(
              width: 84,
              height: 84,
              color: FoaColors.of(context).panelBg,
              alignment: Alignment.center,
              child: Icon(Icons.terminal,
                  size: 40, color: FoaColors.of(context).muted),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Text(AboutInfo.appName,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(AboutInfo.version,
            style: TextStyle(fontSize: 13, color: FoaColors.of(context).muted)),
        const SizedBox(height: 2),
        Text(AboutInfo.tagline,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: FoaColors.of(context).muted)),
      ],
    );
  }

  // ---------------- 作者 ----------------

  Widget _authorCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('作者',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            _row(context, Icons.person_outline, '作者', AboutInfo.author),
            const SizedBox(height: 8),
            _copyRow(
              context: context,
              icon: Icons.mail_outline,
              label: '联系方式',
              value: AboutInfo.email,
              tooltip: '复制邮箱',
            ),
            const SizedBox(height: 8),
            // alpha.70：用户要求展示作者仓库。
            // 用 _copyRow 而非 _row：地址是要粘到浏览器里的，
            // 长按选中的体验远不如一键复制。
            _copyRow(
              context: context,
              icon: Icons.code,
              label: 'GitHub',
              value: AboutInfo.authorRepo,
              tooltip: '复制仓库地址',
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 这个 App 做什么 ----------------

  Widget _whatItDoesCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('这是什么',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '在一台 Android 手机里跑一套完整的 Flutter 开发环境：'
              '内置 Debian 容器（proot 免 root）+ 本地 JDK / Android SDK / '
              'Flutter SDK，可以创建工程 → 编辑代码 → Web 预览热重载 → '
              '构建 APK → 安装，全程不碰电脑。',
              style: TextStyle(
                  fontSize: 12, height: 1.55, color: FoaColors.of(context).muted),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 第三方组件（本页重点） ----------------

  Widget _thirdPartyCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('引用的其它项目',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${AboutInfo.components.length} 项',
                    style: TextStyle(
                        fontSize: 11, color: FoaColors.of(context).muted)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '以下组件不随本 App 的代码一起编译，而是在容器内或运行时分发使用。'
              '列出它们是尊重上游劳动，也让你清楚设备上多了什么。',
              style: TextStyle(
                  fontSize: 11.5, height: 1.5, color: FoaColors.of(context).muted),
            ),
            const SizedBox(height: 10),
            for (final c in AboutInfo.components) ...[
              _componentTile(context, c),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  Widget _componentTile(BuildContext context, AboutComponent c) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(c.name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              _licenseChip(c.license),
            ],
          ),
          if (c.version.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('版本 ${c.version}',
                style: TextStyle(
                    fontSize: 11, color: FoaColors.of(context).muted)),
          ],
          const SizedBox(height: 6),
          Text(c.usage,
              style: TextStyle(
                  fontSize: 11.5, height: 1.5, color: FoaColors.of(context).muted)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  c.repoUrl,
                  maxLines: 1,
                  style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Color(0xFF4C8DFF)),
                ),
              ),
              IconButton(
                tooltip: '复制仓库地址',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 15),
                onPressed: () => _copy(c.repoUrl, '仓库地址'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 许可徽章：GPL 系用琥珀色提示"有分发义务"，宽松许可用中性色。
  Widget _licenseChip(String license) {
    final l = license.toUpperCase();
    final copyleft =
        l.contains('GPL') || l.contains('PROPRIETARY') || l.contains('专有');
    final color = copyleft
        ? const Color(0xFFFFA000)
        : const Color(0xFF3DDC84);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(license,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w600, color: color)),
    );
  }

  // ---------------- 许可说明 ----------------

  Widget _licenseNoteCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('许可与合规',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              '· proot（GPL-2.0）以**独立进程**方式调用，与本项目代码不构成'
              '静态/动态链接；\n'
              '· 容器内运行的构建工具（aapt2、cloudflared 等）同样只在'
              '容器里被 execve，不进 App 进程；\n'
              '· Debian rootfs 内各软件包的许可见 /usr/share/doc/*/copyright；\n'
              '· 完整清单见仓库根目录 THIRD-PARTY-NOTICES.md。',
              style: TextStyle(
                  fontSize: 11.5, height: 1.6, color: FoaColors.of(context).muted),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 小组件 ----------------

  Widget _row(BuildContext context, IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: FoaColors.of(context).muted),
        const SizedBox(width: 8),
        Text('$label：',
            style: TextStyle(fontSize: 12, color: FoaColors.of(context).muted)),
        Expanded(
          child: SelectableText(value,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _copyRow({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String value,
    required String tooltip,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: FoaColors.of(context).muted),
        const SizedBox(width: 8),
        Text('$label：',
            style: TextStyle(fontSize: 12, color: FoaColors.of(context).muted)),
        Expanded(
          child: SelectableText(value,
              style: const TextStyle(fontSize: 13)),
        ),
        IconButton(
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy, size: 15),
          onPressed: () => _copy(value, label),
        ),
      ],
    );
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
  }
}
