import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/terminal_settings.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/terminal_view.dart';
import '../../core/theme.dart';
import 'pane_view_model.dart';

/// Height of the composer with one line.
const _composerMinHeight = 48.0;
const _composerRadius = 20.0;

/// The send button is drawn at 36 inside a 44 hit area, in the composer's
/// 46px of inner height (48 less the hairline).
const _sendSize = 36.0;
const _sendHit = 44.0;
const _quickKeysHeight = 44.0;

class PaneScreen extends StatelessWidget {
  const PaneScreen({super.key, required this.machine, required this.paneId});

  final MachineConnection machine;
  final String paneId;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: machine),
          ChangeNotifierProvider(
            create: (context) => PaneViewModel.forMachine(
              machine,
              paneId,
              wrap: context.read<TerminalSettings>().wrap,
            ),
          ),
        ],
        child: _PaneView(paneId: paneId),
      );
}

/// [id] in the machine's last snapshot, if herdr still has it.
Pane? _paneIn(MachineConnection machine, String id) {
  for (final pane in machine.snapshot.panes) {
    if (pane.id == id) return pane;
  }
  return null;
}

/// Whether input can reach the pane: the machine is live and the pane exists.
bool _acceptsInput(MachineConnection machine, String id) =>
    machine.isLive && _paneIn(machine, id) != null;

/// Owns what outlives a rebuild (the composer's text, the keys toggle) and
/// composes the regions. Every region selects only what it shows, so a
/// notify about some other pane rebuilds nothing here.
class _PaneView extends StatefulWidget {
  const _PaneView({required this.paneId});

  final String paneId;

  @override
  State<_PaneView> createState() => _PaneViewState();
}

class _PaneViewState extends State<_PaneView> {
  final _input = TextEditingController();
  late final PaneViewModel _vm = context.read<PaneViewModel>();
  bool _keysOpen = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Types the composer's text and presses enter. With nothing but whitespace
  /// in it, only presses enter (what the keyboard's send key does on an empty
  /// field), so a stray space is never typed into the pane.
  Future<void> _submit() async {
    if (_vm.sending) return;
    final text = _input.text;
    HapticFeedback.lightImpact();
    if (text.trim().isEmpty) {
      _input.clear();
      await _vm.sendKeys(const ['enter']);
      return;
    }
    final sent = await _vm.sendLine(text);
    // Leaving mid-send disposes the controller; typing more while it was in
    // flight is not ours to wipe.
    if (sent && mounted && _input.text == text) _input.clear();
  }

  void _toggleWrap() {
    HapticFeedback.selectionClick();
    final settings = context.read<TerminalSettings>();
    final next = !settings.wrap;
    _vm.setWrap(next);
    unawaited(settings.setWrap(next));
  }

  void _retry() {
    context.read<MachineConnection>().retry();
    _vm.refresh();
  }

  @override
  Widget build(BuildContext context) => _PaneLayout(
        keysOpen: _keysOpen,
        onToggleKeys: () => setState(() => _keysOpen = !_keysOpen),
        topBar: _TopBar(paneId: widget.paneId, onToggleWrap: _toggleWrap),
        banner: _Banner(paneId: widget.paneId, onRetry: _retry),
        terminal: _TerminalPanel(paneId: widget.paneId),
        keys: _QuickKeys(
          paneId: widget.paneId,
          onKey: (keys) {
            HapticFeedback.selectionClick();
            _vm.sendKeys(keys);
          },
        ),
        composer: _Composer(
          paneId: widget.paneId,
          controller: _input,
          onSubmit: _submit,
        ),
      );
}

/// Stacks the regions. With the keyboard up in landscape there is room for
/// little more than the terminal, so the top bar goes and the quick keys wait
/// behind a toggle beside the composer.
///
/// The regions are built by the caller and only placed here: this widget
/// depends on the window insets, which change every frame of the keyboard's
/// animation, and must not rebuild them.
class _PaneLayout extends StatelessWidget {
  const _PaneLayout({
    required this.topBar,
    required this.banner,
    required this.terminal,
    required this.keys,
    required this.composer,
    required this.keysOpen,
    required this.onToggleKeys,
  });

  final Widget topBar;
  final Widget banner;
  final Widget terminal;
  final Widget keys;
  final Widget composer;
  final bool keysOpen;
  final VoidCallback onToggleKeys;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.orientationOf(context) == Orientation.landscape &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Column(
        children: [
          if (!compact) topBar,
          banner,
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                Gap.lg,
                compact ? top + Gap.xs : Gap.xs,
                Gap.lg,
                compact ? Gap.xs : Gap.sm,
              ),
              child: terminal,
            ),
          ),
          if (!compact || keysOpen) keys,
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, compact ? Gap.xs : Gap.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (compact)
                    SizedBox(
                      height: _composerMinHeight,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.only(right: Gap.sm),
                          child: CircleButton(
                            icon: LucideIcons.keyboard,
                            tooltip: keysOpen ? 'Hide keys' : 'Show keys',
                            active: keysOpen,
                            onPressed: onToggleKeys,
                          ),
                        ),
                      ),
                    ),
                  Expanded(child: composer),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Back, the pane's task title with where it lives, and the wrap toggle. No
/// bottom border: the terminal panel below is the anchor.
class _TopBar extends StatefulWidget {
  const _TopBar({required this.paneId, required this.onToggleWrap});

  final String paneId;
  final VoidCallback onToggleWrap;

  @override
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
  /// The pane as last seen in a snapshot: once it is closed, the bar keeps
  /// saying what it was.
  Pane? _known;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final id = widget.paneId;
    final pane = context.select<MachineConnection, Pane?>((m) => _paneIn(m, id));
    final live = context.select<MachineConnection, bool>((m) => m.isLive);
    final stale = context.select<PaneViewModel, bool>((v) => v.isStale);
    final wrap = context.select<TerminalSettings, bool>((s) => s.wrap);
    final machineLabel = context.read<MachineConnection>().profile.label;
    if (pane != null) _known = pane;
    final shown = pane ?? _known;

    // The task the agent is on; the agent, then the id, when it has none.
    final task = shown?.title.trim() ?? '';
    final title = task.isNotEmpty ? task : (shown?.agent ?? id);
    final where = [
      if (shown?.agent != null && shown!.agent != title) shown.agent!,
      machineLabel,
    ].join(' · ');
    final secondary = Type.secondary.copyWith(color: ds.textSecondary);
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: Row(
            children: [
              CircleButton(
                icon: LucideIcons.chevronLeft,
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.barTitle.copyWith(color: ds.text),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        // The glyph names the status for screen readers; the
                        // text beside it is not repeated.
                        if (pane != null) ...[
                          StatusGlyph(status: pane.status, size: 16, dim: !live || stale),
                          const SizedBox(width: 6),
                        ],
                        // The id is short and never cut; the rest gives way.
                        Flexible(
                          child: Text(
                            where,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: secondary,
                          ),
                        ),
                        Text(' · $id', maxLines: 1, style: secondary),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Gap.md),
              CircleButton(
                icon: LucideIcons.wrapText,
                tooltip: wrap ? 'Show exact terminal layout' : 'Wrap lines to screen',
                active: wrap,
                onPressed: widget.onToggleWrap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The terminal in its dark rounded panel. The outline is drawn over the
/// content, so scrolling rows never paint across it.
class _TerminalPanel extends StatelessWidget {
  const _TerminalPanel({required this.paneId});

  final String paneId;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Radii.panel);
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: TerminalColors.border),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: ColoredBox(
          color: TerminalColors.background,
          child: Builder(
            builder: (context) {
              final (fontSize, wrap) = context.select<TerminalSettings, (double, bool)>(
                (s) => (s.fontSize, s.wrap),
              );
              // What it shows is a pane that is gone: dimmed, not live.
              final closed = context.select<MachineConnection, bool>(
                (m) => m.isLive && _paneIn(m, paneId) == null,
              );
              final settings = context.read<TerminalSettings>();
              return Stack(
                fit: StackFit.expand,
                children: [
                  TerminalView(
                    text: context.select<PaneViewModel, String>((v) => v.text),
                    fontSize: fontSize,
                    wrap: wrap,
                    onFontSizeChanged: settings.previewFontSize,
                    onFontSizeEnd: (size) => unawaited(settings.setFontSize(size)),
                  ),
                  if (closed)
                    IgnorePointer(
                      child: ColoredBox(
                        color: TerminalColors.background.withValues(alpha: 0.6),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// What is wrong, if anything: the link, a pane that is gone, or the last
/// read or send.
class _Problem {
  const _Problem({
    required this.title,
    this.detail,
    required this.color,
    required this.icon,
    required this.retry,
  });

  final String title;
  final String? detail;
  final Color color;
  final IconData icon;
  final bool retry;
}

/// One strip under the top bar. It remembers the last problem so that it can
/// animate closed with its content instead of emptying first.
class _Banner extends StatefulWidget {
  const _Banner({required this.paneId, required this.onRetry});

  final String paneId;
  final VoidCallback onRetry;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  _Problem? _last;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final id = widget.paneId;
    final link = context.select<MachineConnection, ({LinkState state, String? error, bool open})>(
      (m) => (state: m.state, error: m.error, open: _paneIn(m, id) != null),
    );
    final readError = context.select<PaneViewModel, String?>((v) => v.error);

    final _Problem? problem;
    if (link.state != LinkState.online) {
      problem = _Problem(
        title: link.state.label,
        detail: link.error,
        color: link.state.color(ds),
        icon: switch (link.state) {
          LinkState.connecting => LucideIcons.loader,
          LinkState.attention => LucideIcons.triangleAlert,
          LinkState.approval => LucideIcons.keyRound,
          LinkState.disabled => LucideIcons.ban,
          _ => LucideIcons.wifiOff,
        },
        // Approval waits on a person elsewhere; retrying does nothing.
        retry: link.state != LinkState.approval,
      );
    } else if (!link.open) {
      problem = _Problem(
        title: 'This pane was closed',
        color: ds.textSecondary,
        icon: LucideIcons.squareX,
        retry: false,
      );
    } else if (readError != null) {
      problem = _Problem(
        title: readError,
        color: ds.danger,
        icon: LucideIcons.circleAlert,
        retry: true,
      );
    } else {
      problem = null;
    }
    if (problem != null) _last = problem;

    final shown = _last;
    return Collapse(
      open: problem != null,
      child: shown == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xs),
              child: StatusStrip(
                color: shown.color,
                leading: Icon(shown.icon, size: 18, color: shown.color),
                title: shown.title,
                detail: shown.detail,
                action: shown.retry
                    ? AppButton(
                        label: 'Retry',
                        kind: AppButtonKind.secondary,
                        compact: true,
                        onPressed: widget.onRetry,
                      )
                    : null,
              ),
            ),
    );
  }
}

/// One key of the quick row: a text label or an icon, and the herdr key
/// combo(s) it sends.
class _QuickKey {
  const _QuickKey(this.label, this.keys, {this.icon, String? semantic})
      : semantic = semantic ?? label;

  final String label;
  final IconData? icon;
  final String semantic;
  final List<String> keys;
}

/// Keys a phone keyboard lacks. Horizontally scrolling; ordered by use when
/// answering a prompt, so the first five fit a 412dp phone.
class _QuickKeys extends StatelessWidget {
  const _QuickKeys({required this.paneId, required this.onKey});

  final String paneId;
  final ValueChanged<List<String>> onKey;

  static const _keys = <_QuickKey>[
    _QuickKey('esc', ['esc']),
    _QuickKey('', ['up'], icon: LucideIcons.arrowUp, semantic: 'Up'),
    _QuickKey('', ['down'], icon: LucideIcons.arrowDown, semantic: 'Down'),
    _QuickKey('', ['enter'], icon: LucideIcons.cornerDownLeft, semantic: 'Enter'),
    _QuickKey('tab', ['tab']),
    _QuickKey('shift+tab', ['shift+tab']),
    _QuickKey('ctrl+c', ['ctrl+c']),
    _QuickKey('', ['left'], icon: LucideIcons.arrowLeft, semantic: 'Left'),
    _QuickKey('', ['right'], icon: LucideIcons.arrowRight, semantic: 'Right'),
  ];

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<MachineConnection, bool>((m) => _acceptsInput(m, paneId)) &&
        !context.select<PaneViewModel, bool>((v) => v.sending);
    return SizedBox(
      height: _quickKeysHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
        itemCount: _keys.length,
        separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
        itemBuilder: (_, i) {
          final key = _keys[i];
          return _KeyButton(
            data: key,
            onPressed: enabled ? () => onKey(key.keys) : null,
          );
        },
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.data, required this.onPressed});

  final _QuickKey data;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final color = onPressed == null ? ds.textTertiary : ds.text;
    return PressBuilder(
      onTap: onPressed,
      scale: 0.96,
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
            color: pressed ? ds.fillPressed : ds.fill,
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
    );
  }
}

/// Rounded multi-line input with a round send button at its right. Grows to
/// five lines, then scrolls.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.paneId,
    required this.controller,
    required this.onSubmit,
  });

  final String paneId;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (state, open, agent) = context.select<MachineConnection, (LinkState, bool, String?)>(
      (m) {
        final pane = _paneIn(m, paneId);
        return (m.state, pane != null, pane?.agent);
      },
    );
    final sending = context.select<PaneViewModel, bool>((v) => v.sending);
    final enabled = state == LinkState.online && open;
    final hint = switch (state) {
      LinkState.online => open ? 'Message ${agent ?? 'pane'}…' : 'Pane closed',
      LinkState.connecting => 'Connecting…',
      LinkState.approval => 'Waiting for sign-in approval',
      LinkState.reconnecting || LinkState.offline => 'Offline — reconnecting',
      LinkState.attention => 'Needs attention — see above',
      LinkState.disabled => 'Machine disabled',
    };
    const inputStyle = TextStyle(
      fontFamily: monoFamily,
      fontSize: 14,
      height: 1.5,
    );
    const none = InputBorder.none;
    return Container(
      constraints: const BoxConstraints(minHeight: _composerMinHeight),
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(_composerRadius),
        border: Border.all(color: ds.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              // Not onSubmitted: a send action given only that unfocuses the
              // field and drops the keyboard after every message.
              onEditingComplete: onSubmit,
              style: inputStyle.copyWith(
                color: enabled ? ds.text : ds.textTertiary,
              ),
              cursorColor: ds.accent,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: Type.body.copyWith(height: 1.4, color: ds.textMuted),
                hintMaxLines: 1,
                filled: false,
                isDense: true,
                // 1px border + 12.5 + 21px line + 12.5 + 1px = the 48px minimum.
                contentPadding: const EdgeInsets.fromLTRB(Gap.lg, 12.5, Gap.sm, 12.5),
                border: none,
                enabledBorder: none,
                focusedBorder: none,
                disabledBorder: none,
                errorBorder: none,
                focusedErrorBorder: none,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(1),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => _SendButton(
                ready: enabled && !sending && value.text.trim().isNotEmpty,
                sending: sending,
                onPressed: onSubmit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.ready,
    required this.sending,
    required this.onPressed,
  });

  final bool ready;
  final bool sending;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: ready ? onPressed : null,
      scale: 0.92,
      semanticLabel: 'Send',
      builder: (context, pressed) => SizedBox.square(
        dimension: _sendHit,
        child: Center(
          child: AnimatedContainer(
            duration: Motion.standard,
            curve: Motion.easeOut,
            width: _sendSize,
            height: _sendSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ready
                  ? (pressed
                      ? Color.alphaBlend(Colors.black.withValues(alpha: 0.12), ds.accent)
                      : ds.accent)
                  : ds.fill,
            ),
            alignment: Alignment.center,
            child: sending
                ? const BusySpinner()
                : Icon(
                    LucideIcons.arrowUp,
                    size: 18,
                    color: ready ? ds.onAccent : ds.textTertiary,
                  ),
          ),
        ),
      ),
    );
  }
}
