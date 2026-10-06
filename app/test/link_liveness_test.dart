import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/link_liveness.dart';

void main() {
  late Duration now;
  late LinkLiveness live;

  void advance(int seconds) => now += Duration(seconds: seconds);

  setUp(() {
    now = Duration.zero;
    live = LinkLiveness(
      interval: const Duration(seconds: 25),
      timeout: const Duration(seconds: 10),
      clock: () => now,
    );
  });

  test('a link that has been quiet for the interval is due for a ping', () {
    expect(live.untilPing(), const Duration(seconds: 25));

    advance(24);
    expect(live.untilPing(), const Duration(seconds: 1));

    advance(1);
    expect(live.untilPing(), Duration.zero);
    advance(60);
    expect(live.untilPing(), Duration.zero, reason: 'never negative');
  });

  test('inbound bytes push the ping back: a busy link is never pinged', () {
    for (var i = 0; i < 10; i++) {
      advance(20);
      live.inbound();
      expect(live.untilPing(), const Duration(seconds: 25));
    }
  });

  test('a ping that is not answered kills the link only after the timeout', () {
    advance(25);
    live.pingSent();
    expect(live.pinging, isTrue);

    advance(9);
    expect(live.untilVerdict(), const Duration(seconds: 1));
    advance(1);
    expect(live.untilVerdict(), Duration.zero, reason: 'silent for the whole timeout');
  });

  test('a slow reply queued behind a long replay does not kill the link while bytes flow', () {
    advance(25);
    live.pingSent();

    // The host is sending the replay; the ping's reply is somewhere behind it.
    for (var i = 0; i < 30; i++) {
      advance(5);
      live.inbound();
      expect(live.untilVerdict(), isNot(Duration.zero),
          reason: 'bytes keep arriving, so the link is alive at ${i * 5}s');
    }

    // The replay stops dead and the reply never comes.
    advance(10);
    expect(live.untilVerdict(), Duration.zero);
  });

  test('the verdict counts from the ping, not from the last byte before it', () {
    // Last byte at 0; the ping goes out at 25 s. Judging by the last byte
    // would call the link dead at once.
    advance(25);
    live.pingSent();

    expect(live.untilVerdict(), const Duration(seconds: 10));
  });

  test('an answer clears the ping and restarts the interval', () {
    advance(25);
    live.pingSent();
    advance(2);
    live.pingAnswered();

    expect(live.pinging, isFalse);
    expect(live.untilPing(), const Duration(seconds: 25));
  });

  test('the default clock is monotonic and starts fresh', () {
    final real = LinkLiveness();

    expect(real.untilPing(), greaterThan(const Duration(seconds: 24)));
    real.inbound();
    expect(real.untilPing(), greaterThan(const Duration(seconds: 24)));
  });
}
