import 'dart:math' as math;

import '../models/models.dart';
import 'silhouette.dart';

/// Per-frame estimators for the v2 "extra" parts: inseam, sleeve, shoulder
/// width, plus the regression-derived neck and thigh. Pure Dart; every
/// function here works on ONE frame (or on scalar inputs) and returns null
/// when the frame cannot support the estimate — the engines aggregate
/// across frames and simply omit parts that have no estimate.

/// Minimum landmark likelihood for a landmark to be used.
const double _minLikelihood = 0.5;

/// Inseam fallback: the crotch sits this fraction of standing height below
/// the hip landmark row (ANSUR II crotch height vs trochanterion).
const double _crotchBelowHipMale = 0.0313;
const double _crotchBelowHipFemale = 0.0388;

/// Inseam sanity band as a fraction of standing height.
const double _inseamMinFraction = 0.42;
const double _inseamMaxFraction = 0.54;

/// Outseam = [_sleeveSlope]·(upper + forearm) − [_sleeveOffsetCm]: joint
/// centres sit inside the limb, so the landmark chain is scaled and shifted
/// onto the acromion → stylion tape path.
const double _sleeveSlope = 0.983;
const double _sleeveOffsetCm = 1.5;

/// A straight arm has an elbow angle of at least this many degrees.
const double _minElbowAngleDeg = 150;

/// Landmark shoulder distance → biacromial breadth.
const double _biacromialFactor = 1.15;

/// Shoulder sanity band as a fraction of standing height.
const double _shoulderMinFraction = 0.19;
const double _shoulderMaxFraction = 0.28;

/// Biacromial fallback (fraction of height) when the shoulders are not
/// measurable, used only inside the shirt-sleeve regression.
const double _biacromialFallbackFraction = 0.23;

PosePoint? _trusted(BodyPose pose, Landmark l) {
  final p = pose[l];
  if (p == null || p.likelihood < _minLikelihood) return null;
  return p;
}

double _distance(PosePoint a, PosePoint b) {
  final dx = a.x - b.x, dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}

/// Mean of the male and female values for [Sex.other].
double _bySex(Sex sex, double male, double female) => switch (sex) {
      Sex.male => male,
      Sex.female => female,
      Sex.other => (male + female) / 2,
    };

/// Inseam (crotch → floor) in cm, or null when it cannot be estimated.
///
/// Preferred: silhouette crotch — scan mask rows upward from the ankle rows
/// within the column band between the two ankle landmarks (mask coords);
/// the crotch row is the first row (from below) where the two leg runs
/// merge into one run. Floor row = [Silhouette.bottomY].
///
/// Fallback (legs not separable, or ankles untracked): the crotch is k·H
/// below the hip-landmark row, k = 0.0313 (male) / 0.0388 (female) / mean
/// (other), H = profile.heightCm.
///
/// Returns null unless 0.42·H ≤ inseam ≤ 0.54·H.
double? estimateInseamCm(
  SilhouetteFrame frame,
  Silhouette sil,
  double scaleCmPerImagePx,
  UserProfile profile,
) {
  final bottomMaskY = sil.bottomY;
  if (bottomMaskY == null || scaleCmPerImagePx <= 0) return null;
  final heightCm = profile.heightCm;
  if (heightCm <= 0) return null;
  final maskScaleY = frame.maskScaleY;
  if (maskScaleY <= 0) return null;

  double? inseam;
  final crotchRow = _crotchRow(frame, sil, bottomMaskY);
  if (crotchRow != null) {
    final legMaskPx = bottomMaskY - crotchRow;
    inseam = legMaskPx / maskScaleY * scaleCmPerImagePx;
  } else {
    final hipMid = frame.pose.mid(Landmark.leftHip, Landmark.rightHip);
    if (hipMid == null || hipMid.likelihood < _minLikelihood) return null;
    final floorImageY = bottomMaskY / maskScaleY;
    final hipToFloorCm = (floorImageY - hipMid.y) * scaleCmPerImagePx;
    final k = _bySex(profile.sex, _crotchBelowHipMale, _crotchBelowHipFemale);
    inseam = hipToFloorCm - k * heightCm;
  }

  if (inseam < _inseamMinFraction * heightCm ||
      inseam > _inseamMaxFraction * heightCm) {
    return null;
  }
  return inseam;
}

/// The crotch row (mask coords) found by the two-legs-merge scan, or null
/// when the legs are not separable in this frame.
double? _crotchRow(SilhouetteFrame frame, Silhouette sil, double bottomMaskY) {
  final la = _trusted(frame.pose, Landmark.leftAnkle);
  final ra = _trusted(frame.pose, Landmark.rightAnkle);
  if (la == null || ra == null) return null;
  final hipMid = frame.pose.mid(Landmark.leftHip, Landmark.rightHip);

  final xLo = math.min(frame.maskX(la.x), frame.maskX(ra.x));
  final xHi = math.max(frame.maskX(la.x), frame.maskX(ra.x));
  if (xHi - xLo < 1) return null; // ankles superimposed: no gap to find
  final xMid = (xLo + xHi) / 2;

  // Scan upward from the ankle row (never below the silhouette) to the hip
  // landmark row (or the top of the body when hips are unknown).
  final ankleMaskY = math.max(frame.maskY(la.y), frame.maskY(ra.y));
  final startRow = math.min(ankleMaskY, bottomMaskY).floor();
  final endRow = hipMid == null
      ? (sil.topY ?? 0).floor()
      : frame.maskY(hipMid.y).floor();
  if (startRow < 0 || startRow >= sil.height) return null;

  var seenSeparated = false;
  for (var y = startRow; y >= math.max(endRow, 0); y--) {
    final runs = sil.runsAt(y);
    var overlapping = 0;
    RowSpan? single;
    for (final run in runs) {
      if (run.right >= xLo && run.left <= xHi) {
        overlapping++;
        single = run;
      }
    }
    if (overlapping >= 2) {
      seenSeparated = true;
    } else if (overlapping == 1 &&
        seenSeparated &&
        single!.left <= xMid &&
        single.right >= xMid) {
      return y.toDouble();
    }
  }
  return null;
}

/// Interior angle at [elbow] (degrees, 0..180) between the upper arm and
/// the forearm, or null when a segment has zero length.
double? _elbowAngleDeg(PosePoint shoulder, PosePoint elbow, PosePoint wrist) {
  final ux = shoulder.x - elbow.x, uy = shoulder.y - elbow.y;
  final vx = wrist.x - elbow.x, vy = wrist.y - elbow.y;
  final lu = math.sqrt(ux * ux + uy * uy);
  final lv = math.sqrt(vx * vx + vy * vy);
  if (lu == 0 || lv == 0) return null;
  final cos = ((ux * vx + uy * vy) / (lu * lv)).clamp(-1.0, 1.0);
  return math.acos(cos) * 180 / math.pi;
}

/// Sleeve lengths from the landmark chain shoulder→elbow→wrist of each arm.
///
/// outseam = 0.983·(upper + fore) − 1.5 cm (joint-centre → acromion/stylion
/// correction). An arm is used only when shoulder/elbow/wrist likelihood
/// ≥ 0.5 and the elbow angle ≥ 150°; the usable arms are averaged. Returns
/// null when no arm is usable.
///
/// shirtSleeve (centre back → wrist) = 5.6 + 0.795·biacromial + 0.858·outseam
/// (male) / 6.2 + 0.662·biacromial + 0.925·outseam (female) / mean, with
/// biacromial from [estimateShoulderWidthCm] (fallback 0.23·H).
({double outseamCm, double shirtSleeveCm})? estimateSleeveCm(
  BodyPose pose,
  double scaleCmPerImagePx,
  UserProfile profile,
) {
  if (scaleCmPerImagePx <= 0) return null;
  final outseams = <double>[];
  for (final (s, e, w) in const [
    (Landmark.leftShoulder, Landmark.leftElbow, Landmark.leftWrist),
    (Landmark.rightShoulder, Landmark.rightElbow, Landmark.rightWrist),
  ]) {
    final shoulder = _trusted(pose, s);
    final elbow = _trusted(pose, e);
    final wrist = _trusted(pose, w);
    if (shoulder == null || elbow == null || wrist == null) continue;
    final angle = _elbowAngleDeg(shoulder, elbow, wrist);
    if (angle == null || angle < _minElbowAngleDeg) continue;
    final chainCm =
        (_distance(shoulder, elbow) + _distance(elbow, wrist)) *
            scaleCmPerImagePx;
    outseams.add(_sleeveSlope * chainCm - _sleeveOffsetCm);
  }
  if (outseams.isEmpty) return null;
  final outseam = outseams.reduce((a, b) => a + b) / outseams.length;
  if (outseam <= 0) return null;

  final biacromial = estimateShoulderWidthCm(pose, scaleCmPerImagePx, profile) ??
      _biacromialFallbackFraction * profile.heightCm;
  final shirtSleeve = _bySex(
    profile.sex,
    5.6 + 0.795 * biacromial + 0.858 * outseam,
    6.2 + 0.662 * biacromial + 0.925 * outseam,
  );
  return (outseamCm: outseam, shirtSleeveCm: shirtSleeve);
}

/// Biacromial shoulder width = 1.15 × landmark shoulder distance (cm).
/// Null when a shoulder is untracked or the result is outside
/// 0.19·H..0.28·H.
double? estimateShoulderWidthCm(
  BodyPose pose,
  double scaleCmPerImagePx,
  UserProfile profile,
) {
  if (scaleCmPerImagePx <= 0) return null;
  final ls = _trusted(pose, Landmark.leftShoulder);
  final rs = _trusted(pose, Landmark.rightShoulder);
  if (ls == null || rs == null) return null;
  final width = _biacromialFactor * _distance(ls, rs) * scaleCmPerImagePx;
  final h = profile.heightCm;
  if (width < _shoulderMinFraction * h || width > _shoulderMaxFraction * h) {
    return null;
  }
  return width;
}

/// Neck circumference regressed from chest circumference (cm):
/// 15.0 + 0.234·chest (male) / 16.9 + 0.169·chest (female) / mean (other).
double estimateNeckCm(double chestCm, Sex sex) =>
    _bySex(sex, 15.0 + 0.234 * chestCm, 16.9 + 0.169 * chestCm);

/// Thigh circumference regressed from hip circumference (cm):
/// −10.8 + 0.719·hip (male) / −8.9 + 0.691·hip (female) / mean (other).
double estimateThighCm(double hipCm, Sex sex) =>
    _bySex(sex, -10.8 + 0.719 * hipCm, -8.9 + 0.691 * hipCm);
