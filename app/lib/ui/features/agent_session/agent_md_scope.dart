import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../data/repositories/agent_session.dart';
import '../../core/markdown/markdown.dart';
import '../../core/motion.dart';
import '../files/files_navigation.dart';
import '../pane/link_sheet.dart';
import 'photo_thread.dart';

/// What a tap in the Markdown of an agent session does:
///
///  * a link shows its whole address first (the link sheet; a label can say
///    anything), `http`/`https` only;
///  * a file path (`lib/a.dart`, `lib/a.dart:42`, a relative link target) opens
///    the file viewer at that line, on the session's machine, relative to the
///    session's folder. The host is asked only now, on the tap: never in bulk
///    while the text is drawn. An image path opens in the photo viewer.
///
/// It also says which pictures a tap on one in the transcript pages through
/// (`ThreadPhotos`).
///
/// Stateful so the handlers are the same objects for the life of the screen:
/// the Markdown below does not rebuild its spans each time this widget does.
class AgentMdScope extends StatefulWidget {
  const AgentMdScope({super.key, required this.session, required this.child});

  final AgentSessionView session;
  final Widget child;

  @override
  State<AgentMdScope> createState() => _AgentMdScopeState();
}

class _AgentMdScopeState extends State<AgentMdScope> {
  void _link(BuildContext context, String url) => unawaited(showLinkSheet(context, url));

  void _path(BuildContext context, String path, int? line) {
    Haptics.tick();
    final session = widget.session;
    unawaited(openRemoteFile(context, session.machine, path, cwd: session.cwd, line: line));
  }

  @override
  Widget build(BuildContext context) => ThreadPhotos(
    session: widget.session,
    child: MdActions(onLink: _link, onPath: _path, child: widget.child),
  );
}
