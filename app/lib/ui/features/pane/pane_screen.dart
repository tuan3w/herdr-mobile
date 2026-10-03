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
import '../../core/terminal_view.dart';
import '../../core/theme.dart';
import 'pane_view_model.dart';

/// Scrollback lines requested per read.
const _readLines = 300;

/// Height of the composer with one line: a 36px send button with 6px around it.
const _composerMinHeight = 48.0;
const _composerRadius = 20.0;
const _sendSize = 36.0;

class PaneScreen extends StatelessWidget {
  const PaneScreen({super.key, required this.machine, required this.paneId});

  final MachineConnection machine;
  final String paneId;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: machine),
          ChangeNotifierProvider(
            create: (context) => PaneViewModel(
              activity: machine.paneActivity,
              paneId: paneId,
              read: (source) => machine.api.readPane(
                paneId,
                source: source,
                lines: _readLines,
                ansi: true,
              ),
              sendLine: (text) => machine.api.sendLine(paneId, text),
              sendKeys: (keys) => machine.api.sendKeys(paneId, keys),
              wrap: context.read<TerminalSettings>().wrap,
            ),
          ),
        ],
        child: _PaneView(paneId: paneId),
      );
}

class _PaneView extends StatefulWidget {
  const _PaneView({required this.paneId});

  final String paneId;

  @override
  State<_PaneView> createState() => _PaneViewState();
}

class _PaneViewState extends State<_PaneView> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Types the composer's text and presses enter. With nothing but whitespace
  /// in it, only presses enter (what the keyboard's send key does on an empty
  /// field), so a stray space is never typed into the pane.
  Future<void> _submit(PaneViewModel vm) async {
    final text = _input.text;
    HapticFeedback.lightImpact();
    if (text.trim().isEmpty) {
      _input.clear();
      await vm.sendKeys(const ['enter']);
      return;
    }
    if (await vm.sendLine(text)) _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    // Text updates only rebuild the terminal (below), not the whole screen.
    final vm = context.read<PaneViewModel>();
    final (sending, error, stale) =
        context.select<PaneViewModel, (bool, String?, bool)>(
      (v) => (v.sending, v.error, v.isStale),
    );
    final wrap = context.select<TerminalSettings, bool>((s) => s.wrap);
    final machine = context.watch<MachineConnection>();
    final ds = context.ds;
    final pane = machine.snapshot.panes
        .where((p) => p.id == widget.paneId)
        .firstOrNull;
    final live = machine.isLive;
    final hint = switch (machine.state) {
      LinkState.online => 'Message ${pane?.agent ?? 'pane'}…',
      LinkState.connecting => 'Connecting…',
      LinkState.approval => 'Waiting for sign-in approval',
      LinkState.reconnecting || LinkState.offline => 'Offline — reconnecting',
      LinkState.attention => 'Needs attention — see above',
      LinkState.disabled => 'Machine disabled',
    };
    final canSend = live && !sending;

    // Why the pane may not be trustworthy right now, if it is not.
    final _Problem? problem;
    if (!live) {
      problem = _Problem(
        message: machine.error ?? machine.state.label,
        color: machine.state.color(ds),
        icon: switch (machine.state) {
          LinkState.connecting => LucideIcons.loader,
          LinkState.attention => LucideIcons.triangleAlert,
          LinkState.approval => LucideIcons.keyRound,
          LinkState.disabled => LucideIcons.ban,
          _ => LucideIcons.wifiOff,
        },
        // Approval waits on a person elsewhere; retrying does nothing.
        retry: machine.state != LinkState.approval,
      );
    } else if (error != null) {
      problem = _Problem(
        message: error,
        color: ds.danger,
        icon: LucideIcons.circleAlert,
        retry: true,
      );
    } else {
      problem = null;
    }

    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            title: pane?.agent ?? pane?.title ?? widget.paneId,
            machineLabel: machine.profile.label,
            paneId: widget.paneId,
            status: pane?.status,
            dim: !live || stale,
            wrap: wrap,
            onToggleWrap: () {
              HapticFeedback.selectionClick();
              final next = !wrap;
              vm.setWrap(next);
              unawaited(context.read<TerminalSettings>().setWrap(next));
            },
          ),
          Collapse(
            open: problem != null,
            child: problem == null
                ? const SizedBox.shrink()
                : _ProblemBanner(
                    problem: problem,
                    onRetry: () {
                      machine.retry();
                      vm.refresh();
                    },
                  ),
          ),
          const Expanded(child: _TerminalPanel()),
          _QuickKeys(
            enabled: canSend,
            onKey: (keys) {
              HapticFeedback.selectionClick();
              vm.sendKeys(keys);
            },
          ),
          _Composer(
            controller: _input,
            hint: hint,
            enabled: live,
            canSend: canSend,
            sending: sending,
            onSubmit: () => _submit(vm),
          ),
        ],
      ),
    );
  }
}

/// Back, the pane's name with where it lives, and the wrap toggle. No bottom
/// border: the terminal panel below is the anchor.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.machineLabel,
    required this.paneId,
    required this.status,
    required this.dim,
    required this.wrap,
    required this.onToggleWrap,
  });

  final String title;
  final String machineLabel;
  final String paneId;
  final AgentStatus? status;
  final bool dim;
  final bool wrap;
  final VoidCallback onToggleWrap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
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
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.barTitle.copyWith(color: ds.text),
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        if (status != null) ...[
                          StatusGlyph(status: status!, size: 16, dim: dim),
                          const SizedBox(width: 6),
                        ],
                        // The id is short and never cut; the rest gives way.
                        Flexible(
                          child: Text(
                            status == null ? machineLabel : '${status!.label} · $machineLabel',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: secondary,
                          ),
                        ),
                        Text(' · $paneId', maxLines: 1, style: secondary),
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
                onPressed: onToggleWrap,
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
  const _TerminalPanel();

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Radii.panel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
      child: DecoratedBox(
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
                final (fontSize, wrap) =
                    context.select<TerminalSettings, (double, bool)>(
                  (s) => (s.fontSize, s.wrap),
                );
                final settings = context.read<TerminalSettings>();
                return TerminalView(
                  text: context.select<PaneViewModel, String>((v) => v.text),
                  fontSize: fontSize,
                  wrap: wrap,
                  onFontSizeChanged: settings.previewFontSize,
                  onFontSizeEnd: (size) => unawaited(settings.setFontSize(size)),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Problem {
  const _Problem({
    required this.message,
    required this.color,
    required this.icon,
    required this.retry,
  });

  final String message;
  final Color color;
  final IconData icon;
  final bool retry;
}

/// Flat tinted panel: what is wrong with the link (or the last read/send), and
/// a retry.
class _ProblemBanner extends StatelessWidget {
  const _ProblemBanner({required this.problem, required this.onRetry});

  final _Problem problem;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.xs),
      padding: EdgeInsets.fromLTRB(Gap.md, Gap.sm, problem.retry ? Gap.sm : Gap.md, Gap.sm),
      decoration: BoxDecoration(
        color: problem.color.withValues(alpha: ds.isDark ? 0.14 : 0.12),
        borderRadius: BorderRadius.circular(Radii.panel),
        border: Border.all(color: ds.hairline),
      ),
      child: Row(
        children: [
          Icon(problem.icon, size: 18, color: problem.color),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xs),
              child: Text(
                problem.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Type.secondary.copyWith(color: ds.text),
              ),
            ),
          ),
          if (problem.retry) ...[
            const SizedBox(width: Gap.sm),
            AppButton(
              label: 'Retry',
              kind: AppButtonKind.secondary,
              compact: true,
              onPressed: onRetry,
            ),
          ],
        ],
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

/// Keys a phone keyboard lacks. Horizontally scrolling.
class _QuickKeys extends StatelessWidget {
  const _QuickKeys({required this.enabled, required this.onKey});

  final bool enabled;
  final ValueChanged<List<String>> onKey;

  static const _keys = <_QuickKey>[
    _QuickKey('esc', ['esc']),
    _QuickKey('tab', ['tab']),
    _QuickKey('shift+tab', ['shift+tab']),
    _QuickKey('ctrl+c', ['ctrl+c']),
    _QuickKey('', ['up'], icon: LucideIcons.arrowUp, semantic: 'Up'),
    _QuickKey('', ['down'], icon: LucideIcons.arrowDown, semantic: 'Down'),
    _QuickKey('', ['left'], icon: LucideIcons.arrowLeft, semantic: 'Left'),
    _QuickKey('', ['right'], icon: LucideIcons.arrowRight, semantic: 'Right'),
    _QuickKey('', ['enter'], icon: LucideIcons.cornerDownLeft, semantic: 'Enter'),
  ];

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 48,
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
      semanticLabel: data.semantic,
      builder: (context, pressed) => Center(
        child: AnimatedContainer(
          duration: pressed ? Motion.press : Motion.release,
          curve: Motion.easeOut,
          height: 36,
          constraints: const BoxConstraints(minWidth: 40),
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
    required this.controller,
    required this.hint,
    required this.enabled,
    required this.canSend,
    required this.sending,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String hint;

  /// The field accepts typing (the machine is live).
  final bool enabled;

  /// Sending is possible at all (live, nothing in flight); the button also
  /// needs text.
  final bool canSend;
  final bool sending;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    const inputStyle = TextStyle(
      fontFamily: monoFamily,
      fontSize: 14,
      height: 1.5,
    );
    const none = InputBorder.none;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
        child: Container(
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
                  onSubmitted: (_) => onSubmit(),
                  style: inputStyle.copyWith(
                    color: enabled ? ds.text : ds.textTertiary,
                  ),
                  cursorColor: ds.accent,
                  decoration: InputDecoration(
                    hintText: hint,
                    hintStyle: Type.body.copyWith(height: 1.4, color: ds.textTertiary),
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
                padding: const EdgeInsets.all(5),
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => _SendButton(
                    ready: canSend && value.text.trim().isNotEmpty,
                    sending: sending,
                    onPressed: onSubmit,
                  ),
                ),
              ),
            ],
          ),
        ),
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
      builder: (context, pressed) => AnimatedContainer(
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
            ? SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: ds.textSecondary,
                ),
              )
            : Icon(
                LucideIcons.arrowUp,
                size: 18,
                color: ready ? ds.onAccent : ds.textTertiary,
              ),
      ),
    );
  }
}
