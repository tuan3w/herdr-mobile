/// Parse speed of the engine candidates, AOT:
///
///   dart compile exe bin/speed.dart -o /tmp/md_speed && /tmp/md_speed
///
/// 1. one parse of an 8 KB, 22 KB and 200 KB message (median of N runs);
/// 2. streaming replay: a 22 KB message arriving 6 characters at a time, the
///    way a UI without freezing would handle it (re-parse the whole text after
///    every step), and with freezing (flutter_md's own, and ours: the tail of
///    `StreamingMd`, healed, read every step);
/// 3. the worst tails for ours: a 300-item list and a 1000-line code block
///    arriving in 6-character steps (per step: mean and worst).
library;

import 'dart:io';

import 'package:herdr_mobile/ui/core/markdown/markdown.dart';

import '../lib/engine_b.dart';
import '../lib/engine_c.dart';
import '../lib/fmd/parser.dart' show StreamingMarkdownParser;
import '../lib/messages.dart';

final _sink = <int>[0];

double _ms(Stopwatch s) => s.elapsedMicroseconds / 1000.0;

({double min, double med}) _time(void Function() f, int runs) {
  for (var i = 0; i < 2; i++) {
    f();
  }
  final t = <double>[];
  for (var i = 0; i < runs; i++) {
    final s = Stopwatch()..start();
    f();
    t.add(_ms(s));
  }
  t.sort();
  return (min: t.first, med: t[t.length ~/ 2]);
}

String _f(({double min, double med}) t) => '${t.med.toStringAsFixed(2)} ms';

void main() {
  stdout.writeln('| message | B flutter_md | C package:markdown | ours (C chunked + repairs) |');
  stdout.writeln('| --- | ---: | ---: | ---: |');
  for (final kb in [8, 22, 200]) {
    final text = message(kb * 1024);
    final runs = kb >= 200 ? 7 : 25;
    final b = _time(() => _sink[0] += parseBlocksB(text), runs);
    final c = _time(() => _sink[0] += parseC(text).length, runs);
    final d = _time(() => _sink[0] += parseMd(text).blocks.length, runs);
    stdout.writeln('| ${text.length ~/ 1024} KB | ${_f(b)} | ${_f(c)} | ${_f(d)} |');
  }

  final text = message(22 * 1024);
  const step = 6;
  final steps = (text.length / step).ceil();
  stdout.writeln('\nStreaming replay: ${text.length} chars, $step per step, $steps steps');
  void replay(String name, void Function(int end) onStep) {
    final s = Stopwatch()..start();
    for (var e = step; e < text.length + step; e += step) {
      onStep(e > text.length ? text.length : e);
    }
    final total = _ms(s);
    stdout.writeln(
        '$name: total ${total.toStringAsFixed(0)} ms, ${(total / steps).toStringAsFixed(3)} ms per step');
  }

  replay('B full re-parse     ', (e) => _sink[0] += parseBlocksB(text.substring(0, e)));
  replay('C full re-parse     ', (e) => _sink[0] += parseC(text.substring(0, e)).length);
  replay('ours full re-parse  ', (e) => _sink[0] += parseMd(text.substring(0, e)).blocks.length);
  final p = StreamingMarkdownParser();
  var fed = 0;
  replay('B own freeze        ', (e) {
    _sink[0] += p.add(text.substring(fed, e)).blocks.length;
    fed = e;
  });
  final s = StreamingMd();
  var fed2 = 0;
  replay('ours freeze + heal  ', (e) {
    s.append(text.substring(fed2, e));
    fed2 = e;
    _sink[0] += s.frozen.length + s.tail(heal: true).length;
  });

  stdout.writeln('\nWorst tails for ours (per 6-char step: mean / worst):');
  void tail(String name, String t) {
    final st = StreamingMd();
    var worst = 0.0;
    var sum = 0.0;
    var n = 0;
    final sw = Stopwatch();
    for (var at = 0; at < t.length; at += 6) {
      st.append(t.substring(at, (at + 6).clamp(0, t.length)));
      sw
        ..reset()
        ..start();
      _sink[0] += st.frozen.length + st.tail(heal: true).length;
      sw.stop();
      final ms = _ms(sw);
      sum += ms;
      n++;
      if (ms > worst) worst = ms;
    }
    stdout.writeln(
        '$name (${t.length ~/ 1024} KB): ${(sum / n).toStringAsFixed(3)} / ${worst.toStringAsFixed(2)} ms');
  }

  tail('300-item list    ', [
    for (var i = 0; i < 300; i++) '- item $i with **bold** and `code` and [a link](https://x.y/$i)',
  ].join('\n'));
  tail('1000-line code   ', '```dart\n${[
    for (var i = 0; i < 1000; i++) '  final value$i = compute($i, "line $i");',
  ].join('\n')}\n```\n');
  tail('40x30 table      ', () {
    final head = [for (var c = 0; c < 40; c++) 'col$c'];
    return '| ${head.join(' | ')} |\n|${List.filled(40, '---').join('|')}|\n${[
      for (var r = 0; r < 30; r++) '| ${[for (var c = 0; c < 40; c++) '$r,$c'].join(' | ')} |',
    ].join('\n')}\n';
  }());
  stdout.writeln(_sink[0] == -1 ? '' : '');
}
