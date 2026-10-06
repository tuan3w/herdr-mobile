import 'dart:async';
import 'dart:convert';

import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';

/// One end of an in-memory line link. Delivery is synchronous, like the
/// transports the app uses: a line sent by one end is handled by the other
/// end's listener before `send` returns.
class MemoryEnd implements AcpTransport {
  MemoryEnd() : _incoming = StreamController<String>(sync: true);

  final StreamController<String> _incoming;
  late final MemoryEnd peer;

  /// Every line this end sent.
  final sent = <String>[];
  var closed = false;

  @override
  Stream<String> get lines => _incoming.stream;

  @override
  void send(String line) {
    if (closed) throw StateError('transport is closed');
    sent.add(line);
    // A peer that is gone breaks the pipe.
    if (peer._incoming.isClosed) throw StateError('broken pipe');
    peer._incoming.add(line);
  }

  /// This end hangs up: the peer reads EOF, and so does this end's reader.
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(_incoming.close());
    unawaited(peer._incoming.close());
  }

  /// An error event on this end's reader (a corrupt frame on a real channel).
  void injectError(Object error) => _incoming.addError(error);

  /// This end's reader reads EOF while the peer's reader stays open: what a
  /// dead process looks like to the other side, or (called on the agent end)
  /// a pipe that broke only in one direction.
  void peerDied() {
    unawaited(_incoming.close());
  }
}

/// A client end and an agent end wired to each other.
class MemoryLink {
  MemoryLink() : client = MemoryEnd(), agent = MemoryEnd() {
    client.peer = agent;
    agent.peer = client;
  }

  final MemoryEnd client;
  final MemoryEnd agent;
}

typedef AgentMethod = FutureOr<Object?> Function(IncomingRequest request);

/// A scripted agent: [methods] answer the client's requests, `received`
/// records its notifications, and [update] / [ask] push things the way a real
/// agent does.
class FakeAgent {
  FakeAgent(MemoryEnd end, this.methods) {
    rpc = JsonRpcConnection(
      end,
      onRequest: (r) async {
        requests.add((r.method, r.params));
        final handler = methods[r.method];
        if (handler == null) throw JsonRpcException.methodNotFound(r.method);
        return handler(r);
      },
      onNotification: (m, p) => notifications.add((m, p)),
      onProblem: (m, {line}) => problems.add(m),
    );
  }

  late final JsonRpcConnection rpc;
  final Map<String, AgentMethod> methods;
  final requests = <(String, Object?)>[];
  final notifications = <(String, Object?)>[];
  final problems = <String>[];

  /// A `session/update` notification.
  void update(String sessionId, Json update) => rpc.notify('session/update', {'sessionId': sessionId, 'update': update});

  /// The agent calls the client.
  JsonRpcCall ask(String method, Object? params) => rpc.call(method, params);

  Iterable<Object?> paramsOf(String method) => [
    for (final (m, p) in [...requests, ...notifications])
      if (m == method) p,
  ];
}

/// `omp acp` (18.4.12), as captured: the `initialize` result.
Json ompInitialize() => {
  'protocolVersion': 1,
  'agentInfo': {'name': 'omp', 'title': 'omp', 'version': '18.4.12'},
  'authMethods': [
    {'id': 'agent', 'name': 'Use existing local credentials', 'description': 'Use the credentials omp already has.'},
  ],
  'agentCapabilities': {
    'loadSession': true,
    'mcpCapabilities': {'http': true, 'sse': true},
    'promptCapabilities': {'embeddedContext': true, 'image': true},
    'sessionCapabilities': {'list': {}, 'fork': {}, 'resume': {}, 'close': {}},
  },
};

/// `claude-agent-acp`'s `initialize` result, as the adapter builds it
/// (`acp-agent.ts:2660-2727`; shape read from source and its snapshots,
/// UNVERIFIED against a live process): top-level `_meta.steering`, and
/// `agentCapabilities._meta.claudeCode.promptQueueing`.
Json claudeInitialize({List<Json> authMethods = const []}) => {
  'protocolVersion': 1,
  'agentInfo': {'name': '@agentclientprotocol/claude-agent-acp', 'title': 'Claude Agent', 'version': '0.85.1'},
  'authMethods': authMethods,
  '_meta': {
    'steering': {'supported': true},
  },
  'agentCapabilities': {
    '_meta': {
      'claudeCode': {'promptQueueing': true},
    },
    'loadSession': true,
    'mcpCapabilities': {'http': true, 'sse': true},
    'promptCapabilities': {'image': true, 'embeddedContext': true},
    'sessionCapabilities': {'list': {}, 'resume': {}, 'close': {}, 'fork': {}},
  },
};

/// `codex-acp`'s `initialize` result (`CodexAcpServer.ts:455-470`; source
/// only, UNVERIFIED live): `_meta.steering`, no `claudeCode`.
Json codexInitialize() => {
  'protocolVersion': 1,
  'agentInfo': {'name': 'codex-acp', 'title': 'Codex', 'version': '2.1.1'},
  'authMethods': [
    {
      'id': 'api-key',
      'name': 'API Key',
      'description': 'Use an API key to authenticate',
      '_meta': {
        'api-key': {'provider': 'openai'},
      },
    },
    {'id': 'chat-gpt', 'name': 'ChatGPT', 'description': 'Use ChatGPT to authenticate'},
  ],
  '_meta': {
    'steering': {'supported': true},
  },
  'agentCapabilities': {
    'loadSession': true,
    'promptCapabilities': {'image': true, 'embeddedContext': true},
  },
};

/// The shape of omp's `session/new` result (the model list is cut to two).
Json ompSessionNew({String id = '0199d3f2-7c1e-7a55-9d36-1c2b3a4d5e6f'}) => {
  'sessionId': id,
  'configOptions': [
    {
      'id': 'mode',
      'name': 'Mode',
      'category': 'mode',
      'type': 'select',
      'currentValue': 'default',
      'options': [
        {'value': 'default', 'name': 'Default', 'description': 'Ask before risky tools'},
        {'value': 'plan', 'name': 'Plan', 'description': 'Plan only'},
      ],
    },
    {
      'id': 'model',
      'name': 'Model',
      'category': 'model',
      'type': 'select',
      'currentValue': 'anthropic/claude-sonnet-5-5',
      'options': [
        {'value': 'anthropic/claude-sonnet-5-5', 'name': 'Claude Sonnet 5.5'},
        {'value': 'openai/gpt-5', 'name': 'GPT-5'},
      ],
    },
  ],
  'modes': {
    'currentModeId': 'default',
    'availableModes': [
      {'id': 'default', 'name': 'Default'},
      {'id': 'plan', 'name': 'Plan'},
    ],
  },
};

/// Encodes a JSON message the way an agent writes it.
String line(Object message) => jsonEncode(message);

/// Lets scheduled microtasks and zero-duration timers run.
Future<void> settle() => Future<void>.delayed(Duration.zero);
