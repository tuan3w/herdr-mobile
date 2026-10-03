/// "0 B", "1.5 KB", "12 MB": binary units, one decimal under 10, none above.
String formatBytes(int? bytes) {
  if (bytes == null || bytes < 0) return 'Unknown size';
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

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// How long ago [time] was, the way a file manager says it: "Just now",
/// "5 min ago", "3 h ago", "Yesterday", "4 d ago", then a date ("May 20", and
/// the year once it is not this year). Local time.
String formatModified(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final current = (now ?? DateTime.now()).toLocal();
  final t = time.toLocal();
  final diff = current.difference(t);
  if (diff.isNegative || diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24 && current.day == t.day) return '${diff.inHours} h ago';
  final today = DateTime(current.year, current.month, current.day);
  final that = DateTime(t.year, t.month, t.day);
  final days = today.difference(that).inDays;
  if (days == 1) return 'Yesterday';
  if (days < 7) return '$days d ago';
  final date = '${_months[t.month - 1]} ${t.day}';
  return t.year == current.year ? date : '$date, ${t.year}';
}

/// "May 20, 2026 at 09:30", for the info card where the exact moment matters.
String formatExactTime(DateTime? time) {
  if (time == null) return '';
  final t = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_months[t.month - 1]} ${t.day}, ${t.year} at ${two(t.hour)}:${two(t.minute)}';
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
