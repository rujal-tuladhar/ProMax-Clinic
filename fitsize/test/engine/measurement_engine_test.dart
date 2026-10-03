import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fitsize/engine/circumference.dart';
import 'package:fitsize/engine/extra_measurements.dart';
import 'package:fitsize/engine/measurement_engine.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const double heightCm = 170;

/// Mask 128x256 for image 720x1440: 5.625 image px per mask px on both
/// axes; body rows 20..235 (215 mask px) stand for 170 cm.
const double imgPerMask = 5.625;
const double cmPerMaskPx = heightCm / 215;

/// Builds one frame of an "elliptic cylinder person": a constant-width
/// rectangular silhouette (front view width 2a, side view width 2b) with a
/// consistent synthetic pose. The mask resolution differs from the image
/// resolution, so the frame exercises the maskScale conversions.
SilhouetteFrame cylinderFrame({
  required CaptureView view,
  required int left,
  required int right, // inclusive mask columns of the body
  int maskW = 128,
  int maskH = 256,
  int imageW = 720,
  int imageH = 1440,
  int top = 20,
  int bottom = 235, // inclusive mask rows of the body
}) {
  final conf = Float32List(maskW * maskH);
  for (var y = top; y <= bottom; y++) {
    for (var x = left; x <= right; x++) {
      conf[y * maskW + x] = 1.0;
    }
  }
  final toImgX = imageW / maskW;
  final toImgY = imageH / maskH;
  final cx = (left + right) / 2; // run centre in mask coords
  // Anatomy in mask rows, consistent with the silhouette extent.
  final shoulderRow = (top + 20).toDouble();
  final hipRow = (top + 120).toDouble();
  final ankleRow = (bottom - 2).toDouble();
  PosePoint p(double maskX, double maskY) =>
      PosePoint(maskX * toImgX, maskY * toImgY);
  return SilhouetteFrame(
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
    view: view,
  );
}

const int personShoulderRow = 50;
const int personHipRow = 125;
const int personCrotchRow = 136; // last merged row; legs start below it
const int personBottom = 235;
const int personTorsoLeft = 46, personTorsoRight = 81; // 36 px
const double personShoulderHalfSep = 21; // 42 px landmark distance
const double personArmSegment = 20; // mask px per axis, per arm segment

/// A fuller FRONT synthetic person: head, 36-px torso, two legs separated
/// by a 2-column gap below [personCrotchRow] (or a solid block when
/// [legsApart] is false), and a straight-arm A-pose landmark set with
/// shoulders 42 mask px apart and ankles inside each leg.
SilhouetteFrame personFrame({bool legsApart = true}) {
  const maskW = 128, maskH = 256, imageW = 720, imageH = 1440;
  final conf = Float32List(maskW * maskH);
  void fill(int r0, int r1, int c0, int c1) {
    for (var y = r0; y <= r1; y++) {
      for (var x = c0; x <= c1; x++) {
        conf[y * maskW + x] = 1.0;
      }
    }
  }

  fill(20, personShoulderRow - 1, 58, 69); // head
  fill(personShoulderRow, personCrotchRow, personTorsoLeft, personTorsoRight);
  if (legsApart) {
    fill(personCrotchRow + 1, personBottom, personTorsoLeft, 62);
    fill(personCrotchRow + 1, personBottom, 65, personTorsoRight);
  } else {
    fill(personCrotchRow + 1, personBottom, personTorsoLeft, personTorsoRight);
  }

  PosePoint p(double maskX, double maskY) =>
      PosePoint(maskX * imgPerMask, maskY * imgPerMask);
  const cx = 64.0;
  const sh = personShoulderHalfSep;
  const seg = personArmSegment;
  const sy = 50.0;
  return SilhouetteFrame(
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
      Landmark.leftKnee: p(54, 185),
      Landmark.rightKnee: p(73, 185),
      Landmark.leftAnkle: p(54, 230),
      Landmark.rightAnkle: p(73, 230),
    }),
    imageWidth: imageW,
    imageHeight: imageH,
    view: CaptureView.front,
  );
}

/// Analytic ground truth for a cylinder person: full widths in cm from the
/// mask geometry and the known standing height.
double analyticCircumference(
  BodyPart part, {
  required int frontWidthMaskPx,
  required int sideWidthMaskPx,
  int bodyHeightMaskPx = 215,
  double imgPerMaskX = 720 / 128,
  double imgPerMaskY = 1440 / 256,
  Sex sex = Sex.other,
}) {
  final scale = heightCm / (bodyHeightMaskPx * imgPerMaskY); // cm per image px
  return circumferenceFromWidths(
    frontWidthCm: frontWidthMaskPx * imgPerMaskX * scale,
    sideDepthCm: sideWidthMaskPx * imgPerMaskX * scale,
    part: part,
    sex: sex,
  );
}

const profile = UserProfile(heightCm: heightCm, sex: Sex.other);

void main() {
  const engine = MeasurementEngine();

  group('compute (elliptic cylinder ground truth)', () {
    // Front width 28 mask px (cols 50..77), side depth 16 mask px.
    final front = [
      for (var i = 0; i < 3; i++)
        cylinderFrame(view: CaptureView.front, left: 50, right: 77),
    ];
    final side = [
      for (var i = 0; i < 3; i++)
        cylinderFrame(view: CaptureView.side, left: 56, right: 71),
    ];

    test('all three torso parts land within 1.5% of the analytic model', () {
      final result = engine.compute(front: front, side: side, profile: profile);
      for (final part in kTorsoParts) {
        final expected = analyticCircumference(
          part,
          frontWidthMaskPx: 28,
          sideWidthMaskPx: 16,
        );
        final value = result.valueFor(part);
        expect(value, isNotNull, reason: 'missing $part');
        expect(value!, closeTo(expected, expected * 0.015),
            reason: '$part off analytic truth');
      }
      expect(result.frontFrameCount, 3);
      expect(result.sideFrameCount, 3);
    });

    test('uses the profile sex in the breadth/depth model', () {
      for (final sex in Sex.values) {
        final result = engine.compute(
            front: front, side: side, profile: profile.copyWith(sex: sex));
        for (final part in kTorsoParts) {
          final expected = analyticCircumference(
            part,
            frontWidthMaskPx: 28,
            sideWidthMaskPx: 16,
            sex: sex,
          );
          expect(result.valueFor(part)!, closeTo(expected, expected * 0.015),
              reason: '$part $sex');
        }
      }
    });

    test('identical frames give zero spread and full agreement', () {
      final result = engine.compute(front: front, side: side, profile: profile);
      for (final m in result.parts) {
        expect(m.stdDevCm, closeTo(0, 1e-9), reason: '${m.part}');
        if (m.derived) {
          // Regression-derived parts carry 0.6 x the source confidence.
          expect(m.confidence, closeTo(0.6, 1e-9), reason: '${m.part}');
        } else {
          expect(m.confidence, closeTo(1, 1e-9), reason: '${m.part}');
        }
      }
    });

    test('a cylinder omits the length parts but derives neck and thigh', () {
      // Shoulders 20 mask px apart (too narrow), no crotch, hip row too far
      // from the floor for the inseam fallback band, no elbows/wrists.
      final result = engine.compute(front: front, side: side, profile: profile);
      expect(result.partFor(BodyPart.inseam), isNull);
      expect(result.partFor(BodyPart.shoulder), isNull);
      expect(result.partFor(BodyPart.sleeve), isNull);
      expect(result.partFor(BodyPart.shirtSleeve), isNull);
      expect(result.partFor(BodyPart.neck)?.derived, isTrue);
      expect(result.partFor(BodyPart.thigh)?.derived, isTrue);
    });

    test('reports the median cm-per-image-pixel scale', () {
      final result = engine.compute(front: front, side: side, profile: profile);
      expect(result.scaleCmPerPx, closeTo(heightCm / (215 * 5.625), 1e-9));
    });
  });

  group('mask vs image resolution', () {
    test('non-uniform mask scale still converts widths correctly', () {
      // Mask 100x256 for image 720x1440: x and y scales differ (7.2 vs
      // 5.625 image px per mask px). A mixed-up axis would be ~28% off.
      final front = cylinderFrame(
          view: CaptureView.front, left: 36, right: 63, maskW: 100);
      final side = cylinderFrame(
          view: CaptureView.side, left: 42, right: 57, maskW: 100);
      final result =
          engine.compute(front: [front], side: [side], profile: profile);
      for (final part in kTorsoParts) {
        final expected = analyticCircumference(
          part,
          frontWidthMaskPx: 28,
          sideWidthMaskPx: 16,
          imgPerMaskX: 720 / 100,
        );
        expect(result.valueFor(part)!, closeTo(expected, expected * 0.015));
      }
    });
  });

  group('scale-outlier rejection', () {
    test('drops a frame whose implied scale is off and ignores its width',
        () {
      final goodFront = [
        for (var i = 0; i < 3; i++)
          cylinderFrame(view: CaptureView.front, left: 50, right: 77),
      ];
      // Much shorter silhouette (scale +53%) and much wider body: if this
      // frame were kept, the front widths and the result would shift.
      final badFrame = cylinderFrame(
          view: CaptureView.front, left: 30, right: 97, top: 60, bottom: 200);
      final side = [
        for (var i = 0; i < 3; i++)
          cylinderFrame(view: CaptureView.side, left: 56, right: 71),
      ];
      final clean =
          engine.compute(front: goodFront, side: side, profile: profile);
      final withOutlier = engine.compute(
          front: [...goodFront, badFrame], side: side, profile: profile);
      for (final part in kTorsoParts) {
        expect(withOutlier.valueFor(part)!,
            closeTo(clean.valueFor(part)!, 1e-9));
      }
      expect(withOutlier.frontFrameCount, 3);
    });
  });

  group('frame spread', () {
    test('width variation produces stdDev > 0 and confidence < 1', () {
      final front = [
        cylinderFrame(view: CaptureView.front, left: 51, right: 76), // 26 px
        cylinderFrame(view: CaptureView.front, left: 50, right: 77), // 28 px
        cylinderFrame(view: CaptureView.front, left: 49, right: 78), // 30 px
      ];
      final side = [
        for (var i = 0; i < 3; i++)
          cylinderFrame(view: CaptureView.side, left: 56, right: 71),
      ];
      final result =
          engine.compute(front: front, side: side, profile: profile);
      for (final m in result.parts) {
        expect(m.stdDevCm, greaterThan(0), reason: '${m.part}');
        expect(m.confidence, lessThan(1), reason: '${m.part}');
        expect(m.confidence, greaterThan(0), reason: '${m.part}');
      }
      // The median width (28 px) still drives the value.
      final expected = analyticCircumference(BodyPart.waist,
          frontWidthMaskPx: 28, sideWidthMaskPx: 16);
      expect(result.valueFor(BodyPart.waist)!,
          closeTo(expected, expected * 0.015));
      // Derived spread follows the regression slope of the source spread.
      final chest = result.partFor(BodyPart.chest)!;
      final neck = result.partFor(BodyPart.neck)!;
      final slope = estimateNeckCm(101, Sex.other) - estimateNeckCm(100, Sex.other);
      expect(neck.stdDevCm, closeTo(slope * chest.stdDevCm, 1e-9));
      expect(neck.confidence, closeTo(0.6 * chest.confidence, 1e-9));
    });
  });

  group('extra parts (legs-apart synthetic person)', () {
    final front = [for (var i = 0; i < 3; i++) personFrame()];
    final side = [
      for (var i = 0; i < 3; i++)
        cylinderFrame(view: CaptureView.side, left: 56, right: 71),
    ];
    final scaleCmPerImagePx = cmPerMaskPx / imgPerMask;

    test('torso parts still follow the 36 x 16 px widths', () {
      final result = engine.compute(front: front, side: side, profile: profile);
      for (final part in kTorsoParts) {
        final expected = analyticCircumference(
          part,
          frontWidthMaskPx: 36,
          sideWidthMaskPx: 16,
        );
        expect(result.valueFor(part)!, closeTo(expected, expected * 0.015),
            reason: '$part');
      }
      expect(result.frontFrameCount, 3);
    });

    test('yields inseam, shoulder, sleeve and shirt sleeve', () {
      final result = engine.compute(front: front, side: side, profile: profile);

      final inseam = result.partFor(BodyPart.inseam);
      expect(inseam, isNotNull);
      // 99 leg rows below the crotch; within one mask pixel of truth.
      expect(inseam!.valueCm,
          closeTo((personBottom - personCrotchRow) * cmPerMaskPx, cmPerMaskPx));
      expect(inseam.derived, isFalse);

      final shoulder = result.partFor(BodyPart.shoulder);
      expect(shoulder, isNotNull);
      expect(shoulder!.valueCm,
          closeTo(1.15 * 2 * personShoulderHalfSep * cmPerMaskPx, 1e-6));
      expect(shoulder.derived, isFalse);

      final sleeve = result.partFor(BodyPart.sleeve);
      expect(sleeve, isNotNull);
      final chainCm = 2 * personArmSegment * math.sqrt(2) * cmPerMaskPx;
      expect(sleeve!.valueCm, closeTo(0.983 * chainCm - 1.5, 1e-6));
      expect(sleeve.derived, isFalse);

      final shirt = result.partFor(BodyPart.shirtSleeve);
      expect(shirt, isNotNull);
      final direct =
          estimateSleeveCm(front.first.pose, scaleCmPerImagePx, profile)!;
      expect(shirt!.valueCm, closeTo(direct.shirtSleeveCm, 1e-6));
      expect(shirt.derived, isTrue);

      // Identical frames: full agreement, perfect landmarks.
      for (final part in [
        BodyPart.inseam,
        BodyPart.shoulder,
        BodyPart.sleeve,
        BodyPart.shirtSleeve,
      ]) {
        final m = result.partFor(part)!;
        expect(m.stdDevCm, closeTo(0, 1e-9), reason: '$part');
        expect(m.confidence, closeTo(1, 1e-9), reason: '$part');
      }
    });

    test('derives neck from chest and thigh from hip', () {
      final result = engine.compute(front: front, side: side, profile: profile);
      final chest = result.partFor(BodyPart.chest)!;
      final hip = result.partFor(BodyPart.hip)!;
      final neck = result.partFor(BodyPart.neck)!;
      final thigh = result.partFor(BodyPart.thigh)!;
      expect(neck.valueCm, closeTo(estimateNeckCm(chest.valueCm, Sex.other), 1e-9));
      expect(thigh.valueCm, closeTo(estimateThighCm(hip.valueCm, Sex.other), 1e-9));
      expect(neck.derived, isTrue);
      expect(thigh.derived, isTrue);
      expect(neck.confidence, closeTo(0.6 * chest.confidence, 1e-9));
      expect(thigh.confidence, closeTo(0.6 * hip.confidence, 1e-9));
    });

    test('lists torso parts first, then lengths, then derived parts', () {
      final result = engine.compute(front: front, side: side, profile: profile);
      expect(result.parts.map((m) => m.part).toList(), [
        BodyPart.chest,
        BodyPart.waist,
        BodyPart.hip,
        BodyPart.inseam,
        BodyPart.sleeve,
        BodyPart.shirtSleeve,
        BodyPart.shoulder,
        BodyPart.neck,
        BodyPart.thigh,
      ]);
    });

    test('legs together: inseam comes from the hip-offset fallback', () {
      final together = [for (var i = 0; i < 3; i++) personFrame(legsApart: false)];
      final result =
          engine.compute(front: together, side: side, profile: profile);
      final inseam = result.partFor(BodyPart.inseam);
      expect(inseam, isNotNull);
      final k = (0.0313 + 0.0388) / 2;
      final fallback =
          (personBottom - personHipRow) * cmPerMaskPx - k * heightCm;
      expect(inseam!.valueCm, closeTo(fallback, 1e-6));
      expect(inseam.valueCm,
          isNot(closeTo((personBottom - personCrotchRow) * cmPerMaskPx, 1)));
    });

    test('applies profile offsets to every part after derivation', () {
      final base = engine.compute(front: front, side: side, profile: profile);
      final offsets = {
        BodyPart.waist: 2.5,
        BodyPart.inseam: -1.0,
        BodyPart.neck: 0.7,
        BodyPart.chest: 4.0,
      };
      final corrected = engine.compute(
          front: front, side: side, profile: profile.copyWith(offsetsCm: offsets));
      for (final m in base.parts) {
        final c = corrected.partFor(m.part)!;
        expect(c.valueCm, closeTo(m.valueCm + (offsets[m.part] ?? 0), 1e-9),
            reason: '${m.part}');
        expect(c.stdDevCm, m.stdDevCm);
        expect(c.confidence, m.confidence);
        expect(c.derived, m.derived);
      }
      // The neck is derived from the un-corrected chest, then gets only its
      // own offset (the chest offset is not propagated twice).
      expect(corrected.valueFor(BodyPart.neck)!,
          closeTo(base.valueFor(BodyPart.neck)! + 0.7, 1e-9));
    });
  });

  group('failure modes', () {
    final okFront =
        cylinderFrame(view: CaptureView.front, left: 50, right: 77);
    final okSide = cylinderFrame(view: CaptureView.side, left: 56, right: 71);

    test('throws on empty front burst', () {
      expect(
        () => engine.compute(front: [], side: [okSide], profile: profile),
        throwsA(isA<MeasurementException>()),
      );
    });

    test('throws on empty side burst', () {
      expect(
        () => engine.compute(front: [okFront], side: [], profile: profile),
        throwsA(isA<MeasurementException>()),
      );
    });

    test('throws when no frame has a usable silhouette', () {
      final blank = SilhouetteFrame(
        mask: BinaryMask(
            width: 128, height: 256, confidences: Float32List(128 * 256)),
        pose: okFront.pose,
        imageWidth: 720,
        imageHeight: 1440,
        view: CaptureView.front,
      );
      final blankSide = SilhouetteFrame(
        mask: blank.mask,
        pose: okSide.pose,
        imageWidth: 720,
        imageHeight: 1440,
        view: CaptureView.side,
      );
      expect(
        () => engine
            .compute(front: [blank], side: [blankSide], profile: profile),
        throwsA(isA<MeasurementException>()),
      );
    });

    test('MeasurementException carries its message', () {
      try {
        engine.compute(front: [], side: [okSide], profile: profile);
        fail('should have thrown');
      } on MeasurementException catch (e) {
        expect(e.message, isNotEmpty);
        expect(e.toString(), contains(e.message));
      }
    });
  });
}
