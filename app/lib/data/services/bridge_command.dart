import 'dart:convert';

import '../models/herdr_models.dart' show paneReadWireFields, paneWireFields, snapshotWireFields;

final _safeName = RegExp(r'^[A-Za-z0-9._-]+$');

/// The first message the host's mux sends once herdr's socket is there (the
/// first `MSG` of a `herdr.mux` stream); [MuxClient] waits for it before it
/// sends a request.
const muxReadyLine = '{"ready":true}';

/// A `pane.read` whose text is at least [muxDeltaMin] characters is remembered
/// by the mux (the last [muxDeltaKeep] distinct reads, at most [muxDeltaChars]
/// characters of text; the oldest go first). A client that still holds the
/// previous answer to the same read says so (`mux_have`: the `seq` that answer
/// carried) and gets only the rows that differ: the pane view reads a sliding
/// 300-row window many times a second and almost all of it is unchanged, and
/// so is most of a board card's 24 rows between two reads.
///
/// Sent to the host when the mux stream is opened (`herdr.mux` args `delta`),
/// so the numbers live here and nowhere else.
const muxDeltaMin = 512;
const muxDeltaKeep = 256;
const muxDeltaChars = 4000000;

/// Reads with more rows than this (old and new together) are sent whole: the
/// row diff is quadratic in the worst case.
const muxDeltaRows = 4000;

/// What the mux cuts out of an answer before sending it, by method: the parts of
/// an answer the app reads. The same shape as the answer; `true` keeps a value
/// whole, a map keeps the listed keys of an object (of each object, for a
/// list). `id` and `error` are always listed so a failure still arrives whole.
/// Per-pane session paths, scroll state and the layouts are most of a snapshot
/// and nothing reads them (`snapshotWireFields`); the `agents` list is kept only
/// for `completion_seq`, which the mux moves onto the pane row. `pane.read`
/// repeats ids the caller already has.
///
/// Sent to the host when the mux stream is opened (`herdr.mux` args
/// `projections`): the host knows no field names of its own.
const muxProjections = <String, Map<String, Object>>{
  'session.snapshot': {
    'id': true,
    'error': true,
    'result': {'snapshot': snapshotWireFields},
  },
  'pane.read': {
    'id': true,
    'error': true,
    'result': {'read': paneReadWireFields},
  },
};

/// What the event stream keeps of each event: its name and, for
/// `pane_updated`, the pane fields the app reads; for
/// `pane_agent_status_changed`, whose `data` is flat, the pane, the workspace,
/// the agent and the status (`MachineConnection` shows that status before its
/// snapshot answers). The app tells other events apart by name alone
/// (`MachineConnection` refreshes on them). Sent when the stream is opened
/// (`herdr.events` args `projection`).
const eventProjection = <String, Object>{
  'event': true,
  'data': {'pane': paneWireFields, 'pane_id': true, 'workspace_id': true, 'agent': true, 'agent_status': true},
};

String _shQuote(String v) => "'${v.replaceAll("'", r"'\''")}'";

void _checkSession(String session) {
  if (!_safeName.hasMatch(session)) {
    throw ArgumentError.value(session, 'session', 'invalid herdr session name');
  }
}

/// `sh -c '<decode and eval>'` over base64 text: the login shell (fish, csh)
/// sees one single-quoted word, so it cannot choke on `$( )`, `{ }` or `||`
/// (see `_wrap` in `keeper_command.dart`). Base64 has no quote character.
String _shellCommand(String script) {
  final b64 = base64.encode(utf8.encode(script));
  return "sh -c 'eval \"\$(echo $b64 | { base64 -d 2>/dev/null || base64 -D; })\"'";
}

/// Builds the remote command that bridges the SSH channel's stdin/stdout to
/// herdr's API unix socket: one request per channel. This is how a herdr request
/// travels on a host that has no agent helper (`herdr-host serve`, which carries
/// the mux and the event stream on one channel).
///
/// Preference order:
///  1. `herdr remote-api-bridge` (herdr >= 0.9), which also handles named
///     sessions.
///  2. `socat`, for older herdr builds. It needs the socket path: [socketPath]
///     if given, else the default session's `~/.config/herdr/herdr.sock`.
///
/// Exits 78 with a hint when neither is there.
///
/// The script is shipped base64-encoded so it survives any login shell's
/// quoting, and run via `sh -c` with stdin untouched (stdin is the data path).
String buildBridgeCommand({required String session, String? socketPath}) {
  _checkSession(session);
  final String socketExpr;
  if (socketPath != null && socketPath.isNotEmpty) {
    socketExpr = _shQuote(socketPath);
  } else if (session == 'default') {
    socketExpr = r'"$HOME/.config/herdr/herdr.sock"';
  } else {
    socketExpr = '';
  }

  final fallback = socketExpr.isEmpty
      ? '''
echo "herdr-mobile: herdr on this host has no remote-api-bridge; set a socket path for session $session" >&2
exit 78
'''
      : '''
S=$socketExpr
if command -v socat >/dev/null 2>&1; then exec socat - "UNIX-CONNECT:\$S"; fi
echo "herdr-mobile: need herdr >= 0.9 or socat on this host" >&2
exit 78
''';

  final script =
      '''
for H in "\$HOME/.local/bin/herdr" "\$(command -v herdr 2>/dev/null)"; do
  if [ -n "\$H" ] && [ -x "\$H" ] && [ "\$("\$H" --session $session remote-api-bridge --check </dev/null 2>/dev/null)" = herdr-api-bridge-v1 ]; then
    exec "\$H" --session $session remote-api-bridge
  fi
done
$fallback''';

  return _shellCommand(script);
}
