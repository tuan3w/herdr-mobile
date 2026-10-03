import 'dart:convert';

final _safeName = RegExp(r'^[A-Za-z0-9._-]+$');

const _pythonBridge = '''
import socket,sys,os,select
s=socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
i=sys.stdin.fileno()
o=sys.stdout.fileno()
live=True
while True:
    r,_,_=select.select([s]+([i] if live else []),[],[])
    if s in r:
        d=s.recv(65536)
        if not d:
            break
        os.write(o,d)
    if i in r:
        d=os.read(i,65536)
        if not d:
            live=False
            s.shutdown(socket.SHUT_WR)
        else:
            s.sendall(d)
''';

String _shQuote(String v) => "'${v.replaceAll("'", r"'\''")}'";

/// Builds the remote command that bridges the SSH channel's stdin/stdout to
/// herdr's API unix socket.
///
/// Preference order:
///  1. `herdr remote-api-bridge` (herdr >= 0.9), which also handles named
///     sessions.
///  2. `socat`, then a tiny `python3` relay, for older herdr builds. These
///     need the socket path: [socketPath] if given, else the default
///     session's `~/.config/herdr/herdr.sock`.
///
/// The script is shipped base64-encoded so it survives any login shell's
/// quoting, and run via `sh -c` with stdin untouched (stdin is the data path).
String buildBridgeCommand({required String session, String? socketPath}) {
  if (!_safeName.hasMatch(session)) {
    throw ArgumentError.value(session, 'session', 'invalid herdr session name');
  }
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
if command -v python3 >/dev/null 2>&1; then exec python3 -c ${_shQuote(_pythonBridge)} "\$S"; fi
echo "herdr-mobile: need herdr >= 0.9, socat or python3 on this host" >&2
exit 78
''';

  final script = '''
for H in "\$HOME/.local/bin/herdr" "\$(command -v herdr 2>/dev/null)"; do
  if [ -n "\$H" ] && [ -x "\$H" ] && [ "\$("\$H" --session $session remote-api-bridge --check </dev/null 2>/dev/null)" = herdr-api-bridge-v1 ]; then
    exec "\$H" --session $session remote-api-bridge
  fi
done
$fallback''';

  final b64 = base64.encode(utf8.encode(script));
  return 'sh -c "\$(echo $b64 | { base64 -d 2>/dev/null || base64 -D; })"';
}
