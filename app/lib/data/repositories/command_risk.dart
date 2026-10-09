/// Why a command, a question or an option deserves a second tap, in a few
/// words; null when nothing in it does.
///
/// A hint, never the only safeguard: the card always shows the command, and a
/// list of patterns will always have gaps. The rules look at the text of the
/// thing being approved (the command block, the question, the option) and
/// never at the scrollback around it: a diff that mentions "remove" says
/// nothing about the command below it.
///
/// Rules are ordered by consequence and the first match names the reason. Each
/// one matches a command the way it is typed (`git push`, `rm -r`), not a
/// bare word, so `rg "remove_user"` and `git log --grep=delete` pass.
library;

import '../decision/mode_danger.dart' show ModeRisk, assessMode;

/// The first reason [text], taken as a shell command, deserves a second look.
String? commandRisk(String text) => _first(_commandRules, text);

/// The same for a natural-language question or option label ("Remove 3
/// files?", "Delete all branches").
String? proseRisk(String text) => _first(_proseRules, text);

/// A command or a sentence: what an option label or a one-line question may be.
String? riskOf(String text) => commandRisk(text) ?? proseRisk(text);

/// Whether an option grants something that outlives this answer ("Yes, and
/// don't ask again for ...", "Allow always", "allow all edits during this
/// session") or switches the session to a mode that asks for less ("Yes, and
/// bypass permissions", "Yes, auto-accept edits"). One tap is too easy for a
/// permission that stays. The mode words are the ones `assessMode` reads, so
/// the label of an option and the mode it names are judged alike; "manually
/// approve edits" asks for more, not less, and passes.
bool grantsStandingPermission(String optionText) =>
    _standing.hasMatch(optionText) || assessMode(name: optionText).risk != ModeRisk.none;

/// Shown on the confirm chip for a standing grant.
const standingPermission = 'standing permission';

final _standing = RegExp(
  r"(?:don.?t|do\s+not|never)\s+ask\s+again|\balways\b|\ballow\s+all\b|"
  r'(?:this|the\s+rest\s+of\s+(?:the|this))\s+session|\ball\s+edits\b',
  caseSensitive: false,
);

class _Rule {
  _Rule(String pattern, this.reason, {bool caseSensitive = false})
      : re = RegExp(pattern, caseSensitive: caseSensitive);

  final RegExp re;
  final String reason;
}

String? _first(List<_Rule> rules, String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ');
  for (final r in rules) {
    if (r.re.hasMatch(flat)) return r.reason;
  }
  return null;
}

/// Where a command word can start: the beginning, after a space, a separator,
/// a pipe, a subshell, a brace, a quote or a backslash. `--rm` and `a-rm` do
/// not start one; `\rm`, `"rm"`, `eval "rm -rf /"` and `docker exec c 'rm -rf /'`
/// do. A quote opens a word, so a command that is only quoted text
/// (`git commit -m "rm -rf is dangerous"`) is flagged too: a wrong hold costs
/// a tap, a missed one costs the person's files.
const _start = r'''(?:^|[\s;&|(`{"'\\])''';

/// The quote that may close a quoted command word (`"rm" -rf /`).
const _close = '''["']?''';

/// A command word typed with its directory too (`/bin/rm`, `/usr/bin/git`).
const _cmd = '$_start' r'(?:[\w.~-]*/)*';

/// `git`, then the global options that may come before the subcommand
/// (`-C <dir>`, `-c k=v`, `--no-pager`, `--git-dir <dir>`): `git -C repo push`
/// is `git push`.
///
/// The alternatives are mutually exclusive: an option that takes a value is
/// matched only with its value, and the plain-option form refuses to match
/// those names. With both able to match `-C`, a run of `-C -C -C ...` could be
/// split in exponentially many ways and a failed match took minutes.
const _gitValued = r'(?:-[Cc]|--(?:git-dir|work-tree|namespace))';
const _git = r'\bgit(?:\s+(?:' '$_gitValued' r'\s+\S+|(?!' '$_gitValued' r'(?:\s|$))-[\w-]+(?:=\S+)?))*';

final _commandRules = <_Rule>[
  // Remote and history.
  _Rule('$_git' r'\s+push\b[^;&|]*(?:--force(?:-with-lease)?\b|\s-f\b|\s\+\S)', 'force-pushes'),
  _Rule('$_git' r'\s+push\b', 'pushes to a remote'),

  // Data that does not come back.
  _Rule('$_cmd(?:rm|rmdir|unlink|shred)$_close' r'\s+\S', 'deletes files'),
  _Rule(
    r'''\b(?:ba|z|da|k)?sh(?:\s+-\S+)*?\s+-\w*c\s+["'](?:[^"']*[\s;&|])?(?:[\w.~-]*/)*(?:rm|rmdir|unlink|shred)\s+\S''',
    'deletes files',
  ),
  _Rule(r'\bxargs\s+(?:-\S+\s+)*(?:sudo\s+)?(?:rm|rmdir|unlink|shred)\b', 'deletes files'),
  _Rule(r'\bfind\b[^;&|]*\s-delete\b', 'deletes files'),
  _Rule('$_git' r'\s+clean\b', 'deletes files'),
  _Rule('${_cmd}dd$_close' r'\s+[^;&|]*\bof=', 'overwrites a disk'),
  _Rule(r'\b(?:mkfs(?:\.\w+)?|wipefs)\b', 'overwrites a disk'),

  // Work in a repository.
  _Rule('$_git' r'\s+reset\b[^;&|]*--hard\b', 'discards git changes'),
  _Rule('$_git' r'\s+checkout\b[^;&|]*\s(?:--\s+)?\.(?:\s|$)', 'discards git changes'),
  _Rule('$_git' r'\s+restore\b(?![^;&|]*--staged)[^;&|]*\s\.(?:\s|$)', 'discards git changes'),
  _Rule('$_git' r'\s+branch\b[^;&|]*\s-D\b', 'discards git changes', caseSensitive: true),
  _Rule('$_git' r'\s+stash\s+(?:drop|clear)\b', 'discards git changes'),
  _Rule('$_git' r'\s+(?:filter-branch|filter-repo)\b', 'discards git changes'),
  _Rule('$_git' r'\s+reflog\s+(?:expire|delete)\b', 'discards git changes'),

  // Visible to other people.
  _Rule(
    r'\b(?:(?:npm|pnpm|yarn|bun)\s+publish|cargo\s+publish|twine\s+upload|poetry\s+publish|'
    r'gem\s+push|mvn\s+deploy|helm\s+push|docker\s+(?:image\s+)?push|'
    r'gh\s+(?:release\s+(?:create|upload|delete)|pr\s+merge|repo\s+(?:create|delete)|workflow\s+run))\b',
    'publishes or merges',
  ),

  // Somebody else's machines.
  _Rule(
    r'\b(?:(?:terraform|tofu)\s+(?:apply|destroy|import|taint|untaint|state\s+(?:rm|mv|push))|'
    r'pulumi\s+(?:up|destroy|refresh)|'
    r'kubectl\s+(?:apply|delete|replace|scale|patch|edit|drain|cordon|uncordon|rollout|exec|create|annotate|label|set|taint)|'
    r'helm\s+(?:install|upgrade|uninstall|delete|rollback)|ansible-playbook|'
    r'(?:cdk|sls|serverless|sam|fly|flyctl|wrangler)\s+(?:deploy|destroy|remove|publish))\b',
    'changes infrastructure',
  ),
  _Rule(r'\b(?:gcloud|az)\b[^;&|]*\s(?:delete|create|deploy|update|reset|resize)\b', 'changes infrastructure'),
  _Rule(
    r'\baws\b[^;&|]*\s(?:s3\s+(?:rm|rb|sync|mv)|'
    r'(?:delete|terminate|remove|create|put|update|stop|reboot|deregister|modify|invoke|run|start|attach|detach)-\S+|invoke)\b',
    'changes infrastructure',
  ),
  _Rule(r'\b(?:ssh|scp|sftp)\s', 'runs on another machine'),
  _Rule(r'\brsync\b[^;&|]*\s\S+:\S', 'runs on another machine'),

  // Code that was not written here.
  _Rule(
    r'\b(?:curl|wget)\b[^;&]*\|\s*(?:sudo\s+(?:-\S+\s+)*)?'
    r'(?:(?:ba|z|da|k)?sh\b|'
    // An interpreter that reads the script from stdin: bare, or with a lone `-`.
    // `| python3 -m json.tool` and `| node script.js` read something else.
    r'(?:python[\d.]*|node|nodejs|deno|perl|ruby|php)(?:\s+-(?=\s|$)|\s*(?:$|[;&|)])))|'
    // A shell, `eval`, `source` or `.` that runs what a download printed:
    // `bash -c "$(curl ...)"`, `source <(curl ...)`.
    r'\b(?:(?:ba|z|da|k)?sh|eval|source)\b[^;&]*(?:[$<]\(|`)\s*(?:curl|wget)\b|'
    r'(?:^|[\s;&|(])\.\s+<\(\s*(?:curl|wget)\b',
    'runs a downloaded script',
  ),

  _Rule(
    r'\b(?:curl|wget)\b[^;&|]*(?:\s-X\s*|--request[\s=]+|--method[\s=]+)DELETE\b',
    'sends a DELETE request',
  ),
  _Rule(
    r'\bpython[\d.]*\s+(?:-\S+\s+)*-c\s+.*\b(?:rmtree|os\.(?:remove|unlink|rmdir|removedirs))\b',
    'deletes files',
  ),

  // Data somebody else reads.
  _Rule(
    r'\b(?:drop|truncate|alter)\s+(?:table|database|schema|index|view|column|user|role)\b|'
    r'\bdelete\s+from\b|\binsert\s+into\b|\b(?:flushall|flushdb)\b|'
    r'''\bupdate\s+[\w."`\[\]]+\s+set\b|'''
    r'\bdb\.[\w.]+\.(?:drop|deleteMany|deleteOne|remove|updateMany|updateOne|insertMany)\b',
    'changes a database',
  ),
  _Rule(
    r'\b(?:make|just|task|rake|npm\s+run|pnpm(?:\s+run)?|yarn(?:\s+run)?|bun\s+run)\s+[\w:.-]*migrat\w*|'
    r'\bmanage\.py\s+(?:migrate|flush|sqlflush)\b|\bprisma\s+(?:migrate|db\s+(?:push|execute))\b|'
    r'\b(?:rails|rake)\s+db:\w+|'
    r'\b(?:alembic|flyway|liquibase|dbmate|goose|knex|sequelize|typeorm|atlas)\b[^;&|]*\b'
    r'(?:upgrade|migrate|apply|up|down|deploy|reset|rollback|revert)\b',
    'changes a database',
  ),

  // The machine itself.
  _Rule('$_cmd(?:sudo|doas)' r'\b', 'runs as root'),
  _Rule(
    r'\bsystemctl\s+(?:stop|restart|disable|mask|kill|reboot|poweroff|halt)\b|'
    r'\bservice\s+\S+\s+(?:stop|restart)\b|'
    '$_cmd(?:shutdown|reboot|poweroff|halt)' r'\b|'
    // A signal to everything (`kill -9 -1`) is a number too; `kill $PID` and
    // `kill -s TERM 42` name a process like `kill 42` does.
    r'\bkill\s+(?:-\S+\s+|[a-z]+\s+)*(?:-?\d|\$)|\b(?:pkill|killall)\b',
    'stops processes',
  ),
  _Rule(r'\b(?:chmod\s+(?:-\S*R\S*|[0-7]*777)|chown\s+-\S*R\S*)\b', 'changes permissions'),
  _Rule(r'(?:>>?|\btee\b(?:\s+-\S+)*)\s*\S*\.ssh/\S', 'changes ssh keys'),
  _Rule(
    r'\bdocker\b[^;&|]*\bprune\b|\bdocker\s+(?:rm|rmi|kill|stop)\s|'
    r'\bdocker\s+(?:volume|network|image|container)\s+rm\b|'
    r'\bdocker[ -]compose\s+down\b[^;&|]*\s-v\b',
    'removes containers or volumes',
  ),
];

/// Words of a question or an option, not of a command: "Delete all branches",
/// "Overwrite config.json?". Whole words only, so `delete_user.dart` passes.
final _proseRules = <_Rule>[
  _Rule(
    r'\b(?:delet(?:e|es|ed|ing)|remov(?:e|es|ed|ing)|overwrit(?:e|es|ten|ing)|wip(?:e|es|ed|ing)|'
    r'destroy(?:s|ed|ing)?|eras(?:e|es|ed|ing)|purg(?:e|es|ed|ing)|truncat(?:e|es|ed|ing)|'
    r'drop(?:s|ped|ping)?|discard(?:s|ed|ing)?|force)\b',
    'deletes or overwrites',
  ),
];

/// Why writing to [path] deserves a second look, or null. A file write is not
/// a command, so [commandRisk] has nothing to read: what matters is where it
/// lands. Flags the places a write turns into code that runs later or into
/// access for someone else: ssh keys, shell start-up files, `/etc`, git hooks
/// and `.env` files.
String? pathRisk(String path) {
  final p = path.trim().replaceAll('\\', '/');
  for (final r in _pathRules) {
    if (r.re.hasMatch(p)) return r.reason;
  }
  return null;
}

final _pathRules = <_Rule>[
  _Rule(r'(?:^|/)\.ssh(?:/|$)|(?:^|/)authorized_keys2?$', 'changes ssh keys'),
  _Rule(
    r'(?:^|/)\.(?:bashrc|bash_profile|bash_login|bash_logout|zshrc|zshenv|zprofile|zlogin|profile)$|'
    r'(?:^|/)\.config/fish/config\.fish$',
    'changes shell start-up',
  ),
  _Rule(r'^/etc(?:/|$)', 'changes system files'),
  _Rule(r'(?:^|/)\.git/hooks(?:/|$)', 'changes git hooks'),
  _Rule(r'(?:^|/)\.env(?:\.[\w.-]+)?$', 'changes secrets'),
];
