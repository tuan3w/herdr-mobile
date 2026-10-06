import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/decision/mode_danger.dart';
import 'package:herdr_mobile/data/decision/session_chips.dart';

import 'support/trace_session.dart';

Json _select(String id, String category, String value, List<List<String>> choices, {String? name}) => {
  'id': id,
  'name': name ?? id,
  if (category.isNotEmpty) 'category': category,
  'type': 'select',
  'currentValue': value,
  'options': [
    for (final c in choices) {'value': c[0], 'name': c[1]},
  ],
};

Json _bool(String id, bool value, {String? name}) => {'id': id, 'name': name ?? id, 'type': 'boolean', 'currentValue': value};

AgentSessionState _with(List<Json> options, {Json? modes}) => const AgentSessionState('s').withSetup(
  AcpSessionSetup.parse({'configOptions': options, 'modes': ?modes}),
);

List<String> _labels(SessionChips c) => [for (final x in c.shown) x.label];

void main() {
  group('recorded sessions', () {
    test('Claude: mode, model, effort, then the persona select', () {
      final chips = sessionChipsOf(replayTrace('claude/tools').setup);
      expect([for (final c in chips.all) c.kind], [
        SessionChipKind.mode,
        SessionChipKind.model,
        SessionChipKind.effort,
        SessionChipKind.other,
      ]);
      expect(_labels(chips), ['Default', 'Opus', 'High', 'Agent: Default']);
      expect(chips.overflow, 0);
      expect(chips.all.first.risk, ModeRisk.none);
      expect(chips.all.first.settingId, 'mode');
      expect(chips.all.first.viaModes, isFalse);
    });

    test('Codex: Auto review is elevated; reasoning is the effort chip', () {
      final chips = sessionChipsOf(replayTrace('codex/tools').setup);
      final mode = chips.all.first;
      expect((mode.label, mode.risk), ('Auto review', ModeRisk.elevated));
      expect(mode.reason, isNotNull);
      expect(chips.all.map((c) => c.kind), [
        SessionChipKind.mode,
        SessionChipKind.model,
        SessionChipKind.effort,
        SessionChipKind.other,
      ]);
      expect(chips.all[2].title, 'Reasoning effort');
      expect(chips.all[3].label, 'Collaboration mode: Default');
    });

    test('omp: three chips, model by its display name', () {
      final chips = sessionChipsOf(replayTrace('omp/tools').setup);
      expect(_labels(chips), ['Default', 'Claude Sonnet 5.5', 'high']);
    });

    test('the danger chip follows the mode when the agent changes it', () {
      final setup = replayTrace('codex/tools').setup;
      final moved = setup.apply(SessionUpdate.parse({'sessionUpdate': 'current_mode_update', 'currentModeId': 'agent-full-access'}));
      final mode = sessionChipsOf(moved).all.first;
      expect((mode.label, mode.risk, mode.isRisky), ('Full access', ModeRisk.dangerous, true));
    });
  });

  group('derivation', () {
    test('order is fixed whatever order the agent lists its options in', () {
      final options = [
        _bool('fast', true, name: 'Fast'),
        _select('effort', 'thought_level', 'high', [['high', 'High']], name: 'Effort'),
        _select('model', 'model', 'm1', [['m1', 'Model One']], name: 'Model'),
        _select('mode', 'mode', 'default', [['default', 'Default']], name: 'Mode'),
        _select('extra', '', 'x', [['x', 'Ex']], name: 'Extra'),
      ];
      final a = sessionChipsOf(_with(options));
      final b = sessionChipsOf(_with(options.reversed.toList()));
      expect(_labels(a), ['Default', 'Model One', 'High', 'Fast']);
      expect(_labels(b), _labels(a));
      expect(a.overflow, 1);
      expect(a.hidden.single.label, 'Extra: Ex');
      expect(a.all.map((c) => c.settingId).toList(), b.all.map((c) => c.settingId).toList());
    });

    test('a boolean is a toggle chip with its state; labels are its name', () {
      final chips = sessionChipsOf(_with([_bool('fast', true, name: 'Fast'), _bool('think', false, name: 'Thinking')]));
      expect([for (final c in chips.all) (c.label, c.on, c.kind)], [
        ('Fast', true, SessionChipKind.toggle),
        ('Thinking', false, SessionChipKind.toggle),
      ]);
      expect(chips.all.first.settingId, 'fast');
    });

    test('at most four are shown; the overflow counts the rest', () {
      final chips = sessionChipsOf(
        _with([
          _select('mode', 'mode', 'default', [['default', 'Default']]),
          _select('model', 'model', 'm', [['m', 'M']]),
          _select('effort', 'thought_level', 'h', [['h', 'H']]),
          _bool('a', true),
          _bool('b', false),
          _bool('c', false),
        ]),
      );
      expect(chips.all, hasLength(6));
      expect(chips.shown, hasLength(maxSessionChips));
      expect(chips.overflow, 2);
      expect(chips.hidden.map((c) => c.label), ['b', 'c']);
    });

    test('a risky chip is never the one cut', () {
      const risky = SessionChip(kind: SessionChipKind.other, settingId: 'x', title: 'X', label: 'X', risk: ModeRisk.dangerous);
      const quiet = SessionChip(kind: SessionChipKind.other, settingId: 'q', title: 'Q', label: 'Q');
      final chips = SessionChips([quiet, quiet, quiet, quiet, risky]);
      expect(chips.shown, hasLength(4));
      expect(chips.shown.last, same(risky));
      expect(chips.overflow, 1);
    });

    test('modes with no mode option: a mode chip through modes', () {
      final chips = sessionChipsOf(_with(const [], modes: {
        'currentModeId': 'bypassPermissions',
        'availableModes': [
          {'id': 'default', 'name': 'Default'},
          {'id': 'bypassPermissions', 'name': 'Bypass Permissions'},
        ],
      }));
      final mode = chips.all.single;
      expect((mode.label, mode.viaModes, mode.risk), ('Bypass Permissions', true, ModeRisk.dangerous));
      expect(mode.reason, isNotNull);
    });

    test('pi: thinking levels listed as modes are the effort chip, never a mode chip', () {
      final levels = [
        ['off', 'Thinking: off'],
        ['high', 'Thinking: high'],
      ];
      final chips = sessionChipsOf(
        _with(
          [_select('model', 'model', 'p/m', [['p/m', 'p/m']]), _select('thinking', 'thought_level', 'high', levels, name: 'Thinking')],
          modes: {
            'currentModeId': 'high',
            'availableModes': [
              for (final l in levels) {'id': l[0], 'name': l[1]},
            ],
          },
        ),
      );
      expect(chips.all.map((c) => c.kind), [SessionChipKind.model, SessionChipKind.effort]);
      expect(_labels(chips), ['m', 'Thinking: high'], reason: 'a provider prefix on a bare model id is dropped');
    });

    test('a model with a display name keeps it; one named by id loses the provider', () {
      final named = sessionChipsOf(_with([_select('model', 'model', 'a/b', [['a/b', 'Fancy B']])]));
      expect(_labels(named), ['Fancy B']);
      final bare = sessionChipsOf(_with([_select('model', 'model', 'a/b/c', [['a/b/c', 'a/b/c']])]));
      expect(_labels(bare), ['c']);
    });

    test('missing and unknown option kinds make no chip', () {
      final s = _with([
        {'id': 'weird', 'name': 'Weird', 'type': 'slider', 'currentValue': 3},
        {'id': 'empty', 'name': 'Empty', 'type': 'select', 'currentValue': '', 'options': []},
        _select('blank', '', 'b', [['b', '   ']]),
        {'id': 'model', 'type': 'select', 'category': 'model', 'currentValue': 'm', 'options': []},
      ]);
      final chips = sessionChipsOf(s);
      expect(_labels(chips), ['m'], reason: 'the value stands in when it is not among the choices');
      expect(sessionChipsOf(const AgentSessionState('s')).all, isEmpty);
      expect(SessionChips.none.overflow, 0);
    });

    test('labels are cleaned of hidden characters and capped', () {
      final chips = sessionChipsOf(_with([
        _select('model', 'model', 'm', [['m', 'Mo\u202Edel \u200Bwith a name that is far too long to fit a chip']]),
      ]));
      final label = chips.all.single.label;
      expect(label.length, lessThanOrEqualTo(chipLabelLimit));
      expect(label, isNot(contains('\u202E')));
      expect(label, isNot(contains('\u200B')));
      expect(label, endsWith('\u2026'));
    });

    test('Vietnamese labels are kept', () {
      final chips = sessionChipsOf(_with([
        _select('model', 'model', 'm', [['m', 'Mô hình tiết kiệm']]),
      ]));
      expect(chips.all.single.label, 'Mô hình tiết kiệm');
    });
  });
}
