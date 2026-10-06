// A blocked agent's card and reply sheet show what the answer approves (the
// command), in order after the question, and the confirm chip says why.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/prompt_detector.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/hold_confirm.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'hold_support.dart';
import 'ui_harness.dart';

const _tall = 2400.0;

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine() => (
      profile: const MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
      snapshot: snapshotWith(
        [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked')],
        title: (_) => 'task 1',
      ),
    );

const _question = 'Do you want to proceed?';
const _command = 'git push origin main\nPush to remote';

const _push = PromptInfo(
  question: _question,
  subject: _command,
  replies: [
    QuickReply(label: '1. Yes', keys: ['1', 'enter'], needsConfirm: true, risk: 'pushes to a remote'),
    QuickReply(label: '2. No', keys: ['2', 'enter']),
  ],
);

Future<BoardHarness> _board(
  WidgetTester tester,
  PromptInfo prompt, {
  double width = 360,
  double textScale = 1,
  Brightness brightness = Brightness.dark,
  List<String> lines = const ['…context…'],
}) async {
  final h = await BoardHarness.create([_machine()]);
  h.previews.set('a/w1:p1', lines, prompt: prompt);
  await pumpBoard(tester, h, width: width, height: _tall, textScale: textScale, brightness: brightness);
  return h;
}

double _cardHeight(WidgetTester tester) => tester.getSize(find.byType(AgentCard)).height;

Finder _inCard(Finder f) => find.descendant(of: find.byType(AgentCard), matching: f);

Finder _monoText() => _inCard(
      find.byWidgetPredicate((w) => w is Text && w.style?.fontFamily == monoFamily),
    );

void main() {
  setUpAll(loadAppFonts);

  group('card', () {
    for (final brightness in Brightness.values) {
      testWidgets('shows the question, then the command under it, in ${brightness.name}', (tester) async {
        final h = await _board(tester, _push, brightness: brightness);

        final question = find.text(_question);
        final subject = find.text(_command);
        expect(question, findsOneWidget);
        expect(subject, findsOneWidget);
        expect(tester.getTopLeft(question).dy, lessThan(tester.getTopLeft(subject).dy),
            reason: 'the question reads first, the command under it');

        final text = tester.widget<Text>(subject);
        expect(text.style!.fontFamily, monoFamily);
        expect(text.style!.fontSize, promptSubjectStyle.fontSize);
        expect(text.style!.color, isNotNull);
        expect(text.maxLines, 3);
        expect(text.overflow, TextOverflow.ellipsis);

        // Right padding 44 keeps the reply button clear of both texts.
        final block = tester.getRect(find.ancestor(of: subject, matching: find.byType(Container)).first);
        expect(tester.getRect(subject).right, lessThanOrEqualTo(block.right - 44 + 0.5));
        expect(block.height, greaterThanOrEqualTo(kMinTap));
        await teardownBoard(tester, h);
      });
    }

    testWidgets('the semantic label reads the question and the command', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await _board(tester, _push);

      expect(
        find.bySemanticsLabel(RegExp(r'Asks: Do you want to proceed\?\. git push origin main, Push to remote')),
        findsOneWidget,
      );
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('without a subject only the question shows, and the label has no stray full stop',
        (tester) async {
      final semantics = tester.ensureSemantics();
      const edit = PromptInfo(
        question: 'Do you want to make this edit to main.dart?',
        replies: [QuickReply(label: '1. Yes', keys: ['1', 'enter'])],
      );
      final h = await _board(tester, edit);

      expect(_monoText(), findsNothing);
      expect(tester.widget<Text>(find.text(edit.question)).maxLines, 3,
          reason: 'with no subject the question keeps its extra line');
      expect(find.bySemanticsLabel(RegExp(r'Asks: Do you want to make this edit to main\.dart\?$')),
          findsOneWidget);
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('a prompt detected from a Claude Code screen puts its command on the card', (tester) async {
      final prompt = detectPrompt(const [
        ' Bash command',
        '',
        '   npm publish --access public',
        '   Publish the package',
        '',
        ' Do you want to proceed?',
        ' ❯ 1. Yes',
        "   2. Yes, and don't ask again for npm commands in /x",
        '   3. No, and tell Claude what to do differently (esc)',
      ])!;
      final h = await _board(tester, prompt);

      expect(find.text('npm publish --access public\nPublish the package'), findsOneWidget);
      await quickTap(tester, find.text('1. Yes'));
      expect(find.text('Hold to send · publishes or merges'), findsOneWidget);
      await holdFor(tester, find.text('Hold to send · publishes or merges'));
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('a 400 character command and Vietnamese diacritics ellipsize without overflow',
        (tester) async {
      final subject = [
        'x' * 400,
        'Đường dẫn rất dài: /home/user/dự-án/thư-mục-rất-dài/ngày-hôm-nay/${'tệp-tin/' * 12}',
        'Tiếng Việt có dấu: ắ ằ ẳ ẵ ặ ế ề ể ễ ệ ố ồ ổ ỗ ộ ớ ờ ở ỡ ợ ứ ừ ử ữ ự',
      ].join('\n');
      final prompt = PromptInfo(
        question: 'Bạn có muốn tiếp tục không? Lệnh sẽ chạy dưới đây, hãy kiểm tra kỹ trước khi đồng ý',
        subject: subject,
        replies: const [
          QuickReply(
            label: '1. Có, và đừng hỏi lại cho các lệnh tương tự như thế này nữa',
            keys: ['1'],
            needsConfirm: true,
            risk: 'removes containers or volumes',
          ),
          QuickReply(label: '2. Không', keys: ['2']),
        ],
      );
      final h = await _board(tester, prompt, width: 320, textScale: 2);
      expect(tester.takeException(), isNull);

      final text = tester.widget<Text>(find.text(subject));
      expect(text.maxLines, 3);
      expect(text.overflow, TextOverflow.ellipsis);
      // Three lines at 12.5 sp x 1.35 x 2 and no more.
      expect(tester.getSize(find.text(subject)).height, lessThanOrEqualTo(3 * 12.5 * 1.35 * 2 + 1));
      expect(tester.getSize(find.text(prompt.question)).height, lessThanOrEqualTo(2 * 14 * 1.35 * 2 + 1),
          reason: 'with a subject the question is held to two lines');

      // The long reason fits the chip too.
      await quickTap(tester, find.textContaining('Có, và đừng hỏi lại'));
      expect(find.textContaining('Hold to send · removes containers'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final g = await pressAndHold(tester, find.textContaining('Hold to send'), const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: 'the long reason fits the chip while it fills');
      await g.up();
      await advance(tester, holdHintWindow);
      expect(tester.takeException(), isNull);
      await teardownBoard(tester, h);
    });

    testWidgets('the card keeps its height through every chip state and while lines stream',
        (tester) async {
      final h = await _board(tester, _push);
      final idle = _cardHeight(tester);

      for (final lines in [
        <String>[],
        ['one'],
        ['1', '2', '3', '4', '5', '6', '7', '8'],
      ]) {
        h.previews.set('a/w1:p1', lines, prompt: _push);
        await tester.pump();
        expect(_cardHeight(tester), idle, reason: '${lines.length} lines moved the rows below');
      }

      await quickTap(tester, find.text('1. Yes'));
      expect(find.text('Hold to send · pushes to a remote'), findsOneWidget);
      expect(_cardHeight(tester), idle, reason: 'hinting');

      await holdFor(tester, find.text('Hold to send · pushes to a remote'));
      expect(find.text('Sent: 1. Yes'), findsOneWidget);
      expect(_cardHeight(tester), idle, reason: 'sent');
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });
  });

  group('confirm chip', () {
    List<Object?> sentKeys(BoardHarness h) => [
          for (final (m, p) in h.transports['a']!.calls)
            if (m == 'pane.send_keys') p['keys'],
        ];

    testWidgets('names the reason in the hint, and sends only when held', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await _board(tester, _push);

      await quickTap(tester, find.text('1. Yes'));
      expect(find.text('Hold to send · pushes to a remote'), findsOneWidget);
      expect(find.bySemanticsLabel('1. Yes, needs holding or a second activation: pushes to a remote'), findsOneWidget);
      expect(sentKeys(h), isEmpty, reason: 'a tap only says how');

      await holdFor(tester, find.text('Hold to send · pushes to a remote'));
      expect(sentKeys(h).single, ['1', 'enter']);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('the assistive path primes with the reason, then sends', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await _board(tester, _push);

      tester.semantics.tap(find.semantics.byLabel('1. Yes, needs holding or a second activation: pushes to a remote'));
      await tester.pump();
      expect(find.text('Hold or tap again · pushes to a remote'), findsOneWidget);
      expect(find.bySemanticsLabel('Confirm: 1. Yes, pushes to a remote'), findsOneWidget);
      expect(sentKeys(h), isEmpty);

      tester.semantics.tap(find.semantics.byLabel('Confirm: 1. Yes, pushes to a remote'));
      await tester.pump();
      expect(sentKeys(h).single, ['1', 'enter']);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
      await teardownBoard(tester, h);
    });

    testWidgets('without a known reason it still says "Hold to send"', (tester) async {
      final semantics = tester.ensureSemantics();
      const unknown = PromptInfo(
        question: _question,
        replies: [QuickReply(label: '1. Yes', keys: ['1', 'enter'], needsConfirm: true)],
      );
      final h = await _board(tester, unknown);

      await quickTap(tester, find.text('1. Yes'));
      expect(find.text('Hold to send'), findsOneWidget);
      await tester.pump(holdHintWindow);
      expect(find.bySemanticsLabel('1. Yes, needs holding or a second activation'), findsOneWidget);
      tester.semantics.tap(find.semantics.byLabel('1. Yes, needs holding or a second activation'));
      await tester.pump();
      expect(find.text('Hold or tap again to confirm'), findsOneWidget);
      expect(find.bySemanticsLabel('Confirm: 1. Yes'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      semantics.dispose();
      await teardownBoard(tester, h);
    });
  });

  group('reply sheet', () {
    testWidgets('shows the whole command, not three lines of it', (tester) async {
      final rows = [
        for (var i = 1; i <= 6; i++) 'step $i: ${'curl --header "X-Token: abc" https://example.com/api/v1/ ' * 2}',
      ];
      final subject = rows.join('\n');
      final prompt = PromptInfo(question: _question, subject: subject, replies: _push.replies);
      final h = await _board(tester, prompt);

      await tester.tap(find.byTooltip('Reply to task 1'));
      await settle(tester);

      final inSheet = find.descendant(of: find.byType(ReplySheet), matching: find.text(subject));
      expect(inSheet, findsOneWidget);
      final text = tester.widget<Text>(inSheet);
      expect(text.maxLines, isNull, reason: 'the sheet is where the full command is read');
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      expect(text.style!.fontFamily, monoFamily);
      expect(text.style!.fontSize, promptSubjectStyle.fontSize);
      expect(tester.getSize(inSheet).height, greaterThan(3 * 12.5 * 1.35 * 1.5),
          reason: 'six wrapped rows are taller than the card allows');
      expect(
        tester.getTopLeft(find.descendant(of: find.byType(ReplySheet), matching: find.text(_question))).dy,
        lessThan(tester.getTopLeft(inSheet).dy),
      );
      expect(tester.takeException(), isNull);
      await teardownBoard(tester, h);
    });

    testWidgets('its confirm chip names the reason too', (tester) async {
      final h = await _board(tester, _push);
      await tester.tap(find.byTooltip('Reply to task 1'));
      await settle(tester);

      Finder inSheet(String text) =>
          find.descendant(of: find.byType(ReplySheet), matching: find.text(text));
      await quickTap(tester, inSheet('1. Yes'));
      expect(inSheet('Hold to send · pushes to a remote'), findsOneWidget);
      expect(
        [for (final (m, _) in h.transports['a']!.calls) m].where((m) => m == 'pane.send_keys'),
        isEmpty,
      );

      await holdFor(tester, inSheet('Hold to send · pushes to a remote'));
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });
  });
}
