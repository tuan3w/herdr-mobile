import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../support/fake_agent_session.dart';
import '../support/turn_fixtures.dart';

// What the person sees of the keeper's bounded log: one quiet line at the top
// of a transcript whose oldest turns the host no longer keeps, and a mark on
// the tool rows whose detail it cut. Worst case: 320 dp, 160% text,
// Vietnamese.

const _trimmed = {
  'herdr': {'trimmed': true},
};

Future<void> _pump(WidgetTester tester, List<TranscriptItem> items, {Size size = const Size(412, 892), double textScale = 1}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: TranscriptView(session: FakeAgentSession(state: stateWith(items: items)))),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _rich(String text) => find.textContaining(text, findRichText: true);

/// Two finished turns whose calls were trimmed by the host (the first), and
/// one that was not.
List<TranscriptItem> _turns() => [
  userAt('u0', 'Sửa lỗi dấu thanh trong trình phân tích', 0),
  _cutRun('c0', 'dart test --name "Hà Nội"', 2),
  agentAt('a0', 'Đã sửa xong lỗi dấu thanh.', 6),
  userAt('u1', 'Chạy lại kiểm thử', 20),
  runAt('c1', 'dart analyze', 22, exitCode: 1, output: 'còn một cảnh báo'),
  agentAt('a1', 'Vẫn còn một cảnh báo.', 26),
];

/// A finished command the host cut the detail of.
TranscriptTool _cutRun(String id, String command, int start) => toolAt(
  id,
  title: command,
  kind: ToolKind.execute,
  status: ToolStatus.failed,
  rawInput: {'command': command},
  output: const ToolOutput(text: 'x', exited: true, exitCode: 1),
  meta: _trimmed,
  start: start,
);

void main() {
  testWidgets('a transcript whose host dropped turns opens with one quiet line, above everything', (tester) async {
    final items = [TranscriptNote(key: hostDroppedKey, text: hostDroppedText(12)), ..._turns()];
    await _pump(tester, items);
    final line = find.text('Earlier messages are no longer kept on the host (12 turns).');
    expect(line, findsOneWidget);
    expect(tester.getTopLeft(line).dy, lessThan(tester.getTopLeft(find.text('Sửa lỗi dấu thanh trong trình phân tích')).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('no line when the host dropped nothing', (tester) async {
    await _pump(tester, _turns());
    expect(find.textContaining('no longer kept'), findsNothing);
  });

  testWidgets('the divider for what only the phone has reads Earlier, from this phone', (tester) async {
    await _pump(tester, [
      ..._turns().take(3),
      const TranscriptNote(key: phoneEarlierKey, text: phoneEarlierText),
      ..._turns().skip(3),
    ]);
    expect(find.text('Earlier, from this phone'), findsOneWidget);
  });

  testWidgets('a call whose detail was trimmed says so on its row and where its output would be; a whole one does not', (tester) async {
    await _pump(tester, _turns());
    // A failed call breaks out of the fold: both rows are visible.
    expect(_rich('Details trimmed'), findsOneWidget, reason: 'only the trimmed call');
    expect(find.text('Output trimmed'), findsNothing, reason: 'the body is closed');

    await tester.tap(_rich('dart test --name'));
    await tester.pumpAndSettle();
    expect(find.text('Output trimmed'), findsOneWidget);

    // The whole call opens to its output, with no such note.
    await tester.tap(_rich('dart analyze'));
    await tester.pumpAndSettle();
    expect(find.textContaining('còn một cảnh báo', findRichText: true), findsWidgets);
    expect(find.text('Output trimmed'), findsOneWidget, reason: 'still just the first');
  });

  testWidgets('worst case: 320 dp, 160% text, a long Vietnamese title: nothing overflows', (tester) async {
    final long = 'Chạy toàn bộ kiểm thử đơn vị cho thư viện phân tích địa danh Hà Nội, Thành phố Hồ Chí Minh và Đà Nẵng ' * 2;
    final items = [
      TranscriptNote(key: hostDroppedKey, text: hostDroppedText(1234)),
      userAt('u0', 'Kiểm tra', 0),
      _cutRun('c0', long, 2),
      toolAt(
        'r0',
        title: 'Read /home/dev/thư mục dài/tệp rất dài.dart',
        kind: ToolKind.read,
        rawInput: {'file_path': '/home/dev/thư mục dài/tệp rất dài.dart'},
        meta: _trimmed,
        start: 3,
      ),
      agentAt('a0', 'Xong.', 6),
    ];
    await _pump(tester, items, size: const Size(320, 640), textScale: 1.6);
    expect(find.textContaining('no longer kept'), findsOneWidget);
    await tester.tap(_rich('Chạy toàn bộ'));
    await tester.pumpAndSettle();
    expect(find.text('Output trimmed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
