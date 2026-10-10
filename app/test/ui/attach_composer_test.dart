// The composer while the agent works and with things attached: the delivery
// hint, Stop beside Send, the attach sheet, pictures and host files as chips
// that go out with the text, the file browser's pick mode, and the sign-in
// panel.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/auth_needed.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart' show JsonRpcException;
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/data/repositories/attach_target.dart' show AttachMode;
import 'package:herdr_mobile/data/repositories/session_launcher.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/ui/features/attach/attach_bars.dart';
import 'package:herdr_mobile/ui/features/attach/attach_kit.dart';
import 'package:herdr_mobile/ui/features/attach/host_tab.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/status_panel.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_chips.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_picker.dart';
import 'package:herdr_mobile/ui/features/agent_session/auth_panel.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:image/image.dart' as img;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/attach_fakes.dart';
import '../support/fake_agent_session.dart';
import '../support/files_support.dart';
import '../support/shot.dart' show loadAppFonts;

/// Hands out the pictures a test queues; null when the person backs out.
class FakePicker implements AttachPicker {
  final gallery = <PickedPhoto?>[];
  final shots = <PickedPhoto?>[];
  Object? failure;
  var asked = 0;

  @override
  Future<PickedPhoto?> photo() async {
    asked++;
    if (failure != null) throw failure!;
    return gallery.isEmpty ? null : gallery.removeAt(0);
  }

  @override
  Future<PickedPhoto?> camera() async {
    asked++;
    if (failure != null) throw failure!;
    return shots.isEmpty ? null : shots.removeAt(0);
  }
}

final _jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));

/// A picture the system picker left in the app's cache; [pump]'s screen reads
/// every picture of the phone as [_jpeg].
PickedPhoto photo([String name = 'IMG_2031.jpg']) => PickedPhoto(path: '/cache/image_picker/$name', name: name, size: _jpeg.length);

Future<PreparedImage> instantly(Uint8List input) async => PreparedImage(bytes: input, width: 8, height: 8);

Future<void> pump(
  WidgetTester tester,
  FakeAgentSession session, {
  AttachPicker? picker,
  Future<PreparedImage> Function(Uint8List)? prepare,
  Size size = const Size(412, 892),
  AttachKit? kit,
}) async {
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      navigatorObservers: [ToastRouteObserver()],
      home: AgentSessionScreen(
        key: ObjectKey(session),
        session: session,
        picker: picker ?? FakePicker(),
        prepare: prepare ?? instantly,
        attachKit: kit ?? FakeKit(gallery: FakeGallery(state: GalleryAccess.unavailable)).kit,
        readFile: (_) async => _jpeg,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> settle(WidgetTester tester, [int ms = 400]) async {
  await tester.pump();
  await tester.pump(Duration(milliseconds: ms));
}

Finder get field => find.byType(TextField).last;

Finder get attachButton => find.byIcon(LucideIcons.paperclip);

Finder get chips => find.byType(AttachmentChips);

FakeAgentSession working() => FakeAgentSession(state: stateWith(turnActive: true));

/// Taps [name] in the open file browser, scrolling to it first.
Future<void> tapEntry(WidgetTester tester, String name) async {
  final list = find.descendant(of: find.byType(FileBrowserScreen).last, matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(find.text(name), 120, scrollable: list);
  await tester.tap(find.text(name));
  await settle(tester);
}

/// Puts the cursor in the field, as a tap does (the hint shows from then on).
Future<void> focusField(WidgetTester tester) async {
  await tester.tap(field);
  await settle(tester);
}

/// Taps the paperclip and then [item]. The library cannot be read in these
/// tests (the plugin fails), so `Photo library` is the sheet's system-picker
/// button and `Camera` is the one under it.
Future<void> attach(WidgetTester tester, String item) async {
  await tester.tap(attachButton);
  await settle(tester);
  await tester.tap(find.text(switch (item) {
    'Photo library' => 'Open the system picker',
    'Camera' => 'Take a photo',
    _ => item,
  }));
  await settle(tester);
  await settle(tester);
}

/// Picks a file of the machine in the sheet's Host tab: opens the sheet, the
/// tab, lifts the sheet to full height, shows every file and walks [path].
Future<void> attachHostFile(WidgetTester tester, List<String> path) async {
  await tester.tap(attachButton);
  await settle(tester);
  await tester.tap(find.byKey(AttachTabBar.tabKey(AttachTab.host)));
  await settle(tester, 600);
  await tester.dragFrom(const Offset(206, 402), const Offset(0, -380));
  await settle(tester, 600);
  if (find.text('Show all files').evaluate().isNotEmpty) {
    await tester.tap(find.text('Show all files'));
    await settle(tester);
  }
  for (final (i, step) in path.indexed) {
    final list = find.descendant(of: find.byType(HostTab), matching: find.byType(Scrollable)).last;
    await tester.scrollUntilVisible(find.text(step), 120, scrollable: list);
    // Above the floating bars, where a finger can reach it.
    while (tester.getCenter(find.text(step)).dy > 640) {
      await tester.drag(list, const Offset(0, -120));
      await tester.pump();
    }
    await tester.tap(find.text(step));
    await settle(tester);
    if (i == path.length - 1) await tester.tap(find.textContaining('Attach ('));
  }
  await settle(tester);
  await settle(tester);
}

void main() {
  // The browser cuts a long name in the middle by measuring it: with the
  // placeholder font every name is "long".
  setUpAll(loadAppFonts);

  group('while the agent works', () {
    testWidgets('the field stays open and keeps what is typed', (tester) async {
      final session = working();
      await pump(tester, session);
      expect(tester.widget<TextField>(field).enabled, isTrue);
      await tester.enterText(field, 'and the linter');
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'and the linter');
    });

    testWidgets('an agent that queues says so before the message is sent', (tester) async {
      await pump(tester, working());
      expect(find.textContaining('queued until'), findsNothing, reason: 'a resting composer says nothing');
      await focusField(tester);
      expect(find.text('Will be queued until the turn ends'), findsOneWidget);
      expect(find.text('Goes into the running turn'), findsNothing);
    });

    testWidgets('an agent that steers says so; a queue that waits makes it a queue again', (tester) async {
      final session = working()..steerable = true;
      await pump(tester, session);
      await focusField(tester);
      expect(find.text('Goes into the running turn'), findsOneWidget);

      // Something already waits: the order is kept, so the next one waits too.
      await session.sendBlocks([const TextBlock('later')], queue: true);
      await settle(tester);
      expect(find.text('Will be queued until the turn ends'), findsOneWidget);
      expect(find.text('Goes into the running turn'), findsNothing);
    });

    testWidgets('nothing is said when the message would go out at once, or the agent is in a terminal', (tester) async {
      final idle = FakeAgentSession();
      await pump(tester, idle);
      expect(find.textContaining('queued'), findsNothing);
      expect(find.textContaining('running turn'), findsNothing);

      final terminal = working()..observed = true;
      await pump(tester, terminal);
      expect(find.text('Will be queued until the turn ends'), findsNothing);
    });

    testWidgets('the turn ending takes the hint away', (tester) async {
      final session = working();
      await pump(tester, session);
      await focusField(tester);
      expect(find.text('Will be queued until the turn ends'), findsOneWidget);
      session.update((s) => s.withTurnEnded(StopReason.endTurn));
      await settle(tester);
      expect(find.text('Will be queued until the turn ends'), findsNothing);
    });

    testWidgets('a queued message is cut to two lines; a held one says why and can be resumed', (tester) async {
      final session = working();
      await pump(tester, session);
      final long = List.filled(40, 'then run every test in the repository').join(' ');
      await tester.enterText(field, long);
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.listPlus));
      await settle(tester, 300);
      final row = tester.widget<Text>(find.text(long));
      expect(row.maxLines, 2);
      expect(row.overflow, TextOverflow.ellipsis);

      session.holdQueue('Held because the turn was stopped. Resume to send it.'); // a stop from elsewhere
      await settle(tester, 300);
      expect(find.textContaining('turn was stopped'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Resume'), findsOneWidget);
      expect(find.byTooltip('Remove queued message'), findsOneWidget);
    });
  });

  group('the attach button', () {
    testWidgets('opens a sheet with Gallery, Files and Host tabs and the camera tile', (tester) async {
      await pump(tester, FakeAgentSession(machine: machineWithFiles(projectFs())), kit: FakeKit().kit);
      await tester.tap(attachButton);
      await settle(tester);
      expect(find.byKey(AttachTabBar.tabKey(AttachTab.gallery)), findsOneWidget);
      expect(find.byKey(AttachTabBar.tabKey(AttachTab.files)), findsOneWidget);
      expect(find.byKey(AttachTabBar.tabKey(AttachTab.host)), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('This agent does not take images. Photos go up as files.'), findsNothing);
    });

    testWidgets('an agent with no images says so in the Gallery tab; the photos still go, as files', (tester) async {
      final session = FakeAgentSession(machine: machineWithFiles(projectFs()))..imagesAccepted = false;
      await pump(tester, session, kit: FakeKit().kit);
      await tester.tap(attachButton);
      await settle(tester);
      expect(find.text('This agent does not take images. Photos go up as files.'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget, reason: 'the tab is not taken away');
    });

    testWidgets('a host with no file access says so in the Host tab', (tester) async {
      await pump(tester, FakeAgentSession());
      await tester.tap(attachButton);
      await settle(tester);
      await tester.tap(find.byKey(AttachTabBar.tabKey(AttachTab.host)));
      await settle(tester);
      expect(find.text('Files are unavailable on this machine'), findsOneWidget);
    });

    testWidgets('is offered to an agent in a terminal, not to a subagent run, and is dimmed while the link is down', (tester) async {
      await pump(tester, FakeAgentSession()..observed = true..mode = AttachMode.paths);
      expect(attachButton, findsOneWidget);
      await pump(tester, FakeAgentSession()..observed = true..mode = AttachMode.none);
      expect(attachButton, findsNothing);

      final down = FakeAgentSession(link: AgentLink.reconnecting);
      await pump(tester, down);
      await tester.tap(attachButton);
      await settle(tester);
      expect(find.byType(AttachTabBar), findsNothing);
    });
  });

  group('pictures', () {
    testWidgets('a picked picture waits as a chip and goes out with the text', (tester) async {
      final session = FakeAgentSession();
      final picker = FakePicker()..gallery.add(photo());
      await pump(tester, session, picker: picker);

      await attach(tester, 'Photo library');
      expect(find.descendant(of: chips, matching: find.text('IMG_2031.jpg')), findsOneWidget);
      expect(tester.widgetList<Image>(find.descendant(of: chips, matching: find.byType(Image))), hasLength(1));

      await tester.enterText(field, 'what is wrong with this?');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await settle(tester);

      final blocks = session.sentBlocks.single;
      expect(blocks, hasLength(2));
      expect((blocks[0] as TextBlock).text, 'what is wrong with this?');
      expect(blocks[1], isA<ImageBlock>());
      expect((blocks[1] as ImageBlock).mimeType, 'image/jpeg');
      expect(find.text('IMG_2031.jpg'), findsNothing, reason: 'the chips go with the message');
    });

    testWidgets('a picture alone is a message', (tester) async {
      final session = FakeAgentSession();
      await pump(tester, session, picker: FakePicker()..shots.add(photo('shot.jpg')));
      await attach(tester, 'Camera');
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await settle(tester);
      expect(session.sentBlocks.single.single, isA<ImageBlock>());
    });

    testWidgets('while it is being prepared the chip says so and the message cannot go', (tester) async {
      final session = FakeAgentSession();
      final done = Completer<PreparedImage>();
      await pump(tester, session, picker: FakePicker()..gallery.add(photo()), prepare: (_) => done.future);
      await attach(tester, 'Photo library');

      expect(find.text('Preparing\u2026'), findsOneWidget);
      expect(find.descendant(of: chips, matching: find.byType(BusySpinner)), findsOneWidget);
      await tester.enterText(field, 'look');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await settle(tester);
      expect(session.sentBlocks, isEmpty, reason: 'neither the button nor the keyboard sends half a picture');

      done.complete(PreparedImage(bytes: _jpeg, width: 8, height: 8));
      await settle(tester);
      expect(find.text('Preparing\u2026'), findsNothing);
      expect(find.descendant(of: chips, matching: find.byType(BusySpinner)), findsNothing);
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await settle(tester);
      expect(session.sentBlocks, hasLength(1));
    });

    testWidgets('the cross removes a chip, also one still being prepared', (tester) async {
      final session = FakeAgentSession();
      final done = Completer<PreparedImage>();
      await pump(tester, session, picker: FakePicker()..gallery.add(photo()), prepare: (_) => done.future);
      await attach(tester, 'Photo library');
      await tester.tap(find.descendant(of: chips, matching: find.byIcon(LucideIcons.x)));
      await settle(tester);
      expect(find.text('IMG_2031.jpg'), findsNothing);

      done.complete(PreparedImage(bytes: _jpeg, width: 8, height: 8));
      await settle(tester);
      expect(find.text('IMG_2031.jpg'), findsNothing, reason: 'a late result does not bring it back');
    });

    testWidgets('a picker failure or an unreadable picture: a plain message and no chip', (tester) async {
      final picker = FakePicker()..failure = const ImagePrepException('The photo picker could not be opened.');
      await pump(tester, FakeAgentSession(), picker: picker);
      await attach(tester, 'Photo library');
      expect(find.text('The photo picker could not be opened.'), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      final broken = FakePicker()..gallery.add(photo('bad.heic'));
      await pump(
        tester,
        FakeAgentSession(),
        picker: broken,
        prepare: (_) async => throw const ImagePrepException('Could not read that picture. Use a JPEG, PNG or WebP.'),
      );
      await attach(tester, 'Photo library');
      expect(find.text('Could not read that picture. Use a JPEG, PNG or WebP.'), findsOneWidget);
      expect(find.text('bad.heic'), findsNothing);
    });

    testWidgets('backing out of the picker attaches nothing', (tester) async {
      await pump(tester, FakeAgentSession());
      await attach(tester, 'Photo library');
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('at most five; the sixth is refused with a message', (tester) async {
      final picker = FakePicker();
      for (var i = 0; i < 5; i++) {
        picker.gallery.add(photo('p$i.jpg'));
      }
      await pump(tester, FakeAgentSession(), picker: picker);
      for (var i = 0; i < 5; i++) {
        await attach(tester, 'Photo library');
      }
      expect(find.descendant(of: chips, matching: find.byIcon(LucideIcons.x)), findsNWidgets(5));

      await tester.tap(attachButton);
      await settle(tester);
      expect(find.text('At most 5 attachments per message.'), findsOneWidget);
      expect(find.byType(AttachTabBar), findsNothing, reason: 'no sheet when it is full');
    });

    testWidgets('a message queued with a picture keeps it', (tester) async {
      final session = working();
      await pump(tester, session, picker: FakePicker()..gallery.add(photo()));
      await attach(tester, 'Photo library');
      await tester.enterText(field, 'then this');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.listPlus));
      await settle(tester, 300);
      expect(session.queued.single.attachments.single, isA<ImageBlock>());
      expect(find.text('+ 1 attachment'), findsOneWidget);
    });

    testWidgets('long and Vietnamese names, 320 px wide at 1.6 text scale, overflow nothing', (tester) async {
      final picker = FakePicker()
        ..gallery.add(photo('Ảnh chụp màn hình rất dài của giao diện đăng nhập sau khi sửa lỗi bố cục.jpg'))
        ..gallery.add(photo('b.jpg'));
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(tester, FakeAgentSession(), picker: picker, size: const Size(320, 640));
      await attach(tester, 'Photo library');
      await attach(tester, 'Photo library');
      expect(tester.takeException(), isNull);
    });
  });

  group('files from the host', () {
    const root = '/home/dev/herdr-mobile';

    FakeAgentSession onHost() => FakeAgentSession(machine: machineWithFiles(projectFs()), cwd: root);

    testWidgets('a file becomes a chip that goes out as a path link, relative to the folder', (tester) async {
      final session = onHost();
      await pump(tester, session);
      await attachHostFile(tester, ['docs', 'Thiết kế giao diện.md']);

      expect(find.byType(AttachTabBar), findsNothing, reason: 'the sheet closed with the choice');
      expect(find.descendant(of: chips, matching: find.text('Thiết kế giao diện.md')), findsOneWidget);
      expect(find.text('Sent as a path'), findsOneWidget);

      await tester.enterText(field, 'read this');
      await tester.pump();
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await settle(tester);
      final blocks = session.sentBlocks.single;
      final link = blocks[1] as ResourceLinkBlock;
      expect(link.name, 'docs/Thiết kế giao diện.md');
      expect(link.uri, '${Uri.file('$root/docs/Thiết kế giao diện.md')}');
    });

    testWidgets('an agent that takes embedded context gets small text files as text', (tester) async {
      final session = onHost()..embeddedAccepted = true;
      await pump(tester, session);
      await attachHostFile(tester, ['AGENTS.md']);
      expect(find.text('Text included'), findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await settle(tester);
      final block = session.sentBlocks.single.single as EmbeddedResourceBlock;
      expect(block.text, 'notes\n');
    });

    testWidgets('a file over the cap, or one that is not text, stays a link', (tester) async {
      final session = onHost()..embeddedAccepted = true;
      await pump(tester, session);
      await attachHostFile(tester, ['release.apk']);
      expect(find.text('Sent as a path'), findsOneWidget);

      await attachHostFile(tester, ['screenshot 2026-05-20 at 09.30.png']);
      await settle(tester);
      expect(find.text('Sent as a path'), findsNWidgets(2));

      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await settle(tester);
      expect(session.sentBlocks.single, everyElement(isA<ResourceLinkBlock>()));
    });

    testWidgets('closing the sheet without attaching adds nothing', (tester) async {
      await pump(tester, onHost());
      await tester.tap(attachButton);
      await settle(tester);
      await tester.tapAt(const Offset(200, 40));
      await settle(tester);
      expect(find.byType(AttachTabBar), findsNothing);
      expect(find.descendant(of: chips, matching: find.byIcon(LucideIcons.x)), findsNothing);
    });
  });

  group('pick mode of the file browser', () {
    Future<List<String?>> open(WidgetTester tester, {String start = '/home/dev/herdr-mobile'}) async {
      final results = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => GestureDetector(
              onTap: () async => results.add(
                await Navigator.of(context).push<String>(
                  MaterialPageRoute<String>(
                    builder: (_) => FileBrowserScreen(
                      machine: machineWithFiles(projectFs()),
                      path: start,
                      mode: FileBrowserMode.pickFile,
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      return results;
    }

    testWidgets('lists files and folders; a tap on a file returns its absolute path', (tester) async {
      final results = await open(tester);
      expect(find.text('docs'), findsOneWidget);
      await tapEntry(tester, 'AGENTS.md');
      await settle(tester);
      expect(results, ['/home/dev/herdr-mobile/AGENTS.md']);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a file in a folder pops every browser on the way', (tester) async {
      final results = await open(tester);
      await tester.tap(find.text('docs'));
      await settle(tester);
      await tester.tap(find.text('Thiết kế giao diện.md'));
      await settle(tester);
      expect(results, ['/home/dev/herdr-mobile/docs/Thiết kế giao diện.md']);
      expect(find.byType(FileBrowserScreen), findsNothing);
    });

    testWidgets('back returns null and opens no viewer', (tester) async {
      final results = await open(tester);
      await tester.tap(find.byIcon(LucideIcons.chevronLeft));
      await settle(tester);
      expect(results, [null]);
    });
  });

  group('sign in on the host', () {
    AuthNeeded need({bool hint = true}) => AuthNeeded(
      message: 'Claude Code needs you to sign in on the host.',
      agentMessage: 'Authentication required',
      methods: [
        AuthChoice(
          id: 'claude-login',
          name: 'Log in with Claude',
          terminal: hint,
          terminalCommand: hint ? 'claude /login' : null,
        ),
        const AuthChoice(id: 'api-key', name: 'Use an API key'),
      ],
    );

    testWidgets('the screen shows the panel while the agent wants a login, and drops it when cleared', (tester) async {
      final session = FakeAgentSession()..auth = need();
      await pump(tester, session);
      expect(find.byType(StatusPanel), findsOneWidget);
      expect(find.text('Sign in on the host'), findsOneWidget);
      expect(find.textContaining('Log in with Claude \u00b7 Use an API key'), findsOneWidget);
      expect(find.text('Open a terminal on devbox'), findsOneWidget);
      expect(find.text('claude /login'), findsOneWidget);
      expect(find.textContaining('signed in'), findsNothing, reason: 'it never claims the login worked');

      session
        ..auth = null
        ..setLink(AgentLink.live);
      await settle(tester);
      expect(find.byType(StatusPanel), findsNothing);
    });

    testWidgets('a connection that failed for the login offers Try again', (tester) async {
      final session = FakeAgentSession(link: AgentLink.failed, error: 'Claude Code needs you to sign in on the host.')
        ..auth = need();
      await pump(tester, session);
      expect(find.text('Sign in on the host'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(session.reattachCount, 1);
    });

    testWidgets('without a login hint there is no command to copy', (tester) async {
      final session = FakeAgentSession()..auth = need(hint: false);
      await pump(tester, session);
      expect(find.text('Copy command'), findsNothing);
      expect(find.text('Open a terminal on devbox'), findsOneWidget);
    });

    testWidgets('the button opens a plain terminal in the session folder', (tester) async {
      final session = FakeAgentSession()..auth = need();
      final requests = <LaunchRequest>[];
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AuthPanel(
              session: session,
              launcherFor: (m) => _Launcher(m, requests),
              openPane: (context, machine, paneId) async => opened.add(paneId),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open a terminal on devbox'));
      await tester.pump();
      await tester.pump();
      expect(requests.single.folder, '/home/dev/payments-api');
      expect(opened, ['p-signin']);
    });

    testWidgets('a terminal that could not start says why, in a message', (tester) async {
      final session = FakeAgentSession()..auth = need();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: AuthPanel(
              session: session,
              launcherFor: (m) => _Launcher(m, [], fail: const HerdrApiException('x', 'herdr refused')),
              openPane: (context, machine, paneId) async {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open a terminal on devbox'));
      await tester.pump();
      await tester.pump();
      expect(find.text('herdr refused'), findsOneWidget);
      expect(find.byType(BusySpinner), findsNothing);
    });

    testWidgets('Copy command puts the agent\u2019s hint on the clipboard', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(tester, FakeAgentSession()..auth = need());
      await tester.tap(find.text('Copy command'));
      await settle(tester);
      expect(copied, ['claude /login']);
    });

    testWidgets('320 px wide at 1.6 text scale: no overflow, the panel scrolls inside its share', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(tester, FakeAgentSession(link: AgentLink.failed)..auth = need(), size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a login locked in the Mac\u2019s Keychain asks for a token instead of another sign-in, and copies the token command', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final keychain = authNeededFrom(
        const JsonRpcException(-32000, 'Authentication required'),
        agentLabel: 'Claude Code',
        advertised: [
          {'id': 'claude-login', 'name': 'Log in with Claude', '_meta': {'terminal-auth': {'command': 'claude', 'args': ['/login']}}},
        ],
        keychain: true,
      );
      await pump(tester, FakeAgentSession()..auth = keychain);

      expect(find.text('Claude Code needs a token'), findsOneWidget);
      expect(find.textContaining('claude setup-token'), findsWidgets);
      expect(find.textContaining('CLAUDE_CODE_OAUTH_TOKEN'), findsOneWidget);
      expect(find.textContaining('Log in with Claude'), findsNothing, reason: 'signing in again would store it in the Keychain again');
      expect(find.text('claude /login'), findsNothing);
      expect(find.text('Open a terminal on devbox'), findsOneWidget);

      await tester.tap(find.text('Copy command'));
      await settle(tester);
      expect(copied, ['claude setup-token']);
    });

    testWidgets('the token steps fit 320 px wide at 1.6 text scale', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final keychain = authNeededFrom(const JsonRpcException(-32000, 'Authentication required'), agentLabel: 'Claude Code', keychain: true);
      await pump(tester, FakeAgentSession(link: AgentLink.failed)..auth = keychain, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });
  });

  group('the compact layout (landscape with the keyboard up)', () {
    testWidgets('leaves out the hint, the queue and the chips; the paperclip counts what goes along', (tester) async {
      final session = working();
      await pump(tester, session, picker: FakePicker()..gallery.add(photo()), size: const Size(892, 412));
      await attach(tester, 'Photo library');
      await focusField(tester);
      expect(find.text('Will be queued until the turn ends'), findsOneWidget);
      expect(find.text('IMG_2031.jpg'), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.pump();
      expect(find.text('Will be queued until the turn ends'), findsNothing);
      expect(find.text('IMG_2031.jpg'), findsNothing, reason: 'no room for chips');
      expect(find.text('1'), findsOneWidget, reason: 'but what will be sent is never hidden: the badge counts it');

      tester.view.resetViewInsets();
      await tester.pump();
      await tester.pump();
      expect(find.text('IMG_2031.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

class _Launcher extends SessionLauncher {
  _Launcher(super.machine, this.requests, {this.fail});

  final List<LaunchRequest> requests;
  final Exception? fail;

  @override
  Future<LaunchedSession> launch(LaunchRequest request) async {
    requests.add(request);
    if (fail != null) throw fail!;
    return const LaunchedSession(workspaceId: 'w-signin', paneId: 'p-signin');
  }
}
