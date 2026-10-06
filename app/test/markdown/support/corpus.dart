/// Loader for `app/test/markdown/corpus/*.case`.
///
/// ```
/// # comment (only before the first case)
/// === name | flag | flag
/// markdown input lines            (or one `@json "..."` line)
/// --- expect
/// the structure dump              (or, for `heal` cases, the healed source)
/// --- display                     (optional, `heal` cases)
/// dump of parse(healTail(input))
/// ```
/// Flags: `soft=space` (CommonMark soft breaks instead of the chat default),
/// `heal` (the case is a `healTail` case).
///
/// Pure Dart: the bench AOT-compiles it.
library;

import 'dart:convert';
import 'dart:io';

final class MdCase {
  const MdCase({
    required this.file,
    required this.name,
    required this.flags,
    required this.input,
    required this.expect,
    this.display,
  });

  final String file;
  final String name;
  final Set<String> flags;
  final String input;
  final String expect;
  final String? display;

  bool get isHeal => flags.contains('heal');
  bool get softSpace => flags.contains('soft=space');

  @override
  String toString() => '$file:$name';
}

String _section(List<String> lines) {
  var end = lines.length;
  while (end > 0 && lines[end - 1].trim().isEmpty) {
    end--;
  }
  final body = lines.sublist(0, end);
  if (body.length == 1 && body.first.startsWith('@json ')) {
    return jsonDecode(body.first.substring(6)) as String;
  }
  return body.join('\n');
}

List<MdCase> parseCaseFile(String file, String text) {
  final out = <MdCase>[];
  String? name;
  Set<String> flags = {};
  var part = 0; // 0 input, 1 expect, 2 display
  var input = <String>[];
  var expect = <String>[];
  var display = <String>[];

  void finish() {
    final n = name;
    if (n == null) return;
    out.add(MdCase(
      file: file,
      name: n,
      flags: flags,
      input: _section(input),
      expect: _section(expect),
      display: part == 2 ? _section(display) : null,
    ));
  }

  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('=== ')) {
      finish();
      final parts = line.substring(4).split('|').map((s) => s.trim()).toList();
      name = parts.first;
      flags = parts.skip(1).toSet();
      part = 0;
      input = [];
      expect = [];
      display = [];
    } else if (name == null) {
      continue;
    } else if (line == '--- expect' && part == 0) {
      part = 1;
    } else if (line == '--- display' && part == 1) {
      part = 2;
    } else {
      (part == 0 ? input : part == 1 ? expect : display).add(line);
    }
  }
  finish();
  return out;
}

/// All cases of every `*.case` file under [dir], sorted by file name.
List<MdCase> loadCorpus(String dir) {
  final files = Directory(dir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.case'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final f in files)
      ...parseCaseFile(f.uri.pathSegments.last, f.readAsStringSync()),
  ];
}

/// Larger realistic messages (`corpus/messages/*.md`), for the prefix, size
/// and speed tests; no per-case expectation, only invariants.
List<({String name, String text})> loadMessages(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  final files = d
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final f in files)
      (name: f.uri.pathSegments.last, text: f.readAsStringSync()),
  ];
}
