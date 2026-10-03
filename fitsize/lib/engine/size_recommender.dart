import '../models/models.dart';

/// Clothing-size suggestion derived from a [MeasurementResult].
class SizeRecommendation {
  /// Suggested top size, driven by chest circumference (e.g. "M").
  final String topSize;

  /// Suggested bottom size: the LARGER of the waist-driven and hip-driven
  /// letters, because bottoms must clear the bigger of the two girths.
  final String bottomSize;

  /// Size letter per measured part ("–" for parts that were not measured).
  final Map<BodyPart, String> perPart;

  const SizeRecommendation({
    required this.topSize,
    required this.bottomSize,
    required this.perPart,
  });
}

/// Placeholder shown for a part that has no measurement.
const String _missing = '–';

/// Size letters in ascending order.
const List<String> _sizes = ['XS', 'S', 'M', 'L', 'XL', 'XXL'];

/// Upper bounds (exclusive, cm) for XS..XL; anything at or above the last
/// bound is XXL. A measurement equal to a bound belongs to the NEXT size
/// (lower-inclusive ranges), so e.g. a male chest of exactly 94 cm is M.
class _Chart {
  final List<double> upperBounds; // length 5: XS,S,M,L,XL cutoffs

  const _Chart(this.upperBounds);

  String sizeFor(double cm) {
    for (var i = 0; i < upperBounds.length; i++) {
      if (cm < upperBounds[i]) return _sizes[i];
    }
    return _sizes.last;
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
/// specific label.
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

  /// Signed offset (cm) added to each measurement BEFORE the chart lookup:
  /// -3 for slim, 0 for regular, +3 for relaxed.
  static double biasFor(FitPreference fit) => switch (fit) {
        FitPreference.slim => -fitBiasCm,
        FitPreference.regular => 0,
        FitPreference.relaxed => fitBiasCm,
      };

  /// Recommends sizes for [result] using the chart for [sex].
  ///
  /// [Sex.other] uses the midpoint of the male and female chart bounds
  /// (a unisex compromise). Missing parts fall back to "–"; a missing
  /// chest yields topSize "–", and the bottom size uses whichever of
  /// waist/hip is available (or "–" when neither is).
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
  static SizeRecommendation recommend(
    MeasurementResult result,
    Sex sex, {
    FitPreference fit = FitPreference.regular,
  }) {
    final bias = biasFor(fit);
    final perPart = <BodyPart, String>{};
    for (final part in BodyPart.values) {
      final value = result.valueFor(part);
      perPart[part] = value == null
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

  /// The larger of two size letters; a missing ("–") letter defers to the
  /// other one.
  static String _largerSize(String a, String b) {
    final ia = _sizes.indexOf(a);
    final ib = _sizes.indexOf(b);
    if (ia < 0) return b;
    if (ib < 0) return a;
    return _sizes[ia >= ib ? ia : ib];
  }
}
