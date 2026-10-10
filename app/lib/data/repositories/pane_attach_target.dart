import 'attach_target.dart';
import 'machine_connection.dart';

/// An agent in a terminal pane as a place to attach to: what the pane screen
/// hands to the attach flow. A shell takes no attachments, an agent takes host
/// paths. The pane's folder and agent are read when asked, so a pane that moves
/// or changes agent is followed.
class PaneAttachTarget implements AttachTarget {
  const PaneAttachTarget(this.machine, this.paneId);

  @override
  final MachineConnection machine;
  final String paneId;

  @override
  String get key => '${machine.profile.id}/$paneId';

  @override
  String get cwd => machine.paneById(paneId)?.cwd ?? '';

  @override
  bool get acceptsImages => false;

  @override
  bool get acceptsEmbeddedContext => false;

  @override
  AttachMode get attachMode => machine.paneById(paneId)?.agent != null ? AttachMode.paths : AttachMode.none;
}
