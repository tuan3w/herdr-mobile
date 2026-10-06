/// When a saved copy of a transcript was right, in words for the link strip:
/// `at 14:02` for today, `yesterday at 14:02`, else `on 3 Oct at 14:02`.
String savedCopyLabel(DateTime asOf, DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  final at = asOf.toLocal();
  final today = now.toLocal();
  final clock = '${two(at.hour)}:${two(at.minute)}';
  final days = DateTime(today.year, today.month, today.day).difference(DateTime(at.year, at.month, at.day)).inDays;
  if (days <= 0) return 'at $clock';
  if (days == 1) return 'yesterday at $clock';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return 'on ${at.day} ${months[at.month - 1]} at $clock';
}

/// The link strip's note over a saved copy, in every state but live:
/// `Showing the copy saved at 14:02. Nothing here can be answered.` A copy is
/// never live and answers nothing (requests come only with a live attach).
String savedCopyNotice(DateTime asOf, DateTime now) =>
    'Showing the copy saved ${savedCopyLabel(asOf, now)}. Nothing here can be answered.';
