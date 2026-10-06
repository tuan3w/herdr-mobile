import 'dart:async';

import 'fake_transport.dart';

/// [FakeTransport] that can hold `session.snapshot` requests open and counts
/// event streams that are currently being listened to.
class TestTransport extends FakeTransport {
  TestTransport([super.snapshot]);

  /// While set, snapshot requests wait for it before being served.
  Completer<void>? gate;

  /// Snapshot requests issued, including ones still held by [gate].
  int snapshotStarted = 0;

  /// Event streams with an active listener.
  int liveEventStreams = 0;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'session.snapshot') {
      snapshotStarted++;
      await gate?.future;
    }
    return super.request(method, params);
  }

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) {
    final inner = super.events(subscriptions);
    StreamSubscription<Map<String, dynamic>>? sub;
    late final StreamController<Map<String, dynamic>> out;
    out = StreamController<Map<String, dynamic>>(
      onListen: () {
        liveEventStreams++;
        sub = inner.listen(out.add, onError: out.addError, onDone: out.close);
      },
      onCancel: () {
        liveEventStreams--;
        return sub?.cancel();
      },
    );
    return out.stream;
  }
}
