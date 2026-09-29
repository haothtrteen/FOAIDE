import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 清单页（alpha.61 重做）的守卫测试。
///
/// `manifest_codec_test.dart` 已经覆盖了纯函数层面的变换正确性。
/// 这一组守的是**页面层的约定**——那些"写错了也能编译、但会让用户
/// 困惑或造成实际损失"的东西：
///
/// 1. 包名（applicationId）**可编辑**，但必须带齐"改它的代价"的说明
///    （改它会让已装应用无法升级），并且要有重置回磁盘值的出口。
/// 2. 保存必须写**全部三类文件**（pubspec / Manifest / gradle），
///    不能只写一个然后告诉用户"已保存"。
/// 3. 底部悬浮保存按钮必须真的接在 Stack 上（只在 dirty 时出现），
///    否则"保存"入口就没有了。
void main() {
  final src = File('lib/project/manifest_page.dart').readAsStringSync();

  group('清单页 · 包名可编辑', () {
    test('applicationId 绑到了 controller（不再是只读快照）', () {
      expect(src.contains('_pkgCtl'), isTrue);
      expect(src.contains('_pkgCtl.text = appId'), isTrue,
          reason: '读盘后要把磁盘值灌进输入框');
    });

    test('包名旁边保留复制按钮（只是不再需要"粘贴到别处"这个唯一出口）', () {
      expect(src.contains("_copy('包名', _pkgCtl.text.trim())"), isTrue);
    });

    test('有"重置回磁盘值"的出口（改错了不能只能靠手打回去）', () {
      expect(src.contains('_pkgCtl.text = _disk.appId'), isTrue,
          reason: '要有一键还原成当前工程真实包名的入口');
    });

    test('页面文案说清了改包名的代价（否则用户会随手改完再装机）', () {
      expect(src.contains('唯一标识'), isTrue);
      expect(src.contains('装机后不可更换'), isTrue);
    });

    test('明确声明**不会**移动 Kotlin 源码目录', () {
      // 这是用户选定的范围（"只改 gradle + Manifest"）。
      // 不写清楚的话，用户改完包名发现 .kt 里的 package 还是旧的，
      // 会以为是工具没改干净。
      expect(src.contains('package') || src.contains('源码目录'), isTrue);
    });

    test('保存前校验包名格式，并且失败时**不写文件**', () {
      expect(src.contains('ManifestCodec.validAppId'), isTrue,
          reason: '要挡在写文件之前，不能写进去再报错');
      // 校验失败分支里必须 return，否则会带着非法值继续往下写
      final i = src.indexOf('ManifestCodec.validAppId');
      expect(i, greaterThan(0));
      final after = src.substring(i, i + 400);
      expect(after.contains('return'), isTrue,
          reason: '校验不过必须提前返回，不能继续写盘');
    });
  });

  group('清单页 · 保存写全部三类文件', () {
    test('三个目标文件都有写入调用', () {
      // pubspec（描述/版本）
      expect(src.contains('ManifestCodec.setDescription'), isTrue);
      expect(src.contains('ManifestCodec.setVersion'), isTrue);
      // Manifest（应用名/权限）
      expect(src.contains('ManifestCodec.setLabel'), isTrue);
      expect(src.contains('ManifestCodec.applyPermissions'), isTrue);
      // gradle（混淆）
      expect(src.contains('ManifestCodec.setMinify'), isTrue);
    });

    test('每个写入都有失败收集（不能静默吞掉）', () {
      expect(src.contains('failed.add('), isTrue,
          reason: '多处写入无法原子，必须逐文件报告失败');
      expect(src.contains('保存未完成'), isTrue);
    });

    test('写入前先做完整校验（避免写一半才发现格式错）', () {
      final saveIdx = src.indexOf('Future<void> save()');
      final firstWrite =
          src.indexOf('await _fb.write', saveIdx);
      final labelCheck = src.indexOf('ManifestCodec.validLabel', saveIdx);
      final verCheck = src.indexOf('ManifestCodec.validVersionName', saveIdx);
      expect(labelCheck, greaterThan(0));
      expect(verCheck, greaterThan(0));
      expect(labelCheck, lessThan(firstWrite),
          reason: '校验必须在第一次写盘之前——写一半失败会留下不一致的状态');
      expect(verCheck, lessThan(firstWrite));
    });

    test('版本名降级有二次确认（应用商店会拒收）', () {
      expect(src.contains('versionNameDowngrade'), isTrue);
      expect(src.contains('版本名降级'), isTrue);
      expect(src.contains('应用商店会拒绝'), isTrue);
    });

    test('保存后静默复查（信任磁盘而不是信任自己）', () {
      expect(src.contains('_verify()'), isTrue);
      expect(src.contains('写入后校验发现内容不一致'), isTrue);
    });
  });

  group('清单页 · 悬浮保存按钮', () {
    test('只在有改动时出现（无改动时不挡内容）', () {
      expect(src.contains('if (dirty) _saveBar()'), isTrue);
    });

    test('悬浮条汇总"改了什么"，不让用户猜', () {
      expect(src.contains("changed.add('应用名')"), isTrue);
      expect(src.contains("changed.add('版本名')"), isTrue);
      expect(src.contains("changed.add('权限')"), isTrue);
      expect(src.contains('待保存：'), isTrue);
    });

    test('提供"放弃"以便回滚到磁盘值', () {
      expect(src.contains('void revert()'), isTrue);
      expect(src.contains("child: const Text('放弃'"), isTrue);
    });

    test('列表底部留白，避免最后一张卡被悬浮条挡住', () {
      expect(src.contains('dirty ? 96 : 24'), isTrue);
    });
  });

  group('清单页 · 五张卡都在', () {
    test('身份 / 版本 / 权限 / 图标 / 签名 / 构建选项', () {
      expect(src.contains('_identityCard'), isTrue);
      expect(src.contains('_versionCard'), isTrue);
      expect(src.contains('_permissionCard'), isTrue);
      expect(src.contains('_iconCard'), isTrue);
      expect(src.contains('_signingCard'), isTrue);
      expect(src.contains('_advancedCard'), isTrue);
    });

    test('权限勾选既有"新增"也有"移除"语义', () {
      // 只做"加"的话用户无法收回一个不再需要的权限
      expect(src.contains('_uncheckedExisting'), isTrue,
          reason: '取消勾选已声明的权限必须能写回（移除），不能只支持新增');
    });

    test('图标卡既说明正规做法，也给了能直接用的替换入口', () {
      // alpha.93 之前这张卡只有一句"把 png 覆盖到 mipmap-*"的提示，
      // 用户看完还得自己去文件管理器里操作，等于没做。
      expect(src.contains('flutter_launcher_icons'), isTrue,
          reason: '电脑上生成图标的标准做法要保留——用户会拿工程回电脑上继续做');
      expect(src.contains('_replaceIcon'), isTrue);
      expect(src.contains('选择图片替换'), isTrue);
      expect(src.contains('IconReplacer.apply'), isTrue);
    });

    test('签名卡区分"未配置"与"已配置"两种状态', () {
      expect(src.contains('_hasSigning'), isTrue);
      expect(src.contains('debug 签名的 APK 不能上架'), isTrue);
    });

    test('混淆开关说明了 keep 规则的风险', () {
      expect(src.contains('keep 规则'), isTrue);
      expect(src.contains('反射'), isTrue);
    });
  });

  group('清单页 · 与父页的接线', () {
    test('父页把 ManifestPage 放进了 IndexedStack 且顺序正确', () {
      final page = File('lib/project/project_page.dart').readAsStringSync();
      // 枚举顺序 overview, code, manifest, build, ai
      // IndexedStack 的 children 必须同序。
      //
      // 注意：打包区在 _buildSections() 里是通过 `_buildPanel()` 这个转发
      // 方法落位的（真正的 BuildPanel 构造在 _buildPanel() 体内），所以这里
      // 找的是调用点而不是类型名 —— 断言必须贴着实际写法，否则会假失败。
      final i = page.indexOf('Widget _buildSections()');
      final body = page.substring(i, page.indexOf('Widget _buildSideTree()', i));
      const keys = <String>[
        '_buildOverview()',
        'EditorPage(',
        'DesignPage(',
        'ManifestPage(',
        'GitPanel(',
        '_buildPanel()',
        'AiTakeoverPanel(',
      ];
      final order = <int>[];
      for (final k in keys) {
        final at = body.indexOf(k);
        expect(at, greaterThanOrEqualTo(0), reason: '找不到 $k，接线写法和断言脱节了');
        order.add(at);
      }
      for (var i = 1; i < order.length; i++) {
        expect(order[i], greaterThan(order[i - 1]),
            reason: 'IndexedStack 用 _section.index 定位，children 必须与枚举同序');
      }
    });

    test('AppBar 保存按钮与页面内悬浮条共用同一条保存路径', () {
      final page = File('lib/project/project_page.dart').readAsStringSync();
      expect(page.contains('_manifestKey.currentState?.save()'), isTrue,
          reason: '两个入口必须调同一个 save()，否则会出现'
              '"顶部保存成功、底部还在 pending"的不一致');
      expect(page.contains('_manifestCtl.dirty'), isTrue);
    });

    test('清单保存后父页快照会刷新（预览卡不能显示过期数据）', () {
      final page = File('lib/project/project_page.dart').readAsStringSync();
      expect(page.contains('_onManifestChanged'), isTrue);
      expect(page.contains('_refreshManifestSnapshot'), isTrue);
    });
  });

  group('解析逻辑单一来源', () {
    test('父页不再自己写正则解析 pubspec（改用 codec）', () {
      final page = File('lib/project/project_page.dart').readAsStringSync();
      final i = page.indexOf('Future<void> _readManifest');
      final body = page.substring(i, page.indexOf('Future<void> _refreshManifestSnapshot', i));
      expect(body.contains('ManifestCodec.parsePubspec'), isTrue);
      expect(body.contains('ManifestCodec.parseManifest'), isTrue);
      expect(body.contains('ManifestCodec.parseGradle'), isTrue);
      // 反面：不该再出现就地写的正则
      expect(body.contains("RegExp(r'^name:"), isFalse,
          reason: '两处各写一份正则必然漂移，必须共用 codec');
    });
  });
}
