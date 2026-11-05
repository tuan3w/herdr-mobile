import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'press.dart';
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

/// How long toasts stay. One place, so they do not drift apart. The clock
/// starts once the toast is in place and stops while a finger is on it.
abstract final class ToastTiming {
  /// A toast with a button needs time to be reached; a failure needs time to
  /// be read. A short message is read at a glance (Telegram's rule: under 20
  /// characters is short).
  static Duration of(ToastKind kind, {required bool hasAction, required String message}) =>
      kind == ToastKind.failed || hasAction
      ? Dwell.toastAction
      : message.length < 20
      ? Dwell.toastShort
      : Dwell.toastLong;
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
    Toaster.of(context)
        .show(message, kind: kind, action: action, duration: duration, groupKey: groupKey, groupMessage: groupMessage);

/// A handle on the root overlay that outlives the widget that took it: code
/// that shows a toast after an `await` (or after its screen popped) captures
/// one first, before the gap.
class Toaster {
  const Toaster(this._overlay);

  /// The overlay of the root navigator. Throws without one (a context above
  /// the `MaterialApp`).
  factory Toaster.of(BuildContext context) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    // design-lint: allow(voice) a developer assertion, never shown to a person
    assert(overlay != null, 'showToast needs a context under the app\'s Navigator.');
    return Toaster(overlay!);
  }

  /// Like [of], but null instead of throwing.
  static Toaster? maybeOf(BuildContext context) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    return overlay == null ? null : Toaster(overlay);
  }

  final OverlayState _overlay;

  /// Shows [message]. A toast of the same [groupKey] still on screen changes
  /// its text in place; any other message takes over: the toast showing
  /// leaves while the new one comes in. Does nothing once the overlay is gone.
  ///
  /// * [duration] defaults to [ToastTiming.of].
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
      duration: duration ?? ToastTiming.of(kind, hasAction: action != null, message: message),
      groupKey: groupKey,
      groupMessage: groupMessage,
      count: count,
    );
    final live = _live;
    if (live != null && live.overlay == _overlay && _overlay.mounted) {
      final view = live.view;
      if (view == null || (live.spec.joins(next) && !view.leaving)) {
        live.present(next);
        return;
      }
      // Another message: the one showing leaves as this one arrives.
      view.dismiss();
    } else {
      live?.discard();
    }
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

/// Wrap a bar that sits over the page's bottom edge (the board's batch
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
    final next = box.size.height + Gap.sm;
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

class _ToastViewState extends State<_ToastView> with TickerProviderStateMixin {
  /// In and out: 0 below its place (hidden behind the bar it stands on), 1 in place.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.sheetIn,
    reverseDuration: Motion.sheetOut,
  )..addStatusListener(_onStatus);
  late final Animation<double> _curve = Motion.curved(_controller);

  /// Sideways, under the finger: a swipe puts it away.
  late final AnimationController _swipe = AnimationController.unbounded(vsync: this);

  Timer? _timer;
  bool leaving = false;
  bool _touched = false;

  static const _maxWidth = 480.0;

  /// A fling faster than this (dp/s) puts it away whatever the distance.
  static const _flingAway = 800.0;

  @override
  void initState() {
    super.initState();
    widget.slot.view = this;
    _controller.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Under reduced motion it only fades, and quickly.
    final reduced = Motion.reduced(context);
    _controller
      ..duration = reduced ? Motion.fade : Motion.sheetIn
      ..reverseDuration = reduced ? Motion.fade : Motion.sheetOut;
  }

  _ToastSpec get _spec => widget.slot.spec;

  /// Starts the clock, unless the toast is still arriving or a finger holds it.
  void _arm() {
    _timer?.cancel();
    if (leaving || _touched || _controller.status != AnimationStatus.completed) return;
    _timer = Timer(_spec.duration, dismiss);
  }

  /// A joined or swapped toast: the new text, a full clock.
  void apply() {
    leaving = false;
    if (_controller.status == AnimationStatus.completed) {
      _arm();
    } else {
      unawaited(_controller.forward());
    }
    setState(() {});
  }

  void dismiss() {
    _timer?.cancel();
    if (leaving) return;
    leaving = true;
    unawaited(_controller.reverse());
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _arm();
    if (status != AnimationStatus.dismissed || !leaving) return;
    _remove();
  }

  void _remove() {
    final slot = widget.slot;
    if (_live == slot) _live = null;
    if (slot.entry.mounted) {
      slot.entry
        ..remove()
        ..dispose();
    }
  }

  void _act() {
    if (leaving) return;
    final run = List<VoidCallback>.of(_spec.callbacks.reversed);
    dismiss();
    for (final callback in run) {
      callback();
    }
  }

  void _hold(bool down) {
    _touched = down;
    if (down) {
      _timer?.cancel();
    } else {
      _arm();
    }
  }

  void _swipeEnd(double velocity, double width) {
    final dx = _swipe.value;
    if (dx.abs() > width / 3 || velocity.abs() > _flingAway) {
      leaving = true;
      _timer?.cancel();
      final side = (dx.abs() > 1 ? dx.sign : velocity.sign) * (width + Gap.lg);
      unawaited(
        _swipe.animateTo(side, duration: Motion.standard, curve: Motion.easeOut).whenComplete(() {
          if (mounted) _remove();
        }),
      );
    } else {
      unawaited(_swipe.animateWith(SpringSimulation(Springs.settle, dx, 0, velocity)));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.slot.view == this) widget.slot.view = null;
    if (_live == widget.slot) _live = null;
    _controller.dispose();
    _swipe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    final reduced = Motion.reduced(context);
    final media = MediaQuery.of(context);
    final action = spec.action;
    final card = ToastCard(
      key: toastKey,
      message: spec.message,
      kind: spec.kind,
      actionLabel: action?.label,
      onAction: action == null ? null : _act,
    );
    return ValueListenableBuilder<({double lift, bool aboveKeyboard})?>(
      valueListenable: ToastShelf.showing,
      builder: (context, shelf, _) {
        // Two parts: where it rests (the shelf it stands on, or the system
        // inset) eases when a bar appears or grows under it, so it moves up
        // rather than through the bar; the keyboard's share follows the
        // keyboard frame by frame, so it never trails behind it.
        final rest = shelf == null ? media.padding.bottom + Gap.sm : shelf.lift;
        final keyboard = shelf == null
            ? math.max(media.viewInsets.bottom - media.padding.bottom, 0.0)
            : (shelf.aboveKeyboard ? media.viewInsets.bottom : 0.0);
        final width = math.min(_maxWidth, media.size.width - 2 * _side);
        return TweenAnimationBuilder<double>(
          tween: Tween(end: rest),
          duration: Motion.of(context, Motion.standard),
          curve: Motion.easeOut,
          builder: (context, lift, child) => Positioned(left: 0, right: 0, bottom: lift + keyboard, child: child!),
          child: Align(
            heightFactor: 1,
            child: SizedBox(
              width: width,
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: kBarTextScale,
                child: Listener(
                  // A finger on it holds the clock: nothing leaves while read.
                  onPointerDown: (_) => _hold(true),
                  onPointerUp: (_) => _hold(false),
                  onPointerCancel: (_) => _hold(false),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    // Without a button, a tap puts it away: it may sit over
                    // something the person is reaching for. With one, the tap
                    // belongs to the button and a swipe puts it away.
                    onTap: action == null ? dismiss : null,
                    onHorizontalDragUpdate: (d) => _swipe.value += d.delta.dx,
                    onHorizontalDragEnd: (d) => _swipeEnd(d.velocity.pixelsPerSecond.dx, width),
                    onHorizontalDragCancel: () => _swipeEnd(0, width),
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_curve, _swipe]),
                      child: card,
                      builder: (context, child) {
                        final t = _curve.value;
                        final dx = _swipe.value;
                        Widget out = child!;
                        if (dx != 0) out = Transform.translate(offset: Offset(dx, 0), child: out);
                        if (t >= 1) return out;
                        if (reduced) return Opacity(opacity: t, child: out);
                        // It rises from behind the bar it stands on: the
                        // clip is its own place, so below that it is hidden.
                        return ClipRect(
                          child: FractionalTranslation(translation: Offset(0, 1 - t), child: out),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Side margin: the floating bar's (`FloatingBar.side`), so a toast lines up
  /// with the bar it stands on.
  static const _side = Gap.md;
}

/// The toast's card: the inverse surface, a mark for [ToastKind.success] /
/// [ToastKind.failed], the message (two lines at most) and an optional button.
/// Only the picture: [Toaster] places, times and moves it. Public so the kit
/// catalog can show every kind side by side, which the one live toast cannot.
class ToastCard extends StatelessWidget {
  const ToastCard({super.key, required this.message, this.kind = ToastKind.info, this.actionLabel, this.onAction});

  final String message;
  final ToastKind kind;

  /// The button's word; drawn only with [onAction].
  final String? actionLabel;
  final VoidCallback? onAction;

  /// One line of text and its padding: the toast never shrinks below this.
  static const minHeight = 48.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final label = actionLabel;
    final onAction = this.onAction;
    final mark = switch (kind) {
      ToastKind.info => null,
      ToastKind.success => (LucideIcons.check, ds.done),
      ToastKind.failed => (LucideIcons.circleAlert, ds.danger),
    };
    final hasAction = label != null && onAction != null;
    // The one inverse surface: a message over the page, never mistaken for a
    // field or a card in it. No outline, no shadow: dark on paper and a step
    // lighter on ink is edge enough.
    return DecoratedBox(
      decoration: BoxDecoration(color: ds.inverseSurface, borderRadius: BorderRadius.circular(Radii.md)),
      // The root overlay sits above every route, so no `Scaffold` is above the
      // text: without a `Material` it takes `MaterialApp`'s fallback style, a
      // double yellow underline. Transparent: it paints nothing of its own.
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: minHeight),
          child: Padding(
            padding: EdgeInsets.fromLTRB(Gap.lg, Gap.sm, hasAction ? Gap.xs : Gap.lg, Gap.sm),
            child: Row(
              children: [
                if (mark != null) ...[
                  ExcludeSemantics(
                    child: Icon(mark.$1, size: IconSize.bar, color: mark.$2),
                  ),
                  const SizedBox(width: Gap.md),
                ],
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.body.copyWith(color: ds.onInverse),
                    ),
                  ),
                ),
                if (hasAction)
                  PressBuilder(
                    key: toastActionKey,
                    onTap: onAction,
                    minTapSize: kMinTap,
                    scale: PressScale.button,
                    builder: (context, pressed) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                      child: Text(label, style: Type.button.copyWith(color: pressed ? ds.onInverse : ds.inverseAccent)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
