import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../engine/quality.dart';
import '../models/models.dart';

/// Full-screen overlay for the capture preview: a dashed human-silhouette
/// guide (head circle, torso trapezoid, legs) that the person lines up with,
/// tinted green while the live pose check passes and white/amber otherwise,
/// plus a translucent scrim outside the guide area to focus attention.
class PoseOverlay extends StatelessWidget {
  const PoseOverlay({
    super.key,
    required this.check,
    required this.view,
  });

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

/// Paints the dashed silhouette guide and the outside scrim.
class PoseOverlayPainter extends CustomPainter {
  PoseOverlayPainter({required this.check, required this.view});

  /// Latest live pose check; null before the first detection.
  final PoseCheckResult? check;

  /// Which guide to draw.
  final CaptureView view;

  static const Color _okColor = Color(0xFF66E28A); // green: pose OK
  static const Color _issueColor = Color(0xFFFFC95C); // amber: fix something
  static const Color _idleColor = Colors.white; // no detection yet

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final guide = _guidePath(size);

    // Translucent scrim outside the guide area (a rounded capsule generously
    // containing the figure), so the subject region stays bright.
    final window = _guideWindow(size);
    final scrim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(window);
    canvas.drawPath(
      scrim,
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );

    final okNow = check?.okNow;
    final color = switch (okNow) {
      true => _okColor,
      false => _issueColor,
      null => _idleColor,
    };

    // Soft glow behind the guide when the pose is good.
    if (okNow == true) {
      canvas.drawPath(
        guide,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round
          ..color = _okColor.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }

    canvas.drawPath(
      _dashed(guide),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: 0.95),
    );
  }

  /// Rounded capsule around the whole figure, kept clear of the scrim.
  RRect _guideWindow(Size size) {
    final cx = size.width / 2;
    final top = size.height * 0.10;
    final bottom = size.height * 0.93;
    final halfW = math.min(size.width * 0.42, size.height * 0.24);
    return RRect.fromLTRBR(
      cx - halfW,
      top,
      cx + halfW,
      bottom,
      Radius.circular(halfW),
    );
  }

  /// The silhouette guide: head circle + torso trapezoid + two legs; for the
  /// side view the torso is narrower and an arm extends forward at shoulder
  /// height ("sleepwalker" pose), for the front view both arms are raised
  /// ~45 degrees from the body (A-pose).
  Path _guidePath(Size size) {
    final cx = size.width / 2;
    // Person should fill 65–90% of the frame height; aim the guide at ~78%.
    final top = size.height * 0.12;
    final bottom = size.height * 0.90;
    final bodyH = bottom - top;

    final headR = bodyH * 0.075;
    final headCy = top + headR;
    final neckY = top + headR * 2.1;
    final shoulderY = neckY + bodyH * 0.03;
    final hipY = top + bodyH * 0.52;
    final ankleY = bottom;

    final front = view == CaptureView.front;
    final shoulderHalf = bodyH * (front ? 0.155 : 0.095);
    final waistHalf = bodyH * (front ? 0.105 : 0.085);
    final hipHalf = bodyH * (front ? 0.135 : 0.100);
    final ankleHalf = bodyH * (front ? 0.090 : 0.045);
    final legInnerHalf = bodyH * (front ? 0.020 : 0.010);
    final kneeY = hipY + (ankleY - hipY) * 0.5;

    final path = Path();

    // Head.
    path.addOval(
      Rect.fromCircle(center: Offset(cx, headCy), radius: headR),
    );

    // Torso: shoulders -> waist -> hips, slightly curved (trapezoid with a
    // waist pinch), closed across the hips.
    final torso = Path()
      ..moveTo(cx - shoulderHalf, shoulderY)
      ..quadraticBezierTo(
          cx - waistHalf * 1.05, (shoulderY + hipY) / 2, cx - hipHalf, hipY)
      ..lineTo(cx + hipHalf, hipY)
      ..quadraticBezierTo(
          cx + waistHalf * 1.05, (shoulderY + hipY) / 2, cx + shoulderHalf, shoulderY)
      ..close();
    path.addPath(torso, Offset.zero);

    // Legs: two tapering trapezoids from the hips to the ankles with a
    // slight knee pinch. [sign] is -1 for the viewer-left leg, +1 for the
    // viewer-right leg (coordinates mirrored across the centre line).
    Path leg(double sign) {
      final hipOuterX = cx + sign * hipHalf;
      final hipInnerX = cx + sign * legInnerHalf;
      final ankleCx = cx + sign * ankleHalf;
      final kneeHalf = (hipOuterX - hipInnerX).abs() * 0.38;
      return Path()
        ..moveTo(hipOuterX, hipY)
        ..quadraticBezierTo(ankleCx + sign * kneeHalf, kneeY,
            ankleCx + sign * kneeHalf * 0.7, ankleY)
        ..lineTo(ankleCx - sign * kneeHalf * 0.7, ankleY)
        ..quadraticBezierTo(ankleCx - sign * kneeHalf, kneeY, hipInnerX, hipY)
        ..close();
    }

    path.addPath(leg(-1), Offset.zero);
    path.addPath(leg(1), Offset.zero);

    // Arms.
    if (front) {
      // A-pose: straight arms raised ~45 degrees from the body side.
      final armLen = bodyH * 0.30;
      const angle = 45 * math.pi / 180;
      final dx = math.sin(angle) * armLen;
      final dy = math.cos(angle) * armLen;
      path
        ..moveTo(cx - shoulderHalf, shoulderY + bodyH * 0.01)
        ..lineTo(cx - shoulderHalf - dx, shoulderY + dy)
        ..moveTo(cx + shoulderHalf, shoulderY + bodyH * 0.01)
        ..lineTo(cx + shoulderHalf + dx, shoulderY + dy);
    } else {
      // Side view: one arm raised straight forward to horizontal
      // (facing left, so "forward" is towards -x).
      final armLen = bodyH * 0.32;
      path
        ..moveTo(cx - shoulderHalf * 0.4, shoulderY + bodyH * 0.015)
        ..lineTo(cx - shoulderHalf * 0.4 - armLen, shoulderY + bodyH * 0.015);
    }

    return path;
  }

  /// Converts a stroked path into dashes.
  Path _dashed(Path source, {double dash = 11, double gap = 7}) {
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        out.addPath(
          metric.extractPath(
              distance, math.min(distance + dash, metric.length)),
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
