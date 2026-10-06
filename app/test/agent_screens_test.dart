// What the app keeps about agent screens: the one in front between launches
// (and what the removed tabs left behind), and per agent for the app run the
// view chosen with the toggle and the composer's draft.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Store implements AgentScreensStore {
  _Store([this.saved]);

  FrontAgent? saved;

  @override
  Future<FrontAgent?> read() async => saved;

  @override
  Future<void> write(FrontAgent? front) async => saved = front;
}

class _BrokenStore implements AgentScreensStore {
  @override
  Future<FrontAgent?> read() => Future.error(StateError('disk'));

  @override
  Future<void> write(FrontAgent? front) => Future.error(StateError('disk'));
}

const _pane = PaneAgent('m', 'w1:p1');
const _other = PaneAgent('m', 'w1:p2');
const _session = SessionAgent('m/k1');

Future<(AgentScreens, _Store)> _loaded([FrontAgent? saved]) async {
  final store = _Store(saved);
  final screens = AgentScreens(store);
  addTearDown(screens.dispose);
  await screens.load();
  return (screens, store);
}

void main() {
  group('FrontAgent', () {
    test('what is written reads back the same', () {
      for (final front in const [
        FrontAgent(_pane, AgentView.terminal),
        FrontAgent(_pane, AgentView.chat),
        FrontAgent(_session, AgentView.chat),
        FrontAgent(PaneAgent('Mac mini', 'w 1:p|1'), AgentView.terminal),
      ]) {
        expect(FrontAgent.decode(front.encode()), front, reason: front.encode());
      }
    });

    test('anything else reads as nothing', () {
      for (final source in [
        null,
        '',
        'nope',
        '[]',
        '{}',
        jsonEncode({'v': 2, 'pane': ['m', 'p'], 'view': 'terminal'}),
        jsonEncode({'v': 1, 'view': 'terminal'}),
        jsonEncode({'v': 1, 'pane': ['m'], 'view': 'terminal'}),
        jsonEncode({'v': 1, 'pane': ['', 'p'], 'view': 'terminal'}),
        jsonEncode({'v': 1, 'pane': [1, 2], 'view': 'terminal'}),
        jsonEncode({'v': 1, 'pane': ['m', 'p'], 'view': 'sideways'}),
        jsonEncode({'v': 1, 'session': '', 'view': 'chat'}),
      ]) {
        expect(FrontAgent.decode(source), isNull, reason: source);
      }
    });
  });

  group('AgentScreens: the screen in front', () {
    test('a screen shown is saved as the one in front', () async {
      final (screens, store) = await _loaded();
      final owner = Object();

      screens.shown(owner, _pane, AgentView.terminal);
      await pumpEventQueue();

      expect(screens.front, const FrontAgent(_pane, AgentView.terminal));
      expect(store.saved, const FrontAgent(_pane, AgentView.terminal));
    });

    test('a screen torn down with the app stays saved for the next launch', () async {
      final (screens, store) = await _loaded();
      final owner = Object();
      screens.shown(owner, _pane, AgentView.terminal);

      screens.left(owner, leaving: false);
      await pumpEventQueue();

      expect(screens.front, isNull);
      expect(store.saved, const FrontAgent(_pane, AgentView.terminal));
    });

    test('a screen the person left (back to the board) is forgotten', () async {
      final (screens, store) = await _loaded();
      final owner = Object();
      screens.shown(owner, _pane, AgentView.terminal);

      screens.left(owner, leaving: true);
      await pumpEventQueue();

      expect(screens.front, isNull);
      expect(store.saved, isNull);
    });

    test('leaving a newer screen puts the older one under it in front', () async {
      final (screens, store) = await _loaded();
      final older = Object();
      final newer = Object();
      screens.shown(older, _pane, AgentView.terminal);
      screens.shown(newer, _session, AgentView.chat);
      await pumpEventQueue();
      expect(store.saved, const FrontAgent(_session, AgentView.chat));

      screens.left(newer, leaving: true);
      await pumpEventQueue();

      expect(screens.front, const FrontAgent(_pane, AgentView.terminal));
      expect(store.saved, const FrontAgent(_pane, AgentView.terminal));
    });

    test('listeners hear that the front changed', () async {
      final (screens, _) = await _loaded();
      var heard = 0;
      screens.addListener(() => heard++);

      screens.shown(Object(), _pane, AgentView.terminal);
      await pumpEventQueue();

      expect(heard, 1);
    });

    test('the saved screen is handed out once to put back', () async {
      final (screens, _) = await _loaded(const FrontAgent(_pane, AgentView.chat));

      expect(screens.takeResume(), const FrontAgent(_pane, AgentView.chat));
      expect(screens.takeResume(), isNull);
    });

    test('forgetting the one to put back saves what is in front now', () async {
      final (screens, store) = await _loaded(const FrontAgent(_session, AgentView.chat));
      screens.takeResume();

      screens.forgetResume();
      await pumpEventQueue();

      expect(store.saved, isNull);
    });

    test('a store that cannot be read or written never throws, and the app goes on', () async {
      final screens = AgentScreens(_BrokenStore());
      addTearDown(screens.dispose);

      await screens.load();
      expect(screens.takeResume(), isNull);

      final owner = Object();
      screens.shown(owner, _pane, AgentView.terminal);
      await pumpEventQueue();
      expect(screens.front, const FrontAgent(_pane, AgentView.terminal));

      screens.left(owner, leaving: true);
      await pumpEventQueue();
      expect(screens.front, isNull);
    });

    test('a failed write is tried again with the next change', () async {
      final store = _FlakyStore();
      final screens = AgentScreens(store);
      addTearDown(screens.dispose);
      await screens.load();

      final owner = Object();
      store.fail = true;
      screens.shown(owner, _pane, AgentView.terminal);
      await pumpEventQueue();
      store.fail = false;
      screens.shown(owner, _pane, AgentView.terminal);
      await pumpEventQueue();

      expect(store.saved, const FrontAgent(_pane, AgentView.terminal));
    });
  });

  group('AgentScreens: per agent, for the app run', () {
    test('the view chosen with the toggle, per agent', () {
      final screens = AgentScreens();
      addTearDown(screens.dispose);
      expect(screens.viewOf(_pane), isNull);

      screens.choose(_pane, AgentView.terminal);

      expect(screens.viewOf(_pane), AgentView.terminal);
      expect(screens.viewOf(const PaneAgent('m', 'w1:p1')), AgentView.terminal, reason: 'the same agent');
      expect(screens.viewOf(_other), isNull);
      screens.choose(_pane, AgentView.chat);
      expect(screens.viewOf(_pane), AgentView.chat);
    });

    test('the draft, per agent; an empty one is no draft', () {
      final screens = AgentScreens();
      addTearDown(screens.dispose);
      expect(screens.draftOf(_pane), '');

      screens
        ..keepDraft(_pane, 'half a thought')
        ..keepDraft(_session, 'other words');

      expect(screens.draftOf(_pane), 'half a thought');
      expect(screens.draftOf(_session), 'other words');
      expect(screens.draftOf(_other), '');

      screens.keepDraft(_pane, '');
      expect(screens.draftOf(_pane), '');
      expect(screens.draftOf(_session), 'other words');
    });
  });

  group('PrefsAgentScreensStore', () {
    const legacyKey = 'openTabs.v1';
    const key = 'frontAgent.v1';

    String tabs({required bool host, String active = 'm|w1:p2'}) => jsonEncode({
      'v': 1,
      'tabs': [
        ['m', 'w1:p1'],
        ['m', 'w1:p2'],
      ],
      'active': active,
      'host': host,
    });

    test('what is written reads back; nothing written reads as nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final store = PrefsAgentScreensStore();
      expect(await store.read(), isNull);

      await store.write(const FrontAgent(_session, AgentView.chat));
      expect(await store.read(), const FrontAgent(_session, AgentView.chat));

      await store.write(null);
      expect(await store.read(), isNull);
    });

    test('the tab that was in front when the app was left on its tabs comes back as its terminal', () async {
      SharedPreferences.setMockInitialValues({legacyKey: tabs(host: true)});
      final store = PrefsAgentScreensStore();

      expect(await store.read(), const FrontAgent(PaneAgent('m', 'w1:p2'), AgentView.terminal));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyKey), isFalse, reason: 'the tabs are gone for good');
      expect(await store.read(), const FrontAgent(PaneAgent('m', 'w1:p2'), AgentView.terminal),
          reason: 'carried over once and kept');
    });

    test('tabs left while the board was in front bring nothing back, and are gone', () async {
      SharedPreferences.setMockInitialValues({legacyKey: tabs(host: false)});
      final store = PrefsAgentScreensStore();

      expect(await store.read(), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyKey), isFalse);
    });

    test('an active tab that is not listed brings nothing back', () async {
      SharedPreferences.setMockInitialValues({legacyKey: tabs(host: true, active: 'm|w1:p9')});

      expect(await PrefsAgentScreensStore().read(), isNull);
    });

    test('a screen saved since wins over what the tabs left', () async {
      SharedPreferences.setMockInitialValues({
        legacyKey: tabs(host: true),
        key: const FrontAgent(_session, AgentView.chat).encode(),
      });
      final store = PrefsAgentScreensStore();

      expect(await store.read(), const FrontAgent(_session, AgentView.chat));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyKey), isFalse);
    });

    test('garbage left by the tabs brings nothing back and is gone', () async {
      SharedPreferences.setMockInitialValues({legacyKey: '{not json'});
      final store = PrefsAgentScreensStore();

      expect(await store.read(), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyKey), isFalse);
    });
  });
}

class _FlakyStore implements AgentScreensStore {
  bool fail = false;
  FrontAgent? saved;

  @override
  Future<FrontAgent?> read() async => null;

  @override
  Future<void> write(FrontAgent? front) async {
    if (fail) throw StateError('disk');
    saved = front;
  }
}
