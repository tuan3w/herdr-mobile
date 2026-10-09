import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/auth_needed.dart' show AuthNeeded;
import '../../../data/acp/prompt_content.dart' show composePrompt;
import '../../../data/services/image_prep.dart' show PreparedImage, prepareImage;
import '../../../data/acp/session_state.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/last_seen.dart';
import '../../../data/repositories/machine_connection.dart' show LinkState;
import '../../../data/repositories/sent_phrases.dart';
import '../../../data/services/dictation.dart';
import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/status_panel.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../attach/attach_kit.dart';
import 'attach_model.dart';
import 'attach_picker.dart';
import 'auth_panel.dart';
import 'background_format.dart' show stoppedToast;
import 'background_sheet.dart' show showBackgroundToast, showBackgroundWork;
import 'background_strip.dart';
import 'command_palette.dart';
import 'continue_button.dart';
import 'composer.dart';
import 'danger_announce.dart';
import 'observed_widgets.dart';
import '../agents/agent_navigation.dart';
import '../agents/agent_swipe.dart';
import '../agents/swipe_review.dart' show markSessionReviewedWithUndo;
import 'permission_dock.dart';
import 'plan_header.dart';
import 'saved_copy.dart';
import 'session_bar.dart';
import 'session_select.dart';
import 'transcript_view.dart';
import '../dictation/dictation_session.dart';

/// The bottom region (palette, request, composer) never takes more than this
/// share of the room under the bar; past it, it scrolls.
const _bottomShare = 0.8;

/// One agent session as a chat: the slim bar, the link's state, the plan, the
/// transcript, the request that waits for an answer, and the composer.
///
/// It talks to the [AgentSessionView] only. Every region selects the slice of
/// the session it shows and is built once here, so the keyboard's animation
/// re-lays out the transcript and composer and rebuilds neither, and a
/// streaming answer rebuilds one row of the transcript (the live row) and
/// nothing else.
///
/// Opened as an agent ([agent], see `openAgent`), a swipe on the transcript
/// goes to the next agent in the board's order, an agent in a pane has `Show
/// terminal` in the options sheet, and the draft is kept outside the
/// screen. A subagent's transcript is not an agent of the board: it has none
/// of those.
class AgentSessionScreen extends StatefulWidget {
  const AgentSessionScreen({
    super.key,
    required this.session,
    this.agent,
    this.preconnect,
    this.picker = const DevicePicker(),
    this.prepare = prepareImage,
    this.attachKit,
    this.readFile,
  });

  final AgentSessionView session;

  /// The board's agent this chat shows: the session itself, or the pane its
  /// agent runs in. Null for a subagent's transcript.
  final AgentRef? agent;

  /// The hold taken when a finger went down on this session's row (see
  /// `AgentSessions.preconnect`); let go once the screen has its own.
  final Preconnect? preconnect;

  /// Where the attach button's pictures come from (a test swaps it).
  final AttachPicker picker;

  /// Turns a picked picture into what is sent: `prepareImage` (a test swaps
  /// it; the real one needs the engine's codec and an isolate).
  final Future<PreparedImage> Function(Uint8List input) prepare;

  /// The attach sheet's library, files and uploads (the phone's own unless a
  /// test hands in fakes).
  final AttachKit? attachKit;

  /// Reads a picture of the phone's storage; null reads the file.
  final Future<Uint8List> Function(String path)? readFile;

  @override
  State<AgentSessionScreen> createState() => _AgentSessionScreenState();
}

class _AgentSessionScreenState extends State<AgentSessionScreen> with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _focus = FocusNode();

  /// Null without a speech service (tests).
  DictationSession? _dictation;
  late final ComposerAttachments _attachments = ComposerAttachments(
    session: widget.session,
    picker: widget.picker,
    prepare: widget.prepare,
    onProblem: _problem,
    kit: widget.attachKit,
    readFile: widget.readFile ?? ComposerAttachments.readDeviceFile,
  );

  late final Widget _plan = PlanHeader(session: widget.session);

  /// Built again once, when [_resolveSinceLeft] has the divider's data.
  late Widget _transcript = TranscriptView(session: widget.session);
  late final Widget _bottom = _Bottom(
    palette: CommandPalette(session: widget.session, input: _input, onPick: _pickCommand),
    dock: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LiveOutput(session: widget.session),
        _WaitsUntilLive(session: widget.session),
        Flexible(child: PromptDock(session: widget.session)),
      ],
    ),
    strip: BackgroundStrip(session: widget.session),
    composer: Composer(
      dictation: _dictation,
      session: widget.session,
      controller: _input,
      focusNode: _focus,
      attachments: _attachments,
      onSubmit: _submit,
      onStop: _stopTapped,
    ),
  );

  /// Where the person left this session last time; null in a test without one.
  LastSeen? _lastSeen;

  /// Agent screens' memory: what is in front, and this agent's draft.
  late final AgentScreens? _screens = widget.agent == null ? null : context.read<AgentScreens?>();

  /// The transcript is whole: its replay has finished (or the session ended
  /// and replays nothing more). Until then it must not be taken for what the
  /// person saw: a half-replayed list would mark them as having seen less
  /// (and "what is new" would count the history), so nothing is marked or
  /// asked before.
  bool _settled = false;

  /// The session was finished and not yet reviewed when the screen opened:
  /// the first mark is the person reviewing it, so it says so with the Undo
  /// every board review path has (`markSessionReviewedWithUndo`). A turn that
  /// ends while they look is seen quietly: they watched it end.
  late bool _reviewOnArrival = widget.session.unseenDone;

  /// The person took that review back (Undo): the finished turn stays to
  /// review while they look, until a new turn starts.
  bool _keptUnseen = false;

  /// How many items the danger check has looked at (see [announcesDanger]).
  int _announced = 0;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    _announced = widget.session.state.items.length;
    _toldAnswered = widget.session.answeredElsewhere;
    if (context.read<Dictation?>() case final dictation?) {
      _dictation = DictationSession(dictation: dictation, input: _input, focus: _focus, onProblem: _dictationProblem);
    }
    WidgetsBinding.instance.addObserver(this);
    widget.session
      ..acquire()
      ..addListener(_onSession);
    if (widget.agent case final agent?) {
      // What was typed for this agent before a swipe took it away, in either
      // of its views; kept outside the screen as it is typed.
      _input.text = _screens?.draftOf(agent) ?? '';
      _input.addListener(_keepDraft);
      _screens?.shown(this, agent, AgentView.chat);
    }
    // The screen holds the session itself now: the hold taken when a finger
    // went down on its row has done its work.
    widget.preconnect?.cancel();
    // After the first frame: markSeen notifies, and nothing may notify while
    // the tree is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _markShown();
      _checkSettled();
      // The gallery query and the first thumbnails are started now, so the
      // attach sheet opens onto pictures (never asks the system for anything;
      // only on the phone, or with a kit a test handed in).
      if (!widget.session.isObserved && (widget.attachKit != null || Platform.isAndroid)) _attachments.warm();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lastSeen = context.read<LastSeen?>();
  }

  @override
  void dispose() {
    // Leaving: what the person saw is everything there is now.
    _markLeft();
    _dictation?.dispose();
    _screens?.left(this, leaving: leavingInForeground());
    _input.removeListener(_keepDraft);
    WidgetsBinding.instance.removeObserver(this);
    widget.session
      ..removeListener(_onSession)
      ..release();
    _stopWindow?.cancel();
    _input.dispose();
    _attachments.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _keepDraft() {
    if (widget.agent case final agent?) _screens?.keepDraft(agent, _input.text);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _markShown();
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _markLeft();
  }

  /// What is on screen is the session as it is now: the live replay is whole,
  /// or the session ended and its transcript (not a saved copy) is all there
  /// is. A saved copy, a half-replayed list or a link still coming up may not
  /// hold the turn that finished, so it is never taken for the person having
  /// seen it (a failed connect would leave To review emptied, unseen).
  bool get _showsNow {
    final session = widget.session;
    if (session.cachedAsOf != null || session.state.replaying) return false;
    return session.link == AgentLink.live || (session.link == AgentLink.ended && session.state.items.isNotEmpty);
  }

  /// The person is looking at a finished turn: it is reviewed. Only while the
  /// screen is in front and shows the session as it is now ([_showsNow]).
  void _markShown() {
    final session = widget.session;
    if (session.phase != AgentPhase.idle) _reviewOnArrival = _keptUnseen = false;
    if (_keptUnseen || !_foreground || !session.unseenDone || !_showsNow) return;
    if (_reviewOnArrival) {
      _reviewOnArrival = false;
      markSessionReviewedWithUndo(context, session, onUndo: () => _keptUnseen = true);
    } else {
      session.markSeen();
    }
  }

  /// The person is leaving (the screen closes, or the app goes to the
  /// background): remember how much of the transcript they saw.
  void _markLeft() {
    if (!_settled) return;
    _lastSeen?.markSeen(widget.session.key, DateTime.now(), widget.session.state.items.length);
  }

  /// Once, when the replay is done: ask what happened since the person was
  /// last here and hand the answer to the transcript for its divider. Not on
  /// a session that is still connecting (its items are not there yet), and
  /// never again: what is new is what was new when they arrived.
  void _checkSettled() {
    if (_settled) return;
    final session = widget.session;
    if (session.state.replaying) return;
    // A live session has replayed; an ended one has what it had (nothing to
    // wait for), unless that is nothing.
    final ended = session.link == AgentLink.ended && session.state.items.isNotEmpty;
    if (session.link != AgentLink.live && !ended) return;
    _settled = true;
    unawaited(_resolveSinceLeft());
  }

  Future<void> _resolveSinceLeft() async {
    final seen = _lastSeen;
    if (seen == null) return;
    final since = await seen.sinceLeft(widget.session.key, widget.session.state);
    if (!mounted || since == null) return;
    setState(() => _transcript = TranscriptView(session: widget.session, sinceLeft: since));
  }

  /// A turn that ends while the person is looking is seen as it ends (and one
  /// that ended before they came, once the live replay shows it); a mode the
  /// agent put the session in that lowers the guard is felt once.
  void _onSession() {
    final session = widget.session;
    _markShown();
    _checkSettled();
    _checkStopped();
    _checkAnsweredElsewhere();
    final state = session.state;
    final count = state.items.length;
    if (count < _announced) _announced = count;
    if (count > _announced) {
      final from = _announced;
      _announced = count;
      if (announcesDanger(state, from)) Haptics.armed();
    }
  }

  /// The last request answered elsewhere that this screen has dealt with: one
  /// from before it opened is not news (set in [initState]).
  AnsweredElsewhere? _toldAnswered;

  /// A request in the dock was answered by another client first (the terminal
  /// on the computer): say who and how, once, so the dock does not just
  /// vanish. Not while the app is away, where nobody would read it: the
  /// transcript shows what the agent did next.
  void _checkAnsweredElsewhere() {
    final answered = widget.session.answeredElsewhere;
    if (answered == null || identical(answered, _toldAnswered)) return;
    _toldAnswered = answered;
    if (!mounted || !_foreground) return;
    showToast(context, answeredElsewhereText(answered));
  }

  /// The person asked to end the turn and it has not ended yet (or the agent
  /// has not said so). Armed by the Stop button, or by the session reporting
  /// the cancel; expires, so a later, unrelated turn end is never taken for it.
  bool _stopAsked = false;
  Timer? _stopWindow;

  static const _stopExpiry = Duration(seconds: 20);

  void _stopTapped() {
    _stopAsked = true;
    _stopWindow?.cancel();
    _stopWindow = Timer(_stopExpiry, () => _stopAsked = false);
  }

  /// After Stop: when the turn is over and background work still runs, say so
  /// once, with a way to look (`Turn stopped · 1 job still running`). Nothing
  /// when nothing remains: the stop row in the transcript is enough.
  void _checkStopped() {
    final session = widget.session;
    if (session.state.cancelRequested && !_stopAsked) _stopTapped();
    if (!_stopAsked) return;
    final turnOver = session.phase == AgentPhase.idle || session.waitingOnBackground;
    if (!turnOver || session.state.cancelRequested) return;
    _stopAsked = false;
    _stopWindow?.cancel();
    final text = stoppedToast(session.backgroundWork);
    if (text == null || !mounted) return;
    showBackgroundToast(context, text, onView: () => unawaited(showBackgroundWork(context, session)));
  }

  void _pickCommand(AcpCommand command) {
    final text = '/${command.name} ';
    _input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _focus.requestFocus();
  }

  /// An attachment that could not be made (too large, unreadable, no camera):
  /// said once, plainly, with the failure haptic.
  void _problem(String message) {
    if (!mounted) return;
    showToast(context, message, kind: ToastKind.failed);
  }

  /// A dictation that did not start or ended badly: what happened and what to
  /// do, in one toast. Hearing nothing is not a failure.
  void _dictationProblem(DictationProblem problem) {
    if (!mounted) return;
    showToast(
      context,
      problem.message,
      kind: problem == DictationProblem.silence ? ToastKind.info : ToastKind.failed,
    );
  }

  /// Sends the draft and what is attached to it. A live session takes it
  /// whatever the agent is doing: an idle one as a prompt, a working one as a
  /// message that waits (or steers the turn, where the agent takes that), see
  /// `AgentSessionView.delivery`. Not while a picture is still being prepared.
  /// An observed session (an agent in a terminal) only takes one when idle;
  /// the button is a stop while its turn runs and the keyboard's send key
  /// still lands here.
  ///
  /// The field empties at once (nothing visible waits for the agent); the
  /// haptic follows the outcome, as in the pane: `sent` when the session took
  /// the message, `failed` when it did not, and then the text and attachments
  /// come back, so a failed send loses nothing.
  void _submit() {
    final session = widget.session;
    if (session.link != AgentLink.live || session.sendBlocked != null) return;
    // An agent in a terminal says `working` while it waits on a job; that
    // wait is not a turn, so a message may go.
    if (session.isObserved &&
        session.relayNote == null &&
        session.phase != AgentPhase.idle &&
        !session.waitingOnBackground) {
      return;
    }
    if (!_attachments.canSend) return;
    final text = _input.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    final chips = _attachments.items;
    // Taken before the send: if the person leaves while it is out, the screen
    // is gone when it fails, and neither the toast overlay nor the draft's
    // store can be looked up from it then.
    final toaster = Toaster.maybeOf(context);
    final screens = _screens;
    _input.clear();
    unawaited(
      _send(session, text, chips, composePrompt(text, _attachments.take()), context.read<SentPhrases?>(), toaster, screens),
    );
  }

  Future<void> _send(
    AgentSessionView session,
    String text,
    List<Attachment> chips,
    List<ContentBlock> blocks,
    SentPhrases? learned,
    Toaster? toaster,
    AgentScreens? screens,
  ) async {
    final sent = await session.sendBlocks(blocks);
    if (sent) {
      Haptics.sent();
      if (learned != null) unawaited(learned.learn(text));
      return;
    }
    if (mounted) {
      Haptics.failed();
      _giveBack(text);
      _attachments.restore(chips);
      return;
    }
    _giveBackAfterLeaving(text, chips, toaster, screens);
  }

  /// The send failed after the person left this screen (Back, or a swipe to
  /// the next agent): the text goes back to the agent's draft, ahead of
  /// whatever was typed there since, and a toast (failed: it carries the
  /// haptic) says the message did not go. The chips live and die with the
  /// screen (a prepared picture or an upload has no home outside it), so the
  /// toast says they were not kept.
  void _giveBackAfterLeaving(String text, List<Attachment> chips, Toaster? toaster, AgentScreens? screens) {
    final agent = widget.agent;
    final keep = text.isNotEmpty && agent != null && screens != null;
    if (keep) {
      final newer = screens.draftOf(agent);
      screens.keepDraft(agent, newer.isEmpty ? text : '$text\n$newer');
    }
    final lost = chips.isEmpty ? '' : ' Its attachments were not kept: attach them again.';
    toaster?.show('${keep ? 'Not sent. Your message is back in the draft.' : 'Not sent.'}$lost', kind: ToastKind.failed);
  }

  /// Puts the text of a send that failed back in the field. What was typed
  /// while it was out is not ours to wipe: it stays, after the text that came
  /// back, with the cursor where it was.
  void _giveBack(String text) {
    if (text.isEmpty) return;
    final now = _input.value;
    if (now.text.isEmpty) {
      _input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      return;
    }
    final joined = '$text\n${now.text}';
    final shift = text.length + 1;
    final at = now.selection;
    _input.value = TextEditingValue(
      text: joined,
      selection: at.isValid
          ? TextSelection(baseOffset: at.baseOffset + shift, extentOffset: at.extentOffset + shift)
          : TextSelection.collapsed(offset: joined.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    notifyRegionBuilt('screen');
    final ds = context.ds;
    return Scaffold(
      backgroundColor: ds.bg,
      body: Column(
        children: [
          SessionBar(session: widget.session),
          _LinkStrip(session: widget.session, agent: widget.agent),
          Expanded(
            // Shares are worked out when the area is laid out, not when it is
            // built: the keyboard changes the area's height every frame of its
            // animation, and nothing inside may rebuild for that.
            child: CustomMultiChildLayout(
              delegate: _SessionLayout(),
              children: [
                LayoutId(id: _SessionLayout.plan, child: _plan),
                LayoutId(
                  id: _SessionLayout.transcript,
                  // A code block or a table that scrolls sideways keeps its
                  // swipe: it is not a step to the next agent.
                  child: switch (widget.agent) {
                    final agent? => AgentSwipeDetector(
                      enabled: true,
                      onSwipe: (delta) => swipeToAgent(context, agent, delta),
                      child: _transcript,
                    ),
                    null => _transcript,
                  },
                ),
                LayoutId(id: _SessionLayout.bottom, child: _bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Places the plan, the transcript and the bottom region (palette, request,
/// composer) in the room under the bar.
///
/// The bottom region comes first and takes what it needs up to
/// [_bottomShare]; the plan takes what it needs of the rest, leaving the
/// transcript a quarter of the area at least, or is not shown when less than
/// a header would fit; the transcript gets the remainder. Nothing here is
/// built again when the area's height changes.
class _SessionLayout extends MultiChildLayoutDelegate {
  _SessionLayout();

  static const plan = 'plan';
  static const transcript = 'transcript';
  static const bottom = 'bottom';

  /// The plan's header is this high; a plan given less is not drawn.
  static const _planHeader = 52.0;

  @override
  void performLayout(Size size) {
    final width = size.width;
    final bottomSize = layoutChild(
      bottom,
      BoxConstraints(minWidth: width, maxWidth: width, maxHeight: size.height * _bottomShare),
    );
    final rest = size.height - bottomSize.height;
    final planRoom = rest - size.height * 0.25;
    final planSize = layoutChild(
      plan,
      BoxConstraints(minWidth: width, maxWidth: width, maxHeight: planRoom < _planHeader ? 0 : planRoom),
    );
    layoutChild(transcript, BoxConstraints.tight(Size(width, rest - planSize.height)));
    positionChild(plan, Offset.zero);
    positionChild(transcript, Offset(0, planSize.height));
    positionChild(bottom, Offset(0, size.height - bottomSize.height));
  }

  @override
  bool shouldRelayout(_SessionLayout oldDelegate) => false;
}

/// Palette, request and composer, stacked at the bottom. The palette and the
/// request take the room the composer leaves (and scroll in it), so a phone
/// on its side with the keyboard up overflows nothing; the composer is the
/// last child and always stays in reach.
class _Bottom extends StatelessWidget {
  const _Bottom({required this.palette, required this.dock, required this.strip, required this.composer});

  final Widget palette;
  final Widget dock;

  /// What keeps running in the background; above the composer, takes no room
  /// when nothing does.
  final Widget strip;
  final Widget composer;

  @override
  Widget build(BuildContext context) {
    notifyRegionBuilt('bottom');
    // Toasts stand above the composer, not over it.
    return ToastShelf(
      aboveKeyboard: true,
      child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Flexible(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [palette, Flexible(child: dock)],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [strip, composer],
          ),
        ),
      ),
    ],
    ),
    );
  }
}

/// The board says this session needs the person, but its request cannot be
/// shown: the link is not live or the transcript is a saved copy (requests
/// come only with a live attach). The dock says so instead of being empty,
/// so the person knows they came to the right place and what to wait for.
/// Takes no room otherwise. Not for an agent in a terminal: what it asks may
/// only ever show there.
class _WaitsUntilLive extends StatelessWidget {
  const _WaitsUntilLive({required this.session});

  final AgentSessionView session;

  @override
  Widget build(BuildContext context) => SessionSelect<bool>(
    session: session,
    select: (s) {
      final blocked = s.phase == AgentPhase.blockedOnPermission || s.phase == AgentPhase.blockedOnQuestion;
      final docked = s.cachedAsOf == null && s.state.pending.isNotEmpty;
      return blocked && !docked && !s.isObserved && (s.link != AgentLink.live || s.cachedAsOf != null);
    },
    builder: (context, waits) {
      if (!waits) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
        child: StatusStrip(
          color: context.ds.blocked,
          title: 'Needs you',
          detail: 'Its request shows here once connected.',
          leading: const StatusGlyph(status: AgentStatus.blocked, size: 16),
        ),
      );
    },
  );
}

/// What the link is doing, when it is not live: connecting, reconnecting, the
/// session ended (with the reason), or failed. Takes no room when live. Over
/// a saved copy it says so first, in every one of those states.
class _LinkStrip extends StatelessWidget {
  const _LinkStrip({required this.session, required this.agent});

  final AgentSessionView session;

  /// The agent this chat shows (see [AgentSessionScreen.agent]).
  final AgentRef? agent;

  /// The terminal of the agent in a pane: this agent's other view, in place
  /// of the chat (the toggle's way); from a subagent's transcript, pushed
  /// over it, so Back returns to the transcript.
  void _openTerminal(BuildContext context) {
    final own = agent;
    if (own is PaneAgent) {
      unawaited(showAgentView(context, own, AgentView.terminal));
    } else {
      final pane = PaneAgent(session.machine.profile.id, session.terminalPaneId!);
      unawaited(openAgent(context, pane, view: AgentView.terminal));
    }
  }

  @override
  Widget build(BuildContext context) => SessionSelect<(AgentLink, String?, bool, bool, bool, AuthNeeded?, DateTime?, bool)>(
    session: session,
    select: (s) =>
        (s.link, s.error, s.evicted, s.isObserved, s.needsTerminal, s.authNeeded, s.cachedAsOf, s.resumeTarget != null),
    builder: (context, v) {
      final (link, error, evicted, observed, needsTerminal, auth, cachedAsOf, resumable) = v;
      final ds = context.ds;
      // An agent in a terminal: its log cannot be read, or it waits on
      // something only the terminal can show or answer. The terminal is the
      // way out of both.
      final openTerminal = observed && session.terminalPaneId != null
          ? AppButton(
              label: 'Open terminal',
              compact: true,
              kind: AppButtonKind.secondary,
              onPressed: () => _openTerminal(context),
            )
          : null;
      // The agent wants a login. The phone signs in nowhere: the panel says
      // so and opens a terminal on the host (live, or failed to attach for
      // it; its own "Try again" is the way back). It scrolls inside a share of
      // the window and goes in the compact layout (landscape with the
      // keyboard up), where there is no room for it.
      if (auth != null && (link == AgentLink.live || link == AgentLink.failed)) {
        return HideWhenCompact(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
                child: AuthPanel(session: session),
              ),
            ),
          ),
        );
      }
      if (link == AgentLink.live) {
        if (needsTerminal) {
          return _strip(
            color: ds.blocked,
            state: LinkState.attention,
            title: 'Waiting for you in the terminal',
            detail: 'It asks something the chat cannot show.',
            action: openTerminal,
          );
        }
        if (error != null) {
          return _strip(
            color: ds.danger,
            state: LinkState.attention,
            title: 'Something went wrong',
            detail: error,
            action: openTerminal,
          );
        }
        return const SizedBox.shrink();
      }
      final action = evicted ? 'Take over' : (link == AgentLink.failed && !observed ? 'Retry' : null);
      // The keeper is gone but the agent still has the conversation.
      final canContinue = link == AgentLink.ended && !evicted && resumable;
      final (color, state, title, fallback) = switch (link) {
        AgentLink.connecting when cachedAsOf != null => (ds.working, LinkState.connecting, 'Updating…', null),
        AgentLink.connecting => (ds.working, LinkState.connecting, 'Connecting…', null),
        AgentLink.reconnecting => (
          ds.working,
          LinkState.reconnecting,
          'Reconnecting…',
          observed ? 'The agent keeps running in its terminal.' : 'The agent keeps running on the host.',
        ),
        AgentLink.ended => (
          ds.textTertiary,
          LinkState.offline,
          evicted ? 'Taken over' : 'Session ended',
          null,
        ),
        AgentLink.failed => (
          ds.danger,
          LinkState.attention,
          observed ? 'Can’t read the session log' : 'Couldn’t connect',
          null,
        ),
        AgentLink.live => (ds.done, LinkState.online, '', null),
      };
      return _strip(
        color: color,
        state: state,
        title: title,
        detail: _withCopy(cachedAsOf, canContinue ? _keptByAgent(error) : error ?? fallback),
        // Beside the button the strip is short of room: a tap shows it all.
        expandFrom: canContinue ? 40 : 70,
        action: canContinue
            ? ContinueButton(session: session)
            : link == AgentLink.failed && openTerminal != null
            ? openTerminal
            : action == null
            ? null
            : AppButton(
                label: action,
                compact: true,
                kind: AppButtonKind.secondary,
                onPressed: () => unawaited(session.reattach()),
              ),
      );
    },
  );

  /// What Continue brings back, then the reason the session ended.
  static String _keptByAgent(String? reason) {
    const kept = 'The agent kept the conversation.';
    final said = reason?.trim() ?? '';
    return said.isEmpty ? kept : '$kept $said';
  }

  /// [said] after the saved copy's note when the transcript is one
  /// ([cachedAsOf]). Named in every state but live, not only while
  /// connecting: after a failed connect or a drop the copy would otherwise
  /// read as the live session, and nothing in it can be answered.
  static String? _withCopy(DateTime? cachedAsOf, String? said) {
    if (cachedAsOf == null) return said;
    final copy = savedCopyNotice(cachedAsOf, DateTime.now());
    return said == null || said.trim().isEmpty ? copy : '$copy $said';
  }

  Widget _strip({
    required Color color,
    required LinkState state,
    required String title,
    required String? detail,
    int expandFrom = 70,
    Widget? action,
  }) => Builder(
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
      child: StatusStrip(
        color: color,
        title: title,
        detail: detail,
        leading: LinkDot(state: state),
        action: action,
        onTap: detail != null && detail.length > expandFrom ? () => _showReason(context, title, detail) : null,
      ),
    ),
  );

  void _showReason(BuildContext context, String title, String reason) {
    unawaited(
      showAppSheet<void>(
        context,
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xl, Gap.gutter, Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: Text(title, style: Type.title.copyWith(color: ctx.ds.text))),
              const SizedBox(height: Gap.sm),
              SelectableText(reason, style: Type.compact.copyWith(color: ctx.ds.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
