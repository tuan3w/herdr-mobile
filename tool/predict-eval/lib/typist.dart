import 'dart:math' as math;

import 'predictor.dart';
import 'vietnamese.dart';
import 'words.dart';

/// How the simulated person types.
enum Style {
  /// One key press per character. Right for English.
  chars,

  /// Vietnamese with Telex: marks and tones cost extra keys (`việt` = 6).
  telex,

  /// Vietnamese typed without marks (`khong`): one key per character, and the
  /// text on screen has no marks. A chip that answers with the marked word is
  /// correct when it is the word they meant.
  bare,
}

class Simulation {
  const Simulation({
    this.style = Style.telex,
    this.slots = 3,
    this.tapCost = 1.0,
    this.notice = 1.0,
    this.seed = 20261007,
  });

  final Style style;

  /// Chips visible at once: a keyboard's suggestion strip shows three.
  final int slots;

  /// Cost of a tap on a chip, in key presses: the thumb leaves the keys and the
  /// eyes leave the text, so it is not free. Assumed, not measured.
  final double tapCost;

  /// Chance the person notices a right chip. 1 = always (the ceiling); omp
  /// reports 0.5 next to it.
  final double notice;
  final int seed;

  double keyCost(String char) => style == Style.telex ? telexKeys(char).toDouble() : 1;
}

/// Counts over many messages. Everything per message is summed; ratios are
/// taken at the end.
class Tally {
  int messages = 0;
  int words = 0;

  /// Key presses to type the messages with no help.
  double baseKeys = 0;

  /// Key presses with chips: typing, taps, and the backspace after a chip's
  /// space that the text did not want.
  double keys = 0;
  int taps = 0;

  /// Messages finished by taps alone (nothing typed): the supervisor's best case.
  int tapOnly = 0;

  /// Words where a chip was on screen and nothing was tapped for that word.
  int noisyWords = 0;

  /// Times the first chip changed while the same word was being typed: a chip
  /// that moves under the thumb is a mis-tap.
  int flips = 0;
  int positions = 0;
  int positionsWithChips = 0;

  void add(Tally o) {
    messages += o.messages;
    words += o.words;
    baseKeys += o.baseKeys;
    keys += o.keys;
    taps += o.taps;
    tapOnly += o.tapOnly;
    noisyWords += o.noisyWords;
    flips += o.flips;
    positions += o.positions;
    positionsWithChips += o.positionsWithChips;
  }

  /// Share of key presses not needed.
  double get ksr => baseKeys == 0 ? 0 : 1 - keys / baseKeys;
  double per100Words(int n) => words == 0 ? 0 : 100 * n / words;
  double get chipsOnScreen => positions == 0 ? 0 : positionsWithChips / positions;
}

/// Types [truth] one character at a time into [predictor], tapping a chip the
/// moment a chip is exactly right and worth its tap. The person is an oracle:
/// they never tap a wrong chip, so wrong chips cost attention (counted as
/// noise and flips), not keys.
Tally typeMessage(
  String truth,
  Predictor predictor,
  Simulation sim,
  int index, {
  void Function(int micros)? onSuggest,
}) {
  final rng = math.Random(sim.seed + index);
  final bare = sim.style == Style.bare;
  final truthFolded = bare ? foldVietnamese(truth) : truth;
  final spans = allWords(truth);
  int wordAt(int p) {
    for (var i = 0; i < spans.length; i++) {
      if (spans[i].end >= p) return i;
    }
    return spans.length;
  }

  final t = Tally()
    ..messages = 1
    ..words = math.max(1, spans.length);
  for (var i = 0; i < truth.length; i++) {
    t.baseKeys += sim.keyCost(truth[i]);
  }

  var typed = '';
  var pos = 0;
  var typedChars = 0;
  final shown = <int>{}, tapped = <int>{};
  final noticed = <int, bool>{};
  String? lastSignature;
  var lastWord = -1;
  final clock = Stopwatch();

  while (pos < truth.length) {
    clock
      ..reset()
      ..start();
    final chips = predictor.suggest(typed, sim.slots);
    clock.stop();
    onSuggest?.call(clock.elapsedMicroseconds);

    final word = wordAt(pos);
    t.positions++;
    if (chips.isEmpty) {
      lastSignature = null;
    } else {
      t.positionsWithChips++;
      shown.add(word);
      final signature = chips.first.signature;
      if (lastWord == word && lastSignature != null && lastSignature != signature) t.flips++;
      lastSignature = signature;
      lastWord = word;
    }

    var accepted = false;
    for (final chip in chips) {
      final from = typed.length - chip.replace;
      final r = typed.substring(0, from) + chip.insert;
      final right = bare
          ? r.length <= truth.length &&
              truthFolded.startsWith(foldVietnamese(r)) &&
              truth.startsWith(chip.insert, from)
          : truth.startsWith(r);
      if (!right || r.length <= pos) continue;

      var newPos = r.length;
      var newTyped = r;
      var backspace = 0;
      if (chip.space && newPos < truth.length) {
        if (truth[newPos] == ' ') {
          newTyped = '$r ';
          newPos++;
        } else {
          backspace = 1;
        }
      }
      var saved = 0.0;
      for (var i = pos; i < newPos; i++) {
        saved += sim.keyCost(truth[i]);
      }
      if (saved - sim.tapCost - backspace <= 0) continue;
      if (!(noticed[word] ??= rng.nextDouble() < sim.notice)) continue;

      t.keys += sim.tapCost + backspace;
      t.taps++;
      tapped.add(word);
      typed = newTyped;
      pos = newPos;
      accepted = true;
      break;
    }
    if (accepted) continue;

    t.keys += sim.keyCost(truth[pos]);
    typed += bare ? foldVietnamese(truth[pos]) : truth[pos];
    pos++;
    typedChars++;
  }
  t.noisyWords = shown.difference(tapped).length;
  if (typedChars == 0 && t.taps > 0) t.tapOnly = 1;
  return t;
}
