import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart';

import 'support/fake_transport.dart';
import 'support/memory_stores.dart';

MachineFormValues _values({
  String host = 'box.local',
  int port = 22,
  String privateKey = '',
  String passphrase = '',
  String password = '',
  SshAuth auth = SshAuth.key,
  String label = '',
}) =>
    MachineFormValues(
      label: label,
      host: host,
      port: port,
      username: 'me',
      auth: auth,
      privateKey: privateKey,
      passphrase: passphrase,
      password: password,
    );

void main() {
  late MemoryProfileStore profiles;
  late MemorySecretStore secrets;
  late MachineRepository repo;

  setUp(() async {
    profiles = MemoryProfileStore();
    secrets = MemorySecretStore();
    repo = MachineRepository(profiles: profiles, secrets: secrets);
    await repo.load();
  });

  /// A form VM whose "SSH" reports [fingerprint] on first contact and
  /// records the profile/secrets it was asked to connect with.
  MachineFormViewModel form({
    MachineProfile? existing,
    String fingerprint = 'SHA256:seen',
    Object? failure,
    List<({MachineProfile profile, MachineSecrets secrets})>? attempts,
    List<String> banners = const [],
  }) =>
      MachineFormViewModel(
        repo: repo,
        existing: existing,
        transportFactory: (profile, s, onPin, onNotice) {
          attempts?.add((profile: profile, secrets: s));
          if (profile.hostKeyFingerprint == null) onPin(fingerprint);
          banners.forEach(onNotice);
          return FakeTransport()..failure = failure;
        },
      );

  group('tailscale (no credentials)', () {
    test('stores no secrets even if other fields were filled in', () async {
      final vm = form();
      final values = _values(
        auth: SshAuth.none,
        privateKey: 'LEFTOVER KEY',
        password: 'leftover',
      );
      await vm.test(values);
      await vm.save(values);

      final saved = repo.machines.single;
      expect(saved.auth, SshAuth.none);
      final s = await repo.secretsFor(saved.id);
      expect(s.privateKeyPem, isNull);
      expect(s.password, isNull);
    });

    test('a sign-in banner during the test exposes the approval link', () async {
      final seen = <String?>[];
      final vm = form(banners: const [
        '# Tailscale SSH requires an additional check.\n'
            '# To authenticate, visit: https://login.tailscale.com/a/abc123',
      ]);
      vm.addListener(() => seen.add(vm.approvalUrl));

      await vm.test(_values(auth: SshAuth.none));

      expect(seen, contains('https://login.tailscale.com/a/abc123'));
    });

    test('a banner without a web link, or with a non-https one, is ignored', () async {
      final vm = form(banners: const [
        'Welcome!',
        'javascript:alert(1)',
        'http://login.tailscale.com/a/abc',
      ]);

      await vm.test(_values(auth: SshAuth.none));

      expect(vm.approvalUrl, isNull);
    });

    test('a new test clears the previous link', () async {
      final vm = form(banners: const ['visit https://login.tailscale.com/a/one']);
      await vm.test(_values(auth: SshAuth.none));
      expect(vm.approvalUrl, 'https://login.tailscale.com/a/one');

      final clean = form();
      await clean.test(_values(auth: SshAuth.none));
      expect(clean.approvalUrl, isNull);
    });
  });

  group('add', () {
    test('a successful test reports version and pins the seen host key on save',
        () async {
      final vm = form();
      await vm.test(_values(privateKey: 'KEY'));

      expect(vm.testState, TestState.ok);
      expect(vm.version, '9.9.9');
      expect(vm.fingerprint, 'SHA256:seen');

      await vm.save(_values(privateKey: 'KEY', label: 'Box'));
      final saved = repo.machines.single;
      expect(saved.label, 'Box');
      expect(saved.hostKeyFingerprint, 'SHA256:seen');
      expect((await repo.secretsFor(saved.id)).privateKeyPem, 'KEY');
    });

    test('a failed test reports the reason and saves nothing by itself', () async {
      final vm = form(failure: const HerdrTransportException('refused'));
      await vm.test(_values(privateKey: 'KEY'));

      expect(vm.testState, TestState.failed);
      expect(vm.message, 'refused');
      expect(repo.machines, isEmpty);
    });

    test('label falls back to the host', () async {
      await form().save(_values(privateKey: 'KEY'));
      expect(repo.machines.single.label, 'box.local');
    });

    test('editing a field invalidates a previous test result', () async {
      final vm = form();
      await vm.test(_values(privateKey: 'KEY'));
      vm.invalidateTest();
      expect(vm.testState, TestState.idle);
    });

    test('password auth does not store key material', () async {
      await form().save(_values(auth: SshAuth.password, password: 'pw'));
      final s = await repo.secretsFor(repo.machines.single.id);
      expect(s.password, 'pw');
      expect(s.privateKeyPem, isNull);
    });
  });

  group('edit', () {
    late MachineProfile existing;
    setUp(() async {
      await form().save(_values(privateKey: 'OLDKEY', passphrase: 'OLDPASS'));
      await repo.pinHostKey(repo.machines.single.id, 'SHA256:pinned');
      existing = repo.machines.single;
    });

    test('blank secret fields keep the stored secrets', () async {
      await form(existing: existing).save(_values(label: 'Renamed'));

      final s = await repo.secretsFor(existing.id);
      expect(s.privateKeyPem, 'OLDKEY');
      expect(s.passphrase, 'OLDPASS');
      expect(repo.machines.single.label, 'Renamed');
    });

    test('changing only the passphrase does not wipe the key', () async {
      await form(existing: existing).save(_values(passphrase: 'NEWPASS'));

      final s = await repo.secretsFor(existing.id);
      expect(s.privateKeyPem, 'OLDKEY');
      expect(s.passphrase, 'NEWPASS');
    });

    test('keeps the pinned host key while host and port are unchanged', () async {
      final attempts = <({MachineProfile profile, MachineSecrets secrets})>[];
      final vm = form(existing: existing, attempts: attempts);
      await vm.test(_values());
      await vm.save(_values());

      expect(attempts.single.profile.hostKeyFingerprint, 'SHA256:pinned',
          reason: 'test must verify against the pin');
      expect(repo.machines.single.hostKeyFingerprint, 'SHA256:pinned');
    });

    test('changing the host discards the pin and trusts the new machine afresh',
        () async {
      final vm = form(existing: existing, fingerprint: 'SHA256:other');
      await vm.test(_values(host: 'elsewhere.local'));
      await vm.save(_values(host: 'elsewhere.local'));

      expect(repo.machines.single.hostKeyFingerprint, 'SHA256:other');
    });

    test('changing the host without testing leaves it unpinned', () async {
      await form(existing: existing).save(_values(host: 'elsewhere.local'));
      expect(repo.machines.single.hostKeyFingerprint, isNull);
    });

    test('saving keeps the machine id and enabled flag', () async {
      await repo.save(existing.copyWith(enabled: false));
      final disabled = repo.machines.single;
      await form(existing: disabled).save(_values());

      expect(repo.machines.single.id, existing.id);
      expect(repo.machines.single.enabled, isFalse);
    });
  });

  group('repository', () {
    test('remove deletes the profile and its secrets', () async {
      await form().save(_values(privateKey: 'KEY'));
      final id = repo.machines.single.id;

      await repo.remove(id);

      expect(repo.machines, isEmpty);
      expect(profiles.profiles, isEmpty);
      expect((await repo.secretsFor(id)).privateKeyPem, isNull);
    });

    test('profiles persist and reload in order', () async {
      await form().save(_values(host: 'a.local', privateKey: 'K'));
      await form().save(_values(host: 'b.local', privateKey: 'K'));

      final reloaded = MachineRepository(profiles: profiles, secrets: secrets);
      await reloaded.load();
      expect(reloaded.machines.map((m) => m.host), ['a.local', 'b.local']);
    });
  });
}
