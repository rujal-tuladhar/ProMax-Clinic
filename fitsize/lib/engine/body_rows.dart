import '../models/models.dart';
import 'silhouette.dart';

/// Vertical positions (mask row coordinates) of the measurement rows.
class BodyRows {
  final double chestY;
  final double waistY;
  final double hipY;

  const BodyRows({
    required this.chestY,
    required this.waistY,
    required this.hipY,
  });
}

/// Fractions of the shoulder→hip-joint span locating each row; computed on
/// front frames, reused on side frames so both views measure the same
/// anatomical level.
class RowFractions {
  /// Chest row fraction (fixed anatomical prior).
  final double chest; // default 0.22

  /// Waist row fraction, found by narrowest-width search.
  final double waist; // default 0.72

  /// Hip row fraction, found by widest-width search below the hip joints,
  /// expressed as a fraction > 1 of the span.
  final double hip; // default 1.15

  const RowFractions({
    required this.chest,
    required this.waist,
    required this.hip,
  });

  /// Anatomical-prior fallback used when no front frame yields fractions.
  static const RowFractions defaults =
      RowFractions(chest: 0.22, waist: 0.72, hip: 1.15);
}

/// Fixed chest fraction of the shoulder→hip span.
const double _chestFraction = 0.22;

/// Shoulder mid-point and hip mid-point of [frame]'s pose projected into
/// mask coordinates, or null when either is missing.
({double shoulderY, double hipY, double hipX})? _torsoAnchors(
    SilhouetteFrame frame) {
  final shoulderMid = frame.pose.mid(Landmark.leftShoulder, Landmark.rightShoulder);
  final hipMid = frame.pose.mid(Landmark.leftHip, Landmark.rightHip);
  if (shoulderMid == null || hipMid == null) return null;
  return (
    shoulderY: frame.maskY(shoulderMid.y),
    hipY: frame.maskY(hipMid.y),
    hipX: frame.maskX(hipMid.x),
  );
}

/// Scans integer mask rows in [yMin, yMax] and returns the row with the
/// extreme torso-run width (minimum when [findMin], else maximum), or null
/// when no row in the band has a torso run.
double? _extremeWidthRow(
  Silhouette sil,
  double yMin,
  double yMax,
  double torsoCenterX, {
  required bool findMin,
}) {
  int? bestRow;
  double? bestWidth;
  final first = yMin.ceil();
  final last = yMax.floor();
  for (var y = first; y <= last; y++) {
    if (y < 0 || y >= sil.height) continue;
    final span = sil.torsoSpanAt(y, torsoCenterX);
    if (span == null) continue;
    final w = span.width;
    if (bestWidth == null || (findMin ? w < bestWidth : w > bestWidth)) {
      bestWidth = w;
      bestRow = y;
    }
  }
  return bestRow?.toDouble();
}

/// Derives row fractions from ONE front frame.
///
/// - shoulderY = mid(leftShoulder, rightShoulder).y and hipY = mid hips,
///   both projected to mask coordinates; span = hipJointY - shoulderY
///   (must be > 0).
/// - chest fraction is fixed at 0.22.
/// - waist: scans integer rows in the band
///   [shoulderY + 0.50*span, hipJointY - 0.02*span] and picks the row with
///   MINIMUM torso-run width (torsoCenterX = mid-hip x in mask coords);
///   fraction = (rowY - shoulderY) / span.
/// - hip: scans the band [hipJointY, hipJointY + 0.45*span] and picks the
///   MAXIMUM torso width; fraction = (rowY - shoulderY) / span.
///
/// Falls back to [RowFractions.defaults] values for a band in which no
/// torso run exists. Returns null when shoulders/hips are missing or the
/// span is degenerate.
RowFractions? rowFractionsFromFrontFrame(
    SilhouetteFrame frame, Silhouette sil) {
  final anchors = _torsoAnchors(frame);
  if (anchors == null) return null;
  final shoulderY = anchors.shoulderY;
  final hipJointY = anchors.hipY;
  final span = hipJointY - shoulderY;
  if (span <= 0) return null;

  final cx = anchors.hipX;

  final waistRow = _extremeWidthRow(
    sil,
    shoulderY + 0.50 * span,
    hipJointY - 0.02 * span,
    cx,
    findMin: true,
  );
  final hipRow = _extremeWidthRow(
    sil,
    hipJointY,
    hipJointY + 0.45 * span,
    cx,
    findMin: false,
  );

  return RowFractions(
    chest: _chestFraction,
    waist: waistRow == null
        ? RowFractions.defaults.waist
        : (waistRow - shoulderY) / span,
    hip: hipRow == null
        ? RowFractions.defaults.hip
        : (hipRow - shoulderY) / span,
  );
}

/// Median-combines fractions from several front frames; returns
/// [RowFractions.defaults] when the list is empty.
RowFractions medianRowFractions(List<RowFractions> fractions) {
  if (fractions.isEmpty) return RowFractions.defaults;
  double medianOf(double Function(RowFractions) pick) {
    final xs = [for (final f in fractions) pick(f)]..sort();
    final n = xs.length;
    final mid = n ~/ 2;
    return n.isOdd ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2;
  }

  return RowFractions(
    chest: medianOf((f) => f.chest),
    waist: medianOf((f) => f.waist),
    hip: medianOf((f) => f.hip),
  );
}

/// Applies [fractions] to any frame (front or side) using its own
/// landmarks: rowY = shoulderY + fraction * (hipJointY - shoulderY), in
/// mask coordinates. Null when landmarks are missing or the span is
/// degenerate.
BodyRows? rowsForFrame(SilhouetteFrame frame, RowFractions fractions) {
  final anchors = _torsoAnchors(frame);
  if (anchors == null) return null;
  final span = anchors.hipY - anchors.shoulderY;
  if (span <= 0) return null;
  double rowAt(double fraction) => anchors.shoulderY + fraction * span;
  return BodyRows(
    chestY: rowAt(fractions.chest),
    waistY: rowAt(fractions.waist),
    hipY: rowAt(fractions.hip),
  );
}
