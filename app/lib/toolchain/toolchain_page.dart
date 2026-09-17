import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'jdk_installer.dart';
import 'local_install_picker.dart';
import 'qemu_compat.dart';
import 'sdk_downloader.dart';
import 'sdk_installer.dart';

/// Step 3 工具链页：JDK 17 / Android SDK / Flutter SDK(官方 x64 · QEMU 转发) /
/// x64 兼容层(QEMU) / 构建镜像配置。
///
/// 状态机（各卡片独立）：
/// - JDK：idle → probing → downloading(进度) → extracting → validating
///   → installed；任意阶段失败 → error（可重试）；网络全挂可走本地导入。
/// - Android SDK / Flutter SDK：idle → apt → probing → downloading(进度)
///   → extracting → validating → installed；失败 → error（分片续传保留）。
/// - 构建镜像配置：idle → env → init-gradle → wrapper → probing
///   → downloading(Gradle 224MB 预下载) → installed；失败 → error。
/// - x64 兼容层(QEMU)：idle → apt → engine → sdk → validating
///   → installed；失败 → error（apt/预下载阶段为不确定进度条，无取消）。
class ToolchainPage extends StatefulWidget {
  const ToolchainPage({super.key});

  @override
  State<ToolchainPage> createState() => _ToolchainPageState();
}

enum JdkPhase {
  idle,
  probing,
  downloading,
  importing, // 本地文件导入 + 校验
  extracting,
  validating,
  installed,
  uninstalling,
  error,
}

/// Android SDK / Flutter SDK 共用阶段。
enum SdkPhase {
  idle,
  apt, // 容器内 apt 装 xz-utils/unzip
  probing,
  downloading,
  importing, // 本地文件导入 + 校验
  extracting,
  validating,
  installed,
  error,
}

/// 构建镜像配置阶段。
enum MirrorPhase {
  idle,
  env,
  initGradle,
  wrapper,
  probing,
  downloading,
  installed,
  error,
}

/// x64 兼容层(QEMU)阶段。
enum QemuPhase {
  idle,
  apt, // 容器内 apt 装 qemu-user + x86_64 多架构运行库
  engine, // 引擎产物预下载 + linux-arm64 转发层
  sdk, // SDK 工具接管 + AGP aapt2 指向
  validating, // 分步冒烟验证
  installed,
  uninstalling,
  error,
}

class _ToolchainPageState extends State<ToolchainPage> {
  final ProotBridge _bridge = ProotBridge();

  // ---- JDK（原有逻辑）----
  JdkPhase _phase = JdkPhase.idle;
  DownloadProgress? _progress;
  final Set<String> _mirrors = {};
  String _version = '';
  String _error = '';
  EnvInfo? _env;
  DownloadCancelToken? _token;
  bool _verifying = false;

  // ---- Android SDK ----
  SdkPhase _asdkPhase = SdkPhase.idle;
  DownloadProgress? _asdkProgress;
  final Set<String> _asdkMirrors = {};
  String _asdkInfo = '';
  String _asdkError = '';
  DownloadCancelToken? _asdkToken;
  bool _asdkVerifying = false;

  // ---- Flutter SDK ----
  SdkPhase _flPhase = SdkPhase.idle;
  DownloadProgress? _flProgress;
  final Set<String> _flMirrors = {};
  String _flInfo = '';
  String _flError = '';
  DownloadCancelToken? _flToken;
  bool _flVerifying = false;

  // ---- 构建镜像配置 ----
  MirrorPhase _mirrorPhase = MirrorPhase.idle;
  DownloadProgress? _mirrorProgress;
  String _mirrorInfo = '';
  String _mirrorError = '';
  DownloadCancelToken? _mirrorToken;

  // ---- x64 兼容层(QEMU) ----
  QemuPhase _qemuPhase = QemuPhase.idle;
  String _qemuInfo = '';
  String _qemuError = '';
  bool _qemuVerifying = false;

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  Future<void> _refreshAll() async {
    try {
      final env = await _bridge.envInfo();
      final v = env.rootfsInstalled ? await JdkInstaller.verify(_bridge) : null;
      final a = env.rootfsInstalled
          ? await AndroidSdkInstaller.verify(_bridge)
          : null;
      final f = env.rootfsInstalled
          ? await FlutterSdkInstaller.verify(_bridge)
          : null;
      final m = env.rootfsInstalled
          ? await MirrorConfigurator.verify(_bridge, env)
          : null;
      final q = env.rootfsInstalled ? await QemuCompat.verify(_bridge) : null;
      if (!mounted) return;
      setState(() {
        _env = env;
        _phase = v == null ? JdkPhase.idle : JdkPhase.installed;
        _version = v ?? '';
        _asdkPhase = a == null ? SdkPhase.idle : SdkPhase.installed;
        _asdkInfo = a ?? '';
        _flPhase = f == null ? SdkPhase.idle : SdkPhase.installed;
        _flInfo = f ?? '';
        _mirrorPhase = m == null ? MirrorPhase.idle : MirrorPhase.installed;
        _mirrorInfo = m ?? '';
        _qemuPhase = q == null ? QemuPhase.idle : QemuPhase.installed;
        _qemuInfo = q ?? '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = JdkPhase.error;
        _error = '检测失败：$e';
      });
    }
  }

  // ============================ JDK ============================

  Future<void> _onVerify() async {
    setState(() => _verifying = true);
    try {
      final env = await _bridge.envInfo();
      final v = env.rootfsInstalled ? await JdkInstaller.verify(_bridge) : null;
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _env = env;
        _phase = v == null ? JdkPhase.idle : JdkPhase.installed;
        _version = v ?? '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            v == null
                ? '验证失败：/opt/jdk 中未找到 java / javac'
                : '验证通过：${v.replaceAll('\n', ' · ')}',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _phase = JdkPhase.error;
        _error = '检测失败：$e';
      });
    }
  }

  Future<void> _install() async {
    setState(() {
      _phase = JdkPhase.probing;
      _progress = null;
      _error = '';
      _mirrors.clear();
    });
    _token = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final ver = await JdkInstaller.install(
        _bridge,
        env,
        token: _token,
        onPhase: (p) {
          if (!mounted) return;
          setState(() {
            _phase = switch (p) {
              'probing' => JdkPhase.probing,
              'downloading' => JdkPhase.downloading,
              'extracting' => JdkPhase.extracting,
              'validating' => JdkPhase.validating,
              _ => _phase,
            };
          });
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
        onMirrorUsed: (m) {
          if (!mounted) return;
          setState(() => _mirrors.add(m.name));
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = JdkPhase.installed;
        _version = ver;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = JdkPhase.error;
        _error = e.toString();
      });
    }
  }

  Future<void> _cancel() async {
    _token?.cancel();
    setState(() => _phase = JdkPhase.idle);
  }

  Future<void> _installFromLocal() async {
    final picked = await LocalInstallPicker.pickInstallFile();
    if (!mounted) return;
    if (!picked.ok || picked.path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(picked.error ?? '未选择文件')),
      );
      return;
    }
    setState(() {
      _phase = JdkPhase.importing;
      _progress = null;
      _error = '';
      _mirrors.clear();
    });
    _token = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final ver = await JdkInstaller.installFromLocalFile(
        _bridge,
        env,
        picked.path!,
        token: _token,
        onPhase: (p) {
          if (!mounted) return;
          setState(() {
            _phase = switch (p) {
              'importing' => JdkPhase.importing,
              'extracting' => JdkPhase.extracting,
              'validating' => JdkPhase.validating,
              _ => _phase,
            };
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = JdkPhase.installed;
        _version = ver;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = JdkPhase.error;
        _error = e.toString();
      });
    }
  }

  Future<void> _uninstall() async {
    final ok = await _confirm('卸载 JDK', '将删除 /opt/jdk（约 300MB），确定？');
    if (!ok) return;
    setState(() => _phase = JdkPhase.uninstalling);
    await JdkInstaller.uninstall(_bridge);
    await _refreshAll();
  }

  // ============================ Android SDK ============================

  SdkPhase _sdkPhaseFrom(String p) => switch (p) {
        'apt' => SdkPhase.apt,
        'probing' => SdkPhase.probing,
        'downloading' => SdkPhase.downloading,
        'importing' => SdkPhase.importing,
        'extracting' => SdkPhase.extracting,
        'validating' => SdkPhase.validating,
        _ => SdkPhase.idle,
      };

  Future<void> _asdkInstall() async {
    setState(() {
      _asdkPhase = SdkPhase.probing;
      _asdkProgress = null;
      _asdkError = '';
      _asdkMirrors.clear();
    });
    _asdkToken = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final v = await AndroidSdkInstaller.install(
        _bridge,
        env,
        token: _asdkToken,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _asdkPhase = _sdkPhaseFrom(p));
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _asdkProgress = p);
        },
        onMirrorUsed: (m) {
          if (!mounted) return;
          setState(() => _asdkMirrors.add(m.name));
        },
      );
      if (!mounted) return;
      setState(() {
        _asdkPhase = SdkPhase.installed;
        _asdkInfo = v;
      });
      // QEMU 兼容层在位时接管 aapt2/adb/zipalign（幂等，未装则跳过）。
      await QemuCompat.wrapSdkIfReady(_bridge, env);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _asdkPhase = SdkPhase.error;
        _asdkError = e.toString();
      });
    }
  }

  Future<void> _asdkVerify() async {
    setState(() => _asdkVerifying = true);
    try {
      final v = await AndroidSdkInstaller.verify(_bridge);
      if (!mounted) return;
      setState(() {
        _asdkVerifying = false;
        _asdkPhase = v == null ? SdkPhase.idle : SdkPhase.installed;
        _asdkInfo = v ?? '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            v == null
                ? '验证失败：Android SDK 关键组件缺失'
                : '验证通过：$v',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _asdkVerifying = false;
        _asdkPhase = SdkPhase.error;
        _asdkError = '检测失败：$e';
      });
    }
  }

  Future<void> _asdkCancel() async {
    _asdkToken?.cancel();
    setState(() => _asdkPhase = SdkPhase.idle);
  }

  Future<void> _asdkInstallFromLocal() async {
    final picked = await LocalInstallPicker.pickInstallFile();
    if (!mounted) return;
    if (!picked.ok || picked.path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(picked.error ?? '未选择文件')),
      );
      return;
    }
    setState(() {
      _asdkPhase = SdkPhase.importing;
      _asdkProgress = null;
      _asdkError = '';
      _asdkMirrors.clear();
    });
    _asdkToken = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final v = await AndroidSdkInstaller.installFromLocalFile(
        _bridge,
        env,
        picked.path!,
        token: _asdkToken,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _asdkPhase = _sdkPhaseFrom(p));
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _asdkProgress = p);
        },
        onMirrorUsed: (m) {
          if (!mounted) return;
          setState(() => _asdkMirrors.add(m.name));
        },
      );
      if (!mounted) return;
      setState(() {
        _asdkPhase = SdkPhase.installed;
        _asdkInfo = v;
      });
      // QEMU 兼容层在位时接管 aapt2/adb/zipalign（幂等，未装则跳过）。
      await QemuCompat.wrapSdkIfReady(_bridge, env);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _asdkPhase = SdkPhase.error;
        _asdkError = e.toString();
      });
    }
  }

  Future<void> _asdkUninstall() async {
    final ok = await _confirm(
        '卸载 Android SDK', '将删除 /opt/android-sdk（约 1.3GB，含解压后），确定？');
    if (!ok) return;
    await AndroidSdkInstaller.uninstall(_bridge);
    await _refreshAll();
  }

  // ============================ Flutter SDK ============================

  Future<void> _flInstall() async {
    setState(() {
      _flPhase = SdkPhase.probing;
      _flProgress = null;
      _flError = '';
      _flMirrors.clear();
    });
    _flToken = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final v = await FlutterSdkInstaller.install(
        _bridge,
        env,
        token: _flToken,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _flPhase = _sdkPhaseFrom(p));
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _flProgress = p);
        },
        onMirrorUsed: (m) {
          if (!mounted) return;
          setState(() => _flMirrors.add(m.name));
        },
      );
      if (!mounted) return;
      setState(() {
        _flPhase = SdkPhase.installed;
        _flInfo = v;
      });
      // QEMU 兼容层在位时预下载引擎产物并生成 linux-arm64 转发层（幂等）。
      await QemuCompat.syncEngineIfReady(_bridge);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _flPhase = SdkPhase.error;
        _flError = e.toString();
      });
    }
  }

  Future<void> _flVerify() async {
    setState(() => _flVerifying = true);
    try {
      final v = await FlutterSdkInstaller.verify(_bridge);
      if (!mounted) return;
      setState(() {
        _flVerifying = false;
        _flPhase = v == null ? SdkPhase.idle : SdkPhase.installed;
        _flInfo = v ?? '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            v == null
                ? '验证失败：/opt/flutter 缺失或 dart-sdk 版本不符'
                : '验证通过：$v',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _flVerifying = false;
        _flPhase = SdkPhase.error;
        _flError = '检测失败：$e';
      });
    }
  }

  Future<void> _flCancel() async {
    _flToken?.cancel();
    setState(() => _flPhase = SdkPhase.idle);
  }

  Future<void> _flInstallFromLocal() async {
    final picked = await LocalInstallPicker.pickInstallFile();
    if (!mounted) return;
    if (!picked.ok || picked.path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(picked.error ?? '未选择文件')),
      );
      return;
    }
    setState(() {
      _flPhase = SdkPhase.importing;
      _flProgress = null;
      _flError = '';
      _flMirrors.clear();
    });
    _flToken = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final v = await FlutterSdkInstaller.installFromLocalFile(
        _bridge,
        env,
        picked.path!,
        token: _flToken,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _flPhase = _sdkPhaseFrom(p));
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _flProgress = p);
        },
        onMirrorUsed: (m) {
          if (!mounted) return;
          setState(() => _flMirrors.add(m.name));
        },
      );
      if (!mounted) return;
      setState(() {
        _flPhase = SdkPhase.installed;
        _flInfo = v;
      });
      // QEMU 兼容层在位时预下载引擎产物并生成 linux-arm64 转发层（幂等）。
      await QemuCompat.syncEngineIfReady(_bridge);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _flPhase = SdkPhase.error;
        _flError = e.toString();
      });
    }
  }

  Future<void> _flUninstall() async {
    final ok = await _confirm(
        '卸载 Flutter SDK', '将删除 /opt/flutter（约 3GB，含解压后），确定？');
    if (!ok) return;
    await FlutterSdkInstaller.uninstall(_bridge);
    await _refreshAll();
  }

  // ============================ x64 兼容层(QEMU) ============================

  QemuPhase _qemuPhaseFrom(String p) => switch (p) {
        'apt' => QemuPhase.apt,
        'engine' => QemuPhase.engine,
        'sdk' => QemuPhase.sdk,
        'validating' => QemuPhase.validating,
        _ => QemuPhase.idle,
      };

  Future<void> _qemuApply() async {
    setState(() {
      _qemuPhase = QemuPhase.apt;
      _qemuError = '';
    });
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final v = await QemuCompat.apply(
        _bridge,
        env,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _qemuPhase = _qemuPhaseFrom(p));
        },
      );
      if (!mounted) return;
      setState(() {
        _qemuPhase = QemuPhase.installed;
        _qemuInfo = v;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('x64 兼容层已应用：$v'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qemuPhase = QemuPhase.error;
        _qemuError = e.toString();
      });
    }
  }

  Future<void> _qemuVerify() async {
    setState(() => _qemuVerifying = true);
    try {
      final v = await QemuCompat.verify(_bridge);
      if (!mounted) return;
      setState(() {
        _qemuVerifying = false;
        _qemuPhase = v == null ? QemuPhase.idle : QemuPhase.installed;
        _qemuInfo = v ?? '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            v == null ? '未检测到 x64 兼容层' : '兼容层有效：$v',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qemuVerifying = false;
        _qemuPhase = QemuPhase.error;
        _qemuError = '检测失败：$e';
      });
    }
  }

  Future<void> _qemuUninstall() async {
    final ok = await _confirm(
        '卸载 x64 兼容层', '将移除 qemu 转发脚本、x86_64 多架构库并恢复工具原样，确定？');
    if (!ok) return;
    setState(() => _qemuPhase = QemuPhase.uninstalling);
    try {
      final env = await _bridge.envInfo();
      if (env.rootfsInstalled) {
        await QemuCompat.uninstall(_bridge, env);
      }
      await _refreshAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qemuPhase = QemuPhase.error;
        _qemuError = e.toString();
      });
    }
  }

  // ============================ 构建镜像配置 ============================

  MirrorPhase _mirrorPhaseFrom(String p) => switch (p) {
        'env' => MirrorPhase.env,
        'init-gradle' => MirrorPhase.initGradle,
        'wrapper' => MirrorPhase.wrapper,
        'probing' => MirrorPhase.probing,
        'downloading' => MirrorPhase.downloading,
        _ => MirrorPhase.idle,
      };

  Future<void> _mirrorApply() async {
    setState(() {
      _mirrorPhase = MirrorPhase.env;
      _mirrorProgress = null;
      _mirrorError = '';
    });
    _mirrorToken = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final v = await MirrorConfigurator.apply(
        _bridge,
        env,
        token: _mirrorToken,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _mirrorPhase = _mirrorPhaseFrom(p));
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _mirrorProgress = p);
        },
        onMirrorUsed: (_) {},
      );
      if (!mounted) return;
      setState(() {
        _mirrorPhase = MirrorPhase.installed;
        _mirrorInfo = v;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('镜像配置完成：$v'), duration: const Duration(seconds: 4)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mirrorPhase = MirrorPhase.error;
        _mirrorError = e.toString();
      });
    }
  }

  Future<void> _mirrorVerify() async {
    try {
      final env = await _bridge.envInfo();
      final m = env.rootfsInstalled
          ? await MirrorConfigurator.verify(_bridge, env)
          : null;
      if (!mounted) return;
      setState(() {
        _mirrorPhase = m == null ? MirrorPhase.idle : MirrorPhase.installed;
        _mirrorInfo = m ?? '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(m == null ? '未检测到镜像配置' : '配置有效：$m'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mirrorPhase = MirrorPhase.error;
        _mirrorError = '检测失败：$e';
      });
    }
  }

  Future<void> _mirrorCancel() async {
    _mirrorToken?.cancel();
    setState(() => _mirrorPhase = MirrorPhase.idle);
  }

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final rootfsReady = _env?.rootfsInstalled == true;
    return Scaffold(
      appBar: AppBar(title: const Text('工具链')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _JdkCard(
            phase: _phase,
            progress: _progress,
            mirrorName: _mirrors.join(' + '),
            version: _version,
            error: _error,
            env: _env,
            onInstall: _install,
            onCancel: _cancel,
            onUninstall: _uninstall,
            onVerify: _onVerify,
            onInstallLocal: _installFromLocal,
            verifying: _verifying,
          ),
          const SizedBox(height: 12),
          _SdkCard(
            title: 'Android SDK',
            icon: Icons.android,
            phase: _asdkPhase,
            progress: _asdkProgress,
            mirrorName: _asdkMirrors.join(' + '),
            info: _asdkInfo,
            error: _asdkError,
            sizeLabel: '约 ${(AndroidSdkInstaller.totalSize / 1048576).toStringAsFixed(0)} MB · 4 个组件',
            desc: 'platform-tools r37 + platforms;android-36 + build-tools 36.0.0 '
                '+ cmdline-tools（与 Flutter 3.47.4 的 compileSdk 36 对齐）。\n'
                '国内源优先（腾讯云）探测取最快，4 线程分段并发 + SHA-1 校验；'
                '解压到容器内 /opt/android-sdk 并预置许可。',
            verifying: _asdkVerifying,
            rootfsReady: rootfsReady,
            onInstall: _asdkInstall,
            onVerify: _asdkVerify,
            onCancel: _asdkCancel,
            onUninstall: _asdkUninstall,
            onInstallLocal: _asdkInstallFromLocal,
          ),
          const SizedBox(height: 12),
          _SdkCard(
            title: 'Flutter SDK（官方 x64 · QEMU 转发）',
            icon: Icons.bolt,
            phase: _flPhase,
            progress: _flProgress,
            mirrorName: _flMirrors.join(' + '),
            info: _flInfo,
            error: _flError,
            sizeLabel: '约 1575 MB · 官方 tarball（x64 工具链由 QEMU 转发）',
            desc: 'Flutter ${FlutterSdkInstaller.version} 官方仅发布 x64 Linux 构建，'
                '其 flutter_tools.snapshot 为 x64 快照，aarch64 直跑报 '
                '"Snapshot not compatible"（真机已复现）。\n'
                '本方案保留官方 x64 dart-sdk 原样，由「x64 兼容层(QEMU)」统一转发 '
                'dart/gen_snapshot/aapt2 等 x64 二进制后即可在 aarch64 上执行 '
                'flutter build apk。\n'
                '建议先应用兼容层再安装本 SDK；装反了可点兼容层「重新应用」自动补上。'
                '国内源（flutter-io.cn 官方中国镜像）优先；解压到容器内 /opt/flutter。',
            verifying: _flVerifying,
            rootfsReady: rootfsReady,
            onInstall: _flInstall,
            onVerify: _flVerify,
            onCancel: _flCancel,
            onUninstall: _flUninstall,
            onInstallLocal: _flInstallFromLocal,
          ),
          const SizedBox(height: 12),
          _QemuCard(
            phase: _qemuPhase,
            info: _qemuInfo,
            error: _qemuError,
            rootfsReady: rootfsReady,
            verifying: _qemuVerifying,
            onApply: _qemuApply,
            onVerify: _qemuVerify,
            onUninstall: _qemuUninstall,
          ),
          const SizedBox(height: 12),
          _MirrorCard(
            phase: _mirrorPhase,
            progress: _mirrorProgress,
            info: _mirrorInfo,
            error: _mirrorError,
            rootfsReady: rootfsReady,
            onApply: _mirrorApply,
            onVerify: _mirrorVerify,
            onCancel: _mirrorCancel,
          ),
        ],
      ),
    );
  }
}

// ============================ JDK 卡片 ============================

class _JdkCard extends StatelessWidget {
  final JdkPhase phase;
  final DownloadProgress? progress;
  final String mirrorName;
  final String version;
  final String error;
  final EnvInfo? env;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  final VoidCallback onUninstall;
  final VoidCallback onVerify;
  final VoidCallback onInstallLocal;
  final bool verifying;

  const _JdkCard({
    required this.phase,
    required this.progress,
    required this.mirrorName,
    required this.version,
    required this.error,
    required this.env,
    required this.onInstall,
    required this.onCancel,
    required this.onUninstall,
    required this.onVerify,
    required this.onInstallLocal,
    required this.verifying,
  });

  @override
  Widget build(BuildContext context) {
    final busy = phase == JdkPhase.probing ||
        phase == JdkPhase.downloading ||
        phase == JdkPhase.importing ||
        phase == JdkPhase.extracting ||
        phase == JdkPhase.validating ||
        phase == JdkPhase.uninstalling;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (phase) {
                    JdkPhase.installed => Icons.check_circle,
                    JdkPhase.error => Icons.error_outline,
                    _ => Icons.build_circle_outlined,
                  },
                  color: switch (phase) {
                    JdkPhase.installed => const Color(0xFF3DDC84),
                    JdkPhase.error => const Color(0xFFFF7A7A),
                    _ => Colors.orangeAccent,
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  switch (phase) {
                    JdkPhase.installed => 'JDK 已安装',
                    JdkPhase.error => '安装失败',
                    JdkPhase.probing => '正在探测镜像源…',
                    JdkPhase.downloading => '正在下载 JDK…',
                    JdkPhase.importing => '正在导入本地文件…',
                    JdkPhase.extracting => '正在解压到 /opt/jdk…',
                    JdkPhase.validating => '正在验证 java / javac…',
                    JdkPhase.uninstalling => '正在卸载…',
                    JdkPhase.idle => 'JDK 未安装',
                  },
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(height: 20),
            _kv('版本', phase == JdkPhase.installed ? version : JdkInstaller.version),
            _kv('镜像', mirrorName.isEmpty ? '待选源' : mirrorName),
            _kv('大小', '${(JdkInstaller.size / 1048576).toStringAsFixed(0)} MB'),
            if (phase == JdkPhase.downloading && progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress!.fraction,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 6),
              Text(
                '${(progress!.received / 1048576).toStringAsFixed(1)} / '
                '${(progress!.total / 1048576).toStringAsFixed(1)} MB · '
                '${(progress!.speed / 1048576).toStringAsFixed(1)} MB/s',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (verifying) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(
                minHeight: 6,
                borderRadius: BorderRadius.all(Radius.circular(3)),
              ),
              const SizedBox(height: 6),
              const Text('正在重新验证 java / javac…',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            if (phase == JdkPhase.error && error.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(error,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                if (phase == JdkPhase.installed) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: verifying ? null : onVerify,
                      icon: const Icon(Icons.verified_outlined, size: 18),
                      label: const Text('重新验证'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy || verifying ? null : onUninstall,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('卸载'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF7A7A),
                      ),
                    ),
                  ),
                ] else if (busy) ...[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('取消'),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: env?.rootfsInstalled != true ? null : onInstall,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('下载并安装'),
                    ),
                  ),
                ],
              ],
            ),
            if (!busy && phase != JdkPhase.installed) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed:
                      env?.rootfsInstalled != true ? null : onInstallLocal,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('从本地存储选择安装'),
                ),
              ),
            ],
            if (env?.rootfsInstalled != true) ...[
              const SizedBox(height: 8),
              const Text('请先在主页初始化 rootfs 环境',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(k,
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13)),
            ),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'monospace'))),
          ],
        ),
      );
}

// ============================ Android / Flutter 共用卡片 ============================

class _SdkCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final SdkPhase phase;
  final DownloadProgress? progress;
  final String mirrorName;
  final String info;
  final String error;
  final String sizeLabel;
  final String desc;
  final bool verifying;
  final bool rootfsReady;
  final VoidCallback onInstall;
  final VoidCallback onVerify;
  final VoidCallback onCancel;
  final VoidCallback onUninstall;
  final VoidCallback onInstallLocal;

  const _SdkCard({
    required this.title,
    required this.icon,
    required this.phase,
    required this.progress,
    required this.mirrorName,
    required this.info,
    required this.error,
    required this.sizeLabel,
    required this.desc,
    required this.verifying,
    required this.rootfsReady,
    required this.onInstall,
    required this.onVerify,
    required this.onCancel,
    required this.onUninstall,
    required this.onInstallLocal,
  });

  String get _statusLabel => switch (phase) {
        SdkPhase.installed => '$title 已安装',
        SdkPhase.error => '安装失败',
        SdkPhase.apt => '安装 apt 工具（xz-utils/unzip）…',
        SdkPhase.probing => '正在探测镜像源…',
        SdkPhase.downloading => '正在下载…',
        SdkPhase.importing => '正在导入本地文件…',
        SdkPhase.extracting => '正在解压…',
        SdkPhase.validating => '正在验证…',
        SdkPhase.idle => '$title 未安装',
      };

  @override
  Widget build(BuildContext context) {
    final busy = phase == SdkPhase.apt ||
        phase == SdkPhase.probing ||
        phase == SdkPhase.downloading ||
        phase == SdkPhase.importing ||
        phase == SdkPhase.extracting ||
        phase == SdkPhase.validating;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (phase) {
                    SdkPhase.installed => Icons.check_circle,
                    SdkPhase.error => Icons.error_outline,
                    _ => Icons.downloading,
                  },
                  color: switch (phase) {
                    SdkPhase.installed => const Color(0xFF3DDC84),
                    SdkPhase.error => const Color(0xFFFF7A7A),
                    _ => Colors.orangeAccent,
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusLabel,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Icon(icon, size: 20, color: Colors.grey.shade500),
              ],
            ),
            const Divider(height: 20),
            _kv('版本', phase == SdkPhase.installed ? info : '待安装'),
            _kv('镜像', mirrorName.isEmpty ? '待选源' : mirrorName),
            _kv('大小', sizeLabel),
            if (phase == SdkPhase.downloading && progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress!.fraction,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 6),
              Text(
                '${(progress!.received / 1048576).toStringAsFixed(1)} / '
                '${(progress!.total / 1048576).toStringAsFixed(1)} MB · '
                '${(progress!.speed / 1048576).toStringAsFixed(1)} MB/s',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (verifying) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(
                minHeight: 6,
                borderRadius: BorderRadius.all(Radius.circular(3)),
              ),
              const SizedBox(height: 6),
              const Text('正在重新验证…',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            if (phase == SdkPhase.error && error.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(error,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
            const SizedBox(height: 12),
            Text(desc,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            const SizedBox(height: 16),
            Row(
              children: [
                if (phase == SdkPhase.installed) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: verifying ? null : onVerify,
                      icon: const Icon(Icons.verified_outlined, size: 18),
                      label: const Text('重新验证'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy || verifying ? null : onUninstall,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('卸载'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF7A7A),
                      ),
                    ),
                  ),
                ] else if (busy) ...[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('取消'),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: rootfsReady ? onInstall : null,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('下载并安装'),
                    ),
                  ),
                ],
              ],
            ),
            if (!busy && phase != SdkPhase.installed) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: rootfsReady ? onInstallLocal : null,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('从本地存储选择安装'),
                ),
              ),
            ],
            if (!rootfsReady) ...[
              const SizedBox(height: 8),
              const Text('请先在主页初始化 rootfs 环境',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(k,
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13)),
            ),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 13, fontFamily: 'monospace'))),
          ],
        ),
      );
}

// ============================ 构建镜像配置卡片 ============================

class _MirrorCard extends StatelessWidget {
  final MirrorPhase phase;
  final DownloadProgress? progress;
  final String info;
  final String error;
  final bool rootfsReady;
  final VoidCallback onApply;
  final VoidCallback onVerify;
  final VoidCallback onCancel;

  const _MirrorCard({
    required this.phase,
    required this.progress,
    required this.info,
    required this.error,
    required this.rootfsReady,
    required this.onApply,
    required this.onVerify,
    required this.onCancel,
  });

  String get _statusLabel => switch (phase) {
        MirrorPhase.installed => '构建镜像已配置',
        MirrorPhase.error => '配置失败',
        MirrorPhase.env => '写入环境变量…',
        MirrorPhase.initGradle => '写入 init.gradle…',
        MirrorPhase.wrapper => '改写项目 wrapper 镜像…',
        MirrorPhase.probing => '探测 Gradle 镜像…',
        MirrorPhase.downloading => '预下载 Gradle…',
        MirrorPhase.idle => '构建镜像未配置',
      };

  @override
  Widget build(BuildContext context) {
    final busy = phase == MirrorPhase.env ||
        phase == MirrorPhase.initGradle ||
        phase == MirrorPhase.wrapper ||
        phase == MirrorPhase.probing ||
        phase == MirrorPhase.downloading;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (phase) {
                    MirrorPhase.installed => Icons.check_circle,
                    MirrorPhase.error => Icons.error_outline,
                    _ => Icons.settings_ethernet,
                  },
                  color: switch (phase) {
                    MirrorPhase.installed => const Color(0xFF3DDC84),
                    MirrorPhase.error => const Color(0xFFFF7A7A),
                    _ => Colors.orangeAccent,
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusLabel,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            _kv('状态', phase == MirrorPhase.installed ? info : '一键完成以下四步'),
            _kv('环境变量', 'PUB_HOSTED_URL / FLUTTER_STORAGE_BASE_URL / '
                'ANDROID_HOME / JAVA_HOME / GRADLE_USER_HOME'),
            _kv('Maven 镜像', '阿里云 public + google + gradle-plugin（init.gradle 全局生效）'),
            _kv('Gradle 镜像', '腾讯云 ${MirrorConfigurator.gradleUrl.replaceFirst('https://', '')}'),
            if (phase == MirrorPhase.downloading && progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: progress!.fraction,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 6),
              Text(
                '${(progress!.received / 1048576).toStringAsFixed(1)} / '
                '${(progress!.total / 1048576).toStringAsFixed(1)} MB · '
                '${(progress!.speed / 1048576).toStringAsFixed(1)} MB/s',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (phase == MirrorPhase.error && error.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(error,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
            const SizedBox(height: 12),
            Text(
              '把 Flutter/Dart 环境变量写入 /etc/profile.d/foa-env.sh 与 '
              '~/.bashrc（app 内构建命令自动加载）；写入 ~/.gradle/init.gradle '
              '让所有项目走阿里云 Maven；把 /root/projects 下所有项目的 '
              'gradle-wrapper.properties 指向腾讯云镜像；预下载 '
              'Gradle ${MirrorConfigurator.gradleVersion} 分发包（224MB）到 '
              'wrapper 缓存目录，首次构建不再访问国外源。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (phase == MirrorPhase.installed) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onVerify,
                      icon: const Icon(Icons.verified_outlined, size: 18),
                      label: const Text('重新验证'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: busy ? null : onApply,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重新配置'),
                    ),
                  ),
                ] else if (busy) ...[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('取消'),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: rootfsReady ? onApply : null,
                      icon: const Icon(Icons.settings_ethernet, size: 18),
                      label: const Text('一键配置'),
                    ),
                  ),
                ],
              ],
            ),
            if (!rootfsReady) ...[
              const SizedBox(height: 8),
              const Text('请先在主页初始化 rootfs 环境',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 90,
              child: Text(k,
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13)),
            ),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'))),
          ],
        ),
      );
}

// ============================ x64 兼容层(QEMU) 卡片 ============================

class _QemuCard extends StatelessWidget {
  final QemuPhase phase;
  final String info;
  final String error;
  final bool rootfsReady;
  final bool verifying;
  final VoidCallback onApply;
  final VoidCallback onVerify;
  final VoidCallback onUninstall;

  const _QemuCard({
    required this.phase,
    required this.info,
    required this.error,
    required this.rootfsReady,
    required this.verifying,
    required this.onApply,
    required this.onVerify,
    required this.onUninstall,
  });

  String get _statusLabel => switch (phase) {
        QemuPhase.installed => 'x64 兼容层已启用',
        QemuPhase.error => '应用失败',
        QemuPhase.apt => '安装 qemu-user + x86_64 运行库…',
        QemuPhase.engine => '同步引擎产物并生成转发层…',
        QemuPhase.sdk => '接管 SDK 工具 + AGP 指向…',
        QemuPhase.validating => '分步冒烟验证…',
        QemuPhase.uninstalling => '正在卸载…',
        QemuPhase.idle => 'x64 兼容层未启用',
      };

  @override
  Widget build(BuildContext context) {
    final busy = phase == QemuPhase.apt ||
        phase == QemuPhase.engine ||
        phase == QemuPhase.sdk ||
        phase == QemuPhase.validating ||
        phase == QemuPhase.uninstalling;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (phase) {
                    QemuPhase.installed => Icons.check_circle,
                    QemuPhase.error => Icons.error_outline,
                    _ => Icons.memory,
                  },
                  color: switch (phase) {
                    QemuPhase.installed => const Color(0xFF3DDC84),
                    QemuPhase.error => const Color(0xFFFF7A7A),
                    _ => Colors.orangeAccent,
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusLabel,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            _kv('状态', phase == QemuPhase.installed ? info : '一键完成以下三步'),
            _kv('qemu', '/usr/bin/qemu-x86_64-static（apt 安装，静态 aarch64）'),
            _kv('多架构库', 'libc6 / libstdc++6 / libgcc-s1 / zlib1g / libatomic1 (amd64)'),
            _kv('转发层', '引擎 android-*/linux-arm64 → qemu；SDK 工具 .foa-real → qemu'),
            if (busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(
                minHeight: 6,
                borderRadius: BorderRadius.all(Radius.circular(3)),
              ),
              const SizedBox(height: 6),
              const Text('apt 装包 / 引擎产物预下载（约 1GB）/ 工具接管均在容器内进行',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            if (verifying) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(
                minHeight: 6,
                borderRadius: BorderRadius.all(Radius.circular(3)),
              ),
              const SizedBox(height: 6),
              const Text('正在重新验证…',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            if (phase == QemuPhase.error && error.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(error,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
            const SizedBox(height: 12),
            Text(
              '解决 Flutter 官方 SDK 只发布 x86_64 宿主工具（gen_snapshot / '
              'impellerc / aapt2 / zipalign…）导致的 Exec format error：在容器内安装 '
              'qemu-user-static 与 x86_64 多架构运行库，把引擎产物与 SDK 工具替换为 '
              '「qemu 转发脚本」。已按 Flutter issue #189724/#168980 核实，'
              '并内置分步冒烟验证（qemu → 动态链接器 → gen_snapshot --help）。\n'
              '注意：QEMU 为动态翻译，AOT 编译阶段会比原生慢；此层是官方 SDK 在 '
              'aarch64 上完成 flutter build apk 的必要补丁。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (phase == QemuPhase.installed) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: verifying ? null : onVerify,
                      icon: const Icon(Icons.verified_outlined, size: 18),
                      label: const Text('重新验证'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: busy || verifying ? null : onUninstall,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('卸载'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF7A7A),
                      ),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: rootfsReady && !busy ? onApply : null,
                      icon: const Icon(Icons.memory, size: 18),
                      label: Text(busy ? '应用中…' : '一键应用'),
                    ),
                  ),
                ],
              ],
            ),
            if (!rootfsReady) ...[
              const SizedBox(height: 8),
              const Text('请先在主页初始化 rootfs 环境',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 90,
              child: Text(k,
                  style: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13)),
            ),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'))),
          ],
        ),
      );
}
