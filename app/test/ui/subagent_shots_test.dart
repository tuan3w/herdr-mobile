// Renders subagents and the session overview to PNGs for review (light and
// dark, 412x892 and 320x640, text scale 1 and 1.6): the card running,
// finished, failed and waiting, three in parallel, 25 runs in the roster, the
// drill-in with a long conversation, an omp summary, the dock with its origin,
// the overview with everything and with almost nothing, long titles and
// Vietnamese. Off by default; it writes files:
//
//   SUBAGENT_SHOTS=1 flutter test test/ui/subagent_shots_test.dart
//
// Output: $SUBAGENT_SHOTS_DIR (default /tmp/subagent_shots)/<case>-<light|dark>-<w>x<h>-<scale>.png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_dock.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_overview.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_roster.dart';
import 'package:herdr_mobile/ui/features/agent_session/subagent_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import '../support/subagent_fixtures.dart';
import '../support/turn_fixtures.dart';

void main() {
  if (Platform.environment['SUBAGENT_SHOTS'] == null) {
    test('subagent shots are off (set SUBAGENT_SHOTS=1)', () {}, skip: 'set SUBAGENT_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['SUBAGENT_SHOTS_DIR'] ?? '/tmp/subagent_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });
  tearDown(() => statusNow = DateTime.now);

  const long =
      'Investigate why the Hà Nội locale normalization lowercases before composing the Vietnamese diacritics in the payments-api parser module and report every call site';

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget Function(FakeAgentSession) home,
    FakeAgentSession session,
    Size size,
    Brightness brightness,
    double scale, {
    Future<void> Function()? then,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => RepaintBoundary(
          key: key,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: home(session),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await then?.call();
    await tester.pump(const Duration(milliseconds: 600));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}-${scale == 1 ? '1' : scale}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size $scale');
  }

  Widget transcript(FakeAgentSession s) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Expanded(child: TranscriptView(session: s)),
          PromptDock(session: s),
        ],
      ),
    ),
  );

  FakeAgentSession session(AgentSessionState state, {int now = 43}) {
    statusNow = () => at(now);
    return FakeAgentSession(state: state);
  }

  List<Json> many() {
    final updates = <Json>[];
    for (var i = 0; i < 25; i++) {
      updates.add(launch('r$i', description: i == 3 ? long : 'Subagent number $i', type: i.isEven ? 'Explore' : 'general-purpose', status: 'in_progress'));
      if (i >= 4) updates.add(i % 7 == 0 ? toolUpdate('r$i', status: 'failed') : finished('r$i', seconds: 20 + i, tools: i, type: i.isEven ? 'Explore' : 'general-purpose'));
    }
    updates.add(childTool('askc', 'r0'));
    return updates;
  }

  AgentSessionState child() {
    final u = <Json>[launch('t', type: 'Explore', description: long, prompt: 'Read every file under lib/locale and list the places that lowercase a string before normalizing it. Report the file, the line and why it matters for Hà Nội, Đà Nẵng and Huế.', status: 'in_progress')];
    for (var i = 0; i < 24; i++) {
      u
        ..add(childTool('c$i', 't', title: 'Grep locale_$i', status: 'in_progress'))
        ..add({...toolUpdate('c$i', parent: 't', status: 'completed', tool: 'Grep')})
        ..add(childText('t', 'Checked file $i: nothing yet.\n\n', id: 'm$i'));
    }
    u.add(childText('t', 'Found the call in `lib/locale/parse.dart`.', id: 'last'));
    return play(u, from: stateWith(items: [userAt('uu', 'earlier', 0), agentAt('aa', 'ok', 1)]));
  }

  Widget sheetHost(FakeAgentSession s) => Scaffold(body: SafeArea(child: TranscriptView(session: s)));

  // name -> (session, home, action)
  final scenarios = <String, (FakeAgentSession Function(), Widget Function(FakeAgentSession), Future<void> Function(WidgetTester)?)>{
    'card-running': (
      () => session(play([launch('t', type: 'Explore', status: 'in_progress'), childTool('c', 't')])),
      transcript,
      null,
    ),
    'card-finished-open': (
      () => session(
        play(
          [launch('t', type: 'Explore', prompt: 'Find where the locale is lowercased.', status: 'in_progress'), finished('t', text: 'The call is in **lib/locale/parse.dart** line 42.\n\n- it lowercases first\n- then normalizes\n\n```dart\ns.toLowerCase();\n```')],
          active: false,
        ),
      ),
      transcript,
      (t) async {
        await t.tap(find.textContaining('Worked', findRichText: true));
        await t.pump(const Duration(milliseconds: 400));
        await t.tap(find.text('Explore the parser'));
        await t.pump(const Duration(milliseconds: 400));
      },
    ),
    'card-failed': (
      () => session(play([launch('t', type: 'Explore', status: 'in_progress'), childTool('c', 't'), toolUpdate('t', status: 'failed')], active: false)),
      transcript,
      null,
    ),
    'card-waiting-dock': (
      () => session(
        play([launch('t', type: 'Explore', status: 'in_progress'), childTool('c', 't')]).withPending(PendingPermission(1, askFor('c'))),
      ),
      transcript,
      null,
    ),
    'parallel-3': (
      () => session(
        play([
          launch('a', description: 'Check the parser', type: 'Explore', status: 'in_progress'),
          launch('b', description: long, type: 'general-purpose', status: 'in_progress'),
          launch('c', description: 'Đọc tài liệu về chuẩn hóa Unicode', type: 'Explore', status: 'in_progress'),
          childTool('x', 'a'),
          finished('c'),
        ]),
      ),
      transcript,
      null,
    ),
    'omp-group': (
      () => session(
        play(ompTask('call', [ompProgress(0, 'Alpha', 'running'), ompProgress(1, 'Beta', 'pending', extra: {'retryState': {'attempt': 2, 'maxAttempts': 5, 'delayMs': 8000, 'errorMessage': '429 rate limited', 'startedAt': 1}})])),
      ),
      transcript,
      null,
    ),
    'roster-25': (
      () => session(play(many()).withPending(PendingPermission(1, askFor('askc')))),
      (s) => Scaffold(body: SafeArea(child: Column(children: [SubagentsChip(session: s), Expanded(child: TranscriptView(session: s))]))),
      (t) async {
        await t.tap(find.textContaining('waiting for you'));
        await t.pump(const Duration(milliseconds: 400));
      },
    ),
    'drill-in': (
      () => session(child()),
      (s) => SubagentRunScreen(session: s, runId: 't'),
      null,
    ),
    'summary-omp': (
      () => session(play(ompTask('call', [ompProgress(0, 'Alpha', 'running')]))),
      (s) => SubagentRunScreen(session: s, runId: 'call#0'),
      null,
    ),
    'summary-omp-failed': (
      () => session(
        play(
          ompTask('call', [ompProgress(0, 'Beta', 'failed')], results: [
            {'index': 0, 'id': 'Beta', 'agent': 'scout', 'exitCode': 1, 'output': 'Partial notes:\n\n- parser.dart\n- locale.dart', 'error': 'Provider quota exhausted', 'durationMs': 9000},
          ], status: 'completed'),
          active: false,
        ),
      ),
      (s) => SubagentRunScreen(session: s, runId: 'call#0'),
      null,
    ),
    'overview-full': (
      () => session(overviewState()),
      sheetHost,
      (t) async {
        unawaited(showSessionOverview(t.element(find.byType(TranscriptView)), t.widget<TranscriptView>(find.byType(TranscriptView)).session));
        await t.pump(const Duration(milliseconds: 400));
      },
    ),
    'overview-min': (
      () => session(stateWith(items: [userAt('u', 'Say hi', 0)])),
      sheetHost,
      (t) async {
        unawaited(showSessionOverview(t.element(find.byType(TranscriptView)), t.widget<TranscriptView>(find.byType(TranscriptView)).session));
        await t.pump(const Duration(milliseconds: 400));
      },
    ),
    'bar-context': (
      () => session(const AgentSessionState('s1').apply(parse({'sessionUpdate': 'usage_update', 'used': 182000, 'size': 200000}))),
      (s) => Scaffold(body: SessionBar(session: s)),
      null,
    ),
  };

  for (final entry in scenarios.entries) {
    for (final brightness in Brightness.values) {
      for (final (size, scale) in [(const Size(412, 892), 1.0), (const Size(320, 640), 1.6)]) {
        testWidgets('${entry.key} ${brightness.name} ${size.width.toInt()} x$scale', (tester) async {
          final (make, home, action) = entry.value;
          await shoot(tester, entry.key, home, make(), size, brightness, scale, then: action == null ? null : () => action(tester));
        });
      }
    }
  }
}
