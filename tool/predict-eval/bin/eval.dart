// Replays everything the person has typed to agents, in order, through each
// prediction idea, and says what it would have saved on a phone and what it
// would have cost in attention. See ../README.md for the model and its limits.
//
//   dart run bin/eval.dart [--style telex|chars|bare] [--slots 3] [--tap-cost 1]
//       [--notice 1] [--tau 0.1,0.25,0.4] [--slice-tau 0.25] [--only a,b]
//       [--limit 2000] [--corpus corpus/messages.jsonl]
import 'dart:io';
import 'dart:math' as math;

import 'package:predict_eval/corpus.dart';
import 'package:predict_eval/predictor.dart';
import 'package:predict_eval/predictors/blend.dart';
import 'package:predict_eval/predictors/chips.dart';
import 'package:predict_eval/predictors/ngram.dart';
import 'package:predict_eval/predictors/phrase.dart';
import 'package:predict_eval/typist.dart';
import 'package:predict_eval/vietnamese.dart';
import 'package:predict_eval/words.dart';

String? _flag(List<String> args, String name) {
  final i = args.indexOf('--$name');
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

typedef _Factory = Predictor Function(double tau);

String _lang(String text) {
  var marked = 0;
  for (final w in allWords(text)) {
    if (hasVietnameseMark(text.substring(w.start, w.end))) marked++;
  }
  return marked >= 2 ? 'vi' : 'en';
}

List<String> _sliceNames(String text, int index, int total) {
  final n = text.length;
  return [
    'all',
    if (n <= 40) 'len <= 40' else if (n <= 100) 'len 41-100' else 'len > 100',
    'lang ${_lang(text)}',
    if (index < 500) 'msgs 0-499' else if (index < 2000) 'msgs 500-1999' else if (index < 5000) 'msgs 2000-4999' else 'msgs 5000+',
  ];
}

class _Run {
  final slices = <String, Tally>{};
  final micros = <int>[];
  Tally get all => slices['all']!;
  int percentile(double q) {
    if (micros.isEmpty) return 0;
    final sorted = [...micros]..sort();
    return sorted[math.min(sorted.length - 1, (q * sorted.length).floor())];
  }
}

_Run _replay(List<Message> msgs, Predictor p, Simulation sim) {
  final run = _Run();
  for (var i = 0; i < msgs.length; i++) {
    final text = msgs[i].text;
    final t = typeMessage(text, p, sim, i, onSuggest: run.micros.add);
    for (final name in _sliceNames(text, i, msgs.length)) {
      (run.slices[name] ??= Tally()).add(t);
    }
    p.learn(text);
  }
  return run;
}

String _pct(double v) => (100 * v).toStringAsFixed(1);

void main(List<String> args) {
  final style = Style.values.byName(_flag(args, 'style') ?? 'telex');
  final sim = Simulation(
    style: style,
    slots: int.parse(_flag(args, 'slots') ?? '3'),
    tapCost: double.parse(_flag(args, 'tap-cost') ?? '1'),
    notice: double.parse(_flag(args, 'notice') ?? '1'),
  );
  final taus = (_flag(args, 'tau') ?? '0.1,0.25,0.4').split(',').map(double.parse).toList();
  final sliceTau = double.parse(_flag(args, 'slice-tau') ?? '0.25');
  final only = _flag(args, 'only')?.split(',').toSet();
  final dir = File(_flag(args, 'corpus') ?? 'corpus/messages.jsonl').parent.path;

  var msgs = loadMessages(_flag(args, 'corpus') ?? 'corpus/messages.jsonl');
  final limit = int.tryParse(_flag(args, 'limit') ?? '');
  if (limit != null && limit < msgs.length) msgs = msgs.sublist(msgs.length - limit);
  if (msgs.isEmpty) {
    stderr.writeln('no messages: run extract_corpus.py first');
    exit(1);
  }

  final en = loadLexicon('$dir/lexicon-en.tsv');
  final vi = loadLexicon('$dir/lexicon-vi.tsv');
  final priors = {
    false: WordPrior.build(en, vi, viShare: 0.05, fold: false),
    true: WordPrior.build(en, vi, viShare: 0.05, fold: true),
  };
  NgramPredictor ngram(NgramParams p, String label) => NgramPredictor(p, priors[p.fold]!, label: label);

  final configs = <String, _Factory>{
    'none': (_) => NonePredictor(),
    'chips-default': (_) => StaticPhrases(),
    'phrase': (tau) => PhrasePredictor(tau: tau),
    'generic-words': (tau) => ngram(NgramParams(tau: tau, personal: false), 'generic-words'),
    'ngram': (tau) => ngram(NgramParams(tau: tau), 'ngram'),
    'ngram-nextword': (tau) => ngram(NgramParams(tau: tau, nextWord: true, minPrefix: 0), 'ngram-nextword'),
    'ngram-fold': (tau) => ngram(NgramParams(tau: tau, fold: true), 'ngram-fold'),
    'blend': (tau) => BlendPredictor([
          PhrasePredictor(tau: tau),
          ngram(NgramParams(tau: tau), 'ngram'),
        ]),
    'blend-nextword': (tau) => BlendPredictor([
          PhrasePredictor(tau: tau),
          ngram(NgramParams(tau: tau, nextWord: true, minPrefix: 0), 'ngram'),
        ], label: 'blend-nextword'),
  };
  const noTau = {'none', 'chips-default'};

  final distinct = <String>{};
  var repeats = 0;
  for (final m in msgs) {
    if (!distinct.add(m.text)) repeats++;
  }
  final chars = msgs.fold<int>(0, (a, m) => a + m.text.length);
  stdout
    ..writeln('# Prediction replay')
    ..writeln()
    ..writeln('${msgs.length} messages, $chars characters, median length '
        '${(msgs.map((m) => m.text.length).toList()..sort())[msgs.length ~/ 2]}; '
        '${_pct(repeats / msgs.length)}% repeat an earlier message exactly '
        '(the ceiling of whole-message prediction).')
    ..writeln('Style `${style.name}`, ${sim.slots} chips, a tap costs ${sim.tapCost} keys, '
        'the person notices a right chip ${_pct(sim.notice)}% of the time. '
        'Latency is this computer, not a phone.')
    ..writeln();

  final rows = <(String, double?, _Run)>[];
  for (final entry in configs.entries) {
    if (only != null && !only.contains(entry.key)) continue;
    for (final tau in noTau.contains(entry.key) ? [null] : taus) {
      stderr.writeln('replaying ${entry.key}${tau == null ? '' : ' tau=$tau'} ...');
      rows.add((entry.key, tau, _replay(msgs, entry.value(tau ?? 0), sim)));
    }
  }

  stdout
    ..writeln('| idea | τ | keys saved % | taps / msg | answered by taps % | noisy words / 100 | flips / 100 | chips on screen % | p50 µs | p99 µs |')
    ..writeln('|---|---|---|---|---|---|---|---|---|---|');
  for (final (name, tau, run) in rows) {
    final a = run.all;
    stdout.writeln('| $name | ${tau ?? '-'} | ${_pct(a.ksr)} | ${(a.taps / a.messages).toStringAsFixed(2)} '
        '| ${_pct(a.tapOnly / a.messages)} | ${a.per100Words(a.noisyWords).toStringAsFixed(1)} '
        '| ${a.per100Words(a.flips).toStringAsFixed(1)} | ${_pct(a.chipsOnScreen)} '
        '| ${run.percentile(0.5)} | ${run.percentile(0.99)} |');
  }

  final atTau = [for (final r in rows) if (r.$2 == null || r.$2 == sliceTau) r];
  const order = [
    'all', 'len <= 40', 'len 41-100', 'len > 100', 'lang en', 'lang vi',
    'msgs 0-499', 'msgs 500-1999', 'msgs 2000-4999', 'msgs 5000+',
  ];
  stdout
    ..writeln()
    ..writeln('## Keys saved % by slice (τ $sliceTau)')
    ..writeln()
    ..writeln('| slice | messages | ${atTau.map((r) => r.$1).join(' | ')} |')
    ..writeln('|---|---|${atTau.map((_) => '---').join('|')}|');
  for (final slice in order) {
    final n = atTau.first.$3.slices[slice]?.messages ?? 0;
    if (n == 0) continue;
    stdout.writeln('| $slice | $n | ${atTau.map((r) => _pct(r.$3.slices[slice]?.ksr ?? 0)).join(' | ')} |');
  }
}
