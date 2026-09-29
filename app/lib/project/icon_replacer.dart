import 'dart:convert';
import 'dart:typed_data';

import '../editor/fs_bridge.dart';
import '../env/proot_bridge.dart';

/// 项目图标替换（alpha.93）。
///
/// ## 为什么是「容器侧 shell」而不是 Dart 侧处理
///
/// 两条硬约束（都是仓库既有设计，不是这里引入的）：
/// 1. **`FsBridge.read/write` 只走文本**（Kotlin 侧 `fileRead`/`fileWrite`
///    收发的是 String）——PNG 是二进制，**既读不进 Dart 也写不回容器**；
/// 2. **App 进程三方依赖归零**是仓库原则（alpha.27 移除 Kadb、alpha.31
///    不用 flutter_local_notifications 同因）——不能引 `image` 之类的包
///    在 Dart 层做缩放。
///
/// 所以缩放只能交给容器：用户在 SAF 选的图已经由 `pickImport()` 落到
/// `/root/imports/`，容器里用 `cp`（或现成的图像处理工具）写进
/// mipmap-* 即可，全程不碰二进制的跨通道传输。
///
/// ## 渐进增强：有工具就精确缩放，没有就交给系统缩放
///
/// rootfs 是 Debian **minbase**，默认没有 imagemagick / python3-PIL。
/// 为它专门 apt 装一个图像处理栈（联网 + 几十 MB + 耗时）不划算，因此：
/// - 检测到 `convert` 或 `python3 -c "import PIL"` → 按密度生成精确尺寸；
/// - 都没有 → 各密度目录放同一张原图，由 Android 系统按设备密度缩放。
///
/// 后者**可用但非最优**：原图过大则 APK 体积浪费，过小则高密度屏发虚。
/// 因此 UI 必须如实提示建议尺寸，不能假装"已经完美处理"。
class IconReplacer {
  /// mipmap 密度 → 边长（px）。与 Android 官方密度桶一致。
  static const Map<String, int> densities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  /// 建议的原图尺寸（= 最大密度桶）。用于 UI 提示与结果校验。
  static const int recommendedSize = 192;

  /// 替换项目图标。
  ///
  /// [srcGuest] 是容器内已有的图片路径（来自 `pickImport()`，
  /// 通常在 `/root/imports/`）。返回 (ok, msg)。
  static Future<({bool ok, String msg})> apply(
    ProotBridge bridge,
    String projectName,
    String srcGuest,
  ) async {
    if (srcGuest.isEmpty) {
      return (ok: false, msg: '没有选中图片');
    }

    final src = _q(srcGuest);

    // 先探测：源图是否存在 + 有没有可用的缩放工具。
    // 分开跑而不是塞进同一条脚本，是为了失败时能说清是"图没拿到"
    // 还是"工具缺失"——这两件事用户要做的动作完全不同。
    final probe = await bridge.exec(
      'if [ -f $src ]; then echo SRC_OK; else echo SRC_MISSING; fi; '
      'if command -v convert >/dev/null 2>&1; then echo TOOL_CONVERT; '
      'elif python3 -c "import PIL" >/dev/null 2>&1; then echo TOOL_PIL; '
      'else echo TOOL_NONE; fi',
      timeoutSec: 60,
    );
    final out = probe.stdout;
    if (!out.contains('SRC_OK')) {
      return (ok: false, msg: '没找到选中的图片：$srcGuest');
    }
    final tool = out.contains('TOOL_CONVERT')
        ? 'convert'
        : out.contains('TOOL_PIL')
            ? 'pil'
            : 'none';

    // ⚠️ 传给脚本的必须是**已经引号化的整段字面量**（也就是 `$src`），
    // 不能是裸的 projectName——见 [_script] 的注释，那正是之前
    // "找不到 res 目录"的成因。
    final script = buildScript(
      projectName: projectName,
      srcGuest: srcGuest,
      tool: tool,
    );

    final r = await bridge.exec(script, timeoutSec: 300);
    if (!r.ok) {
      // 脚本每段失败都会 echo "ERR=..."（并 exit 非 0），优先把这句原文
      // 透给用户——"无法创建 mipmap-hdpi" 比"写入图标失败"有用得多。
      final err = r.stdout
          .split('\n')
          .firstWhere((l) => l.startsWith('ERR='), orElse: () => '');
      final detail = err.isNotEmpty
          ? err.substring(4)
          : (r.stderr.trim().isNotEmpty ? r.stderr.trim() : '无输出');
      return (ok: false, msg: '写入图标失败：$detail');
    }

    final scaled = tool != 'none';
    final lines = r.stdout.split('\n').where((l) => l.startsWith('WROTE='));
    return (
      ok: true,
      msg: scaled
          ? '已按密度生成 ${lines.length} 个尺寸的图标'
          : '已写入 ${lines.length} 个密度目录（原图未缩放，'
              '由系统按屏幕密度缩放显示）',
    );
  }

  /// 组装替换脚本。
  ///
  /// 每段都 `|| exit N` 显式判错：图标写入失败如果静默继续，用户会在
  /// 打包后才发现图标没变，而那时已经烧掉一次完整构建（手机上二十分钟）。
  ///
  /// ## ⚠️ [srcQuoted] 传的是**已带引号的字面量**（如 `'/root/x.png'`）
  ///
  /// 这里不再对项目名二次引号化。第一版把 `projectName` 交给 `_q()` 转义后
  /// 又拼进双引号字符串里，生成的是：
  ///
  /// ```sh
  /// RES="/root/projects/'my_flutter'/android/app/src/main/res"
  /// ```
  ///
  /// —— 单引号在**双引号里是普通字符**，于是路径里真的多了两个 `'`，
  /// `-d` 判定自然失败，用户看到的就是"找不到 res 目录"（截图实测）。
  ///
  /// ## ⚠️ 源图路径只进 bash，绝不进 python -c 的源码字符串
  ///
  /// PIL 那条分支原来写成 `python3 -c "...Image.open('$src')..."`——
  /// `$src` 是带引号的字面量，插进 Python 单引号字符串会**直接语法错误**
  /// （即使用户的图片路径很干净也一样）。现在统一从环境变量读，
  /// 路径里有什么字符都不影响 Python 解析。
  static String _script(String projQuoted, String srcQuoted, String tool) {
    final dirs = densities.keys.map((d) => "mipmap-$d:${densities[d]}").join(' ');
    return '''
SRC=$srcQuoted
if [ ! -f "\$SRC" ]; then echo "ERR=源图不存在：\$SRC"; exit 9; fi
RES=$projQuoted
if [ ! -d "\$RES" ]; then echo "ERR=找不到 res 目录：\$RES"; exit 1; fi
export ICON_SRC="\$SRC"
TOOL=$tool
for pair in $dirs; do
  d=\${pair%%:*}
  sz=\${pair##*:}
  dir="\$RES/\$d"
  mkdir -p "\$dir" || { echo "ERR=无法创建 \$dir"; exit 2; }
  case "\$TOOL" in
    convert)
      convert "\$SRC" -resize \${sz}x\${sz} "\$dir/ic_launcher.png" \\
        || { echo "ERR=convert 失败于 \$d"; exit 3; }
      ;;
    pil)
      python3 -c "import os; from PIL import Image; \\
im=Image.open(os.environ['ICON_SRC']); \\
im.resize((\$sz,\$sz), Image.LANCZOS).save('\$dir/ic_launcher.png')" \\
        || { echo "ERR=PIL 失败于 \$d"; exit 4; }
      ;;
    *)
      cp "\$SRC" "\$dir/ic_launcher.png" \\
        || { echo "ERR=cp 失败于 \$d"; exit 5; }
      ;;
  esac
  echo "WROTE=\$d"
done
echo "ICON_DONE"
''';
  }

  /// 对外暴露的脚本构造（`apply` 内部用，测试与真机验证也直接用它）。
  ///
  /// 把"拼脚本"和"跑脚本"分开，是为了让脚本能在真机上被逐个验证——
  /// alpha.93 的路径 bug 就是靠把脚本打出来看才定位到的。
  static String buildScript({
    required String projectName,
    required String srcGuest,
    required String tool,
  }) =>
      _script(
        // ⚠️ 整个**完整路径**一起引号化，不能只包住前缀再拼后缀——
        // `'/a/b'/c` 只把 `/a/b` 变成了一个词，`/c` 又成了裸词。
        _q('$kProjectsRoot/$projectName/android/app/src/main/res'),
        _q(srcGuest),
        tool,
      );

  /// 把容器里某个文件读成 base64（给 UI 预览用）。
  ///
  /// 为什么要绕 base64：**FsBridge 只走文本**（返回 String），二进制直接读
  /// 会在 UTF-8 解码时炸。base64 字母表没有 shell 元字符，也避免了
  /// "PNG 里恰好有引号/换行"把命令拼坏的问题。
  ///
  /// 上限 2MB：图标是 192×192 级别的小图，超过这个数说明用户选错了文件
  /// （比如选了张 4K 大图当图标），预览里显示出来也只会拖慢页面。
  static String readBase64Script(String guestPath) => ''
      'f=${_q(guestPath)}\n'
      'if [ ! -f "\$f" ]; then echo "READ_MISSING"; exit 0; fi\n'
      'sz=\$(wc -c < "\$f" 2>/dev/null || echo 0)\n'
      'if [ "\$sz" -gt 2097152 ]; then echo "READ_TOOBIG=\$sz"; exit 0; fi\n'
      'echo "READ_OK"\n'
      'base64 -w0 "\$f" 2>/dev/null || base64 "\$f" 2>/dev/null || echo "READ_FAIL"\n';

  /// 读文件为 base64 字节。拿不到就返回 null（调用方回落默认图标）。
  static Future<Uint8List?> readAsBytes(
      ProotBridge bridge, String guestPath) async {
    if (guestPath.isEmpty) return null;
    final r = await bridge.exec(readBase64Script(guestPath), timeoutSec: 60);
    final lines = r.stdout.split('\n');
    if (lines.isEmpty || lines.first.trim() != 'READ_OK') return null;
    // base64 -w0 是一行；有的实现会折行，所以把剩下的行拼起来
    final b64 = lines.skip(1).join().replaceAll(RegExp(r'\s'), '');
    if (b64.isEmpty || b64.startsWith('READ_')) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  /// 单引号包裹（内部单引号用 '\'' 转义），防项目名/路径里的空格与元字符。
  ///
  /// 返回值**本身就是一个完整的 shell 词**，必须裸拼进脚本
  /// （`SRC='...'` / `RES='...'`），**不要再套一层双引号**——
  /// 双引号内 `'` 只是普通字符，套上去等于把单引号当成了路径的一部分
  /// （alpha.93 实测的"找不到 res 目录"就是这个）。
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";
}
