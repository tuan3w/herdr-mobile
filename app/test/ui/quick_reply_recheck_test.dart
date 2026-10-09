// An answer is sent on the strength of the question the person was shown. The
// pane is read again just before the keys go; what the digest cannot see (a
// reason to ask twice) must not slip a risky answer out on a one-tap chip.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/observed_requests.dart';
import 'package:herdr_mobile/data/repositories/pane_answerer.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/prompt_detector.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/features/agents/quick_reply_controller.dart';

import '../support/fake_transport.dart';

class _Screen extends Fake implements PanePreviews {
  _Screen(this.now);

  PromptInfo? now;

  @override
  Future<PromptInfo?> recheck(MachineConnection machine, String paneId) async => now;
}

const _plain = PromptInfo(
  question: 'Do you want to proceed?',
  replies: [
    QuickReply(label: '1. Yes', keys: ['1', 'enter']),
    QuickReply(label: '2. No', keys: ['2', 'enter']),
  ],
);

/// The same question and words, but the answer now needs a second tap (what
/// the digest does not cover: a cut command, a reason read from other rows).
const _gated = PromptInfo(
  question: 'Do you want to proceed?',
  replies: [
    QuickReply(label: '1. Yes', keys: ['1', 'enter'], needsConfirm: true, risk: 'long command, check it all'),
    QuickReply(label: '2. No', keys: ['2', 'enter']),
  ],
);

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
    screen = _Screen(_plain);
    reply = QuickReplyController(machine: machine, paneId: 'w1:p1', previews: screen, haptic: false);
  });

  tearDown(() {
    reply.dispose();
    machine.dispose();
  });

  List<Object?> sentKeys() => [
        for (final (m, p) in transport.calls)
          if (m == 'pane.send_keys') p['keys'],
      ];

  group('a one-tap chip that became a gated answer', () {
    testWidgets('is not sent: the person never confirmed it', (tester) async {
      screen.now = _gated;
      expect(await reply.choose(_plain.replies.first, asked: _plain), isFalse);

      expect(sentKeys(), isEmpty);
      expect(promptDigest(_gated), promptDigest(_plain), reason: 'the digest alone could not tell');
      expect(reply.phase, ReplyPhase.changed);
      expect(reply.subject, _gated.replies.first, reason: 'the chip under the thumb shows what it is now');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a declining answer still goes', (tester) async {
      screen.now = _gated;
      expect(await reply.choose(_plain.replies.last, asked: _plain), isTrue);
      expect(sentKeys(), [
        ['2', 'enter'],
      ]);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('one the person confirmed goes', (tester) async {
      screen.now = _gated;
      final shown = _gated.replies.first;
      await reply.choose(shown, asked: _gated);
      expect(await reply.choose(shown, asked: _gated), isTrue);
      expect(sentKeys(), [
        ['1', 'enter'],
      ]);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('an observed prompt carries its own reason to the dock', () {
    test('a gated reply travels as the option gate, a plain one does not', () {
      final request = promptRequest(_gated, paneId: 'w1:p1');
      final yes = request.options.first, no = request.options.last;
      expect(yes.gate, 'long command, check it all');
      expect(no.gate, isNull);
      expect(promptRequest(_plain, paneId: 'w1:p1').options.map((o) => o.gate), [null, null]);
    });

    test('a command the card had to cut gates Yes: the dock judges only the rows it is given', () {
      final prompt = detectPrompt([
        ' Bash command',
        for (var i = 1; i <= 9; i++) '   part $i',
        ' Do you want to proceed?',
        ' ❯ 1. Yes',
        '   2. No',
      ])!;
      final request = promptRequest(prompt, paneId: 'w1:p1');
      expect(request.options.first.gate, longCommand);
      expect(request.options.last.gate, isNull);
    });
  });
}
