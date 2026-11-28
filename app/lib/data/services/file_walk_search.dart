import 'dart:async';
import 'dart:collection';

import '../models/remote_file.dart';
import '../models/remote_search.dart';

/// Entries a walking search looks at before it stops and says it did not finish.
const walkSearchMaxScanned = 3000;

/// How long a walking search goes on, in total.
const walkSearchBudget = Duration(seconds: 4);

/// Matches in a batch, at most (the host's `fs.search` sends the same).
const _batchSize = 100;

/// A search for a machine that has no `fs.search` (SFTP, or an older agent
/// helper): a breadth-first walk over [list], one folder at a time, so the
/// shallow matches come first. It never enters a link, skips [FileSearchSpec.ignore]
/// names and (unless asked) names that start with a dot, and stops at
/// [maxScanned] entries looked at or after [budget], saying so in
/// [FileSearchDone.truncated]: SFTP lists one folder per round trip, so an
/// unbounded walk of a big tree would hold the radio for minutes.
///
/// A folder that cannot be listed (permission, gone meanwhile) is skipped and
/// counted; the first listing, of the root, fails the search with its error,
/// and so does a lost connection. Batches are sent as each folder has been
/// looked at; cancelling the subscription stops before the next listing.
///
/// [now] is the clock for both the time limit and "changed within".
Stream<FileSearchEvent> walkSearch(
  Future<List<RemoteEntry>> Function(String path) list,
  FileSearchSpec spec, {
  DateTime Function()? now,
  int maxScanned = walkSearchMaxScanned,
  Duration budget = walkSearchBudget,
}) {
  final clock = now ?? DateTime.now;
  var cancelled = false;
  late final StreamController<FileSearchEvent> out;

  Future<void> run() async {
    final started = clock();
    final within = spec.modifiedWithin;
    final since = within == null ? null : started.subtract(within);
    final needle = spec.query.trim().toLowerCase();
    final ignore = spec.ignore.toSet();
    final queue = Queue<(String, int)>()..add((spec.root, 0));
    var scanned = 0;
    var found = 0;
    var skipped = 0;
    var truncated = false;
    var first = true;

    bool matches(RemoteEntry e) {
      if (needle.isNotEmpty && !e.name.toLowerCase().contains(needle)) return false;
      switch (spec.kind) {
        case FileSearchKind.any:
          break;
        case FileSearchKind.file:
          if (!e.isFile) return false;
        case FileSearchKind.dir:
          if (!e.isDirectory) return false;
      }
      if (since != null) {
        final at = e.modified;
        if (at == null || at.isBefore(since)) return false;
      }
      return true;
    }

    while (queue.isNotEmpty && !cancelled) {
      if (clock().difference(started) >= budget) {
        truncated = true;
        break;
      }
      final (dir, depth) = queue.removeFirst();
      final List<RemoteEntry> entries;
      try {
        entries = await list(dir);
      } on RemoteFileException catch (e) {
        if (first || e.kind == RemoteFileErrorKind.network || e.kind == RemoteFileErrorKind.unsupported) rethrow;
        skipped++;
        continue;
      }
      first = false;
      if (cancelled) return;
      final batch = <RemoteEntry>[];
      for (final e in entries) {
        // `ignore` names folders (and links); a file called `build` is a file.
        final skippable = e.kind == RemoteEntryKind.dir || e.kind == RemoteEntryKind.link;
        if ((skippable && ignore.contains(e.name)) || (!spec.hidden && e.isHidden)) continue;
        scanned++;
        if (matches(e)) {
          if (found >= spec.maxResults) {
            truncated = true;
            break;
          }
          found++;
          batch.add(e);
        }
        // A link is reported but never entered: it may lead back up the tree.
        // (The entries of the root are depth 1, as on the host.)
        if (e.kind == RemoteEntryKind.dir && depth + 1 < spec.maxDepth) queue.add((e.path, depth + 1));
        if (scanned >= maxScanned) {
          truncated = true;
          break;
        }
      }
      for (var i = 0; i < batch.length; i += _batchSize) {
        out.add(FileSearchBatch(batch.sublist(i, i + _batchSize < batch.length ? i + _batchSize : batch.length)));
      }
      if (truncated) break;
    }
    if (cancelled) return;
    out.add(FileSearchDone(scanned: scanned, truncated: truncated, skippedDirs: skipped));
  }

  out = StreamController<FileSearchEvent>(
    onListen: () {
      run().then(
        (_) {
          if (!out.isClosed) unawaited(out.close());
        },
        onError: (Object e, StackTrace s) {
          if (out.isClosed) return;
          out.addError(e, s);
          unawaited(out.close());
        },
      );
    },
    onCancel: () => cancelled = true,
  );
  return out.stream;
}
