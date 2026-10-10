import 'package:flutter/foundation.dart';

import '../acp/acp_models.dart';
import '../acp/auth_needed.dart';
import '../acp/past_session.dart';
import '../acp/background/background_work.dart';
import '../acp/prompt_queue.dart';
import '../acp/session_state.dart';
import '../acp/subagents/subagent_run.dart' show SubagentLogStatus, SubagentRun, SubagentSummary;
import '../observed/observed_contracts.dart' show SubagentInfo;
import 'attach_target.dart';
import 'machine_connection.dart';

/// Where an agent session's link to its keeper stands.
enum AgentLink {
  /// Attaching for the first time.
  connecting,

  /// The keeper runs and nothing is wrong. A session nobody has open need not
  /// be attached (a host allows only a few channels per connection): the board
  /// shows it from the host's listing, and [AgentSessionView.acquire] attaches
  /// it; until that is done a held session reports [connecting].
  live,

  /// The link dropped (SSH, the network); the agent lives on in its keeper and
  /// the session re-attaches by itself.
  reconnecting,

  /// The agent process exited, or the person ended the session.
  ended,

  /// Could not attach and will not retry by itself ([AgentSessionView.error]
  /// says why).
  failed,
}

/// What a session knows of its transcript before the first item of
/// `state.items`.
enum EarlierHistory {
  /// Nothing: the transcript starts where the session did.
  none,

  /// The agent's log holds earlier messages the phone has not read
  /// ([AgentSessionView.loadEarlier] reads them).
  available,

  /// They are being read.
  loading,

  /// The log holds earlier messages, but more than the phone reads at once.
  tooLong,
}

/// One agent session as the screens see it. A `ChangeNotifier`-style
/// [Listenable]: it notifies when [state], [link] or [error] change. Notifies
/// at most once per frame's worth of updates (the implementation batches a
/// burst of chunks), never per chunk.
///
/// Implemented by `AcpAgentSession` (repository layer); screens and tests use
/// this interface only.
abstract interface class AgentSessionView implements Listenable, AttachTarget {
  /// `<machineId>/<keeperId>`: stable, a list key and the route argument.
  @override
  String get key;

  @override
  MachineConnection get machine;

  /// A route id (`omp`, `claude`, `codex`, `pi`).
  String get agent;

  /// `Claude Code`.
  String get agentLabel;

  @override
  String get cwd;

  /// The session's title when the agent sent one, else the folder's name.
  String get title;

  /// Everything known about the conversation: transcript items, tool calls,
  /// plan, slash commands, modes and config options, pending requests, phase.
  AgentSessionState get state;

  AgentLink get link;

  /// When the transcript in [state] is a copy saved by an earlier run (or an
  /// earlier visit) that the keeper has not confirmed yet: the time it was last
  /// known to be right. Null once the live replay has replaced it, and for a
  /// session that never showed one. Nothing in a saved copy can be answered.
  DateTime? get cachedAsOf;

  /// Whether there are earlier messages than [state] holds.
  EarlierHistory get earlier;

  /// Reads the earlier messages ([earlier] is [EarlierHistory.available]);
  /// otherwise nothing happens. What [state] holds now stays shown until they
  /// are all there, and nothing already shown moves.
  void loadEarlier();

  /// Why [link] is [AgentLink.failed], [AgentLink.reconnecting] or
  /// [AgentLink.ended]; null otherwise.
  String? get error;

  /// Derived from [state]: idle, working, blocked on a permission or a
  /// question.
  AgentPhase get phase;

  /// When [phase] last changed, as far as this app knows.
  DateTime? get phaseSince;

  /// When the agent last did anything, by the host's own clock (comparable
  /// across sessions and across launches, which [phaseSince] is not: that is
  /// "since this app saw it"). Null when the session has no such time.
  DateTime? get lastActivity;

  /// When the turn that runs now started, by this phone's clock: the instant
  /// of [send] for a turn this phone started (the elapsed clock of the status
  /// line counts from there, whatever the agent takes to answer), else when
  /// this app first saw the turn running. Null when no turn runs.
  DateTime? get turnStartedAt;

  /// The growing text of the message [messageKey] (a [TranscriptMessage.key])
  /// when it is streaming in right now ([AgentSessionState.liveKey]), else
  /// null. A chunk of that message does not replace [state]`.items`; the row
  /// that shows the message listens to this instead and reads
  /// `LiveText.text` / `LiveText.tail`. It notifies at most once per flush,
  /// together with the session.
  Listenable? liveTextOf(String messageKey);

  /// A turn finished and the person has not opened the session since.
  bool get unseenDone;

  /// The person is looking: clears [unseenDone].
  void markSeen();

  /// Takes back [markSeen] (the board's Undo): the turn that finished shows as
  /// done again. False, and nothing changes, unless that very finished turn is
  /// still the latest one and was seen: a session that has since started or
  /// finished another turn keeps what it has.
  bool unmarkSeen();

  /// Sends [text] as a prompt (a slash command is plain prompt text): the same
  /// as [sendBlocks] with the text alone.
  Future<bool> send(String text);

  /// Sends [blocks] (the text first, then images and file links; see
  /// `prompt_content.dart`), delivered as [delivery] says when it is called:
  ///
  /// - [SendDelivery.now]: a prompt.
  /// - [SendDelivery.steered]: into the running turn (`_session/steering`).
  /// - [SendDelivery.queued]: into [queued]. It goes out as a prompt when the
  ///   turn has ended, and not before.
  ///
  /// [queue] forces [SendDelivery.queued] while a turn runs, for a message
  /// that is meant for after it ("when you are done, also..."), on a route
  /// that could steer.
  ///
  /// Completes once the message is taken or refused, never later (a prompt's
  /// turn is not waited for): true when it went to the agent or waits in
  /// [queued] (held included), false when nothing of it was kept. The
  /// composer clears its draft on true and gives the person their text back
  /// on false, so a false must mean the message is nowhere else.
  ///
  /// Never throws: a failure lands in [error] (and the transcript), and a
  /// message the agent refused (a picture on a model with no vision, or an
  /// image while [acceptsImages] is false) is kept in [queued] as held, with
  /// the reason (true: it is not lost).
  Future<bool> sendBlocks(List<ContentBlock> blocks, {bool queue = false});

  /// How a message sent now would be delivered: what the composer says
  /// ("Queued", "Sent to the running turn"). [SendDelivery.queued] also when
  /// something already waits (the order is kept) and while the link is being
  /// re-made.
  SendDelivery get delivery;

  /// The agent takes messages into a running turn (`_session/steering`: Claude
  /// Code, Codex). omp and pi do not: their messages are queued here, because
  /// a prompt sent to omp during a turn cancels it, and pi's own queue cannot
  /// be shown or edited. False while no attach has told.
  bool get canSteer;

  /// The agent takes pictures in a prompt (`promptCapabilities.image`). Codex
  /// says yes and refuses on a text-only model: that arrives as an error
  /// message on the send. False while no attach has told.
  @override
  bool get acceptsImages;

  /// The agent takes embedded text resources (`promptCapabilities.embeddedContext`).
  @override
  bool get acceptsEmbeddedContext;

  /// How a message's pictures and files reach the agent: as content blocks
  /// (ACP), as host paths typed into its terminal (an observed agent), or not
  /// at all (a subagent's run).
  @override
  AttachMode get attachMode;

  /// What waits to be sent, oldest first; a new list whenever it changes. A
  /// message is [QueuedState.waiting] (goes out when the turn ends) or
  /// [QueuedState.held] (the turn failed or was stopped from elsewhere, or the
  /// agent refused: it stays until edited, removed or resumed). Kept in memory for
  /// the life of this session object: it survives a dropped link and a
  /// re-attach, not the app being killed.
  List<QueuedMessage> get queued;

  /// Replaces the text of the queued message [id], keeping its attachments (a
  /// blank text on a message with no attachment changes nothing).
  void editQueued(String id, String text);

  /// Drops the queued message [id].
  void removeQueued(String id);

  /// Lets every held message go out again, in order, as soon as the agent is
  /// idle.
  void resumeQueue();

  /// The agent says it needs a login (ACP `auth_required`), else null. The
  /// phone runs no login flow: the screen says "sign in on the host" and
  /// offers a terminal session. Cleared by the next send and by a successful
  /// attach.
  AuthNeeded? get authNeeded;

  /// Stops the turn in flight (`session/cancel`); pending requests are
  /// answered as cancelled. Queued messages are not held: once the turn has
  /// stopped they go out together as one message (the person queued them to
  /// follow it; stopping it is going on with them).
  void cancel();

  Future<void> setMode(String modeId);

  Future<void> setConfigOption(String configId, Object value);

  /// Answers the agent's permission request [requestId] (a
  /// `PendingPermission.id`). Nothing is ever allowed except through here.
  void answerPermission(Object requestId, PermissionOutcome outcome);

  /// Answers the agent's question [requestId] (a `PendingQuestion.id`).
  void answerQuestion(Object requestId, ElicitationResponse response);

  /// The last request this session showed that another client of its keeper
  /// answered first (the terminal on the computer, another phone); null until
  /// one was. A new object each time, so a screen tells the person about each
  /// one once (by identity). The request itself leaves [state] as a withdrawn
  /// one does.
  AnsweredElsewhere? get answeredElsewhere;

  /// Ends the session on the host (kills its keeper and agent), then [link]
  /// is [AgentLink.ended]. Detaching, by leaving the screen, does not. Throws
  /// `AgentHostException` (words for the person) when the host could not kill
  /// the keeper; the session is then untouched.
  Future<void> end();

  /// Another device attached to the keeper and took the session over: [link]
  /// is [AgentLink.ended] with that reason, and the session does not attach
  /// again by itself (two phones would evict each other for ever). Only a
  /// keeper started before shared sessions evicts; a newer one keeps every
  /// client attached. The screen offers "Take over", which calls [reattach].
  /// False in every other state.
  bool get evicted;

  /// What [AgentSessions.resume] needs to bring this session back when it
  /// ended because its keeper is gone (the host restarted, the keeper was
  /// killed, it was ended here): null while it lives, for an agent in a
  /// terminal, for a subagent, and when the agent never gave a session id.
  /// Not for an evicted session (`Take over` is its way back).
  ResumeTarget? get resumeTarget;

  /// Attaches again on purpose, after the session was taken over by another
  /// device ([evicted]) or failed to attach ([AgentLink.failed]). Does nothing
  /// when [link] is live, when the agent exited, or while the app is in the
  /// background. Completes when the attempt is over; never throws.
  Future<void> reattach();

  /// A screen shows this session: it is attached to its keeper (replaying what
  /// it missed) until the matching [release], whatever else is going on on the
  /// board. Calls pair up (a count); a screen calls [acquire] when it appears
  /// and [release] when it goes. While held, [link] is [AgentLink.connecting]
  /// until the attach is done.
  void acquire();

  /// Ends one [acquire]. Without a hold the session stays attached only if the
  /// repository has a reason (a waiting request, recent activity); otherwise
  /// it lets go of its channel and shows what the host's listing says.
  void release();

  /// An agent that runs in a herdr pane, followed through its own log: the
  /// chat shows what the log says and types into the pane. It has no modes or
  /// models, [end] is not offered, and the pane is one tap away.
  bool get isObserved;

  /// The pane of an observed session (what "Terminal" opens); null otherwise.
  String? get terminalPaneId;

  /// Observed only: the pane waits for the person on something the chat cannot
  /// show or answer; the screen offers the terminal.
  bool get needsTerminal;

  /// Observed only: the subagents the agent started, latest state first seen
  /// first. Empty for every other session.
  List<SubagentEntry> get subagents;

  /// Observed only: while a screen lists the subagents ([on]) their state is
  /// refined from the artifact folder on the host. Calls pair up; nothing runs
  /// without one.
  void watchSubagents(bool on);

  /// Observed subagent only: what the composer's message becomes ("Goes to the
  /// main agent, who relays it to PongReply"); null when it is sent as is.
  String? get relayNote;

  /// Observed only, ephemeral and never transcript: the last meaningful rows
  /// of the pane while the agent works and its log has been silent for a
  /// moment. Null when it is not shown; an empty list while the log is silent
  /// and the pane has not been read yet.
  List<String>? get liveOutput;

  /// Observed only: why the composer cannot send now (the pane waits for an
  /// answer), in the words of its hint; null when it can.
  String? get sendBlocked;

  /// ACP sessions: the subagent runs the agent started, in the order they
  /// began (the reducer's [AgentSessionState.subagents]). The same list
  /// instance until a run changes, so compare by identity. Not
  /// [subagents], which is the roster of an observed session. Empty for an
  /// observed session.
  List<SubagentRun> get subagentRuns;

  /// What the status line says about [subagentRuns].
  SubagentSummary get subagentSummary;

  /// The run with [id], or null.
  SubagentRun? subagentRun(String id);

  /// The runs the transcript tool row [toolCallId] started.
  List<SubagentRun> subagentsOfToolCall(String toolCallId);

  /// ACP omp: a screen shows (true) or stops showing (false) the subagent
  /// [runId]. While one does, the subagent's own log on the host is read, now
  /// and again while the run is active, and laid over the run as a transcript
  /// ([SubagentRun.log]); best effort, silent when it cannot be read. Without
  /// a watcher nothing is read and no timer runs. One call per screen; a
  /// no-op for every other session and run.
  void watchSubagentLog(String runId, bool on);

  /// How reading the log of [runId] stands, for the drill-in.
  SubagentLogStatus subagentLogStatus(String runId);

  /// Reads the log of [runId] again now (after [SubagentLogStatus.failed]).
  void retrySubagentLog(String runId);

  /// What keeps running after the turn: shell jobs, background terminals,
  /// subagents. The same instance until it changes.
  /// [BackgroundWork.empty] for an agent or route that reports none.
  BackgroundWork get backgroundWork;

  /// The turn is over (or never started here) and the agent still waits on
  /// background work: the screens say `Waiting` instead of `Working`, and
  /// offer Send instead of Stop. Derived once, here; widgets never recompute it.
  bool get waitingOnBackground;

  /// Stops the background task [id] by its route ([BackgroundTask.stop]).
  /// Never throws; the result says what happened.
  Future<BackgroundStopResult> stopBackground(String id);

  /// Stops every running task that has a stop route.
  Future<BackgroundStopResult> stopAllBackground();
}

/// A request ([requestId]) answered by another client of the keeper before
/// this phone did (`_herdr/resolved`).
class AnsweredElsewhere {
  const AnsweredElsewhere({
    required this.requestId,
    required this.by,
    required this.answer,
    this.kind,
    this.question = false,
  });

  final Object requestId;

  /// The name that client gave the keeper (`Terminal on mac-mini`); empty
  /// when it gave none.
  final String by;

  /// The name of the option chosen; for a question its action (`accept`,
  /// `decline`, `cancel`).
  final String answer;

  /// The kind of the option chosen, when it is one the request offered.
  final PermissionOptionKind? kind;

  /// The request was a question (a form), not a permission.
  final bool question;
}

/// Where a subagent stands: the log said [waiting], [running], [finished] or
/// [failed], refined by what the artifact folder on the host shows.
enum SubagentState { waiting, running, finished, failed }

/// One subagent in the roster.
class SubagentEntry {
  const SubagentEntry({required this.info, required this.state});

  final SubagentInfo info;
  final SubagentState state;

  String get name => info.name;
}

/// The sessions of every machine: what the board, the start form and the
/// session screen read. Implemented by `AgentSessionRepository`.
abstract interface class AgentSessions implements Listenable {
  /// Live and recently ended sessions, most urgent first (blocked, done and
  /// unseen, working, idle), then by most recent activity.
  List<AgentSessionView> get sessions;

  AgentSessionView? byKey(String key);

  /// Which route ids [machine] can run (the start form greys out the rest).
  Future<Set<String>> available(MachineConnection machine);

  /// Starts a keeper on [machine] for [agent] in [cwd], attaches, creates the
  /// ACP session and returns it. Throws `AgentHostException` with words for the
  /// person.
  Future<AgentSessionView> start({
    required MachineConnection machine,
    required String agent,
    required String cwd,
  });

  /// What [agent] remembers on [machine] (see [AgentHost.history]), for [cwd]
  /// only when given.
  Future<PastSessions> history({required MachineConnection machine, required String agent, String? cwd});

  /// Reopens a past session in a new keeper: starts the agent in [cwd] and
  /// replays [sessionId] into it (`session/load`, else `session/resume`). The
  /// result is attached. A session already held on [machine] (live, not ended)
  /// with this id is returned as it is, never loaded twice. [replaces] is the
  /// key of an ended session this one continues: it is dropped once the new
  /// one is attached. Throws [AgentHostException] with the reason.
  Future<AgentSessionView> resume({
    required MachineConnection machine,
    required String agent,
    required String cwd,
    required String sessionId,
    String? replaces,
  });

  /// Looks at the hosts again now (pull to refresh): finds keepers started
  /// elsewhere and drops the ones the host forgot. Never throws.
  Future<void> refresh();

  /// The Agents tab is on screen (or not). While it is, the hosts are listed
  /// every 60 s; otherwise no timer runs at all.
  void setBoardVisible(bool visible);

  /// Keep sessions attached and the hosts listed (slowly) while the app is in
  /// the background, instead of letting go 90 s after it left. On while the
  /// person has asked to be told about agents that need them and the
  /// background connection is kept (see `AttentionNotifier`). Off by default;
  /// off again, the usual rules apply (at once if the 90 s are long past).
  set keepAliveInBackground(bool value);

  /// Takes a hold on [sessionKey]'s channel before a screen asks for it (a
  /// finger went down on its row): the attach starts while the route is still
  /// being pushed. Cancel the returned hold when the finger leaves, or hand it
  /// to the screen that opens ([Preconnect.cancel] once that has taken its
  /// own hold). Never starts anything in the background, beyond the machine's
  /// channel limit, or for a session that cannot be attached: then the hold is
  /// inert ([Preconnect.none]). Idempotent per hold, and a hold that nobody
  /// cancels lets go by itself after a few seconds.
  Preconnect preconnect(String sessionKey);
}

/// A hold taken by [AgentSessions.preconnect].
abstract interface class Preconnect {
  /// Lets go of the hold. Safe to call twice.
  void cancel();

  /// A hold that does nothing.
  static const Preconnect none = _NoPreconnect();
}

class _NoPreconnect implements Preconnect {
  const _NoPreconnect();

  @override
  void cancel() {}
}
