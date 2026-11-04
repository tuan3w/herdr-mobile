import 'package:flutter/painting.dart' show Color;
import 'package:mermaid_core/mermaid_core.dart' as core;

import 'package:herdr_mobile/ui/core/kit.dart';

core.Color _c(Color c) => core.Color(c.toARGB32());

/// A diagram's type size in dp. The layout is built for it (labels wrap at 130
/// at this size) and the view never draws it below 80%: 10.4 dp.
const mermaidFontSize = 13.0;

/// The app's colours as a Mermaid theme: quiet fills, hairline borders, text in
/// the text colour, and the one tint (`working`) on a sequence diagram's notes.
/// The categorical palettes of the types the app does not draw (pie, gantt,
/// git, ...) keep the engine's; they are not shown.
///
/// A diagram sits on [Ds.surface]; the scene itself paints no background.
core.MermaidTheme mermaidThemeOf(Ds ds) {
  final cluster = Color.lerp(ds.surface, ds.fill, 0.5)!;
  final note = Color.lerp(ds.surface, ds.working, ds.isDark ? 0.16 : 0.14)!;
  return core.MermaidTheme(
    background: core.Color.transparent,
    primaryColor: _c(ds.fill),
    primaryTextColor: _c(ds.text),
    primaryBorderColor: _c(ds.border),
    secondaryColor: _c(ds.fill),
    lineColor: _c(ds.textTertiary),
    arrowheadColor: _c(ds.textTertiary),
    textColor: _c(ds.text),
    nodeBorder: _c(ds.border),
    mainBkg: _c(ds.fill),
    clusterBkg: _c(cluster),
    clusterBorder: _c(ds.border),
    titleColor: _c(ds.textSecondary),
    edgeLabelBackground: _c(ds.surface),
    // Keep measured Latin metrics; Japanese labels use the bundled JP face.
    fontFamily: 'Inter, ${Type.family}',
    // design-lint: allow(raw-type) the engine's own size field, in the layout's units, not a TextStyle
    fontSize: mermaidFontSize,
    actorBkg: _c(ds.fill),
    actorBorder: _c(ds.border),
    actorTextColor: _c(ds.text),
    actorLineColor: _c(ds.border),
    signalColor: _c(ds.textSecondary),
    signalTextColor: _c(ds.text),
    labelBoxBkgColor: _c(ds.fill),
    labelBoxBorderColor: _c(ds.border),
    labelTextColor: _c(ds.textSecondary),
    loopTextColor: _c(ds.textSecondary),
    noteBkgColor: _c(note),
    noteBorderColor: _c(ds.working),
    noteTextColor: _c(ds.text),
    activationBkgColor: _c(ds.fillPressed),
    activationBorderColor: _c(ds.border),
    attributeBackgroundColorOdd: _c(ds.surface),
    attributeBackgroundColorEven: _c(ds.fill),
    rowOdd: _c(ds.surface),
    rowEven: _c(ds.fill),
    relationColor: _c(ds.textSecondary),
    relationLabelBackground: _c(ds.surface),
    relationLabelColor: _c(ds.text),
  );
}

/// The two text colours a label falls back to when the theme's does not read
/// on a fill an author chose: the paper theme's text for light fills, the ink
/// theme's for dark ones.
core.Color get mermaidDarkText => _c(Ds.paper.text);
core.Color get mermaidLightText => _c(Ds.ink.text);
