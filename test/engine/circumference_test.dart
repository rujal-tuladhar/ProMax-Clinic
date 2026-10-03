import 'dart:math' as math;

import 'package:fitsize/engine/circumference.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reference implementation of the ANSUR II table in the contract, so the
/// tests do not share constants with the code under test.
double reference(BodyPart part, Sex sex, double b, double d) {
  final male = switch (part) {
    BodyPart.chest => -1.38 + 1.548 * b + 2.460 * d,
    BodyPart.waist => 0.94 + 1.663 * b + 1.633 * d,
    BodyPart.hip => 5.90 + 1.841 * b + 1.318 * d,
    _ => throw ArgumentError(part),
  };
  final female = switch (part) {
    BodyPart.chest => 5.04 + 1.198 * b + 2.320 * d,
    BodyPart.waist => 2.96 + 1.776 * b + 1.402 * d,
    BodyPart.hip => 7.43 + 1.861 * b + 1.238 * d,
    _ => throw ArgumentError(part),
  };
  return switch (sex) {
    Sex.male => male,
    Sex.female => female,
    Sex.other => (male + female) / 2,
  };
}

void main() {
  group('ellipsePerimeter (still exported for the rotation fit)', () {
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
    test('standard factors are tape-equivalence placeholders of 1.0', () {
      for (final part in kTorsoParts) {
        expect(Calibration.standard.factorFor(part), 1.0, reason: '$part');
      }
    });

    test('missing part falls back to 1.0', () {
      const cal = Calibration({BodyPart.chest: 0.9});
      expect(cal.factorFor(BodyPart.waist), 1.0);
      expect(cal.factorFor(BodyPart.chest), 0.9);
    });
  });

  group('circumferenceFromWidths (ANSUR II linear model)', () {
    test('male waist at the ANSUR II mean breadth/depth reads ~94.1 cm', () {
      // Waist breadth 32.6 cm, waist depth 23.8 cm (ANSUR II male means);
      // the model gives 94.02 cm against a published mean of ~94.1 cm.
      final c = circumferenceFromWidths(
        frontWidthCm: 32.6,
        sideDepthCm: 23.8,
        part: BodyPart.waist,
        sex: Sex.male,
      );
      expect(c, closeTo(94.1, 0.15));
      expect(c, closeTo(0.94 + 1.663 * 32.6 + 1.633 * 23.8, 1e-9));
    });

    test('female hip at the ANSUR II mean breadth/depth reads ~102 cm', () {
      // Hip breadth 35.4 cm, buttock depth 23.3 cm; model gives 102.15 cm.
      final c = circumferenceFromWidths(
        frontWidthCm: 35.4,
        sideDepthCm: 23.3,
        part: BodyPart.hip,
        sex: Sex.female,
      );
      expect(c, closeTo(102.0, 0.25));
      expect(c, closeTo(7.43 + 1.861 * 35.4 + 1.238 * 23.3, 1e-9));
    });

    test('every part/sex matches the contract coefficients', () {
      for (final part in kTorsoParts) {
        for (final sex in Sex.values) {
          for (final (b, d) in const [(30.0, 20.0), (36.5, 25.2), (28.0, 19.0)]) {
            expect(
              circumferenceFromWidths(
                frontWidthCm: b,
                sideDepthCm: d,
                part: part,
                sex: sex,
              ),
              closeTo(reference(part, sex, b, d), 1e-9),
              reason: '$part $sex b=$b d=$d',
            );
          }
        }
      }
    });

    test('Sex.other is the mean of the male and female predictions', () {
      for (final part in kTorsoParts) {
        double at(Sex sex) => circumferenceFromWidths(
              frontWidthCm: 31,
              sideDepthCm: 22,
              part: part,
              sex: sex,
            );
        expect(at(Sex.other), closeTo((at(Sex.male) + at(Sex.female)) / 2, 1e-9),
            reason: '$part');
      }
    });

    test('sex defaults to other', () {
      final implicit = circumferenceFromWidths(
        frontWidthCm: 31,
        sideDepthCm: 22,
        part: BodyPart.waist,
      );
      final explicit = circumferenceFromWidths(
        frontWidthCm: 31,
        sideDepthCm: 22,
        part: BodyPart.waist,
        sex: Sex.other,
      );
      expect(implicit, explicit);
    });

    test('is linear in breadth and depth with the table slopes', () {
      double waist(double b, double d) => circumferenceFromWidths(
            frontWidthCm: b,
            sideDepthCm: d,
            part: BodyPart.waist,
            sex: Sex.male,
          );
      expect(waist(31, 22) - waist(30, 22), closeTo(1.663, 1e-9));
      expect(waist(30, 23) - waist(30, 22), closeTo(1.633, 1e-9));
    });

    test('the model reads higher than the Ramanujan ellipse at the hip', () {
      // The whole point of the change: a pure ellipse under-reads the tape.
      final ellipse = ellipsePerimeter(35.4 / 2, 23.3 / 2);
      final model = circumferenceFromWidths(
        frontWidthCm: 35.4,
        sideDepthCm: 23.3,
        part: BodyPart.hip,
        sex: Sex.female,
      );
      expect(model - ellipse, greaterThan(5));
    });

    test('applies the per-part calibration factor multiplicatively', () {
      const cal = Calibration({BodyPart.waist: 1.02, BodyPart.hip: 0.98});
      for (final part in kTorsoParts) {
        final base = circumferenceFromWidths(
          frontWidthCm: 30,
          sideDepthCm: 20,
          part: part,
          sex: Sex.female,
        );
        final scaled = circumferenceFromWidths(
          frontWidthCm: 30,
          sideDepthCm: 20,
          part: part,
          sex: Sex.female,
          calibration: cal,
        );
        expect(scaled, closeTo(base * cal.factorFor(part), 1e-9),
            reason: '$part');
      }
    });

    test('rejects non-torso parts', () {
      for (final part in BodyPart.values) {
        if (kTorsoParts.contains(part)) continue;
        expect(
          () => circumferenceFromWidths(
            frontWidthCm: 30,
            sideDepthCm: 20,
            part: part,
          ),
          throwsArgumentError,
          reason: '$part',
        );
      }
    });
  });
}
