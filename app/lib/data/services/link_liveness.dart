import 'dart:async';

/// How often a connection is tested, for one of the two ways the app is used.
///
/// In the foreground a dead link must show within seconds: the person is
/// looking at it. In the background the app only watches agents for a local
/// notification, and every test is a radio wake-up that costs battery, so the
/// intervals stretch; a link that died meanwhile is found on the way back
/// (see `HerdrTransport.setBackground`).
class LivenessTiming {
  const LivenessTiming({
    required this.muxInterval,
    required this.muxTimeout,
    required this.linkInterval,
    required this.linkTimeout,
  });

  /// The mux script is pinged this often, and must answer within [muxTimeout].
  final Duration muxInterval;
  final Duration muxTimeout;

  /// An SSH link with no inbound bytes for [linkInterval] is pinged; a pinged
  /// link silent for [linkTimeout] is dead.
  final Duration linkInterval;
  final Duration linkTimeout;

  static const foreground = LivenessTiming(
    muxInterval: Duration(seconds: 8),
    muxTimeout: Duration(seconds: 5),
    linkInterval: Duration(seconds: 25),
    linkTimeout: Duration(seconds: 10),
  );

  /// The mux heartbeat is the first test to fire (every 120 s) and its answer
  /// counts as inbound bytes, so the link's own ping (150 s) only goes out
  /// when the mux is not in use.
  static const background = LivenessTiming(
    muxInterval: Duration(seconds: 120),
    muxTimeout: Duration(seconds: 15),
    linkInterval: Duration(seconds: 150),
    linkTimeout: Duration(seconds: 15),
  );

  static LivenessTiming of({required bool background}) =>
      background ? LivenessTiming.background : LivenessTiming.foreground;
}

/// When an SSH connection needs a ping, and when an unanswered one means the
/// link is dead. Pure decisions over an injectable monotonic clock; the timers
/// and the ping itself are [LinkWatch]'s.
///
/// Any inbound byte counts as proof of life ([inbound]), not only the ping's
/// own reply. A reply queues behind whatever the host is sending, so on a slow
/// link a ping sent during a multi-megabyte replay is answered late; judging
/// it by its reply alone would reset the connection and restart the replay,
/// for ever. An idle link is the only one that needs a ping, and one that is
/// busy costs no extra packets.
class LinkLiveness {
  LinkLiveness({
    this.interval = const Duration(seconds: 25),
    this.timeout = const Duration(seconds: 10),
    Duration Function()? clock,
  }) : _now = clock ?? _stopwatchClock() {
    _lastInbound = _now();
  }

  /// How long a link may be silent before it is pinged. May be changed while
  /// the link is watched; [LinkWatch.configure] does that and re-arms.
  Duration interval;

  /// How long a pinged link may stay silent before it is declared dead.
  Duration timeout;

  final Duration Function() _now;
  late Duration _lastInbound;
  Duration? _pingSentAt;

  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// Bytes arrived from the host. Cheap: called for every received chunk.
  void inbound() => _lastInbound = _now();

  /// How long until the link needs a ping; [Duration.zero] when it does now.
  Duration untilPing() {
    final left = interval - (_now() - _lastInbound);
    return left.isNegative ? Duration.zero : left;
  }

  /// A ping is on its way.
  void pingSent() => _pingSentAt = _now();

  /// The ping was answered.
  void pingAnswered() {
    _pingSentAt = null;
    inbound();
  }

  /// How long to wait before judging the outstanding ping: [Duration.zero]
  /// means the link has been silent for [timeout] since the ping (or since the
  /// last byte, if that came later) and is dead. Anything else is the time
  /// until the next look.
  Duration untilVerdict() {
    final sent = _pingSentAt ?? _lastInbound;
    final since = sent > _lastInbound ? sent : _lastInbound;
    final left = timeout - (_now() - since);
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether a ping is waiting for its answer.
  bool get pinging => _pingSentAt != null;
}

/// Watches one connection with a single timer that wakes only when a decision
/// of [LinkLiveness] is due. A link that stays silent after a ping is dead:
/// [onDead] runs once and the watch stops.
class LinkWatch {
  LinkWatch({
    required this.liveness,
    required this.ping,
    required this.onDead,
    required this.isClosed,
  });

  final LinkLiveness liveness;

  /// Sends one ping and completes when it is answered (or fails).
  final Future<void> Function() ping;
  final void Function() onDead;
  final bool Function() isClosed;

  Timer? _timer;
  var _stopped = false;
  var _timers = 0;

  /// How many timers were ever created, and whether one is armed now. For
  /// tests: re-arming must replace the timer, never add one.
  int get timersCreated => _timers;
  bool get armed => _timer?.isActive ?? false;

  /// Starts watching: the first decision is due when the link has been quiet
  /// for [LinkLiveness.interval].
  void start() => _arm(liveness.untilPing());

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// New intervals, effective at once: the timer is replaced, and the next
  /// decision is made from the time the link has already been quiet, so no
  /// gap is longer than the new interval. With [checkNow] the link is tested
  /// now if it has been quiet for longer than the new interval (the app came
  /// back to the foreground: a link that died meanwhile must show in
  /// seconds).
  void configure(Duration interval, Duration timeout, {bool checkNow = false}) {
    liveness
      ..interval = interval
      ..timeout = timeout;
    if (_stopped) return;
    if (checkNow) {
      _check();
    } else {
      _arm(liveness.pinging ? liveness.untilVerdict() : liveness.untilPing());
    }
  }

  void _arm(Duration after) {
    if (_stopped) return;
    _timer?.cancel();
    _timers++;
    _timer = Timer(after, _check);
  }

  void _check() {
    if (_stopped || isClosed()) return;
    if (liveness.pinging) {
      final left = liveness.untilVerdict();
      if (left == Duration.zero) {
        stop();
        onDead();
      } else {
        _arm(left);
      }
      return;
    }
    final wait = liveness.untilPing();
    if (wait > Duration.zero) {
      _arm(wait);
      return;
    }
    liveness.pingSent();
    ping().then((_) => liveness.pingAnswered(), onError: (Object _) {
      if (_stopped) return;
      stop();
      onDead();
    });
    _arm(liveness.timeout);
  }
}
