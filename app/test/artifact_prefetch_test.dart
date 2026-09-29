import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/artifact_prefetch.dart';

/// 引擎构件预取（alpha.94）的守卫测试。
///
/// 这一组的核心目标是**把三条已经断掉的官方路径钉死**，防止以后有人
/// 又把它们捡回来：
/// 1. `flutter precache --android_maven` 在 Flutter 3.47.4 上是空操作
///    （`AndroidMavenArtifacts` 定义了但没人实例化）；
/// 2. 它依赖的 `gradle -b <file>` 在 Gradle 9 已被删除；
/// 3. `storage.googleapis.com` 在国内不可达，不能依赖默认值。
///
/// 剩下的断言守的是沙箱实测跑通的那份脚本的形状。
void main() {
  group('档位', () {
    test('debug 档只解析 flutterDebug 这一个配置', () {
      expect(ArtifactPrefetch.modesVar(PrefetchMode.debug), 'flutterDebug');
    });

    test('release 档只解析 flutterRelease', () {
      expect(ArtifactPrefetch.modesVar(PrefetchMode.release), 'flutterRelease');
    });

    test('两档都取时两个配置都要解析', () {
      expect(ArtifactPrefetch.modesVar(PrefetchMode.both),
          'flutterDebug flutterRelease');
    });

    test('体积提示与实测一致（不是拍脑袋写的）', () {
      // 实测 Content-Length：debug 180.6MB+1.6MB，release 42.2MB+1.6MB。
      expect(PrefetchMode.debug.sizeHint, '约 182 MB');
      expect(PrefetchMode.release.sizeHint, '约 44 MB');
    });
  });

  group('gradle 脚本正文', () {
    final body = ArtifactPrefetch.gradleScript();

    test('只声明 arm64 一个 ABI 的构件', () {
      expect(body.contains('arm64_v8a_debug'), isTrue);
      expect(body.contains('arm64_v8a_release'), isTrue);
      expect(body.contains('armeabi_v7a'), isFalse,
          reason: 'FOA 固定 --target-platform=android-arm64，'
              '多拉三个 ABI 会多下四百多兆，永远用不到');
      expect(body.contains('x86'), isFalse);
    });

    test('两档的 embedding 都声明了', () {
      expect(body.contains('flutter_embedding_debug'), isTrue);
      expect(body.contains('flutter_embedding_release'), isTrue);
    });

    test('仓库第一条是 FLUTTER_STORAGE_BASE_URL（io.flutter 只在那里有）', () {
      final i = body.indexOf('repositories');
      final block = body.substring(i, body.indexOf('configurations', i));
      // 顺序不能反：换顺序的话 io.flutter:* 会先去阿里云白查一遍。
      expect(block.indexOf('FOA_BASE'), lessThan(block.indexOf('aliyun')));
    });

    test('不带 google()/mavenCentral()（国内直连不通，只会拖慢解析）', () {
      expect(body.contains('google()'), isFalse);
      expect(body.contains('mavenCentral()'), isFalse);
      expect(body.contains('maven.aliyun.com'), isTrue,
          reason: 'flutter_embedding_* 传递依赖 androidx，'
              '实测解析时会抓 androidx.exifinterface，国内必须有镜像兜底');
    });

    test('版本号从环境变量取，不写死（换 SDK 会换构件版本）', () {
      expect(body.contains('System.getenv("FOA_ENGINE")'), isTrue);
      expect(RegExp(r'1\.0\.0-[0-9a-f]{40}').hasMatch(body), isFalse);
    });

    test('用 create/add 显式 API，不靠动态方法（Gradle 9 在收紧）', () {
      expect(body.contains('configurations.create('), isTrue);
      expect(body.contains('add("flutter'), isTrue);
    });
  });

  group('shell 脚本', () {
    String s(PrefetchMode m) => ArtifactPrefetch.script(m);

    test('不用 `gradle -b`（Gradle 9 已删掉这个选项）', () {
      expect(s(PrefetchMode.debug).contains(' -b '), isFalse);
      expect(RegExp(r'gradle\s+-b\s').hasMatch(s(PrefetchMode.debug)), isFalse,
          reason: '官方 resolve_dependencies.gradle.kts 的调用方式已经失效，'
              '沙箱实测 Unknown command-line option');
    });

    test('不用 flutter precache --android_maven（3.47.4 上是空操作）', () {
      expect(s(PrefetchMode.debug).contains('android_maven'), isFalse);
      expect(s(PrefetchMode.debug).contains('precache'), isFalse);
    });

    test('引擎版本号从 SDK 的 engine.stamp 读', () {
      expect(s(PrefetchMode.debug).contains('bin/cache/engine.stamp'), isTrue);
      expect(s(PrefetchMode.debug).contains('读不到引擎版本号'), isTrue,
          reason: '读不到必须报错退出，否则会拿空版本去拼坐标');
    });

    test('FLUTTER_STORAGE_BASE_URL 有国内兜底（官方默认源不可达）', () {
      final t = s(PrefetchMode.debug);
      expect(t.contains('FLUTTER_STORAGE_BASE_URL:='), isTrue);
      expect(t.contains(ArtifactPrefetch.storageMirror), isTrue);
      expect(t.contains('storage.googleapis.com'), isFalse,
          reason: '沙箱实测该域名 SSL 握手直接断，留着就是白等超时');
    });

    test('显式设 JAVA_HOME（gradle 找不到 java 会直接退出）', () {
      final t = s(PrefetchMode.debug);
      // 沙箱实测：env -i 跑 gradle → `ERROR: JAVA_HOME is not set and no
      // 'java' command could be found`，exit 1。proot 执行的 sh 不读
      // /etc/profile.d，所以必须自己设。
      expect(t.contains('export JAVA_HOME='), isTrue);
      expect(t.contains('/opt/jdk'), isTrue);
      expect(t.contains('容器里没有可用的 java'), isTrue);
      // 已设过就别硬盖（termux/自定义 JDK 场景下会被顶掉）
      expect(t.contains(r'${JAVA_HOME:-'), isTrue);
    });

    test('gradle 可执行文件三条路都留了兜底', () {
      final t = s(PrefetchMode.debug);
      expect(t.contains('command -v gradle'), isTrue);
      expect(t.contains('/root/.gradle/wrapper/dists/gradle-'), isTrue,
          reason: '首次构建后 wrapper 分发包已解压，这是最稳的一条');
      expect(t.contains('artifacts/gradle_wrapper/gradlew'), isTrue,
          reason: '没构建过时用 SDK 自带的 wrapper 现搭一个');
      expect(t.contains('找不到 gradle'), isTrue);
    });

    test('自建 wrapper 用腾讯云镜像 URL（与预下载缓存同 hash 才能命中）', () {
      expect(s(PrefetchMode.debug)
              .contains('mirrors.cloud.tencent.com/gradle'), isTrue);
    });

    test('gradle 脚本正文用引号定界的 heredoc 落盘（不被 shell 展开）', () {
      final t = s(PrefetchMode.debug);
      expect(t.contains("<<'FOA_PREFETCH_EOF'"), isTrue);
      expect(t.contains('\nFOA_PREFETCH_EOF\n'), isTrue);
      // 正文必须原样出现一次（没被二次转义）
      expect(t.contains(ArtifactPrefetch.gradleScript().trim()), isTrue);
    });

    test('失败时把 gradle 日志 tail 出来（否则用户只看到一句"失败"）', () {
      final t = s(PrefetchMode.debug);
      expect(t.contains('out.log'), isTrue);
      expect(t.contains('tail -n 25'), isTrue);
    });

    test('成功打 PREFETCH_OK，失败先打 ERR= 再非零退出', () {
      final t = s(PrefetchMode.debug);
      expect(t.contains('PREFETCH_OK'), isTrue);
      expect(t.contains('ERR=预取失败'), isTrue);
      // 必须是 shell 变量 `\$rc`（脚本里写 `exit \$rc`），
      // 写成 Dart 插值的话退出码会被拼成字面量。
      expect(RegExp(r'exit \$rc').hasMatch(t), isTrue);
    });

    test('不同档位的 FOA_MODES 不同', () {
      expect(s(PrefetchMode.debug).contains('export FOA_MODES="flutterDebug"'),
          isTrue);
      expect(s(PrefetchMode.both)
              .contains('export FOA_MODES="flutterDebug flutterRelease"'),
          isTrue);
    });
  });

  group('输出解析', () {
    test('成功标记', () {
      expect(ArtifactPrefetch.isOk('ENGINE=abc\nPREFETCH_OK'), isTrue);
      expect(ArtifactPrefetch.isOk('ENGINE=abc\nERR=x'), isFalse);
    });

    test('错误行', () {
      expect(ArtifactPrefetch.errorOf('a\nERR=预取失败（gradle exit 1）\nb'),
          '预取失败（gradle exit 1）');
      expect(ArtifactPrefetch.errorOf('no error here'), isNull);
    });

    test('引擎版本与 gradle 路径（排障用）', () {
      const out = 'ENGINE=06a2e2a1\nGRADLE=/root/.gradle/wrapper/dists/x/bin/gradle';
      expect(ArtifactPrefetch.engineOf(out), '06a2e2a1');
      expect(ArtifactPrefetch.gradleOf(out),
          '/root/.gradle/wrapper/dists/x/bin/gradle');
    });
  });

  group('UI 接线', () {
    final page = File('lib/toolchain/toolchain_page.dart').readAsStringSync();

    test('预取卡已 import 且放进 proot 分支的卡片列表', () {
      expect(page.contains("import 'artifact_prefetch.dart';"), isTrue);
      expect(page.contains('const _PrefetchCard()'), isTrue,
          reason: 'import 了没插进 ListView = 用户永远看不到这个入口');
    });

    test('三个档位按钮都在（debug 主推，release/两档次级）', () {
      expect(page.contains("'预取 debug 构件'"), isTrue);
      expect(page.contains("'仅 release'"), isTrue);
      expect(page.contains("'两档都取'"), isTrue);
    });

    // ⚠️ alpha.95 回归：按钮文案一长，中文会**按字换行**，被挤成
    // 「预 / 取 / deb / ug」这种竖直堆叠（真机截图确认，非常难看）。
    // 所以每个按钮都必须显式声明 maxLines + ellipsis：宁可省略号，不竖排。
    test('按钮文案不得竖排（必须 maxLines:1 + ellipsis）', () {
      // 至少 4 处（三个档位按钮 + 可能的其他按钮文案）
      final n = RegExp(r'maxLines: 1, overflow: TextOverflow\.ellipsis')
          .allMatches(page)
          .length;
      expect(n, greaterThanOrEqualTo(3),
          reason: '预取卡里每个按钮文案都要防竖排，否则长文案会被挤成竖列');
      // 老的长文案（"预取 debug" 不带"构件"）不该再出现，它正是被挤的原型
      expect(page.contains("label: const Text('预取 debug')"), isFalse,
          reason: '"预取 debug" 在三个按钮并排时会被按字折行');
    });

    test('跑的时候有取消出口（182MB 可能下很久）', () {
      expect(page.contains('_job.stop'), isTrue);
    });

    test('卡片只出现在 proot 分支（termux 路径不适用，显示了是误导）', () {
      final i = page.indexOf('const _PrefetchCard()');
      final before = page.substring(0, i);
      // 它在 _TermuxCard 之后 —— termux 分支已经结束，说明落在 proot 分支
      expect(before.contains('_TermuxCard('), isTrue);
    });
  });

  // ⚠️ alpha.95：入口从"只在工具链页"扩到"打包区的项目列表上方"。
  //
  // 理由是触发场景错位：工具链页是"我想主动预取"的心智，而用户实际的
  // 痛点发生在「在打包区点了构建 → 第一次卡 20~30 分钟」那一刻。
  // 放到构建页让他**在下手之前**看到，工具链页那份保留。
  group('打包区的预取入口（alpha.95）', () {
    final bp = File('lib/toolchain/build_page.dart').readAsStringSync();

    test('构建页 import 了 artifact_prefetch 且真的建了 job', () {
      expect(bp.contains("import 'artifact_prefetch.dart';"), isTrue);
      expect(bp.contains('PrefetchJob('), isTrue);
    });

    test('提示卡挂在项目列表上方（不是构建日志里）', () {
      expect(bp.contains('_prefetchCard()'), isTrue);
      // 必须在 _buildProjectList 里 —— 那是 idle 状态下的视图
      expect(bp.contains('Widget _buildProjectList()'), isTrue);
    });

    test('跑过 / 点了「不用」之后不再占地方（不能变成常驻噪音）', () {
      expect(bp.contains('_showPrefetchHint'), isTrue);
      expect(bp.contains("'不用'"), isTrue,
          reason: '提醒必须给出口，否则每次进构建页都被念一遍');
    });

    test('跑的时候能取消，且离开页面不停任务', () {
      expect(bp.contains('_prefetch.stop'), isTrue,
          reason: '182MB 可能下很久，必须给取消出口');
      expect(bp.contains('_prefetch.onChanged = null'), isTrue,
          reason: '182MB 要下十几分钟，离开页面应继续跑（只解绑 UI 回调）');
      // 反面：dispose 里**不能**顺手 stop —— 那等于"离页即中止"，
      // 用户切走看一眼再回来发现白下了。
      final disposeBlock = bp.substring(
        bp.indexOf('void dispose()'),
        bp.indexOf('void dispose()') + 700,
      );
      expect(disposeBlock.contains('_prefetch.stop'), isFalse,
          reason: 'dispose 里只解绑回调，不要停任务');
    });

    test('文案讲清"不点也能构建，只是慢"（不制造阻塞感）', () {
      expect(bp.contains('不点也能构建'), isTrue,
          reason: '预取是优化不是前置条件，文案不能让人以为必须先做');
    });

    test('按钮文案同样防竖排', () {
      expect(bp.contains("'预取 debug 构件'"), isTrue);
      expect(RegExp(r'maxLines: 1, overflow: TextOverflow\.ellipsis')
          .hasMatch(bp), isTrue);
    });
  });
}
