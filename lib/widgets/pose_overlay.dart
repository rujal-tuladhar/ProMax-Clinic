import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../engine/quality.dart';
import '../models/models.dart';

/// Full-screen overlay for the capture preview: a smooth human-silhouette
/// guide the person lines up with, drawn as one continuous curve (head,
/// shoulders, arms, torso, legs), tinted green while the live pose check
/// passes and warm amber otherwise, plus a soft vignette scrim outside the
/// figure to focus attention on the subject area.
class PoseOverlay extends StatelessWidget {
  const PoseOverlay({super.key, required this.check, required this.view});

  /// Latest live pose check; null before the first detection.
  final PoseCheckResult? check;

  /// Which guide to draw: front (A-pose) or side (arms forward).
  final CaptureView view;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: PoseOverlayPainter(check: check, view: view),
      ),
    );
  }
}

/// Paints the silhouette guide and the soft scrim.
class PoseOverlayPainter extends CustomPainter {
  PoseOverlayPainter({required this.check, required this.view});

  /// Latest live pose check; null before the first detection.
  final PoseCheckResult? check;

  /// Which guide to draw.
  final CaptureView view;

  static const Color _okColor = Color(0xFF6EE7A8); // green: pose OK
  static const Color _issueColor = Color(0xFFFFC56B); // amber: fix something
  static const Color _idleColor = Color(0xFFF4F1EA); // no detection yet

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final okNow = check?.okNow;
    final color = switch (okNow) {
      true => _okColor,
      false => _issueColor,
      null => _idleColor,
    };

    _paintScrim(canvas, size);

    final guide = _guidePath(size);

    // Faint fill so the figure reads as a silhouette, not just an outline.
    canvas.drawPath(
      guide,
      Paint()..color = color.withValues(alpha: okNow == true ? 0.14 : 0.07),
    );

    // Soft glow when the pose is good.
    if (okNow == true) {
      canvas.drawPath(
        guide,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..strokeJoin = StrokeJoin.round
          ..color = _okColor.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }

    // Outline: solid when OK, long dashes while the person still has to
    // line up (dashes read as "move here").
    canvas.drawPath(
      okNow == true ? guide : _dashed(guide),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: 0.95),
    );
  }

  /// Vignette: clear over an ellipse around the figure, fading to a dark
  /// scrim outside it. Drawn in a scaled canvas space so a unit circle
  /// becomes the ellipse.
  void _paintScrim(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.515;
    final rx = math.min(size.width * 0.47, size.height * 0.27);
    final ry = size.height * 0.47;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(rx, ry);
    final shader = ui.Gradient.radial(
      Offset.zero,
      1.0,
      [
        const Color(0x00000000),
        const Color(0x00000000),
        Colors.black.withValues(alpha: 0.42),
        Colors.black.withValues(alpha: 0.55),
      ],
      const [0.0, 0.74, 0.96, 1.0],
    );
    final rect = Rect.fromLTRB(
      -cx / rx,
      -cy / ry,
      (size.width - cx) / rx,
      (size.height - cy) / ry,
    );
    canvas.drawRect(rect, Paint()..shader = shader);
    canvas.restore();
  }

  /// The silhouette guide as a single smooth closed curve through a list
  /// of key points (Catmull-Rom, converted to cubic Béziers).
  Path _guidePath(Size size) {
    final cx = size.width / 2;
    // Person should fill 65–90% of the frame height; aim the guide at ~78%.
    final top = size.height * 0.12;
    final bottom = size.height * 0.90;
    final h = bottom - top;

    final pts = view == CaptureView.front ? _frontPoints() : _sidePoints();
    final mapped = [for (final p in pts) Offset(cx + p.dx * h, top + p.dy * h)];
    return _smoothClosed(mapped);
  }

  /// Front view, A-pose: the right half of the figure from the top of the
  /// head down the raised arm, torso and leg to the crotch; mirrored for the
  /// left half. Coordinates are fractions of body height, x from centre.
  static List<Offset> _frontPoints() {
    const half = <Offset>[
      Offset(0.000, 0.000), // crown
      Offset(0.052, 0.018),
      Offset(0.074, 0.070), // temple
      Offset(0.062, 0.125),
      Offset(0.036, 0.152), // jaw
      Offset(0.034, 0.176), // neck
      Offset(0.095, 0.192), // shoulder slope
      Offset(0.148, 0.212), // shoulder tip
      // Arm raised 45°: upper edge out to the hand, then back along the
      // lower edge to the armpit.
      Offset(0.230, 0.272),
      Offset(0.318, 0.358),
      Offset(0.372, 0.420), // hand (outer)
      Offset(0.378, 0.452), // fingertips
      Offset(0.348, 0.462), // hand (inner)
      Offset(0.262, 0.388),
      Offset(0.172, 0.302),
      Offset(0.118, 0.262), // armpit
      Offset(0.110, 0.300), // chest
      Offset(0.096, 0.372),
      Offset(0.090, 0.410), // waist
      Offset(0.112, 0.470),
      Offset(0.126, 0.520), // hip
      Offset(0.112, 0.590), // thigh
      Offset(0.094, 0.690),
      Offset(0.084, 0.745), // knee
      Offset(0.082, 0.840), // calf
      Offset(0.070, 0.945), // ankle
      Offset(0.078, 0.992), // foot (outer)
      Offset(0.040, 1.000), // foot (inner)
      Offset(0.032, 0.950),
      Offset(0.036, 0.850),
      Offset(0.040, 0.745), // inner knee
      Offset(0.030, 0.640),
      Offset(0.012, 0.572),
    ];
    return _mirrorClosed(half, crotch: const Offset(0, 0.558));
  }

  /// Side view, facing left ("sleepwalker" pose): the full outline, read
  /// clockwise from the crown. Positive x is the back of the body.
  static List<Offset> _sidePoints() {
    return const <Offset>[
      Offset(0.000, 0.000), // crown
      Offset(0.045, 0.018),
      Offset(0.064, 0.070), // back of head
      Offset(0.052, 0.126),
      Offset(0.034, 0.150), // nape
      Offset(0.040, 0.176),
      Offset(0.074, 0.204), // shoulder (back)
      Offset(0.090, 0.280), // upper back
      Offset(0.074, 0.380), // lower back
      Offset(0.096, 0.470), // seat
      Offset(0.092, 0.530),
      Offset(0.070, 0.620), // back of thigh
      Offset(0.052, 0.740), // back of knee
      Offset(0.058, 0.820), // calf
      Offset(0.046, 0.955), // heel
      Offset(0.050, 1.000),
      Offset(-0.090, 1.000), // toes
      Offset(-0.082, 0.972),
      Offset(-0.034, 0.860), // shin
      Offset(-0.044, 0.745), // knee
      Offset(-0.056, 0.620), // thigh
      Offset(-0.062, 0.520),
      Offset(-0.066, 0.420), // belly
      Offset(-0.062, 0.350),
      Offset(-0.078, 0.282), // chest
      Offset(-0.064, 0.248), // armpit
      // Arm straight forward at shoulder height: lower edge to the hand,
      // fingertips, upper edge back to the shoulder.
      Offset(-0.200, 0.244),
      Offset(-0.340, 0.240),
      Offset(-0.372, 0.228), // fingertips
      Offset(-0.340, 0.202),
      Offset(-0.200, 0.198),
      Offset(-0.056, 0.192), // shoulder (front)
      Offset(-0.030, 0.172), // throat
      Offset(-0.046, 0.146), // chin
      Offset(-0.062, 0.108), // lips/nose
      Offset(-0.064, 0.056), // brow
      Offset(-0.040, 0.016),
    ];
  }

  /// Mirrors a right-half point list (crown first, ending just above the
  /// crotch) into a full clockwise outline.
  static List<Offset> _mirrorClosed(
    List<Offset> half, {
    required Offset crotch,
  }) {
    final out = <Offset>[...half, crotch];
    for (var i = half.length - 1; i >= 1; i--) {
      final p = half[i];
      out.add(Offset(-p.dx, p.dy));
    }
    return out;
  }

  /// Closed Catmull-Rom spline through [pts] as cubic Bézier segments.
  static Path _smoothClosed(List<Offset> pts) {
    final n = pts.length;
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 0; i < n; i++) {
      final p0 = pts[(i - 1 + n) % n];
      final p1 = pts[i];
      final p2 = pts[(i + 1) % n];
      final p3 = pts[(i + 2) % n];
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    path.close();
    return path;
  }

  /// Converts a stroked path into long dashes.
  Path _dashed(Path source, {double dash = 18, double gap = 10}) {
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        out.addPath(
          metric.extractPath(
            distance,
            math.min(distance + dash, metric.length),
          ),
          Offset.zero,
        );
        distance += dash + gap;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(PoseOverlayPainter oldDelegate) =>
      oldDelegate.view != view || oldDelegate.check?.okNow != check?.okNow;
}
