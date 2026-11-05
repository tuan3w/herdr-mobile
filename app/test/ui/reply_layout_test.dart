// A decision on the card and in the reply sheet: the answers that allow come
// first, the ones that decline sit apart and quiet, and a standing grant is
// off the card's main path (in the sheet, still held). Prompts are captured
// from real agents (test/fixtures/prompts).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/prompt_detector.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/agent_card.dart';
import 'package:herdr_mobile/ui/features/agents/reply_chips.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'hold_support.dart';
import 'ui_harness.dart';

/// The prompt the detector finds in a captured screen.
PromptInfo _captured(String name) {
  final rows = File('test/fixtures/prompts/$name.txt').readAsLinesSync();
  final screen = rows.skipWhile((r) => RegExp(r'^# [a-z_]+:').hasMatch(r)).join('\n');
  return detectPrompt(previewRows(screen, keep: 24))!;
}

List<String> _labels(List<QuickReply> replies) => [for (final r in replies) r.label];

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine() => (
  profile: const MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
  snapshot: snapshotWith([(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked')], title: (_) => 'task 1'),
);

Future<BoardHarness> _board(WidgetTester tester, PromptInfo prompt, {double width = 360, double textScale = 1}) async {
  final h = await BoardHarness.create([_machine()]);
  h.previews.set('a/w1:p1', ['…context…'], prompt: prompt);
  await pumpBoard(tester, h, width: width, height: 2400, textScale: textScale);
  return h;
}

List<String> _sent(BoardHarness h) => [
  for (final (m, p) in h.transports['a']!.calls)
    if (m == 'pane.send_keys') (p['keys'] as List).join('+'),
];

Finder _inCard(String text) => find.descendant(of: find.byType(AgentCard), matching: find.text(text));
Finder _inSheet(String text) => find.descendant(of: find.byType(ReplySheet), matching: find.text(text));

/// The colour a chip paints at rest, from the box under its words.
Color? _fill(WidgetTester tester, Finder words) {
  final box = tester.widget<AnimatedContainer>(
    find.ancestor(of: words, matching: find.byType(AnimatedContainer)).first,
  );
  return (box.decoration! as BoxDecoration).color;
}

void main() {
  group('ReplyLayout', () {
    test('a standing grant leaves the card; allowing, then declining', () {
      final prompt = _captured('claude/approvalfull-bash-multiline-dontask');

      final card = ReplyLayout.of(prompt);
      expect(_labels(card.allow), ['1. Yes']);
      expect(card.hidden, 2, reason: "don't ask again and auto mode go behind more");
      expect(_labels(card.refuse), ['4. No']);

      final sheet = ReplyLayout.of(prompt, card: false);
      expect(_labels(sheet.allow), ['1. Yes', "2. Yes, don't ask again", '3. Yes, and switch to auto mode · auto…']);
      expect(sheet.hidden, 0);
      expect(_labels(sheet.refuse), ['4. No']);
    });

    test('codex: one allow, a more chip, the refusal', () {
      final card = ReplyLayout.of(_captured('codex/approval-command'));
      expect(_labels(card.allow), ['1. Yes, proceed']);
      expect(card.hidden, 1);
      expect(_labels(card.refuse), ['3. No']);
      expect(card.count, 3);
    });

    test('the height is the chips, the gap between them and the wider gap between groups', () {
      final card = ReplyLayout.of(_captured('codex/approval-command'));
      expect(card.height, 3 * kMinTap + Gap.sm + Gap.lg);
    });

    test('a long menu without a refusal keeps its order and its last place for more', () {
      final prompt = PromptInfo(
        question: 'Pick one',
        replies: [
          for (var i = 1; i <= 6; i++) QuickReply(label: '$i. Option $i', keys: ['$i']),
        ],
      );
      final card = ReplyLayout.of(prompt, limit: 4);
      expect(_labels(card.allow), ['1. Option 1', '2. Option 2', '3. Option 3']);
      expect(card.hidden, 3);
      expect(card.refuse, isEmpty);
      expect(card.height, 4 * kMinTap + 3 * Gap.sm);
    });

    test('a refusal listed first still goes after the answers that allow', () {
      const prompt = PromptInfo(
        question: 'Continue?',
        replies: [
          QuickReply(label: 'Cancel', keys: ['esc']),
          QuickReply(label: 'Continue', keys: ['enter']),
        ],
      );
      final card = ReplyLayout.of(prompt);
      expect(_labels(card.allow), ['Continue']);
      expect(_labels(card.refuse), ['Cancel']);
    });
  });

  group('on the card', () {
    setUpAll(loadAppFonts);

    testWidgets('the refusal sits apart and quiet; the standing grant is not on the card', (tester) async {
      final prompt = _captured('claude/approvalfull-bash-multiline-dontask');
      final h = await _board(tester, prompt);

      expect(_inCard('1. Yes'), findsOneWidget);
      expect(_inCard('4. No'), findsOneWidget);
      expect(_inCard("2. Yes, don't ask again"), findsNothing, reason: 'a standing grant is not one tap from a glance');
      expect(_inCard('2 more…'), findsOneWidget);

      final more = tester.getRect(
        find.ancestor(of: _inCard('2 more…'), matching: find.byType(AnimatedContainer)).first,
      );
      final no = tester.getRect(find.ancestor(of: _inCard('4. No'), matching: find.byType(AnimatedContainer)).first);
      expect(no.top - more.bottom, Gap.lg, reason: 'declining is a group of its own');
      expect(_fill(tester, _inCard('4. No')), isNot(_fill(tester, _inCard('1. Yes'))), reason: 'not the same fill');
      expect(_fill(tester, _inCard('4. No')), Colors.transparent, reason: 'no fill: a fill read as another yes');
      Finder cross(String label) => find.descendant(
        of: find.ancestor(of: _inCard(label), matching: find.byType(AnswerChip)),
        matching: find.byIcon(LucideIcons.x),
      );
      expect(cross('4. No'), findsOneWidget, reason: 'a small ✕ says it is an answer to tap');
      expect(cross('1. Yes'), findsNothing);

      await tester.tap(_inCard('4. No'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_sent(h), ['4+enter'], reason: 'the keys are the option’s, whatever its place');
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });

    testWidgets('the card reserves exactly the chips it draws, at any text size', (tester) async {
      for (final scale in [1.0, 1.6]) {
        final prompt = _captured('claude/approvalfull-bash-multiline-dontask');
        final h = await _board(tester, prompt, width: 320, textScale: scale);
        final block = tester.getRect(find.byType(ReplyChips));
        expect(block.height, ReplyChips.heightFor(prompt));
        final last = tester.getRect(
          find.ancestor(of: _inCard('4. No'), matching: find.byType(AnimatedContainer)).first,
        );
        expect(last.bottom, block.bottom, reason: 'the last chip ends where the reserved room ends (x$scale)');
        expect(tester.takeException(), isNull);
        await teardownBoard(tester, h);
      }
    });

    testWidgets('a two-option prompt shows both, allow then decline', (tester) async {
      const prompt = PromptInfo(
        question: 'Do you want to proceed?',
        subject: 'npm test',
        replies: [
          QuickReply(label: '1. Yes', keys: ['1', 'enter']),
          QuickReply(label: '2. No', keys: ['2', 'enter']),
        ],
      );
      final h = await _board(tester, prompt);
      expect(_inCard('1. Yes'), findsOneWidget);
      expect(_inCard('2. No'), findsOneWidget);
      expect(find.textContaining('more…'), findsNothing);
      expect(tester.getTopLeft(_inCard('1. Yes')).dy, lessThan(tester.getTopLeft(_inCard('2. No')).dy));
      expect(tester.getRect(find.byType(ReplyChips)).height, 2 * kMinTap + Gap.lg);
      await teardownBoard(tester, h);
    });

    testWidgets('the sheet shows the standing grant in the same order, and it is still held', (tester) async {
      final prompt = _captured('claude/approvalfull-bash-multiline-dontask');
      final h = await _board(tester, prompt);

      await tester.tap(_inCard('2 more…'));
      await settle(tester);
      expect(find.byType(ReplySheet), findsOneWidget);

      double top(String label) => tester.getTopLeft(_inSheet(label)).dy;
      expect(top('1. Yes'), lessThan(top("2. Yes, don't ask again")));
      expect(top("2. Yes, don't ask again"), lessThan(top('4. No')), reason: 'one decision looks the same');

      await quickTap(tester, _inSheet("2. Yes, don't ask again"));
      expect(_inSheet('Hold to send · standing permission'), findsOneWidget);
      expect(_sent(h), isEmpty, reason: 'a tap never sends a standing grant');

      await holdFor(tester, _inSheet('Hold to send · standing permission'));
      expect(_sent(h), ['2+enter']);
      await tester.pump(const Duration(seconds: 4));
      await teardownBoard(tester, h);
    });
  });
}
