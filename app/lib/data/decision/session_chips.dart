import '../acp/acp_models.dart';
import '../acp/session_state.dart';
import 'mode_danger.dart';
import 'plain_text.dart';

/// Most chips drawn above the composer; the rest is an overflow count.
const maxSessionChips = 4;

/// Longest chip label, in characters.
const chipLabelLimit = 28;

enum SessionChipKind {
  /// The permission mode (`bypassPermissions`, `plan`...).
  mode,

  /// The model.
  model,

  /// Thinking or reasoning effort (category `thought_level`).
  effort,

  /// A boolean switch (`fast`).
  toggle,

  /// Any other select the agent offers (`collaboration_mode`, a persona).
  other,
}

/// One quiet chip above the composer.
class SessionChip {
  const SessionChip({
    required this.kind,
    required this.settingId,
    required this.title,
    required this.label,
    this.risk = ModeRisk.none,
    this.reason,
    this.on,
    this.viaModes = false,
  });

  final SessionChipKind kind;

  /// The config option it edits (`session/set_config_option`); for a mode
  /// the agent lists only as `modes` (`viaModes`), the id `mode`.
  final String settingId;

  /// What the setting is called (`Mode`, `Model`, `Fast`): for a tooltip or
  /// an accessibility label.
  final String title;

  /// What is drawn: the current choice's name (`Bypass Permissions`), the
  /// switch's name for a toggle, `Title: choice` for an [SessionChipKind.other]
  /// select (a bare `Default` would mean nothing). At most [chipLabelLimit]
  /// characters, hidden characters removed.
  final String label;

  /// Only a mode chip is ever risky. The UI keeps [ModeRisk.dangerous] in
  /// the danger tint for as long as the mode is active.
  final ModeRisk risk;

  /// Why the mode is risky, in plain words; null for [ModeRisk.none].
  final String? reason;

  /// A toggle's state; null for the other kinds.
  final bool? on;

  /// The mode comes from `modes`, set with `session/set_mode`.
  final bool viaModes;

  bool get isRisky => risk != ModeRisk.none;
}

/// The chips of one session, in a fixed order.
class SessionChips {
  const SessionChips(this.all);

  static const none = SessionChips([]);

  /// Every chip the agent's settings give.
  final List<SessionChip> all;

  /// The first [maxSessionChips] chips: a risky one is always among them
  /// (it moves to the front of the shown ones when it would be cut).
  List<SessionChip> get shown {
    if (all.length <= maxSessionChips) return all;
    final head = all.sublist(0, maxSessionChips);
    final risky = all.skip(maxSessionChips).where((c) => c.isRisky);
    if (risky.isEmpty) return head;
    // Danger is persistent: it replaces the last quiet chip.
    return [...head.sublist(0, maxSessionChips - 1), risky.first];
  }

  /// Chips that are not [shown].
  int get overflow => all.length - shown.length;

  /// The chips not [shown], for the sheet.
  List<SessionChip> get hidden {
    final s = shown;
    return [
      for (final c in all)
        if (!s.contains(c)) c,
    ];
  }
}

/// The chips for [state]. Order is the same whatever order the agent lists
/// its options in: mode, model, effort, switches (in the agent's order), then
/// any other select. A setting with no value to show gives no chip (absent
/// data means absent UI); an option of a kind this client does not know is
/// skipped.
SessionChips sessionChipsOf(AgentSessionState state) {
  SessionChip? mode;
  SessionChip? model;
  SessionChip? effort;
  final toggles = <SessionChip>[];
  final others = <SessionChip>[];

  final current = currentModeOf(state);
  if (current != null) {
    final a = assessMode(id: current.id, name: current.name);
    mode = SessionChip(
      kind: SessionChipKind.mode,
      settingId: current.option?.id ?? 'mode',
      title: current.option == null ? 'Mode' : _nonBlank(current.option!.name) ?? 'Mode',
      label: _label(current.name),
      risk: a.risk,
      reason: a.reason,
      viaModes: current.viaModes,
    );
  }

  for (final o in state.configOptions) {
    switch (o) {
      case SelectConfigOption():
        if (identical(o, current?.option)) break;
        final name = _nonBlank(o.currentName);
        if (name == null) break;
        final title = _nonBlank(o.name) ?? o.id;
        if (o.category == 'model' || (o.category == null && o.id == 'model')) {
          model ??= SessionChip(
            kind: SessionChipKind.model,
            settingId: o.id,
            title: title,
            label: _label(_shortModel(o, name)),
          );
        } else if (o.category == 'thought_level') {
          effort ??= SessionChip(kind: SessionChipKind.effort, settingId: o.id, title: title, label: _label(name));
        } else if (o.category != 'mode') {
          others.add(SessionChip(kind: SessionChipKind.other, settingId: o.id, title: title, label: _label('$title: $name')));
        }
      case BooleanConfigOption():
        final title = _nonBlank(o.name) ?? o.id;
        toggles.add(
          SessionChip(kind: SessionChipKind.toggle, settingId: o.id, title: title, label: _label(title), on: o.value),
        );
      case UnknownConfigOption():
        break;
    }
  }

  return SessionChips([?mode, ?model, ?effort, ...toggles, ...others]);
}

String? _nonBlank(String? s) {
  if (s == null) return null;
  final line = plainLine(s);
  return line.isEmpty ? null : line;
}

String _label(String s) => ellipsize(plainLine(s), chipLabelLimit);

/// `anthropic/claude-sonnet-5-5` reads as `claude-sonnet-5-5`: the provider
/// prefix of a model the agent names by its id alone (omp). A model with a
/// display name keeps it.
String _shortModel(SelectConfigOption o, String name) {
  if (name != o.value) return name;
  final slash = name.lastIndexOf('/');
  return slash > 0 && slash < name.length - 1 ? name.substring(slash + 1) : name;
}
