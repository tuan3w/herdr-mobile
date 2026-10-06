/// Correctness score of the engine candidates on the corpus.
///
///   dart run bin/score.dart [-v name-substring] [--engine a|b|c|d]
///
/// Every non-heal case of app/test/markdown/corpus/*.case is parsed by each
/// candidate and compared, as the canonical dump, with the expectation.
library;

import 'dart:io';

import '../../../app/test/markdown/support/corpus.dart';
import '../lib/engine_b.dart';
import '../lib/engine_c.dart';
import '../lib/engine_d.dart';

typedef Dumper = String Function(String, {bool softSpace});

void main(List<String> args) {
  final verbose = args.contains('-v');
  final filter = args.contains('-v') && args.indexOf('-v') + 1 < args.length
      ? args[args.indexOf('-v') + 1]
      : '';
  final only = args.contains('--engine') ? args[args.indexOf('--engine') + 1] : null;
  final cases = loadCorpus('../../app/test/markdown/corpus')
      .where((c) => !c.isHeal)
      .toList();
  final engines = <String, Dumper>{
    'B': dumpB,
    'C': dumpC,
    'D': dumpD,
  };
  final byFile = <String, Map<String, int>>{};
  final total = <String, int>{for (final k in engines.keys) k: 0};
  final failed = <String, List<String>>{for (final k in engines.keys) k: []};
  for (final c in cases) {
    for (final e in engines.entries) {
      if (only != null && e.key.toLowerCase() != only) continue;
      String got;
      try {
        got = e.value(c.input, softSpace: c.softSpace);
      } catch (err) {
        got = 'THROWS $err';
      }
      final ok = got == c.expect;
      final row = byFile.putIfAbsent(c.file, () => {});
      row['${e.key}.n'] = (row['${e.key}.n'] ?? 0) + 1;
      if (ok) {
        row[e.key] = (row[e.key] ?? 0) + 1;
        total[e.key] = total[e.key]! + 1;
      } else {
        failed[e.key]!.add('${c.file}:${c.name}');
        if (verbose && c.name.contains(filter)) {
          stdout.writeln('--- ${e.key} FAIL ${c.file}:${c.name}\ninput : ${c.input.replaceAll('\n', '⏎')}\nexpect:\n${c.expect}\ngot:\n$got\n');
        }
      }
    }
  }
  stdout.writeln('cases: ${cases.length}');
  for (final f in byFile.entries) {
    final r = f.value;
    stdout.writeln(
        '${f.key.padRight(14)} ${engines.keys.map((k) => '$k ${r[k] ?? 0}/${r['$k.n'] ?? 0}').join('   ')}');
  }
  stdout.writeln(
      'TOTAL          ${engines.keys.map((k) => '$k ${total[k]}/${cases.length}').join('   ')}');
  if (!verbose) {
    for (final k in engines.keys) {
      stdout.writeln('\n$k fails (${failed[k]!.length}): ${failed[k]!.join(' ')}');
    }
  }
}
