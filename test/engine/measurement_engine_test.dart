import 'dart:typed_data';

import 'package:fitsize/engine/circumference.dart';
import 'package:fitsize/engine/measurement_engine.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const double heightCm = 170;

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

/// Analytic ground truth for a cylinder person: full widths in cm from the
/// mask geometry and the known standing height.
double analyticCircumference(
  BodyPart part, {
  required int frontWidthMaskPx,
  required int sideWidthMaskPx,
  int bodyHeightMaskPx = 215,
  double imgPerMaskX = 720 / 128,
  double imgPerMaskY = 1440 / 256,
}) {
  final scale = heightCm / (bodyHeightMaskPx * imgPerMaskY); // cm per image px
  return circumferenceFromWidths(
    frontWidthCm: frontWidthMaskPx * imgPerMaskX * scale,
    sideDepthCm: sideWidthMaskPx * imgPerMaskX * scale,
    part: part,
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

    test('all three parts land within 1.5% of the analytic perimeter', () {
      final result = engine.compute(front: front, side: side, profile: profile);
      for (final part in BodyPart.values) {
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

    test('identical frames give zero spread and full agreement', () {
      final result = engine.compute(front: front, side: side, profile: profile);
      for (final m in result.parts) {
        expect(m.stdDevCm, closeTo(0, 1e-9));
        expect(m.confidence, closeTo(1, 1e-9));
      }
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
      for (final part in BodyPart.values) {
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
      for (final part in BodyPart.values) {
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
        expect(m.stdDevCm, greaterThan(0));
        expect(m.confidence, lessThan(1));
        expect(m.confidence, greaterThan(0));
      }
      // The median width (28 px) still drives the value.
      final expected = analyticCircumference(BodyPart.waist,
          frontWidthMaskPx: 28, sideWidthMaskPx: 16);
      expect(result.valueFor(BodyPart.waist)!,
          closeTo(expected, expected * 0.015));
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
