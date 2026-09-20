/// 「关于」页的数据源（alpha.61 起更名为 FOAIDE）。
///
/// 抽成纯数据类而不是把文案写进 Widget，是为了**可测**：
/// 版本号写错过（旧卡片停在 alpha.26）、仓库地址抄错、许可漏标——
/// 这些都是"不写测试就一定会复发"的类型。
library;

/// 作者信息与第三方组件清单。
class AboutInfo {
  const AboutInfo._();

  /// 应用显示名（与 AndroidManifest 的 android:label 保持一致）。
  static const String appName = 'FOAIDE';

  /// 版本号。**必须与 pubspec.yaml 的 version 同步**（有单测守住）。
  static const String version = 'v0.1.0-alpha.63+63';

  /// 一句话说明（关于页副标题）。
  static const String tagline = '在 Android 上原生构建 Flutter 应用';

  /// 作者。
  static const String author = 'haothtrteen';

  /// 联系方式（用户明确要求展示）。
  static const String email = '2557976190@qq.com';

  /// 引用的第三方项目。
  ///
  /// ⚠️ 维护约定：新增/更换组件时同步更新本表 **与**
  /// `THIRD-PARTY-NOTICES.md`（单测会断言两边都在，防止只改一处）。
  static const List<AboutComponent> components = <AboutComponent>[
    AboutComponent(
      name: 'proot',
      version: 'Termux 分支构建',
      license: 'GPL-2.0',
      repoUrl: 'https://github.com/termux/proot',
      usage: '免 root 提供 Linux 容器环境（ptrace 路径翻译）。'
          '以独立进程调用，不链接进 App 进程。',
    ),
    AboutComponent(
      name: 'Debian rootfs (minbase)',
      version: 'bookworm',
      license: 'DFSG / 各包自有',
      repoUrl: 'https://www.debian.org/distrib/',
      usage: '容器内的根文件系统（aarch64），首次运行解压。'
          '构建工具链（JDK / Android SDK / Flutter SDK）都装在里面。',
    ),
    AboutComponent(
      name: 'QEMU (user-static)',
      version: '容器内 apt 安装',
      license: 'GPL-2.0',
      repoUrl: 'https://www.qemu.org/',
      usage: '把 x86-64 的构建工具（aapt2 / D8 / R8 等）翻译到 arm64 执行。'
          '构建耗时的大头就来自这层指令翻译。',
    ),
    AboutComponent(
      name: 'Android build-tools (arm64)',
      version: 'platform-tools-36.0.0',
      license: 'MIT',
      repoUrl: 'https://github.com/Commit451/android-arm-build-tools',
      usage: '运行时下载 arm64 版 aapt2 / aidl / zipalign / split-select，'
          '省掉 QEMU 翻译。下载后做 SHA-256 校验。',
    ),
    AboutComponent(
      name: 'cloudflared',
      version: '2026.9.1',
      license: 'Apache-2.0',
      repoUrl: 'https://github.com/cloudflare/cloudflared',
      usage: '「AI 接管」用它将容器内的 MCP 服务映射到公网地址，'
          '让远程 AI 客户端接入。仅在开启接管时下载，不随 APK 分发。',
    ),
    AboutComponent(
      name: 'gen_snapshot (arm64 移植)',
      version: '用户自备',
      license: 'BSD-3-Clause',
      repoUrl: 'https://github.com/ImL1s/termux-flutter-wsl',
      usage: 'AOT 编译产物生成器。不自动下载，由用户本地导入到容器 '
          '/opt/foa-native/，用于原生 arm64 构建路线。',
    ),
    AboutComponent(
      name: 'Flutter SDK',
      version: '3.47.4',
      license: 'BSD-3-Clause',
      repoUrl: 'https://github.com/flutter/flutter',
      usage: '本应用自身的开发框架（Flutter SDK 及 Dart 运行时），'
          '同时也会下载进容器供你构建自己的项目。',
    ),
    AboutComponent(
      name: 'proroot',
      version: 'v1.2.8',
      license: 'Proprietary',
      repoUrl: 'https://github.com/coderredlab/proroot',
      usage: '可选的容器层加速：用 LD_PRELOAD + 二进制补丁替代 proot 的 '
          'ptrace 路径翻译，省掉每次系统调用的两次上下文切换。'
          '**默认关闭**，需用户在工具链页自行导入二进制并跑冒烟测试后启用；'
          '本项目不代为分发（上游许可禁止分发修改过的二进制）。'
          '注意它只优化容器层，对 QEMU 指令翻译与 dart/gradle 计算无改善。',
    ),
  ];
}

/// 一个第三方组件的展示信息。
class AboutComponent {
  /// 组件名。
  final String name;

  /// 版本（无固定版本时可写"用户自备"等说明）。
  final String version;

  /// 许可证简称。
  final String license;

  /// 上游仓库/主页地址。
  final String repoUrl;

  /// 在本项目中的用途（一句话，说人话）。
  final String usage;

  const AboutComponent({
    required this.name,
    required this.version,
    required this.license,
    required this.repoUrl,
    required this.usage,
  });
}
