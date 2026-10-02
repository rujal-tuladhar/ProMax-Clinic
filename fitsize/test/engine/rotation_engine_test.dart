import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fitsize/engine/circumference.dart';
import 'package:fitsize/engine/measurement_engine.dart' show MeasurementException;
import 'package:fitsize/engine/rotation_engine.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const double heightCm = 170;
const profile = UserProfile(heightCm: heightCm, sex: Sex.other);

/// Projected full width (cm) of an ellipse with semi-axes [a], [b] seen at
/// body yaw [angleDeg] + [phaseDeg].
double projectedWidth(double a, double b, double angleDeg,
    {double phaseDeg = 0}) {
  final t = (angleDeg + phaseDeg) * math.pi / 180;
  return 2 *
      math.sqrt(math.pow(a * math.cos(t), 2) + math.pow(b * math.sin(t), 2));
}

/// Deterministic pseudo-noise in [-1, 1] (no dart:math Random seed drift).
double noise(int i) => math.sin(i * 12.9898) * 0.86;

List<(double, double)> turnSamples(
  double a,
  double b, {
  int stops = 12,
  double phaseDeg = 0,
  double noiseCm = 0,
}) =>
    [
      for (var i = 0; i < stops; i++)
        (
          i * 360 / stops,
          projectedWidth(a, b, i * 360 / stops, phaseDeg: phaseDeg) +
              noiseCm * noise(i),
        )
    ];

/// One turn still of an "elliptic cylinder person" at yaw [angleDeg]:
/// a rectangular silhouette whose constant width is the analytic projected
/// width of the (aCm, bCm) ellipse, converted to mask pixels through the
/// same height-derived scale the engine must reconstruct. Mask resolution
/// differs from image resolution to exercise maskScale conversions.
RotationFrame cylinderTurnFrame(
  double aCm,
  double bCm,
  double angleDeg, {
  int maskW = 128,
  int maskH = 256,
  int imageW = 720,
  int imageH = 1440,
  int top = 20,
  int bottom = 235,
}) {
  const bodyHeightMaskPx = 215; // bottom - top matches Silhouette's extent
  final imgPerMaskY = imageH / maskH;
  final scaleCmPerImagePx = heightCm / (bodyHeightMaskPx * imgPerMaskY);
  final imgPerMaskX = imageW / maskW;
  final widthCm = projectedWidth(aCm, bCm, angleDeg);
  final widthMaskPx = (widthCm / scaleCmPerImagePx / imgPerMaskX).round();

  const cx = 64.0;
  final left = (cx - widthMaskPx / 2).round();
  final right = left + widthMaskPx - 1; // inclusive; run width == pixel count
  final conf = Float32List(maskW * maskH);
  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      conf[y * maskW + x] = 1.0;
    }
  }
  final shoulderRow = (top + 20).toDouble();
  final hipRow = (top + 120).toDouble();
  final ankleRow = (bottom - 2).toDouble();
  PosePoint p(double maskX, double maskY) =>
      PosePoint(maskX * imgPerMaskX, maskY * imgPerMaskY);
  return RotationFrame(
    angleDegrees: angleDeg,
    frame: SilhouetteFrame(
      mask: BinaryMask(width: maskW, height: maskH, confidences: conf),
      pose: BodyPose({
        Landmark.leftShoulder: p(cx + 10, shoulderRow),
        Landmark.rightShoulder: p(cx - 10, shoulderRow),
        Landmark.leftHip: p(cx + 5, hipRow),
        Landmark.rightHip: p(cx - 5, hipRow),
        Landmark.leftAnkle: p(cx + 3, ankleRow),
        Landmark.rightAnkle: p(cx - 3, ankleRow),
      }),
      imageWidth: imageW,
      imageHeight: imageH,
      view: CaptureView.front,
    ),
  );
}

void main() {
  group('fitEllipseWidths', () {
    test('recovers exact ellipse from 12 clean stops', () {
      final fit = fitEllipseWidths(turnSamples(17, 11))!;
      expect(fit.aCm, closeTo(17, 0.1));
      expect(fit.bCm, closeTo(11, 0.1));
      expect(fit.rmseCm, lessThan(0.05));
    });

    test('recovers ellipse when the subject started 10 degrees off', () {
      final fit = fitEllipseWidths(turnSamples(17, 11, phaseDeg: 10))!;
      final perimeter = ellipsePerimeter(fit.aCm, fit.bCm);
      expect(perimeter, closeTo(ellipsePerimeter(17, 11), 0.5));
      expect(fit.phaseDegrees, closeTo(10, 2.6)); // grid step is 2.5 degrees
    });

    test('tolerates per-view noise within ~2%', () {
      final fit = fitEllipseWidths(turnSamples(17, 11, noiseCm: 0.8))!;
      final perimeter = ellipsePerimeter(fit.aCm, fit.bCm);
      expect(
        perimeter,
        closeTo(ellipsePerimeter(17, 11), 0.02 * ellipsePerimeter(17, 11)),
      );
    });

    test('trims arm-contaminated outlier views', () {
      final samples = turnSamples(17, 11);
      // Two oblique views inflated by a merged arm (+6 cm).
      samples[2] = (samples[2].$1, samples[2].$2 + 6);
      samples[7] = (samples[7].$1, samples[7].$2 + 6);
      final fit = fitEllipseWidths(samples)!;
      final perimeter = ellipsePerimeter(fit.aCm, fit.bCm);
      expect(
        perimeter,
        closeTo(ellipsePerimeter(17, 11), 0.025 * ellipsePerimeter(17, 11)),
      );
      expect(fit.sampleCount, lessThan(samples.length));
    });

    test('returns null for too few samples', () {
      expect(fitEllipseWidths(turnSamples(17, 11, stops: 4)), isNull);
    });

    test('returns null when every view sees the same angle', () {
      final samples = [for (var i = 0; i < 8; i++) (0.0, 34.0)];
      expect(fitEllipseWidths(samples), isNull);
    });
  });

  group('RotationMeasurementEngine.compute', () {
    const engine = RotationMeasurementEngine();

    test('recovers the cylinder-person circumference within 2%', () {
      // Semi-axes chosen so projected widths stay well inside the mask.
      const a = 18.0, b = 12.0;
      final frames = [
        for (var i = 0; i < 12; i++) cylinderTurnFrame(a, b, i * 30),
      ];
      final result = engine.compute(frames: frames, profile: profile);
      for (final part in BodyPart.values) {
        final expected =
            ellipsePerimeter(a, b) * Calibration.standard.factorFor(part);
        final measured = result.valueFor(part);
        expect(measured, isNotNull, reason: '$part missing');
        // Mask-pixel quantisation adds ~1 px (~0.7 cm) of width error.
        expect(measured!, closeTo(expected, 0.02 * expected),
            reason: '$part off');
      }
      expect(result.frontFrameCount, 12);
      expect(result.sideFrameCount, 0);
    });

    test('throws on empty input', () {
      expect(
        () => engine.compute(frames: const [], profile: profile),
        throwsA(isA<MeasurementException>()),
      );
    });

    test('throws when angle coverage is degenerate', () {
      final frames = [
        for (var i = 0; i < 6; i++) cylinderTurnFrame(18, 12, 0),
      ];
      expect(
        () => engine.compute(frames: frames, profile: profile),
        throwsA(isA<MeasurementException>()),
      );
    });
  });
}
