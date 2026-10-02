import '../models/models.dart';

/// Sub-pixel horizontal span of the torso at one mask row.
class RowSpan {
  /// Left edge, in mask x coordinates (subpixel).
  final double left;

  /// Right edge, in mask x coordinates (subpixel); always > [left].
  final double right;

  const RowSpan(this.left, this.right);

  /// Horizontal extent of the span in mask pixels.
  double get width => right - left;

  /// Horizontal midpoint of the span in mask coordinates.
  double get center => (left + right) / 2;

  @override
  String toString() => 'RowSpan(${left.toStringAsFixed(2)}, '
      '${right.toStringAsFixed(2)})';
}

/// Row-oriented view over a segmentation confidence mask.
///
/// Exposes the body's vertical extent and, per row, the contiguous
/// foreground runs with subpixel-refined edges. Pure Dart; safe to use
/// in isolates and unit tests.
class Silhouette {
  final BinaryMask _mask;

  /// Confidence at or above this value counts as body.
  final double threshold;

  double? _topY;
  double? _bottomY;
  bool _extentComputed = false;

  /// Creates a silhouette over [mask]. [threshold]: mask confidence >=
  /// threshold counts as body.
  Silhouette(BinaryMask mask, {this.threshold = 0.5}) : _mask = mask;

  /// Mask width in pixels.
  int get width => _mask.width;

  /// Mask height in pixels.
  int get height => _mask.height;

  void _computeExtent() {
    if (_extentComputed) return;
    _extentComputed = true;
    int? top;
    int? bottom;
    for (var y = 0; y < _mask.height; y++) {
      var hasBody = false;
      for (var x = 0; x < _mask.width; x++) {
        if (_mask.at(x, y) >= threshold) {
          hasBody = true;
          break;
        }
      }
      if (hasBody) {
        top ??= y;
        bottom = y;
      }
    }
    _topY = top?.toDouble();
    _bottomY = bottom?.toDouble();
  }

  /// First mask row containing any body pixel (integer row as double),
  /// or null if the mask has no body pixels.
  double? get topY {
    _computeExtent();
    return _topY;
  }

  /// Last mask row containing any body pixel (integer row as double),
  /// or null if the mask has no body pixels.
  double? get bottomY {
    _computeExtent();
    return _bottomY;
  }

  /// Body height in mask pixels (bottomY - topY), or null if empty.
  double? get bodyHeightPx {
    _computeExtent();
    final t = _topY, b = _bottomY;
    if (t == null || b == null) return null;
    return b - t;
  }

  /// All contiguous foreground runs on row [y] (integer row, clamped to
  /// the mask), each edge refined to subpixel position by linear
  /// interpolation of the confidence crossing of [threshold] against the
  /// neighbouring pixel just outside the run.
  List<RowSpan> runsAt(int y) {
    if (_mask.height == 0 || _mask.width == 0) return const [];
    final row = y.clamp(0, _mask.height - 1);
    final runs = <RowSpan>[];
    var x = 0;
    while (x < _mask.width) {
      if (_mask.at(x, row) < threshold) {
        x++;
        continue;
      }
      final start = x;
      while (x + 1 < _mask.width && _mask.at(x + 1, row) >= threshold) {
        x++;
      }
      final end = x; // inclusive last foreground pixel of the run
      runs.add(RowSpan(_leftEdge(start, row), _rightEdge(end, row)));
      x++;
    }
    return runs;
  }

  /// Subpixel left edge of a run whose first foreground pixel is [x0].
  ///
  /// The crossing is interpolated between the neighbouring pixel just
  /// outside the run (x0 - 1, confidence < threshold; 0 outside the mask)
  /// and the first run pixel. For a hard binary mask this yields x0 - 0.5,
  /// i.e. the pixel's own left boundary.
  double _leftEdge(int x0, int y) {
    final cIn = _mask.at(x0, y);
    final cOut = _mask.at(x0 - 1, y); // 0 when x0 == 0 (out of bounds)
    // cIn >= threshold > cOut, so the denominator is strictly positive.
    return (x0 - 1) + (threshold - cOut) / (cIn - cOut);
  }

  /// Subpixel right edge of a run whose last foreground pixel is [x1].
  double _rightEdge(int x1, int y) {
    final cIn = _mask.at(x1, y);
    final cOut = _mask.at(x1 + 1, y); // 0 when x1 == width-1
    return x1 + (cIn - threshold) / (cIn - cOut);
  }

  /// The torso run at row [y]: the run whose horizontal range contains
  /// [torsoCenterX] (mask coords); if none contains it, the nearest run
  /// by center distance; null if the row has no runs.
  ///
  /// This keeps detached arm blobs on the same row (A-pose arms, side-view
  /// forward arms) from being mistaken for the torso.
  RowSpan? torsoSpanAt(int y, double torsoCenterX) {
    final runs = runsAt(y);
    if (runs.isEmpty) return null;
    for (final run in runs) {
      if (torsoCenterX >= run.left && torsoCenterX <= run.right) {
        return run;
      }
    }
    RowSpan best = runs.first;
    var bestDist = (best.center - torsoCenterX).abs();
    for (final run in runs.skip(1)) {
      final d = (run.center - torsoCenterX).abs();
      if (d < bestDist) {
        best = run;
        bestDist = d;
      }
    }
    return best;
  }
}
