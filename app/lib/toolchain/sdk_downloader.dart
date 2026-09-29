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

/// 信号：镜像不支持 Range 请求（整包回 HTTP 200）。
///
/// **不是错误**，是需要外层切换策略的信号（Bug 470）。
/// 分片函数抛出它 → 外层收齐所有分片后改走单流整包下载。
///
/// 为什么要单独一个类型：混进 `DownloadException` 会被分片里的
/// `on DownloadException { rethrow }` 当成"明确失败"直接换镜像重试，
/// 而换镜像结果一样（同一个源就是没开 Range），白白多跑 N 轮。
class _RangeUnsupported implements Exception {
  const _RangeUnsupported();
  @override
  String toString() => '镜像不支持 Range 请求';
}

/// 单个镜像的探测结果（Bug 464：把失败原因**留证**，不再一律吞掉）。
///
/// 背景：`_probe` 原先 `catch (_) { return (m, null); }` —— 任何异常都被
/// 吞成"不可用"。用户只看到「所有镜像源探测失败（网络不通或超时）」，
/// 无法判断是 DNS 没解析、TLS 握手失败、还是被墙/超时。cloudflared 下载
/// 反复失败却无从下手，根因就在这里：**失败信息在源头就丢了**。
///
/// 现在每个镜像都留下 [error] 与 [elapsed]，UI 可逐条展示。
class MirrorProbe {
  final MirrorSource mirror;
  final bool ok;
  final Duration? elapsed;

  /// 失败原因（ok=false 时非空）：如 `SocketException: Failed host lookup`。
  final String? error;

  const MirrorProbe({
    required this.mirror,
    required this.ok,
    this.elapsed,
    this.error,
  });

  /// 面向用户的一行摘要。
  String get summary {
    if (ok) {
      final ms = elapsed?.inMilliseconds ?? 0;
      return '${mirror.name}：可用（${ms}ms）';
    }
    return '${mirror.name}：失败（${error ?? '未知原因'}）';
  }
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

  // （已删除 Bug 456 时代用于传参的 _currentSegsHint / _currentPartsHint：
  //   Bug 470 把整包兜底提到外层 Future.wait 之后统一执行，
  //   布局与分片表以普通参数传递即可，不再需要静态字段传参。）

  /// 并发竞速选源：返回按"探测耗时升序"排序的镜像列表（最快在前）。
  /// 全部探测失败抛 [DownloadException]。
  static Future<List<MirrorSource>> pickFastest(
    List<MirrorSource> mirrors, {
    Duration timeout = const Duration(seconds: 12),
    DownloadCancelToken? token,
  }) async {
    final probes = await diagnose(mirrors, timeout: timeout, token: token);
    final ok = probes.where((p) => p.ok).toList()
      ..sort((a, b) => (a.elapsed ?? Duration.zero)
          .compareTo(b.elapsed ?? Duration.zero));
    if (ok.isEmpty) {
      // Bug 464：把每个源的具体失败原因带出去，别再只说"网络不通"。
      // 用户据此能区分"DNS 解析不了"（该换 DNS）与"超时"（该换网络）。
      final detail = probes.map((p) => '· ${p.summary}').join('\n');
      throw DownloadException('所有镜像源探测失败：\n$detail');
    }
    return ok.map((p) => p.mirror).toList();
  }

  /// Bug 464：逐镜像探测并**保留失败原因**（供「下载诊断」按钮与错误文案用）。
  static Future<List<MirrorProbe>> diagnose(
    List<MirrorSource> mirrors, {
    Duration timeout = const Duration(seconds: 12),
    DownloadCancelToken? token,
  }) async {
    return Future.wait(
      mirrors.map((m) => _probeDetailed(m, timeout, token)),
    );
  }

  static Future<MirrorProbe> _probeDetailed(
    MirrorSource m,
    Duration timeout,
    DownloadCancelToken? token,
  ) async {
    if (token?.isCancelled ?? false) {
      return MirrorProbe(mirror: m, ok: false, error: '已取消');
    }
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.parse(m.url)).timeout(timeout);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${probeBytes - 1}');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 206 && resp.statusCode != 200) {
        await resp.drain<void>().catchError((_) {});
        return MirrorProbe(
          mirror: m,
          ok: false,
          error: 'HTTP ${resp.statusCode}',
        );
      }
      await resp.drain<void>().timeout(timeout);
      return MirrorProbe(mirror: m, ok: true, elapsed: sw.elapsed);
    } on SocketException catch (e) {
      // DNS / 连接被拒 / 网络不可达——最常见
      return MirrorProbe(mirror: m, ok: false, error: '网络：${e.osError?.message ?? e.message}');
    } on HandshakeException catch (e) {
      return MirrorProbe(mirror: m, ok: false, error: 'TLS 握手失败：${e.message}');
    } on TimeoutException {
      return MirrorProbe(mirror: m, ok: false, error: '超时（${timeout.inSeconds}s）');
    } catch (e) {
      return MirrorProbe(mirror: m, ok: false, error: e.toString());
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

    // ---- Bug 471：确保**父目录存在**（这是"UI 不行、终端可以"的真正原因）----
    //
    // 真机报错：
    //   PathNotFoundException: Cannot open file,
    //   path = '.../files/rootfs/debian/opt/foa-bin/cloudflared.dl.p0'
    //   (OS Error: No such file or directory, errno = 2)
    //
    // 注意 errno=2 是 **ENOENT**（打不开），不是句柄失效。也就是说
    // `open(mode: FileMode.append)` 时那个文件**连同它的父目录都不存在**。
    //
    // 为什么终端里 `wget -O` 能成功、UI 里就失败：**终端那行命令是
    // `mkdir -p <dir> && wget ...`，我们自己建了目录**；而 UI 走的是
    // 这段 Dart 代码——它**从头到尾没有建过目录**，把"父目录已存在"
    // 当成了调用方的责任。`cloudflared_install.dart` 里确实有
    // `mkdir -p $dirPath`，但那在**落位那一步**（下载成功之后），
    // 时序上晚于本次下载 → 目录还没建，下载先挂了。
    //
    // 修法：下载器自己保证目录存在（幂等，已存在则 no-op）。
    // **不依赖调用方**——这类"把前置条件推给调用方"的写法在项目里
    // 已经坑过多次（Bug 464 的读写不对称是同一类）。下载器要能独立工作：
    // 给它一个路径，它就该负责把文件放进去。
    final parent = Directory(File(savePath).parent.path);
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

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
    // Bug 470：镜像不支持 Range 时不再由分片就地兜底（那会与并发分片抢文件），
    // 而是抛出 [_RangeUnsupported] 信号，等这里收齐全部分片后再统一处理。
    var needWholeFile = false;
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
        ).catchError((Object e) {
          // 必须在这里吞掉：Future.wait 遇任一抛错就整体失败，
          // 而我们想要的是「其余分片正常收尾，之后再统一兜底」。
          if (e is _RangeUnsupported) {
            needWholeFile = true;
            return;
          }
          throw e; // 其它异常照常上抛
        }),
    ]);
    if (token?.isCancelled ?? false) throw DownloadException('已取消');

    // ---- 兜底：所有分片已退出，此时才安全地改写文件 ----
    // 这一刻不存在任何分片持有 .p<i> 的打开句柄，删/建都不会踩到别人。
    // （这与 Bug 470 之前的实现是本质区别：原先由分片 0 在并发期就地兜底，
    //   会删掉分片 1..n 正在持有的文件。）
    if (needWholeFile) {
      await _downloadAsWholeFile(
        mirrors,
        totalBytes: expectedSize,
        savePath: savePath,
        token: token,
        onChunk: (len) {
          totalDone += len;
          windowBytes += len;
          emit();
        },
      );
      // 兜底直接写的是最终 savePath，无需拼接；做完整性 + 校验后收工。
      final f = File(savePath);
      if (await f.length() != expectedSize) {
        await f.delete();
        throw DownloadException('整包兜底后大小不符（期望 $expectedSize）');
      }
      if (sha256 != null || sha1 != null) {
        final ok256 = await verifySha256(savePath, sha256 ?? '');
        final ok1 = await verifySha1(savePath, sha1 ?? '');
        if (!ok256 || !ok1) {
          await f.delete();
          throw DownloadException('校验失败（sha256=$ok256, sha1=$ok1）');
        }
      }
      // 清掉分片残留
      for (final p in parts) {
        if (await p.exists()) await p.delete();
      }
      onProgress?.call(
        DownloadProgress(received: expectedSize, total: expectedSize, speed: 0),
      );
      return;
    }

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
              // Bug 456 / Bug 470：服务器不支持 Range（整包回 200）。
              //
              // 历史实现让**分片 0 就地**执行整包兜底（写 .p0、删掉 .p1..n）。
              // 那是个竞态：分片 0 删文件时，分片 1..n 可能仍持有这些文件的
              // 打开句柄（在 369 行以 append 打开），随后 close/flush 就报
              // `PathNotFoundException: Cannot open file '.../x.dl.p1'`
              // ——真机实测表现极具误导性：**4/4 镜像全可用却"下载失败"**。
              //
              // 现在改为：**任何分片**遇到 200 都只抛这个专用信号，
              // 由外层在 `Future.wait` 收齐全部分片后再统一兜底。
              // 那时所有分片都已退出，绝无句柄与文件的交叠。
              await resp.drain<void>();
              client.close(force: true);
              throw const _RangeUnsupported();
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
          } on _RangeUnsupported {
            // Bug 470：不支持 Range 是**策略信号**，不是错误——
            // 必须原样穿透（既不能重试也不能换镜像：同一批源都没开 Range），
            // 由外层收齐全部分片后统一切到整包单流。
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
      } on _RangeUnsupported {
        // 同样必须穿透：若被下面的 `catch (_)` 吞成"网络错误"，
        // 信号就丢了，外层永远不知道该走整包兜底。
        rethrow;
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

  /// Bug 456 / Bug 470：镜像不支持 Range 时的**整包单流下载**兜底。
  ///
  /// 背景：`_downloadSegment` 要求分片请求必须回 206，遇到回 200 的镜像
  /// 就无法分段。对多镜像的 SDK 下载（清华/阿里/华为…）无所谓，
  /// 但像 cloudflared 这样源较少的资产，路径就断了。
  ///
  /// **Bug 470 重写**：本方法原先由分片 0 **就地**调用，会 delete 掉
  /// `.p1..pn` —— 而此时分片 1..n 可能仍持有这些文件的打开句柄，
  /// 于是 close/flush 报 `PathNotFoundException`（真机表现为
  /// 「4/4 镜像全可用却下载失败」）。
  ///
  /// 现在本方法**只在所有分片都已退出后**由外层调用，因此：
  /// - 不再需要"清空其它分片"（它们已经不写了，外层会在结束后统一删）；
  /// - 直接写入最终 [savePath]，省掉一次拼接；
  /// - 失败时自动轮换镜像（多源，且**每个源都试**，不再只试探测最快那个）。
  static Future<void> _downloadAsWholeFile(
    List<MirrorSource> mirrors, {
    required int totalBytes,
    required String savePath,
    DownloadCancelToken? token,
    required void Function(int) onChunk,
  }) async {
    final fullLen = totalBytes;
    final out = File(savePath);
    if (await out.exists()) await out.delete();

    Object? lastError;
    for (final mirror in mirrors) {
      var attempt = 0;
      while (attempt < maxRetriesPerMirror) {
        attempt++;
        if (token?.isCancelled ?? false) throw DownloadException('已取消');
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20);
        final raf = await out.open(mode: FileMode.write);
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
        } on DownloadException catch (e) {
          client.close(force: true);
          // 该源明确失败（拒绝/限速/长度不符）→ 不再对它重试，换下一个源
          lastError = e;
          break;
        } catch (e) {
          client.close(force: true);
          lastError = e;
          if (attempt >= maxRetriesPerMirror) {
            // 本源的瞬时错误重试用尽 → 换下一个源
            break;
          }
        } finally {
          await raf.close();
        }
        // 重试：从头（整包没有续传点，只能重来）
        if (await out.exists()) await out.delete();
      }
    }
    throw DownloadException(
        '整包下载失败（已尝试 ${mirrors.length} 个源）：$lastError');
  }

  static Future<String> _sha256Of(String path) async {
    final file = File(path);
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}
