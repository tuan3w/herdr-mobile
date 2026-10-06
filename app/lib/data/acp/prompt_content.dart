import 'dart:convert';

import 'acp_models.dart';

/// What the phone puts into a prompt besides the typed text.
///
/// **A file mention (`@file`) is a `resource_link`** with `name` = the path
/// relative to the session's folder (the absolute path when the file lies
/// outside it), `uri` = the absolute `file://` URI on the host, and no
/// `title`. That is the one form that reads well in all four adapters (per
/// their upstream sources):
///
/// | Agent | What the model gets from a link |
/// | --- | --- |
/// | omp | `title ?? name ?? uri`: only the name, so it must be the relative path (`modes/acp/acp-agent.ts:1711`); a `title` would hide it |
/// | pi | `\n[Context] <uri>`: only the uri, so it must be absolute (`pi-acp/src/acp/translate/prompt.ts:22`) |
/// | Claude Code | `[@<last segment of the uri>](<uri>)`: only the uri (`formatUriAsLink`, `acp-agent.ts:10544`) |
/// | Codex | `[@<name>](<uri>)`: both (`CodexAcpClient.ts:1344`) |
///
/// **Embedded text** (`resource` with `text`) goes only to an agent that
/// advertised `promptCapabilities.embeddedContext`, and only up to
/// [maxEmbeddedBytes]; bigger files stay links, so a screen's worth of
/// context never becomes a megabyte prompt over a phone's link.
const maxEmbeddedBytes = 64 * 1024;

/// The mention of [absolutePath] (a path on the agent's host) for a session in
/// [cwd].
ResourceLinkBlock fileLinkBlock(String absolutePath, {required String cwd, String? mimeType, int? size}) =>
    ResourceLinkBlock(
      uri: Uri.file(absolutePath, windows: false).toString(),
      name: relativeToCwd(absolutePath, cwd),
      mimeType: mimeType,
      size: size,
    );

/// [absolutePath] relative to [cwd] when it lies below it, else unchanged.
String relativeToCwd(String absolutePath, String cwd) {
  var root = cwd;
  while (root.length > 1 && root.endsWith('/')) {
    root = root.substring(0, root.length - 1);
  }
  if (root == '/' || root.isEmpty) return absolutePath;
  final prefix = '$root/';
  if (absolutePath.startsWith(prefix) && absolutePath.length > prefix.length) {
    return absolutePath.substring(prefix.length);
  }
  return absolutePath;
}

/// The file [absolutePath] as embedded text when the agent takes embedded
/// context ([embeddedContext]) and [text] is within [maxBytes]; else a link.
ContentBlock fileBlock(
  String absolutePath, {
  required String cwd,
  String? text,
  bool embeddedContext = false,
  String? mimeType,
  int maxBytes = maxEmbeddedBytes,
}) {
  if (embeddedContext && text != null && utf8.encode(text).length <= maxBytes) {
    return EmbeddedResourceBlock(
      uri: Uri.file(absolutePath, windows: false).toString(),
      mimeType: mimeType ?? 'text/plain',
      text: text,
    );
  }
  return fileLinkBlock(absolutePath, cwd: cwd, mimeType: mimeType);
}

/// The blocks of one prompt: the typed [text] (left out when blank) first,
/// then the [attachments] in the order given.
List<ContentBlock> composePrompt(String text, [List<ContentBlock> attachments = const []]) => [
  if (text.trim().isNotEmpty) TextBlock(text),
  ...attachments,
];
