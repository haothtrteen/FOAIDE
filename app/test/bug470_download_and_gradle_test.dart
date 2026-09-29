// Bug 470 回归测试：cloudflared 下载竞态 + gradle 读写不对称 + 命名澄清。
//
// 用户的原始反馈（2026-09-20，真机截图）：
//
//   1. 「远程协助」页报 cloudflared 下载失败，且**4/4 镜像全部显示可用**
//      —— 报错是 `PathNotFoundException: Cannot open file
//      '.../cloudflared.dl.p0'`。
//      这个组合极具误导性：镜像都好，却是"下载失败"。
//
//   2. 项目工作台保存时报「读取失败：不是文件
//      /root/projects/my_flutter/android/app/build.gradle」
//      —— 但工程是 Flutter 新版模板，gradle 文件叫 build.gradle.kts。
//
//   3. 「远程接管」这个词容易被误解，且它与「AI 接管」的分工
//      在 UI 上没有任何说明。
//
// 本文件按「根因可被发现」的原则写：断言的是**结构约束**（谁在什么时候
// 能做文件操作），而不是复述实现细节。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String rel) => File(rel).readAsStringSync();

void main() {
  group('Bug 470 · 下载器不再有"兜底与分片抢文件"的竞态', () {
    final src = _read('lib/toolchain/sdk_downloader.dart');

    test('「不支持 Range」是独立信号类型，不是 DownloadException', () {
      // 为什么必须独立：混进 DownloadException 会被分片里的
      // `on DownloadException { rethrow }` 和 `catch (_)` 当成普通失败，
      // 于是"重试 + 换镜像"跑 N 轮，最后抛出网络错误——信号丢失，
      // 外层永远不知道该切整包单流。真机表现就是"镜像全可用却下载失败"。
      expect(src.contains('class _RangeUnsupported'), isTrue,
          reason: '缺少独立的 Range 不支持信号类型');
      expect(
        RegExp(r'class _RangeUnsupported implements Exception').hasMatch(src),
        isTrue,
        reason: '信号类型必须是独立的 Exception 实现',
      );
    });

    test('信号在分片内部必须原样穿透（两处 catch 都要显式放行）', () {
      // 第一处：内层 catch（原 catch (_) 会吞掉它去重试）
      // 第二处：外层 catch（原 catch (_) 会把它记成"网络错误"）
      final passThrough =
          RegExp(r'on _RangeUnsupported').allMatches(src).length;
      expect(passThrough, greaterThanOrEqualTo(2),
          reason: '两处 catch 链都必须显式放行 _RangeUnsupported，'
              '否则信号会被吞成普通网络错误（实测 count=$passThrough）');
    });

    test('分片函数**不再**自己调用整包兜底', () {
      // 这是竞态的直接来源：分片 0 就地兜底时会删掉 .p1..n，
      // 而分片 1..n 可能仍持有这些文件的打开句柄。
      final segBody = _segmentBody(src);
      expect(segBody.contains('_downloadAsWholeFile'), isFalse,
          reason: '分片函数内不得出现整包兜底调用——'
              '兜底必须提到外层 Future.wait 之后执行');
    });

    test('整包兜底在 Future.wait **之后**执行（关键时序）', () {
      final waitIdx = src.indexOf('await Future.wait(');
      expect(waitIdx, greaterThan(0), reason: '找不到 Future.wait');

      // 兜底调用点必须晚于 Future.wait
      final firstWholeCall =
          src.indexOf('await _downloadAsWholeFile(', waitIdx);
      expect(firstWholeCall, greaterThan(waitIdx),
          reason: '整包兜底必须在 Future.wait 之后调用，'
              '此时所有分片已退出、不会有句柄与文件的交叠');
    });

    test('兜底不再删除它人的分片文件', () {
      // 旧实现有 `for (var i = 1; i < parts.length; i++) { delete(); create(); }`
      // —— 这正是竞态的施害动作。
      final wholeBody = _wholeFileBody(src);
      expect(
        RegExp(r'for\s*\(var i = 1;\s*i < parts\.length').hasMatch(wholeBody),
        isFalse,
        reason: '兜底不得再遍历删除其它分片文件（那是竞态根源）',
      );
    });

    test('兜底直接写最终 savePath（省掉一次拼接）', () {
      final wholeBody = _wholeFileBody(src);
      expect(wholeBody.contains('File(savePath)'), isTrue,
          reason: '兜底应直接写目标文件');
    });

    test('兜底会轮换全部镜像（不只试最快的那个）', () {
      final wholeBody = _wholeFileBody(src);
      expect(wholeBody.contains('for (final mirror in mirrors)'), isTrue,
          reason: '兜底必须遍历 mirrors——只试一个源时，'
              '该源恰好不支持整包就彻底失败');
    });

    test('cloudflared 走单流下载（segments: 1）', () {
      // 37MB 的资产，分段并发收益有限，但分段路径有竞态面。
      // 单流没有分片、没有拼接，也就没有那个竞态面。
      final cf = _read('lib/mcp/cloudflared_install.dart');
      expect(cf.contains('segments: 1'), isTrue,
          reason: 'cloudflared 应显式指定单流下载');
    });

    test('cloudflared 传了 sha256 做内容校验', () {
      final cf = _read('lib/mcp/cloudflared_install.dart');
      expect(cf.contains('sha256: sha256'), isTrue,
          reason: '必须传校验和——截断/坏内容骗得过体积比对');
    });
  });

  group('Bug 470 · gradle 文件读写对称（.gradle / .gradle.kts 都要认）', () {
    final src = _read('lib/project/manifest_page.dart');

    test('读路径遍历两个候选', () {
      expect(src.contains('_gradleCandidates'), isTrue,
          reason: '需要统一的候选列表');
      expect(
        RegExp(r"'_gradleRel',\s*\n\s*'android/app/build\.gradle\.kts'")
            .hasMatch(src) ||
            src.contains("'android/app/build.gradle.kts'"),
        isTrue,
        reason: '候选列表必须同时含 .gradle 与 .gradle.kts',
      );
    });

    test('读路径**记住**命中的那个文件（否则写回必错）', () {
      expect(RegExp(r'String\? _gradleActual').hasMatch(src), isTrue,
          reason: '需要一个字段记住实际命中的 gradle 文件路径');
      expect(src.contains('_gradleActual = f'), isTrue,
          reason: '读命中时应记录到 _gradleActual');
    });

    test('写路径复用命中的文件，不再写死 _gradleRel', () {
      // 旧代码：`final r = await _fb.read(_p(_gradleRel));`
      // 在读循环外直接用写死的路径 → .kts 工程报「不是文件」
      final writeBlock = _saveGradleBlock(src);
      expect(writeBlock.contains('_gradleActual'), isTrue,
          reason: '写回必须用探测到的实际路径');
      expect(
        RegExp(r'_fb\.(read|write)\(_p\(_gradleRel\)\)').hasMatch(writeBlock),
        isFalse,
        reason: '写回路径不得再写死 _gradleRel（这是本 bug 的直接成因）',
      );
    });

    test('两个候选都不存在时给明确文案，而不是抛"不是文件"', () {
      final writeBlock = _saveGradleBlock(src);
      expect(writeBlock.contains('_gradleActual == null'), isTrue,
          reason: '需要对"两个候选都没有"给出专门提示');
      expect(writeBlock.contains('没有 android/app/build.gradle'), isTrue,
          reason: '文案应说明工程内缺少 gradle 文件');
    });

    test('提示文案按实际文件类型显示（.kts 不说成 .gradle）', () {
      expect(src.contains('build.gradle.kts'), isTrue,
          reason: 'UI 上应能正确显示 .kts 类型');
    });
  });

  group('Bug 470 · 命名澄清：远程协助 vs AI 接管', () {
    test('面向用户的文案已改称「远程协助」', () {
      for (final f in const [
        'lib/ui/home_page.dart',
        'lib/project/project_preview.dart',
      ]) {
        final s = _read(f);
        expect(s.contains('远程协助'), isTrue, reason: '$f 应使用新名称');
        expect(s.contains('远程接管'), isFalse,
            reason: '$f 不应再出现旧名称');
      }
    });

    test('远程协助页的警告栏说明了与 AI 接管的分工', () {
      final s = _read('lib/mcp/remote_takeover_page.dart');
      expect(s.contains('AI 接管'), isTrue,
          reason: '警告栏应指引「只开发某个项目」的用户去 AI 接管');
      expect(s.contains('整台设备'), isTrue,
          reason: '应点明本页是设备级通道');
    });

    test('AI 接管面板也反向指路（双向说明）', () {
      final s = _read('lib/project/ai_takeover_panel.dart');
      expect(s.contains('远程协助'), isTrue,
          reason: 'AI 接管应说明"整机级通道请用远程协助"');
      expect(s.contains('当前这个项目'), isTrue,
          reason: '应点明 AI 接管只作用于当前项目');
    });

    test('警告栏改用主题语义色（不再硬编码深色底）', () {
      final s = _read('lib/mcp/remote_takeover_page.dart');
      // Bug 465 遗留：这里曾是 Color(0xFF3A2416) + Colors.orange.shade100，
      // 浅色主题下是刺眼深棕。
      expect(s.contains('FoaColors.of(context)'), isTrue,
          reason: '警告栏应使用主题感知语义色');
      expect(s.contains('0xFF3A2416'), isFalse,
          reason: '不应再硬编码深色警告底色');
    });
  });
}

/// 截取 `_downloadSegment` 方法体（到下一个顶层 static 方法为止）。
String _segmentBody(String src) {
  final start = src.indexOf('static Future<void> _downloadSegment(');
  expect(start, greaterThan(0), reason: '找不到 _downloadSegment');
  final next = src.indexOf('static Future<void> _downloadAsWholeFile(', start);
  expect(next, greaterThan(start), reason: '找不到下一个方法边界');
  return src.substring(start, next);
}

/// 截取 `_downloadAsWholeFile` 方法体（到 `_sha256Of` 为止）。
String _wholeFileBody(String src) {
  final start = src.indexOf('static Future<void> _downloadAsWholeFile(');
  expect(start, greaterThan(0), reason: '找不到 _downloadAsWholeFile');
  final next = src.indexOf('static Future<String> _sha256Of(', start);
  expect(next, greaterThan(start), reason: '找不到方法结束边界');
  return src.substring(start, next);
}

/// 截取保存流程里的 gradle 处理块（从注释标记到方法收尾）。
String _saveGradleBlock(String src) {
  // ⚠️ 标记是**文本匹配**的，页面里那段注释一改这里就得跟着改。
  // 改成条件反而会把测试变得更脆（它会去猜"哪段才算保存块"）。
  final start = src.indexOf('构建选项：gradle 的包名 / 混淆开关（Bug 470）');
  expect(start, greaterThan(0), reason: '找不到 gradle 保存块标记');
  return src.substring(start, start + 2000);
}
