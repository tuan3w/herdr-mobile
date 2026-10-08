import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/path_finder.dart';
import '../../core/motion.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import 'file_browser_screen.dart';
import 'file_viewer_screen.dart';
import 'file_widgets.dart';
import 'photo_files.dart';
import 'path_choice_sheet.dart';

/// Whether the transport can do file operations at all (false for fakes
/// without a file system, so callers hide their file actions).
bool machineSupportsFiles(MachineConnection machine) => machine.files.supported;

/// One place to look for a tapped path: [text] taken against [cwd]. A
/// [literal] attempt keeps the `:2024` the text ended with (a file really named
/// `notes:2024`), so its line is the caller's, not the suffix's.
typedef LookupAttempt = ({String text, String? cwd, bool literal});

/// Where to look for a tapped [path], in order. First the path without its
/// `:line:col` against [cwd] (and, when it had a suffix, the whole text:
/// `notes:2024` may be the file's name). Only a relative path that names no
/// place of its own (not `/x`, `~/x`, `./x`, `../x`) gets more: git's `a/` and
/// `b/` prefix taken off, and the two folders above [cwd], because an agent
/// often names a file from the project root while the pane sits in a
/// subfolder. Nothing is asked of the host here: the caller stats the
/// attempts one by one, and only after the one before was not found.
List<LookupAttempt> lookupAttempts(String path, {String? cwd}) {
  final loc = RemotePath.splitLocation(path);
  final whole = path.trim();
  final out = <LookupAttempt>[
    (text: loc.path, cwd: cwd, literal: false),
    if (loc.path != whole) (text: whole, cwd: cwd, literal: true),
  ];
  final text = loc.path;
  final explicit =
      RemotePath.isAbsolute(text) ||
      RemotePath.usesHome(text) ||
      text == '.' ||
      text == '..' ||
      text.startsWith('./') ||
      text.startsWith('../');
  if (explicit) return out;
  final variants = <String>[
    text,
    if (text.length > 2 && (text.startsWith('a/') || text.startsWith('b/')))
      text.substring(2),
  ];
  final bases = <String?>[cwd];
  if (cwd != null && RemotePath.isAbsolute(cwd)) {
    var dir = cwd;
    for (var i = 0; i < 2; i++) {
      dir = RemotePath.parent(dir);
      if (dir == '/') break;
      bases.add(dir);
    }
  }
  for (final base in bases) {
    for (final variant in variants) {
      if (base == cwd && variant == text) continue; // the first attempt
      out.add((text: variant, cwd: base, literal: false));
    }
  }
  return out;
}

/// What a tap on a path is waiting for, per navigator: the same path (or the
/// browser) is opened once, however fast the finger is. A route is on screen
/// as soon as it is pushed, but until its slide has covered the screen the old
/// screen can still be tapped, so a second tap would push a second copy.
final _opening = <(NavigatorState, String)>{};

/// What [resolveRemotePath] came to: one place ([PathFound]) or several the
/// person has to choose from ([PathChoices]).
sealed class PathResolution {
  const PathResolution(this.line);

  /// The line to open at.
  final int? line;
}

class PathFound extends PathResolution {
  const PathFound(this.stat, int? line, {this.from}) : super(line);

  final RemoteStat stat;

  /// Where it was found when that is not where the person looked
  /// (`From worktree herdr-mobile-ux`); said once when it opens.
  final String? from;
}

class PathChoices extends PathResolution {
  const PathChoices(this.candidates, int? line) : super(line);

  /// Two or more, newest first.
  final List<PathCandidate> candidates;
}

/// Longest tapped path a message quotes whole.
const _quotedPath = 56;

/// [text] cut in the middle to at most [max] characters, keeping the end (the
/// file name) longer than the start.
String cutMiddle(String text, [int max = _quotedPath]) {
  if (text.length <= max) return text;
  final tail = (max - 1) * 3 ~/ 5;
  final head = max - 1 - tail;
  return '${text.substring(0, head)}…${text.substring(text.length - tail)}';
}

/// "docs/a.md isn't in herdr-mobile (also looked in 3 worktrees)".
String pathNotFoundMessage(String shown, {String? folder, int worktrees = 0, bool searched = false}) {
  final also = [
    if (worktrees > 0) 'looked in $worktrees ${worktrees == 1 ? 'worktree' : 'worktrees'}',
    if (searched) 'searched by name',
  ];
  final where = folder == null ? "isn't on this machine" : "isn't in $folder";
  return '${cutMiddle(shown)} $where${also.isEmpty ? '' : ' (also ${also.join(' and ')})'}';
}

/// [abs] below [cwd], or null when it is not inside it.
String? _belowCwd(String? abs, String? cwd) {
  if (abs == null || cwd == null || !RemotePath.isAbsolute(cwd)) return null;
  final base = RemotePath.normalize(cwd);
  if (base == '/' || !abs.startsWith('$base/')) return null;
  final rest = abs.substring(base.length + 1);
  return rest.isEmpty ? null : rest;
}

/// Resolves [path] (absolute, `~/...`, or relative to [cwd], then the folders
/// above it), strips a trailing `:line:col` and stats it. The first place that
/// exists wins. When none does and the path is below [cwd] (or relative), the
/// other worktrees of [cwd]'s repository are asked for the same path, and
/// then, for a name that says enough (or when [search] is true), the folders
/// below [cwd] for a file of that name ([PathFinder]); [onLooking] is told
/// before each. Any other failure comes as it is, and a path found nowhere
/// throws a [PathNotFound] that says where it looked.
Future<PathResolution> resolveRemotePath(
  MachineConnection machine,
  String path, {
  String? cwd,
  int? line,
  bool search = false,
  SearchCancel? cancel,
  void Function(String what)? onLooking,
}) async {
  final loc = RemotePath.splitLocation(path);
  String? firstAbs;
  for (final attempt in lookupAttempts(path, cwd: cwd)) {
    try {
      final abs = await machine.files.resolve(attempt.text, cwd: attempt.cwd);
      firstAbs ??= abs;
      final stat = await machine.files.stat(abs);
      return PathFound(stat, attempt.literal ? line : line ?? loc.line);
    } on RemoteFileException catch (e) {
      if (e.kind != RemoteFileErrorKind.notFound) rethrow;
    }
  }

  final rel = _belowCwd(firstAbs, cwd);
  final folder = rel == null ? null : RemotePath.basename(cwd!);
  final token = cancel ?? SearchCancel();
  var worktrees = 0;
  var searched = false;
  if (rel != null && !token.isCancelled) {
    final finder = PathFinder.of(machine.files);
    final text = loc.path;
    final stripped = !RemotePath.isAbsolute(text) && text.length > 2 && (text.startsWith('a/') || text.startsWith('b/'))
        ? text.substring(2)
        : null;
    onLooking?.call('Looking in other checkouts…');
    final others = await finder.inWorktrees([rel, ?stripped], cwd!, token);
    worktrees = others.worktreesLooked;
    if (others.candidates.isNotEmpty) return _choose(others.candidates, line ?? loc.line);
    final name = RemotePath.basename(rel);
    if (!token.isCancelled && (search || PathFinder.isDistinctive(name))) {
      onLooking?.call('Searching $folder for $name…');
      final named = await finder.byName(name, cwd, token);
      searched = true;
      if (named.candidates.isNotEmpty) return _choose(named.candidates, line ?? loc.line);
    }
  }
  throw PathNotFound(
    pathNotFoundMessage(loc.path, folder: folder, worktrees: worktrees, searched: searched),
    path: loc.path,
    canSearch: rel != null && !searched,
  );
}

PathResolution _choose(List<PathCandidate> found, int? line) {
  if (found.length > 1) return PathChoices(found, line);
  final one = found.single;
  final from = switch (one.source) {
    CandidateSource.worktree => 'From worktree ${one.rootName}',
    CandidateSource.search => 'Found in ${one.folder == '.' ? one.rootName : one.folder}',
  };
  return PathFound(one.stat, line, from: from);
}

/// Opens [path]: the file viewer, or the browser for a folder. The screen is
/// pushed AT ONCE with the name and (after a moment) a skeleton, and the path
/// is looked up inside it: a tap answers on the next frame instead of after
/// the host has been asked, and a second tap while it is being found does
/// nothing. A failure (not found, permission, unreachable, ...) is shown on
/// that screen, with what to do; a machine with no file access is a quiet
/// toast and nothing is pushed. Whatever text field had the focus lets go of
/// it first: Flutter hands the focus back when the route comes off, and the
/// keyboard with it, to a person who went to read.
Future<void> openRemoteFile(
  BuildContext context,
  MachineConnection machine,
  String path, {
  String? cwd,
  int? line,
}) async {
  final navigator = Navigator.of(context);
  if (!machineSupportsFiles(machine)) {
    Toaster.of(context).show('Files are not available on this machine.', kind: ToastKind.failed);
    return;
  }
  // The keyboard would come back with Back, over the history someone is reading.
  FocusManager.instance.primaryFocus?.unfocus();
  final key = (navigator, 'path\u0000${cwd ?? ''}\u0000$path');
  if (!_opening.add(key)) return;
  try {
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => _OpenPathScreen(
          machine: machine,
          path: path,
          cwd: cwd,
          line: line,
          onResolved: () => _opening.remove(key),
        ),
      ),
    );
  } finally {
    _opening.remove(key);
  }
}

/// Pushes the directory browser, starting at [startDir] (the login directory
/// when null). The browser is on screen at once and works out where it is
/// inside; a second tap while it does is ignored.
Future<void> openFileBrowser(
  BuildContext context,
  MachineConnection machine, {
  String? startDir,
}) async {
  final navigator = Navigator.of(context);
  if (!machineSupportsFiles(machine)) {
    Toaster.of(context).show('Files are not available on this machine.', kind: ToastKind.failed);
    return;
  }
  final key = (navigator, 'browser');
  if (!_opening.add(key)) return;
  try {
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => FileBrowserScreen(
          machine: machine,
          startDir: startDir,
          onResolved: () => _opening.remove(key),
        ),
      ),
    );
  } finally {
    _opening.remove(key);
  }
}

/// Directory picker for forms: returns the chosen absolute path, or null when
/// dismissed. Pushed at once like [openFileBrowser].
Future<String?> pickRemoteDirectory(
  BuildContext context,
  MachineConnection machine, {
  String? startDir,
}) async {
  final navigator = Navigator.of(context);
  if (!machineSupportsFiles(machine)) return null;
  final key = (navigator, 'picker');
  if (!_opening.add(key)) return null;
  try {
    return await navigator.push<String>(
      MaterialPageRoute<String>(
        builder: (_) => FileBrowserScreen(
          machine: machine,
          startDir: startDir,
          mode: FileBrowserMode.pickDirectory,
          onResolved: () => _opening.remove(key),
        ),
      ),
    );
  } finally {
    _opening.remove(key);
  }
}

/// The route [openRemoteFile] pushes: a waiting page, then the viewer or the
/// browser in its place (a short cross-fade), or the reason it failed.
class _OpenPathScreen extends StatefulWidget {
  const _OpenPathScreen({
    required this.machine,
    required this.path,
    required this.cwd,
    required this.line,
    required this.onResolved,
  });

  final MachineConnection machine;
  final String path;
  final String? cwd;
  final int? line;
  final VoidCallback onResolved;

  @override
  State<_OpenPathScreen> createState() => _OpenPathScreenState();
}

class _OpenPathScreenState extends State<_OpenPathScreen> {
  PathFound? _found;
  RemoteFileException? _error;
  String? _looking;
  var _epoch = 0;
  var _cancel = SearchCancel();

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _resolve({bool search = false}) async {
    final epoch = ++_epoch;
    _cancel.cancel();
    final cancel = _cancel = SearchCancel();
    if (_error != null || _looking != null) {
      setState(() {
        _error = null;
        _looking = null;
      });
    }
    final toaster = Toaster.maybeOf(context);
    try {
      final found = await resolveRemotePath(
        widget.machine,
        widget.path,
        cwd: widget.cwd,
        line: widget.line,
        search: search,
        cancel: cancel,
        onLooking: (what) {
          if (mounted && epoch == _epoch) setState(() => _looking = what);
        },
      );
      if (!mounted || epoch != _epoch) return;
      widget.onResolved();
      // A picture opens in the immersive viewer, which replaces this waiting
      // page (its route is transparent, so it cannot swap in inside this one).
      void open(PathFound f, String? note) {
        if (f.stat.isFile && isPhotoName(f.stat.name)) {
          unawaited(Navigator.of(context).pushReplacement(photoRoute(widget.machine, f.stat)));
        } else {
          setState(() => _found = f);
        }
        if (note != null) toaster?.show(note);
      }

      switch (found) {
        case PathFound():
          open(found, found.from);
        case PathChoices(:final candidates, :final line):
          final name = RemotePath.basename(RemotePath.splitLocation(widget.path).path);
          final picked = await showPathChoices(context, name, candidates);
          if (!mounted || epoch != _epoch) return;
          if (picked == null) {
            unawaited(Navigator.of(context).maybePop());
            return;
          }
          open(
            PathFound(picked.stat, line, from: null),
            picked.source == CandidateSource.worktree ? 'From worktree ${picked.rootName}' : 'Found in ${picked.folder}',
          );
      }
    } on RemoteFileException catch (e) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = e;
        _looking = null;
      });
      widget.onResolved();
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    final error = _error;
    final name = RemotePath.basename(RemotePath.splitLocation(widget.path).path);
    final Widget page;
    if (found != null) {
      page = found.stat.isDirectory
          ? FileBrowserScreen(key: const ValueKey('found'), machine: widget.machine, path: found.stat.path)
          : FileViewerScreen(
              key: const ValueKey('found'),
              machine: widget.machine,
              stat: found.stat,
              line: found.line,
            );
    } else {
      page = FileResolvingPage(
        key: ValueKey(error == null ? 'waiting' : 'failed'),
        title: name,
        error: error,
        onRetry: () => unawaited(_resolve()),
        onSearch: () => unawaited(_resolve(search: true)),
        path: widget.path,
        note: _looking,
      );
    }
    // The pages cross-fade over their own background. Faded over nothing, each
    // is see-through for a moment and shows what is under the route (the chat,
    // shifted by the slide, and the dark backdrop where it left a gap on the
    // right): a dark flash as the file opens.
    return ColoredBox(
      color: context.ds.bg,
      child: AnimatedSwitcher(
        duration: Motion.reduced(context) ? Duration.zero : Motion.fade,
        child: page,
      ),
    );
  }
}
