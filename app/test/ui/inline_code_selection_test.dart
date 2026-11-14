import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/render/markdown/md_styles.dart';

/// The selection highlight is painted under the text, so a span's background
/// that is opaque hides it: selected inline code used to show as holes in the
/// highlight of a message. The chip behind inline code must let it through.
void main() {
  testWidgets('selecting text selects the inline code too: its chip does not hide the highlight', (tester) async {
    final key = GlobalKey();
    late TextStyle chip;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) {
            // Only the chip's colour, at a size the sample below can hit: the
            // test font is a solid square per character.
            chip = TextStyle(
              fontSize: 40,
              backgroundColor: MdStyles.of(context).inlineCode(const TextStyle()).backgroundColor,
            );
            return RepaintBoundary(
              key: key,
              child: Material(
                color: Ds.paper.surface,
                child: SelectionArea(
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: 40, color: Colors.black),
                      children: [
                        const TextSpan(text: 'ab '),
                        TextSpan(text: 'a      b', style: chip),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    tester.state<SelectableRegionState>(find.byType(SelectableRegion)).selectAll(SelectionChangedCause.toolbar);
    await tester.pump();

    late Color inChip;
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: find.byType(SelectionArea), matching: find.byType(RichText)).first,
      );
      // The middle of the blanks inside the chip ('ab ' is 3 characters, then
      // 'a', six spaces and 'b'): no glyph is drawn there, whatever the font.
      final box = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 5, extentOffset: 8)).first.toRect();
      final at = paragraph.localToGlobal(box.center) - boundary.localToGlobal(Offset.zero);
      final i = ((at.dy.round() * image.width) + at.dx.round()) * 4;
      inChip = Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2));
    });
    // The page is near-white and the chip a faint grey: a highlighted pixel is
    // far more blue than red.
    expect(inChip.b - inChip.r, greaterThan(0.1), reason: 'the highlight shows through the chip: $inChip');
  });
}
