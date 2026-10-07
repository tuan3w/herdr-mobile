import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// pinenacl is dartssh2's own Ed25519 primitive; it is the only way to derive
// the public half from a seed, and dartssh2 does not re-export it.
import 'package:pinenacl/ed25519.dart' show SigningKey;

/// A freshly generated key pair: the private key as an OpenSSH PEM (what the
/// secrets store and `SSHKeyPair.fromPem` take) and the matching one-line
/// `authorized_keys` entry.
final class GeneratedKey {
  const GeneratedKey({required this.privateKeyPem, required this.publicKeyLine});

  final String privateKeyPem;
  final String publicKeyLine;

  /// Never prints the private half: a stray log of this object is harmless.
  @override
  String toString() => 'GeneratedKey($publicKeyLine)';
}

/// Why a saved private key did not yield a public key.
enum KeyReadFailure {
  /// The key is protected and no passphrase was given.
  needsPassphrase,

  /// The key is protected and the passphrase does not open it.
  wrongPassphrase,

  /// Not a key this app can read.
  unreadable,
}

/// Outcome of [KeyGenerator.readPublicKey]: exactly one of the two is set.
typedef PublicKeyResult = ({String? line, KeyReadFailure? failure});

/// Creates and inspects SSH keys on the phone. The private key never leaves
/// the device, is never logged, and is only ever returned to the caller.
abstract final class KeyGenerator {
  static const _commentPrefix = 'herdr-mobile@';
  static const _fallbackLabel = 'phone';
  static const _maxLabel = 40;

  /// Ed25519 key pair from the platform's secure random source. The comment
  /// reads `herdr-mobile@<label>`, with [label] reduced to letters, digits and
  /// `. _ -` so it survives being pasted into a shell command.
  static GeneratedKey generate({String label = ''}) {
    final seed = _secureBytes(SigningKey.seedSize);
    final SigningKey signing;
    try {
      signing = SigningKey.fromSeed(seed);
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
    final pair = OpenSSHEd25519KeyPair(
      Uint8List.fromList(signing.verifyKey),
      Uint8List.fromList(signing),
      '$_commentPrefix${_label(label)}',
    );
    return GeneratedKey(privateKeyPem: pair.toPem(), publicKeyLine: publicKeyLine(pair));
  }

  /// The public key of [pem] as an `authorized_keys` line. A protected key
  /// needs its [passphrase]; an unprotected one ignores it, because dartssh2
  /// rejects a passphrase for a key that has none.
  static PublicKeyResult readPublicKey(String pem, {String? passphrase}) {
    final bool encrypted;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(pem);
    } on Object {
      return (line: null, failure: KeyReadFailure.unreadable);
    }
    final given = passphrase != null && passphrase.isNotEmpty;
    if (encrypted && !given) return (line: null, failure: KeyReadFailure.needsPassphrase);
    try {
      final pairs = SSHKeyPair.fromPem(pem, encrypted ? passphrase : null);
      if (pairs.isEmpty) return (line: null, failure: KeyReadFailure.unreadable);
      return (line: publicKeyLine(pairs.first), failure: null);
    } on SSHKeyDecryptError {
      return (
        line: null,
        failure: encrypted ? KeyReadFailure.wrongPassphrase : KeyReadFailure.unreadable,
      );
    } on UnsupportedError {
      return (line: null, failure: KeyReadFailure.unreadable);
    } on Object {
      // A wrong passphrase decrypts to noise that can fail in odd places.
      return (
        line: null,
        failure: encrypted ? KeyReadFailure.wrongPassphrase : KeyReadFailure.unreadable,
      );
    }
  }

  static final _privateKeyBlock = RegExp(
    r'-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----(.*?)-----END \1-----',
    dotAll: true,
  );
  static const _pemWidth = 70;

  /// [text] as pasted into the key field, put back into the shape
  /// `SSHKeyPair.fromPem` reads.
  ///
  /// Copying a key on a phone changes it in ways that are easy to miss and
  /// that the parser refuses: the line breaks turn into spaces (one long line),
  /// each line gains an indent, the key is wrapped in quotes, or a few words of
  /// a chat message come before it. The block between `BEGIN` and `END` is kept,
  /// and its body is cut into lines again. A protected key from an older PEM
  /// format carries `Proc-Type:` and `DEK-Info:` header lines that must stay
  /// lines of their own, so those keep their lines (trimmed). Text that holds no
  /// private key block is returned as it is, trimmed, and fails to read as
  /// before.
  static String cleanPastedPem(String text) {
    final match = _privateKeyBlock.firstMatch(text);
    if (match == null) return text.trim();
    final label = match.group(1)!;
    final lines = [
      for (final line in match.group(2)!.split(RegExp(r'[\r\n]+')))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final List<String> body;
    if (lines.any((l) => l.contains(':'))) {
      body = lines;
    } else {
      final joined = lines.join().replaceAll(RegExp(r'\s+'), '');
      body = [
        for (var i = 0; i < joined.length; i += _pemWidth)
          joined.substring(i, min(i + _pemWidth, joined.length)),
      ];
    }
    return ['-----BEGIN $label-----', ...body, '-----END $label-----'].join('\n');
  }

  /// [readPublicKey] off the UI thread when the key is protected: unlocking
  /// runs bcrypt, which takes about a second on a phone. An unprotected key is
  /// read in place, as that costs less than the hop.
  static Future<PublicKeyResult> readPublicKeyOffThread(String pem, {String? passphrase}) {
    bool encrypted;
    try {
      encrypted = SSHKeyPair.isEncryptedPem(pem);
    } on Object {
      encrypted = false;
    }
    if (!encrypted) return Future.value(readPublicKey(pem, passphrase: passphrase));
    return Isolate.run(() => readPublicKey(pem, passphrase: passphrase));
  }

  /// `ssh-ed25519 AAAA… comment`, the form `authorized_keys` and every Git host
  /// accept. The comment is the key's own, flattened to one line.
  static String publicKeyLine(SSHKeyPair pair) {
    final blob = base64.encode(pair.toPublicKey().encode());
    final comment = (pair.comment ?? '').replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
    return comment.isEmpty ? '${pair.name} $blob' : '${pair.name} $blob $comment';
  }

  /// One command that adds [publicLine] to the machine's `authorized_keys`,
  /// creating `~/.ssh` with safe permissions first. The line goes in single
  /// quotes, and any quote inside it is closed, escaped and reopened so a
  /// crafted comment cannot add commands.
  static String authorizedKeysCommand(String publicLine) {
    final line = publicLine.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();
    final quoted = line.replaceAll("'", r"'\''");
    return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$quoted' >> ~/.ssh/authorized_keys"
        ' && chmod 600 ~/.ssh/authorized_keys';
  }

  static String _label(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final cut = cleaned.length > _maxLabel ? cleaned.substring(0, _maxLabel) : cleaned;
    final trimmed = cut.replaceAll(RegExp(r'-+$'), '');
    return trimmed.isEmpty ? _fallbackLabel : trimmed;
  }

  static Uint8List _secureBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }
}
