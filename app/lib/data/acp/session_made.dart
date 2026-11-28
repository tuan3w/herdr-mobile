import 'dart:convert';
import 'dart:typed_data';

import '../models/made_files.dart';
import '../models/remote_file.dart';
import '../models/web_bridge.dart' show isPreviewHost;
import 'acp_models.dart';
import 'background/background_work.dart' show BackgroundStatus, BackgroundTask;
import 'session_state.dart';
import 'turns/tool_summary.dart' show commandOf, outputTextOf;
import 'turns/turns.dart' show pathOfCall;

/// What a session made for the person to look at: a dev server on the machine,
/// an HTML or SVG page, a picture, a document (`made_files.dart`). Found in the
/// transcript, so it is not lost when the chat scrolls: a link an agent printed
/// an hour ago is here.
///
/// What counts is deliberately narrow. Run over 6,000 recorded sessions, a
/// scanner that took every `localhost` URL and every `.html` name from commands
/// and their output was right for about 6% of its rows: it listed the Milvus a
/// `curl` probed, the pages a `curl -o` downloaded, the files a `grep` named.
/// So a row needs the agent to have MADE or ANNOUNCED the thing:
/// - a page: a completed edit, a file a command writes (`>`, `tee`, `-o`,
///   `cp`/`mv` target, `open`), a "Saved to ..." line a tool printed, or a path
///   in the agent's own words;
/// - a picture or a document: the same, except that a document must be a NEW
///   file (not an edit of a README) and that naming one in words needs a word of
///   making right before it ("saved screenshots/a.png"), because the chat names
///   existing files all day;
/// - a server: a link in the agent's own words, or a banner line a launched
///   command printed (`Local: http://localhost:5173/`).
///
/// A video and a picture share one tab (`Media`), and so do the pictures a tool
/// returned inline (a browser screenshot has no file and no name); a link is
/// any address the agent wrote in its own words outside a code block, newest
/// first (`_sayLinks`): a pull request it opened and a dashboard it announced
/// are as much a link as the paper it cited. A link is SAID, not made, so it is
/// not counted by [madeCountOf].
enum MadeKind { server, page, picture, doc, video, link }

/// A server's state as far as the phone can tell. [seen] is the honest default:
/// a link in the output says the server existed, not that it still runs.
enum ServerState { running, stopped, seen }

/// One server or page, with the last place the transcript mentioned it.
class MadeAsset {
  const MadeAsset({
    required this.kind,
    required this.key,
    required this.title,
    required this.where,
    this.url,
    this.path,
    this.at,
    this.launch,
    this.image,
    required this.order,
  });

  final MadeKind kind;

  /// One row per key: the server's `localhost:5173`, a page's absolute path.
  final String key;

  /// What the row says: `localhost:5173/docs`, `report.html`. Raw text from the
  /// agent: the screen shows it through `visibleText`.
  final String title;

  /// A page's folder (`reports/`); empty for a server and for the top folder.
  final String where;

  /// The server's link, cleaned: `http`, a machine-local host, a valid port, no
  /// credentials.
  final Uri? url;

  /// The page's absolute path, or `~/...` when the home folder is not known
  /// here (the file layer expands it).
  final String? path;

  /// When the last mention arrived; null when the transcript has no times.
  final DateTime? at;

  /// Position of the last mention in the transcript: bigger is newer.
  final int order;

  /// What started the server, from the command that launched it (the
  /// transcript's, see [launchLabelOf]): `python label_server.py --port 8765`.
  /// Null for a file and when no launch was seen. Raw text from the agent.
  final String? launch;

  /// A picture a tool returned inside its result (a screenshot): the block the
  /// transcript holds, for the viewer. Null for a file. Never kept in a
  /// [MadeHistory]: the bytes are the log's, a row of it would be a stale key.
  final ImageBlock? image;

  /// The port, for matching a background task.
  int? get port => url == null ? null : (url!.hasPort ? url!.port : 80);

  /// A server row's address inside its app, decoded for display: `/docs`, `/`.
  String get route {
    final p = _display(url!.path);
    return url!.hasQuery ? '$p?${url!.query}' : p;
  }

  MadeAsset withLaunch(String? launch) => MadeAsset(
    kind: kind,
    key: key,
    title: title,
    where: where,
    url: url,
    path: path,
    at: at,
    launch: launch,
    image: image,
    order: order,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'key': key,
    'title': title,
    'where': where,
    if (url != null) 'url': url.toString(),
    if (path != null) 'path': path,
    if (at != null) 'at': at!.millisecondsSinceEpoch,
    if (launch != null) 'launch': launch,
    'order': order,
  };

  /// A row read back; null when [json] is not one.
  static MadeAsset? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = MadeKind.values.asNameMap()[json['kind']];
    final key = json['key'], title = json['title'], where = json['where'], order = json['order'];
    if (kind == null || key is! String || title is! String || where is! String || order is! int) return null;
    final url = json['url'], path = json['path'], at = json['at'], launch = json['launch'];
    if (url != null && url is! String ||
        path != null && path is! String ||
        at != null && at is! int ||
        launch != null && launch is! String) {
      return null;
    }
    final uri = url == null ? null : Uri.tryParse(url as String);
    if ((kind == MadeKind.server || kind == MadeKind.link) && uri == null) return null;
    return MadeAsset(
      kind: kind,
      key: key,
      title: title,
      where: where,
      url: uri,
      path: path as String?,
      at: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at as int),
      launch: launch as String?,
      order: order,
    );
  }
}

/// The most rows of each kind a session shows (servers, pages, pictures, docs
/// each keep their newest this many): a transcript can mention hundreds of
/// ports or screenshots, and a flood of one kind must not push another out.
const madeAssetsCap = 150;

/// The most pages of one server (one port) a session shows: the pages the agent
/// named, newest first. An agent that links a dashboard, its tabs and a health
/// check has made one thing, and a flood of API paths must not fill the list.
const madeServerPathsCap = 5;

/// Bumped whenever the scanning rules change what a log makes: a [MadeHistory]
/// kept under an older one was read with other rules and is read again.
const madeScanVersion = 4;

/// Whether [a] and [b] show the same rows. A tool call that streams replaces
/// the transcript list on every chunk and with it the list this returns; the
/// screens rebuild on a change of what they SHOW, not of the list.
bool sameMadeAssets(List<MadeAsset> a, List<MadeAsset> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x.key != y.key ||
        x.title != y.title ||
        x.where != y.where ||
        x.at != y.at ||
        x.url != y.url ||
        x.launch != y.launch) {
      return false;
    }
  }
  return true;
}

/// What the part of a session's log that is not on the phone made, as far as it
/// has been read: the rows (as [MadeFold.assets] gives them), how many
/// transcript items it held ([span]: the items read after it are numbered from
/// there, so they are newer) and the log byte offset it was read through
/// ([upTo]: the log is whole when that reaches where the shown part starts).
///
/// Why it exists: a phone opens a long chat with the last 192 KB of its log, and
/// a server or file made hours ago is not in that. Reading older lines again
/// and again over a radio is the cost this avoids: the rows are small, the log
/// is not, and an append-only log makes what was read stay right.
class MadeHistory {
  const MadeHistory({required this.assets, required this.span, required this.upTo});

  final List<MadeAsset> assets;
  final int span;
  final int upTo;

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': madeScanVersion,
        'span': span,
        'upTo': upTo,
        'assets': [for (final a in assets) a.toJson()],
      }),
    ),
  );

  /// Kept bytes read back; null for anything that is not a history of the
  /// current rules (damaged, older rules).
  static MadeHistory? fromBytes(Uint8List bytes) {
    try {
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map || j['v'] != madeScanVersion) return null;
      final span = j['span'], upTo = j['upTo'], list = j['assets'];
      if (span is! int || upTo is! int || list is! List) return null;
      final assets = <MadeAsset>[];
      for (final x in list) {
        final a = MadeAsset.fromJson(x);
        if (a == null) return null;
        assets.add(a);
      }
      return MadeHistory(assets: List.unmodifiable(assets), span: span, upTo: upTo);
    } on FormatException {
      return null;
    }
  }
}

/// The servers and pages of [items], newest mention first, one row each (a
/// server one row per path the agent named, see [madeServerPathsCap]).
/// [history] is what the part of the log before [items] made (see
/// [MadeHistory]): [items] are read on top of it, so a file made there and
/// deleted here is gone. Memoized by list identity, [cwd] (the folder a
/// relative path is taken against; empty counts as unknown) and [history], and
/// the scan of each item by the item.
List<MadeAsset> madeAssetsOf(List<TranscriptItem> items, {String? cwd, MadeHistory? history}) {
  final base = cwd == null || cwd.isEmpty ? null : cwd;
  final memo = _lists[items] ??= {};
  return memo[(base, history)] ??= (MadeFold(cwd: base, from: history)..addAll(items)).assets;
}

/// The background tasks that name [port] in their title or detail.
Iterable<BackgroundTask> _tasksOfPort(int port, Iterable<BackgroundTask> tasks) {
  final pattern = RegExp('(?<!\\d)$port(?!\\d)');
  return tasks.where((t) => pattern.hasMatch(t.title) || (t.detail != null && pattern.hasMatch(t.detail!)));
}

/// A server's state as far as the phone can tell: what the machine itself says
/// about its port ([listening], by port: true while something listens on it NOW,
/// false when the machine looked and nothing does). A port the machine gave no
/// answer for (it is unreachable, has no agent helper or no way to list ports,
/// or the question is still on its way) is [ServerState.seen], whatever the
/// transcript or the background tasks say: a link in the output, or a task that
/// names the port, says the server existed or was started, not that it listens.
ServerState serverStateOf(MadeAsset server, Map<int, bool> listening) {
  final port = server.port;
  final up = port == null ? null : listening[port];
  return switch (up) {
    true => ServerState.running,
    false => ServerState.stopped,
    null => ServerState.seen,
  };
}

/// What to call a server's app: the command of the background task that names
/// its port (a running one before an ended one, the last of each), else the
/// command the transcript launched it with ([MadeAsset.launch]), else null.
String? serverNameOf(MadeAsset server, Iterable<BackgroundTask> tasks) {
  final port = server.port;
  if (port != null) {
    BackgroundTask? pick;
    for (final t in _tasksOfPort(port, tasks)) {
      if (pick == null || t.status == BackgroundStatus.running || pick.status != BackgroundStatus.running) pick = t;
    }
    final label = pick == null ? null : launchLabelOf(pick.title);
    if (label != null) return label;
  }
  return server.launch;
}

/// One server and the pages the agent named on it: the row of `Apps`. Four
/// links `localhost:8765/review`, `/synth`... are one app, not four rows.
class MadeApp {
  const MadeApp({required this.port, required this.entry, required this.pages, required this.at});

  final int port;

  /// What a tap on the app opens: its root page when the agent named it, else
  /// the newest page it named.
  final MadeAsset entry;

  /// The port's other rows, newest first; empty when there are none.
  final List<MadeAsset> pages;

  /// The newest time any of its rows was mentioned; null when none has a time.
  final DateTime? at;
}

/// [servers] grouped by port into apps, in the order each port first appears
/// (the sheet's stable newest-first order).
List<MadeApp> madeAppsOf(Iterable<MadeAsset> servers) {
  final groups = <int, List<MadeAsset>>{};
  for (final s in servers) {
    (groups[s.port!] ??= []).add(s);
  }
  return [
    for (final MapEntry(key: port, value: group) in groups.entries)
      () {
        final root = group.where((a) => a.url!.path == '/' || a.url!.path.isEmpty).firstOrNull;
        final entry = root ?? group.first;
        DateTime? at;
        for (final a in group) {
          if (a.at != null && (at == null || a.at!.isAfter(at))) at = a.at;
        }
        return MadeApp(
          port: port,
          entry: entry,
          pages: [
            for (final a in group)
              if (!identical(a, entry)) a,
          ],
          at: at,
        );
      }(),
  ];
}

/// How many things [assets] are as the sheet counts them: an app once however
/// many of its pages were named, and every other row but a link. A link is
/// said, not made: "12 items made" would claim what the agent only mentioned.
int madeCountOf(Iterable<MadeAsset> assets) {
  final ports = <int>{};
  var others = 0;
  for (final a in assets) {
    if (a.kind == MadeKind.server) {
      ports.add(a.port!);
    } else if (a.kind != MadeKind.link) {
      others++;
    }
  }
  return ports.length + others;
}

// A command word for what a launch is: a runner or an interpreter plus its
// arguments. Not a step that only moves around or prints.
const _notALaunch = {'cd', 'export', 'source', '.', 'set', 'mkdir', 'echo'};

/// What to call the server a command started: the command without what
/// surrounds a launch (`cd`, `nohup`, `VAR=x`, redirects, `&`) and with the
/// program's folder dropped, at most 60 characters:
/// `cd /w && nohup /home/u/.venv/bin/python label_server.py --port 8765 > log 2>&1 &`
/// is `python label_server.py --port 8765`. Null when nothing is left.
String? launchLabelOf(String command) {
  for (final seg in _commandHead(command).split(_segments)) {
    // Leading `VAR=x` and wrappers are not the program; a redirect or `&` ends
    // its arguments (what follows is where its output goes).
    final words = <String>[];
    for (final w in _words(seg)) {
      if (_redirect.hasMatch(w)) break;
      if (words.isEmpty && (_assignment.hasMatch(w) || _wrappers.contains(w))) continue;
      words.add(w);
    }
    if (words.isEmpty || _notALaunch.contains(words.first)) continue;
    if (words.first.contains('/')) words[0] = words.first.substring(words.first.lastIndexOf('/') + 1);
    if (words.first.isEmpty) continue;
    final text = words.join(' ');
    return text.length > 60 ? '${text.substring(0, 59)}…' : text;
  }
  return null;
}

final _redirect = RegExp(r'^(?:&|\d*>|&>|<)');
final _assignment = RegExp(r'^[A-Za-z_]\w*=');
final _launchPort = RegExp(r'(?:--port[= ]|-p |http\.server |PORT=)(\d{2,5})(?!\d)');

final _lists = Expando<Map<(String?, MadeHistory?), List<MadeAsset>>>('session made list');
final _mentions = Expando<List<_Mention>>('session made mentions');
final _commandScans = Expando<List<_Mention>>('session made command');

enum _Act { server, file, drop, launch, link, shot }

/// One thing a transcript item said. [cd] is a `cd` the command made first.
/// A server mention is [weak] when it only names the origin (a banner, a bare
/// `localhost:5173`): the same item's own link to that port says more. A launch
/// mention names the [port] a command started and the [label] to call it by; it
/// makes no row (a launch command is not proof that a server came up). A link
/// mention is a GitHub address with its [title] and the repository in [where];
/// a shot is a picture a tool returned, under [key].
class _Mention {
  const _Mention.server(this.url, this.at, {this.weak = false})
    : act = _Act.server,
      path = null,
      cwd = null,
      cd = null,
      port = null,
      label = null,
      title = null,
      where = null,
      image = null,
      key = null;
  const _Mention.file(this.path, this.cwd, this.cd, this.at)
    : act = _Act.file,
      url = null,
      weak = false,
      port = null,
      label = null,
      title = null,
      where = null,
      image = null,
      key = null;
  const _Mention.drop(this.path, this.cwd, this.cd, this.at)
    : act = _Act.drop,
      url = null,
      weak = false,
      port = null,
      label = null,
      title = null,
      where = null,
      image = null,
      key = null;
  const _Mention.launch(this.port, this.label, this.at)
    : act = _Act.launch,
      url = null,
      path = null,
      cwd = null,
      cd = null,
      weak = false,
      title = null,
      where = null,
      image = null,
      key = null;
  const _Mention.link(this.url, this.title, this.where, this.at)
    : act = _Act.link,
      path = null,
      cwd = null,
      cd = null,
      weak = false,
      port = null,
      label = null,
      image = null,
      key = null;
  const _Mention.shot(this.key, this.image, this.title, this.at)
    : act = _Act.shot,
      url = null,
      path = null,
      cwd = null,
      cd = null,
      weak = false,
      port = null,
      label = null,
      where = null;

  final _Act act;
  final Uri? url;
  final String? path;
  final String? cwd;
  final String? cd;
  final DateTime? at;
  final bool weak;
  final int? port;
  final String? label;
  final String? title;
  final String? where;
  final ImageBlock? image;
  final String? key;
}

/// The rows of a transcript, one item at a time: what a long chat is read with
/// in slices (the UI thread belongs to the person) and what [madeAssetsOf]
/// and [MadeHistory] are made of.
class MadeFold {
  /// [from]: what the log made before the first item added; the items are
  /// numbered after it, so their rows are newer than its rows.
  MadeFold({String? cwd, MadeHistory? from}) : _cwd = cwd == null || cwd.isEmpty ? null : cwd, _next = from?.span ?? 0 {
    if (from != null) {
      for (final a in from.assets) {
        _byKey[a.key] = a;
        // Newest first: the newest launch of a port is kept.
        if (a.kind == MadeKind.server && a.launch != null) _launchByPort.putIfAbsent(a.port!, () => a.launch!);
      }
    }
  }

  final String? _cwd;
  final _byKey = <String, MadeAsset>{};

  /// What last launched each port (see [launchLabelOf]); a row's [MadeAsset.launch].
  final _launchByPort = <int, String>{};
  int _next;

  void addAll(Iterable<TranscriptItem> items) {
    for (final item in items) {
      add(item);
    }
  }

  void add(TranscriptItem item) {
    final index = _next++;
    final mentions = _mentionsOf(item);
    // A port the item linked to with a path of its own: its bare `localhost:PORT`
    // and the banner that names only the origin say nothing more.
    final linked = {
      for (final m in mentions)
        if (m.act == _Act.server && !m.weak) _portOf(m.url!),
    };
    var seq = 0;
    for (final m in mentions) {
      // Items are 1000 apart, the mentions of one item in the order scanned.
      final order = index * 1000 + seq++;
      switch (m.act) {
        case _Act.server:
          if (m.weak && linked.contains(_portOf(m.url!))) break;
          final asset = _serverOf(m.url!, m.at, order);
          _byKey[asset.key] = asset;
        case _Act.file:
          final asset = _fileOf(m, _cwd, order);
          if (asset != null) _byKey[asset.key] = asset;
        case _Act.drop:
          final key = _placed(m, _cwd);
          if (key != null) _byKey.remove(key);
        case _Act.launch:
          _launchByPort[m.port!] = m.label!;
        case _Act.link:
          final key = m.url.toString();
          final old = _byKey[key];
          // The same address said again keeps the longer name: the command that
          // made a pull request knew its title, a later "opened PR" line does not.
          final title = old != null && old.title.length > m.title!.length ? old.title : m.title!;
          _byKey[key] = MadeAsset(
            kind: MadeKind.link,
            key: key,
            title: title,
            where: m.where!,
            url: m.url,
            at: m.at,
            order: order,
          );
        case _Act.shot:
          _byKey[m.key!] = MadeAsset(
            kind: MadeKind.picture,
            key: m.key!,
            title: m.title!,
            where: '',
            image: m.image,
            at: m.at,
            order: order,
          );
      }
    }
  }

  /// How many items the log has been read through (the first number the next
  /// item gets).
  int get span => _next;

  /// The rows, newest first. Each kind keeps its newest [madeAssetsCap], and a
  /// port its newest [madeServerPathsCap] pages, so a flood of one thing never
  /// pushes another out.
  List<MadeAsset> get assets => _kept((_) => true);

  /// [assets] without the pictures a tool returned: what is kept (in memory and
  /// on disk alike) is read again from the log, which holds their bytes. The cap
  /// is applied after they are left out, so they cannot push a file out of it.
  List<MadeAsset> _kept(bool Function(MadeAsset) keep) {
    final out = _byKey.values.where(keep).toList()..sort((a, b) => b.order.compareTo(a.order));
    final seen = <MadeKind, int>{};
    final perPort = <int, int>{};
    final kept = <MadeAsset>[];
    for (final a in out) {
      final n = seen[a.kind] = (seen[a.kind] ?? 0) + 1;
      if (n > madeAssetsCap) continue;
      if (a.kind == MadeKind.server) {
        final port = a.port!;
        final p = perPort[port] = (perPort[port] ?? 0) + 1;
        if (p > madeServerPathsCap) continue;
      }
      kept.add(a.kind == MadeKind.server && _launchByPort[a.port!] != null ? a.withLaunch(_launchByPort[a.port!]) : a);
    }
    return List.unmodifiable(kept);
  }

  /// What is known now, to be kept: read through [upTo] bytes of the log.
  MadeHistory history(int upTo) => MadeHistory(assets: _kept((a) => a.image == null), span: _next, upTo: upTo);
}

int _portOf(Uri url) => url.hasPort ? url.port : 80;

List<_Mention> _mentionsOf(TranscriptItem item) {
  // A message that is still streaming grows under the same object and the
  // item list is not replaced by a chunk: it is read once it has settled.
  if (item is TranscriptMessage && item.live != null) return const [];
  return _mentions[item] ??= _scan(item);
}

/// Per item, at most this many mentions: one message cannot bury the rest.
const _perItem = 40;

List<_Mention> _scan(TranscriptItem item) {
  final out = <_Mention>[];
  switch (item) {
    case TranscriptMessage(role: MessageRole.agent, :final text, :final at):
      _say(text.length > _textCap ? text.substring(0, _textCap) : text, at, out);
    case TranscriptTool(:final call, :final at):
      final done = call.status == ToolStatus.completed;
      // A command that did not run (denied, failed, cancelled, still waiting)
      // wrote and removed nothing. Only a server banner is read before the end:
      // a server never finishes, and its address is printed while it runs.
      final printing = done || call.status == ToolStatus.inProgress;
      // Paths a delete diff of this call removes: the edit below must not list them again.
      final deleted = <String>{};
      for (final c in call.content) {
        if (c is ToolDiff && done) {
          // A page counts whenever it was written; a document only when the
          // agent CREATED it (an edit of a README is not something it made). A
          // patch that leaves nothing behind (Codex deletes a file this way: old
          // text, no new text) is a removal, and an empty "new" file is not a document.
          final kind = _kindOf(c.path);
          final p = kind == null ? null : _cleanPath(c.path);
          if (p == null) continue;
          if (c.newText.isEmpty && c.oldText != null) {
            out.add(_Mention.drop(p, call.cwd, null, at));
            deleted.add(p);
          } else if (kind == MadeFileKind.page ||
              kind == MadeFileKind.doc && c.oldText == null && c.newText.isNotEmpty) {
            out.add(_Mention.file(p, call.cwd, null, at));
          }
        }
      }
      if (done && (call.kind == ToolKind.edit || call.kind == ToolKind.delete)) {
        final p = pathOfCall(call);
        final kind = p == null ? null : _kindOf(p);
        if (p != null && kind != null) {
          final clean = _cleanPath(p);
          if (clean != null) {
            if (call.kind == ToolKind.delete) {
              out.add(_Mention.drop(clean, call.cwd, null, at));
            } else if (kind == MadeFileKind.page && !deleted.contains(clean)) {
              out.add(_Mention.file(clean, call.cwd, null, at));
            }
          }
        }
      }
      if (call.kind == ToolKind.execute) {
        final command = commandOf(call);
        if (command != null) {
          if (done) {
            // The patches of a streaming call replace the call but keep its input.
            final key = call.rawInput;
            final scanned = key is Map
                ? (_commandScans[key] ??= _scanCommand(command, call.cwd))
                : _scanCommand(command, call.cwd);
            out.addAll(scanned.map((m) => _withTime(m, at)));
            // A launch names its port. It makes no row by itself: only a link or a
            // banner does, and then the row says what started it.
            final head = _commandHead(command);
            if (_launchLike.hasMatch(head) && !_testRun.hasMatch(head) && !_isProbe(command)) {
              final label = launchLabelOf(command);
              if (label != null) {
                for (final m in _launchPort.allMatches(head)) {
                  final port = int.parse(m.group(1)!);
                  if (port >= 1 && port <= 65535) out.add(_Mention.launch(port, label, at));
                }
              }
            }
          }
          // What a launched command printed names the server. Not what a probe printed.
          final printed = outputTextOf(call);
          if (printed != null && printing && !_isProbe(command)) {
            _banners(printed, command, at, out);
            if (done) _saved(printed, call.cwd, at, out);
          }
          // What `gh` printed for a command that makes a pull request, an issue, a
          // release or a CI run: its own address.
          if (done && printed != null) _ghLinks(command, printed, at, out);
        }
      }
      if (done) _shots(call, at, out);
    default:
  }
  return out.length > _perItem ? out.sublist(0, _perItem) : out;
}

_Mention _withTime(_Mention m, DateTime? at) => switch (m.act) {
  _Act.server => _Mention.server(m.url, at, weak: m.weak),
  _Act.file => _Mention.file(m.path, m.cwd, m.cd, at),
  _Act.drop => _Mention.drop(m.path, m.cwd, m.cd, at),
  _Act.launch => _Mention.launch(m.port, m.label, at),
  _Act.link => _Mention.link(m.url, m.title, m.where, at),
  _Act.shot => _Mention.shot(m.key, m.image, m.title, at),
};

const _textCap = 20000;

// ----- the agent's own words -----

final _url = RegExp(
  r'https?://(?:[^\s/@<>"`]+@)?(?:\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.\-]+)(?::\d{1,5})?(?:[/?#][^\s<>"`)\]}]*)?',
  caseSensitive: false,
);
final _closingPunct = RegExp(r'''[.,;:!?'"]+$''');
final _markRun = RegExp(r'[*_~]+$');
// A bare `host:port` in prose: the spellings a dev server prints. Not after `/`
// (the scheme case, read by [_url]), `@` (`postgres://u@127.0.0.1:5432`), `:`
// (a tunnel, `ssh -L 8080:127.0.0.1:5432`), `.` or `-` (a longer name).
final _bareLocalhost = RegExp(
  r'(?<![\w/.\-@:])(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):(\d{2,5})(?![\w])',
  caseSensitive: false,
);
final _fence = RegExp(r'```[\s\S]*?```');
final _token = RegExp(r'''[^\s"'`()<>\[\]{}|;,=*?]+''');
// A word of making. `built` is apart: it also says what a build step did to the
// app ("I built the app"), so it counts only when the path follows it directly
// ("built dist/index.html"). `opened` and `output` are not here: the chat opens
// and outputs existing files all day.
final _madeVerb = RegExp(
  r'\b(?:created?|wrote|written|writing|saved?|generated?|exported?|produced?|made|report at|tạo|lưu|xuất|ghi)\b',
  caseSensitive: false,
);
final _builtVerb = RegExp(r'^built$', caseSensitive: false);
final _clauseBreak = RegExp(r'[,;:!?\n]|\.(?:\s|$)|\s(?=(?:and|then|but)\s)', caseSensitive: false);
final _wordEdge = RegExp(r'''^[`*_"'(\[]+|[`*_"')\]]+$''');

/// Whether a word of making stands right before the path at [start] in [prose]:
/// only the clause the path is in is read (after the last `.`, `,`, `;`, `:`,
/// `!`, `?`, line break, `and`, `then` or `but`), and the verb must be within
/// its last 4 words ("saved the chart to charts/x.png", "created docs/spec.md").
/// Further back it is another thing the agent did ("I created the handler and
/// then updated the README.md"), or a path in a sentence about something else.
bool _madeBefore(String prose, int start) {
  final words = _clauseWordsBefore(prose, start);
  if (words.isEmpty) return false;
  if (_builtVerb.hasMatch(words.last)) return true;
  return _madeVerb.hasMatch(words.skip(words.length > 4 ? words.length - 4 : 0).join(' '));
}

/// The words of the clause the thing at [start] is in, up to it (see [_madeBefore]).
List<String> _clauseWordsBefore(String prose, int start) {
  final before = prose.substring(start - 80 < 0 ? 0 : start - 80, start);
  var tail = before;
  for (final b in _clauseBreak.allMatches(before)) {
    tail = before.substring(b.end);
  }
  return [
    for (final w in tail.split(RegExp(r'\s+')))
      if (w.replaceAll(_wordEdge, '').isNotEmpty) w.replaceAll(_wordEdge, ''),
  ];
}

// The agent says it did NOT touch the file: "I left /tmp/old_build.html alone",
// "unchanged docs/a.html", "not docs/b.md". Such a path is named, not made; a
// page with a folder in it counted without a verb, and this one was a row.
final _leftAlone = RegExp(
  r"\b(?:left|leave|leaving|untouched|unchanged|skipped|skipping|ignored|ignoring|not|never|without)\b|n't\b",
  caseSensitive: false,
);
final _sentenceBreak = RegExp(r'[;!?]|\.(?:\s|$)');

/// Whether the sentence the path at [start] is in says, within its last 8 words,
/// that the file was left alone. The window runs back over a `:` and a line
/// break, because the usual shape is a list ("Files I did not touch:\n- a.html").
bool _leftAloneBefore(String prose, int start) {
  final before = prose.substring(start - 120 < 0 ? 0 : start - 120, start);
  var tail = before;
  for (final b in _sentenceBreak.allMatches(before)) {
    tail = before.substring(b.end);
  }
  final words = [
    for (final w in tail.split(RegExp(r'\s+')))
      if (w.replaceAll(_wordEdge, '').isNotEmpty) w.replaceAll(_wordEdge, ''),
  ];
  return _leftAlone.hasMatch(words.skip(words.length > 8 ? words.length - 8 : 0).join(' '));
}

void _say(String text, DateTime? at, List<_Mention> out) {
  for (final m in _url.allMatches(text)) {
    final s = _serverUri(m.group(0)!, text.substring(0, m.start), keepPath: true);
    if (s != null) out.add(_Mention.server(s, at));
  }
  for (final m in _bareLocalhost.allMatches(text)) {
    final port = int.parse(m.group(1)!);
    if (port >= 1 && port <= 65535) {
      out.add(_Mention.server(Uri(scheme: 'http', host: 'localhost', port: port, path: '/'), at, weak: true));
    }
  }
  // Pages: a code block shows what a file CONTAINS (`<img src="logo.svg">`), so
  // it is not read; a bare name needs a verb of making just before it.
  final prose = text.replaceAll(_fence, ' ').replaceAll(_url, ' ');
  for (final m in _token.allMatches(prose)) {
    final raw = m.group(0)!;
    if (raw.length > 400) continue;
    // Nearly every token is a plain word: reject it before the costlier clean-up.
    if (!raw.contains('.')) continue;
    final p = _cleanPath(raw);
    final kind = p == null ? null : _kindOf(p);
    // A verb of making right before the path wins over a "not" further back
    // ("not the CSS, I wrote docs/a.html").
    if (p == null || kind == null || (_leftAloneBefore(prose, m.start) && !_madeBefore(prose, m.start))) continue;
    // A page with a folder in it counts; a bare name, and any picture or
    // document (the chat names existing README.md files and screenshots all day),
    // only right after a word of making.
    if (!p.contains('/') || kind != MadeFileKind.page) {
      if (!_madeBefore(prose, m.start)) continue;
    }
    out.add(_Mention.file(p, null, null, at));
  }
  _sayLinks(text, at, out);
}

/// The machine itself, spelled any way: [isPreviewHost]'s names, `*.localhost` and all of `127.0.0.0/8`.
bool _isLoopback(String host) => isPreviewHost(host) || host.endsWith('.localhost') || host.startsWith('127.');

// An address the agent wrote: "[the PR](https://...)" is called by its label.
final _linkLabel = RegExp(r'\[([^\]\n]{1,100})\]\($');
// Hosts that are placeholders, not places (`https://example.com/api`, the SVG namespace).
final _placeholderHost = RegExp(r'(?:^|\.)(?:example\.(?:com|org|net)|w3\.org)$|\.(?:example|invalid|test)$');
// A template, not an address: `https://api.x.dev/{id}/$name`.
final _templated = RegExp(r'[{}$]|%7B', caseSensitive: false);

/// Every address in the agent's prose. A code block is not read: it shows what a
/// command or a file CONTAINS (`curl https://...`, `<script src="https://...">`),
/// the same reason pages are not read from one.
void _sayLinks(String text, DateTime? at, List<_Mention> out) {
  final prose = text.replaceAll(_fence, ' ');
  for (final m in _url.allMatches(prose)) {
    final link = _saidLink(m.group(0)!, prose.substring(m.start < 120 ? 0 : m.start - 120, m.start));
    if (link != null) out.add(_Mention.link(link.$1, link.$2, link.$3, at));
  }
}

/// The address, what to call it and where it is; null for what is not a link to
/// look at: loopback (a server, read above), a name that cannot be on the
/// internet, a placeholder or template. A GitHub pull request, issue, release or
/// run is named by what it is. Credentials and the fragment are dropped; [before]
/// is the text just before the address.
(Uri, String, String)? _saidLink(String raw, String before) {
  final trimmed = _trimLink(raw, before);
  if (trimmed.length > 2000 || _templated.hasMatch(trimmed)) return null;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null) return null;
  final host = parsed.host.toLowerCase();
  // Loopback is the machine's own, and the phone's browser would open ITS own: a dead end, not a link.
  if (host.isEmpty || _isLoopback(host) || !(host.contains('.') || host.contains(':'))) return null;
  if (_placeholderHost.hasMatch(host)) return null;
  final gh = _ghUrl.firstMatch(trimmed);
  final github = gh == null || gh.start != 0 ? null : _ghLink(gh, null);
  if (github != null) return github;
  final uri = parsed.removeFragment().replace(userInfo: '', path: parsed.path.isEmpty ? '/' : null);
  final label = _linkLabel.firstMatch(before)?.group(1)?.trim();
  final path = uri.path == '/' ? '' : uri.path;
  // The port is part of the name: two dashboards of one machine differ by it.
  final name = '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}$path${uri.hasQuery ? '?${uri.query}' : ''}';
  final labelled = label != null && label.isNotEmpty;
  final named = labelled ? label : name;
  return (
    uri,
    named.length > 120 ? '${named.substring(0, 119)}…' : named,
    // A label does not say where it leads; an address already does.
    labelled ? (host.startsWith('www.') ? host.substring(4) : host) : '',
  );
}

// ----- links and pictures a tool returned -----

// What a pull request, issue, release or CI run is on GitHub. The id of a pull
// request, an issue and a run is digits; a release's is its tag.
final _ghUrl = RegExp(
  r'https://github\.com/([\w.\-]+)/([\w.\-]+)/(pull|issues|releases/tag|actions/runs)/([^\s/?#<>"`)\]}*~]+)',
  caseSensitive: false,
);
final _digits = RegExp(r'^\d+$');

/// The address of [m], what to call it (`PR #93 <title>`, `Release v0.1.51`) and
/// its repository; null when the id is not one.
(Uri, String, String)? _ghLink(RegExpMatch m, String? title) {
  // GitHub reads owner and repository without case: one row for one pull request.
  final owner = m.group(1)!.toLowerCase(), repo = m.group(2)!.toLowerCase(), type = m.group(3)!.toLowerCase();
  final id = m.group(4)!.replaceFirst(_closingPunct, '');
  if (type == 'releases/tag' ? id.isEmpty || id.length > 100 : !_digits.hasMatch(id)) return null;
  final uri = Uri.tryParse('https://github.com/$owner/$repo/$type/$id');
  if (uri == null) return null;
  final name = switch (type) {
    'pull' => 'PR #$id',
    'issues' => 'Issue #$id',
    'releases/tag' => 'Release ${_display(id)}',
    _ => 'Actions run $id',
  };
  final full = title == null || title.trim().isEmpty ? name : '$name ${title.trim()}';
  return (uri, full.length > 120 ? '${full.substring(0, 119)}…' : full, '$owner/$repo');
}

/// What the `gh` subcommands that make something print: its own address.
/// `gh pr view` and `gh release list` print about what is already there, so they
/// are not here; neither is `git push`, whose "Create a pull request" line is an
/// offer. `gh run view` prints "View this run on GitHub: <address>" for the run
/// the agent is checking; `gh run watch`, `gh run rerun` and `gh release upload`
/// print no address (per a review of gh's source; not run here), so a link of
/// theirs comes only from the agent's words.
const _ghMakes = {
  'pr create': 'pull',
  'issue create': 'issues',
  'release create': 'releases/tag',
  'release edit': 'releases/tag',
  'run view': 'actions/runs',
};

/// `gh` flags that take a value and may come before the subcommand
/// (`gh -R o/r pr create`): the value is not the subcommand.
const _ghGlobalValued = {'-R', '--repo', '--hostname'};

void _ghLinks(String command, String printed, DateTime? at, List<_Mention> out) {
  for (final seg in _commandHead(command).split(_segments)) {
    final all = _words(seg);
    var i = 0;
    while (i < all.length && (_assignment.hasMatch(all[i]) || _wrappers.contains(all[i]))) {
      i++;
    }
    if (i >= all.length || all[i] != 'gh') continue;
    final args = all.sublist(i + 1);
    final plain = <String>[];
    for (var j = 0; j < args.length; j++) {
      if (_ghGlobalValued.contains(args[j])) {
        j++;
      } else if (!args[j].startsWith('-')) {
        plain.add(args[j]);
      }
    }
    if (plain.length < 2) continue;
    final type = _ghMakes['${plain[0]} ${plain[1]}'];
    if (type == null) continue;
    String? title;
    for (var j = 0; j < args.length; j++) {
      if ((args[j] == '--title' || args[j] == '-t') && j + 1 < args.length) {
        title = args[j + 1];
      } else if (args[j].startsWith('--title=')) {
        title = args[j].substring(8);
      }
    }
    final head = printed.length > 8192 ? printed.substring(0, 8192) : printed;
    for (final line in head.split('\n')) {
      final l = line.length > 300 ? line.substring(0, 300) : line;
      for (final m in _ghUrl.allMatches(l)) {
        if (m.group(3)!.toLowerCase() != type) continue;
        final link = _ghLink(m, type == 'pull' || type == 'issues' ? title : null);
        if (link != null) out.add(_Mention.link(link.$1, link.$2, link.$3, at));
      }
    }
  }
}

/// The most pictures one tool call makes rows of: a tool that returns forty
/// frames has not made forty things to look at.
const _shotsPerCall = 6;

/// The pictures a finished tool call returned inside its result: a browser
/// screenshot, a rendered chart. Not the pictures a call READ, searched for or
/// fetched: the agent looks at those (1,813 of the 2,468 recorded results were
/// `read`), it did not make them. A picture with no data is not drawn here: the
/// chat shows it as a reference line.
void _shots(ToolCall call, DateTime? at, List<_Mention> out) {
  switch (call.kind) {
    case ToolKind.read || ToolKind.search || ToolKind.fetch || ToolKind.think || ToolKind.delete || ToolKind.switchMode:
      return;
    case ToolKind.edit || ToolKind.move || ToolKind.execute || ToolKind.other:
      break;
  }
  final line = call.title.trim().split('\n').first.trim();
  final title = line.isEmpty ? 'Image' : (line.length > 60 ? '${line.substring(0, 59)}…' : line);
  var n = 0;
  for (final (i, c) in call.content.indexed) {
    if (c is! ToolContentBlock) continue;
    final b = c.block;
    if (b is! ImageBlock || b.data.isEmpty) continue;
    if (++n > _shotsPerCall) break;
    out.add(_Mention.shot('shot:${call.toolCallId}:$i', b, title, at));
  }
}

// ----- commands -----

/// The command up to where a heredoc body starts: what follows is the content
/// of a file, whose own links and names are not what the agent made.
String _commandHead(String command) {
  final out = <String>[];
  for (final line in command.split('\n').take(6)) {
    out.add(line.length > 2000 ? line.substring(0, 2000) : line);
    if (line.contains('<<')) break;
  }
  return out.join('\n');
}

final _segments = RegExp(r'&&|\|\||[;|\n]');
const _wrappers = {'sudo', 'nohup', 'time', 'env', 'command', 'builtin'};

/// What a command that reads or probes does not make: its output is not a
/// banner. `localhost` after `ssh` or `docker exec` is another host.
const _probes = {
  'cat',
  'rg',
  'grep',
  'egrep',
  'sed',
  'awk',
  'git',
  'head',
  'tail',
  'less',
  'more',
  'curl',
  'wget',
  'http',
  'ssh',
  'scp',
  'kubectl',
  'jq',
  'ls',
  'find',
  'echo',
  'printf',
  'diff',
  'nl',
  'wc',
  'psql',
  'redis-cli',
  'gh',
  'nc',
};

bool _isProbe(String command) {
  for (final seg in _commandHead(command).split(_segments)) {
    final w = _words(seg).where((w) => !w.contains('=') && !_wrappers.contains(w)).toList();
    if (w.isEmpty) continue;
    final first = w.first;
    if (_probes.contains(first)) return true;
    if ((first == 'docker' || first == 'podman') &&
        w.length > 1 &&
        (w[1] == 'exec' || w[1] == 'run' && w.contains('-it'))) {
      return true;
    }
  }
  return false;
}

List<String> _words(String segment) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;
  for (final ch in segment.split('')) {
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        buf.write(ch);
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == ' ' || ch == '\t') {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    } else {
      buf.write(ch);
    }
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

const _outFlags = {'-o', '--output', '--out', '--outfile', '--screenshot', '--save', '--export', '--html'};

/// The pages a command writes, moves or removes: only what its words say it
/// writes (a redirect, `tee`, an output flag, a `cp`/`mv` target, `open`). A
/// leading `cd X` moves where a relative name is taken from.
List<_Mention> _scanCommand(String command, String? callCwd) {
  final out = <_Mention>[];
  String? cd;
  void page(String raw) {
    final p = _cleanPath(raw);
    if (p != null && _kindOf(p) != null) out.add(_Mention.file(p, callCwd, cd, null));
  }

  void drop(String raw) {
    final p = _cleanPath(raw);
    if (p != null && _kindOf(p) != null) out.add(_Mention.drop(p, callCwd, cd, null));
  }

  for (final seg in _commandHead(command).split(_segments)) {
    final all = _words(seg);
    var i = 0;
    while (i < all.length && (all[i].contains('=') && !all[i].startsWith('-') || _wrappers.contains(all[i]))) {
      i++;
    }
    if (i >= all.length) continue;
    final cmd = all[i];
    final args = all.sublist(i + 1);
    if (cmd == 'cd') {
      if (args.isNotEmpty) {
        final to = args.first;
        cd = cd == null || RemotePath.isAbsolute(to) || RemotePath.usesHome(to) ? to : RemotePath.normalize('$cd/$to');
      }
      continue;
    }
    // Redirects, wherever they stand in the segment.
    for (var j = 0; j < all.length; j++) {
      final w = all[j];
      if (w == '>' || w == '>>') {
        if (j + 1 < all.length) page(all[j + 1]);
      } else if (w.startsWith('>') && !w.startsWith('>&') && w.length > 1) {
        page(w.replaceFirst(RegExp(r'^>>?'), ''));
      }
    }
    final plain = [
      for (final a in args)
        if (!a.startsWith('-') && !a.startsWith('>')) a,
    ];
    switch (cmd) {
      case 'tee':
        plain.forEach(page);
      case 'cp':
        if (plain.length >= 2) page(plain.last);
      case 'mv':
        if (plain.length >= 2) {
          page(plain.last);
          plain.sublist(0, plain.length - 1).forEach(drop);
        }
      case 'rm' || 'unlink':
        plain.forEach(drop);
      case 'open' || 'xdg-open' || 'start' || 'sensible-browser':
        plain.forEach(page);
      case 'curl' || 'wget':
        // A download is not something the agent made.
        break;
      default:
        for (var j = 0; j < args.length; j++) {
          final a = args[j];
          if (_outFlags.contains(a) && j + 1 < args.length) {
            page(args[j + 1]);
          } else if (a.startsWith('--') && a.contains('=')) {
            final eq = a.indexOf('=');
            if (_outFlags.contains(a.substring(0, eq))) page(a.substring(eq + 1));
          }
        }
    }
  }
  return out;
}

// ----- what a launched command printed -----

// A labelled address ("Local:   http://localhost:5173/", "Network: http://...",
// "Local URL: http://localhost:8501"): the label opens the line and the URL
// follows it. The bare words `local` and `network` were too wide ("Network
// request to http://localhost:8000/api failed", "using local proxy
// http://127.0.0.1:7890").
final _labelled = RegExp(r'^[^\w]*(?:local|network)(?:\s+url)?\s*:\s*https?://', caseSensitive: false);
final _banner = RegExp(
  r'running (?:on|at)|serving http|ready (?:on|at|in)|started server|available at|'
  r'server (?:is )?(?:running|started)|development server|dev server|web server|app running|open .{0,20} at|view it at|you can now view',
  caseSensitive: false,
);
// "Listening on" is also what a fixture server inside a test, a proxy or a
// client library prints, so it counts only from a command that looks like a
// launch: it names one of these words. The list is short on purpose: a command
// outside it (`make check`) can still print a labelled or "running on" banner.
final _listening = RegExp(r'listening (?:on|at)|server (?:is )?listening', caseSensitive: false);
final _launchLike = RegExp(
  r'dev|serve|start|run|uvicorn|gunicorn|http\.server|flask|vite|next|npm|yarn|pnpm|bun|node|deno|python|php|ruby|rails',
  caseSensitive: false,
);
// A test run starts servers of its own and prints their addresses; none of it
// is something the person can open.
final _testRun = RegExp(
  r'(?:^|[\s;&|(])(?:pytest|py\.test|jest|mocha|tox|vitest\s+run|go\s+test|cargo\s+test|flutter\s+test|dart\s+test|make\s+test|'
  r'(?:npm|yarn|pnpm|bun)(?:\s+run)?\s+test(?::[\w-]+)?)(?![\w-])',
  caseSensitive: false,
);

/// A launch prints where it is up on a line of its own ("Local: http://...",
/// "Uvicorn running on http://...", "Serving HTTP on 0.0.0.0 port 8000
/// (http://0.0.0.0:8000/)"), near the top. Only those lines of the first 8 KB
/// are read, and only for the origin: a log that names the server on every
/// line, or an API response with a path, makes no row. Never from a test run.
void _banners(String printed, String command, DateTime? at, List<_Mention> out) {
  final head = _commandHead(command);
  if (_testRun.hasMatch(head)) return;
  final launch = _launchLike.hasMatch(head);
  final text = printed.length > 8192 ? printed.substring(0, 8192) : printed;
  for (final line in text.split('\n')) {
    final l = line.length > 300 ? line.substring(0, 300) : line;
    if (!_labelled.hasMatch(l) && !_banner.hasMatch(l) && !(launch && _listening.hasMatch(l))) continue;
    for (final m in _url.allMatches(l)) {
      final s = _serverUri(m.group(0)!, l.substring(0, m.start), keepPath: false);
      if (s != null) {
        out.add(_Mention.server(s, at, weak: true));
        final label = launchLabelOf(command);
        if (label != null) out.add(_Mention.launch(s.hasPort ? s.port : 80, label, at));
      }
    }
  }
}

final _savedVerb = RegExp(r'\b(?:saved|wrote|written|generated|exported|created|screenshot)\b', caseSensitive: false);

/// A tool that makes a file says so on a line of its own ("Saved screenshot to
/// out/a.png", "Wrote reports/q3.html"): the first 8 KB, a line with a word of
/// making and a path with a folder in it. A listing or a log names files
/// without the word.
void _saved(String printed, String? cwd, DateTime? at, List<_Mention> out) {
  final head = printed.length > 8192 ? printed.substring(0, 8192) : printed;
  for (final line in head.split('\n')) {
    final l = line.length > 300 ? line.substring(0, 300) : line;
    if (!_savedVerb.hasMatch(l)) continue;
    for (final m in _token.allMatches(l.replaceAll(_url, ' '))) {
      final raw = m.group(0)!;
      if (raw.length > 400) continue;
      final p = _cleanPath(raw);
      if (p != null && p.contains('/') && _kindOf(p) != null) out.add(_Mention.file(p, cwd, null, at));
    }
  }
}

// ----- servers -----

/// [raw] without what closes the sentence or the markdown around the link.
String _trimLink(String raw, String before) {
  // `**http://127.0.0.1:8766/**` was read as the path `/**`, a row named
  // `localhost:8766/**` that asked the server for a page that is not there.
  // A run of `*`, `_` or `~` is a mark only when the same run opens the link
  // (`**url**`, `_url_`, `~~url~~`): `?q=snake_` keeps its `_`.
  var trimmed = raw.replaceFirst(_closingPunct, '');
  final opening = _markRun.firstMatch(before)?.group(0);
  if (opening != null && trimmed.endsWith(opening)) {
    trimmed = trimmed.substring(0, trimmed.length - opening.length).replaceFirst(_closingPunct, '');
  }
  return trimmed;
}

/// [before] is the text just before the link.
Uri? _serverUri(String raw, String before, {required bool keepPath}) {
  final trimmed = _trimLink(raw, before);
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme.toLowerCase() != 'http' || !isPreviewHost(uri.host)) return null;
  // `:0` parses as no port at all, so the digits are read from the text.
  final written = RegExp(
    r'^https?://(?:[^/@]*@)?(?:\[[^\]]*\]|[^/:?#]*):(\d+)',
    caseSensitive: false,
  ).firstMatch(trimmed);
  final port = written != null ? int.parse(written.group(1)!) : (uri.hasPort ? uri.port : 80);
  if (port < 1 || port > 65535) return null;
  // Rebuilt: no credentials, no fragment.
  return Uri(
    scheme: 'http',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: keepPath && uri.path.isNotEmpty ? uri.path : '/',
    query: keepPath && uri.hasQuery && uri.query.isNotEmpty ? uri.query : null,
  );
}

MadeAsset _serverOf(Uri url, DateTime? at, int order) {
  final port = _portOf(url);
  final root = url.path == '/' || url.path.isEmpty;
  final path = root ? '' : _display(url.path);
  return MadeAsset(
    kind: MadeKind.server,
    // The root keeps the port's own name, a page adds its path.
    key: root ? 'localhost:$port' : 'localhost:$port${url.path}',
    title: 'localhost${url.hasPort ? ':$port' : ''}$path',
    where: '',
    url: url,
    at: at,
    order: order,
  );
}

String _display(String encoded) {
  try {
    return Uri.decodeComponent(encoded);
  } on FormatException {
    return encoded;
  }
}

// ----- pages -----

final _noise = RegExp(r'(?:^|/)(?:node_modules|site-packages|\.git|\.dart_tool)/|^/(?:usr|proc|sys|lib|opt)/');
final _drive = RegExp(r'^[A-Za-z]:[\\/]');

MadeFileKind? _kindOf(String path) => _noise.hasMatch(path) ? null : madeFileKindOf(path);

/// A path as the scanner will keep it, or null when it is not a usable path of
/// the machine: a shell variable, a URL, a Windows drive, `~user`.
String? _cleanPath(String raw) {
  var p = raw.trim();
  if (p.startsWith('file://')) p = p.substring(7);
  p = p
      .replaceFirst(RegExp(r'[.,:;!?]+$'), '')
      .replaceFirst(RegExp(r':\d+(?::\d+)?$'), '')
      .replaceFirst(RegExp(r'#[^/]*$'), '');
  if (p.isEmpty || p.contains(r'$') || p.contains('`') || p.contains('://') || _drive.hasMatch(p)) return null;
  if (p.startsWith('~') && !p.startsWith('~/')) return null;
  if (p.startsWith('//')) return null;
  return p;
}

/// The key of [m]'s path (absolute, normalized), or null when a relative path
/// has no folder to be taken against.
String? _placed(_Mention m, String? sessionCwd) {
  final path = m.path!;
  if (RemotePath.isAbsolute(path)) return RemotePath.normalize(path);
  if (RemotePath.usesHome(path)) return RemotePath.normalize(path);
  final cwd = m.cwd ?? sessionCwd;
  if (cwd == null || cwd.isEmpty || !RemotePath.isAbsolute(cwd)) return null;
  final base = m.cd == null ? cwd : RemotePath.resolve(m.cd!, cwd: cwd, home: null);
  if (base == null) return null;
  return RemotePath.resolve(path, cwd: base);
}

MadeAsset? _fileOf(_Mention m, String? sessionCwd, int order) {
  final key = _placed(m, sessionCwd);
  final fileKind = key == null ? null : _kindOf(key);
  if (key == null || fileKind == null) return null;
  final name = RemotePath.basename(key);
  final parent = RemotePath.parent(key);
  final folder = parent == '/' || parent == '.' ? '' : '${RemotePath.basename(parent)}/';
  final kind = switch (fileKind) {
    MadeFileKind.page => MadeKind.page,
    MadeFileKind.picture => MadeKind.picture,
    MadeFileKind.video => MadeKind.video,
    MadeFileKind.doc => MadeKind.doc,
  };
  return MadeAsset(kind: kind, key: key, title: name, where: folder, path: key, at: m.at, order: order);
}
