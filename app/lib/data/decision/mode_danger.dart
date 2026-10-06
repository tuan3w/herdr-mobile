import '../acp/acp_models.dart';
import '../acp/session_state.dart';
import 'plain_text.dart';

/// How much a session mode lowers the guard between the agent and the host.
enum ModeRisk {
  /// The agent asks as the person expects (default, plan, read-only...).
  none,

  /// Part of the asking is switched off or delegated (accept edits, auto).
  elevated,

  /// Nothing is asked: the agent runs and writes freely.
  dangerous,
}

/// A mode's [risk] and, when there is one, why in plain words.
class ModeAssessment {
  const ModeAssessment(this.risk, [this.reason]);

  static const none = ModeAssessment(ModeRisk.none);

  final ModeRisk risk;

  /// One sentence for a sheet or a tooltip; null for [ModeRisk.none].
  final String? reason;

  bool get isRisky => risk != ModeRisk.none;
}

/// The mode a session is in, as the agent names it.
class CurrentMode {
  const CurrentMode({required this.id, required this.name, this.option});

  /// The value the agent knows it by (`bypassPermissions`).
  final String id;

  /// The agent's display name for it; the id when it gave none.
  final String name;

  /// The select option that holds the mode (category `mode`), or null when
  /// the agent lists modes only (`session/set_mode` then changes it).
  final SelectConfigOption? option;

  bool get viaModes => option == null;
}

/// The mode [state] is in: the `mode` config option when there is one, else
/// the `modes` list. Null when the agent offers neither, or when `modes` only
/// repeats a thinking-level option (pi-acp lists its thinking levels as
/// modes).
CurrentMode? currentModeOf(AgentSessionState state) {
  for (final o in state.configOptions) {
    if (o is SelectConfigOption && o.category == 'mode') {
      if (o.value.isEmpty) return null;
      return CurrentMode(id: o.value, name: _nonBlank(o.currentName) ?? o.value, option: o);
    }
  }
  final modes = state.modes;
  if (modes == null || modes.currentModeId.isEmpty) return null;
  if (_repeatsThinking(modes, state.configOptions)) return null;
  var name = modes.currentModeId;
  for (final m in modes.availableModes) {
    if (m.id == modes.currentModeId) {
      name = _nonBlank(m.name) ?? name;
      break;
    }
  }
  return CurrentMode(id: modes.currentModeId, name: name);
}

String? _nonBlank(String? s) => s == null || s.trim().isEmpty ? null : s;

bool _repeatsThinking(ModeState modes, List<ConfigOption> options) {
  if (modes.availableModes.isEmpty) return false;
  final ids = {for (final m in modes.availableModes) m.id};
  for (final o in options) {
    if (o is SelectConfigOption && o.category == 'thought_level') {
      final values = {for (final c in o.choices) c.value};
      if (values.length == ids.length && values.containsAll(ids)) return true;
    }
  }
  return false;
}

/// The risk of the mode [state] is in; [ModeAssessment.none] when it has no
/// mode.
ModeAssessment assessSessionMode(AgentSessionState state) {
  final m = currentModeOf(state);
  return m == null ? ModeAssessment.none : assessMode(id: m.id, name: m.name);
}

/// The risk of one mode, from its id and its display name. Both are read and
/// the worse reading wins, so a harmless id with a name that says `Bypass`
/// still shows.
///
/// Order, for each of id and name: the exact table of known modes
/// ([_known], compared as lower-case letters and digits only, so
/// `bypassPermissions`, `bypass_permissions` and `Bypass Permissions` are one
/// entry), then words that mark a mode nobody has listed. A name this client
/// does not know and that does not look risky is [ModeRisk.none]. Descriptions
/// are not read: Claude's own `default` says it "prompts for dangerous
/// operations".
ModeAssessment assessMode({String? id, String? name}) {
  final byId = _assess(id);
  final byName = _assess(name);
  final worse = byName.risk.index > byId.risk.index ? byName : byId;
  return worse;
}

ModeAssessment _assess(String? raw) {
  if (raw == null) return ModeAssessment.none;
  final key = _compact(raw);
  if (key.isEmpty) return ModeAssessment.none;
  final known = _known[key];
  if (known != null) return known;
  for (final word in _dangerWords) {
    if (key.contains(word)) {
      return ModeAssessment(ModeRisk.dangerous, 'The mode "${_shown(raw)}" looks like it skips permission checks.');
    }
  }
  for (final word in _elevatedWords) {
    if (key.contains(word)) return ModeAssessment(ModeRisk.elevated, _unknownElevated(raw));
  }
  for (final token in _tokens(raw)) {
    if (token == 'auto' || token.startsWith('autonom')) {
      return ModeAssessment(ModeRisk.elevated, _unknownElevated(raw));
    }
  }
  return ModeAssessment.none;
}

String _unknownElevated(String raw) => 'The mode "${_shown(raw)}" may ask for less than usual.';

String _shown(String raw) {
  final line = plainLine(raw);
  return line.length <= 40 ? line : ellipsize(line, 40);
}

/// Lower-case letters and digits only (any script's letters stay).
String _compact(String s) {
  final out = StringBuffer();
  for (final r in plainLine(s).toLowerCase().runes) {
    if (_isWordRune(r)) out.writeCharCode(r);
  }
  return out.toString();
}

final _tokenSplit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

Iterable<String> _tokens(String raw) sync* {
  // camelCase boundaries count: `autoAccept` is `auto`, `accept`.
  final spaced = raw.replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}');
  for (final t in plainLine(spaced).toLowerCase().split(_tokenSplit)) {
    if (t.isNotEmpty) yield t;
  }
}

bool _isWordRune(int r) => (r >= 0x30 && r <= 0x39) || (r >= 0x61 && r <= 0x7A) || r > 0x7F;

/// Words (compacted) that make an unlisted mode dangerous.
const _dangerWords = [
  'bypass',
  'yolo',
  'fullaccess',
  'dangerously',
  'dangerfull',
  'skippermission',
  'skipapproval',
  'nosandbox',
];

/// Words (compacted) that make an unlisted mode elevated. A mode that looks
/// like it asks for less is shown: a wrong "elevated" costs a tint, a missed
/// one costs the person's trust.
const _elevatedWords = [
  'acceptedits',
  'autoaccept',
  'autoapprove',
  'autoedit',
  'acceptall',
  'dontask',
  'neverask',
  'noprompt',
  'noapproval',
  'unrestricted',
  'unsafe',
];

const _bypass = ModeAssessment(ModeRisk.dangerous, 'Every tool call runs without asking you.');
const _fullAccess = ModeAssessment(
  ModeRisk.dangerous,
  'Full access: the agent can change any file on the host and use the network without asking.',
);
const _acceptEdits = ModeAssessment(ModeRisk.elevated, 'File edits are accepted without asking you.');
const _auto = ModeAssessment(ModeRisk.elevated, 'A classifier, not you, approves or denies the permission prompts.');
const _codexAgent = ModeAssessment(ModeRisk.elevated, 'It asks only for actions it judges unsafe.');

/// Modes the four routes are known to send (`docs/AGENT_SESSIONS.md`, the
/// recorded traces), by compacted id or name.
///
/// - Claude Code: `default`, `plan` ("Plan Mode"), `dontAsk` (denies what is
///   not pre-approved, so it asks for nothing and runs nothing new: none),
///   `acceptEdits` and `auto` (elevated), `bypassPermissions` (dangerous).
/// - Codex: `read-only`, `workspace-write` ("Workspace access", codex's own
///   default preset: ask before leaving the workspace: none), `agent` ("Auto
///   review": elevated), `agent-full-access` ("Full access": dangerous);
///   `danger-full-access` is the sandbox name of the same thing.
/// - omp: `default`, `plan`. pi: none (its modes are thinking levels).
const _known = <String, ModeAssessment>{
  'bypasspermissions': _bypass,
  'agentfullaccess': _fullAccess,
  'fullaccess': _fullAccess,
  'dangerfullaccess': _fullAccess,
  'acceptedits': _acceptEdits,
  'auto': _auto,
  'agent': _codexAgent,
  'autoreview': _codexAgent,
  'default': ModeAssessment.none,
  'plan': ModeAssessment.none,
  'planmode': ModeAssessment.none,
  'dontask': ModeAssessment.none,
  'readonly': ModeAssessment.none,
  'workspacewrite': ModeAssessment.none,
  'workspaceaccess': ModeAssessment.none,
};
