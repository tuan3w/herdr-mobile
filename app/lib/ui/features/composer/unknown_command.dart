import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'command_model.dart';

/// Holds a send whose first word is a `/command` the agent does not list, and
/// says so ([UnknownCommandNote]), once. A typo (`/clera`) would go to the model
/// as a message and cost a turn; "Send as message" sends it as typed.
///
/// The text stays in the field (nothing is lost), the hold ends the moment the
/// text changes, and a line the person chose to send is let through once.
/// Sent that way it is recorded like any sent command (`recordSent`), so the
/// word is not held again for that agent: a real command the agent's table
/// lacks costs one tap, once.
class UnknownCommandGuard extends ChangeNotifier {
  UnknownCommandGuard({required this.input, required this.model}) {
    input.addListener(_onInput);
  }

  final TextEditingController input;
  final CommandPaletteModel model;

  String? _held;
  String? _word;
  String? _allowed;

  /// The command word being held, or null.
  String? get word => _word;

  /// The agent the word was not found for, for the note.
  String? get agent => model.source.agent;

  /// Whether [line] must not be sent yet. Call it where the send starts, before
  /// anything is cleared.
  bool holds(String line) {
    final text = line.trim();
    if (text == _allowed) {
      _allowed = null;
      return false;
    }
    final word = model.unknownCommand(text);
    if (word == null) return false;
    _held = text;
    _word = word;
    Haptics.tick();
    notifyListeners();
    return true;
  }

  /// The person chose to send the held line as it is: [send] runs it again.
  void sendAnyway(VoidCallback send) {
    _allowed = _held;
    _held = null;
    _word = null;
    notifyListeners();
    send();
  }

  void _onInput() {
    final text = input.text.trim();
    if (_allowed != null && text != _allowed) _allowed = null;
    if (_held != null && text != _held) {
      _held = null;
      _word = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    input.removeListener(_onInput);
    super.dispose();
  }
}

/// The line above the composer that says the held word is not one of the
/// agent's commands, with the one way on. Takes no room when nothing is held.
class UnknownCommandNote extends StatelessWidget {
  const UnknownCommandNote({super.key, required this.guard, required this.onSend});

  final UnknownCommandGuard guard;

  /// Sends the composer's line (the screen's own send).
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: guard,
    builder: (context, _) {
      final word = guard.word;
      if (word == null) return const SizedBox.shrink();
      final ds = context.ds;
      final agent = guard.agent;
      return Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
        child: Semantics(
          liveRegion: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ds.surface,
              borderRadius: BorderRadius.circular(Radii.panel),
              border: Border.all(color: ds.hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.sm, Gap.sm),
              // Side by side only while the text keeps a readable width: at
              // large text sizes the button would take the row and leave the
              // sentence a letter wide, so it goes under it (as the update
              // buttons do).
              child: LayoutBuilder(
                builder: (context, room) {
                  final stacked = MediaQuery.textScalerOf(context).scale(16) > 21 || room.maxWidth < 300;
                  final sentence = Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(LucideIcons.info, size: 16, color: ds.textSecondary),
                      ),
                      const SizedBox(width: Gap.sm),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '/$word',
                                style: TextStyle(fontFamily: monoFamily, fontSize: 13, color: ds.text),
                              ),
                              TextSpan(
                                text: agent == null ? ' is not a command.' : ' is not one of $agent\u2019s commands.',
                              ),
                            ],
                          ),
                          style: Type.secondary.copyWith(color: ds.textSecondary),
                        ),
                      ),
                    ],
                  );
                  final button = AppButton(
                    label: 'Send as message',
                    kind: AppButtonKind.secondary,
                    compact: true,
                    onPressed: () => guard.sendAnyway(onSend),
                  );
                  if (stacked) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        sentence,
                        const SizedBox(height: Gap.sm),
                        Align(alignment: Alignment.centerRight, child: button),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [Expanded(child: sentence), const SizedBox(width: Gap.sm), button],
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}
