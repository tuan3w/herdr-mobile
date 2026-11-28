import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/models/machine_layout.dart';
import 'package:herdr_mobile/data/models/places.dart';

import 'support/worktree_fixtures.dart';

const _primary = '/home/u/workspace/herdr-mobile';
const _linked = '/home/u/.herdr/worktrees/herdr-mobile/worktree-lucky-cloud-848c';

List<MachineItem> _layout(Snapshot s, [Set<String> keepers = const {}]) => machineLayout(s, PlaceIndex.of(s), keepers);

void main() {
  // w1 primary, w2 linked, w3 "Phone sessions" (plain), w4 an unrelated repo.
  Snapshot snap({List<Map<String, dynamic>> panes = const [], bool linkedFirst = false, String phoneStatus = 'idle'}) {
    final main = wireWorkspace('w1', worktree: wirePrimaryWorktree, number: 1);
    final lk = wireWorkspace('w2', worktree: wireLinkedWorktree, number: 2);
    return snapshotOf(
      workspaces: [
        if (linkedFirst) lk,
        main,
        if (!linkedFirst) lk,
        wireWorkspace('w3', label: 'Phone sessions', number: 3, status: phoneStatus),
        wireWorkspace('w4', number: 4),
      ],
      tabs: [
        wireTab('w1:t1', 'w1'),
        wireTab('w2:t1', 'w2'),
        wireTab('w2:t2', 'w2', number: 2),
        wireTab('w3:t1', 'w3'),
        wireTab('w4:t1', 'w4'),
      ],
      panes: panes,
    );
  }

  List<String> ids(List<PaneEntry> e) => [for (final x in e) x.pane.id];

  test(
    'a repo with two checkouts is one item at its first member, blocks primary first, other workspaces as they are',
    () {
      final items = _layout(
        snap(
          linkedFirst: true,
          panes: [
            wirePaneIn('p1', 'w1', 'w1:t1', cwd: _primary),
            wirePaneIn('p2', 'w2', 'w2:t1', cwd: _linked),
            wirePaneIn('p3', 'w4', 'w4:t1', cwd: '/tmp/x'),
          ],
        ),
      );

      expect(items.map((i) => i.runtimeType), [RepoItem, WorkspaceItem, WorkspaceItem]);
      final repo = items.first as RepoItem;
      expect(repo.blocks.map((b) => (b.workspace.id, b.place.isLinked)), [('w1', false), ('w2', true)]);
      expect(repo.paneCount, 2);
    },
  );

  test('a repo with one open checkout is a plain section', () {
    final s = snapshotOf(
      workspaces: [wireWorkspace('w1', worktree: wirePrimaryWorktree)],
      tabs: [wireTab('w1:t1', 'w1')],
      panes: [wirePaneIn('p1', 'w1', 'w1:t1', cwd: _primary)],
    );

    expect(_layout(s).single, isA<WorkspaceItem>());
  });

  test(
    'a phone session whose folder is in a checkout is listed after that checkout\'s own panes, without a tab label',
    () {
      final items = _layout(
        snap(
          panes: [
            wirePaneIn('own', 'w2', 'w2:t1', cwd: _linked),
            wirePaneIn('own2', 'w2', 'w2:t2', cwd: _linked),
            wirePaneIn('keeper', 'w3', 'w3:t1', cwd: '$_linked/app', agent: 'omp'),
            wirePaneIn('other', 'w3', 'w3:t1', cwd: '/tmp/else'),
          ],
        ),
        {'keeper'},
      );

      final linked = (items.first as RepoItem).blocks.last;
      expect(ids(linked.panes), ['own2', 'own', 'keeper'], reason: 'newest tab first, then placed sessions');
      expect(linked.panes.last.tab, isNull);
      expect(linked.panes.first.tab, 'Tab 2', reason: 'a workspace with several tabs says which');

      final phone = items.whereType<WorkspaceItem>().firstWhere((w) => w.workspace.id == 'w3');
      expect(ids(phone.panes), ['other']);
    },
  );

  test('a phone session in no checkout stays in its own workspace', () {
    final items = _layout(
      snap(
        panes: [wirePaneIn('keeper', 'w3', 'w3:t1', cwd: '/tmp/else', agent: 'omp')],
      ),
      {'keeper'},
    );

    final phone = items.whereType<WorkspaceItem>().firstWhere((w) => w.workspace.id == 'w3');
    expect(ids(phone.panes), ['keeper']);
  });

  test('a workspace whose panes all moved under a checkout is dropped', () {
    final items = _layout(
      snap(
        panes: [wirePaneIn('keeper', 'w3', 'w3:t1', cwd: _primary, agent: 'omp')],
      ),
      {'keeper'},
    );

    expect(items.whereType<WorkspaceItem>().map((w) => w.workspace.id), ['w4']);
    expect(ids((items.first as RepoItem).blocks.first.panes), ['keeper']);
  });

  test(
    'a session in a workspace of its own in the main checkout is listed under that checkout, not as a workspace',
    () {
      final s = snapshotOf(
        workspaces: [
          wireWorkspace('w1', worktree: wirePrimaryWorktree, number: 1),
          wireWorkspace('w5', label: 'omp · herdr-mobile', number: 2),
          wireWorkspace('w6', label: 'omp · scratch', number: 3),
        ],
        tabs: [wireTab('w1:t1', 'w1'), wireTab('w5:t1', 'w5'), wireTab('w6:t1', 'w6')],
        panes: [
          wirePaneIn('p1', 'w1', 'w1:t1', cwd: _primary),
          wirePaneIn('keeper', 'w5', 'w5:t1', cwd: _primary, agent: 'omp'),
          wirePaneIn('flat', 'w6', 'w6:t1', cwd: '/tmp/scratch', agent: 'omp'),
        ],
      );

      final items = _layout(s, {'keeper', 'flat'});

      expect(items.whereType<WorkspaceItem>().map((i) => i.workspace.id), [
        'w1',
        'w6',
      ], reason: 'w5 emptied: its session sits under the checkout');
      expect(ids((items.first as WorkspaceItem).panes), ['p1', 'keeper']);
      expect(ids((items.last as WorkspaceItem).panes), [
        'flat',
      ], reason: 'in no checkout it stays in its own workspace');
    },
  );

  test('a pane that is not a phone session never leaves its workspace, whatever its folder', () {
    final items = _layout(snap(panes: [wirePaneIn('p', 'w3', 'w3:t1', cwd: _linked)]));

    final phone = items.whereType<WorkspaceItem>().firstWhere((w) => w.workspace.id == 'w3');
    expect(ids(phone.panes), ['p']);
  });

  test('a blocked agent makes its checkout and the repo blocked; unknown only when nothing is known', () {
    final items = _layout(
      snap(
        panes: [
          wirePaneIn('a', 'w1', 'w1:t1', cwd: _primary, agent: 'omp', status: 'working'),
          wirePaneIn('b', 'w2', 'w2:t1', cwd: _linked, agent: 'omp', status: 'blocked'),
          wirePaneIn('c', 'w2', 'w2:t1', cwd: _linked, status: 'unknown'),
        ],
      ),
    );

    final repo = items.first as RepoItem;
    expect(repo.blocks.map((b) => b.status), [AgentStatus.working, AgentStatus.blocked]);
    expect(repo.status, AgentStatus.blocked);

    final quiet = _layout(
      snap(
        panes: [wirePaneIn('c', 'w1', 'w1:t1', cwd: _primary, status: 'unknown')],
      ),
    );
    expect((quiet.first as RepoItem).status, AgentStatus.unknown);
  });

  test('a finished agent outranks a working one, as in every other roll-up', () {
    final items = _layout(
      snap(
        panes: [
          wirePaneIn('a', 'w1', 'w1:t1', cwd: _primary, agent: 'omp', status: 'working'),
          wirePaneIn('b', 'w2', 'w2:t1', cwd: _linked, agent: 'omp', status: 'done'),
        ],
      ),
    );

    expect((items.first as RepoItem).status, AgentStatus.done);
  });

  test('a workspace that lost its blocked session to a checkout no longer says blocked', () {
    final items = _layout(
      snap(
        phoneStatus: 'blocked',
        panes: [
          wirePaneIn('keeper', 'w3', 'w3:t1', cwd: _linked, agent: 'omp', status: 'blocked'),
          wirePaneIn('idle', 'w3', 'w3:t1', cwd: '/tmp/else', agent: 'omp', status: 'idle'),
        ],
      ),
      {'keeper'},
    );

    final phone = items.whereType<WorkspaceItem>().firstWhere((w) => w.workspace.id == 'w3');
    expect(phone.workspace.status, AgentStatus.idle);
    expect((items.first as RepoItem).status, AgentStatus.blocked, reason: 'it moved where it is read');
  });

  test('a repo with one open checkout takes its phone sessions into that section', () {
    final s = snapshotOf(
      workspaces: [
        wireWorkspace('w2', worktree: wireLinkedWorktree, number: 1),
        wireWorkspace('w3', label: 'Phone sessions', number: 2),
      ],
      tabs: [wireTab('w2:t1', 'w2'), wireTab('w3:t1', 'w3')],
      panes: [
        wirePaneIn('sh', 'w2', 'w2:t1', cwd: _linked),
        wirePaneIn('keeper', 'w3', 'w3:t1', cwd: '$_linked/app', agent: 'omp'),
      ],
    );
    final items = _layout(s, {'keeper'});

    expect(items.single, isA<WorkspaceItem>());
    expect(ids((items.single as WorkspaceItem).panes), ['sh', 'keeper']);
  });

  test('a phone session already in its checkout\'s own workspace keeps its place and tab', () {
    final items = _layout(
      snap(
        panes: [
          wirePaneIn('a', 'w2', 'w2:t1', cwd: _linked),
          wirePaneIn('keeper', 'w2', 'w2:t2', cwd: _linked, agent: 'omp'),
        ],
      ),
      {'keeper'},
    );

    final linked = (items.first as RepoItem).blocks.last;
    expect(linked.panes.map((e) => (e.pane.id, e.tab)), [('keeper', 'Tab 2'), ('a', 'Tab 1')]);
  });
}
