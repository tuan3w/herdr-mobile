import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/render/markdown/markdown.dart';
import 'package:herdr_mobile/ui/render/mermaid/md_diagram_opener.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_cache.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_layout.dart';

const _flow = 'flowchart TD\n A[Start] --> B{Ok?}\n B -->|yes| C[Ship]\n B -->|no| A';

/// 14 nodes in a column: taller than the 420 dp a diagram shows before "Show all".
final _tall =
    'flowchart TB\n${[for (var i = 0; i < 13; i++) ' N$i[Step number $i] --> N${i + 1}[Step number ${i + 1}]'].join('\n')}';

/// 8 participants: wider than a phone at 80%.
final _wide =
    'sequenceDiagram\n${[for (var i = 0; i < 8; i++) ' participant P$i as Participant number $i'].join('\n')}\n P0->>P7: hello';

MdBlock _block(String source, {String lang = 'mermaid'}) => parseMd('```$lang\n$source\n```').blocks.single;

class _Harness extends StatefulWidget {
  const _Harness({required this.block, this.tail = false, this.open});

  final MdBlock block;
  final bool tail;
  final OpenDiagram? open;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    Widget view = Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 328,
        child: SingleChildScrollView(
          child: MdBlockView(
            block: widget.block,
            tail: widget.tail,
            expanded: expanded,
            onToggleExpanded: () => setState(() => expanded = !expanded),
          ),
        ),
      ),
    );
    final open = widget.open;
    if (open != null) view = MdDiagramOpener(open: open, child: view);
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: view),
    );
  }
}

Future<void> _pump(WidgetTester tester, _Harness h) async {
  MermaidCache.shared = MermaidCache((job) async => layoutMermaid(job));
  tester.view.physicalSize = const Size(400, 900) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(h);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('a closed mermaid fence is drawn, and its source isn’t shown as code', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _Harness(block: _block(_flow)));
    expect(find.bySemanticsLabel('Diagram, flowchart'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Code')), findsNothing);
    semantics.dispose();
  });

  testWidgets('the open end of a streaming message is still the code arriving', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _Harness(block: _block(_flow), tail: true));
    expect(find.bySemanticsLabel('Diagram, flowchart'), findsNothing);
    expect(find.text('mermaid'), findsOneWidget, reason: 'the code block header');
    semantics.dispose();
  });

  testWidgets('a fence that never closed (a cut-off message, a thought arriving) is code, not a diagram', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final block = parseMd('Here:\n\n```mermaid\nflowchart TD\n A-->B\n B-->C').blocks.last as MdCode;
    expect(block.closed, isFalse);
    expect((_block(_flow) as MdCode).closed, isTrue);
    await _pump(tester, _Harness(block: block));
    expect(find.bySemanticsLabel('Diagram, flowchart'), findsNothing);
    expect(find.text('mermaid'), findsOneWidget, reason: 'the code block header');
    expect(find.textContaining('Couldn’t draw'), findsNothing, reason: 'no layout was asked for');
    semantics.dispose();
  });

  testWidgets('a diagram the cache holds is on the first frame, with no code block that jumps taller after it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final h = _Harness(block: _block(_flow));
    await _pump(tester, h);
    expect(find.bySemanticsLabel('Diagram, flowchart'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(h);
    expect(
      find.bySemanticsLabel('Diagram, flowchart'),
      findsOneWidget,
      reason: 'drawn by the first frame, not one microtask later',
    );
    expect(find.text('mermaid'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a kind the app doesn’t draw stays code, with the reason', (tester) async {
    await _pump(tester, _Harness(block: _block('gantt\n title x\n section a\n t1 :a1, 2024-01-01, 3d')));
    expect(find.text("Can’t draw gantt chart diagrams yet · showing the source"), findsOneWidget);
    expect(find.text('mermaid'), findsOneWidget);
  });

  testWidgets('a syntax error stays code, with the line', (tester) async {
    await _pump(tester, _Harness(block: _block('flowchart TD\n A-->')));
    expect(find.textContaining('Couldn’t draw this diagram · line 2'), findsOneWidget);
  });

  testWidgets('Copy source puts the source as written on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final semantics = tester.ensureSemantics();
    const source = r'flowchart TD\n A["one\ntwo"] --> B';
    await _pump(tester, _Harness(block: _block(source.replaceAll(r'\n A', '\n A'))));
    await tester.tap(find.bySemanticsLabel('Copy source'));
    await tester.pump();
    expect(copied, contains(r'A["one\ntwo"]'), reason: 'not the normalised text');
    semantics.dispose();
  });

  testWidgets('a diagram wider than the block scrolls sideways', (tester) async {
    await _pump(tester, _Harness(block: _block(_wide)));
    final scroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(MdBlockView),
        matching: find.byWidgetPredicate((w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
      ),
    );
    expect(scroll.controller!.position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('a diagram taller than the cap is cropped until "Show all"', (tester) async {
    await _pump(tester, _Harness(block: _block(_tall)));
    expect(find.text('Cropped'), findsOneWidget);
    final cropped = tester.getSize(find.byType(OverflowBox).first).height;
    expect(cropped, lessThanOrEqualTo(420));

    await tester.tap(find.text('Show all'));
    await tester.pump();
    expect(find.text('Whole diagram'), findsOneWidget);
    expect(tester.getSize(find.byType(OverflowBox).first).height, greaterThan(420));
  });

  testWidgets('the Open button and a tap on the diagram both open it', (tester) async {
    final opened = <MermaidDrawn>[];
    final semantics = tester.ensureSemantics();
    await _pump(tester, _Harness(block: _block(_flow), open: (context, drawn) async => opened.add(drawn)));
    await tester.tap(find.bySemanticsLabel('Open diagram'));
    await tester.tap(find.byType(OverflowBox).first);
    expect(opened, hasLength(2));
    expect(opened.first.kind, MermaidKind.flowchart);
    semantics.dispose();
  });
}
