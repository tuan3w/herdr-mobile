import 'dart:collection';

/// The first [length] rows of an append-only list of rows, read-only.
///
/// What a pane's scrollback hands to the view: taking one is O(1), where
/// copying thousands of rows on every read was a cost that grew with how long
/// the pane had been open. It stays exactly as it was when taken because the
/// owner only ever appends to [backing] while a snapshot of it is out; any
/// other change (rows dropped from either end, a clear) moves the owner to a
/// fresh list first.
///
/// Two snapshots of the same [backing] therefore share their common prefix,
/// which lets a consumer that parsed the older one skip the rows it already
/// knows (see `TerminalDocument.update`).
final class RowsSnapshot extends ListBase<String> {
  RowsSnapshot(this.backing, this.length);

  /// The list the rows live in. Shared; only ever appended to while this
  /// snapshot exists.
  final List<String> backing;

  @override
  final int length;

  @override
  set length(int value) =>
      throw UnsupportedError('Cannot change the length of a RowsSnapshot');

  @override
  String operator [](int index) {
    if (index < 0 || index >= length) throw RangeError.index(index, this);
    return backing[index];
  }

  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('Cannot modify a RowsSnapshot');
}
