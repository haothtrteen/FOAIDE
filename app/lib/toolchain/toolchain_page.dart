import 'dart:io';

import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import 'jdk_installer.dart';
import 'local_install_picker.dart';
import 'native_arm64.dart';
import 'qemu_compat.dart';
import 'sdk_downloader.dart';
import 'sdk_installer.dart';
import 'termux_backend.dart';

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
  uninstalling,
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

/// 原生 arm64 阶段。
///
/// 注意：这里只有「体检」一种动作（只读）。原生产物落位属于后续步骤，
/// 体检结果决定要不要走那条路——先看清楚现状再动手。
enum NativePhase {
  idle,
  auditing, // 只读体检
  apt, // 容器内补原生运行库（libstdc++6 等）
  downloading,
  importing, // 本地文件导入 + 校验
  extracting, // 解 tar.xz 到 /opt/foa-native
  deploying, // 落到 build-tools + 冒烟
  installed, // /opt/foa-native 已落位
  uninstalling,
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

  // ---- 原生 arm64 ----
  NativePhase _nativePhase = NativePhase.idle;
  String _nativeInfo = '';
  String _nativeError = '';
  bool _nativeAuditing = false;
  NativeAudit? _nativeAudit;
  DownloadProgress? _nativeProgress;
  final Set<String> _nativeMirrors = {};
  DownloadCancelToken? _nativeToken;

  // ---- 后端切换（proot 容器 / termux 裸原生）----
  BuildBackend? _backend; // null = 未选择（首次进入会弹询问）
  // ---- Termux 裸原生 ----
  TermuxPhase _termuxPhase = TermuxPhase.idle;
  String _termuxInfo = '';
  String _termuxError = '';
  String _termuxSmoke = '';
  bool _termuxBusy = false; // 冒烟/卸载等不可取消操作
  DownloadProgress? _termuxProgress;
  final Set<String> _termuxMirrors = {};
  DownloadCancelToken? _termuxToken;

  @override
  void initState() {
    super.initState();
    _initBackendAndRefresh();
  }

  /// 加载后端偏好 →（未选择时）弹首次询问 → 刷新全部状态。
  Future<void> _initBackendAndRefresh() async {
    try {
      final env = await _bridge.envInfo();
      final b = await BackendPrefs.load(env);
      if (!mounted) return;
      setState(() => _backend = b);
      if (b == null) {
        // 首次进入：问一次用哪个后端（给推荐），不选完不进页面内容
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showBackendChoiceDialog(firstRun: true);
        });
      }
    } catch (_) {}
    await _refreshAll();
  }

  Future<void> _switchBackend(BuildBackend b) async {
    setState(() => _backend = b);
    try {
      final env = await _bridge.envInfo();
      await BackendPrefs.save(env, b);
    } catch (_) {}
  }

  /// 首次进入的「选后端」对话框（含推荐）。
  ///
  /// 推荐逻辑（诚实原则）：proot 容器是**已真机验证**的成熟路线 → 默认推荐；
  /// termux 裸原生是 2026-09-18 新增的实验路线（供应链已核实为 Termux 主仓
  /// 现货，但构建链路还没真机验证过）→ 明确标注实验性。
  Future<void> _showBackendChoiceDialog({required bool firstRun}) async {
    final choice = await showDialog<BuildBackend>(
      context: context,
      barrierDismissible: !firstRun,
      builder: (ctx) => AlertDialog(
        title: Text(firstRun ? '选择构建后端' : '切换构建后端'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'FOA 支持两套可切换的构建后端，装的工具不一样：',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _backendOptionTile(
                ctx,
                backend: BuildBackend.proot,
                title: 'Proot 容器（推荐）',
                subtitle: 'Debian 官方工具链 + 可选 QEMU/原生加速。\n'
                    '✅ 已真机验证 · 兼容性最好 · 文档最全\n'
                    '⚠️ 需下载 78MB rootfs；proot 有少量系统调用开销',
              ),
              const SizedBox(height: 8),
              _backendOptionTile(
                ctx,
                backend: BuildBackend.termux,
                title: 'Termux 裸原生（实验性）',
                subtitle: 'Termux 主仓 bionic 工具链，不经 proot 直接跑。\n'
                    '✅ 无 rootfs 依赖路径 · 无 proot 开销 · 原生全速\n'
                    '⚠️ 新路线，构建链路未经真机验证；Flutter 需导入移植版'
                    '（版本可能与官方 SDK 不同）',
              ),
            ],
          ),
        ),
        actions: [
          if (!firstRun)
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
        ],
      ),
    );
    if (choice != null && mounted) {
      await _switchBackend(choice);
    }
  }

  Widget _backendOptionTile(
    BuildContext ctx, {
    required BuildBackend backend,
    required String title,
    required String subtitle,
  }) {
    final selected = _backend == backend;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.pop(ctx, backend),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? Theme.of(ctx).colorScheme.primary
                : Theme.of(ctx).colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          children: [
            // 自绘选中圆点（Radio 的 groupValue/onChanged 已 deprecated，
            // 而整块 tile 本身就是点选入口，这里只需要视觉态）
            Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? Theme.of(ctx).colorScheme.primary : null,
                border: Border.all(
                  width: 2,
                  color: selected
                      ? Theme.of(ctx).colorScheme.primary
                      : Theme.of(ctx).colorScheme.outlineVariant,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14,
                      color: Colors.white)
                  : null,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 12, height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
      final nv =
          env.rootfsInstalled ? await NativeArm64.verify(_bridge) : null;
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
        _nativePhase = nv == null ? NativePhase.idle : NativePhase.installed;
        _nativeInfo = nv ?? '';
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
      var detail = '';
      if (v == null) {
        // 精确到文件的缺失清单（Bug 417）
        final miss = await AndroidSdkInstaller.diagnose(_bridge);
        detail = miss.isEmpty ? '' : '缺少 ${miss.join('、')}';
      }
      if (!mounted) return;
      setState(() {
        _asdkVerifying = false;
        _asdkPhase = v == null ? SdkPhase.idle : SdkPhase.installed;
        _asdkInfo = v ?? (detail.isEmpty ? '' : 'Android SDK 未完整安装：$detail');
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            v == null
                ? '验证失败：Android SDK 关键组件缺失${detail.isEmpty ? '' : '（$detail）'}'
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
    setState(() => _asdkPhase = SdkPhase.uninstalling);
    try {
      await AndroidSdkInstaller.uninstall(_bridge);
      await _refreshAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _asdkPhase = SdkPhase.error;
        _asdkError = e.toString();
      });
    }
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
    setState(() => _flPhase = SdkPhase.uninstalling);
    try {
      await FlutterSdkInstaller.uninstall(_bridge);
      await _refreshAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _flPhase = SdkPhase.error;
        _flError = e.toString();
      });
    }
  }

  // ============================ x64 兼容层(QEMU) ============================

  // ============================ Termux 裸原生后端 ============================

  Future<void> _termuxRunSmoke() async {
    setState(() {
      _termuxBusy = true;
      _termuxError = '';
    });
    try {
      final env = await _bridge.envInfo();
      final s = await TermuxInstaller.smoke(_bridge, env);
      if (!mounted) return;
      setState(() {
        _termuxBusy = false;
        _termuxSmoke = s;
        _termuxPhase = TermuxPhase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _termuxBusy = false;
        _termuxPhase = TermuxPhase.error;
        _termuxError = e.toString();
      });
    }
  }

  /// 装 Termux 仓库组件（openjdk-17 / aapt 四件套）。
  Future<void> _termuxInstallPackage(String pkg) async {
    setState(() {
      _termuxPhase = TermuxPhase.indexing;
      _termuxError = '';
      _termuxInfo = '';
    });
    try {
      final env = await _bridge.envInfo();
      final msg = await TermuxInstaller.installPackage(
        _bridge,
        env,
        pkg,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _termuxPhase = switch (p) {
                'indexing' => TermuxPhase.indexing,
                'downloading' => TermuxPhase.downloading,
                'unpacking' => TermuxPhase.unpacking,
                _ => TermuxPhase.unpacking,
              });
        },
        onMirror: (m) {
          if (!mounted) return;
          setState(() => _termuxMirrors..clear()..add(m));
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _termuxProgress = p);
        },
        token: _termuxToken,
      );
      if (!mounted) return;
      setState(() {
        _termuxPhase = TermuxPhase.ready;
        _termuxInfo = msg;
      });
      await _termuxRunSmoke();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _termuxPhase = TermuxPhase.error;
        _termuxError = e.toString();
      });
    }
  }

  /// 导入 bionic Flutter（ImL1s 系 deb / tar.xz，本地文件）。
  Future<void> _termuxImportFlutter() async {
    final ok = await _confirm(
      '导入 Termux 版 Flutter（bionic）',
      '需要你自备 Termux 系的 Flutter aarch64 包（如 ImL1s/termux-flutter '
          '的 flutter_3.44.0_aarch64.deb，或同源 tar.xz）。\n\n'
          '导入后：\n'
          '  1. 解包到 /opt/foa-termux/usr/opt/flutter（不经 proot 运行）；\n'
          '  2. 自动改写包内 Termux 前缀路径；\n'
          '  3. bare 冒烟 flutter --version。\n\n'
          '⚠️ 版本以导入包为准（如 3.44.0），与容器里官方 SDK（3.47.4）'
          '可能不同——Termux 模式构建用的是导入的这套（dart 与 gen_snapshot '
          '必须配套）。',
    );
    if (!ok) return;
    final picked = await LocalInstallPicker.pickInstallFile();
    if (!mounted) return;
    if (!picked.ok || picked.path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(picked.error ?? '未选择文件')),
      );
      return;
    }
    setState(() {
      _termuxPhase = TermuxPhase.importing;
      _termuxError = '';
      _termuxInfo = '';
    });
    try {
      final env = await _bridge.envInfo();
      final msg = await TermuxInstaller.installFlutterFromLocalFile(
        _bridge,
        env,
        picked.path!,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _termuxPhase = TermuxPhase.importing);
        },
      );
      if (!mounted) return;
      setState(() {
        _termuxPhase = TermuxPhase.ready;
        _termuxInfo = msg;
      });
      await _termuxRunSmoke();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _termuxPhase = TermuxPhase.error;
        _termuxError = e.toString();
      });
    }
  }

  /// 在线下载 bionic Flutter（ImL1s release，GitHub + 代理竞速）。
  Future<void> _termuxDownloadFlutter() async {
    final ok = await _confirm(
      '在线下载 Termux 版 Flutter（bionic）',
      '源：ImL1s/termux-flutter-wsl release（快照 ${TermuxFlutterRelease.version}，'
          '${(TermuxFlutterRelease.size / 1048576).toStringAsFixed(0)} MB）。\n\n'
          '  · GitHub 直链 + 多个加速代理竞速，慢源/死源自动切换；\n'
          '  · 全部源失败时回退「本地导入」（你自备 deb）；\n'
          '  · 下载完 SHA256 校验后解包到 /opt/foa-termux/usr/opt/flutter，'
          '自动改写 Termux 前缀路径。\n\n'
          '⚠️ 版本 ${TermuxFlutterRelease.version.replaceFirst('v', '')} 与容器官方 SDK（3.47.4）'
          '不同——Termux 模式构建用的是这套（dart 与 gen_snapshot 配套）。',
    );
    if (!ok) return;
    setState(() {
      _termuxPhase = TermuxPhase.indexing;
      _termuxError = '';
      _termuxInfo = '';
      _termuxToken = DownloadCancelToken();
    });
    try {
      final env = await _bridge.envInfo();
      final msg = await TermuxInstaller.installFlutterOnline(
        _bridge,
        env,
        onPhase: (p) {
          if (!mounted) return;
          setState(() => _termuxPhase = switch (p) {
                'indexing' => TermuxPhase.indexing,
                'downloading' => TermuxPhase.downloading,
                'unpacking' => TermuxPhase.unpacking,
                'importing' => TermuxPhase.importing,
                _ => TermuxPhase.importing,
              });
        },
        onMirror: (m) {
          if (!mounted) return;
          setState(() => _termuxMirrors..clear()..add(m));
        },
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _termuxProgress = p);
        },
        token: _termuxToken,
      );
      if (!mounted) return;
      setState(() {
        _termuxPhase = TermuxPhase.ready;
        _termuxInfo = msg;
      });
      await _termuxRunSmoke();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _termuxPhase = TermuxPhase.error;
        _termuxError = '$e\n\n提示：在线下载失败时可改用「本地导入」（自备 '
            '${TermuxFlutterRelease.asset}）。';
      });
    }
  }

  Future<void> _termuxCancel() async {
    _termuxToken?.cancel();
    setState(() => _termuxPhase = TermuxPhase.idle);
  }

  Future<void> _termuxUninstall() async {
    setState(() => _termuxPhase = TermuxPhase.uninstalling);
    try {
      final env = await _bridge.envInfo();
      await TermuxInstaller.uninstall(env);
      if (!mounted) return;
      setState(() {
        _termuxPhase = TermuxPhase.idle;
        _termuxSmoke = '';
        _termuxInfo = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _termuxPhase = TermuxPhase.error;
        _termuxError = e.toString();
      });
    }
  }

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

  // ============================ 原生 arm64 ============================

  NativePhase _nativePhaseFrom(String p) => switch (p) {
        'apt' => NativePhase.apt,
        'downloading' => NativePhase.downloading,
        'importing' => NativePhase.importing,
        'extracting' => NativePhase.extracting,
        'deploying' => NativePhase.deploying,
        _ => NativePhase.idle,
      };

  Future<void> _nativeInstall({bool local = false}) async {
    String? localPath;
    if (local) {
      final picked = await LocalInstallPicker.pickInstallFile();
      if (!mounted) return;
      if (!picked.ok || picked.path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(picked.error ?? '未选择文件')),
        );
        return;
      }
      localPath = picked.path;
    }
    setState(() {
      _nativePhase =
          local ? NativePhase.importing : NativePhase.downloading;
      _nativeProgress = null;
      _nativeError = '';
      _nativeMirrors.clear();
    });
    _nativeToken = DownloadCancelToken();
    try {
      final env = await _bridge.envInfo();
      if (local) {
        await NativeBuildTools.installFromLocalFile(
          _bridge,
          env,
          localPath!,
          onPhase: (p) {
            if (!mounted) return;
            setState(() => _nativePhase = _nativePhaseFrom(p));
          },
        );
      } else {
        await NativeBuildTools.install(
          _bridge,
          env,
          token: _nativeToken,
          onPhase: (p) {
            if (!mounted) return;
            setState(() => _nativePhase = _nativePhaseFrom(p));
          },
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _nativeProgress = p);
          },
          onMirrorUsed: (m) {
            if (!mounted) return;
            setState(() => _nativeMirrors.add(m.name));
          },
        );
      }
      if (!mounted) return;
      final v = await NativeArm64.verify(_bridge);
      setState(() {
        _nativePhase = NativePhase.installed;
        _nativeInfo = v ?? '已落位';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nativePhase = NativePhase.error;
        _nativeError = e.toString();
      });
    }
  }

  Future<void> _nativeCancel() async {
    _nativeToken?.cancel();
    setState(() => _nativePhase = NativePhase.idle);
  }

  /// 导入原生 gen_snapshot（**有门禁**：先讲清风险再让用户选文件）。
  Future<void> _nativeImportGenSnapshot() async {
    final ok = await _confirm(
      '导入原生 gen_snapshot',
      'gen_snapshot 是 Flutter AOT 编译的核心宿主工具，Google 不发布 arm64 版本，'
          '只能取第三方移植产物（如 Termux 系的 Flutter aarch64 构建）。\n\n'
          '请你自己准备好这个文件后点「确定」再选择它。导入后会立即做两件事：\n'
          '  1. 校验必须是 aarch64 ELF；\n'
          '  2. 实跑一次 --help 冒烟。\n'
          '冒烟不过会当场撤销落位，不会留下半吊子状态。\n\n'
          '注意：Termux 系二进制是 bionic 链接的，运行时需要容器内可见 '
          '/system 与 /apex（原生层会自动追加挂载）。',
    );
    if (!ok) return;
    final picked = await LocalInstallPicker.pickInstallFile();
    if (!mounted) return;
    if (!picked.ok || picked.path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(picked.error ?? '未选择文件')),
      );
      return;
    }
    setState(() {
      _nativePhase = NativePhase.importing;
      _nativeError = '';
    });
    try {
      final env = await _bridge.envInfo();
      final msg =
          await NativeGenSnapshot.importFromLocalFile(_bridge, env, picked.path!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 6)),
      );
      await _nativeRunAudit();
      await _refreshAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nativePhase = NativePhase.error;
        _nativeError = e.toString();
      });
    }
  }

  Future<void> _nativeUninstall() async {
    final ok = await _confirm(
      '卸载原生产物',
      '将还原 build-tools 里的 x64 原件，并删除 /opt/foa-native'
      '（含已导入的 gen_snapshot），确定？',
    );
    if (!ok) return;
    setState(() => _nativePhase = NativePhase.uninstalling);
    try {
      final env = await _bridge.envInfo();
      await NativeBuildTools.uninstall(_bridge, env);
      await _refreshAll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nativePhase = NativePhase.error;
        _nativeError = e.toString();
      });
    }
  }

  Future<void> _nativeRunAudit() async {
    setState(() {
      _nativeAuditing = true;
      _nativeError = '';
    });
    try {
      final env = await _bridge.envInfo();
      if (!env.rootfsInstalled) {
        throw DownloadException('rootfs 未安装，请先在主页初始化环境');
      }
      final a = await NativeArm64.audit(_bridge);
      final v = await NativeArm64.verify(_bridge);
      if (!mounted) return;
      setState(() {
        _nativeAuditing = false;
        _nativeAudit = a;
        _nativePhase = v == null ? NativePhase.idle : NativePhase.installed;
        _nativeInfo = v ?? '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _nativeAuditing = false;
        _nativePhase = NativePhase.error;
        _nativeError = '体检失败：$e';
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
    final backend = _backend;
    final isTermux = backend == BuildBackend.termux;
    // 顺序门控（proot 模式）：SDK 工具为 x64 宿主二进制，**两种后端任一就绪**
    // 即可装 SDK：① QEMU 兼容层转发 ② 原生 arm64 落位。二者是并行后端。
    // termux 模式：SDK 组件（android.jar / lib jars / 许可）架构无关，
    // 装在容器目录但裸模式直接复用，无需任何后端前置。
    final sdkOrderReady = isTermux ||
        _qemuPhase == QemuPhase.installed ||
        _nativePhase == NativePhase.installed;
    return Scaffold(
      appBar: AppBar(title: const Text('工具链')),
      body: backend == null
          // 首次进入：还没选后端（对话框已弹出），先不渲染卡片
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _BackendSwitcher(
                  backend: backend,
                  onChanged: (b) async {
                    if (b == backend) return;
                    await _switchBackend(b);
                  },
                  onDetails: () => _showBackendChoiceDialog(firstRun: false),
                ),
                const SizedBox(height: 12),
                if (isTermux) ...[
                  _TermuxCard(
                    phase: _termuxPhase,
                    info: _termuxInfo,
                    smoke: _termuxSmoke,
                    error: _termuxError,
                    rootfsReady: rootfsReady,
                    busy: _termuxBusy,
                    progress: _termuxProgress,
                    mirrorName: _termuxMirrors.join(' + '),
                    prefixReady: _env != null && TermuxPaths.prefixExists(_env!),
                    hasJdk: _env != null &&
                        Directory(TermuxPaths.jdkHome(_env!)).existsSync(),
                    hasBuildTools: _env != null &&
                        File(TermuxPaths.aapt2(_env!)).existsSync(),
                    hasFlutter: _env != null &&
                        Directory(TermuxPaths.flutterHome(_env!)).existsSync(),
                    onInstallJdk: () => _termuxInstallPackage(TermuxRepo.jdkPackage),
                    onInstallBuildTools: () =>
                        _termuxInstallPackage(TermuxRepo.buildToolsPackage),
                    onDownloadFlutter: _termuxDownloadFlutter,
                    onImportFlutter: _termuxImportFlutter,
                    onSmoke: _termuxRunSmoke,
                    onCancel: _termuxCancel,
                    onUninstall: _termuxUninstall,
                  ),
                  const SizedBox(height: 12),
                  _asdkCard(termuxMode: true, rootfsReady: rootfsReady, orderReady: sdkOrderReady),
                ] else ...[
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
                  _NativeCard(
                    phase: _nativePhase,
                    audit: _nativeAudit,
                    info: _nativeInfo,
                    error: _nativeError,
                    rootfsReady: rootfsReady,
                    auditing: _nativeAuditing,
                    progress: _nativeProgress,
                    mirrorName: _nativeMirrors.join(' + '),
                    hasGenSnapshot: _nativeAudit?.probe('native:gen_snapshot') != null,
                    onAudit: _nativeRunAudit,
                    onInstall: () => _nativeInstall(),
                    onInstallLocal: () => _nativeInstall(local: true),
                    onImportGenSnapshot: _nativeImportGenSnapshot,
                    onCancel: _nativeCancel,
                    onUninstall: _nativeUninstall,
                  ),
                  const SizedBox(height: 12),
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
                  _asdkCard(termuxMode: false, rootfsReady: rootfsReady, orderReady: sdkOrderReady),
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
                        '国内源（flutter-io.cn 官方中国镜像）优先；解压到容器内 /opt/flutter。',
                    verifying: _flVerifying,
                    rootfsReady: rootfsReady,
                    orderReady: sdkOrderReady,
                    orderHint: '需先应用上方「x64 兼容层(QEMU)」再安装：flutter_tools.snapshot '
                        '为 x64 快照、dart 也是 x64 宿主二进制，'
                        '目前**只能**靠 QEMU 转发（原生 arm64 的 dart 替换 + 快照重建尚未实现，'
                        '不做就不会有 "原生提速"）。\n'
                        '若已装反顺序无需卸载——点兼容层「重新应用」会自动补上转发。',
                    onInstall: _flInstall,
                    onVerify: _flVerify,
                    onCancel: _flCancel,
                    onUninstall: _flUninstall,
                    onInstallLocal: _flInstallFromLocal,
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
                  const SizedBox(height: 12),
                  _AvfCard(env: _env),
                ],
              ],
            ),
    );
  }

  /// Android SDK 卡（两种后端共用：组件架构无关，装在容器目录树下，
  /// proot 走容器路径访问、termux 裸模式走宿主路径访问——同一目录）。
  Widget _asdkCard({
    required bool termuxMode,
    required bool rootfsReady,
    required bool orderReady,
  }) {
    return _SdkCard(
      title: termuxMode ? 'Android SDK（组件共享 · 裸模式复用）' : 'Android SDK',
      icon: Icons.android,
      phase: _asdkPhase,
      progress: _asdkProgress,
      mirrorName: _asdkMirrors.join(' + '),
      info: _asdkInfo,
      error: _asdkError,
      sizeLabel: '约 ${(AndroidSdkInstaller.totalSize / 1048576).toStringAsFixed(0)} MB · 4 个组件',
      desc: termuxMode
          ? 'platform android.jar / build-tools 的 lib jars / 许可文件全部'
              '架构无关——Termux 裸模式构建时由原生层直接指向容器 SDK 目录复用，'
              '其中 x64 的 bin/ 二进制不会被调用（aapt2 由 Termux 版顶替）。\n'
              '安装仍写入容器内 /opt/android-sdk（与 proot 模式同一份，切换不重复下载）。'
          : 'platform-tools r37 + platforms;android-36 + build-tools 36.0.0 '
              '+ cmdline-tools（与 Flutter 3.47.4 的 compileSdk 36 对齐）。\n'
              '国内源优先（腾讯云）探测取最快，4 线程分段并发 + SHA-1 校验；'
              '解压到容器内 /opt/android-sdk 并预置许可。',
      verifying: _asdkVerifying,
      rootfsReady: rootfsReady,
      orderReady: orderReady,
      orderHint: termuxMode
          ? 'Termux 模式无需任何前置：SDK 组件本身架构无关。\n'
              '⚠️ adb / fastboot 等可执行文件仍是 x64，裸模式下不可用'
              '（构建流程用不到 adb）。\n'
              '⚠️ 本模式仍需 rootfs 已安装（解包借用容器 dpkg-deb）——'
              '但构建执行不经 proot。'
          : '需先启用一套后端（上方「x64 兼容层(QEMU)」或「原生 arm64」）'
              '再安装：aapt2/adb 默认是 x64 宿主二进制，'
              '既没 QEMU 转发又没换原生版就无法执行。\n'
              '⚠️ 现阶段原生后端只覆盖 build-tools 四件套（aapt2/aidl/zipalign/'
              'split-select），adb 仍是 x64——建议两套都启用：QEMU 兜底、原生提速。',
      onInstall: _asdkInstall,
      onVerify: _asdkVerify,
      onCancel: _asdkCancel,
      onUninstall: _asdkUninstall,
      onInstallLocal: _asdkInstallFromLocal,
    );
  }
}

// ============================ 后端切换器 ============================

/// 工具链页顶部的后端切换（「Termux 裸原生」⇄「Proot 容器」）。
class _BackendSwitcher extends StatelessWidget {
  final BuildBackend backend;
  final ValueChanged<BuildBackend> onChanged;
  final VoidCallback onDetails;

  const _BackendSwitcher({
    required this.backend,
    required this.onChanged,
    required this.onDetails,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_horiz, size: 18, color: cs.primary),
              const SizedBox(width: 6),
              const Text('构建后端',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton(
                onPressed: onDetails,
                child: const Text('两者有什么区别？'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SegmentedButton<BuildBackend>(
            segments: const [
              ButtonSegment(
                value: BuildBackend.termux,
                icon: Icon(Icons.bolt),
                label: Text('Termux 裸原生'),
              ),
              ButtonSegment(
                value: BuildBackend.proot,
                icon: Icon(Icons.dns),
                label: Text('Proot 容器'),
              ),
            ],
            selected: {backend},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
          const SizedBox(height: 6),
          Text(
            backend == BuildBackend.termux
                ? '实验性：Termux 主仓 bionic 工具链，不经 proot 直接在真机内核上执行。'
                    '构建页会自动走裸执行通道（宿主路径）。'
                : '成熟路线：Debian 容器 + 官方/原生工具链（已真机验证）。'
                    '支持 QEMU 兼容层与容器内原生 arm64 两套加速。',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ============================ Termux 裸原生卡片 ============================

/// Termux 裸原生后端卡：三件套安装 + bare 冒烟 + 卸载。
///
/// 三件套 = ① Termux openjdk-17（bionic JVM）② aapt 包（aapt2/aidl/zipalign
/// bionic 四件套）③ Flutter bionic 移植版（在线下载 ImL1s release 或本地导入，
/// dart 与 gen_snapshot 配套）。Gradle/d8/R8/kotlinc 纯 JVM 随 JDK 走；
/// Android SDK 组件卡片共享。
class _TermuxCard extends StatelessWidget {
  final TermuxPhase phase;
  final String info;
  final String smoke;
  final String error;
  final bool rootfsReady;
  final bool busy;
  final DownloadProgress? progress;
  final String mirrorName;
  final bool prefixReady;
  final bool hasJdk;
  final bool hasBuildTools;
  final bool hasFlutter;
  final VoidCallback onInstallJdk;
  final VoidCallback onInstallBuildTools;
  final VoidCallback onDownloadFlutter;
  final VoidCallback onImportFlutter;
  final VoidCallback onSmoke;
  final VoidCallback onCancel;
  final VoidCallback onUninstall;

  const _TermuxCard({
    required this.phase,
    required this.info,
    required this.smoke,
    required this.error,
    required this.rootfsReady,
    required this.busy,
    required this.progress,
    required this.mirrorName,
    required this.prefixReady,
    required this.hasJdk,
    required this.hasBuildTools,
    required this.hasFlutter,
    required this.onInstallJdk,
    required this.onInstallBuildTools,
    required this.onDownloadFlutter,
    required this.onImportFlutter,
    required this.onSmoke,
    required this.onCancel,
    required this.onUninstall,
  });

  String get _statusLabel => switch (phase) {
        TermuxPhase.idle => prefixReady ? '已初始化' : '未安装',
        TermuxPhase.indexing => '查询 Termux 仓库索引（查 JDK / aapt 版本；Flutter 不在主仓，走下方独立下载）…',
        TermuxPhase.downloading => '下载中…',
        TermuxPhase.unpacking => '容器内解包 + 前缀改写…',
        TermuxPhase.importing => '导入 Flutter…',
        TermuxPhase.verifying => 'bare 冒烟验证…',
        TermuxPhase.ready => '就绪',
        TermuxPhase.uninstalling => '卸载中…',
        TermuxPhase.error => '出错',
      };

  Widget _compRow(BuildContext context, String name, String desc, bool installed,
      {VoidCallback? onInstall, required String action,
      VoidCallback? secondaryOnInstall, String secondaryAction = ''}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            installed ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 18,
            color: installed ? Colors.green : cs.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(desc, style: const TextStyle(fontSize: 11.5, height: 1.3)),
              ],
            ),
          ),
          if (!installed) ...[
            if (secondaryOnInstall != null)
              TextButton(
                onPressed: secondaryOnInstall,
                child: Text(secondaryAction),
              ),
            if (onInstall != null)
              TextButton(onPressed: onInstall, child: Text(action)),
          ],
          if (installed)
            Text('已装', style: TextStyle(fontSize: 12, color: cs.primary)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final installing = switch (phase) {
      TermuxPhase.indexing ||
      TermuxPhase.downloading ||
      TermuxPhase.unpacking ||
      TermuxPhase.importing =>
        true,
      _ => false,
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt, color: cs.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Termux 裸原生（实验性）',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                Text(_statusLabel,
                    style: TextStyle(
                        color: phase == TermuxPhase.error
                            ? cs.error
                            : cs.primary,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '不经 proot：Termux 主仓 bionic 二进制直接在真机内核上执行'
              '（无指令翻译、无 ptrace 拦截开销）。安装期借用容器 dpkg-deb 解包'
              '（需 rootfs 已装），**构建执行完全不走 proot**。\n'
              '⚠️ 供应链已核实（dev-handbook/07 §八），但构建链路尚未真机验证。',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
            const Divider(height: 20),
            _compRow(context, 'JDK 17（Termux openjdk-17）',
                'bionic 构建，Gradle/d8/R8/kotlinc 纯 JVM 随其运行', hasJdk,
                onInstall: rootfsReady && !installing && !busy
                    ? onInstallJdk
                    : null,
                action: '安装'),
            _compRow(context, 'aapt2 / aidl / zipalign',
                'Termux aapt 包（AOSP 源码 bionic 构建），AGP 直接调用', hasBuildTools,
                onInstall: rootfsReady && !installing && !busy
                    ? onInstallBuildTools
                    : null,
                action: '安装'),
            _compRow(context, 'Flutter（bionic 移植版）',
                '在线下载 ImL1s release（GitHub+代理竞速）或本地导入；'
                'dart 与 gen_snapshot 配套，版本可能与官方 SDK 不同',
                hasFlutter,
                onInstall: rootfsReady && !installing && !busy
                    ? onImportFlutter
                    : null,
                action: '导入',
                secondaryOnInstall: rootfsReady && !installing && !busy
                    ? onDownloadFlutter
                    : null,
                secondaryAction: '在线下载'),
            if (installing && progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress!.total > 0
                    ? progress!.received / progress!.total
                    : null,
              ),
              const SizedBox(height: 4),
              Text(
                '${(progress!.received / 1048576).toStringAsFixed(1)} / '
                '${(progress!.total / 1048576).toStringAsFixed(1)} MB'
                '${mirrorName.isEmpty ? '' : ' · $mirrorName'}',
                style: const TextStyle(fontSize: 11),
              ),
            ],
            if (info.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(info,
                  style: TextStyle(fontSize: 12, color: cs.primary, height: 1.4)),
            ],
            if (smoke.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                ),
                child: Text('bare 冒烟（不经 proot 直跑）：\n$smoke',
                    style: const TextStyle(fontSize: 11.5, height: 1.5)),
              ),
            ],
            if (error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(error,
                  style: TextStyle(fontSize: 12, color: cs.error, height: 1.4)),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: busy || installing ? null : onSmoke,
                  child: const Text('bare 冒烟'),
                ),
                if (installing)
                  OutlinedButton(onPressed: onCancel, child: const Text('取消')),
                OutlinedButton(
                  onPressed: busy || installing || !prefixReady
                      ? null
                      : onUninstall,
                  child: const Text('卸载'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================ 原生 arm64 体检卡片 ============================

/// 原生 arm64 体检卡（**只读**）。
///
/// 只回答一个问题：现在这套构建链里，哪些二进制是 aarch64 原生、
/// 哪些还是 x86-64（靠 QEMU 模拟）。落位原生产物是后续步骤的事——
/// 先看清楚现状，再决定要不要换后端。
class _NativeCard extends StatelessWidget {
  final NativePhase phase;
  final NativeAudit? audit;
  final String info;
  final String error;
  final bool rootfsReady;
  final bool auditing;
  final DownloadProgress? progress;
  final String mirrorName;
  final bool hasGenSnapshot;
  final VoidCallback onAudit;
  final VoidCallback onInstall;
  final VoidCallback onInstallLocal;
  final VoidCallback onImportGenSnapshot;
  final VoidCallback onCancel;
  final VoidCallback onUninstall;

  const _NativeCard({
    required this.phase,
    required this.audit,
    required this.info,
    required this.error,
    required this.rootfsReady,
    required this.auditing,
    required this.progress,
    required this.mirrorName,
    required this.hasGenSnapshot,
    required this.onAudit,
    required this.onInstall,
    required this.onInstallLocal,
    required this.onImportGenSnapshot,
    required this.onCancel,
    required this.onUninstall,
  });

  bool get _busy => phase == NativePhase.auditing ||
      phase == NativePhase.apt ||
      phase == NativePhase.downloading ||
      phase == NativePhase.importing ||
      phase == NativePhase.extracting ||
      phase == NativePhase.deploying ||
      phase == NativePhase.uninstalling;

  String get _statusLabel => switch (phase) {
        NativePhase.installed => '原生产物已落位',
        NativePhase.auditing => '正在体检…',
        NativePhase.apt => '补齐原生运行库…',
        NativePhase.downloading => '下载 arm64 build-tools…',
        NativePhase.importing => '导入本地文件…',
        NativePhase.extracting => '解包到 /opt/foa-native…',
        NativePhase.deploying => '落位到 build-tools + 冒烟…',
        NativePhase.uninstalling => '正在卸载…',
        NativePhase.error => '失败',
        NativePhase.idle => '原生后端未启用（可先体检）',
      };

  @override
  Widget build(BuildContext context) {
    final a = audit;
    final color = switch (phase) {
      NativePhase.installed => const Color(0xFF3DDC84),
      NativePhase.error => const Color(0xFFFF7A7A),
      _ => Colors.blueAccent,
    };

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
                    NativePhase.installed => Icons.check_circle,
                    NativePhase.error => Icons.error_outline,
                    _ => Icons.speed,
                  },
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusLabel,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    a == null
                        ? '未体检'
                        : (a.buildReady ? '可全原生构建' : '仍有模拟环节'),
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, color: color),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            if (phase == NativePhase.installed && info.isNotEmpty)
              _kv('落位', info),
            if (a != null) ...[
              _kv('总览', a.overview),
              _kv('dart 目标架构',
                  a.dartTargetArch.isEmpty ? '未知' : a.dartTargetArch),
              _kv('readelf',
                  a.readelfAvailable ? '可用（DT_NEEDED 精确）' : '缺失（needed 为粗扫）'),
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 6),
              for (final p in a.probes) _probeRow(p),
              const SizedBox(height: 4),
              Text(
                a.buildReady
                    ? '构建链上必须原生的几项（dart / 快照架构 / gen_snapshot / '
                        'aapt2 / zipalign）均为 aarch64，理论上可去掉 QEMU。'
                    : '构建链上仍有非原生环节（dart / 快照架构 / gen_snapshot / '
                        'aapt2 / zipalign 任一未原生），这部分仍需 QEMU 转发。',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                minHeight: 6,
                value: progress?.fraction,
                borderRadius: const BorderRadius.all(Radius.circular(3)),
              ),
              const SizedBox(height: 6),
              Text(
                switch (phase) {
                  NativePhase.auditing =>
                    '正在读取各二进制的 ELF 头与依赖（dart --version 最慢，约 1 分钟）',
                  NativePhase.downloading =>
                    'arm64 build-tools 约 3.2MB${mirrorName.isEmpty ? '' : ' · 源：$mirrorName'}',
                  NativePhase.importing => '校验本地文件…',
                  NativePhase.apt => '容器内 apt 安装 libstdc++6 / zlib1g',
                  NativePhase.extracting => '解包 + 校验架构（必须 aarch64）',
                  NativePhase.deploying => '备份 x64 原件为 .foa-x64 后覆盖',
                  _ => '处理中…',
                },
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            if (phase == NativePhase.error && error.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(error,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF7A7A))),
            ],
            const SizedBox(height: 12),
            Text(
              '为什么看这个：当前构建链是「官方 x64 SDK + QEMU 动态翻译」，'
              '每层模拟都有性能损耗。逐个把关键宿主二进制换成 aarch64 原生，'
              '就能相应减少翻译层。\n'
              '已原生：java（有 aarch64 JDK）、gradle/d8/R8（纯 JVM）、'
              'dart（有 linux_arm64 发行版）。\n'
              '可原生：aapt2 / aidl / zipalign / split-select（第三方 arm64 构建）。\n'
              '唯一硬缺口：gen_snapshot（Google 不发布 arm64），只能取移植版，'
              '且要注意它可能是 **bionic 链接**（Termux 产物），需要容器能看见 '
              '/system / /apex 才能跑。\n'
              '⚠️ 现阶段是**混合模式**（最小侵入）：本卡片只负责 build-tools 四件套'
              '与可选 gen_snapshot，dart / flutter_tools 仍走 QEMU 转发——'
              '两套后端共存，谁覆盖了谁就少一层翻译。\n'
              '体检本身只读，不会修改任何文件。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 16),
            if (phase == NativePhase.downloading) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('取消下载'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF7A7A),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: rootfsReady && !_busy ? onAudit : null,
                icon: const Icon(Icons.search, size: 18),
                label: Text(
                    phase == NativePhase.auditing ? '体检中…' : (a == null ? '开始体检' : '重新体检')),
              ),
            ),
            const SizedBox(height: 8),
            if (phase == NativePhase.installed) ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : onUninstall,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('卸载'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF7A7A),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: rootfsReady && !_busy ? onInstall : null,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('原生化 build-tools'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: rootfsReady && !_busy ? onInstallLocal : null,
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      label: const Text('本地导入'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'gen_snapshot（唯一硬缺口，无自动下载源）',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: rootfsReady && !_busy && !hasGenSnapshot
                      ? onImportGenSnapshot
                      : null,
                  icon: Icon(
                    hasGenSnapshot ? Icons.check_circle : Icons.file_upload_outlined,
                    size: 18,
                  ),
                  label: Text(hasGenSnapshot ? '已原生化' : '本地导入'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: hasGenSnapshot
                        ? const Color(0xFF3DDC84)
                        : const Color(0xFFFFC46B),
                  ),
                ),
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

  Widget _probeRow(NativeProbe p) {
    final c = p.native
        ? const Color(0xFF3DDC84)
        : (p.kind == NativeProbeKind.qemuWrapper
            ? Colors.orangeAccent
            : (p.kind == NativeProbeKind.missing
                ? Colors.grey.shade600
                : const Color(0xFFFF7A7A)));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: Text(p.name,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade300)),
          ),
          Expanded(
            child: Text(p.summary,
                style: TextStyle(
                    fontSize: 11, fontFamily: 'monospace', color: c)),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(k,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
            ),
            Expanded(
                child: Text(v,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace'))),
          ],
        ),
      );
}

// ============================ AVF 能力卡片 ============================

/// AVF（Android 虚拟化框架）能力检测卡。
///
/// ⚠️ 本卡片**只做能力告知，不做任何 VM 操作**。
/// AVF 的虚拟机由特权系统服务（virtmgr / VirtualizationService）管理，
/// 普通应用（untrusted_app 域）没有创建或驱动 VM 的公开 API。
/// 这里能做的只有：探测设备是否具备条件 → 告诉用户"能不能走这条路"，
/// 避免用户在硬件不支持时白折腾。
///
/// 详见《AVF集成可行性评估.md》
class _AvfCard extends StatelessWidget {
  final EnvInfo? env;

  const _AvfCard({this.env});

  @override
  Widget build(BuildContext context) {
    final e = env;
    final supported = e?.avfSupported == true;
    final installed = e?.avfTerminalInstalled == true;
    final reason = e?.avfReason ?? '正在检测…';

    final color = supported
        ? (installed ? const Color(0xFF3DDC84) : const Color(0xFFFFC46B))
        : Colors.grey.shade600;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory, color: color, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('AVF 虚拟化能力检测',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    supported ? (installed ? '可用' : '部分可用') : '不支持',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              reason,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 10),
            Text(
              '⏸ 本路线已暂停（2026-09-17）：实测设备用不了 AVF，故不再推进。'
              '当前提速方向改为上面的「原生 arm64」——把构建链里的宿主二进制'
              '逐个换成 aarch64 原生，减少 QEMU 转译层。\n\n'
              'AVF 是什么：Android 13+ 的「Linux 开发环境」提供的真 Linux 内核'
              '虚拟机（pKVM），没有 proot 的 syscall 翻译开销，构建速度优于当前方案。\n\n'
              '⚠️ 为什么 App 不能自动用它：AVF 的虚拟机由系统特权服务管理，'
              '普通应用没有创建/驱动 VM 的 API 权限。这条路线需要你手动操作：\n'
              '  设置 → 开发者选项 → Linux 开发环境 → 启用\n'
              '→ 在系统「终端」App 里进入 Debian VM\n'
              '→ 在 VM 内自行安装 Flutter 环境后构建。\n\n'
              '本卡片仅做能力告知，不代表本 App 可代为驱动 VM。',
              style: TextStyle(
                  fontSize: 11, height: 1.6, color: Colors.grey.shade500),
            ),
            if (supported && !installed) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 14, color: Color(0xFFFFC46B)),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '设备具备虚拟化能力，但未找到 Linux 开发环境入口。'
                      '部分厂商 ROM 未开放该选项——可尝试在开发者选项中搜索'
                      '「Linux」或升级系统。',
                      style: TextStyle(
                          fontSize: 11, color: Color(0xFFFFC46B)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
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
  final bool orderReady; // 前置依赖就绪（如 x64 兼容层已应用）才允许安装
  final String orderHint; // orderReady=false 时展示的安装门槛提示

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
    required this.orderReady,
    required this.orderHint,
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
        SdkPhase.uninstalling => '正在卸载…',
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
                ] else if (phase == SdkPhase.uninstalling) ...[
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: null,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('正在卸载…'),
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
                      // 顺序门控：前置依赖（x64 兼容层）未就绪时禁用安装，
                      // 避免小白先装 SDK 后装兼容层导致验证失败/困惑。
                      onPressed: orderReady && rootfsReady ? onInstall : null,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('下载并安装'),
                    ),
                  ),
                ],
              ],
            ),
            if (!orderReady && rootfsReady &&
                phase == SdkPhase.idle) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0x33FFB74D),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline,
                        size: 16, color: Color(0xFFFFB74D)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        orderHint,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFFFB74D), height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (!busy &&
                phase != SdkPhase.installed &&
                phase != SdkPhase.uninstalling) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  // 本地导入同样受顺序门控：前置依赖未就绪时禁用。
                  onPressed: orderReady && rootfsReady ? onInstallLocal : null,
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
