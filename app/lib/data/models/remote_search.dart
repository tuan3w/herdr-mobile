import 'remote_file.dart';

/// What a search is looking for: the kinds of entry matched.
enum FileSearchKind {
  any,
  file,
  dir;

  static FileSearchKind parse(String? name) => values.firstWhere((k) => k.name == name, orElse: () => any);
}

/// A search below a folder: names that contain [query], changed within
/// [modifiedWithin], of one [kind]. Plain data (it crosses the transport
/// isolate as JSON, and is what the host's `fs.search` is called with).
///
/// An empty [query] matches every name, which only makes sense together with
/// [modifiedWithin] ("what changed in the last hour, anywhere below here").
class FileSearchSpec {
  const FileSearchSpec({
    required this.root,
    this.query = '',
    this.kind = FileSearchKind.any,
    this.modifiedWithin,
    this.maxResults = defaultMaxResults,
    this.maxDepth = defaultMaxDepth,
    this.hidden = false,
    this.ignore = defaultIgnore,
  });

  /// Matches the host's own defaults, so a machine without `fs.search` is
  /// walked with the same rules.
  static const defaultMaxResults = 500;
  static const defaultMaxDepth = 12;

  /// Folder names nobody looks for files in: they hold what tools generate,
  /// thousands of entries each. Matched against one path component.
  static const defaultIgnore = ['.git', 'node_modules', 'target', '.cache', '__pycache__', '.venv', 'build'];

  final String root;

  /// Case-insensitive part of a file or folder NAME (not its path).
  final String query;
  final FileSearchKind kind;

  /// Only entries changed this recently; null for any time.
  final Duration? modifiedWithin;
  final int maxResults;
  final int maxDepth;

  /// Whether names that start with a dot are looked at (and entered).
  final bool hidden;

  /// Names that are not entered, nor reported.
  final List<String> ignore;

  Map<String, Object?> toJson() => {
    'root': root,
    'query': query,
    'kind': kind.name,
    'within': modifiedWithin?.inSeconds,
    'max': maxResults,
    'depth': maxDepth,
    'hidden': hidden,
    'ignore': ignore,
  };

  factory FileSearchSpec.fromJson(Map<Object?, Object?> j) => FileSearchSpec(
    root: j['root']! as String,
    query: j['query'] as String? ?? '',
    kind: FileSearchKind.parse(j['kind'] as String?),
    modifiedWithin: j['within'] == null ? null : Duration(seconds: j['within']! as int),
    maxResults: j['max'] as int? ?? defaultMaxResults,
    maxDepth: j['depth'] as int? ?? defaultMaxDepth,
    hidden: j['hidden'] == true,
    ignore: [for (final n in (j['ignore'] as List?) ?? defaultIgnore) n as String],
  );
}

/// What a search says while it runs: batches of matches as they are found, then
/// one [FileSearchDone].
sealed class FileSearchEvent {
  const FileSearchEvent();

  Map<String, Object?> toJson();

  factory FileSearchEvent.fromJson(Map<Object?, Object?> j) => j['done'] == true
      ? FileSearchDone(
          scanned: j['scanned'] as int? ?? 0,
          truncated: j['truncated'] == true,
          skippedDirs: j['skipped'] as int? ?? 0,
        )
      : FileSearchBatch([for (final e in (j['entries']! as List)) RemoteEntry.fromJson(e as Map)]);
}

/// Matches found since the last batch (at most about 100), shallow ones first.
final class FileSearchBatch extends FileSearchEvent {
  const FileSearchBatch(this.entries);

  final List<RemoteEntry> entries;

  @override
  Map<String, Object?> toJson() => {
    'entries': [for (final e in entries) e.toJson()],
  };
}

/// The search ended: everything was looked at, or it stopped at a limit
/// ([truncated]: the result count, the number of entries looked at, or the
/// time). Never sent when the search failed (that is an error on the stream).
final class FileSearchDone extends FileSearchEvent {
  const FileSearchDone({required this.scanned, required this.truncated, this.skippedDirs = 0});

  /// Entries looked at, matching or not.
  final int scanned;
  final bool truncated;

  /// Folders that could not be read (permission) and were left out.
  final int skippedDirs;

  @override
  Map<String, Object?> toJson() => {'done': true, 'scanned': scanned, 'truncated': truncated, 'skipped': skippedDirs};
}
