@Tags(['timing'])
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_made.dart' show MadeKind;
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart' show SubagentInfo;
import 'package:herdr_mobile/data/repositories/agent_session.dart'
    show AgentLink, MadeReach, SubagentEntry, SubagentState;
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/support/deep_link.dart' show SessionLink, parseSessionLink;
import 'package:herdr_mobile/ui/features/agent_session/session_bar.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/files/photo_thumbs.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:herdr_mobile/ui/features/web/web_preview_screen.dart';
import 'package:image/image.dart' as img;
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

TranscriptItem _say(String text) =>
    TranscriptMessage(key: 'm$text', role: MessageRole.agent, blocks: [TextBlock(text)]);

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
    return FakeAgentSession(
      state: AgentSessionState('s', items: items),
      machine: machine,
      key: key ?? 'm/k${sessions++}',
    );
  }

  Future<void> pumpBar(WidgetTester tester, FakeAgentSession s, {Size size = const Size(412, 892)}) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      withFleet(
        fleet,
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: SessionBar(session: s)),
        ),
      ),
    );
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

  group('session options', () {
    Future<void> openOptions(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Session options'));
      await _settle(tester);
    }

    testWidgets('with nothing made the chip is absent but the way in stays, dimmed with its reason', (tester) async {
      await pumpBar(tester, session([_say('Refactored the ledger, no pages.')]));
      await openOptions(tester);
      expect(find.text('Made in this session'), findsOneWidget);
      expect(find.text('Nothing has come up yet'), findsOneWidget);

      await tester.tap(find.text('Made in this session'));
      await _settle(tester);
      expect(find.text('Nothing has come up yet'), findsOneWidget, reason: 'an inert row opens nothing');
    });

    testWidgets('once something is made the row opens the same sheet as the chip', (tester) async {
      await pumpBar(
        tester,
        session([_say('Serving http://localhost:5173/'), _wrote('/home/dev/payments-api/reports/q3.html')]),
      );
      await openOptions(tester);
      expect(find.text('Nothing has come up yet'), findsNothing);

      await tester.tap(find.text('Made in this session'));
      await _settle(tester);
      expect(find.text('q3.html'), findsOneWidget);
      expect(find.text('Copy session link'), findsNothing, reason: 'the options sheet is replaced, not stacked');
    });

    testWidgets('Copy session link puts the link the app opens on the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpBar(tester, session([_say('hi')], key: 'm/keeper 1'));
      await openOptions(tester);

      await tester.tap(find.text('Copy session link'));
      await _settle(tester);
      expect(copied, 'herdr://session/m/keeper%201');
      expect(parseSessionLink(copied), const SessionLink('m', 'keeper 1'));
      expect(find.text('Session link copied'), findsOneWidget);
    });
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
          const BackgroundTask(
            id: 'bg1',
            kind: BackgroundKind.shell,
            status: BackgroundStatus.running,
            title: 'vite --port 5173',
          ),
          const BackgroundTask(
            id: 'bg2',
            kind: BackgroundKind.shell,
            status: BackgroundStatus.finished,
            title: 'uvicorn app:app --port 8000',
          ),
        ],
      ),
    );
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);

    expect(find.text('Made in this session'), findsOneWidget);
    expect(find.text('q3.html'), findsOneWidget, reason: 'opens on the page: the newest kind that isn’t a server');
    expect(find.text('reports/'), findsOneWidget);
    await tapChip(tester, 'Apps');
    await _settle(tester);
    // Named by what runs there, newest first; the state only as far as it is known.
    final ys = [
      for (final t in ['uvicorn app:app --port 8000', 'vite --port 5173']) tester.getTopLeft(find.text(t)).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()), reason: 'newest first');
    expect(find.text('Port 5173 · Running'), findsOneWidget);
    expect(find.text('Port 8000 · Stopped'), findsOneWidget);
  });

  testWidgets('a server opens in herdr through the connection, a page from its own folder', (tester) async {
    final s = session([_say('Serving http://localhost:5173/app'), _wrote('/home/dev/payments-api/reports/q3.html')]);
    await pumpBar(tester, s);

    await tester.tap(find.text('Made'));
    await _settle(tester);
    await tapChip(tester, 'Apps');
    await _settle(tester);
    await tester.tap(find.text('App on port 5173'));
    await _settle(tester);
    expect(find.byType(WebPreviewScreen), findsOneWidget);
    expect(transport.webBridges.single, isA<PortForward>().having((p) => p.port, 'port', 5173));
    expect(web.loaded.first.queryParameters['to'], '/app');
    expect(launcher.opened, isEmpty, reason: 'not the phone’s browser');

    await tester.tap(find.byTooltip('Close page'));
    await _settle(tester);
    expect(find.byType(WebPreviewScreen), findsNothing);
    expect(find.text('Made in this session'), findsOneWidget, reason: 'Back lands on the list, not on the board');
    expect(find.text('App on port 5173'), findsOneWidget, reason: 'on the tab it was left on');
    await tester.pump(
      const Duration(seconds: 6),
    ); // the page's own toast ("Opened on port ...") stands over the bottom rows until it goes
    await tapChip(tester, 'Pages');
    await _settle(tester);
    await tester.tap(find.text('q3.html'));
    await _settle(tester);
    expect(
      transport.webBridges.last,
      isA<StaticSite>().having((p) => p.root, 'root', '/home/dev/payments-api/reports'),
    );
    expect(web.loaded.last.path, '/q3.html', reason: 'the page itself, after the entry');
  });

  testWidgets('a page the agent named that isn’t on the machine says so', (tester) async {
    final s = session([_say('I wrote reports/gone.html for you.')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);

    await tester.tap(find.text('gone.html'));
    await _settle(tester);

    expect(find.text('gone.html isn’t on the machine any more.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget, reason: 'said on the page’s screen, with a way on');
    expect(web.loaded, isEmpty);
  });

  BackgroundWork runningVite() => BackgroundWork(
    tasks: const [
      BackgroundTask(
        id: 'bg1',
        kind: BackgroundKind.shell,
        status: BackgroundStatus.running,
        title: 'vite --port 5173',
      ),
    ],
  );

  testWidgets('a saved copy or a link that is down doesn’t claim anything runs', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')]);
    s.setBackground(runningVite());
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('Port 5173 · Running'), findsOneWidget);

    s.setSavedCopy(DateTime(2026, 5, 20, 6, 31));
    await _settle(tester);
    expect(find.textContaining('Running'), findsNothing);
    expect(find.text('Port 5173 · Status unknown'), findsOneWidget);

    s.setSavedCopy(null);
    s.setLink(AgentLink.reconnecting);
    await _settle(tester);
    expect(find.textContaining('Running'), findsNothing);
  });

  testWidgets('rows do not move while the sheet is open; a link that arrives is there the next time', (tester) async {
    final s = session([_say('Serving http://localhost:5173/'), _say('API http://localhost:8000/docs')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    final before = tester.getTopLeft(find.text('App on port 5173')).dy;

    s.update(
      (st) => AgentSessionState(
        's',
        items: [...st.items, _say('Storybook http://localhost:6006/'), _say('again http://localhost:5173/x')],
      ),
    );
    await _settle(tester);

    expect(
      tester.getTopLeft(find.text('App on port 5173')).dy,
      before,
      reason: 'the rows that were there stay where they were',
    );
    expect(find.text('/x'), findsNothing);
    expect(find.text('App on port 6006'), findsNothing);

    await tester.tapAt(const Offset(200, 20));
    await _settle(tester);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('App on port 6006'), findsOneWidget);
    expect(find.text('/x'), findsOneWidget, reason: 'a page of an app is a chip under it, not a row of its own');
    expect(
      tester.getTopLeft(find.text('App on port 5173')).dy,
      lessThan(tester.getTopLeft(find.text('App on port 6006')).dy),
      reason: 'newest first again',
    );
  });

  testWidgets('a port that isn’t a web server isn’t opened from the list, and says why', (tester) async {
    final s = session([_say('The database is on http://localhost:5432/ and Docker on localhost:2375')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('Port 5432 · not a web page'), findsOneWidget);
    expect(find.text('Port 2375 · not a web page'), findsOneWidget);

    await tester.tap(find.text('PostgreSQL'));
    await _settle(tester);

    expect(transport.webBridges, isEmpty);
    expect(launcher.opened, isEmpty);
    expect(find.textContaining('That is a PostgreSQL port'), findsOneWidget);
    expect(find.text('Made in this session'), findsOneWidget, reason: 'the list stays for the next row');
  });

  testWidgets('a page on a machine without files is dimmed with its reason, not a surprise after the tap', (
    tester,
  ) async {
    fs = FakeFs();
    final s = session([_wrote('/home/dev/payments-api/reports/q3.html')]);
    transport.fs = null;
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    expect(find.text('Files are not available on this machine'), findsOneWidget);
  });

  testWidgets('a tap shows the page’s screen at once, while the connection is made', (tester) async {
    final s = session([_say('Serving http://localhost:5173/')]);
    await pumpBar(tester, s);
    await tester.tap(find.text('Made'));
    await _settle(tester);
    final gate = Completer<void>();
    transport.webGate = gate;
    await tester.tap(find.text('App on port 5173'));
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

  testWidgets('beside the subagents chip on a small phone, the Made chip wraps under it instead of shrinking it', (
    tester,
  ) async {
    final s = session([_say('Serving http://localhost:5173/')])
      ..observed = true
      ..roster = const [
        SubagentEntry(
          info: SubagentInfo(name: 'PongReply'),
          state: SubagentState.running,
        ),
        SubagentEntry(
          info: SubagentInfo(name: 'Other'),
          state: SubagentState.finished,
        ),
      ];
    tester.view.physicalSize = const Size(320, 640) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(body: SessionBar(session: s)),
      ),
    );
    await _settle(tester);

    expect(tester.takeException(), isNull);
    final subagents = tester.getRect(find.text('1 running'));
    final web = tester.getRect(find.text('Made'));
    expect(web.right, lessThanOrEqualTo(320));
    // Whole words, not an ellipsis: never a pixel width, which depends on the
    // fonts. Fonts are per engine, and files that load Inter change them for
    // the files sharing the engine (--experimental-faster-testing).
    expect(
      tester.renderObject<RenderParagraph>(find.text('1 running')).didExceedMaxLines,
      isFalse,
      reason: 'its words are whole',
    );
    expect(find.text('1 running'), findsOneWidget);
    expect(
      web.top >= subagents.bottom - 1 || web.left >= subagents.right,
      isTrue,
      reason: 'beside it or under it, never over it',
    );
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

  testWidgets(
    'with two kinds or more the sheet has a tab for each, with its count, and never one for a kind with nothing',
    (tester) async {
      final handle = tester.ensureSemantics();
      onMachine(['$base/reports/one.html', '$base/notes/plan.md']);
      await openSheet(tester, session([page('one.html'), page('two.html'), doc('plan.md')]));

      expect(find.text('Pages'), findsOneWidget);
      expect(find.text('Docs'), findsOneWidget);
      expect(find.text('Pictures'), findsNothing);
      expect(find.text('2'), findsOneWidget, reason: 'two pages');
      expect(find.text('1'), findsOneWidget, reason: 'one doc');
      handle.dispose();
    },
  );

  testWidgets('one kind only: no tabs, just its rows', (tester) async {
    onMachine(['$base/reports/one.html']);
    await openSheet(tester, session([page('one.html'), page('two.html')]));

    expect(find.byType(AppChip), findsNWidgets(1), reason: 'only the Made chip behind the sheet');
    expect(find.text('Pages'), findsNothing);
    expect(find.text('one.html'), findsOneWidget);
    expect(find.text('two.html'), findsOneWidget);
  });

  testWidgets('only apps: no tabs, the apps', (tester) async {
    await openSheet(tester, session([_say('Serving http://localhost:5173/')]));
    expect(find.text('Apps'), findsNothing);
    expect(find.text('App on port 5173'), findsOneWidget);
  });

  testWidgets('apps and one other kind: two chips, opening on the other', (tester) async {
    onMachine(['$base/reports/one.html']);
    await openSheet(tester, session([_say('Serving http://localhost:5173/'), page('one.html')]));
    expect(find.text('Apps'), findsOneWidget);
    expect(find.text('Pages'), findsOneWidget);
    expect(find.text('one.html'), findsOneWidget);
    expect(find.text('App on port 5173'), findsNothing);
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

  testWidgets(
    'Apps is a chip that lists them; its dot shows only while one runs; the sheet never opens on it when something else exists',
    (tester) async {
      final s = session(mixed(), key: 'm/servers');
      await openSheet(tester, s);
      expect(find.text('Apps'), findsOneWidget);
      expect(find.text('App on port 5173'), findsNothing, reason: 'opens on the pictures, the newest kind');
      expect(find.byType(LinkDot), findsNothing, reason: 'nothing runs');

      await tapChip(tester, 'Apps');
      await _settle(tester);
      expect(find.text('App on port 5173'), findsOneWidget);
      expect(find.text('d.png'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Apps')).dy,
        lessThan(tester.getTopLeft(find.text('App on port 5173')).dy),
        reason: 'chips lead the sheet',
      );

      s.setBackground(runningVite());
      await _settle(tester);
      expect(find.byType(LinkDot), findsNWidgets(2), reason: 'the row’s dot and the chip’s');
      expect(find.descendant(of: find.byType(Segmented<MadeKind>), matching: find.byType(LinkDot)), findsOneWidget);
    },
  );

  testWidgets(
    'a swipe sideways goes to the neighbouring tab and the switch follows; the switch still jumps over several',
    (tester) async {
      final handle = tester.ensureSemantics();
      await openSheet(tester, session(mixed(), key: 'm/swipe'));
      expect(selected(tester, 'Pictures'), isTrue);

      await tester.fling(find.text('d.png'), const Offset(-300, 0), 1500);
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(selected(tester, 'Docs'), isTrue, reason: 'Docs follows Pictures');
      expect(find.text('plan.md'), findsOneWidget);
      expect(find.text('d.png'), findsNothing);

      await tester.fling(find.text('plan.md'), const Offset(300, 0), 1500);
      await _settle(tester);
      await tester.fling(find.text('d.png'), const Offset(300, 0), 1500);
      await _settle(tester);
      expect(selected(tester, 'Pages'), isTrue);
      expect(find.text('one.html'), findsOneWidget);

      await tapChip(tester, 'Apps');
      await _settle(tester);
      expect(selected(tester, 'Apps'), isTrue);
      expect(
        find.text('App on port 5173'),
        findsOneWidget,
        reason: 'the tab of the switch, not a page passed on the way',
      );
      expect(find.text('one.html'), findsNothing);
      handle.dispose();
    },
  );

  testWidgets('the sheet opens on the tab it was left on; a kind that is gone falls back to the newest', (
    tester,
  ) async {
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
    first.update(
      (st) => AgentSessionState(
        's',
        items: [
          for (final i in st.items)
            if (i is! TranscriptTool || !i.call.toolCallId.contains('/notes/')) i,
        ],
      ),
    );
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
    expect(find.byIcon(HerdrIcons.pictureOff), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing picture says so over the list, which stays for the next tap', (tester) async {
    onMachine(['$base/screenshots/here.png']);
    await openSheet(tester, session([picture('gone.png'), picture('here.png')]));

    await tester.tap(find.text('gone.png'));
    await _settle(tester);
    expect(find.text('Made in this session'), findsOneWidget);
    expect(find.text('gone.png isn’t on the machine any more.'), findsOneWidget);
    expect(find.byType(PhotoViewer), findsNothing);
  });

  testWidgets(
    'a picture opens over the list with the list’s other pictures to swipe to, in its order; Back returns to the list',
    (tester) async {
      onMachine(['a', 'b', 'c'].map((n) => '$base/screenshots/$n.png'));
      // Newest first in the grid: gone, c, b, a. The one the grid found gone is not in the viewer.
      await openSheet(tester, session([picture('a.png'), picture('b.png'), picture('c.png'), picture('gone.png')]));

      await tester.tap(find.text('b.png'));
      await _settle(tester);
      expect(find.byType(PhotoViewer), findsOneWidget);
      expect(find.textContaining('Opening'), findsNothing, reason: 'no toast stands over the photo');
      final model = tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;
      expect([for (final i in model.items) i.name], ['c.png', 'b.png', 'a.png']);
      expect(model.index, 1, reason: 'on the one that was tapped');

      Navigator.of(tester.element(find.byType(PhotoViewer))).pop();
      await _settle(tester);
      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.text('Made in this session'), findsOneWidget, reason: 'Back lands on the list, not on the board');
      expect(find.text('c.png'), findsOneWidget);
    },
  );

  testWidgets('a document opens in the file viewer over the list; Back returns to it', (tester) async {
    await openSheet(tester, session(mixed()));
    await tapChip(tester, 'Docs');
    await _settle(tester);
    await tester.tap(find.text('plan.md'));
    await _settle(tester);

    expect(find.byType(FileViewerScreen), findsOneWidget);
    expect(launcher.opened, isEmpty);

    Navigator.of(tester.element(find.byType(FileViewerScreen))).pop();
    await _settle(tester);
    expect(find.text('Made in this session'), findsOneWidget);
    expect(find.text('spec.pdf'), findsOneWidget, reason: 'on the Docs tab it was left on');
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

  testWidgets(
    'the grid builds only the tiles near the viewport, asks the machine only about those, and shows the next batch on request',
    (tester) async {
      onMachine([for (var i = 0; i < 30; i++) '$base/screenshots/s$i.png']);
      final held = PhotoThumbs.shared.length;
      await openSheet(
        tester,
        session([page('one.html'), for (var i = 0; i < 30; i++) picture('s$i.png')]),
        size: const Size(360, 600),
      );

      int stats() => fs.calls.where((c) => c.startsWith('stat $base/screenshots/')).length;
      final built = find.textContaining('.png', skipOffstage: false).evaluate().length;
      expect(built, inInclusiveRange(3, 23), reason: 'the rows at the viewport and a little beyond, not all 24');
      expect(stats(), lessThanOrEqualTo(built), reason: 'nothing for tiles that were never built');
      expect(
        PhotoThumbs.shared.length - held,
        lessThanOrEqualTo(built),
        reason: 'a thumbnail is asked for only by a tile that exists',
      );
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
    },
  );

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

  testWidgets('a picture the machine couldn’t be asked about isn’t shown as gone, and a tap asks again', (
    tester,
  ) async {
    onMachine(['$base/screenshots/here.png']);
    fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'timed out');
    await openSheet(tester, session([picture('here.png')]));
    expect(find.byIcon(HerdrIcons.pictureOff), findsNothing, reason: 'a link that is down says nothing about the file');
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
    expect(find.byType(PhotoViewer), findsNothing, reason: 'and didn’t open anything yet');
  });

  testWidgets('the switch stays where it is whatever tab is open, and while a long list scrolls', (tester) async {
    onMachine([for (var i = 0; i < 30; i++) '$base/screenshots/s$i.png', '$base/reports/one.html']);
    await openSheet(
      tester,
      session([
        _say('Serving http://localhost:5173/'),
        page('one.html'),
        for (var i = 0; i < 30; i++) picture('s$i.png'),
      ]),
    );

    // Only how far from the top: the switch may scroll sideways to its cell.
    double top(String label) => tester.getRect(find.text(label)).top;
    final servers = top('Apps');
    final pictures = top('Pictures');
    expect(
      tester.getSize(find.byType(CustomScrollView)).height,
      lessThanOrEqualTo(892 * 0.6 + 0.5),
      reason: 'a long list scrolls inside the sheet, which doesn’t fill the screen',
    );

    await tester.drag(find.text('s27.png'), const Offset(0, -300));
    await _settle(tester);
    expect(top('Pictures'), pictures, reason: 'the switch doesn’t scroll away with a long list');

    await tapChip(tester, 'Apps');
    await _settle(tester);
    expect(find.text('App on port 5173'), findsOneWidget);
    expect(top('Apps'), servers, reason: 'a short tab after a tall one');
    expect(top('Pictures'), pictures);

    await tapChip(tester, 'Pictures');
    await _settle(tester);
    expect(top('Apps'), servers, reason: 'and a tall one after a short one');
  });

  testWidgets('a running app is said, not only shown as a dot', (tester) async {
    final handle = tester.ensureSemantics();
    final s = session(mixed(), key: 'm/says-running');
    await openSheet(tester, s);
    expect(tester.getSemantics(find.text('Apps')).label, 'Apps, 1');

    s.setBackground(runningVite());
    await _settle(tester);
    expect(tester.getSemantics(find.text('Apps')).label, 'Apps, 1, running');
    handle.dispose();
  });

  testWidgets(
    'four pages of one server are one app named by what launched it, with a chip per page; a chip opens that page',
    (tester) async {
      final launch = TranscriptTool(
        ToolCall(
          toolCallId: 'launch',
          kind: ToolKind.execute,
          status: ToolStatus.completed,
          rawInput: {'command': 'cd /w && nohup python label_server.py --port 8765 > log 2>&1 &'},
        ),
      );
      await openSheet(
        tester,
        session([
          launch,
          _say('Open http://localhost:8765/failures'),
          _say('and http://localhost:8765/review'),
          _say('and http://localhost:8765/synth'),
          _say('and http://localhost:8765/'),
          _say('Other: http://localhost:8790/'),
        ]),
      );

      expect(find.text('python label_server.py --port 8765'), findsOneWidget);
      expect(find.text('Port 8765 · Status unknown'), findsOneWidget);
      expect(find.text('App on port 8790'), findsOneWidget);
      expect(
        find.byType(AppChip),
        findsNWidgets(1 + 3),
        reason: 'the Made chip behind the sheet, and a chip for each of the three pages',
      );
      expect(find.text('/failures'), findsOneWidget);

      await tester.tap(find.text('/review'));
      await _settle(tester);
      expect(transport.webBridges.single, isA<PortForward>().having((p) => p.port, 'port', 8765));
      expect(web.loaded.first.queryParameters['to'], '/review');
      expect(
        find.textContaining('python label_server.py --port 8765'),
        findsOneWidget,
        reason: 'the page’s bar says what the app is, not only localhost:8765',
      );
    },
  );

  testWidgets(
    'a machine without files: pages, pictures and documents are dimmed with the reason, and nothing is asked',
    (tester) async {
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
    },
  );

  testWidgets(
    'a long chat read in part: the chip says `+`, opening the sheet reads the rest, and the sheet says what it is doing',
    (tester) async {
      final s = session([_say('Serving http://localhost:5173/')], key: 'm/partial')..madeReachValue = MadeReach.partial;
      await pumpBar(tester, s);
      expect(find.text('Made 1+'), findsOneWidget);
      expect(s.readEarlierMadeCalls, 0, reason: 'nothing is read until the person looks');

      await tester.tap(find.text('Made 1+'));
      await _settle(tester);
      expect(s.readEarlierMadeCalls, 1);
      expect(find.text('Only the end of this chat has been read.'), findsOneWidget);

      s.setMadeReach(MadeReach.reading);
      await tester.pump();
      expect(find.text('Reading earlier history…'), findsOneWidget);

      s.setMadeReach(MadeReach.failed);
      await tester.pump();
      expect(find.textContaining('Couldn’t read the earlier part'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(s.readEarlierMadeCalls, 2);

      s.setMadeReach(MadeReach.whole);
      await tester.pump();
      expect(find.text('Reading earlier history…'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    },
  );

  testWidgets(
    'nothing found yet but the chat is only read in part: the chip is there, and the sheet doesn’t say nothing came up',
    (tester) async {
      final s = session([_say('No links here.')], key: 'm/partial-empty')..madeReachValue = MadeReach.partial;
      await pumpBar(tester, s);
      await tester.tap(find.text('Made'));
      await _settle(tester);
      expect(find.text('Nothing has come up in this session yet.'), findsNothing);
      expect(find.text('Only the end of this chat has been read.'), findsOneWidget);
    },
  );

  testWidgets('rows keep their place across tabs while the sheet is open; what arrives is there the next time', (
    tester,
  ) async {
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

  testWidgets('nothing overflows at 320 dp and text 1.6: the switch scrolls sideways, the names stay on one line', (
    tester,
  ) async {
    final s = session(mixed());
    tester.view.physicalSize = const Size(320, 640) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
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
