/// Mermaid source in, a laid-out scene or the reason it was not drawn out.
///
/// Pure Dart (no `dart:ui`, no Flutter): it runs in an isolate
/// ([layoutMermaidOffThread]) and the corpus bench (`tool/mermaid-bench`)
/// imports it. The engine is `mermaid_core`; nothing outside
/// `ui/render/mermaid/` may import it.
library;

import 'dart:isolate';
import 'dart:math' as math;

import 'package:mermaid_core/mermaid_core.dart' as core;

import 'inter_text_measurer.dart';
import 'mermaid_source.dart';

/// The diagram kinds v1 draws. Others stay the code block, with the reason.
enum MermaidKind {
  flowchart('Flowchart'),
  sequence('Sequence diagram'),
  state('State diagram'),
  er('ER diagram'),
  classDiagram('Class diagram');

  const MermaidKind(this.label);

  /// What the header says.
  final String label;
}

/// A source longer than this is not laid out: a diagram this size is a
/// generated dump, and its layout would hold an isolate for seconds.
const mermaidMaxSource = 12000;

/// What a diagram is laid out with. A phone is 328 dp of content wide, so type
/// is 13 dp, spacing is tight and labels wrap at 130 (flowchart) or 88
/// (sequence actors); the screen's width is not an input, so one layout serves
/// every window it is drawn in. The author's own `%%{init}%%` or frontmatter
/// replaces this.
const _phoneProfile =
    '%%{init: {"flowchart":{"padding":8,"nodeSpacing":20,"rankSpacing":28,"wrappingWidth":130},'
    '"sequence":{"actorMargin":16,"width":88,"height":32,"boxMargin":6,"messageMargin":22,"wrap":true,"noteMargin":6}}}%%\n';

/// A turned (top-down) flowchart replaces the author's direction only when the
/// diagram as written is wider than a phone's content column (328 dp) and the
/// turned one is clearly narrower: a chain of two nodes that already fits is
/// left as the author drew it.
const _phoneColumn = 328.0;
const _turnedIfNarrowerThan = 0.9;

/// Everything one layout needs; plain data, so it crosses into an isolate.
final class MermaidJob {
  const MermaidJob({required this.source, required this.theme, required this.darkText, required this.lightText});

  /// The diagram as the author wrote it.
  final String source;

  final core.MermaidTheme theme;

  /// The two text colours a label falls back to when the theme's colour does
  /// not read on the node's fill (authors set pastel fills): the one for
  /// light fills and the one for dark fills.
  final core.Color darkText;
  final core.Color lightText;
}

sealed class MermaidResult {
  const MermaidResult();
}

final class MermaidDrawn extends MermaidResult {
  const MermaidDrawn({required this.kind, required this.scene, required this.turned, required this.labels});

  final MermaidKind kind;
  final core.RenderScene scene;

  /// A left-to-right flowchart drawn top-down because that is narrower.
  final bool turned;

  /// The label of every node in scene order, for a screen reader.
  final List<String> labels;
}

final class MermaidFailed extends MermaidResult {
  const MermaidFailed(this.reason);

  /// The sentence shown under the source.
  final String reason;
}

/// Lays [job] out in an isolate, so a large diagram never costs a frame.
Future<MermaidResult> layoutMermaidOffThread(MermaidJob job) => Isolate.run(() => layoutMermaid(job));

/// Lays [job] out on the calling isolate.
MermaidResult layoutMermaid(MermaidJob job) {
  final source = normalizeMermaid(job.source);
  if (source.trim().isEmpty) return const MermaidFailed('Nothing to draw');
  if (source.length > mermaidMaxSource) return const MermaidFailed('Too large to draw here · showing the source');

  final type = core.detectDiagramType(source);
  final kind = switch (type) {
    core.DiagramType.flowchart => MermaidKind.flowchart,
    core.DiagramType.sequence => MermaidKind.sequence,
    core.DiagramType.stateDiagram => MermaidKind.state,
    core.DiagramType.er => MermaidKind.er,
    core.DiagramType.classDiagram => MermaidKind.classDiagram,
    _ => null,
  };
  if (kind == null) {
    if (type == core.DiagramType.unknown) {
      return const MermaidFailed('Couldn’t tell which kind of diagram this is · showing the source');
    }
    return MermaidFailed('Can’t draw ${_unsupportedName(type)} diagrams yet · showing the source');
  }

  final trimmed = source.trimLeft();
  final profiled = !trimmed.startsWith('---') && !source.contains('%%{');
  final engine = core.Mermaid(measurer: const InterTextMeasurer(), theme: job.theme);
  try {
    var scene = engine.render(profiled ? _phoneProfile + source : source);
    var turned = false;
    if (kind == MermaidKind.flowchart) {
      final down = scene.size.width > _phoneColumn ? _topDown(source) : null;
      if (down != null) {
        final alt = engine.render(profiled ? _phoneProfile + down : down);
        if (alt.size.width < scene.size.width * _turnedIfNarrowerThan) {
          scene = alt;
          turned = true;
        }
      }
    }
    scene = ensureReadable(
      scene,
      dark: job.darkText,
      light: job.lightText,
      family: job.theme.fontFamily,
      surface: job.theme.edgeLabelBackground,
    );
    return MermaidDrawn(kind: kind, scene: scene, turned: turned, labels: [for (final l in _labels(scene.nodes)) l]);
  } on core.MermaidParseException catch (e) {
    final line = e.line;
    if (line == null) return const MermaidFailed('Couldn’t draw this diagram · showing the source');
    return MermaidFailed(
      'Couldn’t draw this diagram · line ${_sourceLine(source, profiled, line)} · showing the source',
    );
  } catch (_) {
    return const MermaidFailed('Couldn’t draw this diagram · showing the source');
  }
}

/// The line of [source] the engine means by its [line]. The engine counts the
/// lines left after it strips frontmatter, directives, comments and blank
/// lines (`stripMetadata`), and that is not what the person sees: the lines
/// are matched back one by one, in order. [profiled]: the engine saw the phone
/// profile line in front, which is not in the person's source.
int _sourceLine(String source, bool profiled, int line) {
  final seen = core.stripMetadata(profiled ? _phoneProfile + source : source).split('\n');
  if (line < 1 || line > seen.length) return line;
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  var at = 0;
  for (var i = 0; i < line; i++) {
    while (at < lines.length && lines[at] != seen[i]) {
      at++;
    }
    if (at >= lines.length) return line;
    if (i < line - 1) at++;
  }
  return at + 1;
}

String _unsupportedName(core.DiagramType type) => switch (type) {
  core.DiagramType.gantt => 'gantt chart',
  core.DiagramType.pie => 'pie chart',
  core.DiagramType.mindmap => 'mindmap',
  core.DiagramType.timeline => 'timeline',
  core.DiagramType.gitGraph => 'git graph',
  core.DiagramType.quadrant => 'quadrant chart',
  core.DiagramType.xychart => 'XY chart',
  core.DiagramType.journey => 'user journey',
  core.DiagramType.c4 => 'C4',
  _ => type.name.toLowerCase(),
};

final _header = RegExp(r'^(\s*(?:flowchart|graph)\s+)(LR|RL)\b', multiLine: true);

/// [source] with a left-to-right flowchart turned top-down; null when it is
/// not left-to-right.
String? _topDown(String source) {
  final m = _header.firstMatch(source);
  if (m == null) return null;
  return source.replaceRange(m.start, m.end, '${m[1]}TB');
}

Iterable<String> _labels(List<core.SceneNode> nodes) sync* {
  for (final n in nodes) {
    if (n is! core.SceneGroup) continue;
    final label = n.semanticLabel;
    if (n.role == core.SceneGroupRole.node && label != null && label.isNotEmpty) yield label;
    yield* _labels(n.children);
  }
}

/// WCAG 2 relative luminance.
double _luminance(core.Color c) {
  double channel(int v) {
    final s = v / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue);
}

/// WCAG 2 contrast ratio of two colours.
double contrastRatio(core.Color a, core.Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The engine's hard-coded fills that are not the theme's: the ER
/// relationship label's pale green box and the white of a cardinality ring.
/// On the ink theme both are bright holes in the diagram.
// design-lint: allow(raw-color) the engine's own hard-coded constant, matched so it can be replaced
final _erLabelBox = const core.Color(0xfff9ffec).withOpacity(0.7).value;
const _white = 0xFFFFFFFF;

/// Puts a scene in the app's hands:
///
///  * text that does not read on the fill it sits on (4.5:1) gets whichever of
///    [dark] and [light] reads better. The theme's text colour is right for the
///    theme's fills; an author's `style X fill:#e1f5fe` is not the theme's.
///  * every label is in [family]: the engine hard-codes a Trebuchet stack on
///    some labels (ER relationships), which the phone does not have and would
///    draw in its default font, a different width from the one measured.
///  * the engine's own white and pale-green fills become [surface].
core.RenderScene ensureReadable(
  core.RenderScene scene, {
  required core.Color dark,
  required core.Color light,
  required String family,
  required core.Color surface,
}) {
  var changed = false;
  void mark() => changed = true;

  core.SceneNode one(core.SceneNode n) {
    switch (n) {
      case core.SceneGroup():
        return _group(n, one, dark, light, mark);
      case core.SceneText() when n.style.fontFamily != family:
        mark();
        return n.copyWith(style: n.style.copyWith(fontFamily: family));
      case core.SceneShape(:final fill?)
          when fill.gradient == null && (fill.color.value == _white || fill.color.value == _erLabelBox):
        mark();
        return n.copyWith(fill: core.Fill(surface));
      default:
        return n;
    }
  }

  final nodes = [for (final n in scene.nodes) one(n)];
  return changed ? core.RenderScene(size: scene.size, nodes: nodes, background: scene.background) : scene;
}

core.SceneGroup _group(
  core.SceneGroup g,
  core.SceneNode Function(core.SceneNode) one,
  core.Color dark,
  core.Color light,
  void Function() mark,
) {
  final kids = [for (final c in g.children) one(c)];
  core.Color? fill;
  for (final c in kids) {
    if (c is core.SceneShape && c.fill != null && c.fill!.color.alpha >= 0x80) {
      fill = c.fill!.color;
      break;
    }
  }
  final children = <core.SceneNode>[];
  for (final c in kids) {
    if (fill != null && c is core.SceneText && contrastRatio(c.color, fill) < 4.5) {
      final better = contrastRatio(dark, fill) >= contrastRatio(light, fill) ? dark : light;
      if (better.value != c.color.value) {
        mark();
        children.add(c.copyWith(color: better));
        continue;
      }
    }
    children.add(c);
  }
  return core.SceneGroup(
    children: children,
    id: g.id,
    role: g.role,
    semanticLabel: g.semanticLabel,
    link: g.link,
    tooltip: g.tooltip,
    edge: g.edge,
  );
}
