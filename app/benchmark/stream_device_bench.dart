// ignore_for_file: avoid_print
//
// The streaming benchmark, on a phone: what an agent's answer costs while it
// streams into the real chat screen. `autoresearch-stream.sh` builds and runs it:
//
//   flutter build apk --profile -t benchmark/stream_device_bench.dart
//
// It is the real `AgentSessionScreen` (theme, system bars, the composer, the
// platform's keyboard) over `StreamBenchSession`, an in-memory session that
// mirrors the data path of `AcpAgentSession` (see support/stream_session.dart
// for what is copied and what is not). No network, no agent, fixed content, so
// only the phone and the app vary. Per case it
//   1. shows a transcript of STREAM_ROWS rows (default 2000) ending on an answer;
//   2. optionally taps the composer, so the keyboard is open for the stream;
//   3. types a prompt and sends it through the composer (the real path), and
//      times Send to the end of the next frame;
//   4. streams STREAM_KB KB (default 20) of markdown into the session at a
//      profile's arrival times: `synthetic` (steady 40 tokens/s, in 200 ms
//      bursts) or an agent's recorded cadence (app/test/fixtures/traces, via
//      support/trace_cadence.dart), the text being the synthetic answer;
//   5. ends the turn and lets it settle.
//
// Logged per case, as STREAMBENCH_METRIC <profile>_<closed|kb>_<name>=<value>
// lines (`autoresearch-stream.sh` turns them into METRIC lines):
//   * every frame's build (UI thread) and raster time from FrameTiming; late
//     frames (either over the budget, 1000 / refresh rate); jank_ms (how far
//     past the budget, summed); dropped (vsyncs that passed without a frame
//     while a notification was waiting for one);
//   * chunk_cost_*: per chunk, parse + reducer + scheduling the notification,
//     measured with the transcript's real length (the O(1) criterion);
//   * lag_*: how long the oldest character that arrived but is not on screen
//     has been waiting (ms), and how many letters and digits are waiting. The
//     screen's text is read from the render tree after every frame (the
//     RenderParagraphs inside the screen: the Markdown blocks are `Text.rich`,
//     so frozen blocks and the open tail are found alike), matched against what
//     was received. It includes the pacing on purpose: with Smooth text on
//     (the default; STREAM_SMOOTH=0 turns it off) the newest text is shown up
//     to ~250 ms after it arrived, which is the number the reveal is tuned by.
//     A text engine that paints without RenderParagraph needs
//     `LagProbe.screenTail` taught about it, and until then lag_unread says how
//     many samples could not be read;
//   * end_move_*: how far the end of the content moved per frame (dp), and the
//     number of frames that moved it more than a line (24 dp);
//   * drift_*: the distance between the viewport's bottom and the end of the
//     content, while following (dp; 0 when glued).
// The probe reads the render tree once per frame, after the frame; its cost is
// probe_*_ms, and it comes out of the next frame's budget.
//
// Lines are printed to logcat (profile builds still print): STREAMBENCH_ENV,
// _CASE, _LAG (a one-second series of received/painted letters and the lag),
// _METRIC, _DONE or _ERROR.
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode, kProfileMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:herdr_mobile/boot.dart' show configureSystemUi;
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/ui/core/frame_flush.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:provider/provider.dart';

import '../test/support/memory_app_settings_store.dart';
import 'support/lag_probe.dart';
import 'support/stream_session.dart';

/// Size of the streamed answer, KB of characters.
const _kb = int.fromEnvironment('STREAM_KB', defaultValue: 20);

/// Rows of transcript above the stream.
const _rows = int.fromEnvironment('STREAM_ROWS', defaultValue: 2000);

/// Profiles streamed with the keyboard closed / open (comma separated).
const _closedProfiles = String.fromEnvironment('STREAM_PROFILES', defaultValue: 'synthetic,claude,omp,codex');
const _keyboardProfiles = String.fromEnvironment('STREAM_KEYBOARD_PROFILES', defaultValue: 'synthetic,claude');

/// Smooth text (the pacing of the live answer, Settings > Appearance) on or
/// off for the whole run; `STREAM_SMOOTH=0` measures the text arriving as it
/// comes.
const _smooth = String.fromEnvironment('STREAM_SMOOTH', defaultValue: '1') != '0';

/// The end of the content moving more than this in one frame is a visible jump
/// (about a line of body text), dp.
const _lineDp = 24.0;

/// No keyboard inset change for this long: the keyboard is done.
const _quiet = Duration(milliseconds: 450);

const _prompt = 'Explain the parser notes in sections, with a table and a code sample for each.';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureSystemUi();
  final host = _Host();
  runApp(host);
  unawaited(_Driver(host).run());
}

/// Shows one session at a time; a new one gets a new screen.
class _Host extends StatelessWidget {
  _Host() {
    unawaited(settings.setSmoothText(_smooth));
  }

  final shown = ValueNotifier<StreamBenchSession?>(null);
  final settings = AppSettings(MemoryAppSettingsStore());

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider<AppSettings>.value(
        value: settings,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: ValueListenableBuilder<StreamBenchSession?>(
            valueListenable: shown,
            builder: (context, session, _) =>
                session == null ? const SizedBox.shrink() : AgentSessionScreen(key: ObjectKey(session), session: session),
          ),
        ),
      );
}

/// One frame as the post-frame probe saw it.
typedef _Frame = ({int us, double content, double after, int received, int painted, int probeUs});

/// A case: a profile, with or without the keyboard.
typedef _Case = ({String profile, bool keyboard});

class _Driver {
  _Driver(this.host);

  final _Host host;

  final _timings = <ui.FrameTiming>[];
  final _frames = <_Frame>[];
  var _budgetMs = 1000 / 60;
  var _dpr = 1.0;
  var _recording = false;
  var _pointer = 500;

  ScrollableState? _scrollable;

  // The lag probe: what was received, and what the screen shows of it.
  var _probe = LagProbe();

  ui.FlutterView get _view => ui.PlatformDispatcher.instance.implicitView!;

  Future<void> run() async {
    final watchdog = Timer(const Duration(minutes: 40), () => print('STREAMBENCH_ERROR watchdog: the run did not finish'));
    try {
      await _run();
    } catch (e, s) {
      print('STREAMBENCH_ERROR $e');
      print('STREAMBENCH_ERROR ${s.toString().split('\n').take(6).join(' | ')}');
    } finally {
      watchdog.cancel();
    }
  }

  Future<void> _run() async {
    final binding = SchedulerBinding.instance;
    binding.addPersistentFrameCallback(_onFrame);
    binding.addTimingsCallback((t) => _timings.addAll(t));
    final view = _view;
    _dpr = view.devicePixelRatio;
    final hz = view.display.refreshRate;
    if (hz >= 30 && hz <= 240) _budgetMs = 1000 / hz;
    print(
      'STREAMBENCH_ENV mode=${kProfileMode ? 'profile' : kDebugMode ? 'DEBUG' : 'release'} dpr=$_dpr '
      'hz=${hz.toStringAsFixed(1)} budget_ms=${_budgetMs.toStringAsFixed(2)} rows=$_rows kb=$_kb '
      'closed=$_closedProfiles keyboard=$_keyboardProfiles smooth=$_smooth',
    );
    if (kDebugMode) print('STREAMBENCH_WARN a debug build: the numbers mean nothing, build with --profile');

    final cases = <_Case>[
      for (final p in _closedProfiles.split(',').where((p) => p.isNotEmpty)) (profile: p, keyboard: false),
      for (final p in _keyboardProfiles.split(',').where((p) => p.isNotEmpty)) (profile: p, keyboard: true),
    ];
    final known = StreamProfile.all;
    for (final c in cases) {
      if (!known.contains(c.profile)) throw StateError('unknown profile "${c.profile}"; have ${known.join(', ')}');
    }
    for (final c in cases) {
      await _case(c);
    }
    print('STREAMBENCH_DONE');
  }

  // -------------------------------------------------------------------------
  // One case.

  Future<void> _case(_Case c) async {
    final name = '${c.profile}_${c.keyboard ? 'kb' : 'closed'}';
    print('STREAMBENCH_CASE $name start');
    _timings.clear();
    _frames.clear();
    _recording = false;
    _scrollable = null;
    _probe = LagProbe();

    final session = StreamBenchSession(historyState(_rows), flush: FrameFlush());
    host.shown.value = session;
    await _until(() => _composer() != null && _scroll() != null, 'the screen', const Duration(seconds: 40));
    await Future<void>.delayed(const Duration(seconds: 2));
    await _toEnd();

    if (c.keyboard) {
      await _openKeyboard();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _toEnd();
    }

    final text = syntheticAnswer(_kb * 1000);
    final arrivals = StreamProfile.schedule(c.profile, text);
    _recording = true;
    final startUs = Timeline.now;
    final lagSamples = <({int us, int lagMs, int pending})>[];
    final sampler = Timer.periodic(const Duration(milliseconds: 10), (_) => lagSamples.add(_lag()));

    // Send through the composer, as a person does.
    final sent = Completer<void>();
    session.onSent = sent.complete;
    final path = _sendFromComposer(session);
    await sent.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    await WidgetsBinding.instance.endOfFrame;
    final sendToFrameMs = (Timeline.now - session.sendUs) / 1000;

    final firstArrival = <int>[];
    await play(arrivals, (chunk) {
      final us = Timeline.now;
      if (firstArrival.isEmpty) firstArrival.add(us);
      _probe.record(chunk, us);
      session.ingestText(chunk);
    });
    session.finish();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    sampler.cancel();
    final endUs = Timeline.now;
    final settledUnread = _lag().pending;
    _recording = false;

    if (c.keyboard) await _closeKeyboard();
    // FrameTiming reaches the framework in batches, up to a second late.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    _report(
      name,
      session,
      startUs: startUs,
      endUs: endUs,
      firstArrivalUs: firstArrival.firstOrNull ?? endUs,
      lagSamples: lagSamples,
      sendToFrameMs: sendToFrameMs,
      sendPath: path,
      settledPending: settledUnread,
    );
    host.shown.value = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    session.dispose();
  }

  /// Types the prompt into the composer's field and submits it the way the
  /// keyboard's send key does. If no field takes it, sends on the session
  /// directly (and says so).
  String _sendFromComposer(StreamBenchSession session) {
    final field = _editable();
    if (field != null) {
      field.widget.controller.text = _prompt;
      field.performAction(TextInputAction.send);
      if (session.sent.isNotEmpty) return 'composer';
    }
    unawaited(session.send(_prompt));
    return 'direct';
  }

  // -------------------------------------------------------------------------
  // Recording, after every frame.

  void _onFrame(Duration _) {
    if (!_recording) return;
    final watch = Stopwatch()..start();
    final position = _scroll()?.position;
    if (position == null) return;
    final reversed = position.axisDirection == AxisDirection.up || position.axisDirection == AxisDirection.left;
    final content = position.maxScrollExtent - position.minScrollExtent + position.viewportDimension;
    final after = reversed ? position.extentBefore : position.extentAfter;
    _probe.read(_scroll()?.context.findRenderObject(), _view.physicalSize.height / _dpr);
    _frames.add((
      us: Timeline.now,
      content: content,
      after: after,
      received: _probe.received,
      painted: _probe.painted,
      probeUs: watch.elapsedMicroseconds,
    ));
  }

  /// The oldest character that arrived and is not on screen, now.
  ({int us, int lagMs, int pending}) _lag() {
    final now = Timeline.now;
    final l = _probe.lag(now);
    return (us: now, lagMs: l.lagMs, pending: l.pending);
  }

  // -------------------------------------------------------------------------
  // The screen.

  /// The transcript's scroll state: the tallest vertical [Scrollable].
  ScrollableState? _scroll() {
    final cached = _scrollable;
    if (cached != null && cached.mounted) return cached;
    ScrollableState? best;
    var bestHeight = 0.0;
    void visit(Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        final s = e.state as ScrollableState;
        if (s.position.axis == Axis.vertical && s.position.hasViewportDimension && s.position.viewportDimension > bestHeight) {
          best = s;
          bestHeight = s.position.viewportDimension;
        }
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return _scrollable = best;
  }

  /// Glues the view to the end of the transcript, as it is when a person has
  /// just opened a chat (or sent a message).
  Future<void> _toEnd() async {
    for (var i = 0; i < 8; i++) {
      final p = _scroll()?.position;
      if (p == null) return;
      final reversed = p.axisDirection == AxisDirection.up;
      final after = reversed ? p.extentBefore : p.extentAfter;
      if (after < 0.5) return;
      p.jumpTo(reversed ? p.minScrollExtent : p.maxScrollExtent);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// The composer's field: the lowest enabled [TextField] on screen.
  Element? _composer() {
    Element? found;
    var lowest = -1.0;
    void visit(Element e) {
      final w = e.widget;
      if (w is TextField && (w.enabled ?? true)) {
        final box = e.renderObject;
        if (box is RenderBox && box.attached && box.hasSize) {
          final y = box.localToGlobal(Offset.zero).dy;
          if (y > lowest) {
            lowest = y;
            found = e;
          }
        }
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  EditableTextState? _editable() {
    final composer = _composer();
    if (composer == null) return null;
    EditableTextState? state;
    void visit(Element e) {
      if (state != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        state = e.state as EditableTextState;
        return;
      }
      e.visitChildren(visit);
    }

    visit(composer);
    return state;
  }

  Future<void> _openKeyboard() async {
    final composer = _composer();
    if (composer == null) throw StateError('the composer is gone');
    final box = composer.renderObject! as RenderBox;
    await _tap(box.localToGlobal(box.size.center(Offset.zero)));
    if (!await _keyboardIs(open: true)) throw StateError('the keyboard did not open');
  }

  Future<void> _closeKeyboard() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _keyboardIs(open: false);
  }

  /// A finger: down, a short press, up.
  Future<void> _tap(Offset at) async {
    final id = ++_pointer;
    final binding = GestureBinding.instance;
    PointerEvent event(PointerEvent Function(Duration) make) => make(Duration(microseconds: Timeline.now));
    binding.handlePointerEvent(
      event((t) => PointerDownEvent(viewId: _view.viewId, timeStamp: t, pointer: id, kind: PointerDeviceKind.touch, position: at)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    binding.handlePointerEvent(
      event((t) => PointerUpEvent(viewId: _view.viewId, timeStamp: t, pointer: id, kind: PointerDeviceKind.touch, position: at)),
    );
  }

  /// Waits for the keyboard to be up (or gone) and quiet.
  Future<bool> _keyboardIs({required bool open}) async {
    final watch = Stopwatch()..start();
    var last = -1.0;
    var changed = Timeline.now;
    while (watch.elapsedMilliseconds < 6000) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final now = _view.viewInsets.bottom;
      if (now != last) {
        last = now;
        changed = Timeline.now;
      }
      final there = open ? now > 50 : now < 0.5;
      if (there && Timeline.now - changed >= _quiet.inMicroseconds) return true;
    }
    return false;
  }

  Future<void> _until(bool Function() test, String what, Duration timeout) async {
    final watch = Stopwatch()..start();
    while (!test()) {
      if (watch.elapsed > timeout) throw StateError('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // -------------------------------------------------------------------------
  // Analysis.

  static double _pct(List<double> v, double p) {
    if (v.isEmpty) return 0;
    final s = [...v]..sort();
    return s[math.min(s.length - 1, (s.length * p).floor())];
  }

  static double _max(List<double> v) => v.fold<double>(0, math.max);

  void _metric(String name, num value) =>
      print('STREAMBENCH_METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

  void _report(
    String name,
    StreamBenchSession session, {
    required int startUs,
    required int endUs,
    required int firstArrivalUs,
    required List<({int us, int lagMs, int pending})> lagSamples,
    required double sendToFrameMs,
    required String sendPath,
    required int settledPending,
  }) {
    if (_timings.isEmpty) throw StateError('no FrameTiming arrived');
    print('STREAMBENCH_CASE $name send_path=$sendPath');

    // Frames whose build started in the window, in order.
    final frames = _timings.where((t) {
      final start = t.timestampInMicroseconds(ui.FramePhase.buildStart);
      return start >= startUs && start <= endUs;
    }).toList()
      ..sort((a, b) => a.timestampInMicroseconds(ui.FramePhase.buildStart).compareTo(b.timestampInMicroseconds(ui.FramePhase.buildStart)));
    final build = <double>[], raster = <double>[], total = <double>[];
    var late = 0;
    var jankMs = 0.0;
    var cacheMb = 0.0;
    var dropped = 0;
    final notifies = session.notifyUs.where((u) => u >= startUs && u <= endUs).toList();
    // The oldest notification waiting for each frame, and how long it waited:
    // a frame that shows it should start within a vsync; every whole vsync
    // more is a dropped one. A gap between frames with nothing waiting is no
    // drop (a quiet agent).
    final notifyToFrame = <double>[];
    var next = 0;
    var previousStart = startUs;
    final budgetUs = _budgetMs * 1000;
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      final b = f.buildDuration.inMicroseconds / 1000;
      final r = f.rasterDuration.inMicroseconds / 1000;
      build.add(b);
      raster.add(r);
      total.add(f.totalSpan.inMicroseconds / 1000);
      if (math.max(b, r) > _budgetMs) late++;
      jankMs += math.max(0, math.max(b, r) - _budgetMs);
      cacheMb = math.max(cacheMb, f.layerCacheMegabytes + f.pictureCacheMegabytes);
      final start = f.timestampInMicroseconds(ui.FramePhase.buildStart);
      while (next < notifies.length && notifies[next] <= previousStart) {
        next++;
      }
      if (next < notifies.length && notifies[next] <= start) {
        final waited = start - notifies[next];
        notifyToFrame.add(waited / 1000);
        dropped += (waited / budgetUs).floor();
        while (next < notifies.length && notifies[next] <= start) {
          next++;
        }
      }
      previousStart = start;
    }

    final cost = [for (final us in session.chunkCostUs) us / 1000];
    final lagMs = [for (final s in lagSamples) s.lagMs.toDouble()];
    final lagChars = [for (final s in lagSamples) s.pending.toDouble()];
    final ends = <double>[], drift = <double>[], probe = <double>[];
    var overLine = 0;
    var driftFrames = 0;
    for (var i = 0; i < _frames.length; i++) {
      final f = _frames[i];
      probe.add(f.probeUs / 1000);
      drift.add(f.after);
      if (f.after > 0.5) driftFrames++;
      if (i == 0) continue;
      final move = (f.content - _frames[i - 1].content).abs();
      ends.add(move);
      if (move > _lineDp) overLine++;
    }
    final firstPaint = _frames.where((f) => f.painted > 0).firstOrNull;

    _metric('${name}_send_to_frame_ms', sendToFrameMs);
    _metric('${name}_first_paint_ms', firstPaint == null ? -1 : (firstPaint.us - firstArrivalUs) / 1000);
    _metric('${name}_chunks', session.chunkCostUs.length);
    _metric('${name}_notifies', notifies.length);
    _metric('${name}_chunk_cost_mean_ms', cost.isEmpty ? 0 : cost.reduce((a, b) => a + b) / cost.length);
    _metric('${name}_chunk_cost_p95_ms', _pct(cost, 0.95));
    _metric('${name}_chunk_cost_max_ms', _max(cost));
    _metric('${name}_frames', frames.length);
    _metric('${name}_build_p50_ms', _pct(build, 0.5));
    _metric('${name}_build_p95_ms', _pct(build, 0.95));
    _metric('${name}_build_max_ms', _max(build));
    _metric('${name}_raster_p50_ms', _pct(raster, 0.5));
    _metric('${name}_raster_p95_ms', _pct(raster, 0.95));
    _metric('${name}_raster_max_ms', _max(raster));
    _metric('${name}_total_p95_ms', _pct(total, 0.95));
    _metric('${name}_late_frames', late);
    _metric('${name}_dropped', dropped);
    _metric('${name}_jank_ms', jankMs);
    _metric('${name}_cache_mb', cacheMb);
    _metric('${name}_notify_to_frame_p95_ms', _pct(notifyToFrame, 0.95));
    _metric('${name}_lag_p50_ms', _pct(lagMs, 0.5));
    _metric('${name}_lag_p95_ms', _pct(lagMs, 0.95));
    _metric('${name}_lag_max_ms', _max(lagMs));
    _metric('${name}_lag_chars_p50', _pct(lagChars, 0.5));
    _metric('${name}_lag_chars_p95', _pct(lagChars, 0.95));
    _metric('${name}_lag_unread', _probe.reads == 0 ? 1 : _probe.unread / _probe.reads);
    _metric('${name}_settled_pending_chars', settledPending);
    _metric('${name}_end_move_p95_dp', _pct(ends, 0.95));
    _metric('${name}_end_move_max_dp', _max(ends));
    _metric('${name}_end_move_over_line', overLine);
    _metric('${name}_drift_p95_dp', _pct(drift, 0.95));
    _metric('${name}_drift_max_dp', _max(drift));
    _metric('${name}_drift_frames', driftFrames);
    _metric('${name}_probe_p95_ms', _pct(probe, 0.95));

    // The received / painted letters and the lag, once a second, to read the
    // shape of the stream.
    final series = StringBuffer();
    var nextSecond = startUs;
    for (final s in lagSamples) {
      if (s.us < nextSecond) continue;
      nextSecond = s.us + 1000000;
      series.write('${((s.us - startUs) / 1e6).toStringAsFixed(0)}s:${s.pending}c/${s.lagMs}ms ');
    }
    print('STREAMBENCH_LAG $name pending_and_lag_per_second=${series.toString().trim()}');
  }
}
