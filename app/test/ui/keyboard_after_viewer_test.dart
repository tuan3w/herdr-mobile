// Opening a picture or a file from the chat and coming back must not bring the
// keyboard up: a person who opens one is reading the history, and Flutter gives
// the focus back to whatever had it when the route comes off the screen.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/photo_thread.dart';
import 'package:herdr_mobile/ui/features/files/files_navigation.dart';
import 'package:image/image.dart' as img;

import '../support/fake_fs.dart';
import '../support/files_support.dart';

void main() {
  late FocusNode field;
  late BuildContext home;

  Future<void> pumpChat(WidgetTester tester) async {
    field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              home = c;
              return Column(children: [TextField(focusNode: field)]);
            },
          ),
        ),
      ),
    );
    // The person was typing: the composer has focus (the keyboard is up).
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(field.hasFocus, isTrue);
  }

  testWidgets('a file opened from the chat: back does not give the composer the keyboard again', (tester) async {
    await pumpChat(tester);
    final fs = FakeFs()
      ..mkdirs('/home/dev/app')
      ..addFile('/home/dev/app/main.dart', 'void main() {}\n', modified: DateTime.utc(2026, 5, 20));

    unawaited(openRemoteFile(home, machineWithFiles(fs), '/home/dev/app/main.dart'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(ModalRoute.of(home)!.isCurrent, isFalse, reason: 'the viewer is on top');

    Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(TextField), findsOneWidget);
    expect(field.hasFocus, isFalse, reason: 'back from the viewer: no keyboard');
  });

  testWidgets('a picture of the chat history: back does not give the composer the keyboard again', (tester) async {
    await pumpChat(tester);
    final png = img.Image(width: 8, height: 8);
    final block = ImageBlock(data: base64Encode(Uint8List.fromList(img.encodePng(png))), mimeType: 'image/png');

    unawaited(showContentImage(home, block));
    await tester.pump(const Duration(milliseconds: 600));
    expect(ModalRoute.of(home)!.isCurrent, isFalse, reason: 'the viewer is on top');

    Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
    await tester.pump(const Duration(milliseconds: 600));

    expect(field.hasFocus, isFalse, reason: 'back from the viewer: no keyboard');
  });
}

void unawaited(Future<void> f) {}
