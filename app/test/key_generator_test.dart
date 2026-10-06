import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// The public-key class is not exported by the package; verifying a signature
// against the exported line is the only independent proof the halves match.
import 'package:dartssh2/src/hostkey/hostkey_ed25519.dart' show SSHEd25519PublicKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/key_generator.dart';

OpenSSHEd25519KeyPair _read(String pem, [String? passphrase]) {
  final pairs = SSHKeyPair.fromPem(pem, passphrase);
  expect(pairs, hasLength(1));
  return pairs.single as OpenSSHEd25519KeyPair;
}

Uint8List _blobOf(String line) => base64.decode(line.split(' ')[1]);

/// The executable called [name] on PATH, or null.
String? _onPath(String name) {
  final separator = Platform.isWindows ? ';' : ':';
  for (final dir in (Platform.environment['PATH'] ?? '').split(separator)) {
    if (dir.isEmpty) continue;
    final candidate = File('$dir/$name');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

void main() {
  group('generate', () {
    test('the private key is an OpenSSH PEM that dartssh2 reads back, without a passphrase', () {
      final key = KeyGenerator.generate(label: 'box');

      expect(key.privateKeyPem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      expect(key.privateKeyPem.trim(), endsWith('-----END OPENSSH PRIVATE KEY-----'));
      expect(SSHKeyPair.isEncryptedPem(key.privateKeyPem), isFalse);
      final pair = _read(key.privateKeyPem);
      expect(pair.name, 'ssh-ed25519');
      expect(pair.comment, 'herdr-mobile@box', reason: 'the comment is stored in the key too');
    });

    test('the public line is exactly what the read-back pair exports', () {
      final key = KeyGenerator.generate(label: 'box');
      final pair = _read(key.privateKeyPem);

      expect(key.publicKeyLine, 'ssh-ed25519 ${base64.encode(pair.toPublicKey().encode())} herdr-mobile@box');
      expect(
        key.publicKeyLine,
        matches(RegExp(r'^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43} herdr-mobile@box$')),
        reason: 'the fixed Ed25519 wire prefix plus 32 key bytes, no padding',
      );
    });

    test('the public half belongs to the private half: a signature verifies against the line', () {
      final key = KeyGenerator.generate();
      final pair = _read(key.privateKeyPem);
      final message = Uint8List.fromList(utf8.encode('proof of possession'));

      final publicKey = SSHEd25519PublicKey.decode(_blobOf(key.publicKeyLine));
      expect(publicKey.verify(message, pair.sign(message)), isTrue);
      expect(
        () => publicKey.verify(Uint8List.fromList(utf8.encode('another message')), pair.sign(message)),
        throwsException,
        reason: 'the check can fail, so passing means something',
      );
    });

    test('two keys differ in every part', () {
      final a = KeyGenerator.generate(label: 'box');
      final b = KeyGenerator.generate(label: 'box');

      expect(a.privateKeyPem, isNot(b.privateKeyPem));
      expect(a.publicKeyLine, isNot(b.publicKeyLine));
      expect(_read(a.privateKeyPem).publicKey, isNot(_read(b.privateKeyPem).publicKey));
    });

    test('toString never shows the private key', () {
      final key = KeyGenerator.generate();
      expect('$key', contains(key.publicKeyLine));
      expect('$key', isNot(contains('PRIVATE KEY')));
      expect('$key', isNot(contains(key.privateKeyPem.split('\n')[1])));
    });
  });

  group('comment', () {
    String commentOf(String label) => KeyGenerator.generate(label: label).publicKeyLine.split(' ')[2];

    test('names the machine it was made for, reduced to shell-safe characters', () {
      expect(commentOf('Build server'), 'herdr-mobile@Build-server');
      expect(commentOf('prod_eu-1.example.com'), 'herdr-mobile@prod_eu-1.example.com');
      expect(commentOf('  ##weird // name!!  '), 'herdr-mobile@weird-name');
    });

    test('a quote, newline or space can never reach the line', () {
      final line = KeyGenerator.generate(label: "a'b\nc\td \"e\" \$(rm -rf ~)").publicKeyLine;
      expect(line.split(' '), hasLength(3), reason: 'type, key, one comment word');
      expect(line, isNot(contains("'")));
      expect(line, isNot(contains('\n')));
      expect(line, isNot(contains('\$')));
    });

    test('an empty or symbol-only label falls back to "phone"', () {
      expect(commentOf(''), 'herdr-mobile@phone');
      expect(commentOf('???'), 'herdr-mobile@phone');
    });

    test('a very long label is cut, not allowed to bloat the line', () {
      final comment = commentOf('x' * 500);
      expect(comment, 'herdr-mobile@${'x' * 40}');
    });

    test('a cut never leaves a dangling dash', () {
      final comment = commentOf('${'a' * 39}-${'b' * 20}');
      expect(comment, 'herdr-mobile@${'a' * 39}');
    });
  });

  group('readPublicKey', () {
    test('returns the same line the key was generated with', () {
      final key = KeyGenerator.generate(label: 'saved');
      final result = KeyGenerator.readPublicKey(key.privateKeyPem);

      expect(result.line, key.publicKeyLine);
      expect(result.failure, isNull);
    });

    test('a passphrase typed for a key that has none is ignored, not an error', () {
      final key = KeyGenerator.generate(label: 'saved');
      expect(KeyGenerator.readPublicKey(key.privateKeyPem, passphrase: 'stale').line, key.publicKeyLine);
    });

    group('protected key', () {
      late final GeneratedKey key;
      late final String protected;
      setUpAll(() {
        key = KeyGenerator.generate(label: 'locked');
        // One bcrypt round: the same format, without the second of work.
        protected = _read(key.privateKeyPem).toPem(passphrase: 'right', rounds: 1);
      });

      test('is recognised as protected', () {
        expect(SSHKeyPair.isEncryptedPem(protected), isTrue);
      });

      test('opens with the right passphrase', () {
        expect(KeyGenerator.readPublicKey(protected, passphrase: 'right').line, key.publicKeyLine);
      });

      test('says so when no passphrase is given, and when it is blank', () {
        expect(KeyGenerator.readPublicKey(protected).failure, KeyReadFailure.needsPassphrase);
        expect(KeyGenerator.readPublicKey(protected, passphrase: '').failure, KeyReadFailure.needsPassphrase);
      });

      test('a wrong passphrase is reported as wrong and yields no line', () {
        final result = KeyGenerator.readPublicKey(protected, passphrase: 'wrong');
        expect(result.failure, KeyReadFailure.wrongPassphrase);
        expect(result.line, isNull);
      });

      test('off the UI thread gives the same answers', () async {
        expect((await KeyGenerator.readPublicKeyOffThread(protected, passphrase: 'right')).line, key.publicKeyLine);
        expect(
          (await KeyGenerator.readPublicKeyOffThread(protected, passphrase: 'wrong')).failure,
          KeyReadFailure.wrongPassphrase,
        );
        expect((await KeyGenerator.readPublicKeyOffThread(protected)).failure, KeyReadFailure.needsPassphrase);
      });
    });

    test('a key without a comment gives a line without a trailing space', () {
      final pair = _read(KeyGenerator.generate().privateKeyPem);
      final bare = OpenSSHEd25519KeyPair(pair.publicKey, pair.privateKey, '');
      final line = KeyGenerator.readPublicKey(bare.toPem()).line!;

      expect(line, 'ssh-ed25519 ${base64.encode(bare.toPublicKey().encode())}');
    });

    test('text that is not a key is unreadable, never a crash', () {
      for (final junk in [
        '',
        'hello',
        '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----',
        '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----',
      ]) {
        final result = KeyGenerator.readPublicKey(junk, passphrase: 'x');
        expect(result.failure, KeyReadFailure.unreadable, reason: junk);
        expect(result.line, isNull);
      }
    });
  });

  group('authorizedKeysCommand', () {
    test('is the documented one-liner around the public line', () {
      const line = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc herdr-mobile@box';
      expect(
        KeyGenerator.authorizedKeysCommand(line),
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$line' >> ~/.ssh/authorized_keys "
        '&& chmod 600 ~/.ssh/authorized_keys',
      );
    });

    test('a quote in a pasted key comment cannot break out of the single quotes', () {
      final command = KeyGenerator.authorizedKeysCommand("ssh-ed25519 AAAA x'; rm -rf ~; echo '");
      expect(command, contains(r"echo 'ssh-ed25519 AAAA x'\''; rm -rf ~; echo '\''' >>"));
    });

    test('a line break in the key cannot start a second command', () {
      final command = KeyGenerator.authorizedKeysCommand('ssh-ed25519 AAAA x\nrm -rf ~');
      expect(command, isNot(contains('\n')));
      expect(command, contains("echo 'ssh-ed25519 AAAA x rm -rf ~' >>"));
    });
  });

  group('against OpenSSH itself', () {
    final sshKeygen = _onPath('ssh-keygen');
    final skip = sshKeygen == null ? 'ssh-keygen is not installed on this machine' : null;

    test('ssh-keygen -y reads the generated PEM and prints the same public line', () async {
      final key = KeyGenerator.generate(label: 'box');
      final dir = Directory.systemTemp.createTempSync('herdr-keygen-test');
      try {
        final file = File('${dir.path}/id_ed25519')..writeAsStringSync(key.privateKeyPem);
        // ssh-keygen refuses a private key that anyone else can read.
        expect((await Process.run('chmod', ['600', file.path])).exitCode, 0);

        final result = await Process.run(sshKeygen!, ['-y', '-f', file.path]);

        expect(result.exitCode, 0, reason: '${result.stderr}');
        final printed = (result.stdout as String).trim().split(' ');
        final ours = key.publicKeyLine.split(' ');
        expect(printed.take(2).toList(), ours.take(2).toList(), reason: 'key type and key bytes');
        expect(printed.skip(2).join(' '), ours.skip(2).join(' '), reason: 'comment');
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, skip: skip);
  });
}
