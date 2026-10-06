import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';

import 'support/fake_agent.dart';

void main() {
  group('initialize', () {
    test("reads omp's captured answer", () {
      final r = AcpInitializeResult.parse(ompInitialize());
      expect(r.protocolVersion, 1);
      expect(r.agentInfo!.name, 'omp');
      expect(r.agentInfo!.version, '18.4.12');
      expect(r.agentInfo!.label, 'omp');
      expect(r.authMethods.single.id, 'agent');
      expect(r.authMethods.single.type, isNull);
      final c = r.capabilities;
      expect(c.loadSession, isTrue);
      expect(c.image, isTrue);
      expect(c.embeddedContext, isTrue);
      expect(c.audio, isFalse);
      expect(c.mcpHttp && c.mcpSse, isTrue);
      expect([c.canList, c.canResume, c.canClose, c.canFork], everyElement(isTrue), reason: '`{}` means supported');
      expect(c.canDelete, isFalse, reason: 'absent means not supported');
    });

    test('a null or missing capability object is unsupported, not an error', () {
      final c = AcpAgentCapabilities.parse({
        'sessionCapabilities': {'list': null, 'resume': {}},
      });
      expect(c.canList, isFalse);
      expect(c.canResume, isTrue);
      expect(AcpAgentCapabilities.parse(null).loadSession, isFalse);
    });

    test('junk becomes version 0 so the client refuses it', () {
      for (final junk in <Object?>['x', null, 5, <Object?>[], {'protocolVersion': 'one'}]) {
        expect(AcpInitializeResult.parse(junk).protocolVersion, 0, reason: '$junk');
      }
    });

    test('unknown capability fields are kept in raw', () {
      final r = AcpInitializeResult.parse({
        'protocolVersion': 1,
        'agentCapabilities': {'futureThing': {'a': 1}},
        '_meta': {'x': 1},
      });
      expect(r.capabilities.raw['futureThing'], {'a': 1});
      expect(r.raw['_meta'], {'x': 1});
    });

    test('the client capabilities offer no fs and no terminal, form elicitation and boolean options', () {
      expect(const AcpClientCapabilities().toJson(), {
        'fs': {'readTextFile': false, 'writeTextFile': false},
        'terminal': false,
        'elicitation': {'form': <String, Object?>{}},
        'session': {
          'configOptions': {'boolean': <String, Object?>{}},
        },
      });
      expect(const AcpClientCapabilities(elicitationForm: false).toJson().containsKey('elicitation'), isFalse);
      expect(const AcpClientCapabilities(booleanConfigOptions: false).toJson().containsKey('session'), isFalse);
    });
  });

  group('session setup and lists', () {
    test("reads omp's session/new: select options, modes, 781 models", () {
      final json = ompSessionNew();
      final models = json['configOptions']! as List;
      (models[1]! as Map)['options'] = [
        for (var i = 0; i < 781; i++) {'value': 'p/m$i', 'name': 'Model $i'},
      ];
      final s = AcpSessionSetup.parse(json);
      expect(s.sessionId, '0199d3f2-7c1e-7a55-9d36-1c2b3a4d5e6f');
      expect(s.configOptions.map((o) => o.id), ['mode', 'model']);
      final model = s.configOptions[1] as SelectConfigOption;
      expect(model.category, 'model');
      expect(model.choices, hasLength(781));
      expect(model.value, 'anthropic/claude-sonnet-5-5');
      expect(model.currentName, 'anthropic/claude-sonnet-5-5', reason: 'not among the choices: the value itself');
      expect(s.modes!.availableModes.map((m) => m.id), ['default', 'plan']);
    });

    test('grouped options are flattened with their group name; booleans and unknown types survive', () {
      final options = parseConfigOptions([
        {
          'id': 'model',
          'name': 'Model',
          'type': 'select',
          'currentValue': 'b',
          'options': [
            {
              'group': 'g1',
              'name': 'Fast',
              'options': [
                {'value': 'a', 'name': 'A'},
              ],
            },
            {
              'group': 'g2',
              'name': 'Smart',
              'options': [
                {'value': 'b', 'name': 'B', 'description': 'best'},
              ],
            },
            {'value': 'c', 'name': 'C'},
            {'name': 'no value'},
            'junk',
          ],
        },
        {'id': 'think', 'name': 'Think', 'type': 'boolean', 'currentValue': true, '_meta': {'k': 'v'}},
        {'id': 'future', 'name': 'F', 'type': 'slider', 'currentValue': 3},
        {'name': 'no id', 'type': 'select'},
        'junk',
      ]);
      expect(options.map((o) => o.id), ['model', 'think', 'future']);
      final model = options[0] as SelectConfigOption;
      expect(model.choices.map((c) => (c.value, c.group)), [('a', 'Fast'), ('b', 'Smart'), ('c', null)]);
      expect(model.currentName, 'B');
      expect(model.choices[1].description, 'best');
      expect((options[1] as BooleanConfigOption).value, isTrue);
      expect(options[1].meta, {'k': 'v'});
      expect(options[2], isA<UnknownConfigOption>());
      expect(options[2].currentValue, 3);
    });

    test('withValue changes the value and ignores a value of the wrong type', () {
      final select = ConfigOption.parse({
        'id': 'm',
        'name': 'M',
        'type': 'select',
        'currentValue': 'a',
        'options': [
          {'value': 'a', 'name': 'A'},
          {'value': 'b', 'name': 'B'},
        ],
      })!;
      expect(select.withValue('b').currentValue, 'b');
      expect(select.withValue(true).currentValue, 'a');
      final toggle = ConfigOption.parse({'id': 't', 'name': 'T', 'type': 'boolean', 'currentValue': false})!;
      expect(toggle.withValue(true).currentValue, true);
      expect(toggle.withValue('x').currentValue, false);
    });

    test("reads omp's session/list, keeps _meta, drops rows without an id", () {
      final page = AcpSessionPage.parse({
        'sessions': [
          {
            'sessionId': 's1',
            'cwd': '/home/me/proj',
            'title': 'Fix login',
            'updatedAt': '2026-10-04T10:00:00.000Z',
            '_meta': {'messageCount': 12, 'size': 4096},
          },
          {'sessionId': 's2', 'cwd': '/tmp', 'updatedAt': 'not a date'},
          {'cwd': '/nowhere'},
          'junk',
        ],
        'nextCursor': 'c2',
      });
      expect(page.sessions.map((s) => s.sessionId), ['s1', 's2']);
      expect(page.sessions[0].meta, {'messageCount': 12, 'size': 4096});
      expect(page.sessions[0].updatedAt, DateTime.utc(2026, 10, 4, 10));
      expect(page.sessions[1].updatedAt, isNull, reason: 'an unreadable timestamp is not an error');
      expect(page.sessions[1].title, isNull);
      expect(page.nextCursor, 'c2');
    });

    test('commands: skill entries, hints, nameless rows dropped', () {
      final commands = parseCommands([
        {'name': 'compact', 'description': 'Compact the context', 'input': {'hint': 'what to keep'}},
        {'name': 'skill:review', 'description': 'Review code'},
        {'name': '', 'description': 'empty'},
        {'description': 'no name'},
      ]);
      expect(commands.map((c) => c.name), ['compact', 'skill:review']);
      expect(commands[0].inputHint, 'what to keep');
      expect(commands[1].inputHint, isNull);
    });

    test('prompt results: unknown stop reasons are kept as text', () {
      expect(PromptResult.parse({'stopReason': 'end_turn'}).stopReason, StopReason.endTurn);
      expect(PromptResult.parse({'stopReason': 'cancelled'}).stopReason, StopReason.cancelled);
      final odd = PromptResult.parse({'stopReason': 'future_reason'});
      expect(odd.stopReason, StopReason.unknown);
      expect(odd.rawStopReason, 'future_reason');
      expect(PromptResult.parse(null).stopReason, StopReason.unknown);
    });
  });

  group('content', () {
    test('every block kind survives a round trip', () {
      final blocks = <Json>[
        {'type': 'text', 'text': 'hi', '_meta': {'a': 1}},
        {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png', 'uri': 'file:///a.png'},
        {'type': 'audio', 'data': 'BBBB', 'mimeType': 'audio/wav'},
        {'type': 'resource_link', 'uri': 'file:///a.dart', 'name': 'a.dart', 'title': 'A', 'size': 10, 'mimeType': 'text/x-dart'},
        {
          'type': 'resource',
          'resource': {'uri': 'file:///a.txt', 'mimeType': 'text/plain', 'text': 'body'},
        },
        {
          'type': 'resource',
          'resource': {'uri': 'file:///a.bin', 'blob': 'CCCC'},
        },
      ];
      for (final b in blocks) {
        expect(ContentBlock.parse(b).toJson(), b);
      }
    });

    test('unknown and broken blocks are preserved or neutral, never fatal', () {
      final future = ContentBlock.parse({'type': 'hologram', 'depth': 3});
      expect(future, isA<UnknownBlock>().having((b) => b.type, 'type', 'hologram'));
      expect(future.toJson(), {'type': 'hologram', 'depth': 3});
      expect(ContentBlock.parse(null), isA<UnknownBlock>());
      expect(ContentBlock.parse({'type': 'text'}), isA<TextBlock>().having((b) => b.text, 'text', ''));
      expect(ContentBlock.parse({'type': 'resource'}), isA<UnknownBlock>());
    });

    test('tool content: content, diff, terminal, unknown', () {
      final c = [
        ToolContent.parse({'type': 'content', 'content': {'type': 'text', 'text': 'out'}}),
        ToolContent.parse({'type': 'diff', 'path': '/a', 'newText': 'n'}),
        ToolContent.parse({'type': 'diff', 'path': '/b', 'oldText': 'o', 'newText': 'n'}),
        ToolContent.parse({'type': 'terminal', 'terminalId': 'term-1'}),
        ToolContent.parse({'type': 'hologram'}),
      ];
      expect(((c[0] as ToolContentBlock).block as TextBlock).text, 'out');
      expect((c[1] as ToolDiff).oldText, isNull, reason: 'a new file');
      expect((c[2] as ToolDiff).oldText, 'o');
      expect((c[3] as ToolTerminal).terminalId, 'term-1');
      expect(c[4], isA<UnknownToolContent>());
      expect(c[1].toJson(), {'type': 'diff', 'path': '/a', 'newText': 'n'});
    });
  });

  group('permission requests', () {
    final json = {
      'sessionId': 's1',
      'toolCall': {
        'toolCallId': 'call-1',
        'title': 'Run `rm -rf build`',
        'kind': 'execute',
        'rawInput': {'command': 'rm -rf build'},
      },
      'options': [
        {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
        {'optionId': 'always', 'name': 'Always allow', 'kind': 'allow_always'},
        {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'},
        {'optionId': 'never', 'name': 'Never', 'kind': 'reject_always'},
        {'optionId': 'weird', 'name': 'Weird', 'kind': 'maybe'},
        {'name': 'no id', 'kind': 'allow_once'},
      ],
    };

    test('reads the tool call and the four option kinds', () {
      final r = PermissionRequest.parse(json);
      expect(r.sessionId, 's1');
      expect(r.toolCall.toolCallId, 'call-1');
      expect(r.toolCall.title, 'Run `rm -rf build`');
      expect(r.toolCall.kind, ToolKind.execute);
      expect(r.toolCall.rawInput, {'command': 'rm -rf build'});
      expect(r.options.map((o) => o.kind), [
        PermissionOptionKind.allowOnce,
        PermissionOptionKind.allowAlways,
        PermissionOptionKind.rejectOnce,
        PermissionOptionKind.rejectAlways,
        PermissionOptionKind.other,
      ]);
      expect(r.optionOfKind(PermissionOptionKind.rejectOnce)!.optionId, 'deny');
      expect(r.hasOption('always'), isTrue);
      expect(r.hasOption('nope'), isFalse);
    });

    test('an unknown kind is never an allow; standing grants are marked', () {
      expect(PermissionOptionKind.other.isAllow, isFalse);
      expect(PermissionOptionKind.allowOnce.isStanding, isFalse);
      expect(PermissionOptionKind.allowAlways.isStanding, isTrue);
      expect(PermissionOptionKind.rejectAlways.isStanding, isTrue);
      expect(PermissionRequest.parse(json).options.last.rawKind, 'maybe');
    });

    test('the v2 draft shape: title, description, a command subject', () {
      final r = PermissionRequest.parse({
        'sessionId': 's',
        'title': 'Run a command',
        'description': 'The agent wants to build',
        'subject': {'type': 'command', 'command': 'make', 'cwd': '/repo', 'toolCallId': 't9'},
        'options': [
          {'optionId': 'ok', 'name': 'OK', 'kind': 'allow_once'},
        ],
      });
      expect(r.title, 'Run a command');
      expect(r.command, 'make');
      expect(r.cwd, '/repo');
      final nested = PermissionRequest.parse({
        'sessionId': 's',
        'subject': {
          'type': 'tool_call',
          'toolCall': {'toolCallId': 'inner', 'title': 'T'},
        },
        'options': <Object>[],
      });
      expect(nested.toolCall.toolCallId, 'inner');
    });

    test('outcomes encode as the spec says', () {
      expect(const PermissionSelected('allow').toJson(), {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      expect(const PermissionCancelled().toJson(), {
        'outcome': {'outcome': 'cancelled'},
      });
    });
  });

  group('elicitation', () {
    test("reads omp's single-value forms: select, confirm, input", () {
      final select = ElicitationRequest.parse({
        'mode': 'form',
        'sessionId': 's',
        'message': 'Pick one',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'value': {'type': 'string', 'enum': ['red', 'green']},
          },
          'required': ['value'],
        },
      });
      final field = select.schema!.fields.single as EnumField;
      expect(field.name, 'value');
      expect(field.required, isTrue);
      expect(field.options.map((o) => (o.value, o.title)), [('red', 'red'), ('green', 'green')]);

      final confirm = ElicitationRequest.parse({
        'mode': 'form',
        'message': 'Proceed?',
        'requestedSchema': {
          'type': 'object',
          'properties': {'value': {'type': 'boolean'}},
        },
      });
      expect(confirm.schema!.fields.single, isA<BooleanField>().having((f) => f.required, 'required', isFalse));
      expect(confirm.sessionId, isNull);

      final input = ElicitationRequest.parse({
        'mode': 'form',
        'message': 'Name?',
        'requestedSchema': {
          'type': 'object',
          'properties': {'value': {'type': 'string', 'description': 'placeholder'}},
        },
      });
      expect((input.schema!.fields.single as StringField).description, 'placeholder');
    });

    final schema = ElicitationSchema.parse({
      'type': 'object',
      'title': 'Setup',
      'properties': {
        'name': {'type': 'string', 'title': 'Name', 'minLength': 2, 'maxLength': 5, 'pattern': r'^[a-z]+$'},
        'age': {'type': 'integer', 'minimum': 1, 'maximum': 120, 'default': 30},
        'ratio': {'type': 'number', 'minimum': 0, 'maximum': 1},
        'ok': {'type': 'boolean', 'default': true},
        'color': {
          'type': 'string',
          'oneOf': [
            {'const': 'r', 'title': 'Red'},
            {'const': 'g', 'title': 'Green'},
          ],
          'default': 'g',
        },
        'tags': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 2,
          'items': {'type': 'string', 'enum': ['a', 'b', 'c']},
          'default': ['a'],
        },
        'titled': {
          'type': 'array',
          'items': {
            'anyOf': [
              {'const': 'x', 'title': 'Ex'},
            ],
          },
        },
        'when': {'type': 'hologram', 'weird': true},
      },
      'required': ['name', 'color'],
    });

    test('a flat schema: every field type, in order, with defaults and titles', () {
      expect(schema.fields.map((f) => f.name), ['name', 'age', 'ratio', 'ok', 'color', 'tags', 'titled', 'when']);
      expect(schema.fields[0].label, 'Name');
      expect(schema.fields[1].label, 'age', reason: 'no title: the key');
      expect((schema.fields[1] as NumberField).integer, isTrue);
      expect((schema.fields[1] as NumberField).defaultValue, 30);
      expect((schema.fields[3] as BooleanField).defaultValue, isTrue);
      final color = schema.fields[4] as EnumField;
      expect(color.options.map((o) => o.title), ['Red', 'Green']);
      expect(color.defaultValue, 'g');
      final tags = schema.fields[5] as MultiEnumField;
      expect(tags.options.map((o) => o.value), ['a', 'b', 'c']);
      expect(tags.defaultValues, ['a']);
      expect((schema.fields[6] as MultiEnumField).options.single.title, 'Ex');
      final odd = schema.fields[7] as UnknownField;
      expect(odd.type, 'hologram');
      expect(odd.raw['weird'], isTrue);
      expect(schema.fields.where((f) => f.required).map((f) => f.name), ['name', 'color']);
    });

    test('validation: required, bounds, patterns, enum membership, multi-select counts', () {
      expect(schema.validate({'name': 'abc', 'color': 'r'}), isEmpty);
      expect(schema.validate({}), {'name': 'required', 'color': 'required'});
      expect(schema.validate({'name': '', 'color': ''}).keys, ['name', 'color']);
      expect(schema.validate({'name': 'a', 'color': 'r'})['name'], contains('at least 2'));
      expect(schema.validate({'name': 'abcdef', 'color': 'r'})['name'], contains('at most 5'));
      expect(schema.validate({'name': 'ABC', 'color': 'r'})['name'], contains('pattern'));
      expect(schema.validate({'name': 'abc', 'color': 'blue'})['color'], isNotNull);
      expect(schema.validate({'name': 'abc', 'color': 'r', 'age': 0})['age'], contains('at least 1'));
      expect(schema.validate({'name': 'abc', 'color': 'r', 'age': 1.5})['age'], contains('whole'));
      expect(schema.validate({'name': 'abc', 'color': 'r', 'age': '3'})['age'], contains('number'));
      expect(schema.validate({'name': 'abc', 'color': 'r', 'ratio': 1.5})['ratio'], contains('at most'));
      expect(schema.validate({'name': 'abc', 'color': 'r', 'ratio': 0.5, 'ok': 'yes'})['ok'], isNotNull);
      expect(schema.validate({'name': 'abc', 'color': 'r', 'tags': ['a', 'b', 'c']})['tags'], contains('at most 2'));
      expect(schema.validate({'name': 'abc', 'color': 'r', 'tags': ['z']})['tags'], isNotNull);
      expect(schema.validate({'name': 'abc', 'color': 'r', 'tags': <String>[]}), isEmpty, reason: 'optional and empty');
      expect(schema.validate({'name': 'abc', 'color': 'r', 'when': 'whatever'}), isEmpty, reason: 'unknown fields are left to the agent');
    });

    test('a pattern the engine cannot read does not fail the answer', () {
      final s = ElicitationSchema.parse({
        'properties': {'x': {'type': 'string', 'pattern': '(['}},
      });
      expect(s.validate({'x': 'a'}), isEmpty);
    });

    test('responses encode as the spec says', () {
      expect(const ElicitationAccept({'value': 'red', 'tags': ['a']}).toJson(), {
        'action': 'accept',
        'content': {'value': 'red', 'tags': ['a']},
      });
      expect(const ElicitationDecline().toJson(), {'action': 'decline'});
      expect(const ElicitationCancel().toJson(), {'action': 'cancel'});
    });

    test('the request keeps what it does not model; non-form modes carry no schema', () {
      final url = ElicitationRequest.parse({
        'mode': 'url',
        'message': 'Sign in',
        'url': 'https://example.com/auth',
        'elicitationId': 'e1',
        'requestId': 12,
      });
      expect(url.mode, 'url');
      expect(url.schema, isNull);
      expect(url.url, 'https://example.com/auth');
      expect(url.raw['requestId'], 12);
    });

    test('a schema with junk properties and bad numbers does not throw', () {
      final s = ElicitationSchema.parse({
        'properties': {
          'a': 'junk',
          'b': {'type': 'number', 'minimum': 'low', 'default': 'x'},
          'c': {'type': 'array', 'items': 'junk'},
        },
        'required': [1, 'b'],
      });
      expect(s.fields.map((f) => f.name), ['b', 'c']);
      expect((s.fields[0] as NumberField).minimum, isNull);
      expect(s.fields[0].required, isTrue);
    });
  });

  group('session updates parse', () {
    test('a tool call update keeps exactly the keys it named', () {
      final u = SessionUpdate.parse({'sessionUpdate': 'tool_call_update', 'toolCallId': 'x', 'title': null}) as ToolCallPatchUpdate;
      expect(u.patch.has('title'), isTrue);
      expect(u.patch.has('status'), isFalse);
    });

    test('config option updates and v2 plan updates', () {
      final cfg = SessionUpdate.parse({
        'sessionUpdate': 'config_option_update',
        'configOptions': [
          {'id': 'a', 'name': 'A', 'type': 'boolean', 'currentValue': true},
        ],
      }) as ConfigUpdate;
      expect(cfg.options.single.id, 'a');
      final plan = SessionUpdate.parse({
        'sessionUpdate': 'plan_update',
        'plan': {
          'type': 'items',
          'planId': 'p',
          'entries': [
            {'content': 'x', 'priority': 'high', 'status': 'completed'},
          ],
        },
      }) as PlanUpdate;
      expect(plan.entries.single.status, PlanStatus.completed);
      expect(SessionUpdate.parse({'sessionUpdate': 'plan_update', 'plan': {'type': 'markdown'}}), isA<UnknownUpdate>());
    });
  });
}
