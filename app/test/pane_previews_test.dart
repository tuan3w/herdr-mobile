import 'dart:async';
import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_transport.dart';

typedef _P = ({String id, String ws, String? agent, String status});

_P _pane(String id, [String status = 'working']) =>
    (id: id, ws: 'w1', agent: 'claude', status: status);

Map<String, dynamic> _paneUpdated(String id) => {
      'event': 'pane_updated',
      'data': {
        'type': 'pane_updated',
        'pane': {'pane_id': id},
      },
    };

const _statusChanged = {'event': 'pane_agent_status_changed'};

const _claudePrompt = '''
 Bash command
   git push origin main

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for git push commands
   3. No, and tell Claude what to do differently (esc)
''';

/// The same agent asking about another command: what the pane shows once the
/// question above was answered on the desktop.
const _otherPrompt = '''
 Bash command
   rm -rf build

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm commands
   3. No, and tell Claude what to do differently (esc)
''';

/// A machine that answers `pane.read` from [texts] / [dynamicText] and keeps
/// a log of every read with the fake time it started.
class _PaneTransport extends FakeTransport {
  _PaneTransport(this._now, super.snapshot);

  final Duration Function() _now;
  final reads = <({String pane, Duration at})>[];
  final texts = <String, String>{};
  String Function(String pane, int nth)? dynamicText;
  Duration latency = Duration.zero;
  Object? readFailure;
  int inFlight = 0;
  int maxInFlight = 0;

  int readsOf(String pane) => reads.where((r) => r.pane == pane).length;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method != 'pane.read') return super.request(method, params);
    final pane = params['pane_id'] as String;
    calls.add((method, params));
    reads.add((pane: pane, at: _now()));
    final nth = readsOf(pane);
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      if (latency > Duration.zero) await Future<void>.delayed(latency);
    } finally {
      inFlight--;
    }
    if (readFailure != null) throw readFailure!;
    return {
      'type': 'pane_read',
      'read': {
        'text': dynamicText?.call(pane, nth) ?? texts[pane] ?? '',
        'truncated': false,
      },
    };
  }
}

class _Changes extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// One or more connected machines plus a [PanePreviews] on a fake clock.
class _Rig {
  _Rig(
    this.async, {
    List<_P> panes = const [],
    int retainReleased = 24,
    int maxConcurrentReads = 2,
    Duration latency = Duration.zero,
  }) {
    previews = PanePreviews(
      changes: _changes,
      connection: (id) => _conns[id],
      retainReleased: retainReleased,
      maxConcurrentReads: maxConcurrentReads,
      clock: () => DateTime.utc(2026).add(async.elapsed),
    );
    addMachine('m', panes, latency: latency);
  }

  final FakeAsync async;
  final _changes = _Changes();
  final _conns = <String, MachineConnection>{};
  final _transports = <String, _PaneTransport>{};
  late final PanePreviews previews;

  _PaneTransport get t => _transports['m']!;
  MachineConnection get conn => _conns['m']!;

  MachineConnection addMachine(String id, List<_P> panes,
      {Duration latency = Duration.zero}) {
    final transport = _PaneTransport(() => async.elapsed, snapshotJson(panes: panes))
      ..latency = latency;
    final c = MachineConnection(
      profile: MachineProfile(id: id, label: id, host: 'h', username: 'u'),
      api: HerdrApi(transport),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    )..addListener(_changes.fire);
    _transports[id] = transport;
    _conns[id] = c;
    c.start();
    async.flushMicrotasks();
    return c;
  }

  /// Replaces the connection of [id], as the fleet does when a machine is edited.
  MachineConnection replaceMachine(String id, List<_P> panes) {
    _conns.remove(id)!.dispose();
    final c = addMachine(id, panes);
    _changes.fire();
    return c;
  }

  void elapse(Duration d) {
    async.elapse(d);
  }

  void ms(int n) => async.elapse(Duration(milliseconds: n));
  void seconds(int n) => async.elapse(Duration(seconds: n));

  void dispose() {
    previews.dispose();
    for (final c in _conns.values) {
      c.dispose();
    }
    async.flushMicrotasks();
  }
}

void _rig(
  String name,
  void Function(FakeAsync async, _Rig rig) body, {
  List<_P> panes = const [],
  int retainReleased = 24,
  Duration latency = Duration.zero,
}) =>
    test(name, () {
      fakeAsync((async) {
        final rig = _Rig(async,
            panes: panes, retainReleased: retainReleased, latency: latency);
        body(async, rig);
        rig.dispose();
      });
    });

PanePreview _value(PreviewHandle h) => h.preview.value!;

void main() {
  group('reference counting', () {
    _rig('one initial read per pane no matter how many watchers', (async, rig) {
      final a = rig.previews.watch('m', 'w1:p1');
      final b = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      expect(rig.t.reads, hasLength(1));
      expect(identical(a.preview, b.preview), isTrue);
      a.release();
      b.release();
    }, panes: [_pane('w1:p1')]);

    _rig('reads stop with the last release, not before', (async, rig) {
      rig.t.dynamicText = (p, n) => 'line $n';
      final a = rig.previews.watch('m', 'w1:p1');
      final b = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();

      a.release();
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.seconds(2);
      expect(rig.t.reads, hasLength(2), reason: 'still watched by b');

      b.release();
      final before = rig.t.reads.length;
      for (var i = 0; i < 40; i++) {
        rig.t.emit(_paneUpdated('w1:p1'));
        rig.seconds(2);
      }
      expect(rig.t.reads.length, before, reason: 'nothing read after release');
      expect(rig.previews.watchedPanes, 0);
    }, panes: [_pane('w1:p1')]);

    _rig('a double release does not steal another watcher\'s claim', (async, rig) {
      rig.t.dynamicText = (p, n) => 'line $n';
      final a = rig.previews.watch('m', 'w1:p1');
      final b = rig.previews.watch('m', 'w1:p1');
      a
        ..release()
        ..release();
      expect(rig.previews.watchedPanes, 1);
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.seconds(2);
      expect(rig.t.reads.length, greaterThan(1));
      b.release();
      expect(rig.previews.watchedPanes, 0);
    }, panes: [_pane('w1:p1')]);

    _rig('events for unwatched panes cause no read', (async, rig) {
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      rig.t.emit(_paneUpdated('w1:p2'));
      rig.seconds(5);
      expect(rig.t.readsOf('w1:p2'), 0);
      h.release();
    }, panes: [_pane('w1:p1'), _pane('w1:p2')]);

    _rig('dispose releases everything', (async, rig) {
      rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      rig.previews.dispose();
      final before = rig.t.reads.length;
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.seconds(30);
      expect(rig.t.reads.length, before);
      expect(rig.previews.watchedPanes, 0);
    }, panes: [_pane('w1:p1')]);
  });

  group('throttle', () {
    _rig('an event burst yields one read per 1.5 s, never a starved debounce',
        (async, rig) {
      rig.t.dynamicText = (p, n) => 'output $n';
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      // 10 s of continuous events, 10 per second.
      for (var i = 0; i < 100; i++) {
        rig.t.emit(_paneUpdated('w1:p1'));
        rig.ms(100);
      }
      final at = [for (final r in rig.t.reads) r.at];
      expect(at.length, inInclusiveRange(6, 8));
      for (var i = 1; i < at.length; i++) {
        expect(at[i] - at[i - 1], greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
      }
      expect(at[1], const Duration(milliseconds: 1500),
          reason: 'the first event is served as soon as the throttle allows');
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('a lone event after quiet is served at once', (async, rig) {
      rig.t.dynamicText = (p, n) => 'output $n';
      final h = rig.previews.watch('m', 'w1:p1');
      rig.seconds(10);
      final before = rig.t.reads.length;
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.ms(1);
      expect(rig.t.reads.length, before + 1);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('unchanged reads back off; a status change cuts the backoff short',
        (async, rig) {
      rig.t.texts['w1:p1'] = 'static';
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      for (var i = 0; i < 120; i++) {
        rig.t.emit(_paneUpdated('w1:p1'));
        rig.ms(100);
      }
      // 12 s of events on a pane that never changes: far fewer than 8 reads.
      expect(rig.t.reads.length, lessThanOrEqualTo(4));

      final before = rig.t.reads.length;
      rig.t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
      rig.t.emit(_statusChanged);
      rig.ms(160); // structural refresh lands, urgent read follows at once
      rig.ms(10);
      expect(rig.t.reads.length, before + 1);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('releasing and re-watching at once does not defeat the throttle',
        (async, rig) {
      rig.t.dynamicText = (p, n) => 'output $n';
      final first = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      first.release();
      rig.ms(300);
      final h = rig.previews.watch('m', 'w1:p1');
      rig.ms(100);
      expect(rig.t.reads, hasLength(1));
      rig.ms(1200);
      expect(rig.t.reads, hasLength(2));
      expect(rig.t.reads[1].at - rig.t.reads[0].at,
          greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('the safety poll catches a pane whose events never arrive', (async, rig) {
      rig.t.dynamicText = (p, n) => 'output $n';
      final h = rig.previews.watch('m', 'w1:p1');
      rig.seconds(61);
      expect(rig.t.reads.length, inInclusiveRange(3, 4));
      h.release();
    }, panes: [_pane('w1:p1')]);
  });

  group('staggering', () {
    _rig('20 cards appearing at once: <= 2 reads in flight, starts spaced',
        (async, rig) {
      rig.t.dynamicText = (p, n) => '$p output $n';
      final handles = [
        for (var i = 0; i < 20; i++) rig.previews.watch('m', 'w1:p$i'),
      ];
      rig.seconds(5);
      expect(rig.t.reads.length, 20);
      expect(rig.t.maxInFlight, lessThanOrEqualTo(2));
      final starts = [for (final r in rig.t.reads) r.at];
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i] - starts[i - 1], greaterThanOrEqualTo(const Duration(milliseconds: 40)));
      }
      for (final h in handles) {
        expect(h.preview.value, isNotNull);
        h.release();
      }
    },
        panes: [for (var i = 0; i < 20; i++) _pane('w1:p$i')],
        latency: const Duration(milliseconds: 300));

    _rig('queues are per machine: a slow machine does not hold up another',
        (async, rig) {
      rig.t.latency = const Duration(seconds: 3);
      rig.addMachine('n', [_pane('w2:p1')]);
      final slow = [
        for (var i = 0; i < 6; i++) rig.previews.watch('m', 'w1:p$i'),
      ];
      final fast = rig.previews.watch('n', 'w2:p1');
      rig.ms(200);
      expect(rig.t.readsOf('w1:p0'), 1);
      expect(rig._transports['n']!.readsOf('w2:p1'), 1);
      for (final h in [...slow, fast]) {
        h.release();
      }
    }, panes: [for (var i = 0; i < 6; i++) _pane('w1:p$i')]);
  });

  group('pausing', () {
    _rig('an offline machine is not read; coming back refreshes at once',
        (async, rig) {
      rig.t.dynamicText = (p, n) => 'output $n';
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      expect(rig.t.reads, hasLength(1));

      rig.conn.goOffline();
      rig.seconds(1);
      final before = rig.t.reads.length;
      for (var i = 0; i < 10; i++) {
        rig.t.emit(_paneUpdated('w1:p1'));
        rig.seconds(5);
      }
      expect(rig.t.reads.length, before, reason: 'no reads while offline');

      rig.conn.reconnect();
      async.flushMicrotasks();
      expect(rig.conn.isLive, isTrue);
      rig.ms(1);
      expect(rig.t.reads.length, before + 1, reason: 'immediate refresh on return');
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('a reconnecting machine is not read either', (async, rig) {
      rig.t.dynamicText = (p, n) => 'output $n';
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      rig.conn.suspend();
      rig.seconds(1);
      final before = rig.t.reads.length;
      rig.seconds(60);
      expect(rig.t.reads.length, before);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('backgrounded app: no reads; resumed: one refresh per watched pane',
        (async, rig) {
      rig.t.dynamicText = (p, n) => '$p output $n';
      final a = rig.previews.watch('m', 'w1:p1');
      final b = rig.previews.watch('m', 'w1:p2');
      rig.seconds(3);
      final before = rig.t.reads.length;

      rig.previews.onLifecycleState(AppLifecycleState.paused);
      for (var i = 0; i < 20; i++) {
        rig.t.emit(_paneUpdated('w1:p1'));
        rig.seconds(3);
      }
      expect(rig.t.reads.length, before, reason: 'nothing while backgrounded');

      rig.previews.onLifecycleState(AppLifecycleState.resumed);
      rig.seconds(1);
      expect(rig.t.reads.length, before + 2);
      a.release();
      b.release();
    }, panes: [_pane('w1:p1'), _pane('w1:p2')]);

    _rig('inactive alone (a pulled-down shade) does not pause', (async, rig) {
      rig.t.dynamicText = (p, n) => 'output $n';
      final h = rig.previews.watch('m', 'w1:p1');
      rig.previews.onLifecycleState(AppLifecycleState.inactive);
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.seconds(2);
      expect(rig.t.reads.length, 2);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('a watch opened while the machine is not online reads when it comes up',
        (async, rig) {
      rig.conn.goOffline();
      final h = rig.previews.watch('m', 'w1:p1');
      rig.seconds(5);
      expect(rig.t.reads, isEmpty);
      expect(h.preview.value, isNull);
      rig.conn.reconnect();
      rig.seconds(1);
      expect(rig.t.reads, hasLength(1));
      expect(h.preview.value, isNotNull);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('a replaced connection (machine edited) is followed', (async, rig) {
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      rig.t.texts['w1:p1'] = 'old machine';
      final oldTransport = rig.t;

      rig.replaceMachine('m', [_pane('w1:p1')]);
      rig.t.texts['w1:p1'] = 'new machine';
      rig.seconds(2);
      expect(rig.t.readsOf('w1:p1'), greaterThanOrEqualTo(1));
      expect(_value(h).lines.single.text, 'new machine');

      final oldReads = oldTransport.reads.length;
      oldTransport.emit(_paneUpdated('w1:p1'));
      rig.seconds(5);
      expect(oldTransport.reads.length, oldReads);
      h.release();
    }, panes: [_pane('w1:p1')]);
  });

  group('content', () {
    _rig('ANSI, OSC, CR progress, tabs, box bars and rules are cleaned',
        (async, rig) {
      rig.t.texts['w1:p1'] = [
        '\x1B[1;32m✓\x1B[0m built \x1B[38;5;240min 3s\x1B[0m   ',
        '\x1B]0;window title\x07plain after osc',
        'downloading  10%\rdownloading  60%\rdownloading 100%',
        '\tindented with a tab',
        '╭──────────────╮',
        '│ boxed text   │',
        '╰──────────────╯',
        '   ',
        '',
        'ctrl \x01\x02 chars\x7F gone',
        'x' * 400,
      ].join('\n');
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      final lines = [for (final l in _value(h).lines) l.text];
      expect(lines, [
        '✓ built in 3s',
        'plain after osc',
        'downloading 100%',
        '    indented with a tab',
        'boxed text',
        'ctrl  chars gone',
        'x' * 160,
      ]);
      h.release();
    }, panes: [_pane('w1:p1')]);

    test('a long line is cut on a character boundary, never inside an emoji', () {
      final rows = previewRows('${'a' * 159}😀tail', maxLength: 160);
      expect(rows.single, 'a' * 159);
      expect(rows.single.runes.every((r) => r != 0xD83D), isTrue);
    });

    _rig('keeps only the last 8 non-empty rows, oldest first', (async, rig) {
      rig.t.texts['w1:p1'] = [
        for (var i = 0; i < 15; i++) ...['row $i', ''],
      ].join('\n');
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      expect([for (final l in _value(h).lines) l.text],
          [for (var i = 7; i < 15; i++) 'row $i']);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('asks for a handful of rows, plain text, recent source', (async, rig) {
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      final call = rig.t.calls.firstWhere((c) => c.$1 == 'pane.read').$2;
      expect(call['source'], 'recent');
      expect(call['lines'], lessThanOrEqualTo(24));
      expect(call['strip_ansi'], isTrue);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('an empty pane publishes an empty preview, not null', (async, rig) {
      final h = rig.previews.watch('m', 'w1:p1');
      expect(h.preview.value, isNull);
      async.flushMicrotasks();
      expect(_value(h).lines, isEmpty);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('listeners wake only for a real change', (async, rig) {
      rig.t.texts['w1:p1'] = 'same';
      final h = rig.previews.watch('m', 'w1:p1');
      var wakes = 0;
      h.preview.addListener(() => wakes++);
      async.flushMicrotasks();
      expect(wakes, 1);
      final first = _value(h).updatedAt;

      for (var i = 0; i < 5; i++) {
        rig.t.emit(_paneUpdated('w1:p1'));
        rig.seconds(4);
      }
      expect(rig.t.reads.length, greaterThan(1));
      expect(wakes, 1, reason: 'identical text must not notify');
      expect(_value(h).updatedAt, first, reason: 'updatedAt = last content change');

      rig.t.texts['w1:p1'] = 'different';
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.seconds(8);
      expect(wakes, 2);
      expect(_value(h).updatedAt.isAfter(first), isTrue);
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('a failed read keeps the last preview and recovers on the next event',
        (async, rig) {
      rig.t.texts['w1:p1'] = 'good';
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();

      rig.t.readFailure = const HerdrTransportException('boom');
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.seconds(5);
      expect(_value(h).lines.single.text, 'good');

      rig.t.readFailure = null;
      rig.t.texts['w1:p1'] = 'recovered';
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.seconds(10);
      expect(_value(h).lines.single.text, 'recovered');
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('a pane that no longer exists is not hammered', (async, rig) {
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      rig.t.readFailure =
          const HerdrApiException('pane_not_found', 'pane w1:p1 not found');
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.seconds(3);
      final before = rig.t.reads.length;
      for (var i = 0; i < 10; i++) {
        rig.t.emit(_paneUpdated('w1:p1'));
        rig.seconds(3);
      }
      expect(rig.t.reads.length, before);
      h.release();
    }, panes: [_pane('w1:p1')]);
  });

  group('prompts', () {
    _rig('attached only while the agent is blocked', (async, rig) {
      rig.t.texts['w1:p1'] = _claudePrompt;
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      expect(_value(h).prompt, isNull, reason: 'working agent: menu is just output');
      h.release();
    }, panes: [_pane('w1:p1', 'working')]);

    _rig('a blocked agent shows the question with its replies', (async, rig) {
      rig.t.texts['w1:p1'] = _claudePrompt;
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      final p = _value(h).prompt!;
      expect(p.question, 'Do you want to proceed?');
      expect([for (final r in p.replies) r.keys], [
        ['1', 'enter'],
        ['2', 'enter'],
        ['3', 'enter'],
      ]);
      h.release();
    }, panes: [_pane('w1:p1', 'blocked')]);

    _rig('blocked then answered: the prompt vanishes without waiting for a read',
        (async, rig) {
      rig.t.texts['w1:p1'] = _claudePrompt;
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      expect(_value(h).prompt, isNotNull);
      final reads = rig.t.reads.length;

      rig.t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'working')]);
      rig.t.emit(_statusChanged);
      rig.ms(200); // structural refresh only; the read floor still holds
      expect(h.preview.value!.prompt, isNull);
      expect(rig.t.reads.length, reads);
      h.release();
    }, panes: [_pane('w1:p1', 'blocked')]);

    _rig('working then blocked: the prompt shows at once from the last rows',
        (async, rig) {
      rig.t.texts['w1:p1'] = _claudePrompt;
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      expect(_value(h).prompt, isNull);

      rig.t.snapshot = snapshotJson(panes: [_pane('w1:p1', 'blocked')]);
      rig.t.emit(_statusChanged);
      rig.ms(200);
      expect(_value(h).prompt, isNotNull);
      h.release();
    }, panes: [_pane('w1:p1', 'working')]);

    _rig('a recheck reads past the throttle, shows what it read and returns the question asked now',
        (async, rig) {
      rig.t.texts['w1:p1'] = _claudePrompt;
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      final before = _value(h).prompt!;

      rig.t.texts['w1:p1'] = _otherPrompt;
      PromptInfo? now;
      unawaited(rig.previews.recheck(rig.conn, 'w1:p1').then((p) => now = p));
      async.flushMicrotasks();
      expect(rig.t.reads, hasLength(2), reason: 'inside the read floor: an answer does not wait for it');
      expect(now, isNotNull);
      expect(now, isNot(before));
      expect(_value(h).prompt, now, reason: 'every surface shows the question asked now');
      h.release();
    }, panes: [_pane('w1:p1', 'blocked')]);

    _rig('a read that started before a recheck and lands after it does not bring the old question back',
        (async, rig) {
      rig.t.dynamicText = (pane, nth) => nth <= 2 ? _claudePrompt : _otherPrompt;
      final h = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      rig.seconds(2);
      rig.t.latency = const Duration(milliseconds: 300);
      rig.t.emit(_paneUpdated('w1:p1'));
      rig.ms(1);
      expect(rig.t.reads, hasLength(2), reason: 'a scheduled read is on its way, slowly');

      rig.t.latency = Duration.zero;
      PromptInfo? now;
      unawaited(rig.previews.recheck(rig.conn, 'w1:p1').then((p) => now = p));
      async.flushMicrotasks();
      expect(now, isNotNull);
      expect(_value(h).prompt, now);
      rig.ms(400);
      expect(_value(h).prompt, now, reason: 'the older read is older news');
      h.release();
    }, panes: [_pane('w1:p1', 'blocked')]);

    _rig('a recheck of a pane that is no longer blocked finds no question', (async, rig) {
      rig.t.texts['w1:p1'] = _claudePrompt;
      PromptInfo? now = const PromptInfo(question: 'unset', replies: []);
      unawaited(rig.previews.recheck(rig.conn, 'w1:p1').then((p) => now = p));
      async.flushMicrotasks();
      expect(now, isNull, reason: 'a menu left on the screen of a working agent is just output');
    }, panes: [_pane('w1:p1', 'working')]);
  });

  group('retained previews', () {
    _rig('a card scrolled back in shows the old preview at once', (async, rig) {
      rig.t.texts['w1:p1'] = 'remembered';
      final first = rig.previews.watch('m', 'w1:p1');
      async.flushMicrotasks();
      first.release();
      async.flushMicrotasks();
      rig.t.texts['w1:p1'] = 'newer';

      final h = rig.previews.watch('m', 'w1:p1');
      expect(_value(h).lines.single.text, 'remembered');
      rig.seconds(3);
      expect(_value(h).lines.single.text, 'newer');
      h.release();
    }, panes: [_pane('w1:p1')]);

    _rig('the LRU is bounded and drops the oldest', (async, rig) {
      for (var i = 0; i < 6; i++) {
        final h = rig.previews.watch('m', 'w1:p$i');
        async.flushMicrotasks();
        h.release();
        async.flushMicrotasks();
      }
      expect(rig.previews.retainedPanes, 3);
      final h = rig.previews.watch('m', 'w1:p0');
      expect(h.preview.value, isNull, reason: 'p0 was evicted');
      final kept = rig.previews.watch('m', 'w1:p5');
      expect(kept.preview.value, isNotNull);
      h.release();
      kept.release();
    },
        panes: [for (var i = 0; i < 6; i++) _pane('w1:p$i')],
        retainReleased: 3);
  });

  group('cost', () {
    // 20 visible cards, every pane streaming (events every 200 ms) with text
    // that changes on every read: the worst case the throttle must bound.
    test('20 streaming cards: <= 40 reads/pane/min', () {
      fakeAsync((async) {
        final rig = _Rig(async, panes: [for (var i = 0; i < 20; i++) _pane('w1:p$i')]);
        rig.t.dynamicText = (p, n) => '$p streaming $n';
        final handles = [
          for (var i = 0; i < 20; i++) rig.previews.watch('m', 'w1:p$i'),
        ];
        async.flushMicrotasks();
        final start = rig.t.reads.length;
        for (var tick = 0; tick < 300; tick++) {
          for (var i = 0; i < 20; i++) {
            rig.t.emit(_paneUpdated('w1:p$i'));
          }
          rig.ms(200);
        }
        final perMinute = rig.t.reads.length - start;
        expect(perMinute, lessThanOrEqualTo(20 * 41));
        expect(perMinute, greaterThan(20 * 30), reason: 'it still keeps up');
        for (final h in handles) {
          h.release();
        }
        rig.dispose();
      });
    });

    test('20 idle cards (no events, text never changes): poll only', () {
      fakeAsync((async) {
        final rig = _Rig(async, panes: [for (var i = 0; i < 20; i++) _pane('w1:p$i', 'idle')]);
        rig.t.texts.addAll({for (var i = 0; i < 20; i++) 'w1:p$i': 'idle text'});
        final handles = [
          for (var i = 0; i < 20; i++) rig.previews.watch('m', 'w1:p$i'),
        ];
        async.flushMicrotasks();
        rig.seconds(2);
        final start = rig.t.reads.length;
        rig.seconds(60);
        final perMinute = rig.t.reads.length - start;
        expect(perMinute, lessThanOrEqualTo(20 * 3));
        for (final h in handles) {
          h.release();
        }
        rig.dispose();
      });
    });
  });
}
