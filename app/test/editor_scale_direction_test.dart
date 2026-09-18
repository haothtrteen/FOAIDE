// Bug 432 回归测试：双指手势的方向敏感性。
//
// 用户报告（2026-09-18，原话）：
//   "是双指，但是只有上下有效果，左右没效果"
//
// 根因（已定位并数值验证）：
//   Flutter 的 ScaleUpdateDetails.scale 是**各向同性**的欧氏距离比
//   （scale.dart: _pointerScaleFactor = _currentSpan / _initialSpan，
//    span = 各指到质心的 hypot 距离的平均）。
//   双指自然持机时两指在 y 轴错开，上下滑动过程中两指上下异步
//   （人手指不可能完全同步）会直接改变 hypot 距离 → scale 偏离 1.0。
//   实测复刻 span 公式：竖直排列的两指滑动滞后 2px → 1.72% 漂移，
//   滞后 10px → 8.56%；水平并排的两指同样滞后仅 0.70% / 3.81%。
//   因此「上下划能缩放、左右划不能」与手指数量无关，只与两指的
//   空间排列和滑动轴向有关。
//
// 修复：只用**轴向间距**（horizontalScale / verticalScale）判断缩放，
//       并要求超过 15% 的间距变化才认账（_kSpanSlop）。
//
// 本测试复刻修复后的判定逻辑，覆盖：
//   [1] 双指平移（上下/左右/斜向）**绝不**改字号
//   [2] 双指真实捏合（间距变化）**必须**改字号
//   [3] 单指手势一律不改字号
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻 code_editor.dart 中修复后的状态机（与源码保持逐行同构）。
class ScaleGate {
  ScaleGate(this.fontSize);
  double fontSize;
  double _base = 0;
  bool _active = false;
  bool _engaged = false;
  static const double kSpanSlop = 0.15;

  final List<double> changes = [];

  void start(int pointerCount) {
    if (pointerCount < 2) return;
    _base = fontSize;
    _engaged = false;
    _active = true;
  }

  void update({
    required int pointerCount,
    required double horizontalScale,
    required double verticalScale,
  }) {
    if (!_active || pointerCount < 2) return;
    final fx = horizontalScale;
    final fy = verticalScale;
    final dx = (fx - 1.0).abs();
    final dy = (fy - 1.0).abs();
    if (!_engaged) {
      if (dx < kSpanSlop && dy < kSpanSlop) return;
      _engaged = true;
    } else if (dx < kSpanSlop * 0.5 && dy < kSpanSlop * 0.5) {
      // 回位：撤销本次缩放
      _engaged = false;
      if ((fontSize - _base).abs() >= 0.5) {
        fontSize = _base;
        changes.add(-1); // 标记为一次撤销（字号回到 base）
      }
      return;
    }
    final factor = dx >= dy ? fx : fy;
    if (factor <= 0) return;
    final v = (_base * factor).clamp(8.0, 40.0);
    if ((v - fontSize).abs() >= 0.5) {
      fontSize = v;
      changes.add(v);
    }
  }

  void end() {
    _active = false;
    _engaged = false;
  }
}

/// 用 Flutter 的 span 公式算出 (horizontalScale, verticalScale)。
/// 复刻 /opt/flutter/packages/flutter/lib/src/gestures/scale.dart 的
/// _update() 中 span 的计算方式。
({double h, double v}) axisScales(
  List<Offset> initial,
  List<Offset> current,
) {
  double hSpan(List<Offset> pts) {
    final n = pts.length;
    final fx = pts.map((p) => p.dx).reduce((a, b) => a + b) / n;
    return pts.map((p) => (fx - p.dx).abs()).reduce((a, b) => a + b) / n;
  }

  double vSpan(List<Offset> pts) {
    final n = pts.length;
    final fy = pts.map((p) => p.dy).reduce((a, b) => a + b) / n;
    return pts.map((p) => (fy - p.dy).abs()).reduce((a, b) => a + b) / n;
  }

  final ih = hSpan(initial), ch = hSpan(current);
  final iv = vSpan(initial), cv = vSpan(current);
  return (
    h: ih > 1e-9 ? ch / ih : 1.0,
    v: iv > 1e-9 ? cv / iv : 1.0,
  );
}

void main() {
  group('Bug 432 · 双指平移不得改字号', () {
    test('双指上下滑动（竖直排列，两指异步 2px）', () {
      // 自然持机：两指一上一下
      final initial = [const Offset(150, 250), const Offset(190, 350)];
      final g = ScaleGate(14.0);
      g.start(2);

      // 同步下滑 20px，第二指滞后 2px（真机常态）
      final cur = [const Offset(150, 270), const Offset(190, 368)];
      final s = axisScales(initial, cur);
      for (var i = 0; i < 10; i++) {
        g.update(pointerCount: 2, horizontalScale: s.h, verticalScale: s.v);
      }
      g.end();

      debugPrint('  上下滑 hScale=${s.h.toStringAsFixed(4)} '
          'vScale=${s.v.toStringAsFixed(4)} 字号变化=${g.changes}');
      expect(g.changes, isEmpty, reason: '双指上下滑动不得改字号');
    });

    test('双指左右滑动（并排，两指异步 2px）', () {
      final initial = [const Offset(150, 300), const Offset(250, 300)];
      final g = ScaleGate(14.0);
      g.start(2);

      final cur = [const Offset(130, 300), const Offset(232, 300)];
      final s = axisScales(initial, cur);
      for (var i = 0; i < 10; i++) {
        g.update(pointerCount: 2, horizontalScale: s.h, verticalScale: s.v);
      }
      g.end();

      debugPrint('  左右滑 hScale=${s.h.toStringAsFixed(4)} '
          'vScale=${s.v.toStringAsFixed(4)} 字号变化=${g.changes}');
      expect(g.changes, isEmpty, reason: '双指左右滑动不得改字号');
    });

    test('双指斜向滑动（对角平移）', () {
      final initial = [const Offset(150, 250), const Offset(190, 350)];
      final g = ScaleGate(14.0);
      g.start(2);

      final cur = [const Offset(140, 270), const Offset(182, 366)];
      final s = axisScales(initial, cur);
      for (var i = 0; i < 10; i++) {
        g.update(pointerCount: 2, horizontalScale: s.h, verticalScale: s.v);
      }
      g.end();

      debugPrint('  斜向滑 hScale=${s.h.toStringAsFixed(4)} '
          'vScale=${s.v.toStringAsFixed(4)} 字号变化=${g.changes}');
      expect(g.changes, isEmpty, reason: '双指斜向滑动不得改字号');
    });

    test('极端抖动：两指位移差达到 10px 仍不得改字号', () {
      final initial = [const Offset(150, 250), const Offset(190, 350)];
      final g = ScaleGate(14.0);
      g.start(2);

      final cur = [const Offset(150, 280), const Offset(190, 370)];
      final s = axisScales(initial, cur);
      for (var i = 0; i < 10; i++) {
        g.update(pointerCount: 2, horizontalScale: s.h, verticalScale: s.v);
      }
      g.end();

      debugPrint('  大抖动 hScale=${s.h.toStringAsFixed(4)} '
          'vScale=${s.v.toStringAsFixed(4)} 字号变化=${g.changes}');
      expect(g.changes, isEmpty, reason: '两指异步 10px 仍是平移，不得改字号');
    });
  });

  group('Bug 432 · 真实捏合必须改字号', () {
    test('横向捏合（两指水平拉开 40px）放大字号', () {
      final initial = [const Offset(150, 300), const Offset(250, 300)];
      final g = ScaleGate(14.0);
      g.start(2);

      final cur = [const Offset(110, 300), const Offset(290, 300)];
      final s = axisScales(initial, cur);
      g.update(pointerCount: 2, horizontalScale: s.h, verticalScale: s.v);
      g.end();

      debugPrint('  横向捏合 hScale=${s.h.toStringAsFixed(4)} -> '
          '字号 ${g.changes}');
      expect(g.changes, isNotEmpty, reason: '横向捏合必须能改字号');
      expect(g.changes.last, greaterThan(14.0), reason: '拉开应放大');
    });

    test('纵向捏合（两指竖直拉开 40px）放大字号', () {
      final initial = [const Offset(170, 270), const Offset(170, 330)];
      final g = ScaleGate(14.0);
      g.start(2);

      final cur = [const Offset(170, 240), const Offset(170, 360)];
      final s = axisScales(initial, cur);
      g.update(pointerCount: 2, horizontalScale: s.h, verticalScale: s.v);
      g.end();

      debugPrint('  纵向捏合 hScale=${s.h.toStringAsFixed(4)} '
          'vScale=${s.v.toStringAsFixed(4)} -> 字号 ${g.changes}');
      expect(g.changes, isNotEmpty, reason: '纵向捏合必须能改字号');
      expect(g.changes.last, greaterThan(14.0), reason: '拉开应放大');
    });

    test('横向捏合收拢（缩小）字号', () {
      final initial = [const Offset(110, 300), const Offset(290, 300)];
      final g = ScaleGate(14.0);
      g.start(2);

      final cur = [const Offset(150, 300), const Offset(250, 300)];
      final s = axisScales(initial, cur);
      g.update(pointerCount: 2, horizontalScale: s.h, verticalScale: s.v);
      g.end();

      debugPrint('  横向收拢 hScale=${s.h.toStringAsFixed(4)} -> '
          '字号 ${g.changes}');
      expect(g.changes, isNotEmpty, reason: '横向收拢必须能改字号');
      expect(g.changes.last, lessThan(14.0), reason: '收拢应缩小');
    });
  });

  group('Bug 432 · 单指一律不改字号', () {
    test('单指垂直拖动', () {
      final g = ScaleGate(14.0);
      g.start(1);
      for (var i = 0; i < 10; i++) {
        g.update(pointerCount: 1, horizontalScale: 1.0, verticalScale: 1.0);
      }
      g.end();
      expect(g.changes, isEmpty);
    });

    test('单指水平拖动', () {
      final g = ScaleGate(14.0);
      g.start(1);
      for (var i = 0; i < 10; i++) {
        g.update(pointerCount: 1, horizontalScale: 1.0, verticalScale: 1.0);
      }
      g.end();
      expect(g.changes, isEmpty);
    });
  });

  group('Bug 432 · 异步尖峰后回位必须撤销缩放', () {
    test('越界一帧后手指回位，字号应回到基准且不残留', () {
      final g = ScaleGate(14.0);
      g.start(2);

      // 1) 正常平移若干帧（低于阈值，不动）
      for (var i = 0; i < 5; i++) {
        g.update(pointerCount: 2, horizontalScale: 1.0, verticalScale: 0.98);
      }
      expect(g.changes, isEmpty);

      // 2) 异步尖峰：vScale 掉到 0.70（远超 15% 阈值）→ 被判为缩放
      g.update(pointerCount: 2, horizontalScale: 1.0, verticalScale: 0.70);
      expect(g.changes, isNotEmpty, reason: '越界帧会触发一次缩放');
      expect(g.fontSize, lessThan(14.0));

      // 3) 手指回位：vScale 回到 ~1.0 → 应撤销、字号回基准
      g.update(pointerCount: 2, horizontalScale: 1.0, verticalScale: 1.0);
      expect(g.fontSize, equals(14.0), reason: '回位后字号必须回到基准');

      // 4) 之后继续平移不得再触发缩放
      g.changes.clear();
      for (var i = 0; i < 5; i++) {
        g.update(pointerCount: 2, horizontalScale: 1.0, verticalScale: 0.97);
      }
      expect(g.changes, isEmpty, reason: '撤销后应停止响应本次手势');
      g.end();
    });
  });



  group('Bug 432 · 源码接线检查', () {
    // 直接断言代码编辑器源码用的是轴向倍率而非各向同性 scale，
    // 防止后续重构时退回有 bug 的写法。
    late String src;

    setUpAll(() {
      src = File('lib/editor/code_editor.dart').readAsStringSync();
    });

    test('使用 d.horizontalScale / d.verticalScale 而非 d.scale', () {
      expect(src.contains('d.horizontalScale'), isTrue,
          reason: '必须使用轴向倍率 horizontalScale');
      expect(src.contains('d.verticalScale'), isTrue,
          reason: '必须使用轴向倍率 verticalScale');
    });

    test('onScaleUpdate 内不得直接使用 d.scale 乘算字号', () {
      final body = _stripComments(_fnBody(src, 'onScaleUpdate'));
      expect(body.contains('d.scale'), isFalse,
          reason: '各向同性 scale 会把双指滑动误判为捏合');
      expect(body.contains('_scaleBase * factor'), isTrue,
          reason: '应乘以轴向 factor');
    });

    test('存在跨度阈值常量以防抖动误判', () {
      expect(src.contains('_kSpanSlop'), isTrue,
          reason: '必须有间距变化阈值，滤掉滑动异步抖动');
      expect(src.contains('_scaleEngaged'), isTrue,
          reason: '必须有「已判定为缩放」的锁存标志');
    });

    test('单指（pointerCount<2）在 start/update 均被挡下', () {
      for (final fn in ['onScaleStart', 'onScaleUpdate']) {
        final body = _stripComments(_fnBody(src, fn));
        expect(body.contains('pointerCount < 2'), isTrue,
            reason: '$fn 必须拒绝单指手势');
      }
    });
  });
}

/// 取出一个回调的函数体。
///
/// 注意：不能简单 src.indexOf(fnName)——源码注释里也会提到 onScaleStart
/// 等名字（如「捏合起点字号（onScaleStart 快照…）」），会命中注释。
/// 这里要求匹配 `fnName:` 形式（即真正的具名参数定义），并跳过注释行。
String _fnBody(String src, String fnName) {
  var i = -1;
  var from = 0;
  while (true) {
    final k = src.indexOf('$fnName:', from);
    if (k < 0) break;
    final lineStart = src.lastIndexOf('\n', k) + 1;
    final line = src.substring(lineStart, k);
    final t = line.trimLeft();
    if (!t.startsWith('//') && !t.startsWith('*')) {
      i = k;
      break;
    }
    from = k + 1;
  }
  if (i < 0) return '';
  final start = src.indexOf('{', i);
  if (start < 0) return '';
  var depth = 0;
  for (var k = start; k < src.length; k++) {
    final c = src[k];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, k + 1);
    }
  }
  return src.substring(start);
}

/// 去掉注释行，避免"注释里出现某字符串"造成误判。
String _stripComments(String code) {
  return code
      .split('\n')
      .where((l) {
        final t = l.trim();
        return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
      })
      .join('\n');
}
