import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/repositories/open_tabs.dart';

List<String> _panes(OpenTabs t) => [for (final r in t.tabs) r.paneId];

void main() {
  late OpenTabs tabs;

  setUp(() => tabs = OpenTabs());
  tearDown(() => tabs.dispose());

  void openAll(List<String> ids) {
    for (final id in ids) {
      tabs.open('m', id);
    }
  }

  group('opening', () {
    test('a new tab goes right after the active one and becomes active', () {
      openAll(['a', 'b', 'c']);
      tabs.activate(TabRef('m', 'a').key);

      tabs.open('m', 'd');

      expect(_panes(tabs), ['a', 'd', 'b', 'c']);
      expect(tabs.active, const TabRef('m', 'd'));
    });

    test('opening an open tab only activates it, in place', () {
      openAll(['a', 'b', 'c']);

      tabs.open('m', 'a');

      expect(_panes(tabs), ['a', 'b', 'c']);
      expect(tabs.active, const TabRef('m', 'a'));
    });

    test('the same pane id on another machine is another tab', () {
      tabs.open('m1', 'w1:p1');
      tabs.open('m2', 'w1:p1');

      expect(tabs.length, 2);
      expect(tabs.activeKey, const TabRef('m2', 'w1:p1').key);
    });

    test('switching never re-sorts the tabs', () {
      openAll(['a', 'b', 'c', 'd']);
      for (final id in ['c', 'a', 'd', 'b', 'a']) {
        tabs.activate(TabRef('m', id).key);
      }

      expect(_panes(tabs), ['a', 'b', 'c', 'd']);
    });

    test('entering afresh sorts by recency, most recent first', () {
      openAll(['a', 'b', 'c', 'd']); // used order: a b c d (d latest)
      tabs.activate(const TabRef('m', 'b').key);
      tabs.activate(const TabRef('m', 'a').key); // latest a, then b, then d, c

      tabs.open('m', 'c', byRecency: true);

      expect(_panes(tabs), ['c', 'a', 'b', 'd']);
      expect(tabs.activeKey, const TabRef('m', 'c').key);
    });

    test('entering afresh on a new agent puts it first', () {
      openAll(['a', 'b']);

      tabs.open('m', 'z', byRecency: true);

      expect(_panes(tabs), ['z', 'b', 'a']);
    });

    test('the least recently used tab is evicted beyond the cap, never the active one', () {
      tabs.dispose();
      tabs = OpenTabs(maxTabs: 3);
      openAll(['a', 'b', 'c']);
      tabs.activate(const TabRef('m', 'a').key); // b is now the oldest

      tabs.open('m', 'd');

      expect(_panes(tabs), ['a', 'd', 'c']);
      expect(tabs.active, const TabRef('m', 'd'));
    });

    test('notifies once per change', () {
      var n = 0;
      tabs.addListener(() => n++);
      tabs.open('m', 'a');
      tabs.open('m', 'a');
      tabs.activate(const TabRef('m', 'a').key); // already active
      tabs.open('m', 'b');

      expect(n, 2, reason: 'reopening the active tab is not a change');
    });
  });

  group('closing', () {
    test('the active tab hands over to the tab that slides into its place', () {
      openAll(['a', 'b', 'c']);
      tabs.activate(const TabRef('m', 'b').key);

      tabs.close(const TabRef('m', 'b').key);

      expect(_panes(tabs), ['a', 'c']);
      expect(tabs.active, const TabRef('m', 'c'));
    });

    test('closing the last tab activates the one before it', () {
      openAll(['a', 'b', 'c']);

      tabs.close(const TabRef('m', 'c').key);

      expect(tabs.active, const TabRef('m', 'b'));
    });

    test('closing a background tab leaves the active one', () {
      openAll(['a', 'b', 'c']);

      tabs.close(const TabRef('m', 'a').key);

      expect(_panes(tabs), ['b', 'c']);
      expect(tabs.active, const TabRef('m', 'c'));
    });

    test('closing the only tab leaves none', () {
      tabs.open('m', 'a');

      tabs.close(const TabRef('m', 'a').key);

      expect(tabs.isEmpty, isTrue);
      expect(tabs.activeKey, isNull);
    });

    test('close others, close to the right and close all', () {
      openAll(['a', 'b', 'c', 'd', 'e']);

      tabs.closeToRight(const TabRef('m', 'c').key);
      expect(_panes(tabs), ['a', 'b', 'c']);
      expect(
        tabs.active,
        const TabRef('m', 'c'),
        reason: 'the active tab was closed',
      );

      tabs.closeOthers(const TabRef('m', 'b').key);
      expect(_panes(tabs), ['b']);
      expect(tabs.active, const TabRef('m', 'b'));

      tabs.closeAll();
      expect(tabs.isEmpty, isTrue);
    });

    test('unknown keys are ignored', () {
      tabs.open('m', 'a');
      var n = 0;
      tabs.addListener(() => n++);

      tabs.close('nope');
      tabs.closeOthers('nope');
      tabs.closeToRight('nope');
      tabs.activate('nope');

      expect(n, 0);
      expect(tabs.length, 1);
    });
  });

  group('step', () {
    test('moves to the neighbour and stops at the ends', () {
      openAll(['a', 'b', 'c']);
      tabs.activate(const TabRef('m', 'b').key);

      expect(tabs.step(1), isTrue);
      expect(tabs.active, const TabRef('m', 'c'));
      expect(tabs.step(1), isFalse, reason: 'no wrap-around');
      expect(tabs.step(-2), isTrue);
      expect(tabs.active, const TabRef('m', 'a'));
      expect(tabs.step(-1), isFalse);
    });
  });

  group('attention', () {
    String key(String id) => TabRef('m', id).key;

    setUp(() => openAll(['a', 'b', 'c'])); // c is active

    test('a background tab that becomes blocked or done is marked', () {
      tabs.noteStatus(key('a'), AgentStatus.working);
      tabs.noteStatus(key('b'), AgentStatus.working);

      tabs.noteStatus(key('a'), AgentStatus.blocked);
      tabs.noteStatus(key('b'), AgentStatus.done);

      expect(tabs.hasAttention(key('a')), isTrue);
      expect(tabs.hasAttention(key('b')), isTrue);
      expect(tabs.attentionCount, 2);
    });

    test('working to idle counts as finished; idle to working does not', () {
      tabs.noteStatus(key('a'), AgentStatus.idle);
      tabs.noteStatus(key('a'), AgentStatus.working);
      expect(tabs.hasAttention(key('a')), isFalse);

      tabs.noteStatus(key('a'), AgentStatus.idle);
      expect(tabs.hasAttention(key('a')), isTrue);
    });

    test('the first sighting is not a change', () {
      tabs.noteStatus(key('a'), AgentStatus.blocked);

      expect(tabs.hasAttention(key('a')), isFalse);
    });

    test('the active tab is never marked', () {
      tabs.noteStatus(key('c'), AgentStatus.working);
      tabs.noteStatus(key('c'), AgentStatus.blocked);

      expect(tabs.hasAttention(key('c')), isFalse);
    });

    test('showing the tab clears the mark, and it stays cleared', () {
      tabs.noteStatus(key('a'), AgentStatus.working);
      tabs.noteStatus(key('a'), AgentStatus.blocked);

      tabs.activate(key('a'));
      expect(tabs.hasAttention(key('a')), isFalse);

      tabs.activate(key('b'));
      tabs.noteStatus(key('a'), AgentStatus.blocked);
      expect(
        tabs.hasAttention(key('a')),
        isFalse,
        reason: 'same status, no new change',
      );
    });

    test('a tab that gets blocked again after being seen is marked again', () {
      tabs.noteStatus(key('a'), AgentStatus.blocked);
      tabs.noteStatus(key('a'), AgentStatus.working);
      tabs.noteStatus(key('a'), AgentStatus.blocked);

      expect(tabs.hasAttention(key('a')), isTrue);
    });

    test('a marked tab that becomes active because its neighbour closed is cleared', () {
      tabs.noteStatus(key('b'), AgentStatus.working);
      tabs.noteStatus(key('b'), AgentStatus.blocked);

      tabs.close(key('c')); // the active one; b slides in

      expect(tabs.active, const TabRef('m', 'b'));
      expect(tabs.hasAttention(key('b')), isFalse);
    });

    test('closing a tab forgets its mark', () {
      tabs.noteStatus(key('a'), AgentStatus.working);
      tabs.noteStatus(key('a'), AgentStatus.blocked);

      tabs.close(key('a'));

      expect(tabs.attentionCount, 0);
    });

    test('listeners hear about a new mark once', () {
      tabs.noteStatus(key('a'), AgentStatus.working);
      var n = 0;
      tabs.addListener(() => n++);

      tabs.noteStatus(key('a'), AgentStatus.blocked);
      tabs.noteStatus(key('a'), AgentStatus.blocked);

      expect(n, 1);
    });
  });
}
