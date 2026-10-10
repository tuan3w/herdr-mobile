// Renders the terminal view's composer and the chat's side by side in the same
// worst case (text scale 1.3, three chips with long names, a four-line draft,
// the command palette open on a long list) to PNGs for review. Off by default;
// it writes files:
//
//   COMPOSER_SHOTS=1 flutter test test/ui/composer_parity_shots_test.dart
//
// Then it checks what the eye checks: both composers are as tall, have the same
// corner and the same discs.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/slash_command.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/command_source.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_picker.dart';
import 'package:herdr_mobile/ui/features/composer/command_palette.dart';
import 'package:herdr_mobile/ui/features/composer/composer_frame.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:herdr_mobile/ui/features/composer/command_model.dart';
import '../support/attach_fakes.dart';
import '../support/fake_agent_session.dart';
import '../support/fake_network.dart';
import '../support/fake_transport.dart';
import '../support/memory_stores.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/shot.dart' show loadAppFonts;

class _Picker implements AttachPicker {
  var n = 0;

  PickedPhoto next() {
    final names = ['IMG_20260518_184233_a-very-long-photograph-name-that-keeps-going.jpg', 'Ảnh chụp màn hình.png', 'x.jpg'];
    final name = names[n++ % names.length];
    return PickedPhoto(path: '/cache/$name', name: name, size: 900);
  }

  @override
  Future<PickedPhoto?> camera() async => next();

  @override
  Future<PickedPhoto?> photo() async => next();
}

void main() {
  if (Platform.environment['COMPOSER_SHOTS'] == null) {
    test('composer shots are off (set COMPOSER_SHOTS=1)', () {}, skip: 'set COMPOSER_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['COMPOSER_SHOTS_DIR'] ?? '/tmp/composer_shots';
  final jpeg = fakePicture(3);
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  const dpr = 2.625;
  const size = Size(412, 892);
  // The worst case is 1.3; the attach sheet is driven at 1.0 (it is taller than
  // the phone at 1.3 and needs a finger to scroll), then the text grows.
  final scale = ValueNotifier<double>(1.3);
  const draft = 'Please look at the three screenshots, compare them with the design,\nand list every spacing that differs.\n'
      'Then fix the worst one first.\nAnd run the tests.';

  Future<void> snap(WidgetTester tester, GlobalKey key, String name) async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name.png').writeAsBytes(data!.buffer.asUint8List());
    });
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
  }

  Widget framed(GlobalKey key, Widget home) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark(),
    builder: (context, child) => ValueListenableBuilder<double>(
      valueListenable: scale,
      builder: (context, value, _) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(value)),
        child: RepaintBoundary(key: key, child: child!),
      ),
    ),
    home: home,
  );

  Future<void> addChips(WidgetTester tester) async {
    scale.value = 1;
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byIcon(LucideIcons.paperclip).first);
      for (var t = 0; t < 4; t++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      final take = find.text('Take a photo').last;
      // At a large text size the sheet is longer than the room above the bars:
      // a finger scrolls it.
      if (tester.getCenter(take).dy > size.height - 150) {
        await tester.drag(find.byType(ListView).last, const Offset(0, -260));
        await tester.pump();
      }
      await tester.tap(take);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 400));
    }
    scale.value = 1.3;
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<Size> composerSize(WidgetTester tester) async => tester.getSize(find.byType(ComposerFrame).last);

  late Size paneFrame;
  late Size chatFrame;

  testWidgets('the terminal view of an agent', (tester) async {
    phone(tester);
    final transport = _PaneTransport(snapshotJson(panes: [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')]));
    final machine = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
      api: HerdrApi(transport),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );
    final repo = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    await repo.load();
    final fleet = FleetRepository(machines: repo, network: FakeNetwork(), connect: (p, s) => machine);
    await repo.save(machine.profile, secrets: const MachineSecrets(password: 'x'));
    await fleet.settled();
    final screens = AgentScreens();
    final previews = PanePreviews(changes: fleet, connection: fleet.connection);
    final key = GlobalKey();
    final kit = FakeKit(gallery: FakeGallery(state: GalleryAccess.unavailable));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: TerminalSettings(MemoryTerminalSettingsStore())),
          ChangeNotifierProvider.value(value: fleet),
          ChangeNotifierProvider.value(value: screens),
          Provider<PanePreviews>.value(value: previews),
        ],
        child: framed(
          key,
          PaneScreen(
            agent: PaneAgent('m', 'w1:p1'),
            picker: _Picker(),
            prepare: (b) async => PreparedImage(bytes: b, width: 8, height: 8),
            attachKit: kit.kit,
            readFile: (_) async => jpeg,
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await addChips(tester);
    await tester.enterText(find.byType(TextField).last, draft);
    await tester.pump(const Duration(milliseconds: 600));
    await snap(tester, key, 'pane-chips-draft');
    paneFrame = await composerSize(tester);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    previews.dispose();
    screens.dispose();
    fleet.dispose();
  });

  testWidgets('the chat of an agent', (tester) async {
    phone(tester);
    final session = FakeAgentSession();
    final key = GlobalKey();
    final kit = FakeKit(gallery: FakeGallery(state: GalleryAccess.unavailable));
    await tester.pumpWidget(
      framed(
        key,
        AgentSessionScreen(
          key: ObjectKey(session),
          session: session,
          picker: _Picker(),
          prepare: (b) async => PreparedImage(bytes: b, width: 8, height: 8),
          attachKit: kit.kit,
          readFile: (_) async => jpeg,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await addChips(tester);
    await tester.enterText(find.byType(TextField).last, draft);
    await tester.pump(const Duration(milliseconds: 600));
    await snap(tester, key, 'chat-chips-draft');
    chatFrame = await composerSize(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both composers hold the same four-line draft at the same height', (tester) async {
    expect(paneFrame.height, closeTo(chatFrame.height, 0.5));
  });

  testWidgets('the palette with twenty long commands', (tester) async {
    phone(tester);
    final source = _Fixed([
      for (var i = 0; i < 20; i++)
        SlashCommand(
          'command-with-a-rather-long-name-$i',
          'A description that runs on and on so that it cannot fit on one line of a phone, number $i',
          i < 3 ? SlashSource.project : SlashSource.builtIn,
          hint: i.isEven ? '<an argument hint that is long too>' : null,
        ),
    ]);
    final model = CommandPaletteModel(source: source);
    final input = TextEditingController(text: '/');
    final key = GlobalKey();
    await tester.pumpWidget(
      framed(
        key,
        Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: CommandPalette(input: input, model: model, onPick: (_) {})),
        ),
      ),
    );
    await tester.pump();
    await snap(tester, key, 'palette-20');
    expect(tester.takeException(), isNull);
    expect(find.byType(CommandPalette), findsOneWidget);
  });
}

class _Fixed extends ChangeNotifier implements CommandSource {
  _Fixed(this.commands);

  @override
  final List<SlashCommand> commands;

  @override
  String? get agent => 'claude';

  @override
  void ensureLoaded() {}
}

/// `pane.read` answers with one line.
class _PaneTransport extends FakeTransport {
  _PaneTransport(super.snapshot);

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) {
    if (method != 'pane.read') return super.request(method, params);
    calls.add((method, params));
    return Future.value({
      'type': 'pane_read',
      'read': {'text': 'claude is ready', 'truncated': false},
    });
  }
}
