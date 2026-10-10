import 'dart:convert';

import '../models/remote_file.dart';
import '../models/slash_command.dart';
import '../services/remote_files.dart';

/// The slash commands of an agent: what it ships with, plus the commands and
/// skills its user and project keep as Markdown files on the machine.
///
/// The built-in tables are a best effort: an agent adds and renames commands
/// between versions, so a command listed here may not exist in yours, and one
/// that exists may be missing. The palette only fills in the composer; the
/// agent has the last word when the line is sent.
///
/// Discovery reads the machine over SFTP and never fails: a machine without
/// files, a missing folder or an unreadable file just contributes nothing.
class SlashCatalog {
  SlashCatalog(this._files);

  final RemoteFiles _files;

  /// Most files read for one folder, so a huge skills folder cannot stall.
  static const maxFilesPerFolder = 200;

  /// How much of a file is read to find its description.
  static const headBytes = 4096;

  static const _parallel = 8;

  /// Built-ins, then what the machine has for [agent] working in [cwd].
  /// Names the user or project define replace a built-in of the same name.
  Future<List<SlashCommand>> load({required String agent, String? cwd}) async {
    final key = agent.toLowerCase();
    final home = await _home();
    var found = <SlashCommand>[
      ...await _project(key, cwd, home),
      ...await _user(key, home),
    ];
    // Codex looks in several folders: the first of a name is the one it uses.
    if (key == 'codex') {
      final seen = <String>{};
      found = [
        for (final c in found)
          if (seen.add(c.usageKey)) c,
      ];
    }
    final taken = {for (final c in found) c.usageKey};
    return [
      ...found,
      for (final c in builtInSlashCommands[key] ?? const <SlashCommand>[])
        if (!taken.contains(c.usageKey)) c,
    ];
  }

  Future<String?> _home() async {
    try {
      return await _files.home();
    } on RemoteFileException {
      return null;
    }
  }

  /// Codex reads `.agents/skills` in the folder it runs in and in each folder
  /// above it up to the repository root; how far that is is not known here, so
  /// this goes up [codexLevels] folders (never `/`, and never [home], which
  /// is the user's own).
  static const codexLevels = 6;

  static List<String> _folders(String cwd, String? home) {
    final out = <String>[];
    var dir = cwd;
    while (dir.length > 1 && dir.endsWith('/')) {
      dir = dir.substring(0, dir.length - 1);
    }
    for (var i = 0; i < codexLevels && dir.length > 1; i++) {
      if (dir != home) out.add(dir);
      final cut = dir.lastIndexOf('/');
      dir = cut <= 0 ? '/' : dir.substring(0, cut);
    }
    return out;
  }

  Future<List<SlashCommand>> _project(String agent, String? cwd, String? home) async {
    if (cwd == null || cwd.isEmpty) return const [];
    return switch (agent) {
      'claude' => [
          ...await _commandFiles('$cwd/.claude/commands', SlashSource.project, nested: true),
          ...await _skills('$cwd/.claude/skills', SlashSource.project),
        ],
      'codex' => [
          for (final dir in _folders(cwd, home)) ...await _skills('$dir/.agents/skills', SlashSource.project, trigger: r'$'),
        ],
      'opencode' => [
          ...await _commandFiles('$cwd/.opencode/command', SlashSource.project),
          ...await _commandFiles('$cwd/.opencode/commands', SlashSource.project),
        ],
      _ => const [],
    };
  }

  Future<List<SlashCommand>> _user(String agent, String? home) async {
    if (home == null) return const [];
    return switch (agent) {
      'claude' => [
          ...await _commandFiles('$home/.claude/commands', SlashSource.user, nested: true),
          ...await _skills('$home/.claude/skills', SlashSource.user),
        ],
      'codex' => [
          ...await _skills('$home/.agents/skills', SlashSource.user, trigger: r'$'),
          ...await _skills('$home/.codex/skills', SlashSource.user, trigger: r'$'),
        ],
      'opencode' => [
          ...await _commandFiles('$home/.config/opencode/command', SlashSource.user),
          ...await _commandFiles('$home/.config/opencode/commands', SlashSource.user),
        ],
      _ => const [],
    };
  }

  /// `*.md` files in [dir] as commands named after the file. With [nested], a
  /// file in a subfolder is `folder:file`, as Claude Code names it.
  Future<List<SlashCommand>> _commandFiles(
    String dir,
    SlashSource source, {
    bool nested = false,
    String prefix = '',
    int depth = 0,
  }) async {
    final entries = await _list(dir);
    final files = <RemoteEntry>[];
    final out = <SlashCommand>[];
    for (final e in entries) {
      if (e.isHidden) continue;
      if (e.isDirectory) {
        if (nested && depth < 3) {
          out.addAll(await _commandFiles(
            e.path,
            source,
            nested: true,
            prefix: '$prefix${e.name}:',
            depth: depth + 1,
          ));
        }
      } else if (e.isFile && e.name.endsWith('.md')) {
        files.add(e);
      }
    }
    files.sort((a, b) => a.name.compareTo(b.name));
    out.addAll(await _describeAll(
      files.take(maxFilesPerFolder).toList(),
      (e) => '$prefix${e.name.substring(0, e.name.length - 3)}',
      (e) => e.path,
      source,
    ));
    return out;
  }

  /// Skills: one folder each, with a `SKILL.md` inside, named after the folder.
  Future<List<SlashCommand>> _skills(String dir, SlashSource source, {String trigger = '/'}) async {
    final folders = [
      for (final e in await _list(dir))
        if (e.isDirectory && !e.isHidden) e,
    ]..sort((a, b) => a.name.compareTo(b.name));
    return _describeAll(
      folders.take(maxFilesPerFolder).toList(),
      (e) => e.name,
      (e) => '${e.path}/SKILL.md',
      source,
      trigger: trigger,
    );
  }

  Future<List<SlashCommand>> _describeAll(
    List<RemoteEntry> entries,
    String Function(RemoteEntry) name,
    String Function(RemoteEntry) file,
    SlashSource source, {
    String trigger = '/',
  }) async {
    final out = <SlashCommand>[];
    for (var i = 0; i < entries.length; i += _parallel) {
      final batch = entries.skip(i).take(_parallel).toList();
      final described = await Future.wait([
        for (final e in batch) _describe(file(e)),
      ]);
      for (var j = 0; j < batch.length; j++) {
        final text = described[j];
        // A skill folder without a SKILL.md is not a skill.
        if (text == null) continue;
        out.add(SlashCommand(name(batch[j]), describe(text), source, trigger: trigger));
      }
    }
    return out;
  }

  Future<List<RemoteEntry>> _list(String dir) async {
    try {
      return await _files.list(dir);
    } on RemoteFileException {
      return const [];
    }
  }

  Future<String?> _describe(String path) async {
    try {
      final bytes = await _files.read(path, length: headBytes);
      return utf8.decode(bytes, allowMalformed: true);
    } on RemoteFileException {
      return null;
    }
  }

  /// The one-line description of a command file: the `description:` of its
  /// front matter, else its first line of text.
  static String describe(String text) {
    final lines = const LineSplitter().convert(text);
    var i = 0;
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      final end = lines.indexWhere((l) => l.trim() == '---', 1);
      final head = end == -1 ? lines.length : end;
      for (i = 1; i < head; i++) {
        final m = _description.firstMatch(lines[i]);
        if (m == null) continue;
        var value = m.group(1)!.trim();
        // A block scalar (`>` or `|`) has its text on the next lines.
        if (value == '>' || value == '|' || value == '>-' || value == '|-') {
          final parts = <String>[];
          for (var j = i + 1; j < head && lines[j].startsWith(RegExp(r'\s')); j++) {
            parts.add(lines[j].trim());
          }
          value = parts.join(' ');
        }
        final clean = _unquote(value);
        if (clean.isNotEmpty) return _clip(clean);
      }
      i = end == -1 ? lines.length : end + 1;
    }
    for (; i < lines.length; i++) {
      final t = lines[i].trim().replaceFirst(RegExp(r'^#+\s*'), '');
      if (t.isNotEmpty) return _clip(t);
    }
    return '';
  }

  static final _description = RegExp(r'^description:\s*(.*)$');

  static String _unquote(String v) {
    if (v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  static String _clip(String v) => v.length <= 140 ? v : '${v.substring(0, 139)}…';
}

SlashCommand _b(String name, String description) =>
    SlashCommand(name, description, SlashSource.builtIn);

/// By herdr's agent label.
final Map<String, List<SlashCommand>> builtInSlashCommands = {
  'claude': [
    _b('clear', 'Start a new conversation'),
    _b('compact', 'Summarise the conversation to free context'),
    _b('model', 'Choose the model'),
    _b('resume', 'Resume an earlier conversation'),
    _b('rewind', 'Go back to an earlier point'),
    _b('context', 'Show what fills the context'),
    _b('cost', 'Show token usage'),
    _b('status', 'Show version, model and account'),
    _b('permissions', 'Manage tool permissions'),
    _b('memory', 'Edit memory files'),
    _b('init', 'Create a CLAUDE.md for this project'),
    _b('review', 'Review a pull request'),
    _b('agents', 'Manage subagents'),
    _b('mcp', 'Manage MCP servers'),
    _b('hooks', 'Manage hooks'),
    _b('config', 'Open settings'),
    _b('add-dir', 'Add a working folder'),
    _b('export', 'Export the conversation'),
    _b('todos', 'Show the todo list'),
    _b('doctor', 'Check the installation'),
    _b('help', 'Show help and commands'),
    _b('exit', 'Quit'),
  ],
  'codex': [
    _b('new', 'Start a new chat'),
    _b('resume', 'Resume an earlier chat'),
    _b('compact', 'Summarise the chat to free context'),
    _b('model', 'Choose the model and reasoning effort'),
    _b('approvals', 'Choose what needs approval'),
    _b('status', 'Show the session configuration'),
    _b('diff', 'Show the git diff'),
    _b('review', 'Review the working tree'),
    _b('mention', 'Mention a file'),
    _b('init', 'Create an AGENTS.md'),
    _b('mcp', 'List MCP tools'),
    _b('logout', 'Sign out'),
    _b('quit', 'Quit'),
  ],
  'opencode': [
    _b('new', 'Start a new session'),
    _b('sessions', 'Switch session'),
    _b('models', 'Choose the model'),
    _b('compact', 'Summarise the session'),
    _b('undo', 'Undo the last message and its changes'),
    _b('redo', 'Redo'),
    _b('share', 'Share the session'),
    _b('init', 'Create an AGENTS.md'),
    _b('themes', 'Choose a theme'),
    _b('help', 'Show help'),
    _b('exit', 'Quit'),
  ],
};
