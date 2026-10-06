import '../../../data/acp/session_state.dart';
import '../../../data/decision/mode_danger.dart';

/// Whether the items of [state] from index [from] on hold a note, written
/// because the agent changed the mode on its own, that left the session in a
/// dangerous mode. The transcript only grows at its end, so the screen asks
/// about the items that arrived since it last asked and gives one
/// `Haptics.armed` for a yes: a mode that lowers the guard announces itself
/// once (the note), and is felt once (this).
///
/// Only the mode the session is in now counts: a note about a mode the agent
/// has already left (two changes in one batch) is not news any more.
bool announcesDanger(AgentSessionState state, int from) {
  final items = state.items;
  final current = currentModeOf(state);
  if (current == null || assessMode(id: current.id, name: current.name).risk != ModeRisk.dangerous) return false;
  for (var i = items.length - 1; i >= from && i >= 0; i--) {
    final item = items[i];
    if (item is TranscriptNote && item.modeId == current.id) return true;
  }
  return false;
}
