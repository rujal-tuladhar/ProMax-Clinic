# FitSize

Measure your **chest, waist and hip** with your phone — so you can buy
clothes online that actually fit. One Flutter codebase, Android + iOS,
everything processed **on-device** (photos are never uploaded and are
deleted right after measuring).

## Two capture modes

FitSize offers two guided capture modes from the home screen:

- **Quick measure (2 photos)** — a front + side photo. Fast (~30 s), works
  on any phone. Expected error ~2–4 cm.
- **Precision measure (full turn)** — a guided slow 360° turn with a photo
  at each of 12 stops. The torso's projected width at every angle
  overdetermines an elliptical cross-section per body part, which is fitted
  with a phase offset and outlier trimming (the `RotationMeasurementEngine`).
  This is the capture style used by the most independently validated systems
  in the segment (Prism Labs, ZOZOFIT), whose published circumference
  repeatability is 0.27–0.81 cm — roughly double the accuracy of two-photo
  capture for about a minute more of the user's time.

Both modes share the same on-device pipeline (pose, segmentation, scale from
height, calibration, size recommendation) and produce the same result
screen.

## What v2 adds (built from the competitive research)

- **The tailor set.** Besides chest/waist/hip the engine now estimates
  inseam (silhouette crotch search, anthropometric fallback), sleeve in both
  tailoring conventions (shoulder→wrist and centre-back→wrist), shoulder
  width, and regression-based neck and thigh (shown as *estimated*). Results
  include garment-aware sizes: jeans **W×L**, dress shirt **neck × sleeve**.
- **Better circumference math.** The ellipse model under-read waist ≈5 cm
  and hip ≈8 cm versus a tape; circumference now uses a linear
  breadth/depth → tape model fitted on ANSUR II (≈6,000 measured bodies),
  per sex. Constants are documented in `lib/engine/circumference.dart`.
- **Brand Size Passport.** `assets/data/brand_charts.json` holds versioned,
  source-dated, confidence-flagged charts for 12 brands (Nike, Adidas, Zara,
  H&M, Uniqlo, Levi's, Gap, lululemon, Under Armour, Amazon Essentials, ASOS,
  Mango). `lib/engine/brand_sizes.dart` resolves your size per brand with
  nearest-band/gap logic, point charts, fit bias, a *between sizes* flag and
  normal-CDF probabilities. See the **My Sizes** screen.
- **Honest sizing.** Sizes read as probabilities ("M (78%) · L (22%)")
  from each measurement's spread, not a single letter.
- **Tap-to-correct.** Any measurement can be corrected with a tape; the
  delta is stored as a personal calibration and applied to future scans.
- **Capture that explains itself.** Low-light gate on the live frame
  ("Find a brighter spot"), feet-apart rule so the inseam is measurable.
- **Privacy receipt.** After each scan: photos processed N · uploaded 0 ·
  stored 0.

⚠️ The brand charts were compiled from published charts via search summaries
(the research sandbox could not open brand pages). Each brand carries a
confidence tag and source URL in the asset; **re-verify every chart on the
brand's site before shipping sizing claims.**

## How it works

1. **Onboarding** — enter your height (the metric scale reference), sex and
   units.
2. **Guided capture** — prop the phone upright at hip height (or have a
   friend hold it), step 2–3 m back, and follow the voice coaching. The app
   *refuses to capture* until on-device pose detection confirms the stance.
   In **quick mode**:
   - **Front view**: facing the camera, standing tall, arms raised ~45°
     from the body (A-pose).
   - **Side view**: turned 90°, arms raised straight forward ("sleepwalker"
     pose) so they clear the waist/hip outline.
   The phone must be upright (tilt gate via accelerometer). When the pose
   has held steady for 1.5 s you hear *"Breathe out gently and hold still"*
   (the WHO-standard end-of-exhale capture phase), a spoken 3-2-1, then a
   5-photo burst per view.
3. **Measurement** — per frame: person segmentation → silhouette,
   pose landmarks → chest/waist/hip row location (natural-waist =
   narrowest trunk row, hip = widest row below the hip joints), entered
   height → pixel-to-cm scale, then front width + side depth combined as an
   ellipse (Ramanujan II with per-part calibration factors). Median across
   frames with outlier rejection; cross-view scale consistency checks.
4. **Results** — each measurement with ± spread and a confidence chip
   (low confidence → retake recommended), plus a recommended top/bottom
   clothing size.

## Repo layout

```
lib/
  models/models.dart        shared data models (pinned contract)
  engine/                   pure-Dart measurement core (fully unit-tested)
  services/                 ML Kit pose + segmentation, TTS, tilt, storage
  capture/                  guided-capture state machine
  screens/, widgets/        UI
docs/CONTRACTS.md           module contracts the code was built against
test/                       86 tests (engine math + widget smoke tests)
```

## Build & run

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(built against Flutter 3.47 / Dart 3.13).

```bash
cd fitsize
flutter pub get
flutter test          # 86 tests should pass
flutter analyze       # should report no issues
```

**Android** (needs the Android SDK; a real device — the camera and ML Kit
don't work in emulators for this use case):

```bash
flutter build apk --release      # or: flutter run
```

**iOS** (needs a Mac with Xcode; a real device):

```bash
cd ios && pod install && cd ..
flutter run                       # or open ios/Runner.xcworkspace in Xcode
```

Camera permission is declared for both platforms (`AndroidManifest.xml`,
`Info.plist`). Min Android SDK 24, iOS 15.5+ per ML Kit requirements.

## The segment & where FitSize sits

Body-measurement-for-sizing is a crowded, mostly B2B segment. The players:

| Product | Capture | Licensable |
| --- | --- | --- |
| 3DLOOK (Mobile Tailor) | 2 photos | ✅ market leader for retail sizing |
| Bodygram | 2 photos | ✅ documented API/SDK |
| MeThreeSixty (Size Stream) | 2 photos | B2B white-label; most peer-reviewed |
| **Prism Labs** | **360° turn** | ✅ **best published repeatability (0.27–0.81 cm)** |
| ZOZOFIT | 360° turn | consumer only |
| Presize | turn video | ❌ acquired by Meta (2022) |
| Amazon Halo | 3–4 photos + CNN | ❌ discontinued (2023) |

The top performer by independent evidence is the **360° self-rotation
class** (Prism Labs / ZOZOFIT): peer-reviewed work (EJCN 2024) shows
rotation capture matches in-booth scanners while two-photo apps trail.
FitSize's **Precision mode is built on that approach** — the differentiator
being that it runs **fully on-device** (no upload of body photos), which the
cloud-based incumbents do not. See the research brief for the full survey.

## Accuracy — honest expectations

This v1 implements the best *geometric* 2-photo pipeline the evidence
supports. Peer-reviewed context:

- Trained human with a tape repeats to ~0.9–1.4 cm; self-measurement errs
  ~2.8%.
- Well-executed 2-photo geometry: expect **~2–4 cm** typical error.
- Clothing size buckets are ~4–8 cm wide, so this is sufficient to pick a
  size in most cases — but calibrate before making accuracy claims:
  the per-part shape factors in `lib/engine/circumference.dart`
  (`Calibration.standard`) and the size charts in
  `lib/engine/size_recommender.dart` are literature-informed defaults meant
  to be tuned against tape-measure ground truth (≥70 subjects across BMI
  ranges, Bland-Altman analysis, target MAE ≤ 2 cm).

What moves accuracy most (all enforced or coached by the app): tight
clothing, correct pose, end-exhale capture, accurate entered height, even
lighting, repeat scans.

## Roadmap

- **✅ Done — rotation (precision) capture**: a guided 360° turn with a
  cross-section ellipse fit per body part. The proven class (Prism Labs,
  ZOZOFIT, Presize): precision reaches ~1–2 cm, no new hardware. Shipped as
  the "Precision measure" mode (`lib/engine/rotation_engine.dart`,
  `lib/capture/turn_capture_controller.dart`,
  `lib/screens/turn_capture_screen.dart`).
- **✅ Done — v2 differentiators**: tailor measurements, ANSUR
  circumference model, Brand Size Passport, probabilistic sizes,
  tap-to-correct, low-light gate, privacy receipt (see above).
- **Next — validation study**: 70–120 people across body types, trained
  tape measurer, Bland-Altman; publish per-cohort accuracy in-app and tune
  the calibration constants. Required before any accuracy claim.
- **Next — "Did it fit?" loop**: log brand/garment/size and the outcome;
  learn a per-brand correction; show returns avoided.
- **Next — more turn stops / continuous frames**: capture ~150 frames
  through a continuous turn rather than 12 discrete stops, with a motion
  watchdog, for further noise averaging.
- **Next — more brands and size systems**: Shein, Temu, Target, Old Navy,
  Abercrombie; US/UK/EU/JP conversions; per-product charts for Zara/Uniqlo.
- **v2+ — learned body model**: fit a parametric 3D body model to the
  silhouettes instead of per-row geometry (note: SMPL/SMPL-X need a
  commercial licence via Meshcapade).
- **v3 — LiDAR precision mode** (iPhone Pro only): a short waist-level
  depth ring fused into the model fit as an extra constraint.
- Multi-person rejection (currently the most prominent detected person is
  used), additional measurement sites (inseam, sleeve), size-chart
  configuration per store.
