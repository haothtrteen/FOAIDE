import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/project/project_stats.dart';

/// alpha.61 预览子页/打包子页数据源测试。
///
/// 格式化函数看着简单，但边界不少（0、负数、刚好 1024、跨单位、
/// 时间戳为 0/未来时间）。这类函数写错的后果是"界面显示 0 B 或
/// 未知时间"——不崩溃，所以没人会报 bug，只会觉得"这 App 有点糙"。
void main() {
  group('fmtBytes', () {
    test('0 与负数统一显示 0 B', () {
      expect(fmtBytes(0), '0 B');
      expect(fmtBytes(-5), '0 B');
    });

    test('不足 1KB 按字节显示', () {
      expect(fmtBytes(1), '1 B');
      expect(fmtBytes(512), '512 B');
      expect(fmtBytes(1023), '1023 B');
    });

    test('单位换算点准确（1024 进制）', () {
      expect(fmtBytes(1024), '1 KB');
      expect(fmtBytes(1024 * 1024), '1 MB');
      expect(fmtBytes(1024 * 1024 * 1024), '1 GB');
    });

    test('整数不带小数点，小数保留一位或取整', () {
      expect(fmtBytes(2048), '2 KB');
      expect(fmtBytes(1536), '1.5 KB');
      // 10MB 以上取整，避免 "23.4 MB" 这种假精度
      expect(fmtBytes(1024 * 1024 * 23), '23 MB');
    });

    test('APK 量级的真实值（alpha.60 产物的 88,070,673 字节 ≈ 84 MB）', () {
      final s = fmtBytes(88070673);
      expect(s, '84 MB');
    });
  });

  group('fmtRelativeTime', () {
    final base = DateTime(2026, 9, 20, 12, 0, 0);
    int ms(DateTime t) => t.millisecondsSinceEpoch;

    test('未知时间戳（0）显示"未知时间"而不是 1970 年', () {
      expect(fmtRelativeTime(0), '未知时间');
      expect(fmtRelativeTime(-1), '未知时间');
    });

    test('一分钟内显示"刚刚"', () {
      expect(fmtRelativeTime(ms(base.subtract(const Duration(seconds: 5))), now: base),
          '刚刚');
    });

    test('分钟 / 小时 / 天三级', () {
      expect(fmtRelativeTime(ms(base.subtract(const Duration(minutes: 3))), now: base),
          '3 分钟前');
      expect(fmtRelativeTime(ms(base.subtract(const Duration(hours: 5))), now: base),
          '5 小时前');
      expect(fmtRelativeTime(ms(base.subtract(const Duration(days: 3))), now: base),
          '3 天前');
    });

    test('超过 30 天改用绝对日期（相对时间失去意义）', () {
      final old = base.subtract(const Duration(days: 40));
      final s = fmtRelativeTime(ms(old), now: base);
      expect(s.contains('-'), isTrue);
      expect(s.contains('天前'), isFalse);
    });

    test('未来时间不崩（时钟漂移/时区）', () {
      expect(fmtRelativeTime(ms(base.add(const Duration(hours: 2))), now: base),
          '刚刚');
    });
  });

  group('ProjectStats 模型', () {
    test('空快照：没有数据、没有产物', () {
      const s = ProjectStats.empty;
      expect(s.latest, isNull);
      expect(s.hasAnyData, isFalse);
      expect(s.artifacts, isEmpty);
    });

    test('latest 取时间最新的产物（列表已倒序）', () {
      const s = ProjectStats(artifacts: [
        ApkArtifact(name: 'app-release.apk', guestPath: '/p/app-release.apk', mtimeMs: 200),
        ApkArtifact(name: 'app-debug.apk', guestPath: '/p/app-debug.apk', mtimeMs: 100),
      ]);
      expect(s.latest!.name, 'app-release.apk');
    });

    test('有缓存包即视为有数据（用于决定显示"暂无"还是数值）', () {
      const s = ProjectStats(cachedPackages: 12, pubCacheBytes: 5 * 1024 * 1024);
      expect(s.hasAnyData, isTrue);
    });

    test('产物时间戳为 0 时 modifiedAt 为 null（不伪造 1970 年）', () {
      const a = ApkArtifact(name: 'x.apk', guestPath: '/x.apk');
      expect(a.modifiedAt, isNull);
    });

    test('产物时间戳有效时能解析出时间', () {
      const a = ApkArtifact(name: 'x.apk', guestPath: '/x.apk', mtimeMs: 1700000000000);
      expect(a.modifiedAt, isNotNull);
      expect(a.modifiedAt!.year, greaterThan(2020));
    });
  });
}
