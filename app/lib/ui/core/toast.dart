import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'controls.dart';
import 'motion.dart';
import 'theme.dart';

/// Keys of the toast card and of its button, for tests to find them by.
const toastKey = ValueKey<String>('toast');
const toastActionKey = ValueKey<String>('toast.action');

/// What a toast reports. The kind picks the mark, the haptic (fired when the
/// toast appears) and the default time on screen.
enum ToastKind {
  /// A quiet confirmation or notice. No mark, no haptic.
  info,

  /// Something the person asked for went through: [Haptics.sent].
  success,

  /// Something did not work: [Haptics.failed], and it stays a little longer.
  failed,
}

/// The one button of a toast ("Undo", "Open"). Tapping it runs [onPressed]
/// once and dismisses the toast.
class ToastAction {
  const ToastAction(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;
}

/// Where toasts stay on screen. One place, so they do not drift apart.
abstract final class ToastTiming {
  /// A plain message: read at a glance.
  static const standard = Duration(seconds: 3);

  /// A toast with a button needs time to be reached; a failure needs time to
  /// be read.
  static const long = Duration(seconds: 5);

  static Duration of(ToastKind kind, {required bool hasAction}) =>
      kind == ToastKind.failed || hasAction ? long : standard;
}

/// Shows a toast on the app's root overlay and replaces the one showing: a
/// newer message is never queued behind a stale one, and a failure never
/// waits. See [Toaster.show] for the parameters.
void showToast(
  BuildContext context,
  String message, {
  ToastKind kind = ToastKind.info,
  ToastAction? action,
  Duration? duration,
  Object? groupKey,
  String Function(int count)? groupMessage,
}) =>
    Toaster.of(context).show(
      message,
      kind: kind,
      action: action,
      duration: duration,
      groupKey: groupKey,
      groupMessage: groupMessage,
    );

/// A handle on the root overlay that outlives the widget that took it: code
/// that shows a toast after an `await` (or after its screen popped) captures
/// one first, before the gap.
class Toaster {
  const Toaster(this._overlay);

  /// The overlay of the root navigator. Throws without one (a context above
  /// the `MaterialApp`).
  factory Toaster.of(BuildContext context) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    assert(overlay != null, 'showToast needs a context under the app\'s Navigator.');
    return Toaster(overlay!);
  }

  /// Like [of], but null instead of throwing.
  static Toaster? maybeOf(BuildContext context) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    return overlay == null ? null : Toaster(overlay);
  }

  final OverlayState _overlay;

  /// Shows [message], replacing the toast on screen (it does not slide again:
  /// the text changes in place). Does nothing once the overlay is gone.
  ///
  /// * [duration] defaults to [ToastTiming.of]: 3 s, 5 s with an [action] or
  ///   for [ToastKind.failed].
  /// * [groupKey] lets repeated actions of one kind share a toast so an
  ///   earlier Undo is not lost: while a toast with the same key is still
  ///   showing, the new call joins it. The count goes up (by [count], for a
  ///   call that did several things at once), the text becomes
  ///   `groupMessage(total)` (the plain [message] without one), the clock
  ///   restarts, and the button runs the actions of every call, latest first,
  ///   so "Undo" takes all of them back. After the toast is gone (or when it
  ///   is leaving) the next call starts a new group of [count].
  void show(
    String message, {
    ToastKind kind = ToastKind.info,
    ToastAction? action,
    Duration? duration,
    Object? groupKey,
    String Function(int count)? groupMessage,
    int count = 1,
  }) {
    if (!_overlay.mounted) return;
    switch (kind) {
      case ToastKind.info:
        break;
      case ToastKind.success:
        Haptics.sent();
      case ToastKind.failed:
        Haptics.failed();
    }
    final next = _ToastSpec(
      message: message,
      kind: kind,
      action: action,
      duration: duration ?? ToastTiming.of(kind, hasAction: action != null),
      groupKey: groupKey,
      groupMessage: groupMessage,
      count: count,
    );
    final live = _live;
    if (live != null && live.overlay == _overlay && _overlay.mounted) {
      live.present(next);
      return;
    }
    live?.discard();
    final slot = _ToastSlot(_overlay, next);
    _live = slot;
    slot.entry = OverlayEntry(builder: (_) => _ToastView(slot: slot));
    _overlay.insert(slot.entry);
  }
}

/// The toast on screen, if any. One at a time, app-wide.
_ToastSlot? _live;

/// Install on the app's `Navigator`. Toasts live on the root overlay, above
/// every route, so a sheet or dialog that opens under one would have its
/// bottom rows covered: the toast steps aside (it leaves like a timed-out one)
/// when a [PopupRoute] is pushed.
class ToastRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PopupRoute) return;
    final live = _live;
    if (live == null) return;
    if (live.view case final view?) {
      view.dismiss();
    } else {
      live.discard();
    }
  }
}

/// What one toast shows. Joining a group builds a new spec from the old one.
class _ToastSpec {
  _ToastSpec({
    required this.message,
    required this.kind,
    required this.action,
    required this.duration,
    required this.groupKey,
    required this.groupMessage,
    this.count = 1,
    List<VoidCallback>? undo,
  }) : callbacks = undo ?? [if (action != null) action.onPressed];

  final String message;
  final ToastKind kind;
  final ToastAction? action;
  final Duration duration;
  final Object? groupKey;
  final String Function(int count)? groupMessage;
  final int count;

  /// What the button runs, in the order the calls were made.
  final List<VoidCallback> callbacks;

  bool joins(_ToastSpec next) => groupKey != null && groupKey == next.groupKey;

  _ToastSpec joinedBy(_ToastSpec next) {
    final n = count + next.count;
    return _ToastSpec(
      message: next.groupMessage?.call(n) ?? next.message,
      kind: next.kind,
      action: next.action,
      duration: next.duration,
      groupKey: groupKey,
      groupMessage: next.groupMessage,
      count: n,
      undo: [...callbacks, if (next.action != null) next.action!.onPressed],
    );
  }
}

class _ToastSlot {
  _ToastSlot(this.overlay, this.spec);

  final OverlayState overlay;
  late final OverlayEntry entry;
  _ToastSpec spec;
  _ToastViewState? view;

  void present(_ToastSpec next) {
    final v = view;
    // A toast on its way out has nothing left to undo: start a fresh group.
    spec = spec.joins(next) && !(v?.leaving ?? false) ? spec.joinedBy(next) : next;
    v?.apply();
  }

  /// Removes the entry now (the overlay is being swapped).
  void discard() {
    if (_live == this) _live = null;
    entry
      ..remove()
      ..dispose();
  }
}

/// Wrap a bar that sits over the page's bottom edge (the tab bar, the batch
/// bar, a form's action bar) so toasts stand above it instead of covering its
/// buttons. It counts only while its route is the one showing (under a pushed
/// screen the bar is not there to clear) and while it is built.
///
/// The toast stands [lift] above the bottom edge, or, when that is null, just
/// above the bar's own top as measured (it follows the bar when it grows).
/// With [aboveKeyboard] the bar rides on top of the keyboard (a form whose
/// body shrinks for it), so the keyboard's height is added; the floating tab
/// bar stays under it and does not set this.
class ToastShelf extends StatefulWidget {
  const ToastShelf({super.key, required this.child, this.lift, this.aboveKeyboard = false});

  final Widget child;
  final double? lift;
  final bool aboveKeyboard;

  /// The highest bar showing, for [_ToastView] to stand above; null when
  /// there is none.
  static final ValueNotifier<({double lift, bool aboveKeyboard})?> showing =
      ValueNotifier<({double lift, bool aboveKeyboard})?>(null);

  static final Set<_ToastShelfState> _shelves = {};
  static bool _scheduled = false;

  /// Applies after the frame: bars mount and unmount while a frame builds, and
  /// the toast listens to the answer.
  static void _publish() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      ({double lift, bool aboveKeyboard})? best;
      for (final shelf in _shelves) {
        final lift = shelf.lift;
        if (lift == null) continue;
        if (best == null || lift > best.lift) {
          best = (lift: lift, aboveKeyboard: shelf.widget.aboveKeyboard);
        }
      }
      showing.value = best;
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  State<ToastShelf> createState() => _ToastShelfState();
}

class _ToastShelfState extends State<ToastShelf> {
  double? _measured;

  double? get lift => widget.lift ?? _measured;

  void _sync(bool want) {
    final changed = want ? ToastShelf._shelves.add(this) : ToastShelf._shelves.remove(this);
    if (changed) ToastShelf._publish();
  }

  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final next = box.size.height + Gap.md;
    if (next == _measured) return;
    _measured = next;
    ToastShelf._publish();
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync(TickerMode.valuesOf(context).enabled);
  }

  @override
  void didUpdateWidget(ToastShelf old) {
    super.didUpdateWidget(old);
    if (old.lift != widget.lift || old.aboveKeyboard != widget.aboveKeyboard) ToastShelf._publish();
  }

  @override
  void dispose() {
    _sync(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lift != null) return widget.child;
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        SchedulerBinding.instance.addPostFrameCallback((_) => _measure());
        return false;
      },
      child: SizeChangedLayoutNotifier(child: widget.child),
    );
  }
}

class _ToastView extends StatefulWidget {
  const _ToastView({required this.slot});

  final _ToastSlot slot;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.sheetIn,
    reverseDuration: Motion.sheetOut,
  )..addStatusListener(_onStatus);
  late final Animation<double> _curve = CurvedAnimation(parent: _controller, curve: Motion.easeOut);
  Timer? _timer;
  bool leaving = false;

  /// Slide distance of the enter/exit, in dp.
  static const _travel = 16.0;
  static const _maxWidth = 480.0;

  @override
  void initState() {
    super.initState();
    widget.slot.view = this;
    _arm();
    _controller.forward();
  }

  _ToastSpec get _spec => widget.slot.spec;

  void _arm() {
    _timer?.cancel();
    _timer = Timer(_spec.duration, dismiss);
  }

  /// A new or joined toast arrived: show it, back in if it was leaving.
  void apply() {
    leaving = false;
    _arm();
    if (_controller.status != AnimationStatus.completed) unawaited(_controller.forward());
    setState(() {});
  }

  void dismiss() {
    _timer?.cancel();
    if (leaving) return;
    leaving = true;
    unawaited(_controller.reverse());
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || !leaving) return;
    final slot = widget.slot;
    if (_live == slot) _live = null;
    slot.entry
      ..remove()
      ..dispose();
  }

  void _act() {
    if (leaving) return;
    final run = List<VoidCallback>.of(_spec.callbacks.reversed);
    dismiss();
    for (final callback in run) {
      callback();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.slot.view == this) widget.slot.view = null;
    if (_live == widget.slot) _live = null;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final spec = _spec;
    final reduced = Motion.reduced(context);
    final media = MediaQuery.of(context);
    final action = spec.action;
    final mark = switch (spec.kind) {
      ToastKind.info => null,
      ToastKind.success => (LucideIcons.check, ds.done),
      ToastKind.failed => (LucideIcons.circleAlert, ds.danger),
    };
    final card = DecoratedBox(
      key: toastKey,
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(Radii.toast),
        border: Border.all(color: ds.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: ds.isDark ? 0.45 : 0.1),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      // The root overlay sits above every route, so no `Scaffold` is above the
      // text: without a `Material` it takes `MaterialApp`'s fallback style, a
      // double yellow underline. Transparent: it paints nothing of its own.
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTap),
          child: Padding(
            padding: EdgeInsets.fromLTRB(Gap.lg, Gap.sm, action == null ? Gap.lg : Gap.xs, Gap.sm),
            child: Row(
              children: [
                if (mark != null) ...[
                  ExcludeSemantics(child: Icon(mark.$1, size: 18, color: mark.$2)),
                  const SizedBox(width: Gap.sm),
                ],
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      spec.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.body.copyWith(color: ds.text),
                    ),
                  ),
                ),
                if (action != null)
                  PressBuilder(
                    key: toastActionKey,
                    onTap: _act,
                    minTapSize: kMinTap,
                    builder: (context, pressed) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                      child: Text(
                        action.label,
                        style: Type.button.copyWith(
                          color: ds.accentText.withValues(alpha: pressed ? 0.6 : 1),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return ValueListenableBuilder<({double lift, bool aboveKeyboard})?>(
      valueListenable: ToastShelf.showing,
      builder: (context, shelf, _) {
        final bottom = shelf == null
            ? math.max(media.viewInsets.bottom, media.padding.bottom) + Gap.lg
            : shelf.lift + (shelf.aboveKeyboard ? media.viewInsets.bottom : 0);
        return Positioned(
          left: 0,
          right: 0,
          bottom: bottom,
          child: Align(
            heightFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: AnimatedBuilder(
                    animation: _curve,
                    // A tap anywhere on it puts it away: it may sit over
                    // something the person is reaching for.
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      excludeFromSemantics: true,
                      onTap: dismiss,
                      child: card,
                    ),
                    builder: (context, child) {
                      final t = _curve.value;
                      if (t >= 1) return child!;
                      return Opacity(
                        opacity: t,
                        child: Transform.translate(
                          offset: Offset(0, reduced ? 0 : (1 - t) * _travel),
                          child: child,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
