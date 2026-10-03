import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';

void main() {
  // dartssh2 encrypts in pure Dart on whatever isolate it runs on. Measured
  // through the library, AES-GCM moves 1 MB/s while ChaCha20-Poly1305 and
  // AES-CTR move 30-40 MB/s. The library's own default order prefers GCM, and
  // OpenSSH accepts it, so a plain `SSHClient` negotiated the slowest cipher and
  // froze a phone's UI for ~600 ms per pane refresh.
  group('cipher preference', () {
    final ciphers = sshAlgorithms.cipher;
    int at(SSHCipherType c) => ciphers.indexOf(c);

    test('fast ciphers are offered before the slow GCM ones', () {
      final fast = [
        SSHCipherType.chacha20poly1305,
        SSHCipherType.aes128ctr,
        SSHCipherType.aes256ctr,
      ];
      final slow = [SSHCipherType.aes128gcm, SSHCipherType.aes256gcm];

      for (final f in fast) {
        for (final s in slow) {
          expect(at(f), greaterThanOrEqualTo(0));
          expect(at(f), lessThan(at(s)), reason: '$f must be preferred over $s');
        }
      }
    });

    test('GCM stays available for servers that offer nothing faster', () {
      expect(ciphers, containsAll([SSHCipherType.aes128gcm, SSHCipherType.aes256gcm]));
    });

    test('the library default would have picked GCM first (why this list exists)', () {
      expect(const SSHAlgorithms().cipher.first, SSHCipherType.aes256gcm);
    });
  });
}
