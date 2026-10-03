import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fitsize/engine/extra_measurements.dart';
import 'package:fitsize/engine/silhouette.dart';
import 'package:fitsize/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic 170 cm person on a 128x256 mask of a 720x1440 image
// (5.625 image px per mask px on both axes). Body rows 20..235 (215 mask
// px) so 1 mask px = 170/215 cm.
const double heightCm = 170;
const int maskW = 128, maskH = 256, imageW = 720, imageH = 1440;
const double imgPerMask = 5.625;
const int top = 20, bottom = 235;
const double cmPerMaskPx = heightCm / 215;
const double scale = cmPerMaskPx / imgPerMask; // cm per IMAGE px

const int shoulderRow = 50, hipRow = 125, crotchRow = 136, ankleRow = 230;

const profileOther = UserProfile(heightCm: heightCm, sex: Sex.other);
const profileMale = UserProfile(heightCm: heightCm, sex: Sex.male);
const profileFemale = UserProfile(heightCm: heightCm, sex: Sex.female);

/// Fills [conf] with 1.0 over the inclusive rectangle.
void fill(Float32List conf, int r0, int r1, int c0, int c1) {
  for (var y = r0; y <= r1; y++) {
    for (var x = c0; x <= c1; x++) {
      conf[y * maskW + x] = 1.0;
    }
  }
}

/// Head + torso (cols 46..81) + legs. With [legsApart] the legs are two
/// runs (46..62 and 65..81) from [crotch]+1 down to [bottom]; otherwise a
/// solid block.
BinaryMask personMask({bool legsApart = true, int crotch = crotchRow}) {
  final conf = Float32List(maskW * maskH);
  fill(conf, top, shoulderRow - 1, 58, 69); // head/neck
  fill(conf, shoulderRow, crotch, 46, 81); // torso + pelvis
  if (legsApart) {
    fill(conf, crotch + 1, bottom, 46, 62);
    fill(conf, crotch + 1, bottom, 65, 81);
  } else {
    fill(conf, crotch + 1, bottom, 46, 81);
  }
  return BinaryMask(width: maskW, height: maskH, confidences: conf);
}

PosePoint p(double maskX, double maskY, [double lh = 1]) =>
    PosePoint(maskX * imgPerMask, maskY * imgPerMask, likelihood: lh);

/// A-pose: straight arms 45 degrees from the body, shoulders 42 mask px
/// apart, ankles at mask x 54 / 73 (inside each leg run).
BodyPose aPose({
  double ankleLikelihood = 1,
  double shoulderHalfSep = 21,
  double armSegment = 24, // elbow/wrist step in mask px per axis
  double hipRowY = hipRow * 1.0,
}) =>
    BodyPose({
      Landmark.nose: p(64, 25),
      Landmark.leftShoulder: p(64 + shoulderHalfSep, shoulderRow.toDouble()),
      Landmark.rightShoulder: p(64 - shoulderHalfSep, shoulderRow.toDouble()),
      Landmark.leftElbow:
          p(64 + shoulderHalfSep + armSegment, shoulderRow + armSegment),
      Landmark.rightElbow:
          p(64 - shoulderHalfSep - armSegment, shoulderRow + armSegment),
      Landmark.leftWrist: p(
          64 + shoulderHalfSep + 2 * armSegment, shoulderRow + 2 * armSegment),
      Landmark.rightWrist: p(
          64 - shoulderHalfSep - 2 * armSegment, shoulderRow + 2 * armSegment),
      Landmark.leftHip: p(70, hipRowY),
      Landmark.rightHip: p(58, hipRowY),
      Landmark.leftKnee: p(54, 185),
      Landmark.rightKnee: p(73, 185),
      Landmark.leftAnkle: p(54, ankleRow.toDouble(), ankleLikelihood),
      Landmark.rightAnkle: p(73, ankleRow.toDouble(), ankleLikelihood),
    });

SilhouetteFrame frameOf(BinaryMask mask, BodyPose pose) => SilhouetteFrame(
      mask: mask,
      pose: pose,
      imageWidth: imageW,
      imageHeight: imageH,
      view: CaptureView.front,
    );

BodyPose without(BodyPose pose, Iterable<Landmark> ls) =>
    BodyPose(Map.of(pose.points)..removeWhere((k, _) => ls.contains(k)));

/// Fallback inseam: hip row to floor minus k*H.
double fallbackInseam(Sex sex) {
  final k = switch (sex) {
    Sex.male => 0.0313,
    Sex.female => 0.0388,
    Sex.other => (0.0313 + 0.0388) / 2,
  };
  return (bottom - hipRow) * cmPerMaskPx - k * heightCm;
}

void main() {
  group('estimateInseamCm', () {
    test('finds the crotch between separated legs within 1 px', () {
      final mask = personMask();
      final frame = frameOf(mask, aPose());
      final inseam = estimateInseamCm(frame, Silhouette(mask), scale, profileOther);
      // Leg rows crotchRow+1..bottom = 99 rows of 170/215 cm each.
      final truth = (bottom - crotchRow) * cmPerMaskPx;
      expect(inseam, isNotNull);
      expect(inseam!, closeTo(truth, cmPerMaskPx));
      // And it is NOT the hip-offset fallback.
      expect((inseam - fallbackInseam(Sex.other)).abs(), greaterThan(1));
    });

    test('crotch search follows the actual crotch row', () {
      // All inside the 0.42H..0.54H band (crotch rows 125..144 here).
      for (final crotch in [128, 136, 144]) {
        final mask = personMask(crotch: crotch);
        final inseam =
            estimateInseamCm(frameOf(mask, aPose()), Silhouette(mask), scale, profileOther);
        expect(inseam, isNotNull, reason: 'crotch $crotch');
        expect(inseam!, closeTo((bottom - crotch) * cmPerMaskPx, cmPerMaskPx),
            reason: 'crotch $crotch');
      }
    });

    test('legs together fall back to the hip-offset estimate', () {
      final mask = personMask(legsApart: false);
      final frame = frameOf(mask, aPose());
      final inseam = estimateInseamCm(frame, Silhouette(mask), scale, profileOther);
      expect(inseam, isNotNull);
      expect(inseam!, closeTo(fallbackInseam(Sex.other), 1e-6));
    });

    test('fallback offset is sex-specific (other = mean)', () {
      final mask = personMask(legsApart: false);
      final sil = Silhouette(mask);
      final frame = frameOf(mask, aPose());
      final male = estimateInseamCm(frame, sil, scale, profileMale)!;
      final female = estimateInseamCm(frame, sil, scale, profileFemale)!;
      final other = estimateInseamCm(frame, sil, scale, profileOther)!;
      expect(male, closeTo(fallbackInseam(Sex.male), 1e-6));
      expect(female, closeTo(fallbackInseam(Sex.female), 1e-6));
      expect(other, closeTo((male + female) / 2, 1e-9));
      expect(male, greaterThan(female)); // smaller k -> longer inseam
    });

    test('untracked ankles use the fallback even with separable legs', () {
      final mask = personMask();
      final frame = frameOf(mask, aPose(ankleLikelihood: 0.2));
      final inseam = estimateInseamCm(frame, Silhouette(mask), scale, profileOther);
      expect(inseam, closeTo(fallbackInseam(Sex.other), 1e-6));
    });

    test('null when the result is outside 0.42H..0.54H', () {
      // Crotch far too low: 36 leg rows = 28.5 cm.
      final low = personMask(crotch: 199);
      expect(
        estimateInseamCm(frameOf(low, aPose()), Silhouette(low), scale, profileOther),
        isNull,
      );
      // Crotch far too high (legs from row 100: 135 rows = 106.7 cm), with
      // the hip landmarks above it so the crotch search can reach it.
      final high = personMask(crotch: 99);
      expect(
        estimateInseamCm(frameOf(high, aPose(hipRowY: 90)), Silhouette(high),
            scale, profileOther),
        isNull,
      );
    });

    test('crotch search stops at the hip row and falls back', () {
      // Legs merge above the hip landmarks: not a plausible crotch, so the
      // scan gives up there and the hip-offset fallback is used.
      final mask = personMask(crotch: 110);
      final inseam = estimateInseamCm(
          frameOf(mask, aPose()), Silhouette(mask), scale, profileOther);
      expect(inseam, closeTo(fallbackInseam(Sex.other), 1e-6));
    });

    test('null when neither legs nor hips are usable', () {
      final mask = personMask(legsApart: false);
      final pose = without(aPose(), [Landmark.leftHip, Landmark.rightHip]);
      expect(
        estimateInseamCm(frameOf(mask, pose), Silhouette(mask), scale, profileOther),
        isNull,
      );
    });

    test('null on an empty mask', () {
      final empty = BinaryMask(
          width: maskW, height: maskH, confidences: Float32List(maskW * maskH));
      expect(
        estimateInseamCm(frameOf(empty, aPose()), Silhouette(empty), scale, profileOther),
        isNull,
      );
    });
  });

  group('estimateShoulderWidthCm', () {
    test('is 1.15 x the landmark shoulder distance', () {
      final w = estimateShoulderWidthCm(aPose(), scale, profileOther);
      final landmarkCm = 42 * cmPerMaskPx; // shoulders at mask x 43 / 85
      expect(w, isNotNull);
      expect(w!, closeTo(1.15 * landmarkCm, 1e-9));
      expect(w, inInclusiveRange(0.19 * heightCm, 0.28 * heightCm));
    });

    test('null outside 0.19H..0.28H', () {
      // 20 mask px -> 15.8 cm -> 18.2 cm biacromial: too narrow.
      expect(
        estimateShoulderWidthCm(aPose(shoulderHalfSep: 10), scale, profileOther),
        isNull,
      );
      // 70 mask px -> 55 cm -> 63.6 cm: too wide.
      expect(
        estimateShoulderWidthCm(aPose(shoulderHalfSep: 35), scale, profileOther),
        isNull,
      );
    });

    test('null when a shoulder is untracked', () {
      final pose = BodyPose({
        ...aPose().points,
        Landmark.rightShoulder: p(43, 50, 0.3),
      });
      expect(estimateShoulderWidthCm(pose, scale, profileOther), isNull);
      expect(
        estimateShoulderWidthCm(
            without(aPose(), [Landmark.leftShoulder]), scale, profileOther),
        isNull,
      );
    });
  });

  group('estimateSleeveCm', () {
    final chainCm = 2 * math.sqrt(2) * 24 * cmPerMaskPx; // upper + forearm
    final expectedOutseam = 0.983 * chainCm - 1.5;
    final biacromial = 1.15 * 42 * cmPerMaskPx;

    test('outseam from a straight A-pose arm chain', () {
      final r = estimateSleeveCm(aPose(), scale, profileOther);
      expect(r, isNotNull);
      expect(r!.outseamCm, closeTo(expectedOutseam, 1e-9));
    });

    test('shirt sleeve follows the per-sex regression on biacromial + outseam',
        () {
      final male = estimateSleeveCm(aPose(), scale, profileMale)!;
      final female = estimateSleeveCm(aPose(), scale, profileFemale)!;
      final other = estimateSleeveCm(aPose(), scale, profileOther)!;
      expect(male.shirtSleeveCm,
          closeTo(5.6 + 0.795 * biacromial + 0.858 * expectedOutseam, 1e-9));
      expect(female.shirtSleeveCm,
          closeTo(6.2 + 0.662 * biacromial + 0.925 * expectedOutseam, 1e-9));
      expect(other.shirtSleeveCm,
          closeTo((male.shirtSleeveCm + female.shirtSleeveCm) / 2, 1e-9));
      // Outseam itself does not depend on sex.
      expect(male.outseamCm, closeTo(female.outseamCm, 1e-12));
    });

    test('falls back to 0.23H biacromial when shoulders are not measurable',
        () {
      final r = estimateSleeveCm(aPose(shoulderHalfSep: 10), scale, profileMale)!;
      // The chain is unchanged by moving both shoulders inward symmetrically.
      expect(r.outseamCm, closeTo(expectedOutseam, 1e-9));
      expect(r.shirtSleeveCm,
          closeTo(5.6 + 0.795 * (0.23 * heightCm) + 0.858 * expectedOutseam, 1e-9));
    });

    test('a bent arm is ignored and the straight one is used', () {
      // Left elbow angle 90 degrees: wrist pulled back toward the torso.
      final pose = BodyPose({
        ...aPose().points,
        Landmark.leftWrist: p(64 + 21 + 24 - 24, shoulderRow + 24 + 24),
      });
      final r = estimateSleeveCm(pose, scale, profileOther)!;
      expect(r.outseamCm, closeTo(expectedOutseam, 1e-9));
    });

    test('averages both arms when they differ', () {
      final pose = BodyPose({
        ...aPose().points,
        // Right forearm 30 px per axis instead of 24 (still straight).
        Landmark.rightWrist: p(64 - 21 - 24 - 30, shoulderRow + 24 + 30),
      });
      final r = estimateSleeveCm(pose, scale, profileOther)!;
      final rightChain = (24 + 30) * math.sqrt(2) * cmPerMaskPx;
      final rightOutseam = 0.983 * rightChain - 1.5;
      expect(r.outseamCm, closeTo((expectedOutseam + rightOutseam) / 2, 1e-9));
    });

    test('low-likelihood wrist drops that arm', () {
      final pose = BodyPose({
        ...aPose().points,
        Landmark.rightWrist: p(0, 0, 0.1), // garbage but untrusted
      });
      final r = estimateSleeveCm(pose, scale, profileOther)!;
      expect(r.outseamCm, closeTo(expectedOutseam, 1e-9));
    });

    test('null when no arm is usable', () {
      expect(
        estimateSleeveCm(
          without(aPose(), [Landmark.leftWrist, Landmark.rightElbow]),
          scale,
          profileOther,
        ),
        isNull,
      );
      // Both arms bent to 90 degrees.
      final bent = BodyPose({
        ...aPose().points,
        Landmark.leftWrist: p(64 + 21 + 24 - 24, shoulderRow + 24 + 24),
        Landmark.rightWrist: p(64 - 21 - 24 + 24, shoulderRow + 24 + 24),
      });
      expect(estimateSleeveCm(bent, scale, profileOther), isNull);
    });
  });

  group('neck / thigh regressions', () {
    test('neck from chest, per sex', () {
      expect(estimateNeckCm(100, Sex.male), closeTo(15.0 + 23.4, 1e-9));
      expect(estimateNeckCm(100, Sex.female), closeTo(16.9 + 16.9, 1e-9));
      expect(estimateNeckCm(100, Sex.other),
          closeTo((38.4 + 33.8) / 2, 1e-9));
      expect(estimateNeckCm(94, Sex.male), closeTo(36.996, 1e-9));
    });

    test('thigh from hip, per sex', () {
      expect(estimateThighCm(100, Sex.male), closeTo(-10.8 + 71.9, 1e-9));
      expect(estimateThighCm(100, Sex.female), closeTo(-8.9 + 69.1, 1e-9));
      expect(estimateThighCm(100, Sex.other),
          closeTo((61.1 + 60.2) / 2, 1e-9));
      expect(estimateThighCm(102, Sex.female), closeTo(61.582, 1e-9));
    });

    test('are monotonic in the source measurement', () {
      expect(estimateNeckCm(110, Sex.other), greaterThan(estimateNeckCm(90, Sex.other)));
      expect(estimateThighCm(110, Sex.other), greaterThan(estimateThighCm(90, Sex.other)));
    });
  });
}
