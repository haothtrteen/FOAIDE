import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/build_progress.dart';

void main() {
  group('BuildProgressTracker · 阶段识别', () {
    test('空 tracker 停在兜底阶段', () {
      final t = BuildProgressTracker();
      expect(t.stage, BuildStages.bootstrap);
      expect(t.percent, 0);
      expect(t.isDone, isFalse);
    });

    test('真实日志序列推进到各阶段', () {
      final t = BuildProgressTracker();

      t.feed('Running Gradle task \'assembleRelease\'...');
      expect(t.stage, BuildStages.configGradle);

      t.feed('Resolving dependencies...');
      expect(t.stage, BuildStages.configGradle, reason: '不回退到 resolveDeps');

      t.feed('> Task :app:compileFlutterBuildRelease');
      expect(t.stage, BuildStages.compileKernel);

      t.feed('Target android_aot_release_android-arm64 failed?');
      expect(t.stage, BuildStages.aot);

      t.feed('> Task :app:mergeReleaseResources');
      expect(t.stage, BuildStages.resources);

      t.feed('> Task :app:minifyReleaseWithR8');
      expect(t.stage, BuildStages.dex);

      t.feed('> Task :app:packageRelease');
      expect(t.stage, BuildStages.packageApk);

      t.feed('✓ Built build/app/outputs/flutter-apk/app-release.apk (87.4MB)');
      expect(t.stage, BuildStages.packageApk);
      expect(t.isDone, isFalse, reason: '仅日志命中不算完成');
    });

    test('阶段单调不回退', () {
      final t = BuildProgressTracker();
      t.feed('> Task :app:packageRelease');
      final high = t.stage;
      t.feed('Running Gradle task \'assembleRelease\'...');
      expect(t.stage, high);
      t.feed('Resolving dependencies...');
      expect(t.stage, high);
    });

    test('空白行忽略', () {
      final t = BuildProgressTracker();
      t.feed('   ');
      t.feed('');
      expect(t.stage, BuildStages.bootstrap);
    });
  });

  group('BuildProgressTracker · 进度值', () {
    test('markDone 到达 100%', () {
      final t = BuildProgressTracker();
      t.feed('> Task :app:packageRelease');
      t.markDone();
      expect(t.progress, 1.0);
      expect(t.percent, 100);
      expect(t.stage, BuildStages.locateApk);
    });

    test('markHalted 后 tick 不再推进', () async {
      final t = BuildProgressTracker();
      t.feed('> Task :app:compileReleaseKotlin');
      t.markHalted();
      final before = t.progress;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      t.tick();
      expect(t.progress, before, reason: '冻结后不爬升');
    });

    test('未完成时进度严格小于 1', () {
      final t = BuildProgressTracker();
      t.feed('> Task :app:packageRelease');
      for (var i = 0; i < 50; i++) {
        t.tick();
      }
      expect(t.progress, lessThan(1.0));
      t.feed('Built build/app/outputs/flutter-apk/app-release.apk');
      expect(t.progress, lessThan(1.0), reason: '只有 markDone 才到 100');
    });

    test('进度随阶段推进单调不减', () {
      final t = BuildProgressTracker();
      double last = t.progress;
      const lines = [
        'Running Gradle task \'assembleRelease\'...',
        '> Task :app:compileFlutterBuildRelease',
        'Target android_aot_release_android-arm64',
        '> Task :app:mergeReleaseResources',
        '> Task :app:minifyReleaseWithR8',
        '> Task :app:packageRelease',
      ];
      for (final l in lines) {
        t.feed(l);
        t.tick();
        expect(t.progress, greaterThanOrEqualTo(last));
        last = t.progress;
      }
    });

    test('阶段内插值随时间渐近但不封顶', () async {
      final t = BuildProgressTracker();
      t.feed('> Task :app:mergeReleaseResources');
      final s = t.stage;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      t.tick();
      final p = t.progress;
      expect(p, greaterThan(s.start));
      // 上限 = start + (end-start)*0.92
      final ceiling = s.start + (s.end - s.start) * 0.92;
      expect(p, lessThanOrEqualTo(ceiling + 1e-9));
    });

    test('reset 回到初始', () {
      final t = BuildProgressTracker();
      t.feed('> Task :app:packageRelease');
      t.markDone();
      t.reset();
      expect(t.stage, BuildStages.bootstrap);
      expect(t.isDone, isFalse);
      expect(t.percent, 0);
    });
  });

  group('BuildStages 完整性', () {
    test('阶段区间连续且递增（无空洞、无重叠）', () {
      const list = BuildStages.ordered;
      expect(list.first.start, 0.0);
      for (var i = 0; i < list.length; i++) {
        final s = list[i];
        expect(s.end, greaterThan(s.start), reason: '${s.label} 区间非法');
        if (i > 0) {
          expect(s.start, greaterThanOrEqualTo(list[i - 1].end),
              reason: '${s.label} 与前一段重叠');
        }
      }
      // 最后一段留白：100% 只由 markDone 授予
      expect(list.last.end, lessThan(1.0));
    });

    test('阶段标签非空', () {
      for (final s in BuildStages.ordered) {
        expect(s.label.trim(), isNotEmpty);
      }
    });
  });
}
