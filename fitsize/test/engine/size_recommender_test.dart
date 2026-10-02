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
}
