import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';

MachineProfile _machine(SshAuth auth) => MachineProfile(
      id: 'a',
      label: 'Box',
      host: 'box',
      port: 22,
      username: 'dev',
      auth: auth,
    );

void main() {
  _wrongServerTests();
  // Tailscale says why it refuses (a policy, an unknown user) in a login
  // banner, then closes the login. The person can only fix what they can read.
  group('a refused sign-in', () {
    test('names the machine\'s reason, for Tailscale and for a key or password', () {
      final policy = signInRefused(
        _machine(SshAuth.none),
        'tailnet policy does not permit you to SSH as user "dev"',
      );
      expect(policy.message, contains('tailnet policy does not permit you to SSH as user "dev"'));

      final key = signInRefused(_machine(SshAuth.key), 'Access denied');
      expect(key.message, contains('Access denied'));
    });

    test('is never retried: asking again gets the same answer', () {
      for (final auth in SshAuth.values) {
        expect(signInRefused(_machine(auth), null).fatal, isTrue, reason: '$auth, no reason');
        expect(signInRefused(_machine(auth), 'no').fatal, isTrue, reason: '$auth, reason');
      }
    });

    test('still says what to check when the machine gave no reason', () {
      expect(signInRefused(_machine(SshAuth.none), null).message, contains('"dev"'));
      expect(signInRefused(_machine(SshAuth.password), null).message, contains('username'));
    });
  });
}

void _wrongServerTests() {
  // The Tailscale apps for macOS cannot run Tailscale SSH: a Mac reached over
  // Tailscale answers as its own OpenSSH, which no "no credentials" login opens.
  group('Tailscale sign-in against another SSH server', () {
    test('is told apart by what the server calls itself', () {
      final tailscale = _machine(SshAuth.none);
      expect(answeredByAnotherServer(tailscale, 'SSH-2.0-OpenSSH_10.3'), isTrue);
      expect(answeredByAnotherServer(tailscale, 'SSH-2.0-Tailscale'), isFalse);
      expect(answeredByAnotherServer(tailscale, null), isFalse, reason: 'not known yet');
      // A key or a password is meant for a regular server.
      expect(answeredByAnotherServer(_machine(SshAuth.key), 'SSH-2.0-OpenSSH_10.3'), isFalse);
      expect(answeredByAnotherServer(_machine(SshAuth.password), 'SSH-2.0-OpenSSH_10.3'), isFalse);
    });

    test('names the server and the way forward instead of blaming the tailnet policy', () {
      final e = signInRefused(_machine(SshAuth.none), null, server: 'SSH-2.0-OpenSSH_10.3');
      expect(e.fatal, isTrue);
      expect(e.message, contains('OpenSSH_10.3'));
      expect(e.message, contains('Private key'));
      expect(e.message, isNot(contains('policy')));
    });
  });
}
