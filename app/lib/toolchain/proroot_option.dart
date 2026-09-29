import 'package:flutter/material.dart';

import '../env/models.dart';
import '../env/proot_bridge.dart';
import '../core/theme.dart';
import '../mcp/proroot_download.dart';
import 'sdk_downloader.dart';

/// 容器层加速选项：**proroot**（alpha.61 起可真正启用）。
///
/// ## 这个选项到底是什么
///
/// proot 用 **ptrace** 拦截每一次系统调用做路径翻译，代价是**两次上下文
/// 切换**（进程↔tracer）。proroot 换成 **LD_PRELOAD + 二进制补丁**，
/// 在进程内完成翻译，零上下文切换。
///
/// ## 它**不**改善什么（必须说清，否则用户会以为是提速银弹）
///
/// FOA 构建耗时的大头是 **QEMU 指令翻译**（gen_snapshot / gradle /
/// aapt2 全是 x64 二进制，逐条指令翻译）以及 dart/gradle 自身的计算。
/// **proroot 对这两项没有任何改善**。有感的是 I/O 密集型操作
/// （apt 装包、tar 解压、海量小文件读写）。
///
/// ## 为什么默认关闭
///
/// 1. **专有许可**：可用于你的项目，但禁止分发修改过的二进制；
/// 2. **源码未公开**：无法自行审计；
/// 3. **环境不匹配**：官方要求 Ubuntu arm64（glibc），本项目用
///    Debian 12 bookworm——属**未验证组合**。
///
/// 所以流程设计成"用户自己要开 → 自己导入二进制 → 先冒烟测试再启用"，
/// 而不是给个开关默认打开，出事再让用户猜。
class ProrootOption {
  const ProrootOption._();

  /// 上游仓库（许可与二进制均在此）。
  static const String repoUrl = 'https://github.com/coderredlab/proroot';

  /// 许可**原文**（上游 LICENSE / README 的 License 节逐字照抄）。
  ///
  /// 照抄原文而非概括：这是"能不能用"的唯一依据，转述会失真。
  static const String licenseText =
      'Proprietary. Free to use in your projects. '
      'Redistribution of modified binaries is not permitted.';

  /// 官方要求的最低 Android API（26 = Android 8.0）。
  static const int minAndroidApi = 26;

  /// 仅提供该 ABI 的二进制。
  static const String abi = 'arm64-v8a';

  // ---------------- Bug 471 · glibc 版本门禁 ----------------
  //
  // 背景（真机实测，alpha.64）：5 个 .so 全部就位、sha256 全部相符、
  // 冒烟测试却失败：
  //
  //   proroot-ldso: no offset table for glibc 2.36 - patches skipped
  //   reloc: unresolved __isoc23_strtoul in .../libproroot-runtime.so
  //   proroot-ldso: failure rc=2
  //
  // 取证链（沙箱 readelf 实读，非推测）：
  //   ① v1.2.8 的 `libproroot-runtime.so` 未定义符号含
  //      `__isoc23_strtoul@GLIBC_2.38` / `__isoc23_strtoull@GLIBC_2.38` /
  //      `__isoc23_strtol@GLIBC_2.38` → 它**要求 glibc 2.38**；
  //   ② 解包 rootfs 的 `libc.so.6`，符号版本最高只到 **GLIBC_2.36**，
  //      `__isoc23_*` 家族一个都没有；
  //   ③ 上游 release note 里 **v1.2.3 明确写过**：
  //      "glibc 2.36 compat — `__isoc23_strtol@GLIBC_2.38` undefined
  //       symbol 제거" —— 即上游**曾经修好过**这个问题；
  //   ④ 但 v1.2.8（我们原来钉的版本）把修复**回退了**。实测确认：
  //      **v1.2.5 全部 5 个资产零 `__isoc23` 依赖、最高只需 GLIBC_2.34**。
  //
  // ============ 以下为**已被真机证伪**的旧推理，保留作教训 ============
  //
  // 我当时的结论是"根因不是 proroot 不能用，是版本钉错了，换 v1.2.5 即可"。
  // **错了。** 2026-09-20 真机冒烟测试（alpha.65，钉 v1.2.5）实测崩溃：
  //
  //   proroot-ldso: no offset table for glibc 2.36 — patches skipped
  //   [proroot] SIGSEGV pc=0x7e5b332638 lr=0x7e5b32a9c8 fault=0x7e5b458e34 code=2
  //   [proroot] thread_state @x26+0x710..+0x740  → 全部 (read failed)
  //   [proroot] child exited with code 139          ← 128 + 11 = SIGSEGV
  //
  // 错在哪：我当时断言"`no offset table` 只是没打补丁、通常还不到失败，
  // 真正致命的是 `reloc: unresolved`"。**这条推断是错的** —— 没打补丁本身
  // 就是致命的：linker 没按 2.36 的实际布局修正内部结构体偏移，运行时取到
  // 垃圾数据后解引用即崩。崩溃现场全是"结构体没按预期布局"的特征：
  //   · `x8 = 0x4b5e525852464852` —— 是 ASCII 数据，不是指针；
  //   · `x9 = 0x7f7f7f7f7f7f7f7f` —— 填充模式，不是地址；
  //   · TLS 那块内存（`x26+0x710..+0x740`）**根本没映射**（全部 read failed）。
  //
  // 教训（已写进 Bug 471）：**`no offset table` 与 `reloc: unresolved`
  // 是两条独立的死路，不是一条死路加一句无害警告。** 我犯的错是
  // 把"我没有观察到它致死"当成了"它不致死"——那时我只有符号表推断，
  // 没有真机运行。符号表只能证明"依赖存在"，证明不了"运行期行为"。
  //
  // ============ 真机实测后的版本交集（修正版） ============
  //
  // | 版本 | 5 资产齐全 | runtime 最高 GLIBC 需求 | 真机实测 |
  // |---|---|---|---|
  // | v1.2.3 | ❌ 无 stub-loader | 2.33 | 资产不齐，未测 |
  // | **v1.2.5** | ✅ | **2.34** | **❌ SIGSEGV（code 139）** |
  // | v1.2.6 / 1.2.7 / 1.2.8 | ✅ | 2.38（`__isoc23_*` 回归） | ❌ `reloc: unresolved` → rc=2 |
  //
  // **两个候选都不行。** 结论：当前所有可获得的 proroot 版本，
  // 对本项目的 **Debian 12（glibc 2.36）rootfs 都不可用**。
  //
  // ============ ⚠️⚠️ 2026-09-21 最终修正：以上归因**全部作废** ============
  //
  // 上面那套"DT_NEEDED 写了开发名 → 上游构建有缺陷 → 我方无解"的推理，
  // **是错的**。错在我**用错了加载器**，把 glibc 的规则套在了一个
  // Android bionic 的二进制上。参考作者自己的开源 App
  // [coderredlab/andClaw](https://github.com/coderredlab/andClaw) 后确认：
  //
  //   ── 决定性证据（自写解析器读 PT_INTERP）──
  //
  //   | 文件                       | e_type | PT_INTERP                |
  //   |----------------------------|--------|--------------------------|
  //   | **libproroot.so**          | DYN(3) | **`/system/bin/linker64`** |
  //   | libproroot-linker.so       | DYN(3) | (无，static-pie)          |
  //   | libproroot-stub-loader.so  | DYN(3) | (无，static-pie)          |
  //   | libproroot-bridge.so       | EXEC(2)| (无，静态)                |
  //   | libproroot-runtime.so      | DYN(3) | (无，LD_PRELOAD hook 库)  |
  //
  //   **`libproroot.so` 的 interpreter 是 Android 的 bionic 链接器
  //   `/system/bin/linker64`，不是 glibc 的 `ld-linux-aarch64.so.1`。**
  //
  // 所以那两条"开发名"依赖在 **Android 上是完全正确的**：
  //   · `libc.so` —— 在 bionic 下是**真实存在的运行时库**
  //     （`/system/lib64/libc.so`），**根本不是 ld script**；
  //   · `libdl.so` —— 在 bionic 下也**真实存在**（Android 的 libdl
  //     独立于 libc，与 glibc 2.34 的合并策略无关）。
  //
  // 我观察到的 `libdl.so: cannot open` / `libc.so: invalid ELF header` /
  // `version 'LIBC' not found` **全部是我自己用错加载器造出来的**，
  // 不是上游的缺陷。**证据是真的，解读是错的。**
  //
  // ＝＝＝ 作者的实际做法（andClaw 源码，非推测）＝＝＝
  //
  // 源码：`app/src/main/java/com/coderred/andclaw/proroot/ProrootManager.kt`
  //
  //   ① 五个 .so 打包进 APK 的 `jniLibs/arm64-v8a/`，安装时由 Android
  //      自动解压到 `applicationInfo.nativeLibraryDir`（第 18-19 行注释）；
  //   ② launcher **从 nativeLibraryDir 直接 exec**，不经任何 ld-linux
  //      （第 118-120 行 `nativeProrootPath`）；
  //   ③ 启动命令（第 581-592 行）：
  //        libproroot.so -r <rootfs> -b /dev:/dev -b /proc:/proc -b /sys:/sys \
  //          -b /dev/urandom:/dev/random -b <cacheDir>/shm:/dev/shm \
  //          -w /root --link2symlink /bin/sh -c <cmd>
  //      注意 `-b` 用 **host:guest** 形式，且 proroot 分支**没有 `-0`**；
  //   ④ 环境变量（第 711-717 行）——我们一个都没设：
  //        PROROOT_TMP_DIR / PROROOT_ROOTFS / PROROOT_GUEST_EXE
  //        PROROOT_LIB_PATH / PROROOT_LINKER_PATH / PROROOT_TRAMPOLINE_PATH
  //   ⑤ SELinux（第 143-149 行注释）：
  //      「nativeLibraryDir는 SELinux로 rootfs linker가 접근 불가하므로
  //        filesDir로 복사해서 LD_PRELOAD에 사용한다」
  //      → `libproroot-runtime.so` 要复制到 `filesDir`，
  //        并再放一份进 rootfs 的 `/root/.proroot/`（第 151-152 行）；
  //   ⑥ rootfs 用 **Ubuntu 24.04.3 LTS**（第 92-100 行 `BUNDLED_ROOTFS_OS_RELEASE`）。
  //
  // ＝＝＝ 我们错在哪（逐条对照）＝＝＝
  //
  //   | 我们的做法                              | 作者的做法                     |
  //   |-----------------------------------------|--------------------------------|
  //   | 用 `ld-linux-aarch64.so.1 ./libproroot.so` | 从 nativeLibraryDir 直接 exec |
  //   | 手动导入 / 放私有目录                    | 打包进 APK 的 jniLibs         |
  //   | 没设任何 PROROOT_* 环境变量              | 设了 6 个                     |
  //   | 没处理 SELinux                          | 复制到 filesDir + rootfs 内    |
  //   | `-b /dev`（proot 风格）                 | `-b /dev:/dev`（proroot 风格） |
  //   | Debian 12 rootfs                        | Ubuntu 24.04.3 LTS            |
  //
  // ＝＝＝ 结论口径 ＝＝＝
  //
  // **有解**，但解法是**一整套集成改造**，不是改几行参数。在真正跑通之前，
  // UI 仍然应该劝退（[isKnownUnusable]），但**理由要改**：不是
  // "上游有缺陷、我方无解"，而是"**我们尚未接入正确的集成方式**"。
  //
  // ⚠️ 另外，之前"钉 v1.2.5 而非 v1.2.8"的整个推理建立在错误归因上，
  //    需要用正确集成方式重新评估（v1.2.8 是最新稳定版）。
  //
  // ---------- 以下为历史记录（已被上面修正推翻，保留作教训）----------
  //
  // ============ 真机判别实验：升级 rootfs 是不是出路 ============
  //
  // 上面这张表留下一个悬而未决的问题：**既然 2.36 不行，那升到
  // Debian 13（glibc 2.41）行不行？** 2026-09-21 在真机上做了判别实验。
  //
  // 实验设计（刻意不动系统，全部在 /tmp 的隔离目录里做）：
  //   · 取 Debian 13 trixie 的 `libc6` 包解包到 `/tmp/pexp/tx/`
  //     （glibc **2.41-12+deb13u4**，arm64）；
  //   · 用 trixie 的 `ld-linux-aarch64.so.1` (2.41) 作 loader；
  //   · 用 `LD_LIBRARY_PATH` 指向一个只含软链的 shim 目录，
  //     把 `libc.so` / `libdl.so` 这两个 NEADED 名指到真实 `.so.6`；
  //   · 系统文件一个字节没改（实验后已核对：`libc.so` 时间戳不变）。
  //
  // 结果 —— **两代 glibc 报错逐字相同**：
  //
  //   glibc 2.36 (bookworm)：version `LIBC' not found (required by ./libproroot.so)
  //   glibc 2.41 (trixie)  ：version `LIBC' not found (required by ./libproroot.so)
  //
  // ⚠️ **这个实验的设计本身就是错的** —— 两代都用了错误的加载器，
  //    所以"报错相同"只能证明"错误加载器在两代 glibc 上行为一致"，
  //    **证明不了**"升级 rootfs 无效"。
  //
  // ============ （曾以为的）根因：DT_NEEDED 写了开发名 ============
  //
  // 用自写的 ELF 解析器读 `libproroot.so` 的 `.dynamic`，拿到数据：
  //
  //   | 文件                     | SONAME                   | DT_NEEDED            |
  //   |--------------------------|--------------------------|----------------------|
  //   | libproroot.so            | (无)                     | libdl.so, libc.so    |
  //   | libproroot-runtime.so    | libproroot-runtime.so    | libc.so.6            |
  //   | libproroot-linker.so     | libproroot-linker.so     | (无)                 |
  //   | libproroot-stub-loader.so| libproroot-stub-loader.so| (无)                 |
  //
  // **数据是对的，但"开发名 = 错误"这个判断是错的** —— 在 bionic 语境下
  // 这两个名字完全正确。我拿 glibc 的规则去审 Android 的二进制，
  // 把"环境不匹配"读成了"构建缺陷"。
  //
  // 至于为什么 `libproroot-linker.so` 需要「glibc 偏移表」：因为它是
  // clean-room 动态链接器，要接管 guest（glibc）程序的加载与内部补丁 ——
  // 这恰好印证了"proroot 自带链接器、不依赖系统 ld-linux"这一事实。
  //
  // ============ 历史结论（作废）============
  //
  // 曾写下："升级 rootfs 不是出路 / 根因是上游构建缺陷 / 我方无解"。
  // **三条全部作废。** 正确的表述是：我们尚未接入正确的集成方式。

  /// 本次曾钉死的上游版本（Bug 471）。
  ///
  /// ⚠️ **alpha.69 起已停用** —— 二进制不再随 APK 分发（见 [soFiles]），
  /// 本常量现在只是"我们曾钉过哪个版本"的**历史记录**，供文档溯源与
  /// 自行导入的用户参考。不要再拿它去拼下载地址。
  ///
  /// 历史结论：v1.2.5 在 Debian 12 上实测会 SIGSEGV（v1.2.8 错得更早，
  /// `reloc: unresolved` 直接 rc=2）；两者对 Debian 都不可用。
  static const String pinnedVersion = 'v1.2.5';

  /// `libproroot-runtime.so` 声明需要的**最高 glibc 符号版本**（Bug 471）。
  ///
  /// 取值依据：v1.2.5 的 runtime 实测最高 `GLIBC_2.34`
  /// （v1.2.8 会到 `GLIBC_2.38`，那是我们不接受的那个版本）。
  ///
  /// ⚠️ **满足这个下限是必要条件，不是充分条件。** 实测证明：
  /// 本机 glibc 2.36 确实 ≥ 2.34，符号依赖全部可解析，
  /// **但仍在运行期 SIGSEGV**（原因见 [linkerSupportedGlibc]）。
  static const String requiredGlibc = '2.34';

  /// `libproroot-linker.so` 内置偏移表**覆盖到的最高 glibc 版本**（Bug 471）。
  ///
  /// 超过这个版本，linker 打印 `no offset table for glibc <n>` 并跳过补丁。
  ///
  /// ⚠️ **这只是链条的第三层症状，不是根因**（2026-09-21 定案）。
  /// 根因是**我们用错了加载器**：`libproroot.so` 的 `PT_INTERP` 是
  /// `/system/bin/linker64`，它是 Android 原生 launcher，必须从
  /// `nativeLibraryDir` 直接 exec —— 我们却用 glibc 的
  /// `ld-linux-aarch64.so.1` 去加载它，于是**根本走不到 linker 补丁阶段**。
  /// `no offset table` 是更早那次崩溃（alpha.64/65）里观察到的，
  /// 当时它前面那层加载失败还没被解开。
  ///
  /// 之所以会有这个偏移表机制：proroot 自带链接器要接管后续所有库的加载，
  /// 必须调用 glibc 内部初始化（实测其导入符号表含 `__libc_init`），
  /// 而内部结构体布局每代都变，所以需要按版本打补丁。
  ///
  /// 所以本值**不可作为可用性依据**：它描述的是"假设能加载起来之后"
  /// 的下一步，而当前连第一步都过不去。
  static const String linkerSupportedGlibc = '2.36';

  /// 本项目 rootfs 的 glibc 版本（Debian 12 bookworm 实测 = 2.36）。
  ///
  /// 与 [requiredGlibc] 对照即可判定能否运行，无需真跑一次才知道。
  ///
  /// ⚠️ **这是常量快照，不是运行时探测值**。为什么这样也行：
  /// FOA 的 rootfs 是随 APK 分发的**固定那一份**
  /// （`assets/rootfs/debian-minbase-arm64.tar.gz`），用户不能替换，
  /// 所以"本机 rootfs 的 glibc 版本"在构建期就是确定的。
  /// 换 rootfs 的人必须同时改这个常量——这是**有意的摩擦**：
  /// 换 rootfs 是动摇整条构建链路的动作，不该悄悄发生。
  ///
  /// 想升级成运行时探测（在容器里读 `libc.so.6` 的符号版本）也可以，
  /// 但那要起一次容器、跑一次 `readelf`——为了一个**实验特性**的
  /// 预检多付这个代价不划算。常量 + 测试钉死已经够用
  /// （见 `bug471_proroot_glibc_test.dart` 里"把现实钉住"那条）。
  static const String rootfsGlibc = '2.36';

  /// 需要一并落位的 .so 文件名清单。
  ///
  /// ⚠️ **alpha.69 起已清空** —— 上游许可（Proprietary）明确
  /// "Redistribution of modified binaries is not permitted"，我们不代分发，
  /// 五件套**不再随 APK 打包**（`tools/verify_apk.sh` 第 4/5 项强制检查）。
  ///
  /// 这就是"方案 A"（回退手工导入）落地后的状态，详见仓库根目录的
  /// `PROROOT-许可与分发决策.md`。用户如持有合法副本，仍可通过卡片上的
  /// 「从本地导入」走 `prorootInstall` 落位到 `filesDir`，功能路径完整保留。
  ///
  /// **不要往这里加回文件名** —— `test/proroot_option_test.dart` 有一条
  /// 防复活门禁盯着它；加回来会同时打破门禁与 verify_apk 的合规检查。
  static const List<String> soFiles = <String>[];

  /// 这套二进制在**当前 rootfs** 上是否可能跑起来（Bug 471）。
  ///
  /// 判据：runtime 要求的 glibc ≤ rootfs 提供的 glibc。
  /// 相等即可——`__isoc23_*` 正是 2.38 引入的，2.36 上必然缺。
  ///
  /// ⚠️ **这是必要条件，不是充分条件 —— 而且现在连这一点都已知不成立。**
  ///
  /// 实测反例：本机 glibc 2.36 ≥ v1.2.5 要求的 2.34，本函数返回 `true`，
  /// **但真机冒烟测试直接崩溃**。原因不在 glibc —— 是**我们用了错误的
  /// 加载方式**（见 [isKnownUnusable] 与文件头部）：`libproroot.so` 的
  /// `PT_INTERP` 指向 `/system/bin/linker64`，必须从 `nativeLibraryDir`
  /// 直接 exec。本函数**完全看不到**这一层 —— 它只看符号版本，
  /// 不看加载器对不对。
  ///
  /// 所以：**不要用本函数的返回值向用户承诺"能用"**，它只能拦掉
  /// "符号依赖必然缺失"那一类（如 v1.2.8 的 `reloc: unresolved`）。
  /// 真正的门禁是冒烟测试；在冒出真机通过结论前，
  /// [isKnownUnusable] 才是对用户负责的那个判断。
  static bool isGlibcCompatible({
    String required = requiredGlibc,
    String provided = rootfsGlibc,
  }) =>
      _verNum(provided) >= _verNum(required);

  /// 版本比较用的数值化（"2.38" → 2038）。只处理 major.minor。
  static int _verNum(String v) {
    final p = v.split('.');
    if (p.length < 2) return 0;
    return (int.tryParse(p[0]) ?? 0) * 1000 + (int.tryParse(p[1]) ?? 0);
  }

  /// 不兼容时的解释文案（Bug 471）。
  ///
  /// 必须同时给出**双方版本号**与**可行出路**。历史文案是
  /// "glibc 版本不匹配、缺少 /lib64/ld-linux-aarch64.so.1" —— 后半句
  /// **是误导**：我们的 ld-linux-aarch64.so.1 好端端在
  /// `/usr/lib/aarch64-linux-gnu/` 下，缺的从来不是它。
  ///
  /// ⚠️ 本函数描述的只是"符号依赖算得过来"这一层。**这一层也不是卡点** ——
  /// 真正的卡点是集成方式（见 [knownUnusableMessage]）。
  ///
  /// ⚠️ 2026-09-21 修正：这里原来写"真正的死因是 DT_NEEDED 写了开发名"，
  /// **该归因已作废** —— 在 Android bionic 语境下 `libc.so`/`libdl.so`
  /// 都是真实存在的运行时库，上游依赖名没错（是拿 glibc 规则审错了）。
  /// 真死因是 `libproroot.so` 必须从 `nativeLibraryDir` 直接 exec。
  /// 因为不是 glibc 版本问题，所以文案里**不再提"换 rootfs"** ——
  /// 2026-09-21 实测：换 glibc 2.41 报错逐字相同。
  /// 保留本函数是因为它仍能拦掉 v1.2.8 那类 `reloc: unresolved` 的版本。
  static String glibcMismatchMessage({
    String required = requiredGlibc,
    String provided = rootfsGlibc,
  }) =>
      '这套 proroot 需要 glibc $required，而本机 rootfs 是 glibc $provided。\n\n'
      '这不是文件缺失或下载损坏——文件哈希是对的，是**二进制要求的 '
      'glibc 高于本机 rootfs**（运行时会出现 `reloc: unresolved` 后退出）。\n\n'
      '最常见的原因是上游新版把 glibc 2.36 兼容性回退了'
      '（v1.2.3 曾修过，v1.2.6 起又退回去）。出路：'
      '① 直接用「一键下载」——本 App 已钉死兼容版本 $pinnedVersion；'
      '② 手动导入时选 $pinnedVersion 的构建。\n'
      '⚠️ **不要试图靠升级 rootfs 解决**：2026-09-21 真机实测——'
      '换上 Debian 13 / glibc 2.41 后报错与现在**逐字相同**。'
      '真死因与 glibc 版本无关：`libproroot.so` 的 `PT_INTERP` 指向 '
      '`/system/bin/linker64`，它是一个 **Android 原生 launcher**，'
      '必须从 `nativeLibraryDir` **直接 exec**，而不是用 glibc 的 '
      '`ld-linux-aarch64.so.1` 去加载。'
      '本项目**不会**为了这个实验特性把 rootfs 从 $foaRootfsDistro '
      '升级——那会动摇整条已验证的构建链路，且已被证明无效。';

  /// ⚠️ **当前这套二进制是否已被真机实测证实不可用**（Bug 471 修正）。
  ///
  /// 与 [isGlibcCompatible] 的关键区别：那个是"符号依赖算得过来"，
  /// 这个是"实测跑得起来"。**两者在当前 rootfs 上结论相反** ——
  /// 符号依赖满足（2.36 ≥ 2.34），但实测连加载都过不去。
  ///
  /// 2026-09-20 alpha.65 真机冒烟失败；2026-09-21 经作者开源 App
  /// （andClaw）源码对照，查明**失败原因是我们用错了加载方式** ——
  /// `libproroot.so` 是 Android 原生 launcher（interp = `/system/bin/linker64`），
  /// 必须从 `nativeLibraryDir` 直接 exec。详见文件头部与 [knownUnusableMessage]。
  ///
  /// 在**本 App 真正接通这套集成方式并实测通过**之前，这里恒为 true，
  /// UI 据此**默认劝退**。
  ///
  /// 为什么不用 [isGlibcCompatible] 直接代替：那个判据已经被证伪过一次，
  /// 继续拿它当门禁会让用户"预检通过 → 下载 → 崩溃 → 白折腾"。
  /// 宁可保守地劝退，也不要给一个我们自己还没跑通的承诺。
  static bool isKnownUnusable() => true;

  /// 已知不可用时的说明文案（真机实测 + 作者源码对照结论）。
  ///
  /// ⚠️ 措辞几经修正，**这一版是"方案 A 落地后"的口径**：
  /// · 第 ① 版说"根因是 glibc 版本" —— 错。
  /// · 第 ② 版说"根因是 DT_NEEDED 写了开发名、上游有缺陷、我方无解" —— 错。
  ///   真相：那是 **bionic 语境下的正常依赖名**，我拿 glibc 规则审错了。
  /// · 第 ③ 版说"根因是尚未接入正确的集成方式"（列五项改造清单）—— 正确。
  /// · 第 ④ 版：**五项改造已实施，但尚未在真机上验证通过。**
  /// · 第 ⑤ 版（当前，alpha.69）：**二进制已不再随 APK 分发**（上游许可），
  ///   故不能再宣称"五个 .so 已打包进 jniLibs" —— 那是假承诺。
  ///
  /// 在真机冒烟测试通过之前，本卡片仍保持劝退：我们给不出一个自己
  /// 没验证过的承诺。
  static String knownUnusableMessage() =>
      '**该特性已按作者实现完成集成，但尚未在真机验证通过**，暂未开放。\n\n'
      '背景：`libproroot.so` 是一个 **Android 原生 launcher**'
      '（其 `PT_INTERP` 是 `/system/bin/linker64`），'
      '必须从 `nativeLibraryDir` **直接 exec**，而不是用 glibc 的 '
      '`ld-linux-aarch64.so.1` 去加载。\n\n'
      '⚠️ **本 App 不再内置该二进制。** 上游许可是 Proprietary，'
      '明确"Redistribution of modified binaries is not permitted"，'
      '所以从 alpha.69 起五件套已从 APK 移除，也不提供直链下载。'
      '如你持有合法副本，可以用卡片上的「从本地导入」让它落位。\n\n'
      '原生侧的集成改造（补 `PROROOT_*` 环境变量、runtime 库复制到 '
      '`filesDir`、`-b <host>:<guest>` 参数形式、从 `nativeLibraryDir` '
      '直接 exec）均已保留，未因移除二进制而回退 —— 参考实现见作者的 '
      '开源 App [andClaw](https://github.com/coderredlab/andClaw) '
      '的 `proroot/ProrootManager.kt`。\n\n'
      '⚠️ **rootfs 不必换** —— 官方硬条件是 glibc（非 musl），本机满足。\n\n'
      '**下一步是设备上跑一次冒烟测试**：跑通即开放本卡片；'
      '若仍失败，将以真机报错为准继续修正（不再靠推测）。';

  /// 官方声明支持的 rootfs 发行版。
  ///
  /// ⚠️ 2026-09-21 更正：**不要把它读成"非 Ubuntu 就跑不了"。**
  ///
  /// proroot 官方 README 的 Requirements 是 "Ubuntu arm64 rootfs **with
  /// glibc**" —— 真正的硬条件是 **glibc（而非 musl）**，"Ubuntu" 是作者
  /// 自己的验证环境。三条硬条件本项目**全部满足**：
  /// arm64-v8a ✓、glibc 2.36（非 musl）✓、Android 8.0+ ✓。
  ///
  /// 反证：作者在 `ProrootManager.kt:475-495` 里**主动把 rootfs 的
  /// `etc/os-release` / `usr/lib/os-release` / `etc/lsb-release` 覆写**成
  /// 硬编码的 Ubuntu 字符串，还会删掉 `etc/alpine-release`。真依赖 Ubuntu
  /// 的运行时不需要"修"这些标记 —— 需要覆写恰恰说明 **proroot 不关心
  /// 实际发行版，只关心标记文件说什么**。
  ///
  /// 作者把 Ubuntu rootfs 打包进 assets，是**产品选择**（面向普通用户
  /// 的开箱即用）而非**技术门槛**。我此前把产品配置当成了技术前提。
  ///
  /// 结论：**先做前五项集成改造，用现有 Debian 12 直接跑冒烟测试**。
  /// 跑通就完全不用换；只有实测失败且报错指向 glibc 内部结构体布局
  /// （偏移表机制）时，才需要考虑换。换 rootfs 会动摇已验证的构建链路
  /// （Bug 440 依赖 Debian 12 minbase），代价大且可能根本不必付。
  static const String requiredRootfs = 'Ubuntu arm64';

  /// 本项目实际使用的 rootfs 发行版（决定兼容性提示的措辞）。
  static const String foaRootfsDistro = 'Debian 12 bookworm';

  /// proroot 的启动器形态（与现有 proot 的 argv **不一致**）。
  ///
  /// ⚠️ **2026-09-21 修正**：这里原来写的是
  /// `libproroot.so -r <rootfs> -0 --link2symlink -w /root /bin/sh -c '…'`
  /// —— 那是照抄官方 README 的简写，**漏掉了 `-b` 绑定**，而绑定是必需的
  /// （`/dev`、`/proc`、`/sys`、`/dev/shm` 都要挂）。
  ///
  /// 正确形态照抄作者 andClaw 的 `ProrootManager.kt:581-592`：
  /// ```sh
  /// libproroot.so -r <rootfs> \
  ///   -b /dev:/dev -b /proc:/proc -b /sys:/sys \
  ///   -b /dev/urandom:/dev/random -b <cacheDir>/shm:/dev/shm \
  ///   -w /root --link2symlink /bin/sh -c '…'
  /// ```
  /// 要点：① `-b` 用 **host:guest** 形式（proot 是单个路径）；
  /// ② proroot 分支**不带 `-0`**（proot 分支才带）；
  /// ③ 必须从 `nativeLibraryDir` 直接 exec，**不要**经 `ld-linux-aarch64.so.1`。
  static const String launcherUsage =
      'libproroot.so -r <rootfs> -b /dev:/dev -b /proc:/proc -b /sys:/sys '
      '-w /root --link2symlink /bin/sh -c \'…\'';

  /// 二进制下载地址（用户自己去上游取——许可禁止我们代为分发）。
  static const String downloadHint =
      '到上方仓库的 Release / 源码树里取 $abi 构建的 5 个 .so，'
      '解压成一个目录后用下面的「导入」按钮选那个目录。';

  // ---------------- Bug 464 · 一键从 GitHub 拉取 ----------------
  //
  // 设计取舍（为什么这么实现）：
  //
  // ① **不用 GitHub API**。`api.github.com` 有匿名速率限制（每小时 60 次，
  //    按 IP 计），手机网络常是共享出口 IP，随时可能 403。改用
  //    `raw.githubusercontent.com` 直取文件——raw 域不计数、不返回元数据，
  //    够用且稳。
  //
  // ② **固定文件清单 + 逐个校验**。5 个文件的名字/大小/SHA 都写死在
  //    [soAssets] 里，不动态发现。理由：proroot 是**专有许可、源码未公开**，
  //    动态发现意味着"上游推什么就装什么"，无法审计变化。钉死版本后，
  //    上游一旦改动，校验会失败并明确报错，而不是静默装上不同内容。
  //
  // ③ **sha256 校验而非只看大小**。子集下载/半截响应都可能凑出相同大小。
  //    这里用 sha256 钉死内容（值与上游 Release 页公布的 SHA-256 逐字节
  //    核对一致，2026-09-20 实测）。
  //
  // ④ **不修改二进制**。许可原文："Redistribution of modified binaries is
  //    not permitted." —— 我们只做**按字节原样下载**，不做 strip/重打包。
  //    下载后落位到应用私有目录，不经任何改写。
  //
  // ⑤ **钉 tag 而非 main 分支（Bug 471）**。原来走 `main`，即"上游推什么
  //    我们拿什么"。main 上的 v1.2.8 把 glibc 2.36 兼容性回退了，导致
  //    下载成功、哈希正确、却跑不起来。改为钉 [pinnedVersion] 这个 tag：
  //    - 内容**冻结**，上游再改 main 也不影响我们；
  //    - 仍然满足"原样下载、不改写"的许可要求。

  /// 上游 tag（Bug 471：钉 tag 而不是 `main`，避免被上游静默换版）。
  static const String upstreamRef = pinnedVersion;

  /// 各 .so 的下载清单：文件名 / 字节数 / sha256。
  ///
  /// ⚠️ **alpha.69 起已清空**（同 [soFiles] 的理由：不代分发二进制）。
  /// `tools/fetch_assets.sh` 的 `fetch_proroot()` 会解析这个清单，
  /// 空清单让它直接报错退出 —— 这是**想要的行为**：任何试图拉取
  /// proroot 的操作都应当明确失败，而不是静默把不该分发的二进制灌回来。
  ///
  /// 历史值（v1.2.5 五件套，2026-09-20 逐一实测并与上游 Release 页
  /// SHA-256 逐字节核对一致）保留在仓库根的
  /// `PROROOT-许可与分发决策.md` 里，供将来口径变化时溯源。
  static const List<({String name, int size, String sha256})> soAssets = [];

  /// 单个资产的原始下载地址（不依赖 API）。
  static String rawUrl(String fileName) =>
      'https://raw.githubusercontent.com/coderredlab/proroot/'
      '$upstreamRef/arm64-v8a/$fileName';

  /// 下载源（国内镜像优先，raw 直链兜底）。
  ///
  /// ⚠️ alpha.69：本 App 不再提供 proroot 的下载入口（不代分发），
  /// 本方法保留仅为兼容既有调用点与测试；[soAssets] 已空，
  /// 调用方不应再依赖它取地址。
  static List<MirrorSource> mirrorsFor(String fileName) => [
        MirrorSource('ghfast',
            'https://ghfast.top/https://raw.githubusercontent.com/'
            'coderredlab/proroot/$upstreamRef/arm64-v8a/$fileName'),
        MirrorSource('gh-proxy.com',
            'https://gh-proxy.com/https://raw.githubusercontent.com/'
            'coderredlab/proroot/$upstreamRef/arm64-v8a/$fileName'),
        MirrorSource('github-raw', rawUrl(fileName)),
      ];

  /// 全部资产合计字节数（UI 显示"约 0.7MB"用）。
  ///
  /// alpha.69：清单已空 → 恒为 0。UI 不再展示这个数字。
  static int get totalBytes => soAssets.fold(0, (a, e) => a + e.size);
  /// 兼容性说明（[rootfsDistro] 为本项目的 rootfs 发行版）。
  ///
  /// 抽成纯函数便于单测：这条提示是"别盲目期待"的关键，不能写丢。
  ///
  /// ⚠️ 本条修正过三次，改前读完：
  /// · 第 ① 版："钉的版本与 2.36 是兼容的" / "版本上是够的" ——
  ///   已被 alpha.65 真机冒烟证伪。
  /// · 第 ② 版（2026-09-20）：改成"linker 的偏移表不覆盖" —— 仍是下游症状。
  /// · 第 ③ 版（2026-09-21 判别实验）：改成"DT_NEEDED 写了开发名" —— 仍错，
  ///   那是 bionic 语境下的正常依赖名。
  /// · 第 ④ 版（当前，对照 andClaw 源码后）：根因是**集成方式未接入** ——
  ///   `libproroot.so` 要从 `nativeLibraryDir` 直接 exec。
  ///
  /// ⚠️ **不要写"换 rootfs 就好了"** —— 换 rootfs 既**不是单独的解药**，
  /// 也**很可能根本不需要**（见下方更正）。写成"换个 rootfs 就行"会让
  /// 用户以为升级一下 rootfs 就能用，而实际还差 5 项集成工作。
  ///
  /// ⚠️ 2026-09-21 二次更正：**"非 Ubuntu = 未支持组合"这个措辞过重了。**
  /// 官方 Requirements 是 "Ubuntu arm64 rootfs **with glibc**"，硬条件是
  /// **glibc（非 musl）**，本项目满足。所以非 Ubuntu 应当表述为
  /// "**未在官方验证环境内，但硬条件满足**"，而不是"未支持组合"。
  static String compatNote({required String rootfsDistro}) {
    final d = rootfsDistro.trim();
    if (d.isEmpty) return '未知 rootfs 发行版，无法判断兼容性。';
    final same = d.toLowerCase().contains('ubuntu');
    if (same) return 'rootfs 为 $d，与官方验证环境一致（$requiredRootfs）。';
    // 非 Ubuntu：硬条件满足但不在官方验证环境内 —— 差别要讲准。
    if (isKnownUnusable()) {
      return '当前 rootfs 是 **$d**（glibc $rootfsGlibc）—— 与官方验证环境'
          '（$requiredRootfs）不同，但**硬条件满足**：官方 Requirements 是'
          '"Ubuntu arm64 rootfs **with glibc**"，真正的门槛是 **glibc（非 musl）**，'
          '本机满足。\n\n'
          '不过请注意：**rootfs 不是当前的卡点，也不必急着换**。'
          '真正缺的是**集成方式** ——\n'
          '`libproroot.so` 是一个 Android 原生 launcher（`PT_INTERP` 指向 '
          '`/system/bin/linker64`），必须从 `nativeLibraryDir` **直接 exec**，'
          '而不是用 glibc的 `ld-linux-aarch64.so.1` 加载。'
          '本 App 还没做到这一点，所以现在启用会失败。\n\n'
          '要接通还需要：APK 内 `jniLibs` 打包、`PROROOT_*` 环境变量、'
          'SELinux 路径处理、`-b <host>:<guest>` 参数形式。'
          '⚠️ **先做完这些，用现有 rootfs 直接跑冒烟测试** —— 跑通就不必换。'
          '详见风险清单与 `proroot-结论报告.md`。';
    }
    return '当前 rootfs 是 **$d**（glibc $rootfsGlibc），而本 App 钉的 '
        '$pinnedVersion 需要 glibc $requiredGlibc——**版本不匹配**，'
        '运行时会 `reloc: unresolved` 后退出。文件哈希是对的，'
        '是编译环境与本机 rootfs 不匹配。';
  }

  /// 这套二进制在当前 rootfs 上是否**已确认不可用**（Bug 471）。
  ///
  /// 与 [isGlibcCompatible] 同源，抽出来供 UI 直接控制"是否默认劝退"。
  /// 注意：现在钉的是 v1.2.5，正常情况下返回 **false**（可用）。
  /// 这个 getter 留着是为了"上游再回退"或"用户本地导入新版"时仍能报警。
  static bool get knownIncompatibleOnCurrentRootfs => !isGlibcCompatible();

  /// 是否值得把 proroot 当作**有效选项**呈现。
  ///
  /// 版本错配时返回 false：卡片仍然显示（用户有权知情、也便于等上游更新
  /// 后重试），但入口要明确标注"当前不可用"，不能让他下载 600KB、
  /// 导入 5 个文件、点完冒烟测试才发现是白费。
  static bool get usableOnCurrentRootfs => isGlibcCompatible();

  /// 收益边界说明（必须写在卡片上，避免用户误以为它是提速银弹）。
  static String gainNote() => 'proroot 优化的是**容器层**：用 LD_PRELOAD + '
      '二进制补丁替代 ptrace，省掉每次系统调用的两次上下文切换。'
      '但 FOA 构建慢的大头是 **QEMU 指令翻译**（gen_snapshot / gradle / '
      'aapt2 都是 x64 二进制）与 dart/gradle 自身的计算——'
      '**这两项 proroot 一点都不改善**。有感的是 I/O 密集型操作'
      '（apt 装包、tar 解压、海量小文件读写）；不要指望构建时间'
      '从 10 分钟变成 2 分钟。';

  /// 风险清单（卡片逐条渲染）。
  static const List<String> risks = <String>[
    // Bug 471 修正：**首要风险是"这条路本身走不通"**。先说结论，再说为什么。
    // 2026-09-21 对照作者开源 App（andClaw）源码后，措辞改为"未接通"。
    // alpha.69：补一句"二进制已不再内置"——否则用户会以为本 App 自带。
    '⚠️ **集成改造已完成，但尚未在真机验证通过**，因此暂未开放启用。'
        '这不是上游二进制的问题 —— `libproroot.so` 是 Android 原生 launcher'
        '（`PT_INTERP` = `/system/bin/linker64`），必须从 `nativeLibraryDir` '
        '**直接 exec**；我们此前用 glibc 的 `ld-linux-aarch64.so.1` 去加载它，'
        '方式本身是错的。现已按作者开源实现（andClaw）重做。'
        '（注：二进制已不再内置，需自行导入。）',
    // alpha.69：此处从"已实施的五项改造"改为**历史 + 现状**陈述。
    // 原措辞（"① ✅ 五个 .so 打包进 jniLibs"）在方案 A 落地后是假承诺。
    '集成方式（历史）：曾把五个 .so 打包进 `jniLibs/arm64-v8a/`、'
        '由 Android 解压到 `nativeLibraryDir` 后直接 exec。'
        '**该方案已于 alpha.69 回退** —— 上游许可禁止再分发二进制，'
        '五件套不再随 APK 打包。如你持有合法副本，可按文档手工放入 '
        '`jniLibs/arm64-v8a/`，或用本卡片的「从本地导入」落位到 `filesDir`。'
        '其余四项改造（补 `PROROOT_*` 环境变量、runtime 库复制到 `filesDir`、'
        '`-b <host>:<guest>` 参数形式）均保留在原生侧，未受影响。',
    '⚠️ rootfs **不必换**。官方 Requirements 是'
        '"Ubuntu arm64 rootfs **with glibc**" —— 真正的硬条件是 **glibc（非 musl）**，'
        '本项目 Debian 12 的 glibc 2.36 满足；且作者源码里**主动把 rootfs 的 '
        '`os-release` 覆写成 Ubuntu**，说明 proroot 不关心实际发行版。'
        '所以先用现有 Debian 12 实测；只有失败且报错指向 glibc 内部布局时才考虑换。',
    '专有许可（Proprietary）：可用于你的项目，但**禁止分发修改过的二进制**。',
    '**源码未公开**——无法自行审计，也无法自行修补，出问题只能等上游。',
    '⚠️ 但**已有一个开源的参考实现**：作者的 App '
        '[andClaw](https://github.com/coderredlab/andClaw) 把集成方式'
        '完整写在了 `proroot/ProrootManager.kt` 里，可对照实现。',
    '作者已将重心转向 proroom（proroot README 的 Notice 明确说明），'
        '本仓库的更新预期会变慢。',
    '只提供 $abi 二进制（5 个 .so），要求 Android 8.0+（API $minAndroidApi）。',
    '启动器 argv 与 proot **不一致**（`-b` 用 host:guest 形式，'
        '且 proroot 分支不带 `-0`），原生侧是独立实现路径。',
  ];
}

/// 「容器层加速（proroot）」卡片（alpha.61：从纯告知卡变成可用功能）。
///
/// 交互设计：**先装才能开**。没导入二进制时开关是禁用的，但按钮可点
/// （引导导入）；导入后可以点"冒烟测试"真跑一次；测试通过才允许打开。
/// 这个顺序不是仪式感——proroot 与 Debian rootfs 的组合没验证过，
/// 直接打开开关去构建，失败了用户只会看到一堆 gradle 报错，
/// 根本定位不到是容器层的问题。
class ProrootCard extends StatefulWidget {
  const ProrootCard({
    super.key,
    this.rootfsDistro = ProrootOption.foaRootfsDistro,
    this.enabled = false,
    this.onChanged,
  });

  /// 当前 rootfs 发行版（用于兼容性提示）。
  final String rootfsDistro;

  /// 当前是否已启用 proroot。
  final bool enabled;

  /// 开关回调（父页负责写 ContainerPrefs）。
  final ValueChanged<bool>? onChanged;

  @override
  State<ProrootCard> createState() => _ProrootCardState();
}

class _ProrootCardState extends State<ProrootCard> {
  final ProotBridge _bridge = ProotBridge();

  ProrootStatus? _status;
  bool _busy = false;
  String _note = '';
  bool _noteOk = false;
  ProrootProbeResult? _probeResult;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final s = await _bridge.prorootStatus();
      if (!mounted) return;
      setState(() {
        _status = s;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '无法查询 proroot 状态：$e';
        _noteOk = false;
      });
    }
  }

  /// ⚠️ alpha.69：**UI 已下架此入口**（上游许可禁止再分发二进制，本 App
  /// 不提供直链），故当前无调用点。保留方法体是因为它与 `ProrootDownload`
  /// 是完整可用的一条路径 —— 若将来许可口径变化，把按钮加回来即可，
  /// 无需重写。
  ///
  /// Bug 464：一键从 GitHub 拉取 5 个 .so → 自动落位 → 刷新状态。
  ///
  /// 与 [_import]（系统文件选择器）并存：选择器对"已自己下好文件"的用户
  /// 更灵活，一键下载对"什么都没准备"的用户更省事。两条路最终都汇到
  /// 原生的 `prorootInstall` 落位逻辑，行为一致。
  // ignore: unused_element
  Future<void> _download() async {
    final env = await _bridge.envInfo();
    setState(() {
      _busy = true;
      _note = '正在下载 ${ProrootOption.soAssets.length} 个文件…';
      _noteOk = true;
    });
    final logs = <String>[];
    try {
      final dl = ProrootDownload(_bridge);
      final stagingDir = await dl.fetchAll(
        env: env,
        onLog: (l) {
          logs.add(l);
          if (mounted) setState(() => _note = l);
        },
      );
      // 落位（复用原生的递归拷贝 + ELF 校验）
      setState(() => _note = '落位中…');
      final r = await _bridge.prorootInstallFromDir(stagingDir);
      if (!mounted) return;
      if (r.ok) {
        // 成功才清暂存；失败保留，便于用户/我们排查
        await dl.clearStaging(env);
      }
      setState(() {
        _busy = false;
        _noteOk = r.ok;
        _note = r.ok
            ? '已下载并导入 ${r.copied.length} 个文件，可以点「冒烟测试」验证'
            : (r.error ?? '落位未完成');
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _noteOk = false;
        _note = '一键下载失败：$e';
      });
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _note = '';
    });
    try {
      final r = await _bridge.prorootImport();
      if (!mounted) return;
      if (r == null) {
        setState(() {
          _busy = false;
          _note = '已取消导入';
          _noteOk = false;
        });
        return;
      }
      setState(() {
        _busy = false;
        _noteOk = r.ok;
        _note = r.ok
            ? '已导入 ${r.copied.length} 个文件，可以点「冒烟测试」验证'
            : (r.error ?? '导入未完成');
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '导入失败：$e';
        _noteOk = false;
      });
    }
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _probeResult = null;
      _note = '';
    });
    try {
      final r = await _bridge.prorootProbe();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _probeResult = r;
        _noteOk = r.ok;
        _note = r.ok
            ? '冒烟测试通过：proroot 可以在这个 rootfs 上工作'
            : (r.error ?? '冒烟测试未通过');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '冒烟测试失败：$e';
        _noteOk = false;
      });
    }
  }

  Future<void> _remove() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除 proroot 二进制？'),
        content: const Text(
          '会删除已导入的 5 个 .so。如果开关还开着，请先关掉。\n\n'
          '文件可以随时重新导入，不会有不可逆的损失。',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (go != true) return;
    setState(() => _busy = true);
    try {
      final n = await _bridge.prorootRemove();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _probeResult = null;
        _note = '已移除 $n 个文件';
        _noteOk = true;
      });
      // 二进制没了就不能继续开着，否则下次构建会在启动阶段报错
      if (widget.enabled) widget.onChanged?.call(false);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = '移除失败：$e';
        _noteOk = false;
      });
    }
  }

  void _toggle(bool v) {
    if (v) {
      // ⚠️ **已知不可用组合：直接拒绝开启**（Bug 471 修正）。
      //
      // 这里原来是"提醒一句但不强制"。改了的原因很直接：
      // 那时我们**只是没验证过**，允许用户"想在真构建里试"是合理的。
      // 现在我们已经**实测确认它必崩**（SIGSEGV / code 139），
      // 再放行就只是让用户把一次注定失败的构建从头跑一遍 ——
      // 浪费几十分钟，最后拿到一堆 gradle 报错，还定位不到是容器层。
      //
      // 这跟"冒烟测试没过但让用户自己决定"不是一回事：
      // 前者是未知风险，后者是**已知错误**。已知错误不该放进选项里。
      if (ProrootOption.isKnownUnusable()) {
        final extra = _probeResult?.ok == false
            ? '你的冒烟测试结果也印证了这一点。'
            : '';
        setState(() {
          _note = '暂不能开启：该特性在当前 rootfs 上已实测不可用'
              '（详见下方风险说明）。$extra';
          _noteOk = false;
        });
        return;
      }
      // 开启前先确认二进制齐了；冒烟测试没跑过的话提醒一句，
      // 但不强制——用户可能就是想在真构建里试。
      final s = _status;
      if (s == null || !s.installed) {
        setState(() {
          _note = '还没导入 proroot 二进制，先点上面的「导入」';
          _noteOk = false;
        });
        return;
      }
      if (!s.abiOk) {
        setState(() {
          _note = '设备 ABI 是 ${s.abi}，proroot 只提供 arm64-v8a';
          _noteOk = false;
        });
        return;
      }
      if (_probeResult?.ok != true) {
        setState(() {
          _note = '建议先跑一次「冒烟测试」。没测过也能开，'
              '但构建失败时无法区分是容器层还是项目本身的问题。';
          _noteOk = false;
        });
      }
    }
    widget.onChanged?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: FoaColors.of(context).muted, height: 1.45);
    final s = _status;
    final installed = s?.installed ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune_outlined, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '容器层加速（proroot）',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Chip(
                    label: Text(installed ? '已导入' : '未导入',
                        style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: installed
                        ? FoaTheme.seed.withValues(alpha: 0.15)
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // 开关：装好才可开
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('启用 proroot 替代 proot',
                  style: TextStyle(fontSize: 13)),
              subtitle: Text(
                !installed
                    ? '需要先导入 ${ProrootOption.soFiles.length} 个 .so 文件'
                    : (s?.abiOk == false
                        ? '当前设备 ABI（${s?.abi}）不支持'
                        : '构建与终端命令将走 proroot'),
                style: const TextStyle(fontSize: 11),
              ),
              value: widget.enabled,
              onChanged: (installed && (s?.abiOk ?? true)) ? _toggle : null,
            ),

            // 状态明细：缺什么、哪个不是 ELF，都要说清
            if (s != null) ...[
              _statusRow('落位目录', s.dir.isEmpty ? '—' : s.dir),
              _statusRow('已就位', '${s.present.length}/${ProrootOption.soFiles.length}'),
              if (s.missing.isNotEmpty)
                _statusRow('缺少', s.missing.join('、'), warn: true),
              if (s.notElf.isNotEmpty)
                _statusRow('非 ELF（可能损坏）', s.notElf.join('、'), warn: true),
              _statusRow('设备', '${s.abi} · API ${s.api}'
                  '${s.apiOk ? '' : '（需 ${ProrootOption.minAndroidApi}+）'}'),
            ],

            const SizedBox(height: 10),
            // 动作区（alpha.69：**三个**动作 —— 导入 / 测试 / 移除）。
            //
            // 「一键下载」已下架：上游许可禁止再分发二进制，本 App 不提供直链；
            // 且 [`ProrootDownload.fetchAll`] 因 `isKnownUnusable() == true`
            // 在发第一个网络请求前就抛异常 —— 按钮点了必然立刻失败，
            // 摆在那里只会误导。`_download()` 与 `ProrootDownload` 类保留，
            // 以备将来许可口径变化（届时只需把按钮加回来）。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.file_download_outlined, size: 16),
                  label: Text(installed ? '从本地导入' : '导入 proroot',
                      style: const TextStyle(fontSize: 12)),
                ),
                OutlinedButton.icon(
                  onPressed: (_busy || !installed) ? null : _probe,
                  icon: const Icon(Icons.science_outlined, size: 16),
                  label: const Text('冒烟测试', style: TextStyle(fontSize: 12)),
                ),
                if (installed)
                  TextButton.icon(
                    onPressed: _busy ? null : _remove,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('移除', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: FoaColors.of(context).danger,
                    ),
                  ),
              ],
            ),

            if (_note.isNotEmpty) ...[
              const SizedBox(height: 8),
              _banner(_note, _noteOk),
            ],
            if (_probeResult != null && !_probeResult!.ok && _probeResult!.output.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: FoaColors.of(context).codeBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  _probeResult!.output.trim(),
                  style: const TextStyle(
                      fontSize: 10.5, fontFamily: 'monospace', height: 1.4),
                ),
              ),
            ],

            const SizedBox(height: 10),
            Text(ProrootOption.gainNote(), style: muted),
            const SizedBox(height: 8),
            _warn(ProrootOption.compatNote(rootfsDistro: widget.rootfsDistro)),
            const SizedBox(height: 8),
            Text(ProrootOption.downloadHint, style: muted),
            const SizedBox(height: 10),
            const Text('风险与限制',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final r in ProrootOption.risks) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('· ', style: TextStyle(fontSize: 12)),
                    Expanded(child: Text(_plain(r), style: muted)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text('许可（上游原文）',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const SelectableText(
                ProrootOption.licenseText,
                style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              ),
            ),
            const SizedBox(height: 8),
            SelectableText(
              '仓库：${ProrootOption.repoUrl}\n'
              '形态：${ProrootOption.soFiles.length} 个 ${ProrootOption.abi} '
              '.so，Android ${ProrootOption.minAndroidApi}+ \n'
              '启动器：${ProrootOption.launcherUsage}',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(String k, String v, {bool warn = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(k,
                style: TextStyle(fontSize: 11, color: FoaColors.of(context).muted)),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: warn ? FoaColors.of(context).danger : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _banner(String text, bool ok) {
    // Bug 464：改用主题感知语义色（浅色主题下 warning 会压深，避免对比度不足）
    final fc = FoaColors.of(context);
    final c = ok ? fc.success : fc.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.info_outline,
              size: 15, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, height: 1.45, color: c),
            ),
          ),
        ],
      ),
    );
  }

  /// 去掉 Markdown 星号（风险条目里的加粗是给正文用的，卡片里用样式表达）。
  static String _plain(String s) => s.replaceAll('**', '');

  Widget _warn(String text) {
    // Bug 464：原先用固定的 `orange.shade50/200/800/900`——那是一套**只适合
    // 浅色背景**的橙色阶。深色主题下 shade50 是近白底、shade900 是深褐字，
    // 这块警告框会亮得刺眼且对比度失衡。改用随主题走的语义色。
    final c = FoaColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: c.warningContainer,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _plain(text),
              style: TextStyle(
                  fontSize: 11.5, height: 1.45, color: c.warning),
            ),
          ),
        ],
      ),
    );
  }
}
