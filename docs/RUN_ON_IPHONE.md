# Run FitSize on your iPhone (free Apple ID, no paid developer account)

Takes about 20–30 minutes the first time, most of it downloads. You need a
Mac, Xcode, an iPhone on iOS 15.5 or newer, and a USB cable.

## 1. Install the tools (once)

1. **Xcode** — install from the Mac App Store (large download). Open it once,
   accept the licence, and let it install the iOS platform when prompted
   (Xcode → Settings → Components/Platforms → iOS).
2. **Flutter** — in Terminal:
   ```bash
   brew install --cask flutter      # or download from docs.flutter.dev
   flutter doctor                   # follow any red items it reports
   ```
3. **CocoaPods** (the iOS dependency manager):
   ```bash
   brew install cocoapods
   ```

## 2. Get the code

```bash
git clone https://github.com/rujal-tuladhar/Camera-Size-Measurement.git
cd Camera-Size-Measurement
flutter pub get
cd ios && pod install && cd ..
```

## 3. Sign it with your Apple ID

1. Open `ios/Runner.xcworkspace` in Xcode (the **.xcworkspace**, not the
   .xcodeproj):
   ```bash
   open ios/Runner.xcworkspace
   ```
2. Xcode → Settings → **Accounts** → **+** → sign in with your Apple ID.
3. In the left sidebar click **Runner** (blue icon) → target **Runner** →
   **Signing & Capabilities** tab:
   - tick **Automatically manage signing**
   - **Team**: pick *Your Name (Personal Team)*
   - if Xcode says the bundle identifier is unavailable, change
     **Bundle Identifier** to something unique, e.g. `com.yourname.fitsize`.

## 4. Prepare the iPhone

1. Plug it in with the cable; tap **Trust** on the phone when asked.
2. Turn on **Developer Mode**: Settings → Privacy & Security → Developer
   Mode → on (the phone restarts). iOS 16 and newer only show this after a
   first install attempt — if you don't see it, do step 5 once, then come
   back.

## 5. Run

In Xcode choose your iPhone in the device picker at the top, then press
**▶ Run** (⌘R). Or from Terminal:

```bash
flutter devices                 # find your phone's id
flutter run --release -d <id>   # release build = full speed camera/ML
```

The first launch may say *"Untrusted Developer"*: on the phone go to
Settings → General → **VPN & Device Management** → your Apple ID → **Trust**,
then open FitSize again.

## 6. Test

Allow the camera, enter your **measured** height, prop the phone upright at
hip height about 2–3 m away (lean it against something), tight clothing,
even light, and follow the voice. Try **Quick measure** first, then
**Precision measure (full turn)**. Compare against a tape and use *tap to
correct* on any card — those deltas are the data that tunes the app.

## Good to know

- With a free Apple ID the app **expires after 7 days** — just press Run
  again to refresh it. A paid developer account (US$99/yr) removes that and
  unlocks TestFlight for sharing builds with friends.
- The camera does not work in the iOS Simulator; use a real phone.
- The Android build installs without any of this: the latest APK is always at
  https://github.com/rujal-tuladhar/Camera-Size-Measurement/releases/download/fitsize-test/fitsize-latest.apk

## If something breaks

| Symptom | Fix |
| --- | --- |
| `pod install` fails on a version floor | `cd ios && pod repo update && pod install` (ML Kit needs iOS 15.5; the Podfile already sets it) |
| "Signing for Runner requires a development team" | step 3 — pick your Personal Team |
| "Could not launch… device locked" | unlock the phone, keep the screen on during install |
| Black camera preview | camera permission was declined: Settings → FitSize → Camera → on |
| `flutter doctor` complains about Android | ignore for iPhone testing |
