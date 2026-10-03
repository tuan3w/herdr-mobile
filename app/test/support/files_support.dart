import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'fake_fs.dart';
import 'fake_transport.dart';

/// A machine whose files are [fs] (not started: no snapshot loop runs).
MachineConnection machineWithFiles(FakeFs? fs, {FakeTransport? transport}) {
  final t = (transport ?? FakeTransport())..fs = fs;
  return MachineConnection(
    profile: MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
    api: HerdrApi(t),
    backoff: (_) => const Duration(hours: 1),
    pollInterval: const Duration(hours: 1),
  );
}

/// A realistic project tree at /home/dev/herdr-mobile.
FakeFs projectFs() {
  final fs = FakeFs();
  const root = '/home/dev/herdr-mobile';
  fs.addDir('$root/app/lib/ui');
  fs.addDir('$root/docs');
  fs.addDir('$root/third_party');
  fs.addDir('$root/.git');
  fs.addDir('$root/.github');
  fs.addFile('$root/README.md', _readme);
  fs.addFile('$root/AGENTS.md', 'notes\n');
  fs.addFile('$root/.gitignore', 'build/\n.dart_tool/\n');
  fs.addFile('$root/pubspec.yaml', 'name: herdr_mobile\nversion: 1.4.0+4102\n');
  fs.addFile('$root/package.json', '{"name":"herdr","version":"1.0.0","scripts":{"build":"tsc","test":"vitest"},"dependencies":{"a":"^1","b":"^2"}}');
  fs.addFile('$root/app/lib/main.dart', sampleDart);
  fs.addFile('$root/docs/Thiết kế giao diện.md', '# Thiết kế\n');
  fs.addFile('$root/docs/日本語のメモ.txt', 'メモ\n');
  fs.addFile('$root/screenshot 2026-05-20 at 09.30.png', Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]));
  fs.addFile('$root/release.apk', Uint8List(4 * 1024 * 1024));
  fs.addFile('$root/empty.txt', '');
  fs.addFile('$root/build.log', List.generate(300, (i) => 'line $i ok').join('\n'));
  fs.addLink('$root/latest', 'docs');
  fs.addLink('$root/current.log', 'build.log');
  fs.addLink('$root/stale-link', 'does/not/exist');
  fs.addFile(
    '$root/a-very-long-file-name-that-keeps-going-and-going-until-it-needs-an-ellipsis-somewhere-around-here.dart.orig.bak',
    'x',
  );
  return fs;
}

const _readme = '''# herdr mobile

A **Flutter** client for herdr. See [the docs](https://example.com/docs) or run:

```bash
flutter run --release
```

## Features

- Pane view with *wrap* mode
- Remote files: `SFTP`, no shell
  - nested item
1. First
2. Second

> Tip: pinch to zoom the terminal.

| Name | Kind |
| ---- | ---- |
| a    | dir  |

---

Plain paragraph that wraps over several lines so the reading column can be judged at phone width.
''';

String get sampleDart {
  final b = StringBuffer()
    ..writeln("import 'package:flutter/material.dart';")
    ..writeln()
    ..writeln('/// Entry point.')
    ..writeln('void main() {')
    ..writeln('  runApp(const App());')
    ..writeln('}')
    ..writeln();
  for (var i = 0; i < 60; i++) {
    b.writeln('\tfinal value$i = compute(input[$i], options: const Options(retries: 3, backoff: Duration(milliseconds: 250)));');
  }
  b.writeln('// Tiếng Việt: Đường dẫn tệp rất dài, 日本語のコメントもここにあります。');
  return b.toString();
}

/// PNG bytes of a [width] x [height] gradient with a few shapes, drawn with
/// the engine (needs `tester.runAsync`).
Future<Uint8List> makePng(WidgetTester tester, int width, int height) async {
  late Uint8List out;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final rect = ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    canvas.drawRect(
      rect,
      ui.Paint()
        ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, const [
          ui.Color(0xFF5E6AD2),
          ui.Color(0xFF4CB782),
          ui.Color(0xFFF2C94C),
        ], const [
          0,
          0.55,
          1
        ]),
    );
    canvas.drawCircle(
      ui.Offset(width * 0.3, height * 0.4),
      height * 0.22,
      ui.Paint()..color = const ui.Color(0xCCFFFFFF),
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(width * 0.55, height * 0.5, width * 0.3, height * 0.3),
      ui.Paint()..color = const ui.Color(0x99000000),
    );
    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    out = data!.buffer.asUint8List();
  });
  return out;
}
