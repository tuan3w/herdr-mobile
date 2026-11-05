import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_layout.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_source.dart';
import 'package:mermaid_core/mermaid_core.dart' as core;

const _dark = core.Color(0xFF37352F);
const _light = core.Color(0xFFECEDEF);

MermaidJob _job(String source, {core.MermaidTheme? theme}) => MermaidJob(
  source: source,
  theme: theme ?? core.MermaidTheme.defaultTheme.copyWith(fontFamily: 'Inter', fontSize: 13),
  darkText: _dark,
  lightText: _light,
);

MermaidDrawn _drawn(String source, {core.MermaidTheme? theme}) {
  final r = layoutMermaid(_job(source, theme: theme));
  expect(r, isA<MermaidDrawn>(), reason: r is MermaidFailed ? r.reason : null);
  return r as MermaidDrawn;
}

Iterable<core.SceneText> _texts(List<core.SceneNode> nodes) sync* {
  for (final n in nodes) {
    switch (n) {
      case core.SceneText():
        yield n;
      case core.SceneGroup():
        yield* _texts(n.children);
      case core.SceneShape():
        break;
    }
  }
}

void main() {
  group('normalizeMermaid', () {
    test('a backslash-n in a label becomes a line break', () {
      expect(normalizeMermaid(r'A["cmd1\n(child)"]'), 'A["cmd1<br/>(child)"]');
    });

    test('dotted link text without spaces is spaced, a link without text is left alone', () {
      expect(normalizeMermaid('A -.go.-> B'), 'A -. go .-> B');
      expect(normalizeMermaid('A -.-> B'), 'A -.-> B');
      expect(normalizeMermaid('A -. go .-> B'), 'A -. go .-> B');
      expect(normalizeMermaid('A -.not yet tested.-> B'), 'A -. not yet tested .-> B');
    });
  });

  group('layoutMermaid', () {
    test('draws each kind v1 supports, with the phone profile in front', () {
      const sources = {
        MermaidKind.flowchart: 'flowchart TD\n A[Start] --> B{Ok?}\n B -->|yes| C[Ship]\n B -->|no| A',
        MermaidKind.sequence:
            'sequenceDiagram\n participant A as App\n participant B as Server\n A->>B: hello\n B-->>A: hi',
        MermaidKind.state: 'stateDiagram-v2\n [*] --> idle\n idle --> running: start\n running --> [*]',
        MermaidKind.er: 'erDiagram\n USER ||--o{ ORDER : places\n USER {\n int id PK\n string name\n }',
        MermaidKind.classDiagram: 'classDiagram\n class Animal {\n +String name\n +eat()\n }\n Animal <|-- Dog',
      };
      for (final MapEntry(:key, :value) in sources.entries) {
        final d = _drawn(value);
        expect(d.kind, key);
        expect(d.scene.size.width, greaterThan(0), reason: key.name);
        expect(d.scene.size.height, greaterThan(0), reason: key.name);
      }
    });

    test("the engine’s white and pale-green fills do not light up a dark diagram", () {
      final theme = core.MermaidTheme.darkTheme.copyWith(fontFamily: 'Inter', fontSize: 13);
      final d = _drawn('erDiagram\n USER ||--o{ ORDER : places\n USER {\n int id PK\n }', theme: theme);
      Iterable<core.SceneShape> shapes(List<core.SceneNode> nodes) sync* {
        for (final n in nodes) {
          switch (n) {
            case core.SceneShape():
              yield n;
            case core.SceneGroup():
              yield* shapes(n.children);
            case core.SceneText():
              break;
          }
        }
      }

      final bright = shapes(d.scene.nodes).where((s) => s.fill != null && s.fill!.color.value == 0xFFFFFFFF);
      expect(bright, isEmpty, reason: 'a white ring or box');
      final label = _texts(d.scene.nodes).firstWhere((t) => t.text == 'places');
      expect(label.style.fontFamily, 'Inter');
    });

    test('a kind v1 doesn’t draw says which one, and a syntax error says which line', () {
      final gantt = layoutMermaid(_job('gantt\n title x\n section a\n t1 :a1, 2024-01-01, 3d'));
      expect((gantt as MermaidFailed).reason, startsWith("Can’t draw gantt chart diagrams yet"));

      final broken = layoutMermaid(_job('flowchart TD\n A-->'));
      expect((broken as MermaidFailed).reason, contains('line 2'));

      expect((layoutMermaid(_job('   ')) as MermaidFailed).reason, 'Nothing to draw');
      expect(
        (layoutMermaid(_job('flowchart TD\n${' A-->B\n' * 4000}')) as MermaidFailed).reason,
        startsWith('Too large'),
      );
    });

    test('a left-to-right chain is drawn top-down when that is narrower; a short one keeps its direction', () {
      final chain = _drawn('flowchart LR\n A-->B\n B-->C\n C-->D\n D-->E\n E-->F\n F-->G');
      expect(chain.turned, isTrue);
      expect(_drawn('flowchart LR\n A-->B').turned, isFalse);
      expect(_drawn('flowchart TB\n A-->B\n B-->C\n C-->D\n D-->E\n E-->F\n F-->G').turned, isFalse);
    });

    test("the author’s own directive is kept: no profile line, so the error line is the source’s", () {
      final r = layoutMermaid(_job('%%{init: {"flowchart":{"padding":4}}}%%\nflowchart TD\n A-->'));
      expect((r as MermaidFailed).reason, contains('line 3'));
    });

    test('an author fill the theme text doesn’t read on gets text that does (4.5:1)', () {
      final theme = core.MermaidTheme.darkTheme.copyWith(fontFamily: 'Inter', fontSize: 13);
      final d = _drawn('flowchart TD\n A[Hello world]\n style A fill:#e1f5fe', theme: theme);
      final label = _texts(d.scene.nodes).firstWhere((t) => t.text.contains('Hello'));
      expect(contrastRatio(label.color, const core.Color(0xFFE1F5FE)), greaterThanOrEqualTo(4.5));
    });

    test('a literal backslash-n in a label is drawn as two lines', () {
      final one = _drawn('flowchart TD\n A["one two"]');
      final two = _drawn(
        r'flowchart TD'
        '\n'
        r' A["one\ntwo"]',
      );
      expect(two.scene.size.height, greaterThan(one.scene.size.height));
    });

    test('off the main isolate gives the same scene as on it', () async {
      const source = 'flowchart TD\n A[Start] --> B{Ok?}\n B -->|yes| C[Ship]';
      final here = _drawn(source);
      final there = await layoutMermaidOffThread(_job(source));
      expect(there, isA<MermaidDrawn>());
      final t = there as MermaidDrawn;
      expect(t.scene.size.width, here.scene.size.width);
      expect(t.scene.size.height, here.scene.size.height);
      expect(t.labels, here.labels);
    });
  });
}
