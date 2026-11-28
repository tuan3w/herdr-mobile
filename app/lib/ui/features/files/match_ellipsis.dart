import 'package:flutter/material.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'middle_ellipsis.dart';

/// Where [query] sits in [name], as UTF-16 offsets, or null when it does not.
///
/// The same question the machine asked: a case-insensitive part of the NAME
/// (`file_walk_search.dart`, `svc/search.rs`: lower-case both, `contains`; accents
/// are NOT folded, `bao` does not find `báo`). The first occurrence wins. The
/// span covers whole characters, so a mark never splits `ỉ` written as `i` plus
/// a combining accent.
({int start, int end})? matchSpan(String name, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return null;
  // Lower-casing can change a name's length (`İ` becomes two units), and then the
  // offsets of the lower-cased copy are not the name's. Lower-case one character
  // at a time and remember where each piece came from.
  final lowered = StringBuffer();
  final origin = <int>[]; // lowered offset -> start of the character it came from
  final ends = <int>[]; // lowered offset -> end of that character
  for (final ch in name.characters) {
    final start = origin.isEmpty ? 0 : ends.last;
    final piece = ch.toLowerCase();
    for (var i = 0; i < piece.length; i++) {
      origin.add(start);
      ends.add(start + ch.length);
    }
    lowered.write(piece);
  }
  final at = lowered.toString().indexOf(needle);
  if (at >= 0) return (start: origin[at], end: ends[at + needle.length - 1]);
  // Context-sensitive lower-casing (a Greek final sigma) differs between the
  // whole name and its pieces: ask the way the machine does.
  final whole = name.toLowerCase();
  final found = whole.length == name.length ? whole.indexOf(needle) : -1;
  return found < 0 ? null : _snap(name, found, found + needle.length);
}

/// [start]..[end] moved outwards to character boundaries of [name].
({int start, int end}) _snap(String name, int start, int end) {
  var pos = 0;
  var s = start, e = end;
  for (final ch in name.characters) {
    final next = pos + ch.length;
    if (start >= pos && start < next) s = pos;
    if (end > pos && end <= next) e = next;
    pos = next;
  }
  return (start: s, end: e);
}

/// A name cut to fit with its match kept: [lead] and [trail] are plain text
/// (with their `…`), [match] is the part to mark.
class MatchedName {
  const MatchedName(this.lead, this.match, this.trail);

  final String lead;
  final String match;
  final String trail;

  String get text => '$lead$match$trail';

  @override
  bool operator ==(Object other) =>
      other is MatchedName && other.lead == lead && other.match == match && other.trail == trail;

  @override
  int get hashCode => Object.hash(lead, match, trail);

  @override
  String toString() => 'MatchedName($lead|$match|$trail)';
}

/// [name] cut to fit [maxWidth] on [maxLines] lines in [style], keeping the span
/// [span] whole and in view, which [middleEllipsize] does not know about.
///
/// Whole when it fits. Otherwise what stays, in the order it is given up last
/// to first: the match; the extension (as [tailLength] counts it, kept from the
/// end of what follows the match); then the characters next to the match, the
/// start of the name and the characters after the match, shared round and round,
/// each side cut in its own middle. `payment_service_integration_report_final_test.dart`
/// becomes `payment_…ion_report_fin…test.dart`. When the match alone is wider than
/// the room, its start stays (`repo…`): the person typed the rest.
MatchedName fitAroundMatch(
  String name,
  ({int start, int end}) span,
  double maxWidth,
  TextStyle style,
  TextScaler scaler, {
  int maxLines = 1,
}) {
  final pre = name.substring(0, span.start).characters.toList();
  final mid = name.substring(span.start, span.end).characters.toList();
  final post = name.substring(span.end).characters.toList();
  final whole = MatchedName(pre.join(), mid.join(), post.join());
  final painter = TextPainter(textDirection: TextDirection.ltr, textScaler: scaler, maxLines: maxLines);
  bool fits(MatchedName m) {
    painter
      ..text = TextSpan(
        style: style,
        children: [
          TextSpan(text: m.lead),
          TextSpan(text: m.match),
          TextSpan(text: m.trail),
        ],
      )
      ..layout(maxWidth: maxLines == 1 ? double.infinity : maxWidth);
    return maxLines == 1 ? painter.width <= maxWidth : !painter.didExceedMaxLines;
  }

  try {
    if (!maxWidth.isFinite || fits(whole)) return whole;

    MatchedName build(int tail, int budget) {
      // Share [budget] characters: next to the match before it, after it, then
      // the start of the name, in turn, while each has any left.
      final room = post.length - tail;
      var near = 0, after = 0, head = 0, i = 0;
      for (var left = budget; left > 0; i++) {
        if (near + head >= pre.length && after >= room) break;
        switch (i % 3) {
          case 0 when near + head < pre.length:
            near++;
            left--;
          case 1 when after < room:
            after++;
            left--;
          case 2 when near + head < pre.length:
            head++;
            left--;
        }
      }
      final String lead = near + head >= pre.length
          ? pre.join()
          : '${pre.take(head).join()}…${pre.skip(pre.length - near).join()}';
      final String trail = after + tail >= post.length
          ? post.join()
          : '${post.take(after).join()}…${post.skip(post.length - tail).join()}';
      return MatchedName(lead, mid.join(), trail);
    }

    final keep = tailLength(post);
    for (var tail = keep; tail >= 0; tail = tail > 4 ? tail - 2 : tail - 1) {
      if (!fits(build(tail, 0))) continue;
      var lo = 0, hi = pre.length + post.length - tail;
      while (lo < hi) {
        final m = (lo + hi + 1) >> 1;
        if (fits(build(tail, m))) {
          lo = m;
        } else {
          hi = m - 1;
        }
      }
      return build(tail, lo);
    }
    // The match alone is too wide: its start, then an ellipsis.
    var lo = 1, hi = mid.length;
    MatchedName cut(int n) => MatchedName('', '${mid.take(n).join()}…', '');
    while (lo < hi) {
      final m = (lo + hi + 1) >> 1;
      if (fits(cut(m))) {
        lo = m;
      } else {
        hi = m - 1;
      }
    }
    return cut(lo);
  } finally {
    painter.dispose();
  }
}

/// A file name for a search result: whole when it fits, otherwise cut around the
/// part that matched, which is marked with a quiet wash. Two lines when the
/// person reads at a large text size, where one line holds a dozen characters.
/// Screen readers get the whole name.
class MatchedNameText extends StatelessWidget {
  const MatchedNameText(this.text, {super.key, required this.span, required this.style});

  final String text;
  final ({int start, int end}) span;
  final TextStyle style;

  /// From this text scale a name may take a second line.
  static const largeText = 1.3;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final lines = scaler.scale(10) >= 10 * largeText ? 2 : 1;
    final wash = context.ds.selection;
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) {
          final m = fitAroundMatch(text, span, box.maxWidth, style, scaler, maxLines: lines);
          return Text.rich(
            TextSpan(
              children: [
                TextSpan(text: m.lead),
                TextSpan(
                  text: m.match,
                  style: style.copyWith(backgroundColor: wash),
                ),
                TextSpan(text: m.trail),
              ],
            ),
            maxLines: lines,
            softWrap: lines > 1,
            overflow: TextOverflow.clip,
            style: style,
          );
        },
      ),
    );
  }
}
