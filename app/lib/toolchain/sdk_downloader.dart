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

  /// 响应头超时：TCP 连上后服务器 hang 住不回 Range 响应头的场景
  ///（connectionTimeout 只管三次握手，管不了请求发出后的等待）。
  static const Duration respHeaderTimeout = Duration(seconds: 20);
  static const int defaultSegments = 4;

  /// 慢速熔断：有数据但涓流（如 16KB/s 涓流不死流）——stallTimeout 抓不到，
  /// 只能靠窗口均速判定。窗口 ≥ [slowSpeedWindow] 时算一次均速，
  /// 低于 [slowSpeedFloor] 判定该镜像限速 → 抛出换源（.p<i> 保留，续传代价低）。
  /// 阈值取 64KB/s：教育网镜像正常 ≥5MB/s，GitHub 直链国内一般 ≥200KB/s，
  /// 明显低于一切"健康源"下限，误杀率低。
  static const Duration slowSpeedWindow = Duration(seconds: 10);
  static const int slowSpeedFloor = 64 * 1024;

  /// Bug 456：当前下载任务的分片布局/分片文件表。
  ///
  /// 仅用于「服务器不支持 Range → 整包兜底」时让分片 0 知道：要把整份文件
  /// 写进哪个分片、以及哪些分片需要被跳过。单线程事件循环下同一时刻只有一个
  /// 下载任务，用静态字段传递是安全的（任务结束在 finally 里清空）。
  static List<({int start, int end})>? _currentSegsHint;
  static List<File>? _currentPartsHint;

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
    // Bug 456 的整包兜底需要知道全部分片布局才能"只写 .p0、其余标记完成"，
    // 故经实例字段传递（Dart 无闭包捕获跨静态方法外层的便利）。
    _currentSegsHint = segs;
    _currentPartsHint = parts;
    try {
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
    } finally {
      _currentSegsHint = null;
      _currentPartsHint = null;
    }
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
      // Bug 456：整包兜底路径需要提前释放 raf（随后由分片 0 重写 .p0），
      // 用标志位让 finally 不再二次 close —— 重复 close 会抛
      // FileSystemException('File closed')，把成功的下载变成失败。
      var rafClosed = false;
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
            // 响应头超时（Bug 421）：服务器 hang 住不回头的场景，
            // 超时抛 TimeoutException → 重试/换镜像
            final resp = await req.close().timeout(respHeaderTimeout);
            if (resp.statusCode == 200) {
              // Bug 456：服务器不支持 Range（整包回 200）。
              // 原实现在此直接抛异常换镜像——但 cloudflared 只有 2 个源，
              // GitHub 直链国内不通，等于整链必失败（用户实测报"下载失败"）。
              // 正确做法：**退化为单流整包下载**（由分片 0 承担），
              // 其余分片清空即视为完成。代价是没有并发，但没有并发也远好过装不上。
              //
              // 注意：此处**不能**在这里直接跑兜底——本分片可能是 index != 0，
              // 而兜底要写 .p0 并清空别的分片，会和正在并发运行的分片互相踩。
              // 正确做法是让**分片 0** 去执行：这里只把分片 0 标记为"必须兜底"，
              // 自己作为非 0 分片直接静默返回（内容由分片 0 提供）。
              if (index != 0) {
                // 非 0 分片遇到不支持 Range：本分片无法独立完成，交给分片 0。
                // 释放句柄后直接返回；.p{index} 保持空长度 → 拼接时贡献 0 字节。
                await resp.drain<void>();
                return;
              }
              // index == 0：先释放请求与文件句柄，再整体兜底（避免双重 close）
              await resp.drain<void>();
              client.close(force: true);
              await raf.close();
              rafClosed = true;
              await _downloadAsWholeFile(
                mirror,
                segs: _currentSegsHint,
                partFiles: _currentPartsHint,
                token: token,
                onChunk: onChunk,
              );
              return;
            }
            if (resp.statusCode != 206) {
              throw DownloadException('下载被拒绝（HTTP ${resp.statusCode}）');
            }
            // 慢速熔断滑动窗口（见 slowSpeedWindow 注释）
            var slowAt = DateTime.now();
            var slowBytes = 0;
            // 卡住熔断（Bug 421 修正）：必须由 Stream.timeout 驱动——
            // 原实现把"15s 无数据"检查写在读流循环体内，只在数据到达时
            // 执行；服务端 hang 住（连接在、不吐数据）时循环挂起，检查
            // 永远不运行，熔断形同虚设（真机实测卡死在 80.2/91.8MB）。
            // Stream.timeout 在事件间隔超 stallTimeout 时抛
            // TimeoutException → 走重试/换镜像，分片续传。
            await for (final chunk in resp.timeout(stallTimeout)) {
              if (token?.isCancelled ?? false) throw DownloadException('已取消');
              await raf.writeFrom(chunk);
              done += chunk.length;
              onChunk(chunk.length);
              // 慢速熔断：窗口均速过低（涓流，有数据但 <64KB/s）→ 换镜像
              slowBytes += chunk.length;
              final slowDt = DateTime.now().difference(slowAt);
              if (slowDt >= slowSpeedWindow) {
                final bps = slowBytes / slowDt.inMilliseconds * 1000;
                if (bps < slowSpeedFloor) {
                  throw DownloadException(
                      '镜像限速（${(bps / 1024).toStringAsFixed(0)}KB/s '
                      '< ${(slowSpeedFloor / 1024)}KB/s）');
                }
                slowAt = DateTime.now();
                slowBytes = 0;
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
        if (!rafClosed) await raf.close(); // 成功/失败统一释放句柄
      }
      // 换下一个镜像（.p<i> 保留，长度即续传点）
    }
    throw DownloadException(lastError);
  }

  /// Bug 456：镜像不支持 Range 时的**整包单流下载**兜底。
  ///
  /// 背景：`_downloadSegment` 原本要求分片请求必须回 206，遇到回 200 的镜像
  /// 直接判"该镜像不能用"并换源。对多镜像的 SDK 下载（清华/阿里/华为…）无所谓，
  /// 但像 cloudflared 这样**只有 2 个源、且其中一个国内不通**的资产，路径就断了：
  /// 唯一可用的镜像若回 200，整条链必然失败。
  ///
  /// 本方法把"整包"当成一个覆盖 `[0, expectedSize)` 的分片写入 `.p0`，
  /// 其余分片文件**清空**（长度 0 即天然"已完成"，拼接阶段会跳过它们）。
  /// 这样拼接/SHA 校验逻辑完全不用改，也不会被其它分片的并发写破坏。
  ///
  /// 代价：没有并发。但在"能装 vs 装不上"之间，这个取舍没有悬念。
  static Future<void> _downloadAsWholeFile(
    MirrorSource mirror, {
    required List<({int start, int end})>? segs,
    required List<File>? partFiles,
    DownloadCancelToken? token,
    required void Function(int) onChunk,
  }) async {
    final layout = segs;
    final parts = partFiles;
    if (layout == null || parts == null || layout.isEmpty) {
      throw DownloadException('整包兜底缺少分片布局');
    }
    final fullLen = layout.last.end;
    final target = parts[0];
    // 清掉其它分片：长度 0 → 拼接阶段视作"该分片已完成且无内容"。
    // 先删再建空文件，避免留下上一轮的旧长度造成拼接错位。
    for (var i = 1; i < parts.length; i++) {
      if (await parts[i].exists()) await parts[i].delete();
      await parts[i].create();
    }
    if (await target.exists()) await target.delete();

    var attempt = 0;
    while (true) {
      attempt++;
      if (token?.isCancelled ?? false) throw DownloadException('已取消');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      final raf = await target.open(mode: FileMode.write);
      var written = 0;
      try {
        // 不带 Range 头：整包从头下载
        final resp =
            await client.getUrl(Uri.parse(mirror.url)).then((r) => r.close())
                .timeout(respHeaderTimeout);
        if (resp.statusCode != 200 && resp.statusCode != 206) {
          throw DownloadException('整包下载被拒绝（HTTP ${resp.statusCode}）');
        }
        if (resp.contentLength > 0 && resp.contentLength != fullLen) {
          throw DownloadException(
              '整包长度不符（期望 $fullLen，服务端 ${resp.contentLength}）');
        }
        var slowAt = DateTime.now();
        var slowBytes = 0;
        await for (final chunk in resp.timeout(stallTimeout)) {
          if (token?.isCancelled ?? false) throw DownloadException('已取消');
          await raf.writeFrom(chunk);
          written += chunk.length;
          onChunk(chunk.length);
          slowBytes += chunk.length;
          final slowDt = DateTime.now().difference(slowAt);
          if (slowDt >= slowSpeedWindow) {
            final bps = slowBytes / slowDt.inMilliseconds * 1000;
            if (bps < slowSpeedFloor) {
              throw DownloadException(
                  '镜像限速（${(bps / 1024).toStringAsFixed(0)}KB/s '
                  '< ${(slowSpeedFloor / 1024)}KB/s）');
            }
            slowAt = DateTime.now();
            slowBytes = 0;
          }
        }
        await raf.flush();
        if (written != fullLen) {
          throw DownloadException('整包不完整（$written/$fullLen）');
        }
        return; // 成功
      } on DownloadException {
        client.close(force: true);
        rethrow;
      } catch (_) {
        client.close(force: true);
        if (attempt >= maxRetriesPerMirror) {
          throw DownloadException('整包下载网络错误（${mirror.name}）');
        }
      } finally {
        await raf.close();
      }
      // 重试：从头（整包没有续传点，只能重来）
      if (attempt < maxRetriesPerMirror && await target.exists()) {
        await target.delete();
      }
    }
  }

  static Future<String> _sha256Of(String path) async {
    final file = File(path);
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
