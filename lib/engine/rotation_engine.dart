import 'dart:math' as math;

import '../models/models.dart';
import 'body_rows.dart';
import 'circumference.dart';
import 'measurement_engine.dart' show MeasurementException;
import 'silhouette.dart';
import 'stats.dart';

/// The rotation ("precision turn") measurement core.
///
/// Instead of two orthogonal views, the subject makes a slow full turn in
/// front of the propped phone and a still is captured at each instructed
/// stop. The projected torso width of a (near-)elliptic cross-section seen
/// at body yaw theta is
///
///   w(theta) = 2 * sqrt(a^2 cos^2(theta + phi) + b^2 sin^2(theta + phi))
///
/// so the many (theta, width) samples overdetermine the ellipse semi-axes
/// a (lateral) and b (sagittal). Fitting them per body part averages noise
/// across every view, tolerates the subject not starting perfectly square
/// to the camera (the phase term phi), and lets arm-contaminated views be
/// trimmed as outliers — the per-subject cross-section-fit approach used by
/// the best-validated commercial rotation systems.

/// One captured still of the guided turn.
class RotationFrame {
  final SilhouetteFrame frame;

  /// Instructed body yaw in degrees: 0 = facing the camera, increasing as
  /// the subject turns. The width function has a 180° period, so a full
  /// turn samples each unique angle twice.
  final double angleDegrees;

  const RotationFrame({required this.frame, required this.angleDegrees});
}

/// Result of fitting ellipse semi-axes to multi-angle width samples.
class EllipseFit {
  /// Lateral semi-axis in cm (half the width seen face-on at phase 0).
  final double aCm;

  /// Sagittal (depth) semi-axis in cm.
  final double bCm;

  /// Start-angle correction found by the fit, degrees.
  final double phaseDegrees;

  /// Root-mean-square width residual of the kept samples, cm.
  final double rmseCm;

  /// Samples kept after outlier trimming.
  final int sampleCount;

  const EllipseFit({
    required this.aCm,
    required this.bCm,
    required this.phaseDegrees,
    required this.rmseCm,
    required this.sampleCount,
  });
}

/// Minimum samples for a meaningful fit (2 unknowns + phase + redundancy).
const int _minSamples = 5;

/// Phase search grid: the subject's "facing the camera" is only accurate to
/// a couple of clock positions, not degrees.
const double _phaseRangeDeg = 25;
const double _phaseStepDeg = 2.5;

/// Fraction of the worst-residual samples dropped before the final refit
/// (arm-contaminated oblique views inflate single widths).
const double _trimFraction = 0.2;

/// Fits ellipse semi-axes to (angleDegrees, widthCm) samples.
///
/// For each candidate phase, (w/2)^2 = u cos^2 + v sin^2 is LINEAR in
/// u = a^2, v = b^2, so each phase is a closed-form 2x2 least squares; the
/// best-SSE phase wins, then the worst [_trimFraction] of residuals are
/// dropped and the fit repeats. Returns null when there are fewer than
/// [_minSamples] samples, the angles lack diversity, or the fit collapses
/// (non-positive axes).
EllipseFit? fitEllipseWidths(List<(double, double)> samples) {
  if (samples.length < _minSamples) return null;

  var kept = List.of(samples);
  ({double u, double v, double phase, double sse})? best;
  for (var pass = 0; pass < 2; pass++) {
    best = null;
    for (var phase = -_phaseRangeDeg;
        phase <= _phaseRangeDeg + 1e-9;
        phase += _phaseStepDeg) {
      final fit = _linearFit(kept, phase);
      if (fit == null) continue;
      if (best == null || fit.sse < best.sse) best = fit;
    }
    if (best == null) return null;
    if (pass == 1 || kept.length <= _minSamples) break;

    // Trim the worst residuals and refit once.
    final b = best;
    final withResiduals = [
      for (final s in kept) (s, (_widthAt(b.u, b.v, b.phase, s.$1) - s.$2).abs())
    ]..sort((x, y) => x.$2.compareTo(y.$2));
    final keepCount =
        math.max(_minSamples, (kept.length * (1 - _trimFraction)).ceil());
    kept = [for (final (s, _) in withResiduals.take(keepCount)) s];
  }

  final b = best!;
  final a = math.sqrt(b.u);
  final bb = math.sqrt(b.v);
  var sq = 0.0;
  for (final s in kept) {
    final r = _widthAt(b.u, b.v, b.phase, s.$1) - s.$2;
    sq += r * r;
  }
  return EllipseFit(
    aCm: a,
    bCm: bb,
    phaseDegrees: b.phase,
    rmseCm: math.sqrt(sq / kept.length),
    sampleCount: kept.length,
  );
}

double _widthAt(double u, double v, double phaseDeg, double angleDeg) {
  final t = (angleDeg + phaseDeg) * math.pi / 180;
  final c = math.cos(t), s = math.sin(t);
  return 2 * math.sqrt(u * c * c + v * s * s);
}

({double u, double v, double phase, double sse})? _linearFit(
  List<(double, double)> samples,
  double phaseDeg,
) {
  var scc = 0.0, sss = 0.0, scs = 0.0, scy = 0.0, ssy = 0.0;
  for (final (angleDeg, widthCm) in samples) {
    final t = (angleDeg + phaseDeg) * math.pi / 180;
    final c2 = math.pow(math.cos(t), 2).toDouble();
    final s2 = math.pow(math.sin(t), 2).toDouble();
    final y = math.pow(widthCm / 2, 2).toDouble();
    scc += c2 * c2;
    sss += s2 * s2;
    scs += c2 * s2;
    scy += c2 * y;
    ssy += s2 * y;
  }
  final det = scc * sss - scs * scs;
  // Degenerate when every sample sees (near-)the same angle mod 180°.
  if (det.abs() < 1e-9 * (scc * sss + 1e-12)) return null;
  final u = (scy * sss - ssy * scs) / det;
  final v = (ssy * scc - scy * scs) / det;
  if (u <= 0 || v <= 0) return null;
  var sse = 0.0;
  for (final (angleDeg, widthCm) in samples) {
    final r = _widthAt(u, v, phaseDeg, angleDeg) - widthCm;
    sse += r * r;
  }
  return (u: u, v: v, phase: phaseDeg, sse: sse);
}

/// Fraction a frame's implied scale may deviate from the median before the
/// frame is dropped (same rule as the two-view engine).
const double _maxScaleDeviation = 0.05;

/// A view counts as frontal (usable for row-fraction derivation) when the
/// instructed yaw is within this many degrees of 0 or 180.
const double _frontalToleranceDeg = 20;

/// Measurement engine for the guided-turn capture mode.
class RotationMeasurementEngine {
  final Calibration calibration;

  const RotationMeasurementEngine({this.calibration = Calibration.standard});

  /// Computes chest/waist/hip from the turn stills.
  ///
  /// Per frame: silhouette -> implied cm/px scale from the profile height
  /// (5% scale-outlier rejection) -> rows located by fractions derived on
  /// the frontal-most frames -> torso width at each row. Per part, the
  /// (angle, width) samples feed [fitEllipseWidths]; the fitted ellipse
  /// perimeter (Ramanujan II x per-part calibration) is the circumference.
  ///
  /// Throws [MeasurementException] when no usable geometry survives.
  MeasurementResult compute({
    required List<RotationFrame> frames,
    required UserProfile profile,
  }) {
    if (frames.isEmpty) {
      throw const MeasurementException('No turn frames captured');
    }
    if (profile.heightCm <= 0) {
      throw const MeasurementException('Profile height must be positive');
    }

    // 1. Silhouette + per-frame scale.
    final data = <(RotationFrame, Silhouette, double)>[];
    for (final rf in frames) {
      final sil = Silhouette(rf.frame.mask);
      final bodyHeightMaskPx = sil.bodyHeightPx;
      if (bodyHeightMaskPx == null || bodyHeightMaskPx <= 0) continue;
      final bodyHeightImagePx = bodyHeightMaskPx / rf.frame.maskScaleY;
      data.add((rf, sil, profile.heightCm / bodyHeightImagePx));
    }
    if (data.isEmpty) {
      throw const MeasurementException('No frame contains a usable silhouette');
    }

    // 2. Scale-outlier rejection.
    final medianScale = median([for (final d in data) d.$3]);
    final usable = [
      for (final d in data)
        if ((d.$3 - medianScale).abs() <= _maxScaleDeviation * medianScale) d,
    ];
    if (usable.isEmpty) {
      throw const MeasurementException('No frame passed scale validation');
    }

    // 3. Row fractions from the frontal-most views so every view measures
    // the same anatomical levels.
    final fractionSamples = <RowFractions>[];
    for (final (rf, sil, _) in usable) {
      final yaw = rf.angleDegrees % 180;
      final offFrontal = math.min(yaw, 180 - yaw);
      if (offFrontal > _frontalToleranceDeg) continue;
      final fr = rowFractionsFromFrontFrame(rf.frame, sil);
      if (fr != null) fractionSamples.add(fr);
    }
    final fractions = medianRowFractions(fractionSamples);

    // 4. (angle, width) samples per part.
    final samples = <BodyPart, List<(double, double)>>{
      for (final part in BodyPart.values) part: [],
    };
    final poseLikelihoods = <double>[];
    var usedFrames = 0;
    for (final (rf, sil, scale) in usable) {
      final rows = rowsForFrame(rf.frame, fractions);
      if (rows == null) continue;
      final hipMid = rf.frame.pose.mid(Landmark.leftHip, Landmark.rightHip);
      if (hipMid == null) continue;
      final torsoCenterX = rf.frame.maskX(hipMid.x);
      var contributed = false;
      for (final (part, rowY) in [
        (BodyPart.chest, rows.chestY),
        (BodyPart.waist, rows.waistY),
        (BodyPart.hip, rows.hipY),
      ]) {
        final span = sil.torsoSpanAt(rowY.round(), torsoCenterX);
        if (span == null || span.width <= 0) continue;
        final widthCm = span.width / rf.frame.maskScaleX * scale;
        samples[part]!.add((rf.angleDegrees, widthCm));
        contributed = true;
      }
      if (contributed) {
        usedFrames++;
        poseLikelihoods.add(rf.frame.pose.minLikelihood(const [
          Landmark.leftShoulder,
          Landmark.rightShoulder,
          Landmark.leftHip,
          Landmark.rightHip,
        ]));
      }
    }

    final poseLikelihood =
        poseLikelihoods.isEmpty ? 0.0 : median(poseLikelihoods);

    // 5. Ellipse fit per part.
    final parts = <PartMeasurement>[];
    for (final part in BodyPart.values) {
      final fit = fitEllipseWidths(samples[part]!);
      if (fit == null) continue;
      final value =
          ellipsePerimeter(fit.aCm, fit.bCm) * calibration.factorFor(part);
      if (value <= 0) continue;
      // First-order spread: a width error dw moves a circle's perimeter by
      // pi*dw; the fit averages sampleCount views.
      final spread = math.pi * fit.rmseCm / math.sqrt(fit.sampleCount);
      final cv = spread / value;
      final agreement = 1 - (cv * 8).clamp(0.0, 0.8).toDouble();
      parts.add(PartMeasurement(
        part: part,
        valueCm: value,
        stdDevCm: spread,
        confidence: (agreement * poseLikelihood).clamp(0.0, 1.0).toDouble(),
      ));
    }
    if (parts.isEmpty) {
      throw const MeasurementException(
          'Not enough angle coverage for a turn measurement');
    }

    return MeasurementResult(
      parts: parts,
      scaleCmPerPx: median([for (final d in usable) d.$3]),
      frontFrameCount: usedFrames,
      sideFrameCount: 0,
      timestamp: DateTime.now(),
    );
  }
}
