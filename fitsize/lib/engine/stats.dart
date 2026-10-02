import 'dart:math' as math;

/// Robust statistics helpers used for burst-frame combination.

/// Median of a non-empty list (does not mutate input).
double median(List<double> xs) {
  assert(xs.isNotEmpty, 'median of empty list');
  final sorted = List<double>.of(xs)..sort();
  final n = sorted.length;
  final mid = n ~/ 2;
  if (n.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Median absolute deviation: median of |x - median(xs)|.
double mad(List<double> xs) {
  final m = median(xs);
  return median([for (final x in xs) (x - m).abs()]);
}

/// Keep values within [k]*MAD of the median (k default 3); if MAD == 0
/// returns the input unchanged.
List<double> rejectOutliers(List<double> xs, {double k = 3}) {
  if (xs.length < 2) return xs;
  final m = median(xs);
  final d = mad(xs);
  if (d == 0) return xs;
  return [
    for (final x in xs)
      if ((x - m).abs() <= k * d) x,
  ];
}

/// Sample standard deviation (0 for n < 2).
double stdDev(List<double> xs) {
  final n = xs.length;
  if (n < 2) return 0;
  final mean = xs.reduce((a, b) => a + b) / n;
  var sumSq = 0.0;
  for (final x in xs) {
    final d = x - mean;
    sumSq += d * d;
  }
  return math.sqrt(sumSq / (n - 1));
}
