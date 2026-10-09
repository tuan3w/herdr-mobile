import '../models/herdr_models.dart';
import '../models/remote_file.dart';
import '../repositories/fleet_agent.dart';
import '../repositories/machine_connection.dart';

/// Where the session log of a pane is, as far as the app can tell.
sealed class LogLocation {
  const LogLocation();
}

/// The log is at [path] (validated: see [isReadableLogPath]).
final class Located extends LogLocation {
  const Located(this.path);
  final String path;
}

/// The agent has not written its file yet (a session has none until the first
/// message). [why] is a quiet status for the person; ask again later.
final class NotYet extends LogLocation {
  const NotYet(this.why);
  final String why;
}

/// The log cannot be found and waiting will not change that. [why] says what to
/// do; it is shown as it is.
final class Unlinked extends LogLocation {
  const Unlinked(this.why);
  final String why;
}

/// Finds the log of the agent in a pane. Every file access goes through
/// `machine.files` (SFTP): nothing is put in a shell, and every path built from
/// a log, a pid or a session id is validated before it is used.
abstract interface class SessionLogLocator {
  /// Whether the pane may have a log: cheap and synchronous, for the board and
  /// menus. [locate] has the final word.
  bool mayLocate(Pane pane);

  Future<LogLocation> locate(MachineConnection machine, Pane pane);
}

/// A log path worth reading: absolute, a `.jsonl`, no control characters and
/// no `..` segment.
bool isReadableLogPath(String path) =>
    RemotePath.isAbsolute(path) &&
    path.endsWith('.jsonl') &&
    path.length <= 4096 &&
    !path.codeUnits.any((c) => c < 0x20 || c == 0x7f) &&
    !path.split('/').contains('..');

/// omp tells herdr the path of its log (`kind: path`).
class OmpLocator implements SessionLogLocator {
  const OmpLocator();

  @override
  bool mayLocate(Pane pane) => FleetAgent.logPathOf(pane) != null;

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) async {
    final path = FleetAgent.logPathOf(pane);
    if (path == null || !isReadableLogPath(path)) {
      return const Unlinked('This agent does not name a session log.');
    }
    return Located(path);
  }
}
