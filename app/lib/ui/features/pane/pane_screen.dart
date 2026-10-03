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
import '../../core/terminal_links.dart';
import '../../core/terminal_view.dart';
import '../../core/theme.dart';
import '../files/files_navigation.dart';
import 'link_sheet.dart';
import 'pane_view_model.dart';
import 'tab_swipe.dart';

/// Height of the composer with one line.
const _composerMinHeight = 48.0;
const _composerRadius = 20.0;

/// The send button is drawn at 36 inside a 44 hit area, in the composer's
/// 46px of inner height (48 less the hairline).
const _sendSize = 36.0;
const _sendHit = 44.0;
const _quickKeysHeight = 44.0;

/// One open pane: its banner, terminal, quick keys and composer. The tab
/// screen ([PaneHostScreen]) owns the view model and the chrome around it
/// (back, title, tabs); this page keeps what belongs to the tab itself, such as
/// the draft in the composer and the terminal's scroll position, for as long as
/// the host keeps it mounted.
class PaneScreen extends StatelessWidget {
  const PaneScreen({
    super.key,
    required this.machine,
    required this.paneId,
    required this.viewModel,
    this.onSwipe,
  });

  final MachineConnection machine;
  final String paneId;
  final PaneViewModel viewModel;

  /// A horizontal swipe on the terminal asks for the neighbouring tab (+1
  /// next, -1 previous). Only offered while lines wrap to the screen: the
  /// terminal has nothing to scroll sideways then.
  final ValueChanged<int>? onSwipe;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: machine),
          ChangeNotifierProvider.value(value: viewModel),
        ],
        child: _PaneView(paneId: paneId, onSwipe: onSwipe),
      );
}

/// Tells the pane regions whether the layout is compact: landscape with the
/// keyboard up. It sits ABOVE the host's `Scaffold`, which strips the keyboard
/// inset from what its body sees, and only notifies when the answer changes
/// (the inset itself changes every frame of the keyboard animation).
class CompactScope extends StatelessWidget {
  const CompactScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _Compact(
        compact: MediaQuery.orientationOf(context) == Orientation.landscape &&
            MediaQuery.viewInsetsOf(context).bottom > 0,
        child: child,
      );
}

class _Compact extends InheritedWidget {
  const _Compact({required this.compact, required super.child});

  final bool compact;

  @override
  bool updateShouldNotify(_Compact old) => old.compact != compact;
}

/// Whether the host shows only the terminal and composer (see [CompactScope]).
bool compactLayout(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_Compact>()?.compact ?? false;

/// [id] in the machine's last snapshot, if herdr still has it.
Pane? paneIn(MachineConnection machine, String id) {
  for (final pane in machine.snapshot.panes) {
    if (pane.id == id) return pane;
  }
  return null;
}

/// Whether input can reach the pane: the machine is live and the pane exists.
bool _acceptsInput(MachineConnection machine, String id) =>
    machine.isLive && paneIn(machine, id) != null;

/// Owns what outlives a rebuild (the composer's text, the keys toggle) and
/// composes the regions. Every region selects only what it shows, so a
/// notify about some other pane rebuilds nothing here.
class _PaneView extends StatefulWidget {
  const _PaneView({required this.paneId, this.onSwipe});

  final String paneId;
  final ValueChanged<int>? onSwipe;

  @override
  State<_PaneView> createState() => _PaneViewState();
}

class _PaneViewState extends State<_PaneView> {
  final _input = TextEditingController();
  late final PaneViewModel _vm = context.read<PaneViewModel>();
  bool _keysOpen = false;

  /// A table wider than the view makes the terminal scroll sideways.
  final _sideways = ValueNotifier(false);

  @override
  void dispose() {
    _input.dispose();
    _sideways.dispose();
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

  void _retry() {
    context.read<MachineConnection>().retry();
    _vm.refresh();
  }

  /// A link in the output was tapped: a web address shows its sheet; a path
  /// opens in the file viewer (or browser, for a directory), found from the
  /// pane's folder when it is relative.
  void _openLink(TerminalLink link) {
    HapticFeedback.selectionClick();
    final machine = context.read<MachineConnection>();
    switch (link.kind) {
      case TerminalLinkKind.url:
        unawaited(showLinkSheet(context, link.target));
      case TerminalLinkKind.path:
        unawaited(
          openRemoteFile(
            context,
            machine,
            link.target,
            cwd: paneIn(machine, widget.paneId)?.cwd,
            line: link.line,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => _PaneLayout(
        keysOpen: _keysOpen,
        onToggleKeys: () => setState(() => _keysOpen = !_keysOpen),
        banner: _Banner(paneId: widget.paneId, onRetry: _retry),
        terminal: Builder(
          builder: (context) => ValueListenableBuilder<bool>(
            valueListenable: _sideways,
            // A table wider than the view scrolls it sideways: that swipe is
            // the table's, not a step to the next tab.
            builder: (context, sideways, child) => TabSwipeDetector(
              enabled: widget.onSwipe != null &&
                  !sideways &&
                  context.select<TerminalSettings, bool>((s) => s.wrap),
              onSwipe: (delta) => widget.onSwipe?.call(delta),
              child: child!,
            ),
            child: _TerminalPanel(
              paneId: widget.paneId,
              onLinkTap: _openLink,
              onSidewaysChanged: (value) => _sideways.value = value,
            ),
          ),
        ),
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

/// Stacks the regions under the host's chrome. With the keyboard up in
/// landscape there is room for little more than the terminal, so the host drops
/// its top bar and tabs ([compactLayout]) and the quick keys wait behind a
/// toggle beside the composer.
///
/// The regions are built by the caller and only placed here: this widget
/// depends on the window insets, which change every frame of the keyboard's
/// animation, and must not rebuild them.
class _PaneLayout extends StatelessWidget {
  const _PaneLayout({
    required this.banner,
    required this.terminal,
    required this.keys,
    required this.composer,
    required this.keysOpen,
    required this.onToggleKeys,
  });

  final Widget banner;
  final Widget terminal;
  final Widget keys;
  final Widget composer;
  final bool keysOpen;
  final VoidCallback onToggleKeys;

  @override
  Widget build(BuildContext context) {
    final compact = compactLayout(context);
    final top = MediaQuery.paddingOf(context).top;
    return Column(
        children: [
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
    );
  }
}

/// The terminal in its dark rounded panel. The outline is drawn over the
/// content, so scrolling rows never paint across it.
class _TerminalPanel extends StatelessWidget {
  const _TerminalPanel({
    required this.paneId,
    required this.onLinkTap,
    required this.onSidewaysChanged,
  });

  final String paneId;
  final ValueChanged<TerminalLink> onLinkTap;
  final ValueChanged<bool> onSidewaysChanged;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Radii.panel);
    final palette = context.terminal;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: palette.border),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: ColoredBox(
          color: palette.background,
          child: Builder(
            builder: (context) {
              final (fontSize, wrap) = context.select<TerminalSettings, (double, bool)>(
                (s) => (s.fontSize, s.wrap),
              );
              // What it shows is a pane that is gone: dimmed, not live.
              final closed = context.select<MachineConnection, bool>(
                (m) => m.isLive && paneIn(m, paneId) == null,
              );
              final settings = context.read<TerminalSettings>();
              final vm = context.read<PaneViewModel>();
              final content = context.select<
                  PaneViewModel,
                  ({List<String> history, String text, TerminalTop top})>(
                (v) => (history: v.history, text: v.text, top: v.top),
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  TerminalView(
                    history: content.history,
                    text: content.text,
                    top: content.top,
                    onLinkTap: onLinkTap,
                    onSidewaysChanged: onSidewaysChanged,
                    onScrollChanged: (s) => vm.viewChanged(
                      nearTop: s.nearTop,
                      following: s.following,
                    ),
                    fontSize: fontSize,
                    wrap: wrap,
                    onFontSizeChanged: settings.previewFontSize,
                    onFontSizeEnd: (size) => unawaited(settings.setFontSize(size)),
                  ),
                  if (closed)
                    IgnorePointer(
                      child: ColoredBox(
                        color: palette.background.withValues(alpha: 0.6),
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
      (m) => (state: m.state, error: m.error, open: paneIn(m, id) != null),
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
        final pane = paneIn(m, paneId);
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
