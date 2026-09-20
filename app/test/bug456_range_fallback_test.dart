import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/sdk_downloader.dart';

/// Bug 456：镜像不支持 Range（回 200）时，必须**退化为整包单流下载**，
/// 而不是判该镜像不可用、换源——后者在"源少且大部分不通"的资产上
/// （cloudflared 只有 ghproxy + GitHub 直链）等于整链必失败。
///
/// 这组测试用**本地真实 HTTP 服务器**验证行为，而不是断言源码文本：
/// 服务器可以精确控制「支持/不支持 Range」，是唯一能证明兜底真正生效的办法。
///
/// 覆盖：
/// 1. 服务器支持 206 → 正常分段下载；
/// 2. 服务器不支持 Range（无论带不带 Range 头都回 200）→ 仍然下载成功
///    且内容逐字节正确（这是修复的核心断言）；
/// 3. 整包兜底过程中其它分片被清空 → 拼接结果不膨胀、不串位。
void main() {
  /// 造一份可预测的测试载荷（非随机：便于失败时定位串位）。
  List<int> payload(int n) =>
      List<int>.generate(n, (i) => i % 251);

  /// 起一个测试服务器。
  /// [supportRange] = false 时模拟 ghproxy 类镜像：忽略 Range，整包回 200。
  Future<(HttpServer, List<String> seenRangeHeaders)> serve(
    List<int> body, {
    required bool supportRange,
  }) async {
    final seen = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final range = req.headers.value(HttpHeaders.rangeHeader);
      seen.add(range ?? '');
      if (!supportRange || range == null) {
        req.response.statusCode = 200;
        req.response.headers
            .set(HttpHeaders.contentLengthHeader, body.length);
        req.response.add(body);
      } else {
        // 解析 "bytes=<start>-<end>"
        final spec = range.replaceFirst('bytes=', '');
        final dash = spec.indexOf('-');
        final start = int.parse(spec.substring(0, dash));
        final end = int.parse(spec.substring(dash + 1));
        final slice = body.sublist(start, end + 1 > body.length
            ? body.length
            : end + 1);
        req.response.statusCode = 206;
        req.response.headers
            .set(HttpHeaders.contentLengthHeader, slice.length);
        req.response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $start-${start + slice.length - 1}/${body.length}');
        req.response.add(slice);
      }
      await req.response.close();
    });
    return (server, seen);
  }

  test('支持 Range：分段下载成功且内容逐字节一致', () async {
    final body = payload(300 * 1024);
    final (server, _) = await serve(body, supportRange: true);
    final dir = await Directory.systemTemp.createTemp('foa456a');
    final out = '${dir.path}/out.bin';
    try {
      await SdkDownloader.downloadMultiSource(
        [MirrorSource('local', 'http://127.0.0.1:${server.port}/f')],
        out,
        body.length,
        segments: 4,
      );
      expect(await File(out).readAsBytes(), equals(body));
    } finally {
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });

  test('不支持 Range（回 200）：整包兜底仍成功，内容逐字节一致', () async {
    final body = payload(300 * 1024);
    final (server, seen) = await serve(body, supportRange: false);
    final dir = await Directory.systemTemp.createTemp('foa456b');
    final out = '${dir.path}/out.bin';
    try {
      await SdkDownloader.downloadMultiSource(
        [MirrorSource('local', 'http://127.0.0.1:${server.port}/f')],
        out,
        body.length,
        segments: 4,
      );
      // 核心断言：修复前这里会抛 DownloadException('服务器不支持 Range（HTTP 200）')
      expect(await File(out).readAsBytes(), equals(body),
          reason: '整包兜底必须产出完整且正确的内容');
      expect(await File(out).length(), equals(body.length),
          reason: '长度不得因多分片残留而膨胀');
      // 确认确实走到过 200 分支（而不是碰巧服务器支持了 Range）
      expect(seen.any((r) => r.isNotEmpty), isTrue,
          reason: '客户端应先按分片发过 Range 请求');
    } finally {
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });

  test('整包兜底后分片残留被清理（不留下 .p1/.p2 垃圾）', () async {
    final body = payload(200 * 1024);
    final (server, _) = await serve(body, supportRange: false);
    final dir = await Directory.systemTemp.createTemp('foa456c');
    final out = '${dir.path}/out.bin';
    try {
      await SdkDownloader.downloadMultiSource(
        [MirrorSource('local', 'http://127.0.0.1:${server.port}/f')],
        out,
        body.length,
        segments: 4,
      );
      final leftovers = dir
          .listSync()
          .map((e) => e.path.split('/').last)
          .where((n) => n.contains('.p'))
          .toList();
      expect(leftovers, isEmpty,
          reason: '拼接完成后 .p<i> 应全部删除，否则白占空间且干扰续传判定');
    } finally {
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });
}
