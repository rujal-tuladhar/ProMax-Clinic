import 'package:fitsize/engine/size_recommender.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

MeasurementResult resultWith(
  Map<BodyPart, double> values, {
  double sd = 0.5,
  Set<BodyPart> derived = const {},
}) =>
    MeasurementResult(
      parts: [
        for (final e in values.entries)
          PartMeasurement(
            part: e.key,
            valueCm: e.value,
            stdDevCm: sd,
            confidence: 0.9,
            derived: derived.contains(e.key),
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

double sumOf(Map<String, double> p) =>
    p.values.fold(0.0, (acc, v) => acc + v);

String argmax(Map<String, double> p) =>
    p.entries.reduce((a, b) => b.value > a.value ? b : a).key;

/// Standard normal CDF via the recommender's own erf (what the tests check
/// the chart masses against).
double phi(double z) => SizeRecommender.normalCdf(z);

const List<String> kSizeOrder = ['XS', 'S', 'M', 'L', 'XL', 'XXL'];

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

  group('perPart covers every BodyPart', () {
    final allParts = resultWith({
      BodyPart.chest: 96,
      BodyPart.waist: 82,
      BodyPart.hip: 100,
      BodyPart.neck: 39.4,
      BodyPart.shoulder: 44,
      BodyPart.sleeve: 62,
      BodyPart.shirtSleeve: 86.4,
      BodyPart.inseam: 81.3,
      BodyPart.thigh: 58,
    });

    test('recommend has an entry for each part, torso letters, others –', () {
      final r = SizeRecommender.recommend(allParts, Sex.male);
      expect(r.perPart.keys.toSet(), BodyPart.values.toSet());
      expect(r.perPart[BodyPart.chest], 'M');
      expect(r.perPart[BodyPart.waist], 'M');
      expect(r.perPart[BodyPart.hip], 'M');
      for (final part in BodyPart.values) {
        if (kTorsoParts.contains(part)) continue;
        expect(r.perPart[part], '–', reason: '${part.name} has no chart');
      }
    });

    test('recommendWithProbabilities mirrors that coverage', () {
      final r = SizeRecommender.recommendWithProbabilities(allParts, Sex.male);
      expect(r.perPart.keys.toSet(), BodyPart.values.toSet());
      expect(r.perPart[BodyPart.neck], '–');
      expect(r.perPart[BodyPart.inseam], '–');
      expect(r.topSize, 'M');
      expect(r.bottomSize, 'M');
    });

    test('an empty result still maps every part', () {
      final r = SizeRecommender.recommend(resultWith({}), Sex.other);
      expect(r.perPart.length, BodyPart.values.length);
      expect(r.perPart.values, everyElement('–'));
    });
  });

  group('recommendWithProbabilities', () {
    test('masses sum to 1 and the recommended letter has the highest mass',
        () {
      // Chest 95 (M by 1 cm), waist 86 (M, 1 cm under L), hip 105 (L by 1 cm).
      final r = SizeRecommender.recommendWithProbabilities(
        resultWith(
          {BodyPart.chest: 95, BodyPart.waist: 86, BodyPart.hip: 105},
          sd: 1.5,
        ),
        Sex.male,
      );
      expect(r.topSize, 'M');
      expect(r.bottomSize, 'L');
      expect(sumOf(r.topProbabilities), closeTo(1, 1e-6));
      expect(sumOf(r.bottomProbabilities), closeTo(1, 1e-6));
      expect(argmax(r.topProbabilities), r.topSize);
      expect(argmax(r.bottomProbabilities), r.bottomSize);
      expect(r.topProbabilities.keys.toList(), kSizeOrder);
      expect(r.bottomProbabilities.keys.toList(), kSizeOrder);
      for (final p in r.topProbabilities.values) {
        expect(p, inInclusiveRange(0, 1));
      }
    });

    test('a value 1 cm above the S/M boundary splits ~31/69 at sd 2', () {
      // Male chest: S < 94 <= M < 102. Centre 95, sd 2.
      final r = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.chest: 95}, sd: 2),
        Sex.male,
      );
      final p = r.topProbabilities;
      expect(p['S'], closeTo(phi(-0.5) - phi(-4.5), 1e-6));
      expect(p['M'], closeTo(phi(3.5) - phi(-0.5), 1e-6));
      expect(p['S'], closeTo(0.3085, 1e-3));
      expect(p['M'], closeTo(0.6913, 1e-3));
      expect(p['L'], lessThan(1e-3));
      expect(r.topSize, 'M');
    });

    test('a mid-band value is near-certain', () {
      // 98 is the centre of male M (94–102); sd 1 -> Φ(4) - Φ(-4).
      final r = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.chest: 98}, sd: 1),
        Sex.male,
      );
      expect(r.topProbabilities['M'], closeTo(0.99994, 1e-4));
      expect(r.topSize, 'M');
    });

    test('the spread is floored at 1 cm', () {
      final tight = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.chest: 94.5}, sd: 0.1),
        Sex.male,
      );
      final unit = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.chest: 94.5}, sd: 1.0),
        Sex.male,
      );
      expect(tight.topProbabilities, unit.topProbabilities);
      expect(tight.topProbabilities['S'], closeTo(phi(-0.5), 1e-6));
      expect(SizeRecommender.minSdCm, 1.0);
      expect(
        SizeRecommender.sdFor(const PartMeasurement(
          part: BodyPart.chest,
          valueCm: 90,
          stdDevCm: 2.5,
          confidence: 1,
        )),
        2.5,
      );
      expect(
        SizeRecommender.sdFor(const PartMeasurement(
          part: BodyPart.chest,
          valueCm: 90,
          stdDevCm: double.nan,
          confidence: 1,
        )),
        1.0,
      );
    });

    test('the fit preference shifts the distribution with the letter', () {
      final result = resultWith({BodyPart.chest: 95}, sd: 1);
      final relaxed = SizeRecommender.recommendWithProbabilities(
        result,
        Sex.male,
        fit: FitPreference.relaxed,
      );
      // Centre 98: squarely M.
      expect(relaxed.topSize, 'M');
      expect(relaxed.topProbabilities['M'], greaterThan(0.99));

      final slim = SizeRecommender.recommendWithProbabilities(
        result,
        Sex.male,
        fit: FitPreference.slim,
      );
      // Centre 92: S with Φ(2) - Φ(-6) ≈ 0.977.
      expect(slim.topSize, 'S');
      expect(slim.topProbabilities['S'], closeTo(0.9772, 1e-3));
      expect(argmax(slim.topProbabilities), 'S');
    });

    test('letters agree with recommend() across the charts for realistic '
        'spreads, and are always the modal size', () {
      for (final sex in Sex.values) {
        for (final fit in FitPreference.values) {
          for (final sd in const [0.5, 1.0, 2.0, 2.5]) {
            // .3 offsets keep the grid off the exact chart boundaries.
            for (var v = 55.3; v < 135; v += 1) {
              final result = resultWith(
                {BodyPart.chest: v, BodyPart.waist: v - 14, BodyPart.hip: v},
                sd: sd,
              );
              final plain = SizeRecommender.recommend(result, sex, fit: fit);
              final prob = SizeRecommender.recommendWithProbabilities(
                result,
                sex,
                fit: fit,
              );
              final why = '$sex $fit sd=$sd v=$v';
              expect(prob.topSize, plain.topSize, reason: why);
              expect(prob.bottomSize, plain.bottomSize, reason: why);
              expect(prob.perPart, plain.perPart, reason: why);
              expect(argmax(prob.topProbabilities), prob.topSize,
                  reason: why);
              expect(argmax(prob.bottomProbabilities), prob.bottomSize,
                  reason: why);
              expect(sumOf(prob.topProbabilities), closeTo(1, 1e-6),
                  reason: why);
            }
          }
        }
      }
    });

    test('bottom probabilities come from the part that set the bottom size',
        () {
      // Waist 80 -> M, hip 111 -> L: hip decides.
      final both = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.waist: 80, BodyPart.hip: 111}, sd: 1.5),
        Sex.male,
      );
      final hipOnly = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.hip: 111}, sd: 1.5),
        Sex.male,
      );
      expect(both.bottomSize, 'L');
      expect(both.bottomProbabilities, hipOnly.bottomProbabilities);
      expect(argmax(both.bottomProbabilities), 'L');

      // Waist 100 -> XL, hip 90 -> S: waist decides.
      final waistWins = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.waist: 100, BodyPart.hip: 90}, sd: 1.5),
        Sex.male,
      );
      final waistOnly = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.waist: 100}, sd: 1.5),
        Sex.male,
      );
      expect(waistWins.bottomSize, 'XL');
      expect(waistWins.bottomProbabilities, waistOnly.bottomProbabilities);
    });

    test('equal waist and hip letters use the waist distribution', () {
      final tie = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.waist: 80, BodyPart.hip: 100}, sd: 2),
        Sex.male,
      );
      final waistOnly = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.waist: 80}, sd: 2),
        Sex.male,
      );
      expect(tie.perPart[BodyPart.waist], 'M');
      expect(tie.perPart[BodyPart.hip], 'M');
      expect(tie.bottomSize, 'M');
      expect(tie.bottomProbabilities, waistOnly.bottomProbabilities);
    });

    test('missing parts give dashes and empty distributions', () {
      final noChest = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.waist: 80}),
        Sex.male,
      );
      expect(noChest.topSize, '–');
      expect(noChest.topProbabilities, isEmpty);
      expect(noChest.bottomSize, 'M');
      expect(sumOf(noChest.bottomProbabilities), closeTo(1, 1e-6));

      final nothing = SizeRecommender.recommendWithProbabilities(
        resultWith({}),
        Sex.female,
      );
      expect(nothing.topSize, '–');
      expect(nothing.bottomSize, '–');
      expect(nothing.topProbabilities, isEmpty);
      expect(nothing.bottomProbabilities, isEmpty);
      expect(nothing.perPart.values, everyElement('–'));
    });

    test('Sex.other uses the midpoint chart for the distribution too', () {
      // Other chest bounds: [83, 91, 99, 107, 115]; 92 with sd 1.
      final r = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.chest: 92}, sd: 1),
        Sex.other,
      );
      expect(r.topSize, 'M');
      expect(r.topProbabilities['M'], closeTo(phi(7) - phi(-1), 1e-6));
      expect(r.topProbabilities['S'], closeTo(phi(-1), 1e-6));
    });

    test('recommend() leaves the probability maps empty', () {
      final r = SizeRecommender.recommend(
        resultWith({BodyPart.chest: 96, BodyPart.waist: 80}),
        Sex.male,
      );
      expect(r.topProbabilities, isEmpty);
      expect(r.bottomProbabilities, isEmpty);
    });
  });

  group('erf and normal CDF', () {
    test('erf matches tabulated values to 1e-6', () {
      expect(SizeRecommender.erf(0), 0);
      expect(SizeRecommender.erf(0.5), closeTo(0.5204999, 1e-6));
      expect(SizeRecommender.erf(1), closeTo(0.8427008, 1e-6));
      expect(SizeRecommender.erf(2), closeTo(0.9953223, 1e-6));
      expect(SizeRecommender.erf(-1), closeTo(-0.8427008, 1e-6));
      expect(SizeRecommender.erf(double.infinity), 1);
      expect(SizeRecommender.erf(double.negativeInfinity), -1);
      expect(SizeRecommender.erf(double.nan), isNaN);
    });

    test('normalCdf matches the standard table', () {
      expect(phi(0), 0.5);
      expect(phi(1), closeTo(0.8413447, 1e-6));
      expect(phi(-1), closeTo(0.1586553, 1e-6));
      expect(phi(1.959964), closeTo(0.975, 1e-6));
      expect(phi(3), closeTo(0.9986501, 1e-6));
      expect(phi(double.infinity), 1);
      expect(phi(double.negativeInfinity), 0);
      expect(phi(-8), lessThan(1e-12));
    });
  });

  group('garmentSizes', () {
    test('jeans W×L from waist and inseam inches, nearest inch', () {
      final g = SizeRecommender.garmentSizes(
        resultWith({BodyPart.waist: 86.4, BodyPart.inseam: 81.3}),
      );
      expect(g.jeans, 'W34 L32');
      expect(g.shirt, isNull);
      expect(g.hasAny, isTrue);
    });

    test('shirt collar × sleeve from neck (½ in) and shirt sleeve (1 in)',
        () {
      final g = SizeRecommender.garmentSizes(
        resultWith({BodyPart.neck: 39.4, BodyPart.shirtSleeve: 86.4}),
      );
      expect(g.shirt, '15½ × 34');
      expect(g.jeans, isNull);
    });

    test('both garments at once', () {
      final g = SizeRecommender.garmentSizes(resultWith({
        BodyPart.waist: 86.4,
        BodyPart.inseam: 81.3,
        BodyPart.neck: 39.4,
        BodyPart.shirtSleeve: 86.4,
        BodyPart.chest: 100, // irrelevant to garments
      }));
      expect(g, const GarmentSizes(jeans: 'W34 L32', shirt: '15½ × 34'));
    });

    test('null when a needed part is missing', () {
      expect(
        SizeRecommender.garmentSizes(resultWith({BodyPart.waist: 86.4})),
        GarmentSizes.none,
      );
      expect(
        SizeRecommender.garmentSizes(resultWith({BodyPart.inseam: 81.3}))
            .jeans,
        isNull,
      );
      expect(
        SizeRecommender.garmentSizes(resultWith({BodyPart.neck: 39.4})).shirt,
        isNull,
      );
      expect(
        SizeRecommender.garmentSizes(
                resultWith({BodyPart.shirtSleeve: 86.4}))
            .shirt,
        isNull,
      );
      final none = SizeRecommender.garmentSizes(resultWith({}));
      expect(none.hasAny, isFalse);
      expect(none, GarmentSizes.none);
    });

    test('non-finite or non-positive values count as missing', () {
      expect(
        SizeRecommender.garmentSizes(
          resultWith({BodyPart.waist: double.nan, BodyPart.inseam: 81.3}),
        ).jeans,
        isNull,
      );
      expect(
        SizeRecommender.garmentSizes(
          resultWith({BodyPart.neck: 0, BodyPart.shirtSleeve: 86.4}),
        ).shirt,
        isNull,
      );
    });

    test('whole-inch collars drop the half', () {
      // 40.64 cm = 16.00 in; 38.5 cm = 15.16 in -> 15; 39.0 cm = 15.35 -> 15½.
      String collar(double neckCm) => SizeRecommender.garmentSizes(
            resultWith({BodyPart.neck: neckCm, BodyPart.shirtSleeve: 86.4}),
          ).shirt!;
      expect(collar(40.64), '16 × 34');
      expect(collar(38.5), '15 × 34');
      expect(collar(39.0), '15½ × 34');
      expect(SizeRecommender.formatHalfInches(15.5), '15½');
      expect(SizeRecommender.formatHalfInches(16.0), '16');
      expect(SizeRecommender.formatHalfInches(17.5), '17½');
    });

    test('nearest-inch rounding of waist and inseam', () {
      // 87.6 cm = 34.49 in -> 34; 87.7 cm = 34.53 in -> 35.
      // 83.8 cm = 32.99 in -> 33; 80.1 cm = 31.54 in -> 32;
      // 80.0 cm = 31.496 in -> 31.
      String jeans(double waist, double inseam) =>
          SizeRecommender.garmentSizes(
            resultWith({BodyPart.waist: waist, BodyPart.inseam: inseam}),
          ).jeans!;
      expect(jeans(87.6, 83.8), 'W34 L33');
      expect(jeans(87.7, 80.1), 'W35 L32');
      expect(jeans(87.7, 80.0), 'W35 L31');
    });

    test('fit rounds girths down (slim) or up (relaxed); lengths unchanged',
        () {
      final r = resultWith({
        BodyPart.waist: 87.6, // 34.49 in
        BodyPart.inseam: 83.8, // 32.99 in
        BodyPart.neck: 39.4, // 15.51 in
        BodyPart.shirtSleeve: 86.4, // 34.02 in
      });
      final regular = SizeRecommender.garmentSizes(r);
      final slim =
          SizeRecommender.garmentSizes(r, fit: FitPreference.slim);
      final relaxed =
          SizeRecommender.garmentSizes(r, fit: FitPreference.relaxed);
      expect(regular, const GarmentSizes(jeans: 'W34 L33', shirt: '15½ × 34'));
      expect(slim, const GarmentSizes(jeans: 'W34 L33', shirt: '15½ × 34'));
      expect(relaxed, const GarmentSizes(jeans: 'W35 L33', shirt: '16 × 34'));

      // Just over the half: regular rounds up, slim holds the smaller size.
      final over = resultWith({
        BodyPart.waist: 87.7, // 34.53 in
        BodyPart.inseam: 83.8,
        BodyPart.neck: 39.0, // 15.35 in -> 15½ nearest, 15 slim, 15½ relaxed
        BodyPart.shirtSleeve: 86.4,
      });
      expect(SizeRecommender.garmentSizes(over).jeans, 'W35 L33');
      expect(
        SizeRecommender.garmentSizes(over, fit: FitPreference.slim),
        const GarmentSizes(jeans: 'W34 L33', shirt: '15 × 34'),
      );
      expect(
        SizeRecommender.garmentSizes(over, fit: FitPreference.relaxed).shirt,
        '15½ × 34',
      );
    });

    test('GarmentSizes value semantics', () {
      const a = GarmentSizes(jeans: 'W32 L32', shirt: '15 × 33');
      const b = GarmentSizes(jeans: 'W32 L32', shirt: '15 × 33');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const GarmentSizes(jeans: 'W32 L32')));
      expect(a.toString(), contains('W32 L32'));
    });
  });

  group('formatProbabilities', () {
    test('two heaviest sizes, most likely first, rounded percentages', () {
      expect(
        SizeRecommender.formatProbabilities({
          'XS': 0.001,
          'S': 0.216,
          'M': 0.783,
          'L': 0.0,
          'XL': 0.0,
          'XXL': 0.0,
        }),
        'M (78%) · S (22%)',
      );
      expect(
        SizeRecommender.formatProbabilities({'M': 0.22, 'L': 0.78}),
        'L (78%) · M (22%)',
      );
    });

    test('a runner-up under 5% is dropped; the leader is always shown', () {
      expect(
        SizeRecommender.formatProbabilities({'S': 0.03, 'M': 0.97}),
        'M (97%)',
      );
      expect(
        SizeRecommender.formatProbabilities({'M': 1.0}),
        'M (100%)',
      );
    });

    test('max limits the entries', () {
      expect(
        SizeRecommender.formatProbabilities(
          {'S': 0.31, 'M': 0.4, 'L': 0.29},
          max: 3,
        ),
        'M (40%) · S (31%) · L (29%)',
      );
    });

    test('empty map gives an empty string', () {
      expect(SizeRecommender.formatProbabilities({}), '');
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

    test('exact-boundary ties in the probabilistic path resolve like '
        'recommend()', () {
      // Slim on 97 centres the distribution exactly on the S/M bound (94):
      // S and M carry equal mass; the letter stays M, as in recommend().
      final slim = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.chest: 97}, sd: 1),
        Sex.male,
        fit: FitPreference.slim,
      );
      expect(slim.topSize, 'M');
      expect(slim.topProbabilities['S'],
          closeTo(slim.topProbabilities['M']!, 1e-9));
      final relaxed = SizeRecommender.recommendWithProbabilities(
        resultWith({BodyPart.chest: 99}, sd: 1),
        Sex.male,
        fit: FitPreference.relaxed,
      );
      expect(relaxed.topSize, 'L');
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
