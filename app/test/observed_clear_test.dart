// `/clear` typed into the chat of a Claude Code pane. The terminal clears and
// Claude opens a new log file, but the pane's status does not change (idle
// before, idle after), so nothing looked for the new file and the chat kept
// the old conversation, and the typed `/clear` (housekeeping, never a message
// of the log) ended as "The message is not in the agent's log yet".
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show Pane;
import 'package:herdr_mobile/data/observed/claude_log_mapper.dart';
import 'package:herdr_mobile/data/observed/observed_kind.dart';
import 'package:herdr_mobile/data/observed/session_log_locator.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';

import 'support/fake_fs.dart';
import 'support/fake_log_source.dart';
import 'support/fake_transport.dart';

const _before = '/home/u/.claude/projects/-tmp-x/3f1c9a52-7d0e-4b6a-9a11-0c5d2e8b7f41.jsonl';
const _after = '/home/u/.claude/projects/-tmp-x/a8e2d4c6-1b3f-4a5d-8e7c-9f0a1b2c3d4e.jsonl';

/// Says where Claude's session file is now: [path].
class _Locator implements SessionLogLocator {
  _Locator(this.path);

  String path;
  var asked = 0;

  @override
  bool mayLocate(Pane pane) => true;

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) async {
    asked++;
    return Located(path);
  }
}

void main() {
  test('a /clear from the chat makes it follow the new file, and is not reported as lost', () async {
    final rig = await ObservedRig.create(agent: 'claude', log: _before);
    addTearDown(rig.dispose);
    rig.transport.fs = FakeFs()
      ..addFile(_before, '{}\n')
      ..addFile(_after, '{}\n');
    final locator = _Locator(_before);
    final session = ObservedAgentSession(
      machine: rig.machine,
      paneId: 'w1:p1',
      kind: ObservedKind(id: 'claude', label: 'Claude Code', newMapper: ClaudeLogMapper.new, locator: locator),
      source: rig.source,
      mapper: ClaudeLogMapper.new,
      previews: rig.previews,
      confirmWithin: const Duration(milliseconds: 600),
    );
    addTearDown(session.dispose);
    session.acquire();
    await eventually(() => rig.source.calls.isNotEmpty, reason: 'follows the first file');
    expect(rig.source.calls.last.path, _before);

    // Claude clears: a new file now, the pane still idle.
    locator.path = _after;
    expect(await session.send('/clear'), isTrue);

    await eventually(() => rig.source.calls.any((c) => c.path == _after), reason: 'follows the new file');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(session.error, isNull, reason: '/clear is not a message the log will show');
  });
}
