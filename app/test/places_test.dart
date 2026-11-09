import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/places.dart';
import 'package:herdr_mobile/data/words/place_name.dart';

import 'support/worktree_fixtures.dart';

void main() {
  const primary = '/home/u/workspace/herdr-mobile';
  const linked = '/home/u/.herdr/worktrees/herdr-mobile/worktree-lucky-cloud-848c';

  PlaceIndex index([List<Map<String, dynamic>>? extra]) => PlaceIndex.of(
    snapshotOf(
      workspaces: [
        wireWorkspace('w1', worktree: wirePrimaryWorktree),
        wireWorkspace('w2', worktree: wireLinkedWorktree),
        ...?extra,
      ],
    ),
  );

  group('which checkout a folder is in', () {
    test('a folder inside a linked checkout is that checkout', () {
      final place = index().of('$linked/app/lib')!;

      expect(
        (place.isLinked, place.checkoutName, place.repoName, place.workspaceId),
        (true, 'worktree-lucky-cloud-848c', 'herdr-mobile', 'w2'),
      );
    });

    test('a sibling folder that only shares a name prefix is not inside', () {
      expect(index().of('$primary-extra'), isNull);
      expect(index().of('$primary-extra/src'), isNull);
    });

    test('a trailing slash does not matter, and the checkout itself is in', () {
      expect(index().of('$primary/')!.workspaceId, 'w1');
      expect(index().of(primary)!.workspaceId, 'w1');
    });

    test('the deepest checkout wins when one is nested in another', () {
      final nested = {...wireLinkedWorktree, 'checkout_path': '$primary/.wt/x'};
      final idx = PlaceIndex.of(
        snapshotOf(
          workspaces: [
            wireWorkspace('w1', worktree: wirePrimaryWorktree),
            wireWorkspace('w2', worktree: nested),
          ],
        ),
      );

      expect(idx.of('$primary/.wt/x/app')!.workspaceId, 'w2');
      expect(idx.of('$primary/app')!.workspaceId, 'w1');
    });

    test('no cwd, a relative cwd and a folder of no checkout resolve to nothing', () {
      final idx = index();
      expect(idx.of(null), isNull);
      expect(idx.of('herdr-mobile'), isNull);
      expect(idx.of('/tmp/other'), isNull);
    });
  });

  group('repos', () {
    test('a repo is shown as a group only with two or more open checkouts, primary first', () {
      final idx = PlaceIndex.of(
        snapshotOf(
          workspaces: [
            wireWorkspace('w1', worktree: wireLinkedWorktree),
            wireWorkspace('w2', worktree: wirePrimaryWorktree),
          ],
        ),
      );

      expect(idx.repos.single.checkouts.map((w) => w.id), ['w2', 'w1']);
      expect(idx.groupOf('w1'), same(idx.groupOf('w2')));

      final lone = PlaceIndex.of(snapshotOf(workspaces: [wireWorkspace('w1', worktree: wirePrimaryWorktree)]));
      expect(lone.repos, isEmpty);
      expect(lone.groupOf('w1'), isNull);
    });

    test('a plain workspace is in no group', () {
      expect(index([wireWorkspace('w3')]).groupOf('w3'), isNull);
    });

    test('a repo with one open checkout is an anchor too, and an open checkout is told from a closed one', () {
      final lone = PlaceIndex.of(
        snapshotOf(
          workspaces: [
            wireWorkspace('w1', worktree: wirePrimaryWorktree),
            wireWorkspace('w3'),
          ],
        ),
      );
      expect(lone.repos, isEmpty);
      expect(lone.anchors.map((p) => p.workspaceId), ['w1'], reason: 'a plain workspace has no repo to ask about');

      final idx = index();
      expect(idx.anchors.map((p) => p.workspaceId), ['w1'], reason: 'one anchor per repo, not per checkout');
      expect(idx.isOpenCheckout(linked), isTrue);
      expect(idx.isOpenCheckout('$linked/'), isTrue);
      expect(idx.isOpenCheckout('/home/u/.herdr/worktrees/herdr-mobile/closed-one'), isFalse);
    });
  });

  group('the one place name', () {
    test('a linked checkout reads checkout first, then the repo', () {
      expect(placeName(index(), '$linked/app'), 'worktree-lucky-cloud-848c · herdr-mobile');
    });

    test('the main checkout, its sub-folders, unknown and missing folders keep the last segment', () {
      final idx = index();
      expect(placeName(idx, primary), 'herdr-mobile');
      expect(placeName(idx, '$primary/app'), 'app');
      expect(placeName(idx, '/tmp/scratch'), 'scratch');
      expect(placeName(idx, null), '');
    });
  });
}
