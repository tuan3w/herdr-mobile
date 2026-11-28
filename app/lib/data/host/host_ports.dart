import 'dart:async';
import 'dart:math' as math;

import '../services/herdr_transport.dart';
import 'host_link.dart';

// What the agent helper (`herdr-host serve`) says about the machine's TCP
// ports: who listens, live, and the facts "Made" needs (is this file still
// there, is that port listening now). Typed wrappers over the generic host
// calls: `docs/host-api.json` lists the methods (`ports.list`, `ports.watch`,
// `made.verify`), `rust/crates/host/src/svc/ports.rs` and `made.rs` are the
// reference.

/// The machine cannot answer: the agent helper is not installed, or this
/// machine has no way to look (`reason` says which, in the helper's words).
/// Callers dim what depends on it and keep it listed; they never show an
/// empty answer for it, because "nothing listens" and "cannot tell" differ.
class HostUnsupported implements Exception {
  const HostUnsupported(this.reason);

  final String reason;

  /// The reason is the app's own words about a machine without the agent helper
  /// (every one of them says "agent helper"), not the helper saying that this
  /// machine cannot look at its ports.
  bool get helperMissing => reason.contains('agent helper');

  @override
  String toString() => reason;
}

/// Runs [body]; a host that cannot serve (`unavailable`) becomes [HostUnsupported].
/// Any other [HostException] (and [HostLinkLost]) stays what it is.
Future<T> _supported<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on HostException catch (e) {
    if (e.code == 'unavailable') throw HostUnsupported(e.message);
    rethrow;
  }
}

/// One TCP socket in the LISTEN state.
class PortListener {
  const PortListener({required this.family, required this.addr, required this.port, this.pid, this.process, this.user});

  factory PortListener.fromJson(Object? json) {
    if (json is! Map) throw const HostException('bad_response', 'a listener is not an object');
    final family = json['family'], addr = json['addr'], port = json['port'];
    if (family is! int || addr is! String || port is! int) {
      throw const HostException('bad_response', 'a listener has no family, address and port');
    }
    return PortListener(
      family: family,
      addr: addr,
      port: port,
      pid: json['pid'] as int?,
      process: json['process'] as String?,
      user: json['user'] as String?,
    );
  }

  /// 4 or 6.
  final int family;

  /// The bound address as the host prints it: `127.0.0.1`, `0.0.0.0`, `::1`, `::`.
  final String addr;
  final int port;

  /// The owner, where this user may see it; null otherwise.
  final int? pid;
  final String? process;
  final String? user;

  /// What a change is keyed by: an owner that becomes visible later is not a new socket.
  String get key => '$family|$addr|$port';

  @override
  bool operator ==(Object other) =>
      other is PortListener &&
      other.family == family &&
      other.addr == addr &&
      other.port == port &&
      other.pid == pid &&
      other.process == process &&
      other.user == user;

  @override
  int get hashCode => Object.hash(family, addr, port, pid, process, user);

  @override
  String toString() => '$addr:$port';
}

/// What `ports.watch` sends after its first message: sockets that appeared and
/// sockets that went away.
class PortsChange {
  const PortsChange({required this.opened, required this.closed});

  factory PortsChange.fromJson(Map<Object?, Object?> json) =>
      PortsChange(opened: _listeners(json['opened']), closed: _listeners(json['closed']));

  final List<PortListener> opened;
  final List<PortListener> closed;
}

List<PortListener> _listeners(Object? json) => [
  if (json is List)
    for (final l in json) PortListener.fromJson(l),
];

/// Port order as the host sorts: port, then family, then address.
int _byPort(PortListener a, PortListener b) {
  final c = a.port.compareTo(b.port);
  if (c != 0) return c;
  final f = a.family.compareTo(b.family);
  return f != 0 ? f : a.addr.compareTo(b.addr);
}

/// One thing for `made.verify` to check: a file (`path`: absolute or `~/…`) or
/// a port.
class MadeProbe {
  const MadeProbe.path(this.id, String this.path) : port = null;
  const MadeProbe.port(this.id, int this.port) : path = null;

  /// Echoed in the answer.
  final String id;
  final String? path;
  final int? port;

  Map<String, Object?> toJson() => {'id': id, if (path != null) 'path': path, if (port != null) 'port': port};
}

/// What the host found for one [MadeProbe].
class MadeCheck {
  const MadeCheck({
    required this.id,
    this.exists,
    this.kind,
    this.size,
    this.modifiedMs,
    this.listening,
    this.pid,
    this.process,
    this.error,
  });

  factory MadeCheck.fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) {
      throw const HostException('bad_response', 'a verified item has no id');
    }
    return MadeCheck(
      id: json['id'] as String,
      exists: json['exists'] as bool?,
      kind: json['kind'] as String?,
      size: json['size'] as int?,
      modifiedMs: json['mtime_ms'] as int?,
      listening: json['listening'] as bool?,
      pid: json['pid'] as int?,
      process: json['process'] as String?,
      error: json['error'] as String?,
    );
  }

  final String id;

  /// A path: whether it is there (null when the host could not tell, see [error]).
  final bool? exists;

  /// `file`, `dir` or `other`, for a path that exists.
  final String? kind;
  final int? size;
  final int? modifiedMs;

  /// A port: whether something listens on it now (null when the host could not tell).
  final bool? listening;
  final int? pid;
  final String? process;

  /// Why the host could not answer this one item: `unavailable` (no way to list
  /// ports on this machine), `permission`, `failed`.
  final String? error;
}

/// The machine's ports and "made" facts, asked of the agent helper through the
/// machine's transport. Every method throws [HostUnsupported] when the helper
/// is not there (or cannot look), [HostException] for anything else the host
/// answered, [HostLinkLost] when the connection dropped.
class HostPorts {
  HostPorts(this._transport);

  final HerdrTransport _transport;

  /// Items one `made.verify` takes.
  static const verifyLimit = 200;

  /// The least `ports.watch` accepts.
  static const minInterval = Duration(seconds: 1);

  /// Every TCP listener now, by port.
  Future<List<PortListener>> list() => _supported(() async {
    final answer = await _transport.hostCall('ports', 'list');
    if (answer is! Map) throw const HostException('bad_response', 'ports.list answered something else');
    return _listeners(answer['listeners']);
  });

  /// The listener list now, and again after every change, until cancelled. The
  /// first element is the full list the host starts with; each later one is
  /// that list with the host's `{opened, closed}` applied. Errors as the
  /// methods do, then closes. Cancelling ends the host's watch.
  Stream<List<PortListener>> watch({Duration interval = const Duration(seconds: 2)}) {
    final known = <String, PortListener>{};
    final args = {'interval_ms': (interval < minInterval ? minInterval : interval).inMilliseconds};
    StreamSubscription<Object?>? sub;
    late final StreamController<List<PortListener>> out;

    void fail(Object error, StackTrace stack) {
      if (out.isClosed) return;
      out.addError(
        error is HostException && error.code == 'unavailable' ? HostUnsupported(error.message) : error,
        stack,
      );
      unawaited(sub?.cancel());
      unawaited(out.close());
    }

    void onMessage(Object? message) {
      try {
        if (message is! Map) throw const HostException('bad_response', 'ports.watch sent something else');
        if (message.containsKey('listeners')) {
          known
            ..clear()
            ..addEntries([for (final l in _listeners(message['listeners'])) MapEntry(l.key, l)]);
        } else {
          final change = PortsChange.fromJson(message);
          for (final l in change.closed) {
            known.remove(l.key);
          }
          for (final l in change.opened) {
            known[l.key] = l;
          }
        }
        out.add(known.values.toList()..sort(_byPort));
      } on HostException catch (e, s) {
        fail(e, s);
      }
    }

    out = StreamController<List<PortListener>>(
      onListen: () {
        sub = _transport
            .openHostMessages('ports', 'watch', args)
            .listen(onMessage, onError: fail, onDone: () => unawaited(out.close()));
      },
      // Cancelling the transport's stream is what ends the host's watch.
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  /// One answer per probe, in order. More than [verifyLimit] probes go in
  /// several calls (the host takes that many at once).
  Future<List<MadeCheck>> verifyMade(List<MadeProbe> probes) => _supported(() async {
    final checks = <MadeCheck>[];
    for (var i = 0; i < probes.length; i += verifyLimit) {
      final batch = probes.sublist(i, math.min(i + verifyLimit, probes.length));
      final answer = await _transport.hostCall('made', 'verify', {'items': batch.map((p) => p.toJson()).toList()});
      final results = answer is Map ? answer['results'] : null;
      if (results is! List || results.length != batch.length) {
        throw const HostException('bad_response', 'made.verify answered another number of items');
      }
      checks.addAll(results.map(MadeCheck.fromJson));
    }
    return checks;
  });
}
