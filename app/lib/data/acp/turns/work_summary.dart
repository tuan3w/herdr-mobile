import 'turn.dart';

/// The parts of the fold line of a turn, from data the app has (counts, times,
/// exit codes, diff stats), never from words a model wrote:
///
/// `Worked 42s` · `3 files` · `4 commands` · `1 failed` · `1 cancelled`
///
/// A part that is zero is left out. `Worked` carries the duration only when
/// it is a real measurement ([Turn.duration]: not for a replayed history) and
/// at least a second. Plain strings, safe for any script: nothing here cuts or
/// indexes text.
List<String> workSummaryParts(Turn turn) {
  final d = turn.duration;
  return [
    d == null || d < const Duration(seconds: 1) ? 'Worked' : 'Worked ${formatDuration(d)}',
    ?_count(turn.changed.length, 'file', 'files'),
    ?_count(turn.commands.length, 'command', 'commands'),
    if (turn.failedCount > 0) '${turn.failedCount} failed',
    if (turn.cancelledCount > 0) '${turn.cancelledCount} cancelled',
  ];
}

/// [workSummaryParts] joined with ` · `.
String workSummaryLine(Turn turn) => workSummaryParts(turn).join(' \u00b7 ');

String? _count(int n, String one, String many) => n == 0 ? null : '$n ${n == 1 ? one : many}';

/// `42s`, `3m`, `3m 5s`, `1h`, `1h 5m`: whole seconds, the two largest units.
/// Under a second it is `0s`.
String formatDuration(Duration d) {
  final total = (d.inMilliseconds / 1000).round();
  final s = total < 0 ? 0 : total;
  if (s < 60) return '${s}s';
  if (s < 3600) {
    final m = s ~/ 60, r = s % 60;
    return r == 0 ? '${m}m' : '${m}m ${r}s';
  }
  final h = s ~/ 3600, m = (s % 3600) ~/ 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
