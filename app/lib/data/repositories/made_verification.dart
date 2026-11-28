import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../host/host_link.dart' show HostException;
import '../host/host_ports.dart';
import '../services/herdr_transport.dart' show HerdrTransportException;

/// What the machine itself says about the things a session made, while the Made
/// sheet is open: whether a server's port is listening NOW and whether a page's
/// file is still there. The transcript scanner only knows what was said; this
/// turns "unknown" into a fact, or leaves it unknown.
///
/// Honest by construction: a port has an answer only while the host's helper
/// gave one (no helper, no `ports` on that machine, a lost link, a paused app:
/// no answer, and the caller says "Status unknown"). A path is known gone only
/// when the host said so.
///
/// Cost: one `made.verify` per batch of rows not yet asked (the ports of the
/// servers and the files of the tab in front), then ONE `ports.watch` for the
/// servers' ports, which sends nothing while nothing changes. Everything stops
/// at [dispose] and at [pause] (the app went to the background).
class MadeVerification extends ChangeNotifier {
  MadeVerification(this._ports, {this.watchEvery = const Duration(seconds: 5)});

  final HostPorts _ports;

  /// How often the host looks at its listeners for the watch.
  final Duration watchEvery;

  final _listening = <int, bool>{};
  final _exists = <String, bool>{};

  /// Paths asked (or being asked) and ports followed: what a later [check] skips.
  final _askedPaths = <String>{};
  final _followed = <int>{};

  StreamSubscription<List<PortListener>>? _watch;
  Future<void> _turn = Future.value();
  var _unsupported = false;
  var _disposed = false;
  var _paused = false;

  /// Per port the host answered for: true while it listens, false when it does
  /// not. A port the host did not answer for is not in the map.
  Map<int, bool> get listening => UnmodifiableMapView(_listening);

  /// Whether the host said [path] is not there.
  bool isGone(String path) => _exists[path] == false;

  /// The machine has no agent helper (or no way to look): nothing will be verified.
  bool get unsupported => _unsupported;

  /// Only a path the host can take: absolute or `~/…`.
  static bool isHostPath(String path) => path.startsWith('/') || path == '~' || path.startsWith('~/');

  /// Asks about [ports] and [paths] not asked before, in one `made.verify`
  /// (more than the host takes at once go in several), and follows [ports]
  /// while the host can tell. Never throws: what could not be asked stays
  /// unanswered and is asked again by the next call.
  Future<void> check({Iterable<int> ports = const [], Iterable<String> paths = const []}) {
    if (_unsupported || _disposed || _paused) return Future.value();
    final newPorts = {
      for (final p in ports)
        if (!_followed.contains(p)) p,
    };
    final newPaths = {
      for (final p in paths)
        if (isHostPath(p) && !_askedPaths.contains(p)) p,
    };
    if (newPorts.isEmpty && newPaths.isEmpty) return Future.value();
    _followed.addAll(newPorts);
    _askedPaths.addAll(newPaths);
    return _turn = _turn.then((_) => _ask(newPorts, newPaths));
  }

  Future<void> _ask(Set<int> ports, Set<String> paths) async {
    if (_disposed) return;
    final probes = [
      for (final p in ports) MadeProbe.port('port:$p', p),
      for (final p in paths) MadeProbe.path('path:$p', p),
    ];
    try {
      final checks = await _ports.verifyMade(probes);
      if (_disposed) return;
      var answeredPort = false;
      for (final c in checks) {
        if (c.id.startsWith('port:')) {
          final port = int.parse(c.id.substring(5));
          final up = c.listening;
          if (up != null) {
            _listening[port] = up;
            answeredPort = true;
          }
        } else {
          final exists = c.exists;
          if (exists != null) _exists[c.id.substring(5)] = exists;
        }
      }
      if (answeredPort) _follow();
    } on HostUnsupported {
      _unsupported = true;
    } on HostException {
      _forget(ports, paths);
    } on HerdrTransportException {
      _forget(ports, paths);
    }
    if (!_disposed) notifyListeners();
  }

  void _forget(Set<int> ports, Set<String> paths) {
    _followed.removeAll(ports);
    _askedPaths.removeAll(paths);
  }

  void _follow() {
    if (_watch != null) return;
    _watch = _ports
        .watch(interval: watchEvery)
        .listen(
          (found) {
            var changed = false;
            for (final port in _followed) {
              final up = found.any((l) => l.port == port);
              if (_listening[port] != up) changed = true;
              _listening[port] = up;
            }
            if (changed && !_disposed) notifyListeners();
          },
          // What the host last said is stale once it stops saying: back to unknown, asked again by the next check.
          onError: (Object _) => _stop(),
          onDone: _stop,
        );
  }

  void _stop() {
    final watch = _watch;
    _watch = null;
    unawaited(watch?.cancel());
    final had = _listening.isNotEmpty;
    _listening.clear();
    _followed.clear();
    if (had && !_disposed) notifyListeners();
  }

  /// The app is in the background: nobody looks, so the host stops watching and
  /// what it said goes back to unknown: the ports AND the files (one deleted or
  /// recreated meanwhile would keep its old row for as long as the sheet stays
  /// open). [check] asks nothing until [resume], then asks it all again.
  void pause() {
    _paused = true;
    _stop();
    final had = _exists.isNotEmpty;
    _exists.clear();
    _askedPaths.clear();
    if (had && !_disposed) notifyListeners();
  }

  /// The app is back: [check] asks again.
  void resume() => _paused = false;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_watch?.cancel());
    _watch = null;
    super.dispose();
  }
}
