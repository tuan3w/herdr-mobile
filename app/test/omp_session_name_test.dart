// What the board can name an omp agent by, read from two slices of its log.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/omp_session_name.dart';

String _line(Map<String, Object?> m) => '${jsonEncode(m)}\n';

String _user(Object content) =>
    _line({'type': 'message', 'message': {'role': 'user', 'content': content}});

String _assistant(String text) => _line({
      'type': 'message',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });

List<Map<String, String>> _text(String s) => [
      {'type': 'text', 'text': s},
    ];

void main() {
  group('title', () {
    test('comes from omp\'s fixed-width first line', () {
      final head = _line({
        'type': 'title',
        'v': 1,
        'updatedAt': '2026-10-07T10:00:00Z',
        'title': '  Fix Tailscale SSH key failures  ',
        'pad': ' ' * 80,
      });
      final name = parseOmpSessionName(head: head, tail: head);
      expect(name.title, 'Fix Tailscale SSH key failures');
    });

    test('comes from the session entry of an older log', () {
      final head = _line({'type': 'session', 'cwd': '/src/app', 'title': 'Old style title'});
      expect(parseOmpSessionName(head: head, tail: '').title, 'Old style title');
    });

    test('a later title_change in the tail wins over the head', () {
      final head = _line({'type': 'title', 'title': 'First title'});
      final tail = _user(_text('hello')) + _line({'type': 'title_change', 'title': 'Renamed'});
      expect(parseOmpSessionName(head: head, tail: tail, tailStartsMidLine: true).title, 'Renamed');
    });

    test('an empty or missing title is no title', () {
      final head = _line({'type': 'title', 'title': '   '}) + _line({'type': 'session'});
      expect(parseOmpSessionName(head: head, tail: '').title, isNull);
    });
  });

  group('last prompt', () {
    test('is the first line of the person\'s last message with text', () {
      final tail = _user(_text('Fix the retry test\nand explain why it was flaky')) +
          _assistant('Done.') +
          _user(_text('Now  add a   regression test\nfor the parser'));
      expect(parseOmpSessionName(head: '', tail: tail).lastPrompt, 'Now add a regression test');
    });

    test('accepts a plain string and skips images and the agent\'s own messages', () {
      final tail = _user('Rotate the staging certificates') +
          _user([
            {'type': 'image', 'data': 'AAAA'},
          ]) +
          _assistant('Rotated.');
      expect(parseOmpSessionName(head: '', tail: tail).lastPrompt, 'Rotate the staging certificates');
    });

    test('a slash command or a system note says nothing about the work: the one before stays', () {
      final tail = _user(_text('Profile the training step')) +
          _user(_text('/compact')) +
          _user(_text('<system-reminder>be brief</system-reminder>'));
      expect(parseOmpSessionName(head: '', tail: tail).lastPrompt, 'Profile the training step');
    });

    test('is cut to at most $ompPromptChars characters with an ellipsis, on a character boundary', () {
      final long = 'Hà Nội ' * 20;
      final p = parseOmpSessionName(head: '', tail: _user(_text(long))).lastPrompt!;
      expect(p.runes.length, lessThanOrEqualTo(ompPromptChars));
      expect(p.runes.length, greaterThan(ompPromptChars - 4), reason: 'only a trailing space is given up');
      expect(p, endsWith('\u2026'));
      expect(p, isNot(contains(' \u2026')));
      expect(p, startsWith('Hà Nội Hà Nội'));
    });

    test('the head is not searched for prompts: its messages are the beginning, not the last', () {
      final head = _user(_text('The very first message'));
      expect(parseOmpSessionName(head: head, tail: '').lastPrompt, isNull);
    });

    test('the first line of a tail that starts mid-file is a fragment and is dropped', () {
      final whole = _user(_text('A complete message'));
      final fragment = whole.substring(whole.length ~/ 2); // the second half of a record
      final tail = fragment + _user(_text('The real last one'));
      final withFlag = parseOmpSessionName(head: '', tail: tail, tailStartsMidLine: true);
      expect(withFlag.lastPrompt, 'The real last one');
    });
  });

  test('lines that are not JSON, or not objects, are skipped, not fatal', () {
    final text = 'not json\n[1,2]\n"x"\n${_line({'type': 'title', 'title': 'Survivor'})}{"type":"messa';
    final name = parseOmpSessionName(head: text, tail: text);
    expect(name.title, 'Survivor');
    expect(name.lastPrompt, isNull);
  });
}
