import 'dart:math' as math;

import 'package:fitsize/engine/circumference.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ellipsePerimeter', () {
    test('circle equals 2*pi*r', () {
      expect(ellipsePerimeter(5, 5), closeTo(2 * math.pi * 5, 1e-9));
      expect(ellipsePerimeter(0.5, 0.5), closeTo(math.pi, 1e-9));
    });

    test('matches the known perimeter of a 3x2 ellipse', () {
      // Exact value 15.86543958929... (series/elliptic integral);
      // Ramanujan II agrees to well below 1e-6 at this eccentricity.
      expect(ellipsePerimeter(3, 2), closeTo(15.865439589, 1e-6));
    });

    test('is symmetric in a and b', () {
      expect(ellipsePerimeter(3, 2), ellipsePerimeter(2, 3));
    });

    test('degenerate axes', () {
      expect(ellipsePerimeter(0, 0), 0);
      // A fully flat ellipse has perimeter 4a; Ramanujan II is within ~0.4%.
      expect(ellipsePerimeter(5, 0), closeTo(20, 0.1));
    });
  });

  group('Calibration', () {
    test('standard factors', () {
      expect(Calibration.standard.factorFor(BodyPart.chest), 0.97);
      expect(Calibration.standard.factorFor(BodyPart.waist), 0.99);
      expect(Calibration.standard.factorFor(BodyPart.hip), 1.01);
    });

    test('missing part falls back to 1.0', () {
      const cal = Calibration({BodyPart.chest: 0.9});
      expect(cal.factorFor(BodyPart.waist), 1.0);
      expect(cal.factorFor(BodyPart.chest), 0.9);
    });
  });

  group('circumferenceFromWidths', () {
    test('circle with unit factor gives pi * diameter', () {
      const unit = Calibration({});
      final c = circumferenceFromWidths(
        frontWidthCm: 10,
        sideDepthCm: 10,
        part: BodyPart.waist,
        calibration: unit,
      );
      expect(c, closeTo(math.pi * 10, 1e-9));
    });

    test('halves the full widths into semi-axes', () {
      const unit = Calibration({});
      final c = circumferenceFromWidths(
        frontWidthCm: 6,
        sideDepthCm: 4,
        part: BodyPart.chest,
        calibration: unit,
      );
      expect(c, closeTo(ellipsePerimeter(3, 2), 1e-12));
    });

    test('applies the per-part calibration factor', () {
      final base = ellipsePerimeter(15, 10);
      final chest = circumferenceFromWidths(
        frontWidthCm: 30,
        sideDepthCm: 20,
        part: BodyPart.chest,
      );
      final waist = circumferenceFromWidths(
        frontWidthCm: 30,
        sideDepthCm: 20,
        part: BodyPart.waist,
      );
      final hip = circumferenceFromWidths(
        frontWidthCm: 30,
        sideDepthCm: 20,
        part: BodyPart.hip,
      );
      expect(chest, closeTo(base * 0.97, 1e-9));
      expect(waist, closeTo(base * 0.99, 1e-9));
      expect(hip, closeTo(base * 1.01, 1e-9));
    });
  });
}
