# AVF 集成可行性评估（针对 fv.zip 脚本）

> ⏸ **本路线已暂停（2026-09-17 当天）**：实测目标设备用不了 AVF
> （未开放非受保护 VM 入口），继续投入没有意义。
> 提速方向改为「原生 arm64」——把构建链里的宿主二进制逐个换成 aarch64，
> 减少 QEMU 转译层。详见 `dev-handbook/07-构建后端与原生化.md`。
>
> 本文保留作技术档案：AVF 的能力边界、protected/non-protected VM 这道真门槛、
> 以及 adb shell 权限模型的分析仍然成立，将来设备支持时可直接在本文基础上重启。
>
> ⚠️ 文中第六节之二提到的 adb/Kadb 实现已于同日整体移除（原因见
> `dev-handbook/05-许可证合规.md` 的「历史案例」：它拖进一个 GPL-3.0 的传递依赖
> spake2-java，是闭源商业化的唯一真阻塞点）。

> 日期：2026-09-17 ｜ 结论：**方向有价值，但你上传的 `fv.zip` 里没有任何 AVF 逻辑**——
> 它是"Termux 内无线 adb 自配对"脚本，与 AVF 虚拟机无关。
> 在 FOA 里集成 AVF 需要先解决三个前置问题，其中一个是硬约束。

---

## 一、先厘清：`fv.zip` 实际是什么

四个文件解包后逐行读完：

| 文件 | 大小 | 实际职责 |
|---|---|---|
| `adb-arm64` | 5.1MB | Termux 版 adb（[rendiix/termux-adb-fastboot](https://github.com/rendiix/termux-adb-fastboot)） |
| `main.sh` | 11.0KB | 配对 + **端口扫描** + 连接 + 持久化，交互式 |
| `start.sh` | 2.0KB | 精简版配对 + shell |
| `qwq.sh` | 1.7KB | `start.sh` 的更早版本 |

**脚本做的事**（`main.sh` 逐段核实）：

1. 下载/复用 `adb-arm64`；
2. `scan_ports()` 读 `/proc/net/tcp` + `/proc/net/tcp6`，筛 `st = 0A`（LISTEN）、排除 5037 和特权端口（`main.sh:63-95`）；
3. `adb pair 127.0.0.1:$PAIR_PORT` 输配对码（三种输入方式：手动端口 / 按序号选 / 自动遍历）；
4. `adb connect 127.0.0.1:5555`（`main.sh:281-288`）；
5. `settings put global adb_enabled 1` + `service.adb.tcp.port 5555`（`main.sh:297-298`）；
6. `adb shell`。

**关键核查**：全文搜 `avf|virt|crosvm|pvm|vm_shell|linux_terminal` → **零命中**。
脚本不创建 VM、不启动 VM、不连接 VM。它只是把 Termux 变成一台"能自连本机 adb 的机器"。

所以你说的"用 adb shell 调用 vm"——**这套脚本没有这个能力**，它给的是 `adb shell` 到**宿主 Android**（自己），
不是到 AVF 里的 Linux。要进 AVF 虚拟机，需要的是完全不同的路径（见 §三）。

---

## 二、但 `fv.zip` 有一个意外的好消息

我按手册 Bug 210/211 的教训做了 `readelf -d` 依赖核查（**这是本项目处理第三方二进制的必做步骤**）：

```bash
$ readelf -d adb-arm64 | grep -E "NEEDED|RUNPATH"
RUNPATH: [/data/data/com.termux/files/usr/lib]
NEEDED:  libm.so, libdl.so, libc.so      ← 只有 bionic 三件套
```

对比 Bug 210 里 proot 的处境（需要 Termux 专有的 `libtalloc.so.2` + `libandroid-shmem.so`，
系统目录没有、必须随 APK 分发），**`adb-arm64` 反而干净得多**：

| | proot | adb-arm64 |
|---|---|---|
| `DT_NEEDED` | libc + **libtalloc.so.2** + **libandroid-shmem.so** | libc + libm + libdl |
| 这些库在 Android 系统里？ | ❌ 都没有 | ✅ 都有 |
| 需要随 APK 分发专有库？ | ✅ 需要（已在做） | ❌ 不需要 |
| 硬编码 Termux 路径 | `/usr/tmp`（Bug 211，用 `PROOT_TMP_DIR` 修） | `/usr/lib`（RUNPATH）、`/usr/bin/bash`（仅 `adb shell` 交互用） |

**结论：`adb-arm64` 在 FOA 里能跑。** 因为它是 **bionic 链接的 Android 程序**，不是 glibc 程序——
正好绕开了你引文里说的"box64 库转发失效"那类问题（那说的是 x64 静态二进制，不是这个）。

而且 FOA 已有分发 + 执行 arm64 bionic 二进制的成熟机制：
`ensureProotRuntime()`（`MainActivity.kt:437`）把 assets 拷到 `filesDir/tools/`，
再用 `LD_LIBRARY_PATH` 注入。**加一个 adb 复用同一条管道。**

> 唯一的坑：`adb shell` 的交互式 shell 会去找 `/data/data/com.termux/files/usr/bin/bash`（`strings` 确认）。
> 但**非交互式 `adb shell <cmd>` 不依赖它**，所以"用 adb 执行命令"这条路是通的，
> "用 adb 打开交互式登录 shell"这条不通（也不必要）。

---

## 三、真正的拦路虎：AVF 的 VM 从哪来

这才是问题的核心。AVF（Android Virtualization Framework）不是"装个东西就有了"，它有**硬前置**：

### 3.1 硬件与系统要求

| 要求 | 说明 |
|---|---|
| Android 13+ | AVF 自 Android 13 引入 |
| **设备支持 pKVM** | 需要 SoC 层面支持（Pixel 6+、部分骁龙 8 Gen 1+）。**不是所有 Android 13 设备都有** |
| 厂商开放「Linux 开发环境」入口 | 目前主要是 **Pixel 系列**在开发者选项里可见 |
| 通常需要 16KB 页 + 较新内核 | 各家 ROM 差异大 |

你的引文里也写了："**如果你的设备支持**"——这个前提不能跳过。

### 3.2 从 App 里能控制 AVF 吗？——**基本不能**

这是最关键的技术结论：

**AVF 的 VM 由系统组件 `virtmgr` / `VirtualizationService` 管理，是特权系统服务。**
普通 App（包括 FOA，运行在 `untrusted_app` 域、`targetSdk 28`）**没有任何公开 API 去创建或启动 AVF 虚拟机**。

即使 `fv.zip` 的 adb 配对成功了，`adb shell` 进去也是**宿主 Android 的 shell**（自己），
在那里你也**没有权限**去拉起 `virtmgr` 的 VM——那是 shell/root 级别的操作。

所以"**在 app 里加无限调试配对，然后用 adb shell 调用 vm**"这条链路，在中间就断了：
`App → adb(自己) → adb shell(宿主) → ??? → AVF VM` —— 最后一步的 `???` 不存在。

### 3.3 用户侧的实际操作路径（无法被 App 自动化）

AVF 的正确使用方式是**用户手动进 VM**：

```
设置 → 开发者选项 → Linux 开发环境 → 启用
        ↓ 系统下载并启动 Debian VM（真 Linux 内核，pKVM）
   「终端」App（com.android.virtualization.terminal）里操作
        ↓ 在 VM 内的 Debian 里
   apt install flutter ... 然后 flutter build apk
```

注意最后一步：**VM 里的构建产物是 Android APK，但 VM 自己就是个 Linux 环境**，
它构建 APK 之后再 `adb install` 到宿主。

**这条链路 App 帮不上忙的关键点**：VM 内的 Flutter 环境得在 VM 里装，
而 VM 的文件系统跟 FOA 的 rootfs 是两个完全隔离的世界。

---

## 四、那集成到 FOA 里，做什么才有意义

不是"用 adb 驱动 VM 构建"（做不到），而是**做检测、引导、桥接**。

### 4.1 有意义的集成（推荐）

| 功能 | 可行性 | 价值 | 状态 |
|---|---|---|---|
| **能力检测**：读 `ro.boot.hypervisor.*` / 检查 `com.android.virtualization.terminal` 是否安装 | ✅ 高 | 告诉用户"你的设备支持 AVF"，避免瞎折腾 | ✅ **已实现** |
| **引导页**：如果支持，给出"启用 Linux 开发环境 → 装 Flutter → 回填路径"的图文步骤 | ✅ 高 | 把用户引导到真正能跑通的路上 | ✅ **已实现**（AVF 卡片） |
| **adb 自调试配对**（复用 `fv.zip`） | ✅ 高（见 §二） | 用于**安装构建产物**、读 logcat、调试目标 App——这是 adb 的真实用途 | ⏸ 待实施 |
| **VM 产物回填**：指导用户在 VM 里构建后，用 adb 或共享目录把 APK 拿回 FOA 安装 | ✅ 中 | 打通最后一公里 | ⏸ 待实施 |

**已落地的实现**（2026-09-17）：

- `MainActivity.kt` 新增 `avfCapability()`：只读探测，三重判据（API≥33 / 虚拟化终端 App / `/proc/version` 中的 pKVM 标识）；
- `EnvInfo` 新增 `avfSupported` / `avfTerminalInstalled` / `avfReason` 三个字段；
- 工具链页新增 `_AvfCard`：显示"支持 / 部分可用 / 不支持"三态，并明确写出
  **"App 不能代为驱动 VM"** 的说明和用户手动操作路径。

> 设计上刻意把这句限制写进 UI 文案，而不是留给文档——否则用户会以为
> "检测到支持"就等于"App 能自动用"，反而制造了新的预期落差。

### 4.2 你上传脚本的真实用途（这个值得做）

`fv.zip` 的端口扫描逻辑（`main.sh:49-127`）其实解决了一个真问题：
**Android 11+ 的无线调试配对端口是随机的**，用户得手动去界面看，而脚本能从 `/proc/net/tcp` 自动扫出来。

这个能力放在 FOA 里非常合适：

```
FOA 内置 adb（复用 fv.zip 的 adb-arm64 + 端口扫描逻辑）
  → 「设备调试」页：一键配对 → 连接 → 安装 APK / 看 logcat / 执行 shell
```

**注意**：这跟"构建"是两件事。adb 是用来**把 FOA 构建出的 APK 装到别的设备/自己身上**并调试的，
**不是用来构建的**。

### 4.3 不建议做的

| 想法 | 为什么不做 |
|---|---|
| 用 adb shell 驱动 AVF VM 构建 | §3.2 已证：无 API、无权限，链路断裂 |
| 让 FOA 自动创建/管理 AVF VM | 需要特权系统服务权限，普通 App 不可能 |
| 把 AVF 当作"绕过 targetSdk 28 的方案" | AVF 里的构建在 VM 内完成，跟 FOA 的 rootfs/qemu 栈毫无关系，是**替代路径**而非**补丁** |

---

## 五、三条路的对比与建议

结合你引文里的路 1/2/3，加上 FOA 的现状：

| 方案 | 与 FOA 关系 | 实际速度 | 用户门槛 | 建议 |
|---|---|---|---|---|
| **FOA 现状**（proot + qemu） | — | 构建 923s | 零（App 内全自动） | ✅ **保留为默认** |
| **路 1 ImL1s Termux SDK** | 可与 FOA 的 Termux 生态融合 | 快（全原生 aarch64） | 中（需 Termux，669MB） | ✅ 值得做**可选后端** |
| **路 2 GitHub Actions** | 完全独立 | 中（受网络） | 低 | ✅ 已建议过 |
| **路 3 AVF** | **无关**（VM 内自成一世界） | 最快（真 Linux 内核） | **高**（设备限制 + 手动装环境） | ⚠️ **仅做检测与引导** |
| **box64 替换 qemu** | 改动 FOA 内部 | 改善约 20% | 零 | ❌ 不划算（见另文） |

### 关于路 1，我要补一句

你引文说 ImL1s/termux-flutter-wsl 提供"aarch64 原生的 Flutter Engine + Dart runtime + host tools"。
**如果这是真的（engine 与 gen_snapshot 均为 aarch64 原生），它比 AVF 更值得做**，因为：

- 不需要特殊设备（只要 Termux）；
- 不需要 pKVM；
- 直接消掉 FOA 当前最大的性能负担（qemu 层），而且**架构不用大改**——
  只要 Flutter SDK 换成原生 aarch64，`qemu_compat.dart` 整层都可以不启用。

**但必须验证一个关键点**：路 1 的 `gen_snapshot` 到底是不是**真 aarch64 原生**。
你的引文里"Flutter Engine、Dart runtime、host tools 全部是 aarch64 原生"这个说法**与 Flutter 官方现状矛盾**——
官方明确 aarch64 宿主不支持 AOT（这正是 FOA 做 qemu 层的根因，也是你上一个问题里自己确认过的）。
两种可能：
1. 该仓库**自己打了补丁**，从源码编译出了 aarch64 宿主工具（理论可能，但工作量很大）；
2. 该仓库其实**仍用 x64 gen_snapshot + 某种模拟**（只是打包在一起，用户看不见）。

⚠️ **补充核查（2026-09-17）**：我尝试访问 `github.com/ImL1s/termux-flutter-wsl` 以及
其 `install_flutter_complete.sh` 原始文件，**均返回 404**（本沙箱对 github.com 的直连被 TLS 阻断，
经镜像确认该路径下无内容）。
这意味着**该仓库可能已删除、改名或从未以该名称公开存在**。

> 引文里那句 `curl -L https://raw.githubusercontent.com/ImL1s/termux-flutter-wsl/master/install_flutter_complete.sh`
> 在动手之前**请先在真机上试跑一次**——如果 404，整条路 1 就不成立。
> 我不能替你确认，因为沙箱访问不了 GitHub。**这类"社区方案"的可信度必须用 200/404 先钉死，再谈架构。**

如果仓库确实存在，验证方法（真机上跑）：

```bash
# 装完后确认关键二进制到底是哪个架构 —— 这一步决定路 1 是真是假
file $(find ~/flutter -name gen_snapshot | head -1)
file ~/flutter/bin/cache/dart-sdk/bin/dart
# 期望：ELF 64-bit LSB ... ARM aarch64
# 若显示 x86-64 → 该方案内部仍在模拟，收益不成立
```

**这一步是本项目所有"换 SDK"提议的第一道门禁**（与手册 Bug 210 的 `readelf -d` 同性质：
处理第三方二进制的必做核查）。架构不对，后面全白搭。

---

## 五之二、方案订正（2026-09-17，用户反馈后）

用户指出两点，经核实**均成立**，此前的结论需要订正。

### 订正 1：`adb shell` 确实具备系统 shell 权限

`adb shell` 的身份是 **uid 2000（shell）**，其权限来自伪系统 App `com.android.shell`
——**包含若干签名级权限**（普通 App 拿不到的那些）。这意味着：

```bash
adb shell pm grant dev.foa.flutter_on_android android.permission.MANAGE_VIRTUAL_MACHINE
adb shell pm grant dev.foa.flutter_on_android android.permission.USE_CUSTOM_VIRTUAL_MACHINE
```

**`pm grant` 不需要 root**。这正是「App 自己申请不到 VM 权限，但能通过无线调试自授权」的机制。

产品级佐证：**Podroid**（extv.github.io/Podroid）就是这么做的——它要求用户先在电脑上
跑两条 `adb shell pm grant`，之后 App 就能直接开 VM。而 FOA 的方案更优：
**用内置 adb 自己给自己授权，用户零操作**。

### 订正 2：`vm` 命令本身可用，且官方示例不带 `su`

AOSP 官方文档 `packages/modules/Virtualization/docs/custom_vm.md`：

```bash
adb shell "/apex/com.android.virt/bin/vm run /data/local/tmp/vm_config.json"
```

注意这条**没有** `su root`。同一文档里只有 `pm grant` / `pm enable` 那几步用了 `su`。
所以我此前说的「必须 root」是错的。

### 订正 3：原判据不准，官方判据是这个

我第一版代码用「API≥33 + 查终端 App + 读 `/proc/version`」，**不够准**。
Podroid 用的是官方判据：

```bash
adb shell pm list features | grep virtualization_framework
# 有 android.software.virtualization_framework → 支持
```

而**最狠的一道门禁**是 `protected` vs `non-protected` VM：

> Qualcomm exposes only "protected" VMs at EL2, but the Terminal app requires **non-protected** VMs.
> Snapdragon phones are not supported on stock firmware.

我们自制/第三方的 Debian 镜像不满足 `protected` VM 的签名与测量要求，
**只支持 protected 的芯片直接出局**——这解释了为什么大量骁龙机型"有虚拟化但用不了"。
实测支持名单（Podroid）：Pixel 8 / 8a / 9 / 9 Pro / 9 Pro XL / 10 系列。

### 订正 4：adb 该怎么做——用进程内客户端，不要 exec 二进制

原方案（fv.zip / Termux 容器内跑 adb）绕远了。正确做法：

| 方案 | 评价 |
|---|---|
| rootfs 内 apt 装 adb，proot 内 exec | ❌ 依赖 proot、要处理 Termux 库依赖（Bug 210/211），且受 W^X 约束 |
| 打包 `adb` 二进制→ filesDir → 直接 exec（不经 proot） | ⚠️ 可行（targetSdk 28 允许 execve），但仍要处理子进程与输出解析 |
| **纯 Kotlin adb 客户端库（Kadb）** | ✅ **推荐**：无二进制、无 execve、**不受 W^X 约束**、进程内直连 adbd |

**关键洞察：库调用不是 execve，因此这条能力不依赖 `targetSdk 28`。**
也就是说 FOA 的 adb/AVF 能力可以完全脱离 W^X 这个历史包袱。

已核实（下载 AAR 后 `javap` 实读，非猜 API）：

```
com.flyfishxu.kadb.Kadb.Companion.pair(String, int, String, String, Continuation)
com.flyfishxu.kadb.Kadb.Companion.create(String, int, int, int, KadbOptions)
com.flyfishxu.kadb.Kadb.shell(String) -> AdbShellResponse{output,errorOutput,exitCode,allOutput}
```

许可证 **Apache-2.0**（已实读 LICENSE 文件），与 FOA 的 AGPL-3.0 兼容，
且 Kadb 2.1.3 在 FOA 自己的阿里云镜像上 HTTP 200 可直接解析。
已按项目规矩登记到 `dev-handbook/05-许可证合规.md`。

### 订正后的完整链路

```
用户：系统「无线调试」→「使用配对码配对设备」→ 拿到 6 位码 + 配对端口
FOA：AdbWireless.pair(127.0.0.1, 配对端口, 码)      ← 进程内 SPAKE2+
     → connect(127.0.0.1, 5555)
     → shell("pm grant <FOA> MANAGE_VIRTUAL_MACHINE")
     → shell("pm grant <FOA> USE_CUSTOM_VIRTUAL_MACHINE")
  （此后 App 获权，可自行驱动 VirtualizationService 开 VM）
```

**仍待补的两块**（本次未做）：
1. **mDNS 自动发现配对端口**（`_adb-tls-pairing._tcp`，Kadb 有可选 `kadb-mdns` 模块）——
   补上后用户连端口号都不用看，只填 6 位码；
2. **VirtualizationService 客户端接入**——拿到权限后真正开 VM 的那一步。

## 六、结论与建议

| 问题 | 回答 |
|---|---|
| `fv.zip` 是 AVF 方案吗？ | ❌ **不是**。它是 Termux 无线 adb 自配对脚本，零 AVF 逻辑 |
| `fv.zip` 能直接用在 FOA 里吗？ | ✅ **能，但要换个用途**。`adb-arm64` 依赖干净（只需 bionic 三件套），FOA 已有分发执行机制；端口扫描逻辑解决了配对端口随机的痛点。**用途是安装/调试，不是构建** |
| "adb shell 调用 vm 构建打包"可行吗？ | ⚠️ **半可行**（本节第一版判错，见 §五之二订正）。`adb shell` 确实能调 `/apex/com.android.virt/bin/vm`，且能 `pm grant` 给 FOA 授权——**但**：① adb shell 起的是 shell 自己的 VM，FOA 拿不到控制台/stdio，无法自动化构建；② 正确路径是「无线调试自授权 → FOA 自己通过 VirtualizationService 开 VM」，这一步**尚未实现**；③ 真正门槛是 **non-protected VM**，多数骁龙机型只暴露 protected VM，直接出局 |
| AVF 值不值得集成？ | ⚠️ **只值得做检测 + 引导**。设备门槛高（需 pKVM + 厂商开放入口），且与 FOA 架构无关 |
| 最该做的是什么？ | **① 验证路 1 的 `gen_snapshot` 是否真 aarch64 原生**（若真是，收益远超 AVF）；**② 把 adb 调试能力做成 FOA 的「设备调试」页**（复用 fv.zip）；**③ AVF 做成能力检测 + 引导卡片** |

> 一句话：**`fv.zip` 是个好的 adb 工具，但被当成 AVF 方案了；AVF 是个好的平台能力，但没有 App 集成点。两者应该分开看待。**

## 六之二、实际落地（2026-09-17）

按你的提议——**把 adb 做成 App 原生层的能力，不在 proot 容器内执行命令**——已实现并编译通过。

### 你的判断是对的，而且比你想的更彻底

| 你的判断 | 验证结果 |
|---|---|
| adb 可以做成库封进 APK | ✅ 用 Kotlin adb 客户端 **Kadb**（Apache-2.0），dex 进 APK，**没有 adb 二进制** |
| 配对/启动调试逻辑写在原生+Flutter 层 | ✅ `AdbWireless.kt`（Kotlin）+ `adb_bridge.dart`（MethodChannel）+ `adb_page.dart`（UI） |
| 完全不需要在 proot 容器内执行命令 | ✅ 进程内直接实现 adb 协议（CNXN/AUTH/OPEN/WRTE）连本机 adbd，**零 execve** |
| 顺带的收益 | 🎁 **不受 W^X 约束**——库调用不是 `execve`，所以这条能力**不依赖 targetSdk=28，也不依赖 rootfs 是否装好** |

### 为什么叫 Kadb 而不是 `libadb.so`

真要打包 `libadb.so`（如 `libadb-android` 的 native 版）就得带上 OpenSSL/BoringSSL 的 .so 与 JNI 胶水，
体积和风险都更大；而 Kadb 是**纯 Kotlin 的 AAR**，无 native、无二进制，
正好是"把 adb 做成库"这个诉求的最轻实现。命名不重要，形态才重要：**没有要 exec 的东西**。

### 已落地文件

| 文件 | 作用 |
|---|---|
| `app/android/.../AdbWireless.kt` | 进程内 adb 客户端封装：pair / connect / shell / grantVmPermissions / install / avfFeatureCheck |
| `app/android/.../MainActivity.kt` | 新增 7 个 MethodChannel 方法 `adbPair`…`adbClose`，并给 adb 单独开线程池 |
| `app/lib/env/adb_bridge.dart` | Dart 侧桥接 |
| `app/lib/toolchain/adb_page.dart` | 「无线调试 / ADB」页面（已从配置页入口进入） |
| `app/lib/ui/home_page.dart` | 配置页新增「无线调试 / ADB」入口 |
| `app/tools/vendor_kadb.sh` | 把 Kadb AAR + spake2-java jar 落地到 `android/libs/` |
| `app/THIRD-PARTY-NOTICES.md` | 新增 Java/Kotlin 依赖整表（含 GPL-3.0 警示） |

### 顺手修掉的两个坑

1. **单线程 executor 会堵死 adb**：所有 MethodChannel 调用原本共用一个
   `Executors.newSingleThreadExecutor()`，构建（`execStream`，分钟级）一跑，
   点「检测 AVF」会一直排队到构建结束。已给 adb 独立线程池 `foa-adb`。
2. **`pm grant` 会静默失败**：`pm` 对部分失败回退出码 0，但把
   `SecurityException: Operation not allowed` 打到 stdout。只看 exitCode 会把失败报成成功。
   已改为同时检查输出文本 + 用 `dumpsys package` 复核。

### 还未做的（诚实清单）

1. **mDNS 自动发现配对端口**（`_adb-tls-pairing._tcp`）——现在用户要手填端口号；
2. **VirtualizationService 客户端**——拿到权限后真正开 VM 的那一跳，仍缺；
3. **构建产物真的在 VM 里跑**——即便开了 VM，还要把 rootfs/工具链塞进去、处理 vsock，
   且 **non-protected VM 门槛**会先筛掉绝大多数机型。

### 构建期的两个坑（记录给后来人）

- **JitPack 独占依赖**：Kadb 的传递依赖 `spake2-java` 只在 JitPack 发布。
  往 `~/.gradle/init.gradle` 的 `beforeSettings { dependencyResolutionManagement { ... } }` 加仓库
  **完全没生效**——本项目 `settings.gradle.kts` 没声明 `dependencyResolutionManagement`，
  默认 `PREFER_PROJECT` 让 `app/build.gradle.kts` 自己的 `repositories` 胜出。
  最终解法：`exclude` 掉远端解析 + 本地 vendor jar。
- **`spake2-java` 是 GPL-3.0**（不是 Apache-2.0）。AGPL 项目可用（GPLv3 §13 允许合并），
  但这意味着**本模块绝不能进任何闭源增值层**。
