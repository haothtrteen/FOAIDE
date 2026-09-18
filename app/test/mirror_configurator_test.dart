import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_on_android/toolchain/sdk_installer.dart';

/// Bug 426 固化：init.gradle 必须是无注入的 beforeSettings 前插形态。
///
/// 背景（alpha.36 真机实翻车）：旧版 init.gradle 用
/// `allprojects{repositories{maven}}` + `settingsEvaluated` 往 project /
/// 评估后上下文注入仓库，与 Flutter 新模板 settings.gradle.kts
/// （flutter-plugin-loader 走 PREFER_SETTINGS 仓库模式）冲突——真机构建
/// 22% 配置 Gradle 时报
/// `prefer settings repositories ... repository 'maven' was added`，
/// plugin-loader 解析失败。沙箱出包不走真机工具链，analyze/test 覆盖不到
/// 容器内 gradle 行为——只能靠这里的**文本断言**拦住回归。
void main() {
  group('MirrorConfigurator.initGradleContent · Bug 426 注入边界', () {
    final content = MirrorConfigurator.initGradleContent();

    /// 只看有效代码行：init.gradle 的注释里难免提到关键词（连本测试
    /// 文档都在提），断言只对 Groovy 代码生效。
    final code = content
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('//'))
        .join('\n');

    test('禁止 project 级仓库注入（PREFER_SETTINGS 模式下必报错）', () {
      expect(code.contains('allprojects'), isFalse,
          reason: 'allprojects{repositories{maven}} 会向 project 级注入仓库，'
              'PREFER_SETTINGS 模式拒绝 → 报 "repository maven was added"');
      expect(code.contains('settingsEvaluated'), isFalse,
          reason: 'settingsEvaluated 在插件设完仓库模式后执行，'
              '往 repositories 加仓库属旧版注入形态');
    });

    test('必须用 beforeSettings 前插（settings 仓库合法且优先命中）', () {
      expect(code.contains('beforeSettings'), isTrue,
          reason: 'settings 仓库正是被 prefer 的对象，加仓库合法；'
              '前插镜像使官方源成为兜底');
      expect(code.contains('settings.pluginManagement.repositories'), isTrue);
      expect(code.contains(
          'settings.dependencyResolutionManagement.repositories'), isTrue);
    });

    test('镜像域名齐全（public / google / gradle-plugin）', () {
      for (final repo in ['public', 'google', 'gradle-plugin']) {
        expect(code.contains('maven.aliyun.com/repository/$repo'), isTrue,
            reason: '缺 $repo 镜像仓会导致对应依赖回落官方源（国内易超时）');
      }
    });

    test('无 project 级 repositories 裸注入（repositories{ 前不含 settings. 前缀）', () {
      // 逐行扫描有效代码：settings.xxx.repositories 的写法合法；任何
      // 不以 settings. 开头却出现 repositories 的行都视为注入回归
      final offenders = code
          .split('\n')
          .where((l) => l.contains('repositories'))
          .where((l) => !l.contains('settings.'))
          .toList();
      expect(offenders, isEmpty, reason: '发现 project 级仓库注入：$offenders');
    });
  });
}
