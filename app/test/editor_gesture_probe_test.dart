import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复现用户报告：**单指上下滑动**触发了字号缩放，左右滑动不触发。
///
/// 用户原话（2026-09-18）：
///   「刚刚的代码编辑器其实是上下划可以放大缩小，左右不可以，
///     和几根手指没关系好像。」
///
/// 本测试用最小组件复现「GestureDetector 只注册 onScale* + 内部有一个
/// 横向 SingleChildScrollView」这一结构与单指拖动的交互，判定
/// 单指垂直拖动会不会走进 onScaleUpdate。
void main() {
  testWidgets('单指垂直拖动是否会触发 onScale 回调', (tester) async {
    final log = <String>[];
    int scaleStartCount = 0;
    int scaleUpdateCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: GestureDetector(
                // 与 code_editor.dart 完全同构：只注册 onScale*
                onScaleStart: (d) {
                  scaleStartCount++;
                  log.add('scaleStart pointerCount=${d.pointerCount}');
                },
                onScaleUpdate: (d) {
                  scaleUpdateCount++;
                  log.add('scaleUpdate pointerCount=${d.pointerCount} '
                      'scale=${d.scale} focalDelta=${d.focalPointDelta}');
                },
                onScaleEnd: (_) => log.add('scaleEnd'),
                child: Container(
                  color: Colors.black,
                  // 模拟 CodeField 外层的横向滚动容器
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: 900, child: Text('x' * 200)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // ---- 单指垂直拖动 ----
    log.clear();
    scaleStartCount = 0;
    scaleUpdateCount = 0;
    final center = tester.getCenter(find.byType(SizedBox).first);
    final g = await tester.startGesture(center);
    // 关键：**单个** pointer，垂直移动
    for (var i = 1; i <= 6; i++) {
      await g.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();

    debugPrint('=== 单指垂直拖动 ===');
    debugPrint('onScaleStart 次数 = $scaleStartCount');
    debugPrint('onScaleUpdate 次数 = $scaleUpdateCount');
    for (final l in log) {
      debugPrint('  $l');
    }

    // 记录结论（不断言，先观察真实行为）
    final singleFingerVerticalTriggersScale = scaleUpdateCount > 0;
    debugPrint('结论：单指垂直拖动触发 onScaleUpdate = '
        '$singleFingerVerticalTriggersScale');
  });

  testWidgets('单指水平拖动是否会触发 onScale 回调', (tester) async {
    final log = <String>[];
    int scaleUpdateCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: GestureDetector(
                onScaleStart: (d) => log.add('scaleStart pc=${d.pointerCount}'),
                onScaleUpdate: (d) {
                  scaleUpdateCount++;
                  log.add('scaleUpdate pc=${d.pointerCount}');
                },
                child: Container(
                  color: Colors.black,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(width: 900, child: Text('x' * 200)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    log.clear();
    scaleUpdateCount = 0;
    final center = tester.getCenter(find.byType(SizedBox).first);
    final g = await tester.startGesture(center);
    for (var i = 1; i <= 6; i++) {
      await g.moveBy(const Offset(-20, 0)); // 水平移动
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();

    debugPrint('=== 单指水平拖动 ===');
    debugPrint('onScaleUpdate 次数 = $scaleUpdateCount');
    for (final l in log) {
      debugPrint('  $l');
    }
  });

  testWidgets('双指捏合是否正常触发', (tester) async {
    final log = <String>[];
    int scaleUpdateCount = 0;
    double lastScale = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: GestureDetector(
                onScaleStart: (d) => log.add('scaleStart pc=${d.pointerCount}'),
                onScaleUpdate: (d) {
                  scaleUpdateCount++;
                  lastScale = d.scale;
                  log.add('scaleUpdate pc=${d.pointerCount} '
                      'scale=${d.scale.toStringAsFixed(2)}');
                },
                child: Container(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );

    log.clear();
    scaleUpdateCount = 0;
    final c = tester.getCenter(find.byType(SizedBox).first);
    final p1 = await tester.startGesture(c + const Offset(-40, 0));
    final p2 = await tester.startGesture(c + const Offset(40, 0));
    await tester.pump();
    // 两指分开
    for (var i = 1; i <= 6; i++) {
      await p1.moveBy(const Offset(-8, 0));
      await p2.moveBy(const Offset(8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await p1.up();
    await p2.up();
    await tester.pumpAndSettle();

    debugPrint('=== 双指捏合 ===');
    debugPrint('onScaleUpdate 次数 = $scaleUpdateCount, 末次 scale=$lastScale');
    for (final l in log.take(4)) {
      debugPrint('  $l');
    }
  });

  test('ScaleGestureRecognizer 的拖拽行为（文档级确认）', () {
    // 说明：Flutter 的 ScaleGestureRecognizer 继承自 OneSequenceGestureRecognizer，
    // 它在**单指**按下时也会 accept 手势并回调 onScaleStart/onScaleUpdate
    // （d.scale 恒为 1.0，d.pointerCount 为 1）。
    // 因此 GestureDetector(onScale*) 会与内层滚动容器**竞争**手势：
    // 谁先进入 accepted 状态谁赢，输的一方不再收到事件。
    expect(ScaleGestureRecognizer, isNotNull);
    expect(ScaleUpdateDetails, isNotNull);
  });
}
