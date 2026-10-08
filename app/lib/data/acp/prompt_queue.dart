import 'acp_models.dart';

/// How a message sent right now would reach the agent; what the composer says
/// ("Queued", "Sent to the running turn").
enum SendDelivery {
  /// The agent is idle: a prompt of its own, at once.
  now,

  /// The agent is working and takes input into the turn that runs
  /// (`_session/steering`, advertised by Claude Code and Codex).
  steered,

  /// It waits on the phone and goes out as a prompt when the turn has ended
  /// (a route with no steering, or a link that is being re-made).
  queued,
}

/// Where a [QueuedMessage] stands.
enum QueuedState {
  /// It goes out when the turn ends (and only then).
  waiting,

  /// It will not go out by itself: the person stopped the turn, the turn
  /// failed, or the agent refused the message. The person edits it, removes
  /// it, or resumes the queue.
  held,
}

/// A message that has not been sent yet. Immutable; an edit makes a new one
/// with the same [id].
class QueuedMessage {
  const QueuedMessage({
    required this.id,
    required this.blocks,
    required this.at,
    this.state = QueuedState.waiting,
    this.heldReason,
  });

  /// Stable for the life of the message; what [PromptQueue.edit] and
  /// `AgentSessionView.removeQueued` take.
  final String id;

  /// What will be sent: the text first, then attachments (images, links).
  final List<ContentBlock> blocks;

  /// When the person sent it (their clock).
  final DateTime at;
  final QueuedState state;

  /// Why it is [QueuedState.held], in words for the person; null otherwise.
  final String? heldReason;

  bool get held => state == QueuedState.held;

  /// The typed text.
  String get text => [for (final b in blocks) if (b is TextBlock) b.text].join('\n');

  /// Everything but the text: images and file links.
  List<ContentBlock> get attachments => [
    for (final b in blocks)
      if (b is! TextBlock) b,
  ];

  QueuedMessage _with({List<ContentBlock>? blocks, QueuedState? state, Object? heldReason = _keep}) => QueuedMessage(
    id: id,
    blocks: blocks ?? this.blocks,
    at: at,
    state: state ?? this.state,
    heldReason: identical(heldReason, _keep) ? this.heldReason : heldReason as String?,
  );
}

const Object _keep = Object();

/// The messages a person sent while the agent could not take them, in the
/// order they go out. Pure and synchronous; `AcpAgentSession` owns one per
/// session and decides *when* to send (only once the turn has ended).
///
/// Held in memory only: it survives a dropped link and a re-attach (the
/// session object does), not the app being killed.
///
/// [entries] is replaced on every change (never mutated), so a screen can tell
/// a change by identity.
class PromptQueue {
  List<QueuedMessage> _entries = const [];
  var _next = 1;

  List<QueuedMessage> get entries => _entries;
  bool get isEmpty => _entries.isEmpty;

  /// Something goes out by itself when the turn ends.
  bool get hasWaiting => _entries.any((e) => !e.held);

  /// The next to send: the oldest that is not held.
  QueuedMessage? get firstWaiting {
    for (final e in _entries) {
      if (!e.held) return e;
    }
    return null;
  }

  /// Queues [blocks]; at the back, or at the front with [first] (a message
  /// that was about to go and could not). Returns the new entry.
  QueuedMessage add(
    List<ContentBlock> blocks, {
    required DateTime at,
    QueuedState state = QueuedState.waiting,
    String? heldReason,
    bool first = false,
  }) {
    final entry = QueuedMessage(id: 'q${_next++}', blocks: blocks, at: at, state: state, heldReason: heldReason);
    _entries = first ? [entry, ..._entries] : [..._entries, entry];
    return entry;
  }

  /// Replaces the text of [id], keeping its attachments. A blank [text] on a
  /// message with no attachments changes nothing (it would be an empty
  /// prompt). Returns whether the entry changed.
  bool edit(String id, String text) {
    final i = _indexOf(id);
    if (i < 0) return false;
    final old = _entries[i];
    final trimmed = text.trim();
    final attachments = old.attachments;
    if (trimmed.isEmpty && attachments.isEmpty) return false;
    final blocks = [if (trimmed.isNotEmpty) TextBlock(text), ...attachments];
    return _replace(i, old._with(blocks: blocks));
  }

  bool remove(String id) {
    final i = _indexOf(id);
    if (i < 0) return false;
    _entries = [..._entries]..removeAt(i);
    return true;
  }

  /// Holds [id] for [reason]. Returns whether it changed.
  bool hold(String id, String reason) {
    final i = _indexOf(id);
    if (i < 0) return false;
    return _replace(i, _entries[i]._with(state: QueuedState.held, heldReason: reason));
  }

  /// Holds everything that waits (the person stopped the turn, or it failed).
  /// Returns whether anything changed.
  bool holdAll(String reason) {
    if (!hasWaiting) return false;
    _entries = [for (final e in _entries) e.held ? e : e._with(state: QueuedState.held, heldReason: reason)];
    return true;
  }

  /// Joins everything that waits into one message, at the place of the first:
  /// the person stopped the turn, and what they had queued for after it goes
  /// out together instead of one turn at a time. Text is joined by a blank
  /// line, in the order sent; images and file links follow, in the same order.
  /// The first message keeps its id, so a screen sees one row become one.
  /// Returns whether anything changed (nothing, with fewer than two waiting).
  bool mergeWaiting() {
    final waiting = [for (final e in _entries) if (!e.held) e];
    if (waiting.length < 2) return false;
    final first = waiting.first;
    final text = [
      for (final e in waiting)
        if (e.text.trim().isNotEmpty) e.text.trim(),
    ].join('\n\n');
    final merged = QueuedMessage(
      id: first.id,
      blocks: [
        if (text.isNotEmpty) TextBlock(text),
        for (final e in waiting) ...e.attachments,
      ],
      at: first.at,
    );
    _entries = [
      for (final e in _entries)
        if (identical(e, first))
          merged
        else if (e.held)
          e,
    ];
    return true;
  }

  /// Lets every held message go out again, in order. Returns whether anything
  /// changed.
  bool release() {
    if (!_entries.any((e) => e.held)) return false;
    _entries = [for (final e in _entries) e.held ? e._with(state: QueuedState.waiting, heldReason: null) : e];
    return true;
  }

  int _indexOf(String id) => _entries.indexWhere((e) => e.id == id);

  bool _replace(int i, QueuedMessage next) {
    _entries = [..._entries]..[i] = next;
    return true;
  }
}
