/// MCP 工具与资源定义（alpha.60）。
///
/// **纯数据 + 纯函数**：本文件不依赖任何 Flutter/平台 API，可被单测直接
/// import。协议侧（mcp_server.dart 的 tools/list）与 UI 侧（远程协助页
/// 的「可用能力清单」）**同源渲染本文件**——避免文档与实现漂移。
///
/// 设计要点（面向「确保远程 AI 知道它能干什么」）：
/// - 每个 tool 的 description 必须写清**边界**（能做什么、不能做什么、
///   有什么限制），而不是只写功能名；
/// - [kInstructions] 是 initialize 响应里的 instructions 字段，是 AI
///   接入后看到的**第一段话**，负责建立环境心智模型；
/// - [kGuideMarkdown] 是 resource `foa://guide`，AI 需要细节时自行读取。
library;

/// 单个 MCP 工具定义。
class McpTool {
  final String name;
  final String description;
  final Map<String, Object?> inputSchema;

  const McpTool({
    required this.name,
    required this.description,
    this.inputSchema = const {'type': 'object', 'properties': {}},
  });

  /// MCP tools/list 的条目形态。
  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

/// 简易 schema 构造器（省掉大段重复字面量）。
Map<String, Object?> _schema(
        Map<String, Object?> props, List<String> required) =>
    {
      'type': 'object',
      'properties': props,
      'required': required,
    };

Map<String, Object?> _str(String desc) =>
    {'type': 'string', 'description': desc};

/// 设备容器内可用的项目根（与 FsBridge 的 kProjectsRoot 一致）。
const String kProjectsRootMcp = '/root/projects';

/// v1 工具集（6 个）。
///
/// **刻意不含 `build_apk`**：触发构建会让远程 AI 抢到 Flutter 启动锁、
/// 占用 20+ 分钟且中断路径不完善，风险远大于收益；AI 若确需构建可通过
/// [run_command] 自行执行，但须知会阻塞用户操作。
///
/// 注：非 const —— [inputSchema] 由 [_schema] 构造（`Map` 字面量可以 const，
/// 但方法调用不行），保持可读性优先。
final List<McpTool> kTools = [
  const McpTool(
    name: 'foa_info',
    description: '获取本机 FOA 开发环境信息：CPU 架构、Android API、'
        '容器 rootfs 路径、proot 路径、内置 Flutter 版本、当前构建后端。'
        '建议接入后**首先调用本工具**建立环境认知。无参数。',
  ),
  const McpTool(
    name: 'foa_diag',
    description: '一键运行 8 项标准诊断并返回完整报告：系统架构/内核、'
        'Dart 版本（经 x64 转发层）、Flutter SDK 完整性、x64 兼容层体检、'
        'JDK、磁盘、内存、残留进程。排查环境类问题时应**优先调用本工具**，'
        '而不是自己逐条敲命令——报告已按 AI 易读格式组织。无参数。',
  ),
  const McpTool(
    name: 'run_command',
    description: '在 Debian arm64 容器内执行一条 shell 命令并返回'
        'stdout/stderr/退出码。限制：① 看不到 Android 宿主文件系统'
        '（容器 / 即 rootfs，宿主的 filesDir、/sdcard 均不可见）；'
        '② 单条命令最长 600 秒；③ 同一时刻只允许一条命令（并发会返回 '
        'DeviceBusy，因为容器是单队列执行）；④ flutter 相关命令经 x64 '
        '转发层（QEMU）执行，比 PC 慢一个数量级属正常现象；'
        '⑤ 破坏性命令（rm -rf /、mkfs、dd、管道装脚本等）会被拒绝。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '要执行的 shell 命令'},
        'cwd': {
          'type': 'string',
          'description': '工作目录（可选，默认 /root/projects/<项目>）'
        },
        'timeoutSec': {
          'type': 'integer',
          'description': '超时秒数（可选，默认 60，上限 600）'
        },
      },
      'required': ['command'],
    },
  ),
  const McpTool(
    name: 'list_projects',
    description: '列出容器内 /root/projects 下的所有项目目录。'
        '每个项目根都是 /root/projects/<名称>。无参数。',
  ),
  McpTool(
    name: 'read_file',
    description: '读取项目内的文本文件（最大 2MB）。路径用容器内绝对路径，'
        '例如 /root/projects/my_app/lib/main.dart。',
    inputSchema: _schema(
      {'path': _str('容器内绝对路径')},
      ['path'],
    ),
  ),
  McpTool(
    name: 'write_file',
    description: '写入（覆盖）项目内的文本文件，目录不存在时自动创建。'
        '注意：这是**覆盖写**，不是追加；请先 read_file 确认现有内容，'
        '避免误删用户代码。',
    inputSchema: _schema(
      {
        'path': _str('容器内绝对路径'),
        'content': _str('文件完整内容'),
      },
      ['path', 'content'],
    ),
  ),
  McpTool(
    name: 'list_dir',
    description: '列出指定目录的内容（不递归），返回名称、类型、大小、'
        '修改时间。路径用容器内绝对路径。',
    inputSchema: _schema(
      {'path': _str('容器内绝对路径，例如 /root/projects/my_app/lib')},
      ['path'],
    ),
  ),
];

/// initialize 响应的 instructions：AI 接入后看到的第一段话。
///
/// 目标是让 AI 在**不看文档**的情况下就知道：这是什么、能干什么、
/// 有什么坑、不该干什么。
const String kInstructions = '''
你已连接到一台 **Android 手机上的 FOA（Flutter on Android）开发环境**。

环境拓扑：
- 手机（aarch64）上运行一个 Debian **arm64** 容器（proot，无需 root）；
- 容器内装有 Flutter 官方 SDK，但注意：**官方只发布 x86_64 宿主工具链**，
  因此 dart / gen_snapshot / impellerc 等 x64 工具是通过 QEMU 转发层执行的
  （由 FOA 的「x64 兼容层」自动维护）；
- 用户的项目位于容器内 /root/projects/<项目名>。

你可以做什么：
- 读取、列出、写入用户项目文件；
- 在容器内执行任意（非破坏性）shell 命令；
- 调用 foa_info 获取设备信息，调用 foa_diag 一次性拿到 8 项环境诊断报告。

你必须知道的三件事：
1. **慢是正常的**：flutter 命令经 QEMU 转发，比 PC 慢一个数量级。
   首次 `flutter run -d web-server` 编译可能 3-8 分钟——这不是卡死。
2. **构建与 Web 预览互斥**：二者共用 Flutter 工具链启动锁
   （bin/cache/lockfile），并发会互相卡住。执行此类命令前请先询问用户。
3. **不要做破坏性操作**：不要 rm -rf、mkfs、格式化、批量删除用户代码。
   你的目标是协助开发，不是重装系统。

建议开场顺序：先 foa_info 建立环境认知 → 需要排查时 foa_diag →
再进入具体任务。若需环境细节（目录结构、已知坑），读取 resource `foa://guide`。
''';

/// resource `foa://guide`：按需拉取的详细说明（Markdown）。
const String kGuideMarkdown = '''
# FOA 远程协助 · 环境指南

## 1. 这是什么

Android 手机上的完整 Flutter 开发环境。手机上跑一个 Debian arm64 容器
（proot 用户态，无需 root），容器内装 Flutter SDK 用于构建 APK 与 Web 预览。

## 2. 为什么工具是 x86_64 的

Flutter 官方**不发布 aarch64 Linux 宿主构建**，只发 x86_64。因此：

- `dart`、`gen_snapshot`、`impellerc`、`aapt2` 等在容器内都是 x64 ELF；
- FOA 通过「x64 兼容层」生成转发脚本，用 qemu-x86_64-static 执行它们；
- 代价是**指令翻译开销**：同名命令比 PC 慢约一个数量级。

## 3. 目录结构

| 路径 | 说明 |
|---|---|
| `/root/projects/<项目>` | 用户项目根 |
| `/root/projects/<项目>/lib` | Dart 源码 |
| `/opt/flutter` | Flutter SDK（x64，经转发层） |
| `/opt/flutter/bin/cache/lockfile` | **Flutter 启动锁**（构建/预览互斥的根源） |
| `/opt/foa-dl` | FOA 的下载缓存 |
| `/opt/foa-native` | 原生 arm64 加速产物（如移植版 gen_snapshot） |

## 4. 已知现象与判读（不要误判为故障）

| 现象 | 正确判读 |
|---|---|
| flutter 命令很慢 | 正常：经 QEMU 转发，慢一个数量级 |
| `Waiting for another flutter command to release the startup lock` | 有另一个 flutter 进程在跑（构建或 Web 预览），等它结束 |
| `Snapshot not compatible` | 转发层未生效，需在 App「工具链」页重新应用 x64 兼容层 |
| `invalid ELF header` 红字但构建成功 | FOA 已知的**假警报**（已在 alpha.56 修复；旧版本会误报） |
| Web 预览「编译中」很久 | DDC 首次编译 1-5 分钟，编译期无日志输出属正常 |
| `no space left on device` | 容器磁盘满，可清理 `/opt/foa-dl` 缓存 |

## 5. 你不应该做的事

- 不要 `rm -rf`、`mkfs`、`dd`、格式化任何路径；
- 不要通过管道执行下载来的脚本（`wget ... | sh`）；
- 不要在没有询问用户的情况下触发 `flutter build apk`（会占用 20+ 分钟并阻塞用户）；
- 不要试图访问 Android 宿主文件系统——容器里根本看不到，这不是权限问题。

## 6. 与用户的协作方式

用户在手机上看着这个环境。你的每次操作都会出现在 App 的
「远程操作记录」里，用户实时可见。建议：

- 动用户代码前，先说清楚要改什么、为什么；
- 长耗时命令前提醒用户；
- 优先用 foa_diag 获取诊断，而不是逐条试命令。
''';
