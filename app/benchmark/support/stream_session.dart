// What the stream bench feeds the real `AgentSessionScreen`: a session that
// behaves like `AcpAgentSession` towards the UI, a long transcript to sit
// above the stream, a 20 KB markdown answer, and the arrival profiles.
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math' as math;

import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/streaming/flush_scheduler.dart';

import '../../test/support/fake_agent_session.dart';
import 'trace_cadence.dart';

/// An [AgentSessionView] for the real screen, driven by [ingest].
///
/// It mirrors the data path of `AcpAgentSession` and nothing else (if that
/// class changes how it ingests an update or when it notifies, change
/// [ingest], [send], [finish] and [_schedule] here: this is the one place the
/// bench copies the data layer):
/// - `AgentSessionState.apply` per chunk, so the cost of the reducer is
///   measured with the transcript's real length. A chunk of the streaming
///   message appends to its live slot and leaves the item list alone, as in
///   the real session;
/// - one notification per flush of the [FlushScheduler], coalescing what came
///   in between: the device bench passes `FrameFlush` (the real session's
///   scheduler), a unit test the default timer; every change, urgent or
///   not, waits for it, and the flush also announces the live text
///   (`FakeAgentSession.push`).
/// The agent, the keeper, SSH and the transport isolate are not here; their
/// cost is not in the numbers.
class StreamBenchSession extends FakeAgentSession {
  StreamBenchSession(AgentSessionState initial, {FlushScheduler flush = const TimerFlush()})
      : _pending = initial,
        _scheduler = flush,
        super(state: initial, key: 'bench/stream', agent: 'omp', agentLabel: 'omp', cwd: '/tmp/scratch', title: 'scratch');

  final FlushScheduler _scheduler;
  AgentSessionState _pending;
  FlushCancel? _cancel;

  /// Per [ingest] call, microseconds: parse, apply, schedule the notification.
  final chunkCostUs = <int>[];

  /// `Timeline.now` of every notification the screen got.
  final notifyUs = <int>[];

  /// Called when the screen sent a prompt (the composer's real path).
  void Function()? onSent;

  /// `Timeline.now` of the `send` call; 0 until then.
  int sendUs = 0;

  @override
  void notifyListeners() {
    notifyUs.add(Timeline.now);
    super.notifyListeners();
  }

  @override
  Future<bool> send(String text) async {
    sendUs = Timeline.now;
    sent.add(text);
    _pending = _pending.withUserMessage([TextBlock(text)]).withTurnStarted();
    _schedule();
    onSent?.call();
    return true;
  }

  /// One `session/update` of the agent (the JSON of `params.update`).
  void ingest(Map<String, Object?> update) {
    final watch = Stopwatch()..start();
    _pending = _pending.apply(SessionUpdate.parse(update));
    _schedule();
    chunkCostUs.add(watch.elapsedMicroseconds);
  }

  /// One text chunk of the answer.
  void ingestText(String text) => ingest({
        'sessionUpdate': 'agent_message_chunk',
        'messageId': 'bench-answer',
        'content': {'type': 'text', 'text': text},
      });

  /// The turn ended.
  void finish() {
    _pending = _pending.withTurnEnded(StopReason.endTurn);
    _schedule();
  }

  void _schedule() => _cancel ??= _scheduler.nextFrame(_flushNow);

  void _flushNow() {
    _cancel = null;
    push(_pending);
  }

  @override
  void dispose() {
    _cancel?.call();
    super.dispose();
  }
}

/// A transcript of [rows] items in the shape of real turns (prompt, thought,
/// two tool calls, a markdown answer), ending on an answer.
AgentSessionState historyState(int rows) {
  final items = <TranscriptItem>[];
  var turn = 0;
  while (items.length < rows) {
    final n = turn++;
    final batch = <TranscriptItem>[
      userMsg('hu$n', 'Turn $n: look at lib/feature_$n/parse.dart and fix the locale bug'),
      thoughtMsg('ht$n', 'The parser lowercases before it normalises; check the call in feature $n.'),
      toolItem('hr$n', title: 'Read lib/feature_$n/parse.dart', kind: ToolKind.read),
      toolItem('he$n', title: 'flutter test test/feature_${n}_test.dart', kind: ToolKind.execute),
      agentMsg(
        'ha$n',
        '## Result $n\n\nThe parser **lowercased** before normalising, so `Hà Nội` lost its marks '
        '(see `lib/feature_$n/parse.dart:${40 + n % 50}`).\n\n- moved the call below `normalize()`\n'
        '  - added a regression test\n- left the public API alone\n\nDetails in the [notes](https://example.com/n/$n).',
      ),
    ];
    items.addAll(batch.take(rows - items.length));
  }
  return stateWith(items: items);
}

/// About [chars] characters of markdown with every structure agents write
/// (heading, link, bold, inline code, nested list, table, fenced code with a
/// `path:line` reference). Every unit carries its own number, so a piece of
/// text read back from the screen says where in the answer it is.
String syntheticAnswer(int chars) {
  final b = StringBuffer();
  var n = 1;
  while (b.length < chars) {
    final id = n.toString().padLeft(3, '0');
    b
      ..writeln('## Section $id: parser notes')
      ..writeln()
      ..writeln(
        'Step $id keeps the **fast path** in `lib/parse/step_$id.dart:${10 + n}` and links to the '
        '[guide $id](https://example.com/guide/$id) for details; the rest is plain prose that wraps '
        'over a couple of lines on a phone screen.',
      )
      ..writeln()
      ..writeln('- first item ${id}a')
      ..writeln('  - nested item ${id}b with `inline code`')
      ..writeln('- second item ${id}c')
      ..writeln()
      ..writeln('| name | value |')
      ..writeln('| --- | ---: |')
      ..writeln('| alpha$id | $n |')
      ..writeln('| beta$id | ${n * 2} |')
      ..writeln()
      ..writeln('```dart')
      ..writeln('// lib/parse/step_$id.dart:${10 + n}')
      ..writeln('int step$id(int x) => x + $n;')
      ..writeln('```')
      ..writeln();
    n++;
  }
  return b.toString().substring(0, chars);
}

/// One text chunk and when it arrives, microseconds after the stream starts.
typedef Arrival = ({int atUs, String text});

/// How the text arrives.
abstract final class StreamProfile {
  /// Profiles that need no recording.
  static const synthetic = 'synthetic';

  /// Every profile this build can replay: [synthetic] and one per agent in
  /// [traceCadence].
  static List<String> get all => [synthetic, ...traceCadence.keys];

  /// Steady 40 tokens/s (4 characters each) delivered in 200 ms bursts: eight
  /// chunks land at the same instant, every 200 ms.
  static List<Arrival> _synthetic(String text) {
    final out = <Arrival>[];
    var at = 0;
    for (var i = 0; i < text.length;) {
      for (var k = 0; k < 8 && i < text.length; k++) {
        final end = math.min(i + 4, text.length);
        out.add((atUs: at, text: text.substring(i, end)));
        i = end;
      }
      at += 200000;
    }
    return out;
  }

  /// [text] cut into the chunk sizes of an agent's recording, arriving at its
  /// recorded gaps; the recording repeats until the text is used up.
  static List<Arrival> _recorded(String text, List<int> cadence) {
    final out = <Arrival>[];
    var at = 0;
    var i = 0;
    var k = 0;
    while (i < text.length) {
      at += cadence[k] * 100; // tenths of a millisecond to microseconds
      final end = math.min(i + cadence[k + 1], text.length);
      out.add((atUs: at, text: text.substring(i, end)));
      i = end;
      k = (k + 2) % cadence.length;
    }
    return out;
  }

  /// The arrivals of [text] under [profile].
  static List<Arrival> schedule(String profile, String text) {
    if (profile == synthetic) return _synthetic(text);
    final cadence = traceCadence[profile];
    if (cadence == null) throw ArgumentError('unknown profile "$profile"; have ${all.join(', ')}');
    return _recorded(text, cadence);
  }
}

/// Plays [arrivals] on a wall clock into [deliver]. A timer that fires late
/// delivers the backlog in one go, as a busy isolate does with the messages
/// that queued up.
Future<void> play(List<Arrival> arrivals, void Function(String text) deliver) {
  final done = Completer<void>();
  final clock = Stopwatch()..start();
  var next = 0;
  void tick() {
    final now = clock.elapsedMicroseconds;
    while (next < arrivals.length && arrivals[next].atUs <= now) {
      deliver(arrivals[next++].text);
    }
    if (next >= arrivals.length) {
      done.complete();
      return;
    }
    final wait = arrivals[next].atUs - clock.elapsedMicroseconds;
    Timer(Duration(microseconds: math.max(0, wait)), tick);
  }

  tick();
  return done.future;
}
