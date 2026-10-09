import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:math' as math;

import '../acp/agent_host.dart';
import 'keeper_script.dart';

// Shell commands for the host-side keeper (`docs/AGENT_SESSIONS.md`, "The
// keeper"). The script (~22 KB deflated) is installed once per host and per
// script version by [keeperInstallCommand] as `~/.herdr-mobile/keeper-<id>.py`;
// every other command is a few hundred bytes that runs that file. Needs only
// `python3` on the host.
//
// Exit codes of the commands, for the callers:
//
//   0   done (stdout carries the answer)
//   64  bad arguments (a bug)
//   65  the script of this app version is not installed on the host: run
//       [keeperInstallCommand], then the command again
//   66  start, history: the folder is not there. attach/kill: no such keeper.
//       follow: the file is not an absolute `.jsonl` path under the home
//       folder, or cannot be read; stderr says why
//   67  attach: the keeper's agent has exited; stderr says why
//   69  start, history: the agent is not installed on the host
//   70  start, history: the agent failed to start or to answer `initialize`
//       (history: or `session/list`); stderr has its last words
//   78  python3 is missing

/// The ids the script generates (`[a-z0-9]`, six characters today).
final _keeperId = RegExp(r'^[a-z0-9]{3,32}$');

/// Longest folder path accepted: far above PATH_MAX, far below the command limit.
const _maxCwd = 4096;

String _shQuote(String v) => "'${v.replaceAll("'", r"'\''")}'";

bool _validCwd(String cwd) =>
    cwd.isNotEmpty && cwd.length <= _maxCwd && !cwd.runes.any((c) => c < 0x20 || c == 0x7f);

/// The python source with the route table filled in, as it runs on the host.
String keeperScript() => keeperPython.replaceFirst(
  keeperRoutesSlot,
  jsonEncode([
    for (final r in agentRoutes)
      {
        'id': r.id,
        'label': r.label,
        'binary': r.binary,
        'args': r.args,
        if (r.npxPackage != null) 'npx': r.npxPackage,
        if (r.airCapabilities.isNotEmpty) 'air': r.airCapabilities,
      },
  ]),
);

/// 12 hex characters naming a script version: FNV-1a 64 over the UTF-8 text
/// (the first 12 of its 16 hex digits). A changed script is a new file name, so
/// versions never collide on a host.
String keeperScriptVersion(String script) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(script)) {
    h = (h ^ b) * 0x100000001b3; // wraps at 64 bits
  }
  String half(int v) => (v & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return (half(h >>> 32) + half(h)).substring(0, 12);
}

final String _version = keeperScriptVersion(keeperScript());

/// Writes the script into `~/.herdr-mobile/keeper-<version>.py` (temp file in
/// the same directory, then rename, so a reader never sees half a file), then
/// removes the files of other versions and stale temp files. A keeper that is
/// running holds its own copy of the script in memory, so removing the file it
/// started from is safe. Argument: the version. The deflated script arrives as
/// base64 on stdin.
const _installer = r'''
import base64,os,sys,time,zlib
d=os.path.join(os.path.expanduser("~"),".herdr-mobile")
os.makedirs(d,0o700,exist_ok=True)
os.chmod(d,0o700)
n="keeper-"+sys.argv[1]+".py"
data=zlib.decompress(base64.b64decode(sys.stdin.read()))
t=os.path.join(d,"."+n+".tmp%d"%os.getpid())
f=os.fdopen(os.open(t,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o700),"wb")
f.write(data)
f.close()
os.chmod(t,0o700)
os.replace(t,os.path.join(d,n))
for o in os.listdir(d):
  p=os.path.join(d,o)
  try:
    if o.startswith("keeper-") and o.endswith(".py") and o!=n:
      os.unlink(p)
    elif o.startswith(".keeper-") and ".tmp" in o and time.time()-os.path.getmtime(p)>60:
      os.unlink(p)
  except OSError:
    pass
print('{"ok":true}')
''';

/// `sh -c '<decode and eval>'` over base64 text. The login shell (fish, csh and
/// tcsh included) sees ONE single-quoted word and nothing else: no `$( )`, no
/// `{ }`, no `||`, which fish and csh parse differently or refuse (fish exits
/// 127 on `{ }`, csh 1). The base64 text has only `A-Za-z0-9+/=`, so it can
/// neither close the quote nor be touched by history expansion. `sh` decodes
/// and `eval`s the script; stdin and stdout stay the data path.
String _wrap(String script) {
  final b64 = base64.encode(utf8.encode(script));
  return "sh -c 'eval \"\$(echo $b64 | { base64 -d 2>/dev/null || base64 -D; })\"'";
}

const _needPython = '''
if ! command -v python3 >/dev/null 2>&1; then
  echo "herdr-mobile: agent sessions need python3 on this host" >&2
  exit 78
fi
''';

/// A short command that runs the installed script with [args].
String _command(List<String> args) => _wrap('''
${_needPython}f="\$HOME/.herdr-mobile/keeper-$_version.py"
if [ ! -f "\$f" ]; then
  echo "herdr-mobile: the keeper is not installed on this host" >&2
  exit 65
fi
exec python3 "\$f" ${args.map(_shQuote).join(' ')}
''');

void _checkKeeperId(String id) {
  if (!_keeperId.hasMatch(id)) {
    throw ArgumentError.value(id, 'keeperId', 'invalid keeper id');
  }
}

/// Installs this app version's keeper script on the host (stdout `{"ok":true}`,
/// idempotent): run once per host, when another command exits 65. The command
/// is small; the script travels on the channel's stdin as
/// [keeperInstallPayload] (write it, then close stdin: the installer reads to
/// EOF). A long command line is refused by some SSH servers (Dropbear caps an
/// exec at 9000 bytes). [script] is for tests that need a second version.
String keeperInstallCommand({String? script}) => _wrap('''
${_needPython}exec python3 -c ${_shQuote(_installer)} ${keeperScriptVersion(script ?? keeperScript())}
''');

/// What to write to the stdin of [keeperInstallCommand] before closing it: the
/// deflated script as base64 in lines of 76 characters (~22 KB).
String keeperInstallPayload({String? script}) {
  final b64 = base64.encode(ZLibCodec(level: 9).encode(utf8.encode(script ?? keeperScript())));
  final lines = [for (var i = 0; i < b64.length; i += 76) b64.substring(i, math.min(i + 76, b64.length))];
  return '${lines.join('\n')}\n';
}

/// stdout: one JSON line `{"routes":["omp","claude"]}`: the [agentRoutes] ids
/// whose binary, or `npx` for a route that has a package, the host can run.
String keeperProbeCommand() => _command(const ['probe']);

/// stdout: one JSON line, an array of [KeeperInfo] objects (`KeeperInfo.toJson`
/// keys plus `exit_reason`), newest first: the running keepers and those whose
/// agent exited within a day. Marks keepers whose process vanished as exited and
/// removes the expired ones.
String keeperListCommand() => _command(const ['list']);

/// Starts a keeper that runs [agent] (an [agentRoutes] id) in [cwd] and prints
/// its [KeeperInfo] as one JSON line once the agent has answered `initialize`.
/// The keeper outlives the command. `~` and `~/x` expand on the host. On
/// failure nothing is left behind and stderr says why (exit codes above).
///
/// Throws [ArgumentError] for an unknown [agent] or a [cwd] that is empty, too
/// long or holds a control character (a newline included).
String keeperStartCommand({required String agent, required String cwd}) {
  if (agentRouteById(agent) == null) {
    throw ArgumentError.value(agent, 'agent', 'unknown agent');
  }
  if (!_validCwd(cwd)) {
    throw ArgumentError.value(cwd, 'cwd', 'invalid folder');
  }
  return _command(['start', '--agent', agent, '--cwd', cwd]);
}

/// Asks [agent] (an [agentRoutes] id) what it remembers: runs it briefly,
/// without a keeper or a session, and prints ONE JSON line
/// `{"agent":..,"list":bool,"load":bool,"resume":bool,"more":bool,"sessions":[..]}`
/// (`PastSessions.fromJson` reads it; at most 200 sessions, newest first). With
/// [cwd] only the sessions of that folder, otherwise every folder (the agent
/// then runs in the home folder). Read-only: no keeper file is touched and the
/// agent is stopped before the command exits. Exit codes: 66 the folder is not
/// there, 69 the agent is not installed, 70 the agent failed or did not answer
/// (stderr has why).
///
/// Throws [ArgumentError] for an unknown [agent] or a [cwd] that is empty, too
/// long or holds a control character (a newline included).
String keeperHistoryCommand({required String agent, String? cwd}) {
  if (agentRouteById(agent) == null) {
    throw ArgumentError.value(agent, 'agent', 'unknown agent');
  }
  if (cwd != null && !_validCwd(cwd)) {
    throw ArgumentError.value(cwd, 'cwd', 'invalid folder');
  }
  return _command(['history', agent, ?cwd]);
}

/// Bridges the channel's stdin/stdout to the keeper's socket: lines of ACP
/// JSON-RPC both ways. Closing stdin detaches (the agent keeps running). Every
/// attached client is equal (`docs/AGENT_SESSIONS.md`, "Shared sessions"):
/// each gets every update, a waiting request goes to all of them, and the
/// others are told who answered first (`_herdr/resolved`, then
/// `$/cancel_request`). Keepers started by older scripts still evict an older
/// attach with `{"method":"_herdr/evicted","params":{"reason":...}}`. When the
/// agent exits while attached the keeper writes
/// `{"method":"_herdr/agent_exited","params":{"exitCode":n,"reason":...}}`, then
/// closes. Exit codes: 66 no such keeper, 67 its agent has exited (stderr says
/// why).
///
/// With [zipped] what the keeper writes comes back as `Z<base64>` lines of one
/// zlib stream wherever a batch of lines is big enough to gain from it
/// (`ATTACH_ZIP_MIN` in the script; [ZippedLines] reads it): the replay of a
/// long thread is ~10x smaller on the wire. The other direction is plain.
String keeperAttachCommand(String keeperId, {bool zipped = false}) {
  _checkKeeperId(keeperId);
  return _command(['attach', keeperId, if (zipped) '--z']);
}

/// Follows the session log [path] (absolute, `.jsonl`, under the host user's
/// home; anything else exits 66 with a reason on stderr): first the tail of the
/// file (the last [tailBytes] from a line start, default 192 KB, clamped by the
/// host to 16 KB..64 MB; the whole file when smaller), or
/// with [from] everything after that byte offset; then every complete line
/// that is appended, pushed within [pollMs] (default 250 ms; the file is
/// stat'ed that often while it grows, every 1 s after 60 s and every 2 s after
/// 10 min without growth; growth goes back to [pollMs]). Stdout is one record
/// per line:
///
///   `<endOffset>\t<json>`  a log line, re-serialised compactly, with every
///                          string cut to 16 KB (`... [N bytes cut]`) and
///                          binary payloads dropped; a line that is not JSON
///                          is `{"raw":"<first 2 KB>"}`, one over 4 MB a stub;
///                          an omp message is left without what only omp
///                          reads (token accounting, the provider's envelope,
///                          `thinkingSignature`, `details.displayContent`)
///                          and a `credential_pin` entry is not sent at all
///   `S\t<offset>`          before the first line of a tail read (at the start,
///                          and with every `R`): where in the file the tail
///                          begins, 0 when it is the whole file
///   `R\t<offset>`          the file shrank or was replaced (or [from] is not
///                          a line end of it): forget what came before, what
///                          follows is its content from [offset]
///   `C\t<offset>`          once, after the first read to the end of the file:
///                          everything up to [offset] has been sent, so an
///                          empty log or a resume at its end is up to date
///   `E\t<message>`         reading failed; the command exits 70
///
/// `endOffset` is the byte offset after the line: pass it back as [from] to
/// resume. Closing stdin ends the command (so does a closed stdout); with
/// [idleExit] > 0 it also ends, exit 0, after that many seconds without growth
/// (for a phone that vanished without closing the channel).
///
/// With [zipped] (`--z`) the records of a batch of at least 512 bytes travel as
/// one `Z<base64 of zlib data>` line of ONE zlib stream (each batch ended with
/// a sync flush), the others as they are: the log of a long chat is plain JSON
/// and deflates ~3x. A reader that does not know `Z` lines sees records it
/// skips, so only a transport that reads them back (`openExec(zipped: true)`)
/// should ask.
///
/// Throws [ArgumentError] for a [path] that is empty, too long or holds a
/// control character, and for a negative [from] or [idleExit], a [pollMs] below
/// 1 or a [tailBytes] below 1. [from] wins over [tailBytes].
String keeperFollowCommand(String path, {int? from, int? pollMs, int? idleExit, int? tailBytes, bool zipped = false}) {
  if (path.isEmpty || path.length > _maxCwd || path.runes.any((c) => c < 0x20 || c == 0x7f)) {
    throw ArgumentError.value(path, 'path', 'invalid path');
  }
  if (from != null && from < 0) throw ArgumentError.value(from, 'from', 'invalid offset');
  if (pollMs != null && pollMs < 1) throw ArgumentError.value(pollMs, 'pollMs', 'invalid interval');
  if (idleExit != null && idleExit < 0) throw ArgumentError.value(idleExit, 'idleExit', 'invalid time');
  if (tailBytes != null && tailBytes < 1) throw ArgumentError.value(tailBytes, 'tailBytes', 'invalid size');
  return _command([
    'follow',
    path,
    if (zipped) '--z',
    if (from != null) ...['--from', '$from'],
    if (pollMs != null) ...['--poll-ms', '$pollMs'],
    if (idleExit != null) ...['--idle-exit', '$idleExit'],
    if (tailBytes != null) ...['--tail-bytes', '$tailBytes'],
  ]);
}

/// stdout: `{"ok":true}`. Sends the agent's process group SIGTERM, SIGKILL
/// after 3 s, and forgets the keeper. Also dismisses a keeper whose agent has
/// already exited.
String keeperKillCommand(String keeperId) {
  _checkKeeperId(keeperId);
  return _command(['kill', keeperId]);
}
