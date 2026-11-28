import 'dart:async';
import 'dart:convert';

import 'host_link.dart';

/// Runs the host install (`keeperInstallCommand`) on [process], an exec channel
/// the caller opened for it, and returns once the helper is in place.
///
/// The installer reads nothing from stdin, so stdin is closed at once. Throws
/// [HostException] (`install_failed`) with what the installer said on stderr
/// when it failed, and a retryable `timeout` when it did not finish in [timeout]
/// (a slow host downloads a megabyte or two).
Future<void> installHostHelper(HostProcess process, {Duration timeout = const Duration(seconds: 30)}) async {
  unawaited(process.stdin.close().catchError((Object _) {}));
  final out = utf8.decodeStream(process.stdout).catchError((Object _) => '');
  final err = utf8.decodeStream(process.stderr).catchError((Object _) => '');
  try {
    await process.done.timeout(timeout);
  } on TimeoutException {
    process.close();
    throw const HostException(
      'timeout',
      'The machine did not finish setting up the agent helper in time.',
      retryable: true,
    );
  } on Object {
    throw const HostLinkLost('the connection dropped while the agent helper was being installed');
  }
  final stdout = await out;
  final stderr = (await err).trim();
  final last = stdout.trim().split('\n').last;
  final ok = process.exitCode == 0 && _isOk(last);
  process.close();
  if (!ok) {
    final said = stderr.isEmpty ? '' : ' $stderr';
    throw HostException('install_failed', 'The machine could not set up the agent helper.$said');
  }
}

bool _isOk(String line) {
  try {
    final j = jsonDecode(line);
    return j is Map && j['ok'] == true;
  } on FormatException {
    return false;
  }
}
