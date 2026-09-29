// foa-sh-mcp.sh（终端版 MCP 桥）契约测试。
//
// ## 这个脚本存在的理由
//
// App 的 MCP 服务跑在 **App 进程内**，只在点「远程协助 → 启动隧道」时
// 才被拉起。用户改用**终端手工起隧道**时，8977 上没人听 —— cloudflared
// 日志一切正常，公网访问却是 **502 Bad gateway**（隧道通、回源失败）。
//
// 这个脚本补上那个缺口。它同样是一份**没人会逐行读**的 shell，
// 所以按本项目的规矩（Bug 449 的 shell 语法门禁先例）用单测守住。
//
// ## 本文件守什么
//
//   ① 脚本语法在 dash / bash 下都通过；
//   ② 那几个**踩过的坑**不许回来（nc 的 EOF 行为、预挂监听、
//      JSON 转义还原、只接 /mcp、鉴权）；
//   ③ 文档与实现不许打架（说了"不并发"就要真的在文档里写着）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String src;

  setUpAll(() {
    src = File('tools/foa-sh-mcp.sh').readAsStringSync();
  });

  group('foa-sh-mcp · 语法门禁', () {
    test('dash 与 bash 下语法均通过', () {
      final dir = Directory.systemTemp.createTempSync('foaShMcp');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final f = File('${dir.path}/foa-sh-mcp.sh')..writeAsStringSync(src);
      for (final sh in ['dash', 'bash']) {
        final probe = Process.runSync('sh', ['-c', 'command -v $sh']);
        if (probe.exitCode != 0) continue;
        final r = Process.runSync(sh, ['-n', f.path]);
        expect(r.exitCode, 0, reason: '在 $sh 下语法错误：${r.stderr}');
      }
    });
  });

  group('foa-sh-mcp · 不得回退的四个坑', () {
    test('分流 --serve-one 必须在函数定义之后、启动横幅之前', () {
      // ⚠️ 这个坑我踩了两次，两次都是"位置"问题：
      //
      // 第一次：放在文件**最前面**（自以为"尽早分流"最好）→
      //   报 `run_single_connection: not found`。因为 shell 解析
      //   `if ... fi` 复合命令时整体读入，此时函数还没定义。
      // 第二次：放在文件**最底部**（紧跟函数定义，看着很自然）→
      //   socat 拉起的子进程先把启动横幅打印一遍、再走到"挑监听器"
      //   卡住不处理连接 → 客户端 0 字节超时。
      //
      // 唯一正确的位置：函数定义之后 ∩ 横幅之前。
      final fnIdx = src.indexOf('run_single_connection() {');
      final dispatchIdx = src.indexOf(r'if [ "${1:-}" = "--serve-one" ]');
      final bannerIdx = src.indexOf('log "FOA 终端版 MCP 服务"');
      expect(fnIdx, greaterThan(0), reason: '函数定义锚点');
      expect(dispatchIdx, greaterThan(fnIdx),
          reason: '分流必须在函数定义**之后**，否则 not found');
      expect(bannerIdx, greaterThan(dispatchIdx),
          reason: '分流必须在启动横幅**之前**，否则子进程刷屏并卡死');
    });

    test('run_command 的参数名必须是 command（与 App 版逐字一致）', () {
      // ⚠️ 曾经写成 "cmd"。客户端按 tools/list 声明发的是 "command"，
      // 于是永远取到空串 → run_command 静默执行空命令（返回空输出、
      // exit=0，看起来"成功"），黑名单也永远命中不了。
      // 同一个协议两个名字，是最难查的那类 bug。
      expect(src, contains(r'json_str_field "$body" "command"'),
          reason: '参数名必须与 mcp_server.dart 的 args[\'command\'] 一致');
      expect(src, isNot(contains(r'json_str_field "$body" "cmd"')),
          reason: '"cmd" 是错的，取不到值');
    });

    test('字段抽取必须区分"转义的引号"与"结束引号"', () {
      // ⚠️ 曾经用 grep -o '...\"[^\"]*\"'，`[^"]*` 会在转义引号 `\"` 处
      // 停下 —— content:"a\nb\tc\"d\\e" 只抽出 `a\nb\tc\`，后面的
      // `d\e` 整段丢失。因为"内容只是短了点"，极难往提取阶段截断上想。
      expect(src, contains('json_str_field()'),
          reason: '字段抽取函数必须存在');
      // 不能再退回"否定字符类"的老写法
      expect(src, isNot(contains(r'grep -o ""$2""')),
          reason: '不得退回 [^"]* 的截断写法');
      // 必须有"真结束引号"的判定
      expect(src, contains(r'if (ch == "\"") break'),
          reason: '必须逐字符扫描，区分转义引号与结束引号');
    });

    test('索引偏移：p + klen + 2（含两侧引号），不是 +1', () {
      // ⚠️ `pat` 是 "key"（含两侧引号，长 klen+2）。曾经写 p+klen+1，
      // 停在 key 的**收尾引号**上 → 判定不是冒号 → 一直 continue →
      // 所有字符串字段都返回空串。表征是启动日志 `→  (id=3)`。
      expect(src, contains('q = p + klen + 2'),
          reason: 'pat 含两侧引号，所以要 +2');
      expect(src, isNot(contains('q = p + klen + 1')),
          reason: '+1 会停在收尾引号上，取不到任何值');
    });

    test('参数必须经 json_unescape 还原，否则 \\n 会写成字面量', () {
      // 现象：客户端发 content:"a\nb"，JSON 里是 a\ n b 四个字符，
      // 直接落盘就变成字面量反斜杠+n，而不是真换行。
      expect(src, contains(r'FOA_ARG_CONTENT=$(json_unescape'),
          reason: 'content 必须还原转义（实测写出过错文件）');
      expect(src, contains(r'FOA_ARG_CMD=$(json_unescape'),
          reason: 'command 同理');
      expect(src, contains('json_unescape()'),
          reason: '还原函数本身必须存在');
    });

    test('转义还原顺序：先 \\\\ 最后 \\" （否则 \\\\n 会被误还原成换行）', () {
      final fn = src.substring(
        src.indexOf('json_unescape()'),
        src.indexOf('json_unescape()') + 600,
      );
      // `\\\\` 的替换必须排在 `\\n` 之后
      final iBackslash = fn.indexOf(r"'s/\\\\/\\/g'");
      final iNewline = fn.indexOf(r"'s/\\n/");
      expect(iBackslash, greaterThan(0), reason: '反斜杠还原的锚点');
      expect(iNewline, greaterThan(0), reason: '换行还原的锚点');
      expect(iBackslash, greaterThan(iNewline),
          reason: '先还原 \\n 再还原 \\\\ —— 反过来会把 \\\\n（语义是'
              '反斜杠+n）错误地变成真换行');
    });
  });

  group('foa-sh-mcp · 协议契约（与 App 版对齐）', () {
    test('端口默认 8977（与 McpServer.port 一致）', () {
      expect(src, contains(r'FOA_MCP_PORT:-8977'));
    });

    test('只接 POST /mcp，别的一律 404/405', () {
      expect(src, contains(r'/mcp|/mcp\?*'));
      expect(src, contains('404 Not Found'));
      expect(src, contains('405 Method Not Allowed'));
    });

    test('鉴权支持 Bearer 与 ?token= 两种（客户端只填一个 URL 时要用后者）', () {
      expect(src, contains('Authorization'));
      expect(src, contains(r'[Bb]earer'));
      expect(src, contains('token='));
      expect(src, contains('401 Unauthorized'));
    });

    test('通知类请求回 202 无体（不是 200 带空 JSON）', () {
      // MCP 约定：notifications/* 不需要响应。回 200 + 空 body 有些
      // 客户端会当成协议错误。
      expect(src, contains('notifications/*'));
      expect(src, contains('202 Accepted'));
    });

    test('工具清单与 App 版同名，且不含 build_apk', () {
      for (final t in [
        'foa_info',
        'foa_diag',
        'run_command',
        'list_projects',
        'read_file',
        'write_file',
        'list_dir',
      ]) {
        expect(src, contains('"name":"$t"'), reason: '缺工具 $t');
      }
      // 刻意不暴露 build_apk：构建要走互斥与进度 UI，
      // 交给远程裸调会打架（与 App 版一致的设计决定）。
      expect(src, isNot(contains('"name":"build_apk"')));
    });

    test('工具失败必须带 isError（否则客户端当成功）', () {
      expect(src, contains('"isError":true'));
    });

    test('保留最小命令黑名单（应急通道也不能裸奔）', () {
      expect(src, contains('REJECTED'));
      expect(src, contains('rm -rf /'));
    });
  });

  group('foa-sh-mcp · 文档与实现不许打架', () {
    test('必须说清它是应急通道、不是 App 版替代品', () {
      expect(src, contains('排障/应急通道'));
      // App 版有而它没有的，要列出来
      expect(src, contains('单飞锁'));
    });

    test('必须提醒 rootfs 是 minbase（依赖现实）', () {
      expect(src, contains('minbase'));
    });

    test('必须写明 socat 优先、nc 兜底（依赖史不许忘）', () {
      // 这段依赖史踩过两次：先是因为 nc 不存在直接起不来；
      // 后来改成纯 sh 自实现监听又太脆。现在的结论是
      // **优先 socat（天然并发 + 无 EOF 麻烦），没有也能退回 nc**。
      expect(src, contains('socat'));
      expect(src, contains('TCP-LISTEN'));
      expect(src, contains('netcat-openbsd'),
          reason: '必须给出 nc 的安装提示（兜底路径要用）');
    });

    test('两者都没有时必须明确报错并给建议，不许静默失败', () {
      // 静默失败正是这个脚本存在的原因（让用户对着 502 猜半天）
      expect(src, contains('既没有 socat 也没有 nc'));
      expect(src, contains('远程协助'),
          reason: '要给"改用 App 内一键启动"的退路');
    });
  });
}
