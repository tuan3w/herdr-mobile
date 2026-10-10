import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/acp/prompt_content.dart' show composePrompt;
import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/observed_sessions.dart';
import '../../../data/repositories/attach_target.dart' show AttachMode;
import '../../../data/repositories/sent_phrases.dart';
import '../../../data/repositories/pane_attach_target.dart';
import '../../../data/repositories/command_source.dart';
import '../../../data/repositories/slash_catalog.dart';
import '../../../data/repositories/slash_usage.dart';
import '../../../data/repositories/terminal_prompt.dart';
import '../../../data/repositories/terminal_settings.dart';
import '../../../data/services/dictation.dart';
import '../../../data/services/image_prep.dart' show PreparedImage, prepareImage;
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/terminal_links.dart';
import '../../core/terminal_view.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../agents/agent_navigation.dart';
import '../agents/agent_swipe.dart';
import '../agent_session/attach_chips.dart';
import '../agent_session/attach_model.dart';
import '../agent_session/attach_picker.dart';
import '../agent_session/attach_sheet.dart';
import '../attach/attach_kit.dart';
import '../composer/composer_frame.dart';
import '../create/new_agent_session_screen.dart' show openNewAgentSession;
import '../create/session_prefill.dart' show SessionPrefill;
import '../dictation/dictation_language_sheet.dart';
import '../dictation/dictation_session.dart';
import '../files/files_navigation.dart';
import 'answer_dock.dart';
import 'connect_chat.dart';
import 'key_modifiers.dart';
import 'live_edge.dart';
import 'link_sheet.dart';
import 'pane_bar.dart';
import 'pane_view_model.dart';
import 'quick_keys.dart';
import 'quick_phrases_row.dart';
import '../composer/command_model.dart';
import '../composer/command_palette.dart';

/// Screens shorter than this (a phone on its side) get a lower bar and no
/// docked answers: a question and its chips would leave the terminal a few rows.
const shortScreen = 520.0;

/// One agent's terminal, one screen: the slim bar ([PaneTopBar]), then the
/// pane's banner, terminal, answer dock, quick keys and composer. A swipe on
/// the terminal goes to the next agent in the board's order (it replaces this
/// screen, so Back still goes to the board); the options sheet's `Show chat`
/// shows the same agent's chat when it has one.
///
/// The screen owns the pane's view model, made from the machine's current
/// connection and made again when that connection is replaced (the machine
/// was edited). The draft lives in [AgentScreens], not here, so it is there
/// again when the person comes back to this agent.
class PaneScreen extends StatefulWidget {
  const PaneScreen({
    super.key,
    required this.agent,
    this.picker = const DevicePicker(),
    this.prepare = prepareImage,
    this.attachKit,
    this.readFile,
  });

  final PaneAgent agent;

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
  State<PaneScreen> createState() => _PaneScreenState();
}

class _PaneScreenState extends State<PaneScreen> {
  late final FleetRepository _fleet = context.read<FleetRepository>();
  late final TerminalSettings _settings = context.read<TerminalSettings>();
  late final AgentScreens? _screens = context.read<AgentScreens?>();

  /// What the bar shows; the last one of a pane that was there is kept for
  /// when it goes.
  final _title = ValueNotifier<PaneTitle?>(null);
  PaneTitle? _known;

  MachineConnection? _machine;
  PaneViewModel? _vm;

  /// Built once per view model, so a rebuild of the screen (the bar's
  /// toggle, a machine change) rebuilds none of the pane.
  Widget? _page;

  String get _paneId => widget.agent.paneId;

  @override
  void initState() {
    super.initState();
    _fleet.addListener(_onFleet);
    _sync();
    _screens?.shown(this, widget.agent, AgentView.terminal);
  }

  @override
  void dispose() {
    _screens?.left(this, leaving: leavingInForeground());
    _fleet.removeListener(_onFleet);
    _title.dispose();
    _vm?.dispose();
    super.dispose();
  }

  void _onFleet() {
    if (_sync() && mounted) setState(() {});
  }

  /// Follows the machine's connection (a new view model when it was
  /// replaced, none when the machine was removed) and the bar's title.
  /// Returns whether the page changed.
  bool _sync() {
    final machine = _fleet.connection(widget.agent.machineId);
    var changed = false;
    if (!identical(machine, _machine)) {
      changed = true;
      final old = _vm;
      // Its page is still mounted until the next frame.
      if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      _machine = machine;
      final vm = _vm = machine == null ? null : PaneViewModel.forMachine(machine, _paneId, wrap: _settings.wrap);
      _page = machine == null || vm == null
          ? null
          : KeyedSubtree(
              key: ObjectKey(vm),
              child: _PaneBody(
                machine: machine,
                agent: widget.agent,
                viewModel: vm,
                picker: widget.picker,
                prepare: widget.prepare,
                attachKit: widget.attachKit,
                readFile: widget.readFile,
              ),
            );
    }
    final title = paneTitle(
      machine,
      widget.agent.machineId,
      _paneId,
      known: _known,
      named: _fleet.agent(widget.agent.machineId, _paneId)?.betterTitle,
    );
    if (title.status != null) _known = title;
    _title.value = title;
    return changed;
  }

  void _toggleWrap() {
    Haptics.tick();
    final next = !_settings.wrap;
    _vm?.setWrap(next);
    unawaited(_settings.setWrap(next));
  }

  void _openFiles(MachineConnection machine) {
    unawaited(openFileBrowser(context, machine, startDir: machine.paneById(_paneId)?.cwd));
  }

  /// Opens the new-agent-session form on the pane's machine, folder and agent,
  /// the first message empty. Not while the machine is offline or the pane is
  /// gone (there is nothing to copy it from).
  SheetAction _duplicateAction() {
    final machine = _machine;
    final pane = machine?.paneById(_paneId);
    final reason = machine == null
        ? 'That machine was removed'
        : !machine.isLive
        ? '${machine.profile.label} is offline'
        : pane == null
        ? 'The pane is gone'
        : null;
    return SheetAction(
      label: 'Duplicate',
      icon: LucideIcons.copyPlus,
      unavailable: reason,
      onTap: () {
        if (pane == null || !mounted) return;
        unawaited(
          openNewAgentSession(
            context,
            prefill: SessionPrefill(
              machineId: widget.agent.machineId,
              folder: pane.cwd ?? '',
              agent: pane.agent,
            ),
          ),
        );
      },
    );
  }

  void _showActions() {
    final title = _title.value?.title ?? _paneId;
    final machine = _machine;
    final observed = context.read<ObservedSessions?>();
    // An agent the app could read as a chat if herdr knew its session.
    final connectTarget = machine == null ? null : observed?.integrationFor(machine, _paneId);
    Haptics.tick();
    unawaited(
      showActionSheet(
        context,
        title: title,
        actions: [
          // An agent whose log the app can follow has its chat as well.
          if (machine != null && observed != null && observed.supports(machine, _paneId))
            agentViewAction(context, widget.agent, AgentView.terminal),
          if (machine != null && connectTarget != null)
            SheetAction(
              label: 'Read as chat…',
              icon: LucideIcons.messageSquare,
              onTap: () => unawaited(showConnectChat(context, machine, _paneId, connectTarget)),
            ),
          _duplicateAction(),
          SheetAction(
            label: 'Copy title',
            icon: LucideIcons.copy,
            onTap: () => unawaited(Clipboard.setData(ClipboardData(text: title))),
          ),
          SheetAction(
            label: 'Copy pane id $_paneId',
            icon: LucideIcons.hash,
            onTap: () => unawaited(Clipboard.setData(ClipboardData(text: _paneId))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final machine = _machine;
    final vm = _vm;
    return CompactScope(
      child: Scaffold(
        body: Column(
          children: [
            _Chrome(
              bar: PaneTopBar(
                title: _title,
                viewModel: vm,
                actions: PaneBarActions(
                  machine: machine,
                  onToggleWrap: vm == null ? null : _toggleWrap,
                  onOpenFiles: machine == null ? null : () => _openFiles(machine),
                  onMore: _showActions,
                ),
              ),
            ),
            Expanded(child: _page ?? const _MissingMachine()),
          ],
        ),
      ),
    );
  }
}

/// The chrome above the pane: the one slim bar ([PaneTopBar]). Landscape with
/// the keyboard up ([compactLayout]): none, only the terminal and composer fit.
class _Chrome extends StatelessWidget {
  const _Chrome({required this.bar});

  final Widget bar;

  @override
  Widget build(BuildContext context) => compactLayout(context) ? const SizedBox.shrink() : bar;
}

/// The pane's machine was removed: nothing to read from. Back (the bar's)
/// leaves.
class _MissingMachine extends StatelessWidget {
  const _MissingMachine();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.serverOff, size: 28, color: ds.textTertiary),
            const SizedBox(height: Gap.md),
            Text(
              'This machine is no longer saved',
              textAlign: TextAlign.center,
              style: Type.row.copyWith(color: ds.text),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pane itself under the bar: its machine and view model as providers for
/// the regions, and the page that composes them.
class _PaneBody extends StatelessWidget {
  const _PaneBody({
    required this.machine,
    required this.agent,
    required this.viewModel,
    required this.picker,
    required this.prepare,
    this.attachKit,
    this.readFile,
  });

  final MachineConnection machine;
  final PaneAgent agent;
  final PaneViewModel viewModel;
  final AttachPicker picker;
  final Future<PreparedImage> Function(Uint8List input) prepare;
  final AttachKit? attachKit;
  final Future<Uint8List> Function(String path)? readFile;

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: machine),
      ChangeNotifierProvider.value(value: viewModel),
    ],
    child: _PaneView(agent: agent, picker: picker, prepare: prepare, attachKit: attachKit, readFile: readFile),
  );
}

/// Tells the pane regions whether the layout is compact: landscape with the
/// keyboard up. It sits ABOVE the screen's `Scaffold`, which strips the
/// keyboard inset from what its body sees, and only notifies when the answer
/// changes (the inset itself changes every frame of the keyboard animation).
class CompactScope extends StatelessWidget {
  const CompactScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _Compact(
        compact: MediaQuery.orientationOf(context) == Orientation.landscape &&
            MediaQuery.viewInsetsOf(context).bottom > 0,
        child: child,
      );
}

class _Compact extends InheritedWidget {
  const _Compact({required this.compact, required super.child});

  final bool compact;

  @override
  bool updateShouldNotify(_Compact old) => old.compact != compact;
}

/// Whether the screen shows only the terminal and composer (see [CompactScope]).
bool compactLayout(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_Compact>()?.compact ?? false;

/// Owns what outlives a rebuild (the composer's text, the keys toggle) and
/// composes the regions. Every region selects only what it shows, so a
/// notify about some other pane rebuilds nothing here.
class _PaneView extends StatefulWidget {
  const _PaneView({required this.agent, required this.picker, required this.prepare, this.attachKit, this.readFile});

  final PaneAgent agent;
  final AttachPicker picker;
  final Future<PreparedImage> Function(Uint8List input) prepare;
  final AttachKit? attachKit;
  final Future<Uint8List> Function(String path)? readFile;

  @override
  State<_PaneView> createState() => _PaneViewState();
}

class _PaneViewState extends State<_PaneView> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _mods = StickyModifiers();
  late final PaneViewModel _vm = context.read<PaneViewModel>();
  late final _typing = ModifierTypingFormatter(_mods, _pressChord);
  late final _target = PaneAttachTarget(context.read<MachineConnection>(), _paneId);

  /// Pictures and files of the draft, as long as this page lives: a replaced
  /// connection builds a new page and drops them.
  late final ComposerAttachments _attachments = ComposerAttachments(
    target: _target,
    picker: widget.picker,
    prepare: widget.prepare,
    kit: widget.attachKit,
    readFile: widget.readFile ?? ComposerAttachments.readDeviceFile,
    onProblem: (m) => showToast(context, m, kind: ToastKind.failed),
  );
  late final AgentScreens? _screens = context.read<AgentScreens?>();
  bool _keysOpen = false;

  /// Dictation into the composer; null without a speech service (tests).
  DictationSession? _dictation;

  /// True while the answer dock shows a question; the dock keeps it.
  final _dockAsking = ValueNotifier(false);

  String get _paneId => widget.agent.paneId;

  late final _commandSource = _newCommandSource(context.read<MachineConnection>());
  late final _commands = CommandPaletteModel(source: _commandSource, usage: context.read<SlashUsage?>());

  CatalogCommandSource _newCommandSource(MachineConnection machine) => CatalogCommandSource(
        agent: () => machine.paneById(_paneId)?.agent,
        cwd: () => machine.paneById(_paneId)?.cwd,
        catalog: SlashCatalog(machine.files),
      );

  @override
  void initState() {
    super.initState();
    // What was typed for this agent before a swipe took it away, in either
    // of its views.
    _input.text = _screens?.draftOf(widget.agent) ?? '';
    _input.addListener(_onInput);
    // The gallery query and the first thumbnails are started now, so the
    // attach sheet opens onto pictures (never asks the system for anything;
    // only on the phone, or with a kit a test handed in).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_target.attachMode != AttachMode.none && (widget.attachKit != null || Platform.isAndroid)) {
        _attachments.warm();
      }
    });
    if (context.read<Dictation?>() case final dictation?) {
      _dictation = DictationSession(dictation: dictation, input: _input, focus: _focus, onProblem: _dictationProblem);
    }
  }

  @override
  void dispose() {
    _dictation?.dispose();
    _input.removeListener(_onInput);
    _input.dispose();
    _focus.dispose();
    _mods.dispose();
    _commands.dispose();
    _commandSource.dispose();
    _attachments.dispose();
    _dockAsking.dispose();
    super.dispose();
  }

  /// A `/` or `$` at the start of the composer is the cue to learn the commands.
  /// The draft is kept outside the screen as it is typed.
  void _onInput() {
    _screens?.keepDraft(widget.agent, _input.text);
    final text = _input.text;
    if (text.startsWith('/') || text.startsWith(r'$')) _commands.ensureLoaded();
  }

  /// A key row key, with Ctrl/Alt in front when one is armed.
  Future<void> _pressKeys(List<String> keys) async {
    final pressed = _mods.apply(keys);
    // The key already ticked; a refused Enter only says why.
    if (_refusesEnter(pressed)) return;
    if (!await _vm.sendKeys(pressed)) Haptics.failed();
  }

  /// A bare Enter while the dock shows a question would choose whatever option
  /// the agent has highlighted, past the dock's hold and its guard: it is
  /// refused, and a toast points at the answers. Arrows, Esc and a modified
  /// Enter still go through: those are deliberate moves in the agent's menu.
  bool _refusesEnter(List<String> keys) {
    if (!_dockAsking.value || keys.length != 1 || keys.single != 'enter') return false;
    showToast(context, 'Pick an answer above');
    return true;
  }

  /// A character typed while Ctrl/Alt was armed, already a combo.
  void _pressChord(String combo) {
    Haptics.tick();
    _vm.sendKeys([combo]);
  }

  /// Types [text] into the composer at the cursor and brings the keyboard up.
  void _insert(String text) {
    final value = _input.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _input.value = value.copyWith(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
    _focus.requestFocus();
  }

  /// Opens the attach sheet for this pane's agent.
  void _openAttach() => unawaited(showAttachSheet(context, target: _target, attachments: _attachments));

  /// Types the composer's text and presses enter. With nothing but whitespace
  /// in it, only presses enter (what the keyboard's send key does on an empty
  /// field), so a stray space is never typed into the pane; not while the dock
  /// shows a question (see [_refusesEnter]).
  ///
  /// With pictures or files attached the message goes as a prompt: each
  /// picture's path pasted, then the line with the text and the files' paths
  /// ([terminalPrompt]); it waits while one is still being prepared or
  /// uploaded, and the chips come back when the send fails.
  Future<void> _submit() async {
    if (_vm.sending) return;
    final text = _input.text;
    final chips = _attachments.items;
    if (text.trim().isEmpty && chips.isEmpty) {
      if (_refusesEnter(const ['enter'])) {
        Haptics.tick();
        return;
      }
      _input.clear();
      // The haptic follows the outcome: a heavy one for a failure, so it
      // cannot be mistaken for the click of a send that went out.
      final ok = await _vm.sendKeys(const ['enter']);
      if (ok) {
        Haptics.sent();
      } else {
        Haptics.failed();
      }
      return;
    }
    final bool sent;
    if (chips.isEmpty) {
      sent = await _vm.sendLine(text);
    } else {
      if (!_attachments.canSend) return;
      final prompt = terminalPrompt(composePrompt(text.trim(), _attachments.take()));
      if (prompt == null) {
        _attachments.restore(chips);
        showToast(context, 'This agent runs in a terminal; one attachment cannot be sent to it.', kind: ToastKind.failed);
        Haptics.failed();
        return;
      }
      sent = await _vm.sendPrompt(prompt);
      if (!sent) _attachments.restore(chips);
    }
    if (sent) {
      Haptics.sent();
    } else {
      Haptics.failed();
    }
    if (sent) _commands.recordSent(text);
    // A line typed into a shell is a command, not a phrase: only an agent's prompt is learned.
    if (sent && text.trim().isNotEmpty && mounted && context.read<MachineConnection>().paneById(_paneId)?.agent != null) {
      unawaited(context.read<SentPhrases?>()?.learn(text) ?? Future<void>.value());
    }
    // Leaving mid-send disposes the controller. What was typed while it was in
    // flight is not ours to wipe: only the text that went out is removed.
    if (sent && mounted) {
      final now = _input.text;
      if (now == text) {
        _input.clear();
      } else if (now.startsWith(text)) {
        final rest = now.substring(text.length);
        _input.value = TextEditingValue(text: rest, selection: TextSelection.collapsed(offset: rest.length));
      }
    }
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

  void _retry() {
    _vm.clearSendError();
    context.read<MachineConnection>().retry();
    _vm.refresh();
  }

  /// A link in the output was tapped: a web address shows its sheet; a path
  /// opens in the file viewer (or browser, for a directory), found from the
  /// pane's folder when it is relative.
  void _openLink(TerminalLink link) {
    Haptics.tick();
    final machine = context.read<MachineConnection>();
    switch (link.kind) {
      case TerminalLinkKind.url:
        unawaited(showLinkSheet(context, link.target));
      case TerminalLinkKind.path:
        unawaited(
          openRemoteFile(
            context,
            machine,
            link.target,
            cwd: machine.paneById(_paneId)?.cwd,
            line: link.line,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => _PaneLayout(
        keysOpen: _keysOpen,
        onToggleKeys: () => setState(() => _keysOpen = !_keysOpen),
        banner: _Banner(paneId: _paneId, onRetry: _retry),
        // A table wider than the view, or a terminal wider than the phone
        // with wrap off, scrolls sideways: that swipe is theirs, not a step
        // to the next agent.
        terminal: AgentSwipeDetector(
          enabled: true,
          onSwipe: (delta) => swipeToAgent(context, widget.agent, delta),
          child: _TerminalPanel(paneId: _paneId, onLinkTap: _openLink),
        ),
        palette: CommandPalette(
          input: _input,
          model: _commands,
          onPick: (command) => fillCommand(_input, _focus, command),
        ),
        dock: AnswerDock(paneId: _paneId, asking: _dockAsking),
        keys: QuickKeys(
          paneId: _paneId,
          modifiers: _mods,
          onKeys: _pressKeys,
          onInsert: _insert,
        ),
        phrases: QuickPhrasesRow(
          input: _input,
          focus: _focus,
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        ),
        chips: AttachmentChips(attachments: _attachments),
        composer: _Composer(
          paneId: _paneId,
          controller: _input,
          focusNode: _focus,
          typing: _typing,
          onSubmit: _submit,
          dictation: _dictation,
          attachments: _attachments,
          onAttach: _openAttach,
        ),
      );
}

/// Stacks the regions under the screen's bar. With the keyboard up in
/// landscape there is room for little more than the terminal, so the screen
/// drops its bar ([compactLayout]) and the quick keys wait behind a
/// toggle beside the composer.
///
/// The regions are built by the caller and only placed here: this widget
/// depends on the window insets, which change every frame of the keyboard's
/// animation, and must not rebuild them.
class _PaneLayout extends StatelessWidget {
  const _PaneLayout({
    required this.banner,
    required this.terminal,
    required this.palette,
    required this.dock,
    required this.phrases,
    required this.keys,
    required this.chips,
    required this.composer,
    required this.keysOpen,
    required this.onToggleKeys,
  });

  final Widget banner;
  final Widget terminal;
  final Widget palette;
  final Widget dock;
  final Widget keys;
  final Widget phrases;
  final Widget chips;
  final Widget composer;
  final bool keysOpen;
  final VoidCallback onToggleKeys;

  @override
  Widget build(BuildContext context) {
    final compact = compactLayout(context);
    final top = MediaQuery.paddingOf(context).top;
    final short = MediaQuery.sizeOf(context).height < shortScreen;
    return Column(
        children: [
          banner,
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                Gap.lg,
                compact ? top + Gap.xs : Gap.xs,
                Gap.lg,
                compact ? Gap.xs : Gap.sm,
              ),
              child: terminal,
            ),
          ),
          // Toasts stand above all of this (the keys and the composer), not
          // over it.
          ToastShelf(
            aboveKeyboard: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
          if (!compact) palette,
          if (!compact && !short) dock,
          if (!compact || keysOpen) keys,
          if (!compact && !short) phrases,
          if (!compact) Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.lg), child: chips),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, compact ? Gap.xs : Gap.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (compact)
                    SizedBox(
                      height: composerMinHeight,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.only(right: Gap.sm),
                          child: CircleButton(
                            icon: LucideIcons.keyboard,
                            tooltip: keysOpen ? 'Hide keys' : 'Show keys',
                            active: keysOpen,
                            onPressed: onToggleKeys,
                          ),
                        ),
                      ),
                    ),
                  Expanded(child: composer),
                ],
              ),
            ),
          ),
              ],
            ),
          ),
        ],
    );
  }
}

/// The terminal in its dark rounded panel. The outline is drawn over the
/// content, so scrolling rows never paint across it.
class _TerminalPanel extends StatelessWidget {
  const _TerminalPanel({required this.paneId, required this.onLinkTap});

  final String paneId;
  final ValueChanged<TerminalLink> onLinkTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Radii.panel);
    final palette = context.terminal;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: palette.border),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: ColoredBox(
          color: palette.background,
          child: Builder(
            builder: (context) {
              final (fontSize, wrap) = context.select<TerminalSettings, (double, bool)>(
                (s) => (s.fontSize, s.wrap),
              );
              // What it shows is a pane that is gone, or a link or read that
              // is down: dimmed, not live. A closed pane is not "stale".
              final machine = context.select<
                  MachineConnection,
                  ({bool closed, bool linkDown, bool blocked})>(
                (m) => (
                  closed: m.isLive && m.paneById(paneId) == null,
                  linkDown: !m.isLive,
                  blocked: m.isLive &&
                      m.paneById(paneId)?.status == AgentStatus.blocked,
                ),
              );
              final read = context.select<PaneViewModel, ({bool failed, bool streaming})>(
                (v) => (failed: v.isStale, streaming: v.streaming),
              );
              final closed = machine.closed;
              final stale = !closed && (read.failed || machine.linkDown);
              final settings = context.read<TerminalSettings>();
              final vm = context.read<PaneViewModel>();
              final content = context.select<
                  PaneViewModel,
                  ({List<String> history, String text, TerminalTop top})>(
                (v) => (history: v.history, text: v.text, top: v.top),
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  TerminalView(
                    history: content.history,
                    text: content.text,
                    top: content.top,
                    blocked: machine.blocked,
                    onLinkTap: onLinkTap,
                    onScrollChanged: (s) => vm.viewChanged(
                      nearTop: s.nearTop,
                      following: s.following,
                    ),
                    fontSize: fontSize,
                    wrap: wrap,
                    onFontSizeChanged: settings.previewFontSize,
                    onFontSizeEnd: (size) => unawaited(settings.setFontSize(size)),
                  ),
                  if (closed || stale)
                    IgnorePointer(
                      child: ColoredBox(
                        color: palette.background.withValues(alpha: 0.6),
                      ),
                    ),
                  // Inside the 1 px outline, which is drawn over the content.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(1, 0, 1, 1),
                    child: LiveEdge(
                      stale: stale,
                      failed: read.failed,
                      streaming: read.streaming,
                      lastRead: () => vm.lastRead,
                      now: vm.clock,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// What is wrong, if anything: the link, a pane that is gone, or the last
/// read or send.
class _Problem {
  const _Problem({
    required this.title,
    this.detail,
    required this.color,
    required this.icon,
    required this.retry,
  });

  final String title;
  final String? detail;
  final Color color;
  final IconData icon;
  final bool retry;
}

/// One strip under the top bar. It remembers the last problem so that it can
/// animate closed with its content instead of emptying first.
class _Banner extends StatefulWidget {
  const _Banner({required this.paneId, required this.onRetry});

  final String paneId;
  final VoidCallback onRetry;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  _Problem? _last;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final id = widget.paneId;
    final link = context.select<MachineConnection, ({LinkState state, String? error, bool open})>(
      (m) => (state: m.state, error: m.error, open: m.paneById(id) != null),
    );
    final readError = context.select<PaneViewModel, String?>((v) => v.error);

    final _Problem? problem;
    if (link.state != LinkState.online) {
      problem = _Problem(
        title: link.state.label,
        detail: link.error,
        color: link.state.color(ds),
        icon: switch (link.state) {
          LinkState.connecting => LucideIcons.loader,
          LinkState.attention => LucideIcons.triangleAlert,
          LinkState.approval => LucideIcons.keyRound,
          LinkState.disabled => LucideIcons.ban,
          _ => LucideIcons.wifiOff,
        },
        // Approval waits on a person elsewhere; retrying does nothing.
        retry: link.state != LinkState.approval,
      );
    } else if (!link.open) {
      problem = _Problem(
        title: 'This pane was closed',
        color: ds.textSecondary,
        icon: LucideIcons.squareX,
        retry: false,
      );
    } else if (readError != null) {
      problem = _Problem(
        title: readError,
        color: ds.danger,
        icon: LucideIcons.circleAlert,
        retry: true,
      );
    } else {
      problem = null;
    }
    if (problem != null) _last = problem;

    final shown = _last;
    return Collapse(
      open: problem != null,
      child: shown == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xs),
              child: StatusStrip(
                color: shown.color,
                leading: Icon(shown.icon, size: 18, color: shown.color),
                title: shown.title,
                detail: shown.detail,
                action: shown.retry
                    ? AppButton(
                        label: 'Retry',
                        kind: AppButtonKind.secondary,
                        compact: true,
                        onPressed: widget.onRetry,
                      )
                    : null,
              ),
            ),
    );
  }
}

/// Rounded multi-line input between a paperclip (an agent's prompt only) and a
/// round send button. Grows to five lines, then scrolls.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.paneId,
    required this.controller,
    required this.focusNode,
    required this.typing,
    required this.onSubmit,
    required this.attachments,
    required this.onAttach,
    this.dictation,
  });

  final String paneId;
  final TextEditingController controller;
  final FocusNode focusNode;
  final TextInputFormatter typing;
  final VoidCallback onSubmit;

  /// Pictures and files that go out with the draft.
  final ComposerAttachments attachments;

  /// The paperclip was tapped.
  final VoidCallback onAttach;

  /// Dictation into the field, offered for an agent's prompt only (a line for a
  /// shell is not something to speak). The mic takes Send's place while the
  /// field is empty.
  final DictationSession? dictation;

  @override
  Widget build(BuildContext context) {
    final (state, open, agent) = context.select<MachineConnection, (LinkState, bool, String?)>(
      (m) {
        final pane = m.paneById(paneId);
        return (m.state, pane != null, pane?.agent);
      },
    );
    final sending = context.select<PaneViewModel, bool>((v) => v.sending);
    final enabled = state == LinkState.online && open;
    final hint = switch (state) {
      LinkState.online => open ? 'Message ${agent ?? 'pane'}…' : 'Pane closed',
      LinkState.connecting => 'Connecting…',
      LinkState.approval => 'Waiting for sign-in approval',
      LinkState.reconnecting || LinkState.offline => 'Offline — reconnecting',
      LinkState.attention => 'Needs attention — see above',
      LinkState.disabled => 'Machine disabled',
    };
    return ComposerFrame(
      // An agent's prompt takes pictures and files, as the chat's does; a
      // shell's line takes none, as it takes no dictation. In the compact
      // layout the chips are gone and the paperclip says how many go along.
      leading: agent == null
          ? null
          : ListenableBuilder(
              listenable: attachments,
              builder: (context, _) => ComposerAttachButton(
                enabled: enabled,
                count: compactLayout(context) ? attachments.items.length : 0,
                onPressed: onAttach,
                onWarm: attachments.warm,
              ),
            ),
      field: ListenableBuilder(
        // The hint says why Send waits while a picture or a file is still on
        // its way.
        listenable: attachments,
        builder: (context, _) => ComposerField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          hint: enabled ? attachments.waitingReason ?? hint : hint,
          onSubmit: onSubmit,
          // A shell's line stays in the terminal's font; an agent's prompt is
          // prose, as in the chat.
          mono: agent == null,
          inputFormatters: [typing],
          autocorrect: agent != null,
          enableSuggestions: agent != null,
          hasLeading: agent != null,
          keyboardOnPointerDown: enabled,
        ),
      ),
      trailing: ListenableBuilder(
        listenable: Listenable.merge([controller, attachments, ?dictation]),
        builder: (context, _) {
          final hasContent = controller.text.trim().isNotEmpty || !attachments.isEmpty;
          final dictate = agent == null ? null : dictation;
          if (dictate != null && enabled && (dictate.listening || !hasContent)) {
            return ComposerRoundButton(
              label: dictate.listening ? 'Stop dictating' : 'Dictate',
              icon: LucideIcons.mic,
              iconSize: 18,
              ready: true,
              quiet: !dictate.listening,
              onPressed: () => unawaited(dictate.toggle()),
              onLongPress: dictate.listening
                  ? null
                  : () => unawaited(showDictationLanguageSheet(context, dictate.dictation)),
            );
          }
          return ComposerRoundButton(
            label: 'Send',
            icon: LucideIcons.arrowUp,
            iconSize: 18,
            ready: enabled && !sending && hasContent && attachments.canSend,
            busy: sending,
            onPressed: onSubmit,
          );
        },
      ),
    );
  }
}
