/// What an agent's pane is called when the pane's own title says nothing.
///
/// Read from the agent's session log (`PaneSessionNames`), never typed into the
/// agent. The agent's own title for the session is shown as it is. A name taken
/// from the last thing the person said is shown in quotes: it is what was
/// asked, not the agent's name for the work, and it may be many turns old.
class PaneName {
  const PaneName.title(this.text) : fromPrompt = false;
  const PaneName.prompt(this.text) : fromPrompt = true;

  final String text;

  /// True when [text] is the person's last message, not the agent's title.
  final bool fromPrompt;

  /// What the board shows.
  String get shown => fromPrompt ? '\u201C$text\u201D' : text;

  @override
  bool operator ==(Object other) =>
      other is PaneName && other.text == text && other.fromPrompt == fromPrompt;

  @override
  int get hashCode => Object.hash(text, fromPrompt);

  @override
  String toString() => 'PaneName($shown)';
}

/// The last segment of [cwd] (`/src/payments-api` is `payments-api`), empty for
/// none.
String paneFolder(String? cwd) {
  if (cwd == null || cwd.isEmpty) return '';
  final parts = cwd.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? '/' : parts.last;
}

/// True when [title] tells the person nothing about what the agent is doing:
/// empty, the agent's own name, `terminal`, or the folder or workspace it runs
/// in. omp titles its terminal `π > <session title>` and, before it has a
/// title, `π > <folder>`, so a board of such panes reads as one name repeated.
bool isGenericPaneTitle(
  String title, {
  String? agent,
  String? folder,
  String? workspace,
}) {
  final t = title.trim().toLowerCase();
  if (t.isEmpty || t == 'terminal') return true;
  bool same(String? other) => other != null && other.trim().isNotEmpty && other.trim().toLowerCase() == t;
  return same(agent) || same(folder) || same(workspace);
}
