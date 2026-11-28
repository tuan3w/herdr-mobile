import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/host/host_link.dart' show HostException, HostLinkLost;
import '../../../data/host/host_ports.dart';
import '../../../data/models/web_bridge.dart' show isPreviewHost, sensitiveServiceOf;
import '../../../data/words/error_words.dart';

/// One port the machine listens on, as the sheet shows it: every address the
/// port is bound to is one row (IPv4 and IPv6 `localhost` are one thing).
class PortRow {
  const PortRow({required this.port, required this.addrs, this.process, this.pid, this.listening = true});

  final int port;

  /// What the port is bound to, as the host prints it (`127.0.0.1`, `::`, `192.168.1.5`).
  final List<String> addrs;
  final String? process;
  final int? pid;

  /// False once the port stopped listening while the sheet was open: the row
  /// keeps its place (nothing moves under a thumb) and says so.
  final bool listening;

  String get title => process ?? 'Port $port';

  /// Reachable as `localhost` from the machine itself: bound to loopback or to
  /// every address. A port on one other address (the LAN's) is not.
  bool get onLocalhost => addrs.any(isPreviewHost);

  /// What the port is by convention when it is not a web server (SSH, a database).
  String? get service => sensitiveServiceOf(port);

  /// Why a tap does nothing, or null when it opens the port as a page.
  String? get reason {
    if (!listening) return 'No longer listening';
    final service = this.service;
    if (service != null) return '$service · not a web page';
    if (!onLocalhost) return 'Not on localhost';
    return null;
  }

  /// `localhost:3000`, or the one address the port is on when that is not the machine itself.
  String get address {
    if (onLocalhost) return 'localhost:$port';
    final addr = addrs.first;
    return addr.contains(':') ? '[$addr]:$port' : '$addr:$port';
  }

  /// `localhost:3000 · pid 4242 · SSH · not a web page`.
  String get subtitle => [address, if (pid != null) 'pid $pid', ?reason].join(' · ');

  /// The page the port opens as: the machine's own `localhost`, the one name every spelling shares.
  Uri get url => Uri(scheme: 'http', host: 'localhost', port: port, path: '/');

  /// One row per port of [listeners] (already in port order).
  static List<PortRow> group(List<PortListener> listeners) {
    final byPort = <int, List<PortListener>>{};
    for (final l in listeners) {
      (byPort[l.port] ??= []).add(l);
    }
    return [
      for (final MapEntry(key: port, value: all) in byPort.entries)
        PortRow(
          port: port,
          addrs: {for (final l in all) l.addr}.toList(),
          // Both families may listen; the one whose owner is visible tells.
          process: all.firstWhere((l) => l.process != null, orElse: () => all.first).process,
          pid: all.firstWhere((l) => l.pid != null, orElse: () => all.first).pid,
        ),
    ];
  }

  PortRow gone() => PortRow(port: port, addrs: addrs, process: process, pid: pid, listening: false);
}

enum PortsPhase {
  /// The first answer is on its way.
  loading,

  /// The machine answers; [PortsViewModel.rows] are what listens now.
  live,

  /// This machine cannot say (no agent helper, no way to list ports).
  unsupported,

  /// The link failed; [PortsViewModel.error] says what and what to do.
  failed,
}

/// What listens on a machine, live while the sheet is open: the host's
/// `ports.watch` (it sends only changes), cancelled by [dispose] and [pause] (the
/// app went to the background).
///
/// Rows keep the order they first appeared in (a new port joins at the end, a
/// port that stopped stays, dimmed): a list that reshuffles under a thumb
/// sends the tap to the wrong row.
class PortsViewModel extends ChangeNotifier {
  PortsViewModel({required this._ports, required this.machineName});

  final HostPorts _ports;
  final String machineName;

  StreamSubscription<List<PortListener>>? _watch;
  var _phase = PortsPhase.loading;
  var _rows = const <PortRow>[];
  String? _error;
  HostUnsupported? _unsupported;
  var _disposed = false;

  PortsPhase get phase => _phase;

  /// In the order they appeared.
  List<PortRow> get rows => _rows;

  /// Set while [phase] is [PortsPhase.failed]: a sentence for the person.
  String? get error => _error;

  /// Set while [phase] is [PortsPhase.unsupported].
  HostUnsupported? get unsupported => _unsupported;

  /// Starts watching; nothing happens when it already does.
  void start() {
    if (_watch != null || _disposed) return;
    _watch = _ports.watch().listen(
      _found,
      onError: _failed,
      // The end that follows an error is the same failure, said already.
      onDone: () {
        if (_watch != null) _failed(const HostLinkLost('the connection to the machine ended'));
      },
    );
  }

  /// The app is in the background: the host stops watching. [resume] starts again.
  void pause() {
    final watch = _watch;
    _watch = null;
    unawaited(watch?.cancel());
  }

  void resume() {
    if (_phase == PortsPhase.live || _phase == PortsPhase.loading) start();
  }

  /// Tries again after a failure.
  void retry() {
    pause();
    _phase = PortsPhase.loading;
    _error = null;
    _notify();
    start();
  }

  void _found(List<PortListener> listeners) {
    final now = PortRow.group(listeners);
    final byPort = {for (final r in now) r.port: r};
    final seen = {for (final r in _rows) r.port};
    _rows = [
      for (final r in _rows) byPort[r.port] ?? (r.listening ? r.gone() : r),
      for (final r in now)
        if (!seen.contains(r.port)) r,
    ];
    _phase = PortsPhase.live;
    _error = null;
    _notify();
  }

  void _failed(Object error) {
    _watch = null;
    _rows = const [];
    if (error is HostUnsupported) {
      _phase = PortsPhase.unsupported;
      _unsupported = error;
    } else {
      _phase = PortsPhase.failed;
      _error = _words(error);
    }
    _notify();
  }

  String _words(Object error) {
    if (error is HostLinkLost || (error is HostException && error.retryable)) {
      return 'Lost the connection to $machineName. Check it’s online, then Retry.';
    }
    if (error is HostException) {
      final said = error.message.trim();
      return said.isEmpty
          ? 'The machine couldn’t list its ports. Retry.'
          : 'The machine couldn’t list its ports: $said';
    }
    return describeError(error, machine: machineName);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    super.dispose();
  }
}
