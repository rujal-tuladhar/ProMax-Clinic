import 'dart:typed_data';

import 'package:fitsize/engine/silhouette.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a mask from per-row confidence lists (all rows the same length).
BinaryMask maskFromRows(List<List<double>> rows) {
  final h = rows.length;
  final w = rows.first.length;
  final conf = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      conf[y * w + x] = rows[y][x];
    }
  }
  return BinaryMask(width: w, height: h, confidences: conf);
}

void main() {
  group('runsAt', () {
    test('binary run has pixel-boundary subpixel edges', () {
      final sil = Silhouette(maskFromRows([
        [0, 0, 0, 1, 1, 1, 0, 0],
      ]));
      final runs = sil.runsAt(0);
      expect(runs, hasLength(1));
      // Pixels 3..5 are body; with confidence 1 against 0 the threshold
      // crossing lands halfway into the neighbouring pixel.
      expect(runs.first.left, closeTo(2.5, 1e-9));
      expect(runs.first.right, closeTo(5.5, 1e-9));
      expect(runs.first.width, closeTo(3.0, 1e-9));
      expect(runs.first.center, closeTo(4.0, 1e-9));
    });

    test('graded confidences interpolate the 0.5 crossing', () {
      final sil = Silhouette(maskFromRows([
        [0, 0.25, 1.0, 1.0, 0.25, 0],
      ]));
      final runs = sil.runsAt(0);
      expect(runs, hasLength(1));
      // Left: between x=1 (0.25) and x=2 (1.0): 1 + (0.5-0.25)/0.75.
      expect(runs.first.left, closeTo(1 + 0.25 / 0.75, 1e-9));
      // Right: between x=3 (1.0) and x=4 (0.25): 3 + (1.0-0.5)/0.75.
      expect(runs.first.right, closeTo(3 + 0.5 / 0.75, 1e-9));
    });

    test('run touching the mask border uses 0 confidence outside', () {
      final sil = Silhouette(maskFromRows([
        [1, 1, 0, 0, 1],
      ]));
      final runs = sil.runsAt(0);
      expect(runs, hasLength(2));
      expect(runs[0].left, closeTo(-0.5, 1e-9));
      expect(runs[0].right, closeTo(1.5, 1e-9));
      expect(runs[1].left, closeTo(3.5, 1e-9));
      expect(runs[1].right, closeTo(4.5, 1e-9));
    });

    test('finds every run on a multi-run row, in order', () {
      final sil = Silhouette(maskFromRows([
        [0, 1, 0, 1, 1, 0, 0, 1, 1, 1, 0],
      ]));
      final runs = sil.runsAt(0);
      expect(runs, hasLength(3));
      expect(runs[0].width, closeTo(1, 1e-9));
      expect(runs[1].width, closeTo(2, 1e-9));
      expect(runs[2].width, closeTo(3, 1e-9));
      expect(runs[0].center, lessThan(runs[1].center));
      expect(runs[1].center, lessThan(runs[2].center));
    });

    test('values below threshold produce no runs', () {
      final sil = Silhouette(maskFromRows([
        [0.4, 0.49, 0.2],
      ]));
      expect(sil.runsAt(0), isEmpty);
    });

    test('custom threshold is honoured, >= counts as body', () {
      final rows = [
        [0.0, 0.3, 0.3, 0.0],
      ];
      // Below the default threshold these pixels are background...
      expect(Silhouette(maskFromRows(rows)).runsAt(0), isEmpty);
      // ...but with threshold 0.3 they form a run. Confidence exactly at
      // the threshold interpolates the crossing to the pixel centre, so
      // the span runs from the centre of pixel 1 to the centre of pixel 2.
      final runs = Silhouette(maskFromRows(rows), threshold: 0.3).runsAt(0);
      expect(runs, hasLength(1));
      expect(runs.first.left, closeTo(1.0, 1e-6));
      expect(runs.first.right, closeTo(2.0, 1e-6));
      expect(runs.first.width, closeTo(1.0, 1e-6));
    });

    test('row index is clamped into the mask', () {
      final sil = Silhouette(maskFromRows([
        [0, 1, 1, 0],
        [0, 0, 0, 0],
      ]));
      expect(sil.runsAt(-5), hasLength(1)); // clamps to row 0
      expect(sil.runsAt(99), isEmpty); // clamps to row 1
    });
  });

  group('torsoSpanAt', () {
    // A-pose row: detached left arm, torso, detached right arm.
    final sil = Silhouette(maskFromRows([
      [
        0, 1, 1, 0, 0, 0, // arm blob at ~1.5
        1, 1, 1, 1, 1, 1, // torso at 6..11
        0, 0, 0, 1, 1, 0, // arm blob at ~15.5
      ],
    ]));

    test('picks the run containing torsoCenterX, not an arm blob', () {
      final span = sil.torsoSpanAt(0, 8.5);
      expect(span, isNotNull);
      expect(span!.left, closeTo(5.5, 1e-9));
      expect(span.right, closeTo(11.5, 1e-9));
    });

    test('falls back to the nearest run center when x is outside all runs',
        () {
      // 11.6 sits in the gap between torso (center 8.5, distance 3.1) and
      // the right arm (center 15.5, distance 3.9); torso is nearer.
      final span = sil.torsoSpanAt(0, 11.6)!;
      expect(span.center, closeTo(8.5, 1e-9));
      // 14.2 is nearer to the right arm blob.
      final arm = sil.torsoSpanAt(0, 14.2)!;
      expect(arm.center, closeTo(15.5, 1e-9));
      // 3.9 sits left of the torso but nearer to the left arm (center 1.5).
      final leftArm = sil.torsoSpanAt(0, 3.9)!;
      expect(leftArm.center, closeTo(1.5, 1e-9));
    });

    test('returns null for a row with no runs', () {
      final empty = Silhouette(maskFromRows([
        [0.0, 0.0, 0.0],
      ]));
      expect(empty.torsoSpanAt(0, 1), isNull);
    });
  });

  group('vertical extent', () {
    test('topY/bottomY/bodyHeightPx on a body with empty margins', () {
      final sil = Silhouette(maskFromRows([
        [0, 0, 0],
        [0, 1, 0],
        [1, 1, 1],
        [0, 1, 0],
        [0, 0, 0],
      ]));
      expect(sil.topY, 1.0);
      expect(sil.bottomY, 3.0);
      expect(sil.bodyHeightPx, 2.0);
      expect(sil.width, 3);
      expect(sil.height, 5);
    });

    test('empty mask yields nulls', () {
      final sil = Silhouette(maskFromRows([
        [0.0, 0.0],
        [0.0, 0.0],
      ]));
      expect(sil.topY, isNull);
      expect(sil.bottomY, isNull);
      expect(sil.bodyHeightPx, isNull);
    });

    test('single-row body has zero height but non-null extent', () {
      final sil = Silhouette(maskFromRows([
        [0.0, 0.0],
        [1.0, 1.0],
        [0.0, 0.0],
      ]));
      expect(sil.topY, 1.0);
      expect(sil.bottomY, 1.0);
      expect(sil.bodyHeightPx, 0.0);
    });
  });
}
