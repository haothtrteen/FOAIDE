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
  final double speed; // 字节/秒（最近 200ms 窗口）
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
/// 镜像并发竞速选源 → 断点续传（Range）→ SHA-256 校验 → 失败自动换镜像。
///
/// 设计要点（Bug 219 起积累）：
/// - 竞速：对每个镜像发 Range 首 64KB 探测，读完耗时最短者胜；
/// - 续传：.part 文件已有长度 >0 时发 `bytes=<done>-`，服务器拒 206 则重下；
/// - 校验：完成时 sha256 流式计算（openRead 分块，不整读进内存）；
/// - 降级：单个镜像连续失败 _maxRetries 次后换竞速排序的下一个镜像。
class SdkDownloader {
  static const int probeBytes = 65536;
  static const int maxRetriesPerMirror = 2;

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

  /// 断点续传下载：下载到 [savePath]，校验通过后改名落盘（无 .part 残留）。
  /// 失败抛 [DownloadException]（.part 可能残留，供换镜像续传）。
  static Future<void> download(
    MirrorSource source,
    String savePath,
    int expectedSize, {
    String? sha256,
    DownloadCancelToken? token,
    void Function(DownloadProgress)? onProgress,
  }) async {
    final partPath = '$savePath.part';
    final part = File(partPath);
    var done = 0;
    if (await part.exists()) {
      done = await part.length();
      if (done > 0 && expectedSize > 0 && done >= expectedSize) {
        done = 0; // 上次已下完但未校验成功：从头来
      }
    }
    final raf = await part.open(mode: FileMode.append);

    for (var attempt = 1; ; attempt++) {
      if (token?.isCancelled ?? false) {
        await raf.close();
        throw DownloadException('已取消');
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      try {
        final req = await client.getUrl(Uri.parse(source.url));
        if (done > 0) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$done-');
        }
        final resp = await req.close();
        if (resp.statusCode == 200) {
          // 服务器不支持 Range：从头重下
          if (done > 0) {
            done = 0;
            await raf.truncate(0);
          }
        } else if (resp.statusCode != 206) {
          throw DownloadException('下载被拒绝（HTTP ${resp.statusCode}）');
        }
        final total = resp.contentLength > 0
            ? done + resp.contentLength
            : expectedSize;
        var speedWindow = 0;
        var lastSpeedAt = DateTime.now();
        await for (final chunk in resp) {
          if (token?.isCancelled ?? false) {
            throw DownloadException('已取消');
          }
          await raf.writeFrom(chunk);
          done += chunk.length;
          speedWindow += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastSpeedAt) >= const Duration(milliseconds: 200)) {
            final dt = now.difference(lastSpeedAt).inMilliseconds;
            final speed = dt == 0 ? 0.0 : speedWindow / dt * 1000;
            speedWindow = 0;
            lastSpeedAt = now;
            onProgress?.call(
              DownloadProgress(received: done, total: total, speed: speed),
            );
          }
        }
        await raf.flush();
        await raf.close();
        if (expectedSize > 0 && done != expectedSize) {
          throw DownloadException('大小不符：期望 $expectedSize，实际 $done');
        }
        // SHA-256 流式校验
        if (sha256 != null) {
          final hash = await _sha256Of(partPath);
          if (hash != sha256) {
            await part.delete();
            throw DownloadException('SHA-256 校验失败（$hash）');
          }
        }
        await part.rename(savePath);
        onProgress?.call(
          DownloadProgress(received: done, total: done, speed: 0),
        );
        return;
      } on DownloadException {
        client.close(force: true);
        if (attempt >= maxRetriesPerMirror) rethrow;
      } catch (_) {
        client.close(force: true);
        if (attempt >= maxRetriesPerMirror) {
          throw DownloadException('下载失败（网络错误）');
        }
      }
    }
  }

  /// 按竞速排序依次尝试全部镜像；全部失败抛最后一次异常。
  static Future<void> downloadWithFailover(
    List<MirrorSource> orderedMirrors,
    String savePath,
    int expectedSize, {
    String? sha256,
    DownloadCancelToken? token,
    void Function(DownloadProgress)? onProgress,
    void Function(MirrorSource)? onMirrorSwitch,
  }) async {
    DownloadException? last;
    for (final m in orderedMirrors) {
      if (token?.isCancelled ?? false) {
        throw DownloadException('已取消');
      }
      onMirrorSwitch?.call(m);
      try {
        await download(
          m,
          savePath,
          expectedSize,
          sha256: sha256,
          token: token,
          onProgress: onProgress,
        );
        return;
      } on DownloadException catch (e) {
        last = e;
        // 校验失败已清理 .part；网络失败残留 .part 供下一个镜像续传
      }
    }
    throw last ?? DownloadException('下载失败');
  }

  static Future<String> _sha256Of(String path) async {
    final file = File(path);
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
