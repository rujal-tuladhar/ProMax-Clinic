import 'dart:typed_data';

import 'package:fitsize/engine/body_rows.dart';
import 'package:fitsize/engine/silhouette.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const int maskW = 64;
const int maskH = 128;

/// Hourglass torso: base width 24 px centred at x=32, narrowing to 14 px
/// at row 62 (waist) and widening to 36 px at row 92 (hip). Body spans
/// rows 10..115.
BinaryMask hourglassMask() {
  final conf = Float32List(maskW * maskH);
  for (var y = 10; y <= 115; y++) {
    var w = 24;
    final waistDist = (y - 62).abs();
    if (waistDist < 10) w -= 10 - waistDist; // narrow towards the waist
    final hipDist = (y - 92).abs();
    if (hipDist < 12) w += 12 - hipDist; // widen towards the hip
    final left = 32 - w ~/ 2;
    for (var x = left; x < left + w; x++) {
      conf[y * maskW + x] = 1.0;
    }
  }
  return BinaryMask(width: maskW, height: maskH, confidences: conf);
}

/// Front frame over the hourglass mask; mask == image resolution, so mask
/// and image coordinates coincide. Shoulders at y=20, hip joints at y=80.
SilhouetteFrame hourglassFrame({bool withShoulders = true}) {
  final points = <Landmark, PosePoint>{
    if (withShoulders) Landmark.leftShoulder: const PosePoint(44, 20),
    if (withShoulders) Landmark.rightShoulder: const PosePoint(20, 20),
    Landmark.leftHip: const PosePoint(36, 80),
    Landmark.rightHip: const PosePoint(28, 80),
  };
  return SilhouetteFrame(
    mask: hourglassMask(),
    pose: BodyPose(points),
    imageWidth: maskW,
    imageHeight: maskH,
    view: CaptureView.front,
  );
}

void main() {
  group('rowFractionsFromFrontFrame', () {
    test('finds the waist at the narrowest row and hip at the widest', () {
      final frame = hourglassFrame();
      final fr = rowFractionsFromFrontFrame(frame, Silhouette(frame.mask));
      expect(fr, isNotNull);
      // Span is 80 - 20 = 60; narrowest row 62 -> (62-20)/60.
      expect(fr!.waist, closeTo((62 - 20) / 60, 1e-9));
      // Widest row below the hip joints is 92 -> (92-20)/60.
      expect(fr.hip, closeTo((92 - 20) / 60, 1e-9));
      expect(fr.chest, 0.22);
      expect(fr.hip, greaterThan(1.0));
    });

    test('returns null when shoulders are missing', () {
      final frame = hourglassFrame(withShoulders: false);
      expect(
        rowFractionsFromFrontFrame(frame, Silhouette(frame.mask)),
        isNull,
      );
    });

    test('returns null for a degenerate span (hips above shoulders)', () {
      final frame = SilhouetteFrame(
        mask: hourglassMask(),
        pose: const BodyPose({
          Landmark.leftShoulder: PosePoint(44, 80),
          Landmark.rightShoulder: PosePoint(20, 80),
          Landmark.leftHip: PosePoint(36, 20),
          Landmark.rightHip: PosePoint(28, 20),
        }),
        imageWidth: maskW,
        imageHeight: maskH,
        view: CaptureView.front,
      );
      expect(
        rowFractionsFromFrontFrame(frame, Silhouette(frame.mask)),
        isNull,
      );
    });
  });

  group('medianRowFractions', () {
    test('empty list falls back to defaults', () {
      final fr = medianRowFractions(const []);
      expect(fr.chest, RowFractions.defaults.chest);
      expect(fr.waist, RowFractions.defaults.waist);
      expect(fr.hip, RowFractions.defaults.hip);
    });

    test('component-wise median of several frames', () {
      final fr = medianRowFractions(const [
        RowFractions(chest: 0.20, waist: 0.70, hip: 1.30),
        RowFractions(chest: 0.22, waist: 0.75, hip: 1.10),
        RowFractions(chest: 0.30, waist: 0.71, hip: 1.20),
      ]);
      expect(fr.chest, closeTo(0.22, 1e-9));
      expect(fr.waist, closeTo(0.71, 1e-9));
      expect(fr.hip, closeTo(1.20, 1e-9));
    });

    test('even count averages the middle pair', () {
      final fr = medianRowFractions(const [
        RowFractions(chest: 0.20, waist: 0.70, hip: 1.10),
        RowFractions(chest: 0.24, waist: 0.74, hip: 1.20),
      ]);
      expect(fr.chest, closeTo(0.22, 1e-9));
      expect(fr.waist, closeTo(0.72, 1e-9));
      expect(fr.hip, closeTo(1.15, 1e-9));
    });
  });

  group('rowsForFrame', () {
    test('maps fractions through the frame landmarks in mask coords', () {
      final frame = hourglassFrame();
      const fractions = RowFractions(chest: 0.22, waist: 0.7, hip: 1.2);
      final rows = rowsForFrame(frame, fractions)!;
      expect(rows.chestY, closeTo(20 + 0.22 * 60, 1e-9));
      expect(rows.waistY, closeTo(62, 1e-9));
      expect(rows.hipY, closeTo(92, 1e-9));
    });

    test('projects image-space landmarks onto a smaller mask', () {
      // Image is 2x the mask resolution: landmark y 40/160 in image px
      // land on mask rows 20/80.
      final frame = SilhouetteFrame(
        mask: hourglassMask(),
        pose: const BodyPose({
          Landmark.leftShoulder: PosePoint(88, 40),
          Landmark.rightShoulder: PosePoint(40, 40),
          Landmark.leftHip: PosePoint(72, 160),
          Landmark.rightHip: PosePoint(56, 160),
        }),
        imageWidth: maskW * 2,
        imageHeight: maskH * 2,
        view: CaptureView.front,
      );
      final rows = rowsForFrame(frame, RowFractions.defaults)!;
      expect(rows.chestY, closeTo(20 + 0.22 * 60, 1e-9));
      expect(rows.waistY, closeTo(20 + 0.72 * 60, 1e-9));
      expect(rows.hipY, closeTo(20 + 1.15 * 60, 1e-9));
    });

    test('returns null when landmarks are missing', () {
      final frame = hourglassFrame(withShoulders: false);
      expect(rowsForFrame(frame, RowFractions.defaults), isNull);
    });
  });
}
