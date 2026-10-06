import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/decision/mode_danger.dart';

import 'support/trace_session.dart';

ModeRisk _id(String id, [String? name]) => assessMode(id: id, name: name).risk;

AgentSessionState _session({String? modeId, List<Json> modes = const [], List<Json> options = const []}) {
  return const AgentSessionState('s').withSetup(
    AcpSessionSetup.parse({
      if (modeId != null) 'modes': {'currentModeId': modeId, 'availableModes': modes},
      'configOptions': options,
    }),
  );
}

void main() {
  // What each route sends (docs/AGENT_SESSIONS.md "Routes", the recorded
  // traces): id, name, expected risk.
  const known = <(String, String, ModeRisk)>[
    // Claude Code
    ('default', 'Default', ModeRisk.none),
    ('plan', 'Plan Mode', ModeRisk.none),
    ('dontAsk', "Don't Ask", ModeRisk.none),
    ('acceptEdits', 'Accept Edits', ModeRisk.elevated),
    ('auto', 'Auto', ModeRisk.elevated),
    ('bypassPermissions', 'Bypass Permissions', ModeRisk.dangerous),
    // Codex
    ('read-only', 'Read-only', ModeRisk.none),
    ('workspace-write', 'Workspace access', ModeRisk.none),
    ('agent', 'Auto review', ModeRisk.elevated),
    ('agent-full-access', 'Full access', ModeRisk.dangerous),
    // omp
    ('plan', 'Plan', ModeRisk.none),
  ];

  group('known modes', () {
    for (final (id, name, risk) in known) {
      test('$id ($name) is $risk', () {
        expect(_id(id, name), risk);
        expect(_id(id), risk, reason: 'the id alone');
        final a = assessMode(id: id, name: name);
        expect(a.reason == null, risk == ModeRisk.none, reason: 'a reason exactly when risky');
        expect(a.isRisky, risk != ModeRisk.none);
      });
    }

    test('every mode and mode option value in every recorded trace is classified without surprise', () {
      var seen = 0;
      for (final name in allTraces()) {
        final setup = replayTrace(name).setup;
        final modes = setup.modes?.availableModes ?? const [];
        for (final m in modes) {
          seen++;
          final expected = known.where((k) => k.$1 == m.id).map((k) => k.$3).toSet();
          expect(expected, isNotEmpty, reason: '$name: mode ${m.id} is missing from the table in this test');
          expect({_id(m.id, m.name)}, expected, reason: '$name ${m.id}');
        }
        for (final o in setup.configOptions) {
          if (o is SelectConfigOption && o.category == 'mode') {
            for (final c in o.choices) {
              expect({_id(c.value, c.name)}, known.where((k) => k.$1 == c.value).map((k) => k.$3).toSet(), reason: '$name ${c.value}');
            }
          }
        }
      }
      expect(seen, greaterThan(20));
    });
  });

  group('case and format variants', () {
    test('one mode, many spellings', () {
      for (final s in [
        'bypassPermissions',
        'bypass_permissions',
        'bypass-permissions',
        'BYPASSPERMISSIONS',
        'Bypass Permissions',
        '  bypass permissions  ',
        'bypass\u200BPermissions',
        'bypass\u202EPermissions',
      ]) {
        expect(_id(s), ModeRisk.dangerous, reason: s);
      }
      for (final s in ['agent-full-access', 'agent_full_access', 'AGENT FULL ACCESS', 'Full access', 'FULL-ACCESS', 'danger-full-access']) {
        expect(_id(s), ModeRisk.dangerous, reason: s);
      }
      for (final s in ['acceptEdits', 'accept_edits', 'ACCEPT EDITS', 'Accept Edits']) {
        expect(_id(s), ModeRisk.elevated, reason: s);
      }
      for (final s in ['Auto', 'AUTO', ' auto ']) {
        expect(_id(s), ModeRisk.elevated, reason: s);
      }
    });

    test('the worse of id and name wins', () {
      expect(_id('default', 'Bypass Permissions'), ModeRisk.dangerous);
      expect(_id('bypassPermissions', 'Default'), ModeRisk.dangerous);
      expect(_id('default', 'Accept Edits'), ModeRisk.elevated);
      expect(_id('default', 'Default'), ModeRisk.none);
    });
  });

  group('modes nobody listed', () {
    test('words that mean "no checks" are dangerous', () {
      for (final s in [
        'bypass',
        'bypass-all',
        'super-bypass',
        'yolo',
        'YOLO mode',
        'full-access',
        'fullAccess',
        'dangerously-skip-permissions',
        'dangerouslyAllowAll',
        'skip-permissions',
        'skipPermissions',
        'no-sandbox',
      ]) {
        final a = assessMode(id: s);
        expect(a.risk, ModeRisk.dangerous, reason: s);
        expect(a.reason, isNotNull);
      }
    });

    test('words that mean "asks for less" are elevated', () {
      for (final s in ['auto-accept', 'autoApprove', 'auto_edit', 'accept-all', 'unrestricted', 'never-ask', 'no-prompts', 'autonomous', 'Auto mode', 'dont-ask-again']) {
        expect(_id(s), ModeRisk.elevated, reason: s);
      }
    });

    test('plain unknown names are none', () {
      for (final s in ['custom', 'author', 'Chế độ an toàn', '安全模式', 'review', 'architect', 'ask', 'code', '', '   ', '\u202E']) {
        expect(_id(s), ModeRisk.none, reason: '"$s"');
      }
      expect(assessMode().risk, ModeRisk.none);
      expect(assessMode(id: null, name: null).reason, isNull);
    });

    test('the reason names the mode, cleaned and capped', () {
      final a = assessMode(id: 'yolo\u202E-${'x' * 100}');
      expect(a.reason, contains('looks like it skips permission checks'));
      expect(a.reason, isNot(contains('\u202E')));
      expect(a.reason!.length, lessThan(120));
      expect(assessMode(id: 'autonomous').reason, 'The mode "autonomous" may ask for less than usual.');
    });

    test('descriptions are never read (Claude default "prompts for dangerous operations")', () {
      expect(_id('default', 'Default'), ModeRisk.none);
    });
  });

  group('the session mode', () {
    test('the mode option is read (category mode), with its choice name', () {
      final s = _session(
        modeId: 'agent-full-access',
        options: [
          {
            'id': 'mode',
            'name': 'Mode',
            'category': 'mode',
            'type': 'select',
            'currentValue': 'agent-full-access',
            'options': [
              {'value': 'agent', 'name': 'Auto review'},
              {'value': 'agent-full-access', 'name': 'Full access'},
            ],
          },
        ],
      );
      final m = currentModeOf(s)!;
      expect((m.id, m.name, m.viaModes), ('agent-full-access', 'Full access', false));
      expect(assessSessionMode(s).risk, ModeRisk.dangerous);
    });

    test('modes alone work too (session/set_mode)', () {
      final s = _session(
        modeId: 'acceptEdits',
        modes: [
          {'id': 'default', 'name': 'Default'},
          {'id': 'acceptEdits', 'name': 'Accept Edits'},
        ],
      );
      final m = currentModeOf(s)!;
      expect((m.name, m.viaModes), ('Accept Edits', true));
      expect(assessSessionMode(s).risk, ModeRisk.elevated);
    });

    test('a current id the list does not hold keeps the id as its name', () {
      final s = _session(modeId: 'bypassPermissions', modes: [
        {'id': 'default', 'name': 'Default'},
      ]);
      expect(currentModeOf(s)!.name, 'bypassPermissions');
      expect(assessSessionMode(s).risk, ModeRisk.dangerous);
    });

    test('pi lists thinking levels as modes: not a permission mode', () {
      final levels = [
        for (final l in ['off', 'low', 'high']) {'id': l, 'name': 'Thinking: $l'},
      ];
      final s = _session(
        modeId: 'high',
        modes: levels,
        options: [
          {
            'id': 'thought_level',
            'name': 'Thinking',
            'category': 'thought_level',
            'type': 'select',
            'currentValue': 'high',
            'options': [
              for (final l in ['off', 'low', 'high']) {'value': l, 'name': 'Thinking: $l'},
            ],
          },
        ],
      );
      expect(currentModeOf(s), isNull);
      expect(assessSessionMode(s).risk, ModeRisk.none);
    });

    test('no mode, an empty mode: none', () {
      expect(currentModeOf(const AgentSessionState('s')), isNull);
      expect(assessSessionMode(const AgentSessionState('s')).risk, ModeRisk.none);
      expect(assessSessionMode(_session(modeId: '')).risk, ModeRisk.none);
    });

    test('recorded sessions: setup modes, then the agent moves to a dangerous one', () {
      for (final name in ['claude/permission', 'codex/tools', 'omp/plan']) {
        final setup = replayTrace(name).setup;
        final before = assessSessionMode(setup).risk;
        final id = name.startsWith('codex') ? 'agent-full-access' : name.startsWith('claude') ? 'bypassPermissions' : 'default';
        final moved = setup.apply(SessionUpdate.parse({'sessionUpdate': 'current_mode_update', 'currentModeId': id}));
        expect(currentModeOf(moved)!.id, id, reason: name);
        expect(assessSessionMode(moved).risk, name.startsWith('omp') ? ModeRisk.none : ModeRisk.dangerous, reason: name);
        expect(before, isNot(ModeRisk.dangerous), reason: '$name starts safe');
      }
    });
  });
}
