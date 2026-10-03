import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/terminal_settings.dart';
import '../../core/terminal_view.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'pane_view_model.dart';

/// Scrollback lines requested per read.
const _readLines = 300;

const _easeOut = Cubic(0.23, 1, 0.32, 1);

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

  /// Label, herdr key combo(s).
  static const _quickKeys = <(String, List<String>)>[
    ('esc', ['esc']),
    ('tab', ['tab']),
    ('⇧tab', ['shift+tab']),
    ('ctrl+c', ['ctrl+c']),
    ('↑', ['up']),
    ('↓', ['down']),
    ('←', ['left']),
    ('→', ['right']),
    ('⏎', ['enter']),
  ];

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _submit(PaneViewModel vm) async {
    final text = _input.text;
    HapticFeedback.lightImpact();
    if (text.isEmpty) {
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pane = machine.snapshot.panes
        .where((p) => p.id == widget.paneId)
        .firstOrNull;
    final live = machine.isLive;
    final problem = !live ? (machine.error ?? 'Offline') : error;
    final hint = switch (machine.state) {
      LinkState.online => 'Message ${pane?.agent ?? 'pane'}…',
      LinkState.connecting => 'Connecting…',
      LinkState.approval => 'Waiting for sign-in approval',
      LinkState.reconnecting || LinkState.offline => 'Offline — reconnecting',
      LinkState.attention => 'Needs attention — see above',
      LinkState.disabled => 'Machine disabled',
    };
    final canSend = live && !sending;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(pane?.agent ?? pane?.title ?? widget.paneId,
                style: theme.textTheme.titleMedium),
            Text(
              '${machine.profile.label} · ${widget.paneId}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: wrap ? 'Show exact terminal layout' : 'Wrap lines to screen',
            isSelected: wrap,
            icon: const Icon(Icons.wrap_text_rounded),
            onPressed: () {
              HapticFeedback.selectionClick();
              final next = !wrap;
              vm.setWrap(next);
              unawaited(context.read<TerminalSettings>().setWrap(next));
            },
          ),
          if (pane != null)
            Padding(
              padding: const EdgeInsets.only(right: Gap.lg),
              child: StatusPill(status: pane.status, dim: !live || stale),
            ),
        ],
      ),
      body: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: problem == null
                ? const SizedBox(width: double.infinity)
                : _ProblemBar(
                    message: problem,
                    onRetry: () {
                      machine.retry();
                      vm.refresh();
                    },
                  ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.card - 4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: TerminalColors.background,
                    border: Border.all(color: TerminalColors.border),
                    borderRadius: BorderRadius.circular(Radii.card - 4),
                  ),
                  child: Builder(
                    builder: (context) {
                      final (fontSize, wrap) =
                          context.select<TerminalSettings, (double, bool)>(
                        (s) => (s.fontSize, s.wrap),
                      );
                      final settings = context.read<TerminalSettings>();
                      return TerminalView(
                        text: context.select<PaneViewModel, String>(
                          (v) => v.text,
                        ),
                        fontSize: fontSize,
                        wrap: wrap,
                        onFontSizeChanged: settings.previewFontSize,
                        onFontSizeEnd: (size) =>
                            unawaited(settings.setFontSize(size)),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              itemCount: _quickKeys.length,
              separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
              itemBuilder: (_, i) {
                final (label, keys) = _quickKeys[i];
                return _KeyButton(
                  label: label,
                  onPressed: canSend
                      ? () {
                          HapticFeedback.selectionClick();
                          vm.sendKeys(keys);
                        }
                      : null,
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: live,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submit(vm),
                      style: const TextStyle(fontFamily: monoFamily, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: hint,
                        fillColor: scheme.surfaceContainerHigh,
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  _PressScale(
                    enabled: canSend,
                    child: SizedBox.square(
                      dimension: 48,
                      child: IconButton.filled(
                        onPressed: canSend ? () => _submit(vm) : null,
                        icon: sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.arrow_upward_rounded),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Scales its child to 0.97 while a pointer is down on it, so a tap answers
/// the finger before the action completes.
class _PressScale extends StatefulWidget {
  const _PressScale({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed && widget.enabled ? 0.97 : 1,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 120),
          curve: _easeOut,
          child: widget.child,
        ),
      );
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _PressScale(
      enabled: onPressed != null,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.chip),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.chip),
          onTap: onPressed,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: Gap.md),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: monoFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: onPressed == null ? scheme.outline : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProblemBar extends StatelessWidget {
  const _ProblemBar({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const color = Color(0xFFF59E0B);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.xs, Gap.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.chip),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_rounded, size: 18, color: color),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
