import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/decision/mode_danger.dart';
import '../../../data/decision/session_chips.dart';
import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/agent_screens.dart' show AgentView, PaneAgent;
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/hold_confirm.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/theme.dart';
import '../create/new_agent_session_screen.dart' show openNewAgentSession;
import '../create/session_prefill.dart' show SessionPrefill;
import '../settings/app_switch.dart';
import '../files/files_navigation.dart' show machineSupportsFiles, openFileBrowser;
import '../agents/agent_navigation.dart' show agentViewAction;
import 'permission_dock.dart' show confirmWindow;
import 'session_select.dart';
import 'session_overview.dart' show showSessionOverview;
import 'session_overview_model.dart' show contextWarning;
import 'background_strip.dart' show BackgroundChip;
import 'subagent_roster.dart' show SubagentsChip;

const _barHeight = 56.0;
const _shortBarHeight = 52.0;
const _shortScreen = 520.0;

/// The glyph status of an agent session: blocked on the person, working, done
/// and not yet looked at, or idle.
AgentStatus sessionStatus(AgentPhase phase, {required bool unseenDone}) => switch (phase) {
  AgentPhase.blockedOnPermission || AgentPhase.blockedOnQuestion => AgentStatus.blocked,
  AgentPhase.working => AgentStatus.working,
  AgentPhase.idle => unseenDone ? AgentStatus.done : AgentStatus.idle,
};

/// `claude · devbox · payments-api`: agent, machine, folder. The folder is
/// left out when it is the title (a session is named for its folder at
/// first): said once. [title] defaults to the session's own.
String sessionWhere(AgentSessionView session, {String? title}) {
  final folder = cwdTail(session.cwd);
  final named = (title ?? session.title).trim();
  final same = folder.isNotEmpty && folder.toLowerCase() == named.toLowerCase();
  return [session.agentLabel, session.machine.profile.label, if (!same) folder].where((s) => s.isNotEmpty).join(' · ');
}

/// The one slim bar: back, the status glyph beside the title over where the
/// session lives, and the button for its modes and options (which hold the
/// way to the terminal of an agent in a pane).
class SessionBar extends StatelessWidget {
  const SessionBar({super.key, required this.session});

  final AgentSessionView session;


  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final height = MediaQuery.sizeOf(context).height < _shortScreen ? _shortBarHeight : _barHeight;
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Row(
          children: [
            CircleButton(
              icon: LucideIcons.chevronLeft,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: Gap.xs),
            Expanded(
              child: SessionSelect<(String, AgentPhase, bool, AgentLink, int?)>(
                session: session,
                select: (s) => (s.title, s.phase, s.unseenDone, s.link, contextWarning(s.state.usage)),
                builder: (context, v) {
                  final (title, phase, unseen, link, contextPercent) = v;
                  // The whole title area opens the session overview.
                  return PressBuilder(
                    onTap: () => unawaited(showSessionOverview(context, session)),
                    builder: (context, pressed) => AnimatedContainer(
                      duration: Motion.pressing(pressed),
                      curve: Motion.easeOut,
                      constraints: BoxConstraints(minHeight: height),
                      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
                      decoration: BoxDecoration(
                        color: pressed ? ds.fill : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.row),
                      ),
                      child: Row(
                        children: [
                          StatusGlyph(
                            status: sessionStatus(phase, unseenDone: unseen),
                            size: 16,
                            dim: link != AgentLink.live,
                          ),

                          const SizedBox(width: Gap.sm),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Type.barTitle.copyWith(color: ds.text),
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        sessionWhere(session, title: title),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Type.secondary.copyWith(color: ds.textSecondary),
                                      ),
                                    ),
                                    // The context window is nearly full: said in words,
                                    // in the danger tone, and only then.
                                    if (contextPercent != null) ...[
                                      const SizedBox(width: Gap.sm),
                                      Text(
                                        'Context $contextPercent%',
                                        maxLines: 1,
                                        style: Type.secondary.copyWith(
                                          color: ds.dangerText,
                                          fontWeight: FontWeight.w600,
                                          fontFeatures: Type.tabular,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            CircleButton(
              icon: LucideIcons.ellipsis,
              tooltip: 'Session options',
              onPressed: () => showSessionOptions(context, session),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [SubagentsChip(session: session), BackgroundChip(session: session)],
        ),
          ],
        ),
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
        choices: [for (final m in modes.availableModes) ConfigChoice(value: m.id, name: m.name, description: m.description)],
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
Future<void> showSessionOptions(BuildContext context, AgentSessionView session, {SessionChip? at}) =>
    showAppSheet<void>(context, builder: (ctx) => _OptionsSheet(session: session, at: at));

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
    Navigator.of(context).pop();
  }

  /// Another session of the same agent in the same folder on the same machine,
  /// started from the form with those filled in. Never the conversation.
  void _duplicate() {
    final session = widget.session;
    final navigator = Navigator.of(context)..pop();
    unawaited(
      openNewAgentSession(
        navigator.context,
        prefill: SessionPrefill(
          machineId: session.machine.profile.id,
          folder: session.cwd,
          agent: session.agent,
        ),
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

  @override
  Widget build(BuildContext context) => SessionSelect<(List<ConfigOption>, ModeState?)>(
    session: widget.session,
    select: (s) => (s.state.configOptions, s.state.modes),
    builder: (context, _) {
      final settings = _settings(widget.session.state);
      final picking = settings.where((s) => s.id == _picking).firstOrNull;
      if (picking != null) return _Picker(setting: picking, onBack: () => setState(() => _picking = null), onPick: (c) => _pick(picking, c));
      final ds = context.ds;
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Semantics(
                header: true,
                child: Text(
                  settings.isEmpty ? 'Session' : 'Mode and model',
                  style: Type.label.copyWith(color: ds.textSecondary),
                ),
              ),
            ),
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
                action: SheetAction(label: 'Files', icon: LucideIcons.folderOpen, onTap: _files),
                onTap: _files,
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

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.row),
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
            Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
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
  /// second (within [confirmWindow]) sets it. A finger holds instead.
  void _activate(ConfigChoice choice) {
    if (_primed == choice.value) {
      _primeTimer?.cancel();
      widget.onPick(choice);
      return;
    }
    Haptics.armed();
    _primeTimer?.cancel();
    setState(() => _primed = choice.value);
    _primeTimer = Timer(confirmWindow, () {
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
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(LucideIcons.chevronLeft, size: 18, color: ds.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(setting.name, style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
            if (setting.choices.length > _Picker.searchFrom)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Semantics(
                  label: 'Search ${setting.name}',
                  child: TextField(
                    controller: _query,
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: (_) => setState(() {}),
                    style: Type.body.copyWith(fontSize: 15, color: ds.text),
                    cursorColor: ds.accent,
                    decoration: InputDecoration(
                      hintText: 'Search ${setting.choices.length} choices',
                      prefixIcon: Icon(LucideIcons.search, size: 16, color: ds.textTertiary),
                    ),
                  ),
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
      return Center(child: Text('Nothing matches.', style: Type.secondary.copyWith(color: ds.textMuted)));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        if (e is String) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Semantics(header: true, child: Text(e, style: Type.caption.copyWith(color: ds.textSecondary))),
          );
        }
        final choice = e as ConfigChoice;
        final selected = choice.value == widget.setting.value;
        final risk = widget.setting.isMode ? assessMode(id: choice.value, name: choice.name) : ModeAssessment.none;
        // Entering a dangerous mode is held (the dock's pattern); staying in
        // it, or leaving it for a safer one, is a tap.
        if (risk.risk == ModeRisk.dangerous && !selected) {
          final primed = _primed == choice.value;
          return HoldToConfirm(
            semanticLabel: primed
                ? 'Confirm: switch to ${choice.name}, activate again to confirm'
                : '${choice.name}, dangerous, needs holding or a second activation: ${risk.reason}',
            onActivate: () => _activate(choice),
            onConfirmed: () => widget.onPick(choice),
            builder: (context, hold) => _ChoiceRow(
              choice: choice,
              risk: risk,
              selected: false,
              pressed: hold.holding,
              hold: hold,
              primed: primed,
            ),
          );
        }
        return PressBuilder(
          onTap: () => widget.onPick(choice),
          selected: selected,
          builder: (context, pressed) => _ChoiceRow(choice: choice, risk: risk, selected: selected, pressed: pressed),
        );
      },
    );
  }
}

/// One choice of a select. A mode that asks for less says so: an elevated one
/// with a quiet shield, a dangerous one with a triangle in the danger words,
/// and each with its reason in a line.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.choice,
    required this.risk,
    required this.selected,
    required this.pressed,
    this.hold,
    this.primed = false,
  });

  final ConfigChoice choice;
  final ModeAssessment risk;
  final bool selected;
  final bool pressed;

  /// Set for a dangerous mode, entered by a hold.
  final HoldState? hold;
  final bool primed;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final danger = risk.risk == ModeRisk.dangerous;
    final hold = this.hold;
    final title = (hold?.showsHold ?? false)
        ? 'Hold to switch to ${choice.name}'
        : primed
        ? 'Hold or tap again'
        : choice.name;
    final marker = switch (risk.risk) {
      ModeRisk.dangerous => Icon(LucideIcons.triangleAlert, size: 16, color: ds.dangerText),
      ModeRisk.elevated => Icon(LucideIcons.shieldHalf, size: 16, color: ds.textSecondary),
      ModeRisk.none => null,
    };
    final reason = risk.reason;
    // The padding sits on the content, not the row: a hold's fill covers the
    // whole row.
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (marker != null) ...[
            Padding(padding: const EdgeInsets.only(top: 3), child: marker),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Type.row.copyWith(
                    color: danger ? ds.dangerText : ds.text,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
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
          if (selected) Icon(LucideIcons.check, size: 18, color: ds.accentText),
        ],
      ),
    );
    return AnimatedContainer(
      duration: Motion.pressing(pressed),
      curve: Motion.easeOut,
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        color: primed
            ? ds.danger.withValues(alpha: 0.14)
            : pressed
            ? ds.fill
            : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: hold == null ? content : Stack(fit: StackFit.passthrough, children: [hold.fill, content]),
    );
  }
}
