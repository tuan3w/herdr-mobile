import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart' show MessageRole;
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink, EarlierHistory;
import 'package:herdr_mobile/data/repositories/observed_session.dart';

import 'support/fake_log_source.dart';
import 'support/fake_transport.dart' show eventually;

/// [turns] turns of a person's message and an answer of about 10 KB each: 80
/// of them are ~810 KB, so the first tail read (192 KB) holds the last ~19.
List<String> _turns(int turns, {int from = 0}) => [
  for (var i = from; i < from + turns; i++) ...[
    userLine('u$i', 'question $i'),
    assistantLine('a$i', 'answer $i ${'x' * 10000}'),
  ],
];

/// What the person said, in order.
List<String> _said(ObservedAgentSession s) => [
  for (final i in s.state.items)
    if (i is TranscriptMessage && i.role == MessageRole.user) i.text,
];

/// The key of each item, by what it is.
Map<String, String> _keys(ObservedAgentSession s) => {
  for (final i in s.state.items)
    if (i is TranscriptMessage) '${i.role.name}:${i.text.split(' ').take(2).join(' ')}': i.key,
};

Future<(ObservedRig, ObservedAgentSession)> _open(List<String> lines, {bool hold = false}) async {
  final rig = await ObservedRig.create();
  addTearDown(rig.dispose);
  rig.source.write(lines);
  final session = ObservedAgentSession(
    machine: rig.machine,
    paneId: 'w1:p1',
    kind: ompKind,
    source: rig.source,
    mapper: OmpLogMapper.new,
    previews: rig.previews,
  );
  addTearDown(session.dispose);
  session.acquire();
  await eventually(() => session.link == AgentLink.live && session.state.items.isNotEmpty, reason: 'log followed');
  rig.source.holdTails = hold;
  return (rig, session);
}

void main() {
  test('a log that fits the first read has nothing earlier, and loading does nothing', () async {
    final (rig, session) = await _open([sessionLine(), ..._turns(3)]);
    expect(session.earlier, EarlierHistory.none);
    expect(_said(session), hasLength(3));
    session.loadEarlier();
    await pumpEventQueue();
    expect(rig.source.calls, hasLength(1));
  });

  test('a long log opens at its end, says there is more, and reads back to its start', () async {
    final (rig, session) = await _open([sessionLine(), ..._turns(80)]);
    expect(session.earlier, EarlierHistory.available);
    final shown = _said(session);
    final keys = _keys(session);
    expect(shown.length, lessThan(80));
    expect(shown.last, 'question 79');

    session.loadEarlier();
    expect(session.earlier, EarlierHistory.loading);
    await eventually(() => session.earlier != EarlierHistory.loading, reason: 'wider read done');
    // 4x as wide, read from the end again (not resumed).
    expect(rig.source.calls.last.tailBytes, 4 * 192 * 1024);
    expect(rig.source.calls.last.from, isNull);
    final wider = _said(session);
    expect(wider.length, greaterThan(shown.length));
    expect(wider.sublist(wider.length - shown.length), shown, reason: 'what was shown is still there, after the older turns');
    final now = _keys(session);
    for (final e in keys.entries) {
      expect(now[e.key], e.value, reason: '${e.key} keeps its key, so the list does not jump');
    }
    expect(now.values.toSet(), hasLength(now.length), reason: 'no two items share a key');
    expect(session.earlier, EarlierHistory.available, reason: '768 KB is not all of ~800 KB');

    session.loadEarlier();
    await eventually(() => session.earlier == EarlierHistory.none, reason: 'start of the log reached');
    expect(_said(session), [for (var i = 0; i < 80; i++) 'question $i']);
  });

  test('what is shown stays as it is until the whole wider read is there', () async {
    final (rig, session) = await _open([sessionLine(), ..._turns(80)], hold: true);
    final before = session.state;
    session.loadEarlier();
    await eventually(() => rig.source.calls.length == 2, reason: 'wider read asked');
    final batches = rig.source.tailOf(rig.source.calls.last.tailBytes, batchLines: 10);
    // Everything but the caught-up note: older turns arrive, nothing shown moves.
    for (final b in batches.take(batches.length - 1)) {
      rig.source.last.add(b);
    }
    await pumpEventQueue();
    expect(identical(session.state.items, before.items), isTrue);
    expect(session.earlier, EarlierHistory.loading);

    rig.source.last.add(batches.last);
    await eventually(() => session.earlier != EarlierHistory.loading, reason: 'adopted');
    expect(_said(session).first, isNot(_said(session).last));
    expect(_said(session).length, greaterThan(19));
  });

  test('the agent goes on writing: a line after the wider read is shown once', () async {
    final (rig, session) = await _open([sessionLine(), ..._turns(80)]);
    session.loadEarlier();
    await eventually(() => session.earlier != EarlierHistory.loading, reason: 'wider read done');
    rig.source.push([userLine('u-new', 'one more')]);
    await eventually(() => _said(session).last == 'one more', reason: 'new line shown');
    expect(_said(session).where((k) => k == 'one more'), hasLength(1));
    expect(_said(session).toSet(), hasLength(_said(session).length), reason: 'nothing doubled');
  });

  test('a link that drops in the middle of the wider read starts it over, and nothing is doubled', () async {
    final (rig, session) = await _open([sessionLine(), ..._turns(80)], hold: true);
    session.loadEarlier();
    await eventually(() => rig.source.calls.length == 2, reason: 'wider read asked');
    final batches = rig.source.tailOf(rig.source.calls.last.tailBytes, batchLines: 10);
    rig.source.last.add(batches.first);
    await pumpEventQueue();
    rig.source.holdTails = false;
    rig.source.drop();
    await eventually(() => session.earlier == EarlierHistory.available, reason: 'adopted after the retry');
    final said = _said(session);
    expect(said.toSet(), hasLength(said.length));
    expect(said.last, 'question 79');
    expect(said.length, greaterThan(19));
  });
}
