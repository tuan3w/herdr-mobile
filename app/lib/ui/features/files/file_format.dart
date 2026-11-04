import 'package:herdr_mobile/l10n/app_localizations.dart';

/// "0 B", "1.5 KB", "12 MB": binary units, one decimal under 10, none above.
/// A size the host did not give says so in the phone's language when [l10n] is
/// passed; the number and the unit are the same everywhere.
String formatBytes(int? bytes, {AppLocalizations? l10n}) {
  if (bytes == null || bytes < 0) return l10n?.uiUnknownSize ?? 'Unknown size';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value < 10 ? value.toStringAsFixed(1) : value.round().toString();
  return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} ${units[unit]}';
}

/// `rwxr-xr-x` for the low nine mode bits; empty when unknown.
String formatPermissions(int? mode) {
  if (mode == null) return '';
  const flags = 'rwxrwxrwx';
  final out = StringBuffer();
  for (var i = 0; i < 9; i++) {
    out.write(mode & (1 << (8 - i)) != 0 ? flags[i] : '-');
  }
  return out.toString();
}

/// 1234567 -> "1,234,567".
String groupDigits(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
