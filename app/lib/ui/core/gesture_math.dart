/// Arithmetic shared by the gestures (a sheet, a swiped row, the photo viewer),
/// free of widgets so it can be tested on its own.
library;

/// A boundary that gives way instead of stopping: the further past the edge a
/// drag goes ([overshoot], at least 0), the less the content follows: it starts
/// at [constant] of the finger's speed and never moves more than [dimension].
/// Apple's rubber-banding function; callers pass how far a boundary may be
/// stretched as [dimension]. A hard stop feels like hitting a wall; the
/// resistance says "nothing further" without one.
double rubberBand(double overshoot, double dimension, {double constant = 0.55}) {
  if (overshoot <= 0 || dimension <= 0) return 0;
  return (overshoot * dimension * constant) / (dimension + constant * overshoot);
}
