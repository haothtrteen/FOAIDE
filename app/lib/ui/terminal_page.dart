import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../env/env_installer.dart';
import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../toolchain/termux_backend.dart';

/// 可交互终端（Bug 430）。
///
/// 定位
/// ----
/// 这是**真正的 shell**，不是预设命令跑批。底层走 PTY：
///
///     Dart ──MethodChannel──▶ Java ProcessBuilder ──pipe──▶ foa_pty
///                                                            │ pty
///                                                            ▼
///                                                        proot / 宿主 sh
///
/// 于是 `vim`、`top`、`apt` 的进度条、Ctrl+C 中断、方向键历史、
/// tab 补全全部可用。此前「终端」页只能选预设命令点运行，用户明确
/// 反馈「没有可交互执行命令的界面」——诊断为「不是终端」是对的。
///
/// 渲染
/// ----
/// 用 `xterm` 做完整 VT100 仿真：全屏程序（vim/top）会发送大量光标
/// 定位与清屏序列，裸 Text 渲染必然糊成一团。自研解释器在覆盖度上
/// 最容易翻车，故直接采用成熟实现。
///
/// 为什么必须按字节/原样透传
/// ------------------------
/// Ctrl+C 是 0x03、Esc 序列以 0x1b 开头，这些都不是「可打印字符」。
/// 走 TextField 那套「字符串输入」模型会被 IME/软键盘吞掉，因此终端
/// 的输入由 TerminalView 直接给出字符串（含控制字节）再原样写进 PTY。
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final Terminal _terminal = Terminal(maxLines: 5000);
  final ProotBridge _bridge = ProotBridge();
  final TerminalController _controller = TerminalController();
  final FocusNode _focus = FocusNode();

  int _sessionId = -1;
  String _backend = '';
  bool _starting = false;
  String? _error;
  Timer? _poll;
  int _offset = 0;
  bool _useBare = false;

  @override
  void initState() {
    super.initState();
    // 输入：TerminalView 把按键解析成字符串（含控制字节）交给我们
    _terminal.onOutput = (data) {
      if (_sessionId < 0) return;
      unawaited(_bridge.ptyWrite(_sessionId, data));
    };
    // 尺寸：全屏程序靠它重排（发 TIOCSWINSZ 给子进程）
    _terminal.onResize = (width, height, pw, ph) {
      if (_sessionId < 0) return;
      unawaited(_bridge.ptyResize(
        _sessionId,
        cols: width,
        rows: height,
      ));
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_sessionId >= 0) unawaited(_bridge.ptyStop(_sessionId));
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 选后端：跟随用户已保存的后端偏好（与构建链一致，便于复现同类问题）。
  /// 未显式选择时——rootfs 已装走 proot，否则只能走 Termux 裸原生。
  Future<bool> _pickBackend(EnvInfo env) async {
    final saved = await BackendPrefs.load(env);
    if (saved == BuildBackend.termux) return true;
    if (saved == BuildBackend.proot) return false;
    return !env.rootfsInstalled;
  }

  Future<void> _boot() async {
    if (_starting || _sessionId >= 0) return;
    setState(() {
      _starting = true;
      _error = null;
    });

    final envState = context.read<EnvState>();
    final env = envState.info;
    if (env == null) {
      setState(() {
        _starting = false;
        _error = '环境信息未就绪，请稍后重试。';
      });
      return;
    }

    final bare = await _pickBackend(env);
    _useBare = bare;

    final r = await _bridge.ptyStart(bare: bare);
    if (!mounted) return;

    if (!r.ok) {
      setState(() {
        _starting = false;
        _error = r.error ?? '启动终端失败。';
      });
      return;
    }

    setState(() {
      _sessionId = r.id;
      _backend = r.backend;
      _starting = false;
      _offset = 0;
    });
    _writeLocal(
      '\x1b[38;5;244mFOA 终端 · 后端 ${r.backend}'
      '${bare ? '（宿主 /system/bin/sh）' : '（proot 容器）'}\x1b[0m\r\n',
    );
    _startPolling();
    // 让终端立刻可输入：用户点进来就是要敲命令
    _focus.requestFocus();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 120), (_) async {
      if (_sessionId < 0) return;
      final PtyPoll p;
      try {
        p = await _bridge.ptyPoll(_sessionId, _offset);
      } catch (_) {
        return;
      }
      if (!mounted || !p.ok) return;
      if (p.chunk.isNotEmpty) {
        // 原样喂给终端仿真器：它负责解释 ANSI 转义、光标移动、颜色
        _terminal.write(p.chunk);
        _offset = p.len;
      }
      if (!p.running && p.exitCode != null) {
        _poll?.cancel();
        _writeLocal(
          '\r\n\x1b[38;5;244m[会话结束 · exit ${p.exitCode}]\x1b[0m\r\n',
        );
        setState(() => _sessionId = -1);
      }
    });
  }

  /// 本地提示：直接写进终端缓冲（不经 PTY），与真实输出区分用灰色。
  void _writeLocal(String s) => _terminal.write(s);

  /// 重启会话（exit 后或出错时用）。
  Future<void> _restart() async {
    _poll?.cancel();
    if (_sessionId >= 0) {
      await _bridge.ptyStop(_sessionId);
    }
    _offset = 0;
    setState(() {
      _sessionId = -1;
      _error = null;
      _terminal.write('\x1b[2J\x1b[H'); // 清屏归位
    });
    await _boot();
  }

  Future<void> _stop() async {
    if (_sessionId < 0) return;
    await _bridge.ptyStop(_sessionId);
    _poll?.cancel();
    if (mounted) setState(() => _sessionId = -1);
  }

  /// 发送 Ctrl+字母（软键盘没有 Ctrl 键时的兜底）。
  Future<void> _sendCtrl(String letter) async {
    if (_sessionId < 0) return;
    final code = letter.toUpperCase().codeUnitAt(0) - 64; // Ctrl+A = 0x01
    await _bridge.ptyWrite(_sessionId, String.fromCharCode(code));
  }

  /// 发送常见转义序列（方向键 / Tab / Esc）。
  Future<void> _sendRaw(String seq) async {
    if (_sessionId < 0) return;
    await _bridge.ptyWrite(_sessionId, seq);
  }

  @override
  Widget build(BuildContext context) {
    final running = _sessionId >= 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('终端'),
        actions: [
          if (_backend.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    _backend == 'termux' ? '宿主' : 'proot',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: '复制全部输出',
            icon: const Icon(Icons.copy),
            onPressed: () {
              final buf = _terminal.buffer;
              final sb = StringBuffer();
              for (var i = 0; i < buf.height; i++) {
                sb.writeln(buf.lines[i].toString());
              }
              Clipboard.setData(ClipboardData(text: sb.toString()));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('已复制'),
                duration: Duration(seconds: 1),
              ));
            },
          ),
          IconButton(
            tooltip: '重启会话',
            icon: const Icon(Icons.refresh),
            onPressed: _starting ? null : _restart,
          ),
          IconButton(
            tooltip: '结束会话',
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: running ? _stop : null,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _terminalArea(running)),
          _keyBar(running),
        ],
      ),
    );
  }

  Widget _terminalArea(bool running) {
    if (_starting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在启动终端…'),
          ],
        ),
      );
    }
    if (_error != null) {
      return _errorView(_error!);
    }
    return Container(
      color: const Color(0xFF0B0E11),
      padding: const EdgeInsets.all(6),
      child: TerminalView(
        _terminal,
        controller: _controller,
        focusNode: _focus,
        autofocus: true,
        // 全屏程序（vim/top）自己管光标，这里不强制显示
        alwaysShowCursor: true,
        deleteDetection: true,
        textStyle: const TerminalStyle(fontSize: 13, fontFamily: 'monospace'),
        theme: _foaTheme,
      ),
    );
  }

  Widget _errorView(String msg) {
    final hint = _useBare
        ? '宿主 shell 启动失败。若尚未建立 Termux 后端，'
            '请到「工具链」页应用裸原生后端。'
        : 'proot 容器未就绪。请回主页「初始化环境」安装 rootfs，'
            '或在「工具链」页切换到 Termux 裸原生后端。';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.terminal, size: 48, color: Colors.white24),
            const SizedBox(height: 16),
            Text(msg, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                setState(() => _error = null);
                _boot();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 软键盘补齐：移动端没有物理 Ctrl/Esc/Tab，全靠这一排。
  /// 物理键盘（若接了）由 TerminalView 原生处理，不冲突。
  Widget _keyBar(bool running) {
    final on = running && !_starting;
    Widget btn(String label, VoidCallback onTap, {String? tip, double w = 44}) {
      return SizedBox(
        width: w,
        height: 34,
        child: Tooltip(
          message: tip ?? label,
          child: OutlinedButton(
            onPressed: on ? onTap : null,
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              side: const BorderSide(color: Colors.white24),
            ),
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      color: const Color(0xFF12161A),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            btn('Ctrl+C', () => _sendCtrl('C'), tip: '中断当前命令 (SIGINT)'),
            const SizedBox(width: 6),
            btn('Ctrl+D', () => _sendCtrl('D'), tip: 'EOF / 退出'),
            const SizedBox(width: 6),
            btn('Ctrl+Z', () => _sendCtrl('Z'), tip: '挂起 (SIGTSTP)'),
            const SizedBox(width: 6),
            btn('Esc', () => _sendRaw('\x1b'), tip: 'Esc（退出 vim 插入模式）'),
            const SizedBox(width: 6),
            btn('Tab', () => _sendRaw('\t'), tip: 'Tab 补全'),
            const SizedBox(width: 6),
            btn('↑', () => _sendRaw('\x1b[A'), tip: '上一条历史', w: 38),
            const SizedBox(width: 6),
            btn('↓', () => _sendRaw('\x1b[B'), tip: '下一条历史', w: 38),
            const SizedBox(width: 6),
            btn('←', () => _sendRaw('\x1b[D'), tip: '左移', w: 38),
            const SizedBox(width: 6),
            btn('→', () => _sendRaw('\x1b[C'), tip: '右移', w: 38),
            const SizedBox(width: 6),
            btn('/',
                () => _sendRaw('/'), tip: '斜杠（软键盘路径输入不便）', w: 38),
            const SizedBox(width: 6),
            btn('-', () => _sendRaw('-'), tip: '连字符', w: 38),
            const SizedBox(width: 6),
            btn('~', () => _sendRaw('~'), tip: '波浪号', w: 38),
            const SizedBox(width: 6),
            btn('clear', () => _sendRaw('clear\n'), tip: '清屏', w: 54),
          ],
        ),
      ),
    );
  }

  /// 终端配色（与 App 暗色主题一致）。
  static const TerminalTheme _foaTheme = TerminalTheme(
    cursor: Color(0xFFB6F09C),
    selection: Color(0x40B6F09C),
    foreground: Color(0xFFE6E6E6),
    background: Color(0xFF0B0E11),
    black: Color(0xFF2A2F36),
    red: Color(0xFFFF6B68),
    green: Color(0xFFB6F09C),
    yellow: Color(0xFFF5D76E),
    blue: Color(0xFF6FB3FF),
    magenta: Color(0xFFD19BFF),
    cyan: Color(0xFF6FE3E1),
    white: Color(0xFFD8D8D8),
    brightBlack: Color(0xFF4A525C),
    brightRed: Color(0xFFFF8A87),
    brightGreen: Color(0xFFD3FFC2),
    brightYellow: Color(0xFFFFE9A3),
    brightBlue: Color(0xFF9CCBFF),
    brightMagenta: Color(0xFFE6C2FF),
    brightCyan: Color(0xFF9BF2F0),
    brightWhite: Color(0xFFFFFFFF),
    // 搜索高亮（本页未启用搜索，但字段必填，取与主题协调的色值）
    searchHitBackground: Color(0xFFFFFF2B),
    searchHitBackgroundCurrent: Color(0xFFB6F09C),
    searchHitForeground: Color(0xFF000000),
  );
}
