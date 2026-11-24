import '../models/remote_file.dart';
import 'acp_models.dart';
import 'session_state.dart';
import 'turns/tool_summary.dart' show commandOf;
import 'turns/turns.dart' show pathOfCall;

/// What a session's own tool calls say about where its work happened: the
/// folders the agent ran in and the files its calls touched. A name in the
/// agent's prose is usually a name in those places, not in the folder the
/// session was started from, so a tap tries them before it searches. Nothing
/// is asked of the host to build this; it is read from the transcript.
class PathHints {
  const PathHints({this.folders = const [], this.touched = const []});

  static const none = PathHints();

  /// Absolute folders a call ran in (its `cwd`, or where a `cd` took it),
  /// newest first.
  final List<String> folders;

  /// Absolute paths the calls read, wrote or named, newest first.
  final List<String> touched;

  bool get isEmpty => folders.isEmpty && touched.isEmpty;
}

/// How many of the newest tool calls are read, and what is kept of them.
const _scanTools = 400;
const _maxFolders = 8;
const _maxTouched = 300;

/// Most places one step asks the host about: the paths of a name's own step,
/// and the folders of touched files (cheap stats, but a bound all the same).
const _maxStepPaths = 12;
const _maxSiblingPaths = 24;

final _cd = RegExp(r'''(?:^|&&|;|\|\||\n)\s*cd\s+("[^"]+"|'[^']+'|[^\s;&|]+)''');

/// The folders and files the newest tool calls of [items] worked in. [cwd] is
/// the session's folder: where a call that names none ran, and what a relative
/// path is taken against.
PathHints pathHintsOf(List<TranscriptItem> items, {required String cwd}) {
  final folders = <String>{};
  final touched = <String>{};
  var seen = 0;
  for (var i = items.length - 1; i >= 0 && seen < _scanTools; i--) {
    final item = items[i];
    if (item is! TranscriptTool) continue;
    seen++;
    final call = item.call;
    final base = _folderOf(call, cwd) ?? cwd;
    var ran = base;
    if (call.kind == ToolKind.execute) {
      final command = commandOf(call);
      if (command != null) {
        for (final m in _cd.allMatches(command)) {
          final to = m.group(1)!.replaceAll(RegExp('^["\']|["\']\$'), '');
          if (RemotePath.usesHome(to)) break; // the host's home is not known here
          ran = RemotePath.resolve(to, cwd: ran) ?? ran;
        }
      }
    }
    if (ran != cwd && folders.length < _maxFolders) folders.add(ran);
    if (base != ran && base != cwd && folders.length < _maxFolders) folders.add(base);

    void add(String? raw) {
      if (raw == null || raw.isEmpty || raw.contains('://') || RemotePath.usesHome(raw)) return;
      final abs = RemotePath.resolve(raw, cwd: base);
      if (abs != null && touched.length < _maxTouched) touched.add(abs);
    }

    for (final l in call.locations) {
      add(l.path);
    }
    for (final c in call.content) {
      if (c is ToolDiff) add(c.path);
    }
    add(pathOfCall(call));
  }
  return PathHints(folders: folders.toList(growable: false), touched: touched.toList(growable: false));
}

/// The folder a call says it ran in: its terminal's `cwd`, else a `cwd` or
/// `workdir` in its input. Null when it names none.
String? _folderOf(ToolCall call, String cwd) {
  final named = call.cwd;
  if (named != null && named.isNotEmpty) return RemotePath.resolve(named, cwd: cwd);
  final input = call.rawInput;
  if (input is Map) {
    for (final key in const ['cwd', 'workdir']) {
      final v = input[key];
      if (v is String && v.trim().isNotEmpty && !RemotePath.usesHome(v)) return RemotePath.resolve(v, cwd: cwd);
    }
  }
  return null;
}

/// What a step of [hintSteps] is made of.
enum HintStepKind {
  /// The text taken against a folder the agent ran in.
  agentFolder,

  /// A path a tool call touched that ends with the text.
  touched,

  /// The text taken against the folder of a file a tool call touched: the
  /// other files of the same message are usually in the same place.
  touchedFolder,
}

/// Places to ask the host about, all of one [kind]: they are tried together,
/// and the first step that has an answer wins.
class HintStep {
  const HintStep(this.kind, this.paths);

  final HintStepKind kind;
  final List<String> paths;
}

/// The names [text] may be written as: without a leading `./`, and, when
/// git's `a/` or `b/` prefix is on it, without that too.
List<String> _variants(String text) {
  var t = text.trim();
  if (t.startsWith('./')) t = t.substring(2);
  return [t, if (t.length > 2 && (t.startsWith('a/') || t.startsWith('b/'))) t.substring(2)];
}

/// The places [hints] suggest for a tapped relative [text], cheapest first:
/// the agent's folders, the paths its calls touched, the folders of those.
/// Places the plain lookup against [cwd] and the two folders above it has
/// tried are left out. Empty for an absolute path, a `~/` path and an empty text.
List<HintStep> hintSteps(String text, PathHints hints, {String? cwd}) {
  final t = text.trim();
  if (t.isEmpty || RemotePath.isAbsolute(t) || RemotePath.usesHome(t) || hints.isEmpty) return const [];
  final variants = _variants(t);
  final seen = <String>{};
  if (cwd != null && RemotePath.isAbsolute(cwd)) {
    var dir = cwd;
    for (var i = 0; i < 3 && dir != '/'; i++) {
      for (final v in variants) {
        seen.add(RemotePath.normalize('$dir/$v'));
      }
      dir = RemotePath.parent(dir);
    }
  }
  List<String> fresh(Iterable<String> paths, int cap) {
    final out = <String>[];
    for (final p in paths) {
      if (out.length >= cap) break;
      if (seen.add(p)) out.add(p);
    }
    return out;
  }

  final up = t.startsWith('../');
  final steps = <HintStep>[];
  final inFolders = fresh([
    for (final f in hints.folders)
      for (final v in variants) RemotePath.normalize('$f/$v'),
  ], _maxStepPaths);
  if (inFolders.isNotEmpty) steps.add(HintStep(HintStepKind.agentFolder, inFolders));
  if (up) return steps;
  final tails = [for (final v in variants) '/${RemotePath.normalize(v)}'];
  final named = fresh([
    for (final p in hints.touched)
      if (tails.any(p.endsWith)) p,
  ], _maxStepPaths);
  if (named.isNotEmpty) steps.add(HintStep(HintStepKind.touched, named));
  final dirs = <String>{for (final p in hints.touched) RemotePath.parent(p)};
  final siblings = fresh([
    for (final d in dirs)
      for (final v in variants) RemotePath.normalize('$d/$v'),
  ], _maxSiblingPaths);
  if (siblings.isNotEmpty) steps.add(HintStep(HintStepKind.touchedFolder, siblings));
  return steps;
}

/// Whether a tool call of the session touched the file [text] names: the same
/// absolute path, or a path ending with the relative text. Used to say a file
/// "isn’t there any more" when the agent did use it, instead of "isn’t in the folder".
bool wasTouched(String text, PathHints hints) {
  final t = text.trim();
  if (t.isEmpty || RemotePath.usesHome(t)) return false;
  if (RemotePath.isAbsolute(t)) {
    final n = RemotePath.normalize(t);
    return hints.touched.contains(n);
  }
  if (t.startsWith('../')) return false;
  final tails = [for (final v in _variants(t)) '/${RemotePath.normalize(v)}'];
  return hints.touched.any((p) => tails.any(p.endsWith));
}
