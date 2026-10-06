// The client-side queue (what waits while the agent works), the blocks of a
// rich prompt, and the detection of "sign in on the host".
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/auth_needed.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/prompt_content.dart';
import 'package:herdr_mobile/data/acp/prompt_queue.dart';

final _t = DateTime.utc(2026, 10, 5, 12);

List<ContentBlock> _text(String s) => [TextBlock(s)];

void main() {
  group('PromptQueue', () {
    test('keeps the order messages were sent in, and hands out the oldest waiting one', () {
      final q = PromptQueue();
      final a = q.add(_text('one'), at: _t);
      final b = q.add(_text('two'), at: _t);
      expect(q.entries.map((e) => e.text), ['one', 'two']);
      expect(q.firstWaiting!.id, a.id);
      expect(a.id, isNot(b.id));

      q.remove(a.id);
      expect(q.firstWaiting!.id, b.id);
    });

    test('a message that was about to go and could not returns to the front', () {
      final q = PromptQueue();
      q.add(_text('later'), at: _t);
      q.add(_text('first, refused'), at: _t, state: QueuedState.held, heldReason: 'busy', first: true);
      expect(q.entries.map((e) => e.text), ['first, refused', 'later']);
      expect(q.firstWaiting!.text, 'later', reason: 'a held message does not go by itself');
    });

    test('edit replaces the text and keeps the attachments and the place', () {
      final q = PromptQueue();
      final image = const ImageBlock(data: 'AAAA', mimeType: 'image/jpeg');
      final a = q.add([const TextBlock('look at this'), image], at: _t);
      q.add(_text('after'), at: _t);

      expect(q.edit(a.id, 'look at this, closely'), isTrue);

      expect(q.entries.first.id, a.id);
      expect(q.entries.first.text, 'look at this, closely');
      expect(q.entries.first.attachments, [image]);
      expect(q.entries.first.blocks.first, isA<TextBlock>(), reason: 'text first, then attachments');
    });

    test('a blank edit of a message with nothing else changes nothing; with an attachment the text may go', () {
      final q = PromptQueue();
      final plain = q.add(_text('keep me'), at: _t);
      final withImage = q.add([const TextBlock('x'), const ImageBlock(data: 'AAAA', mimeType: 'image/png')], at: _t);

      expect(q.edit(plain.id, '   '), isFalse);
      expect(q.entries.first.text, 'keep me');
      expect(q.edit(withImage.id, ''), isTrue);
      expect(q.entries.last.blocks.single, isA<ImageBlock>());
      expect(q.edit('nope', 'x'), isFalse);
    });

    test('remove drops one message and says whether it was there', () {
      final q = PromptQueue();
      final a = q.add(_text('one'), at: _t);
      expect(q.remove(a.id), isTrue);
      expect(q.remove(a.id), isFalse);
      expect(q.isEmpty, isTrue);
    });

    test('holdAll holds what waits, release lets it go in the same order', () {
      final q = PromptQueue();
      q.add(_text('one'), at: _t);
      q.add(_text('two'), at: _t);
      expect(q.hasWaiting, isTrue);

      expect(q.holdAll('stopped'), isTrue);
      expect(q.hasWaiting, isFalse);
      expect(q.firstWaiting, isNull);
      expect(q.entries.every((e) => e.held && e.heldReason == 'stopped'), isTrue);
      expect(q.holdAll('again'), isFalse, reason: 'nothing waits: nothing changes');

      expect(q.release(), isTrue);
      expect(q.entries.map((e) => e.text), ['one', 'two']);
      expect(q.entries.every((e) => !e.held && e.heldReason == null), isTrue);
      expect(q.release(), isFalse);
    });

    test('a change makes a new list, so a screen can tell by identity', () {
      final q = PromptQueue();
      final empty = q.entries;
      final a = q.add(_text('one'), at: _t);
      final one = q.entries;
      expect(identical(empty, one), isFalse);
      q.edit(a.id, 'one!');
      expect(identical(one, q.entries), isFalse);
      expect(one.single.text, 'one', reason: 'the old list did not change under a reader');
    });
  });

  group('file mentions', () {
    test('a link names the repo-relative path and carries the absolute file:// uri, with no title', () {
      final b = fileLinkBlock('/home/dev/app/lib/main.dart', cwd: '/home/dev/app');
      expect(b.name, 'lib/main.dart', reason: 'omp keeps only title ?? name ?? uri; codex shows the name');
      expect(b.uri, 'file:///home/dev/app/lib/main.dart', reason: 'pi and Claude Code keep only the uri');
      expect(b.title, isNull, reason: 'a title would hide the path in omp');
      expect(b.toJson()['type'], 'resource_link');
    });

    test('a path outside the folder keeps its absolute path as the name; a trailing slash on the folder is fine', () {
      expect(fileLinkBlock('/etc/hosts', cwd: '/home/dev/app').name, '/etc/hosts');
      expect(fileLinkBlock('/home/dev/app/a.txt', cwd: '/home/dev/app/').name, 'a.txt');
      expect(fileLinkBlock('/home/dev/application/a.txt', cwd: '/home/dev/app').name, '/home/dev/application/a.txt',
          reason: 'a sibling folder with the same prefix is not inside');
    });

    test('the uri is percent-encoded', () {
      expect(fileLinkBlock('/home/dev/my app/é.txt', cwd: '/home/dev/my app').uri, 'file:///home/dev/my%20app/%C3%A9.txt');
    });

    test('embedded text only when the agent takes it and the file is small; else a link', () {
      const path = '/home/dev/app/notes.md';
      final small = fileBlock(path, cwd: '/home/dev/app', text: 'hello', embeddedContext: true);
      expect(small, isA<EmbeddedResourceBlock>());
      expect((small as EmbeddedResourceBlock).text, 'hello');

      expect(fileBlock(path, cwd: '/home/dev/app', text: 'hello', embeddedContext: false), isA<ResourceLinkBlock>(),
          reason: 'the agent did not advertise embeddedContext');
      expect(fileBlock(path, cwd: '/home/dev/app', embeddedContext: true), isA<ResourceLinkBlock>(), reason: 'no text read');

      final big = 'x' * (maxEmbeddedBytes + 1);
      expect(fileBlock(path, cwd: '/home/dev/app', text: big, embeddedContext: true), isA<ResourceLinkBlock>());
      final atCap = 'x' * maxEmbeddedBytes;
      expect(fileBlock(path, cwd: '/home/dev/app', text: atCap, embeddedContext: true), isA<EmbeddedResourceBlock>());
      // Bytes count, not characters.
      final wide = 'é' * (maxEmbeddedBytes ~/ 2 + 1);
      expect(fileBlock(path, cwd: '/home/dev/app', text: wide, embeddedContext: true), isA<ResourceLinkBlock>());
    });

    test('composePrompt puts the text first, drops a blank one, and keeps the order of the attachments', () {
      final link = fileLinkBlock('/p/a.dart', cwd: '/p');
      const image = ImageBlock(data: 'AAAA', mimeType: 'image/jpeg');
      expect(composePrompt('see this', [link, image]), [isA<TextBlock>(), link, image]);
      expect(composePrompt('  ', [image]), [image]);
      expect(composePrompt('', const []), isEmpty);
    });
  });

  group('sign in on the host', () {
    test('ACP -32000 with a message about authentication', () {
      expect(isAuthRequired(const JsonRpcException(-32000, 'Authentication required')), isTrue);
      expect(isAuthRequired(const JsonRpcException(-32000, 'auth_required')), isTrue);
      expect(isAuthRequired(const JsonRpcException(-32000, 'Missing authorization header')), isTrue);
    });

    test('or carrying authMethods in the data (pi-acp\'s authRequired), or reason auth_required', () {
      expect(
        isAuthRequired(const JsonRpcException(-32000, 'Configure an API key or log in with an OAuth provider.', {
          'authMethods': [
            {'id': 'pi_terminal_login'},
          ],
        })),
        isTrue,
      );
      expect(isAuthRequired(const JsonRpcException(-32000, 'nope', {'reason': 'auth_required'})), isTrue);
    });

    test('the same code for another reason is not an auth failure (the keeper uses -32000 too)', () {
      expect(isAuthRequired(const JsonRpcException(-32000, 'The client went away before it answered.')), isFalse);
      expect(isAuthRequired(const JsonRpcException(-32000, 'No client is attached to answer fs/read_text_file.')), isFalse);
      expect(isAuthRequired(const JsonRpcException(-32603, 'Authentication required')), isFalse, reason: 'another code');
      expect(isAuthRequired(StateError('x')), isFalse);
      expect(isAuthRequired(null), isFalse);
    });

    // pi-acp `auth.ts` (source only, no trace: UNVERIFIED live).
    final piMethods = [
      {
        'id': 'pi_terminal_login',
        'name': 'Launch pi in the terminal',
        'description': 'Start pi in an interactive terminal to configure API keys or login',
        'type': 'terminal',
        'args': ['--terminal-login'],
        'env': <String, Object?>{},
        '_meta': {
          'terminal-auth': {
            'command': 'pi-acp',
            'args': ['--terminal-login'],
            'label': 'Launch pi',
          },
        },
      },
    ];

    test('methods come from the error data first, with the terminal hint', () {
      final need = authNeededFrom(
        JsonRpcException(-32000, 'Configure an API key.', {'authMethods': piMethods}),
        agentLabel: 'pi',
        advertised: const [
          {'id': 'other', 'name': 'Other'},
        ],
      );
      expect(need.message, 'pi needs you to sign in on the host.');
      expect(need.agentMessage, 'Configure an API key.');
      expect(need.methods.single.id, 'pi_terminal_login');
      expect(need.methods.single.terminal, isTrue);
      expect(need.methods.single.terminalLabel, 'Launch pi');
      expect(need.methods.single.terminalCommand, 'pi-acp --terminal-login');
      expect(need.terminalHint, isTrue);
    });

    test('else the methods advertised at initialize; agent-handled ones are not terminal', () {
      final need = authNeededFrom(
        const JsonRpcException(-32000, 'Authentication required'),
        agentLabel: 'Codex',
        advertised: const [
          {'id': 'api-key', 'name': 'API Key', 'description': 'Use an API key to authenticate'},
          {'id': 'chat-gpt', 'name': 'ChatGPT'},
        ],
      );
      expect(need.methods.map((m) => m.id), ['api-key', 'chat-gpt']);
      expect(need.methods.first.description, 'Use an API key to authenticate');
      expect(need.terminalHint, isFalse);
    });

    test('a spec terminal method (type: terminal) is a terminal hint even without _meta', () {
      final need = authNeededFrom(
        const JsonRpcException(-32000, 'Authentication required'),
        agentLabel: 'Claude Code',
        advertised: const [
          {'id': 'claude-login', 'name': 'Log in with Claude', 'type': 'terminal', 'args': ['--cli']},
        ],
      );
      expect(need.terminalHint, isTrue);
      expect(need.methods.single.terminalCommand, isNull);
    });

    test('odd shapes parse to nothing instead of throwing', () {
      expect(parseAuthChoices(null), isEmpty);
      expect(parseAuthChoices('x'), isEmpty);
      expect(parseAuthChoices([1, null, 'a']), isEmpty);
      final c = parseAuthChoices([<String, Object?>{}]).single;
      expect(c.id, '');
      expect(c.terminal, isFalse);
    });
  });
}
