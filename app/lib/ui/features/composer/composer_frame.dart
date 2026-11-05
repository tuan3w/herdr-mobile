import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// The one composer every terminal agent and chat shares: the chat's
/// ([Composer]) and the pane's. A person who switches between the two views of
/// an agent finds the same field, the same discs and the same inset.
const composerMinHeight = 48.0;
const composerButtonSize = 36.0;
const composerButtonHit = 44.0;

/// The text of the field is [Type.body] on a fixed line (a strut), so the
/// field's one-line height is known at any text size and the round buttons
/// can be centred on it.
const composerLineHeight = 1.4;

/// Asks for the keyboard now. Focus brings it up; a field that kept its focus
/// while the keyboard was dismissed needs the explicit request.
void showComposerKeyboard(FocusNode focus) {
  if (focus.hasFocus) {
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  } else {
    focus.requestFocus();
  }
}

/// The one composer placeholder: `Message Claude Code…` while the agent can
/// be written to, else what is in the way ([linkWord]: `Offline`,
/// `Connecting…`). [agent] is the agent's display name (`agentName`); null
/// for a pane with no agent, where what is typed is a command.
String composerHint(String? agent, {String? linkWord}) =>
    linkWord ?? (agent == null ? 'Type a command…' : 'Message $agent…');

/// One line of the field is [inner] tall at any text size (the strut fixes the
/// line). The field is a stadium of that height and the round buttons sit the
/// same distance from every edge, so its corner is concentric with them
/// (radius = disc radius + that distance).
class ComposerMetrics {
  const ComposerMetrics._(this.inner, this.vpad, this.vb, this.radius, this.inset, this.side, this.lineHeightPx);

  factory ComposerMetrics.of(BuildContext context) {
    final line = MediaQuery.textScalerOf(context).scale(Type.body.fontSize!) * composerLineHeight;
    final inner = math.max(composerMinHeight - 2, 2 * 12.5 + line);
    final inset = (inner + 2 - composerButtonSize) / 2;
    return ComposerMetrics._(
      inner,
      (inner - line) / 2,
      (inner - composerButtonHit) / 2,
      (inner + 2) / 2,
      inset,
      math.max(0.0, inset - 1 - (composerButtonHit - composerButtonSize) / 2),
      line,
    );
  }

  final double inner;

  /// Vertical padding of the text inside one line.
  final double vpad;

  /// Vertical padding of a 44 dp button inside one line.
  final double vb;
  final double radius;
  final double inset;

  /// Horizontal padding of a button beside the field.
  final double side;

  /// The height of one line of text at the current text scale.
  final double lineHeightPx;
}

/// The rounded frame: [field] fills it, [leading] (the paperclip) sits at its
/// left and [trailing] (the round buttons) at its right.
class ComposerFrame extends StatelessWidget {
  const ComposerFrame({super.key, required this.field, this.leading, required this.trailing});

  final Widget field;
  final Widget? leading;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final m = ComposerMetrics.of(context);
    final pad = EdgeInsets.fromLTRB(m.side, m.vb, m.side, m.vb);
    return Container(
      constraints: const BoxConstraints(minHeight: composerMinHeight),
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(m.radius),
        border: Border.all(color: ds.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (leading != null) Padding(padding: pad, child: leading),
          Expanded(child: field),
          Padding(padding: pad, child: trailing),
        ],
      ),
    );
  }
}

/// The text field of the [ComposerFrame].
class ComposerField extends StatelessWidget {
  const ComposerField({
    super.key,
    required this.controller,
    this.focusNode,
    required this.enabled,
    required this.hint,
    required this.onSubmit,
    this.mono = false,
    this.maxLines = 5,
    this.inputFormatters = const [],
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.keyboardType,
    this.hasLeading = true,
    this.keyboardOnPointerDown = true,
  });

  final TextEditingController controller;

  /// Null for a field that does not ask for the keyboard on pointer-down.
  final FocusNode? focusNode;
  final bool enabled;
  final String hint;
  final VoidCallback onSubmit;

  /// A shell's line stays in the terminal's font; an agent's prompt is prose.
  final bool mono;

  /// The field grows to this many lines, then scrolls.
  final int maxLines;
  final List<TextInputFormatter> inputFormatters;
  final bool autocorrect;
  final bool enableSuggestions;
  final TextInputType? keyboardType;

  /// Whether a button stands at the field's left (less padding there).
  final bool hasLeading;

  /// Ask for the keyboard when the finger lands.
  final bool keyboardOnPointerDown;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final m = ComposerMetrics.of(context);
    const none = InputBorder.none;
    final color = enabled ? ds.text : ds.textMuted;
    final focus = focusNode;
    return Listener(
      // The keyboard takes ~300 ms to start moving once it is asked for: ask
      // when the finger lands, not when it lifts.
      onPointerDown: keyboardOnPointerDown && focus != null ? (_) => showComposerKeyboard(focus) : null,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        inputFormatters: inputFormatters,
        // Autocorrect rewrites commands, paths and flags; it only helps when
        // the line is a prompt for an agent.
        autocorrect: autocorrect,
        enableSuggestions: enableSuggestions,
        // Sentences only where autocorrect is on (a prompt, not a shell line).
        textCapitalization: autocorrect ? TextCapitalization.sentences : TextCapitalization.none,
        enabled: enabled,
        minLines: 1,
        maxLines: maxLines,
        textInputAction: TextInputAction.send,
        keyboardType: keyboardType,
        // Not onSubmitted: a send action given only that unfocuses the field
        // and drops the keyboard after every message.
        onEditingComplete: onSubmit,
        strutStyle: StrutStyle.fromTextStyle(Type.body, height: composerLineHeight, forceStrutHeight: true),
        style: mono
            ? Mono.input.copyWith(height: m.lineHeightPx / Mono.input.fontSize!, color: color)
            : Type.body.copyWith(height: composerLineHeight, color: color),
        cursorColor: ds.accent,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: Type.body.copyWith(height: composerLineHeight, color: ds.textMuted),
          hintMaxLines: 1,
          filled: false,
          isDense: true,
          // The strut fixes the line, so the field's one-line height is
          // exactly `inner` at any text size and the buttons beside it are
          // centred on it.
          contentPadding: EdgeInsets.fromLTRB(hasLeading ? Gap.xs : Gap.lg, m.vpad, Gap.sm, m.vpad),
          border: none,
          enabledBorder: none,
          focusedBorder: none,
          disabledBorder: none,
          errorBorder: none,
          focusedErrorBorder: none,
        ),
      ),
    );
  }
}

/// The paperclip at the field's left: the same soft disc as the round buttons
/// at its right ([CircleButton] at [composerButtonSize]), so both ends of the
/// field weigh the same. With [count] (the compact layout, which has no chips)
/// a small badge says how many pictures and files go along.
class ComposerAttachButton extends StatelessWidget {
  const ComposerAttachButton({super.key, required this.enabled, required this.onPressed, this.onWarm, this.count = 0});

  final bool enabled;
  final VoidCallback onPressed;
  final VoidCallback? onWarm;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Listener(
      // A finger landing starts the library query and the first thumbnails, so
      // the sheet that opens a moment later finds them.
      onPointerDown: enabled ? (_) => onWarm?.call() : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleButton(
            icon: LucideIcons.paperclip,
            tooltip: count == 0 ? 'Attach' : 'Attach, $count attached',
            size: composerButtonSize,
            onPressed: enabled ? onPressed : null,
          ),
          if (count > 0)
            Positioned(
              top: Gap.hair,
              right: 0,
              child: CountBadge(count: count, tone: CountTone.accent, ring: ds.surface),
            ),
        ],
      ),
    );
  }
}

/// A round 36 dp button in a 44 dp hit area: Send, Stop, the mic.
class ComposerRoundButton extends StatelessWidget {
  const ComposerRoundButton({
    super.key,
    required this.label,
    required this.icon,
    required this.iconSize,
    required this.ready,
    required this.onPressed,
    this.onLongPress,
    this.busy = false,
    this.quiet = false,
  });

  final String label;
  final IconData icon;
  final double iconSize;
  final bool ready;
  final bool busy;

  /// A neutral fill instead of the accent: a secondary action beside the
  /// primary one.
  final bool quiet;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: ready ? onPressed : null,
      onLongPress: ready ? onLongPress : null,
      scale: PressScale.icon,
      semanticLabel: label,
      button: true,
      builder: (context, pressed) => SizedBox.square(
        dimension: composerButtonHit,
        child: Center(
          child: AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            width: composerButtonSize,
            height: composerButtonSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ready
                  ? (quiet ? (pressed ? ds.fillPressed : ds.fill) : (pressed ? ds.accentPressed : ds.accent))
                  : ds.fill,
            ),
            alignment: Alignment.center,
            child: busy
                ? const BusySpinner()
                : Icon(icon, size: iconSize, color: ready ? (quiet ? ds.text : ds.onAccent) : ds.textMuted),
          ),
        ),
      ),
    );
  }
}
