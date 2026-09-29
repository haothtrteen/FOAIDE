# FOA —— Flutter on Android IDE

**在手机上直接开发、构建、运行 Flutter 应用。** 不需要电脑、不需要 root。

FOA 是一个原生运行在 Android 上的 Flutter IDE：设备内自带 Flutter SDK、
本地 Linux 容器（proot + Debian rootfs）、Web 热重载预览，以及
**在手机上直接产出 APK**。

```
┌──────────────────────────────────────────────┐
│  Android 设备（arm64，无 root）              │
│                                              │
│  FOA App（Flutter）                          │
│    ├─ 代码编辑器 / 设计器 / 清单编辑          │
│    ├─ Web 热重载预览（改代码即时看效果）      │
│    └─ 构建编排 ──┐                            │
│                  │ fork/exec                  │
│  ┌───────────────▼────────────────────────┐  │
│  │  proot 容器（Debian bookworm arm64）   │  │
│  │    ├─ Flutter SDK / Dart               │  │
│  │    ├─ Android SDK / Gradle             │  │
│  │    └─ 你的工程 → 产出 APK              │  │
│  └────────────────────────────────────────┘  │
│                  │                            │
│  x64 工具（gen_snapshot 等）→ QEMU 指令翻译  │
└──────────────────────────────────────────────┘
```

## 它解决什么问题

官方 Flutter **不支持在 Android 上构建 Android 应用**。FOA 用三层拼出这条路：

| 层 | 做法 | 为什么需要 |
|---|---|---|
| **容器** | proot + Debian rootfs（免 root） | Android 上跑完整 Linux 工具链，且不动系统 |
| **工具链** | 设备内安装 Flutter SDK / Android SDK / JDK | 不依赖电脑，全部落在容器里 |
| **指令翻译** | QEMU 跑 x64 版 `gen_snapshot`/`impellerc` | 官方**没有** arm64 版 AOT 工具（[flutter#152281](https://github.com/flutter/flutter/issues/152281)） |

第三层是真正的难点，也是本仓库 `dev-handbook/` 里绝大部分 Bug 的来源。

## 快速开始

### 你要先有

- 一台 **arm64 Android 设备**（Android 10+，**不需要 root**）
- 约 **8 GB 可用存储**（SDK + rootfs + 构建缓存）
- 能访问网络（首次要下 SDK，容器内走清华 TUNA 镜像）

### 跑起来

```bash
git clone <本仓库>
cd FOA/app
bash tools/fetch_assets.sh all      # 下载未跟踪资产（rootfs 等，约 76MB）
flutter pub get
flutter run --release               # 装到设备上
```

装机后的完整使用流程见 **[构建流程.md](构建流程.md)**。

### 想从源码出包

```bash
cd app
./tools/check_env.sh                 # 1. 自检资产与环境
cat /sys/fs/cgroup/memory.max        # 2. 看清内存配额（重要，见「关键约束」）
flutter pub get                      # 3. 拉依赖
flutter analyze && flutter test      # 4. 门禁（预期 7 条基线 / 1774 项通过）
bash ../tools/sync_platform.sh       # 5. 模板漂移检查（应与代码一致）
flutter build apk --release --target-platform=android-arm64   # 6. 出包
```

完整流程、内存配置公式、常见问题排查 → **[构建流程.md](构建流程.md)**。

## 功能

| 区域 | 能力 |
|---|---|
| **工程** | 新建（空白模板）/ 导入 zip·tar.gz·tar.xz / 导出 tar.gz / git 远端（HTTPS+PAT，只走 `--ff-only`） |
| **编辑** | 代码编辑器（语法高亮、自动保存、外部改动自动同步） |
| **设计** | 可视化界面设计器，生成 Flutter 代码；可从已有 UI 反向导入 |
| **清单** | 应用名 / 包名 / 版本 / 权限 / 混淆开关 / 图标替换 / 签名补丁 |
| **构建** | debug（快，JIT）/ release（AOT，可上架）；实时日志；失败自动分诊给提示 |
| **工具链** | 一键装 Flutter SDK / Android SDK / JDK / x64 兼容层；云端部署入口 |
| **AI** | 内置 LLM 接入（OpenAI 兼容接口）+ MCP 客户端；可派活到远程 AI |

## 目录

| 路径 | 内容 |
|---|---|
| `app/` | Flutter + Android 工程（含完整 git 历史） |
| `dev-handbook/` | **开发手册 01–07**：环境、构建、测试、Bug 库、许可证、发布、原生化 |
| `.trae/skills/` | 3 个构建相关 skill（出包工序、产物验证、体积优化，1900+ 行） |
| `docs/` | 技术方案评估（AVF、box64、Web 预览预热、保活等） |
| `tools/` | 交付脚本：打包、出包、验证、模板同步 |
| `构建流程.md` | **从零到出包的完整步骤** |

> **`dev-handbook/04-常见Bug与解决方案.md` 是本仓库最有价值的部分。**
> 它记录了 400+ 个真实踩坑，每个都带症状、根因、实证过程与修法。
> 如果你在 Android 上跑 Flutter 工具链，多半能在这里找到答案。

## 许可

本项目采用 **AGPL-3.0 + 商业授权** 双许可：

- **开源使用**：按 [AGPL-3.0](LICENSE) 自由使用、修改、分发；
- **闭源集成 / 商业使用**：需[商业授权](LICENSE-COMMERCIAL.md)，
  详见 [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md)。

第三方组件各自适用其原有许可证，清单见
[app/THIRD-PARTY-NOTICES.md](app/THIRD-PARTY-NOTICES.md)。

贡献代码请先阅读 [CLA.md](CLA.md)。

## 状态

**v0.1.0-alpha.98** —— 功能可用，仍在快速迭代。已知边界写在每节末尾，
不用"基本可用"之类的话糊过去。

---

## 关键约束（改动前先读）
- **targetSdk 固定 28** —— W^X 策略的刻意选择，非疏漏
- **Gradle 堆按 cgroup 上限换算，且要 Σ 全部 daemon**（release 构建实测同时存活
  3 个 JVM：Gradle + 两个 Kotlin 编译器）。换机器必须重算，公式见构建流程 §5
- **内存问题读计数器，不要估算**：`cat /sys/fs/cgroup/memory.events` 的
  `oom_kill` 是唯一可信判据；`free -m` 读的是宿主内存，会误导你一路加堆
- **`assets/` 下二进制资产不进 git**，但已随本包提供


# 更新日志

> 以下按版本倒序。每条都注明**诚实边界**——哪些没做、哪些是推测、
> 哪些只在特定条件下成立。

## 当前状态

| 项 | 值 |
|---|---|
| 版本 | v0.1.0-alpha.98+98 |
| ABI | arm64-v8a |
| targetSdk | 28 |
| 默认构建档 | **debug**（alpha.94 起，可手动切 release） |
| analyze / test | 7 条基线（均在 `third_party/`）/ 1774 项通过 |

### alpha.98（本轮）：Bug 638 老写法进构建前置 + Bug 639 模板漂移门禁

两件事都是**补上自己承认过的缺口**，不是新功能。

| # | 项 | 背景 | 做法 |
|---|---|---|---|
| ① | **Bug 638**：老写法检测搬进构建前置 | README 自己写过："检测只在清单页触发，用户若从不打开清单页……**本轮未做**" | 构建前调用 `Signing.repairLegacyPatch`，与 Bug 636 的 shrink 检查同处前置段。**这是 Bug 636 的孪生兄弟**——同一个"用户直接点打包"路径 |
| ② | **Bug 639**：`platform/` 模板漂移门禁 | 手册 Bug 440 记着：模板落后一个月、269 行 PTY 代码从没进过构建目录，**而测试全绿** | `tools/sync_platform.sh`（检查 / `--fix`）+ `test/platform_drift_test.dart`（逐字节比对）。**双保险，同一份映射表** |

**① 的判据细节**：`r.changed` 才打日志，**不能按 `msg` 非空判**——
`repairLegacyPatch` 在"没事"时也会返回 msg（如"构建脚本没有老写法"），
按 msg 判会让**每次构建都刷一行无意义警告**（有断言守着）。

**② 为什么当初测试会全绿**：那时的断言是**分别**检查两个文件
"各含某些字符串"，而不是断言**两者相同**。一个文件多了东西、
另一个没有——两边各自的断言都还是过的。
**所以新门禁只做逐字节比对，不分析语义**——"语义分析"正是当初漏掉它的原因。

**门禁自己也被验证过**：人工注入一行漂移 → 测试报错并指出
"首个差异在第 64 行"、脚本 exit 1；`--fix` 能一键同步回去。
**一个不会失败的门禁等于没有门禁。**

新增 9 条断言（Bug 638 五条 + Bug 639 四条），全量 **1774 项通过**。

### alpha.98（前半）：Bug 636 —— AGP 拒绝非法的 shrink 组合

用户贴出 debug 构建日志，报 `Removing unused resources requires unused
code shrinking to be turned on.`，并问「怎么又出现这个 bug 了，一直反复
是为什么」。

**先要拆掉"又"这个陷阱**：这和之前的 `Unresolved reference 'util'/'io'`
是两个独立问题。三个坑分别位于 ——

| # | 出问题的地方 | 我们的代码在哪一层 | 用户感知 |
|---|---|---|---|
| ① | `scripts/` 里老写法的构建脚本 | 就是我们自己写的（alpha.94/96 改的） | "又报错了" |
| ② | 生成器修了 ≠ 用户现场修了 | 模板改了，用户工程里还是旧脚本 | "修了怎么还报" |
| ③ | **本次**：AGP 配置期校验 | **我们连碰都没碰到** | "又报错了" |

#### 根因（三层叠加，字节码 + SDK 源码双实证）

**第一层 — AGP 硬校验**。反编译 `gradle-8.13.1.jar` 的
`AndroidResourcesCreationConfigImpl.getUseResourceShrinker()`：

```java
if (!getResourcesShrink()) return false;
if (componentType.isForTesting()) return false;
if (!getMinifiedEnabled()) {
    issueReporter.reportError("Removing unused resources requires ...");
    return false;   // ← 是 error，不是 warning → 配置期直接失败
}
```

即 **`shrinkResources=true` + `minifyEnabled=false` = 配置期致命错误**。
这解释了为什么日志里连一条编译错误都没有——构建根本进不到编译。

**第二层 — Flutter 插件无条件设值**（`FlutterPlugin.kt:216-219`，
注意没有 `if`）：对 `release` 无条件设 `isMinifyEnabled = true` 且
`isShrinkResources = isBuiltAsApp()`。所以任何 Flutter 工程的 release
块天生就是 `minify=true, shrink=true`；谁把 minify 改成 false 却没同步
改 shrink，就踩中第一层。

**第三层 — 为什么 debug 也炸**：debug buildType 通过继承链拿到了
`buildTypes.release` 的属性。**在 release 块里手动关 minify，会把 debug
的配置一起搞挂。**

#### 为什么我们之前的修复漏了

`_syncShrinkResources` 只在"文件里已经有这一行"时才改。而用户现场的
那一行是**插件默认/模板/继承**写进去的，UI 读 `minify` 拿到的 `true`
是 **AGP 的 release 默认值** → 开关显示"开" → 我们什么都不改。

> **判据原则**：`parseGradle` 读到的 `true` 可能是默认值。
> **拿默认值当判据去改用户文件 = 误改。** 必须要求**两个值都显式写了**。

#### 修法：只改 shrink，绝不碰 minify

`explicitShrinkResources` / `explicitMinify`（区分"没写"与"写了 false"）
→ `hasIllegalShrinkCombo` → `fixIllegalShrinkCombo`。

选改 `shrinkResources` 而非 `minifyEnabled`：`minifyEnabled = false` 是
用户**刚刚手动设的明确意图**，不能推翻；`shrinkResources = true` 多半
来自插件默认，关掉只是包大一点，不影响功能。

**接线放在构建前**（`build_runner.dart`，磁盘检查之后、启动构建之前）——
因为**用户可能从不打开清单页**，直接点打包。前置检查是唯一能救到他的
地方。

#### `--no-shrink` 是空 flag

用户日志里那条命令带着它，但 `flutter_command.dart:986` 的 help 原文是
`'This flag has no effect. Code shrinking is always enabled in release
builds.'`，且**不映射**到 `-Pshrink=false`（全仓库只有 deferred
components 那条分支会设该属性，`gradle.dart:613`）。

#### 验证

| 项 | 结果 |
|---|---|
| `flutter analyze lib/` | `No issues found!` |
| `manifest_codec_test.dart` | **66 条全过**（原 53 + 新增 13） |
| 全量门禁 | **1762 全过**（1749 + 13） |

新增 13 条含 **4 条"不误报"**（只有 shrink=true / shrink+minify 都 true /
shrink 没写 / shrink=false+minify=false 各种合法形态）与 **1 条接线护栏**
（断言 `_fixIllegalShrinkCombo` 必须出现在 `execStream(cmd` 之前）。

明细见 `dev-handbook/04-常见Bug与解决方案.md` 第十七章。

### alpha.97：构建流程三段优化

起因是用户一句「最后的默认等待 90s」，追问后确认现象是**每次都干等满 90s**
（说明 flutter 进程每次都 hang）。顺着这条线盘出三段可优化点：

| # | 优化点 | 改法 | 预期收益 |
|---|---|---|---|
| ① | **收尾宽限期**（本次重点） | 判据从「纯计时」升级为「**产物双证据确认**」：命中 Built 后探 APK，`size`+`mtime` **连续两次完全一致**即立刻收尾；确认不了才退回等宽限。上限同时 90s → 20s | 90s → **1~3s**（探测成立时） |
| ② | **前置检查合并** | 原来 Dart 侧单独发一次 `exec` 查 Flutter 是否存在（+1 次容器往返），现并入主 shell 最前段，失败 `exit 65` | 少一次 proot 往返（几百 ms 级） |
| ③ | **pub get 退避** | 固定 `sleep 3` → **1s → 3s 递增**，换源时重置回 1s | 抖动路径 6s → 2s |

**① 为什么不是"把 90s 调小"那么简单**：用户明确的取舍是「宁可慢一点也别
出错」，所以判据必须是**证据**而不是**时间**。三条同时成立才提前收尾：

1. 产物看得见（`size > 0`，排除"目录项已建、内容未写"）；
2. **两次读数完全相等**（大小 + mtime 都不变，说明没在继续写）；
3. 两次探测间隔 ≥ 2s（挨太近的"一致"没有信息量）。

用"稳定性"而不是"够大"当判据，是因为 APK 大小本就波动（debug/release、
依赖增减都会变），任何绝对阈值都会在某个项目上失效；稳定性是无量纲的。
凑不齐这三条就老实等满宽限期——**绝不允许"没看到产物也按成功收尾"**。

**③ 的诚实说明**：正常网络下这条改动**几乎看不出差别**（顺利路径本来就
是 0s 等待，成功即 break）。它的价值只在弱网抖动时少等几秒。退避秒数也
刻意偏保守（没上 0/1/2 那种激进序列）——弱网是这条链路的主要场景，
退避太短会把"本来第二次就能成功"变成"两次都撞在同一个抖动窗口上"。

#### 顺带撞出的一个静默 bug

给 ③ 写"termux 不该出现容器路径"的断言时，**断言挂了 —— 而挂的是代码**：

`diag` / `heal` / `reassert` / `stampFix` 四段脚本的路径原先**全部写死容器值**
（`/opt/flutter`、`/opt/android-sdk`），而 **termux 后端的 Flutter 与 SDK
装在 prefix 下**。路径错的表现不是报错，而是**整段整段地静默短路**：

| 段 | 短路点 | 静默后果 |
|---|---|---|
| `stampFix` | 写不存在的目录 | Bug 436 想省的 `git fetch --tags` 从未省掉 |
| `diag` | `[ -x @QEMU@ ] \|\| exit 0`… | 日志里连 `QEMU_CHAIN_*` 都没有 |
| `heal` | 目录不存在 → `HEALED=0` | 自愈是空跑 |
| `reassert` | `[ -d "$E" ] \|\| exit 0` | 转发层重建是空跑 |

**这个 bug 藏了很久的原因**：每一段都"有输出"（`REASSERT=0`、`HEALED=0`
都是合法的正常输出），从日志上完全看不出是"跑了但什么都没做"还是
"本来就没事"。

修法：`QemuCompat.fill` 的 `@FLUTTER@` / `@ENGINE@` / `@SDK@` 三个占位符
参数化，`buildCommand` 按后端传入。**默认值保持不变**，proot 路径语义
完全不受影响。

> 元教训：**"有输出"不等于"做了事"**。凡是"查一下、没有就跳过"的
> 幂等脚本，都要能区分「检查通过」和「检查根本没跑到」。

### alpha.96：老签名补丁的检测与修复

起因是一条**看起来像"alpha.94 没修好"**的真机反馈：用户工程的 debug 构建
反复报 `Unresolved reference 'util' / 'io'`。

实际是**两个问题叠在一起**：

| 层 | 问题 | 修法 |
|---|---|---|
| 代码写法 | `plugins {}` 会遮蔽 `java` 标识符，`java.util.Properties()` 全限定名解析不了 | alpha.94 已改生成器（用 `import` + 简单名） |
| **流程缺口** | 补丁是**写进用户工程文件**的，已生成的工程不会自动回写；而补丁守卫是"已有 `signingConfigs` 就不动"，对老工程直接返回失败 → **老写法原封不动留着** | **本轮新增**：检测 + 升级 + UI 修复入口 |

| 项 | 落点 | 一句话 |
|---|---|---|
| **老写法检测** | `Signing.hasLegacyJavaFqn` | 只看**用法**、排除 `import` 行本身（否则新补丁会被误判成老的） |
| **老写法升级** | `Signing.upgradeLegacyJavaFqn` | 换简单名 + 补 import，幂等 |
| **补丁时顺带修** | `Signing.patchBuildScript` | 守卫拦住完整补丁时，**仍然把老写法修掉**再返回 |
| **修复入口** | 清单页签名卡 | 打开就检测；检测到显示红色警告 + 「修复构建脚本」按钮，明写**不会动你的密钥** |

真 gradle 三组对照（Gradle 9.3.0）：

| 写法 | 结果 |
|---|---|
| 无 `plugins {}` + `java.util.Properties()` | ✅ 通过 |
| **有** `plugins {}` + `java.util.Properties()` | ❌ `5:31 Unresolved reference 'util'` |
| 有 `plugins {}` + `import` + `Properties()` | ✅ 通过 |

**核心教训**：修好生成器 ≠ 修好用户现场。凡是"由工具写入用户文件"的代码，
都要配一条**检测 + 升级**路径 —— 已生成的文件不会自己变新。

诚实边界：**检测只在清单页触发**，用户若从不打开清单页、直接用打包区构建，
仍会撞上老写法（理想方案是在构建前置检查里也加一道，本轮未做）；
`upgradeLegacyJavaFqn` 只覆盖签名补丁会产出的那几种全限定名。
详见手册[第十四章](dev-handbook/04-常见Bug与解决方案.md)。

### alpha.68：导入 / 导出 Flutter 源码工程

两条对称能力，**零 Kotlin 改动** —— 复用了早就存在的 `pickImportFile`
（`ACTION_OPEN_DOCUMENT` → 落到容器 `/root/imports/`）与 `exportFile`
（SAF 保存，源路径走 `resolveRootfsPath` 白名单，`/root/imports` 天然合法）。

| 能力 | 入口 | 说明 |
|---|---|---|
| **导入** | 主页 FAB →「创建工程」面板 →「导入 Flutter 源码工程」 | 选 `.zip` / `.tar.gz` / `.tar.xz` / `.tar`，解压到 `/root/projects/<name>`，自动出现在工程列表 |
| **导出** | 工程页 AppBar 分享图标 | 打成 `<name>-<yyyyMMdd-HHmm>.tar.gz`，走系统保存对话框落到手机 |

三处设计取舍：

1. **探测先于解压** —— 只列成员名（`unzip -Z1` / `tar -tf`）判定有无
   `pubspec.yaml`。选错文件（截屏、APK）是高频误操作，不该让用户等
   500MB 解压完才被告知"这不是 Flutter 工程"。
2. **暂存在 `/root/imports/.foa_extract/`，不在 `/root/projects/`** ——
   主页工程列表就是 `browse('/root/projects').where(isDir)`，半成品放进去
   会立刻以"工程"的样子出现在用户眼前。中途失败对列表零影响。
3. **导出排除构建缓存是正确性问题** —— 导出走 SAF 字节流，打进包的每个
   字节 1:1 落到用户手机。清单见 `ProjectImporter.kPackExcludes`，确认框里
   会**列给用户看**（300MB → 8MB 的体积差，不说清楚用户会以为导出坏了）。

自家导出的包（`tar -C /root/projects <name>`，成员是 `<name>/...`）与
GitHub「Download ZIP」（`<repo>-main/...`）都落进 `ImportLayout.singleDir`
分支，**能被自家导入直接吃回去** —— 这条有单测守着。

> 全部业务逻辑集中在 `app/lib/demo/project_importer.dart`，纯静态可测，
> 63 条契约断言见 `app/test/import_export_project_test.dart`。

### alpha.70 / alpha.71：项目工作台「设计」区

### 导入已有 UI（alpha.71）

「**结构级导入**」：用 AST（`package:analyzer`）解析你项目里的页面文件，
认识的组件还原成可编辑节点，**不认识的 widget 原样保留**。

- 入口：设计区工具栏的下载图标 → 扫 `lib/` 下的 `.dart` → 选文件 → 选 build 方法
- **不认识的 widget 不会丢**。设计器把它画成虚线占位框（树上显示它的真实类名），
  生成代码时把**源码原文**（连注释带缩进）整段吐回去。所以
  `ThirdPartyLoginRow(...)`、`BlocBuilder`、`children:` 里的 `if (...)` 条件渲染
  都原封不动地留在生成物里
- **`Column` / `Row` 会摊平**。设计器模型与 `Column` 同构（不做绝对定位，
  见 `design_model.dart` 的注释），`Row` 摊平会额外给出提醒——横排变竖排是真变了
- **保存去向由你定**：预览代码 → 点「保存」→ 弹窗里选**覆盖原文件**（会先备份成
  `.dart.bak`）或**存为新文件**。覆盖弹窗会明确写出代价：设计器只生成静态界面，
  覆盖会把原文件的业务逻辑/状态/路由全部替换掉

> 纯逻辑（数据模型 + 代码生成器）在 `app/lib/project/design_model.dart`；
> 解析层在 `app/lib/project/design_import.dart`。
> 断言分布：`design_model_test.dart` 52 条 / `design_import_test.dart` 46 条 /
> `design_wiring_test.dart` 28 条。生成器与导入产物的输出已用 `flutter analyze`
> 验证过**零 error**（只有 `prefer_const_*` 级 info）。


可视化拼界面 → 生成 Dart 代码落进 `lib/generated/`。入口在工程页抽屉里
（「概览 / 代码 / **设计** / 清单 / **版本** / 打包 / AI 接管」——
alpha.93 起「版本」区提供容器内 git 的 status / add / commit / log）。

**先说清边界。** 对标对象 [FlutterViz](https://flutterviz.com) 官网原话：

> *NO, it's not yet another NO-CODE or LOW-CODE platform, instead, it is a
> simple visual builder to create Flutter App Screens.. That's it!*

本功能对齐这条线：**只生成静态界面**，不含业务逻辑、状态管理、数据流、路由。
生成物是**起点**不是成品——省掉的是"从空白文件敲 200 行 Column/Row/Padding"
这段体力活，接逻辑本来就得你自己来。**不承诺"拖一拖就出可运行 App"**：
按钮点了不会有反应，这符合预期。

| 能力 | 说明 |
|---|---|
| **模板** | 空白 / 登录页 / 列表页 / 详情页，一键铺开初值树 |
| **组件库** | 标题、文本、按钮、输入框、图片、图标、间距、分割线、卡片、列表项 |
| **组件树** | 点选定位，上移/下移调顺序，删除 |
| **属性面板** | 按组件类型自动生成编辑控件（文字/数值滑条/开关/选项芯片） |
| **实时预览** | 把设计树直接渲染成**真实 Widget**，所见即所得 |
| **导入已有 UI** | 解析**你自己项目里**的 `.dart`，还原成可编辑设计树（见下） |
| **生成代码** | 先给预览、由你选保存去向，可一键跳代码区打开 |

三个刻意的取舍：

1. **不做拖拽，顺序即布局**。FlutterViz 是 Web 端有鼠标；我们是手机。
   "拖到指定坐标"在 6 寸屏上精度根本不够，用户会更频繁地拖歪再拖回来。
   改成「点组件库追加 + 树上调顺序」，可控得多，也不会出现组件互相叠住的坏状态。
2. **颜色只给语义位，不给调色盘**。手调 RGB 在切换深浅主题时会变成不可读的
   组合（深色主题下挑的黑字，切到浅色就消失了）。语义位由主题派生，两边都可读。
3. **预览与代码生成是两条独立实现**。让预览去"执行生成的代码字符串"需要
   `eval`（Dart 没有）或热重载，代价远超收益。两边都由
   `DesignComponentType` 的属性表驱动，加组件时同步改两处，有单测盯着字段键一致。

### alpha.94：默认 debug 档 / 预取构件 / Git 远端 / 签名库

| 项 | 落点 | 一句话 |
|---|---|---|
| **默认档位改 debug** | `FlavorPrefs.fallback` | 日常改代码不需要 AOT；`gen_snapshot` 在手机容器里是 QEMU 转译执行（慢 10~50 倍）。release 仍可手动切 |
| **预取引擎构件** | `lib/toolchain/artifact_prefetch.dart` | 官方 `precache --android_maven` 在 3.47.4 是**空操作**（类存在但从未实例化），配套的 `gradle -b` 在 Gradle 9 已删除 → 自建脚本；只拉 arm64，debug 约 182MB |
| **Git 远端** | `lib/project/git_remote.dart` | HTTPS + PAT，fetch/push/pull，凭据落 `/root/.git-credentials`（chmod 600，**不在工程目录**）。**只走 `--ff-only`**，不做冲突解决 |
| **签名库** | `lib/project/keystore_store.dart` | 多份 keystore 管理 + 导入外部 `.jks`，可切换；清单在 `/root/keystores/registry.json`。debug 签名可一键用（参数是 AOSP 公开的固定值） |

诚实边界：**预取只覆盖 arm64**；**Git 不做 SSH、不解决冲突**（分叉只报错指路）；
**导入只认带私钥的 keystore**（`.pem`/`.cer` 上传证书签不了 APK）；
签名库口令**明文存**（gradle 的 `key.properties` 本身就要明文，UI 上明说不假装加密）。

> ⛔ **proroot 二进制已从本仓库与 APK 中完全移除（alpha.69，方案 A）**。
> 上游许可（Proprietary）禁止再分发修改过的二进制，此前 alpha.66~68
> 打包进 `jniLibs/arm64-v8a/` 的五件套属于超出口径，**已全部删除**，
> 「一键下载」入口同时下架。决策全文与落地清单见
> [PROROOT-许可与分发决策.md](PROROOT-许可与分发决策.md)。
>
> 保留的是**原生侧的集成改造**（6 个 `PROROOT_*` 环境变量、runtime 库
> 落位到 `filesDir`、`-b <host>:<guest>` 参数形式、从 `nativeLibraryDir`
> 直接 exec）与 **UI 卡片**。若你持有合法副本，仍可通过卡片上的
> 「从本地导入」落位使用 —— 参考实现见作者开源 App
> [andClaw](https://github.com/coderredlab/andClaw) 的 `proroot/ProrootManager.kt`。
>
> ⚠️ `isKnownUnusable()` 仍为 `true`（继续劝退）：proroot 省的是容器层的
> ptrace 开销，而 FOA 构建慢的大头是 **QEMU x64 指令翻译** —— 它改善不了。
>
> 附带地，alpha.69 起 `tools/fetch_assets.sh` 的 `proroot` 子命令会
> **固定报错返回 1**，且 `all` 分支刻意不调用它；`flutter test` 里有
> 多条门禁盯着这些清单不被"顺手加回来"。

> 本轮（alpha.65）修复：
> ① **proroot 冒烟测试失败（Bug 471）** —— 曾误判为"上游版本钉错"
> （跟着 `main` 拿到要求 glibc 2.38 的 v1.2.8，而本机 rootfs 是 2.36）。
> 当时修复：钉到 **v1.2.5**、`upstreamRef` 从 `main` 改为钉 tag ——
> **这一步本身没错，但根因判断是错的**，详见上方 471e 说明；
> ② **下载器不建父目录（Bug 471b）** —— "终端 `wget` 能装、UI 装不上"
> 的真因，下载器现在自己保证父目录存在；
> ③ **终端手工隧道 502（Bug 473）** —— 隧道通但 8977 上没人听，
> 新增 `tools/foa-sh-mcp.sh`（纯 shell 终端版 MCP 服务）补齐；
> ④ **该脚本自身四个"语法全过、实测全错"的坑（Bug 474）** ——
> `--serve-one` 分流位置、`command` 参数名两端不一致、正则截断转义引号、
> `index()` 下标偏移；四个坑表征全是"响应为空"，只能逐层实测剥开。
> 现已**真发请求**验证（健康检查 / 完整协议序列 / 文件读写 / 黑名单 /
> 并发 5-5、连发 20-20），并把四条各写一条断言钉进单测；
> ⑤「远程接管」改名「远程协助」，并点明与「AI 接管」的分工；
> ⑥ 下载器并发兜底竞态（`PathNotFoundException`）；
> ⑦ gradle 读写路径不对称（`.gradle.kts` 工程保存失败）；
> ⑧ **About 页的 proroot 版本停在 v1.2.8（Bug 476）** —— 换版本时漏改，
> 现已改为引用 `ProrootOption.pinnedVersion` 唯一真源并加测试钉住。
> 这个是**出包后逐字节核对产物**才发现的——685 项测试全绿时它依然隐形。
>
> 🔴 **真机反馈推翻了 ① 的结论（Bug 471c）**：alpha.65 用钉死的 v1.2.5
> 做冒烟测试，**仍然崩**——
> ```
> proroot-ldso: no offset table for glibc 2.36 — patches skipped
> [proroot] SIGSEGV ... [proroot] child exited with code 139
> ```
> 我此前把 `no offset table` 判为"无害警告、真正致命的是 `reloc: unresolved`"，
> **这个判断是错的**：linker 没为目标 glibc 准备内部结构体偏移表，
> 补丁全部跳过 → 运行期取到垃圾数据 → 解引用崩溃。
> **更新版本也不行**（要 glibc 2.38，失败得更早）。可获得的版本只有
> v1.2.3~v1.2.8 四档，**穷举已做完，两个方向都堵死**。
>
> 🔴🔴 **真机判别实验又推翻了 471c 的根因（Bug 471d）**：471c 说"出路是
> 换 rootfs"，我**从没验证过这句话**。2026-09-21 补做了实验 ——
>
> **升级 rootfs 救不了。** 换上 Debian 13 / glibc 2.41 后报错**逐字相同**：
> ```
> libproroot.so: version `LIBC' not found (required by ./libproroot.so)
> ```
> 真正的根因（自写 ELF 解析器直读 `.dynamic` 拿到硬证据）：**`libproroot.so`
> 的 `DT_NEEDED` 写的是开发名 `libc.so` / `libdl.so`**，而同批其余 4 个库
> 都规规矩矩写 `libc.so.6`。这两个名字在任何运行时系统上都不是可加载的 ELF
> ——`libdl.so` 自 glibc 2.34 起已不再提供，`libc.so` 永远是 `libc6-dev`
> 带的 GNU ld script。**这与 glibc 版本无关，是上游构建产物的缺陷。**
>
> 顺带**推翻了我上一轮的一个猜测**：我曾推测"minbase 精简 rootfs 没装
> `libc6-dev`"，真机 `dpkg -l` 实测**是装了的**。问题不是"缺文件"，
> 而是"这个文件本来就不是 ELF"。
>
> **当前状态：proroot 在 Debian 12/13 上均不可用，且已确认我方无解**
> （许可禁止修改二进制，只能等上游重新构建）。
> 这不影响 alpha.65 作为**可用包**发布（proroot 是默认关闭的实验特性，
> 未启用时构建链路完全不受影响）——但它**不能**当作"已可用的加速选项"。
> 已做的处置：新增 `isKnownUnusable()` 门禁（真机结论优先于符号表推断）、
> UI 开关改为**硬拦**、原生侧识别**三种**失败形态（加载失败排在最先）、
> 风险清单前三条重写，并**显式堵掉"升级 rootfs / 换个版本"两条错误引导**。
>
> 详细变更见 `dev-handbook/04-常见Bug与解决方案.md` 的 Bug 464–476
> （**471c** 是第一次推翻，**471d** 是判别实验与最终根因）。

---

## ⚠️ 已知待决事项：proroot 分发

`dist/` 下 alpha.66/67 的 APK **打进了 proroot 五件套**，因此
`tools/verify_apk.sh` 的第 4/4 项（"proroot 不得入包"）会判红。

- **这不是"proroot 坏了"**，而是 `Bug 471f` 改造 ①（五件套进 `jniLibs`）
  与早期立下的"不代分发"门禁**没同步**；
- 上游措辞是"not permitted to redistribute **modified** binaries"，
  **字面没禁止原样再分发，但也没给出授权** —— 两种解读都不能推断；
- 我方行为是**原样下载 + sha256 校验、零修改**，能证"没改"，
  **不能证"可以发"**。

三条可选路径与建议 → **[PROROOT-许可与分发决策.md](PROROOT-许可与分发决策.md)**

在决策落地前：**本地自用/真机冒烟测试可继续装，不要对外分发。**
