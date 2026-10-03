import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/machine_connection.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'pane_view_model.dart';

class PaneScreen extends StatelessWidget {
  const PaneScreen({super.key, required this.machine, required this.paneId});

  final MachineConnection machine;
  final String paneId;

  @override
  Widget build(BuildContext context) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: machine),
          ChangeNotifierProvider(
            create: (_) => PaneViewModel(api: machine.api, paneId: paneId),
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
  final _scroll = ScrollController();
  bool _follow = true;

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
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom =
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;
      if (atBottom != _follow) setState(() => _follow = atBottom);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _stickToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_follow && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
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
    final vm = context.watch<PaneViewModel>();
    final machine = context.watch<MachineConnection>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pane = machine.snapshot.panes
        .where((p) => p.id == widget.paneId)
        .firstOrNull;
    final problem = !machine.isLive ? (machine.error ?? 'Offline') : vm.error;
    _stickToBottom();

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
          if (pane != null)
            Padding(
              padding: const EdgeInsets.only(right: Gap.lg),
              child: StatusPill(status: pane.status, dim: !machine.isLive),
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
                  child: Stack(
                    children: [
                      // Vertical scroll for history; horizontal so box-drawing
                      // and tables keep their shape on a narrow screen.
                      SingleChildScrollView(
                        controller: _scroll,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.all(Gap.md),
                          child: SelectionArea(
                            child: Text(
                              vm.text.isEmpty ? ' ' : vm.text,
                              softWrap: false,
                              style: const TextStyle(
                                fontFamily: monoFamily,
                                fontSize: 11.5,
                                height: 1.3,
                                color: TerminalColors.foreground,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: Gap.md,
                        bottom: Gap.md,
                        child: AnimatedScale(
                          scale: _follow ? 0 : 1,
                          duration: const Duration(milliseconds: 160),
                          child: FloatingActionButton.small(
                            heroTag: null,
                            onPressed: () {
                              setState(() => _follow = true);
                              _scroll.jumpTo(_scroll.position.maxScrollExtent);
                            },
                            child: const Icon(Icons.keyboard_double_arrow_down_rounded),
                          ),
                        ),
                      ),
                    ],
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
                  onPressed: vm.sending
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          vm.sendKeys(keys);
                        },
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
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submit(vm),
                      style: const TextStyle(fontFamily: monoFamily, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Message ${pane?.agent ?? 'pane'}…',
                        fillColor: scheme.surfaceContainerHigh,
                      ),
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  SizedBox.square(
                    dimension: 48,
                    child: IconButton.filled(
                      onPressed: vm.sending ? null : () => _submit(vm),
                      icon: vm.sending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_upward_rounded),
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

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
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
