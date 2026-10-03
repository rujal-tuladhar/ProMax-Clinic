import 'dart:math' as math;

import '../models/models.dart';

/// Clothing-size suggestion derived from a [MeasurementResult].
class SizeRecommendation {
  /// Suggested top size, driven by chest circumference (e.g. "M").
  final String topSize;

  /// Suggested bottom size: the LARGER of the waist-driven and hip-driven
  /// letters, because bottoms must clear the bigger of the two girths.
  final String bottomSize;

  /// Size letter per body part ("–" for parts that were not measured and for
  /// parts the generic charts do not size — only chest, waist and hip have
  /// a chart). Always has an entry for every [BodyPart].
  final Map<BodyPart, String> perPart;

  /// Probability mass per size letter for the top (chest), keys in chart
  /// order XS..XXL, values summing to 1. Empty when the chest was not
  /// measured or when the recommendation came from [SizeRecommender.recommend]
  /// (which does not compute probabilities).
  final Map<String, double> topProbabilities;

  /// Probability mass per size letter for the bottom; see
  /// [SizeRecommender.recommendWithProbabilities] for which distribution it
  /// is. Empty when neither waist nor hip was measured.
  final Map<String, double> bottomProbabilities;

  const SizeRecommendation({
    required this.topSize,
    required this.bottomSize,
    required this.perPart,
    this.topProbabilities = const {},
    this.bottomProbabilities = const {},
  });
}

/// Garment-scale sizes read straight off the body measurements, in the
/// imperial labels shops print on the garment.
///
/// * [jeans] — `'W34 L32'`: waist circumference in inches (nearest inch) and
///   inseam in inches (nearest inch).
/// * [shirt] — `'15½ × 34'`: dress-shirt collar from the neck circumference
///   (nearest ½ inch) and sleeve from the centre-back-to-wrist shirt sleeve
///   (nearest inch).
///
/// Each is null when either of the parts it needs is missing from the result.
class GarmentSizes {
  final String? jeans;
  final String? shirt;

  const GarmentSizes({this.jeans, this.shirt});

  /// Neither garment could be sized.
  static const GarmentSizes none = GarmentSizes();

  /// True when at least one garment line is available.
  bool get hasAny => jeans != null || shirt != null;

  @override
  bool operator ==(Object other) =>
      other is GarmentSizes && other.jeans == jeans && other.shirt == shirt;

  @override
  int get hashCode => Object.hash(jeans, shirt);

  @override
  String toString() => 'GarmentSizes(jeans: $jeans, shirt: $shirt)';
}

/// Placeholder shown for a part that has no measurement or no chart.
const String _missing = '–';

/// Size letters in ascending order.
const List<String> _sizes = ['XS', 'S', 'M', 'L', 'XL', 'XXL'];

/// Upper bounds (exclusive, cm) for XS..XL; anything at or above the last
/// bound is XXL. A measurement equal to a bound belongs to the NEXT size
/// (lower-inclusive ranges), so e.g. a male chest of exactly 94 cm is M.
class _Chart {
  final List<double> upperBounds; // length 5: XS,S,M,L,XL cutoffs

  const _Chart(this.upperBounds);

  /// Index into [_sizes] of the band containing [cm].
  int indexFor(double cm) {
    for (var i = 0; i < upperBounds.length; i++) {
      if (cm < upperBounds[i]) return i;
    }
    return upperBounds.length;
  }

  String sizeFor(double cm) => _sizes[indexFor(cm)];

  /// Probability mass per size letter for a measurement distributed
  /// N([centre], [sd]²): Φ((hi − centre)/sd) − Φ((lo − centre)/sd) for each
  /// band, with the XS lower edge at −∞ and the XXL upper edge at +∞, so the
  /// masses telescope to exactly 1 (up to floating-point rounding). Keys are
  /// in chart order.
  Map<String, double> massFor(double centre, double sd) {
    assert(_sizes.length == upperBounds.length + 1);
    final out = <String, double>{};
    var lower = 0.0;
    for (var i = 0; i < _sizes.length; i++) {
      final upper = i < upperBounds.length
          ? SizeRecommender.normalCdf((upperBounds[i] - centre) / sd)
          : 1.0;
      out[_sizes[i]] = math.max(0.0, upper - lower);
      lower = upper;
    }
    return out;
  }
}

/// Embedded size charts, cm.
///
/// Source reasoning: values are centred on widely used international
/// ready-to-wear charts (EN 13402 pictogram ranges and the published size
/// guides of large multi-brand retailers such as ASOS/Uniqlo/H&M, which
/// agree within a few cm). Men's charts use 8 cm chest steps around a
/// 94–102 cm "M"; men's waist runs ~23 cm below chest; men's hip ~2 cm
/// above chest. Women's charts shift chest (bust) down ~6 cm, waist down
/// ~17 cm relative to men's, and keep hip close to the men's chest chart
/// (women's hip girth per size ≈ bust + 6 cm). These are starting points
/// for an in-app brand-agnostic suggestion, not a guarantee of fit for a
/// specific label. Only the torso girths ([kTorsoParts]) have a chart; the
/// v2 parts (neck, shoulder, sleeves, inseam, thigh) feed garment sizes
/// ([SizeRecommender.garmentSizes]) and the brand charts instead.
const Map<Sex, Map<BodyPart, _Chart>> _charts = {
  Sex.male: {
    // XS<86, S 86–94, M 94–102, L 102–110, XL 110–118, XXL>=118
    BodyPart.chest: _Chart([86, 94, 102, 110, 118]),
    // XS<71, S 71–79, M 79–87, L 87–95, XL 95–103, XXL>=103
    BodyPart.waist: _Chart([71, 79, 87, 95, 103]),
    // XS<88, S 88–96, M 96–104, L 104–112, XL 112–120, XXL>=120
    BodyPart.hip: _Chart([88, 96, 104, 112, 120]),
  },
  Sex.female: {
    // XS<80, S 80–88, M 88–96, L 96–104, XL 104–112, XXL>=112
    BodyPart.chest: _Chart([80, 88, 96, 104, 112]),
    // XS<62, S 62–70, M 70–78, L 78–86, XL 86–94, XXL>=94
    BodyPart.waist: _Chart([62, 70, 78, 86, 94]),
    // XS<86, S 86–94, M 94–102, L 102–110, XL 110–118, XXL>=118
    BodyPart.hip: _Chart([86, 94, 102, 110, 118]),
  },
};

/// Maps measured circumferences to size letters using embedded charts.
class SizeRecommender {
  SizeRecommender._();

  /// Magnitude of the chart shift applied for a non-regular [FitPreference],
  /// in cm. 3 cm is well under half of one 8 cm size step, so it only moves
  /// measurements that sit near a boundary — a comfortably mid-range value
  /// reads the same size under every preference.
  static const double fitBiasCm = 3.0;

  /// Floor on the standard deviation used for size probabilities, cm. Even a
  /// perfectly repeatable camera estimate is not a tape measure, and the
  /// charts themselves are only good to about a centimetre.
  static const double minSdCm = 1.0;

  /// Signed offset (cm) added to each measurement BEFORE the chart lookup:
  /// -3 for slim, 0 for regular, +3 for relaxed.
  static double biasFor(FitPreference fit) => switch (fit) {
        FitPreference.slim => -fitBiasCm,
        FitPreference.regular => 0,
        FitPreference.relaxed => fitBiasCm,
      };

  /// Standard deviation used for [measurement]'s size probabilities:
  /// `max(stdDevCm, minSdCm)`; a NaN/infinite spread reads as [minSdCm].
  static double sdFor(PartMeasurement measurement) {
    final sd = measurement.stdDevCm;
    if (!sd.isFinite) return minSdCm;
    return math.max(sd, minSdCm);
  }

  /// Recommends sizes for [result] using the chart for [sex].
  ///
  /// [Sex.other] uses the midpoint of the male and female chart bounds
  /// (a unisex compromise). Missing parts fall back to "–"; a missing
  /// chest yields topSize "–", and the bottom size uses whichever of
  /// waist/hip is available (or "–" when neither is). Parts without a
  /// generic chart (everything outside [kTorsoParts]) always read "–" —
  /// [perPart] still has an entry for every [BodyPart].
  ///
  /// [fit] biases the lookup, not the measurement: with [FitPreference.slim]
  /// every value is shifted by -[fitBiasCm] before lookup, so a measurement
  /// less than 3 cm ABOVE a size boundary rounds DOWN to the smaller size;
  /// with [FitPreference.relaxed] it is shifted by +[fitBiasCm], so a value
  /// up to 3 cm BELOW a boundary rounds UP to the larger size (the asymmetry
  /// at exactly 3 cm follows from the lower-inclusive ranges).
  /// [FitPreference.regular] looks up the raw value. Example (male chest,
  /// M = 94–102): 95 cm reads M regular, S slim, M relaxed; 100 cm reads M
  /// regular, M slim, L relaxed; 98 cm reads M under every preference.
  ///
  /// The returned probability maps are empty; use
  /// [recommendWithProbabilities] for them.
  static SizeRecommendation recommend(
    MeasurementResult result,
    Sex sex, {
    FitPreference fit = FitPreference.regular,
  }) {
    final bias = biasFor(fit);
    final perPart = <BodyPart, String>{};
    for (final part in BodyPart.values) {
      final value = result.valueFor(part);
      perPart[part] = value == null || !_hasChart(part)
          ? _missing
          : _chartFor(sex, part).sizeFor(value + bias);
    }

    final waistSize = perPart[BodyPart.waist]!;
    final hipSize = perPart[BodyPart.hip]!;
    return SizeRecommendation(
      topSize: perPart[BodyPart.chest]!,
      bottomSize: _largerSize(waistSize, hipSize),
      perPart: perPart,
    );
  }

  /// Like [recommend], plus a probability distribution over the size letters
  /// for the top and the bottom.
  ///
  /// Each charted part is modelled as a normal distribution centred on its
  /// fit-shifted value (`valueCm + biasFor(fit)`, so letter and distribution
  /// agree) with `sd = max(stdDevCm, minSdCm)`; the mass inside each chart
  /// band is the probability of that letter (see `_Chart.massFor`). The
  /// letter reported for the part is the MODAL band (highest mass), so the
  /// headline size always has the largest probability. For any realistic
  /// spread (sd ≲ 3 cm) the modal band is the band containing the shifted
  /// value, i.e. exactly [recommend]'s letter; only a very noisy part within
  /// a few millimetres of the open-ended XS or XXL edge can differ, and
  /// exact ties resolve to [recommend]'s letter.
  ///
  /// [SizeRecommendation.topProbabilities] is the chest distribution.
  /// [SizeRecommendation.bottomProbabilities] follows the larger-of-waist/hip
  /// rule: it is the distribution of the part that DECIDED the bottom size
  /// (the one with the larger letter; on equal letters the waist, since
  /// bottoms are sized by waist first), not a joint distribution — the two
  /// girths share the same scale error and are strongly correlated on a real
  /// body, so an independence-based max distribution would overstate the
  /// chance of the larger size and could disagree with the letter. When only
  /// one of waist/hip was measured, that part's distribution is used; when
  /// neither was, the map is empty, as is the top map without a chest.
  static SizeRecommendation recommendWithProbabilities(
    MeasurementResult result,
    Sex sex, {
    FitPreference fit = FitPreference.regular,
  }) {
    final bias = biasFor(fit);
    final perPart = <BodyPart, String>{};
    final distributions = <BodyPart, Map<String, double>>{};
    for (final part in BodyPart.values) {
      final measurement = result.partFor(part);
      if (measurement == null || !_hasChart(part)) {
        perPart[part] = _missing;
        continue;
      }
      final chart = _chartFor(sex, part);
      final centre = measurement.valueCm + bias;
      final mass = chart.massFor(centre, sdFor(measurement));
      perPart[part] = _modalSize(mass, chart.sizeFor(centre));
      distributions[part] = Map.unmodifiable(mass);
    }

    final waistSize = perPart[BodyPart.waist]!;
    final hipSize = perPart[BodyPart.hip]!;
    final waistMass = distributions[BodyPart.waist];
    final hipMass = distributions[BodyPart.hip];
    final Map<String, double> bottomMass;
    if (waistMass == null) {
      bottomMass = hipMass ?? const {};
    } else if (hipMass == null) {
      bottomMass = waistMass;
    } else {
      // The part whose letter won decides; waist on a tie.
      bottomMass = _sizes.indexOf(waistSize) >= _sizes.indexOf(hipSize)
          ? waistMass
          : hipMass;
    }

    return SizeRecommendation(
      topSize: perPart[BodyPart.chest]!,
      bottomSize: _largerSize(waistSize, hipSize),
      perPart: perPart,
      topProbabilities: distributions[BodyPart.chest] ?? const {},
      bottomProbabilities: bottomMass,
    );
  }

  /// Garment-label sizes from the parts that have them; see [GarmentSizes].
  ///
  /// Conversions: `inches = cm / 2.54`. Jeans waist and inseam round to the
  /// nearest inch, the collar to the nearest ½ inch, the shirt sleeve to the
  /// nearest inch. A garment is null when either part it needs is absent
  /// (or non-finite / non-positive).
  ///
  /// Fit preference: garment scales step by 1 in (jeans) or ½ in (collar), so
  /// the 3 cm chart bias used for letter sizes would jump a collar by two
  /// sizes. Instead [fit] is applied as the ROUNDING RULE for the girths:
  /// slim rounds the waist / collar DOWN to the next step, regular to the
  /// nearest, relaxed UP — the same "smaller / as measured / larger when
  /// between sizes" meaning as the letter charts. Lengths (inseam, sleeve)
  /// never depend on fit; a leg does not get longer in relaxed fit.
  static GarmentSizes garmentSizes(
    MeasurementResult result, {
    FitPreference fit = FitPreference.regular,
  }) {
    final waist = _usable(result.valueFor(BodyPart.waist));
    final inseam = _usable(result.valueFor(BodyPart.inseam));
    final neck = _usable(result.valueFor(BodyPart.neck));
    final sleeve = _usable(result.valueFor(BodyPart.shirtSleeve));

    String? jeans;
    if (waist != null && inseam != null) {
      final w = _roundToStep(cmToInches(waist), 1, fit);
      final l = _roundToStep(cmToInches(inseam), 1, FitPreference.regular);
      jeans = 'W${w.round()} L${l.round()}';
    }

    String? shirt;
    if (neck != null && sleeve != null) {
      final collar = _roundToStep(cmToInches(neck), 0.5, fit);
      final s = _roundToStep(cmToInches(sleeve), 1, FitPreference.regular);
      shirt = '${formatHalfInches(collar)} × ${s.round()}';
    }

    return GarmentSizes(jeans: jeans, shirt: shirt);
  }

  /// Formats a probability map as `'M (78%) · L (22%)'`: the heaviest [max]
  /// sizes that carry at least [minShare] of the mass (the heaviest one is
  /// always shown), most likely first. Empty string for an empty map.
  static String formatProbabilities(
    Map<String, double> probabilities, {
    int max = 2,
    double minShare = 0.05,
  }) {
    if (probabilities.isEmpty) return '';
    final byMass = probabilities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final shown = <MapEntry<String, double>>[
      byMass.first,
      for (final e in byMass.skip(1).take(math.max(0, max - 1)))
        if (e.value >= minShare) e,
    ];
    return [
      for (final e in shown) '${e.key} (${(e.value * 100).round()}%)',
    ].join(' · ');
  }

  /// A collar size in inches with the half written as `½`: 15.5 → `15½`,
  /// 16.0 → `16`.
  static String formatHalfInches(double inches) {
    final whole = inches.floor();
    final frac = inches - whole;
    if (frac >= 0.75) return '${whole + 1}';
    if (frac >= 0.25) return '$whole½';
    return '$whole';
  }

  /// Standard normal CDF Φ(z), via [erf].
  static double normalCdf(double z) {
    if (z.isNaN) return double.nan;
    if (z == double.infinity) return 1;
    if (z == double.negativeInfinity) return 0;
    return 0.5 * (1 + erf(z / math.sqrt2));
  }

  /// Error function, Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7), pure
  /// Dart. Odd: erf(−x) = −erf(x); erf(0) is exactly 0.
  static double erf(double x) {
    if (x.isNaN) return double.nan;
    if (x == 0) return 0;
    if (x.isInfinite) return x.sign;
    const p = 0.3275911;
    const a1 = 0.254829592;
    const a2 = -0.284496736;
    const a3 = 1.421413741;
    const a4 = -1.453152027;
    const a5 = 1.061405429;
    final sign = x < 0 ? -1.0 : 1.0;
    final ax = x.abs();
    final t = 1 / (1 + p * ax);
    final poly = ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t;
    return sign * (1 - poly * math.exp(-ax * ax));
  }

  static bool _hasChart(BodyPart part) => kTorsoParts.contains(part);

  static _Chart _chartFor(Sex sex, BodyPart part) {
    switch (sex) {
      case Sex.male:
        return _charts[Sex.male]![part]!;
      case Sex.female:
        return _charts[Sex.female]![part]!;
      case Sex.other:
        final m = _charts[Sex.male]![part]!.upperBounds;
        final f = _charts[Sex.female]![part]!.upperBounds;
        return _Chart([
          for (var i = 0; i < m.length; i++) (m[i] + f[i]) / 2,
        ]);
    }
  }

  /// The letter with the largest mass; ties (within 1e-6) go to
  /// [pointEstimate], the band containing the shifted value.
  static String _modalSize(Map<String, double> mass, String pointEstimate) {
    var best = pointEstimate;
    var bestMass = mass[pointEstimate] ?? double.negativeInfinity;
    for (final e in mass.entries) {
      if (e.value > bestMass + 1e-6) {
        best = e.key;
        bestMass = e.value;
      }
    }
    return best;
  }

  /// The larger of two size letters; a missing ("–") letter defers to the
  /// other one.
  static String _largerSize(String a, String b) {
    final ia = _sizes.indexOf(a);
    final ib = _sizes.indexOf(b);
    if (ia < 0) return b;
    if (ib < 0) return a;
    return _sizes[ia >= ib ? ia : ib];
  }

  /// [value] when it is a finite positive length, else null (treated as
  /// absent).
  static double? _usable(double? value) =>
      value != null && value.isFinite && value > 0 ? value : null;

  /// Rounds [x] to a multiple of [step]: down for slim, nearest for regular,
  /// up for relaxed.
  static double _roundToStep(double x, double step, FitPreference fit) {
    final q = x / step;
    final r = switch (fit) {
      FitPreference.slim => q.floorToDouble(),
      FitPreference.regular => q.roundToDouble(),
      FitPreference.relaxed => q.ceilToDouble(),
    };
    return r * step;
  }
}
