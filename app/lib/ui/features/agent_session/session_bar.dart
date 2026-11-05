import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/decision/mode_danger.dart';
import '../../../data/decision/session_chips.dart';
import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/agent_screens.dart' show AgentRef, AgentView, PaneAgent;
import '../../../data/words/agent_names.dart';
import '../../../data/words/plural.dart';
import '../../../data/words/place_name.dart';
import '../../../data/words/where_line.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../create/new_agent_session_screen.dart' show openNewAgentSession;
import '../create/session_prefill.dart' show SessionPrefill;
import '../files/files_navigation.dart' show machineSupportsFiles, openFileBrowser;
import '../agents/agent_navigation.dart' show agentViewAction;
import '../agents/agent_switcher.dart' show AgentSwitchMark, othersNeedingYou, showAgentSwitcher, switchAgentLabel;
import 'session_select.dart';
import 'session_overview.dart' show showSessionOverview;
import 'session_made.dart' show MadeChip, showSessionMade;
import '../../../data/acp/session_made.dart' show madeAssetsOf;
import '../../../data/repositories/attention_notifier.dart' show sessionLinkOf;
import 'session_overview_model.dart' show contextWarning;
import 'background_strip.dart' show BackgroundChip;
import 'subagent_roster.dart' show SubagentsChip;

/// The glyph status of an agent session: blocked on the person, working, done
/// and not yet looked at, or idle.
AgentStatus sessionStatus(AgentPhase phase, {required bool unseenDone}) => switch (phase) {
  AgentPhase.blockedOnPermission || AgentPhase.blockedOnQuestion => AgentStatus.blocked,
  AgentPhase.working => AgentStatus.working,
  AgentPhase.idle => unseenDone ? AgentStatus.done : AgentStatus.idle,
};

/// `Claude Code · devbox · payments-api`: agent, machine, folder
/// ([whereLine]). The folder is left out when it is the title (a session is
/// named for its folder at first): said once. [title] defaults to the
/// session's own.
String sessionWhere(AgentSessionView session, {String? title}) => whereLine(
  agent: agentName(session.agent),
  machine: session.machine.profile.label,
  folder: placeName(session.machine.places, session.cwd),
  title: title ?? session.title,
);

/// The one slim bar ([AppTopBar]): back, the status glyph beside the title over where the
/// session lives, and the button for its modes and options (which hold the
/// way to the terminal of an agent in a pane, and the session overview).
///
/// For a board agent ([agent]) the title is the agent switcher: a chevron,
/// the count of other agents that need the person, and a tap that lists them
/// ([showAgentSwitcher]).
class SessionBar extends StatelessWidget {
  const SessionBar({super.key, required this.session, this.agent});

  final AgentSessionView session;

  /// The board's agent this chat shows; null for a subagent's transcript,
  /// which has no switcher.
  final AgentRef? agent;

  @override
  Widget build(BuildContext context) {
    final agent = this.agent;
    // Rebuilds the bar only when the count changes.
    final others = othersNeedingYou(context, agent);
    return SessionSelect<(String, AgentPhase, bool, AgentLink, int?)>(
      session: session,
      select: (s) => (s.title, s.phase, s.unseenDone, s.link, contextWarning(s.state.usage)),
      builder: (context, v) => _bar(context, v, agent, others),
    );
  }

  Widget _bar(BuildContext context, (String, AgentPhase, bool, AgentLink, int?) v, AgentRef? agent, int others) {
    final (title, phase, unseen, link, contextPercent) = v;
    return AppTopBar(
      title: title,
      subtitle: sessionWhere(session, title: title),
      // The context window is nearly full: said in words, in the danger
      // tone, and only then.
      subtitleAlert: contextPercent == null ? null : 'Context $contextPercent%',
      glyph: StatusGlyph(
        status: sessionStatus(phase, unseenDone: unseen),
        size: IconSize.row,
        dim: link != AgentLink.live,
      ),
      // The whole title area switches agent; the overview is in the options.
      onTitleTap: agent == null ? null : () => unawaited(showAgentSwitcher(context, agent)),
      titleTapLabel: agent == null ? null : switchAgentLabel,
      titleTrailing: agent == null ? null : AgentSwitchMark(othersNeedYou: others),
      actions: [
        CircleButton(
          icon: LucideIcons.ellipsis,
          tooltip: 'Session options',
          onPressed: () => showSessionOptions(context, session),
        ),
      ],
      // The chips wrap rather than shrink: the subagents chip carries "1
      // waiting for you" and must not end in an ellipsis to make room for
      // the Made chip (it did at 320 wide). The background chip only shows
      // in the compact layout, which is wide.
      bottom: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SubagentsChip(session: session),
          BackgroundChip(session: session),
          MadeChip(session: session),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// the options sheet

const _modeId = '\u0000mode';

enum _Kind { select, boolean }

class _Setting {
  const _Setting({
    required this.id,
    required this.name,
    required this.kind,
    this.description,
    this.choices = const [],
    this.value,
    this.isMode = false,
  });

  final String id;
  final String name;
  final _Kind kind;
  final String? description;
  final List<ConfigChoice> choices;

  /// The current choice value (select) or flag (boolean).
  final Object? value;

  /// The session's mode (the `mode` option, or the agent's `modes`): its
  /// choices are assessed, and a dangerous one is entered by a hold.
  final bool isMode;

  String get currentName {
    for (final c in choices) {
      if (c.value == value) return c.name;
    }
    return '${value ?? ''}';
  }
}

/// The settings the agent exposes: its select and boolean config options and,
/// when it has no mode option but lists modes, the modes as one select.
List<_Setting> _settings(AgentSessionState state) {
  final out = <_Setting>[];
  var hasModeOption = false;
  for (final o in state.configOptions) {
    switch (o) {
      case SelectConfigOption():
        if (o.category == 'mode') hasModeOption = true;
        out.add(
          _Setting(
            id: o.id,
            name: o.name,
            kind: _Kind.select,
            description: o.description,
            choices: o.choices,
            value: o.value,
            isMode: o.category == 'mode',
          ),
        );
      case BooleanConfigOption():
        out.add(_Setting(id: o.id, name: o.name, kind: _Kind.boolean, description: o.description, value: o.value));
      case UnknownConfigOption():
        break;
    }
  }
  final modes = state.modes;
  if (!hasModeOption && modes != null && modes.availableModes.isNotEmpty) {
    out.insert(
      0,
      _Setting(
        id: _modeId,
        name: 'Mode',
        kind: _Kind.select,
        choices: [
          for (final m in modes.availableModes) ConfigChoice(value: m.id, name: m.name, description: m.description),
        ],
        value: modes.currentModeId,
        isMode: true,
      ),
    );
  }
  return out;
}

/// The session's options as a sheet: each mode and option of the agent as a
/// row showing its current choice (tap to pick; a long list such as a model
/// catalogue scrolls lazily and can be searched) or a switch, then Duplicate.
/// True when a choice was picked (the sheet closes on a pick).
Future<bool> showSessionOptions(BuildContext context, AgentSessionView session, {SessionChip? at}) async =>
    await showAppSheet<bool>(
      context,
      builder: (ctx) => _OptionsSheet(session: session, at: at),
    ) ==
    true;

class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({required this.session, this.at});

  final AgentSessionView session;

  /// The chip that was tapped: the sheet opens on that setting's choices.
  final SessionChip? at;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late String? _picking = switch (widget.at) {
    null => null,
    SessionChip(viaModes: true) => _modeId,
    final chip => chip.settingId,
  };

  void _pick(_Setting setting, ConfigChoice choice) {
    if (setting.id == _modeId) {
      widget.session.setMode(choice.value);
    } else {
      widget.session.setConfigOption(setting.id, choice.value);
    }
    Navigator.of(context).pop(true);
  }

  /// Another session of the same agent in the same folder on the same machine,
  /// started from the form with those filled in. Never the conversation.
  void _duplicate() {
    final session = widget.session;
    final navigator = Navigator.of(context)..pop();
    unawaited(
      openNewAgentSession(
        navigator.context,
        prefill: SessionPrefill(machineId: session.machine.profile.id, folder: session.cwd, agent: session.agent),
      ),
    );
  }

  PaneAgent _pane(String paneId) => PaneAgent(widget.session.machine.profile.id, paneId);

  /// An agent in a pane has its terminal as well: it takes the place of this
  /// chat (`Show terminal`), and the choice is remembered for this agent.
  void _showTerminal(PaneAgent pane) {
    final navigator = Navigator.of(context)..pop();
    // ignore: use_build_context_synchronously
    agentViewAction(navigator.context, pane, AgentView.chat).onTap();
  }

  /// The overview sheet in place of this one.
  void _overview() {
    final session = widget.session;
    final navigator = Navigator.of(context)..pop();
    // ignore: use_build_context_synchronously
    unawaited(showSessionOverview(navigator.context, session));
  }

  /// The file browser at the folder the agent works in (where it has been
  /// writing).
  void _files() {
    final session = widget.session;
    final navigator = Navigator.of(context)..pop();
    // ignore: use_build_context_synchronously
    unawaited(openFileBrowser(navigator.context, session.machine, startDir: session.cwd.isEmpty ? null : session.cwd));
  }

  /// The Made sheet (servers, pages, pictures, documents) in place of this one.
  void _made() {
    final session = widget.session;
    final navigator = Navigator.of(context)..pop();
    // ignore: use_build_context_synchronously
    unawaited(showSessionMade(navigator.context, session));
  }

  /// The link that opens this session on this phone (`herdr://session/...`).
  void _copyLink() {
    // copyText finds the toaster in the app's overlay, so it outlives the sheet.
    unawaited(copyText(context, sessionLinkOf(widget.session), what: 'Session link copied'));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => SessionSelect<(List<ConfigOption>, ModeState?)>(
    session: widget.session,
    select: (s) => (s.state.configOptions, s.state.modes),
    builder: (context, _) {
      final settings = _settings(widget.session.state);
      final picking = settings.where((s) => s.id == _picking).firstOrNull;
      if (picking != null) {
        return _Picker(
          setting: picking,
          onBack: () => setState(() => _picking = null),
          onPick: (c) => _pick(picking, c),
        );
      }
      return SheetScaffold(
        title: settings.isEmpty ? 'Session' : 'Mode and model',
        kind: SheetKind.actions,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in settings)
              if (s.kind == _Kind.boolean)
                SwitchRow(
                  title: s.name,
                  subtitle: s.description,
                  value: s.value == true,
                  onChanged: (v) => widget.session.setConfigOption(s.id, v),
                )
              else
                _SettingRow(setting: s, onTap: () => setState(() => _picking = s.id)),
            SheetActionRow(
              action: SheetAction(label: 'Session overview', icon: LucideIcons.layoutList, onTap: _overview),
              onTap: _overview,
            ),
            if (machineSupportsFiles(widget.session.machine))
              SheetActionRow(
                action: SheetAction(label: 'Files', icon: HerdrIcons.folder, onTap: _files),
                onTap: _files,
              ),
            // Always here: the chip under the title only shows once something
            // exists, so this is where "where are the files and pictures?" is
            // answered, with its reason while there is nothing.
            SessionSelect<(int, MadeReach)>(
              session: widget.session,
              select: (s) => (madeAssetsOf(s.state.items, cwd: s.cwd, history: s.madeHistory).length, s.madeReach),
              builder: (context, v) {
                final (made, reach) = v;
                // Only the end of a long chat is read: the sheet reads the rest when opened.
                final nothing = made == 0 && reach == MadeReach.whole;
                return SheetActionRow(
                  action: SheetAction(
                    label: 'Made in this session',
                    icon: LucideIcons.globe,
                    onTap: _made,
                    unavailable: nothing ? 'Nothing has come up yet' : null,
                  ),
                  onTap: _made,
                );
              },
            ),
            SheetActionRow(
              action: SheetAction(label: 'Copy session link', icon: LucideIcons.link, onTap: _copyLink),
              onTap: _copyLink,
            ),
            if (!widget.session.isObserved)
              ListenableBuilder(
                listenable: widget.session.machine,
                builder: (context, _) {
                  final machine = widget.session.machine;
                  return SheetActionRow(
                    action: SheetAction(
                      label: 'Duplicate',
                      icon: LucideIcons.copyPlus,
                      onTap: _duplicate,
                      unavailable: machine.isLive ? null : '${machine.profile.label} is offline',
                    ),
                    onTap: _duplicate,
                  );
                },
              ),
            if (widget.session.terminalPaneId case final paneId?)
              SheetActionRow(
                action: agentViewAction(context, _pane(paneId), AgentView.chat),
                onTap: () => _showTerminal(_pane(paneId)),
              ),
          ],
        ),
      );
    },
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.setting, required this.onTap});

  final _Setting setting;
  final VoidCallback onTap;

  /// Two lines: the option and its current choice.
  static const _minHeight = 56.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: _minHeight),
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.sm),
        decoration: BoxDecoration(
          color: pressed ? ds.pressTint : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(setting.name, style: Type.row.copyWith(color: ds.text)),
                  Text(
                    setting.currentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// The choices of one select, searchable past [searchFrom], built lazily.
class _Picker extends StatefulWidget {
  const _Picker({required this.setting, required this.onBack, required this.onPick});

  final _Setting setting;
  final VoidCallback onBack;
  final ValueChanged<ConfigChoice> onPick;

  static const searchFrom = 12;

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  final _query = TextEditingController();

  /// The dangerous mode the assistive activation primed (its value).
  String? _primed;
  Timer? _primeTimer;

  @override
  void dispose() {
    _primeTimer?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// The assistive activation of a dangerous mode: the first primes, the
  /// second (within [Dwell.confirm]) sets it. A finger holds instead.
  void _activate(ConfigChoice choice) {
    if (_primed == choice.value) {
      _primeTimer?.cancel();
      widget.onPick(choice);
      return;
    }
    Haptics.armed();
    _primeTimer?.cancel();
    setState(() => _primed = choice.value);
    _primeTimer = Timer(Dwell.confirm, () {
      if (mounted) setState(() => _primed = null);
    });
  }

  /// Group headers (strings) and choices, filtered by the search.
  List<Object> _entries() {
    final q = _query.text.trim().toLowerCase();
    final out = <Object>[];
    String? group;
    for (final c in widget.setting.choices) {
      if (q.isNotEmpty &&
          !c.name.toLowerCase().contains(q) &&
          !c.value.toLowerCase().contains(q) &&
          !(c.description ?? '').toLowerCase().contains(q)) {
        continue;
      }
      if (c.group != null && c.group != group) out.add(c.group!);
      group = c.group;
      out.add(c);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final setting = widget.setting;
    final height = MediaQuery.sizeOf(context).height * 0.6;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PressBuilder(
              onTap: widget.onBack,
              semanticLabel: 'Back to options',
              builder: (context, pressed) => Container(
                constraints: const BoxConstraints(minHeight: kMinTap),
                padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
                child: Row(
                  children: [
                    Icon(LucideIcons.chevronLeft, size: IconSize.bar, color: ds.textSecondary),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Text(setting.name, style: Type.labelStrong.copyWith(color: ds.textSecondary)),
                    ),
                  ],
                ),
              ),
            ),
            if (setting.choices.length > _Picker.searchFrom)
              Padding(
                padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.sm),
                child: SearchField(
                  controller: _query,
                  hint: 'Search ${countOf(setting.choices.length, 'choice')}',
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Expanded(child: _list(context)),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final ds = context.ds;
    final entries = _entries();
    if (entries.isEmpty) {
      return const Center(child: EmptyState.inline('Nothing matches.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(left: Gap.xs, right: Gap.xs, bottom: Gap.md),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        if (e is String) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
            child: Semantics(
              header: true,
              child: Text(e, style: Type.caption.copyWith(color: ds.textSecondary)),
            ),
          );
        }
        final choice = e as ConfigChoice;
        final selected = choice.value == widget.setting.value;
        final risk = widget.setting.isMode ? assessMode(id: choice.value, name: choice.name) : ModeAssessment.none;
        // Entering a dangerous mode is held (the dock's pattern); staying in
        // it, or leaving it for a safer one, is a tap.
        if (risk.risk == ModeRisk.dangerous && !selected) {
          final primed = _primed == choice.value;
          return AnswerChip(
            label: choice.name,
            detail: [?risk.reason, if ((choice.description ?? '').isNotEmpty) choice.description!].join('\n'),
            risk: AnswerRisk.gate,
            tone: AnswerChipTone.danger,
            state: primed ? AnswerChipState.primed : AnswerChipState.rest,
            hold: true,
            holdVerb: 'Hold to switch to ${choice.name}',
            semanticLabel: primed
                ? 'Confirm: switch to ${choice.name}, activate again to confirm'
                : '${choice.name}, dangerous, needs holding or a second activation: ${risk.reason}',
            onTap: () => _activate(choice),
            onHeld: () => widget.onPick(choice),
          );
        }
        return _ChoiceRow(choice: choice, risk: risk, selected: selected, onTap: () => widget.onPick(choice));
      },
    );
  }
}

/// One choice of a select. A mode that asks for less says so: an elevated one
/// with a quiet shield, a dangerous one with a triangle in the danger words,
/// and each with its reason in a line.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.choice, required this.risk, required this.selected, required this.onTap});

  final ConfigChoice choice;
  final ModeAssessment risk;
  final bool selected;
  final VoidCallback onTap;

  /// One line of choice with room above and below.
  static const _minHeight = 52.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final danger = risk.risk == ModeRisk.dangerous;
    final title = choice.name;
    final marker = switch (risk.risk) {
      ModeRisk.dangerous => Icon(LucideIcons.triangleAlert, size: IconSize.row, color: ds.dangerText),
      ModeRisk.elevated => Icon(LucideIcons.shieldHalf, size: IconSize.row, color: ds.textSecondary),
      ModeRisk.none => null,
    };
    final reason = risk.reason;
    // The padding sits on the content, not the row; the press inset is part of it.
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg - PressRow.inset, vertical: Gap.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (marker != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: Gap.hair),
              child: marker,
            ),
            const SizedBox(width: Gap.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  // The check says which one is chosen; the weight stays.
                  style: Type.row.copyWith(color: danger ? ds.dangerText : ds.text),
                ),
                if (reason != null)
                  Text(reason, style: Type.secondary.copyWith(color: danger ? ds.dangerText : ds.textSecondary)),
                if ((choice.description ?? '').isNotEmpty)
                  Text(
                    choice.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Type.secondary.copyWith(color: ds.textSecondary),
                  ),
              ],
            ),
          ),
          if (selected) Icon(LucideIcons.check, size: IconSize.bar, color: ds.accentText),
        ],
      ),
    );
    return PressRow(onTap: onTap, selected: selected, minHeight: _minHeight, child: content);
  }
}
