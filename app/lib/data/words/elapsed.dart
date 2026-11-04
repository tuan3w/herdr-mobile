import 'package:herdr_mobile/l10n/app_localizations.dart';

/// The app's two registers for a length of time, and its two for a moment.
/// Every duration, "ago" and date the person reads comes from here, so a
/// minute is spelled one way everywhere.
abstract final class Elapsed {
  /// `12s`, `4m`, `1h`, `1h 05m`, `3d`: for labels that sit beside a name.
  /// With [seconds] false, anything under a minute is `<1m`, so a label that
  /// ticks changes at most once a minute. With [l10n], the units follow the
  /// person's language (`59分`, `1時間5分`, `3日`); without it they stay English.
  static String compact(Duration d, {bool seconds = true, AppLocalizations? l10n}) {
    if (d.isNegative) d = Duration.zero;
    if (d.inMinutes < 1) {
      if (!seconds) return l10n?.elapsedUnderAMinute ?? '<1m';
      return l10n?.elapsedSeconds(d.inSeconds) ?? '${d.inSeconds}s';
    }
    if (d.inHours < 1) return l10n?.elapsedMinutes(d.inMinutes) ?? '${d.inMinutes}m';
    if (d.inDays < 1) {
      final m = d.inMinutes % 60;
      if (l10n != null) {
        return m == 0 ? l10n.elapsedHours(d.inHours) : l10n.elapsedHoursMinutes(d.inHours, '$m', _two(m));
      }
      return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${_two(m)}m';
    }
    return l10n?.elapsedDays(d.inDays) ?? '${d.inDays}d';
  }

  /// `12 seconds`, `1 minute`, `1 hour 5 minutes`, `3 days`: inside a
  /// sentence.
  static String words(Duration d) {
    if (d.isNegative) d = Duration.zero;
    String unit(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';
    if (d.inMinutes < 1) return unit(d.inSeconds, 'second');
    if (d.inHours < 1) return unit(d.inMinutes, 'minute');
    if (d.inDays < 1) {
      final m = d.inMinutes % 60;
      return m == 0 ? unit(d.inHours, 'hour') : '${unit(d.inHours, 'hour')} ${unit(m, 'minute')}';
    }
    return unit(d.inDays, 'day');
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

String _date(DateTime t, DateTime now) =>
    t.year == now.year ? '${t.day} ${_months[t.month - 1]}' : '${t.day} ${_months[t.month - 1]} ${t.year}';

/// Whole calendar days from [t] to [now], both local. Counted on UTC dates so
/// a 23 h or 25 h day around a clock change still counts as one.
int _daysBefore(DateTime t, DateTime now) =>
    DateTime.utc(now.year, now.month, now.day).difference(DateTime.utc(t.year, t.month, t.day)).inDays;

/// How long ago [time] was: `Just now`, `4m ago`, `3h ago`, `Yesterday`,
/// `4d ago`, then the date (`3 Oct`, with the year once it is not this year).
/// Local time. A moment in the future reads `Just now`.
String formatAgo(DateTime time, DateTime now) {
  final t = time.toLocal();
  final current = now.toLocal();
  final diff = current.difference(t);
  if (diff.isNegative || diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  final days = _daysBefore(t, current);
  if (days == 0) return '${diff.inHours}h ago';
  if (days == 1) return 'Yesterday';
  if (days < 7) return '${days}d ago';
  return _date(t, current);
}

/// The moment itself: `Today 14:02`, `Yesterday 14:02`, `3 Oct, 14:02`,
/// `3 Oct 2025, 14:02`. With [sentence], the words that follow a verb:
/// `today at 14:02`, `yesterday at 14:02`, `on 3 Oct at 14:02`.
String formatWhen(DateTime time, DateTime now, {bool sentence = false}) {
  final t = time.toLocal();
  final current = now.toLocal();
  final days = _daysBefore(t, current);
  final clock = _clock(t);
  if (sentence) {
    if (days <= 0) return 'today at $clock';
    if (days == 1) return 'yesterday at $clock';
    return 'on ${_date(t, current)} at $clock';
  }
  if (days <= 0) return 'Today $clock';
  if (days == 1) return 'Yesterday $clock';
  return '${_date(t, current)}, $clock';
}
