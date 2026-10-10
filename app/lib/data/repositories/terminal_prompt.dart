import '../acp/acp_models.dart';
import '../services/herdr_api.dart';
import '../services/image_prep.dart' show pictureExtensions;

/// How long the agent gets to turn a pasted picture path into its attachment
/// before the message's line follows. Measured with Claude Code 2.1.x: a line
/// sent at once beats the attaching and the message goes out without the
/// picture; 100 ms and up works. Codex does not need it.
const pasteSettle = Duration(milliseconds: 250);

/// A message as it is typed into an agent's terminal: each picture's host path
/// pasted alone (the agent turns a pasted image path into an attachment:
/// `[Image #1]`), then the line with the text and the files' paths.
class TerminalPrompt {
  const TerminalPrompt({this.pastes = const [], required this.line});

  /// Absolute host paths of pictures, pasted one after the other.
  final List<String> pastes;

  /// The text and the files' paths; ends with enter when sent. A leading space
  /// when a picture was pasted before it, so the text never glues to the
  /// placeholder in an agent that does not convert the paste.
  final String line;
}

/// What a person is told when [terminalPrompt] gave null: the same sentence in
/// the chat and in the pane.
const terminalAttachmentRefusal =
    'This agent runs in a terminal; this kind of attachment cannot be sent to it. The message was not sent.';

/// [blocks] as what is typed into a terminal; null when a block cannot be
/// typed: a picture's bytes, embedded text, anything but text and file links,
/// or a file whose name no mention can carry ([_unsafeName]).
TerminalPrompt? terminalPrompt(List<ContentBlock> blocks) {
  final texts = <String>[];
  final tokens = <String>[];
  final pastes = <String>[];
  for (final block in blocks) {
    switch (block) {
      case TextBlock():
        // Joined below, in order, before the file tokens.
        texts.add(block.text);
      case ResourceLinkBlock():
        final path = _hostPath(block.uri);
        if (path == null || _unsafeName.hasMatch(path)) return null;
        if (_isPicture(path)) {
          pastes.add(path);
        } else {
          final token = _token(block.name);
          if (token == null) return null;
          tokens.add(token);
        }
      case ImageBlock() || AudioBlock() || EmbeddedResourceBlock() || UnknownBlock():
        return null;
    }
  }
  var line = [texts.join('\n'), ...tokens].where((s) => s.isNotEmpty).join(' ');
  if (pastes.isNotEmpty && line.isNotEmpty) line = ' $line';
  return TerminalPrompt(pastes: pastes, line: line);
}

String? _hostPath(String uri) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null || parsed.scheme != 'file') return null;
  return parsed.toFilePath(windows: false);
}

bool _isPicture(String path) {
  final slash = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  if (dot <= slash + 1) return false;
  return pictureExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// Names no agent's mention syntax can carry: a control character (a newline
/// would submit half a line) or a double quote (the quote that ends a quoted
/// mention).
final _unsafeName = RegExp(r'[\x00-\x1f\x7f"]');

/// `@path`, the agent's own file mention, for a file under the folder
/// (relative) and outside it (absolute) alike: Claude Code attaches `@/abs`
/// with no permission prompt, and does not attach a bare path (captured). In
/// double quotes when it holds whitespace. Null when the name cannot be typed.
String? _token(String name) {
  if (_unsafeName.hasMatch(name)) return null;
  return name.contains(RegExp(r'\s')) ? '@"$name"' : '@$name';
}

/// Types [p] into [paneId]: each picture's path alone, a moment for the agent
/// to take them, then the line and enter. An empty line only presses enter.
/// A [HerdrApiException] propagates; one after a paste leaves the picture in
/// the agent's input.
Future<void> sendTerminalPrompt(HerdrApi api, String paneId, TerminalPrompt p, {Duration settle = pasteSettle}) async {
  for (final path in p.pastes) {
    await api.sendInput(paneId, path);
  }
  if (p.pastes.isNotEmpty) await Future<void>.delayed(settle);
  if (p.line.trim().isEmpty) {
    await api.sendInput(paneId, '', keys: const ['enter']);
  } else {
    await api.sendLine(paneId, p.line);
  }
}

/// What a person is told when [sendTerminalPrompt] failed after a picture was
/// pasted.
const terminalPromptFailure =
    "The message was not sent. The agent's input may still hold the picture: check the terminal.";
