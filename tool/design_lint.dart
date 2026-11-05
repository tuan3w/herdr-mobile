// The design lint: every value a screen draws with comes from the kit.
//
//   dart run tool/design_lint.dart            (from the repo root, or ../tool from app/)
//   dart run tool/design_lint.dart --report   counts per rule and folder, exit 0
//
// A finding names the kit token or component to use instead. A line that must
// keep a raw value says why, on the same line or the one above:
//
//   // design-lint: allow(raw-type) markdown inline bold is the author's emphasis
//
// A rule matches across lines (a whole argument list, `SizedBox(\n  width: 12`),
// and an allow on any line the match spans, or the line above it, covers it.
// An allow without a reason is itself a finding. Rules and their reasons live
// in docs/DESIGN.md ("Enforcement"); the kit's own token files are exempt from
// the rules they define.
import 'dart:io';

final class Rule {
  const Rule(
    this.id,
    this.patterns,
    this.message, {
    this.include = const ['lib/ui/'],
    this.exempt = const [],
  });

  final String id;
  final List<RegExp> patterns;
  final String message;

  /// Path prefixes (relative to app/) the rule applies to.
  final List<String> include;

  /// Path prefixes it skips: the files that define the tokens it enforces.
  final List<String> exempt;

  bool appliesTo(String path) =>
      include.any(path.startsWith) && !exempt.any(path.startsWith);
}

final _rules = <Rule>[
  Rule(
    'raw-color',
    [
      RegExp(r'\bColor\(\s*0x'),
      RegExp(r'\bColor\.from(?:ARGB|RGBO)\('),
      RegExp(r'\bColors\.(?!transparent\b)'),
    ],
    'use a Ds role (context.ds.*) or add one to tokens.dart',
    exempt: [
      'lib/ui/core/tokens.dart',
      'lib/ui/core/theme.dart',
      'lib/ui/render/terminal/',
    ],
  ),
  Rule(
    'raw-type',
    [
      RegExp(r'\bfontSize:'),
      RegExp(r'\bfontWeight:'),
      RegExp(r'\bTextStyle\('),
      RegExp(r'\bletterSpacing:\s*-?[\d.]'),
      // A line height read off a token or a measured metric is fine; a typed one is not.
      RegExp(r'\.copyWith\([^)]*\bheight:\s*[\d.]'),
    ],
    'use a Type.* or Mono.* token (Strong variants carry the weight)',
    exempt: ['lib/ui/core/tokens.dart', 'lib/ui/render/terminal/'],
  ),
  Rule(
    'raw-alpha',
    [RegExp(r'\.withValues\(\s*alpha:')],
    'use a Ds role or getter (wash, washPressed, accentWash, pressTint, faint...)',
    exempt: ['lib/ui/core/tokens.dart'],
  ),
  Rule('raw-radius', [
    RegExp(r'\b(?:BorderRadius|Radius)\.circular\(\s*[\d.]'),
  ], 'use Radii.xs/sm/md/lg/pill'),
  Rule(
    'raw-duration',
    [RegExp(r'\bDuration\(\s*(?:milliseconds|seconds|microseconds|minutes):')],
    'use a Motion.* duration or a Dwell.* timer',
    exempt: ['lib/ui/core/motion.dart'],
  ),
  Rule(
    'raw-curve',
    [RegExp(r'\bCubic\('), RegExp(r'\bCurves\.')],
    'use Motion.easeOut / Motion.curved()',
    exempt: ['lib/ui/core/motion.dart'],
  ),
  Rule(
    'raw-spring',
    [RegExp(r'\bSpringDescription(?:\(|\.with)')],
    'use a Springs.* token',
    exempt: ['lib/ui/core/motion.dart'],
  ),
  Rule(
    'raw-size',
    [
      RegExp(r'\b(?:size|iconSize):\s*[\d.]'),
      // A layout size; a stroke's width (BorderSide, Border.all), a line
      // height (copyWith, raw-type's) and a zero floor are not sizes.
      RegExp(
        r'(?<!(?:BorderSide|Border\.all|copyWith)\([^)]*)\b(?:height|width|minWidth|minHeight|maxWidth|maxHeight):\s*(?!0\b)[\d.]',
      ),
      RegExp(r'\bEdgeInsets\.\w+\([^)]*(?<![\w.])\d'),
    ],
    'use IconSize.*, Gap.* or a component size',
    include: ['lib/ui/features/', 'lib/ui/shell/'],
  ),
  Rule(
    'raw-haptic',
    [RegExp(r'\bHapticFeedback\.')],
    'use Haptics.tick/hold/sent/armed/failed',
    exempt: ['lib/ui/core/motion.dart'],
  ),
  Rule(
    'voice',
    [
      // A straight apostrophe in a contraction, in either quote style (`isn't`,
      // `isn\'t`); the voice is a curly one (`isn’t`).
      RegExp(r'''"[^"\n]*[A-Za-z]'(?:t|s|re|ll|ve|d)\b'''),
      RegExp(r'''\'[^'\n]*[A-Za-z]\\'(?:t|s|re|ll|ve|d)\b'''),
      // A negation spelled out in a sentence (a capital after the quote, or
      // a space before it): `Could not`, `did not`, `is not`, `cannot`.
      RegExp(
        r'''['"][^'"\n]*\b(?:[Cc]ould not|did not|does not|is not|was not|cannot|Cannot)\b''',
      ),
    ],
    'say it as the app does: curly apostrophe and contractions (Couldn’t, didn’t, isn’t)',
  ),
  Rule(
    'clipboard',
    [RegExp(r'\bClipboard\.setData\(')],
    'use copyText() from the kit: it says "copied" only where Android does not',
    include: ['lib/'],
    exempt: ['lib/ui/core/clipboard.dart'],
  ),
  Rule(
    'material',
    [
      RegExp(
        r'\b(?:Icons\.|InkWell\(|ListTile\(|AlertDialog\(|SnackBar\(|AppBar\(|Card\(|ElevatedButton\(|TextButton\(|'
        r'OutlinedButton\(|FilledButton\(|IconButton\(|PopupMenuButton\(|ExpansionTile\(|SegmentedButton\(|'
        r'FloatingActionButton\(|BackdropFilter\()',
      ),
    ],
    'herdr is not Material: use the kit (buttons.dart, sheets.dart, toast.dart, Lucide icons)',
  ),
  Rule(
    'modal-sheet',
    [RegExp(r'\bshowModalBottomSheet\b')],
    'use showAppSheet + SheetScaffold',
    exempt: ['lib/ui/core/sheets.dart'],
  ),
  Rule(
    'spinner',
    [RegExp(r'\b(?:CircularProgressIndicator|LinearProgressIndicator)\b')],
    'use BusySpinner (it waits before it shows, and stops under reduced motion)',
    exempt: ['lib/ui/core/spinner.dart'],
  ),
  Rule(
    'loop',
    [RegExp(r'\.repeat\(')],
    'nothing loops at rest (BusySpinner is the one exception)',
    exempt: ['lib/ui/core/spinner.dart'],
  ),
  Rule(
    'kit-import',
    [
      RegExp(
        r'''^import\s+['"](?:package:herdr_mobile/ui/core/(?!kit\.dart)|(?:\.\./)+core/(?!kit\.dart))''',
      ),
    ],
    'import the kit through ui/core/kit.dart',
    include: [
      'lib/ui/features/',
      'lib/ui/shell/',
      'lib/ui/render/',
      'lib/ui/support/',
    ],
  ),
  Rule(
    'layer',
    [
      RegExp(
        r'''^import\s+['"].*(?:ui/features/|ui/render/|ui/support/|\.\./features/|\.\./render/|\.\./support/)''',
      ),
    ],
    'the kit imports nothing above it',
    include: ['lib/ui/core/'],
  ),
  Rule(
    'layer',
    [RegExp(r'''^import\s+['"].*(?:ui/features/|\.\./features/)''')],
    'a renderer imports no feature',
    include: ['lib/ui/render/'],
  ),
  Rule(
    'layer',
    [
      RegExp(
        r'''^import\s+['"](?:package:flutter|package:herdr_mobile/ui/|(?:\.\./)+ui/)''',
      ),
    ],
    'words are pure Dart: no Flutter, no UI',
    include: ['lib/data/words/'],
  ),
];

final _allow = RegExp(
  r'//\s*design-lint:\s*allow\(([\w-]+(?:\s*,\s*[\w-]+)*)\)\s*(.*)$',
);

final class Finding {
  Finding(this.path, this.line, this.rule, this.message);
  final String path;
  final int line;
  final String rule;
  final String message;
}

/// The rule ids a line is allowed to break, from an allow comment on it or on
/// the line above. An allow with no reason allows nothing and is reported.
Set<String> _allowed(List<String> lines, int i, void Function(String) bad) {
  final ids = <String>{};
  for (final j in [i, i - 1]) {
    if (j < 0) continue;
    final m = _allow.firstMatch(lines[j]);
    if (m == null) continue;
    if (j == i - 1 && !lines[j].trimLeft().startsWith('//')) continue;
    if (m[2]!.trim().isEmpty) {
      // Said once, on its own line; the line below just gets no allow.
      if (j == i) bad('design-lint allow(${m[1]}) needs a reason after it');
      continue;
    }
    ids.addAll(m[1]!.split(',').map((s) => s.trim()));
  }
  return ids;
}

List<Finding> lint(Directory app) {
  final findings = <Finding>[];
  final lib = Directory('${app.path}/lib');
  final files =
      lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    findings.addAll(
      lintSource(
        file.path.substring(app.path.length + 1),
        file.readAsStringSync(),
      ),
    );
  }
  return findings;
}

/// The findings in one file's [source], [path] relative to app/ (`lib/...`).
List<Finding> lintSource(String path, String source) {
  final rules = _rules.where((r) => r.appliesTo(path)).toList();
  if (rules.isEmpty) return const [];
  final findings = <Finding>[];
  final lines = source.split('\n');
  // The code with comments blanked, one string, so a rule sees a whole
  // argument list however it is wrapped. Comment lines and trailing comments
  // become spaces, so offsets still map to lines and prose trips nothing.
  final code = StringBuffer();
  final starts = <int>[];
  for (final raw in lines) {
    starts.add(code.length);
    final lead = raw.length - raw.trimLeft().length;
    final cut = raw.trimLeft().startsWith('//')
        ? lead
        : raw.indexOf(RegExp(r'\s//'));
    code
      ..write(cut < 0 ? raw : raw.substring(0, cut).padRight(raw.length))
      ..write('\n');
  }
  final text = code.toString();
  int lineOf(int offset) {
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  final allowed = <int, Set<String>>{};
  for (var i = 0; i < lines.length; i++) {
    allowed[i] = _allowed(
      lines,
      i,
      (m) => findings.add(Finding(path, i + 1, 'allow', m)),
    );
  }
  final seen = <String>{};
  for (final rule in rules) {
    for (final pattern in rule.patterns) {
      final multi = RegExp(pattern.pattern, multiLine: true);
      for (final m in multi.allMatches(text)) {
        final first = lineOf(m.start);
        final last = lineOf(m.end > m.start ? m.end - 1 : m.start);
        var ok = false;
        for (var i = first; i <= last && !ok; i++) {
          ok = allowed[i]!.contains(rule.id);
        }
        // The finding names the line the raw value is on.
        if (!ok && seen.add('$last:${rule.id}'))
          findings.add(Finding(path, last + 1, rule.id, rule.message));
      }
    }
  }
  findings.sort((a, b) => a.line.compareTo(b.line));
  return findings;
}

void main(List<String> args) {
  final here = Directory.current.path;
  final app = Directory(
    File('$here/pubspec.yaml').existsSync() ? here : '$here/app',
  );
  if (!File('${app.path}/pubspec.yaml').existsSync()) {
    stderr.writeln('design_lint: run from the repo root or from app/');
    exit(2);
  }
  final findings = lint(app);
  if (args.contains('--report')) {
    final byRule = <String, int>{};
    final byFolder = <String, int>{};
    for (final f in findings) {
      byRule[f.rule] = (byRule[f.rule] ?? 0) + 1;
      final parts = f.path.split('/');
      final folder = parts.length > 4
          ? parts.take(4).join('/')
          : parts.take(parts.length - 1).join('/');
      byFolder[folder] = (byFolder[folder] ?? 0) + 1;
    }
    stdout.writeln('${findings.length} findings');
    for (final e
        in byRule.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value))) {
      stdout.writeln('  ${e.key.padRight(14)} ${e.value}');
    }
    stdout.writeln('by folder:');
    for (final e
        in byFolder.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value))) {
      stdout.writeln('  ${e.value.toString().padLeft(5)}  ${e.key}');
    }
    return;
  }
  for (final f in findings) {
    stdout.writeln('${f.path}:${f.line} ${f.rule} ${f.message}');
  }
  if (findings.isNotEmpty) {
    stderr.writeln('design_lint: ${findings.length} findings');
    exit(1);
  }
}
