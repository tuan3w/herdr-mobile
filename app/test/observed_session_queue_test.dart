// A message typed in the chat of an agent that runs in a terminal while its
// turn runs: Send goes into the turn (the agent's own Enter does that), a hold
// on Send keeps it on the phone, visible and editable, until the turn has ended.
// Before it was typed into a working pane, the screen is read: a dialog that
// opened since herdr last said `working` would take the text and the Enter as
// its answer.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart' show TextBlock;
import 'package:herdr_mobile/data/acp/prompt_queue.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;

import 'support/fake_log_source.dart';
import 'support/fake_transport.dart';

const _approval = '''
 Bash command

   git push origin main
   Push to remote

 Do you want to proceed?
 ❯ 1. Yes
   2. No
''';

Future<(ObservedRig, ObservedAgentSession)> _open({String status = 'working', void Function()? onIdle}) async {
  final rig = await ObservedRig.create(status: status);
  addTearDown(rig.dispose);
  rig.source.write([sessionLine(), userLine('u1', 'go')]);
  late final ObservedAgentSession session;
  session = ObservedAgentSession(
    machine: rig.machine,
    paneId: 'w1:p1',
    kind: ompKind,
    source: rig.source,
    mapper: OmpLogMapper.new,
    previews: rig.previews,
    confirmWithin: const Duration(seconds: 2),
    idleAfter: const Duration(milliseconds: 30),
    onIdle: (_) => onIdle?.call(),
  );
  addTearDown(session.dispose);
  session.acquire();
  await eventually(() => session.link == AgentLink.live, reason: 'log followed');
  return (rig, session);
}

List<String> _typed(ObservedRig rig) => [for (final p in rig.sent('pane.send_input')) p['text'] as String];

void main() {
  test('Send while the turn runs types the message into the pane at once', () async {
    final (rig, session) = await _open();
    expect(session.delivery, SendDelivery.steered);

    expect(await session.sendBlocks([const TextBlock('use postgres')]), isTrue);

    expect(_typed(rig), ['use postgres']);
    expect(session.queued.where((m) => !m.sent), isEmpty, reason: 'nothing waits on the phone');
  });

  test('a message sent into the turn is a row until the agent has read it, and the order is kept', () async {
    final (rig, session) = await _open();

    expect(await session.sendBlocks([const TextBlock('use postgres')]), isTrue);
    expect(await session.sendBlocks([const TextBlock('and sqlite for tests')]), isTrue);
    expect(session.queued.map((m) => (m.text, m.sent)), [('use postgres', true), ('and sqlite for tests', true)]);

    // The agent reads the first one: its row goes, the second one stays.
    rig.source.push([userLine('u2', 'use postgres')]);
    await eventually(() => session.queued.length == 1, reason: 'the first one was read');
    expect(session.queued.single.text, 'and sqlite for tests');

    rig.source.push([userLine('u3', 'and sqlite for tests')]);
    await eventually(() => session.queued.isEmpty, reason: 'both were read');
  });

  test('a message that goes out at once, with no turn running, is not shown as waiting', () async {
    final (rig, session) = await _open(status: 'idle');

    expect(await session.sendBlocks([const TextBlock('hello')]), isTrue);

    expect(_typed(rig), ['hello']);
    expect(session.queued, isEmpty);
  });

  test('a dialog on the screen takes nothing: the message is refused and nothing is typed', () async {
    final (rig, session) = await _open();
    rig.transport.screen = _approval;

    expect(await session.sendBlocks([const TextBlock('use postgres')]), isFalse);

    expect(_typed(rig), isEmpty);
    expect(session.error, contains('asking something'));
    expect(session.queued, isEmpty, reason: 'false means the text is nowhere else: the field gets it back');
  });

  test('a hold on Send keeps the message on the phone, and it goes out when the turn has ended', () async {
    final (rig, session) = await _open();

    expect(await session.sendBlocks([const TextBlock('then add tests')], queue: true), isTrue);
    expect(session.queued.map((m) => m.text), ['then add tests']);
    expect(session.delivery, SendDelivery.queued, reason: 'what is sent next waits behind it');
    expect(_typed(rig), isEmpty);

    await rig.setStatus('idle');
    await eventually(() => _typed(rig).isNotEmpty, reason: 'the queue goes out');
    expect(_typed(rig), ['then add tests']);
    await eventually(() => session.queued.isEmpty, reason: 'it leaves the queue once typed');
  });

  test('what waits goes one message at a time, each after a turn', () async {
    final (rig, session) = await _open();
    await session.sendBlocks([const TextBlock('first')], queue: true);
    await session.sendBlocks([const TextBlock('second')]);
    expect(session.queued.map((m) => m.text), ['first', 'second'], reason: 'behind what waits, in order');

    await rig.setStatus('idle');
    await eventually(() => _typed(rig).length == 1, reason: 'the first goes');
    expect(_typed(rig), ['first']);

    // The agent took it (a turn runs), the second waits for that turn to end.
    await rig.setStatus('working');
    await eventually(() => session.queued.length == 1, reason: 'the first has left the queue');
    expect(_typed(rig), ['first']);

    await rig.setStatus('idle');
    await eventually(() => _typed(rig).length == 2, reason: 'the second goes after the turn');
    expect(_typed(rig), ['first', 'second']);
  });

  test('Stop with messages waiting sends them together, as one, once the turn has stopped', () async {
    final (rig, session) = await _open();
    await session.sendBlocks([const TextBlock('also the docs')], queue: true);
    await session.sendBlocks([const TextBlock('and a changelog line')], queue: true);

    session.cancel();
    expect(rig.sent('pane.send_keys').single['keys'], ['esc']);
    expect(_typed(rig), isEmpty, reason: 'nothing goes while the turn still runs');

    await rig.setStatus('idle');
    await eventually(() => _typed(rig).isNotEmpty, reason: 'they go out');
    expect(_typed(rig), ['also the docs\n\nand a changelog line']);
  });

  test('a message waits while the agent needs the person, then goes when the pane takes input', () async {
    final (rig, session) = await _open();
    await session.sendBlocks([const TextBlock('wait for me')], queue: true);

    await rig.setStatus('blocked');
    expect(_typed(rig), isEmpty, reason: 'a blocked pane would take it as an answer');
    expect(session.queued.single.held, isFalse);

    await rig.setStatus('idle');
    await eventually(() => _typed(rig).isNotEmpty, reason: 'goes once the pane is idle');
    expect(_typed(rig), ['wait for me']);
  });

  test(
    'a message the pane did not take is held first with the reason, what is behind it waits, Resume keeps the order',
    () async {
      final (rig, session) = await _open();
      await session.sendBlocks([const TextBlock('first')], queue: true);
      await session.sendBlocks([const TextBlock('second')], queue: true);
      var fail = true;
      rig.transport.onInput = (_) {
        if (fail) throw const HerdrTransportException('The link dropped.');
      };

      await rig.setStatus('idle');
      await eventually(() => session.queued.length == 2 && session.queued.every((m) => m.held), reason: 'both held');
      expect(session.queued.map((m) => m.text), ['first', 'second'], reason: 'the one that failed stays first');
      expect(session.queued.first.heldReason, 'The link dropped.');
      expect(_typed(rig), isEmpty, reason: 'the second must not overtake the first');

      fail = false;
      session.resumeQueue();
      await eventually(() => _typed(rig).isNotEmpty, reason: 'resumed');
      expect(_typed(rig), ['first']);
    },
  );

  test('an agent that left the pane takes nothing: the shell would run it', () async {
    final (rig, session) = await _open();
    await session.sendBlocks([const TextBlock('make the tests pass')], queue: true);

    ((rig.transport.snapshot['panes'] as List).first as Map<String, dynamic>).remove('agent');
    await rig.setStatus('idle');

    await eventually(() => session.queued.any((m) => m.held), reason: 'held: no agent runs here');
    expect(_typed(rig), isEmpty);
    expect(session.queued.single.heldReason, contains('not running in this pane'));
    expect(await session.sendBlocks([const TextBlock('git push')]), isFalse, reason: 'nor a direct send');
    expect(_typed(rig), isEmpty);
  });

  test('a Stop that did not stop the turn does not merge what is queued after it', () async {
    final (rig, session) = await _open();
    await session.sendBlocks([const TextBlock('A')], queue: true);
    session.cancel();
    await session.sendBlocks([const TextBlock('B')], queue: true);

    await rig.setStatus('idle');
    await eventually(() => _typed(rig).isNotEmpty, reason: 'the first goes');
    expect(_typed(rig), ['A'], reason: 'B was queued after the Stop: its own message, after the next turn');
  });

  test('an edited message goes out as edited, and a removed one never does', () async {
    final (rig, session) = await _open();
    await session.sendBlocks([const TextBlock('typo mesage')], queue: true);
    await session.sendBlocks([const TextBlock('drop me')], queue: true);
    session.editQueued(session.queued.first.id, 'typo message');
    session.removeQueued(session.queued.last.id);

    await rig.setStatus('idle');
    await eventually(() => _typed(rig).isNotEmpty, reason: 'goes out');
    expect(_typed(rig), ['typo message']);
  });

  test('a session nobody looks at is kept while messages wait in it, and goes once they are gone', () async {
    var idled = 0;
    final (_, session) = await _open(onIdle: () => idled++);
    await session.sendBlocks([const TextBlock('later')], queue: true);

    session.release();
    // Absence has to be waited for: the drop timer is 30 ms, so five times that
    // is long enough to see it did not fire. A slow machine only delays the
    // timer, it can never make this pass when the guard is gone.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(idled, 0, reason: 'a message waits in it: dropping would lose it without a word');

    session.removeQueued(session.queued.single.id);
    await eventually(() => idled == 1, reason: 'unused and empty: dropped');
  });
}
