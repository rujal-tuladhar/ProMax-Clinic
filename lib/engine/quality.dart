import 'dart:math' as math;
import 'dart:typed_data';

import '../models/models.dart';

/// Problems a live pose can have, ordered most-important-first; issue
/// lists returned by the checks below follow this ordering.
enum PoseIssue {
  noPerson,
  tooFar,
  tooClose,
  notCentered,
  lowLight,
  notFacingCamera,
  notSideways,
  armsNotRaised,
  armsTooHigh,
  notUpright,
  feetTogether,
}

/// Result of a live pose check; [ok] is true when [issues] is empty.
class PoseCheckResult {
  /// Detected issues, ordered most-important-first.
  final List<PoseIssue> issues;

  const PoseCheckResult(this.issues);

  /// True when the pose passed every gate ([issues] is empty).
  bool get ok => issues.isEmpty;

  /// Alias of [ok] for live-gating call sites.
  bool get okNow => issues.isEmpty;
}

/// Minimum landmark likelihood for a landmark to be trusted.
const double _minLikelihood = 0.5;

/// Core landmarks that must be present before any framing check runs.
const List<Landmark> _coreLandmarks = [
  Landmark.leftShoulder,
  Landmark.rightShoulder,
  Landmark.leftHip,
  Landmark.rightHip,
  Landmark.leftAnkle,
  Landmark.rightAnkle,
];

/// Minimum ankle x-separation (fraction of body height) for the legs to be
/// separable in the silhouette.
const double _minAnkleSeparation = 0.08;

/// Mean Y-plane luma below which a frame counts as too dark to segment.
const double _minMeanLuma = 60;

/// Head landmarks used to find the top of the body.
const List<Landmark> _headLandmarks = [
  Landmark.nose,
  Landmark.leftEye,
  Landmark.rightEye,
  Landmark.leftEar,
  Landmark.rightEar,
];

PosePoint? _trusted(BodyPose pose, Landmark l) {
  final p = pose[l];
  if (p == null || p.likelihood < _minLikelihood) return null;
  return p;
}

/// Body framing geometry shared by the front and side checks.
class _Framing {
  final double bodyHeight;
  final double centerX;
  const _Framing(this.bodyHeight, this.centerX);
}

_Framing _framingOf(BodyPose pose) {
  // Top of the body: highest trusted head landmark, falling back to the
  // highest shoulder when the head is not tracked.
  double topY = double.infinity;
  for (final l in _headLandmarks) {
    final p = _trusted(pose, l);
    if (p != null) topY = math.min(topY, p.y);
  }
  final ls = pose[Landmark.leftShoulder]!;
  final rs = pose[Landmark.rightShoulder]!;
  if (topY == double.infinity) topY = math.min(ls.y, rs.y);

  final la = pose[Landmark.leftAnkle]!;
  final ra = pose[Landmark.rightAnkle]!;
  final bottomY = math.max(la.y, ra.y);

  final lh = pose[Landmark.leftHip]!;
  final rh = pose[Landmark.rightHip]!;
  final shoulderMidX = (ls.x + rs.x) / 2;
  final hipMidX = (lh.x + rh.x) / 2;

  return _Framing(bottomY - topY, (shoulderMidX + hipMidX) / 2);
}

void _checkFraming(
  _Framing f,
  int imageWidth,
  int imageHeight,
  List<PoseIssue> issues,
) {
  final heightFraction = f.bodyHeight / imageHeight;
  if (heightFraction < 0.65) {
    issues.add(PoseIssue.tooFar);
  } else if (heightFraction > 0.90) {
    issues.add(PoseIssue.tooClose);
  }
  if ((f.centerX - imageWidth / 2).abs() > 0.12 * imageWidth) {
    issues.add(PoseIssue.notCentered);
  }
}

/// Angle (degrees, 0..180) of the shoulder→[tip] vector measured from the
/// vertical pointing down through the shoulder. 0° = hanging straight
/// down, 90° = horizontal, >90° = above shoulder level.
double _angleFromVerticalDeg(PosePoint shoulder, PosePoint tip) {
  final dx = (tip.x - shoulder.x).abs();
  final dy = tip.y - shoulder.y; // positive when tip is below the shoulder
  return math.atan2(dx, dy) * 180 / math.pi;
}

List<PoseIssue> _sorted(List<PoseIssue> issues) {
  issues.sort((a, b) => a.index.compareTo(b.index));
  return issues;
}

/// Checks a FRONT (A-pose) capture pose.
///
/// Landmark-likelihood gate: core landmarks (shoulders, hips, ankles)
/// must each have likelihood >= 0.5, else [PoseIssue.noPerson].
/// Framing: body height (min head-y to max ankle-y) must be 65–90% of
/// [imageHeight] (tooFar / tooClose); body center-x within ±12% of image
/// center (notCentered).
/// Front pose: shoulder left/right x-separation >= 0.12 * body height
/// (else notFacingCamera); both arm angles (elbow relative to the
/// vertical through the shoulder) between 25° and 75°
/// (armsNotRaised / armsTooHigh); shoulder-mid above hip-mid by
/// >= 0.2 * body height (notUpright); ankle x-separation >= 0.08 * body
/// height (else feetTogether — the legs must be separable for the inseam
/// crotch search).
PoseCheckResult checkFrontPose(
    BodyPose pose, int imageWidth, int imageHeight) {
  for (final l in _coreLandmarks) {
    if (_trusted(pose, l) == null) {
      return const PoseCheckResult([PoseIssue.noPerson]);
    }
  }
  final issues = <PoseIssue>[];
  final framing = _framingOf(pose);
  _checkFraming(framing, imageWidth, imageHeight, issues);

  final ls = pose[Landmark.leftShoulder]!;
  final rs = pose[Landmark.rightShoulder]!;
  final lh = pose[Landmark.leftHip]!;
  final rh = pose[Landmark.rightHip]!;
  final la = pose[Landmark.leftAnkle]!;
  final ra = pose[Landmark.rightAnkle]!;

  if ((ls.x - rs.x).abs() < 0.12 * framing.bodyHeight) {
    issues.add(PoseIssue.notFacingCamera);
  }

  if ((la.x - ra.x).abs() < _minAnkleSeparation * framing.bodyHeight) {
    issues.add(PoseIssue.feetTogether);
  }

  var armsNotRaised = false;
  var armsTooHigh = false;
  for (final (shoulder, elbowLandmark) in [
    (ls, Landmark.leftElbow),
    (rs, Landmark.rightElbow),
  ]) {
    final elbow = _trusted(pose, elbowLandmark);
    if (elbow == null) {
      armsNotRaised = true; // cannot verify the arm is clear of the torso
      continue;
    }
    final angle = _angleFromVerticalDeg(shoulder, elbow);
    if (angle < 25) armsNotRaised = true;
    if (angle > 75) armsTooHigh = true;
  }
  if (armsNotRaised) issues.add(PoseIssue.armsNotRaised);
  if (armsTooHigh) issues.add(PoseIssue.armsTooHigh);

  final shoulderMidY = (ls.y + rs.y) / 2;
  final hipMidY = (lh.y + rh.y) / 2;
  if (hipMidY - shoulderMidY < 0.2 * framing.bodyHeight) {
    issues.add(PoseIssue.notUpright);
  }
  return PoseCheckResult(_sorted(issues));
}

/// Checks a SIDE ("sleepwalker") capture pose.
///
/// Same core-landmark and framing gates as [checkFrontPose]. Side pose:
/// shoulder x-separation < 0.08 * body height (else notSideways); wrists
/// roughly at shoulder height (|wristY - shoulderY| <= 0.12 * body
/// height) AND displaced horizontally from the shoulder by >= 0.10 *
/// body height, else armsNotRaised.
PoseCheckResult checkSidePose(
    BodyPose pose, int imageWidth, int imageHeight) {
  for (final l in _coreLandmarks) {
    if (_trusted(pose, l) == null) {
      return const PoseCheckResult([PoseIssue.noPerson]);
    }
  }
  final issues = <PoseIssue>[];
  final framing = _framingOf(pose);
  _checkFraming(framing, imageWidth, imageHeight, issues);

  final ls = pose[Landmark.leftShoulder]!;
  final rs = pose[Landmark.rightShoulder]!;
  if ((ls.x - rs.x).abs() >= 0.08 * framing.bodyHeight) {
    issues.add(PoseIssue.notSideways);
  }

  var armsNotRaised = false;
  for (final (shoulder, wristLandmark) in [
    (ls, Landmark.leftWrist),
    (rs, Landmark.rightWrist),
  ]) {
    final wrist = _trusted(pose, wristLandmark);
    if (wrist == null) {
      armsNotRaised = true;
      continue;
    }
    final atShoulderHeight =
        (wrist.y - shoulder.y).abs() <= 0.12 * framing.bodyHeight;
    final reachingForward =
        (wrist.x - shoulder.x).abs() >= 0.10 * framing.bodyHeight;
    if (!atShoulderHeight || !reachingForward) armsNotRaised = true;
  }
  if (armsNotRaised) issues.add(PoseIssue.armsNotRaised);

  return PoseCheckResult(_sorted(issues));
}

/// Checks a mid-TURN pose (guided 360° rotation mode).
///
/// At oblique yaws neither the front nor the side stance rules apply, so
/// this gate keeps only the core-landmark and framing checks: the person
/// must be tracked, fill 65–90% of the frame height and stay centered.
PoseCheckResult checkTurnPose(
    BodyPose pose, int imageWidth, int imageHeight) {
  for (final l in _coreLandmarks) {
    if (_trusted(pose, l) == null) {
      return const PoseCheckResult([PoseIssue.noPerson]);
    }
  }
  final issues = <PoseIssue>[];
  _checkFraming(_framingOf(pose), imageWidth, imageHeight, issues);
  return PoseCheckResult(_sorted(issues));
}

/// Human-readable coaching instruction for [issue] in the context of
/// [view]; spoken via TTS and shown in the issue banner.
String instructionFor(PoseIssue issue, CaptureView view) {
  switch (issue) {
    case PoseIssue.noPerson:
      return 'Step back so your whole body is in view';
    case PoseIssue.tooFar:
      return 'Step closer to the camera';
    case PoseIssue.tooClose:
      return 'Step back from the camera';
    case PoseIssue.notCentered:
      return 'Move to the center of the frame';
    case PoseIssue.lowLight:
      return 'Find a brighter spot or turn on a light';
    case PoseIssue.notFacingCamera:
      return 'Face the camera straight on';
    case PoseIssue.notSideways:
      return 'Turn to your left so your side faces the camera';
    case PoseIssue.armsNotRaised:
      return view == CaptureView.front
          ? 'Raise your arms away from your body'
          : 'Raise your arms straight forward to shoulder height';
    case PoseIssue.armsTooHigh:
      return view == CaptureView.front
          ? 'Lower your arms a little'
          : 'Lower your arms to shoulder height';
    case PoseIssue.notUpright:
      return 'Stand up straight and tall';
    case PoseIssue.feetTogether:
      return 'Stand with your feet a little apart';
  }
}

/// Mean luma (0..255) of a camera Y plane, sampling every [stride]-th byte
/// so a 1080p plane costs ~20k reads. Returns 0 for an empty plane; a
/// non-positive [stride] samples every byte.
double meanLuma(Uint8List yPlane, {int stride = 97}) {
  if (yPlane.isEmpty) return 0;
  final step = stride < 1 ? 1 : stride;
  var sum = 0;
  var count = 0;
  for (var i = 0; i < yPlane.length; i += step) {
    sum += yPlane[i];
    count++;
  }
  return sum / count;
}

/// True when the scene is too dark for reliable segmentation (mean luma
/// below 60 of 255).
bool isTooDark(double meanLuma) => meanLuma < _minMeanLuma;
