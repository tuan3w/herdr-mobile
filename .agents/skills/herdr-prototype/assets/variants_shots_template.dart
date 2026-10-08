// THROWAWAY PROTOTYPE for a design discussion, not product code. Copy this file
// to app/test/ui/<topic>_variants_shots_test.dart, rename TOPIC, replace the
// data and the variants, and delete the file once a direction is chosen.
//
// It draws one screen with the same data several ways, from real ui/core
// parts. Mark every field the real app may not be able to supply as INVENTED
// here and in the report: _Row.ask below is the example.
//
//   TOPIC_VARIANTS=1 flutter test test/ui/<topic>_variants_shots_test.dart
//
// Output: $TOPIC_VARIANTS_DIR (default /tmp/topic_variants)/<variant>-<light|dark>.png
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/glyphs.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/core/tokens.dart';

import '../support/shot.dart';

/// One row of data. [shown] is what the app shows today; [ask] is INVENTED.
typedef _Row = ({AgentStatus status, String shown, String ask, String where, String time});

const _data = <_Row>[
  (status: AgentStatus.working, shown: 'Claude Code', ask: 'Refactor the settings page into tabs', where: 'claude · studio-mac · web-app', time: 'working 18m'),
  (status: AgentStatus.idle, shown: 'Claude Code', ask: 'Fix the Hà Nội locale bug', where: 'claude · studio-mac · payments-api', time: 'idle 12m'),
  (status: AgentStatus.idle, shown: 'Claude Code', ask: 'Add regression tests for currency rounding', where: 'claude · studio-mac · payments-api', time: 'idle 47m'),
];

Widget _row(BuildContext c, _Row r, {required String title, bool divider = true}) => ListRow(
      leading: StatusGlyph(status: r.status, size: 20),
      title: title,
      subtitle: r.where,
      divider: divider,
      trailing: Text(
        r.time,
        maxLines: 1,
        softWrap: false,
        style: Type.caption.copyWith(color: c.ds.textMuted, fontFeatures: Type.tabular),
      ),
    );

/// Every variant gets the same title bar and the same data; only the list differs.
class _Page extends StatelessWidget {
  const _Page({required this.children});

  final List<Widget> Function(BuildContext) children;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: CustomScrollView(
          slivers: [
            const SliverLargeTitle(title: 'Agents'),
            SliverList(delegate: SliverChildListDelegate(children(context))),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      );
}

// 0. The baseline: today, on the same data. It must show the owner's complaint.
List<Widget> _today(BuildContext c) => [
      for (final (i, r) in _data.indexed) _row(c, r, title: r.shown, divider: i < _data.length - 1),
    ];

// 1. One axis: identity. Title is what the person asked.
List<Widget> _byAsk(BuildContext c) => [
      for (final (i, r) in _data.indexed) _row(c, r, title: r.ask, divider: i < _data.length - 1),
    ];

void main() {
  if (Platform.environment['TOPIC_VARIANTS'] == null) {
    test('topic variants are off (set TOPIC_VARIANTS=1)', () {}, skip: 'set TOPIC_VARIANTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['TOPIC_VARIANTS_DIR'] ?? '/tmp/topic_variants';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  // Named by axis, not A/B/C. Add one combination of the axes.
  final variants = <String, List<Widget> Function(BuildContext)>{
    '0-today': _today,
    'identity-by-last-ask': _byAsk,
  };

  for (final MapEntry(:key, :value) in variants.entries) {
    for (final b in [Brightness.light, Brightness.dark]) {
      testWidgets('$key ${b.name}', (tester) async {
        await shoot(
          tester,
          _Page(children: value),
          '$out/$key-${b.name}.png',
          brightness: b,
          // A page longer than the phone is drawn whole: resize the surface.
          pump: (t) async {
            t.view.physicalSize = const Size(412, 1200) * phoneDpr;
            await t.pump(const Duration(milliseconds: 100));
          },
        );
      });
    }
  }
}
