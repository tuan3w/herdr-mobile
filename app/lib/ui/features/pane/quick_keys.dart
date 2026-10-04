import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/machine_connection.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'key_modifiers.dart';

const quickKeysHeight = 44.0;

/// How long an arrow is held before it repeats, and the gap between repeats.
const _repeatDelay = Duration(milliseconds: 320);
const _repeatGap = Duration(milliseconds: 45);

/// A touch that moves further than this is a scroll of the row, not a hold.
const _holdSlop = 10.0;

sealed class _Key {
  const _Key(this.label, {this.icon, String? semantic}) : semantic = semantic ?? label;

  final String label;
  final IconData? icon;
  final String semantic;
}

/// Presses herdr key combo(s). With [repeat], holding the key repeats it.
final class _Send extends _Key {
  const _Send(super.label, this.keys, {super.icon, super.semantic, this.repeat = false});

  final List<String> keys;
  final bool repeat;
}

/// Types [text] into the composer (the field the keyboard is editing), not
/// into the pane.
final class _Insert extends _Key {
  const _Insert(super.label, this.text, {super.icon, super.semantic});

  final String text;
}

/// Arms Ctrl or Alt for the next key ([StickyModifiers]).
final class _Modifier extends _Key {
  const _Modifier(super.label, {required this.ctrl});

  final bool ctrl;
}

const _up = _Send('', ['up'], icon: LucideIcons.arrowUp, semantic: 'Up', repeat: true);
const _down = _Send('', ['down'], icon: LucideIcons.arrowDown, semantic: 'Down', repeat: true);
const _left = _Send('', ['left'], icon: LucideIcons.arrowLeft, semantic: 'Left', repeat: true);
const _right = _Send('', ['right'], icon: LucideIcons.arrowRight, semantic: 'Right', repeat: true);

// Prompt keys come first (esc, up, down, enter), then the two that write
// (new line, slash: it opens the command palette), so all six fit a 412dp
// phone without scrolling.
const _agentKeys = <_Key>[
  _Send('esc', ['esc']),
  _up,
  _down,
  _Send('', ['enter'], icon: LucideIcons.cornerDownLeft, semantic: 'Enter'),
  _Insert('', '\n', icon: LucideIcons.pilcrow, semantic: 'New line'),
  _Insert('/', '/'),
  _left,
  _right,
  _Insert('@', '@'),
  _Modifier('ctrl', ctrl: true),
  _Modifier('alt', ctrl: false),
  _Send('tab', ['tab']),
  _Send('shift+tab', ['shift+tab']),
  _Send('ctrl+c', ['ctrl+c']),
];

// A shell has no newline key (a pasted line would run) but needs the symbols a
// phone keyboard hides on its second page.
const _shellKeys = <_Key>[
  _Send('esc', ['esc']),
  _up,
  _down,
  _Send('', ['enter'], icon: LucideIcons.cornerDownLeft, semantic: 'Enter'),
  _left,
  _right,
  _Modifier('ctrl', ctrl: true),
  _Modifier('alt', ctrl: false),
  _Send('tab', ['tab']),
  _Send('ctrl+c', ['ctrl+c']),
  _Send('ctrl+d', ['ctrl+d']),
  _Insert('/', '/'),
  _Insert('~', '~'),
  _Insert('-', '-'),
  _Insert('|', '|'),
];

/// Keys a phone keyboard lacks. Horizontally scrolling. The set follows what
/// the pane runs: an agent gets a new-line key, a shell gets symbols.
///
/// A tap on a key never moves focus, so the keyboard stays up.
class QuickKeys extends StatelessWidget {
  const QuickKeys({
    super.key,
    required this.paneId,
    required this.modifiers,
    required this.onKeys,
    required this.onInsert,
  });

  final String paneId;
  final StickyModifiers modifiers;

  /// Presses [keys] in the pane. A held key waits for the answer before it
  /// repeats, so a slow link never builds a queue of presses.
  final Future<void> Function(List<String> keys) onKeys;
  final ValueChanged<String> onInsert;

  @override
  Widget build(BuildContext context) {
    final (enabled, agent) = context.select<MachineConnection, (bool, bool)>(
      (m) => (m.acceptsInput(paneId), m.paneById(paneId)?.agent != null),
    );
    final set = agent ? _agentKeys : _shellKeys;
    return SizedBox(
      height: quickKeysHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        itemCount: set.length,
        separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
        itemBuilder: (_, i) => switch (set[i]) {
          final _Send key => _KeyButton(
              data: key,
              repeat: key.repeat,
              onPressed: enabled ? () => onKeys(key.keys) : null,
            ),
          final _Insert key => _KeyButton(
              data: key,
              onPressed: enabled ? () async => onInsert(key.text) : null,
            ),
          final _Modifier key => ListenableBuilder(
              listenable: modifiers,
              builder: (_, _) => _KeyButton(
                data: key,
                active: key.ctrl ? modifiers.ctrl : modifiers.alt,
                onPressed: enabled
                    ? () async => key.ctrl ? modifiers.toggleCtrl() : modifiers.toggleAlt()
                    : null,
              ),
            ),
        },
      ),
    );
  }
}

class _KeyButton extends StatefulWidget {
  const _KeyButton({
    required this.data,
    required this.onPressed,
    this.active = false,
    this.repeat = false,
  });

  final _Key data;
  final Future<void> Function()? onPressed;
  final bool active;
  final bool repeat;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  Timer? _timer;
  Offset _downAt = Offset.zero;
  bool _holding = false;

  /// The hold already pressed the key, so the tap that ends it must not.
  bool _repeated = false;

  void _down(PointerDownEvent event) {
    if (!widget.repeat || widget.onPressed == null) return;
    _downAt = event.position;
    _holding = true;
    _repeated = false;
    _timer = Timer(_repeatDelay, _tick);
  }

  void _move(PointerMoveEvent event) {
    if (_holding && (event.position - _downAt).distance > _holdSlop) _stop();
  }

  void _stop() {
    _holding = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final press = widget.onPressed;
    if (!_holding || press == null) return;
    _repeated = true;
    await press();
    if (_holding && mounted) _timer = Timer(_repeatGap, _tick);
  }

  void _tap() {
    if (_repeated) {
      _repeated = false;
      return;
    }
    tapFeedback();
    widget.onPressed?.call();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final data = widget.data;
    final enabled = widget.onPressed != null;
    final color = !enabled
        ? ds.textTertiary
        : widget.active
            ? ds.accentText
            : ds.text;
    final fill = widget.active
        ? ds.accent.withValues(alpha: ds.isDark ? 0.22 : 0.14)
        : null;
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: PressBuilder(
        onTap: enabled ? _tap : null,
        scale: 0.96,
        selected: data is _Modifier ? widget.active : null,
        // Icon keys are named; text keys are read from their text.
        semanticLabel: data.icon != null ? data.semantic : null,
        builder: (context, pressed) => Center(
          child: AnimatedContainer(
            duration: pressed ? Motion.press : Motion.release,
            curve: Motion.easeOut,
            height: 36,
            constraints: const BoxConstraints(minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill ?? (pressed ? ds.fillPressed : ds.fill),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: data.icon != null
                ? Icon(data.icon, size: 16, color: color)
                : Text(
                    data.label,
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: monoFamily,
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
