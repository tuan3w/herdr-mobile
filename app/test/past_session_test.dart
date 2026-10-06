import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/past_session.dart';

void main() {
  group('PastSessions.fromJson', () {
    test('reads the history line: sessions, capabilities and the messageCount of _meta', () {
      final past = PastSessions.fromJson({
        'agent': 'omp',
        'list': true,
        'load': true,
        'resume': false,
        'more': true,
        'sessions': [
          {
            'sessionId': 's1',
            'cwd': '/home/me/a',
            'title': '  Fix the build  ',
            'updatedAt': '2026-10-05T10:00:00.000Z',
            '_meta': {'messageCount': 12, 'size': 900},
          },
        ],
      });

      expect(past.agent, 'omp');
      expect((past.canList, past.canLoad, past.canResume, past.more, past.canReopen), (true, true, false, true, true));
      final s = past.sessions.single;
      expect(s.agent, 'omp', reason: 'every session knows which agent holds it');
      expect((s.sessionId, s.cwd, s.title, s.messageCount), ('s1', '/home/me/a', 'Fix the build', 12));
      expect(s.updatedAt, DateTime.utc(2026, 10, 5, 10));
    });

    test('skips entries that cannot be reopened and keeps the rest in order', () {
      final past = PastSessions.fromJson({
        'agent': 'claude',
        'sessions': [
          {'sessionId': 'a', 'cwd': '/x'},
          'junk',
          {'cwd': '/x'},
          {'sessionId': '', 'cwd': '/x'},
          {'sessionId': 'no-cwd'},
          {'sessionId': 7, 'cwd': '/x'},
          {'sessionId': 'b', 'cwd': '/y'},
        ],
      });

      expect(past.sessions.map((s) => s.sessionId), ['a', 'b']);
    });

    test('an entry with odd optional fields is still listed, without them', () {
      final s = PastSessions.fromJson({
        'agent': 'omp',
        'sessions': [
          {'sessionId': 's', 'cwd': '/x', 'title': '   ', 'updatedAt': 'yesterday', '_meta': {'messageCount': 'many'}},
          {'sessionId': 't', 'cwd': '/x', 'title': 5, 'updatedAt': 3, '_meta': 'x'},
        ],
      }).sessions;

      for (final one in s) {
        expect((one.title, one.updatedAt, one.messageCount), (null, null, null));
      }
    });

    test('defaults: a line with no flags can list but not reopen anything', () {
      final past = PastSessions.fromJson({'agent': 'pi'});

      expect(past.sessions, isEmpty);
      expect((past.canList, past.canLoad, past.canResume, past.more, past.canReopen), (true, false, false, false, false));
    });

    test('list false is kept: no sessions then means the agent cannot say', () {
      final past = PastSessions.fromJson({'agent': 'codex', 'list': false, 'load': true, 'sessions': []});

      expect((past.canList, past.canReopen), (false, true));
    });

    test('a sessions field that is not a list is an empty history', () {
      expect(PastSessions.fromJson({'agent': 'omp', 'sessions': 'x'}).sessions, isEmpty);
    });
  });
}
