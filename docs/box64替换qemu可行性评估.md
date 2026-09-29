# box64 替换 qemu 可行性评估

> 评估日期：2026-09-17 ｜ 结论：**不建议替换**，但建议**做成可切换的双后端**，默认仍用 qemu。
> 本文所有 box64 事实均来自源码核查（commit `4e144ee`，2026-08-31），非道听途说。

---

## 一、先承认：提问的前提完全正确

用户判断的三条前提，逐条核实**全部成立**：

| 前提 | 核实结果 | 证据 |
|---|---|---|
| Flutter 官方只发 x86_64 Linux 宿主 SDK | ✅ 成立 | `bin/cache/dart-sdk/` 与 `android-*/linux-x64/gen_snapshot` 均为 ELF x86-64 |
| `flutter_tools.snapshot` 含 x64 机器码、架构相关 | ✅ 成立 | 本仓库 Bug 412 已真机复现 `Snapshot not compatible ... VM has arm64` |
| 官方明确 aarch64 宿主不可用 | ✅ 成立 | Flutter 工程文档：只有 x86-64 gen_snapshot 才能产出 aarch64 AOT 指令 |

所以"能不能换个更快的翻译器"是个**真问题**，不是伪需求。qemu-user 的解释器模式确实是本项目最大的性能瓶颈。

---

## 二、但"换成 box64 能变快"这个推论，有三个硬制约

### 制约 1：box64 的快，前提是程序本身在热循环里

box64 的性能优势（官方宣传 60–80% 原生速度）建立在 **DynaRec 能把 x86 热代码块翻译成 ARM64 原生机码**之上。

而 FOA 走模拟的这四个程序，恰好是**最不适合 DynaRec** 的一类：

| 程序 | 特征 | 为什么 DynaRec 收益低 |
|---|---|---|
| `gen_snapshot` | 一次性 AOT 编译器 | 单次运行、无热循环、翻译开销无法摊薄 |
| `dart`（flutter_tools 宿主） | 自带 x86 JIT | **自修改代码**：DynaRec 翻译的码块会被 dart 自己的 JIT 覆盖，触发频繁失效重译 |
| `aapt2` | 短命命令行工具 | 进程存活几秒，JIT 暖机时间都不够 |
| `zipalign` / `adb` | 同上 | 同上 |

> box64 自己的文档就在反复处理这类问题：`BOX64_DYNAREC_BIGBLOCK=0` 的官方注释是
> "适用于使用大量线程和 JIT 的程序（如 Unity）"，`CALLRET=2` 的注释是
> "improve call/ret optimization compatibility with **SMC code**"。
> 也就是说：**遇到 JIT/SMC 程序，box64 的第一反应是关掉激进优化来保正确性——正好把性能优势交回去。**

### 制约 2：没有官方调优表覆盖，等于用默认参数跑最难的负载

这是最硬的一条证据。box64 仓库里有一份 276 个程序的**人工逐条调优表** `system/box64.box64rc`，
覆盖 Unity、7z、DXVK、Steam 上的各种游戏——每个程序都单独调过 `BIGBLOCK` / `SAFEFLAGS` / `STRONGMEM` / `MAXCPU`。

核查结果：

```bash
$ grep -i "flutter\|gen_snapshot\|dart" system/box64.box64rc
（无输出）

$ grep -c "^\[" system/box64.box64rc
276
```

**这 276 条里，Flutter / Dart / gen_snapshot 一条都没有。**

意味着换到 box64 后，我们面对的是"一个专为游戏调优的模拟器，用默认参数跑几个它从没测过的编译器类负载"。
调参得我们自己从零摸索，而调参错了的表现是**静默产生错误结果**（SAFEFLAGS 放太松会导致内存序错误），
不是崩溃——这对"必须产出正确 APK"的构建场景是危险的失效模式。

### 制约 3：qemu 有"一次也不用"的部分，box64 换不掉也补不上

我们实测的构建总耗时 923s，其中**大头的 gradle / R8 / kotlinc / d8 根本没走模拟**——
它们是 JVM 字节码，跑在 arm64 原生 JDK 上，全速。走 qemu 的只有 4 个短命工具。

所以即使 box64 让这 4 个工具快 3 倍，**总墙钟时间的改善也被稀释得很厉害**：

```
模拟段占比估算（保守）：  aapt2 资源编译 + gen_snapshot AOT ≈ 全程 25~35%
box64 乐观提速 3×：       该段耗时 → 1/3
总耗时改善 = 1 - (0.70 + 0.30/3) ≈ 20%
```

**投入产出比**：为 20% 的收益，引入一个未验证的、无调优表、对 JIT 程序有已知兼容风险的组件，
并承担"错了不报错、错了出坏包"的风险。这笔账不划算。

---

## 三、还有一个容易被忽略的点：当前架构其实**已经是翻译器无关的**

这是我要特别指出的——用户可能低估了自己架构的灵活性。

`qemu_compat.dart` 的转发脚本核心就一行：

```sh
exec @QEMU@ -L / "$2" "$@"
```

`@QEMU@` 是 Dart 侧 `replaceAll` 注入的常量：

```dart
static const String qemuBin = '/usr/bin/qemu-x86_64-static';
```

**换 box64 不需要改架构，只需要改这一个常量和对应的 argv 形式**
（box64 不需要 `-L /`，但需要 `BOX64_LD_LIBRARY_PATH` 指向多架构库，语义一一对应）。

所以真正的问题不是"能不能换"，而是"**值不值得现在换**"。

---

## 四、建议：做成双后端 + 可开关，而不是替换

理由是这样的设计**把风险降到零**，同时保留了未来切换的可能：

### 4.1 改动范围（很小）

在 `qemu_compat.dart` 引入一个后端抽象：

```dart
/// x64 执行后端。当前 default = qemu；box64 为实验后端。
enum X64Backend { qemu, box64 }

class _BackendSpec {
  final String bin;         // /usr/bin/qemu-x86_64-static
  final String execPrefix;  // '-L /' 或 ''（box64 无 chroot 语义）
  final List<String> extraEnv; // qemu: [];  box64: [BOX64_DYNAREC_BIGBLOCK=0, ...]
  const _BackendSpec(this.bin, this.execPrefix, this.extraEnv);
}
```

转发脚本模板由固定文本改为按后端生成（`-L /` 是 qemu-user 的 sysroot 参数，box64 走 `BOX64_LD_LIBRARY_PATH`）。

### 4.2 必须配一个"等价性验证"，而不是只看跑没跑通

这是**不能省的**。核心风险是静默错误，所以要验产物而不是验退出码：

```bash
# 后端切换后，用同一份项目、同一份源码，比对 AOT 产物
sha256sum build/app/outputs/flutter-apk/app-release.apk   # 应可复现
# 更强的判据：直接比 libapp.so 的 AOT 快照（gen_snapshot 的直接产物，去掉了时间戳/签名噪声）
sha256sum build/app/intermediates/flutter/release/arm64-v8a/libapp.so
```

`libapp.so` 哈希一致 ⇒ `gen_snapshot` 在 box64 下产出的机器码与 qemu 下逐字节相同 ⇒ 补上了
"SAFEFLAGS 调太松导致内存序错误"这个静默失效风险。

### 4.3 落地顺序

1. **先量基线**：在真机上记录当前 qemu 后端的分阶段耗时（aapt2 段、AOT 段，可复用本次新增的构建进度阶段名直接打点）；
2. **只给 box64 加 UI 开关**（工具链页 → x64 兼容层 → 后端：qemu / box64（实验）），不动默认路径；
3. **跑等价性验证**：同一项目双后端各构建一次，比 `libapp.so` 哈希；
4. **只有在耗时改善 > 30% 且哈希一致**的情况下，才讨论改默认值。

---

## 五、一个更值得投入的方向（如果目标是"缩短构建时间"）

比起换模拟器，下面这几项收益更确定、风险更低：

| 方向 | 预期收益 | 风险 | 备注 |
|---|---|---|---|
| **构建缓存持久化**（`~/.gradle/caches` + `build/` 不随取消清理） | 二次构建 **-50% 以上** | 低 | 增量构建本来就该命中；首次之后收益最大 |
| **R8 / dex 已经是原生 arm64** | 已享受 | — | 确认无优化空间，别动 |
| **`aapt2` 换用 maven 版 arm64 构建** | 消掉一个模拟段 | 中 | AGP 支持 `aapt2FromMavenOverride`，可优先试点 |
| **限制 gradle worker 数**（`--max-workers=2`） | 移动端 CPU 核少，减少调度抖动 | 低 | 有时反而更快 |
| **只构建单一 ABI + 关闭冗余 lint** | 小 | 低 | 本项目已做（见 §十一 体积优化） |

其中**构建缓存持久化**是性价比最高的一项，且与 qemu/box64 之争完全无关。

---

## 六、结论

| 问题 | 回答 |
|---|---|
| 方案可不可以参考？ | **可以，而且架构上已经准备好了**（转发脚本 + 单一常量） |
| 现在该不该把 qemu 换成 box64？ | **不该**。四个硬理由：DynaRec 对 JIT/短命进程收益低；276 条官方调优表零覆盖；静默错误风险落到构建链上不可接受；模拟段只占全程 25~35%，上限收益 ~20% |
| 那怎么办？ | 抽 `X64Backend` 后端抽象 + UI 开关 + `libapp.so` 哈希等价性验证，**先把基线量出来再谈** |
| 真想提速先做什么？ | 构建缓存持久化（-50%+），而不是换模拟器 |

> 一句话：**用户的技术判断是对的，"Flutter 没有 arm64 宿主"这个根因定位也准；但 box64 解决的是"游戏跑得不够快"，而我们面对的是"编译器跑得对不对"——后者对兼容性的要求高一个量级。**
