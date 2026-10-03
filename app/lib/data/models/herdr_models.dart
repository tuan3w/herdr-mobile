final _spinnerGlyphs = RegExp(r'[\u2800-\u28FF]');
final _leadingNoise = RegExp(r'^[^\p{L}\p{N}]+', unicode: true);

/// Terminal titles carry agent chrome: braille spinner frames that change
/// several times a second, omp's π mark, separators. Stripping it here keeps
/// the title readable and, more importantly, keeps spinner animation from
/// making every snapshot "different" (which refetches and rebuilds the UI for
/// nothing).
String cleanTerminalTitle(String raw) {
  var t = raw.replaceAll(_spinnerGlyphs, '').trim();
  if (t.startsWith('π')) t = t.substring(1);
  return t.replaceFirst(_leadingNoise, '').trim();
}

/// Agent status as reported by herdr. `done` means idle and not yet seen.
enum AgentStatus {
  blocked,
  working,
  done,
  idle,
  unknown;

  static AgentStatus parse(Object? raw) => switch (raw) {
        'blocked' => blocked,
        'working' => working,
        'done' => done,
        'idle' => idle,
        _ => unknown,
      };

  /// Sort rank: what needs the user most comes first.
  int get attentionRank => index;
}

class Workspace {
  const Workspace({
    required this.id,
    required this.number,
    required this.label,
    required this.focused,
    required this.paneCount,
    required this.tabCount,
    required this.status,
  });

  factory Workspace.fromJson(Map<String, dynamic> j) => Workspace(
        id: j['workspace_id'] as String,
        number: (j['number'] as num?)?.toInt() ?? 0,
        label: (j['label'] as String?) ?? '',
        focused: j['focused'] == true,
        paneCount: (j['pane_count'] as num?)?.toInt() ?? 0,
        tabCount: (j['tab_count'] as num?)?.toInt() ?? 0,
        status: AgentStatus.parse(j['agent_status']),
      );

  final String id;
  final int number;
  final String label;
  final bool focused;
  final int paneCount;
  final int tabCount;
  final AgentStatus status;

  Map<String, dynamic> toJson() => {
        'workspace_id': id,
        'number': number,
        'label': label,
        'focused': focused,
        'pane_count': paneCount,
        'tab_count': tabCount,
        'agent_status': status.name,
      };

  @override
  bool operator ==(Object other) =>
      other is Workspace &&
      other.id == id &&
      other.number == number &&
      other.label == label &&
      other.focused == focused &&
      other.paneCount == paneCount &&
      other.tabCount == tabCount &&
      other.status == status;

  @override
  int get hashCode =>
      Object.hash(id, number, label, focused, paneCount, tabCount, status);
}

class Tab {
  const Tab({
    required this.id,
    required this.workspaceId,
    required this.number,
    required this.label,
    required this.focused,
    required this.paneCount,
    required this.status,
  });

  factory Tab.fromJson(Map<String, dynamic> j) => Tab(
        id: j['tab_id'] as String,
        workspaceId: j['workspace_id'] as String,
        number: (j['number'] as num?)?.toInt() ?? 0,
        label: (j['label'] as String?) ?? '',
        focused: j['focused'] == true,
        paneCount: (j['pane_count'] as num?)?.toInt() ?? 0,
        status: AgentStatus.parse(j['agent_status']),
      );

  final String id;
  final String workspaceId;
  final int number;
  final String label;
  final bool focused;
  final int paneCount;
  final AgentStatus status;

  Map<String, dynamic> toJson() => {
        'tab_id': id,
        'workspace_id': workspaceId,
        'number': number,
        'label': label,
        'focused': focused,
        'pane_count': paneCount,
        'agent_status': status.name,
      };

  @override
  bool operator ==(Object other) =>
      other is Tab &&
      other.id == id &&
      other.workspaceId == workspaceId &&
      other.number == number &&
      other.label == label &&
      other.focused == focused &&
      other.paneCount == paneCount &&
      other.status == status;

  @override
  int get hashCode =>
      Object.hash(id, workspaceId, number, label, focused, paneCount, status);
}

class Pane {
  const Pane({
    required this.id,
    required this.workspaceId,
    required this.tabId,
    required this.focused,
    required this.cwd,
    required this.title,
    required this.agent,
    required this.status,
  });

  factory Pane.fromJson(Map<String, dynamic> j) {
    final title = (j['terminal_title_stripped'] ?? j['terminal_title']) as String?;
    return Pane(
      id: j['pane_id'] as String,
      workspaceId: j['workspace_id'] as String,
      tabId: j['tab_id'] as String,
      focused: j['focused'] == true,
      cwd: (j['foreground_cwd'] ?? j['cwd']) as String?,
      title: cleanTerminalTitle(title ?? ''),
      agent: j['agent'] as String?,
      status: AgentStatus.parse(j['agent_status']),
    );
  }

  final String id;
  final String workspaceId;
  final String tabId;
  final bool focused;
  final String? cwd;
  final String title;

  /// Detected agent name (e.g. `claude`, `omp`), null for plain terminals.
  final String? agent;
  final AgentStatus status;

  bool get isAgent => agent != null;

  Map<String, dynamic> toJson() => {
        'pane_id': id,
        'workspace_id': workspaceId,
        'tab_id': tabId,
        'focused': focused,
        'cwd': cwd,
        'terminal_title': title,
        'agent': agent,
        'agent_status': status.name,
      };

  @override
  bool operator ==(Object other) =>
      other is Pane &&
      other.id == id &&
      other.workspaceId == workspaceId &&
      other.tabId == tabId &&
      other.focused == focused &&
      other.cwd == cwd &&
      other.title == title &&
      other.agent == agent &&
      other.status == status;

  @override
  int get hashCode =>
      Object.hash(id, workspaceId, tabId, focused, cwd, title, agent, status);
}

/// One-shot view of a herdr server (`session.snapshot`).
class Snapshot {
  const Snapshot({
    required this.version,
    required this.workspaces,
    required this.tabs,
    required this.panes,
  });

  factory Snapshot.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) f) =>
        ((j[key] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(f)
            .toList(growable: false);
    return Snapshot(
      version: (j['version'] as String?) ?? '',
      workspaces: list('workspaces', Workspace.fromJson),
      tabs: list('tabs', Tab.fromJson),
      panes: list('panes', Pane.fromJson),
    );
  }

  static const empty =
      Snapshot(version: '', workspaces: [], tabs: [], panes: []);

  final String version;
  final List<Workspace> workspaces;
  final List<Tab> tabs;
  final List<Pane> panes;

  Map<String, dynamic> toJson() => {
        'version': version,
        'workspaces': [for (final w in workspaces) w.toJson()],
        'tabs': [for (final t in tabs) t.toJson()],
        'panes': [for (final p in panes) p.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is Snapshot &&
      other.version == version &&
      _sameItems(other.workspaces, workspaces) &&
      _sameItems(other.tabs, tabs) &&
      _sameItems(other.panes, panes);

  @override
  int get hashCode => Object.hash(
        version,
        Object.hashAll(workspaces),
        Object.hashAll(tabs),
        Object.hashAll(panes),
      );

  List<Pane> get agentPanes =>
      panes.where((p) => p.isAgent).toList(growable: false);

  List<Tab> tabsOf(String workspaceId) =>
      tabs.where((t) => t.workspaceId == workspaceId).toList(growable: false);

  List<Pane> panesOf(String tabId) =>
      panes.where((p) => p.tabId == tabId).toList(growable: false);

  Workspace? workspace(String id) {
    for (final w in workspaces) {
      if (w.id == id) return w;
    }
    return null;
  }
}

bool _sameItems<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Text read from a pane (`pane.read`).
class PaneRead {
  const PaneRead({required this.text, required this.truncated});

  factory PaneRead.fromJson(Map<String, dynamic> j) => PaneRead(
        text: (j['text'] as String?) ?? '',
        truncated: j['truncated'] == true,
      );

  final String text;
  final bool truncated;
}
