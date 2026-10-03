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
}
