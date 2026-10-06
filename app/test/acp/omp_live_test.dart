// A live check against the real `omp acp` on this machine.
//
// Skipped unless `HERDR_ACP_LIVE=1` is set and `omp` is on PATH. It spawns
// `omp acp` in a fresh temp directory, runs initialize and session/new, waits
// for the command list and the config options, then closes the session.
// IT LEAVES ONE EMPTY SESSION FILE IN OMP'S STORE (omp writes the session
// when `session/new` runs; `session/close` does not delete it). No prompt is
// sent, so no model is called.
//
//   HERDR_ACP_LIVE=1 flutter test test/acp/omp_live_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_client.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/process_transport.dart';

/// Never allows anything: this test sends no prompt, so nothing should ask.
class _RefuseAll implements AcpClientHandler {
  @override
  Future<PermissionOutcome> requestPermission(PermissionRequest request, Future<void> cancelled) async =>
      const PermissionCancelled();

  @override
  Future<ElicitationResponse> elicit(ElicitationRequest request, Future<void> cancelled) async => const ElicitationCancel();
}

String? _skipReason() {
  if (Platform.environment['HERDR_ACP_LIVE'] != '1') return 'set HERDR_ACP_LIVE=1 to run against the real omp';
  final which = Process.runSync('which', ['omp']);
  if (which.exitCode != 0) return 'omp is not on PATH';
  return null;
}

void main() {
  test('omp acp: initialize, session/new, commands and config options arrive', () async {
    final cwd = Directory.systemTemp.createTempSync('herdr_acp_live_');
    ProcessTransport? transport;
    try {
      transport = await ProcessTransport.start('omp', ['acp'], workingDirectory: cwd.path);
      final problems = <String>[];
      final client = AcpClient(transport, handler: _RefuseAll(), onProblem: problems.add);

      final init = await client.initialize();
      expect(init.agentInfo!.name, 'omp');
      expect(init.protocolVersion, 1);
      expect(init.capabilities.canList, isTrue);

      final session = await client.newSession(cwd: cwd.path);
      expect(session.sessionId, isNotEmpty);
      expect(session.configOptions.map((o) => o.category), containsAll(['mode', 'model']));

      // The command list is a notification after the answer.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (client.state(session.sessionId).commands.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final state = client.state(session.sessionId);
      expect(state.commands, isNotEmpty, reason: 'stderr: ${transport.stderrTail}');
      expect(state.commands.map((c) => c.name), everyElement(isNotEmpty));

      await client.closeSession(session.sessionId);
      await client.close();
      expect(await transport.exitCode.timeout(const Duration(seconds: 10)), isA<int>());
      expect(problems, isEmpty);
    } finally {
      await transport?.close();
      cwd.deleteSync(recursive: true);
    }
  }, skip: _skipReason(), timeout: const Timeout(Duration(seconds: 90)));
}
