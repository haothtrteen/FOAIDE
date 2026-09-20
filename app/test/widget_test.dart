// Step 1 冒烟测试：App 壳能构建出首页。
// 深层逻辑（proot 桥、rootfs 安装）依赖 MethodChannel 与 filesDir，
// 由真机验证清单覆盖（dev-handbook/03-测试指南.md），不在 widget 测试范围。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:foaide/main.dart';

void main() {
  testWidgets('FoaApp 构建冒烟测试', (WidgetTester tester) async {
    await tester.pumpWidget(const FoaApp());

    // 首页能渲染出 MaterialApp / Scaffold 即认为壳完整
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);
  });
}
