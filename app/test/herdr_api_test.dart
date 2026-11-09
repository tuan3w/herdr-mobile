import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_transport.dart';

void main() {
  // Regression: `pane.agent_status_changed` was added to the subscription
  // list, but the schema requires a `pane_id` for it. herdr rejects the WHOLE
  // subscription, the event channel died, and every machine reconnected in a
  // loop once a second. Fake transports cannot catch that, the schema can.
  test('every change subscription is valid without parameters per the schema', () {
    final schema = jsonDecode(File('../docs/herdr-api.schema.json').readAsStringSync()) as Map<String, dynamic>;
    final oneOf = (((schema['schemas'] as Map)['request'] as Map)['\$defs'] as Map)['Subscription']['oneOf'] as List;
    final byType = {
      for (final entry in oneOf.cast<Map<String, dynamic>>())
        ((entry['properties'] as Map)['type'] as Map)['const'] as String: entry,
    };

    final transport = FakeTransport();
    HerdrApi(transport).changes().listen((_) {});
    final subscriptions = transport.subscribed.single;

    expect(subscriptions, isNotEmpty);
    // Token text on the board follows the watcher while the app is in front.
    expect([for (final s in subscriptions) s['type']], contains('workspace.metadata_updated'));
    for (final subscription in subscriptions) {
      final type = subscription['type'] as String;
      final entry = byType[type];
      expect(entry, isNotNull, reason: '$type is not a subscription type');
      expect(entry!['required'], ['type'], reason: '$type needs parameters herdr will reject us without');
      expect(subscription.keys, ['type']);
    }
  });

  // The background profile names panes: the one place a `pane_id` goes.
  test('the status-only subscription is valid per the schema: a pane id on every status entry', () {
    final schema = jsonDecode(File('../docs/herdr-api.schema.json').readAsStringSync()) as Map<String, dynamic>;
    final oneOf = (((schema['schemas'] as Map)['request'] as Map)['\$defs'] as Map)['Subscription']['oneOf'] as List;
    final byType = {
      for (final entry in oneOf.cast<Map<String, dynamic>>())
        ((entry['properties'] as Map)['type'] as Map)['const'] as String: entry,
    };

    final transport = FakeTransport();
    HerdrApi(transport).changes(statusPanes: ['w1:p1', 'w2:p3']).listen((_) {});
    final subscriptions = transport.subscribed.single;

    // Neither churn wakes the radio in the background.
    expect([for (final s in subscriptions) s['type']], isNot(contains('pane.updated')));
    expect([for (final s in subscriptions) s['type']], isNot(contains('workspace.metadata_updated')));
    expect(
      [
        for (final s in subscriptions)
          if (s['type'] == 'pane.agent_status_changed') s['pane_id'],
      ],
      ['w1:p1', 'w2:p3'],
    );
    for (final subscription in subscriptions) {
      final type = subscription['type'] as String;
      final entry = byType[type];
      expect(entry, isNotNull, reason: '$type is not a subscription type');
      expect(
        subscription.keys.toSet(),
        (entry!['required'] as List).cast<String>().toSet(),
        reason: '$type: exactly the parameters the schema requires',
      );
    }

    HerdrApi(transport).changes(statusPanes: const []).listen((_) {});
    expect(transport.subscribed.last, isNotEmpty, reason: 'no agent panes: structure alone');
  });

  group('a message to an agent', () {
    test('goes through agent.prompt, so herdr checks the agent is at its prompt', () async {
      final transport = FakeTransport();
      await HerdrApi(transport).prompt('w1:p1', 'go on');
      expect(transport.calls.single.$1, 'agent.prompt');
      expect(transport.calls.single.$2, {'target': 'w1:p1', 'text': 'go on'});
    });

    test('a herdr without agent.prompt gets the line typed, as before', () async {
      final transport = _NoAgentPrompt();
      await HerdrApi(transport).prompt('w1:p1', 'go on');
      expect([for (final c in transport.calls) c.$1], ['agent.prompt', 'pane.send_input']);
      expect(transport.calls.last.$2, {
        'pane_id': 'w1:p1',
        'text': 'go on',
        'keys': ['enter'],
      });
    });

    test('a refusal reaches the caller', () async {
      final transport = FakeTransport()
        ..failure = const HerdrApiException('agent_blocked', 'agent w1:p1 is blocked and requires interactive input');
      await expectLater(
        HerdrApi(transport).prompt('w1:p1', 'go on'),
        throwsA(isA<HerdrApiException>().having((e) => e.code, 'code', 'agent_blocked')),
      );
      expect([for (final c in transport.calls) c.$1], ['agent.prompt'], reason: 'nothing typed after a refusal');
    });
  });
}

/// A herdr that predates `agent.prompt`.
class _NoAgentPrompt extends FakeTransport {
  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) {
    if (method == 'agent.prompt') {
      calls.add((method, params));
      throw const HerdrApiException('invalid_request', 'unknown variant `agent.prompt`, expected one of `ping`');
    }
    return super.request(method, params);
  }
}
