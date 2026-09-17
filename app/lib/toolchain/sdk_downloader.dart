import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 镜像源（同一文件的不同地址，按偏好顺序给出）。
class MirrorSource {
  final String name; // 显示名：'TUNA 清华' / 'GitHub 官方' ...
  final String url;
  const MirrorSource(this.name, this.url);
}

/// 下载进度快照。
class DownloadProgress {
  final int received;
  final int total;
  final double speed; // 字节/秒（最近 200ms 窗口，全分片聚合）
  const DownloadProgress({
    required this.received,
    required this.total,
    required this.speed,
  });

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);
}

/// 可取消令牌：UI 持同一实例调用 [cancel] 即中断下载。
class DownloadCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class DownloadException implements Exception {
  final String message;
  DownloadException(this.message);
  @override
  String toString() => message;
}

/// SDK 下载器（Step 3 核心，Flutter SDK 阶段复用）：
/// 镜像并发竞速选源 → 多线程分段并发下载（多镜像并行）→ 分片级断点续传
/// → 拼接 + SHA-256 校验 → 分片失败/卡住自动换镜像。
///
/// 设计要点（Bug 219 起积累，2026-09-17 重构为分段并发）：
/// - 竞速：对每个镜像发 Range 首 64KB 探测，读完耗时最短者胜；
/// - 分段：把目标文件按 [defaultSegments] 切成 Range 分片，各分片并发下载；
///   分片 i 起步用镜像 i % n（轮流分散到不同镜像 → 多镜像同时传输）；
/// - 续传：每个分片独立落盘 `<save>.p<i>`，文件长度即该分片进度，
///   重试/重开应用/换镜像时按长度续传，不再从头下载；
/// - 熔断：分片 15s 无数据自动换下一个镜像；明确失败（拒 206/HTTP 错误）
///   立即换源；瞬时网络抖动同镜像最多重试 2 次；
/// - 校验：拼接后 sha256 流式计算（openRead 分块，不整读进内存）；
/// - 快路径：目标文件已存在且尺寸/SHA 匹配 → 直接跳过下载（解压失败重试
///   时不再重复下载 183MB）。
class SdkDownloader {
  static const int probeBytes = 65536;
  static const int maxRetriesPerMirror = 2;
  static const Duration stallTimeout = Duration(seconds: 15);
  static const int defaultSegments = 4;

  /// 并发竞速选源：返回按"探测耗时升序"排序的镜像列表（最快在前）。
  /// 全部探测失败抛 [DownloadException]。
  static Future<List<MirrorSource>> pickFastest(
    List<MirrorSource> mirrors, {
    Duration timeout = const Duration(seconds: 12),
    DownloadCancelToken? token,
  }) async {
    final results = await Future.wait(
      mirrors.map((m) => _probe(m, timeout, token)),
    );
    final ok = results.where((e) => e.$2 != null).toList()
      ..sort((a, b) => a.$2!.compareTo(b.$2!));
    if (ok.isEmpty) {
      throw DownloadException('所有镜像源探测失败（网络不通或超时）');
    }
    return ok.map((e) => e.$1).toList();
  }

  static Future<(MirrorSource, Duration?)> _probe(
    MirrorSource m,
    Duration timeout,
    DownloadCancelToken? token,
  ) async {
    if (token?.isCancelled ?? false) return (m, null);
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client
          .getUrl(Uri.parse(m.url))
          .timeout(timeout);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${probeBytes - 1}');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 206 && resp.statusCode != 200) {
        return (m, null);
      }
      // 读完 64KB 即视为"可达且够快"（首块到达时间 ≈ 整体读取时间）
      await resp.drain<void>().timeout(timeout);
      return (m, sw.elapsed);
    } catch (_) {
      return (m, null);
    } finally {
      client.close(force: true);
    }
  }

  /// 流式计算 [path] 的 SHA-256，与期望值比对（不整读进内存）。
  static Future<bool> verifySha256(String path, String sha256) async {
    if (sha256.isEmpty) return true;
    try {
      return await _sha256Of(path) == sha256;
    } catch (_) {
      return false;
    }
  }

  /// 流式计算 [path] 的 SHA-1，与期望值比对（Android SDK 仓库索引
  /// repo2-3.xml 的 checksum 是 SHA-1，40 位十六进制）。
  static Future<bool> verifySha1(String path, String expectedSha1) async {
    if (expectedSha1.isEmpty) return true;
    try {
      final digest = await sha1.bind(File(path).openRead()).first;
      return digest.toString() == expectedSha1;
    } catch (_) {
      return false;
    }
  }

  /// 多线程分段并发下载（核心入口）。
  ///
  /// [mirrors] 应为竞速排序后的镜像（最快在前）；[expectedSize] 必须 >0。
  /// 若 [savePath] 已存在且尺寸/SHA 校验通过 → 直接返回（快路径，不下载）。
  /// 失败抛 [DownloadException]（分片 .p<i> 残留，供下次续传）。
  static Future<void> downloadMultiSource(
    List<MirrorSource> mirrors,
    String savePath,
    int expectedSize, {
    int segments = defaultSegments,
    String? sha256,
    String? sha1,
    DownloadCancelToken? token,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorUsed,
  }) async {
    // ---- 快路径：已下载且校验通过（解压失败重试时直接复用）----
    if (expectedSize > 0) {
      final existing = File(savePath);
      if (await existing.exists() &&
          await existing.length() == expectedSize &&
          await verifySha256(savePath, sha256 ?? '') &&
          await verifySha1(savePath, sha1 ?? '')) {
        onProgress?.call(
          DownloadProgress(received: expectedSize, total: expectedSize, speed: 0),
        );
        return;
      }
      if (await existing.exists()) await existing.delete(); // 尺寸/校验不符：清掉重下
    }

    if (mirrors.isEmpty) throw DownloadException('没有可用镜像源');
    if (expectedSize <= 0) throw DownloadException('未知文件大小，无法分段下载');

    // ---- 分片区间（[start, end)，最后一个分片可能偏短）----
    final n = segments < 1
        ? 1
        : (segments > expectedSize ? expectedSize : segments);
    final segSize = (expectedSize + n - 1) ~/ n;
    final segs = <({int start, int end})>[];
    for (var i = 0; i < n; i++) {
      final start = i * segSize;
      final end = start + segSize > expectedSize ? expectedSize : start + segSize;
      if (start >= end) break;
      segs.add((start: start, end: end));
    }

    // ---- 进度聚合（单线程事件循环，无竞态）----
    var totalDone = 0;
    final parts = <File>[];
    for (var i = 0; i < segs.length; i++) {
      final p = File('$savePath.p$i');
      if (await p.exists()) {
        final l = await p.length();
        totalDone += l > segs[i].end - segs[i].start
            ? segs[i].end - segs[i].start
            : l;
      }
      parts.add(p);
    }
    var windowBytes = 0;
    var windowAt = DateTime.now();
    void emit() {
      final now = DateTime.now();
      final dt = now.difference(windowAt).inMilliseconds;
      if (dt < 200) return;
      final speed = dt == 0 ? 0.0 : windowBytes / dt * 1000;
      windowBytes = 0;
      windowAt = now;
      onProgress?.call(
        DownloadProgress(received: totalDone, total: expectedSize, speed: speed),
      );
    }

    // ---- 各分片并发下载（Future.wait 同时发出 N 路请求）----
    await Future.wait([
      for (var i = 0; i < segs.length; i++)
        _downloadSegment(
          mirrors,
          index: i,
          seg: segs[i],
          partFile: parts[i],
          token: token,
          onChunk: (len) {
            totalDone += len;
            windowBytes += len;
            emit();
          },
          onMirrorUsed: onMirrorUsed,
        ),
    ]);
    if (token?.isCancelled ?? false) throw DownloadException('已取消');

    // ---- 拼接分片 → 落盘 → 删除分片 ---- 
    final out = File(savePath);
    if (await out.exists()) await out.delete();
    final sink = out.openWrite();
    for (final p in parts) {
      if (token?.isCancelled ?? false) {
        await sink.close();
        throw DownloadException('已取消');
      }
      await sink.addStream(p.openRead());
    }
    await sink.close();
    if (await out.length() != expectedSize) {
      await out.delete();
      throw DownloadException('拼接后大小不符（期望 $expectedSize）');
    }
    for (final p in parts) {
      if (await p.exists()) await p.delete();
    }

    // ---- SHA-256 / SHA-1 校验（失败清掉全部，下次从头）----
    if (sha256 != null || sha1 != null) {
      final ok256 = await verifySha256(savePath, sha256 ?? '');
      final ok1 = await verifySha1(savePath, sha1 ?? '');
      if (!ok256 || !ok1) {
        await out.delete();
        throw DownloadException('校验失败（sha256=$ok256, sha1=$ok1）');
      }
    }
    onProgress?.call(
      DownloadProgress(received: expectedSize, total: expectedSize, speed: 0),
    );
  }

  /// 下载单个分片：Range 请求写入分片 .p<i>，失败/卡住自动换镜像续传。
  static Future<void> _downloadSegment(
    List<MirrorSource> mirrors, {
    required int index,
    required ({int start, int end}) seg,
    required File partFile,
    DownloadCancelToken? token,
    required void Function(int) onChunk,
    void Function(MirrorSource)? onMirrorUsed,
  }) async {
    final segLen = seg.end - seg.start;
    var done = 0;
    if (await partFile.exists()) {
      final l = await partFile.length();
      done = l > segLen ? segLen : l;
    }
    if (done >= segLen) return; // 该分片已完成（上次遗留）

    // 镜像轮流起步：分片 i → 镜像 i % n（多镜像并行），失败向后换
    final startIdx = index % mirrors.length;
    var lastError = '分片 $index 下载失败';

    for (var offset = 0; offset < mirrors.length; offset++) {
      final mirror = mirrors[(startIdx + offset) % mirrors.length];
      if (token?.isCancelled ?? false) throw DownloadException('已取消');
      onMirrorUsed?.call(mirror);

      final raf = await partFile.open(mode: FileMode.append);
      var attempt = 0;
      try {
        while (true) {
          attempt++;
          if (token?.isCancelled ?? false) throw DownloadException('已取消');
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 20);
          try {
            final req = await client.getUrl(Uri.parse(mirror.url));
            req.headers.set(
              HttpHeaders.rangeHeader,
              'bytes=${seg.start + done}-${seg.end - 1}',
            );
            final resp = await req.close();
            if (resp.statusCode == 200) {
              // 不支持 Range：该镜像无法分段，直接换镜像
              throw DownloadException('服务器不支持 Range（HTTP 200）');
            }
            if (resp.statusCode != 206) {
              throw DownloadException('下载被拒绝（HTTP ${resp.statusCode}）');
            }
            var lastByteAt = DateTime.now();
            await for (final chunk in resp) {
              if (token?.isCancelled ?? false) throw DownloadException('已取消');
              await raf.writeFrom(chunk);
              done += chunk.length;
              lastByteAt = DateTime.now();
              onChunk(chunk.length);
              // 卡住熔断：15s 无数据 → 换下一个镜像续传
              if (DateTime.now().difference(lastByteAt) >= stallTimeout) {
                throw DownloadException('镜像无进展（${stallTimeout.inSeconds}s 无数据）');
              }
            }
            await raf.flush();
            if (done < segLen) {
              throw DownloadException('分片不完整（$done/$segLen）');
            }
            return; // 分片完成
          } on DownloadException {
            // 明确失败原因：不浪费重试，直接换镜像（分片续传）
            client.close(force: true);
            rethrow;
          } catch (_) {
            client.close(force: true);
            if (attempt >= maxRetriesPerMirror) {
              throw DownloadException('网络错误（分片 $index）');
            }
            // 瞬时网络抖动：同一镜像重试
          }
        }
      } on DownloadException catch (e) {
        lastError = e.message;
      } catch (_) {
        lastError = '网络错误（分片 $index）';
      } finally {
        await raf.close(); // 成功/失败统一释放句柄
      }
      // 换下一个镜像（.p<i> 保留，长度即续传点）
    }
    throw DownloadException(lastError);
  }

  static Future<String> _sha256Of(String path) async {
    final file = File(path);
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
