# FitSize — module contracts

FitSize is a Flutter app (Android + iOS) that measures a person's **chest,
waist and hip circumference** from two guided photos (front + side), entirely
on-device, so online shoppers can pick the right clothing size. The person
props the phone upright (or a friend holds it), steps back, and follows voice
+ on-screen coaching; the app refuses to capture until the pose is right.

**Measurement principle:** person segmentation gives a silhouette; pose
landmarks locate the chest/waist/hip rows; the user's entered height converts
pixels to cm; front width + side depth at each row are combined as an ellipse
(Ramanujan II) with a per-part shape correction to produce circumference.
Multiple burst frames are captured per view and combined with median/MAD
outlier rejection.

`lib/models/models.dart` is ALREADY WRITTEN and pinned — read it first.
All other modules must implement EXACTLY the public APIs below. Keep
`lib/engine/` pure Dart (`dart:math`, `dart:typed_data`, models only —
no Flutter, no plugin imports) so it is unit-testable.

Capture protocol (fixed; UX copy and gating must match):
- FRONT view: facing camera, A-pose — arms straight, raised ~45° from the
  body side, feet ~10 cm apart, standing tall, tight clothing.
- SIDE view: turned 90° (left shoulder to camera), arms raised straight
  FORWARD to horizontal ("sleepwalker" pose) so arms clear the waist/hip
  outline; chest row sits below the raised arms.
- Phone upright (|pitch| < 8°), person fills 65–90% of frame height,
  horizontally centered within ±12% of frame width.
- Burst: 5 stills per view.

---

## lib/engine/silhouette.dart  (pure Dart)

```dart
import 'dart:typed_data';
import '../models/models.dart';

/// Sub-pixel horizontal span of the torso at one mask row.
class RowSpan {
  final double left;   // mask x, subpixel
  final double right;  // mask x, subpixel; right > left
  const RowSpan(this.left, this.right);
  double get width => right - left;
  double get center => (left + right) / 2;
}

class Silhouette {
  /// [threshold]: mask confidence >= threshold counts as body.
  Silhouette(BinaryMask mask, {double threshold = 0.5});

  int get width;
  int get height;

  /// First/last mask row containing any body pixel (subpixel-refined via
  /// confidence interpolation at those boundary rows is NOT required —
  /// integer rows returned as double). Null if the mask is empty.
  double? get topY;
  double? get bottomY;

  /// Body height in mask pixels (bottomY - topY), or null if empty.
  double? get bodyHeightPx;

  /// All contiguous foreground runs on row y (integer row, clamped),
  /// each edge refined to subpixel by linear interpolation of the
  /// confidence crossing of [threshold] against the neighbouring pixel.
  List<RowSpan> runsAt(int y);

  /// The torso run at row y: the run whose horizontal range contains
  /// [torsoCenterX] (mask coords); if none contains it, the nearest run
  /// by center distance; null if the row has no runs.
  RowSpan? torsoSpanAt(int y, double torsoCenterX);
}
```

## lib/engine/body_rows.dart  (pure Dart)

```dart
import '../models/models.dart';
import 'silhouette.dart';

/// Vertical positions (mask row coords) of the measurement rows.
class BodyRows {
  final double chestY;
  final double waistY;
  final double hipY;
  const BodyRows({required this.chestY, required this.waistY, required this.hipY});
}

/// Fractions of the shoulder→hip-joint span locating each row; computed on
/// front frames, reused on side frames so both views measure the same
/// anatomical level.
class RowFractions {
  final double chest; // default 0.22
  final double waist; // found by narrowest-width search, default 0.72
  final double hip;   // found by widest-width search below hip joints,
                      // expressed as fraction >1 of the span, default 1.15
  const RowFractions({required this.chest, required this.waist, required this.hip});
  static const RowFractions defaults =
      RowFractions(chest: 0.22, waist: 0.72, hip: 1.15);
}

/// Derive row fractions from ONE front frame:
/// - shoulderY = mid(leftShoulder,rightShoulder).y, hipY = mid hips, both
///   projected to mask coords; span = hipJointY - shoulderY (must be > 0).
/// - chest fraction fixed at 0.22.
/// - waist: scan integer rows in band [shoulderY + 0.50*span,
///   hipJointY - 0.02*span]; pick the row with MINIMUM torso-run width
///   (torsoCenterX = mid-hip x in mask coords); fraction = (rowY - shoulderY)/span.
/// - hip: scan band [hipJointY, hipJointY + 0.45*span]; pick MAXIMUM torso
///   width; fraction = (rowY - shoulderY)/span.
/// Returns null when shoulders/hips are missing or span is degenerate.
RowFractions? rowFractionsFromFrontFrame(SilhouetteFrame frame, Silhouette sil);

/// Median-combine fractions from several front frames; returns
/// RowFractions.defaults when the list is empty.
RowFractions medianRowFractions(List<RowFractions> fractions);

/// Apply fractions to any frame (front or side) using its own landmarks:
/// rowY = shoulderY + fraction * (hipJointY - shoulderY), in mask coords.
/// Null when landmarks are missing.
BodyRows? rowsForFrame(SilhouetteFrame frame, RowFractions fractions);
```

## lib/engine/circumference.dart  (pure Dart)

```dart
import '../models/models.dart';

/// Ramanujan II approximation of an ellipse perimeter with semi-axes a, b.
double ellipsePerimeter(double a, double b);

/// Per-part multiplicative shape corrections (body cross-sections are not
/// true ellipses). Defaults are literature-informed starting points and are
/// expected to be tuned against tape-measure ground truth.
class Calibration {
  final Map<BodyPart, double> shapeFactor;
  const Calibration(this.shapeFactor);
  static const Calibration standard = Calibration({
    BodyPart.chest: 0.97,
    BodyPart.waist: 0.99,
    BodyPart.hip: 1.01,
  });
  double factorFor(BodyPart part);
}

/// frontWidthCm = full silhouette width (2a), sideDepthCm = full depth (2b).
/// Returns ellipsePerimeter(a, b) * calibration.factorFor(part).
double circumferenceFromWidths({
  required double frontWidthCm,
  required double sideDepthCm,
  required BodyPart part,
  Calibration calibration = Calibration.standard,
});
```

## lib/engine/stats.dart  (pure Dart)

```dart
/// Median of a non-empty list (does not mutate input).
double median(List<double> xs);
/// Median absolute deviation.
double mad(List<double> xs);
/// Keep values within k*MAD of the median (k default 3); if MAD == 0
/// returns the input unchanged.
List<double> rejectOutliers(List<double> xs, {double k = 3});
/// Sample standard deviation (0 for n < 2).
double stdDev(List<double> xs);
```

## lib/engine/measurement_engine.dart  (pure Dart)

```dart
import '../models/models.dart';
import 'body_rows.dart'; import 'circumference.dart'; import 'silhouette.dart'; import 'stats.dart';

class MeasurementEngine {
  final Calibration calibration;
  const MeasurementEngine({this.calibration = Calibration.standard});

  /// Throws [MeasurementException] (message string field) when front or side
  /// is empty or no frame yields usable geometry.
  ///
  /// Pipeline per frame: Silhouette(mask) -> cm/px scale =
  /// profile.heightCm / (bodyHeightPx / maskScaleY)  [body height converted
  /// to IMAGE pixels] -> rows (fractions from front frames) -> torso widths
  /// at the three rows (mask px -> image px via /maskScaleX -> cm via scale).
  /// Frames whose implied scale deviates >5% from the median scale are
  /// dropped. Median widths per part per view -> circumferenceFromWidths ->
  /// PartMeasurement with stdDev propagated from frame spread and
  /// confidence = agreement score (1 - clamp(cv*8, 0, 0.8)) * pose likelihood.
  MeasurementResult compute({
    required List<SilhouetteFrame> front,
    required List<SilhouetteFrame> side,
    required UserProfile profile,
  });
}

class MeasurementException implements Exception {
  final String message;
  const MeasurementException(this.message);
}
```

## lib/engine/quality.dart  (pure Dart — used for live capture gating)

```dart
import '../models/models.dart';

enum PoseIssue {
  noPerson, tooFar, tooClose, notCentered, notFacingCamera, notSideways,
  armsNotRaised, armsTooHigh, notUpright,
}

class PoseCheckResult {
  final bool ok;                 // true when issues is empty
  final List<PoseIssue> issues;  // ordered most-important-first
  const PoseCheckResult(this.issues);
  bool get okNow => issues.isEmpty;
}

/// Landmark-likelihood gate: core landmarks (shoulders, hips, ankles) must
/// each have likelihood >= 0.5, else [PoseIssue.noPerson].
/// Framing: body height (min head-y to max ankle-y) 65–90% of imageHeight
/// (tooFar / tooClose); body center-x within ±12% of image center
/// (notCentered).
/// FRONT pose: shoulder left/right x-separation >= 0.12 * body height
/// (else notFacingCamera); both arm angles (elbow relative to the vertical
/// through the shoulder) between 25° and 75° (armsNotRaised / armsTooHigh);
/// shoulder-mid above hip-mid by >= 0.2 * body height (notUpright).
PoseCheckResult checkFrontPose(BodyPose pose, int imageWidth, int imageHeight);

/// SIDE pose: shoulder x-separation < 0.08 * body height (else notSideways);
/// wrists roughly at shoulder height: |wristY - shoulderY| <= 0.12 * body
/// height AND wrist displaced horizontally from shoulder by >= 0.10 * body
/// height (armsNotRaised). Framing rules as above.
PoseCheckResult checkSidePose(BodyPose pose, int imageWidth, int imageHeight);

/// Human-readable instruction for the FIRST issue, e.g. tooFar -> "Step
/// closer to the camera", armsNotRaised(front) -> "Raise your arms away
/// from your body". Signature:
String instructionFor(PoseIssue issue, CaptureView view);
```

## lib/engine/size_recommender.dart  (pure Dart)

```dart
import '../models/models.dart';

class SizeRecommendation {
  final String topSize;     // from chest, e.g. "M"
  final String bottomSize;  // from max(waist-driven, hip-driven) size
  final Map<BodyPart, String> perPart; // size letter per measured part
  const SizeRecommendation({required this.topSize, required this.bottomSize, required this.perPart});
}

class SizeRecommender {
  /// Embedded unisex-ish charts per sex (XS..XXL cm ranges for chest,
  /// waist, hip; sensible values — document them in code comments).
  /// Missing parts fall back to "–".
  /// [fit] biases the lookup for between-sizes cases: slim shifts each
  /// measurement -3 cm before lookup, relaxed +3 cm, regular unchanged.
  static SizeRecommendation recommend(MeasurementResult result, Sex sex,
      {FitPreference fit = FitPreference.regular});
}
```

Additive model changes since v1 (models.dart): `enum FitPreference { slim,
regular, relaxed }`; `UserProfile.fit` (default `FitPreference.regular`,
serialised, with `copyWith`). Every existing call site keeps working.

## lib/engine/rotation_engine.dart  (pure Dart — precision turn mode)

`RotationFrame {SilhouetteFrame frame; double angleDegrees}` (instructed
yaw, 0 = facing camera). `fitEllipseWidths(List<(angleDeg, widthCm)>) ->
EllipseFit?` fits a² / b² by closed-form least squares per candidate phase
(±25° grid), trims the worst 20% residuals and refits. `RotationMeasurementEngine
.compute({frames, profile}) -> MeasurementResult` (same output model as the
two-view engine). Companion gate `checkTurnPose` (quality.dart) applies the
framing rules only. Capture: `lib/capture/turn_capture_controller.dart`,
`lib/screens/turn_capture_screen.dart`, route `/capture-turn`.

## lib/services/pose_service.dart

```dart
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import '../models/models.dart';

/// Wraps google_mlkit_pose_detection. Stream mode for live gating,
/// single-image mode for captured stills.
class PoseService {
  PoseService({bool streamMode = true});
  /// Detect on a live CameraImage. Returns pose in UPRIGHT image
  /// coordinates together with the upright image size.
  Future<(BodyPose, int width, int height)?> detectFromCameraImage(
    CameraImage image,
    CameraDescription description,
    DeviceOrientation deviceOrientation,
  );
  Future<(BodyPose, int width, int height)?> detectFromFile(String path);
  Future<void> dispose();
}
```
Implementation notes: build `InputImage` from camera planes using
`google_mlkit_commons` metadata (NV21 on Android — use the camera plugin's
`ImageFormatGroup.nv21`; BGRA8888 on iOS). Compute rotation from sensor
orientation + device orientation + lens direction (standard ML Kit formula).
Map ML Kit `PoseLandmarkType` -> `Landmark` (17 used); translate coordinates
to upright orientation when rotation is 90/270 (swap/flip as needed) so that
returned width/height describe the upright image.

## lib/services/segmentation_service.dart

```dart
import '../models/models.dart';

/// Wraps google_mlkit_selfie_segmentation (single-image mode).
class SegmentationService {
  Future<BinaryMask?> maskFromFile(String path);
  Future<void> dispose();
}
```

## lib/services/tts_service.dart

```dart
/// Wraps flutter_tts; queue-free: speak() interrupts current utterance when
/// interrupt=true. Never throws when the platform has no TTS voice — fail
/// silent. Also exposes a 150ms-debounced `coach(String)` that skips
/// repeating the same phrase twice in a row.
class TtsService {
  Future<void> init();
  Future<void> speak(String text, {bool interrupt = true});
  Future<void> coach(String text);
  Future<void> stop();
  Future<void> dispose();
}
```

## lib/services/tilt_service.dart

```dart
/// Accelerometer-based phone pitch. 0° == phone perfectly upright
/// (portrait, screen facing the subject). Positive = leaning back.
class TiltService {
  void start();
  void stop();
  Stream<double> get pitchDegrees;   // broadcast, ~10 Hz
  double? get latestPitch;
}
```

## lib/services/profile_store.dart

```dart
import '../models/models.dart';

/// shared_preferences-backed persistence for profile + last results.
class ProfileStore {
  Future<UserProfile?> loadProfile();
  Future<void> saveProfile(UserProfile profile);
  Future<List<MeasurementResult>> loadHistory();          // newest first
  Future<void> addResult(MeasurementResult result);       // keep max 20
}
```

## lib/capture/capture_controller.dart

```dart
import 'package:flutter/foundation.dart';
import '../models/models.dart';
import '../engine/quality.dart';
import '../services/tts_service.dart';

enum CaptureStage {
  intro,            // explains setup; advances on user tap
  positioningFront, // live gating until front pose ok for ~1.5s continuous
  countdownFront,   // spoken 3..2..1
  capturingFront,   // burst in progress
  positioningSide,
  countdownSide,
  capturingSide,
  processing,
  done,
  failed,
}

/// Pure logic + TTS; the camera screen feeds it pose results and executes
/// capture bursts when asked. ChangeNotifier so the UI can rebuild.
class CaptureController extends ChangeNotifier {
  CaptureController({required TtsService tts, this.framesPerBurst = 5});

  CaptureStage get stage;
  String get instruction;          // current on-screen instruction text
  PoseCheckResult? get lastCheck;  // for overlay colouring
  int get countdownValue;          // 3..1 during countdown stages

  /// Wire-up: the screen sets this; controller calls it to run a burst and
  /// the screen resolves with captured frames for [view].
  Future<List<SilhouetteFrame>> Function(CaptureView view)? burstCaptor;

  /// Called when both bursts are done; receives front+side frames.
  void Function(List<SilhouetteFrame> front, List<SilhouetteFrame> side)?
      onReadyToProcess;

  void start();                                   // intro -> positioningFront
  void confirmIntro();
  /// Feed ~5–15 Hz live pose checks; drives gating, coaching and countdown.
  /// stability window: pose must stay ok for >= 1.5s before countdown; a
  /// failing check during countdown aborts back to positioning. Tilt gate:
  /// |pitchDegrees| > 8 blocks with instruction "Stand the phone upright".
  void onPoseCheck(PoseCheckResult check, CaptureView view, {double? pitchDegrees});
  void reset();
}
```
The controller speaks instructions via `tts.coach(...)` whenever the
instruction changes, announces view transitions ("Great. Now turn to your
left and raise your arms forward"), and counts down aloud.

## UI (Material 3, seeded teal theme, dark-mode aware)

- `lib/main.dart` — `FitSizeApp`; routes: `/` HomeScreen, `/onboarding`,
  `/capture`, `/results`. Shows onboarding first when no profile saved.
- `lib/screens/onboarding_screen.dart` — height (cm or ft+in picker), sex,
  units; saves via ProfileStore; friendly copy about privacy (all on-device).
- `lib/screens/home_screen.dart` — start measurement CTA, last result cards,
  "how it works" tips (tight clothing, clear background, prop phone at hip
  height, 2–3 m distance), history list.
- `lib/screens/capture_screen.dart` — owns CameraController (front camera
  default, toggle available; `ImageFormatGroup.nv21` on Android /
  `bgra8888` on iOS), streams frames to PoseService (process every Nth
  frame, drop while busy), feeds CaptureController, renders:
  camera preview, pose-status silhouette outline (green when ok), issue
  banner with `instructionFor`, big countdown digits, progress dots for the
  two views. Executes bursts: stop stream -> 5x takePicture ->
  PoseService.detectFromFile + SegmentationService.maskFromFile ->
  SilhouetteFrame list (skip frames where either fails) -> resume.
  On processing stage: run MeasurementEngine.compute in a background isolate
  via `compute()`, then Navigator to results. Handles permission denial with
  a friendly screen.
- `lib/screens/results_screen.dart` — cards per part (value in profile
  units, ± stdDev, confidence chip), SizeRecommender output, disclaimer
  ("estimates for sizing, not medical use"), buttons: measure again, done
  (saves via ProfileStore).
- `lib/widgets/pose_overlay.dart` — paints guide silhouette + state colour.
- `lib/widgets/measure_card.dart` — result card widget.

## Platform config

- Android: `minSdk 24`, CAMERA permission in manifest.
- iOS: `NSCameraUsageDescription` + `NSSpeechRecognition...` not needed;
  add `NSPhotoLibraryUsageDescription` only if saving photos (we don't).
  Camera requires a real device.
- All processing on-device; no network calls anywhere in the app.

## Tests (flutter_test, pure Dart — must pass with `flutter test`)

- `test/engine/silhouette_test.dart` — synthetic masks: runs, subpixel
  edges, torso-run selection with detached "arm" blobs, top/bottom.
- `test/engine/circumference_test.dart` — circle == 2πr (factor 1 part),
  Ramanujan vs known ellipse values, calibration factors applied.
- `test/engine/body_rows_test.dart` — synthetic hourglass silhouette:
  waist found at narrowest row, hip at widest, fractions median.
- `test/engine/stats_test.dart` — median/mad/outliers/stdDev.
- `test/engine/quality_test.dart` — synthetic poses triggering each issue
  and a passing front + side pose.
- `test/engine/measurement_engine_test.dart` — synthetic front+side frames
  of an "elliptic cylinder person" with known height -> circumference within
  1.5% of analytic truth; scale-outlier frame dropped; exception on empty.
- `test/engine/size_recommender_test.dart` — chart boundaries.

---

# v2 contracts — differentiator build (October 2026)

Research-driven additions. All changes to existing types are ADDITIVE unless
stated. Pure-Dart rule for `lib/engine/` still applies.

## models.dart (additive)

```dart
enum BodyPart { chest, waist, hip, neck, shoulder, sleeve, shirtSleeve, inseam, thigh }
enum MeasurementKind { circumference, length }

extension BodyPartLabel on BodyPart {           // existing extension, extended
  String get label;      // Chest, Waist, Hip, Neck, Shoulder width,
                         // Sleeve (shoulder to wrist), Shirt sleeve (centre back to wrist),
                         // Inseam, Thigh
  MeasurementKind get kind;   // chest/waist/hip/neck/thigh = circumference; rest = length
  bool get isCircumference;
}
/// Parts measured directly from silhouette widths (front + side / turn).
const List<BodyPart> kTorsoParts = [BodyPart.chest, BodyPart.waist, BodyPart.hip];

class PartMeasurement {   // + one optional field, default false, in JSON
  final bool derived;     // true when estimated from other measurements (neck, thigh, shirtSleeve)
}

class UserProfile {       // + one optional field, default const {}, in JSON + copyWith
  /// Tap-to-correct calibration: tape value minus app value, per part (cm).
  /// Added to every future measurement of that part.
  final Map<BodyPart, double> offsetsCm;
}
```

## engine/circumference.dart (behaviour change, same entry point)

`circumferenceFromWidths({frontWidthCm, sideDepthCm, part, Sex sex = Sex.other,
Calibration calibration = Calibration.standard})` now uses the ANSUR II
breadth/depth → tape linear model instead of a Ramanujan ellipse (the
ellipse under-reads waist ≈5 cm and hip ≈8 cm vs tape). Coefficients in cm
(circ = a + b·breadth + c·depth):

| part  | male                       | female                    |
|-------|----------------------------|---------------------------|
| chest | −1.38 + 1.548·b + 2.460·d  | 5.04 + 1.198·b + 2.320·d  |
| waist | 0.94 + 1.663·b + 1.633·d   | 2.96 + 1.776·b + 1.402·d  |
| hip   | 5.90 + 1.841·b + 1.318·d   | 7.43 + 1.861·b + 1.238·d  |

`Sex.other` = mean of the two predictions. `Calibration.standard` factors are
now all 1.0 (multiplicative tape-equivalence placeholders for the validation
study). `ellipsePerimeter(a, b)` stays exported. Document the chest caveat:
ANSUR chest breadth is caliper-compressed, so silhouette-based chest may read
high until calibrated. Only `kTorsoParts` are valid `part` values here.

## engine/extra_measurements.dart (new, pure Dart)

```dart
/// Inseam (crotch → floor), cm. Preferred: silhouette crotch — scan mask rows
/// upward from the ankle rows within the column band between the two ankle
/// landmarks (mask coords); the crotch row is the first row (from below) where
/// the two leg runs merge into one run. Floor row = Silhouette.bottomY.
/// Fallback (legs not separable): hipJointY + k·H below the hip-landmark row,
/// k = 0.0313 (male) / 0.0388 (female) / mean (other), H = profile.heightCm.
/// Returns null unless 0.42·H ≤ inseam ≤ 0.54·H.
double? estimateInseamCm(SilhouetteFrame frame, Silhouette sil, double scaleCmPerImagePx, UserProfile profile);

/// Sleeve from the landmark chain shoulder→elbow→wrist of each arm (image px → cm):
/// outseam = 0.983·(upper + fore) − 1.5 (joint-centre → acromion/stylion correction).
/// Use an arm only when shoulder/elbow/wrist likelihood ≥ 0.5 and the elbow angle ≥ 150°;
/// average the usable arms; null when none. shirtSleeve (centre back → wrist) =
/// 5.6 + 0.795·biacromial + 0.858·outseam (male) / 6.2 + 0.662·biacromial + 0.925·outseam (female) / mean,
/// with biacromial from estimateShoulderWidthCm (fallback 0.23·H).
({double outseamCm, double shirtSleeveCm})? estimateSleeveCm(BodyPose pose, double scaleCmPerImagePx, UserProfile profile);

/// Biacromial shoulder width = 1.15 × landmark shoulder distance (cm); null unless 0.19·H..0.28·H.
double? estimateShoulderWidthCm(BodyPose pose, double scaleCmPerImagePx, UserProfile profile);

/// Regression estimates (derived parts): neck = 15.0 + 0.234·chest (male) / 16.9 + 0.169·chest (female);
/// thigh = −10.8 + 0.719·hip (male) / −8.9 + 0.691·hip (female); Sex.other = mean.
double estimateNeckCm(double chestCm, Sex sex);
double estimateThighCm(double hipCm, Sex sex);
```

Both engines (`MeasurementEngine`, `RotationMeasurementEngine`) add, after the
torso parts: inseam, sleeve, shirtSleeve, shoulder from the FRONT(-ish) frames
(median across frames, stdDev from spread, confidence as for torso parts),
then neck (from chest) and thigh (from hip) with `derived: true` and
confidence = 0.6 × source confidence. Finally apply `profile.offsetsCm` to
every part's valueCm. Parts that cannot be estimated are simply omitted.

## engine/quality.dart (additive)

```dart
enum PoseIssue { noPerson, tooFar, tooClose, notCentered, lowLight, notFacingCamera, notSideways,
                 armsNotRaised, armsTooHigh, notUpright, feetTogether }
// checkFrontPose: + feetTogether when ankle x-separation < 0.08 × body height
//   (legs must be separable for the inseam crotch search).
// instructionFor: lowLight → 'Find a brighter spot or turn on a light';
//                 feetTogether → 'Stand with your feet a little apart'.
/// Mean luma 0..255 of a camera Y plane, sampling every [stride]-th byte.
double meanLuma(Uint8List yPlane, {int stride = 97});
bool isTooDark(double meanLuma); // < 60
```

## engine/brand_sizes.dart (new, pure Dart) + assets/data/brand_charts.json

JSON shape (versioned, source-dated, confidence per brand):
```json
{"version":"2026.10","brands":[{"brand":"Nike","source":"https://…","retrieved":"2026-10-03",
  "confidence":"high|medium|low","notes":"…",
  "charts":[{"gender":"men|women","category":"tops|bottoms","measure":"chest|waist|hip|inseam",
             "unit":"cm","sizes":[{"label":"M","min":96,"max":104}]}]}]}
```
Point-value charts are stored with min == max.

```dart
class BrandCatalog { static BrandCatalog fromJson(String json); String get version; List<Brand> get brands; }
class Brand { String brand, source, retrieved, confidence, notes; List<BrandChart> charts; }
class BrandChart { String gender, category, measure, unit; List<SizeBand> sizes; bool get isPointChart; }
class SizeBand { String label; double min, max; }

class SizeLookup {
  final String label;                 // best size
  final bool between;                 // within 1.5 cm of a boundary, or in a chart gap
  final String? alternative;          // the neighbouring size when between
  final Map<String, double> probabilities; // normal CDF mass per label, sd = max(sdCm, 1.0)
}
class BrandSizeMatch {
  final Brand brand; final String gender;
  final SizeLookup? top;     // from chest (tops chart)
  final SizeLookup? bottom;  // bottoms: waist and hip looked up separately, the LARGER size wins
  final String? note;        // e.g. 'Hip chart not published — waist only'
}
class BrandSizeResolver {
  BrandSizeResolver(BrandCatalog catalog);
  /// Range charts with gaps → nearest band by distance; point charts → nearest point
  /// (boundaries at midpoints). Fit bias as SizeRecommender: slim −3 cm, relaxed +3 cm.
  SizeLookup lookup(BrandChart chart, double valueCm, {double sdCm = 1.5, FitPreference fit = FitPreference.regular});
  /// Sex.male → men charts, female → women, other → women then men.
  List<BrandSizeMatch> matchAll(MeasurementResult result, Sex sex, {FitPreference fit = FitPreference.regular});
}
```

## UI additions

- `lib/screens/my_sizes_screen.dart`, route `/my-sizes` (argument:
  MeasurementResult; when absent, use the newest ProfileStore history entry).
  Loads the JSON with `rootBundle.loadString('assets/data/brand_charts.json')`.
  Per brand: top / bottom size, 'between X and Y' chip with the fit-preference
  hint, probability text ('M 78% · L 22%'), chart confidence tag, source +
  retrieved date, note. Search box filters brands. Disclaimer: 'From published
  size charts (Oct 2026). Verify on the brand site before ordering.'
- Home: card 'Your size at 12 brands' (when a result exists) → `/my-sizes`.
- Results: button 'Your size at 12 brands →'; generic sizes shown with
  probabilities ('M (78%) · L (22%)'); garment-aware line: jeans W×L (waist
  inches nearest 1, inseam inches nearest 1), dress shirt neck (nearest ½ in,
  from BodyPart.neck) × sleeve (shirtSleeve inches nearest 1); tap any
  measurement card → 'Correct with a tape' dialog → saves
  `offsetsCm[part] = tape − measured` on the profile and shows the corrected
  value with a '✎ corrected' marker; 'Privacy receipt' card: photos processed
  N (frontFrameCount + sideFrameCount), uploaded 0, stored 0.
- SizeRecommender: `recommendWithProbabilities(result, sex, {fit}) ->
  SizeRecommendation` where `SizeRecommendation` gains
  `Map<String,double> topProbabilities, bottomProbabilities`; and
  `GarmentSizes garmentSizes(result, {fit})` → `{String? jeans, String? shirt}`.
- Capture screens: low-light gate (meanLuma of CameraImage planes[0].bytes →
  `PoseIssue.lowLight` instruction); intro copy adds 'feet a little apart'.
