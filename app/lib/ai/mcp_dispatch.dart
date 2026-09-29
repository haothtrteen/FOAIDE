import '../editor/fs_bridge.dart';

/// 派活给远程 AI 的落盘格式（alpha.81）。
///
/// ## 为什么是"写文件"而不是"推消息"
/// MCP 是 client 主导的：连进来的外部 AI 客户端想调什么就调什么，
/// server 这边没有可靠的"主动推送任务"通道（sampling 支持度参差不齐）。
/// 但客户端**一定会 read_file**——那就把作业写成项目里的一个文件，
/// 让它在 inbox 里自己领。这是当前协议下最笨也最稳的办法。
///
/// 落盘位置（容器内路径，与编辑器读的是同一棵目录树）：
///   `<项目根>/.foa/ai-jobs/<时间戳>-<类型>.md`   单条作业
///   `<项目根>/.foa/ai-inbox.md`                  作业索引（AI 先看这个）
///
/// ⚠️ 派活是**异步无回执**的：写完就完，没人来领就是没人来领。UI 不许
/// 假装"处理中"，必须如实告诉用户"已投递，等远端 AI 领取"。

/// 作业目录名（放在项目根的 .foa 下，跟项目其它元数据一处）。
const String kAiJobsDir = '.foa/ai-jobs';
const String kAiInboxFile = '.foa/ai-inbox.md';

/// 单个作业的 Markdown（纯函数，便于单测）。
///
/// ## 「不要做什么」一节为什么必须存在
/// 真机实测：外部 AI 领到一条「补全光标处代码」后，没先看光标位置，而是
/// 通读全文 → 判断"文件看起来已完整" → 主动去查 `cardTheme` 的 API 定义、
/// 准备验证能否编译 —— 把一条补全作业扩散成了项目体检。
///
/// 根因是**作业里没有"边界"**：只说"要做什么"，没说"不要做什么"、
/// 没说完事了要回执。所以这里把三件事写死：
/// ① **只改这几行**，别扩建范围；② **不要主动跑构建/测试/分析**；
/// ③ **不明确就问**，不要用"顺便检查"补全意图。
String buildJobMarkdown({
  required String file,
  required int cursor,
  required String kindName,
  required String instruction,
  required String contextSnippet,
  required String stamp,
}) {
  final b = StringBuffer();
  b.writeln('# AI 作业 · $kindName');
  b.writeln();
  b.writeln('- 投递时间：$stamp');
  b.writeln('- 文件：`$file`');
  b.writeln('- 光标偏移：$cursor');
  b.writeln();
  b.writeln('## 要求');
  b.writeln();
  b.writeln(instruction.trim().isEmpty ? '（无附加要求）' : instruction.trim());
  b.writeln();
  b.writeln('## 光标附近上下文');
  b.writeln();
  b.writeln('```');
  b.writeln(contextSnippet);
  b.writeln('```');
  b.writeln();
  b.writeln('## 怎么做');
  b.writeln();
  b.writeln('- 直接用 `write_file` 改写 `$file`；编辑器与 MCP 看到的是同一个文件。');
  b.writeln('- 只做「要求」里写的事。文件看起来别处也该改、或看起来已经完整，'
      '**都不是**扩大范围的理由。');
  b.writeln('- 不要主动运行构建 / 测试 / `flutter analyze`。');
  b.writeln('- 不要为了"确认现状"通读整个文件再顺带分析；'
      '需要更多上下文时只读该段前后相邻部分。');
  b.writeln('- 做不了或看不懂要求 → 说明卡在哪，**保持文件原样**，'
      '不要用猜的改动顶上。');
  b.writeln('- 完成后在本文件顶部追加一行 `status: done`。');
  return b.toString();
}

/// inbox 的一行索引（纯函数）。
String buildInboxLine({
  required String jobRelPath,
  required String kindName,
  required String file,
  required String stamp,
}) =>
    '- [$stamp] **$kindName** · `$file` → 详见 `$jobRelPath`';

class McpDispatchResult {
  final bool ok;
  final String? error;
  final String jobPath;
  final String inboxPath;

  const McpDispatchResult({
    required this.ok,
    this.error,
    required this.jobPath,
    required this.inboxPath,
  });
}

/// 投递一条作业：写单条 md + 往 inbox 追加一行索引。
///
/// inbox 先读后写（追加），读不到就按"还没有 inbox"处理，带表头新建。
/// 任何 IO 失败都转成 `ok=false` 交给调用方提示，**不抛异常**——派活失败
/// 不是致命错误，用户还能复制提示词自己投递。
Future<McpDispatchResult> dispatchJob({
  required FsBridge bridge,
  required String projectRoot,
  required String file,
  required int cursor,
  required String kindName,
  required String instruction,
  required String contextSnippet,
  DateTime? now,
}) async {
  final t = now ?? DateTime.now();
  final stamp = _stamp(t);
  final jobPath =
      '$projectRoot/$kAiJobsDir/${t.millisecondsSinceEpoch}-$kindName.md';
  final inboxPath = '$projectRoot/$kAiInboxFile';

  final md = buildJobMarkdown(
    file: file,
    cursor: cursor,
    kindName: kindName,
    instruction: instruction,
    contextSnippet: contextSnippet,
    stamp: stamp,
  );
  final w = await bridge.write(jobPath, md);
  if (!w.ok) {
    return McpDispatchResult(
      ok: false,
      error: w.error ?? '写作业文件失败',
      jobPath: jobPath,
      inboxPath: inboxPath,
    );
  }

  final line = buildInboxLine(
    jobRelPath: '$kAiJobsDir/${t.millisecondsSinceEpoch}-$kindName.md',
    kindName: kindName,
    file: file,
    stamp: stamp,
  );
  final old = await bridge.read(inboxPath);
  // FsReadResult.content 是**非空** String（读不到就是 ''），别写 ?.
  final prev = old.ok && old.content.isNotEmpty
      ? old.content
      : '# AI 作业收件箱\n\n'
          '远程 AI 请先看这里：每行一条待办。\n\n'
          '**没有未处理条目时请停下等待**，不要自行浏览项目或做健康检查；\n'
          '处理完一条就在对应作业文件顶部追加 `status: done`。\n';
  final merged = prev.endsWith('\n') ? '$prev$line\n' : '$prev\n$line\n';
  final w2 = await bridge.write(inboxPath, merged);
  if (!w2.ok) {
    // 作业本身已经落盘了，索引没写上也算部分成功——仍报 ok，
    // 但把错误带出去让用户知道索引可能没更新。
    return McpDispatchResult(
      ok: true,
      error: '作业已写入，但收件箱索引更新失败：${w2.error ?? "未知错误"}',
      jobPath: jobPath,
      inboxPath: inboxPath,
    );
  }
  return McpDispatchResult(
    ok: true,
    jobPath: jobPath,
    inboxPath: inboxPath,
  );
}

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
