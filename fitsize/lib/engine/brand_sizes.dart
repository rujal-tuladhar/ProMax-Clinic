import 'dart:convert';
import 'dart:math' as math;

import '../models/models.dart';

/// Brand size passport: maps measured circumferences onto the published body
/// size charts of real brands (`assets/data/brand_charts.json`).
///
/// Pure Dart (no Flutter): the UI loads the asset string and hands it to
/// [BrandCatalog.fromJson]; everything else here is plain arithmetic.
///
/// Three chart formats are normalised into one lookup:
///
/// * Contiguous range charts (Nike, Adidas, Under Armour): the boundary
///   between two sizes is the edge they share.
/// * Range charts with gaps (Gap, Amazon Essentials, H&M): a value in a gap
///   goes to the NEAREST band, so the effective boundary is the midpoint of
///   the gap.
/// * Point-value charts (Zara, Mango, ASOS, Levi's, Lululemon; stored with
///   `min == max`): the boundary between two sizes is the midpoint of the two
///   points.
///
/// All three reduce to one rule: the boundary between adjacent bands `i` and
/// `i + 1` is `(sizes[i].max + sizes[i + 1].min) / 2`. The first band extends
/// to -infinity and the last to +infinity, so every value gets a size.
/// Boundaries are lower-inclusive (a value exactly on one belongs to the
/// larger size), matching `SizeRecommender`.

/// One size's body-measurement interval in cm. `min == max` for a point
/// chart.
class SizeBand {
  /// Size label as the brand prints it ("M", "W28", "UK12", "8").
  final String label;

  /// Lower bound of the band, cm.
  final double min;

  /// Upper bound of the band, cm (equal to [min] for point charts).
  final double max;

  const SizeBand({required this.label, required this.min, required this.max});

  /// Centre of the band (the point itself for point charts).
  double get midpoint => (min + max) / 2;

  /// Parses `{"label":"M","min":96,"max":104}`.
  factory SizeBand.fromJson(Map<String, dynamic> json) {
    final label = json['label'];
    final min = json['min'];
    final max = json['max'];
    if (label is! String || min is! num || max is! num) {
      throw FormatException('SizeBand needs label/min/max: $json');
    }
    if (max < min) {
      throw FormatException('SizeBand $label has max < min');
    }
    return SizeBand(
      label: label,
      min: min.toDouble(),
      max: max.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {'label': label, 'min': min, 'max': max};

  @override
  String toString() => min == max
      ? '$label=$min'
      : '$label=$min–$max';
}

/// One published chart: a gender, garment category and body measure, with
/// its size bands in the brand's published order (smallest first).
class BrandChart {
  /// "men" | "women".
  final String gender;

  /// "tops" | "bottoms".
  final String category;

  /// "chest" | "waist" | "hip" | "inseam".
  final String measure;

  /// Always "cm" in the shipped asset.
  final String unit;

  /// Size bands, smallest size first.
  final List<SizeBand> sizes;

  const BrandChart({
    required this.gender,
    required this.category,
    required this.measure,
    required this.unit,
    required this.sizes,
  });

  /// True when the brand publishes one value per size (all bands have
  /// `min == max`) rather than ranges.
  bool get isPointChart =>
      sizes.isNotEmpty && sizes.every((b) => b.min == b.max);

  /// Labels in chart order.
  List<String> get labels => [for (final b in sizes) b.label];

  factory BrandChart.fromJson(Map<String, dynamic> json) {
    final gender = json['gender'];
    final category = json['category'];
    final measure = json['measure'];
    final unit = json['unit'] ?? 'cm';
    final sizes = json['sizes'];
    if (gender is! String ||
        category is! String ||
        measure is! String ||
        unit is! String ||
        sizes is! List) {
      throw FormatException('BrandChart needs gender/category/measure/sizes');
    }
    final bands = [
      for (final s in sizes) SizeBand.fromJson(_asMap(s, 'size band')),
    ];
    if (bands.isEmpty) {
      throw FormatException('BrandChart $gender/$category/$measure is empty');
    }
    return BrandChart(
      gender: gender,
      category: category,
      measure: measure,
      unit: unit,
      sizes: List.unmodifiable(bands),
    );
  }

  Map<String, dynamic> toJson() => {
        'gender': gender,
        'category': category,
        'measure': measure,
        'unit': unit,
        'sizes': [for (final b in sizes) b.toJson()],
      };

  @override
  String toString() => 'BrandChart($gender/$category/$measure, $sizes)';
}

/// One brand's entry: provenance, a confidence tag and its charts.
class Brand {
  /// Display name ("Nike", "H&M", "Levi's").
  final String brand;

  /// URL of the official size guide the chart was read from.
  final String source;

  /// ISO date the chart was read, e.g. "2026-10-03".
  final String retrieved;

  /// "high" | "medium" | "low" — how far the shipped numbers can be trusted
  /// (official page read directly vs. summaries, scrapes or third parties).
  final String confidence;

  /// Short, user-facing caveats (point chart, hip definition, coverage).
  final String notes;

  final List<BrandChart> charts;

  const Brand({
    required this.brand,
    required this.source,
    required this.retrieved,
    required this.confidence,
    required this.notes,
    required this.charts,
  });

  /// True when at least one chart is published for [gender].
  bool hasGender(String gender) => charts.any((c) => c.gender == gender);

  /// The charts for [gender], in file order.
  List<BrandChart> chartsFor(String gender) =>
      [for (final c in charts) if (c.gender == gender) c];

  factory Brand.fromJson(Map<String, dynamic> json) {
    final name = json['brand'];
    if (name is! String || name.isEmpty) {
      throw const FormatException('Brand needs a non-empty "brand" name');
    }
    final charts = json['charts'];
    if (charts is! List || charts.isEmpty) {
      throw FormatException('Brand $name has no charts');
    }
    return Brand(
      brand: name,
      source: _asString(json['source']),
      retrieved: _asString(json['retrieved']),
      confidence: _asString(json['confidence'], fallback: 'low'),
      notes: _asString(json['notes']),
      charts: List.unmodifiable([
        for (final c in charts) BrandChart.fromJson(_asMap(c, 'chart')),
      ]),
    );
  }

  Map<String, dynamic> toJson() => {
        'brand': brand,
        'source': source,
        'retrieved': retrieved,
        'confidence': confidence,
        'notes': notes,
        'charts': [for (final c in charts) c.toJson()],
      };

  @override
  String toString() => 'Brand($brand, ${charts.length} charts)';
}

/// The whole shipped data file: a version stamp and the brands, in file
/// order (which is the order the UI lists them).
class BrandCatalog {
  final String _version;
  final List<Brand> _brands;

  const BrandCatalog._(this._version, this._brands);

  /// Builds a catalog from already-decoded JSON.
  factory BrandCatalog.fromMap(Map<String, dynamic> map) {
    final version = map['version'];
    final brands = map['brands'];
    if (version is! String) {
      throw const FormatException('Catalog needs a string "version"');
    }
    if (brands is! List) {
      throw const FormatException('Catalog needs a "brands" list');
    }
    return BrandCatalog._(
      version,
      List.unmodifiable([
        for (final b in brands) Brand.fromJson(_asMap(b, 'brand')),
      ]),
    );
  }

  /// Parses the contents of `assets/data/brand_charts.json`. Throws
  /// [FormatException] when the document does not match the contract shape.
  static BrandCatalog fromJson(String json) {
    final decoded = jsonDecode(json);
    return BrandCatalog.fromMap(_asMap(decoded, 'catalog'));
  }

  /// Data version, e.g. "2026.10".
  String get version => _version;

  /// Brands in file order.
  List<Brand> get brands => _brands;

  /// The brand named [name] (exact match), or null.
  Brand? brandNamed(String name) {
    for (final b in _brands) {
      if (b.brand == name) return b;
    }
    return null;
  }
}

/// Result of looking one measurement up on one chart.
class SizeLookup {
  /// Best size: the band whose (gap- and midpoint-adjusted) interval contains
  /// the fit-adjusted measurement.
  final String label;

  /// True when the measurement sits within [BrandSizeResolver.betweenCm] of
  /// a size boundary, or inside a gap of a range chart — i.e. the brand's own
  /// chart does not decide clearly and [alternative] is a real option.
  final bool between;

  /// The neighbouring size when [between] is true, else null.
  final String? alternative;

  /// Probability mass per label, in chart order: the normal distribution
  /// centred on the fit-adjusted measurement with sd = max(sdCm, 1.0),
  /// integrated over each band's interval (first band to -inf, last to
  /// +inf). Sums to 1.
  final Map<String, double> probabilities;

  const SizeLookup({
    required this.label,
    required this.between,
    required this.alternative,
    required this.probabilities,
  });

  /// The two sizes in chart order when [between], e.g. ("M", "L"); null
  /// otherwise. Convenient for "between X and Y" copy.
  (String, String)? get betweenPair {
    final alt = alternative;
    if (!between || alt == null) return null;
    final labels = probabilities.keys.toList();
    final i = labels.indexOf(label);
    final j = labels.indexOf(alt);
    return i <= j ? (label, alt) : (alt, label);
  }

  @override
  String toString() =>
      'SizeLookup($label${between ? ' / $alternative' : ''}, $probabilities)';
}

/// One brand's sizes for a shopper: top from chest, bottom from waist/hip.
class BrandSizeMatch {
  final Brand brand;

  /// The chart gender used: "men" or "women".
  final String gender;

  /// From the chest measurement on the tops chart; null when either is
  /// missing.
  final SizeLookup? top;

  /// Bottoms: waist and hip are looked up separately (preferring a bottoms
  /// chart, else the brand's body chart filed under tops) and the LARGER
  /// size by band index wins. Null when neither can be looked up.
  final SizeLookup? bottom;

  /// Why something is missing or approximate, e.g.
  /// 'Hip chart not published — waist only'. Null when nothing is.
  final String? note;

  const BrandSizeMatch({
    required this.brand,
    required this.gender,
    required this.top,
    required this.bottom,
    required this.note,
  });

  @override
  String toString() =>
      'BrandSizeMatch(${brand.brand}/$gender, top=${top?.label}, '
      'bottom=${bottom?.label}${note == null ? '' : ', $note'})';
}

/// Looks measurements up on a [BrandCatalog].
class BrandSizeResolver {
  final BrandCatalog catalog;

  BrandSizeResolver(this.catalog);

  /// A measurement this close (cm) to a size boundary is flagged [SizeLookup.
  /// between]: half the ~3 cm step of the finest brand charts.
  static const double betweenCm = 1.5;

  /// Floor on the standard deviation used for probabilities, cm. Even a
  /// perfectly repeatable camera estimate is not a tape measure.
  static const double minSdCm = 1.0;

  /// Magnitude of the fit bias, cm — the same 3 cm as `SizeRecommender`:
  /// under half a typical size step, so only near-boundary values move.
  static const double fitBiasCm = 3.0;

  /// Signed fit bias (cm) added to the measurement before lookup:
  /// -3 for slim, 0 for regular, +3 for relaxed.
  static double biasFor(FitPreference fit) => switch (fit) {
        FitPreference.slim => -fitBiasCm,
        FitPreference.regular => 0,
        FitPreference.relaxed => fitBiasCm,
      };

  /// Looks [valueCm] up on [chart].
  ///
  /// The measurement is first shifted by the fit bias (slim -3 cm, relaxed
  /// +3 cm). The best size is the band whose adjusted interval contains the
  /// shifted value, where the boundary between adjacent bands is the midpoint
  /// of the gap between them (the shared edge for contiguous ranges, the
  /// midpoint of the two values for point charts). [SizeLookup.between] is
  /// set when the shifted value lies inside a gap of a range chart or within
  /// [betweenCm] of a boundary; the alternative is the size across that
  /// boundary.
  ///
  /// Probabilities integrate a normal distribution centred on the SHIFTED
  /// value (so label and distribution agree on screen) with
  /// `sd = max(sdCm, minSdCm)` over each band's interval.
  SizeLookup lookup(
    BrandChart chart,
    double valueCm, {
    double sdCm = 1.5,
    FitPreference fit = FitPreference.regular,
  }) {
    if (!valueCm.isFinite) {
      throw ArgumentError.value(valueCm, 'valueCm', 'must be finite');
    }
    if (chart.sizes.isEmpty) {
      throw ArgumentError.value(chart, 'chart', 'has no sizes');
    }
    final bands = _sortedBands(chart);
    final v = valueCm + biasFor(fit);
    final sd = sdCm.isNaN ? minSdCm : math.max(sdCm, minSdCm);

    // Boundaries between band i and i+1; n-1 of them, strictly ordered after
    // sorting by midpoint (ties collapse to the same boundary).
    final n = bands.length;
    final bounds = List<double>.generate(
      n - 1,
      (i) => (bands[i].max + bands[i + 1].min) / 2,
    );

    // Best band: first boundary strictly above v; lower-inclusive edges.
    var best = 0;
    while (best < n - 1 && v >= bounds[best]) {
      best++;
    }

    // Between: inside a gap, or within betweenCm of a finite boundary.
    var between = false;
    String? alternative;
    final inGapBelow =
        best > 0 && v > bands[best - 1].max && v < bands[best].min;
    final inGapAbove =
        best < n - 1 && v > bands[best].max && v < bands[best + 1].min;
    if (inGapBelow || inGapAbove) {
      // Range chart: v lies in the gap and was assigned to the nearer side.
      between = true;
      alternative = bands[inGapBelow ? best - 1 : best + 1].label;
    } else {
      final dLower = best > 0 ? (v - bounds[best - 1]).abs() : double.infinity;
      final dUpper = best < n - 1 ? (bounds[best] - v).abs() : double.infinity;
      final d = math.min(dLower, dUpper);
      if (d <= betweenCm) {
        between = true;
        alternative = bands[dLower <= dUpper ? best - 1 : best + 1].label;
      }
    }

    // Probability mass per band: Φ((hi - v)/sd) - Φ((lo - v)/sd), with the
    // first lower edge at -inf and the last upper edge at +inf. The sum
    // telescopes to exactly 1 (up to floating-point rounding).
    final probabilities = <String, double>{};
    var lowerCdf = 0.0;
    for (var i = 0; i < n; i++) {
      final upperCdf =
          i == n - 1 ? 1.0 : normalCdf((bounds[i] - v) / sd);
      probabilities[bands[i].label] = math.max(0, upperCdf - lowerCdf);
      lowerCdf = upperCdf;
    }

    return SizeLookup(
      label: bands[best].label,
      between: between,
      alternative: alternative,
      probabilities: Map.unmodifiable(probabilities),
    );
  }

  /// Sizes for every brand in the catalog, in catalog order — always one
  /// entry per brand, so the UI can explain brands it cannot size.
  ///
  /// Chart gender: [Sex.male] uses men's charts, [Sex.female] women's, and
  /// [Sex.other] women's first, falling back to men's for brands that only
  /// publish a men's chart. A brand with no chart for the wanted gender gets
  /// null top/bottom and a note saying so.
  ///
  /// Top: chest on the tops chest chart. Bottom: waist and hip looked up
  /// separately (a bottoms chart when published, else the brand's body chart
  /// filed under tops) and the larger size by band index wins; when only one
  /// chart or measurement exists, that one is used and [BrandSizeMatch.note]
  /// says so.
  List<BrandSizeMatch> matchAll(
    MeasurementResult result,
    Sex sex, {
    FitPreference fit = FitPreference.regular,
  }) {
    final order = switch (sex) {
      Sex.male => const ['men'],
      Sex.female => const ['women'],
      Sex.other => const ['women', 'men'],
    };
    return [
      for (final brand in catalog.brands)
        _matchBrand(brand, result, order, fit),
    ];
  }

  BrandSizeMatch _matchBrand(
    Brand brand,
    MeasurementResult result,
    List<String> genderOrder,
    FitPreference fit,
  ) {
    String? gender;
    for (final g in genderOrder) {
      if (brand.hasGender(g)) {
        gender = g;
        break;
      }
    }
    if (gender == null) {
      final wanted = genderOrder.first;
      return BrandSizeMatch(
        brand: brand,
        gender: wanted,
        top: null,
        bottom: null,
        note: "No $wanted's chart published",
      );
    }

    final notes = <String>[];
    if (gender != genderOrder.first) {
      notes.add(
        "${_capitalise(genderOrder.first)}'s chart not published — "
        "$gender's chart shown",
      );
    }

    // Top: chest on the tops chart.
    SizeLookup? top;
    final chestChart = chartFor(brand, gender, 'tops', 'chest');
    final chest = result.partFor(BodyPart.chest);
    if (chestChart == null) {
      notes.add('No tops chart published');
    } else if (chest == null) {
      notes.add('Chest not measured');
    } else {
      top = lookup(chestChart, chest.valueCm, sdCm: chest.stdDevCm, fit: fit);
    }

    // Bottom: waist and hip separately; larger band index wins.
    final waistChart = chartFor(brand, gender, 'bottoms', 'waist');
    final hipChart = chartFor(brand, gender, 'bottoms', 'hip');
    final waist = result.partFor(BodyPart.waist);
    final hip = result.partFor(BodyPart.hip);

    SizeLookup? waistLookup;
    SizeLookup? hipLookup;
    if (waistChart != null && waist != null) {
      waistLookup =
          lookup(waistChart, waist.valueCm, sdCm: waist.stdDevCm, fit: fit);
    }
    if (hipChart != null && hip != null) {
      hipLookup = lookup(hipChart, hip.valueCm, sdCm: hip.stdDevCm, fit: fit);
    }

    SizeLookup? bottom;
    if (waistLookup != null && hipLookup != null) {
      final wi = _bandIndex(waistChart!, waistLookup.label);
      final hi = _bandIndex(hipChart!, hipLookup.label);
      bottom = hi > wi ? hipLookup : waistLookup;
    } else if (waistLookup != null) {
      bottom = waistLookup;
      notes.add(hipChart == null
          ? 'Hip chart not published — waist only'
          : 'Hip not measured — waist only');
    } else if (hipLookup != null) {
      bottom = hipLookup;
      notes.add(waistChart == null
          ? 'Waist chart not published — hip only'
          : 'Waist not measured — hip only');
    } else if (waistChart == null && hipChart == null) {
      notes.add('No bottoms chart published');
    } else if (waist == null && hip == null) {
      notes.add('Waist and hip not measured');
    } else {
      // One chart exists but its measurement is missing (or vice versa).
      notes.add(waistChart == null
          ? 'Waist chart not published and hip not measured'
          : 'Hip chart not published and waist not measured');
    }

    return BrandSizeMatch(
      brand: brand,
      gender: gender,
      top: top,
      bottom: bottom,
      note: notes.isEmpty ? null : notes.join(' · '),
    );
  }

  /// The chart of [brand] for [gender] and [measure], preferring [category]
  /// and falling back to any category that publishes that measure.
  ///
  /// Many brands publish ONE body chart (chest, waist, hip) that the data
  /// files under "tops"; body measurements do not change with the garment,
  /// so a bottoms lookup may use it when no bottoms chart exists.
  static BrandChart? chartFor(
    Brand brand,
    String gender,
    String category,
    String measure,
  ) {
    BrandChart? fallback;
    for (final c in brand.charts) {
      if (c.gender != gender || c.measure != measure) continue;
      if (c.category == category) return c;
      fallback ??= c;
    }
    return fallback;
  }

  /// Standard normal CDF Φ(z), via [erf].
  static double normalCdf(double z) {
    if (z.isNaN) return double.nan;
    if (z == double.infinity) return 1;
    if (z == double.negativeInfinity) return 0;
    return 0.5 * (1 + erf(z / math.sqrt2));
  }

  /// Error function, Abramowitz & Stegun 7.1.26 (|error| < 1.5e-7).
  static double erf(double x) {
    if (x.isNaN) return double.nan;
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

  /// Bands sorted by midpoint (stable), so gap/midpoint boundaries are
  /// well-defined even for a chart whose published order is not monotonic
  /// (adidas's inseam column, for instance). Circumference charts are
  /// already ordered, so this is a no-op for them.
  static List<SizeBand> _sortedBands(BrandChart chart) {
    final indexed = chart.sizes.indexed.toList()
      ..sort((a, b) {
        final c = a.$2.midpoint.compareTo(b.$2.midpoint);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final (_, b) in indexed) b];
  }

  static int _bandIndex(BrandChart chart, String label) {
    final bands = _sortedBands(chart);
    for (var i = 0; i < bands.length; i++) {
      if (bands[i].label == label) return i;
    }
    return -1;
  }
}

/// Formats a probability map as 'M 78% · L 22%': the heaviest [max] sizes
/// with at least [minShare] of the mass (always at least one), listed in
/// chart order.
String formatSizeProbabilities(
  Map<String, double> probabilities, {
  int max = 2,
  double minShare = 0.05,
}) {
  if (probabilities.isEmpty) return '';
  final entries = probabilities.entries.toList();
  final byMass = [...entries]..sort((a, b) => b.value.compareTo(a.value));
  final keep = <String>{byMass.first.key};
  for (final e in byMass.skip(1).take(max - 1)) {
    if (e.value >= minShare) keep.add(e.key);
  }
  return [
    for (final e in entries)
      if (keep.contains(e.key)) '${e.key} ${(e.value * 100).round()}%',
  ].join(' · ');
}

String _capitalise(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

Map<String, dynamic> _asMap(Object? value, String what) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  throw FormatException('Expected a JSON object for $what, got $value');
}

String _asString(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;
