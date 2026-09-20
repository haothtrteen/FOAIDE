import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/editor/web_preview_service.dart';

/// alpha.57 Web 实时预览：启动/信号命令的文本断言 + shell 语法门禁。
///
/// 背景（同 Bug 424/449 方法论）：沙箱出包不走 WebPreviewService，
/// analyze/test 覆盖不到 shell 运行时行为——只能靠**文本断言**拦住
/// 转义边界回归，靠 **bash/dash -n** 拦住语法错误。凡被执行的脚本
/// 必须可被单测语法检查（Bug 449 设立的门禁，此处一并适用）。
void main() {
  const pid = '/tmp/foa_web_preview.pid';

  String command() => WebPreviewService.startCommand(
        proj: "'/root/projects/my_demo'",
        envPart: 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt ',
        pidFilePath: pid,
        webPort: WebPreviewService.port,
      );

  group('WebPreviewService.startCommand · 结构断言', () {
    test('常驻入口：exec flutter run -d web-server + 固定端口与主机名', () {
      final cmd = command();
      expect(cmd.contains('exec flutter run -d web-server'), isTrue,
          reason: 'exec 是进程内替换——pid 文件才能指向 flutter run 进程');
      expect(cmd.contains('--web-hostname=127.0.0.1'), isTrue);
      expect(cmd.contains('--web-port=8090'), isTrue);
      expect(cmd.contains("cd '/root/projects/my_demo' && "), isTrue);
    });

    test(r'pid 记录：echo $$ 写 pid 文件（$$ 是 shell 层变量，不得被 Dart 插值吃掉）', () {
      final cmd = command();
      expect(cmd.contains('echo \$\$ > $pid'), isTrue,
          reason: r'写成 Dart 插值 $$ 会变空串 → pid 文件恒空 → 热重载永远 GONE');
      expect(cmd.contains(r'echo $ > '), isFalse,
          reason: r'Dart 插值把 $$ 吃掉 = Bug 424 同款转义事故');
    });

    test('残留清理：启动前先杀孤儿会话（端口占用防线）', () {
      final cmd = command();
      expect(cmd.contains('kill -0'), isTrue);
      expect(cmd.contains('kill -9'), isTrue);
      expect(cmd.contains('rm -f $pid'), isTrue);
    });

    test('web 平台自检：缺 web/index.html 则 flutter create --platforms=web 补建', () {
      final cmd = command();
      expect(cmd.contains('[ ! -f web/index.html ]'), isTrue);
      expect(cmd.contains('--platforms=web'), isTrue);
      expect(cmd.contains('--no-pub'), isTrue,
          reason: 'create 不跑 pub get——后面统一轮换');
      expect(cmd.contains('exit 71'), isTrue,
          reason: '补建失败必须退出（exit 71），不能带着缺 web/ 的工程继续 run');
    });

    test('pub 多源轮换：三源两试 + exit 69 哨兵（Bug 423 同款）', () {
      final cmd = command();
      expect(cmd.contains('https://pub.flutter-io.cn'), isTrue);
      expect(cmd.contains('mirrors.tuna.tsinghua.edu.cn/dart-pub'), isTrue);
      expect(cmd.contains('mirrors.ustc.edu.cn/dart-pub'), isTrue);
      expect(cmd.contains('exit 69'), isTrue);
      // shell 层变量必须保留转义形态（Dart 源码 r'' 输出无反斜杠）
      expect(cmd.contains(r'$src'), isTrue);
      expect(cmd.contains(r'$ok'), isTrue);
    });

    test('前置环境：ALLOW_ROOT + storage 镜像 + CA bundle（Bug 419/425）', () {
      final cmd = command();
      expect(cmd.contains('FLUTTER_ALLOW_ROOT=true'), isTrue);
      expect(
          cmd.contains('FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn'),
          isTrue);
      expect(cmd.contains('SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt'),
          isTrue);
    });

    test('版本检查 stamp（Bug 436）与转发层再断言（Bug 433）都在位', () {
      final cmd = command();
      expect(cmd.contains('flutter_version_check.stamp'), isTrue,
          reason: 'web 预览同样触发 3 天一次的 git fetch --tags，504 白等');
      expect(cmd.contains('REASSERT='), isTrue,
          reason: 'pub get 可能触发引擎构件下载覆盖转发脚本，run 前必须再断言');
    });
  });

  group('WebPreviewService · shell 语法门禁（Bug 449 门禁的适用）', () {
    test('startCommand 全串过 bash -n 与 dash -n', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/foa_web_preview_cmd_test.sh');
      await tmp.writeAsString(command());
      for (final sh in ['bash', 'dash']) {
        final r = await Process.run(sh, ['-n', tmp.path]);
        expect(r.exitCode, 0,
            reason: '$sh -n 拒绝了启动命令：${r.stderr}');
      }
      await tmp.delete();
    });

    test('signalCommand 全串过 bash -n 与 dash -n', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/foa_web_preview_sig_test.sh');
      await tmp
          .writeAsString(WebPreviewService.signalCommand(pid, '-USR1'));
      for (final sh in ['bash', 'dash']) {
        final r = await Process.run(sh, ['-n', tmp.path]);
        expect(r.exitCode, 0, reason: '$sh -n 拒绝了信号命令：${r.stderr}');
      }
      await tmp.delete();
    });
  });

  group('WebPreviewService.signalCommand · 信号语义', () {
    test('USR1=热重载 / USR2=热重启，进程存活判定在 kill 之前', () {
      final rl = WebPreviewService.signalCommand(pid, '-USR1');
      final rs = WebPreviewService.signalCommand(pid, '-USR2');
      expect(rl.contains('kill -USR1'), isTrue);
      expect(rs.contains('kill -USR2'), isTrue);
      // 先 kill -0 探活再发信号（会话已死时输出 GONE 而非报错）
      expect(rl.indexOf('kill -0'), lessThan(rl.indexOf('kill -USR1')));
      expect(rl.contains('echo GONE'), isTrue);
      expect(rl.contains('echo RELOADED'), isTrue);
    });
  });

  group('WebPreviewService.staleCleanupCommand · 孤儿清理', () {
    test('含探活、两级信号与 pid 文件移除', () {
      final c = WebPreviewService.staleCleanupCommand(pid);
      expect(c.contains('[ -f $pid ]'), isTrue);
      expect(c.contains(r'n=$(cat '), isTrue);
      expect(c.contains('kill -0'), isTrue);
      expect(c.contains('kill \$n'), isTrue);
      expect(c.contains('kill -9 \$n'), isTrue);
      expect(c.contains('rm -f $pid'), isTrue);
    });
  });

  group('WebPreviewService.isReadyLine · 多信号 ready 判定', () {
    test('五个信号词命中（大小写不敏感）', () {
      expect(WebPreviewService.isReadyLine(
          'Running on http://127.0.0.1:8090'), isTrue);
      expect(WebPreviewService.isReadyLine(
          'lib/main.dart is being served at http://...'), isTrue);
      expect(WebPreviewService.isReadyLine(
          'A Dart VM Service on Web Server is available at: ...'), isTrue);
      expect(WebPreviewService.isReadyLine(
          'Debug service listening on ws://127.0.0.1:xxxxx'), isTrue);
      expect(WebPreviewService.isReadyLine(
          'Flutter run key commands.'), isTrue);
    });

    test('编译期普通行不命中（不能把 starting 误判成 running）', () {
      expect(WebPreviewService.isReadyLine(
          'Launching lib/main.dart on Web Server in debug mode...'),
          isFalse);
      expect(WebPreviewService.isReadyLine(
          'Waiting for connection from debug service on Web Server...'),
          isFalse);
      expect(WebPreviewService.isReadyLine('Compiling lib/main.dart...'),
          isFalse);
      expect(WebPreviewService.isReadyLine(''), isFalse);
    });
  });

  group('WebPreviewService.mutexError · 与构建互斥', () {
    test('构建中 → 拒绝并给出原因', () {
      final e = WebPreviewService.mutexError(
          building: true, previewBusy: false, bare: false);
      expect(e, isNotNull);
      expect(e!.contains('构建'), isTrue);
    });

    test('预览已在跑 → 拒绝', () {
      final e = WebPreviewService.mutexError(
          building: false, previewBusy: true, bare: false);
      expect(e, isNotNull);
      expect(e!.contains('已在运行'), isTrue);
    });

    test('termux 后端 → 第一版不开放', () {
      final e = WebPreviewService.mutexError(
          building: false, previewBusy: false, bare: true);
      expect(e, isNotNull);
      expect(e!.contains('容器'), isTrue);
    });

    test('双空闲 → 允许', () {
      expect(
        WebPreviewService.mutexError(
            building: false, previewBusy: false, bare: false),
        isNull,
      );
    });
  });

  group('WebPreviewService · 常量契约', () {
    test('端口与 URL 恒定（URL 不依赖日志解析，浏览器直达）', () {
      expect(WebPreviewService.port, 8090);
      expect(WebPreviewService.url, 'http://127.0.0.1:8090');
      expect(WebPreviewService.pidFile, pid);
    });

    test('状态机四态齐全', () {
      expect(WebPreviewStatus.values.length, 4);
      expect(WebPreviewStatus.values,
          containsAll(<WebPreviewStatus>[
            WebPreviewStatus.idle,
            WebPreviewStatus.starting,
            WebPreviewStatus.running,
            WebPreviewStatus.error,
          ]));
    });
  });

  // ==================================================================
  // Bug 454（alpha.60）：真机「假编译中」——ready 判定三段式与进度真实化
  //
  // 症状：日志已到 `Launching lib/main.dart on Web Server in debug mode...`，
  // UI 却永远停在「编译中…」（真机实测 10 分钟+）。
  // 真因：DDC 编译期不输出任何 readyMarker，且原实现**无任何超时兜底**，
  // WebView 又只在 running 时构造 → 永不加载。
  // ==================================================================

  group('Bug 454 · readyDecision 三段裁决', () {
    test('marker 命中 → ready（最快路径，行为与旧版一致）', () {
      expect(
        WebPreviewService.readyDecision(
            markerHit: true, portOpen: false, elapsedSec: 1),
        WebReadyDecision.ready,
      );
      expect(
        WebPreviewService.readyDecision(
            markerHit: true, portOpen: true, elapsedSec: 999),
        WebReadyDecision.ready,
      );
    });

    test('端口通 + 宽限到期 → degrade（兜底放行，绝不永久卡死）', () {
      expect(
        WebPreviewService.readyDecision(
            markerHit: false, portOpen: true, elapsedSec: 420),
        WebReadyDecision.degrade,
      );
      expect(
        WebPreviewService.readyDecision(
            markerHit: false, portOpen: true, elapsedSec: 1200),
        WebReadyDecision.degrade,
      );
    });

    test('端口通但未到宽限 → 继续等（不能过早放行）', () {
      expect(
        WebPreviewService.readyDecision(
            markerHit: false, portOpen: true, elapsedSec: 60),
        WebReadyDecision.waiting,
      );
      expect(
        WebPreviewService.readyDecision(
            markerHit: false, portOpen: true, elapsedSec: 419),
        WebReadyDecision.waiting,
      );
    });

    test('端口不通 → 永不 degrade（服务器没起来就没有页面可给）', () {
      expect(
        WebPreviewService.readyDecision(
            markerHit: false, portOpen: false, elapsedSec: 9999),
        WebReadyDecision.waiting,
      );
    });

    test('常量契约：宽限 7 分钟、探测节流 3s、心跳 15s', () {
      expect(WebPreviewService.degradeAfterSec_, 420);
      expect(WebPreviewService.probeIntervalSec, 3);
      expect(WebPreviewService.heartbeatIntervalSec, 15);
    });
  });

  group('Bug 454 · stageLabel 进度文案', () {
    test('未监听 → 说明还在准备（pub/转发层）', () {
      final s = WebPreviewService.stageLabel(portOpen: false, elapsedSec: 5);
      expect(s.contains('准备'), isTrue);
      // 必须提到准备工作，让用户知道不是卡死
      expect(s.contains('依赖') || s.contains('转发'), isTrue);
    });

    test('已监听 → 说明正在编译且「无输出属正常」', () {
      final s = WebPreviewService.stageLabel(portOpen: true, elapsedSec: 90);
      expect(s.contains('编译'), isTrue);
      // 这是本 Bug 的关键安抚点：编译期没有日志是正常的
      expect(s.contains('正常'), isTrue);
    });
  });

  group('Bug 454 · heartbeatLine 心跳', () {
    test('格式含已等待时长与安抚语', () {
      final h = WebPreviewService.heartbeatLine(95);
      expect(h.contains('01:35'), isTrue);
      expect(h.contains('正常'), isTrue);
    });

    test('不足 1 分钟时用「启动中」措辞', () {
      final h = WebPreviewService.heartbeatLine(20);
      expect(h.contains('00:20'), isTrue);
      expect(h.contains('启动中'), isTrue);
    });
  });

  group('Bug 454 · startCommand 加 --no-pub（本版唯一确定提速项）', () {
    test('命令含 --no-pub（省掉 flutter run 内部的第二次隐式 pub get）', () {
      expect(command().contains('--no-pub'), isTrue);
    });

    test('回归防护：仍是 web-server + 固定端口 + pid 记录 + 转发层断言', () {
      final c = command();
      expect(c.contains('exec flutter run -d web-server'), isTrue);
      expect(c.contains('--web-port=8090'), isTrue);
      expect(c.contains('--web-hostname=127.0.0.1'), isTrue);
      expect(c.contains('echo \$\$ > $pid'), isTrue);
      expect(c.contains('REASSERT'), isTrue);
    });
  });
}
