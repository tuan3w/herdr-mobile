// When the board reads an omp agent's session log to name it, and when it does not.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' hide Pane;
import 'package:herdr_mobile/data/models/herdr_models.dart' as models show Pane;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_name.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/pane_session_names.dart';

import 'ui/ui_harness.dart';

const _log = '/home/dev/.omp/agent/sessions/-src-app/2026-10-07_abc123.jsonl';

SessionSlices _slices({String? title, String? prompt, bool mid = false, DateTime? modified}) {
  final head = title == null ? '' : '${jsonEncode({'type': 'title', 'title': title})}\n';
  final tail = prompt == null
      ? ''
      : '${jsonEncode({
          'type': 'message',
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': prompt},
            ],
          },
        })}\n';
  return (
    head: Uint8List.fromList(utf8.encode(head)),
    tail: Uint8List.fromList(utf8.encode(tail)),
    tailStartsMidLine: mid,
    modified: modified,
  );
}

void main() {
  late UiHarness h;
  late MachineConnection machine;
  late List<FleetAgent> agents;
  late List<String> reads;
  late List<bool> texts; // whether each read asked for the text
  late bool canRead;
  late DateTime now;
  SessionSlices Function(String path) answer = (_) => _slices();
  Completer<void>? gate;
  late PaneSessionNames names;
  var heard = 0;

  models.Pane pane(
    String id, {
    String title = 'app',
    String agent = 'omp',
    AgentStatus status = AgentStatus.idle,
    String? path = _log,
    String? label,
    String sessionAgent = 'omp',
  }) =>
      models.Pane(
        id: id,
        workspaceId: 'w1',
        tabId: 'w1:t1',
        focused: false,
        cwd: '/src/app',
        title: label ?? title,
        label: label,
        agent: agent,
        status: status,
        session: path == null
            ? null
            : AgentSessionRef(agent: sessionAgent, kind: 'path', value: path),
      );

  FleetAgent agentOf(models.Pane p) => FleetAgent(machine: machine, pane: p, workspace: null);

  setUp(() async {
    h = await UiHarness.create([
      (
        profile: MachineProfile(
          id: 'a',
          label: 'studio',
          host: 'a.example',
          username: 'dev',
        ),
        snapshot: snapshotWith(const []),
      ),
    ]);
    await pumpEventQueue(times: 50);
    machine = h.fleet.connections.single;
    agents = [];
    reads = [];
    texts = [];
    canRead = true;
    now = DateTime.utc(2026, 1, 1, 12);
    answer = (_) => _slices();
    gate = null;
    heard = 0;
    names = PaneSessionNames(
      agents: () => agents,
      canRead: () => canRead,
      clock: () => now,
      reader: (m, path, {required text}) async {
        reads.add(path);
        texts.add(text);
        await gate?.future;
        return answer(path);
      },
    )..addListener(() => heard++);
  });

  tearDown(() {
    names.dispose();
    h.dispose();
  });

  Future<void> settle() => pumpEventQueue(times: 20);

  test('an omp pane titled with its folder is read and named by the session title', () async {
    answer = (_) => _slices(title: 'Fix the retry test', prompt: 'ignored when there is a title');
    agents = [agentOf(pane('p1'))];

    names.sync();
    await settle();

    expect(reads, [_log]);
    expect(names.nameFor('a', 'p1', _log), const PaneName.title('Fix the retry test'));
    expect(heard, 1);
  });

  test('with no title the person\'s last message names it, in quotes', () async {
    answer = (_) => _slices(prompt: 'Add a regression test for the parser');
    agents = [agentOf(pane('p1'))];

    names.sync();
    await settle();

    final name = names.nameFor('a', 'p1', _log)!;
    expect(name.fromPrompt, isTrue);
    expect(name.shown, '\u201CAdd a regression test for the parser\u201D');
  });

  test('a log title that is only the folder is no title: the last message is used', () async {
    answer = (_) => _slices(title: 'app', prompt: 'Upgrade eslint');
    agents = [agentOf(pane('p1'))];

    names.sync();
    await settle();

    expect(names.nameFor('a', 'p1', _log), const PaneName.prompt('Upgrade eslint'));
  });

  test('a log with neither gives no name, and nothing is announced', () async {
    agents = [agentOf(pane('p1'))];

    names.sync();
    await settle();

    expect(reads, hasLength(1));
    expect(names.nameFor('a', 'p1', _log), isNull);
    expect(heard, 0);
  });

  group('is never read for', () {
    test('a working pane whose own title already names its work', () async {
      agents = [agentOf(pane('p1', title: 'Add mobile keyboard autocomplete', status: AgentStatus.working))];
      names.sync();
      await settle();
      expect(reads, isEmpty, reason: 'nothing to name, and no idle time to read');
    });

    test('a pane that reports no session, however generic its title', () async {
      agents = [agentOf(pane('p1', path: null))];
      names.sync();
      await settle();
      expect(reads, isEmpty);
    });

    test('another agent than omp', () async {
      agents = [agentOf(pane('p1', agent: 'claude', sessionAgent: 'claude'))];
      names.sync();
      await settle();
      expect(reads, isEmpty);
    });

    for (final bad in [
      'relative/session.jsonl',
      '/home/dev/../root/secret.jsonl',
      '/home/dev/notes.txt',
      '/home/dev/x\n.jsonl',
      '/home/dev/x\u0000.jsonl',
    ]) {
      test('an odd path: ${jsonEncode(bad)}', () async {
        agents = [agentOf(pane('p1', path: bad))];
        names.sync();
        await settle();
        expect(reads, isEmpty);
      });
    }
  });

  group('when its session file was last written', () {
    final at = DateTime.utc(2026, 1, 1, 9, 30);

    test('an idle pane with a good title costs one stat: the time, none of the text', () async {
      answer = (_) => _slices(title: 'ignored: not asked for', modified: at);
      agents = [agentOf(pane('p1', title: 'Add mobile keyboard autocomplete'))];

      names.sync();
      await settle();

      expect(texts, [false]);
      expect(names.lastActiveFor('a', 'p1', _log), at);
      expect(names.nameFor('a', 'p1', _log), isNull, reason: 'its own title is the name');
      expect(heard, 1, reason: 'the time is news');
    });

    test('a pane the person named is read for the time only', () async {
      answer = (_) => _slices(modified: at);
      agents = [agentOf(pane('p1', label: 'app'))];

      names.sync();
      await settle();

      expect(texts, [false]);
      expect(names.lastActiveFor('a', 'p1', _log), at);
    });

    test('a pane that needs a name gets the text and the time in one read', () async {
      answer = (_) => _slices(title: 'Fix the retry test', modified: at);
      agents = [agentOf(pane('p1'))];

      names.sync();
      await settle();

      expect(reads, hasLength(1));
      expect(texts, [true]);
      expect(names.nameFor('a', 'p1', _log), const PaneName.title('Fix the retry test'));
      expect(names.lastActiveFor('a', 'p1', _log), at);
    });

    test('a time read from another log is not given to a pane that moved to a new one', () async {
      answer = (_) => _slices(modified: at);
      agents = [agentOf(pane('p1'))];
      names.sync();
      await settle();

      expect(names.lastActiveFor('a', 'p1', '/home/dev/.omp/agent/sessions/-src-app/other.jsonl'), isNull);
    });

    test('a host that does not say when gives no time, and nothing is announced', () async {
      agents = [agentOf(pane('p1', title: 'Add mobile keyboard autocomplete'))];

      names.sync();
      await settle();

      expect(reads, hasLength(1));
      expect(names.lastActiveFor('a', 'p1', _log), isNull);
      expect(heard, 0);
    });
  });

  test('read again when the pane\'s status changes, not on every sync', () async {
    answer = (_) => _slices(prompt: 'First ask');
    agents = [agentOf(pane('p1', status: AgentStatus.working))];
    names.sync();
    await settle();
    names.sync();
    names.sync();
    await settle();
    expect(reads, hasLength(1), reason: 'same status: the read stands');

    answer = (_) => _slices(prompt: 'Second ask');
    agents = [agentOf(pane('p1'))];
    names.sync();
    await settle();

    expect(reads, hasLength(2));
    expect(names.nameFor('a', 'p1', _log), const PaneName.prompt('Second ask'));
  });

  test('a name read from another log is not shown for a pane that moved to a new one', () async {
    answer = (_) => _slices(prompt: 'Old session');
    agents = [agentOf(pane('p1'))];
    names.sync();
    await settle();

    expect(names.nameFor('a', 'p1', '/home/dev/.omp/agent/sessions/-src-app/other.jsonl'), isNull);
  });

  test('a failed read is quiet and is retried only after retryAfter', () async {
    var fail = true;
    final failing = PaneSessionNames(
      agents: () => agents,
      canRead: () => true,
      clock: () => now,
      reader: (m, path, {required text}) async {
        reads.add(path);
        if (fail) throw RemoteFileException(RemoteFileErrorKind.network, 'link lost');
        return _slices(title: 'Back again');
      },
    );
    addTearDown(failing.dispose);
    agents = [agentOf(pane('p1'))];

    failing.sync();
    await settle();
    expect(reads, hasLength(1));
    failing.sync();
    await settle();
    expect(reads, hasLength(1), reason: 'not hammered');

    fail = false;
    now = now.add(failing.retryAfter + const Duration(seconds: 1));
    failing.sync();
    await settle();
    expect(reads, hasLength(2));
    expect(failing.nameFor('a', 'p1', _log), const PaneName.title('Back again'));
  });

  test('nothing is read in the background or while the machine is down; reads resume with the foreground', () async {
    answer = (_) => _slices(title: 'Named');
    agents = [agentOf(pane('p1'))];
    canRead = false;
    names.sync();
    await settle();
    expect(reads, isEmpty);

    canRead = true;
    names.sync();
    await settle();
    expect(reads, hasLength(1));
  });

  test('at most maxConcurrent reads run at once; the rest wait their turn', () async {
    gate = Completer<void>();
    answer = (_) => _slices(title: 'T');
    agents = [for (final i in [1, 2, 3, 4]) agentOf(pane('p$i', path: '/home/dev/s$i.jsonl'))];

    names.sync();
    await settle();
    expect(reads, hasLength(2), reason: 'two in flight, two queued');

    gate!.complete();
    await settle();
    expect(reads, hasLength(4));
    for (final i in [1, 2, 3, 4]) {
      expect(names.nameFor('a', 'p$i', '/home/dev/s$i.jsonl'), const PaneName.title('T'));
    }
  });

  test('panes that are gone are forgotten', () async {
    answer = (_) => _slices(title: 'Named');
    agents = [agentOf(pane('p1'))];
    names.sync();
    await settle();
    expect(names.nameFor('a', 'p1', _log), isNotNull);

    agents = [];
    names.sync();
    expect(names.nameFor('a', 'p1', _log), isNull);
  });
}
