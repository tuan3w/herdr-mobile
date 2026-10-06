import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';

/// The paragraph showing one terminal row whose text is exactly [text]
/// (box drawing shows as spaces, see `blankSprites`).
Finder terminalRow(String text) => find.byWidgetPredicate(
  (w) => w is TerminalLineView && w.text.toPlainText() == text,
  description: 'terminal row "$text"',
);

/// Terminal rows whose text contains [text].
Finder terminalRowContaining(String text) => find.byWidgetPredicate(
  (w) => w is TerminalLineView && w.text.toPlainText().contains(text),
  description: 'terminal row containing "$text"',
);

/// The row's own span: one child per run of identical style. The same object
/// for as long as the row is unchanged.
TextSpan rowSpan(Widget row) =>
    (row as TerminalLineView).text.children!.single as TextSpan;
