import 'dart:convert';

import '../models/herdr_models.dart' show paneReadWireFields, paneWireFields, snapshotWireFields;

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

/// Requests may also arrive deflated: `Q<n>`, a newline and `n` bytes of one
/// continuous zlib stream (a sync flush after every request, see
/// `MuxRequestEncoder`). Request lines repeat the same keys, so after the
/// first one each costs ~16 bytes instead of ~150. Plain lines still work.
///
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

/// Reads with more rows than this (old and new together) are sent whole: the
/// row diff is quadratic in the worst case.
const muxDeltaRows = 4000;

/// What the mux script cuts out of an answer before sending it, by method: the
/// parts of an answer the app reads. The same shape as the answer; `true`
/// keeps a value whole, a map keeps the listed keys of an object (of each
/// object, for a list). `id` and `error` are always listed so a failure still
/// arrives whole. Per-pane session paths, scroll state and the layouts are
/// most of a snapshot and nothing reads them (`snapshotWireFields`); the
/// `agents` list is kept only for `completion_seq`, which the script moves onto
/// the pane row. `pane.read` repeats ids the caller already has.
/// Embedded in the script, so it costs nothing per request.
const muxProjections = <String, Map<String, Object>>{
  'session.snapshot': {
    'id': true,
    'error': true,
    'result': {'snapshot': snapshotWireFields},
  },
  'pane.read': {
    'id': true,
    'error': true,
    'result': {
      'read': paneReadWireFields,
    },
  },
};

/// Where [muxProjections] go in the script.
const _keepSlot = '@@KEEP@@';

/// What the events script keeps of each event: its name and, for
/// `pane_updated`, the pane fields the app reads. The app tells other events
/// apart by name alone (`MachineConnection` refreshes on them).
const eventProjection = <String, Object>{
  'event': true,
  'data': {'pane': paneWireFields},
};

/// The Python `prune` both scripts use to cut an answer down to a projection.
const _pythonPrune = '''
def prune(v,s):
    if s is True:
        return v
    if isinstance(v,list):
        return [prune(x,s) for x in v]
    if isinstance(v,dict):
        return {k:prune(v[k],t) for k,t in s.items() if k in v}
    return v
''';

/// Where [_pythonPrune] goes in a script.
const _pruneSlot = '@@PRUNE@@';

/// Remote half of one event subscription (see [buildEventsCommand]).
const _pythonEvents = '''
import socket,sys,os,json,zlib,threading
K=json.loads(r"""$_keepSlot""")
@@PRUNE@@
q=sys.stdin.buffer.readline()
s=socket.socket(socket.AF_UNIX)
def watch():
    sys.stdin.buffer.read()
    os._exit(0)
threading.Thread(target=watch,daemon=True).start()
def run():
    s.connect(sys.argv[1])
    s.sendall(q)
    f=s.makefile("rb")
    o=sys.stdout.buffer
    a=f.readline()
    if not a:
        return 1
    o.write(a)
    o.flush()
    c=zlib.compressobj(6)
    for line in f:
        try:
            line=json.dumps(prune(json.loads(line),K),ensure_ascii=False,separators=(",",":")).encode()+b"\\n"
        except Exception:
            pass
        z=c.compress(line)+c.flush(zlib.Z_SYNC_FLUSH)
        o.write(b"E%d\\n"%len(z)+z)
        o.flush()
    return 0
try:
    code=run()
except Exception as e:
    sys.stderr.write("herdr-mobile: "+(str(e) or e.__class__.__name__)+"\\n")
    code=1
os._exit(code)
''';

/// Remote half of the multiplexed request channel: one JSON request per
/// stdin line, each served on its own thread against a fresh connection to
/// herdr's one-request-per-connection socket. Responses are written as they
/// complete (possibly out of order); the client matches them by `id`.
const _pythonMux = '''
import socket,sys,os,json,threading,zlib,itertools,difflib
P=sys.argv[1]
K=json.loads(r"""$_keepSlot""")
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
def ops(O,N):
    p=0
    m=min(len(O),len(N))
    while p<m and O[p]==N[p]:
        p+=1
    q=0
    while q<m-p and O[-1-q]==N[-1-q]:
        q+=1
    out=[]
    lit=[]
    if p:
        out.append([0,p])
    # The identical head and tail are cut off first: a pane of repeated rows
    # (blank lines, rulers) would make the diff quadratic otherwise.
    for t,i1,i2,j1,j2 in difflib.SequenceMatcher(None,O[p:len(O)-q],N[p:len(N)-q],autojunk=False).get_opcodes():
        if t=="equal":
            if lit:
                out.append(lit)
                lit=[]
            out.append([i1+p,i2-i1])
        else:
            lit+=N[p+j1:p+j2]
    if lit:
        out.append(lit)
    if q:
        out.append([len(O)-q,q])
    return out
@@PRUNE@@
def delta(q,d,have):
    res=d.get("result")
    if not isinstance(res,dict):
        return
    snap=q.get("method")=="session.snapshot"
    box=res.get("snapshot" if snap else "read")
    if not isinstance(box,dict):
        return
    if snap:
        # herdr puts completion_seq on its per-agent list, which rows do not
        # carry; it travels on the pane row the app already reads it from.
        cs={a.get("pane_id"):a.get("completion_seq") for a in box.get("agents") or [] if isinstance(a,dict) and isinstance(a.get("completion_seq"),int)}
        rows=["v"+str(box.get("version",""))]
        for k,c in (("workspaces","w"),("tabs","t"),("panes","p")):
            for x in box.get(k) or []:
                if k=="panes" and x.get("pane_id") in cs:
                    x["completion_seq"]=cs[x["pane_id"]]
                rows.append(c+json.dumps(x,ensure_ascii=False,separators=(",",":")))
    else:
        text=box.get("text")
        if not isinstance(text,str) or len(text)<$muxDeltaMin:
            return
        rows=text.split("\\n")
    n=sum(len(l)+1 for l in rows)
    key=json.dumps([q.get("method"),q.get("params")],sort_keys=True)
    seq=next(SQ)
    with HL:
        old=H.pop(key,None)
        H[key]=(seq,rows,n)
        T[0]+=n-(old[2] if old else 0)
        while len(H)>1 and (len(H)>$muxDeltaKeep or T[0]>$muxDeltaChars):
            T[0]-=H.pop(next(iter(H)))[2]
    d["seq"]=seq
    body=None
    if old is not None and old[0]==have and len(old[1])+len(rows)<=$muxDeltaRows:
        o=ops(old[1],rows)
        if sum(len(l) for e in o if isinstance(e[0],str) for l in e)*2<n:
            body={"base":have,"o":o}
    if snap:
        res["snapshot"]={"delta":body} if body else {"rows":rows}
    elif body:
        del box["text"]
        box["delta"]=body
def post(q,r,have,keep):
    d=json.loads(r)
    if keep:
        d=prune(d,keep)
    if q.get("method") in ("pane.read","session.snapshot"):
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
            m=q.get("method")
            keep=K.get(m) if isinstance(m,str) else None
            if have is not None:
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
            if isinstance(q,dict) and keep and r.startswith(b'{"id"'):
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
def go(line):
    line=line.strip()
    if line:
        threading.Thread(target=serve,args=(line,)).start()
out(b"$muxReadyLine")
I=sys.stdin.buffer
D=zlib.decompressobj()
rest=b""
while True:
    h=I.readline()
    if not h:
        break
    if h[:1]!=b"Q":
        go(h)
        continue
    try:
        rest+=D.decompress(I.read(int(h[1:])))
    except Exception as e:
        sys.stderr.write("herdr-mobile: bad request stream: "+str(e)+"\\n")
        os._exit(1)
    *ls,rest=rest.split(b"\\n")
    for l in ls:
        go(l)
''';

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

/// Builds the remote command for the multiplexed request channel: prints
/// [muxReadyLine], then serves pipelined JSON request lines from stdin until
/// stdin closes. Talks to herdr's socket directly, so it needs `python3` and
/// the socket at [socketPath] or the path herdr derives from [session]
/// (`$XDG_CONFIG_HOME` or `~/.config`, then `herdr`). Exits 78 with a hint
/// when either is missing so callers can fall back to [buildBridgeCommand].
///
/// Shipped base64-encoded like [buildBridgeCommand], with stdin untouched.
String buildMuxCommand({required String session, String? socketPath}) =>
    _pythonCommand(
      what: 'the multiplexed channel',
      script: _pythonMux
          .replaceFirst(_pruneSlot, _pythonPrune)
          .replaceFirst(_keepSlot, jsonEncode(muxProjections)),
      session: session,
      socketPath: socketPath,
    );

/// Builds the remote command for one event subscription: reads the
/// `events.subscribe` request line from stdin, forwards it to herdr's socket
/// and prints herdr's acknowledgement as a plain line, then every event cut
/// down to what the app reads ([eventProjection]) and deflated as `E<n>`
/// frames of one continuous zlib stream (see `muxMessages`). A working agent
/// makes herdr send ~10 near-identical 770-byte events a second; in a stream
/// that remembers the last one they cost ~30 bytes each. Exits when stdin
/// closes or herdr hangs up. Needs `python3` and the socket like
/// [buildMuxCommand], and exits 78 when either is missing, so the caller can
/// use [buildBridgeCommand] instead.
String buildEventsCommand({required String session, String? socketPath}) =>
    _pythonCommand(
      what: 'the event channel',
      script: _pythonEvents
          .replaceFirst(_pruneSlot, _pythonPrune)
          .replaceFirst(_keepSlot, jsonEncode(eventProjection)),
      session: session,
      socketPath: socketPath,
    );

String _pythonCommand({
  required String what,
  required String script,
  required String session,
  required String? socketPath,
}) {
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
  echo "herdr-mobile: $what needs python3 on this host" >&2
  exit 78
fi
S=$socketExpr
if [ ! -S "\$S" ]; then
  echo "herdr-mobile: no herdr socket at \$S for session $session" >&2
  exit 78
fi
exec python3 -c ${_shQuote(script)} "\$S"
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
