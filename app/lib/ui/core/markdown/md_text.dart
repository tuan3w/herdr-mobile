import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../cell_width.dart';
import '../terminal_links.dart';
import '../../features/agent_session/visible_text.dart';
import 'md_actions.dart';
import 'md_document.dart';
import 'md_styles.dart';

/// Whether the first strong character of [text] is right-to-left (Hebrew,
/// Arabic, Syriac, Thaana...). Looks at the first 200 units only; digits,
/// punctuation, emoji and spaces are neutral. A paragraph that opens in an RTL
/// script is laid out right to left (and aligned to the right with it).
bool mdIsRtl(String text) {
  final n = text.length < 200 ? text.length : 200;
  for (var i = 0; i < n; i++) {
    final c = text.codeUnitAt(i);
    if (c < 0x80) {
      if ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x7a) return false;
      continue;
    }
    if ((c >= 0x0590 && c <= 0x08FF) || (c >= 0xFB1D && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF)) {
      // Arabic-Indic digits and a few marks are weak, not strong.
      if (c >= 0x0660 && c <= 0x066C) continue;
      return true;
    }
    // Latin-1 letters and everything alphabetic outside punctuation, symbols
    // and surrogates (emoji) count as left-to-right.
    if (c >= 0xC0 && c < 0x2000 || c >= 0x2C00 && c < 0xD800) return false;
  }
  return false;
}

/// [text] without the characters that reorder what follows them (the bidi
/// embeddings, overrides and isolates, U+202A-202E and U+2066-2069): in prose
/// they can only mislead. The right-to-left and left-to-right MARKS stay, real
/// RTL text needs them. A lone UTF-16 surrogate becomes U+FFFD: Flutter's
/// paragraph builder throws on one, and a row whose layout throws is left
/// undrawn. Returns [text] itself when it holds none of these.
String proseText(String text) {
  var at = -1;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (_bidiControl(c) || _lone(text, i, c)) {
      at = i;
      break;
    }
  }
  if (at < 0) return text;
  final b = StringBuffer(text.substring(0, at));
  for (var i = at; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (_bidiControl(c)) continue;
    b.writeCharCode(_lone(text, i, c) ? 0xFFFD : c);
  }
  return b.toString();
}

bool _bidiControl(int c) => (c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069);

/// Whether the code unit [c] at [i] is half of a surrogate pair whose other
/// half is missing.
bool _lone(String s, int i, int c) {
  if (c >= 0xD800 && c <= 0xDBFF) return i + 1 >= s.length || (s.codeUnitAt(i + 1) & 0xFC00) != 0xDC00;
  return c >= 0xDC00 && c <= 0xDFFF && (i == 0 || (s.codeUnitAt(i - 1) & 0xFC00) != 0xD800);
}

/// What a link destination is, for the renderer.
enum MdLinkKind {
  /// `http`/`https` with a host: opens the link sheet.
  web,

  /// A file path (no scheme, or `file:`): opens the file viewer.
  path,

  /// `#anchor`, `mailto:`, `javascript:`, anything else: shown as plain text.
  none,
}

/// A path target and the line it names.
typedef MdPathTarget = ({String path, int? line});

/// Classifies the destination of a Markdown link or image.
(MdLinkKind, MdPathTarget?) classifyLink(String url) {
  final u = url.trim();
  if (u.isEmpty || u.startsWith('#')) return (MdLinkKind.none, null);
  final lower = u.length > 8 ? u.substring(0, 8).toLowerCase() : u.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    final host = Uri.tryParse(u)?.host ?? '';
    return host.isEmpty ? (MdLinkKind.none, null) : (MdLinkKind.web, null);
  }
  // `scheme:` (but not `C:\` or `lib/a.dart:42`, which have no `//` and a path
  // character before the colon): any other scheme is refused.
  final colon = u.indexOf(':');
  var rest = u;
  if (lower.startsWith('file://')) {
    rest = u.substring(7);
  } else if (colon > 0 && RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:(?![0-9])').hasMatch(u)) {
    return (MdLinkKind.none, null);
  }
  if (rest.startsWith('//') || rest.isEmpty) return (MdLinkKind.none, null);
  var line = RegExp(r'#L(\d+)(?:C\d+)?(?:-L?\d+(?:C\d+)?)?$').firstMatch(rest);
  var path = rest;
  int? at;
  if (line != null) {
    at = int.tryParse(line.group(1)!);
    path = rest.substring(0, line.start);
  } else {
    // A query or a fragment is not part of a file name.
    final q = path.indexOf(RegExp(r'[?#]'));
    if (q >= 0) path = path.substring(0, q);
  }
  // `[/model](/model)`: a slash command is a word of the agent's, not a file.
  if (path.isEmpty || looksLikeSlashCommand(path)) return (MdLinkKind.none, null);
  return (MdLinkKind.path, (path: path, line: at));
}

/// UTF-16 offsets for the cell columns of [links] (sorted by start): a link's
/// `start`/`end` are terminal cell columns.
List<(int, int)> _unitRanges(String text, List<TerminalLink> links) {
  final out = <(int, int)>[];
  var unit = 0;
  var column = 0;
  int advanceTo(int target) {
    while (column < target && unit < text.length) {
      var rune = text.codeUnitAt(unit++);
      if (rune >= 0xD800 && rune <= 0xDBFF && unit < text.length) {
        final trail = text.codeUnitAt(unit);
        if (trail >= 0xDC00 && trail <= 0xDFFF) {
          rune = 0x10000 + ((rune - 0xD800) << 10) + (trail - 0xDC00);
          unit++;
        }
      }
      column += cellWidth(rune);
    }
    return unit;
  }

  for (final l in links) {
    final s = advanceTo(l.start);
    final e = advanceTo(l.end);
    out.add((s, e));
  }
  return out;
}

/// Inline Markdown: one [Text.rich] whose spans carry the styles, the links
/// and the tappable paths of an [MdInlines].
///
/// Being a `RenderParagraph`, it gets selection (under a `SelectionArea`) and
/// semantics for free: the text is the paragraph's label and every tappable
/// span is a tappable node. Owns the tap recognizers of its spans, so it is
/// stateful; the spans are built again only when the inlines, the style, the
/// theme or the handlers change.
class MdInlineText extends StatefulWidget {
  const MdInlineText({super.key, required this.inlines, required this.style, this.textAlign});

  final MdInlines inlines;

  /// The text style of the block (body or heading).
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  State<MdInlineText> createState() => _MdInlineTextState();
}

class _MdInlineTextState extends State<MdInlineText> {
  final _recognizers = <TapGestureRecognizer>[];

  TextSpan? _span;
  MdInlines? _builtFrom;
  TextStyle? _builtStyle;
  Object? _builtTone;
  Object? _builtDs;
  MdLinkHandler? _builtOnLink;
  MdPathHandler? _builtOnPath;
  bool _rtl = false;

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final styles = MdStyles.of(context);
    final actions = MdActions.maybeOf(context);
    final w = widget;
    if (_span == null ||
        !identical(_builtFrom, w.inlines) ||
        _builtStyle != w.style ||
        _builtTone != styles.tone ||
        !identical(_builtDs, styles.ds) ||
        _builtOnLink != actions?.onLink ||
        _builtOnPath != actions?.onPath) {
      _clear();
      _span = _build(context, styles, actions);
      _rtl = mdIsRtl(w.inlines.text);
      _builtFrom = w.inlines;
      _builtStyle = w.style;
      _builtTone = styles.tone;
      _builtDs = styles.ds;
      _builtOnLink = actions?.onLink;
      _builtOnPath = actions?.onPath;
    }
    return Text.rich(
      _span!,
      style: w.style,
      textDirection: _rtl ? TextDirection.rtl : null,
      textAlign: w.textAlign,
    );
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(r);
    return r;
  }

  TextSpan _build(BuildContext context, MdStyles styles, MdActions? actions) {
    final base = widget.style;
    final onLink = actions?.onLink;
    final onPath = actions?.onPath;
    final out = <InlineSpan>[];

    TextStyle compose(MdStyle bits, {required bool link}) {
      var t = bits.has(MdStyle.code) ? styles.inlineCode(base) : const TextStyle();
      if (bits.has(MdStyle.bold)) t = t.copyWith(fontWeight: FontWeight.w700);
      if (bits.has(MdStyle.italic)) t = t.copyWith(fontStyle: FontStyle.italic);
      final strike = bits.has(MdStyle.strike);
      if (link) {
        final l = styles.link;
        // Inline code already sits on its own badge: the accent says it can be
        // tapped, an underline on top of the fill is one mark too many.
        final underline = !bits.has(MdStyle.code);
        t = t.copyWith(
          color: l.color,
          decoration: strike
              ? TextDecoration.combine([if (underline) TextDecoration.underline, TextDecoration.lineThrough])
              : underline
              ? l.decoration
              : TextDecoration.none,
          decorationColor: l.decorationColor,
        );
      } else if (strike) {
        t = t.copyWith(decoration: TextDecoration.lineThrough);
      }
      return t;
    }

    void pathTap(MdPathTarget p) => onPath!(context, p.path, p.line);

    for (final item in widget.inlines.items) {
      switch (item) {
        case MdBreak():
          out.add(const TextSpan(text: '\n'));
        case MdImage():
          out.add(_image(context, item, styles, onLink, onPath));
        case MdSpan():
          final bits = item.style;
          final isCode = bits.has(MdStyle.code);
          final text = isCode ? visibleText(item.text) : proseText(item.text);
          final link = item.link;
          if (link != null) {
            // A link: the label is the text, the target decides what a tap does.
            final (kind, path) = link.isEmpty ? (MdLinkKind.none, null) : classifyLink(link);
            final tap = switch (kind) {
              MdLinkKind.web when onLink != null => _tap(() => onLink(context, hasHiddenCharacters(link) ? visibleText(link) : link)),
              MdLinkKind.path when onPath != null => _tap(() => pathTap(path!)),
              _ => null,
            };
            // `[x]()` and a label whose address is still arriving read as a
            // link that cannot be followed yet; an anchor, a `mailto:` or a
            // script address is not offered at all.
            final styled = link.isEmpty || kind != MdLinkKind.none;
            out.add(TextSpan(text: text, style: compose(bits, link: styled), recognizer: tap));
            continue;
          }
          if (onPath == null || text.length < 3) {
            out.add(TextSpan(text: text, style: compose(bits, link: false)));
            continue;
          }
          final found = _paths(text);
          if (found.isEmpty) {
            out.add(TextSpan(text: text, style: compose(bits, link: false)));
            continue;
          }
          if (isCode) {
            // Inline code is a path when it is nothing but one.
            final (s, e) = found.first.$1;
            if (found.length == 1 && text.substring(0, s).trim().isEmpty && text.substring(e).trim().isEmpty) {
              final target = found.first.$2;
              out.add(TextSpan(text: text, style: compose(bits, link: true), recognizer: _tap(() => pathTap(target))));
            } else {
              out.add(TextSpan(text: text, style: compose(bits, link: false)));
            }
            continue;
          }
          var at = 0;
          for (final ((s, e), target) in found) {
            if (s > at) out.add(TextSpan(text: text.substring(at, s), style: compose(bits, link: false)));
            out.add(TextSpan(text: text.substring(s, e), style: compose(bits, link: true), recognizer: _tap(() => pathTap(target))));
            at = e;
          }
          if (at < text.length) out.add(TextSpan(text: text.substring(at), style: compose(bits, link: false)));
      }
    }
    return TextSpan(children: out);
  }

  /// The path links of [text], as (UTF-16 range, target).
  List<((int, int), MdPathTarget)> _paths(String text) {
    final links = detectLinks(text).where((l) => l.kind == TerminalLinkKind.path).toList();
    if (links.isEmpty) return const [];
    final ranges = _unitRanges(text, links);
    return [
      for (var i = 0; i < links.length; i++) (ranges[i], (path: links[i].target, line: links[i].line)),
    ];
  }

  /// `Image: alt · host`: a quiet chip. Nothing is fetched; a tap shows the
  /// address (web) or opens the file (a path on the machine).
  InlineSpan _image(BuildContext context, MdImage image, MdStyles styles, MdLinkHandler? onLink, MdPathHandler? onPath) {
    final (kind, path) = classifyLink(image.src);
    final host = kind == MdLinkKind.web ? Uri.tryParse(image.src.trim())?.host ?? '' : '';
    final alt = proseText(image.alt).trim();
    final label = StringBuffer('\u00A0Image');
    if (alt.isNotEmpty) label.write(': $alt');
    if (host.isNotEmpty) label.write(' · $host');
    label.write('\u00A0');
    final recognizer = switch (kind) {
      MdLinkKind.web when onLink != null =>
        _tap(() => onLink(context, hasHiddenCharacters(image.src) ? visibleText(image.src.trim()) : image.src.trim())),
      MdLinkKind.path when onPath != null => _tap(() => onPath(context, path!.path, path.line)),
      _ => null,
    };
    return TextSpan(text: label.toString(), style: styles.imageChip, recognizer: recognizer);
  }
}
