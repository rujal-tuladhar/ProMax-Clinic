import 'dart:math' as math;

import '../models/models.dart';

/// Ramanujan II approximation of an ellipse perimeter with semi-axes
/// [a], [b] (any unit; the result is in the same unit).
///
/// P ≈ π (a+b) (1 + 3h / (10 + sqrt(4 - 3h))) with
/// h = ((a-b)/(a+b))^2. Relative error is below 1e-6 for the mild
/// eccentricities of human torso cross-sections.
///
/// Kept exported for diagnostics and for the rotation engine's ellipse
/// fit; since v2 the circumference itself comes from the ANSUR II linear
/// model in [circumferenceFromWidths], because a pure ellipse under-reads
/// the tape by ≈5 cm at the waist and ≈8 cm at the hip.
double ellipsePerimeter(double a, double b) {
  final sum = a + b;
  if (sum <= 0) return 0;
  final ratio = (a - b) / sum;
  final h = ratio * ratio;
  return math.pi * sum * (1 + 3 * h / (10 + math.sqrt(4 - 3 * h)));
}

/// Per-part multiplicative tape-equivalence corrections applied on top of
/// the breadth/depth model. All 1.0 by default: they are placeholders for
/// the per-part factors the validation study (tape vs app) will produce.
class Calibration {
  /// Multiplicative correction applied to the modelled circumference,
  /// keyed by body part. Parts without an entry use factor 1.0.
  final Map<BodyPart, double> shapeFactor;

  const Calibration(this.shapeFactor);

  /// Default calibration: the linear model already targets the tape, so
  /// every factor is 1.0 until the validation study says otherwise.
  static const Calibration standard = Calibration({
    BodyPart.chest: 1.0,
    BodyPart.waist: 1.0,
    BodyPart.hip: 1.0,
  });

  /// The correction factor for [part] (1.0 when the part has no entry).
  double factorFor(BodyPart part) => shapeFactor[part] ?? 1.0;
}

/// One sex-specific `circ = a + b·breadth + c·depth` regression (cm).
class _LinearModel {
  final double intercept;
  final double breadthCoef;
  final double depthCoef;

  const _LinearModel(this.intercept, this.breadthCoef, this.depthCoef);

  double apply(double breadthCm, double depthCm) =>
      intercept + breadthCoef * breadthCm + depthCoef * depthCm;
}

/// ANSUR II breadth/depth → tape circumference regressions, male.
///
/// Chest caveat: the ANSUR chest breadth is a caliper measurement that
/// compresses soft tissue, whereas a silhouette width is the uncompressed
/// outline, so a silhouette-fed chest tends to read HIGH until the chest
/// factor in [Calibration] is tuned against tape ground truth.
const Map<BodyPart, _LinearModel> _maleModel = {
  BodyPart.chest: _LinearModel(-1.38, 1.548, 2.460),
  BodyPart.waist: _LinearModel(0.94, 1.663, 1.633),
  BodyPart.hip: _LinearModel(5.90, 1.841, 1.318),
};

/// ANSUR II breadth/depth → tape circumference regressions, female.
/// Same chest caveat as [_maleModel].
const Map<BodyPart, _LinearModel> _femaleModel = {
  BodyPart.chest: _LinearModel(5.04, 1.198, 2.320),
  BodyPart.waist: _LinearModel(2.96, 1.776, 1.402),
  BodyPart.hip: _LinearModel(7.43, 1.861, 1.238),
};

/// Combines a front-view full width (breadth, 2a) and a side-view full
/// depth (2b), both in centimetres, into a tape-equivalent circumference
/// for [part] using the ANSUR II linear model
/// `circ = a + b·breadth + c·depth` with per-sex coefficients
/// ([Sex.other] = mean of the male and female predictions), then applies
/// `calibration.factorFor(part)`.
///
/// Only [kTorsoParts] (chest, waist, hip) have a breadth/depth model; any
/// other [part] throws [ArgumentError]. Chest caveat: ANSUR chest breadth is
/// caliper-compressed, so a silhouette-based chest may read high until the
/// chest calibration factor is tuned.
double circumferenceFromWidths({
  required double frontWidthCm,
  required double sideDepthCm,
  required BodyPart part,
  Sex sex = Sex.other,
  Calibration calibration = Calibration.standard,
}) {
  final male = _maleModel[part];
  final female = _femaleModel[part];
  if (male == null || female == null) {
    throw ArgumentError.value(
      part,
      'part',
      'Only torso parts (chest, waist, hip) have a breadth/depth model',
    );
  }
  final value = switch (sex) {
    Sex.male => male.apply(frontWidthCm, sideDepthCm),
    Sex.female => female.apply(frontWidthCm, sideDepthCm),
    Sex.other => (male.apply(frontWidthCm, sideDepthCm) +
            female.apply(frontWidthCm, sideDepthCm)) /
        2,
  };
  return value * calibration.factorFor(part);
}
