import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/models/remote_search.dart';
import '../../../data/services/remote_files.dart';
import '../../core/motion.dart';

/// How recently a match changed.
enum SearchWindow {
  any('Any time'),
  hour('Last hour'),
  today('Today');

  const SearchWindow(this.label);

  final String label;
}

/// Where a search is.
enum SearchPhase {
  /// Nothing to look for yet: no text and no time window.
  idle,

  /// Matches are arriving.
  searching,

  /// The machine finished (see [FileSearchViewModel.truncated]).
  done,

  /// The search could not run or broke off; [FileSearchViewModel.error] says why.
  failed,
}

/// A search below one folder: what was typed, how recent a match must be, the
/// matches as they arrive, and how it ended. The machine does the looking
/// ([RemoteFiles.search]); this keeps what the screen shows.
///
/// It runs only while it matters: after typing pauses (or at once for a tap on
/// a time chip or the keyboard's search key), never for an empty question, and
/// only while the screen is in front ([setActive]): a search that was cut off
/// by another screen or the background continues where it was when the person
/// is back, without moving the rows already shown. A newer question replaces
/// the older one at once: what the old stream still delivers is thrown away.
/// Typed text survives every failure.
class FileSearchViewModel extends ChangeNotifier {
  FileSearchViewModel({
    required this._files,
    required this.root,
    required this.rootName,
    this.kind = FileSearchKind.any,
    this.hidden = false,
    this.maxResults = FileSearchSpec.defaultMaxResults,
    this.typingPause = Dwell.typingPause,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final RemoteFiles _files;
  final DateTime Function() _clock;

  /// The folder searched, and what it is called on screen.
  final String root;
  final String rootName;

  /// Folders only (a folder picker) or anything.
  final FileSearchKind kind;

  /// Names that start with a dot are looked at (the browser's choice).
  final bool hidden;
  final int maxResults;

  /// How long typing has to pause before the machine is asked.
  final Duration typingPause;

  var _query = '';
  var _window = SearchWindow.any;
  var _phase = SearchPhase.idle;
  final _results = <RemoteEntry>[];
  final _seen = <String>{};
  var _scanned = 0;
  var _truncated = false;
  var _skipped = 0;
  RemoteFileException? _error;
  StreamSubscription<FileSearchEvent>? _sub;
  Timer? _timer;
  var _epoch = 0;
  var _active = true;
  var _interrupted = false;
  var _disposed = false;

  String get query => _query;
  SearchWindow get window => _window;
  SearchPhase get phase => _phase;

  /// The matches so far, shallow ones first, in the order they arrived.
  List<RemoteEntry> get results => List.unmodifiable(_results);
  int get resultCount => _results.length;

  /// Entries the machine looked at (known when it is done).
  int get scanned => _scanned;

  /// The machine stopped at a limit (results, entries looked at, time): there
  /// may be more matches.
  bool get truncated => _truncated;

  /// Folders that could not be read and were left out.
  int get skippedFolders => _skipped;
  RemoteFileException? get error => _error;

  /// Something to look for: text, or a time window (which alone means "what
  /// changed lately, anywhere below here").
  bool get hasQuestion => _query.trim().isNotEmpty || _window != SearchWindow.any;

  /// The machine is being asked right now.
  bool get running => _sub != null;

  /// Typing: asks the machine once typing pauses; an empty question stops the
  /// search and clears the matches.
  void setQuery(String text) {
    if (text == _query) return;
    _query = text;
    _timer?.cancel();
    if (!hasQuestion) {
      _reset();
    } else if (typingPause == Duration.zero) {
      _begin();
    } else {
      _timer = Timer(typingPause, _begin);
    }
  }

  /// The keyboard's search key: ask now instead of waiting for the pause.
  void submit() {
    _timer?.cancel();
    if (hasQuestion) {
      _begin();
    } else {
      _reset();
    }
  }

  void setWindow(SearchWindow value) {
    if (value == _window) return;
    _window = value;
    _timer?.cancel();
    if (hasQuestion) {
      _begin();
    } else {
      _reset();
    }
  }

  /// Asks again after a failure (the typed text and window stay).
  void retry() => _begin();

  /// Whether the screen is in front with the app in the foreground. Away, the
  /// machine is not kept searching for nobody; back, a search that was cut off
  /// goes on (what is already listed stays where it is).
  void setActive(bool active) {
    if (_active == active || _disposed) return;
    _active = active;
    if (!active) {
      _timer?.cancel();
      if (_sub != null) {
        _interrupted = true;
        _stop();
      }
    } else if (_interrupted) {
      _interrupted = false;
      _start(resume: true);
    }
  }

  void _reset() {
    _stop();
    _epoch++;
    _interrupted = false;
    _results.clear();
    _seen.clear();
    _error = null;
    _truncated = false;
    _scanned = 0;
    _skipped = 0;
    _phase = SearchPhase.idle;
    notifyListeners();
  }

  /// A new question: the old matches go, the machine is asked.
  void _begin() {
    _timer?.cancel();
    if (!hasQuestion) {
      _reset();
      return;
    }
    _stop();
    _epoch++;
    _interrupted = false;
    _results.clear();
    _seen.clear();
    _error = null;
    _truncated = false;
    _scanned = 0;
    _skipped = 0;
    _phase = SearchPhase.searching;
    notifyListeners();
    if (_active) {
      _start(resume: false);
    } else {
      _interrupted = true;
    }
  }

  FileSearchSpec _spec() {
    final now = _clock().toLocal();
    final Duration? within = switch (_window) {
      SearchWindow.any => null,
      SearchWindow.hour => const Duration(hours: 1),
      SearchWindow.today => now.difference(DateTime(now.year, now.month, now.day)),
    };
    return FileSearchSpec(
      root: root,
      query: _query.trim(),
      kind: kind,
      modifiedWithin: within == null
          ? null
          : (within < const Duration(seconds: 1) ? const Duration(seconds: 1) : within),
      maxResults: maxResults,
      hidden: hidden,
    );
  }

  void _start({required bool resume}) {
    final epoch = _epoch;
    _phase = SearchPhase.searching;
    if (resume) notifyListeners();
    _sub = _files
        .search(_spec())
        .listen(
          (event) => _onEvent(epoch, event),
          onError: (Object e, StackTrace s) => _onError(epoch, e),
          onDone: () => _onClosed(epoch),
        );
  }

  void _stop() {
    final sub = _sub;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
  }

  void _onEvent(int epoch, FileSearchEvent event) {
    if (epoch != _epoch || _disposed) return;
    switch (event) {
      case FileSearchBatch(:final entries):
        var added = false;
        for (final e in entries) {
          // A search taken up again after an interruption lists the same
          // matches first: they are already there.
          if (_seen.add(e.path)) {
            _results.add(e);
            added = true;
          }
        }
        if (added) notifyListeners();
      case FileSearchDone(:final scanned, :final truncated, :final skippedDirs):
        _scanned = scanned;
        _truncated = truncated;
        _skipped = skippedDirs;
        _phase = SearchPhase.done;
        _sub = null;
        notifyListeners();
    }
  }

  void _onError(int epoch, Object error) {
    if (epoch != _epoch || _disposed) return;
    _error = error is RemoteFileException ? error : RemoteFileException(RemoteFileErrorKind.network, '$error');
    _phase = SearchPhase.failed;
    _sub = null;
    notifyListeners();
  }

  void _onClosed(int epoch) {
    if (epoch != _epoch || _disposed || _phase != SearchPhase.searching) return;
    // The stream ended without saying it was done: not a finished search.
    _error = RemoteFileException(RemoteFileErrorKind.network, 'The search stopped early');
    _phase = SearchPhase.failed;
    _sub = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _stop();
    super.dispose();
  }
}
