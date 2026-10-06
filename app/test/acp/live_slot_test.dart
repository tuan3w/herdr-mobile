// The live slot of AgentSessionState: a chunk for the streaming message grows
// its LiveText in place and leaves the item list alone. The reducer must still
// give exactly the transcript a copy per chunk gives; the reference below is
// that old reducer (message handling only, through the public constructor).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/live_text.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

// -- the reference: the reducer as it was, one copy of the list per chunk ------

AgentSessionState _copyOf(AgentSessionState s, {List<TranscriptItem>? items, int? nextKey, int? echoed}) =>
    AgentSessionState(
      s.sessionId,
      items: items ?? s.items,
      plan: s.plan,
      commands: s.commands,
      modes: s.modes,
      configOptions: s.configOptions,
      title: s.title,
      updatedAt: s.updatedAt,
      usage: s.usage,
      pending: s.pending,
      turnActive: s.turnActive,
      cancelRequested: s.cancelRequested,
      runState: s.runState,
      lastStopReason: s.lastStopReason,
      disconnected: s.disconnected,
      nextKey: nextKey ?? s.nextKey,
      echoed: echoed ?? s.echoed,
      lastActivityAt: s.lastActivityAt,
      turnUsage: s.turnUsage,
      turnMeta: s.turnMeta,
      infoMeta: s.infoMeta,
    );

int _find(AgentSessionState s, MessageRole role, String? id) {
  final items = s.items;
  if (id != null) {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is TranscriptMessage && it.role == role && it.messageId == id) return i;
    }
    return -1;
  }
  if (items.isEmpty) return -1;
  final last = items.last;
  return last is TranscriptMessage && last.role == role && !last.local ? items.length - 1 : -1;
}

List<ContentBlock> _appendBlock(List<ContentBlock> blocks, ContentBlock next) {
  if (blocks.isNotEmpty && next is TextBlock && next.meta == null) {
    final last = blocks.last;
    if (last is TextBlock && last.meta == null) {
      return [...blocks.sublist(0, blocks.length - 1), TextBlock(last.text + next.text)];
    }
  }
  return [...blocks, next];
}

/// `AgentSessionState.apply` for message chunks as it was before the live
/// slot; every other update goes to the real reducer (a state that never holds
/// a live message makes it behave as it always did).
AgentSessionState referenceApply(AgentSessionState s, SessionUpdate u) {
  if (u is! MessageChunk) return s.apply(u);
  if (u.role == MessageRole.user && s.items.isNotEmpty) {
    final last = s.items.last;
    final block = u.content;
    if (last is TranscriptMessage && last.local && block is TextBlock) {
      final text = last.text;
      if (text.isNotEmpty && text.startsWith(block.text, s.echoed)) {
        final matched = s.echoed + block.text.length;
        if (matched < text.length) return _copyOf(s, echoed: matched);
        final items = List<TranscriptItem>.of(s.items);
        items[items.length - 1] = TranscriptMessage(
          key: last.key,
          role: last.role,
          messageId: u.messageId ?? last.messageId,
          blocks: last.blocks,
        );
        return _copyOf(s, items: items, echoed: 0);
      }
    }
  }
  final at = _find(s, u.role, u.messageId);
  if (at < 0) {
    return _copyOf(
      s,
      items: [
        ...s.items,
        TranscriptMessage(key: 'm${s.nextKey}', role: u.role, messageId: u.messageId, blocks: [u.content]),
      ],
      nextKey: s.nextKey + 1,
    );
  }
  final m = s.items[at] as TranscriptMessage;
  final items = List<TranscriptItem>.of(s.items);
  items[at] = TranscriptMessage(
    key: m.key,
    role: m.role,
    messageId: u.messageId ?? m.messageId,
    blocks: _appendBlock(m.blocks, u.content),
    local: m.local,
  );
  return _copyOf(s, items: items);
}

/// The two states hold the same transcript.
void expectSameTranscript(AgentSessionState live, AgentSessionState reference, String where) {
  expect(live.items.length, reference.items.length, reason: '$where: item count');
  for (var i = 0; i < live.items.length; i++) {
    final a = live.items[i];
    final b = reference.items[i];
    expect(a.key, b.key, reason: '$where: key of item $i');
    expect(a.runtimeType, b.runtimeType, reason: '$where: kind of item $i');
    if (a is TranscriptMessage && b is TranscriptMessage) {
      expect(a.role, b.role, reason: '$where: role of ${a.key}');
      expect(a.messageId, b.messageId, reason: '$where: id of ${a.key}');
      expect(a.local, b.local, reason: '$where: local of ${a.key}');
      expect(a.text, b.text, reason: '$where: text of ${a.key}');
      expect(a.blocks.length, b.blocks.length, reason: '$where: blocks of ${a.key}');
      for (var k = 0; k < a.blocks.length; k++) {
        final x = a.blocks[k];
        final y = b.blocks[k];
        expect(x.runtimeType, y.runtimeType, reason: '$where: block $k of ${a.key}');
        if (x is TextBlock && y is TextBlock) {
          expect(x.text, y.text, reason: '$where: text of block $k of ${a.key}');
          expect(x.meta, y.meta);
        }
      }
    }
  }
  expect(live.nextKey, reference.nextKey, reason: '$where: nextKey');
  expect(live.echoed, reference.echoed, reason: '$where: echoed');
  expect(live.turnActive, reference.turnActive, reason: '$where: turnActive');
  expect(live.lastStopReason, reference.lastStopReason, reason: '$where: lastStopReason');
}

MessageChunk _chunk(String text, {String? id = 'a1', MessageRole role = MessageRole.agent}) =>
    MessageChunk(role, id, TextBlock(text));

void main() {
  group('LiveText', () {
    test('appends, joins on demand, and counts versions', () {
      final t = LiveText('ab');
      expect(t.text, 'ab');
      expect(t.length, 2);
      expect(t.version, 1);
      t
        ..append('')
        ..append('cd')
        ..append('ef');
      expect(t.version, 3, reason: 'an empty piece is not an append');
      expect(t.length, 6);
      expect(t.text, 'abcdef');
      expect(t.text, 'abcdef');
      t.append('g');
      expect(t.text, 'abcdefg');
      expect(LiveText().text, '');
    });

    test('tail reads only what grew, across pieces, joined or not', () {
      final t = LiveText('hello ');
      final seen = t.length;
      t
        ..append('wor')
        ..append('ld')
        ..append('!');
      expect(t.tail(seen), 'world!');
      expect(t.tail(t.length), '');
      expect(t.tail(0), 'hello world!');
      expect(t.tail(8), 'rld!');
      t.text; // joined into one piece
      expect(t.tail(seen), 'world!');
      t.append('?');
      expect(t.tail(t.length - 1), '?');
      expect(() => t.tail(-1), throwsRangeError);
      expect(() => t.tail(t.length + 1), throwsRangeError);
    });

    test('listeners hear a flush once, not an append', () {
      final t = LiveText();
      var heard = 0;
      void listener() => heard++;
      t.addListener(listener);
      t
        ..append('a')
        ..append('b');
      expect(heard, 0);
      expect(t.dirty, isTrue);
      t.flush();
      expect(heard, 1);
      expect(t.dirty, isFalse);
      t.flush();
      expect(heard, 1, reason: 'nothing new, nothing said');
      t.append('c');
      t.removeListener(listener);
      t.flush();
      expect(heard, 1);
    });

    test('a listener that leaves during a flush is not called after it left', () {
      final t = LiveText();
      var second = 0;
      late void Function() b;
      void a() => t.removeListener(b);
      b = () => second++;
      t
        ..addListener(a)
        ..addListener(b)
        ..append('x')
        ..flush();
      expect(second, 0);
    });
  });

  group('the live slot', () {
    test('the first chunk makes a live message; the next ones keep the list instance', () {
      var s = const AgentSessionState('s').apply(_chunk('Hello'));
      final items = s.items;
      final live = s.liveMessage!.live!;
      expect(s.liveKey, 'm0');
      expect(s.liveTextOf('m0'), same(live));
      expect(s.liveTextOf('m1'), isNull);

      for (var i = 0; i < 50; i++) {
        final next = s.apply(_chunk(' w$i'));
        expect(identical(next.items, items), isTrue, reason: 'chunk $i did not copy the list');
        expect(identical(next, s), isFalse, reason: 'a change is still a new state');
        s = next;
      }
      expect(s.liveMessage!.live, same(live));
      expect(s.items.single, isA<TranscriptMessage>());
      final m = s.items.single as TranscriptMessage;
      expect(m.text, startsWith('Hello w0 w1 w2'));
      expect((m.blocks.single as TextBlock).text, m.text);
      expect(live.text, m.text);
    });

    test('blocks and text of a live message are the text so far', () {
      var s = const AgentSessionState('s').apply(_chunk('a'));
      final m = s.items.single as TranscriptMessage;
      s = s.apply(_chunk('b'));
      expect(m.text, 'ab', reason: 'the same message object grew');
      expect(m.blocks, hasLength(1));
      expect((m.blocks.single as TextBlock).text, 'ab');
    });

    test('a new message, a tool, a stop and a user prompt settle the live message', () {
      var s = const AgentSessionState('s').apply(_chunk('one'));
      final first = s.liveMessage!;
      s = s.apply(_chunk('two', id: 'a2'));
      expect(s.liveKey, 'm1');
      final settled = s.items.first as TranscriptMessage;
      expect(settled.live, isNull);
      expect(settled.text, 'one');
      expect(identical(settled, first), isFalse);
      expect(first.text, 'one', reason: 'the old object keeps its text');

      s = s.apply(ToolCallStart(ToolCall(toolCallId: 't1', title: 'Read')));
      expect(s.liveKey, isNull);
      expect((s.items[1] as TranscriptMessage).live, isNull);
      expect((s.items[1] as TranscriptMessage).text, 'two');

      s = s.apply(_chunk('three', id: 'a3'));
      expect(s.liveKey, 'm2');
      s = s.withUserMessage([const TextBlock('next')]);
      expect(s.liveKey, isNull);
      expect(s.items.whereType<TranscriptMessage>().every((m) => m.live == null), isTrue);
    });

    test('the turn ending, a disconnect and an upsert settle it', () {
      AgentSessionState live() => const AgentSessionState('s').apply(_chunk('text')).withTurnStarted();
      final ended = live().withTurnEnded(StopReason.endTurn);
      expect(ended.liveKey, isNull);
      expect((ended.items.single as TranscriptMessage).text, 'text');
      expect(live().apply(const StateUpdate(AgentRunState.idle, StopReason.endTurn)).liveKey, isNull);
      expect(live().withDisconnected().liveKey, isNull);

      final upserted = live().apply(const MessageUpsert(MessageRole.agent, 'a1', hasContent: true, content: [TextBlock('new')]));
      expect(upserted.liveKey, isNull);
      expect((upserted.items.single as TranscriptMessage).text, 'new');
      final kept = live().apply(const MessageUpsert(MessageRole.agent, 'a1', hasContent: false));
      expect(kept.liveKey, 'm0', reason: 'an upsert without content changes nothing');
    });

    test('updates of other things keep the live message and the list', () {
      final s = const AgentSessionState('s').apply(_chunk('x'));
      final items = s.items;
      final next = s.apply(const PlanUpdate([])).apply(const UnknownUpdate('u', {}), at: DateTime.utc(2026));
      expect(next.liveKey, 'm0');
      expect(identical(next.items, items), isTrue);
    });

    test('a chunk for an earlier message moves the live slot there, once', () {
      var s = const AgentSessionState('s')
          .apply(_chunk('first ', id: 'a1'))
          .apply(ToolCallStart(ToolCall(toolCallId: 't1', title: 'Read')))
          .apply(_chunk('second ', id: 'a2'));
      expect(s.liveKey, 'm1');
      // omp reuses one id across a tool call: the text continues the first message.
      s = s.apply(_chunk('more', id: 'a1'));
      expect(s.liveKey, 'm0');
      final items = s.items;
      s = s.apply(_chunk(' and more', id: 'a1'));
      expect(identical(s.items, items), isTrue);
      expect((s.items[0] as TranscriptMessage).text, 'first more and more');
      expect((s.items[2] as TranscriptMessage).live, isNull);
      expect((s.items[2] as TranscriptMessage).text, 'second ');
    });

    test('chunks that are not plain text end the live text and the next plain chunk starts one', () {
      var s = const AgentSessionState('s').apply(_chunk('look: '));
      s = s.apply(const MessageChunk(MessageRole.agent, 'a1', ImageBlock(data: 'AA', mimeType: 'image/png')));
      expect(s.liveKey, isNull);
      var m = s.items.single as TranscriptMessage;
      expect(m.blocks.map((b) => b.runtimeType), [TextBlock, ImageBlock]);

      s = s.apply(_chunk('caption'));
      expect(s.liveKey, 'm0');
      s = s.apply(_chunk(' text'));
      m = s.items.single as TranscriptMessage;
      expect(m.blocks.map((b) => b.runtimeType), [TextBlock, ImageBlock, TextBlock]);
      expect((m.blocks.last as TextBlock).text, 'caption text');

      s = s.apply(const MessageChunk(MessageRole.agent, 'a1', TextBlock('tagged', meta: {'k': 1})));
      m = s.items.single as TranscriptMessage;
      expect(m.blocks, hasLength(4), reason: 'text with _meta never merges');
      s = s.apply(_chunk('after'));
      m = s.items.single as TranscriptMessage;
      expect(m.blocks, hasLength(5), reason: 'and nothing merges into it');
    });

    test('a message that was built from history goes live on its first chunk', () {
      final history = TranscriptMessage(key: 'h', role: MessageRole.agent, messageId: 'a1', blocks: const [TextBlock('past ')]);
      var s = AgentSessionState('s', items: [history]);
      expect(s.liveKey, isNull);
      s = s.apply(_chunk('and now'));
      expect(s.liveKey, 'h');
      expect((s.items.single as TranscriptMessage).text, 'past and now');
      expect(history.text, 'past ', reason: 'the history message is untouched');
    });

    test('the echo of the prompt is dropped, and the agent reply after it streams live', () {
      var s = const AgentSessionState('s').withUserMessage([const TextBlock('fix it')]).withTurnStarted();
      s = s.apply(_chunk('fix ', id: 'u1', role: MessageRole.user)).apply(_chunk('it', id: 'u1', role: MessageRole.user));
      expect(s.items, hasLength(1));
      expect((s.items.single as TranscriptMessage).local, isFalse);
      s = s.apply(_chunk('ok')).apply(_chunk(' done'));
      expect(s.items, hasLength(2));
      expect((s.items.last as TranscriptMessage).text, 'ok done');
      expect(s.liveKey, 'm1');
    });
  });

  group('the live slot gives the transcript a copy per chunk gives', () {
    final root = Directory('test/fixtures/traces');

    // A trace as the client sees it: the agent's updates, and what the client
    // did (the prompt it sent, the response that ended the turn).
    List<Object> eventsOf(File file) {
      final out = <Object>[];
      Object? promptId;
      for (final row in const LineSplitter().convert(file.readAsStringSync())) {
        if (row.trim().isEmpty) continue;
        final j = jsonDecode(row) as Map<String, dynamic>;
        final msg = j['msg'] as Map<String, dynamic>;
        final received = j['dir'] == 'recv';
        if (!received && msg['method'] == 'session/prompt') {
          promptId = msg['id'];
          final prompt = (msg['params'] as Map)['prompt'] as List;
          out.add(prompt.map((b) => (b as Map)['text'] ?? '').join());
        } else if (received && msg['method'] == 'session/update') {
          final update = (msg['params'] as Map)['update'];
          out.add(SessionUpdate.parse(update));
        } else if (received && promptId != null && msg['id'] == promptId && msg.containsKey('result')) {
          final reason = (msg['result'] as Map)['stopReason'] as String?;
          out.add(StopReason.parse(reason));
          promptId = null;
        }
      }
      return out;
    }

    final traces = root.existsSync()
        ? (root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
        : <File>[];

    test('there are traces to check', () => expect(traces, isNotEmpty));

    for (final file in traces) {
      final name = file.uri.pathSegments.sublist(file.uri.pathSegments.length - 2).join('/');
      test('$name: same transcript after every event, final text equal', () {
        var live = const AgentSessionState('s');
        var reference = const AgentSessionState('s');
        var step = 0;
        var chunks = 0;
        var listCopies = 0;
        for (final event in eventsOf(file)) {
          step++;
          final before = live.items;
          switch (event) {
            case SessionUpdate():
              if (event is MessageChunk) chunks++;
              live = live.apply(event);
              reference = referenceApply(reference, event);
            case String():
              live = live.withUserMessage([TextBlock(event)]).withTurnStarted();
              reference = reference.withUserMessage([TextBlock(event)]).withTurnStarted();
            case StopReason():
              live = live.withTurnEnded(event);
              reference = reference.withTurnEnded(event);
          }
          if (!identical(before, live.items)) listCopies++;
          expectSameTranscript(live, reference, '$name step $step');
        }
        expect(live.liveKey, isNull, reason: 'the turn ended: nothing is live');
        if (chunks > 20) {
          expect(listCopies, lessThan(step), reason: 'chunks of the streaming message did not copy the list');
        }
        final texts = [for (final m in live.items.whereType<TranscriptMessage>()) m.text];
        final expected = [for (final m in reference.items.whereType<TranscriptMessage>()) m.text];
        expect(texts, expected);
      });
    }

    test('random sequences of updates give the same transcript', () {
      for (var seed = 0; seed < 60; seed++) {
        final random = Random(seed);
        var live = const AgentSessionState('s');
        var reference = const AgentSessionState('s');
        void both(AgentSessionState Function(AgentSessionState s, bool ref) f) {
          live = f(live, false);
          reference = f(reference, true);
        }

        for (var step = 0; step < 200; step++) {
          final id = [null, 'a1', 'a2'][random.nextInt(3)];
          final role = MessageRole.values[random.nextInt(3)];
          final text = String.fromCharCodes([for (var i = 0; i < random.nextInt(6); i++) 97 + random.nextInt(26)]);
          final tool = 't${random.nextInt(3)}';
          final hasContent = random.nextBool();
          switch (random.nextInt(14)) {
            case 0:
              both((s, ref) => s.withUserMessage([TextBlock(text)]));
            case 1:
              both((s, ref) => s.apply(ToolCallStart(ToolCall(toolCallId: tool, title: text))));
            case 2:
              both((s, ref) => s.apply(MessageChunk(role, id, ImageBlock(data: text, mimeType: 'image/png'))));
            case 3:
              both((s, ref) => s.apply(MessageChunk(role, id, TextBlock(text, meta: const {'m': 1}))));
            case 4:
              both((s, ref) => s.apply(MessageUpsert(role, id ?? 'a1', hasContent: hasContent, content: [TextBlock(text)])));
            case 5:
              both((s, ref) => s.withTurnEnded(StopReason.endTurn));
            case 6:
              both((s, ref) => s.withTurnStarted());
            case 7:
              both((s, ref) => s.withDisconnected());
            default:
              final update = MessageChunk(role, id, TextBlock(text));
              both((s, ref) => ref ? referenceApply(s, update) : s.apply(update));
          }
          expectSameTranscript(live, reference, 'seed $seed step $step');
        }
      }
    });
  });

  group('cost of a chunk', () {
    // 20 KB in 120-character chunks into a transcript of N items: the copy per
    // chunk of the old reducer grows with N, the live slot does not. The numbers
    // are printed, not asserted (timing); what is asserted is structure.
    AgentSessionState history(int n) => AgentSessionState('s', items: [
          for (var i = 0; i < n; i++)
            i.isEven
                ? TranscriptMessage(key: 'h$i', role: MessageRole.user, blocks: [TextBlock('prompt $i')])
                : TranscriptMessage(key: 'h$i', role: MessageRole.agent, messageId: 'h$i', blocks: [TextBlock('answer $i')]),
        ], nextKey: n);

    final text = List.generate(167, (i) => 'word${i % 10} ' * 20).join().substring(0, 20000);
    final chunks = [for (var i = 0; i < text.length; i += 120) text.substring(i, min(i + 120, text.length))];

    double perChunkUs(AgentSessionState start, AgentSessionState Function(AgentSessionState, SessionUpdate) step) {
      var s = start;
      final watch = Stopwatch()..start();
      for (final c in chunks) {
        s = step(s, MessageChunk(MessageRole.agent, 'big', TextBlock(c)));
      }
      watch.stop();
      expect((s.items.last as TranscriptMessage).text, text);
      return watch.elapsedMicroseconds / chunks.length;
    }

    test('the live slot does not copy the list per chunk, whatever its length', () {
      final report = StringBuffer('per chunk, microseconds (20 KB in ${chunks.length} chunks of 120):\n');
      for (final n in [200, 2000, 8000]) {
        final start = history(n);
        // warm up both paths
        perChunkUs(start, (s, u) => s.apply(u));
        perChunkUs(start, referenceApply);
        final oldUs = perChunkUs(start, referenceApply);
        final newUs = perChunkUs(start, (s, u) => s.apply(u));
        report.writeln('  $n items: old ${oldUs.toStringAsFixed(1)}  new ${newUs.toStringAsFixed(1)}');

        var s = start.apply(MessageChunk(MessageRole.agent, 'big', TextBlock(chunks.first)));
        final items = s.items;
        for (final c in chunks.skip(1)) {
          s = s.apply(MessageChunk(MessageRole.agent, 'big', TextBlock(c)));
          expect(identical(s.items, items), isTrue);
        }
      }
      // ignore: avoid_print
      print(report);
    });
  });
}
