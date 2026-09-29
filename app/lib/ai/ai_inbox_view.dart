import '../editor/fs_bridge.dart';
import 'mcp_dispatch.dart';

/// 派活链路的可观测入口（alpha.84）。
///
/// ## 为什么需要它
/// alpha.81 把"派活"这件事设计成**异步无回执**：写作业文件 + inbox 索引，
/// 等连了隧道的外部 AI 客户端自己来领。协议上这是最稳的，但对用户是个
/// **黑盒**——派完之后他只能看到一句 toast，接下来的问题一个都答不上来：
///
/// - 作业到底写进项目里了吗？还是写到别处去了？
/// - 有外部 AI 来领过吗？
/// - 它改的是我不是打开的那个文件吗？
/// - 它是改了但改错了，还是压根没动？
///
/// 用户原话是"**不确定外部 AI 干了什么**"——这就是缺一个能自己看的地方。
/// 本模块把黑盒摊开成可读的文本快照，UI 只负责展示，判定逻辑全在这里，
/// 因此完全可测（见 `test/ai_inbox_view_test.dart`）。

/// 一条作业的状态。
enum AiJobStatus {
  /// 作业文件里出现了 `status: done`（外部 AI 按约定回执过）。
  done,

  /// 作业还在，没有 done 标记 —— 可能没人领，也可能改了没回执。
  pending,
}

/// 收件箱快照里的一条作业。
class AiJobEntry {
  /// 容器内绝对路径。
  final String path;

  /// 作业文件名（`<毫秒时间戳>-<类型>.md`）。
  final String name;

  /// 从文件名解析出的类型（complete / instruct），解析不出就是空串。
  final String kindName;

  /// 从文件名解析出的投递时刻；解析不出是 null。
  final DateTime? createdAt;

  final AiJobStatus status;

  const AiJobEntry({
    required this.path,
    required this.name,
    required this.kindName,
    required this.createdAt,
    required this.status,
  });

  bool get done => status == AiJobStatus.done;
}

/// 派活链路的整体快照。
class AiInboxSnapshot {
  /// inbox 索引文件（`.foa/ai-inbox.md`）的内容；读不到就是空串。
  final String inbox;

  final bool inboxExists;

  /// 作业列表，**新的在前**（用户最关心刚派的那条）。
  final List<AiJobEntry> jobs;

  /// 一次成功读取时附带的错误（例如目录不可读）；正常情况为 null。
  final String? error;

  const AiInboxSnapshot({
    this.inbox = '',
    this.inboxExists = false,
    this.jobs = const [],
    this.error,
  });

  bool get isEmpty => jobs.isEmpty && inbox.trim().isEmpty;

  /// 待处理的作业数（给入口做角标）。
  int get pendingCount => jobs.where((j) => !j.done).length;
}

/// 从作业文件名解析出 `(createdAt, kindName)`。
///
/// 文件名由 [dispatchJob] 生成，格式 `<毫秒时间戳>-<类型>.md`。解析要
/// **宽容**：这是给用户看的诊断信息，文件名被人手动改过也得能显示出来，
/// 不该整个列表因此报错 —— 解析不出的部分留空即可。
({DateTime? createdAt, String kindName}) parseJobFileName(String name) {
  final base = name.endsWith('.md') ? name.substring(0, name.length - 3) : name;
  final dash = base.indexOf('-');
  if (dash <= 0) return (createdAt: null, kindName: base);
  final ms = int.tryParse(base.substring(0, dash));
  final kind = base.substring(dash + 1);
  return (
    createdAt: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
    kindName: kind,
  );
}

/// 作业正文里是否带 `status: done` 回执。
///
/// 约定写在 [buildJobMarkdown] 的"交付方式"里，由**外部 AI 自己**追加，
/// 所以只能靠文本匹配，且必须宽松：行首可有 `- ` / `* ` 等列表符号，
/// 大小写与两侧空格都不敏感。
bool jobMarkedDone(String content) => RegExp(
      r'^\s*[-*]?\s*status\s*:\s*done\s*$',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(content);

/// 读一次派活链路的完整状态（只读，不产生任何副作用）。
///
/// 任何一步失败都**降级为"看不到"而不是抛异常**：这是个诊断入口，
/// 它自己崩掉比看不到更糟。
Future<AiInboxSnapshot> loadAiInbox({
  required FsBridge bridge,
  required String projectRoot,
  int maxJobs = 20,
}) async {
  if (projectRoot.trim().isEmpty) {
    return const AiInboxSnapshot(error: '项目根为空，无法定位派活目录');
  }
  final jobsDir = '$projectRoot/$kAiJobsDir';
  final inboxPath = '$projectRoot/$kAiInboxFile';

  final inboxRead = await bridge.read(inboxPath);
  final list = await bridge.list(jobsDir);
  if (!list.ok) {
    // 目录不存在是**最常见也最正常**的情况（从没派过活），不算错误。
    return AiInboxSnapshot(
      inbox: inboxRead.ok ? inboxRead.content : '',
      inboxExists: inboxRead.ok,
      error: list.error == null ? null : '读作业目录失败：${list.error}',
    );
  }

  final mdFiles =
      list.entries.where((e) => !e.isDir && e.name.endsWith('.md')).toList()
        // ⚠️ 按解析出的时间戳排，**不能按文件名字符串倒序**：时间戳是变长整数
        // （毫秒数 13 位，但早期/手改过的可能更短），字符串比较会得出
        // '900' > '3000' 这种荒谬结论，把最旧的顶到最前。
        // 解析不出的（createdAt == null）排在最后，它们连时间都不知道。
        ..sort((a, b) {
          final ta = parseJobFileName(a.name).createdAt;
          final tb = parseJobFileName(b.name).createdAt;
          if (ta == null && tb == null) return b.name.compareTo(a.name);
          if (ta == null) return 1;
          if (tb == null) return -1;
          return tb.compareTo(ta);
        });

  final jobs = <AiJobEntry>[];
  for (final e in mdFiles.take(maxJobs)) {
    final path = e.pathOf(jobsDir);
    final r = await bridge.read(path);
    final parsed = parseJobFileName(e.name);
    jobs.add(AiJobEntry(
      path: path,
      name: e.name,
      kindName: parsed.kindName,
      createdAt: parsed.createdAt,
      // 读不到正文时保守当作"未完成"——宁可让用户多点一次进去看，
      // 也不要谎报"已完成"让他以为 AI 干完了。
      status: r.ok && jobMarkedDone(r.content)
          ? AiJobStatus.done
          : AiJobStatus.pending,
    ));
  }
  return AiInboxSnapshot(
    inbox: inboxRead.ok ? inboxRead.content : '',
    inboxExists: inboxRead.ok,
    jobs: jobs,
  );
}

/// 一行作业的展示文案（纯函数，便于测试）。
String describeJob(AiJobEntry j) {
  final b = StringBuffer();
  b.write(j.done ? '✅ ' : '⏳ ');
  b.write(j.kindName.isEmpty ? '作业' : j.kindName);
  final t = j.createdAt;
  if (t != null) {
    String two(int v) => v.toString().padLeft(2, '0');
    b.write(' · ${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}');
  }
  return b.toString();
}
