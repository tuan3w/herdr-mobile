import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart';

import 'support/fake_transport.dart';
import 'support/memory_stores.dart';

MachineFormValues _values({String host = 'old.local', String label = ''}) => MachineFormValues(
      label: label,
      host: host,
      port: 22,
      username: 'me',
      auth: SshAuth.key,
      privateKey: 'KEY',
    );

/// A machine that answers only when the test lets it.
class _Gated extends FakeTransport {
  final gate = Completer<void>();

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    await gate.future;
    return super.request(method, params);
  }
}

void main() {
  late MachineRepository repo;

  setUp(() async {
    repo = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    await repo.load();
  });

  /// The first host asked about answers when [slow] is released; every later
  /// one answers at once. Each reports its own host key on first contact.
  MachineFormViewModel form(_Gated slow) {
    var first = true;
    return MachineFormViewModel(
      repo: repo,
      transportFactory: (profile, secrets, onPin, onNotice) {
        onPin('SHA256:of-${profile.host}');
        if (first) {
          first = false;
          return slow;
        }
        return FakeTransport();
      },
    );
  }

  test('a test overtaken by an edit reports nothing, and Save pins no key for the new host', () async {
    final slow = _Gated();
    final vm = form(slow);

    final running = vm.test(_values());
    await Future<void>.delayed(Duration.zero);
    expect(vm.testState, TestState.testing);

    vm.invalidateTest(); // the person edits the host while the test is out
    slow.gate.complete();
    await running;

    expect(vm.testState, TestState.idle, reason: 'the old result describes a host that is gone');
    expect(vm.fingerprint, isNull);

    await vm.save(_values(host: 'new.local'));
    expect(repo.machines.single.hostKeyFingerprint, isNull, reason: 'nothing was seen of new.local');
  });

  test('a newer test is not overwritten by the older one finishing late', () async {
    final slow = _Gated();
    final vm = form(slow);

    final older = vm.test(_values());
    await Future<void>.delayed(Duration.zero);
    vm.invalidateTest();
    await vm.test(_values(host: 'new.local'));
    expect(vm.testState, TestState.ok);

    slow.gate.complete();
    await older;

    expect(vm.testState, TestState.ok);
    expect(vm.fingerprint, 'SHA256:of-new.local');
  });

  test('a test of one host never vouches for another: Save pins only what was tested', () async {
    final vm = form(_Gated()..gate.complete());
    await vm.test(_values());
    expect(vm.testedFor(_values()), isTrue);
    expect(vm.testedFor(_values(label: 'Renamed')), isTrue, reason: 'a label does not reach the host');
    expect(vm.testedFor(_values(host: 'new.local')), isFalse);

    // The fields changed without the form telling the model.
    await vm.save(_values(host: 'new.local'));
    expect(repo.machines.single.hostKeyFingerprint, isNull);
  });
}
