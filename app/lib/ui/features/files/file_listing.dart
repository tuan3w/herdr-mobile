import '../../../data/models/remote_file.dart';

/// How a folder's entries are ordered. Each mode has one natural direction:
/// names A to Z, the newest change first, the largest first, then by type.
enum FileSort {
  name('Name', 'A to Z'),
  modified('Modified', 'Newest first'),
  size('Size', 'Largest first'),
  type('Type', 'By extension');

  const FileSort(this.label, this.hint);

  final String label;
  final String hint;
}

/// How recent "Changed recently" means.
const recentWindow = Duration(hours: 1);

/// [text] lowercased with its diacritics taken off, for searching: `thiet ke`
/// finds `Thiết kế`, and `dong` finds `Đồng` (Vietnamese đ is not a
/// composed letter, so it is mapped by hand). Decomposed (NFD) text, which
/// macOS file systems hand out, loses its combining marks too.
String foldForSearch(String text) {
  final lower = text.toLowerCase();
  var plain = true;
  for (final unit in lower.codeUnits) {
    if (unit > 0x7e) {
      plain = false;
      break;
    }
  }
  if (plain) return lower;
  final out = StringBuffer();
  for (final rune in lower.runes) {
    if (rune >= 0x0300 && rune <= 0x036f) continue; // combining marks
    final folded = _fold[rune];
    out.write(folded ?? String.fromCharCode(rune));
  }
  return out.toString();
}

final Map<int, String> _fold = () {
  const groups = {
    'a': 'àáảãạăằắẳẵặâầấẩẫậäåāą',
    'e': 'èéẻẽẹêềếểễệëēęě',
    'i': 'ìíỉĩịïīįı',
    'o': 'òóỏõọôồốổỗộơờớởỡợöøōő',
    'u': 'ùúủũụưừứửữựüūůűų',
    'y': 'ỳýỷỹỵÿ',
    'd': 'đďð',
    'c': 'çćčĉċ',
    'n': 'ñńňņ',
    's': 'śšşŝș',
    'z': 'źžż',
    'l': 'łľĺļ',
    'r': 'řŕ',
    't': 'ťțţ',
    'g': 'ğĝġ',
  };
  return {
    for (final MapEntry(key: plain, value: letters) in groups.entries)
      for (final rune in letters.runes) rune: plain,
    0xdf: 'ss',
    0xe6: 'ae',
    0x153: 'oe',
  };
}();

/// What the entry's name ends with, lowercased: `dart` for `a.test.dart`, ''
/// for `Makefile` and `.gitignore`.
String extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1 ? '' : name.substring(dot + 1).toLowerCase();
}

/// The sort key of one entry, worked out once per load.
class _Item {
  _Item(this.entry)
    : lower = entry.name.toLowerCase(),
      folded = foldForSearch(entry.name),
      ext = entry.isDirectory ? '' : extensionOf(entry.name);

  final RemoteEntry entry;
  final String lower;
  final String folded;
  final String ext;
}

/// One loaded folder, ready to be looked at in any order: the names are
/// lowercased and folded once, each ordering is built once and kept, and a
/// filter pass over 5,000 entries is a loop of string compares. Nothing here
/// touches a widget.
class FileListing {
  FileListing(Iterable<RemoteEntry> entries) : _items = [for (final e in entries) _Item(e)];

  final List<_Item> _items;
  final _orders = <(FileSort, bool), List<_Item>>{};

  int get length => _items.length;

  /// Entries the view would show with these settings, in order.
  ///
  /// [query] matches anywhere in the name, ignoring case and diacritics.
  /// [changedSince] keeps only what was modified at or after that moment
  /// (an entry with no known time is not "recent").
  List<RemoteEntry> view({
    required FileSort sort,
    required bool foldersFirst,
    required bool showHidden,
    String query = '',
    DateTime? changedSince,
  }) {
    final needle = foldForSearch(query.trim());
    final since = changedSince?.toUtc();
    final out = <RemoteEntry>[];
    for (final item in _order(sort, foldersFirst)) {
      final e = item.entry;
      if (!showHidden && e.isHidden) continue;
      if (since != null) {
        final m = e.modified;
        if (m == null || m.toUtc().isBefore(since)) continue;
      }
      if (needle.isNotEmpty && !item.folded.contains(needle)) continue;
      out.add(e);
    }
    return out;
  }

  /// Entries a folder holds that are hidden (dotfiles).
  int get hiddenCount => _items.where((i) => i.entry.isHidden).length;

  List<_Item> _order(FileSort sort, bool foldersFirst) =>
      _orders.putIfAbsent((sort, foldersFirst), () => _sorted(sort, foldersFirst));

  List<_Item> _sorted(FileSort sort, bool foldersFirst) {
    int byName(_Item a, _Item b) {
      final c = RemotePath.naturalCompareFolded(a.lower, b.lower);
      return c != 0 ? c : a.entry.name.compareTo(b.entry.name);
    }

    int primary(_Item a, _Item b) {
      switch (sort) {
        case FileSort.name:
          return byName(a, b);
        case FileSort.modified:
          final am = a.entry.modified;
          final bm = b.entry.modified;
          if (am == null || bm == null) {
            if (am == null && bm == null) return byName(a, b);
            return am == null ? 1 : -1;
          }
          final c = bm.compareTo(am); // newest first
          return c != 0 ? c : byName(a, b);
        case FileSort.size:
          // A folder's size is its directory block, not its content: folders
          // sort by name after the files.
          final ad = a.entry.isDirectory;
          final bd = b.entry.isDirectory;
          if (ad || bd) {
            if (ad && bd) return byName(a, b);
            return ad ? 1 : -1;
          }
          final c = (b.entry.size ?? -1).compareTo(a.entry.size ?? -1); // largest first
          return c != 0 ? c : byName(a, b);
        case FileSort.type:
          final c = a.ext.compareTo(b.ext);
          return c != 0 ? c : byName(a, b);
      }
    }

    final list = [..._items];
    list.sort((a, b) {
      if (foldersFirst) {
        final da = a.entry.isDirectory;
        final db = b.entry.isDirectory;
        if (da != db) return da ? -1 : 1;
      }
      return primary(a, b);
    });
    return list;
  }
}

/// Whether nobody could read [e]: no read bit for owner, group or others
/// (or, for a folder, no execute bit at all). Unknown permissions are never
/// "unreadable". Whether YOUR login may read it is only known by trying; the
/// browser remembers a refusal separately.
bool isUnreadable(RemoteEntry e) {
  final mode = e.mode;
  // A link's own mode (777) says nothing about what it points at.
  if (mode == null || e.kind == RemoteEntryKind.link) return false;
  if (mode & 0x124 == 0) return true; // 0o444
  if (e.isDirectory && mode & 0x49 == 0) return true; // 0o111
  return false;
}
