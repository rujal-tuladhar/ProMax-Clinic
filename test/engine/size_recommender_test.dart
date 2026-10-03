import 'package:fitsize/engine/size_recommender.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

MeasurementResult resultWith(Map<BodyPart, double> values) =>
    MeasurementResult(
      parts: [
        for (final e in values.entries)
          PartMeasurement(
            part: e.key,
            valueCm: e.value,
            stdDevCm: 0.5,
            confidence: 0.9,
          ),
      ],
      scaleCmPerPx: 0.14,
      frontFrameCount: 5,
      sideFrameCount: 5,
      timestamp: DateTime(2026, 1, 1),
    );

String chestSize(double cm, Sex sex) => SizeRecommender.recommend(
      resultWith({BodyPart.chest: cm}),
      sex,
    ).perPart[BodyPart.chest]!;

void main() {
  group('male chest chart boundaries', () {
    test('lower-inclusive ranges: a boundary value belongs to the next size',
        () {
      expect(chestSize(85.9, Sex.male), 'XS');
      expect(chestSize(86, Sex.male), 'S');
      expect(chestSize(93.9, Sex.male), 'S');
      expect(chestSize(94, Sex.male), 'M');
      expect(chestSize(101.9, Sex.male), 'M');
      expect(chestSize(102, Sex.male), 'L');
      expect(chestSize(109.9, Sex.male), 'L');
      expect(chestSize(110, Sex.male), 'XL');
      expect(chestSize(118, Sex.male), 'XXL');
      expect(chestSize(140, Sex.male), 'XXL');
    });
  });

  group('female chart is shifted', () {
    test('the same chest reads a size larger for female at 92 cm', () {
      expect(chestSize(92, Sex.male), 'S'); // male S: 86-94
      expect(chestSize(92, Sex.female), 'M'); // female M: 88-96
    });

    test('female waist boundaries', () {
      final r = SizeRecommender.recommend(
          resultWith({BodyPart.waist: 70}), Sex.female);
      expect(r.perPart[BodyPart.waist], 'M'); // female M waist: 70-78
    });
  });

  group('Sex.other uses the midpoint chart', () {
    test('chest 92 is M for other (bounds midway between male/female)', () {
      // Mid bounds for chest: [83, 91, 99, 107, 115] -> 92 lands in M.
      expect(chestSize(92, Sex.other), 'M');
      expect(chestSize(90, Sex.other), 'S');
    });
  });

  group('top and bottom sizes', () {
    test('topSize follows the chest letter', () {
      final r = SizeRecommender.recommend(
        resultWith({BodyPart.chest: 96, BodyPart.waist: 80}),
        Sex.male,
      );
      expect(r.topSize, 'M');
    });

    test('bottomSize is the larger of the waist and hip letters', () {
      // Male waist 80 -> M; male hip 111 -> L... (104-112 is L).
      final r = SizeRecommender.recommend(
        resultWith({BodyPart.waist: 80, BodyPart.hip: 111}),
        Sex.male,
      );
      expect(r.perPart[BodyPart.waist], 'M');
      expect(r.perPart[BodyPart.hip], 'L');
      expect(r.bottomSize, 'L');

      // Reversed dominance: waist XL, hip S -> XL wins.
      final r2 = SizeRecommender.recommend(
        resultWith({BodyPart.waist: 100, BodyPart.hip: 90}),
        Sex.male,
      );
      expect(r2.perPart[BodyPart.waist], 'XL');
      expect(r2.perPart[BodyPart.hip], 'S');
      expect(r2.bottomSize, 'XL');
    });
  });

  group('missing parts', () {
    test('a missing part reads an en dash', () {
      final r = SizeRecommender.recommend(
        resultWith({BodyPart.chest: 96}),
        Sex.male,
      );
      expect(r.perPart[BodyPart.waist], '–');
      expect(r.perPart[BodyPart.hip], '–');
      expect(r.topSize, 'M');
      expect(r.bottomSize, '–');
    });

    test('bottomSize falls back to the only available bottom part', () {
      final r = SizeRecommender.recommend(
        resultWith({BodyPart.waist: 80}),
        Sex.male,
      );
      expect(r.bottomSize, 'M');
    });

    test('empty result yields dashes everywhere', () {
      final r = SizeRecommender.recommend(resultWith({}), Sex.female);
      expect(r.topSize, '–');
      expect(r.bottomSize, '–');
      expect(r.perPart.values, everyElement('–'));
    });
  });

  group('fit preference biases borderline lookups', () {
    String chestWithFit(double cm, FitPreference fit) =>
        SizeRecommender.recommend(
          resultWith({BodyPart.chest: cm}),
          Sex.male,
          fit: fit,
        ).perPart[BodyPart.chest]!;

    test('bias is -3 / 0 / +3 cm for slim / regular / relaxed', () {
      expect(SizeRecommender.biasFor(FitPreference.slim), -3);
      expect(SizeRecommender.biasFor(FitPreference.regular), 0);
      expect(SizeRecommender.biasFor(FitPreference.relaxed), 3);
      expect(SizeRecommender.fitBiasCm, 3);
    });

    test('omitting fit behaves exactly like regular', () {
      final result = resultWith({
        BodyPart.chest: 95,
        BodyPart.waist: 88,
        BodyPart.hip: 103,
      });
      final implicit = SizeRecommender.recommend(result, Sex.male);
      final explicit = SizeRecommender.recommend(
        result,
        Sex.male,
        fit: FitPreference.regular,
      );
      expect(implicit.topSize, explicit.topSize);
      expect(implicit.bottomSize, explicit.bottomSize);
      expect(implicit.perPart, explicit.perPart);
    });

    test('just above a boundary: slim rounds down, regular/relaxed hold', () {
      // Male chest 95 sits 1 cm above the S/M boundary (94).
      expect(chestWithFit(95, FitPreference.regular), 'M');
      expect(chestWithFit(95, FitPreference.slim), 'S');
      expect(chestWithFit(95, FitPreference.relaxed), 'M');
    });

    test('just below a boundary: relaxed rounds up, regular/slim hold', () {
      // Male chest 100 sits 2 cm below the M/L boundary (102).
      expect(chestWithFit(100, FitPreference.regular), 'M');
      expect(chestWithFit(100, FitPreference.relaxed), 'L');
      expect(chestWithFit(100, FitPreference.slim), 'M');
    });

    test('a mid-range measurement is unchanged under every preference', () {
      // 98 is the centre of male M (94–102): ±3 stays inside the range.
      for (final fit in FitPreference.values) {
        expect(chestWithFit(98, fit), 'M', reason: fit.name);
      }
    });

    test('edge semantics follow the lower-inclusive ranges', () {
      // Slim: exactly 3 cm above the boundary lands ON it -> still M.
      expect(chestWithFit(97, FitPreference.slim), 'M');
      expect(chestWithFit(96.9, FitPreference.slim), 'S');
      // Relaxed: exactly 3 cm below the boundary lands ON it -> flips to L.
      expect(chestWithFit(99, FitPreference.relaxed), 'L');
      expect(chestWithFit(98.9, FitPreference.relaxed), 'M');
    });

    test('bias applies to waist and hip, so bottomSize can flip too', () {
      // Male waist 88 is L (87–95) by 1 cm; hip 103 is M (96–104) by 1 cm.
      final result = resultWith({BodyPart.waist: 88, BodyPart.hip: 103});

      final regular = SizeRecommender.recommend(result, Sex.male);
      expect(regular.perPart[BodyPart.waist], 'L');
      expect(regular.perPart[BodyPart.hip], 'M');
      expect(regular.bottomSize, 'L');

      final slim = SizeRecommender.recommend(
        result,
        Sex.male,
        fit: FitPreference.slim,
      );
      expect(slim.perPart[BodyPart.waist], 'M'); // 85
      expect(slim.perPart[BodyPart.hip], 'M'); // 100
      expect(slim.bottomSize, 'M');

      final relaxed = SizeRecommender.recommend(
        result,
        Sex.male,
        fit: FitPreference.relaxed,
      );
      expect(relaxed.perPart[BodyPart.waist], 'L'); // 91
      expect(relaxed.perPart[BodyPart.hip], 'L'); // 106
      expect(relaxed.bottomSize, 'L');
    });

    test('works with the Sex.other midpoint chart', () {
      // Other chest bounds: [83, 91, 99, 107, 115]; 92 is 1 cm into M.
      String other(FitPreference fit) => SizeRecommender.recommend(
            resultWith({BodyPart.chest: 92}),
            Sex.other,
            fit: fit,
          ).topSize;
      expect(other(FitPreference.regular), 'M');
      expect(other(FitPreference.slim), 'S');
      expect(other(FitPreference.relaxed), 'M');
    });

    test('missing parts stay dashes under any fit', () {
      for (final fit in FitPreference.values) {
        final r = SizeRecommender.recommend(
          resultWith({BodyPart.chest: 96}),
          Sex.male,
          fit: fit,
        );
        expect(r.perPart[BodyPart.waist], '–', reason: fit.name);
        expect(r.perPart[BodyPart.hip], '–', reason: fit.name);
        expect(r.bottomSize, '–', reason: fit.name);
      }
    });
  });

  group('FitPreference on UserProfile', () {
    test('defaults to regular and keeps the existing constructor working',
        () {
      const profile = UserProfile(heightCm: 172, sex: Sex.female);
      expect(profile.fit, FitPreference.regular);
    });

    test('copyWith replaces only the given fields', () {
      const profile = UserProfile(
        heightCm: 172,
        sex: Sex.female,
        units: UnitSystem.imperial,
      );
      final slim = profile.copyWith(fit: FitPreference.slim);
      expect(slim.fit, FitPreference.slim);
      expect(slim.heightCm, 172);
      expect(slim.sex, Sex.female);
      expect(slim.units, UnitSystem.imperial);
      expect(profile.fit, FitPreference.regular, reason: 'original untouched');
    });

    test('round-trips through JSON', () {
      const profile = UserProfile(
        heightCm: 180,
        sex: Sex.male,
        fit: FitPreference.relaxed,
      );
      final json = profile.toJson();
      expect(json['fit'], 'relaxed');
      final back = UserProfile.fromJson(json)!;
      expect(back.fit, FitPreference.relaxed);
      expect(back.heightCm, 180);
      expect(back.sex, Sex.male);
    });

    test('profiles saved before the field existed read as regular', () {
      final legacy = UserProfile.fromJson({
        'heightCm': 165,
        'sex': 'female',
        'units': 'metric',
      })!;
      expect(legacy.fit, FitPreference.regular);
    });

    test('an unknown stored value falls back to regular', () {
      final odd = UserProfile.fromJson({
        'heightCm': 165,
        'sex': 'female',
        'fit': 'baggy',
      })!;
      expect(odd.fit, FitPreference.regular);
    });

    test('labels read Slim / Regular / Relaxed', () {
      expect(FitPreference.slim.label, 'Slim');
      expect(FitPreference.regular.label, 'Regular');
      expect(FitPreference.relaxed.label, 'Relaxed');
    });
  });
}
