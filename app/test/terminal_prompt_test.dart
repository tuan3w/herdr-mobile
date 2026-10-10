// What a message with pictures and files is, typed into an agent's terminal.
//
// Captured with real agents (Claude Code 2.1.296, Codex 0.153.4, herdr 0.9.3;
// fixtures `claude_logs/image-paste.jsonl`, `codex_logs/image-paste.jsonl`),
// pasting the absolute path of a JPEG with `pane.send_input` (no keys), then
// ` what colour is this picture?` + enter:
//
// (a) The pane shows `[Image #1]` after the lone paste: Claude yes
//     (`❯ [Image #1]`), Codex yes (`› [Image #1]`).
// (b) The answer names red: Claude yes, Codex yes.
// (c) Claude's log: ONE user line whose content is
//     `[{type: text, text: "[Image #1] what colour is this picture?"},
//       {type: image, source: {type: base64, media_type: image/jpeg, data}}]`,
//     then a second `isMeta` user line `[Image: source: /path]` that the mapper
//     must skip. Codex's `UserMessage` item: `[{type: local_image, path},
//     {type: text, text: "[Image #1]  what colour…"}]` (Codex adds its own
//     space after the placeholder, so ours makes two).
// (d) Claude sent the line at once (0 ms) loses the picture: the line is
//     submitted before the image attaches and the agent says no image came
//     through. 100, 250 (4 runs) and 500 ms work; Codex works at 0. The
//     settle stays 250 ms ([pasteSettle]).
// A file `@path` inside the project folder is read by Claude without a
// permission prompt, outside it as well (manual mode); a bare absolute path
// without `@` is not read. Claude's own Read of a file in `~/.herdr-mobile/inbox`
// does prompt (`prompts/claude/approval-read-outside`).
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/repositories/terminal_prompt.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';

ResourceLinkBlock _link(String path, {String? name}) =>
    ResourceLinkBlock(uri: Uri.file(path, windows: false).toString(), name: name ?? path);

/// Records when each request was made.
class _Timed extends FakeTransport {
  final stamps = <Duration>[];
  final _clock = Stopwatch()..start();

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) {
    stamps.add(_clock.elapsed);
    return super.request(method, params);
  }
}

void main() {
  group('terminalPrompt', () {
    test('a picture is pasted alone and the text follows with a leading space', () {
      final p = terminalPrompt([const TextBlock('what is this?'), _link('/home/dev/.herdr-mobile/inbox/ab/IMG_1.jpg')])!;
      expect(p.pastes, ['/home/dev/.herdr-mobile/inbox/ab/IMG_1.jpg']);
      expect(p.line, ' what is this?');
    });

    test('a picture alone has an empty line', () {
      final p = terminalPrompt([_link('/h/inbox/a.PNG')])!;
      expect(p.pastes, ['/h/inbox/a.PNG'], reason: 'the extension is read in lower case');
      expect(p.line, '');
    });

    test('a file inside the folder is an @mention after the text, one outside is @ and its absolute path', () {
      final p = terminalPrompt([
        const TextBlock('read'),
        _link('/work/app/lib/a.dart', name: 'lib/a.dart'),
        _link('/home/dev/.herdr-mobile/inbox/ab/report.pdf'),
      ])!;
      expect(p.pastes, isEmpty);
      expect(p.line, 'read @lib/a.dart @/home/dev/.herdr-mobile/inbox/ab/report.pdf');
    });

    test('a path with whitespace is quoted after the @', () {
      final p = terminalPrompt([
        _link('/work/a b/c.txt', name: 'a b/c.txt'),
        _link('/x y/z'),
      ])!;
      expect(p.line, '@"a b/c.txt" @"/x y/z"');
    });

    test('several pictures are pasted in order', () {
      final p = terminalPrompt([_link('/i/1.jpg'), const TextBlock('both'), _link('/i/2.jpeg')])!;
      expect(p.pastes, ['/i/1.jpg', '/i/2.jpeg']);
      expect(p.line, ' both');
    });

    test('text alone is the text, joined by newlines, with no leading space', () {
      final p = terminalPrompt([const TextBlock('one'), const TextBlock('two')])!;
      expect(p.pastes, isEmpty);
      expect(p.line, 'one\ntwo');
    });

    test('what cannot be typed gives null', () {
      expect(terminalPrompt([const ImageBlock(data: 'AAAA', mimeType: 'image/png')]), isNull);
      expect(terminalPrompt([const EmbeddedResourceBlock(uri: 'file:///a.txt', text: 'x')]), isNull);
      expect(terminalPrompt([const ResourceLinkBlock(uri: 'https://example.com/a.png', name: 'a.png')]), isNull);
    });

    test('a name no mention can carry is refused whole: a quote, a newline, a control character', () {
      for (final name in ['say "hi".txt', 'a\nb.txt', 'a\tb.txt', 'a\u0007b.txt']) {
        expect(terminalPrompt([const TextBlock('read'), _link('/work/x.txt', name: name)]), isNull, reason: name.codeUnits.toString());
      }
      // A picture's path is pasted: the same rule on the path itself.
      expect(terminalPrompt([_link('/i/a\nb.jpg')]), isNull);
      expect(terminalPrompt([_link('/i/say "hi".jpg')]), isNull);
    });

    test('a file-only message starts with @, never with a slash an agent would take for a command', () {
      final p = terminalPrompt([_link('/home/dev/.herdr-mobile/inbox/ab/report.pdf')])!;
      expect(p.line, startsWith('@'));
    });
  });

  group('sendTerminalPrompt', () {
    test('a picture and text: the path alone, then after the settle the line and enter', () async {
      final t = _Timed();
      const settle = Duration(milliseconds: 60);
      await sendTerminalPrompt(
        HerdrApi(t),
        'w1:p1',
        const TerminalPrompt(pastes: ['/i/a.jpg'], line: ' look'),
        settle: settle,
      );

      expect(t.calls.map((c) => c.$1), ['pane.send_input', 'pane.send_input']);
      expect(t.calls[0].$2, {'pane_id': 'w1:p1', 'text': '/i/a.jpg'}, reason: 'no keys: a paste, not a line');
      expect(t.calls[1].$2, {'pane_id': 'w1:p1', 'text': ' look', 'keys': ['enter']});
      expect(t.stamps[1] - t.stamps[0], greaterThanOrEqualTo(settle));
    });

    test('a picture alone: the second call is enter with no text field', () async {
      final t = _Timed();
      await sendTerminalPrompt(
        HerdrApi(t),
        'w1:p1',
        const TerminalPrompt(pastes: ['/i/a.jpg'], line: ''),
        settle: Duration.zero,
      );
      expect(t.calls[1].$2, {'pane_id': 'w1:p1', 'keys': ['enter']});
    });

    test('text alone is one call and no delay', () async {
      final t = _Timed();
      await sendTerminalPrompt(HerdrApi(t), 'w1:p1', const TerminalPrompt(line: 'hello'));
      expect(t.calls, hasLength(1));
      expect(t.calls.single.$2, {'pane_id': 'w1:p1', 'text': 'hello', 'keys': ['enter']});
    });
  });
}
