import 'package:flutter_test/flutter_test.dart';

import 'package:foaide/toolchain/native_arm64.dart';

/// 构造体检脚本的一行输出（字段以 TAB 分隔，与容器内脚本保持一致）。
String p(
  String name,
  String path,
  String kind, [
  String machine = '-',
  String needed = '-',
  String approx = 'no',
]) =>
    ['P', name, path, kind, machine, needed, approx].join('\t');

const _sample = '''
UNAME=aarch64
READELF=no
DARTVER=Dart SDK version: 3.12.1 (stable) on "linux_x64"
BUILD_TOOLS=/opt/android-sdk/build-tools/36.0.0
NATIVE_DIR=yes
''';

void main() {
  group('NativeAudit 解析', () {
    test('元数据与探测项', () {
      final a = NativeAudit.parse(
        '${_sample.trim()}\n'
        '${p('dart', '/opt/flutter/bin/cache/dart-sdk/bin/dart', 'missing')}\n'
        '${p('aapt2', '/opt/android-sdk/build-tools/36.0.0/aapt2', 'qemu')}\n'
        '${p('zipalign', '/opt/android-sdk/build-tools/36.0.0/zipalign', 'elf', 'x86-64', 'libz.so.1,libc.so.6,')}\n'
        '${p('native:gen_snapshot', '/opt/foa-native/gen_snapshot', 'elf', 'aarch64', 'libc.so,libm.so,libdl.so,')}\n',
      );
      expect(a.unameMachine, 'aarch64');
      expect(a.readelfAvailable, isFalse);
      expect(a.buildToolsDir, '/opt/android-sdk/build-tools/36.0.0');
      expect(a.nativeDirPresent, isTrue);
      expect(a.dartTargetArch, 'linux_x64');
      expect(a.probes.length, 4);
      expect(a.probe('dart')!.kind, NativeProbeKind.missing);
      expect(a.probe('aapt2')!.kind, NativeProbeKind.qemuWrapper);
      expect(a.probe('zipalign')!.x64, isTrue);
      expect(a.probe('zipalign')!.glibcLink, isTrue);
      expect(a.probe('zipalign')!.bionicLink, isFalse);
    });

    test('bionic 链接识别（Termux 移植产物的典型特征）', () {
      final gs = NativeAudit.parse(
        p('native:gen_snapshot', '/opt/foa-native/gen_snapshot', 'elf',
            'aarch64', 'libc.so,libm.so,libdl.so,', 'yes'),
      ).probe('native:gen_snapshot')!;
      expect(gs.native, isTrue);
      expect(gs.bionicLink, isTrue);
      expect(gs.glibcLink, isFalse);
      expect(gs.neededApprox, isTrue); // 无 readelf → 走粗扫
      expect(gs.summary, contains('bionic'));
    });

    test('架构不匹配时 buildReady 为 false', () {
      // dart 是 arm64 但快照仍是 x64 → 不能算"可全原生构建"
      final a = NativeAudit.parse(
        'UNAME=aarch64\n'
        'READELF=yes\n'
        'DARTVER=Dart SDK version: 3.12.1 (stable) on "linux_x64"\n'
        '${p('dart', '/x/dart', 'elf', 'aarch64', 'libc.so.6,')}\n'
        '${p('aapt2', '/x/aapt2', 'elf', 'aarch64', 'libc.so.6,')}\n'
        '${p('zipalign', '/x/zipalign', 'elf', 'aarch64', 'libc.so.6,')}\n'
        '${p('native:gen_snapshot', '/opt/foa-native/gen_snapshot', 'elf', 'aarch64', 'libc.so,')}\n',
      );
      expect(a.buildReady, isFalse);
    });

    test('全链路原生时 buildReady 为 true', () {
      final a = NativeAudit.parse(
        'UNAME=aarch64\n'
        'READELF=yes\n'
        'DARTVER=Dart SDK version: 3.12.1 (stable) on "linux_arm64"\n'
        '${p('dart', '/x/dart', 'elf', 'aarch64', 'libc.so.6,')}\n'
        '${p('aapt2', '/x/aapt2', 'elf', 'aarch64', 'libc.so.6,')}\n'
        '${p('zipalign', '/x/zipalign', 'elf', 'aarch64', 'libc.so.6,')}\n'
        '${p('gen_snapshot(arm64)', '/x/gen_snapshot', 'elf', 'aarch64', 'libc.so.6,')}\n',
      );
      expect(a.buildReady, isTrue);
      expect(a.overview, contains('原生 4'));
    });

    test('空输出不炸', () {
      final a = NativeAudit.parse('');
      expect(a.probes, isEmpty);
      expect(a.buildReady, isFalse);
      expect(a.dartTargetArch, '');
    });
  });

  group('NativeBuildTools 常量', () {
    test('SHA-256 与体积是 64 位十六进制 / 正值', () {
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(NativeBuildTools.tarSha256),
          isTrue);
      expect(NativeBuildTools.tarSize, greaterThan(0));
      expect(NativeBuildTools.tarUrl, contains(NativeBuildTools.tag));
      expect(NativeBuildTools.tarUrl, endsWith(NativeBuildTools.tarName));
    });

    test('镜像列表非空且都能构造出完整 URL', () {
      final ms = NativeBuildTools.mirrors();
      expect(ms, isNotEmpty);
      for (final m in ms) {
        expect(m.url, endsWith(NativeBuildTools.tarName));
        expect(m.name, isNotEmpty);
      }
    });
  });
}
