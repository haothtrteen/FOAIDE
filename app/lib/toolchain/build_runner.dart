import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../filemanager/fs_browser_bridge.dart';
import 'build_notify.dart';
import 'build_progress.dart';
import 'qemu_compat.dart';
import 'termux_backend.dart';
import 'toolchain_ensure.dart';

/// 构建会话状态机（构建页据其渲染）。
enum BuildStatus { idle, building, done, error, cancelled }

/// 构建执行器：全局单例，构建会话与构建页生命周期解耦。
///
/// 为什么抽单例（alpha.31）：原实现构建状态全是 BuildPage 的 State 字段，
/// 离开页面即 dispose 杀构建——用户锁屏/切走必断，还可能留下持锁孤儿
/// （Bug 420 的源头之一）。改为全局单例后：
/// - 页面退出只解绑 UI 钩子（onUiChanged/onAutoScroll），轮询由单例的
///   守护 timer 继续，进度同步喂前台服务通知（BuildNotify）；
/// - 重进页面 attach 回来，日志/进度/产物无缝续显；
/// - 原生 BuildService 前台服务保活 App 进程树，退出界面构建不中断。
///
/// 线程模型：所有方法都在主 isolate（与页面同）；poll 循环 500ms 一次，
/// 通道往返是异步的，天然串行（上一轮未返回时 timer 回调排队）。
class BuildRunner {
  BuildRunner._();
  static final BuildRunner I = BuildRunner._();

  final ProotBridge bridge = ProotBridge();
  final FileBrowserBridge _fb = FileBrowserBridge();

  // ---- 会话状态（构建页读这些渲染）----
  String? active; // 正在构建/已构建的项目名
  BuildStatus status = BuildStatus.idle;
  final List<String> lines = [];
  String partial = '';
  String? apkGuest; // 产物容器路径（rootfs 内）
  final BuildProgressTracker prog = BuildProgressTracker();

  /// 已构建耗时（秒），供"仍在运行/总耗时"展示。
  int elapsedSec = 0;

  /// 命中的修复建议（去重，最多展示 3 条——截取在 UI 层）。
  final List<String> hints = [];

  int _streamId = -1;
  int _offset = 0;
  DateTime? _startedAt;
  Timer? _timer;

  /// `✓ Built build/app/outputs` 行的命中时刻（alpha.58）：
  /// Built 打印在 Gradle 打包+签名**完成之后**——命中即构建本体已成功。
  /// flutter 工具偶发 Built 后 hang 不退出（dart VM 收尾不退出），
  /// 平台侧 running 恒真 → UI 永远停在「打包与签名 95%」骗用户。
  /// 宽限 [builtGraceSec] 秒后仍不退出则按成功强制收尾。
  DateTime? _builtAt;

  /// Built 后宽限秒数（ flutter 收尾通常 <5s；90s 是极宽余量）。
  static const int builtGraceSec = 90;

  /// Built 行标记（flutter build 成功时打印 `✓ Built build/app/outputs/...`）。
  static const String builtMarker = 'Built build/app/outputs';

  // ---- UI 钩子（页面 attach 时注入，dispose 置空；null = 构建在后台跑）----
  void Function()? onUiChanged;
  void Function()? onAutoScroll;

  bool get building => status == BuildStatus.building;

  // 通知节流：阶段与百分比都没变就不推（Kotlin 侧还有 800ms 限频兜底）
  int _lastNotifPct = -1;
  String _lastNotifStage = '';

  static const int _maxLines = 3000;

  void _ui() => onUiChanged?.call();
  void _scroll() => onAutoScroll?.call();

  /// Built 后宽限判定（纯函数，可单测）：
  /// 命中 Built 行超过宽限期且会话仍在 building → 应强制按成功收尾。
  static bool builtGraceElapsed({
    required DateTime? builtAt,
    required DateTime now,
    int graceSec = builtGraceSec,
  }) {
    if (builtAt == null) return false;
    return now.difference(builtAt).inSeconds > graceSec;
  }

  /// 秒 → `mm:ss` / `h:mm:ss`（UI 层与通知共用）。
  static String fmtDur(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// 「返回列表」：清会话到 idle（日志保留到下次构建 start 时 clear）。
  void resetUi() {
    if (building) return; // 构建中不允许（UI 上该按钮也不出现）
    status = BuildStatus.idle;
    active = null;
    _ui();
  }

  /// shell 单引号转义（项目名可能含空格/特殊字符）。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static const String _projectsDir = '/root/projects';

  // ============================ 启动构建 ============================

  Future<void> start(
    String name,
    EnvInfo env,
    BuildBackend backend, {
    ContainerLayer layer = ContainerLayer.proot,
  }) async {
    if (building) return; // 防重入（页面 UI 也不会同时给两个入口）
    final bare = backend == BuildBackend.termux;
    // termux 裸原生根本不进容器，此时 layer 无意义（传 false 下去，
    // 免得原生侧纠结"bare 和 proroot 同时为真怎么办"）
    final proroot = !bare && layer == ContainerLayer.proroot;
    active = name;
    status = BuildStatus.building;
    lines.clear();
    partial = '';
    apkGuest = null;
    prog.reset();
    elapsedSec = 0;
    _startedAt = DateTime.now();
    _builtAt = null;
    _lastNotifPct = -1;
    _lastNotifStage = '';
    hints.clear();
    _ui();

    // shell 命令里的项目目录：proot = 容器路径；termux bare = 宿主路径
    //（bare 执行不经 proot，容器路径 /root/projects 对宿主不存在）。
    final projectsDir = bare ? '${env.rootfsPath}/root/projects' : _projectsDir;
    final proj = '$projectsDir/${_q(name)}';

    // termux 后端前置组件检查（缺了就快速失败，别等 flutter 脚本报错）：
    // bionic Flutter（含 bin/flutter）与 bionic git——容器里的 git 是
    // glibc 二进制，bare 直跑不了，不能用 ToolchainEnsure 兜底。
    if (bare) {
      final miss = <String>[];
      final flDir = TermuxPaths.flutterHome(env);
      if (!Directory(flDir).existsSync() ||
          !File('$flDir/bin/flutter').existsSync()) {
        miss.add('Flutter（bionic）');
      }
      if (!File('${TermuxPaths.prefix(env)}/bin/git').existsSync()) {
        miss.add('git（bionic）');
      }
      if (miss.isNotEmpty) {
        status = BuildStatus.error;
        lines.add('✗ termux 后端缺组件：${miss.join('、')}');
        lines.add('  请到「工具链」页 → Termux 卡片安装后再构建');
        _ui();
        return;
      }
    }

    // 前置校验：不是 Flutter 项目就快速失败，省一次 2h 级长任务
    final check = await bridge.exec(
      'test -f $proj/pubspec.yaml && echo __OK__ || echo __NO__',
      timeoutSec: 30,
      bare: bare,
    );
    if (!check.stdout.contains('__OK__')) {
      status = BuildStatus.error;
      lines.add('✗ 不是 Flutter 项目：$proj/pubspec.yaml 不存在');
      _ui();
      return;
    }

    // proot 后端补一项 Flutter 存在性检查（termux 已在上方前置检查里
    // 覆盖）：快速失败给引导，别等 shell 报 `flutter: not found`
    if (!bare) {
      final probe = await bridge.exec(
        'test -x /opt/flutter/bin/flutter && echo __OK__ || echo __NO__',
        timeoutSec: 30,
      );
      if (!probe.stdout.contains('__OK__')) {
        status = BuildStatus.error;
        lines.add('✗ 容器内未找到 Flutter SDK（/opt/flutter/bin/flutter）');
        lines.add('  请到「工具链」页安装 Flutter 后再打包');
        _ui();
        return;
      }

      // Bug 425 根因修复：容器 CA 证书预检+自愈——minbase rootfs 无
      // ca-certificates 时 pub 对任何 https 源 100% 握手失败（真机
      // 三连卡 4% 的元凶），apt/内置 bundle 双路自愈
      final caErr = await ToolchainEnsure().caCerts(env: env);
      if (caErr != null) {
        status = BuildStatus.error;
        lines.add('✗ $caErr');
        lines.add('  修复后重新打包即可');
        _ui();
        return;
      }

      // Bug 426 根因修复：容器 init.gradle 旧版仓库注入与 Flutter 新模板
      // PREFER_SETTINGS 冲突 → 22% 配置 Gradle 报 "repository 'maven'
      // was added"。检测到旧版则覆写为 beforeSettings 前插形态。
      final gErr = await ToolchainEnsure().gradleInitSanitize(env: env);
      if (gErr != null) lines.add('⚠ $gErr（不阻断构建）');

      // Bug 427 根因修复：Flutter gradle 插件会主动调 sdkmanager 补装
      // NDK（项目 ndkVersion 不在已装列表时），而 sdkmanager 在 Android
      // arm64 上启 JVM 触发 JIT SIGILL（exit 132，真机 24% 配置 Gradle
      // 崩）。构建前写入最小 NDK 占位使插件判定"已装"直接跳过。
      final nErr = await ToolchainEnsure().ndkStub();
      if (nErr != null) lines.add('⚠ $nErr（不阻断构建）');

      // Bug 449 附属修复（alpha.55，2026-09-19 真机实证）：NDK 空壳
      // （见上 ndkStub）只有 source.properties，AOT 修通后第一次跑到
      // gradle :app:stripReleaseDebugSymbols 时找不到 llvm-strip 直接
      // 炸。构建前检测补位：Debian llvm symlink 进 NDK 期望路径
      // （arm64 原生、不过 qemu、能剥任意架构 ELF）。llvm 不可用时
      // 不阻断——留给 strip 阶段报错，避免网络问题卡死整个构建入口。
      final sErr = await ToolchainEnsure().ndkStripTools();
      if (sErr != null) lines.add('⚠ $sErr（不阻断构建）');

      // Bug 428 根因修复：flutter precache 会往 linux-arm64/ 写真 x64
      // gen_snapshot/impellerc，覆盖兼容层先前放的 qemu 转发脚本
      // （上游 artifacts.dart 未对 linux_arm64 做 x64 回退）。
      // 「先应用兼容层、后装 Flutter」必踩。构建前幂等重建转发层。
      final qErr = await ToolchainEnsure().qemuCompatEnsure(env: env);
      if (qErr != null) {
        lines.add('✗ $qErr');
        lines.add('  到「工具链」页 → x64 兼容层 → 重新应用后重试');
        status = BuildStatus.error;
        _ui();
        return;
      }
    }

    lines.add('▶ flutter build apk --no-shrink --release'
        ' --target-platform=android-arm64');
    lines.add('  目录：$projectsDir/$name');
    lines.add('  后端：${bare ? 'Termux 裸原生（不经 proot）' : 'Proot 容器'}');
    lines.add('');
    _ui();

    // 前置清理（Bug 420）：上次构建被强杀的孤儿 dart 进程仍持有 flutter
    // 启动锁时，新构建会永远卡在 "Waiting for another flutter command..."。
    // proot 清容器 SDK 锁；termux 清 prefix 锁（dart 路径两后端都匹配）。
    final flutterDir = bare ? TermuxPaths.flutterHome(env) : '/opt/flutter';
    final killed = await ToolchainEnsure().flutterUnlock(
      bridge,
      flutterDir,
      bare: bare,
    );
    lines.add(killed > 0
        ? '🧹 已清理残留 flutter 进程 $killed 个（启动锁已释放）'
        : '🧹 无残留 flutter 进程，锁干净');
    lines.add('');
    _ui();

    // flutter 工具硬依赖 git，缺失时先自动安装（幂等；已装秒过）。
    // termux 后端跳过：前置检查已确保 bionic git 就位。
    if (!bare) {
      final gitErr = await ToolchainEnsure().git();
      if (gitErr != null) {
        status = BuildStatus.error;
        lines.add('✗ $gitErr');
        _ui();
        return;
      }
    }

    // gradle 发行包统一走腾讯镜像（Step 8）：老工程仍是官方源 URL，哈希
    // 与 Step 3 预下载缓存不匹配会直连 services.gradle.org；幂等改写，
    // 失败仅警告不阻断（构建仍可尝试直连）。
    // termux 后端不经容器 shell，用 Dart 文件 IO 直接改写（rootfs 树内
    // 文件宿主可见可写，与容器改写同一份文件）。
    if (bare) {
      final warn = _gradleMirrorFromDart(env, name);
      if (warn != null) lines.add('⚠ $warn');
    } else {
      final mirrorErr = await ToolchainEnsure().projectGradleMirror(name);
      if (mirrorErr != null) lines.add('⚠ $mirrorErr');
    }

    // aapt2 覆盖（仅 termux）：AGP 默认从 Maven 拉 x86_64 aapt2；termux
    // aapt 组件装好后把 build 期的 aapt2 指回 prefix 里的 bionic arm64 版
    //（-P 优先级高于 gradle.properties，不污染工程文件）。
    String aapt2Override = '';
    if (bare) {
      final aapt2 = TermuxPaths.aapt2(env);
      if (File(aapt2).existsSync()) {
        aapt2Override = " -Pandroid.aapt2FromMavenOverride='$aapt2'";
      }
    }

    // pub get 多源轮换重试（Bug 423）：真机弱网（~50KB/s）下到
    // pub.flutter-io.cn 的 TLS 握手会**持续**失败——同源重试 3 次
    // （alpha.30）救不了，改为 pub 镜像逐源轮换（io.cn → 清华 → 中科大），
    // 每源 2 次，成功源 export 后供 build 内部自动 pub get 复用。
    // storage 镜像不变：engine artifacts 只有 flutter-io.cn 有代理。
    final flutterCmd =
        bare ? "'${TermuxPaths.flutterHome(env)}/bin/flutter'" : 'flutter';
    // proot：SSL_CERT_FILE 显式指向容器 CA bundle（Bug 425 双保险——
    // dart 优先读此环境变量，即使默认路径探测有偏差也能找到根证书）
    final envPart = bare
        ? TermuxPaths.envPrefix(env)
        : 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt ';
    final cmd = buildCommand(
      proj: proj,
      flutterCmd: flutterCmd,
      envPart: envPart,
      aapt2Override: aapt2Override,
    );
    final stream = await bridge.execStream(cmd, bare: bare, proroot: proroot);
    if (!stream.ok || stream.id <= 0) {
      status = BuildStatus.error;
      lines.add('✗ 启动失败：${stream.error ?? '未知错误'}');
      _ui();
      return;
    }
    _streamId = stream.id;
    _offset = 0;

    // 前台服务 + 常驻通知（alpha.31）：此后用户可自由退出页面/锁屏
    // alpha.59：标记通知归属——点击跳构建页
    BuildNotify.lastRoute = 'build';
    BuildNotify.start('构建中 · $name');
    BuildNotify.progress('正在启动构建…', 0);

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  /// 拼接构建命令：pub 多源轮换（Bug 423）+ flutter build（迭代包
  /// --no-shrink 跳过 R8，双轨策略——最终版发布包才用 R8）。
  ///
  /// 转义边界（Bug 424 教训，单测固化在 build_runner_test.dart）：
  /// - `\$src` / `\$ok` **必须**转义——shell for 循环变量，值在 shell 层
  ///   产生，Dart 插值会变成字面字符串；
  /// - `$flutterCmd` **必须** Dart 插值——值在 Dart 层产生，误转义后
  ///   shell 里没有这个变量 → 展开为空 → `pub: not found` ×6 → exit 69
  ///   （alpha.33 真机实翻车）。同一行混用两层变量时，逐个问
  ///   「这个值在哪一层产生」。
  /// 刷新 flutter 的「版本检查时间戳」，跳过它内部的 `git fetch --tags`。
  ///
  /// Bug 436（2026-09-19 真机）：每次构建都出现
  /// ```
  /// Command exited with code 128: fetch --tags
  /// error: RPC failed; HTTP 504 curl 22 ... fatal: the remote end hung up
  /// ```
  /// 并在「准备构建环境」停留很久（4% 就耗掉近 2 分钟）。
  ///
  /// 真因**不在我们的镜像配置**——git URL 重写规则实测正确
  /// （`git ls-remote --get-url` 确认已改写到 gitclone 镜像），
  /// 而是 flutter 工具自身的版本新鲜度检查：
  /// `VersionFreshnessValidator.checkAgeConsideredUpToDate = 3 days`，
  /// 距上次检查超过 3 天就会重新 `_fetchRemoteFrameworkCommitDate()`
  /// （内部即 `git fetch --tags`）。真机上该请求 504，flutter 吞掉异常
  /// 继续跑（`VersionCheckError` 是 best-effort），**但用户要先等满超时**。
  ///
  /// stamp 文件 `<cache>/flutter_version_check.stamp` 是公开的缓存协议
  /// （JSON，字段 `lastTimeVersionWasChecked`）。构建前把它刷新成当前时间，
  /// flutter 就会认为「刚检查过」而跳过网络请求——这是官方机制内的用法，
  /// 不修改 SDK 源码、不影响其它行为。
  ///
  /// 失败静默：这个优化本身不该成为新的失败点。
  static const String refreshVersionCheckStamp = r'''
C=@CACHE@
S="$C/flutter_version_check.stamp"
mkdir -p "$C" 2>/dev/null
printf '{\n  "lastTimeVersionWasChecked": "%s"\n}\n' "$(date '+%Y-%m-%d %H:%M:%S.%6N')" > "$S" 2>/dev/null
exit 0
''';

  static String buildCommand({
    required String proj,
    required String flutterCmd,
    required String envPart,
    required String aapt2Override,
  }) {
    // Bug 433：pub get 会触发 Flutter 重新下载引擎构件，把 linux-arm64/
    // 下的转发脚本盖回真 x64 二进制（真机表现：AOT 跑到 54% 后
    // shaders/*.frag 编译 SIGILL，exit -4）。因此在 pub get 之后、
    // flutter build 之前，于**同一条 shell 命令内**再断言一次转发层。
    //
    // 注意：不能用 `{ script ; }` 分组——脚本末尾带换行，`\n ; }` 在
    // dash/bash 下都是语法错误。改用 `sh -c '...'` 独立执行，既避开
    // 分组问题，也把它的输出隔离（只留最后 2 行，避免刷屏）。
    final reassert = QemuCompat.fill(QemuCompat.wrapReassertScript);
    // Bug 436：跳过 flutter 内部的 git fetch --tags 版本检查
    final stampFix = refreshVersionCheckStamp
        .replaceAll('@CACHE@', '${QemuCompat.flutterHome}/bin/cache');
    // Bug 438：构建前诊断——把「qemu 能否运行 x64」这件最基础的事实
    // 打进构建日志。真机上 shader 阶段 exit -4（SIGILL）且 stderr 为空
    // （flutter 打印 `impellerc failure: ` 后面什么都没有），说明进程被
    // 信号杀死、来不及输出。这种静默崩溃无法从 flutter 的日志反推原因，
    // 必须在构建前**主动**测一遍 qemu 链路并记录结果。
    final diag = QemuCompat.fill(QemuCompat.buildPreflightScript, proj: proj);
    // Bug 441：自愈——把被误包装的文件（如 flutter_tools.snapshot）还原。
    // 放在 reassert 之前：先修好坏文件，再重建转发层，顺序反了会把
    // 刚还原的文件又包一遍。幂等且低代价（只 mv，不动 apt/不删引擎目录），
    // 因此每次构建都跑没有副作用。
    final heal = QemuCompat.fill(QemuCompat.healScript);
    return "cd $proj && $envPart"
        'FLUTTER_ALLOW_ROOT=true '
        // Bug 436：proot 路径原先没设该变量（只有 pub get 那行内联了
        // PUB_HOSTED_URL），导致引擎/资产下载回落到官方地址。
        // profile.d/foa-env.sh 里有，但 proot -c 直接执行 sh 不读 profile。
        'FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn '
        'sh -c ${_shq(stampFix)} 2>&1 | tail -n 1; '
        // Bug 438：qemu 链路预检（输出 QEMU_CHAIN_* 供真机排障）
        //
        // Bug 443：行数上限必须**留足余量**。之前是 tail -n 12，
        // 但预检失败时每行诊断会多带一行原因（Bug 437 加的），
        // 再加 flutter 自身的 stderr 混入，12 行会把**开头几行挤掉**——
        // 而 qemu 版本/加载器状态恰恰在最前面。真机上表现为
        // "日志里没有 REASSERT="，让人以为兜底没跑。
        // 宁可多打几行，也不要丢诊断信息。
        'sh -c ${_shq(diag)} 2>&1 | tail -n 30; '
        // Bug 441：还原被误包装的文件（输出 HEALED=/DART=/SNAPSHOT=）
        // Bug 443：heal 现在会输出 HEALED + DART + SNAPSHOT 三行，
        // 再叠上可能的 stderr，tail -n 3 会截掉前面。放到 10。
        'sh -c ${_shq(heal)} 2>&1 | tail -n 10; '
        'ok=0; '
        'for src in https://pub.flutter-io.cn '
        'https://mirrors.tuna.tsinghua.edu.cn/dart-pub '
        'https://mirrors.ustc.edu.cn/dart-pub; do '
        'for i in 1 2; do '
        'if PUB_HOSTED_URL=\$src $flutterCmd pub get; '
        'then ok=1; break 2; fi; sleep 3; done; done; '
        '[ "\$ok" = 1 ] || exit 69; '
        'export PUB_HOSTED_URL=\$src; '
        // Bug 433 转发层再断言（pub get 后、build 前，同一 shell）
        // Bug 443：reassert 输出 REASSERT= + REASSERT_DART= 两行，
        // 且 `gen` 生成失败时会有 stderr。tail -n 2 太紧（会被 stderr
        // 顶掉正常行），放到 10 确保两行都在。
        // ---------------- Bug 444：把 build 内部的构件下载提前 ----------------
        // 真机链路（已由 flutter_tools 源码 + 沙箱目录结构双向证实）：
        //   AOT 用的 gen_snapshot 路径 = `android-arm64-release/<host>/gen_snapshot`
        //   （artifacts.dart `_getAndroidArtifactPath`：join(engineDir,
        //    hostPlatformName, name)），hostPlatformName 由 `uname -m` 决定，
        //   真机 Android 上 = `linux-arm64`。
        //   而官方**没有** arm64 版的 android gen_snapshot
        //   （artifacts.dart 的 TODO：flutter/flutter#152281），
        //   `linux-arm64/` 目录下放的就是 x86_64 二进制 —— 必须靠转发脚本。
        // 问题：flutter build 在 AOT 之前会检查构件是否就位、缺失则补下载。
        //   （⚠️ 日志里的 `Flutter assets will be downloaded from ...` 是
        //   **常驻提示**，构件已缓存时也会打印 —— 沙箱本次构建就打了这行
        //   而并未真的下载。不能用它判断下载是否发生，别再拿它当证据。）
        //   一旦真的下载，就会把 `linux-arm64/{gen_snapshot,impellerc,...}`
        //   覆写成**裸 x86_64 ELF**，盖掉 reassert 刚放好的转发脚本 → SIGILL。
        //   触发条件 = 构件缓存缺失（卸载重装 / 清数据 / 首次构建），
        //   这也是"之前能构建、卸载重装后必崩"的原因。
        // 修法：先跑 precache 让**下载发生在 reassert 之前**，reassert 再
        //   重建转发层；此时构件已缓存，build 内部不会再下载 → 不会再覆盖。
        //   `--android_gen_snapshot` 精确覆盖 AOT 那两个工具，universal
        //   （impellerc/font-subset）默认 true 会一并带上。
        // ⚠️ 这里的 `| tail -n 5` 是**故意**吞掉退出码做容错：precache
        //   失败（网络/镜像抖动）不该中断构建，后面还有兜底重试。
        //   （对比 Bug 443：那次是无意中被管道吞掉退出码，性质不同。）
        'echo "---- 预取引擎构件（把 build 内部的下载提前）----"; '
        '$flutterCmd precache --android_gen_snapshot 2>&1 | tail -n 5; '
        // ---------------- Bug 445：跑完 precache 立刻重建转发层 ----------------
        // 真机 alpha.50 的日志证明：**下载发生在 build 内部的 AOT 之前**，
        // 我上一版把 precache 放在 reassert 前面**没有拦住它** ——
        // build 自己又下了一遍（它有自己的完整度判定，precache 的精简集
        // 满足不了），照样盖掉 linux-arm64/。所以紧接着 precache 再断言一次，
        // 确保 build 启动时转发层一定是完好的。
        // （⚠️ 这只是"多一道保险"，真正的根治是 build 之后的 heal + 重启构建；
        //   见下面 Bug 445 段。别指望这一步能单独解决问题。）
        'sh -c ${_shq(reassert)} 2>&1 | tail -n 10; '
        '$flutterCmd build apk --no-shrink --release '
        '--target-platform=android-arm64$aapt2Override; '
        // Bug 443：构建失败时**再快照一次** AOT 工具链指纹。
        // 目的是把「构建前 vs 构建后」的转发层状态摆在一起对比：
        // 若构建前是 wrapper、构建后变 RAW_ELF，就能确证是
        // flutter build 内部下载引擎构件把转发层覆盖了（Bug 428 的
        // 变体：precache 发生在 build 过程中，而不是 pub get 阶段）。
        // 只在失败时跑，成功时不留噪音。
        //
        // ---------------- Bug 445：构建后重新取指纹（不是复用旧变量！）----
        // ⚠️ alpha.50 的一处真 bug：这里原写成
        //     fp=$(sh -c '<diag>' | grep -E "AOT_FP=")
        //   但 `fp` 在**上面第一处诊断**已经赋值过了，而这里取的是
        //   **同样的诊断**，只是没走 tail 截断。真机日志里那对
        //   `AOT_FP=impellerc=wrapper` + `AOT_FP=impellerc=RAW_ELF`
        //   不是"两个不同时刻的值"，而是**一次执行的输出被印了两遍**
        //   （diag 只跑了一次，`tail -n 30` 截掉了前半、完整输出在失败段）。
        //   两个文件的四次出现、以及 `QEMU_CHAIN_*` 行只出现一次，
        //   都与此吻合。
        //   后果：我还是不知道"构建后"到底是不是 RAW_ELF。
        //   **所以必须真的重取一次，而且要把新指纹打进日志做对比。**
        //   判定放到 heal+重启之后（见下），因为重启后的构建才是最终事实。
        'brc=\$?; if [ "\$brc" != 0 ]; then '
        'echo "---- 构建后工具链指纹（重新采集，对比上面的 AOT_FP）----"; '
        // Bug 448：这里原来只 grep "AOT_FP="，把 AOT_LOAD / AOT_LOAD_DEF
        // 裁决行全滤掉了 —— alpha.53 真机失败后本该出现的两个退出码
        // 恰恰是最需要的证据，却被这一层过滤吞了。裁决行必须全量透传。
        'fp=\$(sh -c ${_shq(diag)} 2>&1 | grep -E "AOT_FP=|AOT_LOAD"); '
        'echo "\$fp"; '
        // ---------------- Bug 445：heal + 重启构建 ----------------
        // 真机实测（alpha.50 日志）：
        //   FOA_HEAL=转发层在构建中被覆盖，重建后重试一次
        //   REASSERT=0
        //   REASSERT_DART=0
        // **rebuild（重启构建）两步都返回 0，一个文件都没重建** ——
        // 因为 AOT 失步**没有停掉整个构建**：`Target android_aot_..._failed`
        // 被 flutter 记录后，构建继续跑到 shader/资产阶段才整体失败，
        // 而这个过程中 gen_snapshot 已经**产出**了 app.so（Dart AOT 的
        // 失败是非致命的），把文件恢复成了正常的 x64 ELF 形态。
        // 于是 reassert 一看"已是正常形态"就跳过 → 覆盖状态被固化 →
        // 重启构建仍然崩。
        // 根因：**"看形态判定"的幂等修复，遇上"被覆盖后形态依然合法"
        //   的情况会静默失效。**
        // 修法（两件事缺一不可）：
        //   ① heal：把 linux-arm64/ 下的转发位**无条件**删除并由其
        //      linux-x64/ 对应文件重新生成（该目录里的东西**本来就该
        //      全是转发脚本**，不存在"合法的裸 ELF"，所以无条件删是安全的、
        //      比看形态更可靠）；
        //   ② 重启构建：让 AOT 用重建后的转发层重跑一遍。
        // ⚠️ 为什么是"**重启构建**"而不是"重跑 build"：
        //   flutter 的增量构建会看到 app.so「已存在且比输入新」，直接跳过
        //   AOT target，转发层修好了也不会重新编译。必须造一个输入变化
        //   （删掉 app.dill / app.so）把 AOT 逼出来。
        // ⚠️ 判据只看 **BAD**，不能再 grep "RAW_ELF"（Bug 445）：
        //   `linux-x64/` 下的真身**本来就该是** RAW_ELF，
        //   用 RAW_ELF 当"被覆盖"的判据会**恒为真**、白跑一轮自愈。
        //   现在诊断给每行标了角色与是否合格，只看 BAD 即可。
        'if echo "\$fp" | grep -q "BAD("; then '
        'echo "FOA_HEAL=检测到转发位异常（见上面 BAD 行），重建转发层并重启构建"; '
        '$flutterCmd clean --no-version-check > /dev/null 2>&1; '
        'sh -c ${_shq(reassert)} 2>&1 | tail -n 10; '
        '$flutterCmd build apk --no-shrink --release '
        '--target-platform=android-arm64$aapt2Override; brc=\$?; '
        'fi; fi; exit \$brc';
  }

  /// 单引号包裹一段 shell 片段（内部单引号用 '\'' 转义）。
  /// 用于把多行脚本安全地塞进 `sh -c '...'`。
  static String _shq(String s) =>
      "'${s.replaceAll("'", "'\\''")}'";

  /// 清理构建缓存（flutter clean，工作台打包配置卡的快捷操作）：
  /// 返回 null = 成功，否则返回错误文案。构建中拒绝（防清掉正在
  /// 使用的 build 目录）。
  Future<String?> clean(
    String name,
    EnvInfo env,
    BuildBackend backend, {
    ContainerLayer layer = ContainerLayer.proot,
  }) async {
    if (building) return '正在构建中，不能清理缓存';
    final bare = backend == BuildBackend.termux;
    final proroot = !bare && layer == ContainerLayer.proroot;
    final projectsDir = bare ? '${env.rootfsPath}/root/projects' : _projectsDir;
    final flutterDir = bare ? TermuxPaths.flutterHome(env) : '/opt/flutter';
    final flutterCmd =
        bare ? "'$flutterDir/bin/flutter'" : 'flutter';
    final envPart = bare ? TermuxPaths.envPrefix(env) : '';
    final r = await bridge.exec(
      'cd $projectsDir/${_q(name)} && $envPart'
      'FLUTTER_ALLOW_ROOT=true $flutterCmd clean',
      timeoutSec: 300,
      bare: bare,
      proroot: proroot,
    );
    if (r.exitCode != 0) {
      final out = (r.stdout.isNotEmpty ? r.stdout : r.stderr).trim();
      return 'flutter clean 失败（exit ${r.exitCode}）'
          '${out.isEmpty ? '' : '：${out.split('\n').last}'}';
    }
    return null;
  }

  /// termux 后端的 gradle wrapper 镜像改写：不经 shell，Dart 直接读写
  ///（rootfs 树内文件宿主可见）。幂等；非 Flutter 工程静默跳过。
  String? _gradleMirrorFromDart(EnvInfo env, String name) {
    try {
      final f = File('${env.rootfsPath}/root/projects/$name'
          '/android/gradle/wrapper/gradle-wrapper.properties');
      if (!f.existsSync()) return null;
      final t = f.readAsStringSync();
      if (t.contains('mirrors.cloud.tencent.com')) return null;
      f.writeAsStringSync(t.replaceAll(
          'services.gradle.org/distributions',
          'mirrors.cloud.tencent.com/gradle'));
      return null;
    } catch (e) {
      return 'gradle 镜像配置失败：$e';
    }
  }

  // ============================ 轮询循环 ============================

  /// 500ms 守护轮询：页面在时同步刷 UI，页面不在时只喂通知。
  Future<void> _poll() async {
    final poll = await bridge.execStreamPoll(_streamId, _offset);
    if (!poll.ok) {
      _timer?.cancel();
      status = BuildStatus.error;
      prog.markHalted();
      lines.add('✗ 轮询失败：${poll.error ?? '未知错误'}');
      lines.add('  进度已冻结在 ${prog.percent}%（任务已失联，请重试）');
      _ui();
      BuildNotify.finish('✗ 构建失联（exit 未知）· 点开查看日志');
      return;
    }
    _appendChunk(poll.chunk);
    _offset = poll.len;
    // 进度插值：日志推进阶段，时间推进阶段内百分比
    prog.tick();
    final started = _startedAt;
    if (started != null) {
      elapsedSec = DateTime.now().difference(started).inSeconds;
    }
    // alpha.58：Built 已命中（构建+签名本体完成）而 flutter 进程 hang
    // 不退出 → 宽限到期后强制按成功收尾（产物路径从日志/文件系统确认）。
    if (status == BuildStatus.building &&
        builtGraceElapsed(builtAt: _builtAt, now: DateTime.now())) {
      lines.add('ℹ flutter 工具 Built 后未退出（偶发 hang，已等待 '
          '$builtGraceSec 秒）——按构建成功收尾');
      await _finish(0);
      return;
    }
    if (!poll.running) {
      _timer?.cancel();
      await _finish(poll.exitCode);
    } else {
      _ui();
      _notifyProgress();
      _scroll();
    }
  }

  void _appendChunk(String chunk) {
    final clean = chunk.replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '');
    partial += clean;
    final parts = partial.split('\n');
    partial = parts.removeLast();
    for (final p in parts) {
      // 进度条用 \r 原地刷新：只保留最后一段
      final segs = p.split('\r');
      final line = segs.last;
      lines.add(line);
      // 进度识别吃"清洗后"的行：ANSI 已去、\r 段已取末段
      prog.feed(line);
      // alpha.58：Built = Gradle 打包+签名已完成（Built 打印在签名之后）。
      // 立即提示，避免用户把"flutter 收尾 hang"误读成"卡在签名"。
      if (_builtAt == null && line.contains(builtMarker)) {
        _builtAt = DateTime.now();
        lines.add('✓ Gradle 打包+签名完成，等待 flutter 工具收尾…'
            '（若 ${builtGraceSec}s 内未自动结束将按成功收尾）');
      }
      _feedErrorBreakdown(line);
    }
    if (lines.length > _maxLines) {
      lines.removeRange(0, lines.length - _maxLines);
      lines[0] = '[日志截断，仅显示最近 $_maxLines 行]';
    }
  }

  /// 通知进度（节流：阶段与百分比都没变就跳过）。
  void _notifyProgress() {
    final pct = prog.percent;
    final stage = prog.stage.label;
    if (pct == _lastNotifPct && stage == _lastNotifStage) return;
    _lastNotifPct = pct;
    _lastNotifStage = stage;
    BuildNotify.progress('$stage · $pct% · 已用 ${fmtDur(elapsedSec)}', pct);
  }

  /// 从日志里提取"失败类型"，供进度条下方给出可执行的修复建议。
  /// 只识别本仓库已知的失败模式（见 dev-handbook §十 工具链 / §十一 体积）。
  ///
  /// [exposeFeedForTest] 为仅测试可见的转发入口：分诊表是纯文本匹配逻辑，
  /// 沙箱出包不走 BuildRunner、analyze 覆盖不到运行时识别，只能靠单测
  /// 固化（同 Bug 424 的 buildCommand 文本断言思路）。
  @visibleForTesting
  void debugFeedForTest(String line) => _feedErrorBreakdown(line);

  void _feedErrorBreakdown(String line) {
    final l = line.toLowerCase();
    String? tip;
    // Bug 441：优先判这个——它是最具体的信号，且和下面 'shared libraries'
    // 的通配提示是同一句话的前缀，必须排在前面才不会被吃掉。
    //
    // `invalid ELF header` 只可能来自动态加载器（ld.so）：说明某个
    // **不是 ELF 的东西**被当成了可执行程序。真机最典型的受害者是
    // `flutter_tools.snapshot`（Dart app-jit 快照，头 dc dc f6 f6）。
    if (l.contains('invalid elf header')) {
      tip = '工具链文件被误包装成转发脚本（非 ELF 被送进加载器）：'
          '构建前会自动还原（HEALED=）；若本条仍出现，到「工具链」页执行'
          '一次「一键应用」重建转发层后重试（Bug 441）';
    } else if (l.contains('illegal instruction')) {
      // Bug 442：**这条必须排在 'exit code -4' 那组之前**。
      // pub get 阶段的 SIGILL 与 AOT 阶段的 SIGILL 是完全不同的两件事：
      //   - AOT/shader 阶段（有 'impellerc' / 'snapshot generator' 上下文）
      //     → 引擎转发层被 precache 覆写，是 Bug 428/437
      //   - 但 `Illegal instruction` 出现在 **pub get 前后、无编译上下文**
      //     → dart-sdk/bin 的转发层丢了，arm64 直接跑 x64 的 dart，是 Bug 442
      // 若不加这个分支，用户看到的是"重新应用兼容层"这种无关建议。
      tip = '工具链入口（dart-sdk/bin）的转发层丢失：arm64 直接执行了 x64 的 '
          'dart。构建前会自动重建（看日志 REASSERT_DART=）——若 REASSERT_DART '
          '为 0 而本条仍出现，到「工具链」页「重新应用」x64 兼容层后重试（Bug 442）';
    } else if (l.contains('exec format error')) {
      tip = '架构不匹配：x64 工具未经 qemu 转发（工具链页 → x64 兼容层 → 重新应用）';
    } else if (l.contains(': not found')) {
      tip = '命令缺失（sh: xxx: not found）：容器组件不全——到「工具链」页'
          '核对 Flutter / JDK / SDK 组件后重试（alpha.33 的 pub: not found '
          '属构建器自身 bug，alpha.34 已修）';
    } else if (l.contains('shared libraries')) {
      tip = '多架构运行库缺失：x64 兼容层 → 重新应用';
    } else if (l.contains('no space left')) {
      tip = '磁盘空间不足：清理 build/ 与 .gradle 缓存后重试';
    } else if (l.contains('snapshot generator failed') ||
        l.contains('aot snapshotter exited') ||
        l.contains('impellerc failure') ||
        l.contains('shadercompilerexception') ||
        l.contains('failed with exit code -4')) {
      tip = 'AOT/shader 编译崩溃（exit -4 = SIGILL）：Flutter 只发 x86_64 '
          '宿主版 gen_snapshot/impellerc，arm64 真机需 qemu 转发；'
          'flutter precache 会覆写转发脚本（Bug 428）。alpha.39 起构建前'
          '自动重建转发层。若本条仍出现：到「工具链」页重新应用 x64 兼容层';
    } else if (l.contains('exit value 132') ||
        l.contains('sigill') ||
        l.contains('sdkmanager')) {
      tip = 'sdkmanager 崩溃（exit 132 = SIGILL）：Flutter 插件自动补装 '
          'NDK 时在 Android arm64 上启 JVM 触发非法指令。alpha.38 起构建前'
          '自动写 NDK 占位使插件跳过补装（Bug 427）。若本条仍出现：到'
          '「工具链」页卸载并重装 Android SDK 组件后重试';
    } else if (l.contains('prefer settings repositories') ||
        l.contains('was added by settings file')) {
      tip = 'Gradle 仓库注入与 Flutter 新模板 PREFER_SETTINGS 冲突：'
          'alpha.37 起构建前会自动把旧版 init.gradle 覆写为无注入形态'
          '（Bug 426）。若本条仍出现：到「工具链」页 → Gradle 镜像 → '
          '重新「一键应用」后重试';
    } else if (l.contains('could not resolve') || l.contains('sslhandshake')) {
      tip = '依赖下载失败：检查镜像源（工具链页 → Gradle 镜像）';
    } else if (l.contains('tls error') || l.contains('failed to update packages')) {
      tip = 'pub 拉取 TLS 失败：alpha.36 起构建前会自动确保容器根证书'
          '（此前 minbase rootfs 缺 CA 导致所有 https 源必失败——Bug 425）。'
          '若本条仍出现：已自动按 pub 镜像轮换重试（官方 io.cn → 清华 → '
          '中科大），仍全败多为网络到镜像站丢包——切换网络（WiFi/流量互换）'
          '后重试效果最好';
    } else if (l.contains('waiting for another flutter command')) {
      tip = 'Flutter 启动锁被占用：残留进程未清干净——完全杀掉 App 重开再试'
          '（alpha.30 起构建前会自动清理）';
    } else if (l.contains('snapshot not compatible')) {
      tip = 'flutter_tools.snapshot 架构不匹配：x64 兼容层未接管 dart-sdk';
    }
    if (tip != null && !hints.contains(tip)) hints.add(tip);
  }

  Future<void> _finish(int? code) async {
    if (code == 0 && active != null) await _locateApk(active!);
    final ok = code == 0 && apkGuest != null;
    if (ok) {
      // 只有"成功且产物就位"才授予 100%，不动用插值
      prog.markDone();
    } else {
      prog.markHalted();
    }
    status = ok ? BuildStatus.done : BuildStatus.error;
    if (code == 0 && apkGuest == null) {
      lines.add('✗ 构建成功但未找到 APK 产物');
    } else if (code != 0) {
      lines.add('✗ 构建失败（exit ${code ?? -1}）· 已运行 ${fmtDur(elapsedSec)}'
          ' · 进度冻结在 ${prog.percent}%');
    } else {
      lines.add('');
      lines.add('✓ 构建成功：$apkGuest');
      lines.add('  总耗时 ${fmtDur(elapsedSec)}');
    }
    _ui();
    _scroll();
    // 结果通知（服务停、通知留给用户，点击回构建页）
    BuildNotify.finish(ok
        ? '✓ 构建成功 · 总耗时 ${fmtDur(elapsedSec)}'
        : '✗ 构建失败（exit ${code ?? -1}）· 点开查看日志');
  }

  /// 在容器内查找 flutter-apk 产物（优先 app-release.apk）。
  Future<void> _locateApk(String name) async {
    final dir = '$_projectsDir/$name/build/app/outputs/flutter-apk';
    final list = await _fb.browse(dir);
    if (!list.ok) return;
    final apks = list.entries
        .where((e) => !e.isDir && e.name.endsWith('.apk'))
        .toList();
    if (apks.isEmpty) return;
    FsBrowserEntry? pick;
    for (final a in apks) {
      if (a.name == 'app-release.apk') {
        pick = a;
        break;
      }
    }
    pick ??= apks.first;
    apkGuest = '$dir/${pick.name}';
  }

  /// 用户取消：杀流式进程 + 终态落日志 + 结果通知。
  Future<void> cancel() async {
    _timer?.cancel();
    await bridge.execStreamStop(_streamId);
    status = BuildStatus.cancelled;
    prog.markHalted();
    lines.add('');
    lines.add('⏹ 已取消（用户中止）· 已运行 ${fmtDur(elapsedSec)}');
    _ui();
    _scroll();
    BuildNotify.finish('⏹ 已取消 · 已运行 ${fmtDur(elapsedSec)}');
  }
}
