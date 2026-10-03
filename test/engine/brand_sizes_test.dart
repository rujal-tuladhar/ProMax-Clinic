import 'dart:io';

import 'package:fitsize/engine/brand_sizes.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shipped asset, read from disk (flutter test runs from the package
/// root).
final String kAssetJson =
    File('assets/data/brand_charts.json').readAsStringSync();

MeasurementResult resultWith(
  Map<BodyPart, double> values, {
  double sd = 1.5,
}) =>
    MeasurementResult(
      parts: [
        for (final e in values.entries)
          PartMeasurement(
            part: e.key,
            valueCm: e.value,
            stdDevCm: sd,
            confidence: 0.9,
          ),
      ],
      scaleCmPerPx: 0.14,
      frontFrameCount: 5,
      sideFrameCount: 5,
      timestamp: DateTime(2026, 10, 3),
    );

/// Synthetic result from the worked example: chest 90, waist 76, hip 100.
final MeasurementResult kWorked = resultWith({
  BodyPart.chest: 90,
  BodyPart.waist: 76,
  BodyPart.hip: 100,
});

BrandChart rangeChart(List<(String, double, double)> bands) => BrandChart(
      gender: 'women',
      category: 'tops',
      measure: 'waist',
      unit: 'cm',
      sizes: [
        for (final (label, lo, hi) in bands)
          SizeBand(label: label, min: lo, max: hi),
      ],
    );

BrandChart pointChart(List<(String, double)> points) => rangeChart([
      for (final (label, v) in points) (label, v, v),
    ]);

double sum(Iterable<double> xs) => xs.fold(0.0, (a, b) => a + b);

String argmax(Map<String, double> m) =>
    m.entries.reduce((a, b) => b.value > a.value ? b : a).key;

void main() {
  late BrandCatalog catalog;
  late BrandSizeResolver resolver;

  setUpAll(() {
    catalog = BrandCatalog.fromJson(kAssetJson);
    resolver = BrandSizeResolver(catalog);
  });

  BrandChart chartOf(String brand, String gender, String category,
      String measure) {
    final b = catalog.brandNamed(brand);
    expect(b, isNotNull, reason: '$brand missing from catalog');
    return b!.charts.singleWhere((c) =>
        c.gender == gender && c.category == category && c.measure == measure);
  }

  group('shipped asset', () {
    test('parses with the contract version and 12 brands', () {
      expect(catalog.version, '2026.10');
      expect(catalog.brands, hasLength(12));
      expect(
        catalog.brands.map((b) => b.brand),
        containsAll([
          'Nike',
          'Adidas',
          'Zara',
          'H&M',
          'Uniqlo',
          "Levi's",
          'Gap',
          'Lululemon',
          'Under Armour',
          'Amazon Essentials',
          'ASOS',
          'Mango',
        ]),
      );
    });

    test('every brand carries provenance, a confidence tag and >= 1 chart',
        () {
      for (final b in catalog.brands) {
        expect(b.charts, isNotEmpty, reason: b.brand);
        expect(b.source, startsWith('https://'), reason: b.brand);
        expect(b.retrieved, '2026-10-03', reason: b.brand);
        expect(['high', 'medium', 'low'], contains(b.confidence),
            reason: b.brand);
        expect(b.notes, isNotEmpty, reason: b.brand);
      }
    });

    test('confidence tags follow the research assessment', () {
      String conf(String name) => catalog.brandNamed(name)!.confidence;
      expect(conf('Nike'), 'high');
      expect(conf('Adidas'), 'high');
      expect(conf('H&M'), 'high');
      expect(conf('Gap'), 'medium');
      expect(conf('Under Armour'), 'medium');
      expect(conf('ASOS'), 'medium');
      expect(conf('Uniqlo'), 'medium');
      expect(conf("Levi's"), 'medium');
      expect(conf('Mango'), 'medium');
      expect(conf('Zara'), 'low');
      expect(conf('Lululemon'), 'low');
      expect(conf('Amazon Essentials'), 'low');
    });

    test('charts are well-formed: cm, known enums, unique ordered sizes', () {
      for (final b in catalog.brands) {
        for (final c in b.charts) {
          final where = '${b.brand} ${c.gender}/${c.category}/${c.measure}';
          expect(c.unit, 'cm', reason: where);
          expect(['men', 'women'], contains(c.gender), reason: where);
          expect(['tops', 'bottoms'], contains(c.category), reason: where);
          expect(['chest', 'waist', 'hip', 'inseam'], contains(c.measure),
              reason: where);
          expect(c.sizes, isNotEmpty, reason: where);
          expect(c.labels.toSet(), hasLength(c.sizes.length),
              reason: '$where has duplicate labels');
          for (final s in c.sizes) {
            expect(s.max, greaterThanOrEqualTo(s.min), reason: '$where $s');
          }
          // Circumference charts are published smallest-first and never
          // overlap; inseam columns need not be monotonic.
          if (c.measure != 'inseam') {
            for (var i = 1; i < c.sizes.length; i++) {
              expect(c.sizes[i].min, greaterThanOrEqualTo(c.sizes[i - 1].max),
                  reason: '$where: ${c.sizes[i - 1]} then ${c.sizes[i]}');
            }
          }
        }
      }
    });

    test('the implausible H&M men\'s scrape was dropped', () {
      expect(catalog.brandNamed('H&M')!.hasGender('men'), isFalse);
      expect(catalog.brandNamed('H&M')!.hasGender('women'), isTrue);
    });

    test('point charts are stored with min == max and flagged', () {
      expect(chartOf('Zara', 'women', 'tops', 'chest').isPointChart, isTrue);
      expect(chartOf('Mango', 'women', 'tops', 'waist').isPointChart, isTrue);
      expect(chartOf("Levi's", 'women', 'bottoms', 'waist').isPointChart,
          isTrue);
      expect(chartOf('Nike', 'men', 'tops', 'chest').isPointChart, isFalse);
      expect(chartOf('Gap', 'women', 'tops', 'chest').isPointChart, isFalse);
    });

    test('inseam charts are kept', () {
      expect(chartOf('Nike', 'men', 'bottoms', 'inseam').sizes, hasLength(6));
      expect(chartOf('Adidas', 'men', 'bottoms', 'inseam').isPointChart,
          isTrue);
    });

    test('rejects documents that do not match the shape', () {
      expect(() => BrandCatalog.fromJson('[]'), throwsFormatException);
      expect(() => BrandCatalog.fromJson('{"version": 1, "brands": []}'),
          throwsFormatException);
      expect(
        () => BrandCatalog.fromJson(
            '{"version":"x","brands":[{"brand":"B","charts":[]}]}'),
        throwsFormatException,
      );
      expect(
        () => BrandCatalog.fromJson('{"version":"x","brands":[{"brand":"B",'
            '"charts":[{"gender":"men","category":"tops","measure":"chest",'
            '"sizes":[{"label":"M","min":100,"max":96}]}]}]}'),
        throwsFormatException,
      );
    });
  });

  group('lookup on range charts', () {
    test('inside a band: that size, not between', () {
      // Nike men chest M = 96–104; 100 is 4 cm from either edge.
      final l = resolver.lookup(chartOf('Nike', 'men', 'tops', 'chest'), 100);
      expect(l.label, 'M');
      expect(l.between, isFalse);
      expect(l.alternative, isNull);
    });

    test('inside a gap: nearest band, flagged between', () {
      // Amazon Essentials women waist: M 71.1–73.7, L 77.5–81.3, gap midpoint
      // 75.6.
      final chart = chartOf('Amazon Essentials', 'women', 'tops', 'waist');
      final nearM = resolver.lookup(chart, 74.5);
      expect(nearM.label, 'M');
      expect(nearM.between, isTrue);
      expect(nearM.alternative, 'L');
      expect(nearM.betweenPair, ('M', 'L'));

      final nearL = resolver.lookup(chart, 76);
      expect(nearL.label, 'L');
      expect(nearL.between, isTrue);
      expect(nearL.alternative, 'M');
      expect(nearL.betweenPair, ('M', 'L'));
    });

    test('boundary values are lower-inclusive', () {
      // Nike women chest S 83–90, M 90–97.
      final chart = chartOf('Nike', 'women', 'tops', 'chest');
      expect(resolver.lookup(chart, 89.99).label, 'S');
      expect(resolver.lookup(chart, 90).label, 'M');
    });

    test('within 1.5 cm of a boundary is between; further is not', () {
      // Nike women waist: S 67–74, M 74–81, L 81–88.
      final chart = chartOf('Nike', 'women', 'tops', 'waist');
      final near = resolver.lookup(chart, 75);
      expect(near.label, 'M');
      expect(near.between, isTrue);
      expect(near.alternative, 'S');
      expect(near.betweenPair, ('S', 'M'));

      final exactly = resolver.lookup(chart, 75.5);
      expect(exactly.between, isTrue, reason: '1.5 cm is inclusive');

      final mid = resolver.lookup(chart, 77.5);
      expect(mid.label, 'M');
      expect(mid.between, isFalse);
      expect(mid.alternative, isNull);

      final high = resolver.lookup(chart, 79.6);
      expect(high.label, 'M');
      expect(high.between, isTrue);
      expect(high.alternative, 'L');
    });

    test('values beyond the chart ends take the end size', () {
      final chart = chartOf('Nike', 'women', 'tops', 'chest'); // XS from 76
      expect(resolver.lookup(chart, 60).label, 'XS');
      expect(resolver.lookup(chart, 60).between, isFalse);
      expect(resolver.lookup(chart, 150).label, '2XL');
    });
  });

  group('lookup on point charts', () {
    test('nearest point with midpoint boundaries', () {
      // Zara women waist: XS 62, S 66, M 70, L 76, XL 82.
      final chart = chartOf('Zara', 'women', 'tops', 'waist');
      final exact = resolver.lookup(chart, 76);
      expect(exact.label, 'L');
      expect(exact.between, isFalse, reason: '3 cm from both midpoints');

      expect(resolver.lookup(chart, 72.9).label, 'M'); // midpoint M/L = 73
      expect(resolver.lookup(chart, 73).label, 'L'); // lower-inclusive
      expect(resolver.lookup(chart, 67.9).label, 'S'); // midpoint S/M = 68
      expect(resolver.lookup(chart, 68).label, 'M'); // on it -> larger size
    });

    test('close to a midpoint is between', () {
      // Mango women waist M 72, L 78 -> midpoint 75; 76 is 1 cm above it.
      final chart = chartOf('Mango', 'women', 'tops', 'waist');
      final l = resolver.lookup(chart, 76);
      expect(l.label, 'L');
      expect(l.between, isTrue);
      expect(l.alternative, 'M');
      expect(l.betweenPair, ('M', 'L'));
    });

    test('a point chart whose published order is not monotonic still works',
        () {
      // adidas men inseam: XS 81, S 81.5, M 82, L 82.5, XL 83, 2XL 82.5,
      // 3XL 82 — sorted by value before lookup.
      final chart = chartOf('Adidas', 'men', 'bottoms', 'inseam');
      final l = resolver.lookup(chart, 83.4);
      expect(l.label, 'XL');
      expect(sum(l.probabilities.values), closeTo(1, 1e-9));
    });
  });

  group('fit preference', () {
    test('bias is -3 / 0 / +3 cm', () {
      expect(BrandSizeResolver.biasFor(FitPreference.slim), -3);
      expect(BrandSizeResolver.biasFor(FitPreference.regular), 0);
      expect(BrandSizeResolver.biasFor(FitPreference.relaxed), 3);
    });

    test('flips a borderline case, leaves a mid-band case alone', () {
      // Nike women waist: S 67–74, M 74–81, L 81–88. 75 is 1 cm into M.
      final chart = chartOf('Nike', 'women', 'tops', 'waist');
      expect(resolver.lookup(chart, 75).label, 'M');
      expect(resolver.lookup(chart, 75, fit: FitPreference.slim).label, 'S');
      expect(
          resolver.lookup(chart, 75, fit: FitPreference.relaxed).label, 'M');

      // 80 is 1 cm below the M/L boundary.
      expect(resolver.lookup(chart, 80).label, 'M');
      expect(
          resolver.lookup(chart, 80, fit: FitPreference.relaxed).label, 'L');
      expect(resolver.lookup(chart, 80, fit: FitPreference.slim).label, 'M');

      // 77.5 is the centre of M: no preference moves it.
      for (final fit in FitPreference.values) {
        expect(resolver.lookup(chart, 77.5, fit: fit).label, 'M',
            reason: fit.name);
      }
    });

    test('omitting fit behaves like regular', () {
      final chart = chartOf('Adidas', 'men', 'tops', 'chest');
      final a = resolver.lookup(chart, 100.5);
      final b = resolver.lookup(chart, 100.5, fit: FitPreference.regular);
      expect(a.label, b.label);
      expect(a.between, b.between);
      expect(a.probabilities, b.probabilities);
    });
  });

  group('probabilities', () {
    test('sum to 1 and the best label carries the most mass', () {
      final l = resolver.lookup(chartOf('Nike', 'men', 'tops', 'chest'), 100,
          sdCm: 1.5);
      expect(sum(l.probabilities.values), closeTo(1, 1e-9));
      expect(argmax(l.probabilities), l.label);
      // M = 96–104 is ±2.67 sd around 100 -> ~99.2 %.
      expect(l.probabilities['M'], closeTo(0.9924, 0.0005));
      expect(l.probabilities.keys.toList(),
          chartOf('Nike', 'men', 'tops', 'chest').labels,
          reason: 'map keeps chart order');
    });

    test('a value on a shared boundary splits 50/50', () {
      final chart = rangeChart([('A', 80, 90), ('B', 90, 100)]);
      final l = resolver.lookup(chart, 90, sdCm: 2);
      expect(l.label, 'B');
      expect(l.between, isTrue);
      expect(l.alternative, 'A');
      expect(l.probabilities['A'], closeTo(0.5, 1e-7));
      expect(l.probabilities['B'], closeTo(0.5, 1e-7));
    });

    test('end bands extend to infinity', () {
      // Far below the first band: all the mass lands in it.
      final chart = rangeChart([('A', 80, 90), ('B', 90, 100)]);
      final l = resolver.lookup(chart, 20, sdCm: 1.5);
      expect(l.label, 'A');
      expect(l.probabilities['A'], closeTo(1, 1e-9));
      expect(l.probabilities['B'], closeTo(0, 1e-9));
    });

    test('point charts integrate between midpoints', () {
      // Points 70, 76, 82 -> boundaries 73, 79. Value 76, sd 3:
      // P(M) = Φ(1) - Φ(-1) ≈ 0.6827.
      final chart = pointChart([('S', 70), ('M', 76), ('L', 82)]);
      final l = resolver.lookup(chart, 76, sdCm: 3);
      expect(l.probabilities['M'], closeTo(0.6827, 0.0005));
      expect(l.probabilities['S'], closeTo(0.1587, 0.0005));
      expect(l.probabilities['L'], closeTo(0.1587, 0.0005));
    });

    test('sd is floored at 1 cm', () {
      final chart = chartOf('Nike', 'men', 'tops', 'chest');
      final tiny = resolver.lookup(chart, 100, sdCm: 0.01);
      final one = resolver.lookup(chart, 100, sdCm: 1.0);
      final zero = resolver.lookup(chart, 100, sdCm: 0);
      expect(tiny.probabilities, one.probabilities);
      expect(zero.probabilities, one.probabilities);
      // Wider sd spreads mass out of the best band.
      final wide = resolver.lookup(chart, 100, sdCm: 4);
      expect(wide.probabilities['M']!, lessThan(one.probabilities['M']!));
    });

    test('probabilities follow the fit-shifted value, so they agree with the '
        'label', () {
      final chart = chartOf('Nike', 'women', 'tops', 'waist');
      final slim = resolver.lookup(chart, 75, fit: FitPreference.slim);
      expect(slim.label, 'S');
      expect(argmax(slim.probabilities), 'S');
    });

    test('normal CDF and erf are accurate to ~1e-7', () {
      expect(BrandSizeResolver.normalCdf(0), closeTo(0.5, 1e-9));
      expect(BrandSizeResolver.normalCdf(1), closeTo(0.8413447, 2e-7));
      expect(BrandSizeResolver.normalCdf(-1.96), closeTo(0.0249979, 2e-7));
      expect(BrandSizeResolver.normalCdf(double.infinity), 1);
      expect(BrandSizeResolver.normalCdf(double.negativeInfinity), 0);
      expect(BrandSizeResolver.erf(0.5), closeTo(0.5204999, 2e-7));
      expect(BrandSizeResolver.erf(-0.5), closeTo(-0.5204999, 2e-7));
      expect(BrandSizeResolver.erf(3), closeTo(0.9999779, 2e-7));
    });

    test('formatSizeProbabilities renders the heaviest sizes in chart order',
        () {
      expect(formatSizeProbabilities({'S': 0.22, 'M': 0.78}), 'S 22% · M 78%');
      expect(
        formatSizeProbabilities({'S': 0.01, 'M': 0.78, 'L': 0.21}),
        'M 78% · L 21%',
      );
      expect(formatSizeProbabilities({'M': 1.0}), 'M 100%');
      expect(formatSizeProbabilities({}), '');
    });
  });

  group('matchAll', () {
    test('returns one match per brand, in catalog order, for every sex', () {
      for (final sex in Sex.values) {
        final matches = resolver.matchAll(kWorked, sex);
        expect(matches, hasLength(12), reason: sex.name);
        expect(
          matches.map((m) => m.brand.brand).toList(),
          catalog.brands.map((b) => b.brand).toList(),
          reason: sex.name,
        );
        for (final m in matches) {
          for (final l in [m.top, m.bottom]) {
            if (l == null) continue;
            expect(sum(l.probabilities.values), closeTo(1, 1e-9),
                reason: '${m.brand.brand} ${sex.name}');
          }
        }
      }
    });

    test('worked example: 76 cm waist is Nike M, Zara L, Amazon Essentials '
        'between M and L', () {
      final waist = kWorked.partFor(BodyPart.waist)!;
      SizeLookup waistAt(String brand) => resolver.lookup(
            BrandSizeResolver.chartFor(
                catalog.brandNamed(brand)!, 'women', 'bottoms', 'waist')!,
            waist.valueCm,
            sdCm: waist.stdDevCm,
          );

      final nike = waistAt('Nike');
      expect(nike.label, 'M');
      expect(nike.between, isFalse);

      final zara = waistAt('Zara');
      expect(zara.label, 'L');
      expect(zara.between, isFalse);

      final amazon = waistAt('Amazon Essentials');
      expect(amazon.between, isTrue);
      expect(amazon.betweenPair, ('M', 'L'));

      // And the same shows through matchAll's bottoms (hip 100 does not
      // out-rank the waist size at these three brands).
      final byBrand = {
        for (final m in resolver.matchAll(kWorked, Sex.female))
          m.brand.brand: m,
      };
      expect(byBrand['Nike']!.bottom!.label, 'M');
      expect(byBrand['Zara']!.bottom!.label, 'L');
      expect(byBrand['Amazon Essentials']!.bottom!.between, isTrue);
      expect(byBrand['Amazon Essentials']!.bottom!.betweenPair, ('M', 'L'));
    });

    test('female: women\'s charts; top from chest, bottom = larger of waist '
        'and hip', () {
      final byBrand = {
        for (final m in resolver.matchAll(kWorked, Sex.female))
          m.brand.brand: m,
      };
      final nike = byBrand['Nike']!;
      expect(nike.gender, 'women');
      // Chest 90 is exactly the Nike women S/M boundary -> M, between S.
      expect(nike.top!.label, 'M');
      expect(nike.top!.between, isTrue);
      expect(nike.top!.alternative, 'S');
      // Waist 76 -> M (74–81); hip 100 -> M (98–105).
      expect(nike.bottom!.label, 'M');
      expect(nike.note, isNull);

      // Uniqlo: waist 76 is the M/L boundary -> L; hip 100 -> M (96–102);
      // the larger (L) wins.
      final uniqlo = byBrand['Uniqlo']!;
      expect(uniqlo.bottom!.label, 'L');
      expect(uniqlo.bottom!.between, isTrue);

      // Levi's publishes bottoms only.
      final levis = byBrand["Levi's"]!;
      expect(levis.top, isNull);
      expect(levis.bottom, isNotNull);
      expect(levis.note, contains('No tops chart published'));

      // Under Armour has no women's chart at all.
      final ua = byBrand['Under Armour']!;
      expect(ua.top, isNull);
      expect(ua.bottom, isNull);
      expect(ua.note, "No women's chart published");
    });

    test('male: men\'s charts only', () {
      final byBrand = {
        for (final m in resolver.matchAll(kWorked, Sex.male)) m.brand.brand: m,
      };
      final nike = byBrand['Nike']!;
      expect(nike.gender, 'men');
      expect(nike.top!.label, 'S'); // chest 90 in S 88–96
      // Bottoms chart: waist 76 -> S (73–81), hip 100 -> M (96–104) -> M.
      expect(nike.bottom!.label, 'M');

      final ua = byBrand['Under Armour']!;
      expect(ua.top!.label, 'S'); // 86.4–94.0
      expect(ua.bottom!.label, 'S'); // waist 73.7–78.7
      expect(ua.note, 'Hip chart not published — waist only');

      final zara = byBrand['Zara']!;
      expect(zara.top, isNull);
      expect(zara.bottom, isNull);
      expect(zara.note, "No men's chart published");
    });

    test('other: women\'s charts first, men\'s when a brand has no women\'s',
        () {
      final byBrand = {
        for (final m in resolver.matchAll(kWorked, Sex.other)) m.brand.brand: m,
      };
      expect(byBrand['Nike']!.gender, 'women');
      expect(byBrand['Nike']!.top!.label, 'M');

      final ua = byBrand['Under Armour']!;
      expect(ua.gender, 'men');
      expect(ua.top!.label, 'S');
      expect(ua.bottom!.label, 'S');
      expect(ua.note, contains("Women's chart not published"));
      expect(ua.note, contains('Hip chart not published — waist only'));

      // Every brand can be sized for Sex.other (each has some chart).
      for (final m in byBrand.values) {
        expect(m.top != null || m.bottom != null, isTrue, reason: m.brand.brand);
      }
    });

    test('a bottoms chart is preferred over the body chart filed under tops',
        () {
      // Nike men publish both; bottoms waist starts at XS while tops waist
      // starts at S.
      final chart = BrandSizeResolver.chartFor(
          catalog.brandNamed('Nike')!, 'men', 'bottoms', 'waist')!;
      expect(chart.category, 'bottoms');
      expect(chart.sizes.first.label, 'XS');
      // Gap women publish one body chart (under tops): used for bottoms.
      final gap = BrandSizeResolver.chartFor(
          catalog.brandNamed('Gap')!, 'women', 'bottoms', 'waist')!;
      expect(gap.category, 'tops');
    });

    test('missing measurements are reported, not guessed', () {
      final chestOnly = resultWith({BodyPart.chest: 90});
      final nike = resolver.matchAll(chestOnly, Sex.female).first;
      expect(nike.brand.brand, 'Nike');
      expect(nike.top!.label, 'M');
      expect(nike.bottom, isNull);
      expect(nike.note, 'Waist and hip not measured');

      final waistOnly = resultWith({BodyPart.waist: 76});
      final nike2 = resolver.matchAll(waistOnly, Sex.female).first;
      expect(nike2.top, isNull);
      expect(nike2.bottom!.label, 'M');
      expect(nike2.note, 'Chest not measured · Hip not measured — waist only');
    });

    test('fit preference flows through to every brand', () {
      final byBrand = {
        for (final m in resolver.matchAll(kWorked, Sex.female,
            fit: FitPreference.slim))
          m.brand.brand: m,
      };
      // Nike women chest 90 - 3 = 87 -> S.
      expect(byBrand['Nike']!.top!.label, 'S');
      // Zara waist 76 - 3 = 73 -> exactly the M/L midpoint -> L; hip 97 ->
      // M (midpoint M/L at 101); larger L.
      expect(byBrand['Zara']!.bottom!.label, 'L');
    });

    test('uses each part\'s own stdDev for its probabilities', () {
      final precise = resultWith({BodyPart.chest: 100}, sd: 0.5);
      final loose = resultWith({BodyPart.chest: 100}, sd: 4);
      final p = resolver.matchAll(precise, Sex.male).first.top!;
      final l = resolver.matchAll(loose, Sex.male).first.top!;
      expect(p.probabilities['M']!, greaterThan(l.probabilities['M']!));
    });
  });
}
