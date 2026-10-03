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

/// First line the mux script prints, once it is ready to serve requests.
const muxReadyLine = 'herdr-mux-v1';

/// Remote half of the multiplexed request channel: one JSON request per
/// stdin line, each served on its own thread against a fresh connection to
/// herdr's one-request-per-connection socket. Responses are written as they
/// complete (possibly out of order); the client matches them by `id`.
const _pythonMux = '''
import socket,sys,os,json,threading
P=sys.argv[1]
W=threading.Lock()
def out(b):
    try:
        with W:
            sys.stdout.buffer.write(b+b"\\n")
            sys.stdout.buffer.flush()
    except OSError:
        os._exit(1)
def fail(i,m):
    out(json.dumps({"id":i,"error":{"code":"bridge_error","message":m}}).encode())
def serve(line):
    i=None
    try:
        q=json.loads(line)
        if isinstance(q,dict):
            i=q.get("id")
        s=socket.socket(socket.AF_UNIX)
        try:
            s.settimeout(30)
            s.connect(P)
            s.sendall(line+b"\\n")
            b=bytearray()
            while b"\\n" not in b:
                d=s.recv(65536)
                if not d:
                    break
                b+=d
        finally:
            s.close()
        n=b.find(b"\\n")
        if n<0:
            fail(i,"herdr closed the connection without answering")
        else:
            out(bytes(b[:n]))
    except Exception as e:
        fail(i,str(e) or e.__class__.__name__)
out(b"$muxReadyLine")
for line in sys.stdin.buffer:
    line=line.strip()
    if line:
        threading.Thread(target=serve,args=(line,)).start()
''';

String _shQuote(String v) => "'${v.replaceAll("'", r"'\''")}'";

void _checkSession(String session) {
  if (!_safeName.hasMatch(session)) {
    throw ArgumentError.value(session, 'session', 'invalid herdr session name');
  }
}

String _shellCommand(String script) {
  final b64 = base64.encode(utf8.encode(script));
  return 'sh -c "\$(echo $b64 | { base64 -d 2>/dev/null || base64 -D; })"';
}

/// Builds the remote command for the multiplexed request channel: prints
/// [muxReadyLine], then serves pipelined JSON request lines from stdin until
/// stdin closes. Talks to herdr's socket directly, so it needs `python3` and
/// the socket at [socketPath] or the path herdr derives from [session]
/// (`$XDG_CONFIG_HOME` or `~/.config`, then `herdr`). Exits 78 with a hint
/// when either is missing so callers can fall back to [buildBridgeCommand].
///
/// Shipped base64-encoded like [buildBridgeCommand], with stdin untouched.
String buildMuxCommand({required String session, String? socketPath}) {
  _checkSession(session);
  final String socketExpr;
  if (socketPath != null && socketPath.isNotEmpty) {
    socketExpr = _shQuote(socketPath);
  } else {
    final dir = session == 'default' ? '' : '/sessions/$session';
    socketExpr = '"\${XDG_CONFIG_HOME:-\$HOME/.config}/herdr$dir/herdr.sock"';
  }
  return _shellCommand('''
if ! command -v python3 >/dev/null 2>&1; then
  echo "herdr-mobile: the multiplexed channel needs python3 on this host" >&2
  exit 78
fi
S=$socketExpr
if [ ! -S "\$S" ]; then
  echo "herdr-mobile: no herdr socket at \$S for session $session" >&2
  exit 78
fi
exec python3 -c ${_shQuote(_pythonMux)} "\$S"
''');
}

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

  return _shellCommand(script);
}
