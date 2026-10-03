import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/open_tabs.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore implements OpenTabsStore {
  _MemoryStore([this.saved]);

  SavedTabs? saved;
  int writes = 0;
  bool failing = false;

  @override
  Future<SavedTabs?> read() async {
    if (failing) throw StateError('disk gone');
    return saved;
  }

  @override
  Future<void> write(SavedTabs tabs) async {
    if (failing) throw StateError('disk gone');
    writes++;
    saved = tabs;
  }
}

List<String> _panes(OpenTabs t) => [for (final r in t.tabs) r.paneId];

Future<OpenTabs> _reopen(_MemoryStore store) async {
  final tabs = OpenTabs(store: store);
  await tabs.load();
  return tabs;
}

void main() {
  group('tabs survive a restart', () {
    test('their panes, order and the active one come back', () async {
      final store = _MemoryStore();
      final first = await _reopen(store);
      first
        ..open('m1', 'a')
        ..open('m2', 'b')
        ..open('m1', 'c')
        ..activate(const TabRef('m2', 'b').key);
      await pumpEventQueue();

      final second = await _reopen(store);
      expect(second.tabs, [const TabRef('m1', 'a'), const TabRef('m2', 'b'), const TabRef('m1', 'c')]);
      expect(second.active, const TabRef('m2', 'b'));
      expect(second.takeResume(), isFalse, reason: 'the tab screen was not open');
      first.dispose();
      second.dispose();
    });

    test('closing a tab and closing all are remembered', () async {
      final store = _MemoryStore();
      final first = await _reopen(store);
      first
        ..open('m', 'a')
        ..open('m', 'b')
        ..open('m', 'c')
        ..close(const TabRef('m', 'b').key);
      await pumpEventQueue();
      expect(_panes(await _reopen(store)), ['a', 'c']);

      first.closeAll();
      await pumpEventQueue();
      final empty = await _reopen(store);
      expect(empty.isEmpty, isTrue);
      expect(empty.active, isNull);
      first.dispose();
    });

    test('going back saves "not open"; the app being torn down keeps "open"', () async {
      final store = _MemoryStore();
      final first = await _reopen(store);
      first.open('m', 'a');
      first.hostAttached = true;
      await pumpEventQueue();
      expect(store.saved!.hostOpen, isTrue);

      // The process ends with the screen still up: nothing is written.
      first.detachHost(leaving: false);
      await pumpEventQueue();
      expect(store.saved!.hostOpen, isTrue);
      expect((await _reopen(store)).takeResume(), isTrue);

      // The person goes back.
      first.hostAttached = true;
      first.detachHost(leaving: true);
      await pumpEventQueue();
      expect(store.saved!.hostOpen, isFalse);
      expect((await _reopen(store)).takeResume(), isFalse);
      first.dispose();
    });

    test('the tab screen being open is remembered once, then cleared', () async {
      final store = _MemoryStore();
      final first = await _reopen(store);
      first.open('m', 'a');
      first.hostAttached = true;
      await pumpEventQueue();

      final second = await _reopen(store);
      expect(second.takeResume(), isTrue);
      expect(second.takeResume(), isFalse, reason: 'read and cleared');

      first.hostAttached = false;
      await pumpEventQueue();
      expect((await _reopen(store)).takeResume(), isFalse);
      first.dispose();
      second.dispose();
    });

    test('an open screen without tabs is not resumed', () async {
      final store = _MemoryStore(const SavedTabs(tabs: [], hostOpen: true));
      expect((await _reopen(store)).takeResume(), isFalse);
    });

    test('the first entry after a restart keeps the saved order', () async {
      final store = _MemoryStore();
      final first = await _reopen(store);
      first
        ..open('m', 'a')
        ..open('m', 'b')
        ..open('m', 'c')
        ..activate(const TabRef('m', 'a').key);
      await pumpEventQueue();
      final order = _panes(first);

      final second = await _reopen(store);
      // The screen is entered afresh (sorted by recency): the tab opened is
      // first, the others stay as they were.
      second.open('m', 'c', byRecency: true);
      expect(_panes(second).first, 'c');
      expect(_panes(second).skip(1), order.where((p) => p != 'c'));
      first.dispose();
      second.dispose();
    });

    test('only changes that matter are written', () async {
      final store = _MemoryStore();
      final tabs = await _reopen(store);
      tabs.open('m', 'a');
      tabs.open('m', 'b');
      await pumpEventQueue();
      final writes = store.writes;

      tabs.noteStatus(const TabRef('m', 'a').key, null);
      tabs.activate(const TabRef('m', 'b').key); // already active
      tabs.hostAttached = false; // already false
      await pumpEventQueue();
      expect(store.writes, writes);
      tabs.dispose();
    });

    test('nothing is written before load, and a store that fails never throws', () async {
      final store = _MemoryStore(const SavedTabs(tabs: [TabRef('m', 'old')]));
      final tabs = OpenTabs(store: store);
      tabs.open('m', 'new');
      await pumpEventQueue();
      expect(store.writes, 0, reason: 'would overwrite what load has yet to read');
      tabs.dispose();

      final broken = _MemoryStore()..failing = true;
      final unreadable = await _reopen(broken);
      expect(unreadable.isEmpty, isTrue);
      unreadable.open('m', 'a');
      await pumpEventQueue();
      expect(_panes(unreadable), ['a'], reason: 'tabs still work without a disk');
      unreadable.dispose();
    });

    test('duplicates, an unknown active tab and more than the maximum are repaired', () async {
      final store = _MemoryStore(
        const SavedTabs(
          tabs: [
            TabRef('m', 'a'),
            TabRef('m', 'a'),
            TabRef('m', 'b'),
            TabRef('m', 'c'),
            TabRef('m', 'd'),
          ],
          active: 'm|gone',
        ),
      );
      final tabs = OpenTabs(maxTabs: 3, store: store);
      await tabs.load();
      expect(_panes(tabs), ['a', 'b', 'c']);
      expect(tabs.active, const TabRef('m', 'a'));
      tabs.dispose();
    });
  });

  group('SavedTabs', () {
    test('round-trips', () {
      const saved = SavedTabs(
        tabs: [TabRef('m|1', 'w1:p|2'), TabRef('m2', 'p')],
        active: 'm2|p',
        hostOpen: true,
      );
      final back = SavedTabs.decode(saved.encode())!;
      expect(back.tabs, saved.tabs);
      expect(back.active, saved.active);
      expect(back.hostOpen, isTrue);
    });

    test('anything else is nothing', () {
      for (final bad in [null, '', 'nope', '[]', '{"v":2,"tabs":[]}', '{"v":1,"tabs":3}']) {
        expect(SavedTabs.decode(bad), isNull, reason: '$bad');
      }
      final partly = SavedTabs.decode('{"v":1,"tabs":[["m","a"],["x"],[1,2],["","p"],["m","b"]]}')!;
      expect(partly.tabs, [const TabRef('m', 'a'), const TabRef('m', 'b')]);
    });

    test('the prefs store keeps them', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PrefsOpenTabsStore();
      expect(await store.read(), isNull);
      await store.write(const SavedTabs(tabs: [TabRef('m', 'a')], active: 'm|a', hostOpen: true));
      final back = (await store.read())!;
      expect(back.tabs, [const TabRef('m', 'a')]);
      expect(back.hostOpen, isTrue);
    });
  });
}
