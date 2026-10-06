// Renders Continue and the Past sessions screen to PNGs for review, light and
// dark: the Continue strip (normal, narrow at 1.6x, working), three rows, two
// machines with a folder chip, 200 rows scrolled, the worst case (Vietnamese
// titles with a direction override, a 300-character folder, 320 wide at 1.6x),
// empty, cannot list, cannot reopen, loading and error. Off by default; it
// writes files:
//
//   HISTORY_SHOTS=1 flutter test test/ui/history_shots_test.dart
//
// Output: $HISTORY_SHOTS_DIR (default /tmp/history_shots)/<case>-<light|dark>.png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import 'history_support.dart';

void main() {
  if (Platform.environment['HISTORY_SHOTS'] == null) {
    test('history shots are off (set HISTORY_SHOTS=1)', () {}, skip: 'set HISTORY_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['HISTORY_SHOTS_DIR'] ?? '/tmp/history_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  const phone = Size(412, 892);
  const narrow = Size(320, 640);
  const dpr = 2.0;

  Future<void> capture(WidgetTester tester, GlobalKey key, String name, Brightness b) async {
    await tester.pump(const Duration(milliseconds: 400));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name-${b.name}.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${b.name}');
  }

  void bars(WidgetTester tester) {
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
  }

  // The folder the session ran in, the way a real one looks.
  final viet = 'Sửa lỗi đồng bộ dữ liệu người dùng \u202Eexe.txt ${'rất dài '.padRight(400, 'ệ')}';

  PastSessions many(int n) => remembered([
    for (var i = 0; i < n; i++)
      past(
        's$i',
        title: i % 7 == 3 ? null : 'Session $i: ${const ['fix the parser', 'review billing', 'migrate to Postgres', 'tidy the CLI'][i % 4]}',
        cwd: '/home/dev/${const ['payments-api', 'herdr-mobile', 'billing', 'thư-mục-mới'][i % 4]}',
        messages: i % 11 == 5 ? 0 : 6 + i * 3,
        ago: Duration(minutes: 3 + i * 47),
      ),
  ], more: n >= 200);

  // name -> (size, text scale, how to set the scene up, what to do after).
  final past3 = remembered([
    past('s1', title: 'Fix the parser for Hà Nội addresses', ago: const Duration(minutes: 5)),
    past('s2', title: 'Review the billing migration', cwd: '/srv/billing', ago: const Duration(hours: 3), messages: 82),
    past('s3', cwd: '/home/dev/herdr-mobile', ago: const Duration(days: 2), messages: 0),
  ]);

  final cases = <String, Future<void> Function(WidgetTester tester, Brightness b, GlobalKey key)>{};

  Future<void> pastCase(
    WidgetTester tester,
    Brightness b,
    GlobalKey key,
    String name, {
    required void Function(ScriptedSessions s) script,
    Size size = phone,
    double scale = 1,
    List<({String id, String label})> machines = const [(id: 'a', label: 'studio-mac')],
    String? cwd,
    Future<void> Function()? then,
  }) async {
    final e = await historyEnv(machines: machines);
    script(e.sessions);
    bars(tester);
    await pumpPast(tester, e, size: size, textScale: scale, brightness: b, cwd: cwd, boundary: key);
    await then?.call();
    await capture(tester, key, name, b);
    await e.tearDown(tester);
  }

  cases['past-3'] = (t, b, k) => pastCase(t, b, k, 'past-3', script: (s) => s.answers['omp'] = past3);
  cases['past-3-narrow-large'] = (t, b, k) =>
      pastCase(t, b, k, 'past-3-narrow-large', script: (s) => s.answers['omp'] = past3, size: narrow, scale: 1.6);
  cases['past-machines-folder'] = (t, b, k) => pastCase(
    t,
    b,
    k,
    'past-machines-folder',
    script: (s) => s.answers['omp'] = past3,
    machines: const [(id: 'a', label: 'studio-mac'), (id: 'b', label: 'build-box')],
    cwd: '/home/dev/payments-api',
  );
  cases['past-200-top'] = (t, b, k) => pastCase(t, b, k, 'past-200-top', script: (s) => s.answers['omp'] = many(200));
  cases['past-200-scrolled'] = (t, b, k) => pastCase(
    t,
    b,
    k,
    'past-200-scrolled',
    script: (s) => s.answers['omp'] = many(200),
    then: () async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -3600));
      await t.pump(const Duration(milliseconds: 600));
    },
  );
  cases['past-search'] = (t, b, k) => pastCase(
    t,
    b,
    k,
    'past-search',
    script: (s) => s.answers['omp'] = many(40),
    then: () async {
      await t.enterText(find.byType(TextField), 'billing');
      await t.pump(const Duration(milliseconds: 300));
    },
  );
  cases['past-worst-case'] = (t, b, k) => pastCase(
    t,
    b,
    k,
    'past-worst-case',
    size: narrow,
    scale: 1.6,
    script: (s) => s.answers['omp'] = remembered([
      past('w1', title: viet, cwd: '/home/${'đ' * 300}', messages: 1234567),
      past('w2', title: viet, ago: null, messages: null),
      past('w3', ago: const Duration(seconds: 3), messages: 0),
      for (var i = 0; i < 8; i++) past('w${i + 4}', title: 'Phiên số $i', cwd: '/home/dev/thư-mục-$i'),
    ], more: true),
  );
  cases['past-empty'] = (t, b, k) => pastCase(t, b, k, 'past-empty', script: (_) {});
  cases['past-cannot-list'] = (t, b, k) =>
      pastCase(t, b, k, 'past-cannot-list', script: (s) => s.answers['omp'] = remembered(const [], canList: false));
  cases['past-cannot-reopen'] = (t, b, k) => pastCase(
    t,
    b,
    k,
    'past-cannot-reopen',
    script: (s) => s.answers['omp'] = remembered(past3.sessions, canLoad: false),
  );
  cases['past-loading'] = (t, b, k) => pastCase(
    t,
    b,
    k,
    'past-loading',
    script: (s) => s.historyGate = Completer<void>().future,
  );
  cases['past-error'] = (t, b, k) => pastCase(
    t,
    b,
    k,
    'past-error',
    script: (s) => s.historyError = const AgentHostException('omp did not answer in time.'),
  );
  cases['past-offline'] = (t, b, k) => pastCase(t, b, k, 'past-offline', script: (_) {}, machines: const []);
  cases['past-resuming'] = (t, b, k) => pastCase(
    t,
    b,
    k,
    'past-resuming',
    script: (s) {
      s.answers['omp'] = past3;
      s.onResume = (_) => Completer<AgentSessionView>().future;
    },
    then: () async {
      await t.tap(find.text('Review the billing migration'));
      await t.pump(const Duration(milliseconds: 300));
    },
  );

  Future<void> continueCase(
    WidgetTester tester,
    Brightness b,
    GlobalKey key,
    String name, {
    Size size = phone,
    double scale = 1,
    String error = 'Claude Code exited with code 1.',
    bool tap = false,
  }) async {
    final session = FakeAgentSession(
      link: AgentLink.ended,
      error: error,
      state: stateWith(
        items: [
          userMsg('u1', 'Fix the Hà Nội locale bug in the parser and add a test.'),
          agentMsg('a1', 'I moved the call below `normalize()` and added a regression test.'),
        ],
      ),
    )..resumeTargetValue = const ResumeTarget(agent: 'claude', cwd: '/home/dev/payments-api', sessionId: 'sess-old');
    final e = await historyEnv();
    e.sessions.onResume = (_) => Completer<AgentSessionView>().future;
    bars(tester);
    await pumpUnder(
      tester,
      e,
      AgentSessionScreen(key: ObjectKey(session), session: session),
      size: size,
      textScale: scale,
      brightness: b,
      boundary: key,
    );
    await tester.pump(tapGuard);
    if (tap) {
      await tester.tap(find.widgetWithText(AppButton, 'Continue'));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await capture(tester, key, name, b);
    await e.tearDown(tester);
  }

  cases['continue'] = (t, b, k) => continueCase(t, b, k, 'continue');
  cases['continue-working'] = (t, b, k) => continueCase(t, b, k, 'continue-working', tap: true);
  cases['continue-narrow-large'] = (t, b, k) => continueCase(t, b, k, 'continue-narrow-large', size: narrow, scale: 1.6);
  cases['continue-long-reason'] = (t, b, k) => continueCase(
    t,
    b,
    k,
    'continue-long-reason',
    size: narrow,
    error: 'The host restarted and took Claude Code with it, in the middle of a turn that had edited three files.',
  );

  for (final entry in cases.entries) {
    for (final b in Brightness.values) {
      testWidgets('${entry.key} ${b.name}', (tester) async {
        await entry.value(tester, b, GlobalKey());
      });
    }
  }
}
