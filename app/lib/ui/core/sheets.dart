import 'dart:async';

import 'package:flutter/material.dart';

import 'buttons.dart';
import 'hold_confirm.dart';
import 'motion.dart';
import 'rows.dart';
import 'sheet_frame.dart';
import 'sheet_position.dart';
import 'tokens.dart';

/// Opens a sheet in the app's style: a [SheetRoute] whose [SheetFrame] gives
/// it the rounded surface, the [SheetGrabber] and the gestures every sheet
/// shares (see [SheetPosition]): it follows the finger, closes on a throw or a
/// long pull, can be caught while it moves, and a tall one opens at half
/// height and is dragged or scrolled up to show the rest. [builder] returns a
/// [SheetScaffold], which pads, titles and scrolls the body by its
/// [SheetKind].
///
/// Colours come from the theme, so a light/dark switch while a sheet is open
/// restyles it. A tall sheet stops below the status bar: the session overview
/// used to grow under the clock, its grabber and title drawn over the status
/// icons. The side insets are taken inside the sheet ([SafeArea]), not off
/// it: a landscape phone with a side navigation bar showed the page in a strip
/// beside a sheet that had them taken off. The keyboard lifts the sheet; its
/// content never pads for it. Under reduced motion the sheet appears and goes
/// without sliding (dragging still works).
Future<T?> showAppSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  final navigator = Navigator.of(context);
  // Themes set between the opener and the navigator still apply in the sheet.
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push(
    SheetRoute<T>(
      reduced: Motion.reduced(context),
      builder: (ctx) => themes.wrap(
        Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: MaterialLocalizations.of(ctx).dialogLabel,
          child: SafeArea(top: false, child: builder(ctx)),
        ),
      ),
    ),
  );
}

/// The handle at the top of every sheet (app sheets and the attach sheet).
class SheetGrabber extends StatelessWidget {
  const SheetGrabber({super.key});

  static const width = 36.0;
  static const height = 4.0;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(color: context.ds.faint, borderRadius: BorderRadius.circular(Radii.pill)),
  );
}

/// The quiet title of an action or list sheet, announced as a heading.
class SheetTitle extends StatelessWidget {
  const SheetTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: Type.label.copyWith(color: context.ds.textSecondary)),
  );
}

/// What a sheet holds; it sets the padding, the title style and how the body
/// scrolls.
enum SheetKind {
  /// Rows of actions (replaces popup menus). Quiet [SheetTitle].
  actions,

  /// A long list: the title stays pinned and the body scrolls. A body that
  /// scrolls on its own (a lazy list) sets [SheetScaffold.scrolls]; give it
  /// `shrinkWrap` while it is short.
  list,

  /// A short message with buttons. [Type.title] title.
  message,

  /// Fields: like [message]. The sheet stands on the keyboard.
  form,
}

/// The body of every app sheet: padding, title, scrolling and the closing
/// [actions] (usually [AppButton]s, stacked full width) by [kind].
///
/// The body scrolls with the sheet's [SheetScrollController], so a drag on it
/// moves the sheet first where it should (up from half height, down from the
/// top of the body). The [actions] sit under the scrolling part, never inside
/// it, and are [SheetPinned]: they stay in reach while a tall sheet rests at
/// half height.
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    this.title,
    required this.kind,
    required this.child,
    this.actions = const [],
    this.scrolls = false,
    this.bleed = false,
  });

  final String? title;
  final SheetKind kind;
  final Widget child;

  /// Stacked [Gap.lg] under [child], [Gap.sm] apart; the primary one first.
  final List<Widget> actions;

  /// [SheetKind.list] only: [child] is its own scroll view (a lazy list), so
  /// it is given the room under the title instead of being wrapped in one.
  final bool scrolls;

  /// [child] runs edge to edge: its rows bring their own gutter (a
  /// [SectionLabel], full-width rows). The title and [actions] keep theirs.
  final bool bleed;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final title = this.title;
    final rows = kind == SheetKind.actions || kind == SheetKind.list;
    // The side inset; vertical padding wraps the whole sheet.
    final side = rows ? Gap.xs : Gap.gutter;
    final padding = rows
        ? const EdgeInsets.only(top: Gap.sm, bottom: Gap.md)
        : const EdgeInsets.only(top: Gap.xl, bottom: Gap.lg);
    final scroll = SheetScope.maybeOf(context)?.scroll;
    final heading = title == null
        ? null
        : rows
        // Outer inset 4 + 16: the title sits on the 20 gutter, with the rows.
        ? Padding(padding: EdgeInsets.fromLTRB(side + Gap.lg, Gap.sm, side + Gap.lg, Gap.sm), child: SheetTitle(title))
        : Padding(
            padding: EdgeInsets.fromLTRB(side, 0, side, Gap.sm),
            child: Semantics(
              header: true,
              child: Text(title, style: Type.title.copyWith(color: ds.text)),
            ),
          );
    final buttons = actions.isEmpty
        ? null
        : SheetPinned(
            color: ds.surface,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                rows ? side + Gap.lg : side,
                Gap.lg,
                rows ? side + Gap.lg : side,
                padding.bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(height: Gap.sm), actions[i]],
                ],
              ),
            ),
          );
    // The bottom padding goes under the buttons when there are any.
    final end = buttons == null ? padding.bottom : 0.0;
    final body = bleed
        ? child
        : Padding(
            padding: EdgeInsets.symmetric(horizontal: side),
            child: child,
          );
    if (kind == SheetKind.list) {
      return Padding(
        padding: EdgeInsets.only(top: padding.top, bottom: end),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?heading,
            Flexible(
              child: !scrolls
                  ? SingleChildScrollView(controller: scroll, child: body)
                  : scroll == null
                  ? body
                  // The lazy list takes the sheet's controller as its primary one.
                  : PrimaryScrollController(controller: scroll, child: body),
            ),
            ?buttons,
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            controller: scroll,
            padding: EdgeInsets.only(top: padding.top, bottom: end),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [?heading, body],
            ),
          ),
        ),
        ?buttons,
      ],
    );
  }
}

class SheetAction {
  const SheetAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
    this.unavailable,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  /// Why the action cannot be used now. The row stays, dimmed and inert, and
  /// says this under its label.
  final String? unavailable;
}

/// One row of an action sheet: [onTap] runs when the action is available.
class SheetActionRow extends StatelessWidget {
  const SheetActionRow({super.key, required this.action, required this.onTap});

  final SheetAction action;
  final VoidCallback onTap;

  /// One line with its icon; a dimmed row grows to say why.
  static const _rowHeight = 52.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final reason = action.unavailable;
    final inert = reason != null;
    return PressRow(
      onTap: inert ? null : onTap,
      // A dimmed row is still read as a button, a disabled one.
      button: inert ? true : null,
      minHeight: _rowHeight,
      padding: EdgeInsets.symmetric(horizontal: Gap.lg - PressRow.inset, vertical: inert ? Gap.sm : 0),
      child: Row(
        children: [
          Icon(
            action.icon,
            size: IconSize.lead,
            color: inert
                ? ds.textTertiary
                : action.destructive
                ? ds.dangerText
                : ds.textSecondary,
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              // Shrink-wrapped, so the row centres the label with its icon
              // (a full-height column pinned the label to the top).
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.row.copyWith(
                    color: inert
                        ? ds.textMuted
                        : action.destructive
                        ? ds.dangerText
                        : ds.text,
                  ),
                ),
                if (reason != null)
                  Text(
                    reason,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Type.caption.copyWith(color: ds.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A list of actions in a sheet (replaces popup menus). [footer] follows the
/// actions (a [SwitchRow] for a setting that belongs with them).
Future<void> showActionSheet(
  BuildContext context, {
  String? title,
  required List<SheetAction> actions,
  List<Widget> footer = const [],
}) => showAppSheet<void>(
  context,
  builder: (ctx) => SheetScaffold(
    title: title,
    kind: SheetKind.actions,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final a in actions)
          SheetActionRow(
            action: a,
            onTap: () {
              Navigator.of(ctx).pop();
              a.onTap();
            },
          ),
        ...footer,
      ],
    ),
  ),
);

/// Confirmation in a sheet. Returns true if confirmed.
///
/// With [hold] the confirm button has to be held ([HoldToConfirm]) instead of
/// tapped: for what cannot be taken back and deletes something outside the app
/// (a worktree's folder). A tap or an early release only says how; assistive
/// technology gets a two-step activation. Only a [destructive] confirmation
/// can be held: the fill is the danger tint.
Future<bool> showConfirmSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = true,
  bool hold = false,
}) async {
  assert(!hold || destructive, 'a held confirmation is a danger button');
  final result = await showAppSheet<bool>(
    context,
    builder: (ctx) => SheetScaffold(
      title: title,
      kind: SheetKind.message,
      actions: [
        if (hold)
          _HoldConfirmButton(label: confirmLabel, onConfirmed: () => Navigator.of(ctx).pop(true))
        else
          AppButton(
            label: confirmLabel,
            kind: destructive ? AppButtonKind.danger : AppButtonKind.primary,
            expand: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        AppButton(
          label: 'Cancel',
          kind: AppButtonKind.secondary,
          expand: true,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
      ],
      child: Text(message, style: Type.compact.copyWith(color: ctx.ds.textSecondary)),
    ),
  );
  return result ?? false;
}

/// The danger button of a held confirmation, painted like the expanded danger
/// [AppButton] (same height, radius, wash), with the hold's fill under the
/// label. [HoldToConfirm.onActivate] (a screen reader, a switch) primes it; a
/// second activation within [Dwell.confirm] confirms.
class _HoldConfirmButton extends StatefulWidget {
  const _HoldConfirmButton({required this.label, required this.onConfirmed});

  final String label;
  final VoidCallback onConfirmed;

  @override
  State<_HoldConfirmButton> createState() => _HoldConfirmButtonState();
}

class _HoldConfirmButtonState extends State<_HoldConfirmButton> {
  Timer? _unprime;
  bool _primed = false;

  @override
  void dispose() {
    _unprime?.cancel();
    super.dispose();
  }

  void _activate() {
    if (_primed) {
      _unprime?.cancel();
      widget.onConfirmed();
      return;
    }
    setState(() => _primed = true);
    _unprime = Timer(Dwell.confirm, () {
      if (mounted) setState(() => _primed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return HoldToConfirm(
      onConfirmed: widget.onConfirmed,
      onActivate: _activate,
      semanticLabel: _primed ? 'Confirm: ${widget.label}' : '${widget.label}, needs holding or a second activation',
      scale: PressScale.panel,
      builder: (context, hold) {
        final shown = _primed
            ? 'Hold or tap again'
            : hold.showsHold
            ? 'Hold to ${widget.label.toLowerCase()}'
            : widget.label;
        return AnimatedContainer(
          duration: Motion.pressing(hold.holding),
          curve: Motion.easeOut,
          height: 46,
          width: double.infinity,
          decoration: BoxDecoration(
            color: hold.holding ? ds.washPressed(ds.danger) : ds.wash(ds.danger),
            borderRadius: BorderRadius.circular(Radii.sm),
            // Always a border, clear unless primed: a border pads the box, and
            // a primed button must not grow under the finger.
            border: Border.all(color: _primed ? ds.armedEdge(ds.danger) : Colors.transparent),
          ),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              hold.fill,
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    shown,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.button.copyWith(color: ds.dangerText),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
