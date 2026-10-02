# FitSize

Measure your **chest, waist and hip** with your phone — so you can buy
clothes online that actually fit. One Flutter codebase, Android + iOS,
everything processed **on-device** (photos are never uploaded and are
deleted right after measuring).

## How it works

1. **Onboarding** — enter your height (the metric scale reference), sex and
   units.
2. **Guided capture** — prop the phone upright at hip height (or have a
   friend hold it), step 2–3 m back, and follow the voice coaching. The app
   *refuses to capture* until on-device pose detection confirms the stance:
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

- **v2 — rotation capture**: replace 2 stills with a guided slow 360°
  self-turn (~150 frames, clock-position voice prompts). The proven class
  (Prism Labs, ZOZOFIT, Presize): precision reaches ~1–2 cm. Biggest
  accuracy upgrade, no new hardware.
- **v2+ — learned body model**: fit a parametric 3D body model to the
  silhouettes instead of per-row geometry (note: SMPL/SMPL-X need a
  commercial licence via Meshcapade).
- **v3 — LiDAR precision mode** (iPhone Pro only): a short waist-level
  depth ring fused into the model fit as an extra constraint.
- Multi-person rejection (currently the most prominent detected person is
  used), additional measurement sites (inseam, sleeve), size-chart
  configuration per store.
