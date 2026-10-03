import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fitsize/engine/circumference.dart';
import 'package:fitsize/engine/extra_measurements.dart';
import 'package:fitsize/engine/measurement_engine.dart' show MeasurementException;
import 'package:fitsize/engine/rotation_engine.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const double heightCm = 170;
const profile = UserProfile(heightCm: heightCm, sex: Sex.other);

/// Mask 128x256 for image 720x1440 (5.625 image px per mask px on both
/// axes); body rows 20..235 (215 mask px) stand for 170 cm.
const double imgPerMask = 5.625;
const double cmPerMaskPx = heightCm / 215;

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

const int personShoulderRow = 50;
const int personHipRow = 125;
const int personCrotchRow = 136;
const int personBottom = 235;
const double personShoulderHalfSep = 21;
const double personArmSegment = 20;

/// One turn still of an "elliptic cylinder person" at yaw [angleDeg]:
/// a rectangular silhouette whose constant width is the analytic projected
/// width of the (aCm, bCm) ellipse, converted to mask pixels through the
/// same height-derived scale the engine must reconstruct. Mask resolution
/// differs from image resolution to exercise maskScale conversions.
///
/// With [person] the still gains a head, a 2-column crotch gap splitting
/// the legs below [personCrotchRow], and a straight-arm A-pose landmark
/// set (shoulders 42 mask px apart, ankles inside each leg) so the length
/// parts can be estimated from the frontal stills.
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
  bool person = false,
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
  void fill(int r0, int r1, int c0, int c1) {
    for (var y = r0; y <= r1; y++) {
      for (var x = c0; x <= c1; x++) {
        conf[y * maskW + x] = 1.0;
      }
    }
  }

  PosePoint p(double maskX, double maskY) =>
      PosePoint(maskX * imgPerMaskX, maskY * imgPerMaskY);

  if (!person) {
    fill(top, bottom, left, right);
    final shoulderRow = (top + 20).toDouble();
    final hipRow = (top + 120).toDouble();
    final ankleRow = (bottom - 2).toDouble();
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

  fill(top, personShoulderRow - 1, 58, 69); // head
  fill(personShoulderRow, personCrotchRow, left, right); // torso
  fill(personCrotchRow + 1, personBottom, left, 62); // left leg
  fill(personCrotchRow + 1, personBottom, 65, right); // right leg
  const sh = personShoulderHalfSep;
  const seg = personArmSegment;
  const sy = 50.0;
  return RotationFrame(
    angleDegrees: angleDeg,
    frame: SilhouetteFrame(
      mask: BinaryMask(width: maskW, height: maskH, confidences: conf),
      pose: BodyPose({
        Landmark.nose: p(cx, 25),
        Landmark.leftShoulder: p(cx + sh, sy),
        Landmark.rightShoulder: p(cx - sh, sy),
        Landmark.leftElbow: p(cx + sh + seg, sy + seg),
        Landmark.rightElbow: p(cx - sh - seg, sy + seg),
        Landmark.leftWrist: p(cx + sh + 2 * seg, sy + 2 * seg),
        Landmark.rightWrist: p(cx - sh - 2 * seg, sy + 2 * seg),
        Landmark.leftHip: p(cx + 6, personHipRow.toDouble()),
        Landmark.rightHip: p(cx - 6, personHipRow.toDouble()),
        Landmark.leftAnkle: p(56, 230),
        Landmark.rightAnkle: p(72, 230),
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
    // Semi-axes chosen so projected widths stay well inside the mask.
    const a = 18.0, b = 12.0;

    test('recovers the cylinder-person circumference within 2%', () {
      final frames = [
        for (var i = 0; i < 12; i++) cylinderTurnFrame(a, b, i * 30),
      ];
      final result = engine.compute(frames: frames, profile: profile);
      for (final part in kTorsoParts) {
        // The fitted axes feed the ANSUR II model as breadth 2a, depth 2b.
        final expected = circumferenceFromWidths(
          frontWidthCm: 2 * a,
          sideDepthCm: 2 * b,
          part: part,
          sex: profile.sex,
        );
        final measured = result.valueFor(part);
        expect(measured, isNotNull, reason: '$part missing');
        // Mask-pixel quantisation adds ~1 px (~0.7 cm) of width error.
        expect(measured!, closeTo(expected, 0.02 * expected),
            reason: '$part off');
      }
      expect(result.frontFrameCount, 12);
      expect(result.sideFrameCount, 0);
    });

    test('uses the profile sex in the breadth/depth model', () {
      final frames = [
        for (var i = 0; i < 12; i++) cylinderTurnFrame(a, b, i * 30),
      ];
      final male =
          engine.compute(frames: frames, profile: profile.copyWith(sex: Sex.male));
      final female = engine.compute(
          frames: frames, profile: profile.copyWith(sex: Sex.female));
      for (final part in kTorsoParts) {
        expect(
          male.valueFor(part)!,
          closeTo(
            circumferenceFromWidths(
                frontWidthCm: 2 * a, sideDepthCm: 2 * b, part: part, sex: Sex.male),
            0.02 * male.valueFor(part)!,
          ),
          reason: '$part male',
        );
        expect(male.valueFor(part), isNot(closeTo(female.valueFor(part)!, 1e-6)),
            reason: '$part differs by sex');
      }
    });

    test('a plain cylinder omits the length parts but derives neck/thigh', () {
      final frames = [
        for (var i = 0; i < 12; i++) cylinderTurnFrame(a, b, i * 30),
      ];
      final result = engine.compute(frames: frames, profile: profile);
      expect(result.partFor(BodyPart.inseam), isNull);
      expect(result.partFor(BodyPart.shoulder), isNull);
      expect(result.partFor(BodyPart.sleeve), isNull);
      expect(result.partFor(BodyPart.shirtSleeve), isNull);
      final chest = result.partFor(BodyPart.chest)!;
      final neck = result.partFor(BodyPart.neck)!;
      expect(neck.derived, isTrue);
      expect(neck.valueCm, closeTo(estimateNeckCm(chest.valueCm, Sex.other), 1e-9));
      expect(neck.confidence, closeTo(0.6 * chest.confidence, 1e-9));
      final hip = result.partFor(BodyPart.hip)!;
      final thigh = result.partFor(BodyPart.thigh)!;
      expect(thigh.derived, isTrue);
      expect(thigh.valueCm, closeTo(estimateThighCm(hip.valueCm, Sex.other), 1e-9));
    });

    test('legs-apart person yields inseam/shoulder/sleeve from frontal stills',
        () {
      final frames = [
        for (var i = 0; i < 12; i++)
          cylinderTurnFrame(a, b, i * 30, person: true),
      ];
      final result = engine.compute(frames: frames, profile: profile);

      // Torso unaffected by the extra anatomy.
      for (final part in kTorsoParts) {
        final expected = circumferenceFromWidths(
            frontWidthCm: 2 * a, sideDepthCm: 2 * b, part: part);
        expect(result.valueFor(part)!, closeTo(expected, 0.02 * expected),
            reason: '$part');
      }

      final inseam = result.partFor(BodyPart.inseam)!;
      expect(inseam.valueCm,
          closeTo((personBottom - personCrotchRow) * cmPerMaskPx, cmPerMaskPx));
      expect(inseam.derived, isFalse);

      final shoulder = result.partFor(BodyPart.shoulder)!;
      expect(shoulder.valueCm,
          closeTo(1.15 * 2 * personShoulderHalfSep * cmPerMaskPx, 1e-6));

      final sleeve = result.partFor(BodyPart.sleeve)!;
      final chainCm = 2 * personArmSegment * math.sqrt(2) * cmPerMaskPx;
      expect(sleeve.valueCm, closeTo(0.983 * chainCm - 1.5, 1e-6));

      final shirt = result.partFor(BodyPart.shirtSleeve)!;
      final direct = estimateSleeveCm(
          frames.first.frame.pose, cmPerMaskPx / imgPerMask, profile)!;
      expect(shirt.valueCm, closeTo(direct.shirtSleeveCm, 1e-6));
      expect(shirt.derived, isTrue);

      // Only the 0 and 180 degree stills are frontal: identical, so no spread.
      for (final part in [BodyPart.inseam, BodyPart.shoulder, BodyPart.sleeve]) {
        expect(result.partFor(part)!.stdDevCm, closeTo(0, 1e-9), reason: '$part');
        expect(result.partFor(part)!.confidence, closeTo(1, 1e-9),
            reason: '$part');
      }

      expect(result.partFor(BodyPart.neck)!.derived, isTrue);
      expect(result.partFor(BodyPart.thigh)!.derived, isTrue);
    });

    test('applies profile offsets to every part', () {
      final frames = [
        for (var i = 0; i < 12; i++)
          cylinderTurnFrame(a, b, i * 30, person: true),
      ];
      final base = engine.compute(frames: frames, profile: profile);
      final offsets = {BodyPart.hip: -1.5, BodyPart.inseam: 2.0, BodyPart.thigh: 0.3};
      final corrected = engine.compute(
          frames: frames, profile: profile.copyWith(offsetsCm: offsets));
      for (final m in base.parts) {
        expect(corrected.partFor(m.part)!.valueCm,
            closeTo(m.valueCm + (offsets[m.part] ?? 0), 1e-9),
            reason: '${m.part}');
      }
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
