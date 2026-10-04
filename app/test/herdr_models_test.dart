import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';

Pane _pane(String title) => Pane.fromJson({
      'pane_id': 'w1:p1',
      'workspace_id': 'w1',
      'tab_id': 'w1:t1',
      'agent': 'omp',
      'agent_status': 'working',
      'terminal_title_stripped': title,
    });

void main() {
  group('terminal titles', () {
    // Busy agents animate a braille spinner in the title several times a
    // second. If frames made panes differ, every snapshot would "change",
    // refetching and rebuilding the whole UI for nothing.
    test('spinner frames do not make panes differ', () {
      expect(_pane('π ⠹ Fix the tests'), _pane('π ⠦ Fix the tests'));
      expect(_pane('⠋ Fix the tests').title, 'Fix the tests');
    });

    test('a genuinely different title does', () {
      expect(_pane('π ⠹ Fix the tests'), isNot(_pane('π ⠹ Fix the lint')));
    });

    test('agent chrome is stripped, content kept', () {
      expect(cleanTerminalTitle('π ⠼ Merge Branch To Master Push'),
          'Merge Branch To Master Push');
      expect(cleanTerminalTitle('✳ Refactor webhook retry'), 'Refactor webhook retry');
      expect(cleanTerminalTitle('重构支付网关 🚀'), '重构支付网关 🚀');
      expect(cleanTerminalTitle('⠋'), '');
      expect(cleanTerminalTitle(''), '');
    });

    test('cleaning is idempotent, so cached snapshots round-trip', () {
      final once = _pane('π ⠹ Fix the tests');
      expect(Pane.fromJson(once.toJson()), once);
    });
  });

  group('snapshot wire projection', () {
    // The mux drops every field of a snapshot that is not in
    // snapshotWireFields before it crosses the network. A model that starts
    // reading another field would silently get null on every real connection.
    test('covers every field the models read', () {
      final panes = _Spy({'pane_id': 'p', 'workspace_id': 'w', 'tab_id': 't'});
      final tabs = _Spy({'tab_id': 't', 'workspace_id': 'w'});
      final workspaces = _Spy({'workspace_id': 'w'});
      Snapshot.fromJson({
        'version': '1',
        'workspaces': [workspaces],
        'tabs': [tabs],
        'panes': [panes],
      });

      for (final (name, spy) in [
        ('workspaces', workspaces),
        ('tabs', tabs),
        ('panes', panes),
      ]) {
        final wire = (snapshotWireFields[name]! as Map).keys.toSet();
        expect(wire.containsAll(spy.read), isTrue,
            reason: '$name reads ${spy.read.difference(wire)} which is not on the wire');
        // ...and nothing is listed that no model reads.
        expect(spy.read.containsAll(wire), isTrue,
            reason: '$name lists ${wire.difference(spy.read)} but never reads it');
      }
    });
  });
}

/// A map that notes which keys were looked up.
class _Spy extends MapBase<String, dynamic> {
  _Spy(this._m);

  final Map<String, dynamic> _m;
  final read = <String>{};

  @override
  dynamic operator [](Object? key) {
    read.add(key! as String);
    return _m[key];
  }

  @override
  void operator []=(String key, dynamic value) => _m[key] = value;

  @override
  void clear() => _m.clear();

  @override
  Iterable<String> get keys => _m.keys;

  @override
  dynamic remove(Object? key) => _m.remove(key);
}
