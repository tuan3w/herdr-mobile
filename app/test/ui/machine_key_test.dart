// Key generation in the machine form: the field is filled, the public key and
// the one command to run on the host are one tap from the clipboard, a saved
// key can show its public half, and no private key text appears anywhere
// except the field it was put in.
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/key_generator.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart';
import 'package:provider/provider.dart';

import '../support/fake_transport.dart';
import '../support/memory_stores.dart';
import 'ui_harness.dart';

HerdrTransport _noTransport(
  MachineProfile profile,
  MachineSecrets secrets,
  void Function(String) onPin,
  void Function(String) onNotice,
) =>
    throw StateError('this test never opens a connection');

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget home,
  MachineRepository repo, {
  double width = 360,
  double height = 740,
  double scale = 1,
  Brightness brightness = Brightness.light,
  TransportFactory transportFactory = _noTransport,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<TransportFactory>.value(value: transportFactory),
        ChangeNotifierProvider.value(value: repo),
      ],
      child: MaterialApp(
        restorationScopeId: 'test',
        theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await _flush(tester);
}

Future<MachineRepository> _repo([Map<MachineProfile, MachineSecrets> saved = const {}]) async {
  final repo = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
  await repo.load();
  for (final e in saved.entries) {
    await repo.save(e.key, secrets: e.value);
  }
  return repo;
}

MachineProfile _machine(String id, {SshAuth auth = SshAuth.key}) =>
    MachineProfile(id: id, label: 'box', host: 'box.example', username: 'me', auth: auth);

Finder _field(int i) => find.byType(TextFormField).at(i);

// Name 0, Host 1, Port 2, Username 3, Key 4, Passphrase 5.
/// The key field's text as the form saves it: the form trims it.
String _keyText(WidgetTester tester) => tester.widget<TextFormField>(_field(4)).controller!.text.trim();

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _flush(tester);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _flush(tester);
}

Future<void> _tapButton(WidgetTester tester, String label) => _tap(tester, find.widgetWithText(AppButton, label));

/// A tap whose work leaves the UI isolate (unlocking a protected key): real
/// time has to pass, which the fake-async test clock does not give.
Future<void> _tapAndWaitForKey(WidgetTester tester, String label) async {
  final button = find.widgetWithText(AppButton, label);
  await tester.ensureVisible(button);
  await _flush(tester);
  final vm = Provider.of<MachineFormViewModel>(tester.element(find.byType(Scaffold).first), listen: false);
  await tester.runAsync(() async {
    await tester.tap(button);
    for (var i = 0; i < 500 && !vm.readingKey; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    for (var i = 0; i < 500 && vm.readingKey; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await _flush(tester);
}

Future<void> _tearDown(WidgetTester tester) => tester.pumpWidget(const SizedBox());

/// The shown public key line: the one mono Text that starts like one.
Finder get _publicLine => find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('ssh-'));

String _shownLine(WidgetTester tester) => tester.widget<Text>(_publicLine).data!;

List<String?> _clipboardWrites(WidgetTester tester) {
  final writes = <String?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') writes.add((call.arguments as Map)['text'] as String?);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return writes;
}

/// Every string a screen reader or the eye could meet, outside the text field.
List<String> _visibleStrings(WidgetTester tester) {
  final strings = <String>[
    for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
  ];
  void walk(SemanticsNode node) {
    strings
      ..add(node.label)
      ..add(node.tooltip)
      ..add(node.hint);
    node.visitChildren((c) {
      walk(c);
      return true;
    });
  }

  walk(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return strings;
}

void main() {
  group('Generate key', () {
    testWidgets('fills the key field with a key dartssh2 reads, and shows its public half', (tester) async {
      final repo = await _repo();
      await _pump(tester, const MachineFormScreen(), repo);
      await tester.enterText(_field(0), 'Build box');
      expect(_keyText(tester), isEmpty);

      await _tapButton(tester, 'Generate key');

      final pem = _keyText(tester);
      expect(pem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      final pair = SSHKeyPair.fromPem(pem).single;
      expect(pair.name, 'ssh-ed25519');
      expect(find.text('Public key'), findsOneWidget);
      expect(_shownLine(tester), KeyGenerator.readPublicKey(pem).line, reason: 'the panel shows this very key');
      expect(_shownLine(tester), endsWith(' herdr-mobile@Build-box'), reason: 'named after the machine');
      await _tearDown(tester);
    });

    testWidgets('with no name yet the host names the key; with neither it is "phone"', (tester) async {
      final repo = await _repo();
      await _pump(tester, const MachineFormScreen(), repo);
      await tester.enterText(_field(1), 'bartholomew.example.com');
      await _tapButton(tester, 'Generate key');
      expect(_shownLine(tester), endsWith(' herdr-mobile@bartholomew.example.com'));
      await _tearDown(tester);

      await _pump(tester, const MachineFormScreen(), await _repo());
      await _tapButton(tester, 'Generate key');
      expect(_shownLine(tester), endsWith(' herdr-mobile@phone'));
      await _tearDown(tester);
    });

    testWidgets('the generated key is saved through the normal path, with no passphrase', (tester) async {
      final repo = await _repo();
      await _pump(tester, const MachineFormScreen(), repo);
      await tester.enterText(_field(1), 'box.example');
      await tester.enterText(_field(3), 'me');
      await _tapButton(tester, 'Generate key');
      final pem = _keyText(tester);

      await _tapButton(tester, 'Add machine');

      final saved = await repo.secretsFor(repo.machines.single.id);
      expect(saved.privateKeyPem, pem);
      expect(saved.passphrase, isNull);
      expect(SSHKeyPair.fromPem(saved.privateKeyPem!, saved.passphrase), hasLength(1));
      await _tearDown(tester);
    });

    testWidgets('a passphrase typed before generating is cleared: the new key has none', (tester) async {
      final repo = await _repo();
      await _pump(tester, const MachineFormScreen(), repo);
      await tester.enterText(_field(5), 'old passphrase');

      await _tapButton(tester, 'Generate key');

      expect(tester.widget<TextFormField>(_field(5)).controller!.text, isEmpty);
      await _tearDown(tester);
    });

    testWidgets('Test connection runs with the generated key', (tester) async {
      final repo = await _repo();
      MachineSecrets? used;
      await _pump(
        tester,
        const MachineFormScreen(),
        repo,
        transportFactory: (profile, secrets, pin, notice) {
          used = secrets;
          return FakeTransport(snapshotWith(const []));
        },
      );
      await tester.enterText(_field(1), 'box.example');
      await tester.enterText(_field(3), 'me');
      await _tapButton(tester, 'Generate key');
      final pem = _keyText(tester);

      await _tapButton(tester, 'Test connection');

      expect(used?.privateKeyPem, pem);
      expect(used?.passphrase, isNull);
      expect(find.textContaining('Connected'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets('over a typed key it asks first, and Cancel keeps that key untouched', (tester) async {
      final repo = await _repo();
      await _pump(tester, const MachineFormScreen(), repo);
      await tester.enterText(_field(4), 'MY-OLD-KEY');

      await _tapButton(tester, 'Generate key');
      expect(find.text('Replace the current key?'), findsOneWidget);
      expect(_keyText(tester), 'MY-OLD-KEY', reason: 'nothing changed while the question is open');

      await _tap(tester, find.widgetWithText(AppButton, 'Cancel'));
      expect(find.text('Replace the current key?'), findsNothing);
      expect(_keyText(tester), 'MY-OLD-KEY');
      expect(find.text('Public key'), findsNothing);

      await _tapButton(tester, 'Generate key');
      await _tap(tester, find.widgetWithText(AppButton, 'Generate new key'));
      expect(_keyText(tester), startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      expect(find.text('Public key'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets('generating twice asks the second time and yields a different key', (tester) async {
      final repo = await _repo();
      await _pump(tester, const MachineFormScreen(), repo);
      await _tapButton(tester, 'Generate key');
      final first = _keyText(tester);
      final firstLine = _shownLine(tester);
      expect(find.text('Replace the current key?'), findsNothing, reason: 'an empty field needs no question');

      await _tapButton(tester, 'Generate key');
      expect(find.text('Replace the current key?'), findsOneWidget);
      await _tap(tester, find.widgetWithText(AppButton, 'Generate new key'));

      expect(_keyText(tester), isNot(first));
      expect(_shownLine(tester), isNot(firstLine));
      await _tearDown(tester);
    });

    testWidgets('editing a machine with a saved key asks too, and the replaced key drops its passphrase', (tester) async {
      final old = KeyGenerator.generate(label: 'old');
      final protected = (SSHKeyPair.fromPem(old.privateKeyPem).single as OpenSSHEd25519KeyPair)
          .toPem(passphrase: 'OLDPASS', rounds: 1);
      final repo = await _repo({_machine('k'): MachineSecrets(privateKeyPem: protected, passphrase: 'OLDPASS')});
      await _pump(
        tester,
        MachineFormScreen(existing: repo.machines.single),
        repo,
        transportFactory: (profile, secrets, pin, notice) => FakeTransport(snapshotWith(const [])),
      );
      expect(_keyText(tester), isEmpty, reason: 'the saved key is never loaded into the form');

      await _tapButton(tester, 'Generate key');
      expect(find.text('Replace the current key?'), findsOneWidget);
      await _tap(tester, find.widgetWithText(AppButton, 'Generate new key'));
      final fresh = _keyText(tester);
      await _tapButton(tester, 'Save');

      final saved = await repo.secretsFor('k');
      expect(saved.privateKeyPem, fresh);
      expect(saved.passphrase, isNull, reason: 'the old passphrase does not fit the new key and would lock it out');
      expect(SSHKeyPair.fromPem(saved.privateKeyPem!, saved.passphrase), hasLength(1));
      await _tearDown(tester);
    });

    testWidgets('typing in the key field removes a public key that no longer describes it', (tester) async {
      final repo = await _repo();
      await _pump(tester, const MachineFormScreen(), repo);
      await _tapButton(tester, 'Generate key');
      expect(find.text('Public key'), findsOneWidget);

      await tester.enterText(_field(4), 'something else');
      await _flush(tester);

      expect(find.text('Public key'), findsNothing);
      expect(_publicLine, findsNothing);
      await _tearDown(tester);
    });

    testWidgets('a generated key comes back after Android reclaims the process, and goes with Discard',
        (tester) async {
      final repo = await _repo();
      await _pump(
        tester,
        Builder(
          builder: (context) => Center(
            child: AppButton(label: 'Open form', onPressed: () => openMachineForm(context)),
          ),
        ),
        repo,
      );
      await tester.tap(find.text('Open form'));
      await _flush(tester);
      await tester.pump(const Duration(seconds: 1));
      await _tapButton(tester, 'Generate key');
      final key = _keyText(tester);
      final line = _shownLine(tester);

      // The person copies the command and goes to the host; the phone
      // reclaims the app meanwhile.
      await tester.restartAndRestore();
      await _flush(tester);

      expect(_keyText(tester), key, reason: 'the private half of the installed key is not lost');
      expect(_shownLine(tester), line);

      await _tap(tester, find.byTooltip('Back'));
      await _tapButton(tester, 'Discard');
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MachineFormScreen), findsNothing);
      expect(await repo.keyDraft(), isNull, reason: 'a discarded key is kept nowhere');
      await _tearDown(tester);
    });
  });

  group('copying', () {
    testWidgets('Copy public key puts the line, and only the line, on the clipboard', (tester) async {
      final writes = _clipboardWrites(tester);
      await _pump(tester, const MachineFormScreen(), await _repo());
      await tester.enterText(_field(0), 'box');
      await _tapButton(tester, 'Generate key');
      final line = _shownLine(tester);

      await _tap(tester, find.text('Copy public key'));

      expect(writes, [line]);
      expect(find.text('Public key copied'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets('Copy authorized_keys command puts the whole one-liner on the clipboard', (tester) async {
      final writes = _clipboardWrites(tester);
      await _pump(tester, const MachineFormScreen(), await _repo());
      await tester.enterText(_field(0), 'box');
      await _tapButton(tester, 'Generate key');
      final line = _shownLine(tester);

      await _tap(tester, find.text('Copy authorized_keys command'));

      expect(writes, [
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$line' >> ~/.ssh/authorized_keys "
            '&& chmod 600 ~/.ssh/authorized_keys',
      ]);
      expect(find.text('Command copied'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets('neither copy row can put the private key on the clipboard', (tester) async {
      final writes = _clipboardWrites(tester);
      await _pump(tester, const MachineFormScreen(), await _repo());
      await _tapButton(tester, 'Generate key');
      final body = _keyText(tester).split('\n')[1];

      await _tap(tester, find.text('Copy public key'));
      await _tap(tester, find.text('Copy authorized_keys command'));

      expect(writes, hasLength(2));
      for (final w in writes) {
        expect(w, isNot(contains('PRIVATE KEY')));
        expect(w, isNot(contains(body)));
      }
      await _tearDown(tester);
    });

    testWidgets('the panel says what to do with the command', (tester) async {
      await _pump(tester, const MachineFormScreen(), await _repo());
      await _tapButton(tester, 'Generate key');

      expect(find.textContaining('Run the command once on the machine'), findsOneWidget);
      expect(find.textContaining('Tailscale, GitHub'), findsOneWidget);
      await _tearDown(tester);
    });
  });

  group('Show public key', () {
    testWidgets('derives it from the saved key and never shows the private one', (tester) async {
      final handle = tester.ensureSemantics();
      final saved = KeyGenerator.generate(label: 'saved');
      final repo = await _repo({_machine('k'): MachineSecrets(privateKeyPem: saved.privateKeyPem)});
      await _pump(tester, MachineFormScreen(existing: repo.machines.single), repo);
      expect(_publicLine, findsNothing, reason: 'shown on request, not on open');

      await _tapButton(tester, 'Show public key');

      expect(_shownLine(tester), saved.publicKeyLine);
      expect(_keyText(tester), isEmpty, reason: 'the private key is not put in the field');
      final body = saved.privateKeyPem.split('\n')[1];
      for (final s in _visibleStrings(tester)) {
        expect(s, isNot(contains('PRIVATE KEY')));
        expect(s, isNot(contains(body)));
      }
      handle.dispose();
      await _tearDown(tester);
    });

    testWidgets('the copy rows work for a saved key too', (tester) async {
      final writes = _clipboardWrites(tester);
      final saved = KeyGenerator.generate(label: 'saved');
      final repo = await _repo({_machine('k'): MachineSecrets(privateKeyPem: saved.privateKeyPem)});
      await _pump(tester, MachineFormScreen(existing: repo.machines.single), repo);
      await _tapButton(tester, 'Show public key');

      await _tap(tester, find.text('Copy public key'));

      expect(writes, [saved.publicKeyLine]);
      await _tearDown(tester);
    });

    testWidgets('is offered only when a key is saved and the field is empty', (tester) async {
      final saved = KeyGenerator.generate();
      final withKey = await _repo({_machine('k'): MachineSecrets(privateKeyPem: saved.privateKeyPem)});
      await _pump(tester, MachineFormScreen(existing: withKey.machines.single), withKey);
      expect(find.widgetWithText(AppButton, 'Show public key'), findsOneWidget);

      await tester.enterText(_field(4), 'a new key being pasted');
      await _flush(tester);
      expect(find.widgetWithText(AppButton, 'Show public key'), findsNothing, reason: 'the field now holds another key');
      await _tearDown(tester);

      final noKey = await _repo({_machine('n'): const MachineSecrets()});
      await _pump(tester, MachineFormScreen(existing: noKey.machines.single), noKey);
      expect(find.widgetWithText(AppButton, 'Show public key'), findsNothing, reason: 'nothing saved to derive from');
      await _tearDown(tester);

      await _pump(tester, const MachineFormScreen(), await _repo());
      expect(find.widgetWithText(AppButton, 'Show public key'), findsNothing, reason: 'a new machine has no saved key');
      await _tearDown(tester);
    });

    group('protected key', () {
      Future<({MachineRepository repo, GeneratedKey key})> protectedMachine({String? savedPassphrase}) async {
        final key = KeyGenerator.generate(label: 'locked');
        final pem = (SSHKeyPair.fromPem(key.privateKeyPem).single as OpenSSHEd25519KeyPair)
            .toPem(passphrase: 'right', rounds: 1);
        final repo = await _repo({_machine('k'): MachineSecrets(privateKeyPem: pem, passphrase: savedPassphrase)});
        return (repo: repo, key: key);
      }

      testWidgets('with no passphrase anywhere it says one is needed', (tester) async {
        final m = await protectedMachine();
        await _pump(tester, MachineFormScreen(existing: m.repo.machines.single), m.repo);

        await _tapAndWaitForKey(tester, 'Show public key');

        expect(find.textContaining('This key has a passphrase'), findsOneWidget);
        expect(_publicLine, findsNothing);
        await _tearDown(tester);
      });

      testWidgets('a wrong passphrase says so, and the right one then shows the key', (tester) async {
        final m = await protectedMachine();
        await _pump(tester, MachineFormScreen(existing: m.repo.machines.single), m.repo);

        await tester.enterText(_field(5), 'wrong');
        await _tapAndWaitForKey(tester, 'Show public key');
        expect(find.text('That passphrase does not open the saved key.'), findsOneWidget);
        expect(_publicLine, findsNothing);
        expect(find.text('Copy public key'), findsNothing);

        await tester.enterText(_field(5), 'right');
        await _tapAndWaitForKey(tester, 'Show public key');
        expect(find.text('That passphrase does not open the saved key.'), findsNothing, reason: 'the old message is gone');
        expect(_shownLine(tester), m.key.publicKeyLine);
        await _tearDown(tester);
      });

      testWidgets('a blank field falls back to the saved passphrase', (tester) async {
        final m = await protectedMachine(savedPassphrase: 'right');
        await _pump(tester, MachineFormScreen(existing: m.repo.machines.single), m.repo);

        await _tapAndWaitForKey(tester, 'Show public key');

        expect(_shownLine(tester), m.key.publicKeyLine);
        await _tearDown(tester);
      });
    });

    testWidgets('a saved value that is not a key says it could not be read', (tester) async {
      final repo = await _repo({_machine('k'): const MachineSecrets(privateKeyPem: 'not a key at all')});
      await _pump(tester, MachineFormScreen(existing: repo.machines.single), repo);

      await _tapButton(tester, 'Show public key');

      expect(find.text('The saved key could not be read.'), findsOneWidget);
      expect(_publicLine, findsNothing);
      await _tearDown(tester);
    });
  });

  group('no private key text outside the field', () {
    testWidgets('after generating, no Text or semantics label carries it', (tester) async {
      final handle = tester.ensureSemantics();
      final repo = await _repo();
      await _pump(tester, const MachineFormScreen(), repo);
      await _tapButton(tester, 'Generate key');
      final pem = _keyText(tester);
      final body = pem.split('\n')[1];

      final strings = _visibleStrings(tester);
      // The field's own placeholder (hidden while it has text) names the
      // format; anything else naming a private key, or its body, is a leak.
      const placeholder = '-----BEGIN OPENSSH PRIVATE KEY-----';
      for (final s in strings) {
        if (s != placeholder) expect(s, isNot(contains('PRIVATE KEY')));
        expect(s, isNot(contains(body)));
      }
      expect(strings.where((s) => s.startsWith('ssh-ed25519 ')), isNotEmpty, reason: 'the public line is the one key text shown');
      handle.dispose();
      await _tearDown(tester);
    });
  });

  group('replacing the key of a machine that already has one', () {
    const refused = HerdrTransportException('Permission denied (publickey).', fatal: true);

    /// A host that lets in only the keys in [authorized]; [tried] records the
    /// key every connection test was made with.
    ({TransportFactory transport, Set<String?> authorized, List<String?> tried}) host(String authorizedKey) {
      final authorized = <String?>{authorizedKey.trim()};
      final tried = <String?>[];
      return (
        authorized: authorized,
        tried: tried,
        transport: (profile, secrets, pin, notice) {
          tried.add(secrets.privateKeyPem);
          return authorized.contains(secrets.privateKeyPem)
              ? FakeTransport(snapshotWith(const []))
              : (FakeTransport()..failure = refused);
        },
      );
    }

    late GeneratedKey old;
    late MachineRepository repo;
    late ({TransportFactory transport, Set<String?> authorized, List<String?> tried}) h;

    Future<void> open(WidgetTester tester) async {
      old = KeyGenerator.generate(label: 'old');
      repo = await _repo({_machine('k'): MachineSecrets(privateKeyPem: old.privateKeyPem)});
      h = host(old.privateKeyPem);
      await _pump(tester, MachineFormScreen(existing: repo.machines.single), repo, transportFactory: h.transport);
    }

    Future<String> generate(WidgetTester tester) async {
      await _tapButton(tester, 'Generate key');
      await _tap(tester, find.widgetWithText(AppButton, 'Generate new key'));
      return _keyText(tester);
    }

    const warning = 'This replaces the key this machine uses now. Run the command on the host first, '
        'then Test connection, then Save.';

    testWidgets('the generated-key panel says to install it first, but only when it replaces a saved key', (tester) async {
      await open(tester);
      await generate(tester);
      expect(find.text(warning), findsOneWidget);
      await _tearDown(tester);

      await _pump(tester, const MachineFormScreen(), await _repo());
      await _tapButton(tester, 'Generate key');
      expect(find.text(warning), findsNothing, reason: 'a new machine has nothing to lock out of');
      await _tearDown(tester);

      await open(tester);
      await _tapButton(tester, 'Show public key');
      expect(find.text(warning), findsNothing, reason: 'the saved key is already installed');
      await _tearDown(tester);
    });

    testWidgets('Save tests the new key first and saves it when the host accepts it', (tester) async {
      await open(tester);
      final fresh = await generate(tester);
      h.authorized.add(fresh);

      await _tapButton(tester, 'Save');

      expect(h.tried, [fresh], reason: 'the test used the new key, not the old one');
      expect(find.text('The new key could not connect'), findsNothing);
      expect((await repo.secretsFor('k')).privateKeyPem, fresh);
      await _tearDown(tester);
    });

    testWidgets('a test already passed is not repeated by Save', (tester) async {
      await open(tester);
      h.authorized.add(await generate(tester));

      await _tapButton(tester, 'Test connection');
      await _tapButton(tester, 'Save');

      expect(h.tried, hasLength(1));
      await _tearDown(tester);
    });

    testWidgets('a refused key saves nothing and says why, with both ways out', (tester) async {
      await open(tester);
      await generate(tester);

      await _tapButton(tester, 'Save');

      expect(find.text('The new key could not connect'), findsOneWidget);
      expect(find.text('Permission denied (publickey).'), findsWidgets);
      expect(find.textContaining('locks this phone out'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Save anyway'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Keep the old key'), findsOneWidget);
      expect((await repo.secretsFor('k')).privateKeyPem, old.privateKeyPem, reason: 'the old key is still saved');
      await _tearDown(tester);
    });

    testWidgets('Keep the old key empties the field and leaves the saved key and form usable', (tester) async {
      await open(tester);
      await generate(tester);
      await _tapButton(tester, 'Save');

      await _tapButton(tester, 'Keep the old key');

      expect(find.text('The new key could not connect'), findsNothing);
      expect(_keyText(tester), isEmpty);
      expect(find.text('Public key'), findsNothing, reason: 'the panel described the discarded key');
      expect(find.text('Could not connect'), findsNothing, reason: 'the result described the discarded key');
      expect(find.byType(MachineFormScreen), findsOneWidget, reason: 'still editing');
      expect((await repo.secretsFor('k')).privateKeyPem, old.privateKeyPem);

      h.tried.clear();
      await _tapButton(tester, 'Save');
      expect(h.tried, isEmpty, reason: 'no key replaced, so no test gate');
      expect((await repo.secretsFor('k')).privateKeyPem, old.privateKeyPem);
      await _tearDown(tester);
    });

    testWidgets('Save anyway saves the new key', (tester) async {
      await open(tester);
      final fresh = await generate(tester);
      await _tapButton(tester, 'Save');

      await _tapButton(tester, 'Save anyway');

      expect((await repo.secretsFor('k')).privateKeyPem, fresh);
      await _tearDown(tester);
    });

    testWidgets('dismissing the sheet saves nothing and keeps the new key in the field', (tester) async {
      await open(tester);
      final fresh = await generate(tester);
      await _tapButton(tester, 'Save');

      await tester.tapAt(const Offset(180, 30)); // the barrier above the sheet
      await _flush(tester);

      expect(find.text('The new key could not connect'), findsNothing);
      expect(_keyText(tester), fresh);
      expect((await repo.secretsFor('k')).privateKeyPem, old.privateKeyPem);
      await _tearDown(tester);
    });

    testWidgets('a pasted replacement key is held to the same test', (tester) async {
      await open(tester);
      await tester.enterText(_field(4), KeyGenerator.generate().privateKeyPem);

      await _tapButton(tester, 'Save');

      expect(find.text('The new key could not connect'), findsOneWidget);
      await _tearDown(tester);
    });

    testWidgets('editing without touching the key never runs the gate', (tester) async {
      await open(tester);
      await tester.enterText(_field(0), 'renamed');

      await _tapButton(tester, 'Save');

      expect(h.tried, isEmpty);
      expect(repo.machines.single.label, 'renamed');
      await _tearDown(tester);
    });

    testWidgets('a new machine is saved without a gate', (tester) async {
      final fresh = await _repo();
      final h2 = host('unused');
      await _pump(tester, const MachineFormScreen(), fresh, transportFactory: h2.transport);
      await tester.enterText(_field(1), 'box.example');
      await tester.enterText(_field(3), 'me');
      await _tapButton(tester, 'Generate key');

      await _tapButton(tester, 'Add machine');

      expect(h2.tried, isEmpty);
      expect(fresh.machines, hasLength(1));
      await _tearDown(tester);
    });
  });

  group('saving a replaced key', () {
    MachineFormValues values({String key = '', String passphrase = ''}) => MachineFormValues(
          label: '',
          host: 'box.example',
          port: 22,
          username: 'me',
          auth: SshAuth.key,
          privateKey: key,
          passphrase: passphrase,
        );

    Future<MachineFormViewModel> editing(MachineRepository repo) async => MachineFormViewModel(
          repo: repo,
          existing: repo.machines.single,
          transportFactory: _noTransport,
        );

    Future<MachineRepository> savedWithPassphrase() =>
        _repo({_machine('k'): const MachineSecrets(privateKeyPem: 'OLD-KEY', passphrase: 'OLDPASS')});

    test('a new key with a blank passphrase does not inherit the old passphrase', () async {
      final repo = await savedWithPassphrase();
      await (await editing(repo)).save(values(key: 'NEW-KEY'));

      final saved = await repo.secretsFor('k');
      expect(saved.privateKeyPem, 'NEW-KEY');
      expect(saved.passphrase, isNull);
    });

    test('a new key with its own passphrase keeps that one', () async {
      final repo = await savedWithPassphrase();
      await (await editing(repo)).save(values(key: 'NEW-KEY', passphrase: 'NEWPASS'));

      final saved = await repo.secretsFor('k');
      expect(saved.privateKeyPem, 'NEW-KEY');
      expect(saved.passphrase, 'NEWPASS');
    });

    test('no new key keeps both the saved key and its passphrase', () async {
      final repo = await savedWithPassphrase();
      await (await editing(repo)).save(values());

      final saved = await repo.secretsFor('k');
      expect(saved.privateKeyPem, 'OLD-KEY');
      expect(saved.passphrase, 'OLDPASS');
    });
  });

  group('layout', () {
    for (final brightness in Brightness.values) {
      for (final (width, scale) in [(360.0, 1.0), (320.0, 2.0)]) {
        testWidgets('the panel fits at ${width.toInt()}dp ${scale}x, ${brightness.name}, with a very long name', (tester) async {
          await _pump(
            tester,
            const MachineFormScreen(),
            await _repo(),
            width: width,
            scale: scale,
            brightness: brightness,
          );
          await tester.enterText(_field(0), 'build-server-eu-west-2-production-primary-gpu-cluster-0042');
          await _tapButton(tester, 'Generate key');
          await tester.ensureVisible(find.text('Copy authorized_keys command'));
          await _flush(tester);

          expect(tester.takeException(), isNull, reason: 'no overflow');
          final line = tester.getRect(_publicLine);
          expect(line.left, greaterThanOrEqualTo(0));
          expect(line.right, lessThanOrEqualTo(width), reason: 'the long public key wraps inside the screen');
          for (final label in ['Copy public key', 'Copy authorized_keys command']) {
            final row = find.ancestor(of: find.text(label), matching: find.byType(PressBuilder));
            expect(tester.getSize(row).height, greaterThanOrEqualTo(44), reason: label);
          }
          expect(tester.getSize(find.widgetWithText(AppButton, 'Generate key')).height, greaterThanOrEqualTo(44));
          await _tearDown(tester);
        });
      }
    }

    testWidgets('both buttons wrap onto two lines under large text instead of overflowing', (tester) async {
      final saved = KeyGenerator.generate();
      final repo = await _repo({_machine('k'): MachineSecrets(privateKeyPem: saved.privateKeyPem)});
      await _pump(tester, MachineFormScreen(existing: repo.machines.single), repo, width: 320, scale: 2);
      await tester.ensureVisible(find.widgetWithText(AppButton, 'Generate key'));
      await _flush(tester);

      expect(tester.takeException(), isNull);
      final generate = tester.getRect(find.widgetWithText(AppButton, 'Generate key'));
      final show = tester.getRect(find.widgetWithText(AppButton, 'Show public key'));
      expect(show.right, lessThanOrEqualTo(320));
      expect(generate.right, lessThanOrEqualTo(320));
      await _tearDown(tester);
    });
  });
}
