import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_made.dart' show MadeKind;
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart' show SubagentInfo;
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink, SubagentEntry, SubagentState;
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/files/photo_thumbs.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:herdr_mobile/ui/features/web/web_preview_screen.dart';
import 'package:image/image.dart' as img;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/fake_webview.dart';
import '../support/shot.dart' show loadAppFonts;

class _Launcher extends UrlLauncherPlatform {
  final opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return true;
  }
}

TranscriptItem _say(String text) => TranscriptMessage(key: 'm$text', role: MessageRole.agent, blocks: [TextBlock(text)]);

TranscriptItem _wrote(String path) => TranscriptTool(
      ToolCall(
        toolCallId: 't$path',
        kind: ToolKind.edit,
        status: ToolStatus.completed,
        content: [ToolDiff(path: path, newText: '<h1>x</h1>')],
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Taps a chip as a person would: the row is swiped first when it is past the edge.
Future<void> tapChip(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text(label));
}

void main() {
  // The fonts are per engine, and files that load Inter change them for the
  // files sharing the engine (--experimental-faster-testing): load them here
  // so the layout below never depends on which file ran first.
  setUpAll(loadAppFonts);

  late FakeTransport transport;
  late FakeFs fs;
  late _Launcher launcher;
  late FakeWebView web;
  late FleetRepository fleet;

  var sessions = 0;
  FakeAgentSession session(List<TranscriptItem> items, {String? key}) {
    final machine = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u'),
      api: HerdrApi(transport..fs = fs),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );
    // The sheet remembers its tab per session key: every test is its own session.
    return FakeAgentSession(state: AgentSessionState('s', items: items), machine: machine, key: key ?? 'm/k${sessions++}');
  }

  Future<void> pumpBar(WidgetTester tester, FakeAgentSession s, {Size size = const Size(412, 892)}) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(withFleet(fleet, MaterialApp(theme: AppTheme.light(), home: Scaffold(body: SessionBar(session: s)))));
    await _settle(tester);
  }

  setUp(() {
    transport = FakeTransport();
    fs = FakeFs()..addFile('/home/dev/payments-api/reports/q3.html', '<h1>q3</h1>');
    launcher = _Launcher();
    web = FakeWebView.install();
    fleet = emptyFleet();
    addTearDown(fleet.dispose);
    UrlLauncherPlatform.instance = launcher;
  });

  testWidgets('a session that has put nothing on the web has no chip', (tester) async {
    await pumpBar(tester, session([_say('Refactored the ledger, no pages.')]));
    expect(find.text('Made'), findsNothing);
  });

  testWidgets('the chip counts what the transcript holds, and a new link appears in it', (tester) async {
    final s = session([_say('Serving http://localhost:5173/'), _wrote('/home/dev/payments-api/reports/q3.html')]);
    await pumpBar(tester, s);
    expect(find.text('Made'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    s.update((st) => AgentSessionState('s', items: [...st.items, _say('and http://localhost:8000/docs')]));
    await _settle(tester);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('the sheet lists them newest first; a server says only what is known', (tester) async {
    final s = session([
      _say('Serving http://localhost:5173/'),
      _say('API on http://localhost:8000/docs'),
      _wrote('/home/dev/payments-api/reports/q3.html'),
    ]);
    s.setBackground(
      BackgroundWork(
        tasks: [
          const BackgroundTask(id: 'bg1', kind: BackgroundKind.shell, status: BackgroundStatus.running, title: 'vite --port 5173'),
          const BackgroundTask(id: 'bg2', kind: BackgroundKind.shell, status: BackgroundStatus.finished, title: 'uvicorn app:app --port 8000'),
        ],
      ),
    );
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);

    expect(find.text('Made in this session'), findsOneWidget);
    expect(find.text('q3.html'), findsOneWidget, reason: 'opens on the page: the newest kind that is not a server');
    expect(find.text('reports/'), findsOneWidget);
    await tapChip(tester, 'Servers');
    await _settle(tester);
    final ys = [for (final t in ['localhost:8000/docs', 'localhost:5173']) tester.getTopLeft(find.text(t)).dy];
    expect(ys, orderedEquals([...ys]..sort()), reason: 'newest first');
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('Stopped'), findsOneWidget);
  });

  testWidgets('a server opens in herdr through the connection, a page from its own folder', (tester) async {
    final s = session([_say('Serving http://localhost:5173/app'), _wrote('/home/dev/payments-api/reports/q3.html')]);
    await pumpBar(tester, s);

    await tester.tap(find.text('Made'));
    await _settle(tester);
    await tapChip(tester, 'Servers');
    await _settle(tester);
    await tester.tap(find.text('localhost:5173/app'));
    await _settle(tester);
    expect(find.text('Made in this session'), findsNothing, reason: 'the sheet goes first');
    expect(find.byType(WebPreviewScreen), findsOneWidget);
    expect(transport.webBridges.single, isA<PortForward>().having((p) => p.port, 'port', 5173));
    expect(web.loaded.first.queryParameters['to'], '/app');
    expect(launcher.opened, isEmpty, reason: 'not the phone\'s browser');

    await tester.tap(find.byTooltip('Back'));
    await _settle(tester);
    expect(find.byType(WebPreviewScreen), findsNothing);
    await tester.pump(const Duration(seconds: 1)); // the bar's rows settle before they take a tap
    await tester.tap(find.text('Made'));
    await _settle(tester);
    await tapChip(tester, 'Pages');
    await _settle(tester);
    await tester.tap(find.text('q3.html'));
    await _settle(tester);
    expect(transport.webBridges.last, isA<StaticSite>().having((p) => p.root, 'root', '/home/dev/payments-api/reports'));
    expect(web.loaded.last.path, '/q3.html', reason: 'the page itself, after the entry');
  });

  testWidgets('a page the agent named that is not on the machine says so', (tester) async {
    final s = session([_say('I wrote reports/gone.html for you.')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);

    await tester.tap(find.text('gone.html'));
    await _settle(tester);

    expect(find.text('gone.html is not on the machine any more.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget, reason: 'said on the page\'s screen, with a way on');
    expect(web.loaded, isEmpty);
  });

  BackgroundWork runningVite() => BackgroundWork(
        tasks: const [BackgroundTask(id: 'bg1', kind: BackgroundKind.shell, status: BackgroundStatus.running, title: 'vite --port 5173')],
      );

  testWidgets('a saved copy or a link that is down does not claim anything runs', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')]);
    s.setBackground(runningVite());
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('Running'), findsOneWidget);

    s.setSavedCopy(DateTime(2026, 5, 20, 6, 31));
    await _settle(tester);
    expect(find.text('Running'), findsNothing);
    expect(find.text('Seen'), findsOneWidget);

    s.setSavedCopy(null);
    s.setLink(AgentLink.reconnecting);
    await _settle(tester);
    expect(find.text('Running'), findsNothing);
  });

  testWidgets('rows do not move while the sheet is open; a link that arrives is there the next time', (tester) async {
    final s = session([_say('Serving http://localhost:5173/'), _say('API http://localhost:8000/docs')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    final before = tester.getTopLeft(find.text('localhost:5173')).dy;

    s.update((st) => AgentSessionState('s', items: [...st.items, _say('Storybook http://localhost:6006/'), _say('again http://localhost:5173/x')]));
    await _settle(tester);

    expect(tester.getTopLeft(find.text('localhost:5173/x')).dy, before, reason: 'same row, same place, newest path');
    expect(find.text('localhost:6006'), findsNothing);

    await tester.tapAt(const Offset(200, 20));
    await _settle(tester);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('localhost:6006'), findsOneWidget);
    expect(tester.getTopLeft(find.text('localhost:5173/x')).dy, lessThan(tester.getTopLeft(find.text('localhost:6006')).dy), reason: 'newest first again');
  });

  testWidgets('a port that is not a web server is not opened from the list, and says why', (tester) async {
    final s = session([_say('The database is on http://localhost:5432/ and Docker on localhost:2375')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('PostgreSQL, not a web page'), findsOneWidget);

    await tester.tap(find.text('localhost:5432'));
    await _settle(tester);

    expect(transport.webBridges, isEmpty);
    expect(launcher.opened, isEmpty);
    expect(find.textContaining('That is a PostgreSQL port'), findsOneWidget);
  });

  testWidgets('a page on a machine without files is dimmed with its reason, not a surprise after the tap', (tester) async {
    fs = FakeFs();
    final s = session([_wrote('/home/dev/payments-api/reports/q3.html')]);
    transport.fs = null;
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('Files are not available on this machine'), findsOneWidget);
  });

  testWidgets('a tap shows the page\'s screen at once, while the connection is made', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    final gate = Completer<void>();
    transport.webGate = gate;
    await tester.tap(find.text('localhost:5173'));
    await _settle(tester);
    expect(find.byType(WebPreviewScreen), findsOneWidget);
    expect(find.text('localhost:5173'), findsOneWidget, reason: 'the address, until the page has a title');
    expect(web.loaded, isEmpty);

    gate.complete();
    await _settle(tester);
    expect(transport.webBridges, hasLength(1));
    expect(web.loaded, isNotEmpty);
  });

  testWidgets('a name that hides itself is shown with its characters made visible', (tester) async {
    final s = session([_wrote('/home/dev/payments-api/safe\u202Egpj.html')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.textContaining('\u202E'), findsNothing);
    expect(find.textContaining('U+202E'), findsOneWidget);
  });

  testWidgets('beside the subagents chip on a small phone, the Made chip wraps under it instead of shrinking it', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')])
      ..observed = true
      ..roster = const [
        SubagentEntry(info: SubagentInfo(name: 'PongReply'), state: SubagentState.running),
        SubagentEntry(info: SubagentInfo(name: 'Other'), state: SubagentState.finished),
      ];
    tester.view.physicalSize = const Size(320, 640) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)), child: child!),
        home: Scaffold(body: SessionBar(session: s)),
      ),
    );
    await _settle(tester);

    expect(tester.takeException(), isNull);
    final subagents = tester.getRect(find.text('1 of 2 running'));
    final web = tester.getRect(find.text('Made'));
    expect(web.right, lessThanOrEqualTo(320));
    // Whole words, not an ellipsis: never a pixel width, which depends on the
    // fonts. Fonts are per engine, and files that load Inter change them for
    // the files sharing the engine (--experimental-faster-testing).
    expect(tester.renderObject<RenderParagraph>(find.text('1 of 2 running')).didExceedMaxLines, isFalse, reason: 'its words are whole');
    expect(find.text('1 of 2 running'), findsOneWidget);
    expect(web.top >= subagents.bottom - 1 || web.left >= subagents.right, isTrue, reason: 'beside it or under it, never over it');
  });

  // ---- kinds, tabs, the picture grid ----

  const base = '/home/dev/payments-api';

  Uint8List png(int hue) {
    final image = img.Image(width: 96, height: 72);
    for (final p in image) {
      p.setRgb((60 + p.x + hue) % 256, (200 - p.y + hue) % 256, (90 + hue) % 256);
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  // Through the real scanner: a created file, "I saved ..." in the agent's words.
  TranscriptItem page(String name) => _wrote('$base/reports/$name');
  TranscriptItem doc(String name) => _wrote('$base/notes/$name');
  TranscriptItem picture(String name) => _say('I saved screenshots/$name');

  void onMachine(Iterable<String> paths) {
    for (final p in paths) {
      fs.addFile(p, p.endsWith('.png') ? png(p.length) : 'x');
    }
  }

  // 3 pages, 4 pictures (newest), 2 docs, a server.
  List<TranscriptItem> mixed() {
    onMachine([
      for (final n in ['one.html', 'two.html', 'three.html']) '$base/reports/$n',
      for (final n in ['plan.md', 'spec.pdf']) '$base/notes/$n',
      for (final n in ['a.png', 'b.png', 'c.png', 'd.png']) '$base/screenshots/$n',
    ]);
    return [
      _say('Serving http://localhost:5173/'),
      page('one.html'),
      page('two.html'),
      doc('plan.md'),
      page('three.html'),
      doc('spec.pdf'),
      picture('a.png'),
      picture('b.png'),
      picture('c.png'),
      picture('d.png'),
    ];
  }

  Future<void> openSheet(WidgetTester tester, FakeAgentSession s, {Size size = const Size(412, 892)}) async {
    await pumpBar(tester, s, size: size);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    // Thumbnails decode on the engine's real clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> closeSheet(WidgetTester tester) async {
    await tester.tapAt(const Offset(200, 20));
    await _settle(tester);
  }

  /// For a sheet that fills the screen, where there is no barrier to tap.
  Future<void> popSheet(WidgetTester tester) async {
    Navigator.of(tester.element(find.text('Made in this session'))).pop();
    await _settle(tester);
  }

  bool selected(WidgetTester tester, String label) =>
      tester.getSemantics(find.text(label)).flagsCollection.isSelected == Tristate.isTrue;

  testWidgets('with two kinds or more the sheet has a tab for each, with its count, and never one for a kind with nothing', (tester) async {
    final handle = tester.ensureSemantics();
    onMachine(['$base/reports/one.html', '$base/notes/plan.md']);
    await openSheet(tester, session([page('one.html'), page('two.html'), doc('plan.md')]));

    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('Docs'), findsOneWidget);
    expect(find.text('Pictures'), findsNothing);
    expect(find.text('2'), findsOneWidget, reason: 'two pages');
    expect(find.text('1'), findsOneWidget, reason: 'one doc');
    handle.dispose();
  });

  testWidgets('one kind only: no tabs, just its rows', (tester) async {
    onMachine(['$base/reports/one.html']);
    await openSheet(tester, session([page('one.html'), page('two.html')]));

    expect(find.byType(AppChip), findsNWidgets(1), reason: 'only the Made chip behind the sheet');
    expect(find.text('Pages'), findsNothing);
    expect(find.text('one.html'), findsOneWidget);
    expect(find.text('two.html'), findsOneWidget);
  });

  testWidgets('only servers: no tabs, the servers', (tester) async {
    await openSheet(tester, session([_say('Serving http://localhost:5173/')]));
    expect(find.text('Servers'), findsNothing);
    expect(find.text('localhost:5173'), findsOneWidget);
  });

  testWidgets('servers and one other kind: two chips, opening on the other', (tester) async {
    onMachine(['$base/reports/one.html']);
    await openSheet(tester, session([_say('Serving http://localhost:5173/'), page('one.html')]));
    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('one.html'), findsOneWidget);
    expect(find.text('localhost:5173'), findsNothing);
  });

  testWidgets('it opens on the kind of the newest thing made, with exactly that tab selected', (tester) async {
    final handle = tester.ensureSemantics();
    await openSheet(tester, session(mixed()));

    expect(selected(tester, 'Pictures'), isTrue);
    expect(selected(tester, 'Pages'), isFalse);
    expect(selected(tester, 'Docs'), isFalse);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('d.png'), findsOneWidget);
    expect(find.text('one.html'), findsNothing, reason: 'the pages are on their own tab');
    handle.dispose();
  });

  testWidgets('a tab shows only its kind, and a tap on the selected one changes nothing', (tester) async {
    await openSheet(tester, session(mixed()));

    await tapChip(tester, 'Docs');
    await _settle(tester);
    expect(find.text('plan.md'), findsOneWidget);
    expect(find.text('spec.pdf'), findsOneWidget);
    expect(find.text('d.png'), findsNothing);
    expect(find.text('one.html'), findsNothing);

    await tapChip(tester, 'Docs');
    await _settle(tester);
    expect(find.text('plan.md'), findsOneWidget);

    await tapChip(tester, 'Pages');
    await _settle(tester);
    expect(find.text('one.html'), findsOneWidget);
    expect(find.text('plan.md'), findsNothing);
  });

  testWidgets('Servers is a chip that lists them; its dot shows only while one runs; the sheet never opens on it when something else exists', (tester) async {
    final s = session(mixed(), key: 'm/servers');
    await openSheet(tester, s);
    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('localhost:5173'), findsNothing, reason: 'opens on the pictures, the newest kind');
    expect(find.byType(LinkDot), findsNothing, reason: 'nothing runs');

    await tapChip(tester, 'Servers');
    await _settle(tester);
    expect(find.text('localhost:5173'), findsOneWidget);
    expect(find.text('d.png'), findsNothing);
    expect(tester.getTopLeft(find.text('Servers')).dy, lessThan(tester.getTopLeft(find.text('localhost:5173')).dy), reason: 'chips lead the sheet');

    s.setBackground(runningVite());
    await _settle(tester);
    expect(find.byType(LinkDot), findsNWidgets(2), reason: 'the row\'s dot and the chip\'s');
    expect(find.descendant(of: find.byType(Segmented<MadeKind>), matching: find.byType(LinkDot)), findsOneWidget);
  });

  testWidgets('the sheet opens on the tab it was left on; a kind that is gone falls back to the newest', (tester) async {
    final first = session(mixed(), key: 'm/remembered');
    await openSheet(tester, first);
    await tapChip(tester, 'Docs');
    await _settle(tester);
    await closeSheet(tester);

    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('plan.md'), findsOneWidget, reason: 'Docs again, though pictures are newest');
    await closeSheet(tester);

    // The same session, now with no documents: back to the newest kind.
    first.update((st) => AgentSessionState('s', items: [for (final i in st.items) if (i is! TranscriptTool || !i.call.toolCallId.contains('/notes/')) i]));
    await _settle(tester);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('Docs'), findsNothing);
    expect(find.text('d.png'), findsOneWidget);
  });

  testWidgets('pictures are a grid three across with the file name under each', (tester) async {
    await openSheet(tester, session(mixed()));

    // Newest first: d, c, b on the first row, a starts the next.
    final d = tester.getTopLeft(find.text('d.png'));
    final c = tester.getTopLeft(find.text('c.png'));
    final b = tester.getTopLeft(find.text('b.png'));
    final a = tester.getTopLeft(find.text('a.png'));
    expect(c.dx, greaterThan(d.dx));
    expect(b.dx, greaterThan(c.dx));
    expect(d.dy == c.dy && c.dy == b.dy, isTrue, reason: 'three on a row');
    expect(a.dy, greaterThan(b.dy));
    expect(a.dx, d.dx, reason: 'the fourth starts the next row');
    expect(find.byType(RawImage), findsNWidgets(4), reason: 'the real pictures, small');
  });

  testWidgets('a picture that is gone from the machine is a quiet tile, not a hole or an error', (tester) async {
    onMachine(['$base/screenshots/here.png']);
    await openSheet(tester, session([picture('here.png'), picture('gone.png')]));

    expect(find.text('gone.png'), findsOneWidget);
    expect(find.byIcon(LucideIcons.imageOff), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap on a picture opens the photo viewer after the sheet closes; on a missing one it says so', (tester) async {
    onMachine(['$base/screenshots/here.png']);
    await openSheet(tester, session([picture('gone.png'), picture('here.png')]));

    await tester.tap(find.text('gone.png'));
    await _settle(tester);
    expect(find.text('Made in this session'), findsNothing);
    expect(find.text('gone.png is not on the machine any more.'), findsOneWidget);
    expect(find.byType(PhotoViewer), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    await tester.tap(find.text('Made'));
    await _settle(tester);
    await tester.tap(find.text('here.png'));
    await _settle(tester);
    expect(find.text('Made in this session'), findsNothing);
    expect(find.byType(PhotoViewer), findsOneWidget);
    expect(find.textContaining('Opening'), findsNothing, reason: 'no toast stands over the photo');
  });

  testWidgets('a tap on a document opens it in the file viewer', (tester) async {
    await openSheet(tester, session(mixed()));
    await tapChip(tester, 'Docs');
    await _settle(tester);
    await tester.tap(find.text('plan.md'));
    await _settle(tester);

    expect(find.text('Made in this session'), findsNothing);
    expect(find.byType(FileViewerScreen), findsOneWidget);
    expect(launcher.opened, isEmpty);
  });

  testWidgets('a page opens in herdr from its tab', (tester) async {
    await openSheet(tester, session(mixed()));
    await tapChip(tester, 'Pages');
    await _settle(tester);
    await tester.tap(find.text('two.html'));
    await _settle(tester);

    expect(transport.webBridges.last, isA<StaticSite>().having((p) => p.root, 'root', '$base/reports'));
    expect(web.loaded.first.queryParameters['to'], '/two.html');
  });

  testWidgets('a long list shows the first 60 and a row for the rest; tapping it shows the next batch', (tester) async {
    onMachine([for (var i = 0; i < 70; i++) '$base/reports/p$i.html']);
    await openSheet(tester, session([for (var i = 0; i < 70; i++) page('p$i.html'), doc('plan.md')]));
    await tapChip(tester, 'Pages');
    await _settle(tester);

    expect(find.textContaining('.html', skipOffstage: false), findsNWidgets(60));
    expect(find.text('10 more', skipOffstage: false), findsOneWidget);
    await tester.ensureVisible(find.text('10 more'));
    await tester.pump(); // a list lays out its new offset on the next frame
    await tester.tap(find.text('10 more'));
    await _settle(tester);
    expect(find.textContaining('.html', skipOffstage: false), findsNWidgets(70));
    expect(find.textContaining('more', skipOffstage: false), findsNothing);
  });

  testWidgets('the grid builds only the tiles near the viewport, asks the machine only about those, and shows the next batch on request', (tester) async {
    onMachine([for (var i = 0; i < 30; i++) '$base/screenshots/s$i.png']);
    final held = PhotoThumbs.shared.length;
    await openSheet(tester, session([page('one.html'), for (var i = 0; i < 30; i++) picture('s$i.png')]), size: const Size(360, 600));

    int stats() => fs.calls.where((c) => c.startsWith('stat $base/screenshots/')).length;
    final built = find.textContaining('.png', skipOffstage: false).evaluate().length;
    expect(built, inInclusiveRange(3, 23), reason: 'the rows at the viewport and a little beyond, not all 24');
    expect(stats(), lessThanOrEqualTo(built), reason: 'nothing for tiles that were never built');
    expect(PhotoThumbs.shared.length - held, lessThanOrEqualTo(built), reason: 'a thumbnail is asked for only by a tile that exists');
    expect(find.text('6 more', skipOffstage: false), findsNothing);

    final list = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('6 more'), 300, scrollable: list);
    await tester.ensureVisible(find.text('6 more'));
    await tester.pump(); // a list lays out its new offset on the next frame
    await tester.tap(find.text('6 more'));
    await _settle(tester);
    expect(find.text('6 more', skipOffstage: false), findsNothing);
    await tester.scrollUntilVisible(find.text('s0.png'), 300, scrollable: list);
    await _settle(tester);
    expect(stats(), 30, reason: 'every picture once it has been scrolled to, none twice');
  });

  testWidgets('closing the sheet stops the pictures still waiting for their turn', (tester) async {
    onMachine([for (var i = 0; i < 30; i++) '$base/screenshots/s$i.png']);
    final gate = Completer<void>();
    fs.gate = gate;
    await pumpBar(tester, session([for (var i = 0; i < 30; i++) picture('s$i.png')]), size: const Size(360, 600));
    await tester.tap(find.text('Made'));
    await _settle(tester);
    await popSheet(tester);

    gate.complete();
    await _settle(tester);
    final stats = fs.calls.where((c) => c.startsWith('stat $base/screenshots/')).length;
    expect(stats, lessThanOrEqualTo(4), reason: 'only the few that were already being asked');
  });

  testWidgets('a picture the machine could not be asked about is not shown as gone, and a tap asks again', (tester) async {
    onMachine(['$base/screenshots/here.png']);
    fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'timed out');
    await openSheet(tester, session([picture('here.png')]));
    expect(find.byIcon(LucideIcons.imageOff), findsNothing, reason: 'a link that is down says nothing about the file');
    expect(find.byType(RawImage), findsNothing);

    fs.fail = null;
    await tester.tap(find.text('here.png'));
    // The fetch and the decode are real work off the test clock: wait for the
    // picture, not for a fixed time (the first decode in a process is slow,
    // and which test comes first depends on the shard).
    for (var i = 0; i < 100 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(RawImage), findsOneWidget, reason: 'the tap asked the machine again');
    expect(find.byType(PhotoViewer), findsNothing, reason: 'and did not open anything yet');
  });

  testWidgets('the switch stays where it is whatever tab is open, and while a long list scrolls', (tester) async {
    onMachine([for (var i = 0; i < 30; i++) '$base/screenshots/s$i.png', '$base/reports/one.html']);
    await openSheet(tester, session([_say('Serving http://localhost:5173/'), page('one.html'), for (var i = 0; i < 30; i++) picture('s$i.png')]));

    // Only how far from the top: the switch may scroll sideways to its cell.
    double top(String label) => tester.getRect(find.text(label)).top;
    final servers = top('Servers');
    final pictures = top('Pictures');
    expect(tester.getSize(find.byType(CustomScrollView)).height, lessThanOrEqualTo(892 * 0.6 + 0.5), reason: 'a long list scrolls inside the sheet, which does not fill the screen');

    await tester.drag(find.text('s27.png'), const Offset(0, -300));
    await _settle(tester);
    expect(top('Pictures'), pictures, reason: 'the switch does not scroll away with a long list');

    await tapChip(tester, 'Servers');
    await _settle(tester);
    expect(find.text('localhost:5173'), findsOneWidget);
    expect(top('Servers'), servers, reason: 'a short tab after a tall one');
    expect(top('Pictures'), pictures);

    await tapChip(tester, 'Pictures');
    await _settle(tester);
    expect(top('Servers'), servers, reason: 'and a tall one after a short one');
  });

  testWidgets('a running server is said, not only shown as a dot', (tester) async {
    final handle = tester.ensureSemantics();
    final s = session(mixed(), key: 'm/says-running');
    await openSheet(tester, s);
    expect(tester.getSemantics(find.text('Servers')).label, 'Servers, 1');

    s.setBackground(runningVite());
    await _settle(tester);
    expect(tester.getSemantics(find.text('Servers')).label, 'Servers, 1, running');
    handle.dispose();
  });

  testWidgets('a machine without files: pages, pictures and documents are dimmed with the reason, and nothing is asked', (tester) async {
    final s = session(mixed());
    transport.fs = null;
    await openSheet(tester, s);

    expect(find.text('Files are not available on this machine'), findsOneWidget, reason: 'said once over the grid');
    expect(find.byType(RawImage), findsNothing);
    await tester.tap(find.text('a.png'));
    await _settle(tester);
    expect(find.text('Made in this session'), findsOneWidget, reason: 'inert');

    await tapChip(tester, 'Docs');
    await _settle(tester);
    expect(find.text('Files are not available on this machine'), findsNWidgets(2), reason: 'under each row');
    await tester.tap(find.text('plan.md'));
    await _settle(tester);
    expect(find.text('Made in this session'), findsOneWidget);
    expect(find.byType(FileViewerScreen), findsNothing);
  });

  testWidgets('rows keep their place across tabs while the sheet is open; what arrives is there the next time', (tester) async {
    final s = session(mixed(), key: 'm/frozen');
    await openSheet(tester, s);
    final pictureY = tester.getTopLeft(find.text('d.png')).dy;

    s.update((st) => AgentSessionState('s', items: [...st.items, picture('e.png'), page('late.html'), doc('late.md')]));
    await _settle(tester);
    expect(find.text('e.png'), findsNothing);
    expect(tester.getTopLeft(find.text('d.png')).dy, pictureY, reason: 'nothing moves');

    await tapChip(tester, 'Pages');
    await _settle(tester);
    expect(find.text('late.html'), findsNothing);
    expect(find.text('3'), findsOneWidget, reason: 'still the three that were here');
    await tapChip(tester, 'Docs');
    await _settle(tester);
    expect(find.text('late.md'), findsNothing);

    await closeSheet(tester);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('late.md'), findsOneWidget, reason: 'Docs is where it was left, and now it holds the new one');
    await tapChip(tester, 'Pictures');
    await _settle(tester);
    expect(find.text('e.png'), findsOneWidget);
  });

  testWidgets('nothing overflows at 320 dp and text 1.6: the switch scrolls sideways, the names stay on one line', (tester) async {
    final s = session(mixed());
    tester.view.physicalSize = const Size(320, 640) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)), child: child!),
        home: Scaffold(body: SessionBar(session: s)),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('Made'));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Pictures'), findsOneWidget);
    expect(find.text('d.png'), findsOneWidget);

    // Left on Docs, which the switch may not show at this size: it opens with
    // the chosen cell in view, not hidden past the edge.
    await tester.drag(find.text('Pictures'), const Offset(-300, 0));
    await _settle(tester);
    await tapChip(tester, 'Docs');
    await _settle(tester);
    await closeSheet(tester);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    final docs = tester.getRect(find.text('Docs'));
    expect(docs.left, greaterThanOrEqualTo(0));
    expect(docs.right, lessThanOrEqualTo(320));
    expect(tester.getSemantics(find.text('Docs')).flagsCollection.isSelected, Tristate.isTrue);
  });
}
