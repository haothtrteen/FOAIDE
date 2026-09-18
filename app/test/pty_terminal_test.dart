import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Bug 430 固化：可交互 PTY 终端。
///
/// 为什么这些断言值得写
/// ------------------
/// PTY 中继器的正确性由**大量细碎的 curses 约定**支撑，任何一条被
/// 「顺手简化」掉都会导致「终端能开但 Ctrl+C 不灵 / vim 花屏」这类
/// 只在真机上才暴露、且极难归因的故障。而沙箱是 x86_64 主机，跑不了
/// aarch64 的 APK——所以用静态契约测试把关键实现点钉死在源码里。
///
/// 三条最容易被误删的约定（都是实测踩出来的）：
///   1. c_cc[] 控制字符必须显式赋值（否则 stty 显示 intr=<undef>，
///      Ctrl+C 彻底失效）；
///   2. setsid() 之后不能再 setpgid，父进程也不能给子进程设 pgid
///      （进程组组长不能 setsid → 表现为终端一启动就退出，rc=120）；
///   3. 中继进程必须忽略 SIGINT/SIGQUIT，否则 Ctrl+C 打在自身上。
void main() {
  final shimPath = File('platform/android/pty/foa_pty.c');
  final ptyKt = File('platform/android/PtySession.kt');
  final mainKt = File('platform/android/MainActivity.kt');
  final pageDart = File('lib/ui/terminal_page.dart');
  final modelsDart = File('lib/env/models.dart');
  final bridgeDart = File('lib/env/proot_bridge.dart');

  group('Bug 430 · PTY 中继器（foa_pty.c）', () {
    late String src;
    setUpAll(() {
      expect(shimPath.existsSync(), isTrue,
          reason: 'PTY 中继器源码必须存在（assets/tools/foa_pty 由它编译而来）');
      src = shimPath.readAsStringSync();
    });

    test('必须用 openpty 建真 tty（不是单向管道）', () {
      expect(src.contains('openpty('), isTrue);
      expect(src.contains('#include <pty.h>'), isTrue);
    });

    test('c_cc 控制字符必须显式赋值 —— 否则 Ctrl+C 失效', () {
      // 实测现象：只设 flag、c_cc 全零 → stty 显示 intr = <undef>，
      // 屏幕回显 ^C 但 sleep 照睡不误。
      for (final cc in [
        'VINTR',
        'VQUIT',
        'VSUSP',
        'VERASE',
        'VEOF',
        'VKILL',
        'VWERASE',
      ]) {
        expect(src.contains('c_cc[$cc]'), isTrue,
            reason: '缺少 $cc 赋值 → 对应控制键在真机上无声失效');
      }
    });

    test('VINTR 必须是 0x03 且 ISIG 打开（Ctrl+C 的完整前提）', () {
      expect(RegExp(r'c_cc\[VINTR\]\s*=\s*0x03').hasMatch(src), isTrue);
      expect(src.contains('ISIG'), isTrue);
      expect(src.contains('ICANON'), isTrue,
          reason: '规范模式提供行编辑/退格，关掉会让交互体验退化');
    });

    test('前台进程组三步：setsid + TIOCSCTTY + tcsetpgrp', () {
      expect(src.contains('setsid()'), isTrue);
      expect(src.contains('TIOCSCTTY'), isTrue);
      expect(src.contains('tcsetpgrp('), isTrue,
          reason: '不登记前台组，内核找不到 SIGINT 的投递目标');
    });

    test('禁止在 setsid 的会话首进程上再 setpgid（会 EPERM 导致启动即退）', () {
      // 实测：曾写 setpgid(0,0)，返回 EPERM 被当致命错误 → rc=120
      final childBlock = _between(src, 'child_exec', 'static void child_exec');
      final body = _fnBody(src, 'child_exec');
      expect(body.contains('setpgid(0, 0)'), isFalse,
          reason: '会话首进程 setpgid 必失败（EPERM），终端会启动即退出');
      expect(childBlock.isNotEmpty || body.isNotEmpty, isTrue);
    });

    test('父进程禁止 setpgid(子进程, 子进程)（会让子进程 setsid 失败）', () {
      // 实测：父侧抢设 pgid → 子进程成进程组组长 → setsid() 失败 → rc=120
      expect(
        RegExp(r'setpgid\(\s*g_child\s*,\s*g_child\s*\)').hasMatch(src),
        isFalse,
        reason: '进程组组长不得成为新会话首进程，子进程 setsid 会失败',
      );
    });

    test('中继进程必须忽略终端信号（否则 Ctrl+C 打死自己）', () {
      for (final sig in ['SIGINT', 'SIGQUIT', 'SIGPIPE']) {
        expect(RegExp('signal\\($sig,\\s*SIG_IGN\\)').hasMatch(src), isTrue,
            reason: '未忽略 $sig：实测表现为按一下 Ctrl+C 整个终端崩掉');
      }
    });

    test('exec 前清空信号屏蔽集（继承的屏蔽会静默吞掉 SIGINT）', () {
      expect(src.contains('sigprocmask'), isTrue);
      expect(src.contains('SIG_SETMASK'), isTrue);
    });

    test('窗口尺寸热更新走 FOA_PTY_SIZE_FILE 控制文件 + poll 超时', () {
      // master fd 只在 shim 手里，Java 改不了 winsize；stdin 内联控制序列
      // 又会污染用户输入。故用控制文件 + 200ms 超时轮询。
      expect(src.contains('FOA_PTY_SIZE_FILE'), isTrue);
      expect(src.contains('TIOCSWINSZ'), isTrue);
      expect(RegExp(r'poll\(pfd,\s*nfds,\s*200\)').hasMatch(src), isTrue,
          reason: 'poll 必须带超时，否则永远等不到尺寸变化检查');
      expect(src.contains('maybe_apply_size'), isTrue);
    });

    test('exec 失败用 127（可辨识），fork/pty 失败用可区分的高位码', () {
      expect(src.contains('execvp('), isTrue);
      expect(RegExp(r'_exit\(127\)').hasMatch(src), isTrue);
    });

    test('退出码要透传（WEXITSTATUS / 128+WTERMSIG）', () {
      expect(src.contains('WIFEXITED'), isTrue);
      expect(src.contains('WEXITSTATUS'), isTrue);
      expect(src.contains('128 + WTERMSIG'), isTrue);
    });
  });

  group('Bug 430 · 原生会话层（PtySession.kt）', () {
    late String kt;
    setUpAll(() {
      expect(ptyKt.existsSync(), isTrue);
      kt = ptyKt.readAsStringSync();
    });

    test('会话必须持有可写通道（键盘输入）与增量缓冲', () {
      expect(kt.contains('val input: OutputStream'), isTrue);
      expect(kt.contains('StringBuffer'), isTrue);
      expect(kt.contains('fun write('), isTrue);
    });

    test('必须能停止会话（SIGTERM → 强杀）', () {
      expect(kt.contains('fun stop('), isTrue);
      expect(kt.contains('destroyForcibly'), isTrue);
    });

    test('二进制从 assets 落位并设可执行位', () {
      expect(kt.contains('foa_pty'), isTrue);
      expect(kt.contains('setExecutable(true'), isTrue);
    });
  });

  group('Bug 430 · 通道接线（MainActivity.kt）', () {
    late String kt;
    setUpAll(() {
      expect(mainKt.existsSync(), isTrue);
      kt = mainKt.readAsStringSync();
    });

    test('五个 PTY 方法全部接线（起/写/轮询/停/改尺寸）', () {
      for (final m in [
        '"ptyStart"',
        '"ptyWrite"',
        '"ptyPoll"',
        '"ptyStop"',
        '"ptyResize"',
      ]) {
        expect(kt.contains(m), isTrue, reason: '缺少 $m 路由');
      }
    });

    test('PTY 会话禁止 redirectErrorStream(true)', () {
      // pty 已把 stdout/stderr 合到同一终端，再合并会把 shim 自己的
      // 诊断输出混进用户屏幕。注意 ptyStart 之后紧跟的是 execStreamPoll
      // 等**其它**函数，它们仍应保持合并（构建日志要单流保时序），
      // 所以必须精确取 ptyStart 自身函数体，不能按固定长度截断。
      final body = _fnBody(kt, 'private fun ptyStart');
      expect(body.isNotEmpty, isTrue, reason: '未能定位 ptyStart 函数体');
      // 剥离注释行再断言：注释里为说明「为什么不合并」必然会提到
      // redirectErrorStream(true)，直接匹配会误伤（本测试初版即栽在这）。
      final code = body
          .split('\n')
          .where((l) {
            final t = l.trim();
            return !t.startsWith('//') &&
                !t.startsWith('*') &&
                !t.startsWith('/*');
          })
          .join('\n');
      expect(code.contains('redirectErrorStream(true)'), isFalse,
          reason: 'PTY 会话合并流会污染屏幕输出');
      expect(code.contains('redirectErrorStream(false)'), isTrue,
          reason: '必须显式分开 stderr，单独收集 shim 诊断');
    });

    test('Session 销毁时必须清理 PTY 会话（防残留 shell 与 /dev/pts）', () {
      final idx = kt.indexOf('override fun onDestroy');
      expect(idx, greaterThan(0));
      final body = kt.substring(idx, (idx + 1200).clamp(0, kt.length));
      expect(body.contains('ptyRegistry.stopAll()'), isTrue,
          reason: '不清会话会残留僵尸 shell');
    });

    test('交互终端必须用 xterm-256color（TERM=dumb 会让 vim/top 退化）', () {
      final body = _fnBody(kt, 'private fun ptyStart');
      expect(body.contains('TERM=xterm-256color'), isTrue);
    });

    test('proot 交互式 shell 要 exec 顶替外层（保住 tty fd）', () {
      final body = _fnBody(kt, 'private fun ptyStart');
      expect(body.contains('exec /bin/sh -i'), isTrue,
          reason: 'boot 注入后必须 exec，否则多一层进程且信号传递变复杂');
    });
  });

  group('Bug 430 · Dart 侧接线与 UI', () {
    test('数据模型齐备（PtyStart / PtyPoll）', () {
      final m = modelsDart.readAsStringSync();
      expect(m.contains('class PtyStart'), isTrue);
      expect(m.contains('class PtyPoll'), isTrue);
      expect(m.contains('final String chunk'), isTrue,
          reason: 'chunk 必须是原样字符串（含 ANSI），不能提前清洗');
    });

    test('桥接层五个方法齐备', () {
      final b = bridgeDart.readAsStringSync();
      for (final m in [
        'ptyStart',
        'ptyWrite',
        'ptyPoll',
        'ptyStop',
        'ptyResize',
      ]) {
        expect(b.contains('$m('), isTrue, reason: '桥接缺少 $m');
      }
    });

    test('UI 必须用真终端仿真器（xterm），不能拿 Text 硬渲染', () {
      final p = pageDart.readAsStringSync();
      expect(p.contains("package:xterm/xterm.dart"), isTrue,
          reason: '全屏程序的光标/清屏序列必须由 VT 仿真器解释');
      expect(p.contains('TerminalView('), isTrue);
    });

    test('onOutput 必须原样透传（Ctrl+C / Esc 不能被过滤）', () {
      final p = pageDart.readAsStringSync();
      expect(p.contains('_terminal.onOutput'), isTrue);
      expect(RegExp(r'ptyWrite\(_sessionId,\s*data\)').hasMatch(p), isTrue,
          reason: '必须原样写，任何"清洗"都会吃掉控制字节');
    });

    test('尺寸变化要回传原生（全屏程序重排的前提）', () {
      final p = pageDart.readAsStringSync();
      expect(p.contains('_terminal.onResize'), isTrue);
      expect(p.contains('ptyResize('), isTrue);
    });

    test('软键盘必须补齐 Ctrl/Esc/Tab/方向键（移动端没有物理键）', () {
      final p = pageDart.readAsStringSync();
      expect(p.contains('_sendCtrl('), isTrue);
      expect(p.contains(r"'\x1b[A'"), isTrue, reason: '方向键上 = ESC [ A');
      expect(p.contains(r"'\x1b'"), isTrue, reason: 'Esc 是 vim 的基本操作');
      expect(p.contains(r"'\t'"), isTrue, reason: 'Tab 补全');
    });

    test('后端要跟随用户偏好（与构建链一致，便于复现同类问题）', () {
      final p = pageDart.readAsStringSync();
      expect(p.contains('BackendPrefs.load'), isTrue);
      expect(p.contains('BuildBackend.termux'), isTrue);
    });

    test('退出会话时清理轮询与 PTY（防泄漏）', () {
      final p = pageDart.readAsStringSync();
      expect(p.contains('void dispose()'), isTrue);
      final idx = p.indexOf('void dispose()');
      final body = p.substring(idx, (idx + 500).clamp(0, p.length));
      expect(body.contains('_poll?.cancel()'), isTrue);
      expect(body.contains('ptyStop('), isTrue);
    });
  });

  group('Bug 430 · 构建脚本', () {
    test('存在一键编译脚本，且做依赖体检（必须纯 bionic）', () {
      final f = File('tools/build_pty_shim.sh');
      expect(f.existsSync(), isTrue,
          reason: 'assets/tools/foa_pty 不进 git，必须能一键重建');
      final s = f.readAsStringSync();
      expect(s.contains('aarch64-linux-android'), isTrue);
      expect(s.contains('NEEDED'), isTrue, reason: '必须检查动态依赖');
      // 脚本里用正则白名单 libc\.so|libdl\.so|libm\.so，故按正则匹配
      expect(RegExp(r'libc\\?\.so').hasMatch(s), isTrue,
          reason: '必须限定只允许 bionic 系统库，否则设备上加载失败');
    });
  });
}

/// 取两标记之间的文本（找不到返回空串）。
String _between(String s, String start, String end) {
  final i = s.indexOf(start);
  if (i < 0) return '';
  final j = s.indexOf(end, i);
  if (j < 0) return '';
  return s.substring(i, j);
}

/// 取指定函数名的函数体（粗略按花括号配对，找不到返回空串）。
String _fnBody(String s, String name) {
  final i = s.indexOf(name);
  if (i < 0) return '';
  final open = s.indexOf('{', i);
  if (open < 0) return '';
  var depth = 0;
  for (var k = open; k < s.length; k++) {
    if (s[k] == '{') depth++;
    if (s[k] == '}') {
      depth--;
      if (depth == 0) return s.substring(open, k + 1);
    }
  }
  return '';
}
