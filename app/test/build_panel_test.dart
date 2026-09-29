import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foaide/toolchain/build_progress.dart';

/// 打包面板（alpha.61 优化）行为约束。
///
/// 这是一个纯源码断言文件：面板大部分逻辑要跟 BuildRunner 单例、原生桥、
/// 真实文件系统打交道，跑真流程等于集成测试（已在真机验证）。这里守的是
/// **"写代码时容易忘、忘了用户就踩坑"**的那些约束——它们的共同点是
/// 需求来自用户实际反馈，且失效时不会报错、只会静默退化。
void main() {
  final src = File('lib/project/build_panel.dart').readAsStringSync();

  group('打包面板 · 阶段清单与进度同源', () {
    test('阶段清单的数据源是 BuildStages.ordered，不是自己写一份', () {
      expect(src.contains('const list = BuildStages.ordered'), isTrue,
          reason: '阶段清单和进度条各写一份列表，迟早出现'
              '"进度条到第 5 步了清单还停在第 3 步"');
    });

    test('BuildStages.ordered 确实是非空且有序的', () {
      expect(BuildStages.ordered, isNotEmpty);
      for (final s in BuildStages.ordered) {
        expect(s.label, isNotEmpty, reason: '阶段没有可展示的文案');
      }
    });

    test('三个阶段态（已过/进行中/未到）分别有视觉区分', () {
      // 已过打勾、进行中转圈、未到灰点 —— 三者必须都能区分
      expect(src.contains('Icons.check_circle'), isTrue);
      expect(src.contains('CircularProgressIndicator'), isTrue);
      expect(src.contains('Icons.circle'), isTrue);
    });
  });

  group('打包面板 · 防重复提交有两层', () {
    test('按钮层：构建中禁用', () {
      expect(src.contains('onPressed: building ? null : _start'), isTrue,
          reason: '按钮不禁用的话用户会以为"没点到"然后狂点');
    });

    test('方法层：进入前再查一次 r.building', () {
      expect(src.contains('if (r.building) return; // 防重复提交'), isTrue,
          reason: '同一帧内快速双击可绕过按钮禁用，方法内必须兜一层');
    });

    test('清理缓存也有互斥（构建中不允许清）', () {
      expect(src.contains('_cleaning || r.building'), isTrue,
          reason: '构建中途删 build/ 会让构建以看不懂的方式失败');
    });
  });

  group('打包面板 · 前置检查先于构建', () {
    test('_start 里第一步就是 _preflight', () {
      final i = src.indexOf('Future<void> _start() async {');
      final body =
          src.substring(i, src.indexOf('Future<void> _confirmClean()'));
      final pre = body.indexOf('await _preflight()');
      // alpha.93：onStartBuild 带上构建类型（debug 档不走 AOT）
      final go = body.indexOf('widget.onStartBuild(_flavor)');
      expect(pre, greaterThanOrEqualTo(0));
      expect(go, greaterThan(pre), reason: '先检查再构建——顺序反了就失去"提前拦下"的意义');
      expect(go, greaterThanOrEqualTo(0),
          reason: '开始构建必须把构建类型传给父页，否则 BuildRunner 拿不到 flavor');
    });

    test('检查项区分 blocking 与提示项（不是所有缺项都拦人）', () {
      expect(src.contains('blocking: true'), isTrue);
      expect(src.contains('blocking: false'), isTrue);
      expect(src.contains('bool get _hasBlocking'), isTrue);
    });

    test('阻断项存在时必须让用户二次确认，不能直接拒绝', () {
      expect(src.contains('前置检查未通过'), isTrue);
      expect(src.contains('仍要继续吗？'), isTrue, reason: '检查可能是误报，必须给"我就要构建"的出路');
    });

    test('首次进入就静默检查一次（不阻塞界面）', () {
      expect(src.contains('addPostFrameCallback'), isTrue);
      expect(src.contains('_preflight(silent: true)'), isTrue);
    });

    test('检查项覆盖用户真实会缺的东西', () {
      for (final k in ['rootfs', 'pubspec.yaml', 'AndroidManifest.xml']) {
        expect(src.contains(k), isTrue, reason: '前置检查漏了 $k');
      }
      // 后端可用性 + 磁盘空间
      expect(src.contains('prefixExists'), isTrue);
      expect(src.contains('df -P -k'), isTrue,
          reason: '构建产物几百 MB，磁盘满是最常见的玄学失败原因之一');
    });
  });

  group('打包面板 · 构建参数可视化', () {
    test('参数卡展示项目/目标/后端/路径/ABI', () {
      for (final k in ['_paramRow', '项目', '目标', '后端']) {
        expect(src.contains(k), isTrue, reason: '参数卡漏了 $k');
      }
    });

    test('后端可就地切换（不用跳去工具链页）', () {
      expect(src.contains('SegmentedButton'), isTrue);
      expect(src.contains('onBackendChanged'), isTrue);
    });

    test('切换后端是空安全的（父页可能不接）', () {
      expect(src.contains('widget.onBackendChanged?.call'), isTrue);
    });
  });

  group('打包面板 · 全屏日志', () {
    test('日志用 BottomSheet 全屏看，不再只有 30 行', () {
      expect(src.contains('showModalBottomSheet'), isTrue);
      expect(src.contains('class _LogSheet'), isTrue);
      expect(src.contains('isScrollControlled: true'), isTrue,
          reason: '不设这个的话 BottomSheet 最高只有半屏');
    });

    test('BottomSheet 自己订阅刷新，不重建整个打包区', () {
      expect(src.contains('r.onUiChanged = ()'), isTrue,
          reason: '在父页渲染的话，构建中每次日志刷新都会重建整个打包区');
    });

    test('dispose 时还原 onUiChanged（否则回调指向已销毁的 State）', () {
      expect(src.contains('r.onUiChanged = null'), isTrue);
    });

    test('日志行可选中复制（用户要拿去搜）', () {
      expect(src.contains('SelectableText'), isTrue);
    });

    test('自动滚到底 + 用户上滑时停止跟随', () {
      expect(src.contains('_autoScroll'), isTrue);
      expect(src.contains('UserScrollNotification'), isTrue,
          reason: '不处理的话用户往回翻会被一直拽到底部');
      expect(src.contains('_toBottom'), isTrue);
    });

    test('提供"只看错误"过滤', () {
      expect(src.contains('_onlyErrors'), isTrue);
    });

    test('错误关键词表在两处一致（过滤与着色不能各写一份）', () {
      // _lines 的过滤词与 _logLine 的着色词必须能对上，否则
      // "只看错误"筛出来的行不带红色，或者红色行筛不出来
      const keys = ['error', 'failed', 'exception'];
      for (final k in keys) {
        expect(src.contains("contains('$k')"), isTrue, reason: '关键词 $k 缺失');
      }
    });
  });

  group('打包面板 · 失败日志要能一眼看出问题', () {
    test('错误行不只是变色，还加左侧竖条', () {
      expect(src.contains('isErr || isOk'), isTrue);
      expect(src.contains('width: 2,'), isTrue, reason: '左侧竖条');
    });

    test('成功行与警告行也各有颜色（不能只有红/白两色）', () {
      expect(src.contains('0xFFFF7A7A'), isTrue, reason: '错误红');
      expect(src.contains('0xFF3DDC84'), isTrue, reason: '成功绿');
      expect(src.contains('0xFFFFB74D'), isTrue, reason: '警告橙');
    });

    test('失败时给出可操作的修复方向，而不是只说失败', () {
      expect(src.contains('可能的修复方向'), isTrue);
      expect(src.contains('r.hints'), isTrue);
    });
  });

  group('打包面板 · 产物管理', () {
    test('产物卡展示文件名 + 容器内路径', () {
      expect(src.contains('_artifactCard'), isTrue);
      expect(src.contains('容器内路径：'), isTrue);
    });

    test('安装走 rootfsPath + 容器路径拼出的真实宿主路径', () {
      expect(src.contains("final real = '\${env.rootfsPath}\$guest';"), isTrue,
          reason: '产物在容器 /root/projects/... 下，宿主真实路径要拼 rootfsPath');
    });

    test('安装走 FileBrowserBridge（复用 FileProvider 授权），不是 FsBridge', () {
      expect(src.contains('final FileBrowserBridge _fbb'), isTrue);
      expect(src.contains('_fbb.installApk(real)'), isTrue);
    });

    test('产物路径可一键复制', () {
      expect(src.contains('Clipboard.setData'), isTrue);
      expect(src.contains('已复制产物路径'), isTrue);
    });
  });

  group('打包面板 · 清理缓存是危险操作', () {
    test('删之前必须确认，并说清代价', () {
      expect(src.contains('清理构建缓存？'), isTrue);
      expect(src.contains('下次构建会重新下载依赖'), isTrue);
      expect(src.contains('你的源码和配置不会被改动'), isTrue,
          reason: '用户最怕的是"清缓存把我代码删了"，必须明确说不会');
    });

    test('清理时按钮显示进行中（否则用户会重复点）', () {
      expect(src.contains('清理中…'), isTrue);
    });
  });

  group('打包面板 · 通知与状态', () {
    test('构建中显示专门的卡片（不是把按钮变灰了事）', () {
      expect(src.contains('_buildingCard'), isTrue);
      expect(src.contains('构建中…'), isTrue);
    });

    test('别的项目在构建时明确告知，而不是让自己一直点不动', () {
      expect(src.contains('_otherBuildingCard'), isTrue);
      expect(src.contains('r.active == widget.projectName'), isTrue);
    });

    test('通知关闭时提醒用户（退到桌面就看不到进度）', () {
      expect(src.contains('BuildNotify.enabled'), isTrue);
    });

    test('已经跑完且非 idle 时才显示结果卡', () {
      expect(
          src.contains('!r.building && mine && r.status != BuildStatus.idle'),
          isTrue);
    });

    test('rootfs 没装时给专门的空状态，不是让用户对着按钮发呆', () {
      expect(src.contains('rootfs 未初始化'), isTrue);
    });
  });

  group('打包面板 · 与父页的接线', () {
    final page = File('lib/project/project_page.dart').readAsStringSync();

    test('父页通过 _buildPanel() 委托，不再自己内联打包 UI', () {
      expect(page.contains('return BuildPanel('), isTrue);
    });

    test('父页把后端与回调都传下去了', () {
      for (final k in ['onStartBuild:', 'backend:', 'env:']) {
        expect(page.contains(k), isTrue, reason: '父页漏传 $k');
      }
    });

    test('后端切换真的会持久化（不能只改内存）', () {
      expect(page.contains('BackendPrefs.save'), isTrue);
    });
  });

  group('打包面板 · 构建过程中的状态不会自相矛盾', () {
    test('构建中不显示"开始构建"按钮组', () {
      // ⚠️ 别按"整行字符串"找：`dart format` 会把长的 collection-if 折行，
      // 断言的是**逻辑**（有个 otherBuilding 分支），不是排版。
      final m = RegExp(r'if\s*\(otherBuilding\)\s*_otherBuildingCard\(\)')
          .firstMatch(src);
      expect(m, isNotNull, reason: '找不到"别人在构建"的分支');
      final end = src.indexOf('// ---------- 别人的构建占着');
      expect(end, greaterThan(m!.start), reason: '章节锚点必须落在分支之后');
      final body = src.substring(m.start, end);
      expect(body.contains('_buildingCard()'), isTrue);
      expect(body.contains('_actionsCard()'), isTrue,
          reason: '_actionsCard 在 else 分支里，构建中不该出现');
    });
  });
}
