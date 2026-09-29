import 'dart:async';

import 'package:flutter/foundation.dart';

import '../editor/fs_bridge.dart';

/// 派活后的磁盘变更监听（alpha.83 引入，alpha.84 修正基线）。
///
/// ## 为什么是"轮询"而不是"文件监听"
/// 远程 AI 经 MCP `write_file` 改文件**不会通知 App**（MCP 是 client 主导，
/// server 无推送通道——这是 alpha.81 派活设计的既定前提）。真文件监听
/// 要 Kotlin 侧 FileObserver + 新增一条 MethodChannel，成本高；轮询每
/// 2.5s 走既有 FsBridge 读一次**单个文件**，开销可忽略，且行为完全可测。
///
/// ## 触发语义（刻意保守）
/// 只在「磁盘内容 ≠ **派活那一刻磁盘上的内容**」时报告**一次**然后自停
/// ——外部 AI 可能连改多轮，第一轮就该让用户看到；之后他想再看，
/// 编辑器「更多 → 从磁盘重新载入」随时可用，不该被弹窗轰炸。
/// 自己保存文件不算外部变更（调用方在保存成功后 [bumpBaseline]）。
///
/// ## 为什么基线必须是**磁盘**内容（alpha.84 修正）
/// 派活前的初版是拿「派活时**编辑器**里的内容」当基线，理由是"用户自己
/// 未保存的改动不算外部变更"。听起来对，实际会**彻底废掉监听**：
/// 用户有未保存改动时 `编辑器内容 ≠ 磁盘内容` → **第一次轮询就判定"磁盘
/// 变了"** → 弹一个假报警 → [_reported] 置位 + [stop] → 之后外部 AI
/// 真改了也永远不会再报。症状正是"还是要手动从磁盘重新载入"。
///
/// 正确语义是**只看磁盘自己变没变**：基线 = 派活瞬间读到的磁盘内容，
/// 之后磁盘一变就是外部改的。编辑器脏不脏与"磁盘变没变"完全无关。
class AiFileWatcher {
  AiFileWatcher(
      {FsBridge? bridge, this.interval = const Duration(milliseconds: 2500)})
      : _bridge = bridge ?? FsBridge();

  final FsBridge _bridge;

  /// 轮询间隔。2.5s：外部 AI 领活到改完通常是分钟级，再快没有意义，
  /// 再慢会让用户觉得"没反应"。
  final Duration interval;

  /// 检测到外部变更时回调（参数 = 磁盘上的新内容）。只触发一次。
  void Function(String disk)? onChanged;

  Timer? _timer;
  String _path = '';
  String _baseline = '';

  /// 磁盘内容是否已知。读失败时置 false —— 此时**不能把空串当基线**，
  /// 否则下一轮读到真实内容会被当成"外部变更"误报（见 [_poll]）。
  bool _baselineKnown = false;
  bool _reported = false;
  bool _starting = false;

  /// 是否在监听中。
  bool get active => _timer != null;

  /// 开始监听。[path] 是容器内路径。
  ///
  /// 基线由本类**自己去读一次磁盘**得到（[baseline] 仅供测试注入，正常
  /// 别传）——调用方给的多半是"编辑器里的内容"，那会引入假报警，见类注释。
  Future<void> start({required String path, String? baseline}) async {
    if (_starting) return; // 连点两次按钮时只认第一次，避免两个 start 赛跑
    _starting = true;
    try {
      stop();
      _path = path;
      _reported = false;
      if (baseline != null) {
        _baseline = baseline;
        _baselineKnown = true;
      } else {
        final r = await _bridge.read(path);
        if (!r.ok) {
          // 读不到就先不监听：**没有可信基线**时启动，第一轮必然误报。
          // 宁可完全不报（用户仍有手动重载），也不要弹假报警把真改动吃掉。
          _baseline = '';
          _baselineKnown = false;
          return;
        }
        _baseline = r.content;
        _baselineKnown = true;
      }
      _timer = Timer.periodic(interval, (_) => _poll());
    } finally {
      _starting = false;
    }
  }

  /// 停止监听（页面退出 / 换文件 / 用户已处理）。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 自己保存了文件：把基线推进到新内容，避免下一轮轮询把"自己写的"
  /// 误报成"远程 AI 改的"。
  void bumpBaseline(String content) {
    _baseline = content;
    _baselineKnown = true;
  }

  Future<void> _poll() async {
    if (_reported || _timer == null || !_baselineKnown) return;
    final r = await _bridge.read(_path);
    if (_reported || _timer == null) return; // 读盘期间可能已被 stop
    if (!r.ok) return; // 单次读失败（文件被移到 0 字节的中间态）不算变更
    if (r.content == _baseline) return;
    // 基线对齐到刚读到的内容再上报：万一回调没处理，后面也不会连环弹。
    _baseline = r.content;
    _reported = true;
    stop();
    onChanged?.call(r.content);
  }

  /// 测试辅助：不等 [interval] 立即轮一次。
  @visibleForTesting
  Future<void> pollNow() => _poll();
}
