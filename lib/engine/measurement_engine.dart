import 'dart:math' as math;

import '../models/models.dart';
import 'body_rows.dart';
import 'circumference.dart';
import 'silhouette.dart';
import 'stats.dart';

/// Thrown by [MeasurementEngine.compute] when the captured frames cannot
/// produce a measurement.
class MeasurementException implements Exception {
  final String message;

  const MeasurementException(this.message);

  @override
  String toString() => 'MeasurementException: $message';
}

/// Per-frame intermediate data used during the pipeline.
class _FrameData {
  final SilhouetteFrame frame;
  final Silhouette silhouette;

  /// cm per IMAGE pixel implied by this frame.
  final double scaleCmPerPx;

  _FrameData(this.frame, this.silhouette, this.scaleCmPerPx);
}

/// Fraction a frame's implied scale may deviate from the median scale
/// before the frame is rejected as an outlier.
const double _maxScaleDeviation = 0.05;

/// The measurement core: combines front + side silhouette bursts into
/// chest/waist/hip circumferences, scaled by the user's entered height.
class MeasurementEngine {
  final Calibration calibration;

  const MeasurementEngine({this.calibration = Calibration.standard});

  /// Computes a [MeasurementResult] from [front] and [side] burst frames
  /// and the user [profile].
  ///
  /// Pipeline per frame: Silhouette(mask) -> cm/px scale =
  /// profile.heightCm / (bodyHeightPx / maskScaleY) [body height converted
  /// to IMAGE pixels] -> rows (fractions derived on front frames) -> torso
  /// widths at the three rows (mask px -> image px via /maskScaleX -> cm
  /// via scale). Frames whose implied scale deviates more than 5% from
  /// the median scale are dropped. Median widths per part per view ->
  /// [circumferenceFromWidths] -> [PartMeasurement] with stdDev propagated
  /// from the frame spread and confidence = agreement score
  /// (1 - clamp(cv*8, 0, 0.8)) * pose likelihood.
  ///
  /// Throws [MeasurementException] when [front] or [side] is empty or no
  /// frame yields usable geometry.
  MeasurementResult compute({
    required List<SilhouetteFrame> front,
    required List<SilhouetteFrame> side,
    required UserProfile profile,
  }) {
    if (front.isEmpty) {
      throw const MeasurementException('No front frames captured');
    }
    if (side.isEmpty) {
      throw const MeasurementException('No side frames captured');
    }
    if (profile.heightCm <= 0) {
      throw const MeasurementException('Profile height must be positive');
    }

    // 1. Per-frame silhouette + implied cm-per-image-pixel scale.
    final frames = <_FrameData>[];
    for (final frame in [...front, ...side]) {
      final sil = Silhouette(frame.mask);
      final bodyHeightMaskPx = sil.bodyHeightPx;
      if (bodyHeightMaskPx == null || bodyHeightMaskPx <= 0) continue;
      final bodyHeightImagePx = bodyHeightMaskPx / frame.maskScaleY;
      frames.add(_FrameData(
        frame,
        sil,
        profile.heightCm / bodyHeightImagePx,
      ));
    }
    if (frames.isEmpty) {
      throw const MeasurementException(
          'No frame contains a usable silhouette');
    }

    // 2. Scale-outlier rejection: a frame whose implied scale disagrees
    // with the burst median by more than 5% caught a different framing
    // (person moved, partial body) and would corrupt the widths.
    final medianScale = median([for (final f in frames) f.scaleCmPerPx]);
    final usable = [
      for (final f in frames)
        if ((f.scaleCmPerPx - medianScale).abs() <=
            _maxScaleDeviation * medianScale)
          f,
    ];
    if (usable.isEmpty) {
      throw const MeasurementException('No frame passed scale validation');
    }

    // 3. Row fractions from the surviving front frames, so front and side
    // views measure the same anatomical levels.
    final fractionSamples = <RowFractions>[];
    for (final f in usable) {
      if (f.frame.view != CaptureView.front) continue;
      final fr = rowFractionsFromFrontFrame(f.frame, f.silhouette);
      if (fr != null) fractionSamples.add(fr);
    }
    final fractions = medianRowFractions(fractionSamples);

    // 4. Torso widths (cm) per part per view.
    final widthsCm = <BodyPart, Map<CaptureView, List<double>>>{
      for (final part in BodyPart.values)
        part: {CaptureView.front: [], CaptureView.side: []},
    };
    final poseLikelihoods = <double>[];
    var usedFront = 0, usedSide = 0;
    for (final f in usable) {
      final rows = rowsForFrame(f.frame, fractions);
      if (rows == null) continue;
      final hipMid = f.frame.pose.mid(Landmark.leftHip, Landmark.rightHip);
      if (hipMid == null) continue;
      final torsoCenterX = f.frame.maskX(hipMid.x);
      var contributed = false;
      for (final (part, rowY) in [
        (BodyPart.chest, rows.chestY),
        (BodyPart.waist, rows.waistY),
        (BodyPart.hip, rows.hipY),
      ]) {
        final span = f.silhouette.torsoSpanAt(rowY.round(), torsoCenterX);
        if (span == null || span.width <= 0) continue;
        // mask px -> image px -> cm.
        final widthImagePx = span.width / f.frame.maskScaleX;
        widthsCm[part]![f.frame.view]!.add(widthImagePx * f.scaleCmPerPx);
        contributed = true;
      }
      if (contributed) {
        if (f.frame.view == CaptureView.front) {
          usedFront++;
        } else {
          usedSide++;
        }
        poseLikelihoods.add(f.frame.pose.minLikelihood(const [
          Landmark.leftShoulder,
          Landmark.rightShoulder,
          Landmark.leftHip,
          Landmark.rightHip,
        ]));
      }
    }

    final poseLikelihood =
        poseLikelihoods.isEmpty ? 0.0 : median(poseLikelihoods);

    // 5. Combine per part: MAD-reject, median widths, propagate spread.
    final parts = <PartMeasurement>[];
    for (final part in BodyPart.values) {
      final frontW = rejectOutliers(widthsCm[part]![CaptureView.front]!);
      final sideW = rejectOutliers(widthsCm[part]![CaptureView.side]!);
      if (frontW.isEmpty || sideW.isEmpty) continue;
      final frontWidth = median(frontW);
      final sideDepth = median(sideW);
      final value = circumferenceFromWidths(
        frontWidthCm: frontWidth,
        sideDepthCm: sideDepth,
        part: part,
        calibration: calibration,
      );
      if (value <= 0) continue;
      final spread = _propagateSpread(
        part: part,
        frontWidth: frontWidth,
        sideDepth: sideDepth,
        frontSd: stdDev(frontW),
        sideSd: stdDev(sideW),
      );
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
          'No frame yields usable torso geometry');
    }

    return MeasurementResult(
      parts: parts,
      scaleCmPerPx: median([for (final f in usable) f.scaleCmPerPx]),
      frontFrameCount: usedFront,
      sideFrameCount: usedSide,
      timestamp: DateTime.now(),
    );
  }

  /// First-order propagation of the per-view width spreads into a
  /// circumference spread, via central differences of the (nonlinear)
  /// ellipse-perimeter map. The two views are captured independently, so
  /// their contributions add in quadrature.
  double _propagateSpread({
    required BodyPart part,
    required double frontWidth,
    required double sideDepth,
    required double frontSd,
    required double sideSd,
  }) {
    double c(double f, double s) => circumferenceFromWidths(
          frontWidthCm: f,
          sideDepthCm: s,
          part: part,
          calibration: calibration,
        );
    final dFront = frontSd == 0
        ? 0.0
        : (c(frontWidth + frontSd, sideDepth) -
                c(frontWidth - frontSd, sideDepth)) /
            2;
    final dSide = sideSd == 0
        ? 0.0
        : (c(frontWidth, sideDepth + sideSd) -
                c(frontWidth, sideDepth - sideSd)) /
            2;
    return math.sqrt(dFront * dFront + dSide * dSide);
  }
}
