/// Where a slash command comes from. The order is the order they are listed:
/// what this project defines first, then the user's own, then the agent's.
enum SlashSource { project, user, builtIn }

/// One command an agent accepts at the start of a prompt (`/compact`).
class SlashCommand {
  const SlashCommand(this.name, this.description, this.source);

  /// Without the leading slash; may contain `:` for a namespaced command.
  final String name;
  final String description;
  final SlashSource source;

  String get text => '/$name';

  @override
  bool operator ==(Object other) =>
      other is SlashCommand &&
      other.name == name &&
      other.description == description &&
      other.source == source;

  @override
  int get hashCode => Object.hash(name, description, source);

  @override
  String toString() => 'SlashCommand($text, $source)';
}
