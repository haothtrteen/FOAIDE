import 'dart:async';

import '../env/proot_bridge.dart';
import 'native_arm64.dart';

/// 预取哪一套引擎构件。
///
/// 为什么分档：debug 与 release 用的不是同一批 Maven 构件
/// （`io.flutter:arm64_v8a_debug` vs `arm64_v8a_release`），
/// 而 debug 那批**大得多**：
///
/// | 构件 | 体积（实测 Content-Length） |
/// |---|---|
/// | `arm64_v8a_debug` | 180.6 MB |
/// | `arm64_v8a_release` | 42.2 MB |
/// | `flutter_embedding_debug` | 1.6 MB |
/// | `flutter_embedding_release` | 1.6 MB |
///
/// 手机上第一次打 debug 包要现拉 182MB（弱网下十几分钟到一小时），
/// 而这段下载**发生在 gradle 内部**，用户只看到进度条卡住。
/// 默认档位改成 debug 之后（alpha.94）这件事必须能提前做掉。
enum PrefetchMode {
  /// 只预取 debug 档（默认档位需要它）。
  debug,

  /// 只预取 release 档。
  release,

  /// 两档都预取。
  both;

  /// gradle 里要 resolve 的配置名（与脚本里 create 的名字对应）。
  List<String> get configurations => switch (this) {
        PrefetchMode.debug => const ['flutterDebug'],
        PrefetchMode.release => const ['flutterRelease'],
        PrefetchMode.both => const ['flutterDebug', 'flutterRelease'],
      };

  /// 按钮上的字数短标签。
  String get label => switch (this) {
        PrefetchMode.debug => 'debug',
        PrefetchMode.release => 'release',
        PrefetchMode.both => '两档',
      };

  /// 预估下载量（给人看的，不是精确值）。
  String get sizeHint => switch (this) {
        PrefetchMode.debug => '约 182 MB',
        PrefetchMode.release => '约 44 MB',
        PrefetchMode.both => '约 226 MB',
      };
}

/// 引擎构件预取（alpha.94）。
///
/// ## 为什么不是 `flutter precache --android_maven`
///
/// 那是 flutter 官方为此提供的开关，但**在 Flutter 3.47.4 上它是空操作**：
/// `AndroidMavenArtifacts` 这个 ArtifactSet 类还在
/// （`packages/flutter_tools/lib/src/flutter_cache.dart:415`），
/// 却**没有任何地方实例化它**，于是 `precache --android_maven` 跑完
/// exit 0、一行输出都没有（沙箱实测）。
///
/// 它配套的 `packages/flutter_tools/gradle/resolve_dependencies.gradle.kts`
/// 倒是还在，但那份脚本的调用方式 `gradle -b <file>` 也**已经不能用**：
/// Gradle 9 删掉了 `-b/--build-file`（沙箱实测 `Unknown command-line
/// option '-b'`）。两条官方路径都断了。
///
/// 所以这里自己拼一份等价的 gradle 脚本（Groovy DSL，与官方那份声明的
/// 依赖坐标完全一致），在临时目录里跑 `resolveDependencies`。
/// 沙箱实测：**BUILD SUCCESSFUL，182MB 真下载**，
/// `~/.gradle/caches/modules-2/files-2.1/io.flutter/` 下出现
/// `arm64_v8a_debug` 与 `flutter_embedding_debug`。
///
/// ## 与官方脚本的两处有意差异（都写在这里，别当疏漏）
///
/// 1. **只拉 arm64**：官方那份还拉 armeabi_v7a / x86 / x86_64 的 debug
///    包，而 FOA 固定 `--target-platform=android-arm64`，其余三个 ABI
///    永远用不到。少了它们，debug 档从 ~600MB 降到 182MB。
/// 2. **仓库列表换成国内可达的**：`io.flutter:*` 只在
///    `download.flutter.io` 上（阿里云没有镜像），所以第一条是
///    `FLUTTER_STORAGE_BASE_URL/download.flutter.io`；
///    `flutter_embedding_*` 还传递依赖 androidx（实测解析时会去抓
///    `androidx.exifinterface:1.4.1`），国内直连 dl.google.com 与
///    mavenCentral 都不通，所以补了阿里云两仓兜底。
///
/// ⚠️ 沙箱实测过的另一件事：`storage.googleapis.com` 在本环境**完全不可达**
/// （SSL 握手直接断），所以 `FLUTTER_STORAGE_BASE_URL` 必须显式给国内镜像，
/// 不能指望默认值。
/// 这个类只负责**拼脚本和解析输出**（纯函数），跑命令的是 [PrefetchJob]
/// ——分开是为了让脚本能在单测里直接断言，不碰 MethodChannel。
class ArtifactPrefetch {
  /// 临时工作目录（预先下载完就能整个删掉）。
  static const String workDir = '/tmp/foa-prefetch';

  /// 容器里的 Flutter SDK 根（引擎版本号从这里读）。
  static const String flutterRoot = '/opt/flutter';

  /// 国内存储镜像（与 build_runner 里给 build 用的是同一个）。
  static const String storageMirror = 'https://storage.flutter-io.cn';

  /// Gradle 分发包镜像（与 MirrorConfigurator 用同一个 URL——
  /// wrapper 的缓存目录名是 base36(md5(url))，同 URL 才能命中预下载）。
  static const String gradleDistUrl =
      'https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip';

  // ================= 纯函数：脚本 =================

  /// 脚本里被 resolve 的 gradle 配置名（测试与脚本共用同一份真源）。
  static String modesVar(PrefetchMode mode) => mode.configurations.join(' ');

  /// 生成的 gradle 脚本正文（Groovy DSL）。
  ///
  /// 坐标与官方 `resolve_dependencies.gradle.kts` 一致，只有仓库列表和
  /// ABI 范围不同（差异理由见类注释）。
  static String gradleScript() => '''
repositories {
    maven { url = uri(System.getenv("FOA_BASE") + "/download.flutter.io") }
    maven { url = uri("https://maven.aliyun.com/repository/google") }
    maven { url = uri("https://maven.aliyun.com/repository/public") }
}
configurations.create("flutterDebug")
configurations.create("flutterRelease")
dependencies {
    add("flutterDebug", "io.flutter:flutter_embedding_debug:1.0.0-" + System.getenv("FOA_ENGINE"))
    add("flutterDebug", "io.flutter:arm64_v8a_debug:1.0.0-" + System.getenv("FOA_ENGINE"))
    add("flutterRelease", "io.flutter:flutter_embedding_release:1.0.0-" + System.getenv("FOA_ENGINE"))
    add("flutterRelease", "io.flutter:arm64_v8a_release:1.0.0-" + System.getenv("FOA_ENGINE"))
}
tasks.register("resolveDependencies") {
    doLast {
        System.getenv("FOA_MODES").split(" ").each {
            configurations.getByName(it).resolve()
        }
    }
}
''';

  /// 完整 shell 脚本（交给 `ProotBridge.execStream`）。
  ///
  /// 约定（与 git_panel / signing 同源）：出错先打 `ERR=` 再非零退出；
  /// 成功打 `PREFETCH_OK`。解析函数在下面，都是纯函数。
  static String script(PrefetchMode mode) {
    // 引擎版本号从 SDK 里读，不写死——换 SDK 版本后构件版本跟着变，
    // 写死会拉到 404（或更糟：拉到旧版本的 so）。
    return ''
        'FR=$flutterRoot\n'
        'EV=\$(cat \$FR/bin/cache/engine.stamp 2>/dev/null | tr -d " \\t\\n")\n'
        'if [ -z "\$EV" ]; then '
        'echo "ERR=读不到引擎版本号：\$FR/bin/cache/engine.stamp 为空或不存在"; exit 3; fi\n'
        'RM=\$(cat \$FR/bin/cache/engine.realm 2>/dev/null | tr -d " \\t\\n")\n'
        '[ -z "\$RM" ] || RM="\$RM/"\n'
        // ⚠️ 必须显式给镜像：默认 storage.googleapis.com 在国内完全不可达
        // （沙箱实测 SSL 握手直接断），不设就是白等超时。
        ': \${FLUTTER_STORAGE_BASE_URL:=$storageMirror}\n'
        'export FLUTTER_STORAGE_BASE_URL\n'
        'echo "ENGINE=\$EV"\n'
        'echo "BASE=\$FLUTTER_STORAGE_BASE_URL/download.flutter.io"\n'
        // ⚠️ JAVA_HOME 必须显式设：gradle 启动时找不到 java 就直接退出
        // （沙箱实测 `ERROR: JAVA_HOME is not set and no 'java' command
        // could be found`，exit 1）。容器里 /etc/profile.d/foa-env.sh 有
        // 这个变量，但 proot -c 直接执行 sh **不读 profile**（build_runner
        // 里那条 FLUTTER_STORAGE_BASE_URL 的注释是同一个坑）。
        // 已设过就尊重原值，不硬盖。
        'export JAVA_HOME=\${JAVA_HOME:-${NativeArm64.jdkHome}}\n'
        'export PATH="\$JAVA_HOME/bin:\$PATH"\n'
        'if [ ! -x "\$JAVA_HOME/bin/java" ]; then '
        'echo "ERR=容器里没有可用的 java：\$JAVA_HOME/bin/java（先在工具链页装 JDK）"; '
        'exit 5; fi\n'
        'D=$workDir\n'
        'rm -rf \$D; mkdir -p \$D\n'
        // ---- 找一个能跑的 gradle（三条路，按代价从小到大）----
        // ① PATH 上就有的 gradle；② 已解压的 wrapper 分发包
        // （首次构建后必然存在）；③ 用 SDK 自带的 gradle wrapper 现搭一个
        // （分发包走腾讯云镜像，与 MirrorConfigurator 同 URL → 命中预下载缓存）。
        'G=\$(command -v gradle 2>/dev/null)\n'
        'if [ -z "\$G" ]; then '
        'G=\$(ls -d /root/.gradle/wrapper/dists/gradle-*/*/gradle-*/bin/gradle '
        '2>/dev/null | sort -V | tail -n 1); fi\n'
        'if [ -z "\$G" ] && [ -f \$FR/bin/cache/artifacts/gradle_wrapper/gradlew ]; then '
        'cp \$FR/bin/cache/artifacts/gradle_wrapper/gradlew \$D/gradlew; '
        'mkdir -p \$D/gradle/wrapper; '
        'cp \$FR/bin/cache/artifacts/gradle_wrapper/gradle/wrapper/gradle-wrapper.jar '
        '\$D/gradle/wrapper/ 2>/dev/null; '
        'printf %s\\\\n "distributionUrl=$gradleDistUrl" > \$D/gradle/wrapper/gradle-wrapper.properties; '
        'chmod +x \$D/gradlew; G=\$D/gradlew; fi\n'
        'if [ -z "\$G" ]; then '
        'echo "ERR=容器里找不到 gradle（也没找到 wrapper 分发包）：先完整构建一次再预取"; '
        'exit 4; fi\n'
        'echo "GRADLE=\$G"\n'
        // heredoc 用**引号形式**定界：正文里的 \$ 全部原样落盘，
        // 由 gradle 在运行期通过 getenv 取值，不经过 shell 展开。
        'cat > \$D/build.gradle <<\'FOA_PREFETCH_EOF\'\n'
        '${gradleScript()}'
        'FOA_PREFETCH_EOF\n'
        'export FOA_ENGINE=\$EV\n'
        'export FOA_BASE=\$FLUTTER_STORAGE_BASE_URL\n'
        'export FOA_MODES="${modesVar(mode)}"\n'
        'echo "---- 开始预取（${mode.label}：${mode.sizeHint}）----"\n'
        'cd \$D && \$G --project-cache-dir \$D resolveDependencies > \$D/out.log 2>&1\n'
        'rc=\$?\n'
        // 失败时 gradle 的错误在 out.log 里；不 tail 出来的话
        // 用户只看到一句"失败"，没法判断是网络还是坐标问题。
        'tail -n 25 \$D/out.log\n'
        'if [ \$rc -ne 0 ]; then echo "ERR=预取失败（gradle exit \$rc）"; exit \$rc; fi\n'
        'echo "PREFETCH_OK"\n';
  }

  // ================= 纯函数：解析 =================

  /// 是否成功（脚本末尾的标记）。
  static bool isOk(String out) => out.contains('PREFETCH_OK');

  /// 捞 `ERR=` 行（脚本约定：出错先打 ERR= 再退出）。
  static String? errorOf(String out) {
    for (final l in out.split('\n')) {
      final t = l.trim();
      if (t.startsWith('ERR=')) return t.substring(4).trim();
    }
    return null;
  }

  /// 引擎版本号（`ENGINE=`）。
  static String engineOf(String out) => _field(out, 'ENGINE=');

  /// 实际用到的 gradle 可执行文件路径（`GRADLE=`，排障用）。
  static String gradleOf(String out) => _field(out, 'GRADLE=');

  static String _field(String out, String key) {
    for (final l in out.split('\n')) {
      final t = l.trim();
      if (t.startsWith(key)) return t.substring(key.length).trim();
    }
    return '';
  }
}

/// 预取任务（流式）：边下边把 gradle 的输出喂给 UI。
///
/// 不用一次性 `exec` 是因为这段可能跑很久——手机上拉 182MB 十几分钟起步，
/// 而 `exec` 是一次性返回、超时就丢结果；`execStream` + 轮询才能让用户
/// 看到"正在下"而不是对着转圈猜。
class PrefetchJob {
  PrefetchJob(this._bridge);

  final ProotBridge _bridge;

  Timer? _timer;
  int _id = 0;
  int _offset = 0;

  final List<String> lines = <String>[];
  bool running = false;
  bool ok = false;
  String error = '';

  /// 输出有增量（或状态变化）时回调，UI 用来 setState。
  void Function()? onChanged;

  static const int _maxLines = 200;

  Future<void> start(PrefetchMode mode) async {
    if (running) return;
    lines
      ..clear()
      ..add('\$ 预取 ${mode.label} 构件（${mode.sizeHint}）…');
    ok = false;
    error = '';
    final start = await _bridge.execStream(
      ArtifactPrefetch.script(mode),
      timeoutSec: 7200,
    );
    if (!start.ok || start.id <= 0) {
      lines.add('✗ 启动失败：${start.error ?? '未知错误'}');
      _changed();
      return;
    }
    _id = start.id;
    _offset = 0;
    running = true;
    _changed();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _poll());
  }

  Future<void> _poll() async {
    if (!running) return;
    final p = await _bridge.execStreamPoll(_id, _offset);
    if (p.chunk.isNotEmpty) {
      _offset = p.len;
      for (final l in p.chunk.replaceAll('\r', '').split('\n')) {
        if (l.trim().isEmpty) continue;
        lines.add(l);
        if (lines.length > _maxLines) lines.removeAt(0);
      }
      _changed();
    }
    if (!p.running) {
      await _finish(p.exitCode ?? 1);
    } else if (p.error != null) {
      await _finish(1);
    }
  }

  Future<void> _finish(int code) async {
    _timer?.cancel();
    _timer = null;
    running = false;
    final out = lines.join('\n');
    ok = code == 0 && ArtifactPrefetch.isOk(out);
    if (!ok) {
      error = ArtifactPrefetch.errorOf(out) ??
          (code == 0 ? '预取未完成（没拿到成功标记）' : '预取失败（exit $code）');
    }
    _changed();
  }

  /// 用户中途取消。
  Future<void> stop() async {
    if (!running) return;
    await _bridge.execStreamStop(_id);
    _timer?.cancel();
    _timer = null;
    running = false;
    lines.add('已取消。');
    _changed();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _changed() => onChanged?.call();
}
