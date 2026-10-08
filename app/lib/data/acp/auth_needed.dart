import 'acp_models.dart';
import 'json_rpc.dart';

/// ACP's `auth_required`: "Authentication is required before this operation
/// can be performed" (the ACP spec's error codes, `agent-client-protocol` `error.rs`).
const acpAuthRequired = -32000;

/// One way the agent says a person can sign in.
class AuthChoice {
  const AuthChoice({required this.id, required this.name, this.description, this.terminal = false, this.terminalLabel, this.terminalCommand});

  /// Reads one entry of `authMethods` (an `initialize` answer, or the `data`
  /// of an `auth_required` error). Nothing is thrown for a shape it does not
  /// know.
  factory AuthChoice.parse(Json j) {
    final meta = j['_meta'];
    final hint = meta is Map ? meta['terminal-auth'] : null;
    final launch = hint is Map ? hint : const {};
    final command = launch['command'];
    final args = launch['args'];
    final label = launch['label'];
    return AuthChoice(
      id: j['id'] is String ? j['id'] as String : '',
      name: j['name'] is String ? j['name'] as String : '',
      description: j['description'] is String ? j['description'] as String : null,
      terminal: j['type'] == 'terminal' || hint is Map,
      terminalLabel: label is String ? label : null,
      terminalCommand: command is String
          ? [command, if (args is List) ...args.whereType<String>()].join(' ')
          : null,
    );
  }

  final String id;
  final String name;
  final String? description;

  /// A login that runs in a terminal on the host: a method with
  /// `type: "terminal"` (the ACP spec's shape) or one that carries the
  /// `_meta["terminal-auth"]` hint (Zed's, which pi-acp and Claude Code add).
  /// The phone never runs it: it does not advertise `auth.terminal`.
  final bool terminal;

  /// The hint's button label (`Launch pi`, `Claude Login`).
  final String? terminalLabel;

  /// The hint's `command args...`, a path on the *host*; for display only.
  final String? terminalCommand;
}

/// The agent refused for lack of a login. The phone does not run login flows
/// (no `authenticate`, no `auth.terminal`): the screen says so and offers a
/// terminal session on the host, where the person signs in; then "Retry".
class AuthNeeded {
  const AuthNeeded({required this.message, this.agentMessage, this.methods = const [], this.keychain = false});

  /// In words for the person ("Claude Code needs you to sign in on the host.").
  final String message;

  /// What the agent said ("Authentication required").
  final String? agentMessage;
  final List<AuthChoice> methods;

  /// The agent's login is in the macOS Keychain, which the session started
  /// from the phone cannot open (`KeeperInfo.loginInKeychain`): signing in
  /// in a terminal stores it there again, so only a token in the host's
  /// environment helps.
  final bool keychain;

  /// Some method logs in through a terminal on the host: the screen can
  /// offer a terminal session for it.
  bool get terminalHint => methods.any((m) => m.terminal);
}

/// [methods] (`authMethods` as the agent sent them) as choices.
List<AuthChoice> parseAuthChoices(Object? methods) => [
  if (methods is List)
    for (final m in methods)
      if (m is Map) AuthChoice.parse(m.cast<String, Object?>()),
];

/// Whether [e] is an agent saying it needs a login: ACP's `-32000` with a
/// message about authentication, or carrying `authMethods` (pi-acp's
/// `authRequired` error, Claude Code's and Codex's `auth_required`). The same
/// code also means other things (the keeper's "the client went away"), so the
/// code alone is not enough.
bool isAuthRequired(Object? e) {
  if (e is! JsonRpcException || e.code != acpAuthRequired) return false;
  final data = e.data;
  if (data is Map && (data['authMethods'] is List || data['reason'] == 'auth_required')) return true;
  return RegExp(r'auth(entication|orization|orisation|_required| required)', caseSensitive: false).hasMatch(e.message);
}

/// The [AuthNeeded] for the auth error [e]: the methods in its `data` when it
/// has any (pi-acp sends them there), else the ones [advertised] at
/// `initialize`. [keychain]: see [AuthNeeded.keychain].
AuthNeeded authNeededFrom(JsonRpcException e, {required String agentLabel, Object? advertised, bool keychain = false}) {
  final data = e.data;
  var methods = data is Map ? parseAuthChoices(data['authMethods']) : const <AuthChoice>[];
  if (methods.isEmpty) methods = parseAuthChoices(advertised);
  return AuthNeeded(
    message: keychain
        ? '$agentLabel keeps its login in the Mac’s Keychain, which macOS keeps locked for sessions started from the phone.'
        : '$agentLabel needs you to sign in on the host.',
    agentMessage: e.message,
    methods: methods,
    keychain: keychain,
  );
}
