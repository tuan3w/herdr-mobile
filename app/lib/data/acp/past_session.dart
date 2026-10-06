/// A session an agent kept in its own store (`session/list`), whether or not a
/// keeper holds it now. The agent, not this app, is the record of a
/// conversation: after the host restarted, or a keeper was removed, this is how
/// the thread comes back (`session/load` replays it).
class PastSession {
  const PastSession({
    required this.agent,
    required this.sessionId,
    required this.cwd,
    this.title,
    this.updatedAt,
    this.messageCount,
  });

  /// The route id of the agent that holds it (`omp`, `claude`, `codex`, `pi`).
  final String agent;
  final String sessionId;

  /// The folder it ran in on the host; `session/load` needs it.
  final String cwd;

  /// The agent's title for it; null when it has none yet.
  final String? title;

  /// When it last changed, as the agent says.
  final DateTime? updatedAt;

  /// `_meta.messageCount` where the agent reports it (omp does).
  final int? messageCount;

  /// One entry of the `sessions` array of a `session/list` answer.
  static PastSession? fromJson(Map<String, Object?> j, {required String agent}) {
    final id = j['sessionId'];
    final cwd = j['cwd'];
    if (id is! String || id.isEmpty || cwd is! String) return null;
    final meta = j['_meta'];
    final count = meta is Map ? meta['messageCount'] : null;
    final title = j['title'];
    final at = j['updatedAt'];
    return PastSession(
      agent: agent,
      sessionId: id,
      cwd: cwd,
      title: title is String && title.trim().isNotEmpty ? title.trim() : null,
      updatedAt: at is String ? DateTime.tryParse(at) : null,
      messageCount: count is num ? count.toInt() : null,
    );
  }

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'cwd': cwd,
    if (title != null) 'title': title,
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
    if (messageCount != null) '_meta': {'messageCount': messageCount},
  };
}

/// What one agent on one host answered to "what do you remember".
class PastSessions {
  const PastSessions({
    required this.agent,
    required this.sessions,
    this.canList = true,
    this.canLoad = false,
    this.canResume = false,
    this.more = false,
  });

  final String agent;

  /// Newest first (the host sorts by [PastSession.updatedAt], unknown last).
  final List<PastSession> sessions;

  /// The agent offers `session/list`. False means [sessions] is empty because
  /// the agent cannot say, not because it remembers nothing.
  final bool canList;

  /// The agent can replay a session into a new process (`session/load`).
  final bool canLoad;

  /// The agent can reopen one without replaying (`session/resume`).
  final bool canResume;

  /// The host stopped reading pages before the agent ran out.
  final bool more;

  /// A past session can be reopened at all.
  bool get canReopen => canLoad || canResume;

  /// The `history` command's one JSON line:
  /// `{"agent":..,"list":bool,"load":bool,"resume":bool,"more":bool,"sessions":[..]}`.
  factory PastSessions.fromJson(Map<String, Object?> j) {
    final agent = '${j['agent'] ?? ''}';
    final raw = j['sessions'];
    return PastSessions(
      agent: agent,
      sessions: [
        if (raw is List)
          for (final s in raw)
            if (s is Map<String, Object?>) ?PastSession.fromJson(s, agent: agent),
      ],
      canList: j['list'] != false,
      canLoad: j['load'] == true,
      canResume: j['resume'] == true,
      more: j['more'] == true,
    );
  }
}

/// What it takes to reopen a session whose keeper is gone.
class ResumeTarget {
  const ResumeTarget({required this.agent, required this.cwd, required this.sessionId});

  final String agent;
  final String cwd;
  final String sessionId;
}
