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

/// Responses longer than this many bytes are sent deflated: `Z<n>`, a newline
/// and then exactly `n` bytes of zlib data holding the JSON line (no newline
/// after them). Shorter ones are plain JSON lines, which start with `{`, so
/// the two cannot be confused (see `muxMessages`). Pane text compresses 5-10x
/// and costs the phone far less to inflate than to decrypt; binary frames
/// spare the 33% a text encoding of the compressed bytes would add.
const muxCompressMin = 512;

/// First line the mux script prints, once it is ready to serve requests.
const muxReadyLine = 'herdr-mux-v1';

/// A `pane.read` whose text is at least [muxDeltaMin] characters is remembered
/// by the mux (the last [muxDeltaKeep] distinct reads, at most [muxDeltaChars]
/// characters of text; the oldest go first). A client that still holds the
/// previous answer to the same read says so (`mux_have`: the `seq` that answer
/// carried) and gets only the rows that differ: the pane view reads a sliding
/// 300-row window many times a second and almost all of it is unchanged, and
/// so is most of a board card's 24 rows between two reads.
const muxDeltaMin = 512;
const muxDeltaKeep = 256;
const muxDeltaChars = 4000000;

/// Remote half of the multiplexed request channel: one JSON request per
/// stdin line, each served on its own thread against a fresh connection to
/// herdr's one-request-per-connection socket. Responses are written as they
/// complete (possibly out of order); the client matches them by `id`.
const _pythonMux = '''
import socket,sys,os,json,threading,zlib,itertools
P=sys.argv[1]
W=threading.Lock()
def out(b,end=b"\\n"):
    try:
        with W:
            sys.stdout.buffer.write(b+end)
            sys.stdout.buffer.flush()
    except OSError:
        os._exit(1)
def fail(i,m):
    out(json.dumps({"id":i,"error":{"code":"bridge_error","message":m}}).encode())
H={}
T=[0]
HL=threading.Lock()
SQ=itertools.count(1)
def diff(O,N):
    if not O or not N:
        return None
    best=None
    for b in [j for j,l in enumerate(O) if l==N[0]][:16]:
        k=0
        m=min(len(N),len(O)-b)
        while k<m and N[k]==O[b+k]:
            k+=1
        if best is None or k>best[1]:
            best=(b,k)
    if best is None:
        return None
    b,k=best
    x=0
    while x<len(O)-b-k and x<len(N)-k and N[-1-x]==O[-1-x]:
        x+=1
    return b,k,x
def prune(v,s):
    if s is True:
        return v
    if isinstance(v,list):
        return [prune(x,s) for x in v]
    if isinstance(v,dict):
        return {k:prune(v[k],t) for k,t in s.items() if k in v}
    return v
def delta(q,d,have):
    res=d.get("result")
    rd=res.get("read") if isinstance(res,dict) else None
    if not isinstance(rd,dict) or not isinstance(rd.get("text"),str):
        return
    text=rd["text"]
    if len(text)<$muxDeltaMin:
        return
    key=json.dumps(q.get("params"),sort_keys=True)
    seq=next(SQ)
    rows=text.split("\\n")
    n=len(text)
    with HL:
        old=H.pop(key,None)
        H[key]=(seq,rows,n)
        T[0]+=n-(old[2] if old else 0)
        while len(H)>1 and (len(H)>$muxDeltaKeep or T[0]>$muxDeltaChars):
            T[0]-=H.pop(next(iter(H)))[2]
    d["seq"]=seq
    if old is not None and old[0]==have:
        p=diff(old[1],rows)
        if p:
            b,k,x=p
            lit=rows[k:len(rows)-x]
            if sum(len(l) for l in lit)*2<len(text):
                del rd["text"]
                rd["delta"]={"base":have,"s":b,"k":k,"x":x,"t":lit}
def post(q,r,have,keep):
    d=json.loads(r)
    if keep:
        d=prune(d,keep)
    if q.get("method")=="pane.read":
        delta(q,d,have)
    return json.dumps(d,ensure_ascii=False,separators=(",",":")).encode()
def serve(line):
    i=None
    try:
        q=json.loads(line)
        have=keep=None
        if isinstance(q,dict):
            i=q.get("id")
            have=q.pop("mux_have",None)
            keep=q.pop("mux_keep",None)
            if have is not None or keep is not None:
                line=json.dumps(q).encode()
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
            r=bytes(b[:n])
            # herdr cannot correlate a request it fails to parse (an unknown
            # method) and answers with id "": give it the id it was sent with,
            # or the client would wait for a reply that is never matched.
            if i is not None and r.startswith(b'{"id":"",'):
                r=json.dumps(dict(json.loads(r),id=i)).encode()
            if isinstance(q,dict) and (keep or q.get("method")=="pane.read") and r.startswith(b'{"id"'):
                try:
                    r=post(q,r,have,keep)
                except Exception:
                    pass
            if len(r)>$muxCompressMin:
                z=zlib.compress(r,6)
                out(b"Z%d\\n"%len(z)+z,b"")
            else:
                out(r)
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
