/// Where a slash command comes from. The order is the order they are listed:
/// what this project defines first, then the user's own, then the agent's.
enum SlashSource { project, user, builtIn }

/// One command or skill an agent accepts at the start of a prompt
/// (`/compact`, or Codex's `$review`).
class SlashCommand {
  const SlashCommand(this.name, this.description, this.source, {this.hint, this.trigger = '/'});

  /// Without the leading trigger; may contain `:` for a namespaced command.
  final String name;
  final String description;
  final SlashSource source;

  /// What the command's argument is for, shown after its name; null when it
  /// takes none.
  final String? hint;

  /// The character that starts the command: `/`, or `$` for Codex's skills.
  final String trigger;

  String get text => '$trigger$name';

  /// What pins and usage remember the command under: the bare name for a `/`
  /// command (as it always was), the name with its `$` for a skill, so a skill
  /// and a command of one name stay apart.
  String get usageKey => trigger == '/' ? name : '$trigger$name';

  @override
  bool operator ==(Object other) =>
      other is SlashCommand &&
      other.name == name &&
      other.description == description &&
      other.source == source &&
      other.hint == hint &&
      other.trigger == trigger;

  @override
  int get hashCode => Object.hash(name, description, source, hint, trigger);

  @override
  String toString() => 'SlashCommand($text, $source)';
}
