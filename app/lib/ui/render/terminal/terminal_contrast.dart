import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:herdr_mobile/ui/core/kit.dart';

import 'ansi.dart';
import 'box_drawing.dart' show isBoxGlyph;

/// How far dim (SGR 2) text is blended from the background to its colour.
const terminalDimBlend = 0.62;

/// The render-time contrast guard: text that does not read against ITS OWN
/// cell's background (the page, or the cell's background colour, reverse video
/// already resolved) is lifted towards readable, so the palette can keep the
/// true ANSI colours.
///
/// What it judges is the colour the glyphs are drawn in, whatever made it: an
/// ANSI colour, a 256-colour or truecolour one, the default, or dim text (the
/// blend towards the background). It changes lightness only, by
/// [liftToContrast], to [TerminalPalette.minContrast]; backgrounds are never
/// touched, and a colour that reads is never changed. Box drawing, block
/// elements and blank cells are shapes, not text, and are left as they are.
///
/// The answer for a pair of colours is remembered, so the cost of a run is a
/// map lookup, and a run with no colour at all costs a null check.
abstract final class TerminalContrast {
  /// Stored for a pair that reads (a `Color` of alpha 0 is never produced).
  static const _reads = Color(0x00000000);

  /// Pairs kept. A truecolour gradient can produce any number; past this the
  /// memory is dropped and refilled, and the next row asks again.
  static const _capacity = 4096;

  static final _text = <int, Color>{};
  static final _dim = <int, Color>{};

  static int _computed = 0;

  /// Pairs worked out (not found in memory) since [debugReset].
  @visibleForTesting
  static int get debugComputed => _computed;

  @visibleForTesting
  static void debugReset() {
    _text.clear();
    _dim.clear();
    _computed = 0;
  }

  @visibleForTesting
  static void debugResetCount() => _computed = 0;

  /// The colour glyphs drawn in [fg] (dim: blended towards [bg] first) on [bg]
  /// are lifted to, or null when they read as they are. Both are ARGB.
  static Color? lifted(int fg, int bg, bool dim) {
    final memory = dim ? _dim : _text;
    final key = (fg << 32) | bg;
    var answer = memory[key];
    if (answer == null) {
      if (memory.length >= _capacity) memory.clear();
      _computed++;
      final on = Color(bg);
      final ink = dim ? Color.lerp(on, Color(fg), terminalDimBlend)! : Color(fg);
      final lift = liftToContrast(ink, on, TerminalPalette.minContrast);
      answer = identical(lift, ink) ? _reads : lift;
      memory[key] = answer;
    }
    return identical(answer, _reads) ? null : answer;
  }

  /// [run] drawn in [colour] where it has text, as the pieces it falls into:
  /// frames and blocks keep the run's own colour, words get [colour]. Null when
  /// the run has no text to draw (shapes and blanks only).
  ///
  /// A lifted run is no longer dim: [colour] is the colour as blended.
  static List<AnsiRun>? apply(AnsiRun run, Color colour) {
    final text = run.text;
    // Blanks stay with the piece before them (the first run of them with the
    // piece after), so the pieces cut where a word and a shape meet.
    bool? lift;
    var start = 0;
    List<AnsiRun>? pieces;
    AnsiRun piece(int from, int to, bool lifted) {
      final part = from == 0 && to == text.length ? text : text.substring(from, to);
      if (!lifted) return run.withText(part);
      return AnsiRun(
        part,
        fg: colour,
        bg: run.bg,
        bold: run.bold,
        italic: run.italic,
        underline: run.underline,
        strike: run.strike,
      );
    }

    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x20 || unit == 0xA0) continue;
      final word = !isBoxGlyph(unit);
      if (lift == null) {
        lift = word;
      } else if (word != lift) {
        (pieces ??= []).add(piece(start, i, lift));
        start = i;
        lift = word;
      }
    }
    if (lift == null) return null;
    if (pieces == null && !lift) return null;
    pieces ??= [];
    pieces.add(piece(start, text.length, lift));
    return pieces;
  }
}

/// A [TerminalPalette] applied to the parser's runs.
extension AnsiRecolor on TerminalPalette {
  /// [runs] as this palette draws them: the parser's [TerminalColors] become
  /// this palette's; text that has a background of its own and no colour takes
  /// whichever default reads on it; text below [TerminalPalette.minContrast]
  /// against its own background is lifted (see [TerminalContrast]).
  ///
  /// The list itself comes back when nothing changed, and so does every run
  /// that needed nothing.
  List<AnsiRun> recolor(List<AnsiRun> runs) {
    List<AnsiRun>? out;
    for (var i = 0; i < runs.length; i++) {
      final run = runs[i];
      final mapped = isDark ? run : _mapped(run);
      final lifted = _lift(mapped);
      if (lifted == null && identical(mapped, run)) {
        out?.add(run);
        continue;
      }
      out ??= runs.sublist(0, i);
      if (lifted == null) {
        out.add(mapped);
      } else {
        out.addAll(lifted);
      }
    }
    return out ?? runs;
  }

  /// [run] with this palette's colours for the parser's.
  AnsiRun _mapped(AnsiRun run) {
    final bg = run.bg == null ? null : mapped(run.bg!);
    var fg = run.fg == null ? null : mapped(run.fg!);
    if (bg != null && fg == null) {
      fg = bg.computeLuminance() < 0.35 ? TerminalColors.foreground : foreground;
    }
    if (fg == run.fg && bg == run.bg) return run;
    return AnsiRun(
      run.text,
      fg: fg,
      bg: bg,
      bold: run.bold,
      dim: run.dim,
      italic: run.italic,
      underline: run.underline,
      strike: run.strike,
    );
  }

  /// The pieces [run] falls into when its text does not read, else null.
  List<AnsiRun>? _lift(AnsiRun run) {
    // The default on the default is the palette's own pairing; it reads.
    if (run.fg == null && run.bg == null && !run.dim) return null;
    final colour = TerminalContrast.lifted(
      (run.fg ?? foreground).toARGB32(),
      (run.bg ?? background).toARGB32(),
      run.dim,
    );
    return colour == null ? null : TerminalContrast.apply(run, colour);
  }
}
