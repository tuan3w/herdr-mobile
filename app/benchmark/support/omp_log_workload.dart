// Pure Dart: builds the session log of a long `omp` session (the file omp
// appends to under `~/.omp/agent/sessions/`), for the observed-session open
// benchmark (`benchmark/observed_open_bench_test.dart`).
//
// Nothing here is random at run time: the same seed gives the same bytes. The
// SHAPES are those of a real omp log (entry kinds, the keys of each, the noise
// omp writes around a message: `usage`, `contextSnapshot`, a base64
// `thinkingSignature`, a `tool_execution_start` entry per call, a
// `displayContent` copy of every file read); the TEXT is the recorded agents'
// own (`TracePools`). The SIZES are assumptions this file states, estimated
// from one long omp log on the author's machine (about 3 KB an entry; its last
// 192 KB deflated ~2.9x), not measured on anyone else's:
//
//  * a turn is a user message, 2-8 tool calls (assistant entry with a
//    thought, a `tool_execution_start` entry, the result) and an answer;
//  * 6% of the results carry 15-45 KB (a file read, a test log), the rest
//    0.2-8 KB;
//  * one hidden `custom_message` (a 2-5 KB system reminder) every ~17 calls.
//
// What deflate makes of the text is a property of THIS mix, not of every log;
// the bench prints the ratio it got so it can be compared with ~3x.
import 'dart:convert';
import 'dart:math' as math;

import 'session_workload.dart' show TracePools;

typedef _Json = Map<String, Object?>;

/// The lines of an omp session log, about [bytes] long in total.
List<String> buildOmpLog(TracePools pools, {int bytes = 800 * 1024, int seed = 20261007, String cwd = '/home/u/work'}) {
  final g = _Gen(pools, seed, cwd);
  return g.build(bytes);
}

class _Gen {
  _Gen(this.p, int seed, this.cwd) : r = math.Random(seed);

  final TracePools p;
  final math.Random r;
  final String cwd;

  var _t = DateTime.utc(2026, 10, 6, 13, 32, 37);
  String? _parent;
  var _n = 0;

  static const _hex = '0123456789abcdef';
  static const _b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  static const _ident = 'abcdefghijklmnopqrstuvwxyz0123456789_';

  /// Share of the words of a recorded line that are replaced (tuned so the
  /// replay deflates ~3x).
  static const _novelty = 0.3;

  String _id([int n = 8]) => String.fromCharCodes([for (var i = 0; i < n; i++) _hex.codeUnitAt(r.nextInt(16))]);
  String _random64(int n) => String.fromCharCodes([for (var i = 0; i < n; i++) _b64.codeUnitAt(r.nextInt(64))]);
  int _between(int lo, int hi) => lo + r.nextInt(hi - lo + 1);
  T _pick<T>(List<T> l) => l[r.nextInt(l.length)];

  String _stamp() {
    _t = _t.add(Duration(milliseconds: _between(2, 4000)));
    return _t.toIso8601String();
  }

  /// A recorded line with a share of its words replaced by fresh identifiers:
  /// real logs do not repeat a sentence of a finite pool, and deflate would
  /// otherwise make the text far smaller than it is.
  String _fresh(String line) {
    final words = line.split(' ');
    for (var i = 0; i < words.length; i++) {
      if (r.nextDouble() < _novelty) {
        final n = _between(3, 10);
        words[i] = String.fromCharCodes([for (var k = 0; k < n; k++) _ident.codeUnitAt(r.nextInt(_ident.length))]);
      }
    }
    return words.join(' ');
  }

  /// Text of about [chars] characters out of the recorded agents' lines.
  String _text(int chars) {
    final b = StringBuffer();
    while (b.length < chars) {
      final line = _fresh(_pick(p.corpus));
      b
        ..write(line)
        ..write(b.length % 3 == 0 ? '\n' : ' ');
    }
    return b.toString().substring(0, chars);
  }

  /// A file's lines numbered the way omp's `read` prints them.
  (String numbered, String plain, List<int> numbers) _file(int chars) {
    final numbered = StringBuffer();
    final plain = StringBuffer();
    final numbers = <int>[];
    var n = 1;
    while (numbered.length < chars) {
      final line = _fresh(_pick(p.corpus));
      final indent = ' ' * (r.nextInt(4) * 2);
      numbered.write('$n:$indent$line\n');
      plain.write('$indent$line\n');
      numbers.add(n++);
    }
    return (numbered.toString(), plain.toString(), numbers);
  }

  Map<String, Object?> _entry(String type, Map<String, Object?> body, {String? stamp}) {
    final id = _id();
    final e = <String, Object?>{'type': type, ...body, 'id': id, 'parentId': _parent, 'timestamp': stamp ?? _stamp()};
    _parent = id;
    return e;
  }

  String _line(Map<String, Object?> e) => jsonEncode(e);

  // The size of a tool result: mostly small, now and then a whole file.
  int _resultChars() {
    final x = r.nextDouble();
    if (x < 0.06) return _between(15000, 45000);
    if (x < 0.35) return _between(2000, 8000);
    return _between(200, 2000);
  }

  _Json _usage() {
    final input = _between(2, 12);
    final output = _between(60, 900);
    final read = _between(0, 160000);
    final write = _between(200, 16000);
    return {
      'input': input,
      'output': output,
      'cacheRead': read,
      'cacheWrite': write,
      'totalTokens': input + output + read + write,
      'cost': {
        'input': input * 2e-6,
        'output': output * 1e-5,
        'cacheRead': read * 3e-7,
        'cacheWrite': write * 3.75e-6,
        'total': input * 2e-6 + output * 1e-5 + read * 3e-7 + write * 3.75e-6,
      },
      'cttl': {'ephemeral1h': write},
    };
  }

  _Json _assistant(List<_Json> content, {required String stop}) {
    final at = _t.millisecondsSinceEpoch;
    final duration = r.nextDouble() * 6000;
    return {
      'message': {
        'role': 'assistant',
        'content': content,
        'api': 'anthropic-messages',
        'provider': 'anthropic',
        'model': 'claude-opus-4-5',
        'usage': _usage(),
        'stopReason': stop,
        'timestamp': at,
        'responseId': 'msg_01${_random64(22)}',
        'credentialId': 7,
        'duration': duration,
        'ttft': duration * r.nextDouble(),
        'completedAt': at + duration.round(),
        'contextSnapshot': {'promptTokens': _between(8000, 190000), 'nonMessageTokens': 14233, 'compactionEpoch': 0},
        'errorId': 0,
      },
    };
  }

  /// One tool call: the assistant entry that makes it, `tool_execution_start`
  /// and the result. [out] gets the lines in order.
  void _call(List<String> out) {
    final callId = 'toolu_01${_random64(22)}';
    final kind = r.nextDouble();
    final String name;
    final _Json args;
    final String intent;
    String result;
    _Json details = {};
    if (kind < 0.34) {
      name = 'read';
      final path = '$cwd/${_pick(const ['lib', 'test', 'docs'])}/${_pick(const ['alpha', 'beta', 'gamma', 'delta'])}_${_between(1, 60)}.dart';
      intent = 'Reading ${path.split('/').last}';
      args = {'path': path, 'i': intent};
      final (numbered, plain, numbers) = _file(_resultChars());
      result = '[${path.replaceFirst('$cwd/', '')}#${_id(4).toUpperCase()}]\n$numbered';
      details = {
        'totalLines': numbers.length,
        'displayContent': {'text': plain, 'startLine': 1, 'lineNumbers': numbers},
        'fileSize': plain.length,
        'meta': {
          'source': {'type': 'path', 'value': path},
        },
      };
    } else if (kind < 0.62) {
      name = 'bash';
      final command = _pick(const [
        'dart test test/session_test.dart',
        'git status --short && git diff --stat',
        'flutter analyze lib/data',
        'rg -n "TODO" lib | head -40',
        'ls -la app/lib/data/repositories',
        'python3 tool/trace_cadence.py',
      ]);
      intent = 'Running ${command.split(' ').first}';
      args = {'command': command, 'i': intent};
      result = _text(_resultChars());
      details = {'timeoutSeconds': 300, 'wallTimeMs': r.nextDouble() * 4000};
    } else if (kind < 0.78) {
      name = 'edit';
      final path = '$cwd/lib/${_pick(const ['alpha', 'beta', 'gamma'])}_${_between(1, 40)}.dart';
      intent = 'Editing ${path.split('/').last}';
      args = {
        'path': path,
        'edits': [
          {'oldText': _text(_between(80, 900)), 'newText': _text(_between(80, 1200))},
        ],
        'i': intent,
      };
      result = 'Updated ${path.replaceFirst('$cwd/', '')}';
      details = {'diff': _text(_between(200, 1500)), 'firstChangedLine': _between(1, 400)};
    } else if (kind < 0.88) {
      name = 'write';
      final path = '$cwd/${_pick(const ['docs', 'test'])}/note_${_between(1, 80)}.md';
      intent = 'Writing ${path.split('/').last}';
      args = {'path': path, 'content': _text(_between(400, 6000)), 'i': intent};
      result = 'Wrote ${path.replaceFirst('$cwd/', '')}';
    } else {
      name = 'grep';
      final pattern = _pick(const ['TODO', 'Future<void>', 'class .*Session', 'notifyListeners']);
      intent = 'Searching for $pattern';
      args = {'pattern': pattern, 'path': 'lib', 'i': intent};
      result = _text(_between(300, 3500));
      details = {'matchCount': _between(1, 90), 'fileCount': _between(1, 30)};
    }
    out.add(
      _line(
        _entry('message', {
          ..._assistant([
            {
              'type': 'thinking',
              'thinking': _text(_between(80, 1400)),
              'thinkingSignature': _random64(_pick(const [532, 660, 1044, 1916])),
            },
            {'type': 'toolCall', 'id': callId, 'name': name, 'arguments': args, 'intent': intent},
          ], stop: 'toolUse'),
        }),
      ),
    );
    if (r.nextDouble() < 0.3) {
      out.add(_line(_entry('credential_pin', {'provider': 'anthropic', 'hash': '0' * 64})));
    }
    out.add(
      _line(
        _entry('custom', {
          'customType': 'tool_execution_start',
          'data': {
            'toolCallId': callId,
            'toolName': name,
            'startedAt': _t.toIso8601String(),
            'args': {...args}..remove('i'),
            'intent': intent,
          },
        }),
      ),
    );
    out.add(
      _line(
        _entry('message', {
          'message': {
            'role': 'toolResult',
            'toolCallId': callId,
            'toolName': name,
            'content': [
              {'type': 'text', 'text': result},
            ],
            'details': details,
            'isError': false,
            'timestamp': _t.millisecondsSinceEpoch,
          },
        }),
      ),
    );
    if (_n++ % 17 == 16) {
      out.add(
        _line(
          _entry('custom_message', {
            'customType': 'system-reminder',
            'content': _text(_between(2000, 5000)),
            'display': false,
            'attribution': 'agent',
          }),
        ),
      );
    }
  }

  List<String> build(int bytes) {
    final out = <String>[
      jsonEncode({'type': 'title', 'v': 1, 'title': 'Fix the retry loop', 'source': 'auto', 'updatedAt': _t.toIso8601String(), 'pad': ' ' * 121}),
      jsonEncode({'type': 'session', 'version': 3, 'id': '01a1116a-8cba-7280-9342-${_id(12)}', 'timestamp': _t.toIso8601String(), 'cwd': cwd, 'title': 'Fix the retry loop', 'titleSource': 'auto'}),
      _line(_entry('model_change', {'model': 'anthropic/claude-opus-4-5', 'resolvedModelIsFallback': false})),
      _line(_entry('thinking_level_change', {'thinkingLevel': 'high', 'configured': null})),
    ];
    var size = out.fold<int>(0, (a, l) => a + l.length + 1);
    while (size < bytes) {
      final turn = <String>[];
      turn.add(
        _line(
          _entry('message', {
            'message': {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': r.nextDouble() < 0.7 ? _pick(p.users) : _text(_between(40, 400))},
              ],
              'attribution': 'user',
              'timestamp': _t.millisecondsSinceEpoch,
            },
          }),
        ),
      );
      final calls = _between(2, 8);
      for (var i = 0; i < calls; i++) {
        _call(turn);
      }
      final answer = _pick(p.answers).text;
      turn.add(
        _line(
          _entry('message', {
            ..._assistant([
              {'type': 'text', 'text': answer.length > 3000 ? answer.substring(0, 3000) : answer},
            ], stop: 'stop'),
          }),
        ),
      );
      for (final l in turn) {
        out.add(l);
        size += l.length + 1;
      }
    }
    return out;
  }
}
