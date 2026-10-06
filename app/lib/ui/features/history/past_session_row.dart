import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/past_session.dart';
import '../../core/controls.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';
import '../agent_session/visible_text.dart';
import '../files/file_format.dart' show formatModified;

/// `Untitled session`, or the agent's title.
String pastSessionTitle(PastSession s) {
  final title = s.title;
  return title == null ? 'Untitled session' : visibleText(title);
}

/// `No messages`, `1 message`, `14 messages`, `12,480 messages`; empty when the
/// agent does not say.
String messageCountLabel(int? count) => switch (count) {
  null => '',
  <= 0 => 'No messages',
  1 => '1 message',
  final n => '${_grouped(n)} messages',
};

String _grouped(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

/// `2 h ago · 14 messages`: when it last changed and how long it is, whichever
/// the agent reports.
String pastSessionDetail(PastSession s, DateTime now) =>
    [formatModified(s.updatedAt, now: now), messageCountLabel(s.messageCount)].where((p) => p.isNotEmpty).join(' · ');

/// One session an agent remembers: its title, the folder it ran in, when it
/// last changed. The whole row is the tap target.
///
/// [open] means a keeper on this machine holds it already: the row says
/// `Open` and [onTap] shows that session. [busy] means it is being reopened:
/// a spinner, and no taps. A null [onTap] is a row that cannot be reopened.
class PastSessionRow extends StatelessWidget {
  const PastSessionRow({
    super.key,
    required this.session,
    required this.now,
    required this.onTap,
    this.open = false,
    this.busy = false,
  });

  final PastSession session;

  /// What "2 h ago" counts from.
  final DateTime now;
  final VoidCallback? onTap;
  final bool open;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final folder = visibleText(cwdTail(session.cwd));
    final detail = pastSessionDetail(session, now);
    return ListRow(
      title: pastSessionTitle(session),
      subtitle: folder.isEmpty ? null : folder,
      subtitle2: detail.isEmpty ? null : detail,
      onTap: busy ? null : onTap,
      trailing: busy
          ? const BusySpinner(size: 18)
          : open
          ? Text('Open', style: Type.label.copyWith(color: ds.accentText, fontWeight: FontWeight.w600))
          : onTap == null
          ? null
          : Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
    );
  }
}
