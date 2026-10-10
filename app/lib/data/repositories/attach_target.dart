import 'machine_connection.dart';

/// How a message's attachments reach the agent.
enum AttachMode {
  /// ACP content blocks: pictures and embedded text travel inside the prompt.
  blocks,

  /// Host paths typed into a terminal: the file is uploaded to the host and its
  /// path is pasted (a picture) or written into the line (a file), as a person
  /// at the keyboard would do it.
  paths,

  /// The agent takes no attachments.
  none,
}

/// Where a message's pictures and files go: what the attach flow needs of a
/// chat session or of an agent's pane, and nothing else.
abstract interface class AttachTarget {
  /// The inbox folder's key: uploads of one target share a folder, found again
  /// by the same key.
  String get key;

  MachineConnection get machine;

  /// The agent's folder: files under it go as relative paths.
  String get cwd;

  /// The agent takes pictures as content blocks (`promptCapabilities.image`).
  bool get acceptsImages;

  /// The agent takes embedded text resources.
  bool get acceptsEmbeddedContext;

  AttachMode get attachMode;
}

extension AttachTargetPictures on AttachTarget {
  /// A picture is downscaled and stripped of its metadata (`prepareImage`)
  /// before it goes: as a block for an agent that takes images, as a file for
  /// a terminal.
  bool get preparesPictures => acceptsImages || attachMode == AttachMode.paths;
}
