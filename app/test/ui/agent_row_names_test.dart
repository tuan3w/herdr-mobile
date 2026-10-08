// What the board calls an agent whose own title says nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' hide Pane;
import 'package:herdr_mobile/data/models/herdr_models.dart' as models show Pane;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_name.dart';
import 'package:herdr_mobile/data/models/status_time.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';

import 'ui_harness.dart';

void main() {
  late UiHarness h;

  setUp(() async {
    h = await UiHarness.create([
      (
        profile: MachineProfile(id: 'a', label: 'studio', host: 'a.example', username: 'dev'),
        snapshot: snapshotWith(const []),
      ),
    ]);
    await pumpEventQueue(times: 50);
  });

  tearDown(() => h.dispose());

  AgentRowData row({
    String title = 'payments-api',
    String? label,
    String agent = 'omp',
    PaneName? name,
    AgentStatus status = AgentStatus.idle,
    DateTime? lastActive,
  }) =>
      agentRow(
        FleetAgent(
          machine: h.fleet.connections.single,
          pane: models.Pane(
            id: 'p1',
            workspaceId: 'w1',
            tabId: 'w1:t1',
            focused: false,
            cwd: '/src/payments-api',
            title: label ?? title,
            label: label,
            agent: agent,
            status: status,
          ),
          workspace: null,
          sessionName: name,
          lastActive: lastActive,
        ),
        showMachine: false,
      );

  group('when an idle agent last did something', () {
    final at = DateTime.utc(2026, 1, 1, 9, 30);

    test('an idle agent the app has no time for takes the moment its session file was last written', () {
      final r = row(lastActive: at);
      expect(r.since, StatusTime.exact(at), reason: 'so the Idle section can be put in order, and says idle 3h');
    });

    test('without a file time it stays unknown, as before', () {
      expect(row().since, isNull);
    });

    test('only an idle agent: for the others herdr\'s own transitions say it', () {
      for (final s in [AgentStatus.working, AgentStatus.done, AgentStatus.blocked]) {
        expect(row(status: s, lastActive: at).since, isNull, reason: s.name);
      }
    });
  });

  test('a title that is only the folder is replaced by the session title', () {
    final r = row(name: const PaneName.title('Fix the retry test'));
    expect(r.title, 'Fix the retry test');
    expect(r.subtitle, 'omp · payments-api', reason: 'the agent still leads the second line');
  });

  test('a name taken from the last message is shown in quotes: it is what was asked', () {
    final r = row(name: const PaneName.prompt('Add a regression test'));
    expect(r.title, '\u201CAdd a regression test\u201D');
  });

  test('the agent\'s own name for itself counts as generic too', () {
    expect(row(title: 'omp', name: const PaneName.title('Rotate certs')).title, 'Rotate certs');
    expect(row(title: 'terminal', name: const PaneName.title('Rotate certs')).title, 'Rotate certs');
  });

  test('a title that names the work is kept; a log name does not replace it', () {
    final r = row(title: 'Add mobile keyboard autocomplete', name: const PaneName.title('Something else'));
    expect(r.title, 'Add mobile keyboard autocomplete');
  });

  test('a name the person gave the pane always wins, even when it is the folder', () {
    final r = row(label: 'payments-api', name: const PaneName.title('Something else'));
    expect(r.title, 'payments-api');
  });

  test('with no name read, the row reads as it always did', () {
    final r = row();
    expect(r.title, 'payments-api');
    expect(r.subtitle, 'omp · payments-api');
  });

  test('a pane with no title at all is still named after its agent when nothing was read', () {
    final r = row(title: '');
    expect(r.title, 'omp');
    expect(r.subtitle, 'payments-api', reason: 'the agent is the title, so not said twice');
  });
}
