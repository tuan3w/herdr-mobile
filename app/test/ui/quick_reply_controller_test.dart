// The send state machine behind the answer chips: the wrong reply, a double
// tap, a risky option sent without asking, a failure that vanishes, or keys
// sent to a question that changed since the chips were drawn would each
// answer a prompt the user did not mean to answer.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/features/agents/quick_reply_controller.dart';

import '../support/fake_transport.dart';

const _yes = QuickReply(label: '1. Yes', keys: ['1', 'enter']);
const _no = QuickReply(label: '3. No', keys: ['3', 'enter']);
const _delete = QuickReply(label: '2. Yes, delete it', keys: ['2', 'enter'], needsConfirm: true);

/// The question the chips were drawn for.
const _asked = PromptInfo(question: 'Delete the build folder?', replies: [_yes, _delete, _no]);

/// What a fresh read of the pane finds: [now], counting the reads; [failure]
/// is thrown instead when set.
class _Screen extends Fake implements PanePreviews {
  _Screen(this.now);

  PromptInfo? now;
  Object? failure;
  int reads = 0;

  @override
  Future<PromptInfo?> recheck(MachineConnection machine, String paneId) async {
    reads++;
    if (failure != null) throw failure!;
    return now;
  }
}

void main() {
  late FakeTransport transport;
  late MachineConnection machine;
  late _Screen screen;
  late QuickReplyController reply;

  setUp(() {
    transport = FakeTransport();
    machine = MachineConnection(
      profile: MachineProfile(id: 'a', label: 'box', host: 'a.example', username: 'dev'),
      api: HerdrApi(transport),
    );
    screen = _Screen(_asked);
    reply = QuickReplyController(machine: machine, paneId: 'w1:p1', previews: screen, haptic: false);
  });

  tearDown(() {
    reply.dispose();
    machine.dispose();
  });

  List<Map<String, dynamic>> sent(String method) =>
      [for (final (m, p) in transport.calls) if (m == method) p];

  testWidgets('a chip sends exactly its own keys to its own pane, once', (tester) async {
    expect(await reply.choose(_no, asked: _asked), isTrue);

    expect(sent('pane.send_keys'), [
      {'pane_id': 'w1:p1', 'keys': ['3', 'enter']},
    ]);
    expect(reply.phase, ReplyPhase.sent);
    expect(reply.sentLabel, '3. No');
    expect(reply.subject, _no);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a second tap while the first is in flight sends nothing', (tester) async {
    final first = reply.choose(_yes, asked: _asked);
    expect(reply.busy, isTrue);
    final second = reply.choose(_no, asked: _asked);
    expect(await second, isFalse);
    expect(await first, isTrue);

    expect(sent('pane.send_keys'), hasLength(1));
    expect(sent('pane.send_keys').single['keys'], ['1', 'enter']);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('after an answer the other chips stay locked until the hold ends', (tester) async {
    await reply.choose(_yes, asked: _asked);
    expect(await reply.choose(_no, asked: _asked), isFalse, reason: 'a second answer must not slip out');
    expect(sent('pane.send_keys'), hasLength(1));

    await tester.pump(const Duration(seconds: 3, milliseconds: 100));
    expect(reply.phase, ReplyPhase.idle);
    expect(reply.subject, isNull);
    expect(await reply.choose(_no, asked: _asked), isTrue);
    await tester.pump(const Duration(seconds: 4));
  });

  group('risky options', () {
    testWidgets('the first tap only asks; nothing is sent', (tester) async {
      expect(await reply.choose(_delete, asked: _asked), isFalse);
      expect(reply.phase, ReplyPhase.confirming);
      expect(reply.confirming, _delete);
      expect(sent('pane.send_keys'), isEmpty);
      reply.cancelConfirm();
    });

    testWidgets('the second tap sends', (tester) async {
      await reply.choose(_delete, asked: _asked);
      expect(await reply.choose(_delete, asked: _asked), isTrue);
      expect(sent('pane.send_keys').single['keys'], ['2', 'enter']);
      expect(reply.confirming, isNull);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the question lapses on its own: a late tap asks again', (tester) async {
      await reply.choose(_delete, asked: _asked);
      await tester.pump(const Duration(seconds: 5));
      expect(reply.phase, ReplyPhase.idle);
      expect(reply.confirming, isNull);

      expect(await reply.choose(_delete, asked: _asked), isFalse, reason: 'a stale confirmation must not count');
      expect(sent('pane.send_keys'), isEmpty);
      reply.cancelConfirm();
    });

    testWidgets('tapping a different chip drops the question and sends that chip',
        (tester) async {
      await reply.choose(_delete, asked: _asked);
      expect(await reply.choose(_yes, asked: _asked), isTrue);
      expect(sent('pane.send_keys').single['keys'], ['1', 'enter'], reason: 'never the risky one');
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a held chip is already confirmed: the choose that follows sends it at once', (tester) async {
      reply.confirmByHold(_delete);
      expect(await reply.choose(_delete, asked: _asked), isTrue);
      expect(sent('pane.send_keys').single['keys'], ['2', 'enter']);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a hold confirms only the chip it was on, and nothing once an answer is out', (tester) async {
      const other = QuickReply(label: '4. Other', keys: ['4', 'enter'], needsConfirm: true);
      reply.confirmByHold(_delete);
      expect(await reply.choose(other, asked: _asked), isFalse, reason: 'the hold was for another chip');
      expect(reply.confirming, other);
      reply.cancelConfirm();

      await reply.choose(_yes, asked: _asked);
      reply.confirmByHold(_delete);
      expect(await reply.choose(_delete, asked: _asked), isFalse, reason: 'locked after an answer');
      expect(sent('pane.send_keys'), hasLength(1));
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('failure', () {
    testWidgets('is reported on the chip, keeps it, and a retry sends it', (tester) async {
      transport.failure = const HerdrTransportException('Connection reset');
      expect(await reply.choose(_yes, asked: _asked), isFalse);
      expect(reply.phase, ReplyPhase.failed);
      expect(reply.error, 'Connection reset');
      expect(reply.subject, _yes);

      transport.failure = null;
      transport.calls.clear();
      expect(await reply.choose(_yes, asked: _asked), isTrue);
      expect(sent('pane.send_keys').single['keys'], ['1', 'enter']);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('reset clears it', (tester) async {
      transport.failure = const HerdrTransportException('nope');
      await reply.choose(_yes, asked: _asked);
      reply.reset();
      expect(reply.phase, ReplyPhase.idle);
      expect(reply.error, isNull);
    });
  });

  group('the pane is read again before an option goes', () {
    testWidgets('the same question: its keys go, after one read', (tester) async {
      expect(await reply.choose(_no, asked: _asked), isTrue);
      expect(screen.reads, 1);
      expect(sent('pane.send_keys').single['keys'], ['3', 'enter']);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('answered on the desktop and asking something else: nothing is sent, and the chip under the thumb says so',
        (tester) async {
      const next = PromptInfo(
        question: 'Push to origin?',
        replies: [
          QuickReply(label: '1. Push', keys: ['1', 'enter']),
          QuickReply(label: '2. Not now', keys: ['2', 'enter']),
        ],
      );
      screen.now = next;

      expect(await reply.choose(_yes, asked: _asked), isFalse);
      expect(sent('pane.send_keys'), isEmpty, reason: 'the keys were meant for the old question');
      expect(reply.phase, ReplyPhase.changed);
      expect(reply.subject, next.replies.first, reason: 'said on the new chip where the tapped one was');

      await tester.pump(const Duration(milliseconds: 1600));
      expect(reply.phase, ReplyPhase.idle, reason: 'then the chip shows its option again');
      expect(await reply.choose(next.replies.first, asked: next), isTrue);
      expect(sent('pane.send_keys').single['keys'], ['1', 'enter']);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a pane that asks nothing any more gets nothing', (tester) async {
      screen.now = null;
      expect(await reply.choose(_yes, asked: _asked), isFalse);
      expect(sent('pane.send_keys'), isEmpty);
      expect(reply.phase, ReplyPhase.changed);
      expect(reply.subject, isNull);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the same question with the cursor moved: the keys read now go', (tester) async {
      screen.now = const PromptInfo(
        question: 'Delete the build folder?',
        replies: [
          QuickReply(label: '1. Yes', keys: ['up', 'enter']),
          _delete,
          _no,
        ],
      );
      expect(await reply.choose(_yes, asked: _asked), isTrue);
      expect(sent('pane.send_keys').single['keys'], ['up', 'enter']);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a read that fails sends nothing and says so', (tester) async {
      screen.failure = const HerdrTransportException('Connection reset');
      expect(await reply.choose(_yes, asked: _asked), isFalse);
      expect(reply.phase, ReplyPhase.failed);
      expect(reply.error, 'Connection reset');
      expect(sent('pane.send_keys'), isEmpty);
    });
  });

  group('text and keys', () {
    testWidgets('a line is typed and entered; whitespace alone only presses enter',
        (tester) async {
      expect(await reply.sendLine('use the staging db'), isTrue);
      expect(sent('pane.send_input').single, {
        'pane_id': 'w1:p1',
        'text': 'use the staging db',
        'keys': ['enter'],
      });
      expect(reply.subject, isNull, reason: 'no chip to carry the feedback');
      expect(reply.sentLabel, '“use the staging db”');
      await tester.pump(const Duration(seconds: 4));

      transport.calls.clear();
      await reply.sendLine('   ');
      expect(sent('pane.send_input'), isEmpty);
      expect(sent('pane.send_keys').single['keys'], ['enter']);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a long reply is clipped in its confirmation, not in what is sent',
        (tester) async {
      final text = 'word ' * 30;
      await reply.sendLine(text);
      expect(sent('pane.send_input').single['text'], text);
      expect(reply.sentLabel.length, lessThan(30));
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a single key goes out as itself', (tester) async {
      await reply.sendKey('esc');
      expect(sent('pane.send_keys').single['keys'], ['esc']);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('moving through a menu does not lock the answer chips', (tester) async {
      await reply.sendKey('down');
      expect(reply.phase, ReplyPhase.idle, reason: 'arrow keys are not an answer');
      expect(await reply.choose(_yes, asked: _asked), isTrue, reason: 'down, then tap: must not wait three seconds');
      expect([for (final c in sent('pane.send_keys')) c['keys']], [
        ['down'],
        ['1', 'enter'],
      ]);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  testWidgets('disposing mid-request is quiet', (tester) async {
    final pending = reply.choose(_yes, asked: _asked);
    reply.dispose();
    await pending;
    // A second dispose in tearDown must also be harmless to the test.
    reply = QuickReplyController(machine: machine, paneId: 'w1:p1', previews: screen, haptic: false);
  });
}
