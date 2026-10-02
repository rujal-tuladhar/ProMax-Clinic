import 'package:fitsize/engine/quality.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

const int imgW = 1000;
const int imgH = 2000;

/// A compliant FRONT A-pose: body height 1500 px (75% of frame), centred,
/// shoulders 200 px apart, elbows at 45 degrees from vertical, hips 400 px
/// below the shoulders.
BodyPose frontPose({
  double dx = 0,
  double headY = 200,
  double ankleY = 1700,
  double shoulderHalfSep = 100,
  double elbowDx = 150,
  double elbowDy = 150,
  double hipY = 900,
  double ankleLikelihood = 1,
}) {
  PosePoint p(double x, double y, [double lh = 1]) =>
      PosePoint(x + dx, y, likelihood: lh);
  return BodyPose({
    Landmark.nose: p(500, headY),
    Landmark.leftShoulder: p(500 + shoulderHalfSep, 500),
    Landmark.rightShoulder: p(500 - shoulderHalfSep, 500),
    Landmark.leftElbow: p(500 + shoulderHalfSep + elbowDx, 500 + elbowDy),
    Landmark.rightElbow: p(500 - shoulderHalfSep - elbowDx, 500 + elbowDy),
    Landmark.leftWrist: p(850, 800),
    Landmark.rightWrist: p(150, 800),
    Landmark.leftHip: p(540, hipY),
    Landmark.rightHip: p(460, hipY),
    Landmark.leftAnkle: p(530, ankleY, ankleLikelihood),
    Landmark.rightAnkle: p(470, ankleY, ankleLikelihood),
  });
}

/// A compliant SIDE "sleepwalker" pose: shoulders nearly superimposed,
/// wrists at shoulder height reaching 215 px forward.
BodyPose sidePose({
  double wristX = 720,
  double wristY = 520,
  double shoulderHalfSep = 5,
}) {
  return BodyPose({
    Landmark.nose: const PosePoint(520, 200),
    Landmark.leftShoulder: PosePoint(500 + shoulderHalfSep, 500),
    Landmark.rightShoulder: PosePoint(500 - shoulderHalfSep, 500),
    Landmark.leftElbow: const PosePoint(620, 510),
    Landmark.rightElbow: const PosePoint(615, 515),
    Landmark.leftWrist: PosePoint(wristX, wristY),
    Landmark.rightWrist: PosePoint(wristX - 10, wristY + 10),
    Landmark.leftHip: const PosePoint(505, 900),
    Landmark.rightHip: const PosePoint(495, 900),
    Landmark.leftAnkle: const PosePoint(500, 1700),
    Landmark.rightAnkle: const PosePoint(505, 1700),
  });
}

void main() {
  group('checkFrontPose', () {
    test('passes a compliant A-pose', () {
      final r = checkFrontPose(frontPose(), imgW, imgH);
      expect(r.issues, isEmpty);
      expect(r.ok, isTrue);
      expect(r.okNow, isTrue);
    });

    test('low-likelihood core landmark -> noPerson', () {
      final r = checkFrontPose(frontPose(ankleLikelihood: 0.3), imgW, imgH);
      expect(r.issues, [PoseIssue.noPerson]);
      expect(r.ok, isFalse);
    });

    test('missing core landmark -> noPerson', () {
      final pose = BodyPose(Map.of(frontPose().points)
        ..remove(Landmark.leftHip));
      final r = checkFrontPose(pose, imgW, imgH);
      expect(r.issues, [PoseIssue.noPerson]);
    });

    test('small body -> tooFar', () {
      // Height 900 px = 45% of the frame.
      final r =
          checkFrontPose(frontPose(headY: 800, hipY: 1100, ankleY: 1700),
              imgW, imgH);
      expect(r.issues, contains(PoseIssue.tooFar));
    });

    test('body filling the frame -> tooClose', () {
      // Height 1850 px = 92.5% of the frame.
      final r = checkFrontPose(
          frontPose(headY: 100, ankleY: 1950), imgW, imgH);
      expect(r.issues, contains(PoseIssue.tooClose));
    });

    test('body shifted sideways -> notCentered', () {
      final r = checkFrontPose(frontPose(dx: 200), imgW, imgH);
      expect(r.issues, [PoseIssue.notCentered]);
    });

    test('narrow shoulders -> notFacingCamera', () {
      // Separation 80 px < 0.12 * 1500.
      final r = checkFrontPose(frontPose(shoulderHalfSep: 40), imgW, imgH);
      expect(r.issues, [PoseIssue.notFacingCamera]);
    });

    test('arms hanging -> armsNotRaised', () {
      // Elbow nearly below the shoulder: ~3.8 degrees from vertical.
      final r = checkFrontPose(
          frontPose(elbowDx: 10, elbowDy: 150), imgW, imgH);
      expect(r.issues, [PoseIssue.armsNotRaised]);
    });

    test('arms above horizontal -> armsTooHigh', () {
      // Elbow above shoulder level: ~105 degrees from vertical.
      final r = checkFrontPose(
          frontPose(elbowDx: 150, elbowDy: -40), imgW, imgH);
      expect(r.issues, [PoseIssue.armsTooHigh]);
    });

    test('45-degree arms pass the band', () {
      final r = checkFrontPose(
          frontPose(elbowDx: 150, elbowDy: 150), imgW, imgH);
      expect(r.issues, isEmpty);
    });

    test('hips too close to shoulders -> notUpright', () {
      // Shoulder-hip drop 140 px < 0.2 * 1500.
      final r = checkFrontPose(frontPose(hipY: 640), imgW, imgH);
      expect(r.issues, contains(PoseIssue.notUpright));
    });

    test('issues come back ordered most-important-first', () {
      // Far away AND hanging arms: framing outranks arm position.
      final r = checkFrontPose(
          frontPose(headY: 800, hipY: 1100, elbowDx: 10), imgW, imgH);
      expect(r.issues.first, PoseIssue.tooFar);
      expect(r.issues, contains(PoseIssue.armsNotRaised));
    });
  });

  group('checkSidePose', () {
    test('passes a compliant sleepwalker pose', () {
      final r = checkSidePose(sidePose(), imgW, imgH);
      expect(r.issues, isEmpty);
      expect(r.ok, isTrue);
    });

    test('wide shoulders -> notSideways (reported first)', () {
      final r = checkSidePose(sidePose(shoulderHalfSep: 100), imgW, imgH);
      expect(r.issues, isNotEmpty);
      expect(r.issues.first, PoseIssue.notSideways);
    });

    test('wrists hanging low -> armsNotRaised', () {
      final r = checkSidePose(sidePose(wristY: 1050), imgW, imgH);
      expect(r.issues, [PoseIssue.armsNotRaised]);
    });

    test('wrists not reaching forward -> armsNotRaised', () {
      // At shoulder height but only ~60 px forward (< 0.10 * 1500).
      final r = checkSidePose(sidePose(wristX: 565), imgW, imgH);
      expect(r.issues, [PoseIssue.armsNotRaised]);
    });

    test('missing core landmark -> noPerson', () {
      final pose = BodyPose(Map.of(sidePose().points)
        ..remove(Landmark.rightAnkle));
      final r = checkSidePose(pose, imgW, imgH);
      expect(r.issues, [PoseIssue.noPerson]);
    });
  });

  group('instructionFor', () {
    test('every issue has a non-empty instruction in both views', () {
      for (final issue in PoseIssue.values) {
        for (final view in CaptureView.values) {
          expect(instructionFor(issue, view), isNotEmpty);
        }
      }
    });

    test('armsNotRaised coaching differs between views', () {
      expect(
        instructionFor(PoseIssue.armsNotRaised, CaptureView.front),
        isNot(instructionFor(PoseIssue.armsNotRaised, CaptureView.side)),
      );
    });

    test('tooFar asks to step closer', () {
      expect(instructionFor(PoseIssue.tooFar, CaptureView.front),
          contains('closer'));
    });
  });
}
