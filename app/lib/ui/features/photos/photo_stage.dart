import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../../core/motion.dart';
import 'photo_math.dart';
import 'photo_pictures.dart';
import 'photo_viewer_view_model.dart';

/// Black behind the pictures, between them, and the colour the screen fades
/// from as a photo is dragged away.
const photoBackdrop = Color(0xFF000000);

/// Gap between two photos while paging, in logical pixels.
const photoPageGap = 16.0;

/// How long a picture stays sharpened after the person zooms back out to fit
/// (zooming in and out again should not decode twice).
const photoSharpHold = Duration(seconds: 2);

/// Where the open picture is: its zoom and pan, the drag that dismisses it, and
/// how far it has been pulled aside while paging.
@immutable
class PhotoPose {
  const PhotoPose({this.scale = 1, this.offset = Offset.zero, this.drag = Offset.zero, this.pageDx = 0});

  static const rest = PhotoPose();

  /// 1 shows the whole picture.
  final double scale;

  /// The picture's centre from the viewport's centre.
  final Offset offset;

  /// A drag at fit that dismisses: follows the finger, the picture shrinks and
  /// the backdrop fades as it grows.
  final Offset drag;

  /// How far the open page is pulled sideways (neighbours follow).
  final double pageDx;

  PhotoPose copyWith({double? scale, Offset? offset, Offset? drag, double? pageDx}) => PhotoPose(
    scale: scale ?? this.scale,
    offset: offset ?? this.offset,
    drag: drag ?? this.drag,
    pageDx: pageDx ?? this.pageDx,
  );

  @override
  bool operator ==(Object other) =>
      other is PhotoPose &&
      other.scale == scale &&
      other.offset == offset &&
      other.drag == drag &&
      other.pageDx == pageDx;

  @override
  int get hashCode => Object.hash(scale, offset, drag, pageDx);
}

enum _Mode {
  /// One finger on a picture at fit, dragged sideways: paging.
  page,

  /// One finger on a picture at fit, dragged up or down: dismissing.
  dismiss,

  /// One finger on a zoomed picture: panning (past an edge, paging).
  pan,

  /// Two or more fingers: zooming around their centre.
  zoom,
}

class _Gesture {
  _Gesture({
    required this.mode,
    required this.pose,
    required this.focal,
    required this.geometry,
    required this.index,
  });

  final _Mode mode;
  final PhotoPose pose;
  final Offset focal;
  final PhotoGeometry geometry;
  final int index;
  late Offset lastFocal = focal;
  late double lastScale = pose.scale;
}

/// One thing the stage is animating towards: a simulation and where its value
/// goes.
class _Track {
  _Track(this.sim, this.apply, {this.end});

  final Simulation sim;
  final void Function(double value) apply;

  /// Where the track comes to rest, when that is a fixed place: the last frame
  /// lands exactly there (a spring is "done" a hair short of it).
  final double? end;
}

/// How far, as a share of the screen, a drag may stretch past an edge.
const _bandReach = 0.4;

const _scaleTolerance = Tolerance(distance: 0.0005, velocity: 0.002);
const _pixelTolerance = Tolerance(distance: 0.05, velocity: 1);

SpringDescription _spring(double ratio) =>
    SpringDescription.withDampingRatio(mass: 1, stiffness: 400, ratio: ratio);

/// The pictures of a [PhotoViewerViewModel], one of them open, and the touch
/// physics to look at them: pinch (around the fingers), double-tap, pan with
/// momentum, rubber-banding at every edge, swiping between photos, and a drag
/// at fit that dismisses.
///
/// One finger or two, everything is **interruptible**: a finger landing stops
/// the animation under it and the next movement starts from where the picture
/// is. Springs hand over the finger's velocity; there is no timed tween. Under
/// reduced motion the picture jumps to where the animation would end.
class PhotoStage extends StatefulWidget {
  const PhotoStage({
    super.key,
    required this.model,
    required this.dismissProgress,
    required this.onTap,
    required this.onDismiss,
    required this.failureBuilder,
    this.onZoomed,
  });

  final PhotoViewerViewModel model;

  /// Written with how far a dismissing drag is (0 to 1): the screen fades its
  /// backdrop and chrome with it.
  final ValueNotifier<double> dismissProgress;

  /// A single tap (toggle the chrome).
  final VoidCallback onTap;

  /// Called once when a drag or flick closes the viewer.
  final VoidCallback onDismiss;

  /// What shows in place of a picture that could not be loaded.
  final Widget Function(BuildContext context, PhotoEntry entry) failureBuilder;

  /// Told when the picture goes from fit to zoomed and back.
  final ValueChanged<bool>? onZoomed;

  @override
  State<PhotoStage> createState() => PhotoStageState();
}

class PhotoStageState extends State<PhotoStage> with SingleTickerProviderStateMixin {
  final _pose = ValueNotifier<PhotoPose>(PhotoPose.rest);
  late final Ticker _ticker = createTicker(_tick);
  var _tracks = <_Track>[];
  _Gesture? _gesture;
  Offset? _downAt;
  final _pointers = <int>{};
  var _multi = false;
  Offset _doubleTapAt = Offset.zero;
  Size _viewport = Size.zero;
  double _dpr = 1;
  var _dismissed = false;
  var _zoomed = false;
  Timer? _sharpTimer;
  var _sharpAsked = false;

  /// The pose of the page that has just been left, while it slides out.
  ({int index, PhotoPose pose})? _leaving;

  /// The pose now (for tests).
  PhotoPose get pose => _pose.value;

  PhotoViewerViewModel get _model => widget.model;
  Offset get _center => Offset(_viewport.width / 2, _viewport.height / 2);
  double get _pitch => _viewport.width + photoPageGap;
  bool get _reduced => Motion.reduced(context);

  @override
  void initState() {
    super.initState();
    _pose.addListener(_poseChanged);
  }

  @override
  void dispose() {
    _sharpTimer?.cancel();
    _ticker.dispose();
    _pose.dispose();
    super.dispose();
  }

  // -- geometry --------------------------------------------------------------

  PhotoGeometry _geometry(int index) {
    final entry = _model.entryAt(index);
    final image = entry?.nativeSize;
    if (image != null) {
      return PhotoGeometry.forImage(viewport: _viewport, image: image, devicePixelRatio: _dpr);
    }
    // Not decoded yet: the thumbnail's shape, and no zooming.
    final holder = entry?.placeholder;
    final fit = holder == null
        ? _viewport
        : applyBoxFit(BoxFit.contain, Size(holder.width.toDouble(), holder.height.toDouble()), _viewport).destination;
    return PhotoGeometry(viewport: _viewport, fit: fit, maxScale: 1);
  }

  // -- pose ------------------------------------------------------------------

  void _set(PhotoPose pose) => _pose.value = pose;

  void _poseChanged() {
    final p = _pose.value;
    final progress = p.scale <= 1.001 ? dismissProgress(p.drag.dy, _viewport.height) : 0.0;
    if (widget.dismissProgress.value != progress) widget.dismissProgress.value = progress;
    final zoomed = p.scale > 1.02;
    if (zoomed != _zoomed) {
      _zoomed = zoomed;
      widget.onZoomed?.call(zoomed);
      if (!zoomed) {
        _sharpTimer?.cancel();
        _sharpTimer = Timer(photoSharpHold, () {
          if (!_zoomed && mounted) {
            _model.releaseSharp();
            _sharpAsked = false;
          }
        });
      } else {
        _sharpTimer?.cancel();
      }
    }
    if (zoomed && !_sharpAsked) _maybeSharpen(p.scale);
  }

  void _maybeSharpen(double scale) {
    final entry = _model.currentEntry;
    final image = entry.image;
    if (image == null) return;
    final wants = wantsSharper(
      geometry: _geometry(_model.index),
      scale: scale,
      devicePixelRatio: _dpr,
      decodedWidth: image.image.width,
      nativeWidth: image.width,
    );
    if (wants) {
      _sharpAsked = true;
      unawaited(_model.sharpen());
    }
  }

  // -- animation -------------------------------------------------------------

  void _tick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    var done = true;
    for (final track in _tracks) {
      final over = track.sim.isDone(t);
      track.apply(over ? track.end ?? track.sim.x(t) : track.sim.x(t));
      if (!over) done = false;
    }
    if (done) _finishMotion();
  }

  void _run(List<_Track> tracks) {
    _tracks = tracks;
    if (tracks.isEmpty) return;
    if (_reduced) {
      // No travel: land where the springs end.
      for (final t in tracks) {
        t.apply(t.end ?? t.sim.x(60));
      }
      _finishMotion();
      return;
    }
    // Each start() counts its elapsed time from zero.
    if (_ticker.isActive) _ticker.stop();
    _ticker.start();
  }

  void _stopMotion() {
    if (_ticker.isActive) _ticker.stop();
    _tracks = [];
    _leaving = null;
  }

  void _finishMotion() {
    if (_ticker.isActive) _ticker.stop();
    _tracks = [];
    if (_leaving != null) {
      _leaving = null;
      if (mounted) setState(() {});
    }
  }

  _Track _springTrack(double from, double to, double velocity, void Function(double) apply, {
    double ratio = 1,
    Tolerance tolerance = _pixelTolerance,
  }) => _Track(SpringSimulation(_spring(ratio), from, to, velocity, tolerance: tolerance), apply, end: to);

  // -- input -----------------------------------------------------------------

  void _pointerDown(PointerDownEvent e) {
    if (_dismissed) return;
    _pointers.add(e.pointer);
    _downAt ??= e.localPosition;
    _sharpTimer?.cancel();
    // A finger on the picture stops whatever is moving it: the next movement
    // starts from where it is now.
    _stopMotion();
  }

  void _pointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.isNotEmpty) return;
    if (_gesture == null) {
      _downAt = null;
      // A finger that landed and lifted without moving: leave nothing out of
      // bounds (an interrupted rubber band, say).
      _settle(_pose.value, Offset.zero);
      return;
    }
    // The recogniser reports the end of a gesture after this handler, and only
    // if it was still "started": two fingers lifted one after the other
    // without moving in between never report one. Whichever it is, by the end
    // of this event the gesture must be over.
    scheduleMicrotask(() {
      final g = _gesture;
      if (g == null || _pointers.isNotEmpty || !mounted) return;
      _gesture = null;
      _downAt = null;
      _multi = false;
      if (!_dismissed) _release(g, Offset.zero, 0);
    });
  }

  void _onScaleStart(ScaleStartDetails d) {
    if (_dismissed) return;
    _stopMotion();
    final pose = _pose.value;
    final index = _model.index;
    final focal = d.localFocalPoint - _center;
    var mode = _Mode.zoom;
    if (d.pointerCount >= 2) {
      _multi = true;
    } else if (_multi || pose.scale > 1.02) {
      mode = _Mode.pan;
    } else {
      final from = _downAt ?? d.localFocalPoint;
      final moved = d.localFocalPoint - from;
      mode = moved.dy.abs() > moved.dx.abs() ? _Mode.dismiss : _Mode.page;
    }
    _gesture = _Gesture(mode: mode, pose: pose, focal: focal, geometry: _geometry(index), index: index);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final g = _gesture;
    if (g == null || _dismissed) return;
    final focal = d.localFocalPoint - _center;
    final moved = focal - g.focal;
    final start = g.pose;
    final w = _viewport.width;
    final h = _viewport.height;
    var next = _pose.value;
    switch (g.mode) {
      case _Mode.page:
        next = next.copyWith(pageDx: _pageBand(start.pageDx + moved.dx));
      case _Mode.dismiss:
        next = next.copyWith(drag: start.drag + moved);
      case _Mode.pan:
        final limit = g.geometry.panLimit(start.scale);
        final raw = start.offset + moved;
        var dx = raw.dx;
        var page = start.pageDx;
        if (raw.dx > limit.dx) {
          final excess = raw.dx - limit.dx;
          dx = limit.dx;
          page = _pageBand(excess);
        } else if (raw.dx < -limit.dx) {
          final excess = raw.dx + limit.dx;
          dx = -limit.dx;
          page = _pageBand(excess);
        } else {
          page = 0;
        }
        next = next.copyWith(
          offset: Offset(dx, rubberBandedValue(raw.dy, -limit.dy, limit.dy, h * _bandReach)),
          pageDx: page,
        );
      case _Mode.zoom:
        final geo = g.geometry;
        final scale = rubberBandedScale(start.scale * d.scale, 1, geo.maxScale);
        // The point of the picture that was under the fingers when they
        // started stays under them as they move and spread.
        final scene = (g.focal - start.offset) / start.scale;
        final raw = focal - scene * scale;
        final limit = geo.panLimit(scale);
        next = next.copyWith(
          scale: scale,
          offset: Offset(
            rubberBandedValue(raw.dx, -limit.dx, limit.dx, w * _bandReach),
            rubberBandedValue(raw.dy, -limit.dy, limit.dy, h * _bandReach),
          ),
        );
        _detent(g.lastScale, scale, geo.maxScale);
        g.lastScale = scale;
    }
    g.lastFocal = focal;
    _set(next);
  }

  /// Past the first or last photo a drag gives way (rubber band); with a
  /// neighbour the page follows the finger 1:1.
  double _pageBand(double dx) {
    if (dx > 0 && !_model.hasPrevious) return rubberBand(dx, _viewport.width * _bandReach);
    if (dx < 0 && !_model.hasNext) return -rubberBand(-dx, _viewport.width * _bandReach);
    return dx;
  }

  /// A click as the picture reaches fit and as it reaches its largest size.
  void _detent(double from, double to, double max) {
    final crossedFit = (from < 1 && to >= 1) || (from > 1 && to <= 1);
    final reachedMax = from < max && to >= max;
    if (crossedFit || reachedMax) Haptics.tick();
  }

  void _onScaleEnd(ScaleEndDetails d) {
    // A finger lifted but others stay: the next start rebases on the pose.
    if (d.pointerCount > 0) return;
    final g = _gesture;
    _gesture = null;
    _downAt = null;
    _multi = false;
    if (g == null || _dismissed) return;
    _release(g, d.velocity.pixelsPerSecond, d.scaleVelocity);
  }

  void _release(_Gesture g, Offset velocity, double scaleVelocity) {
    var pose = _pose.value;
    final w = _viewport.width;
    final h = _viewport.height;
    var geo = g.geometry;
    var carry = Offset.zero;
    switch (g.mode) {
      case _Mode.dismiss:
        if (shouldDismiss(pose.drag.dy, velocity.dy, h)) {
          _dismiss(pose, velocity);
          return;
        }
        carry = velocity;
      case _Mode.page || _Mode.pan:
        if (pose.pageDx != 0) {
          final dir = pageDecision(pose.pageDx, velocity.dx, w,
              hasPrevious: _model.hasPrevious, hasNext: _model.hasNext);
          if (dir != 0) {
            pose = _flip(dir, pose);
            geo = _geometry(_model.index);
          }
        }
      case _Mode.zoom:
        break;
    }
    _settle(pose, velocity, geometry: geo, focal: g.lastFocal, scaleVelocity: scaleVelocity, carry: carry, mode: g.mode);
  }

  /// Moves to the neighbour in direction [dir] (1 = next) and returns the pose
  /// that keeps the picture where the finger left it: the page that is
  /// leaving slides out in the slot it was in, and the new one springs in.
  PhotoPose _flip(int dir, PhotoPose pose) {
    final leaving = _model.index;
    _model.goTo(leaving + dir);
    _sharpAsked = false;
    _leaving = (index: leaving, pose: pose.copyWith(pageDx: 0));
    setState(() {});
    return PhotoPose(pageDx: pose.pageDx + dir * _pitch);
  }

  /// Springs [pose] to rest: scale inside its bounds, offset inside the
  /// picture, no drag and no sideways pull. [velocity] (the fingers' on
  /// release) is handed to each spring, or to the momentum of a pan.
  void _settle(
    PhotoPose pose,
    Offset velocity, {
    PhotoGeometry? geometry,
    Offset? focal,
    double scaleVelocity = 0,
    Offset carry = Offset.zero,
    _Mode? mode,
  }) {
    final geo = geometry ?? _geometry(_model.index);
    final tracks = <_Track>[];
    final scale = geo.clampScale(pose.scale);
    final target = geo.clampOffset(
      focal == null || scale == pose.scale
          ? pose.offset
          : geo.anchoredOffset(focal: focal, fromScale: pose.scale, fromOffset: pose.offset, toScale: scale),
      scale,
    );
    if (scale != pose.scale) {
      tracks.add(_springTrack(pose.scale, scale, scaleVelocity.isFinite ? scaleVelocity : 0,
          (v) => _set(_pose.value.copyWith(scale: v)),
          tolerance: _scaleTolerance));
    }
    final limit = geo.panLimit(scale);
    final fling = mode == _Mode.pan || mode == _Mode.zoom;
    for (final axis in [Axis.horizontal, Axis.vertical]) {
      final x = axis == Axis.horizontal;
      final from = x ? pose.offset.dx : pose.offset.dy;
      final to = x ? target.dx : target.dy;
      // Past an edge the page takes the sideways velocity, not the picture.
      final v = x ? (pose.pageDx != 0 ? 0.0 : velocity.dx) : velocity.dy;
      final lim = x ? limit.dx : limit.dy;
      void apply(double value) => _set(
        _pose.value.copyWith(
          offset: x ? Offset(value, _pose.value.offset.dy) : Offset(_pose.value.offset.dx, value),
        ),
      );
      if (fling && lim > 0 && scale == pose.scale && v.abs() > 50) {
        tracks.add(_Track(
          BouncingScrollSimulation(
            position: from,
            velocity: v,
            leadingExtent: -lim,
            trailingExtent: lim,
            spring: _spring(0.9),
            tolerance: _pixelTolerance,
          ),
          apply,
        ));
      } else if (from != to) {
        tracks.add(_springTrack(from, to, scale == pose.scale ? v : 0, apply));
      }
    }
    if (pose.drag != Offset.zero) {
      for (final axis in [Axis.horizontal, Axis.vertical]) {
        final x = axis == Axis.horizontal;
        final from = x ? pose.drag.dx : pose.drag.dy;
        if (from == 0) continue;
        final v = x ? carry.dx : carry.dy;
        tracks.add(_springTrack(from, 0, v, (value) => _set(_pose.value.copyWith(
          drag: x ? Offset(value, _pose.value.drag.dy) : Offset(_pose.value.drag.dx, value),
        )), ratio: 0.85));
      }
    }
    if (pose.pageDx != 0) {
      tracks.add(_springTrack(pose.pageDx, 0, velocity.dx, (v) => _set(_pose.value.copyWith(pageDx: v)), ratio: 0.85));
    }
    _set(pose);
    _run(tracks);
  }

  void _dismiss(PhotoPose pose, Offset velocity) {
    _dismissed = true;
    widget.onDismiss();
    if (_reduced) return;
    // The photo keeps going the way it was thrown while the screen fades.
    final away = pose.drag.dy.sign == 0 ? 1.0 : pose.drag.dy.sign;
    _run([
      _springTrack(
        pose.drag.dy,
        pose.drag.dy + away * _viewport.height * 0.35,
        velocity.dy,
        (v) => _set(_pose.value.copyWith(drag: Offset(_pose.value.drag.dx, v))),
        ratio: 1,
      ),
    ]);
  }

  // -- taps ------------------------------------------------------------------

  void _onDoubleTap() {
    if (_dismissed) return;
    final pose = _pose.value;
    final geo = _geometry(_model.index);
    if (geo.maxScale <= 1 && pose.scale <= 1.001) return;
    final focal = _doubleTapAt - _center;
    final target = geo.doubleTapTarget(scale: pose.scale, offset: pose.offset, focal: focal);
    _sharpTimer?.cancel();
    final tracks = <_Track>[
      _springTrack(pose.scale, target.scale, 0, (v) => _set(_pose.value.copyWith(scale: v)), tolerance: _scaleTolerance),
      if (pose.offset.dx != target.offset.dx)
        _springTrack(pose.offset.dx, target.offset.dx, 0,
            (v) => _set(_pose.value.copyWith(offset: Offset(v, _pose.value.offset.dy)))),
      if (pose.offset.dy != target.offset.dy)
        _springTrack(pose.offset.dy, target.offset.dy, 0,
            (v) => _set(_pose.value.copyWith(offset: Offset(_pose.value.offset.dx, v)))),
    ];
    _run(tracks);
  }

  // -- build -----------------------------------------------------------------

  /// Moves the open picture by one place, the way a swipe would (the screen
  /// reader's "scroll" actions).
  void page(int dir) {
    if (dir > 0 ? !_model.hasNext : !_model.hasPrevious) return;
    _stopMotion();
    final pose = _flip(dir, PhotoPose(pageDx: 0));
    _settle(pose, Offset.zero, geometry: _geometry(_model.index));
  }

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        if (size != _viewport) {
          final first = _viewport == Size.zero;
          _viewport = size;
          _model.setViewport(size, _dpr);
          if (!first) {
            // A new shape (rotation, split screen): start again at fit, once
            // this frame is built (the pose drives the build).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _stopMotion();
              _pose.value = PhotoPose.rest;
            });
          }
        }
        return ListenableBuilder(
          listenable: _model,
          builder: (context, _) => RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              ScaleGestureRecognizer: GestureRecognizerFactoryWithHandlers<ScaleGestureRecognizer>(
                () => ScaleGestureRecognizer(),
                (r) => r
                  ..dragStartBehavior = DragStartBehavior.start
                  ..gestureSettings = const DeviceGestureSettings(touchSlop: 6)
                  ..onStart = _onScaleStart
                  ..onUpdate = _onScaleUpdate
                  ..onEnd = _onScaleEnd,
              ),
              // A double tap only means something on a picture that can zoom.
              // Elsewhere (loading, a failure with buttons) its recogniser
              // would hold every tap back for 300 ms waiting for a second one.
              if (_model.count > 0 && _model.currentEntry.ready)
                DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
                  () => DoubleTapGestureRecognizer(),
                  (r) => r
                    ..onDoubleTapDown = ((d) => _doubleTapAt = d.localPosition)
                    ..onDoubleTap = _onDoubleTap,
                ),
              TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(),
                (r) => r.onTap = () {
                  if (!_dismissed) widget.onTap();
                },
              ),
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _pointerDown,
              onPointerUp: _pointerUp,
              onPointerCancel: _pointerUp,
              child: Semantics(
                container: true,
                image: true,
                label: _model.count == 0 ? null : '${_model.positionLabel}, ${_model.current.name}',
                onScrollLeft: _model.hasNext ? () => page(1) : null,
                onScrollRight: _model.hasPrevious ? () => page(-1) : null,
                child: ValueListenableBuilder<PhotoPose>(
                  valueListenable: _pose,
                  builder: (context, pose, _) => _pages(pose),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _pages(PhotoPose pose) {
    final index = _model.index;
    final progress = pose.scale <= 1.001 ? dismissProgress(pose.drag.dy, _viewport.height) : 0.0;
    final children = <Widget>[];
    for (final r in [-1, 0, 1]) {
      final i = index + r;
      final entry = _model.entryAt(i);
      if (entry == null) continue;
      final isOpen = r == 0;
      final leaving = _leaving;
      final shown = isOpen
          ? pose
          : (leaving != null && leaving.index == i ? leaving.pose : PhotoPose.rest);
      final slide = r * _pitch + pose.pageDx;
      if (slide.abs() >= _viewport.width + 1 && !isOpen) continue;
      children.add(
        Positioned.fill(
          key: ValueKey(entry.item.id),
          child: Transform.translate(
            offset: Offset(slide, 0),
            child: PhotoPage(
              entry: entry,
              viewport: _viewport,
              scale: shown.scale,
              offset: shown.offset + shown.drag,
              shrink: isOpen ? 1 - 0.3 * progress : 1,
              failureBuilder: widget.failureBuilder,
            ),
          ),
        ),
      );
    }
    return Stack(clipBehavior: Clip.hardEdge, children: children);
  }
}
