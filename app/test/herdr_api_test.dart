import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';

void main() {
  // Regression: `pane.agent_status_changed` was added to the subscription
  // list, but the schema requires a `pane_id` for it. herdr rejects the WHOLE
  // subscription, the event channel died, and every machine reconnected in a
  // loop once a second. Fake transports cannot catch that, the schema can.
  test('every change subscription is valid without parameters per the schema', () {
    final schema = jsonDecode(File('../docs/herdr-api.schema.json').readAsStringSync())
        as Map<String, dynamic>;
    final oneOf = (((schema['schemas'] as Map)['request'] as Map)['\$defs']
        as Map)['Subscription']['oneOf'] as List;
    final byType = {
      for (final entry in oneOf.cast<Map<String, dynamic>>())
        ((entry['properties'] as Map)['type'] as Map)['const'] as String: entry,
    };

    final transport = FakeTransport();
    HerdrApi(transport).changes().listen((_) {});
    final subscriptions = transport.subscribed.single;

    expect(subscriptions, isNotEmpty);
    for (final subscription in subscriptions) {
      final type = subscription['type'] as String;
      final entry = byType[type];
      expect(entry, isNotNull, reason: '$type is not a subscription type');
      expect(entry!['required'], ['type'],
          reason: '$type needs parameters herdr will reject us without');
      expect(subscription.keys, ['type']);
    }
  });

  // The background profile names panes: the one place a `pane_id` goes.
  test('the status-only subscription is valid per the schema: a pane id on every status entry', () {
    final schema = jsonDecode(File('../docs/herdr-api.schema.json').readAsStringSync())
        as Map<String, dynamic>;
    final oneOf = (((schema['schemas'] as Map)['request'] as Map)['\$defs']
        as Map)['Subscription']['oneOf'] as List;
    final byType = {
      for (final entry in oneOf.cast<Map<String, dynamic>>())
        ((entry['properties'] as Map)['type'] as Map)['const'] as String: entry,
    };

    final transport = FakeTransport();
    HerdrApi(transport).changes(statusPanes: ['w1:p1', 'w2:p3']).listen((_) {});
    final subscriptions = transport.subscribed.single;

    expect([for (final s in subscriptions) s['type']], isNot(contains('pane.updated')));
    expect(
      [for (final s in subscriptions) if (s['type'] == 'pane.agent_status_changed') s['pane_id']],
      ['w1:p1', 'w2:p3'],
    );
    for (final subscription in subscriptions) {
      final type = subscription['type'] as String;
      final entry = byType[type];
      expect(entry, isNotNull, reason: '$type is not a subscription type');
      expect(subscription.keys.toSet(), (entry!['required'] as List).cast<String>().toSet(),
          reason: '$type: exactly the parameters the schema requires');
    }

    HerdrApi(transport).changes(statusPanes: const []).listen((_) {});
    expect(transport.subscribed.last, isNotEmpty, reason: 'no agent panes: structure alone');
  });
}
