import 'package:flutter/foundation.dart' show debugPrint;

/// What was logged already: a row that stays unreadable is met again at every
/// refresh, and the log should say it once.
final _reportedRows = <String>{};

void _reportRow(String list, Object error) {
  if (_reportedRows.length < 50 && _reportedRows.add('$list: $error')) {
    debugPrint('herdr: an unreadable row of "$list" is left out: $error');
  }
}

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

  Workspace withStatus(AgentStatus status) => Workspace(
        id: id,
        number: number,
        label: label,
        focused: focused,
        paneCount: paneCount,
        tabCount: tabCount,
        status: status,
      );

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

  Tab withStatus(AgentStatus status) => Tab(
        id: id,
        workspaceId: workspaceId,
        number: number,
        label: label,
        focused: focused,
        paneCount: paneCount,
        status: status,
      );

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

/// The session an agent in a pane reports about itself (herdr's
/// `agent_session`): for `omp` and others, `kind: path` and the log file the
/// agent appends its transcript to.
class AgentSessionRef {
  const AgentSessionRef({required this.agent, required this.kind, required this.value, this.source});

  /// Null for anything that is not a map with a string `value`: the field is
  /// the host agent's own and its shape is not ours to rely on.
  static AgentSessionRef? tryParse(Object? json) {
    if (json is! Map) return null;
    final value = json['value'];
    if (value is! String || value.isEmpty) return null;
    final agent = json['agent'];
    final kind = json['kind'];
    final source = json['source'];
    return AgentSessionRef(
      agent: agent is String ? agent : '',
      kind: kind is String ? kind : '',
      value: value,
      source: source is String ? source : null,
    );
  }

  final String agent;
  final String kind;
  final String value;
  final String? source;

  Map<String, dynamic> toJson() => {
        'agent': agent,
        'kind': kind,
        'value': value,
        if (source != null) 'source': source,
      };

  @override
  bool operator ==(Object other) =>
      other is AgentSessionRef &&
      other.agent == agent &&
      other.kind == kind &&
      other.value == value &&
      other.source == source;

  @override
  int get hashCode => Object.hash(agent, kind, value, source);
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
    this.label,
    this.completionSeq,
    this.session,
  });

  factory Pane.fromJson(Map<String, dynamic> j) {
    final title = (j['terminal_title_stripped'] ?? j['terminal_title']) as String?;
    final label = (j['label'] as String?)?.trim();
    return Pane(
      id: j['pane_id'] as String,
      workspaceId: j['workspace_id'] as String,
      tabId: j['tab_id'] as String,
      focused: j['focused'] == true,
      cwd: (j['foreground_cwd'] ?? j['cwd']) as String?,
      // A name the person gave the pane wins over whatever the program set.
      title: label != null && label.isNotEmpty ? label : cleanTerminalTitle(title ?? ''),
      agent: j['agent'] as String?,
      status: AgentStatus.parse(j['agent_status']),
      label: label != null && label.isNotEmpty ? label : null,
      completionSeq: (j['completion_seq'] as num?)?.toInt(),
      session: AgentSessionRef.tryParse(j['agent_session']),
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

  /// The name given with `pane.rename`, if any (already what [title] shows).
  final String? label;

  /// herdr's `completion_seq`: names the finished-work transition the pane is
  /// in, independently of who has looked at it. Null on a pane that did not
  /// just finish work, and on herdr versions that do not send it (see
  /// [Snapshot.fromJson] for where it comes from).
  final int? completionSeq;

  /// What the agent in the pane says about its own session (see
  /// [AgentSessionRef]); null for plain terminals and agents that name none.
  final AgentSessionRef? session;

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
        'label': label,
        if (completionSeq != null) 'completion_seq': completionSeq,
        if (session != null) 'agent_session': session!.toJson(),
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
      other.status == status &&
      other.label == label &&
      other.completionSeq == completionSeq &&
      other.session == session;

  @override
  int get hashCode =>
      Object.hash(id, workspaceId, tabId, focused, cwd, title, agent, status, label, completionSeq, session);

  Pane withStatus(AgentStatus status) => Pane(
        id: id,
        workspaceId: workspaceId,
        tabId: tabId,
        focused: focused,
        cwd: cwd,
        title: title,
        agent: agent,
        status: status,
        label: label,
        completionSeq: completionSeq,
        session: session,
      );

  Pane withCompletionSeq(int? seq) => Pane(
        id: id,
        workspaceId: workspaceId,
        tabId: tabId,
        focused: focused,
        cwd: cwd,
        title: title,
        agent: agent,
        status: status,
        label: label,
        completionSeq: seq,
        session: session,
      );
}

/// What `Pane.fromJson` reads of a pane, in a snapshot and in a `pane_updated`
/// event alike (see [snapshotWireFields]).
const paneWireFields = <String, Object>{
  'pane_id': true,
  'workspace_id': true,
  'tab_id': true,
  'focused': true,
  'foreground_cwd': true,
  'cwd': true,
  'terminal_title_stripped': true,
  'terminal_title': true,
  'label': true,
  'agent': true,
  'agent_status': true,
  'completion_seq': true,
  'agent_session': true,
};

/// What of a `session.snapshot` the models above read, as a projection the
/// mux script applies (see `muxProjections`) so the rest never crosses the
/// wire: per-pane session paths, scroll state and the layouts are most of
/// herdr's answer and nothing here uses them. The `agents` list is read for
/// `completion_seq` only (the mux script moves it onto the pane row). A field a `fromJson` starts reading MUST
/// be added here; `herdr_models_test.dart` fails when one is missing.
const snapshotWireFields = <String, Object>{
  'version': true,
  'workspaces': <String, Object>{
    'workspace_id': true,
    'number': true,
    'label': true,
    'focused': true,
    'pane_count': true,
    'tab_count': true,
    'agent_status': true,
  },
  'tabs': <String, Object>{
    'tab_id': true,
    'workspace_id': true,
    'number': true,
    'label': true,
    'focused': true,
    'pane_count': true,
    'agent_status': true,
  },
  'panes': paneWireFields,
  // Where herdr puts `completion_seq`: per agent, not per pane.
  'agents': <String, Object>{'pane_id': true, 'completion_seq': true},
};

/// One-shot view of a herdr server (`session.snapshot`).
class Snapshot {
  const Snapshot({
    required this.version,
    required this.workspaces,
    required this.tabs,
    required this.panes,
  });

  factory Snapshot.fromJson(Map<String, dynamic> j) {
    // One row this app cannot read (a field of another type, one a newer herdr
    // adds) is left out and logged, not the whole machine: its other agents
    // are still there to answer.
    List<T> list<T>(String key, T Function(Map<String, dynamic>) f) {
      final out = <T>[];
      for (final row in (j[key] as List?) ?? const []) {
        try {
          if (row is! Map) throw FormatException('not an object', row);
          out.add(f(row is Map<String, dynamic> ? row : Map<String, dynamic>.from(row)));
        } on Object catch (e) {
          _reportRow(key, e);
        }
      }
      return out.toList(growable: false);
    }
    // `completion_seq` is on the snapshot's `agents` entries (herdr's
    // `AgentInfo`), not on its panes; older servers send none.
    final completions = <String, int>{};
    for (final a in (j['agents'] as List?) ?? const []) {
      if (a is! Map) continue;
      final id = a['pane_id'];
      final seq = a['completion_seq'];
      if (id is String && seq is num) completions[id] = seq.toInt();
    }
    return Snapshot(
      version: (j['version'] as String?) ?? '',
      workspaces: list('workspaces', Workspace.fromJson),
      tabs: list('tabs', Tab.fromJson),
      panes: list('panes', Pane.fromJson)
          .map((p) => p.completionSeq == null && completions.containsKey(p.id)
              ? p.withCompletionSeq(completions[p.id])
              : p)
          .toList(growable: false),
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

/// What `PaneRead.fromJson` reads of a `pane.read` answer (see
/// [snapshotWireFields]).
const paneReadWireFields = <String, Object>{'text': true, 'truncated': true};

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

/// One process in the foreground of a pane (`pane.process_info`).
class PaneProcess {
  const PaneProcess({required this.pid, required this.name, this.argv0, this.cmdline, this.cwd});

  /// Null for a row without an integer pid: herdr's own field, not ours to
  /// rely on.
  static PaneProcess? tryParse(Object? json) {
    if (json is! Map) return null;
    final pid = json['pid'];
    final name = json['name'];
    if (pid is! int || name is! String) return null;
    String? text(String key) => json[key] is String ? json[key] as String : null;
    return PaneProcess(pid: pid, name: name, argv0: text('argv0'), cmdline: text('cmdline'), cwd: text('cwd'));
  }

  final int pid;
  final String name;
  final String? argv0;
  final String? cmdline;
  final String? cwd;
}
