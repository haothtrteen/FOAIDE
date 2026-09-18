import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 精确复刻 code_editor.dart 的手势配置，验证**单指上下滑动**会不会改字号。
///
/// 背景（用户 2026-09-18 报告）：
///   「刚刚的代码编辑器其实是上下划可以放大缩小，左右不可以，
///     和几根手指没关系好像。」
///
/// 第一轮探测（editor_gesture_probe_test.dart）已确认：
///   - 单指垂直拖 → onScaleUpdate 触发，pointerCount=1，scale=1.0
///   - 单指水平拖 → onScaleUpdate 不触发（被内层横向滚动容器抢走）
///
/// 本测试进一步回答：在 code_editor.dart 的**实际判定条件**下
/// （`!_scaleActive || pointerCount < 2` 提前 return），单指垂直拖
/// 到底会不会真的改变字号？如果不会，那用户观察到的必是另一条路径。
void main() {
  /// 与 code_editor.dart 同构的缩放宿主。
  Widget buildHost({
    required double initialFont,
    required void Function(double) onFontChanged,
    required List<String> log,
  }) {
    var fontSize = initialFont;
    var scaleBase = initialFont;
    var scaleActive = false;

    return StatefulBuilder(
      builder: (context, setState) {
        return MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 300,
                child: GestureDetector(
                  // ---- 与 code_editor.dart 逐行同构 ----
                  onScaleStart: (d) {
                    log.add('start pc=${d.pointerCount}');
                    if (d.pointerCount >= 2) {
                      scaleBase = fontSize;
                      scaleActive = true;
                      log.add('  -> active=true base=$scaleBase');
                    }
                  },
                  onScaleUpdate: (d) {
                    log.add('update pc=${d.pointerCount} '
                        'scale=${d.scale.toStringAsFixed(3)} '
                        'active=$scaleActive');
                    if (!scaleActive || d.pointerCount < 2) return;
                    final v = (scaleBase * d.scale).clamp(9.0, 28.0);
                    if ((v - fontSize).abs() >= 0.5) {
                      setState(() => fontSize = v);
                      onFontChanged(fontSize);
                      log.add('  -> FONT CHANGED to $fontSize');
                    }
                  },
                  onScaleEnd: (_) {
                    log.add('end');
                    if (scaleActive) {
                      scaleActive = false;
                      log.add('  -> active=false (saved)');
                    }
                  },
                  child: Container(
                    color: Colors.black,
                    child: Text('code here',
                        style: TextStyle(fontSize: fontSize)),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  testWidgets('单指垂直滑动是否改字号（逐行同构 code_editor）', (tester) async {
    final log = <String>[];
    final changes = <double>[];

    await tester.pumpWidget(buildHost(
      initialFont: 14.0,
      onFontChanged: changes.add,
      log: log,
    ));

    final c = tester.getCenter(find.byType(SizedBox).first);
    final g = await tester.startGesture(c);
    for (var i = 1; i <= 8; i++) {
      await g.moveBy(const Offset(0, 25)); // 纯垂直
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();

    debugPrint('=== 单指垂直滑动（同构实现）===');
    for (final l in log) {
      debugPrint('  $l');
    }
    debugPrint('字号变化次数 = ${changes.length}, 值=$changes');
    debugPrint('结论：单指垂直滑动改字号 = ${changes.isNotEmpty}');
  });

  testWidgets('连续两次：先双指激活后单指抬起，会不会脏状态残留', (tester) async {
    final log = <String>[];
    final changes = <double>[];

    await tester.pumpWidget(buildHost(
      initialFont: 14.0,
      onFontChanged: changes.add,
      log: log,
    ));

    final c = tester.getCenter(find.byType(SizedBox).first);

    // 先双指捏合放大
    final p1 = await tester.startGesture(c + const Offset(-30, 0));
    final p2 = await tester.startGesture(c + const Offset(30, 0));
    await tester.pump();
    for (var i = 1; i <= 5; i++) {
      await p1.moveBy(const Offset(-10, 0));
      await p2.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // **先抬一根手指**（此时 scaleActive 仍为 true）
    await p1.up();
    await tester.pump(const Duration(milliseconds: 16));
    log.add('--- 已抬一根手指，剩余单指继续垂直移动 ---');
    // 剩余那根手指改成垂直移动
    for (var i = 1; i <= 6; i++) {
      await p2.moveBy(const Offset(0, 25));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await p2.up();
    await tester.pumpAndSettle();

    debugPrint('=== 双指→抬一指→单指垂直 ===');
    for (final l in log) {
      debugPrint('  $l');
    }
    debugPrint('字号变化次数 = ${changes.length}, 值=$changes');
  });
}
