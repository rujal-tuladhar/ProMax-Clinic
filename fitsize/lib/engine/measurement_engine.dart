import 'dart:math' as math;

import '../models/models.dart';
import 'body_rows.dart';
import 'circumference.dart';
import 'extra_measurements.dart';
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

/// Confidence multiplier for parts derived by regression from another
/// measured part (neck from chest, thigh from hip).
const double _derivedConfidenceFactor = 0.6;

/// A frontal frame prepared for the length estimators: its silhouette and
/// the cm-per-IMAGE-pixel scale the engine validated for it.
typedef FrontFrameInput = ({
  SilhouetteFrame frame,
  Silhouette silhouette,
  double scaleCmPerPx,
});

/// Frame-agreement score shared by every part:
/// 1 - clamp(cv * 8, 0, 0.8) with cv = spread / value.
double agreementScore(double spreadCm, double valueCm) {
  if (valueCm <= 0) return 0;
  final cv = spreadCm / valueCm;
  return 1 - (cv * 8).clamp(0.0, 0.8).toDouble();
}

/// First-order propagation of per-view width spreads into a circumference
/// spread, via central differences of [circumferenceFromWidths]. The two
/// axes are measured independently, so their contributions add in
/// quadrature.
double propagateCircumferenceSpread({
  required BodyPart part,
  required Sex sex,
  required Calibration calibration,
  required double frontWidthCm,
  required double sideDepthCm,
  required double frontSdCm,
  required double sideSdCm,
}) {
  double c(double f, double s) => circumferenceFromWidths(
        frontWidthCm: f,
        sideDepthCm: s,
        part: part,
        sex: sex,
        calibration: calibration,
      );
  final dFront = frontSdCm == 0
      ? 0.0
      : (c(frontWidthCm + frontSdCm, sideDepthCm) -
              c(frontWidthCm - frontSdCm, sideDepthCm)) /
          2;
  final dSide = sideSdCm == 0
      ? 0.0
      : (c(frontWidthCm, sideDepthCm + sideSdCm) -
              c(frontWidthCm, sideDepthCm - sideSdCm)) /
          2;
  return math.sqrt(dFront * dFront + dSide * dSide);
}

/// Likelihood of the landmarks the inseam estimate rests on: hips always,
/// ankles when both are tracked (they bound the crotch search).
double _inseamLikelihood(BodyPose pose) {
  var l = pose.minLikelihood(const [Landmark.leftHip, Landmark.rightHip]);
  final la = pose[Landmark.leftAnkle], ra = pose[Landmark.rightAnkle];
  if (la != null && ra != null) {
    l = math.min(l, math.min(la.likelihood, ra.likelihood));
  }
  return l;
}

/// Best usable-arm likelihood for the sleeve chain.
double _sleeveLikelihood(BodyPose pose) => math.max(
      pose.minLikelihood(const [
        Landmark.leftShoulder,
        Landmark.leftElbow,
        Landmark.leftWrist,
      ]),
      pose.minLikelihood(const [
        Landmark.rightShoulder,
        Landmark.rightElbow,
        Landmark.rightWrist,
      ]),
    );

double _shoulderLikelihood(BodyPose pose) => pose.minLikelihood(
    const [Landmark.leftShoulder, Landmark.rightShoulder]);

/// Estimates the v2 length parts — inseam, sleeve, shirtSleeve, shoulder —
/// from frontal frames: per-frame estimates from `extra_measurements.dart`,
/// MAD outlier rejection, median value, stdDev from the frame spread and
/// confidence = agreement × median landmark likelihood (as for the torso
/// parts). Parts no frame can estimate are omitted; never throws.
///
/// Shared by [MeasurementEngine] and the rotation engine.
List<PartMeasurement> lengthPartsFromFrontFrames(
  List<FrontFrameInput> frames,
  UserProfile profile,
) {
  final values = <BodyPart, List<double>>{
    BodyPart.inseam: [],
    BodyPart.sleeve: [],
    BodyPart.shirtSleeve: [],
    BodyPart.shoulder: [],
  };
  final likelihoods = <BodyPart, List<double>>{
    for (final part in values.keys) part: [],
  };

  void add(BodyPart part, double? value, double likelihood) {
    if (value == null || !value.isFinite || value <= 0) return;
    values[part]!.add(value);
    likelihoods[part]!.add(likelihood);
  }

  for (final f in frames) {
    final pose = f.frame.pose;
    add(
      BodyPart.inseam,
      estimateInseamCm(f.frame, f.silhouette, f.scaleCmPerPx, profile),
      _inseamLikelihood(pose),
    );
    final sleeve = estimateSleeveCm(pose, f.scaleCmPerPx, profile);
    if (sleeve != null) {
      final l = _sleeveLikelihood(pose);
      add(BodyPart.sleeve, sleeve.outseamCm, l);
      add(BodyPart.shirtSleeve, sleeve.shirtSleeveCm, l);
    }
    add(
      BodyPart.shoulder,
      estimateShoulderWidthCm(pose, f.scaleCmPerPx, profile),
      _shoulderLikelihood(pose),
    );
  }

  final parts = <PartMeasurement>[];
  for (final part in values.keys) {
    final kept = rejectOutliers(values[part]!);
    if (kept.isEmpty) continue;
    final value = median(kept);
    if (value <= 0) continue;
    final spread = stdDev(kept);
    final likelihood = median(likelihoods[part]!);
    parts.add(PartMeasurement(
      part: part,
      valueCm: value,
      stdDevCm: spread,
      confidence:
          (agreementScore(spread, value) * likelihood).clamp(0.0, 1.0).toDouble(),
      // The shirt sleeve is a regression on shoulder + sleeve, not a
      // directly measured length.
      derived: part == BodyPart.shirtSleeve,
    ));
  }
  return parts;
}

/// Neck (from chest) and thigh (from hip) regression estimates for the
/// measured [parts], flagged `derived: true` with confidence 0.6 × the
/// source part's confidence and stdDev scaled by the regression slope.
/// Sources that are missing simply yield no derived part.
List<PartMeasurement> derivedPartsFrom(List<PartMeasurement> parts, Sex sex) {
  PartMeasurement? find(BodyPart p) {
    for (final m in parts) {
      if (m.part == p) return m;
    }
    return null;
  }

  PartMeasurement derive(
    BodyPart part,
    PartMeasurement source,
    double Function(double, Sex) model,
  ) {
    final value = model(source.valueCm, sex);
    // The regressions are linear, so a unit step gives the exact slope.
    final slope = (model(source.valueCm + 1, sex) - value).abs();
    return PartMeasurement(
      part: part,
      valueCm: value,
      stdDevCm: slope * source.stdDevCm,
      confidence: (_derivedConfidenceFactor * source.confidence)
          .clamp(0.0, 1.0)
          .toDouble(),
      derived: true,
    );
  }

  final out = <PartMeasurement>[];
  final chest = find(BodyPart.chest);
  if (chest != null && chest.valueCm > 0) {
    final neck = derive(BodyPart.neck, chest, estimateNeckCm);
    if (neck.valueCm > 0) out.add(neck);
  }
  final hip = find(BodyPart.hip);
  if (hip != null && hip.valueCm > 0) {
    final thigh = derive(BodyPart.thigh, hip, estimateThighCm);
    if (thigh.valueCm > 0) out.add(thigh);
  }
  return out;
}

/// Adds `profile.offsetsCm[part]` (tape minus app, from tap-to-correct) to
/// every part's value; parts without an offset are returned unchanged.
List<PartMeasurement> applyProfileOffsets(
  List<PartMeasurement> parts,
  UserProfile profile,
) {
  if (profile.offsetsCm.isEmpty) return parts;
  return [
    for (final m in parts)
      switch (profile.offsetsCm[m.part]) {
        null => m,
        final offset => PartMeasurement(
            part: m.part,
            valueCm: m.valueCm + offset,
            stdDevCm: m.stdDevCm,
            confidence: m.confidence,
            derived: m.derived,
          ),
      },
  ];
}

/// The measurement core: combines front + side silhouette bursts into
/// chest/waist/hip circumferences, scaled by the user's entered height,
/// then adds the v2 length parts and regression-derived parts.
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
  /// [circumferenceFromWidths] (ANSUR II model, profile.sex) ->
  /// [PartMeasurement] with stdDev propagated from the frame spread and
  /// confidence = agreement score (1 - clamp(cv*8, 0, 0.8)) * pose
  /// likelihood.
  ///
  /// After the torso parts: inseam, sleeve, shirtSleeve and shoulder from
  /// the front frames (median across frames, stdDev from spread, confidence
  /// as above), then neck (from chest) and thigh (from hip) flagged
  /// `derived` with 0.6 × the source confidence. Finally
  /// `profile.offsetsCm` is added to every part. Extra parts that cannot be
  /// estimated are omitted, never an error.
  ///
  /// Throws [MeasurementException] when [front] or [side] is empty or no
  /// frame yields usable torso geometry.
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
      for (final part in kTorsoParts)
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

    // 5. Combine per torso part: MAD-reject, median widths, propagate
    // spread through the breadth/depth model.
    final parts = <PartMeasurement>[];
    for (final part in kTorsoParts) {
      final frontW = rejectOutliers(widthsCm[part]![CaptureView.front]!);
      final sideW = rejectOutliers(widthsCm[part]![CaptureView.side]!);
      if (frontW.isEmpty || sideW.isEmpty) continue;
      final frontWidth = median(frontW);
      final sideDepth = median(sideW);
      final value = circumferenceFromWidths(
        frontWidthCm: frontWidth,
        sideDepthCm: sideDepth,
        part: part,
        sex: profile.sex,
        calibration: calibration,
      );
      if (value <= 0) continue;
      final spread = propagateCircumferenceSpread(
        part: part,
        sex: profile.sex,
        calibration: calibration,
        frontWidthCm: frontWidth,
        sideDepthCm: sideDepth,
        frontSdCm: stdDev(frontW),
        sideSdCm: stdDev(sideW),
      );
      parts.add(PartMeasurement(
        part: part,
        valueCm: value,
        stdDevCm: spread,
        confidence: (agreementScore(spread, value) * poseLikelihood)
            .clamp(0.0, 1.0)
            .toDouble(),
      ));
    }
    if (parts.isEmpty) {
      throw const MeasurementException(
          'No frame yields usable torso geometry');
    }

    // 6. Length parts from the front frames, then regression-derived
    // parts, then the user's tape corrections.
    parts.addAll(lengthPartsFromFrontFrames(
      [
        for (final f in usable)
          if (f.frame.view == CaptureView.front)
            (
              frame: f.frame,
              silhouette: f.silhouette,
              scaleCmPerPx: f.scaleCmPerPx,
            ),
      ],
      profile,
    ));
    parts.addAll(derivedPartsFrom(parts, profile.sex));

    return MeasurementResult(
      parts: applyProfileOffsets(parts, profile),
      scaleCmPerPx: median([for (final f in usable) f.scaleCmPerPx]),
      frontFrameCount: usedFront,
      sideFrameCount: usedSide,
      timestamp: DateTime.now(),
    );
  }
}
