import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';

class _CapturingTransport extends FakeTransport {
  List<Map<String, dynamic>>? subscribed;

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) {
    subscribed = subscriptions;
    return super.events(subscriptions);
  }
}

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

    final transport = _CapturingTransport();
    HerdrApi(transport).changes().listen((_) {});
    final subscriptions = transport.subscribed!;

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
}
