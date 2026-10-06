/// A point in a transcript the keeper can replay from: the phone holds every
/// turn of the keeper's log (named [epoch]) before [turn], as [prefix], the
/// raw lines that build them. The keeper stamps the first line of every turn
/// it replays (`params._meta.herdr = {epoch, turn}`), so a saved copy can be
/// cut where its last stamped turn begins. Everything from there is asked for
/// again: that turn may have grown since, and lines the phone got live carry
/// no stamp.
class ReplaySince {
  const ReplaySince({required this.epoch, required this.turn, required this.prefix});

  final String epoch;
  final int turn;

  /// The lines before the stamped one, oldest first.
  final List<String> prefix;
}

final _turnStamp = RegExp(r'"herdr"\s*:\s*\{\s*"epoch"\s*:\s*"([0-9a-f]+)"\s*,\s*"turn"\s*:\s*(\d+)\s*\}');

/// Where [lines] (a saved copy, oldest first) can be cut to ask the keeper for
/// less than its whole log; null when it has no stamp, or the cut leaves
/// nothing before it (a whole replay costs the same then).
ReplaySince? replaySinceOf(List<String> lines) {
  for (var i = lines.length - 1; i > 0; i--) {
    final line = lines[i];
    if (!line.contains('"herdr"')) continue;
    final m = _turnStamp.firstMatch(line);
    if (m == null) continue;
    return ReplaySince(epoch: m[1]!, turn: int.parse(m[2]!), prefix: lines.sublist(0, i));
  }
  return null;
}
