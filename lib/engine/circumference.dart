import 'dart:math' as math;

import '../models/models.dart';

/// Ramanujan II approximation of an ellipse perimeter with semi-axes
/// [a], [b] (any unit; the result is in the same unit).
///
/// P ≈ π (a+b) (1 + 3h / (10 + sqrt(4 - 3h))) with
/// h = ((a-b)/(a+b))^2. Relative error is below 1e-6 for the mild
/// eccentricities of human torso cross-sections.
double ellipsePerimeter(double a, double b) {
  final sum = a + b;
  if (sum <= 0) return 0;
  final ratio = (a - b) / sum;
  final h = ratio * ratio;
  return math.pi * sum * (1 + 3 * h / (10 + math.sqrt(4 - 3 * h)));
}

/// Per-part multiplicative shape corrections (body cross-sections are not
/// true ellipses). Defaults are literature-informed starting points and are
/// expected to be tuned against tape-measure ground truth.
class Calibration {
  /// Multiplicative correction applied to the elliptical perimeter,
  /// keyed by body part. Parts without an entry use factor 1.0.
  final Map<BodyPart, double> shapeFactor;

  const Calibration(this.shapeFactor);

  /// Default calibration: chest cross-sections are slightly flatter than
  /// an ellipse (ribcage), waists are close to elliptic, hips slightly
  /// fuller (gluteal curvature extends beyond the fitted ellipse).
  static const Calibration standard = Calibration({
    BodyPart.chest: 0.97,
    BodyPart.waist: 0.99,
    BodyPart.hip: 1.01,
  });

  /// The correction factor for [part] (1.0 when the part has no entry).
  double factorFor(BodyPart part) => shapeFactor[part] ?? 1.0;
}

/// Combines a front-view full width (2a) and a side-view full depth (2b),
/// both in centimetres, into a circumference estimate for [part].
///
/// Returns ellipsePerimeter(a, b) * calibration.factorFor(part).
double circumferenceFromWidths({
  required double frontWidthCm,
  required double sideDepthCm,
  required BodyPart part,
  Calibration calibration = Calibration.standard,
}) {
  final a = frontWidthCm / 2;
  final b = sideDepthCm / 2;
  return ellipsePerimeter(a, b) * calibration.factorFor(part);
}
