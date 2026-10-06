// Background timers of several machines land on one shared clock grid, so the
// radio wakes once for all of them.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/aligned_ticker.dart';

void main() {
  const period = Duration(minutes: 4);
  final start = DateTime.utc(2026, 3, 1, 12, 1, 17);

  test('tickers started at different moments tick at the same instants', () {
    fakeAsync((async) {
      final ticks = <(String, Duration)>[];
      DateTime clock() => start.add(async.elapsed);
      AlignedTicker(period, clock, () => ticks.add(('a', async.elapsed)));
      async.elapse(const Duration(seconds: 50));
      AlignedTicker(period, clock, () => ticks.add(('b', async.elapsed)));
      async.elapse(const Duration(minutes: 9));

      final a = [for (final t in ticks) if (t.$1 == 'a') t.$2];
      final b = [for (final t in ticks) if (t.$1 == 'b') t.$2];
      expect(a, b);
      expect(a.length, 2);
      expect(a[1] - a[0], period);
    });
  });

  test('a start exactly on the grid waits a whole period, and cancel stops it', () {
    fakeAsync((async) {
      var n = 0;
      final t = AlignedTicker(period, () => DateTime.utc(2026, 3, 1, 12).add(async.elapsed), () => n++);
      async.elapse(period - const Duration(seconds: 1));
      expect(n, 0);
      async.elapse(const Duration(seconds: 1));
      expect(n, 1);
      t.cancel();
      async.elapse(period * 3);
      expect(n, 1);
    });
  });
}
